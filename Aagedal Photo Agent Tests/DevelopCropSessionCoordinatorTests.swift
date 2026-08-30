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
}
