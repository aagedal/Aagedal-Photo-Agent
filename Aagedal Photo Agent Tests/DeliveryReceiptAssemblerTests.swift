import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Delivery receipt terminal evidence assembly")
struct DeliveryReceiptAssemblerTests {
    private let receiptID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let version = DeliveryApplicationVersion(marketingVersion: "2.3", buildNumber: "230")
    private let completedAt = Date(timeIntervalSince1970: 200)

    @Test("terminal evidence maps to a deterministic validated privacy-shaped receipt")
    func successfulAssembly() async throws {
        let fixture = try await ReceiptAssemblyFixture()
        let assembler = makeAssembler()

        let receipt = try assembler.assemble(
            plan: fixture.plan,
            stagingResult: fixture.staging,
            uploadResult: fixture.upload
        )

        #expect(receipt.id == receiptID)
        #expect(receipt.batchIdentifier == fixture.staging.batchID)
        #expect(receipt.profileIdentifier == fixture.plan.profile.id)
        #expect(receipt.applicationVersion == version)
        #expect(receipt.startedAt == Date(timeIntervalSince1970: 90))
        #expect(receipt.completedAt == completedAt)
        #expect(receipt.destination.identifier == fixture.connectionID.uuidString.lowercased())
        #expect(receipt.destination.path == "/incoming/wire")
        #expect(receipt.destination.transportSecurity == DeliveryTransportSecurity(
            protocolKind: .explicitFTPS,
            verificationEnabled: true
        ))
        #expect(receipt.items.map(\.deliveredFilename) == fixture.plan.items.map(\.outputFilename))
        #expect(receipt.items[0].deliveredSHA256 == fixture.staging.items[0].stagedSHA256)
        #expect(receipt.items[0].sourceIdentity.sha256 == fixture.plan.items[0].sourceRevision.sha256)
        #expect(receipt.items.indices.allSatisfy { index in
            receipt.items[index].metadataVerification.outcome == .verified
                && receipt.items[index].metadataVerification.issueIdentifiers.isEmpty
                && receipt.items[index].metadataVerification.controlledFieldIdentifiers
                    == fixture.staging.items[index].checkedFields
        })
        #expect(receipt.acceptedWarningIdentifiers == fixture.plan.acceptedWarningIDs)
        for index in receipt.items.indices {
            let scoped = fixture.plan.preflight.issues.compactMap { issue in
                issue.severity == .warning && issue.imageIndex == index ? issue.id : nil
            }
            #expect(receipt.items[index].acceptedWarningIdentifiers == scoped)
        }

        let sdr = receipt.items[0].renderSettings
        #expect(sdr.formatIdentifier == "jpeg")
        #expect(sdr.colorSpaceIdentifier == "sRGB")
        // These are renderer-reported crop dimensions, intentionally not dimensions inferred
        // from the 6000x4000 source/orientation/resolution cap.
        #expect(sdr.pixelWidth == 1_234)
        #expect(sdr.pixelHeight == 777)
        #expect(sdr.bitDepth == 8)
        #expect(sdr.quality == 90)
        let hdr = receipt.items[1].renderSettings
        #expect(hdr.formatIdentifier == "heic10bit")
        #expect(hdr.colorSpaceIdentifier == "displayP3")
        #expect(hdr.bitDepth == 10)
        #expect(hdr.quality == 85)

        #expect(receipt.items[0].uploadAcknowledgement.status == .protocolAcknowledged)
        #expect(receipt.items[0].remoteStatAcknowledgement.status == .matchesDeliveredByteSize)
        #expect(receipt.items[1].remoteStatAcknowledgement.status == .unavailable)
        try receipt.validateForPersistence()

        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self).lowercased()
        #expect(!json.contains("private caption"))
        #expect(!json.contains("canonicalurl"))
        #expect(!json.contains("source-0.raw"))
        #expect(!json.contains("password"))
        #expect(json.contains("explicitftps"))
        #expect(json.contains("verificationenabled"))
    }

    @Test("invalid or fingerprint-tampered plans are refused")
    func planRefusal() async throws {
        let fixture = try await ReceiptAssemblyFixture()
        let tampered = DeliveryPlan(
            fingerprint: fixture.plan.fingerprint,
            profile: fixture.plan.profile,
            preflight: fixture.plan.preflight,
            renderAndWrite: fixture.plan.renderAndWrite,
            destination: DeliveryDestinationSnapshot(
                connectionIdentifier: fixture.plan.destination.connectionIdentifier,
                resolvedRemotePath: "/other/path"
            ),
            acceptedWarningIDs: fixture.plan.acceptedWarningIDs,
            items: fixture.plan.items
        )

        #expect(throws: DeliveryReceiptAssemblyError.invalidPlan) {
            _ = try makeAssembler().assemble(
                plan: tampered,
                stagingResult: fixture.staging,
                uploadResult: fixture.upload
            )
        }
    }

    @Test("failed, cancelled, and identity-tampered staging batches are refused")
    func stagingBatchRefusals() async throws {
        let fixture = try await ReceiptAssemblyFixture()
        for status in [DeliveryStagingBatchStatus.failed, .cancelled] {
            #expect(throws: DeliveryReceiptAssemblyError.stagingBatchNotCompleted) {
                _ = try makeAssembler().assemble(
                    plan: fixture.plan,
                    stagingResult: fixture.staging(status: status),
                    uploadResult: fixture.upload
                )
            }
        }

        let wrongFingerprint = fixture.staging(planFingerprint: String(repeating: "f", count: 64))
        #expect(throws: DeliveryReceiptAssemblyError.stagingIdentityMismatch) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: wrongFingerprint,
                uploadResult: fixture.upload
            )
        }

        let wrongToken = fixture.staging(cleanupToken: DeliveryStagingCleanupToken(
            batchID: UUID(),
            planFingerprint: fixture.plan.fingerprint,
            stagingRootURL: fixture.staging.cleanupToken.stagingRootURL,
            stagingDirectoryURL: fixture.staging.stagingDirectoryURL
        ))
        #expect(throws: DeliveryReceiptAssemblyError.stagingIdentityMismatch) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: wrongToken,
                uploadResult: fixture.upload
            )
        }
    }

    @Test("staging item order, controlled fields, failures, hash, and size are exact")
    func stagingItemRefusals() async throws {
        let fixture = try await ReceiptAssemblyFixture()
        var reversed = fixture.staging.items.reversed().map { $0 }
        #expect(throws: DeliveryReceiptAssemblyError.stagingItemMismatch(itemIndex: 0)) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging(items: reversed),
                uploadResult: fixture.upload
            )
        }

        var item = fixture.staging.items[0]
        item.checkedFields = Array(item.checkedFields.dropLast())
        reversed = fixture.staging.items
        reversed[0] = item
        #expect(throws: DeliveryReceiptAssemblyError.stagingItemMismatch(itemIndex: 0)) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging(items: reversed),
                uploadResult: fixture.upload
            )
        }

        item = fixture.staging.items[0]
        item.stagedSHA256 = String(repeating: "F", count: 64)
        reversed[0] = item
        #expect(throws: DeliveryReceiptAssemblyError.stagingItemMismatch(itemIndex: 0)) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging(items: reversed),
                uploadResult: fixture.upload
            )
        }

        item = fixture.staging.items[0]
        item.failure = DeliveryStagingItemFailure(code: .metadataMismatch, message: "Mismatch")
        reversed[0] = item
        #expect(throws: DeliveryReceiptAssemblyError.stagingItemMismatch(itemIndex: 0)) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging(items: reversed),
                uploadResult: fixture.upload
            )
        }

        item = fixture.staging.items[0]
        item.metadataPreservation = .unknown()
        reversed = fixture.staging.items
        reversed[0] = item
        #expect(throws: DeliveryReceiptAssemblyError.metadataPreservationMismatch(itemIndex: 0)) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging(items: reversed),
                uploadResult: fixture.upload
            )
        }
    }

    @Test("failed, cancelled, cross-batch, and count-tampered upload results are refused")
    func uploadBatchRefusals() async throws {
        let fixture = try await ReceiptAssemblyFixture()
        for status in [DeliveryUploadBatchStatus.failed, .cancelled] {
            #expect(throws: DeliveryReceiptAssemblyError.uploadBatchNotCompleted) {
                _ = try makeAssembler().assemble(
                    plan: fixture.plan,
                    stagingResult: fixture.staging,
                    uploadResult: fixture.upload(status: status)
                )
            }
        }

        #expect(throws: DeliveryReceiptAssemblyError.uploadIdentityMismatch) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging,
                uploadResult: fixture.upload(batchIdentifier: UUID())
            )
        }
        #expect(throws: DeliveryReceiptAssemblyError.uploadItemCountMismatch) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging,
                uploadResult: fixture.upload(items: Array(fixture.upload.items.dropLast()))
            )
        }
    }

    @Test("upload item order, stage fingerprint, exact local bytes, and failure state are refused")
    func uploadItemRefusals() async throws {
        let fixture = try await ReceiptAssemblyFixture()
        var items = fixture.upload.items.reversed().map { $0 }
        #expect(throws: DeliveryReceiptAssemblyError.uploadItemMismatch(itemIndex: 0)) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging,
                uploadResult: fixture.upload(items: items)
            )
        }

        var item = fixture.upload.items[0]
        item.localEvidence = DeliveryUploadFileEvidence(
            sha256: item.localEvidence!.sha256,
            byteCount: item.localEvidence!.byteCount + 1
        )
        items = fixture.upload.items
        items[0] = item
        #expect(throws: DeliveryReceiptAssemblyError.uploadItemMismatch(itemIndex: 0)) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging,
                uploadResult: fixture.upload(items: items)
            )
        }

        item = fixture.upload.items[0]
        item.failure = DeliveryUploadItemFailure(code: .uploadRejected)
        items[0] = item
        #expect(throws: DeliveryReceiptAssemblyError.uploadItemMismatch(itemIndex: 0)) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging,
                uploadResult: fixture.upload(items: items)
            )
        }
    }

    @Test("protocol and remote-stat evidence must be coherent and successful")
    func acknowledgementRefusals() async throws {
        let fixture = try await ReceiptAssemblyFixture()
        var items = fixture.upload.items
        items[0].uploadAcknowledgement = DeliveryUploadAcknowledgement(status: .notAttempted)
        #expect(throws: DeliveryReceiptAssemblyError.uploadNotAcknowledged(itemIndex: 0)) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging,
                uploadResult: fixture.upload(items: items)
            )
        }

        items = fixture.upload.items
        items[0].remoteConfirmation = .sizeMatches(
            checkedAt: Date(timeIntervalSince1970: 101),
            observedByteCount: 99_999
        )
        #expect(throws: DeliveryReceiptAssemblyError.remoteEvidenceMismatch(itemIndex: 0)) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging,
                uploadResult: fixture.upload(items: items)
            )
        }

        items = fixture.upload.items
        items[0].remoteConfirmation = .missing(checkedAt: Date(timeIntervalSince1970: 101))
        #expect(throws: DeliveryReceiptAssemblyError.remoteEvidenceMismatch(itemIndex: 0)) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging,
                uploadResult: fixture.upload(items: items)
            )
        }
    }

    @Test("completed checkpoint must exactly reproduce every terminal item")
    func checkpointRefusal() async throws {
        let fixture = try await ReceiptAssemblyFixture()
        var checkpointItems = fixture.upload.checkpoint.items
        let original = checkpointItems[0]
        checkpointItems[0] = DeliveryUploadCheckpointItem(
            itemIndex: original.itemIndex,
            stageInputFingerprint: original.stageInputFingerprint,
            localEvidence: original.localEvidence,
            uploadAcknowledgedAt: original.uploadAcknowledgedAt.addingTimeInterval(1),
            remoteConfirmation: original.remoteConfirmation
        )
        let checkpoint = DeliveryUploadCheckpoint(
            planFingerprint: fixture.plan.fingerprint,
            stagingBatchIdentifier: fixture.staging.batchID,
            items: checkpointItems
        )
        #expect(throws: DeliveryReceiptAssemblyError.checkpointMismatch) {
            _ = try makeAssembler().assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging,
                uploadResult: fixture.upload(checkpoint: checkpoint)
            )
        }
    }

    @Test("injected identity, version, and clock are deterministic and time cannot predate evidence")
    func deterministicDependenciesAndClockRefusal() async throws {
        let fixture = try await ReceiptAssemblyFixture()
        let first = try makeAssembler().assemble(
            plan: fixture.plan,
            stagingResult: fixture.staging,
            uploadResult: fixture.upload
        )
        let second = try makeAssembler().assemble(
            plan: fixture.plan,
            stagingResult: fixture.staging,
            uploadResult: fixture.upload
        )
        #expect(first == second)

        let early = DeliveryReceiptAssembler(
            applicationVersion: { version },
            now: { Date(timeIntervalSince1970: 100) },
            makeReceiptID: { receiptID }
        )
        #expect(throws: DeliveryReceiptAssemblyError.completionTimestampPrecedesEvidence) {
            _ = try early.assemble(
                plan: fixture.plan,
                stagingResult: fixture.staging,
                uploadResult: fixture.upload
            )
        }
    }

    private func makeAssembler() -> DeliveryReceiptAssembler {
        DeliveryReceiptAssembler(
            applicationVersion: { version },
            now: { completedAt },
            makeReceiptID: { receiptID },
            transportSecurity: { _ in
                DeliveryTransportSecurity(protocolKind: .explicitFTPS, verificationEnabled: true)
            }
        )
    }
}

private struct ReceiptAssemblyFixture {
    let connectionID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
    let plan: DeliveryPlan
    let staging: DeliveryStagingBatchResult
    let upload: DeliveryUploadBatchResult

    init() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/receipt-assembly-fixture", isDirectory: true)
        let sourceURLs = (0..<2).map { root.appendingPathComponent("source-\($0).raw") }
        let export = DeadlineExportSnapshot(
            sdrFormat: .jpeg,
            sdrQuality: 0.9,
            sdrGamut: .sRGB,
            hdrFormat: .heic10bit,
            hdrQuality: 0.85,
            hdrGamut: .displayP3,
            tiffCompression: .lzw,
            resolutionLimit: .pixels4000
        )
        let profile = DeadlineProfile(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            name: "Wire desk",
            validationProfile: .snapshot(MetadataValidationProfile(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                name: "No required fields",
                rules: []
            )),
            export: .snapshot(export),
            destination: DeadlineDestinationConfiguration(
                connectionIdentifier: connectionID.uuidString.lowercased(),
                remotePathTemplate: "/incoming/wire"
            ),
            gpsPolicy: .remove,
            metadataWriteStrategy: .stagedCopies
        )
        let metadata = [
            IPTCMetadata(title: "Private caption zero"),
            IPTCMetadata(title: "Private caption one"),
        ]
        let request = DeadlinePreflightRequest(
            profile: profile,
            items: sourceURLs.enumerated().map { index, url in
                DeadlinePreflightItemSnapshot(
                    sourceURL: url,
                    metadata: metadata[index],
                    source: DeadlineSourceSnapshot(
                        byteCount: 500,
                        pixelWidth: 6_000,
                        pixelHeight: 4_000,
                        isHDR: index == 1
                    )
                )
            },
            delivery: DeadlineBatchDeliverySnapshot(
                destinationAvailableBytes: 10_000_000,
                estimatedRequiredBytes: 10_000,
                stagingState: .ready,
                connections: [connectionID.uuidString.lowercased(): .reachable],
                remotePathState: .valid(resolvedPath: "/incoming/wire")
            )
        )
        let report = try await DeadlinePreflightService().evaluate(request)
        let token = DeadlinePreflightRevisionToken(
            selectionSourceRevision: 1,
            metadataRevision: 1,
            profileRevision: 1,
            resourceRevision: 1,
            renameEnvironmentRevision: 1,
            exportCapabilityRevision: 1,
            deliverySnapshotRevision: 1
        )
        let publication = DeadlinePreflightPublication(token: token, report: report, wasCached: false)
        let revisions = sourceURLs.enumerated().map { index, url in
            SourceImageRevision(
                canonicalURL: url,
                fileResourceIdentifier: nil,
                filenameAtCreation: url.lastPathComponent,
                byteCount: 500,
                contentModificationDate: Date(timeIntervalSince1970: 10),
                pixelWidth: 6_000,
                pixelHeight: 4_000,
                exifOrientation: index == 0 ? 6 : 1,
                sha256: String(repeating: index == 0 ? "a" : "b", count: 64),
                hashCompletedAt: Date(timeIntervalSince1970: 11)
            )
        }
        let fixturePlan = try DeliveryPlanningService().makePlan(DeliveryPlanningRequest(
            preflightRequest: request,
            publication: publication,
            currentRevision: token,
            currentProfile: profile,
            items: zip(revisions, metadata).map {
                DeliveryPlanningItemInput(sourceRevision: $0.0, resolvedMetadata: $0.1)
            },
            acceptedWarningIDs: Set(report.issues.filter { $0.severity == .warning }.map(\.id))
        ))
        plan = fixturePlan

        let batchID = UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
        let directory = root.appendingPathComponent(
            "deadline-\(batchID.uuidString.lowercased())",
            isDirectory: true
        )
        let stagedItems = fixturePlan.items.map { item in
            DeliveryStagingItemResult(
                itemIndex: item.itemIndex,
                stageInputFingerprint: item.stageInputFingerprint,
                stagedRelativePath: item.stagedRelativePath,
                stage: .verified,
                stagedByteCount: 1_000 + item.itemIndex,
                stagedSHA256: String(repeating: item.itemIndex == 0 ? "c" : "d", count: 64),
                renderSettings: DeliveryRenderSettings(
                    formatIdentifier: item.isHDR ? export.hdrFormat.rawValue : export.sdrFormat.rawValue,
                    colorSpaceIdentifier: item.isHDR ? export.hdrGamut.rawValue : export.sdrGamut.rawValue,
                    pixelWidth: item.itemIndex == 0 ? 1_234 : 4_000,
                    pixelHeight: item.itemIndex == 0 ? 777 : 2_667,
                    bitDepth: item.isHDR ? 10 : 8,
                    quality: item.isHDR ? 85 : 90
                ),
                metadataPreservation: MetadataPreservationVerificationReport(
                    sourceFormatIdentifier: "raw",
                    stagedFormatIdentifier: item.isHDR ? "heic" : "jpeg",
                    domains: MetadataPreservationDomain.allCases.map {
                        MetadataPreservationDomainResult(
                            domain: $0,
                            status: .unsupported,
                            sourceIdentity: nil,
                            stagedIdentity: nil
                        )
                    },
                    // C2PA carriage is deliberately non-gating terminal evidence.
                    c2paConsequence: .changed
                ),
                checkedFields: IPTCMetadataVerifier.applicableFields(
                    fixturePlan.renderAndWrite.verificationFields,
                    expected: item.resolvedMetadata
                ),
                mismatchedFields: [],
                failure: nil
            )
        }
        staging = DeliveryStagingBatchResult(
            batchID: batchID,
            planFingerprint: fixturePlan.fingerprint,
            stagingDirectoryURL: directory,
            requiredBytes: 2_001,
            status: .completed,
            items: stagedItems,
            cleanupToken: DeliveryStagingCleanupToken(
                batchID: batchID,
                planFingerprint: fixturePlan.fingerprint,
                stagingRootURL: root,
                stagingDirectoryURL: directory
            )
        )

        let uploadedItems = stagedItems.map { staged in
            let acknowledgedAt = Date(timeIntervalSince1970: 100 + Double(staged.itemIndex * 10))
            let remote: DeliveryRemoteFileConfirmation = staged.itemIndex == 0
                ? .sizeMatches(
                    checkedAt: acknowledgedAt.addingTimeInterval(1),
                    observedByteCount: Int64(staged.stagedByteCount!)
                )
                : .existsSizeUnknown(checkedAt: acknowledgedAt.addingTimeInterval(1))
            return DeliveryUploadItemResult(
                itemIndex: staged.itemIndex,
                stageInputFingerprint: staged.stageInputFingerprint,
                stage: .sent,
                localEvidence: DeliveryUploadFileEvidence(
                    sha256: staged.stagedSHA256!,
                    byteCount: Int64(staged.stagedByteCount!)
                ),
                uploadAcknowledgement: DeliveryUploadAcknowledgement(
                    status: .protocolAcknowledged,
                    acknowledgedAt: acknowledgedAt
                ),
                remoteConfirmation: remote,
                failure: nil
            )
        }
        let checkpointItems = uploadedItems.map { item in
            DeliveryUploadCheckpointItem(
                itemIndex: item.itemIndex,
                stageInputFingerprint: item.stageInputFingerprint,
                localEvidence: item.localEvidence!,
                uploadAcknowledgedAt: item.uploadAcknowledgement.acknowledgedAt!,
                remoteConfirmation: item.remoteConfirmation
            )
        }
        upload = DeliveryUploadBatchResult(
            batchIdentifier: batchID,
            planFingerprint: fixturePlan.fingerprint,
            status: .completed,
            items: uploadedItems,
            checkpoint: DeliveryUploadCheckpoint(
                planFingerprint: fixturePlan.fingerprint,
                stagingBatchIdentifier: batchID,
                items: checkpointItems
            )
        )
    }

    func staging(
        planFingerprint: String? = nil,
        status: DeliveryStagingBatchStatus? = nil,
        items: [DeliveryStagingItemResult]? = nil,
        cleanupToken: DeliveryStagingCleanupToken? = nil
    ) -> DeliveryStagingBatchResult {
        DeliveryStagingBatchResult(
            batchID: staging.batchID,
            planFingerprint: planFingerprint ?? staging.planFingerprint,
            stagingDirectoryURL: staging.stagingDirectoryURL,
            requiredBytes: staging.requiredBytes,
            status: status ?? staging.status,
            items: items ?? staging.items,
            cleanupToken: cleanupToken ?? staging.cleanupToken
        )
    }

    func upload(
        batchIdentifier: UUID? = nil,
        status: DeliveryUploadBatchStatus? = nil,
        items: [DeliveryUploadItemResult]? = nil,
        checkpoint: DeliveryUploadCheckpoint? = nil
    ) -> DeliveryUploadBatchResult {
        DeliveryUploadBatchResult(
            batchIdentifier: batchIdentifier ?? upload.batchIdentifier,
            planFingerprint: upload.planFingerprint,
            status: status ?? upload.status,
            items: items ?? upload.items,
            checkpoint: checkpoint ?? upload.checkpoint
        )
    }
}

private extension DeliveryReceiptAssembler {
    func assemble(
        plan: DeliveryPlan,
        stagingResult: DeliveryStagingBatchResult,
        uploadResult: DeliveryUploadBatchResult
    ) throws -> DeliveryReceipt {
        try assemble(
            plan: plan,
            stagingResult: stagingResult,
            uploadResult: uploadResult,
            startedAt: Date(timeIntervalSince1970: 90)
        )
    }
}
