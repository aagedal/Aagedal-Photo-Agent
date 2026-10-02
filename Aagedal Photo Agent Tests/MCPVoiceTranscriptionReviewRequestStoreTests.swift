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
        nonisolated var operations: AutomationOperationRegistry { AutomationOperationRegistry(storageDirectory: root.appendingPathComponent("operations")) }
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
            if kind == "future" { archive["schemaVersion"] = 3; return }
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
        for key in ["consentGranted", "executionAvailable", "commitAvailable"] { #expect(value[key] == .bool(false)) }
        for key in ["nativeAdmissionAvailable", "operationLinkageAvailable"] { #expect(value[key] == .bool(true)) }
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
        #expect(capabilities["voiceTranscriptionReviewNativeAdmissionAvailable"] == .bool(true))
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
    @Test("Version one intent archives migrate on mutation without changing original handles")
    func migration() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), retained = try request(f, id: id)
        try mutateArchive(f) { $0["schemaVersion"] = 1 }
        let before = try Data(contentsOf: f.archive)
        #expect(try f.requests.inspect(id, requestEpoch: f.epoch) == retained)
        #expect(try request(f, id: id) == retained)
        #expect(try Data(contentsOf: f.archive) == before)
        let admitted = try f.requests.admit(id, requestEpoch: f.epoch, expected: retained, operationID: UUID(), ownerID: UUID(), registry: f.operations)
        #expect(admitted.state == .admitted)
        #expect(admitted.requestEpoch == retained.requestEpoch)
        #expect(admitted.intent == retained.intent)
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.archive)) as? [String: Any])
        let payload = try #require(Data(base64Encoded: envelope["payload"] as! String))
        let archive = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(archive["schemaVersion"] as? Int == 2)
        #expect(try f.requests.records() == [admitted])
    }

    @Test("Admission binds exact intent, owner and reserved operation, and cannot replay after restart")
    func admissionIdentity() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), operation = UUID(), owner = UUID(), retained = try request(f, id: id)
        let secondID = UUID(), second = try request(f, id: secondID)
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.conflictingRequest) {
            try f.requests.admit(id, requestEpoch: f.epoch, expected: second, operationID: operation, ownerID: owner, registry: f.operations)
        }
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.staleEpoch) {
            try f.requests.admit(id, requestEpoch: UUID(), expected: retained, operationID: operation, ownerID: owner, registry: f.operations)
        }
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.invalidArguments) {
            try f.requests.admit(id, requestEpoch: f.epoch, expected: retained, operationID: operation, ownerID: owner, registry: f.operations,
                                 now: Date().addingTimeInterval(301))
        }
        let admitted = try f.requests.admit(id, requestEpoch: f.epoch, expected: retained, operationID: operation, ownerID: owner, registry: f.operations)
        #expect(admitted.operationID == nil)
        #expect(admitted.admission?.operationID == operation.uuidString.lowercased())
        #expect(admitted.admission?.ownerID == owner.uuidString.lowercased())
        #expect(admitted.admission?.intentSHA256 == retained.intentSHA256)
        #expect(admitted.admission?.batchIdentity == retained.batchIdentity)
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.conflictingRequest) {
            try f.requests.admit(secondID, requestEpoch: f.epoch, expected: second, operationID: operation, ownerID: owner, registry: f.operations)
        }
        let restarted = MCPVoiceTranscriptionReviewRequestStore(storageDirectory: f.root.appendingPathComponent("requests"))
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition) {
            try restarted.admit(id, requestEpoch: f.epoch, expected: admitted, operationID: operation, ownerID: owner, registry: f.operations)
        }
        #expect(try request(f, id: id) == admitted)
        let cancelled = try restarted.cancel(id, requestEpoch: f.epoch)
        #expect(cancelled.state == .admitted)
        #expect(cancelled.cancellationRequestedAt != nil)
        #expect(try restarted.capacitySnapshot().cancelledBeforeAdmissionCount == 0)
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition) {
            try restarted.recoverCancelledCapacity(expectedEpoch: f.epoch)
        }
    }

    private func queuedOperation(_ f: Fixture, operationID: UUID, ownerID: UUID,
                                 kind: AutomationOperationRegistry.Kind = .voiceTranscription,
                                 count: Int = 1, managed: Bool = true) throws -> (AutomationOperationRegistry, AutomationOperationPersistence.OwnerLease?) {
        let registry = AutomationOperationRegistry(storageDirectory: f.root.appendingPathComponent("operations"))
        let lease = managed ? try registry.acquireOwnerLease(ownerID: ownerID) : nil
        _ = try registry.enqueue(kind: kind, ownerID: ownerID, operationID: operationID, ownerLease: lease)
        if kind == .voiceTranscription { _ = try registry.configureBatch(operationID, ownerID: ownerID, itemCount: count) }
        return (registry, lease)
    }

    @Test("Helper cancellation of an exact linked native transcription stays a cooperative request")
    func helperCancelsLinkedNativeWork() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), operation = UUID(), owner = UUID(), retained = try request(f, id: id)
        _ = try f.requests.admit(id, requestEpoch: f.epoch, expected: retained,
            operationID: operation, ownerID: owner, registry: f.operations)
        let (registry, lease) = try queuedOperation(f, operationID: operation, ownerID: owner)
        defer { withExtendedLifetime(lease) {} }
        _ = try f.requests.link(id, requestEpoch: f.epoch, operationID: operation, registry: registry)
        let handle: [String: MCPJSONValue] = ["requestID": .string(id.uuidString.lowercased()),
            "requestEpoch": .string(f.epoch.uuidString.lowercased())]
        let result = try structured(f.tools.callTool(name: "cancel_voice_transcription_review_request", arguments: handle))
        #expect(result["state"] == .string("linked"))
        #expect(result["operationID"] == .string(operation.uuidString.lowercased()))
        #expect(result["cancellationRequested"] == .bool(true))
        #expect(result["executionAvailable"] == .bool(false))
        #expect(try registry.inspect(operation).outcome == nil)
        #expect(try structured(f.tools.callTool(name: "cancel_voice_transcription_review_request", arguments: handle)) == result)
        #expect(throws: CancellationError.self) { try f.requests.checkCancellation(id, requestEpoch: f.epoch, operationID: operation) }
        #expect(try f.requests.capacitySnapshot().cancelledBeforeAdmissionCount == 0)
    }

    @Test("Only the exact live reserved operation can link", arguments: ["foreign", "owner", "kind", "count", "unmanaged", "cancelled", "running", "missing", "expired"])
    func wrongOperation(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), reserved = UUID(), owner = UUID(), retained = try request(f, id: id)
        _ = try f.requests.admit(id, requestEpoch: f.epoch, expected: retained, operationID: reserved, ownerID: owner, registry: f.operations)
        let operation = kind == "foreign" || kind == "missing" ? UUID() : reserved
        let actualOwner = kind == "owner" ? UUID() : owner
        let (registry, lease) = try queuedOperation(f, operationID: operation, ownerID: actualOwner,
            kind: kind == "kind" ? .iptcDraft : .voiceTranscription, count: kind == "count" ? 2 : 1, managed: kind != "unmanaged")
        defer { withExtendedLifetime(lease) {} }
        if kind == "cancelled" { _ = try registry.requestCancellation(operation) }
        if kind == "running" { _ = try registry.start(operation, ownerID: actualOwner) }
        #expect(throws: (any Error).self) {
            try f.requests.link(id, requestEpoch: f.epoch, operationID: kind == "missing" ? reserved : operation,
                                registry: registry, now: kind == "expired" ? Date().addingTimeInterval(301) : Date())
        }
        #expect(try f.requests.inspect(id, requestEpoch: f.epoch).state == .admitted)
        #expect(try f.requests.inspect(id, requestEpoch: f.epoch).operationID == nil)
    }

    @Test("Linkage and post-admission cancellation preserve exact handles across epoch rotation")
    func linkedCancellation() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), operation = UUID(), owner = UUID(), retained = try request(f, id: id)
        _ = try f.requests.admit(id, requestEpoch: f.epoch, expected: retained, operationID: operation, ownerID: owner, registry: f.operations)
        let (registry, lease) = try queuedOperation(f, operationID: operation, ownerID: owner)
        defer { withExtendedLifetime(lease) {} }
        let linked = try f.requests.link(id, requestEpoch: f.epoch, operationID: operation, registry: registry)
        #expect(linked.state == .linked); #expect(linked.operationID == operation.uuidString.lowercased())
        #expect(try f.requests.link(id, requestEpoch: f.epoch, operationID: operation, registry: registry) == linked)
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition) {
            try f.requests.checkCancellation(id, requestEpoch: f.epoch, operationID: UUID())
        }
        try f.requests.checkCancellation(id, requestEpoch: f.epoch, operationID: operation)
        let cancelledID = UUID(); _ = try request(f, id: cancelledID)
        _ = try f.requests.cancelBeforeAdmission(cancelledID, requestEpoch: f.epoch)
        let epoch = try f.requests.recoverCancelledCapacity(expectedEpoch: f.epoch)
        #expect(epoch != f.epoch)
        let cancelled = try f.requests.cancel(id, requestEpoch: f.epoch)
        #expect(cancelled.state == .linked); #expect(cancelled.operationID == linked.operationID)
        #expect(try f.requests.cancel(id, requestEpoch: f.epoch) == cancelled)
        #expect(try request(f, id: id) == cancelled)
        #expect(throws: CancellationError.self) { try f.requests.checkCancellation(id, requestEpoch: f.epoch, operationID: operation) }
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.staleEpoch) {
            try f.requests.cancel(id, requestEpoch: epoch)
        }
        #expect(try f.requests.capacitySnapshot().cancelledBeforeAdmissionCount == 0)
    }

    @Test("Cancelled admission cannot acquire a link or be retired")
    func cancellationBeforeLink() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), operation = UUID(), owner = UUID(), retained = try request(f, id: id)
        _ = try f.requests.admit(id, requestEpoch: f.epoch, expected: retained, operationID: operation, ownerID: owner, registry: f.operations)
        _ = try f.requests.cancel(id, requestEpoch: f.epoch)
        let (registry, lease) = try queuedOperation(f, operationID: operation, ownerID: owner)
        defer { withExtendedLifetime(lease) {} }
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition) {
            try f.requests.link(id, requestEpoch: f.epoch, operationID: operation, registry: registry)
        }
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition) {
            try f.requests.cancelBeforeAdmission(id, requestEpoch: f.epoch)
        }
        #expect(try f.requests.inspect(id, requestEpoch: f.epoch).state == .admitted)
    }

    @Test("Admission and linkage archive fields remain closed and fully bound", arguments: ["future", "field", "epoch", "request", "digest", "owner", "operation", "null", "missing", "state", "date", "linked-date", "duplicate"])
    func malformedAdmission(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), operation = UUID(), owner = UUID(), retained = try request(f, id: id)
        _ = try f.requests.admit(id, requestEpoch: f.epoch, expected: retained, operationID: operation, ownerID: owner, registry: f.operations)
        let (registry, lease) = try queuedOperation(f, operationID: operation, ownerID: owner)
        defer { withExtendedLifetime(lease) {} }
        _ = try f.requests.link(id, requestEpoch: f.epoch, operationID: operation, registry: registry)
        try mutateArchive(f) { archive in
            var records = archive["records"] as! [[String: Any]], record = records[0]
            var admission = record["admission"] as! [String: Any]
            switch kind {
            case "future": admission["schemaVersion"] = 2
            case "field": admission["consentGranted"] = true
            case "epoch": admission["requestEpoch"] = UUID().uuidString.lowercased()
            case "request": admission["requestID"] = UUID().uuidString.lowercased()
            case "digest": admission["intentSHA256"] = String(repeating: "0", count: 64)
            case "owner": admission["ownerID"] = UUID().uuidString.uppercased()
            case "operation": admission["operationID"] = "not-an-id"
            case "null": admission["admissionID"] = NSNull()
            case "missing": admission.removeValue(forKey: "admissionID")
            case "state": record["state"] = "awaitingReview"
            case "date": record["admittedAt"] = (record["createdAt"] as! Double) - 1
            case "linked-date": record["linkedAt"] = (record["admittedAt"] as! Double) - 1
            default:
                var duplicate = record; duplicate["requestID"] = UUID().uuidString.lowercased()
                var identity = admission; identity["requestID"] = duplicate["requestID"]
                duplicate["admission"] = identity; records.append(duplicate)
            }
            record["admission"] = admission; records[0] = record; archive["records"] = records
        }
        let before = try Data(contentsOf: f.archive)
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.invalidStorage) { try f.requests.records() }
        #expect(try Data(contentsOf: f.archive) == before)
    }

    @Test("Failed exact admission never enqueues or runs work")
    func failedAdmissionNeverRuns() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), reserved = UUID(), retained = try request(f, id: id)
        let registry = AutomationOperationRegistry(storageDirectory: f.root.appendingPathComponent("operations"))
        let runner = AutomationOperationExecutionCoordinator(registry: registry)
        let owner = await runner.ownerID
        _ = try f.requests.cancelBeforeAdmission(id, requestEpoch: f.epoch)
        await #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.conflictingRequest) {
            try await runner.submit(kind: .voiceTranscription, operationID: reserved, admission: {
                _ = try f.requests.admit(id, requestEpoch: f.epoch, expected: retained, operationID: reserved, ownerID: owner, registry: f.operations)
            }) { _ in
                Issue.record("Work ran after refused transcription admission")
                return .verified
            }
        }
        #expect(try registry.records().isEmpty)
        _ = try await runner.shutdown()
    }

    @Test("Failed linkage never runs work, and interrupted admission cannot replay", arguments: [false, true])
    func failedLinkNeverRuns(cancelBeforeLink: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), reserved = UUID(), retained = try request(f, id: id)
        let registry = AutomationOperationRegistry(storageDirectory: f.root.appendingPathComponent("operations"))
        let runner = AutomationOperationExecutionCoordinator(registry: registry)
        let owner = await runner.ownerID
        await #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition) {
            try await runner.submit(kind: .voiceTranscription, operationID: reserved, admission: {
                _ = try f.requests.admit(id, requestEpoch: f.epoch, expected: retained, operationID: reserved, ownerID: owner, registry: f.operations)
            }, didEnqueue: { operation in
                _ = try registry.configureBatch(operation.id, ownerID: owner, itemCount: 1)
                if cancelBeforeLink { _ = try f.requests.cancel(id, requestEpoch: f.epoch) }
                _ = try f.requests.link(id, requestEpoch: f.epoch,
                    operationID: cancelBeforeLink ? reserved : UUID(), registry: registry)
            }) { _ in
                Issue.record("Work ran after refused transcription linkage")
                return .verified
            }
        }
        #expect(try registry.records().count == 1)
        #expect(try registry.inspect(reserved).outcome == .failed)
        let restarted = MCPVoiceTranscriptionReviewRequestStore(storageDirectory: f.root.appendingPathComponent("requests"))
        let admitted = try restarted.inspect(id, requestEpoch: f.epoch)
        #expect(admitted.state == .admitted); #expect(admitted.operationID == nil)
        await #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition) {
            try await runner.submit(kind: .voiceTranscription, admission: {
                _ = try restarted.admit(id, requestEpoch: f.epoch, expected: admitted, operationID: UUID(), ownerID: owner, registry: f.operations)
            }) { _ in
                Issue.record("Interrupted transcription admission was replayed")
                return .verified
            }
        }
        #expect(try registry.records().count == 1)
        _ = try await runner.shutdown()
    }

    private enum IntegrationFailure: Error { case inference }
    private actor IntegrationProbe {
        var generationCount = 0
        var saveCount = 0
        func generated() { generationCount += 1 }
        func saved() { saveCount += 1 }
    }

    @Test("Exact request admission and batch hooks link before recognition and bridge cancellation", arguments: ["linked", "wrong-owner", "wrong-intent", "cancelled"])
    func batchIntegration(mode: String) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), operationID = UUID(), retained = try request(f, id: id)
        let secondID = UUID(), second = try request(f, id: secondID)
        let registry = AutomationOperationRegistry(storageDirectory: f.root.appendingPathComponent("operations"))
        let probe = IntegrationProbe(), requests = f.requests, epoch = f.epoch
        let dependencies = AutomationVoiceTranscriptionBatchService.Dependencies(capture: { image in
            guard case .available(let association) = try VoiceMemoTranscriptionService.lookupRegularAssociation(for: image) else {
                throw VoiceMemoTranscriptionError.relationshipUnavailable
            }
            return .init(imageURL: image, sourceRevision: try await SourceImageRevision.capture(at: image),
                         association: association, memoRevision: try await SourceImageRevision.capture(at: association.memoURL),
                         relationshipRevision: try VoiceMemoRelationshipRevision.capture(for: image))
        }, generate: { _, _ in
            await probe.generated()
            let record = try requests.inspect(id, requestEpoch: epoch)
            #expect(record.state == .linked)
            #expect(record.operationID == operationID.uuidString.lowercased())
            #expect(try registry.inspect(operationID).state == .running)
            throw IntegrationFailure.inference
        }, save: { draft, _ in
            await probe.saved()
            Issue.record("Synthetic integration inference must never save a draft")
            return draft
        })
        let service = AutomationVoiceTranscriptionBatchService(registry: registry, dependencies: dependencies)
        let prepared = try await service.prepare(imageURLs: [f.photo])
        let hooks = AutomationVoiceTranscriptionBatchService.LifecycleHooks(operationID: operationID,
            admission: { owner in
                _ = try requests.admit(id, requestEpoch: epoch, expected: mode == "wrong-intent" ? second : retained,
                                       operationID: operationID, ownerID: mode == "wrong-owner" ? UUID() : owner, registry: registry)
            }, didEnqueue: { operation in
                #expect(operation.id == operationID)
                #expect(operation.batchProgress?.itemCount == retained.intent.photoCount)
                _ = try requests.link(id, requestEpoch: epoch, operationID: operation.id, registry: registry)
                if mode == "cancelled" { _ = try requests.cancel(id, requestEpoch: epoch) }
            }, cancellationCheck: { operation in
                do { try requests.checkCancellation(id, requestEpoch: epoch, operationID: operation) }
                catch is CancellationError {
                    _ = try registry.requestCancellation(operation)
                    throw CancellationError()
                }
            })
        if ["wrong-owner", "wrong-intent"].contains(mode) {
            await #expect(throws: (any Error).self) {
                try await service.submit(prepared: prepared, provider: .apple(Locale(identifier: "en-US")), lifecycle: hooks)
            }
            #expect(try registry.records().count == (mode == "wrong-owner" ? 1 : 0))
            if mode == "wrong-owner" { #expect(try registry.inspect(operationID).outcome == .failed) }
        } else {
            let accepted = try await service.submit(prepared: prepared, provider: .apple(Locale(identifier: "en-US")), lifecycle: hooks)
            #expect(accepted.id == operationID)
            let terminal = try await service.waitForCompletion(operationID)
            #expect(terminal.outcome == (mode == "cancelled" ? .cancelled : .failed))
            #expect((terminal.cancellationRequestedAt != nil) == (mode == "cancelled"))
        }
        #expect(await probe.generationCount == (mode == "linked" ? 1 : 0))
        #expect(await probe.saveCount == 0)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".photo_metadata").path))
        try await service.shutdown()
    }

    @Test("A preexisting operation cannot be admitted even with equal timestamps")
    func reusedOperationWithEqualClock() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), operation = UUID(), owner = UUID(), retained = try request(f, id: id)
        let registry = f.operations
        let lease = try registry.acquireOwnerLease(ownerID: owner)
        defer { withExtendedLifetime(lease) {} }
        _ = try registry.enqueue(kind: .voiceTranscription, ownerID: owner, operationID: operation,
                                 now: retained.updatedAt, ownerLease: lease)
        let before = try Data(contentsOf: f.archive)
        #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.conflictingRequest) {
            try f.requests.admit(id, requestEpoch: f.epoch, expected: retained, operationID: operation,
                                 ownerID: owner, registry: registry, now: retained.updatedAt)
        }
        #expect(try f.requests.inspect(id, requestEpoch: f.epoch) == retained)
        #expect(try Data(contentsOf: f.archive) == before)
    }

    @Test("Cold admission initializes locked empty history without enqueuing work")
    func coldAdmissionHistory() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), operationID = UUID(), retained = try request(f, id: id)
        let directory = f.root.appendingPathComponent("operations")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let registry = f.operations
        let admitted = try f.requests.admit(id, requestEpoch: f.epoch, expected: retained,
            operationID: operationID, ownerID: UUID(), registry: registry)
        #expect(admitted.state == .admitted)
        #expect(admitted.operationID == nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("operations.json").path))
        #expect(try registry.records().isEmpty)
        #expect(try AutomationOperationRegistry(storageDirectory: directory).records().isEmpty)
        #expect(try f.requests.inspect(id, requestEpoch: f.epoch) == admitted)
    }

    @Test("A held cold history lock refuses admission without publishing request evidence")
    func heldColdHistoryLock() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(), operationID = UUID(), retained = try request(f, id: id)
        let before = try Data(contentsOf: f.archive)
        let holder = f.operations, contender = f.operations
        try holder.withAvailableOperationID(UUID()) { () throws in
            #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
                try f.requests.admit(id, requestEpoch: f.epoch, expected: retained,
                    operationID: operationID, ownerID: UUID(), registry: contender)
            }
            #expect(try f.requests.inspect(id, requestEpoch: f.epoch) == retained)
            #expect(try Data(contentsOf: f.archive) == before)
        }
        #expect(try holder.records().isEmpty)
        let admitted = try f.requests.admit(id, requestEpoch: f.epoch, expected: retained,
            operationID: operationID, ownerID: UUID(), registry: contender)
        #expect(admitted.state == .admitted)
        #expect(try contender.records().isEmpty)
    }

}
