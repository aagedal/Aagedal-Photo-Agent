import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@MainActor
@Suite("Application termination durability")
struct ApplicationTerminationFlushCoordinatorTests {
    @Test("Caption flush completes before Develop flush")
    func captionBeforeDevelop() async {
        var stages: [ApplicationTerminationFlushStage] = []
        let coordinator = ApplicationTerminationFlushCoordinator(
            captionFlush: { stages.append(.caption) },
            developFlush: {
                stages.append(.develop)
                return .succeeded
            }
        )

        #expect(await coordinator.attempt() == .succeeded)
        #expect(stages == [.caption, .develop])
    }

    @Test("Caption failure stops Develop and reports the exact stage")
    func captionFailureStopsDevelop() async {
        var developCalls = 0
        let coordinator = ApplicationTerminationFlushCoordinator(
            captionFlush: { throw InjectedTerminationFailure.caption },
            developFlush: {
                developCalls += 1
                return .succeeded
            }
        )

        #expect(await coordinator.attempt() == .failed(ApplicationTerminationFlushFailure(
            stage: .caption,
            message: InjectedTerminationFailure.caption.localizedDescription
        )))
        #expect(developCalls == 0)
    }

    @Test("Retry remains in one termination decision and eventually succeeds")
    func retryThenSucceed() async {
        var attempts = 0
        var failuresPresented = 0
        let coordinator = ApplicationTerminationFlushCoordinator(
            captionFlush: {
                attempts += 1
                if attempts == 1 { throw InjectedTerminationFailure.caption }
            },
            developFlush: { .succeeded }
        )

        let shouldTerminate = await coordinator.resolve { failure in
            #expect(failure.stage == .caption)
            failuresPresented += 1
            return .retry
        }
        #expect(shouldTerminate)
        #expect(attempts == 2)
        #expect(failuresPresented == 1)
    }

    @Test(
        "Failure choices distinguish keep-open from explicit quit-without-saving",
        arguments: [
            (ApplicationTerminationFailureChoice.keepOpen, false),
            (.quitWithoutSaving, true),
        ]
    )
    func terminalFailureChoices(
        choice: ApplicationTerminationFailureChoice,
        expectedTermination: Bool
    ) async {
        let coordinator = ApplicationTerminationFlushCoordinator(
            captionFlush: {},
            developFlush: { .failed("Injected Develop failure") }
        )

        let shouldTerminate = await coordinator.resolve { failure in
            #expect(failure.stage == .develop)
            #expect(failure.message == "Injected Develop failure")
            return choice
        }
        #expect(shouldTerminate == expectedTermination)
    }

    @Test("Reply latch rejects re-entry and duplicate completion")
    func singleReplyLatch() {
        let latch = ApplicationTerminationReplyLatch()
        #expect(latch.begin())
        #expect(latch.isPending)
        #expect(!latch.begin())
        #expect(latch.finish())
        #expect(!latch.isPending)
        #expect(!latch.finish())
        #expect(latch.begin())
    }

    @Test("Failed queued caption persistence retries without recapturing the live draft")
    func queuedCaptionRetryDoesNotRecapture() async throws {
        let queue = CaptionDraftPersistenceQueue(label: "caption-termination-test.retry")
        let persistence = TerminationPersistenceGate()
        queue.enqueue { try persistence.attempt() }
        #expect(queue.pendingCount == 1)

        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        let owner = UUID()
        var editorCaptures = 0
        coordinator.register(owner: owner) { editorCaptures += 1 }
        defer { coordinator.unregister(owner: owner) }
        let operation = CaptionWorkspaceTerminationFlushOperation(coordinator: coordinator)

        do {
            try await operation.flush()
            Issue.record("Expected retained sidecar persistence to fail")
        } catch {
            #expect(error.localizedDescription == InjectedTerminationFailure.sidecar.localizedDescription)
        }
        #expect(queue.pendingCount == 1)
        #expect(editorCaptures == 1)

        persistence.shouldFail = false
        try await operation.flush()
        #expect(queue.pendingCount == 0)
        #expect(editorCaptures == 1)
        #expect(persistence.attempts == 3)
    }

    @Test("Asynchronous caption drain suspends instead of blocking the main actor")
    func asynchronousDrainDoesNotBlockMainActor() async throws {
        let queue = CaptionDraftPersistenceQueue(label: "caption-termination-test.async")
        let started = TerminationAsyncSignal()
        let release = TerminationBlockingGate()
        queue.enqueue {
            started.signal()
            release.wait()
        }
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        let operation = CaptionWorkspaceTerminationFlushOperation(coordinator: coordinator)
        let flush = Task { @MainActor in try await operation.flush() }

        await started.wait()
        // Reaching this main-actor assertion while the persistence queue is held proves the
        // termination drain suspended rather than synchronously deadlocking AppKit.
        #expect(!flush.isCancelled)
        release.signal()
        try await flush.value
        #expect(queue.pendingCount == 0)
    }

    @Test("Transient presentation restores the owning workspace focus only when requested")
    func focusRestorePolicy() {
        #expect(CaptionWorkspaceFocusRestorePolicy.target(
            afterTransientPresentationInCaptionWorkspace: true,
            restoreRequested: true
        ) == .captionEditor)
        #expect(CaptionWorkspaceFocusRestorePolicy.target(
            afterTransientPresentationInCaptionWorkspace: false,
            restoreRequested: true
        ) == .browserGrid)
        #expect(CaptionWorkspaceFocusRestorePolicy.target(
            afterTransientPresentationInCaptionWorkspace: true,
            restoreRequested: false
        ) == .unchanged)
    }
}

private enum InjectedTerminationFailure: LocalizedError {
    case caption
    case sidecar

    var errorDescription: String? {
        switch self {
        case .caption: "Injected caption failure"
        case .sidecar: "Injected sidecar failure"
        }
    }
}

private nonisolated final class TerminationPersistenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failureEnabled = true
    private var attemptCount = 0

    var shouldFail: Bool {
        get { lock.withLock { failureEnabled } }
        set { lock.withLock { failureEnabled = newValue } }
    }

    var attempts: Int { lock.withLock { attemptCount } }

    func attempt() throws {
        let fails = lock.withLock {
            attemptCount += 1
            return failureEnabled
        }
        if fails { throw InjectedTerminationFailure.sidecar }
    }
}

private nonisolated final class TerminationBlockingGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func signal() { semaphore.signal() }
    func wait() { semaphore.wait() }
}

private actor TerminationAsyncSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func signal() {
        Task { await publish() }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func publish() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
