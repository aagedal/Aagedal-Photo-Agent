import Foundation

nonisolated struct TeamRosterExportArtifact: Equatable, Sendable {
    let id: UUID
    let data: Data
    let destinationURL: URL
    let writingOptions: Data.WritingOptions

    init(
        id: UUID = UUID(),
        data: Data,
        destinationURL: URL,
        writingOptions: Data.WritingOptions = []
    ) {
        self.id = id
        self.data = data
        self.destinationURL = destinationURL
        self.writingOptions = writingOptions
    }
}

nonisolated struct TeamRosterExportCommit: Equatable, Sendable {
    let artifactID: UUID
    let destinationURL: URL
    let byteCount: Int
    let cancellationRequestedAfterCommit: Bool
}

nonisolated struct TeamRosterExportFailure: Equatable, Sendable {
    let artifactID: UUID
    let destinationURL: URL
    let errorDomain: String
    let errorCode: Int
    let message: String
    let failureReason: String?
    let recoverySuggestion: String?

    var nsError: NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let failureReason { userInfo[NSLocalizedFailureReasonErrorKey] = failureReason }
        if let recoverySuggestion { userInfo[NSLocalizedRecoverySuggestionErrorKey] = recoverySuggestion }
        return NSError(domain: errorDomain, code: errorCode, userInfo: userInfo)
    }
}

nonisolated enum TeamRosterExportArtifactResult: Equatable, Sendable {
    case committed(TeamRosterExportCommit)
    case failed(TeamRosterExportFailure)
    case cancelledBeforeWrite(artifactID: UUID, destinationURL: URL)
}

/// Immutable evidence for every artifact in an export request. A batch can therefore report
/// commits that happened before a later failure or cancellation without implying a rollback.
nonisolated struct TeamRosterExportEvidence: Equatable, Sendable {
    let requestID: UUID
    let results: [TeamRosterExportArtifactResult]

    var committedCount: Int {
        results.reduce(into: 0) { count, result in
            if case .committed = result { count += 1 }
        }
    }

    var failedCount: Int {
        results.reduce(into: 0) { count, result in
            if case .failed = result { count += 1 }
        }
    }

    var cancelledCount: Int {
        results.reduce(into: 0) { count, result in
            if case .cancelledBeforeWrite = result { count += 1 }
        }
    }

    var isPartialSuccess: Bool {
        committedCount > 0 && committedCount < results.count
    }
}

nonisolated struct TeamRosterExportWriter: Sendable {
    let write: @Sendable (Data, URL, Data.WritingOptions) throws -> Void

    static let system = TeamRosterExportWriter { data, destination, options in
        try data.write(to: destination, options: options)
    }
}

/// Serializes user-selected team roster exports away from MainActor. Foundation writes cannot be
/// preempted safely, so cancellation is checked before every artifact and is recorded after any
/// already-committed write rather than obscuring the durable filesystem result.
actor TeamRosterExportService {
    static let shared = TeamRosterExportService()

    // Run the original task on a retained Dispatch worker so blocking provider I/O does not
    // occupy the cooperative pool, while task locals and cancellation remain intact.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    private let writer: TeamRosterExportWriter

    init(
        writer: TeamRosterExportWriter = .system,
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.team-roster-export", qos: .utility
        )
    ) {
        self.writer = writer
        self.filesystemQueue = filesystemQueue
    }

    func export(
        _ artifacts: [TeamRosterExportArtifact],
        requestID: UUID
    ) -> TeamRosterExportEvidence {
        var results: [TeamRosterExportArtifactResult] = []
        results.reserveCapacity(artifacts.count)

        for (index, artifact) in artifacts.enumerated() {
            guard !Task.isCancelled else {
                results.append(contentsOf: artifacts[index...].map {
                    .cancelledBeforeWrite(artifactID: $0.id, destinationURL: $0.destinationURL)
                })
                break
            }

            do {
                try writer.write(artifact.data, artifact.destinationURL, artifact.writingOptions)
                results.append(.committed(TeamRosterExportCommit(
                    artifactID: artifact.id,
                    destinationURL: artifact.destinationURL,
                    byteCount: artifact.data.count,
                    cancellationRequestedAfterCommit: Task.isCancelled
                )))
            } catch {
                let nsError = error as NSError
                results.append(.failed(TeamRosterExportFailure(
                    artifactID: artifact.id,
                    destinationURL: artifact.destinationURL,
                    errorDomain: nsError.domain,
                    errorCode: nsError.code,
                    message: nsError.localizedDescription,
                    failureReason: nsError.localizedFailureReason,
                    recoverySuggestion: nsError.localizedRecoverySuggestion
                )))
            }
        }

        return TeamRosterExportEvidence(requestID: requestID, results: results)
    }
}
