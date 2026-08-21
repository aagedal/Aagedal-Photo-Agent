import CryptoKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Delivery workflow orchestration")
struct DeliveryWorkflowCoordinatorTests {
    @Test("runs all boundaries, persists privacy-safe lifecycle, and records only terminal receipt")
    func successfulEndToEnd() async throws {
        let fixture = try await WorkflowFixture(itemCount: 2)
        let harness = WorkflowHarness(plan: fixture.plan)
        let coordinator = makeCoordinator(fixture: fixture, harness: harness)
        let progress = WorkflowProgressRecorder()

        let result = try await coordinator.start(fixture.request) { update in
            await progress.record(update)
        }

        #expect(result.isSent)
        #expect(result.receipt?.startedAt == fixture.startedAt)
        #expect(result.receipt?.items.count == 2)
        #expect((await harness.recordedReceipts).count == 1)
        let stages = await progress.stages
        for expected in [
            DeliveryWorkflowStage.queued, .staging, .writing, .verifying,
            .preservationVerifying, .uploading, .remoteConfirming,
            .recordingReceipt, .sent,
        ] {
            #expect(stages.contains(expected))
        }

        let saved = try #require(await harness.savedManifest)
        #expect(saved.stage == .sent)
        #expect(saved.uploadCheckpoint?.items.count == 2)
        let json = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).lowercased()
        #expect(!json.contains("private caption"))
        #expect(!json.contains("workflow-source"))
        #expect(!json.contains("delivered-"))
        #expect(!json.contains("password"))
        #expect(!json.contains("/private/tmp"))

        let stagingDocument = try #require(await harness.savedStagingDocument)
        let stagingJSON = String(
            decoding: try JSONEncoder().encode(stagingDocument),
            as: UTF8.self
        ).lowercased()
        #expect(!stagingJSON.contains("private caption"))
        #expect(!stagingJSON.contains("password"))
    }

    @Test("1,000-item workflow retains compact evidence and completes sequential boundaries")
    func largeBatchWorkflowEvidenceIsLinearAndPayloadFree() async throws {
        let itemCount = 1_000
        let fixture = try await WorkflowFixture(itemCount: itemCount)
        let harness = WorkflowHarness(plan: fixture.plan)
        let coordinator = makeCoordinator(fixture: fixture, harness: harness)

        let startedAt = ContinuousClock.now
        let result = try await coordinator.start(fixture.request)
        let elapsed = startedAt.duration(to: .now)

        #expect(result.isSent)
        #expect(result.stagingResult?.items.count == itemCount)
        #expect(result.uploadResult?.items.count == itemCount)
        #expect(result.manifest.uploadCheckpoint?.items.count == itemCount)
        #expect(result.receipt?.items.count == itemCount)
        #expect(await harness.renderCount == itemCount)
        #expect((await harness.uploadedItemIndices).count == itemCount)

        let manifestBytes = try JSONEncoder().encode(result.manifest)
        let manifestJSON = String(decoding: manifestBytes, as: UTF8.self).lowercased()
        #expect(!manifestJSON.contains("private caption"))
        #expect(!manifestJSON.contains("workflow-source"))
        #expect(!manifestJSON.contains("localurl"))
        #expect(manifestBytes.count < itemCount * 700)

        let stagingDocument = try #require(await harness.savedStagingDocument)
        let stagingBytes = try JSONEncoder().encode(stagingDocument)
        let stagingJSON = String(decoding: stagingBytes, as: UTF8.self).lowercased()
        #expect(!stagingJSON.contains("private caption"))
        #expect(!stagingJSON.contains("stagedbytes"))
        #expect(stagingBytes.count < itemCount * 2_000)
        #expect(elapsed > .zero)
    }

    @Test(
        "renderer, writer, filesystem read, metadata verifier, and preservation failures fail closed",
        arguments: [
            WorkflowHarness.Injection.render,
            .write,
            .read,
            .verify,
            .preservation,
        ]
    )
    private func stagingBoundaryFailures(injection: WorkflowHarness.Injection) async throws {
        let fixture = try await WorkflowFixture(itemCount: 1)
        let harness = WorkflowHarness(plan: fixture.plan, injection: injection)
        let result = try await makeCoordinator(fixture: fixture, harness: harness)
            .start(fixture.request)

        #expect(result.manifest.stage == .failed)
        #expect(result.manifest.failureCode == .stagingFailed)
        #expect(result.stagingResult?.status == .failed)
        #expect(result.uploadResult == nil)
        #expect((await harness.recordedReceipts).isEmpty)
    }

    @Test(
        "source inspection, space estimation, capacity, and directory failures refuse staging",
        arguments: [
            WorkflowHarness.Injection.sourceInspection,
            .sizeEstimate,
            .capacity,
            .createDirectory,
        ]
    )
    private func stagingEnvironmentalFailures(injection: WorkflowHarness.Injection) async throws {
        let fixture = try await WorkflowFixture(itemCount: 1)
        let harness = WorkflowHarness(plan: fixture.plan, injection: injection)
        let result = try await makeCoordinator(fixture: fixture, harness: harness)
            .start(fixture.request)

        #expect(result.manifest.stage == .failed)
        #expect(result.manifest.failureCode == .stagingRefused)
        #expect(result.stagingResult == nil)
        #expect(await harness.renderCount == 0)
    }

    @Test("upload, remote confirmation, and receipt writes fail with exact recoverable evidence")
    func terminalBoundaryFailures() async throws {
        for injection in [
            WorkflowHarness.Injection.inspect,
            .upload(itemIndex: 0),
            .remoteMissing(itemIndex: 0),
            .receiptWrite,
        ] {
            let fixture = try await WorkflowFixture(itemCount: 1)
            let harness = WorkflowHarness(plan: fixture.plan, injection: injection)
            let result = try await makeCoordinator(fixture: fixture, harness: harness)
                .start(fixture.request)

            #expect(result.manifest.stage == .failed)
            if injection == .receiptWrite {
                #expect(result.manifest.failureCode == .receiptPersistenceFailed)
                #expect(result.receipt != nil)
                #expect(result.manifest.uploadCheckpoint?.items.count == 1)
                #expect(result.manifest.pendingReceiptIdentifier == result.receipt?.id)
            } else if injection == .inspect {
                #expect(result.manifest.failureCode == .uploadRefused)
                #expect(result.uploadResult == nil)
            } else {
                #expect(result.manifest.failureCode == .uploadFailed)
                #expect(result.receipt == nil)
            }
            #expect(result.hasRecoverableStagedEvidence)
        }
    }

    @Test("relaunch resumes exact checkpoint without rerendering verified bytes")
    func relaunchResume() async throws {
        let fixture = try await WorkflowFixture(itemCount: 2)
        let harness = WorkflowHarness(
            plan: fixture.plan,
            injection: .upload(itemIndex: 1)
        )
        let first = try await makeCoordinator(fixture: fixture, harness: harness)
            .start(fixture.request)
        let staging = try #require(first.stagingResult)
        #expect(first.manifest.uploadCheckpoint?.items.count == 1)
        #expect((await harness.savedStagingDocument)?.stagingResult.batchID == staging.batchID)
        #expect(await harness.renderCount == 2)
        #expect(await harness.uploadedItemIndices == [0])

        await harness.setInjection(.none)
        let relaunched = makeCoordinator(fixture: fixture, harness: harness)
        let resumed = try await relaunched.resume(fixture.request)

        #expect(resumed.isSent)
        #expect(await harness.renderCount == 2)
        #expect(await harness.uploadedItemIndices == [0, 1])
        #expect((await harness.recordedReceipts).count == 1)
    }

    @Test("relaunch repairs the crash window after staging evidence save and before manifest reference")
    func relaunchRepairsUnreferencedStagingEvidence() async throws {
        let fixture = try await WorkflowFixture(itemCount: 1)
        let harness = WorkflowHarness(
            plan: fixture.plan,
            injection: .upload(itemIndex: 0)
        )
        let first = try await makeCoordinator(fixture: fixture, harness: harness)
            .start(fixture.request)
        #expect(first.stagingResult?.status == .completed)
        #expect(await harness.savedStagingDocument != nil)
        #expect(await harness.renderCount == 1)

        // Model a process exit in the precise interval after the staging document's atomic save
        // but before `setVerifiedStaging` updates the central manifest.
        var preReferenceManifest = try #require(await harness.savedManifest)
        preReferenceManifest.stage = .preservationVerifying
        preReferenceManifest.stagingEvidence = nil
        preReferenceManifest.uploadCheckpoint = nil
        preReferenceManifest.failureCode = nil
        await harness.replaceSavedManifest(preReferenceManifest)
        await harness.setInjection(.none)

        let resumed = try await makeCoordinator(fixture: fixture, harness: harness)
            .resume(fixture.request)

        #expect(resumed.isSent)
        #expect(resumed.manifest.startedAt == fixture.startedAt)
        #expect(resumed.manifest.stagingEvidence != nil)
        #expect(await harness.renderCount == 1)
        #expect(await harness.uploadedItemIndices == [0])
        #expect((await harness.recordedReceipts).count == 1)
    }

    @Test("receipt succeeds before terminal manifest failure and relaunch discovers it without duplication")
    func receiptCrashWindowRecovery() async throws {
        let fixture = try await WorkflowFixture(itemCount: 1)
        let harness = WorkflowHarness(plan: fixture.plan, failNextSentManifestSave: true)
        let first = try await makeCoordinator(fixture: fixture, harness: harness)
            .start(fixture.request)
        let staging = try #require(first.stagingResult)

        #expect(first.manifest.stage == .failed)
        #expect(first.manifest.failureCode == .manifestPersistenceFailed)
        #expect((await harness.recordedReceipts).count == 1)
        #expect((await harness.savedManifest)?.stage == .recordingReceipt)

        let resumed = try await makeCoordinator(fixture: fixture, harness: harness).resume(
            fixture.request,
            evidence: DeliveryWorkflowResumeEvidence(stagingResult: staging)
        )
        #expect(resumed.isSent)
        #expect((await harness.recordedReceipts).count == 1)
        #expect(await harness.uploadedItemIndices == [0])
    }

    @Test("manifest failure during staging returns and retains the completed staging batch")
    func stagingManifestFailureRetention() async throws {
        let fixture = try await WorkflowFixture(itemCount: 1)
        let harness = WorkflowHarness(
            plan: fixture.plan,
            failManifestAtStage: .writing
        )
        let result = try await makeCoordinator(fixture: fixture, harness: harness)
            .start(fixture.request)

        #expect(result.manifest.stage == .failed)
        #expect(result.manifest.failureCode == .manifestPersistenceFailed)
        #expect(result.stagingResult?.status == .completed)
        #expect(result.hasRecoverableStagedEvidence)
        #expect(result.uploadResult == nil)
        #expect(await harness.renderCount == 1)
    }

    @Test("staging evidence write failure retains the completed batch and refuses upload")
    func stagingEvidencePersistenceFailure() async throws {
        let fixture = try await WorkflowFixture(itemCount: 1)
        let harness = WorkflowHarness(
            plan: fixture.plan,
            injection: .stagingEvidenceWrite
        )
        let result = try await makeCoordinator(fixture: fixture, harness: harness)
            .start(fixture.request)

        #expect(result.manifest.stage == .failed)
        #expect(result.manifest.failureCode == .stagingEvidencePersistenceFailed)
        #expect(result.stagingResult?.status == .completed)
        #expect(result.hasRecoverableStagedEvidence)
        #expect(result.uploadResult == nil)
        #expect(await harness.savedStagingDocument == nil)
    }

    @Test("edited resolved metadata and different staged evidence cannot resume a frozen plan")
    func resumeInvalidation() async throws {
        let fixture = try await WorkflowFixture(itemCount: 2)
        let harness = WorkflowHarness(plan: fixture.plan, injection: .upload(itemIndex: 1))
        let first = try await makeCoordinator(fixture: fixture, harness: harness)
            .start(fixture.request)
        let staging = try #require(first.stagingResult)

        var items = fixture.plan.items
        items[0] = DeliveryPlanStageItem(
            itemIndex: items[0].itemIndex,
            sourceRevision: items[0].sourceRevision,
            resolvedMetadata: IPTCMetadata(title: "Edited after freeze"),
            outputFilename: items[0].outputFilename,
            stagedRelativePath: items[0].stagedRelativePath,
            isHDR: items[0].isHDR,
            developSnapshot: items[0].developSnapshot,
            stageInputFingerprint: items[0].stageInputFingerprint
        )
        let editedPlan = DeliveryPlan(
            fingerprint: fixture.plan.fingerprint,
            profile: fixture.plan.profile,
            preflight: fixture.plan.preflight,
            renderAndWrite: fixture.plan.renderAndWrite,
            destination: fixture.plan.destination,
            acceptedWarningIDs: fixture.plan.acceptedWarningIDs,
            items: items
        )
        let editedRequest = DeliveryWorkflowRequest(
            workflowIdentifier: fixture.request.workflowIdentifier,
            plan: editedPlan,
            currentProfile: fixture.plan.profile,
            stagingRootURL: fixture.request.stagingRootURL,
            remoteStatPolicy: .attemptIfAvailable
        )
        await #expect(throws: DeliveryWorkflowError.invalidPlan) {
            _ = try await makeCoordinator(fixture: fixture, harness: harness).resume(
                editedRequest,
                evidence: DeliveryWorkflowResumeEvidence(stagingResult: staging)
            )
        }

        var stagedItems = staging.items
        stagedItems[0].stagedSHA256 = String(repeating: "f", count: 64)
        let changedStaging = DeliveryStagingBatchResult(
            batchID: staging.batchID,
            planFingerprint: staging.planFingerprint,
            stagingDirectoryURL: staging.stagingDirectoryURL,
            requiredBytes: staging.requiredBytes,
            status: staging.status,
            items: stagedItems,
            cleanupToken: staging.cleanupToken
        )
        await #expect(throws: DeliveryWorkflowError.resumeEvidenceMismatch) {
            _ = try await makeCoordinator(fixture: fixture, harness: harness).resume(
                fixture.request,
                evidence: DeliveryWorkflowResumeEvidence(stagingResult: changedStaging)
            )
        }
    }

    @Test("caller cancellation during staging and file-boundary upload cancellation remain distinct")
    func cancellationContracts() async throws {
        let stagingFixture = try await WorkflowFixture(itemCount: 1)
        let stagingHarness = WorkflowHarness(
            plan: stagingFixture.plan,
            injection: .cancelStaging
        )
        let stagingResult = try await makeCoordinator(
            fixture: stagingFixture,
            harness: stagingHarness
        ).start(stagingFixture.request)
        #expect(stagingResult.manifest.stage == .cancelled)
        #expect(stagingResult.stagingResult?.status == .cancelled)

        let uploadFixture = try await WorkflowFixture(itemCount: 2)
        let uploadHarness = WorkflowHarness(plan: uploadFixture.plan)
        let coordinator = makeCoordinator(fixture: uploadFixture, harness: uploadHarness)
        let uploadResult = try await coordinator.start(uploadFixture.request) { update in
            if update.stage == .uploading && update.completedItemCount == 0 {
                await coordinator.requestCancellation()
            }
        }
        #expect(uploadResult.manifest.stage == .cancelled)
        #expect(uploadResult.uploadResult?.status == .cancelled)
        #expect(await uploadHarness.uploadedItemIndices == [0])
        #expect(uploadResult.manifest.uploadCheckpoint?.items.count == 1)
    }

    @Test("workflow cancellation requested during a renderer stops before metadata writing or upload")
    func explicitStagingCancellation() async throws {
        let fixture = try await WorkflowFixture(itemCount: 1)
        let harness = WorkflowHarness(plan: fixture.plan, injection: .pauseRender)
        let coordinator = makeCoordinator(fixture: fixture, harness: harness)

        let operation = Task { try await coordinator.start(fixture.request) }
        await harness.waitUntilRenderEntered()
        await coordinator.requestCancellation()
        await harness.releaseRender()
        let result = try await operation.value

        #expect(result.manifest.stage == .cancelled)
        #expect(result.stagingResult?.status == .cancelled)
        #expect(result.stagingResult?.items.first?.stage == .cancelled)
        #expect(await harness.uploadedItemIndices.isEmpty)
    }

    @Test("an overlapping workflow is rejected while staging remains exclusively owned")
    func concurrentWorkflowRefusal() async throws {
        let fixture = try await WorkflowFixture(itemCount: 1)
        let harness = WorkflowHarness(plan: fixture.plan, injection: .pauseRender)
        let coordinator = makeCoordinator(fixture: fixture, harness: harness)

        let first = Task { try await coordinator.start(fixture.request) }
        await harness.waitUntilRenderEntered()
        await #expect(throws: DeliveryWorkflowError.alreadyExecuting) {
            _ = try await coordinator.start(fixture.request)
        }

        await harness.releaseRender()
        let result = try await first.value
        #expect(result.manifest.stage == .sent)
        #expect(await harness.uploadedItemIndices == [0])
    }

    @Test("atomic manifest storage round-trips and recovers its prior valid primary")
    func atomicManifestPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("workflow.json")
        let persistence = DeliveryWorkflowManifestPersistence.atomic(documentURL: url)
        let manifest = DeliveryWorkflowManifest(
            workflowIdentifier: UUID(),
            planFingerprint: String(repeating: "a", count: 64),
            profileIdentifier: UUID(),
            itemCount: 1,
            startedAt: Date(timeIntervalSince1970: 10),
            remoteStatPolicy: .notRequested
        )
        try await persistence.save(manifest)
        var updated = manifest
        updated.updatedAt = Date(timeIntervalSince1970: 11)
        updated.stage = .staging
        try await persistence.save(updated)
        #expect(try await persistence.load() == updated)

        try Data("corrupt".utf8).write(to: url)
        #expect(try await persistence.load() == manifest)
    }

    @Test("nested future upload checkpoint protects the primary and older backup")
    func nestedFutureUploadCheckpointIsReadOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("workflow.json")
        let backupURL = url.appendingPathExtension("backup")
        let persistence = DeliveryWorkflowManifestPersistence.atomic(documentURL: url)
        let manifest = DeliveryWorkflowManifest(
            workflowIdentifier: UUID(),
            planFingerprint: String(repeating: "a", count: 64),
            profileIdentifier: UUID(),
            itemCount: 1,
            startedAt: Date(timeIntervalSince1970: 10),
            remoteStatPolicy: .notRequested
        )
        try await persistence.save(manifest)
        var updated = manifest
        updated.updatedAt = Date(timeIntervalSince1970: 11)
        updated.stage = .staging
        try await persistence.save(updated)

        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["uploadCheckpoint"] = [
            "schemaVersion": DeliveryUploadCheckpoint.currentSchemaVersion + 1,
            "future": ["keep": true],
        ]
        let futureData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try futureData.write(to: url, options: .atomic)
        let backupData = try Data(contentsOf: backupURL)

        await #expect(throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "delivery upload checkpoint",
            found: DeliveryUploadCheckpoint.currentSchemaVersion + 1,
            supported: DeliveryUploadCheckpoint.currentSchemaVersion
        )) {
            _ = try await persistence.load()
        }
        #expect(try Data(contentsOf: url) == futureData)
        #expect(try Data(contentsOf: backupURL) == backupData)
    }

    private func makeCoordinator(
        fixture: WorkflowFixture,
        harness: WorkflowHarness
    ) -> DeliveryWorkflowCoordinator {
        let staging = StagedDeliveryCoordinator(
            fileSystem: DeliveryStagingFileSystem(
                availableCapacity: { _ in try await harness.availableCapacity() },
                createUniqueBatchDirectory: { root, batchID in
                    try await harness.createDirectory(root: root, batchID: batchID)
                },
                readStagedBytes: { try await harness.read($0) },
                removeBatchDirectory: { _ in }
            ),
            renderer: DeliveryStageRenderer { item, snapshot, url in
                try await harness.render(item, snapshot: snapshot, to: url)
            },
            metadataWriter: DeliveryStageMetadataWriter { _, _, url in
                try await harness.write(url)
            },
            metadataVerifier: DeliveryStageMetadataVerifier { bytes, url, expected, fields in
                try await harness.verify(bytes, url: url, expected: expected, fields: fields)
            },
            preservationVerifier: DeliveryStageMetadataPreservationVerifier { _, _, url in
                await harness.preserve(url)
            },
            sourceInspector: DeliverySourceRevisionInspector { url in
                try await harness.sourceRevision(url)
            },
            sizeEstimator: DeliveryStagingSizeEstimator { _ in try await harness.estimateSize() }
        )
        let upload = VerifiedDeliveryUploadCoordinator(
            transport: DeliveryUploadTransport(
                upload: { try await harness.upload($0) },
                remoteStat: { await harness.remoteStat($0) }
            ),
            fileInspector: DeliveryUploadFileInspector { try await harness.inspect($0) },
            now: fixture.clock.now
        )
        return DeliveryWorkflowCoordinator(
            stagingCoordinator: staging,
            uploadCoordinator: upload,
            receiptAssembler: DeliveryReceiptAssembler(
                applicationVersion: {
                    DeliveryApplicationVersion(marketingVersion: "1.0", buildNumber: "1")
                },
                now: fixture.clock.now,
                makeReceiptID: fixture.receiptID
            ),
            receiptRecorder: DeliveryWorkflowReceiptRecorder(
                record: { try await harness.record($0) },
                receiptForBatch: { await harness.receipt(batchIdentifier: $0) }
            ),
            manifestPersistence: DeliveryWorkflowManifestPersistence(
                load: { await harness.savedManifest },
                save: { try await harness.save($0) }
            ),
            stagingEvidencePersistence: DeliveryWorkflowStagingEvidencePersistence(
                load: { await harness.savedStagingDocument },
                save: { try await harness.saveStagingDocument($0) }
            ),
            now: fixture.clock.now
        )
    }
}

private struct WorkflowFixture: Sendable {
    let plan: DeliveryPlan
    let request: DeliveryWorkflowRequest
    let clock: WorkflowClock
    let receiptID: @Sendable () -> UUID
    let startedAt: Date

    init(itemCount: Int) async throws {
        let export = DeadlineExportSnapshot(
            sdrFormat: .jpeg,
            sdrQuality: 0.9,
            sdrGamut: .sRGB,
            hdrFormat: .jpegGainMap,
            hdrQuality: 0.85,
            hdrGamut: .displayP3,
            tiffCompression: .lzw,
            resolutionLimit: .pixels4000
        )
        let connectionID = UUID(uuidString: "71000000-0000-0000-0000-000000000007")!
        let profile = DeadlineProfile(
            id: UUID(uuidString: "72000000-0000-0000-0000-000000000007")!,
            name: "Workflow desk",
            validationProfile: .snapshot(MetadataValidationProfile(
                id: UUID(uuidString: "73000000-0000-0000-0000-000000000007")!,
                name: "No required fields",
                rules: []
            )),
            export: .snapshot(export),
            destination: DeadlineDestinationConfiguration(
                connectionIdentifier: connectionID.uuidString.lowercased(),
                remotePathTemplate: "/incoming/workflow"
            ),
            gpsPolicy: .retain,
            metadataWriteStrategy: .stagedCopies
        )
        let metadata = (0..<itemCount).map { IPTCMetadata(title: "Private caption \($0)") }
        let revisions = (0..<itemCount).map { index in
            let url = URL(fileURLWithPath: "/private/tmp/workflow-source-\(index).jpg")
                .standardizedFileURL.resolvingSymlinksInPath()
            let date = Date(timeIntervalSince1970: 100 + Double(index))
            return SourceImageRevision(
                canonicalURL: url,
                fileResourceIdentifier: nil,
                filenameAtCreation: url.lastPathComponent,
                byteCount: Int64(10 + index),
                contentModificationDate: date,
                pixelWidth: 6_000,
                pixelHeight: 4_000,
                exifOrientation: 1,
                sha256: String(
                    repeating: String(index % 16, radix: 16),
                    count: 64
                ),
                hashCompletedAt: date.addingTimeInterval(1)
            )
        }
        let preflight = DeadlinePreflightRequest(
            profile: profile,
            items: revisions.enumerated().map { index, revision in
                DeadlinePreflightItemSnapshot(
                    sourceURL: revision.canonicalURL,
                    metadata: metadata[index],
                    source: DeadlineSourceSnapshot(
                        byteCount: revision.byteCount,
                        pixelWidth: 6_000,
                        pixelHeight: 4_000
                    )
                )
            },
            renameEnvironment: RenamePlanningEnvironment(
                caseSensitivity: .caseInsensitive,
                existingURLs: [],
                isComplete: true
            ),
            delivery: DeadlineBatchDeliverySnapshot(
                destinationAvailableBytes: 100_000,
                estimatedRequiredBytes: 1_000,
                stagingState: .ready,
                connections: [connectionID.uuidString.lowercased(): .reachable],
                remotePathState: .valid(resolvedPath: "/incoming/workflow")
            )
        )
        let report = try await DeadlinePreflightService().evaluate(preflight)
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
        plan = try DeliveryPlanningService().makePlan(DeliveryPlanningRequest(
            preflightRequest: preflight,
            publication: publication,
            currentRevision: token,
            currentProfile: profile,
            items: revisions.enumerated().map { index, revision in
                DeliveryPlanningItemInput(
                    sourceRevision: revision,
                    resolvedMetadata: metadata[index]
                )
            }
        ))
        startedAt = Date(timeIntervalSince1970: 1_000)
        clock = WorkflowClock(start: startedAt)
        let fixedReceiptID = UUID(uuidString: "74000000-0000-0000-0000-000000000007")!
        receiptID = { fixedReceiptID }
        request = DeliveryWorkflowRequest(
            workflowIdentifier: UUID(uuidString: "75000000-0000-0000-0000-000000000007")!,
            plan: plan,
            currentProfile: profile,
            stagingRootURL: URL(
                fileURLWithPath: "/private/tmp/workflow-staging",
                isDirectory: true
            ),
            remoteStatPolicy: .attemptIfAvailable
        )
    }
}

private nonisolated final class WorkflowClock: @unchecked Sendable {
    private let lock = NSLock()
    private var next: TimeInterval

    init(start: Date) { next = start.timeIntervalSince1970 }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let value = Date(timeIntervalSince1970: next)
        next += 1
        return value
    }
}

private actor WorkflowHarness {
    enum Injection: Equatable, Sendable {
        case none
        case sourceInspection
        case sizeEstimate
        case capacity
        case createDirectory
        case render
        case write
        case read
        case verify
        case preservation
        case inspect
        case upload(itemIndex: Int)
        case remoteMissing(itemIndex: Int)
        case receiptWrite
        case stagingEvidenceWrite
        case cancelStaging
        case pauseRender
    }

    enum InjectedFailure: Error { case requested }

    let plan: DeliveryPlan
    private var injection: Injection
    private let failManifestAtStage: DeliveryWorkflowStage?
    private var shouldFailSentManifestSave: Bool
    private var payloads: [Int: Data] = [:]
    private(set) var savedManifest: DeliveryWorkflowManifest?
    private(set) var savedStagingDocument: DeliveryWorkflowStagingEvidenceDocument?
    private(set) var recordedReceipts: [DeliveryReceipt] = []
    private(set) var renderCount = 0
    private(set) var uploadedItemIndices: [Int] = []
    private var renderEntered = false
    private var renderEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var renderRelease: CheckedContinuation<Void, Never>?

    init(
        plan: DeliveryPlan,
        injection: Injection = .none,
        failManifestAtStage: DeliveryWorkflowStage? = nil,
        failNextSentManifestSave: Bool = false
    ) {
        self.plan = plan
        self.injection = injection
        self.failManifestAtStage = failManifestAtStage
        shouldFailSentManifestSave = failNextSentManifestSave
    }

    func setInjection(_ value: Injection) { injection = value }

    func replaceSavedManifest(_ manifest: DeliveryWorkflowManifest) {
        savedManifest = manifest
    }

    func sourceRevision(_ url: URL) throws -> SourceImageRevision {
        if injection == .sourceInspection { throw InjectedFailure.requested }
        return plan.items.first { $0.sourceRevision.canonicalURL == url }!.sourceRevision
    }

    func estimateSize() throws -> Int64 {
        if injection == .sizeEstimate { throw InjectedFailure.requested }
        return 1_000
    }

    func availableCapacity() throws -> Int64? {
        if injection == .capacity { return nil }
        return 1_000_000
    }

    func createDirectory(root: URL, batchID: UUID) throws -> URL {
        if injection == .createDirectory { throw InjectedFailure.requested }
        return root.appendingPathComponent(
            "deadline-\(batchID.uuidString.lowercased())",
            isDirectory: true
        )
    }

    func render(
        _ item: DeliveryPlanStageItem,
        snapshot: DeliveryRenderWriteSnapshot,
        to _: URL
    ) async throws -> DeliveryRenderSettings {
        renderCount += 1
        if injection == .render { throw InjectedFailure.requested }
        if injection == .cancelStaging { throw CancellationError() }
        if injection == .pauseRender {
            renderEntered = true
            let waiters = renderEntryWaiters
            renderEntryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { renderRelease = $0 }
        }
        payloads[item.itemIndex] = Data("rendered-\(item.itemIndex)".utf8)
        return DeliveryRenderSettings(
            formatIdentifier: snapshot.export.sdrFormat.rawValue,
            colorSpaceIdentifier: snapshot.export.sdrGamut.rawValue,
            pixelWidth: 4_000,
            pixelHeight: 2_667,
            bitDepth: 8,
            quality: 90
        )
    }

    func waitUntilRenderEntered() async {
        guard !renderEntered else { return }
        await withCheckedContinuation { renderEntryWaiters.append($0) }
    }

    func releaseRender() {
        renderRelease?.resume()
        renderRelease = nil
    }

    func write(_ url: URL) throws {
        if injection == .write { throw InjectedFailure.requested }
        let index = itemIndex(url)
        payloads[index] = Data("delivered-\(index)".utf8)
    }

    func read(_ url: URL) throws -> Data {
        if injection == .read { throw InjectedFailure.requested }
        return payloads[itemIndex(url)]!
    }

    func verify(
        _ bytes: Data,
        url _: URL,
        expected: IPTCMetadata,
        fields: [IPTCMetadataVerificationField]
    ) throws -> IPTCMetadataVerificationReport {
        if injection == .verify { throw InjectedFailure.requested }
        #expect(!bytes.isEmpty)
        return IPTCMetadataVerifier.compare(expected: expected, actual: expected, fields: fields)
    }

    func preserve(_ url: URL) -> MetadataPreservationVerificationReport {
        if injection == .preservation {
            return .unknown(sourceFormatIdentifier: "jpeg", stagedFormatIdentifier: "jpeg")
        }
        _ = itemIndex(url)
        let identity = String(repeating: "a", count: 64)
        return MetadataPreservationVerificationReport(
            sourceFormatIdentifier: "jpeg",
            stagedFormatIdentifier: "jpeg",
            domains: MetadataPreservationDomain.allCases.map {
                MetadataPreservationDomainResult(
                    domain: $0,
                    status: .match,
                    sourceIdentity: identity,
                    stagedIdentity: identity
                )
            },
            c2paConsequence: .absentFromBoth
        )
    }

    func inspect(_ url: URL) throws -> DeliveryUploadFileEvidence {
        if injection == .inspect { throw InjectedFailure.requested }
        let bytes = payloads[itemIndex(url)]!
        return DeliveryUploadFileEvidence(
            sha256: Data(SHA256.hash(data: bytes)).lowercaseHexString,
            byteCount: Int64(bytes.count)
        )
    }

    func upload(_ transfer: DeliveryUploadTransfer) throws {
        let index = itemIndex(transfer.localURL)
        if injection == .upload(itemIndex: index) { throw InjectedFailure.requested }
        uploadedItemIndices.append(index)
    }

    func remoteStat(_ transfer: DeliveryUploadTransfer) -> DeliveryRemoteStatObservation {
        let index = itemIndex(transfer.localURL)
        if injection == .remoteMissing(itemIndex: index) { return .missing }
        return .exists(byteCount: transfer.expectedByteCount)
    }

    func record(_ receipt: DeliveryReceipt) throws {
        if injection == .receiptWrite { throw InjectedFailure.requested }
        guard !recordedReceipts.contains(where: { $0.batchIdentifier == receipt.batchIdentifier }) else {
            throw InjectedFailure.requested
        }
        recordedReceipts.append(receipt)
    }

    func receipt(batchIdentifier: UUID) -> DeliveryReceipt? {
        recordedReceipts.first { $0.batchIdentifier == batchIdentifier }
    }

    func save(_ manifest: DeliveryWorkflowManifest) throws {
        if manifest.stage == failManifestAtStage {
            throw InjectedFailure.requested
        }
        if manifest.stage == .sent && shouldFailSentManifestSave {
            shouldFailSentManifestSave = false
            throw InjectedFailure.requested
        }
        savedManifest = manifest
    }

    func saveStagingDocument(_ document: DeliveryWorkflowStagingEvidenceDocument) throws {
        if injection == .stagingEvidenceWrite { throw InjectedFailure.requested }
        savedStagingDocument = document
    }

    private func itemIndex(_ url: URL) -> Int {
        plan.items.firstIndex { item in
            item.outputFilename == url.lastPathComponent
                || item.sourceRevision.canonicalURL == url
        }!
    }
}

private actor WorkflowProgressRecorder {
    private(set) var stages: [DeliveryWorkflowStage] = []
    func record(_ update: DeliveryWorkflowProgress) { stages.append(update.stage) }
}
