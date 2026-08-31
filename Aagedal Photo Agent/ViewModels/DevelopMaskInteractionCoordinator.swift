import Foundation
import Observation

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
}
