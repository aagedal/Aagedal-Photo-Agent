import CryptoKit
import Darwin
import Foundation

/// Session-only admission of explicitly selected custom files. This records identity, not trust,
/// compatibility, code signing, licensing, or the presence of the patched Whisper JSON producer.
/// UI must obtain explicit execution consent and retain security-scoped access before using it.
actor FFmpegWhisperArtifactAdmissionService {
    nonisolated static let maximumReceipts = 16
    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.whisper-artifact-admission", qos: .utility
    )
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    nonisolated enum AdmissionError: Error, Equatable, Sendable {
        case invalidArtifact, unsafePath, artifactChanged, configurationMismatch, revoked, capacityExceeded
    }

    nonisolated struct Receipt: Sendable {
        fileprivate let id: UUID
        let executable: FFmpegWhisperJobInput
        let model: FFmpegWhisperJobInput
        var buildIdentifier: String { "custom-unverified-sha256:" + executable.sha256 }
        var modelIdentifier: String { "custom-unverified-sha256:" + model.sha256 }

        func configuration(language: String = "auto", useGPU: Bool = false,
                           timeoutSeconds: Double = 300) -> FFmpegWhisperTranscriptionProvider.Configuration {
            .init(executable: executable, buildIdentifier: buildIdentifier, model: model,
                  modelIdentifier: modelIdentifier, language: language, useGPU: useGPU,
                  timeoutSeconds: timeoutSeconds)
        }
    }

    private struct Identity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let mode: UInt16
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size; mode = info.st_mode
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }
    private struct Entry: Sendable {
        let receipt: Receipt
        let executableIdentity: Identity
        let modelIdentity: Identity
    }
    private var entries: [UUID: Entry] = [:]

    /// Does not execute either file or infer permission from a matching hash.
    func admitCustom(executableURL: URL, modelURL: URL) throws -> Receipt {
        try Task.checkCancellation()
        guard entries.count < Self.maximumReceipts else { throw AdmissionError.capacityExceeded }
        let executable = try Self.capture(executableURL, executable: true)
        let model = try Self.capture(modelURL, executable: false)
        guard executable.1.device != model.1.device || executable.1.inode != model.1.inode else {
            throw AdmissionError.invalidArtifact
        }
        let receipt = Receipt(id: UUID(), executable: executable.0, model: model.0)
        entries[receipt.id] = Entry(receipt: receipt, executableIdentity: executable.1,
                                    modelIdentity: model.1)
        return receipt
    }

    func revoke(_ receipt: Receipt) { entries.removeValue(forKey: receipt.id) }

    /// Checks both the pinned files and the provider metadata; the runner still snapshots and
    /// verifies exact bytes immediately before launch, closing the path-to-process substitution gap.
    func revalidate(_ receipt: Receipt,
                    configuration: FFmpegWhisperTranscriptionProvider.Configuration) throws {
        try Task.checkCancellation()
        guard let entry = entries[receipt.id] else { throw AdmissionError.revoked }
        guard configuration.executable == entry.receipt.executable,
              configuration.model == entry.receipt.model,
              configuration.buildIdentifier == entry.receipt.buildIdentifier,
              configuration.modelIdentifier == entry.receipt.modelIdentifier else {
            throw AdmissionError.configurationMismatch
        }
        let executable = try Self.capture(entry.receipt.executable.url, executable: true)
        let model = try Self.capture(entry.receipt.model.url, executable: false)
        guard executable.0 == entry.receipt.executable, model.0 == entry.receipt.model,
              executable.1 == entry.executableIdentity, model.1 == entry.modelIdentity else {
            throw AdmissionError.artifactChanged
        }
    }

    nonisolated func authorizer(for receipt: Receipt) -> FFmpegWhisperTranscriptionProvider.AuthorizeArtifacts {
        { configuration in try await self.revalidate(receipt, configuration: configuration) }
    }

    private static func capture(_ url: URL, executable: Bool) throws -> (FFmpegWhisperJobInput, Identity) {
        try Task.checkCancellation()
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw AdmissionError.unsafePath }
        let parts = url.path.split(separator: "/")
        guard !parts.isEmpty, !parts.contains("."), !parts.contains("..") else {
            throw AdmissionError.unsafePath
        }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw AdmissionError.unsafePath }
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw AdmissionError.unsafePath }
            close(directory); directory = next
        }
        let descriptor = openat(directory, String(parts.last!), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw AdmissionError.unsafePath }
        defer { close(descriptor) }
        var before = stat()
        let maximum: Int64 = executable ? 512 * 1024 * 1024 : Int64(4) * 1024 * 1024 * 1024
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size > 0, before.st_size <= maximum,
              !executable || before.st_mode & 0o111 != 0,
              before.st_mode & (S_ISUID | S_ISGID) == 0 else { throw AdmissionError.invalidArtifact }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, Int(before.st_size - total + 1)))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw AdmissionError.invalidArtifact }
            if count == 0 { break }
            total += Int64(count)
            guard total <= before.st_size else { throw AdmissionError.artifactChanged }
            hash.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &after) == 0, total == before.st_size,
              Identity(before) == Identity(after), after.st_nlink == 1,
              fstatat(directory, String(parts.last!), &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(after) == Identity(pathInfo) else { throw AdmissionError.artifactChanged }
        return (.init(url: url, byteCount: total,
                      sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()), Identity(after))
    }
}
