import SwiftUI

struct ScopeDisplayView: View {
    let scopeViewModel: ScopeViewModel

    var body: some View {
        VStack(spacing: 4) {
            Picker("", selection: Bindable(scopeViewModel).scopeMode) {
                Text("Wave").tag(ScopeViewModel.ScopeMode.waveform)
                Text("Parade").tag(ScopeViewModel.ScopeMode.parade)
                Text("Vector").tag(ScopeViewModel.ScopeMode.vectorscope)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            ZStack {
                Color(nsColor: NSColor(white: 0.1, alpha: 1))

                if scopeViewModel.isMetalScopeActive,
                   let scopePipeline = scopeViewModel.metalScopePipeline,
                   let editPipeline = scopeViewModel.metalEditPipeline {
                    MetalScopeView(
                        scopePipeline: scopePipeline,
                        editPipeline: editPipeline,
                        mode: scopeViewModel.scopeMode,
                        waveformScale: scopeViewModel.waveformScale,
                        coordinator: scopeViewModel.metalScopeCoordinator
                    )
                    // Overlay text labels (Metal renders guide lines but not text)
                    if scopeViewModel.scopeMode != .vectorscope {
                        ScopeLabelsOverlay(scale: scopeViewModel.waveformScale)
                            .allowsHitTesting(false)
                    }
                } else if let image = scopeViewModel.scopeImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else if scopeViewModel.isComputing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

// MARK: - Scope Labels Overlay

/// SwiftUI overlay that renders text labels for waveform/parade guide lines.
/// Positioned to match the Metal shader's guide line locations.
private struct ScopeLabelsOverlay: View {
    let scale: WaveformScale

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let scaleF = size.width / 720
            let labelMargin = max(68 * scaleF, 24)
            let vm = max(16 * scaleF, 4)
            let dataHeight = size.height - vm * 2
            let fontSize = max(22 * scaleF, 8)

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
            let sdrColor = Color(red: 0.9, green: 0.65, blue: 0.2)
            return [
                (CGFloat(WaveformScale.nitsFraction(0)), "0", labelGray),
                (CGFloat(WaveformScale.nitsFraction(100)), "100", labelGray),
                (CGFloat(WaveformScale.nitsFraction(1000)), "1k", labelGray),
                (CGFloat(WaveformScale.nitsFraction(4000)), "4k", labelGray),
                (CGFloat(WaveformScale.nitsFraction(10000)), "10k", labelGray),
                (CGFloat(WaveformScale.nitsFraction(203)), "SDR", sdrColor),
            ]
        }
    }
}
