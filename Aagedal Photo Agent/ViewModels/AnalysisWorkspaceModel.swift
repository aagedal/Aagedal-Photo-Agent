import CoreGraphics
import Foundation

struct AnalysisImageMapAnnotation: Identifiable, Sendable {
    let caseID: UUID
    let sourceURL: URL
    let sourceName: String
    let annotation: AnalysisMapAnnotation

    var id: String { "\(caseID.uuidString)-\(annotation.id.uuidString)" }
}

/// Leaving the current case that would discard edits whose save failed.
enum AnalysisUnsavedChangesExit {
    case openImage(ImageFile, preferredWorkspaceMode: AnalysisWorkspaceMode?)
    case close
}

enum AnalysisRenameQuiescenceError: LocalizedError, Equatable {
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .persistenceFailed(let detail):
            "Analysis changes could not be made durable before rename: \(detail)"
        }
    }
}

@Observable
final class AnalysisWorkspaceModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle
    /// A failed background save keeps the in-memory case editable; the workspace offers
    /// Retry Save, which re-persists the current in-memory documents.
    private(set) var saveError: String?
    /// Navigation or close requested while `saveError` is set; the workspace asks first.
    private(set) var pendingUnsavedChangesExit: AnalysisUnsavedChangesExit?
    private(set) var analysisCase: AnalysisCase? {
        didSet { rebuildPhotoAnnotationCaseIndex() }
    }
    private(set) var currentRevision: SourceImageRevision?
    private(set) var sourceChanged = false
    private(set) var sourceURL: URL? {
        didSet { rebuildPhotoAnnotationCaseIndex() }
    }
    private(set) var hasDevelopedRepresentation = false
    private(set) var developSettings: CameraRawSettings?
    private(set) var sourceOrientation = 1
    private(set) var folderAnalysisCases: [AnalysisCase] = [] {
        didSet { rebuildPhotoAnnotationCaseIndex() }
    }
    private(set) var folderMapDocument = AnalysisFolderMapDocument.create()
    private(set) var caseStorage: AnalysisCaseStorage?
    private(set) var folderMapStorage: AnalysisCaseStorage?
    let analysisRunner: AnalysisRunner

    @ObservationIgnored private var repository: AnalysisCaseRepository?
    @ObservationIgnored private var openedImage: ImageFile?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Tail of the chained case-save queue. Saves are never cancelled: each waits for the one
    /// before it, so an older snapshot can never land on disk after a newer one.
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var folderMapSaveTask: Task<Void, Never>?
    @ObservationIgnored private var saveSequence = 0
    /// Newest queued save per case/folder-map document ID; superseded snapshots skip their write.
    @ObservationIgnored private var latestCaseSaveSequence: [UUID: Int] = [:]
    @ObservationIgnored private var latestFolderMapSaveSequence: [UUID: Int] = [:]
    /// A workspace switch requested from outside Analysis that waits on the unsaved-changes prompt.
    @ObservationIgnored private var pendingExternalCloseTransition: (@MainActor () -> Void)?
    @ObservationIgnored private var workspaceGeneration = UUID()
    @ObservationIgnored private var renameQuiescenceFolderURL: URL?
    @ObservationIgnored private var renameQuiescenceNeedsCaseSave = false
    /// Messages of the open case's and the folder map's failed saves; nil when durable.
    @ObservationIgnored private var caseSaveFailure: String?
    @ObservationIgnored private var folderMapSaveFailure: String?
    /// Saves of a previously open photo's case that failed after the workspace moved on. They are
    /// reported through `saveError`, retried by Retry Save, adopted when that photo is reopened,
    /// and dropped only by Discard (or a failed-rename reset).
    @ObservationIgnored private var failedBackgroundCaseSaves: [UUID: BackgroundCaseSaveFailure] = [:]
    /// Changes whenever an unsaved-changes exit is requested or cancelled, so a slow Retry Save
    /// cannot perform an exit the user has since replaced or abandoned.
    @ObservationIgnored private var unsavedExitRequestID = UUID()

    private struct BackgroundCaseSaveFailure {
        let analysisCase: AnalysisCase
        let repository: AnalysisCaseRepository
        let message: String
    }
    @ObservationIgnored private let analyzers: [any AnalysisAnalyzer]
    @ObservationIgnored private let repositoryFactory: (URL) async throws -> AnalysisCaseRepository
    private var photoAnnotationHistory = AnalysisAnnotationUndoHistory()
    private var mapAnnotationHistory = AnalysisMapAnnotationUndoHistory()
    private var globalMapAnnotationHistory = AnalysisGlobalMapAnnotationUndoHistory()
    private var photoAnnotationCasesByPresentedURL: [URL: AnalysisCase] = [:]

    init(
        analyzers: [any AnalysisAnalyzer]? = nil,
        repositoryFactory: ((URL) async throws -> AnalysisCaseRepository)? = nil
    ) {
        analysisRunner = AnalysisRunner()
        self.analyzers = analyzers ?? [SourceFactsAnalyzer()]
        self.repositoryFactory = repositoryFactory ?? {
            try await AnalysisCaseRepository.open(sourceFolderURL: $0)
        }
        analysisRunner.onPersistableRunChanged = { [weak self] run in
            self?.persistAnalyzerRun(run)
        }
    }

    private var sessionWorkspaceMode: AnalysisWorkspaceMode?

    var workspaceMode: AnalysisWorkspaceMode {
        sessionWorkspaceMode ?? analysisCase?.workspaceMode ?? .pixelAnalysis
    }

    var displayPreference: AnalysisSourceRepresentation {
        guard hasDevelopedRepresentation else { return .original }
        return analysisCase?.displayPreference ?? .original
    }

    var storagePortabilityWarning: String? {
        if caseStorage == .applicationSupport || folderMapStorage == .applicationSupport {
            return AnalysisCaseStorage.applicationSupport.portabilityWarning
        }
        return nil
    }

    var sourceFactsRun: AnalysisAnalyzerRun? {
        analysisRunner.runs.first { $0.analyzerID == SourceFactsAnalyzer.analyzerIdentifier }
    }

    var sourceFacts: AnalysisSourceFacts? {
        sourceFactsRun?.output?.sourceFacts
    }

    var findings: [AnalysisFinding] {
        analysisRunner.runs
            .flatMap { $0.output?.findings ?? [] }
            .sorted {
                if $0.severity != $1.severity {
                    return Self.severityRank($0.severity) > Self.severityRank($1.severity)
                }
                return $0.title < $1.title
            }
    }

    var annotations: [AnalysisAnnotation] {
        analysisCase?.annotations ?? []
    }

    var counterEvidence: [AnalysisCounterEvidence] {
        AnalysisCounterEvidence.summaries(for: annotations)
    }

    func photoAnnotations(for image: ImageFile) -> [AnalysisAnnotation] {
        photoAnnotationCasesByPresentedURL[image.url.standardizedFileURL]?.annotations ?? []
    }

    func pastePhotoAnnotations(
        _ sourceAnnotations: [AnalysisAnnotation],
        to image: ImageFile
    ) async throws {
        guard !sourceAnnotations.isEmpty else { return }
        // Opening another photo while this paste is in flight must not let its result replace the
        // newly opened case, its storage state, or its undo history.
        let generation = workspaceGeneration

        let targetRevision = try await SourceImageRevision.capture(
            at: image.url,
            exifOrientation: image.exifOrientation
        )
        let targetRepository: AnalysisCaseRepository
        if let repository {
            targetRepository = repository
        } else {
            targetRepository = try await repositoryFactory(image.url.deletingLastPathComponent())
            try Task.checkCancellation()
        }
        let copies = AnalysisAnnotationTransfer.copies(of: sourceAnnotations)

        // Pasting into the open photo edits the live case read here, after every suspension, and
        // saves through the chained queue, so edits made while the revision was captured are kept
        // and no write can race the workspace's own saves.
        if workspaceGeneration == generation,
           sourceURL?.standardizedFileURL == image.url.standardizedFileURL,
           var liveCase = analysisCase,
           liveCase.source.relationship(to: targetRevision) == .exactRevision {
            let before = liveCase.annotations
            liveCase.replaceAnnotations(before + copies)
            try liveCase.validateForPersistence()
            photoAnnotationHistory.record(
                before: before,
                after: liveCase.annotations,
                actionName: "Paste Annotations"
            )
            persist(liveCase)
            await saveTask?.value
            return
        }

        // Another photo: queue behind pending saves so none of them can land after the paste.
        let previousSave = saveTask
        let pasteSave = Task { [weak self] () throws -> AnalysisCase in
            await previousSave?.value
            // A failed earlier save of this photo holds edits newer than its disk copy; paste into
            // that copy, which then replaces the failed record once it is durable.
            if let self,
               let record = self.failedBackgroundCaseSaves.values.first(where: {
                   $0.analysisCase.source.relationship(to: targetRevision) == .exactRevision
               }) {
                var updated = record.analysisCase
                updated.replaceAnnotations(updated.annotations + copies)
                try updated.validateForPersistence()
                self.failedBackgroundCaseSaves[updated.id] = nil
                do {
                    try await record.repository.save(updated)
                } catch {
                    self.failedBackgroundCaseSaves[updated.id] = record
                    self.refreshSaveError()
                    throw error
                }
                self.refreshSaveError()
                return updated
            }
            var targetCase: AnalysisCase
            switch await targetRepository.loadMostRelevantCase(for: targetRevision) {
            case .exact(let existing):
                targetCase = existing
            case .sourceChanged, .none:
                targetCase = AnalysisCase.create(for: targetRevision)
            }
            targetCase.replaceAnnotations(targetCase.annotations + copies)
            try targetCase.validateForPersistence()
            try await targetRepository.save(targetCase)
            return targetCase
        }
        saveTask = Task { _ = try? await pasteSave.value }
        let targetCase = try await pasteSave.value
        // The pasted copies are durable on disk; a workspace that moved on keeps its own state.
        guard workspaceGeneration == generation else { return }

        if let index = folderAnalysisCases.firstIndex(where: { $0.id == targetCase.id }) {
            folderAnalysisCases[index] = targetCase
        } else {
            folderAnalysisCases.append(targetCase)
        }
    }

    var timestampEvidence: [AnalysisTimestampEvidence] {
        let sourceEvidence = sourceFacts.map {
            AnalysisTimelineResolver.sourceEvidence(from: $0, rawMetadata: rawMetadata)
        } ?? []
        return AnalysisTimelineResolver.sorted(
            sourceEvidence + (analysisCase?.timestampEvidence ?? [])
        )
    }

    var timestampConflicts: [AnalysisTimestampConflict] {
        AnalysisTimelineResolver.conflicts(in: timestampEvidence)
    }

    var observations: [AnalysisObservation] {
        (analysisCase?.observations ?? []).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var mapState: AnalysisMapState {
        analysisCase?.mapState ?? AnalysisMapState()
    }

    var mapAnnotations: [AnalysisMapAnnotation] {
        mapState.annotations
    }

    var globalMapAnnotations: [AnalysisGlobalMapAnnotation] {
        folderMapDocument.annotations
    }

    var workingFolderMapAnnotations: [AnalysisImageMapAnnotation] {
        var newestCaseBySource: [URL: AnalysisCase] = [:]
        for analysisCase in folderAnalysisCases + (self.analysisCase.map { [$0] } ?? []) {
            let sourceURL = analysisCase.source.canonicalURL
            if let existing = newestCaseBySource[sourceURL],
               existing.updatedAt >= analysisCase.updatedAt {
                continue
            }
            newestCaseBySource[sourceURL] = analysisCase
        }
        return newestCaseBySource.values
            .sorted { $0.source.filenameAtCreation < $1.source.filenameAtCreation }
            .flatMap { analysisCase in
                var items = analysisCase.mapState.annotations.map {
                    AnalysisImageMapAnnotation(
                        caseID: analysisCase.id,
                        sourceURL: analysisCase.source.canonicalURL,
                        sourceName: analysisCase.source.filenameAtCreation,
                        annotation: $0
                    )
                }
                if let location = analysisCase.mapState.investigationLocation {
                    items.append(AnalysisImageMapAnnotation(
                        caseID: analysisCase.id,
                        sourceURL: analysisCase.source.canonicalURL,
                        sourceName: analysisCase.source.filenameAtCreation,
                        annotation: AnalysisMapAnnotation(
                            id: analysisCase.id,
                            kind: .marker,
                            geometry: .point(location.coordinate),
                            text: location.placeName ?? "Photo location",
                            style: AnalysisMapAnnotationStyle(
                                color: .palette(.orange),
                                lineWidthPoints: AnalysisMapAnnotationStyle.default.lineWidthPoints,
                                fillOpacity: AnalysisMapAnnotationStyle.default.fillOpacity
                            ),
                            now: analysisCase.updatedAt
                        )
                    ))
                }
                return items
            }
    }

    var embeddedLocation: AnalysisGeoCoordinate? {
        guard let latitude = sourceFacts?.latitude,
              let longitude = sourceFacts?.longitude else { return nil }
        let coordinate = AnalysisGeoCoordinate(latitude: latitude, longitude: longitude)
        return coordinate.isValid ? coordinate : nil
    }

    /// Waits until the latest photo- and folder-owned documents are durable on disk.
    /// Project export calls this before it snapshots the working folder.
    func flushPendingSaves() async {
        let pendingLoad = loadTask
        await pendingLoad?.value
        await flushPendingSaveChains()
    }

    /// Waits only for the chained case and folder-map writes, never for a photo load (which may
    /// be hashing a file on a stalled volume). Termination uses this so Quit cannot hang.
    func flushPendingSaveChains() async {
        let pendingCaseSave = saveTask
        let pendingFolderMapSave = folderMapSaveTask
        await pendingCaseSave?.value
        await pendingFolderMapSave?.value
    }

    /// Every case and the folder map the repository holds for the open folder, including the
    /// Application Support fallback used for read-only folders. Project export writes these into
    /// the archive instead of relying on the folder's own `.photo_analysis` directory.
    func persistedDocumentsForProjectExport() async -> (
        cases: [AnalysisCase],
        folderMap: AnalysisFolderMapDocument?
    ) {
        guard let repository else { return ([], nil) }
        let cases = await repository.loadAllCases()
        let folderMapLoad = await repository.loadFolderMapDocumentWithStorage()
        return (cases, folderMapLoad.storage == nil ? nil : folderMapLoad.document)
    }

    /// Prevents analyzer callbacks from starting a path-bearing save while a browser rename is
    /// in flight. Existing load/save work is awaited after the gate closes, so every old-path
    /// writer is durable before filesystem execution begins.
    func beginRenameQuiescence(in folderURL: URL) async throws {
        let normalizedFolder = folderURL.standardizedFileURL
        renameQuiescenceFolderURL = normalizedFolder
        renameQuiescenceNeedsCaseSave = false
        await flushPendingSaves()

        // A failed save of a photo in this folder would be retried with its old path hint.
        if let failed = failedBackgroundCaseSaves.values.first(where: {
            isInRenameQuiescedFolder($0.analysisCase)
        }) {
            renameQuiescenceFolderURL = nil
            throw AnalysisRenameQuiescenceError.persistenceFailed(failed.message)
        }

        if sourceURL?.deletingLastPathComponent().standardizedFileURL == normalizedFolder {
            var failureDetail = saveError
            if case .failed(let detail) = loadState { failureDetail = detail }
            if let failureDetail {
                renameQuiescenceFolderURL = nil
                throw AnalysisRenameQuiescenceError.persistenceFailed(failureDetail)
            }
        }
    }

    /// Applies the successful rename to live state before reopening the persistence gate. Any
    /// analyzer result delivered while execution was in flight is then saved with the new hint.
    func finishRenameQuiescence(
        using mappings: [BatchRenameExecutionPresentation.Mapping]
    ) async throws {
        do {
            try await reassociateRenamedSources(using: mappings)
            try await drainRenameQuiescenceChanges()
            renameQuiescenceFolderURL = nil
        } catch {
            renameQuiescenceFolderURL = nil
            throw error
        }
    }

    /// Reopens persistence when execution never touched the filesystem.
    func cancelRenameQuiescenceBeforeExecution() async throws {
        do {
            try await drainRenameQuiescenceChanges()
            renameQuiescenceFolderURL = nil
        } catch {
            renameQuiescenceFolderURL = nil
            throw error
        }
    }

    /// A failed transaction may leave paths in an indeterminate state. Stop every producer and
    /// close the live workspace rather than allowing an old in-memory hint to be saved later.
    func invalidateAfterRenameExecutionFailure() async {
        workspaceGeneration = UUID()
        analysisRunner.configure(existingRuns: [])
        let pendingLoad = loadTask
        let pendingSave = saveTask
        let pendingFolderSave = folderMapSaveTask
        pendingLoad?.cancel()
        pendingSave?.cancel()
        pendingFolderSave?.cancel()
        await pendingLoad?.value
        await pendingSave?.value
        await pendingFolderSave?.value

        loadTask = nil
        saveTask = nil
        folderMapSaveTask = nil
        repository = nil
        openedImage = nil
        sourceURL = nil
        currentRevision = nil
        analysisCase = nil
        folderAnalysisCases = []
        folderMapDocument = .create()
        caseStorage = nil
        folderMapStorage = nil
        sourceChanged = false
        loadState = .idle
        clearSaveFailures()
        pendingUnsavedChangesExit = nil
        pendingExternalCloseTransition = nil
        renameQuiescenceFolderURL = nil
        renameQuiescenceNeedsCaseSave = false
    }

    var canUndoPhotoAnnotation: Bool {
        !sourceChanged && photoAnnotationHistory.canUndo
    }

    var canRedoPhotoAnnotation: Bool {
        !sourceChanged && photoAnnotationHistory.canRedo
    }

    var photoAnnotationUndoActionName: String? {
        photoAnnotationHistory.undoActionName
    }

    var photoAnnotationRedoActionName: String? {
        photoAnnotationHistory.redoActionName
    }

    var canUndoMapAnnotation: Bool {
        !sourceChanged && mapAnnotationHistory.canUndo
    }

    var canRedoMapAnnotation: Bool {
        !sourceChanged && mapAnnotationHistory.canRedo
    }

    var mapAnnotationUndoActionName: String? {
        mapAnnotationHistory.undoActionName
    }

    var mapAnnotationRedoActionName: String? {
        mapAnnotationHistory.redoActionName
    }

    var canUndoGlobalMapAnnotation: Bool {
        !sourceChanged && globalMapAnnotationHistory.canUndo
    }

    var canRedoGlobalMapAnnotation: Bool {
        !sourceChanged && globalMapAnnotationHistory.canRedo
    }

    var globalMapAnnotationUndoActionName: String? {
        globalMapAnnotationHistory.undoActionName
    }

    var globalMapAnnotationRedoActionName: String? {
        globalMapAnnotationHistory.redoActionName
    }

    var rawMetadata: [AnalysisRawMetadataEntry] {
        analysisRunner.runs.flatMap { $0.output?.rawMetadata ?? [] }
    }

    /// Coordinate transform for the representation currently visible in Analysis.
    ///
    /// Findings stay bound to the source bytes, so developed hover positions are
    /// mapped through crop/straighten back to the original source pixel frame.
    var displayTransform: DisplayImageTransform? {
        guard let facts = sourceFacts,
              let width = facts.pixelWidth,
              let height = facts.pixelHeight else {
            return nil
        }

        let developedCrop: DisplayImageTransform.DevelopedCrop?
        if displayPreference == .developed,
           let crop = developSettings?.crop,
           crop.isEffectiveCrop {
            let left = crop.left ?? 0
            let top = crop.top ?? 0
            let right = crop.right ?? 1
            let bottom = crop.bottom ?? 1
            guard let resolvedCrop = try? DisplayImageTransform.DevelopedCrop(
                sourceNormalizedRect: CGRect(
                    x: left,
                    y: top,
                    width: right - left,
                    height: bottom - top
                ),
                straightenAngleDegrees: crop.angle ?? 0
            ) else {
                return nil
            }
            developedCrop = resolvedCrop
        } else {
            developedCrop = nil
        }

        return try? DisplayImageTransform(
            sourcePixelWidth: width,
            sourcePixelHeight: height,
            exifOrientation: sourceOrientation,
            developedCrop: developedCrop
        )
    }

    /// Coordinate transform for the persistent annotation frame: the full upright original.
    ///
    /// Pairing this with `displayTransform` keeps annotations attached to source pixels when a
    /// developed crop or straighten transform is visible.
    var annotationTransform: DisplayImageTransform? {
        guard let facts = sourceFacts,
              let width = facts.pixelWidth,
              let height = facts.pixelHeight else {
            return nil
        }
        return try? DisplayImageTransform(
            sourcePixelWidth: width,
            sourcePixelHeight: height,
            exifOrientation: sourceOrientation
        )
    }

    deinit {
        // Pending saves are left to finish so the last edit is never dropped.
        loadTask?.cancel()
    }

    /// Sidebar navigation keeps the current tab, including while a previous image is loading.
    func openImageInCurrentWorkspace(_ image: ImageFile) {
        open(image, preferredWorkspaceMode: workspaceMode)
    }

    func open(
        _ image: ImageFile,
        preferredWorkspaceMode: AnalysisWorkspaceMode? = nil
    ) {
        sessionWorkspaceMode = preferredWorkspaceMode
        workspaceGeneration = UUID()
        // Wait for (never cancel) the previous case's saves so its last edit is durable and the
        // reload below reads it back.
        let pendingCaseSaveTask = saveTask
        let pendingFolderMapSaveTask = folderMapSaveTask
        loadTask?.cancel()

        sourceURL = image.url
        openedImage = image
        developSettings = image.cameraRawSettings
        sourceOrientation = image.exifOrientation
        hasDevelopedRepresentation = image.hasDevelopEdits && image.cameraRawSettings != nil
        loadState = .loading
        // Failed saves are never dropped by navigation or Try Again: an open case whose save
        // failed becomes a background record, which the reload adopts if it is the same case.
        if let failure = caseSaveFailure, let analysisCase, let repository, !sourceChanged {
            failedBackgroundCaseSaves[analysisCase.id] = BackgroundCaseSaveFailure(
                analysisCase: analysisCase,
                repository: repository,
                message: Self.backgroundFailureMessage(for: analysisCase, detail: failure)
            )
        }
        caseSaveFailure = nil
        folderMapSaveFailure = nil
        refreshSaveError()
        pendingUnsavedChangesExit = nil
        pendingExternalCloseTransition = nil
        analysisCase = nil
        currentRevision = nil
        sourceChanged = false
        photoAnnotationHistory.removeAll()
        mapAnnotationHistory.removeAll()
        globalMapAnnotationHistory.removeAll()
        folderAnalysisCases = []
        folderMapDocument = AnalysisFolderMapDocument.create()
        caseStorage = nil
        folderMapStorage = nil
        analysisRunner.configure(existingRuns: [])

        let url = image.url
        let orientation = image.exifOrientation
        let repositoryFactory = repositoryFactory
        let generation = workspaceGeneration
        repository = nil

        loadTask = Task { [weak self] in
            do {
                await pendingCaseSaveTask?.value
                await pendingFolderMapSaveTask?.value
                try Task.checkCancellation()
                let repository = try await repositoryFactory(url.deletingLastPathComponent())
                try Task.checkCancellation()
                guard let self, self.workspaceGeneration == generation else { return }
                self.repository = repository
                let revision = try await SourceImageRevision.capture(
                    at: url,
                    exifOrientation: orientation
                )
                try Task.checkCancellation()
                let caseLoad = await repository.loadMostRelevantCaseWithStorage(for: revision)
                try Task.checkCancellation()

                guard self.workspaceGeneration == generation else { return }
                self.currentRevision = revision

                self.caseStorage = caseLoad.storage
                switch caseLoad.match {
                case .exact(var existing):
                    let normalizationDate = Date()
                    if let failed = self.failedBackgroundCaseSaves.removeValue(forKey: existing.id) {
                        // This case's last save failed after it was left, so its disk copy is
                        // older than the edits still held in memory. Reopen those edits and show
                        // them as this case's failed save for Retry Save / Discard.
                        existing = failed.analysisCase
                        self.caseSaveFailure = failed.message
                        self.refreshSaveError()
                    } else if AnalysisLinkedMapMarkerNaming.normalize(
                        &existing.mapState.annotations,
                        using: existing.annotations,
                        now: normalizationDate
                    ) {
                        existing.replaceMapAnnotations(
                            existing.mapState.annotations,
                            now: normalizationDate
                        )
                        self.caseStorage = try await repository.save(existing)
                        try Task.checkCancellation()
                        guard self.workspaceGeneration == generation else { return }
                    }
                    self.analysisCase = existing
                    self.sourceChanged = false
                    self.configureAnalysis(for: existing, autoStart: true)
                case .sourceChanged(let existing):
                    self.analysisCase = existing
                    self.sourceChanged = true
                    self.configureAnalysis(for: existing, autoStart: false)
                case .none:
                    let newCase = AnalysisCase.create(for: revision)
                    self.caseStorage = try await repository.save(newCase)
                    try Task.checkCancellation()
                    self.analysisCase = newCase
                    self.sourceChanged = false
                    self.configureAnalysis(for: newCase, autoStart: true)
                }

                if let preferredWorkspaceMode,
                   !self.sourceChanged,
                   var preferredCase = self.analysisCase,
                   preferredCase.workspaceMode != preferredWorkspaceMode {
                    preferredCase.setWorkspaceMode(preferredWorkspaceMode)
                    self.caseStorage = try await repository.save(preferredCase)
                    self.analysisCase = preferredCase
                }
                let folderCases = await repository.loadAllCases()
                let folderMapLoad = await repository.loadFolderMapDocumentWithStorage()
                try Task.checkCancellation()
                guard self.workspaceGeneration == generation else { return }
                self.folderAnalysisCases = folderCases
                self.folderMapDocument = folderMapLoad.document
                self.folderMapStorage = folderMapLoad.storage
                self.loadState = .ready
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.workspaceGeneration == generation else { return }
                self.loadState = .failed(
                    error.localizedDescription.isEmpty
                        ? "The analysis case could not be opened."
                        : error.localizedDescription
                )
            }
        }
    }

    func retry() {
        guard let openedImage else { return }
        open(openedImage)
    }

    /// Re-persists the in-memory documents whose last save failed. Unlike `retry()`, this never
    /// reloads from disk, so edits made after the failure are kept.
    func retryFailedSave() {
        let retryCase = caseSaveFailure != nil
        let retryFolderMap = folderMapSaveFailure != nil
        caseSaveFailure = nil
        folderMapSaveFailure = nil
        var retryRecords: [BackgroundCaseSaveFailure] = []
        for (id, record) in failedBackgroundCaseSaves {
            // A record that cannot be written now stays reported rather than being cleared.
            let isOpenEditableCase = id == analysisCase?.id && !sourceChanged
            guard !isOpenEditableCase, !isInRenameQuiescedFolder(record.analysisCase) else {
                continue
            }
            failedBackgroundCaseSaves[id] = nil
            retryRecords.append(record)
        }
        refreshSaveError()
        for record in retryRecords {
            enqueueCaseSave(record.analysisCase, repository: record.repository, isBackgroundRetry: true)
        }
        if retryCase, let analysisCase {
            persist(analysisCase)
        }
        if retryFolderMap {
            persistFolderMapDocument(folderMapDocument)
        }
    }

    /// Retries any failed save and waits until every pending document write has finished.
    /// Returns false when the current edits are still not durable on disk.
    func savePendingChanges(waitingForLoad: Bool = true) async -> Bool {
        await flushPendingSaves(waitingForLoad: waitingForLoad)
        if saveError != nil {
            retryFailedSave()
            await flushPendingSaves(waitingForLoad: waitingForLoad)
        }
        return saveError == nil
    }

    private func flushPendingSaves(waitingForLoad: Bool) async {
        if waitingForLoad {
            await flushPendingSaves()
        } else {
            await flushPendingSaveChains()
        }
    }

    /// Opening another photo reloads the workspace from disk, so after a failed save it waits
    /// for the user's Retry Save / Discard Changes / Cancel choice instead of dropping edits.
    func requestOpen(_ image: ImageFile, preferredWorkspaceMode: AnalysisWorkspaceMode? = nil) {
        unsavedExitRequestID = UUID()
        guard saveError == nil else {
            pendingExternalCloseTransition = nil
            pendingUnsavedChangesExit = .openImage(image, preferredWorkspaceMode: preferredWorkspaceMode)
            return
        }
        open(image, preferredWorkspaceMode: preferredWorkspaceMode)
    }

    func requestOpenInCurrentWorkspace(_ image: ImageFile) {
        requestOpen(image, preferredWorkspaceMode: workspaceMode)
    }

    /// Returns true when the workspace may close now; otherwise the unsaved-changes prompt is
    /// raised and the caller closes only if `completeUnsavedChangesExit` says so.
    func requestClose() -> Bool {
        unsavedExitRequestID = UUID()
        guard saveError == nil else {
            pendingExternalCloseTransition = nil
            pendingUnsavedChangesExit = .close
            return false
        }
        return true
    }

    /// Workspace switches that start outside Analysis (Workspace menu, toolbar, shortcuts) close
    /// through the same unsaved-changes gate as the Close button. After a failed save the
    /// transition waits for the prompt and runs only after a successful Retry Save or Discard.
    func requestClose(thenPerform transition: @escaping @MainActor () -> Void) {
        guard requestClose() else {
            pendingExternalCloseTransition = transition
            return
        }
        transition()
    }

    /// Hides the prompt. SwiftUI also calls this from the alert binding when Retry Save or
    /// Discard is chosen, before their async completion runs, so it keeps a queued external
    /// transition; only `cancelUnsavedChangesExit()` abandons it.
    func dismissUnsavedChangesPrompt() {
        pendingUnsavedChangesExit = nil
    }

    /// The prompt's Cancel: stay in Analysis and drop any queued workspace switch.
    func cancelUnsavedChangesExit() {
        unsavedExitRequestID = UUID()
        pendingUnsavedChangesExit = nil
        pendingExternalCloseTransition = nil
    }

    /// The save-error banner's Discard: forget every failed save, including earlier photos'.
    func discardFailedSaves() {
        clearSaveFailures()
    }

    /// Finishes an exit the user confirmed from the unsaved-changes prompt. A failed retry keeps
    /// the workspace (and its Retry Save banner) in place. Returns true when the caller should
    /// now close the workspace; a close requested from outside Analysis runs its own transition
    /// here instead and returns false.
    func completeUnsavedChangesExit(
        _ exit: AnalysisUnsavedChangesExit,
        retryingSave: Bool
    ) async -> Bool {
        pendingUnsavedChangesExit = nil
        let requestID = unsavedExitRequestID
        let generation = workspaceGeneration
        let externalTransition = pendingExternalCloseTransition
        pendingExternalCloseTransition = nil
        if retryingSave {
            guard await savePendingChanges() else { return false }
            // The retry can take long. A newer exit request, a cancelled prompt, or another
            // photo opened meanwhile supersedes this exit.
            guard unsavedExitRequestID == requestID, workspaceGeneration == generation else {
                return false
            }
        } else {
            clearSaveFailures()
        }
        switch exit {
        case .openImage(let image, let preferredWorkspaceMode):
            open(image, preferredWorkspaceMode: preferredWorkspaceMode)
            return false
        case .close:
            if let externalTransition {
                externalTransition()
                return false
            }
            return true
        }
    }

    private func clearSaveFailures() {
        caseSaveFailure = nil
        folderMapSaveFailure = nil
        failedBackgroundCaseSaves = [:]
        saveError = nil
    }

    private func refreshSaveError() {
        saveError = caseSaveFailure
            ?? folderMapSaveFailure
            ?? failedBackgroundCaseSaves.values
                .map(\.message)
                .sorted()
                .first
    }

    private static func backgroundFailureMessage(for failedCase: AnalysisCase, detail: String) -> String {
        "Changes to \(failedCase.source.filenameAtCreation) could not be saved: \(detail)"
    }

    private func recordBackgroundSaveFailure(
        _ error: Error,
        for failedCase: AnalysisCase,
        repository: AnalysisCaseRepository
    ) {
        let detail = error.localizedDescription.isEmpty
            ? "The analysis case could not be saved."
            : error.localizedDescription
        failedBackgroundCaseSaves[failedCase.id] = BackgroundCaseSaveFailure(
            analysisCase: failedCase,
            repository: repository,
            message: Self.backgroundFailureMessage(for: failedCase, detail: detail)
        )
        refreshSaveError()
    }

    private func recordSaveFailure(_ error: Error, isFolderMap: Bool) {
        let message = error.localizedDescription.isEmpty
            ? "Analysis changes could not be saved."
            : error.localizedDescription
        if isFolderMap {
            folderMapSaveFailure = message
        } else {
            caseSaveFailure = message
        }
        refreshSaveError()
    }

    private func recordSaveSuccess(isFolderMap: Bool) {
        if isFolderMap {
            folderMapSaveFailure = nil
        } else {
            caseSaveFailure = nil
        }
        refreshSaveError()
    }

    private func isInRenameQuiescedFolder(_ analysisCase: AnalysisCase) -> Bool {
        guard let quiescedFolder = renameQuiescenceFolderURL else { return false }
        let caseFolder = analysisCase.source.canonicalURL.deletingLastPathComponent()
            .standardizedFileURL
        return caseFolder == quiescedFolder
            || caseFolder.resolvingSymlinksInPath() == quiescedFolder.resolvingSymlinksInPath()
    }

    /// Keeps an open analysis workspace attached to the same source bytes after a successful
    /// browser rename. Persistent path hints are updated by `RenameReassociationService`.
    func reassociateRenamedSources(
        using mappings: [BatchRenameExecutionPresentation.Mapping]
    ) async throws {
        guard !mappings.isEmpty else { return }
        let generation = workspaceGeneration
        let urls = [sourceURL, openedImage?.url, currentRevision?.canonicalURL,
                    analysisCase?.source.canonicalURL].compactMap { $0 }
            + folderAnalysisCases.map { $0.source.canonicalURL }
            + mappings.map(\.sourceURL)
        // This is post-commit bookkeeping. Caller cancellation must not reopen the save gate
        // with old hints after the filesystem has already moved the source bytes.
        let identities = try await Task.detached {
            try await RenameIdentityPreparationService.shared.prepare(
                urls: urls, destinations: mappings.map(\.destinationURL)
            )
        }.value
        guard workspaceGeneration == generation else { return }
        // Merge the prepared hints into current values so analyzer results and annotations
        // delivered during preparation survive the update.
        let destinations = Dictionary(uniqueKeysWithValues: mappings.map {
            (identities.lookup($0.sourceURL), $0.destinationURL.standardizedFileURL)
        })
        func destination(for url: URL) -> URL? {
            guard identities.contains([url]) else { return nil }
            return destinations[identities.lookup(url)]
        }
        if let oldURL = sourceURL, let newURL = destination(for: oldURL) {
            sourceURL = newURL
        }
        if let image = openedImage, let newURL = destination(for: image.url) {
            openedImage = ImageFile(url: newURL, relocating: image)
        }
        if let revision = currentRevision,
           let newURL = destination(for: revision.canonicalURL) {
            currentRevision = revision.relocated(toPreparedCanonicalURL: identities.canonical(newURL))
        }
        if var currentCase = analysisCase,
           let newURL = destination(for: currentCase.source.canonicalURL) {
            currentCase.relocateSource(toPreparedCanonicalURL: identities.canonical(newURL))
            analysisCase = currentCase
        }
        folderAnalysisCases = folderAnalysisCases.map { storedCase in
            guard let newURL = destination(for: storedCase.source.canonicalURL) else {
                return storedCase
            }
            var relocated = storedCase
            relocated.relocateSource(toPreparedCanonicalURL: identities.canonical(newURL))
            return relocated
        }
    }

    func createCaseForCurrentRevision() {
        guard let currentRevision, let repository else { return }

        let newCase = AnalysisCase.create(for: currentRevision)
        analysisCase = newCase
        sourceChanged = false
        photoAnnotationHistory.removeAll()
        mapAnnotationHistory.removeAll()
        loadState = .loading
        analysisRunner.configure(existingRuns: [])

        // Chained behind earlier saves, and later edits chain behind it, so neither cancels the
        // other and the loading state always resolves once the new case is on disk.
        let previousSave = saveTask
        saveTask = Task { [weak self] in
            await previousSave?.value
            do {
                try Task.checkCancellation()
                let storage = try await repository.save(newCase)
                try Task.checkCancellation()
                guard let self, self.analysisCase?.id == newCase.id else { return }
                self.caseStorage = storage
                self.configureAnalysis(for: newCase, autoStart: true)
                self.loadState = .ready
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.analysisCase?.id == newCase.id else { return }
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    func selectWorkspaceMode(_ mode: AnalysisWorkspaceMode) {
        sessionWorkspaceMode = mode
        guard var updatedCase = analysisCase,
              updatedCase.workspaceMode != mode else { return }
        updatedCase.setWorkspaceMode(mode)
        persist(updatedCase)
    }

    func selectDisplayPreference(_ representation: AnalysisSourceRepresentation) {
        guard representation == .original || hasDevelopedRepresentation,
              var updatedCase = analysisCase,
              updatedCase.displayPreference != representation else { return }
        updatedCase.setDisplayPreference(representation)
        persist(updatedCase)
    }

    func cancelAnalyzer(_ analyzerID: String) {
        analysisRunner.cancel(analyzerID: analyzerID)
    }

    func retryAnalyzer(_ analyzerID: String) {
        guard !sourceChanged,
              let analyzer = analyzers.first(where: { $0.identifier == analyzerID }),
              let context = analyzerContext else { return }
        analysisRunner.start(analyzer, context: context)
    }

    func setFindingIncluded(_ findingID: String, included: Bool) {
        analysisRunner.setFindingIncluded(findingID, included: included)
    }

    func setTimestampEvidence(_ evidence: AnalysisTimestampEvidence) {
        guard evidence.source == .userEntered,
              var updatedCase = analysisCase,
              !sourceChanged else { return }
        updatedCase.setTimestampEvidence(evidence)
        persist(updatedCase)
    }

    func removeTimestampEvidence(id: UUID) {
        guard var updatedCase = analysisCase,
              !sourceChanged,
              updatedCase.timestampEvidence.contains(where: {
                  $0.id == id && $0.source == .userEntered
              }),
              updatedCase.removeTimestampEvidence(id: id) else { return }
        persist(updatedCase)
    }

    func setObservation(_ observation: AnalysisObservation) {
        guard observation.validate(), var updatedCase = analysisCase, !sourceChanged else { return }
        updatedCase.setObservation(observation)
        persist(updatedCase)
    }

    func removeObservation(id: UUID) {
        guard var updatedCase = analysisCase,
              !sourceChanged,
              updatedCase.removeObservation(id: id) else { return }
        persist(updatedCase)
    }

    func setMapStyle(_ style: AnalysisMapStyle) {
        guard var updatedCase = analysisCase,
              !sourceChanged,
              updatedCase.mapState.style != style else { return }
        updatedCase.setMapStyle(style)
        persist(updatedCase)
    }

    func setMapTrafficVisible(_ isVisible: Bool) {
        guard var updatedCase = analysisCase,
              !sourceChanged,
              updatedCase.mapState.showsTraffic != isVisible else { return }
        updatedCase.setMapTrafficVisible(isVisible)
        persist(updatedCase)
    }

    func setMap3DContentVisible(_ isVisible: Bool) {
        guard var updatedCase = analysisCase,
              !sourceChanged,
              updatedCase.mapState.shows3DContent != isVisible else { return }
        updatedCase.setMap3DContentVisible(isVisible)
        persist(updatedCase)
    }

    func setMapViewport(_ viewport: AnalysisMapViewport) {
        guard viewport.isValid,
              var updatedCase = analysisCase,
              !sourceChanged,
              updatedCase.mapState.viewport != viewport else { return }
        updatedCase.setMapViewport(viewport)
        persist(updatedCase)
    }

    func setInvestigationLocation(_ location: AnalysisLocationEvidence?) {
        guard location?.validate() ?? true,
              var updatedCase = analysisCase,
              !sourceChanged,
              updatedCase.mapState.investigationLocation != location else { return }
        updatedCase.setInvestigationLocation(location)
        persist(updatedCase)
    }

    /// Applies a place-search result only when the case that started the lookup is still open.
    /// Returns false (and changes nothing) when the result arrived for a case that was left.
    @discardableResult
    func setInvestigationLocation(
        _ location: AnalysisLocationEvidence?,
        requestedForCaseID caseID: UUID?
    ) -> Bool {
        guard caseID != nil, analysisCase?.id == caseID else { return false }
        setInvestigationLocation(location)
        return true
    }

    /// Names the investigation location from a reverse-geocode response, but only if the same
    /// case is open and its location is still the coordinate that was looked up.
    @discardableResult
    func applyReverseGeocodedPlaceName(
        _ placeName: String,
        at coordinate: AnalysisGeoCoordinate,
        requestedForCaseID caseID: UUID?
    ) -> Bool {
        guard caseID != nil, analysisCase?.id == caseID,
              var location = mapState.investigationLocation,
              location.coordinate == coordinate else { return false }
        location.placeName = placeName
        location.placeNameSource = .reverseGeocoded
        setInvestigationLocation(location)
        return true
    }

    func setSolarOverlay(_ overlay: AnalysisSolarOverlayState) {
        guard overlay.validate(),
              var updatedCase = analysisCase,
              !sourceChanged,
              updatedCase.mapState.solarOverlay != overlay else { return }
        updatedCase.setSolarOverlay(overlay)
        persist(updatedCase)
    }

    func clearSolarOverlay() {
        guard var updatedCase = analysisCase,
              !sourceChanged,
              updatedCase.clearSolarOverlay() else { return }
        persist(updatedCase)
    }

    func setMapAnnotation(_ annotation: AnalysisMapAnnotation) {
        guard (try? annotation.validate()) != nil,
              var updatedCase = analysisCase,
              !sourceChanged else { return }
        let before = updatedCase.mapState.annotations
        let existing = before.first { $0.id == annotation.id }
        guard existing != annotation else { return }
        let now = Date()
        updatedCase.setMapAnnotation(annotation, now: now)
        AnalysisLinkedMapMarkerNaming.normalize(
            &updatedCase.mapState.annotations,
            using: updatedCase.annotations,
            now: now
        )
        mapAnnotationHistory.record(
            before: before,
            after: updatedCase.mapState.annotations,
            actionName: existing == nil ? "Add Map Annotation" : "Edit Map Annotation"
        )
        persist(updatedCase)
    }

    func removeMapAnnotation(id: UUID) {
        guard var updatedCase = analysisCase, !sourceChanged else { return }
        let before = updatedCase.mapState.annotations
        let now = Date()
        guard updatedCase.removeMapAnnotation(id: id, now: now) else { return }
        AnalysisLinkedMapMarkerNaming.normalize(
            &updatedCase.mapState.annotations,
            using: updatedCase.annotations,
            now: now
        )
        mapAnnotationHistory.record(
            before: before,
            after: updatedCase.mapState.annotations,
            actionName: "Delete Map Annotation"
        )
        persist(updatedCase)
    }

    func setMapAnnotationVisible(id: UUID, isVisible: Bool) {
        guard var annotation = mapAnnotations.first(where: { $0.id == id }),
              annotation.isVisible != isVisible else { return }
        annotation.isVisible = isVisible
        setMapAnnotation(annotation)
    }

    func setAllMapAnnotationsVisible(_ isVisible: Bool) {
        guard var updatedCase = analysisCase, !sourceChanged else { return }
        let before = updatedCase.mapState.annotations
        let now = Date()
        var after = before
        for index in after.indices where after[index].isVisible != isVisible {
            after[index].isVisible = isVisible
            after[index].markUpdated(now: now)
        }
        guard before != after else { return }
        updatedCase.replaceMapAnnotations(after, now: now)
        mapAnnotationHistory.record(
            before: before,
            after: after,
            actionName: isVisible ? "Show All Map Annotations" : "Hide All Map Annotations"
        )
        persist(updatedCase)
    }

    func setMapAnnotationPhotoLabelLink(
        annotationID: UUID,
        photoLabelID: UUID?
    ) {
        guard photoLabelID == nil || annotations.contains(where: {
            $0.id == photoLabelID
        }),
        var annotation = mapAnnotations.first(where: { $0.id == annotationID }),
        annotation.linkedPhotoLabelID != photoLabelID else { return }
        annotation.linkedPhotoLabelID = photoLabelID
        setMapAnnotation(annotation)
    }

    func setGlobalMapAnnotation(_ annotation: AnalysisMapAnnotation) {
        guard (try? annotation.validate()) != nil, !sourceChanged else { return }
        let before = folderMapDocument.annotations
        let existing = before.first { $0.id == annotation.id }
        var normalizedAnnotation = annotation
        var references = existing?.photoAnnotationReferences ?? []
        if let legacyPhotoAnnotationID = normalizedAnnotation.linkedPhotoLabelID,
           let analysisCase,
           analysisCase.annotations.contains(where: { $0.id == legacyPhotoAnnotationID }) {
            let reference = AnalysisPhotoAnnotationReference(
                caseID: analysisCase.id,
                annotationID: legacyPhotoAnnotationID
            )
            if !references.contains(reference) {
                references.append(reference)
            }
            normalizedAnnotation.linkedPhotoLabelID = nil
        }
        guard existing?.annotation != normalizedAnnotation
                || existing?.photoAnnotationReferences != references else { return }
        var document = folderMapDocument
        document.setAnnotation(AnalysisGlobalMapAnnotation(
            annotation: normalizedAnnotation,
            photoAnnotationReferences: references
        ))
        globalMapAnnotationHistory.record(
            before: before,
            after: document.annotations,
            actionName: existing == nil ? "Add Folder Map Annotation" : "Edit Folder Map Annotation"
        )
        persistFolderMapDocument(document)
    }

    func copyMapAnnotationToGlobal(id: UUID) {
        guard let analysisCase,
              let source = mapAnnotations.first(where: { $0.id == id }),
              !sourceChanged else { return }
        let before = folderMapDocument.annotations
        let copy = source.copiedToGlobal(caseID: analysisCase.id)
        var document = folderMapDocument
        document.setAnnotation(copy)
        globalMapAnnotationHistory.record(
            before: before,
            after: document.annotations,
            actionName: "Copy Map Annotation to Global Map"
        )
        persistFolderMapDocument(document)
    }

    func copyGlobalMapAnnotationToCurrentPhoto(id: UUID) {
        guard let analysisCase,
              let source = globalMapAnnotations.first(where: { $0.id == id }),
              !sourceChanged else { return }
        let before = analysisCase.mapState.annotations
        let copy = source.copiedToPhoto(caseID: analysisCase.id)
        var updatedCase = analysisCase
        updatedCase.setMapAnnotation(copy)
        mapAnnotationHistory.record(
            before: before,
            after: updatedCase.mapState.annotations,
            actionName: "Copy Global Map Annotation to Photo"
        )
        persist(updatedCase)
    }

    func removeGlobalMapAnnotation(id: UUID) {
        guard !sourceChanged else { return }
        let before = folderMapDocument.annotations
        var document = folderMapDocument
        guard document.removeAnnotation(id: id) else { return }
        globalMapAnnotationHistory.record(
            before: before,
            after: document.annotations,
            actionName: "Delete Folder Map Annotation"
        )
        persistFolderMapDocument(document)
    }

    func setGlobalMapAnnotationVisible(id: UUID, isVisible: Bool) {
        guard var annotation = globalMapAnnotations.first(where: { $0.id == id })?.annotation,
              annotation.isVisible != isVisible else { return }
        annotation.isVisible = isVisible
        setGlobalMapAnnotation(annotation)
    }

    func setAllGlobalMapAnnotationsVisible(_ isVisible: Bool) {
        guard !sourceChanged else { return }
        let before = folderMapDocument.annotations
        let now = Date()
        var after = before
        for index in after.indices where after[index].annotation.isVisible != isVisible {
            after[index].annotation.isVisible = isVisible
            after[index].annotation.markUpdated(now: now)
        }
        guard before != after else { return }
        var document = folderMapDocument
        document.replaceAnnotations(after, now: now)
        globalMapAnnotationHistory.record(
            before: before,
            after: after,
            actionName: isVisible ? "Show All Folder Map Annotations" : "Hide All Folder Map Annotations"
        )
        persistFolderMapDocument(document)
    }

    func setGlobalMapAnnotationPhotoLink(
        annotationID: UUID,
        photoAnnotationID: UUID,
        isLinked: Bool
    ) {
        guard let analysisCase,
              analysisCase.annotations.contains(where: { $0.id == photoAnnotationID }),
              var globalAnnotation = globalMapAnnotations.first(where: {
                  $0.id == annotationID
              }) else { return }
        let reference = AnalysisPhotoAnnotationReference(
            caseID: analysisCase.id,
            annotationID: photoAnnotationID
        )
        guard globalAnnotation.setPhotoAnnotationLinked(reference, isLinked: isLinked) else {
            return
        }
        let before = folderMapDocument.annotations
        var document = folderMapDocument
        document.setAnnotation(globalAnnotation)
        globalMapAnnotationHistory.record(
            before: before,
            after: document.annotations,
            actionName: isLinked ? "Link Photo Annotation" : "Unlink Photo Annotation"
        )
        persistFolderMapDocument(document)
    }

    func undoGlobalMapAnnotation() {
        guard !sourceChanged,
              let annotations = globalMapAnnotationHistory.undo() else { return }
        var document = folderMapDocument
        document.replaceAnnotations(annotations)
        persistFolderMapDocument(document)
    }

    func redoGlobalMapAnnotation() {
        guard !sourceChanged,
              let annotations = globalMapAnnotationHistory.redo() else { return }
        var document = folderMapDocument
        document.replaceAnnotations(annotations)
        persistFolderMapDocument(document)
    }

    func undoMapAnnotation() {
        guard !sourceChanged,
              var updatedCase = analysisCase,
              let annotations = mapAnnotationHistory.undo() else { return }
        let now = Date()
        updatedCase.replaceMapAnnotations(annotations, now: now)
        AnalysisLinkedMapMarkerNaming.normalize(
            &updatedCase.mapState.annotations,
            using: updatedCase.annotations,
            now: now
        )
        persist(updatedCase)
    }

    func redoMapAnnotation() {
        guard !sourceChanged,
              var updatedCase = analysisCase,
              let annotations = mapAnnotationHistory.redo() else { return }
        let now = Date()
        updatedCase.replaceMapAnnotations(annotations, now: now)
        AnalysisLinkedMapMarkerNaming.normalize(
            &updatedCase.mapState.annotations,
            using: updatedCase.annotations,
            now: now
        )
        persist(updatedCase)
    }

    func setFindingLink(
        findingID: String,
        annotationID: UUID,
        isLinked: Bool
    ) {
        guard findings.contains(where: { $0.id == findingID }),
              var annotation = annotations.first(where: { $0.id == annotationID }),
              annotation.setFindingLinked(findingID, isLinked: isLinked) else { return }
        setAnnotation(
            annotation,
            actionName: isLinked ? "Link Finding" : "Unlink Finding"
        )
    }

    func setAnnotation(_ annotation: AnalysisAnnotation) {
        setAnnotation(annotation, actionName: nil)
    }

    func setPhotoAnnotationVisible(id: UUID, isVisible: Bool) {
        guard var annotation = annotations.first(where: { $0.id == id }),
              annotation.isVisible != isVisible else { return }
        annotation.isVisible = isVisible
        setAnnotation(
            annotation,
            actionName: isVisible ? "Show Annotation" : "Hide Annotation"
        )
    }

    func setAllPhotoAnnotationsVisible(_ isVisible: Bool) {
        setPhotoAnnotationsVisible(ids: Set(annotations.map(\.id)), isVisible: isVisible)
    }

    func setPhotoAnnotationsVisible(ids: Set<UUID>, isVisible: Bool) {
        guard var updatedCase = analysisCase, !sourceChanged else { return }
        let before = updatedCase.annotations
        let now = Date()
        var after = before
        var changed = false
        for index in after.indices where ids.contains(after[index].id) && after[index].isVisible != isVisible {
            after[index].isVisible = isVisible
            after[index].markUpdated(now: now)
            changed = true
        }
        guard changed else { return }
        updatedCase.replaceAnnotations(after, now: now)
        photoAnnotationHistory.record(
            before: before,
            after: after,
            actionName: isVisible ? "Show Annotations" : "Hide Annotations"
        )
        persist(updatedCase)
    }

    func setPhotoMeasurementCalibration(
        annotationID: UUID,
        calibration: AnalysisMeasurementCalibration?
    ) {
        guard var updatedCase = analysisCase, !sourceChanged,
              let targetIndex = updatedCase.annotations.firstIndex(where: {
                  $0.id == annotationID && $0.kind == .distance
              }) else { return }
        let before = updatedCase.annotations
        let now = Date()
        for index in updatedCase.annotations.indices {
            let replacement = index == targetIndex ? calibration : nil
            guard updatedCase.annotations[index].measurementCalibration != replacement else {
                continue
            }
            updatedCase.annotations[index].measurementCalibration = replacement
            updatedCase.annotations[index].markUpdated(now: now)
        }
        guard before != updatedCase.annotations else { return }
        updatedCase.replaceAnnotations(updatedCase.annotations, now: now)
        photoAnnotationHistory.record(
            before: before,
            after: updatedCase.annotations,
            actionName: calibration == nil
                ? "Remove Measurement Calibration"
                : "Set Measurement Calibration"
        )
        persist(updatedCase)
    }

    private func setAnnotation(_ annotation: AnalysisAnnotation, actionName: String?) {
        guard var updatedCase = analysisCase, !sourceChanged else { return }
        let before = updatedCase.annotations
        let existing = before.first { $0.id == annotation.id }
        guard existing != annotation else { return }
        let now = Date()
        updatedCase.setAnnotation(annotation, now: now)
        AnalysisLinkedMapMarkerNaming.normalize(
            &updatedCase.mapState.annotations,
            using: updatedCase.annotations,
            now: now
        )
        photoAnnotationHistory.record(
            before: before,
            after: updatedCase.annotations,
            actionName: actionName ?? (existing == nil ? "Add Annotation" : "Edit Annotation")
        )
        persist(updatedCase)
    }

    func removeAnnotation(id: UUID) {
        guard var updatedCase = analysisCase, !sourceChanged else { return }
        let before = updatedCase.annotations
        let now = Date()
        guard updatedCase.removeAnnotation(id: id, now: now) else { return }
        AnalysisLinkedMapMarkerNaming.normalize(
            &updatedCase.mapState.annotations,
            using: updatedCase.annotations,
            now: now
        )
        photoAnnotationHistory.record(
            before: before,
            after: updatedCase.annotations,
            actionName: "Delete Annotation"
        )
        persist(updatedCase)
    }

    func undoPhotoAnnotation() {
        guard !sourceChanged,
              var updatedCase = analysisCase,
              let annotations = photoAnnotationHistory.undo() else { return }
        let now = Date()
        updatedCase.replaceAnnotations(annotations, now: now)
        AnalysisLinkedMapMarkerNaming.normalize(
            &updatedCase.mapState.annotations,
            using: updatedCase.annotations,
            now: now
        )
        persist(updatedCase)
    }

    func redoPhotoAnnotation() {
        guard !sourceChanged,
              var updatedCase = analysisCase,
              let annotations = photoAnnotationHistory.redo() else { return }
        let now = Date()
        updatedCase.replaceAnnotations(annotations, now: now)
        AnalysisLinkedMapMarkerNaming.normalize(
            &updatedCase.mapState.annotations,
            using: updatedCase.annotations,
            now: now
        )
        persist(updatedCase)
    }

    private var analyzerContext: AnalysisAnalyzerContext? {
        guard let sourceURL, let currentRevision else { return nil }
        return AnalysisAnalyzerContext(
            sourceURL: sourceURL,
            sourceRevision: currentRevision
        )
    }

    private func configureAnalysis(for analysisCase: AnalysisCase, autoStart: Bool) {
        analysisRunner.configure(existingRuns: analysisCase.analyzerRuns)
        guard autoStart, let context = analyzerContext else { return }
        for analyzer in analyzers where analyzer.cost == .fast {
            analysisRunner.start(analyzer, context: context)
        }
    }

    private func persistAnalyzerRun(_ run: AnalysisAnalyzerRun) {
        guard var updatedCase = analysisCase,
              !sourceChanged else { return }
        updatedCase.setAnalyzerRun(run)
        persist(updatedCase)
    }

    private func persist(_ updatedCase: AnalysisCase) {
        analysisCase = updatedCase
        if let index = folderAnalysisCases.firstIndex(where: { $0.id == updatedCase.id }) {
            folderAnalysisCases[index] = updatedCase
        } else {
            folderAnalysisCases.append(updatedCase)
        }
        guard let repository else { return }

        if let quiescedFolder = renameQuiescenceFolderURL,
           updatedCase.source.canonicalURL.deletingLastPathComponent().standardizedFileURL
            == quiescedFolder {
            renameQuiescenceNeedsCaseSave = true
            return
        }

        enqueueCaseSave(updatedCase, repository: repository)
    }

    private func enqueueCaseSave(
        _ updatedCase: AnalysisCase,
        repository: AnalysisCaseRepository,
        isBackgroundRetry: Bool = false
    ) {
        saveSequence += 1
        let sequence = saveSequence
        latestCaseSaveSequence[updatedCase.id] = sequence
        let previousSave = saveTask
        saveTask = Task { [weak self] in
            await previousSave?.value
            // A newer snapshot of the same case is queued behind this one and will write it.
            guard !Task.isCancelled,
                  (self?.latestCaseSaveSequence[updatedCase.id] ?? sequence) == sequence else {
                return
            }
            do {
                let storage = try await repository.save(updatedCase)
                guard let self else { return }
                self.finishCaseSave(id: updatedCase.id, sequence: sequence)
                guard !isBackgroundRetry, self.analysisCase?.id == updatedCase.id else { return }
                self.caseStorage = storage
                self.recordSaveSuccess(isFolderMap: false)
            } catch is CancellationError {
                self?.finishCaseSave(id: updatedCase.id, sequence: sequence)
            } catch {
                guard let self else { return }
                self.finishCaseSave(id: updatedCase.id, sequence: sequence)
                if !isBackgroundRetry, self.analysisCase?.id == updatedCase.id {
                    self.recordSaveFailure(error, isFolderMap: false)
                } else {
                    // The photo was left before its last save failed; still tell the user.
                    self.recordBackgroundSaveFailure(error, for: updatedCase, repository: repository)
                }
            }
        }
    }

    private func finishCaseSave(id: UUID, sequence: Int) {
        if latestCaseSaveSequence[id] == sequence {
            latestCaseSaveSequence[id] = nil
        }
    }

    private func drainRenameQuiescenceChanges() async throws {
        while renameQuiescenceNeedsCaseSave {
            renameQuiescenceNeedsCaseSave = false
            guard let repository, let currentCase = analysisCase else { continue }
            do {
                try currentCase.validateForPersistence()
                caseStorage = try await repository.save(currentCase)
            } catch {
                throw AnalysisRenameQuiescenceError.persistenceFailed(
                    error.localizedDescription.isEmpty
                        ? "The analysis case could not be saved."
                        : error.localizedDescription
                )
            }
        }
    }

    private func persistFolderMapDocument(_ document: AnalysisFolderMapDocument) {
        folderMapDocument = document
        guard let repository else { return }

        saveSequence += 1
        let sequence = saveSequence
        latestFolderMapSaveSequence[document.id] = sequence
        let previousSave = folderMapSaveTask
        folderMapSaveTask = Task { [weak self] in
            await previousSave?.value
            guard !Task.isCancelled,
                  (self?.latestFolderMapSaveSequence[document.id] ?? sequence) == sequence else {
                return
            }
            do {
                let storage = try await repository.saveFolderMapDocument(document)
                guard let self else { return }
                self.finishFolderMapSave(id: document.id, sequence: sequence)
                guard self.folderMapDocument.id == document.id else { return }
                self.folderMapStorage = storage
                self.recordSaveSuccess(isFolderMap: true)
            } catch is CancellationError {
                self?.finishFolderMapSave(id: document.id, sequence: sequence)
            } catch {
                guard let self else { return }
                self.finishFolderMapSave(id: document.id, sequence: sequence)
                guard self.folderMapDocument.id == document.id else { return }
                self.recordSaveFailure(error, isFolderMap: true)
            }
        }
    }

    private func finishFolderMapSave(id: UUID, sequence: Int) {
        if latestFolderMapSaveSequence[id] == sequence {
            latestFolderMapSaveSequence[id] = nil
        }
    }

    /// Builds the synchronous presentation lookup from actor-loaded case identity. Cases persist
    /// canonical source URLs, while Browser may present the same folder through a security-scoped
    /// symlink path. Project each canonical filename onto the already-known presented folder once
    /// when the model changes; frequently evaluated SwiftUI annotation counts then remain pure
    /// in-memory lookups and do not walk the filesystem.
    private func rebuildPhotoAnnotationCaseIndex() {
        var indexed: [URL: AnalysisCase] = [:]

        func install(_ candidate: AnalysisCase, for key: URL) {
            let normalizedKey = key.standardizedFileURL
            if let existing = indexed[normalizedKey], existing.updatedAt >= candidate.updatedAt {
                return
            }
            indexed[normalizedKey] = candidate
        }

        let presentedFolder = sourceURL?.deletingLastPathComponent().standardizedFileURL
        for candidate in folderAnalysisCases {
            install(candidate, for: candidate.source.canonicalURL)
            if let presentedFolder {
                install(
                    candidate,
                    for: presentedFolder.appendingPathComponent(
                        candidate.source.canonicalURL.lastPathComponent,
                        isDirectory: false
                    )
                )
            }
        }

        if let analysisCase {
            install(analysisCase, for: analysisCase.source.canonicalURL)
            if let sourceURL {
                install(analysisCase, for: sourceURL)
            }
        }

        photoAnnotationCasesByPresentedURL = indexed
    }

    private static func severityRank(_ severity: AnalysisFindingSeverity) -> Int {
        switch severity {
        case .informational: 0
        case .notable: 1
        case .caution: 2
        }
    }
}

nonisolated struct AnalysisTerminationSaveError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

/// Lets application termination wait for, and after a failure retry, the Analysis case and
/// folder-map saves of every open window, so Quit cannot silently drop an Analysis edit.
@MainActor
final class AnalysisWorkspaceTerminationFlush {
    static let shared = AnalysisWorkspaceTerminationFlush()
    private let models = NSHashTable<AnalysisWorkspaceModel>.weakObjects()

    func register(_ model: AnalysisWorkspaceModel) {
        models.add(model)
    }

    /// Every window is saved before any failure is reported, so one failing window cannot stop
    /// the others' edits from becoming durable.
    func flush() async throws {
        var failures: [String] = []
        for model in models.allObjects {
            if await !model.savePendingChanges(waitingForLoad: false) {
                failures.append(model.saveError ?? "Analysis changes could not be saved.")
            }
        }
        guard failures.isEmpty else {
            throw AnalysisTerminationSaveError(message: failures.joined(separator: "\n"))
        }
    }
}

enum AnalysisSelectionResolver {
    static func image(
        images: [ImageFile],
        selectedURLs: Set<URL>,
        lastClickedURL: URL?
    ) -> ImageFile? {
        if let lastClickedURL,
           selectedURLs.contains(lastClickedURL),
           let image = images.first(where: {
               $0.url == lastClickedURL && SupportedImageFormats.isSupported(url: $0.url)
           }) {
            return image
        }

        return images.first {
            selectedURLs.contains($0.url) && SupportedImageFormats.isSupported(url: $0.url)
        }
    }
}
