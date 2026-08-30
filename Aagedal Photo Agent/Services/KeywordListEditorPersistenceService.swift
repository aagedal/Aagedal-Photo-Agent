import Foundation

nonisolated struct KeywordListEditorLoadSnapshot: Equatable, Sendable {
    let requestID: UUID
    let sourceURL: URL
    let entries: [String]
    let byteCount: Int
}

nonisolated enum KeywordListEditorLoadResult: Equatable, Sendable {
    case loaded(KeywordListEditorLoadSnapshot)
    case missing(requestID: UUID, sourceURL: URL)
    case cancelledBeforeAccess(requestID: UUID)
    case cancelledBeforeRead(requestID: UUID, sourceURL: URL)
    case cancelledAfterRead(requestID: UUID, sourceURL: URL, byteCount: Int)
}

nonisolated struct KeywordListEditorSaveCommit: Equatable, Sendable {
    let requestID: UUID
    let destinationURL: URL
    let entries: [String]
    let byteCount: Int
    /// Coordinated atomic writes cannot be interrupted after they begin. Cancellation observed
    /// afterward therefore describes a durable commit, not an abandoned save.
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum KeywordListEditorSaveResult: Equatable, Sendable {
    case committed(KeywordListEditorSaveCommit)
    case cancelledBeforeCommit(
        requestID: UUID,
        destinationURL: URL,
        entryCount: Int,
        byteCount: Int
    )
}

nonisolated struct KeywordListEditorFileAccess: Sendable {
    let itemExists: @Sendable (URL) -> Bool
    let readData: @Sendable (URL) throws -> Data
    let writeData: @Sendable (Data, URL) throws -> Void

    static let system = KeywordListEditorFileAccess(
        itemExists: { CloudCoordinatedIO.itemExists(at: $0) },
        readData: { try CloudCoordinatedIO.readData(at: $0) },
        writeData: { try CloudCoordinatedIO.writeData($0, to: $1) }
    )
}

/// Owns flat keyword-list editor reads and instant-save commits away from MainActor.
///
/// The actor serializes overlapping loads and writes against iCloud-backed list URLs. Foundation
/// and coordinated filesystem calls are synchronous once entered, so cancellation is sampled only
/// at stable boundaries. A completed write always returns immutable commit evidence, allowing the
/// editor to distinguish a durable older save from the latest result it is allowed to publish.
actor KeywordListEditorPersistenceService {
    static let shared = KeywordListEditorPersistenceService()

    private let access: KeywordListEditorFileAccess

    init(access: KeywordListEditorFileAccess = .system) {
        self.access = access
    }

    func loadEntries(
        from sourceURL: URL,
        requestID: UUID
    ) throws -> KeywordListEditorLoadResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeAccess(requestID: requestID)
        }

        guard access.itemExists(sourceURL) else {
            return .missing(requestID: requestID, sourceURL: sourceURL)
        }
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID, sourceURL: sourceURL)
        }

        let data = try access.readData(sourceURL)
        guard !Task.isCancelled else {
            return .cancelledAfterRead(
                requestID: requestID,
                sourceURL: sourceURL,
                byteCount: data.count
            )
        }

        let text = String(decoding: data, as: UTF8.self)
        return .loaded(KeywordListEditorLoadSnapshot(
            requestID: requestID,
            sourceURL: sourceURL,
            entries: ApprovedListParser.parseString(text, csv: false),
            byteCount: data.count
        ))
    }

    func saveEntries(
        _ entries: [String],
        to destinationURL: URL,
        requestID: UUID
    ) throws -> KeywordListEditorSaveResult {
        let normalized = Self.normalizedEntries(entries)
        let text = normalized.joined(separator: "\n") + (normalized.isEmpty ? "" : "\n")
        let data = Data(text.utf8)

        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(
                requestID: requestID,
                destinationURL: destinationURL,
                entryCount: normalized.count,
                byteCount: data.count
            )
        }

        try access.writeData(data, destinationURL)
        return .committed(KeywordListEditorSaveCommit(
            requestID: requestID,
            destinationURL: destinationURL,
            entries: normalized,
            byteCount: data.count,
            cancellationRequestedAfterCommit: Task.isCancelled
        ))
    }

    private static func normalizedEntries(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            ordered.append(trimmed)
        }
        return ordered
    }
}
