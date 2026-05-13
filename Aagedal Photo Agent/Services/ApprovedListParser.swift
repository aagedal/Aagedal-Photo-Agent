import Foundation

enum ApprovedListParserError: Error, LocalizedError {
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

enum ApprovedListParser {
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

        guard let raw = decode(data) else {
            throw ApprovedListParserError.decodingFailed
        }

        let isCSV = url.pathExtension.lowercased() == "csv"
        return parseString(raw, csv: isCSV)
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
