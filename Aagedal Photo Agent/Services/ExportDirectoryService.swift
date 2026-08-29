import Foundation

nonisolated struct ExportDirectoryCommit: Sendable, Equatable {
    let directoryURL: URL
    let cancellationRequestedAfterCommit: Bool
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
}
