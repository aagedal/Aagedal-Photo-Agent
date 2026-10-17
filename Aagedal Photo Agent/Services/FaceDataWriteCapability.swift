import Darwin
import Foundation

/// Records file publication separately from directory creation for partial-completion evidence.
nonisolated struct FaceDataWriteError: LocalizedError {
    let committed: Bool
    var directoriesCreated: Bool = false
    let underlying: any Error

    var errorDescription: String? {
        let publication = committed
            ? "Face data was published, but verification failed."
            : "Face data was not published."
        let directories = directoriesCreated ? " Storage directories were created before the failure." : ""
        return publication + directories + " " + underlying.localizedDescription
    }
}

/// Retains the exact directory objects admitted for a scan. Construction is read-only;
/// absent storage directories are created only at an authorized write boundary.
nonisolated final class FaceDataWriteCapability: @unchecked Sendable {
    enum Checkpoint: Sendable {
        case staged(URL)
        case willCommit
        case didCommit
    }

    private enum Failure: LocalizedError {
        case unsafeDirectory, changedIdentity, wrongFolder, io(Int32)

        var errorDescription: String? {
            switch self {
            case .unsafeDirectory: "Face-data storage contains an unsupported directory or symbolic link."
            case .changedIdentity: "Face-data storage changed during scanning. Review the folder and retry."
            case .wrongFolder: "The face-data save does not match the approved folder."
            case .io(let code): "Face-data storage failed: " + POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription
            }
        }
    }

    private final class Directory {
        let descriptor: Int32
        let identity: stat
        init(_ descriptor: Int32) throws {
            var value = stat()
            guard fstat(descriptor, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else {
                close(descriptor)
                throw Failure.unsafeDirectory
            }
            self.descriptor = descriptor
            self.identity = value
        }
        deinit { close(descriptor) }
    }

    let folderURL: URL
    private let authority: @Sendable (URL) throws -> Void
    private let checkpoint: @Sendable (Checkpoint) throws -> Void
    private let lock = NSLock()
    private let ancestors: [Directory]
    private let components: [String]
    private var storage: Directory?
    private var thumbnails: Directory?

    init(folderURL: URL,
         effectAuthority: @escaping @Sendable (URL) throws -> Void,
         checkpoint: @escaping @Sendable (Checkpoint) throws -> Void = { _ in }) throws {
        guard folderURL.isFileURL, !folderURL.pathComponents.contains("..") else {
            throw Failure.unsafeDirectory
        }
        self.folderURL = folderURL.standardizedFileURL
        authority = effectAuthority
        self.checkpoint = checkpoint
        // Foundation deliberately abbreviates existing /private/tmp and /private/var
        // paths to their system aliases even in standardized/resolved URLs. Traverse
        // realpath's physical components, while retaining the approved URL for authority
        // comparison. Arbitrary aliases must not become new write authority.
        guard let physical = realpath(self.folderURL.path, nil) else { throw Failure.io(errno) }
        let physicalPath = String(cString: physical)
        free(physical)
        guard URL(fileURLWithPath: physicalPath).standardizedFileURL == self.folderURL else {
            throw Failure.unsafeDirectory
        }
        components = physicalPath.split(separator: "/").map(String.init)
        let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Failure.io(errno) }
        var chain = [try Directory(root)]
        for component in components {
            let fd = openat(chain.last!.descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.unsafeDirectory }
            chain.append(try Directory(fd))
        }
        ancestors = chain
        storage = try Self.openExistingDirectory(parent: chain.last!, name: ".face_data")
        if let storage {
            thumbnails = try Self.openExistingDirectory(parent: storage, name: "thumbnails")
        }
        try validate()
    }

    func saveFaceData(_ faceData: FolderFaceData) throws {
        guard faceData.folderURL.standardizedFileURL == folderURL else {
            throw FaceDataWriteError(committed: false, underlying: Failure.wrongFolder)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try publish(encoder.encode(faceData), name: "face_data.json", thumbnail: false)
    }

    func saveThumbnail(_ jpegData: Data, for faceID: UUID) throws {
        try publish(jpegData, name: "\(faceID.uuidString).jpg", thumbnail: true)
    }

    private static func openExistingDirectory(parent: Directory, name: String) throws -> Directory? {
        let fd = openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 { return try Directory(fd) }
        guard errno == ENOENT else { throw Failure.unsafeDirectory }
        return nil
    }

    private func validate() throws {
        try authority(folderURL)
        for index in components.indices {
            try Self.requireEntry(parent: ancestors[index], name: components[index], child: ancestors[index + 1])
        }
        if let storage {
            try Self.requireEntry(parent: ancestors.last!, name: ".face_data", child: storage)
            if let thumbnails { try Self.requireEntry(parent: storage, name: "thumbnails", child: thumbnails) }
        }
    }

    private static func requireEntry(parent: Directory, name: String, child: Directory) throws {
        var live = stat()
        guard fstatat(parent.descriptor, name, &live, AT_SYMLINK_NOFOLLOW) == 0,
              (live.st_mode & S_IFMT) == S_IFDIR,
              live.st_dev == child.identity.st_dev, live.st_ino == child.identity.st_ino else {
            throw Failure.changedIdentity
        }
    }

    private func createDirectory(parent: Directory, name: String, directoriesCreated: inout Bool) throws -> Directory {
        try validate()
        // EEXIST is refused: this capability observed absence, so it alone may create
        // the new entry. Never adopt a directory substituted after admission.
        guard mkdirat(parent.descriptor, name, 0o700) == 0 else { throw Failure.io(errno) }
        directoriesCreated = true
        // Make the new entry durable in its parent, including the admitted photo
        // folder when .face_data did not exist at admission.
        guard fsync(parent.descriptor) == 0 else { throw Failure.io(errno) }
        guard let child = try Self.openExistingDirectory(parent: parent, name: name) else {
            throw Failure.changedIdentity
        }
        try Self.requireEntry(parent: parent, name: name, child: child)
        return child
    }

    private func publish(_ data: Data, name: String, thumbnail: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        var committed = false
        var directoriesCreated = false
        do {
            try validate()
            if storage == nil {
                storage = try createDirectory(parent: ancestors.last!, name: ".face_data", directoriesCreated: &directoriesCreated)
            }
            if thumbnails == nil {
                thumbnails = try createDirectory(parent: storage!, name: "thumbnails", directoriesCreated: &directoriesCreated)
            }
            try validate()
            let parent = thumbnail ? thumbnails! : storage!
            let temporary = ".face-stage-\(UUID().uuidString).tmp"
            let fd = openat(parent.descriptor, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.io(errno) }
            var staged = stat()
            var temporaryExists = true
            defer {
                // Cleanup owns only the inode we created, never a replacement entry.
                var live = stat()
                if temporaryExists, fstatat(parent.descriptor, temporary, &live, AT_SYMLINK_NOFOLLOW) == 0,
                   live.st_dev == staged.st_dev, live.st_ino == staged.st_ino {
                    _ = unlinkat(parent.descriptor, temporary, 0)
                }
                close(fd)
            }
            guard fstat(fd, &staged) == 0 else { throw Failure.io(errno) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Failure.io(errno) }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw Failure.io(errno) }
            let directoryURL = thumbnail ? folderURL.appendingPathComponent(".face_data/thumbnails") : folderURL.appendingPathComponent(".face_data")
            try checkpoint(.staged(directoryURL.appendingPathComponent(temporary)))
            try checkpoint(.willCommit)
            try validate()
            try Self.requireFile(fd: fd, parent: parent, name: temporary, expected: staged, data: data)
            guard renameat(parent.descriptor, temporary, parent.descriptor, name) == 0 else { throw Failure.io(errno) }
            temporaryExists = false
            committed = true
            try checkpoint(.didCommit)
            guard fsync(parent.descriptor) == 0 else { throw Failure.io(errno) }
            try validate()
            try Self.requireFile(fd: fd, parent: parent, name: name, expected: staged, data: data)
        } catch {
            throw FaceDataWriteError(committed: committed, directoriesCreated: directoriesCreated, underlying: error)
        }
    }

    private static func requireFile(fd: Int32, parent: Directory, name: String, expected: stat, data: Data) throws {
        var opened = stat(), live = stat()
        guard fstat(fd, &opened) == 0,
              fstatat(parent.descriptor, name, &live, AT_SYMLINK_NOFOLLOW) == 0,
              (live.st_mode & S_IFMT) == S_IFREG, live.st_nlink == 1,
              live.st_dev == expected.st_dev, live.st_ino == expected.st_ino,
              opened.st_dev == live.st_dev, opened.st_ino == live.st_ino,
              live.st_size == data.count else { throw Failure.changedIdentity }
        var readback = Data(count: data.count)
        try readback.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pread(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.changedIdentity }
                offset += count
            }
        }
        guard readback == data else { throw Failure.changedIdentity }
    }
}
