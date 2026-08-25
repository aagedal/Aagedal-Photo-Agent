import Foundation
import os.log
import AppKit

private let watermarkLog = Logger(
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

    /// Test-only seam: overrides the resolved storage root so tests can point at a temp
    /// directory. Production never sets this. `nonisolated(unsafe)` so the Metal texture
    /// loader (`resolvedImageURL`, called off-main during offscreen export) can read it
    /// without actor isolation; tests only ever touch it serially.
    @ObservationIgnored nonisolated(unsafe) static var storageOverrideURL: URL?
    @ObservationIgnored static var deletionIO = DurableDeletionIO.live

    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var cachedDirectory: URL?
    @ObservationIgnored private var recentLocalWrites: [String: Date] = [:]

    private static let selfWriteWindow: TimeInterval = 10
    private static let selfWriteTolerance: TimeInterval = 3
    private static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60

    private init() {}

    // MARK: - Storage paths

    /// Local fallback: `<App Support>/Aagedal Photo Agent/Watermarks`.
    nonisolated static var localWatermarksDirectory: URL {
        AppPaths.applicationSupport.appendingPathComponent("Watermarks", isDirectory: true)
    }

    private var watermarksRootDirectory: URL {
        if let cached = cachedDirectory { return cached }
        let url: URL
        if let override = Self.storageOverrideURL {
            url = override
        } else if UserDefaults.standard.bool(forKey: UserDefaultsKeys.watermarksICloudEnabled),
                  let cloud = AppPaths.iCloudWatermarksURL {
            url = cloud
        } else {
            url = Self.localWatermarksDirectory
        }
        try? CloudCoordinatedIO.ensureDirectory(url)
        try? CloudCoordinatedIO.ensureDirectory(url.appendingPathComponent("items", isDirectory: true))
        cachedDirectory = url
        return url
    }

    private var itemsDirectory: URL {
        watermarksRootDirectory.appendingPathComponent("items", isDirectory: true)
    }

    private func itemDirectory(for id: UUID) -> URL {
        itemsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func metaFileURL(for id: UUID) -> URL {
        itemDirectory(for: id).appendingPathComponent("meta.json")
    }

    private func imageFileURL(for id: UUID) -> URL {
        itemDirectory(for: id).appendingPathComponent("image.png")
    }

    private func tombstoneURL(for id: UUID) -> URL {
        itemsDirectory.appendingPathComponent("\(id.uuidString).deleted")
    }

    /// Deterministic image-file path for an asset, independent of the singleton's cached
    /// state — used by `MetalEditPipeline`'s texture loader, which may run on the offscreen
    /// render queue (not MainActor) and so can't touch `WatermarkStore.shared`'s
    /// actor-isolated `assets` list. Recomputes the iCloud-vs-local root on every call
    /// (a cheap UserDefaults + FileManager check), matching the cost `ensureLoaded()`'s
    /// first access already pays.
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

    private func assetID(fromItemDirectory url: URL) -> UUID? {
        UUID(uuidString: url.lastPathComponent)
    }

    private func assetID(fromTombstoneURL url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
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

    /// Drops in-memory state and re-reads from disk. Called after the backing directory
    /// changes (iCloud toggle).
    func reloadAfterStorageChange() {
        cachedDirectory = nil
        didLoad = false
        ensureLoaded()
        NotificationCenter.default.post(name: .watermarkLibraryDidChange, object: nil)
    }

    /// Loads the library from disk once. The directory listing *is* the library.
    private func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true

        let entries = (try? CloudCoordinatedIO.contentsOfDirectory(at: itemsDirectory)) ?? []
        let itemDirs = entries.filter { isDirectory($0) }
        let tombstoneFiles = entries.filter { $0.pathExtension == "deleted" }
        let tombstoned = collectTombstones(in: tombstoneFiles)

        var loaded: [WatermarkAsset] = []
        for dir in itemDirs {
            guard let id = assetID(fromItemDirectory: dir) else { continue }
            if tombstoned.contains(id) {
                try? CloudCoordinatedIO.removeItem(at: dir)
                continue
            }
            guard let asset = loadAssetMeta(id: id) else { continue }
            loaded.append(asset)
        }
        assets = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// Public accessor that guarantees the library is loaded.
    func allAssets() -> [WatermarkAsset] {
        ensureLoaded()
        return assets
    }

    func asset(byID id: UUID) -> WatermarkAsset? {
        ensureLoaded()
        return assets.first { $0.id == id }
    }

    /// The PNG bytes for an asset — used by the Settings preview and, at render time, by
    /// the Metal texture loader.
    func imageData(forAssetID id: UUID) -> Data? {
        try? CloudCoordinatedIO.readData(at: imageFileURL(for: id))
    }

    /// Local-filesystem URL for the asset's PNG. Stable across calls (not a temp copy), so
    /// the Metal texture loader can key its cache on path + modification date. nil if the
    /// asset doesn't exist.
    func imageURL(forAssetID id: UUID) -> URL? {
        ensureLoaded()
        guard assets.contains(where: { $0.id == id }) else { return nil }
        return imageFileURL(for: id)
    }

    private func loadAssetMeta(id: UUID) -> WatermarkAsset? {
        if let resolved = resolveConflicts(id: id) {
            return resolved
        }
        let url = metaFileURL(for: id)
        do {
            let data = try CloudCoordinatedIO.readData(at: url)
            return try JSONDecoder().decode(WatermarkAsset.self, from: data)
        } catch {
            watermarkLog.error("Failed to load watermark meta \(id.uuidString, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    // MARK: - Write

    private func writeAsset(_ asset: WatermarkAsset, imageData: Data? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metaData = try encoder.encode(asset)
        let metaURL = metaFileURL(for: asset.id)
        try CloudCoordinatedIO.writeData(metaData, to: metaURL)
        stampLocalWrite(metaURL)
        if let imageData {
            let imageURL = imageFileURL(for: asset.id)
            try CloudCoordinatedIO.writeData(imageData, to: imageURL)
            stampLocalWrite(imageURL)
        }
    }

    private func sortAndNotify() {
        assets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        NotificationCenter.default.post(name: .watermarkLibraryDidChange, object: nil)
    }

    // MARK: - CRUD

    /// Imports a PNG from an arbitrary source URL (e.g. a `.fileImporter` result), decodes
    /// its pixel dimensions, copies the bytes into this item's own folder, and adds it to
    /// the library. Throws `WatermarkImportError.notAPNG` if the file isn't a readable image.
    @discardableResult
    func importPNG(from sourceURL: URL, name: String) throws -> WatermarkAsset {
        ensureLoaded()
        let data = try Data(contentsOf: sourceURL)
        guard let rep = NSBitmapImageRep(data: data) else { throw WatermarkImportError.notAPNG }
        let asset = WatermarkAsset(name: name, pixelWidth: rep.pixelsWide, pixelHeight: rep.pixelsHigh)
        try writeAsset(asset, imageData: data)
        assets.append(asset)
        sortAndNotify()
        return asset
    }

    /// Renames an existing asset in place.
    func rename(_ id: UUID, to newName: String) throws {
        ensureLoaded()
        guard var asset = assets.first(where: { $0.id == id }) else { return }
        asset.name = newName
        asset.updatedAt = Date()
        try writeAsset(asset)
        if let index = assets.firstIndex(where: { $0.id == id }) {
            assets[index] = asset
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
    ) throws {
        ensureLoaded()
        guard var asset = assets.first(where: { $0.id == id }) else { return }
        asset.defaultSizeDimension = sizeDimension
        asset.defaultSizeUnit = sizeUnit
        asset.defaultSizeValue = sizeValue
        asset.defaultMarginUnit = marginUnit
        asset.defaultMarginValue = marginValue
        asset.updatedAt = Date()
        try writeAsset(asset)
        if let index = assets.firstIndex(where: { $0.id == id }) {
            assets[index] = asset
        }
        sortAndNotify()
    }

    func delete(id: UUID) throws {
        ensureLoaded()
        let marker = WatermarkTombstone(id: id, deletedAt: Date())
        let markerURL = tombstoneURL(for: id)
        try DurableDeletionTransaction.execute(
            marker: marker,
            markerURL: markerURL,
            recordURL: itemDirectory(for: id),
            markerMatches: { $0.id == id },
            io: Self.deletionIO
        )
        stampLocalWrite(markerURL)
        assets.removeAll { $0.id == id }
        NotificationCenter.default.post(name: .watermarkLibraryDidChange, object: nil)
    }

    // MARK: - Tombstones

    private func collectTombstones(in tombstoneFiles: [URL]) -> Set<UUID> {
        let decoder = JSONDecoder()
        let now = Date()
        var tombstoned = Set<UUID>()
        for url in tombstoneFiles {
            guard let data = try? CloudCoordinatedIO.readData(at: url),
                  let tombstone = try? decoder.decode(WatermarkTombstone.self, from: data) else {
                if let id = assetID(fromTombstoneURL: url) {
                    tombstoned.insert(id)
                } else {
                    try? CloudCoordinatedIO.removeItem(at: url)
                }
                continue
            }
            if now.timeIntervalSince(tombstone.deletedAt) >= Self.tombstoneRetention {
                try? CloudCoordinatedIO.removeItem(at: url)
            } else {
                tombstoned.insert(tombstone.id)
            }
        }
        return tombstoned
    }

    // MARK: - Conflict resolution

    /// Resolve iCloud conflict versions of an item's `meta.json` by keeping the record with
    /// the newest `updatedAt`, rewriting the file and clearing the versions. The image PNG
    /// is immutable after import (rename doesn't touch it), so unlike Teams' whole-record
    /// merge this only needs to resolve the metadata file — a conflicting `image.png` from
    /// a simultaneous import under the same UUID is a vanishingly unlikely edge case, not
    /// handled here. No-op locally.
    private func resolveConflicts(id: UUID) -> WatermarkAsset? {
        let url = metaFileURL(for: id)
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflicts.isEmpty else {
            return nil
        }
        let decoder = JSONDecoder()
        var records: [WatermarkAsset] = []
        if let currentData = try? CloudCoordinatedIO.readData(at: url),
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
            try writeAsset(merged)
            for version in conflicts { version.isResolved = true }
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
        } catch {
            watermarkLog.error("Failed to resolve conflicts for \(id.uuidString, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
        return merged
    }

    // MARK: - Remote changes

    /// Applies remote changes to individual item folders from the iCloud watcher. `changes`
    /// are `meta.json`/`image.png`/`.deleted` file events; grouped by their parent item's
    /// UUID since a single remote sync event may touch more than one file per item.
    func applyRemoteChanges(_ changes: [(url: URL, contentChangeDate: Date?)]) {
        ensureLoaded()
        var didChange = false
        var touchedIDs = Set<UUID>()

        for change in changes {
            let url = change.url
            guard !shouldSkipRemoteReload(path: url.path, contentChangeDate: change.contentChangeDate) else { continue }

            if url.pathExtension == "deleted" {
                guard let id = assetID(fromTombstoneURL: url) else { continue }
                if assets.contains(where: { $0.id == id }) {
                    assets.removeAll { $0.id == id }
                    didChange = true
                }
                try? CloudCoordinatedIO.removeItem(at: itemDirectory(for: id))
                continue
            }
            // meta.json / image.png — parent directory name is the item's UUID.
            guard let id = assetID(fromItemDirectory: url.deletingLastPathComponent()) else { continue }
            touchedIDs.insert(id)
        }

        for id in touchedIDs {
            if CloudCoordinatedIO.itemExists(at: tombstoneURL(for: id)) {
                try? CloudCoordinatedIO.removeItem(at: itemDirectory(for: id))
                if assets.contains(where: { $0.id == id }) {
                    assets.removeAll { $0.id == id }
                    didChange = true
                }
                continue
            }
            if let asset = loadAssetMeta(id: id) {
                if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                    assets[index] = asset
                } else {
                    assets.append(asset)
                }
                didChange = true
            } else if !CloudCoordinatedIO.itemExists(at: metaFileURL(for: id)) {
                if assets.contains(where: { $0.id == id }) {
                    assets.removeAll { $0.id == id }
                    didChange = true
                }
            }
        }
        if didChange { sortAndNotify() }
    }
}

/// Deletion marker so a delete propagates over iCloud and can't be resurrected by a peer
/// that still holds the item.
nonisolated struct WatermarkTombstone: Codable, Sendable {
    let id: UUID
    let deletedAt: Date
}
