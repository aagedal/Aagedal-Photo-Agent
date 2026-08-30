import CoreGraphics
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop white-balance session coordinator")
@MainActor
struct DevelopWhiteBalanceSessionCoordinatorTests {
    @Test("image lifecycle clears picker state and rejects stale neutral publication")
    func imageLifecycleRejectsStaleNeutral() {
        let first = URL(fileURLWithPath: "/tmp/develop-wb-first.raw")
        let second = URL(fileURLWithPath: "/tmp/develop-wb-second.raw")
        let coordinator = DevelopWhiteBalanceSessionCoordinator()

        coordinator.beginImageSession(first)
        #expect(coordinator.togglePicker())
        coordinator.dragRectangle = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(coordinator.publishAsShotNeutral(temperature: 5_200, tint: 7, for: first))

        coordinator.beginImageSession(second)

        #expect(coordinator.activeImageURL == second)
        #expect(!coordinator.isPickerActive)
        #expect(coordinator.dragRectangle == nil)
        #expect(coordinator.asShotNeutral == nil)
        #expect(!coordinator.publishAsShotNeutral(temperature: 4_000, tint: -2, for: first))
        #expect(coordinator.asShotTemperatureKelvin == 6_500)
        #expect(coordinator.asShotTint == 0)

        #expect(coordinator.publishAsShotNeutral(temperature: 5_600, tint: 3, for: second))
        #expect(coordinator.asShotTemperatureKelvin == 5_600)
        #expect(coordinator.asShotTint == 3)
    }

    @Test("picker requests reject replacement, deactivation, and image-session results")
    func pickerRequestIdentity() throws {
        let first = URL(fileURLWithPath: "/tmp/develop-wb-picker-first.raw")
        let second = URL(fileURLWithPath: "/tmp/develop-wb-picker-second.raw")
        let coordinator = DevelopWhiteBalanceSessionCoordinator()

        coordinator.beginImageSession(first)
        #expect(coordinator.togglePicker())
        let stale = try #require(coordinator.beginPickRequest())
        let current = try #require(coordinator.beginPickRequest())
        #expect(!coordinator.consumePickResult(requestID: stale.id, imageURL: first))
        #expect(coordinator.consumePickResult(requestID: current.id, imageURL: first))
        #expect(!coordinator.consumePickResult(requestID: current.id, imageURL: first))

        let deactivated = try #require(coordinator.beginPickRequest())
        coordinator.deactivatePicker()
        #expect(!coordinator.consumePickResult(requestID: deactivated.id, imageURL: first))

        #expect(coordinator.togglePicker())
        let previousImage = try #require(coordinator.beginPickRequest())
        coordinator.beginImageSession(second)
        #expect(!coordinator.consumePickResult(requestID: previousImage.id, imageURL: first))
    }

    @Test("pane projection clamps viewport UVs and flips into Core Image coordinates")
    func sourceRegionProjection() throws {
        let coordinator = DevelopWhiteBalanceSessionCoordinator()
        let region = coordinator.sourceRegion(
            forPaneRect: CGRect(x: -10, y: 25, width: 70, height: 50),
            paneSize: CGSize(width: 100, height: 100),
            viewportOrigin: SIMD2<Float>(0.25, 0.1),
            viewportSize: SIMD2<Float>(0.5, 0.8),
            sourceExtent: CGRect(x: 10, y: 20, width: 400, height: 200)
        )

        let projected = try #require(region)
        #expect(abs(projected.minX - 90) < 0.001)
        #expect(abs(projected.minY - 80) < 0.001)
        #expect(abs(projected.width - 140) < 0.001)
        #expect(abs(projected.height - 80) < 0.001)
        #expect(coordinator.sourceRegion(
            forPaneRect: CGRect(x: 2, y: 2, width: 0, height: 4),
            paneSize: CGSize(width: 100, height: 100),
            viewportOrigin: .zero,
            viewportSize: SIMD2<Float>(1, 1),
            sourceExtent: CGRect(x: 0, y: 0, width: 100, height: 100)
        ) == nil)
    }

    @Test("picked RAW white balance clamps values and requests one durable commit")
    func rawPickClampsAndCommits() {
        let coordinator = DevelopWhiteBalanceSessionCoordinator()
        var settings = CameraRawSettings()

        let intent = coordinator.applyPickedWhiteBalance(
            temperatureKelvin: 500,
            tint: 999,
            usesIncrementalWhiteBalance: false,
            in: &settings
        )

        #expect(intent == .commit)
        #expect(settings.whiteBalance == "Custom")
        #expect(settings.temperature == 2_000)
        #expect(settings.tint == 150)
        #expect(settings.incrementalTemperature == nil)
    }

    @Test("picked non-RAW white balance converts to bounded relative settings")
    func nonRawPickConvertsAndClamps() {
        let coordinator = DevelopWhiteBalanceSessionCoordinator()
        var cold = CameraRawSettings()
        var warm = CameraRawSettings()

        #expect(coordinator.applyPickedWhiteBalance(
            temperatureKelvin: 500,
            tint: -999,
            usesIncrementalWhiteBalance: true,
            in: &cold
        ) == .commit)
        #expect(cold.incrementalTemperature == -135)
        #expect(cold.incrementalTint == -150)

        _ = coordinator.applyPickedWhiteBalance(
            temperatureKelvin: 20_000,
            tint: 4.6,
            usesIncrementalWhiteBalance: true,
            in: &warm
        )
        #expect(warm.incrementalTemperature == 100)
        #expect(warm.incrementalTint == 5)
        #expect(warm.temperature == nil)
    }

    @Test("slider mutations stay preview-only and log mapping is bounded")
    func sliderMutationIntentAndLogMapping() {
        let coordinator = DevelopWhiteBalanceSessionCoordinator()
        var settings = CameraRawSettings()

        #expect(coordinator.setDisplayedTemperature(
            80_000,
            usesIncrementalWhiteBalance: false,
            in: &settings
        ) == .previewOnly)
        #expect(settings.temperature == 50_000)
        #expect(coordinator.setDisplayedTint(
            2.5,
            usesIncrementalWhiteBalance: false,
            in: &settings
        ) == .previewOnly)
        #expect(settings.tint == 3)
        #expect(coordinator.normalizedLogScaleValue(forKelvin: 100) == 0)
        #expect(abs(coordinator.kelvinValue(forNormalizedLogScale: 2) - 50_000) < 0.001)
    }

    @Test("edit workspace delegates white-balance state and lifecycle to the coordinator")
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

        #expect(source.contains(
            "@State private var whiteBalanceSession = DevelopWhiteBalanceSessionCoordinator()"
        ))
        #expect(source.contains("whiteBalanceSession.beginImageSession(selectedImageURL)"))
        #expect(source.contains("whiteBalanceSession.endImageSession()"))
        #expect(source.contains("whiteBalanceSession.sourceRegion("))
        #expect(source.contains("whiteBalanceSession.applyPickedWhiteBalance("))
        #expect(!source.contains("@State private var asShotWhiteBalance"))
        #expect(!source.contains("@State private var isPickingWhiteBalance"))
        #expect(!source.contains("@State private var wbPickDragRect"))
    }
}
