import AppKit
import CoreGraphics

@Observable
final class ScopeViewModel {

    enum ScopeMode: String, CaseIterable {
        case waveform
        case parade
        case vectorscope
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

    var waveformScale: WaveformScale = .percentage {
        didSet {
            guard waveformScale != oldValue else { return }
            rerender()
        }
    }

    var scopeImage: NSImage?
    var isComputing = false

    var isDragMode = false {
        didSet {
            guard isDragMode != oldValue else { return }
            if !isDragMode, metalScopePipeline != nil {
                // Drag ended — keep the Metal scope visible until the CPU scope
                // image is ready, so there's no flash or blank frame.
                holdingMetalScope = true
            }
        }
    }

    // MARK: - Metal Scope

    /// Set by EditWorkspaceView when entering edit mode.
    @ObservationIgnored var metalScopePipeline: MetalScopePipeline?
    @ObservationIgnored var metalEditPipeline: MetalEditPipeline?
    @ObservationIgnored var metalScopeCoordinator: MetalScopeView.Coordinator?

    /// True while we keep the Metal scope visible after drag ends,
    /// waiting for the CPU scope to finish rendering.
    var holdingMetalScope = false

    var isMetalScopeActive: Bool {
        let dragging = isDragMode && metalScopePipeline != nil && metalEditPipeline?.hasSourceTexture == true
        return dragging || holdingMetalScope
    }

    func clearMetal() {
        holdingMetalScope = false
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
            holdingMetalScope = false
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
        let svc = service
        let size: CGFloat = isDragMode ? 360 : 720

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
                }
            }.value

            guard !Task.isCancelled else { return }

            if let result {
                scopeImage = NSImage(cgImage: result, size: NSSize(width: result.width / 4, height: result.height / 4))
            } else {
                scopeImage = nil
            }
            isComputing = false
            // CPU scope is ready — release the Metal scope hold
            holdingMetalScope = false
        }
    }
}
