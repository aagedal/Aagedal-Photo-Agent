import CryptoKit
import Foundation

/// A physical prerequisite for reviewed Develop batches, deliberately unconnected to Start.
/// Callers own consent, whole-batch authority and durable recovery. Both mandatory callbacks
/// must bind those capabilities to the exact request; this primitive supplies confinement.
nonisolated struct DevelopTemplateRootedWriteService: Sendable {
    enum Stage: Equatable, Sendable { case xmp, appSidecar, verification }

    struct Hooks: Sendable {
        var afterStaging: @Sendable () throws -> Void = {}
        var beforeXMP: @Sendable () throws -> Void = {}
        var afterXMP: @Sendable () throws -> Void = {}
        var beforeJSON: @Sendable () throws -> Void = {}
        var afterJSON: @Sendable () throws -> Void = {}
    }

    struct Result: Sendable {
        let writeResult: PrimaryDevelopWriteResult
        let installedXMP: MCPPhotoCarrierSnapshot?
        let installedAppSidecar: MCPPhotoCarrierSnapshot?
        let preparedXMP: MCPPreparedXMPIdentity?
        let preparedAppSidecar: MCPPreparedXMPIdentity?
        let appSidecarURL: URL?
    }

    private enum Failure: LocalizedError {
        case unsupported, changedEvidence, verification
        var errorDescription: String? {
            switch self {
            case .unsupported: "This Develop request requires a different physical admission boundary."
            case .changedEvidence: "The original rooted Develop carriers changed."
            case .verification: "The rooted Develop publication could not be verified."
            }
        }
    }

    // The coordinator runs its body in an unstructured task. Preserve submitting-task
    // cancellation across that boundary instead of consulting only the worker's task.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws {
            try lock.withLock { if cancelled { throw CancellationError() } }
        }
    }

    // Only the held filesystem-actor transaction and its synchronous facade callbacks
    // access this state. Reference storage keeps receipts alive when a callback throws.
    private final class Progress: @unchecked Sendable {
        var preparedXMP: MCPPreparedXMPIdentity?
        var preparedApp: MCPPreparedXMPIdentity?
        var installedXMP: MCPPhotoCarrierSnapshot?
        var installedApp: MCPPhotoCarrierSnapshot?
        var appSidecarURL: URL?
        var xmpMayHaveWritten = false
        var appMayHaveWritten = false
        var failureStage = MetadataSidecarPersistenceResult.FailureStage.xmpSidecar
    }

    let facade: MCPAutomationFacade
    var hooks = Hooks()

    /// The supplied snapshot must come from the original reviewed capture. Callbacks run
    /// synchronously at the physical boundary; the snapshot advances only after an exact
    /// installed-generation receipt. Later-photo validation must retain original witnesses.
    /// `retainPreparedMutation` must durably retain the exact candidate bytes and inode
    /// together with the original reviewed intent before returning.
    func execute(_ request: PrimaryDevelopWriteRequest, expected: MCPPhotoCarrierSnapshot,
                 reservation: MCPProcessReservationLease,
                 validateCommitAuthority: @escaping @Sendable (Stage, MCPPhotoCarrierSnapshot) throws -> Void,
                 retainPreparedMutation: @escaping @Sendable (Stage, MCPPreparedXMPIdentity, Data) throws -> Void) async -> Result {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: request.imageURL)) { @MetadataSidecarFilesystemActor in
                await self.perform(request, expected: expected, reservation: reservation,
                    cancellation: cancellation, validateCommitAuthority: validateCommitAuthority,
                    retainPreparedMutation: retainPreparedMutation)
            }
        } onCancel: { cancellation.cancel() }
    }

    @MetadataSidecarFilesystemActor
    private func perform(_ request: PrimaryDevelopWriteRequest, expected: MCPPhotoCarrierSnapshot,
                         reservation: MCPProcessReservationLease, cancellation: Cancellation,
                         validateCommitAuthority: @escaping @Sendable (Stage, MCPPhotoCarrierSnapshot) throws -> Void,
                         retainPreparedMutation: @escaping @Sendable (Stage, MCPPreparedXMPIdentity, Data) throws -> Void) async -> Result {
        let progress = Progress()
        var result = PrimaryDevelopWriteResult(requestID: request.id)
        var xmpMetadata: IPTCMetadata?
        do {
            try cancellation.check()
            try Task.checkCancellation()
            guard request.mode == .writeToXMPSidecar, request.predecessor == nil,
                  request.captureFailure == nil, request.watermarkDependencies.isEmpty,
                  PrimaryDevelopWriteRequestBuilder.watermarkDependencyIDs(edited: request.edited,
                    previous: request.previous, original: request.original).isEmpty,
                  (request.embeddedBaseline?.cameraRaw?.watermarkLayers ?? []).isEmpty,
                  !request.sidecar.pendingChanges, request.sidecar.orientationDraft == nil,
                  request.sidecar.metadata == request.edited else { throw Failure.unsupported }
            guard reservation.coversPhoto(request.imageURL), expected.target.url == request.imageURL,
                  request.folderURL == request.imageURL.deletingLastPathComponent(),
                  let source = request.sourceRevision,
                  source.canonicalURL == request.imageURL,
                  source.sha256 == SHA256.hash(data: expected.sourceBytes).map({ String(format: "%02x", $0) }).joined(),
                  request.expectedXMP?.data == expected.xmpBytes, request.expectedXMP != nil else {
                throw Failure.changedEvidence
            }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let current = try expected.appSidecarBytes.map { try decoder.decode(MetadataSidecar.self, from: $0) }
            let sidecars = MetadataSidecarService()
            guard current?.orientationDraft == nil,
                  (current == nil && request.expectedRecord == nil)
                    || (current != nil && request.expectedRecord != nil
                        && sidecars.fieldMutationRecordsEqual(current!, request.expectedRecord!)) else {
                throw Failure.changedEvidence
            }
            let configuration = try facade.authorizationStore.load()
            let initial = try facade.withPhotoSnapshot(path: request.imageURL.path, reservation: reservation) { $0 }
            try requireSame(initial, expected)
            try validateCommitAuthority(.xmp, expected)

            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(
                "develop-rooted-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            let stagedPhoto = staging.appendingPathComponent(request.imageURL.lastPathComponent)
            // The production angled-crop codec reads sensor aspect from the source header.
            // Give it retained bytes, never another read of the live photo pathname.
            try expected.sourceBytes.write(to: stagedPhoto)
            let xmp = XMPSidecarService()
            let stagedXMP = xmp.sidecarURL(for: stagedPhoto)
            if let bytes = expected.xmpBytes { try bytes.write(to: stagedXMP) }
            _ = try await xmp.writeMetadataInHeldTransaction(request.edited, for: stagedPhoto,
                expectedSnapshot: .init(data: expected.xmpBytes), onlyIfExisting: false,
                replaceDevelopSettings: request.replaceDevelop, replaceOrientation: request.replaceOrientation)
            let candidateXMP = try Data(contentsOf: stagedXMP)
            guard !candidateXMP.isEmpty, candidateXMP.count <= 8_388_608,
                  let parsed = xmp.loadSidecar(for: stagedPhoto),
                  IPTCMetadataVerifier.compare(expected: request.edited, actual: parsed).isMatch,
                  !request.replaceOrientation || parsed.exifOrientation == request.edited.exifOrientation else {
                throw Failure.verification
            }
            // Develop's structured codec is validated by parsing and exact staged-byte
            // publication. Raw CameraRaw equality would reject inferred defaults/mask IDs.
            xmpMetadata = parsed
            let privateDirectory = staging.appendingPathComponent(".photo_metadata", isDirectory: true)
            try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: false)
            let stagedJSON = privateDirectory.appendingPathComponent("\(stagedPhoto.lastPathComponent).meta.json")
            if let bytes = expected.appSidecarBytes { try bytes.write(to: stagedJSON) }
            let saved = try sidecars.saveSidecar(request.sidecar, for: stagedPhoto, in: staging)
            let candidateJSON = try Data(contentsOf: stagedJSON)
            let decoded = try decoder.decode(MetadataSidecar.self, from: candidateJSON)
            guard !candidateJSON.isEmpty, candidateJSON.count <= 8_388_608,
                  !decoded.pendingChanges, decoded.orientationDraft == nil,
                  sidecars.fieldMutationRecordsEqual(saved, decoded) else { throw Failure.verification }
            if let original = expected.appSidecarBytes, let current {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                guard try MCPIPTCPatchExecutionService.preservesUnknownFields(original: original,
                    known: encoder.encode(current), installed: candidateJSON) else { throw Failure.verification }
            }
            try hooks.afterStaging()
            try cancellation.check()

            // No await follows staging. Publication and receipt collection remain in one
            // synchronous transaction, including cancellation and post-install failures.
            @Sendable func authority(_ stage: Stage, _ snapshot: MCPPhotoCarrierSnapshot) throws {
                try cancellation.check()
                guard reservation.coversPhoto(request.imageURL),
                      try facade.authorizationStore.load() == configuration else { throw Failure.changedEvidence }
                try validateCommitAuthority(stage, snapshot)
            }
            try hooks.beforeXMP()
            try facade.installXMPSidecar(data: candidateXMP, expected: expected,
                reservation: reservation, beforeInstall: { try authority(.xmp, expected) },
                beforeMutation: { identity in
                    try authority(.xmp, expected)
                    try retainPreparedMutation(.xmp, identity, candidateXMP)
                    progress.preparedXMP = identity
                    try authority(.xmp, expected)
                    progress.xmpMayHaveWritten = true
                }, afterInstall: { installed in
                    progress.installedXMP = installed
                })
            try hooks.afterXMP()
            guard let installedXMP = progress.installedXMP else { throw Failure.verification }
            guard installedXMP.sourceRevision == expected.sourceRevision,
                  installedXMP.sourceBytes == expected.sourceBytes,
                  installedXMP.xmpBytes == candidateXMP,
                  installedXMP.appSidecarRevision == expected.appSidecarRevision,
                  installedXMP.appSidecarBytes == expected.appSidecarBytes else { throw Failure.verification }
            progress.failureStage = .metadataSidecar
            try hooks.beforeJSON()
            try facade.installPendingDraft(data: candidateJSON, expected: installedXMP,
                reservation: reservation, onDestination: { progress.appSidecarURL = $0 },
                beforeInstall: { try authority(.appSidecar, installedXMP) },
                beforeMutation: { identity in
                    try authority(.appSidecar, installedXMP)
                    try retainPreparedMutation(.appSidecar, identity, candidateJSON)
                    progress.preparedApp = identity
                    try authority(.appSidecar, installedXMP)
                    progress.appMayHaveWritten = true
                }, afterInstall: { installed in
                    progress.installedApp = installed
                })
            try hooks.afterJSON()
            guard let installedApp = progress.installedApp else { throw Failure.verification }
            try authority(.verification, installedApp)
            let final = try facade.withPhotoSnapshot(path: request.imageURL.path, reservation: reservation) { $0 }
            try requireSame(final, installedApp)
            guard final.sourceRevision == expected.sourceRevision, final.sourceBytes == expected.sourceBytes,
                  final.xmpSidecarRevision == installedXMP.xmpSidecarRevision,
                  final.xmpBytes == candidateXMP, final.appSidecarBytes == candidateJSON else {
                throw Failure.verification
            }
            try authority(.verification, final)
            let terminal = try facade.withPhotoSnapshot(path: request.imageURL.path, reservation: reservation) { $0 }
            try requireSame(terminal, final)
            try cancellation.check()
            guard try facade.authorizationStore.load() == configuration else { throw Failure.changedEvidence }
            result.sourceRevision = source
            result.completion = .init(installedSidecar: decoded, wroteXMPSidecar: true,
                wasCancelled: false, failure: nil, writtenXMPMetadata: parsed,
                writtenXMPSnapshot: .init(data: candidateXMP))
        } catch {
            result.wasCancelled = error is CancellationError
            result.failure = error.localizedDescription
            result.sourceRevision = progress.xmpMayHaveWritten ? request.sourceRevision : nil
            result.completion = .init(installedSidecar: nil,
                wroteXMPSidecar: progress.xmpMayHaveWritten, wasCancelled: result.wasCancelled,
                failure: result.wasCancelled ? nil : .init(stage: progress.failureStage, message: error.localizedDescription),
                committedButUnverifiedSidecarURL: progress.appMayHaveWritten ? progress.appSidecarURL : nil,
                writtenXMPMetadata: progress.installedXMP == nil ? nil : xmpMetadata,
                writtenXMPSnapshot: progress.installedXMP.map { .init(data: $0.xmpBytes) })
        }
        return Result(writeResult: result, installedXMP: progress.installedXMP,
            installedAppSidecar: progress.installedApp, preparedXMP: progress.preparedXMP,
            preparedAppSidecar: progress.preparedApp, appSidecarURL: progress.appSidecarURL)
    }

    private func requireSame(_ actual: MCPPhotoCarrierSnapshot, _ expected: MCPPhotoCarrierSnapshot) throws {
        guard actual.target == expected.target, actual.sourceRevision == expected.sourceRevision,
              actual.xmpSidecarRevision == expected.xmpSidecarRevision,
              actual.appSidecarRevision == expected.appSidecarRevision,
              actual.sourceBytes == expected.sourceBytes, actual.xmpBytes == expected.xmpBytes,
              actual.appSidecarBytes == expected.appSidecarBytes else { throw Failure.changedEvidence }
    }
}
