import CryptoKit
import Foundation

/// Native-only, process-lifetime consent for one verified XMP sidecar candidate. Draft
/// approvals are a different type and cannot enter this store. There is deliberately no
/// installer, Codable receipt or MCP endpoint; validation grants no write. Native admission
/// can consume a receipt exactly once while retaining the matching photo reservation.
nonisolated final class MCPIPTCPatchXMPPublicationApprovalStore: @unchecked Sendable {
    enum Mode: Sendable, Equatable { case xmpSidecar }
    enum Failure: Error, Equatable {
        case changedReview, missingAcknowledgement, unavailableApproval, expiredApproval, capacity
    }

    struct Review: Sendable {
        let report: MCPIPTCPatchXMPPreflightService.Report
        let mode: Mode
        let preview: MCPJSONValue
        /// These consequences must be shown even if the source contains no detected C2PA.
        let consequences: [String]
        fileprivate let generation: UUID
    }

    struct Approval: Sendable, Equatable {
        let id: UUID
        let planID: String
        let mode: Mode
        let targetPath: String
        let stagedSHA256: String
        let stagedByteCount: Int
        let expiresAt: Date
        let promotesPendingDraft: Bool
        fileprivate let planDigest: String
        fileprivate let approvedAt: Date
        fileprivate let generation: UUID
    }

    private let plans: MCPIPTCPatchPlanStore
    private let lock = NSLock()
    private let maximumApprovals: Int
    private var generation = UUID()
    private var approvals: [UUID: Approval] = [:]

    init(plans: MCPIPTCPatchPlanStore, maximumApprovals: Int = 64) {
        self.plans = plans
        self.maximumApprovals = min(max(0, maximumApprovals), 64)
    }

    func review(_ report: MCPIPTCPatchXMPPreflightService.Report, mode: Mode,
                facade: MCPAutomationFacade, now: Date = Date()) throws -> Review {
        lock.lock()
        defer { lock.unlock() }
        let binding = try plans.localApprovalBinding(planID: report.planID, facade: facade, now: now)
        guard binding.digest == report.publicationBinding.planDigest,
              binding.expiresAt == report.publicationBinding.expiresAt else { throw Failure.changedReview }
        var consequences = [
            "Publication changes the physical XMP sidecar. It does not publish embedded metadata.",
            "C2PA properties were checked for preservation, but C2PA trust has not been validated. Publication may affect provenance validity or downstream trust.",
            "Parsed property preservation does not prove arbitrary XML extension preservation."
        ]
        if report.publicationBinding.promotesPendingDraft {
            consequences.append("Publication promotes every effective pending draft value, including changes outside this patch.")
        }
        return Review(report: report, mode: mode, preview: binding.preview,
            consequences: consequences, generation: generation)
    }

    /// Invoke only from an explicit native action after presenting the immutable review.
    /// A remote confirmation boolean or a draft approval must never call this method.
    func approve(_ review: Review, acknowledgesC2PAConsequences: Bool,
                 acknowledgesPendingDraftPromotion: Bool, facade: MCPAutomationFacade,
                 now: Date = Date()) throws -> Approval {
        lock.lock()
        defer { lock.unlock() }
        guard review.generation == generation else { throw Failure.unavailableApproval }
        guard acknowledgesC2PAConsequences,
              !review.report.publicationBinding.promotesPendingDraft || acknowledgesPendingDraftPromotion else {
            throw Failure.missingAcknowledgement
        }
        let report = review.report
        let binding = try plans.localApprovalBinding(planID: report.planID, facade: facade, now: now)
        guard binding.digest == report.publicationBinding.planDigest, binding.preview == review.preview,
              binding.expiresAt == report.publicationBinding.expiresAt else { throw Failure.changedReview }
        let checkedAt = max(now, Date())
        guard checkedAt < binding.expiresAt else { throw Failure.expiredApproval }
        approvals = approvals.filter { $0.value.expiresAt > checkedAt && $0.value.approvedAt <= checkedAt }
        let otherApprovals = approvals.filter { $0.value.planID != report.planID }
        guard otherApprovals.count < maximumApprovals else { throw Failure.capacity }
        let approval = Approval(id: UUID(), planID: report.planID, mode: review.mode,
            targetPath: report.targetPath, stagedSHA256: report.stagedSHA256,
            stagedByteCount: report.stagedByteCount, expiresAt: binding.expiresAt,
            promotesPendingDraft: report.publicationBinding.promotesPendingDraft,
            planDigest: binding.digest, approvedAt: checkedAt, generation: generation)
        approvals = otherApprovals
        approvals[approval.id] = approval
        return approval
    }

    /// Requires the exact restaged bytes and retained photo reservation. Drift permanently
    /// revokes consent. Native admission sets `consumeForPublication` only after establishing
    /// durable recovery; removal and exact-candidate validation share the same lock.
    func validate(_ approval: Approval, candidate: Data, mode: Mode, targetPath: String,
                  facade: MCPAutomationFacade, reservation: MCPProcessReservationLease,
                  now: Date = Date(), consumeForPublication: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        guard approval.generation == generation, approvals[approval.id] == approval else {
            throw Failure.unavailableApproval
        }
        do {
            guard now >= approval.approvedAt, max(now, Date()) < approval.expiresAt else {
                throw Failure.expiredApproval
            }
            guard mode == approval.mode, targetPath == approval.targetPath,
                  candidate.count == approval.stagedByteCount,
                  SHA256.hash(data: candidate).map({ String(format: "%02x", $0) }).joined() == approval.stagedSHA256 else {
                throw Failure.changedReview
            }
            let binding = try plans.localApprovalBinding(planID: approval.planID, facade: facade,
                now: now, reservation: reservation)
            guard binding.digest == approval.planDigest else { throw Failure.changedReview }
            if consumeForPublication { approvals.removeValue(forKey: approval.id) }
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

    func revokeAll() {
        lock.lock()
        defer { lock.unlock() }
        approvals.removeAll()
        generation = UUID()
    }
}
