import Foundation

/// App-side batch intent. Read-only MCP control previews cannot be passed as intents:
/// callers must independently capture application settings, decoder evidence and carriers.
nonisolated struct DevelopTemplateBatchIntent: Sendable {
    static let maximumPhotos = 8
    let id: UUID
    let templateID: UUID
    let templateRevision: String
    let requests: [PrimaryDevelopWriteRequest]

    init(id: UUID = UUID(), templateID: UUID, templateRevision: String,
         requests: [PrimaryDevelopWriteRequest]) throws {
        guard !requests.isEmpty, requests.count <= Self.maximumPhotos,
              !templateRevision.isEmpty else { throw DevelopTemplateBatchFailure.invalidIntent }
        var identities = Set<String>()
        var requestIDs = Set<UUID>()
        for request in requests {
            guard requestIDs.insert(request.id).inserted else { throw DevelopTemplateBatchFailure.duplicatePhoto }
            guard request.predecessor == nil, request.captureFailure == nil,
                  request.mode != .historyOnly, request.sourceRevision != nil,
                  request.expectedXMP != nil, request.imageURL.isFileURL,
                  request.folderURL.isFileURL else { throw DevelopTemplateBatchFailure.invalidIntent }
            // Watermark library reservation/identity admission is not wired to this core yet.
            guard request.watermarkDependencies.isEmpty,
                  PrimaryDevelopWriteRequestBuilder.watermarkDependencyIDs(edited: request.edited,
                    previous: request.previous, original: request.original).isEmpty,
                  (request.embeddedBaseline?.cameraRaw?.watermarkLayers ?? []).isEmpty else {
                throw DevelopTemplateBatchFailure.unsupportedWatermarkDependencies
            }
            let key = request.imageURL.standardizedFileURL.resolvingSymlinksInPath()
                .deletingPathExtension().path.lowercased()
            guard identities.insert(key).inserted else { throw DevelopTemplateBatchFailure.duplicatePhoto }
        }
        self.id = id; self.templateID = templateID; self.templateRevision = templateRevision
        self.requests = requests
    }
}

nonisolated enum DevelopTemplateBatchFailure: Error, Equatable, Sendable {
    case invalidIntent, duplicatePhoto, staleSource, resultIdentityChanged, retentionLimit, unsupportedWatermarkDependencies
}

nonisolated struct DevelopTemplateBatchExecutionResult: Sendable {
    enum Outcome: String, Codable, Sendable { case prepared, running, completed, failed, cancelled, recoveryRequired }
    let intent: DevelopTemplateBatchIntent
    var results: [PrimaryDevelopWriteResult?]
    var outcome: Outcome = .prepared
    /// Persisted before invoking a writer, even when no physical receipt returns.
    var activeRequestID: UUID?
    var failure: String?
    var retentionFailure: String?
    /// A mismatched worker receipt is evidence, never a valid completion for this intent.
    var unexpectedReceipt: DevelopTemplateBatchUnexpectedReceipt?
    var completedCount: Int { results.compactMap { $0 }.filter(\.completed).count }
    var recoveryPayload: DevelopTemplateBatchRecoveryPayload { .init(self) }
}

nonisolated struct DevelopTemplateBatchUnexpectedReceipt: Encodable, Sendable {
    let reportedRequestID: UUID
    let evidence: PrimaryDevelopRecoveryPayload
}

/// Complete original intents and physical receipts are retained together. A later editor
/// selection or freshly rendered preview never supplies a retry's source or destination.
nonisolated final class DevelopTemplateBatchRecoveryPayload: Encodable, Sendable {
    let formatVersion = 1
    let kind = "Develop template batch"
    let batchID: UUID
    let templateID: UUID
    let templateRevision: String
    let outcome: DevelopTemplateBatchExecutionResult.Outcome
    let activeRequestID: UUID?
    let failure: String?
    let retentionFailure: String?
    let photos: [PrimaryDevelopRecoveryPayload]
    let resultCompletions: [Bool?]
    let unexpectedReceipt: DevelopTemplateBatchUnexpectedReceipt?

    init(_ result: DevelopTemplateBatchExecutionResult) {
        batchID = result.intent.id; templateID = result.intent.templateID
        templateRevision = result.intent.templateRevision; outcome = result.outcome
        activeRequestID = result.activeRequestID; failure = result.failure
        retentionFailure = result.retentionFailure
        unexpectedReceipt = result.unexpectedReceipt
        photos = result.intent.requests.indices.map {
            PrimaryDevelopRecoveryPayload(result.intent.requests[$0], result: result.results[$0])
        }
        resultCompletions = result.results.map { $0.map(\.completed) }
    }
}

/// Production carrier checks and shared reservations are owned here. Root/template consent
/// checks and durable storage are mandatory caller capabilities; this is not an MCP executor.
nonisolated struct DevelopTemplateBatchExecutionService: Sendable {
    typealias AuthorityValidation = @Sendable (DevelopTemplateBatchIntent) async throws -> Void
    typealias Retention = @Sendable (DevelopTemplateBatchExecutionResult) async throws -> Void
    typealias CaptureValidation = @Sendable (DevelopTemplateBatchIntent, [UUID: MCPProcessReservationLease], Set<UUID>) throws -> Void
    typealias Writer = @Sendable (PrimaryDevelopWriteRequest, MCPProcessReservationLease,
        @escaping @Sendable () async throws -> Void) async -> PrimaryDevelopWriteResult
    static let maximumRecoveryBytes = 268_435_456
    let write: Writer

    init(engine: any MetadataWriteEngine, hooks: PrimaryDevelopWriteHooks = .init(),
         validateCommitAuthority: @escaping @Sendable () throws -> Void = {}) {
        let service = PrimaryDevelopWriteService(engine: engine, hooks: hooks)
        write = { await service.execute($0, heldReservation: $1, validateAuthority: $2,
                                      validateCommitAuthority: validateCommitAuthority) }
    }

    /// Injectable physical writer, while admission and reservation checks remain production.
    init(write: @escaping Writer) { self.write = write }

    /// App-side durable retention adapter. Recovery loading is evidence for review only;
    /// this entry point still requires independent native authority validation.
    func execute(_ intent: DevelopTemplateBatchIntent,
                 validateAuthority: @escaping AuthorityValidation,
                 checkpointStore: DevelopTemplateBatchCheckpointStore,
                 validateCapture: @escaping CaptureValidation = { _, _, _ in }) async -> DevelopTemplateBatchExecutionResult {
        await execute(intent, validateAuthority: validateAuthority,
                      retain: { try await checkpointStore.retain($0) }, validateCapture: validateCapture)
    }

    func execute(_ intent: DevelopTemplateBatchIntent,
                 validateAuthority: @escaping AuthorityValidation,
                 retain: @escaping Retention,
                 validateCapture: @escaping CaptureValidation = { _, _, _ in }) async -> DevelopTemplateBatchExecutionResult {
        var result = DevelopTemplateBatchExecutionResult(intent: intent,
            results: Array(repeating: nil, count: intent.requests.count))
        var reservations: [UUID: MCPProcessReservationLease] = [:]
        defer { reservations.values.forEach { $0.release() } }
        var effectsPossible = false
        do {
            try Task.checkCancellation()
            for request in intent.requests.sorted(by: { $0.imageURL.path < $1.imageURL.path }) {
                reservations[request.id] = try MCPProcessReservation.acquirePhoto(request.imageURL)
            }
            // Check the complete original set before any photo can be changed.
            try await validateAuthority(intent)
            try validateCapture(intent, reservations, Set(intent.requests.map(\.id)))
            for request in intent.requests { try await Self.validateCarriers(request) }
            // Retention is mandatory and must finish durably before the first possible effect.
            try await Self.retainBounded(result, retain: retain)
            for index in intent.requests.indices {
                try Task.checkCancellation()
                try await validateAuthority(intent)
                let request = intent.requests[index]
                try await Self.validateCarriers(request)
                try Task.checkCancellation()
                result.outcome = .running; result.activeRequestID = request.id
                try await Self.retainBounded(result, retain: retain)
                // A failed prewrite checkpoint cannot authorize physical mutation.
                try await validateAuthority(intent)
                if index == 0 {
                    for captured in intent.requests { try await Self.validateCarriers(captured) }
                }
                let untouched = Set(intent.requests[index...].map(\.id))
                try validateCapture(intent, reservations, untouched)
                try Task.checkCancellation()
                effectsPossible = true
                let heldReservations = reservations
                let receipt = await write(request, reservations[request.id]!) {
                    try await validateAuthority(intent)
                    // Every callback can precede an effect, including a prepared embedded
                    // writer's second callback. Current and later exact generations stay
                    // protected until that worker returns its physical receipt. Admission
                    // currently restricts capture validation to sidecar-only workers;
                    // embedded writes need an explicit owned-effect stage signal.
                    try validateCapture(intent, heldReservations, untouched)
                }
                guard receipt.requestID == request.id else {
                    result.unexpectedReceipt = .init(reportedRequestID: receipt.requestID,
                        evidence: PrimaryDevelopRecoveryPayload(request, result: receipt))
                    throw DevelopTemplateBatchFailure.resultIdentityChanged
                }
                result.results[index] = receipt; result.activeRequestID = nil
                if !receipt.completed {
                    result.failure = receipt.failure
                    result.outcome = receipt.requiresRecovery || result.completedCount > 0
                        ? .recoveryRequired : receipt.wasCancelled ? .cancelled : .failed
                    // No uncertain write occurred when the exact physical worker proves it.
                    effectsPossible = receipt.requiresRecovery || result.completedCount > 0
                    try await Self.retainBounded(result, retain: retain)
                    return result
                }
                try await Self.retainBounded(result, retain: retain)
            }
            result.outcome = .completed
            try await Self.retainBounded(result, retain: retain)
        } catch {
            result.failure = error.localizedDescription
            result.outcome = effectsPossible ? .recoveryRequired : error is CancellationError ? .cancelled : .failed
            // This call deliberately runs even after cancellation. Storage must retain the
            // original payload and any returned receipt without consulting editor selection.
            do { try await Self.retainBounded(result, retain: retain) }
            catch { result.retentionFailure = error.localizedDescription }
        }
        return result
    }

    private static func retainBounded(_ result: DevelopTemplateBatchExecutionResult,
                                      retain: Retention) async throws {
        guard try JSONEncoder().encode(result.recoveryPayload).count <= maximumRecoveryBytes else {
            throw DevelopTemplateBatchFailure.retentionLimit
        }
        try await retain(result)
    }

    private static func validateCarriers(_ request: PrimaryDevelopWriteRequest) async throws {
        try Task.checkCancellation()
        _ = try await MetadataSidecarService().captureWriteCompletionSnapshot(for: request.imageURL,
            in: request.folderURL, expectedSidecar: request.expectedRecord,
            expectedTechnicalMetadata: nil, expectedXMPSnapshot: request.expectedXMP)
        let source = try await SourceImageRevision.capture(at: request.imageURL)
        guard source.canonicalURL == request.sourceRevision?.canonicalURL,
              source.sha256 == request.sourceRevision?.sha256 else { throw DevelopTemplateBatchFailure.staleSource }
    }
}
