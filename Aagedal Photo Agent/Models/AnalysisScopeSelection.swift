import CoreGraphics

/// Normalized selection geometry for region-scoped analysis.
///
/// Both the source preview and `CGImage` use a top-left origin here. Keeping the conversion
/// independent of SwiftUI makes selection behavior deterministic and directly testable.
nonisolated enum AnalysisScopeSelection {
    static let minimumNormalizedDimension: CGFloat = 0.005

    static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect? {
        guard start.x.isFinite,
              start.y.isFinite,
              end.x.isFinite,
              end.y.isFinite else {
            return nil
        }

        let start = clampedPoint(start)
        let end = clampedPoint(end)
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        guard rect.width >= minimumNormalizedDimension,
              rect.height >= minimumNormalizedDimension else {
            return nil
        }
        return rect
    }

    static func pixelRect(
        for normalizedRect: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect? {
        guard imageWidth > 0, imageHeight > 0 else { return nil }

        let rect = normalizedRect.standardized.intersection(
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        guard !rect.isNull,
              rect.width >= minimumNormalizedDimension,
              rect.height >= minimumNormalizedDimension else {
            return nil
        }

        let width = CGFloat(imageWidth)
        let height = CGFloat(imageHeight)
        let minX = max(0, min(width - 1, lowerPixelBoundary(rect.minX * width)))
        let minY = max(0, min(height - 1, lowerPixelBoundary(rect.minY * height)))
        let maxX = max(minX + 1, min(width, upperPixelBoundary(rect.maxX * width)))
        let maxY = max(minY + 1, min(height, upperPixelBoundary(rect.maxY * height)))
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    static func croppedImage(
        from image: CGImage,
        normalizedRect: CGRect
    ) -> CGImage? {
        guard let pixelRect = pixelRect(
            for: normalizedRect,
            imageWidth: image.width,
            imageHeight: image.height
        ) else {
            return nil
        }
        return image.cropping(to: pixelRect)
    }

    private static func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(1, max(0, point.x)),
            y: min(1, max(0, point.y))
        )
    }

    /// Decimal normalized boundaries can land a few ulps above or below their exact integer
    /// pixel edge. Snap those values before expanding outward so a mathematically exact edge
    /// does not accidentally include an extra row or column.
    private static func lowerPixelBoundary(_ value: CGFloat) -> CGFloat {
        let nearest = value.rounded()
        return abs(value - nearest) < 0.000_001 ? nearest : floor(value)
    }

    private static func upperPixelBoundary(_ value: CGFloat) -> CGFloat {
        let nearest = value.rounded()
        return abs(value - nearest) < 0.000_001 ? nearest : ceil(value)
    }
}
