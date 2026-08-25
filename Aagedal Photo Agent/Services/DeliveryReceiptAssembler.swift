import Foundation

/// Refusals at the final, persistence-free evidence boundary of a delivery.
nonisolated enum DeliveryReceiptAssemblyError: Error, Equatable, LocalizedError, Sendable {
    case invalidPlan
    case stagingBatchNotCompleted
    case stagingIdentityMismatch
    case stagingItemCountMismatch
    case stagingItemMismatch(itemIndex: Int)
    case metadataPreservationMismatch(itemIndex: Int)
    case uploadBatchNotCompleted
    case uploadIdentityMismatch
    case uploadItemCountMismatch
    case uploadItemMismatch(itemIndex: Int)
    case uploadNotAcknowledged(itemIndex: Int)
    case remoteEvidenceMismatch(itemIndex: Int)
    case checkpointMismatch
    case missingRenderDimensions(itemIndex: Int)
    case completionTimestampPrecedesEvidence
    case invalidReceipt

    var errorDescription: String? {
        switch self {
        case .invalidPlan:
            "The frozen delivery plan is invalid or has been modified."
        case .stagingBatchNotCompleted:
            "A receipt requires a wholly completed staging batch."
        case .stagingIdentityMismatch:
            "The staging batch identity does not match its plan or cleanup evidence."
        case .stagingItemCountMismatch:
            "The staging item count does not match the frozen plan."
        case let .stagingItemMismatch(index):
            "Staging evidence for delivery item \(index) is incomplete or inconsistent."
        case let .metadataPreservationMismatch(index):
            "Unrelated metadata preservation for delivery item \(index) is incomplete or unacceptable."
        case .uploadBatchNotCompleted:
            "A receipt requires a wholly completed upload batch."
        case .uploadIdentityMismatch:
            "The upload batch does not belong to the supplied plan and staging batch."
        case .uploadItemCountMismatch:
            "The upload item count does not match the frozen plan."
        case let .uploadItemMismatch(index):
            "Upload evidence for delivery item \(index) does not match its verified staged bytes."
        case let .uploadNotAcknowledged(index):
            "Delivery item \(index) has no coherent protocol acknowledgement."
        case let .remoteEvidenceMismatch(index):
            "Remote-stat evidence for delivery item \(index) is incomplete or contradictory."
        case .checkpointMismatch:
            "The terminal upload checkpoint does not reproduce the completed upload evidence."
        case let .missingRenderDimensions(index):
            "Delivery item \(index) has no complete planned pixel dimensions."
        case .completionTimestampPrecedesEvidence:
            "The receipt completion time precedes terminal upload evidence."
        case .invalidReceipt:
            "The assembled delivery receipt failed its persistence validation."
        }
    }
}

/// Pure terminal evidence assembler. It has no repository, filesystem, renderer, or transport
/// dependency, so successful assembly cannot itself persist a receipt or mutate delivery state.
nonisolated struct DeliveryReceiptAssembler: Sendable {
    private let applicationVersion: @Sendable () -> DeliveryApplicationVersion
    private let now: @Sendable () -> Date
    private let makeReceiptID: @Sendable () -> UUID
    private let transportSecurity: @Sendable (String) -> DeliveryTransportSecurity?

    init(
        applicationVersion: @escaping @Sendable () -> DeliveryApplicationVersion,
        now: @escaping @Sendable () -> Date = Date.init,
        makeReceiptID: @escaping @Sendable () -> UUID = UUID.init,
        transportSecurity: @escaping @Sendable (String) -> DeliveryTransportSecurity? = { _ in nil }
    ) {
        self.applicationVersion = applicationVersion
        self.now = now
        self.makeReceiptID = makeReceiptID
        self.transportSecurity = transportSecurity
    }

    func assemble(
        plan: DeliveryPlan,
        stagingResult: DeliveryStagingBatchResult,
        uploadResult: DeliveryUploadBatchResult,
        startedAt: Date
    ) throws -> DeliveryReceipt {
        do {
            try DeliveryPlanningService.validateFrozenPlan(plan)
        } catch {
            throw DeliveryReceiptAssemblyError.invalidPlan
        }

        let verifiedStagedBatch = try validateStaging(plan: plan, result: stagingResult)
        let terminalEvidence = try validateUpload(
            plan: plan,
            stagingResult: stagingResult,
            verifiedStagedBatch: verifiedStagedBatch,
            result: uploadResult
        )
        let completedAt = now()
        guard startedAt <= terminalEvidence.earliestTimestamp,
              terminalEvidence.latestTimestamp <= completedAt else {
            throw DeliveryReceiptAssemblyError.completionTimestampPrecedesEvidence
        }

        var receiptItems: [DeliveryReceiptItem] = []
        receiptItems.reserveCapacity(plan.items.count)
        for planItem in plan.items {
            let index = planItem.itemIndex
            let stagedItem = stagingResult.items[index]
            let uploadItem = uploadResult.items[index]
            guard let byteCount = stagedItem.stagedByteCount,
                  let sha256 = stagedItem.stagedSHA256 else {
                throw DeliveryReceiptAssemblyError.stagingItemMismatch(itemIndex: index)
            }
            receiptItems.append(DeliveryReceiptItem(
                sourceIdentity: DeliveryReceiptSourceIdentity(
                    sha256: planItem.sourceRevision.sha256,
                    byteSize: planItem.sourceRevision.byteCount
                ),
                deliveredFilename: planItem.outputFilename,
                deliveredSHA256: sha256,
                deliveredByteSize: Int64(byteCount),
                metadataVerification: DeliveryMetadataVerificationResult(
                    outcome: .verified,
                    controlledFieldIdentifiers: stagedItem.checkedFields,
                    issueIdentifiers: []
                ),
                renderSettings: try validatedRenderSettings(
                    stagedItem.renderSettings,
                    for: planItem,
                    export: plan.renderAndWrite.export
                ),
                uploadAcknowledgement: uploadItem.uploadAcknowledgement,
                remoteStatAcknowledgement: try remoteAcknowledgement(
                    uploadItem.remoteConfirmation,
                    itemIndex: index
                ),
                acceptedWarningIdentifiers: plan.preflight.issues.compactMap { issue in
                    issue.severity == .warning && issue.imageIndex == index ? issue.id : nil
                }
            ))
        }

        let receipt = DeliveryReceipt(
            id: makeReceiptID(),
            batchIdentifier: stagingResult.batchID,
            profileIdentifier: plan.profile.id,
            applicationVersion: applicationVersion(),
            startedAt: startedAt,
            completedAt: completedAt,
            destination: DeliveryReceiptDestination(
                identifier: plan.destination.connectionIdentifier.lowercased(),
                path: plan.destination.resolvedRemotePath,
                transportSecurity: transportSecurity(plan.destination.connectionIdentifier)
            ),
            acceptedWarningIdentifiers: plan.acceptedWarningIDs,
            items: receiptItems
        )
        do {
            try receipt.validateForPersistence()
        } catch {
            throw DeliveryReceiptAssemblyError.invalidReceipt
        }
        return receipt
    }

    private func validateStaging(
        plan: DeliveryPlan,
        result: DeliveryStagingBatchResult
    ) throws -> DeliveryVerifiedStagedBatch {
        guard result.status == .completed else {
            throw DeliveryReceiptAssemblyError.stagingBatchNotCompleted
        }
        guard result.planFingerprint == plan.fingerprint,
              result.cleanupToken.planFingerprint == plan.fingerprint,
              result.cleanupToken.batchID == result.batchID,
              result.cleanupToken.stagingDirectoryURL.standardizedFileURL
                == result.stagingDirectoryURL.standardizedFileURL,
              Self.isSafeBatchDirectory(
                  result.stagingDirectoryURL,
                  root: result.cleanupToken.stagingRootURL,
                  batchID: result.batchID
              ),
              result.requiredBytes > 0 else {
            throw DeliveryReceiptAssemblyError.stagingIdentityMismatch
        }
        guard result.items.count == plan.items.count else {
            throw DeliveryReceiptAssemblyError.stagingItemCountMismatch
        }
        for item in plan.items {
            guard result.items.indices.contains(item.itemIndex) else {
                throw DeliveryReceiptAssemblyError.stagingItemCountMismatch
            }
            let staged = result.items[item.itemIndex]
            let applicableVerificationFields = IPTCMetadataVerifier.applicableFields(
                plan.renderAndWrite.verificationFields,
                expected: item.resolvedMetadata
            )
            guard staged.itemIndex == item.itemIndex,
                  staged.stageInputFingerprint == item.stageInputFingerprint,
                  staged.stagedRelativePath == item.stagedRelativePath,
                  staged.stage == .verified,
                  staged.failure == nil,
                  staged.checkedFields == applicableVerificationFields,
                  staged.mismatchedFields.isEmpty,
                  let byteCount = staged.stagedByteCount,
                  byteCount >= 0,
                  let sha256 = staged.stagedSHA256,
                  Self.isLowercaseSHA256(sha256),
                  staged.renderSettings != nil else {
                throw DeliveryReceiptAssemblyError.stagingItemMismatch(
                    itemIndex: item.itemIndex
                )
            }
            guard let preservation = staged.metadataPreservation,
                  preservation.domains.map(\.domain) == MetadataPreservationDomain.allCases,
                  preservation.isAcceptableForDelivery,
                  preservation.domains.allSatisfy({ domain in
                      switch domain.status {
                      case .match:
                          guard let source = domain.sourceIdentity,
                                let staged = domain.stagedIdentity else { return false }
                          return source == staged && Self.isLowercaseSHA256(source)
                      case .unsupported:
                          return true
                      case .mismatch, .unknown:
                          return false
                      }
                  }) else {
                throw DeliveryReceiptAssemblyError.metadataPreservationMismatch(
                    itemIndex: item.itemIndex
                )
            }
        }
        do {
            return try DeliveryVerifiedStagedBatch.validated(
                plan: plan,
                stagingResult: result
            )
        } catch {
            throw DeliveryReceiptAssemblyError.stagingIdentityMismatch
        }
    }

    private func validateUpload(
        plan: DeliveryPlan,
        stagingResult: DeliveryStagingBatchResult,
        verifiedStagedBatch: DeliveryVerifiedStagedBatch,
        result: DeliveryUploadBatchResult
    ) throws -> (earliestTimestamp: Date, latestTimestamp: Date) {
        guard result.status == .completed else {
            throw DeliveryReceiptAssemblyError.uploadBatchNotCompleted
        }
        guard result.batchIdentifier == stagingResult.batchID,
              result.batchIdentifier == verifiedStagedBatch.batchIdentifier,
              result.planFingerprint == plan.fingerprint,
              result.checkpoint.schemaVersion == DeliveryUploadCheckpoint.currentSchemaVersion,
              result.checkpoint.planFingerprint == plan.fingerprint,
              result.checkpoint.stagingBatchIdentifier == stagingResult.batchID else {
            throw DeliveryReceiptAssemblyError.uploadIdentityMismatch
        }
        guard result.items.count == plan.items.count else {
            throw DeliveryReceiptAssemblyError.uploadItemCountMismatch
        }
        guard result.checkpoint.items.count == plan.items.count else {
            throw DeliveryReceiptAssemblyError.checkpointMismatch
        }

        var acknowledgementTimes: [Date] = []
        var latestEvidenceTimes: [Date] = []
        for planItem in plan.items {
            let index = planItem.itemIndex
            guard result.items.indices.contains(index),
                  verifiedStagedBatch.artifacts.indices.contains(index) else {
                throw DeliveryReceiptAssemblyError.uploadItemCountMismatch
            }
            let staged = stagingResult.items[index]
            let artifact = verifiedStagedBatch.artifacts[index]
            let uploaded = result.items[index]
            guard uploaded.itemIndex == index,
                  uploaded.stageInputFingerprint == planItem.stageInputFingerprint,
                  uploaded.stage == .sent,
                  uploaded.failure == nil,
                  artifact.itemIndex == index,
                  artifact.stageInputFingerprint == planItem.stageInputFingerprint,
                  let stagedSHA256 = staged.stagedSHA256,
                  let stagedByteCount = staged.stagedByteCount,
                  artifact.expectedSHA256 == stagedSHA256,
                  artifact.expectedByteCount == Int64(stagedByteCount),
                  artifact.renderSettings == staged.renderSettings,
                  uploaded.localEvidence == DeliveryUploadFileEvidence(
                      sha256: stagedSHA256,
                      byteCount: Int64(stagedByteCount)
                  ) else {
                throw DeliveryReceiptAssemblyError.uploadItemMismatch(itemIndex: index)
            }
            guard uploaded.uploadAcknowledgement.status == .protocolAcknowledged,
                  let acknowledgedAt = uploaded.uploadAcknowledgement.acknowledgedAt else {
                throw DeliveryReceiptAssemblyError.uploadNotAcknowledged(itemIndex: index)
            }
            let remoteTimestamp = try validateRemoteEvidence(
                uploaded.remoteConfirmation,
                deliveredByteCount: Int64(stagedByteCount),
                acknowledgedAt: acknowledgedAt,
                itemIndex: index
            )
            acknowledgementTimes.append(acknowledgedAt)
            latestEvidenceTimes.append(remoteTimestamp ?? acknowledgedAt)

            let checkpoint = result.checkpoint.items[index]
            guard checkpoint.itemIndex == index,
                  checkpoint.stageInputFingerprint == planItem.stageInputFingerprint,
                  checkpoint.localEvidence == uploaded.localEvidence,
                  checkpoint.uploadAcknowledgedAt == acknowledgedAt,
                  checkpoint.remoteConfirmation == uploaded.remoteConfirmation else {
                throw DeliveryReceiptAssemblyError.checkpointMismatch
            }
        }
        guard zip(acknowledgementTimes, acknowledgementTimes.dropFirst()).allSatisfy({
            $0.0 <= $0.1
        }), let earliest = acknowledgementTimes.first,
           let latest = latestEvidenceTimes.max() else {
            throw DeliveryReceiptAssemblyError.checkpointMismatch
        }
        return (earliest, latest)
    }

    private func validateRemoteEvidence(
        _ confirmation: DeliveryRemoteFileConfirmation,
        deliveredByteCount: Int64,
        acknowledgedAt: Date,
        itemIndex: Int
    ) throws -> Date? {
        switch confirmation {
        case .notRequested:
            return nil
        case let .unavailable(checkedAt: .some(checkedAt)),
             let .existsSizeUnknown(checkedAt):
            guard checkedAt >= acknowledgedAt else {
                throw DeliveryReceiptAssemblyError.remoteEvidenceMismatch(itemIndex: itemIndex)
            }
            return checkedAt
        case let .sizeMatches(checkedAt, observedByteCount):
            guard checkedAt >= acknowledgedAt,
                  observedByteCount == deliveredByteCount else {
                throw DeliveryReceiptAssemblyError.remoteEvidenceMismatch(itemIndex: itemIndex)
            }
            return checkedAt
        case .unavailable(checkedAt: nil), .missing, .sizeMismatch:
            throw DeliveryReceiptAssemblyError.remoteEvidenceMismatch(itemIndex: itemIndex)
        }
    }

    private func remoteAcknowledgement(
        _ confirmation: DeliveryRemoteFileConfirmation,
        itemIndex: Int
    ) throws -> DeliveryRemoteStatAcknowledgement {
        switch confirmation {
        case .notRequested:
            return DeliveryRemoteStatAcknowledgement(status: .notRequested)
        case let .unavailable(checkedAt: .some(checkedAt)),
             let .existsSizeUnknown(checkedAt):
            return DeliveryRemoteStatAcknowledgement(
                status: .unavailable,
                checkedAt: checkedAt
            )
        case let .sizeMatches(checkedAt, observedByteCount):
            return DeliveryRemoteStatAcknowledgement(
                status: .matchesDeliveredByteSize,
                checkedAt: checkedAt,
                observedByteSize: observedByteCount
            )
        case .unavailable(checkedAt: nil), .missing, .sizeMismatch:
            throw DeliveryReceiptAssemblyError.remoteEvidenceMismatch(itemIndex: itemIndex)
        }
    }

    private func validatedRenderSettings(
        _ evidence: DeliveryRenderSettings?,
        for item: DeliveryPlanStageItem,
        export: DeadlineExportSnapshot
    ) throws -> DeliveryRenderSettings {
        guard let evidence,
              evidence.pixelWidth > 0,
              evidence.pixelHeight > 0 else {
            throw DeliveryReceiptAssemblyError.missingRenderDimensions(
                itemIndex: item.itemIndex
            )
        }
        guard evidence.maximumOutputByteCount == export.maximumOutputByteCount else {
            throw DeliveryReceiptAssemblyError.stagingItemMismatch(itemIndex: item.itemIndex)
        }
        if item.isHDR {
            guard evidence.formatIdentifier == export.hdrFormat.rawValue,
                  evidence.colorSpaceIdentifier == export.hdrGamut.rawValue,
                  evidence.bitDepth == Self.hdrBitDepth(export.hdrFormat),
                  evidence.quality == (Self.hdrSupportsQuality(export.hdrFormat)
                    ? Self.percent(export.hdrQuality) : nil) else {
                throw DeliveryReceiptAssemblyError.stagingItemMismatch(itemIndex: item.itemIndex)
            }
            return evidence
        }
        guard evidence.formatIdentifier == export.sdrFormat.rawValue,
              evidence.colorSpaceIdentifier == export.sdrGamut.rawValue,
              evidence.bitDepth == 8,
              evidence.quality == (Self.sdrSupportsQuality(export.sdrFormat)
                ? Self.percent(export.sdrQuality) : nil) else {
            throw DeliveryReceiptAssemblyError.stagingItemMismatch(itemIndex: item.itemIndex)
        }
        return evidence
    }

    private static func sdrSupportsQuality(
        _ format: DeadlineExportSnapshot.SDRFormat
    ) -> Bool {
        switch format {
        case .png, .tiff: false
        case .jpeg, .heic, .avif, .avifFFmpeg, .jxl: true
        }
    }

    private static func hdrSupportsQuality(
        _ format: DeadlineExportSnapshot.HDRFormat
    ) -> Bool {
        switch format {
        case .tiff16bit, .png16bit: false
        case .jpegGainMap, .heic10bit, .avif10bit, .avifFFmpeg10bit, .jxl: true
        }
    }

    private static func hdrBitDepth(_ format: DeadlineExportSnapshot.HDRFormat) -> Int? {
        switch format {
        case .jpegGainMap: nil
        case .heic10bit, .avif10bit, .avifFFmpeg10bit: 10
        case .jxl, .tiff16bit, .png16bit: 16
        }
    }

    private static func percent(_ value: Double) -> Int {
        Int((value * 100).rounded())
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
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
}
