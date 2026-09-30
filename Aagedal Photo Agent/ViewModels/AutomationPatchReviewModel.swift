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
    func nativeReviewRequests() async throws -> [MCPNativeReviewRequestStore.Record]
    func cancelNativeReviewRequest(_ id: UUID) async throws
    func nativeReviewOperations() async throws -> [AutomationOperationRegistry.Record]
    func inspectNativeReviewRequest(_ id: UUID) async throws -> MCPNativeReviewRequestStore.Record
    func applyToPendingDraft(_ receipt: MCPIPTCPatchApprovalStore.Approval, requestID: UUID?) async throws -> AutomationOperationRegistry.Record
    func publishXMP(_ receipt: MCPIPTCPatchXMPPublicationApprovalStore.Approval, requestID: UUID?) async throws -> AutomationOperationRegistry.Record
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

// Alternate service implementations must explicitly support request binding; a helper
// identifier can never silently fall back to an unrelated manual execution path.
extension AutomationPatchReviewServing {
    func nativeReviewRequests() async throws -> [MCPNativeReviewRequestStore.Record] { [] }
    func nativeReviewOperations() async throws -> [AutomationOperationRegistry.Record] { [] }
    func cancelNativeReviewRequest(_ id: UUID) async throws { throw MCPNativeReviewRequestStore.Failure.unknownRequest }
    func inspectNativeReviewRequest(_ id: UUID) async throws -> MCPNativeReviewRequestStore.Record {
        throw MCPNativeReviewRequestStore.Failure.unknownRequest
    }
    func applyToPendingDraft(_ receipt: MCPIPTCPatchApprovalStore.Approval,
                             requestID: UUID?) async throws -> AutomationOperationRegistry.Record {
        guard requestID == nil else { throw MCPNativeReviewRequestStore.Failure.invalidTransition }
        return try await applyToPendingDraft(receipt)
    }
    func publishXMP(_ receipt: MCPIPTCPatchXMPPublicationApprovalStore.Approval,
                    requestID: UUID?) async throws -> AutomationOperationRegistry.Record {
        guard requestID == nil else { throw MCPNativeReviewRequestStore.Failure.invalidTransition }
        return try await publishXMP(receipt)
    }
}

actor AutomationPatchReviewService: AutomationPatchReviewServing, AutomationRecoveryServing {
    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.automation-patch-review", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }

    private let publicationApprovals: MCPIPTCPatchXMPPublicationApprovalStore
    private let approvals: MCPIPTCPatchApprovalStore
    private let facade: MCPAutomationFacade
    private let plans: MCPIPTCPatchPlanStore
    private let recoveryDirectory: URL?
    private let recoveryHooks: MCPIPTCPatchXMPRecoveryService.Hooks
    private let publicationHooks: MCPIPTCPatchXMPPublicationAdmissionService.Hooks
    private let operationRegistry: AutomationOperationRegistry?
    private let nativeRequests: MCPNativeReviewRequestStore?
    private var executionCoordinator: AutomationOperationExecutionCoordinator?

    init(plans: MCPIPTCPatchPlanStore? = nil, facade: MCPAutomationFacade = .init(),
         operationRegistry: AutomationOperationRegistry? = nil, recoveryDirectory: URL? = nil,
         nativeRequests: MCPNativeReviewRequestStore? = nil,
         publicationHooks: MCPIPTCPatchXMPPublicationAdmissionService.Hooks = .init(),
         recoveryHooks: MCPIPTCPatchXMPRecoveryService.Hooks = .init()) {
        let plans = plans ?? MCPIPTCPatchPlanStore(storageDirectory:
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/Aagedal Photo Agent/Automation/PatchPlans", isDirectory: true))
        self.plans = plans
        self.operationRegistry = operationRegistry
        self.nativeRequests = nativeRequests
        self.recoveryDirectory = recoveryDirectory
        self.publicationHooks = publicationHooks
        self.recoveryHooks = recoveryHooks
        self.approvals = MCPIPTCPatchApprovalStore(plans: plans)
        self.publicationApprovals = MCPIPTCPatchXMPPublicationApprovalStore(plans: plans)
        self.facade = facade
    }

    private func registry() throws -> AutomationOperationRegistry {
        try operationRegistry ?? AutomationOperationRegistry(storageDirectory:
            recoveryDirectory ?? AutomationOperationRegistry.defaultStorageDirectory())
    }

    private func requestStore() throws -> MCPNativeReviewRequestStore {
        try nativeRequests ?? MCPNativeReviewRequestStore(storageDirectory: MCPNativeReviewRequestStore.defaultStorageDirectory())
    }

    func nativeReviewRequests() async throws -> [MCPNativeReviewRequestStore.Record] {
        try Task.checkCancellation()
        guard try facade.authorizationStore.load().isEnabled else { throw MCPAuthorizationError.disabled }
        return try requestStore().records()
    }

    func nativeReviewOperations() async throws -> [AutomationOperationRegistry.Record] {
        try Task.checkCancellation()
        let authorization = try facade.authorizationStore.load()
        guard authorization.isEnabled else { throw MCPAuthorizationError.disabled }
        // Reuse history reconciliation: released owner leases and exact recovery receipts
        // may settle uncertainty; loading a request never proves successful execution.
        let records = try await AutomationOperationHistoryService(registry: registry()).records()
        try Task.checkCancellation()
        guard try facade.authorizationStore.load() == authorization else {
            throw MCPIPTCPatchPlanStore.Failure.authorityChanged
        }
        return records
    }

    func cancelNativeReviewRequest(_ id: UUID) async throws {
        try Task.checkCancellation()
        let authorization = try facade.authorizationStore.load()
        guard authorization.isEnabled else { throw MCPAuthorizationError.disabled }
        func recheckAuthorization() throws {
            try Task.checkCancellation()
            guard try facade.authorizationStore.load() == authorization else {
                throw MCPIPTCPatchPlanStore.Failure.authorityChanged
            }
        }
        let requests = try requestStore()
        let request = try requests.inspect(id)
        if let operationID = request.operationID {
            let registry: AutomationOperationRegistry
            let operation: AutomationOperationRegistry.Record
            do {
                registry = try self.registry()
                operation = try registry.inspect(operationID)
            } catch {
                // Persist intent even when history is missing, corrupt or temporarily
                // locked. The retained executor checks this request at safe boundaries.
                try recheckAuthorization()
                _ = try requests.cancel(id)
                throw error
            }
            let expectedKind: AutomationOperationRegistry.Kind = request.purpose == .pendingDraft ? .iptcDraft : .iptcPatch
            guard operation.kind == expectedKind else { throw MCPNativeReviewRequestStore.Failure.invalidTransition }
            // A terminal operation cannot be stopped again. Do not manufacture a
            // cancellation timestamp on the request after its outcome is confirmed.
            guard !operation.isTerminal else { return }
            try recheckAuthorization()
            _ = try requests.cancel(id)
            try recheckAuthorization()
            _ = try registry.requestCancellation(operationID)
        } else {
            try recheckAuthorization()
            _ = try requests.cancel(id)
        }
    }

    func inspectNativeReviewRequest(_ id: UUID) async throws -> MCPNativeReviewRequestStore.Record {
        try Task.checkCancellation()
        guard try facade.authorizationStore.load().isEnabled else { throw MCPAuthorizationError.disabled }
        let record = try requestStore().inspect(id)
        guard record.state == .awaitingReview else { throw MCPNativeReviewRequestStore.Failure.invalidTransition }
        return record
    }

    private func boundRequest(_ id: UUID?, planID: String,
                              purpose: MCPNativeReviewRequestStore.Purpose) throws -> MCPNativeReviewRequestStore? {
        guard let id else { return nil }
        let store = try requestStore()
        let request = try store.inspect(id)
        guard request.planID == planID, request.purpose == purpose, request.state == .awaitingReview else {
            throw MCPNativeReviewRequestStore.Failure.invalidTransition
        }
        return store
    }

    private nonisolated static func checkRequestCancellation(_ id: UUID?, store: MCPNativeReviewRequestStore?,
        operationID: UUID, registry: AutomationOperationRegistry) throws {
        guard let id, let store else { return }
        let request = try store.inspect(id)
        guard request.state == .linked, request.operationID == operationID else {
            throw MCPNativeReviewRequestStore.Failure.invalidTransition
        }
        if request.cancellationRequestedAt != nil {
            _ = try registry.requestCancellation(operationID)
            throw CancellationError()
        }
    }

    func inspect(planID: String) throws -> AutomationPatchReview {
        try Task.checkCancellation()
        let binding = try approvals.review(planID: planID, facade: facade)
        try Task.checkCancellation()
        var review = try AutomationPatchReview(binding.preview)
        review.approvalReview = binding
        return review
    }

    func inspectRecovery(photoPath: String?) throws -> MCPIPTCPatchXMPRecoveryService.Review? {
        try Task.checkCancellation()
        let directory = try recoveryDirectory ?? AutomationOperationRegistry.defaultStorageDirectory()
        return try MCPIPTCPatchXMPRecoveryService(recovery: .init(directory: directory), facade: facade, hooks: recoveryHooks)
            .inspect(photoPath: photoPath)
    }

    func resolveUnchangedRecovery(_ review: MCPIPTCPatchXMPRecoveryService.Review) async throws {
        try Task.checkCancellation()
        let directory = try recoveryDirectory ?? AutomationOperationRegistry.defaultStorageDirectory()
        try await MCPIPTCPatchXMPRecoveryService(recovery: .init(directory: directory), facade: facade, hooks: recoveryHooks)
            .resolveUnchanged(review)
        do { try await reconcileRecoveryHistory(directory: directory) }
        catch { throw AutomationRecoveryHistoryFailure.unchangedResolutionRecorded }
    }

    func restorePartialPublication(_ review: MCPIPTCPatchXMPRecoveryService.Review) async throws {
        try Task.checkCancellation()
        let directory = try recoveryDirectory ?? AutomationOperationRegistry.defaultStorageDirectory()
        try await MCPIPTCPatchXMPRecoveryService(recovery: .init(directory: directory), facade: facade, hooks: recoveryHooks)
            .restorePartialPublication(review)
        do { try await reconcileRecoveryHistory(directory: directory) }
        catch { throw AutomationRecoveryHistoryFailure.restorationRecorded }
    }

    private func reconcileRecoveryHistory(directory: URL) async throws {
        let registry = try registry()
        // Retry the receipt-to-history handoff before replacing the single retained
        // recovery journal. A failed durable history write leaves that receipt intact.
        try await AutomationOperationHistoryService(registry: registry,
            recovery: .init(directory: directory)).reconcileRecovery()
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
        try await publishXMP(receipt, requestID: nil)
    }

    func publishXMP(_ receipt: MCPIPTCPatchXMPPublicationApprovalStore.Approval, requestID: UUID?) async throws -> AutomationOperationRegistry.Record {
        try Task.checkCancellation()
        let requests = try boundRequest(requestID, planID: receipt.planID, purpose: .xmpPublication)
        let directory = try recoveryDirectory ?? AutomationOperationRegistry.defaultStorageDirectory()
        let registry = try registry()
        try await reconcileRecoveryHistory(directory: directory)
        let coordinator: AutomationOperationExecutionCoordinator
        if let existing = executionCoordinator { coordinator = existing }
        else {
            coordinator = AutomationOperationExecutionCoordinator(registry: registry)
            executionCoordinator = coordinator
        }
        let executor = MCPIPTCPatchXMPPublicationAdmissionService(plans: plans,
            approvals: publicationApprovals, recovery: .init(directory: directory),
            facade: facade, hooks: publicationHooks)
        let accepted: AutomationOperationRegistry.Record
        do {
            accepted = try await coordinator.submit(kind: .iptcPatch, admission: {
                if let requestID, let requests { _ = try requests.admit(requestID) }
            }, didEnqueue: { record in
                if let requestID, let requests { _ = try requests.link(requestID, operationID: record.id) }
            }, cancellationCheck: { operationID in
                try Self.checkRequestCancellation(requestID, store: requests, operationID: operationID, registry: registry)
            }) { context in
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
        } catch {
            if let requestID, let requests { _ = try? requests.markUnknownDisposition(requestID) }
            throw error
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
        try await applyToPendingDraft(receipt, requestID: nil)
    }

    func applyToPendingDraft(_ receipt: MCPIPTCPatchApprovalStore.Approval, requestID: UUID?) async throws -> AutomationOperationRegistry.Record {
        try Task.checkCancellation()
        let requests = try boundRequest(requestID, planID: receipt.planID, purpose: .pendingDraft)
        let registry = try registry()
        let coordinator: AutomationOperationExecutionCoordinator
        if let existing = executionCoordinator { coordinator = existing }
        else {
            coordinator = AutomationOperationExecutionCoordinator(registry: registry)
            executionCoordinator = coordinator
        }
        let executor = MCPIPTCPatchExecutionService(plans: plans, approvals: approvals, facade: facade)
        let accepted: AutomationOperationRegistry.Record
        do {
            accepted = try await coordinator.submit(kind: .iptcDraft, admission: {
                if let requestID, let requests { _ = try requests.admit(requestID) }
            }, didEnqueue: { record in
                if let requestID, let requests { _ = try requests.link(requestID, operationID: record.id) }
            }, cancellationCheck: { operationID in
                try Self.checkRequestCancellation(requestID, store: requests, operationID: operationID, registry: registry)
            }) { context in
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
        } catch {
            if let requestID, let requests { _ = try? requests.markUnknownDisposition(requestID) }
            throw error
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
    private(set) var nativeRequests: [MCPNativeReviewRequestStore.Record] = []
    private(set) var selectedRequest: MCPNativeReviewRequestStore.Record?
    private(set) var nativeRequestOperations: [UUID: AutomationOperationRegistry.Record] = [:]
    private(set) var nativeRequestMessage: String?
    private(set) var isRefreshingNativeRequests = false
    private var nativeRequestTask: Task<Void, Never>?
    private var nativeRequestGeneration = UUID()
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
        nativeRequestTask?.cancel()
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
        nativeRequestGeneration = UUID()
        nativeRequestTask?.cancel()
        nativeRequestTask = nil
        isRefreshingNativeRequests = false
        selectedRequest = nil
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
        guard selectedRequest == nil || selectedRequest?.purpose == .xmpPublication else { return }
        let requestID = selectedRequest?.requestID
        isApplying = true
        isLoading = true
        message = nil
        let expected = generation
        task = Task { [weak self, service] in
            do {
                let result = try await service.publishXMP(receipt, requestID: requestID)
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
                if requestID != nil { self.refreshNativeRequestEvidence() }
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
        guard selectedRequest == nil || selectedRequest?.purpose == .pendingDraft else { return }
        let requestID = selectedRequest?.requestID
        isApplying = true
        xmpPublicationReview = nil
        xmpPreflight = nil
        isLoading = true
        message = nil
        let expected = generation
        task = Task { [weak self, service] in
            do {
                let result = try await service.applyToPendingDraft(receipt, requestID: requestID)
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
                if requestID != nil { self.refreshNativeRequestEvidence() }
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

    /// Explicit refresh still clears idle consent. While an operation is admitted,
    /// only refresh evidence; never cancel its presentation task or lose its request ID.
    func refreshNativeRequests() {
        guard !isRefreshingNativeRequests, !isLoading || isApplying else { return }
        let clearsConsent = !isApplying
        if clearsConsent { clear(); isLoading = true }
        loadNativeRequestEvidence(clearsConsent: clearsConsent)
    }

    /// The request list refreshes independently from review/approval/execution. This
    /// read grants no consent and cannot replace the reviewed snapshot.
    func refreshNativeRequestEvidence() {
        guard !isRefreshingNativeRequests else { return }
        loadNativeRequestEvidence(clearsConsent: false)
    }

    func cancelNativeRequest(_ id: UUID) {
        guard !isRefreshingNativeRequests, !isLoading || isApplying else { return }
        let clearsConsent = !isApplying
        if clearsConsent { clear(); isLoading = true }
        loadNativeRequestEvidence(clearsConsent: clearsConsent, cancelling: id)
    }

    private func loadNativeRequestEvidence(clearsConsent: Bool, cancelling id: UUID? = nil) {
        isRefreshingNativeRequests = true
        nativeRequestMessage = nil
        let expected = nativeRequestGeneration
        nativeRequestTask = Task { [weak self, service] in
            var cancellationFailed = false
            if let id {
                do { try await service.cancelNativeReviewRequest(id) }
                catch { cancellationFailed = true }
            }
            do {
                let requests = try await service.nativeReviewRequests()
                var operations: [AutomationOperationRegistry.Record] = []
                var operationsUnavailable = false
                if requests.contains(where: { $0.operationID != nil }) {
                    do { operations = try await service.nativeReviewOperations() }
                    catch { operationsUnavailable = true }
                }
                guard let self, self.nativeRequestGeneration == expected, !Task.isCancelled else { return }
                self.nativeRequests = requests
                self.nativeRequestOperations = Dictionary(operations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                if let selected = self.selectedRequest,
                   let current = requests.first(where: { $0.requestID == selected.requestID }),
                   current.planID == selected.planID, current.purpose == selected.purpose {
                    self.selectedRequest = current
                }
                if cancellationFailed {
                    self.nativeRequestMessage = "Cancellation could not be confirmed. Refreshed evidence does not establish that work stopped."
                } else if operationsUnavailable {
                    self.nativeRequestMessage = "Operation evidence could not be refreshed. Linked request outcomes are unavailable; inspect retained operation history and recovery."
                }
                self.isRefreshingNativeRequests = false
                if clearsConsent { self.isLoading = false }
                self.nativeRequestTask = nil
            } catch {
                guard let self, self.nativeRequestGeneration == expected, !Task.isCancelled else { return }
                // Old outcome evidence must not appear current after a failed read.
                self.nativeRequestOperations = [:]
                self.nativeRequestMessage = "Review requests could not be refreshed. Displayed requests may be out of date; linked outcomes are unavailable."
                self.isRefreshingNativeRequests = false
                if clearsConsent { self.isLoading = false }
                self.nativeRequestTask = nil
            }
        }
    }

    func operation(for request: MCPNativeReviewRequestStore.Record) -> AutomationOperationRegistry.Record? {
        guard let id = request.operationID, let operation = nativeRequestOperations[id],
              operation.kind == (request.purpose == .pendingDraft ? .iptcDraft : .iptcPatch) else { return nil }
        return operation
    }

    func canCancelNativeRequest(_ request: MCPNativeReviewRequestStore.Record) -> Bool {
        guard request.cancellationRequestedAt == nil else { return false }
        if request.state == .awaitingReview { return true }
        guard request.state == .linked, let id = request.operationID else { return false }
        // Missing evidence cannot prove completion and must not block durable intent.
        // A known wrong-kind link must never target an unrelated activity.
        if let raw = nativeRequestOperations[id],
           raw.kind != (request.purpose == .pendingDraft ? .iptcDraft : .iptcPatch) { return false }
        guard let operation = operation(for: request) else { return true }
        return !operation.isTerminal && operation.cancellationRequestedAt == nil
    }

    func nativeRequestOperationStatus(_ request: MCPNativeReviewRequestStore.Record) -> String {
        guard let operation = operation(for: request) else {
            if request.cancellationRequestedAt != nil {
                return "Cancellation requested; operation confirmation unavailable. Work is not confirmed stopped. Inspect operation history and recovery."
            }
            return "Operation confirmation unavailable. A linked request does not prove completion or success. Inspect operation history and recovery before retrying."
        }
        switch operation.outcome {
        case .verified:
            return request.purpose == .pendingDraft
                ? "Verified: pending draft saved; photo and XMP unchanged."
                : "Verified: XMP published and local metadata history checked."
        case .failed: return "Failed or refused. Inspect retained operation history before retrying."
        case .cancelled: return "Cancelled: cancellation confirmed with no uncertain effects."
        case .stale: return "Stale: prepare and inspect a fresh plan."
        case .partialUncertain, .recoveryRequired:
            if let resolution = operation.recoveryResolution {
                return resolution.disposition == .restored
                    ? "Recovery resolved: original metadata restored. Original publication was not verified."
                    : "Recovery resolved: unchanged staging confirmed. Original publication was not verified."
            }
            return "Recovery required: effects are uncertain. Inspect retained recovery and metadata before retrying."
        case nil:
            if request.cancellationRequestedAt != nil || operation.cancellationRequestedAt != nil {
                return "Cancellation requested; waiting for a confirmed outcome. Work may still finish."
            }
            return operation.state == .queued
                ? "Queued: last recorded as waiting to execute. Current activity is not confirmed."
                : "Running: last recorded as executing. Current activity is not confirmed."
        }
    }

    func inspectNativeRequest(_ id: UUID) {
        guard !isApplying else { return }
        clear()
        isLoading = true
        let expected = generation
        task = Task { [weak self, service] in
            do {
                let request = try await service.inspectNativeReviewRequest(id)
                let result = try await service.inspect(planID: request.planID)
                guard request.state == .awaitingReview, result.planID == request.planID else {
                    throw MCPNativeReviewRequestStore.Failure.invalidTransition
                }
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.planID = request.planID // This clears all prior consent before selection.
                self.selectedRequest = request
                self.review = result
                self.isLoading = false
                self.task = nil
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.message = "This request cannot be reviewed. It may be cancelled, admitted, expired or changed. Refresh requests and inspect retained operation history."
                self.isLoading = false
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
