import Foundation

nonisolated struct ExportDirectoryCommit: Sendable, Equatable {
    let directoryURL: URL
    let cancellationRequestedAfterCommit: Bool
}

/// Immutable evidence for a batch of serialized directory commits. A failed or
/// cancelled batch retains the exact durable prefix so callers never infer that
/// already-created folders disappeared.
nonisolated enum ExportDirectoryBatchResult: Sendable, Equatable {
    case complete(committedDirectoryURLs: [URL])
    case cancelled(committedDirectoryURLs: [URL])
    case failed(committedDirectoryURLs: [URL], message: String)
}

nonisolated struct ExportDirectoryWriter: Sendable {
    let ensureDirectory: @Sendable (URL) throws -> Void

    static let system = ExportDirectoryWriter { url in
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }
}

/// Serializes export destination creation away from the main actor. Foundation directory
/// creation is synchronous and cannot be interrupted after it begins, so a cancellation that
/// arrives during the call is reported alongside the durable commit rather than hiding it.
actor ExportDirectoryService {
    static let shared = ExportDirectoryService()

    private let writer: ExportDirectoryWriter

    init(writer: ExportDirectoryWriter = .system) {
        self.writer = writer
    }

    func ensureDirectory(at url: URL) throws -> ExportDirectoryCommit {
        try Task.checkCancellation()
        try writer.ensureDirectory(url)
        return ExportDirectoryCommit(
            directoryURL: url,
            cancellationRequestedAfterCommit: Task.isCancelled
        )
    }

    /// Commits directories in caller order on the same serialized executor used
    /// by one-off export preparation. Foundation directory creation is
    /// non-preemptible, so cancellation after a commit is represented by the
    /// returned durable prefix rather than by a thrown error that loses it.
    func ensureDirectories(at urls: [URL]) -> ExportDirectoryBatchResult {
        var committedDirectoryURLs: [URL] = []
        committedDirectoryURLs.reserveCapacity(urls.count)

        for url in urls {
            guard !Task.isCancelled else {
                return .cancelled(committedDirectoryURLs: committedDirectoryURLs)
            }

            do {
                try writer.ensureDirectory(url)
                committedDirectoryURLs.append(url)
            } catch {
                return .failed(
                    committedDirectoryURLs: committedDirectoryURLs,
                    message: error.localizedDescription
                )
            }

            guard !Task.isCancelled else {
                return .cancelled(committedDirectoryURLs: committedDirectoryURLs)
            }
        }

        return .complete(committedDirectoryURLs: committedDirectoryURLs)
    }
}
