import CoreGraphics
import Foundation
import Observation

/// Immutable inputs for projecting Develop layer geometry between its durable sensor frame and
/// the current preview. The view supplies source facts; the interaction coordinator owns how
/// those facts affect masks, brush strokes, AI picks, and watermark placement.
struct DevelopLayerGeometryProjection: Equatable {
    var orientation: Int
    var displayImageSize: CGSize
    var crop: NormalizedCropRegion
    var straightenAngle: Double
    var zoomScale: CGFloat

    init(
        orientation: Int = 1,
        displayImageSize: CGSize = .zero,
        crop: NormalizedCropRegion = .full,
        straightenAngle: Double = 0,
        zoomScale: CGFloat = 1
    ) {
        self.orientation = orientation
        self.displayImageSize = displayImageSize
        self.crop = crop
        self.straightenAngle = straightenAngle
        self.zoomScale = zoomScale
    }

    var displayAspect: Double {
        guard displayImageSize.width > 0, displayImageSize.height > 0 else { return 1 }
        return displayImageSize.width / displayImageSize.height
    }
}

/// Owns the image-scoped, transient interaction state shared by Develop mask tools.
///
/// Brush parameters and paint-tool mode intentionally survive image changes because they describe
/// the next stroke, while an image-specific matte preview is terminated at every image boundary.
/// The view remains responsible for synchronizing these state transitions to the Metal pipeline.
@MainActor
@Observable
final class DevelopMaskInteractionCoordinator {
    private(set) var activeImageURL: URL?

    var isBrushPainting = false
    var brushRadius = 0.04
    var brushHardness = 0.5
    var brushFlow = 1.0
    var brushErase = false
    private(set) var mattePreviewMaskID: UUID?

    /// Binds image-specific interaction state to a new image while preserving the existing brush
    /// preferences and paint-tool mode.
    func beginImageSession(_ imageURL: URL?) {
        activeImageURL = imageURL
        mattePreviewMaskID = nil
    }

    func endImageSession() {
        beginImageSession(nil)
    }

    @discardableResult
    func toggleBrushPainting() -> Bool {
        isBrushPainting.toggle()
        return isBrushPainting
    }

    func beginBrushPainting() {
        isBrushPainting = true
    }

    func stopBrushPainting() {
        isBrushPainting = false
    }

    /// Layer changes always end a hover preview. Painting remains active only when the new
    /// selection is another brush mask, matching the editor's existing layer-strip behavior.
    func selectedLayerDidChange(isBrush: Bool) {
        mattePreviewMaskID = nil
        if !isBrush {
            isBrushPainting = false
        }
    }

    /// AI selection and other exclusive preview gestures must relinquish brush/matte input.
    func beginExclusiveSelection() {
        mattePreviewMaskID = nil
        isBrushPainting = false
    }

    /// Returns whether the requested hover transition changed the matte preview target.
    @discardableResult
    func setMattePreview(maskID: UUID, visible: Bool) -> Bool {
        let nextID: UUID?
        if visible {
            nextID = maskID
        } else {
            guard mattePreviewMaskID == maskID else { return false }
            nextID = nil
        }
        guard nextID != mattePreviewMaskID else { return false }
        mattePreviewMaskID = nextID
        return true
    }

    /// Returns whether a coordinator-owned matte preview was active.
    @discardableResult
    func clearMattePreview() -> Bool {
        guard mattePreviewMaskID != nil else { return false }
        mattePreviewMaskID = nil
        return true
    }
}

/// Owns the image-scoped transient geometry used while mask and watermark handles or their
/// inspector sliders are moving. The durable Camera Raw model is updated only when the view
/// consumes a final value, keeping high-frequency pointer state out of metadata persistence.
@MainActor
@Observable
final class DevelopLayerGeometryInteractionCoordinator {
    private(set) var activeImageURL: URL?
    var isDraggingMask = false
    var maskGeometry: EllipseMaskGeometry?
    var watermarkGeometry: WatermarkGeometry?

    func beginImageSession(_ imageURL: URL?) {
        activeImageURL = imageURL
        cancelInteractions()
    }

    func endImageSession() {
        beginImageSession(nil)
    }

    func beginMaskDrag() {
        isDraggingMask = true
    }

    func updateMaskGeometry(_ geometry: EllipseMaskGeometry?) {
        maskGeometry = geometry
    }

    func consumeMaskGeometry() -> EllipseMaskGeometry? {
        defer {
            maskGeometry = nil
            isDraggingMask = false
        }
        return maskGeometry
    }

    func endMaskOverride() {
        maskGeometry = nil
        isDraggingMask = false
    }

    func updateWatermarkGeometry(_ geometry: WatermarkGeometry?) {
        watermarkGeometry = geometry
    }

    func consumeWatermarkGeometry() -> WatermarkGeometry? {
        defer { watermarkGeometry = nil }
        return watermarkGeometry
    }

    func cancelInteractions() {
        isDraggingMask = false
        maskGeometry = nil
        watermarkGeometry = nil
    }

    /// Maps a preview-pane point into display-frame UV. Letterbox and invalid-geometry points
    /// are rejected so keyboard mask creation and AI selection share the overlay's hit contract.
    func displayUV(
        forPanePoint point: CGPoint,
        paneSize: CGSize,
        viewport: DevelopPreviewViewport
    ) -> CGPoint? {
        guard paneSize.width > 0, paneSize.height > 0,
              viewport.size.x > 0, viewport.size.y > 0 else { return nil }

        let x = Double(viewport.origin.x)
            + Double(point.x / paneSize.width) * Double(viewport.size.x)
        let y = Double(viewport.origin.y)
            + Double(point.y / paneSize.height) * Double(viewport.size.y)
        guard x >= 0, x < 1, y >= 0, y < 1 else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Durable sensor-frame ellipse to the preview's EXIF-oriented, straightened display frame.
    func maskForDisplay(
        _ geometry: EllipseMaskGeometry,
        projection: DevelopLayerGeometryProjection
    ) -> EllipseMaskGeometry {
        var result = geometry
        if projection.orientation > 1 {
            let sensorAspect = projection.orientation >= 5
                ? 1 / projection.displayAspect
                : projection.displayAspect
            result = result.transformedForDisplay(
                orientation: projection.orientation,
                sensorAspect: sensorAspect
            )
        }
        return result.rotatedInDisplay(
            byDegrees: -projection.straightenAngle,
            aspect: projection.displayAspect
        )
    }

    /// Exact inverse of `maskForDisplay`, suitable for the persisted XMP geometry.
    func maskForSensor(
        _ geometry: EllipseMaskGeometry,
        projection: DevelopLayerGeometryProjection
    ) -> EllipseMaskGeometry {
        var result = geometry.rotatedInDisplay(
            byDegrees: projection.straightenAngle,
            aspect: projection.displayAspect
        )
        if projection.orientation > 1 {
            result = result.transformedForSensor(
                orientation: projection.orientation,
                displayAspect: projection.displayAspect
            )
        }
        return result
    }

    func watermarkForDisplay(
        _ geometry: WatermarkGeometry,
        projection: DevelopLayerGeometryProjection,
        includesStraighten: Bool = true
    ) -> WatermarkGeometry {
        var result = projection.orientation > 1
            ? geometry.transformedForDisplay(orientation: projection.orientation)
            : geometry
        if includesStraighten {
            result = result.rotatedInDisplay(
                byDegrees: -projection.straightenAngle,
                aspect: projection.displayAspect
            )
        }
        return result
    }

    /// Exact inverse of `watermarkForDisplay`, suitable for the persisted XMP geometry.
    func watermarkForSensor(
        _ geometry: WatermarkGeometry,
        projection: DevelopLayerGeometryProjection,
        includesStraighten: Bool = true
    ) -> WatermarkGeometry {
        var result = includesStraighten
            ? geometry.rotatedInDisplay(
                byDegrees: projection.straightenAngle,
                aspect: projection.displayAspect
            )
            : geometry
        if projection.orientation > 1 {
            result = result.transformedForSensor(orientation: projection.orientation)
        }
        return result
    }

    /// Brush dabs use the same sensor/display orientation boundary as the other local masks.
    /// Straighten remains intentionally excluded to preserve the established brush behavior.
    func brushStrokeForSensor(
        _ stroke: BrushStroke,
        projection: DevelopLayerGeometryProjection
    ) -> BrushStroke {
        guard projection.orientation > 1 else { return stroke }
        let geometry = BrushMaskGeometry(strokes: [stroke])
            .transformedForSensor(orientation: projection.orientation)
        return geometry.strokes.first ?? stroke
    }

    /// Vision analyzes the un-straightened source, so reverse only the displayed straighten
    /// rotation after the common pane-to-viewport projection.
    func sourcePointForAIMask(
        fromDisplayedUV point: CGPoint,
        projection: DevelopLayerGeometryProjection
    ) -> CGPoint {
        var marker = WatermarkGeometry()
        marker.centerX = Double(point.x)
        marker.centerY = Double(point.y)
        marker = marker.rotatedInDisplay(
            byDegrees: projection.straightenAngle,
            aspect: projection.displayAspect
        )
        return CGPoint(
            x: min(max(marker.centerX, 0), 1),
            y: min(max(marker.centerY, 0), 1)
        )
    }

    func watermarkCropImageSize(
        projection: DevelopLayerGeometryProjection
    ) -> CGSize {
        CGSize(
            width: max(1, CGFloat(projection.crop.width) * projection.displayImageSize.width),
            height: max(1, CGFloat(projection.crop.height) * projection.displayImageSize.height)
        )
    }

    func watermarkCropContentRect(
        in containerSize: CGSize,
        projection: DevelopLayerGeometryProjection
    ) -> CGRect {
        let cropSize = watermarkCropImageSize(projection: projection)
        let availableWidth = max(containerSize.width, 1)
        let availableHeight = max(containerSize.height, 1)
        let fitScale = min(
            availableWidth / cropSize.width,
            availableHeight / cropSize.height
        ) * max(projection.zoomScale, 0.0001)
        let width = cropSize.width * fitScale
        let height = cropSize.height * fitScale
        return CGRect(
            x: (containerSize.width - width) * 0.5,
            y: (containerSize.height - height) * 0.5,
            width: width,
            height: height
        )
    }

    /// Re-clamps a watermark after its own size or margin changes. Confirmed crops use the
    /// crop-sized frame and omit straighten because the Metal crop viewport already supplies it.
    func watermarkClampingOwnPosition(
        _ geometry: WatermarkGeometry,
        assetAspect: Double,
        usesCropFrame: Bool,
        projection: DevelopLayerGeometryProjection
    ) -> WatermarkGeometry {
        guard projection.displayImageSize.width > 0,
              projection.displayImageSize.height > 0 else { return geometry }
        let referenceSize = usesCropFrame
            ? watermarkCropImageSize(projection: projection)
            : projection.displayImageSize
        let display = watermarkForDisplay(
            geometry,
            projection: projection,
            includesStraighten: !usesCropFrame
        ).clamped(
            assetAspect: assetAspect,
            imageWidth: referenceSize.width,
            imageHeight: referenceSize.height
        )
        return watermarkForSensor(
            display,
            projection: projection,
            includesStraighten: !usesCropFrame
        )
    }
}
