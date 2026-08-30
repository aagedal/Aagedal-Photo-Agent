import CoreGraphics
import Foundation
import Observation

/// Tells the Develop workspace whether a crop-state mutation belongs in the durable Develop
/// record. Rendering remains immediate in the view, while this explicit result keeps gesture
/// previews from accidentally crossing the XMP/named-version persistence boundary.
nonisolated enum DevelopCropPersistenceIntent: Equatable, Sendable {
    case previewOnly
    case commit
}

struct DevelopCropDragSnapshot: Equatable {
    let angle: Double?
    let region: NormalizedCropRegion?
}

/// Owns crop-tool presentation and image-scoped interaction state for the Develop workspace.
///
/// The coordinator deliberately does not write XMP or named-version JSON. It mutates the value
/// passed across its settings boundary and returns a persistence intent; the workspace chooses
/// the active persistence destination. Pointer cancellation, tool teardown, and navigation all
/// share the same image-session lifetime, so transient straighten geometry cannot leak to the
/// next image.
@MainActor
@Observable
final class DevelopCropSessionCoordinator {
    private(set) var activeImageURL: URL?
    var isToolActive = false
    var zoomScale: CGFloat = 1
    var lastZoomScale: CGFloat = 1
    var aspectRatio: CropAspectRatio = .original
    var lockedImageRect: CGRect?
    private(set) var dragAngle: Double?
    private(set) var dragRegion: NormalizedCropRegion?

    func beginImageSession(_ imageURL: URL?, isCropEnabled: Bool) {
        activeImageURL = imageURL
        resetPreviewZoom()
        cancelInteraction()
        if !isCropEnabled {
            isToolActive = false
        }
    }

    func endImageSession() {
        activeImageURL = nil
        isToolActive = false
        aspectRatio = .original
        resetPreviewZoom()
        cancelInteraction()
    }

    @discardableResult
    func toggleTool() -> Bool {
        isToolActive.toggle()
        if !isToolActive {
            resetPreviewZoom()
            cancelInteraction()
        }
        return isToolActive
    }

    func resetPreviewZoom() {
        zoomScale = 1
        lastZoomScale = 1
    }

    func updateAngleDragPreview(
        _ angle: Double,
        activeCrop: NormalizedCropRegion,
        sourceAspectRatio: Double
    ) {
        let clampedAngle = min(max(angle, -45), 45)
        dragAngle = clampedAngle
        dragRegion = activeCrop
            .centerClampedForRotation(
                angleDegrees: clampedAngle,
                aspectRatio: sourceAspectRatio
            )
            .fittingRotated(
                angleDegrees: clampedAngle,
                aspectRatio: sourceAspectRatio
            )
    }

    func updateCropDrag(_ region: NormalizedCropRegion) {
        dragRegion = region
    }

    func updateAngleDrag(_ angle: Double, region: NormalizedCropRegion) {
        dragAngle = angle
        dragRegion = region
    }

    /// Returns the final drag values exactly once and releases all gesture-only geometry.
    @discardableResult
    func finishInteraction() -> DevelopCropDragSnapshot {
        let snapshot = DevelopCropDragSnapshot(angle: dragAngle, region: dragRegion)
        dragAngle = nil
        dragRegion = nil
        lockedImageRect = nil
        return snapshot
    }

    func cancelInteraction() {
        dragAngle = nil
        dragRegion = nil
        lockedImageRect = nil
    }

    @discardableResult
    func enableCropIfNeeded(
        in settings: inout CameraRawSettings
    ) -> DevelopCropPersistenceIntent {
        guard settings.crop?.hasCrop != true else { return .previewOnly }
        var crop = settings.crop ?? CameraRawCrop()
        crop.hasCrop = true
        if crop.top == nil { crop.top = 0 }
        if crop.left == nil { crop.left = 0 }
        if crop.bottom == nil { crop.bottom = 1 }
        if crop.right == nil { crop.right = 1 }
        if crop.angle == nil { crop.angle = 0 }
        settings.crop = crop
        return .commit
    }

    @discardableResult
    func resetCrop(
        in settings: inout CameraRawSettings
    ) -> DevelopCropPersistenceIntent {
        settings.crop = CameraRawCrop(
            top: 0,
            left: 0,
            bottom: 1,
            right: 1,
            angle: 0,
            hasCrop: false
        )
        aspectRatio = .original
        isToolActive = false
        resetPreviewZoom()
        cancelInteraction()
        return .commit
    }

    @discardableResult
    func updateCrop(
        _ crop: NormalizedCropRegion,
        sourceAspectRatio: Double,
        orientation: Int,
        commit: Bool,
        in settings: inout CameraRawSettings
    ) -> DevelopCropPersistenceIntent {
        let angle = settings.crop?.angle ?? 0
        let normalized = crop.fittingRotated(
            angleDegrees: angle,
            aspectRatio: sourceAspectRatio
        )
        let displayCrop = CameraRawCrop(
            top: normalized.top,
            left: normalized.left,
            bottom: normalized.bottom,
            right: normalized.right,
            angle: angle,
            hasCrop: true
        )
        settings.crop = displayCrop.transformedForSensor(orientation: orientation)
        return commit ? .commit : .previewOnly
    }

    @discardableResult
    func updateCropAngle(
        _ angle: Double,
        sourceAspectRatio: Double,
        orientation: Int,
        commit: Bool,
        in settings: inout CameraRawSettings
    ) -> DevelopCropPersistenceIntent {
        let clampedAngle = min(max(angle, -45), 45)
        let sensorCrop = settings.crop ?? CameraRawCrop(
            top: 0,
            left: 0,
            bottom: 1,
            right: 1,
            angle: 0,
            hasCrop: true
        )
        let displayCrop = sensorCrop.transformedForDisplay(orientation: orientation)
        let region = NormalizedCropRegion(
            top: displayCrop.top ?? 0,
            left: displayCrop.left ?? 0,
            bottom: displayCrop.bottom ?? 1,
            right: displayCrop.right ?? 1
        )
        .centerClampedForRotation(
            angleDegrees: clampedAngle,
            aspectRatio: sourceAspectRatio
        )
        .fittingRotated(
            angleDegrees: clampedAngle,
            aspectRatio: sourceAspectRatio
        )

        let updatedDisplay = CameraRawCrop(
            top: region.top,
            left: region.left,
            bottom: region.bottom,
            right: region.right,
            angle: (clampedAngle * 1_000_000).rounded() / 1_000_000,
            hasCrop: true
        )
        settings.crop = updatedDisplay.transformedForSensor(orientation: orientation)
        return commit ? .commit : .previewOnly
    }
}
