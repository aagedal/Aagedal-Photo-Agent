import CoreImage
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("AI mask selection coordinator")
struct AIMaskSelectionCoordinatorTests {
    @Test("an image change rejects a cancelled generator's late result")
    func imageChangeRejectsLateGeneration() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/ai-mask-first.raw")
        let secondURL = URL(fileURLWithPath: "/tmp/ai-mask-second.raw")
        let output = generatedMask(target: .person)
        let coordinator = AIMaskSelectionCoordinator { _, _, _, _, _ in
            // Ignore cancellation deliberately: request identity must still reject this result.
            try? await Task.sleep(for: .milliseconds(80))
            return output
        }
        var callbackCount = 0

        coordinator.beginImageSession(firstURL)
        #expect(coordinator.beginSelection(replacing: nil, resetsTarget: true))
        let didStartGeneration = coordinator.generate(
            from: sourceImage,
            sourcePoint: CGPoint(x: 0.3, y: 0.4),
            sourceOrientation: 1,
            imageURL: firstURL
        ) { _, _ in
            callbackCount += 1
        }
        #expect(didStartGeneration)
        await Task.yield()

        coordinator.beginImageSession(secondURL)
        try await Task.sleep(for: .milliseconds(120))
        #expect(callbackCount == 0)
        #expect(!coordinator.isSelecting)
        #expect(!coordinator.isGenerating)
        #expect(coordinator.errorMessage == nil)
    }

    @Test("generation snapshots target and replacement identity")
    func generationSnapshotsRequest() async throws {
        let imageURL = URL(fileURLWithPath: "/tmp/ai-mask-success.raw")
        let replacementID = UUID()
        let recorder = AIMaskGeneratorRecorder(output: generatedMask(target: .face))
        let coordinator = AIMaskSelectionCoordinator { image, points, orientation, target, size in
            await recorder.generate(image, points, orientation, target, size)
        }
        coordinator.beginImageSession(imageURL)
        coordinator.adoptTarget(.face)
        #expect(coordinator.beginSelection(replacing: replacementID, resetsTarget: false))
        var installedReplacementID: UUID?

        let didStartGeneration = coordinator.generate(
            from: sourceImage,
            sourcePoint: CGPoint(x: 0.6, y: 0.2),
            sourceOrientation: 6,
            imageURL: imageURL
        ) { _, replacementID in
            installedReplacementID = replacementID
        }
        #expect(didStartGeneration)

        try await eventually { installedReplacementID != nil }
        let request = try #require(await recorder.lastRequest)
        #expect(request.points == [AIMaskPromptPoint(x: 0.6, y: 0.2, isPositive: true)])
        #expect(request.orientation == 6)
        #expect(request.target == .face)
        #expect(installedReplacementID == replacementID)
        #expect(!coordinator.isSelecting)
        #expect(!coordinator.isGenerating)
        #expect(coordinator.replacingMaskID == nil)
    }

    @Test("refinement replays every point, replaces its mask, and stays active between clicks")
    func refinementStaysActive() async throws {
        let imageURL = URL(fileURLWithPath: "/tmp/ai-mask-refine.raw")
        let maskID = UUID()
        let recorder = AIMaskGeneratorRecorder(output: generatedMask(target: .person))
        let coordinator = AIMaskSelectionCoordinator { image, points, orientation, target, size in
            await recorder.generate(image, points, orientation, target, size)
        }
        coordinator.beginImageSession(imageURL)
        #expect(coordinator.beginRefinement(of: maskID, mode: .subtract))
        #expect(coordinator.isRefining)
        #expect(coordinator.pointMode == .subtract)
        var installedID: UUID?
        let points = [
            AIMaskPromptPoint(x: 0.4, y: 0.5, isPositive: true),
            AIMaskPromptPoint(x: 0.7, y: 0.2, isPositive: false),
        ]

        #expect(coordinator.generate(
            from: sourceImage,
            points: points,
            sourceOrientation: 1,
            imageURL: imageURL
        ) { _, id in installedID = id })

        try await eventually { installedID != nil }
        #expect(installedID == maskID)
        #expect(await recorder.lastRequest?.points == points)
        #expect(coordinator.isSelecting)
        #expect(coordinator.refiningMaskID == maskID)
        #expect(!coordinator.isGenerating)

        coordinator.cancelSelectionIfIdle()
        #expect(!coordinator.isSelecting)
        #expect(!coordinator.isRefining)
    }

    @Test("a failed generation keeps selection active for another click")
    func failureKeepsSelectionActive() async throws {
        let imageURL = URL(fileURLWithPath: "/tmp/ai-mask-failure.raw")
        let replacementID = UUID()
        let coordinator = AIMaskSelectionCoordinator { _, _, _, _, _ in
            throw TestGenerationError.failed
        }
        coordinator.beginImageSession(imageURL)
        #expect(coordinator.beginSelection(replacing: replacementID, resetsTarget: false))

        let didStartGeneration = coordinator.generate(
            from: sourceImage,
            sourcePoint: CGPoint(x: 0.5, y: 0.5),
            sourceOrientation: 1,
            imageURL: imageURL,
            onGenerated: { _, _ in Issue.record("Unexpected generated mask") }
        )
        #expect(didStartGeneration)

        try await eventually { coordinator.errorMessage != nil }
        #expect(coordinator.errorMessage == "Test generation failed.")
        #expect(coordinator.isSelecting)
        #expect(!coordinator.isGenerating)
        #expect(coordinator.replacingMaskID == replacementID)
    }

    @Test("a drag preview skips superseded positions and shows the latest")
    func previewRunsOnlyTheLatestPendingRequest() async throws {
        let imageURL = URL(fileURLWithPath: "/tmp/ai-mask-preview.raw")
        let previews = AIMaskPreviewRecorder(image: try previewImage(), delay: .milliseconds(60))
        let coordinator = AIMaskSelectionCoordinator(
            generator: { _, _, _, _, _ in throw TestGenerationError.failed },
            previewer: { _, points, _, size in await previews.preview(points, size) },
            prewarmer: { _, _ in }
        )
        coordinator.beginImageSession(imageURL)
        coordinator.adoptSelectionSize(.large)
        #expect(coordinator.beginSelection(replacing: nil, resetsTarget: false))

        let positions = [0.1, 0.2, 0.3].map { [AIMaskPromptPoint(x: $0, y: 0.5, isPositive: true)] }
        for points in positions {
            coordinator.updatePreview(from: sourceImage, points: points, imageURL: imageURL)
        }

        try await eventually { coordinator.preview?.points == positions[2] }
        #expect(await previews.requests.map(\.points) == [positions[0], positions[2]])
        #expect(await previews.requests.allSatisfy { $0.size == .large })
    }

    @Test("releasing replaces the preview with the generated mask, and stale previews never land")
    func generationSupersedesPreview() async throws {
        let imageURL = URL(fileURLWithPath: "/tmp/ai-mask-preview-release.raw")
        let previews = AIMaskPreviewRecorder(image: try previewImage(), delay: .milliseconds(80))
        let coordinator = AIMaskSelectionCoordinator(
            generator: { [output = generatedMask(target: .object)] _, _, _, _, _ in output },
            previewer: { _, points, _, size in await previews.preview(points, size) },
            prewarmer: { _, _ in }
        )
        coordinator.beginImageSession(imageURL)
        #expect(coordinator.beginSelection(replacing: nil, resetsTarget: true))
        let points = [AIMaskPromptPoint(x: 0.4, y: 0.4, isPositive: true)]
        coordinator.updatePreview(from: sourceImage, points: points, imageURL: imageURL)
        var generated = false

        #expect(coordinator.generate(
            from: sourceImage,
            points: points,
            sourceOrientation: 1,
            imageURL: imageURL
        ) { _, _ in generated = true })

        try await eventually { generated }
        try await Task.sleep(for: .milliseconds(120))
        #expect(coordinator.preview == nil)
        #expect(!coordinator.isSelecting)
    }

    @Test("a size change regenerates the mask in place without entering selection")
    func regenerateUsesSelectionSize() async throws {
        let imageURL = URL(fileURLWithPath: "/tmp/ai-mask-resize.raw")
        let maskID = UUID()
        let recorder = AIMaskGeneratorRecorder(output: generatedMask(target: .object))
        let coordinator = AIMaskSelectionCoordinator { image, points, orientation, target, size in
            await recorder.generate(image, points, orientation, target, size)
        }
        coordinator.beginImageSession(imageURL)
        coordinator.adoptSelectionSize(.small)
        let points = [AIMaskPromptPoint(x: 0.5, y: 0.5, isPositive: true)]
        var installedID: UUID?

        #expect(coordinator.regenerate(
            replacing: maskID,
            from: sourceImage,
            points: points,
            sourceOrientation: 1,
            imageURL: imageURL
        ) { _, id in installedID = id })

        try await eventually { installedID != nil }
        #expect(installedID == maskID)
        #expect(await recorder.lastRequest?.size == .small)
        #expect(!coordinator.isSelecting)

        // A new selection starts from Auto again.
        #expect(coordinator.beginSelection(replacing: nil, resetsTarget: true))
        #expect(coordinator.selectionSize == .automatic)
    }

    private func previewImage() throws -> CGImage {
        try #require(AIMaskPreview.tintedImage(coverage: [255], width: 1, height: 1))
    }

    private var sourceImage: CIImage {
        CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
    }

    private func generatedMask(target: AIMaskTarget) -> GeneratedAIMask {
        GeneratedAIMask(raster: AIMaskGeometry(
            width: 1,
            height: 1,
            pngData: Data([1]),
            target: target
        ))
    }

    private func eventually(
        timeout: Duration = .seconds(30),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for AI mask coordinator state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor AIMaskGeneratorRecorder {
    struct Request: Sendable {
        let points: [AIMaskPromptPoint]
        let orientation: Int
        let target: AIMaskTarget
        let size: AIMaskSelectionSize
    }

    private let output: GeneratedAIMask
    private(set) var lastRequest: Request?

    init(output: GeneratedAIMask) {
        self.output = output
    }

    func generate(
        _ image: CIImage,
        _ points: [AIMaskPromptPoint],
        _ orientation: Int,
        _ target: AIMaskTarget,
        _ size: AIMaskSelectionSize
    ) -> GeneratedAIMask {
        lastRequest = Request(points: points, orientation: orientation, target: target, size: size)
        return output
    }
}

private actor AIMaskPreviewRecorder {
    struct Request: Sendable {
        let points: [AIMaskPromptPoint]
        let size: AIMaskSelectionSize
    }

    private let image: CGImage
    private let delay: Duration
    private(set) var requests: [Request] = []

    init(image: CGImage, delay: Duration) {
        self.image = image
        self.delay = delay
    }

    func preview(_ points: [AIMaskPromptPoint], _ size: AIMaskSelectionSize) async -> AIMaskPreview {
        requests.append(Request(points: points, size: size))
        try? await Task.sleep(for: delay)
        return AIMaskPreview(image: image, points: points)
    }
}

private enum TestGenerationError: LocalizedError {
    case failed

    var errorDescription: String? { "Test generation failed." }
}
