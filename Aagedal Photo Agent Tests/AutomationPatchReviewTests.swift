import CoreGraphics
import ImageIO
import Darwin
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
            let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(canonical) }
            root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
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
        private(set) var publicationRevocations = 0
        private var pendingPublication: CheckedContinuation<MCPIPTCPatchXMPPublicationApprovalStore.Approval, Never>?
        private var publicationReceipt: MCPIPTCPatchXMPPublicationApprovalStore.Approval?
        var hasPendingPublicationApproval: Bool { pendingPublication != nil }
        private var pendingPreflight: CheckedContinuation<MCPIPTCPatchXMPPreflightService.Report, Never>?
        private var preflightResult: MCPIPTCPatchXMPPreflightService.Report?
        var hasPendingPreflight: Bool { pendingPreflight != nil }
        var hasPendingApproval: Bool { pending != nil }

        init(_ underlying: AutomationPatchReviewService) { self.underlying = underlying }

        func inspect(planID: String) async throws -> AutomationPatchReview {
            try await underlying.inspect(planID: planID)
        }

        func inspectXMPCandidate(planID: String) async throws -> MCPIPTCPatchXMPPreflightService.Report {
            preflightResult = try await underlying.inspectXMPCandidate(planID: planID)
            return await withCheckedContinuation { pendingPreflight = $0 }
        }

        func reviewXMPPublication(_ report: MCPIPTCPatchXMPPreflightService.Report) async throws -> MCPIPTCPatchXMPPublicationApprovalStore.Review {
            try await underlying.reviewXMPPublication(report)
        }

        func approveXMPPublication(_ review: MCPIPTCPatchXMPPublicationApprovalStore.Review,
            acknowledgesC2PA: Bool, acknowledgesPendingDraft: Bool) async throws -> MCPIPTCPatchXMPPublicationApprovalStore.Approval {
            publicationReceipt = try await underlying.approveXMPPublication(review,
                acknowledgesC2PA: acknowledgesC2PA, acknowledgesPendingDraft: acknowledgesPendingDraft)
            return await withCheckedContinuation { pendingPublication = $0 }
        }

        func publishXMP(_ receipt: MCPIPTCPatchXMPPublicationApprovalStore.Approval) async throws -> AutomationOperationRegistry.Record {
            try await underlying.publishXMP(receipt)
        }

        func revokeXMPPublication(_ receipt: MCPIPTCPatchXMPPublicationApprovalStore.Approval) async {
            await underlying.revokeXMPPublication(receipt)
            publicationRevocations += 1
        }

        func finishPublicationApproval() {
            guard let pendingPublication, let publicationReceipt else { return }
            self.pendingPublication = nil
            self.publicationReceipt = nil
            pendingPublication.resume(returning: publicationReceipt)
        }

        func approve(_ review: AutomationPatchReview) async throws -> MCPIPTCPatchApprovalStore.Approval {
            receipt = try await underlying.approve(review)
            return await withCheckedContinuation { pending = $0 }
        }

        func finishPreflight() {
            guard let pendingPreflight, let preflightResult else { return }
            self.pendingPreflight = nil
            self.preflightResult = nil
            pendingPreflight.resume(returning: preflightResult)
        }

        func finishApproval() {
            guard let pending, let receipt else { return }
            self.pending = nil
            self.receipt = nil
            pending.resume(returning: receipt)
        }

        func applyToPendingDraft(_ receipt: MCPIPTCPatchApprovalStore.Approval) async throws -> AutomationOperationRegistry.Record {
            try await underlying.applyToPendingDraft(receipt)
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

    @Test("Native draft application verifies a durable operation and consumes consent") @MainActor
    func applyDraft() async throws {
        let fixture = try Fixture()
        let registry = AutomationOperationRegistry(storageDirectory: fixture.root.appendingPathComponent("operations"))
        let service = AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade,
            operationRegistry: registry)
        let model = AutomationPatchReviewModel(service: service)
        model.planID = fixture.planID
        model.inspect()
        try await waitUntil { !model.isLoading }
        model.approveReviewedPlan()
        try await waitUntil { model.isApproved }
        model.applyApprovedPlanToPendingDraft()
        try await waitUntil { !model.isLoading }
        let result = try #require(model.applicationResult)
        #expect(result.kind == .iptcDraft)
        #expect(result.outcome == .verified)
        #expect(result.isTerminal)
        #expect(try registry.inspect(result.id) == result)
        #expect(!model.isApproved)
        #expect(!model.isApplying)
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
        let read = try #require(MCPMetadataSnapshotReader.inspectPhoto(path: fixture.photo.path,
            facade: fixture.facade).objectValue)
        #expect(read["fields"]?.objectValue?["title"] == .string("After"))
        #expect(read["hasPendingChanges"] == .bool(true))
        model.applyApprovedPlanToPendingDraft()
        #expect(try registry.records().count == 1)
        model.expireReview(at: .distantFuture)
        #expect(model.applicationResult == result)
        #expect(!model.isExpired)
    }

    @Test("Drift after native approval refuses draft application without a carrier write")
    func applicationRefusesDrift() async throws {
        let fixture = try Fixture()
        let registry = AutomationOperationRegistry(storageDirectory: fixture.root.appendingPathComponent("operations"))
        let service = AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade,
            operationRegistry: registry)
        let review = try await service.inspect(planID: fixture.planID)
        let receipt = try await service.approve(review)
        try fixture.original.write(to: fixture.photo, options: .atomic)
        let result = try await service.applyToPendingDraft(receipt)
        #expect(result.outcome == .failed)
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".photo_metadata").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("frame.xmp").path))
    }

    @Test("XMP dry run displays checked evidence without granting consent or saving carriers") @MainActor
    func xmpPreflight() async throws {
        let fixture = try Fixture()
        let service = AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade)
        let model = AutomationPatchReviewModel(service: service)
        model.planID = fixture.planID
        model.inspect()
        try await waitUntil { !model.isLoading }
        model.approveReviewedPlan()
        try await waitUntil { !model.isLoading }
        #expect(model.isApproved)
        model.inspectXMPCandidate()
        try await waitUntil { !model.isLoading }
        let result = try #require(model.xmpPreflight)
        #expect(result.planID == fixture.planID)
        #expect(result.targetPath == URL(fileURLWithPath: try #require(fixture.prepared.objectValue?["canonicalPath"]?.stringValue))
            .deletingPathExtension().appendingPathExtension("xmp").path)
        #expect(result.stagedByteCount > 0)
        #expect(result.stagedSHA256.count == 64)
        #expect(!model.isApproved)
        #expect(model.applicationResult == nil)
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["frame.jpg"])
        model.clear()
        #expect(model.xmpPreflight == nil)
    }

    @Test("Late XMP dry runs cannot republish after clear, ID change or expiry", arguments: ["clear", "edit", "expire"])
    @MainActor
    func latePreflight(action: String) async throws {
        let fixture = try Fixture()
        let service = HeldApprovalService(AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade))
        let model = AutomationPatchReviewModel(service: service)
        model.planID = fixture.planID
        model.inspect()
        try await waitUntil { !model.isLoading }
        let review = try #require(model.review)
        model.inspectXMPCandidate()
        try await waitUntil { await service.hasPendingPreflight }
        switch action {
        case "clear": model.clear()
        case "edit": model.planID = UUID().uuidString.lowercased()
        default: model.expireReview(at: review.expiresAt)
        }
        await service.finishPreflight()
        // A subsequent actor roundtrip gives the returned result a chance to publish.
        for _ in 0..<10 { await Task.yield() }
        #expect(!model.isLoading)
        #expect(model.xmpPreflight == nil)
        #expect(!model.isApproved)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["frame.jpg"])
    }

    @Test("Source drift during a later dry run clears obsolete evidence") @MainActor
    func preflightDrift() async throws {
        let fixture = try Fixture()
        let model = AutomationPatchReviewModel(service: AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade))
        model.planID = fixture.planID
        model.inspect()
        try await waitUntil { !model.isLoading }
        model.inspectXMPCandidate()
        try await waitUntil { !model.isLoading }
        #expect(model.xmpPreflight != nil)
        try fixture.original.write(to: fixture.photo, options: .atomic)
        model.inspectXMPCandidate()
        try await waitUntil { !model.isLoading }
        #expect(model.review == nil)
        #expect(model.xmpPreflight == nil)
        #expect(model.message != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["frame.jpg"])
    }

    private nonisolated final class PublicationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private let resume = DispatchSemaphore(value: 0)
        var isWaiting: Bool { lock.withLock { entered } }
        func wait() throws {
            lock.withLock { entered = true }
            guard resume.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
        }
        func release() { resume.signal() }
    }

    @Test("Leaving native publication requests durable cancellation and suppresses late results")
    @MainActor
    func clearDuringPublication() async throws {
        let fixture = try Fixture()
        let storage = fixture.root.appendingPathComponent("operations")
        let registry = AutomationOperationRegistry(storageDirectory: storage)
        let gate = PublicationGate()
        defer { gate.release() }
        let service = AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade,
            operationRegistry: registry, recoveryDirectory: storage,
            publicationHooks: .init(afterRecovery: { try gate.wait() }))
        let model = AutomationPatchReviewModel(service: service)
        model.planID = fixture.planID
        model.inspect()
        try await waitUntil { !model.isLoading }
        model.inspectXMPCandidate()
        try await waitUntil { !model.isLoading }
        model.acknowledgesC2PA = true
        model.approveReviewedXMPPublication()
        try await waitUntil { !model.isLoading }
        #expect(model.isXMPPublicationApproved)
        model.publishApprovedXMP()
        try await waitUntil { gate.isWaiting }
        let accepted = try #require(registry.records().first)
        model.clear()
        try await waitUntil { (try? registry.inspect(accepted.id).cancellationRequestedAt) != nil }
        gate.release()
        try await waitUntil { (try? registry.inspect(accepted.id).isTerminal) == true }
        let completed = try registry.inspect(accepted.id)
        #expect(completed.outcome == .cancelled)
        #expect(model.applicationResult == nil)
        #expect(model.review == nil)
        #expect(!model.isApplying)
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
        #expect(!FileManager.default.fileExists(atPath: fixture.photo.deletingPathExtension().appendingPathExtension("xmp").path))
        #expect(try MCPIPTCPatchXMPRecoveryStore(directory: storage).load()?.id == accepted.id)
    }

    @Test("Native publication requires exact consent and records verified or recoverable results", arguments: ["success", "drift", "interrupted", "selected"])
    @MainActor
    func nativePublication(scenario: String) async throws {
        let fixture = try Fixture()
        let storage = fixture.root.appendingPathComponent("operations")
        let registry = AutomationOperationRegistry(storageDirectory: storage)
        let hooks = MCPIPTCPatchXMPPublicationAdmissionService.Hooks(afterXMPInstall: {
            if scenario == "interrupted" { throw CancellationError() }
        })
        let service = AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade,
            operationRegistry: registry, recoveryDirectory: storage, publicationHooks: hooks)
        let model = AutomationPatchReviewModel(service: service)
        model.planID = fixture.planID
        model.inspect()
        try await waitUntil { !model.isLoading }
        model.publishApprovedXMP()
        #expect(model.applicationResult == nil)
        #expect(try registry.records().isEmpty)
        model.inspectXMPCandidate()
        try await waitUntil { !model.isLoading }
        model.acknowledgesC2PA = true
        model.approveReviewedXMPPublication()
        try await waitUntil { !model.isLoading }
        #expect(model.isXMPPublicationApproved)
        if scenario == "drift" { try fixture.original.write(to: fixture.photo, options: .atomic) }
        let editor = UUID()
        if scenario == "selected" {
            AutomationDraftEditorAdmission.shared.update(owner: editor, selectedURLs: [fixture.photo])
        }
        defer { AutomationDraftEditorAdmission.shared.remove(owner: editor) }
        model.publishApprovedXMP()
        try await waitUntil { !model.isLoading }
        let result = try #require(model.applicationResult)
        #expect(result.kind == .iptcPatch)
        #expect(result.outcome == (scenario == "success" ? .verified : (scenario == "interrupted" ? .recoveryRequired : .failed)))
        #expect(!model.isXMPPublicationApproved)
        #expect(try registry.inspect(result.id) == result)
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
        let xmp = fixture.photo.deletingPathExtension().appendingPathExtension("xmp")
        #expect(FileManager.default.fileExists(atPath: xmp.path) == (scenario == "success" || scenario == "interrupted"))
        if scenario == "success" {
            let snapshot = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
            #expect(try MCPMetadataSnapshotReader.read(snapshot).resolution.metadata.title == "After")
            let bytes = try #require(snapshot.appSidecarBytes)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            #expect(try !decoder.decode(MetadataSidecar.self, from: bytes).pendingChanges)
            #expect(try MCPIPTCPatchXMPRecoveryStore(directory: storage).load() == nil)
        } else if scenario == "interrupted" {
            #expect(try MCPIPTCPatchXMPRecoveryStore(directory: storage).load()?.id == result.id)
        }
        model.publishApprovedXMP()
        #expect(try registry.records().count == 1)
        model.clear()
    }

    @Test("Native XMP consent needs acknowledgement and is separate from pending draft approval") @MainActor
    func publicationConsent() async throws {
        let fixture = try Fixture()
        let model = AutomationPatchReviewModel(service: AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade))
        model.planID = fixture.planID
        model.inspect()
        try await waitUntil { !model.isLoading }
        model.inspectXMPCandidate()
        try await waitUntil { !model.isLoading }
        #expect(model.xmpPublicationReview != nil)
        #expect(!model.canApproveXMPPublication)
        model.approveReviewedXMPPublication()
        #expect(!model.isXMPPublicationApproved)
        model.acknowledgesC2PA = true
        #expect(model.canApproveXMPPublication)
        model.approveReviewedXMPPublication()
        try await waitUntil { !model.isLoading }
        #expect(model.isXMPPublicationApproved)
        #expect(!model.isApproved)
        model.approveReviewedPlan()
        try await waitUntil { !model.isLoading }
        #expect(model.isApproved)
        #expect(!model.isXMPPublicationApproved)
        #expect(!model.acknowledgesC2PA)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["frame.jpg"])
    }

    @Test("Late XMP consent is revoked after clear, edit, expiry or acknowledgement withdrawal",
        arguments: ["clear", "edit", "expire", "withdraw", "clock"])
    @MainActor
    func latePublicationConsent(action: String) async throws {
        let fixture = try Fixture()
        let service = HeldApprovalService(AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade))
        var now = Date()
        let model = AutomationPatchReviewModel(service: service, now: { now })
        model.planID = fixture.planID
        model.inspect()
        try await waitUntil { !model.isLoading }
        let review = try #require(model.review)
        model.inspectXMPCandidate()
        try await waitUntil { await service.hasPendingPreflight }
        await service.finishPreflight()
        try await waitUntil { !model.isLoading }
        model.acknowledgesC2PA = true
        model.approveReviewedXMPPublication()
        try await waitUntil { await service.hasPendingPublicationApproval }
        switch action {
        case "clear": model.clear()
        case "edit": model.planID = UUID().uuidString.lowercased()
        case "expire": model.expireReview(at: review.expiresAt)
        case "clock": now = review.expiresAt
        default: model.acknowledgesC2PA = false
        }
        await service.finishPublicationApproval()
        try await waitUntil { await service.publicationRevocations == 1 }
        #expect(!model.isXMPPublicationApproved)
        #expect(!model.isApproved)
        #expect(!model.isLoading)
        if action == "clock" || action == "expire" { #expect(model.isExpired) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["frame.jpg"])
    }

    @Test("Source replacement invalidates native XMP publication review before consent") @MainActor
    func publicationDrift() async throws {
        let fixture = try Fixture()
        let model = AutomationPatchReviewModel(service: AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade))
        model.planID = fixture.planID
        model.inspect()
        try await waitUntil { !model.isLoading }
        model.inspectXMPCandidate()
        try await waitUntil { !model.isLoading }
        model.acknowledgesC2PA = true
        try fixture.original.write(to: fixture.photo, options: .atomic)
        model.approveReviewedXMPPublication()
        try await waitUntil { !model.isLoading }
        #expect(!model.isXMPPublicationApproved)
        #expect(model.review == nil)
        #expect(model.xmpPublicationReview == nil)
        #expect(model.message != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["frame.jpg"])
    }

    @Test("Pending-value publication requires both acknowledgements and withdrawal revokes consent") @MainActor
    func pendingPublicationConsent() async throws {
        let fixture = try MCPIPTCPatchXMPPreflightServiceTests.Fixture(pending: true)
        let service = HeldApprovalService(AutomationPatchReviewService(plans: fixture.plans, facade: fixture.facade))
        let model = AutomationPatchReviewModel(service: service)
        model.planID = fixture.planID
        model.inspect()
        try await waitUntil { !model.isLoading }
        model.inspectXMPCandidate()
        try await waitUntil { await service.hasPendingPreflight }
        await service.finishPreflight()
        try await waitUntil { !model.isLoading }
        #expect(model.xmpPublicationReview?.report.publicationBinding.promotesPendingDraft == true)
        model.acknowledgesC2PA = true
        #expect(!model.canApproveXMPPublication)
        model.approveReviewedXMPPublication()
        #expect(!(await service.hasPendingPublicationApproval))
        model.acknowledgesPendingDraft = true
        #expect(model.canApproveXMPPublication)
        model.approveReviewedXMPPublication()
        try await waitUntil { await service.hasPendingPublicationApproval }
        await service.finishPublicationApproval()
        try await waitUntil { model.isXMPPublicationApproved }
        model.acknowledgesPendingDraft = false
        #expect(!model.isXMPPublicationApproved)
        #expect(!model.canApproveXMPPublication)
        try await waitUntil { await service.publicationRevocations == 1 }
    }

}
