import Foundation
import os

private let cloudSyncLog = Logger(subsystem: "com.aagedal.photo-agent", category: "ICloudSyncCoordinator")

/// Every user-facing data category controlled by the master iCloud switch.
/// Keeping the master implementation driven by `allCases` prevents newly-added
/// categories from being omitted from either its displayed state or its action.
nonisolated enum ICloudSyncCategory: CaseIterable, Sendable {
    case preferences
    case keywordLists
    case templates
    case knownPeople
    case teams
    case watermarks
}

/// Single entry point the Sync settings UI binds to. Owns the per-category
/// iCloud opt-in toggles and the data movement they imply:
///
/// - **Preferences** → delegates to `PreferencesSyncService` (key-value store).
/// - **Keyword lists** → delegates to `KeywordListsStore` (already file-backed).
/// - **Templates** / **Known People** / **Teams** / **Watermarks** → flips a
///   flag and copies the backing directory between the local Application
///   Support folder and the iCloud ubiquity container.
@MainActor
@Observable
final class ICloudSyncCoordinator {
    static let shared = ICloudSyncCoordinator()

    nonisolated static let masterCategories = ICloudSyncCategory.allCases

    /// Bumped after any toggle so SwiftUI re-reads the derived `*Enabled` values.
    private(set) var version = 0

    /// Last failure reason for the most recent toggle, surfaced in the UI.
    private(set) var lastError: String?

    /// Whether iCloud Drive is reachable for this app right now.
    var iCloudAvailable: Bool {
        AppPaths.iCloudDocuments != nil
    }

    // MARK: - All categories

    /// True only when every category is currently syncing. The master toggle in
    /// Settings binds to this; a mixed state reads as off so flipping it on
    /// brings everything up.
    var allEnabled: Bool {
        _ = version
        return Self.masterCategories.allSatisfy { isEnabled($0) }
    }

    /// Enables or disables every category at once. Each per-category setter still
    /// runs its own data movement and availability check, and any failure remains
    /// surfaced in `lastError` after all categories have been attempted.
    func setAllEnabled(_ on: Bool) {
        var firstError: String?
        for category in Self.masterCategories {
            setEnabled(on, for: category)
            if firstError == nil { firstError = lastError }
        }
        // Each category setter clears its predecessor's error. Preserve the
        // first failure so a partially-applied master toggle remains visible.
        lastError = firstError
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
                let (current, release) = AppPaths.localTemplatesDirectory()
                defer { release() }
                try mergeCopy(from: current, to: cloud)
                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.templatesICloudEnabled)
            } else {
                guard let cloud = AppPaths.iCloudTemplatesURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                let (dest, release) = AppPaths.localTemplatesDirectory()
                defer { release() }
                try mergeCopy(from: cloud, to: dest)
                UserDefaults.standard.set(false, forKey: UserDefaultsKeys.templatesICloudEnabled)
            }
        } catch {
            lastError = "Could not reconcile templates with iCloud Drive: \(error.localizedDescription)"
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
                guard let cloud = AppPaths.iCloudKnownPeopleURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                try mergeCopy(from: cloud, to: KnownPeopleService.localKnownPeopleDirectory)
                UserDefaults.standard.set(false, forKey: UserDefaultsKeys.knownPeopleICloudEnabled)
            }
            KnownPeopleService.shared.reloadAfterStorageChange()
        } catch {
            lastError = "Could not reconcile the Known People database with iCloud Drive: \(error.localizedDescription)"
        }
        // Start/stop the remote-change watcher to match the new toggle state.
        KnownPeopleCloudCoordinator.shared.refresh()
        bump()
    }

    // MARK: - Teams library

    var teamsEnabled: Bool {
        _ = version
        return UserDefaults.standard.bool(forKey: UserDefaultsKeys.teamsICloudEnabled)
    }

    func setTeamsEnabled(_ on: Bool) {
        lastError = nil
        do {
            if on {
                guard let cloud = AppPaths.iCloudTeamsURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                try mergeCopy(from: RosterStore.localTeamsDirectory, to: cloud)
                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.teamsICloudEnabled)
            } else {
                guard let cloud = AppPaths.iCloudTeamsURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                try mergeCopy(from: cloud, to: RosterStore.localTeamsDirectory)
                UserDefaults.standard.set(false, forKey: UserDefaultsKeys.teamsICloudEnabled)
            }
            RosterStore.shared.reloadAfterStorageChange()
        } catch {
            lastError = "Could not reconcile the Teams library with iCloud Drive: \(error.localizedDescription)"
        }
        RosterCloudCoordinator.shared.refresh()
        bump()
    }

    // MARK: - Watermark library

    var watermarksEnabled: Bool {
        _ = version
        return UserDefaults.standard.bool(forKey: UserDefaultsKeys.watermarksICloudEnabled)
    }

    func setWatermarksEnabled(_ on: Bool) {
        lastError = nil
        do {
            if on {
                guard let cloud = AppPaths.iCloudWatermarksURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                try mergeCopy(from: WatermarkStore.localWatermarksDirectory, to: cloud)
                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.watermarksICloudEnabled)
            } else {
                guard let cloud = AppPaths.iCloudWatermarksURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                try mergeCopy(from: cloud, to: WatermarkStore.localWatermarksDirectory)
                UserDefaults.standard.set(false, forKey: UserDefaultsKeys.watermarksICloudEnabled)
            }
            WatermarkStore.shared.reloadAfterStorageChange()
        } catch {
            lastError = "Could not reconcile the Watermark library with iCloud Drive: \(error.localizedDescription)"
        }
        WatermarkCloudCoordinator.shared.refresh()
        bump()
    }

    // MARK: - Helpers

    private func isEnabled(_ category: ICloudSyncCategory) -> Bool {
        switch category {
        case .preferences: return preferencesEnabled
        case .keywordLists: return keywordListsEnabled
        case .templates: return templatesEnabled
        case .knownPeople: return knownPeopleEnabled
        case .teams: return teamsEnabled
        case .watermarks: return watermarksEnabled
        }
    }

    private func setEnabled(_ on: Bool, for category: ICloudSyncCategory) {
        switch category {
        case .preferences: setPreferencesEnabled(on)
        case .keywordLists: setKeywordListsEnabled(on)
        case .templates: setTemplatesEnabled(on)
        case .knownPeople: setKnownPeopleEnabled(on)
        case .teams: setTeamsEnabled(on)
        case .watermarks: setWatermarksEnabled(on)
        }
    }

    private static let unavailableMessage =
        "iCloud Drive is not available. Sign in to iCloud in System Settings and enable iCloud Drive for this app."

    private func bump() { version &+= 1 }

    /// Recursively copies the contents of `src` into `dst`, overwriting files
    /// with the same name and preserving subdirectories. Missing source folders
    /// are treated as empty (nothing to copy). Coordinated via `NSFileCoordinator`
    /// so moving data into the ubiquity container doesn't fork conflict folders.
    private func mergeCopy(from src: URL, to dst: URL) throws {
        try CloudCoordinatedIO.mergeCopyPreservingNewer(from: src, to: dst)
    }
}
