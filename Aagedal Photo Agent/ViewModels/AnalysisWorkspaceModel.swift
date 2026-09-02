import CoreGraphics
import Foundation

struct AnalysisImageMapAnnotation: Identifiable, Sendable {
    let caseID: UUID
    let sourceURL: URL
    let sourceName: String
    let annotation: AnalysisMapAnnotation

    var id: String { "\(caseID.uuidString)-\(annotation.id.uuidString)" }
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
    private(set) var analysisCase: AnalysisCase?
    private(set) var currentRevision: SourceImageRevision?
    private(set) var sourceChanged = false
    private(set) var sourceURL: URL?
    private(set) var hasDevelopedRepresentation = false
    private(set) var developSettings: CameraRawSettings?
    private(set) var sourceOrientation = 1
    private(set) var folderAnalysisCases: [AnalysisCase] = []
    private(set) var folderMapDocument = AnalysisFolderMapDocument.create()
    private(set) var caseStorage: AnalysisCaseStorage?
    private(set) var folderMapStorage: AnalysisCaseStorage?
    let analysisRunner: AnalysisRunner

    @ObservationIgnored private var repository: AnalysisCaseRepository?
    @ObservationIgnored private var openedImage: ImageFile?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var folderMapSaveTask: Task<Void, Never>?
    @ObservationIgnored private var renameQuiescenceFolderURL: URL?
    @ObservationIgnored private var renameQuiescenceNeedsCaseSave = false
    @ObservationIgnored private let analyzers: [any AnalysisAnalyzer]
    @ObservationIgnored private let repositoryFactory: (URL) -> AnalysisCaseRepository
    private var photoAnnotationHistory = AnalysisAnnotationUndoHistory()
    private var mapAnnotationHistory = AnalysisMapAnnotationUndoHistory()
    private var globalMapAnnotationHistory = AnalysisGlobalMapAnnotationUndoHistory()

    init(
        analyzers: [any AnalysisAnalyzer]? = nil,
        repositoryFactory: ((URL) -> AnalysisCaseRepository)? = nil
    ) {
        analysisRunner = AnalysisRunner()
        self.analyzers = analyzers ?? [SourceFactsAnalyzer()]
        self.repositoryFactory = repositoryFactory ?? {
            AnalysisCaseRepository(sourceFolderURL: $0)
        }
        analysisRunner.onPersistableRunChanged = { [weak self] run in
            self?.persistAnalyzerRun(run)
        }
    }

    var workspaceMode: AnalysisWorkspaceMode {
        analysisCase?.workspaceMode ?? .pixelAnalysis
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

    func photoAnnotations(for image: ImageFile) -> [AnalysisAnnotation] {
        analysisCase(for: image.url)?.annotations ?? []
    }

    func pastePhotoAnnotations(
        _ sourceAnnotations: [AnalysisAnnotation],
        to image: ImageFile
    ) async throws {
        guard !sourceAnnotations.isEmpty else { return }

        let targetRevision = try await SourceImageRevision.capture(
            at: image.url,
            exifOrientation: image.exifOrientation
        )
        let targetRepository = repository
            ?? repositoryFactory(image.url.deletingLastPathComponent())
        let isCurrentSource = sourceURL?.standardizedFileURL == image.url.standardizedFileURL
        var targetCase: AnalysisCase
        if isCurrentSource,
           let currentCase = analysisCase,
           currentCase.source.relationship(to: targetRevision) == .exactRevision {
            targetCase = currentCase
        } else {
            let match = await targetRepository.loadMostRelevantCase(for: targetRevision)
            switch match {
            case .exact(let existing):
                targetCase = existing
            case .sourceChanged, .none:
                targetCase = AnalysisCase.create(for: targetRevision)
            }
        }

        let before = targetCase.annotations
        let copies = AnalysisAnnotationTransfer.copies(of: sourceAnnotations)
        targetCase.replaceAnnotations(before + copies)
        try targetCase.validateForPersistence()
        if isCurrentSource {
            saveTask?.cancel()
            await saveTask?.value
        }
        let storage = try await targetRepository.save(targetCase)

        if let index = folderAnalysisCases.firstIndex(where: { $0.id == targetCase.id }) {
            folderAnalysisCases[index] = targetCase
        } else {
            folderAnalysisCases.append(targetCase)
        }

        if isCurrentSource {
            analysisCase = targetCase
            caseStorage = storage
            sourceChanged = false
            photoAnnotationHistory.record(
                before: before,
                after: targetCase.annotations,
                actionName: "Paste Annotations"
            )
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
        let pendingCaseSave = saveTask
        let pendingFolderMapSave = folderMapSaveTask
        await pendingLoad?.value
        await pendingCaseSave?.value
        await pendingFolderMapSave?.value
    }

    /// Prevents analyzer callbacks from starting a path-bearing save while a browser rename is
    /// in flight. Existing load/save work is awaited after the gate closes, so every old-path
    /// writer is durable before filesystem execution begins.
    func beginRenameQuiescence(in folderURL: URL) async throws {
        let normalizedFolder = folderURL.standardizedFileURL
        renameQuiescenceFolderURL = normalizedFolder
        renameQuiescenceNeedsCaseSave = false
        await flushPendingSaves()

        if sourceURL?.deletingLastPathComponent().standardizedFileURL == normalizedFolder,
           case .failed(let detail) = loadState {
            renameQuiescenceFolderURL = nil
            throw AnalysisRenameQuiescenceError.persistenceFailed(detail)
        }
    }

    /// Applies the successful rename to live state before reopening the persistence gate. Any
    /// analyzer result delivered while execution was in flight is then saved with the new hint.
    func finishRenameQuiescence(
        using mappings: [BatchRenameExecutionPresentation.Mapping]
    ) async throws {
        reassociateRenamedSources(using: mappings)
        do {
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
        loadTask?.cancel()
        saveTask?.cancel()
    }

    func open(
        _ image: ImageFile,
        preferredWorkspaceMode: AnalysisWorkspaceMode? = nil
    ) {
        let pendingFolderMapSaveTask = folderMapSaveTask
        loadTask?.cancel()
        saveTask?.cancel()
        folderMapSaveTask = nil

        sourceURL = image.url
        openedImage = image
        developSettings = image.cameraRawSettings
        sourceOrientation = image.exifOrientation
        hasDevelopedRepresentation = image.hasDevelopEdits && image.cameraRawSettings != nil
        loadState = .loading
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
        let repository = repositoryFactory(url.deletingLastPathComponent())
        self.repository = repository

        loadTask = Task { [weak self] in
            do {
                await pendingFolderMapSaveTask?.value
                try Task.checkCancellation()
                let revision = try await SourceImageRevision.capture(
                    at: url,
                    exifOrientation: orientation
                )
                try Task.checkCancellation()
                let caseLoad = await repository.loadMostRelevantCaseWithStorage(for: revision)
                try Task.checkCancellation()

                guard let self, self.sourceURL == url else { return }
                self.currentRevision = revision

                self.caseStorage = caseLoad.storage
                switch caseLoad.match {
                case .exact(var existing):
                    let normalizationDate = Date()
                    if AnalysisLinkedMapMarkerNaming.normalize(
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
                        guard self.sourceURL == url else { return }
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
                guard self.sourceURL == url else { return }
                self.folderAnalysisCases = folderCases
                self.folderMapDocument = folderMapLoad.document
                self.folderMapStorage = folderMapLoad.storage
                self.loadState = .ready
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.sourceURL == url else { return }
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

    /// Keeps an open analysis workspace attached to the same source bytes after a successful
    /// browser rename. Persistent path hints are updated by `RenameReassociationService`.
    func reassociateRenamedSources(
        using mappings: [BatchRenameExecutionPresentation.Mapping]
    ) {
        let destinations = Dictionary(uniqueKeysWithValues: mappings.map {
            (renameReassociationLookupURL($0.sourceURL), $0.destinationURL.standardizedFileURL)
        })
        guard !destinations.isEmpty else { return }

        func destination(for url: URL) -> URL? {
            destinations[renameReassociationLookupURL(url)]
        }
        if let oldURL = sourceURL, let newURL = destination(for: oldURL) {
            sourceURL = newURL
        }
        if let image = openedImage, let newURL = destination(for: image.url) {
            openedImage = ImageFile(url: newURL, relocating: image)
        }
        if let revision = currentRevision,
           let newURL = destination(for: revision.canonicalURL) {
            currentRevision = revision.relocated(to: newURL)
        }
        if var currentCase = analysisCase,
           let newURL = destination(for: currentCase.source.canonicalURL) {
            currentCase.relocateSource(to: newURL)
            analysisCase = currentCase
        }
        folderAnalysisCases = folderAnalysisCases.map { storedCase in
            guard let newURL = destination(for: storedCase.source.canonicalURL) else {
                return storedCase
            }
            var relocated = storedCase
            relocated.relocateSource(to: newURL)
            return relocated
        }
    }

    func createCaseForCurrentRevision() {
        guard let currentRevision, let repository else { return }
        saveTask?.cancel()

        let newCase = AnalysisCase.create(for: currentRevision)
        analysisCase = newCase
        sourceChanged = false
        photoAnnotationHistory.removeAll()
        mapAnnotationHistory.removeAll()
        loadState = .loading
        analysisRunner.configure(existingRuns: [])

        saveTask = Task { [weak self] in
            do {
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
        guard var updatedCase = analysisCase, !sourceChanged else { return }
        let before = updatedCase.annotations
        let now = Date()
        var after = before
        var changed = false
        for index in after.indices where after[index].isVisible != isVisible {
            after[index].isVisible = isVisible
            after[index].markUpdated(now: now)
            changed = true
        }
        guard changed else { return }
        updatedCase.replaceAnnotations(after, now: now)
        photoAnnotationHistory.record(
            before: before,
            after: after,
            actionName: isVisible ? "Show All Annotations" : "Hide All Annotations"
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

        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                let storage = try await repository.save(updatedCase)
                guard let self, self.analysisCase?.id == updatedCase.id else { return }
                self.caseStorage = storage
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.analysisCase?.id == updatedCase.id else { return }
                self.loadState = .failed(error.localizedDescription)
            }
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

        folderMapSaveTask?.cancel()
        folderMapSaveTask = Task { [weak self] in
            do {
                let storage = try await repository.saveFolderMapDocument(document)
                guard let self, self.folderMapDocument.id == document.id else { return }
                self.folderMapStorage = storage
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.folderMapDocument.id == document.id else { return }
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    private func analysisCase(for sourceURL: URL) -> AnalysisCase? {
        let canonicalURL = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        return (folderAnalysisCases + (analysisCase.map { [$0] } ?? []))
            .filter { $0.source.canonicalURL == canonicalURL }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private static func severityRank(_ severity: AnalysisFindingSeverity) -> Int {
        switch severity {
        case .informational: 0
        case .notable: 1
        case .caution: 2
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
