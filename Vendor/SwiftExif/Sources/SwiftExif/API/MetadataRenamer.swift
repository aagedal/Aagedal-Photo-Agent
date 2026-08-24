import Foundation

/// Rename files based on metadata values using a template string.
/// Equivalent to ExifTool's `-FileName<` functionality.
///
/// Template tokens:
/// - `%{FieldName}` — replaced with the metadata value (e.g. `%{Make}`, `%{IPTC:City}`)
/// - `%{FieldName:dateformat}` — format a date field (e.g. `%{DateTimeOriginal:yyyy-MM-dd}`)
/// - `%c` — sequence counter (for uniqueness when names collide)
///
/// Example: `"%{DateTimeOriginal:yyyy-MM-dd}_%{Make}_%c"` → `"2024-01-15_Canon_001.jpg"`
public struct MetadataRenamer: Sendable {

    /// The template string for generating filenames.
    public let template: String

    /// Number of digits for the counter (default 3 → "001").
    public let counterDigits: Int

    public init(template: String, counterDigits: Int = 3) {
        self.template = template
        self.counterDigits = counterDigits
    }

    // MARK: - Single File

    /// Generate the new filename (without extension) for the given metadata.
    /// The `counter` value is used for `%c` tokens.
    public func newName(for metadata: ImageMetadata, counter: Int = 1) -> String {
        let dict = MetadataExporter.buildDictionary(metadata)
        return resolveTemplate(dict: dict, counter: counter)
    }

    /// Generate the full new filename (with extension preserved from original).
    public func newFileName(for metadata: ImageMetadata, originalURL: URL, counter: Int = 1) -> String {
        let baseName = newName(for: metadata, counter: counter)
        let ext = originalURL.pathExtension
        return ext.isEmpty ? baseName : "\(baseName).\(ext)"
    }

    /// Compute the new URL for a file (dry-run — does not rename).
    public func newURL(for metadata: ImageMetadata, originalURL: URL, counter: Int = 1) -> URL {
        let fileName = newFileName(for: metadata, originalURL: originalURL, counter: counter)
        return originalURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// Rename a single file based on its metadata.
    /// Returns the new URL, or `nil` if the name didn't change.
    @discardableResult
    public func rename(file url: URL, counter: Int = 1) throws -> URL? {
        let metadata = try ImageMetadata.read(from: url)
        let destination = newURL(for: metadata, originalURL: url, counter: counter)

        guard destination != url else { return nil }

        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    // MARK: - Batch Rename

    /// Result of a batch rename operation.
    public struct RenameResult: Sendable {
        public let renamed: [(from: URL, to: URL)]
        public let skipped: [URL]
        public let failed: [(url: URL, error: any Error)]
    }

    /// Preview renames without actually moving files.
    public func dryRun(files urls: [URL]) -> [(from: URL, to: URL)] {
        var results: [(from: URL, to: URL)] = []
        var nameCounters: [String: Int] = [:]

        for url in urls {
            guard let metadata = try? ImageMetadata.read(from: url) else { continue }
            let baseName = newName(for: metadata)
            let count = (nameCounters[baseName] ?? 0) + 1
            nameCounters[baseName] = count

            let destination = newURL(for: metadata, originalURL: url, counter: count)
            if destination != url {
                results.append((from: url, to: destination))
            }
        }

        return results
    }

    /// Rename multiple files, using auto-incrementing counters for collisions.
    public func rename(files urls: [URL]) -> RenameResult {
        var renamed: [(from: URL, to: URL)] = []
        var skipped: [URL] = []
        var failed: [(url: URL, error: any Error)] = []
        var nameCounters: [String: Int] = [:]

        for url in urls {
            do {
                let metadata = try ImageMetadata.read(from: url)
                let baseName = newName(for: metadata)
                let count = (nameCounters[baseName] ?? 0) + 1
                nameCounters[baseName] = count

                let destination = newURL(for: metadata, originalURL: url, counter: count)
                guard destination != url else {
                    skipped.append(url)
                    continue
                }

                try FileManager.default.moveItem(at: url, to: destination)
                renamed.append((from: url, to: destination))
            } catch {
                failed.append((url: url, error: error))
            }
        }

        return RenameResult(renamed: renamed, skipped: skipped, failed: failed)
    }

    // MARK: - Template Resolution

    private static let tokenPattern = try! NSRegularExpression(pattern: #"%\{([^}]+)\}"#)
    private static let counterPattern = try! NSRegularExpression(pattern: #"%c"#)

    private func resolveTemplate(dict: [String: Any], counter: Int) -> String {
        var result = template

        // Replace %{Field} and %{Field:format} tokens
        let matches = Self.tokenPattern.matches(in: result, range: NSRange(result.startIndex..., in: result))

        // Process in reverse to preserve indices
        for match in matches.reversed() {
            guard let tokenRange = Range(match.range, in: result),
                  let innerRange = Range(match.range(at: 1), in: result) else { continue }

            let inner = String(result[innerRange])
            let resolved: String

            if let colonIndex = inner.firstIndex(of: ":") {
                // %{Field:dateformat}
                let field = String(inner[inner.startIndex..<colonIndex])
                let dateFormat = String(inner[inner.index(after: colonIndex)...])
                resolved = formatDateField(field: field, format: dateFormat, dict: dict)
            } else {
                // %{Field}
                resolved = resolveField(inner, dict: dict)
            }

            result.replaceSubrange(tokenRange, with: resolved)
        }

        // Replace %c with zero-padded counter
        let counterStr = String(format: "%0\(counterDigits)d", counter)
        result = Self.counterPattern.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: counterStr
        )

        // Sanitize for filesystem
        return sanitizeFilename(result)
    }

    private func resolveField(_ field: String, dict: [String: Any]) -> String {
        guard let value = dict[field] else { return "" }
        if let arr = value as? [String] {
            return arr.joined(separator: "_")
        }
        return String(describing: value)
    }

    // Locale / TimeZone are immutable value types and thread-safe to share.
    // We deliberately don't cache the DateFormatter itself — DateFormatter is
    // not thread-safe, and `MetadataRenamer` is `Sendable`.
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let utcTimeZone = TimeZone(secondsFromGMT: 0)!

    private func formatDateField(field: String, format: String, dict: [String: Any]) -> String {
        guard let dateStr = dict[field] as? String else { return "" }

        let fmt = DateFormatter()
        fmt.locale = Self.posixLocale
        fmt.timeZone = Self.utcTimeZone
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"

        let date: Date?
        if let d = fmt.date(from: dateStr) {
            date = d
        } else {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            date = iso.date(from: dateStr)
        }

        guard let parsed = date else { return dateStr }

        fmt.dateFormat = format
        return fmt.string(from: parsed)
    }

    private func sanitizeFilename(_ name: String) -> String {
        // Remove characters that are problematic in filenames
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.unicodeScalars
            .filter { !illegal.contains($0) }
            .map { Character($0) }
            .map { String($0) }
            .joined()
    }
}
