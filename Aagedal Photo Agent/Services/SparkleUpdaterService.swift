import Combine
import Foundation
import Sparkle

@MainActor
final class SparkleUpdaterService: NSObject, ObservableObject {
    static let shared = SparkleUpdaterService()

    let controller: SPUStandardUpdaterController
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
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: Self.shouldStartUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
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
