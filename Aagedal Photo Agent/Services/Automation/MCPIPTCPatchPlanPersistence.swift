import Darwin
import Foundation

@_silgen_name("flock")
nonisolated private func patchPlanFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Private, bounded snapshot storage. Cooperating helpers hold the same nonblocking file
/// lock through reload and replacement, so a second process cannot bypass capacity limits.
/// The checksum detects corruption, not malicious changes by the same local account.
nonisolated final class MCPIPTCPatchPlanPersistence: Sendable {
    private let directory: URL
    private let maximumBytes: Int

    init(directory: URL, maximumBytes: Int) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    func transaction<T>(readOnly: Bool = false, _ body: (Data?) throws -> (T, Data)) throws -> T {
        let root = try openDirectory(create: !readOnly)
        guard root >= 0 else { return try body(nil).0 }
        defer { Darwin.close(root) }
        let lock = Darwin.openat(root, "plans.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (readOnly ? 0 : O_CREAT), 0o600)
        guard lock >= 0 else { throw MCPIPTCPatchPlanStore.Failure.storageUnavailable }
        defer { Darwin.close(lock) }
        try validateFile(lock)
        guard patchPlanFlock(lock, LOCK_EX | LOCK_NB) == 0 else { throw MCPIPTCPatchPlanStore.Failure.storageUnavailable }
        defer { patchPlanFlock(lock, LOCK_UN) }
        try validateNamedIdentity(lock, name: "plans.lock", root: root)
        let existing = try read(root)
        let (result, replacement) = try body(existing)
        try validateDirectoryIdentity(root)
        try validateNamedIdentity(lock, name: "plans.lock", root: root)
        if !readOnly, replacement != existing { try write(replacement, root: root) }
        try validateDirectoryIdentity(root)
        return result
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw MCPIPTCPatchPlanStore.Failure.storageUnavailable }
        let components = directory.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw MCPIPTCPatchPlanStore.Failure.storageUnavailable
        }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw MCPIPTCPatchPlanStore.Failure.storageUnavailable }
        do {
            for component in components {
                var next = Darwin.openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT {
                    if !create { Darwin.close(current); return -1 }
                    guard mkdirat(current, component, 0o700) == 0 || errno == EEXIST else {
                        throw MCPIPTCPatchPlanStore.Failure.storageUnavailable
                    }
                    next = Darwin.openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw MCPIPTCPatchPlanStore.Failure.storageUnavailable }
                Darwin.close(current)
                current = next
            }
            var status = stat()
            guard fstat(current, &status) == 0, status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else {
                throw MCPIPTCPatchPlanStore.Failure.storageUnavailable
            }
            return current
        } catch { Darwin.close(current); throw error }
    }

    private func validateNamedIdentity(_ descriptor: Int32, name: String, root: Int32) throws {
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            throw MCPIPTCPatchPlanStore.Failure.storageUnavailable
        }
    }

    private func validateDirectoryIdentity(_ root: Int32) throws {
        let fresh = try openDirectory(create: false)
        guard fresh >= 0 else { throw MCPIPTCPatchPlanStore.Failure.storageUnavailable }
        defer { Darwin.close(fresh) }
        var original = stat()
        var current = stat()
        guard fstat(root, &original) == 0, fstat(fresh, &current) == 0,
              original.st_dev == current.st_dev, original.st_ino == current.st_ino else {
            throw MCPIPTCPatchPlanStore.Failure.storageUnavailable
        }
    }

    private func validateFile(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_nlink == 1, status.st_mode & 0o077 == 0 else {
            throw MCPIPTCPatchPlanStore.Failure.storageUnavailable
        }
    }

    private func read(_ root: Int32) throws -> Data? {
        let descriptor = Darwin.openat(root, "plans.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw MCPIPTCPatchPlanStore.Failure.storageUnavailable
        }
        defer { Darwin.close(descriptor) }
        try validateFile(descriptor)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size >= 0, status.st_size <= maximumBytes else {
            throw MCPIPTCPatchPlanStore.Failure.invalidStorage
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw MCPIPTCPatchPlanStore.Failure.storageUnavailable }
            if count == 0 { break }
            guard count <= maximumBytes - data.count else { throw MCPIPTCPatchPlanStore.Failure.invalidStorage }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        var named = stat()
        guard data.count == status.st_size, fstat(descriptor, &after) == 0,
              fstatat(root, "plans.json", &named, AT_SYMLINK_NOFOLLOW) == 0,
              status.st_dev == after.st_dev, status.st_ino == after.st_ino,
              status.st_size == after.st_size,
              status.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              status.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              status.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              status.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              named.st_dev == after.st_dev, named.st_ino == after.st_ino else {
            throw MCPIPTCPatchPlanStore.Failure.invalidStorage
        }
        return data
    }

    private func write(_ data: Data, root: Int32) throws {
        guard data.count <= maximumBytes else { throw MCPIPTCPatchPlanStore.Failure.capacity }
        let name = ".plans-\(UUID().uuidString).tmp"
        let descriptor = Darwin.openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MCPIPTCPatchPlanStore.Failure.storageUnavailable }
        defer { Darwin.close(descriptor); unlinkat(root, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw MCPIPTCPatchPlanStore.Failure.storageUnavailable }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, renameat(root, name, root, "plans.json") == 0, fsync(root) == 0 else {
            throw MCPIPTCPatchPlanStore.Failure.storageUnavailable
        }
    }
}
