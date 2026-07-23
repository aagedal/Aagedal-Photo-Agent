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
            Slider(value: value, in: 0.5...1, step: 0.01)
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

                Text(exportSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                imagePane(
                    title: "Developed reference",
                    image: preview?.referenceImage
                )
                imagePane(
                    title: exportPaneTitle,
                    image: preview?.exportImage
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

    private var exportSummary: String {
        guard let preview else {
            return isLoading ? "Generating preview…" : exportPaneTitle
        }
        let size = ByteCountFormatter.string(
            fromByteCount: preview.encodedFileSize,
            countStyle: .file
        )
        return "\(preview.pixelWidth) × \(preview.pixelHeight) · \(size)"
    }

    private func imagePane(title: String, image: CGImage?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ZStack {
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
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity)
    }
}
