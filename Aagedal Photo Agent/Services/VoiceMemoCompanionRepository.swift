import Foundation
import os

nonisolated struct VoiceMemoRenamePlanningRequest: Sendable {
    let requestID: UUID
    let folderURL: URL
    let items: [RenamePlanningItem]
}

nonisolated enum VoiceMemoRenamePlanningCompletion: Equatable, Sendable {
    case complete
    case cancelled(completedItemCount: Int)
    case failed(completedItemCount: Int, message: String)
}

/// Immutable evidence from one serialized voice-memo relationship scan. A cancelled or failed
/// prefix is diagnostic only; callers publish rename UI exclusively for `.complete` snapshots.
nonisolated struct VoiceMemoRenamePlanningSnapshot: Equatable, Sendable {
    let requestID: UUID
    let folderURL: URL
    let items: [RenamePlanningItem]
    let completion: VoiceMemoRenamePlanningCompletion
}

/// Keeps hidden relationship enumeration and record decoding away from MainActor. Repository
/// operations are synchronous and individually non-preemptible, so cancellation is checked on
/// both sides of every item and the exact completed prefix is returned as immutable evidence.
actor VoiceMemoRenamePlanningService {
    /// Run blocking Foundation calls on a retained Dispatch worker while preserving the
    /// caller's task locals, cancellation, and the actor's transaction ordering.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    typealias ArtifactPlanner = @Sendable (URL) throws -> [RenamePlanningAssociatedArtifact]

    static let shared = VoiceMemoRenamePlanningService()

    private let artifactPlanner: ArtifactPlanner
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "VoiceMemoRenamePlanning"
    )

    init(
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.voice-memo-rename-planning", qos: .utility
        ),
        artifactPlanner: @escaping ArtifactPlanner = {
            try VoiceMemoCompanionRepository().planningArtifacts(for: $0)
        }
    ) {
        self.filesystemQueue = filesystemQueue
        self.artifactPlanner = artifactPlanner
    }

    func plan(_ request: VoiceMemoRenamePlanningRequest) -> VoiceMemoRenamePlanningSnapshot {
        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval("Plan", id: signpostID)
        var completed: [RenamePlanningItem] = []
        completed.reserveCapacity(request.items.count)

        func snapshot(_ completion: VoiceMemoRenamePlanningCompletion) -> VoiceMemoRenamePlanningSnapshot {
            VoiceMemoRenamePlanningSnapshot(
                requestID: request.requestID,
                folderURL: request.folderURL,
                items: completed,
                completion: completion
            )
        }

        guard !Task.isCancelled else {
            signposter.endInterval("Plan", state, "cancelled=preflight")
            return snapshot(.cancelled(completedItemCount: 0))
        }

        do {
            for var item in request.items {
                guard !Task.isCancelled else {
                    signposter.endInterval("Plan", state, "cancelled=prefix count=\(completed.count)")
                    return snapshot(.cancelled(completedItemCount: completed.count))
                }
                item.associatedArtifacts = try artifactPlanner(item.sourceImageURL)
                guard !Task.isCancelled else {
                    signposter.endInterval("Plan", state, "cancelled=postread count=\(completed.count)")
                    return snapshot(.cancelled(completedItemCount: completed.count))
                }
                completed.append(item)
            }
            signposter.endInterval("Plan", state, "result=complete count=\(completed.count)")
            return snapshot(.complete)
        } catch {
            signposter.endInterval("Plan", state, "result=failed count=\(completed.count)")
            return snapshot(.failed(
                completedItemCount: completed.count,
                message: error.localizedDescription
            ))
        }
    }
}

nonisolated protocol VoiceMemoCompanionRecordIO: Sendable {
    func fileExists(at url: URL) -> Bool
    func read(from url: URL) throws -> Data
    func writeAtomically(_ data: Data, to url: URL) throws
    func remove(at url: URL) throws
}

nonisolated struct SystemVoiceMemoCompanionRecordIO: VoiceMemoCompanionRecordIO {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func remove(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

nonisolated struct VoiceMemoCompanionRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let profileIdentifier: String
    let imageFilename: String
    let memoFilename: String

    init(profileIdentifier: String, imageFilename: String, memoFilename: String) {
        self.schemaVersion = Self.currentSchemaVersion
        self.profileIdentifier = profileIdentifier
        self.imageFilename = imageFilename
        self.memoFilename = memoFilename
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, profileIdentifier, imageFilename, memoFilename
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw VoiceMemoCompanionRepository.RepositoryError.unsupportedSchema(version)
        }
        schemaVersion = version
        profileIdentifier = try container.decode(String.self, forKey: .profileIdentifier)
        imageFilename = try container.decode(String.self, forKey: .imageFilename)
        memoFilename = try container.decode(String.self, forKey: .memoFilename)
    }
}

/// Copy preparation stays in a private sibling directory. Only completed files are installed,
/// with no replacement, so rollback never removes a pre-existing destination or a source memo.
nonisolated struct VoiceMemoCompanionCopyIO: Sendable {
    var copy: @Sendable (URL, URL) throws -> Void
    var install: @Sendable (URL, URL) throws -> Void
    var remove: @Sendable (URL) throws -> Void

    static let system = Self(
        copy: { try FileManager.default.copyItem(at: $0, to: $1) },
        install: { try FileManager.default.moveItem(at: $0, to: $1) },
        remove: { try FileManager.default.removeItem(at: $0) }
    )
}

nonisolated struct VoiceMemoCompanionRepository: Sendable {
    private let recordIO: any VoiceMemoCompanionRecordIO
    private let copyIO: VoiceMemoCompanionCopyIO

    init(
        recordIO: any VoiceMemoCompanionRecordIO = SystemVoiceMemoCompanionRecordIO(),
        copyIO: VoiceMemoCompanionCopyIO = .system
    ) {
        self.recordIO = recordIO
        self.copyIO = copyIO
    }

    enum RepositoryError: Error, LocalizedError, Equatable, Sendable {
        case unsafeFilename(String)
        case mismatchedFolder
        case invalidRecord
        case unsupportedSchema(Int)
        case memoMissing(String)
        case ambiguousImportedDestination(String)
        case sharedMemoRequiresGroupAction(String)
        case importPersistenceRollbackFailed
        case copyDestinationExists(String)
        case copyRollbackFailed([String])
        case copySourceChanged

        var errorDescription: String? {
            switch self {
            case .unsafeFilename(let filename):
                return "The voice-memo relationship contains an unsafe filename: \(filename)"
            case .mismatchedFolder:
                return "A voice memo relationship must remain in the same folder as its photo."
            case .invalidRecord:
                return "The saved voice-memo relationship is invalid and was left untouched."
            case .unsupportedSchema(let version):
                return "Voice-memo relationship schema \(version) is newer than this app supports."
            case .memoMissing(let filename):
                return "The saved voice memo \(filename) is missing. Restore it before renaming the photo."
            case .ambiguousImportedDestination(let filename):
                return "The imported voice memo for \(filename) could not be identified unambiguously."
            case .sharedMemoRequiresGroupAction(let filename):
                return "The voice memo \(filename) is linked to multiple photos. Rename is blocked until shared voice-memo groups are supported."
            case .importPersistenceRollbackFailed:
                return "Voice-memo relationship persistence failed and could not be fully rolled back."
            case .copyDestinationExists(let filename):
                return "The destination already contains the photo or voice-memo companion \(filename)."
            case .copyRollbackFailed(let filenames):
                return "Photo and voice-memo copy failed. Remove the incomplete copies before retrying: \(filenames.joined(separator: ", "))."
            case .copySourceChanged:
                return "The photo, voice memo, or saved relationship changed during copying. Try again when the source is stable."
            }
        }
    }

    enum Lookup: Equatable, Sendable {
        case none
        case available(VoiceMemoAssociation)
        case missing(VoiceMemoCompanionRecord)
    }

    static let recordSuffix = ".voice-memo.json"

    func lookup(for imageURL: URL) throws -> Lookup {
        let recordURL = recordURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return .none }
        let record = try loadRecord(at: recordURL, expectedImageFilename: nil)
        let memoFilename = effectiveMemoFilename(
            for: record,
            currentImageFilename: imageURL.lastPathComponent
        )
        let memoURL = imageURL.deletingLastPathComponent().appendingPathComponent(memoFilename)
        guard FileManager.default.fileExists(atPath: memoURL.path) else {
            return .missing(VoiceMemoCompanionRecord(
                profileIdentifier: record.profileIdentifier,
                imageFilename: imageURL.lastPathComponent,
                memoFilename: memoFilename
            ))
        }
        return .available(VoiceMemoAssociation(
            profileIdentifier: record.profileIdentifier,
            imageURL: VoiceMemoAssociationService.canonicalURL(imageURL),
            memoURL: VoiceMemoAssociationService.canonicalURL(memoURL)
        ))
    }

    func save(_ association: VoiceMemoAssociation) throws {
        let imageURL = association.imageURL.standardizedFileURL
        let memoURL = association.memoURL.standardizedFileURL
        guard imageURL.deletingLastPathComponent() == memoURL.deletingLastPathComponent() else {
            throw RepositoryError.mismatchedFolder
        }
        try Self.validateFilename(imageURL.lastPathComponent)
        try Self.validateFilename(memoURL.lastPathComponent)
        guard FileManager.default.fileExists(atPath: imageURL.path),
              FileManager.default.fileExists(atPath: memoURL.path) else {
            throw RepositoryError.memoMissing(memoURL.lastPathComponent)
        }

        let record = VoiceMemoCompanionRecord(
            profileIdentifier: association.profileIdentifier,
            imageFilename: imageURL.lastPathComponent,
            memoFilename: memoURL.lastPathComponent
        )
        try write(record, to: recordURL(for: imageURL))
    }

    /// Writes durable relationships only after both copy jobs completed successfully on the same
    /// destination leg. All deterministic validation completes before the first record is written,
    /// and an I/O failure rolls earlier records back to their exact prior bytes.
    @discardableResult
    func saveImportedAssociations(
        _ associations: [VoiceMemoAssociation],
        results: [ImportCopyService.CopyResult]
    ) throws -> Int {
        let successful = results.flatMap { result in
            successfulDestinations(for: result).map {
                (VoiceMemoAssociationService.canonicalURL(result.source), $0.standardizedFileURL)
            }
        }
        let destinationsBySource = Dictionary(grouping: successful, by: \.0).mapValues { $0.map(\.1) }
        var prepared: [(record: VoiceMemoCompanionRecord, url: URL)] = []

        for association in associations {
            let imageSource = VoiceMemoAssociationService.canonicalURL(association.imageURL)
            guard let imageDestinations = destinationsBySource[imageSource] else { continue }
            let memoSource = VoiceMemoAssociationService.canonicalURL(association.memoURL)
            let memoDestinations = destinationsBySource[memoSource] ?? []

            for imageDestination in imageDestinations {
                let imageStem = imageDestination.deletingPathExtension().lastPathComponent
                let candidates = memoDestinations.filter {
                    $0.deletingLastPathComponent() == imageDestination.deletingLastPathComponent()
                        && $0.deletingPathExtension().lastPathComponent == imageStem
                }
                guard candidates.count == 1, let memoDestination = candidates.first else {
                    throw RepositoryError.ambiguousImportedDestination(imageDestination.lastPathComponent)
                }
                try Self.validateFilename(imageDestination.lastPathComponent)
                try Self.validateFilename(memoDestination.lastPathComponent)
                guard FileManager.default.fileExists(atPath: imageDestination.path),
                      FileManager.default.fileExists(atPath: memoDestination.path) else {
                    throw RepositoryError.memoMissing(memoDestination.lastPathComponent)
                }
                prepared.append((
                    VoiceMemoCompanionRecord(
                        profileIdentifier: association.profileIdentifier,
                        imageFilename: imageDestination.lastPathComponent,
                        memoFilename: memoDestination.lastPathComponent
                    ),
                    recordURL(for: imageDestination)
                ))
            }
        }

        let grouped = Dictionary(grouping: prepared, by: { $0.url.standardizedFileURL })
        let unique = try grouped.keys.sorted(by: { $0.path < $1.path }).map { url in
            let records = grouped[url] ?? []
            guard let first = records.first, records.allSatisfy({ $0.record == first.record }) else {
                throw RepositoryError.ambiguousImportedDestination(url.lastPathComponent)
            }
            return first
        }
        try writeBatchWithRollback(unique)
        return unique.count
    }

    func planningArtifacts(for imageURL: URL) throws -> [RenamePlanningAssociatedArtifact] {
        switch try lookup(for: imageURL) {
        case .none:
            return []
        case .missing(let record):
            throw RepositoryError.memoMissing(record.memoFilename)
        case .available(let association):
            let referenceCount = try memoReferenceCount(
                to: association.memoURL,
                in: imageURL.deletingLastPathComponent()
            )
            guard referenceCount == 1 else {
                throw RepositoryError.sharedMemoRequiresGroupAction(
                    association.memoURL.lastPathComponent
                )
            }
            return [association.renameArtifact, recordRenameArtifact(for: imageURL)]
        }
    }

    /// Includes an absent relationship destination too: adopting an orphan record would silently
    /// link a new duplicate to unrelated audio. WAV names are reserved only for proven memos.
    func copyDestinationURLs(for sourceImageURL: URL, to destinationImageURL: URL) throws -> [URL] {
        var destinations = [destinationImageURL, recordURL(for: destinationImageURL)]
        if let association = try copyAssociation(for: sourceImageURL) {
            destinations.append(copyMemoDestination(for: association, imageURL: destinationImageURL))
        }
        return destinations
    }

    /// Copies a photo plus its proven voice memo as a synchronous transaction. Shared source
    /// memos become independent copies; no source record or audio is moved or rewritten.
    /// Callers serialize this operation. Cancellation can abandon private staging, while the
    /// installation/rollback phase is synchronous and non-cancellable once it begins.
    func copyImagePreservingCompanion(from sourceImageURL: URL, to destinationImageURL: URL) throws {
        let imageRevision = try copyRevision(at: sourceImageURL)
        let originalRecord = try copyRecordBytes(for: sourceImageURL)
        let association = try copyAssociation(for: sourceImageURL)
        let memoRevision = try association.map { try copyRevision(at: $0.memoURL) }
        let recordDestination = recordURL(for: destinationImageURL)
        let memoDestination = association.map { copyMemoDestination(for: $0, imageURL: destinationImageURL) }
        let destinations = [destinationImageURL, recordDestination] + [memoDestination].compactMap { $0 }
        let fm = FileManager.default
        for destination in destinations where fm.fileExists(atPath: destination.path) {
            throw RepositoryError.copyDestinationExists(destination.lastPathComponent)
        }
        guard Set(destinations.map(\.standardizedFileURL)).count == destinations.count else {
            throw RepositoryError.invalidRecord
        }

        let staging = destinationImageURL.deletingLastPathComponent()
            .appendingPathComponent(".voice-memo-copy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let stagedImage = staging.appendingPathComponent(destinationImageURL.lastPathComponent)
        try copyIO.copy(sourceImageURL, stagedImage)
        var prepared = [(stagedImage, destinationImageURL)]
        if let association, let memoDestination {
            let stagedMemo = staging.appendingPathComponent(memoDestination.lastPathComponent)
            try copyIO.copy(association.memoURL, stagedMemo)
            let record = VoiceMemoCompanionRecord(
                profileIdentifier: association.profileIdentifier,
                imageFilename: destinationImageURL.lastPathComponent,
                memoFilename: memoDestination.lastPathComponent
            )
            let stagedRecord = staging.appendingPathComponent(recordDestination.lastPathComponent)
            try encoded(record).write(to: stagedRecord, options: .atomic)
            prepared.append((stagedMemo, memoDestination))
            prepared.append((stagedRecord, recordDestination))
        }

        // Neither path nor modification time alone proves which bytes were copied. Reuse the
        // revision service's streaming hash and stat checks, and verify the staged bytes too.
        // A changed record is rejected even if it happens to resolve to equivalent filenames.
        guard try imageRevision.matches(copyRevision(at: sourceImageURL)),
              imageRevision.digest == (try SourceImageRevisionCaptureIO.system.hash(stagedImage)),
              originalRecord == (try copyRecordBytes(for: sourceImageURL)),
              association == (try copyAssociation(for: sourceImageURL)) else {
            throw RepositoryError.copySourceChanged
        }
        if let association, let memoRevision, let memoDestination {
            let stagedMemo = staging.appendingPathComponent(memoDestination.lastPathComponent)
            guard try memoRevision.matches(copyRevision(at: association.memoURL)),
                  memoRevision.digest == (try SourceImageRevisionCaptureIO.system.hash(stagedMemo)) else {
                throw RepositoryError.copySourceChanged
            }
        }
        // Sample again after the last hash so edits during verification are also rejected.
        guard try imageRevision.snapshot.matches(copyFileSnapshot(at: sourceImageURL)),
              originalRecord == (try copyRecordBytes(for: sourceImageURL)),
              association == (try copyAssociation(for: sourceImageURL)) else {
            throw RepositoryError.copySourceChanged
        }
        if let association, let memoRevision {
            guard try memoRevision.snapshot.matches(copyFileSnapshot(at: association.memoURL)) else {
                throw RepositoryError.copySourceChanged
            }
        }
        for destination in destinations where fm.fileExists(atPath: destination.path) {
            throw RepositoryError.copyDestinationExists(destination.lastPathComponent)
        }

        var installed: [URL] = []
        do {
            for (source, destination) in prepared {
                try copyIO.install(source, destination)
                installed.append(destination)
            }
            // An unassociated copy has no record to install exclusively. Reject a late orphan
            // instead of letting lookup silently adopt it; rollback never deletes that record.
            if association == nil, fm.fileExists(atPath: recordDestination.path) {
                throw RepositoryError.copyDestinationExists(recordDestination.lastPathComponent)
            }
        } catch {
            var residuals: [String] = []
            for destination in installed.reversed() {
                do { try copyIO.remove(destination) }
                catch { residuals.append(destination.path) }
            }
            if !residuals.isEmpty { throw RepositoryError.copyRollbackFailed(residuals) }
            throw error
        }
    }

    private struct CopyRevision {
        let snapshot: SourceImageRevisionFileSnapshot
        let digest: Data

        func matches(_ other: Self) -> Bool {
            snapshot.matches(other.snapshot) && digest == other.digest
        }
    }

    private func copyFileSnapshot(at url: URL) throws -> SourceImageRevisionFileSnapshot {
        // Construct a fresh URL to avoid reusing Foundation's cached resource values.
        try SourceImageRevisionCaptureIO.system.snapshot(URL(fileURLWithPath: url.path))
    }

    private func copyRevision(at url: URL) throws -> CopyRevision {
        let before = try copyFileSnapshot(at: url)
        let digest = try SourceImageRevisionCaptureIO.system.hash(url)
        guard try before.matches(copyFileSnapshot(at: url)) else {
            throw RepositoryError.copySourceChanged
        }
        return CopyRevision(snapshot: before, digest: digest)
    }

    private func copyRecordBytes(for imageURL: URL) throws -> Data? {
        let record = recordURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: record.path) else { return nil }
        return try Data(contentsOf: record)
    }

    private func copyAssociation(for imageURL: URL) throws -> VoiceMemoAssociation? {
        switch try lookup(for: imageURL) {
        case .none: return nil
        case .available(let association): return association
        case .missing(let record): throw RepositoryError.memoMissing(record.memoFilename)
        }
    }

    private func copyMemoDestination(for association: VoiceMemoAssociation, imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension(association.memoURL.pathExtension)
    }

    /// Validates records after the rename executor moved the image, memo, and relationship sidecar.
    /// Lookup derives the current image/memo names from the sidecar's new name when its stored names
    /// describe an earlier rename, so correctness never depends on a fallible post-transaction write.
    @discardableResult
    func reassociateRenamedRecords(
        using mappings: [BatchRenameExecutionPresentation.Mapping]
    ) throws -> Int {
        var count = 0
        for mapping in mappings {
            let destinationRecordURL = recordURL(for: mapping.destinationURL)
            guard FileManager.default.fileExists(atPath: destinationRecordURL.path) else { continue }
            switch try lookup(for: mapping.destinationURL) {
            case .available:
                count += 1
            case .missing(let record):
                throw RepositoryError.memoMissing(record.memoFilename)
            case .none:
                break
            }
        }
        return count
    }

    func recordURL(for imageURL: URL) -> URL {
        imageURL.deletingLastPathComponent()
            .appendingPathComponent(".\(imageURL.lastPathComponent)\(Self.recordSuffix)")
    }

    private func recordRenameArtifact(for imageURL: URL) -> RenamePlanningAssociatedArtifact {
        RenamePlanningAssociatedArtifact(
            identifier: "voice-memo-relationship",
            displayName: "Voice memo relationship",
            sourceURL: recordURL(for: imageURL),
            filenamePattern: RenameArtifactFilenamePattern(
                basis: .fullFilename,
                prefix: ".",
                suffix: Self.recordSuffix
            )
        )
    }

    private func loadRecord(
        at url: URL,
        expectedImageFilename: String?
    ) throws -> VoiceMemoCompanionRecord {
        let data = try Data(contentsOf: url)
        let record: VoiceMemoCompanionRecord
        do {
            record = try JSONDecoder().decode(VoiceMemoCompanionRecord.self, from: data)
        } catch let error as RepositoryError {
            throw error
        } catch {
            throw RepositoryError.invalidRecord
        }
        try Self.validateFilename(record.imageFilename)
        try Self.validateFilename(record.memoFilename)
        guard !record.profileIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expectedImageFilename.map({ $0 == record.imageFilename }) ?? true else {
            throw RepositoryError.invalidRecord
        }
        return record
    }

    private func write(_ record: VoiceMemoCompanionRecord, to url: URL) throws {
        let data = try encoded(record)
        try data.write(to: url, options: .atomic)
    }

    private func encoded(_ record: VoiceMemoCompanionRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }

    private func writeBatchWithRollback(
        _ prepared: [(record: VoiceMemoCompanionRecord, url: URL)]
    ) throws {
        struct PriorContents {
            let url: URL
            let data: Data?
        }

        let writes = try prepared.map { (try encoded($0.record), $0.url) }
        let prior = try writes.map { _, url in
            PriorContents(
                url: url,
                data: recordIO.fileExists(at: url)
                    ? try recordIO.read(from: url)
                    : nil
            )
        }

        do {
            for (data, url) in writes {
                try recordIO.writeAtomically(data, to: url)
            }
        } catch {
            var rollbackFailed = false
            for item in prior.reversed() {
                do {
                    if let data = item.data {
                        try recordIO.writeAtomically(data, to: item.url)
                    } else if recordIO.fileExists(at: item.url) {
                        try recordIO.remove(at: item.url)
                    }
                } catch {
                    rollbackFailed = true
                }
            }
            if rollbackFailed { throw RepositoryError.importPersistenceRollbackFailed }
            throw error
        }
    }

    private func successfulDestinations(
        for result: ImportCopyService.CopyResult
    ) -> [URL] {
        var destinations: [URL] = []
        if let primary = result.primaryURL {
            destinations.append(primary)
        }
        if case let .copied(url, _, _, _) = result.backup,
           let verification = result.backupVerification,
           verification == .verified || verification == .skipped {
            destinations.append(url)
        }
        return destinations
    }

    private func effectiveMemoFilename(
        for record: VoiceMemoCompanionRecord,
        currentImageFilename: String
    ) -> String {
        guard record.imageFilename != currentImageFilename else { return record.memoFilename }
        let memoExtension = (record.memoFilename as NSString).pathExtension
        let currentStem = (currentImageFilename as NSString).deletingPathExtension
        return memoExtension.isEmpty ? currentStem : "\(currentStem).\(memoExtension)"
    }

    private func memoReferenceCount(to memoURL: URL, in folderURL: URL) throws -> Int {
        let target = VoiceMemoAssociationService.canonicalURL(memoURL)
        let recordURLs = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: []
        ).filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(".") && name.hasSuffix(Self.recordSuffix)
        }

        var count = 0
        for url in recordURLs {
            let name = url.lastPathComponent
            let imageFilename = String(name.dropFirst().dropLast(Self.recordSuffix.count))
            try Self.validateFilename(imageFilename)
            let record = try loadRecord(at: url, expectedImageFilename: nil)
            let effectiveMemo = effectiveMemoFilename(
                for: record,
                currentImageFilename: imageFilename
            )
            let candidate = folderURL.appendingPathComponent(effectiveMemo)
            if VoiceMemoAssociationService.canonicalURL(candidate) == target {
                count += 1
            }
        }
        return count
    }

    private static func validateFilename(_ filename: String) throws {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/"),
              !filename.contains("\\") else {
            throw RepositoryError.unsafeFilename(filename)
        }
    }
}
