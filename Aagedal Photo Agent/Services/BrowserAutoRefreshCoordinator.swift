import AppKit
import Foundation
import os

/// Owns filesystem monitors for the currently materialized browser panes and turns
/// bursts of file events into one folder diff. A slow fallback scan covers panes whose
/// FSEvents stream is unavailable or on a non-local volume (network shares do not
/// reliably surface other machines' changes).
@MainActor
final class BrowserAutoRefreshCoordinator {
    private let panes: BrowserPanesModel
    private let metadataViewModel: MetadataViewModel
    private let monitorService: FolderChangeMonitorService
    private let logger = Logger(
        subsystem: "com.aagedal.photo-agent",
        category: "BrowserAutoRefresh"
    )

    private var monitors: [ObjectIdentifier: FolderChangeMonitor] = [:]
    private var monitoredURLs: [ObjectIdentifier: URL] = [:]
    private var monitorRequestIDs: [ObjectIdentifier: UUID] = [:]
    private var monitorSetupTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var refreshTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var fallbackTask: Task<Void, Never>?

    private let debounceDuration = Duration.milliseconds(350)
    private let deferredRetryDuration = Duration.seconds(1)
    private let fallbackInterval = Duration.seconds(30)
    /// Even with a local FSEvents stream, rescan occasionally: a refresh that was admitted and
    /// then cancelled (Batch Rename quiescence) or failed (a scan error) is not retried, and no
    /// further event may arrive to trigger another one.
    private let localSafetyInterval: TimeInterval = 300
    private var lastFallbackScan: [ObjectIdentifier: Date] = [:]
    /// Folder an import is copying into. Panes showing it (or a folder inside it) do not
    /// rescan on every arriving file (a rescan storm over thousands of copies); they refresh
    /// at most once per `ImportRefreshThrottle.defaultInterval` so the user can cull while the
    /// copy runs, and once more when the import ends.
    private var importDeferralFolder: URL?
    private var importDeferredPaneIDs: Set<ObjectIdentifier> = []
    private var importRefreshThrottle = ImportRefreshThrottle()
    /// The running import's copies that are not finished yet; mid-import refreshes never add them.
    private let unfinishedImportURLs: @MainActor () -> Set<URL>
    private var unmountObserver: NSObjectProtocol?

    init(
        panes: BrowserPanesModel,
        metadataViewModel: MetadataViewModel,
        monitorService: FolderChangeMonitorService = .shared,
        unfinishedImportURLs: @escaping @MainActor () -> Set<URL> = { [] }
    ) {
        self.panes = panes
        self.metadataViewModel = metadataViewModel
        self.monitorService = monitorService
        self.unfinishedImportURLs = unfinishedImportURLs
    }

    deinit {
        fallbackTask?.cancel()
        for task in refreshTasks.values { task.cancel() }
        for task in monitorSetupTasks.values { task.cancel() }
        for monitor in monitors.values { monitor.cancel() }
        // The unmount observer is removed in `stop()` (onDisappear); it holds `self` weakly,
        // so a coordinator released without `stop()` leaves only an inert observer.
    }

    func start() {
        synchronizeMonitors()
        if unmountObserver == nil {
            unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didUnmountNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated {
                    self?.volumeDidUnmount(volumeURL)
                }
            }
        }
        guard fallbackTask == nil else { return }
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self?.fallbackInterval ?? .seconds(30))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.synchronizeMonitors()
                for pane in self.panesToMonitor() {
                    guard let folderURL = pane.currentFolderURL,
                          self.needsFallbackScan(paneID: ObjectIdentifier(pane)) else { continue }
                    self.scheduleRefresh(
                        paneID: ObjectIdentifier(pane),
                        folderURL: folderURL,
                        delay: .zero
                    )
                }
            }
        }
    }

    /// Starts (non-nil) or ends (nil) deferring auto-refresh for an import's destination.
    /// Ending it refreshes every pane that skipped a refresh meanwhile, once.
    func setImportDeferralFolder(_ folderURL: URL?) {
        let standardized = folderURL?.standardizedFileURL
        guard standardized != importDeferralFolder else { return }
        importDeferralFolder = standardized
        guard standardized == nil else { return }
        let deferred = importDeferredPaneIDs
        importDeferredPaneIDs.removeAll()
        importRefreshThrottle.reset()
        for paneID in deferred {
            guard let folderURL = monitoredURLs[paneID] else { continue }
            scheduleRefresh(paneID: paneID, folderURL: folderURL, delay: .zero)
        }
    }

    /// True when `folderURL` is the import destination or lies inside it.
    func isDeferredForImport(_ folderURL: URL) -> Bool {
        guard let importDeferralFolder else { return false }
        let root = importDeferralFolder.pathComponents
        let folder = folderURL.standardizedFileURL.pathComponents
        return folder.starts(with: root)
    }

    /// An ejected card or unmounted share produces no FSEvents for the folder itself; check
    /// every pane whose folder lived on that volume (or all panes when the volume is unknown).
    func volumeDidUnmount(_ volumeURL: URL?) {
        let volume = volumeURL?.standardizedFileURL.pathComponents
        for pane in panes.panes {
            guard let folderURL = pane.currentFolderURL else { continue }
            if let volume, !folderURL.standardizedFileURL.pathComponents.starts(with: volume) {
                continue
            }
            Task { await pane.verifyCurrentFolderAvailability() }
        }
    }

    func stop() {
        if let unmountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(unmountObserver)
            self.unmountObserver = nil
        }
        fallbackTask?.cancel()
        fallbackTask = nil
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
        importDeferredPaneIDs.removeAll()
        importRefreshThrottle.reset()
        for task in monitorSetupTasks.values { task.cancel() }
        monitorSetupTasks.removeAll()
        monitorRequestIDs.removeAll()
        for monitor in monitors.values { monitor.cancel() }
        monitors.removeAll()
        monitoredURLs.removeAll()
    }

    func synchronizeMonitors() {
        let desired = Dictionary(uniqueKeysWithValues: panesToMonitor().compactMap { pane in
            pane.currentFolderURL.map { (ObjectIdentifier(pane), $0.standardizedFileURL) }
        })

        let obsoleteIDs = monitoredURLs.keys.filter { desired[$0] != monitoredURLs[$0] }
        for paneID in obsoleteIDs {
            monitorRequestIDs.removeValue(forKey: paneID)
            monitorSetupTasks.removeValue(forKey: paneID)?.cancel()
            monitors.removeValue(forKey: paneID)?.cancel()
            monitoredURLs.removeValue(forKey: paneID)
            refreshTasks.removeValue(forKey: paneID)?.cancel()
            lastFallbackScan.removeValue(forKey: paneID)
        }

        for (paneID, folderURL) in desired where monitoredURLs[paneID] != folderURL {
            monitoredURLs[paneID] = folderURL
            let requestID = UUID()
            monitorRequestIDs[paneID] = requestID
            let request = FolderChangeMonitorRequest(folderURL: folderURL) { [weak self] batch in
                Task { @MainActor [weak self] in
                    self?.filesystemDidChange(
                        batch,
                        paneID: paneID,
                        folderURL: folderURL
                    )
                }
            }
            monitorSetupTasks[paneID] = Task { [weak self] in
                guard let self else { return }
                let result = await monitorService.createMonitor(request)
                guard monitorRequestIDs[paneID] == requestID,
                      monitoredURLs[paneID] == folderURL else {
                    if case let .created(monitor) = result {
                        monitor.cancel()
                    }
                    return
                }
                monitorSetupTasks[paneID] = nil
                switch result {
                case let .created(monitor):
                    monitors[paneID]?.cancel()
                    monitors[paneID] = monitor
                case .unavailable:
                    logger.warning("FSEvents unavailable for \(folderURL.path, privacy: .private(mask: .hash)); using fallback polling")
                case .cancelledBeforeSetup, .cancelledAfterSetup:
                    break
                }
            }
        }
    }

    /// A full rescan of a 10,000-photo folder every 30 s is wasted work when a local
    /// FSEvents stream already delivers every change.
    func needsFallbackScan(paneID: ObjectIdentifier, now: Date = Date()) -> Bool {
        guard let monitor = monitors[paneID], monitor.watchesLocalVolume else {
            lastFallbackScan[paneID] = now
            return true
        }
        guard let last = lastFallbackScan[paneID] else {
            lastFallbackScan[paneID] = now
            return false
        }
        guard now.timeIntervalSince(last) >= localSafetyInterval else { return false }
        lastFallbackScan[paneID] = now
        return true
    }

    private func panesToMonitor() -> [BrowserViewModel] {
        panes.panes
    }

    private func filesystemDidChange(
        _ batch: FolderChangeBatch,
        paneID: ObjectIdentifier,
        folderURL: URL
    ) {
        guard monitoredURLs[paneID] == folderURL else { return }
        let impact = BrowserFolderChangeImpact.classify(
            batch,
            monitoredRoot: folderURL
        )
        let change = HiddenFolderStoreChange(
            folderURL: folderURL,
            changedPaths: batch.paths
        )
        if impact.contains(.analysisStore) {
            NotificationCenter.default.post(name: .analysisStoreDidChange, object: change)
        }
        if impact.contains(.versionStore) {
            NotificationCenter.default.post(name: .versionStoreDidChange, object: change)
        }
        if impact.contains(.browserContent) {
            if isDeferredForImport(folderURL) {
                // Files arrive faster than the debounce during an import; restarting a
                // pending throttled refresh on every event would starve it until the end.
                guard refreshTasks[paneID] == nil else { return }
                let remaining = importRefreshThrottle.remainingDelay(for: paneID)
                scheduleRefresh(
                    paneID: paneID,
                    folderURL: folderURL,
                    delay: max(debounceDuration, .milliseconds(Int((remaining * 1000).rounded(.up))))
                )
                return
            }
            scheduleRefresh(paneID: paneID, folderURL: folderURL, delay: debounceDuration)
        }
    }

    private func scheduleRefresh(
        paneID: ObjectIdentifier,
        folderURL: URL,
        delay: Duration
    ) {
        refreshTasks.removeValue(forKey: paneID)?.cancel()
        refreshTasks[paneID] = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.attemptRefresh(paneID: paneID, folderURL: folderURL)
        }
    }

    private func attemptRefresh(paneID: ObjectIdentifier, folderURL: URL) {
        guard monitoredURLs[paneID] == folderURL,
              let pane = panes.panes.first(where: { ObjectIdentifier($0) == paneID }),
              pane.currentFolderURL?.standardizedFileURL == folderURL else {
            refreshTasks.removeValue(forKey: paneID)?.cancel()
            return
        }

        // An import writes thousands of files into this folder. A rescan per arriving file
        // is a storm; freezing the folder until the end stops the user culling while the copy
        // runs. Throttle instead, and always refresh once more when the import ends.
        let isImportDeferred = isDeferredForImport(folderURL)
        if isImportDeferred {
            importDeferredPaneIDs.insert(paneID)
            let remaining = importRefreshThrottle.remainingDelay(for: paneID)
            if remaining > 0 {
                scheduleRefresh(
                    paneID: paneID,
                    folderURL: folderURL,
                    delay: .milliseconds(Int((remaining * 1000).rounded(.up)))
                )
                return
            }
        }

        // Our own rating/label writes echo back as FSEvents for every photo in the batch.
        // Rescanning mid-batch repeats a full folder diff per debounce window; one diff
        // after the batch observes the same final state, including external changes.
        if pane.hasFieldMutationWritesInFlight {
            scheduleRefresh(paneID: paneID, folderURL: folderURL, delay: deferredRetryDuration)
            return
        }

        if pane === panes.active,
           (metadataViewModel.isInEditView && !metadataViewModel.canAdoptExternalChangesInDevelop)
            || metadataViewModel.hasUnpersistedEditorChanges
            || metadataViewModel.isSaving
            || pane.isEditingSearchText {
            scheduleRefresh(paneID: paneID, folderURL: folderURL, delay: deferredRetryDuration)
            return
        }

        refreshTasks[paneID] = nil
        let started = pane.refreshCurrentFolderIfNeeded(
            onComplete: { [weak self, weak pane] modifiedURLs in
                guard let self, let pane else { return }
                self.refreshCompleted(for: pane, modifiedURLs: modifiedURLs)
            },
            excludingNewURLs: isImportDeferred ? unfinishedImportURLs : nil
        )
        if !started {
            scheduleRefresh(paneID: paneID, folderURL: folderURL, delay: deferredRetryDuration)
        } else if isImportDeferred {
            importRefreshThrottle.recordRefresh(for: paneID)
        }
    }

    private func refreshCompleted(for pane: BrowserViewModel, modifiedURLs: Set<URL>) {
        defer { pane.clearLastRefreshModifiedURLs() }
        guard pane === panes.active,
              !modifiedURLs.isEmpty,
              !metadataViewModel.isSaving else { return }

        let selectedURLs = Set(metadataViewModel.selectedURLs)
        guard !selectedURLs.isEmpty,
              !modifiedURLs.isDisjoint(with: selectedURLs) else { return }
        // Develop may have started an edit while the folder was scanned; reloading now would
        // swap that edit's save baseline. Its save then reports the conflict instead.
        if metadataViewModel.isInEditView, !metadataViewModel.canAdoptExternalChangesInDevelop { return }
        metadataViewModel.loadMetadata(
            for: pane.selectedImages,
            folderURL: pane.currentFolderURL,
            preservingUnsavedEdits: true
        )
    }
}

/// Rate limit for refreshing a pane whose folder an import is copying into: at most one
/// refresh per `interval`, so arriving photos appear while the copy runs without a rescan
/// per file. The coordinator still refreshes once more when the import ends.
nonisolated struct ImportRefreshThrottle: Sendable {
    static let defaultInterval: TimeInterval = 2.5

    let interval: TimeInterval
    private var lastRefresh: [ObjectIdentifier: Date] = [:]

    init(interval: TimeInterval = ImportRefreshThrottle.defaultInterval) {
        self.interval = interval
    }

    /// Seconds until `paneID` may refresh again; zero when a refresh is allowed now.
    func remainingDelay(for paneID: ObjectIdentifier, now: Date = Date()) -> TimeInterval {
        guard let last = lastRefresh[paneID] else { return 0 }
        return max(0, interval - now.timeIntervalSince(last))
    }

    mutating func recordRefresh(for paneID: ObjectIdentifier, at now: Date = Date()) {
        lastRefresh[paneID] = now
    }

    mutating func reset() {
        lastRefresh.removeAll()
    }
}
