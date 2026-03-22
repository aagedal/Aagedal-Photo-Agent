import MetalKit
import os
import SwiftUI

nonisolated(unsafe) private let metalScopeLog = Logger(
    subsystem: "com.aagedal.photo-agent", category: "MetalScope"
)

/// Renders scope (waveform/parade/vectorscope) via Metal compute shaders,
/// displayed in an MTKView. Runs at display refresh rate during slider drag
/// for real-time feedback without CPU-based scope rendering.
///
/// This view only exists while `isMetalScopeActive` is true (i.e. during drag),
/// so it starts in continuous rendering mode immediately.
struct MetalScopeView: NSViewRepresentable {
    let scopePipeline: MetalScopePipeline
    let editPipeline: MetalEditPipeline
    let mode: ScopeViewModel.ScopeMode
    let waveformScale: WaveformScale
    var coordinator: Coordinator?

    func makeCoordinator() -> Coordinator {
        coordinator ?? Coordinator(scopePipeline: scopePipeline)
    }

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView(frame: .zero, device: scopePipeline.device)
        mtkView.delegate = context.coordinator
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        mtkView.layer?.isOpaque = true
        context.coordinator.mtkView = mtkView
        context.coordinator.editPipeline = editPipeline

        // This view only appears during drag — start continuous rendering immediately
        mtkView.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        context.coordinator.drawCount = 0
        context.coordinator.drawLogStart = .now
        metalScopeLog.info("Scope Metal view created — continuous rendering started")

        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.editPipeline = editPipeline
        context.coordinator.mode = mode
        context.coordinator.waveformScale = waveformScale
        if let metalLayer = mtkView.layer as? CAMetalLayer {
            let backingScale = mtkView.window?.backingScaleFactor ?? 2.0
            metalLayer.contentsScale = backingScale
            let bounds = mtkView.bounds.size
            let targetSize = CGSize(
                width: bounds.width * backingScale,
                height: bounds.height * backingScale
            )
            if mtkView.drawableSize != targetSize {
                mtkView.drawableSize = targetSize
            }
        }
    }

    class Coordinator: NSObject, MTKViewDelegate {
        let scopePipeline: MetalScopePipeline
        var editPipeline: MetalEditPipeline?
        var mode: ScopeViewModel.ScopeMode = .waveform
        var waveformScale: WaveformScale = .percentage
        weak var mtkView: MTKView?

        var drawCount: Int = 0
        var drawLogStart: ContinuousClock.Instant = .now

        init(scopePipeline: MetalScopePipeline) {
            self.scopePipeline = scopePipeline
        }

        /// Stop continuous rendering (called when drag ends / view disappears).
        func stopContinuousRendering() {
            guard let mtkView else { return }
            let totalMs = (ContinuousClock.now - drawLogStart).components.attoseconds / 1_000_000_000_000_000
            let rate = drawCount > 0 && totalMs > 0 ? Double(drawCount) / (Double(totalMs) / 1000.0) : 0
            metalScopeLog.info("Scope continuous rendering stopped: \(self.drawCount) draws = \(rate, format: .fixed(precision: 1)) FPS")
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = true
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                performDraw(in: view)
            }
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        private func performDraw(in view: MTKView) {
            guard let editPipeline, editPipeline.hasSourceTexture,
                  let sourceTexture = editPipeline.sourceTexture,
                  let paramsBuffer = editPipeline.paramsBuffer,
                  let drawable = view.currentDrawable else { return }

            let drawableSize = view.drawableSize
            guard drawableSize.width > 0, drawableSize.height > 0 else { return }

            drawCount += 1

            _ = scopePipeline.renderToDrawable(
                sourceTexture: sourceTexture,
                editParamsBuffer: paramsBuffer,
                lutTexture: editPipeline.lutTexture,
                mode: mode,
                scale: waveformScale,
                drawable: drawable,
                drawableSize: drawableSize
            )
        }
    }
}
