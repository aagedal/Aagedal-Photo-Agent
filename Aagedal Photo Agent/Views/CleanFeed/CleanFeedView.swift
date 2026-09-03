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
    @State private var loadRequestID: UUID?

    var body: some View {
        // Reading these here registers SwiftUI observation so `updateNSView` fires
        // (and the browse loader re-runs) when they change.
        CleanFeedRenderView(
            controller: controller,
            feedImage: controller.feedImage,
            useEditPipeline: controller.useEditPipeline,
            isHDR: controller.comparisonPresentation?.containsHDR ?? controller.isHDR,
            feedCrop: controller.feedCrop,
            comparisonPresentation: controller.comparisonPresentation,
            comparisonLayout: controller.comparisonLayout
        )
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear { reloadFromSelection() }
        .onChange(of: browserViewModel.firstSelectedImage?.url) { _, _ in reloadFromSelection() }
        .onChange(of: browserViewModel.firstSelectedImage?.cameraRawSettings) { _, _ in reloadFromSelection() }
        .onChange(of: browserViewModel.firstSelectedImage?.exifOrientation) { _, _ in reloadFromSelection() }
        .onChange(of: controller.editModeActive) { _, active in
            if active {
                cancelBrowseLoad()
            } else {
                reloadFromSelection()
            }
        }
        .onDisappear { cancelBrowseLoad() }
    }

    /// Browse/cull mode: load the selected image, apply its committed edits + crop,
    /// and push the result into the controller as the feed still. No-op while the
    /// edit workspace owns the feed.
    private func reloadFromSelection() {
        guard !controller.editModeActive else { return }
        loadTask?.cancel()
        let requestID = UUID()
        loadRequestID = requestID

        guard let image = browserViewModel.firstSelectedImage else {
            loadRequestID = nil
            controller.feedImage = nil
            controller.useEditPipeline = false
            controller.requestFeedRedraw()
            return
        }

        let url = image.url
        let settings = image.cameraRawSettings
        let exifOrientation = image.exifOrientation
        let maxPixelSize = Self.feedMaxPixelSize
        let isHDR = image.isNativeHDR || settings?.hdrEditMode == 1

        loadTask = Task {
            let snapshot = await CleanFeedBrowseRenderService.shared.render(
                CleanFeedBrowseRenderRequest(
                    requestID: requestID,
                    imageURL: url,
                    settings: settings,
                    displayOrientation: exifOrientation,
                    maxPixelSize: maxPixelSize
                )
            )

            guard !Task.isCancelled,
                  loadRequestID == requestID,
                  snapshot.requestID == requestID,
                  snapshot.imageURL == url,
                  snapshot.completion == .complete,
                  browserViewModel.firstSelectedImage?.url == url,
                  !controller.editModeActive else { return }
            controller.feedImage = snapshot.image
            // HDR when the file is natively HDR or the user enabled HDR edit mode —
            // matches FullScreenImageView's browse-mode rule.
            controller.isHDR = isHDR
            controller.useEditPipeline = false
            controller.requestFeedRedraw()
        }
    }

    private func cancelBrowseLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadRequestID = nil
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
    let isHDR: Bool
    let feedCrop: CleanFeedController.FeedCrop?
    let comparisonPresentation: CleanFeedComparisonPresentation?
    let comparisonLayout: ComparisonLayout

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
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityIdentifier("cleanFeed.preview")
        view.setAccessibilityLabel("Clean Feed image preview")
        view.setAccessibilityHelp("A chrome-free preview shown on the selected external display.")
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = MetalPreviewView.Coordinator.colorSpace
            // Configure EDR eagerly so the first draw can show HDR content on the feed.
            layer.wantsExtendedDynamicRangeContent = isHDR
            if #available(macOS 26.0, *) {
                layer.preferredDynamicRange = isHDR ? .high : .standard
            }
        }
        // Opaque when HDR — non-opaque layer compositing can clip EDR values to SDR.
        view.layer?.isOpaque = isHDR
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
        context.coordinator.feedCrop = feedCrop
        context.coordinator.comparisonPresentation = comparisonPresentation
        context.coordinator.comparisonLayout = comparisonLayout
        view.setAccessibilityLabel(
            comparisonPresentation == nil
                ? "Clean Feed image preview"
                : "Clean Feed comparison, \(comparisonLayout.accessibilityName)"
        )
        if let layer = view.layer as? CAMetalLayer {
            // wantsExtendedDynamicRangeContent is the fundamental CAMetalLayer EDR enabler;
            // preferredDynamicRange (macOS 26+) controls compositing but doesn't replace it.
            layer.wantsExtendedDynamicRangeContent = isHDR
            if #available(macOS 26.0, *) {
                layer.preferredDynamicRange = isHDR ? .high : .standard
            }
        }
        view.layer?.isOpaque = isHDR
        // SwiftUI/NSHostingView insert intermediate layers that clip EDR unless every
        // ancestor opts in — same walk the editor preview uses.
        MetalPreviewView.enableEDRAncestors(for: view, isHDR: isHDR)
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
        let feedPipeline: MetalLivePreviewPipeline?

        // Plain (non-isolated) copies set from `updateNSView` on the main thread.
        var feedImage: CIImage?
        var useEditPipeline: Bool = false
        var feedCrop: CleanFeedController.FeedCrop?
        var comparisonPresentation: CleanFeedComparisonPresentation?
        var comparisonLayout: ComparisonLayout = .sideBySide

        init(feedPipeline: MetalLivePreviewPipeline?) {
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

            // Comparison takes precedence over the browse/edit feed. The interactive workspace
            // owns focus, zoom, pan, replacement, and lock semantics; this passive surface uses
            // that exact snapshot with a separately chosen audience-display layout.
            if let comparisonPresentation {
                renderComparison(
                    comparisonPresentation,
                    layout: comparisonLayout,
                    in: view,
                    drawable: drawable,
                    drawableSize: drawableSize
                )
                return
            }

            // Live edit path: shared compute pipeline, aspect-fit for this display.
            if useEditPipeline,
               let pipeline = feedPipeline,
               pipeline.hasSourceTexture,
               let srcSize = pipeline.sourceTextureSize {
                if let crop = feedCrop, crop.isActive {
                    // Render only the confirmed crop region (with straighten), letterboxed.
                    pipeline.updateCropViewport(
                        containerSize: drawableSize,
                        imageSize: srcSize,
                        cropLeft: crop.left,
                        cropTop: crop.top,
                        cropRight: crop.right,
                        cropBottom: crop.bottom,
                        angleDegrees: crop.angle
                    )
                } else {
                    pipeline.updateViewport(
                        zoomScale: 1.0,
                        offset: .zero,
                        containerSize: drawableSize,
                        imageSize: srcSize
                    )
                }
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

        private func renderComparison(
            _ presentation: CleanFeedComparisonPresentation,
            layout: ComparisonLayout,
            in view: MTKView,
            drawable: CAMetalDrawable,
            drawableSize: CGSize
        ) {
            guard let commandBuffer = MetalPreviewView.Coordinator.commandQueue.makeCommandBuffer() else {
                return
            }
            let drawableRect = CGRect(origin: .zero, size: drawableSize)
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: drawableRect)
            var composite = black

            let paneRects = CleanFeedComparisonGeometry.paneRects(
                layout: layout,
                focusedPane: presentation.session.focusedPane,
                drawableSize: drawableSize
            )

            if layout == .wipe,
               let left = comparisonImage(
                    pane: .left,
                    paneRect: drawableRect,
                    presentation: presentation
               ),
               let right = comparisonImage(
                    pane: .right,
                    paneRect: drawableRect,
                    presentation: presentation
               ),
               let mask = wipeMaskImage(
                    size: drawableSize,
                    position: presentation.session.wipePosition,
                    angleDegrees: presentation.session.wipeAngleDegrees
               ) {
                let background = right.composited(over: black)
                composite = left.applyingFilter(
                    "CIBlendWithMask",
                    parameters: [
                        kCIInputBackgroundImageKey: background,
                        kCIInputMaskImageKey: mask
                    ]
                )
            } else {
                for (pane, paneRect) in paneRects {
                    guard let fitted = comparisonImage(
                        pane: pane,
                        paneRect: paneRect,
                        presentation: presentation
                    ) else { continue }
                    composite = fitted.composited(over: composite)
                }
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
                    toRender: composite,
                    from: drawableRect,
                    to: destination,
                    at: .zero
                )
            } catch {
                cleanFeedViewLog.error("Comparison render failed: \(error.localizedDescription, privacy: .private)")
                return
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func comparisonImage(
            pane: ComparisonPane,
            paneRect: CGRect,
            presentation: CleanFeedComparisonPresentation
        ) -> CIImage? {
            guard let image = presentation.images[pane],
                  presentation.session[pane].source != nil else { return nil }
            let viewport = presentation.session[pane].viewport
            guard let geometry = try? viewport.geometry(
                displayedPixelSize: CGSize(width: image.width, height: image.height),
                viewSize: paneRect.size,
                backingScale: 1
            ) else { return nil }

            let imageRect = geometry.imageRectInView.offsetBy(
                dx: paneRect.minX,
                dy: paneRect.minY
            )
            let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            return CIImage(cgImage: image)
                .cropped(to: extent)
                .transformed(by: CGAffineTransform(
                    translationX: -extent.minX,
                    y: -extent.minY
                ))
                .transformed(by: CGAffineTransform(
                    scaleX: imageRect.width / extent.width,
                    y: imageRect.height / extent.height
                ))
                .transformed(by: CGAffineTransform(
                    translationX: imageRect.minX,
                    y: imageRect.minY
                ))
                .cropped(to: paneRect)
        }

        private func wipeMaskImage(
            size: CGSize,
            position: CGFloat,
            angleDegrees: CGFloat
        ) -> CIImage? {
            let width = max(Int(size.width.rounded(.up)), 1)
            let height = max(Int(size.height.rounded(.up)), 1)
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }

            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let polygon = ComparisonWipeGeometry.maskPolygon(
                in: CGRect(x: 0, y: 0, width: width, height: height),
                position: position,
                angleDegrees: angleDegrees
            )
            guard let first = polygon.first else { return nil }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.beginPath()
            context.move(to: first)
            for point in polygon.dropFirst() { context.addLine(to: point) }
            context.closePath()
            context.setFillColor(gray: 1, alpha: 1)
            context.fillPath()
            guard let image = context.makeImage() else { return nil }
            return CIImage(cgImage: image)
        }

    }
}

private extension ComparisonLayout {
    var accessibilityName: String {
        switch self {
        case .sideBySide: "side by side"
        case .stacked: "stacked"
        case .wipe: "wipe"
        }
    }
}
