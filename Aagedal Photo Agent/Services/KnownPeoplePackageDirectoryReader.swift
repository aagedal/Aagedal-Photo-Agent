import CryptoKit
import Darwin
import Foundation
import ImageIO

/// An admitted immutable byte snapshot. Projection never replaces the original editor JSON,
/// whose whitespace, optional fields and fractional dates must survive future re-export.
nonisolated struct KnownPeoplePackageSnapshot: Sendable {
    let sourceDirectoryURL: URL
    let sourceDevice: Int32
    let sourceInode: UInt64
    let manifest: KnownPeoplePackageManifest
    let payload: KnownPeoplePackagePayload
    let editor: KnownPeoplePackageEditorPayload?
    let files: [String: Data]
    let people: [KnownPerson]
}

/// Directory-level interoperability only: no extraction, managed-store mutation or publication.
/// Filesystem work is actor-owned; callers await admission rather than reading on MainActor.
actor KnownPeoplePackageDirectoryReader {
    enum Failure: Error, Equatable {
        case invalidDirectory, unsafeFile, io, unexpectedFiles, sizeLimit
        case hashMismatch, invalidThumbnail, changedDuringRead
    }

    func read(directoryURL: URL) throws -> KnownPeoplePackageSnapshot {
        try Task.checkCancellation()
        guard directoryURL.isFileURL else { throw Failure.invalidDirectory }
        let root = try Self.openDirectory(directoryURL.path)
        defer { close(root) }
        return try readOpenedDirectory(root, sourceURL: directoryURL.resolvingSymlinksInPath().standardizedFileURL,
                                       verifySourcePath: true)
    }

    /// Reads through a descriptor retained by a transaction. Renames do not change what is
    /// admitted, so this form intentionally does not claim that a caller-provided path is stable.
    func read(heldDirectoryDescriptor descriptor: Int32, sourceURL: URL) throws -> KnownPeoplePackageSnapshot {
        try Task.checkCancellation()
        guard sourceURL.isFileURL else { throw Failure.invalidDirectory }
        let root = dup(descriptor)
        guard root >= 0 else { throw Failure.io }
        defer { close(root) }
        return try readOpenedDirectory(root, sourceURL: sourceURL, verifySourcePath: false)
    }

    private func readOpenedDirectory(_ root: Int32, sourceURL: URL,
                                     verifySourcePath: Bool) throws -> KnownPeoplePackageSnapshot {
        var sourceInfo = stat()
        guard fstat(root, &sourceInfo) == 0 else { throw Failure.io }
        let limits = KnownPeoplePackageManifest.Limits()
        let manifestBytes = try Self.readFile(root, path: "manifest.json", maximum: limits.maximumManifestBytes)
        let manifest = try KnownPeoplePackageManifest.decode(manifestBytes)
        let expected = Set(manifest.files.map(\.path)).union(["manifest.json"])
        guard try Self.enumerate(root, maximum: limits.maximumFiles + 1) == expected else {
            throw Failure.unexpectedFiles
        }
        var files = ["manifest.json": manifestBytes]
        for file in manifest.files {
            try Task.checkCancellation()
            let data = try Self.readFile(root, path: file.path, maximum: file.byteCount)
            guard data.count == file.byteCount, Self.hash(data) == file.sha256 else { throw Failure.hashMismatch }
            if file.path.hasSuffix(".fem2") { _ = try FaceEmbeddingInterchangeCodec.validate(data) }
            if file.path.hasSuffix(".jpg") { try Self.validateThumbnail(data) }
            files[file.path] = data
        }
        guard let peopleBytes = files["people.json"] else { throw Failure.unexpectedFiles }
        let payload = try KnownPeoplePackagePayload.decode(peopleBytes)
        try manifest.validate(payload: payload)
        let editor: KnownPeoplePackageEditorPayload?
        if let descriptor = manifest.editorPayload {
            guard let data = files[descriptor.path] else { throw Failure.unexpectedFiles }
            editor = try KnownPeoplePackageEditorPayload.decode(data, manifest: manifest, payload: payload)
        } else {
            editor = nil
        }
        // Recognition-only snapshots have no editor dates. Use the explicit export date,
        // never wall-clock time, and preserve absent editor metadata as absent in the snapshot.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let exportedAt = formatter.date(from: manifest.exportedAt) else { throw Failure.io }
        let contract = manifest.contract
        let provenance = FaceEmbeddingProvenance(embeddingSpaceVersion: contract.embeddingSpaceVersion,
            componentID: contract.componentID, modelID: contract.modelID,
            preprocessingRevision: contract.preprocessingRevision, vectorEncoding: contract.vectorEncoding,
            dimension: contract.dimension, l2Normalized: contract.l2Normalized)
        let people = try payload.people.map { person in
            let detail = editor?.people[person.id.uuidString.lowercased()]
            let embeddings = try person.examples.map { example in
                guard let data = files[example.embeddingPath] else { throw Failure.unexpectedFiles }
                let metadata = editor?.examples[example.id.uuidString.lowercased()]
                let mode: FaceRecognitionMode?
                switch metadata?.recognitionMode {
                case .vision: mode = .visionFeaturePrint
                case .faceClothing: mode = .faceAndClothing
                case nil: mode = nil
                }
                return PersonEmbedding(id: example.id, featurePrintData: data,
                    sourceDescription: metadata?.sourceDescription,
                    addedAt: metadata.map { Date(timeIntervalSinceReferenceDate: $0.addedAt) } ?? exportedAt,
                    recognitionMode: mode, provenance: provenance)
            }
            return KnownPerson(id: person.id, name: person.name, role: detail?.role, notes: detail?.notes,
                embeddings: embeddings, representativeThumbnailID: detail?.representativeThumbnailID,
                createdAt: detail.map { Date(timeIntervalSinceReferenceDate: $0.createdAt) } ?? exportedAt,
                updatedAt: detail.map { Date(timeIntervalSinceReferenceDate: $0.updatedAt) } ?? exportedAt)
        }
        _ = try KnownPeopleInterchangeEligibility.validate(people: people)
        // Recheck against the same immutable declarations. This is observed-byte validation,
        // not a claim of a transaction with arbitrary external writers.
        for (path, data) in files {
            try Task.checkCancellation()
            guard try Self.readFile(root, path: path, maximum: data.count) == data else {
                throw Failure.changedDuringRead
            }
        }
        guard try Self.enumerate(root, maximum: limits.maximumFiles + 1) == expected else {
            throw Failure.changedDuringRead
        }
        if verifySourcePath {
            var currentSource = stat()
            guard lstat(sourceURL.path, &currentSource) == 0, currentSource.st_mode & S_IFMT == S_IFDIR,
                  sourceInfo.st_dev == currentSource.st_dev, sourceInfo.st_ino == currentSource.st_ino else {
                throw Failure.changedDuringRead
            }
        }
        return KnownPeoplePackageSnapshot(sourceDirectoryURL: sourceURL,
            sourceDevice: sourceInfo.st_dev, sourceInode: sourceInfo.st_ino, manifest: manifest, payload: payload,
            editor: editor, files: files, people: people)
    }

    nonisolated private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated private static func openDirectory(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.invalidDirectory }
        return fd
    }
    nonisolated private static func openChildDirectory(_ parent: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.invalidDirectory }
        return fd
    }
    nonisolated private static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw Failure.unsafeFile }
        return parts
    }
    nonisolated private static func readFile(_ parent: Int32, path: String, maximum: Int) throws -> Data {
        let parts = try components(path)
        let directory = parts.count == 2 ? try openChildDirectory(parent, parts[0]) : dup(parent)
        guard directory >= 0 else { throw Failure.io }
        defer { close(directory) }
        let fd = openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unsafeFile }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= maximum else { throw Failure.unsafeFile }
        var bytes = Data(count: Int(before.st_size))
        let expected = bytes.count
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < expected {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), expected - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }
                offset += count
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, after.st_nlink == 1,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure.unsafeFile }
        return bytes
    }
    nonisolated private static func enumerate(_ fd: Int32, maximum: Int, prefix: String = "") throws -> Set<String> {
        let copy = dup(fd)
        guard copy >= 0 else { throw Failure.io }
        guard let stream = fdopendir(copy) else { close(copy); throw Failure.io }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: Set<String> = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw Failure.unsafeFile }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.io }
            if info.st_mode & S_IFMT == S_IFDIR {
                guard prefix.isEmpty, ["embeddings", "thumbnails", "embedding_thumbnails", "editor"].contains(name) else { throw Failure.unexpectedFiles }
                let child = try openChildDirectory(fd, name)
                defer { close(child) }
                let nested = try enumerate(child, maximum: maximum - result.count, prefix: name + "/")
                guard !nested.isEmpty else { throw Failure.unexpectedFiles }
                result.formUnion(nested)
            } else {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure.unsafeFile }
                result.insert(prefix + name)
            }
            guard result.count <= maximum else { throw Failure.sizeLimit }
        }
        return result
    }
    nonisolated private static func validateThumbnail(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 16_777_216,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) != nil else { throw Failure.invalidThumbnail }
    }
}
