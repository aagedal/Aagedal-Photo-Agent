import CryptoKit
import Darwin
import Foundation

nonisolated enum FFmpegWhisperJobError: Error, Equatable, Sendable {
    case invalidRequest
    case unsafeInput
    case inputChanged
    case identityMismatch
    case launchFailed
    case timedOut
    case outputTooLarge
    case processFailed(FFmpegWhisperProducerCompletion)
}

/// Exact bytes authorized by the caller. Hashes identify content; they do not establish curated
/// provenance, code signing, model compatibility or permission to execute an arbitrary binary.
nonisolated struct FFmpegWhisperJobInput: Equatable, Sendable {
    let url: URL
    let byteCount: Int64
    let sha256: String
}

nonisolated struct FFmpegWhisperJobRequest: Equatable, Sendable {
    let executable: FFmpegWhisperJobInput
    let audio: FFmpegWhisperJobInput
    let model: FFmpegWhisperJobInput
    let language: String
    let useGPU: Bool
    let timeoutSeconds: Double
}

/// An inference result, never a reviewed/approved transcript. The provider must still revalidate
/// the photo/audio relationship and persist exact build/model provenance before publishing a draft.
nonisolated struct FFmpegWhisperJobResult: Sendable {
    let request: FFmpegWhisperJobRequest
    let transcript: FFmpegWhisperTranscript
}

/// Opt-in process foundation. No executable/model discovery, download or provider fallback occurs.
/// The eventual provider must supply its verified, patched, statically linked FFmpeg artifact.
/// Private snapshots prevent path substitution between input hashing and child-process opening.
actor FFmpegWhisperJobRunner {
    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.whisper-job", qos: .utility
    )
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    func run(_ request: FFmpegWhisperJobRequest) async throws -> FFmpegWhisperJobResult {
        try Task.checkCancellation()
        try Self.validate(request)
        let job = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: job) }
        let executable = job.appendingPathComponent("ffmpeg")
        let audio = job.appendingPathComponent("input.wav")
        let model = job.appendingPathComponent("model.bin")
        let output = job.appendingPathComponent("output.json")
        try Self.snapshot(request.executable, to: executable)
        try Self.snapshot(request.audio, to: audio)
        try Self.snapshot(request.model, to: model)
        guard chmod(executable.path, 0o500) == 0 else { throw FFmpegWhisperJobError.unsafeInput }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = job
        process.arguments = Self.arguments(request)
        // Do not inherit report/debug/dynamic-loader environment or unbounded output pipes.
        process.environment = ["LC_ALL": "C", "HOME": job.path, "TMPDIR": job.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try process.run() }
        catch { throw FFmpegWhisperJobError.launchFailed }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(request.timeoutSeconds))
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw FFmpegWhisperJobError.timedOut }
                var outputInfo = stat()
                if lstat(output.path, &outputInfo) == 0,
                   outputInfo.st_size > FFmpegWhisperJSONParser.maximumOutputBytes {
                    throw FFmpegWhisperJobError.outputTooLarge
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            let completion: FFmpegWhisperProducerCompletion = process.terminationReason == .exit
                ? .exited(status: process.terminationStatus) : .signalled(signal: process.terminationStatus)
            guard completion == .exited(status: 0) else {
                throw FFmpegWhisperJobError.processFailed(completion)
            }
            let transcript = try FFmpegWhisperOutputReader.read(from: output, completion: completion)
            try Task.checkCancellation()
            return .init(request: request, transcript: transcript)
        } catch {
            // Reap before deleting owned inputs/output. SIGKILL avoids a child that ignores TERM
            // retaining the job indefinitely; only the directly launched process is supported.
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            // Foundation owns reaping. Its isRunning flag becomes false after termination is
            // collected, so a second synchronous wait is unnecessary and can strand this actor
            // in a thread-local run loop after an async executor hop. Observe completion without
            // inheriting the failed task's cancellation (which would turn sleeps into a spin).
            while process.isRunning {
                await Task.detached {
                    try? await Task.sleep(for: .milliseconds(10))
                }.value
            }
            throw error
        }
    }

    nonisolated static func arguments(_ request: FFmpegWhisperJobRequest) -> [String] {
        ["-hide_banner", "-nostdin", "-xerror", "-loglevel", "error", "-protocol_whitelist", "file",
         "-format_whitelist", "wav", "-f", "wav", "-i", "input.wav", "-map", "0:a:0",
         "-vn", "-sn", "-dn", "-af",
         "whisper=model=model.bin:language=\(request.language):use_gpu=\(request.useGPU ? "true" : "false"):translate=false:max_len=0:destination=output.json:format=json",
         "-f", "null", "-"]
    }

    private nonisolated static func validate(_ request: FFmpegWhisperJobRequest) throws {
        guard request.timeoutSeconds.isFinite, request.timeoutSeconds > 0,
              request.timeoutSeconds <= 3600,
              request.language == "auto" || (request.language.utf8.count == 2 &&
                  request.language.utf8.allSatisfy({ (97...122).contains($0) })) else {
            throw FFmpegWhisperJobError.invalidRequest
        }
        for (input, maximum) in [(request.executable, Int64(512 * 1024 * 1024)),
                                  (request.audio, Int64(512 * 1024 * 1024)),
                                  (request.model, Int64(4) * 1024 * 1024 * 1024)] {
            guard input.url.isFileURL, input.url.host == nil || input.url.host == "" || input.url.host == "localhost",
                  input.url.path.hasPrefix("/"), !input.url.path.utf8.contains(0),
                  input.byteCount > 0, input.byteCount <= maximum,
                  input.sha256.utf8.count == 64,
                  input.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw FFmpegWhisperJobError.invalidRequest
            }
        }
    }

    private nonisolated static func makeDirectory() throws -> URL {
        guard let root = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw FFmpegWhisperJobError.unsafeInput
        }
        defer { free(root) }
        var template = Array((String(cString: root) + "/photo-whisper-XXXXXXXX").utf8CString)
        guard let result = mkdtemp(&template) else { throw FFmpegWhisperJobError.unsafeInput }
        return URL(fileURLWithPath: String(cString: result), isDirectory: true)
    }

    private nonisolated static func openInput(_ url: URL) throws -> Int32 {
        let components = url.path.split(separator: "/")
        guard !components.isEmpty, !components.contains("."), !components.contains("..") else {
            throw FFmpegWhisperJobError.unsafeInput
        }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw FFmpegWhisperJobError.unsafeInput }
        defer { close(parent) }
        for component in components.dropLast() {
            let next = openat(parent, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw FFmpegWhisperJobError.unsafeInput }
            close(parent)
            parent = next
        }
        let descriptor = openat(parent, String(components.last!), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw FFmpegWhisperJobError.unsafeInput }
        return descriptor
    }

    private nonisolated static func snapshot(_ input: FFmpegWhisperJobInput, to output: URL) throws {
        try Task.checkCancellation()
        let source = try openInput(input.url)
        defer { close(source) }
        var before = stat()
        guard fstat(source, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size == input.byteCount else {
            throw FFmpegWhisperJobError.unsafeInput
        }
        let target = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard target >= 0 else { throw FFmpegWhisperJobError.unsafeInput }
        defer { close(target) }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(source, &buffer, min(buffer.count, Int(input.byteCount - total + 1)))
            if count < 0 {
                if errno == EINTR { continue }
                throw FFmpegWhisperJobError.unsafeInput
            }
            if count == 0 { break }
            total += Int64(count)
            guard total <= input.byteCount else { throw FFmpegWhisperJobError.inputChanged }
            hash.update(data: Data(buffer.prefix(count)))
            try buffer.withUnsafeBytes { bytes in
                var written = 0
                while written < count {
                    let amount = Darwin.write(target, bytes.baseAddress!.advanced(by: written), count - written)
                    if amount < 0, errno == EINTR { continue }
                    guard amount > 0 else { throw FFmpegWhisperJobError.unsafeInput }
                    written += amount
                }
            }
        }
        var after = stat()
        guard fstat(source, &after) == 0, total == input.byteCount,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw FFmpegWhisperJobError.inputChanged }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == input.sha256 else { throw FFmpegWhisperJobError.identityMismatch }
        guard fsync(target) == 0, fchmod(target, 0o400) == 0 else { throw FFmpegWhisperJobError.unsafeInput }
    }
}
