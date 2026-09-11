import Foundation
import os

/// MainActor admission barrier for the brief interval in which an explicit Caption write removes
/// its old JSON record. Existing load requests resume afterward and read the resulting revision.
@MainActor
private final class CaptionMetadataCleanupPhase {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        finished = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

enum MetadataReferenceSource: String, CaseIterable, Identifiable, Sendable {
    case embedded
    case xmp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .embedded:
            return "Embedded"
        case .xmp:
            return "XMP Sidecar"
        }
    }
}

/// Common/partial projection for an unordered repeatable metadata property across a selection.
/// Values retain first-seen order for stable presentation even though equality is set-based.
nonisolated struct BatchListSelection<Value: Hashable & Sendable>: Sendable, Equatable {
    var common: [Value]
    var partial: [Value]

    nonisolated static var empty: Self { Self(common: [], partial: []) }
}

/// Typed projection of every repeatable field supported by the batch metadata editor.
/// Keeping partial values outside the editing buffer prevents a mixed-state placeholder from ever
/// becoming data that is propagated to the selected files.
nonisolated struct BatchMetadataListSelectionSummary: Sendable, Equatable {
    var repeatable: [MetadataFieldID: BatchListSelection<String>]
    var locationsShown: BatchListSelection<EditorialLocation>
    var imageSuppliers: BatchListSelection<EditorialImageSupplier>

    nonisolated static let empty = Self(
        repeatable: [:], locationsShown: .empty, imageSuppliers: .empty
    )

    nonisolated func selection(for field: MetadataFieldID) -> BatchListSelection<String> {
        repeatable[field] ?? .empty
    }
}

/// Structured locations are not part of `MetadataFieldID`, so they use the same explicit intent
/// vocabulary through a strongly typed companion operation.
nonisolated enum BatchLocationsShownMutation: Sendable, Equatable {
    case untouched
    case append([EditorialLocation])
    case replace([EditorialLocation])
    case clear
}

nonisolated enum BatchListSelectionError: Error, Sendable, Equatable {
    case batchSelectionRequired
    case repeatableFieldRequired(MetadataFieldID)
    case emptyLocationAppend
    case emptyLocationReplace
    case emptyImageSupplierAppend
    case emptyImageSupplierReplace
}

/// Typed completion from a metadata/history commit. This is separate from presentation state so
/// an owner awaiting an older request never has to infer its result from a mutable error string.
nonisolated enum MetadataCommitResult: Sendable, Equatable {
    case succeeded
    case cancelled(message: String)
    case failed(message: String)
}

/// Batch-specific presentation stays separate from the current editor's error state.
nonisolated struct PendingMetadataWriteBatchAttention: Identifiable, Sendable {
    let id: UUID
    let title: String
    let message: String
}

/// Immutable report for one Write All request, including its exact attempted prefix.
nonisolated struct PendingMetadataWriteBatchOutcome: Sendable {
    let requestID: UUID
    let folderURL: URL
    let results: [PendingMetadataWriteResult]
    let discoveryFailures: [PendingMetadataDiscoveryFailure]
    let unattemptedURLs: [URL]
    let wasCancelled: Bool
    let discoveryWasCancelled: Bool

    var completedCount: Int { results.filter(\.completed).count }
    var skippedCount: Int { results.filter(\.wasSkipped).count }
    var failedCount: Int { results.filter { !$0.completed && !$0.wasSkipped && !$0.wasCancelled }.count }

    var attention: PendingMetadataWriteBatchAttention? {
        guard let message = attentionMessage else { return nil }
        return .init(id: requestID, title: "Write All Needs Attention: \(folderURL.lastPathComponent)", message: message)
    }

    var attentionMessage: String? {
        guard wasCancelled || skippedCount > 0 || failedCount > 0 || !discoveryFailures.isEmpty else { return nil }
        var lines = ["Write All in \(folderURL.path): wrote \(completedCount), skipped \(skippedCount), failed \(failedCount)."]
        if wasCancelled { lines.append("Cancelled after \(results.count) attempted photos; \(unattemptedURLs.count) discovered photos were not attempted.") }
        if discoveryWasCancelled { lines.append("Discovery did not finish; additional pending photos may remain unverified.") }
        for failure in discoveryFailures { lines.append("\(failure.url.path): \(failure.message)") }
        for result in results where !result.completed {
            var message = result.imageURL.path + ": " + (result.failure ?? (result.wasSkipped ? "Skipped protected photo." : "The pending write did not complete."))
            var written: [String] = []
            if result.didWriteEmbedded { written.append("image metadata") }
            if result.didWriteXMP { written.append("XMP sidecar") }
            if !written.isEmpty { message += " Already written: " + written.joined(separator: " and ") + "." }
            if result.embeddedWriteMayHaveOccurred { message += " Image metadata may already have changed; verify it before retrying." }
            if let path = result.committedButUnverifiedSidecarURL { message += " Metadata JSON was committed but could not be verified: \(path.path)." }
            lines.append(message)
        }
        return lines.joined(separator: "\n\n")
    }
}

/// A scoped recovery may reload only the exact editor state that the user reviewed.
nonisolated struct CaptionConflictEditorCheckpoint: Sendable {
    let photoURL: URL
    let folderURL: URL?
    let loadID: UUID?
    let metadata: IPTCMetadata
}

@Observable
final class MetadataViewModel {
    var metadata: IPTCMetadata?
    var editingMetadata = IPTCMetadata()
    var isLoading = false
    var isSaving = false
    var isProcessingFolder = false
    var folderProcessProgress = ""
    private(set) var pendingWriteBatchOutcome: PendingMetadataWriteBatchOutcome?
    var selectedCount = 0
    var selectedURLs: [URL] = []
    var hasChanges = false
    var isInEditView = false
    var saveError: String? {
        didSet { captionPersistenceFailureRequestID = nil }
    }
    @ObservationIgnored private var captionPersistenceFailureRequestID: UUID?
    private(set) var variableBatchOutcome: VariableMetadataBatchOutcome?
    private struct VariableAdmission {
        let id: UUID
        let imageURL: URL
        let folderURL: URL
        let editorCheckpoint: CaptionConflictEditorCheckpoint?
        let requiresPersistence: Bool
        let capture: @MainActor () async throws -> VariableMetadataWriteRequest?
    }
    private var retainedVariableAdmissions: [VariableAdmission] = []
    private var retainedVariableWrites: [VariableMetadataWriteRequest] = []
    @ObservationIgnored private let variableLifecycleOwnerID = UUID()
    @ObservationIgnored private let variableLifecycleCoordinator: VariableDraftLifecycleCoordinator
    @ObservationIgnored private var activeVariableBatchIDs: Set<UUID> = []
    @ObservationIgnored private var retainedVariableEditorCheckpoints: [UUID: CaptionConflictEditorCheckpoint] = [:]
    var hasRetainedVariableWrites: Bool { !retainedVariableWrites.isEmpty || !retainedVariableAdmissions.isEmpty }
    var variableProcessingStatus: String?
    var variableProcessingHadFailures = false
    var selectedHasC2PA = false
    var descriptionConflict: DescriptionConflict?
    /// Non-blocking notice rendered as a dismissible banner in the metadata panel.
    /// Set by bulk-add paths (template apply, partial promotion, Quick List pick)
    /// when entries are rejected or canonicalised against the approved list.
    var notice: MetadataPanelNotice?

    var originalImageMetadata: IPTCMetadata?
    var embeddedMetadata: IPTCMetadata?
    var xmpMetadata: IPTCMetadata?
    private var cleanupBaseline: (imageURL: URL, folderURL: URL?, record: MetadataSidecar?)? {
        didSet { capturedCaptionWriteExpectation = nil }
    }
    @ObservationIgnored private var capturedCaptionWriteExpectation: (loadID: UUID?, request: MetadataSidecarReplayRequest)?
    // Captures belong to the full photo path, including its extension. Cleanup phases use the
    // shared XMP stem key conservatively, since sibling formats can share that companion.
    @ObservationIgnored private var captionCaptureGenerations: [String: Int] = [:]
    @ObservationIgnored private var captionCleanupOwners: [String: CaptionMetadataCleanupPhase] = [:]
    var sidecarHistory: [MetadataHistoryEntry] = []
    var currentFolderURL: URL?
    var metadataReferenceSource: MetadataReferenceSource = .embedded
    /// Incremented after every metadata load completes. Observed by EditWorkspaceView
    /// to force re-render even when editingMetadata.cameraRaw hasn't changed.
    var metadataLoadGeneration: Int = 0
    /// Identity used to reject UI buffers registered for a previous load of the same photo.
    var editorBufferLoadID: UUID? { metadataLoadRequestID }

    var hasXmpMetadata: Bool { xmpMetadata != nil }
    var hasEmbeddedCropNotLoaded: Bool {
        guard let embeddedCrop = embeddedMetadata?.cameraRaw?.crop,
              embeddedCrop.hasCrop == true else { return false }
        return editingMetadata.cameraRaw?.crop?.hasCrop != true
    }
    var referenceMetadata: IPTCMetadata? {
        referenceMetadata(
            for: metadataReferenceSource,
            embedded: embeddedMetadata,
            xmp: xmpMetadata,
            imageURL: selectedURLs.count == 1 ? selectedURLs.first : nil
        )
    }
    var canWriteMetadataToImage: Bool {
        if isSaving { return false }
        if hasChanges { return true }
        if selectedCount == 1, let embedded = embeddedMetadata {
            return editingMetadata != embedded
        }
        return selectedHavePendingSidecars
    }

    // Batch metadata state - stores common values across selected images
    var batchCommonMetadata: IPTCMetadata?
    var batchDifferingFields: Set<String> = []
    var batchPartialKeywords: [String] = []
    var batchPartialPersonShown: [String] = []
    var batchListSelectionSummary = BatchMetadataListSelectionSummary.empty
    private(set) var batchFieldMutations: [MetadataFieldID: MetadataFieldMutation] = [:]
    private(set) var batchLocationsShownMutation: BatchLocationsShownMutation = .untouched
    private(set) var batchImageSupplierMutation: EditorialImageSupplierMutation = .untouched
    var isLoadingBatchMetadata = false

    // Geocoding state
    var isReverseGeocoding = false
    var geocodingError: String?
    var geocodingProgress = ""

    private let readService: SwiftExifReadService
    private let writeEngine: any MetadataWriteEngine
    private let descriptiveWriteBoundary: DescriptiveMetadataWriteBoundary
    private let editorReadService: MetadataEditorReadService
    private let persistHistoryRestore: @Sendable (MetadataSidecarRestoreRequest) async -> MetadataSidecarPersistenceResult
    private let discardSidecar: @Sendable (URL, URL) async throws -> Void
    private let discardFolderSidecars: @Sendable (URL) async throws -> Void
    private let sidecarService = MetadataSidecarService()
    private let xmpSidecarService = XMPSidecarService()
    private let sidecarPersistenceService = MetadataSidecarPersistenceService()
    private let geocodingService = GeocodingService()
    private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "MetadataViewModel")
    private let perfLog = Logger(subsystem: "com.aagedal.photo-agent", category: "MetadataPerf")
    private var previousEditingMetadata: IPTCMetadata?

    /// Pending-on-disk metadata still needs an explicit Write, but merely reading it is not a
    /// new editor change. Caption capture advances `previousEditingMetadata` optimistically;
    /// its FIFO queue owns retries, so an unchanged exit must not enqueue the same draft again.
    var hasUnpersistedEditorChanges: Bool {
        guard hasChanges else { return false }
        guard selectedCount == 1 else { return true }
        return editingMetadata != previousEditingMetadata
    }

    /// The display reference may be the XMP copy of an existing pending draft. Keep that
    /// reference separate from the historical baseline, including an explicitly absent baseline
    /// in legacy JSON. The captured record is usable only for the current image and folder.
    private var pendingDraftImageMetadataSnapshot: IPTCMetadata? {
        if selectedURLs.count == 1,
           let baseline = cleanupBaseline,
           baseline.imageURL == selectedURLs.first,
           baseline.folderURL == currentFolderURL,
           let record = baseline.record {
            return record.imageMetadataSnapshot
        }
        return originalImageMetadata
    }
    @ObservationIgnored private var metadataLoadTask: Task<Void, Never>?
    @ObservationIgnored private var metadataLoadRequestID: UUID?
    @ObservationIgnored private var writeTask: Task<Void, Never>? {
        willSet {
            historyRestoreRequestID = nil
            writeTaskGeneration += 1
        }
    }
    @ObservationIgnored private var writeTaskGeneration = 0
    @ObservationIgnored private var historyRestoreRequestID: UUID?
    @ObservationIgnored private var discardTask: Task<Void, Never>?
    @ObservationIgnored private var discardRequestID: UUID?
    @ObservationIgnored private var batchProcessTask: Task<Void, Never>? {
        willSet { batchProcessGeneration += 1 }
    }
    @ObservationIgnored private var batchProcessGeneration = 0
    @ObservationIgnored private let pendingWriteDiscovery: @Sendable (URL) async -> PendingMetadataDiscoveryResult
    @ObservationIgnored private let pendingWriteExecutor: (@Sendable (PendingMetadataWriteRequest) async -> PendingMetadataWriteResult)?
    @ObservationIgnored private let variableInputLoader: (@MainActor @Sendable (URL, URL) async throws -> VariableMetadataInputSnapshot)?
    @ObservationIgnored private let variableWriteExecutor: (@Sendable (VariableMetadataWriteRequest) async -> VariableMetadataWriteResult)?
    @ObservationIgnored private let variableOptions: @MainActor () -> VariableMetadataOptions
    @ObservationIgnored private let variableResolver: @MainActor @Sendable (VariableMetadataResolutionInput) async throws -> IPTCMetadata
    @ObservationIgnored private var geocodingTask: Task<Void, Never>?
    @ObservationIgnored private var batchMetadataByURL: [URL: IPTCMetadata] = [:]

    init(
        readService: SwiftExifReadService,
        writeEngine: any MetadataWriteEngine,
        editorReadService: MetadataEditorReadService = .shared,
        persistHistoryRestore: @escaping @Sendable (MetadataSidecarRestoreRequest) async -> MetadataSidecarPersistenceResult = {
            await MetadataSidecarService().restoreSidecarAndMirrorXMP($0)
        },
        discardSidecar: @escaping @Sendable (URL, URL) async throws -> Void = { imageURL, folderURL in
            try await MetadataSidecarService().deleteSidecarSerialized(for: imageURL, in: folderURL)
        },
        discardFolderSidecars: @escaping @Sendable (URL) async throws -> Void = { folderURL in
            try await MetadataSidecarService().deleteAllSidecarsSerialized(in: folderURL)
        },
        pendingWriteDiscovery: @escaping @Sendable (URL) async -> PendingMetadataDiscoveryResult = {
            await MetadataSidecarService().discoverPendingSidecars(in: $0)
        },
        pendingWriteExecutor: (@Sendable (PendingMetadataWriteRequest) async -> PendingMetadataWriteResult)? = nil,
        variableInputLoader: (@MainActor @Sendable (URL, URL) async throws -> VariableMetadataInputSnapshot)? = nil,
        variableWriteExecutor: (@Sendable (VariableMetadataWriteRequest) async -> VariableMetadataWriteResult)? = nil,
        variableLifecycleCoordinator: VariableDraftLifecycleCoordinator = .shared,
        variableOptions: @escaping @MainActor () -> VariableMetadataOptions = { .capture() },
        variableResolver: @escaping @MainActor @Sendable (VariableMetadataResolutionInput) async throws -> IPTCMetadata = {
            try await VariableMetadataResolver.resolve($0)
        }
    ) {
        self.readService = readService
        self.writeEngine = writeEngine
        self.descriptiveWriteBoundary = DescriptiveMetadataWriteBoundary(writeEngine: writeEngine)
        self.editorReadService = editorReadService
        self.persistHistoryRestore = persistHistoryRestore
        self.discardSidecar = discardSidecar
        self.discardFolderSidecars = discardFolderSidecars
        self.pendingWriteDiscovery = pendingWriteDiscovery
        self.pendingWriteExecutor = pendingWriteExecutor
        self.variableInputLoader = variableInputLoader
        self.variableWriteExecutor = variableWriteExecutor
        self.variableLifecycleCoordinator = variableLifecycleCoordinator
        self.variableOptions = variableOptions
        self.variableResolver = variableResolver
    }

    deinit {
        metadataLoadTask?.cancel()
        writeTask?.cancel()
        batchProcessTask?.cancel()
        discardTask?.cancel()
        geocodingTask?.cancel()
    }

    var isBatchEdit: Bool { selectedCount > 1 }

    private func multiSelectMode(for field: String) -> MultiSelectFieldMode {
        switch field {
        case "keywords":
            let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.multiSelectKeywordsMode)
                ?? MultiSelectFieldMode.add.rawValue
            return MultiSelectFieldMode(rawValue: raw) ?? .add
        case "personShown":
            let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.multiSelectPersonShownMode)
                ?? MultiSelectFieldMode.add.rawValue
            return MultiSelectFieldMode(rawValue: raw) ?? .add
        default:
            return .overwrite
        }
    }

    /// PM record semantics: when a sidecar exists it is the metadata record, so it is
    /// always the default reference (the per-image reading chip lets the user inspect
    /// embedded values; a stale verdict overrides this to .embedded at load).
    private func defaultReferenceSource(hasXmp: Bool) -> MetadataReferenceSource {
        hasXmp ? .xmp : .embedded
    }

    private func referenceMetadata(
        for source: MetadataReferenceSource,
        embedded: IPTCMetadata?,
        xmp: IPTCMetadata?,
        imageURL: URL? = nil
    ) -> IPTCMetadata? {
        switch source {
        case .embedded:
            // Develop (CRS) edits made in this app always persist to the XMP
            // sidecar — the image file itself is never rewritten by the editor
            // (mandatory for RAW/C2PA, and the default for non-RAW too). So even
            // when the user prefers embedded IPTC, the sidecar is authoritative
            // for develop settings: override embedded CRS with non-empty XMP CRS
            // for ALL file types. This mirrors the grid loader
            // (BrowserViewModel.applyBatchMetadataResults); previously this was
            // gated to RAW only, which dropped develop edits for JPEG/JXL on
            // reload and left the develop view showing the unedited original.
            if let embedded,
               let xmpCRS = xmp?.cameraRaw, !xmpCRS.isEmpty {
                var result = embedded
                var finalCRS = xmpCRS
                if (xmpCRS.localAdjustments?.isEmpty ?? true),
                   let masks = embedded.cameraRaw?.localAdjustments, !masks.isEmpty {
                    finalCRS.localAdjustments = masks
                }
                result.cameraRaw = finalCRS
                return result
            }
            return embedded
        case .xmp:
            if let embedded, let xmp {
                // Photo Mechanic semantics: a sidecar with descriptive content IS the
                // IPTC record — take its descriptive fields wholesale so clears stick
                // instead of resurrecting embedded values through empty fields. A
                // develop-only sidecar (no descriptive content) is not a record;
                // overlay it additively so embedded descriptive values show through.
                var merged = xmp.hasDescriptiveContent
                    ? embedded.replacingDescriptiveFields(from: xmp)
                    : embedded.merged(preferring: xmp)
                // RAW: XMP sidecar is authoritative for CRS — replace, don't merge,
                // to avoid stale embedded values leaking through nil sidecar fields
                // (e.g. Adobe omitting Temperature even with WhiteBalance="Custom").
                if let url = imageURL, SupportedImageFormats.isRaw(url: url),
                   let xmpCRS = xmp.cameraRaw {
                    var finalCRS = xmpCRS
                    // Preserve localAdjustments from embedded (written to image directly, not to XMP sidecar)
                    if (xmpCRS.localAdjustments?.isEmpty ?? true),
                       let masks = embedded.cameraRaw?.localAdjustments, !masks.isEmpty {
                        finalCRS.localAdjustments = masks
                    }
                    merged.cameraRaw = finalCRS
                }
                return merged
            }
            return xmp ?? embedded
        }
    }

    private(set) var selectedHavePendingSidecars = false

    /// Reads a Copy Previous source without changing the current selection or editing buffer.
    /// Pending app sidecars win, followed by a current descriptive XMP record, then embedded
    /// metadata. This mirrors the normal single-image read path while remaining read-only.
    func loadCaptionCopyPreviousMetadata(for imageURL: URL) async throws -> IPTCMetadata {
        let folderURL = currentFolderURL ?? imageURL.deletingLastPathComponent()
        let embedded = try await readService.readFullMetadata(url: imageURL)
        let requestID = UUID()
        let result = await editorReadService.load(MetadataEditorReadRequest(
            id: requestID,
            imageURLs: [imageURL],
            folderURL: folderURL,
            embeddedMetadataByImageURL: [imageURL: embedded]
        ))
        guard !Task.isCancelled,
              case .complete(let snapshot) = result,
              snapshot.request.id == requestID,
              let facts = snapshot.factsByImageURL[imageURL] else {
            throw CancellationError()
        }
        let xmp = facts.xmpMetadata

        var resolved = embedded
        if let xmp {
            let sidecarIsStale = facts.reconciliationVerdict == .fileNewerConflict
            if !sidecarIsStale {
                resolved = xmp.hasDescriptiveContent
                    ? embedded.replacingDescriptiveFields(from: xmp)
                    : embedded.merged(preferring: xmp)
            }
        }

        if let sidecar = facts.appSidecar,
           sidecar.pendingChanges {
            let bestCameraRaw = resolved.cameraRaw ?? sidecar.metadata.cameraRaw
            let bestOrientation = resolved.exifOrientation
            resolved = sidecar.metadata
            resolved.cameraRaw = bestCameraRaw
            resolved.exifOrientation = bestOrientation
        }
        return resolved
    }

    func reportCaptionPersistenceFailure(_ message: String, requestID: UUID?) {
        saveError = message
        captionPersistenceFailureRequestID = requestID
    }

    func clearCaptionPersistenceFailure(requestID: UUID) {
        guard captionPersistenceFailureRequestID == requestID else { return }
        saveError = nil
    }

    func captionConflictEditorCheckpoint(for photoURL: URL) -> CaptionConflictEditorCheckpoint? {
        guard !isLoading, !isSaving, selectedURLs.count == 1,
              selectedURLs[0].resolvingSymlinksInPath().path == photoURL.resolvingSymlinksInPath().path else { return nil }
        return CaptionConflictEditorCheckpoint(photoURL: photoURL, folderURL: currentFolderURL,
            loadID: metadataLoadRequestID, metadata: editingMetadata)
    }

    /// This only reloads saved files. Queue recovery never writes or deletes those files.
    @discardableResult
    func reloadAfterCaptionConflictRecovery(_ checkpoint: CaptionConflictEditorCheckpoint, image: ImageFile) -> Bool {
        guard !isLoading, !isSaving, !hasUnpersistedEditorChanges, selectedURLs.count == 1,
              selectedURLs[0].resolvingSymlinksInPath().path == checkpoint.photoURL.resolvingSymlinksInPath().path,
              image.url.resolvingSymlinksInPath().path == checkpoint.photoURL.resolvingSymlinksInPath().path,
              currentFolderURL == checkpoint.folderURL, metadataLoadRequestID == checkpoint.loadID,
              editingMetadata == checkpoint.metadata else { return false }
        loadMetadata(for: [image], folderURL: checkpoint.folderURL)
        return true
    }

    func loadMetadata(for images: [ImageFile], folderURL: URL? = nil) {
        metadataLoadTask?.cancel()
        metadataLoadTask = nil
        if images.count == 1,
           let image = images.first,
           let phase = captionCleanupOwners[MetadataIOKey.key(for: image.url)] {
            isLoading = true
            metadataLoadTask = Task {
                await phase.waitUntilFinished()
                guard !Task.isCancelled else { return }
                metadataLoadTask = nil
                loadMetadata(for: images, folderURL: folderURL)
            }
            return
        }
        let requestID = UUID()
        metadataLoadRequestID = requestID

        // Snapshot BEFORE overwriting: the "reloading the same image/batch" checks below
        // must compare the new selection against what was previously loaded. Comparing
        // against the just-assigned selectedURLs is always true, which made every
        // navigation count as a same-image reload — carrying the previous file's
        // metadataReferenceSource to the next file. A file without a sidecar legitimately
        // lands on .embedded; the next (sidecar-backed) RAW then kept .embedded and showed
        // empty fields even though its .xmp was intact.
        let previousSelectedURLs = selectedURLs
        let selectionSnapshot = Set(images.map(\.url))
        let isReloadingSameBatch = images.count > 1
            && selectionSnapshot == Set(previousSelectedURLs)
            && batchCommonMetadata != nil

        selectedCount = images.count
        selectedURLs = images.map(\.url)
        hasChanges = false
        selectedHavePendingSidecars = false
        saveError = nil
        variableProcessingStatus = nil
        selectedHasC2PA = images.contains { $0.hasC2PA }
        descriptionConflict = nil
        sidecarHistory = []
        originalImageMetadata = nil
        embeddedMetadata = nil
        xmpMetadata = nil
        // Keep the displayed batch state intact across a redundant reload. Clearing it here
        // made `isReloadingSameBatch` impossible to detect and blanked/replaced fields while
        // the user was typing whenever a folder refresh reloaded the same selection.
        if !isReloadingSameBatch {
            batchCommonMetadata = nil
            batchDifferingFields = []
            batchPartialKeywords = []
            batchPartialPersonShown = []
            batchListSelectionSummary = .empty
            batchFieldMutations = [:]
            batchLocationsShownMutation = .untouched
            batchImageSupplierMutation = .untouched
            batchMetadataByURL = [:]
        }

        if let folderURL {
            currentFolderURL = folderURL
        }
        let folderSnapshot = currentFolderURL

        guard !images.isEmpty else {
            metadata = nil
            editingMetadata = IPTCMetadata()
            previousEditingMetadata = nil
            embeddedMetadata = nil
            xmpMetadata = nil
            isLoading = false
            isLoadingBatchMetadata = false
            batchMetadataByURL = [:]
            return
        }

        if images.count == 1 {
            batchMetadataByURL = [:]
            let imageURL = images[0].url

            // When reloading the same image (e.g. auto-refresh after external edit),
            // skip the synchronous reset to avoid flashing the preview to unedited state.
            let isReloadingSameImage = previousSelectedURLs.count == 1 && previousSelectedURLs.first == imageURL && metadata != nil
            if !isReloadingSameImage {
                metadata = nil
                editingMetadata = IPTCMetadata()
                previousEditingMetadata = nil
            }
            isLoading = true

            metadataLoadTask = Task {
                let loadStart = ContinuousClock.now
                self.perfLog.info("[MetadataVM] loadMetadata START — \(imageURL.lastPathComponent, privacy: .private(mask: .hash))")
                do {
                    let (embedded, conflict) = try await readService.readFullMetadataWithConflictCheck(url: imageURL)
                    let exifMs = loadStart.elapsedMilliseconds()
                    self.perfLog.info("[MetadataVM] metadata read returned — \(exifMs)ms for \(imageURL.lastPathComponent, privacy: .private(mask: .hash))")
                    guard !Task.isCancelled else { return }
                    let sidecarResult = await self.editorReadService.load(MetadataEditorReadRequest(
                        id: requestID,
                        imageURLs: [imageURL],
                        folderURL: folderSnapshot,
                        embeddedMetadataByImageURL: [imageURL: embedded]
                    ))
                    guard !Task.isCancelled,
                          case .complete(let sidecarSnapshot) = sidecarResult,
                          sidecarSnapshot.request.id == requestID,
                          self.metadataLoadRequestID == requestID,
                          self.currentFolderURL == folderSnapshot,
                          let sourceFacts = sidecarSnapshot.factsByImageURL[imageURL] else { return }
                    let xmpMeta = sourceFacts.xmpMetadata
                    // Reconcile embedded vs sidecar: the sidecar is master unless the image
                    // file was modified more recently and they disagree (e.g. Adobe Bridge
                    // wrote into the file after the sidecar), in which case the file is the
                    // trustworthy source. See SidecarReconciliation.
                    let sidecarIsStale = sourceFacts.reconciliationVerdict == .fileNewerConflict
                    // Preserve the user's manual reference source selection when
                    // reloading the same image (e.g. auto-refresh, post-save).
                    // Only fall back to the default on first load or if the
                    // previously selected source is no longer available.
                    let referenceSource: MetadataReferenceSource
                    if isReloadingSameImage,
                       !(self.metadataReferenceSource == .xmp && xmpMeta == nil) {
                        referenceSource = self.metadataReferenceSource
                    } else if sidecarIsStale {
                        // Stale sidecar → trust the embedded file by default; the comparison
                        // sheet lets the user merge per field.
                        referenceSource = .embedded
                    } else {
                        referenceSource = self.defaultReferenceSource(hasXmp: xmpMeta != nil)
                    }
                    let baseMeta = self.referenceMetadata(
                        for: referenceSource,
                        embedded: embedded,
                        xmp: xmpMeta,
                        imageURL: imageURL
                    ) ?? embedded
                    guard !Task.isCancelled else { return }
                    guard self.metadataLoadRequestID == requestID,
                          self.currentFolderURL == folderSnapshot,
                          self.selectedURLs.count == 1,
                          self.selectedURLs.first == imageURL else { return }
                    self.embeddedMetadata = embedded
                    self.descriptionConflict = conflict
                    self.xmpMetadata = xmpMeta
                    self.metadataReferenceSource = referenceSource
                    self.metadata = baseMeta
                    self.originalImageMetadata = baseMeta

                    self.cleanupBaseline = (imageURL, folderSnapshot, sourceFacts.appSidecar)
                    var newEditingMetadata = baseMeta
                    if let sidecar = sourceFacts.appSidecar {
                        self.sidecarHistory = sidecar.history
                        self.sidecarHistory.trimToHistoryLimit()
                        if sidecar.pendingChanges {
                            // Best CRS source: XMP/embedded (baseMeta) > JSON sidecar (fallback)
                            let bestCameraRaw = newEditingMetadata.cameraRaw
                                ?? sidecar.metadata.cameraRaw
                            let bestOrientation = newEditingMetadata.exifOrientation
                            newEditingMetadata = sidecar.metadata
                            newEditingMetadata.cameraRaw = bestCameraRaw
                            newEditingMetadata.exifOrientation = bestOrientation
                            self.hasChanges = true
                        }
                    }
                    // Always update on first load; optimize on reloads only.
                    if !isReloadingSameImage || self.editingMetadata != newEditingMetadata {
                        self.editingMetadata = newEditingMetadata
                    }
                    self.previousEditingMetadata = self.editingMetadata
                    self.metadataLoadGeneration += 1
                    let totalMs = loadStart.elapsedMilliseconds()
                    self.perfLog.info("[MetadataVM] loadMetadata DONE — \(imageURL.lastPathComponent, privacy: .private(mask: .hash)) total \(totalMs)ms")
                    self.logger.info("[\(imageURL.lastPathComponent, privacy: .private(mask: .hash))] loadMetadata result: xmp=\(xmpMeta != nil), stale=\(sidecarIsStale), ref=\(String(describing: referenceSource), privacy: .public), reloadSame=\(isReloadingSameImage), title=\(self.editingMetadata.title ?? "nil", privacy: .private(mask: .hash))")
                    if self.metadataReferenceSource == .xmp, self.xmpMetadata == nil {
                        self.metadataReferenceSource = .embedded
                    }
                } catch {
                    guard self.metadataLoadRequestID == requestID,
                          self.currentFolderURL == folderSnapshot,
                          self.selectedURLs == [imageURL] else { return }
                    self.metadata = nil
                    self.editingMetadata = IPTCMetadata()
                    self.previousEditingMetadata = nil
                    self.saveError = "Failed to load metadata: \(error.localizedDescription)"
                    self.logger.error("[\(imageURL.lastPathComponent, privacy: .private(mask: .hash))] loadMetadata FAILED: \(error.localizedDescription, privacy: .private)")
                }
                guard !Task.isCancelled else { return }
                guard self.metadataLoadRequestID == requestID,
                      self.currentFolderURL == folderSnapshot,
                      self.selectedURLs == [imageURL] else { return }
                self.isLoading = false
            }
        } else {
            // Batch mode: load metadata for all selected images and find common values
            //
            // When reloading the same batch (e.g. auto-refresh after external edit),
            // skip the synchronous editingMetadata reset to avoid blanking the fields
            // while the user is editing.  The async load will update only if values
            // actually changed — mirroring the single-image isReloadingSameImage
            // optimisation.
            if !isReloadingSameBatch {
                metadata = nil
                editingMetadata = IPTCMetadata()
                previousEditingMetadata = nil
                embeddedMetadata = nil
                xmpMetadata = nil
                metadataReferenceSource = .embedded
            }
            isLoadingBatchMetadata = true

            metadataLoadTask = Task {
                await loadBatchMetadata(
                    for: images,
                    selectionSnapshot: selectionSnapshot,
                    isReload: isReloadingSameBatch,
                    requestID: requestID,
                    folderURL: folderSnapshot
                )
                guard !Task.isCancelled else { return }
                guard self.metadataLoadRequestID == requestID,
                      self.currentFolderURL == folderSnapshot,
                      self.selectedURLs == images.map(\.url) else { return }
                self.isLoadingBatchMetadata = false
            }
        }
    }

    func applyReferenceSource(_ source: MetadataReferenceSource) {
        if source == .xmp, xmpMetadata == nil {
            metadataReferenceSource = .embedded
            return
        }
        metadataReferenceSource = source
        guard let reference = referenceMetadata(
            for: source,
            embedded: embeddedMetadata,
            xmp: xmpMetadata,
            imageURL: selectedURLs.count == 1 ? selectedURLs.first : nil
        ) else { return }

        originalImageMetadata = reference
        metadata = reference

        if !hasChanges {
            editingMetadata = reference
            previousEditingMetadata = reference
        }
    }

    /// Load metadata for all selected images and compute common values
    private func loadBatchMetadata(
        for images: [ImageFile],
        selectionSnapshot: Set<URL>,
        isReload: Bool = false,
        requestID: UUID,
        folderURL: URL?
    ) async {
        let urls = images.map(\.url)
        var allMetadata: [IPTCMetadata] = []
        var metadataByURL: [URL: IPTCMetadata] = [:]
        var hasPendingSidecar = false

        do {
            let batchResults = try await readService.readBatchFullMetadata(urls: urls)
            if Task.isCancelled { return }

            let sidecarResult = await editorReadService.load(MetadataEditorReadRequest(
                id: requestID,
                imageURLs: urls,
                folderURL: folderURL,
                embeddedMetadataByImageURL: batchResults,
                reconcilesSidecarTimestamps: false
            ))
            guard !Task.isCancelled,
                  case .complete(let sidecarSnapshot) = sidecarResult,
                  sidecarSnapshot.request.id == requestID else { return }

            for image in images {
                guard var meta = batchResults[image.url] else { continue }
                let sourceFacts = sidecarSnapshot.factsByImageURL[image.url]
                if let xmpMeta = sourceFacts?.xmpMetadata {
                    // Same record semantics as the single-image reference read: a
                    // descriptive sidecar IS the IPTC record (clears stick); a
                    // develop-only sidecar is overlaid additively.
                    meta = xmpMeta.hasDescriptiveContent
                        ? meta.replacingDescriptiveFields(from: xmpMeta)
                        : meta.merged(preferring: xmpMeta)
                }
                if let sidecar = sourceFacts?.appSidecar,
                   sidecar.pendingChanges {
                    hasPendingSidecar = true
                    let bestCameraRaw = meta.cameraRaw ?? sidecar.metadata.cameraRaw
                    let bestOrientation = meta.exifOrientation
                    meta = sidecar.metadata
                    meta.cameraRaw = bestCameraRaw
                    meta.exifOrientation = bestOrientation
                }
                allMetadata.append(meta)
                metadataByURL[image.url] = meta
            }
        } catch {
            logger.error("Failed to load batch metadata: \(error.localizedDescription)")
        }

        guard !allMetadata.isEmpty else { return }
        guard !Task.isCancelled else { return }
        guard metadataLoadRequestID == requestID,
              currentFolderURL == folderURL,
              selectedURLs == urls,
              Set(selectedURLs) == selectionSnapshot else { return }
        selectedHavePendingSidecars = hasPendingSidecar

        publishBatchMetadata(allMetadata, metadataByURL: metadataByURL, isReload: isReload)
    }

    private func publishBatchMetadata(_ allMetadata: [IPTCMetadata], metadataByURL: [URL: IPTCMetadata], isReload: Bool) {
        guard !allMetadata.isEmpty else { return }
        // Compute common values and differing fields
        var common = IPTCMetadata()
        var differing = Set<String>()

        // Optional fields
        compareOptionalField(allMetadata, keyPath: \.title, fieldName: "title", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.description, fieldName: "description", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.extendedDescription, fieldName: "extendedDescription", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.copyright, fieldName: "copyright", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.rightsUsageTerms, fieldName: "rightsUsageTerms", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.webStatementOfRights, fieldName: "webStatementOfRights", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.digitalImageGUID, fieldName: "digitalImageGUID", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.imageSupplierImageID, fieldName: "imageSupplierImageID", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.jobId, fieldName: "jobId", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.creatorJobTitle, fieldName: "creatorJobTitle", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.descriptionWriter, fieldName: "descriptionWriter", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.credit, fieldName: "credit", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.city, fieldName: "city", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.sublocation, fieldName: "sublocation", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.provinceState, fieldName: "provinceState", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.country, fieldName: "country", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.countryCode, fieldName: "countryCode", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.event, fieldName: "event", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.instructions, fieldName: "instructions", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.source, fieldName: "source", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.digitalSourceType, fieldName: "digitalSourceType", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.urgency, fieldName: "urgency", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.dateCreated, fieldName: "dateCreated", common: &common, differing: &differing)

        // Repeatable IPTC Bags use normalized membership. Creator is the ordered Seq exception:
        // only an identical sequence is common, so mixed order can never be propagated silently.
        let listSummary = Self.batchListSelectionSummary(for: allMetadata)
        common.keywords = listSummary.selection(for: .keywords).common
        common.personShown = listSummary.selection(for: .personShown).common
        common.organisationsShownNames = listSummary.selection(for: .organisationShownName).common
        common.organisationsShownCodes = listSummary.selection(for: .organisationShownCode).common
        common.sceneCodes = listSummary.selection(for: .sceneCode).common
        common.subjectCodes = listSummary.selection(for: .subjectCode).common
        let commonMediaTopicIDs = Set(listSummary.selection(for: .mediaTopic).common)
        common.mediaTopics = allMetadata[0].mediaTopics.filter { commonMediaTopicIDs.contains($0.termIdentifier) }
        let commonGenreIDs = Set(listSummary.selection(for: .genre).common)
        common.genres = allMetadata[0].genres.filter { commonGenreIDs.contains($0.termIdentifier) }
        common.creators = listSummary.selection(for: .creator).common
        common.locationsShown = listSummary.locationsShown.common

        for (field, differingName) in [
            (MetadataFieldID.keywords, "keywords"),
            (.personShown, "personShown"),
            (.organisationShownName, "organisationShownName"),
            (.organisationShownCode, "organisationShownCode"),
            (.sceneCode, "sceneCode"),
            (.subjectCode, "subjectCode"),
            (.mediaTopic, "mediaTopic"),
            (.genre, "genre"),
            (.creator, "creator"),
        ] where !listSummary.selection(for: field).partial.isEmpty {
            differing.insert(differingName)
        }
        if !listSummary.locationsShown.partial.isEmpty {
            differing.insert("locationsShown")
        }
        self.batchPartialKeywords = listSummary.selection(for: .keywords).partial
        self.batchPartialPersonShown = listSummary.selection(for: .personShown).partial
        self.batchListSelectionSummary = listSummary
        self.batchMetadataByURL = metadataByURL

        // GPS - check if all have the same coordinates
        let latitudes = allMetadata.compactMap(\.latitude)
        let longitudes = allMetadata.compactMap(\.longitude)
        if latitudes.count == allMetadata.count,
           longitudes.count == allMetadata.count,
           let firstLat = latitudes.first,
           let firstLon = longitudes.first,
           latitudes.allSatisfy({ abs($0 - firstLat) < 0.000001 }),
           longitudes.allSatisfy({ abs($0 - firstLon) < 0.000001 }) {
            common.latitude = firstLat
            common.longitude = firstLon
        } else if !latitudes.isEmpty || !longitudes.isEmpty {
            differing.insert("gps")
        }

        self.batchCommonMetadata = common
        self.batchDifferingFields = differing
        // Pre-populate editing metadata with common values.
        // On redundant reloads (same batch, e.g. auto-refresh), skip the
        // update when the loaded values match what's already displayed to
        // avoid overwriting the user's in-progress edits.
        if !isReload || self.editingMetadata != common {
            self.editingMetadata = common
            self.previousEditingMetadata = common
        }
    }

    private func compareOptionalField<T: Equatable>(
        _ allMetadata: [IPTCMetadata],
        keyPath: WritableKeyPath<IPTCMetadata, T?>,
        fieldName: String,
        common: inout IPTCMetadata,
        differing: inout Set<String>
    ) {
        let values = allMetadata.compactMap { $0[keyPath: keyPath] }
        if values.count == allMetadata.count,
           let first = values.first,
           values.allSatisfy({ $0 == first }) {
            common[keyPath: keyPath] = first
        } else if !values.isEmpty {
            differing.insert(fieldName)
        }
    }

    nonisolated static func batchListSelectionSummary(
        for allMetadata: [IPTCMetadata]
    ) -> BatchMetadataListSelectionSummary {
        guard !allMetadata.isEmpty else { return .empty }

        var repeatable: [MetadataFieldID: BatchListSelection<String>] = [:]
        for field in MetadataFieldID.allCases where field.isRepeatable {
            let lists = allMetadata.map {
                normalizedRepeatableValues(values(for: field, in: $0), field: field)
            }
            repeatable[field] = field == .creator
                ? summarizeOrderedLists(lists)
                : summarizeUnorderedLists(lists)
        }

        return BatchMetadataListSelectionSummary(
            repeatable: repeatable,
            locationsShown: summarizeUnorderedLists(
                allMetadata.map { normalizedLocations($0.locationsShown) }
            ),
            imageSuppliers: summarizeUnorderedLists(
                allMetadata.map { EditorialImageSupplier.normalizedValues($0.imageSuppliers) }
            )
        )
    }

    private nonisolated static func summarizeOrderedLists<Value: Hashable & Sendable>(
        _ lists: [[Value]]
    ) -> BatchListSelection<Value> {
        guard let first = lists.first else { return .empty }
        if lists.dropFirst().allSatisfy({ $0 == first }) {
            return BatchListSelection(common: first, partial: [])
        }
        var union: [Value] = []
        var seen = Set<Value>()
        for list in lists {
            union.append(contentsOf: list.filter { seen.insert($0).inserted })
        }
        return BatchListSelection(common: [], partial: union)
    }

    private nonisolated static func summarizeUnorderedLists<Value: Hashable & Sendable>(
        _ lists: [[Value]]
    ) -> BatchListSelection<Value> {
        guard let first = lists.first else { return .empty }
        let commonSet = lists.dropFirst().reduce(Set(first)) { result, values in
            result.intersection(values)
        }

        var unionOrder: [Value] = []
        var seen = Set<Value>()
        for values in lists {
            for value in values where seen.insert(value).inserted {
                unionOrder.append(value)
            }
        }
        return BatchListSelection(
            common: first.filter { commonSet.contains($0) },
            partial: unionOrder.filter { !commonSet.contains($0) }
        )
    }

    private nonisolated static func values(
        for field: MetadataFieldID,
        in metadata: IPTCMetadata
    ) -> [String] {
        switch field {
        case .creator: metadata.creators
        case .keywords: metadata.keywords
        case .personShown: metadata.personShown
        case .organisationShownName: metadata.organisationsShownNames
        case .organisationShownCode: metadata.organisationsShownCodes
        case .sceneCode: metadata.sceneCodes
        case .subjectCode: metadata.subjectCodes
        case .mediaTopic: metadata.mediaTopics.map(\.termIdentifier)
        case .genre: metadata.genres.map(\.termIdentifier)
        default: []
        }
    }

    private nonisolated static func normalizedRepeatableValues(
        _ values: [String],
        field: MetadataFieldID
    ) -> [String] {
        let trimmed = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniqued()
        if field == .sceneCode {
            return IPTCSceneCode.normalizedValues(trimmed.map(IPTCSceneCode.normalizedEditorValue))
        }
        if field == .subjectCode {
            return IPTCSubjectCode.normalizedValues(trimmed)
        }
        if field == .mediaTopic {
            return IPTCControlledVocabularyTerm.normalizedValues(
                trimmed.compactMap { IPTCControlledVocabularyTerm.mediaTopic(metadataValue: $0) }
            ).map(\.termIdentifier)
        }
        if field == .genre {
            return IPTCControlledVocabularyTerm.normalizedValues(
                trimmed.compactMap { IPTCControlledVocabularyTerm.genre(metadataValue: $0) }
            ).map(\.termIdentifier)
        }
        return trimmed
    }

    private nonisolated static func normalizedLocations(
        _ locations: [EditorialLocation]
    ) -> [EditorialLocation] {
        locations.compactMap { location in
            var normalized = location
            normalized.identifiers = location.identifiers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .uniqued()
                .sorted()
            normalized.name = normalizedText(location.name)
            normalized.sublocation = normalizedText(location.sublocation)
            normalized.city = normalizedText(location.city)
            normalized.provinceState = normalizedText(location.provinceState)
            normalized.countryName = normalizedText(location.countryName)
            normalized.countryCode = ISO3166Country.normalizedAlpha3(normalizedText(location.countryCode))
            normalized.worldRegion = normalizedText(location.worldRegion)
            return normalized.isEmpty ? nil : normalized
        }.uniqued()
    }

    private nonisolated static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Records explicit append/replace/clear intent for one repeatable field. The common-value
    /// projection is only a preview; persistence applies the operation independently to each
    /// selected record, so partial values cannot be mistaken for absent values.
    func setBatchMutation(
        _ mutation: MetadataFieldMutation,
        for field: MetadataFieldID
    ) throws {
        guard isBatchEdit else { throw BatchListSelectionError.batchSelectionRequired }
        guard field.isRepeatable else { throw BatchListSelectionError.repeatableFieldRequired(field) }

        var proposed = batchFieldMutations
        if mutation == .untouched {
            proposed.removeValue(forKey: field)
        } else {
            proposed[field] = mutation
        }
        let preview = try Self.applyingBatchListMutations(
            proposed,
            locationsShown: batchLocationsShownMutation,
            imageSuppliers: batchImageSupplierMutation,
            to: batchCommonMetadata ?? IPTCMetadata()
        )
        batchFieldMutations = proposed
        copyBatchLists(from: preview, into: &editingMetadata)
        // This API owns only the explicit list intent. Never clear dirty state here: scalar
        // fields may already have pending edits that are intentionally independent of it.
        if !batchFieldMutations.isEmpty || batchLocationsShownMutation != .untouched
            || batchImageSupplierMutation != .untouched {
            hasChanges = true
        }
    }

    func setBatchLocationsShownMutation(
        _ mutation: BatchLocationsShownMutation
    ) throws {
        guard isBatchEdit else { throw BatchListSelectionError.batchSelectionRequired }
        let preview = try Self.applyingBatchListMutations(
            batchFieldMutations,
            locationsShown: mutation,
            imageSuppliers: batchImageSupplierMutation,
            to: batchCommonMetadata ?? IPTCMetadata()
        )
        batchLocationsShownMutation = mutation
        copyBatchLists(from: preview, into: &editingMetadata)
        if !batchFieldMutations.isEmpty || mutation != .untouched
            || batchImageSupplierMutation != .untouched {
            hasChanges = true
        }
    }

    func setBatchImageSupplierMutation(
        _ mutation: EditorialImageSupplierMutation
    ) throws {
        guard isBatchEdit else { throw BatchListSelectionError.batchSelectionRequired }
        switch mutation {
        case let .append(values) where EditorialImageSupplier.normalizedValues(values).isEmpty:
            throw BatchListSelectionError.emptyImageSupplierAppend
        case let .replace(values) where EditorialImageSupplier.normalizedValues(values).isEmpty:
            throw BatchListSelectionError.emptyImageSupplierReplace
        default:
            break
        }
        let preview = try Self.applyingBatchListMutations(
            batchFieldMutations,
            locationsShown: batchLocationsShownMutation,
            imageSuppliers: mutation,
            to: batchCommonMetadata ?? IPTCMetadata()
        )
        batchImageSupplierMutation = mutation
        copyBatchLists(from: preview, into: &editingMetadata)
        if !batchFieldMutations.isEmpty || batchLocationsShownMutation != .untouched
            || mutation != .untouched {
            hasChanges = true
        }
    }

    nonisolated static func applyingBatchListMutations(
        _ mutations: [MetadataFieldID: MetadataFieldMutation],
        locationsShown: BatchLocationsShownMutation = .untouched,
        imageSuppliers: EditorialImageSupplierMutation = .untouched,
        to metadata: IPTCMetadata
    ) throws -> IPTCMetadata {
        var result = metadata
        for field in MetadataFieldID.allCases where field.isRepeatable {
            guard let mutation = mutations[field] else { continue }
            try result.apply(mutation, to: field)
        }

        switch locationsShown {
        case .untouched:
            break
        case .clear:
            result.locationsShown = []
        case .append(let locations):
            let normalized = normalizedLocations(locations)
            guard !normalized.isEmpty else { throw BatchListSelectionError.emptyLocationAppend }
            result.locationsShown = normalizedLocations(result.locationsShown + normalized)
        case .replace(let locations):
            let normalized = normalizedLocations(locations)
            guard !normalized.isEmpty else { throw BatchListSelectionError.emptyLocationReplace }
            result.locationsShown = normalized
        }
        result.imageSuppliers = imageSuppliers.apply(to: result.imageSuppliers)
        return result
    }

    private func copyBatchLists(from source: IPTCMetadata, into target: inout IPTCMetadata) {
        target.keywords = source.keywords
        target.personShown = source.personShown
        target.organisationsShownNames = source.organisationsShownNames
        target.organisationsShownCodes = source.organisationsShownCodes
        target.sceneCodes = source.sceneCodes
        target.subjectCodes = source.subjectCodes
        target.mediaTopics = source.mediaTopics
        target.genres = source.genres
        target.creators = source.creators
        target.locationsShown = source.locationsShown
        target.imageSuppliers = source.imageSuppliers
    }

    func promotePartialKeyword(_ keyword: String) {
        switch ApprovedListService.shared.validate(keyword, in: .keywords) {
        case .reject(let reason):
            notice = MetadataPanelNotice(
                title: "Keyword not added — \(reason)",
                detail: [keyword],
                severity: .warning
            )
            return
        case .accept:
            if !editingMetadata.keywords.contains(keyword) {
                editingMetadata.keywords.append(keyword)
            }
        case .acceptCanonical(let canonical):
            if !editingMetadata.keywords.contains(canonical) {
                editingMetadata.keywords.append(canonical)
            }
        }
        batchPartialKeywords.removeAll { $0 == keyword }
        hasChanges = true
    }

    func promotePartialPerson(_ person: String) {
        if !editingMetadata.personShown.contains(person) {
            editingMetadata.personShown.append(person)
        }
        batchPartialPersonShown.removeAll { $0 == person }
        hasChanges = true
    }

    /// Returns the placeholder text for a batch field that has differing values
    func batchPlaceholder(for field: String) -> String {
        if batchDifferingFields.contains(field) {
            return "Multiple values"
        }
        return "Leave empty to skip"
    }

    /// Returns true if a field has differing values across the batch selection
    func fieldHasMultipleValues(_ field: String) -> Bool {
        batchDifferingFields.contains(field)
    }

    func markChanged() {
        hasChanges = true
    }

    /// Append `incoming` to `editingMetadata.keywords`, skipping empties and entries
    /// already present (case-sensitive). Returns the count actually added.
    /// Calls `markChanged()` when at least one keyword was added.
    @discardableResult
    func appendKeywords(_ incoming: [String]) -> Int {
        var current = editingMetadata.keywords
        var seen = Set(current)
        var addedCount = 0
        for keyword in incoming {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !seen.contains(trimmed) {
                seen.insert(trimmed)
                current.append(trimmed)
                addedCount += 1
            }
        }
        guard addedCount > 0 else { return 0 }
        editingMetadata.keywords = current
        markChanged()
        return addedCount
    }

    /// Appends trimmed, de-duplicated names to `personShown`, preserving order.
    /// Returns the number actually added; calls `markChanged()` when non-zero.
    @discardableResult
    func appendPersonShown(_ incoming: [String]) -> Int {
        var current = editingMetadata.personShown
        var seen = Set(current)
        var addedCount = 0
        for name in incoming {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                current.append(trimmed)
                addedCount += 1
            }
        }
        guard addedCount > 0 else { return 0 }
        editingMetadata.personShown = current
        markChanged()
        return addedCount
    }

    func resolveDescriptionConflict(keepXMP: Bool) {
        guard let conflict = descriptionConflict else { return }
        editingMetadata.description = keepXMP ? conflict.xmpDescription : conflict.iptcCaptionAbstract
        descriptionConflict = nil
        markChanged()
    }

    /// Clears Camera Raw develop + crop edits from the live editing session in memory.
    /// Call right after `BrowserViewModel.resetAllEditsOnSelected` so the develop editor
    /// reflects the reset immediately — without this, reopening the editor reads the
    /// not-yet-rewritten file/sidecar and resurrects the just-removed edits (the async
    /// XMP rewrite can land seconds later). Mirrors the clear across the reference copies
    /// so it isn't seen as a pending change, and bumps the generation to force a re-render.
    func resetCameraRawEdits() {
        editingMetadata.cameraRaw = nil
        originalImageMetadata?.cameraRaw = nil
        metadata?.cameraRaw = nil
        previousEditingMetadata?.cameraRaw = nil
        metadataLoadGeneration += 1
    }

    func importEmbeddedCrop() {
        guard let embeddedCrop = embeddedMetadata?.cameraRaw?.crop,
              embeddedCrop.hasCrop == true else { return }
        if editingMetadata.cameraRaw == nil {
            editingMetadata.cameraRaw = CameraRawSettings()
        }
        editingMetadata.cameraRaw?.crop = embeddedCrop
        markChanged()
    }

    /// Writes the editing buffer to the destination the mode dictates. A file-writing
    /// mode writes into C2PA files without ceremony — only the Simple preset resolves
    /// C2PA to `.writeToFile`, and Simple deliberately ignores content credentials
    /// (Professional and Custom route C2PA to sidecar-only modes upstream).
    func commitEdits(
        mode: MetadataWriteMode,
        onComplete: (() -> Void)? = nil
    ) {
        commitEditsReportingResult(mode: mode) { _ in
            onComplete?()
        }
    }

    /// Reports the result of the exact commit request to an external lifecycle owner.
    /// `historyOnly` retains its established fire-and-forget contract; Develop uses the two
    /// durable modes whose completions occur only after their metadata/history work finishes.
    func commitEditsReportingResult(
        mode: MetadataWriteMode,
        onComplete: @escaping (MetadataCommitResult) -> Void
    ) {
        switch mode {
        case .historyOnly:
            saveToSidecar()
            onComplete(.succeeded)
        case .writeToXMPSidecar:
            writeXMPSidecarAndPreserveHistory(onComplete: onComplete)
        case .writeToFile, .writeToFileAndXMPSidecar:
            writeMetadataAndPreserveHistory(alsoWriteXMPSidecar: mode.writesXMPSidecar, onComplete: onComplete)
        }
    }

    func writeMetadata() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let selectionSnapshot = Set(urls)
        let writeFolderURL = currentFolderURL
        let edited = editingMetadata
        let original = metadata
        let isBatch = isBatchEdit
        let prevEditing = previousEditingMetadata
        let explicitBatchMutations = batchFieldMutations
        let explicitLocationsShownMutation = batchLocationsShownMutation
        let resolvedBatchSnapshot = batchMetadataByURL
        isSaving = true
        saveError = nil

        writeTask?.cancel()
        writeTask = Task {
            do {
                if let writeFolderURL {
                    for url in urls {
                        try await sidecarService.requireNoPendingOrientation(for: url, in: writeFolderURL)
                    }
                }
                var fields: [MetadataFieldKey: String] = [:]

                if isBatch {
                    // Batch: only write non-empty fields
                    if let v = edited.title, !v.isEmpty { fields[.headline] = v }
                    if let v = edited.description, !v.isEmpty { fields[.description] = v }
                    if let v = edited.extendedDescription, !v.isEmpty { fields[.extendedDescription] = v }

                    // Keywords — check add vs overwrite mode
                    let keywordsMode = self.multiSelectMode(for: "keywords")
                    if keywordsMode == .overwrite {
                        if !edited.keywords.isEmpty {
                            fields[.subject] = edited.keywords.joined(separator: ", ")
                        }
                    }
                    // Add mode keywords handled below via addRemoveListValues

                    // Person Shown — check add vs overwrite mode
                    let personMode = self.multiSelectMode(for: "personShown")
                    if personMode == .overwrite {
                        if !edited.personShown.isEmpty {
                            fields[.personInImage] = edited.personShown.joined(separator: ", ")
                        }
                    }
                    // Add mode personShown handled below via addRemoveListValues

                    if let v = edited.digitalSourceType { fields[.digitalSourceType] = v.newsCodeURI }
                    if let v = edited.urgency { fields[.urgency] = String(v) }
                    if let lat = edited.latitude, let lon = edited.longitude {
                        fields[.gpsLatitude] = String(abs(lat))
                        fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
                        fields[.gpsLongitude] = String(abs(lon))
                        fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
                    }
                    if let v = edited.creatorTransportValue { fields[.creator] = v }
                    if let v = edited.creatorJobTitle, !v.isEmpty { fields[.creatorJobTitle] = v }
                    if let v = edited.descriptionWriter, !v.isEmpty { fields[.descriptionWriter] = v }
                    if let v = edited.credit, !v.isEmpty { fields[.credit] = v }
                    if let v = edited.copyright, !v.isEmpty { fields[.rights] = v }
                    if let v = edited.rightsUsageTerms, !v.isEmpty { fields[.rightsUsageTerms] = v }
                    if let v = edited.webStatementOfRights, !v.isEmpty { fields[.webStatementOfRights] = v }
                    if let v = edited.digitalImageGUID, !v.isEmpty { fields[.digitalImageGUID] = v }
                    if let v = edited.imageSupplierImageID, !v.isEmpty { fields[.imageSupplierImageID] = v }
                    if let v = edited.jobId, !v.isEmpty { fields[.transmissionReference] = v }
                    if let v = edited.dateCreated, !v.isEmpty { fields[.dateCreated] = v }
                    if let v = edited.city, !v.isEmpty { fields[.city] = v }
                    if let v = edited.sublocation, !v.isEmpty { fields[.sublocation] = v }
                    if let v = edited.provinceState, !v.isEmpty { fields[.provinceState] = v }
                    if let v = edited.country, !v.isEmpty { fields[.country] = v }
                    if let v = edited.countryCode, !v.isEmpty { fields[.countryCode] = v }
                    if let v = edited.event, !v.isEmpty { fields[.event] = v }
                    if let v = edited.instructions, !v.isEmpty { fields[.instructions] = v }
                    if let v = edited.source, !v.isEmpty { fields[.source] = v }
                } else {
                    // Single: write all changed fields
                    if edited.title != original?.title { fields[.headline] = edited.title ?? "" }
                    if edited.description != original?.description { fields[.description] = edited.description ?? "" }
                    if edited.extendedDescription != original?.extendedDescription {
                        fields[.extendedDescription] = edited.extendedDescription ?? ""
                    }
                    if edited.keywords != original?.keywords {
                        // Clear then set keywords
                        fields[.subject] = edited.keywords.uniqued().joined(separator: ", ")
                    }
                    if edited.personShown != original?.personShown {
                        fields[.personInImage] = edited.personShown.uniqued().joined(separator: ", ")
                    }
                    if edited.organisationsShownNames != original?.organisationsShownNames {
                        fields[.organisationInImageName] = edited.organisationsShownNames.uniqued().joined(separator: ", ")
                    }
                    if edited.organisationsShownCodes != original?.organisationsShownCodes {
                        fields[.organisationInImageCode] = edited.organisationsShownCodes.uniqued().joined(separator: ", ")
                    }
                    if edited.sceneCodes != original?.sceneCodes {
                        fields[.scene] = edited.sceneCodes.uniqued().joined(separator: ", ")
                    }
                    if edited.subjectCodes != original?.subjectCodes {
                        fields[.subjectCode] = edited.subjectCodes.uniqued().joined(separator: ", ")
                    }
                    if edited.mediaTopics != original?.mediaTopics {
                        fields[.mediaTopic] = edited.mediaTopics.map(\.termIdentifier).joined(separator: ", ")
                    }
                    if edited.genres != original?.genres {
                        fields[.genre] = edited.genres.map(\.termIdentifier).joined(separator: ", ")
                    }
                    if edited.digitalSourceType != original?.digitalSourceType {
                        fields[.digitalSourceType] = edited.digitalSourceType?.newsCodeURI ?? ""
                    }
                    if edited.urgency != original?.urgency {
                        fields[.urgency] = edited.urgency.map(String.init) ?? ""
                    }
                    if edited.latitude != original?.latitude || edited.longitude != original?.longitude {
                        if let lat = edited.latitude, let lon = edited.longitude {
                            fields[.gpsLatitude] = String(abs(lat))
                            fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
                            fields[.gpsLongitude] = String(abs(lon))
                            fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
                        } else {
                            fields[.gpsLatitude] = ""
                            fields[.gpsLatitudeRef] = ""
                            fields[.gpsLongitude] = ""
                            fields[.gpsLongitudeRef] = ""
                        }
                    }
                    if edited.creators != original?.creators {
                        fields[.creator] = edited.creatorTransportValue ?? ""
                    }
                    if edited.creatorJobTitle != original?.creatorJobTitle { fields[.creatorJobTitle] = edited.creatorJobTitle ?? "" }
                    if edited.descriptionWriter != original?.descriptionWriter { fields[.descriptionWriter] = edited.descriptionWriter ?? "" }
                    if edited.credit != original?.credit { fields[.credit] = edited.credit ?? "" }
                    if edited.copyright != original?.copyright { fields[.rights] = edited.copyright ?? "" }
                    if edited.rightsUsageTerms != original?.rightsUsageTerms { fields[.rightsUsageTerms] = edited.rightsUsageTerms ?? "" }
                    if edited.webStatementOfRights != original?.webStatementOfRights { fields[.webStatementOfRights] = edited.webStatementOfRights ?? "" }
                    if edited.digitalImageGUID != original?.digitalImageGUID { fields[.digitalImageGUID] = edited.digitalImageGUID ?? "" }
                    if edited.imageSupplierImageID != original?.imageSupplierImageID { fields[.imageSupplierImageID] = edited.imageSupplierImageID ?? "" }
                    if edited.jobId != original?.jobId {
                        fields[.transmissionReference] = edited.jobId ?? ""
                    }
                    if edited.dateCreated != original?.dateCreated { fields[.dateCreated] = edited.dateCreated ?? "" }
                    if edited.city != original?.city { fields[.city] = edited.city ?? "" }
                    if edited.sublocation != original?.sublocation { fields[.sublocation] = edited.sublocation ?? "" }
                    if edited.provinceState != original?.provinceState { fields[.provinceState] = edited.provinceState ?? "" }
                    if edited.country != original?.country { fields[.country] = edited.country ?? "" }
                    if edited.countryCode != original?.countryCode { fields[.countryCode] = edited.countryCode ?? "" }
                    if edited.event != original?.event { fields[.event] = edited.event ?? "" }
                    if edited.instructions != original?.instructions { fields[.instructions] = edited.instructions ?? "" }
                    if edited.source != original?.source { fields[.source] = edited.source ?? "" }
                }

                if isBatch {
                    Self.applyExplicitBatchWriteFields(explicitBatchMutations, into: &fields)
                }

                let structuredEditorialChanged = !isBatch && (
                    edited.creatorContactInfo != original?.creatorContactInfo
                        || Set(edited.locationsCreated) != Set(original?.locationsCreated ?? [])
                        || Set(edited.locationsShown) != Set(original?.locationsShown ?? [])
                        || Set(edited.mediaTopics) != Set(original?.mediaTopics ?? [])
                        || Set(edited.genres) != Set(original?.genres ?? [])
                )
                if !fields.isEmpty || structuredEditorialChanged {
                    let structuredData = StructuredWriteData(
                        editorial: structuredEditorialChanged
                            ? EditorialStructuredWriteData(metadata: edited)
                            : nil
                    )
                    try await writeEngine.writeFields(fields, to: urls, structuredData: structuredData)
                }

                // Handle additive list fields via += / -=
                if isBatch, let prev = prevEditing {
                    let diffs = additiveListDiffs(
                        from: edited,
                        previous: prev,
                        explicitMutations: explicitBatchMutations
                    )
                    if !diffs.add.isEmpty || !diffs.remove.isEmpty {
                        try await writeEngine.addRemoveListValues(
                            add: diffs.add,
                            remove: diffs.remove,
                            to: urls
                        )
                    }
                }

                if isBatch, explicitLocationsShownMutation != .untouched {
                    for url in urls {
                        let base: IPTCMetadata
                        if let resolved = resolvedBatchSnapshot[url] {
                            base = resolved
                        } else {
                            base = try await self.readService.readFullMetadata(url: url)
                        }
                        let updated = try Self.applyingBatchListMutations(
                            [:],
                            locationsShown: explicitLocationsShownMutation,
                            to: base
                        )
                        try await writeEngine.writeFields(
                            [:],
                            to: [url],
                            structuredData: StructuredWriteData(
                                editorial: EditorialStructuredWriteData(metadata: updated)
                            )
                        )
                    }
                }

                let controlledStructuredMutations = explicitBatchMutations.filter {
                    $0.key == .mediaTopic || $0.key == .genre
                }
                if isBatch, !controlledStructuredMutations.isEmpty {
                    for url in urls {
                        let base: IPTCMetadata
                        if let resolved = resolvedBatchSnapshot[url] {
                            base = resolved
                        } else {
                            base = try await self.readService.readFullMetadata(url: url)
                        }
                        let updated = try MetadataFieldMutationSet(controlledStructuredMutations)
                            .applying(to: base)
                        try await writeEngine.writeFields(
                            [:],
                            to: [url],
                            structuredData: StructuredWriteData(
                                editorial: EditorialStructuredWriteData(metadata: updated)
                            )
                        )
                    }
                }

                await self.mirrorEmbeddedStateToExistingSidecars(for: urls)

                if Set(self.selectedURLs) == selectionSnapshot {
                    self.metadata = edited
                    self.hasChanges = false
                }
            } catch {
                self.saveError = error.localizedDescription
            }
            self.isSaving = false
        }
    }

    private func batchWriteFields(from metadata: IPTCMetadata) -> [MetadataFieldKey: String] {
        var fields: [MetadataFieldKey: String] = [:]
        if let v = metadata.title, !v.isEmpty { fields[.headline] = v }
        if let v = metadata.description, !v.isEmpty { fields[.description] = v }
        if let v = metadata.extendedDescription, !v.isEmpty { fields[.extendedDescription] = v }
        if multiSelectMode(for: "keywords") == .overwrite, !metadata.keywords.isEmpty {
            fields[.subject] = metadata.keywords.joined(separator: ", ")
        }
        if multiSelectMode(for: "personShown") == .overwrite, !metadata.personShown.isEmpty {
            fields[.personInImage] = metadata.personShown.joined(separator: ", ")
        }
        if let v = metadata.digitalSourceType { fields[.digitalSourceType] = v.newsCodeURI }
        if let v = metadata.urgency { fields[.urgency] = String(v) }
        if let v = metadata.creatorTransportValue { fields[.creator] = v }
        if let v = metadata.creatorJobTitle, !v.isEmpty { fields[.creatorJobTitle] = v }
        if let v = metadata.descriptionWriter, !v.isEmpty { fields[.descriptionWriter] = v }
        if let v = metadata.credit, !v.isEmpty { fields[.credit] = v }
        if let v = metadata.copyright, !v.isEmpty { fields[.rights] = v }
        if let v = metadata.rightsUsageTerms, !v.isEmpty { fields[.rightsUsageTerms] = v }
        if let v = metadata.webStatementOfRights, !v.isEmpty { fields[.webStatementOfRights] = v }
        if let v = metadata.digitalImageGUID, !v.isEmpty { fields[.digitalImageGUID] = v }
        if let v = metadata.imageSupplierImageID, !v.isEmpty { fields[.imageSupplierImageID] = v }
        if let v = metadata.jobId, !v.isEmpty { fields[.transmissionReference] = v }
        if let v = metadata.dateCreated, !v.isEmpty { fields[.dateCreated] = v }
        if let v = metadata.city, !v.isEmpty { fields[.city] = v }
        if let v = metadata.sublocation, !v.isEmpty { fields[.sublocation] = v }
        if let v = metadata.provinceState, !v.isEmpty { fields[.provinceState] = v }
        if let v = metadata.country, !v.isEmpty { fields[.country] = v }
        if let v = metadata.countryCode, !v.isEmpty { fields[.countryCode] = v }
        if let v = metadata.event, !v.isEmpty { fields[.event] = v }
        if let v = metadata.instructions, !v.isEmpty { fields[.instructions] = v }
        if let v = metadata.source, !v.isEmpty { fields[.source] = v }
        if let lat = metadata.latitude, let lon = metadata.longitude {
            fields[.gpsLatitude] = String(abs(lat))
            fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
            fields[.gpsLongitude] = String(abs(lon))
            fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
        }
        appendCameraRawFields(from: metadata, into: &fields)
        return fields
    }

    private nonisolated static func applyExplicitBatchWriteFields(
        _ mutations: [MetadataFieldID: MetadataFieldMutation],
        into fields: inout [MetadataFieldKey: String]
    ) {
        for field in MetadataFieldID.allCases where field.isRepeatable {
            guard let mutation = mutations[field] else { continue }
            switch mutation {
            case .untouched:
                fields.removeValue(forKey: field.metadataWriteKey)
            case .append:
                // Appends use the typed add/remove writer path below; never also overwrite the
                // field with the common-value preview.
                fields.removeValue(forKey: field.metadataWriteKey)
            case .clear:
                fields[field.metadataWriteKey] = ""
            case .overwrite:
                guard let updated = try? applyingBatchListMutations(
                    [field: mutation],
                    to: IPTCMetadata()
                ) else { continue }
                if field == .creator {
                    fields[field.metadataWriteKey] = updated.creatorTransportValue ?? ""
                } else {
                    fields[field.metadataWriteKey] = values(for: field, in: updated)
                        .joined(separator: ", ")
                }
            }
        }
    }

    /// Compute add/remove diffs for list fields in add mode, relative to previousEditingMetadata.
    private func additiveListDiffs(
        from edited: IPTCMetadata,
        previous: IPTCMetadata,
        explicitMutations: [MetadataFieldID: MetadataFieldMutation]
    ) -> (add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]]) {
        var addTags: [MetadataFieldKey: [String]] = [:]
        var removeTags: [MetadataFieldKey: [String]] = [:]

        for field in MetadataFieldID.allCases where field.isRepeatable {
            guard case .append(let values)? = explicitMutations[field] else { continue }
            let normalized = Self.normalizedRepeatableValues(values, field: field)
            if !normalized.isEmpty {
                addTags[field.metadataWriteKey] = normalized
            }
        }

        if explicitMutations[.keywords] == nil, multiSelectMode(for: "keywords") == .add {
            let added = Array(Set(edited.keywords).subtracting(previous.keywords))
            let removed = Array(Set(previous.keywords).subtracting(edited.keywords))
            if !added.isEmpty { addTags[.subject] = added }
            if !removed.isEmpty { removeTags[.subject] = removed }
        }

        if explicitMutations[.personShown] == nil, multiSelectMode(for: "personShown") == .add {
            let added = Array(Set(edited.personShown).subtracting(previous.personShown))
            let removed = Array(Set(previous.personShown).subtracting(edited.personShown))
            if !added.isEmpty { addTags[.personInImage] = added }
            if !removed.isEmpty { removeTags[.personInImage] = removed }
        }

        if explicitMutations[.organisationShownName] == nil {
            let previousOrganisationNames = Set(previous.organisationsShownNames)
            let editedOrganisationNames = Set(edited.organisationsShownNames)
            let addedOrganisationNames = edited.organisationsShownNames.filter { !previousOrganisationNames.contains($0) }
            let removedOrganisationNames = previous.organisationsShownNames.filter { !editedOrganisationNames.contains($0) }
            if !addedOrganisationNames.isEmpty { addTags[.organisationInImageName] = addedOrganisationNames }
            if !removedOrganisationNames.isEmpty { removeTags[.organisationInImageName] = removedOrganisationNames }
        }

        if explicitMutations[.organisationShownCode] == nil {
            let previousOrganisationCodes = Set(previous.organisationsShownCodes)
            let editedOrganisationCodes = Set(edited.organisationsShownCodes)
            let addedOrganisationCodes = edited.organisationsShownCodes.filter { !previousOrganisationCodes.contains($0) }
            let removedOrganisationCodes = previous.organisationsShownCodes.filter { !editedOrganisationCodes.contains($0) }
            if !addedOrganisationCodes.isEmpty { addTags[.organisationInImageCode] = addedOrganisationCodes }
            if !removedOrganisationCodes.isEmpty { removeTags[.organisationInImageCode] = removedOrganisationCodes }
        }

        if explicitMutations[.sceneCode] == nil {
            let previousSceneCodes = Set(previous.sceneCodes)
            let editedSceneCodes = Set(edited.sceneCodes)
            let addedSceneCodes = edited.sceneCodes.filter { !previousSceneCodes.contains($0) }
            let removedSceneCodes = previous.sceneCodes.filter { !editedSceneCodes.contains($0) }
            if !addedSceneCodes.isEmpty { addTags[.scene] = addedSceneCodes }
            if !removedSceneCodes.isEmpty { removeTags[.scene] = removedSceneCodes }
        }


        if explicitMutations[.subjectCode] == nil {
            let previousCodes = Set(previous.subjectCodes)
            let editedCodes = Set(edited.subjectCodes)
            let addedCodes = edited.subjectCodes.filter { !previousCodes.contains($0) }
            let removedCodes = previous.subjectCodes.filter { !editedCodes.contains($0) }
            if !addedCodes.isEmpty { addTags[.subjectCode] = addedCodes }
            if !removedCodes.isEmpty { removeTags[.subjectCode] = removedCodes }
        }

        return (addTags, removeTags)
    }

    /// PM-style writeToFile invariant: an `.xmp` already on disk must mirror the file,
    /// or its stale descriptive values shadow the freshly embedded ones on read and
    /// export (the sidecar is the record once it has descriptive content). Batch writes
    /// don't track per-file post-state, so read it back from each file that has a
    /// sidecar. The sidecar's Camera Raw settings and orientation are preserved —
    /// develop edits (RAW especially) live in the sidecar, not the embedded read-back.
    private func mirrorEmbeddedStateToExistingSidecars(for urls: [URL]) async {
        guard let sidecarURLs = try? await MetadataSidecarMirrorPreflight.shared.existingImageURLs(urls) else {
            return
        }
        guard !sidecarURLs.isEmpty else { return }
        guard let postWrite = try? await readService.readBatchFullMetadata(urls: sidecarURLs) else {
            logger.error("Sidecar mirror: post-write metadata read-back failed; existing .xmp sidecars left untouched")
            return
        }
        for url in sidecarURLs {
            guard let record = postWrite[url] else { continue }
            do {
                try await xmpSidecarService.saveSidecarPreservingDevelopSettingsSerialized(
                    metadata: record,
                    for: url,
                    onlyIfExisting: true,
                    preserveExistingOrientationIfMissing: true
                )
            } catch {
                logger.error("Sidecar mirror failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func writeXMPSidecar() async {
        let urls = selectedURLs
        let folderAtAdmission = currentFolderURL
        guard !urls.isEmpty else { return }
        do {
            if let folder = folderAtAdmission {
                for url in urls {
                    try await sidecarService.requireNoPendingOrientation(for: url, in: folder)
                }
            }
        } catch {
            saveError = error.localizedDescription
            return
        }

        guard !Task.isCancelled, selectedURLs == urls, currentFolderURL == folderAtAdmission else {
            saveError = "The selection changed before the XMP write began. Try the write again."
            return
        }
        if urls.count == 1, let imageURL = urls.first {
            let edited = editingMetadata
            do {
                try await xmpSidecarService.saveSidecarSerialized(
                    metadata: edited,
                    for: imageURL
                )
                if selectedCount == 1, selectedURLs.first == imageURL {
                    xmpMetadata = edited
                }
            } catch {
                saveError = "Failed to write XMP sidecar: \(error.localizedDescription)"
            }
            return
        }

        let mutation = capturedBatchMutation()
        let baselines = batchMetadataByURL
        for imageURL in urls {
            guard !Task.isCancelled else { return }
            do {
                let installed = try await xmpSidecarService.updateSidecarSerialized(
                    for: imageURL,
                    fallback: baselines[imageURL] ?? IPTCMetadata(),
                    mutation: mutation
                )
                if selectedURLs == urls {
                    batchMetadataByURL[imageURL] = installed
                }
            } catch {
                saveError = "Failed to save XMP sidecar: \(error.localizedDescription)"
            }
        }
    }

    private func writeXMPSidecarAndPreserveHistory(
        onComplete: @escaping (MetadataCommitResult) -> Void
    ) {
        guard let folderURL = currentFolderURL else {
            writeTask?.cancel()
            writeTask = Task {
                await writeXMPSidecar()
                if let saveError {
                    onComplete(.failed(message: saveError))
                } else {
                    onComplete(.succeeded)
                }
            }
            return
        }

        if selectedCount > 1 {
            writeTask?.cancel()
            writeTask = Task {
                await writeXMPSidecar()
                if let saveError {
                    onComplete(.failed(message: saveError))
                    return
                }
                await saveBatchSidecars(folderURL: folderURL, pendingChanges: false)
                hasChanges = false
                if let saveError {
                    onComplete(.failed(message: saveError))
                } else {
                    onComplete(.succeeded)
                }
            }
            return
        }

        guard let imageURL = selectedURLs.first else {
            onComplete(.succeeded)
            return
        }

        let edited = editingMetadata
        let previous = previousEditingMetadata ?? IPTCMetadata()
        let existingHistory = sidecarHistory
        let expectedRecord = currentWriteExpectedRecord
        let technicalReference = xmpMetadata
        let loadID = metadataLoadRequestID
        let generation = writeTaskGeneration + 1
        isSaving = true
        saveError = nil

        writeTask?.cancel()
        writeTask = Task {
            defer { if writeTaskGeneration == generation { isSaving = false } }
            let matchesSelection = {
                self.writeTaskGeneration == generation && self.metadataLoadRequestID == loadID
                    && self.selectedURLs == [imageURL] && self.currentFolderURL == folderURL
                    && self.editingMetadata == edited
            }
            do {
                let snapshot = try await sidecarService.captureWriteCompletionSnapshot(
                    for: imageURL, in: folderURL, expectedSidecar: expectedRecord,
                        expectedTechnicalMetadata: technicalReference)
                let now = Date()
                let sidecar = MetadataSidecar(sourceFile: imageURL.lastPathComponent,
                    lastModified: now, pendingChanges: false, metadata: edited,
                    imageMetadataSnapshot: edited,
                    history: buildHistory(previous: previous, edited: edited,
                        timestamp: now, existing: existingHistory))
                let result = await sidecarService.completeSidecarAndMirrorXMP(sidecar, snapshot: snapshot,
                    replaceDevelopSettings: Self.developSettingsChanged(edited.cameraRaw, previous.cameraRaw),
                    replaceOrientation: edited.exifOrientation != previous.exifOrientation)
                if result.completed, let installed = result.installedSidecar {
                    if matchesSelection() {
                        cleanupBaseline = (imageURL, folderURL, installed)
                        sidecarHistory = installed.history
                        xmpMetadata = result.writtenXMPMetadata ?? edited
                        editingMetadata.cameraRaw = xmpMetadata?.cameraRaw
                        editingMetadata.exifOrientation = xmpMetadata?.exifOrientation
                        previousEditingMetadata = editingMetadata
                        if metadataReferenceSource == .xmp {
                            metadata = xmpMetadata
                            originalImageMetadata = xmpMetadata
                        }
                        hasChanges = false
                        selectedHavePendingSidecars = false
                    }
                    onComplete(.succeeded)
                } else {
                    let message = Self.writeCompletionFailure(result, imageWasWritten: false)
                    if matchesSelection() { saveError = message }
                    onComplete(result.wasCancelled ? .cancelled(message: message) : .failed(message: message))
                }
            } catch {
                let message = "Metadata was not saved. \(error.localizedDescription)"
                if matchesSelection() { saveError = message }
                onComplete(error is CancellationError ? .cancelled(message: message) : .failed(message: message))
            }
        }
    }

    private nonisolated static func writeCompletionFailure(
        _ result: MetadataSidecarPersistenceResult, imageWasWritten: Bool
    ) -> String {
        let prefix = imageWasWritten
            ? "The image metadata was written, but its draft could not be completed. Newer pending edits were preserved."
            : result.wroteXMPSidecar
                ? "The XMP metadata was written, but its draft could not be completed."
                : "Metadata was not saved."
        let detail = result.failure?.message ?? "The operation was cancelled."
        let recovery = result.committedButUnverifiedSidecarURL.map { " Review: \($0.path)." } ?? ""
        return "\(prefix) \(detail)\(recovery) Reload before retrying."
    }

    /// True when the develop (Camera Raw) state differs between two snapshots,
    /// ignoring render-time-only fields the edit pipeline stamps on local copies
    /// (as-shot white balance, HDR-headroom flag). Gates whether a metadata save
    /// touches the file's crs block at all: a caption-only save on an ACR-edited
    /// file must not rewrite (and with replaceCameraRawBlock, wipe) Adobe's
    /// develop settings.
    nonisolated static func developSettingsChanged(_ a: CameraRawSettings?, _ b: CameraRawSettings?) -> Bool {
        func normalized(_ s: CameraRawSettings?) -> CameraRawSettings? {
            guard var s else { return nil }
            s.asShotNeutralTemperature = nil
            s.asShotNeutralTint = nil
            s.sourceHasHDRHeadroom = nil
            return s
        }
        return normalized(a) != normalized(b)
    }

    private func overwriteFields(
        from metadata: IPTCMetadata,
        includeCameraRaw: Bool = true,
        imageAspect: () -> Double? = { nil }
    ) -> [MetadataFieldKey: String] {
        var fields: [MetadataFieldKey: String] = [:]
        fields[.headline] = metadata.title ?? ""
        fields[.description] = metadata.description ?? ""
        fields[.extendedDescription] = metadata.extendedDescription ?? ""
        fields[.subject] = metadata.keywords.uniqued().joined(separator: ", ")
        fields[.personInImage] = metadata.personShown.uniqued().joined(separator: ", ")
        fields[.organisationInImageName] = metadata.organisationsShownNames.uniqued().joined(separator: ", ")
        fields[.organisationInImageCode] = metadata.organisationsShownCodes.uniqued().joined(separator: ", ")
        fields[.scene] = metadata.sceneCodes.uniqued().joined(separator: ", ")
        fields[.subjectCode] = metadata.subjectCodes.uniqued().joined(separator: ", ")
        fields[.mediaTopic] = metadata.mediaTopics.map(\.termIdentifier).uniqued().joined(separator: ", ")
        fields[.genre] = metadata.genres.map(\.termIdentifier).uniqued().joined(separator: ", ")
        fields[.digitalSourceType] = metadata.digitalSourceType?.newsCodeURI ?? ""
        fields[.urgency] = metadata.urgency.map(String.init) ?? ""
        fields[.creator] = metadata.creatorTransportValue ?? ""
        fields[.creatorJobTitle] = metadata.creatorJobTitle ?? ""
        fields[.descriptionWriter] = metadata.descriptionWriter ?? ""
        fields[.credit] = metadata.credit ?? ""
        fields[.rights] = metadata.copyright ?? ""
        fields[.rightsUsageTerms] = metadata.rightsUsageTerms ?? ""
        fields[.webStatementOfRights] = metadata.webStatementOfRights ?? ""
        fields[.digitalImageGUID] = metadata.digitalImageGUID ?? ""
        fields[.imageSupplierImageID] = metadata.imageSupplierImageID ?? ""
        fields[.transmissionReference] = metadata.jobId ?? ""
        fields[.dateCreated] = metadata.dateCreated ?? ""
        fields[.city] = metadata.city ?? ""
        fields[.sublocation] = metadata.sublocation ?? ""
        fields[.provinceState] = metadata.provinceState ?? ""
        fields[.country] = metadata.country ?? ""
        fields[.countryCode] = metadata.countryCode ?? ""
        fields[.event] = metadata.event ?? ""
        fields[.instructions] = metadata.instructions ?? ""
        fields[.source] = metadata.source ?? ""

        if let lat = metadata.latitude, let lon = metadata.longitude {
            fields[.gpsLatitude] = String(abs(lat))
            fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
            fields[.gpsLongitude] = String(abs(lon))
            fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
        } else {
            fields[.gpsLatitude] = ""
            fields[.gpsLatitudeRef] = ""
            fields[.gpsLongitude] = ""
            fields[.gpsLongitudeRef] = ""
        }

        // Caption-only saves must not touch the crs block at all — rewriting it
        // (even merge-style) churns Adobe's develop settings for no reason.
        if includeCameraRaw {
            appendCameraRawFields(from: metadata, into: &fields, imageAspect: imageAspect)
        }
        return fields
    }

    private func syncCameraRawToXMPSidecar(for imageURL: URL, metadata: IPTCMetadata) async {
        guard metadata.cameraRaw != nil || originalImageMetadata?.cameraRaw != nil else { return }
        try? await xmpSidecarService.saveCameraRawOnlySerialized(
            metadata.cameraRaw,
            orientation: metadata.exifOrientation,
            for: imageURL
        )
    }

    private func appendCameraRawFields(
        from metadata: IPTCMetadata,
        into fields: inout [MetadataFieldKey: String],
        imageAspect: () -> Double? = { nil }
    ) {
        // When cameraRaw is nil (edits fully reset), check if the original image had CRS
        // fields and clear them. Writing "" removes the field.
        guard let cameraRaw = metadata.cameraRaw else {
            if originalImageMetadata?.cameraRaw != nil {
                clearAllCameraRawFields(into: &fields)
            }
            return
        }

        // Canonical serialization of the simple crs fields (signed ints, +exposure,
        // 6-decimal ACR-encoded crop). Shared with the export engine via
        // CameraRawSettings.developWriteFields to keep the two write paths from drifting.
        fields.merge(cameraRaw.developWriteFields(imageAspect: imageAspect)) { _, new in new }
    }

    private func clearAllCameraRawFields(into fields: inout [MetadataFieldKey: String]) {
        fields[.crsVersion] = ""
        fields[.crsProcessVersion] = ""
        fields[.crsWhiteBalance] = ""
        fields[.crsTemperature] = ""
        fields[.crsTint] = ""
        fields[.crsIncrementalTemperature] = ""
        fields[.crsIncrementalTint] = ""
        fields[.crsExposure2012] = ""
        fields[.crsContrast2012] = ""
        fields[.crsHighlights2012] = ""
        fields[.crsShadows2012] = ""
        fields[.crsWhites2012] = ""
        fields[.crsBlacks2012] = ""
        fields[.crsSaturation] = ""
        fields[.crsVibrance] = ""
        fields[.aaphotoGlobalDensity] = ""
        fields[.crsSharpness] = ""
        fields[.crsClarity2012] = ""
        fields[.crsDehaze] = ""
        fields[.crsHasSettings] = "False"
        fields[.crsCropTop] = ""
        fields[.crsCropLeft] = ""
        fields[.crsCropBottom] = ""
        fields[.crsCropRight] = ""
        fields[.crsCropAngle] = ""
        fields[.crsHasCrop] = ""
        fields[.crsCropConstrainToWarp] = ""
        fields[.crsCropConstrainToUnitSquare] = ""
        fields[.crsHDREditMode] = ""
        fields[.crsHDRMaxValue] = ""
        fields[.crsSDRBrightness] = ""
        fields[.crsSDRContrast] = ""
        fields[.crsSDRClarity] = ""
        fields[.crsSDRHighlights] = ""
        fields[.crsSDRShadows] = ""
        fields[.crsSDRWhites] = ""
        fields[.crsSDRBlend] = ""
        fields[.crsToneCurveName2012] = ""
    }

    private func writeMetadataAndPreserveHistory(
        alsoWriteXMPSidecar: Bool = false,
        onComplete: @escaping (MetadataCommitResult) -> Void
    ) {
        guard selectedCount == 1,
              let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else {
            writeMetadata()
            if alsoWriteXMPSidecar {
                Task { await writeXMPSidecar() }
            }
            onComplete(.succeeded)
            return
        }

        let edited = editingMetadata
        let previous = previousEditingMetadata
        let existingHistory = sidecarHistory
        let expectedRecord = currentWriteExpectedRecord
        let original = originalImageMetadata
        let technicalReference = xmpMetadata
        let loadID = metadataLoadRequestID
        let generation = writeTaskGeneration + 1
        isSaving = true
        saveError = nil

        writeTask?.cancel()
        writeTask = Task {
            defer { if writeTaskGeneration == generation { isSaving = false } }
            let matchesSelection = {
                self.writeTaskGeneration == generation && self.metadataLoadRequestID == loadID
                    && self.selectedURLs == [imageURL] && self.currentFolderURL == folderURL
                    && self.editingMetadata == edited
            }
            do {
                // Capture the exact pending record and companion revision before the image writer.
                // A later edit must survive completion, even though the image write cannot be undone.
                let completionSnapshot = try await sidecarService.captureWriteCompletionSnapshot(
                    for: imageURL, in: folderURL, expectedSidecar: expectedRecord,
                        expectedTechnicalMetadata: technicalReference)
                let developChanged = Self.developSettingsChanged(edited.cameraRaw, original?.cameraRaw)
                let fields = overwriteFields(from: edited, includeCameraRaw: developChanged,
                    imageAspect: { ImagePixelAspect.aspect(at: imageURL) })
                let structuredData = developChanged
                    ? StructuredWriteData(
                        toneCurve: edited.cameraRaw?.toneCurve,
                        masks: edited.cameraRaw?.localAdjustments,
                        watermarkLayers: edited.cameraRaw?.watermarkLayers,
                        hslAdjustments: edited.cameraRaw?.hslAdjustments,
                        layerOrder: edited.cameraRaw?.layerOrder,
                        anonymizer: edited.cameraRaw?.anonymizer,
                        unparsedMaskCorrections: edited.cameraRaw?.unparsedMaskCorrections,
                        editorial: EditorialStructuredWriteData(metadata: edited),
                        replaceCameraRawBlock: true)
                    : StructuredWriteData(editorial: EditorialStructuredWriteData(metadata: edited))
                try await writeEngine.writeFields(fields, to: [imageURL], structuredData: structuredData)
                let now = Date()
                let sidecar = MetadataSidecar(sourceFile: imageURL.lastPathComponent,
                    lastModified: now, pendingChanges: false, metadata: edited,
                    imageMetadataSnapshot: edited,
                    history: buildHistory(previous: previous ?? IPTCMetadata(), edited: edited,
                        timestamp: now, existing: existingHistory))
                let result = await sidecarService.completeSidecarAndMirrorXMP(sidecar,
                    snapshot: completionSnapshot, mirrorOnlyIfExisting: !alsoWriteXMPSidecar,
                    replaceDevelopSettings: developChanged,
                    replaceOrientation: edited.exifOrientation != original?.exifOrientation)
                if result.completed, let installed = result.installedSidecar {
                    if matchesSelection() {
                        cleanupBaseline = (imageURL, folderURL, installed)
                        sidecarHistory = installed.history
                        previousEditingMetadata = edited
                        metadata = edited
                        originalImageMetadata = edited
                        embeddedMetadata = edited
                        if result.wroteXMPSidecar { xmpMetadata = result.writtenXMPMetadata ?? edited }
                        hasChanges = false
                        selectedHavePendingSidecars = false
                    }
                    onComplete(.succeeded)
                } else {
                    let message = Self.writeCompletionFailure(result, imageWasWritten: true)
                    if matchesSelection() { saveError = message }
                    onComplete(result.wasCancelled ? .cancelled(message: message) : .failed(message: message))
                }
            } catch {
                // Once the image writer returns, completion reports its partial outcome as a
                // result above. Only admission and the image writer can throw into this catch.
                let message = "Metadata was not written. \(error.localizedDescription)"
                if matchesSelection() { saveError = message }
                onComplete(error is CancellationError ? .cancelled(message: message) : .failed(message: message))
            }
        }
    }

    func applyTemplateFields(_ template: [String: String], append: Bool = false) {
        for (key, value) in template {
            switch key {
            case "title":
                editingMetadata.title = append ? appendString(editingMetadata.title, value) : value
            case "description":
                editingMetadata.description = append ? appendString(editingMetadata.description, value) : value
            case "extendedDescription":
                editingMetadata.extendedDescription = append ? appendString(editingMetadata.extendedDescription, value) : value
            case "keywords":
                let parsed = value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                // Tokens containing a variable ({...}) can't be validated against
                // the approved list until they're resolved, so pass them through
                // verbatim — validation happens after variable processing (see
                // resolveListField). Validate only literal keywords here.
                let variableTokens = parsed.filter { $0.contains("{") }
                let literalTokens = parsed.filter { !$0.contains("{") }
                let validated = ApprovedListService.shared.validateBulk(literalTokens, in: .keywords, source: .template)
                let toAdd = variableTokens + validated.accepted
                if append {
                    let existing = Set(editingMetadata.keywords)
                    editingMetadata.keywords += toAdd.filter { !existing.contains($0) }
                } else {
                    var seen = Set<String>()
                    editingMetadata.keywords = toAdd.filter { seen.insert($0).inserted }
                }
                if !validated.rejected.isEmpty {
                    let acceptedCount = validated.accepted.count
                    let rejCount = validated.rejected.count
                    let acceptedWord = acceptedCount == 1 ? "keyword" : "keywords"
                    notice = MetadataPanelNotice(
                        title: "Template: \(acceptedCount) \(acceptedWord) added, \(rejCount) rejected",
                        detail: validated.rejected,
                        severity: .warning
                    )
                }
            case "personShown":
                let newPersons = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if append {
                    let existing = Set(editingMetadata.personShown)
                    editingMetadata.personShown += newPersons.filter { !existing.contains($0) }
                } else {
                    editingMetadata.personShown = newPersons
                }
            case "organisationShownName":
                let values = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if append {
                    let existing = Set(editingMetadata.organisationsShownNames)
                    editingMetadata.organisationsShownNames += values.filter { !existing.contains($0) }
                } else {
                    editingMetadata.organisationsShownNames = values
                }
            case "organisationShownCode":
                let values = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if append {
                    let existing = Set(editingMetadata.organisationsShownCodes)
                    editingMetadata.organisationsShownCodes += values.filter { !existing.contains($0) }
                } else {
                    editingMetadata.organisationsShownCodes = values
                }
            case "sceneCode":
                let values = IPTCSceneCode.normalizedValues(
                    value.components(separatedBy: CharacterSet(charactersIn: ",;"))
                )
                if append {
                    let existing = Set(editingMetadata.sceneCodes)
                    editingMetadata.sceneCodes += values.filter { !existing.contains($0) }
                } else {
                    editingMetadata.sceneCodes = values
                }
            case "subjectCode":
                let values = IPTCSubjectCode.normalizedValues(
                    value.components(separatedBy: CharacterSet(charactersIn: ",;"))
                )
                editingMetadata.subjectCodes = append
                    ? IPTCSubjectCode.normalizedValues(editingMetadata.subjectCodes + values)
                    : values
            case "mediaTopic":
                let values = IPTCControlledVocabularyTerm.terms(
                    fromTemplateValue: value,
                    fallback: { IPTCControlledVocabularyTerm.mediaTopic(metadataValue: $0) }
                )
                editingMetadata.mediaTopics = append
                    ? IPTCControlledVocabularyTerm.normalizedValues(editingMetadata.mediaTopics + values)
                    : values
            case "genre":
                let values = IPTCControlledVocabularyTerm.terms(
                    fromTemplateValue: value,
                    fallback: { IPTCControlledVocabularyTerm.genre(metadataValue: $0) }
                )
                editingMetadata.genres = append
                    ? IPTCControlledVocabularyTerm.normalizedValues(editingMetadata.genres + values)
                    : values
            case "digitalSourceType":
                editingMetadata.digitalSourceType = DigitalSourceType(metadataValue: value)
            case "urgency":
                editingMetadata.urgency = Int(value)
            case "creator":
                let values = IPTCMetadata.creators(fromTransportValue: value)
                editingMetadata.creators = append
                    ? IPTCMetadata.normalizedCreators(editingMetadata.creators + values)
                    : values
            case "creatorJobTitle":
                editingMetadata.creatorJobTitle = append ? appendString(editingMetadata.creatorJobTitle, value) : value
            case "descriptionWriter":
                editingMetadata.descriptionWriter = append ? appendString(editingMetadata.descriptionWriter, value) : value
            case "credit":
                editingMetadata.credit = append ? appendString(editingMetadata.credit, value) : value
            case "copyright":
                editingMetadata.copyright = append ? appendString(editingMetadata.copyright, value) : value
            case "rightsUsageTerms":
                editingMetadata.rightsUsageTerms = append ? appendString(editingMetadata.rightsUsageTerms, value) : value
            case "webStatementOfRights":
                editingMetadata.webStatementOfRights = append ? appendString(editingMetadata.webStatementOfRights, value) : value
            case "digitalImageGUID":
                // Identifiers are atomic. Template append mode still replaces this field rather
                // than concatenating two identifiers into an invalid third value.
                editingMetadata.digitalImageGUID = value
            case "imageSupplierImageID":
                editingMetadata.imageSupplierImageID = value
            case "imageSupplier":
                guard let values = EditorialImageSupplier.values(fromCanonicalJSONString: value) else {
                    continue
                }
                editingMetadata.imageSuppliers = append
                    ? EditorialImageSupplier.normalizedValues(editingMetadata.imageSuppliers + values)
                    : values
            case "jobId":
                editingMetadata.jobId = append ? appendString(editingMetadata.jobId, value) : value
            case "dateCreated":
                if MetadataTemplatePlaceholderDetector.containsPlaceholder(value)
                    || (try? EditorialDateCreated(parsing: value)) != nil {
                    editingMetadata.dateCreated = value
                }
            case "city":
                editingMetadata.city = append ? appendString(editingMetadata.city, value) : value
            case "sublocation":
                editingMetadata.sublocation = append ? appendString(editingMetadata.sublocation, value) : value
            case "provinceState":
                editingMetadata.provinceState = append ? appendString(editingMetadata.provinceState, value) : value
            case "country":
                editingMetadata.country = append ? appendString(editingMetadata.country, value) : value
            case "countryCode":
                editingMetadata.countryCode = ISO3166Country.normalizedAlpha3(value)
            case "event":
                editingMetadata.event = append ? appendString(editingMetadata.event, value) : value
            case "instructions":
                editingMetadata.instructions = append ? appendString(editingMetadata.instructions, value) : value
            case "source":
                editingMetadata.source = append ? appendString(editingMetadata.source, value) : value
            default: break
            }
        }
        hasChanges = true
    }

    private func appendString(_ existing: String?, _ new: String) -> String {
        guard let existing, !existing.isEmpty else { return new }
        guard !new.isEmpty else { return existing }
        return existing + " " + new
    }

    /// Applies template fields to the editing buffer and then immediately resolves
    /// metadata variables for exactly the supplied images. Used by templates that
    /// have "process instantly" enabled.
    ///
    /// `images` is captured by the caller at apply time so a selection change during
    /// the async resolution doesn't redirect the writes to other images.
    ///
    /// Template intent and editor inputs are captured before asynchronous work. Each photo's
    /// local copy resolves its own {filename}/{seq} values, then awaited JSON preparation saves
    /// that complete result. No separate literal save can race the variable operation.
    func applyTemplateFieldsAndProcessVariables(_ template: [String: String], to images: [ImageFile], append: Bool = false) {
        applyTemplateFields(template, append: append)
        guard !images.isEmpty else { return }
        if selectedCount > 1 {
            // An instant template names its repeatable fields explicitly. Capture that intent
            // even when the selection has no common value; optional previousCommon inference
            // must not drop a supplied organisation/controlled-vocabulary list.
            let templateLists: [(String, MetadataFieldID)] = [
                ("keywords", .keywords), ("personShown", .personShown), ("creator", .creator),
                ("organisationShownName", .organisationShownName), ("organisationShownCode", .organisationShownCode),
                ("sceneCode", .sceneCode), ("subjectCode", .subjectCode), ("mediaTopic", .mediaTopic), ("genre", .genre)
            ]
            for (key, field) in templateLists where template[key] != nil {
                let values = Self.values(for: field, in: editingMetadata)
                if append {
                    switch batchFieldMutations[field] ?? .untouched {
                    case .clear, .overwrite:
                        // A prior removal/clear is represented as replacement intent. Appending
                        // a template must extend that replacement, not resurrect original values.
                        batchFieldMutations[field] = values.isEmpty ? .clear : .overwrite(.repeatable(values))
                    case .untouched, .append:
                        if !values.isEmpty { batchFieldMutations[field] = .append(values) }
                    }
                } else {
                    batchFieldMutations[field] = values.isEmpty ? .clear : .overwrite(.repeatable(values))
                }
            }
        }
        // Capture the batch mutation with the variable request. Awaited JSON preparation saves
        // the complete per-photo result; no separate fire-and-forget literal write can race it.
        processVariablesForImages(images)
    }

    private static let variablePattern = /(?:\{(date|date:[^}]+|dateCreated|dateCreated:[^}]+|dateCaptured|dateCaptured:[^}]+|filename|initials|persons|keywords|number|gps|gps:city|gps:country|latitude|longitude|field:[^}]+|seq|seq:\d+)\}|\(number\))/

    /// Checks whether any text field, keyword, or person in editingMetadata contains variable placeholders.
    var hasVariables: Bool {
        let fields: [String?] = [
            editingMetadata.title,
            editingMetadata.description,
            editingMetadata.extendedDescription,
            editingMetadata.creatorJobTitle,
            editingMetadata.descriptionWriter,
            editingMetadata.credit,
            editingMetadata.copyright,
            editingMetadata.rightsUsageTerms,
            editingMetadata.webStatementOfRights,
            editingMetadata.digitalImageGUID,
            editingMetadata.imageSupplierImageID,
            editingMetadata.jobId,
            editingMetadata.dateCreated,
            editingMetadata.city,
            editingMetadata.country,
            editingMetadata.event,
        ]
        if fields.contains(where: { field in
            guard let field else { return false }
            return field.contains(Self.variablePattern)
        }) {
            return true
        }
        let listValues = editingMetadata.keywords + editingMetadata.personShown
            + editingMetadata.creators
            + editingMetadata.organisationsShownNames + editingMetadata.organisationsShownCodes
            + editingMetadata.sceneCodes
            + editingMetadata.subjectCodes
            + editingMetadata.mediaTopics.map(\.termIdentifier)
            + editingMetadata.genres.map(\.termIdentifier)
        return listValues.contains { $0.contains(Self.variablePattern) }
    }

    /// Resolves all variable placeholders in editingMetadata text fields in-place.
    func processVariables(filename: String = "", sequenceIndex: Int = 1) {
        guard !isProcessingFolder else {
            saveError = "Wait for the current folder operation before resolving this editor's variables."
            return
        }
        guard let imageURL = selectedURLs.first, selectedCount == 1 else { return }
        let original = editingMetadata
        let selection = selectedURLs
        let folder = currentFolderURL
        let loadID = metadataLoadRequestID
        let input = VariableMetadataResolutionInput(metadata: original, imageURL: imageURL,
            filename: filename, sequenceIndex: sequenceIndex, options: variableOptions())
        let generation = batchProcessGeneration + 1
        batchProcessTask?.cancel()
        batchProcessTask = Task {
            do {
                let resolved = try await variableResolver(input)
                guard !Task.isCancelled, batchProcessGeneration == generation,
                      metadataLoadRequestID == loadID, selectedURLs == selection,
                      currentFolderURL == folder, editingMetadata == original else { return }
                editingMetadata = resolved
                if resolved != original { hasChanges = true }
            } catch {
                guard batchProcessGeneration == generation, metadataLoadRequestID == loadID,
                      selectedURLs == selection, currentFolderURL == folder, editingMetadata == original else { return }
                saveError = error.localizedDescription
            }
        }
    }

    /// Capture live template/editor inputs once. Multi-photo literals are folded into each
    /// immutable local input and durably prepared together with the resolved substitutions.
    func processVariablesForImages(_ images: [ImageFile]) {
        startVariableBatch(images: images)
    }

    func processVariablesInFolder(images: [ImageFile]) {
        startVariableBatch(images: images)
    }

    func retryVariableWrites() {
        guard !isProcessingFolder, let folder = retainedVariableWrites.first?.folderURL ?? retainedVariableAdmissions.first?.folderURL else { return }
        let folderKey = Self.variablePhotoKey(folder)
        let requests = retainedVariableWrites.filter { Self.variablePhotoKey($0.folderURL) == folderKey }
        let admissions = retainedVariableAdmissions.filter { Self.variablePhotoKey($0.folderURL) == folderKey }
        startVariableBatch(images: [], retryRequests: requests, retryAdmissions: admissions, retryFolder: folder)
    }

    func waitForVariableProcessing() async { await batchProcessTask?.value }

    func requireVariableDraftsPersisted() throws {
        if !activeVariableBatchIDs.isEmpty {
            throw CaptionWorkspaceFlushError.persistenceFailed(
                "Variable processing is still running. Wait for its result before closing or changing this workspace.")
        }
        let unverified = retainedVariableWrites.filter { !$0.hasVerifiedPreparedRecord }
        let riskyAdmissions = retainedVariableAdmissions.filter(\.requiresPersistence)
        guard unverified.isEmpty && riskyAdmissions.isEmpty else {
            throw CaptionWorkspaceFlushError.persistenceFailed(
                "Variable edits have not been verified in saved metadata. Use Retry Variable Writes before closing. Retained photos: "
                + (unverified.map { $0.imageURL.path } + riskyAdmissions.map { $0.imageURL.path }).joined(separator: ", "))
        }
    }

    private func synchronizeVariableLifecycleRetention() {
        if !activeVariableBatchIDs.isEmpty || retainedVariableAdmissions.contains(where: \.requiresPersistence) || retainedVariableWrites.contains(where: { !$0.hasVerifiedPreparedRecord }) {
            variableLifecycleCoordinator.register(ownerID: variableLifecycleOwnerID) { [self] in
                try requireVariableDraftsPersisted()
            }
        } else {
            variableLifecycleCoordinator.unregister(ownerID: variableLifecycleOwnerID)
        }
    }

    private static func variablePhotoKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func sameVariableRecord(_ first: MetadataSidecar?, _ second: MetadataSidecar?) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(first) == encoder.encode(second)
    }

    private func loadVariableInput(imageURL: URL, folderURL: URL) async throws -> VariableMetadataInputSnapshot {
        if let variableInputLoader { return try await variableInputLoader(imageURL, folderURL) }
        let before = try await SourceImageRevision.capture(at: imageURL)
        let dictionaries = try await readService.readBatchBasicMetadata(urls: [imageURL])
        guard dictionaries.count == 1, let dictionary = dictionaries.first,
              let path = dictionary[MetadataDictKey.sourceFile] as? String,
              Self.variablePhotoKey(URL(fileURLWithPath: path)) == Self.variablePhotoKey(imageURL) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "Could not verify this photo's metadata and content-credential status."])
        }
        let embedded = iptcMetadataFromDict(dictionary)
        let credentials = TechnicalMetadata.dictHasC2PA(dictionary)
        let baseline = try await MetadataReviewDraftCapture.loadBaseline(for: imageURL, in: folderURL)
        let xmp = try await PendingMetadataWriteService.strictXMP(for: imageURL)
        let after = try await SourceImageRevision.capture(at: imageURL)
        guard before.relationship(to: after) == .exactRevision else { throw MetadataFieldMutationConflict() }
        return .init(baselineSidecar: baseline, embeddedMetadata: embedded, xmpMetadata: xmp.metadata,
            hasC2PA: credentials, evidence: .init(sourceRevision: after, xmpData: xmp.snapshot.data))
    }

    private func startVariableBatch(images: [ImageFile],
                                    retryRequests: [VariableMetadataWriteRequest] = [],
                                    retryAdmissions: [VariableAdmission] = [], retryFolder: URL? = nil) {
        guard let folder = retryFolder ?? currentFolderURL,
              !images.isEmpty || !retryRequests.isEmpty || !retryAdmissions.isEmpty else { return }
        let isRetry = retryFolder != nil
        let urls = isRetry ? retryRequests.map(\.imageURL) + retryAdmissions.map(\.imageURL) : images.map(\.url)
        let batchID = UUID()
        let folderKey = Self.variablePhotoKey(folder)
        guard urls.allSatisfy({ Self.variablePhotoKey($0.deletingLastPathComponent()) == folderKey }) else {
            let message = "The selected photos no longer belong to the captured folder. Select them again before processing variables."
            variableBatchOutcome = .init(requestID: batchID, folderURL: folder,
                results: urls.map { .init(imageURL: $0, failure: message) }, unattemptedURLs: [], wasCancelled: false)
            variableProcessingStatus = message; variableProcessingHadFailures = true
            return
        }
        let options = variableOptions()
        let selected = selectedURLs
        let edited = editingMetadata
        let previous = previousEditingMetadata
        let selectedExpectedRecord = currentWriteExpectedRecord
        let loadID = metadataLoadRequestID
        let selectedSource = metadataReferenceSource
        let hasEditorInput = hasChanges && !Set(selected).isDisjoint(with: Set(urls))
        let hasUnsavedEditorInput = hasEditorInput && hasUnpersistedEditorChanges
        let batchMutation = selectedCount > 1 && hasEditorInput ? capturedBatchMutation() : nil
        let selectedBatchBaselines = batchMetadataByURL
        let technicalDirty = hasEditorInput && (Self.developSettingsChanged(edited.cameraRaw, previous?.cameraRaw)
            || edited.exifOrientation != previous?.exifOrientation)
        let existingKeys = Set(retainedVariableWrites.map { Self.variablePhotoKey($0.imageURL) }
            + retainedVariableAdmissions.map { Self.variablePhotoKey($0.imageURL) })
        if !isRetry && (technicalDirty || urls.contains(where: { existingKeys.contains(Self.variablePhotoKey($0)) })) {
            let message = technicalDirty
                ? "Save the editor's Develop or rotation changes before processing variables. They remain in the editor."
                : "An earlier variable request is retained for these photos. Use Retry Variable Writes before starting another transformation."
            variableBatchOutcome = .init(requestID: batchID, folderURL: folder,
                results: urls.map { .init(imageURL: $0, failure: message) }, unattemptedURLs: [], wasCancelled: false)
            variableProcessingStatus = message; variableProcessingHadFailures = true
            return
        }
        let admissions: [VariableAdmission]
        if isRetry { admissions = retryAdmissions }
        else {
            admissions = urls.enumerated().map { index, url in
                var capturedInput: VariableMetadataInputSnapshot?
                return VariableAdmission(id: UUID(), imageURL: url, folderURL: folder,
                    editorCheckpoint: selected == [url] ? .init(photoURL: url, folderURL: folder,
                        loadID: loadID, metadata: edited) : nil,
                    requiresPersistence: hasUnsavedEditorInput && selected.contains(url),
                    capture: { [weak self] in
                        guard let self else { throw CancellationError() }
                        let input: VariableMetadataInputSnapshot
                        if let capturedInput { input = capturedInput }
                        else {
                            input = try await loadVariableInput(imageURL: url, folderURL: folder)
                            capturedInput = input
                        }
                        let isCapturedSelection = selected.count == 1 && selected.first == url && hasEditorInput
                        let referenceSource: MetadataReferenceSource = isCapturedSelection
                            ? selectedSource : (input.xmpMetadata == nil ? .embedded : .xmp)
                        let physical = referenceMetadata(for: referenceSource, embedded: input.embeddedMetadata,
                            xmp: input.xmpMetadata, imageURL: url) ?? input.embeddedMetadata
                        var original = input.baselineSidecar?.pendingChanges == true
                            ? input.baselineSidecar!.metadata : physical
                        // JSON deliberately omits technical state. Carry the live physical
                        // reference separately so unchanged Develop/orientation is not a draft.
                        original.cameraRaw = physical.cameraRaw
                        original.exifOrientation = physical.exifOrientation
                        var local = original
                        if isCapturedSelection {
                            guard try Self.sameVariableRecord(selectedExpectedRecord, input.baselineSidecar) else {
                                throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
                                    "The saved metadata changed after this editor was loaded. Your editor values were retained; reload or reconcile before processing variables."])
                            }
                            if input.baselineSidecar?.pendingChanges != true {
                                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                                guard let previous, try encoder.encode(previous) == encoder.encode(original) else {
                                    throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
                                        "The photo's physical metadata changed after this editor was loaded. Your editor values remain unchanged; reload or reconcile before processing variables."])
                                }
                            }
                            // The loaded editor already proved its technical values unchanged.
                            // Mask parse identities are not an editorial edit; physical writes
                            // preserve the service's current technical record independently.
                            original.cameraRaw = edited.cameraRaw
                            original.exifOrientation = edited.exifOrientation
                            local = edited
                        } else if selected.contains(url), let batchMutation {
                            if let captured = selectedBatchBaselines[url] {
                                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                                guard try encoder.encode(captured) == encoder.encode(original) else {
                                    throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
                                        "The saved metadata changed after this batch editor was loaded. The template remains in the editor; reconcile before processing variables."])
                                }
                            }
                            batchMutation(&local)
                        }
                        let resolved = try await variableResolver(.init(metadata: local, imageURL: url,
                            filename: url.lastPathComponent, sequenceIndex: index + 1, options: options))
                        try Task.checkCancellation()
                        return try VariableMetadataWriteRequest.capture(original: original, resolved: resolved,
                            baselineSidecar: input.baselineSidecar, imageURL: url, folderURL: folder,
                            requestedMode: options.mode(hasC2PA: input.hasC2PA, imageURL: url), creationEvidence: input.evidence)
                    })
            }
            retainedVariableAdmissions.append(contentsOf: admissions)
        }
        let generation = batchProcessGeneration + 1
        let engine = writeEngine
        let reader = readService
        let executor = variableWriteExecutor
        activeVariableBatchIDs.insert(batchID)
        synchronizeVariableLifecycleRetention()
        isProcessingFolder = true
        folderProcessProgress = "0/\(urls.count)"
        variableBatchOutcome = nil
        variableProcessingStatus = nil
        variableProcessingHadFailures = false
        batchProcessTask?.cancel()
        batchProcessTask = Task {
            defer {
                activeVariableBatchIDs.remove(batchID)
                synchronizeVariableLifecycleRetention()
                if batchProcessGeneration == generation { isProcessingFolder = false; folderProcessProgress = "" }
            }
            let service = VariableMetadataWriteService(writeEngine: engine, readSourceFacts: { @MainActor url in
                let dictionaries = try await reader.readBatchBasicMetadata(urls: [url])
                guard dictionaries.count == 1, let dictionary = dictionaries.first,
                      let path = dictionary[MetadataDictKey.sourceFile] as? String,
                      Self.variablePhotoKey(URL(fileURLWithPath: path)) == Self.variablePhotoKey(url) else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                        "Could not verify this photo's metadata and content-credential status."])
                }
                return .init(metadata: iptcMetadataFromDict(dictionary), hasC2PA: TechnicalMetadata.dictHasC2PA(dictionary))
            })
            var results: [VariableMetadataPhotoOutcome] = []
            var acknowledgedBatchMetadata = selectedBatchBaselines
            var acknowledgedPending: [URL: Bool] = [:]
            var cancelled = false
            for url in urls {
                if Task.isCancelled { cancelled = true; break }
                var item = VariableMetadataPhotoOutcome(imageURL: url)
                do {
                    let key = Self.variablePhotoKey(url)
                    let explicitRetry = retryRequests.first { Self.variablePhotoKey($0.imageURL) == key }
                    let admission = admissions.first { Self.variablePhotoKey($0.imageURL) == key }
                    let request: VariableMetadataWriteRequest? = if let explicitRetry { explicitRetry } else { try await admission?.capture() }
                    if let admission { retainedVariableAdmissions.removeAll { $0.id == admission.id } }
                    if let request {
                        // Retain before the first possible commit. Even a JSON readback failure
                        // must keep the identical operation/receipt available to the Retry action.
                        if !retainedVariableWrites.contains(where: { $0.id == request.id }) {
                            retainedVariableWrites.append(request)
                            if let checkpoint = admission?.editorCheckpoint {
                                retainedVariableEditorCheckpoints[request.id] = checkpoint
                            }
                        }
                        let editorCheckpoint = retainedVariableEditorCheckpoints[request.id]
                        let result = if let executor { await executor(request) } else { await service.execute(request) }
                        item.writeResult = result
                        item.wasCancelled = result.wasCancelled
                        if result.completed {
                            retainedVariableWrites.removeAll { $0.id == request.id }
                            retainedVariableEditorCheckpoints.removeValue(forKey: request.id)
                            if let record = result.physicalResult?.installedSidecar ?? result.preparedSidecar {
                                acknowledgedBatchMetadata[url] = record.metadata
                                acknowledgedPending[url] = record.pendingChanges
                            }
                        }
                        if batchProcessGeneration == generation, let editorCheckpoint,
                           metadataLoadRequestID == editorCheckpoint.loadID,
                           currentFolderURL == editorCheckpoint.folderURL,
                           selectedURLs == [editorCheckpoint.photoURL], editingMetadata == editorCheckpoint.metadata,
                           let installed = result.preparedSidecar,
                           result.completed {
                            let record = result.physicalResult?.installedSidecar ?? installed
                            var displayed = record.metadata
                            displayed.cameraRaw = edited.cameraRaw
                            displayed.exifOrientation = edited.exifOrientation
                            editingMetadata = displayed
                            previousEditingMetadata = displayed
                            cleanupBaseline = (url, folder, record)
                            capturedCaptionWriteExpectation = nil
                            sidecarHistory = record.history
                            hasChanges = record.pendingChanges
                            selectedHavePendingSidecars = record.pendingChanges
                            if result.physicalResult?.didWriteEmbedded == true { embeddedMetadata = displayed }
                            if result.physicalResult?.didWriteXMP == true { xmpMetadata = displayed }
                            let actualReference = referenceMetadata(for: metadataReferenceSource,
                                embedded: embeddedMetadata, xmp: xmpMetadata, imageURL: url)
                            metadata = actualReference
                            originalImageMetadata = actualReference
                            saveError = nil
                        }
                    } else { item.unchanged = true }
                } catch {
                    item.wasCancelled = error is CancellationError
                    item.failure = item.wasCancelled ? nil : error.localizedDescription
                }
                results.append(item)
                if batchProcessGeneration == generation { folderProcessProgress = "\(results.count)/\(urls.count)" }
                if item.wasCancelled || Task.isCancelled { cancelled = true; break }
            }
            guard batchProcessGeneration == generation else { return }
            let outcome = VariableMetadataBatchOutcome(requestID: batchID, folderURL: folder,
                results: results, unattemptedURLs: Array(urls.dropFirst(results.count)), wasCancelled: cancelled)
            // A retry owns earlier per-photo values, not a newly edited batch buffer.
            // Leave that buffer available for explicit reconciliation/reload.
            if !isRetry, selected.count > 1, Set(selected).isSubset(of: Set(urls)),
               selected.allSatisfy({ acknowledgedPending[$0] != nil }),
               metadataLoadRequestID == loadID, currentFolderURL == folder,
               selectedURLs == selected, editingMetadata == edited {
                publishBatchMetadata(selected.compactMap { acknowledgedBatchMetadata[$0] },
                    metadataByURL: acknowledgedBatchMetadata, isReload: false)
                selectedHavePendingSidecars = acknowledgedPending.values.contains(true)
                hasChanges = selectedHavePendingSidecars
                batchFieldMutations = [:]
                batchLocationsShownMutation = .untouched
                batchImageSupplierMutation = .untouched
            }
            variableBatchOutcome = outcome
            variableProcessingHadFailures = outcome.attention != nil
            variableProcessingStatus = "Variable processing: \(results.filter { $0.writeResult?.physicalResult?.completed == true }.count) written, \(results.filter { $0.writeResult?.savedToHistory == true }.count) saved to history, \(results.filter(\.unchanged).count) unchanged, \(results.filter { !$0.completed }.count) incomplete."
            if metadataLoadRequestID == loadID, selectedURLs == selected, currentFolderURL == folder, editingMetadata == edited {
                saveError = outcome.attention?.message
            }
        }
    }

    /// Re-read metadata from file for the currently displayed image after variable processing,
    /// so the UI reflects the resolved values instead of stale template strings.
    private func refreshMetadataAfterProcessing(updatedURLs: Set<URL>, processedImages: [ImageFile]) async {
        if selectedCount > 1 {
            let selectionSnapshot = Set(selectedURLs)
            guard !selectionSnapshot.isDisjoint(with: updatedURLs) else { return }
            let selectedProcessedImages = processedImages.filter { selectionSnapshot.contains($0.url) }
            guard Set(selectedProcessedImages.map(\.url)) == selectionSnapshot else { return }

            let requestID = UUID()
            let folderSnapshot = currentFolderURL
            metadataLoadRequestID = requestID
            await loadBatchMetadata(
                for: selectedProcessedImages,
                selectionSnapshot: selectionSnapshot,
                isReload: false,
                requestID: requestID,
                folderURL: folderSnapshot
            )
            guard metadataLoadRequestID == requestID,
                  currentFolderURL == folderSnapshot,
                  selectedURLs == selectedProcessedImages.map(\.url) else { return }
            hasChanges = false
            return
        }

        guard selectedCount == 1,
              let url = selectedURLs.first,
              updatedURLs.contains(url) else { return }

        do {
            let requestID = UUID()
            let folderSnapshot = currentFolderURL
            metadataLoadRequestID = requestID
            let (embedded, conflict) = try await readService.readFullMetadataWithConflictCheck(url: url)
            let sidecarResult = await editorReadService.load(MetadataEditorReadRequest(
                id: requestID,
                imageURLs: [url],
                folderURL: folderSnapshot,
                embeddedMetadataByImageURL: [url: embedded]
            ))
            guard !Task.isCancelled,
                  metadataLoadRequestID == requestID,
                  currentFolderURL == folderSnapshot,
                  selectedURLs == [url],
                  case .complete(let sidecarSnapshot) = sidecarResult,
                  sidecarSnapshot.request.id == requestID,
                  let sourceFacts = sidecarSnapshot.factsByImageURL[url] else { return }
            let xmpMeta = sourceFacts.xmpMetadata
            // Preserve the user's current reference source selection after processing
            let refSource: MetadataReferenceSource
            if metadataReferenceSource == .xmp, xmpMeta == nil {
                refSource = .embedded
            } else {
                refSource = metadataReferenceSource
            }
            let baseMeta = referenceMetadata(for: refSource, embedded: embedded, xmp: xmpMeta, imageURL: url) ?? embedded

            self.embeddedMetadata = embedded
            self.descriptionConflict = conflict
            self.xmpMetadata = xmpMeta
            self.metadataReferenceSource = refSource
            self.metadata = baseMeta
            self.originalImageMetadata = baseMeta

            self.cleanupBaseline = (url, folderSnapshot, sourceFacts.appSidecar)
            // Load sidecar for images with pending changes (C2PA, historyOnly, etc.)
            if let sidecar = sourceFacts.appSidecar,
               sidecar.pendingChanges {
                self.editingMetadata = sidecar.metadata
                self.previousEditingMetadata = sidecar.metadata
                self.hasChanges = true
            } else {
                self.editingMetadata = baseMeta
                self.previousEditingMetadata = baseMeta
                self.hasChanges = false
                // Only delete sidecar if it has no history entries worth preserving
                if let folderSnapshot,
                   let sidecar = sourceFacts.appSidecar,
                   sidecar.history.isEmpty {
                    _ = try? await sidecarService.deleteUnneededSidecarSerialized(
                        for: url, in: folderSnapshot
                    )
                }
            }
        } catch {
            logger.warning("Failed to refresh metadata after processing: \(error.localizedDescription)")
        }
    }

    private func resolveIfChanged(_ value: String?, interpolator: PresetVariableInterpolator, filename: String, ref: IPTCMetadata, changed: inout Bool, sequenceIndex: Int = 1, initials: String = "") -> String? {
        guard let value, !value.isEmpty else { return value }
        let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref, sequenceIndex: sequenceIndex, initials: initials)
        if resolved != value { changed = true }
        return resolved.isEmpty ? nil : resolved
    }

    /// Resolves variables in each entry of a keyword/person array.
    /// After interpolation, splits on commas so a single token can expand into
    /// multiple values, trims, drops empties, and dedups in order.
    /// When `validateField` is set, each resolved value is checked against the
    /// approved list — this is where variable tokens that bypassed validation at
    /// apply time finally get validated/canonicalised (rejected values dropped).
    private func resolveListField(_ values: [String], interpolator: PresetVariableInterpolator, filename: String, ref: IPTCMetadata, sequenceIndex: Int, initials: String, validateField: ApprovedListField? = nil) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for value in values {
            let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref, sequenceIndex: sequenceIndex, initials: initials)
            for part in resolved.components(separatedBy: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let finalValue: String
                if let field = validateField {
                    switch ApprovedListService.shared.validate(trimmed, in: field, source: .template) {
                    case .accept: finalValue = trimmed
                    case .acceptCanonical(let canonical): finalValue = canonical
                    case .reject: continue
                    }
                } else {
                    finalValue = trimmed
                }
                guard seen.insert(finalValue).inserted else { continue }
                result.append(finalValue)
            }
        }
        return result
    }

    // MARK: - Reverse Geocoding

    /// Reverse geocodes the current image's GPS coordinates to fill City and Country fields.
    func reverseGeocodeCurrentLocation() {
        guard let lat = editingMetadata.latitude,
              let lon = editingMetadata.longitude else {
            geocodingError = "No GPS coordinates available"
            return
        }

        isReverseGeocoding = true
        geocodingError = nil

        geocodingTask?.cancel()
        geocodingTask = Task { @MainActor in
            do {
                let result = try await geocodingService.reverseGeocode(latitude: lat, longitude: lon)
                if let city = result.city { editingMetadata.city = city }
                if let country = result.country { editingMetadata.country = country }
                hasChanges = true
            } catch {
                geocodingError = error.localizedDescription
            }
            isReverseGeocoding = false
        }
    }

    /// Reverse geocodes GPS coordinates for all selected images and writes City/Country directly to each file.
    func reverseGeocodeSelectedImages() {
        guard !selectedURLs.isEmpty else { return }

        isReverseGeocoding = true
        geocodingError = nil
        geocodingProgress = "0/\(selectedURLs.count)"

        geocodingTask?.cancel()
        geocodingTask = Task { @MainActor in
            var processed = 0
            var skipped = 0
            var geocoded = 0
            var failed = 0

            for url in selectedURLs {
                if Task.isCancelled { break }
                do {
                    let meta = try await readService.readFullMetadata(url: url)
                    guard let lat = meta.latitude, let lon = meta.longitude else {
                        skipped += 1
                        processed += 1
                        geocodingProgress = "\(processed)/\(selectedURLs.count)"
                        continue
                    }

                    let result = try await geocodingService.reverseGeocode(latitude: lat, longitude: lon)

                    var fields: [MetadataFieldKey: String] = [:]
                    if let city = result.city { fields[.city] = city }
                    if let country = result.country { fields[.country] = country }

                    if !fields.isEmpty {
                        if SupportedImageFormats.isRaw(url: url) {
                            var update = IPTCMetadata()
                            update.city = result.city
                            update.country = result.country
                            _ = try await descriptiveWriteBoundary.write(
                                metadata: update,
                                for: url,
                                requestedMode: .writeToFile,
                                semantics: .merge
                            )
                        } else {
                            try await writeEngine.writeFields(fields, to: [url])
                        }
                        geocoded += 1
                    }

                    // Throttle only the online geocoder; the offline lookup needs no rate limit.
                    if geocodingService.usesNetwork {
                        try await Task.sleep(for: .milliseconds(500))
                    }
                } catch {
                    failed += 1
                    logger.warning("Reverse geocoding failed for \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                }

                processed += 1
                geocodingProgress = "\(processed)/\(selectedURLs.count)"
            }

            var notes: [String] = []
            if geocoded > 0 { notes.append("\(geocoded) geocoded") }
            if skipped > 0 { notes.append("\(skipped) skipped (no GPS)") }
            if failed > 0 { notes.append("\(failed) failed") }
            geocodingError = notes.isEmpty ? nil : notes.joined(separator: ", ")

            isReverseGeocoding = false
            geocodingProgress = ""
        }
    }

    // MARK: - Sidecar Management

    func saveToSidecar() {
        guard let folderURL = currentFolderURL else { return }
        let generation = writeTaskGeneration + 1
        if selectedCount == 1, let imageURL = selectedURLs.first {
            let edited = editingMetadata
            let previous = previousEditingMetadata ?? IPTCMetadata()
            let expectedRecord = currentWriteExpectedRecord
            let technicalReference = xmpMetadata
            let loadID = metadataLoadRequestID
            let now = Date()
            let sidecar = MetadataSidecar(sourceFile: imageURL.lastPathComponent,
                lastModified: now, pendingChanges: true, metadata: edited,
                imageMetadataSnapshot: pendingDraftImageMetadataSnapshot,
                history: buildHistory(previous: previous, edited: edited, timestamp: now, existing: sidecarHistory))
            isSaving = true
            saveError = nil
            writeTask?.cancel()
            writeTask = Task {
                defer { if writeTaskGeneration == generation { isSaving = false } }
                let matchesSelection = {
                    self.writeTaskGeneration == generation && self.metadataLoadRequestID == loadID
                        && self.selectedURLs == [imageURL] && self.currentFolderURL == folderURL
                        && self.editingMetadata == edited
                }
                do {
                    // An intentional editor/technical save may have no editorial history delta.
                    // Its complete record is valid only against this captured pending revision.
                    let snapshot = try await sidecarService.captureWriteCompletionSnapshot(
                        for: imageURL, in: folderURL, expectedSidecar: expectedRecord,
                        expectedTechnicalMetadata: technicalReference, allowPendingOrientation: true)
                    let result = await sidecarService.completeSidecarAndMirrorXMP(sidecar, snapshot: snapshot,
                        replaceDevelopSettings: Self.developSettingsChanged(edited.cameraRaw, previous.cameraRaw),
                        replaceOrientation: edited.exifOrientation != previous.exifOrientation)
                    if result.completed, let installed = result.installedSidecar {
                        if matchesSelection() {
                            cleanupBaseline = (imageURL, folderURL, installed)
                            sidecarHistory = installed.history
                            xmpMetadata = result.writtenXMPMetadata ?? edited
                            editingMetadata.cameraRaw = xmpMetadata?.cameraRaw
                            editingMetadata.exifOrientation = xmpMetadata?.exifOrientation
                            previousEditingMetadata = editingMetadata
                            hasChanges = true
                            selectedHavePendingSidecars = true
                        }
                    } else if matchesSelection() {
                        saveError = Self.writeCompletionFailure(result, imageWasWritten: false)
                    }
                } catch {
                    if matchesSelection() { saveError = "Failed to save sidecar: \(error.localizedDescription)" }
                }
            }
        } else if selectedCount > 1 {
            isSaving = true
            writeTask?.cancel()
            writeTask = Task {
                await saveBatchSidecars(folderURL: folderURL)
                if writeTaskGeneration == generation { isSaving = false }
            }
        }
    }

    /// Captures the current single-image Caption draft for serialized off-main persistence.
    ///
    /// The selection can change as soon as this returns: every value needed by the write is owned
    /// by the returned request. History state advances optimistically so rapid navigation back to
    /// the same image cannot manufacture duplicate edits; the queue retains and retries a failed
    /// request at the next durable barrier.
    func captureCaptionDraftPersistence() throws -> CaptionDraftPersistence? {
        guard let folderURL = currentFolderURL else {
            throw CaptionWorkspaceFlushError.sidecarUnavailable
        }
        guard hasUnpersistedEditorChanges else { return nil }
        guard selectedCount == 1, let imageURL = selectedURLs.first else {
            throw CaptionWorkspaceFlushError.persistenceFailed(
                "Caption persistence requires exactly one selected photo."
            )
        }

        let now = Date()
        let previous = previousEditingMetadata ?? IPTCMetadata()
        let baselineHistory = sidecarHistory
        let baselineRecordExisted = currentWriteExpectedRecord != nil
        let changes = MetadataHistoryEntry.changes(from: previous, to: editingMetadata, timestamp: now)
        // Caption owns editorial drafts. A Develop-only buffer belongs to its explicit technical
        // write path and must not become a whole-record JSON replacement with no replay intent.
        guard !changes.isEmpty else { return nil }
        let captureKey = imageURL.resolvingSymlinksInPath().path.lowercased()
        let cleanupKey = MetadataIOKey.key(for: imageURL)
        guard captionCleanupOwners[cleanupKey] == nil else {
            throw CaptionWorkspaceFlushError.persistenceFailed(
                "This photo's metadata write is finishing. Your new Caption edits remain in the editor; save them again when it finishes."
            )
        }
        var history = baselineHistory + changes
        history.trimToHistoryLimit()
        let sidecar = MetadataSidecar(
            sourceFile: imageURL.lastPathComponent,
            lastModified: now,
            pendingChanges: true,
            metadata: editingMetadata,
            imageMetadataSnapshot: pendingDraftImageMetadataSnapshot,
            history: history
        )

        sidecarHistory = history
        var persistedEditorialBaseline = editingMetadata
        // Replay deliberately preserves technical XMP state. A mixed buffer must continue to
        // report its unapplied Develop/orientation edits after the editorial request is captured.
        persistedEditorialBaseline.cameraRaw = previous.cameraRaw
        persistedEditorialBaseline.exifOrientation = previous.exifOrientation
        previousEditingMetadata = persistedEditorialBaseline
        saveError = nil
        let request = MetadataSidecarReplayRequest(
            sidecar: sidecar, baselineMetadata: previous, baselineHistory: baselineHistory,
            baselineRecordExisted: baselineRecordExisted,
            changes: changes, imageURL: imageURL, folderURL: folderURL)
        captionCaptureGenerations[captureKey, default: 0] += 1
        capturedCaptionWriteExpectation = (metadataLoadRequestID, request)
        return CaptionDraftPersistence(request: request)
    }

    private func buildHistory(
        previous: IPTCMetadata,
        edited: IPTCMetadata,
        timestamp: Date,
        existing: [MetadataHistoryEntry]
    ) -> [MetadataHistoryEntry] {
        var history = existing
        history.append(contentsOf: MetadataHistoryEntry.changes(
            from: previous,
            to: edited,
            timestamp: timestamp
        ))

        history.trimToHistoryLimit()
        return history
    }

    private func saveBatchSidecars(
        folderURL: URL,
        pendingChanges: Bool = true,
        targetURLs: [URL]? = nil,
        updateState: Bool = true
    ) async {
        let now = Date()
        let mutation = capturedBatchMutation()
        let overridesSuppliers = batchImageSupplierMutation != .untouched
        let urls = targetURLs ?? selectedURLs
        let selectedAtStart = selectedURLs
        let baselines = batchMetadataByURL

        for imageURL in urls {
            guard !Task.isCancelled else { return }
            do {
                let installed = try await sidecarService.updateMetadataSerialized(
                    for: imageURL,
                    in: folderURL,
                    fallback: baselines[imageURL] ?? IPTCMetadata(),
                    pendingChanges: pendingChanges,
                    timestamp: now,
                    mutation: mutation
                )
                if selectedURLs == selectedAtStart {
                    batchMetadataByURL[imageURL] = installed.metadata
                }
                if pendingChanges {
                    // C2PA: save full metadata to XMP sidecar for render+sign overlay.
                    // Installed metadata is JSON-sourced (no crs) — preserve any develop
                    // edits already in the .xmp so a batch rating/keyword edit on a
                    // C2PA RAW doesn't wipe them.
                    try await xmpSidecarService.saveSidecarPreservingDevelopSettingsSerialized(
                        metadata: installed.metadata,
                        for: imageURL,
                        mergeWithExisting: true,
                        imageSuppliersOverride: overridesSuppliers ? installed.metadata.imageSuppliers : nil
                    )
                }
            } catch {
                saveError = "Failed to save metadata sidecar: \(error.localizedDescription)"
            }
        }

        if updateState, selectedURLs == selectedAtStart {
            hasChanges = pendingChanges
            if !pendingChanges {
                selectedHavePendingSidecars = false
            }
        }
    }

    private func capturedBatchMutation() -> @Sendable (inout IPTCMetadata) -> Void {
        let batchMeta = editingMetadata
        let previousCommon = previousEditingMetadata
        let fields = batchFieldMutations
        let locations = batchLocationsShownMutation
        let suppliers = batchImageSupplierMutation
        let keywordsMode = multiSelectMode(for: "keywords")
        let personMode = multiSelectMode(for: "personShown")
        return { metadata in
            Self.applyBatchEdits(
                batchMeta, to: &metadata, previousCommon: previousCommon,
                batchFieldMutations: fields, batchLocationsShownMutation: locations,
                batchImageSupplierMutation: suppliers,
                keywordsMode: keywordsMode, personMode: personMode
            )
        }
    }

    private nonisolated static func applyBatchEdits(
        _ batchMeta: IPTCMetadata,
        to metadata: inout IPTCMetadata,
        previousCommon: IPTCMetadata? = nil,
        batchFieldMutations: [MetadataFieldID: MetadataFieldMutation],
        batchLocationsShownMutation: BatchLocationsShownMutation,
        batchImageSupplierMutation: EditorialImageSupplierMutation,
        keywordsMode: MultiSelectFieldMode,
        personMode: MultiSelectFieldMode
    ) {
        // Explicit intent wins over every legacy inference path below. These operations were
        // validated when recorded, so a failure here can only mean an internal contract drift;
        // fail closed by leaving the per-image record unchanged.
        if !batchFieldMutations.isEmpty || batchLocationsShownMutation != .untouched
            || batchImageSupplierMutation != .untouched {
            guard let explicitlyMutated = try? Self.applyingBatchListMutations(
                batchFieldMutations,
                locationsShown: batchLocationsShownMutation,
                imageSuppliers: batchImageSupplierMutation,
                to: metadata
            ) else { return }
            metadata = explicitlyMutated
        }

        if let title = batchMeta.title, !title.isEmpty {
            metadata.title = title
        }
        if let desc = batchMeta.description, !desc.isEmpty {
            metadata.description = desc
        }
        if let extDesc = batchMeta.extendedDescription, !extDesc.isEmpty {
            metadata.extendedDescription = extDesc
        }

        // Keywords — add vs overwrite
        if batchFieldMutations[.keywords] == nil {
            if keywordsMode == .add, let prev = previousCommon {
                let previous = Set(Self.normalizedRepeatableValues(prev.keywords, field: .keywords))
                let edited = Self.normalizedRepeatableValues(batchMeta.keywords, field: .keywords)
                let editedSet = Set(edited)
                let added = edited.filter { !previous.contains($0) }
                let removed = previous.subtracting(editedSet)
                if !added.isEmpty || !removed.isEmpty {
                    metadata.keywords = metadata.keywords.filter { !removed.contains($0) }
                    metadata.keywords = Self.normalizedRepeatableValues(
                        metadata.keywords + added,
                        field: .keywords
                    )
                }
            } else if !batchMeta.keywords.isEmpty {
                metadata.keywords = Self.normalizedRepeatableValues(batchMeta.keywords, field: .keywords)
            }
        }

        // Person Shown — add vs overwrite
        if batchFieldMutations[.personShown] == nil {
            if personMode == .add, let prev = previousCommon {
                let previous = Set(Self.normalizedRepeatableValues(prev.personShown, field: .personShown))
                let edited = Self.normalizedRepeatableValues(batchMeta.personShown, field: .personShown)
                let editedSet = Set(edited)
                let added = edited.filter { !previous.contains($0) }
                let removed = previous.subtracting(editedSet)
                if !added.isEmpty || !removed.isEmpty {
                    metadata.personShown = metadata.personShown.filter { !removed.contains($0) }
                    metadata.personShown = Self.normalizedRepeatableValues(
                        metadata.personShown + added,
                        field: .personShown
                    )
                }
            } else if !batchMeta.personShown.isEmpty {
                metadata.personShown = Self.normalizedRepeatableValues(batchMeta.personShown, field: .personShown)
            }
        }

        if let prev = previousCommon {
            if batchFieldMutations[.organisationShownName] == nil {
                applyImplicitAdditiveEdit(
                    previous: prev.organisationsShownNames,
                    edited: batchMeta.organisationsShownNames,
                    field: .organisationShownName,
                    to: &metadata.organisationsShownNames
                )
            }
            if batchFieldMutations[.organisationShownCode] == nil {
                applyImplicitAdditiveEdit(
                    previous: prev.organisationsShownCodes,
                    edited: batchMeta.organisationsShownCodes,
                    field: .organisationShownCode,
                    to: &metadata.organisationsShownCodes
                )
            }
            if batchFieldMutations[.sceneCode] == nil {
                applyImplicitAdditiveEdit(
                    previous: prev.sceneCodes,
                    edited: batchMeta.sceneCodes,
                    field: .sceneCode,
                    to: &metadata.sceneCodes
                )
            }
            if batchFieldMutations[.subjectCode] == nil {
                applyImplicitAdditiveEdit(
                    previous: prev.subjectCodes,
                    edited: batchMeta.subjectCodes,
                    field: .subjectCode,
                    to: &metadata.subjectCodes
                )
            }
        }

        if let copyright = batchMeta.copyright, !copyright.isEmpty {
            metadata.copyright = copyright
        }
        if let rightsUsageTerms = batchMeta.rightsUsageTerms, !rightsUsageTerms.isEmpty {
            metadata.rightsUsageTerms = rightsUsageTerms
        }
        if let webStatementOfRights = batchMeta.webStatementOfRights, !webStatementOfRights.isEmpty {
            metadata.webStatementOfRights = webStatementOfRights
        }
        if let digitalImageGUID = batchMeta.digitalImageGUID, !digitalImageGUID.isEmpty {
            metadata.digitalImageGUID = digitalImageGUID
        }
        if let imageSupplierImageID = batchMeta.imageSupplierImageID, !imageSupplierImageID.isEmpty {
            metadata.imageSupplierImageID = imageSupplierImageID
        }
        if let jobId = batchMeta.jobId, !jobId.isEmpty {
            metadata.jobId = jobId
        }
        if let dateCreated = batchMeta.dateCreated,
           (try? EditorialDateCreated(parsing: dateCreated)) != nil {
            metadata.dateCreated = dateCreated
        }
        if batchFieldMutations[.creator] == nil, !batchMeta.creators.isEmpty {
            metadata.creators = batchMeta.creators
        }
        if let creatorJobTitle = batchMeta.creatorJobTitle, !creatorJobTitle.isEmpty {
            metadata.creatorJobTitle = creatorJobTitle
        }
        if let descriptionWriter = batchMeta.descriptionWriter, !descriptionWriter.isEmpty {
            metadata.descriptionWriter = descriptionWriter
        }
        if let credit = batchMeta.credit, !credit.isEmpty {
            metadata.credit = credit
        }
        if let city = batchMeta.city, !city.isEmpty {
            metadata.city = city
        }
        if let sublocation = batchMeta.sublocation, !sublocation.isEmpty {
            metadata.sublocation = sublocation
        }
        if let provinceState = batchMeta.provinceState, !provinceState.isEmpty {
            metadata.provinceState = provinceState
        }
        if let country = batchMeta.country, !country.isEmpty {
            metadata.country = country
        }
        if let countryCode = batchMeta.countryCode, !countryCode.isEmpty {
            metadata.countryCode = countryCode
        }
        if let event = batchMeta.event, !event.isEmpty {
            metadata.event = event
        }
        if let instructions = batchMeta.instructions, !instructions.isEmpty {
            metadata.instructions = instructions
        }
        if let source = batchMeta.source, !source.isEmpty {
            metadata.source = source
        }
        if batchMeta.digitalSourceType != nil {
            metadata.digitalSourceType = batchMeta.digitalSourceType
        }
        if batchMeta.urgency != nil {
            metadata.urgency = batchMeta.urgency
        }

        // GPS — apply only when both coordinates are set, mirroring the batch
        // file-write path in writeMetadata(). When GPS differs across the
        // selection and the user hasn't picked a location, the common
        // coordinates are nil, so each image's existing GPS is preserved.
        if let lat = batchMeta.latitude, let lon = batchMeta.longitude {
            metadata.latitude = lat
            metadata.longitude = lon
        }
    }

    private nonisolated static func applyImplicitAdditiveEdit(
        previous: [String],
        edited: [String],
        field: MetadataFieldID,
        to target: inout [String]
    ) {
        let normalizedPrevious = Set(Self.normalizedRepeatableValues(previous, field: field))
        let normalizedEdited = Self.normalizedRepeatableValues(edited, field: field)
        let normalizedEditedSet = Set(normalizedEdited)
        let added = normalizedEdited.filter { !normalizedPrevious.contains($0) }
        let removed = normalizedPrevious.subtracting(normalizedEditedSet)
        target.removeAll { removed.contains($0) }
        target = Self.normalizedRepeatableValues(target + added, field: field)
    }

    func writeMetadataAndClearSidecar() {
        guard selectedCount == 1,
              let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else {
            writeMetadata()
            return
        }

        isSaving = true
        saveError = nil

        let edited = editingMetadata
        let original = originalImageMetadata
        let loadID = metadataLoadRequestID
        let editorRecord = currentWriteExpectedRecord
        let generation = writeTaskGeneration + 1
        let captureKey = imageURL.resolvingSymlinksInPath().path.lowercased()
        let cleanupKey = MetadataIOKey.key(for: imageURL)
        let capturedGeneration = captionCaptureGenerations[captureKey, default: 0]
        writeTask?.cancel()
        writeTask = Task {
            defer { if writeTaskGeneration == generation { isSaving = false } }
            var metadataWasWritten = false
            do {
                let cleanup = try await sidecarService.captureWriteCleanupSnapshot(
                    for: imageURL, in: folderURL, editorRecord: editorRecord, requiresEditorMatch: true
                )
                // See writeMetadataAndPreserveHistory — leave the crs block alone
                // unless develop settings actually changed.
                let developChanged = Self.developSettingsChanged(
                    edited.cameraRaw, original?.cameraRaw
                )
                let fields = overwriteFields(
                    from: edited,
                    includeCameraRaw: developChanged,
                    imageAspect: { ImagePixelAspect.aspect(at: imageURL) }
                )
                let structuredData = developChanged
                    ? StructuredWriteData(
                        toneCurve: edited.cameraRaw?.toneCurve,
                        masks: edited.cameraRaw?.localAdjustments,
                        watermarkLayers: edited.cameraRaw?.watermarkLayers,
                        hslAdjustments: edited.cameraRaw?.hslAdjustments,
                        layerOrder: edited.cameraRaw?.layerOrder,
                        anonymizer: edited.cameraRaw?.anonymizer,
                        unparsedMaskCorrections: edited.cameraRaw?.unparsedMaskCorrections,
                        editorial: EditorialStructuredWriteData(metadata: edited),
                        replaceCameraRawBlock: true
                    )
                    : StructuredWriteData(editorial: EditorialStructuredWriteData(metadata: edited))
                let wroteToRawSidecar = SupportedImageFormats.isRaw(url: imageURL)
                if wroteToRawSidecar {
                    _ = try await descriptiveWriteBoundary.write(
                        metadata: edited,
                        for: imageURL,
                        requestedMode: .writeToFile,
                        semantics: .replace
                    )
                } else {
                    try await writeEngine.writeFields(fields, to: [imageURL], structuredData: structuredData)
                }

                metadataWasWritten = true
                // A later immutable Caption request still depends on this JSON revision. Keep it
                // until that request commits, even if the user has since selected another photo.
                guard captionCaptureGenerations[captureKey, default: 0] == capturedGeneration,
                      captionCleanupOwners[cleanupKey] == nil,
                      writeTaskGeneration == generation, metadataLoadRequestID == loadID,
                      currentFolderURL == folderURL, selectedURLs == [imageURL] else {
                    if writeTaskGeneration == generation, metadataLoadRequestID == loadID,
                       currentFolderURL == folderURL, selectedURLs == [imageURL] {
                        saveError = "Metadata was written, but a newer Caption draft is still pending. Its saved baseline was retained."
                    }
                    return
                }
                // Capture cannot publish a request based on the soon-to-be-deleted revision while
                // cleanup awaits its photo lock. Unchanged lifecycle captures remain no-ops.
                let cleanupOwner = CaptionMetadataCleanupPhase()
                captionCleanupOwners[cleanupKey] = cleanupOwner
                defer {
                    if captionCleanupOwners[cleanupKey] === cleanupOwner {
                        captionCleanupOwners[cleanupKey] = nil
                    }
                    cleanupOwner.finish()
                }
                let cleared = try await sidecarService.deleteSidecarAfterWriteSerialized(cleanup)
                guard writeTaskGeneration == generation, metadataLoadRequestID == loadID,
                      currentFolderURL == folderURL, selectedURLs == [imageURL] else { return }
                guard cleared else {
                    self.saveError = "Metadata was written, but newer pending sidecar changes were retained."
                    return
                }
                self.metadata = edited
                self.originalImageMetadata = edited
                if wroteToRawSidecar {
                    self.xmpMetadata = edited
                } else {
                    self.embeddedMetadata = edited
                }
                self.sidecarHistory = []
                self.selectedHavePendingSidecars = false
                self.cleanupBaseline = (imageURL, folderURL, nil)
                self.previousEditingMetadata = edited
                // The written revision is now the baseline, even if the user typed a newer value
                // while the writer ran. Preserve that buffer and keep Write & Next on this photo.
                self.hasChanges = self.editingMetadata != edited
            } catch {
                if writeTaskGeneration == generation, metadataLoadRequestID == loadID,
                   currentFolderURL == folderURL, selectedURLs == [imageURL] {
                    let prefix = metadataWasWritten
                        ? "Metadata was written, but pending sidecar cleanup did not finish. " : ""
                    self.saveError = prefix + error.localizedDescription
                }
            }
        }
    }

    func writeAllPendingChanges(in folderURL: URL?, images: [ImageFile], skipC2PA: Bool = true) {
        guard let folderURL else { return }
        // Image-list credential booleans may still be unloaded or stale. The service reads a
        // complete physical record for every discovered photo before choosing its destination.
        _ = images
        let requestID = UUID()
        let generation = batchProcessGeneration + 1
        let loadID = metadataLoadRequestID
        let selected = selectedURLs
        let editorAtAdmission = editingMetadata
        let discovery = pendingWriteDiscovery
        let executor = pendingWriteExecutor
        let engine = writeEngine
        let reader = readService
        isProcessingFolder = true
        folderProcessProgress = "0/?"
        pendingWriteBatchOutcome = nil
        saveError = nil
        batchProcessTask?.cancel()
        batchProcessTask = Task {
            defer {
                if batchProcessGeneration == generation {
                    isProcessingFolder = false
                    folderProcessProgress = ""
                }
            }
            let discovered = await discovery(folderURL)
            let records = discovered.records.sorted { $0.key.path < $1.key.path }
            var results: [PendingMetadataWriteResult] = []
            var cancelled = Task.isCancelled || discovered.wasCancelled
            if batchProcessGeneration == generation { folderProcessProgress = "0/\(records.count)" }
            let service = PendingMetadataWriteService(writeEngine: engine, readSourceFacts: { @MainActor url in
                let dictionaries = try await reader.readBatchBasicMetadata(urls: [url])
                guard dictionaries.count == 1, let dictionary = dictionaries.first,
                      let sourcePath = dictionary[MetadataDictKey.sourceFile] as? String,
                      URL(fileURLWithPath: sourcePath).standardizedFileURL.resolvingSymlinksInPath().path
                        == url.standardizedFileURL.resolvingSymlinksInPath().path else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [
                        NSLocalizedDescriptionKey: "Could not verify this photo's metadata and content-credential status.",
                        NSFilePathErrorKey: url.path
                    ])
                }
                return PendingMetadataSourceFacts(metadata: iptcMetadataFromDict(dictionary),
                    hasC2PA: TechnicalMetadata.dictHasC2PA(dictionary))
            })
            for (imageURL, sidecar) in records {
                guard !cancelled, !Task.isCancelled else { cancelled = true; break }
                let request = PendingMetadataWriteRequest(imageURL: imageURL, folderURL: folderURL,
                    expectedSidecar: sidecar, skipC2PA: skipC2PA)
                let result = if let executor { await executor(request) } else { await service.execute(request) }
                // Preserve a verified/uncertain admitted write even when cancellation arrived
                // during it. Remaining entries stay an explicit unattempted suffix.
                results.append(result)
                if batchProcessGeneration == generation { folderProcessProgress = "\(results.count)/\(records.count)" }
                if result.wasCancelled || Task.isCancelled { cancelled = true; break }
            }
            guard batchProcessGeneration == generation else { return }
            // Read the final pending state strictly; uncertainty must not become a false clean flag.
            let remaining = cancelled ? nil : await discovery(folderURL)
            cancelled = cancelled || Task.isCancelled || remaining?.wasCancelled == true
            var discoveryFailures = discovered.failures
            for failure in remaining?.failures ?? [] where !discoveryFailures.contains(where: { $0.url == failure.url && $0.message == failure.message }) {
                discoveryFailures.append(failure)
            }
            let outcome = PendingMetadataWriteBatchOutcome(requestID: requestID, folderURL: folderURL,
                results: results, discoveryFailures: discoveryFailures,
                unattemptedURLs: records.dropFirst(results.count).map(\.key), wasCancelled: cancelled,
                discoveryWasCancelled: discovered.wasCancelled || remaining?.wasCancelled == true)
            guard batchProcessGeneration == generation else { return }
            pendingWriteBatchOutcome = outcome
            guard
                  currentFolderURL?.standardizedFileURL.resolvingSymlinksInPath().path == folderURL.standardizedFileURL.resolvingSymlinksInPath().path,
                  metadataLoadRequestID == loadID, selectedURLs == selected,
                  editingMetadata == editorAtAdmission else { return }
            if let remaining, remaining.failures.isEmpty, !remaining.wasCancelled {
                let paths = Set(remaining.records.keys.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
                selectedHavePendingSidecars = selected.contains { paths.contains($0.standardizedFileURL.resolvingSymlinksInPath().path) }
            }
            saveError = outcome.attentionMessage
        }
    }

    func waitForPendingMetadataWriteBatch() async { await batchProcessTask?.value }

    // MARK: - Diff Helpers

    private var fieldComparisonMetadata: IPTCMetadata? {
        if currentHistoryRecord?.pendingChanges == true {
            return pendingDraftImageMetadataSnapshot ?? originalImageMetadata
        }
        return originalImageMetadata
    }

    func fieldDiffers(_ keyPath: KeyPath<IPTCMetadata, String?>) -> Bool {
        guard let original = fieldComparisonMetadata else { return false }
        return editingMetadata[keyPath: keyPath] != original[keyPath: keyPath]
    }

    func keywordsDiffer() -> Bool {
        guard let original = fieldComparisonMetadata else { return false }
        return editingMetadata.keywords != original.keywords
    }

    func personShownDiffer() -> Bool {
        guard let original = fieldComparisonMetadata else { return false }
        return editingMetadata.personShown != original.personShown
    }

    func organisationShownNamesDiffer() -> Bool {
        guard let original = fieldComparisonMetadata else { return false }
        return editingMetadata.organisationsShownNames != original.organisationsShownNames
    }

    func organisationShownCodesDiffer() -> Bool {
        guard let original = fieldComparisonMetadata else { return false }
        return editingMetadata.organisationsShownCodes != original.organisationsShownCodes
    }

    func sceneCodesDiffer() -> Bool {
        guard let original = fieldComparisonMetadata else { return false }
        return editingMetadata.sceneCodes != original.sceneCodes
    }

    func subjectCodesDiffer() -> Bool {
        guard let original = fieldComparisonMetadata else { return false }
        return editingMetadata.subjectCodes != original.subjectCodes
    }

    func mediaTopicsDiffer() -> Bool {
        guard let original = fieldComparisonMetadata else { return false }
        return editingMetadata.mediaTopics != original.mediaTopics
    }

    func genresDiffer() -> Bool {
        guard let original = fieldComparisonMetadata else { return false }
        return editingMetadata.genres != original.genres
    }

    func digitalSourceTypeDiffers() -> Bool {
        guard let original = fieldComparisonMetadata else { return false }
        return editingMetadata.digitalSourceType != original.digitalSourceType
    }

    func urgencyDiffers() -> Bool {
        guard let original = fieldComparisonMetadata else { return false }
        return editingMetadata.urgency != original.urgency
    }

    func gpsDiffers() -> Bool {
        guard let original = fieldComparisonMetadata else { return false }
        return editingMetadata.latitude != original.latitude || editingMetadata.longitude != original.longitude
    }

    var pendingFieldNames: [String] {
        guard let original = fieldComparisonMetadata else { return [] }
        var names: [String] = []
        if editingMetadata.title != original.title { names.append("Headline") }
        if editingMetadata.description != original.description { names.append("Description") }
        if editingMetadata.extendedDescription != original.extendedDescription { names.append("Extended Description") }
        if editingMetadata.keywords != original.keywords { names.append("Keywords") }
        if editingMetadata.personShown != original.personShown { names.append("Person Shown") }
        if editingMetadata.organisationsShownNames != original.organisationsShownNames { names.append("Organisation Shown Name") }
        if editingMetadata.organisationsShownCodes != original.organisationsShownCodes { names.append("Organisation Shown Code") }
        if editingMetadata.sceneCodes != original.sceneCodes { names.append("Scene Code") }
        if editingMetadata.subjectCodes != original.subjectCodes { names.append("Subject Code") }
        if editingMetadata.mediaTopics != original.mediaTopics { names.append("Media Topic") }
        if editingMetadata.genres != original.genres { names.append("Genre") }
        if editingMetadata.copyright != original.copyright { names.append("Copyright") }
        if editingMetadata.rightsUsageTerms != original.rightsUsageTerms { names.append("Rights Usage Terms") }
        if editingMetadata.webStatementOfRights != original.webStatementOfRights { names.append("Web Statement of Rights") }
        if editingMetadata.digitalImageGUID != original.digitalImageGUID { names.append("Digital Image GUID") }
        if editingMetadata.imageSupplierImageID != original.imageSupplierImageID { names.append("Image Supplier Image ID") }
        if editingMetadata.jobId != original.jobId { names.append("Job ID") }
        if editingMetadata.creators != original.creators { names.append("Creator") }
        if editingMetadata.creatorJobTitle != original.creatorJobTitle { names.append("Creator Job Title") }
        if editingMetadata.descriptionWriter != original.descriptionWriter { names.append("Description Writer") }
        if editingMetadata.credit != original.credit { names.append("Credit") }
        if editingMetadata.city != original.city { names.append("City") }
        if editingMetadata.sublocation != original.sublocation { names.append("Sublocation") }
        if editingMetadata.provinceState != original.provinceState { names.append("State / Province") }
        if editingMetadata.country != original.country { names.append("Country") }
        if editingMetadata.countryCode != original.countryCode { names.append("Country Code") }
        if editingMetadata.event != original.event { names.append("Event") }
        if editingMetadata.instructions != original.instructions { names.append("Instructions") }
        if editingMetadata.source != original.source { names.append("Source") }
        if editingMetadata.digitalSourceType != original.digitalSourceType { names.append("Digital Source Type") }
        if editingMetadata.urgency != original.urgency { names.append("Urgency") }
        if editingMetadata.rating != original.rating { names.append("Rating") }
        if editingMetadata.label != original.label { names.append("Label") }
        if editingMetadata.latitude != original.latitude || editingMetadata.longitude != original.longitude { names.append("GPS Coordinates") }
        if editingMetadata.captureDate != original.captureDate { names.append("Capture Date") }
        return names
    }

    var showDiscardConfirmation = false
    var showDiscardAllConfirmation = false

    /// Call this instead of discardPendingChanges() directly.
    /// Sets showDiscardConfirmation = true so a view can present an alert.
    func confirmDiscardPendingChanges() {
        showDiscardConfirmation = true
    }

    /// Call this instead of discardAllPendingInFolder() directly.
    /// Sets showDiscardAllConfirmation = true so a view can present an alert.
    func confirmDiscardAllPendingInFolder() {
        showDiscardAllConfirmation = true
    }

    @discardableResult
    func discardPendingChanges() -> Task<Void, Never>? {
        guard let folderURL = currentFolderURL, !selectedURLs.isEmpty else { return nil }
        let urls = selectedURLs
        let original = originalImageMetadata
        let edited = editingMetadata
        let fieldMutations = batchFieldMutations
        let locationsMutation = batchLocationsShownMutation
        let supplierMutation = batchImageSupplierMutation
        let precedingWrite = writeTask
        let loadID = metadataLoadRequestID
        let requestID = UUID()
        discardRequestID = requestID
        discardTask?.cancel()
        saveError = nil
        discardTask = Task {
            await precedingWrite?.value
            var failures = 0
            for imageURL in urls {
                do {
                    try Task.checkCancellation()
                    try await discardSidecar(imageURL, folderURL)
                } catch is CancellationError {
                    return
                } catch {
                    failures += 1
                }
            }
            // A completion for an older selection or draft must not reset current edits.
            guard discardRequestID == requestID,
                  metadataLoadRequestID == loadID,
                  currentFolderURL == folderURL, selectedURLs == urls,
                  editingMetadata == edited,
                  batchFieldMutations == fieldMutations,
                  batchLocationsShownMutation == locationsMutation,
                  batchImageSupplierMutation == supplierMutation else { return }
            guard failures == 0 else {
                saveError = "Failed to discard metadata sidecars for \(failures) image(s)."
                return
            }
            if urls.count == 1, let original {
                editingMetadata = original
                previousEditingMetadata = original
            } else {
                editingMetadata = IPTCMetadata()
                previousEditingMetadata = nil
                batchCommonMetadata = nil
                batchDifferingFields = []
                batchPartialKeywords = []
                batchPartialPersonShown = []
                batchListSelectionSummary = .empty
                batchFieldMutations = [:]
                batchLocationsShownMutation = .untouched
                batchImageSupplierMutation = .untouched
                batchMetadataByURL = [:]
            }
            hasChanges = false
            selectedHavePendingSidecars = false
            sidecarHistory = []
        }
        return discardTask
    }

    @discardableResult
    func discardAllPendingInFolder() -> Task<Void, Never>? {
        guard let folderURL = currentFolderURL else { return nil }
        let urls = selectedURLs
        let original = originalImageMetadata
        let edited = editingMetadata
        let fieldMutations = batchFieldMutations
        let locationsMutation = batchLocationsShownMutation
        let supplierMutation = batchImageSupplierMutation
        let precedingWrite = writeTask
        let loadID = metadataLoadRequestID
        let requestID = UUID()
        discardRequestID = requestID
        discardTask?.cancel()
        saveError = nil
        discardTask = Task {
            await precedingWrite?.value
            do {
                try Task.checkCancellation()
                try await discardFolderSidecars(folderURL)
            } catch is CancellationError {
                return
            } catch {
                guard discardRequestID == requestID,
                      currentFolderURL == folderURL, selectedURLs == urls,
                      metadataLoadRequestID == loadID,
                      editingMetadata == edited,
                      batchFieldMutations == fieldMutations,
                      batchLocationsShownMutation == locationsMutation,
                      batchImageSupplierMutation == supplierMutation else { return }
                saveError = "Failed to discard folder metadata sidecars: \(error.localizedDescription)"
                return
            }
            guard discardRequestID == requestID,
                  metadataLoadRequestID == loadID,
                  currentFolderURL == folderURL, selectedURLs == urls,
                  editingMetadata == edited,
                  batchFieldMutations == fieldMutations,
                  batchLocationsShownMutation == locationsMutation,
                  batchImageSupplierMutation == supplierMutation else { return }
            if urls.count == 1, let original {
                editingMetadata = original
                previousEditingMetadata = original
            } else {
                editingMetadata = IPTCMetadata()
                previousEditingMetadata = nil
                batchCommonMetadata = nil
                batchDifferingFields = []
                batchPartialKeywords = []
                batchPartialPersonShown = []
                batchListSelectionSummary = .empty
                batchFieldMutations = [:]
                batchLocationsShownMutation = .untouched
                batchImageSupplierMutation = .untouched
                batchMetadataByURL = [:]
            }
            hasChanges = false
            selectedHavePendingSidecars = false
            sidecarHistory = []
        }
        return discardTask
    }

    func clearHistory() {
        guard !isSaving, let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else { return }

        sidecarHistory = []

        let sidecar = MetadataSidecar(
            sourceFile: imageURL.lastPathComponent,
            lastModified: Date(),
            pendingChanges: hasChanges,
            metadata: editingMetadata,
            imageMetadataSnapshot: pendingDraftImageMetadataSnapshot,
            history: []
        )
        writeTask?.cancel()
        writeTask = Task {
            do {
                let installed = try await sidecarService.saveSidecarReplacingHistorySerialized(
                    sidecar,
                    for: imageURL,
                    in: folderURL
                )
                if selectedURLs == [imageURL], currentFolderURL == folderURL {
                    cleanupBaseline = (imageURL, folderURL, installed)
                }
            } catch {
                saveError = "Failed to save metadata sidecar: \(error.localizedDescription)"
            }
        }
    }

    private var currentWriteExpectedRecord: MetadataSidecar? {
        if let captured = capturedCaptionWriteExpectation,
           captured.loadID == metadataLoadRequestID,
           selectedURLs == [captured.request.imageURL],
           currentFolderURL == captured.request.folderURL {
            // The durable Caption barrier may complete inline before MainActor callbacks can run.
            // Accept only this exact captured revision; a replay rebased onto newer data must reload.
            return captured.request.sidecar
        }
        return currentHistoryRecord
    }

    private var currentHistoryRecord: MetadataSidecar? {
        guard selectedURLs.count == 1, let baseline = cleanupBaseline,
              baseline.imageURL == selectedURLs.first,
              baseline.folderURL == currentFolderURL else { return nil }
        return baseline.record
    }

    var canRestoreOriginalHistory: Bool { currentHistoryRecord?.imageMetadataSnapshot != nil }

    @discardableResult
    func restoreToOriginal() -> Task<Void, Never>? {
        guard let original = currentHistoryRecord?.imageMetadataSnapshot else {
            saveError = "The original metadata snapshot is unavailable. This older draft cannot safely restore Original State."
            return nil
        }
        return persistRestoredHistoryTarget(original)
    }

    @discardableResult
    func restoreToHistoryPoint(at index: Int) -> Task<Void, Never>? {
        guard let record = currentHistoryRecord,
              sidecarHistory.indices.contains(index),
              record.history.indices.contains(index),
              record.history == sidecarHistory else {
            saveError = "This history point is no longer available. Reload the photo and choose a retained point."
            return nil
        }
        // Reverse only later retained transitions from the actual current record. Replaying a
        // truncated prefix from the original snapshot would lose older edits absent from the log.
        var restored = record.metadata
        for entry in record.history.suffix(from: index + 1).reversed() {
            guard entry.isRestorable else {
                saveError = "Later history includes summarized or hidden values, so this point cannot be restored safely."
                return nil
            }
            var verified = restored
            guard entry.apply(to: &verified), verified == restored else {
                saveError = "The current metadata does not match its recorded history. Reload the photo before restoring."
                return nil
            }
            var prior = restored
            if let field = entry.fieldID {
                field.setHistoryValue(entry.oldValue, in: &prior)
            } else {
                let inverse = MetadataHistoryEntry(timestamp: entry.timestamp, fieldName: entry.fieldName,
                    oldValue: entry.newValue, newValue: entry.oldValue)
                guard inverse.apply(to: &prior) else {
                    saveError = "This history point contains a change that cannot be reversed safely."
                    return nil
                }
            }
            var roundTrip = prior
            guard entry.apply(to: &roundTrip), roundTrip == restored else {
                saveError = "This history point contains an invalid previous value and cannot be restored safely."
                return nil
            }
            restored = prior
        }
        return persistRestoredHistoryTarget(restored)
    }

    private func persistRestoredHistoryTarget(_ target: IPTCMetadata) -> Task<Void, Never>? {
        guard !isLoading, !isSaving, !hasUnpersistedEditorChanges,
              selectedCount == 1, let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL, let record = currentHistoryRecord else {
            saveError = "Finish saving the current edits, then reload the photo before restoring history."
            return nil
        }
        var displayedRecord = record.metadata
        displayedRecord.cameraRaw = editingMetadata.cameraRaw
        displayedRecord.exifOrientation = editingMetadata.exifOrientation
        guard displayedRecord == editingMetadata else {
            saveError = "The displayed metadata differs from the saved draft. Reload the photo before restoring history."
            return nil
        }
        var restored = target
        restored.cameraRaw = editingMetadata.cameraRaw
        restored.exifOrientation = editingMetadata.exifOrientation
        let timestamp = Date()
        var history = record.history
        history.append(contentsOf: MetadataHistoryEntry.changes(from: displayedRecord, to: restored, timestamp: timestamp))
        history.trimToHistoryLimit()
        let replacement = MetadataSidecar(sourceFile: imageURL.lastPathComponent,
            lastModified: timestamp, pendingChanges: true, metadata: restored,
            imageMetadataSnapshot: record.imageMetadataSnapshot, history: history)
        let request = MetadataSidecarRestoreRequest(sidecar: replacement, expectedSidecar: record,
            expectedXMPMetadata: xmpMetadata, imageURL: imageURL, folderURL: folderURL)
        let requestID = UUID()
        let loadID = metadataLoadRequestID
        let edited = editingMetadata
        let previousWrite = writeTask
        isSaving = true
        saveError = nil
        let task = Task {
            defer {
                if historyRestoreRequestID == requestID { isSaving = false }
            }
            // A normal metadata save already admitted before this action retains its completion.
            // The CAS will reject this restore if that save changed its captured source record.
            await previousWrite?.value
            guard !Task.isCancelled else {
                if historyRestoreRequestID == requestID, metadataLoadRequestID == loadID {
                    saveError = "Metadata restoration was cancelled before it started."
                }
                return
            }
            let result = await persistHistoryRestore(request)
            guard historyRestoreRequestID == requestID else { return }
            guard metadataLoadRequestID == loadID, selectedURLs == [imageURL],
                  currentFolderURL == folderURL, editingMetadata == edited else { return }
            if let installed = result.installedSidecar {
                cleanupBaseline = (imageURL, folderURL, installed)
                sidecarHistory = installed.history
                editingMetadata = installed.metadata
                editingMetadata.cameraRaw = edited.cameraRaw
                editingMetadata.exifOrientation = edited.exifOrientation
                previousEditingMetadata = editingMetadata
                hasChanges = true
                selectedHavePendingSidecars = true
                if result.completed {
                    xmpMetadata = editingMetadata
                    if metadataReferenceSource == .xmp {
                        metadata = editingMetadata
                        originalImageMetadata = editingMetadata
                    }
                }
            }
            if result.completed {
                saveError = nil
            } else {
                if let path = result.committedButUnverifiedSidecarURL {
                    saveError = "Restore wrote the metadata draft, but its current contents could not be verified. Reload before another action. Review: \(path.path). \(result.failure?.message ?? "The operation was cancelled.")"
                    return
                }
                let prefix = result.installedSidecar == nil
                    ? "Metadata was not restored."
                    : "The restored draft was saved, but its XMP mirror is incomplete. Choose Restore again to retry, or reload before another action."
                saveError = prefix + " " + (result.failure?.message ?? "The operation was cancelled.")
            }
        }
        writeTask = task
        historyRestoreRequestID = requestID
        return task
    }

    func clear() {
        metadata = nil
        editingMetadata = IPTCMetadata()
        selectedCount = 0
        selectedURLs = []
        hasChanges = false
        sidecarHistory = []
        originalImageMetadata = nil
        previousEditingMetadata = nil
        metadataReferenceSource = .embedded
    }
}
