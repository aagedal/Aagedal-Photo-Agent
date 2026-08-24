import Foundation

/// Glob-pattern filter for metadata tag keys.
///
/// Operates on the flat key format from `MetadataExporter.buildDictionary()`:
/// unprefixed EXIF (`Make`, `ISO`), `IPTC:*`, `XMP-prefix:*`, `MakerNote:*`,
/// `PDF:*`, `ICCProfile:*`, `Composite:*`.
///
/// Supports `*` (match any characters) and `?` (match single character).
public struct TagFilter: Sendable {

    public enum Pattern: Sendable {
        case include(String)
        case exclude(String)
    }

    public let patterns: [Pattern]

    private let includeRegexes: [NSRegularExpression]
    private let excludeRegexes: [NSRegularExpression]

    public init(_ patterns: [Pattern]) {
        self.patterns = patterns
        var includes: [NSRegularExpression] = []
        var excludes: [NSRegularExpression] = []
        for p in patterns {
            switch p {
            case .include(let glob):
                if let rx = Self.globToRegex(glob) { includes.append(rx) }
            case .exclude(let glob):
                if let rx = Self.globToRegex(glob) { excludes.append(rx) }
            }
        }
        self.includeRegexes = includes
        self.excludeRegexes = excludes
    }

    /// Convenience: build from separate include/exclude string arrays.
    public init(tags: [String] = [], excludeTags: [String] = []) {
        let patterns = tags.map { Pattern.include($0) } + excludeTags.map { Pattern.exclude($0) }
        self.init(patterns)
    }

    /// Whether this filter has any patterns at all.
    public var isEmpty: Bool { patterns.isEmpty }

    /// Test whether a single key passes this filter.
    public func matches(key: String) -> Bool {
        // If includes exist, key must match at least one
        if !includeRegexes.isEmpty {
            let matchesAny = includeRegexes.contains { regex in
                let range = NSRange(key.startIndex..., in: key)
                return regex.firstMatch(in: key, range: range) != nil
            }
            if !matchesAny { return false }
        }

        // Excludes remove matching keys
        for regex in excludeRegexes {
            let range = NSRange(key.startIndex..., in: key)
            if regex.firstMatch(in: key, range: range) != nil {
                return false
            }
        }

        return true
    }

    /// Filter a metadata dictionary, returning only keys that pass the filter.
    public func apply(to dict: [String: Any]) -> [String: Any] {
        if isEmpty { return dict }
        return dict.filter { matches(key: $0.key) }
    }

    // MARK: - Private

    /// Convert a glob pattern to an anchored regex.
    private static func globToRegex(_ glob: String) -> NSRegularExpression? {
        var regex = "^"
        for char in glob {
            switch char {
            case "*": regex += ".*"
            case "?": regex += "."
            case ".": regex += "\\."
            case "(", ")", "[", "]", "{", "}", "^", "$", "|", "+", "\\": regex += "\\\(char)"
            default: regex += String(char)
            }
        }
        regex += "$"
        return try? NSRegularExpression(pattern: regex, options: [.caseInsensitive])
    }
}
