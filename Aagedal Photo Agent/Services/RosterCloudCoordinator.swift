import Foundation
import os

private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "RosterCloudCoordinator")

/// Evidence preserves requests that reached Foundation even if cancellation arrived during that call.
nonisolated struct CloudDownloadResult: Equatable, Sendable {
    let attemptedURLs: [URL]
    let failedURLs: [URL]
    let wasCancelled: Bool
}

/// Cloud download initiation may synchronously contact the file provider. Keep complete batches on
/// one executor; no suspension inside the loop allows overlapping updates to interleave access.
/// Each coordinator owns a service so independent libraries can initiate downloads independently.
actor CloudDownloadService {
    private let startDownloading: @Sendable (URL) throws -> Void
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "CloudDownload"
    )

    init(startDownloading: @escaping @Sendable (URL) throws -> Void = {
        try FileManager.default.startDownloadingUbiquitousItem(at: $0)
    }) {
        self.startDownloading = startDownloading
    }

    func requestDownloads(for urls: [URL]) -> CloudDownloadResult {
        let interval = signposter.beginInterval("RequestDownloads", id: signposter.makeSignpostID())
        var seen: Set<URL> = []
        var attemptedURLs: [URL] = []
        var failedURLs: [URL] = []
        for url in urls {
            guard !Task.isCancelled else { break }
            guard seen.insert(url).inserted else { continue }
            do {
                try startDownloading(url)
            } catch {
                failedURLs.append(url)
            }
            attemptedURLs.append(url)
        }
        signposter.endInterval(
            "RequestDownloads", interval,
            "attempted=\(attemptedURLs.count) failed=\(failedURLs.count) cancelled=\(Task.isCancelled)"
        )
        return CloudDownloadResult(
            attemptedURLs: attemptedURLs,
            failedURLs: failedURLs,
            wasCancelled: Task.isCancelled
        )
    }
}

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
    private let downloadService = CloudDownloadService()
    private var pendingDownloads: [UUID: Task<Void, Never>] = [:]
    private var monitoredRoot: URL?
    private var pendingChanges: [String: (url: URL, contentChangeDate: Date?)] = [:]

    private init() {}

    /// Idempotent. Call after app launch and whenever the iCloud toggle changes.
    func refresh(resolvedRoot: URL? = nil) {
        let enabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.teamsICloudEnabled)
        guard enabled else {
            stopQuery()
            return
        }
        if let resolvedRoot {
            startQueryIfNeeded(root: resolvedRoot)
        } else {
            scheduleContainerResolution()
        }
    }

    private func scheduleContainerResolution() {
        guard query == nil, pendingStart == nil else { return }
        pendingStart = Task { [weak self] in
            let resolvedRoot = await LibraryICloudRoutingService.teams.cloudRootURL(
                ensuringDirectory: true
            )
            guard !Task.isCancelled, let self else { return }
            self.pendingStart = nil
            let stillEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.teamsICloudEnabled)
            guard stillEnabled, let root = resolvedRoot else { return }
            self.startQueryIfNeeded(root: root)
        }
    }

    private func startQueryIfNeeded(root: URL) {
        guard query == nil else { return }
        monitoredRoot = root

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
        for task in pendingDownloads.values { task.cancel() }
        pendingDownloads.removeAll()
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
        monitoredRoot = nil
        logger.info("Stopped iCloud metadata query for Teams")
    }

    private func handleUpdate(query: NSMetadataQuery) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        guard let root = monitoredRoot else { return }
        let teamsPath = root.appendingPathComponent("teams", isDirectory: true).path + "/"

        var downloadURLs: [URL] = []
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            guard path.hasPrefix(teamsPath),
                  url.pathExtension == "json" || url.pathExtension == "deleted" else { continue }

            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
               status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                downloadURLs.append(url)
            }

            let changeDate = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            pendingChanges[path] = (url: url, contentChangeDate: changeDate)
        }

        if !downloadURLs.isEmpty { requestDownloads(for: downloadURLs) }
        if !pendingChanges.isEmpty { scheduleRefresh() }
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
