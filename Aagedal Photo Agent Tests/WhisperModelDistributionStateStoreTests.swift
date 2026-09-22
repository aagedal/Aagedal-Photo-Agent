import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@_silgen_name("flock")
nonisolated private func testWhisperReleaseFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

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
        func receipt(_ sequence: Int64, bytes: Data? = nil) throws -> WhisperModelDescriptorReceipt {
            let descriptor = WhisperModelDistributionDescriptor(schemaVersion: 1, componentID: "whisper-ggml-model",
                modelID: "tiny", title: "Tiny", releaseSequence: sequence, modelVersion: "v\(sequence)",
                byteCount: Int64(bytes?.count ?? 20),
                sha256: bytes.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? String(repeating: "a", count: 64),
                downloadURL: URL(string: "https://example.com/model.bin")!)
            let data = try descriptor.canonicalData()
            return try trust.verify(data, signature: key.signature(for: data))
        }
        var stateURL: URL { directory.appendingPathComponent("tiny.release-state.json") }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test("Recovery removes an interrupted published model while retaining current and rollback bytes")
    func interruptedPublicationCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = fixture.directory.appendingPathComponent("download")
        let store = try fixture.store()
        let firstBytes = Data("first".utf8)
        try firstBytes.write(to: source)
        let first = try await store.install(fixture.receipt(1, bytes: firstBytes), from: source, expectedGeneration: nil)
        let firstURL = try #require(await store.installedURL())
        let secondBytes = Data("second".utf8)
        try secondBytes.write(to: source)
        let second = try await store.install(fixture.receipt(2, bytes: secondBytes), from: source, expectedGeneration: first.generation)
        let secondURL = try #require(await store.installedURL())
        let ledger = try Data(contentsOf: fixture.stateURL)
        let thirdBytes = Data("third".utf8)
        let thirdReceipt = try fixture.receipt(3, bytes: thirdBytes)
        try thirdBytes.write(to: source)
        let failing = try WhisperModelDistributionStateStore(directory: fixture.directory,
            modelID: "tiny", trust: fixture.trust, publicationCheckpoint: { throw CancellationError() })
        await #expect(throws: CancellationError.self) {
            try await failing.install(thirdReceipt, from: source, expectedGeneration: second.generation)
        }
        let orphan = fixture.directory.appendingPathComponent("ggml-tiny-\(thirdReceipt.descriptor.sha256).bin")
        #expect(try Data(contentsOf: orphan) == thirdBytes)
        let restarted = try fixture.store()
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.staleGeneration) {
            try await restarted.cleanUpInterruptedInstallation(expectedGeneration: first.generation)
        }
        #expect(try await restarted.cleanUpInterruptedInstallation(expectedGeneration: second.generation) == 1)
        #expect(try await restarted.cleanUpInterruptedInstallation(expectedGeneration: second.generation) == 0)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try Data(contentsOf: firstURL) == firstBytes)
        #expect(try Data(contentsOf: secondURL) == secondBytes)
        #expect(try Data(contentsOf: fixture.stateURL) == ledger)
        let rolledBack = try await restarted.rollBackInstalled(expectedGeneration: second.generation)
        #expect(try await restarted.cleanUpInterruptedInstallation(expectedGeneration: rolledBack.generation) == 0)
        #expect(try Data(contentsOf: firstURL) == firstBytes)
        #expect(try Data(contentsOf: secondURL) == secondBytes)
        _ = try await restarted.install(thirdReceipt, from: source, expectedGeneration: rolledBack.generation)
    }

    @Test("Cleanup authenticates authority and preflights unsafe candidates before deleting")
    func cleanupFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = try fixture.store()
        let initial = try await store.accept(fixture.receipt(1), expectedGeneration: nil)
        let staged = fixture.directory.appendingPathComponent(".tiny.\(UUID().uuidString).model-staging")
        try Data("staged".utf8).write(to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        let symlink = fixture.directory.appendingPathComponent("ggml-tiny-\(String(repeating: "b", count: 64)).bin")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: staged)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.unsafeStorage) {
            try await store.cleanUpInterruptedInstallation(expectedGeneration: initial.generation)
        }
        #expect(try Data(contentsOf: staged) == Data("staged".utf8))
        try FileManager.default.removeItem(at: symlink)
        let otherTrust = try WhisperModelDistributionTrust(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let other = try WhisperModelDistributionStateStore(directory: fixture.directory, modelID: "tiny", trust: otherTrust)
        await #expect(throws: WhisperModelDistributionTrust.TrustError.invalidSignature) {
            try await other.cleanUpInterruptedInstallation(expectedGeneration: initial.generation)
        }
        try Data("broken".utf8).write(to: fixture.stateURL)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.invalidState) {
            try await store.cleanUpInterruptedInstallation(expectedGeneration: initial.generation)
        }
        try FileManager.default.removeItem(at: fixture.stateURL)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.staleGeneration) {
            try await store.cleanUpInterruptedInstallation(expectedGeneration: initial.generation)
        }
        #expect(try Data(contentsOf: staged) == Data("staged".utf8))
    }

    @Test("Cleanup is bounded and preserves other-model and legacy staging files")
    func cleanupBoundsAndScope() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = try fixture.store()
        let initial = try await store.accept(fixture.receipt(1), expectedGeneration: nil)
        var staged: [URL] = []
        for _ in 0..<65 {
            let url = fixture.directory.appendingPathComponent(".tiny.\(UUID().uuidString).model-staging")
            try Data("staged".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            staged.append(url)
        }
        let untouched = [".\(UUID().uuidString).model-staging", ".base.\(UUID().uuidString).model-staging",
                         "ggml-base-\(String(repeating: "c", count: 64)).bin", ".tiny.not-a-uuid.model-staging"]
        for name in untouched { try Data("keep".utf8).write(to: fixture.directory.appendingPathComponent(name)) }
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.cleanupLimitExceeded) {
            try await store.cleanUpInterruptedInstallation(expectedGeneration: initial.generation)
        }
        #expect(staged.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        try FileManager.default.removeItem(at: staged.removeLast())
        #expect(try await store.cleanUpInterruptedInstallation(expectedGeneration: initial.generation) == 64)
        for name in untouched {
            #expect(try Data(contentsOf: fixture.directory.appendingPathComponent(name)) == Data("keep".utf8))
        }
    }

    @Test("Signed installation, update and rollback retain verified bytes across restart")
    func verifiedInstallationLifecycle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = fixture.directory.appendingPathComponent("download")
        let firstBytes = Data("first model".utf8)
        let secondBytes = Data("second model".utf8)
        let firstReceipt = try fixture.receipt(1, bytes: firstBytes)
        let secondReceipt = try fixture.receipt(2, bytes: secondBytes)
        let store = try fixture.store()
        #expect(try await store.installedURL() == nil)
        try firstBytes.write(to: source)
        let first = try await store.install(firstReceipt, from: source, expectedGeneration: nil)
        let firstURL = try #require(await store.installedURL())
        #expect(try Data(contentsOf: firstURL) == firstBytes)
        try secondBytes.write(to: source)
        let second = try await store.install(secondReceipt, from: source, expectedGeneration: first.generation)
        let restarted = try fixture.store()
        let secondURL = try #require(await restarted.installedURL())
        #expect(firstURL != secondURL)
        #expect(try Data(contentsOf: firstURL) == firstBytes)
        #expect(try Data(contentsOf: secondURL) == secondBytes)
        let rolledBack = try await restarted.rollBackInstalled(expectedGeneration: second.generation)
        #expect(try await restarted.installedURL() == firstURL)
        #expect(rolledBack.release.highestAcceptedSequence == 2)
        await #expect(throws: WhisperModelDistributionTrust.TrustError.replayedRelease) {
            try await restarted.install(secondReceipt, from: source, expectedGeneration: rolledBack.generation)
        }
        await #expect(throws: WhisperModelDistributionTrust.TrustError.unavailableRollback) {
            try await restarted.rollBackInstalled(expectedGeneration: rolledBack.generation)
        }
    }

    @Test("A newly signed release can reuse verified identical content without replacing it")
    func identicalContentReleaseAndStaleInstall() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let bytes = Data("identical content".utf8)
        let source = fixture.directory.appendingPathComponent("download")
        try bytes.write(to: source)
        let store = try fixture.store()
        let first = try await store.install(fixture.receipt(1, bytes: bytes), from: source, expectedGeneration: nil)
        let originalURL = try #require(await store.installedURL())
        let before = try FileManager.default.attributesOfItem(atPath: originalURL.path)[.systemFileNumber] as? NSNumber
        let next = try await store.install(fixture.receipt(2, bytes: bytes), from: source, expectedGeneration: first.generation)
        #expect(try await store.installedURL() == originalURL)
        #expect(try FileManager.default.attributesOfItem(atPath: originalURL.path)[.systemFileNumber] as? NSNumber == before)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.staleGeneration) {
            try await store.install(fixture.receipt(3, bytes: bytes), from: source, expectedGeneration: first.generation)
        }
        #expect(try await store.load()?.generation == next.generation)
        try Data("different content".utf8).write(to: originalURL)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.invalidModelBytes) {
            try await store.installedURL()
        }
    }

    @Test("Bad downloaded bytes leave generation, current bytes and rollback intact and allow retry")
    func invalidInstallationPreservesRelease() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = fixture.directory.appendingPathComponent("download")
        let bytes = Data("model one".utf8)
        let nextBytes = Data("model two".utf8)
        let store = try fixture.store()
        try bytes.write(to: source)
        let first = try await store.install(fixture.receipt(1, bytes: bytes), from: source, expectedGeneration: nil)
        let before = try Data(contentsOf: fixture.stateURL)
        let next = try fixture.receipt(2, bytes: nextBytes)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.invalidModelBytes) {
            try await store.install(next, from: source, expectedGeneration: first.generation)
        }
        #expect(try Data(contentsOf: fixture.stateURL) == before)
        #expect(try await store.load()?.generation == first.generation)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).filter { $0.hasSuffix(".model-staging") }.isEmpty)
        try nextBytes.write(to: source)
        _ = try await store.install(next, from: source, expectedGeneration: first.generation)
    }

    @Test("Cancellation after staging preserves ledger and bytes, cleans staging, and permits retry")
    func cancelledInstallationPreservesRelease() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = fixture.directory.appendingPathComponent("download")
        let firstBytes = Data("model one".utf8)
        let nextBytes = Data("model two".utf8)
        let store = try fixture.store()
        try firstBytes.write(to: source)
        let first = try await store.install(fixture.receipt(1, bytes: firstBytes), from: source, expectedGeneration: nil)
        let current = try #require(await store.installedURL())
        let before = try Data(contentsOf: fixture.stateURL)
        try nextBytes.write(to: source)
        let next = try fixture.receipt(2, bytes: nextBytes)
        let cancellingStore = try WhisperModelDistributionStateStore(directory: fixture.directory,
            modelID: "tiny", trust: fixture.trust, installationCheckpoint: {
                // The hook runs only after the complete staged file exists. Cancel the
                // actual installing task so normal cancellation checks and cleanup run.
                withUnsafeCurrentTask { $0?.cancel() }
            })
        let installation = Task {
            try await cancellingStore.install(next, from: source, expectedGeneration: first.generation)
        }
        await #expect(throws: CancellationError.self) { try await installation.value }
        #expect(try Data(contentsOf: fixture.stateURL) == before)
        #expect(try Data(contentsOf: current) == firstBytes)
        #expect(try await store.load()?.generation == first.generation)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        #expect(!names.contains { $0.hasSuffix(".model-staging") })
        #expect(!names.contains("ggml-tiny-\(next.descriptor.sha256).bin"))
        let retried = try await store.install(next, from: source, expectedGeneration: first.generation)
        #expect(retried.release.current.descriptor.releaseSequence == 2)
        let installed = try #require(await store.installedURL())
        #expect(try Data(contentsOf: installed) == nextBytes)
    }

    @Test("Missing or tampered rollback bytes cannot change durable release authority")
    func invalidRollbackPreservesRelease() async throws {
        for remove in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let source = fixture.directory.appendingPathComponent("download")
            let store = try fixture.store()
            let bytes = Data("model one".utf8)
            try bytes.write(to: source)
            let first = try await store.install(fixture.receipt(1, bytes: bytes), from: source, expectedGeneration: nil)
            let retained = try #require(await store.installedURL())
            let nextBytes = Data("model two".utf8)
            try nextBytes.write(to: source)
            let second = try await store.install(fixture.receipt(2, bytes: nextBytes), from: source, expectedGeneration: first.generation)
            let before = try Data(contentsOf: fixture.stateURL)
            if remove { try FileManager.default.removeItem(at: retained) }
            else { try Data("tampered!".utf8).write(to: retained) }
            await #expect(throws: (any Error).self) {
                try await store.rollBackInstalled(expectedGeneration: second.generation)
            }
            #expect(try Data(contentsOf: fixture.stateURL) == before)
            #expect(try await store.load()?.generation == second.generation)
            let current = try #require(await store.installedURL())
            #expect(try Data(contentsOf: current) == nextBytes)
        }
    }

    @Test("Authorization alone and replaced model symlinks never qualify as installed bytes")
    func installedLookupRequiresBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let bytes = Data("model one".utf8)
        let receipt = try fixture.receipt(1, bytes: bytes)
        let store = try fixture.store()
        _ = try await store.accept(receipt, expectedGeneration: nil)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.unsafeStorage) {
            try await store.installedURL()
        }
        let source = fixture.directory.appendingPathComponent("download")
        try bytes.write(to: source)
        let target = fixture.directory.appendingPathComponent("ggml-tiny-\(receipt.descriptor.sha256).bin")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.unsafeStorage) {
            try await store.installedURL()
        }
        #expect(try Data(contentsOf: source) == bytes)
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

    @Test("An independent process excludes reads, updates and rollback, then publishes a newer generation")
    func processContentionAndStaleGeneration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = try fixture.store()
        let other = try fixture.store()
        let first = try await store.accept(fixture.receipt(1), expectedGeneration: nil)
        let original = try Data(contentsOf: fixture.stateURL)
        let second = try await store.accept(fixture.receipt(2), expectedGeneration: first.generation)
        let pending = fixture.directory.appendingPathComponent("pending-release.json")
        try FileManager.default.moveItem(at: fixture.stateURL, to: pending)
        try original.write(to: fixture.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.stateURL.path)

        // macOS's system Perl is only a test fixture. Its flock is independent of the
        // app's actor and process-local admission, and publishes genuine signed state.
        let helper = Process()
        let input = Pipe()
        let output = Pipe()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        helper.arguments = ["-e", """
            use strict; use warnings; use Fcntl qw(:DEFAULT :flock);
            sysopen(my $lock, $ARGV[0], O_RDONLY) or die "open: $!";
            flock($lock, LOCK_EX | LOCK_NB) or die "lock: $!";
            $| = 1; print "R";
            sysread(STDIN, my $command, 1) == 1 or exit 0;
            rename($ARGV[1], $ARGV[2]) or die "rename: $!";
            flock($lock, LOCK_UN) or die "unlock: $!";
            print "D";
            """, fixture.directory.path, pending.path, fixture.stateURL.path]
        helper.standardInput = input
        helper.standardOutput = output
        try helper.run()
        defer {
            try? input.fileHandleForWriting.close()
            if helper.isRunning { helper.terminate() }
        }
        try awaitMarker("R", from: output.fileHandleForReading)
        for retained in [store, other] {
            await #expect(throws: WhisperModelDistributionStateStore.StoreError.storageBusy) {
                try await retained.load()
            }
            await #expect(throws: WhisperModelDistributionStateStore.StoreError.storageBusy) {
                try await retained.accept(fixture.receipt(3), expectedGeneration: first.generation)
            }
            await #expect(throws: WhisperModelDistributionStateStore.StoreError.storageBusy) {
                try await retained.rollBack(expectedGeneration: first.generation)
            }
        }
        #expect(try Data(contentsOf: fixture.stateURL) == original)
        try input.fileHandleForWriting.write(contentsOf: Data("C".utf8))
        try awaitMarker("D", from: output.fileHandleForReading)
        let loaded = try #require(await other.load())
        #expect(loaded.generation == second.generation)
        #expect(loaded.release.highestAcceptedSequence == 2)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.staleGeneration) {
            try await store.accept(fixture.receipt(3), expectedGeneration: first.generation)
        }
        let rollback = try await store.rollBack(expectedGeneration: second.generation)
        #expect(rollback.release.highestAcceptedSequence == 2)
        #expect(rollback.release.current.descriptor.releaseSequence == 1)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.staleGeneration) {
            try await other.rollBack(expectedGeneration: second.generation)
        }
    }

    @Test("A held directory lock refuses first acceptance and failures release transaction locks")
    func firstAcceptanceContentionAndFailureCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = try fixture.store()
        let fd = open(fixture.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0)
        defer { _ = testWhisperReleaseFlock(fd, LOCK_UN); close(fd) }
        try #require(testWhisperReleaseFlock(fd, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.storageBusy) {
            try await store.accept(fixture.receipt(1), expectedGeneration: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.stateURL.path))
        try #require(testWhisperReleaseFlock(fd, LOCK_UN) == 0)
        _ = try await store.accept(fixture.receipt(1), expectedGeneration: nil)
        try Data("broken".utf8).write(to: fixture.stateURL)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.invalidState) {
            try await store.load()
        }
        // Failed authentication/read must not retain an OS lock and starve another process.
        try #require(testWhisperReleaseFlock(fd, LOCK_EX | LOCK_NB) == 0)
        try #require(testWhisperReleaseFlock(fd, LOCK_UN) == 0)
        await #expect(throws: WhisperModelDistributionStateStore.StoreError.invalidState) {
            try await store.accept(fixture.receipt(2), expectedGeneration: nil)
        }
        try #require(testWhisperReleaseFlock(fd, LOCK_EX | LOCK_NB) == 0)
    }

    private func awaitMarker(_ expected: String, from handle: FileHandle) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 { continue }
            if ready < 0, errno == EINTR { continue }
            try #require(ready == 1 && descriptor.revents & Int16(POLLIN) != 0,
                         "Lock helper exited without publishing its marker")
            let marker = try handle.read(upToCount: 1)
            try #require(marker == Data(expected.utf8))
            return
        }
        Issue.record("Lock helper did not respond within five seconds")
        throw WhisperModelDistributionStateStore.StoreError.storageBusy
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
