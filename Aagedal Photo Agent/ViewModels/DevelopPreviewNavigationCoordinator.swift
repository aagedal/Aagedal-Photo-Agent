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

/// The normalized source region sampled by the Develop preview. Keeping the paired values in
/// one result prevents the Metal and Core Image presentation paths from observing geometry
/// calculated from different zoom/pan snapshots.
nonisolated struct DevelopPreviewViewport: Equatable, Sendable {
    let origin: SIMD2<Float>
    let size: SIMD2<Float>

    static let identity = DevelopPreviewViewport(
        origin: .zero,
        size: SIMD2<Float>(1, 1)
    )
}

/// Owns the transient zoom and pan session for the normal Develop preview.
///
/// Metal publication remains at the view boundary. This coordinator owns the paired
/// live/committed values and the geometry derived from them, so image changes, fit-view resets,
/// gesture completion, and cropped-preview framing cannot observe mismatched zoom/pan snapshots.
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

    /// Applies ordinary preview zoom while keeping the source point beneath the cursor fixed.
    /// Invalid geometry retains the requested zoom but deliberately drops anchoring.
    func applyZoom(
        scale: CGFloat,
        preserving cursorFromCenter: CGSize,
        containerSize: CGSize,
        imageSize: CGSize
    ) {
        let targetScale = EditZoomBehavior.clampedScale(scale)
        guard targetScale > 1,
              Self.hasArea(containerSize), Self.hasArea(imageSize) else {
            applyZoom(scale: targetScale)
            return
        }

        let cursorX = 0.5 + cursorFromCenter.width / containerSize.width
        let cursorY = 0.5 + cursorFromCenter.height / containerSize.height
        let currentViewport = viewport(containerSize: containerSize, imageSize: imageSize)
        let sourceX = Double(currentViewport.origin.x)
            + Double(cursorX) * Double(currentViewport.size.x)
        let sourceY = Double(currentViewport.origin.y)
            + Double(cursorY) * Double(currentViewport.size.y)
        let targetSize = Self.viewportSize(
            containerSize: containerSize,
            imageSize: imageSize,
            zoomScale: targetScale
        )
        let targetOriginX = sourceX - Double(cursorX) * Double(targetSize.x)
        let targetOriginY = sourceY - Double(cursorY) * Double(targetSize.y)

        let fittedScale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let fittedWidth = imageSize.width * fittedScale
        let fittedHeight = imageSize.height * fittedScale
        let offsetX = 0.5 - Double(targetSize.x) / 2 - targetOriginX
        let offsetY = 0.5 - Double(targetSize.y) / 2 - targetOriginY
        applyZoom(
            scale: targetScale,
            anchoredOffset: CGSize(
                width: offsetX * fittedWidth * targetScale,
                height: offsetY * fittedHeight * targetScale
            )
        )
        constrainOffset(maximum: maximumOffset(containerSize: containerSize, imageSize: imageSize))
    }

    /// Applies cropped-preview zoom with the established view-space cursor anchor. Crop geometry
    /// supplies the final pan limits separately after this state transition.
    func applyCropZoom(scale: CGFloat, preserving cursorFromCenter: CGSize) {
        let targetScale = EditZoomBehavior.clampedScale(scale)
        guard targetScale > 1 else {
            applyZoom(scale: targetScale)
            return
        }
        let zoomRatio = targetScale / zoomScale
        applyZoom(
            scale: targetScale,
            anchoredOffset: CGSize(
                width: cursorFromCenter.width
                    - (cursorFromCenter.width - offset.width) * zoomRatio,
                height: cursorFromCenter.height
                    - (cursorFromCenter.height - offset.height) * zoomRatio
            )
        )
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

    /// Returns the normalized viewport used by both the Metal preview and its Core Image
    /// fallback. Values outside 0...1 deliberately represent fitted letterboxing.
    func viewport(containerSize: CGSize, imageSize: CGSize) -> DevelopPreviewViewport {
        guard Self.hasArea(containerSize), Self.hasArea(imageSize) else { return .identity }

        let size = Self.viewportSize(
            containerSize: containerSize,
            imageSize: imageSize,
            zoomScale: zoomScale
        )
        let viewportWidth = CGFloat(size.x)
        let viewportHeight = CGFloat(size.y)

        let fittedScale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let fittedWidth = imageSize.width * fittedScale
        let fittedHeight = imageSize.height * fittedScale
        let offsetX = offset.width / (fittedWidth * zoomScale)
        let offsetY = offset.height / (fittedHeight * zoomScale)

        return DevelopPreviewViewport(
            origin: SIMD2<Float>(
                Float(0.5 - offsetX - viewportWidth / 2),
                Float(0.5 - offsetY - viewportHeight / 2)
            ),
            size: SIMD2<Float>(Float(viewportWidth), Float(viewportHeight))
        )
    }

    /// Returns the normalized source viewport for a confirmed crop. Pan is converted from view
    /// points back through the crop fit scale and crop-straighten rotation before being applied
    /// in source space.
    func cropViewport(
        containerSize: CGSize,
        imageSize: CGSize,
        crop: NormalizedCropRegion,
        angleDegrees: Double,
        handlePadding: CGFloat = 0
    ) -> DevelopPreviewViewport {
        guard Self.hasArea(containerSize), Self.hasArea(imageSize) else { return .identity }

        let imageWidth = Double(imageSize.width)
        let imageHeight = Double(imageSize.height)
        let actualWidth = max(crop.width, 0.0001) * imageWidth
        let actualHeight = max(crop.height, 0.0001) * imageHeight
        let availableWidth = max(Double(containerSize.width - handlePadding * 2), 1)
        let availableHeight = max(Double(containerSize.height - handlePadding * 2), 1)
        let fitScale = min(
            availableWidth / max(actualWidth, 1),
            availableHeight / max(actualHeight, 1)
        ) * max(Double(zoomScale), 0.0001)
        guard fitScale > 0, fitScale.isFinite else { return .identity }

        let viewportWidth = Double(containerSize.width) / fitScale / imageWidth
        let viewportHeight = Double(containerSize.height) / fitScale / imageHeight
        let radians = angleDegrees * .pi / 180
        let offsetX = Double(offset.width) / fitScale
        let offsetY = Double(offset.height) / fitScale
        let rotatedOffsetX = offsetX * cos(radians) - offsetY * sin(radians)
        let rotatedOffsetY = offsetX * sin(radians) + offsetY * cos(radians)
        let centerX = crop.centerX - rotatedOffsetX / imageWidth
        let centerY = crop.centerY - rotatedOffsetY / imageHeight

        return DevelopPreviewViewport(
            origin: SIMD2<Float>(
                Float(centerX - viewportWidth / 2),
                Float(centerY - viewportHeight / 2)
            ),
            size: SIMD2<Float>(Float(viewportWidth), Float(viewportHeight))
        )
    }

    /// Frames the full source so the upright crop fills the available preview, then rotates the
    /// crop-center offset into view space. Crop-tool zoom can be supplied independently from the
    /// coordinator's normal Develop zoom.
    func cropFittedImageRect(
        containerSize: CGSize,
        imageSize: CGSize,
        crop: NormalizedCropRegion,
        angleDegrees: Double,
        zoomScale overrideZoomScale: CGFloat? = nil,
        handlePadding: CGFloat = 0
    ) -> CGRect {
        guard Self.hasArea(containerSize), Self.hasArea(imageSize) else { return .zero }

        let availableWidth = max(containerSize.width - handlePadding * 2, 1)
        let availableHeight = max(containerSize.height - handlePadding * 2, 1)
        let actualWidth = crop.width * imageSize.width
        let actualHeight = crop.height * imageSize.height
        let baseScale = min(
            availableWidth / max(actualWidth, 1),
            availableHeight / max(actualHeight, 1)
        )
        let scale = baseScale * (overrideZoomScale ?? zoomScale)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let cropOffsetX = (crop.centerX - 0.5) * width
        let cropOffsetY = (crop.centerY - 0.5) * height
        let viewAngle = -angleDegrees * .pi / 180
        let viewOffsetX = cropOffsetX * cos(viewAngle) - cropOffsetY * sin(viewAngle)
        let viewOffsetY = cropOffsetX * sin(viewAngle) + cropOffsetY * cos(viewAngle)
        let midpointX = containerSize.width * 0.5 - viewOffsetX
        let midpointY = containerSize.height * 0.5 - viewOffsetY

        return CGRect(
            x: midpointX - width * 0.5,
            y: midpointY - height * 0.5,
            width: width,
            height: height
        )
    }

    /// Computes the pan bounds for a confirmed crop from the same fitted geometry used to draw
    /// it. The crop rectangle stays upright while its center follows the straighten rotation.
    func cropMaximumOffset(
        containerSize: CGSize,
        imageSize: CGSize,
        crop: NormalizedCropRegion,
        angleDegrees: Double,
        handlePadding: CGFloat = 0
    ) -> CGSize {
        let imageRect = cropFittedImageRect(
            containerSize: containerSize,
            imageSize: imageSize,
            crop: crop,
            angleDegrees: angleDegrees,
            handlePadding: handlePadding
        )
        guard imageRect != .zero else { return .zero }

        let angle = -angleDegrees * .pi / 180
        let centerOffsetX = (crop.centerX - 0.5) * imageRect.width
        let centerOffsetY = (crop.centerY - 0.5) * imageRect.height
        let centerX = centerOffsetX * cos(angle) - centerOffsetY * sin(angle) + imageRect.midX
        let centerY = centerOffsetX * sin(angle) + centerOffsetY * cos(angle) + imageRect.midY
        let cropRect = CGRect(
            x: centerX - crop.width * imageRect.width / 2,
            y: centerY - crop.height * imageRect.height / 2,
            width: max(2, crop.width * imageRect.width),
            height: max(2, crop.height * imageRect.height)
        )
        return Self.maximumOffset(for: cropRect.size, in: containerSize)
    }

    /// Computes ordinary fit-view pan bounds at the current zoom.
    func maximumOffset(containerSize: CGSize, imageSize: CGSize) -> CGSize {
        guard Self.hasArea(containerSize), Self.hasArea(imageSize) else { return .zero }
        let fittedScale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        return Self.maximumOffset(
            for: CGSize(
                width: imageSize.width * fittedScale * zoomScale,
                height: imageSize.height * fittedScale * zoomScale
            ),
            in: containerSize
        )
    }

    private nonisolated static func hasArea(_ size: CGSize) -> Bool {
        size.width > 0 && size.height > 0
    }

    private nonisolated static func viewportSize(
        containerSize: CGSize,
        imageSize: CGSize,
        zoomScale: CGFloat
    ) -> SIMD2<Float> {
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height
        if containerAspect > imageAspect {
            return SIMD2<Float>(
                Float((1 / zoomScale) * (containerAspect / imageAspect)),
                Float(1 / zoomScale)
            )
        }
        return SIMD2<Float>(
            Float(1 / zoomScale),
            Float((1 / zoomScale) * (imageAspect / containerAspect))
        )
    }

    private nonisolated static func maximumOffset(for contentSize: CGSize, in containerSize: CGSize) -> CGSize {
        CGSize(
            width: max(0, (contentSize.width - containerSize.width) / 2),
            height: max(0, (contentSize.height - containerSize.height) / 2)
        )
    }
}
