import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Durable XMP recovery material without live publication")
struct MCPIPTCPatchXMPRecoveryStoreTests {
    private final class Fixture {
        let root: URL
        init() throws {
            let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(canonical) }
            root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
                .appendingPathComponent("xmp-recovery-test-\(UUID().uuidString)")
        }
        var store: MCPIPTCPatchXMPRecoveryStore { .init(directory: root) }
        var journal: URL { root.appendingPathComponent("iptc-xmp-recovery/operations.json") }
        let binding = MCPIPTCPatchXMPRecoveryStore.Binding(sourceRevision: "source", xmpSidecarRevision: "xmp",
            appSidecarRevision: "app", authorizationRevision: UUID())
        func stage(id: UUID = UUID(), original: Data? = Data([0, 1, 255])) throws -> MCPIPTCPatchXMPRecoveryStore.Material {
            try store.stage(id: id, planID: "plan", targetPath: root.appendingPathComponent("never-created.xmp").path,
                binding: binding, original: original, candidate: Data("candidate".utf8))
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test("Reopening retains exact binary originals and never creates a live sidecar", arguments: [false, true])
    func reopen(missing: Bool) throws {
        let fixture = try Fixture()
        #expect(try fixture.store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
        let material = try fixture.stage(original: missing ? nil : Data([0, 1, 255]))
        #expect(try fixture.store.load() == material)
        #expect(!FileManager.default.fileExists(atPath: material.targetPath))
        #expect(MCPIPTCPatchXMPRecoveryStore.observe(material.original, for: material) == .originalPresent)
        #expect(MCPIPTCPatchXMPRecoveryStore.observe(material.candidate, for: material) == .candidatePresent)
        #expect(MCPIPTCPatchXMPRecoveryStore.observe(Data("external edit".utf8), for: material) == .conflict)
    }

    @Test("Only the identical operation is idempotent; all recovery bytes survive refused replacement")
    func occupied() throws {
        let fixture = try Fixture()
        let material = try fixture.stage()
        let journal = try Data(contentsOf: fixture.journal)
        #expect(try fixture.stage(id: material.id) == material)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.occupied) { try fixture.stage() }
        let changed = MCPIPTCPatchXMPRecoveryStore.Binding(sourceRevision: "source", xmpSidecarRevision: "xmp",
            appSidecarRevision: "app", authorizationRevision: UUID())
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.occupied) {
            try fixture.store.stage(id: material.id, planID: material.planID, targetPath: material.targetPath,
                binding: changed, original: material.original, candidate: material.candidate)
        }
        #expect(try Data(contentsOf: fixture.journal) == journal)
    }

    @Test("Corrupt or unsupported journals fail closed and cannot be overwritten", arguments: [1, 99])
    func corruption(version: Int) throws {
        let fixture = try Fixture()
        _ = try fixture.stage()
        let corrupt = try JSONSerialization.data(withJSONObject: ["version": version, "payload": "AA==", "sha256": "bad"])
        try corrupt.write(to: fixture.journal)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.corruptJournal) { try fixture.store.load() }
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.corruptJournal) { try fixture.stage() }
        #expect(try Data(contentsOf: fixture.journal) == corrupt)
    }

    @Test("Directory durability failure refuses publication and retry syncs existing ancestors")
    func directorySyncFailure() throws {
        let fixture = try Fixture()
        let directory = fixture.root.appendingPathComponent("nested/journal")
        // Pre-existing directories can be left by an interrupted first-use admission.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let refused = AutomationOperationPersistence(directory: directory, maximumBytes: 1024,
            syncDirectoryParent: { _ in -1 })
        #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
            try refused.transaction { _ in ((), Data("never published".utf8)) }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("operations.json").path))
        // Read-only missing-journal inspection never needs a flush or creates a lock.
        // An existing directory without a lock refuses instead of creating storage.
        #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
            try refused.transaction(readOnly: true) { _ in ((), Data()) }
        }
        let admitted = AutomationOperationPersistence(directory: directory, maximumBytes: 1024)
        try admitted.transaction { _ in ((), Data("durable".utf8)) }
        // Even a failure-injected reader succeeds once the journal exists: reads do not sync.
        let bytes = try refused.transaction(readOnly: true) { ($0, $0 ?? Data()) }
        #expect(bytes == Data("durable".utf8))
    }

    @Test("Carrier limits reject before creating recovery storage")
    func bounded() throws {
        let fixture = try Fixture()
        let store = MCPIPTCPatchXMPRecoveryStore(directory: fixture.root, maximumCarrierBytes: 2)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.invalidArguments) {
            try store.stage(id: UUID(), planID: "plan", targetPath: "/test.xmp", binding: fixture.binding,
                original: nil, candidate: Data([1, 2, 3]))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test("Symlink substitution of the journal cannot redirect recovery reads or staging")
    func symlink() throws {
        let fixture = try Fixture()
        _ = try fixture.stage()
        let backup = fixture.root.appendingPathComponent("untouched")
        try FileManager.default.moveItem(at: fixture.journal, to: backup)
        let original = try Data(contentsOf: backup)
        try FileManager.default.createSymbolicLink(at: fixture.journal, withDestinationURL: backup)
        #expect(throws: (any Error).self) { try fixture.store.load() }
        #expect(throws: (any Error).self) { try fixture.stage() }
        #expect(try Data(contentsOf: backup) == original)
    }
}
