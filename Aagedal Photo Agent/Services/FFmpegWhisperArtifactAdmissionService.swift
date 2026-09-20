import CryptoKit
import Darwin
import Foundation
import Security

/// Session-only admission of exact files. Custom admission records identity, not trust;
/// bundled admission additionally requires independently supplied executable and model pins.
/// Callers retain access to the artifacts and obtain any required execution consent.
actor FFmpegWhisperArtifactAdmissionService {
    nonisolated static let maximumReceipts = 16
    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.whisper-artifact-admission", qos: .utility
    )
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    nonisolated enum AdmissionError: LocalizedError, Equatable, Sendable {
        case invalidArtifact, unsafePath, artifactChanged, configurationMismatch, revoked, capacityExceeded, pinMismatch

        var errorDescription: String? {
            switch self {
            case .invalidArtifact, .unsafePath:
                return "The Whisper files cannot be safely admitted. They must be readable regular files without symbolic links, with an executable FFmpeg build."
            case .artifactChanged, .configurationMismatch:
                return "The Whisper files no longer match their admitted identities. Enable transcription again in Settings."
            case .revoked:
                return "Whisper authorization was cleared. Enable transcription again in Settings."
            case .capacityExceeded:
                return "The Whisper session has reached its admission limit. Clear the active transcription configuration before trying again."
            case .pinMismatch:
                return "The bundled transcription files do not match their verified release identities. Download the model again or reinstall the app."
            }
        }
    }

    nonisolated struct Receipt: Sendable {
        fileprivate let id: UUID
        let executable: FFmpegWhisperJobInput
        let model: FFmpegWhisperJobInput
        let buildIdentifier: String
        let modelIdentifier: String

        func configuration(language: String = "auto", useGPU: Bool = false,
                           timeoutSeconds: Double = 300, translate: Bool = false) -> FFmpegWhisperTranscriptionProvider.Configuration {
            .init(executable: executable, buildIdentifier: buildIdentifier, model: model,
                  modelIdentifier: modelIdentifier, language: language, useGPU: useGPU,
                  timeoutSeconds: timeoutSeconds, translate: translate)
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

    private struct BundledRuntimeManifest: Decodable {
        let schemaVersion: Int
        let executableSHA256: String
        let executableByteCount: Int64
        let producerContract: String
    }

    /// The app's resource seal authenticates the manifest generated after helper signing.
    /// Read pins only from that sealed resource, never derive an expected pin from the helper.
    func admitBundled(modelURL: URL, model: WhisperDownloadableModel, bundle: Bundle = .main) throws -> Receipt {
        try Task.checkCancellation()
        guard let resources = bundle.resourceURL else { throw AdmissionError.pinMismatch }
        let executableURL = resources.appendingPathComponent("ffmpeg", isDirectory: false)
        let manifestURL = resources.appendingPathComponent("whisper-runtime.json", isDirectory: false)
        let manifestCapture = try Self.capture(manifestURL, executable: false, maximumBytes: 16 * 1024)
        let manifestData = try Self.readManifest(manifestURL)
        guard manifestData.count == manifestCapture.0.byteCount,
              SHA256.hash(data: manifestData).map({ String(format: "%02x", $0) }).joined() == manifestCapture.0.sha256,
              let manifest = try? JSONDecoder().decode(BundledRuntimeManifest.self, from: manifestData),
              manifest.schemaVersion == 1, manifest.producerContract == "photo-agent-whisper-json-v1",
              manifest.executableByteCount > 0 else { throw AdmissionError.pinMismatch }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode,
                SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate),
                nil) == errSecSuccess else { throw AdmissionError.pinMismatch }
        // Validate the same manifest identity after the signature check, so an intervening
        // resource replacement cannot substitute pins not covered by that successful check.
        let checkedManifest = try Self.capture(manifestURL, executable: false, maximumBytes: 16 * 1024)
        guard checkedManifest.0 == manifestCapture.0, checkedManifest.1 == manifestCapture.1 else {
            throw AdmissionError.artifactChanged
        }
        let receipt = try admitBundled(executableURL: executableURL, modelURL: modelURL,
            expectedExecutableSHA256: manifest.executableSHA256, expectedModelSHA256: model.sha256,
            expectedModelByteCount: model.byteCount, modelIdentifier: model.id)
        guard receipt.executable.byteCount == manifest.executableByteCount else {
            revoke(receipt)
            throw AdmissionError.pinMismatch
        }
        return receipt
    }

    /// Does not execute either file or infer permission from a matching hash.
    func admitCustom(executableURL: URL, modelURL: URL) throws -> Receipt {
        try Task.checkCancellation()
        guard entries.count < Self.maximumReceipts else { throw AdmissionError.capacityExceeded }
        let executable = try Self.capture(executableURL, executable: true)
        let model = try Self.capture(modelURL, executable: false)
        guard executable.1.device != model.1.device || executable.1.inode != model.1.inode else {
            throw AdmissionError.invalidArtifact
        }
        return record(executable: executable, model: model,
                      buildIdentifier: "custom-unverified-sha256:" + executable.0.sha256,
                      modelIdentifier: "custom-unverified-sha256:" + model.0.sha256)
    }

    /// Pins must come from the bundled release manifest and the curated model catalog, never
    /// from hashing the candidate files at runtime. The executable pin covers the final signed
    /// binary: signing changes its bytes, so a pre-signing source digest is insufficient.
    func admitBundled(executableURL: URL, modelURL: URL, expectedExecutableSHA256: String,
                      expectedModelSHA256: String, expectedModelByteCount: Int64,
                      modelIdentifier: String) throws -> Receipt {
        try Task.checkCancellation()
        guard entries.count < Self.maximumReceipts else { throw AdmissionError.capacityExceeded }
        func isDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
        guard isDigest(expectedExecutableSHA256), isDigest(expectedModelSHA256),
              expectedModelByteCount > 0, !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !modelIdentifier.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AdmissionError.pinMismatch
        }
        let executable = try Self.capture(executableURL, executable: true)
        let model = try Self.capture(modelURL, executable: false)
        guard executable.0.sha256 == expectedExecutableSHA256,
              model.0.sha256 == expectedModelSHA256, model.0.byteCount == expectedModelByteCount,
              executable.1.device != model.1.device || executable.1.inode != model.1.inode else {
            throw AdmissionError.pinMismatch
        }
        return record(executable: executable, model: model,
                      buildIdentifier: "bundled-sha256:" + expectedExecutableSHA256,
                      modelIdentifier: modelIdentifier)
    }

    private func record(executable: (FFmpegWhisperJobInput, Identity),
                        model: (FFmpegWhisperJobInput, Identity), buildIdentifier: String,
                        modelIdentifier: String) -> Receipt {
        let receipt = Receipt(id: UUID(), executable: executable.0, model: model.0,
                              buildIdentifier: buildIdentifier, modelIdentifier: modelIdentifier)
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

    private static func readManifest(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw AdmissionError.unsafePath }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 16 * 1024 else { throw AdmissionError.invalidArtifact }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024 + 1)
        while data.count <= 16 * 1024 {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count - data.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw AdmissionError.invalidArtifact }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= 16 * 1024 else { throw AdmissionError.invalidArtifact }
        return data
    }

    private static func capture(_ url: URL, executable: Bool, maximumBytes: Int64? = nil) throws -> (FFmpegWhisperJobInput, Identity) {
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
        let maximum: Int64 = maximumBytes ?? (executable ? 512 * 1024 * 1024 : Int64(4) * 1024 * 1024 * 1024)
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
