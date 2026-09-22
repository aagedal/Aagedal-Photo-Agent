import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Durable XMP publication admission and internal installation")
struct MCPIPTCPatchXMPPublicationAdmissionServiceTests {
    private typealias Fixture = MCPIPTCPatchXMPPreflightServiceTests.Fixture
    private typealias Service = MCPIPTCPatchXMPPublicationAdmissionService

    nonisolated private final class CancelTask: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Service.Admission, Error>?
        private var cancelRequested = false
        func install(_ task: Task<Service.Admission, Error>) {
            let shouldCancel = lock.withLock { self.task = task; return cancelRequested }
            if shouldCancel { task.cancel() }
        }
        func cancel() {
            let pending = lock.withLock { cancelRequested = true; return task }
            pending?.cancel()
        }
    }

    private func approval(_ fixture: Fixture, store: MCPIPTCPatchXMPPublicationApprovalStore) async throws
        -> MCPIPTCPatchXMPPublicationApprovalStore.Approval {
        let report = try await MCPIPTCPatchXMPPreflightService(plans: fixture.plans, facade: fixture.facade)
            .inspect(planID: fixture.planID)
        let review = try store.review(report, mode: .xmpSidecar, facade: fixture.facade)
        return try store.approve(review, acknowledgesC2PAConsequences: true,
            acknowledgesPendingDraftPromotion: true, facade: fixture.facade)
    }

    private func context(_ fixture: Fixture) throws -> AutomationOperationExecutionCoordinator.Context {
        let registry = AutomationOperationRegistry(storageDirectory: try storageDirectory(fixture, name: "operations"))
        let owner = UUID()
        let record = try registry.enqueue(kind: .iptcPatch, ownerID: owner)
        _ = try registry.start(record.id, ownerID: owner)
        return .init(operationID: record.id, registry: registry)
    }

    /// Foundation may present macOS temporary directories through /var even after URL
    /// symlink resolution. Strict persistence opens every ancestor with O_NOFOLLOW, so
    /// give its fixtures the actual existing directory spelling from realpath.
    private func storageDirectory(_ fixture: Fixture, name: String) throws -> URL {
        let canonical = try #require(realpath(fixture.root.path, nil))
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    @Test("Admission retains the lease and exact XMP/app recovery without changing any carrier", arguments: [false, true])
    func admitted(pending: Bool) async throws {
        let fixture = try Fixture(pending: pending)
        let before = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        let store = MCPIPTCPatchXMPPublicationApprovalStore(plans: fixture.plans)
        let receipt = try await approval(fixture, store: store)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: try storageDirectory(fixture, name: "recovery"))
        let context = try context(fixture)
        let service = Service(plans: fixture.plans, approvals: store, recovery: recovery, facade: fixture.facade)
        let admitted = try await service.admit(receipt, context: context)
        defer { admitted.release() }
        let material = try #require(try recovery.load())
        let operationID = await context.operationID
        #expect(admitted.operationID == operationID)
        #expect(material.id == operationID)
        #expect(material.publicationApprovalID == receipt.id)
        #expect(material.original == before.xmpBytes)
        #expect(try #require(material.appSidecarRecovery).original == before.appSidecarBytes)
        #expect(material.candidate != material.original)
        #expect(throws: (any Error).self) { try MCPProcessReservation.acquirePhoto(fixture.photo) }
        admitted.release()
        let after = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(after.sourceRevision == before.sourceRevision)
        #expect(after.xmpSidecarRevision == before.xmpSidecarRevision)
        #expect(after.appSidecarRevision == before.appSidecarRevision)
        await #expect(throws: (any Error).self) { try await service.admit(receipt, context: context) }
        #expect(try recovery.load() == material)
    }

    @Test("Internal publication verifies XMP and reconciles pending app history", arguments: [false, true])
    func publication(pending: Bool) async throws {
        let fixture = try Fixture(pending: pending)
        let before = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        let store = MCPIPTCPatchXMPPublicationApprovalStore(plans: fixture.plans)
        let receipt = try await approval(fixture, store: store)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: try storageDirectory(fixture, name: "recovery"))
        let service = Service(plans: fixture.plans, approvals: store, recovery: recovery, facade: fixture.facade)
        let result = await service.publish(receipt, context: try context(fixture))
        #expect(result.outcome == .verified)
        let material = try #require(try recovery.load())
        let after = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(after.sourceRevision == before.sourceRevision)
        #expect(after.sourceBytes == before.sourceBytes)
        #expect(after.xmpBytes == material.candidate)
        #expect(after.appSidecarBytes == material.appSidecarRecovery?.candidate)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let app = try decoder.decode(MetadataSidecar.self, from: #require(after.appSidecarBytes))
        #expect(!app.pendingChanges)
        #expect(app.metadata.title == "After")
        #expect(app.imageMetadataSnapshot?.title == "After")
        if pending { #expect(app.metadata.credit == "Pending unedited credit") }
        #expect(!app.history.isEmpty)
    }

    @Test("Publication refuses to discard an effective pending Capture Date before changing carriers")
    func pendingCaptureDateIsNotDiscarded() async throws {
        let fixture = try Fixture(pending: true, pendingCaptureDate: "2020:01:02 03:04:05")
        let before = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(try MCPMetadataSnapshotReader.read(before).resolution.metadata.captureDate == "2020:01:02 03:04:05")
        let store = MCPIPTCPatchXMPPublicationApprovalStore(plans: fixture.plans)
        let receipt = try await approval(fixture, store: store)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: try storageDirectory(fixture, name: "recovery"))
        let service = Service(plans: fixture.plans, approvals: store, recovery: recovery, facade: fixture.facade)
        let result = await service.publish(receipt, context: try context(fixture))
        #expect(result.outcome == .refused)
        #expect(try recovery.load() == nil)
        let after = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(after.sourceRevision == before.sourceRevision)
        #expect(after.xmpSidecarRevision == before.xmpSidecarRevision)
        #expect(after.appSidecarRevision == before.appSidecarRevision)
        #expect(try MCPMetadataSnapshotReader.read(after).resolution.hasPendingChanges)
        #expect(try MCPMetadataSnapshotReader.read(after).resolution.metadata.captureDate == "2020:01:02 03:04:05")
    }

    @Test("Interruption after XMP install retains both recovery originals and reports uncertainty")
    func interruptedPublication() async throws {
        let fixture = try Fixture(pending: true)
        let before = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        let store = MCPIPTCPatchXMPPublicationApprovalStore(plans: fixture.plans)
        let receipt = try await approval(fixture, store: store)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: try storageDirectory(fixture, name: "recovery"))
        let service = Service(plans: fixture.plans, approvals: store, recovery: recovery, facade: fixture.facade,
            hooks: .init(afterXMPInstall: { throw CancellationError() }))
        let result = await service.publish(receipt, context: try context(fixture))
        #expect(result.outcome == .uncertain)
        let material = try #require(try recovery.load())
        let after = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(after.sourceRevision == before.sourceRevision)
        #expect(after.xmpBytes == material.candidate)
        #expect(after.appSidecarBytes == before.appSidecarBytes)
        #expect(material.original == before.xmpBytes)
        #expect(material.appSidecarRecovery?.original == before.appSidecarBytes)
        #expect(material.appSidecarRecovery?.candidate != nil)
        let retried = await service.publish(receipt, context: try context(fixture))
        #expect(retried.outcome == .refused)
        #expect(try recovery.load() == material)
    }

    @Test("Missing XMP and app history are recorded as absent without creating either carrier")
    func missingCarriers() async throws {
        let fixture = try Fixture(existingXMP: false)
        let store = MCPIPTCPatchXMPPublicationApprovalStore(plans: fixture.plans)
        let receipt = try await approval(fixture, store: store)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: try storageDirectory(fixture, name: "recovery"))
        let service = Service(plans: fixture.plans, approvals: store, recovery: recovery, facade: fixture.facade)
        let admitted = try await service.admit(receipt, context: context(fixture))
        defer { admitted.release() }
        let material = try #require(try recovery.load())
        #expect(material.original == nil)
        #expect(try #require(material.appSidecarRecovery).original == nil)
        #expect(!FileManager.default.fileExists(atPath: receipt.targetPath))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".photo_metadata").path))
    }

    @Test("Candidate or source changes during staging refuse before recovery is staged", arguments: ["candidate", "source"])
    func stagingDrift(kind: String) async throws {
        let fixture = try Fixture()
        let store = MCPIPTCPatchXMPPublicationApprovalStore(plans: fixture.plans)
        let receipt = try await approval(fixture, store: store)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: try storageDirectory(fixture, name: "recovery"))
        let photo = fixture.photo
        let service = Service(plans: fixture.plans, approvals: store, recovery: recovery, facade: fixture.facade,
            hooks: .init(afterStaging: { url in
                try Data("changed".utf8).write(to: kind == "source" ? photo : url)
            }))
        await #expect(throws: (any Error).self) { try await service.admit(receipt, context: context(fixture)) }
        #expect(try recovery.load() == nil)
        let lease = try MCPProcessReservation.acquirePhoto(photo)
        lease.release()
    }

    @Test("Failure after durable staging retains recovery, revokes consent and releases the lease",
          arguments: ["authority", "journal", "fault"])
    func recoveryFault(kind: String) async throws {
        let fixture = try Fixture(pending: true)
        let before = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        let store = MCPIPTCPatchXMPPublicationApprovalStore(plans: fixture.plans)
        let receipt = try await approval(fixture, store: store)
        let directory = try storageDirectory(fixture, name: "recovery")
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: directory)
        let facade = fixture.facade
        let service = Service(plans: fixture.plans, approvals: store, recovery: recovery, facade: facade,
            hooks: .init(afterRecovery: {
                if kind == "authority" {
                    try facade.authorizationStore.setEnabled(false)
                    try facade.authorizationStore.setEnabled(true)
                } else if kind == "journal" {
                    try Data("corrupt".utf8).write(to: directory.appendingPathComponent("iptc-xmp-recovery/operations.json"))
                } else { throw Service.Failure.verification }
            }))
        await #expect(throws: (any Error).self) { try await service.admit(receipt, context: context(fixture)) }
        let after = try facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(after.sourceBytes == before.sourceBytes)
        #expect(after.xmpBytes == before.xmpBytes)
        #expect(after.appSidecarBytes == before.appSidecarBytes)
        if kind != "journal" {
            let material = try #require(try recovery.load())
            let lease = try MCPProcessReservation.acquirePhoto(fixture.photo)
            defer { lease.release() }
            #expect(throws: MCPIPTCPatchXMPPublicationApprovalStore.Failure.unavailableApproval) {
                try store.validate(receipt, candidate: material.candidate, mode: .xmpSidecar,
                    targetPath: receipt.targetPath, facade: facade, reservation: lease)
            }
        } else {
            #expect(throws: (any Error).self) { try recovery.load() }
        }
    }

    @Test("Caller cancellation survives the metadata coordinator task boundary", arguments: [false, true])
    func callerCancellation(afterRecovery: Bool) async throws {
        let fixture = try Fixture()
        let store = MCPIPTCPatchXMPPublicationApprovalStore(plans: fixture.plans)
        let receipt = try await approval(fixture, store: store)
        let before = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: try storageDirectory(fixture, name: "recovery"))
        let canceller = CancelTask()
        let service = Service(plans: fixture.plans, approvals: store, recovery: recovery, facade: fixture.facade,
            hooks: .init(afterStaging: { _ in if !afterRecovery { canceller.cancel() } },
                         afterRecovery: { if afterRecovery { canceller.cancel() } }))
        let context = try context(fixture)
        let task = Task { try await service.admit(receipt, context: context) }
        canceller.install(task)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect((try recovery.load() != nil) == afterRecovery)
        let after = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(after.sourceRevision == before.sourceRevision)
        #expect(after.xmpSidecarRevision == before.xmpSidecarRevision)
        #expect(after.appSidecarRevision == before.appSidecarRevision)
    }
}
