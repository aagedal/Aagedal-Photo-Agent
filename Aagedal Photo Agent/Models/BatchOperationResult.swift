import Foundation

struct BatchOperationResult: Identifiable, Sendable {
    enum Outcome: Sendable {
        case success
        case partial
        case cancelled
    }

    let id = UUID()
    let title: String
    let outcome: Outcome
    let successCount: Int
    let totalCount: Int
    let failedFilenames: [String]
    let copyFailureFilenames: [String]
    let overlayFailureFilenames: [String]
    /// Files exported from the embedded image rather than the `.xmp` sidecar because the
    /// sidecar looked stale (image file newer and metadata differed). A warning, not a
    /// failure — the file was still published, just from its embedded metadata.
    var staleSidecarFilenames: [String] = []
    let sourceFolderURL: URL?

    var hasFailures: Bool {
        !failedFilenames.isEmpty || !copyFailureFilenames.isEmpty || !overlayFailureFilenames.isEmpty
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
            if !staleSidecarFilenames.isEmpty {
                let n = staleSidecarFilenames.count
                parts.append("\(n) \(n == 1 ? "image" : "images") used embedded metadata (.xmp sidecar looked stale)")
            }
            let warning = parts.isEmpty ? "" : ": \(parts.joined(separator: "; "))"
            return "\(title): \(successCount) of \(totalCount)\(warning)."
        }
    }
}
