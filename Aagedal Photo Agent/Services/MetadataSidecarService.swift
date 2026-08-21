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

    func loadSidecar(for imageURL: URL, in folderURL: URL) -> MetadataSidecar? {
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
                    "Leaving newer sidecar \(fileURL.lastPathComponent, privacy: .public) untouched: \(error.localizedDescription, privacy: .public)"
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
                    sidecarLogger.warning("Moved corrupt sidecar to \(backupURL.lastPathComponent, privacy: .public)")
                } catch {
                    sidecarLogger.error("Failed to move corrupt sidecar \(fileURL.lastPathComponent): \(error.localizedDescription, privacy: .public)")
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
                "Leaving newer sidecar \(file.lastPathComponent, privacy: .public) untouched: \(error.localizedDescription, privacy: .public)"
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
            sidecarLogger.warning("Moved corrupt sidecar to \(backupURL.lastPathComponent, privacy: .public)")
        } catch {
            sidecarLogger.error("Failed to move corrupt sidecar \(file.lastPathComponent): \(error.localizedDescription, privacy: .public)")
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
        if edited.jobId != original.jobId { names.append("Job ID") }
        if edited.creator != original.creator { names.append("Creator") }
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
        if edited.event != original.event { names.append("Event") }
        if edited.instructions != original.instructions { names.append("Instructions") }
        if edited.source != original.source { names.append("Source") }
        if edited.digitalSourceType != original.digitalSourceType { names.append("Digital Source Type") }
        if edited.latitude != original.latitude || edited.longitude != original.longitude { names.append("GPS Coordinates") }
        if edited.captureDate != original.captureDate { names.append("Capture Date") }
        return names
    }

    // MARK: - Save

    func saveSidecar(_ sidecar: MetadataSidecar, for imageURL: URL, in folderURL: URL) throws {
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
                sidecarLogger.warning("Failed to remove legacy sidecar \(legacyURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Delete

    func deleteSidecar(for imageURL: URL, in folderURL: URL) throws {
        for fileURL in sidecarCandidateURLs(for: imageURL, in: folderURL) {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func deleteAllSidecars(in folderURL: URL) throws {
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
                sidecarLogger.warning("Failed to remove old sidecar \(oldURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
                sidecarLogger.warning("Failed to remove extra sidecar \(extra.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
                sidecarLogger.warning("Failed to remove relocated sidecar \(oldURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
            sidecarLogger.warning("Relocating unreadable sidecar \(sourceURL.lastPathComponent, privacy: .public) without rewriting sourceFile")
            return data
        }
        object["sourceFile"] = filename
        guard let updated = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            sidecarLogger.warning("Could not rewrite sourceFile in \(sourceURL.lastPathComponent, privacy: .public); preserving original data")
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
