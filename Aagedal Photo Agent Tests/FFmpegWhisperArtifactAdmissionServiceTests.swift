import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Whisper artifact identity admission")
struct FFmpegWhisperArtifactAdmissionServiceTests {
    private func fixture() throws -> URL {
        let root = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(root) }
        let folder = URL(fileURLWithPath: String(cString: root)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("custom executable fixture".utf8).write(to: folder.appendingPathComponent("ffmpeg"))
        try Data("custom model fixture".utf8).write(to: folder.appendingPathComponent("model"))
        #expect(chmod(folder.appendingPathComponent("ffmpeg").path, 0o700) == 0)
        return folder
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("signed app admits its bundled runtime using the sealed post-sign descriptor")
    func signedAppRuntime() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let modelURL = folder.appendingPathComponent("model")
        let model = WhisperDownloadableModel(id: "fixture", title: "Fixture",
            byteCount: Int64(try Data(contentsOf: modelURL).count), sha256: try digest(modelURL),
            url: URL(string: "https://example.com/model")!)
        let service = FFmpegWhisperArtifactAdmissionService()
        let receipt = try await service.admitBundled(modelURL: modelURL, model: model)
        #expect(receipt.buildIdentifier.hasPrefix("bundled-sha256:"))
        #expect(receipt.modelIdentifier == "fixture")
        try await service.revalidate(receipt, configuration: receipt.configuration(language: "en"))
    }

    @Test("an unsigned bundle cannot establish trusted executable pins")
    func unsignedBundle() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Bundle canonicalizes /private/var to /var; use an unaliased cache path
        // so rejection specifically exercises signing rather than path admission.
        let bundleURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperUnsigned-" + UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let contents = bundleURL.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.aagedal.tests.unsigned", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let executable = resources.appendingPathComponent("ffmpeg")
        try FileManager.default.copyItem(at: folder.appendingPathComponent("ffmpeg"), to: executable)
        let manifest: [String: Any] = ["schemaVersion": 1, "executableSHA256": try digest(executable),
            "executableByteCount": try Data(contentsOf: executable).count, "producerContract": "photo-agent-whisper-json-v1"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: resources.appendingPathComponent("whisper-runtime.json"))
        let bundle = try #require(Bundle(url: bundleURL))
        let modelURL = folder.appendingPathComponent("model")
        let model = WhisperDownloadableModel(id: "fixture", title: "Fixture",
            byteCount: Int64(try Data(contentsOf: modelURL).count), sha256: try digest(modelURL),
            url: URL(string: "https://example.com/model")!)
        await #expect(throws: FFmpegWhisperArtifactAdmissionService.AdmissionError.pinMismatch) {
            _ = try await FFmpegWhisperArtifactAdmissionService().admitBundled(modelURL: modelURL, model: model, bundle: bundle)
        }
    }

    @Test("bundled receipts preserve verified provenance and revalidate exact files")
    func bundledReceipt() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("ffmpeg")
        let model = folder.appendingPathComponent("model")
        let service = FFmpegWhisperArtifactAdmissionService()
        let executableHash = try digest(executable)
        let receipt = try await service.admitBundled(executableURL: executable, modelURL: model,
            expectedExecutableSHA256: executableHash, expectedModelSHA256: try digest(model),
            expectedModelByteCount: Int64(try Data(contentsOf: model).count), modelIdentifier: "ggml-base-pinned")
        #expect(receipt.buildIdentifier == "bundled-sha256:" + executableHash)
        #expect(receipt.modelIdentifier == "ggml-base-pinned")
        try await service.revalidate(receipt, configuration: receipt.configuration(language: "en"))
        let forged = FFmpegWhisperTranscriptionProvider.Configuration(executable: receipt.executable,
            buildIdentifier: receipt.buildIdentifier, model: receipt.model, modelIdentifier: "other-model",
            language: "auto", useGPU: false, timeoutSeconds: 60)
        await #expect(throws: FFmpegWhisperArtifactAdmissionService.AdmissionError.configurationMismatch) {
            try await service.revalidate(receipt, configuration: forged)
        }
        let bytes = try Data(contentsOf: executable)
        try Data(repeating: 120, count: bytes.count).write(to: executable)
        await #expect(throws: FFmpegWhisperArtifactAdmissionService.AdmissionError.artifactChanged) {
            try await service.revalidate(receipt, configuration: receipt.configuration())
        }
    }

    @Test("bundled mismatched pins never fall back to custom admission or consume receipt capacity")
    func bundledPins() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("ffmpeg")
        let model = folder.appendingPathComponent("model")
        let service = FFmpegWhisperArtifactAdmissionService()
        let executableHash = try digest(executable)
        let modelHash = try digest(model)
        let size = Int64(try Data(contentsOf: model).count)
        for kind in ["executable", "model", "size", "invalid", "identifier"] {
            await #expect(throws: FFmpegWhisperArtifactAdmissionService.AdmissionError.pinMismatch) {
                _ = try await service.admitBundled(executableURL: executable, modelURL: model,
                    expectedExecutableSHA256: kind == "executable" ? String(repeating: "0", count: 64) : executableHash,
                    expectedModelSHA256: kind == "model" ? String(repeating: "0", count: 64) : kind == "invalid" ? "invalid" : modelHash,
                    expectedModelByteCount: kind == "size" ? size + 1 : size,
                    modelIdentifier: kind == "identifier" ? "" : "pinned-model")
            }
        }
        for _ in 0..<FFmpegWhisperArtifactAdmissionService.maximumReceipts {
            _ = try await service.admitBundled(executableURL: executable, modelURL: model,
                expectedExecutableSHA256: executableHash, expectedModelSHA256: modelHash,
                expectedModelByteCount: size, modelIdentifier: "pinned-model")
        }
    }

    @Test("bundled admission revalidates the model after inference before publishing")
    func bundledMutationDuringInference() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("ffmpeg")
        let model = folder.appendingPathComponent("model")
        let service = FFmpegWhisperArtifactAdmissionService()
        let receipt = try await service.admitBundled(executableURL: executable, modelURL: model,
            expectedExecutableSHA256: try digest(executable), expectedModelSHA256: try digest(model),
            expectedModelByteCount: Int64(try Data(contentsOf: model).count), modelIdentifier: "pinned-model")
        let provider = FFmpegWhisperTranscriptionProvider(configuration: receipt.configuration(),
            authorizeArtifacts: service.authorizer(for: receipt), run: { request in
                let bytes = try Data(contentsOf: model)
                try bytes.write(to: model, options: .atomic)
                return .init(request: request, transcript: .init(
                    segments: [.init(start: 0, end: 1, text: "draft")], editableText: "draft"))
            })
        await #expect(throws: FFmpegWhisperArtifactAdmissionService.AdmissionError.artifactChanged) {
            _ = try await provider.transcribe(audio: receipt.model)
        }
    }

    @Test("custom receipts pin hashes, label unverifiable provenance and support repeated authorization")
    func receipt() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = FFmpegWhisperArtifactAdmissionService()
        let receipt = try await service.admitCustom(executableURL: folder.appendingPathComponent("ffmpeg"),
                                                    modelURL: folder.appendingPathComponent("model"))
        let bytes = try Data(contentsOf: receipt.model.url)
        #expect(receipt.model.byteCount == Int64(bytes.count))
        #expect(receipt.model.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(receipt.buildIdentifier.hasPrefix("custom-unverified-sha256:"))
        #expect(receipt.modelIdentifier.hasPrefix("custom-unverified-sha256:"))
        let authorize = service.authorizer(for: receipt)
        try await authorize(receipt.configuration())
        try await authorize(receipt.configuration(language: "en"))
        await service.revoke(receipt)
        await #expect(throws: FFmpegWhisperArtifactAdmissionService.AdmissionError.revoked) {
            try await authorize(receipt.configuration())
        }
    }

    @Test("same-length mutation and identical-byte path replacement invalidate admission")
    func changed() async throws {
        for replace in [false, true] {
            let folder = try fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            let service = FFmpegWhisperArtifactAdmissionService()
            let receipt = try await service.admitCustom(executableURL: folder.appendingPathComponent("ffmpeg"),
                                                        modelURL: folder.appendingPathComponent("model"))
            let bytes = try Data(contentsOf: receipt.model.url)
            if replace {
                try bytes.write(to: receipt.model.url, options: .atomic)
            } else {
                try Data(repeating: 120, count: bytes.count).write(to: receipt.model.url)
            }
            await #expect(throws: FFmpegWhisperArtifactAdmissionService.AdmissionError.artifactChanged) {
                try await service.revalidate(receipt, configuration: receipt.configuration())
            }
        }
    }

    @Test("configuration cannot relabel a custom artifact as curated")
    func relabel() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = FFmpegWhisperArtifactAdmissionService()
        let receipt = try await service.admitCustom(executableURL: folder.appendingPathComponent("ffmpeg"),
                                                    modelURL: folder.appendingPathComponent("model"))
        let forged = FFmpegWhisperTranscriptionProvider.Configuration(executable: receipt.executable,
            buildIdentifier: "signed-curated", model: receipt.model, modelIdentifier: "curated",
            language: "auto", useGPU: false, timeoutSeconds: 60)
        await #expect(throws: FFmpegWhisperArtifactAdmissionService.AdmissionError.configurationMismatch) {
            try await service.revalidate(receipt, configuration: forged)
        }
    }

    @Test("leaf and ancestor symlinks, hardlinks, empty and non-executable files are refused")
    func unsafeFiles() async throws {
        for kind in ["leaf", "ancestor", "hardlink", "empty", "non-executable", "directory", "fifo"] {
            let folder = try fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            var executable = folder.appendingPathComponent("ffmpeg")
            var model = folder.appendingPathComponent("model")
            switch kind {
            case "leaf":
                let link = folder.appendingPathComponent("link")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: model)
                model = link
            case "ancestor":
                let link = folder.appendingPathComponent("link")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
                model = link.appendingPathComponent("model")
            case "hardlink":
                try FileManager.default.linkItem(at: model, to: folder.appendingPathComponent("alias"))
            case "empty": try Data().write(to: model)
            case "non-executable": #expect(chmod(executable.path, 0o600) == 0)
            case "directory": model = folder
            default:
                executable = folder.appendingPathComponent("fifo")
                #expect(mkfifo(executable.path, 0o700) == 0)
            }
            let candidateExecutable = executable
            let candidateModel = model
            await #expect(throws: FFmpegWhisperArtifactAdmissionService.AdmissionError.self) {
                _ = try await FFmpegWhisperArtifactAdmissionService().admitCustom(
                    executableURL: candidateExecutable, modelURL: candidateModel)
            }
        }
    }

    @Test("cancelled admission creates no usable receipt")
    func cancellation() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FFmpegWhisperArtifactAdmissionService().admitCustom(
                executableURL: folder.appendingPathComponent("ffmpeg"), modelURL: folder.appendingPathComponent("model"))
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("session admission is bounded and explicit revocation releases capacity")
    func capacity() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = FFmpegWhisperArtifactAdmissionService()
        var receipts: [FFmpegWhisperArtifactAdmissionService.Receipt] = []
        for _ in 0..<FFmpegWhisperArtifactAdmissionService.maximumReceipts {
            receipts.append(try await service.admitCustom(executableURL: folder.appendingPathComponent("ffmpeg"),
                                                         modelURL: folder.appendingPathComponent("model")))
        }
        await #expect(throws: FFmpegWhisperArtifactAdmissionService.AdmissionError.capacityExceeded) {
            _ = try await service.admitCustom(executableURL: folder.appendingPathComponent("ffmpeg"),
                                             modelURL: folder.appendingPathComponent("model"))
        }
        await service.revoke(try #require(receipts.first))
        _ = try await service.admitCustom(executableURL: folder.appendingPathComponent("ffmpeg"),
                                         modelURL: folder.appendingPathComponent("model"))
    }

    @Test("revocation during inference refuses publication through the production authorizer")
    func revokeDuringInference() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = FFmpegWhisperArtifactAdmissionService()
        let receipt = try await service.admitCustom(executableURL: folder.appendingPathComponent("ffmpeg"),
                                                    modelURL: folder.appendingPathComponent("model"))
        let provider = FFmpegWhisperTranscriptionProvider(configuration: receipt.configuration(),
            authorizeArtifacts: service.authorizer(for: receipt), run: { request in
                await service.revoke(receipt)
                return .init(request: request, transcript: .init(
                    segments: [.init(start: 0, end: 1, text: "draft")], editableText: "draft"))
            })
        await #expect(throws: FFmpegWhisperArtifactAdmissionService.AdmissionError.revoked) {
            _ = try await provider.transcribe(audio: receipt.model)
        }
    }
}
