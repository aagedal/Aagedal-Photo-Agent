import Foundation

/// A staging result narrowed to the facts the upload phase is allowed to consume. Construction
/// revalidates the frozen plan and accepts only a wholly completed, read-back-verified batch.
/// Editorial metadata and source paths are deliberately absent.
nonisolated struct DeliveryVerifiedStagedArtifact: Equatable, Sendable {
    let itemIndex: Int
    let stageInputFingerprint: String
    let localURL: URL
    let expectedByteCount: Int64
    let expectedSHA256: String
    let renderSettings: DeliveryRenderSettings

    fileprivate init(
        itemIndex: Int,
        stageInputFingerprint: String,
        localURL: URL,
        expectedByteCount: Int64,
        expectedSHA256: String,
        renderSettings: DeliveryRenderSettings
    ) {
        self.itemIndex = itemIndex
        self.stageInputFingerprint = stageInputFingerprint
        self.localURL = localURL
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
        self.renderSettings = renderSettings
    }
}

nonisolated struct DeliveryVerifiedStagedBatch: Equatable, Sendable {
    let batchIdentifier: UUID
    let planFingerprint: String
    let artifacts: [DeliveryVerifiedStagedArtifact]

    fileprivate init(
        batchIdentifier: UUID,
        planFingerprint: String,
        artifacts: [DeliveryVerifiedStagedArtifact]
    ) {
        self.batchIdentifier = batchIdentifier
        self.planFingerprint = planFingerprint
        self.artifacts = artifacts
    }

    static func validated(
        plan: DeliveryPlan,
        stagingResult: DeliveryStagingBatchResult
    ) throws -> Self {
        do {
            try DeliveryPlanningService.validateFrozenPlan(plan)
        } catch {
            throw DeliveryUploadPreflightError.invalidPlan
        }
        guard stagingResult.planFingerprint == plan.fingerprint else {
            throw DeliveryUploadPreflightError.stagingPlanFingerprintMismatch
        }
        guard stagingResult.status == .completed else {
            throw DeliveryUploadPreflightError.stagingBatchNotCompleted
        }
        guard stagingResult.items.count == plan.items.count else {
            throw DeliveryUploadPreflightError.stagingItemCountMismatch
        }

        let directory = stagingResult.stagingDirectoryURL.standardizedFileURL
            .resolvingSymlinksInPath()
        guard directory.isFileURL else {
            throw DeliveryUploadPreflightError.unsafeStagedArtifact(itemIndex: 0)
        }

        var artifacts: [DeliveryVerifiedStagedArtifact] = []
        artifacts.reserveCapacity(plan.items.count)
        for item in plan.items {
            guard stagingResult.items.indices.contains(item.itemIndex) else {
                throw DeliveryUploadPreflightError.stagingItemCountMismatch
            }
            let staged = stagingResult.items[item.itemIndex]
            guard staged.itemIndex == item.itemIndex else {
                throw DeliveryUploadPreflightError.stagingArtifactMismatch(
                    itemIndex: item.itemIndex
                )
            }
            guard staged.stage == .verified else {
                throw DeliveryUploadPreflightError.stagedArtifactNotVerified(
                    itemIndex: item.itemIndex
                )
            }
            guard staged.stageInputFingerprint == item.stageInputFingerprint else {
                throw DeliveryUploadPreflightError.stageFingerprintDrift(
                    itemIndex: item.itemIndex
                )
            }
            let applicableVerificationFields = IPTCMetadataVerifier.applicableFields(
                plan.renderAndWrite.verificationFields,
                expected: item.resolvedMetadata
            )
            guard staged.stagedRelativePath == item.stagedRelativePath,
                  staged.checkedFields == applicableVerificationFields,
                  staged.mismatchedFields.isEmpty,
                  staged.failure == nil,
                  let byteCount = staged.stagedByteCount,
                  byteCount >= 0,
                  let stagedSHA256 = staged.stagedSHA256,
                  Self.isValidSHA256(stagedSHA256),
                  let renderSettings = staged.renderSettings,
                  let preservation = staged.metadataPreservation,
                  preservation.domains.map(\.domain) == MetadataPreservationDomain.allCases,
                  Self.isCoherentPreservationEvidence(preservation) else {
                throw DeliveryUploadPreflightError.stagingArtifactMismatch(
                    itemIndex: item.itemIndex
                )
            }

            let localURL = directory.appendingPathComponent(
                item.stagedRelativePath,
                isDirectory: false
            ).standardizedFileURL.resolvingSymlinksInPath()
            guard localURL.isFileURL,
                  localURL.deletingLastPathComponent() == directory else {
                throw DeliveryUploadPreflightError.unsafeStagedArtifact(
                    itemIndex: item.itemIndex
                )
            }
            artifacts.append(DeliveryVerifiedStagedArtifact(
                itemIndex: item.itemIndex,
                stageInputFingerprint: item.stageInputFingerprint,
                localURL: localURL,
                expectedByteCount: Int64(byteCount),
                expectedSHA256: stagedSHA256,
                renderSettings: renderSettings
            ))
        }
        return Self(
            batchIdentifier: stagingResult.batchID,
            planFingerprint: plan.fingerprint,
            artifacts: artifacts
        )
    }
}

nonisolated enum DeliveryUploadItemStage: String, Codable, Equatable, Sendable {
    case queued
    case uploading
    case remoteConfirming
    case sent
    case failed
    case cancelled
}

nonisolated enum DeliveryUploadFailureCode: String, Codable, Equatable, Sendable {
    case localArtifactInspectionFailed
    case localArtifactChanged
    case uploadRejected
    case remoteFileMissing
    case remoteByteCountMismatch
}

/// A deliberately non-diagnostic failure record. Transport errors can contain server responses,
/// usernames, or credential-bearing URLs, so arbitrary error descriptions never enter state.
nonisolated struct DeliveryUploadItemFailure: Codable, Equatable, Sendable {
    let code: DeliveryUploadFailureCode
}

nonisolated struct DeliveryUploadFileEvidence: Codable, Equatable, Sendable {
    let sha256: String
    let byteCount: Int64
}

/// Remote existence/size evidence is intentionally not named or modeled as content verification.
/// Only the local staged bytes receive a cryptographic identity.
nonisolated enum DeliveryRemoteFileConfirmation: Codable, Equatable, Sendable {
    case notRequested
    case unavailable(checkedAt: Date?)
    case missing(checkedAt: Date)
    case existsSizeUnknown(checkedAt: Date)
    case sizeMatches(checkedAt: Date, observedByteCount: Int64)
    case sizeMismatch(checkedAt: Date, observedByteCount: Int64)
}

nonisolated struct DeliveryUploadItemResult: Codable, Equatable, Sendable {
    let itemIndex: Int
    let stageInputFingerprint: String
    var stage: DeliveryUploadItemStage
    var localEvidence: DeliveryUploadFileEvidence?
    var uploadAcknowledgement: DeliveryUploadAcknowledgement
    var remoteConfirmation: DeliveryRemoteFileConfirmation
    var failure: DeliveryUploadItemFailure?
}

nonisolated enum DeliveryUploadBatchStatus: String, Codable, Equatable, Sendable {
    case completed
    case failed
    case cancelled
}

/// Persistence-safe file-boundary resume state. It contains no credentials, connection details,
/// local paths, filenames, source paths, or editorial metadata values.
nonisolated struct DeliveryUploadCheckpointItem: Codable, Equatable, Sendable {
    let itemIndex: Int
    let stageInputFingerprint: String
    let localEvidence: DeliveryUploadFileEvidence
    let uploadAcknowledgedAt: Date
    let remoteConfirmation: DeliveryRemoteFileConfirmation
}

nonisolated struct DeliveryUploadCheckpoint: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let planFingerprint: String
    let stagingBatchIdentifier: UUID
    let items: [DeliveryUploadCheckpointItem]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        planFingerprint: String,
        stagingBatchIdentifier: UUID,
        items: [DeliveryUploadCheckpointItem]
    ) {
        self.schemaVersion = schemaVersion
        self.planFingerprint = planFingerprint
        self.stagingBatchIdentifier = stagingBatchIdentifier
        self.items = items
    }
}

nonisolated struct DeliveryUploadBatchResult: Codable, Equatable, Sendable {
    let batchIdentifier: UUID
    let planFingerprint: String
    let status: DeliveryUploadBatchStatus
    let items: [DeliveryUploadItemResult]
    let checkpoint: DeliveryUploadCheckpoint

    var sentItemCount: Int { items.count { $0.stage == .sent } }
}

nonisolated struct DeliveryUploadProgress: Equatable, Sendable {
    let batchIdentifier: UUID
    let planFingerprint: String
    let currentItemIndex: Int?
    let items: [DeliveryUploadItemResult]
}

nonisolated enum DeliveryRemoteStatPolicy: String, Codable, Equatable, Sendable {
    case notRequested
    case attemptIfAvailable
}

nonisolated struct DeliveryUploadRequest: Sendable {
    let plan: DeliveryPlan
    let expectedPlanFingerprint: String
    let stagedBatch: DeliveryVerifiedStagedBatch
    let remoteStatPolicy: DeliveryRemoteStatPolicy
    let resumeCheckpoint: DeliveryUploadCheckpoint?

    init(
        plan: DeliveryPlan,
        expectedPlanFingerprint: String? = nil,
        stagedBatch: DeliveryVerifiedStagedBatch,
        remoteStatPolicy: DeliveryRemoteStatPolicy = .notRequested,
        resumeCheckpoint: DeliveryUploadCheckpoint? = nil
    ) {
        self.plan = plan
        self.expectedPlanFingerprint = expectedPlanFingerprint ?? plan.fingerprint
        self.stagedBatch = stagedBatch
        self.remoteStatPolicy = remoteStatPolicy
        self.resumeCheckpoint = resumeCheckpoint
    }
}

/// The transport sees only an opaque connection identifier, resolved remote directory, one local
/// staged URL, and its output filename. Credential lookup remains wholly inside an implementation.
nonisolated struct DeliveryUploadTransfer: Equatable, Sendable {
    let connectionIdentifier: String
    let remoteDirectory: String
    let outputFilename: String
    let localURL: URL
    let expectedByteCount: Int64
    let expectedSHA256: String
}

nonisolated enum DeliveryRemoteStatObservation: Equatable, Sendable {
    case unavailable
    case missing
    case exists(byteCount: Int64?)
}

nonisolated struct DeliveryUploadTransport: Sendable {
    let upload: @Sendable (DeliveryUploadTransfer) async throws -> Void
    let remoteStat: (@Sendable (DeliveryUploadTransfer) async throws
        -> DeliveryRemoteStatObservation)?

    init(
        upload: @escaping @Sendable (DeliveryUploadTransfer) async throws -> Void,
        remoteStat: (@Sendable (DeliveryUploadTransfer) async throws
            -> DeliveryRemoteStatObservation)? = nil
    ) {
        self.upload = upload
        self.remoteStat = remoteStat
    }
}

nonisolated struct DeliveryUploadFileInspector: Sendable {
    let inspect: @Sendable (URL) async throws -> DeliveryUploadFileEvidence

    static let live = Self { url in
        let before = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard before.isRegularFile == true, let firstSize = before.fileSize, firstSize >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let digest = try await HashStream.hashFile(at: url).lowercaseHexString
        let after = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard after.isRegularFile == true, after.fileSize == firstSize else {
            throw DeliveryUploadInternalInspectionError.fileChangedDuringInspection
        }
        return DeliveryUploadFileEvidence(sha256: digest, byteCount: Int64(firstSize))
    }
}

nonisolated enum DeliveryUploadPreflightError: Error, Equatable, LocalizedError, Sendable {
    case invalidPlan
    case planFingerprintDrift
    case stagingPlanFingerprintMismatch
    case stagingBatchNotCompleted
    case stagingItemCountMismatch
    case stagedArtifactNotVerified(itemIndex: Int)
    case stagingArtifactMismatch(itemIndex: Int)
    case stageFingerprintDrift(itemIndex: Int)
    case unsafeStagedArtifact(itemIndex: Int)
    case artifactInspectionFailed(itemIndex: Int)
    case artifactEvidenceMismatch(itemIndex: Int)
    case staleResumeCheckpoint
    case invalidResumeCheckpoint
    case alreadyExecuting

    var errorDescription: String? {
        switch self {
        case .invalidPlan: "The frozen delivery plan is invalid or has been modified."
        case .planFingerprintDrift: "The delivery plan changed after confirmation."
        case .stagingPlanFingerprintMismatch: "The staged batch belongs to another delivery plan."
        case .stagingBatchNotCompleted: "Every staged item must be verified before upload."
        case .stagingItemCountMismatch: "The staged item count does not match the delivery plan."
        case let .stagedArtifactNotVerified(index):
            "Staged delivery item \(index) has not passed read-back verification."
        case let .stagingArtifactMismatch(index):
            "Staged delivery item \(index) does not match the frozen plan."
        case let .stageFingerprintDrift(index):
            "Staged delivery item \(index) has a stale input fingerprint."
        case let .unsafeStagedArtifact(index):
            "Staged delivery item \(index) is outside the verified staging directory."
        case let .artifactInspectionFailed(index):
            "Staged delivery item \(index) could not be inspected."
        case let .artifactEvidenceMismatch(index):
            "Staged delivery item \(index) changed after read-back verification."
        case .staleResumeCheckpoint: "The upload checkpoint belongs to another plan or staging batch."
        case .invalidResumeCheckpoint: "The upload checkpoint is invalid or has been modified."
        case .alreadyExecuting: "This upload coordinator is already executing a batch."
        }
    }
}

private nonisolated enum DeliveryUploadInternalInspectionError: Error {
    case fileChangedDuringInspection
}

/// Sequential verified upload orchestration. Cancellation is observed only before the first file
/// or after a file has completed upload and optional remote-stat inspection. In-flight transport
/// work runs in an unstructured task so cancellation of the caller cannot interrupt a file.
///
/// There is intentionally no `FTPService` adapter here: its current API accepts a password at the
/// call site and terminates curl on task cancellation. A production adapter must resolve secrets
/// internally and preserve this coordinator's file-boundary cancellation guarantee.
actor VerifiedDeliveryUploadCoordinator {
    typealias ProgressHandler = @Sendable (DeliveryUploadProgress) async -> Void

    private let transport: DeliveryUploadTransport
    private let fileInspector: DeliveryUploadFileInspector
    private let now: @Sendable () -> Date
    private var cancellationRequested = false
    private var isExecuting = false

    init(
        transport: DeliveryUploadTransport,
        fileInspector: DeliveryUploadFileInspector = .live,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.fileInspector = fileInspector
        self.now = now
    }

    /// Requests a stop at the next file boundary. The active upload/stat operation is never
    /// cancelled, avoiding an ambiguous partially written remote object.
    func requestCancellation() {
        cancellationRequested = true
    }

    func upload(
        _ request: DeliveryUploadRequest,
        progress: ProgressHandler? = nil
    ) async throws -> DeliveryUploadBatchResult {
        guard !isExecuting else { throw DeliveryUploadPreflightError.alreadyExecuting }
        isExecuting = true
        cancellationRequested = false
        defer { isExecuting = false }

        let evidence = try await validateAndInspect(request)
        var results = request.plan.items.map {
            DeliveryUploadItemResult(
                itemIndex: $0.itemIndex,
                stageInputFingerprint: $0.stageInputFingerprint,
                stage: .queued,
                localEvidence: evidence[$0.itemIndex],
                uploadAcknowledgement: DeliveryUploadAcknowledgement(status: .notAttempted),
                remoteConfirmation: .notRequested,
                failure: nil
            )
        }
        try applyResumeCheckpoint(request.resumeCheckpoint, request: request, results: &results)
        await publish(progress, request: request, currentItemIndex: nil, results: results)

        for item in request.plan.items where results[item.itemIndex].stage != .sent {
            if cancellationRequested || Task.isCancelled {
                cancelQueuedItems(&results)
                await publish(
                    progress,
                    request: request,
                    currentItemIndex: nil,
                    results: results
                )
                return result(.cancelled, request: request, results: results)
            }

            let index = item.itemIndex
            let artifact = request.stagedBatch.artifacts[index]
            let originalEvidence = evidence[index]
            let freshEvidence: DeliveryUploadFileEvidence
            do {
                freshEvidence = try await fileInspector.inspect(artifact.localURL)
            } catch {
                results[index].stage = .failed
                results[index].failure = DeliveryUploadItemFailure(
                    code: .localArtifactInspectionFailed
                )
                await publish(progress, request: request, currentItemIndex: index, results: results)
                return result(.failed, request: request, results: results)
            }
            if cancellationRequested || Task.isCancelled {
                cancelQueuedItems(&results)
                await publish(
                    progress,
                    request: request,
                    currentItemIndex: nil,
                    results: results
                )
                return result(.cancelled, request: request, results: results)
            }
            guard freshEvidence == originalEvidence,
                  freshEvidence.byteCount == artifact.expectedByteCount,
                  freshEvidence.sha256 == artifact.expectedSHA256 else {
                results[index].stage = .failed
                results[index].failure = DeliveryUploadItemFailure(code: .localArtifactChanged)
                await publish(progress, request: request, currentItemIndex: index, results: results)
                return result(.failed, request: request, results: results)
            }

            let transfer = DeliveryUploadTransfer(
                connectionIdentifier: request.plan.destination.connectionIdentifier,
                remoteDirectory: request.plan.destination.resolvedRemotePath,
                outputFilename: item.outputFilename,
                localURL: artifact.localURL,
                expectedByteCount: freshEvidence.byteCount,
                expectedSHA256: freshEvidence.sha256
            )
            results[index].stage = .uploading
            await publish(progress, request: request, currentItemIndex: index, results: results)

            do {
                try await runUncancelled { [transport] in
                    try await transport.upload(transfer)
                }
            } catch {
                results[index].stage = .failed
                results[index].failure = DeliveryUploadItemFailure(code: .uploadRejected)
                await publish(progress, request: request, currentItemIndex: index, results: results)
                return result(.failed, request: request, results: results)
            }
            results[index].uploadAcknowledgement = DeliveryUploadAcknowledgement(
                status: .protocolAcknowledged,
                acknowledgedAt: now()
            )

            if request.remoteStatPolicy == .attemptIfAvailable {
                results[index].stage = .remoteConfirming
                await publish(progress, request: request, currentItemIndex: index, results: results)
                let checkedAt = now()
                let observation: DeliveryRemoteStatObservation
                if let remoteStat = transport.remoteStat {
                    do {
                        observation = try await runUncancelled {
                            try await remoteStat(transfer)
                        }
                    } catch {
                        observation = .unavailable
                    }
                } else {
                    observation = .unavailable
                }
                switch observation {
                case .unavailable:
                    results[index].remoteConfirmation = .unavailable(checkedAt: checkedAt)
                case .missing:
                    results[index].remoteConfirmation = .missing(checkedAt: checkedAt)
                    results[index].stage = .failed
                    results[index].failure = DeliveryUploadItemFailure(code: .remoteFileMissing)
                    await publish(
                        progress,
                        request: request,
                        currentItemIndex: index,
                        results: results
                    )
                    return result(.failed, request: request, results: results)
                case .exists(byteCount: nil):
                    results[index].remoteConfirmation = .existsSizeUnknown(checkedAt: checkedAt)
                case let .exists(byteCount: .some(observed)) where observed == freshEvidence.byteCount:
                    results[index].remoteConfirmation = .sizeMatches(
                        checkedAt: checkedAt,
                        observedByteCount: observed
                    )
                case let .exists(byteCount: .some(observed)):
                    results[index].remoteConfirmation = .sizeMismatch(
                        checkedAt: checkedAt,
                        observedByteCount: observed
                    )
                    results[index].stage = .failed
                    results[index].failure = DeliveryUploadItemFailure(
                        code: .remoteByteCountMismatch
                    )
                    await publish(
                        progress,
                        request: request,
                        currentItemIndex: index,
                        results: results
                    )
                    return result(.failed, request: request, results: results)
                }
            }

            results[index].stage = .sent
            await publish(progress, request: request, currentItemIndex: index, results: results)
        }

        return result(.completed, request: request, results: results)
    }

    private func validateAndInspect(
        _ request: DeliveryUploadRequest
    ) async throws -> [DeliveryUploadFileEvidence] {
        do {
            try DeliveryPlanningService.validateFrozenPlan(request.plan)
        } catch {
            throw DeliveryUploadPreflightError.invalidPlan
        }
        guard request.plan.fingerprint == request.expectedPlanFingerprint else {
            throw DeliveryUploadPreflightError.planFingerprintDrift
        }
        guard request.stagedBatch.planFingerprint == request.plan.fingerprint else {
            throw DeliveryUploadPreflightError.stagingPlanFingerprintMismatch
        }
        guard request.stagedBatch.artifacts.count == request.plan.items.count else {
            throw DeliveryUploadPreflightError.stagingItemCountMismatch
        }

        var evidence: [DeliveryUploadFileEvidence] = []
        evidence.reserveCapacity(request.plan.items.count)
        for item in request.plan.items {
            try checkCancellation()
            guard request.stagedBatch.artifacts.indices.contains(item.itemIndex) else {
                throw DeliveryUploadPreflightError.stagingItemCountMismatch
            }
            let artifact = request.stagedBatch.artifacts[item.itemIndex]
            guard artifact.itemIndex == item.itemIndex else {
                throw DeliveryUploadPreflightError.stagingArtifactMismatch(
                    itemIndex: item.itemIndex
                )
            }
            guard artifact.stageInputFingerprint == item.stageInputFingerprint else {
                throw DeliveryUploadPreflightError.stageFingerprintDrift(
                    itemIndex: item.itemIndex
                )
            }
            let inspected: DeliveryUploadFileEvidence
            do {
                inspected = try await fileInspector.inspect(artifact.localURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DeliveryUploadPreflightError.artifactInspectionFailed(
                    itemIndex: item.itemIndex
                )
            }
            // Initial inspection is a file boundary just like the fresh inspection immediately
            // before transfer. Large batches must not finish hashing every queued artifact after
            // an explicit stop has already been requested.
            try checkCancellation()
            guard inspected.byteCount == artifact.expectedByteCount,
                  inspected.sha256 == artifact.expectedSHA256 else {
                throw DeliveryUploadPreflightError.artifactEvidenceMismatch(
                    itemIndex: item.itemIndex
                )
            }
            evidence.append(inspected)
        }
        return evidence
    }

    private func checkCancellation() throws {
        guard !cancellationRequested, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func applyResumeCheckpoint(
        _ checkpoint: DeliveryUploadCheckpoint?,
        request: DeliveryUploadRequest,
        results: inout [DeliveryUploadItemResult]
    ) throws {
        guard let checkpoint else { return }
        guard checkpoint.schemaVersion == DeliveryUploadCheckpoint.currentSchemaVersion else {
            throw DeliveryUploadPreflightError.invalidResumeCheckpoint
        }
        guard checkpoint.planFingerprint == request.plan.fingerprint,
              checkpoint.stagingBatchIdentifier == request.stagedBatch.batchIdentifier else {
            throw DeliveryUploadPreflightError.staleResumeCheckpoint
        }
        guard checkpoint.items.map(\.itemIndex) == Array(checkpoint.items.indices),
              zip(checkpoint.items, checkpoint.items.dropFirst()).allSatisfy({ pair in
                  pair.0.uploadAcknowledgedAt <= pair.1.uploadAcknowledgedAt
              }) else {
            throw DeliveryUploadPreflightError.invalidResumeCheckpoint
        }

        for saved in checkpoint.items {
            guard results.indices.contains(saved.itemIndex) else {
                throw DeliveryUploadPreflightError.invalidResumeCheckpoint
            }
            let current = results[saved.itemIndex]
            guard saved.stageInputFingerprint == current.stageInputFingerprint,
                  saved.localEvidence == current.localEvidence,
                  Self.isValidSHA256(saved.localEvidence.sha256),
                  saved.localEvidence.byteCount >= 0,
                  Self.isSuccessfulRemoteConfirmation(saved.remoteConfirmation),
                  Self.hasCoherentTimestamp(
                      saved.remoteConfirmation,
                      uploadAcknowledgedAt: saved.uploadAcknowledgedAt
                  ) else {
                throw DeliveryUploadPreflightError.invalidResumeCheckpoint
            }
            results[saved.itemIndex].stage = .sent
            results[saved.itemIndex].uploadAcknowledgement = DeliveryUploadAcknowledgement(
                status: .protocolAcknowledged,
                acknowledgedAt: saved.uploadAcknowledgedAt
            )
            results[saved.itemIndex].remoteConfirmation = saved.remoteConfirmation
        }
    }

    private func cancelQueuedItems(_ results: inout [DeliveryUploadItemResult]) {
        for index in results.indices where results[index].stage == .queued {
            results[index].stage = .cancelled
        }
    }

    private func publish(
        _ handler: ProgressHandler?,
        request: DeliveryUploadRequest,
        currentItemIndex: Int?,
        results: [DeliveryUploadItemResult]
    ) async {
        guard let handler else { return }
        await handler(DeliveryUploadProgress(
            batchIdentifier: request.stagedBatch.batchIdentifier,
            planFingerprint: request.plan.fingerprint,
            currentItemIndex: currentItemIndex,
            items: results
        ))
    }

    private func result(
        _ status: DeliveryUploadBatchStatus,
        request: DeliveryUploadRequest,
        results: [DeliveryUploadItemResult]
    ) -> DeliveryUploadBatchResult {
        let savedItems = results.compactMap { item -> DeliveryUploadCheckpointItem? in
            guard item.stage == .sent,
                  let localEvidence = item.localEvidence,
                  item.uploadAcknowledgement.status == .protocolAcknowledged,
                  let acknowledgedAt = item.uploadAcknowledgement.acknowledgedAt else {
                return nil
            }
            return DeliveryUploadCheckpointItem(
                itemIndex: item.itemIndex,
                stageInputFingerprint: item.stageInputFingerprint,
                localEvidence: localEvidence,
                uploadAcknowledgedAt: acknowledgedAt,
                remoteConfirmation: item.remoteConfirmation
            )
        }
        return DeliveryUploadBatchResult(
            batchIdentifier: request.stagedBatch.batchIdentifier,
            planFingerprint: request.plan.fingerprint,
            status: status,
            items: results,
            checkpoint: DeliveryUploadCheckpoint(
                planFingerprint: request.plan.fingerprint,
                stagingBatchIdentifier: request.stagedBatch.batchIdentifier,
                items: savedItems
            )
        )
    }

    private func runUncancelled<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Task.detached(priority: nil) {
            try await operation()
        }.value
    }

    private nonisolated static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private nonisolated static func isSuccessfulRemoteConfirmation(
        _ confirmation: DeliveryRemoteFileConfirmation
    ) -> Bool {
        switch confirmation {
        case .notRequested, .unavailable, .existsSizeUnknown, .sizeMatches: true
        case .missing, .sizeMismatch: false
        }
    }

    private nonisolated static func hasCoherentTimestamp(
        _ confirmation: DeliveryRemoteFileConfirmation,
        uploadAcknowledgedAt: Date
    ) -> Bool {
        switch confirmation {
        case .notRequested: true
        case let .unavailable(checkedAt: .some(checkedAt)),
             let .missing(checkedAt),
             let .existsSizeUnknown(checkedAt),
             let .sizeMatches(checkedAt, _),
             let .sizeMismatch(checkedAt, _):
            checkedAt >= uploadAcknowledgedAt
        case .unavailable(checkedAt: nil): false
        }
    }
}

private extension DeliveryVerifiedStagedBatch {
    nonisolated static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    /// Status labels alone are not terminal evidence. A persisted or imported staging result must
    /// retain the equal semantic identities behind every claimed match before upload can consume
    /// it. Explicitly unsupported carrier domains have no identities by construction.
    nonisolated static func isCoherentPreservationEvidence(
        _ report: MetadataPreservationVerificationReport
    ) -> Bool {
        guard report.isAcceptableForDelivery else { return false }
        return report.domains.allSatisfy { result in
            switch result.status {
            case .match:
                guard let sourceIdentity = result.sourceIdentity,
                      let stagedIdentity = result.stagedIdentity else { return false }
                return sourceIdentity == stagedIdentity && isValidSHA256(sourceIdentity)
            case .unsupported:
                return result.sourceIdentity == nil && result.stagedIdentity == nil
            case .mismatch, .unknown:
                return false
            }
        }
    }
}
