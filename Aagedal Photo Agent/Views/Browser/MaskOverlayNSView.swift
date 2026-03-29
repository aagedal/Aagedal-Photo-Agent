import AppKit
import simd
import SwiftUI

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

    private func ellipseTransform(radiusScale: CGFloat = 1) -> CGAffineTransform {
        CGAffineTransform(scaleX: maskGeometry.radiusX * radiusScale, y: maskGeometry.radiusY * radiusScale)
            .concatenating(CGAffineTransform(rotationAngle: angleRadians))
            .concatenating(CGAffineTransform(scaleX: uvToScreenScaleX, y: uvToScreenScaleY))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }

    private func handlePosition(uvDx: CGFloat, uvDy: CGFloat) -> CGPoint {
        let cosR = cos(angleRadians)
        let sinR = sin(angleRadians)
        let rotX = uvDx * cosR - uvDy * sinR
        let rotY = uvDx * sinR + uvDy * cosR
        return CGPoint(
            x: rotX * uvToScreenScaleX + center.x,
            y: rotY * uvToScreenScaleY + center.y
        )
    }

    private var topHandle: CGPoint { handlePosition(uvDx: 0, uvDy: -maskGeometry.radiusY) }
    private var rightHandle: CGPoint { handlePosition(uvDx: maskGeometry.radiusX, uvDy: 0) }
    private var bottomHandle: CGPoint { handlePosition(uvDx: 0, uvDy: maskGeometry.radiusY) }
    private var leftHandle: CGPoint { handlePosition(uvDx: -maskGeometry.radiusX, uvDy: 0) }

    private func isInRotationZone(_ point: CGPoint) -> Bool {
        let cosR = cos(angleRadians)
        let sinR = sin(angleRadians)
        let uvDx = (point.x - center.x) / uvToScreenScaleX
        let uvDy = (point.y - center.y) / uvToScreenScaleY
        let localX = uvDx * cosR + uvDy * sinR
        let localY = -uvDx * sinR + uvDy * cosR

        guard maskGeometry.radiusX > 0, maskGeometry.radiusY > 0 else { return false }
        let marginX = 20.0 / uvToScreenScaleX
        let marginY = 20.0 / uvToScreenScaleY
        let innerRx = maskGeometry.radiusX + marginX
        let innerRy = maskGeometry.radiusY + marginY
        let innerNorm = (localX * localX) / (innerRx * innerRx)
                      + (localY * localY) / (innerRy * innerRy)
        let extentX = 84.0 / uvToScreenScaleX
        let extentY = 84.0 / uvToScreenScaleY
        let outerRx = maskGeometry.radiusX + extentX
        let outerRy = maskGeometry.radiusY + extentY
        let outerNorm = (localX * localX) / (outerRx * outerRx)
                      + (localY * localY) / (outerRy * outerRy)
        return innerNorm > 1.0 && outerNorm <= 1.0
    }

    /// Ellipse distance in UV space — returns < 1 for inside, > 1 for outside.
    private func ellipseDistance(_ point: CGPoint) -> CGFloat {
        let cosR = cos(angleRadians)
        let sinR = sin(angleRadians)
        let uvDx = (point.x - center.x) / uvToScreenScaleX
        let uvDy = (point.y - center.y) / uvToScreenScaleY
        let localX = uvDx * cosR + uvDy * sinR
        let localY = -uvDx * sinR + uvDy * cosR
        guard maskGeometry.radiusX > 0, maskGeometry.radiusY > 0 else { return .greatestFiniteMagnitude }
        let nx = localX / maskGeometry.radiusX
        let ny = localY / maskGeometry.radiusY
        return sqrt(nx * nx + ny * ny)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard viewportSize.x > 0, viewportSize.y > 0 else { return }

        // Outer ellipse
        let unitCircle = CGPath(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2), transform: nil)
        let outerTransform = ellipseTransform()
        if let transformedPath = unitCircle.copy(using: [outerTransform]) {
            ctx.addPath(transformedPath)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }

        // Inner feather boundary (dashed)
        let featherNorm = maskGeometry.feather / 100.0
        if featherNorm > 0.01 {
            let innerScale = max(1.0 - featherNorm, 0.05)
            let innerTransform = ellipseTransform(radiusScale: innerScale)
            if let innerPath = unitCircle.copy(using: [innerTransform]) {
                ctx.addPath(innerPath)
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
                ctx.setLineWidth(0.5)
                ctx.setLineDash(phase: 0, lengths: [4, 4])
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }
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

        // Check inside ellipse (move)
        if ellipseDistance(local) <= 1.0 {
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

        // Determine drag type by priority: handles > move (inside ellipse) > rotate
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
            if newAngle < 0 { newAngle += 360 }

            var geo = startGeo
            geo.rotation = newAngle
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

        // Check inside ellipse (move)
        if ellipseDistance(point) <= 1.0 {
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
        var geo = startGeometry
        let cosR = cos(startGeometry.rotation * .pi / 180)
        let sinR = sin(startGeometry.rotation * .pi / 180)
        // Convert screen-space translation to UV delta via viewport
        let uvDx = translation.width / uvToScreenScaleX
        let uvDy = translation.height / uvToScreenScaleY

        let uniform = NSEvent.modifierFlags.contains(.shift)

        switch dragType {
        case .move:
            geo.centerX = startGeometry.centerX + uvDx
            geo.centerY = startGeometry.centerY + uvDy

        case .resizeTop:
            let proj = -uvDx * sinR + uvDy * cosR
            geo.radiusY = max(startGeometry.radiusY - proj, 0.01)
            if uniform { geo.radiusX = max(startGeometry.radiusX - proj, 0.01) }

        case .resizeBottom:
            let proj = -uvDx * sinR + uvDy * cosR
            geo.radiusY = max(startGeometry.radiusY + proj, 0.01)
            if uniform { geo.radiusX = max(startGeometry.radiusX + proj, 0.01) }

        case .resizeRight:
            let proj = uvDx * cosR + uvDy * sinR
            geo.radiusX = max(startGeometry.radiusX + proj, 0.01)
            if uniform { geo.radiusY = max(startGeometry.radiusY + proj, 0.01) }

        case .resizeLeft:
            let proj = uvDx * cosR + uvDy * sinR
            geo.radiusX = max(startGeometry.radiusX - proj, 0.01)
            if uniform { geo.radiusY = max(startGeometry.radiusY - proj, 0.01) }

        case .rotate, .none:
            break
        }

        return geo
    }
}
