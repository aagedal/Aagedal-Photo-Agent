import Foundation
import os

private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "WatermarkCloudCoordinator")

/// Watches the iCloud ubiquity container for changes to the Watermark library's item
/// folders (`meta.json`/`image.png`/`.deleted`) made on *other* devices and refreshes
/// `WatermarkStore`. Mirrors `RosterCloudCoordinator`. Active only while Watermark iCloud
/// sync is enabled AND the container is reachable.
@MainActor
final class WatermarkCloudCoordinator {
    static let shared = WatermarkCloudCoordinator()

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var pendingRefresh: Task<Void, Never>?
    private var pendingStart: Task<Void, Never>?
    private let downloadService = CloudDownloadService()
    private var pendingDownloads: [UUID: Task<Void, Never>] = [:]
    private(set) var monitoredRoot: URL?
    private var queryGeneration = UUID()
    private let makeMetadataQuery: () -> NSMetadataQuery
    private let isEnabled: () -> Bool
    private let resolveRoot: @Sendable () async -> URL?
    private let startMetadataQuery: (NSMetadataQuery) -> Void
    private let stopMetadataQuery: (NSMetadataQuery) -> Void
    private var pendingChanges: [String: (url: URL, contentChangeDate: Date?)] = [:]

    init(
        isEnabled: @escaping () -> Bool = {
            UserDefaults.standard.bool(forKey: UserDefaultsKeys.watermarksICloudEnabled)
        },
        resolveRoot: @escaping @Sendable () async -> URL? = {
            await LibraryICloudRoutingService.watermarks.cloudRootURL(ensuringDirectory: true)
        },
        makeMetadataQuery: @escaping () -> NSMetadataQuery = { NSMetadataQuery() },
        startMetadataQuery: @escaping (NSMetadataQuery) -> Void = { _ = $0.start() },
        stopMetadataQuery: @escaping (NSMetadataQuery) -> Void = { $0.stop() }
    ) {
        self.makeMetadataQuery = makeMetadataQuery
        self.isEnabled = isEnabled
        self.resolveRoot = resolveRoot
        self.startMetadataQuery = startMetadataQuery
        self.stopMetadataQuery = stopMetadataQuery
    }

    /// Idempotent. Call after app launch and whenever the iCloud toggle changes.
    func refresh(resolvedRoot: URL? = nil) {
        guard isEnabled() else {
            stopQuery()
            return
        }
        if let resolvedRoot {
            // A proven root supersedes any older, still-resolving container lookup.
            pendingStart?.cancel()
            pendingStart = nil
            if monitoredRoot != resolvedRoot { stopQuery() }
            startQueryIfNeeded(root: resolvedRoot)
        } else {
            scheduleContainerResolution()
        }
    }

    private func scheduleContainerResolution() {
        guard query == nil, pendingStart == nil else { return }
        let resolveRoot = resolveRoot
        pendingStart = Task { [weak self] in
            let resolvedRoot = await resolveRoot()
            guard !Task.isCancelled, let self else { return }
            self.pendingStart = nil
            guard self.isEnabled(), let root = resolvedRoot else { return }
            self.startQueryIfNeeded(root: root)
        }
    }

    private func startQueryIfNeeded(root: URL) {
        guard query == nil else { return }
        monitoredRoot = root
        let generation = UUID()
        queryGeneration = generation

        let q = makeMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(
            format: "%K ENDSWITH %@ OR %K ENDSWITH %@ OR %K ENDSWITH %@",
            NSMetadataItemFSNameKey, "meta.json",
            NSMetadataItemFSNameKey, "image.png",
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
                    self?.handleUpdateFromStoredQuery(generation: generation)
                }
            })
        }

        query = q
        startMetadataQuery(q)
        logger.info("Started iCloud metadata query for Watermarks")
    }

    private func handleUpdateFromStoredQuery(generation: UUID) {
        guard generation == queryGeneration, let q = query else { return }
        handleUpdate(query: q)
    }

    private func stopQuery() {
        queryGeneration = UUID()
        pendingStart?.cancel()
        pendingStart = nil
        for task in pendingDownloads.values { task.cancel() }
        pendingDownloads.removeAll()
        if let q = query { stopMetadataQuery(q) }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingChanges.removeAll()
        query = nil
        monitoredRoot = nil
        logger.info("Stopped iCloud metadata query for Watermarks")
    }

    private func handleUpdate(query: NSMetadataQuery) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        guard let root = monitoredRoot else { return }
        let itemsPath = root.appendingPathComponent("items", isDirectory: true).path + "/"

        var downloadURLs: [URL] = []
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            guard path.hasPrefix(itemsPath),
                  url.lastPathComponent == "meta.json" || url.lastPathComponent == "image.png"
                    || url.pathExtension == "deleted" else { continue }

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
            logger.info("Remote Watermark change detected — applying \(changes.count, privacy: .public) file change(s)")
            await WatermarkStore.shared.applyRemoteChanges(changes)
        }
    }
}
