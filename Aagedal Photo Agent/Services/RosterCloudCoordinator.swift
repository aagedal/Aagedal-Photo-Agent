import Foundation
import os

private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "RosterCloudCoordinator")

/// Watches the iCloud ubiquity container for changes to the Teams library files
/// made on *other* devices and refreshes `RosterStore`. Mirrors
/// `KnownPeopleCloudCoordinator`. Active only while Teams iCloud sync is enabled
/// AND the container is reachable.
@MainActor
final class RosterCloudCoordinator {
    static let shared = RosterCloudCoordinator()

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var pendingRefresh: Task<Void, Never>?
    private var pendingStart: Task<Void, Never>?
    private var pendingChanges: [String: (url: URL, contentChangeDate: Date?)] = [:]

    private init() {}

    /// Idempotent. Call after app launch and whenever the iCloud toggle changes.
    func refresh() {
        let enabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.teamsICloudEnabled)
        guard enabled else {
            stopQuery()
            return
        }
        if AppPaths.iCloudTeamsURL != nil {
            startQueryIfNeeded()
        } else {
            scheduleContainerResolution()
        }
    }

    private func scheduleContainerResolution() {
        guard query == nil, pendingStart == nil else { return }
        pendingStart = Task { [weak self] in
            let resolved = await Task.detached(priority: .utility) {
                AppPaths.iCloudTeamsURL
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingStart = nil
                let stillEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.teamsICloudEnabled)
                guard stillEnabled, resolved != nil else { return }
                self.startQueryIfNeeded()
            }
        }
    }

    private func startQueryIfNeeded() {
        guard query == nil else { return }
        guard let root = AppPaths.iCloudTeamsURL else { return }
        try? CloudCoordinatedIO.ensureDirectory(root)

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(
            format: "%K ENDSWITH %@ OR %K ENDSWITH %@",
            NSMetadataItemFSNameKey, ".json",
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
        logger.info("Started iCloud metadata query for Teams")
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
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingChanges.removeAll()
        query = nil
        logger.info("Stopped iCloud metadata query for Teams")
    }

    private func handleUpdate(query: NSMetadataQuery) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        guard let root = AppPaths.iCloudTeamsURL else { return }
        let teamsPath = root.appendingPathComponent("teams", isDirectory: true).path

        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            guard path.hasPrefix(teamsPath),
                  url.pathExtension == "json" || url.pathExtension == "deleted" else { continue }

            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
               status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }

            let changeDate = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            pendingChanges[path] = (url: url, contentChangeDate: changeDate)
        }

        if !pendingChanges.isEmpty { scheduleRefresh() }
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.pendingRefresh = nil
            let changes = Array(self.pendingChanges.values)
            self.pendingChanges.removeAll()
            guard !changes.isEmpty else { return }
            logger.info("Remote Teams change detected — applying \(changes.count, privacy: .public) file change(s)")
            await RosterStore.shared.applyRemoteChanges(changes)
        }
    }
}
