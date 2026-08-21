import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Staged delivery execution")
struct StagedDeliveryCoordinatorTests {
    @Test("stages sequentially, verifies exact bytes, publishes progress, and cleans up only explicitly")
    func successfulBatchAndExplicitCleanup() async throws {
        let fixture = try await makeFixture(itemCount: 2)
        let harness = StageHarness(plan: fixture.plan)
        let coordinator = makeCoordinator(harness: harness)
        let progress = ProgressRecorder()

        let result = try await coordinator.stage(fixture.request) { update in
            await progress.record(update)
        }

        #expect(result.status == .completed)
        #expect(result.requiredBytes == 100)
        #expect(result.verifiedItemCount == 2)
        #expect(result.items.map(\.stage) == [.verified, .verified])
        #expect(result.items.map(\.stagedByteCount) == [9, 9])
        #expect(result.items.map(\.stagedSHA256).allSatisfy { hash in
            hash?.count == 64 && hash?.lowercased() == hash
        })
        #expect(result.items.allSatisfy { $0.checkedFields == IPTCMetadataVerificationField.writableFields })
        #expect(result.items.allSatisfy { $0.mismatchedFields.isEmpty })
        #expect(result.items.allSatisfy { $0.metadataPreservation?.isAcceptableForDelivery == true })

        let beforeCleanup = await harness.snapshot()
        #expect(beforeCleanup.removedDirectories.isEmpty)
        #expect(beforeCleanup.maximumOpenReads == 1)
        #expect(beforeCleanup.verifiedPayloads == [Data("written-0".utf8), Data("written-1".utf8)])
        #expect(beforeCleanup.events == [
            "inspect-0", "inspect-1", "estimate", "capacity", "create",
            "inspect-0", "render-0", "write-0", "read-0", "verify-0", "preserve-0",
            "inspect-1", "render-1", "write-1", "read-1", "verify-1", "preserve-1",
        ])

        let updates = await progress.values
        #expect(updates.first?.currentItemIndex == nil)
        #expect(updates.last?.verifiedItemCount == 2)
        #expect(updates.allSatisfy { $0.batchID == result.batchID })

        try await coordinator.cleanup(result.cleanupToken)
        let afterCleanup = await harness.snapshot()
        #expect(afterCleanup.removedDirectories == [result.stagingDirectoryURL])
    }

    @Test("fingerprint, profile, and source drift are refused before a batch directory exists")
    func driftRefusalsBeforeWork() async throws {
        let fixture = try await makeFixture(itemCount: 1)

        let fingerprintHarness = StageHarness(plan: fixture.plan)
        let fingerprintCoordinator = makeCoordinator(harness: fingerprintHarness)
        let fingerprintRequest = DeliveryStagingRequest(
            plan: fixture.plan,
            expectedPlanFingerprint: String(repeating: "0", count: 64),
            currentProfile: fixture.plan.profile,
            stagingRootURL: fixture.request.stagingRootURL
        )
        await #expect(throws: DeliveryStagingPreflightError.planFingerprintDrift) {
            try await fingerprintCoordinator.stage(fingerprintRequest)
        }
        #expect((await fingerprintHarness.snapshot()).events.isEmpty)

        var changedProfile = fixture.plan.profile
        changedProfile.name = "Changed after confirmation"
        let profileHarness = StageHarness(plan: fixture.plan)
        let profileCoordinator = makeCoordinator(harness: profileHarness)
        let profileRequest = DeliveryStagingRequest(
            plan: fixture.plan,
            currentProfile: changedProfile,
            stagingRootURL: fixture.request.stagingRootURL
        )
        await #expect(throws: DeliveryStagingPreflightError.profileDrift) {
            try await profileCoordinator.stage(profileRequest)
        }
        #expect((await profileHarness.snapshot()).events.isEmpty)

        let sourceHarness = StageHarness(plan: fixture.plan, injection: .sourceDrift(itemIndex: 0))
        let sourceCoordinator = makeCoordinator(harness: sourceHarness)
        await #expect(throws: DeliveryStagingPreflightError.sourceDrift(itemIndex: 0)) {
            try await sourceCoordinator.stage(fixture.request)
        }
        #expect((await sourceHarness.snapshot()).events == ["inspect-0"])
    }

    @Test("source inspection, unknown space, insufficient space, and directory creation fail closed")
    func environmentalPreflightFailures() async throws {
        let fixture = try await makeFixture(itemCount: 1)

        let sourceHarness = StageHarness(plan: fixture.plan, injection: .sourceInspection(itemIndex: 0))
        await #expect(throws: DeliveryStagingPreflightError.sourceInspectionFailed(itemIndex: 0)) {
            try await makeCoordinator(harness: sourceHarness).stage(fixture.request)
        }

        let unknownHarness = StageHarness(plan: fixture.plan, injection: .unknownCapacity)
        await #expect(throws: DeliveryStagingPreflightError.freeSpaceUnknown) {
            try await makeCoordinator(harness: unknownHarness).stage(fixture.request)
        }
        #expect((await unknownHarness.snapshot()).events == ["inspect-0", "estimate", "capacity"])

        let estimateHarness = StageHarness(plan: fixture.plan, injection: .estimate(0))
        await #expect(throws: DeliveryStagingPreflightError.invalidStagingSizeEstimate) {
            try await makeCoordinator(harness: estimateHarness).stage(fixture.request)
        }
        #expect((await estimateHarness.snapshot()).events == ["inspect-0", "estimate"])

        let insufficientHarness = StageHarness(plan: fixture.plan, injection: .capacity(2))
        await #expect(throws: DeliveryStagingPreflightError.insufficientSpace(
            requiredBytes: 100,
            availableBytes: 2
        )) {
            try await makeCoordinator(harness: insufficientHarness).stage(fixture.request)
        }
        #expect((await insufficientHarness.snapshot()).events == ["inspect-0", "estimate", "capacity"])

        let createHarness = StageHarness(plan: fixture.plan, injection: .createDirectory)
        await #expect(throws: DeliveryStagingPreflightError.stagingDirectoryCreationFailed) {
            try await makeCoordinator(harness: createHarness).stage(fixture.request)
        }
        #expect((await createHarness.snapshot()).events == ["inspect-0", "estimate", "capacity", "create"])
    }

    @Test(
        "permission-denied and offline-iCloud sources are refused before staging",
        arguments: [
            StageHarness.Injection.sourcePermissionDenied(itemIndex: 0),
            .sourceICloudOffline(itemIndex: 0),
        ]
    )
    func unavailableSourceEnvironmentalDrills(
        injection: StageHarness.Injection
    ) async throws {
        let fixture = try await makeFixture(itemCount: 2)
        let harness = StageHarness(plan: fixture.plan, injection: injection)

        await #expect(throws: DeliveryStagingPreflightError.sourceInspectionFailed(itemIndex: 0)) {
            try await makeCoordinator(harness: harness).stage(fixture.request)
        }

        let snapshot = await harness.snapshot()
        #expect(snapshot.events == ["inspect-0"])
        #expect(!snapshot.events.contains("create"))
        let message = DeliveryStagingPreflightError.sourceInspectionFailed(itemIndex: 0)
            .localizedDescription.lowercased()
        #expect(!message.contains("private caption"))
        #expect(!message.contains("/private/"))
        #expect(!message.contains("icloud-account-secret"))
    }

    @Test("a simulated read-only staging root is refused without relying on process privileges")
    func readOnlyStagingRootDrill() async throws {
        let fixture = try await makeFixture(itemCount: 1)
        let harness = StageHarness(plan: fixture.plan, injection: .readOnlyStagingRoot)

        await #expect(throws: DeliveryStagingPreflightError.stagingDirectoryCreationFailed) {
            try await makeCoordinator(harness: harness).stage(fixture.request)
        }

        #expect((await harness.snapshot()).events == [
            "inspect-0", "estimate", "capacity", "create",
        ])
        #expect(!DeliveryStagingPreflightError.stagingDirectoryCreationFailed
            .localizedDescription.contains("/private/"))
    }

    @Test(
        "disk-full render or metadata write retains prior verified work and no file payload",
        arguments: [
            (
                StageHarness.Injection.diskFullDuringRender(itemIndex: 1),
                DeliveryStagingFailureCode.renderOrCopyFailed
            ),
            (
                StageHarness.Injection.diskFullDuringWrite(itemIndex: 1),
                DeliveryStagingFailureCode.metadataWriteFailed
            ),
        ]
    )
    func diskFullMidItemRetentionDrill(
        injection: StageHarness.Injection,
        expectedCode: DeliveryStagingFailureCode
    ) async throws {
        let fixture = try await makeFixture(itemCount: 3)
        let harness = StageHarness(plan: fixture.plan, injection: injection)
        let result = try await makeCoordinator(harness: harness).stage(fixture.request)

        #expect(result.status == .failed)
        #expect(result.items[0].stage == .verified)
        #expect(result.items[0].stagedSHA256 != nil)
        #expect(result.items[1].stage == .failed)
        #expect(result.items[1].failure?.code == expectedCode)
        #expect(result.items[2].stage == .pending)
        #expect(result.items[2].stagedByteCount == nil)
        #expect((await harness.snapshot()).removedDirectories.isEmpty)
        let failureMessage = try #require(result.items[1].failure?.message).lowercased()
        #expect(!failureMessage.contains("private caption"))
        #expect(!failureMessage.contains("/private/"))
        #expect(!failureMessage.contains("disk-volume-secret"))
    }

    @Test(
        "render, metadata write, staged-byte read, and read-back verifier failures retain earlier verified files",
        arguments: [
            (StageHarness.Injection.render(itemIndex: 1), DeliveryStagingFailureCode.renderOrCopyFailed),
            (StageHarness.Injection.write(itemIndex: 1), DeliveryStagingFailureCode.metadataWriteFailed),
            (StageHarness.Injection.read(itemIndex: 1), DeliveryStagingFailureCode.stagedBytesReadFailed),
            (StageHarness.Injection.verify(itemIndex: 1), DeliveryStagingFailureCode.metadataVerificationFailed),
        ]
    )
    func operationalFailureRetention(
        injection: StageHarness.Injection,
        expectedCode: DeliveryStagingFailureCode
    ) async throws {
        let fixture = try await makeFixture(itemCount: 2)
        let harness = StageHarness(plan: fixture.plan, injection: injection)
        let result = try await makeCoordinator(harness: harness).stage(fixture.request)

        #expect(result.status == .failed)
        #expect(result.items[0].stage == .verified)
        #expect(result.items[1].stage == .failed)
        #expect(result.items[1].failure?.code == expectedCode)
        #expect(result.items[0].stagedSHA256 != nil)
        #expect(result.items[1].stagedSHA256 == nil)
        #expect(result.items[1].failure?.message.contains("/private/") == false)
        #expect((await harness.snapshot()).removedDirectories.isEmpty)
    }

    @Test("controlled-field mismatch blocks completion with exact typed differences")
    func mismatchBlocksCompletion() async throws {
        let fixture = try await makeFixture(itemCount: 1)
        let harness = StageHarness(plan: fixture.plan, injection: .mismatch(itemIndex: 0))
        let result = try await makeCoordinator(harness: harness).stage(fixture.request)

        #expect(result.status == .failed)
        #expect(result.items[0].failure?.code == .metadataMismatch)
        #expect(result.items[0].mismatchedFields == [.headline])
        #expect(result.items[0].checkedFields == IPTCMetadataVerificationField.writableFields)
        #expect(result.items[0].stagedSHA256 == nil)
        #expect((await harness.snapshot()).removedDirectories.isEmpty)
    }

    @Test("Final post-metadata bytes above the configured ceiling never become upload eligible")
    func exactMaximumOutputByteCountIsEnforced() async throws {
        let fixture = try await makeFixture(itemCount: 2, maximumOutputByteCount: 8)
        let harness = StageHarness(plan: fixture.plan)
        let result = try await makeCoordinator(harness: harness).stage(fixture.request)

        #expect(result.status == .failed)
        #expect(result.items[0].stage == .failed)
        #expect(result.items[0].stagedByteCount == 9)
        #expect(result.items[0].stagedSHA256 == nil)
        #expect(result.items[0].metadataPreservation?.isAcceptableForDelivery == true)
        #expect(result.items[0].failure?.code == .outputExceedsMaximumByteCount)
        #expect(result.items[0].renderSettings?.maximumOutputByteCount == 8)
        #expect(result.items[1].stage == .pending)
        #expect((await harness.snapshot()).events == [
            "inspect-0", "inspect-1", "estimate", "capacity", "create",
            "inspect-0", "render-0", "write-0", "read-0", "verify-0", "preserve-0",
        ])
    }

    @Test(
        "unrelated metadata mismatch and unconfirmed inspection both fail closed",
        arguments: [
            (
                StageHarness.Injection.preservationMismatch(itemIndex: 0),
                DeliveryStagingFailureCode.metadataPreservationMismatch
            ),
            (
                StageHarness.Injection.preservationUnknown(itemIndex: 0),
                DeliveryStagingFailureCode.metadataPreservationUnconfirmed
            ),
        ]
    )
    func preservationFailureBlocksCompletion(
        injection: StageHarness.Injection,
        expectedCode: DeliveryStagingFailureCode
    ) async throws {
        let fixture = try await makeFixture(itemCount: 1)
        let harness = StageHarness(plan: fixture.plan, injection: injection)
        let result = try await makeCoordinator(harness: harness).stage(fixture.request)

        #expect(result.status == .failed)
        #expect(result.items[0].failure?.code == expectedCode)
        #expect(result.items[0].metadataPreservation != nil)
        #expect(result.items[0].metadataPreservation?.isAcceptableForDelivery == false)
        #expect(result.items[0].stagedSHA256 == nil)
        #expect((await harness.snapshot()).events.last == "preserve-0")
    }

    @Test(
        "cancellation at every operational boundary returns a retained recoverable batch",
        arguments: [
            DeliveryStagingItemStage.renderingOrCopying,
            .writingMetadata,
            .readingStagedBytes,
            .verifyingMetadata,
            .verifyingPreservation,
        ]
    )
    func cancellationRetention(stage: DeliveryStagingItemStage) async throws {
        let fixture = try await makeFixture(itemCount: 2)
        let injection: StageHarness.Injection = stage == .verifyingPreservation
            ? .none
            : .cancel(stage: stage, itemIndex: 1)
        let harness = StageHarness(plan: fixture.plan, injection: injection)
        let coordinator = makeCoordinator(harness: harness)
        let result = try await coordinator.stage(fixture.request) { update in
            guard stage == .verifyingPreservation,
                  update.currentItemIndex == 1,
                  update.items[1].stage == .verifyingPreservation else { return }
            await coordinator.requestCancellation()
        }

        #expect(result.status == .cancelled)
        #expect(result.items[0].stage == .verified)
        #expect(result.items[0].stagedSHA256 != nil)
        #expect(result.items[1].stage == .cancelled)
        #expect(result.items[1].stagedSHA256 == nil)
        #expect(result.items[1].failure == nil)
        #expect((await harness.snapshot()).removedDirectories.isEmpty)
    }

    @Test("unsafe cleanup token cannot delete outside the batch root")
    func cleanupBoundary() async throws {
        let fixture = try await makeFixture(itemCount: 1)
        let harness = StageHarness(plan: fixture.plan)
        let coordinator = makeCoordinator(harness: harness)
        let result = try await coordinator.stage(fixture.request)
        let unsafe = DeliveryStagingCleanupToken(
            batchID: result.batchID,
            planFingerprint: result.planFingerprint,
            stagingRootURL: fixture.request.stagingRootURL,
            stagingDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-the-batch")
        )

        await #expect(throws: DeliveryStagingCleanupError.invalidToken) {
            try await coordinator.cleanup(unsafe)
        }
        let uppercaseFingerprint = DeliveryStagingCleanupToken(
            batchID: result.batchID,
            planFingerprint: result.planFingerprint.uppercased(),
            stagingRootURL: result.cleanupToken.stagingRootURL,
            stagingDirectoryURL: result.cleanupToken.stagingDirectoryURL
        )
        await #expect(throws: DeliveryStagingCleanupError.invalidToken) {
            try await coordinator.cleanup(uppercaseFingerprint)
        }
        #expect((await harness.snapshot()).removedDirectories.isEmpty)
    }

    @Test("a reentrant second batch is refused while the first batch is suspended")
    func concurrentBatchRefusal() async throws {
        let fixture = try await makeFixture(itemCount: 1)
        let harness = StageHarness(plan: fixture.plan)
        let gate = StagingEstimateGate()
        let coordinator = makeCoordinator(
            harness: harness,
            sizeEstimator: DeliveryStagingSizeEstimator { _ in
                await gate.estimate()
            }
        )

        let first = Task { try await coordinator.stage(fixture.request) }
        await gate.waitUntilEntered()
        await #expect(throws: DeliveryStagingPreflightError.alreadyExecuting) {
            try await coordinator.stage(fixture.request)
        }
        await gate.release()
        let firstResult = try await first.value
        #expect(firstResult.status == .completed)
        #expect((await harness.snapshot()).events.count { $0 == "create" } == 1)
    }

    @Test("explicit cancellation requested during an awaited preflight step stops at its boundary")
    func explicitBoundaryCancellation() async throws {
        let fixture = try await makeFixture(itemCount: 1)
        let harness = StageHarness(plan: fixture.plan)
        let gate = StagingEstimateGate()
        let coordinator = makeCoordinator(
            harness: harness,
            sizeEstimator: DeliveryStagingSizeEstimator { _ in await gate.estimate() }
        )

        let operation = Task { try await coordinator.stage(fixture.request) }
        await gate.waitUntilEntered()
        await coordinator.requestCancellation()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(!(await harness.snapshot()).events.contains("create"))
    }

    @Test("1,000-item staging keeps one byte payload in flight and remains boundary-cancellable")
    func largeBatchHasBoundedByteWorkingSet() async throws {
        let itemCount = 1_000
        let payloadByteCount = 64 * 1_024
        let fixture = try await makeFixture(itemCount: itemCount)
        let sourceRevisions = Dictionary(uniqueKeysWithValues: fixture.plan.items.map {
            ($0.sourceRevision.canonicalURL, $0.sourceRevision)
        })
        let probe = LargeBatchStagingProbe(
            sourceRevisions: sourceRevisions,
            payloadByteCount: payloadByteCount
        )
        let coordinator = makeLargeBatchCoordinator(probe: probe)

        let startedAt = ContinuousClock.now
        let result = try await coordinator.stage(fixture.request)
        let elapsed = startedAt.duration(to: .now)

        #expect(result.status == .completed)
        #expect(result.items.count == itemCount)
        #expect(result.items.allSatisfy { $0.stage == .verified })
        #expect(result.items.allSatisfy { $0.stagedByteCount == payloadByteCount })
        let snapshot = probe.snapshot()
        #expect(snapshot.readCount == itemCount)
        #expect(snapshot.maximumActivePayloads == 1)
        #expect(snapshot.activePayloads == 0)
        #expect(snapshot.maximumConcurrentOperations == 1)

        // The retained result is O(item-count) fixed evidence. It contains neither staged file
        // payloads nor the frozen plan's editorial values.
        let encoded = try JSONEncoder().encode(result)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("Caption 999"))
        #expect(!json.contains("stagedBytes"))
        #expect(encoded.count < itemCount * 2_000)

        let cancellationProbe = LargeBatchStagingProbe(
            sourceRevisions: sourceRevisions,
            payloadByteCount: payloadByteCount
        )
        let cancellationCoordinator = makeLargeBatchCoordinator(probe: cancellationProbe)
        let cancelled = try await cancellationCoordinator.stage(fixture.request) { update in
            guard update.currentItemIndex == 25,
                  update.items[25].stage == .renderingOrCopying else { return }
            await cancellationCoordinator.requestCancellation()
        }
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.verifiedItemCount == 25)
        #expect(cancelled.items[25].stage == .cancelled)
        #expect(cancellationProbe.snapshot().readCount == 25)

        // Keeps the measured runtime visible in failure output without enforcing a flaky wall
        // clock threshold on shared CI machines.
        #expect(elapsed > .zero)
    }

    private func makeCoordinator(
        harness: StageHarness,
        sizeEstimator: DeliveryStagingSizeEstimator? = nil
    ) -> StagedDeliveryCoordinator {
        StagedDeliveryCoordinator(
            fileSystem: DeliveryStagingFileSystem(
                availableCapacity: { url in try await harness.availableCapacity(at: url) },
                createUniqueBatchDirectory: { root, batchID in
                    try await harness.createDirectory(root: root, batchID: batchID)
                },
                readStagedBytes: { url in try await harness.read(url: url) },
                removeBatchDirectory: { url in await harness.remove(url: url) }
            ),
            renderer: DeliveryStageRenderer { item, snapshot, url in
                try await harness.render(item: item, snapshot: snapshot, destination: url)
            },
            metadataWriter: DeliveryStageMetadataWriter { metadata, snapshot, url in
                try await harness.write(metadata: metadata, snapshot: snapshot, url: url)
            },
            metadataVerifier: DeliveryStageMetadataVerifier { bytes, url, expected, fields in
                try await harness.verify(bytes: bytes, url: url, expected: expected, fields: fields)
            },
            preservationVerifier: DeliveryStageMetadataPreservationVerifier { source, bytes, staged in
                await harness.preserve(sourceURL: source, stagedBytes: bytes, stagedURL: staged)
            },
            sourceInspector: DeliverySourceRevisionInspector { url in
                try await harness.inspect(url: url)
            },
            sizeEstimator: sizeEstimator ?? DeliveryStagingSizeEstimator { plan in
                try await harness.estimate(plan: plan)
            }
        )
    }

    private func makeLargeBatchCoordinator(
        probe: LargeBatchStagingProbe
    ) -> StagedDeliveryCoordinator {
        StagedDeliveryCoordinator(
            fileSystem: DeliveryStagingFileSystem(
                availableCapacity: { _ in Int64.max },
                createUniqueBatchDirectory: { root, batchID in
                    root.appendingPathComponent(
                        "deadline-\(batchID.uuidString.lowercased())",
                        isDirectory: true
                    )
                },
                readStagedBytes: { url in await probe.readPayload(for: url) },
                removeBatchDirectory: { _ in }
            ),
            renderer: DeliveryStageRenderer { item, snapshot, _ in
                await probe.recordOperation()
                return DeliveryRenderSettings(
                    formatIdentifier: snapshot.export.sdrFormat.rawValue,
                    colorSpaceIdentifier: snapshot.export.sdrGamut.rawValue,
                    pixelWidth: 4_000,
                    pixelHeight: 2_667,
                    bitDepth: 8,
                    quality: Int((snapshot.export.sdrQuality * 100).rounded())
                )
            },
            metadataWriter: DeliveryStageMetadataWriter { _, _, _ in
                await probe.recordOperation()
            },
            metadataVerifier: DeliveryStageMetadataVerifier { bytes, _, expected, fields in
                await probe.recordOperation()
                #expect(bytes.count == probe.payloadByteCount)
                return IPTCMetadataVerifier.compare(
                    expected: expected,
                    actual: expected,
                    fields: fields
                )
            },
            preservationVerifier: DeliveryStageMetadataPreservationVerifier { _, bytes, _ in
                await probe.recordOperation()
                #expect(bytes.count == probe.payloadByteCount)
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
            },
            sourceInspector: DeliverySourceRevisionInspector { url in
                try await probe.sourceRevision(for: url)
            },
            sizeEstimator: DeliveryStagingSizeEstimator { plan in
                Int64(plan.items.count * probe.payloadByteCount)
            }
        )
    }

    private func makeFixture(
        itemCount: Int,
        maximumOutputByteCount: Int64? = nil
    ) async throws -> StagingFixture {
        let export = DeadlineExportSnapshot(
            sdrFormat: .jpeg,
            sdrQuality: 0.9,
            sdrGamut: .sRGB,
            hdrFormat: .jpegGainMap,
            hdrQuality: 0.85,
            hdrGamut: .displayP3,
            tiffCompression: .lzw,
            resolutionLimit: .pixels4000,
            maximumOutputByteCount: maximumOutputByteCount
        )
        let connectionID = UUID(uuidString: "51000000-0000-0000-0000-000000000005")!
        let profile = DeadlineProfile(
            id: UUID(uuidString: "31000000-0000-0000-0000-000000000003")!,
            name: "Wire desk",
            validationProfile: .snapshot(MetadataValidationProfile(
                id: UUID(uuidString: "11000000-0000-0000-0000-000000000001")!,
                name: "No required fields",
                rules: []
            )),
            export: .snapshot(export),
            destination: DeadlineDestinationConfiguration(
                connectionIdentifier: connectionID.uuidString.lowercased(),
                remotePathTemplate: "/incoming/desk"
            ),
            gpsPolicy: .retain,
            metadataWriteStrategy: .stagedCopies
        )
        let metadata = (0..<itemCount).map { IPTCMetadata(title: "Caption \($0)") }
        let revisions = (0..<itemCount).map { index -> SourceImageRevision in
            let sourceURL = URL(fileURLWithPath: "/private/tmp/stage-source-\(index).jpg")
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            return SourceImageRevision(
                canonicalURL: sourceURL,
                fileResourceIdentifier: nil,
                filenameAtCreation: sourceURL.lastPathComponent,
                byteCount: Int64(index + 3),
                contentModificationDate: date,
                pixelWidth: 6000,
                pixelHeight: 4000,
                exifOrientation: 1,
                sha256: String(
                    repeating: String(index % 16, radix: 16),
                    count: 64
                ),
                hashCompletedAt: date.addingTimeInterval(1)
            )
        }
        let preflightItems = revisions.enumerated().map { index, revision in
            DeadlinePreflightItemSnapshot(
                sourceURL: revision.canonicalURL,
                metadata: metadata[index],
                source: DeadlineSourceSnapshot(
                    byteCount: revision.byteCount,
                    pixelWidth: 6000,
                    pixelHeight: 4000
                ),
                estimatedOutputByteCount: maximumOutputByteCount.map { min($0, 8) }
            )
        }
        let preflightRequest = DeadlinePreflightRequest(
            profile: profile,
            items: preflightItems,
            renameEnvironment: RenamePlanningEnvironment(
                caseSensitivity: .caseInsensitive,
                existingURLs: [],
                isComplete: true
            ),
            delivery: DeadlineBatchDeliverySnapshot(
                destinationAvailableBytes: 100_000,
                estimatedRequiredBytes: 10_000,
                stagingState: .ready,
                connections: [connectionID.uuidString.lowercased(): .reachable],
                remotePathState: .valid(resolvedPath: "/incoming/desk")
            )
        )
        let report = try await DeadlinePreflightService().evaluate(preflightRequest)
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
        let plan = try DeliveryPlanningService().makePlan(DeliveryPlanningRequest(
            preflightRequest: preflightRequest,
            publication: publication,
            currentRevision: token,
            currentProfile: profile,
            items: revisions.enumerated().map { index, revision in
                DeliveryPlanningItemInput(sourceRevision: revision, resolvedMetadata: metadata[index])
            }
        ))
        let root = URL(fileURLWithPath: "/private/tmp/deadline-staging-root", isDirectory: true)
        return StagingFixture(
            plan: plan,
            request: DeliveryStagingRequest(
                plan: plan,
                currentProfile: profile,
                stagingRootURL: root
            )
        )
    }
}

private struct StagingFixture {
    let plan: DeliveryPlan
    let request: DeliveryStagingRequest
}

private nonisolated final class LargeBatchStagingProbe: @unchecked Sendable {
    struct Snapshot: Sendable {
        let readCount: Int
        let activePayloads: Int
        let maximumActivePayloads: Int
        let maximumConcurrentOperations: Int
    }

    let payloadByteCount: Int

    private let lock = NSLock()
    private let sourceRevisions: [URL: SourceImageRevision]
    private var reads = 0
    private var activePayloads = 0
    private var maximumActivePayloads = 0
    private var activeOperations = 0
    private var maximumConcurrentOperations = 0

    init(sourceRevisions: [URL: SourceImageRevision], payloadByteCount: Int) {
        self.sourceRevisions = sourceRevisions
        self.payloadByteCount = payloadByteCount
    }

    func sourceRevision(for url: URL) async throws -> SourceImageRevision {
        await recordOperation()
        guard let revision = sourceRevisions[url] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return revision
    }

    func recordOperation() async {
        lock.withLock {
            activeOperations += 1
            maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperations)
        }
        await Task.yield()
        lock.withLock { activeOperations -= 1 }
    }

    func readPayload(for url: URL) async -> Data {
        _ = url
        await recordOperation()
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: payloadByteCount,
            alignment: MemoryLayout<UInt8>.alignment
        )
        UnsafeMutableRawBufferPointer(start: pointer, count: payloadByteCount)
            .initializeMemory(as: UInt8.self, repeating: 0x5a)

        lock.withLock {
            reads += 1
            activePayloads += 1
            maximumActivePayloads = max(maximumActivePayloads, activePayloads)
        }

        return Data(bytesNoCopy: pointer, count: payloadByteCount, deallocator: .custom {
            [self] releasedPointer, _ in
            releasedPointer.deallocate()
            lock.lock()
            activePayloads -= 1
            lock.unlock()
        })
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            readCount: reads,
            activePayloads: activePayloads,
            maximumActivePayloads: maximumActivePayloads,
            maximumConcurrentOperations: maximumConcurrentOperations
        )
    }
}

private actor ProgressRecorder {
    private(set) var values: [DeliveryStagingProgress] = []
    func record(_ value: DeliveryStagingProgress) { values.append(value) }
}

private actor StagingEstimateGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func estimate() async -> Int64 {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        return 100
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

actor StageHarness {
    enum Injection: Equatable, Sendable {
        case none
        case sourceInspection(itemIndex: Int)
        case sourcePermissionDenied(itemIndex: Int)
        case sourceICloudOffline(itemIndex: Int)
        case sourceDrift(itemIndex: Int)
        case unknownCapacity
        case capacity(Int64)
        case estimate(Int64)
        case createDirectory
        case readOnlyStagingRoot
        case render(itemIndex: Int)
        case diskFullDuringRender(itemIndex: Int)
        case write(itemIndex: Int)
        case diskFullDuringWrite(itemIndex: Int)
        case read(itemIndex: Int)
        case verify(itemIndex: Int)
        case mismatch(itemIndex: Int)
        case preservationMismatch(itemIndex: Int)
        case preservationUnknown(itemIndex: Int)
        case cancel(stage: DeliveryStagingItemStage, itemIndex: Int)
    }

    struct Snapshot: Sendable {
        let events: [String]
        let removedDirectories: [URL]
        let verifiedPayloads: [Data]
        let maximumOpenReads: Int
    }

    enum InjectedFailure: Error { case requested }

    struct InjectedEnvironmentalFailure: LocalizedError {
        let errorDescription: String? =
            "Injected environmental failure at /private/disk-volume-secret/icloud-account-secret"
    }

    private let plan: DeliveryPlan
    private let injection: Injection
    private var events: [String] = []
    private var removedDirectories: [URL] = []
    private var payloads: [Int: Data] = [:]
    private var verifiedPayloads: [Data] = []
    private var openReads = 0
    private var maximumOpenReads = 0

    init(plan: DeliveryPlan, injection: Injection = .none) {
        self.plan = plan
        self.injection = injection
    }

    func inspect(url: URL) throws -> SourceImageRevision {
        let index = itemIndex(for: url)
        events.append("inspect-\(index)")
        if injection == .sourceInspection(itemIndex: index) { throw InjectedFailure.requested }
        if injection == .sourcePermissionDenied(itemIndex: index)
            || injection == .sourceICloudOffline(itemIndex: index) {
            throw InjectedEnvironmentalFailure()
        }
        let expected = plan.items[index].sourceRevision
        if injection == .sourceDrift(itemIndex: index) {
            return SourceImageRevision(
                canonicalURL: expected.canonicalURL,
                fileResourceIdentifier: expected.fileResourceIdentifier,
                filenameAtCreation: expected.filenameAtCreation,
                byteCount: expected.byteCount,
                contentModificationDate: expected.contentModificationDate,
                pixelWidth: expected.pixelWidth,
                pixelHeight: expected.pixelHeight,
                exifOrientation: expected.exifOrientation,
                sha256: String(repeating: "f", count: 64),
                hashCompletedAt: expected.hashCompletedAt
            )
        }
        return expected
    }

    func availableCapacity(at _: URL) throws -> Int64? {
        events.append("capacity")
        switch injection {
        case .unknownCapacity: return nil
        case let .capacity(value): return value
        default: return 1_000_000
        }
    }

    func estimate(plan _: DeliveryPlan) throws -> Int64 {
        events.append("estimate")
        if case let .estimate(value) = injection { return value }
        return 100
    }

    func createDirectory(root: URL, batchID: UUID) throws -> URL {
        events.append("create")
        if injection == .createDirectory { throw InjectedFailure.requested }
        if injection == .readOnlyStagingRoot { throw InjectedEnvironmentalFailure() }
        return root.appendingPathComponent(
            "deadline-\(batchID.uuidString.lowercased())",
            isDirectory: true
        )
    }

    func render(
        item: DeliveryPlanStageItem,
        snapshot: DeliveryRenderWriteSnapshot,
        destination _: URL
    ) throws -> DeliveryRenderSettings {
        events.append("render-\(item.itemIndex)")
        if injection == .diskFullDuringRender(itemIndex: item.itemIndex) {
            throw InjectedEnvironmentalFailure()
        }
        try inject(stage: .renderingOrCopying, itemIndex: item.itemIndex, failure: .render(itemIndex: item.itemIndex))
        payloads[item.itemIndex] = Data("rendered-\(item.itemIndex)".utf8)
        if item.isHDR {
            return DeliveryRenderSettings(
                formatIdentifier: snapshot.export.hdrFormat.rawValue,
                colorSpaceIdentifier: snapshot.export.hdrGamut.rawValue,
                pixelWidth: 4_000,
                pixelHeight: 2_667,
                bitDepth: nil,
                quality: Int((snapshot.export.hdrQuality * 100).rounded())
            )
        }
        return DeliveryRenderSettings(
            formatIdentifier: snapshot.export.sdrFormat.rawValue,
            colorSpaceIdentifier: snapshot.export.sdrGamut.rawValue,
            pixelWidth: 4_000,
            pixelHeight: 2_667,
            bitDepth: 8,
            quality: Int((snapshot.export.sdrQuality * 100).rounded())
        )
    }

    func write(
        metadata _: IPTCMetadata,
        snapshot _: DeliveryRenderWriteSnapshot,
        url: URL
    ) throws {
        let index = itemIndex(for: url)
        events.append("write-\(index)")
        if injection == .diskFullDuringWrite(itemIndex: index) {
            throw InjectedEnvironmentalFailure()
        }
        try inject(stage: .writingMetadata, itemIndex: index, failure: .write(itemIndex: index))
        payloads[index] = Data("written-\(index)".utf8)
    }

    func read(url: URL) throws -> Data {
        let index = itemIndex(for: url)
        events.append("read-\(index)")
        try inject(stage: .readingStagedBytes, itemIndex: index, failure: .read(itemIndex: index))
        openReads += 1
        maximumOpenReads = max(maximumOpenReads, openReads)
        defer { openReads -= 1 }
        return payloads[index] ?? Data()
    }

    func verify(
        bytes: Data,
        url: URL,
        expected: IPTCMetadata,
        fields: [IPTCMetadataVerificationField]
    ) throws -> IPTCMetadataVerificationReport {
        let index = itemIndex(for: url)
        events.append("verify-\(index)")
        try inject(stage: .verifyingMetadata, itemIndex: index, failure: .verify(itemIndex: index))
        verifiedPayloads.append(bytes)
        var actual = expected
        if injection == .mismatch(itemIndex: index) { actual.title = "Different headline" }
        return IPTCMetadataVerifier.compare(expected: expected, actual: actual, fields: fields)
    }

    func preserve(
        sourceURL _: URL,
        stagedBytes _: Data,
        stagedURL: URL
    ) -> MetadataPreservationVerificationReport {
        let index = itemIndex(for: stagedURL)
        events.append("preserve-\(index)")
        if injection == .preservationUnknown(itemIndex: index) {
            return .unknown(sourceFormatIdentifier: "jpeg", stagedFormatIdentifier: "jpeg")
        }

        return MetadataPreservationVerificationReport(
            sourceFormatIdentifier: "jpeg",
            stagedFormatIdentifier: "jpeg",
            domains: MetadataPreservationDomain.allCases.map { domain in
                MetadataPreservationDomainResult(
                    domain: domain,
                    status: injection == .preservationMismatch(itemIndex: index) && domain == .xmp
                        ? .mismatch
                        : .match,
                    sourceIdentity: String(repeating: "a", count: 64),
                    stagedIdentity: injection == .preservationMismatch(itemIndex: index) && domain == .xmp
                        ? String(repeating: "b", count: 64)
                        : String(repeating: "a", count: 64)
                )
            },
            c2paConsequence: .absentFromBoth
        )
    }

    func remove(url: URL) { removedDirectories.append(url) }

    func snapshot() -> Snapshot {
        Snapshot(
            events: events,
            removedDirectories: removedDirectories,
            verifiedPayloads: verifiedPayloads,
            maximumOpenReads: maximumOpenReads
        )
    }

    private func inject(
        stage: DeliveryStagingItemStage,
        itemIndex: Int,
        failure: Injection
    ) throws {
        if injection == .cancel(stage: stage, itemIndex: itemIndex) { throw CancellationError() }
        if injection == failure { throw InjectedFailure.requested }
    }

    private func itemIndex(for url: URL) -> Int {
        if let index = plan.items.firstIndex(where: {
            $0.sourceRevision.canonicalURL == url || $0.outputFilename == url.lastPathComponent
        }) {
            return index
        }
        preconditionFailure("Unknown staging URL \(url.path)")
    }
}
