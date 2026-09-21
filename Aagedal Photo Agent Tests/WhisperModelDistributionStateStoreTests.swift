import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Durable Whisper release authorization")
struct WhisperModelDistributionStateStoreTests {
    private struct Fixture {
        let directory: URL
        let key = Curve25519.Signing.PrivateKey()
        var trust: WhisperModelDistributionTrust {
            get throws { try WhisperModelDistributionTrust(publicKey: key.publicKey.rawRepresentation) }
        }
        init() throws {
            let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(canonical) }
            directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        func store() throws -> WhisperModelDistributionStateStore {
            try WhisperModelDistributionStateStore(directory: directory, modelID: "tiny", trust: trust)
        }
        func receipt(_ sequence: Int64) throws -> WhisperModelDescriptorReceipt {
            let descriptor = WhisperModelDistributionDescriptor(schemaVersion: 1, componentID: "whisper-ggml-model",
                modelID: "tiny", title: "Tiny", releaseSequence: sequence, modelVersion: "v\(sequence)",
                byteCount: 20, sha256: String(repeating: "a", count: 64),
                downloadURL: URL(string: "https://example.com/model.bin")!)
            let data = try descriptor.canonicalData()
            return try trust.verify(data, signature: key.signature(for: data))
        }
        var stateURL: URL { directory.appendingPathComponent("tiny.release-state.json") }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test("Restart preserves descriptor identity, rollback consumption and signed high-water floor")
    func restartAndRollback() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = try fixture.store()
        #expect(try await store.load() == nil)
        let first = try await store.accept(fixture.receipt(1), expectedGeneration: nil)
        let second = try await store.accept(fixture.receipt(2), expectedGeneration: first.generation)
        let reopened = try fixture.store()
        let loaded = try #require(await reopened.load())
        #expect(loaded.generation == second.generation)
        #expect(loaded.release.current.descriptorSHA256 == second.release.current.descriptorSHA256)
        let rolledBack = try await reopened.rollBack(expectedGeneration: second.generation)
        #expect(rolledBack.release.current.descriptor.releaseSequence == 1)
        #expect(rolledBack.release.highestAcceptedSequence == 2)
        let afterRestart = try fixture.store()
        #expect(try await afterRestart.load()?.release.highestAcceptedSequence == 2)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.staleGeneration) {
            try await afterRestart.rollBack(expectedGeneration: second.generation)
        }
        await #expect(throws: WhisperModelDistributionTrust.TrustError.unavailableRollback) {
            try await afterRestart.rollBack(expectedGeneration: rolledBack.generation)
        }
        await #expect(throws: WhisperModelDistributionTrust.TrustError.replayedRelease) {
            try await afterRestart.accept(fixture.receipt(2), expectedGeneration: rolledBack.generation)
        }
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.staleGeneration) {
            try await afterRestart.accept(fixture.receipt(3), expectedGeneration: nil)
        }
        let third = try await afterRestart.accept(fixture.receipt(3), expectedGeneration: rolledBack.generation)
        #expect(third.release.highestAcceptedSequence == 3)
    }

    @Test("Two store instances cannot consume the same generation")
    func competingUpdates() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let firstStore = try fixture.store()
        let secondStore = try fixture.store()
        let initial = try await firstStore.accept(fixture.receipt(1), expectedGeneration: nil)
        let next = try fixture.receipt(2)
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for store in [firstStore, secondStore] {
                group.addTask {
                    do {
                        _ = try await store.accept(next, expectedGeneration: initial.generation)
                        return true
                    } catch { return false }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(outcomes.filter { $0 }.count == 1)
        #expect(try await firstStore.load()?.release.highestAcceptedSequence == 2)
    }

    @Test("Corrupt and future state cannot reset the floor or fall back to an older backup")
    func failClosed() async throws {
        for corrupt in [Data("broken".utf8), Data("{\"schemaVersion\":999}".utf8)] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let store = try fixture.store()
            let first = try await store.accept(fixture.receipt(1), expectedGeneration: nil)
            let original = try Data(contentsOf: fixture.stateURL)
            try original.write(to: fixture.stateURL.appendingPathExtension("backup"))
            _ = try await store.accept(fixture.receipt(2), expectedGeneration: first.generation)
            try corrupt.write(to: fixture.stateURL)
            await #expect(throws: WhisperModelDistributionStateStore.StoreError.invalidState) { try await store.load() }
            await #expect(throws: WhisperModelDistributionStateStore.StoreError.invalidState) {
                try await store.accept(fixture.receipt(1), expectedGeneration: nil)
            }
            #expect(try Data(contentsOf: fixture.stateURL) == corrupt)
        }
    }

    @Test("Persisted evidence is reverified against the configured authority")
    func changedAuthority() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store().accept(fixture.receipt(1), expectedGeneration: nil)
        let otherTrust = try WhisperModelDistributionTrust(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let other = try WhisperModelDistributionStateStore(directory: fixture.directory, modelID: "tiny", trust: otherTrust)
        await #expect(throws: WhisperModelDistributionTrust.TrustError.invalidSignature) { try await other.load() }
    }

    @Test("A symlink ledger is neither followed nor overwritten")
    func symlinkRefusal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outside = fixture.directory.appendingPathComponent("untouched")
        let bytes = Data("original".utf8)
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.stateURL, withDestinationURL: outside)
        let store = try fixture.store()
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.unsafeStorage) {
            try await store.accept(fixture.receipt(1), expectedGeneration: nil)
        }
        #expect(try Data(contentsOf: outside) == bytes)
    }

    @Test("Parent symlinks are refused before establishing ledger authority")
    func parentSymlinkRefusal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let actual = fixture.directory.appendingPathComponent("actual")
        let leaf = actual.appendingPathComponent("ledger")
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let alias = fixture.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        #expect(throws: WhisperModelDistributionStateStore.StoreError.unsafeStorage) {
            try WhisperModelDistributionStateStore(directory: alias.appendingPathComponent("ledger"),
                modelID: "tiny", trust: fixture.trust)
        }
    }

    @Test("Replacing the ledger directory cannot reset a retained store")
    func directoryIdentityRefusal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = try fixture.store()
        _ = try await store.accept(fixture.receipt(1), expectedGeneration: nil)
        let retained = fixture.directory.appendingPathExtension("retained")
        defer { try? FileManager.default.removeItem(at: retained) }
        try FileManager.default.moveItem(at: fixture.directory, to: retained)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.unsafeStorage) {
            try await store.load()
        }
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.unsafeStorage) {
            try await store.accept(fixture.receipt(2), expectedGeneration: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.stateURL.path))
        #expect(FileManager.default.fileExists(atPath: retained.appendingPathComponent("tiny.release-state.json").path))
    }

}
