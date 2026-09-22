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
            appSidecarRecovery: .init(original: snapshot.appSidecarBytes, candidate: Data("history".utf8)),
            publicationApprovalID: UUID(), sourcePath: legacy ? nil : snapshot.target.url.path)
        return (store, material)
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
