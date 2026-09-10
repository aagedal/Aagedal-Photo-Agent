import Foundation
import os

private nonisolated let sidecarLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "MetadataSidecarService")

struct MetadataSidecarService: Sendable {

    nonisolated static let sidecarDirectoryName = ".photo_metadata"
    /// Small JSON reads are cheap individually, but one task per sidecar creates thousands
    /// of queued jobs for large event folders. Bound admission to the Dispatch worker so
    /// cancellation stops queued reads and other metadata transactions can make progress.
    private nonisolated static let maxPendingReads = 12

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

    private nonisolated struct CarrierSnapshot: Sendable, Equatable {
        let url: URL
        let data: Data
        let isCurrent: Bool
        let isOwned: Bool
    }

    private nonisolated func entryExists(_ url: URL) throws -> Bool {
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return false }
    }

    private nonisolated func ownershipChanged(_ url: URL) -> CocoaError {
        CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path,
            NSLocalizedDescriptionKey: "Metadata ownership or contents changed at \(url.path). Existing data was preserved; reload before retrying."])
    }

    private nonisolated func invalidOwnership(_ url: URL) -> CocoaError {
        CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path,
            NSLocalizedDescriptionKey: "Cannot safely establish metadata ownership at \(url.path). Existing data was preserved."])
    }

    private nonisolated func requireRegularFile(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw invalidOwnership(url)
        }
    }

    private nonisolated func requireMetadataDirectory(in folderURL: URL) throws {
        let directory = sidecarDirectory(for: folderURL)
        if try entryExists(directory),
           try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType != .typeDirectory {
            throw invalidOwnership(directory)
        }
    }

    private nonisolated func declaredOwner(in data: Data, at url: URL) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let owner = object["sourceFile"] as? String,
              !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              owner != ".", owner != "..", !owner.contains("/"), !owner.contains("\\"), !owner.contains("\0") else {
            throw invalidOwnership(url)
        }
        return owner
    }

    private nonisolated func requireIncomingOwner(_ record: MetadataSidecar, imageURL: URL) throws {
        guard record.sourceFile == imageURL.lastPathComponent else { throw invalidOwnership(imageURL) }
        guard record.schemaVersion == MetadataSidecar.currentSchemaVersion else {
            throw EditorialJSONSchemaError.newerSchemaRequiresReadOnly(document: "metadata sidecar",
                found: record.schemaVersion, supported: MetadataSidecar.currentSchemaVersion)
        }
    }

    private nonisolated func carrierSnapshots(for imageURL: URL, in folderURL: URL) throws -> [CarrierSnapshot] {
        try requireMetadataDirectory(in: folderURL)
        let current = sidecarFileURL(for: imageURL, in: folderURL)
        return try sidecarCandidateURLs(for: imageURL, in: folderURL).compactMap { url in
            guard try entryExists(url) else { return nil }
            try requireRegularFile(url)
            let data = try Data(contentsOf: url)
            let owner = try declaredOwner(in: data, at: url)
            let isCurrent = url == current
            let isOwned = owner == imageURL.lastPathComponent
            guard !isCurrent || isOwned else { throw invalidOwnership(url) }
            return CarrierSnapshot(url: url, data: data, isCurrent: isCurrent, isOwned: isOwned)
        }
    }

    private nonisolated func decodeOwnedRecords(_ snapshots: [CarrierSnapshot]) throws -> [MetadataSidecar] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try snapshots.filter(\.isOwned).map { carrier in
            try EditorialJSONSchema.requireWritableVersion(in: carrier.data,
                supportedVersion: MetadataSidecar.currentSchemaVersion, documentName: "metadata sidecar",
                legacyKey: "version", unversionedLegacyVersion: 1)
            return try decoder.decode(MetadataSidecar.self, from: carrier.data)
        }
    }

    private nonisolated func ownedRecords(for imageURL: URL, in folderURL: URL) throws -> [MetadataSidecar] {
        try decodeOwnedRecords(carrierSnapshots(for: imageURL, in: folderURL))
    }

    /// Explicit association-only copy preserves the entire JSON graph, including future-schema
    /// fields and both owned naming generations. No copied record can adopt destination data.
    nonisolated func copySidecarsPreservingOpaqueFields(
        for sourceImageURL: URL, to destinationImageURL: URL, in folderURL: URL,
        beforeInstall: @Sendable () throws -> Void = {},
        install: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws {
        let snapshots = try carrierSnapshots(for: sourceImageURL, in: folderURL)
        let owned = snapshots.filter(\.isOwned)
        try requireMetadataDirectory(in: folderURL)
        let destinations = sidecarCandidateURLs(for: destinationImageURL, in: folderURL)
        for destination in destinations where try entryExists(destination) { throw ownershipChanged(destination) }
        guard !owned.isEmpty else { return }
        let directory = sidecarDirectory(for: folderURL)
        let staging = directory.appendingPathComponent(".copy-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var prepared: [(staged: URL, destination: URL)] = []
        for carrier in owned {
            let destination = carrier.isCurrent
                ? sidecarFileURL(for: destinationImageURL, in: folderURL)
                : legacySidecarFileURL(for: destinationImageURL, in: folderURL)
            let data = Self.updatingSourceFile(in: carrier.data, to: destinationImageURL.lastPathComponent, sourceURL: carrier.url)
            let staged = staging.appendingPathComponent(destination.lastPathComponent)
            try data.write(to: staged, options: .atomic)
            prepared.append((staged, destination))
        }
        try beforeInstall()
        guard try snapshots == carrierSnapshots(for: sourceImageURL, in: folderURL) else { throw ownershipChanged(sourceImageURL) }
        for destination in destinations where try entryExists(destination) { throw ownershipChanged(destination) }
        var installed: [URL] = []
        do {
            for item in prepared {
                do {
                    try install(item.staged, item.destination)
                    installed.append(item.destination)
                } catch {
                    if !(try entryExists(item.staged)), try entryExists(item.destination) {
                        installed.append(item.destination)
                    }
                    throw error
                }
            }
        } catch {
            var residuals: [String] = []
            for destination in installed.reversed() {
                do { try FileManager.default.removeItem(at: destination) }
                catch { residuals.append(destination.path) }
            }
            if !residuals.isEmpty {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                    "Metadata copy failed; incomplete owned copies need cleanup: \(residuals.joined(separator: ", "))"])
            }
            throw error
        }
    }

    // MARK: - Load

    /// Filename discovery never authorizes adopting a different photo's document. Reads are
    /// non-mutating: ambiguous or unsupported carriers remain available for explicit recovery.
    nonisolated func loadSidecar(for imageURL: URL, in folderURL: URL) -> MetadataSidecar? {
        try? loadOwnedSidecarForMutation(for: imageURL, in: folderURL)
    }

    nonisolated func loadOwnedSidecarForMutation(for imageURL: URL, in folderURL: URL) throws -> MetadataSidecar? {
        try ownedRecords(for: imageURL, in: folderURL).first
    }

    @MetadataSidecarFilesystemActor
    func loadAllSidecars(
        in folderURL: URL,
        beforeRead: @escaping @Sendable (URL) -> Void = { _ in }
    ) async -> [URL: MetadataSidecar] {
        guard !Task.isCancelled else { return [:] }
        do { try requireMetadataDirectory(in: folderURL) } catch { return [:] }
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
            for _ in 0..<min(Self.maxPendingReads, jsonFiles.count) {
                guard let file = iterator.next() else { break }
                group.addTask { @MetadataSidecarFilesystemActor in
                    guard !Task.isCancelled else { return nil }
                    beforeRead(file)
                    return Self.decodeSidecar(at: file, folderURL: folderURL)
                }
            }
            var result: [URL: MetadataSidecar] = [:]
            result.reserveCapacity(jsonFiles.count)
            while let item = await group.next() {
                if let (imageURL, sidecar) = item {
                    result[imageURL] = sidecar
                }
                if !Task.isCancelled, let file = iterator.next() {
                    group.addTask { @MetadataSidecarFilesystemActor in
                        guard !Task.isCancelled else { return nil }
                        beforeRead(file)
                        return Self.decodeSidecar(at: file, folderURL: folderURL)
                    }
                }
            }
            return result
        }
    }

    @MetadataSidecarFilesystemActor
    func loadSidecars(
        for imageURLs: [URL], in folderURL: URL,
        beforeRead: @escaping @Sendable (URL) -> Void = { _ in }
    ) async -> [URL: MetadataSidecar] {
        guard !Task.isCancelled, !imageURLs.isEmpty else { return [:] }
        let requests = imageURLs.map { ($0, sidecarCandidateURLs(for: $0, in: folderURL)) }
        return await withTaskGroup(of: (URL, MetadataSidecar)?.self) { group in
            var iterator = requests.makeIterator()
            for _ in 0..<min(Self.maxPendingReads, requests.count) {
                guard let request = iterator.next() else { break }
                let (imageURL, _) = request
                group.addTask { @MetadataSidecarFilesystemActor in
                    guard !Task.isCancelled else { return nil }
                    beforeRead(imageURL)
                    guard let sidecar = try? self.loadOwnedSidecarForMutation(for: imageURL, in: folderURL) else { return nil }
                    return (imageURL, sidecar)
                }
            }
            var result: [URL: MetadataSidecar] = [:]
            result.reserveCapacity(imageURLs.count)
            while let item = await group.next() {
                if let (imageURL, sidecar) = item {
                    result[imageURL] = sidecar
                }
                if !Task.isCancelled, let request = iterator.next() {
                    let (imageURL, _) = request
                    group.addTask { @MetadataSidecarFilesystemActor in
                        guard !Task.isCancelled else { return nil }
                        beforeRead(imageURL)
                        guard let sidecar = try? self.loadOwnedSidecarForMutation(for: imageURL, in: folderURL) else { return nil }
                        return (imageURL, sidecar)
                    }
                }
            }
            return result
        }
    }

    @MetadataSidecarFilesystemActor
    func imagesWithPendingChanges(in folderURL: URL) async -> Set<URL> {
        let sidecars = await loadAllSidecars(in: folderURL)
        return Set(sidecars.filter { $0.value.pendingChanges }.keys)
    }

    private nonisolated static func decodeSidecar(at file: URL, folderURL: URL) -> (URL, MetadataSidecar)? {
        do {
            let service = MetadataSidecarService()
            try service.requireRegularFile(file)
            let data = try Data(contentsOf: file)
            let owner = try service.declaredOwner(in: data, at: file)
            let imageURL = folderURL.appendingPathComponent(owner)
            // Foundation directory enumeration can return absolute/canonical URLs while
            // callers retain /var aliases or base-URL forms. Compare resolved filesystem paths,
            // preserving the exact expected carrier filename and the caller's result URL.
            let observedPath = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard service.sidecarCandidateURLs(for: imageURL, in: folderURL).contains(where: {
                $0.lastPathComponent == file.lastPathComponent
                    && $0.resolvingSymlinksInPath().standardizedFileURL.path == observedPath
            }), let record = try service.loadOwnedSidecarForMutation(for: imageURL, in: folderURL) else { return nil }
            // Every carrier resolves through the canonical current record, so enumeration and
            // task completion order cannot let stale legacy metadata overwrite current edits.
            return (imageURL, record)
        } catch {
            sidecarLogger.warning("Preserving unreadable or unowned sidecar \(file.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return nil
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
        try requireIncomingOwner(sidecar, imageURL: imageURL)
        let snapshots = try carrierSnapshots(for: imageURL, in: folderURL)
        let owned = snapshots.filter(\.isOwned)
        _ = try decodeOwnedRecords(owned)
        var updatedSidecar = sidecar
        updatedSidecar.schemaVersion = MetadataSidecar.currentSchemaVersion
        updatedSidecar.lastModified = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(updatedSidecar)
        if let existing = owned.first {
            data = Self.preservingUnknownFields(from: existing.data, in: data)
        }
        let dir = sidecarDirectory(for: folderURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard try snapshots == carrierSnapshots(for: imageURL, in: folderURL) else { throw ownershipChanged(imageURL) }
        let currentURL = sidecarFileURL(for: imageURL, in: folderURL)
        try data.write(to: currentURL, options: .atomic)
        // Only a sole owned legacy document was migrated into this new current record. When
        // both generations already exist, keep legacy's distinct opaque data rather than erase
        // it. Proven foreign legacy documents never contribute fields or enter cleanup.
        if owned.count == 1, let legacy = owned.first, !legacy.isCurrent {
            do {
                try requireRegularFile(legacy.url)
                if try Data(contentsOf: legacy.url) == legacy.data {
                    try FileManager.default.removeItem(at: legacy.url)
                }
            } catch {
                sidecarLogger.warning("Current metadata was saved; legacy cleanup retained \(legacy.url.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Builds batch metadata and its history from the same revision under the photo lock.
    /// The fallback is used only when no current or legacy record exists.
    @MetadataSidecarFilesystemActor
    func updateMetadataSerialized(
        for imageURL: URL,
        in folderURL: URL,
        fallback: IPTCMetadata,
        pendingChanges: Bool,
        timestamp: Date = Date(),
        beforeRevisionCheck: @escaping @Sendable (Int) -> Void = { _ in },
        mutation: @escaping @Sendable (inout IPTCMetadata) -> Void
    ) async throws -> MetadataSidecar {
        try Task.checkCancellation()
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            for attempt in 0..<4 {
                let tokens = try self.contentTokens(for: imageURL, in: folderURL)
                let current = try self.loadOwnedSidecarForMutation(for: imageURL, in: folderURL)
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
    @MetadataSidecarFilesystemActor
    func saveSidecarMergingHistorySerialized(
        _ sidecar: MetadataSidecar,
        for imageURL: URL,
        in folderURL: URL,
        beforeRevisionCheck: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> MetadataSidecar {
        try requireIncomingOwner(sidecar, imageURL: imageURL)
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            for attempt in 0..<4 {
                let sourceTokens = try self.contentTokens(for: imageURL, in: folderURL)
                let current = try self.loadOwnedSidecarForMutation(for: imageURL, in: folderURL)
                let merged = Self.mergingHistory(sidecar, onto: current)

                beforeRevisionCheck(attempt)
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

    /// A replay is an immutable editorial mutation, not permission to replace a whole record.
    /// Keep its receipt with the queued request across retries, including after a partial commit.
    @MetadataSidecarFilesystemActor
    func replayHistoryAndMirrorXMP(
        _ request: MetadataSidecarReplayRequest,
        beforeJSONCommit: @escaping @Sendable () throws -> Void = {},
        afterJSONCommit: @escaping @Sendable () throws -> Void = {},
        beforeXMPCommit: @escaping @Sendable () throws -> Void = {}
    ) async -> MetadataSidecarPersistenceResult {
        guard !Task.isCancelled else {
            return .init(installedSidecar: nil, wroteXMPSidecar: false, wasCancelled: true, failure: nil)
        }
        return await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: request.imageURL)) { @MetadataSidecarFilesystemActor in
            var installed: MetadataSidecar?
            var committed = false
            let xmpReceipt = MetadataSidecarXMPCommitReceipt()
            var stage = MetadataSidecarPersistenceResult.FailureStage.metadataSidecar
            do {
                try self.requireIncomingOwner(request.sidecar, imageURL: request.imageURL)
                let tokens = try self.contentTokens(for: request.imageURL, in: request.folderURL)
                let current = try self.loadOwnedSidecarForMutation(for: request.imageURL, in: request.folderURL)
                let merged = try Self.replaying(request, onto: current)
                try beforeJSONCommit()
                guard try self.contentTokens(for: request.imageURL, in: request.folderURL) == tokens else {
                    throw self.ownershipChanged(request.imageURL)
                }
                if let current, Self.samePersistedRecord(current, merged) {
                    installed = current
                    request.receipt.markCommitted()
                } else {
                    try self.saveSidecar(merged, for: request.imageURL, in: request.folderURL)
                    committed = true
                    request.receipt.markCommitted()
                    try afterJSONCommit()
                    guard let readBack = self.loadSidecar(for: request.imageURL, in: request.folderURL),
                          Self.samePersistedRecord(readBack, merged) else { throw CocoaError(.fileReadCorruptFile) }
                    installed = readBack
                }
                let authoritativeTokens = try self.contentTokens(for: request.imageURL, in: request.folderURL)
                let xmp = XMPSidecarService()
                let xmpData = try self.xmpBytes(for: request.imageURL)
                stage = .xmpSidecar
                try beforeXMPCommit()
                guard try self.contentTokens(for: request.imageURL, in: request.folderURL) == authoritativeTokens else {
                    throw self.ownershipChanged(request.imageURL)
                }
                _ = try await xmp.writeMetadataInHeldTransaction(merged.metadata,
                    for: request.imageURL, expectedSnapshot: .init(data: xmpData),
                    onlyIfExisting: false, replaceDevelopSettings: false, replaceOrientation: false,
                    onInstalled: { xmpReceipt.record($0) })
                return .init(installedSidecar: installed, wroteXMPSidecar: true, wasCancelled: false, failure: nil,
                    writtenXMPMetadata: self.metadataFromXMPReceipt(xmpReceipt, imageURL: request.imageURL))
            } catch {
                return .init(installedSidecar: installed, wroteXMPSidecar: xmpReceipt.snapshot != nil,
                    wasCancelled: error is CancellationError,
                    failure: error is CancellationError ? nil : .init(stage: stage, message: error.localizedDescription),
                    committedButUnverifiedSidecarURL: committed && installed == nil
                        ? self.sidecarFileURL(for: request.imageURL, in: request.folderURL) : nil)
            }
        }
    }

    nonisolated struct WriteCompletionSnapshot: Sendable {
        let imageURL: URL
        let folderURL: URL
        fileprivate let tokens: [Data?]
        fileprivate let xmpData: Data?
    }

    /// Capture before an embedded write or explicit XMP/technical save. Nil explicitly expects
    /// absence; it does not authorize adopting an independently created draft.
    @MetadataSidecarFilesystemActor
    func captureWriteCompletionSnapshot(
        for imageURL: URL, in folderURL: URL, expectedSidecar: MetadataSidecar?,
        expectedTechnicalMetadata: IPTCMetadata?
    ) async throws -> WriteCompletionSnapshot {
        try Task.checkCancellation()
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            let tokens = try self.contentTokens(for: imageURL, in: folderURL)
            let current = try self.loadOwnedSidecarForMutation(for: imageURL, in: folderURL)
            guard Self.sameOptionalRecord(current, expectedSidecar) else { throw self.ownershipChanged(imageURL) }
            let xmpData = try self.xmpBytes(for: imageURL)
            let technical = xmpData.flatMap { XMPSidecarService().loadSidecar(fromData: $0,
                imageAspect: { ImagePixelAspect.aspect(at: imageURL) }) }
            guard xmpData == nil || technical != nil,
                  technical?.cameraRaw == expectedTechnicalMetadata?.cameraRaw,
                  technical?.exifOrientation == expectedTechnicalMetadata?.exifOrientation else {
                throw DescriptiveMetadataWriteError.staleXMPSidecar(XMPSidecarService().sidecarURL(for: imageURL))
            }
            return WriteCompletionSnapshot(imageURL: imageURL, folderURL: folderURL,
                tokens: tokens, xmpData: xmpData)
        }
    }

    /// Complete only the captured revision. A failed XMP write leaves the pending JSON untouched;
    /// a later JSON failure reports the committed XMP separately. No rollback of an embedded write
    /// that preceded this call is implied by a conflict.
    @MetadataSidecarFilesystemActor
    func completeSidecarAndMirrorXMP(
        _ sidecar: MetadataSidecar,
        snapshot: WriteCompletionSnapshot,
        mirrorOnlyIfExisting: Bool = false,
        replaceDevelopSettings: Bool = false,
        replaceOrientation: Bool = false,
        beforeXMPCommit: @escaping @Sendable () throws -> Void = {},
        beforeJSONCommit: @escaping @Sendable () throws -> Void = {},
        afterJSONCommit: @escaping @Sendable () throws -> Void = {}
    ) async -> MetadataSidecarPersistenceResult {
        guard !Task.isCancelled else {
            return .init(installedSidecar: nil, wroteXMPSidecar: false, wasCancelled: true, failure: nil)
        }
        return await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: snapshot.imageURL)) { @MetadataSidecarFilesystemActor in
            var installed: MetadataSidecar?
            var committed = false
            var wroteXMP = false
            var skippedXMP = false
            let xmpReceipt = MetadataSidecarXMPCommitReceipt()
            var stage = MetadataSidecarPersistenceResult.FailureStage.metadataSidecar
            do {
                try self.requireIncomingOwner(sidecar, imageURL: snapshot.imageURL)
                guard try self.contentTokens(for: snapshot.imageURL, in: snapshot.folderURL) == snapshot.tokens,
                      try self.xmpBytes(for: snapshot.imageURL) == snapshot.xmpData else {
                    throw self.ownershipChanged(snapshot.imageURL)
                }
                stage = .xmpSidecar
                try beforeXMPCommit()
                guard try self.contentTokens(for: snapshot.imageURL, in: snapshot.folderURL) == snapshot.tokens else {
                    throw self.ownershipChanged(snapshot.imageURL)
                }
                wroteXMP = try await XMPSidecarService().writeMetadataInHeldTransaction(sidecar.metadata,
                    for: snapshot.imageURL, expectedSnapshot: .init(data: snapshot.xmpData),
                    onlyIfExisting: mirrorOnlyIfExisting, replaceDevelopSettings: replaceDevelopSettings,
                    replaceOrientation: replaceOrientation, onInstalled: { xmpReceipt.record($0) })
                skippedXMP = !wroteXMP
                stage = .metadataSidecar
                try beforeJSONCommit()
                let committedXMP = xmpReceipt.snapshot ?? XMPSidecarWriteSnapshot(data: snapshot.xmpData)
                guard try self.contentTokens(for: snapshot.imageURL, in: snapshot.folderURL) == snapshot.tokens,
                      try self.xmpBytes(for: snapshot.imageURL) == committedXMP.data else {
                    throw self.ownershipChanged(snapshot.imageURL)
                }
                try self.saveSidecar(sidecar, for: snapshot.imageURL, in: snapshot.folderURL)
                committed = true
                try afterJSONCommit()
                guard let readBack = self.loadSidecar(for: snapshot.imageURL, in: snapshot.folderURL),
                      Self.samePersistedRecord(readBack, sidecar) else { throw CocoaError(.fileReadCorruptFile) }
                installed = readBack
                return .init(installedSidecar: installed, wroteXMPSidecar: wroteXMP,
                    wasCancelled: false, failure: nil, skippedXMPSidecar: skippedXMP,
                    writtenXMPMetadata: self.metadataFromXMPReceipt(xmpReceipt, imageURL: snapshot.imageURL))
            } catch {
                return .init(installedSidecar: installed, wroteXMPSidecar: wroteXMP || xmpReceipt.snapshot != nil,
                    wasCancelled: error is CancellationError,
                    failure: error is CancellationError ? nil : .init(stage: stage, message: error.localizedDescription),
                    committedButUnverifiedSidecarURL: committed && installed == nil
                        ? self.sidecarFileURL(for: snapshot.imageURL, in: snapshot.folderURL) : nil,
                    skippedXMPSidecar: skippedXMP)
            }
        }
    }

    private nonisolated func metadataFromXMPReceipt(_ receipt: MetadataSidecarXMPCommitReceipt,
                                                   imageURL: URL) -> IPTCMetadata? {
        receipt.snapshot?.data.flatMap { XMPSidecarService().loadSidecar(fromData: $0,
            imageAspect: { ImagePixelAspect.aspect(at: imageURL) }) }
    }

    private nonisolated func xmpBytes(for imageURL: URL) throws -> Data? {
        let url = XMPSidecarService().sidecarURL(for: imageURL)
        guard try entryExists(url) else { return nil }
        try requireRegularFile(url)
        return try Data(contentsOf: url)
    }

    private nonisolated static func sameOptionalRecord(_ lhs: MetadataSidecar?, _ rhs: MetadataSidecar?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return samePersistedRecord(lhs, rhs)
        default: return false
        }
    }

    private nonisolated static func replayConflict() -> CocoaError {
        CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
            "This queued caption conflicts with newer saved metadata. Newer metadata was preserved, and the queued edit remains retained. Retrying or reloading alone will not resolve this conflict."])
    }

    private nonisolated static func eventPayload(_ entry: MetadataHistoryEntry) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(entry)
    }

    private nonisolated static func persistedMetadataEqual(_ lhs: IPTCMetadata, _ rhs: IPTCMetadata) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }

    private nonisolated static func replaying(
        _ request: MetadataSidecarReplayRequest, onto current: MetadataSidecar?
    ) throws -> MetadataSidecar {
        guard request.sidecar.pendingChanges, let witness = request.changes.last,
              request.changes.allSatisfy({ $0.persistentEventID != nil }),
              Set(request.changes.map(historyStorageIdentity)).count == request.changes.count else {
            throw replayConflict()
        }
        let known = current?.history ?? []
        for event in request.changes + request.baselineHistory {
            if let matching = known.first(where: { historyStorageIdentity($0) == historyStorageIdentity(event) }),
               eventPayload(matching) != eventPayload(event) { throw replayConflict() }
        }
        if known.contains(where: { eventPayload($0) == eventPayload(witness) }), let current {
            return current
        }
        guard !request.receipt.hasCommitted,
              !request.changes.contains(where: { event in known.contains { eventPayload($0) == eventPayload(event) } }) else {
            throw replayConflict()
        }
        if let current {
            if let anchor = request.baselineHistory.last {
                guard known.contains(where: { eventPayload($0) == eventPayload(anchor) }) else { throw replayConflict() }
            } else {
                guard current.history.isEmpty, persistedMetadataEqual(current.metadata, request.baselineMetadata) else {
                    throw replayConflict()
                }
            }
        } else if request.baselineRecordExisted || !request.baselineHistory.isEmpty {
            throw replayConflict()
        }
        // An older timestamp could later sort ahead of its own anchor and be trimmed while the
        // anchor survives. Refuse that ambiguous chronology instead of resurrecting an old edit.
        if let latestBaseline = request.baselineHistory.map(\.timestamp).max(),
           request.changes.contains(where: { $0.timestamp < latestBaseline }) { throw replayConflict() }
        var intended = request.baselineMetadata
        for event in request.changes {
            if !event.apply(to: &intended), !applyNonReplayableChange(event, from: request.sidecar.metadata, to: &intended) {
                throw replayConflict()
            }
        }
        guard persistedMetadataEqual(intended, request.sidecar.metadata) else { throw replayConflict() }
        let requestedFields = Set(request.changes.map(\.fieldName))
        let actualChanges = MetadataHistoryEntry.changes(from: request.baselineMetadata,
            to: request.sidecar.metadata, timestamp: request.sidecar.lastModified)
        guard Set(actualChanges.map(\.fieldName)) == requestedFields else { throw replayConflict() }
        if let current {
            let independentFields = Set(MetadataHistoryEntry.changes(from: request.baselineMetadata,
                to: current.metadata, timestamp: current.lastModified).map(\.fieldName))
            guard requestedFields.isDisjoint(with: independentFields) else { throw replayConflict() }
        }
        var metadata = current?.metadata ?? request.baselineMetadata
        for event in request.changes {
            if !event.apply(to: &metadata), !applyNonReplayableChange(event, from: request.sidecar.metadata, to: &metadata) {
                throw replayConflict()
            }
        }
        var history = known + request.changes
        history.trimToHistoryLimit()
        return MetadataSidecar(sourceFile: request.sidecar.sourceFile,
            lastModified: request.sidecar.lastModified, pendingChanges: true, metadata: metadata,
            imageMetadataSnapshot: current == nil ? request.sidecar.imageMetadataSnapshot : current?.imageMetadataSnapshot,
            history: history)
    }

    /// Compare-and-replace an explicitly restored editorial draft, then mirror that exact record
    /// to XMP under the same photo lock. Never replay later history deltas onto the restore target.
    /// A committed JSON record is returned even if cancellation or XMP failure follows it.
    @MetadataSidecarFilesystemActor
    func restoreSidecarAndMirrorXMP(
        _ request: MetadataSidecarRestoreRequest,
        beforeJSONCommit: @escaping @Sendable () throws -> Void = {},
        afterJSONCommit: @escaping @Sendable () throws -> Void = {},
        beforeXMPCommit: @escaping @Sendable () throws -> Void = {}
    ) async -> MetadataSidecarPersistenceResult {
        guard !Task.isCancelled else {
            return MetadataSidecarPersistenceResult(installedSidecar: nil, wroteXMPSidecar: false,
                wasCancelled: true, failure: nil)
        }
        return await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: request.imageURL)) { @MetadataSidecarFilesystemActor in
            var installed: MetadataSidecar?
            var didCommitJSON = false
            var stage = MetadataSidecarPersistenceResult.FailureStage.metadataSidecar
            do {
                try Task.checkCancellation()
                let filename = request.imageURL.lastPathComponent
                guard request.expectedSidecar.sourceFile == filename,
                      request.sidecar.sourceFile == filename,
                      request.sidecar.pendingChanges,
                      request.sidecar.imageMetadataSnapshot == request.expectedSidecar.imageMetadataSnapshot else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                let tokens = try self.contentTokens(for: request.imageURL, in: request.folderURL)
                let records = try self.ownedRecords(for: request.imageURL, in: request.folderURL)
                guard let current = records.first,
                      Self.samePersistedRecord(current, request.expectedSidecar) else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
                        "The metadata draft changed before restore. Reload the photo and choose the history point again."])
                }
                let xmpService = XMPSidecarService()
                let xmpURL = xmpService.sidecarURL(for: request.imageURL)
                let xmpData = FileManager.default.fileExists(atPath: xmpURL.path)
                    ? try Data(contentsOf: xmpURL) : nil
                let xmpMetadata = xmpData.flatMap {
                    xmpService.loadSidecar(fromData: $0, imageAspect: { ImagePixelAspect.aspect(at: request.imageURL) })
                }
                guard (xmpData == nil || xmpMetadata != nil), xmpMetadata == request.expectedXMPMetadata else {
                    throw DescriptiveMetadataWriteError.staleXMPSidecar(xmpURL)
                }
                try beforeJSONCommit()
                try Task.checkCancellation()
                guard try self.contentTokens(for: request.imageURL, in: request.folderURL) == tokens else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
                        "The metadata draft changed while restore was prepared. Reload the photo before retrying."])
                }
                if Self.samePersistedRecord(current, request.sidecar) {
                    installed = current
                } else {
                    try self.saveSidecar(request.sidecar, for: request.imageURL, in: request.folderURL)
                    didCommitJSON = true
                    try afterJSONCommit()
                    let readBack = self.loadSidecar(for: request.imageURL, in: request.folderURL)
                    guard let readBack, Self.samePersistedRecord(readBack, request.sidecar) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    installed = readBack
                }
                stage = .xmpSidecar
                try Task.checkCancellation()
                try beforeXMPCommit()
                try await xmpService.restoreDescriptiveMetadataInHeldTransaction(
                    request.sidecar.metadata, for: request.imageURL,
                    expectedSnapshot: XMPSidecarWriteSnapshot(data: xmpData)
                )
                return MetadataSidecarPersistenceResult(installedSidecar: installed,
                    wroteXMPSidecar: true, wasCancelled: false, failure: nil)
            } catch is CancellationError {
                return MetadataSidecarPersistenceResult(installedSidecar: installed,
                    wroteXMPSidecar: false, wasCancelled: true, failure: nil,
                    committedButUnverifiedSidecarURL: didCommitJSON && installed == nil
                        ? self.sidecarFileURL(for: request.imageURL, in: request.folderURL) : nil)
            } catch {
                return MetadataSidecarPersistenceResult(installedSidecar: installed,
                    wroteXMPSidecar: false, wasCancelled: false,
                    failure: .init(stage: stage, message: error.localizedDescription),
                    committedButUnverifiedSidecarURL: didCommitJSON && installed == nil
                        ? self.sidecarFileURL(for: request.imageURL, in: request.folderURL) : nil)
            }
        }
    }

    /// Serializes an intentional history replacement. The latest metadata record remains
    /// authoritative so clearing history cannot erase a face/caption mutation that reached the
    /// shared boundary first.
    @MetadataSidecarFilesystemActor
    func saveSidecarReplacingHistorySerialized(
        _ sidecar: MetadataSidecar,
        for imageURL: URL,
        in folderURL: URL,
        beforeRevisionCheck: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> MetadataSidecar {
        try requireIncomingOwner(sidecar, imageURL: imageURL)
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            for attempt in 0..<4 {
                let sourceTokens = try self.contentTokens(for: imageURL, in: folderURL)
                let current = try self.loadOwnedSidecarForMutation(for: imageURL, in: folderURL)
                var replacement = current ?? sidecar
                replacement.history = sidecar.history

                beforeRevisionCheck(attempt)
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

    @MetadataSidecarFilesystemActor
    func captureWriteCleanupSnapshot(
        for imageURL: URL,
        in folderURL: URL,
        expected: MetadataSidecar? = nil,
        editorRecord: MetadataSidecar? = nil,
        requiresEditorMatch: Bool = false,
        beforeRead: @escaping @Sendable () throws -> Void = {}
    ) async throws -> WriteCleanupSnapshot {
        try Task.checkCancellation()
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            try beforeRead()
            let tokens = try self.contentTokens(for: imageURL, in: folderURL)
            let records = try self.ownedRecords(for: imageURL, in: folderURL)
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
    @MetadataSidecarFilesystemActor
    func deleteSidecarAfterWriteSerialized(
        _ snapshot: WriteCleanupSnapshot,
        beforeRevisionCheck: @escaping @Sendable () throws -> Void = {}
    ) async throws -> Bool {
        try Task.checkCancellation()
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: snapshot.imageURL)) { @MetadataSidecarFilesystemActor in
            try beforeRevisionCheck()
            guard snapshot.matchesEditor,
                  (try? self.contentTokens(for: snapshot.imageURL, in: snapshot.folderURL)) == snapshot.tokens else {
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
    @MetadataSidecarFilesystemActor
    func deleteUnneededSidecarSerialized(
        for imageURL: URL,
        in folderURL: URL,
        beforeRevisionCheck: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> Bool {
        try Task.checkCancellation()
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            for attempt in 0..<4 {
                guard let tokens = try? self.contentTokens(for: imageURL, in: folderURL) else { return false }
                guard tokens.contains(where: { $0 != nil }) else { return false }
                guard let records = try? self.ownedRecords(for: imageURL, in: folderURL), !records.isEmpty else { return false }
                for record in records {
                    guard !record.pendingChanges, record.history.isEmpty else { return false }
                }
                beforeRevisionCheck(attempt)
                await Task.yield()
                guard (try? self.contentTokens(for: imageURL, in: folderURL)) == tokens else {
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
    @MetadataSidecarFilesystemActor
    func deleteSidecarSerialized(
        for imageURL: URL,
        in folderURL: URL,
        beforeDelete: @escaping @Sendable () throws -> Void = {}
    ) async throws {
        try Task.checkCancellation()
        try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            try beforeDelete()
            try self.deleteSidecar(for: imageURL, in: folderURL)
        }
    }

    nonisolated func deleteSidecar(for imageURL: URL, in folderURL: URL) throws {
        let snapshots = try carrierSnapshots(for: imageURL, in: folderURL)
        let owned = snapshots.filter(\.isOwned)
        _ = try decodeOwnedRecords(owned)
        // Complete validation precedes the first removal; never discard an unrelated legacy
        // document or an unreadable/newer owned record while clearing this photo's draft.
        guard try snapshots == carrierSnapshots(for: imageURL, in: folderURL) else { throw ownershipChanged(imageURL) }
        for carrier in owned {
            try requireRegularFile(carrier.url)
            guard try Data(contentsOf: carrier.url) == carrier.data else { throw ownershipChanged(carrier.url) }
            try FileManager.default.removeItem(at: carrier.url)
        }
    }

    @MetadataSidecarFilesystemActor
    func deleteAllSidecarsSerialized(
        in folderURL: URL,
        beforeDelete: @escaping @Sendable () throws -> Void = {}
    ) async throws {
        try Task.checkCancellation()
        let folderKey = folderURL.resolvingSymlinksInPath().path.lowercased()
        try await MetadataIOCoordinator.shared.withFolderLock(folderKey) { @MetadataSidecarFilesystemActor in
            try beforeDelete()
            try self.deleteAllSidecars(in: folderURL)
        }
    }

    nonisolated func deleteAllSidecars(in folderURL: URL) throws {
        let dir = sidecarDirectory(for: folderURL)
        if try entryExists(dir) {
            try requireMetadataDirectory(in: folderURL)
            try FileManager.default.removeItem(at: dir)
        }
    }

    func renameSidecar(from oldImageURL: URL, to newImageURL: URL, in folderURL: URL) throws {
        guard oldImageURL.standardizedFileURL != newImageURL.standardizedFileURL else { return }
        let snapshots = try carrierSnapshots(for: oldImageURL, in: folderURL)
        let owned = snapshots.filter(\.isOwned)
        guard !owned.isEmpty else { return }
        try copySidecarsPreservingOpaqueFields(for: oldImageURL, to: newImageURL, in: folderURL)
        guard try snapshots == carrierSnapshots(for: oldImageURL, in: folderURL) else { throw ownershipChanged(oldImageURL) }
        for carrier in owned {
            try requireRegularFile(carrier.url)
            guard try Data(contentsOf: carrier.url) == carrier.data else { throw ownershipChanged(carrier.url) }
            try FileManager.default.removeItem(at: carrier.url)
        }
    }

    nonisolated func moveSidecar(for imageURL: URL, from sourceFolderURL: URL, to destinationFolderURL: URL) throws {
        let fm = FileManager.default
        let sourceURLs = try ownedRelocationSources(for: imageURL, in: sourceFolderURL)
        guard !sourceURLs.isEmpty else { return }
        let legacyURL = legacySidecarFileURL(for: imageURL, in: sourceFolderURL)
        let keepLegacy = try PhotoSidecarOwnership.hasSurvivingStemSibling(of: imageURL, in: sourceFolderURL)

        let destinationDirectory = sidecarDirectory(for: destinationFolderURL)
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationURL = sidecarFileURL(for: imageURL, in: destinationFolderURL)

        for candidate in relocationDestinationURLs(for: imageURL, in: destinationFolderURL)
            where fm.fileExists(atPath: candidate.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: candidate.path])
        }
        if let first = sourceURLs.first {
            if first == legacyURL && keepLegacy {
                try PhotoSidecarOwnership.copyPreservingSource(from: first, to: destinationURL)
            } else {
                try fm.moveItem(at: first, to: destinationURL)
            }
        }
        for extra in sourceURLs.dropFirst() {
            if extra == legacyURL && keepLegacy { continue }
            do {
                try fm.removeItem(at: extra)
            } catch {
                sidecarLogger.warning("Failed to remove extra sidecar \(extra.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Reserve both supported carrier names even when the source has no sidecar, so a
    /// moved photo cannot adopt unrelated metadata already at its destination.
    nonisolated func relocationDestinationURLs(for imageURL: URL, in folderURL: URL) -> [URL] {
        sidecarCandidateURLs(for: imageURL, in: folderURL)
    }

    private nonisolated func ownedRelocationSources(for imageURL: URL, in folderURL: URL) throws -> [URL] {
        let legacy = legacySidecarFileURL(for: imageURL, in: folderURL)
        return try sidecarCandidateURLs(for: imageURL, in: folderURL).filter { candidate in
            guard FileManager.default.fileExists(atPath: candidate.path) else { return false }
            if candidate != legacy { return true }
            return try PhotoSidecarOwnership.legacyRecordBelongsToImage(
                at: candidate, imageURL: imageURL
            )
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
        let sourceURLs = try ownedRelocationSources(for: sourceImageURL, in: sourceFolderURL)
        guard let sourceURL = sourceURLs.first else { return }
        let legacyURL = legacySidecarFileURL(for: sourceImageURL, in: sourceFolderURL)
        let keepLegacy = try PhotoSidecarOwnership.hasSurvivingStemSibling(of: sourceImageURL, in: sourceFolderURL)

        let sourceData = try Data(contentsOf: sourceURL)
        let destinationData = Self.updatingSourceFile(
            in: sourceData,
            to: destinationImageURL.lastPathComponent,
            sourceURL: sourceURL
        )
        let destinationDirectory = sidecarDirectory(for: destinationFolderURL)
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationURL = sidecarFileURL(for: destinationImageURL, in: destinationFolderURL)
        for candidate in relocationDestinationURLs(for: destinationImageURL, in: destinationFolderURL)
            where fm.fileExists(atPath: candidate.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: candidate.path])
        }
        // Install an already complete file without replacing a destination that arrived
        // after preflight. Atomic Data writes alone are allowed to overwrite that file.
        let stagingURL = destinationDirectory.appendingPathComponent(".relocate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stagingURL) }
        try destinationData.write(to: stagingURL, options: .atomic)
        try fm.moveItem(at: stagingURL, to: destinationURL)

        // The destination is safely on disk before any source artifact is removed.
        // A legacy duplicate may coexist with the current sidecar, so clean up both.
        for oldURL in sourceURLs {
            if oldURL == legacyURL && keepLegacy { continue }
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
        preserveUnknownHistoryFields(from: existing, in: &encoded)

        return (try? JSONSerialization.data(
            withJSONObject: encoded,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? encodedData
    }

    private nonisolated func contentTokens(for imageURL: URL, in folderURL: URL) throws -> [Data?] {
        let snapshots = try carrierSnapshots(for: imageURL, in: folderURL)
        return sidecarCandidateURLs(for: imageURL, in: folderURL).map { url in
            snapshots.first(where: { $0.url == url })?.data
        }
    }

    private nonisolated static func mergingHistory(
        _ incoming: MetadataSidecar,
        onto current: MetadataSidecar?
    ) -> MetadataSidecar {
        guard let current else { return incoming }

        var known = Set(current.history.map(Self.historyStorageIdentity))
        let newEntries = Self.stableHistoryOrder(incoming.history.filter {
            known.insert(Self.historyStorageIdentity($0)).inserted
        })

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

        // Legacy records can contain distinct same-second events with the same derived id.
        // Preserve their order and contents; only an actual persistent event identity (or an
        // identical legacy payload) makes an incoming replay redundant.
        var history = Self.stableHistoryOrder(current.history + newEntries)
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

    private nonisolated static func historyStorageIdentity(_ entry: MetadataHistoryEntry) -> String {
        if let id = entry.persistentEventID { return "event:\(id)" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return "legacy:" + ((try? encoder.encode(entry))?.base64EncodedString() ?? entry.id)
    }

    private nonisolated static func stableHistoryOrder(_ entries: [MetadataHistoryEntry]) -> [MetadataHistoryEntry] {
        entries.enumerated().sorted {
            if $0.element.timestamp != $1.element.timestamp { return $0.element.timestamp < $1.element.timestamp }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    private nonisolated static func preserveUnknownHistoryFields(
        from existing: [String: Any], in encoded: inout [String: Any]
    ) {
        guard let oldEvents = existing["history"] as? [[String: Any]],
              var newEvents = encoded["history"] as? [[String: Any]] else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func identity(_ graph: [String: Any]) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: graph),
                  let entry = try? decoder.decode(MetadataHistoryEntry.self, from: data) else { return nil }
            return historyStorageIdentity(entry)
        }
        var previous: [String: [[String: Any]]] = [:]
        for graph in oldEvents {
            guard let key = identity(graph) else { continue }
            previous[key, default: []].append(graph)
        }
        let known = Set(["eventID", "timestamp", "fieldID", "fieldName", "oldValue", "newValue",
                         "oldValueSummary", "newValueSummary", "valueStorage"])
        for index in newEvents.indices {
            guard let key = identity(newEvents[index]), var candidates = previous[key], !candidates.isEmpty else { continue }
            let old = candidates.removeFirst()
            previous[key] = candidates
            for (field, value) in old where !known.contains(field) { newEvents[index][field] = value }
        }
        encoded["history"] = newEvents
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
private nonisolated final class MetadataSidecarXMPCommitReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var value: XMPSidecarWriteSnapshot?
    var snapshot: XMPSidecarWriteSnapshot? { lock.withLock { value } }
    func record(_ snapshot: XMPSidecarWriteSnapshot) { lock.withLock { value = snapshot } }
}

nonisolated final class MetadataSidecarReplayReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var committed = false
    var hasCommitted: Bool { lock.withLock { committed } }
    func markCommitted() { lock.withLock { committed = true } }
}

nonisolated struct MetadataSidecarReplayRequest: Sendable {
    let sidecar: MetadataSidecar
    let baselineMetadata: IPTCMetadata
    let baselineHistory: [MetadataHistoryEntry]
    let baselineRecordExisted: Bool
    let changes: [MetadataHistoryEntry]
    let imageURL: URL
    let folderURL: URL
    let receipt: MetadataSidecarReplayReceipt

    init(sidecar: MetadataSidecar, baselineMetadata: IPTCMetadata,
         baselineHistory: [MetadataHistoryEntry], baselineRecordExisted: Bool, changes: [MetadataHistoryEntry],
         imageURL: URL, folderURL: URL, receipt: MetadataSidecarReplayReceipt = .init()) {
        self.sidecar = sidecar
        self.baselineMetadata = baselineMetadata
        self.baselineHistory = baselineHistory
        self.baselineRecordExisted = baselineRecordExisted
        self.changes = changes
        self.imageURL = imageURL
        self.folderURL = folderURL
        self.receipt = receipt
    }
}

nonisolated struct MetadataSidecarRestoreRequest: Sendable {
    let sidecar: MetadataSidecar
    let expectedSidecar: MetadataSidecar
    let expectedXMPMetadata: IPTCMetadata?
    let imageURL: URL
    let folderURL: URL
}

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
    let committedButUnverifiedSidecarURL: URL?
    let skippedXMPSidecar: Bool
    let writtenXMPMetadata: IPTCMetadata?

    init(installedSidecar: MetadataSidecar?, wroteXMPSidecar: Bool, wasCancelled: Bool,
         failure: Failure?, committedButUnverifiedSidecarURL: URL? = nil, skippedXMPSidecar: Bool = false,
         writtenXMPMetadata: IPTCMetadata? = nil) {
        self.installedSidecar = installedSidecar
        self.wroteXMPSidecar = wroteXMPSidecar
        self.wasCancelled = wasCancelled
        self.failure = failure
        self.committedButUnverifiedSidecarURL = committedButUnverifiedSidecarURL
        self.skippedXMPSidecar = skippedXMPSidecar
        self.writtenXMPMetadata = writtenXMPMetadata
    }

    var completed: Bool {
        installedSidecar != nil && (wroteXMPSidecar || skippedXMPSidecar) && !wasCancelled && failure == nil
    }
}

/// Shared worker for bulk reads and admitted JSON/XMP transactions. The per-photo coordinator
/// retains ownership across suspension/revision retries; its admitted task explicitly hops here
/// before touching storage. A custom executor on the orchestrator alone would leave nonisolated
/// async helpers running their blocking reads and writes on the cooperative pool.
@globalActor
actor MetadataSidecarFilesystemActor {
    static let shared = MetadataSidecarFilesystemActor()

    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.metadata-sidecar.filesystem", qos: .utility
    )
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }
}

/// Off-main orchestration for the metadata JSON + XMP transaction. Each artifact retains the
/// existing per-photo `MetadataIOCoordinator` serialization and atomic-install behavior. The
/// actor adds one async boundary for the view model and makes the only partial-commit point
/// observable: JSON history installed, then cancellation/XMP failure before the mirror commits.
actor MetadataSidecarPersistenceService {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        MetadataSidecarFilesystemActor.shared.filesystemQueue.asUnownedSerialExecutor()
    }

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
