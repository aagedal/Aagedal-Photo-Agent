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
    func inspectXMPCandidate(planID: String) async throws -> MCPIPTCPatchXMPPreflightService.Report
    func reviewXMPPublication(_ report: MCPIPTCPatchXMPPreflightService.Report) async throws -> MCPIPTCPatchXMPPublicationApprovalStore.Review
    func approveXMPPublication(_ review: MCPIPTCPatchXMPPublicationApprovalStore.Review,
        acknowledgesC2PA: Bool, acknowledgesPendingDraft: Bool) async throws -> MCPIPTCPatchXMPPublicationApprovalStore.Approval
    func publishXMP(_ receipt: MCPIPTCPatchXMPPublicationApprovalStore.Approval) async throws -> AutomationOperationRegistry.Record
    func revokeXMPPublication(_ receipt: MCPIPTCPatchXMPPublicationApprovalStore.Approval) async
    func approve(_ review: AutomationPatchReview) async throws -> MCPIPTCPatchApprovalStore.Approval
    func revoke(_ receipt: MCPIPTCPatchApprovalStore.Approval) async
    func applyToPendingDraft(_ receipt: MCPIPTCPatchApprovalStore.Approval) async throws -> AutomationOperationRegistry.Record
}

actor AutomationPatchReviewService: AutomationPatchReviewServing {
    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.automation-patch-review", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }

    private let publicationApprovals: MCPIPTCPatchXMPPublicationApprovalStore
    private let approvals: MCPIPTCPatchApprovalStore
    private let facade: MCPAutomationFacade
    private let plans: MCPIPTCPatchPlanStore
    private let recoveryDirectory: URL?
    private let publicationHooks: MCPIPTCPatchXMPPublicationAdmissionService.Hooks
    private let operationRegistry: AutomationOperationRegistry?
    private var executionCoordinator: AutomationOperationExecutionCoordinator?

    init(plans: MCPIPTCPatchPlanStore? = nil, facade: MCPAutomationFacade = .init(),
         operationRegistry: AutomationOperationRegistry? = nil, recoveryDirectory: URL? = nil,
         publicationHooks: MCPIPTCPatchXMPPublicationAdmissionService.Hooks = .init()) {
        let plans = plans ?? MCPIPTCPatchPlanStore(storageDirectory:
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/Aagedal Photo Agent/Automation/PatchPlans", isDirectory: true))
        self.plans = plans
        self.operationRegistry = operationRegistry
        self.recoveryDirectory = recoveryDirectory
        self.publicationHooks = publicationHooks
        self.approvals = MCPIPTCPatchApprovalStore(plans: plans)
        self.publicationApprovals = MCPIPTCPatchXMPPublicationApprovalStore(plans: plans)
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

    func inspectXMPCandidate(planID: String) async throws -> MCPIPTCPatchXMPPreflightService.Report {
        try await MCPIPTCPatchXMPPreflightService(plans: plans, facade: facade).inspect(planID: planID)
    }

    func reviewXMPPublication(_ report: MCPIPTCPatchXMPPreflightService.Report) throws -> MCPIPTCPatchXMPPublicationApprovalStore.Review {
        try Task.checkCancellation()
        return try publicationApprovals.review(report, mode: .xmpSidecar, facade: facade)
    }

    func approveXMPPublication(_ review: MCPIPTCPatchXMPPublicationApprovalStore.Review,
        acknowledgesC2PA: Bool, acknowledgesPendingDraft: Bool) throws -> MCPIPTCPatchXMPPublicationApprovalStore.Approval {
        try Task.checkCancellation()
        let receipt = try publicationApprovals.approve(review,
            acknowledgesC2PAConsequences: acknowledgesC2PA,
            acknowledgesPendingDraftPromotion: acknowledgesPendingDraft, facade: facade)
        do {
            try Task.checkCancellation()
            return receipt
        } catch {
            publicationApprovals.revoke(receipt)
            throw error
        }
    }

    /// Explicit native consent is the only entry point; helper clients cannot publish.
    func publishXMP(_ receipt: MCPIPTCPatchXMPPublicationApprovalStore.Approval) async throws -> AutomationOperationRegistry.Record {
        try Task.checkCancellation()
        let directory = try recoveryDirectory ?? AutomationOperationRegistry.defaultStorageDirectory()
        let registry = operationRegistry ?? AutomationOperationRegistry(storageDirectory: directory)
        let coordinator: AutomationOperationExecutionCoordinator
        if let existing = executionCoordinator { coordinator = existing }
        else {
            coordinator = AutomationOperationExecutionCoordinator(registry: registry)
            executionCoordinator = coordinator
        }
        let executor = MCPIPTCPatchXMPPublicationAdmissionService(plans: plans,
            approvals: publicationApprovals, recovery: .init(directory: directory),
            facade: facade, hooks: publicationHooks)
        let accepted = try await coordinator.submit(kind: .iptcPatch) { context in
            let result = await executor.publish(receipt, context: context)
            switch result.outcome {
            case .verified: return .verified
            case .refused: return .failed
            case .uncertain: return .recoveryRequired
            case .cancelled:
                _ = try registry.requestCancellation(context.operationID)
                return .cancelled
            }
        }
        return try await withTaskCancellationHandler {
            try await coordinator.waitForCompletion(accepted.id)
        } onCancel: {
            Task.detached(priority: .utility) { _ = try? registry.requestCancellation(accepted.id) }
        }
    }

    func revokeXMPPublication(_ receipt: MCPIPTCPatchXMPPublicationApprovalStore.Approval) {
        publicationApprovals.revoke(receipt)
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

    /// The retained operation outlives a dismissed Settings panel. Cancellation requests
    /// are checked before saving; an already saved draft is still verified to completion.
    func applyToPendingDraft(_ receipt: MCPIPTCPatchApprovalStore.Approval) async throws -> AutomationOperationRegistry.Record {
        try Task.checkCancellation()
        let registry = try operationRegistry ?? AutomationOperationRegistry(
            storageDirectory: AutomationOperationRegistry.defaultStorageDirectory())
        let coordinator: AutomationOperationExecutionCoordinator
        if let existing = executionCoordinator { coordinator = existing }
        else {
            coordinator = AutomationOperationExecutionCoordinator(registry: registry)
            executionCoordinator = coordinator
        }
        let executor = MCPIPTCPatchExecutionService(plans: plans, approvals: approvals, facade: facade)
        let accepted = try await coordinator.submit(kind: .iptcDraft) { context in
            let result = await executor.applyToPendingDraft(receipt, context: context)
            switch result.outcome {
            case .draftSaved: return .verified
            case .refused: return .failed
            case .uncertain: return .recoveryRequired
            case .cancelled:
                _ = try registry.requestCancellation(context.operationID)
                return .cancelled
            }
        }
        return try await withTaskCancellationHandler {
            try await coordinator.waitForCompletion(accepted.id)
        } onCancel: {
            Task.detached(priority: .utility) { _ = try? registry.requestCancellation(accepted.id) }
        }
    }
}

@MainActor @Observable
final class AutomationPatchReviewModel {
    var planID = "" { didSet { if planID != oldValue { clear() } } }
    private(set) var review: AutomationPatchReview?
    private(set) var message: String?
    private(set) var isLoading = false
    private(set) var isApproved = false
    private(set) var isXMPPublicationApproved = false
    private(set) var xmpPublicationReview: MCPIPTCPatchXMPPublicationApprovalStore.Review?
    var acknowledgesC2PA = false {
        didSet { if oldValue != acknowledgesC2PA { revokePublicationApproval() } }
    }
    var acknowledgesPendingDraft = false {
        didSet { if oldValue != acknowledgesPendingDraft { revokePublicationApproval() } }
    }
    var canApproveXMPPublication: Bool {
        guard let xmpPublicationReview else { return false }
        return acknowledgesC2PA && (!xmpPublicationReview.report.publicationBinding.promotesPendingDraft || acknowledgesPendingDraft)
            && !isLoading && !isApplying && !isExpired && !isXMPPublicationApproved && applicationResult == nil
    }
    private var publicationApproval: MCPIPTCPatchXMPPublicationApprovalStore.Approval?
    private(set) var isExpired = false
    private(set) var isApplying = false
    private(set) var xmpPreflight: MCPIPTCPatchXMPPreflightService.Report?
    private(set) var applicationResult: AutomationOperationRegistry.Record?
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
        if let receipt = publicationApproval {
            let service = service
            Task { await service.revokeXMPPublication(receipt) }
        }
        if let receipt = approval {
            let service = service
            Task { await service.revoke(receipt) }
        }
    }

    func clear() {
        revokeApproval()
        review = nil
        xmpPreflight = nil
        xmpPublicationReview = nil
        applicationResult = nil
        isApplying = false
        isExpired = false
        message = nil
        isLoading = false
    }

    func revokePublicationApproval() {
        // Also invalidate an approval already in flight when an acknowledgement changes.
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
        isXMPPublicationApproved = false
        if let receipt = publicationApproval {
            publicationApproval = nil
            Task { [service] in await service.revokeXMPPublication(receipt) }
        }
    }

    func revokeApproval() {
        revokePublicationApproval()
        acknowledgesC2PA = false
        acknowledgesPendingDraft = false
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
        guard let review, !isExpired, !isApplying, applicationResult == nil, now >= review.expiresAt else { return }
        revokeApproval()
        isExpired = true
        xmpPublicationReview = nil
        xmpPreflight = nil
        message = "This plan has expired. Prepare a new patch in your client."
    }

    /// A dry run grants no consent. Replace prior evidence, and reject a result that
    /// completes after navigation, expiry, cancellation or a different plan inspection.
    func inspectXMPCandidate() {
        guard let review, !isLoading, !isApplying, !isExpired, applicationResult == nil else { return }
        guard now() < review.expiresAt else { expireReview(at: now()); return }
        revokeApproval()
        xmpPreflight = nil
        xmpPublicationReview = nil
        message = nil
        isLoading = true
        let expected = generation
        task = Task { [weak self, service] in
            do {
                let result = try await service.inspectXMPCandidate(planID: review.planID)
                let publicationReview = try await service.reviewXMPPublication(result)
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                guard self.now() < review.expiresAt else { self.expireReview(at: self.now()); return }
                guard result.planID == review.planID else { throw MCPIPTCPatchPlanStore.Failure.invalidStorage }
                self.xmpPublicationReview = publicationReview
                self.xmpPreflight = result
                self.isLoading = false
                self.task = nil
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.clear()
                self.message = error.localizedDescription
            }
        }
    }

    func approveReviewedPlan() {
        guard let review, !isLoading, !isApplying, applicationResult == nil, !isApproved, !isExpired else { return }
        guard now() < review.expiresAt else { expireReview(at: now()); return }
        revokeApproval()
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


    func approveReviewedXMPPublication() {
        guard canApproveXMPPublication, let publicationReview = xmpPublicationReview,
              let review else { return }
        guard now() < review.expiresAt else { expireReview(at: now()); return }
        let c2pa = acknowledgesC2PA
        let pending = acknowledgesPendingDraft
        revokeApproval()
        acknowledgesC2PA = c2pa
        acknowledgesPendingDraft = pending
        message = nil
        isLoading = true
        let expected = generation
        task = Task { [weak self, service] in
            do {
                let receipt = try await service.approveXMPPublication(publicationReview,
                    acknowledgesC2PA: c2pa, acknowledgesPendingDraft: pending)
                guard let self, self.generation == expected, !Task.isCancelled else {
                    await service.revokeXMPPublication(receipt)
                    return
                }
                guard self.now() < receipt.expiresAt else {
                    await service.revokeXMPPublication(receipt)
                    guard self.generation == expected, !Task.isCancelled else { return }
                    self.expireReview(at: self.now())
                    return
                }
                self.publicationApproval = receipt
                self.isXMPPublicationApproved = true
                self.isLoading = false
                self.task = nil
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.clear()
                self.message = "XMP publication approval could not be confirmed. Inspect a fresh plan and verify its XMP candidate again."
            }
        }
    }

    func publishApprovedXMP() {
        guard let receipt = publicationApproval, let review, isXMPPublicationApproved,
              !isLoading, !isApplying, applicationResult == nil, !isExpired else { return }
        guard now() < review.expiresAt else { expireReview(at: now()); return }
        isApplying = true
        isLoading = true
        message = nil
        let expected = generation
        task = Task { [weak self, service] in
            do {
                let result = try await service.publishXMP(receipt)
                if result.outcome == .verified || result.outcome == .recoveryRequired {
                    NotificationCenter.default.post(name: .automationDraftDidChange,
                        object: URL(fileURLWithPath: review.path))
                }
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.publicationApproval = nil
                self.isXMPPublicationApproved = false
                self.xmpPublicationReview = nil
                self.xmpPreflight = nil
                self.isLoading = false
                self.isApplying = false
                self.applicationResult = result
                self.task = nil
            } catch {
                await service.revokeXMPPublication(receipt)
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.publicationApproval = nil
                self.isXMPPublicationApproved = false
                self.isLoading = false
                self.isApplying = false
                self.message = "XMP publication could not be confirmed. Inspect retained operation history and recovery before preparing another plan."
                self.task = nil
            }
        }
    }

    func applyApprovedPlanToPendingDraft() {
        guard let receipt = approval, let review, !isLoading, !isApplying,
              applicationResult == nil, !isExpired else { return }
        guard now() < review.expiresAt else { expireReview(at: now()); return }
        isApplying = true
        xmpPublicationReview = nil
        xmpPreflight = nil
        isLoading = true
        message = nil
        let expected = generation
        task = Task { [weak self, service] in
            do {
                let result = try await service.applyToPendingDraft(receipt)
                if result.outcome == .verified {
                    NotificationCenter.default.post(name: .automationDraftDidChange,
                        object: URL(fileURLWithPath: review.path))
                }
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.approval = nil
                self.isApproved = false
                self.isLoading = false
                self.isApplying = false
                self.applicationResult = result
                self.task = nil
            } catch {
                await service.revoke(receipt)
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.approval = nil
                self.isApproved = false
                self.isLoading = false
                self.isApplying = false
                self.message = "Draft application could not be confirmed. Inspect the photo's pending metadata and operation status before retrying."
                self.task = nil
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

extension Notification.Name {
    static let automationDraftDidChange = Notification.Name("automationDraftDidChange")
}
