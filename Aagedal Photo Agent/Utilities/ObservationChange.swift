import Foundation
import Observation

/// Suspends until one of the observable properties read by `track` changes, or until the calling
/// task is cancelled.
///
/// Observation loops in long-lived AppKit controllers used to write
/// `guard let self` followed by `await withCheckedContinuation { withObservationTracking { self... } }`,
/// which keeps `self` strongly retained for the whole suspension. Because the suspension only ends
/// on the next change, the controller could never deallocate and its `deinit` (the only place the
/// loop was cancelled) never ran. Callers of this helper capture the observed model directly and
/// re-acquire a weak owner after it returns, and cancellation resumes the wait immediately so a
/// torn-down controller's task ends without waiting for another model change.
///
/// The change callback fires in `willSet`; the awaiting main-actor task resumes on a later turn, so
/// values read after this returns are the new ones.
@MainActor
func awaitObservationChange(_ track: () -> Void) async {
    let gate = ObservationResumeGate()
    await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.install(continuation)
            withObservationTracking(track) { gate.fire() }
        }
    } onCancel: {
        gate.fire()
    }
}

/// Resumes a continuation exactly once, whichever of "observed change" and "task cancelled"
/// happens first (cancellation may also arrive before the continuation is installed).
nonisolated final class ObservationResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = lock.withLock { () -> Bool in
            if fired { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func fire() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            fired = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}
