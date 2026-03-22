import CoreImage
import MetalKit
import os
import SwiftUI

nonisolated(unsafe) private let metalPreviewLog = Logger(
    subsystem: "com.aagedal.photo-agent", category: "MetalPreview"
)

/// Renders a CIImage directly to a Metal drawable, bypassing the GPU→CPU→GPU
/// round-trip of CIContext.createCGImage + NSImage + SwiftUI Image.
/// Supports HDR via rgba16Float pixel format and extended dynamic range.
///
/// Dual rendering mode:
/// - **Metal compute path** (primary): MetalEditPipeline dispatches a single
///   compute kernel with LUT-based tonal adjustments directly to the drawable.
/// - **CIImage path** (fallback): Renders the CIFilter graph via CIContext
///   when compute shader is unavailable (e.g. "before" toggle).
struct MetalPreviewView: NSViewRepresentable {
    let ciImage: CIImage?
    let isHDR: Bool
    var metalPipeline: MetalEditPipeline?
    var useComputeShader: Bool = false
    /// Shared coordinator owned by the parent view for direct redraw requests.
    var coordinator: Coordinator?

    func makeCoordinator() -> Coordinator {
        // Use the shared coordinator if provided, otherwise create one
        coordinator ?? Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView(frame: .zero, device: Coordinator.device)
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .rgba16Float
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0)
        mtkView.layer?.isOpaque = false
        if let metalLayer = mtkView.layer as? CAMetalLayer {
            metalLayer.colorspace = Coordinator.colorSpace
        }
        context.coordinator.mtkView = mtkView
        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.ciImage = ciImage
        context.coordinator.metalPipeline = metalPipeline
        context.coordinator.useComputeShader = useComputeShader
        if let metalLayer = mtkView.layer as? CAMetalLayer {
            if #available(macOS 26.0, *) {
                metalLayer.preferredDynamicRange = isHDR ? .high : .standard
            } else {
                metalLayer.wantsExtendedDynamicRangeContent = isHDR
            }
            // Always render at full Retina resolution — Apple Silicon GPUs handle
            // the compute shader at full 2x with ease (<1ms for typical preview sizes).
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
        // Ensure the window's content view opts into EDR — CAMetalLayer EDR
        // requires ancestor opt-in on macOS (matching FullScreenImageView setup).
        if let windowContentView = mtkView.window?.contentView {
            windowContentView.wantsLayer = true
            if #available(macOS 26.0, *) {
                let target: CALayer.DynamicRange = isHDR ? .high : .standard
                if windowContentView.layer?.preferredDynamicRange != target {
                    windowContentView.layer?.preferredDynamicRange = target
                }
            } else {
                if windowContentView.layer?.wantsExtendedDynamicRangeContent != isHDR {
                    windowContentView.layer?.wantsExtendedDynamicRangeContent = isHDR
                }
            }
        }
        mtkView.setNeedsDisplay(mtkView.bounds)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        nonisolated(unsafe) static let device = MTLCreateSystemDefaultDevice()!
        nonisolated(unsafe) static let commandQueue = device.makeCommandQueue()!
        nonisolated(unsafe) static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        nonisolated(unsafe) static let ciContext = CIContext(mtlDevice: device, options: [
            .workingFormat: CIFormat.RGBAh,
            .workingColorSpace: colorSpace,
        ])

        var ciImage: CIImage?
        var metalPipeline: MetalEditPipeline?
        var useComputeShader: Bool = false
        weak var mtkView: MTKView?

        // Draw rate logging
        var drawCount: Int = 0
        var drawLogStart: ContinuousClock.Instant = .now
        var lastDrawTimestamp: ContinuousClock.Instant = .now

        /// Direct redraw bypassing SwiftUI state propagation.
        func requestRedraw() {
            guard let mtkView else { return }
            mtkView.setNeedsDisplay(mtkView.bounds)
        }

        /// Switch MTKView to continuous rendering at the display's native refresh rate.
        /// Call when slider drag begins — decouples render rate from input event rate.
        func startContinuousRendering() {
            guard let mtkView else { return }
            drawCount = 0
            drawLogStart = .now
            metalPreviewLog.info("⏱ Continuous rendering started (target: \(NSScreen.main?.maximumFramesPerSecond ?? 60) FPS)")
            mtkView.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
            mtkView.isPaused = false
            mtkView.enableSetNeedsDisplay = false
        }

        /// Return MTKView to manual rendering mode.
        /// Call when slider drag ends — avoids burning GPU cycles when idle.
        func stopContinuousRendering() {
            guard let mtkView else { return }
            let totalMs = (ContinuousClock.now - drawLogStart).components.attoseconds / 1_000_000_000_000_000
            let rate = drawCount > 0 && totalMs > 0 ? Double(drawCount) / (Double(totalMs) / 1000.0) : 0
            metalPreviewLog.info("⏱ Continuous rendering stopped: \(self.drawCount) draws over \(totalMs)ms = \(rate, format: .fixed(precision: 1)) FPS")
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = true
            mtkView.setNeedsDisplay(mtkView.bounds)
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                performDraw(in: view)
            }
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Drawable resized — redraw on next display refresh
        }

        private func performDraw(in view: MTKView) {
            guard let drawable = view.currentDrawable else { return }
            let drawableSize = view.drawableSize
            guard drawableSize.width > 0, drawableSize.height > 0 else { return }

            drawCount += 1
            let now = ContinuousClock.now
            let sinceLastMs = (now - lastDrawTimestamp).components.attoseconds / 1_000_000_000_000_000
            lastDrawTimestamp = now
            if drawCount % 10 == 0 {
                metalPreviewLog.info("⏱ Draw #\(self.drawCount) — \(sinceLastMs)ms since last")
            }

            // Fast path: Metal compute shader during slider drag
            if useComputeShader, let pipeline = metalPipeline, pipeline.hasSourceTexture {
                if pipeline.render(to: drawable, drawableSize: drawableSize) {
                    return
                }
            }

            // Standard path: CIImage → CIContext → drawable
            guard let ciImage,
                  let commandBuffer = Self.commandQueue.makeCommandBuffer() else { return }

            let extent = ciImage.extent
            guard extent.width > 0, extent.height > 0 else { return }

            // Scale CIImage to fill the drawable.
            // Parent SwiftUI view handles aspect-fit layout via .frame(width:height:).
            let scaleX = drawableSize.width / extent.width
            let scaleY = drawableSize.height / extent.height
            let scaled = ciImage
                .transformed(by: CGAffineTransform(
                    translationX: -extent.origin.x,
                    y: -extent.origin.y
                ))
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

            let destination = CIRenderDestination(
                width: Int(drawableSize.width),
                height: Int(drawableSize.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: commandBuffer,
                mtlTextureProvider: { drawable.texture }
            )
            destination.isFlipped = true
            destination.colorSpace = Self.colorSpace

            do {
                try Self.ciContext.startTask(
                    toRender: scaled,
                    from: CGRect(origin: .zero, size: drawableSize),
                    to: destination,
                    at: .zero
                )
            } catch {
                return
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
