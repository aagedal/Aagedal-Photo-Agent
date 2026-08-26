import Testing
@testable import Aagedal_Photo_Agent

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
