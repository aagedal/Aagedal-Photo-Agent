import CryptoKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Durable face review request retention")
struct MCPFaceScanReviewRequestStoreTests {
    nonisolated private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSince1970: 1_800_000_000)
        private var uptime: TimeInterval = 1_000
        private var boot = UUID().uuidString.lowercased()
        private var available = true
        func date() -> Date { lock.withLock { time } }
        func witness() -> MCPFaceScanReviewRequestStore.MonotonicWitness? {
            lock.withLock { available ? .init(bootSessionID: boot, uptime: uptime) : nil }
        }
        func advance(wall: TimeInterval = 0, monotonic: TimeInterval = 0) {
            lock.withLock { time = time.addingTimeInterval(wall); uptime += monotonic }
        }
        func reboot() { lock.withLock { boot = UUID().uuidString.lowercased() } }
        func loseWitness() { lock.withLock { available = false } }
    }
    nonisolated private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?
        func read() -> Data? { lock.withLock { value } }
        func write(_ data: Data?) { lock.withLock { value = data } }
    }
    nonisolated private struct Fixture {
        let root: URL
        let clock: Clock
        let authority: MCPAuthorizationStore
        let admission: MCPFaceScanAdmissionService
        let store: MCPFaceScanReviewRequestStore
        let epoch: UUID
        var archive: URL { root.appendingPathComponent("requests/operations.json") }
        var arguments: [String: MCPJSONValue] { ["path": .string(root.path)] }
        func request(_ id: UUID = UUID()) throws -> MCPFaceScanReviewRequestStore.Record {
            try store.request(requestID: id, requestEpoch: epoch, arguments: arguments, admission: admission)
        }
        func restarted() -> MCPFaceScanReviewRequestStore {
            MCPFaceScanReviewRequestStore(storageDirectory: root.appendingPathComponent("requests"),
                clock: { clock.date() }, monotonicWitness: { clock.witness() })
        }
    }
    private func fixture(maximumRecords: Int = 64, maximumBytes: Int = 1_048_576) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/face-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("image".utf8).write(to: root.appendingPathComponent("image.jpg"))
        let box = Box(), clock = Clock()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(root); try authority.setEnabled(true)
        let store = MCPFaceScanReviewRequestStore(storageDirectory: root.appendingPathComponent("requests"),
            maximumRecords: maximumRecords, maximumBytes: maximumBytes, clock: { clock.date() }, monotonicWitness: { clock.witness() })
        return Fixture(root: root, clock: clock, authority: authority, admission: MCPFaceScanAdmissionService(authorizationStore: authority),
            store: store, epoch: try store.capacitySnapshot().epoch)
    }
    private func mutate(_ f: Fixture, _ body: (inout [String: Any]) throws -> Void) throws {
        var outer = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.archive)) as? [String: Any])
        var archive = try #require(JSONSerialization.jsonObject(with: Data(base64Encoded: outer["payload"] as! String)!) as? [String: Any])
        try body(&archive)
        let payload = try JSONSerialization.data(withJSONObject: archive)
        outer["payload"] = payload.base64EncodedString()
        outer["sha256"] = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: outer).write(to: f.archive)
    }
    @Test("Read-only inspection creates no archive; capacity initializes a stable bounded epoch")
    func empty() throws {
        let root = URL(fileURLWithPath: "/private/tmp/face-review-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPFaceScanReviewRequestStore(storageDirectory: root, maximumRecords: 100)
        #expect(try store.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.unknownRequest) { try store.inspect(UUID(), requestEpoch: UUID()) }
        let capacity = try store.capacitySnapshot()
        #expect(capacity.maximumRecords == 64)
        #expect(try MCPFaceScanReviewRequestStore(storageDirectory: root).capacitySnapshot() == capacity)
    }
    @Test("Immutable original evidence survives relaunch and exact retries without renewing time")
    func restoration() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), record = try f.request(id), before = try Data(contentsOf: f.archive)
        #expect(record.intent.photoCount == 1)
        #expect(record.intent.expiresAt.timeIntervalSince(record.intent.preparedAt) == 300)
        #expect(record.intentSHA256.count == 64)
        #expect(try f.restarted().inspect(id, requestEpoch: f.epoch) == record)
        f.clock.advance(wall: 301, monotonic: 301)
        #expect(try f.request(id) == record)
        #expect(try Data(contentsOf: f.archive) == before)
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.expiredRequest) { try f.restarted().validateFreshness(record) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".photo_metadata").path))
    }
    @Test("Normalized options bind retries, conflicting identifiers and stale epochs refuse")
    func conflicting() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID()
        let record = try f.store.request(requestID: id, requestEpoch: f.epoch,
            arguments: ["path": .string(f.root.path), "includeJerseyNumbers": .bool(true)], admission: f.admission)
        #expect(record.intent.forceFullScan)
        #expect(try f.store.request(requestID: id, requestEpoch: f.epoch,
            arguments: ["path": .string(f.root.path), "forceFullScan": .bool(true), "includeJerseyNumbers": .bool(true)], admission: f.admission) == record)
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.conflictingRequest) { try f.request(id) }
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.staleEpoch) {
            try f.store.request(requestID: id, requestEpoch: UUID(), arguments: f.arguments, admission: f.admission)
        }
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.staleEpoch) {
            try f.store.request(requestID: UUID(), requestEpoch: UUID(), arguments: f.arguments, admission: f.admission)
        }
    }
    @Test("Frozen wall time cannot renew process-independent monotonic lifetime")
    func monotonicExpiry() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let record = try f.request()
        f.clock.advance(monotonic: 299)
        try f.restarted().validateFreshness(record)
        f.clock.advance(monotonic: 1)
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.expiredRequest) { try f.restarted().validateFreshness(record) }
    }
    @Test("Boot change, missing witness, wall rollback and uptime rollback fail closed")
    func invalidWitnesses() throws {
        for mode in 0..<4 {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let record = try f.request()
            switch mode { case 0: f.clock.reboot(); case 1: f.clock.loseWitness(); case 2: f.clock.advance(wall: -1); default: f.clock.advance(monotonic: -1) }
            #expect(throws: MCPFaceScanReviewRequestStore.Failure.expiredRequest) { try f.restarted().validateFreshness(record) }
            #expect(try f.store.inspect(UUID(uuidString: record.requestID)!, requestEpoch: f.epoch) == record)
        }
    }
    @Test("Fresh recapture rejects changed inventory and authorization")
    func revalidation() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let record = try f.request()
        _ = try f.store.revalidate(record, admission: f.admission)
        try Data("another image".utf8).write(to: f.root.appendingPathComponent("second.jpg"))
        #expect(throws: MCPFaceScanAdmissionService.Failure.staleSnapshot) { try f.store.revalidate(record, admission: f.admission) }
        try f.authority.setEnabled(false)
        #expect(throws: (any Error).self) { try f.store.revalidate(record, admission: f.admission) }
    }
    @Test("Full archives never evict; explicit cancellation cleanup rotates epoch and retains active evidence")
    func capacity() throws {
        let f = try fixture(maximumRecords: 2); defer { try? FileManager.default.removeItem(at: f.root) }
        let cancelledID = UUID(), activeID = UUID()
        _ = try f.request(cancelledID); let active = try f.request(activeID)
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.capacity) { try f.request() }
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.invalidTransition) { try f.store.recoverCancelledCapacity(expectedEpoch: f.epoch) }
        let cancelled = try f.store.cancel(cancelledID, requestEpoch: f.epoch)
        #expect(cancelled.state == .cancelled)
        #expect(try f.store.cancel(cancelledID, requestEpoch: f.epoch) == cancelled)
        #expect(try f.store.capacitySnapshot().cancelledBeforeAdmissionCount == 1)
        let epoch = try f.store.recoverCancelledCapacity(expectedEpoch: f.epoch)
        #expect(epoch != f.epoch)
        #expect(try f.store.inspect(activeID, requestEpoch: f.epoch) == active)
        #expect(try f.request(activeID) == active)
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.staleEpoch) { try f.request(cancelledID) }
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.staleEpoch) { try f.store.recoverCancelledCapacity(expectedEpoch: f.epoch) }
        #expect(try f.restarted().capacitySnapshot().epoch == epoch)
    }
    @Test("Preparation consumes original monotonic lifetime before any record is retained")
    func preparationLifetime() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        nonisolated final class WitnessReads: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int { lock.withLock { count += 1; return count } }
        }
        let reads = WitnessReads()
        let delayed = MCPFaceScanReviewRequestStore(storageDirectory: f.root.appendingPathComponent("delayed-requests"),
            clock: { f.clock.date() }, monotonicWitness: {
                if reads.next() == 2 { f.clock.advance(monotonic: 300) }
                return f.clock.witness()
            })
        let epoch = try delayed.capacitySnapshot().epoch
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.expiredRequest) {
            try delayed.request(requestID: UUID(), requestEpoch: epoch, arguments: f.arguments, admission: f.admission)
        }
        #expect(try delayed.records().isEmpty)
        let lease = try MCPProcessReservation.acquireFolder(f.root); lease.release()
    }

    @Test("Checksums and strict shape/state/identity/date validation reject corrupt retained evidence")
    func malformed() throws {
        for mode in 0..<8 {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            _ = try f.request()
            try mutate(f) { archive in
                var records = archive["records"] as! [[String: Any]], record = records[0]
                var intent = record["intent"] as! [String: Any]
                switch mode {
                case 0: record["requestID"] = (record["requestID"] as! String).uppercased()
                case 1: record["unexpected"] = true
                case 2: record["state"] = "admitted"
                case 3: intent["photoCount"] = 0; record["intent"] = intent
                case 4: intent["expiresAt"] = (intent["preparedAt"] as! Double) + 301; record["intent"] = intent
                case 5: record["cancellationRequestedAt"] = NSNull()
                case 6: record["intentSHA256"] = String(repeating: "0", count: 64)
                default: records.append(record)
                }
                records[0] = record; archive["records"] = records
            }
            #expect(throws: MCPFaceScanReviewRequestStore.Failure.invalidStorage) { try f.restarted().records() }
        }
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.request()
        var outer = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.archive)) as? [String: Any])
        outer["sha256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: outer).write(to: f.archive)
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.invalidStorage) { try f.store.records() }
    }
}
