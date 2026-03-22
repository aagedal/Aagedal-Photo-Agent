import SwiftUI

struct EllipseMaskOverlayView: View {
    let imageRect: CGRect
    let viewSize: CGSize
    let geometry: EllipseMaskGeometry
    let inverted: Bool
    let onChange: (EllipseMaskGeometry) -> Void
    let onCommit: () -> Void

    @State private var dragStartGeometry: EllipseMaskGeometry?
    @State private var dragType: DragType = .none

    private enum DragType {
        case none, move, resizeTop, resizeRight, resizeBottom, resizeLeft
    }

    private var center: CGPoint {
        CGPoint(
            x: imageRect.minX + geometry.centerX * imageRect.width,
            y: imageRect.minY + geometry.centerY * imageRect.height
        )
    }

    private var rx: CGFloat { geometry.radiusX * imageRect.width }
    private var ry: CGFloat { geometry.radiusY * imageRect.height }
    private var rotationAngle: Angle { .degrees(geometry.rotation) }

    private func handlePosition(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        let cosR = cos(geometry.rotation * .pi / 180)
        let sinR = sin(geometry.rotation * .pi / 180)
        let px = dx * cosR - dy * sinR + center.x
        let py = dx * sinR + dy * cosR + center.y
        return CGPoint(x: px, y: py)
    }

    private var topHandle: CGPoint { handlePosition(0, -ry) }
    private var rightHandle: CGPoint { handlePosition(rx, 0) }
    private var bottomHandle: CGPoint { handlePosition(0, ry) }
    private var leftHandle: CGPoint { handlePosition(-rx, 0) }

    private let handleSize: CGFloat = 10

    var body: some View {
        Canvas { ctx, size in
            // Outer ellipse
            let ellipsePath = Path(ellipseIn: CGRect(
                x: -rx, y: -ry, width: rx * 2, height: ry * 2
            ))
            var transform = CGAffineTransform.identity
                .translatedBy(x: center.x, y: center.y)
                .rotated(by: geometry.rotation * .pi / 180)
            let transformedEllipse = ellipsePath.applying(transform)
            ctx.stroke(transformedEllipse, with: .color(.white.opacity(0.8)), lineWidth: 1.5)

            // Inner feather boundary (dashed)
            let featherNorm = geometry.feather / 100.0
            if featherNorm > 0.01 {
                let innerScale = max(1.0 - featherNorm, 0.05)
                let innerPath = Path(ellipseIn: CGRect(
                    x: -rx * innerScale, y: -ry * innerScale,
                    width: rx * 2 * innerScale, height: ry * 2 * innerScale
                ))
                let transformedInner = innerPath.applying(transform)
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
        .overlay {
            // Invisible gesture layer
            gestureLayer
        }
    }

    private var gestureLayer: some View {
        ZStack {
            // Move gesture on the ellipse area
            Ellipse()
                .fill(Color.white.opacity(0.001))
                .frame(width: rx * 2, height: ry * 2)
                .rotationEffect(rotationAngle)
                .position(center)
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

    private func handleDrag(startGeometry: EllipseMaskGeometry, translation: CGSize) {
        var geo = startGeometry
        let cosR = cos(startGeometry.rotation * .pi / 180)
        let sinR = sin(startGeometry.rotation * .pi / 180)

        switch dragType {
        case .move:
            let dx = translation.width / imageRect.width
            let dy = translation.height / imageRect.height
            geo.centerX = startGeometry.centerX + dx
            geo.centerY = startGeometry.centerY + dy

        case .resizeTop:
            let proj = -translation.width * sinR + translation.height * cosR
            let deltaR = -proj / imageRect.height
            geo.radiusY = max(startGeometry.radiusY + deltaR, 0.01)

        case .resizeBottom:
            let proj = -translation.width * sinR + translation.height * cosR
            let deltaR = proj / imageRect.height
            geo.radiusY = max(startGeometry.radiusY + deltaR, 0.01)

        case .resizeRight:
            let proj = translation.width * cosR + translation.height * sinR
            let deltaR = proj / imageRect.width
            geo.radiusX = max(startGeometry.radiusX + deltaR, 0.01)

        case .resizeLeft:
            let proj = translation.width * cosR + translation.height * sinR
            let deltaR = -proj / imageRect.width
            geo.radiusX = max(startGeometry.radiusX + deltaR, 0.01)

        case .none:
            return
        }

        onChange(geo)
    }
}
