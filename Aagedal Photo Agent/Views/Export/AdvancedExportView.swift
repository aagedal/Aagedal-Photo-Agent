import AppKit
import SwiftUI

struct AdvancedExportView: View {
    let session: AdvancedExportSession
    let onExport: (AdvancedExportConfiguration) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var configuration: AdvancedExportConfiguration
    @State private var previewService = AdvancedExportPreviewService()

    init(
        session: AdvancedExportSession,
        initialConfiguration: AdvancedExportConfiguration,
        onExport: @escaping (AdvancedExportConfiguration) -> Void
    ) {
        self.session = session
        self.onExport = onExport
        _configuration = State(initialValue: initialConfiguration)
    }

    private var hasSDRItems: Bool {
        session.items.contains { !$0.isHDR }
    }

    private var hasHDRItems: Bool {
        session.items.contains { $0.isHDR }
    }

    var body: some View {
        HStack(spacing: 0) {
            comparisonList
            Divider()
            settingsInspector
        }
        .frame(minWidth: 1_180, idealWidth: 1_320, minHeight: 720, idealHeight: 820)
    }

    private var comparisonList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced Export")
                        .font(.title2.weight(.semibold))
                    Text("\(session.items.count) \(session.items.count == 1 ? "image" : "images") queued")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Reference")
                    .frame(maxWidth: .infinity)
                Text("Export Preview")
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView(.vertical) {
                LazyVStack(spacing: 18) {
                    ForEach(session.items) { item in
                        AdvancedExportComparisonRow(
                            item: item,
                            configuration: configuration,
                            previewService: previewService
                        )
                    }
                }
                .padding(20)
            }
        }
    }

    private var settingsInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Settings")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if hasSDRItems {
                        sdrSettings
                    }
                    if hasHDRItems {
                        hdrSettings
                    }
                    resolutionSettings
                    if configuration.sdrFormat == .tiff
                        || configuration.hdrFormat == .tiff16bit {
                        tiffSettings
                    }
                    destinationSettings
                }
            }

            Divider()

            Text("Previews are encoded at full output resolution. Only the display copy is reduced.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Export \(session.items.count)") {
                    onExport(configuration)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 300)
    }

    private var sdrSettings: some View {
        GroupBox("SDR") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Format") {
                    Picker("Format", selection: $configuration.sdrFormat) {
                        ForEach(ExportFormatSDR.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 145)
                }

                if configuration.sdrFormat.supportsQuality {
                    qualityControl(
                        title: "Quality",
                        value: $configuration.sdrQuality
                    )
                }

                LabeledContent("Gamut") {
                    Picker("Gamut", selection: $configuration.sdrGamut) {
                        ForEach(TargetColorGamut.allCases) { gamut in
                            Text(gamut.displayName).tag(gamut)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 145)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var hdrSettings: some View {
        GroupBox("HDR") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Format") {
                    Picker("Format", selection: $configuration.hdrFormat) {
                        ForEach(ExportFormatHDR.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 145)
                }

                if configuration.hdrFormat.supportsQuality {
                    qualityControl(
                        title: "Quality",
                        value: $configuration.hdrQuality
                    )
                }

                LabeledContent("Gamut") {
                    Picker("Gamut", selection: $configuration.hdrGamut) {
                        ForEach(TargetColorGamut.allCases) { gamut in
                            Text(gamut.displayName).tag(gamut)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 145)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var tiffSettings: some View {
        GroupBox("TIFF") {
            LabeledContent("Compression") {
                Picker("Compression", selection: $configuration.tiffCompression) {
                    ForEach(TIFFCompression.allCases) { compression in
                        Text(compression.displayName).tag(compression)
                    }
                }
                .labelsHidden()
                .frame(width: 145)
            }
            .padding(.vertical, 4)
        }
    }

    private var resolutionSettings: some View {
        GroupBox("Resolution") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Long edge") {
                    Picker("Long edge", selection: $configuration.resolutionLimit) {
                        ForEach(ExportResolutionLimit.allCases) { limit in
                            Text(limit.displayName).tag(limit)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 145)
                }

                Text("Smaller images are never enlarged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var destinationSettings: some View {
        GroupBox("Destination") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Save exported files", selection: $configuration.locationMode) {
                    ForEach(ExportLocationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                if configuration.locationMode == .customSubfolder {
                    TextField(
                        "Sub-folder name",
                        text: $configuration.customSubfolderName
                    )
                }

                Text(configuration.locationMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    private func qualityControl(
        title: String,
        value: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: value,
                in: AdvancedExportConfiguration.minimumQuality...1,
                step: 0.01
            )
        }
    }
}

private struct AdvancedExportComparisonRow: View {
    let item: AdvancedExportItem
    let configuration: AdvancedExportConfiguration
    let previewService: AdvancedExportPreviewService

    @State private var preview: AdvancedExportPreview?
    @State private var errorMessage: String?
    @State private var isLoading = true

    private var taskID: String {
        configuration.previewSignature(isHDR: item.isHDR)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(item.filename)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(item.isHDR ? "HDR" : "SDR")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(item.isHDR ? Color.orange.opacity(0.18) : Color.blue.opacity(0.16))
                    .clipShape(Capsule())

                Spacer()
            }

            Text(comparisonSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            HStack(spacing: 12) {
                AdvancedExportImagePane(
                    title: "Developed reference",
                    image: preview?.referenceImage,
                    isLoading: isLoading,
                    item: item,
                    configuration: configuration,
                    preview: preview,
                    previewService: previewService
                )
                AdvancedExportImagePane(
                    title: exportPaneTitle,
                    image: preview?.exportImage,
                    isLoading: isLoading,
                    item: item,
                    configuration: configuration,
                    preview: preview,
                    previewService: previewService
                )
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .task(id: taskID) {
            preview = nil
            errorMessage = nil
            isLoading = true

            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                preview = try await previewService.makePreview(
                    item: item,
                    configuration: configuration
                )
                isLoading = false
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private var exportPaneTitle: String {
        var components = [configuration.formatName(isHDR: item.isHDR)]
        if let quality = configuration.quality(isHDR: item.isHDR) {
            components.append("\(Int(quality * 100))%")
        }
        return components.joined(separator: " · ")
    }

    private var comparisonSummary: String {
        let source = summary(
            label: "Source",
            pixelWidth: item.sourcePixelWidth,
            pixelHeight: item.sourcePixelHeight,
            fileSize: item.sourceFileSize
        )
        guard let preview else {
            let output = isLoading ? "Output generating…" : "Output \(exportPaneTitle)"
            return "\(source)  →  \(output)"
        }
        let output = summary(
            label: "Output",
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight,
            fileSize: preview.encodedFileSize
        )
        return "\(source)  →  \(output)"
    }

    private func summary(
        label: String,
        pixelWidth: Int?,
        pixelHeight: Int?,
        fileSize: Int64?
    ) -> String {
        var components: [String] = []
        if let pixelWidth, let pixelHeight {
            components.append("\(pixelWidth) × \(pixelHeight)")
        }
        if let fileSize {
            components.append(ByteCountFormatter.string(
                fromByteCount: fileSize,
                countStyle: .file
            ))
        }
        return components.isEmpty
            ? "\(label) unavailable"
            : "\(label) \(components.joined(separator: " · "))"
    }
}

private struct AdvancedExportImagePane: View {
    let title: String
    let image: CGImage?
    let isLoading: Bool
    let item: AdvancedExportItem
    let configuration: AdvancedExportConfiguration
    let preview: AdvancedExportPreview?
    let previewService: AdvancedExportPreviewService

    @State private var isHovered = false
    @State private var hoverPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var hoverLocation = CGPoint.zero
    @State private var loupePoint = CGPoint(x: 0.5, y: 0.5)
    @State private var isShowingLoupe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.92)

                    if let image {
                        Image(
                            nsImage: NSImage(
                                cgImage: image,
                                size: NSSize(width: image.width, height: image.height)
                            )
                        )
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(8)
                    } else if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if image != nil, preview != nil, isHovered {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.black.opacity(0.72), in: Circle())
                            .position(loupeIndicatorPosition(in: geometry.size))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isHovered else { return }
                    loupePoint = hoverPoint
                    isShowingLoupe = true
                }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        if let image,
                           let point = normalizedImagePoint(
                               location: location,
                               containerSize: geometry.size,
                               imageSize: CGSize(width: image.width, height: image.height)
                           ) {
                            isHovered = true
                            hoverPoint = point
                            hoverLocation = location
                        } else {
                            isHovered = false
                        }
                    case .ended:
                        isHovered = false
                    }
                }
                .accessibilityLabel("Inspect \(title) at 100%")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    loupePoint = hoverPoint
                    isShowingLoupe = true
                }
                .help(isHovered ? "Click to inspect this area at 100%" : "")
                .popover(isPresented: $isShowingLoupe, arrowEdge: .trailing) {
                    if let preview {
                        AdvancedExportLoupeView(
                            item: item,
                            configuration: configuration,
                            preview: preview,
                            previewService: previewService,
                            normalizedPoint: loupePoint
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity)
    }

    private func normalizedImagePoint(
        location: CGPoint,
        containerSize: CGSize,
        imageSize: CGSize
    ) -> CGPoint? {
        let availableWidth = max(0, containerSize.width - 16)
        let availableHeight = max(0, containerSize.height - 16)
        guard availableWidth > 0, availableHeight > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let scale = min(
            availableWidth / imageSize.width,
            availableHeight / imageSize.height
        )
        let displayedSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        let origin = CGPoint(
            x: (containerSize.width - displayedSize.width) / 2,
            y: (containerSize.height - displayedSize.height) / 2
        )
        let imageRect = CGRect(origin: origin, size: displayedSize)
        guard imageRect.contains(location) else { return nil }
        return CGPoint(
            x: (location.x - origin.x) / displayedSize.width,
            y: (location.y - origin.y) / displayedSize.height
        )
    }

    private func loupeIndicatorPosition(in containerSize: CGSize) -> CGPoint {
        CGPoint(
            x: min(containerSize.width - 18, max(18, hoverLocation.x + 22)),
            y: min(containerSize.height - 18, max(18, hoverLocation.y - 22))
        )
    }
}

private struct AdvancedExportLoupeView: View {
    let item: AdvancedExportItem
    let configuration: AdvancedExportConfiguration
    let preview: AdvancedExportPreview
    let previewService: AdvancedExportPreviewService
    let normalizedPoint: CGPoint

    @State private var loupe: AdvancedExportLoupe?
    @State private var errorMessage: String?

    private let displaySize: CGFloat = 280

    private var backingScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    private var pixelSize: Int {
        Int((displaySize * backingScale).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("100% Comparison")
                    .font(.headline)
                Spacer()
                Text("Same image area")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 10) {
                loupePane(
                    title: "Developed reference",
                    image: loupe?.referenceImage
                )
                loupePane(
                    title: encodedExportTitle,
                    image: loupe?.exportImage
                )
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(loupeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .task {
            do {
                loupe = try await previewService.makeLoupe(
                    item: item,
                    configuration: configuration,
                    preview: preview,
                    normalizedPoint: normalizedPoint,
                    pixelSize: pixelSize
                )
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loupePane(title: String, image: CGImage?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ZStack {
                Color.black.opacity(0.94)

                if let image {
                    Image(decorative: image, scale: backingScale, orientation: .up)
                        .interpolation(.none)
                } else if errorMessage == nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(width: displaySize, height: displaySize)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var loupeDescription: String {
        guard let loupe else {
            return "Rendering matching true-pixel crops…"
        }
        return "\(loupe.referenceImage.width) × \(loupe.referenceImage.height) pixel crops · no display interpolation"
    }

    private var encodedExportTitle: String {
        var components = ["Encoded export", configuration.formatName(isHDR: item.isHDR)]
        if let quality = configuration.quality(isHDR: item.isHDR) {
            components.append("\(Int(quality * 100))%")
        }
        return components.joined(separator: " · ")
    }
}
