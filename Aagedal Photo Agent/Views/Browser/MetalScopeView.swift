import MetalKit
import os
import SwiftUI

nonisolated private let metalScopeLog = Logger(
    subsystem: "com.aagedal.photo-agent", category: "MetalScope"
)

/// Renders scope (waveform/parade/vectorscope) via Metal compute shaders,
/// displayed in an MTKView. Runs at display refresh rate during slider drag
/// for real-time feedback without CPU-based scope rendering.
struct MetalScopeView: NSViewRepresentable {
    let scopePipeline: MetalScopePipeline
    let editPipeline: MetalLivePreviewPipeline
    let mode: ScopeViewModel.ScopeMode
    let waveformScale: WaveformScale
    var showClippedGamut: Bool = false
    var targetGamut: UInt32 = 0
    var displayGamut: UInt32 = 0
    var isContinuouslyRendering = false
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

        // Idle scopes render on demand; active adjustments switch to display-rate rendering.
        context.coordinator.setContinuousRendering(isContinuouslyRendering)

        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.editPipeline = editPipeline
        context.coordinator.mode = mode
        context.coordinator.waveformScale = waveformScale
        context.coordinator.clipMode = showClippedGamut
        context.coordinator.targetGamut = targetGamut
        context.coordinator.displayGamut = displayGamut
        context.coordinator.setContinuousRendering(isContinuouslyRendering)
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
        if !isContinuouslyRendering {
            context.coordinator.requestRedraw()
        }
    }

    static func dismantleNSView(_ mtkView: MTKView, coordinator: Coordinator) {
        coordinator.stopContinuousRendering()
        mtkView.delegate = nil
        coordinator.mtkView = nil
    }

    class Coordinator: NSObject, MTKViewDelegate {
        let scopePipeline: MetalScopePipeline
        var editPipeline: MetalLivePreviewPipeline?
        var mode: ScopeViewModel.ScopeMode = .waveform
        var waveformScale: WaveformScale = .percentage
        var clipMode: Bool = false
        var targetGamut: UInt32 = 0
        var displayGamut: UInt32 = 0
        var cropLeft: Float = 0
        var cropTop: Float = 0
        var cropRight: Float = 1
        var cropBottom: Float = 1
        weak var mtkView: MTKView?

        var drawCount: Int = 0
        var drawLogStart: ContinuousClock.Instant = .now
        private var isRenderingContinuously = false

        init(scopePipeline: MetalScopePipeline) {
            self.scopePipeline = scopePipeline
        }

        /// Direct redraw while the view is in its idle, on-demand rendering mode.
        func requestRedraw() {
            guard let mtkView else { return }
            mtkView.setNeedsDisplay(mtkView.bounds)
        }

        func setContinuousRendering(_ enabled: Bool) {
            if enabled {
                startContinuousRendering()
            } else {
                stopContinuousRendering()
            }
        }

        private func startContinuousRendering() {
            guard let mtkView, !isRenderingContinuously else { return }
            isRenderingContinuously = true
            drawCount = 0
            drawLogStart = .now
            mtkView.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
            mtkView.enableSetNeedsDisplay = false
            mtkView.isPaused = false
            metalScopeLog.info("Scope continuous rendering started")
        }

        /// Stop continuous rendering (called when drag ends / view disappears).
        func stopContinuousRendering() {
            guard let mtkView else { return }
            if isRenderingContinuously {
                let elapsed = ContinuousClock.now - drawLogStart
                let totalSeconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                let rate = drawCount > 0 && totalSeconds > 0
                    ? Double(drawCount) / totalSeconds
                    : 0
                metalScopeLog.info("Scope continuous rendering stopped: \(self.drawCount) draws = \(rate, format: .fixed(precision: 1)) FPS")
            }
            isRenderingContinuously = false
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = true
            requestRedraw()
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
                colorLUTTexture: editPipeline.colorLUTTexture,
                maskBuffer: editPipeline.maskBuffer,
                hslBuffer: editPipeline.hslBuffer,
                orderBuffer: editPipeline.orderBuffer,
                mode: mode,
                scale: waveformScale,
                clipMode: clipMode,
                targetGamut: targetGamut,
                displayGamut: displayGamut,
                cropLeft: cropLeft, cropTop: cropTop,
                cropRight: cropRight, cropBottom: cropBottom,
                drawable: drawable,
                drawableSize: drawableSize
            )
        }
    }
}
