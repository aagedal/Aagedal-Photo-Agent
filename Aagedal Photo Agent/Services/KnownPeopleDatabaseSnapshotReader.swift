import Foundation

/// Read-only, off-main assembly of the Known People database from its per-person files.
///
/// `KnownPeopleService.loadDatabase()` performs coordinated reads of every person file plus
/// conflict checks and JSON decoding on the main actor; after an iCloud storage change (the
/// cloud watcher resolving the container at launch) that stalled the UI for as long as the
/// library took to read. This reader performs the same reads on a concurrent executor through
/// `CloudCoordinatedIO` (NSFileCoordinator, as every container access must) and returns the
/// assembled database only when the store needs no repair. Anything that `loadDatabase()` would
/// fix by writing (legacy `database.json`, iCloud conflict versions, corrupt or unreadable
/// records, tombstoned strays, expired or malformed tombstones) yields `.needsRepair`, and the
/// service runs its existing main-actor repair path instead. It never writes.
nonisolated enum KnownPeopleDatabaseSnapshotReader {
    enum Outcome: Sendable {
        case clean(KnownPeopleDatabase)
        case needsRepair
    }

    /// Mirrors `KnownPeopleService.tombstoneRetention`.
    static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60

    @concurrent
    static func read(
        root: URL,
        hasConflicts: @escaping @Sendable (URL) -> Bool = { url in
            !(NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty
        }
    ) async -> Outcome {
        readSynchronously(root: root, hasConflicts: hasConflicts)
    }

    static func readSynchronously(
        root: URL,
        hasConflicts: (URL) -> Bool
    ) -> Outcome {
        if CloudCoordinatedIO.itemExists(at: root.appendingPathComponent("database.json")) {
            return .needsRepair
        }
        let peopleDirectory = root.appendingPathComponent("people", isDirectory: true)
        let entries = (try? CloudCoordinatedIO.contentsOfDirectory(at: peopleDirectory)) ?? []
        let decoder = JSONDecoder()
        let now = Date()

        var tombstoned = Set<UUID>()
        for url in entries where url.pathExtension == "deleted" {
            if Task.isCancelled { return .needsRepair }
            guard let fileID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? CloudCoordinatedIO.readData(at: url),
                  let tombstone = try? decoder.decode(KnownPersonTombstone.self, from: data),
                  tombstone.id == fileID,
                  now.timeIntervalSince(tombstone.deletedAt) < tombstoneRetention else {
                return .needsRepair
            }
            tombstoned.insert(fileID)
        }

        var people: [KnownPerson] = []
        for url in entries where url.pathExtension == "json" {
            if Task.isCancelled { return .needsRepair }
            guard let fileID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !tombstoned.contains(fileID),
                  !hasConflicts(url),
                  let data = try? CloudCoordinatedIO.readData(at: url),
                  let person = try? decoder.decode(KnownPerson.self, from: data),
                  person.id == fileID else {
                return .needsRepair
            }
            people.append(person)
        }

        return .clean(KnownPeopleDatabase(
            people: people,
            lastModified: people.map(\.updatedAt).max() ?? Date()
        ))
    }
}
