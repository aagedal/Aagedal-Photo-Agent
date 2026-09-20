import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("FFmpeg Whisper owned process jobs")
struct FFmpegWhisperJobRunnerTests {
    private func directory() throws -> URL {
        let root = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(root) }
        let url = URL(fileURLWithPath: String(cString: root)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func input(_ text: String, name: String, directory: URL) throws -> FFmpegWhisperJobInput {
        let bytes = Data(text.utf8)
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return .init(url: url, byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    private func request(_ script: String, directory: URL, timeout: Double = 3, language: String = "auto") throws -> FFmpegWhisperJobRequest {
        .init(executable: try input("#!/bin/sh\n" + script, name: "producer", directory: directory),
              audio: try input("wave fixture", name: "audio.wav", directory: directory),
              model: try input("model fixture", name: "model.bin", directory: directory),
              language: language, useGPU: false, timeoutSeconds: timeout)
    }

    @Test("Successful child yields canonical source-bound result and removes its private output")
    func successAndCleanup() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let witness = directory.appendingPathComponent("job-path")
        let request = try request("pwd > '\(witness.path)'\nprintf '%s' '{\"start\":0,\"end\":100,\"text\":\"Hei!\"}' > output.json\n", directory: directory)
        let result = try await FFmpegWhisperJobRunner().run(request)
        #expect(result.request == request)
        #expect(result.transcript.editableText == "Hei!")
        let job = try String(contentsOf: witness, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: job))
        #expect(FileManager.default.fileExists(atPath: request.audio.url.path))
    }

    @Test("A valid-looking output cannot override failed process termination")
    func failedProcess() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try request("printf '%s' '{\"start\":0,\"end\":100,\"text\":\"Hello\"}' > output.json\nexit 7", directory: directory)
        await #expect(throws: FFmpegWhisperJobError.processFailed(.exited(status: 7))) {
            try await FFmpegWhisperJobRunner().run(request)
        }
    }

    @Test("A stuck direct child is killed on deadline")
    func deadline() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try request("while :; do :; done", directory: directory, timeout: 0.05)
        await #expect(throws: FFmpegWhisperJobError.timedOut) {
            try await FFmpegWhisperJobRunner().run(request)
        }
    }

    @Test("Cancellation waits for child exit and removes the owned job")
    func cancellation() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let witness = directory.appendingPathComponent("job-path")
        let request = try request("pwd > '\(witness.path)'\nwhile :; do :; done", directory: directory)
        let task = Task { try await FFmpegWhisperJobRunner().run(request) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: witness.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let job = try String(contentsOf: witness, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: job))
    }

    @Test("Oversized output kills the producer and removes its owned job without publication")
    func oversizedOutput() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let witness = directory.appendingPathComponent("job-path")
        // Shell builtins only: after exceeding the output budget the direct child remains alive
        // until the runner detects the file size and reaps it. No helper process can outlive cleanup.
        let size = FFmpegWhisperJSONParser.maximumOutputBytes + 1
        let request = try request("pwd > '\(witness.path)'\nprintf '%\(size)s' x > output.json\nwhile :; do :; done", directory: directory)
        await #expect(throws: FFmpegWhisperJobError.outputTooLarge) {
            try await FFmpegWhisperJobRunner().run(request)
        }
        let job = try String(contentsOf: witness, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: job))
        #expect(FileManager.default.fileExists(atPath: request.audio.url.path))
        #expect(FileManager.default.fileExists(atPath: request.model.url.path))
    }

    @Test("A successful child without canonical output fails and removes its owned job")
    func missingOutput() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let witness = directory.appendingPathComponent("job-path")
        let request = try request("pwd > '\(witness.path)'\nexit 0", directory: directory)
        await #expect(throws: FFmpegWhisperOutputError.unsafeFile) {
            try await FFmpegWhisperJobRunner().run(request)
        }
        let job = try String(contentsOf: witness, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: job))
    }

    @Test("Canonical output parsing remains mandatory after successful exit")
    func malformedOutput() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try request("printf '%s' 'console transcript' > output.json", directory: directory)
        await #expect(throws: FFmpegWhisperJSONError.malformedSegment(line: 1)) {
            try await FFmpegWhisperJobRunner().run(request)
        }
    }

    @Test("An empty successful inference reports no speech")
    func noSpeech() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try request(": > output.json", directory: directory)
        await #expect(throws: FFmpegWhisperJSONError.noSpeech) {
            try await FFmpegWhisperJobRunner().run(request)
        }
    }

    @Test("Repeated immediate signal exits cannot publish output or strand teardown")
    func signalledChild() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try request("kill -KILL $$", directory: directory)
        let runner = FFmpegWhisperJobRunner()
        for _ in 0..<20 {
            await #expect(throws: FFmpegWhisperJobError.processFailed(.signalled(signal: SIGKILL))) {
                try await runner.run(request)
            }
        }
    }

    @Test("FIFO admission is nonblocking and refuses special inputs")
    func specialInput() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try request("exit 0", directory: directory)
        try FileManager.default.removeItem(at: request.model.url)
        #expect(mkfifo(request.model.url.path, 0o600) == 0)
        await #expect(throws: FFmpegWhisperJobError.unsafeInput) {
            try await FFmpegWhisperJobRunner().run(request)
        }
    }

    @Test("Exact-byte authority rejects same-size model changes before execution")
    func identityMismatch() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try request("exit 0", directory: directory)
        try Data("MODEL fixture".utf8).write(to: request.model.url)
        await #expect(throws: FFmpegWhisperJobError.identityMismatch) {
            try await FFmpegWhisperJobRunner().run(request)
        }
    }

    @Test("Symlink inputs cannot provide authorized bytes")
    func symlink() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try request("exit 0", directory: directory)
        let original = directory.appendingPathComponent("original")
        try FileManager.default.moveItem(at: request.model.url, to: original)
        try FileManager.default.createSymbolicLink(at: request.model.url, withDestinationURL: original)
        await #expect(throws: FFmpegWhisperJobError.unsafeInput) {
            try await FFmpegWhisperJobRunner().run(request)
        }
    }

    @Test("Untrusted filter text is refused and invocation admits WAV file input only")
    func argumentAuthority() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = try request("exit 0", directory: directory, language: "en:destination=elsewhere")
        await #expect(throws: FFmpegWhisperJobError.invalidRequest) {
            try await FFmpegWhisperJobRunner().run(invalid)
        }
        let valid = try request("exit 0", directory: directory)
        let args = FFmpegWhisperJobRunner.arguments(valid)
        #expect(args.contains("file"))
        #expect(args.contains("-xerror"))
        #expect(args.contains { $0.contains(":translate=false:") })
        #expect(args.contains("wav"))
        #expect(!args.joined().contains(valid.audio.url.path))
        #expect(args.contains { $0.contains("max_len=0:destination=output.json:format=json") })
    }
}
