import Foundation

/// Stable UI failures for workflow Activity. These deliberately carry no underlying error text,
/// paths, filenames, hashes, destination facts, or editorial values.
nonisolated enum DeliveryWorkflowActivityError: Error, Equatable, LocalizedError, Sendable {
    case catalogUnavailable
    case resumeUnavailable
    case workflowBusy
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .catalogUnavailable:
            "Saved delivery workflows are unavailable."
        case .resumeUnavailable:
            "This delivery no longer has verified retained staging available to resume."
        case .workflowBusy:
            "This delivery is currently executing."
        case .cleanupFailed:
            "The saved delivery workflow could not be removed."
        }
    }
}

/// The complete workflow shape permitted to cross into Activity UI or UI-state serialization.
/// The registry's private plan and resume record must never be stored on this value.
nonisolated struct DeliveryWorkflowActivitySummary: Codable, Equatable, Identifiable, Sendable {
    let workflowIdentifier: UUID
    let stage: DeliveryWorkflowStage
    let completedItemCount: Int
    let itemCount: Int
    let hasRetainedStaging: Bool
    let failureCode: DeliveryWorkflowFailureCode?

    var id: UUID { workflowIdentifier }

    var canResume: Bool {
        hasRetainedStaging && stage != .sent
    }

    var stageTitle: String {
        switch stage {
        case .queued: "Queued"
        case .staging: "Staging"
        case .writing: "Writing metadata"
        case .verifying: "Verifying metadata"
        case .preservationVerifying: "Verifying preservation"
        case .uploading: "Uploading"
        case .remoteConfirming: "Confirming remote file"
        case .recordingReceipt: "Recording receipt"
        case .sent: "Sent"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var failureTitle: String? {
        guard let failureCode else { return nil }
        return switch failureCode {
        case .invalidPlan: "Invalid frozen plan"
        case .profileDrift: "Profile changed"
        case .manifestPersistenceFailed: "Progress recording failed"
        case .stagingEvidencePersistenceFailed: "Staging evidence recording failed"
        case .stagingRefused: "Staging refused"
        case .stagingFailed: "Staging failed"
        case .uploadRefused: "Upload refused"
        case .uploadFailed: "Upload failed"
        case .receiptAssemblyFailed: "Receipt creation failed"
        case .receiptPersistenceFailed: "Receipt recording failed"
        case .resumeEvidenceMismatch: "Retained evidence mismatch"
        }
    }

    init(_ summary: DeliveryWorkflowRegistrySummary) {
        workflowIdentifier = summary.workflowIdentifier
        stage = summary.stage
        completedItemCount = summary.completedItemCount
        itemCount = summary.itemCount
        hasRetainedStaging = summary.hasRetainedStaging
        failureCode = summary.failureCode
    }
}

@MainActor
struct DeliveryWorkflowActivityDependencies {
    let catalog: () async throws -> DeliveryWorkflowRegistryCatalog
    let validateResume: (UUID) async throws -> Void
    let releaseResume: (UUID) async -> Void
    let removeWorkflow: (UUID) async throws -> Void
    let protectedWorkflowIdentifier: () -> UUID?

    static func production(session: DeadlineDeliveryProductionSession) -> Self {
        Self(
            catalog: { try await session.workflowCatalog() },
            validateResume: { try await session.validateResume(workflowIdentifier: $0) },
            releaseResume: { session.releaseResumeReservation(for: $0) },
            removeWorkflow: { try await session.removeWorkflow($0) },
            protectedWorkflowIdentifier: { session.protectedWorkflowIdentifier }
        )
    }
}

/// Reloadable, privacy-safe Activity projection for retained delivery workflows.
/// Any invalid/corrupt/newer-schema registry entry fails the entire projection closed.
@MainActor
@Observable
final class DeliveryWorkflowActivityModel {
    private(set) var workflows: [DeliveryWorkflowActivitySummary] = []
    private(set) var isLoaded = false
    private(set) var isReloading = false
    private(set) var resumingWorkflowIdentifier: UUID?
    private(set) var removingWorkflowIdentifier: UUID?
    var error: DeliveryWorkflowActivityError?

    @ObservationIgnored private let dependencies: DeliveryWorkflowActivityDependencies

    init(dependencies: DeliveryWorkflowActivityDependencies) {
        self.dependencies = dependencies
    }

    func reload() async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }
        do {
            let catalog = try await dependencies.catalog()
            workflows = catalog.workflows.map(DeliveryWorkflowActivitySummary.init)
            isLoaded = true
            error = nil
        } catch {
            // A partial catalog could misidentify which workflow is safe to resume or remove.
            workflows = []
            isLoaded = true
            self.error = .catalogUnavailable
        }
    }

    func isActivelyExecuting(_ workflowIdentifier: UUID) -> Bool {
        dependencies.protectedWorkflowIdentifier() == workflowIdentifier
    }

    func isBusy(_ workflowIdentifier: UUID) -> Bool {
        isActivelyExecuting(workflowIdentifier)
            || resumingWorkflowIdentifier == workflowIdentifier
            || removingWorkflowIdentifier == workflowIdentifier
    }

    /// Validates the exact selected UUID against private retained evidence. The resulting plan is
    /// intentionally not returned through or retained by this Activity model.
    func requestResume(_ workflowIdentifier: UUID) async -> Bool {
        guard resumingWorkflowIdentifier == nil,
              removingWorkflowIdentifier == nil,
              dependencies.protectedWorkflowIdentifier() == nil,
              workflows.first(where: { $0.id == workflowIdentifier })?.canResume == true else {
            error = dependencies.protectedWorkflowIdentifier() != nil
                ? .workflowBusy
                : .resumeUnavailable
            return false
        }
        resumingWorkflowIdentifier = workflowIdentifier
        defer { resumingWorkflowIdentifier = nil }
        do {
            try await dependencies.validateResume(workflowIdentifier)
            guard dependencies.protectedWorkflowIdentifier() == workflowIdentifier else {
                error = .workflowBusy
                await dependencies.releaseResume(workflowIdentifier)
                return false
            }
            error = nil
            return true
        } catch {
            self.error = .resumeUnavailable
            await reload()
            return false
        }
    }

    func abandonResume(_ workflowIdentifier: UUID) async {
        await dependencies.releaseResume(workflowIdentifier)
    }

    /// Deletes only after the view has collected an explicit confirmation for this exact UUID.
    /// Staging is otherwise retained indefinitely; no load or lifecycle path calls this method.
    func removeConfirmedWorkflow(_ workflowIdentifier: UUID) async -> Bool {
        guard removingWorkflowIdentifier == nil,
              resumingWorkflowIdentifier == nil,
              workflows.contains(where: { $0.id == workflowIdentifier }) else {
            error = .cleanupFailed
            return false
        }
        guard !isActivelyExecuting(workflowIdentifier) else {
            error = .workflowBusy
            return false
        }
        removingWorkflowIdentifier = workflowIdentifier
        defer { removingWorkflowIdentifier = nil }
        do {
            try await dependencies.removeWorkflow(workflowIdentifier)
            workflows.removeAll { $0.id == workflowIdentifier }
            error = nil
            return true
        } catch {
            self.error = dependencies.protectedWorkflowIdentifier() == workflowIdentifier
                ? .workflowBusy
                : .cleanupFailed
            return false
        }
    }
}
