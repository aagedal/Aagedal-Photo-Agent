import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Read-only rooted complete-folder face scan preparation")
struct MCPFaceScanAdmissionServiceTests {
    nonisolated private final class ConfigurationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func read() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
        func write(_ value: Data?) { lock.lock(); defer { lock.unlock() }; data = value }
    }

    private struct Fixture {
        let root: URL
        let authority: MCPAuthorizationStore
        let service: MCPFaceScanAdmissionService
        let photos: [URL]
        var arguments: [String: MCPJSONValue] { ["path": .string(root.path)] }
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/face-scan-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let box = ConfigurationBox()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(root); try authority.setEnabled(true)
        let photos = [root.appendingPathComponent("b-å.JPG"), root.appendingPathComponent("a.jpg")]
        for photo in photos { try Data("disposable image bytes".utf8).write(to: photo) }
        return Fixture(root: root, authority: authority, service: .init(authorizationStore: authority), photos: photos)
    }

    @Test("Preparation is deterministic, complete, and creates no scan or operation data")
    func completeReadOnlySnapshot() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("video".utf8).write(to: f.root.appendingPathComponent("clip.mp4"))
        try Data("hidden".utf8).write(to: f.root.appendingPathComponent(".hidden.jpg"))
        let nested = f.root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: nested.appendingPathComponent("nested.jpg"))
        let before = try f.photos.map { try Data(contentsOf: $0) }
        let prepared = try f.service.prepare(arguments: f.arguments)
        // Foundation standardizes /private/tmp to /tmp when authorizing the folder.
        // Compare the complete ordered paths using the same URL normalization.
        let expectedPhotos = f.photos.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(\.standardizedFileURL)
        #expect(prepared.imageURLs.map(\.standardizedFileURL) == expectedPhotos)
        #expect(prepared.folderURL == f.root.standardizedFileURL)
        #expect(prepared.snapshotRevision.hasPrefix("sha256:"))
        #expect(prepared.snapshotRevision.count == 71)
        #expect(try f.service.revalidate(prepared).snapshotRevision == prepared.snapshotRevision)
        #expect(prepared.protocolValue.objectValue?["photoCount"] == .integer(2))
        #expect(prepared.protocolValue.objectValue?["executionAvailable"] == .bool(false))
        #expect(prepared.protocolValue.objectValue?["mutationAuthorized"] == .bool(false))
        #expect(try f.photos.map { try Data(contentsOf: $0) } == before)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".face_data").path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations").path))
        let serialized = try JSONEncoder().encode(prepared.protocolValue)
        #expect(prepared.protocolValue.objectValue?["canonicalPath"] == .string(f.root.standardizedFileURL.path))
        #expect(prepared.protocolValue.objectValue?["schemaVersion"] == .integer(1))
        #expect(!String(decoding: serialized, as: UTF8.self).contains(f.photos[0].lastPathComponent))
    }

    @Test("Jersey preparation preserves the scanner's full-reset option semantics")
    func normalizedOptions() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var arguments = f.arguments
        arguments["includeJerseyNumbers"] = .bool(true); arguments["forceFullScan"] = .bool(false)
        let prepared = try f.service.prepare(arguments: arguments)
        #expect(prepared.forceFullScan)
        #expect(prepared.includeJerseyNumbers)
        #expect(prepared.snapshotRevision != (try f.service.prepare(arguments: f.arguments)).snapshotRevision)
    }

    @Test("Strict arguments refuse aliases, unknown fields, and nonboolean scan flags", arguments: [
        [String: MCPJSONValue](), ["path": .string("relative")], ["path": .string("/tmp"), "photos": .array([])],
        ["path": .string("/tmp"), "forceFullScan": .integer(1)], ["path": .string("/tmp"), "includeJerseyNumbers": .null]
    ])
    func malformedArguments(arguments: [String: MCPJSONValue]) {
        #expect(throws: MCPFaceScanAdmissionService.Failure.invalidArguments) {
            try MCPFaceScanAdmissionService.Request(arguments: arguments)
        }
    }

    @Test("Unavailable complete inventories refuse without scan state", arguments: ["symbolic", "hardlink", "placeholder", "empty", "file"])
    func invalidInventory(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var arguments = f.arguments
        switch kind {
        case "symbolic": try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("link.jpg"), withDestinationURL: f.photos[0])
        case "hardlink": try FileManager.default.linkItem(at: f.photos[0], to: f.root.appendingPathComponent("copy.jpg"))
        case "placeholder": try Data().write(to: f.root.appendingPathComponent(".pending.JPG.icloud"))
        case "empty": for photo in f.photos { try FileManager.default.removeItem(at: photo) }
        default: arguments["path"] = .string(f.photos[0].path)
        }
        #expect(throws: (any Error).self) { try f.service.prepare(arguments: arguments) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".face_data").path))
    }

    @Test("Captured sessions refuse inventory and authorization drift", arguments: ["add", "remove", "replace", "modify", "disabled", "regrant"])
    func staleSession(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let prepared = try f.service.prepare(arguments: f.arguments)
        switch kind {
        case "add": try Data("new".utf8).write(to: f.root.appendingPathComponent("new.jpg"))
        case "remove": try FileManager.default.removeItem(at: f.photos[0])
        case "replace": try Data("new inode".utf8).write(to: f.photos[0], options: .atomic)
        case "modify": try Data("different byte count".utf8).write(to: f.photos[0])
        case "disabled": try f.authority.setEnabled(false)
        default: try f.authority.setEnabled(false); try f.authority.setEnabled(true)
        }
        #expect(throws: (any Error).self) { try f.service.revalidate(prepared) }
    }

    @Test("Folder preparation cannot overlap a participating photo writer and releases its own reservation")
    func reservations() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.photos[0])
        #expect(throws: MCPProcessReservationError.busy) { try f.service.prepare(arguments: f.arguments) }
        lease.release()
        _ = try f.service.prepare(arguments: f.arguments)
        let next = try MCPProcessReservation.acquirePhoto(f.photos[0]); next.release()
    }

    @Test("Enabled rooted authority is required even for read-only preparation", arguments: ["disabled", "outside", "traversal"])
    func missingAuthority(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var arguments = f.arguments
        switch kind {
        case "disabled": try f.authority.setEnabled(false)
        case "outside": arguments["path"] = .string(f.root.deletingLastPathComponent().path)
        default: arguments["path"] = .string(f.root.path + "/../" + f.root.lastPathComponent)
        }
        #expect(throws: (any Error).self) { try f.service.prepare(arguments: arguments) }
    }

    @Test("Root replacement or folder symlink cannot reuse authority")
    func rootedRefusal() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = f.root.appendingPathExtension("original")
        defer { try? FileManager.default.removeItem(at: original) }
        let prepared = try f.service.prepare(arguments: f.arguments)
        try FileManager.default.moveItem(at: f.root, to: original)
        try FileManager.default.createSymbolicLink(at: f.root, withDestinationURL: original)
        #expect(throws: (any Error).self) { try f.service.revalidate(prepared) }
    }

    @Test("Retained rooted inventory excludes participating writers across suspension")
    func retainedAcrossSuspension() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let prepared = try f.service.prepare(arguments: f.arguments)
        let retained = try f.service.retain(prepared)
        defer { retained.release() }
        await Task.yield()
        try retained.validate()
        #expect(throws: MCPProcessReservationError.busy) { try MCPProcessReservation.acquirePhoto(f.photos[0]) }
        #expect(throws: MCPProcessReservationError.busy) { try MCPProcessReservation.acquireFolder(f.root) }
        #expect(try retained.withValidatedFolder { snapshot, descriptor in
            snapshot.snapshotRevision == prepared.snapshotRevision && descriptor >= 0
        })
        retained.release(); retained.release()
        #expect(throws: MCPFaceScanAdmissionService.Failure.releasedReservation) { try retained.validate() }
        #expect(throws: MCPFaceScanAdmissionService.Failure.releasedReservation) { try retained.checkAuthority() }
        let lease = try MCPProcessReservation.acquirePhoto(f.photos[0]); lease.release()
    }

    @Test("Retained complete inventory refuses drift before a boundary callback", arguments: ["add", "modify", "disabled", "replace-root"])
    func retainedDrift(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let retained = try f.service.retain(f.service.prepare(arguments: f.arguments))
        defer { retained.release() }
        let moved = f.root.appendingPathExtension("original")
        defer { try? FileManager.default.removeItem(at: moved) }
        switch kind {
        case "add": try Data("new".utf8).write(to: f.root.appendingPathComponent("new.jpg"))
        case "modify": try Data("changed image".utf8).write(to: f.photos[0])
        case "disabled": try f.authority.setEnabled(false)
        default:
            try FileManager.default.moveItem(at: f.root, to: moved)
            try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false)
        }
        var invoked = false
        #expect(throws: (any Error).self) {
            try retained.withValidatedFolder { _, _ in invoked = true }
        }
        #expect(!invoked)
    }

    @Test("Boundary completion refuses external input changes instead of reporting success")
    func retainedPostBoundaryDrift() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let retained = try f.service.retain(f.service.prepare(arguments: f.arguments))
        defer { retained.release() }
        #expect(throws: MCPFaceScanAdmissionService.Failure.staleSnapshot) {
            try retained.withValidatedFolder { _, _ in
                try Data("changed input bytes".utf8).write(to: f.photos[0])
            }
        }
    }

    @Test("Failed retained admission and deinitialization release reservations")
    func retainedCleanup() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let prepared = try f.service.prepare(arguments: f.arguments)
        try Data("new".utf8).write(to: f.root.appendingPathComponent("new.jpg"))
        #expect(throws: MCPFaceScanAdmissionService.Failure.staleSnapshot) { try f.service.retain(prepared) }
        let next = try MCPProcessReservation.acquireFolder(f.root); next.release()
        var retained: MCPFaceScanAdmissionService.RetainedFolder? = try f.service.retain(f.service.prepare(arguments: f.arguments))
        #expect(retained != nil)
        retained = nil
        let last = try MCPProcessReservation.acquireFolder(f.root); last.release()
    }

    nonisolated private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        func read() -> Date { lock.withLock { date } }
        func advance(_ interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
    }

    @Test("Immutable session intents bind normalized options and expire without extending on inspection")
    func immutableIntent() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let clock = ClockBox()
        let store = MCPFaceScanIntentStore(admission: f.service, clock: { clock.read() })
        var arguments = f.arguments; arguments["includeJerseyNumbers"] = .bool(true)
        let intent = try store.prepare(arguments: arguments)
        #expect(intent.prepared.forceFullScan)
        #expect(intent.prepared.includeJerseyNumbers)
        #expect(intent.expiresAt.timeIntervalSince(intent.createdAt) == 300)
        clock.advance(299)
        #expect(try store.inspect(id: intent.id).expiresAt == intent.expiresAt)
        let retained = try store.retain(id: intent.id)
        defer { retained.release() }
        clock.advance(1)
        #expect(throws: MCPFaceScanIntentStore.Failure.expiredIntent) { try store.retain(id: intent.id) }
        // Expiry gates admission; original authority remains checked for retained work.
        try retained.validate()
        retained.release()
        #expect(throws: MCPFaceScanIntentStore.Failure.expiredIntent) { try store.inspect(id: intent.id) }
        #expect(throws: MCPFaceScanIntentStore.Failure.unknownIntent) {
            try MCPFaceScanIntentStore(admission: f.service).inspect(id: intent.id)
        }
    }

    @Test("Intent stores bound both entries and total retained photos and prune expired capacity")
    func intentBounds() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let clock = ClockBox()
        let store = MCPFaceScanIntentStore(admission: f.service, maximumIntents: 1, clock: { clock.read() })
        _ = try store.prepare(arguments: f.arguments)
        #expect(throws: MCPFaceScanIntentStore.Failure.capacity) { try store.prepare(arguments: f.arguments) }
        clock.advance(300)
        _ = try store.prepare(arguments: f.arguments)
        #expect(throws: MCPFaceScanIntentStore.Failure.capacity) {
            try MCPFaceScanIntentStore(admission: f.service, maximumRetainedPhotos: 1).prepare(arguments: f.arguments)
        }
        #expect(throws: MCPFaceScanIntentStore.Failure.capacity) {
            try MCPFaceScanIntentStore(admission: f.service, maximumIntents: 0).prepare(arguments: f.arguments)
        }
    }

    @Test("Intents refuse a backwards clock and changed authority before retention")
    func intentRefusals() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let clock = ClockBox()
        let store = MCPFaceScanIntentStore(admission: f.service, clock: { clock.read() })
        let intent = try store.prepare(arguments: f.arguments)
        clock.advance(-1)
        #expect(throws: MCPFaceScanIntentStore.Failure.expiredIntent) { try store.inspect(id: intent.id) }
        clock.advance(1)
        try f.authority.setEnabled(false)
        #expect(throws: (any Error).self) { try store.retain(id: intent.id) }
        let lease = try MCPProcessReservation.acquireFolder(f.root); lease.release()
    }


    @Test("Cancellation refuses retained boundaries and cleanup remains available")
    func retainedCancellation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let retained = try f.service.retain(f.service.prepare(arguments: f.arguments))
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try retained.validate(); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        #expect(await task.value)
        retained.release()
        let lease = try MCPProcessReservation.acquireFolder(f.root); lease.release()
    }

    @Test("Nonfinite intent clocks refuse without retaining a snapshot")
    func invalidIntentClock() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = MCPFaceScanIntentStore(admission: f.service, clock: { Date(timeIntervalSince1970: .nan) })
        #expect(throws: MCPFaceScanIntentStore.Failure.invalidClock) { try store.prepare(arguments: f.arguments) }
        let lease = try MCPProcessReservation.acquireFolder(f.root); lease.release()
    }

}
