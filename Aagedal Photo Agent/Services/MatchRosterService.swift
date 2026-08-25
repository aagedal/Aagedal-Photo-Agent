import Foundation
import os.log

nonisolated private let matchRosterLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent",
    category: "MatchRosterService"
)

/// Loads and saves the per-folder `MatchRoster` next to the folder's face data
/// (`<folder>/.face_data/match_roster.json`). On save it embeds the current
/// `Team` snapshots from `RosterStore` so the folder keeps resolving names even
/// if the library team is later edited or deleted.
nonisolated struct MatchRosterService: Sendable {

    private static let fileName = "match_roster.json"

    private func faceDataDirectory(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(FaceDataStorageService.faceDataDirectoryName, isDirectory: true)
    }

    private func fileURL(for folderURL: URL) -> URL {
        faceDataDirectory(for: folderURL).appendingPathComponent(Self.fileName)
    }

    func load(for folderURL: URL) -> MatchRoster? {
        let url = fileURL(for: folderURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(MatchRoster.self, from: data)
        } catch {
            matchRosterLog.error("Failed to decode match roster at \(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    func save(_ roster: MatchRoster) throws {
        let dir = faceDataDirectory(for: roster.folderURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var toSave = roster
        toSave.lastUpdated = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(toSave)
        try data.write(to: fileURL(for: roster.folderURL), options: .atomic)
    }
}
