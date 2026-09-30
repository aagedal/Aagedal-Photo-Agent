import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Private durable ordered automation batch progress")
struct AutomationOperationBatchProgressTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func directory() throws -> URL {
        let path = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("operation-batch-\(UUID().uuidString)", isDirectory: true)
    }

    private func rewrite(_ root: URL, _ body: (inout [String: Any]) throws -> Void) throws -> Data {
        let url = root.appendingPathComponent("operations.json")
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let encodedPayload = try #require(envelope["payload"] as? String)
        let payload = try #require(Data(base64Encoded: encodedPayload))
        var archive = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        try body(&archive)
        let changed = try JSONSerialization.data(withJSONObject: archive)
        envelope["payload"] = changed.base64EncodedString()
        envelope["sha256"] = SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
        let bytes = try JSONSerialization.data(withJSONObject: envelope)
        try bytes.write(to: url)
        return bytes
    }

    @Test("A completed ordered batch survives relaunch and contains only closed evidence")
    func durableBatch() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        let operation = try registry.enqueue(kind: .voiceTranscription, ownerID: owner, now: now)
        let configured = try registry.configureBatch(operation.id, ownerID: owner, itemCount: 3, now: now)
        #expect(configured.batchProgress?.items.map(\.index) == [0, 1, 2])
        #expect(configured.batchProgress?.itemCount == 3)
        #expect(configured.batchProgress?.completedCount == 0)
        _ = try registry.start(operation.id, ownerID: owner, now: now)
        for index in 0..<3 {
            _ = try registry.startBatchItem(operation.id, ownerID: owner, index: index, now: now)
            let progress = try registry.finishBatchItem(operation.id, ownerID: owner, index: index, outcome: .draftSaved, now: now)
            #expect(progress.batchProgress?.completedCount == index + 1)
            #expect(try AutomationOperationRegistry(storageDirectory: root).inspect(operation.id) == progress)
        }
        let completed = try registry.finish(operation.id, ownerID: owner, outcome: .verified, now: now)
        #expect(try AutomationOperationRegistry(storageDirectory: root).inspect(operation.id) == completed)
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("operations.json"))) as? [String: Any])
        let encodedPayload = try #require(envelope["payload"] as? String)
        let payload = try #require(Data(base64Encoded: encodedPayload))
        let archive = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(archive["schemaVersion"] as? Int == 2)
        let records = try #require(archive["records"] as? [[String: Any]])
        let batch = try #require(records[0]["batchProgress"] as? [String: Any])
        #expect(Set(batch.keys) == ["items"])
        let items = try #require(batch["items"] as? [[String: Any]])
        #expect(items.allSatisfy { Set($0.keys) == ["index", "state", "outcome"] })
    }

    @Test("Ownership, order, clock and immutable completion guards preserve exact bytes")
    func transitionGuards() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        let operation = try registry.enqueue(kind: .voiceTranscription, ownerID: owner, now: now)
        #expect(throws: AutomationOperationRegistry.Failure.wrongOwner) {
            try registry.configureBatch(operation.id, ownerID: UUID(), itemCount: 2, now: now)
        }
        #expect(throws: AutomationOperationRegistry.Failure.unknownOperation) {
            try registry.configureBatch(UUID(), ownerID: owner, itemCount: 2, now: now)
        }
        _ = try registry.configureBatch(operation.id, ownerID: owner, itemCount: 2, now: now)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.startBatchItem(operation.id, ownerID: owner, index: 0, now: now)
        }
        _ = try registry.start(operation.id, ownerID: owner, now: now)
        let original = try Data(contentsOf: root.appendingPathComponent("operations.json"))
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.configureBatch(operation.id, ownerID: owner, itemCount: 1, now: now)
        }
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.startBatchItem(operation.id, ownerID: owner, index: 1, now: now)
        }
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.finishBatchItem(operation.id, ownerID: owner, index: 0, outcome: .draftSaved, now: now)
        }
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.finish(operation.id, ownerID: owner, outcome: .verified, now: now)
        }
        for index in [-1, 2] {
            #expect(throws: AutomationOperationRegistry.Failure.invalidArguments) {
                try registry.startBatchItem(operation.id, ownerID: owner, index: index, now: now)
            }
        }
        #expect(try Data(contentsOf: root.appendingPathComponent("operations.json")) == original)
        _ = try registry.startBatchItem(operation.id, ownerID: owner, index: 0, now: now.addingTimeInterval(1))
        #expect(throws: AutomationOperationRegistry.Failure.wrongOwner) {
            try registry.finishBatchItem(operation.id, ownerID: UUID(), index: 0, outcome: .draftSaved, now: now.addingTimeInterval(1))
        }
        #expect(throws: AutomationOperationRegistry.Failure.wrongOwner) {
            try registry.startBatchItem(operation.id, ownerID: UUID(), index: 1, now: now.addingTimeInterval(1))
        }
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.startBatchItem(operation.id, ownerID: owner, index: 1, now: now.addingTimeInterval(1))
        }
        #expect(throws: AutomationOperationRegistry.Failure.invalidArguments) {
            try registry.finishBatchItem(operation.id, ownerID: owner, index: 0, outcome: .failed, now: now)
        }
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.finishBatchItem(operation.id, ownerID: owner, index: 0, outcome: .cancelled, now: now.addingTimeInterval(1))
        }
        _ = try registry.finishBatchItem(operation.id, ownerID: owner, index: 0, outcome: .failed, now: now.addingTimeInterval(1))
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.startBatchItem(operation.id, ownerID: owner, index: 0, now: now.addingTimeInterval(1))
        }
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.finishBatchItem(operation.id, ownerID: owner, index: 0, outcome: .draftSaved, now: now.addingTimeInterval(1))
        }
        let terminal = try registry.finish(operation.id, ownerID: owner, outcome: .failed, now: now.addingTimeInterval(1))
        #expect(terminal.batchProgress?.items[1].state == .queued)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.startBatchItem(operation.id, ownerID: owner, index: 1, now: now.addingTimeInterval(1))
        }
    }

    @Test("Cancellation preserves a completed save and queued suffix without starting more work")
    func cancellationRace() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        let operation = try registry.enqueue(kind: .voiceTranscription, ownerID: owner, now: now)
        _ = try registry.configureBatch(operation.id, ownerID: owner, itemCount: 3, now: now)
        _ = try registry.start(operation.id, ownerID: owner, now: now)
        _ = try registry.startBatchItem(operation.id, ownerID: owner, index: 0, now: now)
        _ = try registry.requestCancellation(operation.id, now: now)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.acknowledgeCancellation(operation.id, ownerID: owner, now: now)
        }
        _ = try registry.finishBatchItem(operation.id, ownerID: owner, index: 0, outcome: .draftSaved, now: now)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.startBatchItem(operation.id, ownerID: owner, index: 1, now: now)
        }
        let cancelled = try registry.acknowledgeCancellation(operation.id, ownerID: owner, now: now)
        #expect(cancelled.batchProgress?.items.map(\.state) == [.completed, .queued, .queued])
        #expect(cancelled.batchProgress?.items[0].outcome == .draftSaved)
        #expect(try AutomationOperationRegistry(storageDirectory: root).inspect(operation.id) == cancelled)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.finishBatchItem(operation.id, ownerID: owner, index: 1, outcome: .cancelled, now: now)
        }
        let queued = try registry.enqueue(kind: .voiceTranscription, ownerID: owner, now: now)
        _ = try registry.requestCancellation(queued.id, now: now)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.configureBatch(queued.id, ownerID: owner, itemCount: 1, now: now)
        }
    }

    @Test("Uncertain running work survives owner reconciliation without being replayed")
    func abandonedWork() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        let operation = try registry.enqueue(kind: .voiceTranscription, ownerID: owner, now: now)
        _ = try registry.configureBatch(operation.id, ownerID: owner, itemCount: 3, now: now)
        _ = try registry.start(operation.id, ownerID: owner, now: now)
        _ = try registry.startBatchItem(operation.id, ownerID: owner, index: 0, now: now)
        _ = try registry.finishBatchItem(operation.id, ownerID: owner, index: 0, outcome: .draftSaved, now: now)
        _ = try registry.startBatchItem(operation.id, ownerID: owner, index: 1, now: now)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.finish(operation.id, ownerID: owner, outcome: .failed, now: now)
        }
        let reconciled = try #require(try registry.reconcileStoppedOwner(ownerID: owner, now: now).first)
        #expect(reconciled.outcome == .recoveryRequired)
        #expect(reconciled.batchProgress?.items.map(\.state) == [.completed, .running, .queued])
        #expect(reconciled.batchProgress?.completedCount == 1)
        #expect(try AutomationOperationRegistry(storageDirectory: root).inspect(operation.id) == reconciled)
    }

    @Test("Closed item failures remain distinct and uncertainty cannot become a definite terminal result", arguments:
        [AutomationOperationRegistry.BatchItemOutcome.failed, .stale, .cancelled, .recoveryRequired])
    func closedOutcomes(outcome: AutomationOperationRegistry.BatchItemOutcome) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        let operation = try registry.enqueue(kind: .voiceTranscription, ownerID: owner, now: now)
        _ = try registry.configureBatch(operation.id, ownerID: owner, itemCount: 1, now: now)
        _ = try registry.start(operation.id, ownerID: owner, now: now)
        _ = try registry.startBatchItem(operation.id, ownerID: owner, index: 0, now: now)
        _ = try registry.requestCancellation(operation.id, now: now)
        let progress = try registry.finishBatchItem(operation.id, ownerID: owner, index: 0, outcome: outcome, now: now)
        #expect(progress.batchProgress?.items[0].outcome == outcome)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.finish(operation.id, ownerID: owner, outcome: .verified, now: now)
        }
        if outcome == .recoveryRequired {
            #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
                try registry.finish(operation.id, ownerID: owner, outcome: .failed, now: now)
            }
            #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
                try registry.acknowledgeCancellation(operation.id, ownerID: owner, now: now)
            }
            _ = try registry.finish(operation.id, ownerID: owner, outcome: .recoveryRequired, now: now)
        } else {
            _ = try registry.acknowledgeCancellation(operation.id, ownerID: owner, now: now)
        }
        #expect(try AutomationOperationRegistry(storageDirectory: root).inspect(operation.id).batchProgress == progress.batchProgress)
    }

    @Test("Batch bounds, operation kind and byte capacity fail atomically")
    func boundsAndCapacity() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        let operation = try registry.enqueue(kind: .voiceTranscription, ownerID: owner, now: now)
        for count in [0, -1, 65, Int.max] {
            #expect(throws: AutomationOperationRegistry.Failure.invalidArguments) {
                try registry.configureBatch(operation.id, ownerID: owner, itemCount: count, now: now)
            }
        }
        let url = root.appendingPathComponent("operations.json")
        let bytes = try Data(contentsOf: url)
        #expect(throws: AutomationOperationRegistry.Failure.capacity) {
            try AutomationOperationRegistry(storageDirectory: root, maximumBytes: bytes.count)
                .configureBatch(operation.id, ownerID: owner, itemCount: 64, now: now)
        }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try registry.configureBatch(operation.id, ownerID: owner, itemCount: 64, now: now).batchProgress?.items.count == 64)
        let otherKind = try registry.enqueue(kind: .iptcDraft, ownerID: owner, now: now)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.configureBatch(otherKind.id, ownerID: owner, itemCount: 1, now: now)
        }
    }

    @Test("Legacy v1 stays readable and batch schema appears only while batch records exist")
    func legacySchema() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        let legacy = try registry.enqueue(kind: .iptcDraft, ownerID: owner, now: now)
        #expect(try AutomationOperationRegistry(storageDirectory: root).inspect(legacy.id) == legacy)
        _ = try rewrite(root) { archive in #expect(archive["schemaVersion"] as? Int == 1) }
        let batch = try registry.enqueue(kind: .voiceTranscription, ownerID: owner, now: now)
        _ = try registry.configureBatch(batch.id, ownerID: owner, itemCount: 1, now: now)
        #expect(try registry.inspect(legacy.id).batchProgress == nil)
        _ = try registry.finish(batch.id, ownerID: owner, outcome: .failed, now: now)
        try registry.removeTerminal(batch.id, ownerID: owner)
        _ = try rewrite(root) { archive in #expect(archive["schemaVersion"] as? Int == 1) }
        #expect(try registry.records() == [legacy])
    }

    @Test("Tampered nested evidence and unsupported schemas refuse read and write without replacing bytes", arguments:
        ["v1", "future", "batch-field", "item-field", "outcome", "index", "order", "missing-outcome", "queued-outcome", "verified", "empty", "oversized", "kind", "null", "checksum"])
    func invalidBatchArchive(kind: String) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        let operation = try registry.enqueue(kind: .voiceTranscription, ownerID: owner, now: now)
        _ = try registry.configureBatch(operation.id, ownerID: owner, itemCount: 2, now: now)
        _ = try registry.start(operation.id, ownerID: owner, now: now)
        let url = root.appendingPathComponent("operations.json")
        var corrupted = try rewrite(root) { archive in
            if kind == "v1" { archive["schemaVersion"] = 1 }
            else if kind == "future" { archive["schemaVersion"] = 3 }
            else {
                var records = try #require(archive["records"] as? [[String: Any]])
                var batch = try #require(records[0]["batchProgress"] as? [String: Any])
                var items = try #require(batch["items"] as? [[String: Any]])
                switch kind {
                case "batch-field": batch["photoPath"] = "/private/photo.jpg"
                case "item-field": items[0]["transcript"] = "private words"
                case "outcome": items[0]["state"] = "completed"; items[0]["outcome"] = "private words"
                case "index": items[0]["index"] = 1
                case "order": items[1]["state"] = "running"
                case "missing-outcome": items[0]["state"] = "completed"
                case "queued-outcome": items[0]["outcome"] = "draftSaved"
                case "verified": records[0]["state"] = "completed"; records[0]["outcome"] = "verified"
                case "empty": items = []
                case "oversized": items = (0..<65).map { ["index": $0, "state": "queued"] }
                case "kind": records[0]["kind"] = "iptc_draft"
                default: break
                }
                batch["items"] = items
                records[0]["batchProgress"] = kind == "null" ? NSNull() : batch
                archive["records"] = records
            }
        }
        if kind == "checksum" {
            var envelope = try #require(JSONSerialization.jsonObject(with: corrupted) as? [String: Any])
            envelope["sha256"] = String(repeating: "0", count: 64)
            corrupted = try JSONSerialization.data(withJSONObject: envelope)
            try corrupted.write(to: url)
        }
        #expect(throws: AutomationOperationRegistry.Failure.invalidStorage) { try registry.records() }
        #expect(throws: AutomationOperationRegistry.Failure.invalidStorage) {
            try registry.finish(operation.id, ownerID: owner, outcome: .failed, now: now)
        }
        #expect(try Data(contentsOf: url) == corrupted)
    }
}
