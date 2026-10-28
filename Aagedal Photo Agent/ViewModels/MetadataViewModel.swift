import Foundation
import SwiftMediaMetadata
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

/// Outcome of saving the photos the Browser editor is leaving (selection change, folder switch,
/// workspace exit). The editor has usually moved on by the time it arrives, so the caller shows
/// `attentionMessage` somewhere that survives the change of selection.
nonisolated enum EditorBoundaryCommitOutcome: Sendable, Equatable {
    case nothingToCommit
    case saved
    /// A newer save of the same photo replaced this one; it carries these edits, so this is
    /// neither a failure nor a reason to write a fallback draft.
    case superseded
    /// The configured write failed; the edit was kept as a pending metadata draft instead.
    case keptAsDraft(message: String)
    /// Neither the write nor a pending draft succeeded (for example a read-only card). The edit
    /// exists only in the editor. `message` reads "Couldn't save your metadata edits to …: …".
    case failed(message: String)

    var preservesEdits: Bool {
        if case .failed = self { return false }
        return true
    }

    var attentionMessage: String? {
        switch self {
        case .nothingToCommit, .saved, .superseded: nil
        case .keptAsDraft(let message), .failed(let message): message
        }
    }

    static func failureMessage(files: String, reason: String) -> String {
        "Couldn't save your metadata edits to \(files): \(reason)"
    }
}

/// What a boundary that is leaving the Browser editor's photos does with a save outcome.
nonisolated enum EditorBoundaryDecision: Equatable {
    /// Continue the transition; show `attention` (if any) once it has happened.
    case proceed(attention: String?)
    /// Nothing durable holds the edit. Ask: discard the edits and continue, or stay.
    case askToDiscard(message: String)

    /// A selection change has already happened, so it cannot ask; a failed save there is
    /// reported as discarded. Folder, workspace and close transitions can still ask.
    static func resolve(_ outcome: EditorBoundaryCommitOutcome, canStay: Bool) -> EditorBoundaryDecision {
        switch outcome {
        case .nothingToCommit, .saved, .superseded:
            return .proceed(attention: nil)
        case .keptAsDraft(let message):
            return .proceed(attention: message)
        case .failed(let message):
            return canStay
                ? .askToDiscard(message: message)
                : .proceed(attention: message + " The edits were discarded.")
        }
    }
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
        var lines = ["Write All wrote \(completedCount), skipped \(skippedCount) and failed \(failedCount)."]
        if wasCancelled { lines.append("Cancelled after \(results.count) \(results.count == 1 ? "photo" : "photos"). \(unattemptedURLs.count) more \(unattemptedURLs.count == 1 ? "photo with unsaved changes wasn't" : "photos with unsaved changes weren't") started.") }
        if discoveryWasCancelled { lines.append("The search for photos with unsaved changes didn't finish, so some may not have been written.") }
        for failure in discoveryFailures { lines.append(Self.discoveryFailureSubject(failure.url) + ": " + failure.message) }
        for result in results where !result.completed {
            var message = result.imageURL.lastPathComponent + ": " + (result.failure ?? (result.wasSkipped ? "Skipped because the photo is protected." : "The changes weren't written."))
            var written: [String] = []
            if result.didWriteEmbedded { written.append("image metadata") }
            if result.didWriteXMP { written.append("XMP sidecar") }
            if !written.isEmpty { message += " Already written: " + written.joined(separator: " and ") + "." }
            if result.embeddedWriteMayHaveOccurred { message += " Image metadata may already have changed; check it before trying again." }
            if let path = result.committedButUnverifiedSidecarURL { message += " The app's saved edits for \(path.lastPathComponent.replacingOccurrences(of: ".meta.json", with: "")) couldn't be checked after saving. Reload the folder before editing it again." }
            lines.append(message)
        }
        return lines.joined(separator: "\n\n")
    }

    /// Discovery reads the app's per-photo `.meta.json` records; name the photo, not the record.
    private static func discoveryFailureSubject(_ url: URL) -> String {
        let name = url.lastPathComponent
        guard name.hasSuffix(".meta.json") else { return "This folder's saved edits" }
        return "Saved edits for " + name.replacingOccurrences(of: ".meta.json", with: "")
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
    var selectedURLs: [URL] = [] {
        didSet {
            AutomationDraftEditorAdmission.shared.update(owner: automationDraftEditorOwner,
                                                         selectedURLs: selectedURLs)
        }
    }
    @ObservationIgnored private let automationDraftEditorOwner = UUID()
    var hasChanges = false
    var isInEditView = false
    var saveError: String? {
        didSet { captionPersistenceFailureRequestID = nil }
    }
    @ObservationIgnored private var captionPersistenceFailureRequestID: UUID?
    private(set) var variableBatchOutcome: VariableMetadataBatchOutcome?
    private struct VariableCapturedBatchInput {
        let metadata: IPTCMetadata
        let previousCommon: IPTCMetadata?
        let fields: [MetadataFieldID: MetadataFieldMutation]
        let locations: BatchLocationsShownMutation
        let suppliers: EditorialImageSupplierMutation
        let keywordsMode: MultiSelectFieldMode
        let personMode: MultiSelectFieldMode
    }
    private final class VariableAdmission {
        let id: UUID
        let imageURL: URL
        let folderURL: URL
        let editorCheckpoint: CaptionConflictEditorCheckpoint?
        let loadID: UUID?
        let requiresPersistence: Bool
        let selectedURLs: [URL]
        let edited: IPTCMetadata
        let previous: IPTCMetadata?
        let expectedRecord: MetadataSidecar?
        let referenceSource: MetadataReferenceSource
        let hasEditorInput: Bool
        let batchInput: VariableCapturedBatchInput?
        let batchBaseline: IPTCMetadata?
        let options: VariableMetadataOptions
        let sequenceIndex: Int
        let previewAction: VoiceMemoVariablePreviewAction
        var cachedInput: VariableMetadataInputSnapshot?

        init(id: UUID, imageURL: URL, folderURL: URL, editorCheckpoint: CaptionConflictEditorCheckpoint?, loadID: UUID?,
             requiresPersistence: Bool, selectedURLs: [URL], edited: IPTCMetadata,
             previous: IPTCMetadata?, expectedRecord: MetadataSidecar?, referenceSource: MetadataReferenceSource,
             hasEditorInput: Bool, batchInput: VariableCapturedBatchInput?, batchBaseline: IPTCMetadata?,
             options: VariableMetadataOptions, sequenceIndex: Int,
             previewAction: VoiceMemoVariablePreviewAction) {
            self.id = id; self.imageURL = imageURL; self.folderURL = folderURL
            self.editorCheckpoint = editorCheckpoint; self.loadID = loadID; self.requiresPersistence = requiresPersistence
            self.selectedURLs = selectedURLs; self.edited = edited; self.previous = previous
            self.expectedRecord = expectedRecord; self.referenceSource = referenceSource
            self.hasEditorInput = hasEditorInput; self.batchInput = batchInput; self.batchBaseline = batchBaseline
            self.options = options; self.sequenceIndex = sequenceIndex
            self.previewAction = previewAction
        }
    }
    private var retainedVariableAdmissions: [VariableAdmission] = [] {
        didSet { variableRecoveryGeneration &+= 1 }
    }
    private var retainedVariableWrites: [VariableMetadataWriteRequest] = [] {
        didSet { variableRecoveryGeneration &+= 1 }
    }
    @ObservationIgnored private var variableRecoveryGeneration: UInt64 = 0
    @ObservationIgnored private var variableRecoveryOwnerID: UUID?
    private(set) var variableRecoveryPhotoURL: URL?
    @ObservationIgnored private var variableRecoverySnapshot: VariableConflictSnapshot?
    @ObservationIgnored private var variableRecoveryOperationID: UUID?
    @ObservationIgnored private var variableRecoveryEndRequested = false
    @ObservationIgnored private var variableQuiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var variableFailures: [String: String] = [:]
    @ObservationIgnored private var retainedVariableOrigins: [UUID: VariableAdmission] = [:]
    private struct PendingVoiceMemoVariablePreview {
        let id: UUID
        let folderURL: URL
        let requestIDs: [UUID]
    }
    @ObservationIgnored private var pendingVoiceMemoVariablePreviewState: PendingVoiceMemoVariablePreview?
    private(set) var voiceMemoVariablePreview: VoiceMemoVariableBatchPreview?
    @ObservationIgnored private let variableRecoveryExportAccess: CaptionConflictExportAccess
    @ObservationIgnored private let variableRecoveryBeforeDiscard: @Sendable () async -> Void
    @ObservationIgnored private let variableLifecycleOwnerID = UUID()
    @ObservationIgnored private let variableLifecycleCoordinator: VariableDraftLifecycleCoordinator
    @ObservationIgnored private var activeVariableBatchIDs: Set<UUID> = []
    @ObservationIgnored private var retainedVariableEditorCheckpoints: [UUID: CaptionConflictEditorCheckpoint] = [:]
    var hasRetainedVariableWrites: Bool { !retainedVariableWrites.isEmpty || !retainedVariableAdmissions.isEmpty || !variableDiscardedEditorCheckpoints.isEmpty }
    var variableProcessingStatus: String?
    var variableProcessingHadFailures = false
    var selectedHasC2PA = false
    /// The loaded photos known to carry Content Credentials. Automatic saves resolve their write
    /// mode from this editor-owned fact: by the time a selection or folder change saves, the
    /// browser's arrays may already describe the next selection (or be empty).
    private(set) var selectedC2PAURLs: Set<URL> = []
    /// The folder the editor's current photos were loaded from. A folder switch can publish the
    /// next folder into `currentFolderURL` before the departing photos' save is admitted.
    private(set) var editorFolderURL: URL?
    var descriptionConflict: DescriptionConflict?
    /// Non-blocking notice rendered as a dismissible banner in the metadata panel.
    /// Set by bulk-add paths (template apply, partial promotion, Quick List pick)
    /// when entries are rejected or canonicalised against the approved list.
    /// Notices describe the photos they were raised for, so loading another selection clears
    /// them (except a navigation-boundary notice, which must survive its own navigation).
    var notice: MetadataPanelNotice? {
        didSet { noticeSurvivesNextSelectionLoad = false }
    }
    @ObservationIgnored private var noticeSurvivesNextSelectionLoad = false

    var originalImageMetadata: IPTCMetadata?
    var embeddedMetadata: IPTCMetadata?
    var xmpMetadata: IPTCMetadata?
    @ObservationIgnored private var editorXMPWriteBaseline: (imageURL: URL, folderURL: URL?, loadID: UUID?, snapshot: XMPSidecarWriteSnapshot?, failure: String?)?
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
    /// Incremented whenever the editor's develop settings are replaced from outside Develop
    /// (Reset All Edits). Develop ends its undo history on it: Undo must not resurrect them.
    private(set) var developSettingsReplacementGeneration: Int = 0
    /// Identity used to reject UI buffers registered for a previous load of the same photo.
    var editorBufferLoadID: UUID? { metadataLoadRequestID }

    var hasXmpMetadata: Bool { xmpMetadata != nil }
    var hasEmbeddedCropNotLoaded: Bool {
        guard embeddedCropForImport != nil else { return false }
        return editingMetadata.cameraRaw?.crop?.hasCrop != true
    }
    /// The file-embedded crop "Load Embedded Crop" applies. Develop routes it through its own
    /// undoable, version-aware settings mutation instead of `importEmbeddedCrop()`.
    var embeddedCropForImport: CameraRawCrop? {
        guard let embeddedCrop = embeddedMetadata?.cameraRaw?.crop,
              embeddedCrop.hasCrop == true else { return nil }
        return embeddedCrop
    }
    var referenceMetadata: IPTCMetadata? {
        referenceMetadata(
            for: metadataReferenceSource,
            embedded: embeddedMetadata,
            xmp: xmpMetadata,
            imageURL: selectedURLs.count == 1 ? selectedURLs.first : nil
        )
    }
    var canWriteMetadataToImage: Bool { canWriteMetadataToImage() }

    func canWriteMetadataToImage(knownC2PAURLs: Set<URL> = []) -> Bool {
        if isSaving { return false }
        if hasChanges || selectedHavePendingSidecars { return true }
        // The editor can show values the file itself lacks (for example an XMP reference copy
        // of a JPEG). Only a mode that embeds can write those into the file; a sidecar-mode save
        // never updates `embeddedMetadata`, so comparing it there kept Write enabled forever.
        if selectedCount == 1, let embedded = embeddedMetadata,
           let url = selectedURLs.first, !SupportedImageFormats.isRaw(url: url),
           editorWriteMode(knownC2PAURLs: knownC2PAURLs).writesEmbedded {
            return editingMetadata != embedded
        }
        return false
    }

    /// The write mode for the photos this editor holds. `knownC2PAURLs` adds Content Credentials
    /// a caller learned after the load (the browser detects C2PA asynchronously).
    func editorWriteMode(knownC2PAURLs: Set<URL> = []) -> MetadataWriteMode {
        MetadataWriteMode.current(forURLs: selectedURLs, c2paURLs: selectedC2PAURLs.union(knownC2PAURLs))
    }

    // Batch metadata state - stores common values across selected images
    var batchCommonMetadata: IPTCMetadata?
    var batchDifferingFields: Set<String> = []
    var batchPartialKeywords: [String] = []
    var batchPartialPersonShown: [String] = []
    var batchListSelectionSummary = BatchMetadataListSelectionSummary.empty
    private(set) var batchFieldMutations: [MetadataFieldID: MetadataFieldMutation] = [:]
    /// The editor value each scalar text intent in `batchFieldMutations` was recorded against.
    /// Typing into the field afterwards replaces the template's intent with the typed value.
    @ObservationIgnored private var batchTextIntentEditorValues: [MetadataFieldID: String?] = [:]
    /// Identity of each pending `.appendText` intent. A later template append that extends a
    /// still-pending intent keeps its token, so `textAppendLedger` can tell which part of it
    /// each photo's records already received.
    @ObservationIgnored private var batchTextAppendTokens: [MetadataFieldID: UUID] = [:]
    /// Which template text appends each photo's records already received. Shared by reference
    /// with captured batch mutations, which consult it when they are applied, so a save queued
    /// behind (or retried after) a partial save, or a dual-write XMP phase, never appends twice.
    @ObservationIgnored private let textAppendLedger = BatchTextAppendLedger()
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

    /// Literal placeholders belong to the variable transaction, not the ordinary focus-loss
    /// writer. Writing them first would change the transaction's baseline underneath it.
    var shouldDeferAutomaticCommitForVariables: Bool {
        hasUnpersistedEditorChanges && hasVariables
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
    /// Selection loaded ahead of the debounced selection load (a template shortcut pressed
    /// right after navigating). That debounced load must not replace the applied template.
    @ObservationIgnored private var eagerSelectionLoadURLs: Set<URL>?
    @ObservationIgnored private var metadataLoadRequestID: UUID? {
        didSet { if oldValue != metadataLoadRequestID { editorXMPWriteBaseline = nil; primaryDevelopSourceBaseline = nil } }
    }
    /// The selection the current (or most recent) metadata load is for. Set before the load
    /// publishes `selectedURLs`, so picks made while waiting key to the photos being loaded.
    @ObservationIgnored private var loadingSelection: (urls: [URL], folderURL: URL?)?
    /// Keyword / Person Shown picks made while the editor was still loading. The empty
    /// placeholder editor cannot be saved and the load replaces it, so these run once the
    /// load for the same selection completes (and are dropped if the selection changes).
    @ObservationIgnored private var deferredLoadActions: (urls: [URL], folderURL: URL?,
        actions: [@MainActor () -> Bool], commit: @MainActor () -> Void)?
    @ObservationIgnored private var writeTask: Task<Void, Never>? {
        willSet {
            historyRestoreRequestID = nil
            writeTaskGeneration += 1
        }
    }
    @ObservationIgnored private var writeTaskGeneration = 0
    /// The single-photo save that currently owns `writeTask`, if any (see `priorWriteForSingleSave`).
    @ObservationIgnored private var supersedableSingleSave: (generation: Int, imageURL: URL, loadID: UUID?)?
    /// Failures of embedded writes keyed by their write generation, so a caller chained behind
    /// other writes reads its own outcome instead of the shared, overwritable `saveError`.
    @ObservationIgnored private var embeddedWriteFailures: [Int: String] = [:]
    @ObservationIgnored private var primaryDevelopSourceBaseline: (imageURL: URL, loadID: UUID, revision: SourceImageRevision)?
    private(set) var retainedPrimaryDevelopWrites: [PrimaryDevelopWriteRequest] = []
    @ObservationIgnored private var primaryDevelopResults: [UUID: PrimaryDevelopWriteResult] = [:]
    @ObservationIgnored private var primaryDevelopTask: Task<Void, Never>?
    private(set) var primaryDevelopActiveCount = 0
    @ObservationIgnored private let primaryDevelopOwnerID = UUID()
    @ObservationIgnored private let primaryDevelopLifecycle: DevelopPrimaryLifecycleCoordinator
    @ObservationIgnored private let primaryDevelopExecutor: (@Sendable (PrimaryDevelopWriteRequest) async -> PrimaryDevelopWriteResult)?
    @ObservationIgnored private var primaryDevelopGeneration: UInt64 = 0
    private(set) var primaryDevelopRecoveryPhotoURL: URL?
    private(set) var primaryDevelopRecoveryReloadGeneration = 0
    @ObservationIgnored private var primaryDevelopReview: VariableConflictSnapshot?
    @ObservationIgnored private var primaryDevelopReviewOwner: UUID?
    @ObservationIgnored private var primaryDevelopRecoveryOperation = false
    @ObservationIgnored private var primaryDevelopRecoveryEndRequested = false
    @ObservationIgnored private var primaryDevelopRecoveryLoadGuard: (loadID: UUID?, edited: IPTCMetadata)?
    @ObservationIgnored private var primaryDevelopEditorBarrier: (owner: UUID, handler: @MainActor () throws -> Void)?
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
    @ObservationIgnored private let voiceMemoTranscriptContextLoader: @Sendable (URL) async throws -> VoiceMemoTranscriptVariableContext
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
        variableRecoveryExportAccess: CaptionConflictExportAccess = .init(),
        variableRecoveryBeforeDiscard: @escaping @Sendable () async -> Void = {},
        variableOptions: @escaping @MainActor () -> VariableMetadataOptions = { .capture() },
        variableResolver: @escaping @MainActor @Sendable (VariableMetadataResolutionInput) async throws -> IPTCMetadata = {
            try await VariableMetadataResolver.resolve($0)
        },
        voiceMemoTranscriptContextLoader: @escaping @Sendable (URL) async throws -> VoiceMemoTranscriptVariableContext = { imageURL in
            try await VoiceMemoTranscriptionService().readyVariableContext(imageURL: imageURL)
        },
        primaryDevelopLifecycle: DevelopPrimaryLifecycleCoordinator = .shared,
        primaryDevelopExecutor: (@Sendable (PrimaryDevelopWriteRequest) async -> PrimaryDevelopWriteResult)? = nil
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
        self.variableRecoveryExportAccess = variableRecoveryExportAccess
        self.variableRecoveryBeforeDiscard = variableRecoveryBeforeDiscard
        self.variableOptions = variableOptions
        self.variableResolver = variableResolver
        self.voiceMemoTranscriptContextLoader = voiceMemoTranscriptContextLoader
        self.primaryDevelopLifecycle = primaryDevelopLifecycle
        self.primaryDevelopExecutor = primaryDevelopExecutor
    }

    deinit {
        AutomationDraftEditorAdmission.shared.remove(owner: automationDraftEditorOwner)
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
            let raw = AppDefaults.store.string(forKey: UserDefaultsKeys.multiSelectKeywordsMode)
                ?? MultiSelectFieldMode.add.rawValue
            return MultiSelectFieldMode(rawValue: raw) ?? .add
        case "personShown":
            let raw = AppDefaults.store.string(forKey: UserDefaultsKeys.multiSelectPersonShownMode)
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
        EffectiveMetadataResolver.physicalMetadata(for: source, embedded: embedded, xmp: xmp,
            isRaw: imageURL.map { SupportedImageFormats.isRaw(url: $0) } ?? false)
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
        return try EffectiveMetadataResolver.resolve(embedded: embedded, facts: facts,
            isRaw: SupportedImageFormats.isRaw(url: imageURL)).metadata
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

    /// The debounced browser-selection load. Skipped when `loadSelectionMetadataNow` already
    /// loaded exactly this selection, so edits applied since then survive.
    func loadSelectionMetadata(for images: [ImageFile], folderURL: URL?) {
        let urls = Set(images.map(\.url))
        if let held = heldSelectionURL?.standardizedFileURL,
           selectedURLs.count == 1, selectedURLs[0].standardizedFileURL == held {
            // Caption is holding this photo open until its draft is captured. Any selection
            // load — the browser dropping it from the filter, or reselecting it when it comes
            // back — would replace the uncaptured draft.
            return
        }
        if let eager = eagerSelectionLoadURLs, eager == urls, Set(selectedURLs) == urls {
            eagerSelectionLoadURLs = nil
            return
        }
        loadMetadata(for: images, folderURL: folderURL)
    }

    /// A photo Caption keeps open after it left the browser's filtered list, until its draft has
    /// been captured. Only the debounced browser-selection load honours it.
    @ObservationIgnored private(set) var heldSelectionURL: URL?

    func holdSelection(on imageURL: URL) { heldSelectionURL = imageURL }

    func releaseSelectionHold() { heldSelectionURL = nil }

    /// Loads a new browser selection immediately, ahead of its debounced selection load.
    func loadSelectionMetadataNow(for images: [ImageFile], folderURL: URL?) {
        loadMetadata(for: images, folderURL: folderURL)
        eagerSelectionLoadURLs = Set(images.map(\.url))
    }

    /// Waits until the current metadata load (including one it hands over to) has finished.
    func waitForMetadataLoad() async {
        while let task = metadataLoadTask {
            await task.value
            if metadataLoadTask == task { return }
        }
    }

    /// `preservingUnsavedEdits`: a passive refresh of the same photo/batch (folder auto-refresh)
    /// keeps edits the user has not persisted yet and only advances their baseline. Explicit
    /// reloads (discard, recovery) leave it false and replace the editor.
    func loadMetadata(for images: [ImageFile], folderURL: URL? = nil, preservingUnsavedEdits: Bool = false) {
        if let eager = eagerSelectionLoadURLs, eager != Set(images.map(\.url)) { eagerSelectionLoadURLs = nil }
        metadataLoadTask?.cancel()
        metadataLoadTask = nil
        // The replacement request owns both flags, including single/batch transitions.
        isLoading = false
        isLoadingBatchMetadata = false
        let loadFolderURL = folderURL ?? currentFolderURL
        loadingSelection = (images.map(\.url), loadFolderURL)
        if let deferred = deferredLoadActions,
           deferred.urls != images.map(\.url) || deferred.folderURL != loadFolderURL {
            deferredLoadActions = nil
        }
        if images.count == 1,
           let image = images.first,
           let phase = captionCleanupOwners[MetadataIOKey.key(for: image.url)] {
            isLoading = true
            metadataLoadTask = Task {
                await phase.waitUntilFinished()
                guard !Task.isCancelled else { return }
                metadataLoadTask = nil
                loadMetadata(for: images, folderURL: folderURL, preservingUnsavedEdits: preservingUnsavedEdits)
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
        let isReloadingSameImage = images.count == 1 && previousSelectedURLs.count == 1
            && previousSelectedURLs.first == images[0].url && metadata != nil
        // A passive reload of the same photo/batch (folder auto-refresh) must not replace edits
        // the user has not persisted yet; the load then refreshes only their baselines.
        let preservesUnsavedEdits = preservingUnsavedEdits
            && (isReloadingSameBatch || isReloadingSameImage)
            && hasUnpersistedEditorChanges

        selectedCount = images.count
        selectedURLs = images.map(\.url)
        hasChanges = preservesUnsavedEdits
        selectedHavePendingSidecars = false
        saveError = nil
        variableProcessingStatus = nil
        selectedHasC2PA = images.contains { $0.hasC2PA }
        selectedC2PAURLs = Set(images.filter(\.hasC2PA).map(\.url))
        descriptionConflict = nil
        sidecarHistory = []
        if !isReloadingSameBatch && !isReloadingSameImage {
            if noticeSurvivesNextSelectionLoad {
                noticeSurvivesNextSelectionLoad = false
            } else if notice != nil {
                notice = nil
            }
        }
        // A passive reload that keeps unsaved edits also keeps their diff baseline until the
        // fresh one arrives: a save issued meanwhile must not see "no baseline" and treat every
        // field — including an unchanged crs block — as changed.
        if !preservesUnsavedEdits { originalImageMetadata = nil }
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
        } else if !preservesUnsavedEdits {
            // This reload replaces the editor with the files' values, so explicit list changes
            // it no longer shows must not ride along into the next save.
            batchFieldMutations = [:]
            batchLocationsShownMutation = .untouched
            batchImageSupplierMutation = .untouched
        }

        if let folderURL {
            currentFolderURL = folderURL
        }
        let folderSnapshot = currentFolderURL
        editorFolderURL = folderSnapshot

        guard !images.isEmpty else {
            metadata = nil
            editingMetadata = IPTCMetadata()
            previousEditingMetadata = nil
            embeddedMetadata = nil
            xmpMetadata = nil
            isLoading = false
            isLoadingBatchMetadata = false
            batchMetadataByURL = [:]
            deferredLoadActions = nil
            return
        }

        if images.count == 1 {
            batchMetadataByURL = [:]
            let imageURL = images[0].url

            // When reloading the same image (e.g. auto-refresh after external edit),
            // skip the synchronous reset to avoid flashing the preview to unedited state.
            if !isReloadingSameImage {
                metadata = nil
                editingMetadata = IPTCMetadata()
                previousEditingMetadata = nil
            }
            isLoading = true

            metadataLoadTask = Task {
                var loaded = false
                defer {
                    // Several guards below return early without reaching the tail that ends the
                    // load. When that happens to the still-current request (not one cancelled or
                    // superseded by a newer owner), end the load here: otherwise the editor stays
                    // loading forever and queued picks block every Caption flush.
                    if !Task.isCancelled, self.metadataLoadRequestID == requestID, self.isLoading {
                        self.isLoading = false
                        self.deferredLoadActions = nil
                        if self.metadata == nil, self.saveError == nil {
                            self.saveError = "The photo's metadata could not be loaded. Select it again to retry."
                        }
                    }
                }
                let loadStart = ContinuousClock.now
                self.perfLog.info("[MetadataVM] loadMetadata START — \(imageURL.lastPathComponent, privacy: .private(mask: .hash))")
                do {
                    if self.isPendingBatchWrite(imageURL) {
                        await self.waitForPendingWrites()
                        guard !Task.isCancelled, self.metadataLoadRequestID == requestID else { return }
                    }
                    let sourceBefore = try? await SourceImageRevision.capture(at: imageURL)
                    // A cancelled capture is intentionally optional evidence, but must not
                    // enqueue an obsolete metadata read ahead of the next selected photo.
                    guard !Task.isCancelled, self.metadataLoadRequestID == requestID else { return }
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
                    let sourceAfter = try? await SourceImageRevision.capture(at: imageURL)
                    guard self.metadataLoadRequestID == requestID, !Task.isCancelled else { return }
                    if let recovery = self.primaryDevelopRecoveryLoadGuard, recovery.loadID == requestID,
                       self.editingMetadata != recovery.edited {
                        self.isLoading = false
                        self.deferredLoadActions = nil
                        return
                    }
                    if let sourceBefore, let sourceAfter, sourceBefore.canonicalURL == sourceAfter.canonicalURL,
                       sourceBefore.sha256 == sourceAfter.sha256 {
                        self.primaryDevelopSourceBaseline = (imageURL, requestID, sourceAfter)
                    }
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
                    // A sidecar-only photo whose XMP sidecar carries the description is not
                    // affected by its file's internal disagreement — resolving it saves to the
                    // sidecar, so showing the banner would bring it back on every load.
                    let sidecarOwnsDescription = referenceSource == .xmp && xmpMeta?.description != nil
                        && !MetadataWriteMode.current(forC2PA: images[0].hasC2PA,
                            isRaw: SupportedImageFormats.isRaw(url: imageURL)).writesEmbedded
                    self.descriptionConflict = sidecarOwnsDescription ? nil : conflict
                    self.xmpMetadata = xmpMeta
                    self.editorXMPWriteBaseline = (imageURL, folderSnapshot, requestID,
                        sourceFacts.xmpWriteSnapshot, sourceFacts.xmpReadFailure)
                    self.metadataReferenceSource = referenceSource
                    self.metadata = baseMeta
                    self.originalImageMetadata = baseMeta

                    self.cleanupBaseline = (imageURL, folderSnapshot, sourceFacts.appSidecar)
                    var newEditingMetadata = baseMeta
                    if let sidecar = sourceFacts.appSidecar {
                        self.sidecarHistory = sidecar.history
                        self.sidecarHistory.trimToHistoryLimit()
                        if sidecar.pendingChanges {
                            newEditingMetadata = EffectiveMetadataResolver.applyingPendingDraft(
                                sidecar, to: newEditingMetadata)
                            self.hasChanges = true
                            // A loaded draft still needs an explicit Write (and offers Discard),
                            // as it does for a batch.
                            self.selectedHavePendingSidecars = true
                        }
                    }
                    // Always update on first load. A same-photo reload keeps unsaved edits and
                    // only advances the baseline they will be saved (and diffed) against.
                    if preservesUnsavedEdits, self.hasUnpersistedEditorChanges {
                        self.previousEditingMetadata = newEditingMetadata
                        self.hasChanges = true
                    } else {
                        if self.editingMetadata != newEditingMetadata {
                            self.editingMetadata = newEditingMetadata
                        }
                        self.previousEditingMetadata = self.editingMetadata
                    }
                    self.metadataLoadGeneration += 1
                    let totalMs = loadStart.elapsedMilliseconds()
                    self.perfLog.info("[MetadataVM] loadMetadata DONE — \(imageURL.lastPathComponent, privacy: .private(mask: .hash)) total \(totalMs)ms")
                    self.logger.info("[\(imageURL.lastPathComponent, privacy: .private(mask: .hash))] loadMetadata result: xmp=\(xmpMeta != nil), stale=\(sidecarIsStale), ref=\(String(describing: referenceSource), privacy: .public), reloadSame=\(isReloadingSameImage), title=\(self.editingMetadata.title ?? "nil", privacy: .private(mask: .hash))")
                    if self.metadataReferenceSource == .xmp, self.xmpMetadata == nil {
                        self.metadataReferenceSource = .embedded
                    }
                    loaded = true
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
                if loaded { self.runDeferredLoadActions() } else { self.deferredLoadActions = nil }
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
                    isReload: preservesUnsavedEdits,
                    requestID: requestID,
                    folderURL: folderSnapshot
                )
                guard !Task.isCancelled else { return }
                guard self.metadataLoadRequestID == requestID,
                      self.currentFolderURL == folderSnapshot,
                      self.selectedURLs == images.map(\.url) else { return }
                self.isLoadingBatchMetadata = false
                self.runDeferredLoadActions()
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
        } catch is CancellationError {
            // Superseded by a newer selection; its load owns the editor now.
            return
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
        // Pre-populate editing metadata with common values. A redundant reload of the same
        // batch (e.g. auto-refresh) keeps the user's in-progress edits and their diff baseline.
        if isReload, hasChanges {
            return
        }
        if self.editingMetadata != common {
            self.editingMetadata = common
        }
        self.previousEditingMetadata = common
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

    /// Applies the explicit scalar text intents a batch template recorded, per photo.
    nonisolated static func applyingBatchTextMutations(
        _ mutations: [MetadataFieldID: MetadataFieldMutation],
        to metadata: IPTCMetadata
    ) throws -> IPTCMetadata {
        var result = metadata
        for field in MetadataFieldID.allCases where !field.isRepeatable {
            guard let mutation = mutations[field] else { continue }
            try result.apply(mutation, to: field)
        }
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
        switch batchTextIntent(for: field) {
        case .appendText(let text)?:
            return "Will append “\(text)” to each of \(selectedCount) photos"
        case .clear?:
            return "Will be cleared on all \(selectedCount) photos"
        case .fillIfEmpty(.scalar(let text))?:
            let count = batchEmptyPhotoCount(for: field)
            return "Will fill “\(text)” where empty on \(count) \(count == 1 ? "photo" : "photos")"
        default:
            break
        }
        if batchDifferingFields.contains(field) {
            return "Multiple values"
        }
        // Emptying a value every selected photo shared clears it on save (Photo Mechanic).
        if let path = MetadataEditorFieldPaths.scalarText(for: field),
           let common = previousEditingMetadata?[keyPath: path], !common.isEmpty,
           (editingMetadata[keyPath: path] ?? "").isEmpty {
            return "Will be cleared on all \(selectedCount) photos"
        }
        return "Leave empty to skip"
    }

    /// How many selected photos have no value for an editor field key (for batch placeholders).
    private func batchEmptyPhotoCount(for key: String) -> Int {
        guard let field = MetadataFieldID(rawValue: key), !batchMetadataByURL.isEmpty else { return selectedCount }
        return batchMetadataByURL.values.filter { field.isEmpty(in: $0) }.count
    }

    /// Partial keywords not yet added to every photo by the editor. A partial value the user
    /// typed (or picked) is now common, so it must not also show as a partial chip.
    var visibleBatchPartialKeywords: [String] {
        let common = Set(editingMetadata.keywords)
        return batchPartialKeywords.filter { !common.contains($0) }
    }

    var visibleBatchPartialPersonShown: [String] {
        let common = Set(editingMetadata.personShown)
        return batchPartialPersonShown.filter { !common.contains($0) }
    }

    /// After a batch save, values written to every photo are no longer partial. Overwrite mode
    /// replaced each photo's list, so nothing remains partial.
    private func reconcileBatchPartials(afterSaving saved: IPTCMetadata) {
        if multiSelectMode(for: "keywords") == .overwrite, !saved.keywords.isEmpty {
            batchPartialKeywords = []
        } else {
            let common = Set(saved.keywords)
            batchPartialKeywords.removeAll { common.contains($0) }
        }
        if multiSelectMode(for: "personShown") == .overwrite, !saved.personShown.isEmpty {
            batchPartialPersonShown = []
        } else {
            let common = Set(saved.personShown)
            batchPartialPersonShown.removeAll { common.contains($0) }
        }
    }

    /// Returns true if a field has differing values across the batch selection
    func fieldHasMultipleValues(_ field: String) -> Bool {
        batchDifferingFields.contains(field)
    }

    func markChanged() {
        hasChanges = true
    }

    /// True while a single-photo or batch metadata load still owns the editor.
    var isEditorLoading: Bool { isLoading || isLoadingBatchMetadata }

    /// The editor shows the empty placeholder of an in-flight load (not a same-selection
    /// reload, which keeps the loaded fields). It has no verified baseline to save against.
    var isShowingLoadPlaceholder: Bool {
        (isLoading && metadata == nil) || (isLoadingBatchMetadata && batchCommonMetadata == nil)
    }

    /// Runs `action` now, or — while the editor is still loading — once the load for the
    /// photos being loaded completes. Picks made against the empty placeholder editor would
    /// otherwise fail the save's XMP evidence check and then be replaced by the load.
    /// `action` returns whether it changed the editor; `commit` runs once afterwards if any
    /// deferred action did (the latest caller's commit wins).
    func performAfterEditorLoad(
        commit: @escaping @MainActor () -> Void,
        _ action: @escaping @MainActor () -> Bool
    ) {
        // Only the empty placeholder of an in-flight load defers: a same-selection reload or a
        // load waiting on caption cleanup still shows a real, saveable editor for its photos.
        guard isShowingLoadPlaceholder, let selection = loadingSelection else {
            if action() { commit() }
            return
        }
        if let deferred = deferredLoadActions,
           deferred.urls == selection.urls, deferred.folderURL == selection.folderURL {
            deferredLoadActions?.actions.append(action)
            deferredLoadActions?.commit = commit
        } else {
            deferredLoadActions = (selection.urls, selection.folderURL, [action], commit)
        }
    }

    /// Keyword/person picks made against the load placeholder that are still queued for the
    /// in-flight load. They live outside `editingMetadata` until the load finishes, so a flush
    /// barrier must treat them as edits: replacing this load would drop them.
    var hasDeferredEditorActions: Bool {
        guard let deferred = deferredLoadActions, let selection = loadingSelection,
              !deferred.actions.isEmpty else { return false }
        return deferred.urls == selection.urls && deferred.folderURL == selection.folderURL
    }

    private func runDeferredLoadActions() {
        guard let deferred = deferredLoadActions else { return }
        deferredLoadActions = nil
        guard deferred.urls == selectedURLs, deferred.folderURL == currentFolderURL else { return }
        var changed = false
        for action in deferred.actions where action() { changed = true }
        if changed { deferred.commit() }
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

    /// Picks one of the file's disagreeing descriptions. The choice must then be saved so both
    /// containers agree — call `commitEdits` afterwards. When the chosen text is what the editor
    /// already shows, nothing would look changed and the save would be skipped (bringing the
    /// banner back on the next load), so the baseline records the losing container's text: that
    /// is literally what one of the containers still holds.
    func resolveDescriptionConflict(keepXMP: Bool) {
        guard let conflict = descriptionConflict else { return }
        let chosen = keepXMP ? conflict.xmpDescription : conflict.iptcCaptionAbstract
        let losing = keepXMP ? conflict.iptcCaptionAbstract : conflict.xmpDescription
        let chosenValue: String? = chosen.isEmpty ? nil : chosen
        editingMetadata.description = chosenValue
        descriptionConflict = nil
        if selectedCount == 1, previousEditingMetadata?.description == chosenValue {
            previousEditingMetadata?.description = losing.isEmpty ? nil : losing
        }
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
        developSettingsReplacementGeneration += 1
        metadataLoadGeneration += 1
    }

    func importEmbeddedCrop() {
        guard let embeddedCrop = embeddedCropForImport else { return }
        if editingMetadata.cameraRaw == nil {
            editingMetadata.cameraRaw = CameraRawSettings()
        }
        editingMetadata.cameraRaw?.crop = embeddedCrop
        markChanged()
    }

    func hasUncapturedPrimaryDevelopEdits(mode: MetadataWriteMode) -> Bool {
        guard hasUnpersistedEditorChanges else { return false }
        // A retained Reset keeps its captured dual destination even when the lifecycle's
        // ordinary capture mode is XMP. A mode change never replaces that owned intent.
        let latest = retainedPrimaryDevelopWrites.last {
            $0.imageURL == selectedURLs.first && selectedURLs.count == 1 && $0.folderURL == currentFolderURL
                && $0.loadID == metadataLoadRequestID
        }
        return latest?.edited != editingMetadata
    }
    var hasRetainedPrimaryDevelopWrites: Bool { !retainedPrimaryDevelopWrites.isEmpty || primaryDevelopActiveCount > 0 || primaryDevelopReviewOwner != nil }
    var primaryDevelopRecoveryPhotos: [URL] {
        var seen = Set<String>()
        return retainedPrimaryDevelopWrites.map(\.imageURL).filter { seen.insert(Self.variablePhotoKey($0)).inserted }
    }
    func registerPrimaryDevelopRecoveryEditorBarrier(owner: UUID, handler: @escaping @MainActor () throws -> Void) {
        primaryDevelopEditorBarrier = (owner, handler)
    }
    func unregisterPrimaryDevelopRecoveryEditorBarrier(owner: UUID) {
        if primaryDevelopEditorBarrier?.owner == owner { primaryDevelopEditorBarrier = nil }
    }
    func waitForPrimaryDevelopWrites() async { await primaryDevelopTask?.value }
    func requirePrimaryDevelopWritesPersisted() throws {
        guard !hasRetainedPrimaryDevelopWrites else {
            throw PrimaryDevelopWriteError(message: "This photo has Develop edits that haven't been saved yet. Try saving again, or export them for review, before leaving.")
        }
    }
    private func synchronizePrimaryDevelopRetention() {
        primaryDevelopGeneration &+= 1
        if hasRetainedPrimaryDevelopWrites {
            primaryDevelopLifecycle.register(ownerID: primaryDevelopOwnerID,
                waitForAccepted: { await self.waitForPrimaryDevelopWrites() },
                requirePersisted: { try self.requirePrimaryDevelopWritesPersisted() })
        } else {
            primaryDevelopLifecycle.unregister(ownerID: primaryDevelopOwnerID)
            primaryDevelopResults.removeAll()
        }
    }

    /// The JPEG (any non-RAW) half of a RAW+JPEG pair shares the stem `.xmp` whose Camera Raw
    /// block belongs to the RAW, so its Develop settings live in its own embedded XMP (Adobe
    /// convention; an atomic metadata-only rewrite, no pixel recompression). A sidecar-bound
    /// request becomes embedded + sidecar: the embedded half carries only Camera Raw settings
    /// (`embedsDevelopOnly`), the sidecar half keeps receiving the descriptive record as before
    /// and never touches the RAW's crs block.
    nonisolated static func primaryDevelopMode(_ mode: MetadataWriteMode, pairedWithRAW: Bool) -> MetadataWriteMode {
        guard pairedWithRAW else { return mode }
        switch mode {
        case .writeToXMPSidecar: return .writeToFileAndXMPSidecar
        case .writeToFile, .writeToFileAndXMPSidecar, .historyOnly: return mode
        }
    }

    /// Restores only the Develop part of the editing buffer to its last persisted state, keeping
    /// any descriptive edits; `hasChanges` follows the buffer instead of being forced off.
    func revertPrimaryDevelopToPersisted() {
        guard let previous = previousEditingMetadata else { return }
        editingMetadata.cameraRaw = previous.cameraRaw
        editingMetadata.exifOrientation = previous.exifOrientation
        hasChanges = selectedHavePendingSidecars || editingMetadata != previous
    }

    /// Why the selected photo's Primary Develop edit has no destination, or nil. A paired JPEG
    /// carrying Content Credentials can't be embedded into without breaking them, and its
    /// stem sidecar's develop block belongs to the RAW.
    func primaryDevelopRefusal(for image: URL) -> String? {
        // Simple deliberately ignores Content Credentials for every embedded write.
        guard selectedHasC2PA, MetadataWritePreset.current != .simple, let raw = PhotoSidecarOwnership.developOwningRawSibling(of: image) else { return nil }
        return "\(image.lastPathComponent) has Content Credentials and shares its XMP sidecar with \(raw.lastPathComponent). "
            + "Develop edits can't be saved into the JPEG without breaking its credentials, and the shared sidecar's "
            + "develop settings belong to the RAW. Edit \(raw.lastPathComponent) instead."
    }

    /// The last persisted Primary Develop settings of the selected photo (what a refused edit
    /// reverts to).
    var persistedPrimaryDevelopSettings: CameraRawSettings? { previousEditingMetadata?.cameraRaw }

    /// Develop uses its own retained queue: generic metadata writes cannot cancel its only copy.
    func commitPrimaryDevelopEdits(mode requestedMode: MetadataWriteMode, onComplete: @escaping (MetadataCommitResult) -> Void) {
        guard primaryDevelopReviewOwner == nil else {
            let message = "Finish the Primary Develop recovery review before accepting another edit."
            saveError = message; onComplete(.failed(message: message)); return
        }
        guard selectedURLs.count == 1, let image = selectedURLs.first, let folder = currentFolderURL,
              let loadID = metadataLoadRequestID, !isLoading else {
            let message = "Wait for one photo to finish loading before saving its Primary Develop edit."
            saveError = message; onComplete(.failed(message: message)); return
        }
        // Refuse before anything is retained, so a refusal never blocks later edits.
        if let refusal = primaryDevelopRefusal(for: image) {
            revertPrimaryDevelopToPersisted()
            saveError = refusal; onComplete(.failed(message: refusal)); return
        }
        let pairedWithRAW = !SupportedImageFormats.isRaw(url: image)
            && PhotoSidecarOwnership.stemSidecarDevelopBelongsToRawSibling(of: image, requiringFreshListing: true)
        let mode = Self.primaryDevelopMode(requestedMode, pairedWithRAW: pairedWithRAW)
        let edited = editingMetadata
        if let existing = retainedPrimaryDevelopWrites.last(where: {
            $0.imageURL == image && $0.folderURL == folder && $0.loadID == loadID
        }), existing.edited == edited, existing.mode == mode {
            let message = primaryDevelopResults[existing.id].map {
                PrimaryDevelopFailureText.userMessage(failure: $0.failure, fileName: image.lastPathComponent,
                    requiresRecovery: $0.requiresRecovery)
            } ?? "Your edits to \(image.lastPathComponent) are still being saved."
            onComplete(.failed(message: message)); return
        }
        let predecessor = retainedPrimaryDevelopWrites.last {
            $0.imageURL == image && $0.folderURL == folder && $0.loadID == loadID
        }
        let token: XMPSidecarWriteSnapshot?
        let captureFailure: String?
        do { token = try editorXMPWriteEvidence(for: image, in: folder).get(); captureFailure = nil }
        catch { token = nil; captureFailure = error.localizedDescription }
        let source = primaryDevelopSourceBaseline.flatMap { $0.imageURL == image && $0.loadID == loadID ? $0.revision : nil }
        let watermarkIDs = PrimaryDevelopWriteRequestBuilder.watermarkDependencyIDs(
            edited: edited, previous: predecessor?.edited ?? previousEditingMetadata, original: originalImageMetadata)
        let watermarkDependencies = watermarkIDs.sorted { $0.uuidString < $1.uuidString }.map { id in
            let imageURL = WatermarkStore.resolvedImageURL(forAssetID: id)
            let asset = WatermarkStore.shared.asset(byID: id)
            let data = WatermarkStore.shared.imageData(forAssetID: id)
            return PrimaryDevelopWatermarkDependency(id: id, asset: asset,
                imageData: data, imageURL: imageURL,
                metadataURL: imageURL.deletingLastPathComponent().appendingPathComponent("meta.json"),
                unavailableAtAdmission: asset == nil || data == nil)
        }
        let request = PrimaryDevelopWriteRequestBuilder.build(.init(
            imageURL: image, folderURL: folder, loadID: loadID, mode: mode,
            edited: edited, previous: previousEditingMetadata, original: originalImageMetadata,
            xmpBaseline: xmpMetadata, embeddedBaseline: embeddedMetadata,
            expectedRecord: currentWriteExpectedRecord, expectedXMP: token,
            sourceRevision: source, captureFailure: captureFailure, history: sidecarHistory,
            timestamp: Date(), predecessor: predecessor, watermarkDependencies: watermarkDependencies,
            embedsDevelopOnly: pairedWithRAW, allowsCredentialedEmbed: MetadataWritePreset.current == .simple))
        retainedPrimaryDevelopWrites.append(request)
        schedulePrimaryDevelop(request, onComplete: onComplete)
    }

    private func schedulePrimaryDevelop(_ request: PrimaryDevelopWriteRequest, onComplete: @escaping (MetadataCommitResult) -> Void) {
        let preceding = primaryDevelopTask
        primaryDevelopActiveCount += 1
        synchronizePrimaryDevelopRetention()
        primaryDevelopTask = Task { @MainActor in
            await preceding?.value
            let result: PrimaryDevelopWriteResult
            if let older = retainedPrimaryDevelopWrites.first(where: {
                Self.variablePhotoKey($0.imageURL) == Self.variablePhotoKey(request.imageURL)
            }), older.id != request.id {
                result = .init(requestID: request.id, failure: PrimaryDevelopFailureText.earlierEditUnresolved)
            } else if primaryDevelopResults[request.id]?.requiresRecovery == true {
                result = primaryDevelopResults[request.id]!
            } else if let primaryDevelopExecutor {
                result = await primaryDevelopExecutor(request)
            } else {
                result = await PrimaryDevelopWriteService(engine: writeEngine).execute(request,
                    predecessorResult: request.predecessor.flatMap { primaryDevelopResults[$0.id] })
            }
            primaryDevelopResults[request.id] = result
            primaryDevelopActiveCount -= 1
            let matches = metadataLoadRequestID == request.loadID && selectedURLs == [request.imageURL]
                && currentFolderURL == request.folderURL && editingMetadata == request.edited
            if result.completed, let completion = result.completion, let installed = completion.installedSidecar {
                retainedPrimaryDevelopWrites.removeAll { $0.id == request.id }
                let sameEditorSession = metadataLoadRequestID == request.loadID && selectedURLs == [request.imageURL]
                    && currentFolderURL == request.folderURL
                if sameEditorSession {
                    // Advance only to this own verified receipt, retaining any newer live edit.
                    cleanupBaseline = (request.imageURL, request.folderURL, installed)
                    sidecarHistory = installed.history
                    previousEditingMetadata = request.edited
                    if result.wroteEmbedded { adoptEmbeddedPrimaryDevelop(request) }
                    capturedCaptionWriteExpectation = nil
                    if completion.wroteXMPSidecar { xmpMetadata = completion.writtenXMPMetadata ?? request.edited }
                    editorXMPWriteBaseline = (request.imageURL, request.folderURL, request.loadID,
                        completion.writtenXMPSnapshot ?? request.expectedXMP, nil)
                    if let source = result.sourceRevision { primaryDevelopSourceBaseline = (request.imageURL, request.loadID, source) }
                }
                if matches {
                    cleanupBaseline = (request.imageURL, request.folderURL, installed)
                    sidecarHistory = installed.history
                    if completion.wroteXMPSidecar { xmpMetadata = completion.writtenXMPMetadata ?? request.edited }
                    editorXMPWriteBaseline = (request.imageURL, request.folderURL, request.loadID,
                        completion.writtenXMPSnapshot ?? request.expectedXMP, nil)
                    if let source = result.sourceRevision { primaryDevelopSourceBaseline = (request.imageURL, request.loadID, source) }
                    editingMetadata.cameraRaw = completion.writtenXMPMetadata?.cameraRaw ?? request.edited.cameraRaw
                    previousEditingMetadata = editingMetadata
                    if result.wroteEmbedded { adoptEmbeddedPrimaryDevelop(request) }
                    else if metadataReferenceSource == .xmp { metadata = xmpMetadata; originalImageMetadata = xmpMetadata }
                    hasChanges = false; selectedHavePendingSidecars = false; saveError = nil
                }
                synchronizePrimaryDevelopRetention(); onComplete(.succeeded)
            } else if result.refusedForContentCredentials || result.refusedBeforeWrite {
                // Nothing was written (Content Credentials, or develop metadata too large for the
                // file): drop this photo's queued edits instead of retaining work that can never
                // be saved, and revert only the Develop part of the editor.
                let message = result.failure ?? "This photo's Develop edit could not be saved safely and was not written."
                retainedPrimaryDevelopWrites.removeAll {
                    $0.imageURL == request.imageURL && $0.folderURL == request.folderURL && $0.loadID == request.loadID
                }
                if metadataLoadRequestID == request.loadID, selectedURLs == [request.imageURL] {
                    if result.refusedForContentCredentials {
                        selectedHasC2PA = true
                        selectedC2PAURLs.insert(request.imageURL)
                    }
                    revertPrimaryDevelopToPersisted()
                    saveError = message
                }
                synchronizePrimaryDevelopRetention()
                onComplete(.failed(message: message))
            } else {
                let message = PrimaryDevelopFailureText.userMessage(failure: result.failure,
                    fileName: request.imageURL.lastPathComponent, requiresRecovery: result.requiresRecovery)
                if matches { saveError = message }
                synchronizePrimaryDevelopRetention()
                onComplete(result.wasCancelled ? .cancelled(message: message) : .failed(message: message))
            }
        }
    }
    /// A develop-only embed (RAW+JPEG pair's JPEG) changed only the file's Camera Raw block;
    /// its descriptive record is untouched, so only the develop part of the baselines moves.
    private func adoptEmbeddedPrimaryDevelop(_ request: PrimaryDevelopWriteRequest) {
        guard request.embedsDevelopOnly else {
            embeddedMetadata = request.edited; originalImageMetadata = request.edited; metadata = request.edited
            return
        }
        embeddedMetadata?.cameraRaw = request.edited.cameraRaw
        originalImageMetadata?.cameraRaw = request.edited.cameraRaw
        metadata?.cameraRaw = request.edited.cameraRaw
    }

    private func primaryDevelopFailureMessage(_ result: PrimaryDevelopWriteResult) -> String {
        let prefix = result.requiresRecovery
            ? "The Develop edit may be only partly saved. The full edit is still kept in Photo Agent; export it and check the result before discarding it."
            : "The Develop edit wasn't saved, but it is still kept in Photo Agent. Retrying saves the same edit to the same photo."
        return prefix + " " + (result.failure ?? "The save did not complete.")
    }
    func retryPrimaryDevelopWrites() async throws {
        guard primaryDevelopReviewOwner == nil else { throw PrimaryDevelopWriteError(message: "Finish the recovery review before retrying.") }
        await waitForPrimaryDevelopWrites()
        guard primaryDevelopReviewOwner == nil else { throw PrimaryDevelopWriteError(message: "Finish the recovery review before retrying.") }
        for request in retainedPrimaryDevelopWrites {
            if primaryDevelopResults[request.id]?.requiresRecovery == true { continue }
            schedulePrimaryDevelop(request, onComplete: { _ in })
        }
        await waitForPrimaryDevelopWrites()
        try requirePrimaryDevelopWritesPersisted()
    }

    func beginPrimaryDevelopRecovery(for image: URL) async throws -> VariableConflictSnapshot {
        guard primaryDevelopReviewOwner == nil else { throw PrimaryDevelopWriteError(message: "A Primary Develop recovery review is already open.") }
        try primaryDevelopEditorBarrier?.handler()
        let owner = UUID(); primaryDevelopReviewOwner = owner; primaryDevelopRecoveryPhotoURL = image
        synchronizePrimaryDevelopRetention()
        await waitForPrimaryDevelopWrites()
        do {
            try Task.checkCancellation()
            let snapshot = try await VariableConflictRecovery.makeSnapshot(photoURL: image,
                reason: retainedPrimaryDevelopWrites.first(where: { Self.variablePhotoKey($0.imageURL) == Self.variablePhotoKey(image) })
                    .flatMap { primaryDevelopResults[$0.id] }.map(primaryDevelopFailureMessage) ?? "An unsaved Develop edit is still kept in Photo Agent.",
                generation: primaryDevelopGeneration, entries: primaryDevelopEntries(for: image))
            guard primaryDevelopReviewOwner == owner else { throw PrimaryDevelopWriteError(message: "The recovery review changed.") }
            primaryDevelopReview = snapshot
            return snapshot
        } catch { releasePrimaryDevelopReview(); throw error }
    }
    func endPrimaryDevelopRecovery(_ snapshot: VariableConflictSnapshot) async {
        guard primaryDevelopReview?.id == snapshot.id else { return }
        if primaryDevelopRecoveryOperation { primaryDevelopRecoveryEndRequested = true }
        else { releasePrimaryDevelopReview() }
    }
    private func validatePrimaryDevelopReview(_ snapshot: VariableConflictSnapshot) throws {
        guard primaryDevelopReview?.id == snapshot.id, primaryDevelopGeneration == snapshot.generation else {
            throw PrimaryDevelopWriteError(message: "The unsaved Develop edits changed since you reviewed them. Review and export them again.")
        }
    }
    private var primaryDevelopProtectedPhotos: [URL] {
        PrimaryDevelopWriteRequest.protectedURLs(for: retainedPrimaryDevelopWrites)
            + variableRecoveryProtectedPhotos + selectedURLs
    }
    func exportPrimaryDevelopRecovery(_ snapshot: VariableConflictSnapshot, to url: URL) async throws -> VariableConflictExportReceipt {
        try validatePrimaryDevelopReview(snapshot)
        guard !primaryDevelopRecoveryOperation else { throw PrimaryDevelopWriteError(message: "Recovery is still running.") }
        primaryDevelopRecoveryOperation = true
        defer { primaryDevelopRecoveryOperation = false; if primaryDevelopRecoveryEndRequested { releasePrimaryDevelopReview() } }
        let receipt = try await VariableConflictRecovery.export(snapshot, to: url,
            currentEntries: primaryDevelopEntries(for: snapshot.photoURL), generation: primaryDevelopGeneration,
            protectedPhotoURLs: primaryDevelopProtectedPhotos)
        try validatePrimaryDevelopReview(snapshot)
        return receipt
    }
    func discardPrimaryDevelopRecovery(_ snapshot: VariableConflictSnapshot, receipt: VariableConflictExportReceipt) async throws {
        try validatePrimaryDevelopReview(snapshot)
        guard !primaryDevelopRecoveryOperation else { throw PrimaryDevelopWriteError(message: "Recovery is still running.") }
        primaryDevelopRecoveryOperation = true
        defer { primaryDevelopRecoveryOperation = false; if primaryDevelopRecoveryEndRequested { releasePrimaryDevelopReview() } }
        let ids = try await VariableConflictRecovery.verifyDiscard(snapshot, receipt: receipt,
            currentEntries: primaryDevelopEntries(for: snapshot.photoURL), generation: primaryDevelopGeneration,
            protectedPhotoURLs: primaryDevelopProtectedPhotos)
        try Task.checkCancellation(); try validatePrimaryDevelopReview(snapshot)
        try primaryDevelopEditorBarrier?.handler()
        let last = retainedPrimaryDevelopWrites.last { ids.contains($0.id) }
        let ownsUnchangedEditor = last.map {
            $0.loadID == metadataLoadRequestID && selectedURLs == [$0.imageURL] && currentFolderURL == $0.folderURL && editingMetadata == $0.edited
        } == true
        guard !ownsUnchangedEditor || (primaryDevelopEditorBarrier != nil && !isSaving) else {
            throw PrimaryDevelopWriteError(message: "Open this photo in Develop and finish the adjustment you're making before discarding the unsaved edits.")
        }
        let mayReload = ownsUnchangedEditor
        if mayReload, let last {
            let beforeGeneration = metadataLoadGeneration
            let expectedEditor = editingMetadata
            primaryDevelopRecoveryReloadGeneration += 1
            loadMetadata(for: [ImageFile(url: last.imageURL)], folderURL: last.folderURL)
            let reloadID = metadataLoadRequestID
            primaryDevelopRecoveryLoadGuard = (reloadID, expectedEditor)
            await metadataLoadTask?.value
            if primaryDevelopRecoveryLoadGuard?.loadID == reloadID { primaryDevelopRecoveryLoadGuard = nil }
            try validatePrimaryDevelopReview(snapshot)
            guard metadataLoadRequestID == reloadID, selectedURLs == [last.imageURL],
                  metadataLoadGeneration > beforeGeneration, !isLoading else {
                throw PrimaryDevelopWriteError(message: "The export is saved, but the editor couldn't reload the photo. Your unsaved edits are kept. Wait for the photo to reload before discarding them.")
            }
        }
        retainedPrimaryDevelopWrites.removeAll { ids.contains($0.id) }
        // Keep receipts referenced by surviving causal successors; they remain part of export.
        releasePrimaryDevelopReview()
    }
    private func releasePrimaryDevelopReview() {
        primaryDevelopReview = nil; primaryDevelopReviewOwner = nil; primaryDevelopRecoveryPhotoURL = nil
        primaryDevelopRecoveryEndRequested = false; synchronizePrimaryDevelopRetention()
    }
    private func primaryDevelopEntries(for image: URL) throws -> [VariableConflictEntry] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try retainedPrimaryDevelopWrites.filter { Self.variablePhotoKey($0.imageURL) == Self.variablePhotoKey(image) }.map {
            request in
            let payloads = PrimaryDevelopWriteRequest.ancestry(of: [request]).map {
                PrimaryDevelopRecoveryPayload($0, result: primaryDevelopResults[$0.id])
            }
            let graph: [String: Any] = ["kind": "Primary Develop", "requestAndPredecessors":
                try JSONSerialization.jsonObject(with: encoder.encode(payloads))]
            return .init(id: request.id, imageURL: request.imageURL, folderURL: request.folderURL,
                admissionPayload: try JSONSerialization.data(withJSONObject: graph, options: [.sortedKeys]),
                failure: primaryDevelopResults[request.id].map(primaryDevelopFailureMessage))
        }
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
    /// Every mode completes only after its metadata/history work finishes (History Only once
    /// its pending draft is durable), so boundaries never race a save they believe is done.
    func commitEditsReportingResult(
        mode: MetadataWriteMode,
        onComplete: @escaping (MetadataCommitResult) -> Void
    ) {
        do { try requirePrimaryDevelopWritesPersisted() }
        catch { saveError = error.localizedDescription; onComplete(.failed(message: error.localizedDescription)); return }
        do { try requireVariableDiscardedEditorReconciled() }
        catch { saveError = error.localizedDescription; onComplete(.failed(message: error.localizedDescription)); return }
        switch mode {
        case .historyOnly:
            // Report when the draft is durable, so a boundary waits for it instead of racing it.
            saveToSidecar { failure in
                onComplete(failure.map { .failed(message: $0) } ?? .succeeded)
            }
        case .writeToXMPSidecar:
            writeXMPSidecarAndPreserveHistory(onComplete: onComplete)
        case .writeToFile, .writeToFileAndXMPSidecar:
            writeMetadataAndPreserveHistory(alsoWriteXMPSidecar: mode.writesXMPSidecar, onComplete: onComplete)
        }
    }

    /// Saves the photos the editor holds before it moves on, using the editor's own write mode
    /// and load folder — never the browser's current arrays, which a folder or pane switch has
    /// already replaced. A failed write keeps a single photo's edit as a pending JSON draft so
    /// navigating away never silently drops it; the outcome names the photo and the reason.
    func commitDepartingEditor(
        knownC2PAURLs: Set<URL> = [],
        onComplete: @escaping (EditorBoundaryCommitOutcome) -> Void
    ) {
        guard hasUnpersistedEditorChanges else { onComplete(.nothingToCommit); return }
        let names = selectedURLs.map(\.lastPathComponent).joined(separator: ", ")
        let mode = editorWriteMode(knownC2PAURLs: knownC2PAURLs)
        withEditorFolder {
            let fallback = boundaryDraftFallback()
            let edited = editingMetadata
            let loadID = metadataLoadRequestID
            let folder = currentFolderURL
            commitEditsReportingResult(mode: mode) { [weak self] result in
                switch result {
                case .succeeded:
                    onComplete(.saved)
                case .cancelled:
                    // Superseded by a newer save of this photo, which carries these edits.
                    onComplete(.superseded)
                case .failed(let message):
                    guard let fallback else {
                        onComplete(.failed(message: EditorBoundaryCommitOutcome.failureMessage(
                            files: names, reason: message)))
                        return
                    }
                    guard let self else {
                        onComplete(.failed(message: EditorBoundaryCommitOutcome.failureMessage(
                            files: names, reason: message)))
                        return
                    }
                    self.enqueueBoundaryDraftFallback(fallback) { failure in
                        if let failure {
                            onComplete(.failed(message: EditorBoundaryCommitOutcome.failureMessage(
                                files: names, reason: "\(message) A pending draft could not be kept either: \(failure)")))
                            return
                        }
                        self.adoptBoundaryDraft(fallback, edited: edited, loadID: loadID, folderURL: folder)
                        onComplete(.keptAsDraft(message: "Metadata for \(names) could not be written and was kept as a pending draft. Use Write to retry. \(message)"))
                    }
                }
            }
        }
    }

    /// Persists a boundary's fallback draft as part of the write chain, so `waitForPendingWrites`
    /// (quit, rename, Paste IPTC, the next boundary) returns only once it is durable, and a later
    /// save of the photo queues behind it instead of racing it.
    private func enqueueBoundaryDraftFallback(
        _ fallback: CaptionDraftPersistence,
        onComplete: @escaping @MainActor (String?) -> Void
    ) {
        let priorWrite = writeTask
        let generation = writeTaskGeneration + 1
        isSaving = true
        let write = Task { @MainActor in
            defer { if writeTaskGeneration == generation { isSaving = false } }
            await priorWrite?.value
            do {
                try await fallback.persistAsync()
                onComplete(nil)
            } catch {
                onComplete(error.localizedDescription)
            }
        }
        writeTask = Task { await write.value }
    }

    /// Runs `body` with `currentFolderURL` set to the folder the editor's photos were loaded
    /// from. Saves capture the folder synchronously, so restoring it afterwards is safe.
    private func withEditorFolder<T>(_ body: () -> T) -> T {
        guard let editorFolderURL, currentFolderURL != editorFolderURL else { return body() }
        let published = currentFolderURL
        currentFolderURL = editorFolderURL
        defer { if currentFolderURL == editorFolderURL { currentFolderURL = published } }
        return body()
    }

    /// The pending draft a failed boundary save falls back to: the editor's field changes,
    /// replayed onto the photo's latest JSON record. Captured before the write is attempted,
    /// because the editor may hold another photo by the time the write reports its failure.
    private func boundaryDraftFallback() -> CaptionDraftPersistence? {
        guard selectedCount == 1, let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else { return nil }
        let now = Date()
        let previous = previousEditingMetadata ?? IPTCMetadata()
        let changes = MetadataHistoryEntry.changes(from: previous, to: editingMetadata, timestamp: now)
        guard !changes.isEmpty else { return nil }
        var history = sidecarHistory + changes
        history.trimToHistoryLimit()
        let sidecar = MetadataSidecar(sourceFile: imageURL.lastPathComponent, lastModified: now,
            pendingChanges: true, metadata: editingMetadata,
            imageMetadataSnapshot: pendingDraftImageMetadataSnapshot, history: history)
        return CaptionDraftPersistence(request: MetadataSidecarReplayRequest(
            sidecar: sidecar, baselineMetadata: previous, baselineHistory: sidecarHistory,
            baselineRecordExisted: currentWriteExpectedRecord != nil,
            changes: changes, imageURL: imageURL, folderURL: folderURL))
    }

    /// When the editor still shows the photo whose save fell back to a draft, reload it: the
    /// photo now holds a pending draft (Write enabled), and the reload refreshes the JSON and XMP
    /// baselines the next save is checked against — keeping the old ones would make that save
    /// fail as an ownership or stale-sidecar conflict.
    private func adoptBoundaryDraft(_ draft: CaptionDraftPersistence, edited: IPTCMetadata,
                                    loadID: UUID?, folderURL: URL?) {
        guard selectedURLs == [draft.imageURL], metadataLoadRequestID == loadID,
              editingMetadata == edited else { return }
        var image = ImageFile(url: draft.imageURL)
        image.hasC2PA = selectedC2PAURLs.contains(draft.imageURL)
        loadMetadata(for: [image], folderURL: folderURL ?? draft.folderURL)
    }

    /// "Discard Edits and Continue" at a boundary whose save failed: drop the editor's unsaved
    /// changes (pending drafts on disk are untouched) so the transition can go ahead.
    func discardUnsavedEditorChanges() {
        if let previous = previousEditingMetadata { editingMetadata = previous }
        if isBatchEdit {
            batchFieldMutations = [:]
            batchLocationsShownMutation = .untouched
            batchImageSupplierMutation = .untouched
            hasChanges = false
        } else {
            hasChanges = selectedHavePendingSidecars
        }
        saveError = nil
    }

    func writeMetadata() {
        do { try requirePrimaryDevelopWritesPersisted() }
        catch { saveError = error.localizedDescription; return }
        do { try requireVariableDiscardedEditorReconciled() }
        catch { saveError = error.localizedDescription; return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        pruneStaleBatchTextIntents()
        let selectionSnapshot = Set(urls)
        let writeFolderURL = currentFolderURL
        let edited = editingMetadata
        let original = metadata
        let isBatch = isBatchEdit
        let prevEditing = previousEditingMetadata
        let explicitBatchMutations = batchFieldMutations
        let explicitLocationsShownMutation = batchLocationsShownMutation
        let resolvedBatchSnapshot = batchMetadataByURL
        let draftMutation = isBatch
            ? (mutation: capturedBatchMutation(), overridesSuppliers: batchImageSupplierMutation != .untouched)
            : nil
        let generation = writeTaskGeneration + 1
        isSaving = true
        saveError = nil

        // Serialize behind any running write instead of cancelling it, and keep the write itself
        // out of reach of a later `writeTask?.cancel()`: a cancelled batch write stops partway
        // through the selection and leaves photos half-updated.
        let priorWrite = writeTask
        let batchTracking = isBatch ? beginBatchWriteTracking(urls) : nil
        let write = Task {
            defer { if let batchTracking { self.endBatchWriteTracking(batchTracking) } }
            await priorWrite?.value
            do {
                if let writeFolderURL {
                    for url in urls {
                        try await sidecarService.requireNoPendingOrientation(for: url, in: writeFolderURL)
                    }
                }
                // Never embed into a RAW container: RAW photos in the selection get their complete
                // per-photo record in the XMP sidecar below, the rest are written in place.
                let embedURLs = urls.filter { !SupportedImageFormats.isRaw(url: $0) }
                let rawURLs = urls.filter { SupportedImageFormats.isRaw(url: $0) }
                var fields: [MetadataFieldKey: String] = [:]
                // Files refused because their metadata wouldn't fit a JPEG segment are left
                // untouched; every later phase continues with the files that were written.
                var lossRefusals: [EmbeddedMetadataLossRefusal] = []
                func writableEmbedURLs() -> [URL] {
                    let refused = Set(lossRefusals.map(\.imageURL))
                    return embedURLs.filter { !refused.contains($0) }
                }

                if isBatch {
                    // Batch: write non-empty fields; emptying a value common to the selection clears it
                    if let v = Self.batchScalarWriteValue(edited.title, previous: prevEditing?.title) { fields[.headline] = v }
                    if let v = Self.batchScalarWriteValue(edited.description, previous: prevEditing?.description) { fields[.description] = v }
                    if let v = Self.batchScalarWriteValue(edited.extendedDescription, previous: prevEditing?.extendedDescription) { fields[.extendedDescription] = v }

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

                    if let v = Self.batchScalarWriteValue(edited.digitalSourceType?.newsCodeURI,
                        previous: prevEditing?.digitalSourceType?.newsCodeURI) { fields[.digitalSourceType] = v }
                    if let v = Self.batchScalarWriteValue(edited.urgency.map(String.init),
                        previous: prevEditing?.urgency.map(String.init)) { fields[.urgency] = v }
                    if let lat = edited.latitude, let lon = edited.longitude {
                        fields[.gpsLatitude] = String(abs(lat))
                        fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
                        fields[.gpsLongitude] = String(abs(lon))
                        fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
                    } else if Self.batchClearsGPS(edited: edited, previous: prevEditing) {
                        fields[.gpsLatitude] = ""
                        fields[.gpsLatitudeRef] = ""
                        fields[.gpsLongitude] = ""
                        fields[.gpsLongitudeRef] = ""
                    }
                    if let v = edited.creatorTransportValue { fields[.creator] = v }
                    if let v = Self.batchScalarWriteValue(edited.creatorJobTitle, previous: prevEditing?.creatorJobTitle) { fields[.creatorJobTitle] = v }
                    if let v = Self.batchScalarWriteValue(edited.descriptionWriter, previous: prevEditing?.descriptionWriter) { fields[.descriptionWriter] = v }
                    if let v = Self.batchScalarWriteValue(edited.credit, previous: prevEditing?.credit) { fields[.credit] = v }
                    if let v = Self.batchScalarWriteValue(edited.copyright, previous: prevEditing?.copyright) { fields[.rights] = v }
                    if let v = Self.batchScalarWriteValue(edited.rightsUsageTerms, previous: prevEditing?.rightsUsageTerms) { fields[.rightsUsageTerms] = v }
                    if let v = Self.batchScalarWriteValue(edited.webStatementOfRights, previous: prevEditing?.webStatementOfRights) { fields[.webStatementOfRights] = v }
                    if let v = Self.batchScalarWriteValue(edited.digitalImageGUID, previous: prevEditing?.digitalImageGUID) { fields[.digitalImageGUID] = v }
                    if let v = Self.batchScalarWriteValue(edited.imageSupplierImageID, previous: prevEditing?.imageSupplierImageID) { fields[.imageSupplierImageID] = v }
                    if let v = Self.batchScalarWriteValue(edited.jobId, previous: prevEditing?.jobId) { fields[.transmissionReference] = v }
                    if let v = Self.batchScalarWriteValue(edited.dateCreated, previous: prevEditing?.dateCreated) { fields[.dateCreated] = v }
                    if let v = Self.batchScalarWriteValue(edited.city, previous: prevEditing?.city) { fields[.city] = v }
                    if let v = Self.batchScalarWriteValue(edited.sublocation, previous: prevEditing?.sublocation) { fields[.sublocation] = v }
                    if let v = Self.batchScalarWriteValue(edited.provinceState, previous: prevEditing?.provinceState) { fields[.provinceState] = v }
                    if let v = Self.batchScalarWriteValue(edited.country, previous: prevEditing?.country) { fields[.country] = v }
                    if let v = Self.batchScalarWriteValue(edited.countryCode, previous: prevEditing?.countryCode) { fields[.countryCode] = v }
                    if let v = Self.batchScalarWriteValue(edited.event, previous: prevEditing?.event) { fields[.event] = v }
                    if let v = Self.batchScalarWriteValue(edited.instructions, previous: prevEditing?.instructions) { fields[.instructions] = v }
                    if let v = Self.batchScalarWriteValue(edited.source, previous: prevEditing?.source) { fields[.source] = v }
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
                if !embedURLs.isEmpty, !fields.isEmpty || structuredEditorialChanged {
                    let structuredData = StructuredWriteData(
                        editorial: structuredEditorialChanged
                            ? EditorialStructuredWriteData(metadata: edited)
                            : nil,
                        listValues: EditorialListWriteData(metadata: edited)
                    )
                    do {
                        try await writeEngine.writeFields(fields, to: embedURLs, structuredData: structuredData)
                    } catch let batch as EmbeddedMetadataBatchRefusal {
                        lossRefusals += batch.refusals
                    }
                }

                // Handle additive list fields via += / -=
                if isBatch, let prev = prevEditing {
                    let diffs = additiveListDiffs(
                        from: edited,
                        previous: prev,
                        explicitMutations: explicitBatchMutations
                    )
                    let listTargets = writableEmbedURLs()
                    if !listTargets.isEmpty, !diffs.add.isEmpty || !diffs.remove.isEmpty {
                        do {
                            try await writeEngine.addRemoveListValues(
                                add: diffs.add,
                                remove: diffs.remove,
                                to: listTargets
                            )
                        } catch let batch as EmbeddedMetadataBatchRefusal {
                            lossRefusals += batch.refusals
                        }
                    }
                }

                if let batchMutation = draftMutation?.mutation,
                   explicitBatchMutations.values.contains(where: \.appliesPerRecord) {
                    // Template appends and fills are per photo: each file gets its own value plus
                    // the appended text (or the fill where empty), never the common-value preview.
                    for url in writableEmbedURLs() {
                        let base: IPTCMetadata
                        if let resolved = resolvedBatchSnapshot[url] {
                            base = resolved
                        } else {
                            base = try await self.readService.readFullMetadata(url: url)
                        }
                        let photoWrite = batchMutation.embeddedPerRecordWrite(for: url, base: base)
                        guard !photoWrite.fields.isEmpty else { continue }
                        do {
                            try await writeEngine.writeFields(
                                photoWrite.fields, to: [url],
                                structuredData: StructuredWriteData(listValues: photoWrite.listValues)
                            )
                            batchMutation.markDelivered(to: url, channel: .embedded)
                        } catch let batch as EmbeddedMetadataBatchRefusal {
                            lossRefusals += batch.refusals
                        }
                    }
                }

                if isBatch, explicitLocationsShownMutation != .untouched {
                    for url in writableEmbedURLs() {
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
                        do {
                            try await writeEngine.writeFields(
                                [:],
                                to: [url],
                                structuredData: StructuredWriteData(
                                    editorial: EditorialStructuredWriteData(metadata: updated)
                                )
                            )
                        } catch let batch as EmbeddedMetadataBatchRefusal {
                            lossRefusals += batch.refusals
                        }
                    }
                }

                let controlledStructuredMutations = explicitBatchMutations.filter {
                    $0.key == .mediaTopic || $0.key == .genre
                }
                if isBatch, !controlledStructuredMutations.isEmpty {
                    for url in writableEmbedURLs() {
                        let base: IPTCMetadata
                        if let resolved = resolvedBatchSnapshot[url] {
                            base = resolved
                        } else {
                            base = try await self.readService.readFullMetadata(url: url)
                        }
                        let updated = try MetadataFieldMutationSet(controlledStructuredMutations)
                            .applying(to: base)
                        do {
                            try await writeEngine.writeFields(
                                [:],
                                to: [url],
                                structuredData: StructuredWriteData(
                                    editorial: EditorialStructuredWriteData(metadata: updated)
                                )
                            )
                        } catch let batch as EmbeddedMetadataBatchRefusal {
                            lossRefusals += batch.refusals
                        }
                    }
                }

                var installedRawRecords: [URL: IPTCMetadata] = [:]
                for url in rawURLs {
                    if let draftMutation {
                        // Apply the batch change to the sidecar's current record inside its
                        // transaction. Replacing it from the load-time snapshot would revert
                        // ratings, labels or face names written to the sidecar since then.
                        var fallback: IPTCMetadata
                        if let resolved = resolvedBatchSnapshot[url] {
                            fallback = resolved
                        } else {
                            fallback = try await self.readService.readFullMetadata(url: url)
                        }
                        // A descriptive batch edit leaves develop settings exactly as stored, and a
                        // new sidecar must not freeze a copy of the file's embedded Camera Raw.
                        fallback.cameraRaw = nil
                        installedRawRecords[url] = try await self.xmpSidecarService.updateSidecarSerialized(
                            for: url, fallback: fallback, preservesDevelopSettings: true,
                            mutation: draftMutation.mutation.closure(for: url, channel: .xmpSidecar))
                        draftMutation.mutation.markDelivered(to: url, channel: .xmpSidecar)
                    } else {
                        _ = try await self.descriptiveWriteBoundary.write(
                            metadata: edited, for: url, requestedMode: .writeToFile, semantics: .replace)
                    }
                }

                let refusedURLs = Set(lossRefusals.map(\.imageURL))
                // Refused files whose change actually landed in a pending draft.
                var draftedRefusedURLs: Set<URL> = []
                let mirroredURLs = await self.mirrorEmbeddedStateToExistingSidecars(for: writableEmbedURLs())
                if let draftMutation {
                    // The mirror copied each file's complete post-write record, appended text
                    // included, into its existing .xmp: a dual-write XMP phase must not append again.
                    for url in mirroredURLs { draftMutation.mutation.markDelivered(to: url, channel: .xmpSidecar) }
                }

                // A pending draft is the photo's record until it is written. Apply the same batch
                // change to it (keeping it pending) so a later Write All cannot revert this write.
                if let draftMutation, let writeFolderURL {
                    let pendingNames = Set(await self.sidecarService.imagesWithPendingChanges(in: writeFolderURL)
                        .map(\.lastPathComponent))
                    let draftURLs = urls.filter { pendingNames.contains($0.lastPathComponent) }
                    if !draftURLs.isEmpty {
                        let failure = await self.saveBatchSidecars(folderURL: writeFolderURL, pendingChanges: true,
                            updateState: false,
                            capture: self.captureBatchSidecars(targetURLs: draftURLs, capturedMutation: draftMutation))
                        if failure == nil { draftedRefusedURLs.formUnion(refusedURLs.intersection(draftURLs)) }
                    }
                    // A refused file keeps this change as a pending draft (not written, not lost),
                    // so it can be written later or moved to a sidecar destination.
                    for url in embedURLs where refusedURLs.contains(url) && !pendingNames.contains(url.lastPathComponent) {
                        var fallback: IPTCMetadata
                        if let resolved = resolvedBatchSnapshot[url] {
                            fallback = resolved
                        } else {
                            fallback = (try? await self.readService.readFullMetadata(url: url)) ?? IPTCMetadata()
                        }
                        fallback.cameraRaw = nil
                        if (try? await self.sidecarService.updateMetadataSerialized(
                            for: url, in: writeFolderURL, fallback: fallback, pendingChanges: true,
                            timestamp: Date(), mutation: draftMutation.mutation.closure(for: url, channel: .jsonDraft))) != nil {
                            draftMutation.mutation.markDelivered(to: url, channel: .jsonDraft)
                            draftedRefusedURLs.insert(url)
                        }
                    }
                }

                // A refused file with no pending draft holds this change only in the editor: keep
                // it dirty and leave the baselines where they were, so it isn't mistaken for saved.
                let undraftedRefusedURLs = refusedURLs.subtracting(draftedRefusedURLs)
                if Set(self.selectedURLs) == selectionSnapshot, !undraftedRefusedURLs.isEmpty {
                    self.hasChanges = true
                    if !draftedRefusedURLs.isEmpty { self.selectedHavePendingSidecars = true }
                } else if Set(self.selectedURLs) == selectionSnapshot {
                    self.metadata = edited
                    if isBatch {
                        // The saved state is the new baseline: later add/remove diffs and
                        // explicit list operations must be computed against it, not load time.
                        // The per-photo records advance with it: a later RAW `.replace` or
                        // structured write starts from them and would otherwise revert this one.
                        if let draftMutation {
                            for (url, record) in resolvedBatchSnapshot where !refusedURLs.contains(url) {
                                var written = record
                                draftMutation.mutation.applyIgnoringDeliveries(to: &written)
                                self.batchMetadataByURL[url] = installedRawRecords[url] ?? written
                            }
                        }
                        self.previousEditingMetadata = edited
                        self.clearSavedBatchFieldMutations(explicitBatchMutations)
                        if self.batchLocationsShownMutation == explicitLocationsShownMutation {
                            self.batchLocationsShownMutation = .untouched
                        }
                        self.batchCommonMetadata = edited
                        self.reconcileBatchPartials(afterSaving: edited)
                    }
                    self.hasChanges = self.editingMetadata != edited
                    if !draftedRefusedURLs.isEmpty { self.selectedHavePendingSidecars = true }
                }
                if !lossRefusals.isEmpty {
                    let message = EmbeddedMetadataBatchRefusal(refusals: lossRefusals).localizedDescription
                    self.saveError = message
                    self.embeddedWriteFailures[generation] = message
                }
            } catch is CancellationError {
                // Superseded or torn down; not a user-facing failure.
            } catch {
                self.saveError = error.localizedDescription
                self.embeddedWriteFailures[generation] = error.localizedDescription
            }
            if self.writeTaskGeneration == generation { self.isSaving = false }
        }
        writeTask = Task { await write.value }
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
        for field in MetadataFieldID.allCases where !field.isRepeatable {
            guard let mutation = mutations[field] else { continue }
            switch mutation {
            case .untouched, .append, .appendText, .fillIfEmpty:
                // A per-photo append or fill is written file by file (see
                // `perPhotoBatchWrite`); never also write the common-value preview to every file.
                fields.removeValue(forKey: field.metadataWriteKey)
            case .clear:
                fields[field.metadataWriteKey] = ""
            case .overwrite:
                guard let updated = try? applyingBatchTextMutations([field: mutation], to: IPTCMetadata()),
                      let value = field.textValue(in: updated) else { continue }
                fields[field.metadataWriteKey] = value
            }
        }
        for field in MetadataFieldID.allCases where field.isRepeatable {
            guard let mutation = mutations[field] else { continue }
            switch mutation {
            case .untouched, .appendText, .fillIfEmpty:
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

    /// The embedded write for one photo's per-photo text appends and fills, computed from that
    /// photo's own record; no fields when the batch carries no per-photo intent. Typed list
    /// values keep list entries containing commas intact. A fill only writes a field the photo
    /// has empty; one it already has is left out of the write entirely.
    nonisolated static func perPhotoBatchWrite(
        _ mutations: [MetadataFieldID: MetadataFieldMutation],
        base: IPTCMetadata
    ) -> (fields: [MetadataFieldKey: String], listValues: EditorialListWriteData) {
        let perPhoto = mutations.filter { entry in
            switch entry.value {
            case .appendText: !entry.key.isRepeatable
            case .fillIfEmpty: entry.key.isEmpty(in: base)
            default: false
            }
        }
        guard !perPhoto.isEmpty,
              let texts = try? applyingBatchTextMutations(perPhoto, to: base),
              let updated = try? applyingBatchListMutations(perPhoto, to: texts)
        else { return ([:], EditorialListWriteData(metadata: base)) }
        var fields: [MetadataFieldKey: String] = [:]
        for field in perPhoto.keys {
            if field == .creator {
                fields[field.metadataWriteKey] = updated.creatorTransportValue ?? ""
            } else if field.isRepeatable {
                fields[field.metadataWriteKey] = values(for: field, in: updated).joined(separator: ", ")
            } else {
                fields[field.metadataWriteKey] = field.textValue(in: updated) ?? ""
            }
        }
        return (fields, EditorialListWriteData(metadata: updated))
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
    @discardableResult
    private func mirrorEmbeddedStateToExistingSidecars(for urls: [URL]) async -> Set<URL> {
        guard let sidecarURLs = try? await MetadataSidecarMirrorPreflight.shared.existingImageURLs(urls) else {
            return []
        }
        guard !sidecarURLs.isEmpty else { return [] }
        // Not cancellable: the embedded write already happened, so skipping the read-back
        // would leave the sidecar shadowing it with stale values.
        guard let postWrite = try? await readService.readBatchFullMetadata(
            urls: sidecarURLs, stopsWhenCancelled: false
        ) else {
            logger.error("Sidecar mirror: post-write metadata read-back failed; existing .xmp sidecars left untouched")
            return []
        }
        var mirrored: Set<URL> = []
        for url in sidecarURLs {
            guard let record = postWrite[url] else { continue }
            do {
                try await xmpSidecarService.saveSidecarPreservingDevelopSettingsSerialized(
                    metadata: record,
                    for: url,
                    onlyIfExisting: true,
                    preserveExistingOrientationIfMissing: true
                )
                mirrored.insert(url)
            } catch {
                logger.error("Sidecar mirror failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return mirrored
    }

    /// Everything an XMP sidecar write needs, captured when the save is requested so a write
    /// that waits behind an earlier one still writes this selection's edits.
    private struct XMPSidecarWriteCapture {
        let urls: [URL]
        let folder: URL?
        let edited: IPTCMetadata
        let mutation: BatchRecordMutation
        let baselines: [URL: IPTCMetadata]
    }

    /// Returns nil (with `saveError` set) when the write must not start.
    private func captureXMPSidecarWrite() -> XMPSidecarWriteCapture? {
        do { try requirePrimaryDevelopWritesPersisted() }
        catch { saveError = error.localizedDescription; return nil }
        guard !selectedURLs.isEmpty else { return nil }
        return XMPSidecarWriteCapture(
            urls: selectedURLs,
            folder: currentFolderURL,
            edited: editingMetadata,
            mutation: capturedBatchMutation(),
            baselines: batchMetadataByURL
        )
    }

    /// Returns this write's own failure (also published as `saveError`), so a chained caller
    /// never mistakes another write's error — or its cleared error — for its own outcome.
    @discardableResult
    private func writeXMPSidecar(_ capture: XMPSidecarWriteCapture) async -> String? {
        let urls = capture.urls
        do {
            if let folder = capture.folder {
                for url in urls {
                    try await sidecarService.requireNoPendingOrientation(for: url, in: folder)
                }
            }
        } catch {
            saveError = error.localizedDescription
            return saveError
        }
        guard !Task.isCancelled else { return nil }
        if urls.count == 1, let imageURL = urls.first {
            let edited = capture.edited
            do {
                try await xmpSidecarService.saveSidecarSerialized(
                    metadata: edited,
                    for: imageURL
                )
                if selectedCount == 1, selectedURLs.first == imageURL {
                    xmpMetadata = edited
                }
            } catch {
                saveError = "Couldn't save the XMP file for \(imageURL.lastPathComponent). \(UserFacingErrorCause.sentence(for: error)) Try again."
                return saveError
            }
            return nil
        }

        var failure: String?
        for imageURL in urls {
            guard !Task.isCancelled else { return failure }
            do {
                var fallback = capture.baselines[imageURL] ?? IPTCMetadata()
                fallback.cameraRaw = nil
                let installed = try await xmpSidecarService.updateSidecarSerialized(
                    for: imageURL,
                    fallback: fallback,
                    preservesDevelopSettings: true,
                    mutation: capture.mutation.closure(for: imageURL, channel: .xmpSidecar)
                )
                capture.mutation.markDelivered(to: imageURL, channel: .xmpSidecar)
                if selectedURLs == urls {
                    batchMetadataByURL[imageURL] = installed
                }
            } catch {
                saveError = "Couldn't save the XMP file for \(imageURL.lastPathComponent). \(UserFacingErrorCause.sentence(for: error)) Try again."
                failure = failure ?? saveError
            }
        }
        return failure
    }

    private func writeXMPSidecarAndPreserveHistory(
        onComplete: @escaping (MetadataCommitResult) -> Void
    ) {
        guard let folderURL = currentFolderURL else {
            guard let capture = captureXMPSidecarWrite() else {
                onComplete(.failed(message: saveError ?? "The XMP sidecar could not be written."))
                return
            }
            // Wait for an earlier write instead of cancelling it partway through its selection,
            // and keep this one out of reach of a later `writeTask?.cancel()` the same way.
            let priorWrite = writeTask
            let generation = writeTaskGeneration + 1
            isSaving = true
            let batchTracking = capture.urls.count > 1 ? beginBatchWriteTracking(capture.urls) : nil
            let write = Task {
                defer { if writeTaskGeneration == generation { isSaving = false } }
                defer { if let batchTracking { endBatchWriteTracking(batchTracking) } }
                await priorWrite?.value
                // Judge this write by its own result: `saveError` may belong to the earlier one.
                if let failure = await writeXMPSidecar(capture) {
                    onComplete(.failed(message: failure))
                } else {
                    onComplete(.succeeded)
                }
            }
            writeTask = Task { await write.value }
            return
        }

        if selectedCount > 1 {
            guard let capture = captureXMPSidecarWrite() else {
                onComplete(.failed(message: saveError ?? "The XMP sidecar could not be written."))
                return
            }
            let historyCapture = captureBatchSidecars()
            let priorWrite = writeTask
            let generation = writeTaskGeneration + 1
            isSaving = true
            // The batch runs in its own task so a later `writeTask?.cancel()` cannot stop it
            // partway through the selection.
            let batchTracking = beginBatchWriteTracking(capture.urls)
            let write = Task {
                defer { if writeTaskGeneration == generation { isSaving = false } }
                defer { endBatchWriteTracking(batchTracking) }
                await priorWrite?.value
                // Judge each phase by its own result: `saveError` may belong to the earlier write.
                if let failure = await writeXMPSidecar(capture) {
                    onComplete(.failed(message: failure))
                    return
                }
                let historyFailure = await saveBatchSidecars(folderURL: folderURL, pendingChanges: false,
                    updateState: true, capture: historyCapture)
                if let historyFailure {
                    onComplete(.failed(message: historyFailure))
                } else {
                    if selectedURLs == historyCapture.selectedAtStart { hasChanges = false }
                    onComplete(.succeeded)
                }
            }
            writeTask = Task { await write.value }
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
        let xmpEvidence = editorXMPWriteEvidence(for: imageURL, in: folderURL)
        let loadID = metadataLoadRequestID
        let generation = writeTaskGeneration + 1
        isSaving = true
        saveError = nil

        let priorWrite = priorWriteForSingleSave(imageURL: imageURL, loadID: loadID)
        writeTask = Task {
            defer { if writeTaskGeneration == generation { isSaving = false } }
            await priorWrite?.value
            let matchesSelection = {
                self.writeTaskGeneration == generation && self.metadataLoadRequestID == loadID
                    && self.selectedURLs == [imageURL] && self.currentFolderURL == folderURL
                    && self.editingMetadata == edited
            }
            do {
                let snapshot = try await sidecarService.captureWriteCompletionSnapshot(
                    for: imageURL, in: folderURL, expectedSidecar: expectedRecord,
                        expectedTechnicalMetadata: technicalReference, expectedXMPSnapshot: try xmpEvidence.get())
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
                        editorXMPWriteBaseline = (imageURL, folderURL, loadID, result.writtenXMPSnapshot, nil)
                        // A RAW+JPEG pair's stem crs is the RAW's; the JPEG keeps its embedded develop.
                        editingMetadata.cameraRaw = PhotoSidecarOwnership.stemSidecarDevelopBelongsToRawSibling(of: imageURL)
                            ? edited.cameraRaw : xmpMetadata?.cameraRaw
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
        registerSingleSave(imageURL: imageURL, loadID: loadID)
    }

    private nonisolated static func writeCompletionFailure(
        _ result: MetadataSidecarPersistenceResult, imageWasWritten: Bool
    ) -> String {
        let prefix = imageWasWritten
            ? "Your changes were saved in the photo, but the app's saved edits couldn't be updated. Newer unsaved edits were kept."
            : result.wroteXMPSidecar
                ? "Your changes were saved in the XMP file, but the app's saved edits couldn't be updated."
                : "Your changes weren't saved."
        let detail = result.failure?.message ?? "The save was cancelled."
        let recovery = result.committedButUnverifiedSidecarURL.map { url in
            let name = url.lastPathComponent.replacingOccurrences(of: ".meta.json", with: "")
            return " The app's saved edits for \(name) may be incomplete."
        } ?? ""
        return "\(prefix) \(detail)\(recovery) Reload the folder, then try again."
    }

    /// True when the develop (Camera Raw) state differs between two snapshots,
    /// ignoring render-time-only fields the edit pipeline stamps on local copies
    /// (as-shot white balance, HDR-headroom flag). Gates whether a metadata save
    /// touches the file's crs block at all: a caption-only save on an ACR-edited
    /// file must not rewrite (and with replaceCameraRawBlock, wipe) Adobe's
    /// develop settings.
    nonisolated static func developSettingsChanged(_ a: CameraRawSettings?, _ b: CameraRawSettings?) -> Bool {
        PrimaryDevelopWriteRequestBuilder.developSettingsChanged(a, b)
    }

    private func overwriteFields(
        from metadata: IPTCMetadata,
        includeCameraRaw: Bool = true,
        imageAspect: () -> Double? = { nil }
    ) -> [MetadataFieldKey: String] {
        PrimaryDevelopWriteRequestBuilder.overwriteFields(from: metadata,
            original: originalImageMetadata, includeCameraRaw: includeCameraRaw, imageAspect: imageAspect)
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
        PrimaryDevelopWriteRequestBuilder.clearAllCameraRawFields(into: &fields)
    }

    private func writeMetadataAndPreserveHistory(
        alsoWriteXMPSidecar: Bool = false,
        onComplete: @escaping (MetadataCommitResult) -> Void
    ) {
        guard selectedCount == 1,
              let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else {
            // Batch / folderless fallback. Report completion only after both writes actually
            // finish, so callers (pending badges, Develop lifecycle) never see an early success.
            let xmpCapture = alsoWriteXMPSidecar ? captureXMPSidecarWrite() : nil
            if alsoWriteXMPSidecar, xmpCapture == nil {
                onComplete(.failed(message: saveError ?? "The XMP sidecar could not be written."))
                return
            }
            let generationBeforeEmbed = writeTaskGeneration
            writeMetadata()
            guard writeTaskGeneration != generationBeforeEmbed else {
                // The embedded write refused to start (for example unsaved Develop work).
                onComplete(.failed(message: saveError ?? "Metadata could not be written."))
                return
            }
            let embedGeneration = writeTaskGeneration
            let embedWrite = writeTask
            // Replacing `writeTask` advances the generation, so the inner write no longer owns
            // `isSaving`; this wrapper must clear it when it is still the latest write.
            let wrapperGeneration = writeTaskGeneration + 1
            // Like the embedded write, the XMP phase runs in its own task so a later
            // `writeTask?.cancel()` cannot stop it partway through the selection.
            let xmpTracking = xmpCapture.map { beginBatchWriteTracking($0.urls) }
            let write = Task {
                defer { if self.writeTaskGeneration == wrapperGeneration { self.isSaving = false } }
                defer { if let xmpTracking { self.endBatchWriteTracking(xmpTracking) } }
                await embedWrite?.value
                // Judge each phase by its own result: `saveError` may belong to another write.
                if let embedFailure = self.embeddedWriteFailures.removeValue(forKey: embedGeneration) {
                    onComplete(.failed(message: embedFailure))
                    return
                }
                if let xmpCapture {
                    if let xmpFailure = await writeXMPSidecar(xmpCapture) {
                        onComplete(.failed(message: xmpFailure))
                        return
                    }
                }
                onComplete(.succeeded)
            }
            writeTask = Task { await write.value }
            return
        }

        let edited = editingMetadata
        let previous = previousEditingMetadata
        let existingHistory = sidecarHistory
        let expectedRecord = currentWriteExpectedRecord
        let original = originalImageMetadata
        let technicalReference = xmpMetadata
        let xmpEvidence = editorXMPWriteEvidence(for: imageURL, in: folderURL)
        let loadID = metadataLoadRequestID
        let generation = writeTaskGeneration + 1
        isSaving = true
        saveError = nil

        let priorWrite = priorWriteForSingleSave(imageURL: imageURL, loadID: loadID)
        writeTask = Task {
            defer { if writeTaskGeneration == generation { isSaving = false } }
            await priorWrite?.value
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
                        expectedTechnicalMetadata: technicalReference, expectedXMPSnapshot: try xmpEvidence.get())
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
                        listValues: EditorialListWriteData(metadata: edited),
                        replaceCameraRawBlock: true)
                    : StructuredWriteData(editorial: EditorialStructuredWriteData(metadata: edited),
                                          listValues: EditorialListWriteData(metadata: edited))
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
                        editorXMPWriteBaseline = (imageURL, folderURL, loadID,
                            result.writtenXMPSnapshot ?? (result.skippedXMPSidecar ? (try? xmpEvidence.get()) : nil), nil)
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
        registerSingleSave(imageURL: imageURL, loadID: loadID)
    }

    func applyTemplateFields(_ template: [String: String], mode: TemplateApplyMode = .replace) {
        if mode == .fillEmpty {
            applyTemplateFillingEmptyFields(template)
            return
        }
        let append = mode == .append
        let editorBeforeTemplate = editingMetadata
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
                guard let values = EditorialImageSupplier.values(fromTemplateValue: value) else {
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
        if selectedCount > 1 {
            // A template names its repeatable fields explicitly. Capture that intent even when
            // the selection has no common value: the batch save would otherwise infer lists from
            // previousCommon (dropping organisation/code/controlled-vocabulary lists) and let
            // replace/append act on the common subset instead of every photo's own list.
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
                    case .untouched, .append, .appendText, .fillIfEmpty:
                        if !values.isEmpty { batchFieldMutations[field] = .append(values) }
                    }
                } else {
                    batchFieldMutations[field] = values.isEmpty ? .clear : .overwrite(.repeatable(values))
                }
            }
            recordBatchTextTemplateIntents(template, append: append, before: editorBeforeTemplate)
        }
        hasChanges = true
    }

    private func appendString(_ existing: String?, _ new: String) -> String {
        MetadataTemplateText.appending(existing, new)
    }

    /// Fill Empty Fields (Photo Mechanic): each template value lands only where its field is
    /// empty, and an empty template value never clears anything. A single photo is decided from
    /// the editor. A multi-selection fills a field every photo has empty like a replace, leaves a
    /// field they all share alone, and records a per-photo `.fillIfEmpty` intent for a mixed one.
    private func applyTemplateFillingEmptyFields(_ template: [String: String]) {
        var applied: [String: String] = [:]
        var perPhoto: [MetadataFieldID] = []
        for (key, value) in template {
            guard let field = MetadataFieldID(rawValue: key),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  field.isEmpty(in: editingMetadata) else { continue }
            guard selectedCount > 1 else {
                applied[key] = value
                continue
            }
            switch batchFillEmptyState(of: field) {
            case .allEmpty:
                applied[key] = value
            case .mixed:
                applied[key] = value
                perPhoto.append(field)
            case .filled:
                continue
            }
        }
        guard !applied.isEmpty else { return }

        // Mixed fields go through the replace path too, so they are parsed and validated exactly
        // like a replace; the recorded overwrite then becomes a per-photo fill and the editor
        // keeps showing the field's mixed state.
        let editorBefore = editingMetadata
        let mutationsBefore = batchFieldMutations
        let intentValuesBefore = batchTextIntentEditorValues
        let tokensBefore = batchTextAppendTokens
        applyTemplateFields(applied, mode: .replace)
        for field in perPhoto {
            field.setHistoryValue(field.historyValue(in: editorBefore), in: &editingMetadata)
            guard case .overwrite(let value)? = batchFieldMutations[field] else {
                // The template value resolved to nothing (e.g. every keyword rejected).
                batchFieldMutations[field] = mutationsBefore[field]
                batchTextIntentEditorValues[field] = intentValuesBefore[field]
                batchTextAppendTokens[field] = tokensBefore[field]
                continue
            }
            if field.isRepeatable {
                batchFieldMutations[field] = .fillIfEmpty(value)
            } else {
                let path = MetadataEditorFieldPaths.scalarText(for: field.rawValue)
                setBatchTextIntent(.fillIfEmpty(value), for: field,
                                   editorValue: path.map { editorBefore[keyPath: $0] } ?? nil)
            }
        }
    }

    private enum BatchFillEmptyState { case allEmpty, mixed, filled }

    /// How Fill Empty Fields treats a field the batch editor shows as empty.
    private func batchFillEmptyState(of field: MetadataFieldID) -> BatchFillEmptyState {
        if field == .imageSupplier {
            // Suppliers are not projected into the batch editor; only an all-empty selection
            // is known to be empty.
            let suppliers = batchListSelectionSummary.imageSuppliers
            return suppliers.common.isEmpty && suppliers.partial.isEmpty ? .allEmpty : .filled
        }
        let pending = field.isRepeatable ? batchFieldMutations[field] : batchTextIntent(for: field.rawValue)
        switch pending {
        case .clear?:
            return .allEmpty // A pending clear empties the field on every photo first.
        case .append?, .appendText?, .fillIfEmpty?:
            return .filled // Every photo already ends up with a value.
        default:
            break
        }
        guard batchDifferingFields.contains(field.rawValue) else { return .allEmpty }
        let supportsPerPhoto = field.isRepeatable
            || Self.batchTemplateTextFields.contains { $0.field == field }
        guard supportsPerPhoto else { return .filled } // Mixed values without a per-photo write path.
        if !batchMetadataByURL.isEmpty,
           !batchMetadataByURL.values.contains(where: { field.isEmpty(in: $0) }) {
            return .filled
        }
        return .mixed
    }

    /// How a template text field acts on a multi-selection. Appendable text concatenates per
    /// photo in append mode; atomic values are always replaced (or cleared when empty).
    private enum BatchTemplateTextKind { case appendable, atomic }

    private static let batchTemplateTextFields: [(key: String, field: MetadataFieldID, kind: BatchTemplateTextKind)] = [
        ("title", .headline, .appendable), ("description", .description, .appendable),
        ("extendedDescription", .extendedDescription, .appendable),
        ("creatorJobTitle", .creatorJobTitle, .appendable), ("descriptionWriter", .descriptionWriter, .appendable),
        ("credit", .credit, .appendable), ("copyright", .copyright, .appendable),
        ("rightsUsageTerms", .rightsUsageTerms, .appendable), ("webStatementOfRights", .webStatementOfRights, .appendable),
        ("jobId", .jobId, .appendable), ("city", .city, .appendable), ("sublocation", .sublocation, .appendable),
        ("provinceState", .provinceState, .appendable), ("country", .country, .appendable),
        ("event", .event, .appendable), ("instructions", .instructions, .appendable), ("source", .source, .appendable),
        ("digitalImageGUID", .digitalImageGUID, .atomic), ("imageSupplierImageID", .imageSupplierImageID, .atomic),
        ("countryCode", .countryCode, .atomic),
    ]

    /// Records explicit per-photo text intent for a template applied to a multi-selection.
    /// Without it the batch save only sees the common-value preview: an append on a mixed field
    /// would write the bare template text over every photo's own value, and an empty ("clear")
    /// template field would leave mixed values untouched.
    private func recordBatchTextTemplateIntents(
        _ template: [String: String],
        append: Bool,
        before: IPTCMetadata
    ) {
        for (key, field, kind) in Self.batchTemplateTextFields {
            guard let value = template[key],
                  let path = MetadataEditorFieldPaths.scalarText(for: key) else { continue }
            let beforeValue = before[keyPath: path]
            let after = editingMetadata[keyPath: path]
            // An intent recorded by an earlier template is current only while the editor still
            // shows the value it was recorded against; a typed value supersedes it.
            var prior = batchFieldMutations[field]
            if prior != nil, !Self.sameEditorText(batchTextIntentEditorValues[field] ?? nil, beforeValue) {
                prior = nil
            }
            let afterIsEmpty = (after ?? "").isEmpty
            if append, kind == .appendable {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue // Appending nothing leaves the field and its intent as they were.
                }
                switch prior {
                case .appendText(let earlier)?:
                    // Extends the pending append, keeping its token. A mixed field keeps showing
                    // its mixed state; a shared one shows the combined value that will be written.
                    let combined = MetadataFieldMutation.appendText(MetadataTemplateText.appending(earlier, value))
                    if batchDifferingFields.contains(key) {
                        setBatchTextIntent(combined, for: field, restoring: beforeValue, path: path, keepsToken: true)
                    } else {
                        setBatchTextIntent(combined, for: field, editorValue: after, keepsToken: true)
                    }
                case .overwrite?, .clear?:
                    setBatchTextIntent(.overwrite(.scalar(after ?? value)), for: field, editorValue: after)
                default:
                    let commonValue = previousEditingMetadata?[keyPath: path]
                    if !Self.sameEditorText(beforeValue, commonValue) {
                        // The user typed a value for every photo; the template extends it.
                        setBatchTextIntent(.overwrite(.scalar(after ?? value)), for: field, editorValue: after)
                    } else if batchDifferingFields.contains(key) {
                        // Mixed values: there is no common text to preview. Keep the field
                        // showing its mixed state; each photo gets its own text plus the template.
                        setBatchTextIntent(.appendText(value), for: field, restoring: beforeValue, path: path)
                    } else {
                        setBatchTextIntent(.appendText(value), for: field, editorValue: after)
                    }
                }
            } else if afterIsEmpty {
                setBatchTextIntent(.clear, for: field, editorValue: after)
            } else if let after {
                setBatchTextIntent(.overwrite(.scalar(after)), for: field, editorValue: after)
            }
        }
    }

    private func setBatchTextIntent(
        _ mutation: MetadataFieldMutation,
        for field: MetadataFieldID,
        editorValue: String?,
        keepsToken: Bool = false
    ) {
        batchFieldMutations[field] = mutation
        batchTextIntentEditorValues[field] = .some(editorValue)
        if case .appendText = mutation {
            if !keepsToken || batchTextAppendTokens[field] == nil { batchTextAppendTokens[field] = UUID() }
        } else {
            batchTextAppendTokens.removeValue(forKey: field)
        }
    }

    /// The panel stores an emptied text field as nil; a template sets "". Both mean empty.
    private nonisolated static func sameEditorText(_ lhs: String?, _ rhs: String?) -> Bool {
        (lhs ?? "") == (rhs ?? "")
    }

    /// Records an append on a mixed field and puts the editor back to its mixed (empty) state.
    private func setBatchTextIntent(
        _ mutation: MetadataFieldMutation,
        for field: MetadataFieldID,
        restoring editorValue: String?,
        path: WritableKeyPath<IPTCMetadata, String?>,
        keepsToken: Bool = false
    ) {
        editingMetadata[keyPath: path] = editorValue
        setBatchTextIntent(mutation, for: field, editorValue: editorValue, keepsToken: keepsToken)
    }

    /// Drops scalar text intents whose field the user has since edited, so the typed value is
    /// saved with ordinary batch semantics instead of the superseded template intent.
    private func pruneStaleBatchTextIntents() {
        for (field, mutation) in batchFieldMutations where !field.isRepeatable {
            guard mutation != .untouched else { continue }
            let path = MetadataEditorFieldPaths.scalarText(for: field.rawValue)
            let current = path.map { editingMetadata[keyPath: $0] } ?? nil
            if !Self.sameEditorText(batchTextIntentEditorValues[field] ?? nil, current) {
                batchFieldMutations.removeValue(forKey: field)
                batchTextIntentEditorValues.removeValue(forKey: field)
                batchTextAppendTokens.removeValue(forKey: field)
            }
        }
    }

    /// The pending template text intent for an editor field key, if any (batch editor only).
    func batchTextIntent(for key: String) -> MetadataFieldMutation? {
        guard isBatchEdit, let field = MetadataFieldID(rawValue: key), !field.isRepeatable,
              let mutation = batchFieldMutations[field] else { return nil }
        let path = MetadataEditorFieldPaths.scalarText(for: key)
        let current = path.map { editingMetadata[keyPath: $0] } ?? nil
        guard Self.sameEditorText(batchTextIntentEditorValues[field] ?? nil, current) else { return nil }
        return mutation
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
    func applyTemplateFieldsAndProcessVariables(_ template: [String: String], to images: [ImageFile], mode: TemplateApplyMode = .replace) {
        do { try requireVariableDiscardedEditorReconciled() }
        catch { saveError = error.localizedDescription; return }
        guard variableRecoveryOwnerID == nil else {
            saveError = "Finish or cancel the variable conflict review before applying a variable template."
            return
        }
        applyTemplateFields(template, mode: mode)
        guard !images.isEmpty else { return }
        // Capture the batch mutation with the variable request. Awaited JSON preparation saves
        // the complete per-photo result; no separate fire-and-forget literal write can race it.
        let previewAction: VoiceMemoVariablePreviewAction = switch mode {
        case .replace: .replace
        case .fillEmpty: .fillEmpty
        case .append: .append
        }
        startVariableBatch(images: images, previewAction: previewAction)
    }

    private static let variablePattern = /(?:\{(date|date:[^}]+|dateCreated|dateCreated:[^}]+|dateCaptured|dateCaptured:[^}]+|filename|initials|persons|keywords|voiceMemoTranscript|number|gps|gps:city|gps:country|latitude|longitude|field:[^}]+|seq|seq:\d+)\}|\(number\))/

    /// Checks whether any text field, keyword, or person in editingMetadata contains variable placeholders.
    var hasVariables: Bool {
        if Self.containsVariables(editingMetadata) { return true }
        // A batch template append or fill on a mixed field keeps its text in the explicit
        // intent, not in the editor buffer.
        return batchFieldMutations.values.contains { mutation in
            switch mutation {
            case .appendText(let text), .fillIfEmpty(.scalar(let text)):
                return text.contains(Self.variablePattern)
            case .fillIfEmpty(.repeatable(let values)):
                return values.contains { $0.contains(Self.variablePattern) }
            default:
                return false
            }
        }
    }

    /// Whether any field variable resolution expands contains a placeholder. The scalar field
    /// list is the resolver's own (`VariableMetadataResolver.scalarVariableFields`).
    static func containsVariables(_ editingMetadata: IPTCMetadata) -> Bool {
        let fields = VariableMetadataResolver.scalarVariableFields.map { editingMetadata[keyPath: $0] }
        let localizedTitleValues = editingMetadata.localizedTitles?.map(\.value) ?? []
        if fields.contains(where: { field in
            guard let field else { return false }
            return field.contains(Self.variablePattern)
        }) || localizedTitleValues.contains(where: { $0.contains(Self.variablePattern) }) {
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
        do { try requireVariableDiscardedEditorReconciled() }
        catch { saveError = error.localizedDescription; return }
        guard variableRecoveryOwnerID == nil else {
            saveError = "Finish or cancel the variable conflict review before resolving variables."
            return
        }
        guard !isProcessingFolder else {
            saveError = "Wait for the current folder operation before resolving this editor's variables."
            return
        }
        guard let imageURL = selectedURLs.first, selectedCount == 1 else { return }
        let original = editingMetadata
        let selection = selectedURLs
        let folder = currentFolderURL
        let loadID = metadataLoadRequestID
        let options = variableOptions()
        let generation = batchProcessGeneration + 1
        batchProcessTask?.cancel()
        batchProcessTask = Task {
            do {
                let transcriptContext: VoiceMemoTranscriptVariableContext? = if
                    VariableMetadataResolver.requiresVoiceMemoTranscript(original)
                { try await voiceMemoTranscriptContextLoader(imageURL) } else { nil }
                let input = VariableMetadataResolutionInput(metadata: original, imageURL: imageURL,
                    filename: filename, sequenceIndex: sequenceIndex, options: options,
                    voiceMemoTranscriptContext: transcriptContext)
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
        startVariableBatch(images: images, previewAction: .processExisting)
    }

    func processVariablesInFolder(images: [ImageFile]) {
        startVariableBatch(images: images, previewAction: .processExisting)
    }

    func confirmVoiceMemoVariablePreview(_ previewID: UUID) {
        guard !isProcessingFolder,
              let state = pendingVoiceMemoVariablePreviewState,
              state.id == previewID,
              voiceMemoVariablePreview?.id == previewID else { return }
        let ids = Set(state.requestIDs)
        let requests = retainedVariableWrites.filter { ids.contains($0.id) }
        guard requests.count == ids.count else {
            cancelVoiceMemoVariablePreview(previewID)
            saveError = "The reviewed transcript preview is no longer current. Prepare it again."
            return
        }
        let action = voiceMemoVariablePreview?.action ?? .processExisting
        pendingVoiceMemoVariablePreviewState = nil
        voiceMemoVariablePreview = nil
        startVariableBatch(images: [], retryRequests: requests, retryFolder: state.folderURL,
            previewAction: action, voiceMemoPreviewConfirmed: true)
    }

    func cancelVoiceMemoVariablePreview(_ previewID: UUID) {
        guard let state = pendingVoiceMemoVariablePreviewState, state.id == previewID else { return }
        let ids = Set(state.requestIDs)
        retainedVariableWrites.removeAll { ids.contains($0.id) }
        for id in ids {
            retainedVariableOrigins.removeValue(forKey: id)
            retainedVariableEditorCheckpoints.removeValue(forKey: id)
        }
        pendingVoiceMemoVariablePreviewState = nil
        voiceMemoVariablePreview = nil
        variableProcessingStatus = "Voice-memo transcript application was cancelled; no metadata was written."
        variableProcessingHadFailures = false
        AccessibilityAnnouncementCenter.post(.cancellation(.voiceMemoTranscriptApplication))
        synchronizeVariableLifecycleRetention()
    }

    func retryVariableWrites() {
        guard voiceMemoVariablePreview == nil else {
            saveError = "Confirm or cancel the voice-memo transcript preview before retrying variable writes."
            return
        }
        guard !isProcessingFolder else {
            saveError = "Variable processing is still running. Wait for it to finish before retrying."
            return
        }
        if retainedVariableWrites.isEmpty && retainedVariableAdmissions.isEmpty && !variableDiscardedEditorCheckpoints.isEmpty {
            guard variableRecoveryOwnerID == nil else { return }
            saveError = nil
            batchProcessTask = Task {
                await reconcileVariableDiscardedEditors()
                synchronizeVariableLifecycleRetention()
            }
            return
        }
        guard let folder = retainedVariableWrites.first?.folderURL ?? retainedVariableAdmissions.first?.folderURL else { return }
        let folderKey = Self.variablePhotoKey(folder)
        let requests = retainedVariableWrites.filter { Self.variablePhotoKey($0.folderURL) == folderKey }
        let admissions = retainedVariableAdmissions.filter { Self.variablePhotoKey($0.folderURL) == folderKey }
        saveError = nil
        startVariableBatch(images: [], retryRequests: requests, retryAdmissions: admissions, retryFolder: folder,
            previewAction: .processExisting)
    }

    func waitForVariableProcessing() async { await batchProcessTask?.value }

    func requireVariableDraftsPersisted() throws {
        if variableRecoveryOwnerID != nil {
            throw CaptionWorkspaceFlushError.persistenceFailed("Finish or cancel the variable conflict review before closing or changing this workspace.")
        }
        if variableDiscardedEditorCheckpoints.contains(where: variableDiscardOwnsCurrentEditor) {
            throw CaptionWorkspaceFlushError.persistenceFailed(
                "The discarded variable editor must be refreshed before saving or leaving. Open the metadata editor and finish recovery for any other selected photos.")
        }
        if !activeVariableBatchIDs.isEmpty {
            throw CaptionWorkspaceFlushError.persistenceFailed(
                "Variable processing is still running. Wait for its result before closing or changing this workspace.")
        }
        let unverified = retainedVariableWrites.filter { !$0.hasVerifiedPreparedRecord }
        let riskyAdmissions = retainedVariableAdmissions.filter(\.requiresPersistence)
        guard unverified.isEmpty && riskyAdmissions.isEmpty else {
            throw CaptionWorkspaceFlushError.persistenceFailed(
                "Some variable edits haven't been confirmed as saved. Use Retry Variable Writes before closing. Photos: "
                + (unverified.map { $0.imageURL.lastPathComponent } + riskyAdmissions.map { $0.imageURL.lastPathComponent }).joined(separator: ", "))
        }
    }

    private func synchronizeVariableLifecycleRetention() {
        if variableRecoveryOwnerID != nil || variableDiscardedEditorCheckpoints.contains(where: variableDiscardOwnsCurrentEditor) || !activeVariableBatchIDs.isEmpty || retainedVariableAdmissions.contains(where: \.requiresPersistence) || retainedVariableWrites.contains(where: { !$0.hasVerifiedPreparedRecord }) {
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
        encoder.dateEncodingStrategy = .iso8601
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

    @ObservationIgnored private var variableRecoveryEditorBarrier: (owner: UUID, handler: @MainActor () throws -> Void)?

    func registerVariableRecoveryEditorBarrier(owner: UUID, handler: @escaping @MainActor () throws -> Void) {
        variableRecoveryEditorBarrier = (owner, handler)
    }

    func unregisterVariableRecoveryEditorBarrier(owner: UUID) {
        if variableRecoveryEditorBarrier?.owner == owner { variableRecoveryEditorBarrier = nil }
    }

    func prepareVariableRecoveryPresentation() throws {
        try variableRecoveryEditorBarrier?.handler()
    }

    /// Publishes typed-but-uncommitted text from the focused metadata field into
    /// `editingMetadata`. AppKit text fields only commit on focus loss or Return, so keyboard
    /// navigation, Paste IPTC and termination call this before deciding whether to save.
    func captureFocusedEditorText() {
        // The barrier flushes the field buffer first; its later folder check is irrelevant here.
        try? variableRecoveryEditorBarrier?.handler()
    }

    /// Automatic saves (navigation, backgrounding, quit) must not embed literal `{variable}`
    /// tokens. Keep the edit as a pending draft instead and tell the user why.
    func keepUnresolvedVariablesAsPendingDraft(onComplete: ((String?) -> Void)? = nil) {
        let names = selectedURLs.map(\.lastPathComponent)
        withEditorFolder { saveToSidecar(onComplete: onComplete) }
        notice = MetadataPanelNotice(
            title: "Unresolved variables were kept as a pending draft. Use Process Variables, then Write, to update the file.",
            detail: names,
            severity: .warning
        )
        // Raised at a navigation boundary: keep it through the load of the next selection.
        noticeSurvivesNextSelectionLoad = true
    }

    /// The write a new single-photo save must wait for. Saves queue instead of cancelling the
    /// running write: a cancelled batch or other-photo save stops partway and loses its edits.
    /// Only a still-running save of this same photo and load is superseded, as before — the new
    /// request carries its newer edits and was captured against the same baseline. Call
    /// `registerSingleSave` right after installing the new `writeTask`.
    private func priorWriteForSingleSave(imageURL: URL, loadID: UUID?) -> Task<Void, Never>? {
        let prior = writeTask
        if let owner = supersedableSingleSave, owner.generation == writeTaskGeneration,
           owner.imageURL == imageURL, owner.loadID == loadID {
            prior?.cancel()
        }
        return prior
    }

    private func registerSingleSave(imageURL: URL, loadID: UUID?) {
        supersedableSingleSave = (writeTaskGeneration, imageURL, loadID)
    }

    /// Waits until the current write chain (including writes queued while waiting) finishes.
    /// Folder-wide batches (Write All Pending, Process Variables) run outside it; only quit
    /// (`waitForPendingWritesAndBatches`) and file operations whose targets the batch is
    /// writing (`waitForBatchOverlapping`) wait for those.
    func waitForPendingWrites() async {
        while let task = writeTask {
            await task.value
            if writeTask == task { return }
        }
    }

    /// Quit-time barrier: the write chain and any metadata batch, including work queued meanwhile.
    func waitForPendingWritesAndBatches() async {
        while true {
            let write = writeTask
            let batch = batchProcessTask
            await write?.value
            await batch?.value
            if writeTask == write, batchProcessTask == batch { return }
        }
    }

    nonisolated enum BatchProcessKind: Sendable {
        case writeAllPending
        case processVariables

        var displayName: String {
            switch self {
            case .writeAllPending: "Write All"
            case .processVariables: "Process Variables"
            }
        }
    }

    /// What the running folder batch is and which folder it writes; valid while `isProcessingFolder`.
    @ObservationIgnored private var batchProcessScope: (kind: BatchProcessKind, folder: URL)?

    /// "Write All: 340 of 2000" while a folder batch runs, else nil.
    var runningBatchDescription: String? {
        guard isProcessingFolder, let scope = batchProcessScope else { return nil }
        let parts = folderProcessProgress.split(separator: "/")
        guard parts.count == 2 else { return scope.kind.displayName }
        return "\(scope.kind.displayName): \(parts[0]) of \(parts[1])"
    }

    /// The kind of running folder batch that may write any of `urls`, or nil.
    func runningBatchOverlapping(_ urls: [URL]) -> BatchProcessKind? {
        guard isProcessingFolder, let scope = batchProcessScope else { return nil }
        let folder = scope.folder.standardizedFileURL.resolvingSymlinksInPath().path
        let overlaps = urls.contains {
            $0.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == folder
        }
        return overlaps ? scope.kind : nil
    }

    /// Waits for the folder batch only when it may be writing one of `urls` (rename, move).
    func waitForBatchOverlapping(_ urls: [URL]) async {
        guard runningBatchOverlapping(urls) != nil else { return }
        while let batch = batchProcessTask {
            await batch.value
            if batchProcessTask == batch { return }
        }
    }

    /// The Browser editor boundary (folder switch, folder close, workspace exit) that is
    /// committing the departing photos, including its discard prompt. Termination waits for it
    /// rather than committing the same photo a second time and stacking a second prompt.
    @ObservationIgnored private var editorBoundaryTask: Task<Void, Never>?

    func trackEditorBoundary(_ task: Task<Void, Never>) {
        editorBoundaryTask = task
    }

    func waitForEditorBoundary() async {
        while let task = editorBoundaryTask {
            await task.value
            if editorBoundaryTask == task {
                editorBoundaryTask = nil
                return
            }
        }
    }

    /// Photos covered by queued or running batch writes. A single-photo load of one of them waits
    /// for those writes, so its editor baseline includes the batch change; otherwise a later save
    /// of that photo would rewrite its fields from the pre-batch values and undo the batch.
    @ObservationIgnored private var pendingBatchWriteURLs: [UUID: Set<URL>] = [:]

    private func beginBatchWriteTracking(_ urls: [URL]) -> UUID {
        let id = UUID()
        pendingBatchWriteURLs[id] = Set(urls.map(\.standardizedFileURL))
        return id
    }

    private func endBatchWriteTracking(_ id: UUID) {
        pendingBatchWriteURLs[id] = nil
    }

    private func isPendingBatchWrite(_ url: URL) -> Bool {
        let key = url.standardizedFileURL
        return pendingBatchWriteURLs.values.contains { $0.contains(key) }
    }

    var variableRecoveryPhotos: [URL] {
        var seen = Set<String>()
        return (retainedVariableWrites.map(\.imageURL) + retainedVariableAdmissions.map(\.imageURL))
            .filter { seen.insert(Self.variablePhotoKey($0)).inserted }
    }

    func beginVariableRecovery(for photoURL: URL) async throws -> VariableConflictSnapshot {
        guard variableRecoveryOwnerID == nil else { throw VariableConflictRecoveryError.requestRunning }
        guard variableRecoveryPhotos.contains(where: { Self.variablePhotoKey($0) == Self.variablePhotoKey(photoURL) }) else {
            throw VariableConflictRecoveryError.obsoleteReview
        }
        try prepareVariableRecoveryPresentation()
        let owner = UUID()
        variableRecoveryOwnerID = owner
        variableRecoveryPhotoURL = photoURL
        variableRecoveryEndRequested = false
        synchronizeVariableLifecycleRetention()
        do {
            // Freeze first, then settle every already accepted operation. In-flight admissions
            // may become requests; the review snapshots that final set, never an earlier guess.
            if !activeVariableBatchIDs.isEmpty {
                await withCheckedContinuation { variableQuiescenceWaiters.append($0) }
            }
            try Task.checkCancellation()
            guard variableRecoveryOwnerID == owner else { throw VariableConflictRecoveryError.obsoleteReview }
            let entries = try variableRecoveryEntries(for: photoURL)
            guard !entries.isEmpty else { throw VariableConflictRecoveryError.obsoleteReview }
            let generation = variableRecoveryGeneration
            let snapshot = try await VariableConflictRecovery.makeSnapshot(photoURL: photoURL,
                reason: variableFailures[Self.variablePhotoKey(photoURL)] ?? "Unsaved variable edits need review.",
                generation: generation, entries: entries)
            try Task.checkCancellation()
            guard variableRecoveryOwnerID == owner, variableRecoveryGeneration == generation else {
                throw VariableConflictRecoveryError.obsoleteReview
            }
            variableRecoverySnapshot = snapshot
            return snapshot
        } catch {
            if variableRecoveryOwnerID == owner { releaseVariableRecovery() }
            throw error
        }
    }

    func endVariableRecovery(_ snapshot: VariableConflictSnapshot) async {
        guard variableRecoverySnapshot?.id == snapshot.id else { return }
        if variableRecoveryOperationID != nil {
            // The operation owns its freeze through verification and editor cleanup even if the
            // sheet disappears. Its defer releases only after every awaited step is finished.
            variableRecoveryEndRequested = true
        } else { releaseVariableRecovery() }
    }

    func exportVariableRecovery(_ snapshot: VariableConflictSnapshot, to url: URL) async throws -> VariableConflictExportReceipt {
        try validateVariableRecovery(snapshot)
        guard variableRecoveryOperationID == nil else { throw VariableConflictRecoveryError.requestRunning }
        let operation = UUID()
        variableRecoveryOperationID = operation
        defer { finishVariableRecoveryOperation(operation) }
        let receipt = try await VariableConflictRecovery.export(snapshot, to: url,
            currentEntries: variableRecoveryEntries(for: snapshot.photoURL), generation: variableRecoveryGeneration,
            protectedPhotoURLs: variableRecoveryProtectedPhotos, access: variableRecoveryExportAccess)
        try Task.checkCancellation()
        try validateVariableRecovery(snapshot)
        return receipt
    }

    func discardVariableRecovery(_ snapshot: VariableConflictSnapshot, receipt: VariableConflictExportReceipt) async throws {
        try validateVariableRecovery(snapshot)
        guard variableRecoveryOperationID == nil else { throw VariableConflictRecoveryError.requestRunning }
        let operation = UUID()
        variableRecoveryOperationID = operation
        defer { finishVariableRecoveryOperation(operation) }
        await variableRecoveryBeforeDiscard()
        try Task.checkCancellation()
        try validateVariableRecovery(snapshot)
        let ids = try await VariableConflictRecovery.verifyDiscard(snapshot, receipt: receipt,
            currentEntries: variableRecoveryEntries(for: snapshot.photoURL), generation: variableRecoveryGeneration,
            protectedPhotoURLs: variableRecoveryProtectedPhotos)
        try Task.checkCancellation()
        try validateVariableRecovery(snapshot)
        guard Set(ids) == Set(snapshot.entryIDs) else { throw VariableConflictRecoveryError.obsoleteReview }
        // Capture any currently focused native text before deciding whether the original
        // editor checkpoint is unchanged. No registered barrier means no destructive reload.
        try prepareVariableRecoveryPresentation()
        let mayReloadEditor = variableRecoveryEditorBarrier != nil
        let key = Self.variablePhotoKey(snapshot.photoURL)
        let idSet = Set(ids)
        let origin = retainedVariableAdmissions.first { idSet.contains($0.id) && Self.variablePhotoKey($0.imageURL) == key }
            ?? retainedVariableWrites.first(where: { idSet.contains($0.id) && Self.variablePhotoKey($0.imageURL) == key })
                .flatMap { retainedVariableOrigins[$0.id] }
        if (!mayReloadEditor || isSaving), let origin, variableDiscardOwnsCurrentEditor(origin) {
            throw CaptionWorkspaceFlushError.persistenceFailed(isSaving
                ? "Wait for the current metadata save to finish before discarding variable requests. The exported requests are still retained."
                : "Open the metadata editor before discarding this photo's variable requests so its current text can be checked. The exported requests are still retained.")
        }
        retainedVariableAdmissions.removeAll { idSet.contains($0.id) && Self.variablePhotoKey($0.imageURL) == key }
        retainedVariableWrites.removeAll { idSet.contains($0.id) && Self.variablePhotoKey($0.imageURL) == key }
        for id in ids {
            retainedVariableEditorCheckpoints.removeValue(forKey: id)
            retainedVariableOrigins.removeValue(forKey: id)
        }
        variableFailures.removeValue(forKey: key)
        if let origin, variableDiscardOwnsCurrentEditor(origin) {
            variableDiscardedEditorCheckpoints.append(origin)
            if mayReloadEditor { await reconcileVariableDiscardedEditors() }
        }
        // Verification and removal are complete; no file or sidecar has been modified.
        releaseVariableRecovery()
    }

    private var variableRecoveryProtectedPhotos: [URL] { variableRecoveryPhotos + selectedURLs }

    private func validateVariableRecovery(_ snapshot: VariableConflictSnapshot) throws {
        guard variableRecoveryOwnerID != nil, variableRecoverySnapshot?.id == snapshot.id,
              variableRecoveryGeneration == snapshot.generation,
              variableRecoveryPhotoURL.map(Self.variablePhotoKey) == Self.variablePhotoKey(snapshot.photoURL) else {
            throw VariableConflictRecoveryError.obsoleteReview
        }
    }

    private func finishVariableRecoveryOperation(_ operation: UUID) {
        guard variableRecoveryOperationID == operation else { return }
        variableRecoveryOperationID = nil
        if variableRecoveryEndRequested { releaseVariableRecovery() }
    }

    private func releaseVariableRecovery() {
        variableRecoverySnapshot = nil
        variableRecoveryPhotoURL = nil
        variableRecoveryOwnerID = nil
        variableRecoveryOperationID = nil
        variableRecoveryEndRequested = false
        synchronizeVariableLifecycleRetention()
    }

    private func variableRecoveryEntries(for photoURL: URL) throws -> [VariableConflictEntry] {
        let key = Self.variablePhotoKey(photoURL)
        let failure = variableFailures[key]
        let admissions = try retainedVariableAdmissions.filter { Self.variablePhotoKey($0.imageURL) == key }.map {
            VariableConflictEntry(id: $0.id, imageURL: $0.imageURL, folderURL: $0.folderURL,
                admissionPayload: try variableAdmissionPayload($0), failure: failure)
        }
        let requests = try retainedVariableWrites.filter { Self.variablePhotoKey($0.imageURL) == key }.map { request in
            VariableConflictEntry(id: request.id, imageURL: request.imageURL, folderURL: request.folderURL,
                admissionPayload: try retainedVariableOrigins[request.id].map(variableAdmissionPayload),
                request: request, failure: failure)
        }
        return requests + admissions
    }

    private func variableAdmissionPayload(_ admission: VariableAdmission) throws -> Data {
        func json<T: Encodable>(_ value: T) throws -> Any {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
        }
        func metadata(_ value: IPTCMetadata?) throws -> Any { try json(value.map(VariableRecoveryMetadata.init)) }
        func sidecar(_ value: MetadataSidecar?) throws -> Any { try json(value.map(VariableRecoverySidecar.init)) }
        func mutation(_ value: MetadataFieldMutation) throws -> [String: Any] {
            switch value {
            case .untouched: return ["operation": "untouched"]
            case .clear: return ["operation": "clear"]
            case .append(let values): return ["operation": "append", "values": values]
            case .appendText(let value): return ["operation": "appendText", "value": value]
            case .overwrite(.scalar(let value)): return ["operation": "overwriteScalar", "value": value]
            case .overwrite(.repeatable(let values)): return ["operation": "overwriteRepeatable", "values": values]
            case .fillIfEmpty(.scalar(let value)): return ["operation": "fillIfEmptyScalar", "value": value]
            case .fillIfEmpty(.repeatable(let values)): return ["operation": "fillIfEmptyRepeatable", "values": values]
            }
        }
        let options = admission.options
        let ownsEditor = admission.selectedURLs.contains(admission.imageURL)
        var document: [String: Any] = [
            "formatVersion": 1, "admissionID": admission.id.uuidString,
            "imageURL": admission.imageURL.absoluteString, "folderURL": admission.folderURL.absoluteString,
            "requiresPersistence": admission.requiresPersistence,
            "selectionURLs": ownsEditor ? admission.selectedURLs.map(\.absoluteString) : [],
            "selectionLoadID": try json(ownsEditor ? admission.loadID : nil),
            "editedMetadata": try metadata(ownsEditor ? admission.edited : nil),
            "previousMetadata": try metadata(ownsEditor ? admission.previous : nil),
            "expectedSidecarExisted": ownsEditor && admission.expectedRecord != nil,
            "expectedSidecar": try sidecar(ownsEditor ? admission.expectedRecord : nil),
            "referenceSource": ownsEditor ? admission.referenceSource.rawValue : "automatic",
            "hasEditorInput": ownsEditor && admission.hasEditorInput,
            "sequenceIndex": admission.sequenceIndex, "filename": admission.imageURL.lastPathComponent,
            "batchBaseline": try metadata(ownsEditor ? admission.batchBaseline : nil),
            "options": ["ordinaryMode": options.ordinaryMode.rawValue, "credentialMode": options.credentialMode.rawValue,
                "rawMode": options.rawMode.rawValue, "credentialRawMode": options.credentialRawMode.rawValue,
                "initials": options.initials, "addJobIDToKeywords": options.addJobIDToKeywords,
                "approvedKeywords": options.approvedKeywords, "strictKeywords": options.strictKeywords] as [String: Any]
        ]
        if ownsEditor, let batch = admission.batchInput {
            var fields: [String: Any] = [:]
            for (field, intent) in batch.fields { fields[field.rawValue] = try mutation(intent) }
            let locations: [String: Any]
            switch batch.locations {
            case .untouched: locations = ["operation": "untouched"]
            case .clear: locations = ["operation": "clear"]
            case .append(let values): locations = ["operation": "append", "values": try json(values)]
            case .replace(let values): locations = ["operation": "replace", "values": try json(values)]
            }
            let suppliers: [String: Any]
            switch batch.suppliers {
            case .untouched: suppliers = ["operation": "untouched"]
            case .clear: suppliers = ["operation": "clear"]
            case .append(let values): suppliers = ["operation": "append", "values": try json(values)]
            case .replace(let values): suppliers = ["operation": "replace", "values": try json(values)]
            }
            document["batchInput"] = ["metadata": try metadata(batch.metadata),
                "previousCommon": try metadata(batch.previousCommon), "fields": fields,
                "locations": locations, "suppliers": suppliers, "keywordsMode": batch.keywordsMode.rawValue,
                "personMode": batch.personMode.rawValue]
        } else { document["batchInput"] = NSNull() }
        if let input = admission.cachedInput {
            document["cachedFirstInput"] = ["baselineSidecar": try sidecar(input.baselineSidecar),
                "embeddedMetadata": try metadata(input.embeddedMetadata), "xmpMetadata": try metadata(input.xmpMetadata),
                "hasC2PA": input.hasC2PA, "evidence": try json(input.evidence)]
        } else { document["cachedFirstInput"] = NSNull() }
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    private var variableDiscardedEditorCheckpoints: [VariableAdmission] = []

    private func reconcileVariableDiscardedEditors() async {
        guard !isSaving, variableRecoveryEditorBarrier != nil else { return }
        do { try prepareVariableRecoveryPresentation() } catch { return }
        let pending = variableDiscardedEditorCheckpoints
        for origin in pending {
            let keys = Set(origin.selectedURLs.map(Self.variablePhotoKey))
            guard !variableRecoveryPhotos.contains(where: { keys.contains(Self.variablePhotoKey($0)) }) else { continue }
            variableDiscardedEditorCheckpoints.removeAll { $0.id == origin.id }
            await reloadAfterVariableDiscard(origin)
        }
    }

    private func requireVariableDiscardedEditorReconciled() throws {
        guard !variableDiscardedEditorCheckpoints.contains(where: variableDiscardOwnsCurrentEditor) else {
            throw CaptionWorkspaceFlushError.persistenceFailed(
                "This shared editor still contains exported variable edits. Finish recovery for the other selected photos, then use Retry Variable Writes to refresh it before saving.")
        }
    }

    private func variableDiscardOwnsCurrentEditor(_ origin: VariableAdmission) -> Bool {
        !origin.selectedURLs.isEmpty && origin.selectedURLs.contains(origin.imageURL)
            && selectedURLs == origin.selectedURLs
            && currentFolderURL.map(Self.variablePhotoKey) == Self.variablePhotoKey(origin.folderURL)
            && metadataLoadRequestID == origin.loadID && editingMetadata == origin.edited
    }

    private func reloadAfterVariableDiscard(_ origin: VariableAdmission) async {
        let selection = origin.selectedURLs
        guard !isSaving, variableDiscardOwnsCurrentEditor(origin) else { return }
        let selectionKeys = Set(selection.map(Self.variablePhotoKey))
        // Shared template buffers still belong to other retained photos until their own review.
        guard !variableRecoveryPhotos.contains(where: { selectionKeys.contains(Self.variablePhotoKey($0)) }) else { return }
        let loadID = UUID()
        let empty = IPTCMetadata()
        metadataLoadTask?.cancel()
        metadataLoadRequestID = loadID
        isLoading = true
        editingMetadata = empty
        previousEditingMetadata = empty
        hasChanges = false
        selectedHavePendingSidecars = false
        cleanupBaseline = nil
        capturedCaptionWriteExpectation = nil
        sidecarHistory = []
        batchFieldMutations = [:]
        batchLocationsShownMutation = .untouched
        batchImageSupplierMutation = .untouched
        defer { if metadataLoadRequestID == loadID { isLoading = false } }
        do {
            var records: [URL: IPTCMetadata] = [:]
            var inputs: [URL: VariableMetadataInputSnapshot] = [:]
            for url in selection {
                let input = try await loadVariableInput(imageURL: url, folderURL: origin.folderURL)
                inputs[url] = input
                let source: MetadataReferenceSource = selection.count == 1 ? origin.referenceSource
                    : (input.xmpMetadata == nil ? .embedded : .xmp)
                let reference = referenceMetadata(for: source, embedded: input.embeddedMetadata, xmp: input.xmpMetadata, imageURL: url)
                    ?? input.embeddedMetadata
                var displayed = input.baselineSidecar?.pendingChanges == true ? input.baselineSidecar!.metadata : reference
                displayed.cameraRaw = reference.cameraRaw
                displayed.exifOrientation = input.baselineSidecar?.orientationDraft?.targetOrientation ?? reference.exifOrientation
                records[url] = displayed
            }
            guard metadataLoadRequestID == loadID, selectedURLs == selection,
                  currentFolderURL.map(Self.variablePhotoKey) == Self.variablePhotoKey(origin.folderURL), editingMetadata == empty else { return }
            if selection.count == 1, let url = selection.first, let input = inputs[url], let displayed = records[url] {
                embeddedMetadata = input.embeddedMetadata
                xmpMetadata = input.xmpMetadata
                editorXMPWriteBaseline = (url, origin.folderURL, loadID, .init(data: input.evidence.xmpData), nil)
                metadataReferenceSource = origin.referenceSource == .xmp && input.xmpMetadata == nil ? .embedded : origin.referenceSource
                metadata = referenceMetadata(for: metadataReferenceSource, embedded: embeddedMetadata, xmp: xmpMetadata, imageURL: url)
                originalImageMetadata = metadata
                cleanupBaseline = (url, origin.folderURL, input.baselineSidecar)
                sidecarHistory = input.baselineSidecar?.history ?? []
                editingMetadata = displayed
                previousEditingMetadata = displayed
            } else { publishBatchMetadata(selection.compactMap { records[$0] }, metadataByURL: records, isReload: false) }
            selectedHavePendingSidecars = inputs.values.contains { $0.baselineSidecar?.pendingChanges == true }
            hasChanges = selectedHavePendingSidecars
            metadataLoadGeneration += 1
            saveError = nil
        } catch {
            guard metadataLoadRequestID == loadID, selectedURLs == selection, editingMetadata == empty else { return }
            metadata = nil; originalImageMetadata = nil; embeddedMetadata = nil; xmpMetadata = nil
            saveError = "The exported variable requests were discarded, but saved metadata could not be reloaded: \(error.localizedDescription)"
        }
    }

    private func captureVariableAdmission(_ admission: VariableAdmission) async throws -> VariableMetadataWriteRequest? {
        let url = admission.imageURL
        let folder = admission.folderURL
        let selected = admission.selectedURLs
        let edited = admission.edited
        let previous = admission.previous
        let selectedExpectedRecord = admission.expectedRecord
        let selectedSource = admission.referenceSource
        let hasEditorInput = admission.hasEditorInput
        let options = admission.options
        let input: VariableMetadataInputSnapshot
        if let cached = admission.cachedInput { input = cached }
        else {
            input = try await loadVariableInput(imageURL: url, folderURL: folder)
            admission.cachedInput = input
            variableRecoveryGeneration &+= 1
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
                        "The file's metadata changed after you opened it here. Your edits are kept — reload the photo, then try again."])
                }
            }
            // The loaded editor already proved its technical values unchanged.
            // Mask parse identities are not an editorial edit; physical writes
            // preserve the service's current technical record independently.
            original.cameraRaw = edited.cameraRaw
            original.exifOrientation = edited.exifOrientation
            local = edited
        } else if selected.contains(url), let batchInput = admission.batchInput {
            if let captured = admission.batchBaseline {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(captured) == encoder.encode(original) else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
                        "The saved metadata changed after this batch editor was loaded. The template remains in the editor; reconcile before processing variables."])
                }
            }
            Self.applyBatchEdits(batchInput.metadata, to: &local,
                previousCommon: batchInput.previousCommon, batchFieldMutations: batchInput.fields,
                batchLocationsShownMutation: batchInput.locations, batchImageSupplierMutation: batchInput.suppliers,
                keywordsMode: batchInput.keywordsMode, personMode: batchInput.personMode)
        }
        let transcriptDestinations: [MetadataFieldID]
        let transcriptContext: VoiceMemoTranscriptVariableContext?
        if VariableMetadataResolver.requiresVoiceMemoTranscript(local) {
            transcriptDestinations = try VoiceMemoTranscriptVariablePolicy.validateDestinations(in: local)
            transcriptContext = try await voiceMemoTranscriptContextLoader(url)
        } else {
            transcriptDestinations = []
            transcriptContext = nil
        }
        let resolved = try await variableResolver(.init(metadata: local, imageURL: url,
            filename: url.lastPathComponent, sequenceIndex: admission.sequenceIndex,
            options: options, voiceMemoTranscriptContext: transcriptContext))
        try Task.checkCancellation()
        return try VariableMetadataWriteRequest.capture(original: original, resolved: resolved,
            baselineSidecar: input.baselineSidecar, imageURL: url, folderURL: folder,
            requestedMode: options.mode(hasC2PA: input.hasC2PA, imageURL: url),
            creationEvidence: input.evidence, voiceMemoTranscriptContext: transcriptContext,
            voiceMemoTranscriptDestinationFields: transcriptDestinations,
            voiceMemoVariablePreviewAction: admission.previewAction)
    }

    private func startVariableBatch(images: [ImageFile],
                                    retryRequests: [VariableMetadataWriteRequest] = [],
                                    retryAdmissions: [VariableAdmission] = [], retryFolder: URL? = nil,
                                    previewAction: VoiceMemoVariablePreviewAction,
                                    voiceMemoPreviewConfirmed: Bool = false) {
        guard variableRecoveryOwnerID == nil else {
            saveError = "Finish or cancel the variable conflict review before starting or retrying variable processing."
            return
        }
        guard voiceMemoVariablePreview == nil else {
            saveError = "Confirm or cancel the voice-memo transcript preview before starting another variable operation."
            return
        }
        guard let folder = retryFolder ?? currentFolderURL,
              !images.isEmpty || !retryRequests.isEmpty || !retryAdmissions.isEmpty else { return }
        let isRetry = retryFolder != nil
        if !isRetry {
            do {
                // Cancel the metadata panel's focus-loss debounce and synchronously capture its
                // AppKit field buffer before freezing the variable admission.
                try prepareVariableRecoveryPresentation()
                try requireVariableDiscardedEditorReconciled()
            }
            catch { saveError = error.localizedDescription; return }
        }
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
        if selectedCount > 1 { pruneStaleBatchTextIntents() }
        let batchInput: VariableCapturedBatchInput? = selectedCount > 1 && hasEditorInput
            ? .init(metadata: edited, previousCommon: previous, fields: batchFieldMutations,
                locations: batchLocationsShownMutation, suppliers: batchImageSupplierMutation,
                keywordsMode: multiSelectMode(for: "keywords"), personMode: multiSelectMode(for: "personShown")) : nil
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
                VariableAdmission(id: UUID(), imageURL: url, folderURL: folder,
                    editorCheckpoint: selected == [url] ? .init(photoURL: url, folderURL: folder,
                        loadID: loadID, metadata: edited) : nil, loadID: loadID,
                    requiresPersistence: hasUnsavedEditorInput && selected.contains(url),
                    selectedURLs: selected, edited: edited, previous: previous,
                    expectedRecord: selectedExpectedRecord, referenceSource: selectedSource,
                    hasEditorInput: hasEditorInput, batchInput: batchInput,
                    batchBaseline: selectedBatchBaselines[url], options: options, sequenceIndex: index + 1,
                    previewAction: previewAction)
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
        batchProcessScope = (.processVariables, folder)
        folderProcessProgress = "0/\(urls.count)"
        variableBatchOutcome = nil
        variableProcessingStatus = nil
        variableProcessingHadFailures = false
        batchProcessTask?.cancel()
        batchProcessTask = Task {
            defer {
                activeVariableBatchIDs.remove(batchID)
                if activeVariableBatchIDs.isEmpty {
                    let waiters = variableQuiescenceWaiters
                    variableQuiescenceWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                }
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
            // Resolve every source and transcript before the first write. Transcript batches are
            // all-or-nothing at this admission boundary: one missing/stale approval must not
            // leave an earlier photo silently written before the user sees the failure.
            var plannedRequests: [String: VariableMetadataWriteRequest] = [:]
            var planningResults: [String: VariableMetadataPhotoOutcome] = [:]
            var transcriptBatch = false
            for url in urls {
                if Task.isCancelled { break }
                let key = Self.variablePhotoKey(url)
                let explicitRetry = retryRequests.first { Self.variablePhotoKey($0.imageURL) == key }
                let admission = admissions.first { Self.variablePhotoKey($0.imageURL) == key }
                do {
                    let request: VariableMetadataWriteRequest?
                    if let explicitRetry { request = explicitRetry }
                    else if let admission { request = try await captureVariableAdmission(admission) }
                    else { throw VariableConflictRecoveryError.obsoleteReview }
                    if let admission { retainedVariableAdmissions.removeAll { $0.id == admission.id } }
                    guard let request else {
                        planningResults[key] = .init(imageURL: url, unchanged: true)
                        continue
                    }
                    transcriptBatch = transcriptBatch || request.voiceMemoTranscriptContext != nil
                    plannedRequests[key] = request
                    if !retainedVariableWrites.contains(where: { $0.id == request.id }) {
                        retainedVariableWrites.append(request)
                        if let admission { retainedVariableOrigins[request.id] = admission }
                        if let checkpoint = admission?.editorCheckpoint {
                            retainedVariableEditorCheckpoints[request.id] = checkpoint
                        }
                    }
                } catch {
                    if error is VoiceMemoTranscriptVariableError { transcriptBatch = true }
                    planningResults[key] = .init(imageURL: url,
                        failure: error is CancellationError ? nil : error.localizedDescription,
                        wasCancelled: error is CancellationError)
                }
                if batchProcessGeneration == generation {
                    folderProcessProgress = "Preparing \(planningResults.count + plannedRequests.count)/\(urls.count)"
                }
            }

            // Revalidate the entire authority set together before execution. A changed transcript invalidates the complete transcript batch.
            if !Task.isCancelled {
                for request in plannedRequests.values {
                    guard let expected = request.voiceMemoTranscriptContext else { continue }
                    do {
                        let current = try await voiceMemoTranscriptContextLoader(request.imageURL)
                        guard current == expected else { throw VoiceMemoTranscriptVariableError.transcriptChanged }
                    } catch {
                        var failureMessage = error.localizedDescription
                        // A refused, never-prepared transcript request has no durable resolved
                        // values to replay. Retain its original template admission so the next
                        // explicit retry can load the current transcript instead of repeatedly
                        // validating text that transcription has since replaced.
                        if error as? VoiceMemoTranscriptVariableError == .transcriptChanged,
                           !request.hasVerifiedPreparedRecord,
                           !request.replay.receipt.hasCommitted,
                           let origin = retainedVariableOrigins.removeValue(forKey: request.id) {
                            failureMessage += " Use Retry Variable Writes to prepare the original template with the current transcript."
                            retainedVariableWrites.removeAll { $0.id == request.id }
                            retainedVariableEditorCheckpoints.removeValue(forKey: request.id)
                            if !retainedVariableAdmissions.contains(where: { $0.id == origin.id }) {
                                retainedVariableAdmissions.append(origin)
                            }
                        }
                        planningResults[Self.variablePhotoKey(request.imageURL)] = .init(
                            imageURL: request.imageURL,
                            failure: error is CancellationError ? nil : failureMessage,
                            wasCancelled: error is CancellationError
                        )
                    }
                }
            }

            let planningWasCancelled = Task.isCancelled || planningResults.values.contains(where: \.wasCancelled)
            let planningFailures = planningResults.values.filter { !$0.completed }
            if transcriptBatch && (!planningFailures.isEmpty || planningWasCancelled) {
                let refusal = "No metadata was written because every photo in a voice-memo transcript batch must pass validation together."
                var refusedResults: [VariableMetadataPhotoOutcome] = []
                for url in urls {
                    let key = Self.variablePhotoKey(url)
                    if let failure = planningResults[key], !failure.completed {
                        refusedResults.append(failure)
                    } else if plannedRequests[key] != nil {
                        refusedResults.append(.init(imageURL: url, failure: refusal))
                    } else {
                        refusedResults.append(planningResults[key] ?? .init(imageURL: url, unchanged: true))
                    }
                }
                await reconcileVariableDiscardedEditors()
                guard batchProcessGeneration == generation else { return }
                let outcome = VariableMetadataBatchOutcome(requestID: batchID, folderURL: folder,
                    results: refusedResults, unattemptedURLs: [], wasCancelled: planningWasCancelled)
                variableBatchOutcome = outcome
                variableProcessingHadFailures = true
                variableProcessingStatus = "Voice-memo transcript processing refused; 0 photos were written."
                AccessibilityAnnouncementCenter.post(.failure(.voiceMemoTranscriptRefused))
                if metadataLoadRequestID == loadID, selectedURLs == selected, currentFolderURL == folder,
                   editingMetadata == edited { saveError = outcome.attention?.message }
                return
            }

            var results: [VariableMetadataPhotoOutcome] = []
            var acknowledgedBatchMetadata = selectedBatchBaselines
            var acknowledgedPending: [URL: Bool] = [:]
            var cancelled = planningWasCancelled
            for url in urls {
                if Task.isCancelled { cancelled = true; break }
                let key = Self.variablePhotoKey(url)
                if let plannedResult = planningResults[key] {
                    let failureKey = Self.variablePhotoKey(url)
                    if plannedResult.completed { variableFailures.removeValue(forKey: failureKey) }
                    else { variableFailures[failureKey] = plannedResult.failure ?? "Variable persistence did not complete." }
                    results.append(plannedResult)
                    if plannedResult.wasCancelled { cancelled = true; break }
                    continue
                }
                var item = VariableMetadataPhotoOutcome(imageURL: url)
                do {
                    if let request = plannedRequests[key] {
                        if let expected = request.voiceMemoTranscriptContext {
                            let current = try await voiceMemoTranscriptContextLoader(url)
                            guard current == expected else {
                                throw VoiceMemoTranscriptVariableError.transcriptChanged
                            }
                        }
                        let editorCheckpoint = retainedVariableEditorCheckpoints[request.id]
                        let result = if let executor { await executor(request) } else { await service.execute(request) }
                        item.writeResult = result
                        item.wasCancelled = result.wasCancelled
                        if result.completed {
                            retainedVariableWrites.removeAll { $0.id == request.id }
                            retainedVariableEditorCheckpoints.removeValue(forKey: request.id)
                            retainedVariableOrigins.removeValue(forKey: request.id)
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
                            if let physical = result.physicalResult?.resultingPhysicalBaseline {
                                let installedXMP = XMPSidecarWriteSnapshot(data: physical.xmpData)
                                if let loaded = editorXMPWriteBaseline?.snapshot,
                                   (try? Self.sameXMPTechnicalEvidence(loaded, installedXMP)) == true {
                                    editorXMPWriteBaseline = (url, folder, loadID, installedXMP, nil)
                                } else {
                                    let message = "Variable processing preserved newer XMP technical metadata. Reload this photo before another metadata save."
                                    editorXMPWriteBaseline = (url, folder, loadID, nil, message)
                                    saveError = message
                                }
                            }
                            let actualReference = referenceMetadata(for: metadataReferenceSource,
                                embedded: embeddedMetadata, xmp: xmpMetadata, imageURL: url)
                            metadata = actualReference
                            originalImageMetadata = actualReference
                            saveError = editorXMPWriteBaseline?.failure
                        }
                    } else { throw VariableConflictRecoveryError.obsoleteReview }
                } catch {
                    item.wasCancelled = error is CancellationError
                    item.failure = item.wasCancelled ? nil : error.localizedDescription
                }
                let failureKey = Self.variablePhotoKey(url)
                if item.completed { variableFailures.removeValue(forKey: failureKey) }
                else { variableFailures[failureKey] = item.failure ?? item.writeResult?.failure ?? "Variable persistence did not complete." }
                results.append(item)
                if batchProcessGeneration == generation { folderProcessProgress = "\(results.count)/\(urls.count)" }
                if item.wasCancelled || Task.isCancelled { cancelled = true; break }
            }
            await reconcileVariableDiscardedEditors()
            guard batchProcessGeneration == generation else { return }
            let outcome = VariableMetadataBatchOutcome(requestID: batchID, folderURL: folder,
                results: results, unattemptedURLs: Array(urls.dropFirst(results.count)), wasCancelled: cancelled)
            // A retry owns earlier per-photo values, not a newly edited batch buffer.
            // Leave that buffer available for explicit reconciliation/reload.
            if (!isRetry || voiceMemoPreviewConfirmed), selected.count > 1,
               Set(selected).isSubset(of: Set(urls)),
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
            if transcriptBatch {
                AccessibilityAnnouncementCenter.post(
                    outcome.attention == nil
                        ? .success(.voiceMemoTranscriptApplied)
                        : .failure(.voiceMemoTranscriptApplication)
                )
            }
            if metadataLoadRequestID == loadID, selectedURLs == selected, currentFolderURL == folder, editingMetadata == edited {
                saveError = outcome.attention?.message
            }
        }
    }

    /// Re-read metadata from file for the currently displayed image after variable processing,
    /// so the UI reflects the resolved values instead of stale template strings.
    /// Replacing `metadataLoadRequestID` strands an in-flight load: its completion guard no
    /// longer matches, so it would never clear the loading flags (leaving the editor "loading").
    private func supersedeInFlightMetadataLoad() {
        guard let task = metadataLoadTask else { return }
        task.cancel()
        metadataLoadTask = nil
        isLoading = false
        isLoadingBatchMetadata = false
    }

    private func refreshMetadataAfterProcessing(updatedURLs: Set<URL>, processedImages: [ImageFile]) async {
        if selectedCount > 1 {
            let selectionSnapshot = Set(selectedURLs)
            guard !selectionSnapshot.isDisjoint(with: updatedURLs) else { return }
            let selectedProcessedImages = processedImages.filter { selectionSnapshot.contains($0.url) }
            guard Set(selectedProcessedImages.map(\.url)) == selectionSnapshot else { return }

            supersedeInFlightMetadataLoad()
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

        supersedeInFlightMetadataLoad()
        do {
            let requestID = UUID()
            let folderSnapshot = currentFolderURL
            metadataLoadRequestID = requestID
            let sourceBefore = try? await SourceImageRevision.capture(at: url)
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
            let sourceAfter = try? await SourceImageRevision.capture(at: url)
            guard self.metadataLoadRequestID == requestID, !Task.isCancelled else { return }
            if let sourceBefore, let sourceAfter, sourceBefore.canonicalURL == sourceAfter.canonicalURL,
               sourceBefore.sha256 == sourceAfter.sha256 {
                self.primaryDevelopSourceBaseline = (url, requestID, sourceAfter)
            }
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
            self.editorXMPWriteBaseline = (url, folderSnapshot, requestID,
                sourceFacts.xmpWriteSnapshot, sourceFacts.xmpReadFailure)
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

    /// `onComplete` receives this save's own failure, or nil once the draft is durable.
    func saveToSidecar(onComplete: ((String?) -> Void)? = nil) {
        do { try requirePrimaryDevelopWritesPersisted() }
        catch { saveError = error.localizedDescription; onComplete?(saveError); return }
        do { try requireVariableDiscardedEditorReconciled() }
        catch { saveError = error.localizedDescription; onComplete?(saveError); return }
        guard let folderURL = currentFolderURL else {
            onComplete?("No folder is open for this photo's metadata draft.")
            return
        }
        let generation = writeTaskGeneration + 1
        if selectedCount == 1, let imageURL = selectedURLs.first {
            let edited = editingMetadata
            let previous = previousEditingMetadata ?? IPTCMetadata()
            let expectedRecord = currentWriteExpectedRecord
            let technicalReference = xmpMetadata
            let xmpEvidence = editorXMPWriteEvidence(for: imageURL, in: folderURL)
            let loadID = metadataLoadRequestID
            let now = Date()
            let sidecar = MetadataSidecar(sourceFile: imageURL.lastPathComponent,
                lastModified: now, pendingChanges: true, metadata: edited,
                imageMetadataSnapshot: pendingDraftImageMetadataSnapshot,
                history: buildHistory(previous: previous, edited: edited, timestamp: now, existing: sidecarHistory))
            isSaving = true
            saveError = nil
            let priorWrite = priorWriteForSingleSave(imageURL: imageURL, loadID: loadID)
            writeTask = Task {
                defer { if writeTaskGeneration == generation { isSaving = false } }
                await priorWrite?.value
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
                        expectedTechnicalMetadata: technicalReference, expectedXMPSnapshot: try xmpEvidence.get(), allowPendingOrientation: true)
                    let result = await sidecarService.completeSidecarAndMirrorXMP(sidecar, snapshot: snapshot,
                        replaceDevelopSettings: Self.developSettingsChanged(edited.cameraRaw, previous.cameraRaw),
                        replaceOrientation: edited.exifOrientation != previous.exifOrientation)
                    if result.completed, let installed = result.installedSidecar {
                        if matchesSelection() {
                            cleanupBaseline = (imageURL, folderURL, installed)
                            sidecarHistory = installed.history
                            xmpMetadata = result.writtenXMPMetadata ?? edited
                            editorXMPWriteBaseline = (imageURL, folderURL, loadID, result.writtenXMPSnapshot, nil)
                            editingMetadata.cameraRaw = PhotoSidecarOwnership.stemSidecarDevelopBelongsToRawSibling(of: imageURL)
                                ? edited.cameraRaw : xmpMetadata?.cameraRaw
                            editingMetadata.exifOrientation = xmpMetadata?.exifOrientation
                            previousEditingMetadata = editingMetadata
                            hasChanges = true
                            selectedHavePendingSidecars = true
                        }
                        onComplete?(nil)
                    } else {
                        let message = Self.writeCompletionFailure(result, imageWasWritten: false)
                        if matchesSelection() { saveError = message }
                        onComplete?(message)
                    }
                } catch {
                    let message = "Couldn't save changes to \(imageURL.lastPathComponent). \(UserFacingErrorCause.sentence(for: error)) Try again."
                    if matchesSelection() { saveError = message }
                    onComplete?(message)
                }
            }
            registerSingleSave(imageURL: imageURL, loadID: loadID)
        } else if selectedCount > 1 {
            // Capture now and wait for an earlier write instead of cancelling it partway through
            // its selection; this save still applies to the photos selected when it was requested.
            // Its own task keeps it out of reach of a later `writeTask?.cancel()`.
            let capture = captureBatchSidecars()
            let priorWrite = writeTask
            isSaving = true
            let batchTracking = beginBatchWriteTracking(capture.urls)
            let write = Task {
                defer { endBatchWriteTracking(batchTracking) }
                await priorWrite?.value
                let failure = await saveBatchSidecars(folderURL: folderURL, pendingChanges: true,
                    updateState: true, capture: capture)
                if writeTaskGeneration == generation { isSaving = false }
                onComplete?(failure)
            }
            writeTask = Task { await write.value }
        } else {
            onComplete?(nil)
        }
    }

    /// Captures the current single-image Caption draft for serialized off-main persistence.
    ///
    /// The selection can change as soon as this returns: every value needed by the write is owned
    /// by the returned request. History state advances optimistically so rapid navigation back to
    /// the same image cannot manufacture duplicate edits; the queue retains and retries a failed
    /// request at the next durable barrier.
    func captureCaptionDraftPersistence() throws -> CaptionDraftPersistence? {
        try requirePrimaryDevelopWritesPersisted()
        try requireVariableDiscardedEditorReconciled()
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

    /// The batch editor state a sidecar save applies, captured when the save is requested so a
    /// save that waits behind an earlier write still applies this selection's edits.
    private struct BatchSidecarCapture {
        let urls: [URL]
        let selectedAtStart: [URL]
        let baselines: [URL: IPTCMetadata]
        let savedEditing: IPTCMetadata
        let savedFieldMutations: [MetadataFieldID: MetadataFieldMutation]
        let savedLocationsShownMutation: BatchLocationsShownMutation
        let savedImageSupplierMutation: EditorialImageSupplierMutation
        let mutation: BatchRecordMutation
        let overridesSuppliers: Bool
    }

    private func captureBatchSidecars(
        targetURLs: [URL]? = nil,
        capturedMutation: (mutation: BatchRecordMutation, overridesSuppliers: Bool)? = nil
    ) -> BatchSidecarCapture {
        pruneStaleBatchTextIntents()
        return BatchSidecarCapture(
            urls: targetURLs ?? selectedURLs,
            selectedAtStart: selectedURLs,
            baselines: batchMetadataByURL,
            savedEditing: editingMetadata,
            savedFieldMutations: batchFieldMutations,
            savedLocationsShownMutation: batchLocationsShownMutation,
            savedImageSupplierMutation: batchImageSupplierMutation,
            mutation: capturedMutation?.mutation ?? capturedBatchMutation(),
            overridesSuppliers: capturedMutation?.overridesSuppliers ?? (batchImageSupplierMutation != .untouched)
        )
    }

    private func saveBatchSidecars(
        folderURL: URL,
        pendingChanges: Bool = true,
        targetURLs: [URL]? = nil,
        updateState: Bool = true,
        capturedMutation: (mutation: BatchRecordMutation, overridesSuppliers: Bool)? = nil
    ) async {
        _ = await saveBatchSidecars(
            folderURL: folderURL,
            pendingChanges: pendingChanges,
            updateState: updateState,
            capture: captureBatchSidecars(targetURLs: targetURLs, capturedMutation: capturedMutation)
        )
    }

    /// Returns this save's first failure (also published as `saveError`).
    @discardableResult
    private func saveBatchSidecars(
        folderURL: URL,
        pendingChanges: Bool,
        updateState: Bool,
        capture: BatchSidecarCapture
    ) async -> String? {
        let now = Date()
        let mutation = capture.mutation
        let overridesSuppliers = capture.overridesSuppliers
        let urls = capture.urls
        let selectedAtStart = capture.selectedAtStart
        let baselines = capture.baselines
        let savedEditing = capture.savedEditing
        let savedFieldMutations = capture.savedFieldMutations
        let savedLocationsShownMutation = capture.savedLocationsShownMutation
        let savedImageSupplierMutation = capture.savedImageSupplierMutation
        var allSaved = true
        var failure: String?

        for imageURL in urls {
            guard !Task.isCancelled else { return failure }
            do {
                let installed = try await sidecarService.updateMetadataSerialized(
                    for: imageURL,
                    in: folderURL,
                    fallback: baselines[imageURL] ?? IPTCMetadata(),
                    pendingChanges: pendingChanges,
                    timestamp: now,
                    mutation: mutation.closure(for: imageURL, channel: .jsonDraft)
                )
                mutation.markDelivered(to: imageURL, channel: .jsonDraft)
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
                    // The .xmp now carries the complete record, appended text included.
                    mutation.markDelivered(to: imageURL, channel: .xmpSidecar)
                }
            } catch {
                allSaved = false
                saveError = "Couldn't save changes to \(imageURL.lastPathComponent). \(UserFacingErrorCause.sentence(for: error)) Try again."
                failure = failure ?? saveError
            }
        }

        if updateState, allSaved, selectedURLs == selectedAtStart {
            // The saved state is the new baseline for later add/remove diffs and list operations.
            previousEditingMetadata = savedEditing
            batchCommonMetadata = savedEditing
            reconcileBatchPartials(afterSaving: savedEditing)
            clearSavedBatchFieldMutations(savedFieldMutations)
            if batchLocationsShownMutation == savedLocationsShownMutation {
                batchLocationsShownMutation = .untouched
            }
            if batchImageSupplierMutation == savedImageSupplierMutation {
                batchImageSupplierMutation = .untouched
            }
        }
        // A failed photo keeps the editor's unsaved state so the edit is not reported as saved.
        if updateState, allSaved, selectedURLs == selectedAtStart {
            hasChanges = pendingChanges
            if !pendingChanges {
                selectedHavePendingSidecars = false
            }
        }
        return failure
    }

    private func capturedBatchMutation() -> BatchRecordMutation {
        pruneStaleBatchTextIntents()
        return BatchRecordMutation(
            batchMeta: editingMetadata,
            previousCommon: previousEditingMetadata,
            fields: batchFieldMutations,
            appendTokens: batchTextAppendTokens,
            locations: batchLocationsShownMutation,
            suppliers: batchImageSupplierMutation,
            keywordsMode: multiSelectMode(for: "keywords"),
            personMode: multiSelectMode(for: "personShown"),
            ledger: textAppendLedger
        )
    }

    /// After a save, drops each intent it saved that is still unchanged, key by key. Clearing
    /// only when the whole set matched left a saved `.appendText` in place whenever anything
    /// else was edited during the save, and the next save appended it again. An append the
    /// user extended meanwhile stays; the ledger knows which part each photo already has.
    private func clearSavedBatchFieldMutations(_ saved: [MetadataFieldID: MetadataFieldMutation]) {
        for (field, mutation) in saved where batchFieldMutations[field] == mutation {
            batchFieldMutations.removeValue(forKey: field)
            batchTextIntentEditorValues.removeValue(forKey: field)
            batchTextAppendTokens.removeValue(forKey: field)
        }
    }

    /// Batch scalar intent (Photo Mechanic semantics): a non-empty value overwrites every
    /// selected photo, and emptying a value that was common to the selection explicitly clears
    /// it. An empty field that was already empty or mixed leaves each photo untouched.
    nonisolated static func batchScalarWriteValue(_ edited: String?, previous: String?) -> String? {
        if let edited, !edited.isEmpty { return edited }
        if let previous, !previous.isEmpty { return "" }
        return nil
    }

    private nonisolated static func applyBatchScalar(_ edited: String?, previous: String?, to value: inout String?) {
        guard let write = batchScalarWriteValue(edited, previous: previous) else { return }
        value = write.isEmpty ? nil : write
    }

    nonisolated static func applyBatchEdits(
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
        // Explicit template text intent (append/replace/clear) applies to each photo's own value.
        guard let textMutated = try? Self.applyingBatchTextMutations(batchFieldMutations, to: metadata) else { return }
        metadata = textMutated
        func scalar(_ field: MetadataFieldID, _ path: WritableKeyPath<IPTCMetadata, String?>) {
            guard batchFieldMutations[field] == nil else { return }
            applyBatchScalar(batchMeta[keyPath: path], previous: previousCommon?[keyPath: path], to: &metadata[keyPath: path])
        }

        scalar(.headline, \.title)
        scalar(.description, \.description)
        scalar(.extendedDescription, \.extendedDescription)

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

        scalar(.copyright, \.copyright)
        scalar(.rightsUsageTerms, \.rightsUsageTerms)
        scalar(.webStatementOfRights, \.webStatementOfRights)
        scalar(.digitalImageGUID, \.digitalImageGUID)
        scalar(.imageSupplierImageID, \.imageSupplierImageID)
        scalar(.jobId, \.jobId)
        if let dateCreated = batchMeta.dateCreated, !dateCreated.isEmpty {
            if (try? EditorialDateCreated(parsing: dateCreated)) != nil {
                metadata.dateCreated = dateCreated
            }
        } else if let previous = previousCommon?.dateCreated, !previous.isEmpty {
            // Emptying a date every photo shared clears it, like every other batch scalar.
            metadata.dateCreated = nil
        }
        if batchFieldMutations[.creator] == nil, !batchMeta.creators.isEmpty {
            metadata.creators = batchMeta.creators
        }
        scalar(.creatorJobTitle, \.creatorJobTitle)
        scalar(.descriptionWriter, \.descriptionWriter)
        scalar(.credit, \.credit)
        scalar(.city, \.city)
        scalar(.sublocation, \.sublocation)
        scalar(.provinceState, \.provinceState)
        scalar(.country, \.country)
        scalar(.countryCode, \.countryCode)
        scalar(.event, \.event)
        scalar(.instructions, \.instructions)
        scalar(.source, \.source)
        // Clearing a value common to the selection clears it everywhere; a value that was
        // already empty or mixed leaves each photo's own value untouched.
        if batchMeta.digitalSourceType != nil {
            metadata.digitalSourceType = batchMeta.digitalSourceType
        } else if previousCommon?.digitalSourceType != nil {
            metadata.digitalSourceType = nil
        }
        if batchMeta.urgency != nil {
            metadata.urgency = batchMeta.urgency
        } else if previousCommon?.urgency != nil {
            metadata.urgency = nil
        }

        // GPS — apply only when both coordinates are set, mirroring the batch
        // file-write path in writeMetadata(). When GPS differs across the
        // selection and the user hasn't picked a location, the common
        // coordinates are nil, so each image's existing GPS is preserved.
        // Clearing coordinates every photo shared removes them from all.
        if let lat = batchMeta.latitude, let lon = batchMeta.longitude {
            metadata.latitude = lat
            metadata.longitude = lon
        } else if batchClearsGPS(edited: batchMeta, previous: previousCommon) {
            metadata.latitude = nil
            metadata.longitude = nil
        }
    }

    /// The Clear button empties both coordinates. Only a location the whole selection shared
    /// is cleared; mixed GPS has no common value and stays untouched.
    nonisolated static func batchClearsGPS(edited: IPTCMetadata, previous: IPTCMetadata?) -> Bool {
        edited.latitude == nil && edited.longitude == nil
            && previous?.latitude != nil && previous?.longitude != nil
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
        do { try requirePrimaryDevelopWritesPersisted() }
        catch { saveError = error.localizedDescription; return }
        do { try requireVariableDiscardedEditorReconciled() }
        catch { saveError = error.localizedDescription; return }
        guard selectedCount == 1,
              let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else {
            let urls = selectedURLs
            let folderURL = currentFolderURL
            let hadPendingDrafts = selectedHavePendingSidecars
            writeMetadata()
            // The batch write folds its change into each pending draft; writing those drafts
            // completes them, matching the single-photo Write (which writes and clears its draft).
            guard hadPendingDrafts, let folderURL else { return }
            let batchWrite = writeTask
            Task { @MainActor in
                await batchWrite?.value
                guard saveError == nil, currentFolderURL == folderURL else { return }
                // The caller confirmed the C2PA warning before an explicit Write.
                writeAllPendingChanges(in: folderURL, images: [], skipC2PA: false, limitedTo: urls)
            }
            return
        }

        isSaving = true
        saveError = nil

        let edited = editingMetadata
        let original = originalImageMetadata
        let loadID = metadataLoadRequestID
        let editorRecord = currentWriteExpectedRecord
        let priorXMPEvidence = editorXMPWriteEvidence(for: imageURL, in: folderURL)
        let generation = writeTaskGeneration + 1
        let captureKey = imageURL.resolvingSymlinksInPath().path.lowercased()
        let cleanupKey = MetadataIOKey.key(for: imageURL)
        let capturedGeneration = captionCaptureGenerations[captureKey, default: 0]
        let priorWrite = priorWriteForSingleSave(imageURL: imageURL, loadID: loadID)
        writeTask = Task {
            defer { if writeTaskGeneration == generation { isSaving = false } }
            await priorWrite?.value
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
                        listValues: EditorialListWriteData(metadata: edited),
                        replaceCameraRawBlock: true
                    )
                    : StructuredWriteData(editorial: EditorialStructuredWriteData(metadata: edited),
                                          listValues: EditorialListWriteData(metadata: edited))
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
                        saveError = "Metadata was saved. Newer caption edits you made meanwhile are kept and not saved yet."
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
                    self.saveError = "Metadata was saved. Newer edits you made meanwhile are kept and not saved yet."
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
                // A RAW write lands in the .xmp; the bytes this write installed are the evidence
                // the next save in this editor is checked against.
                self.editorXMPWriteBaseline = (imageURL, folderURL, loadID,
                    wroteToRawSidecar ? descriptiveWriteBoundary.xmpSnapshot(for: imageURL) : (try? priorXMPEvidence.get()),
                    nil)
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
        registerSingleSave(imageURL: imageURL, loadID: loadID)
    }

    /// Paste IPTC writes the file (or its XMP), but a pending draft stays the photo's record until
    /// Write All. Merge the pasted values into each pending draft too (keeping it pending), so a
    /// later Write All cannot revert the paste. Photos without a pending draft are untouched.
    func applyPastedIPTCToPendingDrafts(_ copied: IPTCMetadata, urls: [URL], in folderURL: URL) async {
        guard !urls.isEmpty else { return }
        let pendingNames = Set(await sidecarService.imagesWithPendingChanges(in: folderURL).map(\.lastPathComponent))
        var pasted = copied
        pasted.cameraRaw = nil
        pasted.exifOrientation = nil
        let record = pasted
        for url in urls where pendingNames.contains(url.lastPathComponent) {
            do {
                _ = try await sidecarService.updateMetadataSerialized(
                    for: url, in: folderURL, fallback: IPTCMetadata(), pendingChanges: true,
                    mutation: { $0 = $0.merged(preferring: record) }
                )
            } catch {
                saveError = "IPTC was pasted, but the pending draft for \(url.lastPathComponent) could not be updated: \(error.localizedDescription)"
            }
        }
    }

    func writeAllPendingChanges(in folderURL: URL?, images: [ImageFile], skipC2PA: Bool = true,
                                limitedTo photoURLs: [URL]? = nil) {
        guard let folderURL else { return }
        let limitedNames = photoURLs.map { Set($0.map(\.lastPathComponent)) }
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
        batchProcessScope = (.writeAllPending, folderURL)
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
            let records = discovered.records
                .filter { limitedNames?.contains($0.key.lastPathComponent) ?? true }
                .sorted { $0.key.path < $1.key.path }
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

    func fieldDiffers<Value: Equatable>(_ keyPath: KeyPath<IPTCMetadata, Value>) -> Bool {
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
                saveError = "Couldn't discard the app's saved edits in \(folderURL.lastPathComponent). \(UserFacingErrorCause.sentence(for: error)) Try again."
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
        // Queue behind any running write instead of cancelling it partway through.
        let priorWrite = writeTask
        writeTask = Task {
            await priorWrite?.value
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
                saveError = "Couldn't save changes to \(imageURL.lastPathComponent). \(UserFacingErrorCause.sentence(for: error)) Try again."
            }
        }
    }

    private func editorXMPWriteEvidence(for imageURL: URL, in folderURL: URL) -> Result<XMPSidecarWriteSnapshot, any Error> {
        if let captured = capturedCaptionWriteExpectation,
           captured.loadID == metadataLoadRequestID, captured.request.imageURL == imageURL,
           captured.request.folderURL == folderURL, selectedURLs == [imageURL],
           let snapshot = captured.request.receipt.verifiedXMPSnapshot {
            // Caption mirrors may preserve an independent Develop edit made after this editor
            // loaded. Its verified bytes are usable only if the technical reference is still
            // the one from which the user's current editor was derived.
            guard let baseline = editorXMPWriteBaseline, baseline.imageURL == imageURL,
                  baseline.folderURL == folderURL, baseline.loadID == metadataLoadRequestID,
                  let loaded = baseline.snapshot,
                  (try? Self.sameXMPTechnicalEvidence(loaded, snapshot)) == true else {
                return .failure(CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
                    "The XMP technical metadata changed while Caption was saving. Reload this photo before changing or saving Develop settings."]))
            }
            return .success(snapshot)
        }
        if let baseline = editorXMPWriteBaseline, baseline.imageURL == imageURL,
           baseline.folderURL == folderURL, baseline.loadID == metadataLoadRequestID,
           let snapshot = baseline.snapshot { return .success(snapshot) }
        return .failure(CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
            editorXMPWriteBaseline?.failure
                ?? "The editor's XMP revision could not be verified. Reload this photo before saving."]))
    }

    private nonisolated static func sameXMPTechnicalEvidence(_ lhs: XMPSidecarWriteSnapshot, _ rhs: XMPSidecarWriteSnapshot) throws -> Bool {
        if lhs == rhs { return true }
        func properties(_ snapshot: XMPSidecarWriteSnapshot) throws -> [String: XMPValue] {
            let xmp = try snapshot.data.map { try XMPReader.readFromXML($0) } ?? XMPData()
            var values: [String: XMPValue] = [:]
            for namespace in [XMPNamespace.crs, XMPDataBuilder.aaphotoNamespace] {
                for (name, value) in xmp.properties(in: namespace) {
                    if namespace == XMPDataBuilder.aaphotoNamespace && name == "LocalizedTitleCleared" { continue }
                    values[namespace + name] = value
                }
            }
            for namespace in [XMPNamespace.tiff, XMPNamespace.exif] {
                values[namespace + "Orientation"] = xmp.value(namespace: namespace, property: "Orientation")
            }
            return values
        }
        return try properties(lhs) == properties(rhs)
    }

    private var currentWriteExpectedRecord: MetadataSidecar? {
        if let captured = capturedCaptionWriteExpectation,
           captured.loadID == metadataLoadRequestID,
           selectedURLs == [captured.request.imageURL],
           currentFolderURL == captured.request.folderURL {
            // The durable Caption barrier may complete inline before MainActor callbacks can run.
            // Accept only this exact captured revision; a replay rebased onto newer data must reload.
            if let installed = captured.request.receipt.verifiedSidecar {
                var intended = captured.request.sidecar
                intended.lastModified = installed.lastModified
                // Accept timestamp canonicalization only. A replay that incorporated other
                // editorial changes still requires reconciliation with the visible editor.
                if (try? Self.sameVariableRecord(intended, installed)) == true { return installed }
            }
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

    enum HistoryRestoreTarget {
        case original
        case point(MetadataHistoryEntry)
    }

    /// Reserve before scheduling, then await captured drafts without blocking the editor actor.
    /// A history point is retained by value because replay can trim or replace history while waiting.
    func prepareHistoryRestore(
        _ target: HistoryRestoreTarget,
        coordinator: CaptionWorkspaceFlushCoordinator,
        hasLiveCaptionEditor: Bool,
        captureEditor: @escaping @MainActor () throws -> Void
    ) -> Task<Void, Never>? {
        let token: UUID
        do { token = try coordinator.reserveTransition() }
        catch { return nil }
        let loadID = metadataLoadRequestID
        let urls = selectedURLs
        let folder = currentFolderURL
        return Task { @MainActor in
            let isCurrent = {
                self.metadataLoadRequestID == loadID && self.selectedURLs == urls && self.currentFolderURL == folder
            }
            var restore: Task<Void, Never>?
            do {
                try await coordinator.performReservedTransition(token, flush: {
                    guard isCurrent() else { throw CancellationError() }
                    try captureEditor()
                    if hasLiveCaptionEditor { try await coordinator.flushAsync() }
                    else { try await coordinator.flushQueuedPersistenceAsync() }
                }, operation: {
                    guard isCurrent() else { return }
                    switch target {
                    case .original:
                        restore = self.restoreToOriginal()
                    case .point(let point):
                        guard let index = self.sidecarHistory.firstIndex(of: point) else {
                            self.saveError = "This history point is no longer available. Reload the photo and choose another point."
                            return
                        }
                        restore = self.restoreToHistoryPoint(at: index)
                    }
                })
                // Once admitted, the model's transactional restore owns its durable completion.
                await restore?.value
            } catch is CancellationError {
                // Captured writes retain their completion; the delayed restore is abandoned.
            } catch {
                if isCurrent() {
                    self.saveError = "Finish saving the Caption draft before restoring history: \(error.localizedDescription)"
                }
            }
        }
    }

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
            saveError = "This history point is no longer available. Reload the photo and choose another point."
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
        let restoreXMP: XMPSidecarWriteSnapshot
        do { restoreXMP = try editorXMPWriteEvidence(for: imageURL, in: folderURL).get() }
        catch { saveError = error.localizedDescription; return nil }
        let request = MetadataSidecarRestoreRequest(sidecar: replacement, expectedSidecar: record,
            expectedXMPMetadata: xmpMetadata, imageURL: imageURL, folderURL: folderURL,
            expectedXMPSnapshot: restoreXMP)
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
                    editorXMPWriteBaseline = (imageURL, folderURL, loadID, result.writtenXMPSnapshot, nil)
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
                    saveError = "The earlier version was restored, but the app's saved edits for \(path.lastPathComponent.replacingOccurrences(of: ".meta.json", with: "")) couldn't be checked. \(result.failure?.message ?? "The restore was cancelled.") Reload the folder before doing anything else with this photo."
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

/// Batch scalar text fields keyed by the editor's field name (the `batchPlaceholder` key).
nonisolated enum MetadataEditorFieldPaths {
    static func scalarText(for key: String) -> WritableKeyPath<IPTCMetadata, String?>? {
        switch key {
        case "title": \.title
        case "description": \.description
        case "extendedDescription": \.extendedDescription
        case "copyright": \.copyright
        case "rightsUsageTerms": \.rightsUsageTerms
        case "webStatementOfRights": \.webStatementOfRights
        case "digitalImageGUID": \.digitalImageGUID
        case "imageSupplierImageID": \.imageSupplierImageID
        case "jobId": \.jobId
        case "dateCreated": \.dateCreated
        case "creatorJobTitle": \.creatorJobTitle
        case "descriptionWriter": \.descriptionWriter
        case "credit": \.credit
        case "source": \.source
        case "city": \.city
        case "sublocation": \.sublocation
        case "provinceState": \.provinceState
        case "country": \.country
        case "countryCode": \.countryCode
        case "event": \.event
        case "instructions": \.instructions
        default: nil
        }
    }
}


/// Which record of a photo a batch mutation is being applied to.
nonisolated enum BatchRecordChannel: Hashable, Sendable {
    /// The image file itself (embedded IPTC/XMP).
    case embedded
    /// The photo's `.xmp` sidecar.
    case xmpSidecar
    /// The app's JSON metadata draft.
    case jsonDraft
}

/// Remembers which template text appends each record of each photo already received, keyed by
/// the intent's token. Appending is the one batch operation that is not idempotent, so every
/// path that applies a captured mutation consults this when it applies it, not when the save was
/// requested: a dual-write XMP phase after the embedded phase (which already wrote RAW sidecars
/// and mirrored existing ones), a save queued behind a slow one, and a retry after a partial
/// failure each append only what that record still lacks.
nonisolated final class BatchTextAppendLedger: @unchecked Sendable {
    private struct Key: Hashable {
        let url: URL
        let field: MetadataFieldID
        let channel: BatchRecordChannel
    }

    private let lock = NSLock()
    private var delivered: [Key: (token: UUID, text: String)] = [:]

    func effective(
        _ fields: [MetadataFieldID: MetadataFieldMutation],
        tokens: [MetadataFieldID: UUID],
        url: URL,
        channel: BatchRecordChannel
    ) -> [MetadataFieldID: MetadataFieldMutation] {
        lock.withLock {
            var result = fields
            for (field, mutation) in fields {
                guard case .appendText(let text) = mutation, let token = tokens[field],
                      let done = delivered[Key(url: url.standardizedFileURL, field: field, channel: channel)],
                      done.token == token else { continue }
                if text == done.text {
                    result.removeValue(forKey: field)
                } else if text.hasPrefix(done.text + " ") {
                    result[field] = .appendText(String(text.dropFirst(done.text.count + 1)))
                }
            }
            return result
        }
    }

    func markDelivered(
        _ fields: [MetadataFieldID: MetadataFieldMutation],
        tokens: [MetadataFieldID: UUID],
        url: URL,
        channel: BatchRecordChannel
    ) {
        lock.withLock {
            // Entries are tiny and keyed by one-off tokens; bound growth over a long session.
            if delivered.count > 20_000 { delivered.removeAll() }
            for (field, mutation) in fields {
                guard case .appendText(let text) = mutation, let token = tokens[field] else { continue }
                delivered[Key(url: url.standardizedFileURL, field: field, channel: channel)] = (token, text)
            }
        }
    }
}

/// A batch editor change captured when a save is requested, applied per photo and per record.
nonisolated struct BatchRecordMutation: Sendable {
    let batchMeta: IPTCMetadata
    let previousCommon: IPTCMetadata?
    let fields: [MetadataFieldID: MetadataFieldMutation]
    let appendTokens: [MetadataFieldID: UUID]
    let locations: BatchLocationsShownMutation
    let suppliers: EditorialImageSupplierMutation
    let keywordsMode: MultiSelectFieldMode
    let personMode: MultiSelectFieldMode
    let ledger: BatchTextAppendLedger

    /// Applies the change to one record, appending only text that record has not received yet.
    func apply(to metadata: inout IPTCMetadata, url: URL, channel: BatchRecordChannel) {
        apply(to: &metadata, fields: ledger.effective(fields, tokens: appendTokens, url: url, channel: channel))
    }

    /// The full change, for computing a baseline that starts from a pre-save snapshot.
    func applyIgnoringDeliveries(to metadata: inout IPTCMetadata) {
        apply(to: &metadata, fields: fields)
    }

    func closure(for url: URL, channel: BatchRecordChannel) -> @Sendable (inout IPTCMetadata) -> Void {
        { metadata in self.apply(to: &metadata, url: url, channel: channel) }
    }

    /// The embedded write for one photo's appends and fills, from that photo's own record.
    func embeddedPerRecordWrite(
        for url: URL, base: IPTCMetadata
    ) -> (fields: [MetadataFieldKey: String], listValues: EditorialListWriteData) {
        MetadataViewModel.perPhotoBatchWrite(
            ledger.effective(fields, tokens: appendTokens, url: url, channel: .embedded), base: base
        )
    }

    func markDelivered(to url: URL, channel: BatchRecordChannel) {
        ledger.markDelivered(fields, tokens: appendTokens, url: url, channel: channel)
    }

    private func apply(to metadata: inout IPTCMetadata, fields: [MetadataFieldID: MetadataFieldMutation]) {
        MetadataViewModel.applyBatchEdits(
            batchMeta, to: &metadata, previousCommon: previousCommon,
            batchFieldMutations: fields, batchLocationsShownMutation: locations,
            batchImageSupplierMutation: suppliers,
            keywordsMode: keywordsMode, personMode: personMode
        )
    }
}
