import Foundation
import os.log

private let rosterLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent",
    category: "RosterStore"
)

extension Notification.Name {
    /// Posted whenever the Teams library changes (local edit or remote sync).
    static let teamsLibraryDidChange = Notification.Name("teamsLibraryDidChange")
}

/// Global, optionally iCloud-synced library of teams (name, kit colour, roster).
///
/// Mirrors `KnownPeopleService`'s per-record store: one `<uuid>.json` per team
/// under `teams/`, with `<uuid>.deleted` tombstones, self-write filtering, and
/// per-file conflict resolution — all routed through `CloudCoordinatedIO` so the
/// iCloud daemon can't fork the folder into "Teams 2". Leaner than Known People
/// (teams are few and edited by hand, so whole-record newest-wins merging is
/// enough — no embedding union).
///
/// `@Observable` so SwiftUI editors bind to `teams` directly; a notification is
/// also posted for any imperative listeners.
@MainActor
@Observable
final class RosterStore {

    static let shared = RosterStore()

    /// The current teams, sorted by name. Source of truth is the on-disk files;
    /// this is the in-memory listing, refreshed lazily and on remote changes.
    private(set) var teams: [Team] = []

    /// Test-only seam: overrides the resolved storage root so tests can point at
    /// a temp directory. Production never sets this.
    @ObservationIgnored static var storageOverrideURL: URL?
    @ObservationIgnored static var deletionIO = DurableDeletionIO.live

    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var cachedDirectory: URL?
    @ObservationIgnored private var recentLocalWrites: [String: Date] = [:]

    private static let selfWriteWindow: TimeInterval = 10
    private static let selfWriteTolerance: TimeInterval = 3
    private static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60

    private init() {}

    // MARK: - Storage paths

    /// Local fallback: `<App Support>/Aagedal Photo Agent/Teams`.
    nonisolated static var localTeamsDirectory: URL {
        AppPaths.applicationSupport.appendingPathComponent("Teams", isDirectory: true)
    }

    private var teamsRootDirectory: URL {
        if let cached = cachedDirectory { return cached }
        let url: URL
        if let override = Self.storageOverrideURL {
            url = override
        } else if UserDefaults.standard.bool(forKey: UserDefaultsKeys.teamsICloudEnabled),
                  let cloud = AppPaths.iCloudTeamsURL {
            url = cloud
        } else {
            url = Self.localTeamsDirectory
        }
        try? CloudCoordinatedIO.ensureDirectory(url)
        try? CloudCoordinatedIO.ensureDirectory(url.appendingPathComponent("teams", isDirectory: true))
        cachedDirectory = url
        return url
    }

    private var teamsDirectory: URL {
        teamsRootDirectory.appendingPathComponent("teams", isDirectory: true)
    }

    private func teamFileURL(for id: UUID) -> URL {
        teamsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func tombstoneURL(for id: UUID) -> URL {
        teamsDirectory.appendingPathComponent("\(id.uuidString).deleted")
    }

    private func teamID(fromFileURL url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Self-write filtering

    private func stampLocalWrite(_ url: URL) {
        let now = Date()
        recentLocalWrites[url.standardizedFileURL.path] = now
        recentLocalWrites = recentLocalWrites.filter { now.timeIntervalSince($0.value) < Self.selfWriteWindow }
    }

    /// Whether a remote-change notification is just an echo of our own write.
    func shouldSkipRemoteReload(path: String, contentChangeDate: Date?) -> Bool {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let stamped = recentLocalWrites[key] else { return false }
        if Date().timeIntervalSince(stamped) >= Self.selfWriteWindow {
            recentLocalWrites[key] = nil
            return false
        }
        guard let changeDate = contentChangeDate else { return true }
        return abs(changeDate.timeIntervalSince(stamped)) <= Self.selfWriteTolerance
    }

    // MARK: - Load

    /// Drops in-memory state and re-reads from disk. Called after the backing
    /// directory changes (iCloud toggle).
    func reloadAfterStorageChange() {
        cachedDirectory = nil
        didLoad = false
        ensureLoaded()
        NotificationCenter.default.post(name: .teamsLibraryDidChange, object: nil)
    }

    /// Loads the library from disk once. The directory listing *is* the library.
    private func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true

        let entries = (try? CloudCoordinatedIO.contentsOfDirectory(at: teamsDirectory)) ?? []
        let tombstoned = collectTombstones(in: entries)

        var loaded: [Team] = []
        for url in entries where url.pathExtension == "json" {
            guard let team = loadTeamFile(at: url) else { continue }
            if tombstoned.contains(team.id) {
                try? CloudCoordinatedIO.removeItem(at: url)
                continue
            }
            loaded.append(team)
        }
        teams = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Public accessor that guarantees the library is loaded.
    func allTeams() -> [Team] {
        ensureLoaded()
        return teams
    }

    func team(byID id: UUID) -> Team? {
        ensureLoaded()
        return teams.first { $0.id == id }
    }

    private func loadTeamFile(at url: URL) -> Team? {
        if let resolved = resolveConflicts(at: url) {
            return resolved
        }
        do {
            let data = try CloudCoordinatedIO.readData(at: url)
            return try JSONDecoder().decode(Team.self, from: data)
        } catch {
            rosterLog.error("Failed to load team file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            backupCorruptFile(at: url)
            return nil
        }
    }

    private func backupCorruptFile(at url: URL) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt.\(timestamp)")
        if let corrupt = try? CloudCoordinatedIO.readData(at: url) {
            try? CloudCoordinatedIO.writeData(corrupt, to: backupURL)
        }
    }

    // MARK: - Write

    private func writeTeam(_ team: Team) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(team)
        let url = teamFileURL(for: team.id)
        try CloudCoordinatedIO.writeData(data, to: url)
        stampLocalWrite(url)
    }

    private func sortAndNotify() {
        teams.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        NotificationCenter.default.post(name: .teamsLibraryDidChange, object: nil)
    }

    // MARK: - CRUD

    /// Insert a new team or overwrite an existing one with the same id.
    func upsert(_ team: Team) throws {
        ensureLoaded()
        var updated = team
        updated.updatedAt = Date()
        try writeTeam(updated)
        if let index = teams.firstIndex(where: { $0.id == updated.id }) {
            teams[index] = updated
        } else {
            teams.append(updated)
        }
        sortAndNotify()
    }

    func delete(id: UUID) throws {
        ensureLoaded()
        let marker = TeamTombstone(id: id, deletedAt: Date())
        let markerURL = tombstoneURL(for: id)
        try DurableDeletionTransaction.execute(
            marker: marker,
            markerURL: markerURL,
            recordURL: teamFileURL(for: id),
            markerMatches: { $0.id == id },
            io: Self.deletionIO
        )
        stampLocalWrite(markerURL)
        teams.removeAll { $0.id == id }
        NotificationCenter.default.post(name: .teamsLibraryDidChange, object: nil)
    }

    // MARK: - Roster bridge

    /// Stamp a Known-People link onto a roster entry (the face↔number bridge),
    /// persisting the change. No-op if the team or player is gone.
    func linkKnownPerson(_ knownPersonID: UUID, toPlayerNumber number: Int, teamID: UUID) throws {
        ensureLoaded()
        guard var team = team(byID: teamID),
              let playerIndex = team.roster.firstIndex(where: { $0.number == number }) else { return }
        team.roster[playerIndex].knownPersonID = knownPersonID
        try upsert(team)
    }

    // MARK: - Tombstones

    private func collectTombstones(in entries: [URL]) -> Set<UUID> {
        let decoder = JSONDecoder()
        let now = Date()
        var tombstoned = Set<UUID>()
        for url in entries where url.pathExtension == "deleted" {
            guard let data = try? CloudCoordinatedIO.readData(at: url),
                  let tombstone = try? decoder.decode(TeamTombstone.self, from: data) else {
                if let id = teamID(fromFileURL: url) {
                    tombstoned.insert(id)
                } else {
                    try? CloudCoordinatedIO.removeItem(at: url)
                }
                continue
            }
            if now.timeIntervalSince(tombstone.deletedAt) >= Self.tombstoneRetention {
                try? CloudCoordinatedIO.removeItem(at: url)
            } else {
                tombstoned.insert(tombstone.id)
            }
        }
        return tombstoned
    }

    // MARK: - Conflict resolution

    /// Resolve iCloud conflict versions by keeping the record with the newest
    /// `updatedAt`, rewriting the file and clearing the versions. No-op locally.
    private func resolveConflicts(at url: URL) -> Team? {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflicts.isEmpty else {
            return nil
        }
        let decoder = JSONDecoder()
        var records: [Team] = []
        if let currentData = try? CloudCoordinatedIO.readData(at: url),
           let current = try? decoder.decode(Team.self, from: currentData) {
            records.append(current)
        }
        for version in conflicts {
            if let data = try? Data(contentsOf: version.url),
               let team = try? decoder.decode(Team.self, from: data) {
                records.append(team)
            }
        }
        guard let merged = records.max(by: { $0.updatedAt < $1.updatedAt }) else {
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
            return nil
        }
        do {
            try writeTeam(merged)
            for version in conflicts { version.isResolved = true }
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
        } catch {
            rosterLog.error("Failed to resolve conflicts for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return merged
    }

    // MARK: - Remote changes

    /// Applies remote changes to individual team files from the iCloud watcher.
    func applyRemoteChanges(_ changes: [(url: URL, contentChangeDate: Date?)]) {
        ensureLoaded()
        var didChange = false
        for change in changes {
            let url = change.url
            guard !shouldSkipRemoteReload(path: url.path, contentChangeDate: change.contentChangeDate) else { continue }
            guard let id = teamID(fromFileURL: url) else { continue }

            if url.pathExtension == "deleted" {
                if teams.contains(where: { $0.id == id }) {
                    teams.removeAll { $0.id == id }
                    didChange = true
                }
                try? CloudCoordinatedIO.removeItem(at: teamFileURL(for: id))
                continue
            }
            guard url.pathExtension == "json" else { continue }

            if CloudCoordinatedIO.itemExists(at: tombstoneURL(for: id)) {
                try? CloudCoordinatedIO.removeItem(at: url)
                continue
            }
            if let team = loadTeamFile(at: url) {
                if let index = teams.firstIndex(where: { $0.id == team.id }) {
                    teams[index] = team
                } else {
                    teams.append(team)
                }
                didChange = true
            } else if !CloudCoordinatedIO.itemExists(at: url) {
                if teams.contains(where: { $0.id == id }) {
                    teams.removeAll { $0.id == id }
                    didChange = true
                }
            }
        }
        if didChange { sortAndNotify() }
    }
}

/// Deletion marker so a delete propagates over iCloud and can't be resurrected
/// by a peer that still holds the team.
nonisolated struct TeamTombstone: Codable, Sendable {
    let id: UUID
    let deletedAt: Date
}
