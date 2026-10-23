import Foundation

struct BatchOperationResult: Identifiable, Sendable {
    enum Outcome: Sendable {
        case success
        case partial
        case cancelled
    }

    /// One item that failed outright, with the reason the user needs to act on it.
    struct Failure: Sendable, Hashable {
        /// Name shown in the banner; may carry a qualifier such as "(Secondary)".
        let displayName: String
        /// Bare source filename, used to reveal the source in Finder.
        let filename: String
        /// Human-readable reason, when one is known.
        let reason: String?

        init(displayName: String? = nil, filename: String, reason: String?) {
            self.displayName = displayName ?? filename
            self.filename = filename
            self.reason = reason
        }

        init(filename: String, error: any Error) {
            self.init(filename: filename, reason: error.localizedDescription)
        }
    }

    let id = UUID()
    let title: String
    let outcome: Outcome
    let successCount: Int
    let totalCount: Int
    let failures: [Failure]
    let copyFailureFilenames: [String]
    let overlayFailureFilenames: [String]
    /// Exact paths to private operation-owned artifacts that could not be removed after a
    /// successful commit. The published output remains a success and must not be hidden.
    var cleanupFailurePaths: [String] = []
    /// Files exported from the embedded image rather than the `.xmp` sidecar because the
    /// sidecar looked stale (image file newer and metadata differed). A warning, not a
    /// failure — the file was still published, just from its embedded metadata.
    var staleSidecarFilenames: [String] = []
    let sourceFolderURL: URL?
    /// Files the operation wrote, so the result banner can reveal them in Finder.
    var outputURLs: [URL] = []

    var failedFilenames: [String] { failures.map(\.displayName) }

    var hasFailures: Bool {
        !failedFilenames.isEmpty || !copyFailureFilenames.isEmpty
            || !overlayFailureFilenames.isEmpty || !cleanupFailurePaths.isEmpty
    }

    var hasWarnings: Bool {
        !staleSidecarFilenames.isEmpty
    }

    var summaryLine: String {
        switch outcome {
        case .cancelled:
            return "\(title) cancelled. \(successCount) of \(totalCount) completed."
        case .success:
            return "\(title): \(successCount) of \(totalCount) completed."
        case .partial:
            var parts: [String] = []
            if !failedFilenames.isEmpty {
                let n = failedFilenames.count
                parts.append("\(n) \(n == 1 ? "failure" : "failures")")
            }
            if !copyFailureFilenames.isEmpty {
                let n = copyFailureFilenames.count
                parts.append("metadata copy failed for \(n) \(n == 1 ? "image" : "images")")
            }
            if !overlayFailureFilenames.isEmpty {
                let n = overlayFailureFilenames.count
                parts.append("IPTC overlay failed for \(n) \(n == 1 ? "image" : "images")")
            }
            if !cleanupFailurePaths.isEmpty {
                let n = cleanupFailurePaths.count
                parts.append("\(n) private \(n == 1 ? "staging folder needs" : "staging folders need") cleanup")
            }
            if !staleSidecarFilenames.isEmpty {
                let n = staleSidecarFilenames.count
                parts.append("\(n) \(n == 1 ? "image" : "images") used embedded metadata (.xmp sidecar looked stale)")
            }
            let warning = parts.isEmpty ? "" : ": \(parts.joined(separator: "; "))"
            return "\(title): \(successCount) of \(totalCount)\(warning)."
        }
    }
}
