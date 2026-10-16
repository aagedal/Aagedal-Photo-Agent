import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Authenticated durable face intent presentation")
struct AutomationNativeFaceScanReviewInvocationServiceTests {
    nonisolated private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private let wall = Date(timeIntervalSince1970: 1_800_000_000)
        private var uptime: TimeInterval = 1_000
        private var boot = UUID().uuidString.lowercased()
        func date() -> Date { wall }
        func witness() -> MCPFaceScanReviewRequestStore.MonotonicWitness? {
            lock.withLock { .init(bootSessionID: boot, uptime: uptime) }
        }
        func advance(_ seconds: TimeInterval) { lock.withLock { uptime += seconds } }
        func reboot() { lock.withLock { boot = UUID().uuidString.lowercased() } }
    }
    nonisolated private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?
        func read() -> Data? { lock.withLock { value } }
        func write(_ data: Data?) { lock.withLock { value = data } }
    }
    nonisolated private struct Fixture {
        let root: URL
        let photo: URL
        let clock: Clock
        let authority: MCPAuthorizationStore
        let requests: MCPFaceScanReviewRequestStore
        let record: MCPFaceScanReviewRequestStore.Record
        var id: UUID { UUID(uuidString: record.requestID)! }
        var epoch: UUID { UUID(uuidString: record.requestEpoch)! }
        func restartedService() -> AutomationNativeFaceScanReviewInvocationService {
            .init(requests: .init(storageDirectory: requests.storageDirectory,
                clock: { clock.date() }, monotonicWitness: { clock.witness() }),
                admission: .init(authorizationStore: authority))
        }
    }
    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/face-invocation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let photo = root.appendingPathComponent("literal-**untrusted**-å.jpg")
        try Data("original photo".utf8).write(to: photo)
        let box = Box(), clock = Clock()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(root); try authority.setEnabled(true)
        let requests = MCPFaceScanReviewRequestStore(storageDirectory: root.appendingPathComponent("requests"),
            clock: { clock.date() }, monotonicWitness: { clock.witness() })
        let record = try requests.request(requestID: UUID(), requestEpoch: requests.capacitySnapshot().epoch,
            arguments: ["path": .string(root.path), "includeJerseyNumbers": .bool(true)],
            admission: .init(authorizationStore: authority))
        return Fixture(root: root, photo: photo, clock: clock, authority: authority, requests: requests, record: record)
    }

    @Test("Relaunch presents exact original options and inventory without changing archive or photos")
    func presentationOnly() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let archive = f.requests.storageDirectory.appendingPathComponent("operations.json")
        let originalArchive = try Data(contentsOf: archive), originalPhoto = try Data(contentsOf: f.photo)
        let service = f.restartedService()
        let selected = try service.invoke(requestID: f.id, requestEpoch: f.epoch)
        #expect(selected.record == f.record)
        #expect(selected.imageURLs == [f.photo.standardizedFileURL])
        #expect(selected.record.intent.forceFullScan && selected.record.intent.includeJerseyNumbers)
        #expect(try service.revalidate(selected) == selected)
        #expect(try Data(contentsOf: archive) == originalArchive)
        #expect(try Data(contentsOf: f.photo) == originalPhoto)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".photo_metadata").path))
    }

    @Test("Opening again and relaunch cannot renew original monotonic deadline with frozen wall clock")
    func originalDeadline() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let selected = try f.restartedService().invoke(requestID: f.id, requestEpoch: f.epoch)
        f.clock.advance(299)
        #expect(try f.restartedService().revalidate(selected).record == f.record)
        f.clock.advance(1)
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.expiredRequest) {
            try f.restartedService().requireFreshForPublication(selected)
        }
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.expiredRequest) {
            try f.restartedService().revalidate(selected)
        }
        #expect(try f.requests.inspect(f.id, requestEpoch: f.epoch) == f.record)
    }

    @Test("Changes during the UI handoff fail closed", arguments: ["cancel", "photo", "inventory", "authority", "boot"])
    func changedHandoff(_ change: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.restartedService()
        let selected = try service.invoke(requestID: f.id, requestEpoch: f.epoch)
        switch change {
        case "cancel": _ = try f.requests.cancel(f.id, requestEpoch: f.epoch)
        case "photo": try Data("changed photo bytes".utf8).write(to: f.photo)
        case "inventory": try Data("new".utf8).write(to: f.root.appendingPathComponent("new.jpg"))
        case "authority": try f.authority.setEnabled(false)
        default: f.clock.reboot()
        }
        #expect(throws: (any Error).self) { try service.revalidate(selected) }
    }

    @Test("Stale epochs and unrelated handles cannot present face intent")
    func wrongHandles() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.staleEpoch) {
            try f.restartedService().invoke(requestID: f.id, requestEpoch: UUID())
        }
        #expect(throws: MCPFaceScanReviewRequestStore.Failure.unknownRequest) {
            try f.restartedService().invoke(requestID: UUID(), requestEpoch: f.epoch)
        }
    }

    @MainActor @Test("Timeout retires delayed face publication")
    func delayedPublication() {
        let handoff = AutomationNativeInvocationController.ExecutionHandoff()
        #expect(!handoff.wait(timeout: 0))
        var published = false
        handoff.resolve { published = true; return true }
        #expect(!published)
    }

    @MainActor @Test("Timed-out validation retains its in-flight slot until it drains")
    func boundedPresentation() {
        let gate = AutomationNativeInvocationController.FacePresentationGate()
        #expect(gate.acquire())
        let handoff = AutomationNativeInvocationController.ExecutionHandoff()
        #expect(!handoff.wait(timeout: 0))
        #expect(!gate.acquire())
        gate.release()
        #expect(gate.acquire())
        gate.release()
    }
}
