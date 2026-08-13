import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AnalysisWorkspaceView: View {
    @Bindable var model: AnalysisWorkspaceModel
    let folderImages: [ImageFile]
    let thumbnailService: ThumbnailService
    let onSelectImage: (ImageFile) -> Void
    let onClose: () -> Void
    @State private var selectedFindingID: String?
    @State private var pixelInspectionSample: ImageInspectionSample?
    @State private var displayedScopeImage: CGImage?
    @State private var scopeSourceMode: AnalysisScopeSourceMode = .fullImage
    @State private var selectedScopeRegion: CGRect?
    @State private var pixelViewMode: AnalysisPixelViewMode = .normal
    @State private var photoAnnotationTool: AnalysisAnnotationTool = .select
    @State private var mapAnnotationTool: AnalysisAnnotationTool = .select
    @State private var annotationStyle = AnalysisAnnotationStyle.default
    @State private var selectedAnnotationID: UUID?
    @State private var selectedMapAnnotationID: UUID?
    @State private var activeMarkupSurface: AnalysisMarkupSurface = .photo
    @State private var calibrationEditorRequest: AnalysisCalibrationEditorRequest?
    @State private var annotationLabelEditorRequest: AnalysisAnnotationLabelEditorRequest?
    @State private var photoPolygonDraftCount = 0
    @State private var photoPolygonFinishRequestID = 0
    @State private var photoPolygonCancelRequestID = 0
    @State private var isTimestampEditorPresented = false
    @State private var isObservationEditorPresented = false
    @State private var mapLayerScope: AnalysisMapLayerScope = .currentPhoto
    @State private var mapDraftCoordinateCount = 0
    @State private var mapPrimaryActionRequestID = 0
    @State private var mapFinishShapeRequestID = 0
    @State private var mapCancelDraftRequestID = 0
    @State private var isReportOptionsPresented = false
    @State private var reportExportProgress: Double?
    @State private var reportExportError: String?
    @State private var reportExportTask: Task<Void, Never>?
    @State private var evidenceExportTask: Task<Void, Never>?
    @State private var copiedPhotoAnnotations: [AnalysisAnnotation] = []
    @State private var copiedAnnotationSourceName: String?
    @State private var annotationPasteError: String?

    var body: some View {
        workspaceWithStateObservers
        .sheet(item: $calibrationEditorRequest) { request in
            AnalysisCalibrationEditor(
                request: request,
                onSave: { calibration in
                    model.setPhotoMeasurementCalibration(
                        annotationID: request.annotationID,
                        calibration: calibration
                    )
                    calibrationEditorRequest = nil
                },
                onRemove: {
                    model.setPhotoMeasurementCalibration(
                        annotationID: request.annotationID,
                        calibration: nil
                    )
                    calibrationEditorRequest = nil
                },
                onCancel: { calibrationEditorRequest = nil }
            )
        }
        .sheet(isPresented: $isTimestampEditorPresented) {
            AnalysisTimestampEditor(
                onSave: { evidence in
                    model.setTimestampEvidence(evidence)
                    isTimestampEditorPresented = false
                },
                onCancel: { isTimestampEditorPresented = false }
            )
        }
        .sheet(isPresented: $isObservationEditorPresented) {
            AnalysisObservationEditor(
                onSave: { observation in
                    model.setObservation(observation)
                    isObservationEditorPresented = false
                },
                onCancel: { isObservationEditorPresented = false }
            )
        }
        .sheet(item: $annotationLabelEditorRequest) { request in
            AnalysisAnnotationLabelEditor(
                request: request,
                onSave: { label, note in
                    setSelectedAnnotationDetails(label: label, note: note)
                    annotationLabelEditorRequest = nil
                },
                onCancel: { annotationLabelEditorRequest = nil }
            )
        }
        .sheet(isPresented: $isReportOptionsPresented) {
            AnalysisReportExportSheet(
                hasSelectedEvidenceCrop: reportEvidenceCropRect != nil,
                onExport: { options in
                    isReportOptionsPresented = false
                    Task { @MainActor in
                        await Task.yield()
                        chooseReportDestinationAndExport(options: options)
                    }
                },
                onCancel: { isReportOptionsPresented = false }
            )
        }
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { reportExportError != nil },
                set: { if !$0 { reportExportError = nil } }
            )
        ) {
            Button("OK") { reportExportError = nil }
        } message: {
            Text(reportExportError ?? "The export could not be completed.")
        }
        .alert(
            "Annotations Could Not Be Pasted",
            isPresented: Binding(
                get: { annotationPasteError != nil },
                set: { if !$0 { annotationPasteError = nil } }
            )
        ) {
            Button("OK") { annotationPasteError = nil }
        } message: {
            Text(annotationPasteError ?? "The annotations could not be pasted.")
        }
        .onDisappear {
            reportExportTask?.cancel()
            evidenceExportTask?.cancel()
        }
    }

    private var workspaceWithStateObservers: some View {
        workspaceWithSourceObservers
        .onChange(of: selectedAnnotationID) {
            guard let selectedAnnotationID,
                  let annotation = model.annotations.first(where: {
                      $0.id == selectedAnnotationID
                  }) else { return }
            activeMarkupSurface = .photo
            selectedMapAnnotationID = nil
            annotationStyle = annotation.style
        }
        .onChange(of: selectedMapAnnotationID) {
            guard selectedMapAnnotationID != nil,
                  let annotation = selectedMapAnnotation else { return }
            activeMarkupSurface = .map
            selectedAnnotationID = nil
            annotationStyle = AnalysisAnnotationStyle(
                color: annotation.style.color,
                lineWidthPoints: annotation.style.lineWidthPoints,
                fillOpacity: annotation.style.fillOpacity
            )
        }
        .onChange(of: annotationStyle) {
            updateSelectedAnnotationStyle()
        }
        .onChange(of: model.annotations) {
            guard let selectedAnnotationID else { return }
            guard let annotation = model.annotations.first(where: {
                $0.id == selectedAnnotationID
            }) else {
                self.selectedAnnotationID = nil
                return
            }
            if annotationStyle != annotation.style {
                annotationStyle = annotation.style
            }
        }
        .onChange(of: mapLayerScope) {
            selectedMapAnnotationID = nil
            mapDraftCoordinateCount = 0
            mapCancelDraftRequestID += 1
        }
    }

    private var workspaceWithSourceObservers: some View {
        workspaceContent
        .onChange(of: model.sourceURL) {
            resetForSourceChange()
        }
        .onChange(of: model.analysisCase?.id) {
            selectedAnnotationID = nil
            selectedMapAnnotationID = nil
        }
        .onChange(of: model.displayPreference) {
            pixelInspectionSample = nil
            displayedScopeImage = nil
            selectedScopeRegion = nil
            selectedAnnotationID = nil
            selectedMapAnnotationID = nil
        }
    }

    private var workspaceContent: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()

            if model.sourceChanged {
                sourceChangedBanner
                Divider()
            }

            workspaceBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image Analysis workspace")
    }

    private func resetForSourceChange() {
        pixelInspectionSample = nil
        displayedScopeImage = nil
        selectedScopeRegion = nil
        scopeSourceMode = .fullImage
        pixelViewMode = .normal
        selectedAnnotationID = nil
        selectedMapAnnotationID = nil
        mapDraftCoordinateCount = 0
        photoPolygonDraftCount = 0
        photoPolygonCancelRequestID += 1
    }

    private func updateSelectedAnnotationStyle() {
        switch activeMarkupSurface {
        case .photo:
            guard let selectedAnnotationID,
                  var annotation = model.annotations.first(where: {
                      $0.id == selectedAnnotationID
                  }),
                  annotation.style != annotationStyle else { return }
            annotation.style = annotationStyle
            model.setAnnotation(annotation)
        case .map:
            guard selectedMapAnnotationID != nil,
                  var annotation = selectedMapAnnotation else { return }
            let style = AnalysisMapAnnotationStyle(
                color: annotationStyle.color,
                lineWidthPoints: annotationStyle.lineWidthPoints,
                fillOpacity: annotationStyle.fillOpacity
            )
            guard annotation.style != style else { return }
            annotation.style = style
            if mapLayerScope == .workingFolder {
                model.setGlobalMapAnnotation(annotation)
            } else {
                model.setMapAnnotation(annotation)
            }
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 14) {
            Label("Image Analysis", systemImage: "waveform.path.ecg.rectangle")
                .font(.headline)

            Picker(
                "Analysis Mode",
                selection: Binding(
                    get: { model.workspaceMode },
                    set: { model.selectWorkspaceMode($0) }
                )
            ) {
                ForEach(AnalysisWorkspaceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            .disabled(model.analysisCase == nil)

            if model.workspaceMode == .pixelAnalysis {
                Picker("Pixel View", selection: $pixelViewMode) {
                    ForEach(AnalysisPixelViewMode.allCases, id: \.self) { mode in
                        Text(mode.compactLabel)
                            .tag(mode)
                            .accessibilityLabel(mode.displayName)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 360, idealWidth: 460, maxWidth: 540)
                .disabled(model.analysisCase == nil)
                .help(
                    "Show the normal image, a linear-light channel, relative luminance, "
                        + "or a fixed-parameter JPEG compression residual"
                )
            }

            Spacer()

            if let reportExportProgress {
                ProgressView(value: reportExportProgress)
                    .frame(width: 90)
                    .accessibilityLabel("Exporting analysis report")
                Button("Cancel", role: .cancel) {
                    reportExportTask?.cancel()
                }
                .buttonStyle(.borderless)
            } else {
                Menu {
                    Button("PDF Report…", systemImage: "doc.richtext") {
                        isReportOptionsPresented = true
                    }
                    .disabled(model.sourceChanged)

                    Divider()

                    Button("Annotated Image (JPEG)…", systemImage: "photo") {
                        chooseAnnotatedImageDestinationAndExport()
                    }
                    .disabled(model.sourceChanged || evidenceExportTask != nil)

                    Button("Annotated Map (JPEG)…", systemImage: "map") {
                        chooseAnnotatedMapDestinationAndExport()
                    }
                    .disabled(model.mapState.viewport == nil || evidenceExportTask != nil)
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(model.analysisCase == nil)
                .help("Export a PDF report or a separate annotated image or map JPEG")
            }

            Picker(
                "Image Representation",
                selection: Binding(
                    get: { model.displayPreference },
                    set: { model.selectDisplayPreference($0) }
                )
            ) {
                Text(AnalysisSourceRepresentation.original.displayName)
                    .tag(AnalysisSourceRepresentation.original)
                if model.hasDevelopedRepresentation {
                    Text(AnalysisSourceRepresentation.developed.displayName)
                        .tag(AnalysisSourceRepresentation.developed)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(model.analysisCase == nil)
            .help("Choose which representation is displayed; source-byte findings remain bound to the original")

            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
                .help("Return to the browser workspace")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var workspaceBody: some View {
        switch model.loadState {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Validating source revision…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Validating source revision")

        case .failed(let message):
            ContentUnavailableView {
                Label("Analysis Case Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.retry() }
            }

        case .ready:
            if model.workspaceMode == .pixelAnalysis {
                pixelAnalysisBody
            } else {
                osintBody
            }
        }
    }

    private var sourceChangedBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Source changed")
                    .font(.headline)
                Text("This case remains tied to its original SHA-256 revision. Create a new case to analyze the current bytes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Create Case for Current Source") {
                model.createCaseForCurrentRevision()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
        .accessibilityElement(children: .combine)
    }

    private func chooseReportDestinationAndExport(options: AnalysisReportExportOptions) {
        guard let analysisCase = model.analysisCase,
              let sourceURL = model.sourceURL,
              reportExportTask == nil else { return }

        let panel = NSSavePanel()
        panel.title = "Export Analysis Report"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let baseName = analysisCase.title.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = "\(baseName.isEmpty ? "Analysis" : baseName) Report.pdf"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        let evidenceCropRect = options.includeSelectedEvidenceCrop
            ? reportEvidenceCropRect
            : nil
        reportExportProgress = 0
        reportExportTask = Task { @MainActor in
            defer {
                reportExportProgress = nil
                reportExportTask = nil
            }
            do {
                let snapshot = try await AnalysisReportSnapshot.capture(
                    from: analysisCase,
                    sourceURL: sourceURL,
                    appVersion: appVersion,
                    appBuild: appBuild,
                    originalDisplayEvidenceCrop: evidenceCropRect
                )
                try Task.checkCancellation()
                reportExportProgress = 0.08
                let data = try await AnalysisPDFReportRenderer.makePDF(
                    snapshot: snapshot,
                    options: options,
                    progress: { reportExportProgress = 0.08 + $0 * 0.90 }
                )
                try Task.checkCancellation()
                try data.write(to: outputURL, options: .atomic)
                reportExportProgress = 1
            } catch is CancellationError {
                return
            } catch AnalysisPDFReportError.cancelled {
                return
            } catch {
                reportExportError = error.localizedDescription.isEmpty
                    ? "The report could not be exported."
                    : error.localizedDescription
            }
        }
    }

    /// The scope selection is relative to the currently displayed representation. A true-pixel
    /// crop is offered only for the original representation, where every selected displayed pixel
    /// maps directly to one source pixel without a developed crop/straighten resample.
    private var reportEvidenceCropRect: CGRect? {
        guard model.displayPreference == .original,
              let selectedScopeRegion,
              let displayTransform = model.displayTransform,
              let annotationTransform = model.annotationTransform else {
            return nil
        }
        let sourceRect = displayTransform.sourceNormalizedRect(
            fromDisplayNormalized: selectedScopeRegion
        )
        let originalDisplayRect = annotationTransform.displayNormalizedRect(
            fromSourceNormalized: sourceRect
        ).standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !originalDisplayRect.isNull,
              originalDisplayRect.width >= AnalysisScopeSelection.minimumNormalizedDimension,
              originalDisplayRect.height >= AnalysisScopeSelection.minimumNormalizedDimension else {
            return nil
        }
        return originalDisplayRect
    }

    private func chooseAnnotatedImageDestinationAndExport() {
        guard let analysisCase = model.analysisCase,
              let sourceURL = model.sourceURL,
              evidenceExportTask == nil else { return }
        guard let outputURL = chooseJPEGDestination(
            title: "Export Annotated Image",
            suggestedName: "\(analysisCase.title) Annotated.jpg"
        ) else { return }

        evidenceExportTask = Task { @MainActor in
            defer { evidenceExportTask = nil }
            do {
                let data = try await AnalysisEvidenceJPEGRenderer.photoJPEG(
                    sourceURL: sourceURL,
                    annotations: analysisCase.annotations
                )
                try Task.checkCancellation()
                try data.write(to: outputURL, options: .atomic)
            } catch is CancellationError {
                return
            } catch {
                reportExportError = error.localizedDescription.isEmpty
                    ? "The annotated image could not be exported."
                    : error.localizedDescription
            }
        }
    }

    private func chooseAnnotatedMapDestinationAndExport() {
        guard let analysisCase = model.analysisCase,
              let evidence = AnalysisReportMapEvidence(
                  state: analysisCase.mapState,
                  capturedAt: Date()
              ), evidenceExportTask == nil else { return }
        guard let outputURL = chooseJPEGDestination(
            title: "Export Annotated Map",
            suggestedName: "\(analysisCase.title) Map.jpg"
        ) else { return }

        evidenceExportTask = Task { @MainActor in
            defer { evidenceExportTask = nil }
            do {
                let data = try await AnalysisEvidenceJPEGRenderer.mapJPEG(evidence: evidence)
                try Task.checkCancellation()
                try data.write(to: outputURL, options: .atomic)
            } catch is CancellationError {
                return
            } catch {
                reportExportError = error.localizedDescription.isEmpty
                    ? "The annotated map could not be exported."
                    : error.localizedDescription
            }
        }
    }

    private func chooseJPEGDestination(title: String, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = "Export"
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private var pixelAnalysisBody: some View {
        HStack(spacing: 0) {
            AnalysisImageRail(
                images: folderImages,
                selectedURL: model.sourceURL,
                thumbnailService: thumbnailService,
                copiedAnnotationCount: copiedPhotoAnnotations.count,
                copiedAnnotationSourceName: copiedAnnotationSourceName,
                annotationCount: { model.photoAnnotations(for: $0).count },
                canPasteAnnotations: { image in
                    image.url != model.sourceURL || !model.sourceChanged
                },
                onSelect: onSelectImage,
                onCopyAnnotations: copyAnnotations,
                onPasteAnnotations: pasteAnnotations
            )
            .frame(width: 76)

            Divider()

            HSplitView {
                caseSidebar
                    .frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
                VSplitView {
                    sourcePreview(showMarkupToolbar: true)
                        .frame(minHeight: 260)
                    AnalysisScopeWorkspace(
                        sourceImage: displayedScopeImage,
                        sourceMode: $scopeSourceMode,
                        selectedRegion: $selectedScopeRegion
                    )
                        .frame(minHeight: 180, idealHeight: 300)
                }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                analysisDetail
                    .frame(minWidth: 260, idealWidth: 330, maxWidth: 430)
            }
        }
    }

    private var osintBody: some View {
        VStack(spacing: 0) {
            osintMarkupToolbar
            Divider()

            HStack(spacing: 0) {
                AnalysisImageRail(
                    images: folderImages,
                    selectedURL: model.sourceURL,
                    thumbnailService: thumbnailService,
                    copiedAnnotationCount: copiedPhotoAnnotations.count,
                    copiedAnnotationSourceName: copiedAnnotationSourceName,
                    annotationCount: { model.photoAnnotations(for: $0).count },
                    canPasteAnnotations: { image in
                        image.url != model.sourceURL || !model.sourceChanged
                    },
                    onSelect: onSelectImage,
                    onCopyAnnotations: copyAnnotations,
                    onPasteAnnotations: pasteAnnotations
                )
                .frame(width: 76)

                Divider()

                HSplitView {
                    VSplitView {
                        sourcePreview(showMarkupToolbar: false)
                            .frame(minHeight: 260)

                        AnalysisTimelineView(
                            evidence: model.timestampEvidence,
                            observations: model.observations,
                            conflicts: model.timestampConflicts,
                            isReadOnly: model.sourceChanged,
                            onAddTimed: { isTimestampEditorPresented = true },
                            onAddNote: { isObservationEditorPresented = true },
                            onDeleteTimestamp: model.removeTimestampEvidence,
                            onDeleteObservation: model.removeObservation
                        )
                        .frame(minHeight: 170, idealHeight: 280)
                    }
                    .frame(minWidth: 400, idealWidth: 620, maxWidth: 760)

                    VSplitView {
                        AnalysisMapEvidenceView(
                            mapState: model.mapState,
                            embeddedLocation: model.embeddedLocation,
                            photoAnnotationToLocate: selectedPhotoAnnotation,
                            currentSourceURL: model.sourceURL,
                            folderAnnotations: mapLayerScope == .workingFolder
                                ? model.workingFolderMapAnnotations
                                : [],
                            globalAnnotations: model.globalMapAnnotations,
                            usesFolderOwnedAnnotations: mapLayerScope == .workingFolder,
                            isReadOnly: model.sourceChanged,
                            onSetStyle: model.setMapStyle,
                            onSetTrafficVisible: model.setMapTrafficVisible,
                            onSet3DContentVisible: model.setMap3DContentVisible,
                            onSetViewport: model.setMapViewport,
                            onSetInvestigationLocation: model.setInvestigationLocation,
                            onSetAnnotation: { annotation in
                                if mapLayerScope == .workingFolder {
                                    model.setGlobalMapAnnotation(annotation)
                                } else {
                                    model.setMapAnnotation(annotation)
                                }
                            },
                            onSetLocalAnnotation: model.setMapAnnotation,
                            onCopyAnnotationToOtherScope: { annotationID in
                                if mapLayerScope == .workingFolder {
                                    model.copyGlobalMapAnnotationToCurrentPhoto(id: annotationID)
                                } else {
                                    model.copyMapAnnotationToGlobal(id: annotationID)
                                }
                            },
                            onDeleteAnnotation: { annotationID in
                                if mapLayerScope == .workingFolder {
                                    model.removeGlobalMapAnnotation(id: annotationID)
                                } else {
                                    model.removeMapAnnotation(id: annotationID)
                                }
                            },
                            annotationTool: $mapAnnotationTool,
                            sharedAnnotationStyle: $annotationStyle,
                            selectedAnnotationID: $selectedMapAnnotationID,
                            primaryActionRequestID: mapPrimaryActionRequestID,
                            finishShapeRequestID: mapFinishShapeRequestID,
                            cancelDraftRequestID: mapCancelDraftRequestID,
                            onDraftCountChanged: { mapDraftCoordinateCount = $0 }
                        )
                        .frame(minWidth: 520, minHeight: 480)

                        AnalysisMapLayersView(
                            annotations: model.mapAnnotations,
                            globalAnnotations: model.globalMapAnnotations,
                            photoAnnotations: model.annotations,
                            folderAnnotations: model.workingFolderMapAnnotations,
                            currentCaseID: model.analysisCase?.id,
                            scope: $mapLayerScope,
                            selectedPhotoAnnotationID: $selectedAnnotationID,
                            selectedAnnotationID: $selectedMapAnnotationID,
                            isReadOnly: model.sourceChanged,
                            onSetPhotoVisible: model.setPhotoAnnotationVisible,
                            onSetAllPhotosVisible: model.setAllPhotoAnnotationsVisible,
                            onEditPhotoAnnotation: presentPhotoAnnotationEditor,
                            onDeletePhotoAnnotation: model.removeAnnotation,
                            onSetVisible: model.setMapAnnotationVisible,
                            onSetAllVisible: model.setAllMapAnnotationsVisible,
                            onEditMapAnnotation: presentMapAnnotationEditor,
                            onDeleteMapAnnotation: model.removeMapAnnotation,
                            onSetPhotoAnnotationLink: model.setMapAnnotationPhotoLabelLink,
                            onSetGlobalVisible: model.setGlobalMapAnnotationVisible,
                            onSetAllGlobalsVisible: model.setAllGlobalMapAnnotationsVisible,
                            onEditGlobalAnnotation: presentMapAnnotationEditor,
                            onDeleteGlobalAnnotation: model.removeGlobalMapAnnotation,
                            onSetGlobalPhotoAnnotationLink: model.setGlobalMapAnnotationPhotoLink,
                            onCopyToGlobal: model.copyMapAnnotationToGlobal,
                            onCopyToCurrentPhoto: model.copyGlobalMapAnnotationToCurrentPhoto
                        )
                        .frame(minHeight: 150, idealHeight: 210, maxHeight: 280)
                    }
                    .frame(minWidth: 520, maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: photoAnnotationTool) {
            activeMarkupSurface = .photo
        }
        .onChange(of: mapAnnotationTool) {
            activeMarkupSurface = .map
        }
    }

    private func copyAnnotations(from image: ImageFile) {
        copiedPhotoAnnotations = model.photoAnnotations(for: image)
        copiedAnnotationSourceName = image.filename
    }

    private func pasteAnnotations(to image: ImageFile) {
        let annotations = copiedPhotoAnnotations
        guard !annotations.isEmpty else { return }
        Task { @MainActor in
            do {
                try await model.pastePhotoAnnotations(annotations, to: image)
            } catch {
                annotationPasteError = error.localizedDescription.isEmpty
                    ? "The annotations could not be pasted to \(image.filename)."
                    : error.localizedDescription
            }
        }
    }

    private var osintMarkupToolbar: some View {
        AnalysisAnnotationToolbar(
            tool: $photoAnnotationTool,
            style: $annotationStyle,
            selectedAnnotationID: activeMarkupSurface == .photo
                ? selectedAnnotationID
                : selectedMapAnnotationID,
            isReadOnly: model.sourceChanged,
            canUndo: activeMarkupSurface == .photo
                ? model.canUndoPhotoAnnotation
                : (mapLayerScope == .workingFolder
                    ? model.canUndoGlobalMapAnnotation
                    : model.canUndoMapAnnotation),
            canRedo: activeMarkupSurface == .photo
                ? model.canRedoPhotoAnnotation
                : (mapLayerScope == .workingFolder
                    ? model.canRedoGlobalMapAnnotation
                    : model.canRedoMapAnnotation),
            undoActionName: activeMarkupSurface == .photo
                ? model.photoAnnotationUndoActionName
                : (mapLayerScope == .workingFolder
                    ? model.globalMapAnnotationUndoActionName
                    : model.mapAnnotationUndoActionName),
            redoActionName: activeMarkupSurface == .photo
                ? model.photoAnnotationRedoActionName
                : (mapLayerScope == .workingFolder
                    ? model.globalMapAnnotationRedoActionName
                    : model.mapAnnotationRedoActionName),
            onUndo: activeMarkupSurface == .photo
                ? model.undoPhotoAnnotation
                : (mapLayerScope == .workingFolder
                    ? model.undoGlobalMapAnnotation
                    : model.undoMapAnnotation),
            onRedo: activeMarkupSurface == .photo
                ? model.redoPhotoAnnotation
                : (mapLayerScope == .workingFolder
                    ? model.redoGlobalMapAnnotation
                    : model.redoMapAnnotation),
            canCalibrate: activeMarkupSurface == .photo && selectedDistanceAnnotation != nil,
            selectedIsCalibration: selectedDistanceAnnotation?.measurementCalibration != nil,
            onCalibrate: presentCalibrationEditor,
            onDelete: deleteActiveAnnotation,
            tools: AnalysisAnnotationTool.photoTools,
            contextLabel: "Photo",
            secondaryTool: $mapAnnotationTool,
            secondaryTools: AnalysisAnnotationTool.mapTools,
            secondaryContextLabel: "Map",
            canEditLabel: activeSelectedAnnotationID != nil,
            selectedHasLabel: activeSelectedAnnotationHasDetails,
            showsLabelActionTitle: true,
            photoFinishActionTitle: photoPolygonDraftCount >= 3 ? "Finish Polygon" : nil,
            photoDraftIsActive: photoPolygonDraftCount > 0,
            onPhotoFinishAction: { photoPolygonFinishRequestID += 1 },
            onCancelPhotoDraft: { photoPolygonCancelRequestID += 1 },
            mapActionTitle: mapToolbarActionTitle,
            mapFinishActionTitle: mapToolbarFinishActionTitle,
            mapDraftIsActive: mapDraftCoordinateCount > 0,
            onMapAction: { mapPrimaryActionRequestID += 1 },
            onMapFinishAction: { mapFinishShapeRequestID += 1 },
            onCancelMapDraft: { mapCancelDraftRequestID += 1 },
            onEditLabel: presentAnnotationLabelEditor
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var mapToolbarActionTitle: String? {
        switch mapAnnotationTool {
        case .select, .hand: nil
        case .marker: "Add Marker"
        case .line: mapDraftCoordinateCount == 0 ? "Set Start" : "Set End"
        case .distance: mapDraftCoordinateCount == 0 ? "Set Start" : "Set End"
        case .shape: "Add Vertex"
        case .label: "Add Label"
        case .arrow, .rectangle, .ellipse: nil
        }
    }

    private var mapToolbarFinishActionTitle: String? {
        mapAnnotationTool == .shape && mapDraftCoordinateCount >= 3 ? "Finish Shape" : nil
    }

    private var caseSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CASE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let analysisCase = model.analysisCase {
                VStack(alignment: .leading, spacing: 5) {
                    Text(analysisCase.title)
                        .font(.headline)
                        .lineLimit(2)
                }

                Divider()

                Button {
                    selectedFindingID = nil
                } label: {
                    HStack {
                        Label("Source Facts", systemImage: "checkmark.shield")
                        Spacer()
                        analyzerStatusAccessory
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .accessibilityLabel("Source Facts")

                if !model.findings.isEmpty {
                    Text("FINDINGS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(model.findings) { finding in
                                Button {
                                    selectedFindingID = finding.id
                                } label: {
                                    HStack(alignment: .top, spacing: 7) {
                                        Image(systemName: severityIcon(finding.severity))
                                            .foregroundStyle(severityColor(finding.severity))
                                            .frame(width: 14)
                                        Text(finding.title)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                        let linkedCount = model.annotations.count(where: {
                                            $0.findingIDs.contains(finding.id)
                                        })
                                        if linkedCount > 0 {
                                            Label("\(linkedCount)", systemImage: "link")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                                .labelStyle(.titleAndIcon)
                                                .accessibilityLabel(
                                                    "\(linkedCount) linked "
                                                        + (linkedCount == 1
                                                            ? "annotation"
                                                            : "annotations")
                                                )
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    "\(finding.severity.rawValue) finding: \(finding.title)"
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }

                if !model.annotations.isEmpty {
                    Divider()

                    AnalysisAnnotationList(
                        annotations: model.annotations,
                        selectedAnnotationID: $selectedAnnotationID,
                        isReadOnly: model.sourceChanged,
                        onSetVisible: model.setPhotoAnnotationVisible,
                        onSetAllVisible: model.setAllPhotoAnnotationsVisible,
                        onEdit: presentPhotoAnnotationEditor,
                        onDelete: { annotationID in
                            model.removeAnnotation(id: annotationID)
                            if selectedAnnotationID == annotationID {
                                self.selectedAnnotationID = nil
                            }
                        }
                    )
                }

                Divider()

                AnalysisCaseNotesView(
                    observations: model.observations,
                    isReadOnly: model.sourceChanged,
                    onAdd: { isObservationEditorPresented = true },
                    onDelete: model.removeObservation
                )
            }
            Spacer()
        }
        .padding(14)
    }

    private func sourcePreview(showMarkupToolbar: Bool) -> some View {
        VStack(spacing: 10) {
            if pixelViewMode != .normal {
                Text(pixelViewMode.methodLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel("Pixel view method: \(pixelViewMode.methodLabel)")
            }

            if let limitation = pixelViewMode.limitationLabel {
                Label(limitation, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Compression residual limitation: \(limitation)")
            }

            AnalysisSourceThumbnail(
                url: model.sourceURL,
                representation: model.displayPreference,
                pixelViewMode: pixelViewMode,
                developSettings: model.developSettings,
                sourceOrientation: model.sourceOrientation,
                displayTransform: model.displayTransform,
                annotationTransform: model.annotationTransform,
                inspectionSample: $pixelInspectionSample,
                scopeSourceMode: scopeSourceMode,
                selectedScopeRegion: $selectedScopeRegion,
                annotations: model.annotations,
                annotationTool: photoAnnotationTool,
                annotationStyle: annotationStyle,
                selectedAnnotationID: $selectedAnnotationID,
                annotationsAreReadOnly: model.sourceChanged,
                thumbnailService: thumbnailService,
                polygonFinishRequestID: photoPolygonFinishRequestID,
                polygonCancelRequestID: photoPolygonCancelRequestID,
                onPolygonDraftCountChanged: { photoPolygonDraftCount = $0 },
                onImageLoaded: { displayedScopeImage = $0 },
                onSetAnnotation: model.setAnnotation,
                onEditAnnotation: presentPhotoAnnotationEditor,
                onRemoveAnnotation: model.removeAnnotation
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showMarkupToolbar {
                AnalysisAnnotationToolbar(
                    tool: $photoAnnotationTool,
                    style: $annotationStyle,
                    selectedAnnotationID: selectedAnnotationID,
                    isReadOnly: model.sourceChanged,
                    canUndo: model.canUndoPhotoAnnotation,
                    canRedo: model.canRedoPhotoAnnotation,
                    undoActionName: model.photoAnnotationUndoActionName,
                    redoActionName: model.photoAnnotationRedoActionName,
                    onUndo: model.undoPhotoAnnotation,
                    onRedo: model.redoPhotoAnnotation,
                    canCalibrate: selectedDistanceAnnotation != nil,
                    selectedIsCalibration: selectedDistanceAnnotation?.measurementCalibration != nil,
                    onCalibrate: presentCalibrationEditor,
                    onDelete: {
                        guard let selectedAnnotationID else { return }
                        model.removeAnnotation(id: selectedAnnotationID)
                        self.selectedAnnotationID = nil
                    },
                    canEditLabel: selectedAnnotationID != nil,
                    selectedHasLabel: selectedPhotoAnnotation?.text?
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                    photoFinishActionTitle: photoPolygonDraftCount >= 3
                        ? "Finish Polygon"
                        : nil,
                    photoDraftIsActive: photoPolygonDraftCount > 0,
                    onPhotoFinishAction: { photoPolygonFinishRequestID += 1 },
                    onCancelPhotoDraft: { photoPolygonCancelRequestID += 1 },
                    onEditLabel: presentAnnotationLabelEditor
                )
            }

            PixelInspectionReadout(sample: pixelInspectionSample)
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var selectedDistanceAnnotation: AnalysisAnnotation? {
        guard let selectedAnnotationID else { return nil }
        return model.annotations.first {
            $0.id == selectedAnnotationID && $0.kind == .distance
        }
    }

    private var selectedPhotoAnnotation: AnalysisAnnotation? {
        guard let selectedAnnotationID else { return nil }
        return model.annotations.first { $0.id == selectedAnnotationID }
    }

    private var selectedMapAnnotation: AnalysisMapAnnotation? {
        guard let selectedMapAnnotationID else { return nil }
        if mapLayerScope == .workingFolder {
            return model.globalMapAnnotations.first {
                $0.id == selectedMapAnnotationID
            }?.annotation
        }
        return model.mapAnnotations.first { $0.id == selectedMapAnnotationID }
    }

    private var activeSelectedAnnotationID: UUID? {
        switch activeMarkupSurface {
        case .photo: selectedPhotoAnnotation?.id
        case .map: selectedMapAnnotation?.id
        }
    }

    private var activeSelectedAnnotationHasDetails: Bool {
        switch activeMarkupSurface {
        case .photo:
            let label = selectedPhotoAnnotation?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let note = selectedPhotoAnnotation?.note?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return label?.isEmpty == false || note?.isEmpty == false
        case .map:
            return selectedMapAnnotation?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private func presentCalibrationEditor() {
        guard let annotation = selectedDistanceAnnotation else { return }
        let pixelLength = model.annotationTransform.flatMap {
            AnalysisSourcePixelMeasurement(
                annotation: annotation,
                annotationTransform: $0
            )?.formattedLength
        }
        calibrationEditorRequest = AnalysisCalibrationEditorRequest(
            annotationID: annotation.id,
            existingCalibration: annotation.measurementCalibration,
            sourcePixelLength: pixelLength
        )
    }

    private func deleteActiveAnnotation() {
        switch activeMarkupSurface {
        case .photo:
            guard let selectedAnnotationID else { return }
            model.removeAnnotation(id: selectedAnnotationID)
            self.selectedAnnotationID = nil
        case .map:
            guard let selectedMapAnnotationID else { return }
            if mapLayerScope == .workingFolder {
                model.removeGlobalMapAnnotation(id: selectedMapAnnotationID)
            } else {
                model.removeMapAnnotation(id: selectedMapAnnotationID)
            }
            self.selectedMapAnnotationID = nil
        }
    }

    private func presentAnnotationLabelEditor() {
        switch activeMarkupSurface {
        case .photo:
            guard let annotation = selectedPhotoAnnotation else { return }
            annotationLabelEditorRequest = AnalysisAnnotationLabelEditorRequest(
                surface: .photo,
                annotationID: annotation.id,
                annotationName: annotation.kind.displayName,
                existingLabel: annotation.text,
                existingNote: annotation.note,
                allowsRemoval: annotation.kind != .label
            )
        case .map:
            guard let annotation = selectedMapAnnotation else { return }
            annotationLabelEditorRequest = AnalysisAnnotationLabelEditorRequest(
                surface: .map,
                annotationID: annotation.id,
                annotationName: annotation.kind.displayName,
                existingLabel: annotation.text,
                existingNote: nil,
                allowsRemoval: annotation.kind != .label
            )
        }
    }

    private func presentPhotoAnnotationEditor(_ annotationID: UUID) {
        guard let annotation = model.annotations.first(where: { $0.id == annotationID }) else {
            return
        }
        activeMarkupSurface = .photo
        selectedAnnotationID = annotation.id
        selectedMapAnnotationID = nil
        annotationLabelEditorRequest = AnalysisAnnotationLabelEditorRequest(
            surface: .photo,
            annotationID: annotation.id,
            annotationName: annotation.kind.displayName,
            existingLabel: annotation.text,
            existingNote: annotation.note,
            allowsRemoval: annotation.kind != .label
        )
    }

    private func presentMapAnnotationEditor(_ annotationID: UUID) {
        let annotation = mapLayerScope == .workingFolder
            ? model.globalMapAnnotations.first(where: { $0.id == annotationID })?.annotation
            : model.mapAnnotations.first(where: { $0.id == annotationID })
        guard let annotation else {
            return
        }
        activeMarkupSurface = .map
        selectedMapAnnotationID = annotation.id
        selectedAnnotationID = nil
        annotationLabelEditorRequest = AnalysisAnnotationLabelEditorRequest(
            surface: .map,
            annotationID: annotation.id,
            annotationName: annotation.kind.displayName,
            existingLabel: annotation.text,
            existingNote: nil,
            allowsRemoval: annotation.kind != .label
        )
    }

    private func setSelectedAnnotationDetails(label: String?, note: String?) {
        guard let request = annotationLabelEditorRequest else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedLabel = trimmed?.isEmpty == false ? trimmed : nil
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedNote = trimmedNote?.isEmpty == false ? trimmedNote : nil
        guard request.allowsRemoval || storedLabel != nil else { return }

        switch request.surface {
        case .photo:
            guard var annotation = model.annotations.first(where: {
                $0.id == request.annotationID
            }) else { return }
            annotation.text = storedLabel
            annotation.note = storedNote
            model.setAnnotation(annotation)
        case .map:
            let existing = mapLayerScope == .workingFolder
                ? model.globalMapAnnotations.first(where: {
                    $0.id == request.annotationID
                })?.annotation
                : model.mapAnnotations.first(where: { $0.id == request.annotationID })
            guard var annotation = existing else { return }
            annotation.text = storedLabel
            if mapLayerScope == .workingFolder {
                model.setGlobalMapAnnotation(annotation)
            } else {
                model.setMapAnnotation(annotation)
            }
        }
    }

    @ViewBuilder
    private var analysisDetail: some View {
        VStack(spacing: 0) {
            Group {
                if let selectedFindingID,
                   let finding = model.findings.first(where: { $0.id == selectedFindingID }) {
                    FindingDetailView(
                        finding: finding,
                        annotations: model.annotations,
                        isReadOnly: model.sourceChanged,
                        onReportInclusionChanged: { included in
                            model.setFindingIncluded(finding.id, included: included)
                        },
                        onAnnotationLinkChanged: { annotationID, isLinked in
                            model.setFindingLink(
                                findingID: finding.id,
                                annotationID: annotationID,
                                isLinked: isLinked
                            )
                        },
                        onSelectAnnotation: { annotationID in
                            photoAnnotationTool = .select
                            selectedAnnotationID = annotationID
                        }
                    )
                } else {
                    SourceFactsDetailView(
                        facts: model.sourceFacts,
                        rawMetadata: model.rawMetadata,
                        run: model.sourceFactsRun,
                        onCancel: {
                            if let id = model.sourceFactsRun?.analyzerID {
                                model.cancelAnalyzer(id)
                            }
                        },
                        onRetry: {
                            if let id = model.sourceFactsRun?.analyzerID {
                                model.retryAnalyzer(id)
                            }
                        }
                    )
                }
            }
            .frame(maxHeight: .infinity)

            if let hash = model.analysisCase?.source.sha256 {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("SOURCE SHA-256")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(hash)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Source SHA-256 \(hash)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private var analyzerStatusAccessory: some View {
        if let run = model.sourceFactsRun {
            switch run.status {
            case .queued, .running:
                ProgressView(value: run.progress)
                    .controlSize(.small)
                    .frame(width: 42)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .cancelled:
                Image(systemName: "stop.circle")
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func severityIcon(_ severity: AnalysisFindingSeverity) -> String {
        switch severity {
        case .informational: "info.circle"
        case .notable: "exclamationmark.circle"
        case .caution: "exclamationmark.triangle.fill"
        }
    }

    private func severityColor(_ severity: AnalysisFindingSeverity) -> Color {
        switch severity {
        case .informational: .secondary
        case .notable: .yellow
        case .caution: .orange
        }
    }
}

private struct AnalysisReportExportSheet: View {
    let hasSelectedEvidenceCrop: Bool
    let onExport: (AnalysisReportExportOptions) -> Void
    let onCancel: () -> Void

    @State private var pageFormat: AnalysisReportPageFormat = .a4
    @State private var includeSelectedEvidenceCrop = true
    @State private var includeCanonicalPath = false
    @State private var includeCameraSerialNumber = false
    @State private var includeLocationCoordinates = true
    @State private var includeRawMetadata = true
    @State private var mapBasemap: AnalysisReportMapBasemap = .openStreetMap

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Export Analysis Report", systemImage: "doc.richtext")
                    .font(.title2.weight(.semibold))
                Text("The source will be re-hashed before a frozen report snapshot is rendered.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                Picker("Paper size", selection: $pageFormat) {
                    ForEach(AnalysisReportPageFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                Picker("Map background", selection: $mapBasemap) {
                    ForEach(AnalysisReportMapBasemap.allCases, id: \.self) { basemap in
                        Text(basemap.displayName).tag(basemap)
                    }
                }

                Section("Pixel evidence") {
                    Toggle(
                        "Include selected source-pixel region",
                        isOn: $includeSelectedEvidenceCrop
                    )
                    .disabled(!hasSelectedEvidenceCrop)
                    if hasSelectedEvidenceCrop {
                        Text("The selected region is embedded at 1:1 source-pixel extraction with no interpolation and captioned with its exact bounds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Choose Original, switch Scopes to Selected Region, and drag a region to include a true-pixel crop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Sensitive fields") {
                    Toggle("Canonical source path", isOn: $includeCanonicalPath)
                    Toggle("Camera serial number", isOn: $includeCameraSerialNumber)
                    Toggle("Exact location coordinates and live map link", isOn: $includeLocationCoordinates)
                    Toggle("Raw metadata appendix", isOn: $includeRawMetadata)
                }
            }
            .formStyle(.grouped)

            Label(
                "Review the selected fields before sharing. Paths, serial numbers, coordinates, and raw metadata can identify a person, device, or location.",
                systemImage: "exclamationmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Choose Destination…") {
                    onExport(AnalysisReportExportOptions(
                        pageFormat: pageFormat,
                        includeSelectedEvidenceCrop: includeSelectedEvidenceCrop
                            && hasSelectedEvidenceCrop,
                        includeCanonicalPath: includeCanonicalPath,
                        includeCameraSerialNumber: includeCameraSerialNumber,
                        includeLocationCoordinates: includeLocationCoordinates,
                        includeRawMetadata: includeRawMetadata,
                        mapBasemap: mapBasemap
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

private struct AnalysisAnnotationList: View {
    let annotations: [AnalysisAnnotation]
    @Binding var selectedAnnotationID: UUID?
    let isReadOnly: Bool
    let onSetVisible: (UUID, Bool) -> Void
    let onSetAllVisible: (Bool) -> Void
    let onEdit: (UUID) -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ANNOTATIONS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Menu {
                    Button("Show All") { onSetAllVisible(true) }
                        .disabled(isReadOnly || annotations.allSatisfy(\.isVisible))
                    Button("Hide All") { onSetAllVisible(false) }
                        .disabled(isReadOnly || annotations.allSatisfy({ !$0.isVisible }))
                } label: {
                    Label("Layer Visibility", systemImage: "eye")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isReadOnly)
                .help("Show or hide all photo-annotation layers")
            }

            List(selection: $selectedAnnotationID) {
                ForEach(Array(annotations.enumerated()), id: \.element.id) { index, annotation in
                    HStack(spacing: 7) {
                        Image(systemName: annotation.kind.systemImage)
                            .frame(width: 14)
                            .foregroundStyle(annotation.style.color.swiftUIColor)
                            .accessibilityHidden(true)

                        Text(annotation.listName(index: index))
                            .lineLimit(1)

                        if let calibration = annotation.measurementCalibration {
                            Text("CAL \(calibration.formattedKnownLength)")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityLabel(
                                    "Measurement calibration, \(calibration.formattedKnownLength)"
                                )
                        }

                        if !annotation.findingIDs.isEmpty {
                            Label("\(annotation.findingIDs.count)", systemImage: "link")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                                .accessibilityLabel(
                                    "\(annotation.findingIDs.count) linked "
                                        + (annotation.findingIDs.count == 1
                                            ? "finding"
                                            : "findings")
                                )
                        }

                        Spacer(minLength: 2)

                        Button {
                            onSetVisible(annotation.id, !annotation.isVisible)
                        } label: {
                            Image(systemName: annotation.isVisible ? "eye" : "eye.slash")
                                .foregroundStyle(annotation.isVisible ? .secondary : .tertiary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isReadOnly)
                        .help(annotation.isVisible ? "Hide annotation" : "Show annotation")
                        .accessibilityLabel(
                            annotation.isVisible
                                ? "Hide \(annotation.listName(index: index))"
                                : "Show \(annotation.listName(index: index))"
                        )
                    }
                    .tag(annotation.id)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(
                        "\(annotation.listName(index: index)), "
                            + (annotation.isVisible ? "visible" : "hidden")
                    )
                    .contextMenu {
                        Button("Rename / Add Note…") {
                            onEdit(annotation.id)
                        }
                        .disabled(isReadOnly)

                        Divider()

                        Button("Delete Photo Annotation", role: .destructive) {
                            onDelete(annotation.id)
                        }
                        .disabled(isReadOnly)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 90, idealHeight: 150, maxHeight: 210)
            .onDeleteCommand {
                guard !isReadOnly, let selectedAnnotationID else { return }
                onDelete(selectedAnnotationID)
            }
            .accessibilityLabel("Photo annotation layers")
        }
    }
}

private struct AnalysisCaseNotesView: View {
    let observations: [AnalysisObservation]
    let isReadOnly: Bool
    let onAdd: () -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("CASE NOTES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Note", systemImage: "plus", action: onAdd)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(isReadOnly)
                    .help("Add a case-only note; IPTC metadata is not changed")
            }

            if observations.isEmpty {
                Text("Add general analysis notes here. Notes remain in the case and do not alter IPTC metadata.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(observations) { observation in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(observation.title)
                                    .font(.caption.weight(.semibold))
                                Text(observation.note)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(7)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                            .contextMenu {
                                Button("Delete Note", role: .destructive) {
                                    onDelete(observation.id)
                                }
                                .disabled(isReadOnly)
                            }
                        }
                    }
                }
                .frame(minHeight: 55, idealHeight: 110, maxHeight: 150)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("General case notes")
    }
}

private struct AnalysisTimelineView: View {
    let evidence: [AnalysisTimestampEvidence]
    let observations: [AnalysisObservation]
    let conflicts: [AnalysisTimestampConflict]
    let isReadOnly: Bool
    let onAddTimed: () -> Void
    let onAddNote: () -> Void
    let onDeleteTimestamp: (UUID) -> Void
    let onDeleteObservation: (UUID) -> Void
    @State private var expandedEvidenceIDs: Set<UUID> = []
    @State private var expandedObservationIDs: Set<UUID> = []

    private var conflictedIDs: Set<UUID> {
        conflicts.reduce(into: Set<UUID>()) { result, conflict in
            result.formUnion(conflict.evidenceIDs)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Evidence & Observations", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("Timed Observation", systemImage: "clock.badge", action: onAddTimed)
                    Button("Note Without Time", systemImage: "note.text.badge.plus", action: onAddNote)
                } label: {
                    Label("Add Observation", systemImage: "plus")
                }
                .disabled(isReadOnly)
                .help("Add a case-only timed observation or note")
            }

            if !conflicts.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(conflicts) { conflict in
                            Label(conflict.explanation, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                        }
                    }
                    .padding(.top, 5)
                } label: {
                    Text("\(conflicts.count) timestamp \(conflicts.count == 1 ? "conflict" : "conflicts")")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .accessibilityLabel("Timestamp conflicts")
            }

            if evidence.isEmpty, observations.isEmpty {
                ContentUnavailableView(
                    "No Evidence or Observations",
                    systemImage: "note.text",
                    description: Text("Add a timed observation or a note without time.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(evidence) { item in
                            timestampRow(item)
                        }
                        ForEach(observations) { observation in
                            observationRow(observation)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }

            Text("Case observations never write IPTC metadata. Expand a row for provenance and details.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Evidence and observations")
    }

    private func timestampRow(_ item: AnalysisTimestampEvidence) -> some View {
        let conflicted = conflictedIDs.contains(item.id)
        return DisclosureGroup(
            isExpanded: expansionBinding(for: item.id, in: $expandedEvidenceIDs)
        ) {
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("Source", value: item.source.displayName)
                LabeledContent("Precision", value: item.value.precision.displayName)
                LabeledContent(
                    "Timezone",
                    value: item.value.timezoneKnown ? "Known" : "Unknown"
                )
                Text(item.sourceDetail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if item.source == .userEntered {
                    Button("Delete Timed Observation", role: .destructive) {
                        onDeleteTimestamp(item.id)
                    }
                    .disabled(isReadOnly)
                }
            }
            .font(.caption)
            .padding(.top, 5)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: item.kind))
                    .frame(width: 15)
                    .foregroundStyle(conflicted ? Color.orange : Color.secondary)
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(item.value.formatted)
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                if conflicted {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Conflicting timestamp")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(conflicted ? Color.orange.opacity(0.10) : Color.secondary.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(conflicted ? Color.orange.opacity(0.65) : Color.clear, lineWidth: 1)
        }
    }

    private func observationRow(_ observation: AnalysisObservation) -> some View {
        DisclosureGroup(
            isExpanded: expansionBinding(for: observation.id, in: $expandedObservationIDs)
        ) {
            VStack(alignment: .leading, spacing: 7) {
                Text(observation.note)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent(
                    "Added",
                    value: observation.createdAt.formatted(date: .abbreviated, time: .shortened)
                )
                Button("Delete Note", role: .destructive) {
                    onDeleteObservation(observation.id)
                }
                .disabled(isReadOnly)
            }
            .font(.caption)
            .padding(.top, 5)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .frame(width: 15)
                    .foregroundStyle(.secondary)
                Text(observation.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("No time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func expansionBinding(
        for id: UUID,
        in ids: Binding<Set<UUID>>
    ) -> Binding<Bool> {
        Binding(
            get: { ids.wrappedValue.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    ids.wrappedValue.insert(id)
                } else {
                    ids.wrappedValue.remove(id)
                }
            }
        )
    }

    private func icon(for kind: AnalysisTimestampKind) -> String {
        switch kind {
        case .capture: "camera"
        case .gps: "location"
        case .fileCreation: "doc.badge.plus"
        case .fileModification: "doc.badge.clock"
        case .sidecarModification: "doc.text"
        case .observation: "person.crop.circle.badge.clock"
        }
    }
}

private struct AnalysisMapLayersView: View {
    let annotations: [AnalysisMapAnnotation]
    let globalAnnotations: [AnalysisGlobalMapAnnotation]
    let photoAnnotations: [AnalysisAnnotation]
    let folderAnnotations: [AnalysisImageMapAnnotation]
    let currentCaseID: UUID?
    @Binding var scope: AnalysisMapLayerScope
    @Binding var selectedPhotoAnnotationID: UUID?
    @Binding var selectedAnnotationID: UUID?
    let isReadOnly: Bool
    let onSetPhotoVisible: (UUID, Bool) -> Void
    let onSetAllPhotosVisible: (Bool) -> Void
    let onEditPhotoAnnotation: (UUID) -> Void
    let onDeletePhotoAnnotation: (UUID) -> Void
    let onSetVisible: (UUID, Bool) -> Void
    let onSetAllVisible: (Bool) -> Void
    let onEditMapAnnotation: (UUID) -> Void
    let onDeleteMapAnnotation: (UUID) -> Void
    let onSetPhotoAnnotationLink: (UUID, UUID?) -> Void
    let onSetGlobalVisible: (UUID, Bool) -> Void
    let onSetAllGlobalsVisible: (Bool) -> Void
    let onEditGlobalAnnotation: (UUID) -> Void
    let onDeleteGlobalAnnotation: (UUID) -> Void
    let onSetGlobalPhotoAnnotationLink: (UUID, UUID, Bool) -> Void
    let onCopyToGlobal: (UUID) -> Void
    let onCopyToCurrentPhoto: (UUID) -> Void

    var body: some View {
        HSplitView {
            photoAnnotationsPane
                .frame(minWidth: 240)
            mapAnnotationsPane
                .frame(minWidth: 300)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo and map annotations")
    }

    private var photoAnnotationsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Photo Annotations", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                Spacer()
                Button("Show All") { onSetAllPhotosVisible(true) }
                    .disabled(isReadOnly || photoAnnotations.allSatisfy(\.isVisible))
                Button("Hide All") { onSetAllPhotosVisible(false) }
                    .disabled(isReadOnly || photoAnnotations.allSatisfy({ !$0.isVisible }))
            }

            if photoAnnotations.isEmpty {
                ContentUnavailableView(
                    "No Photo Annotations",
                    systemImage: "photo.badge.plus",
                    description: Text("Use the Photo tools above to mark visible evidence.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(Array(photoAnnotations.enumerated().reversed()), id: \.element.id) {
                            index, annotation in
                            photoLayerRow(annotation, index: index)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo annotations")
    }

    private var mapAnnotationsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Map Annotations", systemImage: "square.3.layers.3d")
                        .font(.headline)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()

                    Button("Show All") {
                        scope == .currentPhoto
                            ? onSetAllVisible(true)
                            : onSetAllGlobalsVisible(true)
                    }
                    .disabled(isReadOnly || displayedMapAnnotations.allSatisfy(\.isVisible))
                    Button("Hide All") {
                        scope == .currentPhoto
                            ? onSetAllVisible(false)
                            : onSetAllGlobalsVisible(false)
                    }
                    .disabled(isReadOnly || displayedMapAnnotations.allSatisfy({ !$0.isVisible }))
                }

                Picker("Layer Scope", selection: $scope) {
                    ForEach(AnalysisMapLayerScope.allCases, id: \.self) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
            }

            if displayedAnnotationsAreEmpty {
                ContentUnavailableView(
                    "No Map Markup",
                    systemImage: "map",
                    description: Text(
                        scope == .currentPhoto
                            ? "Use the Map tools above, or place a selected photo object from the map."
                            : "Use the Map tools above to add a map layer shared by this working folder."
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        if scope == .currentPhoto {
                            ForEach(Array(annotations.enumerated().reversed()), id: \.element.id) {
                                index, annotation in
                                mapLayerRow(annotation, index: index)
                            }
                        } else {
                            ForEach(Array(globalAnnotations.enumerated().reversed()), id: \.element.id) {
                                index, globalAnnotation in
                                globalMapLayerRow(globalAnnotation, index: index)
                            }
                            if !folderAnnotations.isEmpty {
                                Text("PHOTO-LOCAL CONTEXT")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(Array(folderAnnotations.reversed())) { item in
                                    folderLayerRow(item)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map annotations")
    }

    private func photoLayerRow(_ annotation: AnalysisAnnotation, index: Int) -> some View {
        HStack(spacing: 8) {
            Button {
                selectedPhotoAnnotationID = annotation.id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: annotation.kind.systemImage)
                        .frame(width: 15)
                        .foregroundStyle(annotation.style.color.swiftUIColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(annotation.listName(index: index))
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if let note = annotation.note {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onEditPhotoAnnotation(annotation.id)
            } label: {
                Image(systemName: annotation.note == nil && annotation.text == nil ? "note.text.badge.plus" : "note.text")
            }
            .buttonStyle(.borderless)
            .disabled(isReadOnly)
            .help("Edit this photo annotation's label and note")

            Button {
                onSetPhotoVisible(annotation.id, !annotation.isVisible)
            } label: {
                Image(systemName: annotation.isVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .disabled(isReadOnly)
            .help(annotation.isVisible ? "Hide photo annotation" : "Show photo annotation")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    selectedPhotoAnnotationID == annotation.id
                        ? Color.accentColor.opacity(0.16)
                        : Color.secondary.opacity(0.08)
                )
        )
        .contextMenu {
            Button("Rename…") {
                onEditPhotoAnnotation(annotation.id)
            }
            .disabled(isReadOnly)
            Divider()
            Button("Delete Photo Annotation", role: .destructive) {
                onDeletePhotoAnnotation(annotation.id)
                if selectedPhotoAnnotationID == annotation.id {
                    selectedPhotoAnnotationID = nil
                }
            }
            .disabled(isReadOnly)
        }
    }

    private var displayedAnnotationsAreEmpty: Bool {
        scope == .currentPhoto ? annotations.isEmpty : globalAnnotations.isEmpty
    }

    private var displayedMapAnnotations: [AnalysisMapAnnotation] {
        scope == .currentPhoto ? annotations : globalAnnotations.map(\.annotation)
    }

    private func folderLayerRow(_ item: AnalysisImageMapAnnotation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: item.annotation.kind))
                .frame(width: 15)
                .foregroundStyle(item.annotation.style.color.swiftUIColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.annotation.text ?? item.annotation.kind.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Label(item.sourceName, systemImage: "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: item.annotation.isVisible ? "eye" : "eye.slash")
                .foregroundStyle(.secondary)
                .accessibilityLabel(item.annotation.isVisible ? "Visible" : "Hidden")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .help("Open \(item.sourceName) to edit this layer")
    }

    private func globalMapLayerRow(
        _ globalAnnotation: AnalysisGlobalMapAnnotation,
        index: Int
    ) -> some View {
        let annotation = globalAnnotation.annotation
        return HStack(spacing: 8) {
            Button {
                selectedAnnotationID = annotation.id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: annotation.kind))
                        .frame(width: 15)
                        .foregroundStyle(annotation.style.color.swiftUIColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(layerName(annotation, index: index))
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Label(
                            "\(globalAnnotation.photoAnnotationReferences.count) linked photo "
                                + (globalAnnotation.photoAnnotationReferences.count == 1
                                    ? "annotation"
                                    : "annotations"),
                            systemImage: "link"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                if photoAnnotations.isEmpty {
                    Text("Annotate an object in this photo first")
                } else {
                    ForEach(Array(photoAnnotations.enumerated()), id: \.element.id) {
                        photoIndex, photoAnnotation in
                        let isLinked = isCurrentPhotoAnnotationLinked(
                            photoAnnotation.id,
                            to: globalAnnotation
                        )
                        Toggle(
                            photoAnnotation.listName(index: photoIndex),
                            isOn: Binding(
                                get: { isLinked },
                                set: { linked in
                                    onSetGlobalPhotoAnnotationLink(
                                        annotation.id,
                                        photoAnnotation.id,
                                        linked
                                    )
                                }
                            )
                        )
                    }
                }
            } label: {
                Image(systemName: globalAnnotation.photoAnnotationReferences.isEmpty
                    ? "link.badge.plus"
                    : "link")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isReadOnly)
            .help("Connect this folder map annotation to one or more objects in this photo")

            Button {
                onSetGlobalVisible(annotation.id, !annotation.isVisible)
            } label: {
                Image(systemName: annotation.isVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .disabled(isReadOnly)
            .help(annotation.isVisible ? "Hide folder map annotation" : "Show folder map annotation")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    selectedAnnotationID == annotation.id
                        ? Color.accentColor.opacity(0.16)
                        : Color.secondary.opacity(0.08)
                )
        )
        .contextMenu {
            Button("Copy to This Photo's Map") {
                onCopyToCurrentPhoto(annotation.id)
            }
            .disabled(isReadOnly)
            Divider()
            Button("Rename…") { onEditGlobalAnnotation(annotation.id) }
                .disabled(isReadOnly)
            Divider()
            Button("Delete Folder Map Layer", role: .destructive) {
                onDeleteGlobalAnnotation(annotation.id)
                if selectedAnnotationID == annotation.id {
                    selectedAnnotationID = nil
                }
            }
            .disabled(isReadOnly)
        }
    }

    private func isCurrentPhotoAnnotationLinked(
        _ photoAnnotationID: UUID,
        to globalAnnotation: AnalysisGlobalMapAnnotation
    ) -> Bool {
        guard let currentCaseID else { return false }
        return globalAnnotation.photoAnnotationReferences.contains(
            AnalysisPhotoAnnotationReference(
                caseID: currentCaseID,
                annotationID: photoAnnotationID
            )
        )
    }

    private func mapLayerRow(_ annotation: AnalysisMapAnnotation, index: Int) -> some View {
        HStack(spacing: 8) {
            Button {
                selectedAnnotationID = annotation.id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: annotation.kind))
                        .frame(width: 15)
                        .foregroundStyle(annotation.style.color.swiftUIColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(layerName(annotation, index: index))
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if let linkedName = linkedPhotoAnnotationName(annotation) {
                            Label("Photo: \(linkedName)", systemImage: "link")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("No Photo Link") {
                    onSetPhotoAnnotationLink(annotation.id, nil)
                }
                .disabled(annotation.linkedPhotoLabelID == nil)
                Divider()
                if photoAnnotations.isEmpty {
                    Text("Annotate an object in the photo first")
                } else {
                    ForEach(Array(photoAnnotations.enumerated()), id: \.element.id) {
                        photoIndex, photoAnnotation in
                        Button {
                            onSetPhotoAnnotationLink(annotation.id, photoAnnotation.id)
                        } label: {
                            if annotation.linkedPhotoLabelID == photoAnnotation.id {
                                Label(photoAnnotation.listName(index: photoIndex), systemImage: "checkmark")
                            } else {
                                Text(photoAnnotation.listName(index: photoIndex))
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: annotation.linkedPhotoLabelID == nil ? "link.badge.plus" : "link")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isReadOnly)
            .help("Connect this map annotation to an object annotated in the photo")

            Button {
                onSetVisible(annotation.id, !annotation.isVisible)
            } label: {
                Image(systemName: annotation.isVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .disabled(isReadOnly)
            .help(annotation.isVisible ? "Hide map annotation" : "Show map annotation")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    selectedAnnotationID == annotation.id
                        ? Color.accentColor.opacity(0.16)
                        : Color.secondary.opacity(0.08)
                )
        )
        .contextMenu {
            Button("Copy to Global Map") {
                onCopyToGlobal(annotation.id)
            }
            .disabled(isReadOnly)
            Divider()
            Button("Rename…") {
                onEditMapAnnotation(annotation.id)
            }
            .disabled(isReadOnly)
            Divider()
            Button("Delete Map Layer", role: .destructive) {
                onDeleteMapAnnotation(annotation.id)
                if selectedAnnotationID == annotation.id {
                    selectedAnnotationID = nil
                }
            }
            .disabled(isReadOnly)
        }
    }

    private func layerName(_ annotation: AnalysisMapAnnotation, index: Int) -> String {
        if let text = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return "\(annotation.kind.displayName) \(index + 1)"
    }

    private func linkedPhotoAnnotationName(_ annotation: AnalysisMapAnnotation) -> String? {
        guard let id = annotation.linkedPhotoLabelID,
              let index = photoAnnotations.firstIndex(where: { $0.id == id }) else { return nil }
        return photoAnnotations[index].listName(index: index)
    }

    private func icon(for kind: AnalysisMapAnnotationKind) -> String {
        switch kind {
        case .marker: "mappin"
        case .line: "line.diagonal"
        case .shape: "pentagon"
        case .distance: "ruler"
        case .label: "character.cursor.ibeam"
        }
    }
}

private struct AnalysisTimestampEditor: View {
    let onSave: (AnalysisTimestampEvidence) -> Void
    let onCancel: () -> Void
    @State private var title = "Observed time"
    @State private var selectedDate = Date()
    @State private var precision: AnalysisTimestampPrecision = .minute
    @State private var timezoneKnown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Time Observation")
                .font(.headline)

            Text("Record an investigator-supplied time separately from embedded and file-system evidence.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Observation label", text: $title)
                .textFieldStyle(.roundedBorder)

            DatePicker(
                "Observed date and time",
                selection: $selectedDate,
                displayedComponents: precision == .day ? [.date] : [.date, .hourAndMinute]
            )

            Picker("Precision", selection: $precision) {
                Text(AnalysisTimestampPrecision.day.displayName)
                    .tag(AnalysisTimestampPrecision.day)
                Text(AnalysisTimestampPrecision.minute.displayName)
                    .tag(AnalysisTimestampPrecision.minute)
            }
            .pickerStyle(.segmented)

            Toggle("The current Mac timezone applies", isOn: $timezoneKnown)
                .help("Leave off when the timezone for this observation is not established")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onSave(makeEvidence())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 430)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add time observation")
    }

    private func makeEvidence() -> AnalysisTimestampEvidence {
        var value = AnalysisTimestampValue(
            date: selectedDate,
            precision: precision,
            timeZone: .current
        )
        if precision == .day {
            value.hour = 0
            value.minute = 0
            value.second = 0
            value.nanosecond = 0
        } else {
            value.second = 0
            value.nanosecond = 0
        }
        if !timezoneKnown {
            value.utcOffsetMinutes = nil
        }
        return AnalysisTimestampEvidence(
            kind: .observation,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            value: value,
            source: .userEntered,
            sourceDetail: "Entered in this analysis case"
        )
    }
}

private struct AnalysisObservationEditor: View {
    let onSave: (AnalysisObservation) -> Void
    let onCancel: () -> Void
    @State private var title = "Observation"
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Note Without Time")
                .font(.headline)

            Text("Record a case-only observation when no date or time can be established.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Observation title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $note)
                .font(.body)
                .frame(minHeight: 130)
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                )
                .accessibilityLabel("Observation note")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onSave(AnalysisObservation(
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        note: note.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add note without time")
    }
}

private struct AnalysisImageRail: View {
    let images: [ImageFile]
    let selectedURL: URL?
    let thumbnailService: ThumbnailService
    let copiedAnnotationCount: Int
    let copiedAnnotationSourceName: String?
    let annotationCount: (ImageFile) -> Int
    let canPasteAnnotations: (ImageFile) -> Bool
    let onSelect: (ImageFile) -> Void
    let onCopyAnnotations: (ImageFile) -> Void
    let onPasteAnnotations: (ImageFile) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Label("Photos", systemImage: "photo.stack")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
                .padding(.top, 8)
                .help("Photos in the working folder")

            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(images) { image in
                        Button {
                            guard image.url != selectedURL else { return }
                            onSelect(image)
                        } label: {
                            AnalysisRailThumbnail(
                                image: image,
                                isSelected: image.url == selectedURL,
                                thumbnailService: thumbnailService
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            let count = annotationCount(image)
                            Button("Copy All Annotations", systemImage: "doc.on.doc") {
                                onCopyAnnotations(image)
                            }
                            .disabled(count == 0)

                            Button(
                                copiedAnnotationCount == 1
                                    ? "Paste 1 Annotation"
                                    : "Paste \(copiedAnnotationCount) Annotations",
                                systemImage: "doc.on.clipboard"
                            ) {
                                onPasteAnnotations(image)
                            }
                            .disabled(
                                copiedAnnotationCount == 0 || !canPasteAnnotations(image)
                            )

                            if let copiedAnnotationSourceName, copiedAnnotationCount > 0 {
                                Text("Copied from \(copiedAnnotationSourceName)")
                            }
                        }
                        .help(image.filename)
                        .accessibilityLabel(
                            image.url == selectedURL
                                ? "\(image.filename), current photo"
                                : "Open \(image.filename) in analysis"
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Working folder photos")
    }
}

private struct AnalysisRailThumbnail: View {
    let image: ImageFile
    let isSelected: Bool
    let thumbnailService: ThumbnailService
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.10))

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                    lineWidth: isSelected ? 3 : 0.5
                )
        }
        .task(id: image.url) {
            if let cached = thumbnailService.thumbnail(for: image.url) {
                thumbnail = cached
            } else {
                thumbnail = await thumbnailService.loadThumbnail(for: image.url)
            }
        }
    }
}

private enum AnalysisMarkupSurface: String {
    case photo
    case map

    var displayName: String { rawValue.capitalized }
}

private struct AnalysisAnnotationLabelEditorRequest: Identifiable {
    let surface: AnalysisMarkupSurface
    let annotationID: UUID
    let annotationName: String
    let existingLabel: String?
    let existingNote: String?
    let allowsRemoval: Bool

    var id: String { "\(surface.rawValue)-\(annotationID.uuidString)" }
}

private struct AnalysisAnnotationLabelEditor: View {
    let request: AnalysisAnnotationLabelEditorRequest
    let onSave: (String?, String?) -> Void
    let onCancel: () -> Void
    @State private var label: String
    @State private var note: String

    init(
        request: AnalysisAnnotationLabelEditorRequest,
        onSave: @escaping (String?, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _label = State(initialValue: request.existingLabel ?? "")
        _note = State(initialValue: request.existingNote ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Annotation Details")
                .font(.headline)

            Text(
                "Give this \(request.annotationName.lowercased()) a name so it can be identified "
                    + "and connected to map evidence."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextField("Annotation label", text: $label)
                .textFieldStyle(.roundedBorder)

            if request.surface == .photo {
                Text("Note")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .font(.body)
                    .frame(minHeight: 90)
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
                    .accessibilityLabel("Photo annotation note")
            }

            HStack {
                if request.allowsRemoval, request.existingLabel != nil {
                    Button("Remove Label", role: .destructive) {
                        onSave(nil, trimmedNote)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(
                        label.trimmingCharacters(in: .whitespacesAndNewlines),
                        trimmedNote
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !request.allowsRemoval
                        && label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 440)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Annotation details editor")
    }

    private var trimmedNote: String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct AnalysisCalibrationEditorRequest: Identifiable {
    let annotationID: UUID
    let existingCalibration: AnalysisMeasurementCalibration?
    let sourcePixelLength: String?

    var id: UUID { annotationID }
}

private struct AnalysisCalibrationEditor: View {
    let request: AnalysisCalibrationEditorRequest
    let onSave: (AnalysisMeasurementCalibration) -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    @State private var lengthText: String
    @State private var unit: AnalysisMeasurementUnit

    init(
        request: AnalysisCalibrationEditorRequest,
        onSave: @escaping (AnalysisMeasurementCalibration) -> Void,
        onRemove: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSave = onSave
        self.onRemove = onRemove
        self.onCancel = onCancel
        _lengthText = State(initialValue: request.existingCalibration.map {
            String($0.knownLength)
        } ?? "")
        _unit = State(initialValue: request.existingCalibration?.unit ?? .centimeters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.existingCalibration == nil ? "Calibrate Distance" : "Edit Calibration")
                .font(.headline)

            Text(
                "Enter the real-world length represented by this distance segment. "
                    + "Other distance annotations will use the same scale."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let sourcePixelLength = request.sourcePixelLength {
                LabeledContent("Segment length", value: sourcePixelLength)
                    .font(.callout.monospacedDigit())
            }

            HStack {
                TextField("Known length", text: $lengthText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 150)
                    .accessibilityLabel("Known real-world length")

                Picker("Unit", selection: $unit) {
                    ForEach(AnalysisMeasurementUnit.allCases) { unit in
                        Text(unit.displayName).tag(unit)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            HStack {
                if request.existingCalibration != nil {
                    Button("Remove Calibration", role: .destructive, action: onRemove)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let knownLength else { return }
                    onSave(AnalysisMeasurementCalibration(
                        knownLength: knownLength,
                        unit: unit
                    ))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(knownLength == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Measurement calibration editor")
    }

    private var knownLength: Double? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        let trimmed = lengthText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = formatter.number(from: trimmed)?.doubleValue
            ?? Double(trimmed.replacingOccurrences(of: ",", with: "."))
        guard let parsed, parsed.isFinite, parsed > 0 else { return nil }
        return parsed
    }
}

private extension AnalysisAnnotation {
    func listName(index: Int) -> String {
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return "\(kind.displayName) \(index + 1)"
    }
}

private extension AnalysisAnnotationKind {
    var displayName: String {
        switch self {
        case .line: "Line"
        case .arrow: "Arrow"
        case .distance: "Distance"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .polygon: "Polygon"
        case .label: "Label"
        }
    }

    var systemImage: String {
        switch self {
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .distance: "ruler"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .polygon: "pentagon"
        case .label: "character.cursor.ibeam"
        }
    }
}

private struct SourceFactsDetailView: View {
    let facts: AnalysisSourceFacts?
    let rawMetadata: [AnalysisRawMetadataEntry]
    let run: AnalysisAnalyzerRun?
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Source Facts", systemImage: "checkmark.shield")
                    .font(.headline)

                if let run, run.status == .queued || run.status == .running {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: run.progress)
                        HStack {
                            Text("Reading source evidence…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel", action: onCancel)
                        }
                    }
                } else if let run, run.status == .failed || run.status == .cancelled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(run.errorMessage ?? "Analysis was cancelled.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Run Again", action: onRetry)
                    }
                }

                if let facts {
                    factSection("FILE") {
                        factRow("Name", facts.filename)
                        factRow("Bytes", ByteCountFormatter.string(
                            fromByteCount: facts.byteCount,
                            countStyle: .file
                        ))
                        factRow("Container", facts.detectedMIMEType ?? facts.detectedTypeIdentifier ?? "Unknown")
                        factRow(
                            "Dimensions",
                            dimensions(width: facts.pixelWidth, height: facts.pixelHeight)
                        )
                        factRow("Bit depth", facts.bitDepth.map(String.init))
                        factRow("Color", facts.colorProfile)
                        factRow("Frames", String(facts.frameCount))
                        factRow("HDR", facts.isHDR ? "Detected" : "Not detected")
                    }

                    factSection("CAPTURE") {
                        factRow("Camera", facts.camera)
                        factRow("Lens", facts.lens)
                        factRow("Capture time", facts.captureDate)
                        factRow("Exposure", exposureSummary(facts))
                        factRow("Software", facts.software)
                        if let latitude = facts.latitude, let longitude = facts.longitude {
                            factRow(
                                "GPS",
                                String(format: "%.6f, %.6f", latitude, longitude)
                            )
                        }
                    }

                    factSection("PROVENANCE") {
                        factRow("C2PA present", facts.c2pa.isPresent ? "Yes" : "No")
                        factRow("C2PA validity", facts.c2pa.validity.rawValue.capitalized)
                        factRow("Signer trust", displayTrust(facts.c2pa.trust))
                        factRow("Digital source", facts.digitalSourceType?.displayName)
                        factRow("XMP sidecar", facts.sidecarPath)
                    }

                    DisclosureGroup("Raw metadata (\(rawMetadata.count))") {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(rawMetadata) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(entry.namespace) · \(entry.key)")
                                        .font(.caption.weight(.semibold))
                                    Text(entry.value)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 8)
                    }
                } else if run == nil {
                    ContentUnavailableView(
                        "Source Facts Unavailable",
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
            }
            .padding(14)
        }
        .accessibilityLabel("Source facts and raw metadata")
    }

    private func factSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func factRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .font(.caption)
        }
    }

    private func dimensions(width: Int?, height: Int?) -> String? {
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }

    private func exposureSummary(_ facts: AnalysisSourceFacts) -> String? {
        let values = [facts.focalLength, facts.aperture, facts.shutterSpeed, facts.iso.map { "ISO \($0)" }]
            .compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func displayTrust(_ trust: C2PATrustState) -> String {
        switch trust {
        case .trusted: "Trusted"
        case .untrusted: "Not trusted"
        case .notConfigured: "Trust list unavailable"
        case .notApplicable: "Not applicable"
        case .unknown: "Unknown"
        }
    }
}

private struct FindingDetailView: View {
    let finding: AnalysisFinding
    let annotations: [AnalysisAnnotation]
    let isReadOnly: Bool
    let onReportInclusionChanged: (Bool) -> Void
    let onAnnotationLinkChanged: (UUID, Bool) -> Void
    let onSelectAnnotation: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(finding.title)
                    .font(.headline)

                HStack {
                    Label(finding.severity.rawValue.capitalized, systemImage: "circle.fill")
                    Text(finding.evidenceClass.rawValue.displayCase)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                detailSection("WHAT WAS OBSERVED", finding.explanation)
                detailSection("TECHNICAL DETAIL", finding.technicalDetail, monospaced: true)

                if !finding.alternatives.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("ALTERNATIVES AND LIMITATIONS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(finding.alternatives, id: \.self) { alternative in
                            Label(alternative, systemImage: "arrow.turn.down.right")
                                .font(.callout)
                        }
                    }
                }

                linkedAnnotationsSection

                Divider()
                Toggle(
                    "Include in report",
                    isOn: Binding(
                        get: { finding.includeInReport },
                        set: { included in
                            onReportInclusionChanged(included)
                        }
                    )
                )
                .help("Controls this finding's inclusion in a future analysis report")

                Text("Analyzer \(finding.analyzerID) v\(finding.analyzerVersion) · \(finding.sourceRepresentation.rawValue.displayCase)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(14)
        }
        .accessibilityLabel("Finding detail: \(finding.title)")
    }

    private var linkedAnnotations: [(offset: Int, element: AnalysisAnnotation)] {
        Array(annotations.enumerated()).filter {
            $0.element.findingIDs.contains(finding.id)
        }
    }

    private var linkedAnnotationsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("LINKED ANNOTATIONS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !annotations.isEmpty {
                    Menu {
                        ForEach(Array(annotations.enumerated()), id: \.element.id) {
                            index, annotation in
                            let isLinked = annotation.findingIDs.contains(finding.id)
                            Toggle(
                                annotation.listName(index: index),
                                isOn: Binding(
                                    get: { isLinked },
                                    set: { linked in
                                        onAnnotationLinkChanged(annotation.id, linked)
                                    }
                                )
                            )
                        }
                    } label: {
                        Label("Manage Links", systemImage: "link.badge.plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(isReadOnly)
                    .help("Link or unlink photo annotations from this finding")
                }
            }

            if annotations.isEmpty {
                Text("Add a photo annotation before linking visual evidence to this finding.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if linkedAnnotations.isEmpty {
                Text("No photo annotations are linked to this finding.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(linkedAnnotations, id: \.element.id) { index, annotation in
                    Button {
                        onSelectAnnotation(annotation.id)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: annotation.kind.systemImage)
                                .foregroundStyle(annotation.style.color.swiftUIColor)
                                .frame(width: 14)
                            Text(annotation.listName(index: index))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "scope")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "Select linked annotation \(annotation.listName(index: index))"
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Linked photo annotations")
    }

    private func detailSection(
        _ title: String,
        _ value: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
        }
    }
}

private extension String {
    var displayCase: String {
        unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar), !result.isEmpty {
                result.append(" ")
            }
            result.unicodeScalars.append(scalar)
        }
        .replacingOccurrences(of: "_", with: " ")
        .capitalized
    }
}

private struct AnalysisAnnotationEditSession {
    let target: AnalysisAnnotationEditTarget
    let original: AnalysisAnnotation
    let dragStart: AnalysisNormalizedPoint
    var updated: AnalysisAnnotation
}

private struct AnalysisSourceThumbnail: View {
    let url: URL?
    let representation: AnalysisSourceRepresentation
    let pixelViewMode: AnalysisPixelViewMode
    let developSettings: CameraRawSettings?
    let sourceOrientation: Int
    let displayTransform: DisplayImageTransform?
    let annotationTransform: DisplayImageTransform?
    @Binding var inspectionSample: ImageInspectionSample?
    let scopeSourceMode: AnalysisScopeSourceMode
    @Binding var selectedScopeRegion: CGRect?
    let annotations: [AnalysisAnnotation]
    let annotationTool: AnalysisAnnotationTool
    let annotationStyle: AnalysisAnnotationStyle
    @Binding var selectedAnnotationID: UUID?
    let annotationsAreReadOnly: Bool
    let thumbnailService: ThumbnailService
    let polygonFinishRequestID: Int
    let polygonCancelRequestID: Int
    let onPolygonDraftCountChanged: (Int) -> Void
    let onImageLoaded: (CGImage?) -> Void
    let onSetAnnotation: (AnalysisAnnotation) -> Void
    let onEditAnnotation: (UUID) -> Void
    let onRemoveAnnotation: (UUID) -> Void
    @State private var loadedSourceIdentity: SourcePreviewIdentity?
    @State private var sourceCGImage: CGImage?
    @State private var sourceImage: NSImage?
    @State private var image: NSImage?
    @State private var selectionDragStart: CGPoint?
    @State private var selectionDraft: CGRect?
    @State private var annotationDraft: AnalysisAnnotationGestureDraft?
    @State private var annotationEditSession: AnalysisAnnotationEditSession?
    @State private var polygonDraftPoints: [AnalysisNormalizedPoint] = []
    @State private var pendingLabelAnchor: AnalysisNormalizedPoint?
    @State private var labelText = ""
    @State private var isLabelPromptPresented = false
    @State private var zoomScale: CGFloat = 1
    @State private var zoomGestureStartScale: CGFloat?
    @State private var panOffset: CGSize = .zero
    @State private var panDragStartOffset: CGSize?
    @State private var viewportSize: CGSize = .zero
    @State private var pointerLocationInViewport: CGPoint?
    @State private var scrollEventMonitor: Any?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    CheckerboardBackground(tileSize: 12)
                        .opacity(0.16)
                    ZStack {
                    if let image {
                    if pixelViewMode == .compressionResidual, let sourceImage {
                        HStack(spacing: 8) {
                            analysisImagePane(
                                sourceImage,
                                label: "Reference"
                            )
                            analysisImagePane(
                                image,
                                label: "Compression Residual"
                            )
                        }
                    } else {
                        analysisImagePane(
                            image,
                            label: pixelViewMode.displayName,
                            showsLabel: false
                        )
                    }

                    if let inspectionSample {
                        ForEach(
                            Array(
                                inspectionGeometries(
                                    image: image,
                                    containerSize: geometry.size
                                ).enumerated()
                            ),
                            id: \.offset
                        ) { _, inspectionGeometry in
                            PixelInspectionCrosshair(
                                position: inspectionGeometry.viewPoint(
                                    fromNormalizedDisplay: inspectionSample.normalizedDisplayPoint
                                ),
                                imageRect: inspectionGeometry.imageRectInView
                            )
                        }
                    }

                    if let region = selectionDraft ?? selectedScopeRegion {
                        ForEach(
                            Array(
                                inspectionGeometries(
                                    image: image,
                                    containerSize: geometry.size
                                ).enumerated()
                            ),
                            id: \.offset
                        ) { _, inspectionGeometry in
                            ScopeRegionOverlay(
                                rect: viewRect(
                                    for: region,
                                    geometry: inspectionGeometry
                                ),
                                isActive: scopeSourceMode == .selectedRegion
                            )
                        }
                    }

                    if let coordinateMapper {
                        ForEach(
                            Array(
                                inspectionGeometries(
                                    image: image,
                                    containerSize: geometry.size
                                ).enumerated()
                            ),
                            id: \.offset
                        ) { _, inspectionGeometry in
                            AnalysisAnnotationOverlay(
                                annotations: visibleAnnotations,
                                draft: draftAnnotation,
                                selectedAnnotationID: selectedAnnotationID,
                                geometry: inspectionGeometry,
                                coordinateMapper: coordinateMapper,
                                measurementScale: AnalysisMeasurementScale(
                                    annotations: annotations,
                                    annotationTransform: coordinateMapper.annotationTransform
                                )
                            )
                        }
                    }
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                    }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            if handleAnnotationDragChanged(value, image: image, size: geometry.size) {
                                return
                            }
                            guard scopeSourceMode == .selectedRegion,
                                  annotationTool == .select,
                                  let image,
                                  let inspectionGeometry = inspectionGeometry(
                                      containing: value.startLocation,
                                      image: image,
                                      containerSize: geometry.size
                                  ),
                                  let initial = selectionDragStart
                                      ?? inspectionGeometry.normalizedDisplayPoint(
                                          fromViewPoint: value.startLocation
                                      ) else {
                                return
                            }
                            let current = inspectionGeometry.clampedNormalizedDisplayPoint(
                                fromViewPoint: value.location
                            )
                            selectionDragStart = initial
                            selectionDraft = AnalysisScopeSelection.normalizedRect(
                                from: initial,
                                to: current
                            )
                        }
                        .onEnded { value in
                            defer {
                                selectionDragStart = nil
                                selectionDraft = nil
                            }
                            if handleAnnotationDragEnded(value, image: image, size: geometry.size) {
                                return
                            }
                            guard scopeSourceMode == .selectedRegion,
                                  annotationTool == .select,
                                  let image,
                                  let inspectionGeometry = inspectionGeometry(
                                      containing: value.startLocation,
                                      image: image,
                                      containerSize: geometry.size
                                  ),
                                  let start = selectionDragStart else {
                                return
                            }
                            let end = inspectionGeometry.clampedNormalizedDisplayPoint(
                                fromViewPoint: value.location
                            )
                            selectedScopeRegion = AnalysisScopeSelection.normalizedRect(
                                from: start,
                                to: end
                            )
                        }
                )
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    guard let image,
                          let displayTransform,
                          let inspectionGeometry = inspectionGeometry(
                              containing: location,
                              image: image,
                              containerSize: geometry.size
                          ),
                          let point = inspectionGeometry.normalizedDisplayPoint(
                              fromViewPoint: location
                          ) else {
                        inspectionSample = nil
                        return
                    }
                    inspectionSample = ImageInspectionSample(
                        normalizedDisplayPoint: point,
                        transform: displayTransform,
                        rgba16: sourceCGImage.flatMap {
                            SourcePixelSampler.rgba16(
                                in: $0,
                                atDisplayPoint: point
                            )
                        }
                    )
                case .ended:
                    inspectionSample = nil
                }
            }
            .accessibilityAction(named: "Inspect center pixel") {
                guard let displayTransform else { return }
                inspectionSample = ImageInspectionSample(
                    normalizedDisplayPoint: CGPoint(x: 0.5, y: 0.5),
                    transform: displayTransform,
                    rgba16: sourceCGImage.flatMap {
                        SourcePixelSampler.rgba16(
                            in: $0,
                            atDisplayPoint: CGPoint(x: 0.5, y: 0.5)
                        )
                    }
                )
            }
            .accessibilityAction(named: "Select center region for scopes") {
                selectedScopeRegion = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            }
            .contextMenu {
                if let selectedAnnotationID {
                    Button("Rename / Add Note…") {
                        onEditAnnotation(selectedAnnotationID)
                    }
                    .disabled(annotationsAreReadOnly)

                    Divider()

                    Button("Delete Selected Photo Annotation", role: .destructive) {
                        onRemoveAnnotation(selectedAnnotationID)
                        self.selectedAnnotationID = nil
                    }
                    .disabled(annotationsAreReadOnly)
                } else {
                    Text("Select a photo annotation to delete it")
                }
                }
                .scaleEffect(zoomScale)
                .offset(panOffset)

                if annotationTool == .hand {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { value in
                                    NSCursor.closedHand.set()
                                    updatePan(value.translation, in: geometry.size)
                                }
                                .onEnded { _ in
                                    panDragStartOffset = nil
                                    NSCursor.openHand.set()
                                }
                        )
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                NSCursor.openHand.set()
                            case .ended:
                                NSCursor.arrow.set()
                            }
                        }
                }
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let start = zoomGestureStartScale ?? zoomScale
                            if zoomGestureStartScale == nil {
                                zoomGestureStartScale = start
                            }
                            setZoom(start * value.magnification, in: geometry.size)
                        }
                        .onEnded { _ in
                            zoomGestureStartScale = nil
                        }
                )
                // Keep keyboard focus on the fixed viewport. A focus effect attached
                // to the zoomed canvas scales into the large blue rectangle that can
                // escape the photo pane.
                .focusable()
                .focusEffectDisabled()
                .onDeleteCommand {
                    guard !annotationsAreReadOnly, let selectedAnnotationID else { return }
                    onRemoveAnnotation(selectedAnnotationID)
                    self.selectedAnnotationID = nil
                }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        pointerLocationInViewport = location
                    case .ended:
                        pointerLocationInViewport = nil
                    }
                }
                .onAppear {
                    viewportSize = geometry.size
                }
                .onChange(of: geometry.size) { _, newSize in
                    viewportSize = newSize
                    panOffset = clampedPanOffset(panOffset, in: newSize)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear {
            installScrollEventMonitor()
        }
        .onDisappear {
            removeScrollEventMonitor()
        }
        .onChange(of: polygonFinishRequestID) {
            finishPolygonDraft()
        }
        .onChange(of: polygonCancelRequestID) {
            cancelPolygonDraft()
        }
        .onChange(of: annotationTool) {
            if annotationTool != .shape {
                cancelPolygonDraft()
            }
        }
        .alert("New Label", isPresented: $isLabelPromptPresented) {
            TextField("Label", text: $labelText)
            Button("Cancel", role: .cancel) {
                pendingLabelAnchor = nil
                labelText = ""
            }
            Button("Create") {
                createPendingLabel()
            }
            .disabled(labelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter the text to place at this image position.")
        }
        .task(
            id: PreviewIdentity(
                url: url,
                representation: representation,
                pixelViewMode: pixelViewMode,
                sourceOrientation: sourceOrientation,
                renderToken: FullScreenImageCache.renderToken(
                    settings: developSettings,
                    isEdited: representation == .developed
                )
            )
        ) {
            image = nil
            resetZoom()
            cancelPolygonDraft()
            onImageLoaded(nil)
            guard let url else { return }
            let sourceIdentity = SourcePreviewIdentity(
                url: url,
                representation: representation,
                sourceOrientation: sourceOrientation,
                renderToken: FullScreenImageCache.renderToken(
                    settings: developSettings,
                    isEdited: representation == .developed
                )
            )
            let loadedImage: NSImage
            let source: CGImage
            if loadedSourceIdentity == sourceIdentity,
               let cachedSourceImage = sourceImage,
               let cachedSourceCGImage = sourceCGImage {
                loadedImage = cachedSourceImage
                source = cachedSourceCGImage
            } else {
                sourceImage = nil
                sourceCGImage = nil
                loadedSourceIdentity = nil
                let settings = representation == .developed ? developSettings : nil
                if let decoded = await FullScreenImageCache.decodedEditedPreview(
                    for: url,
                    settings: settings,
                    orientation: sourceOrientation,
                    screenMaxPx: 2_048
                ), !Task.isCancelled {
                    source = decoded
                    loadedImage = NSImage(
                        cgImage: decoded,
                        size: NSSize(width: decoded.width, height: decoded.height)
                    )
                } else {
                    let fallback: NSImage?
                    if representation == .developed, let developSettings {
                        fallback = await thumbnailService.renderEditedThumbnail(
                            for: url,
                            settings: developSettings,
                            exifOrientation: sourceOrientation
                        )
                    } else {
                        fallback = await thumbnailService.loadThumbnail(for: url)
                    }
                    guard !Task.isCancelled,
                          let fallback,
                          let fallbackCGImage = fallback.cgImage(
                              forProposedRect: nil,
                              context: nil,
                              hints: nil
                          ) else {
                        return
                    }
                    loadedImage = fallback
                    source = fallbackCGImage
                }
                loadedSourceIdentity = sourceIdentity
                sourceImage = loadedImage
                sourceCGImage = source
            }
            guard !Task.isCancelled else { return }
            let mode = pixelViewMode
            let cacheKey = AnalysisDerivedViewCacheKey(
                sourceIdentifier: sourceIdentity.derivedViewCacheIdentifier,
                mode: mode,
                source: source
            )
            let rendered = await AnalysisDerivedViewService.shared.image(
                for: cacheKey,
                source: source
            )
            guard !Task.isCancelled, let rendered else { return }
            image = mode == .normal
                ? loadedImage
                : NSImage(cgImage: rendered, size: loadedImage.size)
            onImageLoaded(rendered)
        }
    }

    private func setZoom(
        _ requestedScale: CGFloat,
        anchoredAt anchor: CGPoint? = nil,
        in viewportSize: CGSize
    ) {
        let oldScale = zoomScale
        let newScale = ImagePreviewZoomGeometry.clampedScale(requestedScale)
        let requestedOffset: CGSize
        if let anchor, newScale != oldScale {
            requestedOffset = ImagePreviewZoomGeometry.offset(
                anchoredAt: anchor,
                in: viewportSize,
                currentOffset: panOffset,
                oldScale: oldScale,
                newScale: newScale
            )
        } else {
            requestedOffset = panOffset
        }
        zoomScale = newScale
        panOffset = clampedPanOffset(requestedOffset, in: viewportSize)
        if zoomScale <= 1 {
            panOffset = .zero
            panDragStartOffset = nil
        }
    }

    private func updatePan(_ translation: CGSize, in viewportSize: CGSize) {
        let start = panDragStartOffset ?? panOffset
        if panDragStartOffset == nil {
            panDragStartOffset = start
        }
        panOffset = clampedPanOffset(
            CGSize(
                width: start.width + translation.width,
                height: start.height + translation.height
            ),
            in: viewportSize
        )
    }

    private func clampedPanOffset(_ offset: CGSize, in viewportSize: CGSize) -> CGSize {
        guard let image else { return .zero }
        return ImagePreviewZoomGeometry.clampedOffset(
            offset,
            zoomScale: zoomScale,
            viewportSize: viewportSize,
            imageRects: inspectionGeometries(
                image: image,
                containerSize: viewportSize
            ).map(\.imageRectInView)
        )
    }

    private func installScrollEventMonitor() {
        guard scrollEventMonitor == nil else { return }
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let pointerLocationInViewport,
                  viewportSize.width > 0,
                  viewportSize.height > 0 else {
                return event
            }
            // Ignore trackpad momentum so zoom stops when the user's fingers stop,
            // while still supporting ordinary mouse-wheel events without phases.
            guard event.phase != [] || event.momentumPhase == [] else { return event }
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.01 else { return event }

            let zoomFactor = max(0.1, 1 + delta * 0.005)
            setZoom(
                zoomScale * zoomFactor,
                anchoredAt: pointerLocationInViewport,
                in: viewportSize
            )
            return nil
        }
    }

    private func removeScrollEventMonitor() {
        guard let scrollEventMonitor else { return }
        NSEvent.removeMonitor(scrollEventMonitor)
        self.scrollEventMonitor = nil
    }

    private func resetZoom() {
        zoomScale = 1
        zoomGestureStartScale = nil
        panOffset = .zero
        panDragStartOffset = nil
    }

    private func analysisImagePane(
        _ image: NSImage,
        label: String,
        showsLabel: Bool = true
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(
                    "\(label): \(url?.lastPathComponent ?? "analyzed image")"
                )

            if showsLabel {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inspectionGeometries(
        image: NSImage,
        containerSize: CGSize
    ) -> [ImageInspectionGeometry] {
        guard image.size.width > 0, image.size.height > 0 else { return [] }
        return paneRects(in: containerSize).compactMap {
            try? ImageInspectionGeometry(
                imagePixelSize: image.size,
                containerRect: $0
            )
        }
    }

    private func inspectionGeometry(
        containing point: CGPoint,
        image: NSImage,
        containerSize: CGSize
    ) -> ImageInspectionGeometry? {
        inspectionGeometries(image: image, containerSize: containerSize)
            .first { $0.imageRectInView.contains(point) }
    }

    private func paneRects(in containerSize: CGSize) -> [CGRect] {
        let bounds = CGRect(origin: .zero, size: containerSize)
        guard pixelViewMode == .compressionResidual else { return [bounds] }
        let gap: CGFloat = 8
        let paneWidth = max(0, (containerSize.width - gap) / 2)
        return [
            CGRect(x: 0, y: 0, width: paneWidth, height: containerSize.height),
            CGRect(
                x: paneWidth + gap,
                y: 0,
                width: paneWidth,
                height: containerSize.height
            )
        ]
    }

    private func viewRect(
        for normalizedRect: CGRect,
        geometry: ImageInspectionGeometry
    ) -> CGRect {
        CGRect(
            x: geometry.imageRectInView.minX
                + normalizedRect.minX * geometry.imageRectInView.width,
            y: geometry.imageRectInView.minY
                + normalizedRect.minY * geometry.imageRectInView.height,
            width: normalizedRect.width * geometry.imageRectInView.width,
            height: normalizedRect.height * geometry.imageRectInView.height
        )
    }

    private var coordinateMapper: AnalysisAnnotationCoordinateMapper? {
        guard let annotationTransform, let displayTransform else { return nil }
        return AnalysisAnnotationCoordinateMapper(
            annotationTransform: annotationTransform,
            displayTransform: displayTransform
        )
    }

    private var visibleAnnotations: [AnalysisAnnotation] {
        annotations.filter(\.isVisible)
    }

    private var draftAnnotation: AnalysisAnnotation? {
        if let annotationEditSession {
            return annotationEditSession.updated
        }
        if !polygonDraftPoints.isEmpty {
            return AnalysisAnnotation(
                kind: .polygon,
                geometry: .polygon(polygonDraftPoints),
                style: annotationStyle
            )
        }
        guard let annotationDraft,
              let geometry = AnalysisAnnotationGeometryBuilder.geometry(
                  for: annotationDraft.kind,
                  start: annotationDraft.start,
                  end: annotationDraft.current
              ) else {
            return nil
        }
        return AnalysisAnnotation(
            kind: annotationDraft.kind,
            geometry: geometry,
            style: annotationStyle
        )
    }

    private func handleAnnotationDragChanged(
        _ value: DragGesture.Value,
        image: NSImage?,
        size: CGSize
    ) -> Bool {
        guard !annotationsAreReadOnly else { return false }
        if annotationTool == .select {
            guard let image,
                  let coordinateMapper,
                  let geometry = inspectionGeometry(
                      containing: value.startLocation,
                      image: image,
                      containerSize: size
                  ) else { return false }

            if annotationEditSession == nil {
                guard let target = AnalysisAnnotationHitTester.editTarget(
                    at: value.startLocation,
                    selectedAnnotationID: selectedAnnotationID,
                    annotations: visibleAnnotations,
                    geometry: geometry,
                    coordinateMapper: coordinateMapper
                ), let original = visibleAnnotations.first(where: {
                    $0.id == target.annotationID
                }) else { return false }
                let dragStart = coordinateMapper.annotationPoint(
                    from: geometry.clampedNormalizedDisplayPoint(
                        fromViewPoint: value.startLocation
                    )
                )
                selectedAnnotationID = original.id
                annotationEditSession = AnalysisAnnotationEditSession(
                    target: target,
                    original: original,
                    dragStart: dragStart,
                    updated: original
                )
            }

            guard var session = annotationEditSession else { return false }
            let current = coordinateMapper.annotationPoint(
                from: geometry.clampedNormalizedDisplayPoint(fromViewPoint: value.location)
            )
            switch session.target {
            case .move:
                session.updated.geometry = AnalysisAnnotationGeometryEditor.moving(
                    session.original.geometry,
                    from: session.dragStart,
                    to: current
                )
            case .resize(_, let controlPoint):
                session.updated.geometry = AnalysisAnnotationGeometryEditor.resizing(
                    session.original.geometry,
                    controlPoint: controlPoint,
                    to: current
                ) ?? session.original.geometry
            }
            annotationEditSession = session
            return true
        }

        guard let kind = annotationTool.annotationKind else {
            return false
        }
        if kind == .polygon { return true }
        guard kind != .label else { return true }
        guard let image,
              let coordinateMapper,
              let geometry = inspectionGeometry(
                  containing: value.startLocation,
                  image: image,
                  containerSize: size
              ) else {
            return true
        }
        let start = annotationDraft?.start ?? coordinateMapper.annotationPoint(
            from: geometry.clampedNormalizedDisplayPoint(fromViewPoint: value.startLocation)
        )
        let current = coordinateMapper.annotationPoint(
            from: geometry.clampedNormalizedDisplayPoint(fromViewPoint: value.location)
        )
        annotationDraft = AnalysisAnnotationGestureDraft(
            kind: kind,
            start: start,
            current: current
        )
        return true
    }

    private func handleAnnotationDragEnded(
        _ value: DragGesture.Value,
        image: NSImage?,
        size: CGSize
    ) -> Bool {
        guard let image,
              let coordinateMapper,
              let geometry = inspectionGeometry(
                  containing: value.startLocation,
                  image: image,
                  containerSize: size
              ) else {
            annotationDraft = nil
            return annotationTool != .select
        }

        if annotationTool == .select {
            if let annotationEditSession {
                defer { self.annotationEditSession = nil }
                selectedAnnotationID = annotationEditSession.original.id
                if annotationEditSession.updated != annotationEditSession.original {
                    onSetAnnotation(annotationEditSession.updated)
                }
                return true
            }
            let dragDistance = hypot(
                value.location.x - value.startLocation.x,
                value.location.y - value.startLocation.y
            )
            if scopeSourceMode == .selectedRegion, dragDistance >= 3 {
                return false
            }
            selectedAnnotationID = AnalysisAnnotationHitTester.annotationID(
                at: value.location,
                annotations: visibleAnnotations,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            return true
        }

        guard !annotationsAreReadOnly, let kind = annotationTool.annotationKind else {
            annotationDraft = nil
            return true
        }

        if kind == .polygon {
            let point = coordinateMapper.annotationPoint(
                from: geometry.clampedNormalizedDisplayPoint(fromViewPoint: value.location)
            )
            let viewPoint = geometry.viewPoint(
                fromNormalizedDisplay: coordinateMapper.displayPoint(from: point)
            )
            if polygonDraftPoints.count >= 3,
               let first = polygonDraftPoints.first {
                let firstViewPoint = geometry.viewPoint(
                    fromNormalizedDisplay: coordinateMapper.displayPoint(from: first)
                )
                if hypot(viewPoint.x - firstViewPoint.x, viewPoint.y - firstViewPoint.y) <= 12 {
                    finishPolygonDraft()
                    return true
                }
            }
            if let last = polygonDraftPoints.last {
                let lastViewPoint = geometry.viewPoint(
                    fromNormalizedDisplay: coordinateMapper.displayPoint(from: last)
                )
                guard hypot(viewPoint.x - lastViewPoint.x, viewPoint.y - lastViewPoint.y) > 3 else {
                    return true
                }
            }
            guard polygonDraftPoints.count < 1_000 else { return true }
            polygonDraftPoints.append(point)
            onPolygonDraftCountChanged(polygonDraftPoints.count)
            return true
        }

        if kind == .label {
            pendingLabelAnchor = coordinateMapper.annotationPoint(
                from: geometry.clampedNormalizedDisplayPoint(fromViewPoint: value.location)
            )
            labelText = ""
            isLabelPromptPresented = true
            return true
        }

        defer { annotationDraft = nil }
        guard let annotationDraft,
              hypot(
                  value.location.x - value.startLocation.x,
                  value.location.y - value.startLocation.y
              ) >= 3,
              let completedGeometry = AnalysisAnnotationGeometryBuilder.geometry(
                  for: kind,
                  start: annotationDraft.start,
                  end: annotationDraft.current
              ) else {
            return true
        }
        let annotation = AnalysisAnnotation(
            kind: kind,
            geometry: completedGeometry,
            style: annotationStyle
        )
        onSetAnnotation(annotation)
        selectedAnnotationID = annotation.id
        return true
    }

    private func finishPolygonDraft() {
        guard !annotationsAreReadOnly, polygonDraftPoints.count >= 3 else { return }
        let annotation = AnalysisAnnotation(
            kind: .polygon,
            geometry: .polygon(polygonDraftPoints),
            style: annotationStyle
        )
        guard (try? annotation.validate()) != nil else { return }
        onSetAnnotation(annotation)
        selectedAnnotationID = annotation.id
        polygonDraftPoints.removeAll(keepingCapacity: false)
        onPolygonDraftCountChanged(0)
    }

    private func cancelPolygonDraft() {
        guard !polygonDraftPoints.isEmpty else { return }
        polygonDraftPoints.removeAll(keepingCapacity: false)
        onPolygonDraftCountChanged(0)
    }

    private func createPendingLabel() {
        defer {
            pendingLabelAnchor = nil
            labelText = ""
        }
        let text = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !annotationsAreReadOnly,
              !text.isEmpty,
              let pendingLabelAnchor else { return }
        let annotation = AnalysisAnnotation(
            kind: .label,
            geometry: .anchor(pendingLabelAnchor),
            text: text,
            style: annotationStyle
        )
        onSetAnnotation(annotation)
        selectedAnnotationID = annotation.id
    }
}

private struct PreviewIdentity: Hashable {
    let url: URL?
    let representation: AnalysisSourceRepresentation
    let pixelViewMode: AnalysisPixelViewMode
    let sourceOrientation: Int
    let renderToken: String?
}

private struct SourcePreviewIdentity: Hashable {
    let url: URL
    let representation: AnalysisSourceRepresentation
    let sourceOrientation: Int
    let renderToken: String?

    var derivedViewCacheIdentifier: String {
        [
            url.standardizedFileURL.path,
            representation.rawValue,
            String(sourceOrientation),
            renderToken ?? "source"
        ].joined(separator: "|")
    }
}

private struct PixelInspectionCrosshair: View {
    let position: CGPoint
    let imageRect: CGRect

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: imageRect.minX, y: position.y))
                path.addLine(to: CGPoint(x: imageRect.maxX, y: position.y))
                path.move(to: CGPoint(x: position.x, y: imageRect.minY))
                path.addLine(to: CGPoint(x: position.x, y: imageRect.maxY))
            }
            .stroke(.black.opacity(0.75), lineWidth: 3)

            Path { path in
                path.move(to: CGPoint(x: imageRect.minX, y: position.y))
                path.addLine(to: CGPoint(x: imageRect.maxX, y: position.y))
                path.move(to: CGPoint(x: position.x, y: imageRect.minY))
                path.addLine(to: CGPoint(x: position.x, y: imageRect.maxY))
            }
            .stroke(.yellow, lineWidth: 1)

            Circle()
                .strokeBorder(.black.opacity(0.8), lineWidth: 3)
                .overlay {
                    Circle().strokeBorder(.yellow, lineWidth: 1)
                }
                .frame(width: 13, height: 13)
                .position(position)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ScopeRegionOverlay: View {
    let rect: CGRect
    let isActive: Bool

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(isActive ? 0.12 : 0.06))
            .overlay {
                Rectangle()
                    .strokeBorder(
                        Color.accentColor.opacity(isActive ? 1 : 0.55),
                        style: StrokeStyle(lineWidth: 2, dash: [7, 4])
                    )
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct PixelInspectionReadout: View {
    let sample: ImageInspectionSample?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .accessibilityHidden(true)
            if let sample {
                Text("Source pixel x: \(sample.sourcePixel.x), y: \(sample.sourcePixel.y)")
                .monospacedDigit()
                .textSelection(.enabled)
                if let rgba = sample.rgba16 {
                    Divider()
                        .frame(height: 14)
                    Text(
                        "R: \(rgba.red)  |  G: \(rgba.green)  |  "
                            + "B: \(rgba.blue)  |  A: \(rgba.alpha)"
                    )
                    .monospacedDigit()
                    .textSelection(.enabled)
                }
                Spacer()
                Text(
                    String(
                        format: "Display %.2f%%, %.2f%%",
                        sample.normalizedDisplayPoint.x * 100,
                        sample.normalizedDisplayPoint.y * 100
                    )
                )
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            } else {
                Text("Hover over the image to inspect its source-pixel position")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let sample else {
            return "Pixel inspector. Hover over the image to inspect a source pixel."
        }
        if let rgba = sample.rgba16 {
            return "Source pixel x \(sample.sourcePixel.x), y \(sample.sourcePixel.y). "
                + "16-bit red \(rgba.red), green \(rgba.green), "
                + "blue \(rgba.blue), alpha \(rgba.alpha)"
        }
        return "Source pixel x \(sample.sourcePixel.x), y \(sample.sourcePixel.y)"
    }
}

private enum SourcePixelSampler {
    static func rgba16(
        in image: CGImage,
        atDisplayPoint point: CGPoint
    ) -> SourcePixelRGBA16? {
        guard image.width > 0, image.height > 0 else { return nil }
        let x = min(image.width - 1, max(0, Int(point.x * CGFloat(image.width))))
        let displayY = min(image.height - 1, max(0, Int(point.y * CGFloat(image.height))))
        let quartzY = image.height - 1 - displayY
        var components = [UInt16](repeating: 0, count: 4)
        let bitmapInfo = CGBitmapInfo.byteOrder16Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &components,
            width: 1,
            height: 1,
            bitsPerComponent: 16,
            bytesPerRow: MemoryLayout<UInt16>.size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: -CGFloat(x), y: -CGFloat(quartzY))
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )

        let alpha = components[3]
        guard alpha > 0, alpha < UInt16.max else {
            return SourcePixelRGBA16(
                red: components[0],
                green: components[1],
                blue: components[2],
                alpha: alpha
            )
        }
        func unpremultiply(_ value: UInt16) -> UInt16 {
            UInt16(min(UInt32(UInt16.max), UInt32(value) * UInt32(UInt16.max) / UInt32(alpha)))
        }
        return SourcePixelRGBA16(
            red: unpremultiply(components[0]),
            green: unpremultiply(components[1]),
            blue: unpremultiply(components[2]),
            alpha: alpha
        )
    }
}
