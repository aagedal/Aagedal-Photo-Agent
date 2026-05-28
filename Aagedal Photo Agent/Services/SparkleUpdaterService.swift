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

    override init() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: !Self.isHomebrewInstall,
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
