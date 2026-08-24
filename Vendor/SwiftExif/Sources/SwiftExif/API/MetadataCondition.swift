import Foundation

/// Thread-safe cache for compiled regular expressions.
private final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private let lock = NSLock()
    private var cache: [String: NSRegularExpression] = [:]

    func regex(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pattern] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache[pattern] = compiled
        return compiled
    }
}

/// A condition for filtering metadata, equivalent to ExifTool's `-if` flag.
/// Conditions are evaluated against the flattened metadata dictionary from `MetadataExporter.buildDictionary`.
public indirect enum MetadataCondition: Sendable {

    // MARK: - Comparison Operators

    /// Field equals value (case-sensitive string comparison).
    case equals(field: String, value: String)

    /// Field does not equal value.
    case notEquals(field: String, value: String)

    /// Field contains substring (case-insensitive).
    case contains(field: String, substring: String)

    /// Field matches a regular expression pattern.
    case matches(field: String, pattern: String)

    /// Field exists (has any value).
    case exists(field: String)

    /// Numeric comparison: field > value.
    case greaterThan(field: String, value: Double)

    /// Numeric comparison: field < value.
    case lessThan(field: String, value: Double)

    /// Numeric comparison: field >= value.
    case greaterThanOrEqual(field: String, value: Double)

    /// Numeric comparison: field <= value.
    case lessThanOrEqual(field: String, value: Double)

    // MARK: - Logical Combinators

    /// All conditions must be true.
    case and([MetadataCondition])

    /// At least one condition must be true.
    case or([MetadataCondition])

    /// Negates the condition.
    case not(MetadataCondition)

    // MARK: - Evaluation

    /// Evaluate this condition against an `ImageMetadata` instance.
    public func matches(_ metadata: ImageMetadata) -> Bool {
        let dict = MetadataExporter.buildDictionary(metadata)
        return evaluate(against: dict)
    }

    // MARK: - Internal

    private func evaluate(against dict: [String: Any]) -> Bool {
        switch self {
        case .equals(let field, let value):
            return stringValue(for: field, in: dict) == value

        case .notEquals(let field, let value):
            return stringValue(for: field, in: dict) != value

        case .contains(let field, let substring):
            guard let str = stringValue(for: field, in: dict) else { return false }
            return str.localizedCaseInsensitiveContains(substring)

        case .matches(let field, let pattern):
            guard let str = stringValue(for: field, in: dict) else { return false }
            return RegexCache.shared.regex(for: pattern)
                .map { $0.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) != nil }
                ?? false

        case .exists(let field):
            return dict[field] != nil

        case .greaterThan(let field, let value):
            guard let num = numericValue(for: field, in: dict) else { return false }
            return num > value

        case .lessThan(let field, let value):
            guard let num = numericValue(for: field, in: dict) else { return false }
            return num < value

        case .greaterThanOrEqual(let field, let value):
            guard let num = numericValue(for: field, in: dict) else { return false }
            return num >= value

        case .lessThanOrEqual(let field, let value):
            guard let num = numericValue(for: field, in: dict) else { return false }
            return num <= value

        case .and(let conditions):
            return conditions.allSatisfy { $0.evaluate(against: dict) }

        case .or(let conditions):
            return conditions.contains { $0.evaluate(against: dict) }

        case .not(let condition):
            return !condition.evaluate(against: dict)
        }
    }

    private func stringValue(for field: String, in dict: [String: Any]) -> String? {
        guard let value = dict[field] else { return nil }
        if let arr = value as? [String] {
            return arr.joined(separator: ", ")
        }
        return String(describing: value)
    }

    private func numericValue(for field: String, in dict: [String: Any]) -> Double? {
        guard let value = dict[field] else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

// MARK: - BatchProcessor Integration

extension BatchProcessor {

    /// Apply a transformation only to files whose metadata matches the condition.
    public static func processFiles(
        _ urls: [URL],
        where condition: MetadataCondition,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        transform: @escaping MetadataTransform
    ) throws -> BatchResult {
        runBatch(urls, concurrency: concurrency) { url in
            var metadata = try ImageMetadata.read(from: url)
            guard condition.matches(metadata) else { return false }
            try transform(&metadata)
            try metadata.write(to: url)
            return true
        }
    }

    /// Apply a transformation to directory files matching a condition.
    public static func processDirectory(
        at url: URL,
        where condition: MetadataCondition,
        recursive: Bool = false,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        transform: @escaping MetadataTransform
    ) throws -> BatchResult {
        let urls = try enumerateFiles(in: url, recursive: recursive)
        return try processFiles(urls, where: condition, concurrency: concurrency, transform: transform)
    }

    // MARK: - Async Conditional Processing

    /// Apply a transformation only to files whose metadata matches the condition, using structured concurrency.
    public static func processFiles(
        _ urls: [URL],
        where condition: MetadataCondition,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        transform: @escaping MetadataTransform
    ) async -> BatchResult {
        await runBatchAsync(urls, concurrency: concurrency) { url in
            var metadata = try ImageMetadata.read(from: url)
            guard condition.matches(metadata) else { return false }
            try transform(&metadata)
            try metadata.write(to: url)
            return true
        }
    }

    /// Apply a transformation to directory files matching a condition, using structured concurrency.
    public static func processDirectory(
        at url: URL,
        where condition: MetadataCondition,
        recursive: Bool = false,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        transform: @escaping MetadataTransform
    ) async throws -> BatchResult {
        let urls = try enumerateFiles(in: url, recursive: recursive)
        return await processFiles(urls, where: condition, concurrency: concurrency, transform: transform)
    }
}
