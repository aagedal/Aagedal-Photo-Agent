import CryptoKit
import Foundation

/// Durable recovery material and verified completion dispositions. This store neither grants
/// publication consent nor reads, installs, restores or deletes a live carrier. The caller binds
/// disposition to retained root descriptors, exact carrier identities and native consent.
/// Checksums detect corruption, not tampering by another process running as this account.
nonisolated struct MCPIPTCPatchXMPRecoveryStore: Sendable {
    enum Failure: Error, Equatable { case invalidArguments, occupied, corruptJournal, verification }
    enum Observation: Sendable, Equatable {
        case originalPresent, candidatePresent, conflict
    }

    struct Binding: Codable, Sendable, Equatable {
        let sourceRevision: String
        let xmpSidecarRevision: String
        let appSidecarRevision: String
        let authorizationRevision: UUID
    }

    struct Material: Codable, Sendable, Equatable {
        let id: UUID
        let planID: String
        let targetPath: String
        var sourcePath: String? = nil
        let binding: Binding
        let original: Data?
        let candidate: Data
        /// Missing in legacy passive journals. A publication admission must retain both
        /// this wrapper (whose nil original means absent) and the exact consent identity.
        let appSidecarRecovery: AppSidecarRecovery?
        let publicationApprovalID: UUID?
    }

    struct AppSidecarRecovery: Codable, Sendable, Equatable {
        let original: Data?
        /// Exact reconciled app history prepared before any live carrier mutation.
        let candidate: Data?

        init(original: Data?, candidate: Data? = nil) {
            self.original = original; self.candidate = candidate
        }
    }

    struct InstalledCarriers: Codable, Sendable, Equatable {
        let xmpRevision: String
        let appRevision: String?
    }

    struct RestoredCarriers: Codable, Sendable, Equatable {
        let xmpRevision: String
        let appRevision: String?
    }

    /// Exact staged generation for the next carrier mutation. Absence is deliberately
    /// unsupported: a missing file cannot authenticate an interrupted unlink.
    struct PreparedMutation: Codable, Sendable, Equatable {
        enum Purpose: String, Codable, Sendable { case appPublication, xmpRestoration, appRestoration }
        let purpose: Purpose
        let identity: MCPPreparedXMPIdentity
    }

    private struct MutationProgress: Codable {
        let material: Material
        let installed: InstalledCarriers
        let restored: RestoredCarriers?
        let mutation: PreparedMutation
    }

    func recordPreparedMutation(_ expected: Material, mutation: PreparedMutation,
                                verify: () throws -> Void) throws {
        try persistence.transaction { bytes in
            guard let bytes else { throw Failure.verification }
            let record = try decodeRecord(bytes)
            guard !record.resolved, record.material == expected, let installed = record.installed,
                  record.preparedMutation == nil, record.preparedXMP == nil,
                  validMutation(mutation, material: expected, installed: installed, restored: record.restored)
            else { throw Failure.verification }
            try verify()
            let encoder = JSONEncoder()
            let payload = try encoder.encode(MutationProgress(material: expected, installed: installed,
                restored: record.restored, mutation: mutation))
            return ((), try encoder.encode(Envelope(version: 10, payload: payload, sha256: Self.digest(payload))))
        }
    }

    /// A staged inode that never reached its destination can be abandoned only after the
    /// caller verifies the exact receipted carrier generations still remain rooted and live.
    func discardUnrenamedMutation(_ expected: Material, verify: () throws -> Void) throws {
        try persistence.transaction { bytes in
            guard let bytes else { throw Failure.verification }
            let record = try decodeRecord(bytes)
            guard !record.resolved, record.material == expected, record.preparedMutation != nil,
                  let installed = record.installed else { throw Failure.verification }
            try verify()
            let encoder = JSONEncoder()
            let payload: Data
            let version: Int
            if let restored = record.restored {
                guard restored.appRevision == nil else { throw Failure.verification }
                version = 7
                payload = try encoder.encode(RestorationProgress(material: expected, installed: installed, restored: restored))
            } else {
                version = 6
                payload = try encoder.encode(PublicationProgress(material: expected, installed: installed))
            }
            return ((), try encoder.encode(Envelope(version: version, payload: payload, sha256: Self.digest(payload))))
        }
    }

    private func validMutation(_ mutation: PreparedMutation, material: Material,
                               installed: InstalledCarriers, restored: RestoredCarriers?) -> Bool {
        let bytes: Data?
        switch mutation.purpose {
        case .appPublication:
            guard installed.appRevision == nil, restored == nil else { return false }
            bytes = material.appSidecarRecovery?.candidate
        case .xmpRestoration:
            guard restored == nil else { return false }
            bytes = material.original
        case .appRestoration:
            guard installed.appRevision != nil, restored != nil, restored?.appRevision == nil else { return false }
            bytes = material.appSidecarRecovery?.original
        }
        guard let bytes else { return false }
        return mutation.identity.file.device != 0 && mutation.identity.file.inode != 0
            && mutation.identity.size == Int64(bytes.count)
            && (0..<1_000_000_000).contains(mutation.identity.modificationNanoseconds)
    }

    private struct RestorationProgress: Codable {
        let material: Material
        let installed: InstalledCarriers
        let restored: RestoredCarriers
        private enum CodingKeys: String, CodingKey { case material = "restorationMaterial", installed, restored }
    }

    /// Progress is committed only after a rooted mutation verified its exact generation.
    /// Interrupted renames require retained prepared identity, never bytes alone.
    func recordRestored(_ expected: Material, restored: RestoredCarriers,
                        complete: Bool = false, verify: () throws -> Void) throws {
        try persistence.transaction { bytes in
            guard let bytes else { throw Failure.verification }
            let record = try decodeRecord(bytes)
            guard !record.resolved, record.material == expected, let installed = record.installed,
                  !restored.xmpRevision.isEmpty, restored.xmpRevision.utf8.count <= 1024,
                  restored.appRevision.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true,
                  complete == (restored.appRevision != nil) else { throw Failure.verification }
            if let mutation = record.preparedMutation {
                guard (mutation.purpose == .xmpRestoration && restored.appRevision == nil)
                    || (mutation.purpose == .appRestoration && complete) else { throw Failure.verification }
            }
            if let previous = record.restored {
                guard previous.xmpRevision == restored.xmpRevision,
                      previous.appRevision == nil || previous == restored else { throw Failure.verification }
            } else {
                guard restored.appRevision == nil else { throw Failure.verification }
            }
            try verify()
            let encoder = JSONEncoder()
            let payload = try encoder.encode(RestorationProgress(material: expected, installed: installed, restored: restored))
            return ((), try encoder.encode(Envelope(version: complete ? 8 : 7, payload: payload, sha256: Self.digest(payload))))
        }
    }

    private struct PublicationProgress: Codable {
        let material: Material
        let installed: InstalledCarriers
        private enum CodingKeys: String, CodingKey { case material = "incompleteMaterial", installed }
    }

    private struct PreparedPublication: Codable {
        let material: Material
        let xmpIdentity: MCPPreparedXMPIdentity
    }

    /// Persist the identity of the retained staged XMP inode before its rename. This is
    /// evidence of intent only; the live rooted carrier must still match it exactly.
    func recordPreparedXMP(_ expected: Material, xmpIdentity: MCPPreparedXMPIdentity,
                           verify: () throws -> Void) throws {
        try persistence.transaction { bytes in
            guard let bytes else { throw Failure.verification }
            let record = try decodeRecord(bytes)
            guard !record.resolved, record.material == expected,
                  record.installed == nil, record.restored == nil,
                  record.preparedXMP == nil,
                  expected.appSidecarRecovery?.candidate != nil,
                  xmpIdentity.file.device != 0, xmpIdentity.file.inode != 0,
                  xmpIdentity.size == Int64(expected.candidate.count),
                  (0..<1_000_000_000).contains(xmpIdentity.modificationNanoseconds) else { throw Failure.verification }
            try verify()
            let encoder = JSONEncoder()
            let payload = try encoder.encode(PreparedPublication(material: expected, xmpIdentity: xmpIdentity))
            return ((), try encoder.encode(Envelope(version: 9, payload: payload, sha256: Self.digest(payload))))
        }
    }

    struct VerifiedDisposition: Codable, Sendable, Equatable {
        let material: Material
        var installed: InstalledCarriers? = nil
    }

    /// Durable identity evidence only. A receipt never authorizes restoration by itself.
    func loadInstalledCarriers() throws -> InstalledCarriers? {
        try persistence.transaction(readOnly: true) { bytes in
            let record = try bytes.map(decodeRecord)
            return (record?.installed, bytes ?? Data())
        }
    }

    /// Called from the rooted installer while its installed descriptor remains retained.
    /// XMP must be recorded first; app history may advance that receipt exactly once.
    func recordInstalled(_ expected: Material, installed: InstalledCarriers,
                         verify: () throws -> Void) throws {
        try persistence.transaction { bytes in
            guard let bytes else { throw Failure.verification }
            let record = try decodeRecord(bytes)
            guard !record.resolved, record.restored == nil, record.material == expected,
                  expected.appSidecarRecovery?.candidate != nil,
                  !installed.xmpRevision.isEmpty, installed.xmpRevision.utf8.count <= 1024,
                  installed.appRevision.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true,
                  installed.xmpRevision != expected.binding.xmpSidecarRevision,
                  installed.appRevision != expected.binding.appSidecarRevision else { throw Failure.verification }
            if record.preparedXMP != nil, installed.appRevision != nil { throw Failure.verification }
            if let mutation = record.preparedMutation {
                guard mutation.purpose == .appPublication, installed.appRevision != nil else { throw Failure.verification }
            }
            if let previous = record.installed {
                guard previous.xmpRevision == installed.xmpRevision,
                      previous.appRevision == nil || previous == installed else { throw Failure.verification }
            } else {
                guard installed.appRevision == nil else { throw Failure.verification }
            }
            try verify()
            let encoder = JSONEncoder()
            let payload = try encoder.encode(PublicationProgress(material: expected, installed: installed))
            return ((), try encoder.encode(Envelope(version: 6, payload: payload, sha256: Self.digest(payload))))
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let payload: Data
        let sha256: String
    }

    private let persistence: AutomationOperationPersistence
    private let maximumCarrierBytes: Int

    /// Use an application-private parent. A dedicated child prevents collision with the
    /// operation registry's filenames. At most one unresolved recovery record is retained;
    /// replacement by a different operation fails closed instead of evicting original bytes.
    init(directory: URL, maximumCarrierBytes: Int = 8_388_608) {
        self.maximumCarrierBytes = min(max(0, maximumCarrierBytes), 8_388_608)
        persistence = AutomationOperationPersistence(
            directory: directory.appendingPathComponent("iptc-xmp-recovery", isDirectory: true),
            maximumBytes: 64_000_000)
    }

    @discardableResult
    func stage(id: UUID, planID: String, targetPath: String, binding: Binding, original: Data?, candidate: Data,
               appSidecarRecovery: AppSidecarRecovery? = nil, publicationApprovalID: UUID? = nil,
               sourcePath: String? = nil) throws -> Material {
        try Task.checkCancellation()
        let proposed = Material(id: id, planID: planID, targetPath: targetPath, sourcePath: sourcePath, binding: binding,
            original: original, candidate: candidate, appSidecarRecovery: appSidecarRecovery,
            publicationApprovalID: publicationApprovalID)
        try validate(proposed)
        return try persistence.transaction { existing in
            if let existing {
                let record = try decodeRecord(existing)
                if !record.resolved {
                    guard record.material == proposed else { throw Failure.occupied }
                    return (record.material, existing)
                }
                // A completed operation cannot reacquire authority by replaying its journal.
                guard record.material.id != proposed.id else { throw Failure.occupied }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let payload = try encoder.encode(proposed)
            let data = try encoder.encode(Envelope(version: appSidecarRecovery?.candidate != nil ? 3 : (appSidecarRecovery == nil ? 1 : 2),
                payload: payload, sha256: Self.digest(payload)))
            try Task.checkCancellation()
            return (proposed, data)
        }
    }

    /// Reloads from disk under the shared process lock; no in-memory success receipt can
    /// conceal a missing, substituted, over-permissive or corrupt recovery file.
    func load() throws -> Material? {
        try persistence.transaction(readOnly: true) { bytes in
            let record = try bytes.map(decodeRecord)
            return (record?.resolved == true ? nil : record?.material, bytes ?? Data())
        }
    }

    func loadRecoveryState() throws -> (material: Material, installed: InstalledCarriers?,
                                        restored: RestoredCarriers?, preparedXMP: MCPPreparedXMPIdentity?, preparedMutation: PreparedMutation?)? {
        try persistence.transaction(readOnly: true) { bytes in
            let record = try bytes.map(decodeRecord)
            let state = record.flatMap { $0.resolved ? nil : (material: $0.material, installed: $0.installed,
                restored: $0.restored, preparedXMP: $0.preparedXMP, preparedMutation: $0.preparedMutation) }
            return (state, bytes ?? Data())
        }
    }

    /// Pure byte classification, deliberately not an authorization to restore. Same-byte
    /// inode substitutions and source/app-history changes require separate rooted checks.
    static func observe(_ bytes: Data?, for material: Material) -> Observation {
        if bytes == material.original { return .originalPresent }
        if bytes == material.candidate { return .candidatePresent }
        return .conflict
    }

    /// The most recent verified material is retained for inspection until a new operation
    /// is staged. This is a disposition receipt, never a grant to publish or restore bytes.
    func loadVerifiedDisposition() throws -> VerifiedDisposition? {
        try persistence.transaction(readOnly: true) { bytes in
            let record = try bytes.map(decodeRecord)
            return (record?.verified == true ? record.map { VerifiedDisposition(material: $0.material, installed: $0.installed) } : nil,
                bytes ?? Data())
        }
    }

    /// Successful restoration is a separate disposition, never publication success.
    func loadRestoredDisposition() throws -> Material? {
        try persistence.transaction(readOnly: true) { bytes in
            let record = try bytes.map(decodeRecord)
            return (record?.resolved == true && record?.restored != nil ? record?.material : nil, bytes ?? Data())
        }
    }

    /// Called only in the retained rooted carrier transaction. The verifier must recheck
    /// identities, authorization and both installed candidates while the journal lock is held.
    /// Both rooted install receipts must already be durable; a permissive verifier cannot
    /// turn interrupted staging or partial publication into a completion receipt.
    /// Failed verification leaves the exact unresolved journal untouched.
    func recordVerified(_ expected: Material, verify: () throws -> Void) throws {
        try persistence.transaction { bytes in
            guard let bytes else { throw Failure.verification }
            let record = try decodeRecord(bytes)
            guard !record.resolved, record.restored == nil, record.preparedMutation == nil, record.material == expected,
                  expected.appSidecarRecovery?.candidate != nil,
                  record.installed?.appRevision != nil else { throw Failure.verification }
            try verify()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let payload = try encoder.encode(VerifiedDisposition(material: expected, installed: record.installed))
            return ((), try encoder.encode(Envelope(version: 4, payload: payload, sha256: Self.digest(payload))))
        }
    }

    /// Records a native decision that the exact original carrier generations remain present.
    /// This is not successful publication: candidates are retained as evidence in a separate
    /// disposition type. Verification runs while the unresolved journal is locked.
    func recordUnchanged(_ expected: Material, verify: () throws -> Void) throws {
        try persistence.transaction { bytes in
            guard let bytes else { throw Failure.verification }
            let record = try decodeRecord(bytes)
            guard !record.resolved, record.material == expected,
                  expected.appSidecarRecovery != nil, record.installed == nil else { throw Failure.verification }
            try verify()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let payload = try encoder.encode(UnchangedDisposition(material: expected))
            return ((), try encoder.encode(Envelope(version: 5, payload: payload, sha256: Self.digest(payload))))
        }
    }

    struct UnchangedDisposition: Codable, Sendable, Equatable {
        let material: Material
        private enum CodingKeys: String, CodingKey { case material = "unchangedMaterial" }
    }

    func loadUnchangedDisposition() throws -> UnchangedDisposition? {
        try persistence.transaction(readOnly: true) { bytes in
            let record = try bytes.map(decodeRecord)
            return (record?.unchanged == true ? record.map { UnchangedDisposition(material: $0.material) } : nil,
                bytes ?? Data())
        }
    }

    private func decodeRecord(_ bytes: Data) throws -> (material: Material, verified: Bool, unchanged: Bool,
        resolved: Bool, installed: InstalledCarriers?, restored: RestoredCarriers?, preparedXMP: MCPPreparedXMPIdentity?, preparedMutation: PreparedMutation?) {
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].contains(envelope.version), envelope.sha256 == Self.digest(envelope.payload) else {
                throw Failure.corruptJournal
            }
            let material: Material
            var installed: InstalledCarriers?
            var restored: RestoredCarriers?
            var preparedXMP: MCPPreparedXMPIdentity?
            var preparedMutation: PreparedMutation?
            if envelope.version == 10 {
                let progress = try JSONDecoder().decode(MutationProgress.self, from: envelope.payload)
                material = progress.material; installed = progress.installed; restored = progress.restored
                preparedMutation = progress.mutation
                guard validMutation(progress.mutation, material: material, installed: progress.installed,
                                    restored: progress.restored) else { throw Failure.corruptJournal }
            } else if envelope.version == 9 {
                let progress = try JSONDecoder().decode(PreparedPublication.self, from: envelope.payload)
                material = progress.material; preparedXMP = progress.xmpIdentity
                guard progress.xmpIdentity.file.device != 0, progress.xmpIdentity.file.inode != 0,
                      progress.xmpIdentity.size == Int64(material.candidate.count),
                      (0..<1_000_000_000).contains(progress.xmpIdentity.modificationNanoseconds) else { throw Failure.corruptJournal }
            } else if envelope.version >= 7 {
                let progress = try JSONDecoder().decode(RestorationProgress.self, from: envelope.payload)
                material = progress.material; installed = progress.installed; restored = progress.restored
                guard !progress.restored.xmpRevision.isEmpty, progress.restored.xmpRevision.utf8.count <= 1024,
                      progress.restored.appRevision.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true,
                      (envelope.version == 8) == (progress.restored.appRevision != nil) else { throw Failure.corruptJournal }
            } else if envelope.version == 6 {
                let progress = try JSONDecoder().decode(PublicationProgress.self, from: envelope.payload)
                material = progress.material
                installed = progress.installed
            } else if envelope.version == 5 {
                material = try JSONDecoder().decode(UnchangedDisposition.self, from: envelope.payload).material
            } else if envelope.version == 4 {
                let receipt = try JSONDecoder().decode(VerifiedDisposition.self, from: envelope.payload)
                material = receipt.material
                installed = receipt.installed
            } else {
                material = try JSONDecoder().decode(Material.self, from: envelope.payload)
            }
            guard (envelope.version >= 2) == (material.appSidecarRecovery != nil),
                  (envelope.version == 5 || (envelope.version >= 3) == (material.appSidecarRecovery?.candidate != nil)) else {
                throw Failure.corruptJournal
            }
            try validate(material)
            if let restored {
                guard installed != nil, !restored.xmpRevision.isEmpty, restored.xmpRevision.utf8.count <= 1024,
                      restored.appRevision.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true
                else { throw Failure.corruptJournal }
            }
            if let installed {
                guard !installed.xmpRevision.isEmpty, installed.xmpRevision.utf8.count <= 1024,
                      installed.appRevision.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true,
                      installed.xmpRevision != material.binding.xmpSidecarRevision,
                      installed.appRevision != material.binding.appSidecarRevision else { throw Failure.corruptJournal }
            }
            return (material, envelope.version == 4, envelope.version == 5,
                envelope.version == 4 || envelope.version == 5 || envelope.version == 8, installed, restored, preparedXMP, preparedMutation)
        } catch { throw Failure.corruptJournal }
    }

    private func validate(_ material: Material) throws {
        if let sourcePath = material.sourcePath {
            let parts = sourcePath.split(separator: "/", omittingEmptySubsequences: false)
            guard sourcePath.hasPrefix("/"), sourcePath.utf8.count <= 4096,
                  !sourcePath.contains("\0"), !parts.dropFirst().contains(""),
                  !parts.contains("."), !parts.contains(".."),
                  URL(fileURLWithPath: sourcePath).deletingPathExtension().appendingPathExtension("xmp").path == material.targetPath
            else { throw Failure.invalidArguments }
        }
        let components = material.targetPath.split(separator: "/", omittingEmptySubsequences: false)
        let revisions = [material.binding.sourceRevision, material.binding.xmpSidecarRevision, material.binding.appSidecarRevision]
        guard revisions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }),
              !material.planID.isEmpty, material.planID.utf8.count <= 256,
              material.targetPath.hasPrefix("/"), material.targetPath.utf8.count <= 4096,
              !material.targetPath.contains("\0"), !components.dropFirst().contains(""),
              !components.contains("."), !components.contains(".."),
              material.targetPath.lowercased().hasSuffix(".xmp"),
              !material.candidate.isEmpty, material.candidate.count <= maximumCarrierBytes,
              (material.original?.count ?? 0) <= maximumCarrierBytes,
              (material.appSidecarRecovery?.original?.count ?? 0) <= maximumCarrierBytes,
              (material.appSidecarRecovery?.candidate?.count ?? 0) <= maximumCarrierBytes,
              material.appSidecarRecovery?.candidate?.isEmpty != true,
              (material.appSidecarRecovery == nil) == (material.publicationApprovalID == nil),
              material.original != material.candidate else { throw Failure.invalidArguments }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
