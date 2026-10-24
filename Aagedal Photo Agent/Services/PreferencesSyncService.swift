import Foundation
import os

private let prefsSyncLog = Logger(subsystem: "com.aagedal.photo-agent", category: "PreferencesSyncService")

/// The cloud key-value store preferences mirror into. `NSUbiquitousKeyValueStore` in the app;
/// tests inject an in-memory store so they never touch real iCloud.
@MainActor
protocol PreferencesCloudKeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: PreferencesCloudKeyValueStore {}

/// Mirrors a curated set of portable app preferences between `UserDefaults` and
/// `NSUbiquitousKeyValueStore` so they follow the user across Macs.
///
/// Only device-independent preferences are synced. Machine-specific values
/// (file paths, security-scoped bookmarks, certificate locations, FTP details)
/// are deliberately excluded — see `syncedKeys`.
@MainActor
final class PreferencesSyncService {
    static let shared = PreferencesSyncService()

    private let kvs: any PreferencesCloudKeyValueStore
    private let defaults: UserDefaults
    private var observersInstalled = false
    /// Tokens for the block-based notification observers so they can be removed.
    private var observerTokens: [NSObjectProtocol] = []
    /// Guards against the local→cloud mirror echoing a change we just pulled
    /// from the cloud (which would otherwise re-write identical values).
    private var isApplyingRemote = false
    private var pushWorkItem: DispatchWorkItem?

    /// Portable preference keys. Anything tied to a specific machine (paths,
    /// bookmarks, certificates, FTP, window geometry) is intentionally absent.
    static let syncedKeys: [String] = [
        // Browser / preview
        UserDefaultsKeys.rawRenderAsHDR,
        UserDefaultsKeys.rawDecodeProfile,
        UserDefaultsKeys.rawDecoderVersionPreference,
        UserDefaultsKeys.showAllFiles,
        UserDefaultsKeys.browserFileVisibility,
        UserDefaultsKeys.showOriginalThumbnails,
        UserDefaultsKeys.defaultEditDestination,
        UserDefaultsKeys.hiddenDevelopSliders,
        UserDefaultsKeys.developSectionOrder,
        UserDefaultsKeys.thumbnailSortOrder,
        UserDefaultsKeys.thumbnailSortReversed,
        UserDefaultsKeys.previewMode,
        // Metadata behavior
        UserDefaultsKeys.metadataWritePreset,
        UserDefaultsKeys.metadataWriteModeNonC2PA,
        UserDefaultsKeys.metadataWriteModeC2PA,
        UserDefaultsKeys.metadataWriteModeRaw,
        UserDefaultsKeys.multiSelectKeywordsMode,
        UserDefaultsKeys.multiSelectPersonShownMode,
        UserDefaultsKeys.addJobIdToKeywords,
        UserDefaultsKeys.structuredPersonShownCategoriesAsKeywords,
        UserDefaultsKeys.hiddenIPTCMetadataFields,
        UserDefaultsKeys.iptcMetadataFieldOrder,
        // Face recognition
        UserDefaultsKeys.faceCleanupPolicy,
        UserDefaultsKeys.faceMinConfidence,
        UserDefaultsKeys.faceMinFaceSize,
        UserDefaultsKeys.faceMinQuality,
        UserDefaultsKeys.faceTiledDetection,
        UserDefaultsKeys.knownPeopleMinConfidence,
        // Format & compression
        UserDefaultsKeys.exportFormatSDR,
        UserDefaultsKeys.exportFormatHDR,
        UserDefaultsKeys.exportQualitySDR,
        UserDefaultsKeys.exportQualityHDR,
        UserDefaultsKeys.exportResolutionLimit,
        UserDefaultsKeys.exportTIFFCompression,
        UserDefaultsKeys.exportColorGamutSDR,
        UserDefaultsKeys.exportColorGamutHDR,
        // Import behavior (portable modes only, not backup folders)
        UserDefaultsKeys.importVerificationMode,
        UserDefaultsKeys.importBackupVerifyAfterWrite,
        UserDefaultsKeys.importFileTypeFilter,
        UserDefaultsKeys.importConflictPolicy,
        UserDefaultsKeys.importCreateSubFolders,
        UserDefaultsKeys.importSortByDate,
        UserDefaultsKeys.importGroupByYear,
        UserDefaultsKeys.importDateFolderGrouping,
        UserDefaultsKeys.importSkipPreviouslyImported,
        UserDefaultsKeys.importSplitShootsIntoSubfolders,
        // Signing author name (portable; the certificate itself is not synced)
        UserDefaultsKeys.c2paDefaultAuthor,
    ]

    init(
        kvs: any PreferencesCloudKeyValueStore = NSUbiquitousKeyValueStore.default,
        defaults: UserDefaults = AppDefaults.store
    ) {
        self.kvs = kvs
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.bool(forKey: UserDefaultsKeys.preferencesICloudEnabled)
    }

    /// Posted after remote preference values are written into `UserDefaults` so
    /// open views can re-read them if they choose to observe.
    static let didChangeRemotely = Notification.Name("PreferencesSyncService.didChangeRemotely")

    /// Call once at launch. Installs observers and pulls any newer cloud values
    /// when sync is already enabled.
    func start() {
        guard isEnabled else { return }
        installObservers()
        kvs.synchronize()
        applyRemoteToLocal(keys: Self.syncedKeys)
    }

    /// Cloud key naming the device that last pushed preferences, and when.
    /// Not in `syncedKeys`, so it is never copied into local defaults.
    static let lastWriterKey = "preferencesSync.lastWriter"
    /// Local-only identity of this Mac for `lastWriterKey`.
    static let deviceIDKey = "preferencesSync.deviceID"
    /// Local-only time of this Mac's last push.
    static let lastPushTimeKey = "preferencesSync.lastPushTime"

    private var deviceID: String {
        if let id = defaults.string(forKey: Self.deviceIDKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.deviceIDKey)
        return id
    }

    /// Turns preference sync on or off.
    ///
    /// On enable, whoever pushed last decides the direction. When this Mac wrote the cloud copy
    /// last (sync is being turned back on here), local values are pushed as before, so settings
    /// changed while sync was off are not reverted to the old cloud copy. When another Mac wrote
    /// last (or the cloud copy predates the marker), the cloud wins: its values are applied
    /// here first and only keys the cloud lacks are seeded, so a second Mac adopts the first
    /// Mac's settings instead of overwriting them or removing keys it never set.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        defaults.set(enabled, forKey: UserDefaultsKeys.preferencesICloudEnabled)
        if enabled {
            kvs.synchronize()
            let lastWriter = (kvs.object(forKey: Self.lastWriterKey) as? [String: Any])?["device"] as? String
            if lastWriter == deviceID {
                pushLocalToRemote(keys: Self.syncedKeys)
            } else {
                let cloudKeys = Self.syncedKeys.filter { kvs.object(forKey: $0) != nil }
                if !cloudKeys.isEmpty {
                    applyRemoteToLocal(keys: cloudKeys)
                }
                let missingInCloud = Self.syncedKeys.filter { kvs.object(forKey: $0) == nil }
                seedRemote(keys: missingInCloud)
            }
            kvs.synchronize()
            installObservers()
        } else {
            removeObservers()
        }
        return true
    }

    private func stampLastWriter() {
        let now = Date().timeIntervalSince1970
        kvs.set(["device": deviceID, "time": now], forKey: Self.lastWriterKey)
        defaults.set(now, forKey: Self.lastPushTimeKey)
    }

    // MARK: - Observers

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        // NotificationCenter's main OperationQueue delivery can synchronously block
        // a background poster. RAW decoder initialization posts defaults changes
        // while holding its once lock; waiting for MainActor here can deadlock a
        // main-thread ImageIO reader. Receive inline, then enqueue background posts.
        // Preserve inline main-thread handling so isApplyingRemote still prevents
        // local notifications from echoing a remote preference update.
        observerTokens.append(center.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs as AnyObject,
            queue: nil
        ) { [weak self] note in
            // Extract the Sendable key list before hopping — `Notification`
            // itself is not Sendable and can't cross into the actor closure.
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            Self.deliverNotification { [weak self] in self?.remoteStoreChanged(changedKeys: changed) }
        })
        observerTokens.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Self.deliverNotification { [weak self] in self?.localDefaultsChanged() }
        })
    }

    /// Never make a background notification poster wait for the main actor.
    /// Main-thread delivery stays synchronous to preserve the remote-update echo guard.
    nonisolated static func deliverNotification(_ action: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { action() }
        } else {
            Task { @MainActor in action() }
        }
    }

    private func removeObservers() {
        guard observersInstalled else { return }
        observersInstalled = false
        let center = NotificationCenter.default
        for token in observerTokens { center.removeObserver(token) }
        observerTokens.removeAll()
    }

    private func remoteStoreChanged(changedKeys: [String]?) {
        let keys = changedKeys.map { $0.filter(Set(Self.syncedKeys).contains) } ?? Self.syncedKeys
        guard !keys.isEmpty else { return }
        applyRemoteToLocal(keys: keys)
    }

    private func localDefaultsChanged() {
        guard isEnabled, !isApplyingRemote else { return }
        // Coalesce bursts of `didSet` writes into a single cloud push.
        pushWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pushLocalToRemote(keys: Self.syncedKeys)
            self.kvs.synchronize()
        }
        pushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Mirroring

    /// Writes local values for keys the cloud lacks; never removes anything from the cloud.
    private func seedRemote(keys: [String]) {
        var wrote = false
        for key in keys {
            if let value = defaults.object(forKey: key) {
                kvs.set(value, forKey: key)
                wrote = true
            }
        }
        // Adopting the cloud copy without adding anything leaves the other Mac as last writer.
        if wrote { stampLastWriter() }
    }

    private func pushLocalToRemote(keys: [String]) {
        for key in keys {
            if let value = defaults.object(forKey: key) {
                kvs.set(value, forKey: key)
            } else {
                kvs.removeObject(forKey: key)
            }
        }
        stampLastWriter()
    }

    private func applyRemoteToLocal(keys: [String]) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        for key in keys {
            if let value = kvs.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        NotificationCenter.default.post(name: Self.didChangeRemotely, object: nil)
    }
}
