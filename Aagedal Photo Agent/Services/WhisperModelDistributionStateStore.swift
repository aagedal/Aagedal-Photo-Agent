import Darwin
import Foundation

/// Durable release authorization, NOT proof that model bytes have been installed.
/// All instances in this process serialize read/compare/replace through storage admission.
/// This is NOT cross-process compare-and-swap: another process can race a transition.
/// A multi-process installer must add a shared filesystem lock before using this ledger.
/// The caller supplies a private app-owned directory. External deletion/restoration of the
/// entire ledger is outside this local replay protection; there is deliberately no backup
/// fallback that could silently lower the accepted release floor.
actor WhisperModelDistributionStateStore {
    enum StoreError: Error, Equatable {
        case staleGeneration, invalidState, unsafeStorage
    }

    struct Snapshot: Sendable {
        let generation: UUID
        let release: WhisperModelReleaseState
    }

    private struct Document: Codable {
        let schemaVersion: Int
        let generation: UUID
        let modelID: String
        let record: WhisperModelReleaseRecord
    }

    private let directory: URL
    private let directoryDevice: dev_t
    private let directoryInode: ino_t
    private let modelID: String
    private let trust: WhisperModelDistributionTrust
    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.whisper-release-state", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }

    init(directory: URL, modelID: String, trust: WhisperModelDistributionTrust) throws {
        guard !modelID.isEmpty, modelID.utf8.count <= 64,
              modelID.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw StoreError.invalidState
        }
        // Preserve the caller's POSIX spelling. Foundation standardizedFileURL can
        // rewrite /private/var to its /var symlink, defeating the no-follow walk below.
        let path = directory.path
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard directory.isFileURL, path.hasPrefix("/"), !path.contains("\0"),
              !components.contains("."), !components.contains(".."),
              !components.dropFirst().dropLast().contains("") else { throw StoreError.unsafeStorage }
        let fd = try Self.openVerifiedDirectory(directory)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw StoreError.unsafeStorage }
        self.directory = directory
        self.directoryDevice = info.st_dev
        self.directoryInode = info.st_ino
        self.modelID = modelID
        self.trust = trust
    }

    func load() async throws -> Snapshot? {
        try await StorageTransactionAdmission.shared.withAccess(to: [admissionURL]) {
            try await self.readSnapshot()
        }
    }

    /// nil generation means first acceptance, never reset an existing ledger.
    func accept(_ receipt: WhisperModelDescriptorReceipt, expectedGeneration: UUID?) async throws -> Snapshot {
        try await StorageTransactionAdmission.shared.withAccess(to: [admissionURL]) {
            try await self.transition(receipt: receipt, expectedGeneration: expectedGeneration)
        }
    }

    /// Requires explicit rollback intent from its eventual installer caller.
    func rollBack(expectedGeneration: UUID) async throws -> Snapshot {
        try await StorageTransactionAdmission.shared.withAccess(to: [admissionURL]) {
            try await self.transition(receipt: nil, expectedGeneration: expectedGeneration)
        }
    }

    private var filename: String { "\(modelID).release-state.json" }
    private var admissionURL: URL {
        directory.appendingPathComponent(filename)
    }

    /// Walk every component relative to retained descriptors. O_NOFOLLOW on a single
    /// absolute open protects only the leaf and would still traverse parent symlinks.
    private static func openVerifiedDirectory(_ directory: URL) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.unsafeStorage }
        do {
            for component in directory.path.split(separator: "/") {
                let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw StoreError.unsafeStorage }
                close(fd)
                fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
                throw StoreError.unsafeStorage
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private func openDirectory() throws -> Int32 {
        let fd = try Self.openVerifiedDirectory(directory)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == directoryDevice, info.st_ino == directoryInode else {
            close(fd)
            throw StoreError.unsafeStorage
        }
        return fd
    }

    private func readSnapshot() throws -> Snapshot? {
        let fd = try openDirectory()
        defer { close(fd) }
        guard let (document, state, _) = try read(directoryFD: fd) else { return nil }
        return Snapshot(generation: document.generation, release: state)
    }

    private func read(directoryFD: Int32) throws -> (Document, WhisperModelReleaseState, WhisperModelDescriptorReceipt)? {
        let fd = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw StoreError.unsafeStorage
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 100_000 else { throw StoreError.unsafeStorage }
        let data = try handle.read(upToCount: 100_001) ?? Data()
        guard data.count == info.st_size,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == 1, document.modelID == modelID else { throw StoreError.invalidState }
        let (state, highWater) = try document.record.authenticated(using: trust)
        guard state.current.descriptor.modelID == modelID else { throw StoreError.invalidState }
        return (document, state, highWater)
    }

    private func transition(receipt: WhisperModelDescriptorReceipt?, expectedGeneration: UUID?) throws -> Snapshot {
        let fd = try openDirectory()
        defer { close(fd) }
        let existing = try read(directoryFD: fd)
        guard existing?.0.generation == expectedGeneration else { throw StoreError.staleGeneration }
        let next: WhisperModelReleaseState
        let highWater: WhisperModelDescriptorReceipt
        if let receipt {
            guard receipt.descriptor.modelID == modelID else { throw WhisperModelDistributionTrust.TrustError.wrongModel }
            next = try existing.map { try trust.updating($0.1, to: receipt) } ?? trust.initialState(receipt)
            highWater = receipt
        } else {
            guard let existing else { throw StoreError.staleGeneration }
            next = try trust.rollingBack(existing.1)
            highWater = existing.2
        }
        let document = Document(schemaVersion: 1, generation: UUID(), modelID: modelID,
                                record: WhisperModelReleaseRecord(state: next, highWater: highWater))
        let data = try JSONEncoder().encode(document)
        let temporary = ".\(filename).\(UUID().uuidString).staging"
        let stagedFD = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard stagedFD >= 0 else { throw StoreError.unsafeStorage }
        let handle = FileHandle(fileDescriptor: stagedFD, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlinkat(fd, temporary, 0)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard renameat(fd, temporary, fd, filename) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard fsync(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Snapshot(generation: document.generation, release: next)
    }
}
