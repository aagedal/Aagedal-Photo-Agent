import CryptoKit
import Darwin
import Foundation
import os

nonisolated enum FFmpegWhisperJobError: LocalizedError, Equatable, Sendable {
    case invalidRequest
    case unsafeInput
    case inputChanged
    case identityMismatch
    case launchFailed
    case timedOut
    case outputTooLarge
    case processFailed(FFmpegWhisperProducerCompletion)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "The Whisper configuration is invalid. Select compatible custom files and enable them again."
        case .unsafeInput:
            return "Whisper could not safely read the selected files. Choose regular files without symbolic links and enable them again."
        case .inputChanged, .identityMismatch:
            return "A Whisper input no longer matches its recorded identity. Refresh the voice memo and select and enable the custom files again."
        case .launchFailed:
            return "The selected FFmpeg could not be launched. Choose an executable build compatible with this Mac and the patched Whisper JSON filter."
        case .timedOut:
            return "Whisper exceeded the transcription time limit. Try a smaller compatible model or a shorter voice memo."
        case .outputTooLarge:
            return "Whisper output exceeded the supported size limit. Try a shorter voice memo."
        case .processFailed:
            return "FFmpeg could not finish Whisper transcription. Check that the executable includes the patched Whisper JSON filter and supports the selected model."
        }
    }
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
    let translate: Bool

    init(executable: FFmpegWhisperJobInput, audio: FFmpegWhisperJobInput,
         model: FFmpegWhisperJobInput, language: String, useGPU: Bool,
         timeoutSeconds: Double, translate: Bool = false) {
        self.executable = executable
        self.audio = audio
        self.model = model
        self.language = language
        self.useGPU = useGPU
        self.timeoutSeconds = timeoutSeconds
        self.translate = translate
    }
}

/// An inference result, not yet a saved transcript. The provider must still revalidate
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
    private let snapshots: FFmpegWhisperVerifiedSnapshotCache

    init(snapshots: FFmpegWhisperVerifiedSnapshotCache = .shared) {
        self.snapshots = snapshots
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
        // The executable and model are the same for every memo in a session: each job gets an
        // APFS clone of a snapshot verified once (see `FFmpegWhisperVerifiedSnapshotCache`)
        // instead of re-copying and re-hashing a multi-GB model per memo. The executable's
        // session snapshot is always rewritten (never cloned from the source), so it carries no
        // source xattrs such as quarantine; the per-job clones inherit that clean copy.
        try snapshots.materialize(request.executable, to: executable, allowCloneFromSource: false)
        try Self.snapshot(request.audio, to: audio, allowClone: true)
        try snapshots.materialize(request.model, to: model, allowCloneFromSource: true)
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
         "whisper=model=model.bin:language=\(request.language):use_gpu=\(request.useGPU ? "true" : "false"):translate=\(request.translate ? "true" : "false"):max_len=0:destination=output.json:format=json",
         "-f", "null", "-"]
    }

    private nonisolated static func validate(_ request: FFmpegWhisperJobRequest) throws {
        guard request.timeoutSeconds.isFinite, request.timeoutSeconds > 0,
              request.timeoutSeconds <= 3600,
              WhisperTranscriptionLanguage.isValid(request.language) else {
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

    fileprivate nonisolated static func openInput(_ url: URL) throws -> Int32 {
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

    /// Opens `input` without following links and checks it is the expected regular, singly
    /// linked file. The caller owns (and must close) the returned descriptor.
    fileprivate nonisolated static func openVerifiedSource(_ input: FFmpegWhisperJobInput) throws -> (descriptor: Int32, info: stat) {
        try Task.checkCancellation()
        let source = try openInput(input.url)
        var before = stat()
        guard fstat(source, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size == input.byteCount else {
            close(source)
            throw FFmpegWhisperJobError.unsafeInput
        }
        return (source, before)
    }

    private nonisolated static func snapshot(_ input: FFmpegWhisperJobInput, to output: URL,
                                             allowClone: Bool) throws {
        let source = try openVerifiedSource(input)
        defer { close(source.descriptor) }
        _ = try snapshot(source: source.descriptor, before: source.info, input, to: output, allowClone: allowClone)
    }

    /// Creates `output` as a private copy (or same-volume clone) of the open `source`, verifies
    /// the exact pinned bytes with one SHA-256 pass, makes it read-only and returns its final
    /// stat. A failed snapshot leaves `output` for the caller's directory cleanup.
    fileprivate nonisolated static func snapshot(source: Int32, before: stat, _ input: FFmpegWhisperJobInput,
                                                 to output: URL, allowClone: Bool) throws -> stat {
        // Same APFS volume: an atomic copy-on-write clone is an equally isolated snapshot without
        // rewriting a multi-GB model. The clone is then verified against the pin.
        if allowClone, fclonefileat(source, AT_FDCWD, output.path, 0) == 0 {
            return try verifyClone(at: output, expected: input)
        }
        let target = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard target >= 0 else { throw FFmpegWhisperJobError.unsafeInput }
        defer { close(target) }
        FFmpegWhisperHashObserver.current?(input.url)
        var hash = SHA256()
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: FFmpegWhisperHashObserver.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(source, buffer.baseAddress, min(buffer.count, Int(input.byteCount - total + 1)))
            if count < 0 {
                if errno == EINTR { continue }
                throw FFmpegWhisperJobError.unsafeInput
            }
            if count == 0 { break }
            total += Int64(count)
            guard total <= input.byteCount else { throw FFmpegWhisperJobError.inputChanged }
            let chunk = UnsafeRawBufferPointer(rebasing: buffer[0..<count])
            hash.update(bufferPointer: chunk)
            var written = 0
            while written < count {
                let amount = Darwin.write(target, chunk.baseAddress!.advanced(by: written), count - written)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw FFmpegWhisperJobError.unsafeInput }
                written += amount
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
        var final = stat()
        guard fsync(target) == 0, fchmod(target, 0o400) == 0, fstat(target, &final) == 0 else {
            throw FFmpegWhisperJobError.unsafeInput
        }
        return final
    }

    /// The clone is private to this process's directory, so hashing it proves exactly what the
    /// producer reads. Returns the verified clone's final stat.
    private nonisolated static func verifyClone(at url: URL, expected input: FFmpegWhisperJobInput) throws -> stat {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FFmpegWhisperJobError.unsafeInput }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == input.byteCount, fchmod(descriptor, 0o400) == 0 else {
            throw FFmpegWhisperJobError.inputChanged
        }
        FFmpegWhisperHashObserver.current?(input.url)
        var hash = SHA256()
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: FFmpegWhisperHashObserver.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw FFmpegWhisperJobError.unsafeInput
            }
            if count == 0 { break }
            total += Int64(count)
            guard total <= input.byteCount else { throw FFmpegWhisperJobError.inputChanged }
            hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
        }
        guard total == input.byteCount else { throw FFmpegWhisperJobError.inputChanged }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == input.sha256 else { throw FFmpegWhisperJobError.identityMismatch }
        var final = stat()
        guard fstat(descriptor, &final) == 0 else { throw FFmpegWhisperJobError.unsafeInput }
        return final
    }
}

/// Test seam and shared constants for full-content SHA-256 passes over Whisper artifacts
/// (admission and job snapshots). The observer is task-local, so concurrently running tests
/// count only their own passes.
nonisolated enum FFmpegWhisperHashObserver {
    @TaskLocal static var current: (@Sendable (URL) -> Void)?
    /// One reused 4 MiB buffer per pass keeps multi-GB model hashing I/O bound instead of
    /// allocating a `Data` per 64 KiB chunk.
    static let bufferSize = 4 * 1024 * 1024
}

/// Session cache of verified, private, read-only snapshots of the FFmpeg executable and the
/// Whisper model, so a batch of memos verifies each multi-GB artifact once instead of copying
/// and hashing it again for every job.
///
/// Security reasoning. The runner's guarantee is that the bytes the child executes and loads
/// are exactly the pinned (SHA-256, byte count) bytes, closing path substitution between
/// hashing and launch. That still holds:
/// - A snapshot is created by this process in its own `mkdtemp` (0700) directory, from a source
///   opened without following links (regular file, one link, expected size), verified by a full
///   SHA-256 pass against the pin and set to 0400. Nothing else ever writes it.
/// - Before every reuse, and again after cloning it into the job directory, the snapshot's full
///   stat identity is compared with the identity recorded right after verification: device,
///   inode, size, mode, owner, link count, mtime and ctime. Any write, truncate, chmod/chown,
///   hard link or rename-replace changes at least one of these, and ctime cannot be set back by
///   user tools, so an unchanged identity proves the per-job APFS clone carries the verified
///   bytes. Any mismatch discards the snapshot and re-verifies from the source.
/// - The source is still opened and checked for every job, and a changed source identity
///   discards its snapshot, so a replaced or modified source is re-snapshotted and re-hashed
///   (and the job fails if its bytes no longer match the pin) exactly as before.
/// The threat model is unchanged: a same-user process able to write into our temporary
/// directory could equally have modified a per-job snapshot between verification and launch.
/// Snapshots are removed on eviction (LRU, idle timeout), at app termination, and stale
/// directories from crashed sessions are swept when a new one is created.
nonisolated final class FFmpegWhisperVerifiedSnapshotCache: Sendable {
    static let shared: FFmpegWhisperVerifiedSnapshotCache = {
        let cache = FFmpegWhisperVerifiedSnapshotCache()
        // AppKit's NSApplicationWillTerminateNotification, by name so this service stays AppKit-free.
        _ = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: nil
        ) { _ in cache.removeAll() }
        return cache
    }()

    struct FileIdentity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let mode: UInt16
        let owner: UInt32
        let links: UInt16
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size; mode = info.st_mode
            owner = info.st_uid; links = info.st_nlink
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    private struct Key: Hashable {
        let path: String
        let byteCount: Int64
        let sha256: String
        let allowCloneFromSource: Bool
    }

    private struct Entry {
        let snapshotPath: String
        let source: FileIdentity
        let snapshot: FileIdentity
        var lastUse: ContinuousClock.Instant
    }

    private struct State {
        var directory: String?
        var entries: [Key: Entry] = [:]
    }

    private static let directoryPrefix = "photo-whisper-snapshots-"
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let capacity: Int
    private let idleLifetime: Duration

    /// Two entries cover the steady state (one executable, one model); switching models evicts
    /// the older snapshot, bounding temporary disk use when the model cannot be cloned.
    init(capacity: Int = 2, idleLifetime: Duration = .seconds(30 * 60)) {
        self.capacity = max(1, capacity)
        self.idleLifetime = idleLifetime
    }

    /// Places a private, read-only file with exactly `input`'s pinned bytes at `destination`
    /// (which must not exist). Reuses a verified snapshot when both it and the source are
    /// unchanged; otherwise snapshots and verifies the source first.
    func materialize(_ input: FFmpegWhisperJobInput, to destination: URL, allowCloneFromSource: Bool) throws {
        let source = try FFmpegWhisperJobRunner.openVerifiedSource(input)
        defer { close(source.descriptor) }
        let key = Key(path: input.url.path, byteCount: input.byteCount, sha256: input.sha256,
                      allowCloneFromSource: allowCloneFromSource)
        let sourceIdentity = FileIdentity(source.info)
        if let entry = reusableEntry(for: key, source: sourceIdentity) {
            if cloneSnapshot(entry, to: destination) { return }
            discard(key, ifSnapshotAt: entry.snapshotPath)
        }
        try Task.checkCancellation()
        let directory = try snapshotDirectory()
        let path = directory + "/" + UUID().uuidString
        let verified: stat
        do {
            verified = try FFmpegWhisperJobRunner.snapshot(source: source.descriptor, before: source.info, input,
                                                           to: URL(fileURLWithPath: path),
                                                           allowClone: allowCloneFromSource)
        } catch {
            _ = unlink(path)
            throw error
        }
        let entry = Entry(snapshotPath: path, source: sourceIdentity, snapshot: FileIdentity(verified),
                          lastUse: .now)
        store(entry, for: key)
        if cloneSnapshot(entry, to: destination) { return }
        // Cloning inside one temporary volume should not fail; if it does, fall back to a
        // per-job verified copy from the snapshot just made.
        discard(key, ifSnapshotAt: path)
        let snapshotInput = FFmpegWhisperJobInput(url: URL(fileURLWithPath: path),
                                                  byteCount: input.byteCount, sha256: input.sha256)
        _ = unlink(destination.path)
        let fallback = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fallback >= 0 else { throw FFmpegWhisperJobError.unsafeInput }
        defer { close(fallback) }
        var info = stat()
        guard fstat(fallback, &info) == 0 else { throw FFmpegWhisperJobError.unsafeInput }
        _ = try FFmpegWhisperJobRunner.snapshot(source: fallback, before: info, snapshotInput,
                                                to: destination, allowClone: false)
    }

    /// Deletes every snapshot and the session directory.
    func removeAll() {
        let (paths, directory) = state.withLock { (state: inout State) -> ([String], String?) in
            let paths = state.entries.values.map(\.snapshotPath)
            let directory = state.directory
            state.entries.removeAll()
            state.directory = nil
            return (paths, directory)
        }
        for path in paths { _ = unlink(path) }
        if let directory { try? FileManager.default.removeItem(atPath: directory) }
    }

    private func reusableEntry(for key: Key, source: FileIdentity) -> Entry? {
        let now = ContinuousClock.now
        let (entry, expired) = state.withLock { (state: inout State) -> (Entry?, [String]) in
            var expired: [String] = []
            for (otherKey, other) in state.entries where now - other.lastUse > idleLifetime {
                state.entries[otherKey] = nil
                expired.append(other.snapshotPath)
            }
            guard var entry = state.entries[key] else { return (nil, expired) }
            guard entry.source == source else {
                state.entries[key] = nil
                return (nil, expired + [entry.snapshotPath])
            }
            entry.lastUse = now
            state.entries[key] = entry
            return (entry, expired)
        }
        for path in expired { _ = unlink(path) }
        return entry
    }

    /// APFS-clones the verified snapshot to `destination`, proving with the snapshot's stat
    /// identity before and after the clone that the cloned bytes are the verified ones.
    private func cloneSnapshot(_ entry: Entry, to destination: URL) -> Bool {
        let descriptor = open(entry.snapshotPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, FileIdentity(before) == entry.snapshot,
              before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { return false }
        guard fclonefileat(descriptor, AT_FDCWD, destination.path, 0) == 0 else { return false }
        var after = stat()
        let clone = open(destination.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        var cloneInfo = stat()
        let verified = fstat(descriptor, &after) == 0 && FileIdentity(after) == entry.snapshot
            && clone >= 0 && fstat(clone, &cloneInfo) == 0
            && cloneInfo.st_mode & S_IFMT == S_IFREG && cloneInfo.st_size == entry.snapshot.size
            && cloneInfo.st_uid == entry.snapshot.owner && fchmod(clone, 0o400) == 0
        if clone >= 0 { close(clone) }
        guard verified else {
            _ = unlink(destination.path)
            return false
        }
        return true
    }

    private func store(_ entry: Entry, for key: Key) {
        let evicted = state.withLock { (state: inout State) -> [String] in
            var evicted: [String] = []
            if let previous = state.entries[key] { evicted.append(previous.snapshotPath) }
            state.entries[key] = entry
            while state.entries.count > capacity,
                  let oldest = state.entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                state.entries[oldest.key] = nil
                evicted.append(oldest.value.snapshotPath)
            }
            return evicted
        }
        for path in evicted where path != entry.snapshotPath { _ = unlink(path) }
    }

    private func discard(_ key: Key, ifSnapshotAt path: String) {
        let removed = state.withLock { (state: inout State) -> Bool in
            guard state.entries[key]?.snapshotPath == path else { return false }
            state.entries[key] = nil
            return true
        }
        if removed { _ = unlink(path) }
    }

    /// The session's private snapshot directory, recreated (and the cache reset) if it vanished
    /// or no longer has the expected owner and permissions.
    private func snapshotDirectory() throws -> String {
        if let existing = state.withLock({ $0.directory }) {
            var info = stat()
            if lstat(existing, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
               info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 {
                return existing
            }
            removeAll()
        }
        guard let root = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw FFmpegWhisperJobError.unsafeInput
        }
        let rootPath = String(cString: root)
        free(root)
        Self.sweepStaleDirectories(in: rootPath)
        var template = Array((rootPath + "/" + Self.directoryPrefix + "\(getpid())-XXXXXXXX").utf8CString)
        guard let result = mkdtemp(&template) else { throw FFmpegWhisperJobError.unsafeInput }
        let created = String(cString: result)
        let winner = state.withLock { (state: inout State) -> String in
            if let directory = state.directory { return directory }
            state.directory = created
            return created
        }
        if winner != created { _ = rmdir(created) }
        return winner
    }

    /// Removes snapshot directories left by app sessions that are no longer running.
    private static func sweepStaleDirectories(in root: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for name in names where name.hasPrefix(directoryPrefix) {
            let rest = name.dropFirst(directoryPrefix.count)
            guard let pidText = rest.split(separator: "-").first, let pid = pid_t(pidText),
                  pid != getpid(), kill(pid, 0) == -1, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(atPath: root + "/" + name)
        }
    }
}
