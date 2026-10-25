import Foundation
import Observation

nonisolated struct CaptionVoiceMemoAssociationPreview: Sendable {
    let association: VoiceMemoAssociation
    fileprivate let inventory: [URL: CaptionVoiceMemoAssociationRevision]
    fileprivate let stem: String
    fileprivate let folderDevice: UInt64
    fileprivate let folderInode: UInt64
    /// Folder modification date when the stem group was listed, if it was already safely in
    /// the past. An unchanged settled date proves no entry was added, removed or renamed, so
    /// revalidation can skip relisting a large (NAS) folder.
    fileprivate let settledFolderModificationDate: Date?
}

nonisolated struct CaptionVoiceMemoAssociationRevision: Equatable, Sendable {
    let file: CaptionVoiceMemoFileRevision
    let digest: Data
}

/// Discovery is read-only. Both explicit and automatic linking revalidate a unique match before creating a relationship.
///
/// Every content hash goes through `SourceImageRevisionCaptureService`, whose digest cache is
/// keyed on file ID, size, mtime and ctime. Revalidation therefore re-reads only files whose stat
/// identity changed (or whose timestamps have not settled yet), instead of re-hashing whole RAW,
/// JPEG and WAV files at every step of discovery and installation.
actor CaptionVoiceMemoAssociationService {
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }
    private let scanner: ImportVoiceMemoAssociationScanService
    private let revisionCapture: SourceImageRevisionCaptureService

    init(scanner: ImportVoiceMemoAssociationScanService = ImportVoiceMemoAssociationScanService(),
         revisionCapture: SourceImageRevisionCaptureService = .shared,
         filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.caption-memo-association", qos: .utility)) {
        self.scanner = scanner
        self.revisionCapture = revisionCapture
        self.filesystemQueue = filesystemQueue
    }

    func discover(imageURL: URL) async throws -> CaptionVoiceMemoAssociationPreview {
        let image = imageURL.standardizedFileURL
        let folder = image.deletingLastPathComponent()
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        try requireAbsentRecord(image)
        // Pairing is decided per stem (DSC01234.ARW/.JPG/.WAV), so only that group is evidence.
        // Hashing the whole folder made every Caption open on a card folder read gigabytes.
        let stem = SonyDualCardVoiceMemoAssociationService.stem(image)
        let folderRevision = try CaptionVoiceMemoFileRevision.read(folder)
        let group = try Self.stemGroup(folder, stem: stem)
        guard group.contains(where: { $0.pathExtension.lowercased() == "wav" }) else { throw Failure.noMatch }
        // Sample every file before the scan, so the scan's evidence and the digests captured
        // afterwards are bound to the same, unchanged bytes. Ambiguous or unmatched groups end
        // here without reading any file content.
        let before = try Self.fileRevisions(group)
        let association = try await uniqueAssociation(for: image, files: group, folder: folder)
        let inventory = try Self.captureInventory(before, capture: revisionCapture)
        let preview = CaptionVoiceMemoAssociationPreview(association: association, inventory: inventory,
            stem: stem, folderDevice: folderRevision.device, folderInode: folderRevision.inode,
            settledFolderModificationDate: Self.settledDate(folderRevision.modified))
        try Self.revalidate(preview, capture: revisionCapture)
        try requireAbsentRecord(image)
        return preview
    }

    /// Badge-only probe: the same unique-match decision as `discover` (record absent, regular
    /// same-stem files, one validated Sony pairing) without hashing any file and without
    /// creating identity evidence. Linking still goes through `discover`/`confirm`, which
    /// verify content identity.
    func hasUnlinkedMatch(imageURL: URL) async throws -> Bool {
        let image = imageURL.standardizedFileURL
        let folder = image.deletingLastPathComponent()
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        do {
            try requireAbsentRecord(image)
            let group = try Self.stemGroup(folder, stem: SonyDualCardVoiceMemoAssociationService.stem(image))
            guard group.contains(where: { $0.pathExtension.lowercased() == "wav" }) else { return false }
            _ = try Self.fileRevisions(group)
            _ = try await uniqueAssociation(for: image, files: group, folder: folder)
            return true
        } catch Failure.noMatch {
            return false
        } catch Failure.existingRecord {
            return false
        }
    }

    /// Used when Caption opens a photo. Existing relationships and ambiguous/no matches
    /// are left alone; the normal installation boundary rechecks the source bytes.
    func associateAutomatically(imageURL: URL) async throws -> Bool {
        do {
            let preview = try await discover(imageURL: imageURL)
            try Task.checkCancellation()
            try await confirm(preview)
            return true
        } catch Failure.noMatch {
            return false
        } catch Failure.existingRecord {
            return false
        }
    }

    func confirm(_ preview: CaptionVoiceMemoAssociationPreview) async throws {
        let image = preview.association.imageURL
        let folder = image.deletingLastPathComponent()
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let lease = try MCPProcessReservation.acquireFolder(folder)
        defer { lease.release() }
        let capture = revisionCapture
        try Self.revalidate(preview, capture: capture)
        try requireAbsentRecord(image)
        let report = try await scan(files: Array(preview.inventory.keys), folder: folder)
        guard report.association(for: image) == preview.association else { throw Failure.changed }
        try Task.checkCancellation()
        try requireAbsentRecord(image)
        try VoiceMemoCompanionRepository(revisionCapture: capture).saveNewReviewedAssociation(preview.association) {
            try Self.revalidate(preview, capture: capture)
        }
    }

    private func uniqueAssociation(for image: URL, files: [URL], folder: URL) async throws -> VoiceMemoAssociation {
        let report = try await scan(files: files, folder: folder)
        guard let association = report.association(for: image) else {
            throw Failure.noMatch
        }
        guard association.imageURL == image, association.memoURL.deletingLastPathComponent() == folder else {
            throw Failure.changed
        }
        return association
    }

    private func scan(files: [URL], folder: URL) async throws -> VoiceMemoAssociationReport {
        let files = files.sorted { $0.path < $1.path }
        let result = await scanner.scan(
            primaryImages: files.filter { $0.pathExtension.lowercased() != "wav" },
            primaryMemos: files.filter { $0.pathExtension.lowercased() == "wav" },
            companionFiles: [], primaryRoot: folder, companionRoot: nil)
        guard case .complete(let evidence) = result else { throw CancellationError() }
        try Task.checkCancellation()
        return evidence.report
    }

    private func requireAbsentRecord(_ image: URL) throws {
        let record = VoiceMemoCompanionRepository().recordURL(for: image)
        // attributesOfItem sees dangling links, which also reserve the relationship name.
        if (try? FileManager.default.attributesOfItem(atPath: record.path)) != nil {
            throw Failure.existingRecord
        }
    }

    /// The same-stem supported images and WAVs in `folder`, from one listing.
    private static func stemGroup(_ folder: URL, stem: String) throws -> [URL] {
        guard try FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType == .typeDirectory
        else { throw Failure.changed }
        let files = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        return files.filter { file in
            SonyDualCardVoiceMemoAssociationService.stem(file) == stem
                && (SupportedImageFormats.isSupported(url: file) || file.pathExtension.lowercased() == "wav")
        }.map(\.standardizedFileURL)
    }

    /// Stat samples for `files`, refusing anything that is not a regular file.
    private static func fileRevisions(_ files: [URL]) throws -> [URL: CaptionVoiceMemoFileRevision] {
        var revisions: [URL: CaptionVoiceMemoFileRevision] = [:]
        for file in files {
            try Task.checkCancellation()
            try VoiceMemoTranscriptionService.requireRegularInput(file)
            revisions[file] = try CaptionVoiceMemoFileRevision.read(file)
        }
        return revisions
    }

    /// Digests for files sampled at `expected`; a file whose stat changed since is rejected.
    private static func captureInventory(
        _ expected: [URL: CaptionVoiceMemoFileRevision],
        capture: SourceImageRevisionCaptureService
    ) throws -> [URL: CaptionVoiceMemoAssociationRevision] {
        var inventory: [URL: CaptionVoiceMemoAssociationRevision] = [:]
        for (file, before) in expected {
            try Task.checkCancellation()
            try VoiceMemoTranscriptionService.requireRegularInput(file)
            guard try CaptionVoiceMemoFileRevision.read(file) == before else { throw Failure.changed }
            let verified: SourceImageRevisionVerifiedDigest
            do {
                verified = try capture.verifiedDigestSynchronously(at: file, canonicalize: false)
            } catch SourceImageRevisionError.sourceChangedDuringHash {
                throw Failure.changed
            }
            guard try CaptionVoiceMemoFileRevision.read(file) == before else { throw Failure.changed }
            inventory[file] = .init(file: before, digest: verified.digest)
        }
        return inventory
    }

    /// Re-samples the folder and every inventoried file. Unchanged, settled files answer from
    /// the capture service's digest cache, so repeated revalidation costs stats rather than
    /// reads; a changed stat identity re-hashes the file, which must still match the recorded
    /// digest. Content identity is therefore still verified on every revalidation.
    private static func revalidate(_ preview: CaptionVoiceMemoAssociationPreview,
                                   capture: SourceImageRevisionCaptureService) throws {
        try Task.checkCancellation()
        let folder = preview.association.imageURL.deletingLastPathComponent()
        let current = try CaptionVoiceMemoFileRevision.read(folder)
        guard current.device == preview.folderDevice, current.inode == preview.folderInode else {
            throw Failure.changed
        }
        let listed: Set<URL>
        if let settled = preview.settledFolderModificationDate, current.modified == settled {
            listed = Set(preview.inventory.keys)
        } else {
            listed = Set(try stemGroup(folder, stem: preview.stem))
        }
        guard listed == Set(preview.inventory.keys),
              try captureInventory(preview.inventory.mapValues(\.file), capture: capture) == preview.inventory
        else { throw Failure.changed }
    }

    /// Mirrors the status service's folder-index rule: a listing is reusable only once the
    /// folder date is safely in the past, so a change on a coarse-timestamp volume (FAT: 2 s)
    /// cannot land on the same recorded date.
    private static func settledDate(_ modified: Date) -> Date? {
        Date().timeIntervalSince(modified) > 3 ? modified : nil
    }

    enum Failure: LocalizedError {
        case noMatch, changed, existingRecord
        var errorDescription: String? {
            switch self {
            case .noMatch: "No matching voice memo was found for this photo."
            case .changed: "The folder, photo or voice memo changed. Find the matching voice memo again before linking it."
            case .existingRecord: "This photo already has a saved relationship. Refresh or recover that relationship instead."
            }
        }
    }
}

@MainActor @Observable
final class CaptionVoiceMemoAssociationModel {
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    var pendingAssociation: VoiceMemoAssociation? { preview?.association }
    @ObservationIgnored private let service: CaptionVoiceMemoAssociationService
    private var preview: CaptionVoiceMemoAssociationPreview?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var cancelWork: (() -> Void)?

    init(service: CaptionVoiceMemoAssociationService = CaptionVoiceMemoAssociationService()) { self.service = service }

    func discover(imageURL: URL) async {
        cancel()
        let requested = generation
        isWorking = true
        let task = Task { [service] in Optional(try await service.discover(imageURL: imageURL)) }
        cancelWork = { task.cancel() }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard requested == generation, !Task.isCancelled else { return }
            preview = result
        } catch {
            guard requested == generation else { return }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
        guard requested == generation else { return }
        cancelWork = nil
        isWorking = false
    }

    func associateAutomatically(imageURL: URL) async -> Bool {
        guard !isWorking, preview == nil else { return false }
        cancel()
        let requested = generation
        isWorking = true
        let task = Task { [service] in
            try await service.associateAutomatically(imageURL: imageURL)
        }
        cancelWork = { task.cancel() }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard requested == generation else { return false }
            cancelWork = nil
            isWorking = false
            guard !Task.isCancelled else { return false }
            return result
        } catch {
            guard requested == generation else { return false }
            cancelWork = nil
            isWorking = false
            // Background discovery must not present errors for unrelated or unsupported files.
            return false
        }
    }

    func confirm() async -> Bool {
        guard let preview, !isWorking else { return false }
        self.preview = nil
        errorMessage = nil
        let requested = generation
        isWorking = true
        let task = Task { [service] in
            try await service.confirm(preview)
            return Optional<CaptionVoiceMemoAssociationPreview>.none
        }
        cancelWork = { task.cancel() }
        do {
            _ = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard requested == generation, !Task.isCancelled else { return false }
            cancelWork = nil
            isWorking = false
            return true
        } catch {
            guard requested == generation else { return false }
            cancelWork = nil
            isWorking = false
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            return false
        }
    }

    func cancel() {
        generation &+= 1
        cancelWork?()
        cancelWork = nil
        preview = nil
        isWorking = false
        errorMessage = nil
    }
}
