import Foundation

nonisolated enum ApplicationTerminationFlushStage: String, Equatable, Sendable {
    case caption
    case analysis
    case develop
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

/// Testable ordering and retry boundary for application termination. Caption persistence always
/// completes first, then pending Analysis saves, then Develop; a failure stops the later stages
/// until the user chooses. Quit Without Saving abandons only the failed stage: later stages still
/// flush and may raise their own prompt.
@MainActor
final class ApplicationTerminationFlushCoordinator {
    typealias CaptionFlush = @MainActor () async throws -> Void
    typealias AnalysisFlush = @MainActor () async throws -> Void
    typealias DevelopFlush = @MainActor () async -> DevelopVersionFlushOutcome

    private let captionFlush: CaptionFlush
    private let analysisFlush: AnalysisFlush
    private let developFlush: DevelopFlush

    init(
        captionFlush: @escaping CaptionFlush,
        analysisFlush: @escaping AnalysisFlush = {},
        developFlush: @escaping DevelopFlush
    ) {
        self.captionFlush = captionFlush
        self.analysisFlush = analysisFlush
        self.developFlush = developFlush
    }

    /// Runs the stages in order, beginning with `firstStage`.
    func attempt(
        from firstStage: ApplicationTerminationFlushStage = .caption
    ) async -> ApplicationTerminationFlushOutcome {
        if firstStage == .caption {
            do {
                try await captionFlush()
            } catch {
                return .failed(ApplicationTerminationFlushFailure(
                    stage: .caption,
                    message: error.localizedDescription
                ))
            }
        }

        if firstStage != .develop {
            do {
                try await analysisFlush()
            } catch {
                return .failed(ApplicationTerminationFlushFailure(
                    stage: .analysis,
                    message: error.localizedDescription
                ))
            }
        }

        switch await developFlush() {
        case .succeeded:
            return .succeeded
        case let .failed(message):
            return .failed(ApplicationTerminationFlushFailure(stage: .develop, message: message))
        }
    }

    /// Returns whether termination should proceed after presenting each failure to the caller.
    /// Retry remains within the original AppKit terminate-later request, so exactly one reply is
    /// ultimately required.
    func resolve(
        chooseFailure: @MainActor (ApplicationTerminationFlushFailure) -> ApplicationTerminationFailureChoice
    ) async -> Bool {
        var firstStage = ApplicationTerminationFlushStage.caption
        while true {
            switch await attempt(from: firstStage) {
            case .succeeded:
                return true
            case let .failed(failure):
                switch chooseFailure(failure) {
                case .retry:
                    continue
                case .keepOpen:
                    return false
                case .quitWithoutSaving:
                    // Skip only the abandoned stage; the remaining stages still get to save.
                    switch failure.stage {
                    case .caption: firstStage = .analysis
                    case .analysis: firstStage = .develop
                    case .develop: return true
                    }
                }
            }
        }
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
