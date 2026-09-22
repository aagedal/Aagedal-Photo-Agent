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

    @Test("Changing an unchanged receipt version cannot claim verified publication")
    func unchangedReceiptVersion() throws {
        let fixture = try Fixture()
        let material = try fixture.store.stage(id: UUID(), planID: "plan", targetPath: "/test.xmp",
            binding: fixture.binding, original: nil, candidate: Data("xmp".utf8),
            appSidecarRecovery: .init(original: nil, candidate: Data("history".utf8)), publicationApprovalID: UUID())
        try fixture.store.recordUnchanged(material, verify: {})
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.journal)) as? [String: Any])
        envelope["version"] = 4
        try JSONSerialization.data(withJSONObject: envelope).write(to: fixture.journal)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.corruptJournal) { try fixture.store.loadVerifiedDisposition() }
    }

    @Test("Installed identity progression survives reopen and refuses rollback or mismatched generations")
    func installedIdentities() throws {
        let fixture = try Fixture()
        let material = try fixture.store.stage(id: UUID(), planID: "plan", targetPath: "/test.xmp",
            binding: fixture.binding, original: nil, candidate: Data("xmp".utf8),
            appSidecarRecovery: .init(original: nil, candidate: Data("history".utf8)), publicationApprovalID: UUID())
        let xmp = MCPIPTCPatchXMPRecoveryStore.InstalledCarriers(xmpRevision: "installed-xmp", appRevision: nil)
        let both = MCPIPTCPatchXMPRecoveryStore.InstalledCarriers(xmpRevision: "installed-xmp", appRevision: "installed-app")
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.verification) {
            try fixture.store.recordInstalled(material, installed: both, verify: {})
        }
        try fixture.store.recordInstalled(material, installed: xmp, verify: {})
        #expect(try fixture.store.load() == material)
        #expect(try fixture.store.loadInstalledCarriers() == xmp)
        let before = try Data(contentsOf: fixture.journal)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.verification) {
            try fixture.store.recordInstalled(material, installed: both) { throw MCPIPTCPatchXMPRecoveryStore.Failure.verification }
        }
        #expect(try Data(contentsOf: fixture.journal) == before)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.verification) {
            try fixture.store.recordUnchanged(material, verify: {})
        }
        try fixture.store.recordInstalled(material, installed: both, verify: {})
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.verification) {
            try fixture.store.recordInstalled(material, installed: xmp, verify: {})
        }
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.verification) {
            try fixture.store.recordInstalled(material, installed: .init(xmpRevision: "substituted", appRevision: "installed-app"), verify: {})
        }
        try fixture.store.recordVerified(material, verify: {})
        #expect(try fixture.store.loadVerifiedDisposition()?.installed == both)
        #expect(try fixture.store.load() == nil)
    }

    @Test("Changing an incomplete receipt envelope cannot claim completion")
    func incompleteReceiptVersion() throws {
        let fixture = try Fixture()
        let material = try fixture.store.stage(id: UUID(), planID: "plan", targetPath: "/test.xmp",
            binding: fixture.binding, original: nil, candidate: Data("xmp".utf8),
            appSidecarRecovery: .init(original: nil, candidate: Data("history".utf8)), publicationApprovalID: UUID())
        try fixture.store.recordInstalled(material, installed: .init(xmpRevision: "installed", appRevision: nil), verify: {})
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.journal)) as? [String: Any])
        envelope["version"] = 4
        try JSONSerialization.data(withJSONObject: envelope).write(to: fixture.journal)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.corruptJournal) { try fixture.store.loadVerifiedDisposition() }
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

    @Test("Restoration progress is monotonic and cannot be relabeled as publication or completion", arguments: [4, 5, 6, 8])
    func restorationProgressVersion(version: Int) throws {
        let fixture = try Fixture()
        let material = try fixture.store.stage(id: UUID(), planID: "plan", targetPath: "/test.xmp",
            binding: fixture.binding, original: nil, candidate: Data("xmp".utf8),
            appSidecarRecovery: .init(original: nil, candidate: Data("history".utf8)), publicationApprovalID: UUID())
        let installed = MCPIPTCPatchXMPRecoveryStore.InstalledCarriers(xmpRevision: "installed-xmp", appRevision: nil)
        try fixture.store.recordInstalled(material, installed: installed, verify: {})
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.verification) {
            try fixture.store.recordRestored(material, restored: .init(xmpRevision: "restored", appRevision: "app"), complete: true, verify: {})
        }
        try fixture.store.recordRestored(material, restored: .init(xmpRevision: "restored", appRevision: nil), verify: {})
        let retained = try Data(contentsOf: fixture.journal)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.verification) {
            try fixture.store.recordRestored(material, restored: .init(xmpRevision: "different", appRevision: nil), verify: {})
        }
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.verification) {
            try fixture.store.recordInstalled(material, installed: installed, verify: {})
        }
        #expect(try Data(contentsOf: fixture.journal) == retained)
        var envelope = try #require(JSONSerialization.jsonObject(with: retained) as? [String: Any])
        envelope["version"] = version
        try JSONSerialization.data(withJSONObject: envelope).write(to: fixture.journal)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.corruptJournal) { try fixture.store.loadRecoveryState() }
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.corruptJournal) { try fixture.store.loadRestoredDisposition() }
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

@Suite("Native unchanged XMP staging disposition")
struct MCPIPTCPatchXMPRecoveryServiceTests {
    private typealias Fixture = MCPIPTCPatchXMPPreflightServiceTests.Fixture

    private func recoveryDirectory(_ fixture: Fixture) throws -> URL {
        // Snapshot photo URLs can use Foundation's /var spelling. Recovery persistence
        // requires the real /private/var ancestor chain because it uses O_NOFOLLOW.
        let canonical = try #require(realpath(fixture.root.path, nil))
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("recovery", isDirectory: true)
    }

    private func staged(_ fixture: Fixture, legacy: Bool = false) throws
        -> (MCPIPTCPatchXMPRecoveryStore, MCPIPTCPatchXMPRecoveryStore.Material) {
        let snapshot = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        let store = MCPIPTCPatchXMPRecoveryStore(directory: try recoveryDirectory(fixture))
        let material = try store.stage(id: UUID(), planID: fixture.planID,
            targetPath: snapshot.target.url.deletingPathExtension().appendingPathExtension("xmp").path,
            binding: .init(sourceRevision: snapshot.sourceRevision, xmpSidecarRevision: snapshot.xmpSidecarRevision,
                appSidecarRevision: snapshot.appSidecarRevision,
                authorizationRevision: try #require(try fixture.facade.authorizationStore.load().authorizationRevision)),
            original: snapshot.xmpBytes, candidate: Data("candidate".utf8),
            appSidecarRecovery: .init(original: snapshot.appSidecarBytes, candidate: Data(#"{"sourceFile":"photo.jpg","schemaVersion":1,"pendingChanges":false}"#.utf8)),
            publicationApprovalID: UUID(), sourcePath: legacy ? nil : snapshot.target.url.path)
        return (store, material)
    }

    private func partiallyPublished(_ fixture: Fixture, installApp: Bool) throws
        -> (MCPIPTCPatchXMPRecoveryStore, MCPIPTCPatchXMPRecoveryStore.Material) {
        let (store, material) = try staged(fixture)
        let lease = try MCPProcessReservation.acquirePhoto(fixture.photo)
        defer { lease.release() }
        let original = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path, reservation: lease) { $0 }
        try fixture.facade.installXMPSidecar(data: material.candidate, expected: original, reservation: lease,
            afterInstall: { after in
                try store.recordInstalled(material, installed: .init(xmpRevision: after.xmpSidecarRevision, appRevision: nil), verify: {})
            })
        if installApp {
            let current = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path, reservation: lease) { $0 }
            try fixture.facade.installPendingDraft(data: try #require(material.appSidecarRecovery?.candidate), expected: current,
                reservation: lease, afterInstall: { after in
                    try store.recordInstalled(material, installed: .init(xmpRevision: after.xmpSidecarRevision,
                        appRevision: after.appSidecarRevision), verify: {})
                })
        }
        return (store, material)
    }

    @Test("Explicit internal restoration returns exact originals and records a separate disposition",
        arguments: [false, true], [false, true])
    func restoresPartialPublication(originalsPresent: Bool, installApp: Bool) async throws {
        let fixture = try Fixture(pending: originalsPresent, existingXMP: originalsPresent)
        let original = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        let (store, material) = try partiallyPublished(fixture, installApp: installApp)
        let service = MCPIPTCPatchXMPRecoveryService(recovery: store, facade: fixture.facade)
        let review = try #require(try service.inspect())
        #expect(review.canRestorePartialPublication)
        #expect(!review.canResolveUnchanged)
        try await service.restorePartialPublication(review)
        let after = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(after.sourceRevision == original.sourceRevision)
        #expect(after.xmpBytes == original.xmpBytes)
        #expect(after.appSidecarBytes == original.appSidecarBytes)
        #expect(try store.load() == nil)
        #expect(try store.loadRestoredDisposition() == material)
        #expect(try store.loadVerifiedDisposition() == nil)
        #expect(try store.loadUnchangedDisposition() == nil)
        await #expect(throws: (any Error).self) { try await service.restorePartialPublication(review) }
    }

    @Test("Restoration recreates an originally empty XMP file rather than removing it", arguments: [false, true])
    func restoresEmptyXMP(installApp: Bool) async throws {
        let fixture = try Fixture(existingXMP: false)
        let xmp = fixture.photo.deletingPathExtension().appendingPathExtension("xmp")
        try Data().write(to: xmp)
        let original = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(original.xmpBytes == Data())
        let (store, material) = try partiallyPublished(fixture, installApp: installApp)
        #expect(material.original == Data())
        let service = MCPIPTCPatchXMPRecoveryService(recovery: store, facade: fixture.facade)
        let review = try #require(try service.inspect())
        #expect(review.canRestorePartialPublication)
        try await service.restorePartialPublication(review)
        let after = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(FileManager.default.fileExists(atPath: xmp.path))
        #expect(after.xmpBytes == Data())
        #expect(after.xmpSidecarRevision != original.xmpSidecarRevision)
        #expect(after.appSidecarBytes == original.appSidecarBytes)
        #expect(try store.loadRestoredDisposition() == material)
    }

    @Test("Restoration resumes from an empty-XMP receipt after reopening")
    func resumesEmptyXMP() async throws {
        let fixture = try Fixture(existingXMP: false)
        let xmp = fixture.photo.deletingPathExtension().appendingPathExtension("xmp")
        try Data().write(to: xmp)
        let (store, material) = try partiallyPublished(fixture, installApp: true)
        do {
            let lease = try MCPProcessReservation.acquirePhoto(fixture.photo)
            defer { lease.release() }
            let current = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path, reservation: lease) { $0 }
            #expect(throws: (any Error).self) {
                try fixture.facade.installXMPSidecar(data: Data(), expected: current, reservation: lease)
            }
            try fixture.facade.installXMPSidecar(data: Data(), expected: current, reservation: lease,
                restoringEmptyOriginal: true, afterInstall: { after in
                    try store.recordRestored(material, restored: .init(xmpRevision: after.xmpSidecarRevision, appRevision: nil), verify: {})
                })
        }
        let reopened = MCPIPTCPatchXMPRecoveryStore(directory: try recoveryDirectory(fixture))
        let service = MCPIPTCPatchXMPRecoveryService(recovery: reopened, facade: fixture.facade)
        let review = try #require(try service.inspect())
        #expect(review.canRestorePartialPublication)
        try await service.restorePartialPublication(review)
        #expect(FileManager.default.fileExists(atPath: xmp.path))
        #expect(try Data(contentsOf: xmp).isEmpty)
        #expect(try reopened.loadRestoredDisposition() == material)
    }

    @Test("Restoration resumes from a durable XMP receipt and blocks publication receipt replay")
    func resumesRestoration() async throws {
        let fixture = try Fixture(pending: true)
        let (store, material) = try partiallyPublished(fixture, installApp: true)
        let installed = try #require(try store.loadInstalledCarriers())
        let lease = try MCPProcessReservation.acquirePhoto(fixture.photo)
        let current = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path, reservation: lease) { $0 }
        try fixture.facade.installXMPSidecar(data: try #require(material.original), expected: current, reservation: lease,
            afterInstall: { after in
                try store.recordRestored(material, restored: .init(xmpRevision: after.xmpSidecarRevision, appRevision: nil), verify: {})
            })
        lease.release()
        #expect(throws: (any Error).self) { try store.recordInstalled(material, installed: installed, verify: {}) }
        #expect(throws: (any Error).self) { try store.recordVerified(material, verify: {}) }
        let reopened = MCPIPTCPatchXMPRecoveryStore(directory: try recoveryDirectory(fixture))
        let service = MCPIPTCPatchXMPRecoveryService(recovery: reopened, facade: fixture.facade)
        let restoredXMP = try #require(try reopened.loadRecoveryState()?.restored?.xmpRevision)
        let review = try #require(try service.inspect())
        #expect(review.canRestorePartialPublication)
        try await service.restorePartialPublication(review)
        #expect(try reopened.loadRestoredDisposition() == material)
        let after = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(after.xmpSidecarRevision == restoredXMP)
    }

    @Test("Restoration interrupted before its durable receipt remains blocked")
    func unreceiptedRestoration() throws {
        let fixture = try Fixture()
        let (store, material) = try partiallyPublished(fixture, installApp: false)
        let lease = try MCPProcessReservation.acquirePhoto(fixture.photo)
        let current = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path, reservation: lease) { $0 }
        try fixture.facade.installXMPSidecar(data: try #require(material.original), expected: current, reservation: lease)
        lease.release()
        let service = MCPIPTCPatchXMPRecoveryService(recovery: store, facade: fixture.facade)
        let review = try #require(try service.inspect())
        #expect(!review.canRestorePartialPublication)
        #expect(!review.canResolveUnchanged)
        #expect(try store.load() == material)
    }

    @Test("Restoration refuses external same-byte replacements after review")
    func refusesStaleRestoration() async throws {
        let fixture = try Fixture()
        let (store, material) = try partiallyPublished(fixture, installApp: true)
        let service = MCPIPTCPatchXMPRecoveryService(recovery: store, facade: fixture.facade)
        let review = try #require(try service.inspect())
        try material.candidate.write(to: URL(fileURLWithPath: material.targetPath), options: .atomic)
        await #expect(throws: (any Error).self) { try await service.restorePartialPublication(review) }
        #expect(try #require(try service.inspect()).canRestorePartialPublication == false)
        #expect(try store.load() == material)
    }

    @Test("Unchanged resolution retains a distinct receipt and never reports publication", arguments: [false, true])
    func unchanged(missing: Bool) async throws {
        let fixture = try Fixture(existingXMP: !missing)
        let (store, material) = try staged(fixture)
        let service = MCPIPTCPatchXMPRecoveryService(recovery: store, facade: fixture.facade)
        let before = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        let review = try #require(try service.inspect())
        #expect(review.canResolveUnchanged)
        try await service.resolveUnchanged(review)
        let after = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(before.sourceRevision == after.sourceRevision)
        #expect(before.xmpSidecarRevision == after.xmpSidecarRevision)
        #expect(before.appSidecarRevision == after.appSidecarRevision)
        #expect(try store.load() == nil)
        #expect(try store.loadVerifiedDisposition() == nil)
        #expect(try store.loadUnchangedDisposition()?.material == material)
        await #expect(throws: (any Error).self) { try await service.resolveUnchanged(review) }
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.occupied) {
            try store.stage(id: material.id, planID: material.planID, targetPath: material.targetPath,
                binding: material.binding, original: material.original, candidate: material.candidate,
                appSidecarRecovery: material.appSidecarRecovery, publicationApprovalID: material.publicationApprovalID,
                sourcePath: material.sourcePath)
        }
        _ = try store.stage(id: UUID(), planID: material.planID, targetPath: material.targetPath,
            binding: material.binding, original: material.original, candidate: material.candidate)
        #expect(try store.load() != nil)
    }

    @Test("Changed carrier or same-byte inode replacement preserves unresolved material",
        arguments: [false, true], ["xmp", "source", "app"])
    func changed(sameBytes: Bool, carrier: String) async throws {
        let fixture = try Fixture(pending: true)
        let (store, material) = try staged(fixture)
        let service = MCPIPTCPatchXMPRecoveryService(recovery: store, facade: fixture.facade)
        let review = try #require(try service.inspect())
        let target: URL
        switch carrier {
        case "source": target = fixture.photo
        case "app": target = fixture.root.appendingPathComponent(".photo_metadata/photo.jpg.meta.json")
        default: target = URL(fileURLWithPath: material.targetPath)
        }
        let bytes = sameBytes ? try Data(contentsOf: target) : material.candidate
        try bytes.write(to: target, options: .atomic)
        await #expect(throws: (any Error).self) { try await service.resolveUnchanged(review) }
        if let refreshed = try? service.inspect() { #expect(!refreshed.canResolveUnchanged) }
        #expect(try store.load() == material)
        #expect(try store.loadUnchangedDisposition() == nil)
    }

    @Test("Revoked and regranted authority invalidates an otherwise unchanged review")
    func authority() async throws {
        let fixture = try Fixture()
        let (store, material) = try staged(fixture)
        let service = MCPIPTCPatchXMPRecoveryService(recovery: store, facade: fixture.facade)
        let review = try #require(try service.inspect())
        try fixture.facade.authorizationStore.setEnabled(false)
        try fixture.facade.authorizationStore.setEnabled(true)
        await #expect(throws: (any Error).self) { try await service.resolveUnchanged(review) }
        #expect(try #require(try service.inspect()).canResolveUnchanged == false)
        #expect(try store.load() == material)
    }

    @Test("Legacy source-less records require an explicit correct photo path")
    func legacy() async throws {
        let fixture = try Fixture()
        let (store, material) = try staged(fixture, legacy: true)
        let service = MCPIPTCPatchXMPRecoveryService(recovery: store, facade: fixture.facade)
        #expect(throws: (any Error).self) { try service.inspect() }
        let review = try #require(try service.inspect(photoPath: fixture.photo.path))
        #expect(review.canResolveUnchanged)
        try await service.resolveUnchanged(review)
        #expect(try store.loadUnchangedDisposition()?.material == material)
    }

    @Test("Failed disposition verification preserves the exact journal")
    func verificationFailure() throws {
        let fixture = try Fixture()
        let (store, material) = try staged(fixture)
        #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.verification) {
            try store.recordUnchanged(material) { throw MCPIPTCPatchXMPRecoveryStore.Failure.verification }
        }
        #expect(try store.load() == material)
        #expect(try store.loadUnchangedDisposition() == nil)
    }
    @MainActor
    @Test("Native recovery model resolves inspected unchanged staging through production service")
    func nativeModel() async throws {
        let fixture = try Fixture()
        let (store, material) = try staged(fixture)
        let service = AutomationPatchReviewService(plans: fixture.plans,
            facade: fixture.facade, recoveryDirectory: try recoveryDirectory(fixture))
        let directReview = try await service.inspectRecovery(photoPath: nil)
        #expect(directReview?.materialID == material.id)
        let model = AutomationRecoveryModel(service: service)
        await model.inspect()
        #expect(model.review?.materialID == material.id)
        #expect(model.review?.canResolveUnchanged == true)
        await model.resolveUnchanged()
        #expect(model.review == nil)
        #expect(!model.isLoading)
        #expect(model.message?.contains("Unchanged staging resolved") == true)
        #expect(try store.loadUnchangedDisposition()?.material == material)
    }

    @MainActor
    @Test("Native failed stale resolution clears approval and retains recovery")
    func nativeStaleModel() async throws {
        let fixture = try Fixture()
        let (store, material) = try staged(fixture)
        let service = AutomationPatchReviewService(plans: fixture.plans,
            facade: fixture.facade, recoveryDirectory: try recoveryDirectory(fixture))
        let directReview = try await service.inspectRecovery(photoPath: nil)
        #expect(directReview?.materialID == material.id)
        let model = AutomationRecoveryModel(service: service)
        await model.inspect()
        #expect(model.review?.canResolveUnchanged == true)
        try material.candidate.write(to: URL(fileURLWithPath: material.targetPath), options: .atomic)
        await model.resolveUnchanged()
        #expect(model.review == nil)
        #expect(!model.isLoading)
        #expect(model.message?.contains("could not be resolved") == true)
        #expect(try store.load() == material)
    }

    private actor DelayedInspection: AutomationRecoveryServing {
        let result: MCPIPTCPatchXMPRecoveryService.Review
        private var pending: CheckedContinuation<MCPIPTCPatchXMPRecoveryService.Review?, Never>?
        private var started: CheckedContinuation<Void, Never>?
        init(result: MCPIPTCPatchXMPRecoveryService.Review) { self.result = result }
        func inspectRecovery(photoPath: String?) async throws -> MCPIPTCPatchXMPRecoveryService.Review? {
            await withCheckedContinuation { continuation in
                pending = continuation
                started?.resume(); started = nil
            }
        }
        func resolveUnchangedRecovery(_ review: MCPIPTCPatchXMPRecoveryService.Review) async throws {}
        func waitUntilStarted() async {
            if pending != nil { return }
            await withCheckedContinuation { started = $0 }
        }
        func complete() { pending?.resume(returning: result); pending = nil }
    }

    @MainActor
    @Test("Clearing native recovery suppresses a late inspection result")
    func nativeClear() async throws {
        let fixture = try Fixture()
        let (store, _) = try staged(fixture)
        let review = try #require(try MCPIPTCPatchXMPRecoveryService(recovery: store, facade: fixture.facade).inspect())
        let delayed = DelayedInspection(result: review)
        let model = AutomationRecoveryModel(service: delayed)
        let task = Task { await model.inspect() }
        await delayed.waitUntilStarted()
        model.clear()
        await delayed.complete()
        await task.value
        #expect(model.review == nil)
        #expect(model.message == nil)
        #expect(!model.isLoading)
        #expect(try store.load() != nil)
    }

    private actor DelayedResolution: AutomationRecoveryServing {
        let result: MCPIPTCPatchXMPRecoveryService.Review
        private var pending: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        private(set) var observedCancellation = false
        init(result: MCPIPTCPatchXMPRecoveryService.Review) { self.result = result }
        func inspectRecovery(photoPath: String?) async throws -> MCPIPTCPatchXMPRecoveryService.Review? { result }
        func resolveUnchangedRecovery(_ review: MCPIPTCPatchXMPRecoveryService.Review) async throws {
            await withCheckedContinuation { continuation in
                pending = continuation
                started?.resume(); started = nil
            }
            observedCancellation = Task.isCancelled
            try Task.checkCancellation()
        }
        func waitUntilStarted() async {
            if pending != nil { return }
            await withCheckedContinuation { started = $0 }
        }
        func complete() { pending?.resume(); pending = nil }
    }

    @MainActor
    @Test("Dismissing native recovery cancels pending resolution and preserves evidence")
    func nativeDismissalCancellation() async throws {
        let fixture = try Fixture()
        let (store, material) = try staged(fixture)
        let review = try #require(try MCPIPTCPatchXMPRecoveryService(recovery: store, facade: fixture.facade).inspect())
        let delayed = DelayedResolution(result: review)
        let model = AutomationRecoveryModel(service: delayed)
        await model.inspect()
        let task = Task { await model.resolveUnchanged() }
        await delayed.waitUntilStarted()
        model.clear()
        await delayed.complete()
        await task.value
        #expect(await delayed.observedCancellation)
        #expect(model.review == nil)
        #expect(model.message == nil)
        #expect(!model.isLoading)
        #expect(try store.load() == material)
    }

}

@Suite("Native restoration confirmation binding")
@MainActor
struct AutomationRecoveryModelTests {
    private func review(_ fixture: MCPIPTCPatchXMPPreflightServiceTests.Fixture) throws -> MCPIPTCPatchXMPRecoveryService.Review {
        let snapshot = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        let canonical = try #require(realpath(fixture.root.path, nil))
        defer { free(canonical) }
        let store = MCPIPTCPatchXMPRecoveryStore(directory: URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("recovery"))
        let material = try store.stage(id: UUID(), planID: fixture.planID,
            targetPath: snapshot.target.url.deletingPathExtension().appendingPathExtension("xmp").path,
            binding: .init(sourceRevision: snapshot.sourceRevision, xmpSidecarRevision: snapshot.xmpSidecarRevision,
                appSidecarRevision: snapshot.appSidecarRevision,
                authorizationRevision: try #require(try fixture.facade.authorizationStore.load().authorizationRevision)),
            original: snapshot.xmpBytes, candidate: Data("candidate".utf8),
            appSidecarRecovery: .init(original: snapshot.appSidecarBytes, candidate: Data("history".utf8)),
            publicationApprovalID: UUID(), sourcePath: snapshot.target.url.path)
        let lease = try MCPProcessReservation.acquirePhoto(fixture.photo)
        defer { lease.release() }
        let original = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path, reservation: lease) { $0 }
        try fixture.facade.installXMPSidecar(data: material.candidate, expected: original, reservation: lease,
            afterInstall: { after in
                try store.recordInstalled(material, installed: .init(xmpRevision: after.xmpSidecarRevision, appRevision: nil), verify: {})
            })
        lease.release()
        return try #require(try MCPIPTCPatchXMPRecoveryService(recovery: store, facade: fixture.facade).inspect())
    }

    private actor Service: AutomationRecoveryServing {
        let review: MCPIPTCPatchXMPRecoveryService.Review
        var calls: [UUID] = []
        var fails = false
        var delays = false
        var pending: CheckedContinuation<Void, Never>?
        var wasCancelled = false
        init(_ review: MCPIPTCPatchXMPRecoveryService.Review) { self.review = review }
        func inspectRecovery(photoPath: String?) async throws -> MCPIPTCPatchXMPRecoveryService.Review? { review }
        func resolveUnchangedRecovery(_ review: MCPIPTCPatchXMPRecoveryService.Review) async throws {}
        func configure(fails: Bool = false, delays: Bool = false) { self.fails = fails; self.delays = delays }
        func restorePartialPublication(_ review: MCPIPTCPatchXMPRecoveryService.Review) async throws {
            calls.append(review.materialID)
            if delays { await withCheckedContinuation { pending = $0 } }
            wasCancelled = Task.isCancelled
            try Task.checkCancellation()
            if fails { throw MCPIPTCPatchXMPRecoveryService.Failure.staleReview }
        }
        func resume() { pending?.resume(); pending = nil }
        func started() -> Bool { pending != nil }
    }

    @Test("Restoration requires the current explicit confirmation and runs once")
    func explicitConfirmation() async throws {
        let fixture = try MCPIPTCPatchXMPPreflightServiceTests.Fixture()
        let checked = try review(fixture)
        let service = Service(checked)
        let model = AutomationRecoveryModel(service: service)
        await model.inspect()
        await model.confirmRestoration(UUID())
        #expect(await service.calls.isEmpty)
        model.requestRestoration()
        let cancelled = try #require(model.restorationConfirmation?.id)
        model.cancelRestoration()
        await model.confirmRestoration(cancelled)
        #expect(await service.calls.isEmpty)
        #expect(model.review != nil)
        model.requestRestoration()
        let accepted = try #require(model.restorationConfirmation?.id)
        await model.confirmRestoration(accepted)
        await model.confirmRestoration(accepted)
        #expect(await service.calls == [checked.materialID])
        #expect(model.review == nil)
        #expect(model.restorationConfirmation == nil)
        #expect(model.message?.hasPrefix("Original metadata restored.") == true)
    }

    @Test("Reinspection, path edits and clearing invalidate pending confirmation", arguments: ["inspect", "path", "clear"])
    func invalidation(action: String) async throws {
        let fixture = try MCPIPTCPatchXMPPreflightServiceTests.Fixture()
        let service = Service(try review(fixture))
        let model = AutomationRecoveryModel(service: service)
        await model.inspect()
        model.requestRestoration()
        let old = try #require(model.restorationConfirmation?.id)
        switch action {
        case "inspect": await model.inspect()
        case "path": model.legacyPhotoPath = "/different/photo.jpg"
        default: model.clear()
        }
        #expect(model.restorationConfirmation == nil)
        await model.confirmRestoration(old)
        #expect(await service.calls.isEmpty)
    }

    @Test("Failed restoration discards consent and requires fresh inspection")
    func staleFailure() async throws {
        let fixture = try MCPIPTCPatchXMPPreflightServiceTests.Fixture()
        let service = Service(try review(fixture))
        await service.configure(fails: true)
        let model = AutomationRecoveryModel(service: service)
        await model.inspect()
        model.requestRestoration()
        let id = try #require(model.restorationConfirmation?.id)
        await model.confirmRestoration(id)
        #expect(model.review == nil)
        #expect(model.restorationConfirmation == nil)
        #expect(model.message?.contains("inspect retained recovery again") == true)
        model.requestRestoration()
        #expect(model.restorationConfirmation == nil)
        await model.confirmRestoration(id)
        #expect(await service.calls.count == 1)
    }

    @Test("Clearing in-flight restoration cancels work and ignores late completion")
    func clearInFlight() async throws {
        let fixture = try MCPIPTCPatchXMPPreflightServiceTests.Fixture()
        let service = Service(try review(fixture))
        await service.configure(delays: true)
        let model = AutomationRecoveryModel(service: service)
        await model.inspect()
        model.requestRestoration()
        let id = try #require(model.restorationConfirmation?.id)
        let task = Task { await model.confirmRestoration(id) }
        while !(await service.started()) { await Task.yield() }
        model.clear()
        await service.resume()
        await task.value
        #expect(await service.wasCancelled)
        #expect(model.review == nil)
        #expect(model.restorationConfirmation == nil)
        #expect(model.message == nil)
        #expect(!model.isLoading)
    }
}
