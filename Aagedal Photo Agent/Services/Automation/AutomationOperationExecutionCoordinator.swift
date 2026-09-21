import Foundation

/// Retains admitted work independently of the submitting request. Durable records contain
/// coordination evidence only; the work closure remains responsible for authorization,
/// reservations, mutation verification and any rollback.
actor AutomationOperationExecutionCoordinator {
    enum Failure: Error, Equatable { case capacity, stopped, unresolved, unknownOperation }
    typealias Work = @Sendable (Context) async throws -> AutomationOperationRegistry.Outcome

    /// Effects are marked before the first possible write, not after it succeeds. An
    /// unexpected throw after that boundary must never become a definite failure.
    actor Context {
        let operationID: UUID
        private let registry: AutomationOperationRegistry
        private var effectsPossible = false

        init(operationID: UUID, registry: AutomationOperationRegistry) {
            self.operationID = operationID
            self.registry = registry
        }

        func checkCancellation() throws {
            if try registry.inspect(operationID).cancellationRequestedAt != nil {
                throw CancellationError()
            }
            try Task.checkCancellation()
        }

        func markEffectsMayHaveOccurred() throws {
            try checkCancellation()
            effectsPossible = true
        }

        fileprivate func fallbackOutcome() -> AutomationOperationRegistry.Outcome {
            effectsPossible ? .recoveryRequired : .failed
        }
    }

    let ownerID: UUID
    private let registry: AutomationOperationRegistry
    private let maximumConcurrentOperations: Int
    private var tasks: [UUID: Task<AutomationOperationRegistry.Record, Error>] = [:]
    private var accepting = true

    init(registry: AutomationOperationRegistry, ownerID: UUID = UUID(), maximumConcurrentOperations: Int = 4) {
        self.registry = registry
        self.ownerID = ownerID
        self.maximumConcurrentOperations = min(max(0, maximumConcurrentOperations), 32)
    }

    /// Admission and durable enqueue finish before execution can begin. A returned
    /// record is an acceptance receipt, never a promise that mutation succeeded.
    func submit(kind: AutomationOperationRegistry.Kind, work: @escaping Work) throws -> AutomationOperationRegistry.Record {
        guard accepting else { throw Failure.stopped }
        guard tasks.count < maximumConcurrentOperations else { throw Failure.capacity }
        let record = try registry.enqueue(kind: kind, ownerID: ownerID)
        tasks[record.id] = Task { try await execute(record.id, work: work) }
        return record
    }

    func waitForCompletion(_ id: UUID) async throws -> AutomationOperationRegistry.Record {
        if let task = tasks[id] { return try await task.value }
        let record = try registry.inspect(id)
        guard record.ownerID == ownerID else { throw Failure.unknownOperation }
        guard record.isTerminal else { throw Failure.unresolved }
        return record
    }

    /// Stops admission, requests cancellation and waits for all retained closures to
    /// actually return. Only then is stopped-owner reconciliation truthful. It does
    /// not detach active writes or claim that requesting cancellation stopped them.
    func shutdown() async throws -> [AutomationOperationRegistry.Record] {
        accepting = false
        let retained = tasks
        var requestError: Error?
        for id in retained.keys {
            do { _ = try registry.requestCancellation(id) }
            catch { if requestError == nil { requestError = error } }
        }
        for task in retained.values { _ = await task.result }
        let reconciled = try registry.reconcileStoppedOwner(ownerID: ownerID)
        if let requestError { throw requestError }
        return reconciled
    }

    private func execute(_ id: UUID, work: Work) async throws -> AutomationOperationRegistry.Record {
        defer { tasks.removeValue(forKey: id) }
        let context = Context(operationID: id, registry: registry)
        let outcome: AutomationOperationRegistry.Outcome
        do {
            try await context.checkCancellation()
            // A helper request between the check and start is rejected by the registry.
            do { _ = try registry.start(id, ownerID: ownerID) }
            catch {
                try await context.checkCancellation()
                throw error
            }
            outcome = try await work(context)
        } catch is CancellationError {
            let fallback = await context.fallbackOutcome()
            let record = try registry.inspect(id)
            if record.cancellationRequestedAt != nil {
                return try registry.acknowledgeCancellation(id, ownerID: ownerID,
                    outcome: fallback == .failed ? .cancelled : .recoveryRequired)
            }
            // Task cancellation without a durable request is not evidence of an
            // acknowledged helper request or of a successfully reversed write.
            return try registry.finish(id, ownerID: ownerID, outcome: fallback)
        } catch {
            return try registry.finish(id, ownerID: ownerID, outcome: await context.fallbackOutcome())
        }
        if outcome == .cancelled {
            // The work closure may return this only after establishing that no
            // uncertain effects remain. The registry requires a durable request.
            return try registry.acknowledgeCancellation(id, ownerID: ownerID)
        }
        return try registry.finish(id, ownerID: ownerID, outcome: outcome)
    }
}
