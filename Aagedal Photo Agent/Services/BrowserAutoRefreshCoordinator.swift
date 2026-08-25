import Foundation
import os

/// Owns filesystem monitors for the currently materialized browser panes and turns
/// bursts of file events into one folder diff. A slow fallback scan covers providers
/// that do not reliably surface native FSEvents (some network and cloud volumes).
@MainActor
final class BrowserAutoRefreshCoordinator {
    private let panes: BrowserPanesModel
    private let metadataViewModel: MetadataViewModel
    private let logger = Logger(
        subsystem: "com.aagedal.photo-agent",
        category: "BrowserAutoRefresh"
    )

    private var monitors: [ObjectIdentifier: FolderChangeMonitor] = [:]
    private var monitoredURLs: [ObjectIdentifier: URL] = [:]
    private var refreshTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var fallbackTask: Task<Void, Never>?

    private let debounceDuration = Duration.milliseconds(350)
    private let deferredRetryDuration = Duration.seconds(1)
    private let fallbackInterval = Duration.seconds(30)

    init(panes: BrowserPanesModel, metadataViewModel: MetadataViewModel) {
        self.panes = panes
        self.metadataViewModel = metadataViewModel
    }

    deinit {
        fallbackTask?.cancel()
        for task in refreshTasks.values { task.cancel() }
        for monitor in monitors.values { monitor.cancel() }
    }

    func start() {
        synchronizeMonitors()
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
                    guard let folderURL = pane.currentFolderURL else { continue }
                    self.scheduleRefresh(
                        paneID: ObjectIdentifier(pane),
                        folderURL: folderURL,
                        delay: .zero
                    )
                }
            }
        }
    }

    func stop() {
        fallbackTask?.cancel()
        fallbackTask = nil
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
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
            monitors.removeValue(forKey: paneID)?.cancel()
            monitoredURLs.removeValue(forKey: paneID)
            refreshTasks.removeValue(forKey: paneID)?.cancel()
        }

        for (paneID, folderURL) in desired where monitoredURLs[paneID] != folderURL {
            monitoredURLs[paneID] = folderURL
            monitors[paneID] = FolderChangeMonitor(url: folderURL) { [weak self] batch in
                Task { @MainActor [weak self] in
                    self?.filesystemDidChange(
                        batch,
                        paneID: paneID,
                        folderURL: folderURL
                    )
                }
            }
            if monitors[paneID] == nil {
                logger.warning("FSEvents unavailable for \(folderURL.path, privacy: .private(mask: .hash)); using fallback polling")
            }
        }
    }

    private func panesToMonitor() -> [BrowserViewModel] {
        panes.layout.usesSecondPane ? panes.panes : [panes.active]
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

        if pane === panes.active,
           metadataViewModel.isInEditView
            || metadataViewModel.hasChanges
            || metadataViewModel.isSaving
            || !pane.searchText.isEmpty {
            scheduleRefresh(paneID: paneID, folderURL: folderURL, delay: deferredRetryDuration)
            return
        }

        refreshTasks[paneID] = nil
        let started = pane.refreshCurrentFolderIfNeeded { [weak self, weak pane] modifiedURLs in
            guard let self, let pane else { return }
            self.refreshCompleted(for: pane, modifiedURLs: modifiedURLs)
        }
        if !started {
            scheduleRefresh(paneID: paneID, folderURL: folderURL, delay: deferredRetryDuration)
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
        metadataViewModel.loadMetadata(
            for: pane.selectedImages,
            folderURL: pane.currentFolderURL
        )
    }
}
