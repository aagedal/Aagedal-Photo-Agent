import Foundation

/// Immutable, bounded plans retained for the lifetime of one helper session. Retention and
/// successful revalidation grant no mutation/publication authority. Restart intentionally
/// discards plans; durable transactions require a separate verified recovery design.
nonisolated final class MCPIPTCPatchPlanStore: @unchecked Sendable {
    enum Failure: String, LocalizedError {
        case invalidArguments = "invalid_arguments"
        case unknownPlan = "unknown_patch_plan"
        case expiredPlan = "expired_patch_plan"
        case authorityChanged = "patch_plan_authority_changed"
        case stalePlan = "stale_patch_plan"
        case capacity = "patch_plan_capacity"

        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Provide only the exact planID returned by prepare_iptc_patch."
            case .unknownPlan: "This plan is unavailable in this helper session. Prepare a new patch."
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

    static let lifetime: TimeInterval = 300
    private let lock = NSLock()
    private var plans: [String: Plan] = [:]
    private let maximumPlans: Int
    private let maximumBytes: Int

    init(maximumPlans: Int = 64, maximumBytes: Int = 8 * 1_024 * 1_024) {
        self.maximumPlans = maximumPlans
        self.maximumBytes = maximumBytes
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
        value["planStorage"] = .string("helper-session-memory")
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
        guard let plan = plans[id] else { throw Failure.unknownPlan }
        guard now >= plan.createdAt, now < plan.expiresAt else {
            plans.removeValue(forKey: id)
            throw Failure.expiredPlan
        }
        return plan
    }
}
