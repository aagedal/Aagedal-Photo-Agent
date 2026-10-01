import CryptoKit
import Foundation

/// Immutable intent preview only. Checksums detect corruption, never authenticate consent.
/// Every snapshot is revalidated with the whole photo set retained before publication.
nonisolated final class MCPVoiceTranscriptionPlanStore: @unchecked Sendable {
    enum Failure: String, LocalizedError {
        case invalidArguments = "invalid_arguments"
        case unknownPlan = "unknown_voice_transcription_plan"
        case expiredPlan = "expired_voice_transcription_plan"
        case authorityChanged = "voice_transcription_authority_changed"
        case stalePlan = "stale_voice_transcription_plan"
        case missingAssociation = "voice_transcription_association_missing"
        case capacity = "voice_transcription_plan_capacity"
        case storageUnavailable = "voice_transcription_storage_unavailable"
        case invalidStorage = "invalid_voice_transcription_storage"
        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Provide only the explicit ordered photo revisions, provider and supported language, translate and useGPU options; inspect with only the returned planID."
            case .unknownPlan: "The transcription preview is unavailable. Prepare a new preview."
            case .expiredPlan: "The transcription preview expired or the clock moved backwards. Prepare a new preview."
            case .authorityChanged: "Local automation authorization changed. Prepare a new preview."
            case .stalePlan: "A retained photo, metadata carrier, relationship or WAV changed. Prepare a new preview."
            case .missingAssociation: "Every photo requires an explicit persisted WAV relationship."
            case .capacity: "The bounded transcription preview store is full. Wait for previews to expire."
            case .storageUnavailable: "Private transcription preview storage is unavailable."
            case .invalidStorage: "Private transcription preview storage is invalid or has an unsupported schema."
            }
        }
    }
    struct Request: Sendable {
        static let keys: Set<String> = ["photos", "provider", "language", "translate", "useGPU"]
        static let photoKeys: Set<String> = ["path", "sourceRevision", "appSidecarRevision", "xmpSidecarRevision", "relationshipRevision", "audioRevision"]
        let arguments: [String: MCPJSONValue]
        let photos: [[String: MCPJSONValue]]
        let paths: [String]
        init(arguments: [String: MCPJSONValue]) throws {
            guard Set(arguments.keys) == Self.keys,
                  case .array(let items) = arguments["photos"], !items.isEmpty, items.count <= 8,
                  let provider = arguments["provider"]?.stringValue, ["appleSpeech", "whisper", "customWhisper"].contains(provider),
                  let language = arguments["language"]?.stringValue,
                  case .bool(let translate) = arguments["translate"], case .bool(let useGPU) = arguments["useGPU"] else { throw Failure.invalidArguments }
            if provider == "appleSpeech" {
                let parts = language.split(separator: "-", omittingEmptySubsequences: false)
                guard language != "auto", language.utf8.count <= 64, !parts.isEmpty,
                      parts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8 && $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) } }),
                      parts[0].utf8.count >= 2, parts[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                      !translate, !useGPU else { throw Failure.invalidArguments }
            } else {
                guard language == "auto" || (language.utf8.count == 2 && language.utf8.allSatisfy({ (97...122).contains($0) })) else { throw Failure.invalidArguments }
            }
            var keys = Set<String>(), photos: [[String: MCPJSONValue]] = [], paths: [String] = []
            for item in items {
                guard let photo = item.objectValue, Set(photo.keys) == Self.photoKeys,
                      let path = photo["path"]?.stringValue, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096,
                      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                      Self.photoKeys.subtracting(["path"]).allSatisfy({ key in
                          guard let token = photo[key]?.stringValue else { return false }
                          return token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                      }), keys.insert(URL(fileURLWithPath: path).standardizedFileURL.deletingPathExtension().path.lowercased()).inserted else { throw Failure.invalidArguments }
                photos.append(photo); paths.append(path)
            }
            self.arguments = arguments; self.photos = photos; self.paths = paths
        }
    }
    private struct Record: Codable {
        let arguments: [String: MCPJSONValue]
        let preview: MCPJSONValue
        let configuration: MCPAuthorizationConfiguration
        let createdAt: Date
        let expiresAt: Date
    }
    private struct Archive: Codable { let schemaVersion: Int; let records: [String: Record] }
    private struct Envelope: Codable { let payload: Data; let sha256: String }
    static let lifetime: TimeInterval = 300
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private let storage: MCPIPTCPatchPlanPersistence?
    private let maximumPlans: Int
    private let maximumBytes: Int

    static func defaultStorageDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Aagedal Photo Agent/Automation/VoiceTranscriptionPlans", isDirectory: true)
    }
    init(maximumPlans: Int = 64, maximumBytes: Int = 8_388_608, storageDirectory: URL? = nil) {
        self.maximumPlans = min(max(0, maximumPlans), 64)
        self.maximumBytes = min(max(0, maximumBytes), 8_388_608)
        storage = storageDirectory.map { MCPIPTCPatchPlanPersistence(directory: $0, maximumBytes: min(max(0, maximumBytes), 8_388_608) * 4 + 65_536) }
    }
    func prepare(arguments: [String: MCPJSONValue], facade: MCPAutomationFacade, now: Date = Date()) throws -> MCPJSONValue {
        let request = try Request(arguments: arguments)
        let configuration = try facade.authorizationStore.load()
        guard configuration.isEnabled else { throw Failure.authorityChanged }
        let result = try facade.withVoiceMemoBatch(paths: request.paths) { inputs in
            try Self.check(request: request, inputs: inputs)
            guard try facade.authorizationStore.load() == configuration else { throw Failure.authorityChanged }
            let expiry = Date(timeIntervalSince1970: floor(now.addingTimeInterval(Self.lifetime).timeIntervalSince1970))
            guard now < expiry, Date() < expiry else { throw Failure.expiredPlan }
            let id = UUID().uuidString.lowercased()
            let preview = Self.preview(request: request, inputs: inputs, id: id, createdAt: now, expiresAt: expiry, durable: storage != nil)
            let record = Record(arguments: arguments, preview: preview, configuration: configuration, createdAt: now, expiresAt: expiry)
            lock.lock(); defer { lock.unlock() }
            let retained = try transaction {
                records = records.filter { $0.value.expiresAt > now }
                guard records.count < maximumPlans else { throw Failure.capacity }
                records[id] = record
                guard try totalBytes(records) <= maximumBytes else { records.removeValue(forKey: id); throw Failure.capacity }
                return preview
            }
            guard Date() < expiry else { throw Failure.expiredPlan }
            return retained
        }
        guard let expiryText = result.objectValue?["expiresAt"]?.stringValue,
              let expiry = ISO8601DateFormatter().date(from: expiryText), Date() < expiry else { throw Failure.expiredPlan }
        return result
    }
    func inspect(arguments: [String: MCPJSONValue], facade: MCPAutomationFacade, now: Date = Date()) throws -> MCPJSONValue {
        guard Set(arguments.keys) == ["planID"], let id = arguments["planID"]?.stringValue,
              UUID(uuidString: id)?.uuidString.lowercased() == id else { throw Failure.invalidArguments }
        return try withValidatedPreview(planID: id, facade: facade, now: now) { $0 }
    }

    /// Retains whole-set rooted reservations and witnesses across private handoff publication.
    /// The callback grants no execution authority and must not mutate photo inputs.
    func withValidatedPreview<Value>(planID id: String, facade: MCPAutomationFacade,
                                     now: Date = Date(), _ body: (MCPJSONValue) throws -> Value) throws -> Value {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw Failure.invalidArguments }
        let record = try lookup(id: id, now: now)
        guard try facade.authorizationStore.load() == record.configuration else { throw Failure.authorityChanged }
        let request = try Request(arguments: record.arguments)
        let result = try facade.withVoiceMemoBatch(paths: request.paths) { inputs in
            try Self.check(request: request, inputs: inputs)
            guard try facade.authorizationStore.load() == record.configuration else { throw Failure.authorityChanged }
            let current = Self.preview(request: request, inputs: inputs, id: id, createdAt: record.createdAt,
                expiresAt: record.expiresAt, durable: storage != nil)
            guard current == record.preview else { throw Failure.stalePlan }
            _ = try lookup(id: id, now: max(now, Date()))
            let value = try body(record.preview)
            _ = try lookup(id: id, now: max(now, Date()))
            return value
        }
        _ = try lookup(id: id, now: max(now, Date()))
        return result
    }
    private static func check(request: Request, inputs: [[String: MCPJSONValue]]) throws {
        guard inputs.count == request.photos.count else { throw Failure.stalePlan }
        for (photo, input) in zip(request.photos, inputs) {
            guard input["associationState"] == .string("available") else { throw Failure.missingAssociation }
            for key in Request.photoKeys.subtracting(["path"]) {
                guard input[key] == photo[key] else { throw Failure.stalePlan }
            }
        }
    }
    private static func preview(request: Request, inputs: [[String: MCPJSONValue]], id: String,
                                createdAt: Date, expiresAt: Date, durable: Bool) -> MCPJSONValue {
        var options = request.arguments; options.removeValue(forKey: "photos")
        return .object([
            "schemaVersion": .integer(1), "planID": .string(id), "previewOnly": .bool(true),
            "commitAvailable": .bool(false), "executionAvailable": .bool(false), "consentGranted": .bool(false),
            "planStorage": .string(durable ? "local-durable-read-only" : "helper-session-memory"),
            "planAuthority": .string("read-only-preview; no consent, execution or draft authority"),
            "createdAt": .string(createdAt.ISO8601Format()), "expiresAt": .string(expiresAt.ISO8601Format()),
            "options": .object(options), "photos": .array(inputs.map(MCPJSONValue.object)), "photoCount": .integer(Int64(inputs.count)),
            "providerReadiness": .string("unknown-application-session-required"),
            "providerModelIdentity": .string("unresolved-application-session-required"),
            "providerExecutableIdentity": .string("unresolved-application-session-required"),
            "warnings": .array([.string("Ordered immutable intent preview only. Native runtime/model selection, readiness, exact execution binding and explicit consent remain unavailable through this helper. No transcription, download or transcript draft is created.")])
        ])
    }
    private func lookup(id: String, now: Date) throws -> Record {
        lock.lock(); defer { lock.unlock() }
        return try transaction(readOnly: true) {
            guard let record = records[id] else { throw Failure.unknownPlan }
            guard now >= record.createdAt, now < record.expiresAt else { throw Failure.expiredPlan }
            return record
        }
    }
    private func totalBytes(_ values: [String: Record]) throws -> Int {
        try values.values.reduce(0) { sum, record in
            let bytes = try JSONEncoder().encode(record.preview).count
            guard bytes <= MCPServerConstants.maximumToolResultBytes else { throw Failure.capacity }
            return sum + bytes
        }
    }
    private func transaction<T>(readOnly: Bool = false, _ body: () throws -> T) throws -> T {
        guard let storage else { return try body() }
        do {
            return try storage.transaction(readOnly: readOnly) { data in
                records = try data.map(decode) ?? [:]
                let result = try body()
                if readOnly { return (result, data ?? Data()) }
                let payload = try JSONEncoder().encode(Archive(schemaVersion: 1, records: records))
                return (result, try JSONEncoder().encode(Envelope(payload: payload, sha256: Self.digest(payload))))
            }
        } catch let error as MCPIPTCPatchPlanStore.Failure {
            switch error { case .capacity: throw Failure.capacity; case .invalidStorage: throw Failure.invalidStorage; default: throw Failure.storageUnavailable }
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func decode(_ data: Data) throws -> [String: Record] {
        do {
            guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(outer.keys) == ["payload", "sha256"] else { throw Failure.invalidStorage }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard Self.digest(envelope.payload) == envelope.sha256,
                  let archiveObject = try JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any],
                  Set(archiveObject.keys) == ["schemaVersion", "records"],
                  let objects = archiveObject["records"] as? [String: [String: Any]],
                  objects.values.allSatisfy({ Set($0.keys) == ["arguments", "preview", "configuration", "createdAt", "expiresAt"] && Self.knownConfiguration($0["configuration"]) }) else { throw Failure.invalidStorage }
            let archive = try JSONDecoder().decode(Archive.self, from: envelope.payload)
            guard archive.schemaVersion == 1, archive.records.count <= maximumPlans else { throw Failure.invalidStorage }
            for (id, record) in archive.records {
                let request = try Request(arguments: record.arguments)
                guard UUID(uuidString: id)?.uuidString.lowercased() == id, record.configuration.schemaVersion == MCPAuthorizationConfiguration.schemaVersion,
                      record.configuration.isEnabled, record.expiresAt > record.createdAt,
                      record.expiresAt <= record.createdAt.addingTimeInterval(Self.lifetime),
                      case .array(let items) = record.preview.objectValue?["photos"], items.count == request.photos.count else { throw Failure.invalidStorage }
                let inputs = try items.enumerated().map { index, item -> [String: MCPJSONValue] in
                    let keys = Request.photoKeys.subtracting(["path"]).union(["canonicalPath", "rootID", "photoIdentity", "audioIdentity", "associationState", "audioByteCount", "historicalPhotoContentMatches", "historicalAudioContentMatches", "audioFormat", "audioContentDecoded", "executionAvailable", "providerReadiness", "consentGranted", "scope"])
                    guard let input = item.objectValue, Set(input.keys) == keys,
                          let rootID = input["rootID"]?.stringValue,
                          record.configuration.roots.contains(where: { $0.id.uuidString.lowercased() == rootID }),
                          input["canonicalPath"] == .string(URL(fileURLWithPath: request.paths[index]).standardizedFileURL.path),
                          ["photoIdentity", "audioIdentity"].allSatisfy({ key in
                              guard let value = input[key]?.stringValue else { return false }
                              return value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                          }), case .integer(let count) = input["audioByteCount"], count >= 0, count <= MCPVoiceMemoAdmission.maximumAudioBytes,
                          input["audioFormat"] == .string("wav-extension"), input["audioContentDecoded"] == .bool(false),
                          input["executionAvailable"] == .bool(false), input["consentGranted"] == .bool(false),
                          input["providerReadiness"] == .string("unavailable-in-helper"), input["scope"] == .string("persisted-relationship-read-only"),
                          ["historicalPhotoContentMatches", "historicalAudioContentMatches"].allSatisfy({ input[$0] == .null || input[$0] == .bool(false) || input[$0] == .bool(true) }) else { throw Failure.invalidStorage }
                    return input
                }
                try Self.check(request: request, inputs: inputs)
                guard record.preview == Self.preview(request: request, inputs: inputs, id: id, createdAt: record.createdAt, expiresAt: record.expiresAt, durable: true) else { throw Failure.invalidStorage }
            }
            guard try totalBytes(archive.records) <= maximumBytes else { throw Failure.invalidStorage }
            return archive.records
        } catch { throw Failure.invalidStorage }
    }
    private static func knownConfiguration(_ value: Any?) -> Bool {
        guard let config = value as? [String: Any],
              Set(config.keys).isSubset(of: ["schemaVersion", "authorizationRevision", "isEnabled", "allowsTeamCreation", "roots"]),
              Set(["schemaVersion", "isEnabled", "roots"]).isSubset(of: Set(config.keys)),
              let roots = config["roots"] as? [[String: Any]] else { return false }
        return roots.allSatisfy { root in
            guard Set(root.keys).isSubset(of: ["id", "displayName", "canonicalPath", "identity", "bookmarkData"]),
                  Set(["id", "displayName", "canonicalPath", "identity"]).isSubset(of: Set(root.keys)),
                  let identity = root["identity"] as? [String: Any] else { return false }
            return Set(identity.keys) == ["device", "inode"]
        }
    }
}
