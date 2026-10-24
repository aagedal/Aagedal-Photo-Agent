import CoreGraphics
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop crop session coordinator")
@MainActor
struct DevelopCropSessionCoordinatorTests {
    @Test("image replacement cancels crop interaction without closing an enabled tool")
    func imageReplacementCancelsInteraction() {
        let first = URL(fileURLWithPath: "/tmp/develop-crop-first.raw")
        let second = URL(fileURLWithPath: "/tmp/develop-crop-second.raw")
        let coordinator = DevelopCropSessionCoordinator()
        coordinator.beginImageSession(first, isCropEnabled: false)
        #expect(coordinator.toggleTool())
        coordinator.aspectRatio = .ratio16x9
        coordinator.zoomScale = 2.25
        coordinator.lastZoomScale = 2.25
        coordinator.lockedImageRect = CGRect(x: 1, y: 2, width: 30, height: 40)
        coordinator.updateAngleDrag(
            12,
            region: NormalizedCropRegion(top: 0.1, left: 0.2, bottom: 0.8, right: 0.9)
        )

        coordinator.beginImageSession(second, isCropEnabled: true)

        #expect(coordinator.activeImageURL == second)
        #expect(coordinator.isToolActive)
        #expect(coordinator.aspectRatio == .ratio16x9)
        #expect(coordinator.zoomScale == 1)
        #expect(coordinator.lastZoomScale == 1)
        #expect(coordinator.lockedImageRect == nil)
        #expect(coordinator.dragAngle == nil)
        #expect(coordinator.dragRegion == nil)
    }

    @Test("image replacement closes crop controls when the new image has no crop")
    func imageReplacementClosesInactiveCrop() {
        let coordinator = DevelopCropSessionCoordinator()
        coordinator.beginImageSession(
            URL(fileURLWithPath: "/tmp/develop-crop-enabled.raw"),
            isCropEnabled: true
        )
        _ = coordinator.toggleTool()
        #expect(coordinator.isToolActive)

        coordinator.beginImageSession(
            URL(fileURLWithPath: "/tmp/develop-crop-plain.raw"),
            isCropEnabled: false
        )

        #expect(!coordinator.isToolActive)
    }

    @Test("finishing a drag publishes one snapshot and cancels its transient state")
    func finishDragConsumesSnapshot() {
        let coordinator = DevelopCropSessionCoordinator()
        let crop = NormalizedCropRegion(top: 0.15, left: 0.2, bottom: 0.75, right: 0.8)
        coordinator.lockedImageRect = CGRect(x: 10, y: 20, width: 100, height: 80)
        coordinator.updateAngleDrag(7.5, region: crop)

        let first = coordinator.finishInteraction()
        let second = coordinator.finishInteraction()

        #expect(first == DevelopCropDragSnapshot(angle: 7.5, region: crop))
        #expect(second == DevelopCropDragSnapshot(angle: nil, region: nil))
        #expect(coordinator.lockedImageRect == nil)
    }

    @Test("crop settings boundary distinguishes preview changes from durable commits")
    func settingsMutationPersistenceIntent() {
        let coordinator = DevelopCropSessionCoordinator()
        var settings = CameraRawSettings()

        let enable = coordinator.enableCropIfNeeded(in: &settings)
        #expect(enable == .commit)
        #expect(settings.crop?.top == 0)
        #expect(settings.crop?.left == 0)
        #expect(settings.crop?.bottom == 1)
        #expect(settings.crop?.right == 1)
        #expect(settings.crop?.angle == 0)
        #expect(settings.crop?.hasCrop == true)
        #expect(coordinator.enableCropIfNeeded(in: &settings) == .previewOnly)

        let preview = coordinator.updateCrop(
            NormalizedCropRegion(top: 0.1, left: 0.15, bottom: 0.8, right: 0.9),
            sourceAspectRatio: 3.0 / 2.0,
            orientation: 1,
            commit: false,
            in: &settings
        )
        #expect(preview == .previewOnly)
        #expect(settings.crop?.hasCrop == true)

        let committed = coordinator.updateCropAngle(
            90,
            sourceAspectRatio: 3.0 / 2.0,
            orientation: 1,
            commit: true,
            in: &settings
        )
        #expect(committed == .commit)
        #expect(settings.crop?.angle == 45)

        // With the tool closed, Reset clears the crop entirely.
        #expect(coordinator.resetCrop(in: &settings) == .commit)
        #expect(settings.crop?.hasCrop == false)
        #expect(coordinator.aspectRatio == .original)
        #expect(!coordinator.isToolActive)
    }

    @Test("edit workspace delegates crop state and lifecycle to the coordinator")
    func editWorkspaceSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("@State private var cropSession = DevelopCropSessionCoordinator()"))
        #expect(source.contains("cropSession.beginImageSession(selectedImageURL, isCropEnabled: isCropEnabled)"))
        #expect(source.contains("cropSession.endImageSession()"))
        #expect(source.contains("cropSession.enableCropIfNeeded(in: &cameraRaw)"))
        #expect(source.contains("cropSession.updateCropAngle("))
        #expect(!source.contains("@State private var cropZoomScale"))
        #expect(!source.contains("@State private var showCropControls"))
        #expect(!source.contains("@State private var dragCropAngle"))
        #expect(!source.contains("@State private var lockedCropImageRect"))
    }

    @Test("Esc cancel restores the crop captured on entry; Done and navigation drop it")
    func cancelRestoresEntryCrop() {
        let image = URL(fileURLWithPath: "/tmp/develop-crop-cancel.raw")
        let entry = CameraRawCrop(top: 0.1, left: 0.2, bottom: 0.8, right: 0.9, angle: 3.5, hasCrop: true)
        let coordinator = DevelopCropSessionCoordinator()
        coordinator.beginImageSession(image, isCropEnabled: true)

        // Capture is ignored while the tool is closed.
        coordinator.captureEntryCrop(entry)
        #expect(coordinator.entrySnapshot == nil)

        #expect(coordinator.toggleTool())
        coordinator.captureEntryCrop(entry)
        coordinator.zoomScale = 2
        coordinator.updateAngleDrag(9, region: NormalizedCropRegion(top: 0, left: 0, bottom: 1, right: 1))

        let restored = coordinator.cancelTool()
        #expect(restored == DevelopCropEntrySnapshot(crop: entry))
        #expect(!coordinator.isToolActive)
        #expect(coordinator.entrySnapshot == nil)
        #expect(coordinator.zoomScale == 1)
        #expect(coordinator.dragAngle == nil)
        #expect(coordinator.dragRegion == nil)

        // A crop-less image restores "no crop" (nil), distinct from "no snapshot".
        #expect(coordinator.toggleTool())
        coordinator.captureEntryCrop(nil)
        #expect(coordinator.cancelTool() == DevelopCropEntrySnapshot(crop: nil))

        // The full-frame crop the tool enabled on entry is remembered with the snapshot, so an
        // untouched session can undo that step; without a snapshot nothing is recorded.
        let fullFrame = CameraRawCrop(top: 0, left: 0, bottom: 1, right: 1, angle: 0, hasCrop: true)
        coordinator.recordAutoEnabledCrop(fullFrame)
        #expect(coordinator.entrySnapshot == nil)
        #expect(coordinator.toggleTool())
        coordinator.captureEntryCrop(nil)
        coordinator.recordAutoEnabledCrop(fullFrame)
        #expect(coordinator.cancelTool() == DevelopCropEntrySnapshot(crop: nil, autoEnabledCrop: fullFrame))

        // Done keeps the edit: the snapshot is discarded.
        #expect(coordinator.toggleTool())
        coordinator.captureEntryCrop(entry)
        #expect(!coordinator.toggleTool())
        #expect(coordinator.entrySnapshot == nil)

        // A tool left open across navigation has no snapshot until the next image's own
        // settings load; then it adopts that image's framing for Esc.
        #expect(coordinator.toggleTool())
        coordinator.captureEntryCrop(entry)
        coordinator.beginImageSession(URL(fileURLWithPath: "/tmp/develop-crop-next.raw"), isCropEnabled: true)
        #expect(coordinator.isToolActive)
        #expect(coordinator.entrySnapshot == nil)
        let nextCrop = CameraRawCrop(top: 0.2, left: 0.1, bottom: 0.9, right: 0.7, angle: -1, hasCrop: true)
        #expect(coordinator.adoptLoadedPhoto(crop: nextCrop, isCropEnabled: true))
        #expect(!coordinator.adoptLoadedPhoto(crop: nil, isCropEnabled: false))
        #expect(coordinator.cancelTool() == DevelopCropEntrySnapshot(crop: nextCrop))
    }

    @Test("an open tool closes when the next photo turns out to have no crop")
    func openToolClosesForUncroppedLoadedPhoto() {
        let coordinator = DevelopCropSessionCoordinator()
        coordinator.beginImageSession(URL(fileURLWithPath: "/tmp/develop-crop-a.raw"), isCropEnabled: true)
        #expect(coordinator.toggleTool())
        // The stale buffer still describes the previous (cropped) photo during navigation.
        coordinator.beginImageSession(URL(fileURLWithPath: "/tmp/develop-crop-b.raw"), isCropEnabled: true)
        #expect(coordinator.isToolActive)
        #expect(!coordinator.adoptLoadedPhoto(crop: nil, isCropEnabled: false))
        #expect(!coordinator.isToolActive)
        // A same-image session restart (preview reload) keeps the entry snapshot.
        #expect(coordinator.toggleTool())
        let entry = CameraRawCrop(top: 0.1, left: 0.1, bottom: 0.9, right: 0.9, angle: 0, hasCrop: true)
        coordinator.captureEntryCrop(entry)
        coordinator.beginImageSession(URL(fileURLWithPath: "/tmp/develop-crop-b.raw"), isCropEnabled: true)
        #expect(coordinator.entrySnapshot == DevelopCropEntrySnapshot(crop: entry))
    }

    @Test("Reset inside an open crop tool keeps the tool open on the full frame")
    func resetKeepsOpenToolOpen() {
        let coordinator = DevelopCropSessionCoordinator()
        coordinator.beginImageSession(URL(fileURLWithPath: "/tmp/develop-crop-reset.raw"), isCropEnabled: true)
        #expect(coordinator.toggleTool())
        let entry = CameraRawCrop(top: 0.1, left: 0.2, bottom: 0.8, right: 0.9, angle: 4, hasCrop: true)
        coordinator.captureEntryCrop(entry)
        var settings = CameraRawSettings()
        settings.crop = entry

        #expect(coordinator.resetCrop(in: &settings) == .commit)
        #expect(coordinator.isToolActive)
        #expect(settings.crop == CameraRawCrop(top: 0, left: 0, bottom: 1, right: 1, angle: 0, hasCrop: true))
        // Esc after Reset still restores the framing the tool was opened on.
        #expect(coordinator.cancelTool() == DevelopCropEntrySnapshot(crop: entry))
    }

    @Test("Re-entering crop selects the preset the existing crop already has")
    func aspectPresetMatchesExistingCrop() {
        let landscape = 3.0 / 2.0
        // Full frame of a 3:2 image is "Original".
        #expect(CropAspectRatio.matching(.full, imageAspectRatio: landscape) == .original)
        // A 16:9 crop on a 3:2 image: normalized width/height = (16/9) / 1.5.
        let wide = NormalizedCropRegion(top: 0.1, left: 0, bottom: 0.1 + 1.5 / (16.0 / 9.0), right: 1)
        #expect(CropAspectRatio.matching(wide, imageAspectRatio: landscape) == .ratio16x9)
        // A square crop.
        let square = NormalizedCropRegion(top: 0, left: 0.2, bottom: 0.9, right: 0.2 + 0.9 / landscape)
        #expect(CropAspectRatio.matching(square, imageAspectRatio: landscape) == .square)
        // Portrait 2:3 crop on a landscape image picks the portrait preset, not 3:2.
        let portrait = NormalizedCropRegion(top: 0, left: 0.3, bottom: 1, right: 0.3 + (2.0 / 3.0) / landscape)
        #expect(CropAspectRatio.matching(portrait, imageAspectRatio: landscape) == .ratio2x3)
        // On a portrait image, its own shape is "Original" and a 3:2 landscape crop is 3:2.
        let portraitImage = 2.0 / 3.0
        #expect(CropAspectRatio.matching(.full, imageAspectRatio: portraitImage) == .original)
        let landscapeOnPortrait = NormalizedCropRegion(top: 0.3, left: 0, bottom: 0.3 + portraitImage / 1.5, right: 1)
        #expect(CropAspectRatio.matching(landscapeOnPortrait, imageAspectRatio: portraitImage) == .ratio3x2)
        // Anything else is Free, so entering the tool never reshapes it.
        let odd = NormalizedCropRegion(top: 0.1, left: 0.1, bottom: 0.73, right: 0.9)
        #expect(CropAspectRatio.matching(odd, imageAspectRatio: landscape) == .free)
    }

    @Test("Develop routes Esc in crop mode through cancel and Load Embedded Crop through undo")
    func escapeAndEmbeddedCropSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"
            ),
            encoding: .utf8
        )
        #expect(source.contains("cropSession.captureEntryCrop(entryCrop)"))
        #expect(source.contains("if showCropControls {\n                cancelCropControls()"))
        #expect(source.contains("whiteBalanceSession.deactivatePicker()\n                return nil"))
        #expect(source.contains("maskInteraction.stopBrushPainting()\n                syncMaskOverlayTarget()\n                return nil"))
        #expect(source.contains("guard !workspaceInput.isOverlayPresented,"))
        // Embedded crop import is an undoable, version-aware Develop mutation.
        #expect(!source.contains("metadataViewModel.importEmbeddedCrop()"))
        #expect(source.contains("metadataViewModel.embeddedCropForImport"))
    }
}
