import Foundation
import os

private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "KnownPeopleCloudCoordinator")

/// Watches the iCloud ubiquity container for changes to the Known People
/// database/thumbnails made on *other* devices and refreshes
/// `KnownPeopleService` so the UI reflects them. Mirrors
/// `KeywordListsCloudCoordinator`. Active only while Known People iCloud sync is
/// enabled AND the container is reachable.
///
/// DRAFT — known limitations to resolve before this is relied on:
///
///  1. **No self-write filtering.** The query also fires for this device's own
///     writes (every `saveDatabase`, every thumbnail write, and especially a
///     batch import). The 1s debounce coalesces a burst into a single reload,
///     but that reload still runs after local edits settle. A cleaner version
///     would suppress reacting while a local save is in flight, or stamp a
///     generation counter in `database.json` and skip the reload when the
///     incoming change is one this device just made.
///
///  2. **Reload is heavy.** `reloadAfterStorageChange()` drops the whole
///     in-memory database, the feature-print cache, and the thumbnail cache,
///     then re-reads `database.json`. For large libraries this is much heavier
///     than the keyword-list refresh. Consider a lighter "reload database only"
///     entry point that keeps the feature-print cache warm.
///
///  3. **Whole-file last-writer-wins.** Even with this watcher, two devices
///     editing concurrently still race on a single `database.json`: the later
///     writer overwrites the earlier one wholesale. True multi-device safety
///     needs record-level merge (or per-person files), which is out of scope
///     for a change-watcher and is the larger follow-up.
@MainActor
final class KnownPeopleCloudCoordinator {
    static let shared = KnownPeopleCloudCoordinator()

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var pendingRefresh: Task<Void, Never>?

    private init() {}

    /// Idempotent. Call after app launch and whenever the iCloud toggle changes.
    func refresh() {
        let enabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.knownPeopleICloudEnabled)
        let containerAvailable = AppPaths.iCloudKnownPeopleURL != nil

        if enabled && containerAvailable {
            startQueryIfNeeded()
        } else {
            stopQuery()
        }
    }

    private func startQueryIfNeeded() {
        guard query == nil else { return }
        guard let root = AppPaths.iCloudKnownPeopleURL else { return }
        // The ubiquity container must exist before the query can find anything.
        // Coordinated so we don't fork a "KnownPeople 2" conflict folder.
        try? CloudCoordinatedIO.ensureDirectory(root)

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // Match database.json and the thumbnail .jpg files anywhere in the
        // ubiquitous documents scope; `handleUpdate` narrows to the KnownPeople
        // folder by path prefix (the scope only contains this app's files).
        q.predicate = NSPredicate(
            format: "%K ENDSWITH %@ OR %K ENDSWITH %@",
            NSMetadataItemFSNameKey, ".json",
            NSMetadataItemFSNameKey, ".jpg"
        )

        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering,
                     Notification.Name.NSMetadataQueryDidUpdate] {
            observers.append(center.addObserver(
                forName: name,
                object: q,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleUpdateFromStoredQuery()
                }
            })
        }

        q.start()
        query = q
        logger.info("Started iCloud metadata query for Known People")
    }

    private func handleUpdateFromStoredQuery() {
        guard let q = query else { return }
        handleUpdate(query: q)
    }

    private func stopQuery() {
        guard let q = query else { return }
        q.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        pendingRefresh?.cancel()
        pendingRefresh = nil
        query = nil
        logger.info("Stopped iCloud metadata query")
    }

    private func handleUpdate(query: NSMetadataQuery) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        guard let root = AppPaths.iCloudKnownPeopleURL else { return }
        let rootPath = root.path

        var touched = false
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  path.hasPrefix(rootPath) else { continue }
            touched = true
            // Pull down any item that is still a metadata-only stub locally — on
            // the first sync after a new device signs in, iCloud may hold only
            // the placeholder.
            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
               status != NSMetadataUbiquitousItemDownloadingStatusCurrent,
               let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }

        if touched { scheduleRefresh() }
    }

    /// Coalesce bursts of update notifications (one sync pulls many files) into a
    /// single reload shortly after the last one settles. See limitation (1): this
    /// still reloads after the device's own writes.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.pendingRefresh = nil
            logger.info("Remote Known People change detected — reloading database")
            KnownPeopleService.shared.reloadAfterStorageChange()
        }
    }
}
