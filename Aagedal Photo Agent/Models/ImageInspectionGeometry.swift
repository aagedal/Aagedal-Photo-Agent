import CoreGraphics
import Foundation

/// Shared fit-to-view and pixel-inspection geometry used by Analysis, Comparison,
/// and the Advanced Export true-pixel loupe.
///
/// View and normalized-display coordinates use a top-left origin. Source pixel
/// coordinates are discrete, zero-based indices in the file's pixel-storage frame.
nonisolated struct ImageInspectionGeometry: Hashable, Sendable {
    let imagePixelSize: CGSize
    let containerRect: CGRect
    let imageRectInView: CGRect

    init(
        imagePixelSize: CGSize,
        containerRect: CGRect
    ) throws {
        let standardizedContainer = containerRect.standardized
        let viewport = try ViewportState(mode: .fit).geometry(
            displayedPixelSize: imagePixelSize,
            viewSize: standardizedContainer.size,
            backingScale: 1
        )

        self.imagePixelSize = imagePixelSize
        self.containerRect = standardizedContainer
        imageRectInView = viewport.imageRectInView.offsetBy(
            dx: standardizedContainer.minX,
            dy: standardizedContainer.minY
        )
    }

    /// Returns a normalized image point only while the pointer is over displayed pixels.
    func normalizedDisplayPoint(fromViewPoint point: CGPoint) -> CGPoint? {
        guard imageRectInView.contains(point) else { return nil }
        return clampedNormalizedDisplayPoint(fromViewPoint: point)
    }

    /// Maps a point to the nearest normalized image edge. Selection drags use this after
    /// confirming that the drag began over displayed pixels, so dragging beyond an edge still
    /// produces an edge-clamped region.
    func clampedNormalizedDisplayPoint(fromViewPoint point: CGPoint) -> CGPoint {
        return CGPoint(
            x: Self.clampUnit((point.x - imageRectInView.minX) / imageRectInView.width),
            y: Self.clampUnit((point.y - imageRectInView.minY) / imageRectInView.height)
        )
    }

    func viewPoint(fromNormalizedDisplay point: CGPoint) -> CGPoint {
        CGPoint(
            x: imageRectInView.minX + point.x * imageRectInView.width,
            y: imageRectInView.minY + point.y * imageRectInView.height
        )
    }

    /// Calculates a source-resolution crop around a normalized display point.
    ///
    /// Core Image uses a bottom-left origin while SwiftUI hover positions use a
    /// top-left origin. Callers choose the pixel extent's origin explicitly so the
    /// crop cannot be silently mirrored vertically.
    static func centeredPixelCropRect(
        in imageExtent: CGRect,
        normalizedDisplayPoint point: CGPoint,
        pixelSize: Int,
        extentOrigin: ImageInspectionExtentOrigin
    ) -> CGRect? {
        let extent = imageExtent.standardized
        guard extent.width > 0,
              extent.height > 0,
              extent.width.isFinite,
              extent.height.isFinite,
              pixelSize > 0 else {
            return nil
        }

        let cropWidth = min(CGFloat(pixelSize), extent.width)
        let cropHeight = min(CGFloat(pixelSize), extent.height)
        let unitX = clampUnit(point.x)
        let displayUnitY = clampUnit(point.y)
        let extentUnitY = extentOrigin == .topLeft ? displayUnitY : 1 - displayUnitY
        let centerX = extent.minX + unitX * extent.width
        let centerY = extent.minY + extentUnitY * extent.height
        let originX = min(
            extent.maxX - cropWidth,
            max(extent.minX, centerX - cropWidth / 2)
        )
        let originY = min(
            extent.maxY - cropHeight,
            max(extent.minY, centerY - cropHeight / 2)
        )

        return CGRect(
            x: originX,
            y: originY,
            width: cropWidth,
            height: cropHeight
        ).integral
    }

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}

nonisolated enum ImageInspectionExtentOrigin: Hashable, Sendable {
    case topLeft
    case bottomLeft
}

nonisolated struct SourcePixelCoordinate: Hashable, Sendable {
    let x: Int
    let y: Int
}

/// One linked hover location expressed both in representation space and in the
/// original file's pixel-storage frame.
nonisolated struct ImageInspectionSample: Hashable, Sendable {
    let normalizedDisplayPoint: CGPoint
    let sourceNormalizedPoint: CGPoint
    let sourcePixel: SourcePixelCoordinate

    init(
        normalizedDisplayPoint: CGPoint,
        transform: DisplayImageTransform
    ) {
        let displayPoint = CGPoint(
            x: min(1, max(0, normalizedDisplayPoint.x)),
            y: min(1, max(0, normalizedDisplayPoint.y))
        )
        let sourcePoint = transform.sourceNormalizedPoint(
            fromDisplayNormalized: displayPoint
        )
        let continuousPixel = CGPoint(
            x: sourcePoint.x * CGFloat(transform.sourcePixelWidth),
            y: sourcePoint.y * CGFloat(transform.sourcePixelHeight)
        )

        self.normalizedDisplayPoint = displayPoint
        sourceNormalizedPoint = CGPoint(
            x: min(1, max(0, sourcePoint.x)),
            y: min(1, max(0, sourcePoint.y))
        )
        sourcePixel = SourcePixelCoordinate(
            x: Self.pixelIndex(continuousPixel.x, count: transform.sourcePixelWidth),
            y: Self.pixelIndex(continuousPixel.y, count: transform.sourcePixelHeight)
        )
    }

    private static func pixelIndex(_ value: CGFloat, count: Int) -> Int {
        min(count - 1, max(0, Int(floor(value))))
    }
}
