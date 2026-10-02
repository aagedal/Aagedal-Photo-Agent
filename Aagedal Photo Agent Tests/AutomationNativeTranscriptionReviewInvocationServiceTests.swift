import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Authenticated native transcription review handoff resolution")
struct AutomationNativeTranscriptionReviewInvocationServiceTests {
    private struct Fixture {
        let root: URL
        let photos: [URL]
        let memos: [URL]
        let authority: MCPAuthorizationStore
        let facade: MCPAutomationFacade
        let plans: MCPVoiceTranscriptionPlanStore
        let requests: MCPVoiceTranscriptionReviewRequestStore
        let registry: AutomationOperationRegistry
        let record: MCPVoiceTranscriptionReviewRequestStore.Record
        var id: UUID { UUID(uuidString: record.requestID)! }
        var epoch: UUID { UUID(uuidString: record.requestEpoch)! }
        var service: AutomationNativeTranscriptionReviewInvocationService {
            .init(requests: requests, plans: plans, facade: facade, registry: registry)
        }
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/native-transcription-invocation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let box = UITestTranscriptionReviewFixture.ConfigurationBox()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(root); try authority.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: authority)
        var inputs: [MCPJSONValue] = [], photos: [URL] = [], memos: [URL] = []
        for index in 1...2 {
            let photo = root.appendingPathComponent("photo\(index)-**untrusted**-å.jpg")
            let memo = root.appendingPathComponent("memo\(index).wav")
            try Data("photo \(index)".utf8).write(to: photo)
            try Data("memo \(index)".utf8).write(to: memo)
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "profileIdentifier": "reviewed-profile",
                "imageFilename": photo.lastPathComponent, "memoFilename": memo.lastPathComponent])
                .write(to: root.appendingPathComponent(".\(photo.lastPathComponent).voice-memo.json"))
            let evidence = try #require(facade.inspectPhotoVoiceMemo(path: photo.path).objectValue)
            var input = evidence.filter { MCPVoiceTranscriptionPlanStore.Request.photoKeys.contains($0.key) }
            input["path"] = .string(photo.path)
            inputs.append(.object(input)); photos.append(photo); memos.append(memo)
        }
        let plans = MCPVoiceTranscriptionPlanStore(storageDirectory: root.appendingPathComponent("plans"))
        let preview = try plans.prepare(arguments: ["photos": .array(Array(inputs.reversed())),
            "provider": .string("whisper"), "language": .string("auto"), "translate": .bool(true), "useGPU": .bool(true)], facade: facade)
        let requests = MCPVoiceTranscriptionReviewRequestStore(storageDirectory: root.appendingPathComponent("requests"))
        let record = try requests.request(requestID: UUID(), requestEpoch: requests.capacitySnapshot().epoch,
            planID: #require(preview.objectValue?["planID"]?.stringValue), plans: plans, facade: facade)
        return Fixture(root: root, photos: photos, memos: memos, authority: authority, facade: facade,
            plans: plans, requests: requests, registry: .init(storageDirectory: root.appendingPathComponent("operations")), record: record)
    }

    private func link(_ f: Fixture, operationID: UUID = UUID(), ownerID: UUID = UUID()) throws
        -> (UUID, UUID, AutomationOperationPersistence.OwnerLease) {
        _ = try f.requests.admit(f.id, requestEpoch: f.epoch, expected: f.record,
            operationID: operationID, ownerID: ownerID, registry: f.registry)
        let lease = try f.registry.acquireOwnerLease(ownerID: ownerID)
        _ = try f.registry.enqueue(kind: .voiceTranscription, ownerID: ownerID, operationID: operationID, ownerLease: lease)
        _ = try f.registry.configureBatch(operationID, ownerID: ownerID, itemCount: f.record.intent.photoCount)
        _ = try f.requests.link(f.id, requestEpoch: f.epoch, operationID: operationID, registry: f.registry)
        return (operationID, ownerID, lease)
    }

    @Test("Exact retained intent is returned internally without admission or carrier changes")
    func reviewOnly() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let photoBytes = try f.photos.map { try Data(contentsOf: $0) }
        let memoBytes = try f.memos.map { try Data(contentsOf: $0) }
        guard case .review(let selected) = try f.service.invoke(requestID: f.id, requestEpoch: f.epoch) else {
            Issue.record("Expected native review intent"); return
        }
        #expect(selected == f.record)
        #expect(selected.intent.photos.compactMap { $0["path"]?.stringValue } == Array(f.photos.reversed()).map { $0.standardizedFileURL.path })
        #expect(selected.intent.options["translate"] == .bool(true))
        #expect(try f.requests.records() == [f.record])
        #expect(try f.registry.records().isEmpty)
        #expect(try f.photos.map { try Data(contentsOf: $0) } == photoBytes)
        #expect(try f.memos.map { try Data(contentsOf: $0) } == memoBytes)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".photo_metadata").path))
    }

    @Test("Disabled authority and unrelated or stale handles cannot select native review", arguments: ["disabled", "stale", "unknown"])
    func invalidHandle(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        if kind == "disabled" { try f.authority.setEnabled(false) }
        #expect(throws: (any Error).self) {
            try f.service.invoke(requestID: kind == "unknown" ? UUID() : f.id,
                requestEpoch: kind == "stale" ? UUID() : f.epoch)
        }
        #expect(try f.requests.records() == [f.record])
        #expect(try f.registry.records().isEmpty)
    }

    @Test("Expired plans and changes anywhere in the original set refuse handoff", arguments: ["expired", "photo", "wav", "relationship", "metadata", "root"])
    func changedSet(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var service = f.service
        switch kind {
        case "expired":
            let expiry = try #require(ISO8601DateFormatter().date(from: f.record.intent.planExpiresAt))
            service = .init(requests: f.requests, plans: f.plans, facade: f.facade, registry: f.registry, now: { expiry })
        case "photo": try Data("changed photo".utf8).write(to: f.photos[1])
        case "wav": try Data("changed memo".utf8).write(to: f.memos[1])
        case "relationship":
            try FileManager.default.removeItem(at: f.root.appendingPathComponent(".\(f.photos[1].lastPathComponent).voice-memo.json"))
        case "metadata":
            let draftRoot = f.root.appendingPathComponent(".photo_metadata")
            try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: false)
            try JSONSerialization.data(withJSONObject: ["sourceFile": f.photos[1].lastPathComponent, "title": "changed"])
                .write(to: draftRoot.appendingPathComponent(f.photos[1].lastPathComponent + ".meta.json"))
        default:
            let rootID = try #require(f.authority.load().roots.first?.id)
            try f.authority.removeRoot(id: rootID)
        }
        #expect(throws: (any Error).self) { try service.invoke(requestID: f.id, requestEpoch: f.epoch) }
        #expect(try f.requests.records() == [f.record])
        #expect(try f.registry.records().isEmpty)
    }

    @Test("Cancelled and uncertain admitted requests cannot be replayed", arguments: ["cancelled", "admitted"])
    func unavailableState(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        if kind == "cancelled" { _ = try f.requests.cancelBeforeAdmission(f.id, requestEpoch: f.epoch) }
        else {
            _ = try f.requests.admit(f.id, requestEpoch: f.epoch, expected: f.record,
                operationID: UUID(), ownerID: UUID(), registry: f.registry)
        }
        let before = try f.requests.records()
        #expect(throws: AutomationNativeTranscriptionReviewInvocationService.Failure.reviewUnavailable) {
            try f.service.invoke(requestID: f.id, requestEpoch: f.epoch)
        }
        #expect(try f.requests.records() == before)
        #expect(try f.registry.records().isEmpty)
    }

    @Test("UI publication revalidation refuses cancellation or recreation after resolution", arguments: ["cancelled", "recreated", "wav"])
    func stalePublication(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        guard case .review(let selected) = try f.service.invoke(requestID: f.id, requestEpoch: f.epoch) else {
            Issue.record("Expected native review intent"); return
        }
        if kind == "wav" { try Data("changed during UI hop".utf8).write(to: f.memos[0]) }
        else {
            _ = try f.requests.cancelBeforeAdmission(f.id, requestEpoch: f.epoch)
            if kind == "recreated" {
                let epoch = try f.requests.recoverCancelledCapacity(expectedEpoch: f.epoch)
                _ = try f.requests.request(requestID: f.id, requestEpoch: epoch,
                    planID: f.record.planID, plans: f.plans, facade: f.facade)
            }
        }
        #expect(throws: (any Error).self) { try f.service.revalidate(selected) }
    }

    @Test("An exact linked handle survives expiry without inferring completion or reopening review")
    func linkedEvidence() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (operationID, ownerID, lease) = try link(f)
        defer { withExtendedLifetime(lease) {} }
        _ = try f.registry.finish(operationID, ownerID: ownerID, outcome: .partialUncertain)
        let before = try f.requests.records(), history = try f.registry.records()
        let expiry = try #require(ISO8601DateFormatter().date(from: f.record.intent.planExpiresAt))
        let service = AutomationNativeTranscriptionReviewInvocationService(requests: f.requests,
            plans: f.plans, facade: f.facade, registry: f.registry, now: { expiry.addingTimeInterval(1) })
        try Data("source changed after linkage".utf8).write(to: f.memos[0])
        guard case .linked(let selected) = try service.invoke(requestID: f.id, requestEpoch: f.epoch) else {
            Issue.record("Expected exact retained operation handle"); return
        }
        #expect(selected == operationID)
        #expect(try f.requests.records() == before)
        #expect(try f.registry.records() == history)
    }

    @Test("Linked results require exact ID, owner lease, kind, batch and retained history", arguments: ["missing", "id", "owner", "unmanaged", "kind", "count", "cancelled", "operationCancelled"])
    func mismatchedLinkedEvidence(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (operationID, ownerID, lease) = try link(f)
        defer { withExtendedLifetime(lease) {} }
        if kind == "cancelled" || kind == "operationCancelled" {
            if kind == "cancelled" { _ = try f.requests.cancel(f.id, requestEpoch: f.epoch) }
            else { _ = try f.registry.requestCancellation(operationID) }
            #expect(throws: AutomationNativeTranscriptionReviewInvocationService.Failure.linkedEvidenceUnavailable) {
                try f.service.invoke(requestID: f.id, requestEpoch: f.epoch)
            }
            return
        }
        let other = AutomationOperationRegistry(storageDirectory: f.root.appendingPathComponent("other-history"))
        let otherOwner = kind == "owner" ? UUID() : ownerID
        let otherLease = try other.acquireOwnerLease(ownerID: otherOwner)
        defer { withExtendedLifetime(otherLease) {} }
        let operationCreatedAt = try f.registry.inspect(operationID).createdAt
        if kind != "missing" {
            let id = kind == "id" ? UUID() : operationID
            _ = try other.enqueue(kind: kind == "kind" ? .faceScan : .voiceTranscription,
                ownerID: otherOwner, operationID: id, now: operationCreatedAt,
                ownerLease: kind == "unmanaged" ? nil : otherLease)
            if kind != "kind" {
                _ = try other.configureBatch(id, ownerID: otherOwner,
                    itemCount: kind == "count" ? 1 : f.record.intent.photoCount, now: operationCreatedAt)
            }
        }
        let service = AutomationNativeTranscriptionReviewInvocationService(requests: f.requests,
            plans: f.plans, facade: f.facade, registry: other)
        if kind == "missing" {
            #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
                try service.invoke(requestID: f.id, requestEpoch: f.epoch)
            }
        } else {
            #expect(throws: AutomationNativeTranscriptionReviewInvocationService.Failure.linkedEvidenceUnavailable) {
                try service.invoke(requestID: f.id, requestEpoch: f.epoch)
            }
        }
    }
}
