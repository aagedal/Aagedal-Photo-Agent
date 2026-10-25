import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

private enum AnalysisPixelInspectorSection: String, CaseIterable {
    case evidence
    case scopes
    case layers
    case metadata

    var label: String {
        switch self {
        case .evidence: "Evidence"
        case .scopes: "Scopes"
        case .layers: "Layers"
        case .metadata: "Metadata"
        }
    }
}

struct AnalysisWorkspaceView: View {
    private static let metaContentSealCheckURL = URL(
        string: "https://www.meta.ai/identification/"
    )!
    private static let googleSynthIDCheckURL = URL(
        string: "https://synthid.com/"
    )!
    private static let imageWhispererURL = URL(
        string: "https://imagewhisperer.org/"
    )!

    @Bindable var model: AnalysisWorkspaceModel
    let folderImages: [ImageFile]
    let thumbnailService: ThumbnailService
    let onSelectImage: (ImageFile) -> Void
    let onOpenImportedProject: (URL) -> Void
    let onClose: () -> Void
    @State private var metadataNoteRequest: AnalysisMetadataNoteRequest?
    @State private var isVerificationToolsPresented = false
    @State private var selectedFindingID: String?
    @State private var isLoupeEnabled = true
    /// Hover sample, read only by the readout and the loupe/crosshair layers so pointer moves
    /// do not re-evaluate the whole workspace body.
    @State private var pixelInspection = AnalysisPixelInspectionState()
    @State private var displayedScopeImage: CGImage?
    @State private var scopeSourceMode: AnalysisScopeSourceMode = .fullImage
    @State private var selectedScopeRegion: CGRect?
    @State private var scopeWorkspaceState = AnalysisScopeWorkspaceState()
    @State private var pixelViewMode: AnalysisPixelViewMode = .normal
    @State private var pixelChannel: AnalysisPixelChannel = .rgb
    @State private var levelSweepCenter = 128.0
    @State private var isLevelSweepEditing = false
    @State private var comparisonPixelMode: AnalysisPixelViewMode?
    @State private var comparisonPixelChannel: AnalysisPixelChannel = .rgb
    @State private var pixelComparisonLayout: ComparisonLayout = .sideBySide
    @State private var pixelWipePosition: CGFloat = 0.5
    @State private var pixelWipeAngle: CGFloat = 0
    @State private var pixelInspectorSection: AnalysisPixelInspectorSection = .evidence
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
    @State private var mapDraftCoordinateCount = 0
    @State private var mapPrimaryActionRequestID = 0
    @State private var mapFinishShapeRequestID = 0
    @State private var mapCancelDraftRequestID = 0
    @State private var isReportOptionsPresented = false
    @State private var reportExportProgress: Double?
    @State private var reportExportError: String?
    @State private var reportExportTask: Task<Void, Never>?
    @State private var evidenceExportTask: Task<Void, Never>?
    @State private var reportExportRequestID: UUID?
    @State private var evidenceExportRequestID: UUID?
    @State private var projectArchiveTask: Task<Void, Never>?
    @State private var projectArchiveStatus: String?
    @State private var exportConfirmation: AnalysisExportConfirmation?
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
        .sheet(item: $metadataNoteRequest) { request in
            AnalysisMetadataNoteEditor(
                request: request,
                onSave: { observation in
                    guard model.analysisCase?.id == request.caseID, !model.sourceChanged else { return }
                    model.setObservation(observation)
                    metadataNoteRequest = nil
                },
                onCancel: { metadataNoteRequest = nil }
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
            "Analysis Operation Failed",
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
            exportConfirmation?.title ?? "Exported",
            isPresented: Binding(
                get: { exportConfirmation != nil },
                set: { if !$0 { exportConfirmation = nil } }
            ),
            presenting: exportConfirmation
        ) { confirmation in
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([confirmation.url])
                exportConfirmation = nil
            }
            Button("OK", role: .cancel) { exportConfirmation = nil }
        } message: { confirmation in
            Text("Saved “\(confirmation.url.lastPathComponent)”.")
        }
        .alert(
            "Analysis Changes Not Saved",
            isPresented: Binding(
                get: { model.pendingUnsavedChangesExit != nil },
                set: { if !$0 { model.dismissUnsavedChangesPrompt() } }
            ),
            presenting: model.pendingUnsavedChangesExit
        ) { exit in
            Button("Retry Save") { completeUnsavedChangesExit(exit, retryingSave: true) }
            Button("Discard Changes", role: .destructive) {
                completeUnsavedChangesExit(exit, retryingSave: false)
            }
            Button("Cancel", role: .cancel) { model.cancelUnsavedChangesExit() }
        } message: { _ in
            Text("The latest case or map edits could not be saved. Retry the save before leaving this photo, or discard the unsaved edits.")
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
            projectArchiveTask?.cancel()
            // Up to four 2,048 px RGBAh previews (~256 MB) are only useful inside Analysis.
            AnalysisSourcePreviewCache.shared.removeAll()
        }
    }

    private var workspaceWithStateObservers: some View {
        workspaceWithSourceObservers
        .onChange(of: photoAnnotationTool) {
            if photoAnnotationTool == .counter {
                pixelInspectorSection = .layers
            }
        }
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
    }

    private var workspaceWithSourceObservers: some View {
        workspaceContent
        .onChange(of: model.sourceURL) { oldURL, newURL in
            resetForSourceChange()
            prefetchNextPreview(leaving: oldURL, opening: newURL)
        }
        .onChange(of: model.analysisCase?.id) {
            metadataNoteRequest = nil
            selectedAnnotationID = nil
            selectedMapAnnotationID = nil
        }
        .onChange(of: model.displayPreference) {
            pixelInspection.update(nil)
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

            if let warning = model.storagePortabilityWarning {
                storagePortabilityBanner(warning)
                Divider()
            }

            if model.sourceChanged {
                sourceChangedBanner
                Divider()
            }

            if let saveError = model.saveError {
                saveErrorBanner(saveError)
                Divider()
            }

            workspaceBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            AnalysisEscapeKeyMonitor(onEscape: handleEscapeKey)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image Analysis workspace")
        .accessibilityIdentifier("analysis.workspace")
    }

    /// Running PDF/JPEG exports captured their case, source, and annotations when they started,
    /// so selecting another photo must not abort them; only Cancel or closing the workspace does.
    private func resetForSourceChange() {
        pixelInspection.update(nil)
        displayedScopeImage = nil
        selectedScopeRegion = nil
        scopeSourceMode = .fullImage
        pixelViewMode = .normal
        pixelChannel = .rgb
        selectedAnnotationID = nil
        selectedMapAnnotationID = nil
        mapDraftCoordinateCount = 0
        photoPolygonDraftCount = 0
        photoPolygonCancelRequestID += 1
    }

    /// Decodes the original preview of the next rail photo in the direction of travel, so
    /// stepping through the rail shows each photo at once. A later navigation replaces it.
    private func prefetchNextPreview(leaving oldURL: URL?, opening newURL: URL?) {
        guard let newURL,
              let newIndex = folderImages.firstIndex(where: { $0.url == newURL }) else { return }
        let oldIndex = oldURL.flatMap { old in folderImages.firstIndex { $0.url == old } }
        let step = (oldIndex.map { $0 > newIndex } ?? false) ? -1 : 1
        let nextIndex = newIndex + step
        guard folderImages.indices.contains(nextIndex) else { return }
        let next = folderImages[nextIndex]
        guard SupportedImageFormats.isSupported(url: next.url) else { return }
        // A newly opened photo shows its original until its case says otherwise.
        AnalysisSourcePreviewCache.shared.prefetch(
            SourcePreviewIdentity(
                url: next.url,
                representation: .original,
                sourceOrientation: next.exifOrientation,
                renderToken: nil
            ),
            settings: nil
        )
    }

    /// Escape cancels the narrowest active state first: an in-progress draft, then a
    /// non-select markup tool, then the annotation selection; with nothing left to cancel it
    /// closes the workspace (asking first after a failed save). Returns false while an export
    /// is running so the event continues normally.
    private func handleEscapeKey() -> Bool {
        if photoPolygonDraftCount > 0 {
            photoPolygonCancelRequestID += 1
            return true
        }
        let showsMapMarkup = model.workspaceMode == .osint
        if showsMapMarkup, mapDraftCoordinateCount > 0 {
            mapCancelDraftRequestID += 1
            return true
        }
        if photoAnnotationTool != .select {
            photoAnnotationTool = .select
            return true
        }
        if showsMapMarkup, mapAnnotationTool != .select {
            mapAnnotationTool = .select
            return true
        }
        if selectedAnnotationID != nil || selectedMapAnnotationID != nil {
            selectedAnnotationID = nil
            selectedMapAnnotationID = nil
            return true
        }
        // Closing cancels running exports, so Escape only closes an otherwise idle workspace.
        guard reportExportTask == nil, evidenceExportTask == nil, projectArchiveTask == nil else {
            return false
        }
        requestClose()
        return true
    }

    private func requestClose() {
        if model.requestClose() { onClose() }
    }

    private func completeUnsavedChangesExit(
        _ exit: AnalysisUnsavedChangesExit,
        retryingSave: Bool
    ) {
        Task { @MainActor in
            if await model.completeUnsavedChangesExit(exit, retryingSave: retryingSave) {
                onClose()
            }
        }
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
            model.setGlobalMapAnnotation(annotation)
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
            .labelsHidden()
            .accessibilityLabel("Analysis Mode")
            .fixedSize(horizontal: true, vertical: false)
            .disabled(model.analysisCase == nil)

            if model.workspaceMode == .pixelAnalysis {
                Picker("Channel", selection: $pixelChannel) {
                    ForEach(AnalysisPixelChannel.allCases, id: \.self) { channel in
                        Text(channel.displayName).tag(channel)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(model.analysisCase == nil || pixelViewMode == .alpha)
                .help("Analyze RGB or an individual channel; Alpha shows source coverage")

                Picker("Pixel View", selection: $pixelViewMode) {
                    ForEach(AnalysisPixelViewMode.analysisModes, id: \.self) { mode in
                        Text(mode.displayName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(model.analysisCase == nil)
                .help(
                    "Choose an alpha, edge, compression, noise, level sweep, or clone view"
                )
            }

            if model.workspaceMode == .pixelAnalysis {
                Toggle(isOn: Binding(
                    get: { comparisonPixelMode != nil },
                    set: { comparisonPixelMode = $0 ? .normal : nil }
                )) {
                    Label("Compare", systemImage: "rectangle.split.2x1")
                }
                .toggleStyle(.button)
                .disabled(model.analysisCase == nil)
                .help("Compare two pixel view modes with linked zoom and pan")
            }

            Toggle(isOn: $isLoupeEnabled) {
                Label("Loupe", systemImage: "magnifyingglass")
            }
            .toggleStyle(.button)
            .help("Show or hide true-pixel detail (Z while the pointer is over the image)")
            .accessibilityHint("Press Z while pointing at the image to toggle the loupe")

            Spacer()

            externalVerificationLinks

            if evidenceExportTask != nil {
                backgroundJobIndicator(
                    "Exporting JPEG…",
                    cancelHelp: "Cancel the annotated JPEG export"
                ) {
                    evidenceExportTask?.cancel()
                }
            }

            if let projectArchiveStatus {
                backgroundJobIndicator(
                    projectArchiveStatus,
                    cancelHelp: "Cancel the Image Analysis Project operation"
                ) {
                    projectArchiveTask?.cancel()
                }
            }

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
                    .disabled(model.analysisCase == nil || model.sourceChanged)

                    Divider()

                    Button("Annotated Image (JPEG)…", systemImage: "photo") {
                        chooseAnnotatedImageDestinationAndExport()
                    }
                    .disabled(model.analysisCase == nil || model.sourceChanged || evidenceExportTask != nil)

                    Button(
                        model.mapState.viewport == nil
                            ? "Annotated Map (JPEG) — Show the OSINT Map First"
                            : "Annotated Map (JPEG)…",
                        systemImage: "map"
                    ) {
                        chooseAnnotatedMapDestinationAndExport()
                    }
                    .disabled(model.mapState.viewport == nil || evidenceExportTask != nil)
                    .help(model.mapState.viewport == nil
                        ? "Show this photo's map in the OSINT tab once to choose the area to export"
                        : "Export the annotated OSINT map as a JPEG")

                    Divider()

                    Button("Image Analysis Project (.pint)…", systemImage: "archivebox") {
                        chooseProjectDestinationAndExport()
                    }
                    .disabled(model.sourceURL == nil || projectArchiveTask != nil)

                    Button("Import Image Analysis Project…", systemImage: "square.and.arrow.down") {
                        chooseProjectArchiveAndImport()
                    }
                    .disabled(projectArchiveTask != nil)
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .help("Export evidence, or export and import a portable Image Analysis Project")
            }

            Picker(
                "Version",
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
            .help("Choose which version is displayed; findings based on the source file remain tied to the original")

            // Escape cancels the current draft, tool, or selection first and closes only when
            // nothing is left to cancel (see handleEscapeKey).
            Button("Close", action: requestClose)
                .help("Return to the browser workspace (Esc when nothing is selected or being drawn)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // Keep the rail outside loading and tab branches so navigation retains its scroll view.
    private var workspaceBody: some View {
        VStack(spacing: 0) {
            if model.workspaceMode == .osint {
                osintMarkupToolbar
                    .disabled(model.loadState != .ready)
                Divider()
            }
            HStack(spacing: 0) {
                imageRail
                Divider()
                workspaceDetail
            }
        }
    }

    @ViewBuilder
    private var workspaceDetail: some View {
        switch model.loadState {
        case .idle:
            // Reached when the open case was invalidated (for example by a failed rename);
            // nothing is loading, so offer a way out instead of an endless spinner.
            ContentUnavailableView {
                Label("No Photo Selected", systemImage: "photo")
            } description: {
                Text("Choose a photo in the rail to analyze it, or close Image Analysis.")
            } actions: {
                Button("Close", action: requestClose)
            }

        case .failed(let message):
            ContentUnavailableView {
                Label("Analysis Case Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.retry() }
            }

        // One branch for loading and ready keeps the source preview mounted across photo
        // changes: it decodes while the case is resolved and keeps its decoded image. Only the
        // case-dependent panels show the loading placeholder and are rebuilt when ready.
        case .loading, .ready:
            if model.workspaceMode == .pixelAnalysis {
                pixelAnalysisBody
            } else {
                osintBody
            }
        }
    }

    private var isCaseReady: Bool { model.loadState == .ready }

    /// The preview decodes while the case loads. A photo with develop edits waits for its case,
    /// which decides between the original and developed version, so it never flashes the wrong one.
    private var previewSourceURL: URL? {
        guard isCaseReady || !model.hasDevelopedRepresentation else { return nil }
        return model.sourceURL
    }

    private var analysisLoadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Validating source revision…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Validating source revision")
    }

    private func backgroundJobIndicator(
        _ status: String,
        cancelHelp: String,
        cancel: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Button("Cancel", role: .cancel, action: cancel)
                .buttonStyle(.borderless)
                .help(cancelHelp)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status)
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

    private func storagePortabilityBanner(_ warning: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Analysis stored on this Mac")
                    .font(.headline)
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("analysis.storage-portability-warning")
    }

    private func saveErrorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Analysis changes not saved")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Discard Changes", role: .destructive) {
                model.discardFailedSaves()
            }
            .help("Forget the unsaved Analysis changes; nothing is written")
            Button("Retry Save") {
                model.retryFailedSave()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("analysis.save-error")
    }

    /// Whether the photo under analysis has Anonymizer redactions (in-memory copy, or its
    /// sidecar defensively). Analysis exports embed the original pixels by forensic design.
    private func sourcePhotoRedacts(_ sourceURL: URL) -> Bool {
        if let image = folderImages.first(where: { $0.url == sourceURL }) {
            return RedactionPrivacyGuard.redactsIncludingSidecar(image)
        }
        return XMPSidecarService().loadDevelopSettings(for: sourceURL)?.hasActiveRedaction == true
    }

    private func chooseReportDestinationAndExport(options: AnalysisReportExportOptions) {
        guard let analysisCase = model.analysisCase,
              let sourceURL = model.sourceURL,
              reportExportTask == nil else { return }
        guard RedactionPrivacyPrompt.confirmAnalysisExport(
            containsRedactedPhoto: sourcePhotoRedacts(sourceURL)
        ) else { return }

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
        let folderMapAnnotations = model.globalMapAnnotations.map(\.annotation)
        let requestID = UUID()
        reportExportRequestID = requestID
        reportExportProgress = 0
        reportExportTask = Task { @MainActor in
            defer {
                if reportExportRequestID == requestID {
                    reportExportProgress = nil
                    reportExportTask = nil
                    reportExportRequestID = nil
                }
            }
            do {
                let snapshot = try await AnalysisReportSnapshot.capture(
                    from: analysisCase,
                    sourceURL: sourceURL,
                    appVersion: appVersion,
                    appBuild: appBuild,
                    originalDisplayEvidenceCrop: evidenceCropRect,
                    folderMapAnnotations: folderMapAnnotations
                )
                try Task.checkCancellation()
                reportExportProgress = 0.08
                let data = try await AnalysisPDFReportRenderer.makePDF(
                    snapshot: snapshot,
                    options: options,
                    progress: {
                        guard reportExportRequestID == requestID else { return }
                        reportExportProgress = 0.08 + $0 * 0.90
                    }
                )
                try Task.checkCancellation()
                let result = try await AnalysisExportFileService.shared.write(
                    data,
                    to: outputURL,
                    requestID: requestID
                )
                guard reportExportRequestID == requestID else { return }
                guard case .committed = result else { return }
                reportExportProgress = 1
                exportConfirmation = AnalysisExportConfirmation(
                    title: "Analysis Report Exported",
                    url: outputURL
                )
            } catch is CancellationError {
                return
            } catch AnalysisPDFReportError.cancelled {
                return
            } catch {
                guard reportExportRequestID == requestID else { return }
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
        guard RedactionPrivacyPrompt.confirmAnalysisExport(
            containsRedactedPhoto: sourcePhotoRedacts(sourceURL)
        ) else { return }
        guard let outputURL = chooseJPEGDestination(
            title: "Export Annotated Image",
            suggestedName: "\(analysisCase.title) Annotated.jpg"
        ) else { return }

        let requestID = UUID()
        evidenceExportRequestID = requestID
        evidenceExportTask = Task { @MainActor in
            defer {
                if evidenceExportRequestID == requestID {
                    evidenceExportTask = nil
                    evidenceExportRequestID = nil
                }
            }
            do {
                let data = try await AnalysisEvidenceJPEGRenderer.photoJPEG(
                    sourceURL: sourceURL,
                    annotations: analysisCase.annotations
                )
                try Task.checkCancellation()
                let result = try await AnalysisExportFileService.shared.write(
                    data,
                    to: outputURL,
                    requestID: requestID
                )
                if case .committed = result, evidenceExportRequestID == requestID {
                    exportConfirmation = AnalysisExportConfirmation(
                        title: "Annotated Image Exported",
                        url: outputURL
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard evidenceExportRequestID == requestID else { return }
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
                  folderMapAnnotations: model.globalMapAnnotations.map(\.annotation),
                  capturedAt: Date()
              ), evidenceExportTask == nil else { return }
        guard let outputURL = chooseJPEGDestination(
            title: "Export Annotated Map",
            suggestedName: "\(analysisCase.title) Map.jpg"
        ) else { return }

        let requestID = UUID()
        evidenceExportRequestID = requestID
        evidenceExportTask = Task { @MainActor in
            defer {
                if evidenceExportRequestID == requestID {
                    evidenceExportTask = nil
                    evidenceExportRequestID = nil
                }
            }
            do {
                let data = try await AnalysisEvidenceJPEGRenderer.mapJPEG(evidence: evidence)
                try Task.checkCancellation()
                let result = try await AnalysisExportFileService.shared.write(
                    data,
                    to: outputURL,
                    requestID: requestID
                )
                if case .committed = result, evidenceExportRequestID == requestID {
                    exportConfirmation = AnalysisExportConfirmation(
                        title: "Annotated Map Exported",
                        url: outputURL
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard evidenceExportRequestID == requestID else { return }
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

    private func chooseProjectDestinationAndExport() {
        guard let sourceURL = model.sourceURL, projectArchiveTask == nil else { return }
        // The project archive carries every photo in the folder as its original file.
        let folderRedacts = folderImages.contains { RedactionPrivacyGuard.knowledge(for: $0) == .redacts }
        guard RedactionPrivacyPrompt.confirmAnalysisExport(
            containsRedactedPhoto: folderRedacts || sourcePhotoRedacts(sourceURL)
        ) else { return }
        let sourceFolder = sourceURL.deletingLastPathComponent()
        let panel = NSSavePanel()
        panel.title = "Export Image Analysis Project"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.photoIntelligenceProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(sourceFolder.lastPathComponent).pint"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        projectArchiveStatus = "Exporting project…"
        projectArchiveTask = Task { @MainActor in
            defer {
                projectArchiveTask = nil
                projectArchiveStatus = nil
            }
            do {
                // A failed save would leave stale case data on disk: retry it, and refuse to
                // export anything older than what the workspace shows.
                guard await model.savePendingChanges() else {
                    reportExportError = "The project was not exported because the latest Analysis changes could not be saved. \(model.saveError ?? "")"
                    return
                }
                try Task.checkCancellation()
                // Read-only folders keep their cases and folder map in Application Support, so
                // export what the repository holds rather than only the folder's own files.
                let analysisDocuments = await model.persistedDocumentsForProjectExport()
                try Task.checkCancellation()
                _ = try await ImageAnalysisProjectArchive.export(
                    sourceFolderURL: sourceFolder,
                    imageURLs: folderImages.map(\.url),
                    title: sourceFolder.lastPathComponent,
                    destinationURL: destination,
                    appVersion: appVersion,
                    appBuild: appBuild,
                    analysisCases: analysisDocuments.cases,
                    folderMapDocument: analysisDocuments.folderMap
                )
                // The archive is committed; report it even if Cancel arrived during the final move.
                exportConfirmation = AnalysisExportConfirmation(
                    title: "Image Analysis Project Exported",
                    url: destination
                )
            } catch is CancellationError {
                return
            } catch {
                reportExportError = error.localizedDescription.isEmpty
                    ? "The Image Analysis Project could not be exported."
                    : error.localizedDescription
            }
        }
    }

    private func chooseProjectArchiveAndImport() {
        guard projectArchiveTask == nil else { return }
        let openPanel = NSOpenPanel()
        openPanel.title = "Import Image Analysis Project"
        openPanel.prompt = "Open"
        openPanel.allowedContentTypes = [.photoIntelligenceProject, .zip]
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        guard openPanel.runModal() == .OK, let archiveURL = openPanel.url else { return }

        projectArchiveStatus = "Reading project…"
        projectArchiveTask = Task { @MainActor in
            defer {
                projectArchiveTask = nil
                projectArchiveStatus = nil
            }
            do {
                let preview = try await ImageAnalysisProjectArchive.inspect(archiveURL)
                try Task.checkCancellation()
                projectArchiveStatus = nil

                let savePanel = NSSavePanel()
                savePanel.title = "Choose Imported Project Folder"
                savePanel.prompt = "Import"
                savePanel.canCreateDirectories = true
                savePanel.allowedContentTypes = [.folder]
                savePanel.nameFieldStringValue = sanitizedProjectFolderName(preview.title)
                guard savePanel.runModal() == .OK, let destination = savePanel.url else { return }

                projectArchiveStatus = "Importing project…"
                _ = try await ImageAnalysisProjectArchive.importProject(
                    from: archiveURL,
                    to: destination
                )
                // The project is installed; open it even if Cancel arrived during the final move.
                onOpenImportedProject(destination)
            } catch is CancellationError {
                return
            } catch {
                reportExportError = error.localizedDescription.isEmpty
                    ? "The Image Analysis Project could not be imported."
                    : error.localizedDescription
            }
        }
    }

    private func sanitizedProjectFolderName(_ proposedName: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let components = proposedName.components(separatedBy: invalid)
        let cleaned = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Imported Photo Intelligence Project" : cleaned
    }

    private var imageRail: some View {
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
    }

    private var pixelAnalysisBody: some View {
        HSplitView {
            sourcePreview(showMarkupToolbar: true)
                .frame(minWidth: 520, minHeight: 360)
                .layoutPriority(1)

            Group {
                if isCaseReady {
                    pixelAnalysisInspector
                } else {
                    analysisLoadingPlaceholder
                }
            }
            .frame(minWidth: 350, idealWidth: 410, maxWidth: .infinity)
        }
    }

    private var pixelAnalysisInspector: some View {
        VStack(spacing: 0) {
            Picker("Pixel Analysis Inspector", selection: $pixelInspectorSection) {
                ForEach(AnalysisPixelInspectorSection.allCases, id: \.self) { section in
                    Text(section.label).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch pixelInspectorSection {
            case .evidence:
                VSplitView {
                    caseSidebar
                        .frame(minHeight: 190, idealHeight: 300)
                    analysisDetail
                        .frame(minHeight: 210, idealHeight: 340)
                }
            case .metadata:
                sourceFactsDetail
            case .scopes:
                AnalysisScopeWorkspace(
                    sourceImage: displayedScopeImage,
                    sourceMode: $scopeSourceMode,
                    selectedRegion: $selectedScopeRegion,
                    state: $scopeWorkspaceState
                )
                .frame(minHeight: 300)
            case .layers:
                VStack(alignment: .leading, spacing: 12) {
                    AnalysisCounterEvidenceView(annotations: model.annotations)
                    AnalysisAnnotationList(
                        annotations: model.annotations,
                        selectedAnnotationID: $selectedAnnotationID,
                        isReadOnly: model.sourceChanged,
                        onSetVisible: model.setPhotoAnnotationVisible,
                        onSetAllVisible: model.setAllPhotoAnnotationsVisible,
                        onSetGroupVisible: { model.setPhotoAnnotationsVisible(ids: $0, isVisible: $1) },
                        onEdit: presentPhotoAnnotationEditor,
                        onDelete: { id in
                            model.removeAnnotation(id: id)
                            if selectedAnnotationID == id { selectedAnnotationID = nil }
                        },
                        expandsToFill: true
                    )
                }
                .padding(14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pixel Analysis inspector")
    }

    private var osintBody: some View {
        HSplitView {
            VSplitView {
                sourcePreview(showMarkupToolbar: false)
                    .frame(minHeight: 260)

                if isCaseReady {
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
                } else {
                    analysisLoadingPlaceholder
                        .frame(minHeight: 170, idealHeight: 280)
                }
            }
            .frame(minWidth: 400, idealWidth: 620, maxWidth: 760)

            if isCaseReady {
                VSplitView {
                    AnalysisMapEvidenceView(
                        mapState: model.mapState,
                        embeddedLocation: model.embeddedLocation,
                        photoAnnotationToLocate: selectedPhotoAnnotation,
                        currentSourceURL: model.sourceURL,
                        folderAnnotations: model.workingFolderMapAnnotations,
                        globalAnnotations: model.globalMapAnnotations,
                        isReadOnly: model.sourceChanged,
                        onSetStyle: model.setMapStyle,
                        onSetTrafficVisible: model.setMapTrafficVisible,
                        onSet3DContentVisible: model.setMap3DContentVisible,
                        onSetViewport: model.setMapViewport,
                        onSetInvestigationLocation: { model.setInvestigationLocation($0) },
                        caseID: model.analysisCase?.id,
                        onSetLookedUpInvestigationLocation: {
                            model.setInvestigationLocation($0, requestedForCaseID: $1)
                        },
                        onApplyReverseGeocodedPlaceName: {
                            model.applyReverseGeocodedPlaceName($0, at: $1, requestedForCaseID: $2)
                        },
                        timestampEvidence: model.timestampEvidence,
                        onSetSolarOverlay: model.setSolarOverlay,
                        onClearSolarOverlay: model.clearSolarOverlay,
                        onSetAnnotation: model.setGlobalMapAnnotation,
                        onSetLocalAnnotation: model.setMapAnnotation,
                        onDeleteAnnotation: model.removeGlobalMapAnnotation,
                        annotationTool: $mapAnnotationTool,
                        sharedAnnotationStyle: $annotationStyle,
                        selectedAnnotationID: $selectedMapAnnotationID,
                        primaryActionRequestID: mapPrimaryActionRequestID,
                        finishShapeRequestID: mapFinishShapeRequestID,
                        cancelDraftRequestID: mapCancelDraftRequestID,
                        onDraftCountChanged: { mapDraftCoordinateCount = $0 }
                    )
                    .frame(minWidth: 520, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)

                    AnalysisMapLayersView(
                        globalAnnotations: model.globalMapAnnotations,
                        photoAnnotations: model.annotations,
                        folderAnnotations: model.workingFolderMapAnnotations,
                        currentCaseID: model.analysisCase?.id,
                        selectedPhotoAnnotationID: $selectedAnnotationID,
                        selectedAnnotationID: $selectedMapAnnotationID,
                        isReadOnly: model.sourceChanged,
                        onSetPhotoVisible: model.setPhotoAnnotationVisible,
                                onSetAllPhotosVisible: model.setAllPhotoAnnotationsVisible,
                                onSetPhotoGroupVisible: { model.setPhotoAnnotationsVisible(ids: $0, isVisible: $1) },
                        onEditPhotoAnnotation: presentPhotoAnnotationEditor,
                        onDeletePhotoAnnotation: model.removeAnnotation,
                        onSetGlobalVisible: model.setGlobalMapAnnotationVisible,
                        onSetAllGlobalsVisible: model.setAllGlobalMapAnnotationsVisible,
                        onEditGlobalAnnotation: presentMapAnnotationEditor,
                        onDeleteGlobalAnnotation: model.removeGlobalMapAnnotation,
                        onSetGlobalPhotoAnnotationLink: model.setGlobalMapAnnotationPhotoLink
                    )
                    .frame(minHeight: 220, idealHeight: 360, maxHeight: .infinity)
                }
                .frame(minWidth: 520, maxWidth: .infinity)
            } else {
                analysisLoadingPlaceholder
                    .frame(minWidth: 520, maxWidth: .infinity)
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
                : model.canUndoGlobalMapAnnotation,
            canRedo: activeMarkupSurface == .photo
                ? model.canRedoPhotoAnnotation
                : model.canRedoGlobalMapAnnotation,
            undoActionName: activeMarkupSurface == .photo
                ? model.photoAnnotationUndoActionName
                : model.globalMapAnnotationUndoActionName,
            redoActionName: activeMarkupSurface == .photo
                ? model.photoAnnotationRedoActionName
                : model.globalMapAnnotationRedoActionName,
            onUndo: activeMarkupSurface == .photo
                ? model.undoPhotoAnnotation
                : model.undoGlobalMapAnnotation,
            onRedo: activeMarkupSurface == .photo
                ? model.redoPhotoAnnotation
                : model.redoGlobalMapAnnotation,
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
        case .arrow, .rectangle, .ellipse, .counter: nil
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
                    if model.workspaceMode == .pixelAnalysis { pixelInspectorSection = .metadata }
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

                AnalysisCounterEvidenceView(annotations: model.annotations)

                if !model.annotations.isEmpty {
                    Button("Manage Annotation Layers…") { pixelInspectorSection = .layers }
                        .font(.caption)
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

    private var externalVerificationLinks: some View {
        Button {
            isVerificationToolsPresented = true
        } label: {
            Image(systemName: "checkmark.shield")
        }
        .accessibilityLabel("External Verification Tools")
        .help("External verification tools: source search, provenance, and image forensics")
        .popover(isPresented: $isVerificationToolsPresented, arrowEdge: .trailing) {
            verificationToolsPopover
        }
    }

    private var verificationToolsPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("External Verification Tools")
                        .font(.headline)
                    Spacer()
                    Button {
                        isVerificationToolsPresented = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close verification tools")
                }

                verificationToolsHeading("Source and context")
                verificationToolLink("TinEye", url: URL(string: "https://tineye.com/")!,
                                     description: "Find matching images and earlier uses online.")
                verificationToolLink("Google Lens", url: URL(string: "https://lens.google/")!,
                                     description: "Find related images, objects, and location clues.")

                Divider()
                verificationToolsHeading("Provenance and watermarks")
                verificationToolLink("Content Credentials Verify",
                                     url: URL(string: "https://verify.contentauthenticity.org/")!,
                                     description: "Inspect signed C2PA provenance and editing history when available.")
                verificationToolLink("Check Meta Content Seal", url: Self.metaContentSealCheckURL,
                                     description: "Open Meta’s official identification page.")
                verificationToolLink("SynthID Detector", url: Self.googleSynthIDCheckURL,
                                     description: "Open Google’s dedicated SynthID checking site.")

                Divider()
                verificationToolsHeading("Manipulation analysis")
                verificationToolLink("ImageWhisperer", url: Self.imageWhispererURL,
                                     description: "Investigate possible AI generation or image manipulation.")
                verificationToolLink("Forensically", url: URL(string: "https://29a.ch/photo-forensics/")!,
                                     description: "Inspect clone patterns, noise, compression, and metadata in your browser.")

                Divider()
                Text("Results are supporting evidence, not proof of authenticity. Missing credentials or watermarks do not establish manipulation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Links open the provider’s site. Photo Agent does not upload the image; you choose what to share there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
        }
        .frame(width: 380, height: 580)
    }

    private func verificationToolsHeading(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func verificationToolLink(_ title: String, url: URL, description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Link(destination: url) {
                Label(title, systemImage: "arrow.up.right.square")
            }
            .help(description)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourcePreview(showMarkupToolbar: Bool) -> some View {
        VStack(spacing: 10) {
            if model.workspaceMode == .pixelAnalysis, comparisonPixelMode != nil {
                HStack(spacing: 10) {
                    Text("Compare").font(.caption)
                        .fixedSize()
                    Picker("Comparison pixel view", selection: Binding(
                        get: { comparisonPixelMode ?? .normal },
                        set: { comparisonPixelMode = $0 }
                    )) {
                        ForEach(AnalysisPixelViewMode.analysisModes, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    Picker("Comparison channel", selection: $comparisonPixelChannel) {
                        ForEach(AnalysisPixelChannel.allCases, id: \.self) { channel in
                            Text(channel.displayName).tag(channel)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .disabled(comparisonPixelMode == .alpha)
                    Picker("Comparison layout", selection: $pixelComparisonLayout) {
                        Text("Side by Side").tag(ComparisonLayout.sideBySide)
                        Text("Stacked").tag(ComparisonLayout.stacked)
                        Text("Wipe").tag(ComparisonLayout.wipe)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    if pixelComparisonLayout == .wipe {
                        Slider(value: $pixelWipePosition, in: 0...1)
                            .frame(width: 110)
                            .accessibilityLabel("Wipe position")
                        Slider(value: $pixelWipeAngle, in: -180...180)
                            .frame(width: 90)
                            .accessibilityLabel("Wipe angle")
                        Text("\(Int(pixelWipeAngle))°").font(.caption.monospacedDigit())
                    }
                }
                .padding(.horizontal, 10)
                if let comparisonPixelMode, comparisonPixelMode != .normal || comparisonPixelChannel != .rgb {
                    Text("Comparison: \(comparisonPixelChannel.displayName) · \(comparisonPixelMode.methodLabel)")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let limitation = comparisonPixelMode.limitationLabel {
                        Text(limitation).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if pixelViewMode != .normal || pixelChannel != .rgb {
                Text("\(pixelChannel.displayName) · \(pixelViewMode.methodLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel("Pixel view method: \(pixelViewMode.methodLabel)")
            }

            if pixelViewMode == .levelSweep || comparisonPixelMode == .levelSweep {
                HStack {
                    Text("Brightness window")
                        .font(.caption)
                    Slider(value: $levelSweepCenter, in: 0...255, step: 1, onEditingChanged: { isLevelSweepEditing = $0 })
                        .accessibilityLabel("Level sweep brightness center")
                    Text("\(Int(levelSweepCenter))/255")
                        .font(.caption.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                }
            }

            if let limitation = pixelViewMode.limitationLabel {
                Label(limitation, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Pixel view limitation: \(limitation)")
            }

            AnalysisSourceThumbnail(
                url: previewSourceURL,
                representation: model.displayPreference,
                pixelViewMode: pixelViewMode,
                pixelChannel: pixelChannel,
                levelSweepCenter: Int(levelSweepCenter),
                isLevelSweepEditing: isLevelSweepEditing,
                comparisonPixelMode: model.workspaceMode == .pixelAnalysis ? comparisonPixelMode : nil,
                comparisonPixelChannel: comparisonPixelChannel,
                comparisonLayout: pixelComparisonLayout,
                wipePosition: $pixelWipePosition,
                wipeAngle: pixelWipeAngle,
                developSettings: model.developSettings,
                sourceOrientation: model.sourceOrientation,
                displayTransform: model.displayTransform,
                annotationTransform: model.annotationTransform,
                inspection: pixelInspection,
                developedRenderToken: model.developedRenderToken,
                isLoupeEnabled: $isLoupeEnabled,
                scopeSourceMode: scopeSourceMode,
                selectedScopeRegion: $selectedScopeRegion,
                annotations: model.annotations,
                annotationTool: $photoAnnotationTool,
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

            PixelInspectionReadout(inspection: pixelInspection)
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
        return model.globalMapAnnotations.first {
            $0.id == selectedMapAnnotationID
        }?.annotation
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
            model.removeGlobalMapAnnotation(id: selectedMapAnnotationID)
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
        let annotation = model.globalMapAnnotations.first {
            $0.id == annotationID
        }?.annotation
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
            let existing = model.globalMapAnnotations.first {
                $0.id == request.annotationID
            }?.annotation
            guard var annotation = existing else { return }
            annotation.text = storedLabel
            model.setGlobalMapAnnotation(annotation)
        }
    }

    @ViewBuilder
    private var sourceFactsDetail: some View {
        SourceFactsDetailView(
            facts: model.sourceFacts,
            rawMetadata: model.rawMetadata,
            run: model.sourceFactsRun,
            isReadOnly: model.sourceChanged || model.analysisCase == nil,
            onAddMetadataNote: { field, value in
                guard let analysisCase = model.analysisCase, !model.sourceChanged else { return }
                metadataNoteRequest = AnalysisMetadataNoteRequest(
                    caseID: analysisCase.id,
                    sourceName: model.sourceFacts?.filename ?? model.sourceURL?.lastPathComponent ?? "Source",
                    field: field,
                    value: value
                )
            },
            onCancel: {
                if let id = model.sourceFactsRun?.analyzerID { model.cancelAnalyzer(id) }
            },
            onRetry: {
                if let id = model.sourceFactsRun?.analyzerID { model.retryAnalyzer(id) }
            }
        )
    }

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
                    if model.workspaceMode == .pixelAnalysis {
                        ContentUnavailableView(
                            "Select a Finding",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("Select a finding to inspect its evidence, or open the Metadata tab for source facts.")
                        )
                    } else {
                        sourceFactsDetail
                    }
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
    @State private var includeAnalyticalScopes = true
    @State private var includeCanonicalPath = false
    @State private var includeCameraSerialNumber = false
    @State private var includeLocationCoordinates = false
    @State private var includeRawMetadata = false
    @State private var mapBasemap: AnalysisReportMapBasemap = .schematic

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
                if mapBasemap == .openStreetMap {
                    Text("This sends the visible map region as tile coordinates to OpenStreetMap. Tiles are used only for this export and are not stored in the URL cache.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Section("Pixel evidence") {
                    Toggle(
                        "Include full-image analytical scopes",
                        isOn: $includeAnalyticalScopes
                    )
                    Text("Adds Waveform, RGBY Parade, Vectorscope, and Chromaticity from the validated original source. Image previews and selection-only scopes are excluded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                        includeAnalyticalScopes: includeAnalyticalScopes,
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

private struct AnalysisCounterEvidenceView: View {
    let annotations: [AnalysisAnnotation]

    private var groups: [AnalysisAnnotationLayerGroup] {
        AnalysisAnnotationLayerGroup.groups(in: annotations.filter { $0.kind == .counter })
    }

    var body: some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Counter Evidence", systemImage: "number.circle")
                    .font(.caption.weight(.semibold))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(groups) { group in
                            HStack {
                                Circle().fill(group.color.swiftUIColor)
                                    .overlay(Circle().stroke(Color.secondary, lineWidth: 1))
                                    .frame(width: 10, height: 10)
                                    .accessibilityHidden(true)
                                Text(group.color.displayName)
                                Spacer()
                                Text("\(group.annotationIDs.count)").monospacedDigit().bold()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(height: min(CGFloat(groups.count) * 22, 100))
                Text("Manual counts · includes hidden markers · included in reports")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
        }
    }
}

/// Group visibility edits are persisted once and undo together; filters only narrow this list.
private struct AnalysisAnnotationLayerControls: View {
    let annotations: [AnalysisAnnotation]
    @Binding var filter: AnalysisAnnotationLayerFilter
    let isReadOnly: Bool
    let onSetVisible: (Set<UUID>, Bool) -> Void
    @State private var showsGroups = false

    private var groups: [AnalysisAnnotationLayerGroup] {
        AnalysisAnnotationLayerGroup.groups(in: annotations)
    }

    private var colors: [AnalysisAnnotationColor] {
        var seen = Set<String>()
        return annotations.compactMap {
            seen.insert($0.style.color.stableIdentifier).inserted ? $0.style.color : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Picker("Type", selection: $filter.kind) {
                    Text("All Types").tag(AnalysisAnnotationKind?.none)
                    ForEach(AnalysisAnnotationKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(Optional(kind))
                    }
                }
                Picker("Color", selection: $filter.colorID) {
                    Text("All Colors").tag(String?.none)
                    ForEach(colors, id: \.stableIdentifier) { color in
                        Text(color.displayName).tag(Optional(color.stableIdentifier))
                    }
                }
            }
            .labelsHidden()
            .controlSize(.small)

            HStack(spacing: 8) {
                let ids = filter.matchingIDs(in: annotations)
                Text("\(ids.count) of \(annotations.count) layers")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if filter.kind != nil || filter.colorID != nil {
                    Button("Reset") { filter = AnalysisAnnotationLayerFilter() }
                }
                Button { onSetVisible(ids, true) } label: {
                    Image(systemName: "eye")
                }
                .help("Show all layers matching these filters")
                .accessibilityLabel("Show matching layers")
                .disabled(isReadOnly || ids.isEmpty)
                Button { onSetVisible(ids, false) } label: {
                    Image(systemName: "eye.slash")
                }
                .help("Hide all layers matching these filters")
                .accessibilityLabel("Hide matching layers")
                .disabled(isReadOnly || ids.isEmpty)
            }
            .buttonStyle(.borderless)
            .font(.caption)

            DisclosureGroup("Groups by Type and Color", isExpanded: $showsGroups) {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(groups) { group in
                            HStack {
                                Image(systemName: group.kind.systemImage)
                                    .foregroundStyle(group.color.swiftUIColor)
                                Button {
                                    filter.kind = group.kind
                                    filter.colorID = group.color.stableIdentifier
                                } label: {
                                    Text("\(group.color.displayName) \(group.kind.displayName)")
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .help("Filter the layer list to this group")
                                Spacer(minLength: 3)
                                Text("\(group.visibleCount)/\(group.annotationIDs.count)")
                                    .monospacedDigit().foregroundStyle(.secondary)
                                    .accessibilityLabel("\(group.visibleCount) visible of \(group.annotationIDs.count)")
                                Button {
                                    onSetVisible(group.annotationIDs, group.visibleCount == 0)
                                } label: {
                                    Image(systemName: group.visibleCount == 0 ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                                .disabled(isReadOnly)
                                .accessibilityLabel("\(group.visibleCount == 0 ? "Show" : "Hide") \(group.color.displayName) \(group.kind.displayName) layers")
                            }
                        }
                    }
                    .padding(.top, 5)
                }
                .frame(maxHeight: 150)
            }
            .font(.caption)
        }
    }
}

private struct AnalysisAnnotationList: View {
    let annotations: [AnalysisAnnotation]
    @Binding var selectedAnnotationID: UUID?
    let isReadOnly: Bool
    let onSetVisible: (UUID, Bool) -> Void
    let onSetAllVisible: (Bool) -> Void
    let onSetGroupVisible: (Set<UUID>, Bool) -> Void
    let onEdit: (UUID) -> Void
    let onDelete: (UUID) -> Void
    var expandsToFill = false
    @State private var filter = AnalysisAnnotationLayerFilter()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PHOTO LAYERS")
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

            AnalysisAnnotationLayerControls(
                annotations: annotations, filter: $filter,
                isReadOnly: isReadOnly, onSetVisible: onSetGroupVisible
            )

            List(selection: $selectedAnnotationID) {
                ForEach(Array(annotations.enumerated()).filter { filter.includes($0.element) }, id: \.element.id) { index, annotation in
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
            .frame(minHeight: 90, idealHeight: 150, maxHeight: expandsToFill ? .infinity : 210)
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
    let globalAnnotations: [AnalysisGlobalMapAnnotation]
    let photoAnnotations: [AnalysisAnnotation]
    let folderAnnotations: [AnalysisImageMapAnnotation]
    let currentCaseID: UUID?
    @Binding var selectedPhotoAnnotationID: UUID?
    @Binding var selectedAnnotationID: UUID?
    let isReadOnly: Bool
    let onSetPhotoVisible: (UUID, Bool) -> Void
    let onSetAllPhotosVisible: (Bool) -> Void
    let onSetPhotoGroupVisible: (Set<UUID>, Bool) -> Void
    let onEditPhotoAnnotation: (UUID) -> Void
    let onDeletePhotoAnnotation: (UUID) -> Void
    let onSetGlobalVisible: (UUID, Bool) -> Void
    let onSetAllGlobalsVisible: (Bool) -> Void
    let onEditGlobalAnnotation: (UUID) -> Void
    let onDeleteGlobalAnnotation: (UUID) -> Void
    let onSetGlobalPhotoAnnotationLink: (UUID, UUID, Bool) -> Void
    @State private var photoFilter = AnalysisAnnotationLayerFilter()

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

            AnalysisCounterEvidenceView(annotations: photoAnnotations)
            AnalysisAnnotationLayerControls(
                annotations: photoAnnotations, filter: $photoFilter,
                isReadOnly: isReadOnly, onSetVisible: onSetPhotoGroupVisible
            )

            if photoAnnotations.isEmpty {
                ContentUnavailableView(
                    "No Photo Annotations",
                    systemImage: "photo.badge.plus",
                    description: Text("Use the Photo tools above to mark visible evidence.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(Array(photoAnnotations.enumerated().reversed()).filter { photoFilter.includes($0.element) }, id: \.element.id) {
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

                    Button("Show All") { onSetAllGlobalsVisible(true) }
                    .disabled(isReadOnly || displayedMapAnnotations.allSatisfy(\.isVisible))
                    Button("Hide All") { onSetAllGlobalsVisible(false) }
                    .disabled(isReadOnly || displayedMapAnnotations.allSatisfy({ !$0.isVisible }))
                }
            }

            if displayedAnnotationsAreEmpty {
                ContentUnavailableView(
                    "No Map Markup",
                    systemImage: "map",
                    description: Text(
                        "Use the Map tools above to add a map layer shared by this working folder."
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
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
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map annotations")
    }

    private func photoLayerRow(_ annotation: AnalysisAnnotation, index: Int) -> some View {
        let linkedMapAnnotations = globalMapAnnotationsLinked(to: annotation.id)
        return HStack(spacing: 8) {
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
                        if !linkedMapAnnotations.isEmpty {
                            Label(
                                "\(linkedMapAnnotations.count) linked map "
                                    + (linkedMapAnnotations.count == 1
                                        ? "annotation"
                                        : "annotations"),
                                systemImage: "link"
                            )
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
                if globalAnnotations.isEmpty {
                    Text("Add an annotation to the working-folder map first")
                } else {
                    ForEach(Array(globalAnnotations.enumerated()), id: \.element.id) {
                        mapIndex, globalAnnotation in
                        let isLinked = linkedMapAnnotations.contains {
                            $0.id == globalAnnotation.id
                        }
                        Toggle(
                            layerName(globalAnnotation.annotation, index: mapIndex),
                            isOn: Binding(
                                get: { isLinked },
                                set: { linked in
                                    onSetGlobalPhotoAnnotationLink(
                                        globalAnnotation.id,
                                        annotation.id,
                                        linked
                                    )
                                }
                            )
                        )
                    }
                }
            } label: {
                Image(systemName: linkedMapAnnotations.isEmpty
                    ? "link.badge.plus"
                    : "link")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isReadOnly || currentCaseID == nil)
            .help("Connect this photo annotation to working-folder map annotations")
            .accessibilityLabel("Link photo annotation to map annotations")

            Button {
                onEditPhotoAnnotation(annotation.id)
            } label: {
                Image(systemName: annotation.note == nil && annotation.text == nil ? "note.text.badge.plus" : "note.text")
            }
            .buttonStyle(.borderless)
            .disabled(isReadOnly)
            .help("Edit this photo annotation's label and note")
            .accessibilityLabel("Edit photo annotation label and note")

            Button {
                onSetPhotoVisible(annotation.id, !annotation.isVisible)
            } label: {
                Image(systemName: annotation.isVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .disabled(isReadOnly)
            .help(annotation.isVisible ? "Hide photo annotation" : "Show photo annotation")
            .accessibilityLabel(annotation.isVisible ? "Hide photo annotation" : "Show photo annotation")
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

    private func globalMapAnnotationsLinked(
        to photoAnnotationID: UUID
    ) -> [AnalysisGlobalMapAnnotation] {
        guard let currentCaseID else { return [] }
        let reference = AnalysisPhotoAnnotationReference(
            caseID: currentCaseID,
            annotationID: photoAnnotationID
        )
        return globalAnnotations.filter {
            $0.isLinked(to: reference)
        }
    }

    private var displayedAnnotationsAreEmpty: Bool {
        globalAnnotations.isEmpty && folderAnnotations.isEmpty
    }

    private var displayedMapAnnotations: [AnalysisMapAnnotation] {
        globalAnnotations.map(\.annotation)
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
            .accessibilityLabel("Link folder map annotation to photo annotations")

            Button {
                onSetGlobalVisible(annotation.id, !annotation.isVisible)
            } label: {
                Image(systemName: annotation.isVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .disabled(isReadOnly)
            .help(annotation.isVisible ? "Hide folder map annotation" : "Show folder map annotation")
            .accessibilityLabel(annotation.isVisible ? "Hide folder map annotation" : "Show folder map annotation")
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
        return globalAnnotation.isLinked(
            to: AnalysisPhotoAnnotationReference(
                caseID: currentCaseID,
                annotationID: photoAnnotationID
            )
        )
    }

    private func layerName(_ annotation: AnalysisMapAnnotation, index: Int) -> String {
        if let text = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return "\(annotation.kind.displayName) \(index + 1)"
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

private struct AnalysisMetadataNoteRequest: Identifiable {
    let id = UUID()
    let caseID: UUID
    let sourceName: String
    let field: String
    let value: String
}

private struct AnalysisMetadataNoteEditor: View {
    let request: AnalysisMetadataNoteRequest
    let onSave: (AnalysisObservation) -> Void
    let onCancel: () -> Void
    @State private var comment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Metadata to Case Note")
                .font(.headline)
            Text(request.sourceName)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.field).font(.subheadline.weight(.semibold))
                    Text(request.value).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            Text("Comment (optional)").font(.subheadline)
            TextEditor(text: $comment)
                .frame(height: 120)
                .border(Color.secondary.opacity(0.3))
                .accessibilityLabel("Metadata case note comment")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Note") {
                    let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                    let evidence = "Source: \(request.sourceName)\n\(request.field): \(request.value)"
                    onSave(AnalysisObservation(
                        title: "Metadata: \(request.field)",
                        note: evidence + (trimmed.isEmpty ? "" : "\n\nComment: \(trimmed)")
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
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

            ScrollViewReader { proxy in
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
                            .id(image.url)
                            .buttonStyle(.plain)
                            .contextMenu {
                                let count = annotationCount(image)
                                Button("Copy All Photo Annotations", systemImage: "doc.on.doc") {
                                    onCopyAnnotations(image)
                                }
                                .disabled(count == 0)

                                Button(
                                    copiedAnnotationCount == 1
                                        ? "Paste 1 Photo Annotation"
                                        : "Paste \(copiedAnnotationCount) Photo Annotations",
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
                .onChange(of: selectedURL) { _, target in
                    guard let target else { return }
                    // With no anchor, an already visible thumbnail stays in place.
                    proxy.scrollTo(target)
                }
                .onAppear {
                    // Wait for the lazy stack's first layout before revealing an initial selection.
                    DispatchQueue.main.async {
                        guard let selectedURL else { return }
                        proxy.scrollTo(selectedURL)
                    }
                }
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
    @State private var thumbnailUnavailable = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.10))

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else if thumbnailUnavailable {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
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
            thumbnailUnavailable = false
            if let cached = thumbnailService.thumbnail(for: image.url) {
                thumbnail = cached
            } else {
                thumbnail = await thumbnailService.loadThumbnail(for: image.url)
                // A failed load shows a placeholder instead of spinning forever.
                thumbnailUnavailable = thumbnail == nil && !Task.isCancelled
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
        if kind == .counter {
            let number = counterNumber.map(String.init) ?? "?"
            let label = text.map { " · " + $0 } ?? ""
            return "\(style.color.displayName) Counter \(number)\(label)"
        }
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
        case .counter: "Counter"
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
        case .counter: "number.circle"
        }
    }
}

private struct SourceFactsDetailView: View {
    let facts: AnalysisSourceFacts?
    let rawMetadata: [AnalysisRawMetadataEntry]
    let run: AnalysisAnalyzerRun?
    let isReadOnly: Bool
    let onAddMetadataNote: (String, String) -> Void
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
                                .contentShape(Rectangle())
                                .contextMenu {
                                    Button("Add to Case Note…", systemImage: "note.text.badge.plus") {
                                        onAddMetadataNote("\(entry.namespace) · \(entry.key)", entry.value)
                                    }
                                    .disabled(isReadOnly)
                                }
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
            .contentShape(Rectangle())
            .contextMenu {
                Button("Add to Case Note…", systemImage: "note.text.badge.plus") {
                    onAddMetadataNote(label, value)
                }
                .disabled(isReadOnly)
            }
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
    let pixelChannel: AnalysisPixelChannel
    let levelSweepCenter: Int
    let isLevelSweepEditing: Bool
    let comparisonPixelMode: AnalysisPixelViewMode?
    let comparisonPixelChannel: AnalysisPixelChannel
    let comparisonLayout: ComparisonLayout
    @Binding var wipePosition: CGFloat
    let wipeAngle: CGFloat
    let developSettings: CameraRawSettings?
    let sourceOrientation: Int
    let displayTransform: DisplayImageTransform?
    let annotationTransform: DisplayImageTransform?
    let inspection: AnalysisPixelInspectionState
    /// `model.developedRenderToken`; computed once per settings change.
    let developedRenderToken: String?
    @Binding var isLoupeEnabled: Bool
    let scopeSourceMode: AnalysisScopeSourceMode
    @Binding var selectedScopeRegion: CGRect?
    let annotations: [AnalysisAnnotation]
    @Binding var annotationTool: AnalysisAnnotationTool
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
    @State private var previewFailed = false
    @State private var comparisonImage: NSImage?
    @State private var loadedComparisonKey: AnalysisDerivedViewCacheKey?
    @State private var failedComparisonKey: AnalysisDerivedViewCacheKey?
    @State private var loupeSourceIdentity: SourcePreviewIdentity?
    @State private var loupeSourceCGImage: CGImage?
    @State private var loupeLoadFailedIdentity: SourcePreviewIdentity?
    @State private var zoomedImage: NSImage?
    @State private var inspectionViewCGImage: CGImage?
    @State private var inspectionRenderFailedIdentity: PreviewIdentity?
    @State private var loadedZoomedPreviewIdentity: PreviewIdentity?
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
    /// Read only by the event monitors, never by `body`; a reference box keeps per-move
    /// pointer updates from re-rendering this view.
    @State private var pointer = AnalysisPointerLocation()
    @State private var loupeCorner: ImageInspectionLoupePlacement.Corner = .topTrailing
    @State private var eventWindow = WorkspaceEventWindowReference()
    @State private var scrollEventMonitor: Any?
    @State private var keyEventMonitor: Any?
    @State private var isSpaceHandToolActive = false

    private let loupeDisplaySize: CGFloat = 198

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    CheckerboardBackground(tileSize: 12)
                        .opacity(0.16)
                    ZStack {
                    if let image {
                    pixelImageContent(image)


                    if inspection.hasSample {
                        PixelInspectionCrosshairLayer(
                            inspection: inspection,
                            geometries: inspectionGeometries(
                                image: image,
                                containerSize: geometry.size
                            )
                        )
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

                    } else if previewFailed {
                        ContentUnavailableView("Analysis Preview Unavailable", systemImage: "photo.badge.exclamationmark",
                                               description: Text("Try another analysis mode or source representation."))
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
                        inspection.update(nil)
                        return
                    }
                    inspection.update(makeInspectionSample(
                        at: point,
                        transform: displayTransform
                    ))
                case .ended:
                    inspection.update(nil)
                }
            }
            .accessibilityAction(named: "Inspect center pixel") {
                guard let displayTransform else { return }
                inspection.update(makeInspectionSample(
                    at: CGPoint(x: 0.5, y: 0.5),
                    transform: displayTransform
                ))
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

                if isLoupeEnabled, inspection.hasSample {
                    AnalysisTruePixelLoupeLayer(
                        inspection: inspection,
                        sourceImage: loupeViewImage,
                        isUnavailable: (loupeLoadFailedIdentity != nil
                            && loupeLoadFailedIdentity == loupeLoadIdentity)
                            || (inspectionRenderFailedIdentity != nil && inspectionRenderFailedIdentity == zoomedPreviewIdentity),
                        viewLabel: pixelViewLabel(pixelViewMode, channel: pixelChannel),
                        isBoundedPreview: [.compressionResidual, .noiseResidual, .levelSweep, .cloneDetection].contains(pixelViewMode),
                        representation: representation,
                        displaySize: loupeDisplaySize
                    )
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: loupeAlignment)
                    .allowsHitTesting(false)
                    .accessibilityHidden(false)
                }

                if annotationTool == .hand || isSpaceHandToolActive {
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
                        pointer.location = location
                        let corner = ImageInspectionLoupePlacement.corner(
                            avoiding: location, in: geometry.size, retaining: loupeCorner
                        )
                        // Only a corner change should re-render the source view.
                        if corner != loupeCorner { loupeCorner = corner }
                    case .ended:
                        pointer.location = nil
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
        .background(WorkspaceEventWindowReader(reference: eventWindow))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let owner = eventWindow.window,
                  let resigned = notification.object as? NSWindow, resigned === owner else { return }
            resetTransientInput()
        }
        .onAppear {
            installScrollEventMonitor()
            installKeyEventMonitor()
        }
        .onDisappear {
            removeScrollEventMonitor()
            removeKeyEventMonitor()
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
                pixelChannel: pixelChannel,
                levelSweepCenter: pixelViewMode == .levelSweep ? levelSweepCenter : 128,
                isLevelSweepEditing: pixelViewMode == .levelSweep && isLevelSweepEditing,
                sourceOrientation: sourceOrientation,
                renderToken: renderToken
            )
        ) {
            previewFailed = false
            guard let url else { image = nil; onImageLoaded(nil); return }
            let sourceIdentity = SourcePreviewIdentity(
                url: url,
                representation: representation,
                sourceOrientation: sourceOrientation,
                renderToken: renderToken
            )
            if loadedSourceIdentity != sourceIdentity {
                image = nil
                comparisonImage = nil
                resetZoom()
                cancelPolygonDraft()
                onImageLoaded(nil)
            }
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
                if let decoded = await AnalysisSourcePreviewCache.shared.image(
                    for: sourceIdentity,
                    settings: settings
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
                source: source,
                levelSweepCenter: levelSweepCenter,
                channel: pixelChannel,
                isInteracting: isLevelSweepEditing
            )
            let rendered = await AnalysisDerivedViewService.shared.image(
                for: cacheKey,
                source: source
            )
            guard !Task.isCancelled else { return }
            guard let rendered else {
                previewFailed = true
                image = nil
                onImageLoaded(nil)
                return
            }
            image = mode == .normal && pixelChannel == .rgb
                ? loadedImage
                : NSImage(cgImage: rendered, size: loadedImage.size)
            if mode != .levelSweep || !isLevelSweepEditing { onImageLoaded(rendered) }
        }
        .task(id: comparisonRenderKey) {
            failedComparisonKey = nil
            guard let key = comparisonRenderKey,
                  let source = comparisonRenderSource else {
                comparisonImage = nil
                loadedComparisonKey = nil
                return
            }
            let rendered = await AnalysisDerivedViewService.shared.image(for: key, source: source)
            guard !Task.isCancelled else { return }
            guard let rendered else { failedComparisonKey = key; return }
            comparisonImage = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
            loadedComparisonKey = key
        }
        .onChange(of: url) {
            // The native-resolution decode can be hundreds of megabytes; never carry it to
            // another photo.
            releaseLoupeSource()
        }
        .task(id: loupeLoadIdentity) {
            guard let identity = loupeLoadIdentity,
                  let displayTransform else {
                if loupeSourceIdentity != nil, loupeSourceIdentity != currentSourceIdentity {
                    releaseLoupeSource()
                }
                return
            }
            if loupeSourceIdentity == identity, loupeSourceCGImage != nil {
                return
            }
            // A pointer passing over the image must not start a full-resolution decode; wait
            // for it to dwell. Zoom needs the pixels immediately.
            if zoomScale <= 1 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }

            loupeSourceCGImage = nil
            loupeSourceIdentity = nil
            loupeLoadFailedIdentity = nil
            let settings = identity.representation == .developed ? developSettings : nil
            let maximumPixelSize = ceil(max(
                displayTransform.displayedPixelSize.width,
                displayTransform.displayedPixelSize.height
            ))
            let fullResolutionImage = await FullScreenImageCache.decodedEditedPreview(
                for: identity.url,
                settings: settings,
                orientation: identity.sourceOrientation,
                screenMaxPx: maximumPixelSize
            )
            guard !Task.isCancelled else { return }
            guard let fullResolutionImage else {
                loupeLoadFailedIdentity = identity
                return
            }
            loupeSourceIdentity = identity
            loupeSourceCGImage = fullResolutionImage
        }
        .task(id: zoomedPreviewIdentity) {
            zoomedImage = nil
            inspectionViewCGImage = nil
            inspectionRenderFailedIdentity = nil
            loadedZoomedPreviewIdentity = nil
            guard let identity = zoomedPreviewIdentity,
                  let sourceIdentity = loupeSourceIdentity,
                  let source = loupeSourceCGImage else { return }
            let key = AnalysisDerivedViewCacheKey(
                sourceIdentifier: sourceIdentity.derivedViewCacheIdentifier,
                mode: identity.pixelViewMode,
                source: source,
                levelSweepCenter: identity.levelSweepCenter,
                channel: identity.pixelChannel,
                isInteracting: identity.isLevelSweepEditing
            )
            let rendered = await AnalysisDerivedViewService.shared.image(for: key, source: source)
            guard !Task.isCancelled else { return }
            guard let rendered else { inspectionRenderFailedIdentity = identity; return }
            inspectionViewCGImage = rendered
            zoomedImage = NSImage(
                cgImage: rendered,
                size: NSSize(width: rendered.width, height: rendered.height)
            )
            loadedZoomedPreviewIdentity = identity
        }
    }

    /// Reads RGBA from the full-resolution decode once it is loaded for the displayed source;
    /// until then the bounded preview is sampled and the readout labels it as a preview value.
    private func makeInspectionSample(
        at point: CGPoint,
        transform: DisplayImageTransform
    ) -> ImageInspectionSample {
        let selected = ImageInspectionColorSource.select(
            fullResolution: loupeSourceCGImage,
            fullResolutionMatchesSource: loupeSourceIdentity != nil
                && loupeSourceIdentity == currentSourceIdentity,
            preview: sourceCGImage
        )
        return ImageInspectionSample(
            normalizedDisplayPoint: point,
            transform: transform,
            rgba16: selected.flatMap {
                SourcePixelSampler.rgba16(in: $0.image, atDisplayPoint: point)
            },
            rgbaSource: selected?.source
        )
    }

    private var currentSourceIdentity: SourcePreviewIdentity? {
        guard let url else { return nil }
        return SourcePreviewIdentity(
            url: url,
            representation: representation,
            sourceOrientation: sourceOrientation,
            renderToken: renderToken
        )
    }

    private var renderToken: String? {
        representation == .developed ? developedRenderToken : nil
    }

    private func releaseLoupeSource() {
        loupeSourceCGImage = nil
        loupeSourceIdentity = nil
        loupeLoadFailedIdentity = nil
        zoomedImage = nil
        inspectionViewCGImage = nil
        inspectionRenderFailedIdentity = nil
        loadedZoomedPreviewIdentity = nil
    }

    // Keep the bounded preview for initial display, scopes and the pixel readout, but use the
    // loupe's original-resolution decode for the zoomed canvas and the visible loupe. Hovering
    // with the loupe off reads preview pixels (labelled as such) and never decodes natively.
    // Zoom must request it even without a hover sample (for example with a trackpad pinch).
    private var loupeLoadIdentity: SourcePreviewIdentity? {
        guard (isLoupeEnabled && inspection.hasSample) || zoomScale > 1 else { return nil }
        return currentSourceIdentity
    }

    private var zoomedPreviewIdentity: PreviewIdentity? {
        guard zoomScale > 1 || (isLoupeEnabled && inspection.hasSample),
              let source = loupeSourceIdentity,
              source == loupeLoadIdentity,
              loupeSourceCGImage != nil else { return nil }
        return PreviewIdentity(
            url: source.url,
            representation: source.representation,
            pixelViewMode: pixelViewMode,
            pixelChannel: pixelChannel,
            levelSweepCenter: pixelViewMode == .levelSweep ? levelSweepCenter : 128,
            isLevelSweepEditing: pixelViewMode == .levelSweep && isLevelSweepEditing,
            sourceOrientation: source.sourceOrientation,
            renderToken: source.renderToken
        )
    }

    private var loupeViewImage: CGImage? {
        guard loupeSourceIdentity == loupeLoadIdentity else { return nil }
        if pixelViewMode == .normal && pixelChannel == .rgb { return loupeSourceCGImage }
        guard let identity = zoomedPreviewIdentity, loadedZoomedPreviewIdentity == identity else { return nil }
        return inspectionViewCGImage
    }

    private var displayedZoomedImage: NSImage? {
        guard zoomScale > 1, let identity = zoomedPreviewIdentity,
              loadedZoomedPreviewIdentity == identity else { return nil }
        return zoomedImage
    }

    private var comparisonRenderSource: CGImage? {
        if zoomScale > 1, loupeSourceIdentity == loupeLoadIdentity,
           let source = loupeSourceCGImage { return source }
        return sourceCGImage
    }

    private var comparisonRenderKey: AnalysisDerivedViewCacheKey? {
        guard let mode = comparisonPixelMode, let source = comparisonRenderSource,
              let identity = loadedSourceIdentity else { return nil }
        return AnalysisDerivedViewCacheKey(sourceIdentifier: identity.derivedViewCacheIdentifier,
                                           mode: mode, source: source, levelSweepCenter: levelSweepCenter, channel: comparisonPixelChannel,
                                           isInteracting: isLevelSweepEditing)
    }

    private func pixelViewLabel(_ mode: AnalysisPixelViewMode, channel: AnalysisPixelChannel) -> String {
        mode == .alpha ? mode.displayName : "\(channel.displayName) · \(mode.displayName)"
    }

    @ViewBuilder
    private func pixelImageContent(_ primary: NSImage) -> some View {
        let primaryImage = displayedZoomedImage ?? primary
        if let mode = comparisonPixelMode {
            switch comparisonLayout {
            case .sideBySide:
                HStack(spacing: 8) {
                    analysisImagePane(primaryImage, label: pixelViewLabel(pixelViewMode, channel: pixelChannel))
                    comparisonImagePane(mode)
                }
            case .stacked:
                VStack(spacing: 8) {
                    analysisImagePane(primaryImage, label: pixelViewLabel(pixelViewMode, channel: pixelChannel))
                    comparisonImagePane(mode)
                }
            case .wipe:
                ZStack {
                    analysisImagePane(primaryImage, label: pixelViewLabel(pixelViewMode, channel: pixelChannel), showsLabel: false)
                    comparisonImagePane(mode, showsLabel: false)
                        .mask(ComparisonWipeMask(position: wipePosition, angleDegrees: wipeAngle))
                    GeometryReader { geometry in
                        let rect = CGRect(origin: .zero, size: geometry.size)
                        ComparisonWipeDivider(position: wipePosition, angleDegrees: wipeAngle)
                            .stroke(.white, lineWidth: 2)
                            .overlay {
                                ComparisonWipeDivider(position: wipePosition, angleDegrees: wipeAngle)
                                    .stroke(.white.opacity(0.001), lineWidth: 24)
                                    .contentShape(ComparisonWipeDivider(position: wipePosition, angleDegrees: wipeAngle).stroke(lineWidth: 24))
                                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                        wipePosition = ComparisonWipeGeometry.position(
                                            for: value.location, in: rect, angleDegrees: wipeAngle
                                        )
                                    })
                                    .help("Drag to move the wipe")
                            }
                    }
                    VStack {
                        HStack {
                            Text(pixelViewLabel(mode, channel: comparisonPixelChannel))
                            Spacer()
                            Text(pixelViewLabel(pixelViewMode, channel: pixelChannel))
                        }
                        .font(.caption).padding(6).background(.ultraThinMaterial)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
        } else {
            analysisImagePane(primaryImage, label: pixelViewLabel(pixelViewMode, channel: pixelChannel), showsLabel: false)
        }
    }

    @ViewBuilder
    private func comparisonImagePane(_ mode: AnalysisPixelViewMode, showsLabel: Bool = true) -> some View {
        if failedComparisonKey != nil, failedComparisonKey == comparisonRenderKey {
            ContentUnavailableView("Analysis Preview Unavailable", systemImage: "photo.badge.exclamationmark")
        } else if let loaded = loadedComparisonKey, let requested = comparisonRenderKey,
           loaded.sourceIdentifier == requested.sourceIdentifier,
           loaded.mode == requested.mode, loaded.channel == requested.channel,
           loaded.pixelWidth == requested.pixelWidth, loaded.pixelHeight == requested.pixelHeight,
           let comparisonImage {
            analysisImagePane(comparisonImage, label: pixelViewLabel(mode, channel: comparisonPixelChannel), showsLabel: showsLabel)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
            guard eventWindow.ownsEvent(in: event.window) else {
                resetTransientInput()
                return event
            }
            guard let pointerLocationInViewport = pointer.location,
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

    private func installKeyEventMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
            event in
            handleKeyEvent(event)
        }
    }

    private func removeKeyEventMonitor() {
        guard let keyEventMonitor else { return }
        NSEvent.removeMonitor(keyEventMonitor)
        self.keyEventMonitor = nil
        resetTransientInput()
    }

    private func resetTransientInput() {
        isSpaceHandToolActive = false
        panDragStartOffset = nil
        zoomGestureStartScale = nil
        pointer.location = nil
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Reset a held gesture on ownership loss, but leave the foreign key-up
        // untouched so its real window can finish its own interaction.
        guard eventWindow.ownsEvent(in: event.window) else {
            resetTransientInput()
            return event
        }
        let isKeyDown = event.type == .keyDown
        let isKeyUp = event.type == .keyUp

        // Space is a momentary override: releasing it restores the selected markup tool.
        // Handle key-up even if the pointer left the viewport during the drag.
        if event.keyCode == 49, isKeyUp, isSpaceHandToolActive {
            isSpaceHandToolActive = false
            panDragStartOffset = nil
            NSCursor.arrow.set()
            return nil
        }

        let responder = event.window?.firstResponder
        let textEditorOwnsInput = responder is NSText || responder is NSTextView
        guard pointer.location != nil, !textEditorOwnsInput else {
            return event
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return event }

        if isKeyDown, event.charactersIgnoringModifiers?.lowercased() == "z" {
            if !event.isARepeat { isLoupeEnabled.toggle() }
            return nil
        }

        if event.keyCode == 49, isKeyDown {
            isSpaceHandToolActive = true
            NSCursor.openHand.set()
            return nil
        }

        guard isKeyDown,
              !event.isARepeat,
              !annotationsAreReadOnly,
              let key = event.charactersIgnoringModifiers,
              let tool = AnalysisAnnotationTool.photoTool(forShortcut: key) else {
            return event
        }
        annotationTool = tool
        return nil
    }

    private var loupeAlignment: Alignment {
        switch loupeCorner {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
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
        guard comparisonPixelMode != nil, comparisonLayout != .wipe else { return [bounds] }
        if comparisonLayout == .stacked {
            let height = max(0, (containerSize.height - 8) / 2)
            return [CGRect(x: 0, y: 0, width: containerSize.width, height: height),
                    CGRect(x: 0, y: height + 8, width: containerSize.width, height: height)]
        }
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
        guard kind != .label, kind != .counter else { return true }
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

        if kind == .counter {
            // A click adds one marker. Ignore drags so accidental movement does
            // not add counts while the user is navigating a crowded image.
            guard hypot(
                value.location.x - value.startLocation.x,
                value.location.y - value.startLocation.y
            ) < 3,
            let point = geometry.normalizedDisplayPoint(fromViewPoint: value.location) else {
                return true
            }
            let annotation = AnalysisAnnotation(
                kind: .counter,
                geometry: .anchor(coordinateMapper.annotationPoint(from: point)),
                style: annotationStyle
            )
            onSetAnnotation(annotation)
            // Leave the new marker unselected so choosing another color starts
            // a separate counter instead of recoloring the marker just placed.
            selectedAnnotationID = nil
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
    let pixelChannel: AnalysisPixelChannel
    let levelSweepCenter: Int
    let isLevelSweepEditing: Bool
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

/// The 2,048 px source previews of the last few photos, so returning to a photo or opening the
/// prefetched next one shows it at once. A decode that only cancelled waiters (and no prefetch)
/// still want is cancelled, so rapid navigation does not pile up decodes.
@MainActor
private final class AnalysisSourcePreviewCache {
    static let shared = AnalysisSourcePreviewCache()

    /// 2,048 px previews are 16–64 MB each depending on bit depth; keep the set small.
    private let capacity = 4
    private let screenMaxPixelSize: CGFloat = 2_048
    private var entries: [(identity: SourcePreviewIdentity, image: CGImage)] = []
    private var inFlight: [SourcePreviewIdentity: Decode] = [:]
    private var prefetchIdentity: SourcePreviewIdentity?
    /// This fixed-size cache sits outside the proportional budget; it still yields on memory
    /// pressure (alongside the other derived analysis rasters, at the warning tier).
    private var pressureRegistration: ImageMemoryCoordinator.Registration?

    private init() {
        pressureRegistration = ImageMemoryCoordinator.shared.registerPressureEviction(
            level: .warning
        ) { [weak self] in
            Task { @MainActor in self?.evictForMemoryPressure() }
        }
    }

    /// Memory pressure: drop cached previews and the speculative prefetch, but keep decodes a
    /// visible view is still waiting for.
    private func evictForMemoryPressure() {
        entries.removeAll()
        if let prefetch = prefetchIdentity {
            prefetchIdentity = nil
            cancelIfUnwanted(prefetch)
        }
    }

    /// Drops every cached preview and the prefetch (an Analysis workspace closed). The cache is
    /// shared by every window, so decodes another Analysis window is still waiting for keep
    /// running; only decodes nobody waits for are cancelled.
    func removeAll() {
        entries.removeAll()
        prefetchIdentity = nil
        for identity in Array(inFlight.keys) {
            cancelIfUnwanted(identity)
        }
    }

    private final class Decode {
        let task: Task<CGImage?, Never>
        var waiters = 0

        init(task: Task<CGImage?, Never>) {
            self.task = task
        }
    }

    /// The preview for `identity`, from the cache, an in-flight decode, or a new decode.
    func image(
        for identity: SourcePreviewIdentity,
        settings: CameraRawSettings?
    ) async -> CGImage? {
        if let cached = cachedImage(for: identity) { return cached }
        let decode = inFlight[identity] ?? startDecode(identity, settings: settings, priority: .userInitiated)
        decode.waiters += 1
        let image = await withTaskCancellationHandler {
            await decode.task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.releaseWaiter(of: identity, decode: decode) }
        }
        if !Task.isCancelled {
            decode.waiters -= 1
        }
        return image
    }

    /// Decodes the photo the user is likely to open next. A newer prefetch replaces this one.
    func prefetch(_ identity: SourcePreviewIdentity, settings: CameraRawSettings?) {
        let previous = prefetchIdentity
        prefetchIdentity = identity
        if let previous, previous != identity { cancelIfUnwanted(previous) }
        guard cachedImage(for: identity) == nil, inFlight[identity] == nil else { return }
        _ = startDecode(identity, settings: settings, priority: .utility)
    }

    private func cachedImage(for identity: SourcePreviewIdentity) -> CGImage? {
        guard let index = entries.firstIndex(where: { $0.identity == identity }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.image
    }

    private func insert(_ image: CGImage, for identity: SourcePreviewIdentity) {
        entries.removeAll { $0.identity == identity }
        entries.append((identity, image))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    private func startDecode(
        _ identity: SourcePreviewIdentity,
        settings: CameraRawSettings?,
        priority: TaskPriority
    ) -> Decode {
        let screenMaxPixelSize = screenMaxPixelSize
        let task = Task(priority: priority) {
            await FullScreenImageCache.decodedEditedPreview(
                for: identity.url,
                settings: settings,
                orientation: identity.sourceOrientation,
                screenMaxPx: screenMaxPixelSize
            )
        }
        let decode = Decode(task: task)
        inFlight[identity] = decode
        Task { [weak self] in
            let image = await task.value
            guard let self else { return }
            if self.inFlight[identity] === decode { self.inFlight[identity] = nil }
            if self.prefetchIdentity == identity { self.prefetchIdentity = nil }
            if let image, !task.isCancelled { self.insert(image, for: identity) }
        }
        return decode
    }

    private func releaseWaiter(of identity: SourcePreviewIdentity, decode: Decode) {
        decode.waiters -= 1
        if inFlight[identity] === decode { cancelIfUnwanted(identity) }
    }

    private func cancelIfUnwanted(_ identity: SourcePreviewIdentity) {
        guard identity != prefetchIdentity,
              let decode = inFlight[identity],
              decode.waiters <= 0 else { return }
        decode.task.cancel()
        inFlight[identity] = nil
    }
}

/// The pointer position inside the source viewport, for the scroll and key monitors.
private final class AnalysisPointerLocation {
    var location: CGPoint?
}

/// Reads the per-move sample so only this layer re-renders while the pointer moves.
private struct PixelInspectionCrosshairLayer: View {
    let inspection: AnalysisPixelInspectionState
    let geometries: [ImageInspectionGeometry]

    var body: some View {
        if let sample = inspection.sample {
            ForEach(Array(geometries.enumerated()), id: \.offset) { _, inspectionGeometry in
                PixelInspectionCrosshair(
                    position: inspectionGeometry.viewPoint(
                        fromNormalizedDisplay: sample.normalizedDisplayPoint
                    ),
                    imageRect: inspectionGeometry.imageRectInView
                )
            }
        }
    }
}

/// Reads the per-move sample so only the loupe re-renders while the pointer moves.
private struct AnalysisTruePixelLoupeLayer: View {
    let inspection: AnalysisPixelInspectionState
    let sourceImage: CGImage?
    let isUnavailable: Bool
    let viewLabel: String
    let isBoundedPreview: Bool
    let representation: AnalysisSourceRepresentation
    let displaySize: CGFloat

    var body: some View {
        if let sample = inspection.sample {
            AnalysisTruePixelLoupe(
                sourceImage: sourceImage,
                isUnavailable: isUnavailable,
                viewLabel: viewLabel,
                isBoundedPreview: isBoundedPreview,
                normalizedDisplayPoint: sample.normalizedDisplayPoint,
                sourcePixel: sample.sourcePixel,
                representation: representation,
                displaySize: displaySize
            )
        }
    }
}

private struct AnalysisTruePixelLoupe: View {
    let sourceImage: CGImage?
    let isUnavailable: Bool
    let viewLabel: String
    let isBoundedPreview: Bool
    let normalizedDisplayPoint: CGPoint
    let sourcePixel: SourcePixelCoordinate
    let representation: AnalysisSourceRepresentation
    let displaySize: CGFloat

    @Environment(\.displayScale) private var displayScale

    private var pixelSize: Int {
        max(1, Int((displaySize * displayScale).rounded()))
    }

    private var crop: ImageInspectionLoupeCrop? {
        sourceImage.flatMap {
            ImageInspectionLoupeCrop.make(
                from: $0,
                normalizedDisplayPoint: normalizedDisplayPoint,
                pixelSize: pixelSize
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label(isBoundedPreview ? "Pixel view detail" : "True-pixel detail", systemImage: "magnifyingglass")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text("x \(sourcePixel.x), y \(sourcePixel.y)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 8) {
                loupePane(title: isBoundedPreview ? "100% preview" : "100%", magnification: 1)
                loupePane(title: isBoundedPreview ? "400% preview" : "400%", magnification: 4)
            }

            Text(viewLabel)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // Bound the header Spacer to the two pixel panes instead of the entire viewport.
        .frame(width: displaySize * 2 + 8)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.primary.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(viewLabel) detail for source pixel x \(sourcePixel.x), y \(sourcePixel.y)"
        )
        .accessibilityValue(caption)
    }

    private func loupePane(title: String, magnification: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ZStack {
                Color.black.opacity(0.94)
                if let crop {
                    Image(decorative: crop.image, scale: displayScale, orientation: .up)
                        .interpolation(.none)
                        .scaleEffect(magnification)
                        .offset(magnifiedImageOffset(for: crop, magnification: magnification))

                    PixelInspectionLoupeReticle()
                        .position(reticlePosition(for: crop, magnification: magnification))
                } else if isUnavailable {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(width: displaySize, height: displaySize)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func magnifiedImageOffset(
        for crop: ImageInspectionLoupeCrop,
        magnification: CGFloat
    ) -> CGSize {
        guard magnification > 1 else { return .zero }
        let nativeCenter = CGPoint(
            x: CGFloat(crop.image.width) / displayScale / 2,
            y: CGFloat(crop.image.height) / displayScale / 2
        )
        let focus = CGPoint(
            x: crop.focusPointInCrop.x / displayScale,
            y: crop.focusPointInCrop.y / displayScale
        )
        return CGSize(
            width: (nativeCenter.x - focus.x) * magnification,
            height: (nativeCenter.y - focus.y) * magnification
        )
    }

    private func reticlePosition(
        for crop: ImageInspectionLoupeCrop,
        magnification: CGFloat
    ) -> CGPoint {
        let center = CGPoint(x: displaySize / 2, y: displaySize / 2)
        guard magnification == 1 else { return center }
        let nativeCenter = CGPoint(
            x: CGFloat(crop.image.width) / displayScale / 2,
            y: CGFloat(crop.image.height) / displayScale / 2
        )
        return CGPoint(
            x: center.x + crop.focusPointInCrop.x / displayScale - nativeCenter.x,
            y: center.y + crop.focusPointInCrop.y / displayScale - nativeCenter.y
        )
    }

    private var caption: String {
        guard let crop else {
            if isUnavailable {
                return "Selected pixel view could not be loaded"
            }
            return "Loading \(viewLabel.lowercased()) pixels…"
        }
        return "\(Int(crop.pixelRect.width)) × \(Int(crop.pixelRect.height)) px · nearest-neighbor magnification"
    }
}

private struct PixelInspectionLoupeReticle: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.75))
                .frame(width: 0.75, height: 7)
            Rectangle()
                .fill(.white.opacity(0.75))
                .frame(width: 7, height: 0.75)
        }
        .frame(width: 9, height: 9)
        .shadow(color: .black.opacity(0.25), radius: 0.5)
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

/// The pointer's pixel sample. Only the readout, crosshair and loupe layers read `sample`; the
/// source view reads just `hasSample`, which changes when the pointer enters or leaves the image.
@Observable
final class AnalysisPixelInspectionState {
    private(set) var sample: ImageInspectionSample?
    private(set) var hasSample = false

    func update(_ newSample: ImageInspectionSample?) {
        if sample != newSample { sample = newSample }
        let present = newSample != nil
        if hasSample != present { hasSample = present }
    }
}

private struct PixelInspectionReadout: View {
    let inspection: AnalysisPixelInspectionState

    private var sample: ImageInspectionSample? { inspection.sample }

    var body: some View {
        Color.clear
            .frame(height: 18)
            .overlay(alignment: .leading) {
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
                            if sample.rgbaSource == .preview {
                                Text("Preview pixel")
                                    .foregroundStyle(.secondary)
                                    .help("Values come from the downsampled preview; turn on the Loupe or zoom in to read full-resolution values")
                            }
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
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let sample else {
            return "Pixel inspector. Hover over the image to inspect a source pixel."
        }
        if let rgba = sample.rgba16 {
            let origin = sample.rgbaSource == .preview ? "Preview pixel " : ""
            return "Source pixel x \(sample.sourcePixel.x), y \(sample.sourcePixel.y). "
                + "\(origin)16-bit red \(rgba.red), green \(rgba.green), "
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
        // Crop first (CGImage cropping uses a top-left origin and shares pixel storage) so a
        // full-resolution source costs one pixel per hover rather than a full-image draw.
        if let pixel = image.cropping(to: CGRect(x: x, y: displayY, width: 1, height: 1)) {
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        } else {
            context.translateBy(x: -CGFloat(x), y: -CGFloat(image.height - 1 - displayY))
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
        }

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

/// Window-scoped Escape handling for the Analysis workspace. Escape is left alone while a text
/// field is editing, a sheet, alert, or modal panel is up, or the workspace is hidden.
private struct AnalysisExportConfirmation {
    let title: String
    let url: URL
}

private struct AnalysisEscapeKeyMonitor: NSViewRepresentable {
    let onEscape: () -> Bool

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onEscape = onEscape
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.removeMonitor()
    }

    final class MonitorView: NSView {
        var onEscape: (() -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      event.keyCode == 53, !event.isARepeat,
                      let window = self.window,
                      event.window === window, window.isKeyWindow,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      !self.isHiddenOrHasHiddenAncestor,
                      !(window.firstResponder is NSText),
                      !(window.firstResponder is NSTextField),
                      event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
                      self.onEscape?() == true else {
                    return event
                }
                return nil
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
