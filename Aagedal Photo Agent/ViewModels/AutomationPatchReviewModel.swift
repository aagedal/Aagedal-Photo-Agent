import Foundation
import Observation

/// A presentation of one exact inspected plan. All text remains untrusted plain text.
nonisolated struct AutomationPatchReview: Sendable {
    struct Change: Identifiable, Sendable {
        let id: String
        let operation: String
        let before: String
        let after: String
    }
    fileprivate var approvalReview: MCPIPTCPatchApprovalStore.Review?
    let planID: String
    let path: String
    let expiresAt: Date
    let changes: [Change]
    let warnings: [String]

    init(_ preview: MCPJSONValue) throws {
        guard let value = preview.objectValue,
              let planID = value["planID"]?.stringValue,
              UUID(uuidString: planID)?.uuidString.lowercased() == planID,
              value["previewOnly"] == .bool(true), value["commitAvailable"] == .bool(false),
              let path = value["canonicalPath"]?.stringValue,
              let expiry = value["expiresAt"]?.stringValue,
              let date = ISO8601DateFormatter().date(from: expiry),
              case .array(let changes) = value["changes"], !changes.isEmpty,
              case .array(let warnings) = value["preservationWarnings"],
              let validation = value["validation"]?.objectValue,
              case .array(let issues) = validation["issues"] else {
            throw MCPIPTCPatchPlanStore.Failure.invalidStorage
        }
        func text(_ value: MCPJSONValue?) throws -> String {
            switch value {
            case .string(let text): return text
            case .null: return ""
            case .array(let items):
                guard items.allSatisfy({ $0.stringValue != nil }) else {
                    throw MCPIPTCPatchPlanStore.Failure.invalidStorage
                }
                // JSON quoting preserves boundaries, including embedded newlines and commas.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                return String(decoding: try encoder.encode(items), as: UTF8.self)
            default: throw MCPIPTCPatchPlanStore.Failure.invalidStorage
            }
        }
        var seen = Set<String>()
        self.changes = try changes.map { change in
            guard let object = change.objectValue,
                  let field = object["field"]?.stringValue,
                  MCPIPTCPatchPreparation.supportedFields.contains(field), seen.insert(field).inserted,
                  let operation = object["operation"]?.stringValue, ["set", "clear"].contains(operation) else {
                throw MCPIPTCPatchPlanStore.Failure.invalidStorage
            }
            return Change(id: field, operation: operation,
                          before: try text(object["before"]), after: try text(object["after"]))
        }
        self.warnings = try warnings.map { warning in
            guard let text = warning.stringValue else { throw MCPIPTCPatchPlanStore.Failure.invalidStorage }
            return text
        } + issues.map { issue in
            guard let object = issue.objectValue, let message = object["message"]?.stringValue,
                  let field = object["field"]?.stringValue else { throw MCPIPTCPatchPlanStore.Failure.invalidStorage }
            return "\(field): \(message)"
        }
        self.planID = planID
        self.path = path
        self.expiresAt = date
    }
}

nonisolated protocol AutomationPatchReviewServing: Sendable {
    func inspect(planID: String) async throws -> AutomationPatchReview
    func approve(_ review: AutomationPatchReview) async throws -> MCPIPTCPatchApprovalStore.Approval
    func revoke(_ receipt: MCPIPTCPatchApprovalStore.Approval) async
}

actor AutomationPatchReviewService: AutomationPatchReviewServing {
    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.automation-patch-review", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }

    private let approvals: MCPIPTCPatchApprovalStore
    private let facade: MCPAutomationFacade

    init(plans: MCPIPTCPatchPlanStore? = nil, facade: MCPAutomationFacade = .init()) {
        let plans = plans ?? MCPIPTCPatchPlanStore(storageDirectory:
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/Aagedal Photo Agent/Automation/PatchPlans", isDirectory: true))
        self.approvals = MCPIPTCPatchApprovalStore(plans: plans)
        self.facade = facade
    }

    func inspect(planID: String) throws -> AutomationPatchReview {
        try Task.checkCancellation()
        let binding = try approvals.review(planID: planID, facade: facade)
        try Task.checkCancellation()
        var review = try AutomationPatchReview(binding.preview)
        review.approvalReview = binding
        return review
    }

    func approve(_ review: AutomationPatchReview) throws -> MCPIPTCPatchApprovalStore.Approval {
        try Task.checkCancellation()
        guard let binding = review.approvalReview else {
            throw MCPIPTCPatchApprovalStore.Failure.invalidReview
        }
        let receipt = try approvals.approve(binding, facade: facade)
        do {
            try Task.checkCancellation()
            return receipt
        } catch {
            approvals.revoke(receipt)
            throw error
        }
    }

    func revoke(_ receipt: MCPIPTCPatchApprovalStore.Approval) {
        approvals.revoke(receipt)
    }
}

@MainActor @Observable
final class AutomationPatchReviewModel {
    var planID = "" { didSet { if planID != oldValue { clear() } } }
    private(set) var review: AutomationPatchReview?
    private(set) var message: String?
    private(set) var isLoading = false
    private(set) var isApproved = false
    private(set) var isExpired = false
    private var approval: MCPIPTCPatchApprovalStore.Approval?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let service: any AutomationPatchReviewServing
    private let now: @MainActor () -> Date

    init(service: (any AutomationPatchReviewServing)? = nil,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
        if let service { self.service = service; return }
        do {
            self.service = try UITestPatchReviewFixture.currentServiceForModel() ?? AutomationPatchReviewService()
        } catch {
            // A requested test fixture must never fall back to the user's plan archive.
            preconditionFailure("Could not prepare the isolated patch review UI fixture.")
        }
    }

    isolated deinit {
        task?.cancel()
        if let receipt = approval {
            let service = service
            Task { await service.revoke(receipt) }
        }
    }

    func clear() {
        revokeApproval()
        review = nil
        isExpired = false
        message = nil
        isLoading = false
    }

    func revokeApproval() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
        isApproved = false
        if let receipt = approval {
            approval = nil
            Task { [service] in await service.revoke(receipt) }
        }
    }

    /// Called by the presentation clock; explicit time also makes deadline behavior deterministic.
    func expireReview(at now: Date) {
        guard let review, !isExpired, now >= review.expiresAt else { return }
        revokeApproval()
        isExpired = true
        message = "This plan has expired. Prepare a new patch in your client."
    }

    func approveReviewedPlan() {
        guard let review, !isLoading, !isApproved, !isExpired else { return }
        guard now() < review.expiresAt else { expireReview(at: now()); return }
        message = nil
        isLoading = true
        let expected = generation
        task = Task { [weak self, service] in
            do {
                let receipt = try await service.approve(review)
                guard let self, self.generation == expected, !Task.isCancelled else {
                    // Consent may finish while the user clears, navigates away or changes IDs.
                    await service.revoke(receipt)
                    return
                }
                guard self.now() < receipt.expiresAt else {
                    await service.revoke(receipt)
                    guard self.generation == expected, !Task.isCancelled else { return }
                    self.expireReview(at: self.now())
                    return
                }
                self.approval = receipt
                self.isApproved = true
                self.isLoading = false
                self.task = nil
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.clear()
                self.message = error.localizedDescription
            }
        }
    }

    func inspect() {
        clear()
        let id = planID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else {
            message = "Enter the exact plan ID returned by prepare_iptc_patch."
            return
        }
        isLoading = true
        let expected = generation
        task = Task { [weak self, service] in
            do {
                let result = try await service.inspect(planID: id)
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.review = result
                self.isLoading = false
                self.task = nil
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.message = error.localizedDescription
                self.isLoading = false
                self.task = nil
            }
        }
    }
}
