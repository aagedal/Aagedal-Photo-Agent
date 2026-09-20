import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Managed Whisper model downloads")
struct WhisperModelDownloadServiceTests {
    private let bytes = Data("ggml model fixture".utf8)

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func model() -> WhisperDownloadableModel {
        WhisperDownloadableModel(id: "fixture", title: "Fixture", byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://example.com/immutable-model.bin")!)
    }

    @Test("Catalog pins multilingual weights to immutable revisions and exact identities")
    func catalog() {
        #expect(WhisperDownloadableModel.catalog.map(\.id) == ["tiny", "base", "small"])
        #expect(WhisperDownloadableModel.catalog.map(\.byteCount) == [77_691_713, 147_951_465, 487_601_967])
        for model in WhisperDownloadableModel.catalog {
            #expect(model.url.path.contains(WhisperDownloadableModel.revision))
            #expect(model.url.host == "huggingface.co")
            #expect(model.sha256.count == 64)
        }
    }

    @Test("Verified download publishes a private model and reuse avoids network")
    func downloadAndReuse() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = bytes
        let service = WhisperModelDownloadService(directory: root, fetch: { _, destination, progress in
            try bytes.write(to: destination)
            progress(0.5)
        })
        #expect(try await service.installedURL(for: model()) == nil)
        let result = try await service.download(model())
        #expect(try Data(contentsOf: result) == bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: result.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let reuse = WhisperModelDownloadService(directory: root, fetch: { _, _, _ in
            throw URLError(.notConnectedToInternet)
        })
        #expect(try await reuse.download(model()) == result)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["ggml-fixture.bin"])
        try await reuse.remove(model())
        #expect(try await reuse.installedURL(for: model()) == nil)
    }

    @Test("Corrupt and truncated downloads never publish and partial files are removed", arguments: [false, true])
    func invalidDownload(truncated: Bool) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let count = bytes.count
        let service = WhisperModelDownloadService(directory: root, fetch: { _, destination, _ in
            try Data(repeating: 0, count: truncated ? count - 1 : count).write(to: destination)
        })
        let error: WhisperModelDownloadService.DownloadError = truncated ? .sizeMismatch : .checksumMismatch
        await #expect(throws: error) { _ = try await service.download(model()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Failed replacement preserves the existing file")
    func preserveExisting() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("ggml-fixture.bin")
        let old = Data("previous model".utf8)
        try old.write(to: target)
        let service = WhisperModelDownloadService(directory: root, fetch: { _, destination, _ in
            try Data("bad".utf8).write(to: destination)
        })
        await #expect(throws: WhisperModelDownloadService.DownloadError.sizeMismatch) {
            _ = try await service.download(model())
        }
        #expect(try Data(contentsOf: target) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["ggml-fixture.bin"])
    }

    @Test("Cancellation after transfer cleans partial output and allows retry")
    func cancellation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = bytes
        let service = WhisperModelDownloadService(directory: root, fetch: { _, destination, _ in
            try bytes.write(to: destination)
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let model = model()
        let download = Task { try await service.download(model) }
        await #expect(throws: CancellationError.self) { _ = try await download.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let retry = WhisperModelDownloadService(directory: root, fetch: { _, destination, _ in try bytes.write(to: destination) })
        #expect(try await retry.download(model).lastPathComponent == "ggml-fixture.bin")
    }

    @Test("Changed installed model is rejected")
    func installedMutation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = bytes
        let service = WhisperModelDownloadService(directory: root, fetch: { _, destination, _ in try bytes.write(to: destination) })
        let installed = try await service.download(model())
        try Data(repeating: 0, count: bytes.count).write(to: installed)
        await #expect(throws: WhisperModelDownloadService.DownloadError.checksumMismatch) {
            _ = try await service.installedURL(for: model())
        }
    }

    @Test("Symlinks and hardlinks cannot masquerade as installed models", arguments: [false, true])
    func unsafeLeaf(hardlink: Bool) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("external")
        let target = root.appendingPathComponent("ggml-fixture.bin")
        try bytes.write(to: external)
        if hardlink { try FileManager.default.linkItem(at: external, to: target) }
        else { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external) }
        let service = WhisperModelDownloadService(directory: root)
        await #expect(throws: WhisperModelDownloadService.DownloadError.unsafeStorage) {
            _ = try await service.installedURL(for: model())
        }
        try await service.remove(model())
        #expect(try Data(contentsOf: external) == bytes)
    }

    @Test("Dangling links refuse download before fetching")
    func danglingInstalledLink() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        let target = root.appendingPathComponent("ggml-fixture.bin")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: missing)
        let service = WhisperModelDownloadService(directory: root, fetch: { _, _, _ in
            Issue.record("Unsafe cached entry must be refused before fetching")
        })
        await #expect(throws: WhisperModelDownloadService.DownloadError.unsafeStorage) {
            _ = try await service.installedURL(for: model())
        }
        await #expect(throws: WhisperModelDownloadService.DownloadError.unsafeStorage) {
            _ = try await service.download(model())
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == missing.path)
    }

    @Test("Linked parent is refused before creating model storage")
    func linkedParent() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: external)
        let service = WhisperModelDownloadService(directory: linked.appendingPathComponent("models"))
        await #expect(throws: WhisperModelDownloadService.DownloadError.unsafeStorage) {
            _ = try await service.download(model())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test("Linked transfer output is refused without changing its source", arguments: [false, true])
    func linkedTransferOutput(hardlink: Bool) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("external")
        try bytes.write(to: external)
        #expect(chmod(external.path, 0o640) == 0)
        let service = WhisperModelDownloadService(directory: root, fetch: { _, destination, _ in
            if hardlink { try FileManager.default.linkItem(at: external, to: destination) }
            else { try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: external) }
        })
        await #expect(throws: WhisperModelDownloadService.DownloadError.unsafeStorage) {
            _ = try await service.download(model())
        }
        #expect(try Data(contentsOf: external) == bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: external.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["external"])
    }

    @Test("A model appearing during transfer is preserved")
    func targetAppearsDuringTransfer() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = bytes
        let target = root.appendingPathComponent("ggml-fixture.bin")
        let service = WhisperModelDownloadService(directory: root, fetch: { _, destination, _ in
            try bytes.write(to: destination)
            try bytes.write(to: target)
        })
        await #expect(throws: WhisperModelDownloadService.DownloadError.storageChanged) {
            _ = try await service.download(model())
        }
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["ggml-fixture.bin"])
        #expect(try await service.installedURL(for: model()) == target)
    }

    @Test("Storage replacement refuses publication and cleans only the original partial")
    func replacedDirectory() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("models")
        let moved = root.appendingPathComponent("moved")
        let bytes = bytes
        let service = WhisperModelDownloadService(directory: storage, fetch: { _, destination, _ in
            try bytes.write(to: destination)
            try FileManager.default.moveItem(at: storage, to: moved)
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            // A replacement root's coincidentally named partial belongs to someone else.
            try bytes.write(to: destination)
        })
        await #expect(throws: WhisperModelDownloadService.DownloadError.storageChanged) {
            _ = try await service.download(model())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)
        #expect(remaining.count == 1)
        #expect(remaining.first?.pathExtension == "partial")
        if let partial = remaining.first { #expect(try Data(contentsOf: partial) == bytes) }
    }

    private actor RetryTransfer {
        var attempts = 0
        func shouldFail() -> Bool {
            attempts += 1
            return attempts == 1
        }
    }

    @Test("Interrupted transfer preserves the old file and the same service can retry")
    func interruptedTransferRetry() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("ggml-fixture.bin")
        let old = Data("old incomplete model".utf8)
        try old.write(to: target)
        let bytes = bytes
        let transfer = RetryTransfer()
        let service = WhisperModelDownloadService(directory: root, fetch: { _, destination, _ in
            try bytes.write(to: destination)
            if await transfer.shouldFail() { throw URLError(.networkConnectionLost) }
        })
        await #expect(throws: URLError.self) { _ = try await service.download(model()) }
        #expect(try Data(contentsOf: target) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["ggml-fixture.bin"])
        #expect(try await service.download(model()) == target)
        #expect(try Data(contentsOf: target) == bytes)
    }

    private actor TransferGate {
        var started = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pause() async {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        func resume() { continuation?.resume(); continuation = nil }
    }

    @Test("Concurrent download and removal are refused while a transfer is active")
    func busy() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = bytes
        let gate = TransferGate()
        let service = WhisperModelDownloadService(directory: root, fetch: { _, destination, _ in
            await gate.pause()
            try bytes.write(to: destination)
        })
        let model = model()
        let first = Task { try await service.download(model) }
        while !(await gate.started) { await Task.yield() }
        await #expect(throws: WhisperModelDownloadService.DownloadError.busy) {
            _ = try await service.download(model)
        }
        await #expect(throws: WhisperModelDownloadService.DownloadError.busy) {
            try await service.remove(model)
        }
        await gate.resume()
        _ = try await first.value
    }

    @Test("Path traversal model IDs are rejected before fetching")
    func unsafeID() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = model()
        let invalid = WhisperDownloadableModel(id: "../../escape", title: good.title, byteCount: good.byteCount, sha256: good.sha256, url: good.url)
        await #expect(throws: WhisperModelDownloadService.DownloadError.invalidModel) {
            _ = try await WhisperModelDownloadService(directory: root).download(invalid)
        }
    }
}
