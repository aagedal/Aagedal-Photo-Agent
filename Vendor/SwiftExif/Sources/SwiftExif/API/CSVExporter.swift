import Foundation

/// Export metadata as CSV for DAM/CMS integration.
public struct CSVExporter: Sendable {

    /// Export multiple files' metadata as a CSV string.
    /// - Parameters:
    ///   - items: Metadata instances to export.
    ///   - fields: Specific field keys to include (nil = auto-discover all unique keys).
    /// - Returns: A CSV string with header row and one data row per item.
    public static func toCSV(_ items: [ImageMetadata], fields: [String]? = nil) -> String {
        guard !items.isEmpty else { return "" }

        let dicts = items.map { MetadataExporter.buildDictionary($0) }

        // Determine columns
        let columns: [String]
        if let fields = fields {
            columns = fields
        } else {
            var allKeys = Set<String>()
            for dict in dicts {
                allKeys.formUnion(dict.keys)
            }
            columns = allKeys.sorted()
        }

        guard !columns.isEmpty else { return "" }

        var lines: [String] = []

        // Header row
        lines.append(columns.map { escapeCSVField($0) }.joined(separator: ","))

        // Data rows
        for dict in dicts {
            let row = columns.map { key -> String in
                guard let value = dict[key] else { return "" }
                let str = stringifyValue(value)
                return escapeCSVField(str)
            }
            lines.append(row.joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Export metadata as CSV, filtered to matching tags only.
    public static func toCSV(_ items: [ImageMetadata], filter: TagFilter) -> String {
        guard !items.isEmpty else { return "" }
        let dicts = items.map { filter.apply(to: MetadataExporter.buildDictionary($0)) }
        var allKeys = Set<String>()
        for dict in dicts { allKeys.formUnion(dict.keys) }
        let columns = allKeys.sorted()
        guard !columns.isEmpty else { return "" }

        var lines: [String] = []
        lines.append(columns.map { escapeCSVField($0) }.joined(separator: ","))
        for dict in dicts {
            let row = columns.map { key -> String in
                guard let value = dict[key] else { return "" }
                return escapeCSVField(stringifyValue(value))
            }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Private

    private static func stringifyValue(_ value: Any) -> String {
        if let arr = value as? [String] {
            return arr.joined(separator: ";")
        }
        return String(describing: value)
    }

    /// Escape a string for safe inclusion in a CSV field (RFC 4180).
    public static func escapeCSV(_ field: String) -> String {
        escapeCSVField(field)
    }

    private static func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }
}
