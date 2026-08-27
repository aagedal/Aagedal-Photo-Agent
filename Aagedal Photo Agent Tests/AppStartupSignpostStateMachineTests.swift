import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("Scene app command router")
@MainActor
struct AppCommandRouterTests {
    @Test("folder commands preserve their typed payloads")
    func folderCommandPayloads() throws {
        let router = AppCommandRouter()
        let recentFolder = URL(fileURLWithPath: "/tmp/recent-folder", isDirectory: true)

        #expect(router.latestDelivery == nil)

        router.send(.openFolder)
        #expect(router.latestDelivery == AppCommandDelivery(
            sequence: 1,
            command: .openFolder
        ))

        router.send(.openRecentFolder(recentFolder))
        let delivery = try #require(router.latestDelivery)
        #expect(delivery.sequence == 2)
        #expect(delivery.command == .openRecentFolder(recentFolder))
    }

    @Test("repeated commands remain distinct deliveries")
    func repeatedCommandsAreDistinct() throws {
        let router = AppCommandRouter()

        router.send(.openFolder)
        let first = try #require(router.latestDelivery)
        router.send(.openFolder)
        let second = try #require(router.latestDelivery)

        #expect(first.command == second.command)
        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(first != second)
    }

    @Test("rating and label commands preserve their domain payloads")
    func cullingCommandPayloads() throws {
        let router = AppCommandRouter()

        router.send(.setRating(.three))
        #expect(try #require(router.latestDelivery).command == .setRating(.three))

        router.send(.setLabel(.red))
        #expect(try #require(router.latestDelivery).command == .setLabel(.red))
        #expect(try #require(router.latestDelivery).sequence == 2)
    }

    @Test("export commands preserve operation identity and archive format")
    func exportCommandPayloads() throws {
        let router = AppCommandRouter()

        router.send(.renderSelected)
        #expect(try #require(router.latestDelivery).command == .renderSelected)

        router.send(.advancedExportSelected)
        #expect(try #require(router.latestDelivery).command == .advancedExportSelected)

        router.send(.archiveRAW(.dngLossless))
        #expect(try #require(router.latestDelivery).command == .archiveRAW(.dngLossless))
        #expect(try #require(router.latestDelivery).sequence == 3)
    }

    @Test("image navigation commands preserve direction and ordering")
    func navigationCommandIdentity() throws {
        let router = AppCommandRouter()

        router.send(.selectPreviousImage)
        #expect(try #require(router.latestDelivery).command == .selectPreviousImage)

        router.send(.selectNextImage)
        #expect(try #require(router.latestDelivery).command == .selectNextImage)
        #expect(try #require(router.latestDelivery).sequence == 2)
    }
}

@Suite("App startup signpost lifecycle")
struct AppStartupSignpostStateMachineTests {
    @Test("cold launch is emitted once and ends at first content appearance")
    func coldLaunchIsBalancedAndIdempotent() {
        var machine = AppStartupSignpostStateMachine()

        #expect(machine.handle(.processStarted) == [.beginColdLaunch])
        #expect(machine.handle(.processStarted).isEmpty)
        #expect(machine.handle(.mainContentAppeared) == [.endColdLaunch])
        #expect(machine.handle(.mainContentAppeared).isEmpty)
    }

    @Test("warm activation starts only after cold launch and balances duplicate callbacks")
    func warmActivationRequiresCompletedColdLaunch() {
        var machine = AppStartupSignpostStateMachine()

        #expect(machine.handle(.applicationWillBecomeActive).isEmpty)
        #expect(machine.handle(.applicationDidBecomeActive).isEmpty)
        #expect(machine.handle(.processStarted) == [.beginColdLaunch])
        #expect(machine.handle(.applicationWillBecomeActive).isEmpty)
        #expect(machine.handle(.mainContentAppeared) == [.endColdLaunch])
        #expect(machine.handle(.applicationWillBecomeActive) == [.beginWarmActivation])
        #expect(machine.handle(.applicationWillBecomeActive).isEmpty)
        #expect(machine.handle(.applicationDidBecomeActive) == [.endWarmActivation])
        #expect(machine.handle(.applicationDidBecomeActive).isEmpty)
        #expect(machine.handle(.applicationWillBecomeActive) == [.beginWarmActivation])
        #expect(machine.handle(.applicationDidBecomeActive) == [.endWarmActivation])
    }

    @Test("first folder interaction publishes one aggregate-only result")
    func firstFolderInteractionIsRecordedOnce() {
        var machine = AppStartupSignpostStateMachine()

        #expect(machine.handle(.firstFolderLoadFinished(.failed)).isEmpty)
        #expect(machine.handle(.firstFolderLoadStarted) == [.beginFirstFolderInteraction])
        #expect(machine.handle(.firstFolderLoadStarted).isEmpty)
        #expect(machine.handle(.firstFolderLoadFinished(.ready(itemCount: 42))) == [
            .endFirstFolderInteraction(.ready(itemCount: 42))
        ])
        #expect(machine.handle(.firstFolderLoadFinished(.failed)).isEmpty)
        #expect(machine.handle(.firstFolderLoadStarted).isEmpty)
    }

    @Test("a failed first folder interaction is balanced and terminal")
    func firstFolderFailureIsBalanced() {
        var machine = AppStartupSignpostStateMachine()

        #expect(machine.handle(.firstFolderLoadStarted) == [.beginFirstFolderInteraction])
        #expect(machine.handle(.firstFolderLoadFinished(.failed)) == [
            .endFirstFolderInteraction(.failed)
        ])
        #expect(machine.handle(.firstFolderLoadStarted).isEmpty)
    }
}

@Suite("Deferred app startup work")
@MainActor
struct AppStartupWorkCoordinatorTests {
    @Test("first paint schedules dependency-ordered work exactly once")
    func schedulesOrderedWorkOnce() async {
        var events: [String] = []
        let coordinator = AppStartupWorkCoordinator(dependencies: AppStartupWorkDependencies(
            migrateKeywordLists: { events.append("keyword migration") },
            migrateKnownPeople: { events.append("known people migration") },
            startCloudWatchers: { events.append("cloud watchers") },
            startPortableServices: { events.append("portable services") },
            refreshC2PATrustList: { events.append("trust list") }
        ))

        #expect(coordinator.state == .idle)
        coordinator.startAfterFirstPaint()
        coordinator.startAfterFirstPaint()
        #expect(coordinator.state == .scheduled)

        await coordinator.waitUntilFinished()

        #expect(coordinator.state == .finished)
        #expect(events == [
            "keyword migration",
            "known people migration",
            "cloud watchers",
            "portable services",
            "trust list",
        ])
    }

    @Test("cancellation stops later startup stages")
    func cancellationStopsLaterStages() async {
        var events: [String] = []
        let coordinator = AppStartupWorkCoordinator(dependencies: AppStartupWorkDependencies(
            migrateKeywordLists: {
                events.append("keyword migration")
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    // Expected when application termination cancels startup.
                }
            },
            migrateKnownPeople: { events.append("known people migration") },
            startCloudWatchers: { events.append("cloud watchers") },
            startPortableServices: { events.append("portable services") },
            refreshC2PATrustList: { events.append("trust list") }
        ))

        coordinator.startAfterFirstPaint()
        while events.isEmpty {
            await Task.yield()
        }
        coordinator.cancel()
        await coordinator.waitUntilFinished()

        #expect(coordinator.state == .cancelled)
        #expect(events == ["keyword migration"])
    }

    @Test("cancelling idle or completed work is harmless")
    func cancellationIsIdempotent() async {
        var runCount = 0
        let coordinator = AppStartupWorkCoordinator(dependencies: AppStartupWorkDependencies(
            migrateKeywordLists: { runCount += 1 },
            migrateKnownPeople: {},
            startCloudWatchers: {},
            startPortableServices: {},
            refreshC2PATrustList: {}
        ))

        coordinator.cancel()
        #expect(coordinator.state == .idle)
        coordinator.startAfterFirstPaint()
        await coordinator.waitUntilFinished()
        coordinator.cancel()
        coordinator.startAfterFirstPaint()

        #expect(coordinator.state == .finished)
        #expect(runCount == 1)
    }
}
