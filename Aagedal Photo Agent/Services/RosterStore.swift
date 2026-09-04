import Foundation
import os.log

nonisolated private let rosterLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent",
    category: "RosterStore"
)

extension Notification.Name {
    /// Posted whenever the Teams library changes (local edit or remote sync).
    static let teamsLibraryDidChange = Notification.Name("teamsLibraryDidChange")
}

nonisolated struct TeamTombstone: Codable, Sendable {
    let id: UUID
    let deletedAt: Date
}

nonisolated struct RosterLibrarySnapshot: Sendable {
    let requestID: UUID
    let teams: [Team]
    let inspectedEntryCount: Int
    /// Cleanup can durably remove expired tombstones, corrupt filenames, or records shadowed
    /// by tombstones even when cancellation prevents publication of the final snapshot.
    let cleanupCommitURLs: [URL]
}

nonisolated enum RosterLibraryLoadResult: Sendable {
    case loaded(RosterLibrarySnapshot)
    case cancelledBeforeAccess(requestID: UUID)
    case cancelledAfterPrefix(
        requestID: UUID,
        inspectedEntryCount: Int,
        cleanupCommitURLs: [URL]
    )
}

nonisolated struct RosterLibraryUpsertCommit: Sendable {
    let requestID: UUID
    let team: Team
    let recordURL: URL
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum RosterLibraryUpsertResult: Sendable {
    case committed(RosterLibraryUpsertCommit)
    case cancelledBeforeCommit(requestID: UUID)
}

nonisolated struct RosterLibraryDeleteCommit: Sendable {
    let requestID: UUID
    let teamID: UUID
    let markerURL: URL
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum RosterLibraryDeleteResult: Sendable {
    case committed(RosterLibraryDeleteCommit)
    case cancelledBeforeCommit(requestID: UUID, teamID: UUID)
}

nonisolated struct RosterLibraryFileAccess: @unchecked Sendable {
    let ensureDirectory: @Sendable (URL) throws -> Void
    let contentsOfDirectory: @Sendable (URL) throws -> [URL]
    let readData: @Sendable (URL) throws -> Data
    let writeData: @Sendable (Data, URL) throws -> Void
    let removeItem: @Sendable (URL) throws -> Void

    static let system = RosterLibraryFileAccess(
        ensureDirectory: { try CloudCoordinatedIO.ensureDirectory($0) },
        contentsOfDirectory: { try CloudCoordinatedIO.contentsOfDirectory(at: $0) },
        readData: { try CloudCoordinatedIO.readData(at: $0) },
        writeData: { try CloudCoordinatedIO.writeData($0, to: $1) },
        removeItem: { try CloudCoordinatedIO.removeItem(at: $0) }
    )
}

/// Owns every coordinated Teams-library filesystem operation. Its immutable results are the
/// only values published by ``RosterStore`` on MainActor. Foundation coordination is not
/// preemptible, so each mutation result records whether cancellation arrived after durability.
actor RosterLibraryPersistenceService {
    static let shared = RosterLibraryPersistenceService()

    private let access: RosterLibraryFileAccess
    private let deletionIO: DurableDeletionIO?
    private let now: @Sendable () -> Date

    private static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60

    init(
        access: RosterLibraryFileAccess = .system,
        deletionIO: DurableDeletionIO? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.access = access
        self.deletionIO = deletionIO
        self.now = now
    }

    func load(from rootDirectory: URL, requestID: UUID) -> RosterLibraryLoadResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeAccess(requestID: requestID)
        }

        let directory = teamsDirectory(in: rootDirectory)
        do {
            try access.ensureDirectory(rootDirectory)
            try access.ensureDirectory(directory)
        } catch {
            rosterLog.error("Failed to prepare Teams library: \(error.localizedDescription, privacy: .private)")
            return .loaded(RosterLibrarySnapshot(
                requestID: requestID,
                teams: [],
                inspectedEntryCount: 0,
                cleanupCommitURLs: []
            ))
        }
        guard !Task.isCancelled else {
            return .cancelledAfterPrefix(
                requestID: requestID,
                inspectedEntryCount: 0,
                cleanupCommitURLs: []
            )
        }

        let entries: [URL]
        do {
            entries = try access.contentsOfDirectory(directory)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            rosterLog.error("Failed to enumerate Teams library: \(error.localizedDescription, privacy: .private)")
            return .loaded(RosterLibrarySnapshot(
                requestID: requestID,
                teams: [],
                inspectedEntryCount: 0,
                cleanupCommitURLs: []
            ))
        }

        var inspected = 0
        var cleanupCommits: [URL] = []
        var tombstoned = Set<UUID>()
        let decoder = JSONDecoder()

        for url in entries where url.pathExtension == "deleted" {
            guard !Task.isCancelled else {
                return .cancelledAfterPrefix(
                    requestID: requestID,
                    inspectedEntryCount: inspected,
                    cleanupCommitURLs: cleanupCommits
                )
            }
            inspected += 1
            guard let data = try? access.readData(url),
                  let tombstone = try? decoder.decode(TeamTombstone.self, from: data) else {
                if let id = teamID(fromFileURL: url) {
                    tombstoned.insert(id)
                } else if removeIfPresent(url) {
                    cleanupCommits.append(url)
                }
                continue
            }
            if now().timeIntervalSince(tombstone.deletedAt) >= Self.tombstoneRetention {
                if removeIfPresent(url) { cleanupCommits.append(url) }
            } else {
                tombstoned.insert(tombstone.id)
            }
        }

        var loaded: [Team] = []
        for url in entries where url.pathExtension == "json" {
            guard !Task.isCancelled else {
                return .cancelledAfterPrefix(
                    requestID: requestID,
                    inspectedEntryCount: inspected,
                    cleanupCommitURLs: cleanupCommits
                )
            }
            inspected += 1
            guard let id = teamID(fromFileURL: url) else { continue }
            if tombstoned.contains(id) {
                if removeIfPresent(url) { cleanupCommits.append(url) }
                continue
            }
            if let team = loadTeamFile(at: url, cleanupCommits: &cleanupCommits) {
                loaded.append(team)
            }
        }

        guard !Task.isCancelled else {
            return .cancelledAfterPrefix(
                requestID: requestID,
                inspectedEntryCount: inspected,
                cleanupCommitURLs: cleanupCommits
            )
        }
        loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return .loaded(RosterLibrarySnapshot(
            requestID: requestID,
            teams: loaded,
            inspectedEntryCount: inspected,
            cleanupCommitURLs: cleanupCommits
        ))
    }

    func upsert(
        _ team: Team,
        in rootDirectory: URL,
        requestID: UUID
    ) throws -> RosterLibraryUpsertResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID)
        }
        let directory = teamsDirectory(in: rootDirectory)
        try access.ensureDirectory(rootDirectory)
        try access.ensureDirectory(directory)
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID)
        }

        let recordURL = teamFileURL(for: team.id, in: directory)
        try writeTeam(team, to: recordURL)
        return .committed(RosterLibraryUpsertCommit(
            requestID: requestID,
            team: team,
            recordURL: recordURL,
            cancellationRequestedAfterCommit: Task.isCancelled
        ))
    }

    func delete(
        teamID: UUID,
        in rootDirectory: URL,
        requestID: UUID,
        io overrideIO: DurableDeletionIO? = nil
    ) throws -> RosterLibraryDeleteResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID, teamID: teamID)
        }
        let directory = teamsDirectory(in: rootDirectory)
        try access.ensureDirectory(rootDirectory)
        try access.ensureDirectory(directory)
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID, teamID: teamID)
        }

        let marker = TeamTombstone(id: teamID, deletedAt: now())
        let markerURL = tombstoneURL(for: teamID, in: directory)
        let recordURL = teamFileURL(for: teamID, in: directory)
        try DurableDeletionTransaction.execute(
            marker: marker,
            markerURL: markerURL,
            recordURL: recordURL,
            markerMatches: { $0.id == teamID },
            io: overrideIO ?? deletionIO ?? .live
        )
        return .committed(RosterLibraryDeleteCommit(
            requestID: requestID,
            teamID: teamID,
            markerURL: markerURL,
            cancellationRequestedAfterCommit: Task.isCancelled
        ))
    }

    private func teamsDirectory(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("teams", isDirectory: true)
    }

    private func teamFileURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func tombstoneURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).deleted")
    }

    private func teamID(fromFileURL url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    private func removeIfPresent(_ url: URL) -> Bool {
        do {
            try access.removeItem(url)
            return true
        } catch {
            rosterLog.error("Failed to clean Teams item \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func loadTeamFile(at url: URL, cleanupCommits: inout [URL]) -> Team? {
        if let resolved = resolveConflicts(at: url, cleanupCommits: &cleanupCommits) {
            return resolved
        }
        do {
            let data = try access.readData(url)
            return try JSONDecoder().decode(Team.self, from: data)
        } catch {
            rosterLog.error("Failed to load team file \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            backupCorruptFile(at: url, cleanupCommits: &cleanupCommits)
            return nil
        }
    }

    private func backupCorruptFile(at url: URL, cleanupCommits: inout [URL]) {
        let timestamp = ISO8601DateFormatter().string(from: now())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt.\(timestamp)")
        guard let corrupt = try? access.readData(url) else { return }
        do {
            try access.writeData(corrupt, backupURL)
            cleanupCommits.append(backupURL)
        } catch {
            rosterLog.error("Failed to back up corrupt team file: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func writeTeam(_ team: Team, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try access.writeData(try encoder.encode(team), url)
    }

    /// Conflict versions are inspected and rewritten on this actor, never by the UI owner.
    private func resolveConflicts(at url: URL, cleanupCommits: inout [URL]) -> Team? {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflicts.isEmpty else {
            return nil
        }
        let decoder = JSONDecoder()
        var records: [Team] = []
        if let currentData = try? access.readData(url),
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
            try writeTeam(merged, to: url)
            cleanupCommits.append(url)
            for version in conflicts { version.isResolved = true }
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
        } catch {
            rosterLog.error("Failed to resolve conflicts for \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
        return merged
    }
}

/// Global, optionally iCloud-synced library of teams (name, kit colour, roster).
///
/// The observable object owns only UI-facing state and request identity. Directory scans,
/// coordinated reads/writes, tombstone cleanup, and conflict resolution are serialized by
/// ``RosterLibraryPersistenceService`` away from MainActor.
@MainActor
@Observable
final class RosterStore {

    static let shared = RosterStore()

    private(set) var teams: [Team] = []

    @ObservationIgnored static var storageOverrideURL: URL?
    @ObservationIgnored static var deletionIO = DurableDeletionIO.live

    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var cachedDirectory: URL?
    @ObservationIgnored private var recentLocalWrites: [String: Date] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadRequestID = UUID()
    @ObservationIgnored private let persistence: RosterLibraryPersistenceService
    @ObservationIgnored private let injectedStorageRoot: URL?
    @ObservationIgnored private let injectedDeletionIO: DurableDeletionIO?

    private static let selfWriteWindow: TimeInterval = 10
    private static let selfWriteTolerance: TimeInterval = 3

    init(
        persistence: RosterLibraryPersistenceService = .shared,
        storageRoot: URL? = nil,
        deletionIO: DurableDeletionIO? = nil
    ) {
        self.persistence = persistence
        injectedStorageRoot = storageRoot
        injectedDeletionIO = deletionIO
    }

    nonisolated static var localTeamsDirectory: URL {
        AppPaths.applicationSupport.appendingPathComponent("Teams", isDirectory: true)
    }

    private var teamsRootDirectory: URL {
        if let cachedDirectory { return cachedDirectory }
        let url: URL
        if let injectedStorageRoot {
            url = injectedStorageRoot
        } else if let override = Self.storageOverrideURL {
            url = override
        } else if UserDefaults.standard.bool(forKey: UserDefaultsKeys.teamsICloudEnabled),
                  let cloud = AppPaths.iCloudTeamsURL {
            url = cloud
        } else {
            url = Self.localTeamsDirectory
        }
        cachedDirectory = url
        return url
    }

    private func stampLocalWrite(_ url: URL) {
        let now = Date()
        recentLocalWrites[url.standardizedFileURL.path] = now
        recentLocalWrites = recentLocalWrites.filter {
            now.timeIntervalSince($0.value) < Self.selfWriteWindow
        }
    }

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

    /// Re-resolves the selected local/iCloud root and asynchronously replaces the full library.
    func reloadAfterStorageChange(resolvedStorageURL: URL? = nil) async {
        cachedDirectory = resolvedStorageURL
        didLoad = false
        loadTask?.cancel()
        loadTask = nil
        await loadIfNeeded()
    }

    func loadIfNeeded() async {
        if didLoad { return }
        if let loadTask {
            await loadTask.value
            return
        }

        let requestID = UUID()
        loadRequestID = requestID
        let root = teamsRootDirectory
        let task = Task { @MainActor [weak self, persistence] in
            let result = await persistence.load(from: root, requestID: requestID)
            guard let self, self.loadRequestID == requestID else { return }
            self.loadTask = nil
            switch result {
            case .loaded(let snapshot) where snapshot.requestID == requestID:
                snapshot.cleanupCommitURLs.forEach(self.stampLocalWrite)
                self.teams = snapshot.teams
                self.didLoad = true
                NotificationCenter.default.post(name: .teamsLibraryDidChange, object: nil)
            case .cancelledAfterPrefix(let resultID, _, let cleanupCommitURLs)
                where resultID == requestID:
                cleanupCommitURLs.forEach(self.stampLocalWrite)
            case .cancelledBeforeAccess, .cancelledAfterPrefix, .loaded:
                break
            }
        }
        loadTask = task
        await task.value
    }

    private func scheduleLoadIfNeeded() {
        guard !didLoad, loadTask == nil else { return }
        Task { @MainActor [weak self] in
            await self?.loadIfNeeded()
        }
    }

    /// Returns the current immutable in-memory snapshot. First access schedules its disk load.
    func allTeams() -> [Team] {
        scheduleLoadIfNeeded()
        return teams
    }

    func team(byID id: UUID) -> Team? {
        scheduleLoadIfNeeded()
        return teams.first { $0.id == id }
    }

    private func sortAndNotify() {
        teams.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        NotificationCenter.default.post(name: .teamsLibraryDidChange, object: nil)
    }

    /// Insert a new team or overwrite an existing one with the same id.
    func upsert(_ team: Team) async throws {
        await loadIfNeeded()
        var updated = team
        updated.updatedAt = Date()
        let result = try await persistence.upsert(
            updated,
            in: teamsRootDirectory,
            requestID: UUID()
        )
        guard case .committed(let commit) = result else { return }
        stampLocalWrite(commit.recordURL)
        if let index = teams.firstIndex(where: { $0.id == updated.id }) {
            teams[index] = commit.team
        } else {
            teams.append(commit.team)
        }
        sortAndNotify()
    }

    func delete(id: UUID) async throws {
        await loadIfNeeded()
        let result = try await persistence.delete(
            teamID: id,
            in: teamsRootDirectory,
            requestID: UUID(),
            io: injectedDeletionIO ?? Self.deletionIO
        )
        guard case .committed(let commit) = result else { return }
        stampLocalWrite(commit.markerURL)
        teams.removeAll { $0.id == id }
        NotificationCenter.default.post(name: .teamsLibraryDidChange, object: nil)
    }

    func linkKnownPerson(
        _ knownPersonID: UUID,
        toPlayerNumber number: Int,
        teamID: UUID
    ) async throws {
        await loadIfNeeded()
        guard var team = teams.first(where: { $0.id == teamID }),
              let playerIndex = team.roster.firstIndex(where: { $0.number == number }) else { return }
        team.roster[playerIndex].knownPersonID = knownPersonID
        try await upsert(team)
    }

    /// Remote notifications are filtered on MainActor, then collapsed into one complete actor-owned
    /// snapshot. This avoids publishing a mixture of old and newly coordinated record reads.
    func applyRemoteChanges(_ changes: [(url: URL, contentChangeDate: Date?)]) async {
        let hasExternalChange = changes.contains { change in
            !shouldSkipRemoteReload(path: change.url.path, contentChangeDate: change.contentChangeDate)
        }
        guard hasExternalChange else { return }
        didLoad = false
        loadTask?.cancel()
        loadTask = nil
        await loadIfNeeded()
    }
}
