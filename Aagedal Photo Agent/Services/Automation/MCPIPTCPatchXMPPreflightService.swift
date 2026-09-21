import CryptoKit
import Foundation
import SwiftMediaMetadata

/// Native, read-only candidate verification. Temporary XMP bytes are never an installation
/// capability and are removed before returning; no approval is consumed or source written.
nonisolated struct MCPIPTCPatchXMPPreflightService: Sendable {
    struct Report: Sendable, Equatable {
        let planID: String
        let targetPath: String
        let stagedByteCount: Int
        let stagedSHA256: String
        let warnings: [String]
    }

    struct Hooks: Sendable {
        var afterStaging: @Sendable (URL) throws -> Void = { _ in }
    }

    private let plans: MCPIPTCPatchPlanStore
    private let facade: MCPAutomationFacade
    private let hooks: Hooks

    init(plans: MCPIPTCPatchPlanStore, facade: MCPAutomationFacade, hooks: Hooks = .init()) {
        self.plans = plans; self.facade = facade; self.hooks = hooks
    }

    @MetadataSidecarFilesystemActor
    func inspect(planID: String) async throws -> Report {
        try Task.checkCancellation()
        let binding = try plans.localApprovalBinding(planID: planID, facade: facade, now: Date())
        guard let path = binding.preview.objectValue?["canonicalPath"]?.stringValue else {
            throw MCPIPTCPatchPlanStore.Failure.invalidArguments
        }
        let photo = URL(fileURLWithPath: path)
        let reservation = try MCPProcessReservation.acquirePhoto(photo)
        defer { reservation.release() }
        let request = try plans.requestForDraftExecution(planID: planID, facade: facade, reservation: reservation)
        let snapshot = try facade.withPhotoSnapshot(path: path, reservation: reservation) { $0 }
        let read = try MCPMetadataSnapshotReader.read(snapshot)
        var expected = read.resolution.metadata
        for operation in request.operations { try operation.apply(to: &expected) }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("iptc-xmp-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedPhoto = staging.appendingPathComponent(photo.lastPathComponent)
        let service = XMPSidecarService()
        let stagedXMP = service.sidecarURL(for: stagedPhoto)
        if let original = snapshot.xmpBytes { try original.write(to: stagedXMP) }
        // This production transaction preserves the exact existing Develop and orientation
        // properties. It needs no source file when neither technical replacement is requested.
        _ = try await service.writeMetadataInHeldTransaction(expected, for: stagedPhoto,
            expectedSnapshot: .init(data: snapshot.xmpBytes), onlyIfExisting: false,
            replaceDevelopSettings: false, replaceOrientation: false)
        try hooks.afterStaging(stagedXMP)
        try Task.checkCancellation()
        let bytes = try Data(contentsOf: stagedXMP)
        guard !bytes.isEmpty, bytes.count <= 8_388_608,
              let actual = service.loadSidecar(fromData: bytes) else { throw VerificationFailure() }
        // Capture Date is a read-only source fact; its original carrier remains byte-identical.
        guard IPTCMetadataVerificationField.writableFields.allSatisfy({
            IPTCMetadataVerifier.canonicalValue(for: $0, in: expected)
                == IPTCMetadataVerifier.canonicalValue(for: $0, in: actual)
        }) else { throw VerificationFailure() }
        try Self.verifyPreservation(before: snapshot.xmpBytes, after: bytes)
        // Staging suspends on the filesystem actor. Recheck authority, expiry and every
        // carrier afterwards, including same-byte pathname/identity substitutions.
        _ = try plans.requestForDraftExecution(planID: planID, facade: facade, reservation: reservation)
        let after = try facade.withPhotoSnapshot(path: path, reservation: reservation) { $0 }
        guard snapshot.sourceRevision == after.sourceRevision,
              snapshot.xmpSidecarRevision == after.xmpSidecarRevision,
              snapshot.appSidecarRevision == after.appSidecarRevision,
              snapshot.sourceBytes == after.sourceBytes, snapshot.xmpBytes == after.xmpBytes,
              snapshot.appSidecarBytes == after.appSidecarBytes else { throw VerificationFailure() }
        var warnings = [
            "Temporary XMP candidate only. No live write support, publication approval, or durable recovery installation is established.",
            "Preservation covers parsed XMP properties and production editorial semantics; it is not proof of arbitrary XML extension preservation.",
            "C2PA trust and publication consequences have not been assessed.",
            "This evaluates an XMP sidecar candidate, not embedded metadata support or the selected publication mode.",
        ]
        if read.resolution.hasPendingChanges {
            warnings.append("The candidate includes every effective pending draft value, including changes outside this patch. Publishing it would promote those pending changes too.")
        }
        return Report(planID: planID, targetPath: service.sidecarURL(for: photo).path,
            stagedByteCount: bytes.count,
            stagedSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            warnings: warnings)
    }

    static func verifyPreservation(before: Data?, after: Data) throws {
        let old = try before.map { try XMPReader.readFromXML($0) } ?? XMPData()
        let new = try XMPReader.readFromXML(after)
        // Use the existing semantic preservation engine, permitting only the production
        // CreatorTool stamp. Keep Camera Raw, faces, unrelated properties and C2PA identities.
        let policy = MetadataPreservationSnapshotPolicy(treatsCameraRawAsPreservable: true,
            excludesRenderedEXIF: false, excludesRendererAuthoredXMP: true)
        func snapshot(_ xmp: XMPData) -> MetadataPreservationSnapshot {
            var carrier = ImageMetadata(format: .jpeg)
            carrier.xmp = xmp
            return MetadataPreservationSnapshotBuilder.makeSnapshot(from: carrier, policy: policy)
        }
        let report = MetadataPreservationComparator.compare(source: snapshot(old), staged: snapshot(new))
        guard report.domains.allSatisfy({ $0.status == .match }),
              [.absentFromBoth, .carriedUnchanged].contains(report.c2paConsequence) else { throw VerificationFailure() }
        // The generic preservation policy excludes writable orientation. This descriptive
        // candidate grants no technical intent, so both original orientation tags must match.
        for namespace in [XMPNamespace.tiff, XMPNamespace.exif] {
            guard old.simpleValue(namespace: namespace, property: "Orientation")
                    == new.simpleValue(namespace: namespace, property: "Orientation") else { throw VerificationFailure() }
        }
    }

    private struct VerificationFailure: LocalizedError {
        var errorDescription: String? {
            "The temporary XMP candidate could not verify every editorial value and preserved property. No live metadata was written."
        }
    }
}
