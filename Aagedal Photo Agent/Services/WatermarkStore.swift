import Foundation
import os.log
import AppKit

nonisolated private let watermarkLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent",
    category: "WatermarkStore"
)

extension Notification.Name {
    /// Posted whenever the Watermark library changes (local edit or remote sync).
    static let watermarkLibraryDidChange = Notification.Name("watermarkLibraryDidChange")
}

nonisolated enum WatermarkImportError: Error, LocalizedError {
    case notAPNG

    var errorDescription: String? {
        switch self {
        case .notAPNG: return "The selected file isn't a readable PNG image."
        }
    }
}

nonisolated struct WatermarkLibraryImportCommit: Equatable, Sendable {
    let requestID: UUID
    let sourceURL: URL
    let asset: WatermarkAsset
    let imageURL: URL
    let metadataURL: URL
    let imageData: Data
    let byteCount: Int
    /// Coordinated writes are non-preemptible. Cancellation observed after both files are
    /// installed therefore describes a durable import rather than an abandoned operation.
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum WatermarkLibraryImportResult: Equatable, Sendable {
    case committed(WatermarkLibraryImportCommit)
    case cancelledBeforeAccess(requestID: UUID)
    case cancelledBeforeRead(requestID: UUID, sourceURL: URL)
    case cancelledAfterRead(requestID: UUID, sourceURL: URL, byteCount: Int)
    case cancelledBeforeCommit(requestID: UUID, sourceURL: URL, byteCount: Int)
}

nonisolated struct WatermarkLibraryFileAccess: Sendable {
    let startAccessing: @Sendable (URL) -> Bool
    let stopAccessing: @Sendable (URL) -> Void
    let readData: @Sendable (URL) throws -> Data
    let writeData: @Sendable (Data, URL) throws -> Void
    let removeItem: @Sendable (URL) throws -> Void
    let ensureDirectory: @Sendable (URL) throws -> Void
    let contentsOfDirectory: @Sendable (URL) throws -> [URL]
    let isDirectory: @Sendable (URL) -> Bool

    static let system = WatermarkLibraryFileAccess(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() },
        readData: { try Data(contentsOf: $0) },
        writeData: { try CloudCoordinatedIO.writeData($0, to: $1) },
        removeItem: { try CloudCoordinatedIO.removeItem(at: $0) },
        ensureDirectory: { try CloudCoordinatedIO.ensureDirectory($0) },
        contentsOfDirectory: { try CloudCoordinatedIO.contentsOfDirectory(at: $0) },
        isDirectory: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    )
}

nonisolated struct WatermarkLibrarySnapshot: Sendable {
    let requestID: UUID
    let assets: [WatermarkAsset]
    let imageDataByAssetID: [UUID: Data]
    let inspectedEntryCount: Int
    let cleanupCommitURLs: [URL]
}

nonisolated enum WatermarkLibraryLoadResult: Sendable {
    case loaded(WatermarkLibrarySnapshot)
    case cancelledBeforeAccess(requestID: UUID)
    case cancelledAfterPrefix(
        requestID: UUID,
        inspectedEntryCount: Int,
        cleanupCommitURLs: [URL]
    )
}

nonisolated struct WatermarkLibraryMetadataCommit: Sendable {
    let requestID: UUID
    let asset: WatermarkAsset
    let metadataURL: URL
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum WatermarkLibraryMetadataResult: Sendable {
    case committed(WatermarkLibraryMetadataCommit)
    case cancelledBeforeCommit(requestID: UUID)
}

nonisolated struct WatermarkLibraryDeleteCommit: Sendable {
    let requestID: UUID
    let assetID: UUID
    let markerURL: URL
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum WatermarkLibraryDeleteResult: Sendable {
    case committed(WatermarkLibraryDeleteCommit)
    case cancelledBeforeCommit(requestID: UUID, assetID: UUID)
}

/// Owns every coordinated Watermark-library filesystem operation away from MainActor. The PNG is
/// installed before `meta.json`, which is the record-discovery boundary. Loads publish one complete
/// metadata-and-image snapshot, while mutations report cancellation before or after durability.
actor WatermarkLibraryPersistenceService {
    static let shared = WatermarkLibraryPersistenceService()

    private let access: WatermarkLibraryFileAccess

    init(access: WatermarkLibraryFileAccess = .system) {
        self.access = access
    }

    func importPNG(
        from sourceURL: URL,
        name: String,
        into itemsDirectory: URL,
        requestID: UUID
    ) throws -> WatermarkLibraryImportResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeAccess(requestID: requestID)
        }

        let didStartAccess = access.startAccessing(sourceURL)
        defer { if didStartAccess { access.stopAccessing(sourceURL) } }
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID, sourceURL: sourceURL)
        }

        let data = try access.readData(sourceURL)
        guard !Task.isCancelled else {
            return .cancelledAfterRead(
                requestID: requestID,
                sourceURL: sourceURL,
                byteCount: data.count
            )
        }
        guard let rep = NSBitmapImageRep(data: data),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            throw WatermarkImportError.notAPNG
        }

        let asset = WatermarkAsset(
            name: name,
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh
        )
        let itemDirectory = itemsDirectory.appendingPathComponent(
            asset.id.uuidString,
            isDirectory: true
        )
        let imageURL = itemDirectory.appendingPathComponent("image.png")
        let metadataURL = itemDirectory.appendingPathComponent("meta.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = try encoder.encode(asset)

        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(
                requestID: requestID,
                sourceURL: sourceURL,
                byteCount: data.count
            )
        }

        do {
            try access.writeData(data, imageURL)
            try access.writeData(metadata, metadataURL)
        } catch {
            try? access.removeItem(itemDirectory)
            throw error
        }

        return .committed(WatermarkLibraryImportCommit(
            requestID: requestID,
            sourceURL: sourceURL,
            asset: asset,
            imageURL: imageURL,
            metadataURL: metadataURL,
            imageData: data,
            byteCount: data.count,
            cancellationRequestedAfterCommit: Task.isCancelled
        ))
    }

    func load(from rootDirectory: URL, requestID: UUID) -> WatermarkLibraryLoadResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeAccess(requestID: requestID)
        }

        let itemsDirectory = itemsDirectory(in: rootDirectory)
        do {
            try access.ensureDirectory(rootDirectory)
            try access.ensureDirectory(itemsDirectory)
        } catch {
            watermarkLog.error("Failed to prepare Watermark library: \(error.localizedDescription, privacy: .private)")
            return .loaded(WatermarkLibrarySnapshot(
                requestID: requestID,
                assets: [],
                imageDataByAssetID: [:],
                inspectedEntryCount: 0,
                cleanupCommitURLs: []
            ))
        }
        guard !Task.isCancelled else {
            return .cancelledAfterPrefix(
                requestID: requestID,
                inspectedEntryCount: 0,
                cleanupCommitURLs: []
            )
        }

        let entries: [URL]
        do {
            entries = try access.contentsOfDirectory(itemsDirectory)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            watermarkLog.error("Failed to enumerate Watermark library: \(error.localizedDescription, privacy: .private)")
            return .loaded(WatermarkLibrarySnapshot(
                requestID: requestID,
                assets: [],
                imageDataByAssetID: [:],
                inspectedEntryCount: 0,
                cleanupCommitURLs: []
            ))
        }

        var inspected = 0
        var cleanupCommits: [URL] = []
        var tombstoned = Set<UUID>()
        let decoder = JSONDecoder()
        let now = Date()

        for url in entries where url.pathExtension == "deleted" {
            guard !Task.isCancelled else {
                return .cancelledAfterPrefix(
                    requestID: requestID,
                    inspectedEntryCount: inspected,
                    cleanupCommitURLs: cleanupCommits
                )
            }
            inspected += 1
            guard let data = try? access.readData(url),
                  let tombstone = try? decoder.decode(WatermarkTombstone.self, from: data) else {
                if let id = assetID(fromTombstoneURL: url) {
                    tombstoned.insert(id)
                } else if removeIfPresent(url) {
                    cleanupCommits.append(url)
                }
                continue
            }
            if now.timeIntervalSince(tombstone.deletedAt) >= Self.tombstoneRetention {
                if removeIfPresent(url) { cleanupCommits.append(url) }
            } else {
                tombstoned.insert(tombstone.id)
            }
        }

        var loaded: [WatermarkAsset] = []
        var imageDataByAssetID: [UUID: Data] = [:]
        for directory in entries {
            guard !Task.isCancelled else {
                return .cancelledAfterPrefix(
                    requestID: requestID,
                    inspectedEntryCount: inspected,
                    cleanupCommitURLs: cleanupCommits
                )
            }
            guard access.isDirectory(directory) else { continue }
            inspected += 1
            guard let id = assetID(fromItemDirectory: directory) else { continue }
            if tombstoned.contains(id) {
                if removeIfPresent(directory) { cleanupCommits.append(directory) }
                continue
            }
            guard let asset = loadAssetMeta(
                id: id,
                in: itemsDirectory,
                cleanupCommitURLs: &cleanupCommits
            ) else { continue }
            loaded.append(asset)
            let imageURL = imageFileURL(for: id, in: itemsDirectory)
            if let data = try? access.readData(imageURL) {
                imageDataByAssetID[id] = data
            }
        }

        guard !Task.isCancelled else {
            return .cancelledAfterPrefix(
                requestID: requestID,
                inspectedEntryCount: inspected,
                cleanupCommitURLs: cleanupCommits
            )
        }
        loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return .loaded(WatermarkLibrarySnapshot(
            requestID: requestID,
            assets: loaded,
            imageDataByAssetID: imageDataByAssetID,
            inspectedEntryCount: inspected,
            cleanupCommitURLs: cleanupCommits
        ))
    }

    func upsertMetadata(
        _ asset: WatermarkAsset,
        in rootDirectory: URL,
        requestID: UUID
    ) throws -> WatermarkLibraryMetadataResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID)
        }
        let itemsDirectory = itemsDirectory(in: rootDirectory)
        try access.ensureDirectory(rootDirectory)
        try access.ensureDirectory(itemsDirectory)
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID)
        }
        let metadataURL = metadataFileURL(for: asset.id, in: itemsDirectory)
        try writeAsset(asset, to: metadataURL)
        return .committed(WatermarkLibraryMetadataCommit(
            requestID: requestID,
            asset: asset,
            metadataURL: metadataURL,
            cancellationRequestedAfterCommit: Task.isCancelled
        ))
    }

    func delete(
        assetID: UUID,
        in rootDirectory: URL,
        requestID: UUID,
        deletionIO: DurableDeletionIO
    ) throws -> WatermarkLibraryDeleteResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID, assetID: assetID)
        }
        let itemsDirectory = itemsDirectory(in: rootDirectory)
        try access.ensureDirectory(rootDirectory)
        try access.ensureDirectory(itemsDirectory)
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID, assetID: assetID)
        }
        let marker = WatermarkTombstone(id: assetID, deletedAt: Date())
        let markerURL = tombstoneURL(for: assetID, in: itemsDirectory)
        try DurableDeletionTransaction.execute(
            marker: marker,
            markerURL: markerURL,
            recordURL: itemDirectory(for: assetID, in: itemsDirectory),
            markerMatches: { $0.id == assetID },
            io: deletionIO
        )
        return .committed(WatermarkLibraryDeleteCommit(
            requestID: requestID,
            assetID: assetID,
            markerURL: markerURL,
            cancellationRequestedAfterCommit: Task.isCancelled
        ))
    }

    private static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60

    private func itemsDirectory(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("items", isDirectory: true)
    }

    private func itemDirectory(for id: UUID, in itemsDirectory: URL) -> URL {
        itemsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func metadataFileURL(for id: UUID, in itemsDirectory: URL) -> URL {
        itemDirectory(for: id, in: itemsDirectory).appendingPathComponent("meta.json")
    }

    private func imageFileURL(for id: UUID, in itemsDirectory: URL) -> URL {
        itemDirectory(for: id, in: itemsDirectory).appendingPathComponent("image.png")
    }

    private func tombstoneURL(for id: UUID, in itemsDirectory: URL) -> URL {
        itemsDirectory.appendingPathComponent("\(id.uuidString).deleted")
    }

    private func assetID(fromItemDirectory url: URL) -> UUID? {
        UUID(uuidString: url.lastPathComponent)
    }

    private func assetID(fromTombstoneURL url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    private func removeIfPresent(_ url: URL) -> Bool {
        do {
            try access.removeItem(url)
            return true
        } catch {
            watermarkLog.error("Failed to clean Watermark item \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func loadAssetMeta(
        id: UUID,
        in itemsDirectory: URL,
        cleanupCommitURLs: inout [URL]
    ) -> WatermarkAsset? {
        let url = metadataFileURL(for: id, in: itemsDirectory)
        if let resolved = resolveConflicts(at: url, cleanupCommitURLs: &cleanupCommitURLs) {
            return resolved
        }
        do {
            return try JSONDecoder().decode(WatermarkAsset.self, from: access.readData(url))
        } catch {
            watermarkLog.error("Failed to load watermark meta \(id.uuidString, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    private func writeAsset(_ asset: WatermarkAsset, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try access.writeData(try encoder.encode(asset), url)
    }

    private func resolveConflicts(
        at url: URL,
        cleanupCommitURLs: inout [URL]
    ) -> WatermarkAsset? {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflicts.isEmpty else { return nil }
        let decoder = JSONDecoder()
        var records: [WatermarkAsset] = []
        if let currentData = try? access.readData(url),
           let current = try? decoder.decode(WatermarkAsset.self, from: currentData) {
            records.append(current)
        }
        for version in conflicts {
            if let data = try? Data(contentsOf: version.url),
               let asset = try? decoder.decode(WatermarkAsset.self, from: data) {
                records.append(asset)
            }
        }
        guard let merged = records.max(by: { $0.updatedAt < $1.updatedAt }) else {
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
            return nil
        }
        do {
            try writeAsset(merged, to: url)
            cleanupCommitURLs.append(url)
            for version in conflicts { version.isResolved = true }
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
        } catch {
            watermarkLog.error("Failed to resolve conflicts for \(merged.id.uuidString, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
        return merged
    }
}

/// Global, optionally iCloud-synced library of watermark PNGs (name + image), referenced by
/// `WatermarkLayer.libraryAssetID` in the develop layer chain.
///
/// Mirrors `RosterStore`'s one-record-per-file layout, but each record is a *folder*
/// (`items/<uuid>/meta.json` + `items/<uuid>/image.png`) rather than a flat `<uuid>.json`,
/// since a watermark carries a binary asset alongside its metadata — keeping both files
/// under one item folder lets `CloudCoordinatedIO` sync them together. Deletion tombstones
/// (`<uuid>.deleted`) live as flat siblings of the item folders under `items/`.
///
/// `@Observable` so SwiftUI editors bind to `assets` directly; a notification is also
/// posted for any imperative listeners (e.g. the edit view's watermark picker).
@MainActor
@Observable
final class WatermarkStore {

    static let shared = WatermarkStore()

    /// The current library, sorted by name. Source of truth is the on-disk folders; this is
    /// the in-memory listing, refreshed lazily and on remote changes.
    private(set) var assets: [WatermarkAsset] = []
    private var imageDataByAssetID: [UUID: Data] = [:]

    /// Test-only seam: overrides the resolved storage root so tests can point at a temp
    /// directory. Production never sets this. `nonisolated(unsafe)` so the Metal texture
    /// loader (`resolvedImageURL`, called off-main during offscreen export) can read it
    /// without actor isolation; tests only ever touch it serially.
    @ObservationIgnored nonisolated(unsafe) static var storageOverrideURL: URL?
    @ObservationIgnored static var deletionIO = DurableDeletionIO.live

    @ObservationIgnored private let injectedStorageRoot: URL?
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var cachedDirectory: URL?
    @ObservationIgnored private var recentLocalWrites: [String: Date] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadRequestID = UUID()
    @ObservationIgnored private let persistence: WatermarkLibraryPersistenceService

    private static let selfWriteWindow: TimeInterval = 10
    private static let selfWriteTolerance: TimeInterval = 3

    init(
        storageRoot: URL? = nil,
        persistence: WatermarkLibraryPersistenceService = .shared
    ) {
        injectedStorageRoot = storageRoot
        self.persistence = persistence
    }

    // MARK: - Storage paths

    /// Local fallback: `<App Support>/Aagedal Photo Agent/Watermarks`.
    nonisolated static var localWatermarksDirectory: URL {
        AppPaths.applicationSupport.appendingPathComponent("Watermarks", isDirectory: true)
    }

    private func resolveWatermarksRootDirectory(requestID: UUID) async -> URL? {
        if let cached = cachedDirectory { return cached }
        let url: URL
        if let injectedStorageRoot {
            url = injectedStorageRoot
        } else if let override = Self.storageOverrideURL {
            url = override
        } else {
            let syncEnabled = UserDefaults.standard.bool(
                forKey: UserDefaultsKeys.watermarksICloudEnabled
            )
            url = await LibraryICloudRoutingService.watermarks.storageURL(
                syncEnabled: syncEnabled
            )
        }
        guard loadRequestID == requestID, !Task.isCancelled else { return nil }
        cachedDirectory = url
        return url
    }

    private var loadedRootDirectory: URL {
        guard let cachedDirectory else {
            preconditionFailure("Watermark storage must be resolved before use")
        }
        return cachedDirectory
    }

    private var itemsDirectory: URL {
        loadedRootDirectory.appendingPathComponent("items", isDirectory: true)
    }

    private func imageFileURL(for id: UUID) -> URL {
        itemsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("image.png")
    }

    /// Deterministic image-file path for an asset, independent of the singleton's cached
    /// state — used by `MetalEditPipeline`'s texture loader, which may run on the offscreen
    /// render queue (not MainActor) and so can't touch `WatermarkStore.shared`'s
    /// actor-isolated `assets` list. Recomputes the iCloud-vs-local root on every call
    /// (a UserDefaults + ubiquity-container check). Production call sites use this only on
    /// worker/executor paths; MainActor presentation reads the store's published byte cache.
    nonisolated static func resolvedImageURL(forAssetID id: UUID) -> URL {
        let root: URL
        if let override = storageOverrideURL {
            root = override
        } else if UserDefaults.standard.bool(forKey: UserDefaultsKeys.watermarksICloudEnabled),
                  let cloud = AppPaths.iCloudWatermarksURL {
            root = cloud
        } else {
            root = localWatermarksDirectory
        }
        return root.appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("image.png")
    }

    // MARK: - Self-write filtering

    private func stampLocalWrite(_ url: URL) {
        let now = Date()
        recentLocalWrites[url.standardizedFileURL.path] = now
        recentLocalWrites = recentLocalWrites.filter { now.timeIntervalSince($0.value) < Self.selfWriteWindow }
    }

    /// Whether a remote-change notification is just an echo of our own write.
    func shouldSkipRemoteReload(path: String, contentChangeDate: Date?) -> Bool {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let stamped = recentLocalWrites[key] else { return false }
        if Date().timeIntervalSince(stamped) >= Self.selfWriteWindow {
            recentLocalWrites[key] = nil
            return false
        }
        guard let changeDate = contentChangeDate else { return true }
        return abs(changeDate.timeIntervalSince(stamped)) <= Self.selfWriteTolerance
    }

    // MARK: - Load

    /// Drops in-memory state and asynchronously re-reads from disk. Called after the backing
    /// directory changes (iCloud toggle).
    func reloadAfterStorageChange(resolvedStorageURL: URL? = nil) async {
        invalidateStorageCache(resolvedStorageURL: resolvedStorageURL)
        await loadIfNeeded()
    }

    /// Test and lifecycle seam that invalidates cached presentation without starting filesystem
    /// work. Production route changes normally use ``reloadAfterStorageChange``.
    func invalidateStorageCache(resolvedStorageURL: URL? = nil) {
        cachedDirectory = resolvedStorageURL
        didLoad = false
        loadTask?.cancel()
        loadTask = nil
        assets = []
        imageDataByAssetID = [:]
    }

    func loadIfNeeded() async {
        if didLoad { return }
        if let loadTask {
            await loadTask.value
            return
        }

        let requestID = UUID()
        loadRequestID = requestID
        let task = Task { @MainActor [weak self, persistence] in
            guard let self else { return }
            guard let root = await self.resolveWatermarksRootDirectory(
                requestID: requestID
            ) else { return }
            let result = await persistence.load(from: root, requestID: requestID)
            guard self.loadRequestID == requestID else { return }
            self.loadTask = nil
            switch result {
            case .loaded(let snapshot) where snapshot.requestID == requestID:
                snapshot.cleanupCommitURLs.forEach(self.stampLocalWrite)
                self.assets = snapshot.assets
                self.imageDataByAssetID = snapshot.imageDataByAssetID
                self.didLoad = true
                NotificationCenter.default.post(name: .watermarkLibraryDidChange, object: nil)
            case .cancelledAfterPrefix(let resultID, _, let cleanupCommitURLs)
                where resultID == requestID:
                cleanupCommitURLs.forEach(self.stampLocalWrite)
            case .cancelledBeforeAccess, .cancelledAfterPrefix, .loaded:
                break
            }
        }
        loadTask = task
        await task.value
    }

    private func scheduleLoadIfNeeded() {
        guard !didLoad, loadTask == nil else { return }
        Task { @MainActor [weak self] in
            await self?.loadIfNeeded()
        }
    }

    /// Returns the current immutable in-memory snapshot. First access schedules its disk load.
    func allAssets() -> [WatermarkAsset] {
        scheduleLoadIfNeeded()
        return assets
    }

    func asset(byID id: UUID) -> WatermarkAsset? {
        scheduleLoadIfNeeded()
        return assets.first { $0.id == id }
    }

    /// The PNG bytes for an asset — used by the Settings preview and, at render time, by
    /// the Metal texture loader.
    func imageData(forAssetID id: UUID) -> Data? {
        scheduleLoadIfNeeded()
        return imageDataByAssetID[id]
    }

    /// Local-filesystem URL for the asset's PNG. Stable across calls (not a temp copy), so
    /// the Metal texture loader can key its cache on path + modification date. nil if the
    /// asset doesn't exist.
    func imageURL(forAssetID id: UUID) -> URL? {
        scheduleLoadIfNeeded()
        guard assets.contains(where: { $0.id == id }) else { return nil }
        return imageFileURL(for: id)
    }

    private func sortAndNotify() {
        assets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        NotificationCenter.default.post(name: .watermarkLibraryDidChange, object: nil)
    }

    // MARK: - CRUD

    /// Imports a PNG from an arbitrary source URL (e.g. a `.fileImporter` result), decodes
    /// its pixel dimensions, copies the bytes into this item's own folder, and adds it to
    /// the library. Throws `WatermarkImportError.notAPNG` if the file isn't a readable image.
    func importPNG(
        from sourceURL: URL,
        name: String,
        requestID: UUID
    ) async throws -> WatermarkLibraryImportResult {
        await loadIfNeeded()
        let result = try await persistence.importPNG(
            from: sourceURL,
            name: name,
            into: itemsDirectory,
            requestID: requestID
        )
        if case .committed(let commit) = result {
            stampLocalWrite(commit.imageURL)
            stampLocalWrite(commit.metadataURL)
            imageDataByAssetID[commit.asset.id] = commit.imageData
            if let index = assets.firstIndex(where: { $0.id == commit.asset.id }) {
                assets[index] = commit.asset
            } else {
                assets.append(commit.asset)
            }
            sortAndNotify()
        }
        return result
    }

    /// Convenience for non-UI callers. Interactive owners should keep the request ID so they can
    /// reject stale presentation while the store still publishes every durable commit.
    @discardableResult
    func importPNG(from sourceURL: URL, name: String) async throws -> WatermarkAsset {
        let result = try await importPNG(
            from: sourceURL,
            name: name,
            requestID: UUID()
        )
        guard case .committed(let commit) = result else {
            throw CancellationError()
        }
        return commit.asset
    }

    /// Renames an existing asset in place.
    func rename(_ id: UUID, to newName: String) async throws {
        await loadIfNeeded()
        guard var asset = assets.first(where: { $0.id == id }) else { return }
        asset.name = newName
        asset.updatedAt = Date()
        let result = try await persistence.upsertMetadata(
            asset,
            in: loadedRootDirectory,
            requestID: UUID()
        )
        guard case .committed(let commit) = result else { return }
        stampLocalWrite(commit.metadataURL)
        if let index = assets.firstIndex(where: { $0.id == id }) {
            assets[index] = commit.asset
        }
        sortAndNotify()
    }

    /// Updates an asset's default placement (applied to newly-added layers created from it).
    func updateDefaults(
        _ id: UUID,
        sizeDimension: WatermarkDimension,
        sizeUnit: WatermarkSizeUnit,
        sizeValue: Double,
        marginUnit: WatermarkMarginUnit,
        marginValue: Double
    ) async throws {
        await loadIfNeeded()
        guard var asset = assets.first(where: { $0.id == id }) else { return }
        asset.defaultSizeDimension = sizeDimension
        asset.defaultSizeUnit = sizeUnit
        asset.defaultSizeValue = sizeValue
        asset.defaultMarginUnit = marginUnit
        asset.defaultMarginValue = marginValue
        asset.updatedAt = Date()
        let result = try await persistence.upsertMetadata(
            asset,
            in: loadedRootDirectory,
            requestID: UUID()
        )
        guard case .committed(let commit) = result else { return }
        stampLocalWrite(commit.metadataURL)
        if let index = assets.firstIndex(where: { $0.id == id }) {
            assets[index] = commit.asset
        }
        sortAndNotify()
    }

    func delete(id: UUID) async throws {
        await loadIfNeeded()
        let result = try await persistence.delete(
            assetID: id,
            in: loadedRootDirectory,
            requestID: UUID(),
            deletionIO: Self.deletionIO
        )
        guard case .committed(let commit) = result else { return }
        stampLocalWrite(commit.markerURL)
        assets.removeAll { $0.id == id }
        imageDataByAssetID[id] = nil
        NotificationCenter.default.post(name: .watermarkLibraryDidChange, object: nil)
    }

    // MARK: - Remote changes

    /// Filters remote events against recent local writes, then replaces the cache with one
    /// complete actor-loaded snapshot so metadata and PNG bytes cannot publish from different
    /// iCloud generations.
    func applyRemoteChanges(_ changes: [(url: URL, contentChangeDate: Date?)]) async {
        let hasExternalChange = changes.contains { change in
            !shouldSkipRemoteReload(path: change.url.path, contentChangeDate: change.contentChangeDate)
        }
        guard hasExternalChange else { return }
        didLoad = false
        loadTask?.cancel()
        loadTask = nil
        await loadIfNeeded()
    }
}

/// Deletion marker so a delete propagates over iCloud and can't be resurrected by a peer
/// that still holds the item.
nonisolated struct WatermarkTombstone: Codable, Sendable {
    let id: UUID
    let deletedAt: Date
}
