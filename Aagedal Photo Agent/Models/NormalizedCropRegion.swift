import Foundation

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

    /// Constrains the crop so all 4 corners of the rotated rectangle stay within the image.
    /// `aspectRatio` is imageWidth / imageHeight.
    func fittingRotated(angleDegrees: Double, aspectRatio: Double) -> NormalizedCropRegion {
        var result = clamped()
        let radians = angleDegrees * Double.pi / 180.0
        if abs(radians) < 0.000001 {
            return result
        }

        let cx = result.centerX
        let cy = result.centerY
        let halfW = result.width * 0.5
        let halfH = result.height * 0.5
        let cosA: Double = Foundation.cos(radians)
        let sinA: Double = Foundation.sin(radians)
        let ar = Swift.max(aspectRatio, 0.001)

        // Convert AABB diagonal half-sizes to pixel-proportional units (in terms of image height)
        let dW = halfW * ar
        let dH = halfH

        // Forward projection: AABB diagonal → actual crop half-dimensions
        let hw = Swift.abs(dW * cosA + dH * sinA)
        let hh = Swift.abs(-dW * sinA + dH * cosA)

        // Check all 4 rotated corners stay within [0,1]² normalized bounds
        let signs: [(Double, Double)] = [(-1, -1), (1, -1), (-1, 1), (1, 1)]
        var maxScale = 1.0

        for (sx, sy) in signs {
            let ox = sx * hw * cosA - sy * hh * sinA
            let oy = sx * hw * sinA + sy * hh * cosA
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
        if maxScale >= 1.0 - 0.0001 { return result }

        // Scale actual crop dimensions uniformly
        let newHw = hw * maxScale
        let newHh = hh * maxScale

        // Inverse projection: actual → AABB diagonal
        let newHalfW = Swift.abs(newHw * cosA - newHh * sinA) / ar
        let newHalfH = Swift.abs(newHw * sinA + newHh * cosA)

        return NormalizedCropRegion(
            top: cy - newHalfH,
            left: cx - newHalfW,
            bottom: cy + newHalfH,
            right: cx + newHalfW
        ).clamped()
    }

    /// Adjusts center position so all rotated corners stay within [0,1]² bounds,
    /// without changing the crop dimensions. Use instead of `fittingRotated` when
    /// only the position should change (e.g., during movement).
    func centerClampedForRotation(angleDegrees: Double, aspectRatio: Double) -> NormalizedCropRegion {
        let halfW = Swift.max(width * 0.5, 0.015)
        let halfH = Swift.max(height * 0.5, 0.015)
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

        let dW = halfW * ar
        let dH = halfH
        let hw = Swift.abs(dW * cosA + dH * sinA)
        let hh = Swift.abs(-dW * sinA + dH * cosA)

        // Compute center bounds from rotated corner constraints
        var minCX = 0.0, maxCX = 1.0
        var minCY = 0.0, maxCY = 1.0
        let signs: [(Double, Double)] = [(-1, -1), (1, -1), (-1, 1), (1, 1)]

        for (sx, sy) in signs {
            let ox = sx * hw * cosA - sy * hh * sinA
            let oy = sx * hw * sinA + sy * hh * cosA
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

    /// Recomputes the AABB when changing the crop angle, preserving the actual crop dimensions.
    /// `aspectRatio` is imageWidth / imageHeight.
    func withAngle(from oldAngle: Double, to newAngle: Double, aspectRatio: Double) -> NormalizedCropRegion {
        let base = clamped()
        let oldRad = oldAngle * Double.pi / 180.0
        let newRad = newAngle * Double.pi / 180.0
        let ar = Swift.max(aspectRatio, 0.001)

        let halfW = base.width * 0.5
        let halfH = base.height * 0.5

        // AABB diagonal in pixel-proportional units
        let dW = halfW * ar
        let dH = halfH

        // Forward: actual crop dims from old angle
        let cosOld: Double = Foundation.cos(oldRad)
        let sinOld: Double = Foundation.sin(oldRad)
        let hw = Swift.abs(dW * cosOld + dH * sinOld)
        let hh = Swift.abs(-dW * sinOld + dH * cosOld)

        // Inverse: new AABB at new angle
        let cosNew: Double = Foundation.cos(newRad)
        let sinNew: Double = Foundation.sin(newRad)
        let newHalfW = Swift.abs(hw * cosNew - hh * sinNew) / ar
        let newHalfH = Swift.abs(hw * sinNew + hh * cosNew)

        let cx = base.centerX
        let cy = base.centerY
        return NormalizedCropRegion(
            top: cy - newHalfH,
            left: cx - newHalfW,
            bottom: cy + newHalfH,
            right: cx + newHalfW
        ).clamped()
    }
}
