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

    @Test("Analysis saves flush between Caption and Develop, and their failure stops Develop")
    func analysisBetweenCaptionAndDevelop() async {
        var stages: [ApplicationTerminationFlushStage] = []
        var analysisFails = false
        let coordinator = ApplicationTerminationFlushCoordinator(
            captionFlush: { stages.append(.caption) },
            analysisFlush: {
                stages.append(.analysis)
                if analysisFails { throw InjectedTerminationFailure.analysis }
            },
            developFlush: {
                stages.append(.develop)
                return .succeeded
            }
        )

        #expect(await coordinator.attempt() == .succeeded)
        #expect(stages == [.caption, .analysis, .develop])

        stages = []
        analysisFails = true
        #expect(await coordinator.attempt() == .failed(ApplicationTerminationFlushFailure(
            stage: .analysis,
            message: InjectedTerminationFailure.analysis.localizedDescription
        )))
        #expect(stages == [.caption, .analysis])
    }

    @Test("Quit Without Saving after an Analysis failure still flushes Develop")
    func quitWithoutSavingSkipsOnlyFailedStage() async {
        var stages: [ApplicationTerminationFlushStage] = []
        var developResult = DevelopVersionFlushOutcome.succeeded
        let coordinator = ApplicationTerminationFlushCoordinator(
            captionFlush: { stages.append(.caption) },
            analysisFlush: {
                stages.append(.analysis)
                throw InjectedTerminationFailure.analysis
            },
            developFlush: {
                stages.append(.develop)
                return developResult
            }
        )

        var presented: [ApplicationTerminationFlushStage] = []
        #expect(await coordinator.resolve { failure in
            presented.append(failure.stage)
            return .quitWithoutSaving
        })
        #expect(stages == [.caption, .analysis, .develop])
        #expect(presented == [.analysis])

        // A later Develop failure still raises its own prompt, which can keep the app open.
        stages = []
        presented = []
        developResult = .failed("Injected Develop failure")
        let shouldTerminate = await coordinator.resolve { failure in
            presented.append(failure.stage)
            return failure.stage == .analysis ? .quitWithoutSaving : .keepOpen
        }
        #expect(!shouldTerminate)
        #expect(stages == [.caption, .analysis, .develop])
        #expect(presented == [.analysis, .develop])
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
        #expect(await queue.pendingCountWhenIdle() == 1)

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
        #expect(await queue.pendingCountWhenIdle() == 1)
        #expect(editorCaptures == 1)

        persistence.shouldFail = false
        try await operation.flush()
        #expect(await queue.pendingCountWhenIdle() == 0)
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
        #expect(await queue.pendingCountWhenIdle() == 0)
    }

    @Test("Stages run Browser editor, Caption, Analysis, Develop")
    func fullStageOrder() async {
        #expect(ApplicationTerminationFlushStage.allCases == [.browserEditor, .caption, .analysis, .develop])
        #expect(ApplicationTerminationFlushStage.browserEditor.next == .caption)
        #expect(ApplicationTerminationFlushStage.develop.next == nil)
        var stages: [ApplicationTerminationFlushStage] = []
        let coordinator = ApplicationTerminationFlushCoordinator(
            browserEditorFlush: { stages.append(.browserEditor) },
            captionFlush: { stages.append(.caption) },
            analysisFlush: { stages.append(.analysis) },
            developFlush: {
                stages.append(.develop)
                return .succeeded
            }
        )
        #expect(await coordinator.attempt() == .succeeded)
        #expect(stages == [.browserEditor, .caption, .analysis, .develop])
    }

    @Test("Quit Without Saving on the Browser editor still flushes Caption, and on Caption still flushes the rest")
    func abandoningOneEditorNeverSkipsTheOther() async {
        var stages: [ApplicationTerminationFlushStage] = []
        var failing: Set<ApplicationTerminationFlushStage> = [.browserEditor]
        let coordinator = ApplicationTerminationFlushCoordinator(
            browserEditorFlush: {
                stages.append(.browserEditor)
                if failing.contains(.browserEditor) { throw InjectedTerminationFailure.browserEditor }
            },
            captionFlush: {
                stages.append(.caption)
                if failing.contains(.caption) { throw InjectedTerminationFailure.caption }
            },
            analysisFlush: { stages.append(.analysis) },
            developFlush: {
                stages.append(.develop)
                return .succeeded
            }
        )

        var presented: [ApplicationTerminationFlushFailure] = []
        #expect(await coordinator.resolve { failure in
            presented.append(failure)
            return .quitWithoutSaving
        })
        #expect(stages == [.browserEditor, .caption, .analysis, .develop])
        #expect(presented == [ApplicationTerminationFlushFailure(
            stage: .browserEditor, message: InjectedTerminationFailure.browserEditor.localizedDescription)])

        stages = []
        presented = []
        failing = [.caption]
        #expect(await coordinator.resolve { failure in
            presented.append(failure)
            return .quitWithoutSaving
        })
        #expect(stages == [.browserEditor, .caption, .analysis, .develop])
        #expect(presented.map(\.stage) == [.caption])
    }

    @Test("Caption stage captures every editor and drains the FIFO before a variable-draft failure fails it")
    func captionStageCapturesAndDrainsBeforeVariableCheck() async throws {
        let queue = CaptionDraftPersistenceQueue(label: "caption-termination-test.variables")
        // A retained caption draft whose first write failed; the drain's retry now succeeds.
        let written = TerminationPersistenceGate()
        queue.enqueue { try written.attempt() }
        #expect(await queue.pendingCountWhenIdle() == 1)
        written.shouldFail = false
        let variables = VariableDraftLifecycleCoordinator()
        let variableOwner = UUID()
        variables.register(ownerID: variableOwner) { throw InjectedTerminationFailure.variables }
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue, variableLifecycle: variables)
        let owner = UUID()
        var editorCaptures = 0
        coordinator.register(owner: owner) { editorCaptures += 1 }
        defer { coordinator.unregister(owner: owner) }

        do {
            try await CaptionWorkspaceTerminationFlushOperation(coordinator: coordinator).flush()
            Issue.record("Expected the retained variable draft to fail the Caption stage")
        } catch {
            #expect(error.localizedDescription == InjectedTerminationFailure.variables.localizedDescription)
        }
        // Quit Without Saving on this stage would abandon only the variable draft: the editor was
        // captured and the already queued caption draft is on disk.
        #expect(editorCaptures == 1)
        #expect(written.attempts == 2)
        #expect(await queue.pendingCountWhenIdle() == 0)
    }

    @Test("Failure alerts describe the stage that failed, even while Develop has pending work")
    func failurePresentationFollowsFailedStage() {
        let expectedTitles: [ApplicationTerminationFlushStage: String] = [
            .browserEditor: "Metadata Edits Not Saved",
            .caption: "Caption Save Failed",
            .analysis: "Analysis Save Failed",
        ]
        for (stage, title) in expectedTitles {
            let presentation = ApplicationTerminationFailurePresentation.make(
                for: ApplicationTerminationFlushFailure(stage: stage, message: "Injected \(stage)"),
                developHasPendingPrimaryWork: true
            )
            #expect(presentation.title == title)
            #expect(presentation.message.contains("Injected \(stage)"))
            #expect(presentation.offersRetryAndQuit, "a \(stage) failure keeps Retry / Quit Without Saving")
        }

        let developPending = ApplicationTerminationFailurePresentation.make(
            for: ApplicationTerminationFlushFailure(stage: .develop, message: "Injected develop"),
            developHasPendingPrimaryWork: true
        )
        #expect(developPending.title == "Develop Save Failed")
        #expect(!developPending.offersRetryAndQuit)

        let developVersion = ApplicationTerminationFailurePresentation.make(
            for: ApplicationTerminationFlushFailure(stage: .develop, message: "Injected develop"),
            developHasPendingPrimaryWork: false
        )
        #expect(developVersion.title == "Named Version Save Failed")
        #expect(developVersion.offersRetryAndQuit)
    }

    @Test("A flush that finishes before the timeout never shows the saving prompt")
    func fastFlushDoesNotPrompt() async {
        let clock = TerminationManualClock()
        let coordinator = ApplicationTerminationFlushCoordinator(
            captionFlush: {},
            developFlush: { .succeeded },
            waitTimeout: .seconds(4),
            sleep: { _ in await clock.sleep() }
        )
        var prompts = 0
        let shouldTerminate = await coordinator.resolve(
            chooseWhileWaiting: { _ in
                prompts += 1
                return .keepWaiting
            },
            chooseFailure: { _ in .keepOpen }
        )
        #expect(shouldTerminate)
        #expect(prompts == 0)
        clock.fire()
    }

    @Test("A slow flush prompts after the timeout; Keep Waiting re-arms it and completion dismisses the prompt")
    func slowFlushPromptsAndKeepsWaiting() async {
        let clock = TerminationManualClock()
        let gate = TerminationManualGate()
        var stages: [ApplicationTerminationFlushStage] = []
        let coordinator = ApplicationTerminationFlushCoordinator(
            captionFlush: {
                stages.append(.caption)
                await gate.wait()
            },
            developFlush: {
                stages.append(.develop)
                return .succeeded
            },
            waitTimeout: .seconds(4),
            sleep: { duration in
                #expect(duration == .seconds(4))
                await clock.sleep()
            }
        )
        var promptedStages: [ApplicationTerminationFlushStage?] = []
        var dismissedByCompletion = false
        let resolution = Task { @MainActor in
            await coordinator.resolve(
                chooseWhileWaiting: { context in
                    promptedStages.append(context.stage)
                    #expect(context.activityDescription == ApplicationTerminationFlushStage.caption.activityDescription)
                    if promptedStages.count == 1 { return .keepWaiting }
                    // The modal stays up until the flush finishes and the coordinator dismisses it.
                    return await withCheckedContinuation { continuation in
                        context.whenFlushFinishes {
                            dismissedByCompletion = true
                            continuation.resume(returning: .keepWaiting)
                        }
                        gate.open()
                    }
                },
                chooseFailure: { _ in
                    Issue.record("No failure expected")
                    return .keepOpen
                }
            )
        }

        await clock.waitForSleeps(1)
        clock.fire()
        await clock.waitForSleeps(2)
        clock.fire()
        #expect(await resolution.value)
        #expect(promptedStages == [.caption, .caption])
        #expect(dismissedByCompletion)
        #expect(stages == [.caption, .develop])
        clock.fire()
    }

    @Test("Quit Without Saving on a stalled last stage terminates without waiting for it")
    func waitingQuitWithoutSaving() async {
        let clock = TerminationManualClock()
        let gate = TerminationManualGate()
        var captionCalls = 0
        let coordinator = ApplicationTerminationFlushCoordinator(
            captionFlush: { captionCalls += 1 },
            developFlush: {
                await gate.wait()
                return .succeeded
            },
            waitTimeout: .seconds(4),
            sleep: { _ in await clock.sleep() }
        )
        let resolution = Task { @MainActor in
            await coordinator.resolve(chooseWhileWaiting: { _ in .quitWithoutSaving },
                                      chooseFailure: { _ in .keepOpen })
        }
        await clock.waitForSleeps(1)
        clock.fire()
        #expect(await resolution.value)
        #expect(captionCalls == 1, "earlier stages are not rerun")
        #expect(coordinator.unfinishedAttempt == nil)
        gate.open()
        clock.fire()
    }

    @Test("Quit Without Saving at the saving prompt abandons only the hung stage; the rest still save")
    func waitingQuitWithoutSavingSkipsOnlyRunningStage() async {
        let clock = TerminationManualClock()
        let hung = TerminationManualGate()
        var events: [String] = []
        var hungRuns = 0
        let coordinator = ApplicationTerminationFlushCoordinator(
            browserEditorFlush: {
                hungRuns += 1
                await hung.wait()
                events.append("browserEditor finished")
            },
            captionFlush: { events.append("caption") },
            analysisFlush: { events.append("analysis") },
            developFlush: {
                events.append("develop")
                return .succeeded
            },
            waitTimeout: .seconds(4),
            sleep: { _ in await clock.sleep() },
            describeActivity: { stage in stage == .browserEditor ? "Write All: 340 of 2000" : nil }
        )
        var prompted: [ApplicationTerminationFlushStage?] = []
        var descriptions: [String] = []
        let shouldTerminate = Task { @MainActor in
            await coordinator.resolve(
                chooseWhileWaiting: { context in
                    prompted.append(context.stage)
                    descriptions.append(context.activityDescription)
                    return .quitWithoutSaving
                },
                chooseFailure: { _ in
                    Issue.record("No failure expected")
                    return .keepOpen
                }
            )
        }
        await clock.waitForSleeps(1)
        clock.fire()
        #expect(await shouldTerminate.value)
        #expect(prompted == [.browserEditor])
        #expect(descriptions == ["Write All: 340 of 2000"])
        #expect(events == ["caption", "analysis", "develop"])
        #expect(hungRuns == 1, "the abandoned stage is not restarted")

        // The abandoned attempt finishes its own stage's writes but starts no later stage.
        hung.open()
        for _ in 0..<20 { await Task.yield() }
        #expect(events == ["caption", "analysis", "develop", "browserEditor finished"])
        clock.fire()
    }

    @Test("Captured Primary Develop work cannot be abandoned from the saving prompt")
    func waitingPromptRefusesToAbandonPendingDevelop() async {
        let clock = TerminationManualClock()
        let gate = TerminationManualGate()
        let coordinator = ApplicationTerminationFlushCoordinator(
            captionFlush: {},
            developFlush: {
                await gate.wait()
                return .succeeded
            },
            waitTimeout: .seconds(4),
            sleep: { _ in await clock.sleep() },
            canAbandonStage: { $0 != .develop }
        )
        var allowed: [Bool] = []
        let resolution = Task { @MainActor in
            await coordinator.resolve(
                chooseWhileWaiting: { context in
                    allowed.append(context.allowsQuitWithoutSaving)
                    if allowed.count == 1 { return .quitWithoutSaving } // ignored: treated as Keep Waiting
                    return await withCheckedContinuation { continuation in
                        context.whenFlushFinishes { continuation.resume(returning: .keepWaiting) }
                        gate.open()
                    }
                },
                chooseFailure: { _ in .keepOpen }
            )
        }
        await clock.waitForSleeps(1)
        clock.fire()
        await clock.waitForSleeps(2)
        clock.fire()
        #expect(await resolution.value)
        #expect(allowed == [false, false])
        clock.fire()
    }

    @Test("Cancel Quit stops the attempt after its running stage, and the next quit waits for it first")
    func waitingCancelQuitKeepsWorkRunning() async throws {
        let clock = TerminationManualClock()
        let gate = TerminationManualGate()
        var events: [String] = []
        let coordinator = ApplicationTerminationFlushCoordinator(
            captionFlush: {
                await gate.wait()
                events.append("caption")
            },
            developFlush: {
                events.append("develop")
                return .succeeded
            },
            waitTimeout: .seconds(4),
            sleep: { _ in await clock.sleep() }
        )
        let resolution = Task { @MainActor in
            await coordinator.resolve(chooseWhileWaiting: { _ in .cancelQuit },
                                      chooseFailure: { _ in .keepOpen })
        }
        await clock.waitForSleeps(1)
        clock.fire()
        #expect(await resolution.value == false)
        let unfinished = try #require(coordinator.unfinishedAttempt)
        #expect(events.isEmpty)

        let next = ApplicationTerminationFlushCoordinator(
            browserEditorFlush: { events.append("next quit") },
            captionFlush: {},
            developFlush: { .succeeded },
            precedingWork: { await unfinished.value }
        )
        let nextResolution = Task { @MainActor in
            await next.resolve { _ in .keepOpen }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(events.isEmpty, "the next quit must not start while the earlier writes run")
        gate.open()
        #expect(await nextResolution.value)
        // The cancelled attempt finished Caption's writes but never started Develop, so it
        // cannot commit editors the user moved on with after cancelling.
        #expect(events == ["caption", "next quit"])
        clock.fire()
    }

    @Test("A cancelled attempt starts no later stage")
    func cancelledAttemptStopsBetweenStages() async {
        var stages: [ApplicationTerminationFlushStage] = []
        let attempt = ApplicationTerminationAttempt()
        let coordinator = ApplicationTerminationFlushCoordinator(
            browserEditorFlush: {
                stages.append(.browserEditor)
                attempt.cancel()
            },
            captionFlush: { stages.append(.caption) },
            developFlush: {
                stages.append(.develop)
                return .succeeded
            }
        )
        #expect(await coordinator.attempt(as: attempt) == .cancelled)
        #expect(stages == [.browserEditor])
    }

    @Test("Quit warning lists every running background writer")
    func backgroundOperationSummary() {
        let monitor = BackgroundOperationMonitor()
        #expect(!monitor.hasActiveOperation)
        var scanning = true
        monitor.registerSource("test") { scanning ? ["a face scan"] : [] }
        monitor.isImporting = true
        #expect(monitor.activeOperations == ["an import", "a face scan"])
        #expect(monitor.activeOperationSummary == "an import and a face scan")
        #expect(BackgroundOperationMonitor.quitWarningText(for: monitor.activeOperations)
            .hasPrefix("An import and a face scan are still running."))
        monitor.isImporting = false
        #expect(BackgroundOperationMonitor.quitWarningText(for: monitor.activeOperations)
            .hasPrefix("A face scan is still running."))
        scanning = false
        #expect(!monitor.hasActiveOperation)
        #expect(BackgroundOperationMonitor.summary(of: ["a", "b", "c"]) == "a, b and c")
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
    case browserEditor
    case caption
    case analysis
    case sidecar
    case variables

    var errorDescription: String? {
        switch self {
        case .browserEditor: "Injected Browser editor failure"
        case .caption: "Injected caption failure"
        case .analysis: "Injected analysis failure"
        case .sidecar: "Injected sidecar failure"
        case .variables: "Injected variable draft failure"
        }
    }
}

/// Injected termination clock: each `sleep` suspends until `fire()`.
@MainActor
private final class TerminationManualClock {
    private(set) var sleepCount = 0
    private var sleepers: [CheckedContinuation<Void, Never>] = []

    func sleep() async {
        sleepCount += 1
        await withCheckedContinuation { sleepers.append($0) }
    }

    func fire() {
        let pending = sleepers
        sleepers.removeAll()
        pending.forEach { $0.resume() }
    }

    /// Bounded: records an issue instead of hanging when the expected timer never starts.
    func waitForSleeps(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while sleepCount < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        if sleepCount < count { Issue.record("Timer \(count) never started") }
    }
}

@MainActor
private final class TerminationManualGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
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
    func wait() { semaphore.waitBounded() }
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
