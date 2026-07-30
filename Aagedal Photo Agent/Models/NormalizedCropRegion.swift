import Foundation

enum CropAspectRatio: String, CaseIterable, Identifiable {
    case free
    case original
    case square
    case ratio4x3
    case ratio3x2
    case ratio16x9
    case ratio5x7
    case ratio3x4
    case ratio2x3
    case ratio9x16
    case ratio7x5

    var id: String { rawValue }

    /// Menu presentation keeps the two adaptive modes first, followed by every fixed ratio
    /// from widest landscape to tallest portrait. Deriving the order from `value` prevents a
    /// newly-added ratio from silently landing in the wrong part of the menu.
    static var menuOrder: [CropAspectRatio] {
        [.free, .original] + allCases
            .filter { $0.value != nil }
            .sorted { ($0.value ?? 0) > ($1.value ?? 0) }
    }

    /// Width/height ratio, nil for free/original (original handled externally)
    var value: Double? {
        switch self {
        case .free, .original: return nil
        case .square: return 1.0
        case .ratio4x3: return 4.0 / 3.0
        case .ratio3x2: return 3.0 / 2.0
        case .ratio16x9: return 16.0 / 9.0
        case .ratio5x7: return 5.0 / 7.0
        case .ratio3x4: return 3.0 / 4.0
        case .ratio2x3: return 2.0 / 3.0
        case .ratio9x16: return 9.0 / 16.0
        case .ratio7x5: return 7.0 / 5.0
        }
    }

    var label: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "1:1"
        case .ratio4x3: return "4:3"
        case .ratio3x2: return "3:2"
        case .ratio16x9: return "16:9"
        case .ratio5x7: return "5:7"
        case .ratio3x4: return "3:4"
        case .ratio2x3: return "2:3"
        case .ratio9x16: return "9:16"
        case .ratio7x5: return "7:5"
        }
    }
}

struct NormalizedCropRegion: Equatable {
    var top: Double
    var left: Double
    var bottom: Double
    var right: Double

    static let full = NormalizedCropRegion(top: 0, left: 0, bottom: 1, right: 1)

    var width: Double { right - left }
    var height: Double { bottom - top }
    var centerX: Double { (left + right) * 0.5 }
    var centerY: Double { (top + bottom) * 0.5 }

    func clamped(minSize: Double = 0.03) -> NormalizedCropRegion {
        var result = self
        result.left = min(max(result.left, 0), 1 - minSize)
        result.top = min(max(result.top, 0), 1 - minSize)
        result.right = max(result.right, result.left + minSize)
        result.bottom = max(result.bottom, result.top + minSize)
        result.right = min(result.right, 1)
        result.bottom = min(result.bottom, 1)
        result.left = min(result.left, result.right - minSize)
        result.top = min(result.top, result.bottom - minSize)
        return result
    }

    func movedBy(dx: Double, dy: Double) -> NormalizedCropRegion {
        let width = self.width
        let height = self.height
        var left = self.left + dx
        var top = self.top + dy
        left = min(max(left, 0), 1 - width)
        top = min(max(top, 0), 1 - height)
        return NormalizedCropRegion(
            top: top,
            left: left,
            bottom: top + height,
            right: left + width
        ).clamped()
    }

    /// Constrains the crop so all 4 corners of the rotated rectangle stay within the image,
    /// shrinking it uniformly (preserving aspect ratio) if needed.
    ///
    /// The region stores the *upright* crop rectangle directly (its `width`/`height` are the
    /// actual on-screen crop dimensions in normalized image units). When the crop is
    /// straightened by `angleDegrees`, its footprint in image space is this rectangle rotated
    /// by `+angle`. `aspectRatio` is imageWidth / imageHeight.
    func fittingRotated(angleDegrees: Double, aspectRatio: Double) -> NormalizedCropRegion {
        let radians = angleDegrees * Double.pi / 180.0
        if abs(radians) < 0.000001 {
            return clamped()
        }

        let cx = centerX
        let cy = centerY
        let halfW = width * 0.5
        let halfH = height * 0.5
        let cosA: Double = Foundation.cos(radians)
        let sinA: Double = Foundation.sin(radians)
        let ar = Swift.max(aspectRatio, 0.001)

        // Crop half-extents in pixel-proportional units (relative to image height), measured
        // along the crop's own (view) axes.
        let px = halfW * ar
        let py = halfH

        // Check all 4 rotated corners stay within [0,1]² normalized bounds. Each corner offset
        // (±px, ±py) is rotated by +angle into image space, then converted back to normalized.
        let signs: [(Double, Double)] = [(-1, -1), (1, -1), (-1, 1), (1, 1)]
        var maxScale = 1.0

        for (sx, sy) in signs {
            let ox = sx * px * cosA - sy * py * sinA
            let oy = sx * px * sinA + sy * py * cosA
            // Convert back to normalized space
            let nx = ox / ar
            let ny = oy

            if nx > 0 { maxScale = Swift.min(maxScale, (1 - cx) / nx) }
            if nx < 0 { maxScale = Swift.min(maxScale, cx / (-nx)) }
            if ny > 0 { maxScale = Swift.min(maxScale, (1 - cy) / ny) }
            if ny < 0 { maxScale = Swift.min(maxScale, cy / (-ny)) }
        }

        maxScale = Swift.min(maxScale, 1.0)
        if maxScale < 0 { maxScale = 0 }
        if maxScale >= 1.0 - 0.0001 { return self }

        // Scale both crop dimensions uniformly — aspect ratio is preserved exactly.
        let newHalfW = halfW * maxScale
        let newHalfH = halfH * maxScale

        return NormalizedCropRegion(
            top: cy - newHalfH,
            left: cx - newHalfW,
            bottom: cy + newHalfH,
            right: cx + newHalfW
        )
    }

    /// Adjusts center position so all rotated corners stay within [0,1]² bounds,
    /// without changing the crop dimensions. Use instead of `fittingRotated` when
    /// only the position should change (e.g., during movement).
    func centerClampedForRotation(angleDegrees: Double, aspectRatio: Double) -> NormalizedCropRegion {
        let halfW = Swift.max(width * 0.5, 0.0001)
        let halfH = Swift.max(height * 0.5, 0.0001)
        let radians = angleDegrees * Double.pi / 180.0

        if abs(radians) < 0.000001 {
            // No rotation — clamp center to keep AABB within [0,1]
            let newCX = Swift.min(Swift.max(centerX, halfW), 1 - halfW)
            let newCY = Swift.min(Swift.max(centerY, halfH), 1 - halfH)
            return NormalizedCropRegion(
                top: newCY - halfH,
                left: newCX - halfW,
                bottom: newCY + halfH,
                right: newCX + halfW
            )
        }

        let cx = centerX
        let cy = centerY
        let cosA: Double = Foundation.cos(radians)
        let sinA: Double = Foundation.sin(radians)
        let ar = Swift.max(aspectRatio, 0.001)

        // Crop half-extents in pixel-proportional units, along the crop's own (view) axes.
        let px = halfW * ar
        let py = halfH

        // Compute center bounds from rotated corner constraints
        var minCX = 0.0, maxCX = 1.0
        var minCY = 0.0, maxCY = 1.0
        let signs: [(Double, Double)] = [(-1, -1), (1, -1), (-1, 1), (1, 1)]

        for (sx, sy) in signs {
            let ox = sx * px * cosA - sy * py * sinA
            let oy = sx * px * sinA + sy * py * cosA
            let nx = ox / ar
            let ny = oy

            if nx > 0 { maxCX = Swift.min(maxCX, 1 - nx) }
            else if nx < 0 { minCX = Swift.max(minCX, -nx) }
            if ny > 0 { maxCY = Swift.min(maxCY, 1 - ny) }
            else if ny < 0 { minCY = Swift.max(minCY, -ny) }
        }

        let newCX: Double
        if minCX > maxCX {
            newCX = (minCX + maxCX) / 2
        } else {
            newCX = Swift.min(Swift.max(cx, minCX), maxCX)
        }

        let newCY: Double
        if minCY > maxCY {
            newCY = (minCY + maxCY) / 2
        } else {
            newCY = Swift.min(Swift.max(cy, minCY), maxCY)
        }

        return NormalizedCropRegion(
            top: newCY - halfH,
            left: newCX - halfW,
            bottom: newCY + halfH,
            right: newCX + halfW
        )
    }

    /// Resizes the crop so the visible (upright) crop rectangle has the target pixel aspect
    /// ratio, while preserving the crop area.
    /// `targetRatio` is the desired width/height of the visible crop rectangle.
    /// `imageAspectRatio` is imageWidth / imageHeight.
    ///
    /// Because the region stores the upright crop directly, the visible aspect ratio is simply
    /// `(width · imageAspectRatio) / height` regardless of the straighten angle — so this is
    /// angle-independent. `angleDegrees` is accepted for call-site symmetry but unused.
    func resizedToActualAspectRatio(_ targetRatio: Double, angleDegrees: Double = 0, imageAspectRatio: Double) -> NormalizedCropRegion {
        guard targetRatio > 0, imageAspectRatio > 0 else { return self }
        // Visible ratio = (width·ar)/height = targetRatio  ⇒  normalized width/height = targetRatio/ar
        return resizedToAspectRatio(targetRatio / imageAspectRatio)
    }

    /// Resizes the crop to match a target aspect ratio while preserving the crop area.
    /// Unlike `constrainedToAspectRatio` (which only shrinks), this can grow one dimension
    /// to maintain constant area — preventing progressive shrinking when switching ratios.
    /// `targetRatio` is desired cropWidth/cropHeight in normalized coords.
    func resizedToAspectRatio(_ targetRatio: Double) -> NormalizedCropRegion {
        let currentW = width
        let currentH = height
        guard currentW > 0, currentH > 0, targetRatio > 0 else { return self }

        let area = currentW * currentH
        var newW = Foundation.sqrt(area * targetRatio)
        var newH = Foundation.sqrt(area / targetRatio)

        let cx = centerX
        let cy = centerY

        // Clamp to [0,1] bounds, shrinking proportionally if needed
        let maxW = Swift.min(cx, 1 - cx) * 2
        let maxH = Swift.min(cy, 1 - cy) * 2

        if newW > maxW || newH > maxH {
            let scaleW = maxW > 0 ? newW / maxW : Double.greatestFiniteMagnitude
            let scaleH = maxH > 0 ? newH / maxH : Double.greatestFiniteMagnitude
            let scale = Swift.max(scaleW, scaleH)
            newW /= scale
            newH /= scale
        }

        return NormalizedCropRegion(
            top: cy - newH / 2,
            left: cx - newW / 2,
            bottom: cy + newH / 2,
            right: cx + newW / 2
        ).clamped()
    }

    /// Constrains dimensions to match a target aspect ratio (width/height in normalized image space,
    /// i.e. accounting for the image's own aspect ratio).
    /// `targetRatio` is desired cropWidth/cropHeight in normalized coords.
    /// `anchorX`/`anchorY`: 0 = anchor left/top edge, 1 = anchor right/bottom edge, 0.5 = anchor center.
    func constrainedToAspectRatio(_ targetRatio: Double, anchorX: Double = 0.5, anchorY: Double = 0.5) -> NormalizedCropRegion {
        let currentW = width
        let currentH = height
        guard currentW > 0, currentH > 0, targetRatio > 0 else { return self }

        let newW: Double
        let newH: Double

        // Fit within current bounds: shrink the dimension that's too large
        if currentW / currentH > targetRatio {
            // Too wide — shrink width
            newW = currentH * targetRatio
            newH = currentH
        } else {
            // Too tall — shrink height
            newW = currentW
            newH = currentW / targetRatio
        }

        let dW = currentW - newW
        let dH = currentH - newH

        return NormalizedCropRegion(
            top: top + dH * anchorY,
            left: left + dW * anchorX,
            bottom: top + dH * anchorY + newH,
            right: left + dW * anchorX + newW
        ).clamped()
    }
}
