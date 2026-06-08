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

    private init() {}

    /// Idempotent. Call after app launch and whenever the iCloud toggle changes.
    func refresh() {
        let store = KeywordListsStore.shared
        guard store.iCloudEnabled else {
            stopQuery()
            return
        }
        if store.iCloudContainerListsURL != nil {
            startQueryIfNeeded()
        } else {
            // The ubiquity container isn't reachable yet. Early in launch the
            // daemon may still be provisioning it, and resolving on the main
            // thread can transiently return nil — so resolve off-main and start
            // the query once it lands, instead of giving up for the session.
            scheduleContainerResolution()
        }
    }

    /// Resolves the ubiquity container off the main thread (the documented
    /// pattern: the call provisions and blocks, then returns the URL), then
    /// starts the metadata query back on the main actor. A single attempt
    /// suffices — the call blocks until provisioning finishes; a nil result
    /// means iCloud is genuinely unavailable (signed out / Drive off).
    private func scheduleContainerResolution() {
        guard query == nil, pendingStart == nil else { return }
        pendingStart = Task { [weak self] in
            let resolved = await Task.detached(priority: .utility) {
                // AppPaths.iCloudContainerID is nonisolated and matches
                // KeywordListsStore.iCloudContainerID (same entitlement).
                FileManager.default.url(forUbiquityContainerIdentifier: AppPaths.iCloudContainerID)
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingStart = nil
                guard KeywordListsStore.shared.iCloudEnabled, resolved != nil else { return }
                self.startQueryIfNeeded()
                // Re-read now that the cloud root resolves so the in-memory tree
                // reflects the synced file immediately, without waiting on the
                // query's first gathering callback.
                KeywordListsStore.shared.notifyRemoteUpdate()
            }
        }
    }

    private func startQueryIfNeeded() {
        guard query == nil else { return }
        guard let root = KeywordListsStore.shared.iCloudContainerListsURL else { return }
        // The ubiquity container must exist before the query can find anything.
        // Coordinated so we don't fork a "Lists 2" conflict folder.
        try? CloudCoordinatedIO.ensureDirectory(root)

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
