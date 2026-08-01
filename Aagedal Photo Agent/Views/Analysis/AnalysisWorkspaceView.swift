import AppKit
import SwiftUI

struct AnalysisWorkspaceView: View {
    @Bindable var model: AnalysisWorkspaceModel
    let thumbnailService: ThumbnailService
    let onClose: () -> Void
    @State private var selectedFindingID: String?
    @State private var pixelInspectionSample: ImageInspectionSample?
    @State private var displayedScopeImage: CGImage?
    @State private var scopeSourceMode: AnalysisScopeSourceMode = .fullImage
    @State private var selectedScopeRegion: CGRect?
    @State private var pixelViewMode: AnalysisPixelViewMode = .normal
    @State private var annotationTool: AnalysisAnnotationTool = .select
    @State private var annotationStyle = AnalysisAnnotationStyle.default
    @State private var selectedAnnotationID: UUID?
    @State private var calibrationEditorRequest: AnalysisCalibrationEditorRequest?

    var body: some View {
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
        .onChange(of: model.sourceURL) {
            pixelInspectionSample = nil
            displayedScopeImage = nil
            selectedScopeRegion = nil
            scopeSourceMode = .fullImage
            pixelViewMode = .normal
            selectedAnnotationID = nil
        }
        .onChange(of: model.analysisCase?.id) {
            selectedAnnotationID = nil
        }
        .onChange(of: model.displayPreference) {
            pixelInspectionSample = nil
            displayedScopeImage = nil
            selectedScopeRegion = nil
            selectedAnnotationID = nil
        }
        .onChange(of: selectedAnnotationID) {
            guard let selectedAnnotationID,
                  let annotation = model.annotations.first(where: {
                      $0.id == selectedAnnotationID
                  }) else { return }
            annotationStyle = annotation.style
        }
        .onChange(of: annotationStyle) {
            guard let selectedAnnotationID,
                  var annotation = model.annotations.first(where: {
                      $0.id == selectedAnnotationID
                  }),
                  annotation.style != annotationStyle else { return }
            annotation.style = annotationStyle
            model.setAnnotation(annotation)
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

            Spacer()

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

    private var pixelAnalysisBody: some View {
        HSplitView {
            caseSidebar
                .frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
            VSplitView {
                sourcePreview
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

    private var osintBody: some View {
        VStack(spacing: 0) {
            HSplitView {
                sourcePreview
                    .frame(minWidth: 420, minHeight: 320)
                ContentUnavailableView(
                    "Map Evidence",
                    systemImage: "map",
                    description: Text("Satellite and hybrid map evidence arrives in the OSINT map slice.")
                )
                .frame(minWidth: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Label(
                "Time and location evidence will remain case-only and will not modify IPTC metadata.",
                systemImage: "clock.badge.questionmark"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        onDelete: {
                            guard let selectedAnnotationID else { return }
                            model.removeAnnotation(id: selectedAnnotationID)
                            self.selectedAnnotationID = nil
                        }
                    )
                }

                Text("SHA-256")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(analysisCase.source.sha256)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .accessibilityLabel("Source SHA-256 \(analysisCase.source.sha256)")
            }
            Spacer()
        }
        .padding(14)
    }

    private var sourcePreview: some View {
        VStack(spacing: 10) {
            HStack {
                Text(model.displayPreference.displayName)
                    .font(.caption.weight(.semibold))
                Spacer()
                if let name = model.sourceURL?.lastPathComponent {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(name)
                }
            }

            Picker("Pixel View", selection: $pixelViewMode) {
                ForEach(AnalysisPixelViewMode.allCases, id: \.self) { mode in
                    Text(mode.compactLabel)
                        .tag(mode)
                        .accessibilityLabel(mode.displayName)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 540)
            .help("Show the normal image, a linear-light channel, relative luminance, or a fixed-parameter JPEG compression residual")

            Text(pixelViewMode.methodLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel("Pixel view method: \(pixelViewMode.methodLabel)")

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
                annotationTool: annotationTool,
                annotationStyle: annotationStyle,
                selectedAnnotationID: $selectedAnnotationID,
                annotationsAreReadOnly: model.sourceChanged,
                thumbnailService: thumbnailService,
                onImageLoaded: { displayedScopeImage = $0 },
                onSetAnnotation: model.setAnnotation,
                onRemoveAnnotation: model.removeAnnotation
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            AnalysisAnnotationToolbar(
                tool: $annotationTool,
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
                }
            )

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

    @ViewBuilder
    private var analysisDetail: some View {
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
                    annotationTool = .select
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

private struct AnalysisAnnotationList: View {
    let annotations: [AnalysisAnnotation]
    @Binding var selectedAnnotationID: UUID?
    let isReadOnly: Bool
    let onSetVisible: (UUID, Bool) -> Void
    let onSetAllVisible: (Bool) -> Void
    let onDelete: () -> Void

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
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 90, idealHeight: 150, maxHeight: 210)
            .onDeleteCommand {
                guard !isReadOnly, selectedAnnotationID != nil else { return }
                onDelete()
            }
            .accessibilityLabel("Photo annotation layers")
        }
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
        if kind == .label,
           let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
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
    let onImageLoaded: (CGImage?) -> Void
    let onSetAnnotation: (AnalysisAnnotation) -> Void
    let onRemoveAnnotation: (UUID) -> Void
    @State private var loadedSourceIdentity: SourcePreviewIdentity?
    @State private var sourceCGImage: CGImage?
    @State private var sourceImage: NSImage?
    @State private var image: NSImage?
    @State private var selectionDragStart: CGPoint?
    @State private var selectionDraft: CGRect?
    @State private var annotationDraft: AnalysisAnnotationGestureDraft?
    @State private var annotationEditSession: AnalysisAnnotationEditSession?
    @State private var pendingLabelAnchor: AnalysisNormalizedPoint?
    @State private var labelText = ""
    @State private var isLabelPromptPresented = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.92)
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
                        transform: displayTransform
                    )
                case .ended:
                    inspectionSample = nil
                }
            }
            .accessibilityAction(named: "Inspect center pixel") {
                guard let displayTransform else { return }
                inspectionSample = ImageInspectionSample(
                    normalizedDisplayPoint: CGPoint(x: 0.5, y: 0.5),
                    transform: displayTransform
                )
            }
            .accessibilityAction(named: "Select center region for scopes") {
                selectedScopeRegion = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            }
            .focusable()
            .onDeleteCommand {
                guard !annotationsAreReadOnly, let selectedAnnotationID else { return }
                onRemoveAnnotation(selectedAnnotationID)
                self.selectedAnnotationID = nil
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
                Text(
                    "Source pixel x: \(sample.sourcePixel.x), y: \(sample.sourcePixel.y)"
                )
                .monospacedDigit()
                .textSelection(.enabled)
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
        return "Source pixel x \(sample.sourcePixel.x), y \(sample.sourcePixel.y)"
    }
}
