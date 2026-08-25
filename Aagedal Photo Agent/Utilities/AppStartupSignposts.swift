import Foundation
import os

/// Pure transition model for the app-startup Instruments intervals. Keeping lifecycle
/// decisions separate from `OSSignposter` makes duplicate SwiftUI/AppKit callbacks harmless
/// and lets tests prove every interval is balanced without depending on the unified log.
struct AppStartupSignpostStateMachine {
    enum Event: Equatable {
        case processStarted
        case mainContentAppeared
        case applicationWillBecomeActive
        case applicationDidBecomeActive
        case firstFolderLoadStarted
        case firstFolderLoadFinished(FirstFolderResult)
    }

    enum FirstFolderResult: Equatable {
        case ready(itemCount: Int)
        case failed
    }

    enum Action: Equatable {
        case beginColdLaunch
        case endColdLaunch
        case beginWarmActivation
        case endWarmActivation
        case beginFirstFolderInteraction
        case endFirstFolderInteraction(FirstFolderResult)
    }

    private enum Phase {
        case idle
        case inProgress
        case complete
    }

    private var coldLaunch: Phase = .idle
    private var warmActivation: Phase = .idle
    private var firstFolderInteraction: Phase = .idle

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .processStarted:
            guard coldLaunch == .idle else { return [] }
            coldLaunch = .inProgress
            return [.beginColdLaunch]

        case .mainContentAppeared:
            guard coldLaunch == .inProgress else { return [] }
            coldLaunch = .complete
            return [.endColdLaunch]

        case .applicationWillBecomeActive:
            guard coldLaunch == .complete, warmActivation != .inProgress else { return [] }
            warmActivation = .inProgress
            return [.beginWarmActivation]

        case .applicationDidBecomeActive:
            guard warmActivation == .inProgress else { return [] }
            warmActivation = .complete
            return [.endWarmActivation]

        case .firstFolderLoadStarted:
            guard firstFolderInteraction == .idle else { return [] }
            firstFolderInteraction = .inProgress
            return [.beginFirstFolderInteraction]

        case .firstFolderLoadFinished(let result):
            guard firstFolderInteraction == .inProgress else { return [] }
            firstFolderInteraction = .complete
            return [.endFirstFolderInteraction(result)]
        }
    }
}

/// Privacy-safe startup and first-folder intervals for Instruments' Points of Interest.
/// Signposts contain only static lifecycle labels plus an aggregate item count; paths,
/// filenames, identifiers, metadata, and other user content never cross this boundary.
@MainActor
final class AppStartupSignposts {
    static let shared = AppStartupSignposts()

    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "AppStartup"
    )
    private var stateMachine = AppStartupSignpostStateMachine()
    private var coldLaunchState: OSSignpostIntervalState?
    private var warmActivationState: OSSignpostIntervalState?
    private var firstFolderState: OSSignpostIntervalState?

    private init() {}

    func processStarted() {
        handle(.processStarted)
    }

    func mainContentAppeared() {
        handle(.mainContentAppeared)
    }

    func applicationWillBecomeActive() {
        handle(.applicationWillBecomeActive)
    }

    func applicationDidBecomeActive() {
        handle(.applicationDidBecomeActive)
    }

    func firstFolderLoadStarted() {
        handle(.firstFolderLoadStarted)
    }

    func firstFolderLoadReady(itemCount: Int) {
        handle(.firstFolderLoadFinished(.ready(itemCount: itemCount)))
    }

    func firstFolderLoadFailed() {
        handle(.firstFolderLoadFinished(.failed))
    }

    private func handle(_ event: AppStartupSignpostStateMachine.Event) {
        for action in stateMachine.handle(event) {
            switch action {
            case .beginColdLaunch:
                coldLaunchState = signposter.beginInterval(
                    "ColdLaunch",
                    id: signposter.makeSignpostID()
                )
            case .endColdLaunch:
                guard let state = coldLaunchState else { continue }
                signposter.endInterval("ColdLaunch", state)
                coldLaunchState = nil
            case .beginWarmActivation:
                warmActivationState = signposter.beginInterval(
                    "WarmLaunch",
                    id: signposter.makeSignpostID()
                )
            case .endWarmActivation:
                guard let state = warmActivationState else { continue }
                signposter.endInterval("WarmLaunch", state)
                warmActivationState = nil
            case .beginFirstFolderInteraction:
                firstFolderState = signposter.beginInterval(
                    "FirstFolderInteraction",
                    id: signposter.makeSignpostID()
                )
            case .endFirstFolderInteraction(.ready(let itemCount)):
                guard let state = firstFolderState else { continue }
                signposter.endInterval(
                    "FirstFolderInteraction",
                    state,
                    "result=ready itemCount=\(itemCount, privacy: .private)"
                )
                firstFolderState = nil
            case .endFirstFolderInteraction(.failed):
                guard let state = firstFolderState else { continue }
                signposter.endInterval(
                    "FirstFolderInteraction",
                    state,
                    "result=failed"
                )
                firstFolderState = nil
            }
        }
    }
}
