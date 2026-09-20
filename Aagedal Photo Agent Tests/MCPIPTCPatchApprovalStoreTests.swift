import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Local exact-plan IPTC approval")
struct MCPIPTCPatchApprovalStoreTests {
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

    @Test("Explicit consent binds an immutable preview without changing files or helper write claims")
    func exactConsentAndRevocation() throws {
        let fixture = try Fixture()
        let store = MCPIPTCPatchApprovalStore(plans: fixture.plans)
        let review = try store.review(planID: fixture.planID, facade: fixture.facade)
        #expect(review.preview == fixture.prepared)
        let approval = try store.approve(review, facade: fixture.facade)
        #expect(approval.planID == fixture.planID)
        #expect(approval.expiresAt == review.expiresAt)
        #expect(try store.validate(approval, facade: fixture.facade) == fixture.prepared)
        #expect(try fixture.plans.inspect(arguments: ["planID": .string(fixture.planID)], facade: fixture.facade) == fixture.prepared)
        #expect(fixture.prepared.objectValue?["commitAvailable"] == .bool(false))
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["frame.jpg"])
        store.revoke(approval)
        #expect(throws: MCPIPTCPatchApprovalStore.Failure.unavailableApproval) {
            try store.validate(approval, facade: fixture.facade)
        }
    }

    @Test("Review and approval cannot transfer to another native session, and closing invalidates open reviews")
    func sessionBoundary() throws {
        let fixture = try Fixture()
        let store = MCPIPTCPatchApprovalStore(plans: fixture.plans)
        let other = MCPIPTCPatchApprovalStore(plans: fixture.plans)
        let review = try store.review(planID: fixture.planID, facade: fixture.facade)
        #expect(throws: MCPIPTCPatchApprovalStore.Failure.invalidReview) {
            try other.approve(review, facade: fixture.facade)
        }
        let approval = try store.approve(review, facade: fixture.facade)
        #expect(throws: MCPIPTCPatchApprovalStore.Failure.unavailableApproval) {
            try other.validate(approval, facade: fixture.facade)
        }
        store.revokeAll()
        #expect(throws: MCPIPTCPatchApprovalStore.Failure.invalidReview) {
            try store.approve(review, facade: fixture.facade)
        }
        #expect(throws: MCPIPTCPatchApprovalStore.Failure.unavailableApproval) {
            try store.validate(approval, facade: fixture.facade)
        }
    }

    @Test("Authorization changes between review and click refuse local consent")
    func authorityDriftBeforeApproval() throws {
        let fixture = try Fixture()
        let store = MCPIPTCPatchApprovalStore(plans: fixture.plans)
        let review = try store.review(planID: fixture.planID, facade: fixture.facade)
        try fixture.authority.setEnabled(false)
        try fixture.authority.setEnabled(true)
        #expect(throws: MCPIPTCPatchPlanStore.Failure.authorityChanged) {
            try store.approve(review, facade: fixture.facade)
        }
    }

    @Test("Observed carrier drift revokes consent even when original file bytes return")
    func carrierDriftRevokes() throws {
        let fixture = try Fixture()
        let store = MCPIPTCPatchApprovalStore(plans: fixture.plans)
        let review = try store.review(planID: fixture.planID, facade: fixture.facade)
        let approval = try store.approve(review, facade: fixture.facade)
        var changed = fixture.original
        changed.append(contentsOf: [0, 1, 2])
        try changed.write(to: fixture.photo)
        #expect(throws: (any Error).self) { try store.validate(approval, facade: fixture.facade) }
        try fixture.original.write(to: fixture.photo)
        #expect(throws: MCPIPTCPatchApprovalStore.Failure.unavailableApproval) {
            try store.validate(approval, facade: fixture.facade)
        }
    }

    @Test("Authorization drift after approval revokes its receipt permanently")
    func authorityDriftAfterApproval() throws {
        let fixture = try Fixture()
        let store = MCPIPTCPatchApprovalStore(plans: fixture.plans)
        let review = try store.review(planID: fixture.planID, facade: fixture.facade)
        let approval = try store.approve(review, facade: fixture.facade)
        try fixture.authority.setEnabled(false)
        try fixture.authority.setEnabled(true)
        #expect(throws: MCPIPTCPatchPlanStore.Failure.authorityChanged) {
            try store.validate(approval, facade: fixture.facade)
        }
        #expect(throws: MCPIPTCPatchApprovalStore.Failure.unavailableApproval) {
            try store.validate(approval, facade: fixture.facade)
        }
    }

    @Test("Deadline and backwards clock revoke approval", arguments: [false, true])
    func expiration(backwards: Bool) throws {
        let fixture = try Fixture()
        let store = MCPIPTCPatchApprovalStore(plans: fixture.plans)
        let before = Date().addingTimeInterval(-1)
        let review = try store.review(planID: fixture.planID, facade: fixture.facade)
        let approval = try store.approve(review, facade: fixture.facade)
        #expect(throws: MCPIPTCPatchApprovalStore.Failure.expiredApproval) {
            try store.validate(approval, facade: fixture.facade, now: backwards ? before : review.expiresAt)
        }
        #expect(throws: MCPIPTCPatchApprovalStore.Failure.unavailableApproval) {
            try store.validate(approval, facade: fixture.facade)
        }
    }

    @Test("Repeat consent replaces its receipt and zero capacity refuses consent")
    func boundedConsent() throws {
        let fixture = try Fixture()
        let store = MCPIPTCPatchApprovalStore(plans: fixture.plans, maximumApprovals: 1)
        let review = try store.review(planID: fixture.planID, facade: fixture.facade)
        let first = try store.approve(review, facade: fixture.facade)
        let second = try store.approve(review, facade: fixture.facade)
        #expect(first.id != second.id)
        #expect(throws: MCPIPTCPatchApprovalStore.Failure.unavailableApproval) {
            try store.validate(first, facade: fixture.facade)
        }
        #expect(try store.validate(second, facade: fixture.facade) == fixture.prepared)
        let disabled = MCPIPTCPatchApprovalStore(plans: fixture.plans, maximumApprovals: 0)
        let disabledReview = try disabled.review(planID: fixture.planID, facade: fixture.facade)
        #expect(throws: MCPIPTCPatchApprovalStore.Failure.capacity) {
            try disabled.approve(disabledReview, facade: fixture.facade)
        }
    }
}
