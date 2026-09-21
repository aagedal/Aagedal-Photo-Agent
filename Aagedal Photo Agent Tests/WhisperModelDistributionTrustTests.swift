import CryptoKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Whisper signed model release authorization")
struct WhisperModelDistributionTrustTests {
    private func descriptor(sequence: Int64 = 1, modelID: String = "tiny", url: String = "https://example.com/model.bin",
                            bytes: Int64 = 20, hash: String = String(repeating: "a", count: 64)) -> WhisperModelDistributionDescriptor {
        WhisperModelDistributionDescriptor(schemaVersion: 1, componentID: "whisper-ggml-model", modelID: modelID,
            title: "Tiny", releaseSequence: sequence, modelVersion: "revision-\(sequence)", byteCount: bytes,
            sha256: hash, downloadURL: URL(string: url)!)
    }

    private func receipt(_ descriptor: WhisperModelDistributionDescriptor, key: Curve25519.Signing.PrivateKey,
                         trust: WhisperModelDistributionTrust) throws -> WhisperModelDescriptorReceipt {
        let data = try descriptor.canonicalData()
        return try trust.verify(data, signature: key.signature(for: data))
    }

    @Test("Exact signed bytes produce a descriptor-bound downloadable identity")
    func verifiedIdentity() throws {
        let key = Curve25519.Signing.PrivateKey()
        let trust = try WhisperModelDistributionTrust(publicKey: key.publicKey.rawRepresentation)
        let value = descriptor()
        let admitted = try receipt(value, key: key, trust: trust)
        #expect(admitted.descriptor == value)
        #expect(admitted.downloadableModel.id == value.modelID)
        #expect(admitted.downloadableModel.sha256 == value.sha256)
        #expect(admitted.downloadableModel.byteCount == value.byteCount)
        #expect(admitted.downloadableModel.url == value.downloadURL)
        #expect(admitted.descriptorSHA256 == SHA256.hash(data: try value.canonicalData()).map { String(format: "%02x", $0) }.joined())
    }

    @Test("Tampering, another signer and truncated signatures cannot mint a receipt")
    func invalidSignatures() throws {
        let key = Curve25519.Signing.PrivateKey()
        let trust = try WhisperModelDistributionTrust(publicKey: key.publicKey.rawRepresentation)
        let data = try descriptor().canonicalData()
        let altered = try descriptor(sequence: 2).canonicalData()
        #expect(throws: WhisperModelDistributionTrust.TrustError.invalidSignature) {
            try trust.verify(altered, signature: key.signature(for: data))
        }
        #expect(throws: WhisperModelDistributionTrust.TrustError.invalidSignature) {
            try trust.verify(data, signature: Curve25519.Signing.PrivateKey().signature(for: data))
        }
        #expect(throws: WhisperModelDistributionTrust.TrustError.invalidSignature) {
            try trust.verify(data, signature: Data(repeating: 0, count: 63))
        }
    }

    @Test("Even correctly signed noncanonical, duplicate or unknown fields are refused")
    func ambiguousJSON() throws {
        let key = Curve25519.Signing.PrivateKey()
        let trust = try WhisperModelDistributionTrust(publicKey: key.publicKey.rawRepresentation)
        let canonical = String(decoding: try descriptor().canonicalData(), as: UTF8.self)
        for text in [canonical + "\n", "{\"extra\":true," + canonical.dropFirst(),
                     "{\"modelID\":\"base\"," + canonical.dropFirst()] {
            let data = Data(text.utf8)
            #expect(throws: WhisperModelDistributionTrust.TrustError.invalidDescriptor) {
                try trust.verify(data, signature: key.signature(for: data))
            }
        }
    }

    @Test("Authenticated payloads still require bounded model identities and secure URLs")
    func invalidDescriptors() throws {
        let key = Curve25519.Signing.PrivateKey()
        let trust = try WhisperModelDistributionTrust(publicKey: key.publicKey.rawRepresentation)
        for value in [descriptor(sequence: 0), descriptor(modelID: "../tiny"), descriptor(bytes: 0),
                      descriptor(bytes: 4_000_000_001), descriptor(hash: String(repeating: "A", count: 64)),
                      descriptor(url: "http://example.com/model"), descriptor(url: "https://user:pass@example.com/model"),
                      descriptor(url: "https://example.com/model#fragment"), descriptor(url: "https://example.com:444/model")] {
            #expect(throws: WhisperModelDistributionTrust.TrustError.invalidDescriptor) {
                try receipt(value, key: key, trust: trust)
            }
        }
        #expect(throws: WhisperModelDistributionTrust.TrustError.invalidDescriptor) {
            try trust.verify(Data(repeating: 0, count: 16_385), signature: Data())
        }
    }

    @Test("Rollback proposals retain the replay floor and select the exact previous release")
    func updateRollback() throws {
        let key = Curve25519.Signing.PrivateKey()
        let trust = try WhisperModelDistributionTrust(publicKey: key.publicKey.rawRepresentation)
        let first = try receipt(descriptor(), key: key, trust: trust)
        let initial = try trust.initialState(first)
        #expect(throws: WhisperModelDistributionTrust.TrustError.unavailableRollback) { try trust.rollingBack(initial) }
        let second = try receipt(descriptor(sequence: 2), key: key, trust: trust)
        let updated = try trust.updating(initial, to: second)
        #expect(updated.current.descriptorSHA256 == second.descriptorSHA256)
        #expect(updated.rollbackCandidate?.descriptorSHA256 == first.descriptorSHA256)
        let rolledBack = try trust.rollingBack(updated)
        #expect(rolledBack.current.descriptorSHA256 == first.descriptorSHA256)
        #expect(rolledBack.highestAcceptedSequence == 2)
        #expect(throws: WhisperModelDistributionTrust.TrustError.unavailableRollback) { try trust.rollingBack(rolledBack) }
        let equivocation = try receipt(descriptor(sequence: 2, hash: String(repeating: "b", count: 64)), key: key, trust: trust)
        for previous in [first, second, equivocation] {
            #expect(throws: WhisperModelDistributionTrust.TrustError.replayedRelease) {
                try trust.updating(rolledBack, to: previous)
            }
        }
        let third = try receipt(descriptor(sequence: 3), key: key, trust: trust)
        let recovered = try trust.updating(rolledBack, to: third)
        #expect(recovered.highestAcceptedSequence == 3)
        #expect(recovered.rollbackCandidate?.descriptorSHA256 == first.descriptorSHA256)
    }

    @Test("Copyable transition proposals do not consume state or establish a persisted replay floor")
    func proposalsAreNotConsumableTokens() throws {
        let key = Curve25519.Signing.PrivateKey()
        let trust = try WhisperModelDistributionTrust(publicKey: key.publicKey.rawRepresentation)
        let first = try receipt(descriptor(), key: key, trust: trust)
        let second = try receipt(descriptor(sequence: 2), key: key, trust: trust)
        let initial = try trust.initialState(first)
        let updated = try trust.updating(initial, to: second)
        let proposal = try trust.rollingBack(updated)
        let repeatedProposal = try trust.rollingBack(updated)
        #expect(proposal.current.descriptorSHA256 == repeatedProposal.current.descriptorSHA256)
        #expect(proposal.highestAcceptedSequence == repeatedProposal.highestAcceptedSequence)
        // An authoritative installer must reject stale generations and repeated first-install
        // proposals. This pure helper deliberately cannot infer previously committed state.
        let repeatedInitialProposal = try trust.initialState(first)
        #expect(repeatedInitialProposal.highestAcceptedSequence == 1)
        #expect(updated.highestAcceptedSequence == 2)
    }

    @Test("Receipts cannot cross model identities or injected trust authorities")
    func wrongAuthorityAndModel() throws {
        let key = Curve25519.Signing.PrivateKey()
        let trust = try WhisperModelDistributionTrust(publicKey: key.publicKey.rawRepresentation)
        let initial = try trust.initialState(receipt(descriptor(), key: key, trust: trust))
        let base = try receipt(descriptor(sequence: 2, modelID: "base"), key: key, trust: trust)
        #expect(throws: WhisperModelDistributionTrust.TrustError.wrongModel) { try trust.updating(initial, to: base) }
        let otherKey = Curve25519.Signing.PrivateKey()
        let otherTrust = try WhisperModelDistributionTrust(publicKey: otherKey.publicKey.rawRepresentation)
        let other = try receipt(descriptor(sequence: 2), key: otherKey, trust: otherTrust)
        #expect(throws: WhisperModelDistributionTrust.TrustError.wrongAuthority) { try trust.initialState(other) }
        #expect(throws: WhisperModelDistributionTrust.TrustError.wrongAuthority) { try trust.updating(initial, to: other) }
        #expect(throws: WhisperModelDistributionTrust.TrustError.wrongAuthority) { try otherTrust.rollingBack(initial) }
    }
}
