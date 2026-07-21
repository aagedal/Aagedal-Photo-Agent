import AppKit
import simd
import SwiftUI

private struct SuppressesEditCursorOverlaysKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set while a temporary interaction, such as the Space hand tool, owns the pointer.
    /// Cursor-following edit overlays should hide themselves whenever this is true.
    var suppressesEditCursorOverlays: Bool {
        get { self[SuppressesEditCursorOverlaysKey.self] }
        set { self[SuppressesEditCursorOverlaysKey.self] = newValue }
    }
}

// MARK: - NSViewRepresentable wrapper

struct MaskOverlayRepresentable: NSViewRepresentable {
    let viewportOrigin: SIMD2<Float>
    let viewportSize: SIMD2<Float>
    let viewSize: CGSize
    let geometry: EllipseMaskGeometry
    let inverted: Bool
    let onStart: () -> Void
    let onChange: (EllipseMaskGeometry) -> Void
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MaskOverlayNSView {
        let view = MaskOverlayNSView(coordinator: context.coordinator)
        context.coordinator.overlayView = view
        context.coordinator.onStart = onStart
        context.coordinator.onChange = onChange
        context.coordinator.onCommit = onCommit
        view.viewportOrigin = viewportOrigin
        view.viewportSize = viewportSize
        view.maskGeometry = geometry
        return view
    }

    func updateNSView(_ nsView: MaskOverlayNSView, context: Context) {
        context.coordinator.onStart = onStart
        context.coordinator.onChange = onChange
        context.coordinator.onCommit = onCommit
        // Don't override geometry during drag — coordinator owns it
        if !context.coordinator.isDragging {
            nsView.viewportOrigin = viewportOrigin
            nsView.viewportSize = viewportSize
            nsView.maskGeometry = geometry
            nsView.needsDisplay = true
        }
    }

    // MARK: - Coordinator

    class Coordinator {
        weak var overlayView: MaskOverlayNSView?
        var onStart: (() -> Void)?
        var onChange: ((EllipseMaskGeometry) -> Void)?
        var onCommit: (() -> Void)?

        var isDragging = false
        var dragStartGeometry: EllipseMaskGeometry?
        var dragType: DragType = .none
        var mouseDownLocation: CGPoint = .zero
        // For rotation: store the start angle from atan2
        var rotationStartAngle: CGFloat = 0
        var isShowingRotateCursor = false
    }
}

// MARK: - Drag type

enum DragType {
    case none, move, rotate, resizeTop, resizeRight, resizeBottom, resizeLeft
}

// MARK: - Rotation cursor

nonisolated(unsafe) private let rotateCursor: NSCursor = {
    let size: CGFloat = 24
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let c = CGPoint(x: size / 2, y: size / 2)
        let r: CGFloat = 8

        let halfGap: CGFloat = .pi / 5
        let arcStart = CGFloat.pi / 2 + halfGap
        let arcEnd = CGFloat.pi / 2 - halfGap

        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
        ctx.setLineWidth(3.5)
        ctx.setLineCap(.round)
        ctx.addArc(center: c, radius: r, startAngle: arcStart, endAngle: arcEnd, clockwise: false)
        ctx.strokePath()

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.5)
        ctx.addArc(center: c, radius: r, startAngle: arcStart, endAngle: arcEnd, clockwise: false)
        ctx.strokePath()

        let al: CGFloat = 5.0
        let aw: CGFloat = 2.5
        func drawArrow(atAngle a: CGFloat, tangentX tx: CGFloat, tangentY ty: CGFloat) {
            let px = c.x + r * cos(a)
            let py = c.y + r * sin(a)
            let nx = cos(a), ny = sin(a)
            let tip = CGPoint(x: px + tx * al, y: py + ty * al)
            let w1 = CGPoint(x: px + nx * aw, y: py + ny * aw)
            let w2 = CGPoint(x: px - nx * aw, y: py - ny * aw)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.move(to: tip); ctx.addLine(to: w1); ctx.addLine(to: w2)
            ctx.closePath(); ctx.fillPath()
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.move(to: tip); ctx.addLine(to: w1); ctx.addLine(to: w2)
            ctx.closePath(); ctx.fillPath()
        }
        drawArrow(atAngle: arcStart, tangentX: sin(arcStart), tangentY: -cos(arcStart))
        drawArrow(atAngle: arcEnd, tangentX: -sin(arcEnd), tangentY: cos(arcEnd))

        return true
    }
    return NSCursor(image: img, hotSpot: NSPoint(x: size / 2, y: size / 2))
}()

// MARK: - MaskOverlayNSView

final class MaskOverlayNSView: NSView {
    private weak var coordinator: MaskOverlayRepresentable.Coordinator?

    var viewportOrigin: SIMD2<Float> = .zero
    var viewportSize: SIMD2<Float> = SIMD2<Float>(1, 1)
    var maskGeometry: EllipseMaskGeometry = EllipseMaskGeometry()

    private let handleSize: CGFloat = 10
    private let handleHitRadius: CGFloat = 10 // 20pt diameter hit area

    init(coordinator: MaskOverlayRepresentable.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Viewport coordinate helpers

    /// Scale factor from UV delta to screen pixels (X axis)
    private var uvToScreenScaleX: CGFloat {
        guard viewportSize.x > 0 else { return 0 }
        return bounds.width / CGFloat(viewportSize.x)
    }

    /// Scale factor from UV delta to screen pixels (Y axis)
    private var uvToScreenScaleY: CGFloat {
        guard viewportSize.y > 0 else { return 0 }
        return bounds.height / CGFloat(viewportSize.y)
    }

    private var center: CGPoint {
        let cx = (CGFloat(maskGeometry.centerX) - CGFloat(viewportOrigin.x)) / CGFloat(viewportSize.x) * bounds.width
        let cy = (CGFloat(maskGeometry.centerY) - CGFloat(viewportOrigin.y)) / CGFloat(viewportSize.y) * bounds.height
        return CGPoint(x: cx, y: cy)
    }

    private var angleRadians: CGFloat { maskGeometry.rotation * .pi / 180 }

    /// True semi-axes in screen points, decoded from the ACR oriented-corner box
    /// half-extents stored in the geometry (see EllipseMaskGeometry). The screen
    /// mapping is aspect-true, so the decode and all rotation happen directly in
    /// screen points — rotating in UV space before the anisotropic UV→screen
    /// scale would shear the ellipse by the image aspect ratio. Clamped so
    /// degenerate foreign values stay grabbable.
    private func trueScreenRadii(of geo: EllipseMaskGeometry) -> (x: CGFloat, y: CGFloat) {
        let theta = geo.rotation * .pi / 180
        let dx = geo.radiusX * uvToScreenScaleX
        let dy = geo.radiusY * uvToScreenScaleY
        let a = dx * cos(theta) + dy * sin(theta)
        let b = -dx * sin(theta) + dy * cos(theta)
        return (max(a, 2), max(b, 2))
    }

    /// Re-encode true screen-point semi-axes into the stored oriented-corner box
    /// half-extents (UV), using the rotation already set on `geo`.
    private func settingTrueScreenRadii(_ geo: EllipseMaskGeometry, x: CGFloat, y: CGFloat) -> EllipseMaskGeometry {
        var out = geo
        let theta = geo.rotation * .pi / 180
        out.radiusX = (x * cos(theta) - y * sin(theta)) / uvToScreenScaleX
        out.radiusY = (x * sin(theta) + y * cos(theta)) / uvToScreenScaleY
        return out
    }

    private var screenRadiusX: CGFloat { trueScreenRadii(of: maskGeometry).x }
    private var screenRadiusY: CGFloat { trueScreenRadii(of: maskGeometry).y }

    /// Editable analytic outline. Corner radius is normalized independently along both axes:
    /// 1 produces the exact ACR ellipse, 0 a rectangle, and intermediate values elliptical
    /// rounded corners. Scaling produces the feather guides around the same nominal shape.
    private func maskPath(radiusScale: CGFloat = 1) -> CGPath {
        let radiusX = screenRadiusX * radiusScale
        let radiusY = screenRadiusY * radiusScale
        let corner = CGFloat(maskGeometry.normalizedCornerRadius)
        let localPath = CGPath(
            roundedRect: CGRect(x: -radiusX, y: -radiusY,
                                width: radiusX * 2, height: radiusY * 2),
            cornerWidth: radiusX * corner,
            cornerHeight: radiusY * corner,
            transform: nil
        )
        let transform = CGAffineTransform(rotationAngle: angleRadians)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return localPath.copy(using: [transform]) ?? localPath
    }

    private func handlePosition(screenDx: CGFloat, screenDy: CGFloat) -> CGPoint {
        let cosR = cos(angleRadians)
        let sinR = sin(angleRadians)
        return CGPoint(
            x: screenDx * cosR - screenDy * sinR + center.x,
            y: screenDx * sinR + screenDy * cosR + center.y
        )
    }

    private var topHandle: CGPoint { handlePosition(screenDx: 0, screenDy: -screenRadiusY) }
    private var rightHandle: CGPoint { handlePosition(screenDx: screenRadiusX, screenDy: 0) }
    private var bottomHandle: CGPoint { handlePosition(screenDx: 0, screenDy: screenRadiusY) }
    private var leftHandle: CGPoint { handlePosition(screenDx: -screenRadiusX, screenDy: 0) }

    /// Point's offset from the mask center, unrotated into the analytic shape's local
    /// frame, in screen points.
    private func localScreenOffset(_ point: CGPoint) -> CGPoint {
        let cosR = cos(angleRadians)
        let sinR = sin(angleRadians)
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(x: dx * cosR + dy * sinR, y: -dx * sinR + dy * cosR)
    }

    private func isInRotationZone(_ point: CGPoint) -> Bool {
        guard screenRadiusX > 0, screenRadiusY > 0 else { return false }
        return shapeSignedDistance(point, expansion: 20) > 0
            && shapeSignedDistance(point, expansion: 84) <= 0
    }

    /// Rounded-box SDF in the normalized local frame, matching the edit shader. The zero
    /// contour is the visible mask edge; negative is inside and positive outside.
    private func shapeSignedDistance(_ point: CGPoint, expansion: CGFloat = 0) -> CGFloat {
        let radiusX = screenRadiusX + expansion
        let radiusY = screenRadiusY + expansion
        guard radiusX > 0, radiusY > 0 else { return .greatestFiniteMagnitude }
        let local = localScreenOffset(point)
        let corner = CGFloat(maskGeometry.normalizedCornerRadius)
        let qx = abs(local.x / radiusX) - (1 - corner)
        let qy = abs(local.y / radiusY) - (1 - corner)
        let outside = hypot(max(qx, 0), max(qy, 0))
        return outside + min(max(qx, qy), 0) - corner
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard viewportSize.x > 0, viewportSize.y > 0 else { return }

        // Editable nominal shape. With feathering this is the Gaussian's 10%-coverage contour,
        // not a finite cutoff; the tail continues outside it.
        ctx.addPath(maskPath())
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
        ctx.setLineWidth(1.5)
        ctx.strokePath()

        // Full-strength inner feather boundary (dashed).
        let featherNorm = maskGeometry.feather / 100.0
        if featherNorm > 0.01 {
            let innerScale = max(1.0 - featherNorm, 0.0)
            if innerScale > 0.05 {
                ctx.addPath(maskPath(radiusScale: innerScale))
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
                ctx.setLineWidth(0.5)
                ctx.setLineDash(phase: 0, lengths: [4, 4])
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }

            // A faint 1%-coverage guide communicates that the feather extends beyond the handles.
            let tailScale = innerScale + sqrt(2.0) * featherNorm
            ctx.addPath(maskPath(radiusScale: tailScale))
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.2))
            ctx.setLineWidth(0.5)
            ctx.setLineDash(phase: 0, lengths: [2, 4])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Center dot
        let c = center
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))

        // Edge handles
        for pos in [topHandle, rightHandle, bottomHandle, leftHandle] {
            let handleRect = CGRect(
                x: pos.x - handleSize / 2,
                y: pos.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillEllipse(in: handleRect)
            ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
            ctx.setLineWidth(0.5)
            ctx.strokeEllipse(in: handleRect)
        }

        // Rotation readout while rotating
        if coordinator?.isDragging == true, coordinator?.dragType == .rotate {
            let text = String(format: "%.1f°", maskGeometry.rotation) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            let padding = CGSize(width: 8, height: 4)
            let badgeRect = CGRect(
                x: c.x - textSize.width / 2 - padding.width,
                y: c.y + 16,
                width: textSize.width + padding.width * 2,
                height: textSize.height + padding.height * 2
            )
            let badge = CGPath(
                roundedRect: badgeRect,
                cornerWidth: 5, cornerHeight: 5,
                transform: nil
            )
            ctx.addPath(badge)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.65))
            ctx.fillPath()
            text.draw(
                at: CGPoint(x: badgeRect.minX + padding.width, y: badgeRect.minY + padding.height),
                withAttributes: attributes
            )
        }
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard viewportSize.x > 0, viewportSize.y > 0 else { return nil }

        // Check handle hit areas first
        for pos in [topHandle, rightHandle, bottomHandle, leftHandle] {
            let dx = local.x - pos.x
            let dy = local.y - pos.y
            if dx * dx + dy * dy <= handleHitRadius * handleHitRadius {
                return self
            }
        }

        // Check inside analytic shape (move)
        if shapeSignedDistance(local) <= 0 {
            return self
        }

        // Check rotation zone
        if isInRotationZone(local) {
            return self
        }

        return nil
    }

    // MARK: - Mouse tracking for rotation cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let coordinator else { return }
        let location = convert(event.locationInWindow, from: nil)
        let inZone = isInRotationZone(location)
        if inZone, !coordinator.isShowingRotateCursor {
            coordinator.isShowingRotateCursor = true
            rotateCursor.push()
        } else if !inZone, coordinator.isShowingRotateCursor {
            coordinator.isShowingRotateCursor = false
            NSCursor.pop()
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard let coordinator else { return }
        if coordinator.isShowingRotateCursor {
            coordinator.isShowingRotateCursor = false
            NSCursor.pop()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, let coordinator, coordinator.isShowingRotateCursor {
            coordinator.isShowingRotateCursor = false
            NSCursor.pop()
        }
    }

    // MARK: - Mouse event handling

    override func mouseDown(with event: NSEvent) {
        guard let coordinator else { return }
        let location = convert(event.locationInWindow, from: nil)
        coordinator.mouseDownLocation = location

        // Determine drag type by priority: handles > move (inside shape) > rotate
        let dragType = determineDragType(at: location)
        guard dragType != .none else {
            super.mouseDown(with: event)
            return
        }

        coordinator.isDragging = true
        coordinator.dragType = dragType
        coordinator.dragStartGeometry = maskGeometry

        if dragType == .rotate {
            // Store the initial atan2 angle for rotation
            let cx = center.x
            let cy = center.y
            coordinator.rotationStartAngle = atan2(location.y - cy, location.x - cx)
        }

        coordinator.onStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let coordinator, coordinator.isDragging,
              let startGeo = coordinator.dragStartGeometry else { return }
        let location = convert(event.locationInWindow, from: nil)

        if coordinator.dragType == .rotate {
            // Rotation: compute angle delta from start
            let cx = center.x
            let cy = center.y
            let currentAngle = atan2(location.y - cy, location.x - cx)
            let deltaDegrees = (currentAngle - coordinator.rotationStartAngle) * 180.0 / .pi

            var newAngle = startGeo.rotation + deltaDegrees
            newAngle = newAngle.truncatingRemainder(dividingBy: 360)
            if newAngle > 180 { newAngle -= 360 }
            if newAngle <= -180 { newAngle += 360 }

            // Canonicalize into ACR's (−45°, 45°] range, swapping the shape
            // axes per quarter turn — ACR's decoder renders nothing for angles
            // outside this range, and its own files always store the canonical
            // form. The displayed analytic shape is identical either way.
            var radii = trueScreenRadii(of: startGeo)
            let quarterTurns = (newAngle / 90).rounded()
            newAngle -= quarterTurns * 90
            if !Int(quarterTurns).isMultiple(of: 2) {
                radii = (x: radii.y, y: radii.x)
            }

            // Rotation keeps the true semi-axes fixed; the stored corner
            // half-extents change with the angle, so re-encode them.
            var geo = startGeo
            geo.rotation = newAngle
            geo = settingTrueScreenRadii(geo, x: radii.x, y: radii.y)
            maskGeometry = geo
            needsDisplay = true
            coordinator.onChange?(geo)
        } else {
            // Move/resize: compute cumulative translation
            let translation = CGSize(
                width: location.x - coordinator.mouseDownLocation.x,
                height: location.y - coordinator.mouseDownLocation.y
            )
            let newGeo = computeDrag(startGeometry: startGeo, translation: translation, dragType: coordinator.dragType)
            maskGeometry = newGeo
            needsDisplay = true
            coordinator.onChange?(newGeo)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let coordinator, coordinator.isDragging else { return }
        coordinator.isDragging = false
        coordinator.dragStartGeometry = nil
        coordinator.dragType = .none
        coordinator.onCommit?()
    }

    // MARK: - Drag type determination

    private func determineDragType(at point: CGPoint) -> DragType {
        // Check handles (highest priority)
        let handles: [(CGPoint, DragType)] = [
            (topHandle, .resizeTop),
            (rightHandle, .resizeRight),
            (bottomHandle, .resizeBottom),
            (leftHandle, .resizeLeft),
        ]
        for (pos, type) in handles {
            let dx = point.x - pos.x
            let dy = point.y - pos.y
            if dx * dx + dy * dy <= handleHitRadius * handleHitRadius {
                return type
            }
        }

        // Check inside analytic shape (move)
        if shapeSignedDistance(point) <= 0 {
            return .move
        }

        // Check rotation zone
        if isInRotationZone(point) {
            return .rotate
        }

        return .none
    }

    // MARK: - Drag computation

    private func computeDrag(startGeometry: EllipseMaskGeometry, translation: CGSize, dragType: DragType) -> EllipseMaskGeometry {
        let cosR = cos(startGeometry.rotation * .pi / 180)
        let sinR = sin(startGeometry.rotation * .pi / 180)
        // Resize projections happen in screen space (where the rotation is rigid)
        // on the DECODED true radii; the result re-encodes into the stored corner
        // half-extents. Shift-uniform applies the same screen delta to both axes
        // so a screen circle stays a circle.
        let projX = translation.width * cosR + translation.height * sinR
        let projY = -translation.width * sinR + translation.height * cosR
        let start = trueScreenRadii(of: startGeometry)

        let uniform = NSEvent.modifierFlags.contains(.shift)

        switch dragType {
        case .move:
            var geo = startGeometry
            geo.centerX = startGeometry.centerX + translation.width / uvToScreenScaleX
            geo.centerY = startGeometry.centerY + translation.height / uvToScreenScaleY
            return geo

        case .resizeTop:
            return settingTrueScreenRadii(
                startGeometry,
                x: uniform ? max(start.x - projY, 2) : start.x,
                y: max(start.y - projY, 2)
            )

        case .resizeBottom:
            return settingTrueScreenRadii(
                startGeometry,
                x: uniform ? max(start.x + projY, 2) : start.x,
                y: max(start.y + projY, 2)
            )

        case .resizeRight:
            return settingTrueScreenRadii(
                startGeometry,
                x: max(start.x + projX, 2),
                y: uniform ? max(start.y + projX, 2) : start.y
            )

        case .resizeLeft:
            return settingTrueScreenRadii(
                startGeometry,
                x: max(start.x - projX, 2),
                y: uniform ? max(start.y - projX, 2) : start.y
            )

        case .rotate, .none:
            return startGeometry
        }
    }
}

// MARK: - Brush paint overlay (Phase 4)

/// SwiftUI wrapper for the freeform brush-paint overlay — the sibling of
/// `MaskOverlayRepresentable`, but instead of dragging discrete ellipse handles it interprets a
/// continuous mouse drag as a paint gesture. It collects spacing-filtered dabs in the DISPLAY
/// frame, streams each incremental batch to `onStrokeChanged` for immediate GPU feedback while
/// the user drags, and hands the finished stroke to `onStrokeEnded` on mouse-up for a single
/// model commit (one undo entry per gesture, matching ellipse dragging).
struct BrushMaskOverlayRepresentable: NSViewRepresentable {
    @Environment(\.suppressesEditCursorOverlays) private var suppressesCursorOverlays

    let viewportOrigin: SIMD2<Float>
    let viewportSize: SIMD2<Float>
    let viewSize: CGSize
    let imageSize: CGSize          // display-frame image pixel dimensions
    let radius: Double             // brush radius as a fraction of the long edge (BrushStroke.radius)
    let hardness: Double           // 0-1 (dab CenterWeight)
    let flow: Double               // 0-1 (dab flow)
    let erase: Bool
    /// Called on mouse-down: ensure a target brush mask exists and its GPU alpha slice is
    /// allocated, returning the slice index to live-stamp into (nil aborts the gesture).
    let onStrokeBegan: () -> Int?
    /// Called per new dab batch during the drag: the incremental dabs (display frame) + the
    /// slice to stamp into.
    let onStrokeChanged: (BrushStroke, Int) -> Void
    /// Called on mouse-up with the whole gesture's dabs (display frame) for one model commit.
    let onStrokeEnded: (BrushStroke) -> Void
    /// Photoshop-style brush HUD adjustment. Horizontal drag changes size, vertical drag changes
    /// hardness; this updates transient brush settings only and does not paint.
    let onBrushSettingsChanged: (_ radius: Double, _ hardness: Double) -> Void

    func makeNSView(context: Context) -> BrushMaskOverlayNSView {
        let view = BrushMaskOverlayNSView(coordinator: context.coordinator)
        context.coordinator.view = view
        view.suppressesCursorOverlays = suppressesCursorOverlays
        return view
    }

    func updateNSView(_ nsView: BrushMaskOverlayNSView, context: Context) {
        context.coordinator.parent = self
        nsView.viewportOrigin = viewportOrigin
        nsView.viewportSize = viewportSize
        nsView.imageSize = imageSize
        nsView.radius = radius
        nsView.hardness = hardness
        nsView.flow = flow
        nsView.erase = erase
        nsView.suppressesCursorOverlays = suppressesCursorOverlays
        nsView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: BrushMaskOverlayRepresentable
        weak var view: BrushMaskOverlayNSView?
        init(parent: BrushMaskOverlayRepresentable) { self.parent = parent }
    }
}

/// Axis inference and projection for Photoshop-style Shift-drag brush strokes.
nonisolated enum BrushStrokeAxis: Equatable {
    case horizontal
    case vertical

    static func inferred(from start: CGPoint, to point: CGPoint) -> Self {
        abs(point.x - start.x) >= abs(point.y - start.y) ? .horizontal : .vertical
    }

    func constrain(_ point: CGPoint, from start: CGPoint) -> CGPoint {
        switch self {
        case .horizontal:
            CGPoint(x: point.x, y: start.y)
        case .vertical:
            CGPoint(x: start.x, y: point.y)
        }
    }
}

/// The paint-capture NSView. Captures every mouse event within the image area (unlike the
/// ellipse overlay, which only hit-tests near its handles) and draws a brush-size cursor ring.
final class BrushMaskOverlayNSView: NSView {
    private weak var coordinator: BrushMaskOverlayRepresentable.Coordinator?

    var viewportOrigin: SIMD2<Float> = .zero
    var viewportSize: SIMD2<Float> = SIMD2<Float>(1, 1)
    var imageSize: CGSize = .zero
    var radius: Double = 0.04
    var hardness: Double = 0.5
    var flow: Double = 1.0
    var erase: Bool = false
    var suppressesCursorOverlays = false {
        didSet {
            guard suppressesCursorOverlays != oldValue else { return }
            if suppressesCursorOverlays { cursorPoint = nil }
            needsDisplay = true
        }
    }

    // Active gesture state.
    private var isPainting = false
    private var isAdjustingBrush = false
    private var targetLayer = 0
    private var allDabs: [BrushDab] = []
    private var lastDabImagePx: CGPoint?
    private var cursorPoint: CGPoint?
    private var strokeStartPoint: CGPoint?
    private var strokeAxis: BrushStrokeAxis?
    private var isStrokeAxisConstrained = false
    private var adjustStartPoint: CGPoint = .zero
    private var adjustStartRadius: Double = 0.04
    private var adjustStartHardness: Double = 0.5
    private var adjustDelta: CGPoint = .zero
    private var isMouseCursorDetached = false

    init(coordinator: BrushMaskOverlayRepresentable.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if isMouseCursorDetached {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    override var isFlipped: Bool { true }        // top-left origin, y-down — matches UV space
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    // MARK: Coordinate mapping (identical projection to the ellipse overlay)

    private func uv(for point: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(
            x: CGFloat(viewportOrigin.x) + (point.x / bounds.width) * CGFloat(viewportSize.x),
            y: CGFloat(viewportOrigin.y) + (point.y / bounds.height) * CGFloat(viewportSize.y)
        )
    }
    private func imagePx(_ uvPoint: CGPoint) -> CGPoint {
        CGPoint(x: uvPoint.x * imageSize.width, y: uvPoint.y * imageSize.height)
    }
    /// Brush radius projected to screen points. The image is displayed at a uniform scale, so a
    /// single conversion factor (points per image pixel) covers both axes.
    private var screenRadius: CGFloat {
        guard imageSize.width > 0, viewportSize.x > 0, bounds.width > 0 else { return 12 }
        let longEdgePx = CGFloat(max(imageSize.width, imageSize.height))
        let ptsPerImagePx = bounds.width / (CGFloat(viewportSize.x) * imageSize.width)
        return max(2, CGFloat(radius) * longEdgePx * ptsPerImagePx)
    }
    /// Minimum cursor travel (image px) between dabs — ~10% of the brush diameter. Tight enough
    /// that overlapping soft dabs read as a continuous stroke (not a string of scalloped blobs),
    /// but coarse enough to avoid thousands of redundant stamps on a slow drag.
    private var dabSpacingPx: CGFloat {
        let longEdgePx = CGFloat(max(imageSize.width, imageSize.height))
        return max(1, 0.2 * CGFloat(radius) * longEdgePx)
    }

    private func makeDab(at uvPoint: CGPoint) -> BrushDab {
        BrushDab(x: Double(uvPoint.x), y: Double(uvPoint.y), flow: flow, hardness: hardness)
    }
    private func makeStroke(_ dabs: [BrushDab]) -> BrushStroke {
        BrushStroke(dabs: dabs, radius: radius, density: 1.0, erase: erase)
    }
    private func isBrushAdjustmentShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.contains(.option) && modifiers.contains(.control)
    }
    private func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
    private func detachMouseCursorForAdjustment() {
        guard !isMouseCursorDetached else { return }
        if CGAssociateMouseAndMouseCursorPosition(0) == .success {
            isMouseCursorDetached = true
        }
    }
    private func restoreMouseCursorIfNeeded() {
        guard isMouseCursorDetached else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        isMouseCursorDetached = false
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        cursorPoint = loc

        if isBrushAdjustmentShortcut(event) {
            isAdjustingBrush = true
            isPainting = false
            adjustStartPoint = loc
            adjustStartRadius = radius
            adjustStartHardness = hardness
            adjustDelta = .zero
            detachMouseCursorForAdjustment()
            needsDisplay = true
            return
        }

        guard let coordinator, imageSize.width > 0,
              let layer = coordinator.parent.onStrokeBegan() else { return }
        isPainting = true
        isStrokeAxisConstrained = event.modifierFlags.contains(.shift)
        strokeStartPoint = loc
        strokeAxis = nil
        targetLayer = layer
        allDabs.removeAll(keepingCapacity: true)
        let uvPoint = uv(for: loc)
        let dab = makeDab(at: uvPoint)
        allDabs.append(dab)
        lastDabImagePx = imagePx(uvPoint)
        coordinator.parent.onStrokeChanged(makeStroke([dab]), targetLayer)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if isAdjustingBrush, let coordinator {
            cursorPoint = adjustStartPoint
            adjustDelta.x += event.deltaX
            adjustDelta.y += event.deltaY
            let newRadius = clamped(adjustStartRadius * pow(2.0, Double(adjustDelta.x) / 180.0), to: 0.005...0.20)
            let newHardness = clamped(adjustStartHardness - Double(adjustDelta.y) / 300.0, to: 0...1)
            radius = newRadius
            hardness = newHardness
            coordinator.parent.onBrushSettingsChanged(newRadius, newHardness)
            needsDisplay = true
            return
        }

        guard isPainting, let coordinator else { return }
        var loc = convert(event.locationInWindow, from: nil)
        if isStrokeAxisConstrained, let start = strokeStartPoint {
            if strokeAxis == nil {
                // The first drag event chooses the axis; it remains fixed for this stroke.
                strokeAxis = BrushStrokeAxis.inferred(from: start, to: loc)
            }
            loc = strokeAxis?.constrain(loc, from: start) ?? loc
        }
        cursorPoint = loc
        let uvPoint = uv(for: loc)
        let px = imagePx(uvPoint)
        defer { needsDisplay = true }
        guard let last = lastDabImagePx else { return }
        let travel = hypot(px.x - last.x, px.y - last.y)
        guard travel >= dabSpacingPx else { return }
        // Interpolate intermediate dabs so a fast drag lays down a continuous line, not gaps.
        // `ceil` keeps every inter-dab step at or below the target spacing (no residual gap).
        let steps = max(1, Int((travel / dabSpacingPx).rounded(.up)))
        let startUV = allDabs.last.map { CGPoint(x: $0.x, y: $0.y) } ?? uvPoint
        var newDabs: [BrushDab] = []
        for s in 1...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let interp = CGPoint(x: startUV.x + (uvPoint.x - startUV.x) * t,
                                 y: startUV.y + (uvPoint.y - startUV.y) * t)
            newDabs.append(makeDab(at: interp))
        }
        allDabs.append(contentsOf: newDabs)
        lastDabImagePx = px
        coordinator.parent.onStrokeChanged(makeStroke(newDabs), targetLayer)
    }

    override func mouseUp(with event: NSEvent) {
        if isAdjustingBrush {
            isAdjustingBrush = false
            adjustDelta = .zero
            restoreMouseCursorIfNeeded()
            needsDisplay = true
            return
        }

        guard isPainting, let coordinator else { return }
        isPainting = false
        let stroke = makeStroke(allDabs)
        allDabs.removeAll(keepingCapacity: true)
        lastDabImagePx = nil
        strokeStartPoint = nil
        strokeAxis = nil
        isStrokeAxisConstrained = false
        needsDisplay = true
        guard !stroke.dabs.isEmpty else { return }
        coordinator.parent.onStrokeEnded(stroke)
    }

    override func rightMouseDown(with event: NSEvent) {
        if isBrushAdjustmentShortcut(event) {
            mouseDown(with: event)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if isAdjustingBrush {
            mouseDragged(with: event)
        } else {
            super.rightMouseDragged(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if isAdjustingBrush {
            mouseUp(with: event)
        } else {
            super.rightMouseUp(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !suppressesCursorOverlays else { return }
        cursorPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        cursorPoint = nil
        needsDisplay = true
    }

    // MARK: Cursor

    override func draw(_ dirtyRect: NSRect) {
        guard !suppressesCursorOverlays, let point = cursorPoint else { return }
        let r = screenRadius
        let accentColor = erase ? NSColor.systemRed : NSColor.white

        func strokeRing(radius: CGFloat, lightWidth: CGFloat, darkWidth: CGFloat, alpha: CGFloat, dashed: Bool = false) {
            guard radius > 0 else { return }
            let rect = NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            let shadow = NSBezierPath(ovalIn: rect)
            shadow.lineWidth = darkWidth
            if dashed {
                var dash: [CGFloat] = [5, 4]
                shadow.setLineDash(&dash, count: dash.count, phase: 0)
            }
            NSColor.black.withAlphaComponent(0.55 * alpha).setStroke()
            shadow.stroke()

            let highlight = NSBezierPath(ovalIn: rect)
            highlight.lineWidth = lightWidth
            if dashed {
                var dash: [CGFloat] = [5, 4]
                highlight.setLineDash(&dash, count: dash.count, phase: 0)
            }
            accentColor.withAlphaComponent(alpha).setStroke()
            highlight.stroke()
        }

        strokeRing(radius: r, lightWidth: 1.0, darkWidth: 2.5, alpha: 1.0)

        // The solid ring remains the nominal 50%-coverage contour. Dashed rings show the
        // full-strength inner region and the Gaussian tail's 10%-coverage contour; the actual
        // raster tail continues beyond the latter until it is visually negligible.
        let innerRadius = CGFloat(BrushDabProfile.innerRadius(
            nominalRadius: Double(r), hardness: hardness
        ))
        let outerRadius = CGFloat(BrushDabProfile.tenPercentRadius(
            nominalRadius: Double(r), hardness: hardness
        ))
        if innerRadius > 2, innerRadius < r - 1 {
            strokeRing(radius: innerRadius, lightWidth: 0.75, darkWidth: 2.0, alpha: 0.65, dashed: true)
        }
        if outerRadius > r + 1 {
            strokeRing(radius: outerRadius, lightWidth: 0.75, darkWidth: 2.0, alpha: 0.65, dashed: true)
        }
    }
}
