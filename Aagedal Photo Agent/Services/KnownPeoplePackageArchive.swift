import CryptoKit
import Darwin
import Foundation
import ImageIO

nonisolated enum KnownPeoplePackageArchiveError: Error {
    case invalidArchive, unsafePath, sizeLimit, invalidInventory, changedFile, io, destinationExists
}

/// ZIP32 STORED is the manual interchange profile. Compression, ZIP64, links,
/// directory entries, extras, comments and data descriptors are deliberately unsupported.
/// Package paths are at archive root; the archive filename is not an entry prefix.
nonisolated enum KnownPeoplePackageArchiveCodec {
    static let maximumArchiveBytes = 536_870_912
    static let maximumEntries = 65_534
    private static let maximumPathBytes = 96

    static func decode(_ data: Data) throws -> [String: Data] {
        try Task.checkCancellation()
        guard data.count >= 22, data.count <= maximumArchiveBytes else { throw KnownPeoplePackageArchiveError.sizeLimit }
        let end = data.count - 22
        guard data.zip32(end) == 0x06054b50, data.zip16(end + 4) == 0,
              data.zip16(end + 6) == 0, data.zip16(end + 20) == 0 else { throw KnownPeoplePackageArchiveError.invalidArchive }
        let count = Int(data.zip16(end + 10))
        let central = Int(data.zip32(end + 16)), centralSize = Int(data.zip32(end + 12))
        guard count >= 2, count <= maximumEntries, Int(data.zip16(end + 8)) == count,
              central <= end, centralSize == end - central,
              centralSize <= count * (46 + maximumPathBytes) else { throw KnownPeoplePackageArchiveError.invalidArchive }
        struct Entry { let path: String; let name: Data; let size: Int; let crc: UInt32; let offset: Int; let timestamp: UInt32 }
        var entries: [Entry] = [], cursor = central, keys: Set<String> = [], total = 0
        let limits = KnownPeoplePackageManifest.Limits()
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor <= end - 46, data.zip32(cursor) == 0x02014b50 else { throw KnownPeoplePackageArchiveError.invalidArchive }
            let nameCount = Int(data.zip16(cursor + 28)), size = Int(data.zip32(cursor + 24))
            guard nameCount > 0, nameCount <= maximumPathBytes, cursor + 46 + nameCount <= end,
                  data.zip16(cursor + 6) == 20, data.zip16(cursor + 8) == 0x800,
                  data.zip16(cursor + 10) == 0, data.zip16(cursor + 30) == 0,
                  data.zip16(cursor + 32) == 0, data.zip16(cursor + 34) == 0,
                  data.zip16(cursor + 36) == 0, data.zip32(cursor + 20) == UInt32(size),
                  size > 0, size <= limits.maximumFileBytes else { throw KnownPeoplePackageArchiveError.invalidArchive }
            let host = data.zip16(cursor + 4) >> 8
            let attributes = data.zip32(cursor + 38), fileType = mode_t(attributes >> 16) & S_IFMT
            guard attributes & 0x10 == 0,
                  (host == 3 || host == 19 ? fileType == S_IFREG : fileType == 0 || fileType == S_IFREG) else {
                throw KnownPeoplePackageArchiveError.unsafePath
            }
            let name = data.subdata(in: cursor + 46..<cursor + 46 + nameCount)
            guard let path = String(data: name, encoding: .utf8) else { throw KnownPeoplePackageArchiveError.unsafePath }
            try validatePath(path)
            guard keys.insert(path.lowercased()).inserted else { throw KnownPeoplePackageArchiveError.unsafePath }
            total += size
            guard total <= limits.maximumTotalBytes + limits.maximumManifestBytes else { throw KnownPeoplePackageArchiveError.sizeLimit }
            entries.append(.init(path: path, name: name, size: size, crc: data.zip32(cursor + 16), offset: Int(data.zip32(cursor + 42)), timestamp: data.zip32(cursor + 12)))
            cursor += 46 + nameCount
        }
        guard cursor == end else { throw KnownPeoplePackageArchiveError.invalidArchive }
        // Validate every local header and range before copying any payload or materializing files.
        var next = 0
        for entry in entries.sorted(by: { $0.offset < $1.offset }) {
            let offset = entry.offset
            guard offset == next, offset <= central - 30,
                  data.zip32(offset) == 0x04034b50, data.zip16(offset + 4) == 20,
                  data.zip16(offset + 6) == 0x800, data.zip16(offset + 8) == 0,
                  data.zip32(offset + 10) == entry.timestamp,
                  data.zip32(offset + 14) == entry.crc,
                  data.zip32(offset + 18) == UInt32(entry.size), data.zip32(offset + 22) == UInt32(entry.size),
                  Int(data.zip16(offset + 26)) == entry.name.count, data.zip16(offset + 28) == 0 else {
                throw KnownPeoplePackageArchiveError.invalidArchive
            }
            let start = offset + 30 + entry.name.count
            guard start <= central, entry.size <= central - start,
                  data.subdata(in: offset + 30..<start) == entry.name else { throw KnownPeoplePackageArchiveError.invalidArchive }
            next = start + entry.size
        }
        guard next == central else { throw KnownPeoplePackageArchiveError.invalidArchive }
        var files: [String: Data] = [:]
        for entry in entries {
            try Task.checkCancellation()
            let start = entry.offset + 30 + entry.name.count
            let bytes = data.subdata(in: start..<start + entry.size)
            guard try crc32(bytes) == entry.crc else { throw KnownPeoplePackageArchiveError.invalidArchive }
            files[entry.path] = bytes
        }
        try validateFiles(files)
        return files
    }

    static func encode(_ files: [String: Data]) throws -> Data {
        try validateFiles(files)
        guard files.count <= maximumEntries else { throw KnownPeoplePackageArchiveError.sizeLimit }
        var local = Data(), central = Data()
        for path in files.keys.sorted() {
            try Task.checkCancellation()
            let bytes = files[path]!, name = Data(path.utf8), crc = try crc32(bytes)
            let offset = local.count
            guard offset + bytes.count + name.count + 30 <= maximumArchiveBytes else { throw KnownPeoplePackageArchiveError.sizeLimit }
            local.zipAppend32(0x04034b50); local.zipAppend16(20); local.zipAppend16(0x800)
            local.zipAppend16(0); local.zipAppend16(0); local.zipAppend16(0x21) // 1980-01-01, fixed DOS epoch
            local.zipAppend32(crc); local.zipAppend32(UInt32(bytes.count)); local.zipAppend32(UInt32(bytes.count))
            local.zipAppend16(UInt16(name.count)); local.zipAppend16(0); local.append(name); local.append(bytes)
            central.zipAppend32(0x02014b50); central.zipAppend16(0x0314); central.zipAppend16(20)
            central.zipAppend16(0x800); central.zipAppend16(0); central.zipAppend16(0); central.zipAppend16(0x21)
            central.zipAppend32(crc); central.zipAppend32(UInt32(bytes.count)); central.zipAppend32(UInt32(bytes.count))
            central.zipAppend16(UInt16(name.count)); central.zipAppend16(0); central.zipAppend16(0)
            central.zipAppend16(0); central.zipAppend16(0); central.zipAppend32(UInt32(S_IFREG | 0o600) << 16)
            central.zipAppend32(UInt32(offset)); central.append(name)
        }
        let centralOffset = local.count
        guard local.count + central.count + 22 <= maximumArchiveBytes else { throw KnownPeoplePackageArchiveError.sizeLimit }
        local.append(central)
        local.zipAppend32(0x06054b50); local.zipAppend16(0); local.zipAppend16(0)
        local.zipAppend16(UInt16(files.count)); local.zipAppend16(UInt16(files.count))
        local.zipAppend32(UInt32(central.count)); local.zipAppend32(UInt32(centralOffset)); local.zipAppend16(0)
        return local
    }

    static func validateFiles(_ files: [String: Data]) throws {
        guard let manifestBytes = files["manifest.json"], let peopleBytes = files["people.json"] else { throw KnownPeoplePackageArchiveError.invalidInventory }
        let manifest = try KnownPeoplePackageManifest.decode(manifestBytes)
        let payload = try KnownPeoplePackagePayload.decode(peopleBytes)
        try manifest.validate(payload: payload)
        guard Set(files.keys) == Set(manifest.files.map(\.path)).union(["manifest.json"]), files.count <= maximumEntries else {
            throw KnownPeoplePackageArchiveError.invalidInventory
        }
        for declaration in manifest.files {
            try Task.checkCancellation()
            try validatePath(declaration.path)
            guard let bytes = files[declaration.path], bytes.count == declaration.byteCount,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == declaration.sha256 else {
                throw KnownPeoplePackageArchiveError.invalidInventory
            }
            if declaration.path.hasSuffix(".fem2") { _ = try FaceEmbeddingInterchangeCodec.validate(bytes) }
            if declaration.path.hasSuffix(".jpg") {
                guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1,
                      CGImageSourceGetStatus(source) == .statusComplete,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 4096, height <= 4096,
                      CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
                    throw KnownPeoplePackageArchiveError.invalidInventory
                }
            }
        }
        if let editor = manifest.editorPayload {
            guard let bytes = files[editor.path] else { throw KnownPeoplePackageArchiveError.invalidInventory }
            _ = try KnownPeoplePackageEditorPayload.decode(bytes, manifest: manifest, payload: payload)
        }
    }

    private static func validatePath(_ path: String) throws {
        if path == "manifest.json" || path == "people.json" || path == "editor/photo-agent.json" { return }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, ["embeddings", "thumbnails", "embedding_thumbnails"].contains(String(parts[0])) else { throw KnownPeoplePackageArchiveError.unsafePath }
        let suffix = parts[0] == "embeddings" ? ".fem2" : ".jpg"
        guard parts[1].hasSuffix(suffix) else { throw KnownPeoplePackageArchiveError.unsafePath }
        let id = String(parts[1].dropLast(suffix.count))
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { throw KnownPeoplePackageArchiveError.unsafePath }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
        return value
    }
    private static func crc32(_ bytes: Data) throws -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for (index, byte) in bytes.enumerated() {
            if index % 65_536 == 0 { try Task.checkCancellation() }
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)]
        }
        return crc ^ 0xffffffff
    }
}

nonisolated private extension Data {
    func zip16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func zip32(_ offset: Int) -> UInt32 { UInt32(zip16(offset)) | UInt32(zip16(offset + 2)) << 16 }
    mutating func zipAppend16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func zipAppend32(_ value: UInt32) { zipAppend16(UInt16(truncatingIfNeeded: value)); zipAppend16(UInt16(truncatingIfNeeded: value >> 16)) }
}

nonisolated struct KnownPeoplePackageArchiveReceipt: Sendable {
    let destinationURL: URL
    let sha256: String
    let byteCount: Int
    let replacedExistingArchive: Bool
    let installedBytesVerified: Bool
    let parentDirectorySynced: Bool
}

nonisolated struct KnownPeoplePackageArchiveResult: Sendable {
    let receipt: KnownPeoplePackageArchiveReceipt?
    let wasCancelled: Bool
    let failure: String?
    /// A committed replacement can leave the displaced archive here if cleanup did not finish.
    let recoveryURLs: [URL]
    var completed: Bool { receipt != nil && failure == nil && !wasCancelled }
}

nonisolated struct KnownPeoplePackageArchiveAccess: Sendable {
    var beforeMaterialization: @Sendable () throws -> Void = {}
    /// File bytes have been written/synced; the descriptor is still owned by stage creation.
    var beforeStageAdmission: @Sendable (Int32) throws -> Void = { _ in }
    var beforeCommit: @Sendable () throws -> Void = {}
    var afterCommit: @Sendable () throws -> Void = {}
}

/// Manual archive boundary only. This adapter never changes the managed Known People store.
/// Cooperating exports serialize on the directory writer's parent lock. Exact observed-byte
/// checks do not claim atomic compare-and-rename protection against arbitrary external writers.
actor KnownPeoplePackageArchive {
    private let access: KnownPeoplePackageArchiveAccess
    init(access: KnownPeoplePackageArchiveAccess = .init()) { self.access = access }

    func importArchive(at archiveURL: URL, to destinationURL: URL,
                       overwrite: Bool = false) async -> KnownPeoplePackageWriteResult {
        var stage: KnownPeoplePackageHeldDirectory?
        var heldParent: KnownPeoplePackageHeldDirectory?
        var stageName: String?
        var parentURL: URL?
        var result: KnownPeoplePackageWriteResult?
        do {
            try Task.checkCancellation()
            let destination = try Self.destination(destinationURL, archive: false)
            let source = archiveURL.resolvingSymlinksInPath().standardizedFileURL
            guard archiveURL.isFileURL, archiveURL.lastPathComponent.hasSuffix(".aagedalpeople.zip"),
                  !Self.contains(destination, source) else { throw KnownPeoplePackageArchiveError.unsafePath }
            let input = try ArchiveFile(url: archiveURL)
            let bytes = try input.bytes()
            let files = try KnownPeoplePackageArchiveCodec.decode(bytes)
            try input.verify(bytes)
            try access.beforeMaterialization()
            try Task.checkCancellation()
            let parentPath = destination.deletingLastPathComponent()
            parentURL = parentPath
            let name = ".KnownPeople-import-\(UUID().uuidString)"
            stageName = name
            // This lexical scope releases the parent lock before DirectoryWriter acquires it.
            let held: KnownPeoplePackageHeldDirectory = try {
                let parent = try KnownPeoplePackageWriterFilesystem.openParent(parentPath)
                let retainedDescriptor = dup(parent.descriptor)
                guard retainedDescriptor >= 0 else { throw KnownPeoplePackageArchiveError.io }
                heldParent = .init(descriptor: retainedDescriptor, identity: parent.identity)
                if !overwrite, try KnownPeoplePackageWriterFilesystem.openDirectory(parent, destination.lastPathComponent) != nil {
                    throw KnownPeoplePackageArchiveError.destinationExists
                }
                return try KnownPeoplePackageWriterFilesystem.createStage(parent, name)
            }()
            stage = held
            for path in files.keys.sorted() {
                try Task.checkCancellation()
                try KnownPeoplePackageWriterFilesystem.writeFile(files[path]!, path, held)
            }
            try Task.checkCancellation()
            let stageURL = parentPath.appendingPathComponent(name, isDirectory: true)
            let snapshot = try await KnownPeoplePackageDirectoryReader().read(
                heldDirectoryDescriptor: held.descriptor, sourceURL: stageURL)
            guard snapshot.files == files else { throw KnownPeoplePackageArchiveError.changedFile }
            var writeAccess = KnownPeoplePackageWriteAccess()
            if !overwrite {
                writeAccess.install = { plan, committed in
                    guard plan.destinationIdentity == nil else { throw KnownPeoplePackageArchiveError.destinationExists }
                    try KnownPeoplePackageWriterFilesystem.install(plan, onCommitted: committed)
                }
            }
            let hook = access.beforeCommit
            writeAccess.beforeCommit = { try input.verify(bytes); try hook() }
            writeAccess.afterCommit = access.afterCommit
            result = await KnownPeoplePackageDirectoryWriter(access: writeAccess).write(snapshot: snapshot, destinationURL: destination)
        } catch {
            result = .init(receipt: nil, wasCancelled: error is CancellationError,
                           failure: error is CancellationError ? nil : String(describing: error), recoveryDirectories: [])
        }
        var recovery = result?.recoveryDirectories ?? []
        var cleanupFailure: String?
        if let stage, let stageName, let parentURL, let heldParent {
            let recoveryURL = (try? KnownPeoplePackageWriterFilesystem.directoryURL(stage)) ?? parentURL.appendingPathComponent(stageName)
            do {
                // The transaction lock was released for DirectoryWriter, but the original
                // parent descriptor remains open. Never reopen the old lexical path: it
                // may now name an unrelated replacement directory.
                let actualParent = try KnownPeoplePackageWriterFilesystem.directoryURL(heldParent)
                let parent = try KnownPeoplePackageWriterFilesystem.openParent(actualParent)
                guard parent.identity.sameDirectory(as: heldParent.identity) else { throw KnownPeoplePackageArchiveError.changedFile }
                try KnownPeoplePackageWriterFilesystem.removeOwned(parent, stageName, stage.identity)
            } catch {
                recovery.append(recoveryURL)
                cleanupFailure = "Imported package cleanup did not finish: \(error)"
            }
        }
        let value = result!
        return .init(receipt: value.receipt, wasCancelled: value.wasCancelled, failure: value.failure ?? cleanupFailure,
                     recoveryDirectories: recovery)
    }

    func export(snapshot: KnownPeoplePackageSnapshot, to destinationURL: URL,
                overwrite: Bool = false) throws -> KnownPeoplePackageArchiveResult {
        var receipt: KnownPeoplePackageArchiveReceipt?
        var recovery: [URL] = [], cancelled = false, failure: String?
        var parent: KnownPeoplePackageParentTransaction?
        var staged: ArchiveFile?
        var previous: ArchiveFile?
        var stageName: String?
        var committed = false
        do {
            try Task.checkCancellation()
            try KnownPeoplePackageSnapshotValidation.validate(snapshot)
            let destination = try Self.destination(destinationURL, archive: true)
            let source = snapshot.sourceDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
            guard let sourceID = try KnownPeoplePackageWriterFilesystem.inspect(source),
                  sourceID.device == snapshot.sourceDevice, sourceID.inode == snapshot.sourceInode,
                  !Self.contains(source, destination), !Self.contains(destination, source) else {
                throw KnownPeoplePackageArchiveError.unsafePath
            }
            let bytes = try KnownPeoplePackageArchiveCodec.encode(snapshot.files)
            let parentHandle = try KnownPeoplePackageWriterFilesystem.openParent(destination.deletingLastPathComponent())
            parent = parentHandle
            let leaf = destination.lastPathComponent
            previous = try ArchiveFile.optional(parent: parentHandle.descriptor, name: leaf)
            guard overwrite || previous == nil else { throw KnownPeoplePackageArchiveError.destinationExists }
            let oldBytes = try previous?.bytes()
            let name = ".KnownPeople-archive-\(UUID().uuidString)"
            stageName = name
            staged = try ArchiveFile.create(parent: parentHandle.descriptor, name: name, bytes: bytes,
                                           beforeAdmission: access.beforeStageAdmission)
            try staged!.verify(bytes)
            try access.beforeCommit()
            try Task.checkCancellation()
            try staged!.verify(bytes)
            try staged!.verifyEntry(parent: parentHandle.descriptor, name: name)
            if let previous, let oldBytes {
                try previous.verify(oldBytes)
                try previous.verifyEntry(parent: parentHandle.descriptor, name: leaf)
            } else {
                guard try ArchiveFile.optional(parent: parentHandle.descriptor, name: leaf) == nil else {
                    throw KnownPeoplePackageArchiveError.changedFile
                }
            }
            let flags = previous == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
            guard renameatx_np(parentHandle.descriptor, name, parentHandle.descriptor, leaf, flags) == 0 else {
                throw KnownPeoplePackageArchiveError.io
            }
            committed = true
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            receipt = .init(destinationURL: destination, sha256: hash, byteCount: bytes.count,
                            replacedExistingArchive: previous != nil, installedBytesVerified: false, parentDirectorySynced: false)
            try access.afterCommit()
            try Task.checkCancellation()
            try staged!.verifyEntry(parent: parentHandle.descriptor, name: leaf)
            // Rename updates ctime; content and descriptor identity remain independently checked.
            guard try staged!.bytes(requireOriginalTimes: false) == bytes else { throw KnownPeoplePackageArchiveError.changedFile }
            guard fsync(parentHandle.descriptor) == 0 else { throw KnownPeoplePackageArchiveError.io }
            receipt = .init(destinationURL: destination, sha256: hash, byteCount: bytes.count,
                            replacedExistingArchive: previous != nil, installedBytesVerified: true, parentDirectorySynced: true)
            if let previous, let oldBytes {
                try previous.verifyEntry(parent: parentHandle.descriptor, name: name)
                guard try previous.bytes(requireOriginalTimes: false) == oldBytes else { throw KnownPeoplePackageArchiveError.changedFile }
                try Task.checkCancellation()
                guard unlinkat(parentHandle.descriptor, name, 0) == 0 else { throw KnownPeoplePackageArchiveError.io }
            }
            stageName = nil
        } catch {
            cancelled = error is CancellationError
            if !cancelled { failure = String(describing: error) }
        }
        if let parent, let stageName {
            let recoveryURL = (try? KnownPeoplePackageWriterFilesystem.entryURL(parent, stageName)) ?? parent.initialURL.appendingPathComponent(stageName)
            if committed {
                if previous != nil { recovery.append(recoveryURL) }
            } else if let staged {
                do {
                    try staged.verifyEntry(parent: parent.descriptor, name: stageName)
                    guard unlinkat(parent.descriptor, stageName, 0) == 0 else { throw KnownPeoplePackageArchiveError.io }
                } catch { recovery.append(recoveryURL) }
            } else {
                // Creation may fail before returning an admitted handle. Its cleanup owns
                // only the original inode; report any surviving entry rather than silently
                // orphaning it or deleting a possible external replacement.
                var info = stat()
                if fstatat(parent.descriptor, stageName, &info, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
                    recovery.append(recoveryURL)
                }
            }
        }
        if let prior = receipt, let parent,
           let actualURL = try? KnownPeoplePackageWriterFilesystem.entryURL(parent, destinationURL.lastPathComponent) {
            receipt = .init(destinationURL: actualURL, sha256: prior.sha256, byteCount: prior.byteCount,
                            replacedExistingArchive: prior.replacedExistingArchive,
                            installedBytesVerified: prior.installedBytesVerified, parentDirectorySynced: prior.parentDirectorySynced)
        }
        return .init(receipt: receipt, wasCancelled: cancelled, failure: failure, recoveryURLs: recovery)
    }

    private static func destination(_ url: URL, archive: Bool) throws -> URL {
        let validExtension = archive ? url.lastPathComponent.hasSuffix(".aagedalpeople.zip") : url.pathExtension == "aagedalpeople"
        guard url.isFileURL, validExtension, !url.lastPathComponent.contains("\0") else {
            throw KnownPeoplePackageArchiveError.unsafePath
        }
        // Resolve existing parent aliases once, never the destination leaf. All subsequent
        // creation, identity checks and rename operations use the retained parent descriptor.
        return url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(url.lastPathComponent)
    }
    private static func contains(_ directory: URL, _ child: URL) -> Bool {
        child.path == directory.path || child.path.hasPrefix(directory.path + "/")
    }
}

nonisolated private final class ArchiveFile: @unchecked Sendable {
    let fd: Int32
    private let original: stat
    deinit { close(fd) }
    private init(fd: Int32) throws {
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= KnownPeoplePackageArchiveCodec.maximumArchiveBytes else {
            if fd >= 0 { close(fd) }; throw KnownPeoplePackageArchiveError.unsafePath
        }
        self.fd = fd; original = info
    }
    convenience init(url: URL) throws { try self.init(fd: open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)) }
    static func optional(parent: Int32, name: String) throws -> ArchiveFile? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        return try .init(fd: fd)
    }
    static func create(parent: Int32, name: String, bytes: Data,
                       beforeAdmission: @Sendable (Int32) throws -> Void) throws -> ArchiveFile {
        let fd = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw KnownPeoplePackageArchiveError.io }
        var original = stat(), capturedIdentity = false, initializerOwnsDescriptor = false
        do {
            guard fstat(fd, &original) == 0 else { throw KnownPeoplePackageArchiveError.io }
            capturedIdentity = true
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    try Task.checkCancellation()
                    let amount = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), min(65_536, buffer.count - offset))
                    if amount < 0, errno == EINTR { continue }
                    guard amount > 0 else { throw KnownPeoplePackageArchiveError.io }
                    offset += amount
                }
            }
            guard fsync(fd) == 0 else { throw KnownPeoplePackageArchiveError.io }
            try beforeAdmission(fd)
            // init(fd:) consumes the descriptor on success AND failure. Transfer ownership
            // before calling it, so a rejected post-write fstat never causes a double close.
            initializerOwnsDescriptor = true
            return try .init(fd: fd)
        } catch {
            if !initializerOwnsDescriptor { close(fd) }
            var entry = stat()
            if capturedIdentity, fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
               entry.st_mode & S_IFMT == S_IFREG, entry.st_dev == original.st_dev, entry.st_ino == original.st_ino {
                _ = unlinkat(parent, name, 0)
            }
            throw error
        }
    }
    func bytes(requireOriginalTimes: Bool = true) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == original.st_size, info.st_nlink == 1,
              !requireOriginalTimes || Self.sameTimes(info, original) else { throw KnownPeoplePackageArchiveError.changedFile }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let amount = pread(fd, buffer.baseAddress!.advanced(by: offset), min(65_536, buffer.count - offset), off_t(offset))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw KnownPeoplePackageArchiveError.io }
                offset += amount
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == info.st_size, after.st_nlink == 1,
              Self.sameTimes(info, after) else { throw KnownPeoplePackageArchiveError.changedFile }
        return data
    }
    func verify(_ expected: Data) throws {
        guard try bytes() == expected else { throw KnownPeoplePackageArchiveError.changedFile }
    }
    func verifyEntry(parent: Int32, name: String) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_dev == original.st_dev, info.st_ino == original.st_ino else { throw KnownPeoplePackageArchiveError.changedFile }
    }
    private static func sameTimes(_ a: stat, _ b: stat) -> Bool {
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
