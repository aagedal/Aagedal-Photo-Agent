import Foundation
import os

private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "KeywordListsCloudCoordinator")

/// Watches the iCloud ubiquity container for changes to keyword-list files and
/// notifies `KeywordListsStore` so observers can refresh. Active only while
/// `KeywordListsStore.iCloudEnabled` is true AND the container is reachable.
@MainActor
final class KeywordListsCloudCoordinator {
    static let shared = KeywordListsCloudCoordinator()

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Idempotent. Call after app launch and whenever the iCloud toggle changes.
    func refresh() {
        let store = KeywordListsStore.shared
        let enabled = store.iCloudEnabled
        let containerAvailable = store.iCloudContainerListsURL != nil

        if enabled && containerAvailable {
            startQueryIfNeeded()
        } else {
            stopQuery()
        }
    }

    private func startQueryIfNeeded() {
        guard query == nil else { return }
        guard let root = KeywordListsStore.shared.iCloudContainerListsURL else { return }
        // The ubiquity container must exist before the query can find anything.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // Match any file under our Lists folder. NSMetadataItemPathKey returns
        // an absolute path; the predicate ignores the schema and matches by prefix.
        q.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.txt")

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: q,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleUpdateFromStoredQuery()
            }
        })
        observers.append(center.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: q,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleUpdateFromStoredQuery()
            }
        })

        q.start()
        query = q
        logger.info("Started iCloud metadata query for keyword lists")
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
        query = nil
        logger.info("Stopped iCloud metadata query")
    }

    private func handleUpdate(query: NSMetadataQuery) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        guard let root = KeywordListsStore.shared.iCloudContainerListsURL else { return }
        let rootPath = root.path

        var touched = false
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if path.hasPrefix(rootPath) {
                touched = true
                // Kick off a download if the file isn't yet cached locally — for
                // the first sync after a new device signs in, iCloud may have
                // only the metadata stub locally.
                if let isDownloadedNumber = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
                   isDownloadedNumber != NSMetadataUbiquitousItemDownloadingStatusCurrent
                {
                    if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    }
                }
                break
            }
        }

        if touched {
            KeywordListsStore.shared.notifyRemoteUpdate()
        }
    }
}
