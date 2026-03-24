import SwiftUI

struct EllipseMaskOverlayView: View {
    let imageRect: CGRect
    let viewSize: CGSize
    let geometry: EllipseMaskGeometry
    let inverted: Bool
    let useMetalOverlay: Bool
    let onStart: () -> Void
    let onChange: (EllipseMaskGeometry) -> Void
    let onCommit: () -> Void

    @State private var dragStartGeometry: EllipseMaskGeometry?
    @State private var dragType: DragType = .none
    @State private var isShowingRotateCursor = false

    private enum DragType {
        case none, move, rotate, resizeTop, resizeRight, resizeBottom, resizeLeft
    }

    // MARK: - Rotation cursor

    nonisolated(unsafe) private static let rotateCursor: NSCursor = {
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

    private var center: CGPoint {
        CGPoint(
            x: imageRect.minX + geometry.centerX * imageRect.width,
            y: imageRect.minY + geometry.centerY * imageRect.height
        )
    }

    private var angleRadians: CGFloat { geometry.rotation * .pi / 180 }

    private let handleSize: CGFloat = 10

    // MARK: - UV-space ellipse transform

    /// Builds a CGAffineTransform that maps a unit circle to the correctly rotated
    /// ellipse in view pixel coordinates. The rotation is applied in normalized UV
    /// space (matching the Metal shader) before scaling to pixel dimensions.
    private func ellipseTransform(radiusScale: CGFloat = 1) -> CGAffineTransform {
        CGAffineTransform(scaleX: geometry.radiusX * radiusScale, y: geometry.radiusY * radiusScale)
            .concatenating(CGAffineTransform(rotationAngle: angleRadians))
            .concatenating(CGAffineTransform(scaleX: imageRect.width, y: imageRect.height))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }

    /// Computes a handle position by rotating the offset in UV space, then scaling
    /// to pixels. uvDx/uvDy are in normalized image coordinates (e.g. radiusX, -radiusY).
    private func handlePosition(uvDx: CGFloat, uvDy: CGFloat) -> CGPoint {
        let cosR = cos(angleRadians)
        let sinR = sin(angleRadians)
        let rotX = uvDx * cosR - uvDy * sinR
        let rotY = uvDx * sinR + uvDy * cosR
        return CGPoint(
            x: rotX * imageRect.width + center.x,
            y: rotY * imageRect.height + center.y
        )
    }

    private var topHandle: CGPoint { handlePosition(uvDx: 0, uvDy: -geometry.radiusY) }
    private var rightHandle: CGPoint { handlePosition(uvDx: geometry.radiusX, uvDy: 0) }
    private var bottomHandle: CGPoint { handlePosition(uvDx: 0, uvDy: geometry.radiusY) }
    private var leftHandle: CGPoint { handlePosition(uvDx: -geometry.radiusX, uvDy: 0) }

    /// Whether a point is in the rotation zone: outside the ellipse but within a buffer distance.
    /// All math done in UV space to match the Metal shader.
    private func isInRotationZone(_ point: CGPoint) -> Bool {
        let cosR = cos(angleRadians)
        let sinR = sin(angleRadians)
        // Convert pixel offset to UV offset
        let uvDx = (point.x - center.x) / imageRect.width
        let uvDy = (point.y - center.y) / imageRect.height
        // Rotate into ellipse-local UV space
        let localX = uvDx * cosR + uvDy * sinR
        let localY = -uvDx * sinR + uvDy * cosR

        guard geometry.radiusX > 0, geometry.radiusY > 0 else { return false }
        // Inner margin (~20px) keeps rotation zone away from resize handles
        let marginX = 20.0 / imageRect.width
        let marginY = 20.0 / imageRect.height
        let innerRx = geometry.radiusX + marginX
        let innerRy = geometry.radiusY + marginY
        let innerNorm = (localX * localX) / (innerRx * innerRx)
                      + (localY * localY) / (innerRy * innerRy)
        // Outer extent (~84px from ellipse edge)
        let extentX = 84.0 / imageRect.width
        let extentY = 84.0 / imageRect.height
        let outerRx = geometry.radiusX + extentX
        let outerRy = geometry.radiusY + extentY
        let outerNorm = (localX * localX) / (outerRx * outerRx)
                      + (localY * localY) / (outerRy * outerRy)
        return innerNorm > 1.0 && outerNorm <= 1.0
    }

    var body: some View {
        Canvas { ctx, size in
            // Skip Canvas drawing when Metal overlay is rendering the shapes
            guard !useMetalOverlay else { return }

            // Unit circle transformed via UV-space rotation then pixel scaling
            let unitCircle = Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2))

            // Outer ellipse
            let outerTransform = ellipseTransform()
            let transformedEllipse = unitCircle.applying(outerTransform)
            ctx.stroke(transformedEllipse, with: .color(.white.opacity(0.8)), lineWidth: 1.5)

            // Inner feather boundary (dashed)
            let featherNorm = geometry.feather / 100.0
            if featherNorm > 0.01 {
                let innerScale = max(1.0 - featherNorm, 0.05)
                let innerTransform = ellipseTransform(radiusScale: innerScale)
                let transformedInner = unitCircle.applying(innerTransform)
                ctx.stroke(
                    transformedInner,
                    with: .color(.white.opacity(0.35)),
                    style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])
                )
            }

            // Center dot
            let centerDot = Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
            ctx.fill(centerDot, with: .color(.white))

            // Edge handles
            for pos in [topHandle, rightHandle, bottomHandle, leftHandle] {
                let handleRect = CGRect(
                    x: pos.x - handleSize / 2,
                    y: pos.y - handleSize / 2,
                    width: handleSize,
                    height: handleSize
                )
                let handlePath = Path(ellipseIn: handleRect)
                ctx.fill(handlePath, with: .color(.white))
                ctx.stroke(handlePath, with: .color(.black.opacity(0.3)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
        .frame(width: viewSize.width, height: viewSize.height)
        .overlay { gestureLayer }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let inZone = isInRotationZone(location)
                if inZone, !isShowingRotateCursor {
                    isShowingRotateCursor = true
                    Self.rotateCursor.push()
                } else if !inZone, isShowingRotateCursor {
                    isShowingRotateCursor = false
                    NSCursor.pop()
                }
            case .ended:
                if isShowingRotateCursor {
                    isShowingRotateCursor = false
                    NSCursor.pop()
                }
            }
        }
        .onDisappear {
            if isShowingRotateCursor {
                isShowingRotateCursor = false
                NSCursor.pop()
            }
        }
    }

    /// The UV-rotated ellipse path in view coordinates, used for move hit testing.
    private var ellipseHitPath: Path {
        let unitCircle = Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2))
        return unitCircle.applying(ellipseTransform())
    }

    private var gestureLayer: some View {
        ZStack {
            // Rotation gesture — full view, behind move area and handles
            Color.clear
                .contentShape(Rectangle())
                .gesture(makeRotationGesture())

            // Move gesture — UV-rotated ellipse matching the actual mask shape
            ellipseHitPath
                .fill(Color.white.opacity(0.001))
                .gesture(makeDragGesture(.move))

            // Edge handle hit areas (larger than visual)
            handleHitArea(at: topHandle, type: .resizeTop)
            handleHitArea(at: rightHandle, type: .resizeRight)
            handleHitArea(at: bottomHandle, type: .resizeBottom)
            handleHitArea(at: leftHandle, type: .resizeLeft)
        }
        .frame(width: viewSize.width, height: viewSize.height)
    }

    private func handleHitArea(at position: CGPoint, type: DragType) -> some View {
        Circle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 20, height: 20)
            .position(position)
            .gesture(makeDragGesture(type))
    }

    private func makeDragGesture(_ type: DragType) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartGeometry == nil {
                    dragStartGeometry = geometry
                    dragType = type
                    onStart()
                }
                guard let startGeo = dragStartGeometry else { return }
                handleDrag(startGeometry: startGeo, translation: value.translation)
            }
            .onEnded { _ in
                dragStartGeometry = nil
                dragType = .none
                onCommit()
            }
    }

    private func makeRotationGesture() -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartGeometry == nil {
                    dragStartGeometry = geometry
                    dragType = .rotate
                    onStart()
                }
                guard let startGeo = dragStartGeometry else { return }

                let startVector = CGPoint(
                    x: value.startLocation.x - center.x,
                    y: value.startLocation.y - center.y
                )
                let currentVector = CGPoint(
                    x: value.location.x - center.x,
                    y: value.location.y - center.y
                )
                let startRadians = atan2(startVector.y, startVector.x)
                let currentRadians = atan2(currentVector.y, currentVector.x)
                let deltaDegrees = (currentRadians - startRadians) * 180.0 / .pi

                var newAngle = startGeo.rotation + deltaDegrees
                // Normalize to 0-360
                newAngle = newAngle.truncatingRemainder(dividingBy: 360)
                if newAngle < 0 { newAngle += 360 }

                var geo = startGeo
                geo.rotation = newAngle
                onChange(geo)
            }
            .onEnded { _ in
                dragStartGeometry = nil
                dragType = .none
                onCommit()
            }
    }

    private func handleDrag(startGeometry: EllipseMaskGeometry, translation: CGSize) {
        var geo = startGeometry
        let cosR = cos(startGeometry.rotation * .pi / 180)
        let sinR = sin(startGeometry.rotation * .pi / 180)
        // Convert pixel drag to UV offset for projection onto rotated UV axes
        let uvDx = translation.width / imageRect.width
        let uvDy = translation.height / imageRect.height

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
            return
        }

        onChange(geo)
    }
}
