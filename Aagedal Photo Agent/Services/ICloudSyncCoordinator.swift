import Foundation
import os

private let cloudSyncLog = Logger(subsystem: "com.aagedal.photo-agent", category: "ICloudSyncCoordinator")

/// Single entry point the Sync settings UI binds to. Owns the per-category
/// iCloud opt-in toggles and the data movement they imply:
///
/// - **Preferences** → delegates to `PreferencesSyncService` (key-value store).
/// - **Keyword lists** → delegates to `KeywordListsStore` (already file-backed).
/// - **Templates** / **Known People** → flips a flag and copies the backing
///   directory between the local Application Support folder and the iCloud
///   ubiquity container.
@MainActor
@Observable
final class ICloudSyncCoordinator {
    static let shared = ICloudSyncCoordinator()

    /// Bumped after any toggle so SwiftUI re-reads the derived `*Enabled` values.
    private(set) var version = 0

    /// Last failure reason for the most recent toggle, surfaced in the UI.
    private(set) var lastError: String?

    /// Whether iCloud Drive is reachable for this app right now.
    var iCloudAvailable: Bool {
        AppPaths.iCloudDocuments != nil
    }

    // MARK: - Preferences (key-value store)

    var preferencesEnabled: Bool {
        _ = version
        return PreferencesSyncService.shared.isEnabled
    }

    func setPreferencesEnabled(_ on: Bool) {
        lastError = nil
        if on && !iCloudAvailable {
            lastError = Self.unavailableMessage
            bump()
            return
        }
        PreferencesSyncService.shared.setEnabled(on)
        bump()
    }

    // MARK: - Keyword lists

    var keywordListsEnabled: Bool {
        _ = version
        return KeywordListsStore.shared.iCloudEnabled
    }

    func setKeywordListsEnabled(_ on: Bool) {
        lastError = nil
        let ok = KeywordListsStore.shared.setICloudEnabled(on)
        if !ok {
            lastError = KeywordListsStore.shared.lastSyncError ?? Self.unavailableMessage
        }
        KeywordListsCloudCoordinator.shared.refresh()
        bump()
    }

    // MARK: - Templates

    var templatesEnabled: Bool {
        _ = version
        return UserDefaults.standard.bool(forKey: UserDefaultsKeys.templatesICloudEnabled)
    }

    func setTemplatesEnabled(_ on: Bool) {
        lastError = nil
        do {
            if on {
                guard let cloud = AppPaths.iCloudTemplatesURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                let (current, release) = AppPaths.templatesDirectory()
                defer { release() }
                try mergeCopy(from: current, to: cloud)
                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.templatesICloudEnabled)
            } else {
                let (current, release) = AppPaths.templatesDirectory()
                UserDefaults.standard.set(false, forKey: UserDefaultsKeys.templatesICloudEnabled)
                let (dest, release2) = AppPaths.templatesDirectory()
                try? mergeCopy(from: current, to: dest)
                release()
                release2()
            }
        } catch {
            lastError = "Could not move templates into iCloud Drive: \(error.localizedDescription)"
        }
        bump()
    }

    // MARK: - Known People

    var knownPeopleEnabled: Bool {
        _ = version
        return UserDefaults.standard.bool(forKey: UserDefaultsKeys.knownPeopleICloudEnabled)
    }

    func setKnownPeopleEnabled(_ on: Bool) {
        lastError = nil
        do {
            if on {
                guard let cloud = AppPaths.iCloudKnownPeopleURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                try mergeCopy(from: KnownPeopleService.localKnownPeopleDirectory, to: cloud)
                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.knownPeopleICloudEnabled)
            } else {
                if let cloud = AppPaths.iCloudKnownPeopleURL {
                    try? mergeCopy(from: cloud, to: KnownPeopleService.localKnownPeopleDirectory)
                }
                UserDefaults.standard.set(false, forKey: UserDefaultsKeys.knownPeopleICloudEnabled)
            }
            KnownPeopleService.shared.reloadAfterStorageChange()
        } catch {
            lastError = "Could not move the Known People database into iCloud Drive: \(error.localizedDescription)"
        }
        bump()
    }

    // MARK: - Helpers

    private static let unavailableMessage =
        "iCloud Drive is not available. Sign in to iCloud in System Settings and enable iCloud Drive for this app."

    private func bump() { version &+= 1 }

    /// Recursively copies the contents of `src` into `dst`, overwriting files
    /// with the same name and preserving subdirectories. Missing source folders
    /// are treated as empty (nothing to copy). Coordinated via `NSFileCoordinator`
    /// so moving data into the ubiquity container doesn't fork conflict folders.
    private func mergeCopy(from src: URL, to dst: URL) throws {
        try CloudCoordinatedIO.mergeCopy(from: src, to: dst)
    }
}
