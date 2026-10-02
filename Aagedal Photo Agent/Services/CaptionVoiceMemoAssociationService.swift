import Foundation
import Observation

nonisolated struct CaptionVoiceMemoAssociationPreview: Sendable {
    let association: VoiceMemoAssociation
    fileprivate let inventory: [URL: CaptionVoiceMemoAssociationRevision]
    fileprivate let folderDevice: UInt64
    fileprivate let folderInode: UInt64
}

nonisolated struct CaptionVoiceMemoAssociationRevision: Equatable, Sendable {
    let file: CaptionVoiceMemoFileRevision
    let digest: Data
}

/// Discovery is read-only. Both explicit and automatic linking revalidate a unique match before creating a relationship.
actor CaptionVoiceMemoAssociationService {
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }
    private let scanner: ImportVoiceMemoAssociationScanService

    init(scanner: ImportVoiceMemoAssociationScanService = ImportVoiceMemoAssociationScanService(),
         filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.caption-memo-association", qos: .utility)) {
        self.scanner = scanner
        self.filesystemQueue = filesystemQueue
    }

    func discover(imageURL: URL) async throws -> CaptionVoiceMemoAssociationPreview {
        let image = imageURL.standardizedFileURL
        let folder = image.deletingLastPathComponent()
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        try requireAbsentRecord(image)
        // Most photo folders have no voice memos. Avoid hashing their entire inventory
        // during automatic checks when there cannot be an adjacent candidate.
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        guard files.contains(where: { $0.pathExtension.lowercased() == "wav" }) else { throw Failure.noMatch }
        let folderRevision = try CaptionVoiceMemoFileRevision.read(folder)
        let inventory = try Self.captureInventory(folder)
        let report = try await scan(inventory: inventory, folder: folder)
        guard let association = report.association(for: image) else {
            throw Failure.noMatch
        }
        guard association.imageURL == image, association.memoURL.deletingLastPathComponent() == folder else {
            throw Failure.changed
        }
        let preview = CaptionVoiceMemoAssociationPreview(association: association, inventory: inventory,
            folderDevice: folderRevision.device, folderInode: folderRevision.inode)
        try Self.revalidate(preview)
        try requireAbsentRecord(image)
        return preview
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
        try Self.revalidate(preview)
        try requireAbsentRecord(image)
        let report = try await scan(inventory: preview.inventory, folder: folder)
        guard report.association(for: image) == preview.association else { throw Failure.changed }
        try Task.checkCancellation()
        try requireAbsentRecord(image)
        try VoiceMemoCompanionRepository().saveNewReviewedAssociation(preview.association) {
            try Self.revalidate(preview)
        }
    }

    private func scan(inventory: [URL: CaptionVoiceMemoAssociationRevision], folder: URL) async throws
        -> VoiceMemoAssociationReport {
        let files = inventory.keys.sorted { $0.path < $1.path }
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

    private static func captureInventory(_ folder: URL) throws -> [URL: CaptionVoiceMemoAssociationRevision] {
        guard try FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType == .typeDirectory
        else { throw Failure.changed }
        let files = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        var inventory: [URL: CaptionVoiceMemoAssociationRevision] = [:]
        for file in files where SupportedImageFormats.isSupported(url: file) || file.pathExtension.lowercased() == "wav" {
            try Task.checkCancellation()
            try VoiceMemoTranscriptionService.requireRegularInput(file)
            let before = try CaptionVoiceMemoFileRevision.read(file)
            let hash = try SourceImageRevisionCaptureIO.system.hash(file)
            guard try CaptionVoiceMemoFileRevision.read(file) == before else { throw Failure.changed }
            inventory[file.standardizedFileURL] = .init(file: before, digest: hash)
        }
        return inventory
    }

    private static func revalidate(_ preview: CaptionVoiceMemoAssociationPreview) throws {
        try Task.checkCancellation()
        let folder = preview.association.imageURL.deletingLastPathComponent()
        let current = try CaptionVoiceMemoFileRevision.read(folder)
        guard current.device == preview.folderDevice, current.inode == preview.folderInode,
              try captureInventory(folder) == preview.inventory else { throw Failure.changed }
    }

    enum Failure: LocalizedError {
        case noMatch, changed, existingRecord
        var errorDescription: String? {
            switch self {
            case .noMatch: "No unique, validated Sony voice memo was found. Matching names alone cannot establish a relationship."
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
