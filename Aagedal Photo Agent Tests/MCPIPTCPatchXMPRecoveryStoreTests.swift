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

    @Test("Publication recovery preserves exact app history and operation/approval identities", arguments: [false, true])
    func appHistory(absent: Bool) throws {
        let fixture = try Fixture()
        let operationID = UUID(), approvalID = UUID()
        let original = absent ? nil : Data([0, 128, 255])
        let material = try fixture.store.stage(id: operationID, planID: "plan", targetPath: "/test.xmp",
            binding: fixture.binding, original: nil, candidate: Data("candidate".utf8),
            appSidecarRecovery: .init(original: original), publicationApprovalID: approvalID)
        let reopened = try #require(try fixture.store.load())
        #expect(reopened == material)
        #expect(reopened.id == operationID)
        #expect(reopened.publicationApprovalID == approvalID)
        #expect(try #require(reopened.appSidecarRecovery).original == original)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.occupied) {
            try fixture.store.stage(id: operationID, planID: "plan", targetPath: "/test.xmp",
                binding: fixture.binding, original: nil, candidate: Data("candidate".utf8),
                appSidecarRecovery: .init(original: original), publicationApprovalID: UUID())
        }
    }

    @Test("Reconciliation bytes survive reopening and cannot be replaced by the same operation")
    func reconciliation() throws {
        let fixture = try Fixture()
        let material = try fixture.store.stage(id: UUID(), planID: "plan", targetPath: "/test.xmp",
            binding: fixture.binding, original: nil, candidate: Data("xmp".utf8),
            appSidecarRecovery: .init(original: nil, candidate: Data("history".utf8)), publicationApprovalID: UUID())
        #expect(try fixture.store.load() == material)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.occupied) {
            try fixture.store.stage(id: material.id, planID: material.planID, targetPath: material.targetPath,
                binding: material.binding, original: material.original, candidate: material.candidate,
                appSidecarRecovery: .init(original: nil, candidate: Data("replacement".utf8)),
                publicationApprovalID: material.publicationApprovalID)
        }
        #expect(try fixture.store.load() == material)
    }

    @Test("Verified disposition survives reopening, rejects replay and admits the next operation")
    func verifiedDisposition() throws {
        let fixture = try Fixture()
        let material = try fixture.store.stage(id: UUID(), planID: "plan", targetPath: "/test.xmp",
            binding: fixture.binding, original: nil, candidate: Data("xmp".utf8),
            appSidecarRecovery: .init(original: nil, candidate: Data("history".utf8)), publicationApprovalID: UUID())
        try fixture.store.recordVerified(material, verify: {})
        #expect(try fixture.store.load() == nil)
        #expect(try fixture.store.loadVerifiedDisposition()?.material == material)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.occupied) {
            try fixture.store.stage(id: material.id, planID: material.planID, targetPath: material.targetPath,
                binding: material.binding, original: material.original, candidate: material.candidate,
                appSidecarRecovery: material.appSidecarRecovery, publicationApprovalID: material.publicationApprovalID)
        }
        let next = try fixture.stage()
        #expect(try fixture.store.load() == next)
        #expect(try fixture.store.loadVerifiedDisposition() == nil)
    }

    @Test("Failed verification or mismatched material cannot resolve retained recovery")
    func dispositionRefusal() throws {
        let fixture = try Fixture()
        let material = try fixture.store.stage(id: UUID(), planID: "plan", targetPath: "/test.xmp",
            binding: fixture.binding, original: nil, candidate: Data("xmp".utf8),
            appSidecarRecovery: .init(original: nil, candidate: Data("history".utf8)), publicationApprovalID: UUID())
        let bytes = try Data(contentsOf: fixture.journal)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.verification) {
            try fixture.store.recordVerified(material) { throw MCPIPTCPatchXMPRecoveryStore.Failure.verification }
        }
        let mismatched = MCPIPTCPatchXMPRecoveryStore.Material(id: UUID(), planID: material.planID,
            targetPath: material.targetPath, binding: material.binding, original: material.original,
            candidate: material.candidate, appSidecarRecovery: material.appSidecarRecovery,
            publicationApprovalID: material.publicationApprovalID)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.verification) {
            try fixture.store.recordVerified(mismatched, verify: {})
        }
        #expect(try Data(contentsOf: fixture.journal) == bytes)
        #expect(try fixture.store.load() == material)
        #expect(try fixture.store.loadVerifiedDisposition() == nil)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.occupied) { try fixture.stage() }
    }

    @Test("App history and publication consent bindings cannot be partially supplied")
    func partialPublicationBinding() throws {
        let fixture = try Fixture()
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.invalidArguments) {
            try fixture.store.stage(id: UUID(), planID: "plan", targetPath: "/test.xmp", binding: fixture.binding,
                original: nil, candidate: Data("candidate".utf8), appSidecarRecovery: .init(original: nil))
        }
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.invalidArguments) {
            try fixture.store.stage(id: UUID(), planID: "plan", targetPath: "/test.xmp", binding: fixture.binding,
                original: nil, candidate: Data("candidate".utf8), publicationApprovalID: UUID())
        }
        #expect(try fixture.store.load() == nil)
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

    @Test("Changing only the envelope version cannot turn unresolved recovery into completion")
    func forgedDispositionVersion() throws {
        let fixture = try Fixture()
        _ = try fixture.store.stage(id: UUID(), planID: "plan", targetPath: "/test.xmp",
            binding: fixture.binding, original: nil, candidate: Data("xmp".utf8),
            appSidecarRecovery: .init(original: nil, candidate: Data("history".utf8)), publicationApprovalID: UUID())
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.journal)) as? [String: Any])
        envelope["version"] = 4
        let corrupt = try JSONSerialization.data(withJSONObject: envelope)
        try corrupt.write(to: fixture.journal)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.corruptJournal) { try fixture.store.load() }
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.corruptJournal) { try fixture.store.loadVerifiedDisposition() }
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
