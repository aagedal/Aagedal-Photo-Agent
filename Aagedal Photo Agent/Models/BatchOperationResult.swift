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
    let sourceFolderURL: URL?

    var hasFailures: Bool {
        !failedFilenames.isEmpty || !copyFailureFilenames.isEmpty || !overlayFailureFilenames.isEmpty
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
            let warning = parts.isEmpty ? "" : ": \(parts.joined(separator: "; "))"
            return "\(title): \(successCount) of \(totalCount)\(warning)."
        }
    }
}
