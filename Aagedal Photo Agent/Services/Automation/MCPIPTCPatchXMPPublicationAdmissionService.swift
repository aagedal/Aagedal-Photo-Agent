import Foundation

/// Internal admission groundwork, intentionally not connected to a publication button or
/// helper endpoint. It consumes exact native consent only after durable recovery is read back.
/// It never installs a carrier, reconciles app history or claims publication completed.
nonisolated struct MCPIPTCPatchXMPPublicationAdmissionService: Sendable {
    enum Failure: Error, Equatable { case verification, missingAuthorizationRevision }

    /// A process-local retained reservation, not a serializable write capability. Candidate
    /// and original bytes remain private to recovery storage; no install API is exposed.
    /// Releasing this object does not resolve or erase its durable recovery record.
    final class Admission: Sendable {
        let operationID: UUID
        let planID: String
        let targetPath: String
        private let reservation: MCPProcessReservationLease

        fileprivate init(operationID: UUID, planID: String, targetPath: String,
                         reservation: MCPProcessReservationLease) {
            self.operationID = operationID; self.planID = planID; self.targetPath = targetPath
            self.reservation = reservation
        }

        func release() { reservation.release() }
        deinit { reservation.release() }
    }

    struct Hooks: Sendable {
        var afterStaging: @Sendable (URL) throws -> Void = { _ in }
        var afterRecovery: @Sendable () throws -> Void = {}
    }

    /// MetadataIOCoordinator executes its body in an unstructured task. Carry cancellation
    /// from the submitting task across that boundary and linearize it with consent consumption.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws { try checking {} }
        func checking<Value>(_ body: () throws -> Value) throws -> Value {
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                return try body()
            }
        }
    }

    private let plans: MCPIPTCPatchPlanStore
    private let approvals: MCPIPTCPatchXMPPublicationApprovalStore
    private let recovery: MCPIPTCPatchXMPRecoveryStore
    private let facade: MCPAutomationFacade
    private let hooks: Hooks

    init(plans: MCPIPTCPatchPlanStore, approvals: MCPIPTCPatchXMPPublicationApprovalStore,
         recovery: MCPIPTCPatchXMPRecoveryStore, facade: MCPAutomationFacade, hooks: Hooks = .init()) {
        self.plans = plans; self.approvals = approvals; self.recovery = recovery
        self.facade = facade; self.hooks = hooks
    }

    @MetadataSidecarFilesystemActor
    func admit(_ approval: MCPIPTCPatchXMPPublicationApprovalStore.Approval,
               context: AutomationOperationExecutionCoordinator.Context) async throws -> Admission {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await admit(approval, context: context, cancellation: cancellation)
        } onCancel: { cancellation.cancel() }
    }

    @MetadataSidecarFilesystemActor
    private func admit(_ approval: MCPIPTCPatchXMPPublicationApprovalStore.Approval,
                       context: AutomationOperationExecutionCoordinator.Context,
                       cancellation: Cancellation) async throws -> Admission {
        var admitted = false
        defer { if !admitted { approvals.revoke(approval) } }
        try Task.checkCancellation()
        try await context.checkCancellation()
        let binding = try plans.localApprovalBinding(planID: approval.planID, facade: facade, now: Date())
        guard let path = binding.preview.objectValue?["canonicalPath"]?.stringValue else {
            throw MCPIPTCPatchPlanStore.Failure.invalidArguments
        }
        let photo = URL(fileURLWithPath: path)
        let reservation = try MCPProcessReservation.acquirePhoto(photo)
        do {
            let result = try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: photo)) { @MetadataSidecarFilesystemActor in
                try cancellation.check()
                return try await prepare(approval, photo: photo, reservation: reservation,
                    context: context, cancellation: cancellation)
            }
            admitted = true
            return result
        } catch {
            reservation.release()
            throw error
        }
    }

    @MetadataSidecarFilesystemActor
    private func prepare(_ approval: MCPIPTCPatchXMPPublicationApprovalStore.Approval, photo: URL,
                         reservation: MCPProcessReservationLease,
                         context: AutomationOperationExecutionCoordinator.Context,
                         cancellation: Cancellation) async throws -> Admission {
        let request = try plans.requestForDraftExecution(planID: approval.planID, facade: facade, reservation: reservation)
        let configuration = try facade.authorizationStore.load()
        guard let authorizationRevision = configuration.authorizationRevision else {
            throw Failure.missingAuthorizationRevision
        }
        let snapshot = try facade.withPhotoSnapshot(path: photo.path, reservation: reservation) { $0 }
        var expected = try MCPMetadataSnapshotReader.read(snapshot).resolution.metadata
        for operation in request.operations { try operation.apply(to: &expected) }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("iptc-xmp-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedPhoto = staging.appendingPathComponent(photo.lastPathComponent)
        let service = XMPSidecarService()
        let stagedXMP = service.sidecarURL(for: stagedPhoto)
        if let original = snapshot.xmpBytes { try original.write(to: stagedXMP) }
        _ = try await service.writeMetadataInHeldTransaction(expected, for: stagedPhoto,
            expectedSnapshot: .init(data: snapshot.xmpBytes), onlyIfExisting: false,
            replaceDevelopSettings: false, replaceOrientation: false)
        try hooks.afterStaging(stagedXMP)
        try Task.checkCancellation()
        try cancellation.check()
        let candidate = try Data(contentsOf: stagedXMP)
        guard !candidate.isEmpty, candidate.count <= 8_388_608,
              let actual = service.loadSidecar(fromData: candidate),
              IPTCMetadataVerificationField.writableFields.allSatisfy({
                  IPTCMetadataVerifier.canonicalValue(for: $0, in: expected)
                      == IPTCMetadataVerifier.canonicalValue(for: $0, in: actual)
              }) else { throw Failure.verification }
        try MCPIPTCPatchXMPPreflightService.verifyPreservation(before: snapshot.xmpBytes, after: candidate)
        let targetPath = service.sidecarURL(for: photo).path
        try approvals.validate(approval, candidate: candidate, mode: .xmpSidecar, targetPath: targetPath,
            facade: facade, reservation: reservation)
        try await context.checkCancellation()
        try cancellation.check()
        try AutomationDraftEditorAdmission.shared.requireUnselected(photo)
        let material = try recovery.stage(id: context.operationID, planID: approval.planID,
            targetPath: targetPath, binding: .init(sourceRevision: snapshot.sourceRevision,
                xmpSidecarRevision: snapshot.xmpSidecarRevision, appSidecarRevision: snapshot.appSidecarRevision,
                authorizationRevision: authorizationRevision), original: snapshot.xmpBytes, candidate: candidate,
            appSidecarRecovery: .init(original: snapshot.appSidecarBytes), publicationApprovalID: approval.id)
        try hooks.afterRecovery()
        try await context.checkCancellation()
        // No await follows these final checks. Same-byte inode changes, revoked/regranted
        // authority, missing/substituted journals and inactive reservations all refuse.
        guard try recovery.load() == material,
              try facade.authorizationStore.load() == configuration else { throw Failure.verification }
        try AutomationDraftEditorAdmission.shared.requireUnselected(photo)
        try cancellation.checking {
            try approvals.validate(approval, candidate: candidate, mode: .xmpSidecar, targetPath: targetPath,
                facade: facade, reservation: reservation, consumeForPublication: true)
        }
        return Admission(operationID: context.operationID, planID: approval.planID,
            targetPath: targetPath, reservation: reservation)
    }
}
