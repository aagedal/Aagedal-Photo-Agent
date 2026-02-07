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

    func fittingRotated(angleDegrees: Double) -> NormalizedCropRegion {
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

        let signs: [(Double, Double)] = [(-1, -1), (1, -1), (-1, 1), (1, 1)]
        var maxScale = 1.0

        for (sx, sy) in signs {
            let ox = (sx * halfW * cosA) - (sy * halfH * sinA)
            let oy = (sx * halfW * sinA) + (sy * halfH * cosA)

            if ox > 0 { maxScale = min(maxScale, (1 - cx) / ox) }
            if ox < 0 { maxScale = min(maxScale, cx / (-ox)) }
            if oy > 0 { maxScale = min(maxScale, (1 - cy) / oy) }
            if oy < 0 { maxScale = min(maxScale, cy / (-oy)) }
        }

        maxScale = min(maxScale, 1.0)
        if maxScale < 0 { maxScale = 0 }

        let newHalfW = halfW * maxScale
        let newHalfH = halfH * maxScale
        result = NormalizedCropRegion(
            top: cy - newHalfH,
            left: cx - newHalfW,
            bottom: cy + newHalfH,
            right: cx + newHalfW
        ).clamped()
        return result
    }
}
