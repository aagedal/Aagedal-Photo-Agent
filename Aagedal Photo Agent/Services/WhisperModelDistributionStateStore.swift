import CryptoKit
import Darwin
import Foundation

@_silgen_name("flock")
nonisolated private func whisperReleaseFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Durable release authorization, NOT proof that model bytes have been installed.
/// Cooperating processes hold an exclusive lock on the verified directory throughout
/// read/compare/replace. Contention fails promptly, and callers must reload before retrying.
/// The directory lock covers every model ledger in that directory and is never unlinked.
/// The caller supplies a private app-owned directory. External deletion/restoration of the
/// entire ledger is outside this local replay protection; there is deliberately no backup
/// fallback that could silently lower the accepted release floor.
actor WhisperModelDistributionStateStore {
    enum StoreError: Error, Equatable {
        case staleGeneration, invalidState, unsafeStorage, storageBusy, invalidModelBytes, cleanupLimitExceeded
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
    private let installationCheckpoint: @Sendable () throws -> Void
    private let publicationCheckpoint: @Sendable () throws -> Void
    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.whisper-release-state", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }

    init(directory: URL, modelID: String, trust: WhisperModelDistributionTrust,
         installationCheckpoint: @escaping @Sendable () throws -> Void = {},
         publicationCheckpoint: @escaping @Sendable () throws -> Void = {}) throws {
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
        self.installationCheckpoint = installationCheckpoint
        self.publicationCheckpoint = publicationCheckpoint
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

    /// Copies caller-staged bytes into a content-addressed sibling and commits release
    /// authority last. An interrupted commit can leave an unreferenced model, but never
    /// an accepted release whose bytes were not verified and synchronized first.
    func install(_ receipt: WhisperModelDescriptorReceipt, from source: URL,
                 expectedGeneration: UUID?) async throws -> Snapshot {
        try await StorageTransactionAdmission.shared.withAccess(to: [admissionURL]) {
            try await self.installBytes(receipt, from: source, expectedGeneration: expectedGeneration)
        }
    }

    func rollBackInstalled(expectedGeneration: UUID) async throws -> Snapshot {
        try await StorageTransactionAdmission.shared.withAccess(to: [admissionURL]) {
            try await self.transition(receipt: nil, expectedGeneration: expectedGeneration, requireInstalled: true)
        }
    }

    /// Rechecks bytes on every lookup; a ledger alone never establishes installation.
    /// The returned path is not a retained read capability. Consumers must still use
    /// the transcription runner's artifact admission when opening it later.
    func installedURL() async throws -> URL? {
        try await StorageTransactionAdmission.shared.withAccess(to: [admissionURL]) {
            try await self.readInstalledURL()
        }
    }

    /// Explicit maintenance after relaunch. Authenticated authority is required before
    /// deleting anything; absent/corrupt ledgers must be recovered separately. All
    /// candidates are checked before mutation, and retries tolerate a partial sweep.
    /// Old unscoped staging names are intentionally outside this model's ownership.
    func cleanUpInterruptedInstallation(expectedGeneration: UUID) async throws -> Int {
        try await StorageTransactionAdmission.shared.withAccess(to: [admissionURL]) {
            try await self.cleanUpOrphans(expectedGeneration: expectedGeneration)
        }
    }

    /// Legacy staging names carry no model identity. Explicitly remove one only when
    /// its complete bytes match authenticated retained authority and another verified,
    /// durable copy exists. Partial/unknown legacy files require separate recovery.
    func cleanUpLegacyStaging(named name: String, expectedGeneration: UUID) async throws {
        try await StorageTransactionAdmission.shared.withAccess(to: [admissionURL]) {
            try await self.removeLegacyStaging(named: name, expectedGeneration: expectedGeneration)
        }
    }

    /// Restore only missing current content using the already authenticated ledger.
    /// This is not release acceptance: generation, rollback and replay floor stay intact.
    /// Existing corrupt or unsafe content is refused rather than overwritten.
    func restoreMissingCurrentModel(from source: URL, expectedGeneration: UUID) async throws -> URL {
        try await StorageTransactionAdmission.shared.withAccess(to: [admissionURL]) {
            try await self.restoreMissingBytes(from: source, expectedGeneration: expectedGeneration, rollback: false)
        }
    }

    /// Repairs the retained rollback candidate without selecting it or consuming rollback.
    /// The caller must still explicitly request rollBackInstalled after restoration.
    func restoreMissingRollbackModel(from source: URL, expectedGeneration: UUID) async throws -> URL {
        try await StorageTransactionAdmission.shared.withAccess(to: [admissionURL]) {
            try await self.restoreMissingBytes(from: source, expectedGeneration: expectedGeneration, rollback: true)
        }
    }

    private func restoreMissingBytes(from source: URL, expectedGeneration: UUID, rollback: Bool) throws -> URL {
        let fd = try openTransaction()
        defer { closeTransaction(fd) }
        guard let (document, state, _) = try read(directoryFD: fd),
              document.generation == expectedGeneration else { throw StoreError.staleGeneration }
        let receipt: WhisperModelDescriptorReceipt
        if rollback {
            guard let candidate = state.rollbackCandidate else {
                throw WhisperModelDistributionTrust.TrustError.unavailableRollback
            }
            receipt = candidate
        } else {
            receipt = state.current
        }
        let name = modelFilename(receipt)
        var existing = stat()
        if fstatat(fd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            try verifyModel(receipt, directoryFD: fd)
            try validateDirectoryIdentity()
            return directory.appendingPathComponent(name)
        }
        guard errno == ENOENT, source.isFileURL, !source.path.contains("\0") else {
            throw StoreError.unsafeStorage
        }
        let temporary = ".\(modelID).\(UUID().uuidString).model-staging"
        try WhisperDownloadedFileStaging.copy(source, to: temporary, in: fd,
            byteCount: receipt.descriptor.byteCount, checkCancellation: { try Task.checkCancellation() })
        // copy owns cleanup on failure; only remove a name we successfully created.
        defer { _ = unlinkat(fd, temporary, 0) }
        try installationCheckpoint()
        try verifyModel(receipt, directoryFD: fd, filename: temporary)
        try validateDirectoryIdentity()
        try Task.checkCancellation()
        // Never replace a file that appeared while the staged copy was being checked.
        guard renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL)) == 0,
              fsync(fd) == 0 else { throw StoreError.unsafeStorage }
        try publicationCheckpoint()
        try verifyModel(receipt, directoryFD: fd)
        try validateDirectoryIdentity()
        return directory.appendingPathComponent(name)
    }

    private func removeLegacyStaging(named name: String, expectedGeneration: UUID) throws {
        let suffix = ".model-staging"
        guard name.hasPrefix("."), name.hasSuffix(suffix) else { throw StoreError.unsafeStorage }
        let identifier = String(name.dropFirst().dropLast(suffix.count))
        guard UUID(uuidString: identifier)?.uuidString == identifier else { throw StoreError.unsafeStorage }
        let fd = try openTransaction()
        defer { closeTransaction(fd) }
        guard let (document, state, highWater) = try read(directoryFD: fd),
              document.generation == expectedGeneration else { throw StoreError.staleGeneration }
        var original = stat()
        guard fstatat(fd, name, &original, AT_SYMLINK_NOFOLLOW) == 0,
              original.st_mode & S_IFMT == S_IFREG, original.st_uid == geteuid(),
              original.st_nlink == 1, original.st_mode & 0o077 == 0 else { throw StoreError.unsafeStorage }
        let receipts = [state.current, state.rollbackCandidate, highWater].compactMap { $0 }
        var matched = false
        for receipt in receipts where receipt.descriptor.byteCount == original.st_size {
            do {
                try verifyModel(receipt, directoryFD: fd, filename: name)
            } catch StoreError.invalidModelBytes {
                continue
            }
            // Never delete the only surviving copy, even with a valid release ledger.
            try verifyModel(receipt, directoryFD: fd)
            matched = true
            break
        }
        guard matched else { throw StoreError.invalidModelBytes }
        try Task.checkCancellation()
        try validateDirectoryIdentity()
        var named = stat()
        guard fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == original.st_dev, named.st_ino == original.st_ino,
              named.st_mode == original.st_mode, named.st_uid == original.st_uid,
              named.st_nlink == 1, named.st_size == original.st_size,
              named.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              named.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else {
            throw StoreError.unsafeStorage
        }
        guard unlinkat(fd, name, 0) == 0, fsync(fd) == 0 else { throw StoreError.unsafeStorage }
        try validateDirectoryIdentity()
    }

    private func cleanUpOrphans(expectedGeneration: UUID) throws -> Int {
        let fd = try openTransaction()
        defer { closeTransaction(fd) }
        guard let (document, state, highWater) = try read(directoryFD: fd),
              document.generation == expectedGeneration else { throw StoreError.staleGeneration }
        // Keep signed high-water bytes too: rollback consumes its candidate without
        // lowering replay protection, and maintenance must not silently erase it.
        var retained = Set([modelFilename(state.current), modelFilename(highWater)])
        if let rollback = state.rollbackCandidate { retained.insert(modelFilename(rollback)) }
        let scanFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard scanFD >= 0 else { throw StoreError.unsafeStorage }
        guard let stream = fdopendir(scanFD) else {
            close(scanFD)
            throw StoreError.unsafeStorage
        }
        defer { closedir(stream) }
        var candidates: [(String, stat)] = []
        var scanned = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw StoreError.unsafeStorage }
                break
            }
            scanned += 1
            guard scanned <= 4_096 else { throw StoreError.cleanupLimitExceeded }
            let nameCapacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                    String(cString: $0)
                }
            }
            guard !retained.contains(name), isCleanupCandidate(name) else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
                  info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw StoreError.unsafeStorage }
            candidates.append((name, info))
            guard candidates.count <= 64 else { throw StoreError.cleanupLimitExceeded }
        }
        try validateDirectoryIdentity()
        for (name, original) in candidates {
            try Task.checkCancellation()
            var named = stat()
            guard fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_dev == original.st_dev, named.st_ino == original.st_ino,
                  named.st_mode == original.st_mode, named.st_nlink == 1,
                  named.st_uid == original.st_uid,
                  named.st_size == original.st_size,
                  named.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
                  named.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else {
                throw StoreError.unsafeStorage
            }
            guard unlinkat(fd, name, 0) == 0 else { throw StoreError.unsafeStorage }
        }
        guard fsync(fd) == 0 else { throw StoreError.unsafeStorage }
        try validateDirectoryIdentity()
        return candidates.count
    }

    private func isCleanupCandidate(_ name: String) -> Bool {
        let contentPrefix = "ggml-\(modelID)-"
        if name.hasPrefix(contentPrefix), name.hasSuffix(".bin") {
            let digest = name.dropFirst(contentPrefix.count).dropLast(4)
            return digest.utf8.count == 64 && digest.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
        for (prefix, suffix) in [(".\(modelID).", ".model-staging"), (".\(filename).", ".staging")] {
            if name.hasPrefix(prefix), name.hasSuffix(suffix) {
                let identifier = String(name.dropFirst(prefix.count).dropLast(suffix.count))
                return UUID(uuidString: identifier)?.uuidString == identifier
            }
        }
        return false
    }

    private func modelFilename(_ receipt: WhisperModelDescriptorReceipt) -> String {
        "ggml-\(modelID)-\(receipt.descriptor.sha256).bin"
    }

    private func readInstalledURL() throws -> URL? {
        let fd = try openTransaction()
        defer { closeTransaction(fd) }
        guard let (_, state, _) = try read(directoryFD: fd) else { return nil }
        try verifyModel(state.current, directoryFD: fd)
        try validateDirectoryIdentity()
        return directory.appendingPathComponent(modelFilename(state.current))
    }

    private func verifyModel(_ receipt: WhisperModelDescriptorReceipt, directoryFD: Int32, filename: String? = nil) throws {
        let name = filename ?? modelFilename(receipt)
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.unsafeStorage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o077 == 0 else { throw StoreError.unsafeStorage }
        guard before.st_size == receipt.descriptor.byteCount else { throw StoreError.invalidModelBytes }
        var hash = SHA256()
        var count: Int64 = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            count += Int64(bytes.count)
            guard count <= receipt.descriptor.byteCount else { throw StoreError.invalidModelBytes }
            hash.update(data: bytes)
        }
        guard count == receipt.descriptor.byteCount,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == receipt.descriptor.sha256 else {
            throw StoreError.invalidModelBytes
        }
        var after = stat()
        var named = stat()
        guard fstat(fd, &after) == 0, fstatat(directoryFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, after.st_nlink == 1,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              named.st_dev == after.st_dev, named.st_ino == after.st_ino else { throw StoreError.unsafeStorage }
        // The content file must be durable before its ledger can be made durable.
        guard fsync(fd) == 0 else { throw StoreError.unsafeStorage }
        try Task.checkCancellation()
    }

    private func installBytes(_ receipt: WhisperModelDescriptorReceipt, from source: URL,
                              expectedGeneration: UUID?) throws -> Snapshot {
        let fd = try openTransaction()
        defer { closeTransaction(fd) }
        let existing = try read(directoryFD: fd)
        guard existing?.0.generation == expectedGeneration else { throw StoreError.staleGeneration }
        guard receipt.descriptor.modelID == modelID else { throw WhisperModelDistributionTrust.TrustError.wrongModel }
        _ = try existing.map { try trust.updating($0.1, to: receipt) } ?? trust.initialState(receipt)
        try Task.checkCancellation()
        guard source.isFileURL, !source.path.contains("\0") else { throw StoreError.unsafeStorage }
        let temporary = ".\(modelID).\(UUID().uuidString).model-staging"
        try WhisperDownloadedFileStaging.copy(source, to: temporary, in: fd,
            byteCount: receipt.descriptor.byteCount, checkCancellation: { try Task.checkCancellation() })
        // copy owns cleanup on failure; only remove a name we successfully created.
        defer { _ = unlinkat(fd, temporary, 0) }
        // Deterministic cancellation coverage after staging, before content publication.
        try installationCheckpoint()
        try Task.checkCancellation()
        try verifyModel(receipt, directoryFD: fd, filename: temporary)
        try validateDirectoryIdentity()
        // Publish without replacing any retained release. A same-content release can
        // reuse an existing sibling, but it must pass verification below.
        let name = modelFilename(receipt)
        if renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL)) != 0, errno != EEXIST {
            throw StoreError.unsafeStorage
        }
        // Persist the content filename before publishing a ledger that references it.
        guard fsync(fd) == 0 else { throw StoreError.unsafeStorage }
        try publicationCheckpoint()
        return try transition(receipt: receipt, expectedGeneration: expectedGeneration,
                              directoryFD: fd, requireInstalled: true)
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
        let fd = try openTransaction()
        defer { closeTransaction(fd) }
        let loaded = try read(directoryFD: fd)
        try validateDirectoryIdentity()
        guard let (document, state, _) = loaded else { return nil }
        return Snapshot(generation: document.generation, release: state)
    }

    /// Lock the directory itself so an exchanged lock-file name cannot divide writers
    /// between different locks. No actor suspension is allowed while this fd is held.
    private func openTransaction() throws -> Int32 {
        let fd = try openDirectory()
        do {
            while whisperReleaseFlock(fd, LOCK_EX | LOCK_NB) != 0 {
                if errno == EINTR { continue }
                if errno == EWOULDBLOCK || errno == EAGAIN { throw StoreError.storageBusy }
                throw StoreError.unsafeStorage
            }
            try validateDirectoryIdentity()
            return fd
        } catch {
            closeTransaction(fd)
            throw error
        }
    }

    private func closeTransaction(_ fd: Int32) {
        _ = whisperReleaseFlock(fd, LOCK_UN)
        close(fd)
    }

    private func validateDirectoryIdentity() throws {
        // Repeat the complete no-follow walk, including the retained device/inode check.
        let fresh = try openDirectory()
        close(fresh)
    }

    private func read(directoryFD: Int32) throws -> (Document, WhisperModelReleaseState, WhisperModelDescriptorReceipt)? {
        let fd = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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
        var after = stat()
        var named = stat()
        guard fstat(fd, &after) == 0,
              fstatat(directoryFD, filename, &named, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == after.st_dev, info.st_ino == after.st_ino,
              info.st_size == after.st_size,
              info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              named.st_dev == after.st_dev, named.st_ino == after.st_ino else {
            throw StoreError.unsafeStorage
        }
        guard data.count == info.st_size,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == 1, document.modelID == modelID else { throw StoreError.invalidState }
        let (state, highWater) = try document.record.authenticated(using: trust)
        guard state.current.descriptor.modelID == modelID else { throw StoreError.invalidState }
        return (document, state, highWater)
    }

    private func transition(receipt: WhisperModelDescriptorReceipt?, expectedGeneration: UUID?,
                            requireInstalled: Bool = false) throws -> Snapshot {
        let fd = try openTransaction()
        defer { closeTransaction(fd) }
        return try transition(receipt: receipt, expectedGeneration: expectedGeneration,
                              directoryFD: fd, requireInstalled: requireInstalled)
    }

    private func transition(receipt: WhisperModelDescriptorReceipt?, expectedGeneration: UUID?,
                            directoryFD fd: Int32, requireInstalled: Bool) throws -> Snapshot {
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
        if requireInstalled { try verifyModel(next.current, directoryFD: fd) }
        try Task.checkCancellation()
        let document = Document(schemaVersion: 1, generation: UUID(), modelID: modelID,
                                record: WhisperModelReleaseRecord(state: next, highWater: highWater))
        let data = try JSONEncoder().encode(document)
        let temporary = ".\(filename).\(UUID().uuidString).staging"
        let stagedFD = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard stagedFD >= 0 else { throw StoreError.unsafeStorage }
        let handle = FileHandle(fileDescriptor: stagedFD, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlinkat(fd, temporary, 0)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try validateDirectoryIdentity()
        guard renameat(fd, temporary, fd, filename) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard fsync(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try validateDirectoryIdentity()
        return Snapshot(generation: document.generation, release: next)
    }
}
