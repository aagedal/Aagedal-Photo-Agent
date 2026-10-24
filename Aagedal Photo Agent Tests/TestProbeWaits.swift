import Foundation

/// Test probes block shared serial queues (filesystem, keyword lists, exports) until a test
/// releases them. An unbounded wait means a test that fails before releasing — for example a
/// timed-out "started" check under full-suite load — wedges that queue for every later test and
/// hangs the whole run. Bounded waits turn that into an ordinary failure of the one test.
///
/// The limit stays below the 30 s that tests allow for a probe to be reached: an abandoned probe
/// must free its queue before the next test queued behind it gives up too, or one slow test under
/// full-suite load cascades into every later test that shares the queue. Probes are normally
/// released within milliseconds, so this only bounds the failure path.
nonisolated let testProbeWaitLimit: TimeInterval = 20

extension NSCondition {
    /// Waits for a signal for at most `testProbeWaitLimit`. Returns false on timeout so callers
    /// in a `while` loop can stop waiting instead of re-arming forever.
    @discardableResult
    nonisolated func waitBounded() -> Bool {
        wait(until: Date(timeIntervalSinceNow: testProbeWaitLimit))
    }
}

extension DispatchSemaphore {
    /// A bounded `wait()` for test probes; see `testProbeWaitLimit`.
    nonisolated func waitBounded() {
        _ = wait(timeout: .now() + testProbeWaitLimit)
    }
}
