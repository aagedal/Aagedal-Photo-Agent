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
        case moveRollbackFailed([String])
        case unsafeMemoFile(String)
        case unsafeTrashCarrier(String)
        case trashRollbackFailed([String])
        case trashOutcomeUncertain(String)

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
                return "The saved voice memo \(filename) is missing. Restore it before copying, moving, renaming, or trashing the photo."
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
                return "The photo, voice memo, or saved relationship changed during the file operation. Try again when the source is stable."
            case .moveRollbackFailed(let paths):
                return "The photo and voice-memo move failed and could not be fully rolled back. Recover these files before retrying: \(paths.joined(separator: ", "))."
            case .unsafeTrashCarrier(let path):
                return "Trash was stopped because a photo companion is malformed or is not an owned regular file: \(path)"
            case .trashRollbackFailed(let paths):
                return "Trash failed and some originals could not be restored. Recover these files before retrying: \(paths.joined(separator: ", "))."
            case .trashOutcomeUncertain(let path):
                return "Trash reported an error after the recovery bundle disappeared. Check Finder Trash for \(URL(fileURLWithPath: path).lastPathComponent) before retrying; the original files may already be there. Original recovery path: \(path)"
            case .unsafeMemoFile(let filename):
                return "The saved voice memo \(filename) must be a regular file in the photo's folder before file operations can proceed. Symbolic links are left untouched."
            }
        }
    }

    enum Lookup: Equatable, Sendable {
        case none
        case available(VoiceMemoAssociation)
        case missing(VoiceMemoCompanionRecord)
    }

    /// Immutable source evidence retained while a derivative RAW archive is rendered and signed.
    /// The image revision prevents a long conversion from being committed against different source
    /// bytes. A relationship is either absent, or is bound to the exact record and regular adjacent
    /// memo bytes captured here; adjacent WAV files without a record are deliberately ignored.
    struct ArchiveSourceSnapshot: Sendable {
        fileprivate let sourceImageURL: URL
        fileprivate let imageRevision: CopyRevision
        fileprivate let recordBytes: Data?
        fileprivate let association: VoiceMemoAssociation?
        fileprivate let memoRevision: CopyRevision?

        var memoPathExtension: String? { association?.memoURL.pathExtension }
        var hasAssociation: Bool { association != nil }
    }

    struct StagedArchiveCompanion: Sendable {
        let stagedMemoURL: URL?
        let destinationMemoURL: URL?
        let stagedRecordURL: URL?
        let destinationRecordURL: URL
    }

    static let recordSuffix = ".voice-memo.json"

    func captureArchiveSource(for imageURL: URL) throws -> ArchiveSourceSnapshot {
        let source = imageURL.standardizedFileURL
        let imageRevision = try copyRevision(at: source)
        let recordBytes = try copyRecordBytes(for: source)
        let association = try copyAssociation(for: source)
        let memoRevision: CopyRevision?
        if let association {
            try requireOwnedRegularMemo(association, sourceImageURL: source)
            memoRevision = try copyRevision(at: association.memoURL)
        } else {
            memoRevision = nil
        }
        let snapshot = ArchiveSourceSnapshot(
            sourceImageURL: source,
            imageRevision: imageRevision,
            recordBytes: recordBytes,
            association: association,
            memoRevision: memoRevision
        )
        try revalidateArchiveSource(snapshot)
        return snapshot
    }

    func revalidateArchiveSource(_ snapshot: ArchiveSourceSnapshot) throws {
        guard snapshot.imageRevision.matches(try copyRevision(at: snapshot.sourceImageURL)),
              snapshot.recordBytes == (try copyRecordBytes(for: snapshot.sourceImageURL)),
              snapshot.association == (try copyAssociation(for: snapshot.sourceImageURL)) else {
            throw RepositoryError.copySourceChanged
        }
        if let association = snapshot.association, let memoRevision = snapshot.memoRevision {
            try requireOwnedRegularMemo(association, sourceImageURL: snapshot.sourceImageURL)
            guard memoRevision.matches(try copyRevision(at: association.memoURL)) else {
                throw RepositoryError.copySourceChanged
            }
        }
    }

    /// Prepares only the derivative archive's independent memo and rewritten relationship.
    /// The rendered image and XMP remain owned by the archive transaction. No destination is
    /// installed here, which lets signing and final source revalidation finish before commit.
    func stageArchiveCompanion(
        from snapshot: ArchiveSourceSnapshot,
        for destinationImageURL: URL,
        in stagingDirectory: URL
    ) throws -> StagedArchiveCompanion {
        try revalidateArchiveSource(snapshot)
        let destinationRecord = recordURL(for: destinationImageURL)
        guard let association = snapshot.association, let memoRevision = snapshot.memoRevision else {
            return StagedArchiveCompanion(
                stagedMemoURL: nil,
                destinationMemoURL: nil,
                stagedRecordURL: nil,
                destinationRecordURL: destinationRecord
            )
        }

        let destinationMemo = destinationImageURL.deletingPathExtension()
            .appendingPathExtension(association.memoURL.pathExtension)
        let stagedMemo = stagingDirectory.appendingPathComponent("archive-memo")
            .appendingPathExtension(association.memoURL.pathExtension)
        let stagedRecord = stagingDirectory.appendingPathComponent("archive-relationship.json")
        try copyIO.copy(association.memoURL, stagedMemo)
        guard memoRevision.digest == (try SourceImageRevisionCaptureIO.system.hash(stagedMemo)) else {
            throw RepositoryError.copySourceChanged
        }
        let record = VoiceMemoCompanionRecord(
            profileIdentifier: association.profileIdentifier,
            imageFilename: destinationImageURL.lastPathComponent,
            memoFilename: destinationMemo.lastPathComponent
        )
        try encoded(record).write(to: stagedRecord, options: .atomic)
        try revalidateArchiveSource(snapshot)
        return StagedArchiveCompanion(
            stagedMemoURL: stagedMemo,
            destinationMemoURL: destinationMemo,
            stagedRecordURL: stagedRecord,
            destinationRecordURL: destinationRecord
        )
    }

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

    fileprivate struct CopyRevision: Sendable {
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

    private func requireOwnedRegularMemo(
        _ association: VoiceMemoAssociation,
        sourceImageURL: URL
    ) throws {
        let record = try loadRecord(at: recordURL(for: sourceImageURL), expectedImageFilename: nil)
        let memoFilename = effectiveMemoFilename(
            for: record,
            currentImageFilename: sourceImageURL.lastPathComponent
        )
        let memoEntry = sourceImageURL.deletingLastPathComponent().appendingPathComponent(memoFilename)
        let uncachedMemoEntry = URL(fileURLWithPath: memoEntry.path)
        let values = try uncachedMemoEntry.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              association.memoURL.deletingLastPathComponent()
                == VoiceMemoAssociationService.canonicalURL(sourceImageURL.deletingLastPathComponent()) else {
            throw RepositoryError.unsafeMemoFile(memoFilename)
        }
    }

    /// Shared source memos receive an image-specific name at the destination. This lets a
    /// sequential RAW+JPEG move preserve independent copies without the first consuming the
    /// second photo's WAV name. Existing destination audio is never reused by filename alone.
    func moveDestinationURLs(for sourceImageURL: URL, to destinationImageURL: URL) throws -> [URL] {
        let companion = try moveCompanion(for: sourceImageURL, to: destinationImageURL)
        return [destinationImageURL, recordURL(for: destinationImageURL)]
            + [companion?.destinationMemo].compactMap { $0 }
    }

    struct MoveReceipt: Sendable {
        /// Committed moves remain successes. These private original-byte backups need cleanup
        /// after a failed post-commit deletion; callers must report the exact paths separately.
        let cleanupResidualURLs: [URL]
    }

    /// Moves the photo, its proven memo, and its rewritten relationship as one transaction.
    /// Shared source WAVs are copied; exclusive WAVs move. The optional tail lets a caller
    /// transact additional artifacts, provided it rolls back its own partial changes if it
    /// throws. Cancellation may discard preparation; installation and rollback do not suspend.
    @discardableResult
    func moveImagePreservingCompanion(
        from sourceImageURL: URL,
        to destinationImageURL: URL,
        additionalChanges: () throws -> Void = {}
    ) throws -> MoveReceipt {
        let fm = FileManager.default
        let sourceRecord = recordURL(for: sourceImageURL)
        let destinationRecord = recordURL(for: destinationImageURL)
        let originalRecord = try copyRecordBytes(for: sourceImageURL)
        let imageRevision = try copyRevision(at: sourceImageURL)
        let companion = try moveCompanion(for: sourceImageURL, to: destinationImageURL)
        let memoRevision = try companion.map { try copyRevision(at: $0.association.memoURL) }
        let destinations = [destinationImageURL, destinationRecord]
            + [companion?.destinationMemo].compactMap { $0 }
        try requireAvailableMoveDestinations(destinations)

        let staging = destinationImageURL.deletingLastPathComponent()
            .appendingPathComponent(".voice-memo-move-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let stagedRecord = staging.appendingPathComponent("relationship.json")
        let stagedImage = staging.appendingPathComponent("image")
        let stagedMemo = staging.appendingPathComponent("memo.wav")
        try copyIO.copy(sourceImageURL, stagedImage)
        if let companion {
            try copyIO.copy(companion.association.memoURL, stagedMemo)
            guard try memoRevision?.digest == SourceImageRevisionCaptureIO.system.hash(stagedMemo) else {
                throw RepositoryError.copySourceChanged
            }
            let record = VoiceMemoCompanionRecord(
                profileIdentifier: companion.association.profileIdentifier,
                imageFilename: destinationImageURL.lastPathComponent,
                memoFilename: companion.destinationMemo.lastPathComponent
            )
            try encoded(record).write(to: stagedRecord, options: .atomic)
        }

        guard try imageRevision.matches(copyRevision(at: sourceImageURL)),
              imageRevision.digest == (try SourceImageRevisionCaptureIO.system.hash(stagedImage)),
              originalRecord == (try copyRecordBytes(for: sourceImageURL)),
              companion == (try moveCompanion(for: sourceImageURL, to: destinationImageURL)) else {
            throw RepositoryError.copySourceChanged
        }
        if let companion, let memoRevision {
            guard try memoRevision.matches(copyRevision(at: companion.association.memoURL)) else {
                throw RepositoryError.copySourceChanged
            }
        }
        guard try imageRevision.snapshot.matches(copyFileSnapshot(at: sourceImageURL)),
              originalRecord == (try copyRecordBytes(for: sourceImageURL)),
              companion == (try moveCompanion(for: sourceImageURL, to: destinationImageURL)) else {
            throw RepositoryError.copySourceChanged
        }
        try requireAvailableMoveDestinations(destinations)
        try Task.checkCancellation()

        // Foundation moveItem copies then removes across volumes, and can throw after creating a
        // destination. Avoid that ambiguous state entirely: stage verified destination copies,
        // retire sources with same-directory renames, then install only same-volume staged files.
        // Keep retirement backups if recovery fails; their names are never mistaken for records.
        let recordBackup = sourceImageURL.deletingLastPathComponent()
            .appendingPathComponent(".voice-memo-move-backup-\(UUID().uuidString)")
        let imageBackup = sourceImageURL.deletingLastPathComponent()
            .appendingPathComponent(".voice-memo-move-backup-\(UUID().uuidString)")
        let memoBackup = sourceImageURL.deletingLastPathComponent()
            .appendingPathComponent(".voice-memo-move-backup-\(UUID().uuidString)")
        var recordRetired = false
        var imageRetired = false
        var memoRetired = false
        var imageInstalled = false
        var memoInstalled = false
        var recordInstalled = false
        do {
            if companion != nil {
                try copyIO.install(sourceRecord, recordBackup)
                recordRetired = true
                guard try Data(contentsOf: recordBackup) == originalRecord else {
                    throw RepositoryError.copySourceChanged
                }
            }
            try copyIO.install(sourceImageURL, imageBackup)
            imageRetired = true
            if let companion, !companion.isShared {
                try copyIO.install(companion.association.memoURL, memoBackup)
                memoRetired = true
            }
            // Retiring closes the source-name race: validate the actual original bytes now held
            // in our backups before committing or deleting them. An external write immediately
            // before a retirement rename must be restored, never discarded for an older copy.
            guard try imageRevision.matches(copyRevision(at: imageBackup)) else {
                throw RepositoryError.copySourceChanged
            }
            if let companion, let memoRevision {
                guard try memoRevision.matches(copyRevision(
                    at: memoRetired ? memoBackup : companion.association.memoURL
                )) else {
                    throw RepositoryError.copySourceChanged
                }
            }
            try copyIO.install(stagedImage, destinationImageURL)
            imageInstalled = true
            if let companion {
                try copyIO.install(stagedMemo, companion.destinationMemo)
                memoInstalled = true
                try copyIO.install(stagedRecord, destinationRecord)
                recordInstalled = true
            } else if fm.fileExists(atPath: destinationRecord.path)
                || fm.fileExists(atPath: sourceRecord.path) {
                throw RepositoryError.copySourceChanged
            }
            try additionalChanges()
        } catch {
            var recovery: [String] = []
            if recordInstalled {
                do { try copyIO.remove(destinationRecord) }
                catch { recovery.append(destinationRecord.path) }
            }
            if memoInstalled, let companion {
                do { try copyIO.remove(companion.destinationMemo) }
                catch { recovery.append(companion.destinationMemo.path) }
            }
            if imageInstalled {
                do { try copyIO.remove(destinationImageURL) }
                catch { recovery.append(destinationImageURL.path) }
            }
            if memoRetired, let companion {
                do { try copyIO.install(memoBackup, companion.association.memoURL) }
                catch { recovery.append(memoBackup.path) }
            }
            if imageRetired {
                do { try copyIO.install(imageBackup, sourceImageURL) }
                catch { recovery.append(imageBackup.path) }
            }
            if recordRetired {
                do { try copyIO.install(recordBackup, sourceRecord) }
                catch { recovery.append(recordBackup.path) }
            }
            if !recovery.isEmpty { throw RepositoryError.moveRollbackFailed(recovery) }
            throw error
        }
        // The installed bundle is authoritative. Report retained original bytes separately;
        // throwing here would incorrectly label a fully committed photo as still unmoved.
        var cleanupResiduals: [URL] = []
        for backup in [recordRetired ? recordBackup : nil, imageRetired ? imageBackup : nil,
                       memoRetired ? memoBackup : nil].compactMap({ $0 }) {
            do { try copyIO.remove(backup) }
            catch { cleanupResiduals.append(backup) }
        }
        return MoveReceipt(cleanupResidualURLs: cleanupResiduals)
    }

    /// A proven memo is trashed with its photo in one visible recoverable folder. Shared
    /// audio and shared XMP are copied, so deleting one RAW/JPEG never consumes the
    /// remaining variant's companions. Restore the whole folder from Finder Trash, then open
    /// that folder in Photo Agent; filenames and the hidden metadata hierarchy remain intact.
    /// This is a synchronous rollback transaction, not a process-crash-atomic multi-file move.
    func trashImagePreservingCompanion(
        at imageURL: URL,
        using handler: any ImageTrashHandling
    ) throws {
        let fm = FileManager.default
        let recordURL = recordURL(for: imageURL)
        if try trashCarrierExists(at: recordURL),
           try fm.attributesOfItem(atPath: recordURL.path)[.type] as? FileAttributeType != .typeRegular {
            throw RepositoryError.unsafeTrashCarrier(recordURL.path)
        }
        // Keep the old direct path for photos without a persisted relationship, including
        // callers with virtual URLs. Malformed or unavailable saved relationships fail closed.
        guard let companion = try moveCompanion(for: imageURL, to: imageURL) else {
            try handler.trashItem(at: imageURL)
            return
        }
        let folder = imageURL.deletingLastPathComponent()
        let bundle = folder.appendingPathComponent(
            "\(String(imageURL.lastPathComponent.prefix(60))) Photo Agent Trash \(UUID().uuidString)",
            isDirectory: true
        )
        let originalReferenceCount = try memoReferenceCount(to: companion.association.memoURL, in: folder)
        guard companion.isShared == (originalReferenceCount > 1) else { throw RepositoryError.copySourceChanged }
        let originalSiblings = try trashSiblingImages(for: imageURL)
        struct Carrier {
            let source: URL
            let destination: URL
            let shared: Bool
            let revision: CopyRevision
        }
        var carriers: [Carrier] = []
        func append(_ source: URL, relativePath: String, shared: Bool) throws {
            let attributes = try fm.attributesOfItem(atPath: source.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  source.resolvingSymlinksInPath().deletingLastPathComponent().path
                    == source.deletingLastPathComponent().resolvingSymlinksInPath().path else {
                throw RepositoryError.unsafeTrashCarrier(source.path)
            }
            carriers.append(Carrier(source: source, destination: bundle.appendingPathComponent(relativePath),
                                    shared: shared, revision: try copyRevision(at: source)))
        }
        try append(imageURL, relativePath: imageURL.lastPathComponent, shared: false)
        try append(recordURL, relativePath: recordURL.lastPathComponent, shared: false)
        try append(companion.association.memoURL,
                   relativePath: companion.association.memoURL.lastPathComponent, shared: companion.isShared)
        let xmp = imageURL.deletingPathExtension().appendingPathExtension("xmp")
        if try trashCarrierExists(at: xmp) {
            guard try fm.attributesOfItem(atPath: xmp.path)[.type] as? FileAttributeType == .typeRegular else {
                throw RepositoryError.unsafeTrashCarrier(xmp.path)
            }
            // Trash preserves opaque XMP bytes without interpreting or rewriting them.
            // Even unreadable metadata must remain recoverable with the original photo.
            try append(xmp, relativePath: xmp.lastPathComponent, shared: !originalSiblings.isEmpty)
        }
        let metadataFolder = folder.appendingPathComponent(MetadataSidecarService.sidecarDirectoryName)
        if try trashCarrierExists(at: metadataFolder) {
            guard try fm.attributesOfItem(atPath: metadataFolder.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw RepositoryError.unsafeTrashCarrier(metadataFolder.path)
            }
            for source in MetadataSidecarService().relocationDestinationURLs(for: imageURL, in: folder) {
                guard try trashCarrierExists(at: source) else { continue }
                guard try fm.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeRegular else {
                    throw RepositoryError.unsafeTrashCarrier(source.path)
                }
                // Preserve all fields, including newer opaque extensions; only reject malformed
                // carriers rather than silently dropping them or traversing linked directories.
                guard let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: source))) as? [String: Any],
                      let declaredOwner = json["sourceFile"] as? String,
                      !declaredOwner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      declaredOwner != ".", declaredOwner != "..",
                      !declaredOwner.contains("/"), !declaredOwner.contains("\\") else {
                    throw RepositoryError.unsafeTrashCarrier(source.path)
                }
                let isCurrent = source.lastPathComponent == "\(imageURL.lastPathComponent).meta.json"
                guard declaredOwner == imageURL.lastPathComponent else {
                    if isCurrent { throw RepositoryError.unsafeTrashCarrier(source.path) }
                    // A basename fallback can belong to another variant. Its owner, not
                    // the shared stem, controls which photo may consume or adopt it.
                    continue
                }
                try append(source, relativePath: "\(MetadataSidecarService.sidecarDirectoryName)/\(source.lastPathComponent)",
                           shared: false)
            }
        }
        guard Set(carriers.map { $0.source.standardizedFileURL }).count == carriers.count,
              Set(carriers.map { $0.destination.standardizedFileURL }).count == carriers.count else {
            throw RepositoryError.invalidRecord
        }
        try Task.checkCancellation()
        try fm.createDirectory(at: bundle, withIntermediateDirectories: false)
        var retired: [Carrier] = []
        var trashEntered = false
        do {
            for carrier in carriers {
                try fm.createDirectory(at: carrier.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if carrier.shared {
                    try copyIO.copy(carrier.source, carrier.destination)
                    guard try carrier.revision.digest == SourceImageRevisionCaptureIO.system.hash(carrier.destination) else {
                        throw RepositoryError.copySourceChanged
                    }
                }
            }
            guard try originalSiblings == trashSiblingImages(for: imageURL),
                  originalReferenceCount == (try memoReferenceCount(to: companion.association.memoURL, in: folder)) else {
                throw RepositoryError.copySourceChanged
            }
            for carrier in carriers {
                guard try carrier.revision.matches(copyRevision(at: carrier.source)) else {
                    throw RepositoryError.copySourceChanged
                }
            }
            try Task.checkCancellation()
            for carrier in carriers where !carrier.shared {
                do {
                    try copyIO.install(carrier.source, carrier.destination)
                    retired.append(carrier)
                } catch {
                    // Same-volume rename may have committed before a wrapper reports failure.
                    if !fm.fileExists(atPath: carrier.source.path), fm.fileExists(atPath: carrier.destination.path) {
                        retired.append(carrier)
                    }
                    throw error
                }
                guard try carrier.revision.matches(copyRevision(at: carrier.destination)) else {
                    throw RepositoryError.copySourceChanged
                }
            }
            // Our relationship and photo are now inside the private bundle, so the expected
            // source reference count falls by one. Catch a new shared owner before Trash.
            guard try originalSiblings == trashSiblingImages(for: imageURL),
                  originalReferenceCount - 1 == (try memoReferenceCount(to: companion.association.memoURL, in: folder)) else {
                throw RepositoryError.copySourceChanged
            }
            for carrier in carriers {
                guard try carrier.revision.matches(copyRevision(at: carrier.shared ? carrier.source : carrier.destination)) else {
                    throw RepositoryError.copySourceChanged
                }
            }
            try Task.checkCancellation()
            trashEntered = true
            try handler.trashItem(at: bundle)
        } catch {
            // Never delete or recreate contents after an ambiguous Trash result. Finder may
            // already hold the only original-byte bundle; its identity is the recovery evidence.
            if trashEntered && !fm.fileExists(atPath: bundle.path) {
                throw RepositoryError.trashOutcomeUncertain(bundle.path)
            }
            var recovery: [String] = []
            for carrier in retired.reversed() {
                do { try copyIO.install(carrier.destination, carrier.source) }
                catch { recovery.append(carrier.destination.path) }
            }
            if recovery.isEmpty {
                do { try copyIO.remove(bundle) }
                catch { recovery.append(bundle.path) }
            }
            if !recovery.isEmpty { throw RepositoryError.trashRollbackFailed(recovery) }
            throw error
        }
    }

    private func trashCarrierExists(at url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return false
        }
    }

    private func trashSiblingImages(for imageURL: URL) throws -> Set<URL> {
        let source = imageURL.standardizedFileURL
        let stem = imageURL.deletingPathExtension().lastPathComponent.lowercased()
        return Set(try FileManager.default.contentsOfDirectory(
            at: imageURL.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).filter {
            $0.standardizedFileURL != source && SupportedImageFormats.isSupported(url: $0)
                && $0.deletingPathExtension().lastPathComponent.lowercased() == stem
        }.map(\.standardizedFileURL))
    }

    private struct MoveCompanion: Equatable {
        let association: VoiceMemoAssociation
        let destinationMemo: URL
        let isShared: Bool
    }

    private func moveCompanion(for source: URL, to destination: URL) throws -> MoveCompanion? {
        guard let association = try copyAssociation(for: source) else { return nil }
        // Lookup resolves canonical URLs for identity. Moving that canonical target would consume
        // an external file if the saved folder entry were a symlink, leaving the link dangling.
        // Moves require ownership of a regular adjacent entry, not merely readable linked bytes.
        let record = try loadRecord(at: recordURL(for: source), expectedImageFilename: nil)
        let memoFilename = effectiveMemoFilename(for: record, currentImageFilename: source.lastPathComponent)
        let memoEntry = source.deletingLastPathComponent().appendingPathComponent(memoFilename)
        let attributes = try FileManager.default.attributesOfItem(atPath: memoEntry.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              association.memoURL.deletingLastPathComponent()
                == VoiceMemoAssociationService.canonicalURL(source.deletingLastPathComponent()) else {
            throw RepositoryError.unsafeMemoFile(memoFilename)
        }
        let count = try memoReferenceCount(to: association.memoURL, in: source.deletingLastPathComponent())
        guard count > 0 else { throw RepositoryError.invalidRecord }
        let isShared = count > 1
        let memoDestination = isShared
            ? destination.appendingPathExtension(association.memoURL.pathExtension)
            : copyMemoDestination(for: association, imageURL: destination)
        return MoveCompanion(association: association, destinationMemo: memoDestination, isShared: isShared)
    }

    private func requireAvailableMoveDestinations(_ destinations: [URL]) throws {
        guard Set(destinations.map(\.standardizedFileURL)).count == destinations.count else {
            throw RepositoryError.invalidRecord
        }
        for destination in destinations where FileManager.default.fileExists(atPath: destination.path) {
            throw RepositoryError.copyDestinationExists(destination.lastPathComponent)
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
