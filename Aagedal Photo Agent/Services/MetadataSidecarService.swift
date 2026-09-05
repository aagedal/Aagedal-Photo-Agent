import Foundation
import os

private nonisolated let sidecarLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "MetadataSidecarService")

struct MetadataSidecarService: Sendable {

    nonisolated static let sidecarDirectoryName = ".photo_metadata"
    /// Small JSON reads are cheap individually, but one task per sidecar creates thousands
    /// of runnable jobs for large event folders. A bounded pool keeps I/O parallel without
    /// overwhelming the cooperative executor or the filesystem.
    private nonisolated static let maxConcurrentReads = 12

    // MARK: - Directory Helpers

    private nonisolated func sidecarDirectory(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(Self.sidecarDirectoryName)
    }

    private nonisolated func sidecarFileURL(for imageURL: URL, in folderURL: URL) -> URL {
        let filename = imageURL.lastPathComponent
        return sidecarDirectory(for: folderURL).appendingPathComponent("\(filename).meta.json")
    }

    private nonisolated func legacySidecarFileURL(for imageURL: URL, in folderURL: URL) -> URL {
        let basename = imageURL.deletingPathExtension().lastPathComponent
        return sidecarDirectory(for: folderURL).appendingPathComponent("\(basename).meta.json")
    }

    private nonisolated func sidecarCandidateURLs(for imageURL: URL, in folderURL: URL) -> [URL] {
        let current = sidecarFileURL(for: imageURL, in: folderURL)
        let legacy = legacySidecarFileURL(for: imageURL, in: folderURL)
        if current == legacy { return [current] }
        return [current, legacy]
    }

    // MARK: - Load

    nonisolated func loadSidecar(for imageURL: URL, in folderURL: URL) -> MetadataSidecar? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for fileURL in sidecarCandidateURLs(for: imageURL, in: folderURL) {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            do {
                let data = try Data(contentsOf: fileURL)
                let sidecar = try decoder.decode(MetadataSidecar.self, from: data)
                guard !sidecar.sourceFile.contains("/"), !sidecar.sourceFile.contains("\\"), !sidecar.sourceFile.contains("..") else {
                    continue
                }
                return sidecar
            } catch let error as EditorialJSONSchemaError where error.isNewerSchema {
                sidecarLogger.warning(
                    "Leaving newer sidecar \(fileURL.lastPathComponent, privacy: .private(mask: .hash)) untouched: \(error.localizedDescription, privacy: .private)"
                )
                continue
            } catch {
                sidecarLogger.error("Failed to decode sidecar \(fileURL.lastPathComponent): \(error.localizedDescription)")
                // Move corrupt file aside so it doesn't block future loads
                let timestamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let backupURL = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("\(fileURL.lastPathComponent).corrupt.\(timestamp)")
                do {
                    try FileManager.default.moveItem(at: fileURL, to: backupURL)
                    sidecarLogger.warning("Moved corrupt sidecar to \(backupURL.lastPathComponent, privacy: .private(mask: .hash))")
                } catch {
                    sidecarLogger.error("Failed to move corrupt sidecar \(fileURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                }
                continue
            }
        }
        return nil
    }

    nonisolated func loadAllSidecars(in folderURL: URL) async -> [URL: MetadataSidecar] {
        let dir = sidecarDirectory(for: folderURL)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [:] }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return [:]
        }

        let jsonFiles = files.filter { $0.pathExtension == "json" }

        return await withTaskGroup(of: (URL, MetadataSidecar)?.self) { group in
            var iterator = jsonFiles.makeIterator()
            for _ in 0..<min(Self.maxConcurrentReads, jsonFiles.count) {
                guard let file = iterator.next() else { break }
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return Self.decodeSidecar(at: file, folderURL: folderURL)
                }
            }
            var result: [URL: MetadataSidecar] = [:]
            result.reserveCapacity(jsonFiles.count)
            while let item = await group.next() {
                if let (imageURL, sidecar) = item {
                    result[imageURL] = sidecar
                }
                if let file = iterator.next() {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return Self.decodeSidecar(at: file, folderURL: folderURL)
                    }
                }
            }
            return result
        }
    }

    nonisolated func loadSidecars(for imageURLs: [URL], in folderURL: URL) async -> [URL: MetadataSidecar] {
        guard !imageURLs.isEmpty else { return [:] }
        let requests = imageURLs.map { ($0, sidecarCandidateURLs(for: $0, in: folderURL)) }
        return await withTaskGroup(of: (URL, MetadataSidecar)?.self) { group in
            var iterator = requests.makeIterator()
            for _ in 0..<min(Self.maxConcurrentReads, requests.count) {
                guard let request = iterator.next() else { break }
                let (imageURL, candidates) = request
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    for fileURL in candidates {
                        guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
                        if let (_, sidecar) = Self.decodeSidecar(at: fileURL, folderURL: folderURL) {
                            return (imageURL, sidecar)
                        }
                    }
                    return nil
                }
            }
            var result: [URL: MetadataSidecar] = [:]
            result.reserveCapacity(imageURLs.count)
            while let item = await group.next() {
                if let (imageURL, sidecar) = item {
                    result[imageURL] = sidecar
                }
                if let request = iterator.next() {
                    let (imageURL, candidates) = request
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        for fileURL in candidates {
                            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
                            if let (_, sidecar) = Self.decodeSidecar(at: fileURL, folderURL: folderURL) {
                                return (imageURL, sidecar)
                            }
                        }
                        return nil
                    }
                }
            }
            return result
        }
    }

    nonisolated func imagesWithPendingChanges(in folderURL: URL) async -> Set<URL> {
        let sidecars = await loadAllSidecars(in: folderURL)
        return Set(sidecars.filter { $0.value.pendingChanges }.keys)
    }

    private nonisolated static func decodeSidecar(
        at file: URL,
        folderURL: URL
    ) -> (URL, MetadataSidecar)? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: file)
            let sidecar = try decoder.decode(MetadataSidecar.self, from: data)
            guard !sidecar.sourceFile.contains("/"),
                  !sidecar.sourceFile.contains("\\"),
                  !sidecar.sourceFile.contains("..") else {
                return nil
            }
            let imageURL = folderURL.appendingPathComponent(sidecar.sourceFile)
            return (imageURL, sidecar)
        } catch let error as EditorialJSONSchemaError where error.isNewerSchema {
            sidecarLogger.warning(
                "Leaving newer sidecar \(file.lastPathComponent, privacy: .private(mask: .hash)) untouched: \(error.localizedDescription, privacy: .private)"
            )
            return nil
        } catch {
            sidecarLogger.error("Failed to decode sidecar \(file.lastPathComponent): \(error.localizedDescription)")
            moveCorruptSidecarAside(file: file)
            return nil
        }
    }

    private nonisolated static func moveCorruptSidecarAside(file: URL) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.lastPathComponent).corrupt.\(timestamp)")
        do {
            try FileManager.default.moveItem(at: file, to: backupURL)
            sidecarLogger.warning("Moved corrupt sidecar to \(backupURL.lastPathComponent, privacy: .private(mask: .hash))")
        } catch {
            sidecarLogger.error("Failed to move corrupt sidecar \(file.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
    }

    func pendingFieldNames(for imageURL: URL, in folderURL: URL) -> [String] {
        guard let sidecar = loadSidecar(for: imageURL, in: folderURL),
              sidecar.pendingChanges,
              let original = sidecar.imageMetadataSnapshot else {
            return []
        }
        let edited = sidecar.metadata
        var names: [String] = []
        if edited.title != original.title { names.append("Headline") }
        if edited.description != original.description { names.append("Description") }
        if edited.extendedDescription != original.extendedDescription { names.append("Extended Description") }
        if edited.keywords != original.keywords { names.append("Keywords") }
        if edited.personShown != original.personShown { names.append("Person Shown") }
        if edited.organisationsShownNames != original.organisationsShownNames { names.append("Organisation Shown Name") }
        if edited.organisationsShownCodes != original.organisationsShownCodes { names.append("Organisation Shown Code") }
        if edited.rating != original.rating { names.append("Rating") }
        if edited.label != original.label { names.append("Label") }
        if edited.copyright != original.copyright { names.append("Copyright") }
        if edited.rightsUsageTerms != original.rightsUsageTerms { names.append("Rights Usage Terms") }
        if edited.webStatementOfRights != original.webStatementOfRights { names.append("Web Statement of Rights") }
        if edited.digitalImageGUID != original.digitalImageGUID { names.append("Digital Image GUID") }
        if edited.imageSupplierImageID != original.imageSupplierImageID { names.append("Image Supplier Image ID") }
        if edited.imageSuppliers != original.imageSuppliers { names.append("Image Supplier") }
        if edited.jobId != original.jobId { names.append("Job ID") }
        if edited.creators != original.creators { names.append("Creator") }
        if edited.creatorJobTitle != original.creatorJobTitle { names.append("Creator Job Title") }
        if edited.descriptionWriter != original.descriptionWriter { names.append("Description Writer") }
        if edited.credit != original.credit { names.append("Credit") }
        if edited.city != original.city { names.append("City") }
        if edited.sublocation != original.sublocation { names.append("Sublocation") }
        if edited.provinceState != original.provinceState { names.append("State / Province") }
        if edited.country != original.country { names.append("Country") }
        if edited.countryCode != original.countryCode { names.append("Country Code") }
        if edited.urgency != original.urgency { names.append("Urgency") }
        if edited.sceneCodes != original.sceneCodes { names.append("Scene Code") }
        if edited.subjectCodes != original.subjectCodes { names.append("Subject Code") }
        if edited.mediaTopics != original.mediaTopics { names.append("Media Topic") }
        if edited.genres != original.genres { names.append("Genre") }
        if edited.event != original.event { names.append("Event") }
        if edited.instructions != original.instructions { names.append("Instructions") }
        if edited.source != original.source { names.append("Source") }
        if edited.digitalSourceType != original.digitalSourceType { names.append("Digital Source Type") }
        if edited.latitude != original.latitude || edited.longitude != original.longitude { names.append("GPS Coordinates") }
        if edited.captureDate != original.captureDate { names.append("Capture Date") }
        return names
    }

    // MARK: - Save

    nonisolated func saveSidecar(_ sidecar: MetadataSidecar, for imageURL: URL, in folderURL: URL) throws {
        let dir = sidecarDirectory(for: folderURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var existingCurrentData: Data?
        for existingURL in sidecarCandidateURLs(for: imageURL, in: folderURL)
            where FileManager.default.fileExists(atPath: existingURL.path) {
            let existingData = try Data(contentsOf: existingURL)
            try EditorialJSONSchema.requireWritableVersion(
                in: existingData,
                supportedVersion: MetadataSidecar.currentSchemaVersion,
                documentName: "metadata sidecar",
                legacyKey: "version",
                unversionedLegacyVersion: 1
            )
            if existingCurrentData == nil {
                existingCurrentData = existingData
            }
        }

        var updatedSidecar = sidecar
        updatedSidecar.schemaVersion = MetadataSidecar.currentSchemaVersion
        updatedSidecar.lastModified = Date()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(updatedSidecar)
        if let existingCurrentData {
            data = Self.preservingUnknownFields(from: existingCurrentData, in: data)
        }
        let currentURL = sidecarFileURL(for: imageURL, in: folderURL)
        try data.write(to: currentURL, options: .atomic)

        let legacyURL = legacySidecarFileURL(for: imageURL, in: folderURL)
        if legacyURL != currentURL,
           FileManager.default.fileExists(atPath: legacyURL.path) {
            do {
                try FileManager.default.removeItem(at: legacyURL)
            } catch {
                sidecarLogger.warning("Failed to remove legacy sidecar \(legacyURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Builds batch metadata and its history from the same revision under the photo lock.
    /// The fallback is used only when no current or legacy record exists.
    nonisolated func updateMetadataSerialized(
        for imageURL: URL,
        in folderURL: URL,
        fallback: IPTCMetadata,
        pendingChanges: Bool,
        timestamp: Date = Date(),
        beforeRevisionCheck: @escaping @Sendable (Int) -> Void = { _ in },
        mutation: @escaping @Sendable (inout IPTCMetadata) -> Void
    ) async throws -> MetadataSidecar {
        try Task.checkCancellation()
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) {
            for attempt in 0..<4 {
                let tokens = try self.contentTokens(for: imageURL, in: folderURL)
                let current = self.loadSidecar(for: imageURL, in: folderURL)
                let previous = current?.metadata ?? fallback
                var metadata = previous
                mutation(&metadata)
                var history = current?.history ?? []
                history.append(contentsOf: MetadataHistoryEntry.changes(
                    from: previous, to: metadata, timestamp: timestamp
                ))
                history.trimToHistoryLimit()
                let sidecar = MetadataSidecar(
                    sourceFile: imageURL.lastPathComponent,
                    lastModified: timestamp,
                    pendingChanges: pendingChanges,
                    metadata: metadata,
                    imageMetadataSnapshot: pendingChanges
                        ? (current == nil ? fallback : current?.imageMetadataSnapshot) : metadata,
                    history: history
                )
                beforeRevisionCheck(attempt)
                await Task.yield()
                guard try self.contentTokens(for: imageURL, in: folderURL) == tokens else { continue }
                try self.saveSidecar(sidecar, for: imageURL, in: folderURL)
                guard let installed = self.loadSidecar(for: imageURL, in: folderURL),
                      Self.samePersistedRecord(installed, sidecar) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return installed
            }
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "The metadata sidecar kept changing while the batch edit was being saved."
            ])
        }
    }

    /// Serializes the complete JSON history transaction for one photo. History entries captured
    /// by Caption/Metadata/face workflows are treated as field mutations and replayed onto the
    /// latest on-disk record. This prevents a complete-but-stale draft from erasing an unrelated
    /// field saved while that draft was queued.
    nonisolated func saveSidecarMergingHistorySerialized(
        _ sidecar: MetadataSidecar,
        for imageURL: URL,
        in folderURL: URL
    ) async throws -> MetadataSidecar {
        try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) {
            for _ in 0..<4 {
                let sourceTokens = try self.contentTokens(for: imageURL, in: folderURL)
                let current = self.loadSidecar(for: imageURL, in: folderURL)
                let merged = Self.mergingHistory(sidecar, onto: current)

                await Task.yield()
                guard try self.contentTokens(for: imageURL, in: folderURL) == sourceTokens else {
                    continue
                }

                try self.saveSidecar(merged, for: imageURL, in: folderURL)
                guard let readBack = self.loadSidecar(for: imageURL, in: folderURL),
                      Self.samePersistedRecord(readBack, merged)
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return readBack
            }
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "The metadata sidecar kept changing while the edit was being saved."
            ])
        }
    }

    /// Serializes an intentional history replacement. The latest metadata record remains
    /// authoritative so clearing history cannot erase a face/caption mutation that reached the
    /// shared boundary first.
    nonisolated func saveSidecarReplacingHistorySerialized(
        _ sidecar: MetadataSidecar,
        for imageURL: URL,
        in folderURL: URL
    ) async throws -> MetadataSidecar {
        try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) {
            for _ in 0..<4 {
                let sourceTokens = try self.contentTokens(for: imageURL, in: folderURL)
                let current = self.loadSidecar(for: imageURL, in: folderURL)
                var replacement = current ?? sidecar
                replacement.history = sidecar.history

                await Task.yield()
                guard try self.contentTokens(for: imageURL, in: folderURL) == sourceTokens else {
                    continue
                }

                try self.saveSidecar(replacement, for: imageURL, in: folderURL)
                guard let readBack = self.loadSidecar(for: imageURL, in: folderURL),
                      Self.samePersistedRecord(readBack, replacement)
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return readBack
            }
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "The metadata sidecar kept changing while the edit was being saved."
            ])
        }
    }

    /// Exact bytes captured before a file write. Cleanup consumes this evidence under the
    /// photo lock, so a sidecar saved while the image writer was running survives.
    nonisolated struct WriteCleanupSnapshot: Sendable {
        let imageURL: URL
        let folderURL: URL
        fileprivate let tokens: [Data?]
        fileprivate let matchesEditor: Bool
    }

    nonisolated func captureWriteCleanupSnapshot(
        for imageURL: URL,
        in folderURL: URL,
        expected: MetadataSidecar? = nil,
        editorRecord: MetadataSidecar? = nil,
        requiresEditorMatch: Bool = false,
        beforeRead: @escaping @Sendable () throws -> Void = {}
    ) async throws -> WriteCleanupSnapshot {
        try Task.checkCancellation()
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) {
            try beforeRead()
            let tokens = try self.contentTokens(for: imageURL, in: folderURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try tokens.compactMap { data -> MetadataSidecar? in
                guard let data else { return nil }
                let record = try decoder.decode(MetadataSidecar.self, from: data)
                guard record.sourceFile == imageURL.lastPathComponent else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return record
            }
            if let expected {
                guard let current = records.first, Self.samePersistedRecord(current, expected) else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [
                        NSLocalizedDescriptionKey: "Pending metadata changed before the file write. Try again."
                    ])
                }
            }
            let matchesEditor = records.allSatisfy { current in
                guard let editorRecord else { return !requiresEditorMatch }
                var intended = current
                intended.metadata = editorRecord.metadata
                intended.history = editorRecord.history
                return Self.samePersistedRecord(current, intended)
            }
            return WriteCleanupSnapshot(
                imageURL: imageURL, folderURL: folderURL, tokens: tokens, matchesEditor: matchesEditor
            )
        }
    }

    /// Returns false when a later sidecar revision must be retained. No retry may adopt
    /// that revision: the image write only committed the originally captured metadata.
    nonisolated func deleteSidecarAfterWriteSerialized(
        _ snapshot: WriteCleanupSnapshot,
        beforeRevisionCheck: @escaping @Sendable () throws -> Void = {}
    ) async throws -> Bool {
        try Task.checkCancellation()
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: snapshot.imageURL)) {
            try beforeRevisionCheck()
            guard snapshot.matchesEditor,
                  try self.contentTokens(for: snapshot.imageURL, in: snapshot.folderURL) == snapshot.tokens else {
                return false
            }
            try self.deleteSidecar(for: snapshot.imageURL, in: snapshot.folderURL)
            return true
        }
    }

    // MARK: - Delete

    /// Refresh cleanup must recheck eligibility under the same photo lock as history saves.
    /// Inspect both naming generations before removing either, and leave unreadable/newer-schema
    /// documents in place. Once admitted, the transaction follows the coordinator's existing
    /// run-to-completion contract; cancellation can only prevent entry.
    nonisolated func deleteUnneededSidecarSerialized(
        for imageURL: URL,
        in folderURL: URL,
        beforeRevisionCheck: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> Bool {
        try Task.checkCancellation()
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) {
            for attempt in 0..<4 {
                let tokens = try self.contentTokens(for: imageURL, in: folderURL)
                guard tokens.contains(where: { $0 != nil }) else { return false }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                for data in tokens.compactMap({ $0 }) {
                    guard let record = try? decoder.decode(MetadataSidecar.self, from: data),
                          !record.pendingChanges, record.history.isEmpty,
                          record.sourceFile == imageURL.lastPathComponent else { return false }
                }
                beforeRevisionCheck(attempt)
                await Task.yield()
                guard try self.contentTokens(for: imageURL, in: folderURL) == tokens else {
                    continue
                }
                try self.deleteSidecar(for: imageURL, in: folderURL)
                return true
            }
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "The metadata sidecar kept changing while cleanup was being prepared."
            ])
        }
    }

    /// Explicit user discard is serialized with photo writes. Unlike refresh cleanup it
    /// intentionally removes pending edits/history. Cancellation prevents admission only.
    nonisolated func deleteSidecarSerialized(
        for imageURL: URL,
        in folderURL: URL,
        beforeDelete: @escaping @Sendable () throws -> Void = {}
    ) async throws {
        try Task.checkCancellation()
        try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) {
            try beforeDelete()
            try self.deleteSidecar(for: imageURL, in: folderURL)
        }
    }

    nonisolated func deleteSidecar(for imageURL: URL, in folderURL: URL) throws {
        for fileURL in sidecarCandidateURLs(for: imageURL, in: folderURL) {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    nonisolated func deleteAllSidecarsSerialized(
        in folderURL: URL,
        beforeDelete: @escaping @Sendable () throws -> Void = {}
    ) async throws {
        try Task.checkCancellation()
        let folderKey = folderURL.resolvingSymlinksInPath().path.lowercased()
        try await MetadataIOCoordinator.shared.withFolderLock(folderKey) {
            try beforeDelete()
            try self.deleteAllSidecars(in: folderURL)
        }
    }

    nonisolated func deleteAllSidecars(in folderURL: URL) throws {
        let dir = sidecarDirectory(for: folderURL)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    func renameSidecar(from oldImageURL: URL, to newImageURL: URL, in folderURL: URL) throws {
        let fm = FileManager.default
        let sourceURLs = sidecarCandidateURLs(for: oldImageURL, in: folderURL).filter {
            fm.fileExists(atPath: $0.path)
        }
        guard !sourceURLs.isEmpty else { return }

        // Load existing sidecar, update sourceFile to match the new filename, and save at new path.
        // If this build cannot decode the document (including a newer schema), preserve its
        // complete JSON graph and rewrite only the association field.
        if var sidecar = loadSidecar(for: oldImageURL, in: folderURL) {
            sidecar.sourceFile = newImageURL.lastPathComponent
            try saveSidecar(sidecar, for: newImageURL, in: folderURL)
        } else if let first = sourceURLs.first {
            let originalData = try Data(contentsOf: first)
            let destinationData = Self.updatingSourceFile(
                in: originalData,
                to: newImageURL.lastPathComponent,
                sourceURL: first
            )
            let destinationURL = sidecarFileURL(for: newImageURL, in: folderURL)
            try destinationData.write(to: destinationURL, options: .atomic)
        }

        // Remove all old sidecar files (current + legacy)
        for oldURL in sourceURLs {
            let newURL = sidecarFileURL(for: newImageURL, in: folderURL)
            guard oldURL != newURL else { continue }
            do {
                try fm.removeItem(at: oldURL)
            } catch {
                sidecarLogger.warning("Failed to remove old sidecar \(oldURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    nonisolated func moveSidecar(for imageURL: URL, from sourceFolderURL: URL, to destinationFolderURL: URL) throws {
        let fm = FileManager.default
        let sourceURLs = sidecarCandidateURLs(for: imageURL, in: sourceFolderURL).filter {
            fm.fileExists(atPath: $0.path)
        }
        guard !sourceURLs.isEmpty else { return }

        let destinationDirectory = sidecarDirectory(for: destinationFolderURL)
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationURL = sidecarFileURL(for: imageURL, in: destinationFolderURL)

        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        if let first = sourceURLs.first {
            try fm.moveItem(at: first, to: destinationURL)
        }
        for extra in sourceURLs.dropFirst() {
            do {
                try fm.removeItem(at: extra)
            } catch {
                sidecarLogger.warning("Failed to remove extra sidecar \(extra.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Moves a sidecar while allowing the image filename to change. The JSON's
    /// `sourceFile` value must follow the destination filename or bulk sidecar
    /// loading will continue to associate it with the old image URL.
    nonisolated func relocateSidecar(
        for sourceImageURL: URL,
        to destinationImageURL: URL,
        from sourceFolderURL: URL,
        to destinationFolderURL: URL
    ) throws {
        let fm = FileManager.default
        let sourceURLs = sidecarCandidateURLs(for: sourceImageURL, in: sourceFolderURL).filter {
            fm.fileExists(atPath: $0.path)
        }
        guard let sourceURL = sourceURLs.first else { return }

        let sourceData = try Data(contentsOf: sourceURL)
        let destinationData = Self.updatingSourceFile(
            in: sourceData,
            to: destinationImageURL.lastPathComponent,
            sourceURL: sourceURL
        )
        let destinationDirectory = sidecarDirectory(for: destinationFolderURL)
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationURL = sidecarFileURL(for: destinationImageURL, in: destinationFolderURL)
        guard !fm.fileExists(atPath: destinationURL.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destinationURL.path])
        }
        try destinationData.write(to: destinationURL, options: .atomic)

        // The destination is safely on disk before any source artifact is removed.
        // A legacy duplicate may coexist with the current sidecar, so clean up both.
        for oldURL in sourceURLs {
            do {
                try fm.removeItem(at: oldURL)
            } catch {
                sidecarLogger.warning("Failed to remove relocated sidecar \(oldURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private nonisolated static func updatingSourceFile(
        in data: Data,
        to filename: String,
        sourceURL: URL
    ) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Preserve an unreadable sidecar with the rejected image. Normal loading
            // will quarantine it as corrupt, while the original bytes remain recoverable.
            sidecarLogger.warning("Relocating unreadable sidecar \(sourceURL.lastPathComponent, privacy: .private(mask: .hash)) without rewriting sourceFile")
            return data
        }
        object["sourceFile"] = filename
        guard let updated = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            sidecarLogger.warning("Could not rewrite sourceFile in \(sourceURL.lastPathComponent, privacy: .private(mask: .hash)); preserving original data")
            return data
        }
        return updated
    }

    /// Overlay unknown extension fields from a same-schema sidecar onto freshly encoded data.
    /// Known keys are intentionally not merged: if the current model omits a known optional key,
    /// that represents an explicit clear and the old value must stay removed.
    private nonisolated static func preservingUnknownFields(
        from existingData: Data,
        in encodedData: Data
    ) -> Data {
        guard let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
              var encoded = try? JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
        else {
            return encodedData
        }

        for (key, value) in existing where !MetadataSidecar.persistedJSONFieldNames.contains(key) {
            encoded[key] = value
        }
        preserveUnknownMetadataFields(key: "metadata", from: existing, in: &encoded)
        preserveUnknownMetadataFields(key: "imageMetadataSnapshot", from: existing, in: &encoded)

        return (try? JSONSerialization.data(
            withJSONObject: encoded,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? encodedData
    }

    private nonisolated func contentTokens(for imageURL: URL, in folderURL: URL) throws -> [Data?] {
        try sidecarCandidateURLs(for: imageURL, in: folderURL).map { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
    }

    private nonisolated static func mergingHistory(
        _ incoming: MetadataSidecar,
        onto current: MetadataSidecar?
    ) -> MetadataSidecar {
        guard let current else { return incoming }

        let currentIDs = Set(current.history.map(\.id))
        let newEntries = incoming.history
            .filter { !currentIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id < rhs.id
            }

        // Callers that do not provide a history delta retain the established whole-record save
        // contract. Transactional editor workflows always provide entries for their changed fields.
        var metadata = newEntries.isEmpty ? incoming.metadata : current.metadata
        for entry in newEntries {
            guard !entry.apply(to: &metadata) else { continue }
            // Summarized/redacted values are intentionally absent from history. Copy only the
            // field named by the delta from the captured incoming record so an unrelated field
            // that changed while this draft was queued remains authoritative.
            _ = Self.applyNonReplayableChange(entry, from: incoming.metadata, to: &metadata)
        }

        var historyByID = Dictionary(uniqueKeysWithValues: current.history.map { ($0.id, $0) })
        for entry in incoming.history { historyByID[entry.id] = entry }
        var history = historyByID.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }
        history.trimToHistoryLimit()

        return MetadataSidecar(
            sourceFile: incoming.sourceFile,
            lastModified: max(current.lastModified, incoming.lastModified),
            pendingChanges: incoming.pendingChanges,
            metadata: metadata,
            imageMetadataSnapshot: incoming.imageMetadataSnapshot ?? current.imageMetadataSnapshot,
            history: history
        )
    }

    private nonisolated static func applyNonReplayableChange(
        _ entry: MetadataHistoryEntry,
        from incoming: IPTCMetadata,
        to metadata: inout IPTCMetadata
    ) -> Bool {
        if let fieldID = entry.fieldID {
            fieldID.setHistoryValue(fieldID.historyValue(in: incoming), in: &metadata)
            return true
        }

        switch entry.fieldName {
        case "Creator Contact Information":
            metadata.creatorContactInfo = incoming.creatorContactInfo
        case "Location Created":
            metadata.locationsCreated = incoming.locationsCreated
        case "Location Shown":
            metadata.locationsShown = incoming.locationsShown
        case "GPS", "GPS Coordinates":
            metadata.latitude = incoming.latitude
            metadata.longitude = incoming.longitude
        default:
            // Audit-only and unknown future events do not authorize replacing a complete
            // metadata record. Their history is retained while the latest record stays intact.
            return false
        }
        return true
    }

    private nonisolated static func samePersistedRecord(
        _ lhs: MetadataSidecar,
        _ rhs: MetadataSidecar
    ) -> Bool {
        // saveSidecar refreshes lastModified. Compare the deterministic encoded payload after
        // normalizing that installation timestamp.
        var left = lhs
        var right = rhs
        left.lastModified = .distantPast
        right.lastModified = .distantPast
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(left)) == (try? encoder.encode(right))
    }

    private nonisolated static func preserveUnknownMetadataFields(
        key: String,
        from existingSidecar: [String: Any],
        in encodedSidecar: inout [String: Any]
    ) {
        guard let existingMetadata = existingSidecar[key] as? [String: Any],
              var encodedMetadata = encodedSidecar[key] as? [String: Any]
        else {
            return
        }
        for (field, value) in existingMetadata
            where !IPTCMetadata.persistedJSONFieldNames.contains(field) {
            encodedMetadata[field] = value
        }
        encodedSidecar[key] = encodedMetadata
    }
}

private extension EditorialJSONSchemaError {
    var isNewerSchema: Bool {
        if case .newerSchemaRequiresReadOnly = self { return true }
        return false
    }
}

/// Immutable input for the two-artifact metadata save used by the single-image XMP workflow.
/// Keeping the complete snapshot in one value prevents a selection change on the main actor from
/// redirecting either half of the persistence operation to a different photo.
nonisolated struct MetadataSidecarPersistenceRequest: Sendable {
    let sidecar: MetadataSidecar
    let imageURL: URL
    let folderURL: URL
    let mergeWithExistingXMP: Bool

    init(
        sidecar: MetadataSidecar,
        imageURL: URL,
        folderURL: URL,
        mergeWithExistingXMP: Bool = true
    ) {
        self.sidecar = sidecar
        self.imageURL = imageURL
        self.folderURL = folderURL
        self.mergeWithExistingXMP = mergeWithExistingXMP
    }
}

/// The JSON history record is installed before its Adobe-compatible XMP mirror. A failure or
/// cancellation between those commits is therefore partial success, not an all-or-nothing error.
/// The main actor consumes this value without needing to inspect the filesystem again.
nonisolated struct MetadataSidecarPersistenceResult: Sendable {
    enum FailureStage: String, Sendable {
        case metadataSidecar
        case xmpSidecar
    }

    struct Failure: Sendable, Equatable {
        let stage: FailureStage
        let message: String
    }

    let installedSidecar: MetadataSidecar?
    let wroteXMPSidecar: Bool
    let wasCancelled: Bool
    let failure: Failure?

    var completed: Bool {
        installedSidecar != nil && wroteXMPSidecar && !wasCancelled && failure == nil
    }
}

/// Off-main orchestration for the metadata JSON + XMP transaction. Each artifact retains the
/// existing per-photo `MetadataIOCoordinator` serialization and atomic-install behavior. The
/// actor adds one async boundary for the view model and makes the only partial-commit point
/// observable: JSON history installed, then cancellation/XMP failure before the mirror commits.
actor MetadataSidecarPersistenceService {
    private let metadataSidecarService: MetadataSidecarService
    private let xmpSidecarService: XMPSidecarService

    init(
        metadataSidecarService: MetadataSidecarService = MetadataSidecarService(),
        xmpSidecarService: XMPSidecarService = XMPSidecarService()
    ) {
        self.metadataSidecarService = metadataSidecarService
        self.xmpSidecarService = xmpSidecarService
    }

    func persistHistoryAndMirrorXMP(
        _ request: MetadataSidecarPersistenceRequest
    ) async -> MetadataSidecarPersistenceResult {
        guard !Task.isCancelled else {
            return MetadataSidecarPersistenceResult(
                installedSidecar: nil,
                wroteXMPSidecar: false,
                wasCancelled: true,
                failure: nil
            )
        }

        let installed: MetadataSidecar
        do {
            installed = try await metadataSidecarService.saveSidecarMergingHistorySerialized(
                request.sidecar,
                for: request.imageURL,
                in: request.folderURL
            )
        } catch is CancellationError {
            return MetadataSidecarPersistenceResult(
                installedSidecar: nil,
                wroteXMPSidecar: false,
                wasCancelled: true,
                failure: nil
            )
        } catch {
            return MetadataSidecarPersistenceResult(
                installedSidecar: nil,
                wroteXMPSidecar: false,
                wasCancelled: false,
                failure: .init(stage: .metadataSidecar, message: error.localizedDescription)
            )
        }

        // A Foundation atomic write that has returned is committed even if cancellation arrived
        // during it. Stop before the next artifact and report that durable partial success.
        guard !Task.isCancelled else {
            return MetadataSidecarPersistenceResult(
                installedSidecar: installed,
                wroteXMPSidecar: false,
                wasCancelled: true,
                failure: nil
            )
        }

        do {
            try await xmpSidecarService.saveSidecarPreservingDevelopSettingsSerialized(
                metadata: installed.metadata,
                for: request.imageURL,
                mergeWithExisting: request.mergeWithExistingXMP
            )
            return MetadataSidecarPersistenceResult(
                installedSidecar: installed,
                wroteXMPSidecar: true,
                wasCancelled: false,
                failure: nil
            )
        } catch is CancellationError {
            return MetadataSidecarPersistenceResult(
                installedSidecar: installed,
                wroteXMPSidecar: false,
                wasCancelled: true,
                failure: nil
            )
        } catch {
            return MetadataSidecarPersistenceResult(
                installedSidecar: installed,
                wroteXMPSidecar: false,
                wasCancelled: false,
                failure: .init(stage: .xmpSidecar, message: error.localizedDescription)
            )
        }
    }
}
