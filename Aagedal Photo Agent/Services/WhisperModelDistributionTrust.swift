import CryptoKit
import Foundation

/// Wire format for a future managed model distribution. No production key or remote
/// endpoint is configured here; the compiled model catalog remains the shipping authority.
nonisolated struct WhisperModelDistributionDescriptor: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let componentID: String
    let modelID: String
    let title: String
    let releaseSequence: Int64
    let modelVersion: String
    let byteCount: Int64
    let sha256: String
    let downloadURL: URL

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// An authenticated descriptor receipt, not evidence that model bytes are installed.
/// It cannot be decoded or constructed by a caller; persisted descriptor/signature
/// pairs must be verified again against the application's trust anchor on each load.
nonisolated struct WhisperModelDescriptorReceipt: Sendable {
    let descriptor: WhisperModelDistributionDescriptor
    let descriptorSHA256: String
    fileprivate let descriptorData: Data
    fileprivate let signature: Data
    fileprivate let publicKey: Data

    fileprivate init(descriptor: WhisperModelDistributionDescriptor, data: Data, signature: Data, publicKey: Data) {
        self.descriptor = descriptor
        self.descriptorData = data
        self.signature = signature
        self.publicKey = publicKey
        descriptorSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var downloadableModel: WhisperDownloadableModel {
        WhisperDownloadableModel(id: descriptor.modelID, title: descriptor.title,
            byteCount: descriptor.byteCount, sha256: descriptor.sha256, url: descriptor.downloadURL)
    }
}

/// A copyable transition proposal, not authoritative installation state or a consumable token.
/// A future installer must persist the high-water mark and atomically compare its current
/// generation before committing a proposal together with verified model bytes. Copies can
/// propose the same rollback repeatedly; this value neither installs nor recovers disk state.
nonisolated struct WhisperModelReleaseState: Sendable {
    let current: WhisperModelDescriptorReceipt
    let rollbackCandidate: WhisperModelDescriptorReceipt?
    let highestAcceptedSequence: Int64

    fileprivate init(current: WhisperModelDescriptorReceipt, rollbackCandidate: WhisperModelDescriptorReceipt?,
                     highestAcceptedSequence: Int64) {
        self.current = current
        self.rollbackCandidate = rollbackCandidate
        self.highestAcceptedSequence = highestAcceptedSequence
    }
}

nonisolated struct WhisperModelDistributionTrust: Sendable {
    enum TrustError: Error, Equatable {
        case invalidSignature, invalidDescriptor, wrongAuthority, wrongModel, replayedRelease, unavailableRollback
    }

    private let publicKey: Data

    /// Supply an app-controlled Ed25519 key, never a key obtained from the descriptor's server.
    init(publicKey: Data) throws {
        guard publicKey.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)) != nil else {
            throw TrustError.invalidSignature
        }
        self.publicKey = publicKey
    }

    /// Signature is the raw 64-byte Ed25519 representation over exact canonical JSON bytes.
    func verify(_ data: Data, signature: Data) throws -> WhisperModelDescriptorReceipt {
        guard !data.isEmpty, data.count <= 16_384 else { throw TrustError.invalidDescriptor }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard signature.count == 64, key.isValidSignature(signature, for: data) else {
            throw TrustError.invalidSignature
        }
        guard let descriptor = try? JSONDecoder().decode(WhisperModelDistributionDescriptor.self, from: data),
              (try? descriptor.canonicalData()) == data else { throw TrustError.invalidDescriptor }
        try validate(descriptor)
        return WhisperModelDescriptorReceipt(descriptor: descriptor, data: data, signature: signature, publicKey: publicKey)
    }

    /// Proposes first-install state only. The installer must independently establish that
    /// no authoritative state exists; calling this again must never reset a persisted floor.
    func initialState(_ receipt: WhisperModelDescriptorReceipt) throws -> WhisperModelReleaseState {
        try authenticate(receipt)
        return WhisperModelReleaseState(current: receipt, rollbackCandidate: nil,
            highestAcceptedSequence: receipt.descriptor.releaseSequence)
    }

    /// Equal sequences are refused even if a server signs different replacement bytes.
    /// The proposed high-water mark survives rollback. Replay protection requires the installer
    /// to compare against its persisted state, not a stale caller-supplied copy.
    func updating(_ state: WhisperModelReleaseState, to receipt: WhisperModelDescriptorReceipt) throws -> WhisperModelReleaseState {
        try authenticate(state.current)
        try authenticate(receipt)
        guard state.current.descriptor.modelID == receipt.descriptor.modelID else { throw TrustError.wrongModel }
        guard receipt.descriptor.releaseSequence > state.highestAcceptedSequence else { throw TrustError.replayedRelease }
        return WhisperModelReleaseState(current: receipt, rollbackCandidate: state.current,
            highestAcceptedSequence: receipt.descriptor.releaseSequence)
    }

    /// Call only after explicit rollback intent. Proposes the exact retained prior release;
    /// it does not consume the supplied state. The installer must reject stale generations
    /// and commit the proposal durably before permitting another transition.
    func rollingBack(_ state: WhisperModelReleaseState) throws -> WhisperModelReleaseState {
        try authenticate(state.current)
        guard let previous = state.rollbackCandidate else { throw TrustError.unavailableRollback }
        try authenticate(previous)
        guard previous.descriptor.modelID == state.current.descriptor.modelID else { throw TrustError.wrongModel }
        return WhisperModelReleaseState(current: previous, rollbackCandidate: nil,
            highestAcceptedSequence: state.highestAcceptedSequence)
    }

    private func authenticate(_ receipt: WhisperModelDescriptorReceipt) throws {
        guard receipt.publicKey == publicKey else { throw TrustError.wrongAuthority }
        _ = try verify(receipt.descriptorData, signature: receipt.signature)
    }

    private func validate(_ descriptor: WhisperModelDistributionDescriptor) throws {
        let url = descriptor.downloadURL
        guard descriptor.schemaVersion == 1, descriptor.componentID == "whisper-ggml-model",
              !descriptor.modelID.isEmpty, descriptor.modelID.utf8.count <= 64,
              descriptor.modelID.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              !descriptor.title.isEmpty, descriptor.title.utf8.count <= 128,
              !descriptor.modelVersion.isEmpty, descriptor.modelVersion.utf8.count <= 128,
              descriptor.releaseSequence > 0,
              descriptor.byteCount > 0, descriptor.byteCount <= 4_000_000_000,
              descriptor.sha256.utf8.count == 64,
              descriptor.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              !url.path.isEmpty else { throw TrustError.invalidDescriptor }
    }
}

/// Persistence evidence only. Decoding this envelope never authenticates a release.
nonisolated struct WhisperModelReleaseRecord: Codable, Sendable {
    private struct Evidence: Codable, Sendable {
        let descriptor: Data
        let signature: Data

        init(_ receipt: WhisperModelDescriptorReceipt) {
            descriptor = receipt.descriptorData
            signature = receipt.signature
        }

        func verify(using trust: WhisperModelDistributionTrust) throws -> WhisperModelDescriptorReceipt {
            try trust.verify(descriptor, signature: signature)
        }
    }

    private let current: Evidence
    private let previous: Evidence?
    private let highWater: Evidence

    init(state: WhisperModelReleaseState, highWater: WhisperModelDescriptorReceipt) {
        current = Evidence(state.current)
        previous = state.rollbackCandidate.map(Evidence.init)
        self.highWater = Evidence(highWater)
    }

    func authenticated(using trust: WhisperModelDistributionTrust) throws -> (WhisperModelReleaseState, WhisperModelDescriptorReceipt) {
        let current = try current.verify(using: trust)
        let previous = try previous?.verify(using: trust)
        let highWater = try highWater.verify(using: trust)
        guard current.descriptor.modelID == highWater.descriptor.modelID,
              current.descriptor.releaseSequence <= highWater.descriptor.releaseSequence else {
            throw WhisperModelDistributionTrust.TrustError.invalidDescriptor
        }
        if current.descriptor.releaseSequence == highWater.descriptor.releaseSequence {
            guard current.descriptorSHA256 == highWater.descriptorSHA256 else {
                throw WhisperModelDistributionTrust.TrustError.invalidDescriptor
            }
        } else if previous != nil {
            // A committed rollback consumes the sole retained candidate.
            throw WhisperModelDistributionTrust.TrustError.invalidDescriptor
        }
        if let previous {
            guard previous.descriptor.modelID == current.descriptor.modelID,
                  previous.descriptor.releaseSequence < current.descriptor.releaseSequence else {
                throw WhisperModelDistributionTrust.TrustError.invalidDescriptor
            }
        }
        return (WhisperModelReleaseState(current: current, rollbackCandidate: previous,
            highestAcceptedSequence: highWater.descriptor.releaseSequence), highWater)
    }
}

/// Connects a verified release to the existing bounded transfer and durable installer.
/// The caller owns descriptor retrieval and supplies an isolated download cache; this
/// type never treats a downloaded cache file as release authority.
actor WhisperSignedModelLifecycle {
    private let trust: WhisperModelDistributionTrust
    private let downloads: WhisperModelDownloadService
    private let store: WhisperModelDistributionStateStore

    init(trust: WhisperModelDistributionTrust, downloads: WhisperModelDownloadService,
         store: WhisperModelDistributionStateStore) {
        self.trust = trust
        self.downloads = downloads
        self.store = store
    }

    func install(descriptorData: Data, signature: Data, expectedGeneration: UUID?,
                 progress: @escaping WhisperModelDownloadService.Progress = { _ in }) async throws -> WhisperModelDistributionStateStore.Snapshot {
        let receipt = try trust.verify(descriptorData, signature: signature)
        // Reject stale/replayed proposals before a potentially large network transfer.
        let current = try await store.load()
        guard current?.generation == expectedGeneration else {
            throw WhisperModelDistributionStateStore.StoreError.staleGeneration
        }
        if let current {
            _ = try trust.updating(current.release, to: receipt)
        } else {
            _ = try trust.initialState(receipt)
        }
        let source = try await downloads.download(receipt.downloadableModel, progress: progress)
        // The store rechecks its generation, signature, byte count and hash under its
        // own transaction lock before committing the release record.
        return try await store.install(receipt, from: source, expectedGeneration: expectedGeneration)
    }

    func installedURL() async throws -> URL? { try await store.installedURL() }

    func rollBack(expectedGeneration: UUID) async throws -> WhisperModelDistributionStateStore.Snapshot {
        try await store.rollBackInstalled(expectedGeneration: expectedGeneration)
    }
}
