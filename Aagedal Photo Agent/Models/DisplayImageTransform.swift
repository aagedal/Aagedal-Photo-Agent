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

    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    let orientation: Orientation

    /// Missing and unknown EXIF values are interpreted as orientation 1, matching ImageIO.
    init(
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        exifOrientation: Int? = nil
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
    }

    var sourcePixelSize: CGSize {
        CGSize(width: sourcePixelWidth, height: sourcePixelHeight)
    }

    var displayedPixelSize: CGSize {
        if orientation.transposesDimensions {
            CGSize(width: sourcePixelHeight, height: sourcePixelWidth)
        } else {
            sourcePixelSize
        }
    }

    /// Maps a normalized point from the source pixel-storage frame into the upright display frame.
    ///
    /// Coordinates are not clamped. Keeping points outside `0...1` intact makes the conversion
    /// reversible for in-progress gestures and lets the owning surface choose its boundary policy.
    func displayNormalizedPoint(fromSourceNormalized point: CGPoint) -> CGPoint {
        mapNormalizedPoint(point, orientation: orientation)
    }

    /// Maps an upright, normalized display point back into the source pixel-storage frame.
    func sourceNormalizedPoint(fromDisplayNormalized point: CGPoint) -> CGPoint {
        mapNormalizedPoint(point, orientation: orientation.inverse)
    }

    func displayNormalizedRect(fromSourceNormalized rect: CGRect) -> CGRect {
        mapNormalizedRect(rect, orientation: orientation)
    }

    func sourceNormalizedRect(fromDisplayNormalized rect: CGRect) -> CGRect {
        mapNormalizedRect(rect, orientation: orientation.inverse)
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

    private func mapNormalizedRect(_ rect: CGRect, orientation: Orientation) -> CGRect {
        let standardized = rect.standardized
        let corners = [
            CGPoint(x: standardized.minX, y: standardized.minY),
            CGPoint(x: standardized.maxX, y: standardized.minY),
            CGPoint(x: standardized.minX, y: standardized.maxY),
            CGPoint(x: standardized.maxX, y: standardized.maxY)
        ].map { mapNormalizedPoint($0, orientation: orientation) }

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

    private func mapNormalizedPoint(_ point: CGPoint, orientation: Orientation) -> CGPoint {
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

    var errorDescription: String? {
        switch self {
        case let .invalidSourcePixelSize(width, height):
            "Source pixel dimensions must be positive (received \(width) × \(height))."
        }
    }
}
