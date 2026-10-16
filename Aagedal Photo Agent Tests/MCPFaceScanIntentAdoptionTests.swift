import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Durable face intent adoption")
struct MCPFaceScanIntentAdoptionTests {
    nonisolated private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var wall = Date(timeIntervalSince1970: 1_800_000_000)
        private var uptime: TimeInterval = 1_000
        private var instant = ContinuousClock.now
        private var boot = UUID().uuidString.lowercased()
        private var advanceContinuousOnWitness = false
        func date() -> Date { lock.withLock { wall } }
        func continuous() -> ContinuousClock.Instant { lock.withLock { instant } }
        func witness() -> MCPFaceScanReviewRequestStore.MonotonicWitness? {
            lock.withLock {
                if advanceContinuousOnWitness {
                    advanceContinuousOnWitness = false
                    instant = instant.advanced(by: .seconds(300))
                }
                return .init(bootSessionID: boot, uptime: uptime)
            }
        }
        func advance(wall seconds: TimeInterval = 0, uptime elapsed: TimeInterval = 0, continuous: TimeInterval = 0) {
            lock.withLock { wall = wall.addingTimeInterval(seconds); uptime += elapsed; instant = instant.advanced(by: .seconds(continuous)) }
        }
        func expireContinuousOnNextWitness() { lock.withLock { advanceContinuousOnWitness = true } }
        func reboot() { lock.withLock { boot = UUID().uuidString.lowercased() } }
    }
    nonisolated private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func read() -> Data? { lock.withLock { data } }
        func write(_ value: Data?) { lock.withLock { data = value } }
    }
    nonisolated private struct Fixture {
        let root: URL
        let clock: Clock
        let authority: MCPAuthorizationStore
        let requests: MCPFaceScanReviewRequestStore
        let intents: MCPFaceScanIntentStore
        let record: MCPFaceScanReviewRequestStore.Record
    }
    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/face-adoption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("image".utf8).write(to: root.appendingPathComponent("image.jpg"))
        let box = Box(), clock = Clock()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(root); try authority.setEnabled(true)
        let admission = MCPFaceScanAdmissionService(authorizationStore: authority)
        let requests = MCPFaceScanReviewRequestStore(storageDirectory: root.appendingPathComponent("requests"),
            clock: { clock.date() }, monotonicWitness: { clock.witness() })
        let record = try requests.request(requestID: UUID(), requestEpoch: requests.capacitySnapshot().epoch,
            arguments: ["path": .string(root.path)], admission: admission)
        let intents = MCPFaceScanIntentStore(admission: admission, clock: { clock.date() },
            monotonicClock: { clock.continuous() }, monotonicWitness: { clock.witness() })
        return Fixture(root: root, clock: clock, authority: authority, requests: requests, intents: intents, record: record)
    }
    @Test("Adoption preserves original identity, options, expiry and reduced lifetime")
    func originalEvidence() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.clock.advance(wall: 120, uptime: 120)
        let intent = try f.intents.adopt(record: f.record, requests: f.requests)
        #expect(intent.createdAt == f.record.intent.preparedAt)
        #expect(intent.expiresAt == f.record.intent.expiresAt)
        #expect(intent.durableRequest?.requestID == f.record.requestID)
        #expect(intent.durableRequest?.requestEpoch == f.record.requestEpoch)
        #expect(intent.durableRequest?.intentSHA256 == f.record.intentSHA256)
        #expect(intent.prepared.snapshotRevision == f.record.intent.snapshotRevision)
        #expect(try f.intents.adopt(record: f.record, requests: f.requests).id == intent.id)
        f.clock.advance(continuous: 180)
        #expect(throws: MCPFaceScanIntentStore.Failure.expiredIntent) { try f.intents.inspect(id: intent.id) }
        #expect(throws: MCPFaceScanIntentStore.Failure.expiredIntent) { try f.intents.adopt(record: f.record, requests: f.requests) }
    }
    @Test("Frozen wall time uses the original boot witness remaining lifetime")
    func frozenWall() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.clock.advance(uptime: 299)
        let intent = try f.intents.adopt(record: f.record, requests: f.requests)
        f.clock.advance(continuous: 1)
        #expect(throws: MCPFaceScanIntentStore.Failure.expiredIntent) { try f.intents.retain(id: intent.id) }
        #expect(throws: MCPFaceScanIntentStore.Failure.expiredIntent) { try f.intents.adopt(record: f.record, requests: f.requests) }
    }
    @Test("Archive verification cannot outlast the local adoption deadline")
    func delayedFreshnessCheck() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let intent = try f.intents.adopt(record: f.record, requests: f.requests)
        // Durable freshness still sees the original wall/boot time, while its
        // witness read models a long archive wait crossing the local deadline.
        f.clock.expireContinuousOnNextWitness()
        #expect(throws: MCPFaceScanIntentStore.Failure.expiredIntent) { try f.intents.inspect(id: intent.id) }
    }
    @Test("Cancellation invalidates adopted lookup and retain without changing durable evidence")
    func cancelled() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let intent = try f.intents.adopt(record: f.record, requests: f.requests)
        let cancelled = try f.requests.cancel(UUID(uuidString: f.record.requestID)!, requestEpoch: UUID(uuidString: f.record.requestEpoch)!)
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.conflictingRequest) { try f.intents.inspect(id: intent.id) }
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.conflictingRequest) { try f.intents.retain(id: intent.id) }
        #expect(try f.requests.records() == [cancelled])
    }
    @Test("Retain recaptures durable inventory and releases its folder reservation")
    func retaining() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let intent = try f.intents.adopt(record: f.record, requests: f.requests)
        let retained = try f.intents.retain(id: intent.id)
        retained.release()
        try Data("second".utf8).write(to: f.root.appendingPathComponent("second.jpg"))
        #expect(throws: MCPFaceScanAdmissionService.Failure.staleSnapshot) { try f.intents.retain(id: intent.id) }
        let lease = try MCPProcessReservation.acquireFolder(f.root)
        lease.release()
        #expect(try f.requests.records() == [f.record])
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".photo_metadata").path))
    }
    @Test("Changed inventory, withdrawn authority and boot change refuse adoption")
    func invalidEvidence() throws {
        for mode in 0..<3 {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            switch mode {
            case 0: try Data("second".utf8).write(to: f.root.appendingPathComponent("second.jpg"))
            case 1: try f.authority.setEnabled(false)
            default: f.clock.reboot()
            }
            #expect(throws: (any Error).self) { try f.intents.adopt(record: f.record, requests: f.requests) }
            #expect(try f.requests.records() == [f.record])
        }
    }
}
