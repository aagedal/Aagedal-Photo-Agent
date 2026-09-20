import CryptoKit
import Foundation

/// Immutable, bounded read-only plans. Optional disk storage survives helper restarts, but
/// neither persistence nor successful revalidation grants mutation/publication authority.
nonisolated final class MCPIPTCPatchPlanStore: @unchecked Sendable {
    enum Failure: String, LocalizedError {
        case invalidArguments = "invalid_arguments"
        case unknownPlan = "unknown_patch_plan"
        case expiredPlan = "expired_patch_plan"
        case authorityChanged = "patch_plan_authority_changed"
        case stalePlan = "stale_patch_plan"
        case capacity = "patch_plan_capacity"
        case storageUnavailable = "patch_plan_storage_unavailable"
        case invalidStorage = "invalid_patch_plan_storage"

        var errorDescription: String? {
            switch self {
            case .storageUnavailable: "Patch-plan storage is unavailable. No plan was published."
            case .invalidStorage: "Patch-plan storage is invalid or uses an unsupported schema. No plan was restored."
            case .invalidArguments: "Provide only the exact planID returned by prepare_iptc_patch."
            case .unknownPlan: "This plan is unavailable in this patch-plan store. Prepare a new patch."
            case .expiredPlan: "The patch plan has expired. Prepare a new patch."
            case .authorityChanged: "Local automation authorization changed after preparation. Prepare a new patch."
            case .stalePlan: "The effective metadata or carrier revisions changed after preparation. Prepare a new patch."
            case .capacity: "This helper session has reached its live patch-plan limit. Wait for plans to expire."
            }
        }
    }

    private struct Plan: Sendable {
        let request: MCPIPTCPatchPreparation.Request
        let preview: MCPJSONValue
        let result: MCPJSONValue
        let configuration: MCPAuthorizationConfiguration
        let createdAt: Date
        let expiresAt: Date
        let byteCount: Int
    }

    private struct Record: Codable {
        let arguments: [String: MCPJSONValue]
        let preview: MCPJSONValue
        let configuration: MCPAuthorizationConfiguration
        let createdAt: Date
    }
    private struct Archive: Codable {
        let schemaVersion: Int
        let records: [String: Record]
    }
    private struct Envelope: Codable {
        let payload: Data
        let sha256: String
    }

    static let lifetime: TimeInterval = 300
    private let lock = NSLock()
    private var plans: [String: Plan] = [:]
    private let storage: MCPIPTCPatchPlanPersistence?
    private let maximumPlans: Int
    private let maximumBytes: Int

    init(maximumPlans: Int = 64, maximumBytes: Int = 8 * 1_024 * 1_024, storageDirectory: URL? = nil) {
        let boundedBytes = min(max(0, maximumBytes), 8 * 1_024 * 1_024)
        self.storage = storageDirectory.map { MCPIPTCPatchPlanPersistence(directory: $0, maximumBytes: boundedBytes * 4 + 65_536) }
        self.maximumPlans = min(max(0, maximumPlans), 64)
        self.maximumBytes = boundedBytes
    }

    func retain(request: MCPIPTCPatchPreparation.Request, preview: MCPJSONValue,
                configuration: MCPAuthorizationConfiguration, createdAt: Date) throws -> MCPJSONValue {
        guard configuration.isEnabled, var value = preview.objectValue,
              value["previewOnly"] == .bool(true), value["commitAvailable"] == .bool(false),
              let rootID = value["rootID"]?.stringValue,
              configuration.roots.contains(where: { $0.id.uuidString.lowercased() == rootID }) else {
            throw Failure.authorityChanged
        }
        let id = UUID().uuidString.lowercased()
        value["planID"] = .string(id)
        value["planStorage"] = .string(storage == nil ? "helper-session-memory" : "local-durable-read-only")
        value["planAuthority"] = .string("read-only-preview; no approval or commit authority")
        let result = MCPJSONValue.object(value)
        let bytes = try JSONEncoder().encode(result).count
        guard bytes <= MCPServerConstants.maximumToolResultBytes else { throw MCPIPTCPatchPreparation.Failure.outputLimit }
        // Use the published second-resolution deadline, so expiry cannot outlive the returned time.
        guard let expiry = value["expiresAt"]?.stringValue.flatMap({ ISO8601DateFormatter().date(from: $0) }),
              expiry > createdAt, expiry <= createdAt.addingTimeInterval(Self.lifetime) else {
            throw Failure.invalidArguments
        }
        guard Date() < expiry else { throw Failure.expiredPlan }
        lock.lock()
        defer { lock.unlock() }
        return try transaction {
            // Preparations can finish out of order: an older capture must not evict a newer
            // live plan. Clock rollback is checked against each plan at lookup instead.
            plans = plans.filter { $0.value.expiresAt > createdAt }
            guard plans.count < maximumPlans, bytes <= maximumBytes - plans.values.reduce(0, { $0 + $1.byteCount }) else {
                throw Failure.capacity
            }
            plans[id] = Plan(request: request, preview: preview, result: result, configuration: configuration,
                             createdAt: createdAt, expiresAt: expiry, byteCount: bytes)
            return result
        }
    }

    /// Re-read under the normal retained snapshot admission. Never accept replacement values,
    /// revisions, paths or authority supplied alongside the opaque plan ID.
    func inspect(arguments: [String: MCPJSONValue], facade: MCPAutomationFacade, now: Date = Date()) throws -> MCPJSONValue {
        guard Set(arguments.keys) == ["planID"], let id = arguments["planID"]?.stringValue,
              let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else {
            throw Failure.invalidArguments
        }
        let plan = try lookup(id: id, now: now)
        guard try facade.authorizationStore.load() == plan.configuration else { throw Failure.authorityChanged }
        let current = try facade.withPhotoSnapshot(path: plan.request.path) { snapshot in
            do {
                try MCPIPTCPatchPreparation.checkRevisions(plan.request, source: snapshot.sourceRevision,
                    xmp: snapshot.xmpSidecarRevision, app: snapshot.appSidecarRevision)
                let metadata = try MCPMetadataSnapshotReader.read(snapshot).protocolValue()
                return try MCPIPTCPatchPreparation.preview(request: plan.request, metadata: metadata, now: plan.createdAt)
            } catch is MCPIPTCPatchPreparation.Failure {
                throw Failure.stalePlan
            }
        }
        guard current == plan.preview else { throw Failure.stalePlan }
        guard try facade.authorizationStore.load() == plan.configuration else { throw Failure.authorityChanged }
        // Production wall clock can pass the deadline while a large photo is being decoded.
        _ = try lookup(id: id, now: max(now, Date()))
        return plan.result
    }

    private func lookup(id: String, now: Date) throws -> Plan {
        lock.lock()
        defer { lock.unlock() }
        return try transaction(readOnly: true) {
            guard let plan = plans[id] else { throw Failure.unknownPlan }
            guard now >= plan.createdAt, now < plan.expiresAt else {
                plans.removeValue(forKey: id)
                throw Failure.expiredPlan
            }
            return plan
        }
    }

    /// The persistence lock spans reload, budget admission and atomic replacement across helpers.
    private func transaction<T>(readOnly: Bool = false, _ body: () throws -> T) throws -> T {
        guard let storage else { return try body() }
        return try storage.transaction(readOnly: readOnly) { data in
            if let data { plans = try decode(data) } else { plans = [:] }
            let result = try body()
            if readOnly { return (result, data ?? Data()) }
            let records = plans.mapValues { plan in
                var arguments = plan.request.revisions
                arguments["path"] = .string(plan.request.path)
                arguments["operations"] = .array(plan.request.operations.map { operation in
                    var value: [String: MCPJSONValue] = ["field": .string(operation.field), "operation": .string(operation.kind)]
                    if operation.kind == "set" { value["value"] = operation.after }
                    return .object(value)
                })
                return Record(arguments: arguments, preview: plan.preview, configuration: plan.configuration, createdAt: plan.createdAt)
            }
            let payload = try JSONEncoder().encode(Archive(schemaVersion: 1, records: records))
            let encoded = try JSONEncoder().encode(Envelope(payload: payload, sha256: Self.digest(payload)))
            return (result, encoded)
        }
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Codable intentionally tolerates unknown authorization fields elsewhere. A persisted plan
    /// must refuse them before rewriting, so future authority semantics cannot be silently lost.
    private static func hasKnownAuthorizationShape(_ value: Any?) -> Bool {
        guard let configuration = value as? [String: Any],
              Set(configuration.keys).isSubset(of: ["schemaVersion", "authorizationRevision", "isEnabled", "roots"]),
              Set(["schemaVersion", "isEnabled", "roots"]).isSubset(of: Set(configuration.keys)),
              let roots = configuration["roots"] as? [[String: Any]] else { return false }
        return roots.allSatisfy { root in
            guard Set(root.keys).isSubset(of: ["id", "displayName", "canonicalPath", "identity", "bookmarkData"]),
                  Set(["id", "displayName", "canonicalPath", "identity"]).isSubset(of: Set(root.keys)),
                  let identity = root["identity"] as? [String: Any] else { return false }
            return Set(identity.keys) == ["device", "inode"]
        }
    }

    private func decode(_ data: Data) throws -> [String: Plan] {
        do {
            guard let envelopeObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(envelopeObject.keys) == ["payload", "sha256"] else { throw Failure.invalidStorage }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.sha256 == Self.digest(envelope.payload) else { throw Failure.invalidStorage }
            guard let archiveObject = try JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any],
                  Set(archiveObject.keys) == ["schemaVersion", "records"],
                  let recordObjects = archiveObject["records"] as? [String: [String: Any]],
                  recordObjects.values.allSatisfy({
                      Set($0.keys) == ["arguments", "preview", "configuration", "createdAt"]
                          && Self.hasKnownAuthorizationShape($0["configuration"])
                  }) else {
                throw Failure.invalidStorage
            }
            let archive = try JSONDecoder().decode(Archive.self, from: envelope.payload)
            guard archive.schemaVersion == 1, archive.records.count <= maximumPlans else { throw Failure.invalidStorage }
            var restored: [String: Plan] = [:]
            var totalBytes = 0
            for (id, record) in archive.records {
                guard UUID(uuidString: id)?.uuidString.lowercased() == id,
                      record.configuration.schemaVersion == MCPAuthorizationConfiguration.schemaVersion,
                      record.configuration.isEnabled,
                      var value = record.preview.objectValue,
                      value["previewOnly"] == .bool(true), value["commitAvailable"] == .bool(false),
                      value["planID"] == nil,
                      let rootID = value["rootID"]?.stringValue,
                      record.configuration.roots.contains(where: { $0.id.uuidString.lowercased() == rootID }),
                      let expiry = value["expiresAt"]?.stringValue.flatMap({ ISO8601DateFormatter().date(from: $0) }),
                      expiry > record.createdAt, expiry <= record.createdAt.addingTimeInterval(Self.lifetime) else { throw Failure.invalidStorage }
                let request = try MCPIPTCPatchPreparation.Request(arguments: record.arguments)
                value["planID"] = .string(id)
                value["planStorage"] = .string("local-durable-read-only")
                value["planAuthority"] = .string("read-only-preview; no approval or commit authority")
                let result = MCPJSONValue.object(value)
                let bytes = try JSONEncoder().encode(result).count
                guard bytes <= MCPServerConstants.maximumToolResultBytes, bytes <= maximumBytes - totalBytes else { throw Failure.invalidStorage }
                totalBytes += bytes
                restored[id] = Plan(request: request, preview: record.preview, result: result,
                    configuration: record.configuration, createdAt: record.createdAt, expiresAt: expiry, byteCount: bytes)
            }
            return restored
        } catch { throw Failure.invalidStorage }
    }
}
