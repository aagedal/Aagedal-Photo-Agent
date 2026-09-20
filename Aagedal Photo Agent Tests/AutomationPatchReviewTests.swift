import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Local automation patch review presentation")
struct AutomationPatchReviewTests {
    private final class Fixture {
        let root: URL
        let photo: URL
        let authority: MCPAuthorizationStore
        let facade: MCPAutomationFacade
        let plans = MCPIPTCPatchPlanStore()
        let prepared: MCPJSONValue
        let planID: String
        let original: Data

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("patch-approval-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            photo = root.appendingPathComponent("frame.jpg")
            let pixels = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8,
                bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try #require(pixels.makeImage())
            let bytes = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image,
                [kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCHeadline: "Before"]] as CFDictionary)
            try #require(CGImageDestinationFinalize(destination))
            original = bytes as Data
            try original.write(to: photo)
            let box = MCPServerCoreTests.DataBox()
            authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
            try authority.addRoot(root)
            try authority.setEnabled(true)
            facade = MCPAutomationFacade(authorizationStore: authority)
            let metadata = try #require(MCPMetadataSnapshotReader.inspectPhoto(path: photo.path, facade: facade).objectValue)
            var arguments: [String: MCPJSONValue] = ["path": .string(photo.path), "operations": .array([
                .object(["field": .string("title"), "operation": .string("set"), "value": .string("After")])])]
            for key in ["sourceRevision", "xmpSidecarRevision", "appSidecarRevision"] { arguments[key] = metadata[key] }
            prepared = try MCPIPTCPatchPreparation.prepare(arguments: arguments, facade: facade, plans: plans)
            planID = try #require(prepared.objectValue?["planID"]?.stringValue)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// Holds a real receipt after the store grants it, deliberately ignoring task cancellation.
    /// This reproduces a service completion already in flight when native consent is cleared.
    private actor HeldApprovalService: AutomationPatchReviewServing {
        let underlying: AutomationPatchReviewService
        private var pending: CheckedContinuation<MCPIPTCPatchApprovalStore.Approval, Never>?
        private var receipt: MCPIPTCPatchApprovalStore.Approval?
        private(set) var revocations = 0
        var hasPendingApproval: Bool { pending != nil }

        init(_ underlying: AutomationPatchReviewService) { self.underlying = underlying }

        func inspect(planID: String) async throws -> AutomationPatchReview {
            try await underlying.inspect(planID: planID)
        }

        func approve(_ review: AutomationPatchReview) async throws -> MCPIPTCPatchApprovalStore.Approval {
            receipt = try await underlying.approve(review)
            return await withCheckedContinuation { pending = $0 }
        }

        func finishApproval() {
            guard let pending, let receipt else { return }
            self.pending = nil
            self.receipt = nil
            pending.resume(returning: receipt)
        }

        func revoke(_ receipt: MCPIPTCPatchApprovalStore.Approval) async {
            await underlying.revoke(receipt)
            revocations += 1
        }
    }

    @MainActor
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition(), "Timed out waiting for a controlled review transition")
    }

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

    @Test("Native review requires explicit consent and rechecks source bytes")
    func nativeConsent() async throws {
        let fixture = try Fixture()
        let service = AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade)
        let review = try await service.inspect(planID: fixture.planID)
        let otherSession = AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade)
        await #expect(throws: MCPIPTCPatchApprovalStore.Failure.invalidReview) {
            try await otherSession.approve(review)
        }
        let receipt = try await service.approve(review)
        #expect(receipt.planID == fixture.planID)
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
        await service.revoke(receipt)
        var changed = fixture.original
        changed.append(0)
        try changed.write(to: fixture.photo)
        await #expect(throws: (any Error).self) { try await service.approve(review) }
    }

    @Test("Presentation-only previews cannot grant consent")
    func presentationCannotApprove() async throws {
        let service = AutomationPatchReviewService()
        let review = try AutomationPatchReview(.object(preview()))
        await #expect(throws: MCPIPTCPatchApprovalStore.Failure.invalidReview) {
            try await service.approve(review)
        }
    }

    @Test("Clear and ID edits cancel pending review or approval presentation") @MainActor
    func modelLifecycle() async throws {
        let fixture = try Fixture()
        let model = AutomationPatchReviewModel(service:
            AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade))
        model.planID = fixture.planID
        model.inspect()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.review != nil)
        #expect(!model.isApproved)
        model.approveReviewedPlan()
        // No suspension: clear cancels the queued MainActor task before it enters the service.
        model.clear()
        #expect(!model.isApproved)
        #expect(!model.isLoading)
        #expect(model.review == nil)
        model.inspect()
        model.planID = UUID().uuidString.lowercased()
        #expect(model.review == nil)
        #expect(!model.isLoading)
        #expect(!model.isApproved)
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
    }

    @Test("A receipt completing after clear, ID edit or expiry is revoked", arguments: ["clear", "edit", "expire"])
    @MainActor
    func lateApprovalIsRevoked(action: String) async throws {
        let fixture = try Fixture()
        let service = HeldApprovalService(AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade))
        let model = AutomationPatchReviewModel(service: service)
        model.planID = fixture.planID
        model.inspect()
        try await waitUntil { !model.isLoading }
        let review = try #require(model.review)
        model.approveReviewedPlan()
        try await waitUntil { await service.hasPendingApproval }
        switch action {
        case "clear": model.clear()
        case "edit": model.planID = UUID().uuidString.lowercased()
        default: model.expireReview(at: review.expiresAt)
        }
        await service.finishApproval()
        try await waitUntil { await service.revocations == 1 }
        #expect(!model.isApproved)
        #expect(!model.isLoading)
        if action == "expire" {
            #expect(model.review?.planID == fixture.planID)
            #expect(model.isExpired)
            #expect(model.message == "This plan has expired. Prepare a new patch in your client.")
        } else {
            #expect(model.review == nil)
            #expect(model.message == nil)
        }
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
    }

    @Test("Expiry revokes existing consent exactly at the immutable deadline") @MainActor
    func modelExpiry() async throws {
        let fixture = try Fixture()
        let service = HeldApprovalService(AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade))
        let model = AutomationPatchReviewModel(service: service)
        model.planID = fixture.planID
        model.inspect()
        try await waitUntil { !model.isLoading }
        let review = try #require(model.review)
        model.approveReviewedPlan()
        try await waitUntil { await service.hasPendingApproval }
        await service.finishApproval()
        try await waitUntil { model.isApproved }
        model.expireReview(at: review.expiresAt.addingTimeInterval(-0.001))
        #expect(model.isApproved)
        #expect(model.message == nil)
        #expect(await service.revocations == 0)
        model.expireReview(at: review.expiresAt)
        #expect(!model.isApproved)
        #expect(!model.isLoading)
        #expect(model.review?.planID == fixture.planID)
        try await waitUntil { await service.revocations == 1 }
        model.expireReview(at: review.expiresAt.addingTimeInterval(1))
        #expect(model.isExpired)
        model.approveReviewedPlan()
        #expect(!model.isLoading)
        #expect(await service.revocations == 1)
        model.clear()
        #expect(!model.isExpired)
        #expect(model.review == nil)
        #expect(model.message == nil)
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
    }

    @Test("Receipt expiry while returning to the main actor cannot display approved consent") @MainActor
    func receiptExpiresBeforePresentation() async throws {
        let fixture = try Fixture()
        let service = HeldApprovalService(AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade))
        var now = Date()
        let model = AutomationPatchReviewModel(service: service, now: { now })
        model.planID = fixture.planID
        model.inspect()
        try await waitUntil { !model.isLoading }
        let review = try #require(model.review)
        model.approveReviewedPlan()
        try await waitUntil { await service.hasPendingApproval }
        now = review.expiresAt
        await service.finishApproval()
        try await waitUntil { !model.isLoading }
        #expect(model.isExpired)
        #expect(!model.isApproved)
        #expect(await service.revocations == 1)
        #expect(model.message == "This plan has expired. Prepare a new patch in your client.")
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
    }

}
