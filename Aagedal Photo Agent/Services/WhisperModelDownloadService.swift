import CryptoKit
import Darwin
import Foundation

/// Public GGML weights from whisper.cpp, pinned to an immutable repository revision.
nonisolated struct WhisperDownloadableModel: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let byteCount: Int64
    let sha256: String
    let url: URL

    static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    static let catalog: [Self] = [
        model("tiny", "Tiny", 77_691_713, "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
        model("base", "Base", 147_951_465, "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        model("small", "Small", 487_601_967, "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b")
    ]

    private static func model(_ id: String, _ title: String, _ bytes: Int64, _ hash: String) -> Self {
        Self(id: id, title: title, byteCount: bytes, sha256: hash,
             url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)/ggml-\(id).bin")!)
    }
}

actor WhisperModelDownloadService {
    typealias Progress = @Sendable (Double) -> Void
    typealias Fetch = @Sendable (WhisperDownloadableModel, URL, @escaping Progress) async throws -> Void

    enum DownloadError: Error, LocalizedError, Equatable {
        case invalidModel, unsafeStorage, storageChanged, invalidResponse, sizeMismatch, checksumMismatch, busy
        var errorDescription: String? {
            switch self {
            case .invalidModel: "The selected Whisper model is invalid."
            case .unsafeStorage: "The Whisper model storage location is not a private regular file or directory."
            case .storageChanged: "The model storage changed during download. Please try again."
            case .invalidResponse: "The model server returned an invalid response. Please try again."
            case .sizeMismatch: "The downloaded model has an unexpected size. Please try again."
            case .checksumMismatch: "The downloaded model failed checksum verification. Please try again."
            case .busy: "A model download is already in progress."
            }
        }
    }

    private let directory: URL
    private let fetch: Fetch?
    // Internal checkpoint allows deterministic filesystem-race regression coverage.
    private let verificationCheckpoint: @Sendable () throws -> Void
    private var downloading = false

    init(directory: URL? = nil, fetch: Fetch? = nil,
         verificationCheckpoint: @escaping @Sendable () throws -> Void = {}) {
        self.verificationCheckpoint = verificationCheckpoint
        self.directory = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aagedal Photo Agent/WhisperModels", isDirectory: true)).standardizedFileURL
        self.fetch = fetch
    }

    func installedURL(for model: WhisperDownloadableModel) throws -> URL? {
        let target = try targetURL(model)
        try Task.checkCancellation()
        // Validate ancestors even when no model exists: a missing leaf does not make
        // a redirected cache safe. Bind hashing to the admitted directory descriptor.
        try validateAncestors(allowMissing: true)
        guard let admittedDirectory = try identity(at: directory) else { return nil }
        try validateStorage(create: false)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DownloadError.unsafeStorage }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).sameFile(as: admittedDirectory) else { throw DownloadError.storageChanged }
        let admittedTarget = try identity(at: target, directoryDescriptor: descriptor)
        guard let admittedTarget else {
            guard try identity(at: directory)?.sameFile(as: admittedDirectory) == true else {
                throw DownloadError.storageChanged
            }
            try validateStorage(create: false)
            try Task.checkCancellation()
            return nil
        }
        let verified = try verify(target, model: model, directoryDescriptor: descriptor)
        guard verified == admittedTarget,
              try identity(at: directory)?.sameFile(as: admittedDirectory) == true else {
            throw DownloadError.storageChanged
        }
        try validateStorage(create: false)
        try Task.checkCancellation()
        return target
    }

    func download(_ model: WhisperDownloadableModel, progress: @escaping Progress = { _ in }) async throws -> URL {
        guard !downloading else { throw DownloadError.busy }
        let target = try targetURL(model)
        try Task.checkCancellation()
        try validateStorage(create: true)
        let admittedDirectory = try identity(at: directory)
        let admittedTarget = try identity(at: target)
        do {
            if let installed = try installedURL(for: model) { return installed }
        } catch DownloadError.sizeMismatch {
            // A corrupt regular model may be replaced, but unsafe storage must be refused.
        } catch DownloadError.checksumMismatch {
        }
        guard try identity(at: directory)?.sameFile(as: admittedDirectory) == true,
              try identity(at: target) == admittedTarget else { throw DownloadError.storageChanged }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { throw DownloadError.unsafeStorage }
        defer { close(directoryDescriptor) }
        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0,
              FileIdentity(directoryInfo).sameFile(as: admittedDirectory) else { throw DownloadError.storageChanged }
        downloading = true
        defer { downloading = false }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        // Cleanup stays bound to the admitted directory even if its pathname moves.
        defer { _ = unlinkat(directoryDescriptor, temporary.lastPathComponent, 0) }
        progress(0)
        if let fetch {
            try await fetch(model, temporary, progress)
        } else {
            try await WhisperModelTransfer(model: model, destination: temporary,
                directoryDescriptor: directoryDescriptor, progress: progress).run()
        }
        try Task.checkCancellation()
        try validateStorage(create: false)
        guard try identity(at: directory)?.sameFile(as: admittedDirectory) == true else {
            throw DownloadError.storageChanged
        }
        let verifiedPartial = try verify(temporary, model: model, directoryDescriptor: directoryDescriptor, makePrivate: true)
        // Hashing can be lengthy; an ancestor may have become a symlink while the
        // directory and leaf still resolve to the same inodes through that link.
        try validateStorage(create: false)
        guard try identity(at: directory)?.sameFile(as: admittedDirectory) == true,
              try identity(at: target) == admittedTarget else { throw DownloadError.storageChanged }
        try Task.checkCancellation()
        var partialInfo = stat()
        guard fstatat(directoryDescriptor, temporary.lastPathComponent, &partialInfo, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(partialInfo) == verifiedPartial else { throw DownloadError.storageChanged }
        // POSIX rename publishes the verified sibling atomically, preserving an old model on failure.
        let publication = admittedTarget == nil
            ? renameatx_np(directoryDescriptor, temporary.lastPathComponent, directoryDescriptor, target.lastPathComponent, UInt32(RENAME_EXCL))
            : renameat(directoryDescriptor, temporary.lastPathComponent, directoryDescriptor, target.lastPathComponent)
        guard publication == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        progress(1)
        return target
    }

    func remove(_ model: WhisperDownloadableModel) throws {
        guard !downloading else { throw DownloadError.busy }
        let target = try targetURL(model)
        try Task.checkCancellation()
        // An absent cache is already removed, including first-use and external cleanup.
        // Still reject linked ancestors before treating an absent leaf as success.
        try validateAncestors(allowMissing: true)
        guard let admittedDirectory = try identity(at: directory) else { return }
        try validateStorage(create: false)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DownloadError.unsafeStorage }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).sameFile(as: admittedDirectory) else { throw DownloadError.storageChanged }
        try validateStorage(create: false)
        guard try identity(at: directory)?.sameFile(as: admittedDirectory) == true else {
            throw DownloadError.storageChanged
        }
        try Task.checkCancellation()
        // Stay bound to the admitted directory if its path subsequently moves.
        // Removing the leaf never follows a link or recursively removes a directory.
        if unlinkat(descriptor, target.lastPathComponent, 0) != 0 && errno != ENOENT {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func targetURL(_ model: WhisperDownloadableModel) throws -> URL {
        guard !model.id.isEmpty, model.id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              model.byteCount > 0, model.byteCount <= 4_000_000_000,
              model.sha256.count == 64, model.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              model.url.scheme == "https" else { throw DownloadError.invalidModel }
        return directory.appendingPathComponent("ggml-\(model.id).bin")
    }

    private func validateStorage(create: Bool) throws {
        let manager = FileManager.default
        // Refuse linked existing ancestors before creating anything beneath them.
        try validateAncestors(allowMissing: create)
        if create { try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw DownloadError.unsafeStorage }
        try validateAncestors(allowMissing: false)
    }

    private func validateAncestors(allowMissing: Bool) throws {
        var info = stat()
        // Standard system aliases (/var and /tmp) are resolved by Foundation; reject additional links.
        var ancestor = directory
        while ancestor.path != "/" {
            if lstat(ancestor.path, &info) != 0 {
                guard allowMissing && errno == ENOENT else { throw DownloadError.unsafeStorage }
                ancestor.deleteLastPathComponent()
                continue
            }
            if (info.st_mode & S_IFMT) == S_IFLNK && ancestor.path != "/var" && ancestor.path != "/tmp" {
                throw DownloadError.unsafeStorage
            }
            ancestor.deleteLastPathComponent()
        }
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }

        func sameFile(as other: Self?) -> Bool {
            other?.device == device && other?.inode == inode
        }
    }

    private func identity(at url: URL, directoryDescriptor: Int32? = nil) throws -> FileIdentity? {
        var info = stat()
        let status = directoryDescriptor.map { fstatat($0, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) }
            ?? lstat(url.path, &info)
        guard status == 0 else {
            if errno == ENOENT { return nil }
            throw DownloadError.unsafeStorage
        }
        return FileIdentity(info)
    }

    private func verify(_ url: URL, model: WhisperDownloadableModel, directoryDescriptor: Int32, makePrivate: Bool = false) throws -> FileIdentity {
        let descriptor = openat(directoryDescriptor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw DownloadError.unsafeStorage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid() else { throw DownloadError.unsafeStorage }
        guard makePrivate || info.st_mode & 0o022 == 0 else { throw DownloadError.unsafeStorage }
        guard info.st_size == model.byteCount else { throw DownloadError.sizeMismatch }
        try verificationCheckpoint()
        var hash = SHA256()
        var count: Int64 = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            count += Int64(bytes.count)
            guard count <= model.byteCount else { throw DownloadError.sizeMismatch }
            hash.update(data: bytes)
        }
        guard count == model.byteCount else { throw DownloadError.sizeMismatch }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == model.sha256 else { throw DownloadError.checksumMismatch }
        var current = stat()
        let status = fstatat(directoryDescriptor, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW)
        guard status == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino,
              current.st_size == info.st_size, current.st_nlink == 1,
              current.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { throw DownloadError.storageChanged }
        if makePrivate, fchmod(descriptor, 0o600) != 0 { throw DownloadError.unsafeStorage }
        guard fstat(descriptor, &current) == 0 else { throw DownloadError.unsafeStorage }
        return FileIdentity(current)
    }
}

/// URLSession streams to disk. The delegate caps actual bytes even when Content-Length is absent.
nonisolated private final class WhisperModelTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let model: WhisperDownloadableModel
    private let destination: URL
    private let directoryDescriptor: Int32
    private let progress: WhisperModelDownloadService.Progress
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    init(model: WhisperDownloadableModel, destination: URL, directoryDescriptor: Int32,
         progress: @escaping WhisperModelDownloadService.Progress) {
        self.model = model; self.destination = destination; self.progress = progress
        self.directoryDescriptor = directoryDescriptor
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 3_600
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: model.url)
                lock.lock()
                self.continuation = continuation
                self.task = task
                let cancel = cancelled
                lock.unlock()
                task.resume()
                if cancel { task.cancel() }
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else {
            failure = WhisperModelDownloadService.DownloadError.invalidResponse
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= model.byteCount,
              totalBytesExpectedToWrite <= 0 || totalBytesExpectedToWrite == model.byteCount else {
            failure = WhisperModelDownloadService.DownloadError.sizeMismatch
            downloadTask.cancel()
            return
        }
        progress(min(0.99, Double(totalBytesWritten) / Double(model.byteCount)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https" else {
            failure = WhisperModelDownloadService.DownloadError.invalidResponse
            return
        }
        do {
            try WhisperDownloadedFileStaging.copy(location, to: destination.lastPathComponent,
                in: directoryDescriptor, byteCount: model.byteCount, checkCancellation: {
                    self.lock.lock()
                    let cancelled = self.cancelled
                    self.lock.unlock()
                    if cancelled { throw CancellationError() }
                })
        } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        let wasCancelled = cancelled
        lock.unlock()
        session.finishTasksAndInvalidate()
        if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else if let error = failure ?? error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}

/// The URLSession temporary file is copied only into the already admitted cache directory.
/// A path replacement during the network request cannot redirect this staging write.
nonisolated enum WhisperDownloadedFileStaging {
    static func copy(_ source: URL, to name: String, in directoryDescriptor: Int32,
                     byteCount: Int64, checkCancellation: () throws -> Void = {}) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw WhisperModelDownloadService.DownloadError.unsafeStorage
        }
        try checkCancellation()
        let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard sourceDescriptor >= 0 else { throw WhisperModelDownloadService.DownloadError.unsafeStorage }
        let input = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(sourceDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw WhisperModelDownloadService.DownloadError.unsafeStorage
        }
        guard info.st_size == byteCount else { throw WhisperModelDownloadService.DownloadError.sizeMismatch }
        let outputDescriptor = openat(directoryDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputDescriptor >= 0 else { throw WhisperModelDownloadService.DownloadError.unsafeStorage }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        var completed = false
        defer {
            try? output.close()
            if !completed { _ = unlinkat(directoryDescriptor, name, 0) }
        }
        var count: Int64 = 0
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try checkCancellation()
            count += Int64(bytes.count)
            guard count <= byteCount else { throw WhisperModelDownloadService.DownloadError.sizeMismatch }
            try output.write(contentsOf: bytes)
        }
        try checkCancellation()
        guard count == byteCount else { throw WhisperModelDownloadService.DownloadError.sizeMismatch }
        try output.close()
        completed = true
    }
}
