import CryptoKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Separate durable transcription review intent")
struct MCPVoiceTranscriptionReviewRequestStoreTests {
    private struct Fixture {
        let root: URL
        let photo: URL
        let memo: URL
        let authority: MCPAuthorizationStore
        let facade: MCPAutomationFacade
        let plans: MCPVoiceTranscriptionPlanStore
        let requests: MCPVoiceTranscriptionReviewRequestStore
        let preview: MCPJSONValue
        let planID: String
        let epoch: UUID
        var archive: URL { root.appendingPathComponent("requests/operations.json") }
        var tools: MCPFoundationTools { MCPFoundationTools(authorizationStore: authority,
            voiceTranscriptionPlans: plans, voiceTranscriptionReviewRequests: requests) }
    }
    private func fixture(maximumRecords: Int = 64) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/transcription-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let box = MCPVoiceTranscriptionPlanStoreTests.Box()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(root); try authority.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: authority)
        let photo = root.appendingPathComponent("frame.jpg"), memo = root.appendingPathComponent("memo.wav")
        try Data("photo".utf8).write(to: photo); try Data("wav".utf8).write(to: memo)
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "profileIdentifier": "reviewed", "imageFilename": "frame.jpg", "memoFilename": "memo.wav"])
            .write(to: root.appendingPathComponent(".frame.jpg.voice-memo.json"))
        var input = try #require(facade.inspectPhotoVoiceMemo(path: photo.path).objectValue)
            .filter { MCPVoiceTranscriptionPlanStore.Request.photoKeys.contains($0.key) }
        input["path"] = .string(photo.path)
        let plans = MCPVoiceTranscriptionPlanStore(storageDirectory: root.appendingPathComponent("plans"))
        let preview = try plans.prepare(arguments: ["photos": .array([.object(input)]), "provider": .string("whisper"),
            "language": .string("auto"), "translate": .bool(false), "useGPU": .bool(true)], facade: facade)
        let requests = MCPVoiceTranscriptionReviewRequestStore(storageDirectory: root.appendingPathComponent("requests"), maximumRecords: maximumRecords)
        return Fixture(root: root, photo: photo, memo: memo, authority: authority, facade: facade, plans: plans,
            requests: requests, preview: preview, planID: try #require(preview.objectValue?["planID"]?.stringValue),
            epoch: try requests.capacitySnapshot().epoch)
    }
    private func request(_ f: Fixture, id: UUID = UUID()) throws -> MCPVoiceTranscriptionReviewRequestStore.Record {
        try f.requests.request(requestID: id, requestEpoch: f.epoch, planID: f.planID, plans: f.plans, facade: f.facade)
    }
    private func arguments(_ f: Fixture, id: UUID) -> [String: MCPJSONValue] {
        ["requestID": .string(id.uuidString.lowercased()), "requestEpoch": .string(f.epoch.uuidString.lowercased()), "planID": .string(f.planID)]
    }
    private func structured(_ result: MCPJSONValue) throws -> [String: MCPJSONValue] { try #require(result.objectValue?["structuredContent"]?.objectValue) }
    private func mutateArchive(_ f: Fixture, body: (inout [String: Any]) throws -> Void) throws {
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.archive)) as? [String: Any])
        let data = try #require(Data(base64Encoded: envelope["payload"] as! String))
        var archive = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try body(&archive)
        let payload = try JSONSerialization.data(withJSONObject: archive)
        envelope["payload"] = payload.base64EncodedString()
        envelope["sha256"] = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: envelope).write(to: f.archive)
    }
    @Test("Read-only discovery creates nothing; capacity persists a separate mandatory epoch")
    func empty() throws {
        let root = URL(fileURLWithPath: "/private/tmp/review-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPVoiceTranscriptionReviewRequestStore(storageDirectory: root, maximumRecords: 1_000)
        #expect(try store.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.unknownRequest) { try store.inspect(UUID(), requestEpoch: UUID()) }
        let capacity = try store.capacitySnapshot()
        #expect(capacity.maximumRecords == 64)
        #expect(try MCPVoiceTranscriptionReviewRequestStore(storageDirectory: root).capacitySnapshot() == capacity)
        #expect(try MCPVoiceTranscriptionReviewRequestStore.defaultStorageDirectory().lastPathComponent.hasPrefix(".aagedal-photo-agent"))
    }
    @Test("Immutable ordered intent survives restart; no drafts or operations are created")
    func restoration() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), retained = try request(f, id: id)
        #expect(retained.intent == (try MCPVoiceTranscriptionReviewRequestStore.Intent(preview: f.preview)))
        #expect(retained.intent.photoCount == 1)
        #expect(retained.intentSHA256.utf8.count == 64); #expect(retained.batchIdentity.utf8.count == 64)
        let before = try Data(contentsOf: f.archive)
        let restarted = MCPVoiceTranscriptionReviewRequestStore(storageDirectory: f.root.appendingPathComponent("requests"))
        #expect(try restarted.inspect(id, requestEpoch: f.epoch) == retained)
        #expect(try restarted.records() == [retained])
        #expect(try request(f, id: id) == retained)
        #expect(try Data(contentsOf: f.archive) == before)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".photo_metadata").path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations").path))
    }
    @Test("Exact retry remains status-only after expiry or photo and authority changes")
    func retryAfterDrift() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), retained = try request(f, id: id)
        try Data("changed".utf8).write(to: f.memo)
        try f.authority.setEnabled(false)
        #expect(try f.requests.request(requestID: id, requestEpoch: f.epoch, planID: f.planID,
            plans: MCPVoiceTranscriptionPlanStore(), facade: f.facade, now: Date().addingTimeInterval(301)) == retained)
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.conflictingRequest) {
            try f.requests.request(requestID: id, requestEpoch: f.epoch, planID: UUID().uuidString.lowercased(), plans: f.plans, facade: f.facade)
        }
        #expect(try structured(f.tools.callTool(name: "get_voice_transcription_review_request",
            arguments: arguments(f, id: id).filter { $0.key != "planID" }))["code"] == .string("disabled"))
    }
    @Test("Fresh intent refuses every stale plan or authorization, leaving archive unchanged", arguments: ["wav", "source", "relationship", "xmp", "authority", "expiry"])
    func staleNewIntent(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try Data(contentsOf: f.archive)
        switch kind {
        case "wav": try Data("changed".utf8).write(to: f.memo)
        case "source": try Data("changed".utf8).write(to: f.photo)
        case "relationship": try Data("changed".utf8).write(to: f.root.appendingPathComponent(".frame.jpg.voice-memo.json"))
        case "xmp": try Data("changed".utf8).write(to: f.root.appendingPathComponent("frame.xmp"))
        case "authority": try f.authority.setEnabled(false); try f.authority.setEnabled(true)
        default: break
        }
        #expect(throws: (any Error).self) {
            try f.requests.request(requestID: UUID(), requestEpoch: f.epoch, planID: f.planID, plans: f.plans,
                facade: f.facade, now: kind == "expiry" ? Date().addingTimeInterval(301) : Date())
        }
        #expect(try f.requests.records().isEmpty); #expect(try Data(contentsOf: f.archive) == before)
        let lease = try MCPProcessReservation.acquirePhoto(f.photo); lease.release()
    }
    @Test("Retirement rotates epoch; exact retained retries survive but retired old handles cannot replay")
    func epochRetirement() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let liveID = UUID(), cancelledID = UUID(), live = try request(f, id: liveID)
        _ = try request(f, id: cancelledID)
        _ = try f.requests.cancelBeforeAdmission(cancelledID, requestEpoch: f.epoch)
        let current = try f.requests.recoverCancelledCapacity(expectedEpoch: f.epoch)
        #expect(current != f.epoch); #expect(try request(f, id: liveID) == live)
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.staleEpoch) { try request(f, id: cancelledID) }
        let recreated = try f.requests.request(requestID: cancelledID, requestEpoch: current, planID: f.planID, plans: f.plans, facade: f.facade)
        #expect(recreated.state == .awaitingReview)
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.staleEpoch) { try f.requests.cancelBeforeAdmission(cancelledID, requestEpoch: f.epoch) }
        #expect(try f.requests.inspect(cancelledID, requestEpoch: current) == recreated)
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.staleEpoch) { try f.requests.recoverCancelledCapacity(expectedEpoch: f.epoch) }
    }
    @Test("Bounded independent stores never evict live or cancelled intent")
    func capacity() throws {
        let f = try fixture(maximumRecords: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(); _ = try request(f, id: id)
        let cancelled = try f.requests.cancelBeforeAdmission(id, requestEpoch: f.epoch)
        let second = MCPVoiceTranscriptionReviewRequestStore(storageDirectory: f.root.appendingPathComponent("requests"), maximumRecords: 1)
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.capacity) { try second.request(requestID: UUID(), requestEpoch: f.epoch, planID: f.planID, plans: f.plans, facade: f.facade) }
        #expect(try second.inspect(id, requestEpoch: f.epoch) == cancelled)
        #expect(try f.requests.cancelBeforeAdmission(id, requestEpoch: f.epoch) == cancelled)
    }
    @Test("Checksum-valid unknown fields, future domains and fabricated execution remain fail-closed", arguments: ["future", "purpose", "consent", "admitted", "unknown", "operation", "epoch", "option", "photo", "digest", "date", "cancel-null"])
    func malformed(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try request(f)
        try mutateArchive(f) { archive in
            if kind == "future" { archive["schemaVersion"] = 2; return }
            var records = archive["records"] as! [[String: Any]], record = records[0]
            switch kind {
            case "purpose": record["purpose"] = "pendingDraft"
            case "consent": record["consentGranted"] = true
            case "admitted": record["state"] = "admitted"
            case "unknown": record["state"] = "unknownDisposition"
            case "operation": record["operationID"] = UUID().uuidString.lowercased()
            case "epoch": record["requestEpoch"] = UUID().uuidString.uppercased()
            case "digest": record["intentSHA256"] = String(repeating: "0", count: 64)
            case "date": record["createdAt"] = (record["createdAt"] as! Double) - 1_000
            case "cancel-null": record["cancellationRequestedAt"] = NSNull()
            default:
                var intent = record["intent"] as! [String: Any]
                if kind == "option" { var options = intent["options"] as! [String: Any]; options["consent"] = true; intent["options"] = options }
                else { var photos = intent["photos"] as! [[String: Any]]; photos[0]["executionAvailable"] = true; intent["photos"] = photos }
                record["intent"] = intent
            }
            records[0] = record; archive["records"] = records
        }
        let damaged = try Data(contentsOf: f.archive)
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.invalidStorage) { try f.requests.records() }
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.invalidStorage) { try f.requests.capacitySnapshot() }
        #expect(try Data(contentsOf: f.archive) == damaged)
    }
    @Test("Helper protocol requires exact epoch handles and truthfully separates review from execution")
    func protocolContract() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), args = arguments(f, id: id), tool = "request_voice_transcription_review"
        var missingEpoch = args; missingEpoch.removeValue(forKey: "requestEpoch")
        #expect(try structured(f.tools.callTool(name: tool, arguments: missingEpoch))["code"] == .string("invalid_arguments"))
        var extra = args; extra["consent"] = .bool(true)
        #expect(try structured(f.tools.callTool(name: tool, arguments: extra))["code"] == .string("invalid_arguments"))
        let value = try structured(f.tools.callTool(name: tool, arguments: args))
        for key in ["consentGranted", "executionAvailable", "commitAvailable", "nativeAdmissionAvailable", "operationLinkageAvailable"] { #expect(value[key] == .bool(false)) }
        #expect(value["operationID"] == .null); #expect(value["photoCount"] == .integer(1))
        let handle = args.filter { $0.key != "planID" }
        #expect(try structured(f.tools.callTool(name: "get_voice_transcription_review_request", arguments: handle)) == value)
        let listed = try structured(f.tools.callTool(name: "list_voice_transcription_review_requests", arguments: [:]))
        #expect(listed["requests"] == .array([.object(value)]))
        let cancelled = try structured(f.tools.callTool(name: "cancel_voice_transcription_review_request", arguments: handle))
        #expect(cancelled["state"] == .string("cancelled"))
        #expect(try structured(f.tools.callTool(name: tool, arguments: args)) == cancelled)
        let capabilities = try structured(f.tools.callTool(name: "get_server_capabilities", arguments: [:]))
        #expect(capabilities["voiceTranscriptionReviewRequestProtocolVersion"] == .integer(1))
        #expect(capabilities["voiceTranscriptionReviewNativeAdmissionAvailable"] == .bool(false))
        for name in [tool, "get_voice_transcription_review_request", "cancel_voice_transcription_review_request", "list_voice_transcription_review_requests", "get_voice_transcription_review_capacity"] {
            let definition = try #require(f.tools.toolDefinitions(configuration: .init()).first { $0.objectValue?["name"] == .string(name) }?.objectValue)
            #expect(definition["inputSchema"]?.objectValue?["additionalProperties"] == .bool(false))
        }
    }
    @Test("Injected helper storage stays separate from IPTC and exact retries never read replacement plans")
    func helperDomainIsolation() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), args = arguments(f, id: id)
        let iptc = MCPNativeReviewRequestStore(storageDirectory: f.root.appendingPathComponent("iptc-requests"))
        let iptcEpoch = try iptc.capacitySnapshot().epoch
        _ = try iptc.request(requestID: id, requestEpoch: iptcEpoch, planID: f.planID, purpose: .pendingDraft)
        let tools = MCPFoundationTools(authorizationStore: f.authority, voiceTranscriptionPlans: f.plans,
            nativeReviewRequests: iptc, voiceTranscriptionReviewRequests: f.requests)
        let value = try structured(tools.callTool(name: "request_voice_transcription_review", arguments: args))
        #expect(value["state"] == .string("awaitingReview"))
        let restarted = MCPFoundationTools(authorizationStore: f.authority, voiceTranscriptionPlans: MCPVoiceTranscriptionPlanStore(),
            nativeReviewRequests: iptc, voiceTranscriptionReviewRequests: f.requests)
        try Data("changed after handoff".utf8).write(to: f.memo)
        #expect(try structured(restarted.callTool(name: "request_voice_transcription_review", arguments: args)) == value)
        let handle = args.filter { $0.key != "planID" }
        #expect(try structured(restarted.callTool(name: "cancel_voice_transcription_review_request", arguments: handle))["state"] == .string("cancelled"))
        #expect(try iptc.inspect(id).state == .awaitingReview)
        var foreign = args; foreign["requestEpoch"] = .string(iptcEpoch.uuidString.lowercased())
        #expect(try structured(restarted.callTool(name: "request_voice_transcription_review", arguments: foreign))["code"] == .string("stale_voice_transcription_review_request_epoch"))
    }
    @Test("Helper malformed handles and archived execution injection cannot admit or replay work")
    func helperExecutionInjection() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), args = arguments(f, id: id)
        for key in ["execute", "admit", "provider", "modelPath", "purpose", "operationID", "intentSHA256"] {
            var injected = args; injected[key] = .string("untrusted")
            #expect(try structured(f.tools.callTool(name: "request_voice_transcription_review", arguments: injected))["code"] == .string("invalid_arguments"))
        }
        for key in ["requestID", "requestEpoch", "planID"] {
            var malformed = args; malformed[key] = .string("NOT-A-CANONICAL-UUID")
            #expect(try structured(f.tools.callTool(name: "request_voice_transcription_review", arguments: malformed))["code"] == .string("invalid_arguments"))
        }
        #expect(try f.requests.records().isEmpty)
        _ = try request(f, id: id)
        try mutateArchive(f) { archive in
            var records = archive["records"] as! [[String: Any]]
            records[0]["state"] = "unknownDisposition"
            archive["records"] = records
        }
        let damaged = try Data(contentsOf: f.archive)
        for name in ["request_voice_transcription_review", "get_voice_transcription_review_request", "cancel_voice_transcription_review_request"] {
            let arguments = name == "request_voice_transcription_review" ? args : args.filter { $0.key != "planID" }
            #expect(try structured(f.tools.callTool(name: name, arguments: arguments))["code"] == .string("invalid_voice_transcription_review_request_storage"))
        }
        #expect(try Data(contentsOf: f.archive) == damaged)
    }
}
