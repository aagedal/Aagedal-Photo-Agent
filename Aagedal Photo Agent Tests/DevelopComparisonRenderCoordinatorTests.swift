import CoreGraphics
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop comparison render coordinator")
struct DevelopComparisonRenderCoordinatorTests {
    @Test("a replacement render rejects a cancelled renderer's late pixels")
    func replacementRenderRejectsLatePixels() async throws {
        let coordinator = DevelopComparisonRenderCoordinator(renderDelay: .zero)
        coordinator.openImageComparison(target: ImageFile(url: URL(fileURLWithPath: "/tmp/right.jpg")))

        coordinator.renderImage {
            // Ignore cancellation deliberately to characterize the request-token boundary.
            try? await Task.sleep(for: .milliseconds(80))
            return renderedSource(token: "stale")
        }
        await Task.yield()
        coordinator.renderImage {
            renderedSource(token: "current")
        }

        try await eventually {
            coordinator.liveSource?.source.representation.renderToken == "current"
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.liveSource?.source.representation.renderToken == "current")
        #expect(!coordinator.isRendering)
    }

    @Test("closing Compare cancels work and rejects late failures")
    func closeRejectsLateFailure() async throws {
        let coordinator = DevelopComparisonRenderCoordinator(renderDelay: .zero)
        coordinator.openImageComparison(target: ImageFile(url: URL(fileURLWithPath: "/tmp/right.jpg")))
        coordinator.renderImage {
            try? await Task.sleep(for: .milliseconds(50))
            throw TestError.lateFailure
        }

        await Task.yield()
        coordinator.close()
        try await Task.sleep(for: .milliseconds(80))

        #expect(!coordinator.isActive)
        #expect(!coordinator.isRendering)
        #expect(coordinator.liveSource == nil)
        #expect(coordinator.errorMessage == nil)
    }

    @Test("switching comparison modes clears the previous mode and publishes an atomic version pair")
    func modeSwitchPublishesVersionPair() async throws {
        let coordinator = DevelopComparisonRenderCoordinator(renderDelay: .zero)
        coordinator.openImageComparison(target: ImageFile(url: URL(fileURLWithPath: "/tmp/right.jpg")))
        let versionID = UUID()
        coordinator.openVersionComparison(target: .named(versionID))

        #expect(coordinator.imageTarget == nil)
        #expect(coordinator.versionTarget == .named(versionID))
        #expect(coordinator.liveSource == nil)

        coordinator.renderVersion(target: .named(versionID)) {
            .init(
                live: renderedSource(token: "live"),
                target: renderedSource(token: "named")
            )
        }

        try await eventually {
            coordinator.liveSource != nil && coordinator.versionTargetSource != nil
        }
        #expect(coordinator.liveSource?.source.representation.renderToken == "live")
        #expect(coordinator.versionTargetSource?.source.representation.renderToken == "named")
        #expect(coordinator.errorMessage == nil)
    }

    private enum TestError: Error {
        case lateFailure
    }

    private func renderedSource(token: String) -> ComparisonRenderedSource {
        let url = URL(fileURLWithPath: "/tmp/\(token).jpg")
        let revision = SourceImageRevision(
            canonicalURL: url,
            fileResourceIdentifier: nil,
            filenameAtCreation: url.lastPathComponent,
            byteCount: 4,
            contentModificationDate: Date(timeIntervalSince1970: 10),
            pixelWidth: 1,
            pixelHeight: 1,
            exifOrientation: 1,
            sha256: String(repeating: "a", count: 64),
            hashCompletedAt: Date(timeIntervalSince1970: 11)
        )
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ComparisonRenderedSource(
            source: ComparisonSource(
                revision: revision,
                representation: .liveEdit(renderToken: token)
            ),
            image: context.makeImage()!
        )
    }

    private func eventually(
        timeout: Duration = .seconds(30),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for coordinator state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
