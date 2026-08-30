import CoreGraphics
import Foundation
import Observation

/// The persistence boundary crossed when an interactive Develop control stops changing.
nonisolated enum DevelopInteractiveRenderPersistenceIntent: Equatable {
    /// High-frequency interaction is render-only; durable metadata must not be written yet.
    case previewOnly
    /// A completed slider gesture requests the view's existing XMP/named-version commit path.
    case commit
}

/// Owns high-frequency Develop render policy without owning pixels or persistence.
///
/// The editor injects scope rendering and publication so Core Image, notifications, and durable
/// metadata remain at their existing boundaries. This coordinator owns slider-interaction
/// lifecycle, the 10 Hz CPU-scope throttle, cancellation, and a request identity gate. The gate
/// prevents a detached renderer that ignores cooperative cancellation from publishing pixels for
/// a superseded edit, image, or workspace session.
@MainActor
@Observable
final class DevelopInteractiveRenderCoordinator {
    /// Immutable scope output returned by injected rendering work.
    struct ScopeOutput: @unchecked Sendable {
        let image: CGImage
        let isHDR: Bool

        nonisolated init(image: CGImage, isHDR: Bool) {
            self.image = image
            self.isHDR = isHDR
        }
    }

    typealias ScopeOperation = @MainActor () async -> ScopeOutput?
    typealias ScopePublisher = @MainActor (CGImage, Bool) -> Void

    private(set) var isWorkspaceActive = false
    private(set) var isSliderInteractionActive = false
    private(set) var isScopePublicationPending = false

    @ObservationIgnored private let minimumScopeInterval: Duration
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var lastScopeRequestTime: ContinuousClock.Instant
    @ObservationIgnored private var scopeTask: Task<Void, Never>?
    @ObservationIgnored private var scopeRequestID = UUID()

    init(minimumScopeInterval: Duration = .milliseconds(100)) {
        self.minimumScopeInterval = minimumScopeInterval
        lastScopeRequestTime = clock.now
    }

    /// Starts a workspace lifetime with no inherited gesture or pending publication.
    func beginWorkspace() {
        invalidateScopePublication()
        isWorkspaceActive = true
        isSliderInteractionActive = false
        lastScopeRequestTime = clock.now
    }

    /// Image replacement is a publication boundary even if detached work ignores cancellation.
    func beginImageSession() {
        invalidateScopePublication()
        isSliderInteractionActive = false
        lastScopeRequestTime = clock.now
    }

    /// Ends interactive rendering and rejects every outstanding scope result.
    func endWorkspace() {
        invalidateScopePublication()
        isSliderInteractionActive = false
        isWorkspaceActive = false
    }

    /// Records slider gesture state and reports whether the caller should cross its persistence
    /// boundary. Repeated state callbacks are idempotent and never request duplicate commits.
    @discardableResult
    func setSliderInteraction(
        active: Bool
    ) -> DevelopInteractiveRenderPersistenceIntent {
        guard isWorkspaceActive, active != isSliderInteractionActive else { return .previewOnly }
        isSliderInteractionActive = active
        if active {
            return .previewOnly
        }
        invalidateScopePublication()
        return .commit
    }

    /// Coalesces CPU-scope work to at most one request per interval. Replacing a request cancels
    /// its task and advances an identity token; late non-cooperative output is therefore harmless.
    func requestScopePublication(
        operation: @escaping ScopeOperation,
        publisher: @escaping ScopePublisher
    ) {
        guard isWorkspaceActive, isSliderInteractionActive else { return }

        invalidateScopePublication()
        let requestID = scopeRequestID
        let now = clock.now
        let elapsed = now - lastScopeRequestTime
        let delay = elapsed >= minimumScopeInterval ? Duration.zero : minimumScopeInterval - elapsed
        if delay == .zero {
            lastScopeRequestTime = now
        }
        isScopePublicationPending = true

        scopeTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard let self,
                      !Task.isCancelled,
                      scopeRequestID == requestID else { return }
                lastScopeRequestTime = clock.now
            }

            let output = await operation()
            guard let self,
                  !Task.isCancelled,
                  scopeRequestID == requestID else { return }
            if let output {
                publisher(output.image, output.isHDR)
            }
            finishScopePublication(requestID: requestID)
        }
    }

    /// Cancels throttled or rendering work without changing slider interaction state.
    func cancelScopePublication() {
        invalidateScopePublication()
    }

    private func invalidateScopePublication() {
        scopeTask?.cancel()
        scopeTask = nil
        scopeRequestID = UUID()
        isScopePublicationPending = false
    }

    private func finishScopePublication(requestID completedRequestID: UUID) {
        guard scopeRequestID == completedRequestID else { return }
        scopeTask = nil
        isScopePublicationPending = false
    }
}
