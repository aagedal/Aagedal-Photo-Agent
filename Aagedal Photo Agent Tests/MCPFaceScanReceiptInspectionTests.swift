import CryptoKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Read-only face receipt inspection")
struct MCPFaceScanReceiptInspectionTests {
    @Test("Managed absent inspection creates no folders or archives")
    func absent() throws {
        let base = URL(fileURLWithPath: "/private/tmp/face-receipts-\(UUID())")
        let location = try MCPFaceScanReceiptStore.defaultStorageDirectory(applicationSupportDirectory: base, arguments: [])
        #expect(try MCPFaceScanReceiptStore(storageDirectory: location).receipts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }

    @Test("UI testing requires an explicit disposable receipt location")
    func isolatedUITests() throws {
        #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
            try MCPFaceScanReceiptStore.defaultStorageDirectory(arguments: ["--ui-testing"])
        }
        #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
            try MCPFaceScanReceiptStore.defaultStorageDirectory(arguments: ["--ui-testing", "--ui-test-face-receipt-root", "relative"])
        }
        let path = "/private/tmp/receipt-\(UUID())"
        #expect(try MCPFaceScanReceiptStore.defaultStorageDirectory(arguments:
            ["--ui-testing", "--ui-test-face-receipt-root", path]).path == path)
    }

    @Test("Corrupt inspection preserves exact bytes and inventory")
    func corrupt() throws {
        let root = URL(fileURLWithPath: "/private/tmp/face-receipts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = root.appendingPathComponent("operations.json")
        let lock = root.appendingPathComponent("operations.lock")
        let original = Data("retained malformed receipt".utf8)
        try original.write(to: archive); try Data().write(to: lock)
        for url in [archive, lock] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        #expect(throws: MCPFaceScanReceiptStore.Failure.invalidStorage) { try MCPFaceScanReceiptStore(storageDirectory: root).receipts() }
        #expect(try Data(contentsOf: archive) == original)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["operations.json", "operations.lock"])
    }
    nonisolated private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func read() -> Data? { lock.withLock { data } }
        func write(_ value: Data?) { lock.withLock { data = value } }
    }
    private struct Fixture {
        let root: URL
        let intent: MCPFaceScanIntentStore.Intent
        let record: MCPFaceScanReviewRequestStore.Record
        let registry: AutomationOperationRegistry
        let operation: AutomationOperationRegistry.Record
        let receipts: MCPFaceScanReceiptStore
    }
    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/face-receipt-binding-\(UUID())")
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("synthetic image".utf8).write(to: photos.appendingPathComponent("image.jpg"))
        let box = Box()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(photos); try authority.setEnabled(true)
        let admission = MCPFaceScanAdmissionService(authorizationStore: authority)
        let requests = MCPFaceScanReviewRequestStore(storageDirectory: root.appendingPathComponent("requests"))
        let id = UUID(), epoch = try requests.capacitySnapshot().epoch
        let request = try requests.request(requestID: id, requestEpoch: epoch,
            arguments: ["path": .string(photos.path)], admission: admission)
        let intents = MCPFaceScanIntentStore(admission: admission)
        let intent = try intents.adopt(record: request, requests: requests)
        let registry = AutomationOperationRegistry(storageDirectory: root.appendingPathComponent("history"))
        let owner = UUID(), operationID = UUID()
        let lease = try registry.acquireOwnerLease(ownerID: owner)
        _ = try requests.admit(id, requestEpoch: epoch, expected: request,
            operationID: operationID, ownerLease: lease, registry: registry)
        _ = try registry.enqueue(kind: .faceScan, ownerID: owner, operationID: operationID, ownerLease: lease)
        let linked = try requests.link(id, requestEpoch: epoch, operationID: operationID, ownerLease: lease, registry: registry)
        _ = try registry.start(operationID, ownerID: owner)
        let terminal = try registry.finish(operationID, ownerID: owner, outcome: .verified)
        let receipts = MCPFaceScanReceiptStore(storageDirectory: root.appendingPathComponent("receipts"))
        try receipts.admit(intent: intent, operationID: operationID, durableAdmission: linked.admission)
        try receipts.markExecutionPossible(operationID)
        try receipts.complete(operationID, evidence: .init(outcome: .verified, processedCount: 1,
            failureCount: 0, unsignedFileCount: 0, committedThumbnailCount: 0,
            committedDocumentCount: 0, resetCommitted: false, persistenceFailed: false))
        return .init(root: root, intent: intent, record: linked, registry: registry, operation: terminal, receipts: receipts)
    }

    @Test("Durable completion requires exact admitted evidence and actual terminal history")
    func durableCompletion() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let receipt = try #require(try f.receipts.receipts().first)
        #expect(receipt.durableAdmission == f.record.admission)
        try receipt.requireCompletion(intent: f.intent, operation: f.operation, durableRecord: f.record, registry: f.registry)
        #expect(throws: MCPFaceScanReceiptStore.Failure.mismatchedCompletion) {
            try receipt.requireCompletion(intent: f.intent, operation: f.operation)
        }
        let unrelated = AutomationOperationRegistry(storageDirectory: f.root.appendingPathComponent("other-history"))
        #expect(throws: MCPFaceScanReceiptStore.Failure.mismatchedCompletion) {
            try receipt.requireCompletion(intent: f.intent, operation: f.operation, durableRecord: f.record, registry: unrelated)
        }
        var legacy = receipt; legacy.durableAdmission = nil
        #expect(throws: MCPFaceScanReceiptStore.Failure.mismatchedCompletion) {
            try legacy.requireCompletion(intent: f.intent, operation: f.operation, durableRecord: f.record, registry: f.registry)
        }
        let unbound = MCPFaceScanReceiptStore(storageDirectory: f.root.appendingPathComponent("unbound"))
        #expect(throws: MCPFaceScanReceiptStore.Failure.mismatchedCompletion) {
            try unbound.admit(intent: f.intent, operationID: f.operation.id)
        }
        let a = try #require(receipt.durableAdmission)
        let different = MCPFaceScanReviewRequestStore.Admission(admissionID: UUID().uuidString.lowercased(),
            requestID: a.requestID, requestEpoch: a.requestEpoch, intentSHA256: a.intentSHA256,
            operationID: a.operationID, ownerID: a.ownerID, admittedAt: a.admittedAt, operationStoragePath: a.operationStoragePath)
        var mismatched = receipt; mismatched.durableAdmission = different
        #expect(throws: MCPFaceScanReceiptStore.Failure.mismatchedCompletion) {
            try mismatched.requireCompletion(intent: f.intent, operation: f.operation, durableRecord: f.record, registry: f.registry)
        }
        let legacyIntent = MCPFaceScanIntentStore.Intent(id: f.intent.id, createdAt: f.intent.createdAt,
            expiresAt: f.intent.expiresAt, prepared: f.intent.prepared)
        try legacy.requireCompletion(intent: legacyIntent, operation: f.operation)
        try unbound.admit(intent: legacyIntent, operationID: f.operation.id)
        #expect(try unbound.receipts().first?.durableAdmission == nil)
        try f.registry.removeTerminal(f.operation.id, ownerID: f.operation.ownerID)
        #expect(throws: AutomationOperationRegistry.Failure.unknownOperation) {
            try receipt.requireCompletion(intent: f.intent, operation: f.operation, durableRecord: f.record, registry: f.registry)
        }
    }

    @Test("Durable receipt bindings reject unknown, null and malformed fields without changing bytes")
    func strictDurableSchema() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appendingPathComponent("receipts/operations.json")
        let original = try Data(contentsOf: file)
        for field in ["unknown", "ownerID", "operationID", "requestEpoch", "intentSHA256", "operationStoragePath", "durableAdmission"] {
            var envelope = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
            let encoded = try #require(envelope["payload"] as? String)
            let payload = try #require(Data(base64Encoded: encoded))
            var archive = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
            var entries = try #require(archive["receipts"] as? [[String: Any]])
            var admission = try #require(entries[0]["durableAdmission"] as? [String: Any])
            switch field {
            case "unknown": admission["unexpected"] = "value"
            case "ownerID": admission[field] = NSNull()
            case "operationID": admission[field] = UUID().uuidString.lowercased()
            case "requestEpoch": admission[field] = "invalid"
            case "intentSHA256": admission[field] = String(repeating: "A", count: 64)
            case "operationStoragePath": admission[field] = "/private/tmp/../history"
            default: break
            }
            if field == "durableAdmission" { entries[0]["durableAdmission"] = NSNull() }
            else { entries[0]["durableAdmission"] = admission }
            archive["receipts"] = entries
            let modifiedPayload = try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys])
            envelope["payload"] = modifiedPayload.base64EncodedString()
            envelope["sha256"] = SHA256.hash(data: modifiedPayload).map { String(format: "%02x", $0) }.joined()
            let modified = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            try modified.write(to: file)
            #expect(throws: MCPFaceScanReceiptStore.Failure.invalidStorage) { try f.receipts.receipts() }
            #expect(try Data(contentsOf: file) == modified)
        }
    }

}
