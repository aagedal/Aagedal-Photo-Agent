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
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        return SourceImageRevision(
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
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
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
                )
            )
        },
        hash: { try HashStream.hashFileSynchronously(at: $0) },
        now: Date.init
    )
}

/// Owns the complete stat-hash-stat transaction. Keeping every synchronous filesystem primitive
/// in one non-reentrant actor method prevents MainActor callers from performing the two resource
/// probes and prevents overlapping captures from observing one another's partial transaction.
actor SourceImageRevisionCaptureService {
    static let shared = SourceImageRevisionCaptureService()

    private let io: SourceImageRevisionCaptureIO

    init(io: SourceImageRevisionCaptureIO = .system) {
        self.io = io
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

        let digest = try io.hash(canonicalURL)
        try Task.checkCancellation()
        let after = try io.snapshot(canonicalURL)
        try Task.checkCancellation()
        guard before.matches(after) else {
            throw SourceImageRevisionError.sourceChangedDuringHash
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
