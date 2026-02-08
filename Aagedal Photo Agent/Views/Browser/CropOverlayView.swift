import SwiftUI

struct CropOverlayView: View {
    let imageRect: CGRect
    let viewSize: CGSize
    let crop: NormalizedCropRegion
    let angle: Double
    let onChange: (NormalizedCropRegion) -> Void
    let onAngleChange: (Double) -> Void
    let onCommit: () -> Void

    @State private var interactionStartCrop: NormalizedCropRegion?
    @State private var interactionStartAngle: Double?
    @State private var interactionStartViewRect: CGRect?
    @State private var gestureImageRect: CGRect?

    private enum HandleKind: Hashable {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight

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
        crop.clamped()
    }

    /// Returns the locked image rect during resize, or the live image rect otherwise.
    private var activeImageRect: CGRect {
        gestureImageRect ?? imageRect
    }

    // MARK: - View-space computed properties

    /// The rotation angle in radians (image is rotated by -angle, so view rotation is -angle).
    private var viewRotationRadians: Double {
        -angle * Double.pi / 180.0
    }

    /// The straight crop rectangle in view coordinates.
    /// The image is displayed rotated by -angle degrees. We compute the crop's AABB center
    /// offset from the image center, rotate it by the image rotation, then compute actual
    /// crop dimensions via forward projection.
    private var viewCropRect: CGRect {
        let nc = normalizedCrop
        let ir = activeImageRect
        let A = viewRotationRadians
        let cosA = cos(A)
        let sinA = sin(A)

        // AABB center offset from image center in image-rect pixel units
        let imgCX = (nc.centerX - 0.5) * ir.width
        let imgCY = (nc.centerY - 0.5) * ir.height

        // Rotate center offset to view space
        let viewCX = imgCX * cosA - imgCY * sinA + ir.midX
        let viewCY = imgCX * sinA + imgCY * cosA + ir.midY

        // Compute actual crop dimensions from AABB via forward projection
        let aabbW = nc.width * ir.width
        let aabbH = nc.height * ir.height
        let (actualW, actualH) = forwardProjectDims(aabbW: aabbW, aabbH: aabbH)

        return CGRect(
            x: viewCX - actualW / 2,
            y: viewCY - actualH / 2,
            width: max(2, actualW),
            height: max(2, actualH)
        )
    }

    /// The 4 corners of the original (unrotated) image outline, rotated into view space.
    /// Used for the image boundary stroke.
    private var rotatedImageCorners: [CGPoint] {
        let ir = activeImageRect
        let A = viewRotationRadians
        let cosA = cos(A)
        let sinA = sin(A)
        let hw = ir.width * 0.5
        let hh = ir.height * 0.5
        let cx = ir.midX
        let cy = ir.midY

        let offsets: [(Double, Double)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        return offsets.map { (sx, sy) in
            let lx = sx * hw
            let ly = sy * hh
            return CGPoint(
                x: lx * cosA - ly * sinA + cx,
                y: lx * sinA + ly * cosA + cy
            )
        }
    }

    // MARK: - Forward / inverse projection helpers

    /// Forward project: AABB pixel dims -> actual (rotated) crop dims.
    /// Uses the crop angle (not the view rotation).
    private func forwardProjectDims(aabbW: Double, aabbH: Double) -> (w: Double, h: Double) {
        let radians = angle * Double.pi / 180.0
        guard abs(radians) > 0.000001 else { return (aabbW, aabbH) }
        let cosA = cos(radians)
        let sinA = sin(radians)
        let w = abs(aabbW * cosA + aabbH * sinA)
        let h = abs(-aabbW * sinA + aabbH * cosA)
        return (w, h)
    }

    /// Inverse project: actual crop dims -> AABB pixel dims.
    private func inverseProjectDims(actualW: Double, actualH: Double) -> (aabbW: Double, aabbH: Double) {
        let radians = angle * Double.pi / 180.0
        guard abs(radians) > 0.000001 else { return (actualW, actualH) }
        let cosA = cos(radians)
        let sinA = sin(radians)
        let aabbW = abs(actualW * cosA - actualH * sinA)
        let aabbH = abs(actualW * sinA + actualH * cosA)
        return (aabbW, aabbH)
    }

    // MARK: - Body

    var body: some View {
        let rect = viewCropRect
        let corners = rotatedImageCorners

        ZStack {
            // Dimming: entire view with straight crop cutout
            Path { path in
                path.addRect(CGRect(origin: .zero, size: viewSize))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

            // Image boundary stroke — subtle line showing rotated image edges
            Path { path in
                if let first = corners.first {
                    path.move(to: first)
                    for corner in corners.dropFirst() {
                        path.addLine(to: corner)
                    }
                    path.closeSubpath()
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 1)

            // Crop border — straight rectangle
            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Rule of thirds — straight lines
            ruleOfThirdsGrid(in: rect)

            // Move gesture area — straight rectangle
            Rectangle()
                .fill(.clear)
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .position(x: rect.midX, y: rect.midY)
                .gesture(moveGesture())

            // Resize handles
            ForEach(
                [
                    HandleKind.topLeft, HandleKind.top, HandleKind.topRight,
                    HandleKind.left, HandleKind.right,
                    HandleKind.bottomLeft, HandleKind.bottom, HandleKind.bottomRight,
                ],
                id: \.self
            ) { handle in
                cropHandle(for: handle, in: rect)
            }

            // Rotation handle
            rotationHandle(in: rect)
        }
    }

    // MARK: - Handles

    @ViewBuilder
    private func cropHandle(for kind: HandleKind, in rect: CGRect) -> some View {
        let point = handlePoint(for: kind, in: rect)
        if kind.isCorner {
            cornerBracket(for: kind, in: rect)
                .gesture(resizeGesture(for: kind))
        } else {
            edgeHandle(for: kind, at: point)
                .gesture(resizeGesture(for: kind))
        }
    }

    private func handlePoint(for kind: HandleKind, in rect: CGRect) -> CGPoint {
        let fx: Double
        switch kind.movesHorizontal {
        case -1: fx = rect.minX
        case 1: fx = rect.maxX
        default: fx = rect.midX
        }
        let fy: Double
        switch kind.movesVertical {
        case -1: fy = rect.minY
        case 1: fy = rect.maxY
        default: fy = rect.midY
        }
        return CGPoint(x: fx, y: fy)
    }

    @ViewBuilder
    private func cornerBracket(for kind: HandleKind, in rect: CGRect) -> some View {
        let armLength = min(16.0, min(rect.width, rect.height) * 0.15)
        let corner = handlePoint(for: kind, in: rect)
        let hDir = Double(kind.movesHorizontal)
        let vDir = Double(kind.movesVertical)

        // Arm endpoints extending inward from the corner
        let hPoint = CGPoint(x: corner.x - hDir * armLength, y: corner.y)
        let vPoint = CGPoint(x: corner.x, y: corner.y - vDir * armLength)

        ZStack {
            Path { path in
                path.move(to: hPoint)
                path.addLine(to: corner)
                path.addLine(to: vPoint)
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .square))

            // Invisible hit area
            Circle()
                .fill(Color.clear)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .position(corner)
        }
    }

    @ViewBuilder
    private func edgeHandle(for kind: HandleKind, at point: CGPoint) -> some View {
        let isVerticalEdge = kind == .left || kind == .right
        RoundedRectangle(cornerRadius: 2)
            .fill(.white)
            .frame(
                width: isVerticalEdge ? 6 : 10,
                height: isVerticalEdge ? 10 : 6
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.black.opacity(0.5), lineWidth: 0.5)
            )
            .position(point)
    }

    @ViewBuilder
    private func rotationHandle(in rect: CGRect) -> some View {
        let topCenter = CGPoint(x: rect.midX, y: rect.minY)
        let handlePoint = CGPoint(x: rect.midX, y: rect.minY - 26)
        let viewCenter = CGPoint(x: rect.midX, y: rect.midY)

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
            .gesture(rotationGesture(center: viewCenter))
    }

    @ViewBuilder
    private func ruleOfThirdsGrid(in rect: CGRect) -> some View {
        Path { path in
            // Vertical lines at 1/3 and 2/3
            let x1 = rect.minX + rect.width / 3
            let x2 = rect.minX + rect.width * 2 / 3
            path.move(to: CGPoint(x: x1, y: rect.minY))
            path.addLine(to: CGPoint(x: x1, y: rect.maxY))
            path.move(to: CGPoint(x: x2, y: rect.minY))
            path.addLine(to: CGPoint(x: x2, y: rect.maxY))
            // Horizontal lines at 1/3 and 2/3
            let y1 = rect.minY + rect.height / 3
            let y2 = rect.minY + rect.height * 2 / 3
            path.move(to: CGPoint(x: rect.minX, y: y1))
            path.addLine(to: CGPoint(x: rect.maxX, y: y1))
            path.move(to: CGPoint(x: rect.minX, y: y2))
            path.addLine(to: CGPoint(x: rect.maxX, y: y2))
        }
        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
    }

    // MARK: - Gestures

    private func moveGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let ir = activeImageRect
                guard ir.width > 0, ir.height > 0 else { return }
                let start = interactionStartCrop ?? normalizedCrop
                interactionStartCrop = start

                // View-space drag delta -> inverse rotate to image-space delta
                let viewDX = Double(value.translation.width)
                let viewDY = Double(value.translation.height)
                let A = viewRotationRadians
                let cosA = cos(A)
                let sinA = sin(A)
                let imgDX = viewDX * cosA + viewDY * sinA
                let imgDY = -viewDX * sinA + viewDY * cosA
                let dx = imgDX / ir.width
                let dy = imgDY / ir.height

                let ar = ir.width / ir.height
                // Inverted: crop center moves opposite to drag (image pans under stable crop)
                let newCX = start.centerX - dx
                let newCY = start.centerY - dy
                let halfW = start.width * 0.5
                let halfH = start.height * 0.5
                let moved = NormalizedCropRegion(
                    top: newCY - halfH,
                    left: newCX - halfW,
                    bottom: newCY + halfH,
                    right: newCX + halfW
                ).centerClampedForRotation(angleDegrees: angle, aspectRatio: ar)
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
                let ir = activeImageRect
                guard ir.width > 0, ir.height > 0 else { return }

                if interactionStartCrop == nil {
                    interactionStartCrop = normalizedCrop
                    // Lock image rect at gesture start to prevent re-centering during resize
                    gestureImageRect = imageRect
                    interactionStartViewRect = viewCropRect
                }

                guard let startViewRect = interactionStartViewRect else { return }

                let dvx = Double(value.translation.width)
                let dvy = Double(value.translation.height)
                let symmetric = NSEvent.modifierFlags.contains(.option)
                let mh = Double(kind.movesHorizontal)
                let mv = Double(kind.movesVertical)

                let newRect: CGRect

                if symmetric {
                    // Center-anchored: resize equally from center
                    let newHalfW = Swift.max(1, startViewRect.width / 2 + mh * dvx)
                    let newHalfH = Swift.max(1, startViewRect.height / 2 + mv * dvy)
                    newRect = CGRect(
                        x: startViewRect.midX - newHalfW,
                        y: startViewRect.midY - newHalfH,
                        width: newHalfW * 2,
                        height: newHalfH * 2
                    )
                } else {
                    // Opposite corner/edge anchored
                    var minX = startViewRect.minX
                    var minY = startViewRect.minY
                    var maxX = startViewRect.maxX
                    var maxY = startViewRect.maxY

                    if mh < 0 { minX += dvx }
                    else if mh > 0 { maxX += dvx }

                    if mv < 0 { minY += dvy }
                    else if mv > 0 { maxY += dvy }

                    // Ensure valid rect if user drags past opposite corner
                    if minX > maxX { swap(&minX, &maxX) }
                    if minY > maxY { swap(&minY, &maxY) }

                    newRect = CGRect(
                        x: minX,
                        y: minY,
                        width: Swift.max(2, maxX - minX),
                        height: Swift.max(2, maxY - minY)
                    )
                }

                // Convert view rect back to image-space AABB
                let A = viewRotationRadians
                let cosA = cos(A)
                let sinA = sin(A)

                // Inverse-rotate center from view space to image space
                let viewCenterOffX = newRect.midX - ir.midX
                let viewCenterOffY = newRect.midY - ir.midY
                let imgCenterOffX = viewCenterOffX * cosA + viewCenterOffY * sinA
                let imgCenterOffY = -viewCenterOffX * sinA + viewCenterOffY * cosA
                let newCX = imgCenterOffX / ir.width + 0.5
                let newCY = imgCenterOffY / ir.height + 0.5

                // Inverse project actual view dims to AABB dims
                let (aabbW, aabbH) = inverseProjectDims(actualW: newRect.width, actualH: newRect.height)
                let halfW = aabbW / ir.width / 2
                let halfH = aabbH / ir.height / 2

                let ar = ir.width / ir.height
                let result = NormalizedCropRegion(
                    top: newCY - halfH,
                    left: newCX - halfW,
                    bottom: newCY + halfH,
                    right: newCX + halfW
                )
                .clamped()
                .fittingRotated(angleDegrees: angle, aspectRatio: ar)

                onChange(result)
            }
            .onEnded { _ in
                interactionStartCrop = nil
                interactionStartViewRect = nil
                gestureImageRect = nil
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
}
