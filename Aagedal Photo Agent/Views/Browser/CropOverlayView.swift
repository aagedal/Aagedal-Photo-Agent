import SwiftUI

struct CropOverlayView: View {
    let imageRect: CGRect
    let crop: NormalizedCropRegion
    let angle: Double
    let onChange: (NormalizedCropRegion) -> Void
    let onAngleChange: (Double) -> Void
    let onCommit: () -> Void

    @State private var interactionStartCrop: NormalizedCropRegion?
    @State private var interactionStartAngle: Double?

    private enum HandleKind: Hashable {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight

        var localAnchor: CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: -0.5, y: -0.5)
            case .top: return CGPoint(x: 0, y: -0.5)
            case .topRight: return CGPoint(x: 0.5, y: -0.5)
            case .left: return CGPoint(x: -0.5, y: 0)
            case .right: return CGPoint(x: 0.5, y: 0)
            case .bottomLeft: return CGPoint(x: -0.5, y: 0.5)
            case .bottom: return CGPoint(x: 0, y: 0.5)
            case .bottomRight: return CGPoint(x: 0.5, y: 0.5)
            }
        }

        var movesHorizontal: Int {
            switch self {
            case .topLeft, .left, .bottomLeft: return -1
            case .topRight, .right, .bottomRight: return 1
            case .top, .bottom: return 0
            }
        }

        var movesVertical: Int {
            switch self {
            case .topLeft, .top, .topRight: return -1
            case .bottomLeft, .bottom, .bottomRight: return 1
            case .left, .right: return 0
            }
        }

        var isCorner: Bool { movesHorizontal != 0 && movesVertical != 0 }
    }

    private var normalizedCrop: NormalizedCropRegion {
        crop.clamped().fittingRotated(angleDegrees: angle)
    }

    private var cropRect: CGRect {
        rect(for: normalizedCrop)
    }

    private var cropCenter: CGPoint {
        CGPoint(x: cropRect.midX, y: cropRect.midY)
    }

    var body: some View {
        let rect = cropRect
        let center = cropCenter

        ZStack {
            Path { path in
                path.addRect(imageRect)
                path.addPath(rotatedRectPath(center: center, size: rect.size, angleDegrees: angle))
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .rotationEffect(.degrees(angle))
                .position(center)

            Rectangle()
                .fill(.clear)
                .frame(width: rect.width, height: rect.height)
                .rotationEffect(.degrees(angle))
                .contentShape(Rectangle())
                .position(center)
                .gesture(moveGesture())

            ForEach(
                [
                    HandleKind.topLeft, HandleKind.top, HandleKind.topRight,
                    HandleKind.left, HandleKind.right,
                    HandleKind.bottomLeft, HandleKind.bottom, HandleKind.bottomRight,
                ],
                id: \.self
            ) { handle in
                cropHandle(for: handle, in: rect, center: center)
            }

            rotationHandle(in: rect, center: center)
        }
    }

    @ViewBuilder
    private func cropHandle(for kind: HandleKind, in rect: CGRect, center: CGPoint) -> some View {
        let point = pointForAnchor(kind.localAnchor, in: rect, center: center, angleDegrees: angle)
        Group {
            if kind.isCorner {
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 12, height: 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.black.opacity(0.7), lineWidth: 1)
                    )
                    .rotationEffect(.degrees(angle))
            }
        }
        .position(point)
        .gesture(resizeGesture(for: kind))
    }

    @ViewBuilder
    private func rotationHandle(in rect: CGRect, center: CGPoint) -> some View {
        let topCenter = pointForAnchor(CGPoint(x: 0, y: -0.5), in: rect, center: center, angleDegrees: angle)
        let handlePoint = pointForAnchor(CGPoint(x: 0, y: -0.5), in: rect.insetBy(dx: 0, dy: -26), center: center, angleDegrees: angle)

        Path { path in
            path.move(to: topCenter)
            path.addLine(to: handlePoint)
        }
        .stroke(Color.white.opacity(0.9), lineWidth: 1)

        Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1))
            .position(handlePoint)
            .gesture(rotationGesture(center: center))
    }

    private func moveGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard imageRect.width > 0, imageRect.height > 0 else { return }
                let start = interactionStartCrop ?? normalizedCrop
                interactionStartCrop = start

                let dx = Double(value.translation.width / imageRect.width)
                let dy = Double(value.translation.height / imageRect.height)
                let moved = start.movedBy(dx: dx, dy: dy).fittingRotated(angleDegrees: angle)
                onChange(moved)
            }
            .onEnded { _ in
                interactionStartCrop = nil
                onCommit()
            }
    }

    private func resizeGesture(for kind: HandleKind) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard imageRect.width > 0, imageRect.height > 0 else { return }
                let start = interactionStartCrop ?? normalizedCrop
                interactionStartCrop = start

                let dx = Double(value.translation.width / imageRect.width)
                let dy = Double(value.translation.height / imageRect.height)
                let local = toLocalDelta(dx: dx, dy: dy, angleDegrees: angle)
                let symmetric = NSEvent.modifierFlags.contains(.option)

                let resized = resizedCrop(
                    from: start,
                    localDX: local.dx,
                    localDY: local.dy,
                    kind: kind,
                    symmetric: symmetric
                )
                .fittingRotated(angleDegrees: angle)

                onChange(resized)
            }
            .onEnded { _ in
                interactionStartCrop = nil
                onCommit()
            }
    }

    private func rotationGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let startAngle = interactionStartAngle ?? angle
                interactionStartAngle = startAngle

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
                let newAngle = min(max(startAngle + deltaDegrees, -45), 45)
                onAngleChange(newAngle)
            }
            .onEnded { _ in
                interactionStartAngle = nil
                onCommit()
            }
    }

    private func resizedCrop(
        from start: NormalizedCropRegion,
        localDX: Double,
        localDY: Double,
        kind: HandleKind,
        symmetric: Bool
    ) -> NormalizedCropRegion {
        var result = start

        if kind.movesHorizontal < 0 {
            result.left = start.left + localDX
            if symmetric { result.right = start.right - localDX }
        } else if kind.movesHorizontal > 0 {
            result.right = start.right + localDX
            if symmetric { result.left = start.left - localDX }
        }

        if kind.movesVertical < 0 {
            result.top = start.top + localDY
            if symmetric { result.bottom = start.bottom - localDY }
        } else if kind.movesVertical > 0 {
            result.bottom = start.bottom + localDY
            if symmetric { result.top = start.top - localDY }
        }

        return result.clamped()
    }

    private func toLocalDelta(dx: Double, dy: Double, angleDegrees: Double) -> (dx: Double, dy: Double) {
        let radians = angleDegrees * Double.pi / 180.0
        let cosA: Double = Foundation.cos(radians)
        let sinA: Double = Foundation.sin(radians)
        let localX = (dx * cosA) + (dy * sinA)
        let localY = (-dx * sinA) + (dy * cosA)
        return (dx: localX, dy: localY)
    }

    private func pointForAnchor(_ anchor: CGPoint, in rect: CGRect, center: CGPoint, angleDegrees: Double) -> CGPoint {
        let local = CGPoint(
            x: anchor.x * rect.width,
            y: anchor.y * rect.height
        )
        let radians = angleDegrees * Double.pi / 180.0
        let cosA: Double = Foundation.cos(radians)
        let sinA: Double = Foundation.sin(radians)
        let localX = Double(local.x)
        let localY = Double(local.y)
        let rotated = CGPoint(
            x: (localX * cosA) - (localY * sinA),
            y: (localX * sinA) + (localY * cosA)
        )
        return CGPoint(
            x: center.x + CGFloat(rotated.x),
            y: center.y + CGFloat(rotated.y)
        )
    }

    private func rotatedRectPath(center: CGPoint, size: CGSize, angleDegrees: Double) -> Path {
        let anchors = [
            CGPoint(x: -0.5, y: -0.5),
            CGPoint(x: 0.5, y: -0.5),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: -0.5, y: 0.5),
        ]
        let points = anchors.map { pointForAnchor($0, in: CGRect(origin: .zero, size: size), center: center, angleDegrees: angleDegrees) }
        var path = Path()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
        return path
    }

    private func rect(for crop: NormalizedCropRegion) -> CGRect {
        CGRect(
            x: imageRect.minX + (crop.left * imageRect.width),
            y: imageRect.minY + (crop.top * imageRect.height),
            width: max(2, (crop.right - crop.left) * imageRect.width),
            height: max(2, (crop.bottom - crop.top) * imageRect.height)
        )
    }
}
