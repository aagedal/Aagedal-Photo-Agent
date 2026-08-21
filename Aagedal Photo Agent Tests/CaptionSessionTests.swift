import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@MainActor
@Suite("Caption session")
struct CaptionSessionTests {
    private let urls = [
        URL(fileURLWithPath: "/tmp/caption-a.jpg"),
        URL(fileURLWithPath: "/tmp/caption-b.jpg"),
        URL(fileURLWithPath: "/tmp/caption-c.jpg"),
    ]

    @Test("Session owns a stable ordered, deduplicated image list")
    func initialization() {
        let session = CaptionSession(
            imageURLs: [urls[0], urls[1], urls[0], urls[2]],
            currentURL: urls[1]
        )

        #expect(session.orderedImageURLs == urls)
        #expect(session.currentURL == urls[1])
        #expect(session.position == 2)
        #expect(session.previousURL == urls[0])
        #expect(session.count == 3)
        #expect(session.selectedURLs == [urls[1]])
        #expect(session.canGoPrevious)
        #expect(session.canGoNext)
    }

    @Test("Navigation flushes buffered text before changing focus")
    func navigationFlushesBeforeMutation() async throws {
        let session = CaptionSession(imageURLs: urls)
        var focusedDuringFlush: URL?

        let moved = try await session.goNext {
            focusedDuringFlush = session.currentURL
            session.markCurrentDirty()
        }

        #expect(moved)
        #expect(focusedDuringFlush == urls[0])
        #expect(session.currentURL == urls[1])
        #expect(session.dirtyURLs == [urls[0]])
        #expect(session.selectedURLs == [urls[1]])
    }

    @Test("A failed flush leaves navigation and selection unchanged")
    func failedFlushPreventsTransition() async {
        let session = CaptionSession(imageURLs: urls)
        let originalSelection = session.selectedURLs

        await #expect(throws: FlushFailure.self) {
            try await session.goNext { throw FlushFailure() }
        }

        #expect(session.currentURL == urls[0])
        #expect(session.selectedURLs == originalSelection)
        #expect(!session.isTransitioning)
    }

    @Test("Rapid opposite navigation is serialized without changing focus out of order")
    func rapidOppositeNavigationIsSerialized() async throws {
        let session = CaptionSession(imageURLs: urls, currentURL: urls[1])
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let next = Task { @MainActor in
            try await session.goNext {
                entered.signal()
                await release.wait()
            }
        }

        await entered.wait()
        do {
            _ = try await session.goPrevious {}
            Issue.record("Expected the second navigation to be rejected while flushing")
        } catch {
            #expect(error as? CaptionSessionError == .transitionInProgress)
        }
        #expect(session.currentURL == urls[1])

        release.signal()
        #expect(try await next.value)
        #expect(session.currentURL == urls[2])
        #expect(try await session.goPrevious {})
        #expect(session.currentURL == urls[1])
    }

    @Test("A previous-image load is rejected after navigation")
    func staleLoadSuppression() async throws {
        let session = CaptionSession(imageURLs: urls)
        let stale = try #require(session.beginLoad())
        #expect(session.accepts(load: stale))

        try await session.goNext {}

        #expect(!session.accepts(load: stale))
        let current = try #require(session.beginLoad())
        #expect(current.imageURL == urls[1])
        #expect(session.accepts(load: current))
    }

    @Test("Navigation returns while serialized sidecar persistence is still blocked")
    func navigationDoesNotAwaitPersistence() async throws {
        let session = CaptionSession(imageURLs: urls)
        let queue = CaptionDraftPersistenceQueue(label: "caption-session-test.persistence")
        let firstStarted = AsyncSignal()
        let releaseFirst = BlockingGate()
        let order = LockedStrings()

        let moved = try await session.goNext {
            queue.enqueue {
                order.append("first-start")
                firstStarted.signal()
                releaseFirst.wait()
                order.append("first-end")
            }
            queue.enqueue {
                order.append("second")
            }
        }

        #expect(moved)
        #expect(session.currentURL == urls[1])
        await firstStarted.wait()
        // The first operation is still held at the gate, so a FIFO queue cannot have started the
        // second operation. This is an ordering assertion, not a wall-clock threshold.
        #expect(order.values == ["first-start"])

        releaseFirst.signal()
        try queue.drain()
        #expect(order.values == ["first-start", "first-end", "second"])
        #expect(queue.pendingCount == 0)
    }

    @Test("Navigation invalidates but never awaits an in-flight image decode")
    func navigationDoesNotAwaitDecode() async throws {
        let session = CaptionSession(imageURLs: urls)
        let token = try #require(session.beginLoad())
        let decodeStarted = AsyncSignal()
        let releaseDecode = BlockingGate()
        let decode = Task.detached {
            decodeStarted.signal()
            releaseDecode.wait()
        }
        await decodeStarted.wait()

        let moved = try await session.goNext {}

        #expect(moved)
        #expect(session.currentURL == urls[1])
        #expect(!session.accepts(load: token))
        releaseDecode.signal()
        await decode.value
    }

    @Test("Failed persistence remains queued and durable drain retries in FIFO order")
    func persistenceFailureIsRetainedForRetry() throws {
        let queue = CaptionDraftPersistenceQueue(label: "caption-session-test.retry")
        let gate = PersistenceFailureGate()

        queue.enqueue(
            operation: { try gate.attempt() }
        )

        // Synchronizing through pendingCount proves the first background attempt has finished.
        #expect(queue.pendingCount == 1)
        #expect(throws: PersistenceFailure.self) {
            try queue.drain()
        }
        #expect(queue.pendingCount == 1)
        #expect(gate.attempts == 2)

        gate.shouldFail = false
        try queue.drain()
        #expect(queue.pendingCount == 0)
        #expect(gate.attempts == 3)
    }

    @Test("Selection changes flush first and choose a deterministic focus")
    func selectionTransition() async throws {
        let session = CaptionSession(imageURLs: urls)
        var flushCount = 0

        let changed = try await session.select([urls[2], urls[1]], focusedURL: urls[2]) {
            flushCount += 1
        }

        #expect(changed)
        #expect(flushCount == 1)
        #expect(session.currentURL == urls[2])
        #expect(session.selectedURLs == [urls[1], urls[2]])
    }

    @Test("Replacing images retains focus and prunes per-image state")
    func replaceImagesReconcilesState() {
        let session = CaptionSession(imageURLs: urls, currentURL: urls[1])
        session.markCurrentDirty()
        session.setReadiness(.blocked, for: urls[1])
        session.setReadiness(.warnings, for: urls[2])

        session.replaceImages([urls[2], urls[1]])
        #expect(session.currentURL == urls[1])
        #expect(session.position == 2)
        #expect(session.isCurrentDirty)
        #expect(session.currentReadiness == .blocked)

        session.replaceImages([urls[2]])
        #expect(session.currentURL == urls[2])
        #expect(session.dirtyURLs.isEmpty)
        #expect(session.readinessByURL[urls[1]] == nil)
        #expect(session.currentReadiness == .warnings)
    }

    @Test("Copy, template, write, send, and workspace exit all use the flush barrier")
    func actionFlushBarrier() async throws {
        let session = CaptionSession(imageURLs: urls)
        var actions = 0

        try await session.prepare(for: .copyPrevious) { actions += 1 }
        try await session.prepare(for: .applyTemplate) { actions += 1 }
        try await session.prepare(for: .write) { actions += 1 }
        try await session.prepare(for: .send) { actions += 1 }
        try await session.prepare(for: .workspaceExit) { actions += 1 }

        #expect(actions == 5)
    }

    @Test("Caption readiness follows blocker then warning severity")
    func readinessResolution() {
        let warning = MetadataValidationIssue(
            id: "warning",
            imageURL: urls[0],
            field: .headline,
            severity: .warning,
            message: "Warning",
            technicalDetail: nil
        )
        let blocker = MetadataValidationIssue(
            id: "blocker",
            imageURL: urls[0],
            field: .description,
            severity: .blocker,
            message: "Blocked",
            technicalDetail: nil
        )

        #expect(CaptionReadinessResolver.readiness(for: MetadataValidationReport(issues: [])) == .ready)
        #expect(CaptionReadinessResolver.readiness(for: MetadataValidationReport(issues: [warning])) == .warnings)
        #expect(CaptionReadinessResolver.readiness(for: MetadataValidationReport(issues: [warning, blocker])) == .blocked)
    }

    @Test("Only the active caption panel can unregister the flush barrier")
    func flushCoordinatorOwnership() throws {
        let coordinator = CaptionWorkspaceFlushCoordinator()
        let firstOwner = UUID()
        let activeOwner = UUID()
        var flushed = 0

        coordinator.register(owner: firstOwner) { flushed = 1 }
        coordinator.register(owner: activeOwner) { flushed = 2 }
        coordinator.unregister(owner: firstOwner)
        try coordinator.flush()
        #expect(flushed == 2)

        coordinator.unregister(owner: activeOwner)
        #expect(!coordinator.hasRegisteredHandler)
        #expect(throws: CaptionWorkspaceFlushError.handlerUnavailable) {
            try coordinator.flush()
        }
    }
}

private struct FlushFailure: Error {}

private struct PersistenceFailure: LocalizedError {
    var errorDescription: String? { "Injected caption persistence failure" }
}

private nonisolated final class BlockingGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait() {
        semaphore.wait()
    }

}

private actor AsyncSignal {
    private var isSignaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    nonisolated func signal() {
        Task { await publish() }
    }

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    private func publish() {
        guard !isSignaled else { return }
        isSignaled = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private nonisolated final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private nonisolated final class PersistenceFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failureEnabled = true
    private var attemptCount = 0

    var shouldFail: Bool {
        get { lock.withLock { failureEnabled } }
        set { lock.withLock { failureEnabled = newValue } }
    }

    var attempts: Int {
        lock.withLock { attemptCount }
    }

    func attempt() throws {
        let fails = lock.withLock {
            attemptCount += 1
            return failureEnabled
        }
        if fails { throw PersistenceFailure() }
    }
}
