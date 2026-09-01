import Foundation
import Observation

/// Owns the Develop workspace's process-local input session.
///
/// AppKit event monitors are registrations with explicit teardown requirements rather than view
/// values. Keeping all three registrations here prevents replacement presentations from leaking
/// a local monitor, while the observable hover and hand-tool state remains scoped to the same
/// workspace lifetime. Event interpretation stays injected at `EditWorkspaceView`.
@MainActor
@Observable
final class DevelopWorkspaceInputCoordinator {
    typealias MonitorRemoval = @MainActor (Any) -> Void

    private struct MonitorRegistration {
        let token: Any
        let remove: MonitorRemoval

        func cancel() {
            remove(token)
        }
    }

    private(set) var isWorkspaceActive = false
    var isCursorOverPreview = false
    var hoveredFilmstripURL: URL?
    var isSpaceHandToolActive = false
    var filmstripKeyboardScrollTarget: URL?

    @ObservationIgnored private var scrollMonitor: MonitorRegistration?
    @ObservationIgnored private var keyMonitor: MonitorRegistration?
    @ObservationIgnored private var middleMouseMonitor: MonitorRegistration?

    var hasScrollMonitor: Bool { scrollMonitor != nil }
    var hasKeyMonitor: Bool { keyMonitor != nil }
    var hasMiddleMouseMonitor: Bool { middleMouseMonitor != nil }

    /// Begins a clean presentation. Defensive teardown also makes a repeated SwiftUI appearance
    /// safe when an earlier disappearance was interrupted.
    func beginWorkspace() {
        removeAllMonitors()
        resetTransientState()
        isWorkspaceActive = true
    }

    func installScrollMonitor(_ token: Any, remove: @escaping MonitorRemoval) {
        guard isWorkspaceActive else {
            remove(token)
            return
        }
        scrollMonitor?.cancel()
        scrollMonitor = MonitorRegistration(token: token, remove: remove)
    }

    func installKeyMonitor(_ token: Any, remove: @escaping MonitorRemoval) {
        guard isWorkspaceActive else {
            remove(token)
            return
        }
        keyMonitor?.cancel()
        keyMonitor = MonitorRegistration(token: token, remove: remove)
    }

    func installMiddleMouseMonitor(_ token: Any, remove: @escaping MonitorRemoval) {
        guard isWorkspaceActive else {
            remove(token)
            return
        }
        middleMouseMonitor?.cancel()
        middleMouseMonitor = MonitorRegistration(token: token, remove: remove)
    }

    func removeScrollMonitor() {
        scrollMonitor?.cancel()
        scrollMonitor = nil
    }

    /// Ends the complete process-local input lifetime. Each installed token is removed exactly
    /// once and every hover/temporary-navigation value is cleared together.
    func endWorkspace() {
        removeAllMonitors()
        resetTransientState()
        isWorkspaceActive = false
    }

    private func removeAllMonitors() {
        scrollMonitor?.cancel()
        keyMonitor?.cancel()
        middleMouseMonitor?.cancel()
        scrollMonitor = nil
        keyMonitor = nil
        middleMouseMonitor = nil
    }

    private func resetTransientState() {
        isCursorOverPreview = false
        hoveredFilmstripURL = nil
        isSpaceHandToolActive = false
        filmstripKeyboardScrollTarget = nil
    }
}
