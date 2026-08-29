import Foundation

nonisolated struct AnalysisExportCommit: Equatable, Sendable {
    let requestID: UUID
    let destinationURL: URL
    let byteCount: Int
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum AnalysisExportWriteResult: Equatable, Sendable {
    case committed(AnalysisExportCommit)
    case cancelledBeforeWrite(requestID: UUID)
}

nonisolated struct AnalysisExportFileWriter: Sendable {
    let write: @Sendable (Data, URL) throws -> Void

    static let system = AnalysisExportFileWriter { data, destination in
        try data.write(to: destination, options: .atomic)
    }
}

/// Serializes the final filesystem commit for Analysis PDF and JPEG exports away from MainActor.
/// Rendering remains independently cancellable; once an atomic write has committed, the immutable
/// result reports that fact even if cancellation arrived during the synchronous Foundation call.
actor AnalysisExportFileService {
    static let shared = AnalysisExportFileService()

    private let writer: AnalysisExportFileWriter

    init(writer: AnalysisExportFileWriter = .system) {
        self.writer = writer
    }

    func write(
        _ data: Data,
        to destination: URL,
        requestID: UUID
    ) throws -> AnalysisExportWriteResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeWrite(requestID: requestID)
        }

        try writer.write(data, destination)
        return .committed(AnalysisExportCommit(
            requestID: requestID,
            destinationURL: destination,
            byteCount: data.count,
            cancellationRequestedAfterCommit: Task.isCancelled
        ))
    }
}
