import Foundation

nonisolated enum KnownPeopleLocalIdentityAssignmentFailure: Error, LocalizedError {
    case attemptInProgress

    var errorDescription: String? {
        "This Known People identity assignment is already running. Wait for its retained result."
    }
}

/// Immutable input and stable IDs. Only read-only preparation can create a plan.
/// The receipt is process-local transaction evidence, not a claim that the installed root
/// remains unchanged after the transaction returns.
nonisolated final class KnownPeopleLocalIdentityAssignmentPlan: Sendable {
    let id: UUID
    let libraryID: UUID
    let installationID: UUID
    let replacementPlan: KnownPeopleManagedStoreReplacementPlan
    fileprivate let receipt = Receipt()

    fileprivate init(libraryID: UUID, installationID: UUID,
                     replacementPlan: KnownPeopleManagedStoreReplacementPlan) {
        id = UUID()
        self.libraryID = libraryID
        self.installationID = installationID
        self.replacementPlan = replacementPlan
    }

    var lastTransactionResult: KnownPeopleManagedStoreReplacementResult? { receipt.lastResult }

    nonisolated fileprivate final class Receipt: @unchecked Sendable {
        enum Admission {
            case admitted, busy
            case committed(KnownPeopleManagedStoreReplacementResult)
        }
        private let lock = NSLock()
        private var running = false
        private var result: KnownPeopleManagedStoreReplacementResult?
        var lastResult: KnownPeopleManagedStoreReplacementResult? { lock.withLock { result } }

        func begin() -> Admission {
            lock.withLock {
                if let result, result.committed { return .committed(result) }
                guard !running else { return .busy }
                running = true
                return .admitted
            }
        }
        func finish(_ value: KnownPeopleManagedStoreReplacementResult) {
            lock.withLock { result = value; running = false }
        }
    }
}

nonisolated struct KnownPeopleLocalIdentityAssignmentResult: Sendable {
    let transaction: KnownPeopleManagedStoreReplacementResult
    /// True means no new filesystem transaction ran: the original committed receipt is
    /// returned, including any readback/durability uncertainty and its retained backup.
    let returnedCommittedReceipt: Bool
}

nonisolated struct KnownPeopleLocalIdentityAssignmentAccess: Sendable {
    var capture = KnownPeopleLocalStoreSnapshotAccess()
    var afterCapture: @Sendable () throws -> Void = {}
    var beforeReplacementPlan: @Sendable () throws -> Void = {}
}

/// Explicit first-time identity assignment for an already-resolved local store. Preparation
/// performs no migration or writes. Commit reuses the service owner's route lease, import
/// lane, complete-root reservation, exact inventory checks, and atomic managed replacement.
actor KnownPeopleLocalIdentityAssignment {
    private let access: KnownPeopleLocalIdentityAssignmentAccess
    init(access: KnownPeopleLocalIdentityAssignmentAccess = .init()) { self.access = access }

    func prepare(route: KnownPeopleManagedStoreRoute, exportedAt: String,
                 exporter: KnownPeoplePackageManifest.Exporter) async throws -> KnownPeopleLocalIdentityAssignmentPlan {
        try Task.checkCancellation()
        let replacement = KnownPeopleManagedStoreReplacement()
        let initial = try await replacement.inventory(route: route)
        let libraryID = UUID(), installationID = UUID()
        let captured = try await KnownPeopleLocalStoreSnapshotBuilder(access: access.capture).captureUntracked(
            rootURL: route.rootURL, libraryID: libraryID, exportedAt: exportedAt, exporter: exporter)
        try access.afterCapture()
        guard captured.managedInventorySHA256 == initial.inventorySHA256,
              try await replacement.inventory(route: route) == initial else {
            throw KnownPeopleManagedStoreFailure.staleInventory
        }
        try access.beforeReplacementPlan()
        let planned = try await replacement.plan(snapshot: captured.snapshot, route: route,
                                                  initialInstallationID: installationID)
        guard planned.priorState == nil, planned.requiredDecision == .replaceUntracked,
              planned.inventory == initial,
              captured.inventory.device == initial.rootIdentity.device,
              captured.inventory.inode == initial.rootIdentity.inode else {
            throw KnownPeopleManagedStoreFailure.staleInventory
        }
        try Task.checkCancellation()
        return .init(libraryID: libraryID, installationID: installationID, replacementPlan: planned)
    }

    /// Production commit API. No direct filesystem executor is selected by the UI.
    func assign(plan: KnownPeopleLocalIdentityAssignmentPlan, owner: KnownPeopleService,
                routingActive: Bool,
                routeMutationGate: KnownPeopleRouteMutationGate = .shared,
                replacementAccess: KnownPeopleManagedStoreReplacementAccess = .init()) async -> KnownPeopleLocalIdentityAssignmentResult {
        await assign(plan: plan) { replacementPlan in
            await owner.replaceManagedStore(plan: replacementPlan, decision: .replaceUntracked,
                routingActive: routingActive, routeMutationGate: routeMutationGate,
                replacementAccess: replacementAccess)
        }
    }

    /// Internal transaction seam for deterministic filesystem tests. Production uses the
    /// owner overload above; the executor must return the actual atomic-commit outcome.
    func assign(plan: KnownPeopleLocalIdentityAssignmentPlan,
                execute: @Sendable (KnownPeopleManagedStoreReplacementPlan) async -> KnownPeopleManagedStoreReplacementResult) async -> KnownPeopleLocalIdentityAssignmentResult {
        switch plan.receipt.begin() {
        case .committed(let result):
            return .init(transaction: result, returnedCommittedReceipt: true)
        case .busy:
            return .init(transaction: .init(committed: false, revision: nil, recoveryDirectory: nil,
                installedState: nil, failure: KnownPeopleLocalIdentityAssignmentFailure.attemptInProgress.localizedDescription,
                wasCancelled: false), returnedCommittedReceipt: false)
        case .admitted:
            let result: KnownPeopleManagedStoreReplacementResult
            if Task.isCancelled {
                result = .init(committed: false, revision: nil, recoveryDirectory: nil,
                               installedState: nil, failure: nil, wasCancelled: true)
            } else {
                result = await execute(plan.replacementPlan)
            }
            // Record the commit bit even when the caller was cancelled during the admitted
            // transaction. Retrying must never assign a new identity after a possible swap.
            plan.receipt.finish(result)
            return .init(transaction: result, returnedCommittedReceipt: false)
        }
    }
}
