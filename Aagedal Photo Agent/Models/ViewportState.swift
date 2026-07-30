import CoreGraphics
import Foundation

/// Shared image navigation state for analysis, comparison, full-screen, and Clean Feed surfaces.
///
/// All coordinates use a top-left origin. `normalizedCenter` is expressed in the displayed,
/// EXIF-oriented image frame, which makes it independent of view size and backing scale.
nonisolated struct ViewportState: Hashable, Sendable {
    enum Mode: Hashable, Sendable {
        case fit
        case actualPixels
        /// Image pixels represented by one display backing pixel. Values below 1 zoom in.
        case custom(imagePixelsPerBackingPixel: CGFloat)
    }

    enum Interpolation: String, CaseIterable, Hashable, Sendable {
        case nearest
        case linear
    }

    var mode: Mode
    var normalizedCenter: CGPoint
    var interpolation: Interpolation

    init(
        mode: Mode = .fit,
        normalizedCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
        interpolation: Interpolation = .linear
    ) {
        self.mode = mode
        self.normalizedCenter = normalizedCenter
        self.interpolation = interpolation
    }

    /// Resolves the state into geometry for a particular surface.
    func geometry(
        displayedPixelSize: CGSize,
        viewSize: CGSize,
        backingScale: CGFloat
    ) throws -> ViewportGeometry {
        try ViewportGeometry(
            state: self,
            displayedPixelSize: displayedPixelSize,
            viewSize: viewSize,
            backingScale: backingScale
        )
    }

    /// Returns a copy whose center cannot pan the image beyond an edge.
    ///
    /// An axis that fits inside the view remains centered. This deliberately does not mutate the
    /// zoom mode, so resizing a surface can re-clamp the same logical viewport.
    func clamped(
        displayedPixelSize: CGSize,
        viewSize: CGSize,
        backingScale: CGFloat
    ) throws -> ViewportState {
        let geometry = try geometry(
            displayedPixelSize: displayedPixelSize,
            viewSize: viewSize,
            backingScale: backingScale
        )
        var result = self
        result.normalizedCenter = CGPoint(
            x: Self.clampCenterAxis(
                normalizedCenter.x,
                visibleFraction: viewSize.width / geometry.imageRectInView.width
            ),
            y: Self.clampCenterAxis(
                normalizedCenter.y,
                visibleFraction: viewSize.height / geometry.imageRectInView.height
            )
        )
        return result
    }

    private static func clampCenterAxis(
        _ center: CGFloat,
        visibleFraction: CGFloat
    ) -> CGFloat {
        guard visibleFraction < 1 else { return 0.5 }
        let halfVisible = visibleFraction / 2
        return min(max(center, halfVisible), 1 - halfVisible)
    }
}

/// Derived, immutable mapping between one view and one displayed image.
nonisolated struct ViewportGeometry: Hashable, Sendable {
    let displayedPixelSize: CGSize
    let viewSize: CGSize
    let backingScale: CGFloat
    let imagePixelsPerBackingPixel: CGFloat
    let imageRectInView: CGRect

    fileprivate init(
        state: ViewportState,
        displayedPixelSize: CGSize,
        viewSize: CGSize,
        backingScale: CGFloat
    ) throws {
        guard Self.isPositiveFinite(displayedPixelSize.width),
              Self.isPositiveFinite(displayedPixelSize.height) else {
            throw ViewportStateError.invalidDisplayedPixelSize(displayedPixelSize)
        }
        guard Self.isPositiveFinite(viewSize.width),
              Self.isPositiveFinite(viewSize.height) else {
            throw ViewportStateError.invalidViewSize(viewSize)
        }
        guard Self.isPositiveFinite(backingScale) else {
            throw ViewportStateError.invalidBackingScale(backingScale)
        }
        guard state.normalizedCenter.x.isFinite,
              state.normalizedCenter.y.isFinite else {
            throw ViewportStateError.invalidNormalizedCenter(state.normalizedCenter)
        }

        let resolvedPixelsPerBackingPixel: CGFloat
        switch state.mode {
        case .fit:
            let viewBackingSize = CGSize(
                width: viewSize.width * backingScale,
                height: viewSize.height * backingScale
            )
            resolvedPixelsPerBackingPixel = max(
                displayedPixelSize.width / viewBackingSize.width,
                displayedPixelSize.height / viewBackingSize.height
            )
        case .actualPixels:
            resolvedPixelsPerBackingPixel = 1
        case let .custom(imagePixelsPerBackingPixel):
            guard Self.isPositiveFinite(imagePixelsPerBackingPixel) else {
                throw ViewportStateError.invalidCustomScale(imagePixelsPerBackingPixel)
            }
            resolvedPixelsPerBackingPixel = imagePixelsPerBackingPixel
        }

        let displayedSizeInView = CGSize(
            width: displayedPixelSize.width / resolvedPixelsPerBackingPixel / backingScale,
            height: displayedPixelSize.height / resolvedPixelsPerBackingPixel / backingScale
        )
        let effectiveCenter = state.mode == .fit
            ? CGPoint(x: 0.5, y: 0.5)
            : state.normalizedCenter
        let viewCenter = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)

        self.displayedPixelSize = displayedPixelSize
        self.viewSize = viewSize
        self.backingScale = backingScale
        imagePixelsPerBackingPixel = resolvedPixelsPerBackingPixel
        imageRectInView = CGRect(
            x: viewCenter.x - effectiveCenter.x * displayedSizeInView.width,
            y: viewCenter.y - effectiveCenter.y * displayedSizeInView.height,
            width: displayedSizeInView.width,
            height: displayedSizeInView.height
        )
    }

    func normalizedDisplayPoint(fromViewPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - imageRectInView.minX) / imageRectInView.width,
            y: (point.y - imageRectInView.minY) / imageRectInView.height
        )
    }

    func viewPoint(fromNormalizedDisplay point: CGPoint) -> CGPoint {
        CGPoint(
            x: imageRectInView.minX + point.x * imageRectInView.width,
            y: imageRectInView.minY + point.y * imageRectInView.height
        )
    }

    func normalizedDisplayRect(fromViewRect rect: CGRect) -> CGRect {
        let first = normalizedDisplayPoint(
            fromViewPoint: CGPoint(x: rect.standardized.minX, y: rect.standardized.minY)
        )
        let second = normalizedDisplayPoint(
            fromViewPoint: CGPoint(x: rect.standardized.maxX, y: rect.standardized.maxY)
        )
        return CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }

    func viewRect(fromNormalizedDisplay rect: CGRect) -> CGRect {
        let first = viewPoint(
            fromNormalizedDisplay: CGPoint(x: rect.standardized.minX, y: rect.standardized.minY)
        )
        let second = viewPoint(
            fromNormalizedDisplay: CGPoint(x: rect.standardized.maxX, y: rect.standardized.maxY)
        )
        return CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }

    func displayPixelPoint(fromViewPoint point: CGPoint) -> CGPoint {
        let normalized = normalizedDisplayPoint(fromViewPoint: point)
        return CGPoint(
            x: normalized.x * displayedPixelSize.width,
            y: normalized.y * displayedPixelSize.height
        )
    }

    func viewPoint(fromDisplayPixel point: CGPoint) -> CGPoint {
        viewPoint(
            fromNormalizedDisplay: CGPoint(
                x: point.x / displayedPixelSize.width,
                y: point.y / displayedPixelSize.height
            )
        )
    }

    private static func isPositiveFinite(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0
    }
}

nonisolated enum ViewportStateError: Error, Equatable, LocalizedError, Sendable {
    case invalidDisplayedPixelSize(CGSize)
    case invalidViewSize(CGSize)
    case invalidBackingScale(CGFloat)
    case invalidCustomScale(CGFloat)
    case invalidNormalizedCenter(CGPoint)

    var errorDescription: String? {
        switch self {
        case let .invalidDisplayedPixelSize(size):
            "Displayed pixel dimensions must be positive and finite (received \(size))."
        case let .invalidViewSize(size):
            "Viewport dimensions must be positive and finite (received \(size))."
        case let .invalidBackingScale(scale):
            "Backing scale must be positive and finite (received \(scale))."
        case let .invalidCustomScale(scale):
            "Custom image scale must be positive and finite (received \(scale))."
        case let .invalidNormalizedCenter(center):
            "Viewport center must be finite (received \(center))."
        }
    }
}
