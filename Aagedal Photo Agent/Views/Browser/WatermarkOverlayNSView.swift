import AppKit
import simd
import SwiftUI

/// SwiftUI wrapper for the watermark position handle — the move-only sibling of
/// `MaskOverlayRepresentable`. A watermark has no shape to resize or rotate interactively
/// (size/margin are slider-driven in the control panel), so this only supports dragging the
/// center, clamped live to the margin-inset safe area so it can never be dropped closer to
/// any edge than the margin allows.
struct WatermarkOverlayRepresentable: NSViewRepresentable {
    let viewportOrigin: SIMD2<Float>
    let viewportSize: SIMD2<Float>
    let viewSize: CGSize
    let geometry: WatermarkGeometry   // display frame
    let assetAspect: Double           // decoded PNG aspect ratio (width/height); 1 if unknown
    let imageSize: CGSize             // display-frame image pixel dimensions
    let contentRect: CGRect?
    let onStart: () -> Void
    let onChange: (WatermarkGeometry) -> Void
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WatermarkOverlayNSView {
        let view = WatermarkOverlayNSView(coordinator: context.coordinator)
        context.coordinator.overlayView = view
        context.coordinator.onStart = onStart
        context.coordinator.onChange = onChange
        context.coordinator.onCommit = onCommit
        view.viewportOrigin = viewportOrigin
        view.viewportSize = viewportSize
        view.watermarkGeometry = geometry
        view.assetAspect = assetAspect
        view.imageSize = imageSize
        view.contentRect = contentRect
        return view
    }

    func updateNSView(_ nsView: WatermarkOverlayNSView, context: Context) {
        context.coordinator.onStart = onStart
        context.coordinator.onChange = onChange
        context.coordinator.onCommit = onCommit
        // Don't override geometry during drag — coordinator owns it (mirrors MaskOverlayNSView).
        if !context.coordinator.isDragging {
            nsView.viewportOrigin = viewportOrigin
            nsView.viewportSize = viewportSize
            nsView.watermarkGeometry = geometry
            nsView.assetAspect = assetAspect
            nsView.imageSize = imageSize
            nsView.contentRect = contentRect
            nsView.needsDisplay = true
        }
    }

    final class Coordinator {
        weak var overlayView: WatermarkOverlayNSView?
        var onStart: (() -> Void)?
        var onChange: ((WatermarkGeometry) -> Void)?
        var onCommit: (() -> Void)?

        var isDragging = false
        var dragStartGeometry: WatermarkGeometry?
        var mouseDownLocation: CGPoint = .zero
    }
}

/// Draws the watermark's rendered footprint, the margin-inset safe-area boundary it's
/// clamped to, and a draggable center handle. Hit-testing accepts the whole footprint
/// rectangle (not just the small center dot) since a large watermark should be easy to grab
/// anywhere on it.
final class WatermarkOverlayNSView: NSView {
    private weak var coordinator: WatermarkOverlayRepresentable.Coordinator?

    var viewportOrigin: SIMD2<Float> = .zero
    var viewportSize: SIMD2<Float> = SIMD2<Float>(1, 1)
    var watermarkGeometry: WatermarkGeometry = WatermarkGeometry()
    var assetAspect: Double = 1
    var imageSize: CGSize = .zero
    var contentRect: CGRect?

    private let handleHitRadius: CGFloat = 10

    init(coordinator: WatermarkOverlayRepresentable.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Viewport coordinate helpers (identical projection to MaskOverlayNSView)

    private var uvToScreenScaleX: CGFloat {
        if let contentRect {
            return contentRect.width
        }
        guard viewportSize.x > 0 else { return 0 }
        return bounds.width / CGFloat(viewportSize.x)
    }

    private var uvToScreenScaleY: CGFloat {
        if let contentRect {
            return contentRect.height
        }
        guard viewportSize.y > 0 else { return 0 }
        return bounds.height / CGFloat(viewportSize.y)
    }

    private func screenPoint(forUV uv: (x: Double, y: Double)) -> CGPoint {
        if let contentRect {
            return CGPoint(
                x: contentRect.minX + CGFloat(uv.x) * contentRect.width,
                y: contentRect.minY + CGFloat(uv.y) * contentRect.height
            )
        }
        return CGPoint(
            x: (CGFloat(uv.x) - CGFloat(viewportOrigin.x)) / CGFloat(viewportSize.x) * bounds.width,
            y: (CGFloat(uv.y) - CGFloat(viewportOrigin.y)) / CGFloat(viewportSize.y) * bounds.height
        )
    }

    private var center: CGPoint {
        screenPoint(forUV: (watermarkGeometry.centerX, watermarkGeometry.centerY))
    }

    /// The watermark's rendered half-extent in screen points — decoded the same way the CPU
    /// param upload and Metal shader do (`WatermarkGeometry.renderedHalfExtentUV`), then
    /// converted from UV to screen via the (possibly anisotropic) per-axis scale.
    private func screenHalfExtent(of geo: WatermarkGeometry) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGSize(width: 20, height: 20) }
        let half = geo.renderedHalfExtentUV(
            assetAspect: assetAspect, imageWidth: imageSize.width, imageHeight: imageSize.height
        )
        return CGSize(width: half.halfWidthUV * uvToScreenScaleX, height: half.halfHeightUV * uvToScreenScaleY)
    }

    /// The margin boundary (screen space) — where the watermark's own visible EDGE may not
    /// cross. This is what gets drawn as the dashed line: it's the margin inset directly from
    /// the image edges, independent of the watermark's own size — NOT `safeAreaRect` (which is
    /// where the CENTER may travel, sitting margin+half-extent inside the image and so reading,
    /// confusingly, as if it tracked the watermark's center rather than its border).
    private func marginBoundaryScreenRect(of geo: WatermarkGeometry) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let rect = geo.marginBoundaryRect(imageWidth: imageSize.width, imageHeight: imageSize.height)
        let topLeft = screenPoint(forUV: (rect.minX, rect.minY))
        let bottomRight = screenPoint(forUV: (rect.maxX, rect.maxY))
        return CGRect(
            x: min(topLeft.x, bottomRight.x), y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x), height: abs(bottomRight.y - topLeft.y)
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard viewportSize.x > 0, viewportSize.y > 0 else { return }

        let c = center
        let half = screenHalfExtent(of: watermarkGeometry)
        let footprint = CGRect(x: c.x - half.width, y: c.y - half.height, width: half.width * 2, height: half.height * 2)

        // Watermark footprint outline.
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.setLineWidth(1.5)
        ctx.stroke(footprint)

        // Margin boundary (dashed) — where the watermark's own edge may not cross.
        let marginBoundary = marginBoundaryScreenRect(of: watermarkGeometry)
        if marginBoundary.width > 0, marginBoundary.height > 0 {
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.9, blue: 0.2, alpha: 0.55))
            ctx.setLineWidth(0.75)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.stroke(marginBoundary)
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Center handle.
        let handleRect = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: handleRect)
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
        ctx.setLineWidth(0.5)
        ctx.strokeEllipse(in: handleRect)
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard viewportSize.x > 0, viewportSize.y > 0 else { return nil }

        let c = center
        let dx = local.x - c.x
        let dy = local.y - c.y
        if dx * dx + dy * dy <= handleHitRadius * handleHitRadius {
            return self
        }

        // Also accept anywhere inside the rendered footprint — easier to grab a large
        // watermark than to hit the small center dot precisely.
        let half = screenHalfExtent(of: watermarkGeometry)
        if abs(dx) <= half.width, abs(dy) <= half.height {
            return self
        }

        return nil
    }

    // MARK: - Mouse event handling

    override func mouseDown(with event: NSEvent) {
        guard let coordinator else { return }
        coordinator.mouseDownLocation = convert(event.locationInWindow, from: nil)
        coordinator.isDragging = true
        coordinator.dragStartGeometry = watermarkGeometry
        coordinator.onStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let coordinator, coordinator.isDragging,
              let startGeo = coordinator.dragStartGeometry else { return }
        let location = convert(event.locationInWindow, from: nil)
        let dx = location.x - coordinator.mouseDownLocation.x
        let dy = location.y - coordinator.mouseDownLocation.y

        var geo = startGeo
        geo.centerX = startGeo.centerX + Double(dx / uvToScreenScaleX)
        geo.centerY = startGeo.centerY + Double(dy / uvToScreenScaleY)
        // Clamp live, every drag tick, so the handle visually can never leave the
        // margin-inset safe area — not just on commit.
        if imageSize.width > 0, imageSize.height > 0 {
            geo = geo.clamped(assetAspect: assetAspect, imageWidth: imageSize.width, imageHeight: imageSize.height)
        }
        watermarkGeometry = geo
        needsDisplay = true
        coordinator.onChange?(geo)
    }

    override func mouseUp(with event: NSEvent) {
        guard let coordinator, coordinator.isDragging else { return }
        coordinator.isDragging = false
        coordinator.dragStartGeometry = nil
        coordinator.onCommit?()
    }
}
