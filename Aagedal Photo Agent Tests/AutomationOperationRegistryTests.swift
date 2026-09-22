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

    @Test("Same-instance inspection waits for a held transaction and observes its committed bytes")
    func sameInstanceTransactionSerialization() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = AutomationOperationPersistence(directory: root, maximumBytes: 1_024)
        let original = Data("before".utf8)
        let committed = Data("after".utf8)
        try persistence.transaction { _ in ((), original) }
        // Blocking coordination stays off the main actor. Separate GCD queues
        // guarantee actual overlapping OS-lock attempts.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          DispatchQueue(label: "test.operation-persistence.orchestration").async {
            defer { continuation.resume() }
            let writerEntered = DispatchSemaphore(value: 0)
            let releaseWriter = DispatchSemaphore(value: 0)
            let readerStarted = DispatchSemaphore(value: 0)
            let readerFinished = DispatchSemaphore(value: 0)
            let completed = DispatchGroup()
            completed.enter()
            DispatchQueue(label: "test.operation-persistence.writer").async {
                defer { completed.leave() }
                do {
                    try persistence.transaction { existing in
                        #expect(existing == original)
                        writerEntered.signal()
                        try #require(releaseWriter.wait(timeout: .now() + 5) == .success)
                        return ((), committed)
                    }
                } catch { Issue.record("Held writer failed: \(error)") }
            }
            let writerReady = writerEntered.wait(timeout: .now() + 5)
            #expect(writerReady == .success)
            completed.enter()
            DispatchQueue(label: "test.operation-persistence.reader").async {
                defer { readerFinished.signal(); completed.leave() }
                readerStarted.signal()
                do {
                    let read = try persistence.transaction(readOnly: true) { existing in
                        (existing, existing ?? Data())
                    }
                    #expect(read == committed)
                } catch { Issue.record("Same-instance inspection must wait instead of failing: \(error)") }
            }
            #expect(readerStarted.wait(timeout: .now() + 5) == .success)
            // Previously the independent flock descriptor immediately failed here.
            #expect(readerFinished.wait(timeout: .now() + .milliseconds(200)) == .timedOut)
            releaseWriter.signal()
            #expect(completed.wait(timeout: .now() + 10) == .success)
          }
        }
        #expect(try persistence.transaction(readOnly: true) { ($0, $0 ?? Data()) } == committed)
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

    @Test("Stopped-owner reconciliation preserves evidence, terminal records and other owners")
    func stoppedOwnerRecovery() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        let otherOwner = UUID()
        let queued = try registry.enqueue(kind: .metadataTemplate, ownerID: owner, now: now)
        let running = try registry.enqueue(kind: .iptcPatch, ownerID: owner, now: now)
        _ = try registry.start(running.id, ownerID: owner, now: now.addingTimeInterval(1))
        let requested = try registry.requestCancellation(running.id, now: now.addingTimeInterval(2))
        let completed = try registry.enqueue(kind: .faceScan, ownerID: owner, now: now)
        let failed = try registry.finish(completed.id, ownerID: owner, outcome: .failed, now: now)
        let cancelled = try registry.enqueue(kind: .developTemplate, ownerID: owner, now: now)
        _ = try registry.requestCancellation(cancelled.id, now: now)
        let acknowledged = try registry.acknowledgeCancellation(cancelled.id, ownerID: owner, now: now)
        let otherQueued = try registry.enqueue(kind: .voiceTranscription, ownerID: otherOwner, now: now)
        let other = try registry.enqueue(kind: .iptcPatch, ownerID: otherOwner, now: now)
        let otherRunning = try registry.start(other.id, ownerID: otherOwner, now: now)

        // A fresh coordinator must not infer that persisted owners have stopped.
        let restarted = AutomationOperationRegistry(storageDirectory: root)
        #expect(try restarted.inspect(queued.id) == queued)
        #expect(try restarted.inspect(running.id) == requested)
        let recoveredAt = now.addingTimeInterval(3)
        let recovered = try restarted.reconcileStoppedOwner(ownerID: owner, now: recoveredAt)
        #expect(recovered.map(\.id) == [queued.id, running.id])
        for record in recovered {
            #expect(record.ownerID == owner)
            #expect(record.createdAt == now)
            #expect(record.updatedAt == recoveredAt)
            #expect(record.state == .completed)
            #expect(record.outcome == .recoveryRequired)
        }
        #expect(recovered[0].kind == queued.kind)
        #expect(recovered[0].cancellationRequestedAt == nil)
        #expect(recovered[1].kind == requested.kind)
        #expect(recovered[1].cancellationRequestedAt == requested.cancellationRequestedAt)
        #expect(try registry.inspect(failed.id) == failed)
        #expect(try registry.inspect(acknowledged.id) == acknowledged)
        #expect(try registry.inspect(otherQueued.id) == otherQueued)
        #expect(try registry.inspect(otherRunning.id) == otherRunning)
        let snapshot = try registry.records()
        let persisted = try Data(contentsOf: root.appendingPathComponent("operations.json"))
        #expect(try registry.reconcileStoppedOwner(ownerID: owner, now: recoveredAt.addingTimeInterval(10)).isEmpty)
        #expect(try registry.reconcileStoppedOwner(ownerID: UUID(), now: now).isEmpty)
        #expect(try AutomationOperationRegistry(storageDirectory: root).records() == snapshot)
        #expect(try Data(contentsOf: root.appendingPathComponent("operations.json")) == persisted)
        #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
            try registry.finish(running.id, ownerID: owner, outcome: .verified, now: recoveredAt)
        }
    }

    @Test("Recovery rejects an invalid clock for the whole batch without changing durable evidence")
    func recoveryClockRollback() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        _ = try registry.enqueue(kind: .metadataTemplate, ownerID: owner, now: now)
        let later = try registry.enqueue(kind: .iptcPatch, ownerID: owner, now: now)
        _ = try registry.start(later.id, ownerID: owner, now: now.addingTimeInterval(10))
        let records = try registry.records()
        let url = root.appendingPathComponent("operations.json")
        let bytes = try Data(contentsOf: url)
        for invalidTime in [now.addingTimeInterval(5), Date(timeIntervalSinceReferenceDate: .infinity),
                            Date(timeIntervalSinceReferenceDate: .nan)] {
            #expect(throws: AutomationOperationRegistry.Failure.invalidArguments) {
                try registry.reconcileStoppedOwner(ownerID: owner, now: invalidTime)
            }
            #expect(try Data(contentsOf: url) == bytes)
            #expect(try AutomationOperationRegistry(storageDirectory: root).records() == records)
        }
    }

    @Test("Recovery refuses archive growth beyond capacity without committing a partial batch")
    func recoveryCapacityFailure() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationOperationRegistry(storageDirectory: root)
        let owner = UUID()
        _ = try registry.enqueue(kind: .iptcPatch, ownerID: owner, now: now)
        _ = try registry.enqueue(kind: .metadataTemplate, ownerID: owner, now: now)
        let records = try registry.records()
        let url = root.appendingPathComponent("operations.json")
        let bytes = try Data(contentsOf: url)
        let constrained = AutomationOperationRegistry(storageDirectory: root, maximumBytes: bytes.count)
        #expect(throws: AutomationOperationRegistry.Failure.capacity) {
            try constrained.reconcileStoppedOwner(ownerID: owner, now: now)
        }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try AutomationOperationRegistry(storageDirectory: root).records() == records)
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
        #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
            try registry.reconcileStoppedOwner(ownerID: record.ownerID, now: now)
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
