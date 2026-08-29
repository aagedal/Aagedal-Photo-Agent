import Foundation
import Observation

/// Owns the transient render lifecycle for Compare launched from the Develop workspace.
///
/// Opening a comparison defines a new request boundary. Replacing the target, retrying, closing
/// Compare, or ending the workspace cancels the current task and advances a token. The token gate
/// prevents a renderer that ignores cooperative cancellation from publishing stale pixels or an
/// obsolete error. Rendering itself is injected as an async closure so this lifecycle remains
/// deterministic in tests and independent of the concrete decode pipeline.
@MainActor
@Observable
final class DevelopComparisonRenderCoordinator {
    struct VersionRenderResult: @unchecked Sendable {
        let live: ComparisonRenderedSource
        let target: ComparisonRenderedSource
    }

    var imageTarget: ImageFile?
    var versionTarget: DevelopVersionComparisonTarget?
    private(set) var liveSource: ComparisonRenderedSource?
    private(set) var versionTargetSource: ComparisonRenderedSource?
    private(set) var errorMessage: String?
    private(set) var isRendering = false

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private let renderDelay: Duration

    init(renderDelay: Duration = .milliseconds(120)) {
        self.renderDelay = renderDelay
    }

    var isActive: Bool {
        imageTarget != nil || versionTarget != nil
    }

    func openImageComparison(target: ImageFile) {
        invalidateRender()
        imageTarget = target
        versionTarget = nil
        clearOutput()
    }

    func openVersionComparison(target: DevelopVersionComparisonTarget) {
        invalidateRender()
        imageTarget = nil
        versionTarget = target
        clearOutput()
    }

    func close() {
        invalidateRender()
        imageTarget = nil
        versionTarget = nil
        clearOutput()
    }

    /// Stops the current decode without clearing the presented comparison. A later result is still
    /// rejected even if the injected renderer ignores cancellation.
    func cancelRender() {
        invalidateRender()
    }

    func renderImage(
        _ operation: @escaping @MainActor () async throws -> ComparisonRenderedSource
    ) {
        guard let targetURL = imageTarget?.url, versionTarget == nil else { return }
        let currentRequestID = beginRender()
        renderTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await Task.sleep(for: renderDelay)
                let result = try await operation()
                try Task.checkCancellation()
                guard requestID == currentRequestID,
                      imageTarget?.url == targetURL,
                      versionTarget == nil else { return }
                liveSource = result
                finishRender(requestID: currentRequestID)
            } catch is CancellationError {
                self?.finishRender(requestID: currentRequestID)
            } catch {
                guard let self, requestID == currentRequestID,
                      imageTarget?.url == targetURL,
                      versionTarget == nil else { return }
                errorMessage = error.localizedDescription
                finishRender(requestID: currentRequestID)
            }
        }
    }

    func renderVersion(
        target: DevelopVersionComparisonTarget,
        _ operation: @escaping @MainActor () async throws -> VersionRenderResult
    ) {
        guard versionTarget == target, imageTarget == nil else { return }
        let currentRequestID = beginRender()
        renderTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await Task.sleep(for: renderDelay)
                let result = try await operation()
                try Task.checkCancellation()
                guard requestID == currentRequestID,
                      versionTarget == target,
                      imageTarget == nil else { return }
                liveSource = result.live
                versionTargetSource = result.target
                finishRender(requestID: currentRequestID)
            } catch is CancellationError {
                self?.finishRender(requestID: currentRequestID)
            } catch {
                guard let self, requestID == currentRequestID,
                      versionTarget == target,
                      imageTarget == nil else { return }
                errorMessage = error.localizedDescription
                finishRender(requestID: currentRequestID)
            }
        }
    }

    private func beginRender() -> UUID {
        invalidateRender()
        let currentRequestID = requestID
        errorMessage = nil
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

    private func clearOutput() {
        liveSource = nil
        versionTargetSource = nil
        errorMessage = nil
    }
}
