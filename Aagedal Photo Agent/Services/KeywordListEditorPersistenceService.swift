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

nonisolated struct QuickListMutationCommit: Equatable, Sendable {
    let requestID: UUID
    let destinationURL: URL
    let entries: [String]
    let addedEntries: [String]
    let byteCount: Int
    /// Coordinated writes are non-preemptible after entry. A cancelled caller must still publish
    /// this durable mutation so every list observer invalidates its in-memory snapshot.
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum QuickListMutationResult: Equatable, Sendable {
    /// The managed list has not been created yet. Callers may present the existing first-use file
    /// picker without performing a synchronous existence probe on MainActor.
    case missingDestination(requestID: UUID, destinationURL: URL)
    case committed(QuickListMutationCommit)
    case unchanged(requestID: UUID, destinationURL: URL, entries: [String])
    case cancelledBeforeAccess(requestID: UUID)
    case cancelledAfterRead(
        requestID: UUID,
        destinationURL: URL,
        byteCount: Int
    )
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
    let startAccessingSecurityScopedResource: @Sendable (URL) -> Bool
    let stopAccessingSecurityScopedResource: @Sendable (URL) -> Void

    init(
        itemExists: @escaping @Sendable (URL) -> Bool,
        readData: @escaping @Sendable (URL) throws -> Data,
        writeData: @escaping @Sendable (Data, URL) throws -> Void,
        startAccessingSecurityScopedResource: @escaping @Sendable (URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        stopAccessingSecurityScopedResource: @escaping @Sendable (URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        }
    ) {
        self.itemExists = itemExists
        self.readData = readData
        self.writeData = writeData
        self.startAccessingSecurityScopedResource = startAccessingSecurityScopedResource
        self.stopAccessingSecurityScopedResource = stopAccessingSecurityScopedResource
    }

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

    /// Appends values to an existing managed Quick List, or imports a user-selected first-use
    /// file before appending. The read/merge/write transaction shares this actor with editor
    /// saves, preventing an editor save and a Caption-panel append from overwriting each other.
    func appendEntries(
        _ entries: [String],
        to destinationURL: URL,
        importing sourceURL: URL? = nil,
        createDestinationIfMissing: Bool = false,
        requestID: UUID
    ) throws -> QuickListMutationResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeAccess(requestID: requestID)
        }

        let importedData: Data?
        var destinationExists = false
        if let sourceURL {
            let didStart = access.startAccessingSecurityScopedResource(sourceURL)
            defer {
                if didStart {
                    access.stopAccessingSecurityScopedResource(sourceURL)
                }
            }
            importedData = try access.readData(sourceURL)
            guard !Task.isCancelled else {
                return .cancelledAfterRead(
                    requestID: requestID,
                    destinationURL: destinationURL,
                    byteCount: importedData?.count ?? 0
                )
            }
        } else {
            destinationExists = access.itemExists(destinationURL)
            guard destinationExists || createDestinationIfMissing else {
                return .missingDestination(
                    requestID: requestID,
                    destinationURL: destinationURL
                )
            }
            guard !Task.isCancelled else {
                return .cancelledAfterRead(
                    requestID: requestID,
                    destinationURL: destinationURL,
                    byteCount: 0
                )
            }
            importedData = nil
        }

        let existing: [String]
        if let importedData, let sourceURL {
            guard importedData.count <= ApprovedListParser.maxFileSizeBytes else {
                throw ApprovedListParserError.fileTooLarge(
                    bytes: Int64(importedData.count),
                    limit: ApprovedListParser.maxFileSizeBytes
                )
            }
            existing = try ApprovedListParser.parse(
                importedData,
                csv: sourceURL.pathExtension.lowercased() == "csv"
            )
        } else if destinationExists {
            let existingData = try access.readData(destinationURL)
            guard !Task.isCancelled else {
                return .cancelledAfterRead(
                    requestID: requestID,
                    destinationURL: destinationURL,
                    byteCount: existingData.count
                )
            }
            existing = ApprovedListParser.parseString(
                String(decoding: existingData, as: UTF8.self),
                csv: false
            )
        } else {
            existing = []
        }
        let incoming = Self.normalizedEntries(entries)
        var seen = Set(existing)
        let added = incoming.filter { seen.insert($0).inserted }
        let combined = existing + added

        // An import replaces the managed list even when it adds no new values. Without an import,
        // avoiding a no-op write preserves the former best-effort append behavior.
        guard sourceURL != nil || !added.isEmpty else {
            return .unchanged(
                requestID: requestID,
                destinationURL: destinationURL,
                entries: existing
            )
        }

        let text = combined.joined(separator: "\n") + (combined.isEmpty ? "" : "\n")
        let data = Data(text.utf8)
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(
                requestID: requestID,
                destinationURL: destinationURL,
                entryCount: combined.count,
                byteCount: data.count
            )
        }

        try access.writeData(data, destinationURL)
        return .committed(QuickListMutationCommit(
            requestID: requestID,
            destinationURL: destinationURL,
            entries: combined,
            addedEntries: added,
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
