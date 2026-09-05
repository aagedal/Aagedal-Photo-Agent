import Foundation

/// Injected startup operations keep orchestration testable without constructing the app's
/// singleton-backed persistence and cloud services. Every operation is main-actor isolated because
/// the stores/coordinators it starts own UI-observed state; expensive work inside those services is
/// responsible for crossing to its existing asynchronous boundary.
@MainActor
struct AppStartupWorkDependencies {
    var migrateKeywordLists: @MainActor () async -> Void
    var migrateKnownPeople: @MainActor () async -> Void
    var startCloudWatchers: @MainActor () async -> Void
    var startPortableServices: @MainActor () async -> Void
    var refreshC2PATrustList: @MainActor () async -> Void

    init(
        migrateKeywordLists: @escaping @MainActor () async -> Void,
        migrateKnownPeople: @escaping @MainActor () async -> Void,
        startCloudWatchers: @escaping @MainActor () async -> Void,
        startPortableServices: @escaping @MainActor () async -> Void,
        refreshC2PATrustList: @escaping @MainActor () async -> Void
    ) {
        self.migrateKeywordLists = migrateKeywordLists
        self.migrateKnownPeople = migrateKnownPeople
        self.startCloudWatchers = startCloudWatchers
        self.startPortableServices = startPortableServices
        self.refreshC2PATrustList = refreshC2PATrustList
    }

    static func production() -> AppStartupWorkDependencies {
        AppStartupWorkDependencies(
            migrateKeywordLists: {
                await KeywordListsStore.shared.migrateLegacyBookmarksIfNeeded()
            },
            migrateKnownPeople: {
                KnownPeopleService.shared.migrateLegacyDatabaseIfNeeded()
            },
            startCloudWatchers: {
                KeywordListsCloudCoordinator.shared.refresh()
                KnownPeopleCloudCoordinator.shared.refresh()
                RosterCloudCoordinator.shared.refresh()
                WatermarkCloudCoordinator.shared.refresh()
            },
            startPortableServices: {
                PreferencesSyncService.shared.start()
                KeywordListsBackupService.shared.start()
            },
            refreshC2PATrustList: {
                await C2PATrustListService.shared.refreshIfNeeded()
            }
        )
    }
}

/// Starts non-first-paint application work once, in dependency order, after SwiftUI has presented
/// the main content. The task is retained so application termination can cancel work that has not
/// started yet and tests can await a deterministic terminal state.
@MainActor
final class AppStartupWorkCoordinator {
    enum State: Equatable {
        case idle
        case scheduled
        case running
        case finished
        case cancelled
    }

    static let shared = AppStartupWorkCoordinator(dependencies: .production())

    private let dependencies: AppStartupWorkDependencies
    private var startupTask: Task<Void, Never>?
    private(set) var state: State = .idle

    init(dependencies: AppStartupWorkDependencies) {
        self.dependencies = dependencies
    }

    /// Idempotently schedules work after the current main-actor turn, allowing the first rendered
    /// content to be committed before any migration or watcher setup runs.
    func startAfterFirstPaint() {
        guard state == .idle else { return }
        state = .scheduled
        startupTask = Task { @MainActor [weak self] in
            // Do not compete with the SwiftUI appearance transaction that called this method.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }

            state = .running
            defer {
                startupTask = nil
                if state != .cancelled {
                    state = .finished
                }
            }

            // The legacy sources must be migrated before their corresponding cloud queries can
            // observe and reconcile files. Portable observers/backups start only after the stores
            // and queries are ready. The opportunistic network refresh is deliberately last.
            await dependencies.migrateKeywordLists()
            guard !Task.isCancelled else { return }
            await dependencies.migrateKnownPeople()
            guard !Task.isCancelled else { return }
            await dependencies.startCloudWatchers()
            guard !Task.isCancelled else { return }
            await dependencies.startPortableServices()
            guard !Task.isCancelled else { return }
            await dependencies.refreshC2PATrustList()
        }
    }

    func cancel() {
        guard state == .scheduled || state == .running else { return }
        state = .cancelled
        startupTask?.cancel()
    }

    func waitUntilFinished() async {
        await startupTask?.value
    }
}
