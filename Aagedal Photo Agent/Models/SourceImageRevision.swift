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
        try Task.checkCancellation()

        guard url.isFileURL else {
            throw SourceImageRevisionError.notAFileURL
        }

        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let before = try FileSnapshot.capture(at: canonicalURL)
        guard before.isRegularFile else {
            throw SourceImageRevisionError.notARegularFile
        }

        let digest = try await HashStream.hashFile(at: canonicalURL)
        try Task.checkCancellation()

        let after = try FileSnapshot.capture(at: canonicalURL)
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
            hashCompletedAt: Date()
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

private extension SourceImageRevision {
    nonisolated struct FileSnapshot {
        let isRegularFile: Bool
        let byteCount: Int64
        let contentModificationDate: Date
        let fileResourceIdentifier: FileResourceIdentifier?

        static func capture(at url: URL) throws -> FileSnapshot {
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

            return FileSnapshot(
                isRegularFile: true,
                byteCount: Int64(fileSize),
                contentModificationDate: contentModificationDate,
                fileResourceIdentifier: FileResourceIdentifier(
                    foundationValue: values.fileResourceIdentifier
                )
            )
        }

        func matches(_ other: FileSnapshot) -> Bool {
            isRegularFile == other.isRegularFile
                && byteCount == other.byteCount
                && contentModificationDate == other.contentModificationDate
                && fileResourceIdentifier == other.fileResourceIdentifier
        }
    }
}
