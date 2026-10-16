import Foundation

/// App-side durable bridge only. Callers must establish native consent independently.
/// Scheduling still uses the scanner's existing effect checks and path-based storage;
/// these receipts confer neither helper execution nor rooted publication authority.
actor MCPFaceScanOperationService {
    enum Failure: Error { case missingCompletion, mismatchedSubmission }
    /// A scheduled submission must own its actual task; returning a nil or unrelated
    /// task violates this executor contract. The production native bridge captures it
    /// synchronously with scheduling on MainActor.
    typealias Scheduler = @Sendable (MCPFaceScanAdmissionService.RetainedFolder, UUID, @escaping @Sendable () throws -> Void) async throws -> FaceFolderScanSubmission
    private let intents: MCPFaceScanIntentStore
    private let registry: AutomationOperationRegistry
    private let receipts: MCPFaceScanReceiptStore
    private let coordinator: AutomationOperationExecutionCoordinator
    private let schedule: Scheduler
    private var submissions: [UUID: FaceFolderScanSubmission] = [:]
    private var stopping = false

    init(intents: MCPFaceScanIntentStore, registry: AutomationOperationRegistry,
         receipts: MCPFaceScanReceiptStore, schedule: @escaping Scheduler) {
        self.intents = intents; self.registry = registry; self.receipts = receipts
        self.schedule = schedule
        coordinator = .init(registry: registry, maximumConcurrentOperations: 1)
    }

    /// The production scheduler captures the exact task on MainActor. No helper route
    /// or automatically granted native consent is installed by constructing this adapter.
    @MainActor static func native(intents: MCPFaceScanIntentStore, registry: AutomationOperationRegistry,
                                  receipts: MCPFaceScanReceiptStore,
                                  scanner: FaceRecognitionViewModel) -> MCPFaceScanOperationService {
        .init(intents: intents, registry: registry, receipts: receipts, schedule: { retained, _, validateNativeAuthority in
            await scanner.scheduleRetainedFolderScan(retained: retained, validateNativeAuthority: validateNativeAuthority)
        })
    }

    /// The nativeAdmission callback must validate a caller-owned native capability
    /// for this exact intent that remains valid through the retained worker's effects.
    /// This adapter cannot manufacture such a capability. Persistence finishes before
    /// the scheduler can run. An admitted intent is single use even after a refusal.
    func submit(intentID: UUID,
                nativeAdmission: @escaping @Sendable (MCPFaceScanIntentStore.Intent) throws -> Void,
                nativeCompletion: @escaping @Sendable () -> Void = {}) async throws -> AutomationOperationRegistry.Record {
        guard !stopping else { throw AutomationOperationExecutionCoordinator.Failure.stopped }
        let intent = try intents.inspect(id: intentID)
        try nativeAdmission(intent)
        let binding = try intents.reviewBinding(id: intentID)
        let retained = try intents.retain(id: intentID)
        let operationID = UUID(), admissionID = UUID()
        let ownerID = await coordinator.ownerID
        let receipts = self.receipts, intents = self.intents, schedule = self.schedule, registry = self.registry
        let checkDurable: @Sendable () throws -> Void = {
            guard let binding else { return }
            try binding.requests.checkCancellation(UUID(uuidString: binding.record.requestID)!,
                requestEpoch: UUID(uuidString: binding.record.requestEpoch)!, admissionID: admissionID,
                operationID: operationID, ownerID: ownerID)
        }
        do {
            return try await coordinator.submit(kind: .faceScan, operationID: operationID,
                managedAdmission: { lease in
                    try nativeAdmission(intent)
                    try retained.validate()
                    try intents.validateAdmission(id: intentID)
                    let durable: MCPFaceScanReviewRequestStore.Admission?
                    if let binding {
                        let admitted = try binding.requests.admit(UUID(uuidString: binding.record.requestID)!,
                            requestEpoch: UUID(uuidString: binding.record.requestEpoch)!, expected: binding.record,
                            admissionID: admissionID, operationID: operationID, ownerLease: lease, registry: registry)
                        durable = admitted.admission
                    } else { durable = nil }
                    try receipts.admit(intent: intent, operationID: operationID, durableAdmission: durable)
                }, managedDidEnqueue: { record, lease in
                    if let binding {
                        _ = try binding.requests.link(UUID(uuidString: binding.record.requestID)!,
                            requestEpoch: UUID(uuidString: binding.record.requestEpoch)!, operationID: record.id,
                            ownerLease: lease, registry: registry)
                    }
                }, cancellationCheck: { id in
                    do { try checkDurable() }
                    catch is CancellationError {
                        _ = try registry.requestCancellation(id)
                        throw CancellationError()
                    }
                }, completion: { retained.release(); nativeCompletion() }) { context in
                // Both conservative execution evidence and coordination effects precede
                // scanner scheduling (which may immediately schedule a reset/write).
                try await context.checkCancellation()
                try receipts.markExecutionPossible(operationID)
                try await context.markEffectsMayHaveOccurred()
                // The caller's native capability must remain valid for the retained task;
                // recheck it immediately before scheduling as well as initial admission.
                try nativeAdmission(intent)
                let submission = try await schedule(retained, intentID, {
                    try nativeAdmission(intent)
                    try checkDurable()
                    if try registry.inspect(operationID).cancellationRequestedAt != nil { throw CancellationError() }
                })
                let registrationError = await self.retainSubmission(submission, operationID: operationID)
                // This watcher owns only this exact handle and ends before operation
                // completion. External helper requests cannot accidentally cancel a later
                // scanner slot. Failed history reads stop possible effects conservatively.
                let cancellationWatcher = Task { () -> Bool in
                    while !Task.isCancelled {
                        do {
                            do { try checkDurable() }
                            catch is CancellationError {
                                _ = try registry.requestCancellation(operationID)
                                submission.cancel()
                                return false
                            }
                            if try registry.inspect(operationID).cancellationRequestedAt != nil {
                                submission.cancel()
                                return false
                            }
                        } catch {
                            submission.cancel()
                            return true
                        }
                        do { try await Task.sleep(for: .milliseconds(100)) }
                        catch { return false }
                    }
                    return false
                }
                // Drain every returned task, including an invalid refused/mismatched
                // submission. Ownership lasts until its actual possible effects end.
                let completion = await submission.completion()
                cancellationWatcher.cancel()
                let watcherFailed = await cancellationWatcher.value
                await self.releaseSubmission(operationID)
                var coordinationFailed = registrationError != nil || watcherFailed
                // The exact worker may finish before the watcher's first poll, or
                // observe request cancellation at an effect boundary during that poll.
                // Reconcile once more after drain before recording terminal evidence.
                do { try checkDurable() }
                catch is CancellationError {
                    do { _ = try registry.requestCancellation(operationID) }
                    catch { coordinationFailed = true }
                } catch { coordinationFailed = true }
                let requested: Bool
                do { requested = try self.registry.inspect(operationID).cancellationRequestedAt != nil }
                catch { requested = false; coordinationFailed = true }
                let matches: Bool
                if case .scheduled(let request) = submission.admission {
                    matches = request.folderURL == intent.prepared.folderURL.standardizedFileURL
                        && request.imageURLs.map(\.standardizedFileURL) == intent.prepared.imageURLs.map(\.standardizedFileURL)
                        && request.forceFullScan == intent.prepared.forceFullScan
                        && request.includeJerseyNumbers == intent.prepared.includeJerseyNumbers
                        && completion?.folderURL.standardizedFileURL == intent.prepared.folderURL.standardizedFileURL
                } else { matches = false }
                var evidence: MCPFaceScanReceiptStore.Completion
                if let completion {
                    evidence = Self.evidence(completion, cancellationRequested: requested)
                    if !matches {
                        evidence.outcome = .recoveryRequired
                        evidence.submissionMismatch = true
                    }
                } else {
                    let refused: Bool
                    if case .refused = submission.admission { refused = true } else { refused = false }
                    evidence = .init(outcome: refused ? .failed : .recoveryRequired, processedCount: 0,
                        failureCount: 0, unsignedFileCount: intent.prepared.imageURLs.count,
                        committedThumbnailCount: 0, committedDocumentCount: 0, resetCommitted: false,
                        persistenceFailed: false, completionUnavailable: !refused)
                }
                if coordinationFailed {
                    evidence.outcome = .recoveryRequired
                    evidence.coordinationFailed = true
                }
                // Failure to preserve physical completion is uncertain, even if the worker
                // itself reports success. Coordinator fallback remains recoveryRequired.
                try receipts.complete(operationID, evidence: evidence)
                return evidence.outcome
            }
        } catch {
            retained.release()
            nativeCompletion()
            throw error
        }
    }

    func waitForCompletion(_ id: UUID) async throws -> AutomationOperationRegistry.Record {
        try await coordinator.waitForCompletion(id)
    }

    /// Persist first, then cancel only this operation's exact retained task. Direct
    /// helper registry requests are observed by the execution's 100 ms watcher.
    func requestCancellation(_ id: UUID) throws -> AutomationOperationRegistry.Record {
        guard try registry.inspect(id).kind == .faceScan else { throw Failure.mismatchedSubmission }
        let record = try registry.requestCancellation(id)
        submissions[id]?.cancel()
        return record
    }

    private func retainSubmission(_ submission: FaceFolderScanSubmission, operationID: UUID) -> (any Error)? {
        submissions[operationID] = submission
        do {
            if stopping { _ = try registry.requestCancellation(operationID) }
            if try registry.inspect(operationID).cancellationRequestedAt != nil { submission.cancel() }
            return nil
        } catch {
            submission.cancel()
            return error
        }
    }

    private func releaseSubmission(_ id: UUID) { submissions.removeValue(forKey: id) }

    /// Released kernel owner locks prove abandonment. Receipts remain inspectable;
    /// neither this method nor constructing a new adapter replays retained intents.
    func reconcileAbandonedOwners() throws -> [AutomationOperationRegistry.Record] {
        try registry.reconcileAbandonedOwners()
    }

    func shutdown() async throws -> [AutomationOperationRegistry.Record] {
        stopping = true
        var requestError: (any Error)?
        for (id, submission) in submissions {
            do {
                _ = try registry.requestCancellation(id)
                submission.cancel()
            } catch { if requestError == nil { requestError = error } }
        }
        // Coordinator also accumulates request failures and drains every retained
        // work closure before returning or throwing. Never detach on a storage error.
        let reconciled = try await coordinator.shutdown()
        if let requestError { throw requestError }
        return reconciled
    }

    nonisolated static func evidence(_ completion: FaceScanCompletion,
                                     cancellationRequested: Bool) -> MCPFaceScanReceiptStore.Completion {
        let committedDocuments = completion.documentPersistenceResults.reduce(0) { count, result in
            if case .committed(let evidence) = result, evidence.documentCommitted { return count + 1 }
            return count
        }
        let resetCommitted: Bool
        switch completion.resetPersistence {
        case .committed?, .committedButUnverified?: resetCommitted = true
        default: resetCommitted = false
        }
        let persistenceFailed = completion.persistenceError != nil
            || completion.documentPersistenceResults.contains { $0.failureMessage != nil }
            || completion.resetPersistence?.failureMessage != nil
        let hasEffects = resetCommitted || committedDocuments > 0 || !completion.committedThumbnailIDs.isEmpty
        let outcome: AutomationOperationRegistry.Outcome
        if completion.succeeded, !persistenceFailed { outcome = .verified }
        else if case .cancelled = completion.outcome, !hasEffects,
                !persistenceFailed, cancellationRequested { outcome = .cancelled }
        else { outcome = hasEffects || persistenceFailed ? .recoveryRequired : .failed }
        let documents = completion.documentPersistenceResults.map { result -> MCPFaceScanReceiptStore.DocumentEvidence in
            switch result {
            case .committed(let evidence):
                return .init(result: .committed, documentCommitted: evidence.documentCommitted,
                    requestedThumbnailDeletionCount: evidence.requestedThumbnailDeletionCount,
                    deletedThumbnailIDs: evidence.deletedThumbnailIDs,
                    failedThumbnailIDs: evidence.thumbnailFailures.map(\.faceID),
                    cancellationRequestedAfterCommit: evidence.cancellationRequestedAfterCommit,
                    authorityRefused: evidence.authorityFailure != nil)
            case .cancelledBeforeCommit, .failedBeforeCommit:
                return .init(result: result.failureMessage == nil ? .cancelledBeforeCommit : .failedBeforeCommit,
                    documentCommitted: false, requestedThumbnailDeletionCount: 0, deletedThumbnailIDs: [],
                    failedThumbnailIDs: [], cancellationRequestedAfterCommit: false, authorityRefused: false)
            }
        }
        let reset: MCPFaceScanReceiptStore.ResetEvidence?
        switch completion.resetPersistence {
        case .committed(_, let cancelled)?: reset = .init(result: .committed, cancellationRequestedAfterCommit: cancelled)
        case .committedButUnverified(_, _, let cancelled)?: reset = .init(result: .committedButUnverified, cancellationRequestedAfterCommit: cancelled)
        case .cancelledBeforeCommit?: reset = .init(result: .cancelledBeforeCommit, cancellationRequestedAfterCommit: false)
        case .failed?: reset = .init(result: .failed, cancellationRequestedAfterCommit: false)
        case nil: reset = nil
        }
        return .init(outcome: outcome, processedCount: completion.processedCount,
            failureCount: completion.failureCount, unsignedFileCount: completion.unsignedFileCount,
            committedThumbnailCount: completion.committedThumbnailIDs.count,
            committedDocumentCount: committedDocuments, resetCommitted: resetCommitted,
            persistenceFailed: persistenceFailed, committedThumbnailIDs: completion.committedThumbnailIDs,
            documents: documents, reset: reset)
    }
}
