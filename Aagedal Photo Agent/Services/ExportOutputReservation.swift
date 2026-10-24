import Darwin
import Foundation

nonisolated enum ExportOutputReservationError: LocalizedError {
    case invalidDestination(URL)

    var errorDescription: String? {
        switch self {
        case .invalidDestination(let url):
            "The export destination \(url.lastPathComponent) is not a regular file."
        }
    }
}

/// Holds destination claims across pixel encoding and subsequent metadata work. Numbered
/// allocation also occupies the actual path, so another process cannot choose the same name
/// merely because its first encode has not started. Only an unchanged, empty owned placeholder
/// is removed on release; encoded pixels and foreign replacements are retained.
nonisolated final class ExportOutputReservationOwner: @unchecked Sendable {
    private struct Claim: Sendable {
        let keys: [String]
        let url: URL
        let descriptor: Int32?
        let device: dev_t
        let inode: ino_t
    }

    private let lock = NSLock()
    private var claims: [Claim] = []
    private let beforeFilesystemAccess: @Sendable (URL) -> Void
    private let beforeCleanup: @Sendable () -> Void

    init(beforeFilesystemAccess: @escaping @Sendable (URL) -> Void = { _ in },
         beforeCleanup: @escaping @Sendable () -> Void = {}) {
        self.beforeFilesystemAccess = beforeFilesystemAccess
        self.beforeCleanup = beforeCleanup
    }

    func reserveOutput(for sourceURL: URL, in folder: URL, extension ext: String,
                       filenameSuffix: String = "",
                       collisionPolicy: EditedImageRenderer.OutputCollisionPolicy) throws -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent + filenameSuffix
        var number = 1
        while true {
            let suffix = number == 1 ? "" : " \(number)"
            let candidate = folder.appendingPathComponent(base + suffix).appendingPathExtension(ext)
            do {
                try EditedImageRenderer.requireDistinctDestination(candidate, from: sourceURL)
            } catch EditedImageRenderer.RenderError.sourceDestinationAlias {
                if case .appendNumber = collisionPolicy { number += 1; continue }
                throw EditedImageRenderer.RenderError.sourceDestinationAlias
            }
            let keys = Self.keys(for: candidate)
            guard ExportOutputNamespace.claim(keys) else {
                if case .appendNumber = collisionPolicy { number += 1; continue }
                throw EditedImageRenderer.RenderError.destinationBusy
            }
            do {
                beforeFilesystemAccess(candidate)
                let descriptor = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
                if descriptor >= 0 {
                    var status = stat()
                    guard Darwin.fstat(descriptor, &status) == 0 else {
                        let code = errno
                        Darwin.close(descriptor)
                        throw Self.filesystemError(code, at: candidate)
                    }
                    let inodeKey = "inode:\(status.st_dev):\(status.st_ino)"
                    guard ExportOutputNamespace.claim([inodeKey]) else {
                        Self.removeEmptyPlaceholder(at: candidate, device: status.st_dev, inode: status.st_ino)
                        Darwin.close(descriptor)
                        throw EditedImageRenderer.RenderError.destinationBusy
                    }
                    lock.withLock {
                        claims.append(Claim(keys: keys + [inodeKey], url: candidate, descriptor: descriptor,
                                            device: status.st_dev, inode: status.st_ino))
                    }
                    return candidate
                }
                let code = errno
                if code == EEXIST {
                    if case .appendNumber = collisionPolicy {
                        ExportOutputNamespace.release(keys)
                        number += 1
                        continue
                    }
                    let resolved = candidate.resolvingSymlinksInPath()
                    let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else {
                        throw ExportOutputReservationError.invalidDestination(candidate)
                    }
                    // Recheck before handing an existing path to an overwriting encoder.
                    try EditedImageRenderer.requireDistinctDestination(candidate, from: sourceURL)
                    guard let device = attributes[.systemNumber] as? NSNumber,
                          let inode = attributes[.systemFileNumber] as? NSNumber else {
                        throw ExportOutputReservationError.invalidDestination(candidate)
                    }
                    let inodeKey = "inode:\(device.stringValue):\(inode.stringValue)"
                    guard ExportOutputNamespace.claim([inodeKey]) else {
                        throw EditedImageRenderer.RenderError.destinationBusy
                    }
                    lock.withLock {
                        claims.append(Claim(keys: keys + [inodeKey], url: candidate, descriptor: nil, device: 0, inode: 0))
                    }
                    return candidate
                }
                throw Self.filesystemError(code, at: candidate)
            } catch {
                ExportOutputNamespace.release(keys)
                throw error
            }
        }
    }

    private static func keys(for url: URL) -> [String] {
        // Keep the spelling after resolving its parent as well as the existing target:
        // atomic encoding can replace a final symlink, changing its resolved identity.
        // Both keys retain the extension and conservatively fold case.
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let stable = parent.appendingPathComponent(url.lastPathComponent)
        return Array(Set([stable.path.lowercased(), stable.resolvingSymlinksInPath().path.lowercased()]))
    }

    private static func filesystemError(_ code: Int32, at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }

    private static func removeEmptyPlaceholder(at url: URL, device: dev_t, inode: ino_t) {
        var current = stat()
        if Darwin.lstat(url.path, &current) == 0,
           current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), current.st_size == 0,
           current.st_dev == device, current.st_ino == inode {
            _ = Darwin.unlink(url.path)
        }
    }

    /// Finish admitted filesystem work before releasing names, without running cleanup
    /// on the caller's actor. Cancellation must not abandon these ownership obligations.
    func release() async {
        await release(discardingOwnedContents: false)
    }

    /// Failure/cancellation path: a failed encoder (e.g. FFmpeg writing JPEG XL/AVIF with
    /// `-y` straight to the reserved name, or an interrupted ImageIO finalize) can leave
    /// partial bytes under the final name. Unlink every file this owner itself created
    /// (O_EXCL placeholder) whose device/inode still match, regardless of size. A claim on a
    /// pre-existing file, or a path whose identity changed (replaced by anyone), is never
    /// deleted — only names are released for those.
    func discardOnFailure() async {
        await release(discardingOwnedContents: true)
    }

    private func release(discardingOwnedContents: Bool) async {
        let drained = drainClaims()
        guard !drained.isEmpty else { return }
        let hook = beforeCleanup
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                hook()
                Self.cleanup(drained, discardingOwnedContents: discardingOwnedContents)
                continuation.resume()
            }
        }
    }

    private func drainClaims() -> [Claim] {
        lock.withLock {
            let drained = claims
            claims.removeAll()
            return drained
        }
    }

    private static func cleanup(_ claims: [Claim], discardingOwnedContents: Bool = false) {
        for claim in claims {
            if let descriptor = claim.descriptor {
                if discardingOwnedContents {
                    Self.removeOwnedFile(at: claim.url, device: claim.device, inode: claim.inode)
                } else {
                    Self.removeEmptyPlaceholder(at: claim.url, device: claim.device, inode: claim.inode)
                }
                Darwin.close(descriptor)
            }
            ExportOutputNamespace.release(claim.keys)
        }
    }

    private static func removeOwnedFile(at url: URL, device: dev_t, inode: ino_t) {
        var current = stat()
        if Darwin.lstat(url.path, &current) == 0,
           current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
           current.st_dev == device, current.st_ino == inode {
            _ = Darwin.unlink(url.path)
        }
    }

    deinit {
        let drained = drainClaims()
        if !drained.isEmpty {
            beforeCleanup()
            Self.cleanup(drained)
        }
    }
}

/// The registry protects only process admission bookkeeping. Source checks, provider/file
/// system calls and cleanup always run outside this lock, allowing unrelated exports to proceed.
private nonisolated enum ExportOutputNamespace {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active: Set<String> = []

    static func claim(_ keys: [String]) -> Bool {
        lock.withLock {
            guard keys.allSatisfy({ !active.contains($0) }) else { return false }
            active.formUnion(keys)
            return true
        }
    }
    static func release(_ keys: [String]) {
        lock.withLock { active.subtract(keys) }
    }
}
