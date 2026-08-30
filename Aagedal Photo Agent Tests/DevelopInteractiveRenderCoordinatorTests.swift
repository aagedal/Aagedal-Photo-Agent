import CoreGraphics
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop interactive render coordinator")
@MainActor
struct DevelopInteractiveRenderCoordinatorTests {
    @Test("slider lifecycle keeps previews transient and requests one commit on release")
    func sliderLifecycleAndPersistenceIntent() {
        let coordinator = DevelopInteractiveRenderCoordinator()

        #expect(coordinator.setSliderInteraction(active: true) == .previewOnly)
        #expect(!coordinator.isSliderInteractionActive)

        coordinator.beginWorkspace()
        #expect(coordinator.isWorkspaceActive)
        #expect(coordinator.setSliderInteraction(active: true) == .previewOnly)
        #expect(coordinator.isSliderInteractionActive)
        #expect(coordinator.setSliderInteraction(active: true) == .previewOnly)
        #expect(coordinator.setSliderInteraction(active: false) == .commit)
        #expect(!coordinator.isSliderInteractionActive)
        #expect(coordinator.setSliderInteraction(active: false) == .previewOnly)

        _ = coordinator.setSliderInteraction(active: true)
        coordinator.endWorkspace()
        #expect(!coordinator.isWorkspaceActive)
        #expect(!coordinator.isSliderInteractionActive)
        #expect(!coordinator.isScopePublicationPending)
    }

    @Test("throttle coalesces queued scope work onto the latest edit")
    func throttleCoalescesQueuedWork() async throws {
        let coordinator = DevelopInteractiveRenderCoordinator(
            minimumScopeInterval: .milliseconds(60)
        )
        coordinator.beginWorkspace()
        _ = coordinator.setSliderInteraction(active: true)
        var renderedWidths: [Int] = []
        var publishedWidths: [Int] = []

        coordinator.requestScopePublication(
            operation: {
                renderedWidths.append(1)
                return Self.output(width: 1)
            },
            publisher: { image, _ in publishedWidths.append(image.width) }
        )
        coordinator.requestScopePublication(
            operation: {
                renderedWidths.append(2)
                return Self.output(width: 2)
            },
            publisher: { image, _ in publishedWidths.append(image.width) }
        )

        try await eventually { publishedWidths == [2] }
        #expect(renderedWidths == [2])
        #expect(!coordinator.isScopePublicationPending)
    }

    @Test("replacement request rejects a cancelled renderer's late scope pixels")
    func replacementRejectsLatePixels() async throws {
        let coordinator = DevelopInteractiveRenderCoordinator(minimumScopeInterval: .zero)
        coordinator.beginWorkspace()
        _ = coordinator.setSliderInteraction(active: true)
        var publishedWidths: [Int] = []

        coordinator.requestScopePublication(
            operation: {
                // Deliberately ignore cooperative cancellation to exercise the identity gate.
                try? await Task.sleep(for: .milliseconds(80))
                return Self.output(width: 1)
            },
            publisher: { image, _ in publishedWidths.append(image.width) }
        )
        await Task.yield()
        coordinator.requestScopePublication(
            operation: { Self.output(width: 2, isHDR: true) },
            publisher: { image, isHDR in
                #expect(isHDR)
                publishedWidths.append(image.width)
            }
        )

        try await eventually { publishedWidths == [2] }
        try await Task.sleep(for: .milliseconds(100))
        #expect(publishedWidths == [2])
    }

    @Test("image replacement cancels pending scope publication")
    func imageReplacementCancelsPendingPublication() async throws {
        let coordinator = DevelopInteractiveRenderCoordinator(minimumScopeInterval: .zero)
        coordinator.beginWorkspace()
        _ = coordinator.setSliderInteraction(active: true)
        var publicationCount = 0

        coordinator.requestScopePublication(
            operation: {
                try? await Task.sleep(for: .milliseconds(50))
                return Self.output(width: 3)
            },
            publisher: { _, _ in publicationCount += 1 }
        )
        await Task.yield()
        coordinator.beginImageSession()
        try await Task.sleep(for: .milliseconds(80))

        #expect(publicationCount == 0)
        #expect(!coordinator.isSliderInteractionActive)
        #expect(!coordinator.isScopePublicationPending)
    }

    @Test("edit workspace delegates interactive render state and publication")
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
            "@State private var interactiveRender = DevelopInteractiveRenderCoordinator()"
        ))
        #expect(source.contains("interactiveRender.beginWorkspace()"))
        #expect(source.contains("interactiveRender.beginImageSession()"))
        #expect(source.contains("interactiveRender.endWorkspace()"))
        #expect(source.contains("interactiveRender.setSliderInteraction(active: editing)"))
        #expect(source.contains("interactiveRender.requestScopePublication("))
        #expect(!source.contains("@State private var isDraggingEditSlider"))
        #expect(!source.contains("@State private var scopeThrottleTask"))
        #expect(!source.contains("@State private var lastScopeUpdateTime"))
    }

    private static func output(width: Int, isHDR: Bool = false) -> DevelopInteractiveRenderCoordinator.ScopeOutput {
        let context = CGContext(
            data: nil,
            width: width,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return DevelopInteractiveRenderCoordinator.ScopeOutput(
            image: context.makeImage()!,
            isHDR: isHDR
        )
    }

    private func eventually(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for interactive render publication")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
