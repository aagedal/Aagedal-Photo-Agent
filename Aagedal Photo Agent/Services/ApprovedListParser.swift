import Foundation

nonisolated enum ApprovedListParserError: Error, LocalizedError {
    case fileTooLarge(bytes: Int64, limit: Int64)
    case readFailed(underlying: Error)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes, let limit):
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            return "File is too large (\(formatter.string(fromByteCount: bytes)), limit is \(formatter.string(fromByteCount: limit)))."
        case .readFailed(let error):
            return "Could not read file: \(error.localizedDescription)"
        case .decodingFailed:
            return "Could not decode file contents as text."
        }
    }
}

nonisolated enum ApprovedListParser {
    static let maxFileSizeBytes: Int64 = 50 * 1024 * 1024

    /// Parses an approved-keywords list file.
    ///
    /// - For `.csv` (by extension): takes everything before the first `,` on each line.
    /// - For any other extension: takes the whole line.
    /// - Strips BOM, normalizes NBSP to space, trims whitespace and surrounding quotes.
    /// - Skips empty lines and lines starting with `#`.
    /// - First occurrence wins on duplicates (file order is canonical).
    static func parse(_ url: URL) throws -> [String] {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? NSNumber, size.int64Value > maxFileSizeBytes {
            throw ApprovedListParserError.fileTooLarge(bytes: size.int64Value, limit: maxFileSizeBytes)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ApprovedListParserError.readFailed(underlying: error)
        }

        return try parse(data, csv: url.pathExtension.lowercased() == "csv")
    }

    /// Parses already-read bytes so callers that own an asynchronous filesystem boundary do not
    /// have to re-enter the synchronous URL-based API.
    static func parse(_ data: Data, csv: Bool) throws -> [String] {
        guard let raw = decode(data) else {
            throw ApprovedListParserError.decodingFailed
        }
        return parseString(raw, csv: csv)
    }

    /// Visible for testing — parses a raw string without touching the filesystem.
    static func parseString(_ raw: String, csv: Bool) -> [String] {
        let cleaned = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        var seen = Set<String>()
        var result: [String] = []
        cleaned.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }

            let payload: String
            if csv {
                if let comma = trimmed.firstIndex(of: ",") {
                    payload = String(trimmed[..<comma])
                } else {
                    payload = trimmed
                }
            } else {
                payload = trimmed
            }

            let unquoted = stripSurroundingQuotes(payload)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !unquoted.isEmpty else { return }

            if seen.insert(unquoted).inserted {
                result.append(unquoted)
            }
        }
        return result
    }

    private static func stripSurroundingQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func decode(_ data: Data) -> String? {
        // Try UTF-8 first (most common). Fall back to UTF-16 (Excel with BOM commonly exports this).
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        if let s = String(data: data, encoding: .utf16BigEndian) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return nil
    }
}

nonisolated struct ApprovedListImportCommit: Equatable, Sendable {
    let requestID: UUID
    let sourceURL: URL
    let destinationURL: URL
    let entries: [String]
    let sourceByteCount: Int
    let committedByteCount: Int
    /// A coordinated atomic write cannot be interrupted once entered. A cancellation observed
    /// after it returns therefore describes a completed commit, not a cancelled import.
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum ApprovedListImportResult: Equatable, Sendable {
    case committed(ApprovedListImportCommit)
    case cancelledBeforeAccess(requestID: UUID)
    case cancelledBeforeRead(requestID: UUID, sourceURL: URL)
    case cancelledAfterRead(requestID: UUID, sourceURL: URL, byteCount: Int)
    case cancelledBeforeCommit(
        requestID: UUID,
        sourceURL: URL,
        destinationURL: URL,
        byteCount: Int,
        entryCount: Int
    )
}

nonisolated struct ApprovedListImportFileAccess: Sendable {
    let startAccessing: @Sendable (URL) -> Bool
    let stopAccessing: @Sendable (URL) -> Void
    let fileSize: @Sendable (URL) throws -> Int64
    let readData: @Sendable (URL) throws -> Data
    let writeData: @Sendable (Data, URL) throws -> Void

    static let system = ApprovedListImportFileAccess(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() },
        fileSize: { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        },
        readData: { try Data(contentsOf: $0) },
        writeData: { try CloudCoordinatedIO.writeData($0, to: $1) }
    )
}

/// Serializes approved-list imports away from MainActor, including the security-scoped source
/// read and coordinated destination commit. Synchronous Foundation calls are non-preemptible, so
/// cancellation is checked only at stable boundaries. Once the destination write returns, the
/// result always carries immutable durable-commit evidence even if cancellation arrived in flight.
actor ApprovedListImportService {
    static let shared = ApprovedListImportService()

    private let access: ApprovedListImportFileAccess

    init(access: ApprovedListImportFileAccess = .system) {
        self.access = access
    }

    func importEntries(
        from sourceURL: URL,
        to destinationURL: URL,
        requestID: UUID
    ) throws -> ApprovedListImportResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeAccess(requestID: requestID)
        }

        let didStartAccessing = access.startAccessing(sourceURL)
        defer {
            if didStartAccessing {
                access.stopAccessing(sourceURL)
            }
        }

        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID, sourceURL: sourceURL)
        }

        let fileSize = try access.fileSize(sourceURL)
        if fileSize > ApprovedListParser.maxFileSizeBytes {
            throw ApprovedListParserError.fileTooLarge(
                bytes: fileSize,
                limit: ApprovedListParser.maxFileSizeBytes
            )
        }
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID, sourceURL: sourceURL)
        }

        let data: Data
        do {
            data = try access.readData(sourceURL)
        } catch {
            throw ApprovedListParserError.readFailed(underlying: error)
        }
        guard !Task.isCancelled else {
            return .cancelledAfterRead(
                requestID: requestID,
                sourceURL: sourceURL,
                byteCount: data.count
            )
        }

        let entries = try ApprovedListParser.parse(
            data,
            csv: sourceURL.pathExtension.lowercased() == "csv"
        )
        let committedData = Self.encodedEntries(entries)
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(
                requestID: requestID,
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                byteCount: data.count,
                entryCount: entries.count
            )
        }

        try access.writeData(committedData, destinationURL)
        return .committed(ApprovedListImportCommit(
            requestID: requestID,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            entries: entries,
            sourceByteCount: data.count,
            committedByteCount: committedData.count,
            cancellationRequestedAfterCommit: Task.isCancelled
        ))
    }

    private static func encodedEntries(_ entries: [String]) -> Data {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            ordered.append(trimmed)
        }
        let text = ordered.joined(separator: "\n") + (ordered.isEmpty ? "" : "\n")
        return Data(text.utf8)
    }
}
