import SwiftUI

struct ScopeDisplayView: View {
    let scopeViewModel: ScopeViewModel
    @Binding var isExpanded: Bool
    @State private var hoveredMode: ScopeViewModel.ScopeMode?

    /// Fixed height of the scope area — independent of the sidebar width.
    private let scopeHeight = ScopePresentationSizing.sidebarHeight

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse scopes" : "Expand scopes")

                if isExpanded {
                    ForEach(ScopeViewModel.ScopeMode.allCases, id: \.self) { mode in
                        Button {
                            scopeViewModel.scopeMode = mode
                        } label: {
                            Text(label(for: mode))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(
                                    scopeViewModel.scopeMode == mode
                                        ? Color.primary
                                        : Color.secondary.opacity(0.5)
                                )
                                .underline(hoveredMode == mode)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            hoveredMode = hovering ? mode : nil
                        }
                        .accessibilityLabel("\(label(for: mode)) scope")
                        .accessibilityValue(
                            scopeViewModel.scopeMode == mode ? "Selected" : "Not selected"
                        )
                        .accessibilityAddTraits(
                            scopeViewModel.scopeMode == mode ? .isSelected : []
                        )
                    }
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isExpanded = true
                        }
                    } label: {
                        Text("Scopes")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Expand scope controls")
                    Spacer()
                    Text(label(for: scopeViewModel.scopeMode))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isExpanded {
                // GeometryReader sizes from its parent (not its children), so the
                // background tracks the sidebar width and shrinks back correctly
                // when the sidebar narrows again.
                GeometryReader { geo in
                    let content = scopeContentSize(forWidth: geo.size.width)
                    ZStack {
                        // Background always fills the full available width. Black so
                        // it's seamless with the scopes' own black backgrounds
                        // (e.g. the centered vectorscope square).
                        Color.black

                        // The scope graphic, sized per-mode and centered.
                        scopeGraphic
                            .frame(width: content.width, height: content.height)
                    }
                    .frame(width: geo.size.width, height: scopeHeight)
                }
                .frame(height: scopeHeight)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    @ViewBuilder
    private var scopeGraphic: some View {
        ZStack {
            if scopeViewModel.isMetalScopeActive,
               let scopePipeline = scopeViewModel.metalScopePipeline,
               let editPipeline = scopeViewModel.metalEditPipeline {
                MetalScopeView(
                    scopePipeline: scopePipeline,
                    editPipeline: editPipeline,
                    mode: scopeViewModel.scopeMode,
                    waveformScale: scopeViewModel.waveformScale,
                    showClippedGamut: scopeViewModel.showClippedGamut,
                    targetGamut: scopeViewModel.targetGamut.shaderIndex,
                    displayGamut: scopeViewModel.displayGamut.shaderIndex,
                    isContinuouslyRendering: scopeViewModel.isDragMode,
                    coordinator: scopeViewModel.metalScopeCoordinator
                )
            } else if let image = scopeViewModel.scopeImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else if scopeViewModel.isComputing {
                ProgressView()
                    .controlSize(.small)
            }

            // Unified label overlay for both Metal and CPU scope paths
            if scopeViewModel.scopeMode != .vectorscope && scopeViewModel.scopeMode != .chromaticity {
                ScopeLabelsOverlay(scale: scopeViewModel.waveformScale)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Size the scope graphic occupies (centered on the background) for a given
    /// available width. Height stays fixed; only the width adapts per-mode.
    private func scopeContentSize(forWidth width: CGFloat) -> CGSize {
        ScopePresentationSizing.contentSize(
            mode: scopeViewModel.scopeMode,
            availableSize: CGSize(width: width, height: scopeHeight)
        )
    }

    private func label(for mode: ScopeViewModel.ScopeMode) -> String {
        switch mode {
        case .waveform: "Wave"
        case .parade: "Parade"
        case .vectorscope: "Vector"
        case .chromaticity: "Gamut"
        }
    }
}

// MARK: - Scope Labels Overlay

/// SwiftUI overlay that renders text labels for waveform/parade guide lines.
/// Positioned to match the Metal shader's guide line locations.
struct ScopeLabelsOverlay: View {
    let scale: WaveformScale

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let scaleF = size.width / 720
            let labelMargin = max(68 * scaleF, 24)
            let vm = max(16 * scaleF, 4)
            let dataHeight = size.height - vm * 2
            let fontSize = max(20 * scaleF, 8)

            ForEach(guideLabels, id: \.label) { guide in
                let yFromBottom = vm + guide.fraction * dataHeight
                let y = size.height - yFromBottom
                Text(guide.label)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(guide.color)
                    .position(x: labelMargin * 0.45, y: y)
            }
        }
    }

    private var guideLabels: [(fraction: CGFloat, label: String, color: Color)] {
        let labelGray = Color(white: 0.55)
        switch scale {
        case .percentage:
            return [
                (0.0, "0", labelGray),
                (0.25, "25", labelGray),
                (0.5, "50", labelGray),
                (0.75, "75", labelGray),
                (1.0, "100", labelGray),
            ]
        case .nits:
            let hdrColor = Color(red: 0.9, green: 0.65, blue: 0.2)
            return [
                (CGFloat(WaveformScale.nitsFraction(0)), "0", labelGray),
                (CGFloat(WaveformScale.nitsFraction(100)), "100", labelGray),
                (CGFloat(WaveformScale.nitsFraction(500)), "500", labelGray),
                (CGFloat(WaveformScale.nitsFraction(1000)), "1k", labelGray),
                (CGFloat(WaveformScale.nitsFraction(2000)), "2k", labelGray),
                (CGFloat(WaveformScale.nitsFraction(165)), "SDR", .white),
                (CGFloat(WaveformScale.nitsFraction(260)), "HDR", hdrColor),
            ]
        }
    }
}
