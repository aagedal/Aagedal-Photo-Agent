import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Immutable MCP voice transcription batch previews")
struct MCPVoiceTranscriptionPlanStoreTests {
    nonisolated final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?
        func read() -> Data? { lock.withLock { value } }
        func write(_ data: Data?) { lock.withLock { value = data } }
    }
    private struct Fixture {
        let root: URL
        let photos: [URL]
        let memos: [URL]
        let relationships: [URL]
        let store: MCPAuthorizationStore
        let facade: MCPAutomationFacade
        let arguments: [String: MCPJSONValue]
        var storage: URL { root.appendingPathComponent("private-plans") }
    }
    private func fixture(count: Int = 2, teamCreation: Bool? = nil) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/voice-preview-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let box = Box()
        let store = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try store.addRoot(root); try store.setEnabled(true)
        if let teamCreation { var config = try store.load(); config.allowsTeamCreation = teamCreation; try store.save(config) }
        let facade = MCPAutomationFacade(authorizationStore: store)
        var photos: [URL] = [], memos: [URL] = [], relationships: [URL] = [], inputs: [MCPJSONValue] = []
        for index in 0..<count {
            let photo = root.appendingPathComponent("frame\(index).jpg"), memo = root.appendingPathComponent("memo\(index).wav")
            let relationship = root.appendingPathComponent(".\(photo.lastPathComponent).voice-memo.json")
            try Data("photo \(index)".utf8).write(to: photo); try Data("wav \(index)".utf8).write(to: memo)
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "profileIdentifier": "custom-reviewed-profile", "imageFilename": photo.lastPathComponent, "memoFilename": memo.lastPathComponent]).write(to: relationship)
            let evidence = try #require(facade.inspectPhotoVoiceMemo(path: photo.path).objectValue)
            var input = evidence.filter { MCPVoiceTranscriptionPlanStore.Request.photoKeys.contains($0.key) }
            input["path"] = .string(photo.path)
            inputs.append(.object(input)); photos.append(photo); memos.append(memo); relationships.append(relationship)
        }
        return Fixture(root: root, photos: photos, memos: memos, relationships: relationships, store: store, facade: facade,
            arguments: ["photos": .array(inputs), "provider": .string("whisper"), "language": .string("auto"), "translate": .bool(false), "useGPU": .bool(true)])
    }
    private func planArguments(_ value: MCPJSONValue) throws -> [String: MCPJSONValue] {
        ["planID": try #require(value.objectValue?["planID"])]
    }
    @Test("Whole ordered preview restores unchanged, including independent team preferences", arguments: [true, false])
    func restored(teamCreation: Bool) throws {
        let f = try fixture(teamCreation: teamCreation); defer { try? FileManager.default.removeItem(at: f.root) }
        let plans = MCPVoiceTranscriptionPlanStore(storageDirectory: f.storage)
        let value = try plans.prepare(arguments: f.arguments, facade: f.facade)
        let object = try #require(value.objectValue)
        #expect(object["previewOnly"] == .bool(true)); #expect(object["executionAvailable"] == .bool(false))
        #expect(object["commitAvailable"] == .bool(false)); #expect(object["consentGranted"] == .bool(false))
        #expect(object["providerModelIdentity"] == .string("unresolved-application-session-required"))
        #expect(object["options"] == .object(f.arguments.filter { $0.key != "photos" }))
        #expect(object["photoCount"] == .integer(2))
        let restarted = MCPVoiceTranscriptionPlanStore(storageDirectory: f.storage)
        let args = try planArguments(value), bytes = try Data(contentsOf: f.storage.appendingPathComponent("plans.json"))
        #expect(try restarted.inspect(arguments: args, facade: f.facade) == value)
        #expect(try Data(contentsOf: f.storage.appendingPathComponent("plans.json")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".photo_metadata").path))
    }
    @Test("Handoff callback retains whole-set reservations and rejects publication-time carrier drift")
    func retainedHandoff() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let plans = MCPVoiceTranscriptionPlanStore(), value = try plans.prepare(arguments: f.arguments, facade: f.facade)
        let id = try #require(value.objectValue?["planID"]?.stringValue)
        var collisions = 0, observedPreview: MCPJSONValue?
        #expect(throws: (any Error).self) {
            try plans.withValidatedPreview(planID: id, facade: f.facade) { preview in
                observedPreview = preview
                for photo in f.photos {
                    do { let unexpected = try MCPProcessReservation.acquirePhoto(photo); unexpected.release() }
                    catch { collisions += 1 }
                }
                try (Data(contentsOf: f.relationships[0]) + Data("\n ".utf8)).write(to: f.relationships[0])
                return preview
            }
        }
        #expect(observedPreview == value)
        #expect(collisions == f.photos.count)
        // No leaked reservation after the callback and final witness refusal.
        for photo in f.photos { let lease = try MCPProcessReservation.acquirePhoto(photo); lease.release() }
    }
    @Test("Each exact carrier revision invalidates preparation and retained inspection", arguments: ["source", "wav", "relationship", "xmp", "draft"])
    func carrierDrift(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let plans = MCPVoiceTranscriptionPlanStore()
        let value = try plans.prepare(arguments: f.arguments, facade: f.facade)
        switch kind {
        case "source": try Data("changed source".utf8).write(to: f.photos[0])
        case "wav": try Data("changed wav".utf8).write(to: f.memos[0])
        case "relationship":
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.relationships[0])) as? [String: Any])
            object["profileIdentifier"] = "different-profile"
            try JSONSerialization.data(withJSONObject: object).write(to: f.relationships[0])
        case "xmp": try Data("changed xmp".utf8).write(to: f.photos[0].deletingPathExtension().appendingPathExtension("xmp"))
        default:
            let dir = f.root.appendingPathComponent(".photo_metadata"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "sourceFile": f.photos[0].lastPathComponent, "pendingChanges": true, "metadata": ["caption": "changed"]]).write(to: dir.appendingPathComponent("\(f.photos[0].lastPathComponent).meta.json"))
        }
        #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.stalePlan) { try plans.prepare(arguments: f.arguments, facade: f.facade) }
        #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.stalePlan) { try plans.inspect(arguments: planArguments(value), facade: f.facade) }
    }
    @Test("Authorization revoke, change and regrant invalidate exact intent", arguments: ["disable", "team", "regrant"])
    func authorityDrift(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let plans = MCPVoiceTranscriptionPlanStore(), value = try plans.prepare(arguments: f.arguments, facade: f.facade)
        switch kind {
        case "disable": try f.store.setEnabled(false)
        case "team": var config = try f.store.load(); config.allowsTeamCreation = true; try f.store.save(config)
        default: try f.store.setEnabled(false); try f.store.setEnabled(true)
        }
        #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.authorityChanged) { try plans.inspect(arguments: planArguments(value), facade: f.facade) }
    }
    @Test("Expiry and rollback reject before filesystem admission", arguments: [-1.0, 300.0, 301.0])
    func expires(offset: Double) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let now = Date(), plans = MCPVoiceTranscriptionPlanStore()
        let value = try plans.prepare(arguments: f.arguments, facade: f.facade, now: now)
        #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.expiredPlan) { try plans.inspect(arguments: planArguments(value), facade: f.facade, now: now.addingTimeInterval(offset)) }
    }
    @Test("Independent stores enforce durable count and byte capacity without evicting a live plan")
    func capacity() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = MCPVoiceTranscriptionPlanStore(maximumPlans: 1, storageDirectory: f.storage)
        let value = try first.prepare(arguments: f.arguments, facade: f.facade)
        let second = MCPVoiceTranscriptionPlanStore(maximumPlans: 1, storageDirectory: f.storage)
        #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.capacity) { try second.prepare(arguments: f.arguments, facade: f.facade) }
        #expect(try second.inspect(arguments: planArguments(value), facade: f.facade) == value)
        #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.capacity) { try MCPVoiceTranscriptionPlanStore(maximumBytes: 1).prepare(arguments: f.arguments, facade: f.facade) }
    }
    @Test("Malformed, future and checksum-valid unknown archives remain unchanged", arguments: ["corrupt", "future", "unknown-config", "unknown-input", "false-consent"])
    func invalidArchive(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let plans = MCPVoiceTranscriptionPlanStore(storageDirectory: f.storage), value = try plans.prepare(arguments: f.arguments, facade: f.facade)
        let url = f.storage.appendingPathComponent("plans.json")
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        if kind == "corrupt" { envelope["sha256"] = "wrong" }
        else {
            var archive = try #require(JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!) as? [String: Any])
            if kind == "future" { archive["schemaVersion"] = 2 }
            else {
                var records = archive["records"] as! [String: [String: Any]], id = value.objectValue!["planID"]!.stringValue!
                var record = records[id]!
                if kind == "unknown-config" { var configuration = record["configuration"] as! [String: Any]; configuration["futureAuthority"] = true; record["configuration"] = configuration }
                else { var preview = record["preview"] as! [String: Any], inputs = preview["photos"] as! [[String: Any]]; inputs[0][kind == "unknown-input" ? "futureCarrier" : "consentGranted"] = true; preview["photos"] = inputs; record["preview"] = preview }
                records[id] = record; archive["records"] = records
            }
            let payload = try JSONSerialization.data(withJSONObject: archive)
            envelope["payload"] = payload.base64EncodedString(); envelope["sha256"] = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        }
        let damaged = try JSONSerialization.data(withJSONObject: envelope); try damaged.write(to: url)
        let restored = MCPVoiceTranscriptionPlanStore(storageDirectory: f.storage)
        #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.invalidStorage) { try restored.inspect(arguments: planArguments(value), facade: f.facade) }
        #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.invalidStorage) { try restored.prepare(arguments: f.arguments, facade: f.facade) }
        #expect(try Data(contentsOf: url) == damaged)
    }
    @Test("Strict arguments reject unknown options, duplicate ownership and unsafe paths", arguments: ["unknown", "provider", "locale", "apple-gpu", "model", "bool", "duplicate", "empty", "too-many", "traversal", "bad-token"])
    func invalidRequest(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var args = f.arguments
        switch kind {
        case "unknown": args["timeoutSeconds"] = .integer(300)
        case "provider": args["provider"] = .string("automatic")
        case "locale": args["language"] = .string("en-US")
        case "apple-gpu": args["provider"] = .string("appleSpeech"); args["language"] = .string("en-US")
        case "model": args["modelPath"] = .string("/tmp/model.bin")
        case "bool": args["translate"] = .integer(1)
        case "empty": args["photos"] = .array([])
        case "too-many": if case .array(let items) = args["photos"] { args["photos"] = .array(Array(repeating: items[0], count: 9)) }
        default:
            if case .array(var items) = args["photos"] {
                if kind == "duplicate" { items[1] = items[0] }
                else { var photo = items[0].objectValue!; photo[kind == "traversal" ? "path" : "audioRevision"] = .string(kind == "traversal" ? "/tmp/../frame.jpg" : "bad"); items[0] = .object(photo) }
                args["photos"] = .array(items)
            }
        }
        #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.invalidArguments) { try MCPVoiceTranscriptionPlanStore.Request(arguments: args) }
    }
    @Test("Missing association refuses intent and replacement inspection arguments cannot be supplied")
    func missing() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let plans = MCPVoiceTranscriptionPlanStore(), value = try plans.prepare(arguments: f.arguments, facade: f.facade)
        var args = try planArguments(value); args["provider"] = .string("appleSpeech")
        #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.invalidArguments) { try plans.inspect(arguments: args, facade: f.facade) }
        try FileManager.default.removeItem(at: f.relationships[0])
        #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.missingAssociation) { try plans.prepare(arguments: f.arguments, facade: f.facade) }
    }
    @Test("Every lease is held together and relationship/WAV/authority changes during publication refuse results", arguments: ["none", "wav", "relationship", "authority"])
    func leaseRetention(change: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var admitted = false
        do {
            _ = try f.facade.withVoiceMemoBatch(paths: f.photos.map(\.path)) { inputs in
                admitted = true
                for photo in f.photos { #expect(throws: MCPProcessReservationError.busy) { try MCPProcessReservation.acquirePhoto(photo) } }
                #expect(inputs.count == 2)
                if change == "wav" { try Data("changed".utf8).write(to: f.memos[0]) }
                if change == "relationship" { try Data("changed".utf8).write(to: f.relationships[0]) }
                if change == "authority" { try f.store.setEnabled(false) }
                return true
            }
            #expect(change == "none")
        } catch { #expect(change != "none") }
        #expect(admitted)
        for photo in f.photos { let lease = try MCPProcessReservation.acquirePhoto(photo); lease.release() }
    }
    @Test("Requested reverse order survives sorted lease acquisition")
    func requestedOrder() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var arguments = f.arguments
        if case .array(let photos) = arguments["photos"] { arguments["photos"] = .array(Array(photos.reversed())) }
        let plans = MCPVoiceTranscriptionPlanStore()
        let result = try plans.prepare(arguments: arguments, facade: f.facade)
        guard case .array(let photos) = result.objectValue?["photos"] else { Issue.record("Missing ordered previews"); return }
        let expectedPaths = try f.photos.reversed().map { try f.store.authorizeExistingPath($0.path).url.path }
        #expect(photos.map { $0.objectValue?["canonicalPath"]?.stringValue } == expectedPaths.map(Optional.some))
        #expect(try plans.inspect(arguments: planArguments(result), facade: f.facade) == result)
    }
    @Test("Explicit Apple and custom Whisper options remain unresolved immutable intent", arguments: ["appleSpeech", "customWhisper"])
    func providerRoundtrip(provider: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var arguments = f.arguments
        arguments["provider"] = .string(provider); arguments["language"] = .string(provider == "appleSpeech" ? "nb-NO" : "en")
        arguments["translate"] = .bool(provider != "appleSpeech"); arguments["useGPU"] = .bool(provider != "appleSpeech")
        let plans = MCPVoiceTranscriptionPlanStore(storageDirectory: f.storage)
        let result = try plans.prepare(arguments: arguments, facade: f.facade)
        #expect(result.objectValue?["options"] == .object(arguments.filter { $0.key != "photos" }))
        #expect(result.objectValue?["providerReadiness"] == .string("unknown-application-session-required"))
        #expect(result.objectValue?["executionAvailable"] == .bool(false))
        #expect(try MCPVoiceTranscriptionPlanStore(storageDirectory: f.storage).inspect(arguments: planArguments(result), facade: f.facade) == result)
    }
    @Test("Distinct photos may share a WAV while same-stem metadata ownership refuses admission")
    func sharedWAVAndOwnership() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "profileIdentifier": "custom-reviewed-profile", "imageFilename": f.photos[1].lastPathComponent, "memoFilename": f.memos[0].lastPathComponent]).write(to: f.relationships[1])
        var arguments = f.arguments
        arguments["photos"] = .array(try f.photos.map { photo in
            var input = try #require(f.facade.inspectPhotoVoiceMemo(path: photo.path).objectValue).filter { MCPVoiceTranscriptionPlanStore.Request.photoKeys.contains($0.key) }
            input["path"] = .string(photo.path); return .object(input)
        })
        let plans = MCPVoiceTranscriptionPlanStore(), result = try plans.prepare(arguments: arguments, facade: f.facade)
        guard case .array(let items) = result.objectValue?["photos"] else { Issue.record("Missing previews"); return }
        #expect(items[0].objectValue?["audioIdentity"] == items[1].objectValue?["audioIdentity"])
        #expect(try plans.inspect(arguments: planArguments(result), facade: f.facade) == result)
        let sibling = f.photos[0].deletingPathExtension().appendingPathExtension("nef")
        try Data("raw source".utf8).write(to: sibling)
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "profileIdentifier": "custom-reviewed-profile", "imageFilename": sibling.lastPathComponent, "memoFilename": f.memos[0].lastPathComponent]).write(to: f.root.appendingPathComponent(".\(sibling.lastPathComponent).voice-memo.json"))
        arguments["photos"] = .array(try [f.photos[0], sibling].map { photo in
            var input = try #require(f.facade.inspectPhotoVoiceMemo(path: photo.path).objectValue).filter { MCPVoiceTranscriptionPlanStore.Request.photoKeys.contains($0.key) }
            input["path"] = .string(photo.path); return .object(input)
        })
        #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.invalidArguments) { try plans.prepare(arguments: arguments, facade: f.facade) }
    }
    nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }
    @Test("Changing the first WAV during a later capture refuses the whole set and releases all leases")
    func earlierInputChangesDuringLaterCapture() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let counter = Counter(), memo = f.memos[0]
        let facade = MCPAutomationFacade(authorizationStore: f.store, onVoiceMemoCaptureCheckpoint: {
            if counter.next() == 2 { try? Data("changed during later capture".utf8).write(to: memo) }
        })
        let plans = MCPVoiceTranscriptionPlanStore(storageDirectory: f.storage)
        #expect(throws: MCPAutomationReadError.photoChanged) { try plans.prepare(arguments: f.arguments, facade: facade) }
        #expect(!FileManager.default.fileExists(atPath: f.storage.path))
        for photo in f.photos { let lease = try MCPProcessReservation.acquirePhoto(photo); lease.release() }
    }

}
