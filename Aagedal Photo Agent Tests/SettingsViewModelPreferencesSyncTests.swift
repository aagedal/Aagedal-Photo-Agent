import Foundation
import Testing
@testable import Aagedal_Photo_Agent

/// iCloud preference sync writes pulled values straight into UserDefaults and posts
/// `PreferencesSyncService.didChangeRemotely`. The shared Settings model must pick them up
/// without echoing them back (which would re-push them to iCloud).
@MainActor
@Suite("Settings view model remote preference refresh")
struct SettingsViewModelPreferencesSyncTests {
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    private static let keys = [
        UserDefaultsKeys.exportQualitySDR,
        UserDefaultsKeys.exportFormatHDR,
        UserDefaultsKeys.showOriginalThumbnails,
        UserDefaultsKeys.browserFileVisibility,
        UserDefaultsKeys.hiddenDevelopSliders,
    ]

    @Test("Re-reading synced values updates the model without writing preferences back")
    func remoteChangeRefreshesWithoutWriteBack() {
        let store = AppDefaults.store
        let saved = Self.keys.map { store.object(forKey: $0) }
        defer {
            for (key, value) in zip(Self.keys, saved) { store.set(value, forKey: key) }
        }
        for key in Self.keys { store.removeObject(forKey: key) }

        let viewModel = SettingsViewModel()
        #expect(viewModel.exportQualitySDR == 0.92)
        #expect(viewModel.showOriginalThumbnails == false)
        #expect(viewModel.hiddenDevelopSliders.isEmpty)

        // What PreferencesSyncService.applyRemoteToLocal does for values from another Mac.
        store.set(0.5, forKey: UserDefaultsKeys.exportQualitySDR)
        store.set(ExportFormatHDR.heic10bit.rawValue, forKey: UserDefaultsKeys.exportFormatHDR)
        store.set(true, forKey: UserDefaultsKeys.showOriginalThumbnails)
        store.set(BrowserFileVisibility.media.rawValue, forKey: UserDefaultsKeys.browserFileVisibility)
        store.set([DevelopSlider.contrast.rawValue], forKey: UserDefaultsKeys.hiddenDevelopSliders)

        let defaultsWrites = Counter()
        let visibilityPosts = Counter()
        let center = NotificationCenter.default
        let writeToken = center.addObserver(
            forName: UserDefaults.didChangeNotification, object: store, queue: nil
        ) { _ in defaultsWrites.value += 1 }
        let visibilityToken = center.addObserver(
            forName: .showAllFilesChanged, object: nil, queue: nil
        ) { _ in visibilityPosts.value += 1 }
        defer {
            center.removeObserver(writeToken)
            center.removeObserver(visibilityToken)
        }

        // Call the refresh directly: the hosting app's own Settings model and browser panes
        // also observe the remote-change notification and would muddy the write count.
        viewModel.applyStoredValues()

        #expect(viewModel.exportQualitySDR == 0.5)
        #expect(viewModel.exportFormatHDR == .heic10bit)
        #expect(viewModel.showOriginalThumbnails)
        #expect(viewModel.fileVisibility == .media)
        #expect(viewModel.hiddenDevelopSliders == [.contrast])
        // Nothing was written back, so PreferencesSyncService has nothing to re-push...
        #expect(defaultsWrites.value == 0)
        // ...while the browser panes are still told the visibility changed.
        #expect(visibilityPosts.value == 1)
    }

    @Test("The remote-change notification refreshes the model, and later edits keep the other Mac's values")
    func editAfterRemoteChangeDoesNotRevert() {
        let store = AppDefaults.store
        let key = UserDefaultsKeys.hiddenDevelopSliders
        let saved = store.object(forKey: key)
        defer { store.set(saved, forKey: key) }
        store.removeObject(forKey: key)

        let viewModel = SettingsViewModel()
        store.set([DevelopSlider.contrast.rawValue], forKey: key)
        NotificationCenter.default.post(name: PreferencesSyncService.didChangeRemotely, object: nil)
        #expect(viewModel.hiddenDevelopSliders == [.contrast])

        viewModel.setDevelopSlider(.clarity, visible: false)

        #expect(store.stringArray(forKey: key) == [DevelopSlider.clarity.rawValue, DevelopSlider.contrast.rawValue])
    }
}

/// In-memory stand-in for `NSUbiquitousKeyValueStore`; tests never touch real iCloud.
@MainActor
private final class InMemoryCloudKeyValueStore: PreferencesCloudKeyValueStore {
    var values: [String: Any] = [:]
    private(set) var removedKeys: [String] = []
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) {
        removedKeys.append(key)
        values.removeValue(forKey: key)
    }
    @discardableResult func synchronize() -> Bool { true }
}

@MainActor
@Suite("Preferences sync enabling", .serialized)
struct PreferencesSyncEnablingTests {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "PreferencesSyncEnablingTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    @Test("enabling on a second Mac adopts the cloud settings and only seeds keys the cloud lacks")
    func enablingAdoptsExistingCloudValues() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cloud = InMemoryCloudKeyValueStore()
        cloud.values[UserDefaultsKeys.exportQualitySDR] = 0.5
        cloud.values[UserDefaultsKeys.thumbnailSortOrder] = "name"
        defaults.set(0.9, forKey: UserDefaultsKeys.exportQualitySDR)
        defaults.set("jpeg", forKey: UserDefaultsKeys.exportFormatSDR)

        let service = PreferencesSyncService(kvs: cloud, defaults: defaults)
        service.setEnabled(true)
        defer { service.setEnabled(false) }

        // The first Mac's settings win on this Mac…
        #expect(defaults.double(forKey: UserDefaultsKeys.exportQualitySDR) == 0.5)
        #expect(defaults.string(forKey: UserDefaultsKeys.thumbnailSortOrder) == "name")
        // …the cloud keeps them, gains only what it lacked, and loses nothing.
        #expect(cloud.values[UserDefaultsKeys.exportQualitySDR] as? Double == 0.5)
        #expect(cloud.values[UserDefaultsKeys.exportFormatSDR] as? String == "jpeg")
        #expect(cloud.values[UserDefaultsKeys.thumbnailSortOrder] as? String == "name")
        #expect(cloud.removedKeys.isEmpty)
    }

    @Test("enabling on the first Mac seeds the empty cloud with local values")
    func enablingSeedsEmptyCloud() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cloud = InMemoryCloudKeyValueStore()
        defaults.set(0.8, forKey: UserDefaultsKeys.exportQualitySDR)

        let service = PreferencesSyncService(kvs: cloud, defaults: defaults)
        service.setEnabled(true)
        defer { service.setEnabled(false) }

        #expect(cloud.values[UserDefaultsKeys.exportQualitySDR] as? Double == 0.8)
        #expect(cloud.removedKeys.isEmpty)
        #expect(defaults.bool(forKey: UserDefaultsKeys.preferencesICloudEnabled))
    }
}

@MainActor
@Suite("Preferences sync re-enabling", .serialized)
struct PreferencesSyncReEnablingTests {
    @Test("turning sync back on where it was last written pushes this Mac's newer local values")
    func reEnablingOnSameMacPushesLocal() throws {
        let suiteName = "PreferencesSyncReEnablingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cloud = InMemoryCloudKeyValueStore()
        defaults.set(0.8, forKey: UserDefaultsKeys.exportQualitySDR)

        let service = PreferencesSyncService(kvs: cloud, defaults: defaults)
        service.setEnabled(true)
        service.setEnabled(false)
        // Changed while sync was off; the cloud still holds the old copy.
        defaults.set(0.3, forKey: UserDefaultsKeys.exportQualitySDR)
        service.setEnabled(true)
        defer { service.setEnabled(false) }

        #expect(defaults.double(forKey: UserDefaultsKeys.exportQualitySDR) == 0.3)
        #expect(cloud.values[UserDefaultsKeys.exportQualitySDR] as? Double == 0.3)
    }

    @Test("when another Mac wrote last, enabling pulls its values first")
    func anotherMacWroteLastPulls() throws {
        let suiteName = "PreferencesSyncReEnablingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cloud = InMemoryCloudKeyValueStore()
        defaults.set(0.8, forKey: UserDefaultsKeys.exportQualitySDR)

        let service = PreferencesSyncService(kvs: cloud, defaults: defaults)
        service.setEnabled(true)
        service.setEnabled(false)
        // Another Mac pushes a newer value and becomes the last writer.
        cloud.values[UserDefaultsKeys.exportQualitySDR] = 0.5
        cloud.values[PreferencesSyncService.lastWriterKey] = ["device": "other-mac", "time": 1.0]
        defaults.set(0.3, forKey: UserDefaultsKeys.exportQualitySDR)
        service.setEnabled(true)
        defer { service.setEnabled(false) }

        #expect(defaults.double(forKey: UserDefaultsKeys.exportQualitySDR) == 0.5)
        #expect(cloud.values[UserDefaultsKeys.exportQualitySDR] as? Double == 0.5)
    }
}
