import CryptoKit
import Foundation

/// User-visible delivery lifecycle. Raw transport and filesystem errors never enter this state.
nonisolated enum DeliveryWorkflowStage: String, Codable, Equatable, Sendable {
    case queued
    case staging
    case writing
    case verifying
    case preservationVerifying = "preservation-verifying"
    case uploading
    case remoteConfirming = "remote-confirming"
    case recordingReceipt = "recording-receipt"
    case sent
    case failed
    case cancelled
}

/// Stable, deliberately non-diagnostic failure categories safe for persistence and Activity UI.
nonisolated enum DeliveryWorkflowFailureCode: String, Codable, Equatable, Sendable {
    case invalidPlan
    case profileDrift
    case manifestPersistenceFailed
    case stagingEvidencePersistenceFailed
    case stagingRefused
    case stagingFailed
    case uploadRefused
    case uploadFailed
    case receiptAssemblyFailed
    case receiptPersistenceFailed
    case resumeEvidenceMismatch
}

/// Identity for a wholly verified staged batch. It contains no local paths or filenames.
nonisolated struct DeliveryWorkflowStagingEvidence: Codable, Equatable, Sendable {
    let batchIdentifier: UUID
    let evidenceFingerprint: String
    let verifiedItemCount: Int
}

/// Atomic relaunch state. This intentionally excludes credentials, connection settings, source
/// paths, staged paths, output filenames, and editorial metadata values. The nested upload
/// checkpoint has the same privacy-preserving shape enforced by the upload coordinator.
nonisolated struct DeliveryWorkflowManifest: VersionedJSONDocument, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let workflowIdentifier: UUID
    let planFingerprint: String
    let profileIdentifier: UUID
    let itemCount: Int
    let startedAt: Date
    var updatedAt: Date
    var stage: DeliveryWorkflowStage
    let remoteStatPolicy: DeliveryRemoteStatPolicy
    var stagingEvidence: DeliveryWorkflowStagingEvidence?
    var uploadCheckpoint: DeliveryUploadCheckpoint?
    var pendingReceiptIdentifier: UUID?
    var pendingReceiptFingerprint: String?
    var completedReceiptIdentifier: UUID?
    var failureCode: DeliveryWorkflowFailureCode?

    init(
        workflowIdentifier: UUID,
        planFingerprint: String,
        profileIdentifier: UUID,
        itemCount: Int,
        startedAt: Date,
        stage: DeliveryWorkflowStage = .queued,
        remoteStatPolicy: DeliveryRemoteStatPolicy
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.workflowIdentifier = workflowIdentifier
        self.planFingerprint = planFingerprint
        self.profileIdentifier = profileIdentifier
        self.itemCount = itemCount
        self.startedAt = startedAt
        updatedAt = startedAt
        self.stage = stage
        self.remoteStatPolicy = remoteStatPolicy
        stagingEvidence = nil
        uploadCheckpoint = nil
        pendingReceiptIdentifier = nil
        pendingReceiptFingerprint = nil
        completedReceiptIdentifier = nil
        failureCode = nil
    }

    func validateForPersistence() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              Self.isSHA256(planFingerprint),
              itemCount > 0,
              startedAt <= updatedAt else {
            throw DeliveryWorkflowError.invalidManifest
        }
        if let stagingEvidence {
            guard Self.isSHA256(stagingEvidence.evidenceFingerprint),
                  stagingEvidence.verifiedItemCount == itemCount else {
                throw DeliveryWorkflowError.invalidManifest
            }
        }
        if let checkpoint = uploadCheckpoint {
            guard stagingEvidence != nil,
                  checkpoint.schemaVersion == DeliveryUploadCheckpoint.currentSchemaVersion,
                  checkpoint.planFingerprint == planFingerprint,
                  checkpoint.stagingBatchIdentifier == stagingEvidence?.batchIdentifier,
                  checkpoint.items.count <= itemCount else {
                throw DeliveryWorkflowError.invalidManifest
            }
            for (expectedIndex, item) in checkpoint.items.enumerated() {
                guard item.itemIndex == expectedIndex,
                      Self.isSHA256(item.stageInputFingerprint),
                      Self.isSHA256(item.localEvidence.sha256),
                      item.localEvidence.byteCount >= 0 else {
                    throw DeliveryWorkflowError.invalidManifest
                }
            }
        }
        guard (pendingReceiptIdentifier == nil) == (pendingReceiptFingerprint == nil) else {
            throw DeliveryWorkflowError.invalidManifest
        }
        if let pendingReceiptFingerprint, !Self.isSHA256(pendingReceiptFingerprint) {
            throw DeliveryWorkflowError.invalidManifest
        }
        if stage == .sent {
            guard completedReceiptIdentifier != nil, failureCode == nil else {
                throw DeliveryWorkflowError.invalidManifest
            }
        } else if completedReceiptIdentifier != nil {
            throw DeliveryWorkflowError.invalidManifest
        }
        if stage == .failed {
            guard failureCode != nil else { throw DeliveryWorkflowError.invalidManifest }
        } else if failureCode != nil {
            throw DeliveryWorkflowError.invalidManifest
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

nonisolated enum DeliveryWorkflowError: Error, Equatable, LocalizedError, Sendable {
    case invalidPlan
    case planFingerprintDrift
    case profileDrift
    case invalidManifest
    case manifestNotFound
    case workflowIdentityMismatch
    case resumeUnavailable
    case resumeEvidenceMismatch
    case alreadyExecuting
    case manifestPersistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidPlan: "The frozen delivery plan is invalid or was edited."
        case .planFingerprintDrift: "The confirmed delivery-plan fingerprint changed."
        case .profileDrift: "The deadline profile changed after the delivery plan was frozen."
        case .invalidManifest: "The saved delivery workflow state is invalid."
        case .manifestNotFound: "No saved delivery workflow state is available."
        case .workflowIdentityMismatch: "The saved workflow belongs to another delivery."
        case .resumeUnavailable: "This workflow has no wholly verified staged batch to resume."
        case .resumeEvidenceMismatch: "The supplied staged bytes do not match the saved workflow."
        case .alreadyExecuting: "This delivery workflow is already executing."
        case .manifestPersistenceFailed: "Delivery progress could not be saved safely."
        }
    }
}

/// Persistence boundary used both by production atomic JSON storage and deterministic tests.
nonisolated struct DeliveryWorkflowManifestPersistence: Sendable {
    let load: @Sendable () async throws -> DeliveryWorkflowManifest?
    let save: @Sendable (DeliveryWorkflowManifest) async throws -> Void

    static func atomic(documentURL: URL) -> Self {
        let store = AtomicJSONDocumentStore<DeliveryWorkflowManifest>(documentURL: documentURL)
        return Self(
            load: {
                // A future nested upload checkpoint is not a corrupt manifest. Refuse it before
                // generic backup recovery can surface an older checkpoint and enable downgrade.
                try rejectNewerUploadCheckpointSchema(in: documentURL)
                do {
                    switch try await store.load() {
                    case let .document(document, _): return document
                    case let .newerSchema(found, _, _):
                        throw AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
                            found: found,
                            supported: DeliveryWorkflowManifest.currentSchemaVersion
                        )
                    }
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    return nil
                }
            },
            save: { try await store.save($0) }
        )
    }

    private static func rejectNewerUploadCheckpointSchema(in documentURL: URL) throws {
        guard FileManager.default.fileExists(atPath: documentURL.path),
              let data = try? Data(contentsOf: documentURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let checkpoint = manifest["uploadCheckpoint"] as? [String: Any],
              let version = checkpoint["schemaVersion"] as? Int,
              version > DeliveryUploadCheckpoint.currentSchemaVersion else {
            return
        }
        throw EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "delivery upload checkpoint",
            found: version,
            supported: DeliveryUploadCheckpoint.currentSchemaVersion
        )
    }
}

/// Separately sealed relaunch payload for the retained staging directory. Unlike the central
/// privacy-safe manifest, this document necessarily carries the existing staging type's local
/// batch paths and relative output names. It contains no credentials or editorial metadata.
nonisolated struct DeliveryWorkflowStagingEvidenceDocument:
    VersionedJSONDocument, Equatable, Sendable
{
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let workflowIdentifier: UUID
    let planFingerprint: String
    let stagingResult: DeliveryStagingBatchResult

    init(
        workflowIdentifier: UUID,
        planFingerprint: String,
        stagingResult: DeliveryStagingBatchResult
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.workflowIdentifier = workflowIdentifier
        self.planFingerprint = planFingerprint
        self.stagingResult = stagingResult
    }

    func validateForPersistence() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              stagingResult.status == .completed,
              stagingResult.planFingerprint == planFingerprint,
              stagingResult.cleanupToken.planFingerprint == planFingerprint,
              stagingResult.cleanupToken.batchID == stagingResult.batchID,
              stagingResult.items.count > 0,
              stagingResult.items.allSatisfy({ $0.stage == .verified }) else {
            throw DeliveryWorkflowError.invalidManifest
        }
    }
}

nonisolated struct DeliveryWorkflowStagingEvidencePersistence: Sendable {
    let load: @Sendable () async throws -> DeliveryWorkflowStagingEvidenceDocument?
    let save: @Sendable (DeliveryWorkflowStagingEvidenceDocument) async throws -> Void

    static func atomic(documentURL: URL) -> Self {
        let store = AtomicJSONDocumentStore<DeliveryWorkflowStagingEvidenceDocument>(
            documentURL: documentURL
        )
        return Self(
            load: {
                do {
                    switch try await store.load() {
                    case let .document(document, _): return document
                    case let .newerSchema(found, _, _):
                        throw AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
                            found: found,
                            supported: DeliveryWorkflowStagingEvidenceDocument.currentSchemaVersion
                        )
                    }
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    return nil
                }
            },
            save: { try await store.save($0) }
        )
    }
}

/// Receipt persistence/search boundary. Batch lookup closes the crash window between the atomic
/// receipt write and the following terminal-manifest update.
nonisolated struct DeliveryWorkflowReceiptRecorder: Sendable {
    let record: @Sendable (DeliveryReceipt) async throws -> Void
    let receiptForBatch: @Sendable (UUID) async throws -> DeliveryReceipt?

    static func repository(_ repository: DeliveryReceiptRepository) -> Self {
        Self(
            record: { try await repository.record($0) },
            receiptForBatch: { batchIdentifier in
                let entry = try await repository.list().first {
                    $0.batchIdentifier == batchIdentifier
                }
                guard let entry else { return nil }
                return try await repository.read(id: entry.id)
            }
        )
    }
}

nonisolated struct DeliveryWorkflowRequest: Sendable {
    let workflowIdentifier: UUID
    let plan: DeliveryPlan
    let expectedPlanFingerprint: String
    let currentProfile: DeadlineProfile
    let stagingRootURL: URL
    let remoteStatPolicy: DeliveryRemoteStatPolicy

    init(
        workflowIdentifier: UUID = UUID(),
        plan: DeliveryPlan,
        expectedPlanFingerprint: String? = nil,
        currentProfile: DeadlineProfile,
        stagingRootURL: URL,
        remoteStatPolicy: DeliveryRemoteStatPolicy = .notRequested
    ) {
        self.workflowIdentifier = workflowIdentifier
        self.plan = plan
        self.expectedPlanFingerprint = expectedPlanFingerprint ?? plan.fingerprint
        self.currentProfile = currentProfile
        self.stagingRootURL = stagingRootURL
        self.remoteStatPolicy = remoteStatPolicy
    }
}

/// Relaunch evidence is supplied by the owner of the retained staging directory. The manifest
/// does not persist local paths, and the coordinator never reconstructs or guesses them.
nonisolated struct DeliveryWorkflowResumeEvidence: Sendable {
    let stagingResult: DeliveryStagingBatchResult
}

nonisolated struct DeliveryWorkflowProgress: Equatable, Sendable {
    let workflowIdentifier: UUID
    let planFingerprint: String
    let stage: DeliveryWorkflowStage
    let completedItemCount: Int
    let itemCount: Int
    let failureCode: DeliveryWorkflowFailureCode?
}

nonisolated struct DeliveryWorkflowResult: Sendable {
    let manifest: DeliveryWorkflowManifest
    let stagingResult: DeliveryStagingBatchResult?
    let uploadResult: DeliveryUploadBatchResult?
    let receipt: DeliveryReceipt?

    var isSent: Bool { manifest.stage == .sent }
    var hasRecoverableStagedEvidence: Bool {
        stagingResult?.status == .completed
    }
}

/// End-to-end delivery orchestration over injected production boundaries. Staging is run only by
/// `start`; `resume` requires an exact wholly verified retained batch and goes directly to upload.
actor DeliveryWorkflowCoordinator {
    typealias ProgressHandler = @Sendable (DeliveryWorkflowProgress) async -> Void

    private let stagingCoordinator: StagedDeliveryCoordinator
    private let uploadCoordinator: VerifiedDeliveryUploadCoordinator
    private let receiptAssembler: DeliveryReceiptAssembler
    private let receiptRecorder: DeliveryWorkflowReceiptRecorder
    private let manifestPersistence: DeliveryWorkflowManifestPersistence
    private let stagingEvidencePersistence: DeliveryWorkflowStagingEvidencePersistence
    private let now: @Sendable () -> Date
    private var isExecuting = false
    private var cancellationRequested = false

    init(
        stagingCoordinator: StagedDeliveryCoordinator,
        uploadCoordinator: VerifiedDeliveryUploadCoordinator,
        receiptAssembler: DeliveryReceiptAssembler,
        receiptRecorder: DeliveryWorkflowReceiptRecorder,
        manifestPersistence: DeliveryWorkflowManifestPersistence,
        stagingEvidencePersistence: DeliveryWorkflowStagingEvidencePersistence,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.stagingCoordinator = stagingCoordinator
        self.uploadCoordinator = uploadCoordinator
        self.receiptAssembler = receiptAssembler
        self.receiptRecorder = receiptRecorder
        self.manifestPersistence = manifestPersistence
        self.stagingEvidencePersistence = stagingEvidencePersistence
        self.now = now
    }

    func requestCancellation() async {
        cancellationRequested = true
        await stagingCoordinator.requestCancellation()
        await uploadCoordinator.requestCancellation()
    }

    func start(
        _ request: DeliveryWorkflowRequest,
        progress: ProgressHandler? = nil
    ) async throws -> DeliveryWorkflowResult {
        guard !isExecuting else { throw DeliveryWorkflowError.alreadyExecuting }
        isExecuting = true
        cancellationRequested = false
        defer { isExecuting = false }
        try Self.validate(request)

        // Captured before the first persistence or staging operation, and later supplied unchanged
        // to terminal receipt assembly.
        let startedAt = now()
        let manifest = DeliveryWorkflowManifest(
            workflowIdentifier: request.workflowIdentifier,
            planFingerprint: request.plan.fingerprint,
            profileIdentifier: request.plan.profile.id,
            itemCount: request.plan.items.count,
            startedAt: startedAt,
            remoteStatPolicy: request.remoteStatPolicy
        )
        let journal = DeliveryWorkflowJournal(
            manifest: manifest,
            persistence: manifestPersistence,
            now: now,
            progress: progress
        )
        try await journal.persistInitial()
        try await journal.transition(to: .staging)
        if cancellationRequested || Task.isCancelled {
            await journal.finishCancelled()
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: nil,
                uploadResult: nil,
                receipt: nil
            )
        }

        let stagingResult: DeliveryStagingBatchResult
        do {
            stagingResult = try await stagingCoordinator.stage(DeliveryStagingRequest(
                plan: request.plan,
                expectedPlanFingerprint: request.expectedPlanFingerprint,
                currentProfile: request.currentProfile,
                stagingRootURL: request.stagingRootURL
            )) { update in
                await journal.record(staging: update)
            }
        } catch is CancellationError {
            await journal.finishCancelled()
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: nil,
                uploadResult: nil,
                receipt: nil
            )
        } catch {
            await journal.finishFailed(.stagingRefused)
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: nil,
                uploadResult: nil,
                receipt: nil
            )
        }
        if await journal.didPersistenceFail {
            await journal.finishFailed(.manifestPersistenceFailed)
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: nil,
                receipt: nil
            )
        }
        guard stagingResult.status == .completed else {
            if stagingResult.status == .cancelled {
                await journal.finishCancelled()
            } else {
                await journal.finishFailed(.stagingFailed)
            }
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: nil,
                receipt: nil
            )
        }

        let stagingEvidence = try Self.stagingEvidence(
            plan: request.plan,
            result: stagingResult
        )
        do {
            try await stagingEvidencePersistence.save(DeliveryWorkflowStagingEvidenceDocument(
                workflowIdentifier: request.workflowIdentifier,
                planFingerprint: request.plan.fingerprint,
                stagingResult: stagingResult
            ))
        } catch {
            await journal.finishFailed(.stagingEvidencePersistenceFailed)
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: nil,
                receipt: nil
            )
        }
        do {
            try await journal.setVerifiedStaging(stagingEvidence)
        } catch {
            await journal.finishFailed(.manifestPersistenceFailed)
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: nil,
                receipt: nil
            )
        }
        if cancellationRequested || Task.isCancelled {
            await journal.finishCancelled()
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: nil,
                receipt: nil
            )
        }
        return try await uploadAndRecord(
            request: request,
            stagingResult: stagingResult,
            resumeCheckpoint: nil,
            journal: journal
        )
    }

    /// Relaunches from exact retained, already verified staged bytes. This method has no code path
    /// to the renderer or metadata writer.
    func resume(
        _ request: DeliveryWorkflowRequest,
        progress: ProgressHandler? = nil
    ) async throws -> DeliveryWorkflowResult {
        guard let document = try await stagingEvidencePersistence.load() else {
            throw DeliveryWorkflowError.resumeUnavailable
        }
        guard document.workflowIdentifier == request.workflowIdentifier,
              document.planFingerprint == request.plan.fingerprint else {
            throw DeliveryWorkflowError.resumeEvidenceMismatch
        }
        return try await resume(
            request,
            evidence: DeliveryWorkflowResumeEvidence(stagingResult: document.stagingResult),
            progress: progress
        )
    }

    /// The explicit-evidence overload remains useful to a UI that already holds the retained
    /// batch, but it still cross-checks the atomically persisted evidence document before use.
    func resume(
        _ request: DeliveryWorkflowRequest,
        evidence: DeliveryWorkflowResumeEvidence,
        progress: ProgressHandler? = nil
    ) async throws -> DeliveryWorkflowResult {
        guard !isExecuting else { throw DeliveryWorkflowError.alreadyExecuting }
        isExecuting = true
        cancellationRequested = false
        defer { isExecuting = false }
        try Self.validate(request)
        guard let persistedEvidence = try await stagingEvidencePersistence.load(),
              persistedEvidence.workflowIdentifier == request.workflowIdentifier,
              persistedEvidence.planFingerprint == request.plan.fingerprint,
              persistedEvidence.stagingResult == evidence.stagingResult else {
            throw DeliveryWorkflowError.resumeEvidenceMismatch
        }
        guard let saved = try await manifestPersistence.load() else {
            throw DeliveryWorkflowError.manifestNotFound
        }
        try saved.validateForPersistence()
        guard saved.workflowIdentifier == request.workflowIdentifier,
              saved.planFingerprint == request.plan.fingerprint,
              saved.profileIdentifier == request.plan.profile.id,
              saved.itemCount == request.plan.items.count,
              saved.remoteStatPolicy == request.remoteStatPolicy else {
            throw DeliveryWorkflowError.workflowIdentityMismatch
        }
        let actualStaging = try Self.stagingEvidence(
            plan: request.plan,
            result: evidence.stagingResult
        )
        let journal = DeliveryWorkflowJournal(
            manifest: saved,
            persistence: manifestPersistence,
            now: now,
            progress: progress
        )
        guard saved.stage != .sent else { throw DeliveryWorkflowError.resumeUnavailable }

        let savedStaging: DeliveryWorkflowStagingEvidence
        if let referencedStaging = saved.stagingEvidence {
            guard actualStaging == referencedStaging else {
                throw DeliveryWorkflowError.resumeEvidenceMismatch
            }
            savedStaging = referencedStaging
        } else {
            // Crash repair for the only intentional two-document window: the fully validated
            // staging document became durable immediately before the central manifest gained its
            // reference. Repair only from an active pre-upload staging stage; failed, cancelled,
            // or receipt-stage manifests cannot acquire new evidence by inference.
            guard Self.canRepairUnreferencedStagingEvidence(stage: saved.stage),
                  saved.uploadCheckpoint == nil,
                  saved.pendingReceiptIdentifier == nil,
                  saved.pendingReceiptFingerprint == nil else {
                throw DeliveryWorkflowError.resumeUnavailable
            }
            try await journal.setVerifiedStaging(actualStaging)
            savedStaging = actualStaging
        }

        // If the receipt write succeeded immediately before a crash, discover and validate it
        // instead of creating a duplicate batch receipt.
        if let pendingID = saved.pendingReceiptIdentifier,
           let pendingFingerprint = saved.pendingReceiptFingerprint,
           let existing = try await receiptRecorder.receiptForBatch(savedStaging.batchIdentifier) {
            guard existing.id == pendingID,
                  try Self.receiptFingerprint(existing) == pendingFingerprint else {
                throw DeliveryWorkflowError.resumeEvidenceMismatch
            }
            try await journal.finishSent(receiptIdentifier: existing.id)
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: evidence.stagingResult,
                uploadResult: nil,
                receipt: existing
            )
        }

        if cancellationRequested || Task.isCancelled {
            await journal.finishCancelled()
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: evidence.stagingResult,
                uploadResult: nil,
                receipt: nil
            )
        }

        return try await uploadAndRecord(
            request: request,
            stagingResult: evidence.stagingResult,
            resumeCheckpoint: saved.uploadCheckpoint,
            journal: journal
        )
    }

    private func uploadAndRecord(
        request: DeliveryWorkflowRequest,
        stagingResult: DeliveryStagingBatchResult,
        resumeCheckpoint: DeliveryUploadCheckpoint?,
        journal: DeliveryWorkflowJournal
    ) async throws -> DeliveryWorkflowResult {
        let stagedBatch: DeliveryVerifiedStagedBatch
        do {
            stagedBatch = try DeliveryVerifiedStagedBatch.validated(
                plan: request.plan,
                stagingResult: stagingResult
            )
        } catch {
            await journal.finishFailed(.resumeEvidenceMismatch)
            throw DeliveryWorkflowError.resumeEvidenceMismatch
        }

        try await journal.transition(to: .queued)
        let uploadResult: DeliveryUploadBatchResult
        do {
            uploadResult = try await uploadCoordinator.upload(DeliveryUploadRequest(
                plan: request.plan,
                expectedPlanFingerprint: request.expectedPlanFingerprint,
                stagedBatch: stagedBatch,
                remoteStatPolicy: request.remoteStatPolicy,
                resumeCheckpoint: resumeCheckpoint
            )) { update in
                await journal.record(upload: update)
                if await journal.didPersistenceFail {
                    // The uploader observes this only at a file boundary, preserving its
                    // non-interruptible active-transfer contract.
                    await self.uploadCoordinator.requestCancellation()
                }
            }
        } catch is CancellationError {
            await journal.finishCancelled()
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: nil,
                receipt: nil
            )
        } catch {
            await journal.finishFailed(.uploadRefused)
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: nil,
                receipt: nil
            )
        }
        await journal.setUploadCheckpoint(uploadResult.checkpoint)
        if await journal.didPersistenceFail {
            await journal.finishFailed(.manifestPersistenceFailed)
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: uploadResult,
                receipt: nil
            )
        }
        guard uploadResult.status == .completed else {
            if uploadResult.status == .cancelled {
                await journal.finishCancelled()
            } else {
                await journal.finishFailed(.uploadFailed)
            }
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: uploadResult,
                receipt: nil
            )
        }

        do {
            try await journal.transition(to: .recordingReceipt)
        } catch {
            await journal.finishFailed(.manifestPersistenceFailed)
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: uploadResult,
                receipt: nil
            )
        }
        let receipt: DeliveryReceipt
        do {
            receipt = try receiptAssembler.assemble(
                plan: request.plan,
                stagingResult: stagingResult,
                uploadResult: uploadResult,
                startedAt: await journal.manifest.startedAt
            )
        } catch {
            await journal.finishFailed(.receiptAssemblyFailed)
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: uploadResult,
                receipt: nil
            )
        }

        do {
            try await journal.setPendingReceipt(
                identifier: receipt.id,
                fingerprint: try Self.receiptFingerprint(receipt)
            )
        } catch {
            await journal.finishFailed(.manifestPersistenceFailed)
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: uploadResult,
                receipt: receipt
            )
        }
        do {
            try await receiptRecorder.record(receipt)
        } catch {
            // The pending receipt identity plus terminal staging/upload evidence remains in the
            // manifest. Resume first searches the receipt repository to close ambiguous failures.
            await journal.finishFailed(.receiptPersistenceFailed)
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: uploadResult,
                receipt: receipt
            )
        }
        do {
            try await journal.finishSent(receiptIdentifier: receipt.id)
        } catch {
            // The receipt is already durable. The last persisted manifest remains in
            // `recording-receipt` with the exact pending receipt identity, so relaunch can find it
            // by batch without uploading or recording a duplicate.
            await journal.finishFailed(.manifestPersistenceFailed)
            return DeliveryWorkflowResult(
                manifest: await journal.manifest,
                stagingResult: stagingResult,
                uploadResult: uploadResult,
                receipt: receipt
            )
        }
        return DeliveryWorkflowResult(
            manifest: await journal.manifest,
            stagingResult: stagingResult,
            uploadResult: uploadResult,
            receipt: receipt
        )
    }

    private static func validate(_ request: DeliveryWorkflowRequest) throws {
        do {
            try DeliveryPlanningService.validateFrozenPlan(request.plan)
        } catch {
            throw DeliveryWorkflowError.invalidPlan
        }
        guard request.expectedPlanFingerprint == request.plan.fingerprint else {
            throw DeliveryWorkflowError.planFingerprintDrift
        }
        guard request.currentProfile == request.plan.profile else {
            throw DeliveryWorkflowError.profileDrift
        }
    }

    private static func canRepairUnreferencedStagingEvidence(
        stage: DeliveryWorkflowStage
    ) -> Bool {
        switch stage {
        case .staging, .writing, .verifying, .preservationVerifying:
            true
        case .queued, .uploading, .remoteConfirming, .recordingReceipt, .sent,
             .failed, .cancelled:
            false
        }
    }

    private static func stagingEvidence(
        plan: DeliveryPlan,
        result: DeliveryStagingBatchResult
    ) throws -> DeliveryWorkflowStagingEvidence {
        _ = try DeliveryVerifiedStagedBatch.validated(plan: plan, stagingResult: result)
        let payload = DeliveryWorkflowStagingFingerprintPayload(
            batchIdentifier: result.batchID,
            planFingerprint: result.planFingerprint,
            requiredBytes: result.requiredBytes,
            items: result.items.map {
                DeliveryWorkflowStagingItemFingerprintPayload(
                    itemIndex: $0.itemIndex,
                    stageInputFingerprint: $0.stageInputFingerprint,
                    stagedByteCount: $0.stagedByteCount,
                    stagedSHA256: $0.stagedSHA256,
                    renderSettings: $0.renderSettings,
                    metadataPreservation: $0.metadataPreservation,
                    checkedFields: $0.checkedFields
                )
            }
        )
        return DeliveryWorkflowStagingEvidence(
            batchIdentifier: result.batchID,
            evidenceFingerprint: try fingerprint(payload),
            verifiedItemCount: result.verifiedItemCount
        )
    }

    private static func receiptFingerprint(_ receipt: DeliveryReceipt) throws -> String {
        try fingerprint(receipt.deterministicallyOrdered)
    }

    private static func fingerprint<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        // Match AtomicJSONDocumentStore so a persisted/reloaded receipt retains the same identity
        // even when its original Date carried sub-second precision.
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        return Data(SHA256.hash(data: bytes)).lowercaseHexString
    }
}

private nonisolated struct DeliveryWorkflowStagingFingerprintPayload: Codable, Sendable {
    let batchIdentifier: UUID
    let planFingerprint: String
    let requiredBytes: Int64
    let items: [DeliveryWorkflowStagingItemFingerprintPayload]
}

private nonisolated struct DeliveryWorkflowStagingItemFingerprintPayload: Codable, Sendable {
    let itemIndex: Int
    let stageInputFingerprint: String
    let stagedByteCount: Int?
    let stagedSHA256: String?
    let renderSettings: DeliveryRenderSettings?
    let metadataPreservation: MetadataPreservationVerificationReport?
    let checkedFields: [IPTCMetadataVerificationField]
}

/// Serializes manifest writes originating from two nested coordinator progress callbacks.
private actor DeliveryWorkflowJournal {
    private(set) var manifest: DeliveryWorkflowManifest
    private(set) var didPersistenceFail = false

    private let persistence: DeliveryWorkflowManifestPersistence
    private let now: @Sendable () -> Date
    private let progress: DeliveryWorkflowCoordinator.ProgressHandler?

    init(
        manifest: DeliveryWorkflowManifest,
        persistence: DeliveryWorkflowManifestPersistence,
        now: @escaping @Sendable () -> Date,
        progress: DeliveryWorkflowCoordinator.ProgressHandler?
    ) {
        self.manifest = manifest
        self.persistence = persistence
        self.now = now
        self.progress = progress
    }

    func persistInitial() async throws {
        do {
            try await persist()
        } catch {
            throw DeliveryWorkflowError.manifestPersistenceFailed
        }
    }

    func transition(to stage: DeliveryWorkflowStage) async throws {
        manifest.stage = stage
        manifest.failureCode = nil
        manifest.updatedAt = max(now(), manifest.startedAt)
        do {
            try await persist()
        } catch {
            didPersistenceFail = true
            throw DeliveryWorkflowError.manifestPersistenceFailed
        }
    }

    func setVerifiedStaging(_ evidence: DeliveryWorkflowStagingEvidence) async throws {
        manifest.stagingEvidence = evidence
        manifest.stage = .queued
        manifest.failureCode = nil
        manifest.updatedAt = max(now(), manifest.startedAt)
        do {
            try await persist()
        } catch {
            didPersistenceFail = true
            throw DeliveryWorkflowError.manifestPersistenceFailed
        }
    }

    func setUploadCheckpoint(_ checkpoint: DeliveryUploadCheckpoint) async {
        manifest.uploadCheckpoint = checkpoint
        manifest.updatedAt = max(now(), manifest.startedAt)
        await persistBestEffort()
    }

    func setPendingReceipt(identifier: UUID, fingerprint: String) async throws {
        manifest.pendingReceiptIdentifier = identifier
        manifest.pendingReceiptFingerprint = fingerprint
        manifest.stage = .recordingReceipt
        manifest.failureCode = nil
        manifest.updatedAt = max(now(), manifest.startedAt)
        do {
            try await persist()
        } catch {
            didPersistenceFail = true
            throw DeliveryWorkflowError.manifestPersistenceFailed
        }
    }

    func finishSent(receiptIdentifier: UUID) async throws {
        manifest.stage = .sent
        manifest.failureCode = nil
        manifest.completedReceiptIdentifier = receiptIdentifier
        manifest.updatedAt = max(now(), manifest.startedAt)
        do {
            try await persist()
        } catch {
            didPersistenceFail = true
            throw DeliveryWorkflowError.manifestPersistenceFailed
        }
    }

    func finishFailed(_ code: DeliveryWorkflowFailureCode) async {
        manifest.stage = .failed
        manifest.failureCode = code
        manifest.completedReceiptIdentifier = nil
        manifest.updatedAt = max(now(), manifest.startedAt)
        await persistBestEffort()
    }

    func finishCancelled() async {
        manifest.stage = .cancelled
        manifest.failureCode = nil
        manifest.completedReceiptIdentifier = nil
        manifest.updatedAt = max(now(), manifest.startedAt)
        await persistBestEffort()
    }

    func record(staging update: DeliveryStagingProgress) async {
        guard update.planFingerprint == manifest.planFingerprint else { return }
        let active = update.currentItemIndex.flatMap { index in
            update.items.indices.contains(index) ? update.items[index].stage : nil
        }
        let stage: DeliveryWorkflowStage
        switch active {
        case .writingMetadata: stage = .writing
        case .readingStagedBytes, .verifyingMetadata: stage = .verifying
        case .verifyingPreservation: stage = .preservationVerifying
        case .failed: stage = .failed
        case .cancelled: stage = .cancelled
        default: stage = .staging
        }
        manifest.stage = stage
        manifest.failureCode = stage == .failed ? .stagingFailed : nil
        manifest.updatedAt = max(now(), manifest.startedAt)
        await persistBestEffort(completedItemCount: update.verifiedItemCount)
    }

    func record(upload update: DeliveryUploadProgress) async {
        guard update.planFingerprint == manifest.planFingerprint,
              update.batchIdentifier == manifest.stagingEvidence?.batchIdentifier else { return }
        let active = update.currentItemIndex.flatMap { index in
            update.items.indices.contains(index) ? update.items[index].stage : nil
        }
        switch active {
        case .uploading: manifest.stage = .uploading
        case .remoteConfirming: manifest.stage = .remoteConfirming
        case .failed: manifest.stage = .failed
        case .cancelled: manifest.stage = .cancelled
        default: manifest.stage = .queued
        }
        manifest.failureCode = manifest.stage == .failed ? .uploadFailed : nil
        manifest.uploadCheckpoint = Self.checkpoint(
            planFingerprint: manifest.planFingerprint,
            batchIdentifier: update.batchIdentifier,
            items: update.items
        )
        manifest.updatedAt = max(now(), manifest.startedAt)
        await persistBestEffort(completedItemCount: update.items.count { $0.stage == .sent })
    }

    private func persistBestEffort(completedItemCount: Int? = nil) async {
        guard !didPersistenceFail else { return }
        do {
            try await persist(completedItemCount: completedItemCount)
        } catch {
            didPersistenceFail = true
        }
    }

    private func persist(completedItemCount: Int? = nil) async throws {
        try manifest.validateForPersistence()
        try await persistence.save(manifest)
        if let progress {
            await progress(DeliveryWorkflowProgress(
                workflowIdentifier: manifest.workflowIdentifier,
                planFingerprint: manifest.planFingerprint,
                stage: manifest.stage,
                completedItemCount: completedItemCount ?? manifest.uploadCheckpoint?.items.count ?? 0,
                itemCount: manifest.itemCount,
                failureCode: manifest.failureCode
            ))
        }
    }

    private static func checkpoint(
        planFingerprint: String,
        batchIdentifier: UUID,
        items: [DeliveryUploadItemResult]
    ) -> DeliveryUploadCheckpoint {
        var completed: [DeliveryUploadCheckpointItem] = []
        for item in items {
            guard item.itemIndex == completed.count,
                  item.stage == .sent,
                  let evidence = item.localEvidence,
                  item.uploadAcknowledgement.status == .protocolAcknowledged,
                  let acknowledgedAt = item.uploadAcknowledgement.acknowledgedAt else {
                break
            }
            completed.append(DeliveryUploadCheckpointItem(
                itemIndex: item.itemIndex,
                stageInputFingerprint: item.stageInputFingerprint,
                localEvidence: evidence,
                uploadAcknowledgedAt: acknowledgedAt,
                remoteConfirmation: item.remoteConfirmation
            ))
        }
        return DeliveryUploadCheckpoint(
            planFingerprint: planFingerprint,
            stagingBatchIdentifier: batchIdentifier,
            items: completed
        )
    }
}
