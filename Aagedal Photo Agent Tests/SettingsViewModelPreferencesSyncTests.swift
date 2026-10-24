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
