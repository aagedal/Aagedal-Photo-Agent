import Foundation

/// Native-app-only, process-lifetime consent for an exact immutable patch plan. There is no
/// Codable representation or MCP approval endpoint. Validation is evidence for a future retained
/// write executor, not a write capability: that executor must revalidate inside its mutation gate.
nonisolated final class MCPIPTCPatchApprovalStore: @unchecked Sendable {
    enum Failure: String, LocalizedError {
        case invalidReview = "invalid_patch_review"
        case changedReview = "changed_patch_review"
        case unavailableApproval = "unavailable_patch_approval"
        case expiredApproval = "expired_patch_approval"
        case capacity = "patch_approval_capacity"

        var errorDescription: String? {
            switch self {
            case .invalidReview: "Open a fresh local patch review before approving."
            case .changedReview: "The reviewed patch or its authorization changed. Review a new plan."
            case .unavailableApproval: "This local approval is unavailable or revoked. Review the patch again."
            case .expiredApproval: "This local approval expired. Prepare and review a new patch."
            case .capacity: "Too many local patch approvals are active. Revoke an approval or wait for expiry."
            }
        }
    }

    struct Review: Sendable {
        let planID: String
        let preview: MCPJSONValue
        let expiresAt: Date
        fileprivate let digest: String
        fileprivate let generation: UUID
    }

    struct Approval: Sendable, Equatable {
        let id: UUID
        let planID: String
        let expiresAt: Date
        fileprivate let approvedAt: Date
        fileprivate let digest: String
        fileprivate let generation: UUID
    }

    private let plans: MCPIPTCPatchPlanStore
    private let lock = NSLock()
    private var generation = UUID()
    private var approvals: [UUID: Approval] = [:]
    private let maximumApprovals: Int

    init(plans: MCPIPTCPatchPlanStore, maximumApprovals: Int = 64) {
        self.plans = plans
        self.maximumApprovals = min(max(0, maximumApprovals), 64)
    }

    /// Present this immutable preview in native UI. Merely opening it records no consent.
    func review(planID: String, facade: MCPAutomationFacade, now: Date = Date()) throws -> Review {
        lock.lock()
        defer { lock.unlock() }
        let binding = try plans.localApprovalBinding(planID: planID, facade: facade, now: now)
        return Review(planID: planID, preview: binding.preview, expiresAt: binding.expiresAt,
                      digest: binding.digest, generation: generation)
    }

    /// Call only from an explicit local user action on the presented Review. Accepts no edited
    /// values, replacement paths, remote boolean confirmation or client-supplied approval token.
    func approve(_ review: Review, facade: MCPAutomationFacade, now: Date = Date()) throws -> Approval {
        lock.lock()
        defer { lock.unlock() }
        guard review.generation == generation else { throw Failure.invalidReview }
        let binding = try plans.localApprovalBinding(planID: review.planID, facade: facade, now: now)
        guard binding.digest == review.digest, binding.preview == review.preview else { throw Failure.changedReview }
        let checkedAt = max(now, Date())
        guard checkedAt < review.expiresAt else { throw Failure.expiredApproval }
        approvals = approvals.filter { $0.value.expiresAt > checkedAt && $0.value.approvedAt <= checkedAt }
        // Reapproving the same exact plan replaces its prior receipt rather than accumulating grants.
        approvals = approvals.filter { $0.value.planID != review.planID }
        guard approvals.count < maximumApprovals else { throw Failure.capacity }
        let approval = Approval(id: UUID(), planID: review.planID, expiresAt: review.expiresAt,
            approvedAt: checkedAt, digest: binding.digest, generation: generation)
        approvals[approval.id] = approval
        return approval
    }

    /// Any observed drift permanently revokes this receipt, even if a later edit restores the
    /// original metadata. A successful check never extends the immutable plan's deadline.
    func validate(_ approval: Approval, facade: MCPAutomationFacade, now: Date = Date()) throws -> MCPJSONValue {
        lock.lock()
        defer { lock.unlock() }
        guard approval.generation == generation, approvals[approval.id] == approval else {
            throw Failure.unavailableApproval
        }
        do {
            let checkedAt = max(now, Date())
            guard now >= approval.approvedAt, checkedAt < approval.expiresAt else { throw Failure.expiredApproval }
            let binding = try plans.localApprovalBinding(planID: approval.planID, facade: facade, now: now)
            guard binding.digest == approval.digest else { throw Failure.changedReview }
            return binding.preview
        } catch {
            approvals.removeValue(forKey: approval.id)
            throw error
        }
    }

    func revoke(_ approval: Approval) {
        lock.lock()
        defer { lock.unlock() }
        approvals.removeValue(forKey: approval.id)
    }

    /// Also invalidates every open review, e.g. when native automation settings close or change.
    func revokeAll() {
        lock.lock()
        defer { lock.unlock() }
        approvals.removeAll()
        generation = UUID()
    }
}
