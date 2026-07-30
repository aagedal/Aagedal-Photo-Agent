import AppKit
import SwiftUI

struct AnalysisWorkspaceView: View {
    @Bindable var model: AnalysisWorkspaceModel
    let thumbnailService: ThumbnailService
    let onClose: () -> Void

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
            detailPlaceholder
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
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
                    Label("Source", systemImage: "checkmark.shield")
                    Label("Provenance", systemImage: "seal")
                    Label("Metadata", systemImage: "list.bullet.rectangle")
                    Label("Encoding", systemImage: "shippingbox")
                    Label("Pixels", systemImage: "square.grid.3x3")
                    Label("Limitations", systemImage: "info.circle")
                }

                Divider()

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
                thumbnailService: thumbnailService
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var detailPlaceholder: some View {
        ContentUnavailableView(
            "No Finding Selected",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Source facts and evidence findings arrive in the next analyzer slice.")
        )
        .padding()
    }
}

private struct AnalysisSourceThumbnail: View {
    let url: URL?
    let representation: AnalysisSourceRepresentation
    let developSettings: CameraRawSettings?
    let sourceOrientation: Int
    let thumbnailService: ThumbnailService
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(url?.lastPathComponent ?? "Analyzed image")
            } else {
                ProgressView()
                    .tint(.white)
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
}

private struct PreviewIdentity: Hashable {
    let url: URL?
    let representation: AnalysisSourceRepresentation
}
