import AppKit
import SwiftUI

struct AnalysisWorkspaceView: View {
    @Bindable var model: AnalysisWorkspaceModel
    let thumbnailService: ThumbnailService
    let onClose: () -> Void
    @State private var selectedFindingID: String?
    @State private var pixelInspectionSample: ImageInspectionSample?

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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image Analysis workspace")
        .onChange(of: model.sourceURL) {
            pixelInspectionSample = nil
        }
        .onChange(of: model.displayPreference) {
            pixelInspectionSample = nil
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
            sourcePreview
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            analysisDetail
                .frame(minWidth: 260, idealWidth: 330, maxWidth: 430)
        }
    }

    private var osintBody: some View {
        VStack(spacing: 0) {
            HSplitView {
                sourcePreview
                ContentUnavailableView(
                    "Map Evidence",
                    systemImage: "map",
                    description: Text("Satellite and hybrid map evidence arrives in the OSINT map slice.")
                )
            }
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

            AnalysisSourceThumbnail(
                url: model.sourceURL,
                representation: model.displayPreference,
                developSettings: model.developSettings,
                sourceOrientation: model.sourceOrientation,
                displayTransform: model.displayTransform,
                inspectionSample: $pixelInspectionSample,
                thumbnailService: thumbnailService
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PixelInspectionReadout(sample: pixelInspectionSample)
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var analysisDetail: some View {
        if let selectedFindingID,
           let finding = model.findings.first(where: { $0.id == selectedFindingID }) {
            FindingDetailView(finding: finding) { included in
                model.setFindingIncluded(finding.id, included: included)
            }
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
    let onReportInclusionChanged: (Bool) -> Void

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

private struct AnalysisSourceThumbnail: View {
    let url: URL?
    let representation: AnalysisSourceRepresentation
    let developSettings: CameraRawSettings?
    let sourceOrientation: Int
    let displayTransform: DisplayImageTransform?
    @Binding var inspectionSample: ImageInspectionSample?
    let thumbnailService: ThumbnailService
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.92)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(url?.lastPathComponent ?? "Analyzed image")

                    if let inspectionSample,
                       let inspectionGeometry = inspectionGeometry(
                           image: image,
                           containerSize: geometry.size
                       ) {
                        PixelInspectionCrosshair(
                            position: inspectionGeometry.viewPoint(
                                fromNormalizedDisplay: inspectionSample.normalizedDisplayPoint
                            ),
                            imageRect: inspectionGeometry.imageRectInView
                        )
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    guard let image,
                          let displayTransform,
                          let inspectionGeometry = inspectionGeometry(
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
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: PreviewIdentity(url: url, representation: representation)) {
            image = nil
            guard let url else { return }
            if representation == .developed, let developSettings {
                image = await thumbnailService.renderEditedThumbnail(
                    for: url,
                    settings: developSettings,
                    exifOrientation: sourceOrientation
                )
            } else {
                image = await thumbnailService.loadThumbnail(for: url)
            }
        }
    }

    private func inspectionGeometry(
        image: NSImage,
        containerSize: CGSize
    ) -> ImageInspectionGeometry? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return try? ImageInspectionGeometry(
            imagePixelSize: image.size,
            containerRect: CGRect(origin: .zero, size: containerSize)
        )
    }
}

private struct PreviewIdentity: Hashable {
    let url: URL?
    let representation: AnalysisSourceRepresentation
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
