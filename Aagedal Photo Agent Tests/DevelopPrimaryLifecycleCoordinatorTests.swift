import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@MainActor
private final class PrimaryLifecycleTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

/// A deliberately small stand-in for the VM-owned immutable request queue. The lifecycle
/// registry receives only wait/check closures, never a mutable editor or a retry operation.
@MainActor
private final class PrimaryLifecycleTestOwner {
    struct Intent {
        let id: UUID
        let imageURL: URL
        let settings: CameraRawSettings?
        let originalXMP: Data
    }
    enum State { case accepted, failed, durable }
    let intent: Intent
    let registry: DevelopPrimaryLifecycleCoordinator
    private(set) var state = State.accepted
    private(set) var executionCount = 0
    private(set) var waitCount = 0
    private var task: Task<Void, Never>?
    init(registry: DevelopPrimaryLifecycleCoordinator, imageURL: URL,
         settings: CameraRawSettings? = nil, originalXMP: Data = Data("original XMP".utf8)) {
        self.registry = registry
        self.intent = .init(id: UUID(), imageURL: imageURL, settings: settings, originalXMP: originalXMP)
    }
    func start(gate: PrimaryLifecycleTestGate, fail: Bool,
               completion: @escaping @MainActor (DevelopPrimaryPersistenceCompletion) -> Void = { _ in }) {
        state = .accepted
        executionCount += 1
        register()
        task = Task {
            await gate.wait()
            state = fail ? .failed : .durable
            if fail { register() } else { registry.unregister(ownerID: intent.id) }
            completion(fail ? .failed(message: "Captured Primary failed") : .succeeded)
        }
    }
    func finishRecovery() {
        state = .durable
        registry.unregister(ownerID: intent.id)
    }
    private func register() {
        registry.register(ownerID: intent.id, waitForAccepted: { [self] in
            waitCount += 1
            await task?.value
        }, requirePersisted: { [self] in
            guard case .durable = state else {
                throw CaptionWorkspaceFlushError.persistenceFailed("Retained Primary: " + intent.imageURL.path)
            }
        })
    }
}

@Suite("Primary Develop shared lifetime", .serialized)
@MainActor
struct DevelopPrimaryLifecycleCoordinatorTests {
    private func wait(_ gate: PrimaryLifecycleTestGate) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.isWaiting, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.isWaiting)
    }
    private func waitUntilAwaited(_ owner: PrimaryLifecycleTestOwner) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while owner.waitCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        try #require(owner.waitCount > 0)
    }

    private func settings(_ exposure: Double) -> CameraRawSettings {
        var value = CameraRawSettings(); value.exposure2012 = exposure; return value
    }

    @Test("Alert dismissal and session replacement preserve the only immutable failed Primary")
    func failureSurvivesPresentationAndOwnerRelease() async throws {
        let registry = DevelopPrimaryLifecycleCoordinator()
        let session = DevelopPersistenceSessionCoordinator()
        let gate = PrimaryLifecycleTestGate()
        let image = URL(fileURLWithPath: "/private/tmp/primary-lifetime/photo.png")
        var owner: PrimaryLifecycleTestOwner? = .init(registry: registry, imageURL: image, settings: settings(0.75))
        weak var retained = owner
        let originalID = try #require(owner).intent.id
        session.beginWorkspace(); session.beginImageSession(image)
        _ = session.schedulePrimaryPersistence { [weak owner] completion in
            owner?.start(gate: gate, fail: true, completion: completion)
        }
        owner = nil
        try await wait(gate)
        _ = session.endWorkspace()
        session.beginWorkspace(); session.beginImageSession(image.deletingLastPathComponent().appendingPathComponent("other.png"))
        session.dismissPrimaryPersistenceResult()
        #expect(registry.hasPendingWork)
        var flushFinished = false
        let flush = Task {
            defer { flushFinished = true }
            try await registry.flush()
        }
        await Task.yield()
        #expect(!flushFinished)
        gate.release()
        await #expect(throws: (any Error).self) { try await flush.value }
        await session.waitForAcceptedPrimaryPersistence()
        #expect(session.latestPrimaryPersistenceOutcome == nil)
        #expect(retained?.intent.id == originalID)
        #expect(retained?.intent.settings?.exposure2012 == 0.75)
        #expect(retained?.intent.originalXMP == Data("original XMP".utf8))
        #expect(registry.hasPendingWork)
        await #expect(throws: (any Error).self) { try await registry.flush() }
        #expect(retained?.executionCount == 1) // A lifecycle check never silently retries.
        retained?.finishRecovery()
        try await registry.flush()
        #expect(!registry.hasPendingWork)
    }

    @Test("Flush waits work admitted while a previous generation is finishing")
    func waitsEveryAcceptedGeneration() async throws {
        let registry = DevelopPrimaryLifecycleCoordinator()
        let first = PrimaryLifecycleTestOwner(registry: registry, imageURL: URL(fileURLWithPath: "/private/tmp/first.png"))
        let second = PrimaryLifecycleTestOwner(registry: registry, imageURL: URL(fileURLWithPath: "/private/tmp/second.png"))
        let firstGate = PrimaryLifecycleTestGate(), secondGate = PrimaryLifecycleTestGate()
        first.start(gate: firstGate, fail: false)
        try await wait(firstGate)
        var finished = false
        let flush = Task { try await registry.flush(); finished = true }
        try await waitUntilAwaited(first)
        second.start(gate: secondGate, fail: false)
        try await wait(secondGate)
        firstGate.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(!finished)
        secondGate.release()
        try await flush.value
        #expect(finished)
        #expect(!registry.hasPendingWork)
    }

    @Test("Dirty undo and redo settings are captured before a successful exit")
    func capturesUndoAndRedoBeforeWaiting() async throws {
        let registry = DevelopPrimaryLifecycleCoordinator()
        let session = DevelopPersistenceSessionCoordinator()
        let image = URL(fileURLWithPath: "/private/tmp/undo-primary.png")
        let before = settings(0.25), after = settings(0.75)
        var current: CameraRawSettings? = after
        var dirty = false
        var captures: [PrimaryLifecycleTestOwner] = []
        var nextGate = PrimaryLifecycleTestGate()
        session.beginWorkspace(); session.beginImageSession(image)
        _ = session.recordMutation(before: before, after: after, editsNamedVersion: false) { value, named in
            #expect(!named)
            current = value; dirty = true
        }
        let editorID = UUID()
        registry.registerEditor(ownerID: editorID, hasPendingWork: { dirty }, capture: {
            let owner = PrimaryLifecycleTestOwner(registry: registry, imageURL: image, settings: current)
            captures.append(owner); dirty = false
            owner.start(gate: nextGate, fail: false)
        })
        session.undo()
        #expect(registry.hasPendingWork)
        let undoFlush = Task { try await registry.flush() }
        try await wait(nextGate)
        #expect(captures.count == 1)
        #expect(captures[0].intent.settings == before)
        nextGate.release(); try await undoFlush.value
        nextGate = PrimaryLifecycleTestGate()
        session.redo()
        let redoFlush = Task { try await registry.flush() }
        try await wait(nextGate)
        #expect(captures.count == 2)
        #expect(captures[1].intent.settings == after)
        nextGate.release(); try await redoFlush.value
        registry.unregisterEditor(ownerID: editorID)
        #expect(!registry.hasPendingWork)
    }

    @Test("Capture refusal still awaits other accepted work before reporting the failure")
    func captureFailureDoesNotSkipAcceptedWrite() async throws {
        let registry = DevelopPrimaryLifecycleCoordinator()
        let gate = PrimaryLifecycleTestGate()
        let owner = PrimaryLifecycleTestOwner(registry: registry, imageURL: URL(fileURLWithPath: "/private/tmp/accepted.png"))
        owner.start(gate: gate, fail: false)
        try await wait(gate)
        let editor = UUID()
        registry.registerEditor(ownerID: editor, hasPendingWork: { true }, capture: { throw CocoaError(.userCancelled) })
        var finished = false
        let flush = Task {
            defer { finished = true }
            try await registry.flush()
        }
        await Task.yield()
        #expect(!finished)
        gate.release()
        await #expect(throws: CocoaError.self) { try await flush.value }
        #expect(owner.executionCount == 1)
        registry.unregisterEditor(ownerID: editor)
        try await registry.flush()
    }

    @Test("Recovery capture is outside the failing barrier and editor unregister cannot erase retained work")
    func captureOnlyAndSynchronousBarrier() async throws {
        let registry = DevelopPrimaryLifecycleCoordinator()
        let gate = PrimaryLifecycleTestGate()
        let owner = PrimaryLifecycleTestOwner(registry: registry, imageURL: URL(fileURLWithPath: "/private/tmp/recovery.png"))
        let editor = UUID()
        var dirty = true
        registry.registerEditor(ownerID: editor, hasPendingWork: { dirty }, capture: {
            dirty = false
            owner.start(gate: gate, fail: true)
        })
        try registry.captureEditors()
        #expect(owner.executionCount == 1)
        #expect(throws: (any Error).self) { try registry.requirePersisted() }
        try registry.captureEditors() // No duplicate accepted request.
        registry.unregisterEditor(ownerID: editor)
        #expect(registry.hasPendingWork)
        try await wait(gate)
        gate.release()
        await #expect(throws: (any Error).self) { try await registry.flush() }
        #expect(owner.executionCount == 1)
        owner.finishRecovery()
        try registry.requirePersisted()
    }

    @Test("A cancelled flush still waits the admitted writer instead of abandoning its result")
    func cancellationWaitsAcceptedWork() async throws {
        let registry = DevelopPrimaryLifecycleCoordinator()
        let gate = PrimaryLifecycleTestGate()
        let owner = PrimaryLifecycleTestOwner(registry: registry, imageURL: URL(fileURLWithPath: "/private/tmp/cancel.png"))
        owner.start(gate: gate, fail: false)
        try await wait(gate)
        var finished = false
        let flush = Task {
            defer { finished = true }
            try await registry.flush()
        }
        await Task.yield(); flush.cancel(); await Task.yield()
        #expect(!finished)
        gate.release()
        await #expect(throws: CancellationError.self) { try await flush.value }
        #expect(!registry.hasPendingWork)
    }

    @Test("Session teardown does not cancel accepted completion tracking")
    func acceptedSessionCallbacksSurviveTeardown() async throws {
        let session = DevelopPersistenceSessionCoordinator()
        session.beginWorkspace(); session.beginImageSession(URL(fileURLWithPath: "/private/tmp/session.png"))
        var callback: DevelopPersistenceSessionCoordinator.PrimaryPersistenceCompletion?
        _ = session.schedulePrimaryPersistence { callback = $0 }
        _ = session.endWorkspace()
        var finished = false
        let waiting = Task { await session.waitForAcceptedPrimaryPersistence(); finished = true }
        await Task.yield()
        #expect(!finished)
        callback?(.failed(message: "Failure after teardown"))
        await waiting.value
        #expect(finished)
        #expect(session.latestPrimaryPersistenceOutcome == nil)
    }
    @Test("Global Develop bridge awaits and refuses retained Primary without any mounted named view")
    func globalBridgeNoMountedView() async throws {
        let registry = DevelopPrimaryLifecycleCoordinator()
        let bridge = DevelopVersionFlushCoordinator(primaryLifecycle: registry)
        let owner = PrimaryLifecycleTestOwner(registry: registry, imageURL: URL(fileURLWithPath: "/private/tmp/no-view.png"))
        let gate = PrimaryLifecycleTestGate()
        owner.start(gate: gate, fail: true)
        try await wait(gate)
        #expect(bridge.hasRegisteredHandler)
        var finished = false
        let flush = Task {
            let outcome = await bridge.flush(.applicationTermination)
            finished = true
            return outcome
        }
        await Task.yield()
        #expect(!finished)
        gate.release()
        guard case .failed(let message) = await flush.value else { Issue.record("Missing retained Primary barrier"); return }
        #expect(message.contains("no-view.png"))
        owner.finishRecovery()
        #expect(await bridge.flush(.workspaceExit) == .succeeded)
        #expect(!bridge.hasRegisteredHandler)
    }

    @Test("A replacement named registration cannot be invoked by an older waiting flush")
    func globalBridgeRejectsChangedNamedRegistration() async throws {
        let registry = DevelopPrimaryLifecycleCoordinator()
        let bridge = DevelopVersionFlushCoordinator(primaryLifecycle: registry)
        let owner = PrimaryLifecycleTestOwner(registry: registry, imageURL: URL(fileURLWithPath: "/private/tmp/awaiting.png"))
        let gate = PrimaryLifecycleTestGate()
        var oldCalls = 0, newCalls = 0
        let oldID = bridge.register { _ in oldCalls += 1; return .succeeded }
        owner.start(gate: gate, fail: false)
        try await wait(gate)
        let flush = Task { await bridge.flush(.imageNavigation) }
        try await waitUntilAwaited(owner)
        _ = bridge.register { _ in newCalls += 1; return .succeeded }
        bridge.unregister(oldID) // A late old-view teardown must not unregister its replacement.
        gate.release()
        guard case .failed(let message) = await flush.value else { Issue.record("Expected changed registration refusal"); return }
        #expect(message.contains("workspace changed"))
        #expect(oldCalls == 0)
        #expect(newCalls == 0)
        #expect(await bridge.flush(.imageNavigation) == .succeeded)
        #expect(newCalls == 1)
    }

    @Test("Late unregister cannot remove a newer named view or bypass retained Primary")
    func globalBridgeStaleUnregister() async throws {
        let registry = DevelopPrimaryLifecycleCoordinator()
        let bridge = DevelopVersionFlushCoordinator(primaryLifecycle: registry)
        let old = bridge.register { _ in .failed("Old registration") }
        var called = false
        let current = bridge.register { _ in called = true; return .succeeded }
        bridge.unregister(old)
        #expect(bridge.hasRegisteredHandler)
        #expect(await bridge.flush(.workspaceExit) == .succeeded)
        #expect(called)
        bridge.unregister(current)
        #expect(!bridge.hasRegisteredHandler)
    }

}
