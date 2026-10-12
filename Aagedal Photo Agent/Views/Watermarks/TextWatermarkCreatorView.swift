import AppKit
import SwiftUI

/// Creates PNG assets so text watermarks use the same placement and export path as imports.
struct TextWatermarkCreatorView: View {
    let store: WatermarkStore
    let onCreated: (WatermarkAsset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = "Text watermark"
    @State private var text = ""
    @State private var fontFamily: TextWatermarkFontFamily = .system
    @State private var fontSize: Double = 96
    @State private var bold = false
    @State private var italic = false
    @State private var color: Color = .white
    @State private var previewImage: NSImage?
    @State private var previewError: String?
    @State private var isRenderingPreview = false
    @State private var previewGeneration = UUID()
    @State private var saveTask: Task<Void, Never>?
    @State private var saveRequestID: UUID?
    @State private var saveError: String?
    @State private var cancellationRequested = false

    private var configuration: TextWatermarkConfiguration {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return TextWatermarkConfiguration(
            text: text,
            fontFamily: fontFamily,
            fontSize: fontSize,
            bold: bold,
            italic: italic,
            color: TextWatermarkColor(
                red: Double(resolved.redComponent),
                green: Double(resolved.greenComponent),
                blue: Double(resolved.blueComponent),
                alpha: Double(resolved.alphaComponent)
            )
        )
    }

    private var isSaving: Bool { saveRequestID != nil }
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create a reusable text watermark")
                .font(.title2.bold())
            Text("Choose your text and style. The watermark is saved as a transparent PNG in your library.")
                .foregroundStyle(.secondary)

            Form {
                TextField("Overlay name", text: $name)
                    .accessibilityIdentifier("textWatermark.name")
                LabeledContent("Text") {
                    TextEditor(text: $text)
                        .font(.body)
                        .frame(height: 72)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
                        .accessibilityLabel("Watermark text")
                        .accessibilityIdentifier("textWatermark.text")
                }
                Picker("Font family", selection: $fontFamily) {
                    ForEach(TextWatermarkFontFamily.allCases) { family in
                        Text(family.displayName).tag(family)
                    }
                }
                .accessibilityIdentifier("textWatermark.fontFamily")
                TextField("Font size (pixels)", value: $fontSize, format: .number)
                    .accessibilityIdentifier("textWatermark.fontSize")
                HStack {
                    Toggle("Bold", isOn: $bold)
                        .accessibilityIdentifier("textWatermark.bold")
                    Toggle("Italic", isOn: $italic)
                        .accessibilityIdentifier("textWatermark.italic")
                    Spacer()
                    ColorPicker("Text color", selection: $color, supportsOpacity: true)
                        .accessibilityIdentifier("textWatermark.color")
                }
            }
            .disabled(isSaving)

            ZStack {
                CheckerboardBackground(lightColor: Color(white: 0.28), darkColor: Color(white: 0.2))
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                        .accessibilityLabel("Text watermark preview")
                        .accessibilityIdentifier("textWatermark.preview")
                } else if !hasText {
                    Text("Enter text to preview your watermark")
                        .foregroundStyle(.white.opacity(0.8))
                }
                if isRenderingPreview { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let error = saveError ?? previewError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .accessibilityIdentifier("textWatermark.error")
            }
            HStack {
                if isSaving {
                    ProgressView().controlSize(.small)
                    Text(cancellationRequested ? "Finishing cancellation…" : "Saving watermark…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .disabled(cancellationRequested)
                    .accessibilityIdentifier("textWatermark.cancel")
                Button("Create", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || !hasText || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("textWatermark.create")
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(isSaving)
        .task(id: configuration) { await renderPreview(configuration) }
    }

    private func renderPreview(_ configuration: TextWatermarkConfiguration) async {
        let generation = UUID()
        previewGeneration = generation
        previewImage = nil
        previewError = nil
        isRenderingPreview = hasText
        guard hasText else { return }
        do {
            try await Task.sleep(for: .milliseconds(200))
            let data = try await TextWatermarkRenderer.shared.renderPNG(configuration: configuration)
            guard !Task.isCancelled, previewGeneration == generation else { return }
            previewImage = NSImage(data: data)
            isRenderingPreview = false
        } catch {
            guard !Task.isCancelled, previewGeneration == generation else { return }
            previewError = error.localizedDescription
            isRenderingPreview = false
        }
    }

    private func save() {
        guard !isSaving else { return }
        let requestID = UUID()
        let configuration = configuration
        let assetName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveRequestID = requestID
        saveError = nil
        cancellationRequested = false
        saveTask = Task {
            do {
                let result = try await store.createTextOverlay(
                    configuration: configuration,
                    name: assetName,
                    requestID: requestID
                )
                guard saveRequestID == requestID else { return }
                saveTask = nil
                saveRequestID = nil
                // A completed coordinated write survives cancellation and must remain selected.
                if case .committed(let commit) = result {
                    onCreated(commit.asset)
                    dismiss()
                } else if cancellationRequested {
                    dismiss()
                } else {
                    saveError = "The watermark could not be saved. Please try again."
                }
            } catch {
                guard saveRequestID == requestID else { return }
                saveTask = nil
                saveRequestID = nil
                if cancellationRequested, error is CancellationError {
                    dismiss()
                } else {
                    cancellationRequested = false
                    saveError = error.localizedDescription
                }
            }
        }
    }

    private func cancel() {
        guard isSaving else { dismiss(); return }
        cancellationRequested = true
        saveTask?.cancel()
    }
}
