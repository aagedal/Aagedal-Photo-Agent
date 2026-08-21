import Foundation

nonisolated enum ApplicationTerminationFlushStage: String, Equatable, Sendable {
    case caption
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
/// completes before Develop is asked to flush; a failure stops the later stage.
@MainActor
final class ApplicationTerminationFlushCoordinator {
    typealias CaptionFlush = @MainActor () async throws -> Void
    typealias DevelopFlush = @MainActor () async -> DevelopVersionFlushOutcome

    private let captionFlush: CaptionFlush
    private let developFlush: DevelopFlush

    init(
        captionFlush: @escaping CaptionFlush,
        developFlush: @escaping DevelopFlush
    ) {
        self.captionFlush = captionFlush
        self.developFlush = developFlush
    }

    func attempt() async -> ApplicationTerminationFlushOutcome {
        do {
            try await captionFlush()
        } catch {
            return .failed(ApplicationTerminationFlushFailure(
                stage: .caption,
                message: error.localizedDescription
            ))
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
        while true {
            switch await attempt() {
            case .succeeded:
                return true
            case let .failed(failure):
                switch chooseFailure(failure) {
                case .retry:
                    continue
                case .keepOpen:
                    return false
                case .quitWithoutSaving:
                    return true
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
