import Foundation
import os

private let prefsSyncLog = Logger(subsystem: "com.aagedal.photo-agent", category: "PreferencesSyncService")

/// Mirrors a curated set of portable app preferences between `UserDefaults` and
/// `NSUbiquitousKeyValueStore` so they follow the user across Macs.
///
/// Only device-independent preferences are synced. Machine-specific values
/// (file paths, security-scoped bookmarks, certificate locations, FTP details)
/// are deliberately excluded — see `syncedKeys`.
@MainActor
final class PreferencesSyncService {
    static let shared = PreferencesSyncService()

    private let kvs = NSUbiquitousKeyValueStore.default
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
        UserDefaultsKeys.showOriginalThumbnails,
        UserDefaultsKeys.defaultEditDestination,
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
        // Face recognition
        UserDefaultsKeys.faceCleanupPolicy,
        UserDefaultsKeys.faceMinConfidence,
        UserDefaultsKeys.faceMinFaceSize,
        UserDefaultsKeys.faceMinQuality,
        UserDefaultsKeys.knownPeopleMinConfidence,
        // Format & compression
        UserDefaultsKeys.exportFormatSDR,
        UserDefaultsKeys.exportFormatHDR,
        UserDefaultsKeys.exportQualitySDR,
        UserDefaultsKeys.exportQualityHDR,
        UserDefaultsKeys.exportTIFFCompression,
        UserDefaultsKeys.exportColorGamutSDR,
        UserDefaultsKeys.exportColorGamutHDR,
        // Import behavior (portable modes only, not backup folders)
        UserDefaultsKeys.importVerificationMode,
        UserDefaultsKeys.importBackupVerifyAfterWrite,
        UserDefaultsKeys.importFileTypeFilter,
        UserDefaultsKeys.importGroupByYear,
        UserDefaultsKeys.importDateFolderGrouping,
        // Signing author name (portable; the certificate itself is not synced)
        UserDefaultsKeys.c2paDefaultAuthor,
    ]

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.preferencesICloudEnabled)
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

    /// Turns preference sync on or off. On enable, seeds the cloud store with the
    /// current local values so other devices converge on this Mac's settings.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.preferencesICloudEnabled)
        if enabled {
            installObservers()
            pushLocalToRemote(keys: Self.syncedKeys)
            kvs.synchronize()
        } else {
            removeObservers()
        }
        return true
    }

    // MARK: - Observers

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        // Block-based observers pinned to the main queue. Both handlers touch
        // `@MainActor` state, and `UserDefaults.didChangeNotification` (as well
        // as the KVS notification) can be posted from a background thread — e.g.
        // `registerDefaults:` invoked off-main. The old target/selector form ran
        // the handler synchronously on the posting thread, which tripped the
        // Swift MainActor executor check (SIGTRAP). Forcing main-queue delivery
        // and asserting isolation keeps the handlers on the main actor.
        observerTokens.append(center.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs,
            queue: .main
        ) { [weak self] note in
            // Extract the Sendable key list before hopping — `Notification`
            // itself is not Sendable and can't cross into the actor closure.
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { self?.remoteStoreChanged(changedKeys: changed) }
        })
        observerTokens.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.localDefaultsChanged() }
        })
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

    private func pushLocalToRemote(keys: [String]) {
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = defaults.object(forKey: key) {
                kvs.set(value, forKey: key)
            } else {
                kvs.removeObject(forKey: key)
            }
        }
    }

    private func applyRemoteToLocal(keys: [String]) {
        let defaults = UserDefaults.standard
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
