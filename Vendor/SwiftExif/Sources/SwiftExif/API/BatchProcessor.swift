import Foundation

/// Result of a batch processing operation.
public struct BatchResult: Sendable {
    public let succeeded: Int
    public let failed: [(url: URL, error: any Error)]
    public let totalTime: TimeInterval

    public init(succeeded: Int, failed: [(url: URL, error: any Error)], totalTime: TimeInterval) {
        self.succeeded = succeeded
        self.failed = failed
        self.totalTime = totalTime
    }

    public var totalProcessed: Int { succeeded + failed.count }
}

/// The validation result for a single file.
public struct FileValidationResult: Sendable {
    public let url: URL
    public let result: ValidationResult?
    public let readError: (any Error)?

    public var passed: Bool { result?.isValid ?? false }
    public var errorCount: Int { result?.errors.count ?? (readError != nil ? 1 : 0) }
    public var warningCount: Int { result?.warnings.count ?? 0 }
}

/// Report from validating multiple files against a profile.
public struct BatchValidationReport: Sendable {
    public let results: [FileValidationResult]
    public let totalTime: TimeInterval

    public var passed: Int { results.filter(\.passed).count }
    public var failed: Int { results.count - passed }
    public var totalFiles: Int { results.count }

    /// Export the report as CSV with one row per file.
    public func toCSV() -> String {
        var lines = ["File,Status,Errors,Warnings,Details"]
        for entry in results.sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent }) {
            let file = CSVExporter.escapeCSV(entry.url.lastPathComponent)
            if let error = entry.readError {
                lines.append("\(file),Error,1,0,\(CSVExporter.escapeCSV(String(describing: error)))")
            } else if let result = entry.result {
                let status = result.isValid ? "Pass" : "Fail"
                let details = result.issues.map(\.description).joined(separator: "; ")
                lines.append("\(file),\(status),\(result.errors.count),\(result.warnings.count),\(CSVExporter.escapeCSV(details))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Process metadata across many files efficiently.
public struct BatchProcessor: Sendable {
    public typealias MetadataTransform = @Sendable (inout ImageMetadata) throws -> Void

    /// Apply a transformation to a single file.
    public static func process(file url: URL, transform: MetadataTransform) throws {
        var metadata = try ImageMetadata.read(from: url)
        try transform(&metadata)
        try metadata.write(to: url)
    }

    /// Apply a transformation to all supported files in a directory.
    public static func processDirectory(
        at url: URL,
        recursive: Bool = false,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        transform: @escaping MetadataTransform
    ) throws -> BatchResult {
        let urls = try enumerateFiles(in: url, recursive: recursive)
        return try processFiles(urls, concurrency: concurrency, transform: transform)
    }

    /// Apply a transformation to a list of files.
    public static func processFiles(
        _ urls: [URL],
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        transform: @escaping MetadataTransform
    ) throws -> BatchResult {
        runBatch(urls, concurrency: concurrency) { url in
            try process(file: url, transform: transform)
            return true
        }
    }

    // MARK: - Internal Helpers

    /// Run a batch operation over URLs with bounded concurrency.
    /// The `operation` closure returns `true` if the file was processed (counted as success),
    /// `false` if skipped (not counted), or throws on failure.
    internal static func runBatch(
        _ urls: [URL],
        concurrency: Int,
        operation: @escaping @Sendable (URL) throws -> Bool
    ) -> BatchResult {
        let start = Date()
        let accumulator = Accumulator()

        let semaphore = DispatchSemaphore(value: max(1, concurrency))
        let group = DispatchGroup()

        for url in urls {
            group.enter()
            semaphore.wait()

            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    semaphore.signal()
                    group.leave()
                }

                do {
                    if try operation(url) {
                        accumulator.recordSuccess()
                    }
                } catch {
                    accumulator.recordFailure(url: url, error: error)
                }
            }
        }

        group.wait()

        let elapsed = Date().timeIntervalSince(start)
        return BatchResult(succeeded: accumulator.succeeded, failed: accumulator.failed, totalTime: elapsed)
    }

    /// Enumerate supported image files in a directory.
    internal static func enumerateFiles(in url: URL, recursive: Bool) throws -> [URL] {
        let fm = FileManager.default
        if recursive {
            var urls: [URL] = []
            if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    if isSupportedFormat(fileURL) {
                        urls.append(fileURL)
                    }
                }
            }
            return urls
        } else {
            return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { isSupportedFormat($0) }
        }
    }

    // MARK: - Private

    final class Accumulator: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var succeeded = 0
        private(set) var failed: [(url: URL, error: any Error)] = []

        func recordSuccess() {
            lock.lock()
            succeeded += 1
            lock.unlock()
        }

        func recordFailure(url: URL, error: any Error) {
            lock.lock()
            failed.append((url: url, error: error))
            lock.unlock()
        }
    }

    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg",
        "tif", "tiff",
        "dng", "gpr", "cr2", "nef", "arw",
        "jxl",
        "png",
        "avif",
        "heic", "heif",
        "webp",
        "cr3",
        "psd", "psb",
        "pdf",
    ]

    static func isSupportedFormat(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Batch Validation

    /// Validate all files against a MetadataValidator profile.
    public static func validateFiles(
        _ urls: [URL],
        validator: MetadataValidator,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) throws -> BatchValidationReport {
        let start = Date()
        let collector = ValidationCollector()

        let semaphore = DispatchSemaphore(value: max(1, concurrency))
        let group = DispatchGroup()

        for url in urls {
            group.enter()
            semaphore.wait()

            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    semaphore.signal()
                    group.leave()
                }

                do {
                    let metadata = try ImageMetadata.read(from: url)
                    let result = validator.validate(metadata)
                    collector.record(url: url, result: result)
                } catch {
                    collector.recordError(url: url, error: error)
                }
            }
        }

        group.wait()

        return BatchValidationReport(
            results: collector.results,
            totalTime: Date().timeIntervalSince(start)
        )
    }

    /// Validate all supported files in a directory against a MetadataValidator profile.
    public static func validateDirectory(
        at url: URL,
        validator: MetadataValidator,
        recursive: Bool = false,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) throws -> BatchValidationReport {
        let urls = try enumerateFiles(in: url, recursive: recursive)
        return try validateFiles(urls, validator: validator, concurrency: concurrency)
    }

    final class ValidationCollector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var results: [FileValidationResult] = []

        func record(url: URL, result: ValidationResult) {
            lock.lock()
            results.append(FileValidationResult(url: url, result: result, readError: nil))
            lock.unlock()
        }

        func recordError(url: URL, error: any Error) {
            lock.lock()
            results.append(FileValidationResult(url: url, result: nil, readError: error))
            lock.unlock()
        }
    }

    // MARK: - Async API (Swift Concurrency)

    /// Apply a transformation to a list of files using structured concurrency.
    public static func processFiles(
        _ urls: [URL],
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        transform: @escaping MetadataTransform
    ) async -> BatchResult {
        await runBatchAsync(urls, concurrency: concurrency) { url in
            try process(file: url, transform: transform)
            return true
        }
    }

    /// Apply a transformation to all supported files in a directory using structured concurrency.
    public static func processDirectory(
        at url: URL,
        recursive: Bool = false,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        transform: @escaping MetadataTransform
    ) async throws -> BatchResult {
        let urls = try enumerateFiles(in: url, recursive: recursive)
        return await processFiles(urls, concurrency: concurrency, transform: transform)
    }

    /// Run a batch operation with bounded concurrency using TaskGroup.
    internal static func runBatchAsync(
        _ urls: [URL],
        concurrency: Int,
        operation: @escaping @Sendable (URL) throws -> Bool
    ) async -> BatchResult {
        let start = Date()
        let limit = max(1, concurrency)

        return await withTaskGroup(of: (URL, Result<Bool, any Error>).self) { group in
            var succeeded = 0
            var failed: [(url: URL, error: any Error)] = []
            var iterator = urls.makeIterator()

            // Seed initial batch up to concurrency limit
            for _ in 0..<min(limit, urls.count) {
                guard let url = iterator.next() else { break }
                group.addTask {
                    do {
                        let result = try operation(url)
                        return (url, .success(result))
                    } catch {
                        return (url, .failure(error))
                    }
                }
            }

            // As each task completes, collect result and enqueue next
            for await (url, result) in group {
                switch result {
                case .success(let processed):
                    if processed { succeeded += 1 }
                case .failure(let error):
                    failed.append((url: url, error: error))
                }

                if let nextURL = iterator.next() {
                    group.addTask {
                        do {
                            let result = try operation(nextURL)
                            return (nextURL, .success(result))
                        } catch {
                            return (nextURL, .failure(error))
                        }
                    }
                }
            }

            return BatchResult(
                succeeded: succeeded,
                failed: failed,
                totalTime: Date().timeIntervalSince(start)
            )
        }
    }

}
