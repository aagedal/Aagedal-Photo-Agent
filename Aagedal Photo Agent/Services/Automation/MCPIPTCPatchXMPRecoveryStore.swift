import CryptoKit
import Foundation

/// Durable recovery material only. This store neither grants publication consent nor reads,
/// installs, restores or deletes a live carrier. A future installer must bind these bytes to
/// retained root descriptors, carrier identities, exact-plan consent and app-history recovery.
/// Checksums detect corruption, not tampering by another process running as this account.
nonisolated struct MCPIPTCPatchXMPRecoveryStore: Sendable {
    enum Failure: Error, Equatable { case invalidArguments, occupied, corruptJournal }
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
            maximumBytes: 48_000_000)
    }

    @discardableResult
    func stage(id: UUID, planID: String, targetPath: String, binding: Binding, original: Data?, candidate: Data,
               appSidecarRecovery: AppSidecarRecovery? = nil, publicationApprovalID: UUID? = nil) throws -> Material {
        try Task.checkCancellation()
        let proposed = Material(id: id, planID: planID, targetPath: targetPath, binding: binding,
            original: original, candidate: candidate, appSidecarRecovery: appSidecarRecovery,
            publicationApprovalID: publicationApprovalID)
        try validate(proposed)
        return try persistence.transaction { existing in
            if let existing {
                let material = try decode(existing)
                guard material == proposed else { throw Failure.occupied }
                return (material, existing)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let payload = try encoder.encode(proposed)
            let data = try encoder.encode(Envelope(version: appSidecarRecovery == nil ? 1 : 2,
                payload: payload, sha256: Self.digest(payload)))
            try Task.checkCancellation()
            return (proposed, data)
        }
    }

    /// Reloads from disk under the shared process lock; no in-memory success receipt can
    /// conceal a missing, substituted, over-permissive or corrupt recovery file.
    func load() throws -> Material? {
        try persistence.transaction(readOnly: true) { bytes in
            (try bytes.map(decode), bytes ?? Data())
        }
    }

    /// Pure byte classification, deliberately not an authorization to restore. Same-byte
    /// inode substitutions and source/app-history changes require separate rooted checks.
    static func observe(_ bytes: Data?, for material: Material) -> Observation {
        if bytes == material.original { return .originalPresent }
        if bytes == material.candidate { return .candidatePresent }
        return .conflict
    }

    private func decode(_ bytes: Data) throws -> Material {
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard [1, 2].contains(envelope.version), envelope.sha256 == Self.digest(envelope.payload) else {
                throw Failure.corruptJournal
            }
            let material = try JSONDecoder().decode(Material.self, from: envelope.payload)
            guard (envelope.version == 2) == (material.appSidecarRecovery != nil) else {
                throw Failure.corruptJournal
            }
            try validate(material)
            return material
        } catch { throw Failure.corruptJournal }
    }

    private func validate(_ material: Material) throws {
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
              (material.appSidecarRecovery == nil) == (material.publicationApprovalID == nil),
              material.original != material.candidate else { throw Failure.invalidArguments }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
