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

        // A tool left open across navigation has no snapshot for the next image.
        #expect(coordinator.toggleTool())
        coordinator.captureEntryCrop(entry)
        coordinator.beginImageSession(URL(fileURLWithPath: "/tmp/develop-crop-next.raw"), isCropEnabled: true)
        #expect(coordinator.isToolActive)
        #expect(coordinator.cancelTool() == nil)
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
