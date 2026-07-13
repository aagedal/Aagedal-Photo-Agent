import CoreImage
import MetalKit
import os
import SwiftUI

nonisolated private let metalPreviewLog = Logger(
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
    /// Shared display scaling preference used by both the full-screen viewer and editor.
    var useNearestNeighbor: Bool = false
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
        mtkView.clearColor = MTLClearColorMake(0.0197, 0.0197, 0.0197, 1)
        if let metalLayer = mtkView.layer as? CAMetalLayer {
            metalLayer.colorspace = Coordinator.colorSpace
            // Configure EDR eagerly so the first draw can show HDR content.
            metalLayer.wantsExtendedDynamicRangeContent = isHDR
            if #available(macOS 26.0, *) {
                metalLayer.preferredDynamicRange = isHDR ? .high : .standard
            }
        }
        // Opaque when HDR — non-opaque layer compositing can clip EDR values to SDR.
        mtkView.layer?.isOpaque = isHDR
        context.coordinator.mtkView = mtkView
        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.ciImage = ciImage
        context.coordinator.metalPipeline = metalPipeline
        context.coordinator.useComputeShader = useComputeShader
        context.coordinator.useNearestNeighbor = useNearestNeighbor
        if let metalLayer = mtkView.layer as? CAMetalLayer {
            // Always set wantsExtendedDynamicRangeContent — this is the fundamental
            // CAMetalLayer EDR enabler. preferredDynamicRange (macOS 26+) controls
            // layer compositing but doesn't replace this property.
            metalLayer.wantsExtendedDynamicRangeContent = isHDR
            if #available(macOS 26.0, *) {
                metalLayer.preferredDynamicRange = isHDR ? .high : .standard
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
        // Opaque when HDR to prevent alpha compositing from clipping EDR values.
        mtkView.layer?.isOpaque = isHDR
        // Walk the entire view hierarchy from the MTKView up to the window content view
        // and enable EDR on every ancestor layer. SwiftUI inserts intermediate
        // NSView/CALayer objects that can block EDR propagation if not opted in.
        Self.enableEDRAncestors(for: mtkView, isHDR: isHDR)
        mtkView.setNeedsDisplay(mtkView.bounds)
    }

    /// Walk from the given view up to the window content view, enabling EDR on every
    /// ancestor layer. Without this, SwiftUI's intermediate hosting layers clip
    /// extended-range pixel values to [0, 1] during compositing.
    /// Shared with the clean-feed render view (`CleanFeedRenderView`) so both EDR paths
    /// stay in lockstep.
    static func enableEDRAncestors(for view: NSView, isHDR: Bool) {
        var current: NSView? = view.superview
        while let ancestor = current {
            ancestor.wantsLayer = true
            if let layer = ancestor.layer {
                if #available(macOS 26.0, *) {
                    let target: CALayer.DynamicRange = isHDR ? .high : .standard
                    if layer.preferredDynamicRange != target {
                        layer.preferredDynamicRange = target
                    }
                }
                // wantsExtendedDynamicRangeContent is only on CAMetalLayer,
                // but preferredDynamicRange is on all CALayers (macOS 26+).
            }
            current = ancestor.superview
        }
    }

    class Coordinator: NSObject, MTKViewDelegate {
        nonisolated static let device = MTLCreateSystemDefaultDevice()!
        nonisolated static let commandQueue = device.makeCommandQueue()!
        nonisolated static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        nonisolated static let ciContext = CIContext(mtlDevice: device, options: [
            .workingFormat: CIFormat.RGBAh,
            .workingColorSpace: colorSpace,
        ])

        var ciImage: CIImage?
        var metalPipeline: MetalEditPipeline?
        var useComputeShader: Bool = false
        var useNearestNeighbor: Bool = false
        weak var mtkView: MTKView?

        /// Viewport for CIImage fallback rendering (set from EditWorkspaceView)
        var viewportOrigin: SIMD2<Float> = .zero
        var viewportSize: SIMD2<Float> = SIMD2<Float>(1, 1)

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
            // `.components.attoseconds` is only the sub-second remainder — must add `.seconds`
            // or any drag past 1s under-reports the elapsed time and wildly inflates the FPS.
            let elapsed = ContinuousClock.now - drawLogStart
            let totalSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let totalMs = Int(totalSeconds * 1000)
            let rate = drawCount > 0 && totalSeconds > 0 ? Double(drawCount) / totalSeconds : 0
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
            let sinceLast = now - lastDrawTimestamp
            let sinceLastMs = Int((Double(sinceLast.components.seconds)
                + Double(sinceLast.components.attoseconds) / 1e18) * 1000)
            lastDrawTimestamp = now
            if drawCount % 10 == 0 {
                metalPreviewLog.info("⏱ Draw #\(self.drawCount) — \(sinceLastMs)ms since last")
            }

            // Fast path: Metal compute shader during slider drag
            if useComputeShader, let pipeline = metalPipeline, pipeline.hasSourceTexture {
                if pipeline.render(
                    to: drawable,
                    drawableSize: drawableSize,
                    useNearestNeighbor: useNearestNeighbor
                ) {
                    return
                }
            }

            // Standard path: CIImage → CIContext → drawable (viewport-aware)
            guard let ciImage,
                  let commandBuffer = Self.commandQueue.makeCommandBuffer() else { return }

            let extent = ciImage.extent
            guard extent.width > 0, extent.height > 0 else { return }

            // Compute viewport region in CIImage coordinates.
            // The viewport maps normalized [0,1] source coords to the visible area.
            let vpOriginX = CGFloat(viewportOrigin.x) * extent.width + extent.origin.x
            let vpOriginY = CGFloat(viewportOrigin.y) * extent.height + extent.origin.y
            let vpWidth = CGFloat(viewportSize.x) * extent.width
            let vpHeight = CGFloat(viewportSize.y) * extent.height

            // Scale the viewport region to fill the drawable
            let scaleX = drawableSize.width / vpWidth
            let scaleY = drawableSize.height / vpHeight
            let sampledImage = useNearestNeighbor ? ciImage.samplingNearest() : ciImage
            let scaled = sampledImage
                .transformed(by: CGAffineTransform(
                    translationX: -vpOriginX,
                    y: -vpOriginY
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
