import Foundation

/// Native XMP publication consumes exact consent only after durable recovery is read back.
/// The rooted transaction installs and verifies XMP plus reconciled app history; helper
/// clients cannot invoke publication. Unresolved recovery blocks further publication.
nonisolated struct MCPIPTCPatchXMPPublicationAdmissionService: Sendable {
    enum Failure: Error, Equatable { case verification, missingAuthorizationRevision }

    /// A process-local retained reservation, not a serializable write capability. Candidate
    /// and original bytes remain private to recovery storage; no install API is exposed.
    /// Releasing this object does not resolve or erase its durable recovery record.
    final class Admission: Sendable {
        let operationID: UUID
        let planID: String
        let targetPath: String
        fileprivate let reservation: MCPProcessReservationLease
        fileprivate let snapshot: MCPPhotoCarrierSnapshot
        fileprivate let material: MCPIPTCPatchXMPRecoveryStore.Material

        fileprivate init(operationID: UUID, planID: String, targetPath: String,
                         reservation: MCPProcessReservationLease, snapshot: MCPPhotoCarrierSnapshot,
                         material: MCPIPTCPatchXMPRecoveryStore.Material) {
            self.operationID = operationID; self.planID = planID; self.targetPath = targetPath
            self.reservation = reservation; self.snapshot = snapshot; self.material = material
        }

        func release() { reservation.release() }
        deinit { reservation.release() }
    }

    struct Hooks: Sendable {
        var afterStaging: @Sendable (URL) throws -> Void = { _ in }
        var afterRecovery: @Sendable () throws -> Void = {}
        var beforeDisposition: @Sendable () throws -> Void = {}
        var afterXMPInstall: @Sendable () throws -> Void = {}
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
        let appCandidate = try stageAppHistory(snapshot: snapshot, expected: expected,
            stagedPhoto: stagedPhoto, staging: staging)
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
            appSidecarRecovery: .init(original: snapshot.appSidecarBytes, candidate: appCandidate), publicationApprovalID: approval.id,
            sourcePath: photo.path)
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
            targetPath: targetPath, reservation: reservation, snapshot: snapshot, material: material)
    }

    private final class Effects: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func mark() { lock.withLock { value = true } }
        var occurred: Bool { lock.withLock { value } }
    }

    enum PublicationOutcome: Sendable, Equatable { case verified, refused, uncertain, cancelled }
    struct PublicationResult: Sendable {
        let outcome: PublicationOutcome
        let message: String
    }

    /// Verified publication receives a durable disposition; uncertain/interrupted operations
    /// retain unresolved recovery and block replacement. No helper endpoint exposes this API.
    @MetadataSidecarFilesystemActor
    func publish(_ approval: MCPIPTCPatchXMPPublicationApprovalStore.Approval,
                 context: AutomationOperationExecutionCoordinator.Context) async -> PublicationResult {
        let effects = Effects()
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            do {
                let admission = try await admit(approval, context: context)
                defer { admission.release() }
                try Task.checkCancellation()
                try await context.checkCancellation()
                try await context.markEffectsMayHaveOccurred()
                try Task.checkCancellation()
                // No suspension after entering the held transaction: cancellation cannot skip
                // reconciliation or verification once the first carrier could have changed.
                return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: admission.snapshot.target.url)) { @MetadataSidecarFilesystemActor in
                    let snapshot = admission.snapshot
                    guard let material = try recovery.load(), material == admission.material,
                          material.id == admission.operationID,
                          material.planID == admission.planID, material.targetPath == admission.targetPath,
                          material.publicationApprovalID == approval.id,
                          material.binding.authorizationRevision == (try facade.authorizationStore.load()).authorizationRevision,
                          let appCandidate = material.appSidecarRecovery?.candidate else { throw Failure.verification }
                    try AutomationDraftEditorAdmission.shared.requireUnselected(snapshot.target.url)
                    try cancellation.checking { effects.mark() }
                    _ = try facade.installXMPSidecar(data: material.candidate, expected: snapshot,
                        reservation: admission.reservation, beforeInstall: {
                            guard try recovery.load() == material,
                                  material.binding.authorizationRevision == (try facade.authorizationStore.load()).authorizationRevision
                            else { throw Failure.verification }
                        }, afterInstall: { installed in
                            try recovery.recordInstalled(material,
                                installed: .init(xmpRevision: installed.xmpSidecarRevision, appRevision: nil)) {
                                guard installed.sourceRevision == snapshot.sourceRevision,
                                      installed.appSidecarRevision == snapshot.appSidecarRevision,
                                      material.binding.authorizationRevision == (try facade.authorizationStore.load()).authorizationRevision
                                else { throw Failure.verification }
                            }
                        })
                    try hooks.afterXMPInstall()
                    let installedXMP = try facade.withPhotoSnapshot(path: snapshot.target.url.path,
                        reservation: admission.reservation) { $0 }
                    guard installedXMP.sourceRevision == snapshot.sourceRevision,
                          installedXMP.sourceBytes == snapshot.sourceBytes,
                          installedXMP.xmpBytes == material.candidate,
                          installedXMP.appSidecarRevision == snapshot.appSidecarRevision,
                          installedXMP.appSidecarBytes == snapshot.appSidecarBytes,
                          try recovery.load() == material,
                          material.binding.authorizationRevision == (try facade.authorizationStore.load()).authorizationRevision
                    else { throw Failure.verification }
                    _ = try facade.installPendingDraft(data: appCandidate, expected: installedXMP,
                        reservation: admission.reservation, beforeInstall: {
                            guard try recovery.load() == material,
                                  material.binding.authorizationRevision == (try facade.authorizationStore.load()).authorizationRevision
                            else { throw Failure.verification }
                        }, afterInstall: { installed in
                            try recovery.recordInstalled(material,
                                installed: .init(xmpRevision: installed.xmpSidecarRevision,
                                    appRevision: installed.appSidecarRevision)) {
                                guard installed.sourceRevision == snapshot.sourceRevision,
                                      installed.xmpSidecarRevision == installedXMP.xmpSidecarRevision,
                                      material.binding.authorizationRevision == (try facade.authorizationStore.load()).authorizationRevision
                                else { throw Failure.verification }
                            }
                        })
                    let final = try facade.withPhotoSnapshot(path: snapshot.target.url.path,
                        reservation: admission.reservation) { $0 }
                    guard let installedReceipt = try recovery.loadInstalledCarriers(),
                          installedReceipt.xmpRevision == final.xmpSidecarRevision,
                          installedReceipt.appRevision == final.appSidecarRevision,
                          final.sourceRevision == snapshot.sourceRevision,
                          final.sourceBytes == snapshot.sourceBytes,
                          final.xmpSidecarRevision == installedXMP.xmpSidecarRevision,
                          final.xmpBytes == material.candidate, final.appSidecarBytes == appCandidate,
                          try recovery.load() == material,
                          material.binding.authorizationRevision == (try facade.authorizationStore.load()).authorizationRevision
                    else { throw Failure.verification }
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    let saved = try decoder.decode(MetadataSidecar.self, from: appCandidate)
                    let actual = try MCPMetadataSnapshotReader.read(final).resolution.metadata
                    guard !saved.pendingChanges,
                          IPTCMetadataVerificationField.allCases.allSatisfy({
                              IPTCMetadataVerifier.canonicalValue(for: $0, in: saved.metadata)
                                == IPTCMetadataVerifier.canonicalValue(for: $0, in: actual)
                          }) else { throw Failure.verification }
                    try hooks.beforeDisposition()
                    try recovery.recordVerified(material) {
                        let current = try facade.withPhotoSnapshot(path: snapshot.target.url.path,
                            reservation: admission.reservation) { $0 }
                        guard current.sourceRevision == final.sourceRevision,
                              current.sourceBytes == final.sourceBytes,
                              current.xmpSidecarRevision == final.xmpSidecarRevision,
                              current.xmpBytes == material.candidate,
                              current.appSidecarRevision == final.appSidecarRevision,
                              current.appSidecarBytes == appCandidate,
                              material.binding.authorizationRevision == (try facade.authorizationStore.load()).authorizationRevision
                        else { throw Failure.verification }
                    }
                    return PublicationResult(outcome: .verified,
                        message: "XMP and app history verified. Publication completion is durably recorded.")
                }
            } catch {
                return PublicationResult(outcome: effects.occurred ? .uncertain : (error is CancellationError ? .cancelled : .refused),
                    message: effects.occurred
                        ? "Publication may have changed metadata. Recovery is retained; review the carriers before retrying."
                        : error.localizedDescription)
            }
        } onCancel: { cancellation.cancel() }
    }

    @MetadataSidecarFilesystemActor
    private func stageAppHistory(snapshot: MCPPhotoCarrierSnapshot, expected: IPTCMetadata,
                                 stagedPhoto: URL, staging: URL) throws -> Data {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let current = try snapshot.appSidecarBytes.map { try decoder.decode(MetadataSidecar.self, from: $0) }
        // Orientation has its own commit contract; never silently mark that draft saved.
        guard current?.orientationDraft == nil else { throw Failure.verification }
        let baseline = try MCPMetadataSnapshotReader.read(snapshot).resolution.metadata
        if current?.pendingChanges == true {
            // Capture Date is not written by this descriptive publication. Clearing a
            // pending record would otherwise discard its effective value and silently
            // restore the physical carrier's value despite a successful writable-field check.
            let physicalSnapshot = MCPPhotoCarrierSnapshot(target: snapshot.target,
                sourceBytes: snapshot.sourceBytes, xmpBytes: snapshot.xmpBytes, appSidecarBytes: nil,
                sourceModificationDate: snapshot.sourceModificationDate,
                xmpModificationDate: snapshot.xmpModificationDate,
                sourceRevision: snapshot.sourceRevision, xmpSidecarRevision: snapshot.xmpSidecarRevision,
                appSidecarRevision: snapshot.appSidecarRevision)
            let physical = try MCPMetadataSnapshotReader.read(physicalSnapshot).resolution.metadata
            guard IPTCMetadataVerifier.canonicalValue(for: .captureDate, in: expected)
                    == IPTCMetadataVerifier.canonicalValue(for: .captureDate, in: physical) else {
                throw Failure.verification
            }
        }
        var reconciled = current ?? MetadataSidecar(sourceFile: stagedPhoto.lastPathComponent)
        reconciled.metadata = expected
        reconciled.imageMetadataSnapshot = expected
        reconciled.pendingChanges = false
        reconciled.history += MetadataHistoryEntry.changes(from: baseline, to: expected, timestamp: Date())
        reconciled.history.trimToHistoryLimit()
        let directory = staging.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("\(stagedPhoto.lastPathComponent).meta.json")
        if let original = snapshot.appSidecarBytes { try original.write(to: url) }
        let service = MetadataSidecarService()
        let saved = try service.saveSidecar(reconciled, for: stagedPhoto, in: staging)
        let bytes = try Data(contentsOf: url)
        let decoded = try decoder.decode(MetadataSidecar.self, from: bytes)
        guard !decoded.pendingChanges, decoded.orientationDraft == nil,
              service.fieldMutationRecordsEqual(saved, decoded),
              IPTCMetadataVerificationField.allCases.allSatisfy({
                  IPTCMetadataVerifier.canonicalValue(for: $0, in: expected)
                    == IPTCMetadataVerifier.canonicalValue(for: $0, in: decoded.metadata)
              }) else { throw Failure.verification }
        if let original = snapshot.appSidecarBytes, let current {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            guard try MCPIPTCPatchExecutionService.preservesUnknownFields(original: original,
                known: encoder.encode(current), installed: bytes) else { throw Failure.verification }
        }
        return bytes
    }
}
