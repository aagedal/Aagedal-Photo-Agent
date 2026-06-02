import Foundation
import os

private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "KnownPeopleCloudCoordinator")

/// Watches the iCloud ubiquity container for changes to the Known People
/// per-person files made on *other* devices and refreshes `KnownPeopleService`
/// so the UI reflects them. Mirrors `KeywordListsCloudCoordinator`. Active only
/// while Known People iCloud sync is enabled AND the container is reachable.
///
/// Reacts at file granularity: it collects the changed `people/<uuid>.json` and
/// `<uuid>.deleted` URLs from each query update and hands them to
/// `KnownPeopleService.applyRemoteChanges(_:)`, which patches just those cache
/// entries (resolving any conflict versions) instead of dropping the whole
/// in-memory database. The service filters out echoes of this device's own
/// writes via its self-write registry, so a local save no longer triggers a
/// reload.
@MainActor
final class KnownPeopleCloudCoordinator {
    static let shared = KnownPeopleCloudCoordinator()

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var pendingRefresh: Task<Void, Never>?
    /// Changed person-file URLs accumulated across query updates within one
    /// debounce window, keyed by path so repeated notifications coalesce.
    private var pendingChanges: [String: (url: URL, contentChangeDate: Date?)] = [:]

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
            format: "%K ENDSWITH %@ OR %K ENDSWITH %@ OR %K ENDSWITH %@",
            NSMetadataItemFSNameKey, ".json",
            NSMetadataItemFSNameKey, ".jpg",
            NSMetadataItemFSNameKey, ".deleted"
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
        pendingChanges.removeAll()
        query = nil
        logger.info("Stopped iCloud metadata query")
    }

    private func handleUpdate(query: NSMetadataQuery) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        guard let root = AppPaths.iCloudKnownPeopleURL else { return }
        let peoplePath = root.appendingPathComponent("people", isDirectory: true).path

        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            // Only person files (people/<uuid>.json and <uuid>.deleted) drive a
            // record-level refresh; thumbnails are read lazily on demand.
            guard path.hasPrefix(peoplePath),
                  url.pathExtension == "json" || url.pathExtension == "deleted" else { continue }

            // Pull down any item that is still a metadata-only stub locally — on
            // the first sync after a new device signs in, iCloud may hold only
            // the placeholder.
            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
               status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }

            let changeDate = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            pendingChanges[path] = (url: url, contentChangeDate: changeDate)
        }

        if !pendingChanges.isEmpty { scheduleRefresh() }
    }

    /// Coalesce bursts of update notifications (one sync pulls many files) into a
    /// single per-file refresh shortly after the last one settles.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.pendingRefresh = nil
            let changes = Array(self.pendingChanges.values)
            self.pendingChanges.removeAll()
            guard !changes.isEmpty else { return }
            logger.info("Remote Known People change detected — applying \(changes.count, privacy: .public) file change(s)")
            KnownPeopleService.shared.applyRemoteChanges(changes)
        }
    }
}
