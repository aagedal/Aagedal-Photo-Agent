import AppKit
import CoreImage
import MetalKit
import os
import SwiftUI

nonisolated private let cleanFeedViewLog = Logger(
    subsystem: "com.aagedal.photo-agent", category: "CleanFeedView"
)

/// SwiftUI content hosted inside the clean-feed window. Renders the current image
/// chrome-free, aspect-fit on black. In browse/cull mode it loads + edits the
/// selected image; in edit mode the workspace pushes content into the controller.
struct CleanFeedContentView: View {
    @Bindable var controller: CleanFeedController
    let browserViewModel: BrowserViewModel

    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        // Reading these here registers SwiftUI observation so `updateNSView` fires
        // (and the browse loader re-runs) when they change.
        CleanFeedRenderView(
            controller: controller,
            feedImage: controller.feedImage,
            useEditPipeline: controller.useEditPipeline
        )
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear { reloadFromSelection() }
        .onChange(of: browserViewModel.firstSelectedImage?.url) { _, _ in reloadFromSelection() }
        .onChange(of: browserViewModel.firstSelectedImage?.cameraRawSettings) { _, _ in reloadFromSelection() }
        .onChange(of: browserViewModel.firstSelectedImage?.exifOrientation) { _, _ in reloadFromSelection() }
        .onChange(of: controller.editModeActive) { _, active in
            if !active { reloadFromSelection() }
        }
    }

    /// Browse/cull mode: load the selected image, apply its committed edits + crop,
    /// and push the result into the controller as the feed still. No-op while the
    /// edit workspace owns the feed.
    private func reloadFromSelection() {
        guard !controller.editModeActive else { return }
        loadTask?.cancel()

        guard let image = browserViewModel.firstSelectedImage else {
            controller.feedImage = nil
            controller.useEditPipeline = false
            controller.requestFeedRedraw()
            return
        }

        let url = image.url
        let settings = image.cameraRawSettings
        let exifOrientation = image.exifOrientation
        let maxPixelSize = Self.feedMaxPixelSize

        loadTask = Task {
            let edited: CIImage? = await Task.detached(priority: .userInitiated) {
                // Base image (display-oriented as decoded by the cache loaders).
                let base: CIImage?
                if FullScreenImageCache.isRawFile(url) {
                    base = FullScreenImageCache.loadRAWPreview(from: url, maxPixelSize: maxPixelSize, draftMode: true)
                        ?? FullScreenImageCache.extractEmbeddedPreview(from: url).map { CIImage(cgImage: $0) }
                } else {
                    base = FullScreenImageCache.loadHDRPreview(from: url, maxPixelSize: maxPixelSize)
                        ?? FullScreenImageCache.loadDownsampled(from: url, maxPixelSize: maxPixelSize).map { CIImage(cgImage: $0) }
                }
                guard let base else { return nil }

                // Correct for in-memory rotation that isn't baked into the file
                // (mirrors FullScreenImageView's file-vs-memory orientation handling).
                let fileOrientation: Int = {
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                          let o = props[kCGImagePropertyOrientation] as? Int else { return exifOrientation }
                    return o
                }()

                var processed = base
                if let settings {
                    processed = CameraRawApproximation.applyWithCrop(
                        to: base, settings: settings, exifOrientation: fileOrientation
                    )
                }
                let correction = ImageFile.orientationCorrection(from: fileOrientation, to: exifOrientation)
                if correction != .up { processed = processed.oriented(correction) }
                return processed
            }.value

            guard !Task.isCancelled else { return }
            controller.feedImage = edited
            controller.isHDR = false
            controller.useEditPipeline = false
            controller.requestFeedRedraw()
        }
    }

    /// Cap the browse-mode decode to roughly the largest connected display so the
    /// feed is sharp without decoding full-resolution RAW for a passive monitor.
    private static var feedMaxPixelSize: CGFloat {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0
        let logical = NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) }
            .max() ?? 1920
        return min(max(logical * scale, 1600), 3840)
    }
}

/// Renders the feed to a Metal drawable. Two paths, mirroring the editor:
/// - **Live edit**: the shared `feedPipeline` compute shader (zero-lag tracking).
/// - **Still**: a `CIImage` aspect-fit and composited over black.
struct CleanFeedRenderView: NSViewRepresentable {
    let controller: CleanFeedController
    let feedImage: CIImage?
    let useEditPipeline: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(feedPipeline: controller.feedPipeline)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MetalPreviewView.Coordinator.device)
        view.delegate = context.coordinator
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.framebufferOnly = false
        view.colorPixelFormat = .rgba16Float
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = MetalPreviewView.Coordinator.colorSpace
        }
        context.coordinator.mtkView = view

        // Register redraw / continuous hooks so the edit pipeline (via the controller)
        // can drive this view directly during live editing.
        controller.hooks.redraw = { [weak coordinator = context.coordinator] in
            coordinator?.requestRedraw()
        }
        controller.hooks.setContinuous = { [weak coordinator = context.coordinator] on in
            coordinator?.setContinuousRendering(on)
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.feedImage = feedImage
        context.coordinator.useEditPipeline = useEditPipeline
        view.setNeedsDisplay(view.bounds)
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.mtkView = nil
    }

    /// Not marked `@MainActor` so `requestRedraw()` can be called from the pipeline's
    /// non-isolated `updateParams` (matching `MetalPreviewView.Coordinator`). All
    /// drawing happens inside `MainActor.assumeIsolated`.
    final class Coordinator: NSObject, MTKViewDelegate {
        weak var mtkView: MTKView?
        let feedPipeline: MetalEditPipeline?

        // Plain (non-isolated) copies set from `updateNSView` on the main thread.
        var feedImage: CIImage?
        var useEditPipeline: Bool = false

        init(feedPipeline: MetalEditPipeline?) {
            self.feedPipeline = feedPipeline
        }

        func requestRedraw() {
            guard let mtkView else { return }
            mtkView.setNeedsDisplay(mtkView.bounds)
        }

        func setContinuousRendering(_ on: Bool) {
            guard let mtkView else { return }
            if on {
                mtkView.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
                mtkView.isPaused = false
                mtkView.enableSetNeedsDisplay = false
            } else {
                mtkView.isPaused = true
                mtkView.enableSetNeedsDisplay = true
                mtkView.setNeedsDisplay(mtkView.bounds)
            }
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { performDraw(in: view) }
        }

        private func performDraw(in view: MTKView) {
            guard let drawable = view.currentDrawable else { return }
            let drawableSize = view.drawableSize
            guard drawableSize.width > 0, drawableSize.height > 0 else { return }

            // Live edit path: shared compute pipeline, aspect-fit for this display.
            if useEditPipeline,
               let pipeline = feedPipeline,
               pipeline.hasSourceTexture,
               let srcSize = pipeline.sourceTextureSize {
                pipeline.updateViewport(
                    zoomScale: 1.0,
                    offset: .zero,
                    containerSize: drawableSize,
                    imageSize: srcSize
                )
                if pipeline.render(to: drawable, drawableSize: drawableSize) { return }
            }

            // Still path: aspect-fit the CIImage and composite over black so the
            // letterbox area is always cleared (no stale frame contents).
            guard let commandBuffer = MetalPreviewView.Coordinator.commandQueue.makeCommandBuffer() else { return }
            let drawableRect = CGRect(origin: .zero, size: drawableSize)
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: drawableRect)

            let content: CIImage
            if let image = feedImage, image.extent.width > 0, image.extent.height > 0 {
                let extent = image.extent
                let scale = min(drawableSize.width / extent.width, drawableSize.height / extent.height)
                let scaledW = extent.width * scale
                let scaledH = extent.height * scale
                let tx = (drawableSize.width - scaledW) / 2
                let ty = (drawableSize.height - scaledH) / 2
                let fitted = image
                    .transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: tx, y: ty))
                content = fitted.composited(over: black)
            } else {
                content = black
            }

            let destination = CIRenderDestination(
                width: Int(drawableSize.width),
                height: Int(drawableSize.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: commandBuffer,
                mtlTextureProvider: { drawable.texture }
            )
            destination.isFlipped = true
            destination.colorSpace = MetalPreviewView.Coordinator.colorSpace

            do {
                try MetalPreviewView.Coordinator.ciContext.startTask(
                    toRender: content,
                    from: drawableRect,
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
