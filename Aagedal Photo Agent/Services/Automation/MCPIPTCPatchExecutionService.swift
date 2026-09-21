import Foundation

/// Native-only application of an exact reviewed patch to the app's pending JSON draft.
/// This never publishes embedded/XMP metadata and is deliberately absent from MCP tools.
nonisolated struct MCPIPTCPatchExecutionService: Sendable {
    enum Outcome: Sendable, Equatable { case draftSaved, refused, uncertain, cancelled }
    struct Result: Sendable {
        let outcome: Outcome
        let sidecarURL: URL?
        let message: String
        let installedSidecar: MetadataSidecar?
    }
    struct Hooks: Sendable {
        var beforeAdmission: @Sendable () throws -> Void = {}
        var afterSave: @Sendable () throws -> Void = {}
    }
    private let plans: MCPIPTCPatchPlanStore
    private let approvals: MCPIPTCPatchApprovalStore
    private let facade: MCPAutomationFacade
    private let hooks: Hooks

    init(plans: MCPIPTCPatchPlanStore, approvals: MCPIPTCPatchApprovalStore,
         facade: MCPAutomationFacade, hooks: Hooks = .init()) {
        self.plans = plans; self.approvals = approvals; self.facade = facade; self.hooks = hooks
    }

    @MetadataSidecarFilesystemActor
    func applyToPendingDraft(_ approval: MCPIPTCPatchApprovalStore.Approval,
                            context: AutomationOperationExecutionCoordinator.Context? = nil) async -> Result {
        do {
            try Task.checkCancellation()
            try await context?.checkCancellation()
            let preview = try approvals.validate(approval, facade: facade)
            guard let path = preview.objectValue?["canonicalPath"]?.stringValue else {
                throw MCPIPTCPatchPlanStore.Failure.invalidArguments
            }
            let photo = URL(fileURLWithPath: path)
            let reservation = try MCPProcessReservation.acquirePhoto(photo)
            defer { reservation.release() }
            return await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: photo)) { @MetadataSidecarFilesystemActor in
                await execute(approval, photo: photo, reservation: reservation, context: context)
            }
        } catch {
            return .init(outcome: error is CancellationError ? .cancelled : .refused,
                         sidecarURL: nil, message: error.localizedDescription, installedSidecar: nil)
        }
    }

    @MetadataSidecarFilesystemActor
    private func execute(_ approval: MCPIPTCPatchApprovalStore.Approval, photo: URL,
                         reservation: MCPProcessReservationLease,
                         context: AutomationOperationExecutionCoordinator.Context?) async -> Result {
        var sidecarURL: URL?
        var saveMayHaveOccurred = false
        do {
            try hooks.beforeAdmission()
            try Task.checkCancellation()
            try await context?.checkCancellation()
            _ = try approvals.validate(approval, facade: facade, reservation: reservation)
            let request = try plans.requestForDraftExecution(planID: approval.planID,
                facade: facade, reservation: reservation)
            let configuration = try facade.authorizationStore.load()
            let snapshot = try facade.withPhotoSnapshot(path: photo.path, reservation: reservation) { $0 }
            let baseline = try MCPMetadataSnapshotReader.read(snapshot).resolution.metadata
            var expected = baseline
            for operation in request.operations { try operation.apply(to: &expected) }
            let service = MetadataSidecarService()
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let current = try snapshot.appSidecarBytes.map { try decoder.decode(MetadataSidecar.self, from: $0) }
            var draft = current ?? MetadataSidecar(sourceFile: photo.lastPathComponent,
                metadata: baseline, imageMetadataSnapshot: baseline)
            draft.metadata = expected
            // Descriptive consent does not replace the saved private Develop/orientation record.
            if let current {
                draft.metadata.cameraRaw = current.metadata.cameraRaw
                draft.metadata.exifOrientation = current.metadata.exifOrientation
            }
            draft.pendingChanges = true
            draft.history += MetadataHistoryEntry.changes(from: baseline, to: expected, timestamp: Date())
            draft.history.trimToHistoryLimit()
            let priorKnown = try current.map(Self.encoded)
            // Run the production owned-sidecar codec in an isolated staging directory first.
            // The actual installation uses the facade's descriptor-relative rooted boundary.
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("iptc-draft-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            let stagedPhoto = staging.appendingPathComponent(photo.lastPathComponent)
            let stagedDirectory = staging.appendingPathComponent(".photo_metadata", isDirectory: true)
            try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: false)
            let stagedSidecar = stagedDirectory.appendingPathComponent("\(photo.lastPathComponent).meta.json")
            if let bytes = snapshot.appSidecarBytes { try bytes.write(to: stagedSidecar) }
            let saved = try service.saveSidecar(draft, for: stagedPhoto, in: staging)
            let stagedBytes = try Data(contentsOf: stagedSidecar)
            if let original = snapshot.appSidecarBytes, let priorKnown {
                guard try Self.preservesUnknownFields(original: original, known: priorKnown, installed: stagedBytes) else {
                    throw UnsupportedPrivateExtension()
                }
            }
            // The only suspension immediately before admission is cancellation/effect bookkeeping.
            // Revalidate receipt and every carrier after it, and consume consent atomically.
            try await context?.markEffectsMayHaveOccurred()
            try Task.checkCancellation()
            try AutomationDraftEditorAdmission.shared.requireUnselected(photo)
            _ = try approvals.validate(approval, facade: facade, reservation: reservation, consumeForDraft: true)
            saveMayHaveOccurred = true
            sidecarURL = try facade.installPendingDraft(data: stagedBytes, expected: snapshot, reservation: reservation)
            try hooks.afterSave()
            // Cancellation after install cannot skip verification or become a no-effects claim.
            let after = try facade.withPhotoSnapshot(path: photo.path, reservation: reservation) { $0 }
            guard try facade.authorizationStore.load() == configuration,
                  snapshot.sourceBytes == after.sourceBytes, snapshot.sourceRevision == after.sourceRevision,
                  snapshot.xmpBytes == after.xmpBytes, snapshot.xmpSidecarRevision == after.xmpSidecarRevision,
                  let installedBytes = after.appSidecarBytes, installedBytes == stagedBytes else { throw VerificationFailure() }
            let installed = try decoder.decode(MetadataSidecar.self, from: installedBytes)
            guard service.fieldMutationRecordsEqual(installed, saved) else { throw VerificationFailure() }
            let actual = try MCPMetadataSnapshotReader.read(after).resolution.metadata
            // Compare every field, including absent localized titles; the generic write verifier
            // intentionally skips nil localized titles because physical writes treat nil as intent.
            guard IPTCMetadataVerificationField.allCases.allSatisfy({
                IPTCMetadataVerifier.canonicalValue(for: $0, in: expected)
                    == IPTCMetadataVerifier.canonicalValue(for: $0, in: actual)
            }) else { throw VerificationFailure() }
            if let priorBytes = snapshot.appSidecarBytes, let priorKnown {
                guard try Self.preservesUnknownFields(original: priorBytes, known: priorKnown, installed: installedBytes) else {
                    throw VerificationFailure()
                }
            }
            return .init(outcome: .draftSaved, sidecarURL: sidecarURL,
                message: "Applied to the pending Photo Agent draft. Embedded and XMP metadata were not published.",
                installedSidecar: installed)
        } catch {
            return .init(outcome: saveMayHaveOccurred ? .uncertain : (error is CancellationError ? .cancelled : .refused),
                sidecarURL: saveMayHaveOccurred ? sidecarURL : nil,
                message: saveMayHaveOccurred
                    ? "The pending draft may have been saved, but verification did not complete. Reload and review it before retrying. \(error.localizedDescription)"
                    : error.localizedDescription,
                installedSidecar: nil)
        }
    }

    private struct UnsupportedPrivateExtension: LocalizedError {
        var errorDescription: String? {
            "This draft contains private metadata extensions that the current writer cannot preserve. No draft was installed."
        }
    }

    private struct VerificationFailure: LocalizedError {
        var errorDescription: String? { "The saved draft or a preserved carrier did not match the reviewed patch." }
    }

    private static func encoded(_ record: MetadataSidecar) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(record)
    }

    /// Verify opaque extensions recursively wherever the production codec has an object.
    /// Nested arrays are checked too; unsupported opaque extensions refuse before installation.
    static func preservesUnknownFields(original: Data, known: Data, installed: Data) throws -> Bool {
        let decoder = JSONDecoder()
        let original = try decoder.decode(MCPJSONValue.self, from: original)
        let known = try decoder.decode(MCPJSONValue.self, from: known)
        let installed = try decoder.decode(MCPJSONValue.self, from: installed)
        func check(_ original: MCPJSONValue, _ known: MCPJSONValue, _ installed: MCPJSONValue) -> Bool {
            if case .array(let old) = original, case .array(let modeled) = known {
                guard case .array(let new) = installed else { return old.isEmpty }
                guard old.count == modeled.count else { return false }
                for index in old.indices {
                    if !check(old[index], modeled[index], index < new.count ? new[index] : .null) { return false }
                }
                return true
            }
            guard let old = original.objectValue, let modeled = known.objectValue else { return true }
            guard let new = installed.objectValue else { return false }
            for (key, value) in old {
                guard let modeledValue = modeled[key] else {
                    if new[key] != value { return false }
                    continue
                }
                if !check(value, modeledValue, new[key] ?? .null) { return false }
            }
            return true
        }
        return check(original, known, installed)
    }
}
