import CryptoKit
import Darwin
import Foundation

/// Deliberately small ZIP32 reader for the deterministic AuraFace distribution.
/// It admits the complete central directory before creating any extracted file and
/// accepts only the three signed, stored, UTF-8 regular-file entries.
nonisolated final class AuraFaceZIPArchive {
    private struct Entry {
        let relativePath: String
        let name: Data
        let crc32: UInt32
        let size: Int
        let localOffset: Int
        var dataOffset = 0
    }

    private var fd: Int32
    private let originalIdentity: stat
    private let entries: [Entry]

    deinit {
        if fd >= 0 { close(fd) }
    }

    init(url: URL, descriptor: AuraFaceDistributionDescriptor? = nil) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AuraFaceComponentError.unsafeArchive }
        var shouldClose = true
        defer { if shouldClose { close(fd) } }
        var identity = stat()
        guard fstat(fd, &identity) == 0, identity.st_mode & S_IFMT == S_IFREG,
              identity.st_nlink == 1, identity.st_size > 0,
              descriptor == nil || identity.st_size == descriptor?.archive.byteCount else {
            throw AuraFaceComponentError.unsafeArchive
        }
        let size = Int(identity.st_size)
        guard size >= 22, size <= Int(AuraFaceComponentStore.maximumArchiveBytes) else {
            throw AuraFaceComponentError.invalidArchive
        }
        let tailSize = min(size, 65_535 + 22)
        let tail = try Self.read(fd, offset: size - tailSize, count: tailSize)
        guard let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail.u32($0) == 0x0605_4b50 && $0 + 22 + Int(tail.u16($0 + 20)) == tail.count
        }), tail.u16(eocd + 4) == 0, tail.u16(eocd + 6) == 0,
              tail.u16(eocd + 8) == 3, tail.u16(eocd + 10) == 3,
              tail.u16(eocd + 20) == 0 else { throw AuraFaceComponentError.invalidArchive }
        let centralSize = Int(tail.u32(eocd + 12)), centralOffset = Int(tail.u32(eocd + 16))
        let eocdOffset = size - tailSize + eocd
        guard centralSize <= 16_384, centralOffset >= 0,
              centralSize == eocdOffset - centralOffset else { throw AuraFaceComponentError.invalidArchive }
        let central = try Self.read(fd, offset: centralOffset, count: centralSize)
        var parsed: [Entry] = [], cursor = 0, collisionKeys: Set<String> = []
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard cursor <= central.count - 46, central.u32(cursor) == 0x0201_4b50 else {
                throw AuraFaceComponentError.invalidArchive
            }
            let versionMadeBy = central.u16(cursor + 4), flags = central.u16(cursor + 8)
            let method = central.u16(cursor + 10), crc = central.u32(cursor + 16)
            let compressed = central.u32(cursor + 20), uncompressed = central.u32(cursor + 24)
            let nameLength = Int(central.u16(cursor + 28)), extraLength = Int(central.u16(cursor + 30))
            let commentLength = Int(central.u16(cursor + 32)), disk = central.u16(cursor + 34)
            let external = central.u32(cursor + 38), localOffset = central.u32(cursor + 42)
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, nameLength <= 1_024, cursor <= central.count - recordLength,
                  flags == 0x0800, method == 0, disk == 0, extraLength == 0, commentLength == 0,
                  compressed == uncompressed, compressed > 0,
                  localOffset != UInt32.max, uncompressed != UInt32.max else {
                throw AuraFaceComponentError.invalidArchive
            }
            let host = UInt8(truncatingIfNeeded: versionMadeBy >> 8)
            let fileType = mode_t(external >> 16) & mode_t(S_IFMT)
            guard external & 0x10 == 0,
                  (host == 3 || host == 19 ? fileType == S_IFREG : fileType == 0 || fileType == S_IFREG) else {
                throw AuraFaceComponentError.unsafeArchive
            }
            let name = central.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard let path = String(data: name, encoding: .utf8),
                  path.hasPrefix(AuraFaceComponentStore.packageDirectory + "/") else {
                throw AuraFaceComponentError.unsafeArchive
            }
            let relative = String(path.dropFirst(AuraFaceComponentStore.packageDirectory.count + 1))
            try Self.validate(relative)
            let collision = relative.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard collisionKeys.insert(collision).inserted,
                  Int64(uncompressed) <= AuraFaceComponentStore.maximumPackageFileBytes else {
                throw AuraFaceComponentError.packageFileSetMismatch
            }
            if let descriptor {
                guard let declaration = descriptor.packageFiles[relative], declaration.byteCount == Int64(uncompressed) else {
                    throw AuraFaceComponentError.packageFileSetMismatch
                }
            }
            parsed.append(.init(relativePath: relative, name: name, crc32: crc,
                                size: Int(uncompressed), localOffset: Int(localOffset)))
            cursor += recordLength
        }
        guard cursor == central.count, Set(parsed.map(\.relativePath)) == AuraFaceComponentStore.expectedPackageFiles else {
            throw AuraFaceComponentError.packageFileSetMismatch
        }
        for index in parsed.indices {
            let entry = parsed[index]
            guard entry.localOffset >= 0, entry.localOffset <= centralOffset - 30 else {
                throw AuraFaceComponentError.invalidArchive
            }
            let local = try Self.read(fd, offset: entry.localOffset, count: 30)
            guard local.u32(0) == 0x0403_4b50, local.u16(6) == 0x0800, local.u16(8) == 0,
                  local.u32(14) == entry.crc32, local.u32(18) == UInt32(entry.size),
                  local.u32(22) == UInt32(entry.size), Int(local.u16(26)) == entry.name.count,
                  local.u16(28) == 0 else { throw AuraFaceComponentError.invalidArchive }
            let localName = try Self.read(fd, offset: entry.localOffset + 30, count: entry.name.count)
            guard localName == entry.name else { throw AuraFaceComponentError.invalidArchive }
            parsed[index].dataOffset = entry.localOffset + 30 + entry.name.count
        }
        let ordered = parsed.sorted { $0.localOffset < $1.localOffset }
        var next = 0
        for entry in ordered {
            guard entry.localOffset == next else { throw AuraFaceComponentError.invalidArchive }
            next = entry.dataOffset + entry.size
        }
        guard next == centralOffset else { throw AuraFaceComponentError.invalidArchive }
        self.fd = fd
        self.originalIdentity = identity
        self.entries = parsed
        shouldClose = false
    }

    func extract(to destination: URL, descriptor: AuraFaceDistributionDescriptor? = nil) throws {
        defer { close(fd); fd = -1 }
        guard mkdir(destination.path, S_IRWXU) == 0 else { throw AuraFaceComponentError.unsafeArchive }
        let root = open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw AuraFaceComponentError.unsafeArchive }
        defer { close(root) }
        guard mkdirat(root, AuraFaceComponentStore.packageDirectory, S_IRWXU) == 0 else {
            throw AuraFaceComponentError.unsafeArchive
        }
        let package = openat(root, AuraFaceComponentStore.packageDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard package >= 0 else { throw AuraFaceComponentError.unsafeArchive }
        defer { close(package) }
        for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            try Task.checkCancellation()
            let components = entry.relativePath.split(separator: "/").map(String.init)
            var parent = dup(package)
            guard parent >= 0 else { throw AuraFaceComponentError.io }
            defer { close(parent) }
            for component in components.dropLast() {
                if mkdirat(parent, component, S_IRWXU) != 0, errno != EEXIST { throw AuraFaceComponentError.io }
                let child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw AuraFaceComponentError.unsafeArchive }
                close(parent); parent = child
            }
            let name = components[components.count - 1]
            let output = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard output >= 0 else { throw AuraFaceComponentError.io }
            var succeeded = false
            defer { close(output); if !succeeded { _ = unlinkat(parent, name, 0) } }
            var offset = 0, crc: UInt32 = 0xffff_ffff
            var hasher = SHA256()
            while offset < entry.size {
                try Task.checkCancellation()
                let amount = min(65_536, entry.size - offset)
                let bytes = try Self.read(fd, offset: entry.dataOffset + offset, count: amount)
                hasher.update(data: bytes)
                crc = Self.updateCRC(crc, bytes)
                try bytes.withUnsafeBytes { buffer in
                    var written = 0
                    while written < buffer.count {
                        let count = Darwin.write(output, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw AuraFaceComponentError.io }
                        written += count
                    }
                }
                offset += amount
            }
            let digest = Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
            guard crc ^ 0xffff_ffff == entry.crc32 else { throw AuraFaceComponentError.invalidArchive }
            if let descriptor {
                guard let declaration = descriptor.packageFiles[entry.relativePath], digest == declaration.sha256 else {
                    throw AuraFaceComponentError.packageHashMismatch(entry.relativePath)
                }
            }
            guard fsync(output) == 0, fsync(parent) == 0 else { throw AuraFaceComponentError.io }
            succeeded = true
        }
        var after = stat()
        guard fstat(fd, &after) == 0, Self.sameFile(originalIdentity, after) else {
            throw AuraFaceComponentError.unsafeArchive
        }
    }

    private static func validate(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"), !path.contains("\\"),
              !path.contains("\0"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              AuraFaceComponentStore.expectedPackageFiles.contains(path) else {
            throw AuraFaceComponentError.unsafeArchive
        }
    }

    private static func read(_ fd: Int32, offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else { throw AuraFaceComponentError.invalidArchive }
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { buffer in
            var consumed = 0
            while consumed < count {
                try Task.checkCancellation()
                let amount = pread(fd, buffer.baseAddress!.advanced(by: consumed),
                                   min(65_536, count - consumed), off_t(offset + consumed))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw AuraFaceComponentError.io }
                consumed += amount
            }
        }
        return result
    }

    private static func updateCRC(_ initial: UInt32, _ data: Data) -> UInt32 {
        var value = initial
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 }
        }
        return value
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
            lhs.st_nlink == 1 && rhs.st_nlink == 1 &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

nonisolated private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 |
            UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
