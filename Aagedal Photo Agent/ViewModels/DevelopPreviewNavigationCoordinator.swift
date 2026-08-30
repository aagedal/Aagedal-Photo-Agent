import CoreGraphics
import Observation

/// Shared zoom bounds for every normal Develop-preview input path. Crop-tool zoom remains
/// intentionally separate because it controls framing for crop handles rather than pixel-level
/// image inspection.
nonisolated enum EditZoomBehavior {
    static let scaleRange: ClosedRange<CGFloat> = 1.0...40.0
    static let maximumScale = scaleRange.upperBound

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        if scale < scaleRange.lowerBound { return scaleRange.lowerBound }
        if scale > scaleRange.upperBound { return scaleRange.upperBound }
        return scale
    }
}

/// Owns the transient zoom and pan session for the normal Develop preview.
///
/// Preview geometry and Metal viewport publication remain at the view boundary. This coordinator
/// owns the paired live/committed values used by magnify and drag gestures so image changes,
/// fit-view resets, and gesture completion cannot leave the next interaction anchored to stale
/// state.
@MainActor
@Observable
final class DevelopPreviewNavigationCoordinator {
    private(set) var zoomScale: CGFloat = 1.0
    private(set) var committedZoomScale: CGFloat = 1.0
    private(set) var offset: CGSize = .zero
    private(set) var committedOffset: CGSize = .zero

    func reset() {
        zoomScale = 1.0
        committedZoomScale = 1.0
        recenter()
    }

    /// Clears only pan state. Gesture cleanup uses this instead of a full image-session reset so
    /// it never changes the current zoom value.
    func recenter() {
        offset = .zero
        committedOffset = .zero
    }

    /// Applies the live magnification relative to the scale captured by the previous completed
    /// gesture. The dampening factor preserves the existing Develop trackpad response.
    func updateMagnification(_ magnification: CGFloat) {
        let dampened = 1.0 + (magnification - 1.0) * 0.4
        zoomScale = EditZoomBehavior.clampedScale(committedZoomScale * dampened)
    }

    /// Commits a magnification gesture. Returning to fit also recenters the preview and resets
    /// the next drag's anchor.
    func finishMagnification() {
        committedZoomScale = zoomScale
        if zoomScale <= 1.0 {
            recenter()
        }
    }

    /// Commits a discrete zoom (scroll or keyboard toggle) and its cursor-anchored offset.
    /// Supplying no offset retains the current pan, matching the no-geometry fallback path.
    func applyZoom(scale: CGFloat, anchoredOffset: CGSize? = nil) {
        let scale = EditZoomBehavior.clampedScale(scale)
        zoomScale = scale
        committedZoomScale = scale
        if scale <= 1.0 {
            recenter()
        } else if let anchoredOffset {
            offset = anchoredOffset
            committedOffset = anchoredOffset
        }
    }

    /// Updates a pan from the offset captured by the previous completed drag.
    @discardableResult
    func updatePan(translation: CGSize) -> Bool {
        guard zoomScale > 1.0 else { return false }
        offset = CGSize(
            width: committedOffset.width + translation.width,
            height: committedOffset.height + translation.height
        )
        return true
    }

    /// Clamps the live offset and makes it the anchor for the next pan gesture.
    func constrainOffset(maximum: CGSize) {
        guard zoomScale > 1.0 else {
            recenter()
            return
        }
        let maximumWidth = max(0, maximum.width)
        let maximumHeight = max(0, maximum.height)
        offset = CGSize(
            width: min(max(offset.width, -maximumWidth), maximumWidth),
            height: min(max(offset.height, -maximumHeight), maximumHeight)
        )
        committedOffset = offset
    }
}
