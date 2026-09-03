import CoreImage
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Clean Feed browse render service")
struct CleanFeedBrowseRenderServiceTests {
    @Test("render returns immutable request evidence off the main actor")
    @MainActor
    func renderReturnsRequestEvidenceOffMainActor() async {
        let probe = CleanFeedRenderProbe()
        let service = CleanFeedBrowseRenderService(renderer: probe.render)
        let request = makeRequest()

        let snapshot = await service.render(request)

        #expect(snapshot.requestID == request.requestID)
        #expect(snapshot.imageURL == request.imageURL)
        #expect(snapshot.image != nil)
        #expect(snapshot.completion == .complete)
        #expect(probe.callCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("pre-cancelled render performs no source work")
    func preCancelledRenderSkipsSourceWork() async {
        let probe = CleanFeedRenderProbe()
        let service = CleanFeedBrowseRenderService(renderer: probe.render)
        let request = makeRequest()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.render(request)
        }

        let snapshot = await task.value

        #expect(snapshot.requestID == request.requestID)
        #expect(snapshot.imageURL == request.imageURL)
        #expect(snapshot.image == nil)
        #expect(snapshot.completion == .cancelled(renderCompleted: false))
        #expect(probe.callCount == 0)
    }

    @Test("cancellation after non-preemptible render is explicit")
    func postRenderCancellationIsExplicit() async {
        let probe = BlockingCleanFeedRenderProbe()
        defer { probe.release() }
        let service = CleanFeedBrowseRenderService(renderer: probe.render)
        let request = makeRequest()
        let task = Task { await service.render(request) }

        let didBlock = await probe.waitUntilBlocked()
        #expect(didBlock, "The simulated Clean Feed render did not start within 30 seconds")
        guard didBlock else { return }
        task.cancel()
        probe.release()

        let snapshot = await task.value
        #expect(snapshot.requestID == request.requestID)
        #expect(snapshot.imageURL == request.imageURL)
        #expect(snapshot.image != nil)
        #expect(snapshot.completion == .cancelled(renderCompleted: true))
    }

    @Test("Clean Feed delegates browsing render and rejects stale publication")
    func cleanFeedSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/CleanFeed/CleanFeedView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("await CleanFeedBrowseRenderService.shared.render("))
        #expect(source.contains("loadRequestID == requestID"))
        #expect(source.contains("snapshot.requestID == requestID"))
        #expect(source.contains("snapshot.imageURL == url"))
        #expect(source.contains("browserViewModel.firstSelectedImage?.url == url"))
        #expect(source.contains("!controller.editModeActive"))
        #expect(source.contains(".onDisappear { cancelBrowseLoad() }"))
        #expect(!source.contains("Task.detached"))
        #expect(!source.contains("CGImageSourceCreateWithURL"))
        #expect(!source.contains("FullScreenImageCache.loadRAWPreview("))
    }

    private func makeRequest() -> CleanFeedBrowseRenderRequest {
        CleanFeedBrowseRenderRequest(
            requestID: UUID(),
            imageURL: URL(fileURLWithPath: "/virtual/clean-feed.raw"),
            settings: nil,
            displayOrientation: 1,
            maxPixelSize: 2_048
        )
    }
}

nonisolated private final class CleanFeedRenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCallCount = 0
    private var observedMainThread = false

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    var ranOnMainThread: Bool {
        lock.withLock { observedMainThread }
    }

    func render(_ request: CleanFeedBrowseRenderRequest) async -> CIImage? {
        lock.withLock {
            recordedCallCount += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return CIImage(color: .gray).cropped(
            to: CGRect(x: 0, y: 0, width: request.maxPixelSize, height: 16)
        )
    }
}

nonisolated private final class BlockingCleanFeedRenderProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var isBlocked = false
    private var isReleased = false

    func render(_ request: CleanFeedBrowseRenderRequest) async -> CIImage? {
        renderSynchronously(request)
    }

    private func renderSynchronously(_ request: CleanFeedBrowseRenderRequest) -> CIImage? {
        condition.lock()
        isBlocked = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
        return CIImage(color: .gray).cropped(
            to: CGRect(x: 0, y: 0, width: request.maxPixelSize, height: 16)
        )
    }

    func waitUntilBlocked(timeout: TimeInterval = 30) async -> Bool {
        await Task.detached { [self] in
            waitUntilBlockedSynchronously(timeout: timeout)
        }.value
    }

    private func waitUntilBlockedSynchronously(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !isBlocked {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release() {
        condition.withLock {
            isReleased = true
            condition.broadcast()
        }
    }
}
