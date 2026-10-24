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
    let voiceMemo: DeliveryVerifiedStagedVoiceMemo?

    fileprivate init(
        itemIndex: Int,
        stageInputFingerprint: String,
        localURL: URL,
        expectedByteCount: Int64,
        expectedSHA256: String,
        renderSettings: DeliveryRenderSettings,
        voiceMemo: DeliveryVerifiedStagedVoiceMemo? = nil
    ) {
        self.itemIndex = itemIndex
        self.stageInputFingerprint = stageInputFingerprint
        self.localURL = localURL
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
        self.renderSettings = renderSettings
        self.voiceMemo = voiceMemo
    }
}

nonisolated struct DeliveryVerifiedStagedVoiceMemo: Equatable, Sendable {
    let outputFilename: String
    let localURL: URL
    let expectedByteCount: Int64
    let expectedSHA256: String
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
                renderSettings: renderSettings,
                voiceMemo: try validatedVoiceMemo(
                    planItem: item,
                    stagedItem: staged,
                    directory: directory
                )
            ))
        }
        return Self(
            batchIdentifier: stagingResult.batchID,
            planFingerprint: plan.fingerprint,
            artifacts: artifacts
        )
    }

    private static func validatedVoiceMemo(
        planItem: DeliveryPlanStageItem,
        stagedItem: DeliveryStagingItemResult,
        directory: URL
    ) throws -> DeliveryVerifiedStagedVoiceMemo? {
        guard let planned = planItem.voiceMemo else {
            guard stagedItem.voiceMemoStagedRelativePath == nil,
                  stagedItem.voiceMemoStagedByteCount == nil,
                  stagedItem.voiceMemoStagedSHA256 == nil else {
                throw DeliveryUploadPreflightError.stagingArtifactMismatch(
                    itemIndex: planItem.itemIndex
                )
            }
            return nil
        }
        guard stagedItem.voiceMemoStagedRelativePath == planned.stagedRelativePath,
              let byteCount = stagedItem.voiceMemoStagedByteCount,
              Int64(byteCount) == planned.sourceRevision.byteCount,
              let sha256 = stagedItem.voiceMemoStagedSHA256,
              sha256 == planned.sourceRevision.sha256,
              isValidSHA256(sha256) else {
            throw DeliveryUploadPreflightError.stagingArtifactMismatch(itemIndex: planItem.itemIndex)
        }
        let localURL = directory.appendingPathComponent(
            planned.stagedRelativePath,
            isDirectory: false
        ).standardizedFileURL.resolvingSymlinksInPath()
        guard localURL.isFileURL, localURL.deletingLastPathComponent() == directory else {
            throw DeliveryUploadPreflightError.unsafeStagedArtifact(itemIndex: planItem.itemIndex)
        }
        return DeliveryVerifiedStagedVoiceMemo(
            outputFilename: planned.outputFilename,
            localURL: localURL,
            expectedByteCount: Int64(byteCount),
            expectedSHA256: sha256
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
    /// The server rejected this file (or the transfer broke); other files may still succeed.
    case uploadRejected
    /// Retained for decoding older results; a missing remote file after an acknowledged
    /// upload is now recorded as "sent, not visible" rather than as a failure.
    case remoteFileMissing
    case remoteByteCountMismatch
    // Fixed transfer categories (never server output). The server-level ones stop the batch.
    case connectionUnavailable
    case loginDenied
    case accessDenied
    case serverUnreachable
    case ftpsUnsupported
    case certificateUntrusted
    case secureConnectionFailed
    case timedOut

    /// True when every remaining file would fail the same way, so the batch stops here instead
    /// of retrying each file (and, for logins, risking a lockout).
    var isServerLevel: Bool {
        switch self {
        case .connectionUnavailable, .loginDenied, .accessDenied, .serverUnreachable,
             .ftpsUnsupported, .certificateUntrusted, .secureConnectionFailed:
            true
        case .localArtifactInspectionFailed, .localArtifactChanged, .uploadRejected,
             .remoteFileMissing, .remoteByteCountMismatch, .timedOut:
            false
        }
    }

    var userMessage: String {
        switch self {
        case .localArtifactInspectionFailed: "The staged file could not be read."
        case .localArtifactChanged: "The staged file changed after verification."
        case .uploadRejected: FTPFailureCategory.fileRejected.userMessage
        case .remoteFileMissing: "The file was not visible on the server after upload."
        case .remoteByteCountMismatch: "The file size on the server doesn't match the delivered file."
        case .connectionUnavailable: "The saved delivery connection or its password is unavailable."
        case .loginDenied: FTPFailureCategory.loginDenied.userMessage
        case .accessDenied: FTPFailureCategory.accessDenied.userMessage
        case .serverUnreachable: FTPFailureCategory.serverUnreachable.userMessage
        case .ftpsUnsupported: FTPFailureCategory.ftpsUnsupported.userMessage
        case .certificateUntrusted: FTPFailureCategory.certificateUntrusted.userMessage
        case .secureConnectionFailed: FTPFailureCategory.secureConnectionFailed.userMessage
        case .timedOut: FTPFailureCategory.timedOut.userMessage
        }
    }

    /// Maps a transport error to its fixed code. Unknown errors are file-level rejections.
    init(transportError error: any Error) {
        guard let transportError = error as? DeliveryFTPTransportError else {
            self = .uploadRejected
            return
        }
        switch transportError {
        case .invalidConnectionIdentifier, .connectionUnavailable, .credentialUnavailable,
             .insecureTransportNotAcknowledged:
            self = .connectionUnavailable
        case .loginDenied: self = .loginDenied
        case .accessDenied: self = .accessDenied
        case .serverUnreachable: self = .serverUnreachable
        case .ftpsUnsupported: self = .ftpsUnsupported
        case .certificateUntrusted: self = .certificateUntrusted
        case .secureConnectionFailed: self = .secureConnectionFailed
        case .timedOut: self = .timedOut
        case .unsafeTransfer, .uploadFailed, .remoteObservationUnavailable, .fileRejected:
            self = .uploadRejected
        }
    }
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
    var voiceMemoLocalEvidence: DeliveryUploadFileEvidence? = nil
    var voiceMemoUploadAcknowledgement: DeliveryUploadAcknowledgement? = nil
    var voiceMemoRemoteConfirmation: DeliveryRemoteFileConfirmation? = nil
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
    let voiceMemoLocalEvidence: DeliveryUploadFileEvidence?
    let voiceMemoUploadAcknowledgedAt: Date?
    let voiceMemoRemoteConfirmation: DeliveryRemoteFileConfirmation?

    init(
        itemIndex: Int,
        stageInputFingerprint: String,
        localEvidence: DeliveryUploadFileEvidence,
        uploadAcknowledgedAt: Date,
        remoteConfirmation: DeliveryRemoteFileConfirmation,
        voiceMemoLocalEvidence: DeliveryUploadFileEvidence? = nil,
        voiceMemoUploadAcknowledgedAt: Date? = nil,
        voiceMemoRemoteConfirmation: DeliveryRemoteFileConfirmation? = nil
    ) {
        self.itemIndex = itemIndex
        self.stageInputFingerprint = stageInputFingerprint
        self.localEvidence = localEvidence
        self.uploadAcknowledgedAt = uploadAcknowledgedAt
        self.remoteConfirmation = remoteConfirmation
        self.voiceMemoLocalEvidence = voiceMemoLocalEvidence
        self.voiceMemoUploadAcknowledgedAt = voiceMemoUploadAcknowledgedAt
        self.voiceMemoRemoteConfirmation = voiceMemoRemoteConfirmation
    }
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

private nonisolated struct DeliveryUploadArtifactEvidence: Sendable {
    let image: DeliveryUploadFileEvidence
    let voiceMemo: DeliveryUploadFileEvidence?
}

/// Sequential verified upload orchestration.
///
/// Failures are classified per file: a file-level failure (the server rejected one file, a
/// transfer stalled, a staged file changed) marks that item failed and the batch continues;
/// a server-level failure (login denied, TLS refused, server unreachable after retries,
/// unusable connection) stops the batch because every remaining file would fail the same way.
/// Every delivered item is checkpointed — not just a contiguous prefix — so Resume skips
/// exactly the delivered items and re-sends only the failed or unattempted ones.
///
/// Cancellation stops at the next file boundary and also terminates the active transfer:
/// the transport uploads to a temporary name and renames only after a complete transfer, so
/// interrupting it can't leave a truncated file under the final name.
actor VerifiedDeliveryUploadCoordinator {
    typealias ProgressHandler = @Sendable (DeliveryUploadProgress) async -> Void

    private let transport: DeliveryUploadTransport
    private let fileInspector: DeliveryUploadFileInspector
    private let now: @Sendable () -> Date
    private var cancellationRequested = false
    private var isExecuting = false
    private var activeTransfer: Task<Void, any Error>?

    init(
        transport: DeliveryUploadTransport,
        fileInspector: DeliveryUploadFileInspector = .live,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.fileInspector = fileInspector
        self.now = now
    }

    /// Requests a stop: no further file starts, and an active transfer is terminated (the
    /// transport cleans up its temporary remote file). A transfer that completes anyway is
    /// recorded as sent.
    func requestCancellation() {
        cancellationRequested = true
        activeTransfer?.cancel()
    }

    private enum FileStep {
        case delivered
        case failed(DeliveryUploadFailureCode)
        case cancelled
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
                localEvidence: evidence[$0.itemIndex].image,
                uploadAcknowledgement: DeliveryUploadAcknowledgement(status: .notAttempted),
                remoteConfirmation: .notRequested,
                failure: nil,
                voiceMemoLocalEvidence: evidence[$0.itemIndex].voiceMemo,
                voiceMemoUploadAcknowledgement: evidence[$0.itemIndex].voiceMemo == nil
                    ? nil : DeliveryUploadAcknowledgement(status: .notAttempted),
                voiceMemoRemoteConfirmation: evidence[$0.itemIndex].voiceMemo == nil
                    ? nil : .notRequested
            )
        }
        try applyResumeCheckpoint(request.resumeCheckpoint, request: request, results: &results)
        await publish(progress, request: request, currentItemIndex: nil, results: results)

        var anyItemFailed = false
        for item in request.plan.items where results[item.itemIndex].stage != .sent {
            if cancellationRequested || Task.isCancelled {
                cancelQueuedItems(&results)
                await publish(progress, request: request, currentItemIndex: nil, results: results)
                return result(anyItemFailed ? .failed : .cancelled, request: request, results: results)
            }

            let index = item.itemIndex
            let artifact = request.stagedBatch.artifacts[index]

            let freshEvidence: DeliveryUploadFileEvidence
            do {
                freshEvidence = try await fileInspector.inspect(artifact.localURL)
            } catch {
                anyItemFailed = true
                if await markFailed(.localArtifactInspectionFailed, index: index, request: request, progress: progress, results: &results) {
                    return result(.failed, request: request, results: results)
                }
                continue
            }
            if cancellationRequested || Task.isCancelled {
                cancelQueuedItems(&results)
                await publish(progress, request: request, currentItemIndex: nil, results: results)
                return result(anyItemFailed ? .failed : .cancelled, request: request, results: results)
            }
            guard freshEvidence == evidence[index].image,
                  freshEvidence.byteCount == artifact.expectedByteCount,
                  freshEvidence.sha256 == artifact.expectedSHA256 else {
                anyItemFailed = true
                if await markFailed(.localArtifactChanged, index: index, request: request, progress: progress, results: &results) {
                    return result(.failed, request: request, results: results)
                }
                continue
            }

            let transfer = DeliveryUploadTransfer(
                connectionIdentifier: request.plan.destination.connectionIdentifier,
                remoteDirectory: request.plan.destination.resolvedRemotePath,
                outputFilename: item.outputFilename,
                localURL: artifact.localURL,
                expectedByteCount: freshEvidence.byteCount,
                expectedSHA256: freshEvidence.sha256
            )
            switch await deliverFile(
                transfer,
                index: index,
                isVoiceMemo: false,
                request: request,
                progress: progress,
                results: &results
            ) {
            case .delivered:
                break
            case .cancelled:
                results[index].stage = .cancelled
                cancelQueuedItems(&results)
                await publish(progress, request: request, currentItemIndex: index, results: results)
                return result(anyItemFailed ? .failed : .cancelled, request: request, results: results)
            case let .failed(code):
                anyItemFailed = true
                if await markFailed(code, index: index, request: request, progress: progress, results: &results) { return result(.failed, request: request, results: results) }
                continue
            }

            if let memo = artifact.voiceMemo,
               let originalMemoEvidence = evidence[index].voiceMemo {
                if cancellationRequested || Task.isCancelled {
                    results[index].stage = .cancelled
                    cancelQueuedItems(&results)
                    await publish(progress, request: request, currentItemIndex: index, results: results)
                    return result(anyItemFailed ? .failed : .cancelled, request: request, results: results)
                }
                let freshMemoEvidence: DeliveryUploadFileEvidence
                do {
                    freshMemoEvidence = try await fileInspector.inspect(memo.localURL)
                } catch {
                    anyItemFailed = true
                    if await markFailed(.localArtifactInspectionFailed, index: index, request: request, progress: progress, results: &results) {
                        return result(.failed, request: request, results: results)
                    }
                    continue
                }
                guard freshMemoEvidence == originalMemoEvidence,
                      freshMemoEvidence.byteCount == memo.expectedByteCount,
                      freshMemoEvidence.sha256 == memo.expectedSHA256 else {
                    anyItemFailed = true
                    if await markFailed(.localArtifactChanged, index: index, request: request, progress: progress, results: &results) {
                        return result(.failed, request: request, results: results)
                    }
                    continue
                }
                let memoTransfer = DeliveryUploadTransfer(
                    connectionIdentifier: request.plan.destination.connectionIdentifier,
                    remoteDirectory: request.plan.destination.resolvedRemotePath,
                    outputFilename: memo.outputFilename,
                    localURL: memo.localURL,
                    expectedByteCount: freshMemoEvidence.byteCount,
                    expectedSHA256: freshMemoEvidence.sha256
                )
                switch await deliverFile(
                    memoTransfer,
                    index: index,
                    isVoiceMemo: true,
                    request: request,
                    progress: progress,
                    results: &results
                ) {
                case .delivered:
                    break
                case .cancelled:
                    results[index].stage = .cancelled
                    cancelQueuedItems(&results)
                    await publish(progress, request: request, currentItemIndex: index, results: results)
                    return result(anyItemFailed ? .failed : .cancelled, request: request, results: results)
                case let .failed(code):
                    anyItemFailed = true
                    if await markFailed(code, index: index, request: request, progress: progress, results: &results) { return result(.failed, request: request, results: results) }
                    continue
                }
            }

            results[index].stage = .sent
            await publish(progress, request: request, currentItemIndex: index, results: results)
        }

        return result(anyItemFailed ? .failed : .completed, request: request, results: results)
    }

    /// Marks an item failed and publishes it; returns true when the batch must stop here.
    private func markFailed(
        _ code: DeliveryUploadFailureCode,
        index: Int,
        request: DeliveryUploadRequest,
        progress: ProgressHandler?,
        results: inout [DeliveryUploadItemResult]
    ) async -> Bool {
        results[index].stage = .failed
        results[index].failure = DeliveryUploadItemFailure(code: code)
        await publish(progress, request: request, currentItemIndex: index, results: results)
        return code.isServerLevel
    }

    /// Uploads one file and, when requested, observes it remotely. A remote "missing" after a
    /// protocol-acknowledged STOR (and rename) is recorded as sent-but-not-visible: write-only
    /// drop boxes can't be listed and hot folders move files away instantly, so treating it as
    /// a failure would make Resume upload the item twice.
    private func deliverFile(
        _ transfer: DeliveryUploadTransfer,
        index: Int,
        isVoiceMemo: Bool,
        request: DeliveryUploadRequest,
        progress: ProgressHandler?,
        results: inout [DeliveryUploadItemResult]
    ) async -> FileStep {
        results[index].stage = .uploading
        await publish(progress, request: request, currentItemIndex: index, results: results)

        do {
            try await runCancellableTransfer { [transport] in
                try await transport.upload(transfer)
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(DeliveryUploadFailureCode(transportError: error))
        }
        let acknowledgement = DeliveryUploadAcknowledgement(
            status: .protocolAcknowledged,
            acknowledgedAt: now()
        )
        if isVoiceMemo {
            results[index].voiceMemoUploadAcknowledgement = acknowledgement
        } else {
            results[index].uploadAcknowledgement = acknowledgement
        }

        guard request.remoteStatPolicy == .attemptIfAvailable else { return .delivered }
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

        let confirmation: DeliveryRemoteFileConfirmation
        var failure: DeliveryUploadFailureCode?
        switch observation {
        case .unavailable:
            confirmation = .unavailable(checkedAt: checkedAt)
        case .missing:
            confirmation = .missing(checkedAt: checkedAt)
        case .exists(byteCount: nil):
            confirmation = .existsSizeUnknown(checkedAt: checkedAt)
        case let .exists(byteCount: .some(observed)) where observed == transfer.expectedByteCount:
            confirmation = .sizeMatches(checkedAt: checkedAt, observedByteCount: observed)
        case let .exists(byteCount: .some(observed)):
            confirmation = .sizeMismatch(checkedAt: checkedAt, observedByteCount: observed)
            failure = .remoteByteCountMismatch
        }
        if isVoiceMemo {
            results[index].voiceMemoRemoteConfirmation = confirmation
        } else {
            results[index].remoteConfirmation = confirmation
        }
        if let failure { return .failed(failure) }
        return .delivered
    }

    /// Runs one transfer so that `requestCancellation()` or cancellation of the calling task
    /// terminates it.
    private func runCancellableTransfer(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let task = Task.detached { try await operation() }
        activeTransfer = task
        defer { activeTransfer = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func validateAndInspect(
        _ request: DeliveryUploadRequest
    ) async throws -> [DeliveryUploadArtifactEvidence] {
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

        var evidence: [DeliveryUploadArtifactEvidence] = []
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
            let memoEvidence: DeliveryUploadFileEvidence?
            if let memo = artifact.voiceMemo {
                do {
                    let inspectedMemo = try await fileInspector.inspect(memo.localURL)
                    guard inspectedMemo.byteCount == memo.expectedByteCount,
                          inspectedMemo.sha256 == memo.expectedSHA256 else {
                        throw DeliveryUploadPreflightError.artifactEvidenceMismatch(
                            itemIndex: item.itemIndex
                        )
                    }
                    memoEvidence = inspectedMemo
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as DeliveryUploadPreflightError {
                    throw error
                } catch {
                    throw DeliveryUploadPreflightError.artifactInspectionFailed(
                        itemIndex: item.itemIndex
                    )
                }
            } else {
                memoEvidence = nil
            }
            evidence.append(DeliveryUploadArtifactEvidence(image: inspected, voiceMemo: memoEvidence))
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
        // Delivered items need not be a contiguous prefix (the batch continues past file-level
        // failures, and a resumed run delivers earlier items later), but each item appears once,
        // in plan order.
        guard zip(checkpoint.items, checkpoint.items.dropFirst()).allSatisfy({ pair in
                  pair.0.itemIndex < pair.1.itemIndex
              }),
              checkpoint.items.allSatisfy({ results.indices.contains($0.itemIndex) }) else {
            throw DeliveryUploadPreflightError.invalidResumeCheckpoint
        }

        for saved in checkpoint.items {
            guard results.indices.contains(saved.itemIndex) else {
                throw DeliveryUploadPreflightError.invalidResumeCheckpoint
            }
            let current = results[saved.itemIndex]
            let memoCheckpointIsValid: Bool
            if let expectedMemo = current.voiceMemoLocalEvidence {
                memoCheckpointIsValid = saved.voiceMemoLocalEvidence == expectedMemo
                    && saved.voiceMemoUploadAcknowledgedAt != nil
                    && saved.voiceMemoRemoteConfirmation != nil
                    && Self.isValidSHA256(expectedMemo.sha256)
                    && expectedMemo.byteCount >= 0
                    && Self.isSuccessfulRemoteConfirmation(saved.voiceMemoRemoteConfirmation!)
                    && Self.hasCoherentTimestamp(
                        saved.voiceMemoRemoteConfirmation!,
                        uploadAcknowledgedAt: saved.voiceMemoUploadAcknowledgedAt!
                    )
            } else {
                memoCheckpointIsValid = saved.voiceMemoLocalEvidence == nil
                    && saved.voiceMemoUploadAcknowledgedAt == nil
                    && saved.voiceMemoRemoteConfirmation == nil
            }
            guard saved.stageInputFingerprint == current.stageInputFingerprint,
                  saved.localEvidence == current.localEvidence,
                  Self.isValidSHA256(saved.localEvidence.sha256),
                  saved.localEvidence.byteCount >= 0,
                  Self.isSuccessfulRemoteConfirmation(saved.remoteConfirmation),
                  Self.hasCoherentTimestamp(
                      saved.remoteConfirmation,
                      uploadAcknowledgedAt: saved.uploadAcknowledgedAt
                  ), memoCheckpointIsValid else {
                throw DeliveryUploadPreflightError.invalidResumeCheckpoint
            }
            results[saved.itemIndex].stage = .sent
            results[saved.itemIndex].uploadAcknowledgement = DeliveryUploadAcknowledgement(
                status: .protocolAcknowledged,
                acknowledgedAt: saved.uploadAcknowledgedAt
            )
            results[saved.itemIndex].remoteConfirmation = saved.remoteConfirmation
            results[saved.itemIndex].voiceMemoUploadAcknowledgement =
                saved.voiceMemoUploadAcknowledgedAt.map {
                    DeliveryUploadAcknowledgement(status: .protocolAcknowledged, acknowledgedAt: $0)
                }
            results[saved.itemIndex].voiceMemoRemoteConfirmation = saved.voiceMemoRemoteConfirmation
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
            let memoAcknowledgedAt = item.voiceMemoUploadAcknowledgement?.acknowledgedAt
            if item.voiceMemoLocalEvidence != nil,
               item.voiceMemoUploadAcknowledgement?.status != .protocolAcknowledged {
                return nil
            }
            return DeliveryUploadCheckpointItem(
                itemIndex: item.itemIndex,
                stageInputFingerprint: item.stageInputFingerprint,
                localEvidence: localEvidence,
                uploadAcknowledgedAt: acknowledgedAt,
                remoteConfirmation: item.remoteConfirmation,
                voiceMemoLocalEvidence: item.voiceMemoLocalEvidence,
                voiceMemoUploadAcknowledgedAt: memoAcknowledgedAt,
                voiceMemoRemoteConfirmation: item.voiceMemoRemoteConfirmation
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
        // `.missing` after an acknowledged upload = sent, not visible (drop box / hot folder).
        case .notRequested, .unavailable, .existsSizeUnknown, .sizeMatches, .missing: true
        case .sizeMismatch: false
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
