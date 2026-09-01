import Foundation
import Observation

/// Owns state whose lifetime is the complete Develop workspace rather than one image.
///
/// Named-version flush registration must survive image navigation but be removed when the
/// workspace disappears. Transient copy/paste/template notices follow the same presentation
/// lifetime and have replaceable timers, so an older timer cannot clear a newer message.
@MainActor
@Observable
final class DevelopWorkspaceSessionCoordinator {
    typealias FlushHandler = DevelopVersionFlushCoordinator.Handler

    private struct FlushRegistration {
        let coordinator: DevelopVersionFlushCoordinator
        let id: UUID

        func cancel() {
            coordinator.unregister(id)
        }
    }

    private(set) var isWorkspaceActive = false
    private(set) var notice: String?

    @ObservationIgnored private let noticeDuration: Duration
    @ObservationIgnored private var flushRegistration: FlushRegistration?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var noticeRequestID = UUID()

    init(noticeDuration: Duration = .seconds(1)) {
        self.noticeDuration = noticeDuration
    }

    /// Begins a clean workspace presentation and installs its app-transition flush boundary.
    /// Repeated appearance defensively tears down every registration and timer from the prior
    /// presentation before publishing the replacement lifetime.
    func beginWorkspace(
        flushCoordinator: DevelopVersionFlushCoordinator = .shared,
        flushHandler: @escaping FlushHandler
    ) {
        endWorkspace()
        isWorkspaceActive = true
        let id = flushCoordinator.register(flushHandler)
        flushRegistration = FlushRegistration(coordinator: flushCoordinator, id: id)
    }

    /// Publishes one short-lived notice. Replacement invalidates both the previous task and its
    /// request identity because cancellation alone cannot stop already-resumed task code.
    func showNotice(_ message: String) {
        guard isWorkspaceActive else { return }
        invalidateNotice()
        notice = message
        let requestID = noticeRequestID
        let duration = noticeDuration
        noticeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  isWorkspaceActive,
                  noticeRequestID == requestID else { return }
            notice = nil
            noticeTask = nil
        }
    }

    /// Ends the workspace presentation and rejects every late notice or app-level flush handoff.
    func endWorkspace() {
        invalidateNotice()
        notice = nil
        flushRegistration?.cancel()
        flushRegistration = nil
        isWorkspaceActive = false
    }

    private func invalidateNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        noticeRequestID = UUID()
    }
}
