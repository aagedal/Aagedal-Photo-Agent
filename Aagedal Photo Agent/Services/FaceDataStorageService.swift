import CryptoKit
import Foundation
import os.log

nonisolated private let faceDataLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent", category: "FaceDataStorageService")

/// The explicit deletion intent is applied to the latest reserved disk snapshot.
nonisolated enum FaceDataDeletionSelection: Sendable {
    case photos(Set<URL>)
    case faces(Set<UUID>)
}

nonisolated struct FaceDataStorageService: Sendable {

    static let faceDataDirectoryName = ".face_data"
    static let dataFileName = "face_data.json"
    private static let thumbnailsDirectoryName = "thumbnails"

    // MARK: - Directory Helpers

    private func faceDataDirectory(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(Self.faceDataDirectoryName)
    }

    private func dataFileURL(for folderURL: URL) -> URL {
        faceDataDirectory(for: folderURL).appendingPathComponent(Self.dataFileName)
    }

    private func thumbnailsDirectory(for folderURL: URL) -> URL {
        faceDataDirectory(for: folderURL).appendingPathComponent(Self.thumbnailsDirectoryName)
    }

    private func thumbnailURL(for faceID: UUID, folderURL: URL) -> URL {
        thumbnailsDirectory(for: folderURL).appendingPathComponent("\(faceID.uuidString).jpg")
    }

    // MARK: - Load

    func faceDataExists(for folderURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: dataFileURL(for: folderURL).path)
    }

    func loadFaceData(for folderURL: URL, relocateCorruptFile: Bool = false) -> FolderFaceData? {
        let fileURL = dataFileURL(for: folderURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            let faceData = try JSONDecoder().decode(FolderFaceData.self, from: data)
            return faceData
        } catch {
            faceDataLog.error("Failed to decode face data at \(fileURL.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            guard relocateCorruptFile else { return nil }
            // Only a caller holding the folder reservation may relocate corrupt data.
            // Move corrupt file aside so it doesn't block future loads
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(Self.dataFileName).corrupt.\(timestamp)")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backupURL)
                faceDataLog.error("Moved corrupt face data to \(backupURL.lastPathComponent, privacy: .private(mask: .hash))")
            } catch {
                faceDataLog.error("Failed to move corrupt face data aside: \(error.localizedDescription, privacy: .private)")
            }
            return nil
        }
    }

    func loadThumbnail(for faceID: UUID, folderURL: URL) -> Data? {
        let url = thumbnailURL(for: faceID, folderURL: folderURL)
        do {
            return try Data(contentsOf: url)
        } catch {
            faceDataLog.warning("Failed to load thumbnail for face \(faceID.uuidString, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    // MARK: - Save

    func saveFaceData(_ faceData: FolderFaceData,
                      effectAuthority: FaceDataFolderLoadService.EffectAuthority? = nil) throws {
        let dir = faceDataDirectory(for: faceData.folderURL)
        let thumbDir = thumbnailsDirectory(for: faceData.folderURL)

        try effectAuthority?(faceData.folderURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try effectAuthority?(faceData.folderURL)
        try FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(faceData)
        try effectAuthority?(faceData.folderURL)
        try data.write(to: dataFileURL(for: faceData.folderURL), options: .atomic)
    }

    func saveThumbnail(_ jpegData: Data, for faceID: UUID, folderURL: URL,
                       effectAuthority: FaceDataFolderLoadService.EffectAuthority? = nil) throws {
        let thumbDir = thumbnailsDirectory(for: folderURL)
        try effectAuthority?(folderURL)
        try FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        try effectAuthority?(folderURL)
        try jpegData.write(to: thumbnailURL(for: faceID, folderURL: folderURL), options: .atomic)
    }

    // MARK: - Delete

    func deleteThumbnail(for faceID: UUID, folderURL: URL) throws {
        let url = thumbnailURL(for: faceID, folderURL: folderURL)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // File already gone — not an error
        } catch {
            faceDataLog.warning("Failed to delete thumbnail for face \(faceID.uuidString, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    func deleteFaceData(for folderURL: URL) throws {
        let dir = faceDataDirectory(for: folderURL)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Cleanup

    func shouldCleanup(faceData: FolderFaceData, policy: FaceCleanupPolicy) -> Bool {
        guard let maxAge = policy.timeInterval else { return false }
        return Date().timeIntervalSince(faceData.lastScanDate) > maxAge
    }

    func applyCleanupIfNeeded(for folderURL: URL, policy: FaceCleanupPolicy) throws {
        guard let faceData = loadFaceData(for: folderURL) else { return }
        if shouldCleanup(faceData: faceData, policy: policy) {
            try deleteFaceData(for: folderURL)
        }
    }
}

/// Immutable folder state returned after every face-data and thumbnail read has finished on the
/// serialized filesystem actor. Thumbnail bytes deliberately cross the actor boundary instead of
/// `NSImage`; AppKit image objects remain owned by the main-actor view model.
nonisolated struct FaceDataFolderLoadEvidence: @unchecked Sendable {
    enum CleanupDisposition: Sendable, Equatable {
        case notRequested
        case retained
        case deletionFailed(String)
        case deleted(cancellationRequestedAfterCommit: Bool)
    }

    let folderURL: URL
    let faceData: FolderFaceData?
    let thumbnailData: [UUID: Data]
    let requestedThumbnailCount: Int
    let processedThumbnailCount: Int
    let cleanupDisposition: CleanupDisposition

    /// A historical completion flag is qualified by every retained face's current crop read.
    /// This changes presentation only; durable repair remains an explicitly requested scan.
    var scanCompleteWithThumbnails: Bool {
        guard let faceData, faceData.scanComplete else { return false }
        return faceData.faces.allSatisfy { thumbnailData[$0.id] != nil }
    }
}

/// A cancelled folder load retains its exact thumbnail prefix for diagnostics, but callers must
/// not publish it as a complete folder snapshot.
nonisolated struct CancelledFaceDataFolderLoadEvidence: Sendable, Equatable {
    let folderURL: URL
    let requestedThumbnailCount: Int
    let processedThumbnailCount: Int
}

nonisolated enum FaceDataFolderLoadResult: @unchecked Sendable {
    case complete(FaceDataFolderLoadEvidence)
    case cancelled(CancelledFaceDataFolderLoadEvidence)
}

nonisolated struct FaceDataDocumentLoadEvidence: Sendable {
    let folderURL: URL
    let documentExisted: Bool
    let faceData: FolderFaceData?
}

nonisolated enum FaceDataDocumentLoadResult: Sendable {
    case complete(FaceDataDocumentLoadEvidence)
    case cancelled(folderURL: URL)
}

nonisolated enum FaceThumbnailLoadResult: Sendable {
    case complete(Data?)
    case cancelled
}

/// Durable evidence for one face-data document commit and its optional orphan-thumbnail cleanup.
/// The document is installed first, so cancellation or a cleanup failure can leave only harmless
/// unreferenced thumbnails rather than a document that points at thumbnails already removed.
nonisolated struct FaceDataPersistenceEvidence: Sendable, Equatable {
    struct ThumbnailFailure: Sendable, Equatable {
        let faceID: UUID
        let message: String
    }

    let folderURL: URL
    let documentCommitted: Bool
    let requestedThumbnailDeletionCount: Int
    let deletedThumbnailIDs: [UUID]
    let thumbnailFailures: [ThumbnailFailure]
    let cancellationRequestedAfterCommit: Bool
    var authorityFailure: String? = nil
}

nonisolated enum FaceDataPersistenceResult: Sendable, Equatable {
    case committed(FaceDataPersistenceEvidence)
    case cancelledBeforeCommit(folderURL: URL)
    case failedBeforeCommit(folderURL: URL, message: String)

    var failureMessage: String? {
        switch self {
        case .failedBeforeCommit(_, let message):
            message
        case .committed(let evidence):
            evidence.authorityFailure ?? evidence.thumbnailFailures.first?.message
        case .cancelledBeforeCommit:
            nil
        }
    }
}

nonisolated enum FaceThumbnailPersistenceResult: Sendable, Equatable {
    case committed(faceID: UUID, cancellationRequestedAfterCommit: Bool)
    case committedButUnverified(faceID: UUID, message: String, cancellationRequestedAfterCommit: Bool)
    case cancelledBeforeCommit(faceID: UUID)
    case failed(faceID: UUID, message: String)
}

/// Exact physical removal prefix, retained even when verification or authority fails.
nonisolated struct FaceDataResetEvidence: Sendable, Equatable {
    let folderURL: URL
    let removedRelativePaths: [String]
    let completed: Bool
    let failureMessage: String?
    let cancellationRequested: Bool
}

nonisolated enum FaceDataDeletionResult: Sendable, Equatable {
    case anchored(FaceDataResetEvidence)
    case committed(folderURL: URL, cancellationRequestedAfterCommit: Bool)
    case committedButUnverified(folderURL: URL, message: String, cancellationRequestedAfterCommit: Bool)
    case cancelledBeforeCommit(folderURL: URL)
    case failed(folderURL: URL, message: String)

    var deletionCompleted: Bool {
        switch self {
        case .committed: return true
        case .anchored(let evidence): return evidence.completed
        default: return false
        }
    }

    var failureMessage: String? {
        switch self {
        case .anchored(let evidence): return evidence.failureMessage
        case .failed(_, let message), .committedButUnverified(_, let message, _): return message
        default: return nil
        }
    }
}

/// Immutable file-identity evidence used to decide which photos need another face scan.
nonisolated struct FaceScanFileClassification: Sendable, Equatable {
    let imageURLsToScan: [URL]
    let removedOrModifiedPaths: Set<String>
    let unchangedPaths: Set<String>
    /// Unchanged files whose stored signature must be replaced: a metadata-only write moved the
    /// date/size while the content fingerprint still matches, or a legacy signature gained one.
    var refreshedSignatures: [String: FileSignature] = [:]
}

/// Metadata-independent identity of a photo's image content, so a metadata-only write (ours,
/// Photo Mechanic's, …) does not discard faces detected in unchanged pixels.
///
/// JPEG only: SHA-256 over every non-metadata segment before the first scan (frame, tables),
/// the byte length of the entropy-coded region, three 64 KB samples of it (start, middle, end)
/// and the EXIF orientation. APPn/COM segments — where EXIF, XMP, IPTC and ICC live — are
/// excluded (only the EXIF orientation is read from APP1). A pixel edit re-encodes the scan data
/// (changing its length and samples) and a rotation changes the orientation, so either still
/// forces a rescan.
///
/// Reads go through a `FileHandle` with bounded, explicit reads (never memory mapping), so a file
/// truncated or a network volume dropped mid-read yields "no fingerprint" instead of SIGBUS.
nonisolated enum FaceScanContentFingerprint {
    static let sampleSize = 64 * 1024
    /// Headers (all segments before the first scan) larger than this are not fingerprinted.
    static let maximumHeaderBytes: UInt64 = 16 * 1024 * 1024
    static let maximumSegments = 4096

    static func compute(for url: URL) -> String? {
        guard ["jpg", "jpeg", "jpe"].contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let fileSize = try handle.seekToEnd()
            /// Exactly `count` bytes at `offset`, or nil (short read: truncated or changed file).
            func read(_ offset: UInt64, _ count: Int) throws -> Data? {
                guard count >= 0, offset + UInt64(count) <= fileSize else { return nil }
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: count) ?? Data()
                return data.count == count ? data : nil
            }
            return try compute(fileSize: fileSize, read: read)
        } catch {
            return nil
        }
    }

    private static func compute(fileSize: UInt64, read: (UInt64, Int) throws -> Data?) throws -> String? {
        guard fileSize > 4, let soi = try read(0, 2), soi[soi.startIndex] == 0xFF,
              soi[soi.startIndex + 1] == 0xD8 else { return nil }
        var hasher = SHA256()
        var offset: UInt64 = 2
        var sawFrame = false
        var orientation: Int?
        var segments = 0
        while offset + 4 <= fileSize, offset <= maximumHeaderBytes, segments < maximumSegments {
            segments += 1
            guard let head = try read(offset, 2) else { return nil }
            guard head[head.startIndex] == 0xFF else { return nil }
            let marker = head[head.startIndex + 1]
            if marker == 0xFF { offset += 1; continue }
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { offset += 2; continue }
            guard marker != 0xD9, let lengthBytes = try read(offset + 2, 2) else { return nil }
            let length = Int(lengthBytes[lengthBytes.startIndex]) << 8 | Int(lengthBytes[lengthBytes.startIndex + 1])
            let segmentEnd = offset + 2 + UInt64(length)
            guard length >= 2, segmentEnd <= fileSize else { return nil }
            if marker == 0xDA {
                guard sawFrame else { return nil }
                let scanLength = fileSize - offset
                withUnsafeBytes(of: scanLength.bigEndian) { hasher.update(bufferPointer: $0) }
                let sampleLength = Int(min(UInt64(sampleSize), scanLength))
                let middle = offset + (scanLength - UInt64(sampleLength)) / 2
                for start in [offset, middle, fileSize - UInt64(sampleLength)] {
                    guard let sample = try read(start, sampleLength) else { return nil }
                    hasher.update(data: sample)
                }
                withUnsafeBytes(of: Int64(orientation ?? 1).bigEndian) { hasher.update(bufferPointer: $0) }
                return "jpeg-v2:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
            if marker == 0xE1, orientation == nil, length > 8 {
                // APP1: only the EXIF orientation matters (it changes the face geometry).
                if let payload = try read(offset + 4, length - 2) { orientation = exifOrientation(payload) }
            }
            let isMetadata = (0xE0...0xEF).contains(marker) || marker == 0xFE
            if !isMetadata {
                if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) { sawFrame = true }
                guard let segment = try read(offset, 2 + length) else { return nil }
                hasher.update(data: segment)
            }
            offset = segmentEnd
        }
        return nil
    }

    /// IFD0 tag 0x0112 from an APP1 "Exif\0\0" payload; nil when absent or malformed.
    static func exifOrientation(_ payload: Data) -> Int? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 14, Array(bytes[0..<6]) == [0x45, 0x78, 0x69, 0x66, 0, 0] else { return nil }
        let tiff = Array(bytes[6...])
        let littleEndian: Bool
        switch (tiff[0], tiff[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: return nil
        }
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= tiff.count else { return nil }
            return littleEndian ? Int(tiff[at]) | Int(tiff[at + 1]) << 8 : Int(tiff[at]) << 8 | Int(tiff[at + 1])
        }
        func u32(_ at: Int) -> Int? {
            guard let high = u16(littleEndian ? at + 2 : at), let low = u16(littleEndian ? at : at + 2) else { return nil }
            return high << 16 | low
        }
        guard let ifd = u32(4), let count = u16(ifd), count < 1000 else { return nil }
        for index in 0..<count {
            let entry = ifd + 2 + index * 12
            guard let tag = u16(entry) else { return nil }
            if tag == 0x0112 { return u16(entry + 8) }
        }
        return nil
    }
}

/// Classification stops at a precise URL boundary when cancellation is observed. Callers must
/// not install a partial classification because it could incorrectly discard existing faces.
nonisolated enum FaceScanFileClassificationResult: Sendable, Equatable {
    case complete(FaceScanFileClassification)
    case cancelled(processedFileCount: Int, requestedFileCount: Int)
}

/// A signature read is non-preemptible once Foundation enters the filesystem. Cancellation
/// therefore records whether the read completed instead of publishing its value as current.
nonisolated enum FaceScanFileSignatureResult: Sendable, Equatable {
    case captured(imageURL: URL, signature: FileSignature?)
    case cancelled(imageURL: URL, readCompleted: Bool)
}

/// Serializes incremental face-scan file identity reads away from the app's default MainActor.
/// The same actor owns the initial classification transaction and the per-image signature reads
/// performed after detection, so neither path can overlap a slow volume probe.
actor FaceScanFileSignatureService {
    /// Run blocking Foundation calls on a retained Dispatch worker while preserving the
    /// caller's task locals, cancellation, and the actor's transaction ordering.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    static let shared = FaceScanFileSignatureService()

    typealias SignatureReader = @Sendable (URL) -> FileSignature?
    typealias FingerprintReader = @Sendable (URL) -> String?

    private let readSignature: SignatureReader
    private let readFingerprint: FingerprintReader

    init(
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.face-scan-signatures", qos: .utility
        ),
        readSignature: @escaping SignatureReader = { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modificationDate = attrs[.modificationDate] as? Date else {
                return nil
            }
            let fileSize: Int64?
            if let value = attrs[.size] as? NSNumber {
                fileSize = value.int64Value
            } else {
                fileSize = attrs[.size] as? Int64
            }
            guard let fileSize else { return nil }
            return FileSignature(modificationDate: modificationDate, fileSize: fileSize)
        },
        readFingerprint: @escaping FingerprintReader = { FaceScanContentFingerprint.compute(for: $0) }
    ) {
        self.filesystemQueue = filesystemQueue
        self.readSignature = readSignature
        self.readFingerprint = readFingerprint
    }

    /// Run under the caller's folder reservation before reading/resetting saved face data.
    /// The lease coordinates app/helper writers; it does not freeze external filesystem edits.
    func validateCompleteInventory(_ request: FaceFolderScanRequest) -> FaceFolderScanRefusal? {
        let folder = request.folderURL.resolvingSymlinksInPath().standardizedFileURL
        guard request.folderURL.isFileURL else { return .invalidInventory("the folder must be local") }
        var requestedPaths: Set<String> = []
        for image in request.imageURLs {
            let canonical = image.standardizedFileURL.resolvingSymlinksInPath()
            guard image.isFileURL, canonical.deletingLastPathComponent() == folder,
                  SupportedImageFormats.isSupported(url: image), !image.lastPathComponent.hasPrefix(".") else {
                return .invalidInventory("an item is not a supported immediate folder image")
            }
            guard requestedPaths.insert(canonical.path).inserted else {
                return .invalidInventory("duplicate image URLs")
            }
        }
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: request.folderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                    .ubiquitousItemDownloadingStatusKey], options: [])
            var inventoryPaths: Set<String> = []
            for image in contents {
                let name = image.lastPathComponent
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    let logicalName = String(name.dropFirst().dropLast(".icloud".count))
                    if SupportedImageFormats.isSupported(url: request.folderURL.appendingPathComponent(logicalName)) {
                        return .invalidInventory("an image is not downloaded locally")
                    }
                }
                guard !name.hasPrefix("."), SupportedImageFormats.isSupported(url: image) else { continue }
                let values = try image.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                    .ubiquitousItemDownloadingStatusKey])
                guard values.isSymbolicLink != true else {
                    return .invalidInventory("symbolic-link images require a separate scan scope")
                }
                guard values.isRegularFile == true else { continue }
                if let status = values.ubiquitousItemDownloadingStatus,
                   status != .current && status != .downloaded {
                    return .invalidInventory("an image is not downloaded locally")
                }
                inventoryPaths.insert(image.standardizedFileURL.resolvingSymlinksInPath().path)
            }
            guard requestedPaths == inventoryPaths else {
                return .invalidInventory("the image list differs from the folder contents; refresh and retry")
            }
            return nil
        } catch {
            return .invalidInventory(BrowserViewModel.folderLoadMessage(for: error))
        }
    }

    func classify(
        imageURLs: [URL],
        existingSignatures: [String: FileSignature]
    ) -> FaceScanFileClassificationResult {
        let currentPaths = Set(imageURLs.map(\.path))
        let existingPaths = Set(existingSignatures.keys)
        var imageURLsToScan: [URL] = []
        var unchangedPaths: Set<String> = []
        var refreshedSignatures: [String: FileSignature] = [:]
        var processedFileCount = 0

        for url in imageURLs {
            guard !Task.isCancelled else {
                return .cancelled(
                    processedFileCount: processedFileCount,
                    requestedFileCount: imageURLs.count
                )
            }
            let currentSignature = readSignature(url)
            processedFileCount += 1
            guard !Task.isCancelled else {
                return .cancelled(
                    processedFileCount: processedFileCount,
                    requestedFileCount: imageURLs.count
                )
            }

            if let existingSignature = existingSignatures[url.path], let currentSignature,
               existingSignature.hasSameFileFacts(as: currentSignature) {
                unchangedPaths.insert(url.path)
                // Backfill a legacy signature so a later metadata-only write keeps its faces.
                if existingSignature.contentFingerprint == nil, let fingerprint = readFingerprint(url) {
                    refreshedSignatures[url.path] = FileSignature(modificationDate: existingSignature.modificationDate,
                        fileSize: existingSignature.fileSize, contentFingerprint: fingerprint)
                }
            } else if let existingSignature = existingSignatures[url.path], let currentSignature,
                      existingSignature.contentFingerprint != nil,
                      case let current = FileSignature(modificationDate: currentSignature.modificationDate,
                          fileSize: currentSignature.fileSize, contentFingerprint: readFingerprint(url)),
                      FileSignature.storedFacesAreCurrent(stored: existingSignature, current: current) {
                // Metadata-only change: same pixels and orientation, new date/size.
                unchangedPaths.insert(url.path)
                refreshedSignatures[url.path] = current
            } else {
                imageURLsToScan.append(url)
            }
        }

        let removedOrModifiedPaths = existingPaths.subtracting(currentPaths).union(
            Set(imageURLsToScan.map(\.path)).intersection(existingPaths)
        )
        return .complete(FaceScanFileClassification(
            imageURLsToScan: imageURLsToScan,
            removedOrModifiedPaths: removedOrModifiedPaths,
            unchangedPaths: unchangedPaths,
            refreshedSignatures: refreshedSignatures
        ))
    }

    func signature(for imageURL: URL) -> FaceScanFileSignatureResult {
        guard !Task.isCancelled else {
            return .cancelled(imageURL: imageURL, readCompleted: false)
        }
        var signature = readSignature(imageURL)
        if signature != nil { signature?.contentFingerprint = readFingerprint(imageURL) }
        guard !Task.isCancelled else {
            return .cancelled(imageURL: imageURL, readCompleted: true)
        }
        return .captured(imageURL: imageURL, signature: signature)
    }

    /// Date/size only (no content read) for cheap before/after comparisons around our own writes.
    func fileFacts(for imageURL: URL) -> FileSignature? {
        readSignature(imageURL)
    }
}

/// Serializes folder-navigation reads, scan writes, interactive mutation commits, thumbnail
/// cleanup, and whole-folder deletion away from the app's default MainActor.
///
/// Foundation reads cannot be interrupted once entered, so cancellation is sampled before and
/// after the document read and every thumbnail read. Expiration cleanup is a durable mutation:
/// cancellation observed after deletion is recorded in complete evidence rather than pretending
/// the deleted data still exists.
actor FaceDataFolderLoadService {
    /// Run blocking Foundation calls on a retained Dispatch worker while preserving the
    /// caller's task locals, cancellation, and the actor's transaction ordering.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    static let shared = FaceDataFolderLoadService()

    /// Synchronous full-scope validation at each publication boundary; grants no consent.
    typealias EffectAuthority = @Sendable (URL) throws -> Void

    typealias WriteCapabilityFactory = @Sendable (URL, @escaping EffectAuthority) throws -> FaceDataWriteCapability

    typealias FaceDataLoader = @Sendable (URL) -> FolderFaceData?
    typealias FaceDataExistenceChecker = @Sendable (URL) -> Bool
    typealias ThumbnailLoader = @Sendable (UUID, URL) -> Data?
    typealias FaceDataDeleter = @Sendable (URL) throws -> Void
    typealias FaceDataSaver = @Sendable (FolderFaceData) throws -> Void
    typealias ThumbnailSaver = @Sendable (Data, UUID, URL) throws -> Void
    typealias ThumbnailDeleter = @Sendable (UUID, URL) throws -> Void
    typealias CurrentDate = @Sendable () -> Date

    private let writeCapabilityFactory: WriteCapabilityFactory
    private let loadDocumentFaceData: FaceDataLoader
    private let loadFaceData: FaceDataLoader
    private let faceDataExists: FaceDataExistenceChecker
    private let loadThumbnail: ThumbnailLoader
    private let deleteFaceData: FaceDataDeleter
    private let usesDefaultFaceDataSaver: Bool
    private let usesDefaultThumbnailSaver: Bool
    private let saveFaceData: FaceDataSaver
    private let saveThumbnail: ThumbnailSaver
    private let deleteThumbnail: ThumbnailDeleter
    private let currentDate: CurrentDate

    /// Stat identity of a folder's face-data document; see `cachedDocumentFaceData`.
    private struct DocumentFileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }

        func isSettled(at now: Date) -> Bool {
            let latest = TimeInterval(max(modifiedSeconds, changedSeconds)) + 1
            return now.timeIntervalSince1970 - latest >= 2.5
        }
    }

    private struct DocumentCacheEntry {
        let identity: DocumentFileIdentity
        let faceData: FolderFaceData
    }

    private let cachesDocuments: Bool
    private var documentCache: [String: DocumentCacheEntry] = [:]
    private static let documentCacheCapacity = 8

    init(
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.face-data-storage", qos: .utility
        ),
        writeCapabilityFactory: @escaping WriteCapabilityFactory = { folder, authority in
            try FaceDataWriteCapability(folderURL: folder, effectAuthority: authority)
        },
        loadFaceData: FaceDataLoader? = nil,
        faceDataExists: @escaping FaceDataExistenceChecker = { folderURL in
            FaceDataStorageService().faceDataExists(for: folderURL)
        },
        loadThumbnail: @escaping ThumbnailLoader = { faceID, folderURL in
            FaceDataStorageService().loadThumbnail(for: faceID, folderURL: folderURL)
        },
        deleteFaceData: @escaping FaceDataDeleter = { folderURL in
            try FaceDataStorageService().deleteFaceData(for: folderURL)
        },
        saveFaceData: FaceDataSaver? = nil,
        saveThumbnail: ThumbnailSaver? = nil,
        deleteThumbnail: @escaping ThumbnailDeleter = { faceID, folderURL in
            try FaceDataStorageService().deleteThumbnail(for: faceID, folderURL: folderURL)
        },
        currentDate: @escaping CurrentDate = Date.init,
        cachesDocuments: Bool? = nil
    ) {
        self.filesystemQueue = filesystemQueue
        self.writeCapabilityFactory = writeCapabilityFactory
        self.loadDocumentFaceData = loadFaceData ?? { folderURL in
            FaceDataStorageService().loadFaceData(for: folderURL)
        }
        self.loadFaceData = loadFaceData ?? { folderURL in
            FaceDataStorageService().loadFaceData(for: folderURL, relocateCorruptFile: true)
        }
        self.faceDataExists = faceDataExists
        self.loadThumbnail = loadThumbnail
        self.deleteFaceData = deleteFaceData
        self.usesDefaultFaceDataSaver = saveFaceData == nil
        self.usesDefaultThumbnailSaver = saveThumbnail == nil
        self.saveFaceData = saveFaceData ?? { try FaceDataStorageService().saveFaceData($0) }
        self.saveThumbnail = saveThumbnail ?? { try FaceDataStorageService().saveThumbnail($0, for: $1, folderURL: $2) }
        self.deleteThumbnail = deleteThumbnail
        self.currentDate = currentDate
        // Injected loaders are uncached unless a test explicitly opts in.
        self.cachesDocuments = cachesDocuments ?? (loadFaceData == nil)
    }

    /// Bind the retained scan's write destination on the filesystem worker before any
    /// detection suspension. Browsing and corruption recovery remain read-only here.
    func prepareWriteCapability(
        folderURL: URL,
        effectAuthority: @escaping EffectAuthority
    ) throws -> FaceDataWriteCapability {
        try Task.checkCancellation()
        try effectAuthority(folderURL)
        let capability = try writeCapabilityFactory(folderURL, effectAuthority)
        try effectAuthority(folderURL)
        return capability
    }

    func loadDocument(folderURL: URL) -> FaceDataDocumentLoadResult {
        let standardizedFolderURL = folderURL.standardizedFileURL
        guard !Task.isCancelled else {
            return .cancelled(folderURL: standardizedFolderURL)
        }
        let existed = faceDataExists(folderURL)
        guard !Task.isCancelled else {
            return .cancelled(folderURL: standardizedFolderURL)
        }
        let faceData = cachedDocumentFaceData(folderURL).map { Self.rebased($0, to: folderURL).data }
        guard !Task.isCancelled else {
            return .cancelled(folderURL: standardizedFolderURL)
        }
        return .complete(FaceDataDocumentLoadEvidence(
            folderURL: standardizedFolderURL,
            documentExisted: existed,
            faceData: faceData
        ))
    }

    /// `loadDocument` runs on every Caption navigation, and a busy folder's document is over a
    /// megabyte of JSON. Reuse the decoded document while the data file's stat identity
    /// (device, inode, size, mtime, ctime) is unchanged; atomic saves replace the inode and
    /// in-place writes advance mtime/ctime, so any change on disk (including another process)
    /// misses. This actor's own mutations also drop the folder's entry. Only the production
    /// loader is cached; injected test loaders keep their per-call behavior.
    private func cachedDocumentFaceData(_ folderURL: URL) -> FolderFaceData? {
        guard cachesDocuments else { return loadDocumentFaceData(folderURL) }
        let key = folderURL.standardizedFileURL.path
        guard let before = Self.documentIdentity(folderURL) else {
            documentCache[key] = nil
            return loadDocumentFaceData(folderURL)
        }
        if let cached = documentCache[key], cached.identity == before {
            return cached.faceData
        }
        documentCache[key] = nil
        let faceData = loadDocumentFaceData(folderURL)
        // Remember only a document that did not change while it was read and whose timestamps
        // have settled (coarse-timestamp volumes could otherwise hide a same-tick rewrite).
        if let faceData, Self.documentIdentity(folderURL) == before, before.isSettled(at: currentDate()) {
            if documentCache.count >= Self.documentCacheCapacity { documentCache.removeAll(keepingCapacity: true) }
            documentCache[key] = DocumentCacheEntry(identity: before, faceData: faceData)
        }
        return faceData
    }

    /// A moved or copied folder's document still names the old location. Every read is rebased
    /// onto the folder actually requested so no edit, Apply or save can target the old folder.
    private static func rebased(_ data: FolderFaceData, to folderURL: URL) -> (data: FolderFaceData, changed: Bool) {
        var copy = data
        let changed = copy.rebase(toFolder: folderURL)
        return (copy, changed)
    }

    private func invalidateDocumentCache(_ folderURL: URL) {
        documentCache[folderURL.standardizedFileURL.path] = nil
    }

    private static func documentIdentity(_ folderURL: URL) -> DocumentFileIdentity? {
        let path = folderURL
            .appendingPathComponent(FaceDataStorageService.faceDataDirectoryName)
            .appendingPathComponent(FaceDataStorageService.dataFileName).path
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return DocumentFileIdentity(info)
    }

    func loadThumbnailData(faceID: UUID, folderURL: URL) -> FaceThumbnailLoadResult {
        guard !Task.isCancelled else { return .cancelled }
        let data = loadThumbnail(faceID, folderURL)
        return Task.isCancelled ? .cancelled : .complete(data)
    }

    /// Interactive mutations do not own the scan's long-lived lease. Admit them on this
    /// filesystem executor and retain ownership through document and thumbnail changes.
    func persistWithFolderReservation(
        _ faceData: FolderFaceData,
        deletingThumbnailIDs thumbnailIDs: [UUID] = [],
        expectedSnapshot: FolderFaceData? = nil
    ) -> FaceDataPersistenceResult {
        let folderURL = faceData.folderURL.standardizedFileURL
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(folderURL: folderURL)
        }
        do {
            let reservation = try MCPProcessReservation.acquireFolder(folderURL)
            defer { reservation.release() }
            if let expectedSnapshot {
                // Decode without recovery: corrupt, removed, or foreign-owned documents must
                // never be replaced by an older interactive whole-document snapshot.
                guard expectedSnapshot.folderURL.standardizedFileURL.path == folderURL.path,
                      let current = loadDocumentFaceData(folderURL).map({ Self.rebased($0, to: folderURL).data }),
                      current.folderURL.standardizedFileURL.path == folderURL.path else {
                    return .failedBeforeCommit(folderURL: folderURL,
                        message: "Face data changed on disk. Reload the folder and reapply the edit.")
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(current) == encoder.encode(expectedSnapshot) else {
                    return .failedBeforeCommit(folderURL: folderURL,
                        message: "Face data changed on disk. Reload the folder and reapply the edit.")
                }
            }
            return persist(faceData, deletingThumbnailIDs: thumbnailIDs)
        } catch {
            return .failedBeforeCommit(folderURL: folderURL, message: error.localizedDescription)
        }
    }

    /// The caller of this primitive must supply any enclosing operation reservation (as
    /// face scans do). Interactive callers use `persistWithFolderReservation` instead.
    func persist(
        _ faceData: FolderFaceData,
        deletingThumbnailIDs thumbnailIDs: [UUID] = [],
        effectAuthority: EffectAuthority? = nil,
        writeCapability: FaceDataWriteCapability? = nil
    ) -> FaceDataPersistenceResult {
        let folderURL = faceData.folderURL.standardizedFileURL
        invalidateDocumentCache(folderURL)
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(folderURL: folderURL)
        }

        do {
            try effectAuthority?(folderURL)
            if let writeCapability {
                // Anchored scan publication must never fall back to an injected/path saver.
                guard thumbnailIDs.isEmpty else { throw CocoaError(.featureUnsupported) }
                try writeCapability.saveFaceData(faceData)
            } else if usesDefaultFaceDataSaver {
                try FaceDataStorageService().saveFaceData(faceData, effectAuthority: effectAuthority)
            } else {
                try saveFaceData(faceData)
            }
        } catch let error as FaceDataWriteError where error.committed {
            return .committed(FaceDataPersistenceEvidence(
                folderURL: folderURL, documentCommitted: true,
                requestedThumbnailDeletionCount: thumbnailIDs.count,
                deletedThumbnailIDs: [], thumbnailFailures: [],
                cancellationRequestedAfterCommit: Task.isCancelled,
                authorityFailure: error.localizedDescription
            ))
        } catch {
            return .failedBeforeCommit(
                folderURL: folderURL,
                message: error.localizedDescription
            )
        }

        var authorityFailure: String?
        do { try effectAuthority?(folderURL) }
        catch { authorityFailure = error.localizedDescription }

        var deletedIDs: [UUID] = []
        var failures: [FaceDataPersistenceEvidence.ThumbnailFailure] = []
        for faceID in thumbnailIDs {
            guard !Task.isCancelled, authorityFailure == nil else { break }
            do {
                try effectAuthority?(folderURL)
            } catch { authorityFailure = error.localizedDescription; break }
            do {
                try deleteThumbnail(faceID, faceData.folderURL)
                deletedIDs.append(faceID)
                do { try effectAuthority?(folderURL) }
                catch { authorityFailure = error.localizedDescription; break }
            } catch {
                failures.append(.init(faceID: faceID, message: error.localizedDescription))
            }
        }

        return .committed(FaceDataPersistenceEvidence(
            folderURL: folderURL,
            documentCommitted: true,
            requestedThumbnailDeletionCount: thumbnailIDs.count,
            deletedThumbnailIDs: deletedIDs,
            thumbnailFailures: failures,
            cancellationRequestedAfterCommit: Task.isCancelled
                || (authorityFailure == nil && deletedIDs.count + failures.count < thumbnailIDs.count),
            authorityFailure: authorityFailure
        ))
    }

    func persistThumbnail(
        _ data: Data,
        faceID: UUID,
        folderURL: URL,
        effectAuthority: EffectAuthority? = nil,
        writeCapability: FaceDataWriteCapability? = nil
    ) -> FaceThumbnailPersistenceResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(faceID: faceID)
        }
        do {
            try effectAuthority?(folderURL)
            if let writeCapability {
                guard writeCapability.folderURL == folderURL.standardizedFileURL else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                try writeCapability.saveThumbnail(data, for: faceID)
            } else if usesDefaultThumbnailSaver {
                try FaceDataStorageService().saveThumbnail(data, for: faceID, folderURL: folderURL, effectAuthority: effectAuthority)
            } else {
                try saveThumbnail(data, faceID, folderURL)
            }
            do { try effectAuthority?(folderURL) }
            catch { return .committedButUnverified(faceID: faceID, message: error.localizedDescription,
                cancellationRequestedAfterCommit: Task.isCancelled) }
            return .committed(
                faceID: faceID,
                cancellationRequestedAfterCommit: Task.isCancelled
            )
        } catch let error as FaceDataWriteError where error.committed {
            return .committedButUnverified(faceID: faceID, message: error.localizedDescription,
                cancellationRequestedAfterCommit: Task.isCancelled)
        } catch {
            return .failed(faceID: faceID, message: error.localizedDescription)
        }
    }

    func deleteAllWithFolderReservation(for folderURL: URL) -> FaceDataDeletionResult {
        let folderURL = folderURL.standardizedFileURL
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(folderURL: folderURL)
        }
        do {
            let reservation = try MCPProcessReservation.acquireFolder(folderURL)
            defer { reservation.release() }
            return deleteAll(for: folderURL)
        } catch {
            return .failed(folderURL: folderURL, message: error.localizedDescription)
        }
    }

    func deleteAll(for folderURL: URL, effectAuthority: EffectAuthority? = nil,
                   writeCapability: FaceDataWriteCapability? = nil) -> FaceDataDeletionResult {
        invalidateDocumentCache(folderURL)
        if let writeCapability {
            guard writeCapability.folderURL == folderURL.standardizedFileURL else {
                return .failed(folderURL: folderURL, message: "Reset capability does not match the approved folder.")
            }
            return .anchored(writeCapability.reset())
        }
        let standardizedFolderURL = folderURL.standardizedFileURL
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(folderURL: standardizedFolderURL)
        }
        do {
            try effectAuthority?(folderURL)
            try deleteFaceData(folderURL)
            do { try effectAuthority?(folderURL) }
            catch { return .committedButUnverified(folderURL: standardizedFolderURL, message: error.localizedDescription,
                cancellationRequestedAfterCommit: Task.isCancelled) }
            return .committed(
                folderURL: standardizedFolderURL,
                cancellationRequestedAfterCommit: Task.isCancelled
            )
        } catch {
            return .failed(
                folderURL: standardizedFolderURL,
                message: error.localizedDescription
            )
        }
    }

    /// Folder browsing may recover corrupt documents or expire old results. Hold the
    /// shared reservation across those mutations and the complete thumbnail snapshot.
    func loadWithFolderReservation(
        folderURL: URL,
        cleanupPolicy: FaceCleanupPolicy
    ) throws -> FaceDataFolderLoadResult {
        guard !Task.isCancelled else {
            return .cancelled(CancelledFaceDataFolderLoadEvidence(
                folderURL: folderURL.standardizedFileURL,
                requestedThumbnailCount: 0,
                processedThumbnailCount: 0
            ))
        }
        let reservation = try MCPProcessReservation.acquireFolder(folderURL)
        defer { reservation.release() }
        return load(folderURL: folderURL, cleanupPolicy: cleanupPolicy)
    }

    /// Face deletion must not release admission between its snapshot and commit.
    /// Return the original snapshot on write failure and the committed snapshot even if
    /// thumbnail cleanup fails; callers must not confuse cleanup with a failed document write.
    func deletePhotoFacesWithFolderReservation(
        folderURL: URL,
        imageURLs: Set<URL>
    ) throws -> (load: FaceDataFolderLoadResult, persistence: FaceDataPersistenceResult?) {
        try deleteFacesWithFolderReservation(folderURL: folderURL, selection: .photos(imageURLs))
    }

    func deleteFacesWithFolderReservation(
        folderURL: URL,
        selection: FaceDataDeletionSelection
    ) throws -> (load: FaceDataFolderLoadResult, persistence: FaceDataPersistenceResult?) {
        guard !Task.isCancelled else {
            return (.cancelled(CancelledFaceDataFolderLoadEvidence(
                folderURL: folderURL.standardizedFileURL,
                requestedThumbnailCount: 0, processedThumbnailCount: 0
            )), nil)
        }
        let reservation = try MCPProcessReservation.acquireFolder(folderURL)
        defer { reservation.release() }
        return try deleteFaces(folderURL: folderURL, selection: selection)
    }

    /// The caller owns the folder reservation through photo Trash and this commit.
    func deleteFaces(
        folderURL: URL,
        selection: FaceDataDeletionSelection
    ) throws -> (load: FaceDataFolderLoadResult, persistence: FaceDataPersistenceResult?) {
        let loaded = load(folderURL: folderURL, cleanupPolicy: .never)
        guard case .complete(let evidence) = loaded, var data = evidence.faceData else {
            return (loaded, nil)
        }
        // A persisted URL must never redirect this transaction outside its reserved folder.
        guard data.folderURL.standardizedFileURL.path == folderURL.standardizedFileURL.path else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let removedIDs: Set<UUID>
        switch selection {
        case .photos(let imageURLs):
            guard imageURLs.allSatisfy({
                $0.deletingLastPathComponent().standardizedFileURL.path == folderURL.standardizedFileURL.path
            }) else { throw CocoaError(.fileReadCorruptFile) }
            let paths = Set(imageURLs.map { $0.standardizedFileURL.path })
            removedIDs = Set(data.faces.filter {
                paths.contains($0.imageURL.standardizedFileURL.path)
            }.map(\.id))
        case .faces(let faceIDs):
            removedIDs = faceIDs.intersection(data.faces.map(\.id))
        }
        guard !removedIDs.isEmpty else { return (loaded, nil) }
        for index in data.groups.indices {
            data.groups[index].faceIDs.removeAll { removedIDs.contains($0) }
            if removedIDs.contains(data.groups[index].representativeFaceID),
               let replacement = data.groups[index].faceIDs.first {
                data.groups[index].representativeFaceID = replacement
            }
        }
        data.groups.removeAll { $0.faceIDs.isEmpty }
        data.faces.removeAll { removedIDs.contains($0.id) }
        let persistence = persist(data, deletingThumbnailIDs: removedIDs.sorted {
            $0.uuidString < $1.uuidString
        })
        guard case .committed = persistence else { return (loaded, persistence) }
        return (.complete(FaceDataFolderLoadEvidence(
            folderURL: evidence.folderURL,
            faceData: data,
            thumbnailData: evidence.thumbnailData.filter { !removedIDs.contains($0.key) },
            requestedThumbnailCount: evidence.requestedThumbnailCount,
            processedThumbnailCount: evidence.processedThumbnailCount,
            cleanupDisposition: evidence.cleanupDisposition
        )), persistence)
    }

    /// The caller must own the enclosing folder reservation (for example a face scan).
    /// Document-only consumers use the non-mutating `loadDocument` path instead.
    func load(
        folderURL: URL,
        cleanupPolicy: FaceCleanupPolicy,
        readOnlyRecovery: Bool = false
    ) -> FaceDataFolderLoadResult {
        let standardizedFolderURL = folderURL.standardizedFileURL
        // This path may relocate a corrupt document or expire old results.
        invalidateDocumentCache(standardizedFolderURL)
        guard !Task.isCancelled else {
            return .cancelled(CancelledFaceDataFolderLoadEvidence(
                folderURL: standardizedFolderURL,
                requestedThumbnailCount: 0,
                processedThumbnailCount: 0
            ))
        }

        guard let storedFaceData = (readOnlyRecovery ? loadDocumentFaceData(folderURL) : loadFaceData(folderURL)) else {
            let evidence = FaceDataFolderLoadEvidence(
                folderURL: standardizedFolderURL,
                faceData: nil,
                thumbnailData: [:],
                requestedThumbnailCount: 0,
                processedThumbnailCount: 0,
                cleanupDisposition: cleanupPolicy == .never ? .notRequested : .retained
            )
            return Task.isCancelled
                ? .cancelled(CancelledFaceDataFolderLoadEvidence(
                    folderURL: standardizedFolderURL,
                    requestedThumbnailCount: 0,
                    processedThumbnailCount: 0
                ))
                : .complete(evidence)
        }

        guard !Task.isCancelled else {
            return .cancelled(CancelledFaceDataFolderLoadEvidence(
                folderURL: standardizedFolderURL,
                requestedThumbnailCount: 0,
                processedThumbnailCount: 0
            ))
        }

        let (faceData, wasRebased) = Self.rebased(storedFaceData, to: folderURL)
        if wasRebased, !readOnlyRecovery {
            // The caller owns the folder reservation; durably adopt the new location so the
            // document no longer points at the folder it was moved or copied from.
            if let failure = persist(faceData).failureMessage {
                faceDataLog.warning("Failed to save rebased face data: \(failure, privacy: .private)")
            }
        }

        let cleanupDisposition: FaceDataFolderLoadEvidence.CleanupDisposition
        if !readOnlyRecovery, let maximumAge = cleanupPolicy.timeInterval,
           currentDate().timeIntervalSince(faceData.lastScanDate) > maximumAge {
            do {
                try deleteFaceData(folderURL)
                return .complete(FaceDataFolderLoadEvidence(
                    folderURL: standardizedFolderURL,
                    faceData: nil,
                    thumbnailData: [:],
                    requestedThumbnailCount: 0,
                    processedThumbnailCount: 0,
                    cleanupDisposition: .deleted(
                        cancellationRequestedAfterCommit: Task.isCancelled
                    )
                ))
            } catch {
                cleanupDisposition = .deletionFailed(error.localizedDescription)
            }
        } else {
            cleanupDisposition = cleanupPolicy == .never ? .notRequested : .retained
        }

        let faceIDs = Self.orderedThumbnailFaceIDs(in: faceData)
        var thumbnails: [UUID: Data] = [:]
        thumbnails.reserveCapacity(faceIDs.count)
        var processedThumbnailCount = 0

        for faceID in faceIDs {
            guard !Task.isCancelled else {
                return .cancelled(CancelledFaceDataFolderLoadEvidence(
                    folderURL: standardizedFolderURL,
                    requestedThumbnailCount: faceIDs.count,
                    processedThumbnailCount: processedThumbnailCount
                ))
            }
            let data = loadThumbnail(faceID, folderURL)
            guard !Task.isCancelled else {
                return .cancelled(CancelledFaceDataFolderLoadEvidence(
                    folderURL: standardizedFolderURL,
                    requestedThumbnailCount: faceIDs.count,
                    processedThumbnailCount: processedThumbnailCount
                ))
            }
            if let data {
                thumbnails[faceID] = data
            }
            processedThumbnailCount += 1
        }

        return .complete(FaceDataFolderLoadEvidence(
            folderURL: standardizedFolderURL,
            faceData: faceData,
            thumbnailData: thumbnails,
            requestedThumbnailCount: faceIDs.count,
            processedThumbnailCount: processedThumbnailCount,
            cleanupDisposition: cleanupDisposition
        ))
    }

    private static func orderedThumbnailFaceIDs(in faceData: FolderFaceData) -> [UUID] {
        var result: [UUID] = []
        result.reserveCapacity(faceData.faces.count)
        var seen: Set<UUID> = []

        // Load visible group representatives first, then the remaining detail-view faces.
        for faceID in faceData.groups.map(\.representativeFaceID) + faceData.faces.map(\.id) {
            if seen.insert(faceID).inserted {
                result.append(faceID)
            }
        }
        return result
    }
}
