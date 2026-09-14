import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("UI test launch configuration")
struct UITestLaunchConfigurationTests {
    @Test("Known People workflow and disposable root require the UI-testing gate")
    func knownPeopleWorkflowIsGated() {
        let root = "/private/tmp/Aagedal Known People UI Test"
        let enabled = UITestLaunchConfiguration(arguments: [
            "Aagedal Photo Agent",
            "--ui-testing",
            "--ui-test-workflow", "known-people-interchange",
            "--ui-test-known-people-root", root,
        ])

        #expect(enabled.isEnabled)
        #expect(enabled.workflow == .knownPeopleInterchange)
        #expect(enabled.knownPeopleRootURL?.path == root)

        let production = UITestLaunchConfiguration(arguments: [
            "Aagedal Photo Agent",
            "--ui-test-workflow", "known-people-interchange",
            "--ui-test-known-people-root", root,
        ])

        #expect(!production.isEnabled)
        #expect(production.workflow == .knownPeopleInterchange)
        #expect(production.knownPeopleRootURL == nil)
    }

    @Test("A missing disposable root stays absent")
    func missingRoot() {
        let configuration = UITestLaunchConfiguration(arguments: [
            "Aagedal Photo Agent", "--ui-testing",
            "--ui-test-workflow", "known-people-interchange",
        ])

        #expect(configuration.workflow == .knownPeopleInterchange)
        #expect(configuration.knownPeopleRootURL == nil)
    }

    @Test("A disposable template root requires the UI-testing gate")
    func templateRootIsGated() {
        let root = "/private/tmp/Aagedal Template UI Test"
        let enabled = UITestLaunchConfiguration(arguments: [
            "Aagedal Photo Agent", "--ui-testing",
            "--ui-test-workflow", "caption",
            "--ui-test-template-root", root,
        ])
        #expect(enabled.templateRootURL?.path == root)

        let production = UITestLaunchConfiguration(arguments: [
            "Aagedal Photo Agent",
            "--ui-test-template-root", root,
        ])
        #expect(production.templateRootURL == nil)
    }

    @Test("Voice-memo variable batch workflow is explicit")
    func voiceMemoVariableBatchWorkflow() {
        let configuration = UITestLaunchConfiguration(arguments: [
            "Aagedal Photo Agent", "--ui-testing",
            "--ui-test-workflow", "voice-memo-variable-batch",
        ])
        #expect(configuration.workflow == .voiceMemoVariableBatch)
    }
}
