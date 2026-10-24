import AppKit
import Observation

/// Owns publication and cancellation for the materialized Develop scope source.
///
/// The Metal preview and Metal scope stay live on their own; this lower-frequency render exists
/// only for the CPU scope fallback (no Metal scope pipeline or no uploaded source texture).
/// Replacing a request or ending an image session advances an identity gate as well as
/// cancelling the task, so a renderer that does not cooperatively observe cancellation cannot
/// publish pixels from an obsolete edit or image. Requests made within one main-actor turn
/// coalesce: only the last one starts its operation.
@MainActor
@Observable
final class DevelopPreviewRenderCoordinator {
    /// Render output crossing back from detached Core Image work. `CGImage` is immutable.
    struct Output: Sendable {
        let scopeImage: CGImage

        nonisolated init(scopeImage: CGImage) {
            self.scopeImage = scopeImage
        }
    }

    typealias ScopePublisher = @MainActor (_ image: CGImage?, _ isHDR: Bool) -> Void

    private(set) var isRendering = false

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()

    /// Prevents any of the previous image's in-flight work from publishing. The source-loading
    /// lifecycle calls this before it starts decoding a new image.
    func beginImageSession() {
        invalidateRender()
    }

    /// Ends the workspace/image lifecycle without emitting a scope update into a disappearing UI.
    func endImageSession() {
        beginImageSession()
    }

    /// Publishes "no CPU scope image" synchronously: used when no renderable CI source exists
    /// and when the Metal scope already presents the edit (so the scope still learns the HDR
    /// mode for its waveform scale and gamut without a redundant offscreen render).
    func publishWithoutImage(
        isHDR: Bool,
        scopePublisher: ScopePublisher
    ) {
        invalidateRender()
        scopePublisher(nil, isHDR)
    }

    /// Replaces the current materialization request. The operation is injected so render policy
    /// and Core Image remain at the view boundary while lifecycle behavior is deterministic in
    /// coordinator tests. The operation runs inside the request task, so replacing or cancelling
    /// the request cancels it.
    func requestRender(
        isHDR: Bool,
        operation: @escaping @MainActor () async -> Output?,
        scopePublisher: @escaping ScopePublisher
    ) {
        let currentRequestID = beginRender()
        renderTask = Task { [weak self] in
            // A later request in the same main-actor turn has already cancelled this one.
            guard !Task.isCancelled else { return }
            let output = await operation()
            guard let self,
                  !Task.isCancelled,
                  requestID == currentRequestID else { return }

            scopePublisher(output?.scopeImage, isHDR)
            finishRender(requestID: currentRequestID)
        }
    }

    /// Cancels the current request.
    func cancelRender() {
        invalidateRender()
    }

    private func beginRender() -> UUID {
        invalidateRender()
        let currentRequestID = requestID
        isRendering = true
        return currentRequestID
    }

    private func invalidateRender() {
        renderTask?.cancel()
        renderTask = nil
        requestID = UUID()
        isRendering = false
    }

    private func finishRender(requestID completedRequestID: UUID) {
        guard requestID == completedRequestID else { return }
        renderTask = nil
        isRendering = false
    }
}
