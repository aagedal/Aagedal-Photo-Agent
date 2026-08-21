import CryptoKit
import Foundation

/// The ordered lifecycle of one staged delivery item. These stable values can be mirrored into
/// Activity records or a future resume manifest without exposing implementation-specific errors.
nonisolated enum DeliveryStagingItemStage: String, Codable, Equatable, Sendable {
    case pending
    case validatingSource
    case renderingOrCopying
    case writingMetadata
    case readingStagedBytes
    case verifyingMetadata
    case verifyingPreservation
    case verified
    case failed
    case cancelled
}

nonisolated enum DeliveryStagingFailureCode: String, Codable, Equatable, Sendable {
    case sourceInspectionFailed
    case sourceDrift
    case renderOrCopyFailed
    case metadataWriteFailed
    case stagedBytesReadFailed
    case metadataVerificationFailed
    case metadataMismatch
    case metadataPreservationMismatch
    case metadataPreservationUnconfirmed
    case outputExceedsMaximumByteCount
}

nonisolated struct DeliveryStagingItemFailure: Codable, Equatable, Sendable {
    let code: DeliveryStagingFailureCode
    let message: String
}

/// A compact, persistence-friendly record of one item's staging state.
nonisolated struct DeliveryStagingItemResult: Codable, Equatable, Sendable {
    let itemIndex: Int
    let stageInputFingerprint: String
    let stagedRelativePath: String
    var stage: DeliveryStagingItemStage
    var stagedByteCount: Int?
    /// Hash of the exact bytes that passed metadata read-back. It is populated only for `.verified`.
    var stagedSHA256: String?
    /// Actual render facts reported by the renderer that produced this staged artifact. These are
    /// terminal evidence, not dimensions inferred later from source metadata.
    var renderSettings: DeliveryRenderSettings?
    /// Full source-vs-staged unrelated-metadata evidence. C2PA carriage is recorded inside the
    /// report but does not imply that a carried manifest is valid for the rendered asset.
    var metadataPreservation: MetadataPreservationVerificationReport? = nil
    var checkedFields: [IPTCMetadataVerificationField]
    var mismatchedFields: [IPTCMetadataVerificationField]
    var failure: DeliveryStagingItemFailure?
}

nonisolated enum DeliveryStagingBatchStatus: String, Codable, Equatable, Sendable {
    case completed
    case failed
    case cancelled
}

/// Only the coordinator can create this token. Cleanup also revalidates that the batch directory
/// is a direct child of the recorded staging root before deleting it.
nonisolated struct DeliveryStagingCleanupToken: Codable, Equatable, Sendable {
    let batchID: UUID
    let planFingerprint: String
    let stagingRootURL: URL
    let stagingDirectoryURL: URL
}

nonisolated struct DeliveryStagingBatchResult: Codable, Equatable, Sendable {
    let batchID: UUID
    let planFingerprint: String
    let stagingDirectoryURL: URL
    let requiredBytes: Int64
    let status: DeliveryStagingBatchStatus
    let items: [DeliveryStagingItemResult]
    let cleanupToken: DeliveryStagingCleanupToken

    var verifiedItemCount: Int { items.count { $0.stage == .verified } }
}

nonisolated struct DeliveryStagingProgress: Equatable, Sendable {
    let batchID: UUID
    let planFingerprint: String
    let stagingDirectoryURL: URL
    let requiredBytes: Int64
    let currentItemIndex: Int?
    let items: [DeliveryStagingItemResult]

    var verifiedItemCount: Int { items.count { $0.stage == .verified } }
    var totalItemCount: Int { items.count }
}

nonisolated struct DeliveryStagingRequest: Equatable, Sendable {
    let plan: DeliveryPlan
    /// The fingerprint shown/confirmed by the caller. A newly substituted plan is refused even if
    /// it is internally valid.
    let expectedPlanFingerprint: String
    /// A fresh profile snapshot from the repository, captured immediately before staging.
    let currentProfile: DeadlineProfile
    let stagingRootURL: URL

    init(
        plan: DeliveryPlan,
        expectedPlanFingerprint: String? = nil,
        currentProfile: DeadlineProfile,
        stagingRootURL: URL
    ) {
        self.plan = plan
        self.expectedPlanFingerprint = expectedPlanFingerprint ?? plan.fingerprint
        self.currentProfile = currentProfile
        self.stagingRootURL = stagingRootURL
    }
}

nonisolated enum DeliveryStagingPreflightError: Error, Equatable, LocalizedError, Sendable {
    case invalidPlan
    case planFingerprintDrift
    case profileDrift
    case sourceInspectionFailed(itemIndex: Int)
    case sourceDrift(itemIndex: Int)
    case stagingSizeEstimateUnavailable
    case invalidStagingSizeEstimate
    case freeSpaceUnknown
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case stagingDirectoryCreationFailed
    case unsafeStagingDirectory
    case alreadyExecuting

    var errorDescription: String? {
        switch self {
        case .invalidPlan:
            "The frozen delivery plan is invalid or has been modified."
        case .planFingerprintDrift:
            "The delivery plan changed after confirmation."
        case .profileDrift:
            "The deadline profile changed after the delivery plan was frozen."
        case let .sourceInspectionFailed(index):
            "The source for delivery item \(index) could not be inspected."
        case let .sourceDrift(index):
            "The source bytes for delivery item \(index) changed after confirmation."
        case .stagingSizeEstimateUnavailable:
            "A reliable staging-space estimate could not be produced."
        case .invalidStagingSizeEstimate:
            "The staging-space estimate is invalid."
        case .freeSpaceUnknown:
            "Available staging space could not be determined."
        case let .insufficientSpace(required, available):
            "Staging requires \(required) bytes, but only \(available) bytes are available."
        case .stagingDirectoryCreationFailed:
            "A unique delivery staging directory could not be created."
        case .unsafeStagingDirectory:
            "The staging filesystem returned an unsafe batch directory."
        case .alreadyExecuting:
            "This staging coordinator is already executing a batch."
        }
    }
}

nonisolated enum DeliveryStagingCleanupError: Error, Equatable, LocalizedError, Sendable {
    case invalidToken
    case removalFailed

    var errorDescription: String? {
        switch self {
        case .invalidToken: "The delivery cleanup token does not identify a safe batch directory."
        case .removalFailed: "The delivery staging directory could not be removed."
        }
    }
}

/// Sendable filesystem boundary. Reading is deliberately separate from metadata verification:
/// the coordinator always obtains the actual completed staged bytes before asking the verifier to
/// interpret them.
nonisolated struct DeliveryStagingFileSystem: Sendable {
    let availableCapacity: @Sendable (URL) async throws -> Int64?
    let createUniqueBatchDirectory: @Sendable (URL, UUID) async throws -> URL
    let readStagedBytes: @Sendable (URL) async throws -> Data
    let removeBatchDirectory: @Sendable (URL) async throws -> Void

    static let live = Self(
        availableCapacity: { rootURL in
            let values = try rootURL.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            if let important = values.volumeAvailableCapacityForImportantUsage {
                return important
            }
            return values.volumeAvailableCapacity.map(Int64.init)
        },
        createUniqueBatchDirectory: { rootURL, batchID in
            let directory = rootURL.appendingPathComponent(
                "deadline-\(batchID.uuidString.lowercased())",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            return directory
        },
        readStagedBytes: { try Data(contentsOf: $0, options: [.mappedIfSafe]) },
        removeBatchDirectory: { try FileManager.default.removeItem(at: $0) }
    )
}

/// Renderer/copy boundary. Implementations must write exactly to `destinationURL` and must not
/// mutate the source. The frozen export/develop choices are supplied without consulting UI state.
nonisolated struct DeliveryStageRenderer: Sendable {
    let renderOrCopy: @Sendable (
        _ item: DeliveryPlanStageItem,
        _ snapshot: DeliveryRenderWriteSnapshot,
        _ destinationURL: URL
    ) async throws -> DeliveryRenderSettings
}

/// Descriptive write boundary for a completed staged output. This is intentionally distinct from
/// original-file metadata writing; implementations receive only the staged URL.
nonisolated struct DeliveryStageMetadataWriter: Sendable {
    let write: @Sendable (
        _ metadata: IPTCMetadata,
        _ snapshot: DeliveryRenderWriteSnapshot,
        _ stagedURL: URL
    ) async throws -> Void
}

/// Read-back verification boundary. The actual staged bytes are mandatory input, allowing a
/// decoder-backed implementation to compare those exact bytes with the resolved metadata.
nonisolated struct DeliveryStageMetadataVerifier: Sendable {
    let verify: @Sendable (
        _ stagedBytes: Data,
        _ stagedURL: URL,
        _ expected: IPTCMetadata,
        _ fields: [IPTCMetadataVerificationField]
    ) async throws -> IPTCMetadataVerificationReport

    static func comparing(
        readMetadata: @escaping @Sendable (Data, URL) async throws -> IPTCMetadata
    ) -> Self {
        Self { bytes, url, expected, fields in
            let actual = try await readMetadata(bytes, url)
            return IPTCMetadataVerifier.compare(
                expected: expected,
                actual: actual,
                fields: fields
            )
        }
    }
}

nonisolated struct DeliverySourceRevisionInspector: Sendable {
    let inspect: @Sendable (URL) async throws -> SourceImageRevision

    static let live = Self { try await SourceImageRevision.capture(at: $0) }
}

/// Renderer-aware output estimate boundary. A source-byte sum is intentionally not used because
/// rendered TIFF/PNG/HDR output may be materially larger than its compressed source.
nonisolated struct DeliveryStagingSizeEstimator: Sendable {
    let estimateRequiredBytes: @Sendable (DeliveryPlan) async throws -> Int64
}

/// Sequential, bounded-memory staged-delivery execution. The actor permits only one batch per
/// coordinator at a time, while each item releases its staged `Data` before the next begins.
actor StagedDeliveryCoordinator {
    typealias ProgressHandler = @Sendable (DeliveryStagingProgress) async -> Void

    private let fileSystem: DeliveryStagingFileSystem
    private let renderer: DeliveryStageRenderer
    private let metadataWriter: DeliveryStageMetadataWriter
    private let metadataVerifier: DeliveryStageMetadataVerifier
    private let preservationVerifier: DeliveryStageMetadataPreservationVerifier
    private let sourceInspector: DeliverySourceRevisionInspector
    private let sizeEstimator: DeliveryStagingSizeEstimator
    private var isExecuting = false
    private var cancellationRequested = false

    init(
        fileSystem: DeliveryStagingFileSystem,
        renderer: DeliveryStageRenderer,
        metadataWriter: DeliveryStageMetadataWriter,
        metadataVerifier: DeliveryStageMetadataVerifier,
        preservationVerifier: DeliveryStageMetadataPreservationVerifier = .liveRenderedDelivery,
        sourceInspector: DeliverySourceRevisionInspector = .live,
        sizeEstimator: DeliveryStagingSizeEstimator
    ) {
        self.fileSystem = fileSystem
        self.renderer = renderer
        self.metadataWriter = metadataWriter
        self.metadataVerifier = metadataVerifier
        self.preservationVerifier = preservationVerifier
        self.sourceInspector = sourceInspector
        self.sizeEstimator = sizeEstimator
    }

    /// Requests cancellation at the next staging boundary. An in-progress renderer or metadata
    /// operation is allowed to finish before the request is observed, so no partially mutated
    /// output is mistaken for a verified artifact.
    func requestCancellation() {
        cancellationRequested = true
    }

    /// Validates every immutable/source prerequisite and known free space before creating output.
    /// After the unique directory exists, operational failures and cancellation are returned as a
    /// recoverable batch result; no implicit cleanup occurs.
    func stage(
        _ request: DeliveryStagingRequest,
        progress: ProgressHandler? = nil
    ) async throws -> DeliveryStagingBatchResult {
        guard !isExecuting else { throw DeliveryStagingPreflightError.alreadyExecuting }
        isExecuting = true
        defer {
            isExecuting = false
            cancellationRequested = false
        }

        try checkCancellation()
        do {
            try DeliveryPlanningService.validateFrozenPlan(request.plan)
        } catch {
            throw DeliveryStagingPreflightError.invalidPlan
        }
        guard request.plan.fingerprint == request.expectedPlanFingerprint else {
            throw DeliveryStagingPreflightError.planFingerprintDrift
        }
        guard request.currentProfile == request.plan.profile else {
            throw DeliveryStagingPreflightError.profileDrift
        }
        guard request.stagingRootURL.isFileURL else {
            throw DeliveryStagingPreflightError.unsafeStagingDirectory
        }

        // Validate all sources before creating any staged output. Each source is checked again
        // immediately before its own render to close the gap during a multi-item batch.
        for item in request.plan.items {
            try checkCancellation()
            try await validateSource(item)
        }

        let requiredBytes: Int64
        do {
            requiredBytes = try await sizeEstimator.estimateRequiredBytes(request.plan)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DeliveryStagingPreflightError.stagingSizeEstimateUnavailable
        }
        try checkCancellation()
        guard requiredBytes > 0 else {
            throw DeliveryStagingPreflightError.invalidStagingSizeEstimate
        }
        let availableBytes: Int64?
        do {
            availableBytes = try await fileSystem.availableCapacity(request.stagingRootURL)
        } catch {
            throw DeliveryStagingPreflightError.freeSpaceUnknown
        }
        try checkCancellation()
        guard let availableBytes else {
            throw DeliveryStagingPreflightError.freeSpaceUnknown
        }
        guard availableBytes >= requiredBytes else {
            throw DeliveryStagingPreflightError.insufficientSpace(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        }
        try checkCancellation()

        let batchID = UUID()
        let directory: URL
        do {
            directory = try await fileSystem.createUniqueBatchDirectory(
                request.stagingRootURL,
                batchID
            )
        } catch {
            throw DeliveryStagingPreflightError.stagingDirectoryCreationFailed
        }
        guard Self.isSafeBatchDirectory(
            directory,
            root: request.stagingRootURL,
            batchID: batchID
        ) else {
            throw DeliveryStagingPreflightError.unsafeStagingDirectory
        }

        let cleanupToken = DeliveryStagingCleanupToken(
            batchID: batchID,
            planFingerprint: request.plan.fingerprint,
            stagingRootURL: request.stagingRootURL.standardizedFileURL,
            stagingDirectoryURL: directory.standardizedFileURL
        )
        var results = request.plan.items.map {
            DeliveryStagingItemResult(
                itemIndex: $0.itemIndex,
                stageInputFingerprint: $0.stageInputFingerprint,
                stagedRelativePath: $0.stagedRelativePath,
                stage: .pending,
                stagedByteCount: nil,
                stagedSHA256: nil,
                renderSettings: nil,
                checkedFields: [],
                mismatchedFields: [],
                failure: nil
            )
        }

        await publish(
            progress,
            batchID: batchID,
            plan: request.plan,
            directory: directory,
            requiredBytes: requiredBytes,
            currentItemIndex: nil,
            results: results
        )

        for item in request.plan.items {
            let index = item.itemIndex
            var activeStage = DeliveryStagingItemStage.validatingSource
            results[index].stage = activeStage
            await publish(
                progress,
                batchID: batchID,
                plan: request.plan,
                directory: directory,
                requiredBytes: requiredBytes,
                currentItemIndex: index,
                results: results
            )

            do {
                try checkCancellation()
                try await validateSource(item)

                let stagedURL = directory.appendingPathComponent(
                    item.stagedRelativePath,
                    isDirectory: false
                )
                activeStage = .renderingOrCopying
                results[index].stage = activeStage
                await publish(
                    progress,
                    batchID: batchID,
                    plan: request.plan,
                    directory: directory,
                    requiredBytes: requiredBytes,
                    currentItemIndex: index,
                    results: results
                )
                try checkCancellation()
                let renderedSettings = try await renderer.renderOrCopy(
                    item,
                    request.plan.renderAndWrite,
                    stagedURL
                )
                results[index].renderSettings = renderedSettings.recordingMaximumOutputByteCount(
                    request.plan.renderAndWrite.export.maximumOutputByteCount
                )

                activeStage = .writingMetadata
                results[index].stage = activeStage
                await publish(
                    progress,
                    batchID: batchID,
                    plan: request.plan,
                    directory: directory,
                    requiredBytes: requiredBytes,
                    currentItemIndex: index,
                    results: results
                )
                try checkCancellation()
                try await metadataWriter.write(
                    item.resolvedMetadata,
                    request.plan.renderAndWrite,
                    stagedURL
                )

                activeStage = .readingStagedBytes
                results[index].stage = activeStage
                await publish(
                    progress,
                    batchID: batchID,
                    plan: request.plan,
                    directory: directory,
                    requiredBytes: requiredBytes,
                    currentItemIndex: index,
                    results: results
                )
                try checkCancellation()
                // Kept scoped to one loop iteration so a batch never retains every rendered file
                // in memory at once.
                let stagedBytes = try await fileSystem.readStagedBytes(stagedURL)
                results[index].stagedByteCount = stagedBytes.count

                activeStage = .verifyingMetadata
                results[index].stage = activeStage
                await publish(
                    progress,
                    batchID: batchID,
                    plan: request.plan,
                    directory: directory,
                    requiredBytes: requiredBytes,
                    currentItemIndex: index,
                    results: results
                )
                try checkCancellation()
                let report = try await metadataVerifier.verify(
                    stagedBytes,
                    stagedURL,
                    item.resolvedMetadata,
                    request.plan.renderAndWrite.verificationFields
                )
                try checkCancellation()
                results[index].checkedFields = report.checkedFields
                results[index].mismatchedFields = report.differences.map(\.field)
                guard report.isMatch else {
                    results[index].stage = .failed
                    results[index].failure = DeliveryStagingItemFailure(
                        code: .metadataMismatch,
                        message: "Read-back metadata did not match \(report.differences.count) controlled field(s)."
                    )
                    await publish(
                        progress,
                        batchID: batchID,
                        plan: request.plan,
                        directory: directory,
                        requiredBytes: requiredBytes,
                        currentItemIndex: index,
                        results: results
                    )
                    return Self.result(
                        status: .failed,
                        batchID: batchID,
                        plan: request.plan,
                        directory: directory,
                        requiredBytes: requiredBytes,
                        results: results,
                        cleanupToken: cleanupToken
                    )
                }

                activeStage = .verifyingPreservation
                results[index].stage = activeStage
                await publish(
                    progress,
                    batchID: batchID,
                    plan: request.plan,
                    directory: directory,
                    requiredBytes: requiredBytes,
                    currentItemIndex: index,
                    results: results
                )
                try checkCancellation()
                let preservation = await preservationVerifier.verify(
                    item.sourceRevision.canonicalURL,
                    stagedBytes,
                    stagedURL
                )
                results[index].metadataPreservation = preservation
                try checkCancellation()
                guard preservation.isAcceptableForDelivery else {
                    let unconfirmedCount = preservation.domains.count { $0.status == .unknown }
                    results[index].stage = .failed
                    if preservation.hasProvenMismatch {
                        results[index].failure = DeliveryStagingItemFailure(
                            code: .metadataPreservationMismatch,
                            message: "Unrelated metadata did not match in \(preservation.mismatchedDomains.count) supported domain(s)."
                        )
                    } else {
                        results[index].failure = DeliveryStagingItemFailure(
                            code: .metadataPreservationUnconfirmed,
                            message: "Unrelated metadata preservation could not be confirmed in \(unconfirmedCount) domain(s)."
                        )
                    }
                    await publish(
                        progress,
                        batchID: batchID,
                        plan: request.plan,
                        directory: directory,
                        requiredBytes: requiredBytes,
                        currentItemIndex: index,
                        results: results
                    )
                    return Self.result(
                        status: .failed,
                        batchID: batchID,
                        plan: request.plan,
                        directory: directory,
                        requiredBytes: requiredBytes,
                        results: results,
                        cleanupToken: cleanupToken
                    )
                }

                if let maximum = request.plan.renderAndWrite.export.maximumOutputByteCount,
                   Int64(stagedBytes.count) > maximum {
                    results[index].stage = .failed
                    results[index].failure = DeliveryStagingItemFailure(
                        code: .outputExceedsMaximumByteCount,
                        message: "The final encoded output is \(stagedBytes.count) bytes; the configured maximum is \(maximum) bytes."
                    )
                    await publish(
                        progress,
                        batchID: batchID,
                        plan: request.plan,
                        directory: directory,
                        requiredBytes: requiredBytes,
                        currentItemIndex: index,
                        results: results
                    )
                    return Self.result(
                        status: .failed,
                        batchID: batchID,
                        plan: request.plan,
                        directory: directory,
                        requiredBytes: requiredBytes,
                        results: results,
                        cleanupToken: cleanupToken
                    )
                }

                results[index].stagedSHA256 = Data(SHA256.hash(data: stagedBytes)).lowercaseHexString
                results[index].stage = .verified
                await publish(
                    progress,
                    batchID: batchID,
                    plan: request.plan,
                    directory: directory,
                    requiredBytes: requiredBytes,
                    currentItemIndex: index,
                    results: results
                )
            } catch is CancellationError {
                results[index].stage = .cancelled
                await publish(
                    progress,
                    batchID: batchID,
                    plan: request.plan,
                    directory: directory,
                    requiredBytes: requiredBytes,
                    currentItemIndex: index,
                    results: results
                )
                return Self.result(
                    status: .cancelled,
                    batchID: batchID,
                    plan: request.plan,
                    directory: directory,
                    requiredBytes: requiredBytes,
                    results: results,
                    cleanupToken: cleanupToken
                )
            } catch {
                results[index].stage = .failed
                results[index].failure = DeliveryStagingItemFailure(
                    code: Self.failureCode(for: activeStage, error: error),
                    message: Self.failureMessage(for: activeStage, error: error)
                )
                await publish(
                    progress,
                    batchID: batchID,
                    plan: request.plan,
                    directory: directory,
                    requiredBytes: requiredBytes,
                    currentItemIndex: index,
                    results: results
                )
                return Self.result(
                    status: .failed,
                    batchID: batchID,
                    plan: request.plan,
                    directory: directory,
                    requiredBytes: requiredBytes,
                    results: results,
                    cleanupToken: cleanupToken
                )
            }
        }

        return Self.result(
            status: .completed,
            batchID: batchID,
            plan: request.plan,
            directory: directory,
            requiredBytes: requiredBytes,
            results: results,
            cleanupToken: cleanupToken
        )
    }

    /// Explicitly removes a retained staging batch. No stage/failure/cancellation path calls this.
    func cleanup(_ token: DeliveryStagingCleanupToken) async throws {
        guard Self.isSafeBatchDirectory(
            token.stagingDirectoryURL,
            root: token.stagingRootURL,
            batchID: token.batchID
        ), Self.isLowercaseSHA256(token.planFingerprint) else {
            throw DeliveryStagingCleanupError.invalidToken
        }
        do {
            try await fileSystem.removeBatchDirectory(token.stagingDirectoryURL)
        } catch {
            throw DeliveryStagingCleanupError.removalFailed
        }
    }

    private func validateSource(_ item: DeliveryPlanStageItem) async throws {
        let actual: SourceImageRevision
        do {
            actual = try await sourceInspector.inspect(item.sourceRevision.canonicalURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DeliveryStagingPreflightError.sourceInspectionFailed(itemIndex: item.itemIndex)
        }
        try checkCancellation()
        let expectedURL = item.sourceRevision.canonicalURL.standardizedFileURL.resolvingSymlinksInPath()
        let actualURL = actual.canonicalURL.standardizedFileURL.resolvingSymlinksInPath()
        guard expectedURL == actualURL,
              item.sourceRevision.relationship(to: actual) == .exactRevision else {
            throw DeliveryStagingPreflightError.sourceDrift(itemIndex: item.itemIndex)
        }
    }

    private func publish(
        _ handler: ProgressHandler?,
        batchID: UUID,
        plan: DeliveryPlan,
        directory: URL,
        requiredBytes: Int64,
        currentItemIndex: Int?,
        results: [DeliveryStagingItemResult]
    ) async {
        guard let handler else { return }
        await handler(DeliveryStagingProgress(
            batchID: batchID,
            planFingerprint: plan.fingerprint,
            stagingDirectoryURL: directory,
            requiredBytes: requiredBytes,
            currentItemIndex: currentItemIndex,
            items: results
        ))
    }

    private static func result(
        status: DeliveryStagingBatchStatus,
        batchID: UUID,
        plan: DeliveryPlan,
        directory: URL,
        requiredBytes: Int64,
        results: [DeliveryStagingItemResult],
        cleanupToken: DeliveryStagingCleanupToken
    ) -> DeliveryStagingBatchResult {
        DeliveryStagingBatchResult(
            batchID: batchID,
            planFingerprint: plan.fingerprint,
            stagingDirectoryURL: directory,
            requiredBytes: requiredBytes,
            status: status,
            items: results,
            cleanupToken: cleanupToken
        )
    }

    private static func failureCode(
        for stage: DeliveryStagingItemStage,
        error: Error
    ) -> DeliveryStagingFailureCode {
        if let error = error as? DeliveryStagingPreflightError {
            switch error {
            case .sourceDrift: return .sourceDrift
            case .sourceInspectionFailed: return .sourceInspectionFailed
            default: break
            }
        }
        switch stage {
        case .validatingSource: return .sourceInspectionFailed
        case .renderingOrCopying: return .renderOrCopyFailed
        case .writingMetadata: return .metadataWriteFailed
        case .readingStagedBytes: return .stagedBytesReadFailed
        case .verifyingMetadata, .verifyingPreservation: return .metadataVerificationFailed
        case .pending, .verified, .failed, .cancelled: return .metadataVerificationFailed
        }
    }

    private static func failureMessage(
        for stage: DeliveryStagingItemStage,
        error: Error
    ) -> String {
        if let preflightError = error as? DeliveryStagingPreflightError {
            switch preflightError {
            case .sourceDrift: return "The source bytes changed after confirmation."
            case .sourceInspectionFailed: return "The source could not be inspected."
            default: break
            }
        }
        switch stage {
        case .validatingSource: return "Source validation failed."
        case .renderingOrCopying: return "The staged render or copy failed."
        case .writingMetadata: return "Writing resolved metadata to the staged file failed."
        case .readingStagedBytes: return "Reading the completed staged bytes failed."
        case .verifyingMetadata: return "Read-back metadata verification failed."
        case .verifyingPreservation: return "Unrelated metadata preservation verification failed."
        case .pending, .verified, .failed, .cancelled: return "Staging failed."
        }
    }

    private static func isSafeBatchDirectory(_ directory: URL, root: URL, batchID: UUID) -> Bool {
        guard directory.isFileURL, root.isFileURL else { return false }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        return canonicalDirectory.deletingLastPathComponent() == canonicalRoot
            && canonicalDirectory.lastPathComponent
                == "deadline-\(batchID.uuidString.lowercased())"
    }

    private func checkCancellation() throws {
        if cancellationRequested { throw CancellationError() }
        try Task.checkCancellation()
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
