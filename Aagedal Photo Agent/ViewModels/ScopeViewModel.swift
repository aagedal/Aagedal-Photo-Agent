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
            rerender()
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
            guard isDragMode != oldValue, !isDragMode else { return }
            rerender()
        }
    }

    @ObservationIgnored private var computeTask: Task<Void, Never>?
    @ObservationIgnored private let service = ScopeRenderService()
    @ObservationIgnored private var lastCGImage: CGImage?

    func updateImage(_ cgImage: CGImage?) {
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
        }
    }
}
