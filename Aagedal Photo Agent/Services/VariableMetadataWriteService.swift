import Foundation

nonisolated final class VariableMetadataWriteReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var prepared: MetadataSidecar?
    private var physical: MetadataSidecarReplayCreationEvidence
    private var completed: VariableMetadataWriteResult?
    private var unverified: PendingMetadataWriteResult?
    private var lastResult: VariableMetadataWriteResult?
    func recordLastResult(_ value: VariableMetadataWriteResult) { lock.withLock { lastResult = value } }
    func captureRecovery<T>(_ body: (MetadataSidecar?, MetadataSidecarReplayCreationEvidence, VariableMetadataWriteResult?, PendingMetadataWriteResult?, VariableMetadataWriteResult?) throws -> T) throws -> T {
        try lock.withLock {
            guard !running else { throw VariableConflictRecoveryError.requestRunning }
            return try body(prepared, physical, completed, unverified, lastResult)
        }
    }
    var unverifiedCompletion: PendingMetadataWriteResult? { lock.withLock { unverified } }
    func recordUnverified(_ value: PendingMetadataWriteResult) { lock.withLock { unverified = value } }
    init(evidence: MetadataSidecarReplayCreationEvidence) { physical = evidence }
    func begin() -> Bool { lock.withLock { guard !running else { return false }; running = true; return true } }
    func end() { lock.withLock { running = false } }
    var state: (MetadataSidecar?, MetadataSidecarReplayCreationEvidence, VariableMetadataWriteResult?) {
        lock.withLock { (prepared, physical, completed) }
    }
    func recordPrepared(_ value: MetadataSidecar) { lock.withLock { prepared = value } }
    func recordPhysical(_ value: MetadataSidecarReplayCreationEvidence) { lock.withLock { physical = value } }
    func finish(_ value: VariableMetadataWriteResult) { lock.withLock { completed = value } }
}

/// An immutable interpolation result. Retrying this request never interpolates again, generates
/// new history IDs, or adopts an independently newer pending record as its completion target.
nonisolated struct VariableMetadataWriteRequest: Sendable {
    let id: UUID
    let imageURL: URL
    let folderURL: URL
    let requestedMode: MetadataWriteMode
    let originalMetadata: IPTCMetadata
    let replay: MetadataSidecarReplayRequest
    let baselineSidecar: MetadataSidecar?
    fileprivate let receipt: VariableMetadataWriteReceipt
    var sidecar: MetadataSidecar { replay.sidecar }
    /// A verified JSON preparation has already retained this captured intent durably.
    var hasVerifiedPreparedRecord: Bool { receipt.state.0 != nil }

    /// Sample all private receipt fields while execution is excluded by the same receipt lock.
    /// The caller also freezes its admissions so this settled snapshot stays current for review.
    func recoverySnapshot() throws -> VariableMetadataRequestRecoverySnapshot {
        try receipt.captureRecovery { prepared, physical, completed, unverified, last in
            .init(requestID: id, imageURL: imageURL, folderURL: folderURL, requestedMode: requestedMode.rawValue,
                originalMetadata: .init(originalMetadata), capturedMetadata: .init(replay.sidecar.metadata),
                baselineMetadata: .init(replay.baselineMetadata),
                baselineSidecar: baselineSidecar.map(VariableRecoverySidecar.init),
                capturedSidecar: .init(replay.sidecar), baselineRecordExisted: replay.baselineRecordExisted,
                baselineHistory: replay.baselineHistory, fullChanges: replay.changes,
                initialPhysicalEvidence: replay.creationEvidence, currentPhysicalEvidence: physical,
                preparedSidecar: prepared.map(VariableRecoverySidecar.init),
                completedResult: completed.map(VariableRecoveryWriteResult.init),
                unverifiedCompletion: unverified.map(VariableRecoveryPhysicalResult.init),
                lastResult: last.map(VariableRecoveryWriteResult.init),
                jsonWasCommitted: replay.receipt.hasCommitted,
                committedRecord: replay.receipt.committedRecord.map(VariableRecoverySidecar.init),
                creationEvidenceInvalidated: replay.receipt.creationEvidenceInvalidated,
                creationMirrorCompleted: replay.receipt.creationMirrorCompleted,
                creationInstalledXMPData: replay.receipt.creationInstalledXMPData)
        }
    }

    static func capture(original: IPTCMetadata, resolved: IPTCMetadata,
        baselineSidecar: MetadataSidecar?, imageURL: URL, folderURL: URL,
        requestedMode: MetadataWriteMode, creationEvidence: MetadataSidecarReplayCreationEvidence,
        timestamp: Date = Date()
    ) throws -> Self? {
        guard resolved.cameraRaw == original.cameraRaw,
              resolved.exifOrientation == original.exifOrientation else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey:
                "Save or apply the pending Develop and rotation edits before processing variables. The captured edits were retained."])
        }
        if let baselineSidecar, baselineSidecar.sourceFile != imageURL.lastPathComponent {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        // A stale completed JSON record is not itself a variable-processing intent. Require an
        // actual transformation or captured editor/template change against the original input.
        guard !MetadataHistoryEntry.changes(from: original, to: resolved, timestamp: timestamp).isEmpty else {
            return nil
        }
        let baseline = baselineSidecar?.metadata ?? original
        let changes = MetadataHistoryEntry.changes(from: baseline, to: resolved, timestamp: timestamp)
        var history = (baselineSidecar?.history ?? []) + changes
        history.trimToHistoryLimit()
        let sidecar = MetadataSidecar(sourceFile: imageURL.lastPathComponent, pendingChanges: true,
            metadata: resolved, imageMetadataSnapshot: baselineSidecar == nil ? original : baselineSidecar?.imageMetadataSnapshot,
            history: history, orientationDraft: baselineSidecar?.orientationDraft)
        let replay = MetadataSidecarReplayRequest(sidecar: sidecar, baselineMetadata: baseline,
            baselineHistory: baselineSidecar?.history ?? [], baselineRecordExisted: baselineSidecar != nil,
            changes: changes, imageURL: imageURL, folderURL: folderURL, creationEvidence: creationEvidence)
        return Self(id: UUID(), imageURL: imageURL, folderURL: folderURL, requestedMode: requestedMode, originalMetadata: original,
            replay: replay, baselineSidecar: baselineSidecar, receipt: .init(evidence: creationEvidence))
    }
}

nonisolated struct VariableMetadataWriteResult: Sendable {
    let requestID: UUID
    let imageURL: URL
    var preparedSidecar: MetadataSidecar? = nil
    var physicalResult: PendingMetadataWriteResult? = nil
    var wasCancelled = false
    var failure: String? = nil
    var savedToHistory = false
    var committedButUnverifiedSidecarURL: URL? = nil
    var completed: Bool { !wasCancelled && failure == nil && (savedToHistory || physicalResult?.completed == true) }
}
nonisolated struct VariableMetadataWriteHooks: Sendable {
    var beforeJSONCommit: @Sendable () throws -> Void = {}
    var afterJSONCommit: @Sendable () throws -> Void = {}
    var physical = PendingMetadataWriteHooks()
}

nonisolated struct VariableMetadataWriteService: Sendable {
    private let physicalService: PendingMetadataWriteService
    private let hooks: VariableMetadataWriteHooks
    init(writeEngine: any MetadataWriteEngine,
        readSourceFacts: @escaping @Sendable (URL) async throws -> PendingMetadataSourceFacts,
        hooks: VariableMetadataWriteHooks = .init()) {
        self.physicalService = .init(writeEngine: writeEngine, readSourceFacts: readSourceFacts, hooks: hooks.physical)
        self.hooks = hooks
    }

    func execute(_ request: VariableMetadataWriteRequest) async -> VariableMetadataWriteResult {
        var result = VariableMetadataWriteResult(requestID: request.id, imageURL: request.imageURL)
        guard request.receipt.begin() else {
            result.failure = "This variable request is already being saved. Its captured values were retained."
            return result
        }
        defer { request.receipt.recordLastResult(result); request.receipt.end() }
        if let completed = request.receipt.state.2 { result = completed; return result }
        if Task.isCancelled { result.wasCancelled = true; return result }
        let service = MetadataSidecarService()
        if var unverified = request.receipt.unverifiedCompletion,
           let prepared = request.receipt.state.0 {
            result.preparedSidecar = prepared
            var expected = prepared; expected.pendingChanges = false
            do {
                let installed = try await service.verifyCompletedVariableRecord(expected,
                    evidence: request.receipt.state.1, for: request.imageURL, in: request.folderURL)
                unverified.installedSidecar = installed
                unverified.failure = nil; unverified.wasCancelled = false
                unverified.committedButUnverifiedSidecarURL = nil
                result.physicalResult = unverified
                request.receipt.finish(result)
            } catch {
                result.wasCancelled = error is CancellationError
                result.failure = result.wasCancelled ? nil : error.localizedDescription
                result.physicalResult = unverified
                result.committedButUnverifiedSidecarURL = unverified.committedButUnverifiedSidecarURL
            }
            return result
        }
        if let prepared = request.receipt.state.0 {
            result.preparedSidecar = prepared
            do { try await service.requirePreparedVariableRecord(prepared, for: request.imageURL, in: request.folderURL) }
            catch {
                result.wasCancelled = error is CancellationError
                result.failure = result.wasCancelled ? nil : error.localizedDescription
                return result
            }
        } else {
            let prepared = await service.replayHistoryToJSON(request.replay,
                expectedBaseline: request.baselineSidecar,
                requiresExactBaseline: request.requestedMode != .historyOnly || request.replay.changes.isEmpty,
                allowsEmptyPreparation: request.replay.changes.isEmpty,
                beforeJSONCommit: hooks.beforeJSONCommit, afterJSONCommit: hooks.afterJSONCommit)
            result.preparedSidecar = prepared.installedSidecar
            result.wasCancelled = prepared.wasCancelled
            result.failure = prepared.failure?.kind == .replayConflict
                ? "This variable request conflicts with newer metadata. Newer metadata was preserved, and the captured variable request remains retained."
                : prepared.failure?.message
            result.committedButUnverifiedSidecarURL = prepared.committedButUnverifiedSidecarURL
            guard prepared.completed, let installed = prepared.installedSidecar else { return result }
            request.receipt.recordPrepared(installed)
        }
        guard let prepared = result.preparedSidecar else { return result }
        if request.requestedMode == .historyOnly {
            result.savedToHistory = true
            request.receipt.finish(result)
            return result
        }
        let physical = await physicalService.execute(.init(imageURL: request.imageURL, folderURL: request.folderURL,
            expectedSidecar: prepared, skipC2PA: false, id: request.id, requestedMode: request.requestedMode,
            expectedPhysicalBaseline: request.receipt.state.1))
        result.physicalResult = physical
        result.wasCancelled = physical.wasCancelled
        result.failure = physical.failure
        result.committedButUnverifiedSidecarURL = physical.committedButUnverifiedSidecarURL
        if let baseline = physical.resultingPhysicalBaseline { request.receipt.recordPhysical(baseline) }
        if physical.committedButUnverifiedSidecarURL != nil { request.receipt.recordUnverified(physical) }

        if result.completed { request.receipt.finish(result) }
        return result
    }
}
