import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Retained automation execution lifecycle")
struct AutomationOperationExecutionCoordinatorTests {
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
    private enum InjectedFailure: Error { case write }
    private func directory() throws -> URL {
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("operation-execution-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Admission is bounded while submitted work outlives its caller")
    func retainedAdmission() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let runner = AutomationOperationExecutionCoordinator(registry: registry, maximumConcurrentOperations: 1)
        let entered = Gate(), release = Gate()
        let submitter = Task {
            try await runner.submit(kind: .iptcDraft) { _ in
                await entered.open()
                await release.wait()
                return .verified
            }
        }
        let record = try await submitter.value
        submitter.cancel()
        await entered.wait()
        #expect(try registry.inspect(record.id).state == .running)
        do {
            _ = try await runner.submit(kind: .iptcDraft) { _ in .verified }
            Issue.record("A full coordinator accepted more work")
        } catch {
            #expect(error as? AutomationOperationExecutionCoordinator.Failure == .capacity)
        }
        #expect(try registry.records().count == 1)
        await release.open()
        let completed = try await runner.waitForCompletion(record.id)
        #expect(completed.outcome == .verified)
        #expect(completed.kind == .iptcDraft)
        let next = try await runner.submit(kind: .iptcDraft) { _ in .stale }
        #expect(try await runner.waitForCompletion(next.id).outcome == .stale)
    }

    @Test("Independent helper cancellation is observed at a safe boundary", arguments: [false, true])
    func helperCancellation(afterEffects: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let helper = AutomationOperationRegistry(storageDirectory: root)
        let runner = AutomationOperationExecutionCoordinator(registry: registry)
        let entered = Gate(), release = Gate()
        let record = try await runner.submit(kind: .iptcDraft) { context in
            if afterEffects { try await context.markEffectsMayHaveOccurred() }
            await entered.open()
            await release.wait()
            try await context.checkCancellation()
            Issue.record("Cancelled work passed its safe boundary")
            return .verified
        }
        await entered.wait()
        _ = try helper.requestCancellation(record.id)
        #expect(try helper.inspect(record.id).state == .running)
        await release.open()
        let terminal = try await runner.waitForCompletion(record.id)
        #expect(terminal.state == .cancelled)
        #expect(terminal.outcome == (afterEffects ? .recoveryRequired : .cancelled))
    }

    @Test("Unexpected errors distinguish definite failure from possible effects", arguments: [false, true])
    func unexpectedFailure(afterEffects: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let runner = AutomationOperationExecutionCoordinator(registry: registry)
        let record = try await runner.submit(kind: .iptcDraft) { context in
            if afterEffects { try await context.markEffectsMayHaveOccurred() }
            throw InjectedFailure.write
        }
        let terminal = try await runner.waitForCompletion(record.id)
        #expect(terminal.state == .completed)
        #expect(terminal.outcome == (afterEffects ? .recoveryRequired : .failed))
    }

    @Test("Verified completion wins a cancellation race after publication")
    func verifiedCancellationRace() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let runner = AutomationOperationExecutionCoordinator(registry: registry)
        let entered = Gate(), release = Gate()
        let record = try await runner.submit(kind: .iptcDraft) { context in
            try await context.markEffectsMayHaveOccurred()
            await entered.open()
            await release.wait()
            return .verified
        }
        await entered.wait()
        _ = try registry.requestCancellation(record.id)
        await release.open()
        let terminal = try await runner.waitForCompletion(record.id)
        #expect(terminal.state == .completed)
        #expect(terminal.outcome == .verified)
        #expect(terminal.cancellationRequestedAt != nil)
    }

    @Test("Explicit executor evidence remains distinct", arguments:
        [AutomationOperationRegistry.Outcome.failed, .stale, .partialUncertain, .recoveryRequired])
    func explicitOutcomes(outcome: AutomationOperationRegistry.Outcome) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let runner = AutomationOperationExecutionCoordinator(registry: registry)
        let record = try await runner.submit(kind: .iptcDraft) { _ in outcome }
        #expect(try await runner.waitForCompletion(record.id).outcome == outcome)
    }

    @Test("Graceful shutdown waits for writes and recovers only stopped unresolved ownership")
    func shutdown() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        let runner = AutomationOperationExecutionCoordinator(registry: registry, ownerID: owner)
        let other = try registry.enqueue(kind: .iptcDraft, ownerID: UUID())
        let unresolved = try registry.enqueue(kind: .iptcDraft, ownerID: owner)
        let entered = Gate(), release = Gate()
        let record = try await runner.submit(kind: .iptcDraft) { context in
            try await context.markEffectsMayHaveOccurred()
            await entered.open()
            await release.wait()
            return .partialUncertain
        }
        await entered.wait()
        let stopping = Task { try await runner.shutdown() }
        // Waiting on the retained task also exercises concurrent completion waiters.
        let waiting = Task { try await runner.waitForCompletion(record.id) }
        await release.open()
        let changed = try await stopping.value
        #expect(changed.map(\.id) == [unresolved.id])
        #expect(changed.first?.outcome == .recoveryRequired)
        #expect(try await waiting.value.outcome == .partialUncertain)
        #expect(try registry.inspect(other.id).state == .queued)
        do {
            _ = try await runner.submit(kind: .iptcDraft) { _ in .verified }
            Issue.record("Stopped coordinator accepted work")
        } catch {
            #expect(error as? AutomationOperationExecutionCoordinator.Failure == .stopped)
        }
        #expect(try await runner.shutdown().isEmpty)
    }
    @Test("Relaunch recovery requires a released managed-owner lock and preserves cancellation")
    func abandonedOwnerRecovery() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let helper = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        var lease: AutomationOperationPersistence.OwnerLease? = try registry.acquireOwnerLease(ownerID: owner)
        let managed = try registry.enqueue(kind: .iptcDraft, ownerID: owner, ownerLease: lease)
        _ = try registry.start(managed.id, ownerID: owner)
        let requested = try registry.requestCancellation(managed.id)
        let legacy = try registry.enqueue(kind: .iptcDraft, ownerID: owner)
        #expect(try helper.reconcileAbandonedOwners().isEmpty)
        withExtendedLifetime(lease) {}
        lease = nil
        let recovered = try helper.reconcileAbandonedOwners()
        #expect(recovered.map(\.id) == [managed.id])
        #expect(recovered.first?.outcome == .recoveryRequired)
        #expect(recovered.first?.cancellationRequestedAt == requested.cancellationRequestedAt)
        #expect(try helper.inspect(legacy.id).state == .queued)
        #expect(try helper.reconcileAbandonedOwners().isEmpty)
        #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
            _ = try registry.acquireOwnerLease(ownerID: owner)
        }
    }

    @Test("A live coordinator cannot be recovered by another registry")
    func liveOwnerRecoveryRefused() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let runner = AutomationOperationExecutionCoordinator(registry: registry)
        let entered = Gate(), release = Gate()
        let record = try await runner.submit(kind: .iptcDraft) { _ in
            await entered.open()
            await release.wait()
            return .verified
        }
        await entered.wait()
        #expect(try registry.inspect(record.id).ownerLeaseManaged == true)
        #expect(try registry.reconcileAbandonedOwners().isEmpty)
        await release.open()
        #expect(try await runner.waitForCompletion(record.id).outcome == .verified)
    }

    @Test("Owner leases cannot enroll another owner or another archive")
    func mismatchedLeaseRefused() throws {
        let root = try directory(), otherRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
        }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let other = AutomationOperationRegistry(storageDirectory: otherRoot)
        let owner = UUID()
        let lease = try registry.acquireOwnerLease(ownerID: owner)
        #expect(throws: AutomationOperationRegistry.Failure.wrongOwner) {
            _ = try registry.enqueue(kind: .iptcDraft, ownerID: UUID(), ownerLease: lease)
        }
        #expect(throws: AutomationOperationRegistry.Failure.wrongOwner) {
            _ = try other.enqueue(kind: .iptcDraft, ownerID: owner, ownerLease: lease)
        }
    }

    @Test("Missing owner evidence is unresolved and symlink evidence is refused")
    func invalidOwnerEvidence() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        var lease: AutomationOperationPersistence.OwnerLease? = try registry.acquireOwnerLease(ownerID: owner)
        let record = try registry.enqueue(kind: .iptcDraft, ownerID: owner, ownerLease: lease)
        withExtendedLifetime(lease) {}
        lease = nil
        let lock = root.appendingPathComponent("owner-\(owner.uuidString).lock")
        try FileManager.default.removeItem(at: lock)
        #expect(try registry.reconcileAbandonedOwners().isEmpty)
        #expect(try registry.inspect(record.id).state == .queued)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: root.appendingPathComponent("operations.lock"))
        #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
            _ = try registry.reconcileAbandonedOwners()
        }
        #expect(try registry.inspect(record.id).state == .queued)
    }

    @Test("Clock rollback refuses an abandoned-owner batch without changing any record")
    func abandonedOwnerClockRollback() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID(), now = Date()
        var lease: AutomationOperationPersistence.OwnerLease? = try registry.acquireOwnerLease(ownerID: owner)
        let first = try registry.enqueue(kind: .iptcDraft, ownerID: owner, now: now, ownerLease: lease)
        let later = try registry.enqueue(kind: .iptcDraft, ownerID: owner, now: now.addingTimeInterval(10), ownerLease: lease)
        withExtendedLifetime(lease) {}
        lease = nil
        #expect(throws: AutomationOperationRegistry.Failure.invalidArguments) {
            _ = try registry.reconcileAbandonedOwners(now: now)
        }
        #expect(try registry.records() == [first, later])
    }

}
