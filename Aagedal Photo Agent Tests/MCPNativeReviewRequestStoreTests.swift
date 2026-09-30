import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Durable native review intent handoff")
struct MCPNativeReviewRequestStoreTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let planID = "12b831f7-e976-4e40-bf94-a446428b44d5"

    private func directory() throws -> URL {
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("native-review-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Read-only discovery creates no storage, and unknown IDs fail closed")
    func missingStorage() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        #expect(try store.records().isEmpty)
        #expect(throws: MCPNativeReviewRequestStore.Failure.unknownRequest) { try store.inspect(UUID()) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let defaultRoot = try MCPNativeReviewRequestStore.defaultStorageDirectory()
        #expect(defaultRoot.lastPathComponent == ".aagedal-photo-agent-native-review-requests")
    }

    @Test("Capacity snapshots durably initialize the epoch and clamp record bounds")
    func durableCapacitySnapshot() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root, maximumRecords: 1_000)
        let snapshot = try store.capacitySnapshot()
        #expect(snapshot.retainedCount == 0)
        #expect(snapshot.maximumRecords == 256)
        #expect(snapshot.cancelledBeforeAdmissionCount == 0)
        let file = root.appendingPathComponent("operations.json")
        let bytes = try Data(contentsOf: file)
        #expect(try MCPNativeReviewRequestStore(storageDirectory: root).capacitySnapshot() == snapshot)
        #expect(try store.records().isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) {
            try store.recoverCancelledCapacity(expectedEpoch: snapshot.epoch)
        }
        #expect(try Data(contentsOf: file) == bytes)
        let zero = try directory()
        defer { try? FileManager.default.removeItem(at: zero) }
        let bounded = MCPNativeReviewRequestStore(storageDirectory: zero, maximumRecords: -1)
        let capacity = try bounded.capacitySnapshot()
        #expect(capacity.maximumRecords == 0)
        #expect(throws: MCPNativeReviewRequestStore.Failure.capacity) {
            try bounded.request(requestID: UUID(), requestEpoch: capacity.epoch,
                                planID: planID, purpose: .pendingDraft, now: now)
        }
    }

    @Test("V1 archives remain unchanged on inspection and migrate only under a durable mutation")
    func legacyMigration() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let id = UUID()
        let legacy = try store.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now)
        try replaceArchive(at: root) { archive in
            archive["schemaVersion"] = 1
            archive.removeValue(forKey: "currentEpoch")
            archive.removeValue(forKey: "legacyCreationAllowed")
        }
        let file = root.appendingPathComponent("operations.json")
        let v1 = try Data(contentsOf: file)
        #expect(try store.records() == [legacy])
        #expect(try store.inspect(id) == legacy)
        #expect(try Data(contentsOf: file) == v1)
        #expect(throws: MCPNativeReviewRequestStore.Failure.unknownRequest) { try store.cancel(UUID(), now: now) }
        #expect(try Data(contentsOf: file) == v1)
        // V1 must refuse fields belonging only to V2, even with a valid checksum.
        try replaceArchive(at: root) { archive in
            var records = archive["records"] as! [[String: Any]]
            records[0]["requestEpoch"] = UUID().uuidString.lowercased()
            archive["records"] = records
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidStorage) { try store.capacitySnapshot() }
        try v1.write(to: file)
        let migrated = try store.capacitySnapshot()
        #expect(migrated.retainedCount == 1)
        #expect(try Data(contentsOf: file) != v1)
        #expect(try MCPNativeReviewRequestStore(storageDirectory: root).capacitySnapshot() == migrated)
        #expect(try store.inspect(id) == legacy)
        #expect(try store.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now) == legacy)
        #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
            try store.request(requestID: id, requestEpoch: migrated.epoch,
                              planID: planID, purpose: .pendingDraft, now: now)
        }
    }

    @Test("Epoch requests retry exactly and reject unknown or mismatched epochs without changing storage")
    func epochRequestValidation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let epoch = try store.capacitySnapshot().epoch
        let id = UUID()
        let requested = try store.request(requestID: id, requestEpoch: epoch,
                                          planID: planID, purpose: .pendingDraft, now: now)
        #expect(requested.requestEpoch == epoch)
        let file = root.appendingPathComponent("operations.json")
        let bytes = try Data(contentsOf: file)
        #expect(try store.request(requestID: id, requestEpoch: epoch, planID: planID,
                                  purpose: .pendingDraft, now: now.addingTimeInterval(1)) == requested)
        #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
            try store.request(requestID: UUID(), requestEpoch: UUID(), planID: planID, purpose: .pendingDraft, now: now)
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
            try store.request(requestID: id, requestEpoch: UUID(), planID: planID, purpose: .pendingDraft, now: now)
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
            try store.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now)
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.conflictingRequest) {
            try store.request(requestID: id, requestEpoch: epoch, planID: planID, purpose: .xmpPublication, now: now)
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test("Cancelled-only recovery rotates atomically and preserves all admitted, linked and awaiting evidence")
    func cancelledCapacityRecovery() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root, maximumRecords: 8)
        let competitor = MCPNativeReviewRequestStore(storageDirectory: root, maximumRecords: 8)
        let oldEpoch = try store.capacitySnapshot().epoch
        let retired = UUID()
        let legacyRetired = UUID()
        _ = try store.request(requestID: retired, requestEpoch: oldEpoch, planID: planID, purpose: .pendingDraft, now: now)
        _ = try store.cancel(retired, requestEpoch: oldEpoch, now: now)
        _ = try store.request(requestID: legacyRetired, planID: planID, purpose: .pendingDraft, now: now)
        _ = try store.cancel(legacyRetired, now: now)
        let awaitingID = UUID()
        let awaiting = try store.request(requestID: awaitingID, requestEpoch: oldEpoch,
                                         planID: planID, purpose: .pendingDraft, now: now)
        let legacyID = UUID()
        let legacy = try store.request(requestID: legacyID, planID: planID, purpose: .pendingDraft, now: now)
        let admittedID = UUID()
        _ = try store.request(requestID: admittedID, requestEpoch: oldEpoch, planID: planID, purpose: .pendingDraft, now: now)
        let admitted = try store.admit(admittedID, requestEpoch: oldEpoch, now: now)
        let uncertainID = UUID()
        _ = try store.request(requestID: uncertainID, requestEpoch: oldEpoch, planID: planID, purpose: .pendingDraft, now: now)
        _ = try store.admit(uncertainID, requestEpoch: oldEpoch, now: now)
        let uncertain = try store.cancel(uncertainID, requestEpoch: oldEpoch, now: now)
        let linkedID = UUID()
        _ = try store.request(requestID: linkedID, requestEpoch: oldEpoch, planID: planID, purpose: .pendingDraft, now: now)
        _ = try store.admit(linkedID, requestEpoch: oldEpoch, now: now)
        _ = try store.link(linkedID, operationID: UUID(), now: now)
        let linked = try store.cancel(linkedID, requestEpoch: oldEpoch, now: now)
        let snapshot = try store.capacitySnapshot()
        #expect(snapshot.retainedCount == 7)
        #expect(snapshot.cancelledBeforeAdmissionCount == 2)
        let recovered = try competitor.recoverCancelledCapacity(expectedEpoch: oldEpoch)
        #expect(recovered.epoch != oldEpoch)
        #expect(recovered.retiredCount == 2)
        #expect(try store.records() == [awaiting, legacy, admitted, uncertain, linked])
        #expect(try store.capacitySnapshot().epoch == recovered.epoch)
        #expect(try store.capacitySnapshot().cancelledBeforeAdmissionCount == 0)
        #expect(throws: MCPNativeReviewRequestStore.Failure.unknownRequest) { try store.inspect(retired) }
        #expect(throws: MCPNativeReviewRequestStore.Failure.unknownRequest) { try store.inspect(legacyRetired) }
        let file = root.appendingPathComponent("operations.json")
        let bytes = try Data(contentsOf: file)
        for id in [retired, UUID()] {
            #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
                try store.request(requestID: id, requestEpoch: oldEpoch, planID: planID, purpose: .pendingDraft, now: now)
            }
        }
        for id in [legacyRetired, UUID()] {
            #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
                try store.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now)
            }
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
            try store.recoverCancelledCapacity(expectedEpoch: snapshot.epoch)
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) {
            try store.recoverCancelledCapacity(expectedEpoch: recovered.epoch)
        }
        #expect(try store.request(requestID: awaitingID, requestEpoch: oldEpoch, planID: planID, purpose: .pendingDraft, now: now) == awaiting)
        #expect(try store.request(requestID: admittedID, requestEpoch: oldEpoch, planID: planID, purpose: .pendingDraft, now: now) == admitted)
        #expect(try store.request(requestID: uncertainID, requestEpoch: oldEpoch, planID: planID, purpose: .pendingDraft, now: now) == uncertain)
        #expect(try store.request(requestID: linkedID, requestEpoch: oldEpoch, planID: planID, purpose: .pendingDraft, now: now) == linked)
        #expect(try store.request(requestID: legacyID, planID: planID, purpose: .pendingDraft, now: now) == legacy)
        #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
            try store.request(requestID: awaitingID, requestEpoch: recovered.epoch, planID: planID, purpose: .pendingDraft, now: now)
        }
        #expect(try Data(contentsOf: file) == bytes)
        // A retained historical request can still be cancelled and retired in a later epoch.
        let cancelled = try store.cancel(awaitingID, requestEpoch: oldEpoch, now: now.addingTimeInterval(1))
        #expect(cancelled.requestEpoch == oldEpoch)
        #expect(try store.request(requestID: awaitingID, requestEpoch: oldEpoch,
                                  planID: planID, purpose: .pendingDraft, now: now) == cancelled)
        let next = try store.recoverCancelledCapacity(expectedEpoch: recovered.epoch)
        #expect(next.retiredCount == 1)
        let restarted = MCPNativeReviewRequestStore(storageDirectory: root, maximumRecords: 8)
        _ = try restarted.request(requestID: UUID(), requestEpoch: next.epoch,
                                   planID: planID, purpose: .pendingDraft, now: now)
        #expect(try restarted.inspect(linkedID) == linked)
        #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
            try restarted.request(requestID: legacyRetired, planID: planID, purpose: .pendingDraft, now: now)
        }
    }

    @Test("A retired UUID reused in a new epoch rejects stale and epochless admission or cancellation")
    func reusedRequestIDCannotAcceptStaleMutations() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let oldEpoch = try store.capacitySnapshot().epoch
        let id = UUID()
        _ = try store.request(requestID: id, requestEpoch: oldEpoch, planID: planID, purpose: .pendingDraft, now: now)
        _ = try store.cancel(id, requestEpoch: oldEpoch, now: now)
        let newEpoch = try store.recoverCancelledCapacity(expectedEpoch: oldEpoch).epoch
        let current = try store.request(requestID: id, requestEpoch: newEpoch, planID: planID,
                                       purpose: .pendingDraft, now: now.addingTimeInterval(1))
        let file = root.appendingPathComponent("operations.json")
        let bytes = try Data(contentsOf: file)
        for epoch in [oldEpoch, nil] as [UUID?] {
            #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
                try store.cancel(id, requestEpoch: epoch, now: now.addingTimeInterval(2))
            }
            #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
                try store.admit(id, requestEpoch: epoch, now: now.addingTimeInterval(2))
            }
        }
        #expect(try store.inspect(id) == current)
        #expect(try Data(contentsOf: file) == bytes)
        let admitted = try store.admit(id, requestEpoch: newEpoch, now: now.addingTimeInterval(2))
        #expect(admitted.state == .admitted)
        let admittedBytes = try Data(contentsOf: file)
        for epoch in [oldEpoch, nil] as [UUID?] {
            #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
                try store.markUnknownDisposition(id, requestEpoch: epoch, now: now.addingTimeInterval(3))
            }
        }
        #expect(try store.inspect(id) == admitted)
        #expect(try Data(contentsOf: file) == admittedBytes)
        let uncertain = try store.markUnknownDisposition(id, requestEpoch: newEpoch, now: now.addingTimeInterval(3))
        #expect(uncertain.state == .unknownDisposition)
        #expect(uncertain.admittedAt == admitted.admittedAt)
        let cancelled = try store.cancel(id, requestEpoch: newEpoch, now: now.addingTimeInterval(4))
        #expect(cancelled.state == .unknownDisposition)
        #expect(cancelled.cancellationRequestedAt == now.addingTimeInterval(4))
    }

    @Test("Recovery releases full capacity while byte failures and lock contention cannot rotate epochs")
    func recoveryBoundsAndContention() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root, maximumRecords: 1)
        let competitor = MCPNativeReviewRequestStore(storageDirectory: root, maximumRecords: 1)
        let epoch = try store.capacitySnapshot().epoch
        let id = UUID()
        _ = try store.request(requestID: id, requestEpoch: epoch, planID: planID, purpose: .pendingDraft, now: now)
        _ = try store.cancel(id, requestEpoch: epoch, now: now)
        #expect(throws: MCPNativeReviewRequestStore.Failure.capacity) {
            try competitor.request(requestID: UUID(), requestEpoch: epoch, planID: planID, purpose: .pendingDraft, now: now)
        }
        let holder = AutomationOperationPersistence(directory: root, maximumBytes: 1_048_576)
        try holder.transaction { bytes in
            #expect(throws: MCPNativeReviewRequestStore.Failure.storageUnavailable) { try competitor.capacitySnapshot() }
            #expect(throws: MCPNativeReviewRequestStore.Failure.storageUnavailable) {
                try competitor.recoverCancelledCapacity(expectedEpoch: epoch)
            }
            #expect(throws: MCPNativeReviewRequestStore.Failure.storageUnavailable) {
                try competitor.request(requestID: UUID(), requestEpoch: epoch, planID: planID, purpose: .pendingDraft, now: now)
            }
            return ((), try #require(bytes))
        }
        #expect(try competitor.capacitySnapshot().epoch == epoch)
        let recovery = try competitor.recoverCancelledCapacity(expectedEpoch: epoch)
        _ = try store.request(requestID: UUID(), requestEpoch: recovery.epoch, planID: planID, purpose: .pendingDraft, now: now)
        #expect(try store.capacitySnapshot().retainedCount == 1)
        let tinyRoot = try directory()
        defer { try? FileManager.default.removeItem(at: tinyRoot) }
        let tiny = MCPNativeReviewRequestStore(storageDirectory: tinyRoot, maximumBytes: 128)
        #expect(throws: MCPNativeReviewRequestStore.Failure.capacity) { try tiny.capacitySnapshot() }
        #expect(!FileManager.default.fileExists(atPath: tinyRoot.appendingPathComponent("operations.json").path))
        #expect(try tiny.records().isEmpty)
    }

    @Test("Exact retries survive restart and never revive cancelled intent")
    func durableIdempotency() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MCPNativeReviewRequestStore(storageDirectory: root)
        let second = MCPNativeReviewRequestStore(storageDirectory: root)
        let id = UUID()
        let requested = try first.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now)
        #expect(requested.state == .awaitingReview)
        #expect(requested.operationID == nil)
        #expect(requested.admittedAt == nil)
        #expect(try second.request(requestID: id, planID: planID, purpose: .pendingDraft,
                                   now: now.addingTimeInterval(10)) == requested)
        #expect(throws: MCPNativeReviewRequestStore.Failure.conflictingRequest) {
            try second.request(requestID: id, planID: UUID().uuidString.lowercased(), purpose: .pendingDraft, now: now)
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.conflictingRequest) {
            try second.request(requestID: id, planID: planID, purpose: .xmpPublication, now: now)
        }
        let cancelled = try second.cancel(id, now: now.addingTimeInterval(1))
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.cancellationRequestedAt == now.addingTimeInterval(1))
        #expect(try first.request(requestID: id, planID: planID, purpose: .pendingDraft,
                                  now: now.addingTimeInterval(20)) == cancelled)
        #expect(try first.cancel(id, now: now.addingTimeInterval(20)) == cancelled)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) { try first.admit(id, now: now.addingTimeInterval(2)) }
        let restarted = MCPNativeReviewRequestStore(storageDirectory: root)
        #expect(try restarted.records() == [cancelled])
    }

    @Test("Admission is one-way; cancellation before operation linking remains uncertain")
    func admittedCancellation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = MCPNativeReviewRequestStore(storageDirectory: root)
        let helper = MCPNativeReviewRequestStore(storageDirectory: root)
        let id = UUID()
        _ = try helper.request(requestID: id, planID: planID, purpose: .xmpPublication, now: now)
        let admitted = try native.admit(id, now: now.addingTimeInterval(1))
        #expect(admitted.state == .admitted)
        #expect(admitted.admittedAt == now.addingTimeInterval(1))
        // A helper reconnecting must not invalidate a live native admission.
        #expect(try MCPNativeReviewRequestStore(storageDirectory: root).inspect(id) == admitted)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) { try helper.admit(id, now: now.addingTimeInterval(2)) }
        let uncertain = try helper.cancel(id, now: now.addingTimeInterval(2))
        #expect(uncertain.state == .unknownDisposition)
        #expect(uncertain.admittedAt == admitted.admittedAt)
        #expect(uncertain.cancellationRequestedAt != nil)
        #expect(uncertain.operationID == nil)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) {
            try native.link(id, operationID: UUID(), now: now.addingTimeInterval(3))
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) { try native.admit(id, now: now.addingTimeInterval(3)) }
        #expect(try native.inspect(id) == uncertain)
    }

    @Test("Each operation links once and cancellation retains its durable identity")
    func exactOperationLink() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let id = UUID()
        let other = UUID()
        let operation = UUID()
        _ = try store.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) { try store.link(id, operationID: operation, now: now) }
        _ = try store.admit(id, now: now)
        let linked = try store.link(id, operationID: operation, now: now.addingTimeInterval(1))
        #expect(linked.state == .linked)
        #expect(linked.operationID == operation)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) {
            try store.link(id, operationID: operation, now: now.addingTimeInterval(2))
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) {
            try store.link(id, operationID: UUID(), now: now.addingTimeInterval(2))
        }
        _ = try store.request(requestID: other, planID: planID, purpose: .pendingDraft, now: now)
        _ = try store.admit(other, now: now)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) {
            try store.link(other, operationID: operation, now: now.addingTimeInterval(2))
        }
        let cancelled = try store.cancel(id, now: now.addingTimeInterval(2))
        #expect(cancelled.state == .linked)
        #expect(cancelled.operationID == operation)
        #expect(cancelled.cancellationRequestedAt == now.addingTimeInterval(2))
        #expect(try MCPNativeReviewRequestStore(storageDirectory: root).inspect(id) == cancelled)
    }

    @Test("Native startup reconciles lost links without replay or invented cancellation")
    func restartAdmissionRecovery() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let missing = UUID()
        let waiting = UUID()
        let linkedID = UUID()
        _ = try store.request(requestID: missing, planID: planID, purpose: .pendingDraft, now: now)
        let admitted = try store.admit(missing, now: now.addingTimeInterval(1))
        let awaiting = try store.request(requestID: waiting, planID: planID, purpose: .pendingDraft, now: now)
        _ = try store.request(requestID: linkedID, planID: planID, purpose: .xmpPublication, now: now)
        _ = try store.admit(linkedID, now: now)
        let linked = try store.link(linkedID, operationID: UUID(), now: now)
        let restarted = MCPNativeReviewRequestStore(storageDirectory: root)
        let changed = try restarted.reconcileUnlinkedAdmissions(now: now.addingTimeInterval(2))
        #expect(changed.count == 1)
        let recovered = try #require(changed.first)
        #expect(recovered.requestID == missing)
        #expect(recovered.state == .unknownDisposition)
        #expect(recovered.admittedAt == admitted.admittedAt)
        #expect(recovered.operationID == nil)
        #expect(recovered.cancellationRequestedAt == nil)
        #expect(try restarted.inspect(waiting) == awaiting)
        #expect(try restarted.inspect(linkedID) == linked)
        let bytes = try Data(contentsOf: root.appendingPathComponent("operations.json"))
        #expect(try restarted.reconcileUnlinkedAdmissions(now: now.addingTimeInterval(3)).isEmpty)
        #expect(try Data(contentsOf: root.appendingPathComponent("operations.json")) == bytes)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) {
            try restarted.admit(missing, now: now.addingTimeInterval(3))
        }
        #expect(try restarted.request(requestID: missing, planID: planID, purpose: .pendingDraft,
                                      now: now.addingTimeInterval(3)) == recovered)
    }

    @Test("Submission failures preserve uncertain admissions and existing operation links")
    func submissionFailure() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let id = UUID()
        _ = try store.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) { try store.markUnknownDisposition(id, now: now) }
        _ = try store.admit(id, now: now)
        let uncertain = try store.markUnknownDisposition(id, now: now.addingTimeInterval(1))
        #expect(uncertain.state == .unknownDisposition)
        #expect(try store.markUnknownDisposition(id, now: now.addingTimeInterval(2)) == uncertain)
        let linkedID = UUID()
        _ = try store.request(requestID: linkedID, planID: planID, purpose: .pendingDraft, now: now)
        _ = try store.admit(linkedID, now: now)
        let linked = try store.link(linkedID, operationID: UUID(), now: now)
        #expect(try store.markUnknownDisposition(linkedID, now: now.addingTimeInterval(2)) == linked)
    }

    @Test("Record and byte bounds retain idempotency evidence and refuse new intent")
    func boundedStorage() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MCPNativeReviewRequestStore(storageDirectory: root, maximumRecords: 1)
        let other = MCPNativeReviewRequestStore(storageDirectory: root, maximumRecords: 1)
        let id = UUID()
        _ = try first.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now)
        let cancelled = try first.cancel(id, now: now)
        #expect(throws: MCPNativeReviewRequestStore.Failure.capacity) {
            try other.request(requestID: UUID(), planID: planID, purpose: .pendingDraft, now: now)
        }
        #expect(try other.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now) == cancelled)
        #expect(try first.records() == [cancelled])
        let tinyRoot = try directory()
        defer { try? FileManager.default.removeItem(at: tinyRoot) }
        let tiny = MCPNativeReviewRequestStore(storageDirectory: tinyRoot, maximumBytes: 128)
        #expect(throws: MCPNativeReviewRequestStore.Failure.capacity) {
            try tiny.request(requestID: UUID(), planID: planID, purpose: .pendingDraft, now: now)
        }
        #expect(try tiny.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tinyRoot.appendingPathComponent("operations.json").path))
    }

    @Test("A competing persistence transaction cannot bypass request cancellation or admission")
    func crossStoreContention() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let competitor = MCPNativeReviewRequestStore(storageDirectory: root)
        let id = UUID()
        let requested = try store.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now)
        let holder = AutomationOperationPersistence(directory: root, maximumBytes: 1_048_576)
        try holder.transaction { bytes in
            #expect(throws: MCPNativeReviewRequestStore.Failure.storageUnavailable) { try competitor.admit(id, now: now) }
            #expect(throws: MCPNativeReviewRequestStore.Failure.storageUnavailable) { try competitor.cancel(id, now: now) }
            return ((), try #require(bytes))
        }
        #expect(try competitor.inspect(id) == requested)
        let cancelled = try competitor.cancel(id, now: now)
        #expect(try store.inspect(id) == cancelled)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) { try store.admit(id, now: now) }
    }

    @Test("Clock rollback and noncanonical plan IDs never change admission evidence")
    func invalidArguments() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        for invalid in [planID.uppercased(), "\(planID) ", "../plan", ""] {
            #expect(throws: MCPNativeReviewRequestStore.Failure.invalidArguments) {
                try store.request(requestID: UUID(), planID: invalid, purpose: .pendingDraft, now: now)
            }
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidArguments) {
            try store.request(requestID: UUID(), planID: planID, purpose: .pendingDraft,
                              now: Date(timeIntervalSinceReferenceDate: .infinity))
        }
        let id = UUID()
        _ = try store.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now)
        let admitted = try store.admit(id, now: now.addingTimeInterval(2))
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidArguments) { try store.cancel(id, now: now) }
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidArguments) { try store.reconcileUnlinkedAdmissions(now: now) }
        #expect(try store.inspect(id) == admitted)
    }

    private func replaceArchive(at root: URL, mutation: (inout [String: Any]) -> Void) throws {
        let file = root.appendingPathComponent("operations.json")
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let encoded = try #require(envelope["payload"] as? String)
        let payload = try #require(Data(base64Encoded: encoded))
        var archive = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        mutation(&archive)
        let updated = try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys])
        envelope["payload"] = updated.base64EncodedString()
        envelope["sha256"] = SHA256.hash(data: updated).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: file)
    }

    @Test("Checksummed but invalid archives refuse inspection and all subsequent mutations")
    func strictArchiveValidation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let id = try #require(UUID(uuidString: "fa0b9a20-4382-46a8-a6bc-0a4f5c3f37c9"))
        _ = try store.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now)
        let file = root.appendingPathComponent("operations.json")
        let baseline = try Data(contentsOf: file)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["schemaVersion"] = 3 },
            { $0["currentEpoch"] = UUID().uuidString.uppercased() },
            { $0["currentEpoch"] = "invalid" },
            { $0.removeValue(forKey: "currentEpoch") },
            { $0["currentEpoch"] = NSNull() },
            { $0["legacyCreationAllowed"] = 1 },
            { $0.removeValue(forKey: "legacyCreationAllowed") },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["requestEpoch"] = UUID().uuidString.uppercased(); archive["records"] = records
            },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["requestEpoch"] = NSNull(); archive["records"] = records
            },
            { $0["authority"] = true },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records.append(records[0]); archive["records"] = records
            },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["consent"] = true; archive["records"] = records
            },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["planID"] = "noncanonical"; archive["records"] = records
            },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["requestID"] = id.uuidString.uppercased(); archive["records"] = records
            },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["state"] = "linked"; archive["records"] = records
            },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["state"] = "admitted"; archive["records"] = records
            },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["state"] = "cancelled"; archive["records"] = records
            },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["state"] = "unknownDisposition"; archive["records"] = records
            },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["admittedAt"] = records[0]["createdAt"]; archive["records"] = records
            },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["cancellationRequestedAt"] = records[0]["createdAt"]; archive["records"] = records
            },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["operationID"] = NSNull(); archive["records"] = records
            },
            { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["updatedAt"] = -1; archive["records"] = records
            }
        ]
        for mutation in mutations {
            try baseline.write(to: file)
            try replaceArchive(at: root, mutation: mutation)
            let invalid = try Data(contentsOf: file)
            #expect(throws: MCPNativeReviewRequestStore.Failure.invalidStorage) { try store.records() }
            #expect(throws: MCPNativeReviewRequestStore.Failure.invalidStorage) { try store.cancel(id, now: now) }
            #expect(throws: MCPNativeReviewRequestStore.Failure.invalidStorage) { try store.capacitySnapshot() }
            #expect(throws: MCPNativeReviewRequestStore.Failure.invalidStorage) {
                try store.recoverCancelledCapacity(expectedEpoch: UUID())
            }
            #expect(try Data(contentsOf: file) == invalid)
        }
    }

    @Test("Checksum damage, malformed bytes and excessive archive size fail closed")
    func corruptStorage() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let id = UUID()
        _ = try store.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now)
        let file = root.appendingPathComponent("operations.json")
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        envelope["sha256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidStorage) { try store.admit(id, now: now) }
        try Data("broken".utf8).write(to: file)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidStorage) { try store.records() }
        try Data(repeating: 0x20, count: 1_048_577).write(to: file)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidStorage) { try store.records() }
    }

    @Test("Durable files are private and an insecure or substituted snapshot refuses access")
    func privateStorage() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        _ = try store.request(requestID: UUID(), planID: planID, purpose: .pendingDraft, now: now)
        let file = root.appendingPathComponent("operations.json")
        for item in [root, file, root.appendingPathComponent("operations.lock")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            let mode = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(mode.intValue & 0o077 == 0)
        }
        #expect(chmod(file.path, 0o644) == 0)
        #expect(throws: MCPNativeReviewRequestStore.Failure.storageUnavailable) { try store.records() }
        #expect(chmod(file.path, 0o600) == 0)
        let moved = root.appendingPathComponent("private-copy.json")
        try FileManager.default.moveItem(at: file, to: moved)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
        #expect(throws: MCPNativeReviewRequestStore.Failure.storageUnavailable) { try store.records() }
    }
}
