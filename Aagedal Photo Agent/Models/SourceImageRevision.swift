import Foundation

/// A stable, persisted description of the exact source bytes used by a 2.3 feature.
///
/// The content hash is authoritative. Paths, resource identifiers, dates, and sizes are
/// discovery/cache hints only and must never be used to silently attach persisted work to
/// different source bytes.
nonisolated struct SourceImageRevision: Codable, Hashable, Sendable {
    /// A Codable representation of Foundation's opaque file-resource identifier.
    ///
    /// The value is intentionally only useful for equality checks. Foundation does not
    /// guarantee a portable identifier representation, and source reassociation still
    /// requires an exact content-hash match.
    nonisolated struct FileResourceIdentifier: Codable, Hashable, Sendable {
        let representation: String
        let value: String

        init?(foundationValue: Any?) {
            guard let foundationValue else { return nil }

            switch foundationValue {
            case let data as Data:
                representation = "data"
                value = data.base64EncodedString()
            case let uuid as UUID:
                representation = "uuid"
                value = uuid.uuidString.lowercased()
            case let number as NSNumber:
                representation = "number"
                value = number.stringValue
            case let string as String:
                representation = "string"
                value = string
            default:
                representation = String(reflecting: type(of: foundationValue))
                value = String(describing: foundationValue)
            }
        }
    }

    enum Relationship: Equatable, Sendable {
        /// Both records describe the same byte-for-byte source revision.
        case exactRevision
        /// The filesystem identity matches, but the bytes do not.
        case sameFileChanged
        /// Only the canonical path matches. This is a discovery hint, not identity.
        case samePathChanged
        case unrelated
    }

    let canonicalURL: URL
    let fileResourceIdentifier: FileResourceIdentifier?
    let filenameAtCreation: String
    let byteCount: Int64
    let contentModificationDate: Date
    let pixelWidth: Int?
    let pixelHeight: Int?
    let exifOrientation: Int?
    /// Lowercase SHA-256 encoded as 64 hexadecimal characters.
    let sha256: String
    let hashCompletedAt: Date

    /// Captures a source revision while streaming the source through SHA-256.
    ///
    /// File attributes are read both before and after hashing. A source that changes during
    /// capture is rejected so downstream analysis cannot be bound to a mixed or stale read.
    static func capture(
        at url: URL,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        exifOrientation: Int? = nil
    ) async throws -> SourceImageRevision {
        try await SourceImageRevisionCaptureService.shared.capture(
            at: url,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            exifOrientation: exifOrientation
        )
    }

    func relationship(to other: SourceImageRevision) -> Relationship {
        if byteCount == other.byteCount && sha256 == other.sha256 {
            return .exactRevision
        }
        if let fileResourceIdentifier,
           fileResourceIdentifier == other.fileResourceIdentifier {
            return .sameFileChanged
        }
        if canonicalURL == other.canonicalURL {
            return .samePathChanged
        }
        return .unrelated
    }

    /// Returns the same authoritative source revision with portable discovery hints for a
    /// relocated byte-for-byte copy. The content hash and analysis-time file facts remain intact;
    /// filesystem identity is deliberately cleared because it is not portable across volumes.
    func relocated(to url: URL) -> SourceImageRevision {
        relocated(toPreparedCanonicalURL: url.standardizedFileURL.resolvingSymlinksInPath())
    }

    /// Uses canonical identity already resolved by a filesystem service.
    func relocated(toPreparedCanonicalURL canonicalURL: URL) -> SourceImageRevision {
        SourceImageRevision(
            canonicalURL: canonicalURL,
            fileResourceIdentifier: nil,
            filenameAtCreation: canonicalURL.lastPathComponent,
            byteCount: byteCount,
            contentModificationDate: contentModificationDate,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            exifOrientation: exifOrientation,
            sha256: sha256,
            hashCompletedAt: hashCompletedAt
        )
    }
}

/// Immutable file facts sampled before and after hashing. The resource identifier is only an
/// equality hint; the streamed digest remains the authoritative revision identity.
nonisolated struct SourceImageRevisionFileSnapshot: Sendable {
    let isRegularFile: Bool
    let byteCount: Int64
    let contentModificationDate: Date
    let fileResourceIdentifier: SourceImageRevision.FileResourceIdentifier?
    /// The inode status-change time (ctime). Any content write, truncate, rename-replace, or
    /// timestamp restore advances it, and user tools cannot set it back. Only used as part of the
    /// capture service's digest-cache identity; `nil` disables caching for this snapshot.
    let statusChangeDate: Date?

    init(
        isRegularFile: Bool,
        byteCount: Int64,
        contentModificationDate: Date,
        fileResourceIdentifier: SourceImageRevision.FileResourceIdentifier?,
        statusChangeDate: Date? = nil
    ) {
        self.isRegularFile = isRegularFile
        self.byteCount = byteCount
        self.contentModificationDate = contentModificationDate
        self.fileResourceIdentifier = fileResourceIdentifier
        self.statusChangeDate = statusChangeDate
    }

    func matches(_ other: SourceImageRevisionFileSnapshot) -> Bool {
        isRegularFile == other.isRegularFile
            && byteCount == other.byteCount
            && contentModificationDate == other.contentModificationDate
            && fileResourceIdentifier == other.fileResourceIdentifier
    }
}

/// Injectable synchronous primitives kept below the actor boundary so tests can prove executor,
/// ordering, and cancellation behavior without touching a real slow volume.
nonisolated struct SourceImageRevisionCaptureIO: Sendable {
    let canonicalURL: @Sendable (URL) -> URL
    let snapshot: @Sendable (URL) throws -> SourceImageRevisionFileSnapshot
    let hash: @Sendable (URL) throws -> Data
    let now: @Sendable () -> Date

    static let system = SourceImageRevisionCaptureIO(
        canonicalURL: { $0.standardizedFileURL.resolvingSymlinksInPath() },
        snapshot: { url in
            // A fresh URL never answers from Foundation's per-instance resource-value cache, so
            // every snapshot (and the digest cache keyed on it) reflects the file as it is now.
            let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .attributeModificationDateKey,
                .fileResourceIdentifierKey
            ])

            guard values.isRegularFile == true else {
                throw SourceImageRevisionError.notARegularFile
            }
            guard let fileSize = values.fileSize else {
                throw SourceImageRevisionError.missingFileSize
            }
            guard let contentModificationDate = values.contentModificationDate else {
                throw SourceImageRevisionError.missingModificationDate
            }

            return SourceImageRevisionFileSnapshot(
                isRegularFile: true,
                byteCount: Int64(fileSize),
                contentModificationDate: contentModificationDate,
                fileResourceIdentifier: SourceImageRevision.FileResourceIdentifier(
                    foundationValue: values.fileResourceIdentifier
                ),
                statusChangeDate: values.attributeModificationDate
            )
        },
        hash: { try HashStream.hashFileSynchronously(at: $0) },
        now: Date.init
    )
}

/// Owns the complete stat-hash-stat transaction. Keeping every synchronous filesystem primitive
/// in one non-reentrant actor method prevents MainActor callers from performing the two resource
/// probes and prevents overlapping captures from observing one another's partial transaction.
/// The Dispatch executor keeps full-file hashing and slow-volume reads off Swift's cooperative
/// pool, leaving its threads available for image navigation and metadata transaction orchestration.
actor SourceImageRevisionCaptureService {
    static let shared = SourceImageRevisionCaptureService()

    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }
    private let io: SourceImageRevisionCaptureIO

    /// Stat identity that must be unchanged for a memoized digest to be reused. The status-change
    /// time is the decisive member: unlike the content modification date it cannot be restored by
    /// user tools, so a same-size rewrite with a preserved mtime still misses.
    private struct DigestIdentity: Equatable {
        let fileResourceIdentifier: SourceImageRevision.FileResourceIdentifier
        let byteCount: Int64
        let contentModificationDate: Date
        let statusChangeDate: Date

        init?(_ snapshot: SourceImageRevisionFileSnapshot) {
            guard snapshot.isRegularFile,
                  let fileResourceIdentifier = snapshot.fileResourceIdentifier,
                  let statusChangeDate = snapshot.statusChangeDate else { return nil }
            self.fileResourceIdentifier = fileResourceIdentifier
            self.byteCount = snapshot.byteCount
            self.contentModificationDate = snapshot.contentModificationDate
            self.statusChangeDate = statusChangeDate
        }
    }

    private struct DigestCacheEntry {
        let identity: DigestIdentity
        let digest: Data
        var lastUse: UInt64
    }

    /// Bounded LRU of verified digests keyed by canonical path. Actor isolation makes it
    /// thread-safe; selection, rating, and write paths capture the same file several times per
    /// operation, and only the first capture after a content change needs to read the bytes.
    private var digestCache: [URL: DigestCacheEntry] = [:]
    private var digestCacheClock: UInt64 = 0
    private let digestCacheCapacity: Int
    private static let digestCacheSettleInterval: TimeInterval = 2.5

    init(io: SourceImageRevisionCaptureIO = .system,
         filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.source-revision.filesystem", qos: .utility
         ),
         digestCacheCapacity: Int = 4_096) {
        self.io = io
        self.filesystemQueue = filesystemQueue
        self.digestCacheCapacity = max(1, digestCacheCapacity)
    }

    func capture(
        at url: URL,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        exifOrientation: Int? = nil
    ) throws -> SourceImageRevision {
        try Task.checkCancellation()
        guard url.isFileURL else {
            throw SourceImageRevisionError.notAFileURL
        }

        let canonicalURL = io.canonicalURL(url)
        try Task.checkCancellation()
        let before = try io.snapshot(canonicalURL)
        try Task.checkCancellation()
        guard before.isRegularFile else {
            throw SourceImageRevisionError.notARegularFile
        }

        let identity = DigestIdentity(before)
        let digest: Data
        if let identity, let cached = cachedDigest(for: canonicalURL, identity: identity) {
            // The stat identity proves the bytes are the ones hashed earlier; no read needed.
            digest = cached
        } else {
            digest = try io.hash(canonicalURL)
            try Task.checkCancellation()
            let after = try io.snapshot(canonicalURL)
            try Task.checkCancellation()
            guard before.matches(after) else {
                throw SourceImageRevisionError.sourceChangedDuringHash
            }
            // Only remember files whose timestamps have settled: on volumes with coarse
            // timestamps (HFS+ 1 s, FAT/exFAT 2 s) a same-size rewrite within the same tick
            // would otherwise keep every identity field and reuse a stale digest.
            let now = io.now()
            if let identity, after.statusChangeDate == before.statusChangeDate,
               now.timeIntervalSince(identity.statusChangeDate) >= Self.digestCacheSettleInterval,
               now.timeIntervalSince(identity.contentModificationDate) >= Self.digestCacheSettleInterval {
                storeDigest(digest, for: canonicalURL, identity: identity)
            }
        }

        return SourceImageRevision(
            canonicalURL: canonicalURL,
            fileResourceIdentifier: before.fileResourceIdentifier,
            filenameAtCreation: canonicalURL.lastPathComponent,
            byteCount: before.byteCount,
            contentModificationDate: before.contentModificationDate,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            exifOrientation: exifOrientation,
            sha256: digest.lowercaseHexString,
            hashCompletedAt: io.now()
        )
    }

    private func cachedDigest(for url: URL, identity: DigestIdentity) -> Data? {
        guard var entry = digestCache[url] else { return nil }
        guard entry.identity == identity else {
            digestCache[url] = nil
            return nil
        }
        digestCacheClock &+= 1
        entry.lastUse = digestCacheClock
        digestCache[url] = entry
        return entry.digest
    }

    private func storeDigest(_ digest: Data, for url: URL, identity: DigestIdentity) {
        digestCacheClock &+= 1
        digestCache[url] = DigestCacheEntry(identity: identity, digest: digest, lastUse: digestCacheClock)
        guard digestCache.count > digestCacheCapacity else { return }
        // Evict the least-recently-used quarter in one pass so the O(n) scan is amortized.
        let evictCount = digestCache.count - max(1, digestCacheCapacity * 3 / 4)
        let victims = digestCache.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(evictCount)
        for victim in victims { digestCache[victim.key] = nil }
    }
}

enum SourceImageRevisionError: Error, Equatable, LocalizedError, Sendable {
    case notAFileURL
    case notARegularFile
    case missingFileSize
    case missingModificationDate
    case sourceChangedDuringHash

    var errorDescription: String? {
        switch self {
        case .notAFileURL:
            "The source must be a local file."
        case .notARegularFile:
            "The source is not a regular file."
        case .missingFileSize:
            "The source file size could not be read."
        case .missingModificationDate:
            "The source modification date could not be read."
        case .sourceChangedDuringHash:
            "The source changed while its revision was being captured. Try again when the file is stable."
        }
    }
}
