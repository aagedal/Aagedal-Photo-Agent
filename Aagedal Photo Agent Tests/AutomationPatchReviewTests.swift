import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Local automation patch review presentation")
struct AutomationPatchReviewTests {
    private func preview() -> [String: MCPJSONValue] {
        ["planID": .string(UUID().uuidString.lowercased()), "previewOnly": .bool(true),
         "commitAvailable": .bool(false), "canonicalPath": .string("/photos/å.jpg"),
         "expiresAt": .string("2030-01-01T00:00:00Z"),
         "changes": .array([.object(["field": .string("title"), "operation": .string("set"),
             "before": .string("Before"), "after": .string("**Untrusted** {text}\n新")])]),
         "preservationWarnings": .array([.string("No commit")]),
         "validation": .object(["issues": .array([])])]
    }

    @Test("Plain text and Unicode survive review without markup interpretation")
    func plainText() throws {
        let result = try AutomationPatchReview(.object(preview()))
        #expect(result.changes.first?.after == "**Untrusted** {text}\n新")
        #expect(result.path == "/photos/å.jpg")
        #expect(result.warnings == ["No commit"])
    }

    @Test("Repeatable values retain exact item boundaries")
    func arrayBoundaries() throws {
        var value = preview()
        value["changes"] = .array([.object(["field": .string("keywords"), "operation": .string("set"),
            "before": .array([]), "after": .array([.string("one\ntwo"), .string("three, four")])])])
        let result = try AutomationPatchReview(.object(value))
        let after = try #require(result.changes.first?.after.data(using: .utf8))
        #expect(try JSONDecoder().decode([String].self, from: after) == ["one\ntwo", "three, four"])
    }

    @Test("Invalid or mutating preview contracts cannot be displayed", arguments: ["commit", "duplicate", "missing"])
    func malformed(kind: String) throws {
        var value = preview()
        if kind == "commit" { value["commitAvailable"] = .bool(true) }
        if kind == "missing" { value["validation"] = nil }
        if kind == "duplicate", case .array(let items) = value["changes"] { value["changes"] = .array(items + items) }
        #expect(throws: MCPIPTCPatchPlanStore.Failure.invalidStorage) { try AutomationPatchReview(.object(value)) }
    }

    @Test("Invalid IDs fail locally and clearing removes the error") @MainActor
    func invalidID() {
        let model = AutomationPatchReviewModel()
        model.planID = "not a plan"
        model.inspect()
        #expect(model.message != nil)
        #expect(!model.isLoading)
        #expect(model.review == nil)
        model.clear()
        #expect(model.message == nil)
    }

    @Test("Fixture flags cannot activate outside UI testing or fall back when malformed") @MainActor
    func fixtureGate() throws {
        let normal = UITestLaunchConfiguration(arguments: ["--ui-test-patch-review-folder", "/unavailable"])
        #expect(try UITestPatchReviewFixture.makeService(configuration: normal) == nil)
        let missing = UITestLaunchConfiguration(arguments: ["--ui-testing", "--ui-test-patch-review-folder"])
        #expect(missing.patchReviewRequested)
        #expect(throws: UITestPatchReviewFixture.Failure.invalidFolder) {
            try UITestPatchReviewFixture.makeService(configuration: missing)
        }
    }
}
