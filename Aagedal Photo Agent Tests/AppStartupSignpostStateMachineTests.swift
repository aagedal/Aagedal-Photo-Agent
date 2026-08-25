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
