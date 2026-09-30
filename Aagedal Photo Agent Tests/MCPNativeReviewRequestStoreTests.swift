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

    @Test("Confirmed terminal recovery retains operation bytes and all other request evidence while rotating replay protection")
    func confirmedTerminalRecovery() throws {
        let root = try directory()
        let operationRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: operationRoot)
        }
        let store = MCPNativeReviewRequestStore(storageDirectory: root, maximumRecords: 7)
        let registry = AutomationOperationRegistry(storageDirectory: operationRoot)
        let epoch = try store.capacitySnapshot().epoch
        var retired: [UUID] = []
        for outcome in [AutomationOperationRegistry.Outcome.verified, .failed, .cancelled, .stale] {
            let id = UUID()
            let legacy = outcome == .stale
            let purpose: MCPNativeReviewRequestStore.Purpose = outcome == .failed ? .xmpPublication : .pendingDraft
            _ = try terminalFixture(store: store, registry: registry, id: id, epoch: legacy ? nil : epoch,
                                    purpose: purpose, outcome: outcome)
            retired.append(id)
        }
        let awaiting = try store.request(requestID: UUID(), requestEpoch: epoch, planID: planID,
                                         purpose: .pendingDraft, now: now)
        let cancelledID = UUID()
        _ = try store.request(requestID: cancelledID, requestEpoch: epoch, planID: planID,
                              purpose: .pendingDraft, now: now)
        let cancelled = try store.cancel(cancelledID, requestEpoch: epoch, now: now)
        let uncertainID = UUID()
        _ = try terminalFixture(store: store, registry: registry, id: uncertainID, epoch: epoch,
                                purpose: .xmpPublication, outcome: .recoveryRequired)
        let uncertain = try store.inspect(uncertainID)
        let operationFile = operationRoot.appendingPathComponent("operations.json")
        let operationBytes = try Data(contentsOf: operationFile)
        let operationRecords = try registry.records()
        let snapshot = try store.terminalCapacitySnapshot(registry: registry)
        #expect(snapshot.retainedCount == 7)
        #expect(snapshot.confirmedTerminalCount == 4)
        #expect(snapshot.cancelledBeforeAdmissionCount == 1)
        #expect(try store.capacitySnapshot().confirmedTerminalCount == nil)
        #expect(throws: MCPNativeReviewRequestStore.Failure.capacity) {
            try store.request(requestID: UUID(), requestEpoch: epoch, planID: planID, purpose: .pendingDraft, now: now)
        }
        let result = try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry)
        #expect(result.retiredCount == 4)
        #expect(result.epoch != epoch)
        #expect(try store.records() == [awaiting, cancelled, uncertain])
        #expect(try Data(contentsOf: operationFile) == operationBytes)
        #expect(try registry.records() == operationRecords)
        let requestFile = root.appendingPathComponent("operations.json")
        let requestBytes = try Data(contentsOf: requestFile)
        for id in retired {
            #expect(throws: MCPNativeReviewRequestStore.Failure.unknownRequest) { try store.inspect(id) }
            #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
                try store.request(requestID: id, requestEpoch: epoch, planID: planID, purpose: .pendingDraft, now: now)
            }
            #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
                try store.request(requestID: id, planID: planID, purpose: .pendingDraft, now: now)
            }
        }
        #expect(try store.request(requestID: awaiting.requestID, requestEpoch: epoch, planID: planID,
                                  purpose: .pendingDraft, now: now) == awaiting)
        #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
            try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry)
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) {
            try store.recoverConfirmedTerminalCapacity(expectedEpoch: result.epoch, registry: registry)
        }
        #expect(try Data(contentsOf: requestFile) == requestBytes)
        #expect(try MCPNativeReviewRequestStore(storageDirectory: root).terminalCapacitySnapshot(registry: registry).epoch == result.epoch)
        _ = try store.request(requestID: retired[0], requestEpoch: result.epoch, planID: planID,
                              purpose: .pendingDraft, now: now.addingTimeInterval(10))
        for stale in [epoch, nil] as [UUID?] {
            #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
                try store.admit(retired[0], requestEpoch: stale, now: now.addingTimeInterval(11))
            }
        }
    }

    @Test("Missing, wrong-kind, old, live and uncertain operation histories cannot retire linked requests")
    func terminalEvidenceRefusals() throws {
        let root = try directory()
        let operationRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: operationRoot)
        }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let registry = AutomationOperationRegistry(storageDirectory: operationRoot)
        let epoch = try store.capacitySnapshot().epoch
        for purpose in [MCPNativeReviewRequestStore.Purpose.pendingDraft, .xmpPublication] {
            _ = try terminalFixture(store: store, registry: registry, id: UUID(), epoch: epoch,
                                    purpose: purpose, outcome: .failed,
                                    kind: purpose == .pendingDraft ? .iptcPatch : .iptcDraft)
        }
        for kind in [AutomationOperationRegistry.Kind.faceScan, .metadataTemplate, .developTemplate, .voiceTranscription] {
            _ = try terminalFixture(store: store, registry: registry, id: UUID(), epoch: epoch,
                                    purpose: .pendingDraft, outcome: .failed, kind: kind)
        }
        for outcome in [AutomationOperationRegistry.Outcome.partialUncertain, .recoveryRequired] {
            _ = try terminalFixture(store: store, registry: registry, id: UUID(), epoch: epoch,
                                    purpose: .xmpPublication, outcome: outcome)
        }
        #expect(try store.terminalCapacitySnapshot(registry: registry).confirmedTerminalCount == 0)
        // A registry marker without the exact retained recovery journal is insufficient.
        try replaceArchive(at: operationRoot) { archive in
            var records = archive["records"] as! [[String: Any]]
            for index in records.indices where ["partialUncertain", "recoveryRequired"].contains(records[index]["outcome"] as? String ?? "") {
                records[index]["recoveryResolution"] = ["disposition": "restored",
                    "receiptSHA256": String(repeating: "a", count: 64), "resolvedAt": records[index]["updatedAt"]!]
            }
            archive["records"] = records
        }
        let early = try registry.enqueue(kind: .iptcDraft, ownerID: UUID(), now: now.addingTimeInterval(-1))
        let earlyID = UUID()
        _ = try store.request(requestID: earlyID, requestEpoch: epoch, planID: planID, purpose: .pendingDraft, now: now)
        _ = try store.admit(earlyID, requestEpoch: epoch, now: now)
        _ = try store.link(earlyID, operationID: early.id, now: now)
        _ = try registry.finish(early.id, ownerID: early.ownerID, outcome: .failed, now: now.addingTimeInterval(3))
        for state in [AutomationOperationRegistry.State.queued, .running] {
            let id = UUID()
            _ = try store.request(requestID: id, requestEpoch: epoch, planID: planID, purpose: .pendingDraft, now: now)
            _ = try store.admit(id, requestEpoch: epoch, now: now)
            let operation = try registry.enqueue(kind: .iptcDraft, ownerID: UUID(), now: now)
            _ = try store.link(id, operationID: operation.id, now: now)
            if state == .running { _ = try registry.start(operation.id, ownerID: operation.ownerID, now: now) }
        }
        let missingID = UUID()
        _ = try store.request(requestID: missingID, requestEpoch: epoch, planID: planID, purpose: .pendingDraft, now: now)
        _ = try store.admit(missingID, requestEpoch: epoch, now: now)
        _ = try store.link(missingID, operationID: UUID(), now: now)
        let admittedID = UUID()
        _ = try store.request(requestID: admittedID, requestEpoch: epoch, planID: planID, purpose: .pendingDraft, now: now)
        _ = try store.admit(admittedID, requestEpoch: epoch, now: now)
        let operationFile = operationRoot.appendingPathComponent("operations.json")
        let operationBytes = try Data(contentsOf: operationFile)
        let requestFile = root.appendingPathComponent("operations.json")
        let requestBytes = try Data(contentsOf: requestFile)
        #expect(try store.terminalCapacitySnapshot(registry: registry).confirmedTerminalCount == 0)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) {
            try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry)
        }
        #expect(try Data(contentsOf: requestFile) == requestBytes)
        #expect(try Data(contentsOf: operationFile) == operationBytes)
    }

    @Test("Exact retained recovery releases linked publication capacity while preserving original outcomes and all evidence",
          arguments: [AutomationOperationRegistry.Outcome.recoveryRequired, .partialUncertain], [false, true])
    func resolvedRecoveryRetirement(outcome: AutomationOperationRegistry.Outcome, restored: Bool) throws {
        let root = try directory()
        let operationRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: operationRoot)
        }
        let store = MCPNativeReviewRequestStore(storageDirectory: root, maximumRecords: 3)
        let registry = AutomationOperationRegistry(storageDirectory: operationRoot)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: operationRoot)
        let epoch = try store.capacitySnapshot().epoch
        let id = UUID()
        let operation = try terminalFixture(store: store, registry: registry, id: id, epoch: epoch,
                                            purpose: .xmpPublication, outcome: outcome)
        if outcome == .partialUncertain {
            // Cancellation can leave uncertainty; its resolved receipt qualifies equally.
            try replaceArchive(at: operationRoot) { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["state"] = "cancelled"
                records[0]["cancellationRequestedAt"] = now.addingTimeInterval(2).timeIntervalSinceReferenceDate
                archive["records"] = records
            }
        }
        try recoveryFixture(recovery: recovery, operationID: operation.id, restored: restored)
        try recovery.reconcileHistoryDisposition {
            try registry.recordRecoveryResolution($0, now: now.addingTimeInterval(4))
        }
        let awaiting = try store.request(requestID: UUID(), requestEpoch: epoch, planID: planID,
                                         purpose: .pendingDraft, now: now)
        let unknownID = UUID()
        _ = try store.request(requestID: unknownID, requestEpoch: epoch, planID: planID,
                              purpose: .xmpPublication, now: now)
        _ = try store.admit(unknownID, requestEpoch: epoch, now: now)
        let unknown = try store.cancel(unknownID, requestEpoch: epoch, now: now)
        let requestFile = root.appendingPathComponent("operations.json")
        let operationFile = operationRoot.appendingPathComponent("operations.json")
        let recoveryFile = operationRoot.appendingPathComponent("iptc-xmp-recovery/operations.json")
        let operationBytes = try Data(contentsOf: operationFile)
        let recoveryBytes = try Data(contentsOf: recoveryFile)
        let operationRecords = try registry.records()
        #expect(try store.terminalCapacitySnapshot(registry: registry).confirmedTerminalCount == 0)
        #expect(try store.terminalCapacitySnapshot(registry: registry, recoveryStore: recovery).confirmedTerminalCount == 1)
        #expect(throws: MCPNativeReviewRequestStore.Failure.capacity) {
            try store.request(requestID: UUID(), requestEpoch: epoch, planID: planID, purpose: .pendingDraft, now: now)
        }
        let result = try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry, recoveryStore: recovery)
        #expect(result.retiredCount == 1)
        #expect(result.epoch != epoch)
        #expect(try store.records() == [awaiting, unknown])
        #expect(try registry.records() == operationRecords)
        #expect(try registry.inspect(operation.id).outcome == outcome)
        #expect(try Data(contentsOf: operationFile) == operationBytes)
        #expect(try Data(contentsOf: recoveryFile) == recoveryBytes)
        let requestBytes = try Data(contentsOf: requestFile)
        #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
            try store.request(requestID: id, requestEpoch: epoch, planID: planID, purpose: .xmpPublication, now: now)
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
            try store.request(requestID: id, planID: planID, purpose: .xmpPublication, now: now)
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
            try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry, recoveryStore: recovery)
        }
        #expect(try Data(contentsOf: requestFile) == requestBytes)
        let reopened = MCPNativeReviewRequestStore(storageDirectory: root)
        let reopenedRegistry = AutomationOperationRegistry(storageDirectory: operationRoot)
        let reopenedRecovery = MCPIPTCPatchXMPRecoveryStore(directory: operationRoot)
        #expect(try reopened.terminalCapacitySnapshot(registry: reopenedRegistry, recoveryStore: reopenedRecovery).epoch == result.epoch)
        #expect(throws: MCPNativeReviewRequestStore.Failure.unknownRequest) { try reopened.inspect(id) }
        #expect(try reopened.records() == [awaiting, unknown])
        _ = try store.request(requestID: id, requestEpoch: result.epoch, planID: planID,
                              purpose: .xmpPublication, now: now.addingTimeInterval(5))
        #expect(throws: MCPNativeReviewRequestStore.Failure.staleEpoch) {
            try store.admit(id, requestEpoch: epoch, now: now.addingTimeInterval(6))
        }
    }

    @Test("Resolved recovery requires exact ID, plan, digest, disposition and current request evidence",
          arguments: ["id", "plan", "digest", "disposition", "olderResolution", "lateCancellation", "markerMissing", "unresolved"])
    func recoveryEvidenceRefusals(mismatch: String) throws {
        let root = try directory()
        let operationRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: operationRoot)
        }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let registry = AutomationOperationRegistry(storageDirectory: operationRoot)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: operationRoot)
        let epoch = try store.capacitySnapshot().epoch
        let id = UUID()
        let operation = try terminalFixture(store: store, registry: registry, id: id, epoch: epoch,
                                            purpose: .xmpPublication, outcome: .recoveryRequired)
        try recoveryFixture(recovery: recovery, operationID: mismatch == "id" ? UUID() : operation.id,
                            plan: mismatch == "plan" ? UUID().uuidString.lowercased() : nil)
        try recovery.reconcileHistoryDisposition {
            try registry.recordRecoveryResolution($0, now: now.addingTimeInterval(4))
        }
        if ["digest", "disposition", "olderResolution"].contains(mismatch) {
            try replaceArchive(at: operationRoot) { archive in
                var records = archive["records"] as! [[String: Any]]
                var resolution = records[0]["recoveryResolution"] as! [String: Any]
                if mismatch == "digest" { resolution["receiptSHA256"] = String(repeating: "a", count: 64) }
                if mismatch == "disposition" { resolution["disposition"] = "restored" }
                if mismatch == "olderResolution" { resolution["resolvedAt"] = now.addingTimeInterval(1).timeIntervalSinceReferenceDate }
                records[0]["recoveryResolution"] = resolution
                archive["records"] = records
            }
        }
        if mismatch == "lateCancellation" {
            _ = try store.cancel(id, requestEpoch: epoch, now: now.addingTimeInterval(5))
            // An unrelated operation timestamp must not make the older resolution current.
            try replaceArchive(at: operationRoot) { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0]["updatedAt"] = now.addingTimeInterval(6).timeIntervalSinceReferenceDate
                archive["records"] = records
            }
        }
        if mismatch == "markerMissing" {
            try replaceArchive(at: operationRoot) { archive in
                var records = archive["records"] as! [[String: Any]]
                records[0].removeValue(forKey: "recoveryResolution")
                archive["records"] = records
            }
        }
        if mismatch == "unresolved" {
            // A later journal cannot substitute for the exact separately resolved operation.
            _ = try recovery.stage(id: UUID(), planID: planID, targetPath: "/private/tmp/photo.xmp",
                binding: .init(sourceRevision: "source", xmpSidecarRevision: "xmp", appSidecarRevision: "app", authorizationRevision: UUID()),
                original: Data("original".utf8), candidate: Data("candidate".utf8))
        }
        let requestFile = root.appendingPathComponent("operations.json")
        let requestBytes = try Data(contentsOf: requestFile)
        let operationFile = operationRoot.appendingPathComponent("operations.json")
        let operationBytes = try Data(contentsOf: operationFile)
        let recoveryFile = operationRoot.appendingPathComponent("iptc-xmp-recovery/operations.json")
        let recoveryBytes = try Data(contentsOf: recoveryFile)
        #expect(try store.terminalCapacitySnapshot(registry: registry, recoveryStore: recovery).confirmedTerminalCount == 0)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) {
            try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry, recoveryStore: recovery)
        }
        #expect(try Data(contentsOf: requestFile) == requestBytes)
        #expect(try Data(contentsOf: operationFile) == operationBytes)
        #expect(try Data(contentsOf: recoveryFile) == recoveryBytes)
        #expect(try store.capacitySnapshot().epoch == epoch)
    }

    @Test("Recovery cleanup reloads retained journals and refuses loss, replacement, corruption and lock contention",
          arguments: ["missing", "replaced", "corrupt", "insecure", "contended"])
    func recoveryJournalRevalidation(change: String) throws {
        let root = try directory()
        let operationRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: operationRoot)
        }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let registry = AutomationOperationRegistry(storageDirectory: operationRoot)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: operationRoot)
        let competitor = MCPIPTCPatchXMPRecoveryStore(directory: operationRoot)
        let epoch = try store.capacitySnapshot().epoch
        let id = UUID()
        let operation = try terminalFixture(store: store, registry: registry, id: id, epoch: epoch,
                                            purpose: .xmpPublication, outcome: .partialUncertain)
        try recoveryFixture(recovery: recovery, operationID: operation.id)
        try recovery.reconcileHistoryDisposition {
            try registry.recordRecoveryResolution($0, now: now.addingTimeInterval(4))
        }
        #expect(try store.terminalCapacitySnapshot(registry: registry, recoveryStore: recovery).confirmedTerminalCount == 1)
        let requestFile = root.appendingPathComponent("operations.json")
        let requestBytes = try Data(contentsOf: requestFile)
        let operationFile = operationRoot.appendingPathComponent("operations.json")
        let operationBytes = try Data(contentsOf: operationFile)
        let recoveryFile = operationRoot.appendingPathComponent("iptc-xmp-recovery/operations.json")
        let recoveryBytes = try Data(contentsOf: recoveryFile)
        switch change {
        case "missing": try FileManager.default.removeItem(at: recoveryFile)
        case "replaced": try recoveryFixture(recovery: competitor, operationID: UUID())
        case "corrupt": try Data("broken".utf8).write(to: recoveryFile)
        case "insecure": #expect(chmod(recoveryFile.path, 0o644) == 0)
        default: break
        }
        if change == "contended" {
            try recovery.withLockedHistoryDisposition { receipt in
                #expect(receipt?.operationID == operation.id)
                #expect(throws: MCPNativeReviewRequestStore.Failure.storageUnavailable) {
                    try store.terminalCapacitySnapshot(registry: registry, recoveryStore: competitor)
                }
                #expect(throws: MCPNativeReviewRequestStore.Failure.storageUnavailable) {
                    try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry, recoveryStore: competitor)
                }
                #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
                    try recoveryFixture(recovery: competitor, operationID: UUID())
                }
            }
        } else if change == "corrupt" || change == "insecure" {
            let expected: MCPNativeReviewRequestStore.Failure = change == "corrupt" ? .invalidStorage : .storageUnavailable
            #expect(throws: expected) {
                try store.terminalCapacitySnapshot(registry: registry, recoveryStore: recovery)
            }
            #expect(throws: expected) {
                try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry, recoveryStore: recovery)
            }
        } else {
            #expect(try store.terminalCapacitySnapshot(registry: registry, recoveryStore: recovery).confirmedTerminalCount == 0)
            #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) {
                try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry, recoveryStore: recovery)
            }
        }
        #expect(try Data(contentsOf: requestFile) == requestBytes)
        #expect(try Data(contentsOf: operationFile) == operationBytes)
        #expect(try store.capacitySnapshot().epoch == epoch)
        if change == "missing" {
            #expect(!FileManager.default.fileExists(atPath: recoveryFile.path))
        } else if change == "corrupt" {
            #expect(try Data(contentsOf: recoveryFile) == Data("broken".utf8))
        } else if change != "replaced" {
            #expect(try Data(contentsOf: recoveryFile) == recoveryBytes)
        }
        // Restoring the retained evidence makes the same explicit cleanup available again.
        if change == "insecure" { #expect(chmod(recoveryFile.path, 0o600) == 0) }
        try recoveryBytes.write(to: recoveryFile)
        #expect(chmod(recoveryFile.path, 0o600) == 0)
        #expect(try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry, recoveryStore: recovery).retiredCount == 1)
        #expect(try Data(contentsOf: operationFile) == operationBytes)
        #expect(try Data(contentsOf: recoveryFile) == recoveryBytes)
    }

    @Test("Publication verification and incomplete restoration never substitute for a resolved recovery journal", arguments: [false, true])
    func onlyResolvedRecoveryJournals(verified: Bool) throws {
        let root = try directory()
        let operationRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: operationRoot)
        }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let registry = AutomationOperationRegistry(storageDirectory: operationRoot)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: operationRoot)
        let epoch = try store.capacitySnapshot().epoch
        let operation = try terminalFixture(store: store, registry: registry, id: UUID(), epoch: epoch,
                                            purpose: .xmpPublication, outcome: .recoveryRequired)
        try recoveryFixture(recovery: recovery, operationID: operation.id, restored: true,
                            complete: false, verified: verified)
        let recoveryFile = operationRoot.appendingPathComponent("iptc-xmp-recovery/operations.json")
        let recoveryBytes = try Data(contentsOf: recoveryFile)
        // Even a syntactically valid marker with this journal's exact digest cannot
        // upgrade publication verification or partial restoration to recovery resolution.
        try replaceArchive(at: operationRoot) { archive in
            var records = archive["records"] as! [[String: Any]]
            records[0]["updatedAt"] = now.addingTimeInterval(4).timeIntervalSinceReferenceDate
            records[0]["recoveryResolution"] = ["disposition": "restored",
                "receiptSHA256": SHA256.hash(data: recoveryBytes).map { String(format: "%02x", $0) }.joined(),
                "resolvedAt": now.addingTimeInterval(4).timeIntervalSinceReferenceDate]
            archive["records"] = records
        }
        #expect(try recovery.withLockedHistoryDisposition { $0 == nil })
        let requestFile = root.appendingPathComponent("operations.json")
        let requestBytes = try Data(contentsOf: requestFile)
        let operationFile = operationRoot.appendingPathComponent("operations.json")
        let operationBytes = try Data(contentsOf: operationFile)
        #expect(try store.terminalCapacitySnapshot(registry: registry, recoveryStore: recovery).confirmedTerminalCount == 0)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) {
            try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry, recoveryStore: recovery)
        }
        #expect(try Data(contentsOf: requestFile) == requestBytes)
        #expect(try Data(contentsOf: operationFile) == operationBytes)
        #expect(try Data(contentsOf: recoveryFile) == recoveryBytes)
    }

    private func recoveryFixture(recovery: MCPIPTCPatchXMPRecoveryStore, operationID: UUID,
                                 plan: String? = nil, restored: Bool = false,
                                 complete: Bool = true, verified: Bool = false) throws {
        let material = try recovery.stage(id: operationID, planID: plan ?? planID, targetPath: "/private/tmp/photo.xmp",
            binding: .init(sourceRevision: "source", xmpSidecarRevision: "xmp", appSidecarRevision: "app", authorizationRevision: UUID()),
            original: Data("original".utf8), candidate: Data("candidate".utf8),
            appSidecarRecovery: .init(original: Data("app-original".utf8), candidate: Data("app-candidate".utf8)),
            publicationApprovalID: UUID())
        if restored {
            try recovery.recordInstalled(material, installed: .init(xmpRevision: "installed-xmp", appRevision: nil)) {}
            try recovery.recordInstalled(material, installed: .init(xmpRevision: "installed-xmp", appRevision: "installed-app")) {}
            if verified {
                try recovery.recordVerified(material) {}
            } else {
                try recovery.recordRestored(material, restored: .init(xmpRevision: "restored-xmp", appRevision: nil)) {}
                if complete {
                    try recovery.recordRestored(material, restored: .init(xmpRevision: "restored-xmp", appRevision: "restored-app"), complete: true) {}
                }
            }
        } else {
            try recovery.recordUnchanged(material) {}
        }
    }

    @Test("Cleanup revalidates removed history and later linked cancellation instead of trusting an earlier count")
    func terminalRecoveryRevalidatesEvidence() throws {
        let root = try directory()
        let operationRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: operationRoot)
        }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let registry = AutomationOperationRegistry(storageDirectory: operationRoot)
        let competitor = AutomationOperationRegistry(storageDirectory: operationRoot)
        let epoch = try store.capacitySnapshot().epoch
        let id = UUID()
        let removed = try terminalFixture(store: store, registry: registry, id: id, epoch: epoch,
                                          purpose: .pendingDraft, outcome: .failed)
        let cancellationID = UUID()
        _ = try terminalFixture(store: store, registry: registry, id: cancellationID, epoch: epoch,
                                purpose: .pendingDraft, outcome: .verified)
        #expect(try store.terminalCapacitySnapshot(registry: registry).confirmedTerminalCount == 2)
        try competitor.removeTerminal(removed.id, ownerID: removed.ownerID)
        let cancelled = try store.cancel(cancellationID, requestEpoch: epoch, now: now.addingTimeInterval(4))
        let file = root.appendingPathComponent("operations.json")
        let bytes = try Data(contentsOf: file)
        #expect(try store.terminalCapacitySnapshot(registry: registry).confirmedTerminalCount == 0)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) {
            try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry)
        }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try store.inspect(cancellationID) == cancelled)
        #expect(try store.capacitySnapshot().epoch == epoch)
    }

    @Test("Locked terminal evidence prevents concurrent history deletion and contention cannot rotate request epochs")
    func lockedTerminalEvidence() throws {
        let root = try directory()
        let operationRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: operationRoot)
        }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let registry = AutomationOperationRegistry(storageDirectory: operationRoot)
        let competitor = AutomationOperationRegistry(storageDirectory: operationRoot)
        let epoch = try store.capacitySnapshot().epoch
        let operation = try terminalFixture(store: store, registry: registry, id: UUID(), epoch: epoch,
                                            purpose: .pendingDraft, outcome: .verified)
        let requestFile = root.appendingPathComponent("operations.json")
        let requestBytes = try Data(contentsOf: requestFile)
        let operationFile = operationRoot.appendingPathComponent("operations.json")
        let operationBytes = try Data(contentsOf: operationFile)
        try registry.withLockedRecords { records in
            #expect(records == [operation])
            #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
                try competitor.removeTerminal(operation.id, ownerID: operation.ownerID)
            }
            #expect(throws: MCPNativeReviewRequestStore.Failure.storageUnavailable) {
                try store.terminalCapacitySnapshot(registry: competitor)
            }
            #expect(throws: MCPNativeReviewRequestStore.Failure.storageUnavailable) {
                try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: competitor)
            }
        }
        let requestHolder = AutomationOperationPersistence(directory: root, maximumBytes: 1_048_576)
        try requestHolder.transaction(readOnly: true) { bytes in
            #expect(throws: MCPNativeReviewRequestStore.Failure.storageUnavailable) {
                try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry)
            }
            return ((), try #require(bytes))
        }
        #expect(try Data(contentsOf: requestFile) == requestBytes)
        #expect(try Data(contentsOf: operationFile) == operationBytes)
        #expect(try store.capacitySnapshot().epoch == epoch)
        #expect(try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry).retiredCount == 1)
        #expect(try Data(contentsOf: operationFile) == operationBytes)
    }

    @Test("Unavailable or corrupt operation evidence fails closed without changing requests or disabling cancelled-only maintenance")
    func invalidTerminalEvidenceStorage() throws {
        let root = try directory()
        let operationRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: operationRoot)
        }
        let store = MCPNativeReviewRequestStore(storageDirectory: root)
        let registry = AutomationOperationRegistry(storageDirectory: operationRoot)
        let epoch = try store.capacitySnapshot().epoch
        #expect(try store.terminalCapacitySnapshot(registry: registry).confirmedTerminalCount == 0)
        #expect(!FileManager.default.fileExists(atPath: operationRoot.path))
        let id = UUID()
        _ = try terminalFixture(store: store, registry: registry, id: id, epoch: epoch,
                                purpose: .pendingDraft, outcome: .verified)
        let cancelledID = UUID()
        _ = try store.request(requestID: cancelledID, requestEpoch: epoch, planID: planID,
                              purpose: .pendingDraft, now: now)
        _ = try store.cancel(cancelledID, requestEpoch: epoch, now: now)
        let requestFile = root.appendingPathComponent("operations.json")
        let requestBytes = try Data(contentsOf: requestFile)
        let operationFile = operationRoot.appendingPathComponent("operations.json")
        let operationBytes = try Data(contentsOf: operationFile)
        try Data("broken".utf8).write(to: operationFile)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidStorage) {
            try store.terminalCapacitySnapshot(registry: registry)
        }
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidStorage) {
            try store.recoverConfirmedTerminalCapacity(expectedEpoch: epoch, registry: registry)
        }
        #expect(try Data(contentsOf: requestFile) == requestBytes)
        #expect(try Data(contentsOf: operationFile) == Data("broken".utf8))
        #expect(try store.capacitySnapshot().cancelledBeforeAdmissionCount == 1)
        let recovered = try store.recoverCancelledCapacity(expectedEpoch: epoch)
        #expect(recovered.retiredCount == 1)
        #expect(try store.inspect(id).state == .linked)
        try operationBytes.write(to: operationFile)
        #expect(chmod(operationFile.path, 0o644) == 0)
        let linkedBytes = try Data(contentsOf: requestFile)
        #expect(throws: MCPNativeReviewRequestStore.Failure.storageUnavailable) {
            try store.recoverConfirmedTerminalCapacity(expectedEpoch: recovered.epoch, registry: registry)
        }
        #expect(try Data(contentsOf: requestFile) == linkedBytes)
        #expect(chmod(operationFile.path, 0o600) == 0)
        #expect(try store.recoverConfirmedTerminalCapacity(expectedEpoch: recovered.epoch, registry: registry).retiredCount == 1)
    }

    private func terminalFixture(store: MCPNativeReviewRequestStore, registry: AutomationOperationRegistry,
                                 id: UUID, epoch: UUID?, purpose: MCPNativeReviewRequestStore.Purpose,
                                 outcome: AutomationOperationRegistry.Outcome,
                                 kind: AutomationOperationRegistry.Kind? = nil) throws -> AutomationOperationRegistry.Record {
        if let epoch {
            _ = try store.request(requestID: id, requestEpoch: epoch, planID: planID, purpose: purpose, now: now)
        } else {
            _ = try store.request(requestID: id, planID: planID, purpose: purpose, now: now)
        }
        _ = try store.admit(id, requestEpoch: epoch, now: now)
        let operation = try registry.enqueue(kind: kind ?? (purpose == .pendingDraft ? .iptcDraft : .iptcPatch),
                                              ownerID: UUID(), now: now.addingTimeInterval(1))
        _ = try store.link(id, operationID: operation.id, now: now.addingTimeInterval(2))
        if outcome == .cancelled {
            _ = try registry.requestCancellation(operation.id, now: now.addingTimeInterval(2))
            return try registry.acknowledgeCancellation(operation.id, ownerID: operation.ownerID,
                                                         now: now.addingTimeInterval(3))
        }
        _ = try registry.start(operation.id, ownerID: operation.ownerID, now: now.addingTimeInterval(2))
        return try registry.finish(operation.id, ownerID: operation.ownerID, outcome: outcome, now: now.addingTimeInterval(3))
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
