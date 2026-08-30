import AppKit
import Observation

/// Owns publication and cancellation for the materialized Develop preview.
///
/// The Metal preview remains interactive while this lower-frequency render produces the image
/// used by scopes and non-Metal fallbacks. Replacing a request or ending an image session advances
/// an identity gate as well as cancelling the task, so a renderer that does not cooperatively
/// observe cancellation cannot publish pixels from an obsolete edit or image.
@MainActor
@Observable
final class DevelopPreviewRenderCoordinator {
    /// Render outputs cross back from a detached Core Image operation. Both references are treated
    /// as immutable after construction; only the main-actor coordinator publishes or replaces them.
    struct Output: @unchecked Sendable {
        let previewImage: NSImage
        let scopeImage: CGImage

        nonisolated init(previewImage: NSImage, scopeImage: CGImage) {
            self.previewImage = previewImage
            self.scopeImage = scopeImage
        }
    }

    typealias ScopePublisher = @MainActor (_ image: CGImage?, _ isHDR: Bool) -> Void

    private(set) var previewImage: NSImage?
    private(set) var isRendering = false

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()

    /// Clears the previous image's presentation and prevents any of its in-flight work from
    /// publishing. The source-loading lifecycle calls this before it starts decoding a new image.
    func beginImageSession() {
        invalidateRender()
        previewImage = nil
    }

    /// Ends the workspace/image lifecycle without emitting a scope update into a disappearing UI.
    func endImageSession() {
        beginImageSession()
    }

    /// Publishes the source fallback synchronously when no renderable CI source is available.
    /// This retains the existing behavior of notifying scopes even when the fallback itself is nil.
    func publishFallback(
        _ fallback: NSImage?,
        isHDR: Bool,
        scopePublisher: ScopePublisher
    ) {
        invalidateRender()
        previewImage = fallback
        scopePublisher(nil, isHDR)
    }

    /// Replaces the current materialization request. The operation is injected so render policy
    /// and Core Image remain at the view boundary while lifecycle behavior is deterministic in
    /// coordinator tests.
    func requestRender(
        fallback: NSImage?,
        isHDR: Bool,
        operation: @escaping @MainActor () async -> Output?,
        scopePublisher: @escaping ScopePublisher
    ) {
        let currentRequestID = beginRender()
        renderTask = Task { [weak self] in
            let output = await operation()
            guard let self,
                  !Task.isCancelled,
                  requestID == currentRequestID else { return }

            if let output {
                previewImage = output.previewImage
                scopePublisher(output.scopeImage, isHDR)
            } else {
                previewImage = fallback
                scopePublisher(nil, isHDR)
            }
            finishRender(requestID: currentRequestID)
        }
    }

    /// Cancels the current request without clearing the last successfully published preview.
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
