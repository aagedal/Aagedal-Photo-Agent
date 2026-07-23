import AppKit
import CoreGraphics

@Observable
final class ScopeViewModel {

    enum ScopeMode: String, CaseIterable {
        case waveform
        case parade
        case vectorscope
        case chromaticity
    }

    var scopeMode: ScopeMode = .waveform {
        didSet {
            guard scopeMode != oldValue else { return }
            UserDefaults.standard.set(scopeMode.rawValue, forKey: UserDefaultsKeys.lastScopeMode)
            rerender()
        }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastScopeMode),
           let mode = ScopeMode(rawValue: raw) {
            self.scopeMode = mode
        }
    }

    deinit {
        computeTask?.cancel()
    }

    var waveformScale: WaveformScale = .percentage {
        didSet {
            guard waveformScale != oldValue else { return }
            rerender()
        }
    }

    var showClippedGamut: Bool = false {
        didSet {
            guard showClippedGamut != oldValue else { return }
            rerender()
        }
    }

    var targetGamut: TargetColorGamut = .sRGB {
        didSet {
            guard targetGamut != oldValue, scopeMode == .chromaticity else { return }
            rerender()
        }
    }

    var displayGamut: TargetColorGamut = .sRGB {
        didSet {
            guard displayGamut != oldValue, scopeMode == .chromaticity else { return }
            rerender()
        }
    }

    var scopeImage: NSImage?
    var isComputing = false

    var isDragMode = false

    // MARK: - Metal Scope

    /// Set by EditWorkspaceView when entering edit mode.
    @ObservationIgnored var metalScopePipeline: MetalScopePipeline?
    @ObservationIgnored var metalEditPipeline: MetalEditPipeline?
    @ObservationIgnored var metalScopeCoordinator: MetalScopeView.Coordinator?

    /// Keep the live Metal renderer as the scope presentation throughout edit mode.
    /// `MetalScopeView` pauses itself between adjustments and redraws only when needed,
    /// so the idle presentation matches the adjusting presentation without continuously
    /// consuming GPU time.
    var isMetalScopeActive: Bool {
        metalScopePipeline != nil && metalEditPipeline?.hasSourceTexture == true
    }

    func clearMetal() {
        metalScopePipeline = nil
        metalEditPipeline = nil
        metalScopeCoordinator = nil
    }

    // MARK: - CPU Scope

    @ObservationIgnored private var computeTask: Task<Void, Never>?
    @ObservationIgnored private let service = ScopeRenderService()
    @ObservationIgnored private var lastCGImage: CGImage?

    func updateImage(_ cgImage: CGImage?) {
        // During active drag, Metal handles scope rendering
        if isDragMode, metalScopePipeline != nil { return }

        guard cgImage !== lastCGImage else { return }
        lastCGImage = cgImage

        guard let cgImage else {
            computeTask?.cancel()
            scopeImage = nil
            isComputing = false
            return
        }

        render(cgImage)
    }

    // MARK: - Private

    private func rerender() {
        guard let image = lastCGImage else { return }
        render(image)
    }

    private func render(_ cgImage: CGImage) {
        computeTask?.cancel()
        isComputing = true

        let mode = scopeMode
        let scale = waveformScale
        let clipped = showClippedGamut
        let gamut = targetGamut
        let dispGamut = displayGamut
        let svc = service
        let size: CGFloat = 720

        computeTask = Task {
            let result = await Task.detached(priority: .utility) { () -> CGImage? in
                let outputSize = CGSize(width: size, height: size)
                switch mode {
                case .waveform:
                    return svc.renderWaveform(from: cgImage, outputSize: outputSize, scale: scale)
                case .parade:
                    return svc.renderParade(from: cgImage, outputSize: outputSize, scale: scale)
                case .vectorscope:
                    return svc.renderVectorscope(from: cgImage, outputSize: outputSize)
                case .chromaticity:
                    return svc.renderChromaticity(from: cgImage, outputSize: outputSize, clipped: clipped, targetGamut: gamut, displayGamut: dispGamut)
                }
            }.value

            guard !Task.isCancelled else { return }

            if let result {
                scopeImage = NSImage(cgImage: result, size: NSSize(width: result.width / 4, height: result.height / 4))
            } else {
                scopeImage = nil
            }
            isComputing = false
        }
    }
}
