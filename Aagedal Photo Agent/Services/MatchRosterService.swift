import Foundation
import os.log

nonisolated private let matchRosterLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent",
    category: "MatchRosterService"
)

nonisolated struct MatchRosterFileIO: Sendable {
    let fileExists: @Sendable (URL) -> Bool
    let readData: @Sendable (URL) throws -> Data
    let createDirectory: @Sendable (URL) throws -> Void
    let writeData: @Sendable (Data, URL, Data.WritingOptions) throws -> Void

    static let system = MatchRosterFileIO(
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        readData: { try Data(contentsOf: $0) },
        createDirectory: {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        },
        writeData: { try $0.write(to: $1, options: $2) }
    )
}

nonisolated struct MatchRosterLoadSnapshot: Sendable {
    let requestID: UUID
    let folderURL: URL
    let roster: MatchRoster?
    let sourceByteCount: Int?
}

nonisolated enum MatchRosterLoadResult: Sendable {
    case cancelledBeforeRead(requestID: UUID, folderURL: URL)
    case cancelledAfterRead(requestID: UUID, folderURL: URL, sourceByteCount: Int?)
    case loaded(MatchRosterLoadSnapshot)
}

nonisolated struct MatchRosterSaveCommit: Equatable, Sendable {
    let requestID: UUID
    let folderURL: URL
    let destinationURL: URL
    let byteCount: Int
    let persistedLastUpdated: Date
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum MatchRosterSaveResult: Equatable, Sendable {
    case cancelledBeforeCommit(requestID: UUID, folderURL: URL)
    case committed(MatchRosterSaveCommit)
}

/// Loads and saves the per-folder `MatchRoster` next to the folder's face data
/// (`<folder>/.face_data/match_roster.json`). The actor keeps synchronous Foundation filesystem
/// calls off MainActor and serializes overlapping reads and writes. Since a Foundation write cannot
/// be preempted safely, callers receive immutable evidence that distinguishes cancellation before a
/// mutation from cancellation observed after an atomic write committed.
actor MatchRosterService {
    static let shared = MatchRosterService()

    private static let fileName = "match_roster.json"
    private let fileIO: MatchRosterFileIO

    init(fileIO: MatchRosterFileIO = .system) {
        self.fileIO = fileIO
    }

    private func faceDataDirectory(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(FaceDataStorageService.faceDataDirectoryName, isDirectory: true)
    }

    private func fileURL(for folderURL: URL) -> URL {
        faceDataDirectory(for: folderURL).appendingPathComponent(Self.fileName)
    }

    func load(for folderURL: URL, requestID: UUID) -> MatchRosterLoadResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID, folderURL: folderURL)
        }

        let url = fileURL(for: folderURL)
        guard fileIO.fileExists(url) else {
            guard !Task.isCancelled else {
                return .cancelledAfterRead(
                    requestID: requestID,
                    folderURL: folderURL,
                    sourceByteCount: nil
                )
            }
            return .loaded(MatchRosterLoadSnapshot(
                requestID: requestID,
                folderURL: folderURL,
                roster: nil,
                sourceByteCount: nil
            ))
        }
        do {
            let data = try fileIO.readData(url)
            guard !Task.isCancelled else {
                return .cancelledAfterRead(
                    requestID: requestID,
                    folderURL: folderURL,
                    sourceByteCount: data.count
                )
            }
            let roster = try JSONDecoder().decode(MatchRoster.self, from: data)
            return .loaded(MatchRosterLoadSnapshot(
                requestID: requestID,
                folderURL: folderURL,
                roster: roster,
                sourceByteCount: data.count
            ))
        } catch {
            if Task.isCancelled {
                return .cancelledAfterRead(
                    requestID: requestID,
                    folderURL: folderURL,
                    sourceByteCount: nil
                )
            }
            matchRosterLog.error("Failed to decode match roster at \(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return .loaded(MatchRosterLoadSnapshot(
                requestID: requestID,
                folderURL: folderURL,
                roster: nil,
                sourceByteCount: nil
            ))
        }
    }

    func save(_ roster: MatchRoster, requestID: UUID) throws -> MatchRosterSaveResult {
        var toSave = roster
        toSave.lastUpdated = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(toSave)

        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID, folderURL: roster.folderURL)
        }

        let directory = faceDataDirectory(for: roster.folderURL)
        let destination = fileURL(for: roster.folderURL)
        try fileIO.createDirectory(directory)
        try fileIO.writeData(data, destination, .atomic)

        return .committed(MatchRosterSaveCommit(
            requestID: requestID,
            folderURL: roster.folderURL,
            destinationURL: destination,
            byteCount: data.count,
            persistedLastUpdated: toSave.lastUpdated,
            cancellationRequestedAfterCommit: Task.isCancelled
        ))
    }
}
