import CryptoKit
import Foundation

/// Synchronous recovery evidence for a single independently reviewed photo. This store
/// grants no consent, performs no carrier writes and never reconstructs an executable intent.
/// Use on the retained filesystem executor, including the writer's physical callbacks.
nonisolated struct DevelopTemplateRootedMutationStore: Sendable {
    enum Failure: Error, Equatable { case invalidMaterial, corruptJournal, changedMaterial, invalidTransition }
    enum Carrier: String, Codable, Sendable { case xmp, appSidecar }

    struct Material: Codable, Equatable, Sendable {
        let batchID: UUID
        let requestID: UUID
        let evidenceData: Data
        let photoURL: URL
        let rootID: UUID
        let sourceIdentity: MCPFileIdentity
        let sourceRevision: String
        let originalXMPRevision: String
        let originalAppRevision: String
        let originalXMP: Data?
        let originalApp: Data?

        init(evidence: DevelopTemplateBatchAdmissionEvidence, request: PrimaryDevelopWriteRequest,
             original: MCPPhotoCarrierSnapshot) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(evidence)
            guard evidence.formatVersion == 1,
                  data.count <= DevelopTemplateBatchAdmissionStore.maximumEvidenceBytes,
                  let photo = evidence.photos.first(where: { $0.requestID == request.id }),
                  photo.url == request.imageURL, original.target.url == photo.url,
                  photo.rootID == original.target.rootID, photo.targetIdentity == original.target.identity,
                  photo.sourceRevision == original.sourceRevision,
                  photo.xmpRevision == original.xmpSidecarRevision, photo.appRevision == original.appSidecarRevision,
                  let intent = try JSONSerialization.jsonObject(with: evidence.originalIntentData) as? [String: Any],
                  let photos = intent["photos"] as? [[String: Any]],
                  let captured = photos.first(where: { $0["requestID"] as? String == request.id.uuidString }),
                  try JSONSerialization.data(withJSONObject: captured, options: [.sortedKeys])
                    == JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with:
                        encoder.encode(PrimaryDevelopRecoveryPayload(request, result: nil))), options: [.sortedKeys]) else {
                throw Failure.invalidMaterial
            }
            batchID = evidence.batchID; requestID = request.id; evidenceData = data
            photoURL = photo.url; rootID = photo.rootID; sourceIdentity = photo.targetIdentity
            sourceRevision = photo.sourceRevision; originalXMPRevision = photo.xmpRevision
            originalAppRevision = photo.appRevision; originalXMP = original.xmpBytes; originalApp = original.appSidecarBytes
            guard isValid else { throw Failure.invalidMaterial }
        }

        fileprivate var isValid: Bool {
            guard evidenceData.count <= DevelopTemplateBatchAdmissionStore.maximumEvidenceBytes,
                  let evidence = try? JSONDecoder().decode(DevelopTemplateBatchAdmissionEvidence.self, from: evidenceData),
                  evidence.formatVersion == 1, evidence.batchID == batchID,
                  !evidence.templateRevision.isEmpty,
                  !evidence.configurationRevision.isEmpty, evidence.configurationRevision.utf8.count <= 4_096,
                  !evidence.photos.isEmpty, evidence.photos.count <= DevelopTemplateBatchIntent.maximumPhotos,
                  Set(evidence.photos.map(\.requestID)).count == evidence.photos.count,
                  let photo = evidence.photos.first(where: { $0.requestID == requestID }),
                  photo.url == photoURL, photo.rootID == rootID, photo.targetIdentity == sourceIdentity,
                  photo.sourceRevision == sourceRevision, photo.xmpRevision == originalXMPRevision,
                  photo.appRevision == originalAppRevision, photoURL.isFileURL,
                  sourceIdentity.device != 0, sourceIdentity.inode != 0,
                  !sourceRevision.isEmpty, !originalXMPRevision.isEmpty, !originalAppRevision.isEmpty,
                  (originalXMP?.count ?? 0) <= Int(MCPPhotoCarrierSnapshot.maximumXMPBytes),
                  (originalApp?.count ?? 0) <= Int(MCPPhotoCarrierSnapshot.maximumXMPBytes),
                  let intent = try? JSONSerialization.jsonObject(with: evidence.originalIntentData) as? [String: Any],
                  intent["formatVersion"] as? Int == 1, intent["kind"] as? String == "Develop template batch",
                  intent["batchID"] as? String == batchID.uuidString,
                  intent["templateID"] as? String == evidence.template.id.uuidString,
                  intent["templateRevision"] as? String == evidence.templateRevision,
                  let photos = intent["photos"] as? [[String: Any]], photos.count == evidence.photos.count,
                  photos.map({ $0["requestID"] as? String }) == evidence.photos.map({ Optional($0.requestID.uuidString) }),
                  let captured = photos.first(where: { $0["requestID"] as? String == requestID.uuidString }),
                  captured["imageURL"] as? String == photoURL.absoluteString,
                  captured["expectedXMPKnown"] as? Bool == true,
                  captured["expectedXMPData"] as? String == originalXMP?.base64EncodedString() else { return false }
            guard captured["expectedRecordExisted"] as? Bool == (originalApp != nil) else { return false }
            if let originalApp {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                guard let original = try? decoder.decode(MetadataSidecar.self, from: originalApp),
                      let object = captured["expectedRecord"],
                      let bytes = try? JSONSerialization.data(withJSONObject: object),
                      let expected = try? JSONDecoder().decode(VariableRecoverySidecar.self, from: bytes),
                      MetadataSidecarService().fieldMutationRecordsEqual(original, expected.record) else { return false }
            } else if captured["expectedRecord"] != nil { return false }
            return true
        }
    }

    struct Mutation: Codable, Equatable, Sendable {
        let carrier: Carrier
        let identity: MCPPreparedXMPIdentity
        let candidate: Data
        let destination: URL
        var installedRevision: String?
    }
    struct Record: Codable, Equatable, Sendable {
        let material: Material
        var mutations: [Mutation]
        /// Even app installation is physical evidence, never a verified batch completion.
        var hasUnresolvedPreparation: Bool { mutations.last?.installedRevision == nil && !mutations.isEmpty }
    }
    private struct Envelope: Codable {
        let formatVersion: Int
        let payload: Data
        let sha256: String
    }
    private let persistence: AutomationOperationPersistence
    init(directory: URL) {
        persistence = .init(directory: directory, maximumBytes: 100_663_296)
    }

    /// Retaining an identical original binding is idempotent; it never clears progress.
    func retain(_ material: Material) throws {
        guard material.isValid else { throw Failure.invalidMaterial }
        try persistence.transaction { bytes in
            if let bytes {
                guard try decode(bytes).material == material else { throw Failure.changedMaterial }
                return ((), bytes)
            }
            return ((), try encode(.init(material: material, mutations: [])))
        }
    }

    func recordPrepared(_ material: Material, carrier: Carrier,
                        identity: MCPPreparedXMPIdentity, candidate: Data, destination: URL) throws {
        try update(material) { record in
            guard Self.validDestination(destination, carrier: carrier, photo: material.photoURL), !candidate.isEmpty, candidate.count <= Int(MCPPhotoCarrierSnapshot.maximumXMPBytes),
                  identity.size == Int64(candidate.count), identity.file.device != 0, identity.file.inode != 0,
                  identity.modificationNanoseconds >= 0, identity.modificationNanoseconds < 1_000_000_000,
                  (record.mutations.isEmpty && carrier == .xmp)
                    || (record.mutations.count == 1 && record.mutations[0].installedRevision != nil && carrier == .appSidecar) else {
                throw Failure.invalidTransition
            }
            record.mutations.append(.init(carrier: carrier, identity: identity, candidate: candidate, destination: destination))
        }
    }

    func recordInstalled(_ material: Material, carrier: Carrier, snapshot: MCPPhotoCarrierSnapshot) throws {
        try update(material) { record in
            guard let pending = record.mutations.last, pending.carrier == carrier,
                  pending.installedRevision == nil,
                  snapshot.target.url == material.photoURL, snapshot.target.rootID == material.rootID,
                  snapshot.target.identity == material.sourceIdentity, snapshot.sourceRevision == material.sourceRevision else {
                throw Failure.invalidTransition
            }
            if carrier == .xmp {
                guard snapshot.xmpBytes == pending.candidate, snapshot.preparedXMPIdentity == pending.identity,
                      snapshot.appSidecarRevision == material.originalAppRevision,
                      snapshot.appSidecarBytes == material.originalApp else { throw Failure.invalidTransition }
            } else {
                guard record.mutations.count == 2,
                      snapshot.appSidecarBytes == pending.candidate, snapshot.preparedAppIdentity == pending.identity,
                      snapshot.xmpBytes == record.mutations[0].candidate,
                      snapshot.xmpSidecarRevision == record.mutations[0].installedRevision else { throw Failure.invalidTransition }
            }
            let revision = carrier == .xmp ? snapshot.xmpSidecarRevision : snapshot.appSidecarRevision
            guard !revision.isEmpty, revision.utf8.count <= 4_096,
                  revision != (carrier == .xmp ? material.originalXMPRevision : material.originalAppRevision) else {
                throw Failure.invalidTransition
            }
            record.mutations[record.mutations.count - 1].installedRevision = revision
        }
    }

    func load() throws -> Record? {
        try persistence.transaction(readOnly: true) { bytes in
            (try bytes.map(decode), bytes ?? Data())
        }
    }
    private func update(_ material: Material, body: (inout Record) throws -> Void) throws {
        try persistence.transaction { bytes in
            guard let bytes else { throw Failure.invalidTransition }
            var record = try decode(bytes)
            guard record.material == material else { throw Failure.changedMaterial }
            try body(&record)
            return ((), try encode(record))
        }
    }
    private func encode(_ record: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        return try encoder.encode(Envelope(formatVersion: 1, payload: data, sha256: Self.hash(data)))
    }
    private func decode(_ bytes: Data) throws -> Record {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: bytes), envelope.formatVersion == 1,
              envelope.sha256 == Self.hash(envelope.payload),
              let record = try? JSONDecoder().decode(Record.self, from: envelope.payload),
              record.material.isValid, record.mutations.count <= 2 else { throw Failure.corruptJournal }
        for (index, mutation) in record.mutations.enumerated() {
            guard mutation.carrier == (index == 0 ? .xmp : .appSidecar),
                  Self.validDestination(mutation.destination, carrier: mutation.carrier, photo: record.material.photoURL),
                  !mutation.candidate.isEmpty, mutation.candidate.count <= Int(MCPPhotoCarrierSnapshot.maximumXMPBytes),
                  mutation.identity.size == Int64(mutation.candidate.count),
                  mutation.identity.file.device != 0, mutation.identity.file.inode != 0,
                  mutation.identity.modificationNanoseconds >= 0, mutation.identity.modificationNanoseconds < 1_000_000_000,
                  mutation.installedRevision == nil || (!mutation.installedRevision!.isEmpty
                    && mutation.installedRevision!.utf8.count <= 4_096
                    && mutation.installedRevision != (index == 0 ? record.material.originalXMPRevision : record.material.originalAppRevision)),
                  index == 0 || record.mutations[0].installedRevision != nil else { throw Failure.corruptJournal }
        }
        return record
    }
    private static func validDestination(_ destination: URL, carrier: Carrier, photo: URL) -> Bool {
        if carrier == .xmp { return destination == photo.deletingPathExtension().appendingPathExtension("xmp") }
        let directory = photo.deletingLastPathComponent().appendingPathComponent(".photo_metadata")
        return destination == directory.appendingPathComponent(photo.lastPathComponent + ".meta.json")
            || destination == directory.appendingPathComponent(photo.deletingPathExtension().lastPathComponent + ".meta.json")
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension DevelopTemplateRootedWriteService {
    /// Retain original review material before staging, then every prepared/installed
    /// generation synchronously. A journal failure stops the next physical carrier.
    func execute(_ request: PrimaryDevelopWriteRequest, expected: MCPPhotoCarrierSnapshot,
                 reservation: MCPProcessReservationLease,
                 evidence: DevelopTemplateBatchAdmissionEvidence,
                 mutationStore: DevelopTemplateRootedMutationStore,
                 validateCommitAuthority: @escaping @Sendable (Stage, MCPPhotoCarrierSnapshot) throws -> Void) async throws -> Result {
        let material = try DevelopTemplateRootedMutationStore.Material(evidence: evidence, request: request, original: expected)
        // This adapter is called on a retained Dispatch executor by the future batch bridge.
        // Original retention runs inside the writer's first synchronous authority boundary.
        return await execute(request, expected: expected, reservation: reservation, validateCommitAuthority: { stage, snapshot in
            try validateCommitAuthority(stage, snapshot)
            try mutationStore.retain(material)
        }, retainInstalledMutation: { stage, snapshot in
            try mutationStore.recordInstalled(material, carrier: stage == .xmp ? .xmp : .appSidecar, snapshot: snapshot)
        }, retainPreparedMutation: { stage, identity, candidate, destination in
            try mutationStore.recordPrepared(material, carrier: stage == .xmp ? .xmp : .appSidecar,
                identity: identity, candidate: candidate, destination: destination)
        })
    }
}
