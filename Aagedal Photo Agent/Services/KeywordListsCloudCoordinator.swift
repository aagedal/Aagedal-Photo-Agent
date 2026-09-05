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
    /// In-flight off-main resolution of the ubiquity container. Held so a second
    /// `refresh()` doesn't stack a duplicate attempt and so disabling can cancel it.
    private var pendingStart: Task<Void, Never>?

    private let downloadService = CloudDownloadService()
    private var pendingDownloads: [UUID: Task<Void, Never>] = [:]
    private var resolvedRoot: URL?

    private init() {}

    /// Idempotent. Call after app launch and whenever the iCloud toggle changes.
    func refresh() {
        let store = KeywordListsStore.shared
        guard store.iCloudEnabled else {
            stopQuery()
            return
        }
        scheduleContainerResolution()
    }

    /// Resolve and prepare the directory on the same executor used for route reconciliation.
    private func scheduleContainerResolution() {
        guard query == nil, pendingStart == nil else { return }
        pendingStart = Task { [weak self] in
            do {
                let root = try await KeywordListsRoutingService.shared.prepareMonitoringRoot()
                guard !Task.isCancelled, let self else { return }
                self.pendingStart = nil
                guard KeywordListsStore.shared.iCloudEnabled, let root else { return }
                self.startQueryIfNeeded(root: root)
                KeywordListsStore.shared.notifyRemoteUpdate()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.pendingStart = nil
                logger.error("Could not prepare keyword-list cloud monitoring directory")
            }
        }
    }

    private func startQueryIfNeeded(root: URL) {
        guard query == nil else { return }
        resolvedRoot = root

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
        pendingStart?.cancel()
        pendingStart = nil
        for task in pendingDownloads.values { task.cancel() }
        pendingDownloads.removeAll()
        resolvedRoot = nil
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

        guard let root = resolvedRoot else { return }
        let rootPath = root.path + "/"

        var touched = false
        var downloadURLs: [URL] = []
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
                        downloadURLs.append(url)
                    }
                }
            }
        }

        if !downloadURLs.isEmpty { requestDownloads(for: downloadURLs) }
        if touched {
            KeywordListsStore.shared.notifyRemoteUpdate()
        }
    }

    private func requestDownloads(for urls: [URL]) {
        let requestID = UUID()
        let downloadService = downloadService
        pendingDownloads[requestID] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            _ = await downloadService.requestDownloads(for: urls)
            self?.pendingDownloads.removeValue(forKey: requestID)
        }
    }
}
