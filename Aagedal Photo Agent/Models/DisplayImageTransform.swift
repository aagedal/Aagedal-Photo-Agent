import CoreGraphics
import Foundation

/// Converts image geometry between the pixel storage recorded in the source file and the
/// top-left-origin display space produced by applying its EXIF orientation.
///
/// Point coordinates use continuous image-edge units: `(0, 0)` is the top-left image edge and
/// `(width, height)` is the bottom-right edge. This keeps rectangles and normalized annotations
/// lossless. A caller displaying a discrete pixel index can clamp/floor the returned value at the
/// UI boundary.
nonisolated struct DisplayImageTransform: Hashable, Sendable {
    /// The eight transformations defined by the EXIF orientation tag.
    enum Orientation: Int, CaseIterable, Sendable {
        case up = 1
        case upMirrored = 2
        case down = 3
        case downMirrored = 4
        case leftMirrored = 5
        case right = 6
        case rightMirrored = 7
        case left = 8

        var transposesDimensions: Bool {
            switch self {
            case .leftMirrored, .right, .rightMirrored, .left:
                true
            default:
                false
            }
        }

        var inverse: Orientation {
            switch self {
            case .right: .left
            case .left: .right
            default: self
            }
        }
    }

    /// A developed crop as persisted in the source/XMP pixel-storage frame.
    ///
    /// The crop rectangle is converted through the EXIF orientation before the straighten
    /// transform is applied. It may extend beyond `0...1`; angled crops can legitimately retain
    /// an off-image upright rectangle while their rotated corners remain in bounds.
    struct DevelopedCrop: Hashable, Sendable {
        let sourceNormalizedRect: CGRect
        let straightenAngleDegrees: CGFloat

        init(
            sourceNormalizedRect: CGRect,
            straightenAngleDegrees: CGFloat = 0
        ) throws {
            guard sourceNormalizedRect.origin.x.isFinite,
                  sourceNormalizedRect.origin.y.isFinite,
                  sourceNormalizedRect.width.isFinite,
                  sourceNormalizedRect.height.isFinite else {
                throw DisplayImageTransformError.invalidDevelopedCrop(sourceNormalizedRect)
            }

            let standardized = sourceNormalizedRect.standardized
            guard standardized.minX.isFinite,
                  standardized.minY.isFinite,
                  standardized.maxX.isFinite,
                  standardized.maxY.isFinite,
                  standardized.width > 0,
                  standardized.height > 0 else {
                throw DisplayImageTransformError.invalidDevelopedCrop(sourceNormalizedRect)
            }
            guard straightenAngleDegrees.isFinite else {
                throw DisplayImageTransformError.invalidStraightenAngle(straightenAngleDegrees)
            }

            self.sourceNormalizedRect = standardized
            self.straightenAngleDegrees = straightenAngleDegrees
        }
    }

    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    let orientation: Orientation
    let developedCrop: DevelopedCrop?

    /// The developed crop in the upright, full-image display frame.
    ///
    /// This is `nil` for the original representation. The resolved rectangle is useful at
    /// rendering boundaries that already operate on EXIF-oriented pixels.
    var developedCropRectInFullDisplay: CGRect? {
        developedCrop.map {
            mapNormalizedRect($0.sourceNormalizedRect, orientation: orientation)
        }
    }

    /// Missing and unknown EXIF values are interpreted as orientation 1, matching ImageIO.
    init(
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        exifOrientation: Int? = nil,
        developedCrop: DevelopedCrop? = nil
    ) throws {
        guard sourcePixelWidth > 0, sourcePixelHeight > 0 else {
            throw DisplayImageTransformError.invalidSourcePixelSize(
                width: sourcePixelWidth,
                height: sourcePixelHeight
            )
        }

        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        orientation = exifOrientation.flatMap(Orientation.init(rawValue:)) ?? .up
        self.developedCrop = developedCrop
    }

    var sourcePixelSize: CGSize {
        CGSize(width: sourcePixelWidth, height: sourcePixelHeight)
    }

    /// Pixel dimensions of the full source after applying EXIF orientation.
    var fullDisplayedPixelSize: CGSize {
        if orientation.transposesDimensions {
            CGSize(width: sourcePixelHeight, height: sourcePixelWidth)
        } else {
            sourcePixelSize
        }
    }

    /// Pixel dimensions of the selected representation after orientation and developed crop.
    var displayedPixelSize: CGSize {
        guard let crop = developedCropRectInFullDisplay else {
            return fullDisplayedPixelSize
        }
        return CGSize(
            width: crop.width * fullDisplayedPixelSize.width,
            height: crop.height * fullDisplayedPixelSize.height
        )
    }

    /// Maps a normalized point from the source pixel-storage frame into the upright display frame.
    ///
    /// Coordinates are not clamped. Keeping points outside `0...1` intact makes the conversion
    /// reversible for in-progress gestures and lets the owning surface choose its boundary policy.
    func displayNormalizedPoint(fromSourceNormalized point: CGPoint) -> CGPoint {
        let fullDisplayPoint = mapNormalizedPoint(point, orientation: orientation)
        return developedNormalizedPoint(fromFullDisplayNormalized: fullDisplayPoint)
    }

    /// Maps an upright, normalized display point back into the source pixel-storage frame.
    func sourceNormalizedPoint(fromDisplayNormalized point: CGPoint) -> CGPoint {
        let fullDisplayPoint = fullDisplayNormalizedPoint(fromDevelopedNormalized: point)
        return mapNormalizedPoint(fullDisplayPoint, orientation: orientation.inverse)
    }

    func displayNormalizedRect(fromSourceNormalized rect: CGRect) -> CGRect {
        mapNormalizedRect(rect) {
            displayNormalizedPoint(fromSourceNormalized: $0)
        }
    }

    /// Returns the source-frame axis-aligned bounding box of a display rectangle.
    ///
    /// With a nonzero straighten angle, the exact source footprint is a rotated quadrilateral;
    /// this rectangle intentionally encloses it and is therefore not losslessly round-trippable.
    func sourceNormalizedRect(fromDisplayNormalized rect: CGRect) -> CGRect {
        mapNormalizedRect(rect) {
            sourceNormalizedPoint(fromDisplayNormalized: $0)
        }
    }

    func displayNormalizedPoint(fromSourcePixel point: CGPoint) -> CGPoint {
        displayNormalizedPoint(
            fromSourceNormalized: CGPoint(
                x: point.x / CGFloat(sourcePixelWidth),
                y: point.y / CGFloat(sourcePixelHeight)
            )
        )
    }

    func sourcePixelPoint(fromDisplayNormalized point: CGPoint) -> CGPoint {
        let normalized = sourceNormalizedPoint(fromDisplayNormalized: point)
        return CGPoint(
            x: normalized.x * CGFloat(sourcePixelWidth),
            y: normalized.y * CGFloat(sourcePixelHeight)
        )
    }

    func displayNormalizedRect(fromSourcePixel rect: CGRect) -> CGRect {
        displayNormalizedRect(
            fromSourceNormalized: CGRect(
                x: rect.origin.x / CGFloat(sourcePixelWidth),
                y: rect.origin.y / CGFloat(sourcePixelHeight),
                width: rect.size.width / CGFloat(sourcePixelWidth),
                height: rect.size.height / CGFloat(sourcePixelHeight)
            )
        )
    }

    func sourcePixelRect(fromDisplayNormalized rect: CGRect) -> CGRect {
        let normalized = sourceNormalizedRect(fromDisplayNormalized: rect)
        return CGRect(
            x: normalized.origin.x * CGFloat(sourcePixelWidth),
            y: normalized.origin.y * CGFloat(sourcePixelHeight),
            width: normalized.size.width * CGFloat(sourcePixelWidth),
            height: normalized.size.height * CGFloat(sourcePixelHeight)
        )
    }

    private func developedNormalizedPoint(
        fromFullDisplayNormalized point: CGPoint
    ) -> CGPoint {
        guard let crop = developedCropRectInFullDisplay,
              let angleDegrees = developedCrop?.straightenAngleDegrees else {
            return point
        }

        let fullSize = fullDisplayedPixelSize
        let offset = CGPoint(
            x: (point.x - crop.midX) * fullSize.width,
            y: (point.y - crop.midY) * fullSize.height
        )
        let radians = -angleDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let unrotated = CGPoint(
            x: offset.x * cosine - offset.y * sine,
            y: offset.x * sine + offset.y * cosine
        )
        return CGPoint(
            x: 0.5 + unrotated.x / displayedPixelSize.width,
            y: 0.5 + unrotated.y / displayedPixelSize.height
        )
    }

    private func fullDisplayNormalizedPoint(
        fromDevelopedNormalized point: CGPoint
    ) -> CGPoint {
        guard let crop = developedCropRectInFullDisplay,
              let angleDegrees = developedCrop?.straightenAngleDegrees else {
            return point
        }

        let developedSize = displayedPixelSize
        let offset = CGPoint(
            x: (point.x - 0.5) * developedSize.width,
            y: (point.y - 0.5) * developedSize.height
        )
        let radians = angleDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let rotated = CGPoint(
            x: offset.x * cosine - offset.y * sine,
            y: offset.x * sine + offset.y * cosine
        )
        let fullSize = fullDisplayedPixelSize
        return CGPoint(
            x: crop.midX + rotated.x / fullSize.width,
            y: crop.midY + rotated.y / fullSize.height
        )
    }

    private func mapNormalizedRect(
        _ rect: CGRect,
        pointTransform: (CGPoint) -> CGPoint
    ) -> CGRect {
        let standardized = rect.standardized
        let corners = [
            CGPoint(x: standardized.minX, y: standardized.minY),
            CGPoint(x: standardized.maxX, y: standardized.minY),
            CGPoint(x: standardized.minX, y: standardized.maxY),
            CGPoint(x: standardized.maxX, y: standardized.maxY)
        ].map(pointTransform)

        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(),
              let maxX = xs.max(),
              let minY = ys.min(),
              let maxY = ys.max() else {
            return .null
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func mapNormalizedRect(_ rect: CGRect, orientation: Orientation) -> CGRect {
        mapNormalizedRect(rect) {
            mapNormalizedPoint($0, orientation: orientation)
        }
    }

    private func mapNormalizedPoint(
        _ point: CGPoint,
        orientation: Orientation
    ) -> CGPoint {
        switch orientation {
        case .up:
            point
        case .upMirrored:
            CGPoint(x: 1 - point.x, y: point.y)
        case .down:
            CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .downMirrored:
            CGPoint(x: point.x, y: 1 - point.y)
        case .leftMirrored:
            CGPoint(x: point.y, y: point.x)
        case .right:
            CGPoint(x: 1 - point.y, y: point.x)
        case .rightMirrored:
            CGPoint(x: 1 - point.y, y: 1 - point.x)
        case .left:
            CGPoint(x: point.y, y: 1 - point.x)
        }
    }
}

nonisolated enum DisplayImageTransformError: Error, Equatable, LocalizedError, Sendable {
    case invalidSourcePixelSize(width: Int, height: Int)
    case invalidDevelopedCrop(CGRect)
    case invalidStraightenAngle(CGFloat)

    var errorDescription: String? {
        switch self {
        case let .invalidSourcePixelSize(width, height):
            "Source pixel dimensions must be positive (received \(width) × \(height))."
        case let .invalidDevelopedCrop(rect):
            "Developed crop dimensions must be positive and finite (received \(rect))."
        case let .invalidStraightenAngle(angle):
            "Straighten angle must be finite (received \(angle))."
        }
    }
}
