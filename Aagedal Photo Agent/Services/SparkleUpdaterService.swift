import Combine
import Foundation
import Sparkle

/// Selects the website mirror for one retry when the primary appcast cannot
/// be downloaded or parsed. Failures after the appcast loads (for example,
/// signature validation or installation errors) must not switch feeds.
private final class SparkleFeedFallbackDelegate: NSObject, SPUUpdaterDelegate {
    private let backupFeedURL: String
    private var isUsingBackupFeed = false
    private var didLoadAppcast = false

    init(backupFeedURL: String) {
        self.backupFeedURL = backupFeedURL
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        didLoadAppcast = false
        return isUsingBackupFeed ? backupFeedURL : nil
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        didLoadAppcast = true
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        let shouldRetry = !isUsingBackupFeed
            && !didLoadAppcast
            && Self.isFeedLoadFailure(error)

        if isUsingBackupFeed {
            isUsingBackupFeed = false
        }
        didLoadAppcast = false

        guard shouldRetry else { return }
        isUsingBackupFeed = true

        switch updateCheck {
        case .updates:
            updater.checkForUpdates()
        case .updatesInBackground:
            updater.checkForUpdatesInBackground()
        case .updateInformation:
            updater.checkForUpdateInformation()
        @unknown default:
            updater.checkForUpdatesInBackground()
        }
    }

    private static func isFeedLoadFailure(_ error: Error?) -> Bool {
        guard let error = error as NSError?,
              error.domain == SUSparkleErrorDomain
        else { return false }

        return error.code == SUError.downloadError.rawValue
            || error.code == SUError.appcastParseError.rawValue
            || error.code == SUError.appcastError.rawValue
    }
}

@MainActor
final class SparkleUpdaterService: NSObject, ObservableObject {
    static let shared = SparkleUpdaterService()

    let controller: SPUStandardUpdaterController
    private let feedFallbackDelegate: SparkleFeedFallbackDelegate
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    @Published var updateCheckInterval: TimeInterval {
        didSet { controller.updater.updateCheckInterval = updateCheckInterval }
    }

    private var cancellables: Set<AnyCancellable> = []

    static var isHomebrewInstall: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/Caskroom/") || path.contains("/homebrew/")
    }

    static var hasValidPublicKey: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty,
              key != "REPLACE_WITH_PUBLIC_KEY_FROM_GENERATE_KEYS",
              let decoded = Data(base64Encoded: key),
              decoded.count == 32
        else { return false }
        return true
    }

    static var shouldStartUpdater: Bool {
        !isHomebrewInstall && hasValidPublicKey
    }

    override init() {
        let feedFallbackDelegate = SparkleFeedFallbackDelegate(
            backupFeedURL: "https://aagedal.me/apps/appcast/photoagent.xml"
        )
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: Self.shouldStartUpdater,
            updaterDelegate: feedFallbackDelegate,
            userDriverDelegate: nil
        )
        self.feedFallbackDelegate = feedFallbackDelegate
        controller = updaterController
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        updateCheckInterval = updaterController.updater.updateCheckInterval
        super.init()

        updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
