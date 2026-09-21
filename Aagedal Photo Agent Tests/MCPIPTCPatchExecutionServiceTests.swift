import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Exact-plan pending draft execution")
struct MCPIPTCPatchExecutionServiceTests {
    private final class Fixture {
        let root: URL
        let photo: URL
        let authority: MCPAuthorizationStore
        let facade: MCPAutomationFacade
        let plans = MCPIPTCPatchPlanStore()
        let prepared: MCPJSONValue
        let planID: String
        let original: Data

        init(existingDraft: Bool = false, legacyDraft: Bool = false) throws {
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
            if existingDraft {
                var draft = MetadataSidecar(sourceFile: photo.lastPathComponent, pendingChanges: true,
                    metadata: IPTCMetadata(), imageMetadataSnapshot: IPTCMetadata())
                draft.metadata.title = "Before"
                draft.metadata.credit = "Unrelated saved credit"
                draft.metadata.keywords = ["untouched"]
                draft.history = [.init(timestamp: Date(), fieldName: "Credit", oldValue: nil, newValue: "Unrelated saved credit")]
                _ = try MetadataSidecarService().saveSidecar(draft, for: photo, in: root)
                let sidecar = root.appendingPathComponent(".photo_metadata/frame.jpg.meta.json")
                var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
                object["futurePrivateExtension"] = ["secret": [1, 2, 3]]
                var fields = try #require(object["metadata"] as? [String: Any])
                fields["futureNestedField"] = ["payload": "retained"]
                object["metadata"] = fields
                try JSONSerialization.data(withJSONObject: object).write(to: sidecar)
            }
            if legacyDraft {
                try FileManager.default.moveItem(at: root.appendingPathComponent(".photo_metadata/frame.jpg.meta.json"),
                    to: root.appendingPathComponent(".photo_metadata/frame.meta.json"))
            }
            let metadata = try #require(MCPMetadataSnapshotReader.inspectPhoto(path: photo.path, facade: facade).objectValue)
            var arguments: [String: MCPJSONValue] = ["path": .string(photo.path), "operations": .array([
                .object(["field": .string("title"), "operation": .string("set"), "value": .string("After")])])]
            for key in ["sourceRevision", "xmpSidecarRevision", "appSidecarRevision"] { arguments[key] = metadata[key] }
            prepared = try MCPIPTCPatchPreparation.prepare(arguments: arguments, facade: facade, plans: plans)
            planID = try #require(prepared.objectValue?["planID"]?.stringValue)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }


    private func approved(_ fixture: Fixture) throws -> (MCPIPTCPatchApprovalStore, MCPIPTCPatchApprovalStore.Approval) {
        let store = MCPIPTCPatchApprovalStore(plans: fixture.plans)
        return (store, try store.approve(store.review(planID: fixture.planID, facade: fixture.facade), facade: fixture.facade))
    }

    @Test("Real draft saves preserve source, unedited values, original snapshot, history and opaque extensions", arguments: [false, true])
    func applyDraft(existingDraft: Bool) async throws {
        let fixture = try Fixture(existingDraft: existingDraft)
        let (store, approval) = try approved(fixture)
        let service = MCPIPTCPatchExecutionService(plans: fixture.plans, approvals: store, facade: fixture.facade)
        let result = await service.applyToPendingDraft(approval)
        #expect(result.outcome == .draftSaved)
        let installed = try #require(result.installedSidecar)
        #expect(installed.pendingChanges)
        #expect(installed.metadata.title == "After")
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("frame.xmp").path))
        #expect(installed.history.contains { $0.fieldID == .title })
        if existingDraft {
            #expect(installed.metadata.credit == "Unrelated saved credit")
            #expect(installed.metadata.keywords == ["untouched"])
            #expect(installed.imageMetadataSnapshot?.title == nil)
            #expect(installed.history.contains { $0.fieldName == "Credit" })
            let installedURL = try #require(result.sidecarURL)
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: installedURL)) as? [String: Any])
            #expect(object["futurePrivateExtension"] != nil)
            #expect((object["metadata"] as? [String: Any])?["futureNestedField"] != nil)
        } else {
            #expect(installed.imageMetadataSnapshot?.title == "Before")
        }
        #expect(fixture.prepared.objectValue?["commitAvailable"] == .bool(false))
        let second = await service.applyToPendingDraft(approval)
        #expect(second.outcome == .refused)
    }

    @Test("A sole legacy draft updates in place and reports the installed filename")
    func legacyDraft() async throws {
        let fixture = try Fixture(existingDraft: true, legacyDraft: true)
        let (store, approval) = try approved(fixture)
        let result = await MCPIPTCPatchExecutionService(plans: fixture.plans, approvals: store, facade: fixture.facade)
            .applyToPendingDraft(approval)
        #expect(result.outcome == .draftSaved)
        #expect(result.sidecarURL?.lastPathComponent == "frame.meta.json")
        #expect(result.installedSidecar?.metadata.title == "After")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".photo_metadata/frame.jpg.meta.json").path))
    }

    @Test("Rooted installation refuses a swapped private directory without writing through its symlink")
    func privateDirectoryRetarget() throws {
        let fixture = try Fixture(existingDraft: true)
        let snapshot = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        let reservation = try MCPProcessReservation.acquirePhoto(fixture.photo)
        defer { reservation.release() }
        let privateURL = fixture.root.appendingPathComponent(".photo_metadata")
        let retainedURL = fixture.root.appendingPathComponent("retained-private")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("patch-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(throws: (any Error).self) {
            try fixture.facade.installPendingDraft(data: Data("must-not-escape".utf8), expected: snapshot,
                reservation: reservation, beforeInstall: {
                    try FileManager.default.moveItem(at: privateURL, to: retainedURL)
                    try FileManager.default.createSymbolicLink(at: privateURL, withDestinationURL: outside)
                })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try Data(contentsOf: retainedURL.appendingPathComponent("frame.jpg.meta.json")) == snapshot.appSidecarBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: retainedURL.path) == ["frame.jpg.meta.json"])
    }

    @Test("An editor selection acquired after consent refuses the actual draft write")
    func selectedEditorGate() async throws {
        let fixture = try Fixture()
        let (store, approval) = try approved(fixture)
        let owner = UUID()
        AutomationDraftEditorAdmission.shared.update(owner: owner, selectedURLs: [fixture.photo])
        defer { AutomationDraftEditorAdmission.shared.remove(owner: owner) }
        let result = await MCPIPTCPatchExecutionService(plans: fixture.plans, approvals: store, facade: fixture.facade)
            .applyToPendingDraft(approval)
        #expect(result.outcome == .refused)
        #expect(result.message.contains("Deselect"))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".photo_metadata").path))
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
        #expect(try store.validate(approval, facade: fixture.facade) == fixture.prepared)
    }

    @Test("Authority revoked after acquiring the gate refuses before creating a draft")
    func authorityDrift() async throws {
        let fixture = try Fixture()
        let (store, approval) = try approved(fixture)
        let authority = fixture.authority
        let service = MCPIPTCPatchExecutionService(plans: fixture.plans, approvals: store, facade: fixture.facade,
            hooks: .init(beforeAdmission: { try authority.setEnabled(false) }))
        let result = await service.applyToPendingDraft(approval)
        #expect(result.outcome == .refused)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".photo_metadata").path))
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
    }

    @Test("A competing reservation refuses and invalidates the receipt conservatively")
    func competingWriter() async throws {
        let fixture = try Fixture()
        let (store, approval) = try approved(fixture)
        let lease = try MCPProcessReservation.acquirePhoto(fixture.photo)
        let service = MCPIPTCPatchExecutionService(plans: fixture.plans, approvals: store, facade: fixture.facade)
        let blocked = await service.applyToPendingDraft(approval)
        #expect(blocked.outcome == .refused)
        lease.release()
        // Validation observes failed read admission and intentionally revokes the receipt.
        #expect(throws: MCPIPTCPatchApprovalStore.Failure.unavailableApproval) {
            try store.validate(approval, facade: fixture.facade)
        }
    }

    @Test("Failure after installation is uncertain and consumes consent, never a retryable definite failure")
    func installedButUnverified() async throws {
        let fixture = try Fixture()
        let (store, approval) = try approved(fixture)
        let service = MCPIPTCPatchExecutionService(plans: fixture.plans, approvals: store, facade: fixture.facade,
            hooks: .init(afterSave: { throw CocoaError(.fileReadCorruptFile) }))
        let result = await service.applyToPendingDraft(approval)
        #expect(result.outcome == .uncertain)
        #expect(result.installedSidecar == nil)
        #expect(FileManager.default.fileExists(atPath: try #require(result.sidecarURL).path))
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
        #expect(throws: MCPIPTCPatchApprovalStore.Failure.unavailableApproval) {
            try store.validate(approval, facade: fixture.facade)
        }
    }

    @Test("Cancellation before the save creates no draft")
    func cancellationBeforeSave() async throws {
        let fixture = try Fixture()
        let (store, approval) = try approved(fixture)
        let service = MCPIPTCPatchExecutionService(plans: fixture.plans, approvals: store, facade: fixture.facade,
            hooks: .init(beforeAdmission: { throw CancellationError() }))
        let result = await service.applyToPendingDraft(approval)
        #expect(result.outcome == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".photo_metadata").path))
        #expect(try store.validate(approval, facade: fixture.facade) == fixture.prepared)
    }

    @Test("Unknown nested structured fields refuse before replacing the original draft")
    func nestedOpaqueExtension() async throws {
        let fixture = try Fixture(existingDraft: true)
        let url = fixture.root.appendingPathComponent(".photo_metadata/frame.jpg.meta.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var metadata = try #require(object["metadata"] as? [String: Any])
        metadata["creatorContactInfo"] = ["email": "editor@example.test", "futurePrivate": ["retained": true]]
        object["metadata"] = metadata
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try bytes.write(to: url)
        let live = try #require(MCPMetadataSnapshotReader.inspectPhoto(path: fixture.photo.path, facade: fixture.facade).objectValue)
        var arguments: [String: MCPJSONValue] = ["path": .string(fixture.photo.path), "operations": .array([
            .object(["field": .string("title"), "operation": .string("set"), "value": .string("After")])])]
        for key in ["sourceRevision", "xmpSidecarRevision", "appSidecarRevision"] { arguments[key] = live[key] }
        let plan = try MCPIPTCPatchPreparation.prepare(arguments: arguments, facade: fixture.facade, plans: fixture.plans)
        let store = MCPIPTCPatchApprovalStore(plans: fixture.plans)
        let review = try store.review(planID: #require(plan.objectValue?["planID"]?.stringValue), facade: fixture.facade)
        let approval = try store.approve(review, facade: fixture.facade)
        let result = await MCPIPTCPatchExecutionService(plans: fixture.plans, approvals: store, facade: fixture.facade)
            .applyToPendingDraft(approval)
        #expect(result.outcome == .refused)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try Data(contentsOf: fixture.photo) == fixture.original)
    }

    @Test("Opaque descendants cannot disappear through missing or scalar replacement containers")
    func opaqueVerification() throws {
        let original = Data(#"{"metadata":{"title":"Before","future":{"private":1}},"extension":[1,2]}"#.utf8)
        let known = Data(#"{"metadata":{"title":"Before"}}"#.utf8)
        for installed in [#"{"extension":[1,2]}"#, #"{"metadata":"broken","extension":[1,2]}"#,
                          #"{"metadata":{"title":"After"},"extension":[1,2]}"#] {
            #expect(try !MCPIPTCPatchExecutionService.preservesUnknownFields(original: original, known: known,
                installed: Data(installed.utf8)))
        }
        let retained = Data(#"{"metadata":{"title":"After","future":{"private":1}},"extension":[1,2]}"#.utf8)
        #expect(try MCPIPTCPatchExecutionService.preservesUnknownFields(original: original, known: known, installed: retained))
        #expect(try !MCPIPTCPatchExecutionService.preservesUnknownFields(
            original: Data(#"{"locations":[{"name":"A","future":1}]}"#.utf8),
            known: Data(#"{"locations":[{"name":"A"}]}"#.utf8),
            installed: Data(#"{"locations":[{"name":"A"}]}"#.utf8)))
    }
}
