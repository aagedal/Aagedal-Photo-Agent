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

/// Geometry shared by fit-to-view previews that zoom a centered image canvas.
/// Offsets are expressed in viewport points after scaling, so a one-point pointer
/// movement always produces a one-point pan on screen.
nonisolated enum ImagePreviewZoomGeometry {
    static let maximumScale: CGFloat = 40

    static func clampedScale(_ requestedScale: CGFloat, minimumScale: CGFloat = 1) -> CGFloat {
        min(maximumScale, max(minimumScale, requestedScale))
    }

    static func offset(
        anchoredAt anchor: CGPoint,
        in viewportSize: CGSize,
        currentOffset: CGSize,
        oldScale: CGFloat,
        newScale: CGFloat
    ) -> CGSize {
        guard oldScale > 0,
              oldScale.isFinite,
              newScale.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return currentOffset
        }

        let ratio = newScale / oldScale
        let anchorFromCenter = CGSize(
            width: anchor.x - viewportSize.width / 2,
            height: anchor.y - viewportSize.height / 2
        )
        return CGSize(
            width: currentOffset.width * ratio + anchorFromCenter.width * (1 - ratio),
            height: currentOffset.height * ratio + anchorFromCenter.height * (1 - ratio)
        )
    }

    static func clampedOffset(
        _ requestedOffset: CGSize,
        zoomScale: CGFloat,
        viewportSize: CGSize,
        imageRects: [CGRect]
    ) -> CGSize {
        guard zoomScale >= 1,
              zoomScale.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0,
              let imageBounds = imageRects
                .map(\.standardized)
                .filter({ !$0.isEmpty && !$0.isNull && !$0.isInfinite })
                .reduce(nil, { bounds, rect in
                    bounds?.union(rect) ?? rect
                }) else {
            return .zero
        }

        let viewportCenter = CGPoint(
            x: viewportSize.width / 2,
            y: viewportSize.height / 2
        )
        return CGSize(
            width: clampedAxisOffset(
                requestedOffset.width,
                scale: zoomScale,
                viewportLength: viewportSize.width,
                viewportCenter: viewportCenter.x,
                contentMinimum: imageBounds.minX,
                contentMaximum: imageBounds.maxX
            ),
            height: clampedAxisOffset(
                requestedOffset.height,
                scale: zoomScale,
                viewportLength: viewportSize.height,
                viewportCenter: viewportCenter.y,
                contentMinimum: imageBounds.minY,
                contentMaximum: imageBounds.maxY
            )
        )
    }

    private static func clampedAxisOffset(
        _ requestedOffset: CGFloat,
        scale: CGFloat,
        viewportLength: CGFloat,
        viewportCenter: CGFloat,
        contentMinimum: CGFloat,
        contentMaximum: CGFloat
    ) -> CGFloat {
        let scaledLength = (contentMaximum - contentMinimum) * scale
        guard scaledLength > viewportLength else {
            let contentCenter = (contentMinimum + contentMaximum) / 2
            return -(contentCenter - viewportCenter) * scale
        }

        let minimumOffset = viewportLength
            - viewportCenter
            - (contentMaximum - viewportCenter) * scale
        let maximumOffset = -viewportCenter
            - (contentMinimum - viewportCenter) * scale
        return min(maximumOffset, max(minimumOffset, requestedOffset))
    }
}

nonisolated struct SourcePixelCoordinate: Hashable, Sendable {
    let x: Int
    let y: Int
}

nonisolated struct SourcePixelRGBA16: Hashable, Sendable {
    let red: UInt16
    let green: UInt16
    let blue: UInt16
    let alpha: UInt16
}

/// One linked hover location expressed both in representation space and in the
/// original file's pixel-storage frame.
nonisolated struct ImageInspectionSample: Hashable, Sendable {
    let normalizedDisplayPoint: CGPoint
    let sourceNormalizedPoint: CGPoint
    let sourcePixel: SourcePixelCoordinate
    let rgba16: SourcePixelRGBA16?

    init(
        normalizedDisplayPoint: CGPoint,
        transform: DisplayImageTransform,
        rgba16: SourcePixelRGBA16? = nil
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
        self.rgba16 = rgba16
    }

    private static func pixelIndex(_ value: CGFloat, count: Int) -> Int {
        min(count - 1, max(0, Int(floor(value))))
    }
}
