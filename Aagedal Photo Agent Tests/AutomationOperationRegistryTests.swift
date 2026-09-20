import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@_silgen_name("flock")
private nonisolated func testOperationFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

@Suite("Durable shared automation operation records")
struct AutomationOperationRegistryTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func directory() throws -> URL {
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("operation-registry-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Independent coordinators observe durable cancellation without inventing completion")
    func cooperativeCancellation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let first = AutomationOperationRegistry(storageDirectory: root)
        let second = AutomationOperationRegistry(storageDirectory: root)
        #expect(try first.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let queued = try first.enqueue(kind: .iptcPatch, ownerID: owner, now: now)
        #expect(try second.inspect(queued.id) == queued)
        _ = try first.start(queued.id, ownerID: owner, now: now)
        let requested = try second.requestCancellation(queued.id, now: now.addingTimeInterval(1))
        #expect(requested.state == .running)
        #expect(requested.outcome == nil)
        #expect(requested.cancellationRequestedAt != nil)
        let restarted = AutomationOperationRegistry(storageDirectory: root)
        #expect(try restarted.inspect(queued.id) == requested)
        let acknowledged = try first.acknowledgeCancellation(queued.id, ownerID: owner,
            outcome: .partialUncertain, now: now.addingTimeInterval(2))
        #expect(acknowledged.state == .cancelled)
        #expect(acknowledged.outcome == .partialUncertain)
        #expect(try second.requestCancellation(queued.id, now: now.addingTimeInterval(3)) == acknowledged)
    }

    @Test("Queued cancellation prevents execution and requires owner acknowledgement")
    func queuedCancellation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        let record = try registry.enqueue(kind: .developTemplate, ownerID: owner, now: now)
        _ = try registry.requestCancellation(record.id, now: now)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.start(record.id, ownerID: owner, now: now)
        }
        #expect(throws: AutomationOperationRegistry.Failure.wrongOwner) {
            try registry.acknowledgeCancellation(record.id, ownerID: UUID(), now: now)
        }
        #expect(try registry.inspect(record.id).state == .queued)
        #expect(try registry.acknowledgeCancellation(record.id, ownerID: owner, now: now).outcome == .cancelled)
    }

    @Test("Wrong owners, backwards clocks and invalid lifecycle transitions preserve the record")
    func transitionGuards() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        let record = try registry.enqueue(kind: .developTemplate, ownerID: owner, now: now)
        #expect(throws: AutomationOperationRegistry.Failure.wrongOwner) {
            try registry.start(record.id, ownerID: UUID(), now: now)
        }
        #expect(throws: AutomationOperationRegistry.Failure.invalidArguments) {
            try registry.start(record.id, ownerID: owner, now: now.addingTimeInterval(-1))
        }
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.finish(record.id, ownerID: owner, outcome: .verified, now: now)
        }
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.acknowledgeCancellation(record.id, ownerID: owner, now: now)
        }
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.finish(record.id, ownerID: owner, outcome: .cancelled, now: now)
        }
        #expect(try registry.inspect(record.id) == record)
        _ = try registry.start(record.id, ownerID: owner, now: now)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.start(record.id, ownerID: owner, now: now)
        }
    }

    @Test("Verified, failed, uncertain, recovery and stale remain distinct", arguments:
        [AutomationOperationRegistry.Outcome.verified, .failed, .partialUncertain, .recoveryRequired, .stale])
    func outcomes(outcome: AutomationOperationRegistry.Outcome) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        let record = try registry.enqueue(kind: .developTemplate, ownerID: owner, now: now)
        _ = try registry.start(record.id, ownerID: owner, now: now)
        // A request can race verified completion; the verified owner result wins.
        _ = try registry.requestCancellation(record.id, now: now)
        let completed = try registry.finish(record.id, ownerID: owner, outcome: outcome, now: now)
        #expect(completed.state == .completed)
        #expect(completed.outcome == outcome)
        #expect(try AutomationOperationRegistry(storageDirectory: root).inspect(record.id) == completed)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.acknowledgeCancellation(record.id, ownerID: owner, now: now)
        }
    }

    @Test("Terminal retention is bounded and explicit; active records cannot be removed")
    func limitsAndRemoval() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root, maximumRecords: 1)
        let owner = UUID()
        let record = try registry.enqueue(kind: .developTemplate, ownerID: owner, now: now)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.removeTerminal(record.id, ownerID: owner)
        }
        #expect(throws: AutomationOperationRegistry.Failure.capacity) {
            try AutomationOperationRegistry(storageDirectory: root, maximumRecords: 1)
                .enqueue(kind: .developTemplate, ownerID: owner, now: now)
        }
        _ = try registry.finish(record.id, ownerID: owner, outcome: .failed, now: now)
        #expect(throws: AutomationOperationRegistry.Failure.capacity) {
            try registry.enqueue(kind: .developTemplate, ownerID: owner, now: now)
        }
        try registry.removeTerminal(record.id, ownerID: owner)
        #expect(try registry.records().isEmpty)
        let tinyRoot = try directory()
        defer { try? FileManager.default.removeItem(at: tinyRoot) }
        #expect(throws: AutomationOperationRegistry.Failure.capacity) {
            try AutomationOperationRegistry(storageDirectory: tinyRoot, maximumBytes: 10)
                .enqueue(kind: .developTemplate, ownerID: owner, now: now)
        }
    }

    @Test("Corrupt and future records refuse reload without replacing evidence", arguments:
        ["corrupt", "checksum", "schema", "field", "record-field", "state", "unknown-kind", "inconsistent"])
    func invalidArchive(kind: String) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        _ = try registry.enqueue(kind: .developTemplate, ownerID: UUID(), now: now)
        let url = root.appendingPathComponent("operations.json")
        var data = try Data(contentsOf: url)
        if kind == "corrupt" { data = Data("broken".utf8) }
        else {
            var envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if kind == "checksum" { envelope["sha256"] = "broken" }
            else if kind == "field" { envelope["future"] = true }
            else {
                let encoded = try #require(envelope["payload"] as? String)
                let payload = try #require(Data(base64Encoded: encoded))
                var archive = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
                if kind == "schema" { archive["schemaVersion"] = 2 }
                else {
                    var records = try #require(archive["records"] as? [[String: Any]])
                    if kind == "record-field" { records[0]["future"] = true }
                    if kind == "state" { records[0]["state"] = "future" }
                    if kind == "unknown-kind" { records[0]["kind"] = "private-filename.jpg" }
                    if kind == "inconsistent" { records[0]["state"] = "cancelled" }
                    archive["records"] = records
                }
                let changed = try JSONSerialization.data(withJSONObject: archive)
                envelope["payload"] = changed.base64EncodedString()
                envelope["sha256"] = SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
            }
            data = try JSONSerialization.data(withJSONObject: envelope)
        }
        try data.write(to: url)
        #expect(throws: AutomationOperationRegistry.Failure.invalidStorage) { try registry.records() }
        #expect(throws: AutomationOperationRegistry.Failure.invalidStorage) {
            try registry.enqueue(kind: .developTemplate, ownerID: UUID(), now: now)
        }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("An independently held lock refuses reads and mutations without losing evidence")
    func lockContention() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let record = try registry.enqueue(kind: .developTemplate, ownerID: UUID(), now: now)
        let url = root.appendingPathComponent("operations.json")
        let before = try Data(contentsOf: url)
        let descriptor = Darwin.open(root.appendingPathComponent("operations.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { _ = testOperationFlock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        try #require(testOperationFlock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) { try registry.records() }
        #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
            try registry.requestCancellation(record.id, now: now)
        }
        #expect(try Data(contentsOf: url) == before)
        try #require(testOperationFlock(descriptor, LOCK_UN) == 0)
        #expect(try registry.inspect(record.id) == record)
    }

    @Test("Symlink, hardlink and unsafe permissions refuse storage", arguments: ["symlink", "hardlink", "mode"])
    func unsafeStorage(kind: String) throws {
        let root = try directory()
        let extra = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: extra) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        _ = try registry.enqueue(kind: .developTemplate, ownerID: UUID(), now: now)
        let url = root.appendingPathComponent("operations.json")
        let before = try Data(contentsOf: url)
        if kind == "mode" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        else if kind == "hardlink" { try FileManager.default.linkItem(at: url, to: extra) }
        else {
            try FileManager.default.moveItem(at: url, to: extra)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: extra)
        }
        #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) { try registry.records() }
        #expect(try Data(contentsOf: url) == before)
    }
}
