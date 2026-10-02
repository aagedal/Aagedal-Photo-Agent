import Foundation

/// Read-only app-side resolution of an authenticated helper handoff. A returned
/// review means only that the exact retained intent can be presented for native
/// review; it grants no provider consent, admission, inference or metadata write.
/// The caller keeps the record inside the app and sends only closed wire status.
nonisolated struct AutomationNativeTranscriptionReviewInvocationService: Sendable {
    enum Failure: Error, Equatable {
        case requestChanged, reviewUnavailable, linkedEvidenceUnavailable
    }

    enum Result: Sendable {
        case review(MCPVoiceTranscriptionReviewRequestStore.Record)
        /// An exact retained history handle, never a completion acknowledgement.
        case linked(UUID)
    }

    private let requests: MCPVoiceTranscriptionReviewRequestStore
    private let plans: MCPVoiceTranscriptionPlanStore
    private let facade: MCPAutomationFacade
    private let registry: AutomationOperationRegistry
    private let now: @Sendable () -> Date

    init(requests: MCPVoiceTranscriptionReviewRequestStore, plans: MCPVoiceTranscriptionPlanStore,
         facade: MCPAutomationFacade, registry: AutomationOperationRegistry,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.requests = requests; self.plans = plans; self.facade = facade
        self.registry = registry; self.now = now
    }

    /// Synchronous so the private transport can resolve on its utility queue.
    /// UI publication is a separate safe boundary: revalidate the returned record
    /// after any suspension, then use the existing native review inspection flow.
    func invoke(requestID: UUID, requestEpoch: UUID) throws -> Result {
        try Task.checkCancellation()
        let authority = try enabledAuthority()
        let request = try requests.inspect(requestID, requestEpoch: requestEpoch)
        let result: Result
        switch request.state {
        case .awaitingReview:
            try revalidate(request)
            result = .review(request)
        case .linked:
            result = .linked(try linkedOperation(for: request))
        case .admitted, .cancelled:
            throw Failure.reviewUnavailable
        }
        try requireAuthority(authority)
        try Task.checkCancellation()
        return result
    }

    /// Rechecks the complete original ordered batch, sources, associations, WAVs,
    /// expiry and authorization while rooted reservations remain held. Passing a
    /// record from a prior UI event cannot silently select a recreated request.
    func revalidate(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) throws {
        try Task.checkCancellation()
        let authority = try enabledAuthority()
        try requireAwaiting(request)
        try plans.withValidatedPreview(planID: request.planID, facade: facade, now: now()) { preview in
            try requireAwaiting(request)
            guard try MCPVoiceTranscriptionReviewRequestStore.Intent(preview: preview) == request.intent else {
                throw Failure.requestChanged
            }
            try requireAuthority(authority)
            try Task.checkCancellation()
            try requireAwaiting(request)
        }
        try requireAwaiting(request)
        try requireAuthority(authority)
        try Task.checkCancellation()
    }

    private func requireAwaiting(_ expected: MCPVoiceTranscriptionReviewRequestStore.Record) throws {
        guard expected.state == .awaitingReview, expected.cancellationRequestedAt == nil,
              expected.admission == nil, expected.operationID == nil else { throw Failure.reviewUnavailable }
        try requireCurrent(expected)
    }

    private func requireCurrent(_ expected: MCPVoiceTranscriptionReviewRequestStore.Record) throws {
        guard let id = UUID(uuidString: expected.requestID), let epoch = UUID(uuidString: expected.requestEpoch),
              try requests.inspect(id, requestEpoch: epoch) == expected else { throw Failure.requestChanged }
    }

    private func linkedOperation(for expected: MCPVoiceTranscriptionReviewRequestStore.Record) throws -> UUID {
        // Match the durable reserved ID and owner, never a similar kind/count/time
        // candidate. History locks precede request locks throughout this domain.
        try registry.withLockedRecords { operations in
            try requireCurrent(expected)
            guard expected.state == .linked, expected.cancellationRequestedAt == nil,
                  let admission = expected.admission,
                  admission.requestID == expected.requestID, admission.requestEpoch == expected.requestEpoch,
                  admission.intentSHA256 == expected.intentSHA256, admission.batchIdentity == expected.batchIdentity,
                  let operationID = UUID(uuidString: admission.operationID),
                  expected.operationID == admission.operationID,
                  let operation = operations.first(where: { $0.id == operationID }),
                  operation.kind == .voiceTranscription, operation.ownerLeaseManaged == true,
                  operation.ownerID.uuidString.lowercased() == admission.ownerID,
                  operation.batchProgress?.itemCount == expected.intent.photoCount,
                  let admittedAt = expected.admittedAt, let linkedAt = expected.linkedAt,
                  operation.createdAt >= admittedAt, operation.createdAt <= linkedAt,
                  operation.cancellationRequestedAt == nil, operation.state != .cancelled else {
                throw Failure.linkedEvidenceUnavailable
            }
            try requireCurrent(expected)
            try Task.checkCancellation()
            return operationID
        }
    }

    private func enabledAuthority() throws -> MCPAuthorizationConfiguration {
        let authority = try facade.authorizationStore.load()
        guard authority.isEnabled else { throw MCPAuthorizationError.disabled }
        return authority
    }

    private func requireAuthority(_ expected: MCPAuthorizationConfiguration) throws {
        guard try enabledAuthority() == expected else { throw MCPVoiceTranscriptionPlanStore.Failure.authorityChanged }
    }
}
