import Darwin
import Foundation

nonisolated enum FFmpegWhisperOutputError: Error, Equatable, Sendable {
    case producerNotSuccessful
    case unsafePath
    case unsafeFile
    case fileChanged
    case readFailed
}

/// Reads canonical output only after the owner has observed process termination. This enum is a
/// caller-supplied precondition, not independent proof of inference success or source provenance.
nonisolated enum FFmpegWhisperProducerCompletion: Equatable, Sendable {
    case running
    case exited(status: Int32)
    case signalled(signal: Int32)
}

/// A bounded, no-follow reader for a private inference job's canonical output. The future provider
/// must supply an absolute path with no symlink components and retain ownership of the job directory.
/// Neither these bytes nor successful exit confer reviewed transcript approval.
nonisolated enum FFmpegWhisperOutputReader {
    static func read(
        from url: URL,
        completion: FFmpegWhisperProducerCompletion,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> FFmpegWhisperTranscript {
        try checkCancellation()
        guard completion == .exited(status: 0) else {
            throw FFmpegWhisperOutputError.producerNotSuccessful
        }
        let admitted = try openFile(url)
        let descriptor = admitted.descriptor
        defer { close(descriptor) }
        let before = try identity(descriptor)
        guard before.st_size >= 0,
              before.st_size <= FFmpegWhisperJSONParser.maximumOutputBytes else {
            throw FFmpegWhisperJSONError.outputTooLarge
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try checkCancellation()
            guard unchanged(before, try identity(descriptor)) else {
                throw FFmpegWhisperOutputError.fileChanged
            }
            // Always bound actual reads too; a stale initial stat must never permit unbounded data.
            let remaining = min(FFmpegWhisperJSONParser.maximumOutputBytes, Int(before.st_size)) - data.count
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, remaining + 1))
            if count < 0 {
                if errno == EINTR { continue }
                throw FFmpegWhisperOutputError.readFailed
            }
            if count == 0 { break }
            guard count <= remaining else { throw FFmpegWhisperOutputError.fileChanged }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == before.st_size else { throw FFmpegWhisperOutputError.fileChanged }
        try verifyUnchanged(url, admitted: admitted, before: before)
        let transcript = try FFmpegWhisperJSONParser.parse(data)
        try checkCancellation()
        try verifyUnchanged(url, admitted: admitted, before: before)
        return transcript
    }

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct OpenedFile {
        let descriptor: Int32
        let ancestors: [DirectoryIdentity]
    }

    private static func directoryIdentity(_ descriptor: Int32) throws -> DirectoryIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw FFmpegWhisperOutputError.unsafePath
        }
        return DirectoryIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func openFile(_ url: URL) throws -> OpenedFile {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw FFmpegWhisperOutputError.unsafePath
        }
        let path = url.path
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"), !path.utf8.contains(0), !components.isEmpty,
              !components.contains("."), !components.contains("..") else {
            throw FFmpegWhisperOutputError.unsafePath
        }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw FFmpegWhisperOutputError.unsafePath }
        defer { close(current) }
        var ancestors = [try directoryIdentity(current)]
        for component in components.dropLast() {
            let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw FFmpegWhisperOutputError.unsafePath }
            close(current)
            current = next
            ancestors.append(try directoryIdentity(current))
        }
        let file = openat(current, String(components.last!), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw FFmpegWhisperOutputError.unsafeFile }
        do {
            _ = try identity(file)
            return OpenedFile(descriptor: file, ancestors: ancestors)
        } catch {
            close(file)
            throw error
        }
    }

    private static func identity(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1 else { throw FFmpegWhisperOutputError.unsafeFile }
        return info
    }

    private static func unchanged(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
        a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec &&
        a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private static func verifyUnchanged(_ url: URL, admitted: OpenedFile, before: stat) throws {
        guard unchanged(before, try identity(admitted.descriptor)) else {
            throw FFmpegWhisperOutputError.fileChanged
        }
        // Re-walk the entire path without following links: descriptor stability alone misses rename
        // replacement or substitution of a parent directory while the original file stays open.
        let current: OpenedFile
        do { current = try openFile(url) }
        catch { throw FFmpegWhisperOutputError.fileChanged }
        defer { close(current.descriptor) }
        guard current.ancestors == admitted.ancestors,
              unchanged(before, try identity(current.descriptor)) else {
            throw FFmpegWhisperOutputError.fileChanged
        }
    }
}
