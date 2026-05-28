import Foundation

enum StructuredKeywordParserError: Error, LocalizedError {
    case fileTooLarge(bytes: Int64, limit: Int64)
    case readFailed(underlying: Error)
    case decodingFailed
    case empty

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
        case .empty:
            return "File contained no keywords."
        }
    }
}

enum StructuredKeywordParser {
    static let maxFileSizeBytes: Int64 = 50 * 1024 * 1024

    static func parse(_ url: URL) throws -> [StructuredKeyword] {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? NSNumber, size.int64Value > maxFileSizeBytes {
            throw StructuredKeywordParserError.fileTooLarge(bytes: size.int64Value, limit: maxFileSizeBytes)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StructuredKeywordParserError.readFailed(underlying: error)
        }
        guard let raw = decode(data) else {
            throw StructuredKeywordParserError.decodingFailed
        }
        let roots = parseString(raw)
        if roots.isEmpty {
            throw StructuredKeywordParserError.empty
        }
        return roots
    }

    /// Visible for testing. Returns the parsed tree from a raw string.
    static func parseString(_ raw: String) -> [StructuredKeyword] {
        let cleaned = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        // Invariant during the walk: `stack[i]` is the most recent non-synonym node at
        // file-depth `i - 1`. `stack[0]` is the synthetic root (file-depth -1). After a
        // keyword at file-depth D is processed, it sits at `stack[D + 1]`.
        let root = Builder(name: "", kind: .container)
        var stack: [Builder] = [root]

        cleaned.enumerateLines { rawLine, _ in
            let (depth, payload) = splitIndent(rawLine)
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            // {synonym} at file-depth D belongs to the owner at file-depth D - 1, which
            // — by the invariant above — lives at stack[D]. Skip orphan top-level synonyms.
            if let synonym = extractBraced(trimmed) {
                if depth >= 1, depth < stack.count {
                    stack[depth].synonyms.append(synonym)
                }
                return
            }

            // Trim the stack so its top is the parent for this node. For a node at
            // file-depth D, parent is the entry at stack[D] (file-depth D - 1).
            while stack.count > depth + 1 {
                stack.removeLast()
            }
            // Malformed files may skip indent levels — attach to the deepest known parent.
            let parent = stack.last ?? root

            let kind: StructuredKeyword.Kind
            let name: String
            if let bracketed = extractBracketed(trimmed) {
                kind = .container
                name = bracketed
            } else {
                kind = .keyword
                name = trimmed
            }
            let builder = Builder(name: name, kind: kind)
            parent.children.append(builder)
            stack.append(builder)
        }

        return root.children.map { $0.freeze() }
    }

    // MARK: - Helpers

    private static func splitIndent(_ line: String) -> (depth: Int, rest: Substring) {
        var depth = 0
        var idx = line.startIndex
        // Count leading tabs as depth. Treat runs of spaces as soft indent: every 4 spaces
        // count as one tab. This is forgiving for files that were re-saved with a
        // tab-expanding editor.
        var pendingSpaces = 0
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == "\t" {
                depth += 1
                pendingSpaces = 0
            } else if ch == " " {
                pendingSpaces += 1
                if pendingSpaces == 4 {
                    depth += 1
                    pendingSpaces = 0
                }
            } else {
                break
            }
            idx = line.index(after: idx)
        }
        return (depth, line[idx...])
    }

    private static func extractBraced(_ s: String) -> String? {
        guard s.hasPrefix("{"), s.hasSuffix("}"), s.count >= 2 else { return nil }
        let inner = s.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    private static func extractBracketed(_ s: String) -> String? {
        guard s.hasPrefix("["), s.hasSuffix("]"), s.count >= 2 else { return nil }
        let inner = s.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    private static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        if let s = String(data: data, encoding: .utf16BigEndian) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return nil
    }

    // MARK: - Builder

    private final class Builder {
        let name: String
        let kind: StructuredKeyword.Kind
        var synonyms: [String] = []
        var children: [Builder] = []

        init(name: String, kind: StructuredKeyword.Kind) {
            self.name = name
            self.kind = kind
        }

        func freeze() -> StructuredKeyword {
            StructuredKeyword(
                name: name,
                kind: kind,
                synonyms: synonyms,
                children: children.map { $0.freeze() }
            )
        }
    }
}
