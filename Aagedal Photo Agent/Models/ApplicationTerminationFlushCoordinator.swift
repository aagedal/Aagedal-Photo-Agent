import Foundation

/// Termination flush stages, declared in the order they run.
nonisolated enum ApplicationTerminationFlushStage: String, CaseIterable, Equatable, Sendable {
    /// The Browser metadata panel (shared by Faces and every non-Caption workspace), plus the
    /// Person Shown writes that must not be cut off between writing a photo and recording it.
    case browserEditor
    /// Caption Workspace and Metadata Review editors, their durable FIFO and variable drafts.
    case caption
    case analysis
    case develop

    /// The stage that runs after this one, or nil for the last stage.
    var next: ApplicationTerminationFlushStage? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    /// What this stage is writing, for the "still saving" prompt.
    var activityDescription: String {
        switch self {
        case .browserEditor: "metadata panel edits and Person Shown names"
        case .caption: "Caption Workspace and Metadata Review drafts"
        case .analysis: "Image Analysis case and map edits"
        case .develop: "Develop edits"
        }
    }
}

nonisolated struct ApplicationTerminationFlushFailure: Equatable, Sendable {
    let stage: ApplicationTerminationFlushStage
    let message: String
}

nonisolated enum ApplicationTerminationFlushOutcome: Equatable, Sendable {
    case succeeded
    case failed(ApplicationTerminationFlushFailure)
}

nonisolated enum ApplicationTerminationFailureChoice: Equatable, Sendable {
    case retry
    case keepOpen
    case quitWithoutSaving
}

/// The user's answer to the "still saving" prompt shown when a flush runs long.
nonisolated enum ApplicationTerminationWaitChoice: Equatable, Sendable {
    /// Keep waiting; the prompt returns after another timeout if the flush is still running.
    /// Also what a prompt returns when it was dismissed because the flush finished.
    case keepWaiting
    /// Reply to AppKit now and let the process exit, abandoning the in-flight writes.
    case quitWithoutSaving
    /// Stay open; the in-flight writes keep running.
    case cancelQuit
}

/// Alert content for one termination failure. Kept apart from AppKit so the stage-to-text
/// mapping is testable: the alert must describe the stage that actually failed.
nonisolated struct ApplicationTerminationFailurePresentation: Equatable, Sendable {
    let title: String
    let message: String
    /// False when the only safe answer is to keep the app open (captured Primary Develop edits
    /// that still need Retry Develop Writes or Review Develop Conflicts).
    let offersRetryAndQuit: Bool

    static func make(
        for failure: ApplicationTerminationFlushFailure,
        developHasPendingPrimaryWork: Bool
    ) -> ApplicationTerminationFailurePresentation {
        switch failure.stage {
        case .browserEditor:
            return .init(
                title: "Metadata Edits Not Saved",
                message: "\(failure.message)\n\nThe metadata panel's edits could not be written or kept as a pending draft. Retry saving, keep the app open, or explicitly quit without saving them.",
                offersRetryAndQuit: true)
        case .caption:
            return .init(
                title: "Caption Save Failed",
                message: "Caption Workspace or Metadata Review changes could not be saved: \(failure.message)\n\nRetry the retained drafts, keep the app open, or explicitly quit without saving them.",
                offersRetryAndQuit: true)
        case .analysis:
            return .init(
                title: "Analysis Save Failed",
                message: "The latest Image Analysis case or map edits could not be saved: \(failure.message)\n\nRetry saving, keep the app open, or explicitly quit without saving these changes.",
                offersRetryAndQuit: true)
        case .develop where developHasPendingPrimaryWork:
            return .init(
                title: "Develop Save Failed",
                message: "Captured Primary Develop edits still need attention: \(failure.message)\n\nKeep the app open and use Retry Develop Writes, or Review Develop Conflicts to export the captured edits before discarding them.",
                offersRetryAndQuit: false)
        case .develop:
            return .init(
                title: "Named Version Save Failed",
                message: "The active Develop version could not be saved: \(failure.message)\n\nRetry saving, keep the app open, or explicitly quit without saving these changes.",
                offersRetryAndQuit: true)
        }
    }
}

/// Handed to the "still saving" prompt. A modal presenter registers `whenFlushFinishes` right
/// before it enters its modal loop. The handler is delivered in a later main-actor turn (never
/// during the call) and only while the prompt is still showing, so it can end that modal
/// session without ever touching a later alert.
@MainActor
final class ApplicationTerminationWaitContext {
    /// The stage still running, or nil while an earlier, cancelled quit's writes finish.
    let stage: ApplicationTerminationFlushStage?
    private(set) var isFlushFinished = false
    private var handler: (@MainActor () -> Void)?
    private var isShowing = true

    init(stage: ApplicationTerminationFlushStage?) {
        self.stage = stage
    }

    var activityDescription: String {
        stage?.activityDescription ?? "changes from the earlier quit attempt"
    }

    func whenFlushFinishes(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        if isFlushFinished { deliver() }
    }

    fileprivate func markFlushFinished() {
        guard !isFlushFinished else { return }
        isFlushFinished = true
        deliver()
    }

    fileprivate func invalidate() {
        isShowing = false
        handler = nil
    }

    private func deliver() {
        Task { @MainActor [weak self] in
            guard let self, self.isShowing, let handler = self.handler else { return }
            self.handler = nil
            handler()
        }
    }
}

/// Testable ordering, retry and timeout boundary for application termination. The Browser
/// metadata editor flushes first, then Caption persistence, then pending Analysis saves, then
/// Develop; a failure stops the later stages until the user chooses. Quit Without Saving abandons
/// only the failed stage: later stages still flush and may raise their own prompt.
///
/// With a `waitTimeout`, an attempt still running after it asks `chooseWhileWaiting` whether to
/// keep waiting (re-arms the timeout), quit without saving, or cancel the quit. A cancelled
/// quit leaves its writes running; `unfinishedAttempt` lets the next quit wait for them first.
@MainActor
final class ApplicationTerminationFlushCoordinator {
    typealias StageFlush = @MainActor () async throws -> Void
    typealias DevelopFlush = @MainActor () async -> DevelopVersionFlushOutcome
    typealias Sleep = @MainActor (Duration) async throws -> Void
    typealias WaitPrompt = @MainActor (ApplicationTerminationWaitContext) async -> ApplicationTerminationWaitChoice
    typealias FailurePrompt = @MainActor (ApplicationTerminationFlushFailure) -> ApplicationTerminationFailureChoice

    private let browserEditorFlush: StageFlush
    private let captionFlush: StageFlush
    private let analysisFlush: StageFlush
    private let developFlush: DevelopFlush
    private var precedingWork: (@MainActor () async -> Void)?
    private let waitTimeout: Duration?
    private let sleep: Sleep

    /// The stage the current attempt is running; nil between attempts or while `precedingWork` runs.
    private(set) var runningStage: ApplicationTerminationFlushStage?
    /// The attempt Cancel Quit left running, if any.
    private(set) var unfinishedAttempt: Task<Void, Never>?

    init(
        browserEditorFlush: @escaping StageFlush = {},
        captionFlush: @escaping StageFlush,
        analysisFlush: @escaping StageFlush = {},
        developFlush: @escaping DevelopFlush,
        precedingWork: (@MainActor () async -> Void)? = nil,
        waitTimeout: Duration? = nil,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.browserEditorFlush = browserEditorFlush
        self.captionFlush = captionFlush
        self.analysisFlush = analysisFlush
        self.developFlush = developFlush
        self.precedingWork = precedingWork
        self.waitTimeout = waitTimeout
        self.sleep = sleep
    }

    /// Runs the stages in order, beginning with `firstStage`.
    func attempt(
        from firstStage: ApplicationTerminationFlushStage = .browserEditor
    ) async -> ApplicationTerminationFlushOutcome {
        defer { runningStage = nil }
        for stage in ApplicationTerminationFlushStage.allCases.drop(while: { $0 != firstStage }) {
            runningStage = stage
            if let failure = await run(stage) { return .failed(failure) }
        }
        return .succeeded
    }

    private func run(_ stage: ApplicationTerminationFlushStage) async -> ApplicationTerminationFlushFailure? {
        let flush: StageFlush
        switch stage {
        case .browserEditor: flush = browserEditorFlush
        case .caption: flush = captionFlush
        case .analysis: flush = analysisFlush
        case .develop:
            switch await developFlush() {
            case .succeeded: return nil
            case let .failed(message): return ApplicationTerminationFlushFailure(stage: .develop, message: message)
            }
        }
        do {
            try await flush()
            return nil
        } catch {
            return ApplicationTerminationFlushFailure(stage: stage, message: error.localizedDescription)
        }
    }

    /// Returns whether termination should proceed after presenting each failure to the caller.
    /// Retry remains within the original AppKit terminate-later request, so exactly one reply is
    /// ultimately required.
    func resolve(chooseFailure: FailurePrompt) async -> Bool {
        await resolve(chooseWhileWaiting: { _ in .keepWaiting }, chooseFailure: chooseFailure)
    }

    /// Like `resolve(chooseFailure:)`, and asks `chooseWhileWaiting` whenever an attempt is still
    /// running after `waitTimeout`. Every path returns exactly once: true to terminate.
    func resolve(
        chooseWhileWaiting: WaitPrompt,
        chooseFailure: FailurePrompt
    ) async -> Bool {
        var firstStage = ApplicationTerminationFlushStage.browserEditor
        while true {
            let stageStart = firstStage
            let preceding = precedingWork
            precedingWork = nil
            let work = Task { @MainActor in
                await preceding?()
                return await self.attempt(from: stageStart)
            }

            var outcome: ApplicationTerminationFlushOutcome?
            while outcome == nil {
                if let finished = await awaitAttempt(work) {
                    outcome = finished
                    break
                }
                let context = ApplicationTerminationWaitContext(stage: runningStage)
                Task { @MainActor in
                    _ = await work.value
                    context.markFlushFinished()
                }
                let choice = await chooseWhileWaiting(context)
                context.invalidate()
                switch choice {
                case .keepWaiting:
                    continue
                case .quitWithoutSaving:
                    return true
                case .cancelQuit:
                    unfinishedAttempt = Task { @MainActor in _ = await work.value }
                    return false
                }
            }

            guard case let .failed(failure)? = outcome else { return true }
            switch chooseFailure(failure) {
            case .retry:
                continue
            case .keepOpen:
                return false
            case .quitWithoutSaving:
                // Skip only the abandoned stage; the remaining stages still get to save.
                guard let next = failure.stage.next else { return true }
                firstStage = next
            }
        }
    }

    /// The attempt's outcome, or nil when `waitTimeout` elapsed first.
    private func awaitAttempt(
        _ work: Task<ApplicationTerminationFlushOutcome, Never>
    ) async -> ApplicationTerminationFlushOutcome? {
        guard let waitTimeout else { return await work.value }
        let race = TerminationAttemptRace()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            let timer = Task { @MainActor in
                try? await self.sleep(waitTimeout)
                race.finish(nil)
            }
            Task { @MainActor in
                let outcome = await work.value
                timer.cancel()
                race.finish(outcome)
            }
        }
    }
}

/// First-of-two resumption for `awaitAttempt`: whichever of the attempt and the timer finishes
/// first resumes the waiter; the other is ignored.
@MainActor
private final class TerminationAttemptRace {
    var continuation: CheckedContinuation<ApplicationTerminationFlushOutcome?, Never>?

    func finish(_ outcome: ApplicationTerminationFlushOutcome?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
    }
}

/// Prevents re-entrant termination requests and duplicate AppKit replies while an async flush is
/// pending. A new request may begin only after the prior request has produced its single reply.
@MainActor
final class ApplicationTerminationReplyLatch {
    private(set) var isPending = false

    func begin() -> Bool {
        guard !isPending else { return false }
        isPending = true
        return true
    }

    func finish() -> Bool {
        guard isPending else { return false }
        isPending = false
        return true
    }
}

nonisolated enum CaptionWorkspaceFocusRestoreTarget: Equatable, Sendable {
    case captionEditor
    case browserGrid
    case unchanged
}

nonisolated enum CaptionWorkspaceFocusRestorePolicy {
    static func target(
        afterTransientPresentationInCaptionWorkspace isCaptionWorkspace: Bool,
        restoreRequested: Bool
    ) -> CaptionWorkspaceFocusRestoreTarget {
        guard restoreRequested else { return .unchanged }
        return isCaptionWorkspace ? .captionEditor : .browserGrid
    }
}
