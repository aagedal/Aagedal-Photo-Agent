import AppKit
import SwiftUI

private enum AnalysisScopeLayout: Int, CaseIterable {
    case one = 1
    case two = 2
    case four = 4

    var label: String { "\(rawValue)" }

    var accessibilityLabel: String {
        switch self {
        case .one: "One scope"
        case .two: "Two scopes"
        case .four: "Four scopes"
        }
    }
}

/// Larger, resizable scope presentation for Pixel Analysis.
///
/// Each card owns a normal `ScopeViewModel`, so cancellation, request identity, and rendering
/// behavior remain the same as the established browser sidebar. Only models visible in the
/// selected layout retain the source image or consume render work.
struct AnalysisScopeWorkspace: View {
    let sourceImage: CGImage?

    @State private var layout: AnalysisScopeLayout = .two
    @State private var waveform = ScopeViewModel(
        scopeMode: .waveform,
        persistsScopeMode: false
    )
    @State private var parade = ScopeViewModel(
        scopeMode: .parade,
        persistsScopeMode: false
    )
    @State private var vectorscope = ScopeViewModel(
        scopeMode: .vectorscope,
        persistsScopeMode: false
    )
    @State private var chromaticity = ScopeViewModel(
        scopeMode: .chromaticity,
        persistsScopeMode: false
    )

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Scopes", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.semibold))
                Spacer()
                Picker("Scope layout", selection: $layout) {
                    ForEach(AnalysisScopeLayout.allCases, id: \.self) { layout in
                        Text(layout.label)
                            .tag(layout)
                            .accessibilityLabel(layout.accessibilityLabel)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 116)
                .help("Show one, two, or four resizable scopes")
            }

            scopeLayout
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: sourceIdentity, initial: true) {
            updateVisibleModels()
        }
        .onChange(of: layout) {
            updateVisibleModels()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(layout.accessibilityLabel) for the displayed image representation")
    }

    @ViewBuilder
    private var scopeLayout: some View {
        switch layout {
        case .one:
            AnalysisScopeCard(model: waveform)
        case .two:
            HSplitView {
                AnalysisScopeCard(model: waveform)
                AnalysisScopeCard(model: vectorscope)
            }
        case .four:
            VSplitView {
                HSplitView {
                    AnalysisScopeCard(model: waveform)
                    AnalysisScopeCard(model: parade)
                }
                HSplitView {
                    AnalysisScopeCard(model: vectorscope)
                    AnalysisScopeCard(model: chromaticity)
                }
            }
        }
    }

    private var sourceIdentity: ObjectIdentifier? {
        sourceImage.map { ObjectIdentifier($0) }
    }

    private var allModels: [ScopeViewModel] {
        [waveform, parade, vectorscope, chromaticity]
    }

    private var visibleModels: [ScopeViewModel] {
        switch layout {
        case .one:
            [waveform]
        case .two:
            [waveform, vectorscope]
        case .four:
            allModels
        }
    }

    private func updateVisibleModels() {
        let visibleIDs = Set(visibleModels.map(ObjectIdentifier.init))
        for model in allModels {
            model.updateImage(visibleIDs.contains(ObjectIdentifier(model)) ? sourceImage : nil)
        }
    }
}

private struct AnalysisScopeCard: View {
    @Bindable var model: ScopeViewModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("Scope", selection: $model.scopeMode) {
                    ForEach(ScopeViewModel.ScopeMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Scope type")
                Spacer()
                if model.isComputing {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Rendering \(model.scopeMode.displayName)")
                }
            }

            GeometryReader { geometry in
                let contentSize = ScopePresentationSizing.contentSize(
                    mode: model.scopeMode,
                    availableSize: geometry.size
                )

                ZStack {
                    Color.black

                    ZStack {
                        if let image = model.scopeImage {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .accessibilityLabel("\(model.scopeMode.displayName) scope")
                        } else if model.isComputing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("No image")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if model.scopeMode == .waveform || model.scopeMode == .parade {
                            ScopeLabelsOverlay(scale: model.waveformScale)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: contentSize.width, height: contentSize.height)
                    .task(id: RenderSizeIdentity(size: contentSize, scale: displayScale)) {
                        // Split-view drags can publish a new size every frame. Wait for a short
                        // quiet period so superseded detached CPU renders do not pile up.
                        do {
                            try await Task.sleep(for: .milliseconds(120))
                        } catch {
                            return
                        }
                        guard let pixelSize = ScopeRenderRequest.outputPixelSize(
                            for: contentSize,
                            backingScale: displayScale
                        ) else { return }
                        model.setOutputPixelSize(pixelSize)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(8)
        .frame(minWidth: 170, minHeight: 145)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct RenderSizeIdentity: Hashable {
    let width: Int
    let height: Int
    let scale: Int

    init(size: CGSize, scale: CGFloat) {
        width = Int(size.width.rounded())
        height = Int(size.height.rounded())
        self.scale = Int((scale * 100).rounded())
    }
}

private extension ScopeViewModel.ScopeMode {
    var displayName: String {
        switch self {
        case .waveform: "Waveform"
        case .parade: "RGBY Parade"
        case .vectorscope: "Vectorscope"
        case .chromaticity: "Chromaticity"
        }
    }
}
