import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@MainActor
struct AdobeDNGDiscoveryTests {
    @Test("DNG lookup probes candidates off MainActor in priority order")
    func orderedLookup() async {
        let first = URL(fileURLWithPath: "/registered.app")
        let second = URL(fileURLWithPath: "/fallback.app")
        let service = AdobeDNGDiscoveryService(applications: {
            #expect(!Thread.isMainThread)
            return [first, second, URL(fileURLWithPath: "/unused.app")]
        }, executable: { url in
            #expect(!Thread.isMainThread)
            #expect(url == first || url == second)
            return url == second ? second : nil
        })
        #expect(await service.discover() == .complete(executableURL: second))
    }

    @Test("Cancelled DNG lookup preserves its exact inspected prefix")
    func cancellationAfterProbe() async {
        let service = AdobeDNGDiscoveryService(applications: {
            [URL(fileURLWithPath: "/first.app"), URL(fileURLWithPath: "/unused.app")]
        }, executable: { url in
            #expect(url.path == "/first.app")
            withUnsafeCurrentTask { $0?.cancel() }
            return url
        })
        let task = Task { await service.discover() }
        #expect(await task.value == .cancelled(inspectedCount: 1))
    }

    @Test("Cancellation before DNG lookup skips Launch Services and executable probes")
    func cancellationBeforeLookup() async {
        let service = AdobeDNGDiscoveryService(applications: {
            Issue.record("Cancelled lookup must not resolve applications")
            return []
        }, executable: { _ in
            Issue.record("Cancelled lookup must not inspect executables")
            return nil
        })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.discover()
        }
        #expect(await task.value == .cancelled(inspectedCount: 0))
    }

    @Test("Cancelled discovery does not publish an unavailable menu snapshot")
    func cancellationKeepsCacheUnknown() async {
        let service = AdobeDNGDiscoveryService(applications: {
            withUnsafeCurrentTask { $0?.cancel() }
            return []
        })
        let store = AdobeDNGDiscoveryStore(service: service)
        let task = Task { await store.refresh() }
        #expect(await task.value == .cancelled(inspectedCount: 0))
        #expect(!store.hasChecked)
        #expect(store.executableURL == nil)
    }

    @Test("Cancelled refresh retains the last complete executable snapshot")
    func cancelledRefreshRetainsCache() async {
        let gate = DNGDiscoveryGate(cancelSecond: true)
        gate.releaseAll()
        let service = AdobeDNGDiscoveryService(applications: {
            [URL(fileURLWithPath: "/converter.app")]
        }, executable: { _ in gate.probe() })
        let store = AdobeDNGDiscoveryStore(service: service)
        #expect(await store.refresh() == .complete(executableURL: gate.firstURL))
        let cancelled = Task { await store.refresh() }
        #expect(await cancelled.value == .cancelled(inspectedCount: 1))
        #expect(store.hasChecked)
        #expect(store.executableURL == gate.firstURL)
    }

    @Test("Superseded DNG refresh cannot publish while its replacement is still probing")
    func replacementPublication() async throws {
        let gate = DNGDiscoveryGate()
        defer { gate.releaseAll() }
        let service = AdobeDNGDiscoveryService(applications: {
            [URL(fileURLWithPath: "/converter.app")]
        }, executable: { _ in gate.probe() })
        let store = AdobeDNGDiscoveryStore(service: service)
        let first = Task { await store.refresh() }
        try await gate.waitForCount(1)
        var replacement: Task<AdobeDNGDiscoveryResult, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            replacement = Task {
                started.resume()
                return await store.refresh()
            }
        }
        // The continuation resumes on MainActor after refresh sets its request identity
        // and suspends at the worker boundary.
        gate.release(0)
        try await gate.waitForCount(2)
        #expect(await first.value == .complete(executableURL: gate.firstURL))
        #expect(!store.hasChecked)
        gate.release(1)
        #expect(await replacement?.value == .complete(executableURL: nil))
        #expect(store.hasChecked)
        #expect(store.executableURL == nil)
    }
}

private nonisolated final class DNGDiscoveryGate: @unchecked Sendable {
    let firstURL = URL(fileURLWithPath: "/converter.app/Contents/MacOS/converter")
    private let cancelSecond: Bool
    init(cancelSecond: Bool = false) { self.cancelSecond = cancelSecond }
    private let lock = NSLock()
    private var calls = 0
    private let releases = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]

    func probe() -> URL? {
        lock.lock()
        let index = calls
        calls += 1
        lock.unlock()
        guard index < releases.count else { return nil }
        #expect(releases[index].wait(timeout: .now() + 10) == .success)
        if index == 1, cancelSecond {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return index == 0 ? firstURL : nil
    }

    private var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func waitForCount(_ target: Int) async throws {
        for _ in 0..<5_000 {
            if count >= target { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CancellationError()
    }

    func release(_ index: Int) { releases[index].signal() }
    func releaseAll() { releases.forEach { $0.signal() } }
}
