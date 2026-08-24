import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Verified delivery upload")
struct VerifiedDeliveryUploadCoordinatorTests {
    @Test("verified staging input refuses incomplete, mismatched, and stale artifacts")
    func verifiedInputRefusals() async throws {
        let fixture = try await UploadFixture(itemCount: 1)
        defer { fixture.remove() }

        var item = fixture.stagingResult.items[0]
        item.stage = .failed
        item.stagedSHA256 = nil
        let failed = fixture.stagingResult(replacing: [item], status: .failed)
        #expect(throws: DeliveryUploadPreflightError.stagingBatchNotCompleted) {
            try DeliveryVerifiedStagedBatch.validated(
                plan: fixture.plan,
                stagingResult: failed
            )
        }

        let original = fixture.stagingResult.items[0]
        item = DeliveryStagingItemResult(
            itemIndex: original.itemIndex,
            stageInputFingerprint: String(repeating: "0", count: 64),
            stagedRelativePath: original.stagedRelativePath,
            stage: original.stage,
            stagedByteCount: original.stagedByteCount,
            stagedSHA256: original.stagedSHA256,
            renderSettings: original.renderSettings,
            metadataPreservation: original.metadataPreservation,
            checkedFields: original.checkedFields,
            mismatchedFields: original.mismatchedFields,
            failure: original.failure
        )
        let stale = fixture.stagingResult(replacing: [item])
        #expect(throws: DeliveryUploadPreflightError.stageFingerprintDrift(itemIndex: 0)) {
            try DeliveryVerifiedStagedBatch.validated(
                plan: fixture.plan,
                stagingResult: stale
            )
        }

        item = fixture.stagingResult.items[0]
        item.mismatchedFields = [.headline]
        let mismatched = fixture.stagingResult(replacing: [item])
        #expect(throws: DeliveryUploadPreflightError.stagingArtifactMismatch(itemIndex: 0)) {
            try DeliveryVerifiedStagedBatch.validated(
                plan: fixture.plan,
                stagingResult: mismatched
            )
        }

        item = fixture.stagingResult.items[0]
        item.metadataPreservation = MetadataPreservationVerificationReport(
            sourceFormatIdentifier: "raw",
            stagedFormatIdentifier: "jpeg",
            domains: MetadataPreservationDomain.allCases.map {
                MetadataPreservationDomainResult(
                    domain: $0,
                    status: .match,
                    sourceIdentity: nil,
                    stagedIdentity: nil
                )
            },
            c2paConsequence: .unknown
        )
        let forgedPreservation = fixture.stagingResult(replacing: [item])
        #expect(throws: DeliveryUploadPreflightError.stagingArtifactMismatch(itemIndex: 0)) {
            try DeliveryVerifiedStagedBatch.validated(
                plan: fixture.plan,
                stagingResult: forgedPreservation
            )
        }
    }

    @Test("same-size tampering after read-back verification is refused before transport")
    func sameSizeTamperRefusal() async throws {
        let fixture = try await UploadFixture(itemCount: 1, stagedContents: [Data("AAAA".utf8)])
        defer { fixture.remove() }
        let staged = try fixture.verifiedBatch()
        try Data("BBBB".utf8).write(to: staged.artifacts[0].localURL, options: .atomic)

        let recorder = UploadRecorder()
        let coordinator = VerifiedDeliveryUploadCoordinator(transport: recorder.transport())
        await #expect(throws: DeliveryUploadPreflightError.artifactEvidenceMismatch(itemIndex: 0)) {
            _ = try await coordinator.upload(DeliveryUploadRequest(
                plan: fixture.plan,
                stagedBatch: staged
            ))
        }
        #expect(await recorder.uploadedItemIndices().isEmpty)
    }

    @Test("protocol acknowledgement and remote size remain distinct evidence")
    func remoteStatEvidence() async throws {
        let fixture = try await UploadFixture(itemCount: 1)
        defer { fixture.remove() }
        let recorder = UploadRecorder(remoteObservation: .exists(
            byteCount: Int64(fixture.stagingResult.items[0].stagedByteCount!)
        ))
        let states = UploadProgressRecorder()
        let coordinator = VerifiedDeliveryUploadCoordinator(
            transport: recorder.transport(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = try await coordinator.upload(
            DeliveryUploadRequest(
                plan: fixture.plan,
                stagedBatch: fixture.verifiedBatch(),
                remoteStatPolicy: .attemptIfAvailable
            ),
            progress: { progress in await states.record(progress.items[0].stage) }
        )

        #expect(result.status == .completed)
        #expect(result.items[0].stage == .sent)
        #expect(result.items[0].uploadAcknowledgement.status == .protocolAcknowledged)
        guard case let .sizeMatches(_, observedSize) = result.items[0].remoteConfirmation else {
            Issue.record("Expected a separate remote-size match")
            return
        }
        #expect(observedSize == result.items[0].localEvidence?.byteCount)
        let recordedStates = await states.values()
        #expect(recordedStates.contains(.uploading))
        #expect(recordedStates.contains(.remoteConfirming))
        #expect(recordedStates.contains(.sent))
    }

    @Test("remote size mismatch fails without claiming cryptographic verification")
    func remoteSizeMismatch() async throws {
        let fixture = try await UploadFixture(itemCount: 1)
        defer { fixture.remove() }
        let recorder = UploadRecorder(remoteObservation: .exists(byteCount: 999))
        let coordinator = VerifiedDeliveryUploadCoordinator(transport: recorder.transport())

        let result = try await coordinator.upload(DeliveryUploadRequest(
            plan: fixture.plan,
            stagedBatch: fixture.verifiedBatch(),
            remoteStatPolicy: .attemptIfAvailable
        ))

        #expect(result.status == .failed)
        #expect(result.items[0].stage == .failed)
        #expect(result.items[0].failure?.code == .remoteByteCountMismatch)
        #expect(result.items[0].uploadAcknowledgement.status == .protocolAcknowledged)
        guard case .sizeMismatch = result.items[0].remoteConfirmation else {
            Issue.record("Expected non-cryptographic size-mismatch evidence")
            return
        }
        #expect(result.checkpoint.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.stagedURLs[0].path))
    }

    @Test("failure retains inputs and retry starts at the failed file boundary")
    func failureAndRetry() async throws {
        let fixture = try await UploadFixture(itemCount: 3)
        defer { fixture.remove() }
        let firstTransport = UploadRecorder(failingCalls: [2])
        let firstCoordinator = VerifiedDeliveryUploadCoordinator(
            transport: firstTransport.transport(),
            now: { Date(timeIntervalSince1970: 100) }
        )
        let first = try await firstCoordinator.upload(DeliveryUploadRequest(
            plan: fixture.plan,
            stagedBatch: fixture.verifiedBatch()
        ))

        #expect(first.status == .failed)
        #expect(first.items.map(\.stage) == [.sent, .failed, .queued])
        #expect(first.items[1].failure?.code == .uploadRejected)
        #expect(first.checkpoint.items.map(\.itemIndex) == [0])
        #expect(fixture.stagedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let retryTransport = UploadRecorder()
        let retryCoordinator = VerifiedDeliveryUploadCoordinator(
            transport: retryTransport.transport(),
            now: { Date(timeIntervalSince1970: 101) }
        )
        let retry = try await retryCoordinator.upload(DeliveryUploadRequest(
            plan: fixture.plan,
            stagedBatch: fixture.verifiedBatch(),
            resumeCheckpoint: first.checkpoint
        ))

        #expect(retry.status == .completed)
        #expect(retry.items.allSatisfy { $0.stage == .sent })
        #expect(await retryTransport.uploadedItemIndices() == [1, 2])
    }

    @Test("network unavailable before the first file retains every item for retry")
    func networkDropBeforeFirstFile() async throws {
        let fixture = try await UploadFixture(itemCount: 3)
        defer { fixture.remove() }
        let unavailable = UploadRecorder(failingCalls: [1])
        let first = try await VerifiedDeliveryUploadCoordinator(
            transport: unavailable.transport()
        ).upload(DeliveryUploadRequest(
            plan: fixture.plan,
            stagedBatch: fixture.verifiedBatch()
        ))

        #expect(first.status == .failed)
        #expect(first.items.map(\.stage) == [.failed, .queued, .queued])
        #expect(first.items[0].failure?.code == .uploadRejected)
        #expect(first.checkpoint.items.isEmpty)
        let failureJSON = String(
            decoding: try JSONEncoder().encode(first),
            as: UTF8.self
        ).lowercased()
        #expect(!failureJSON.contains("private caption"))
        #expect(!failureJSON.contains("password"))
        #expect(!failureJSON.contains(fixture.rootURL.path.lowercased()))

        let retryTransport = UploadRecorder()
        let retry = try await VerifiedDeliveryUploadCoordinator(
            transport: retryTransport.transport()
        ).upload(DeliveryUploadRequest(
            plan: fixture.plan,
            stagedBatch: fixture.verifiedBatch(),
            resumeCheckpoint: first.checkpoint
        ))
        #expect(retry.status == .completed)
        #expect(await retryTransport.uploadedItemIndices() == [0, 1, 2])
    }

    @Test("a network drop during a file finishes that boundary and retries from the failed file")
    func networkDropDuringFileBoundary() async throws {
        let fixture = try await UploadFixture(itemCount: 3)
        defer { fixture.remove() }
        let gate = NetworkDropBoundaryGate(dropItemIndex: 1)
        let coordinator = VerifiedDeliveryUploadCoordinator(transport: gate.transport())
        let operation = Task {
            try await coordinator.upload(DeliveryUploadRequest(
                plan: fixture.plan,
                stagedBatch: fixture.verifiedBatch()
            ))
        }

        await gate.waitUntilDroppedTransferStarts()
        await coordinator.requestCancellation()
        #expect(!(await gate.hasDroppedTransferFinished()))
        await gate.releaseDroppedTransfer()
        let first = try await operation.value

        // A transport failure wins for the active file; cancellation never relabels an ambiguous
        // partial remote object as safely cancelled. The prior acknowledged prefix remains exact.
        #expect(first.status == .failed)
        #expect(first.items.map(\.stage) == [.sent, .failed, .queued])
        #expect(first.items[1].failure?.code == .uploadRejected)
        #expect(first.checkpoint.items.map(\.itemIndex) == [0])
        #expect(await gate.startedItemIndices() == [0, 1])

        let retryTransport = UploadRecorder()
        let retry = try await VerifiedDeliveryUploadCoordinator(
            transport: retryTransport.transport()
        ).upload(DeliveryUploadRequest(
            plan: fixture.plan,
            stagedBatch: fixture.verifiedBatch(),
            resumeCheckpoint: first.checkpoint
        ))
        #expect(retry.status == .completed)
        #expect(await retryTransport.uploadedItemIndices() == [1, 2])
    }

    @Test("JSON checkpoint supports relaunch resume and omits sensitive inputs")
    func relaunchResumeAndCheckpointPrivacy() async throws {
        let fixture = try await UploadFixture(itemCount: 2)
        defer { fixture.remove() }
        let firstTransport = UploadRecorder(failingCalls: [2])
        let firstCoordinator = VerifiedDeliveryUploadCoordinator(
            transport: firstTransport.transport(),
            now: { Date(timeIntervalSince1970: 200) }
        )
        let first = try await firstCoordinator.upload(DeliveryUploadRequest(
            plan: fixture.plan,
            stagedBatch: fixture.verifiedBatch()
        ))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(first.checkpoint)
        let json = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!json.contains("private caption"))
        #expect(!json.contains("password"))
        #expect(!json.contains("username"))
        #expect(!json.contains("localurl"))
        #expect(!json.contains("outputfilename"))
        #expect(!json.contains(fixture.rootURL.path.lowercased()))

        let reopened = try JSONDecoder().decode(DeliveryUploadCheckpoint.self, from: data)
        let relaunchedTransport = UploadRecorder()
        let relaunched = VerifiedDeliveryUploadCoordinator(
            transport: relaunchedTransport.transport(),
            now: { Date(timeIntervalSince1970: 201) }
        )
        let result = try await relaunched.upload(DeliveryUploadRequest(
            plan: fixture.plan,
            stagedBatch: fixture.verifiedBatch(),
            resumeCheckpoint: reopened
        ))

        #expect(result.status == .completed)
        #expect(await relaunchedTransport.uploadedItemIndices() == [1])
    }

    @Test("resume checkpoint must be a timestamp-coherent sequential prefix")
    func checkpointIntegrity() async throws {
        let fixture = try await UploadFixture(itemCount: 2)
        defer { fixture.remove() }
        let evidence = try await DeliveryUploadFileInspector.live.inspect(fixture.stagedURLs[1])
        let nonPrefix = DeliveryUploadCheckpoint(
            planFingerprint: fixture.plan.fingerprint,
            stagingBatchIdentifier: fixture.stagingResult.batchID,
            items: [DeliveryUploadCheckpointItem(
                itemIndex: 1,
                stageInputFingerprint: fixture.plan.items[1].stageInputFingerprint,
                localEvidence: evidence,
                uploadAcknowledgedAt: Date(timeIntervalSince1970: 10),
                remoteConfirmation: .notRequested
            )]
        )
        let coordinator = VerifiedDeliveryUploadCoordinator(
            transport: UploadRecorder().transport()
        )
        await #expect(throws: DeliveryUploadPreflightError.invalidResumeCheckpoint) {
            _ = try await coordinator.upload(DeliveryUploadRequest(
                plan: fixture.plan,
                stagedBatch: fixture.verifiedBatch(),
                resumeCheckpoint: nonPrefix
            ))
        }

        let item0Evidence = try await DeliveryUploadFileInspector.live.inspect(
            fixture.stagedURLs[0]
        )
        let incoherent = DeliveryUploadCheckpoint(
            planFingerprint: fixture.plan.fingerprint,
            stagingBatchIdentifier: fixture.stagingResult.batchID,
            items: [DeliveryUploadCheckpointItem(
                itemIndex: 0,
                stageInputFingerprint: fixture.plan.items[0].stageInputFingerprint,
                localEvidence: item0Evidence,
                uploadAcknowledgedAt: Date(timeIntervalSince1970: 20),
                remoteConfirmation: .sizeMatches(
                    checkedAt: Date(timeIntervalSince1970: 19),
                    observedByteCount: item0Evidence.byteCount
                )
            )]
        )
        await #expect(throws: DeliveryUploadPreflightError.invalidResumeCheckpoint) {
            _ = try await coordinator.upload(DeliveryUploadRequest(
                plan: fixture.plan,
                stagedBatch: fixture.verifiedBatch(),
                resumeCheckpoint: incoherent
            ))
        }
    }

    @Test("cancellation waits for the active file and cancels only queued items")
    func fileBoundaryCancellation() async throws {
        let fixture = try await UploadFixture(itemCount: 2)
        defer { fixture.remove() }
        let gate = UploadBoundaryGate()
        let coordinator = VerifiedDeliveryUploadCoordinator(transport: gate.transport())
        let task = Task {
            try await coordinator.upload(DeliveryUploadRequest(
                plan: fixture.plan,
                stagedBatch: fixture.verifiedBatch()
            ))
        }

        await gate.waitUntilFirstUploadStarts()
        task.cancel()
        await coordinator.requestCancellation()
        #expect(!(await gate.hasFirstUploadFinished()))
        await gate.releaseFirstUpload()
        let result = try await task.value

        #expect(result.status == .cancelled)
        #expect(result.items.map(\.stage) == [.sent, .cancelled])
        #expect(await gate.uploadedItemIndices() == [0])
        #expect(result.checkpoint.items.map(\.itemIndex) == [0])
    }

    @Test("an overlapping batch is rejected while the active file remains exclusively owned")
    func concurrentBatchRefusal() async throws {
        let fixture = try await UploadFixture(itemCount: 1)
        defer { fixture.remove() }
        let gate = UploadBoundaryGate()
        let coordinator = VerifiedDeliveryUploadCoordinator(transport: gate.transport())
        let request = DeliveryUploadRequest(
            plan: fixture.plan,
            stagedBatch: try fixture.verifiedBatch()
        )

        let first = Task { try await coordinator.upload(request) }
        await gate.waitUntilFirstUploadStarts()
        await #expect(throws: DeliveryUploadPreflightError.alreadyExecuting) {
            _ = try await coordinator.upload(request)
        }
        #expect(!(await gate.hasFirstUploadFinished()))

        await gate.releaseFirstUpload()
        let result = try await first.value
        #expect(result.status == .completed)
        #expect(await gate.uploadedItemIndices() == [0])
    }

    @Test("1,000-item upload is sequential, compact, and cancellable during preflight inspection")
    func largeBatchHasBoundedTransferWorkingSet() async throws {
        let itemCount = 1_000
        let fixture = try await UploadFixture(itemCount: itemCount)
        defer { fixture.remove() }
        let stagedBatch = try fixture.verifiedBatch()
        let expectedEvidence = Dictionary(uniqueKeysWithValues: stagedBatch.artifacts.map {
            ($0.localURL, DeliveryUploadFileEvidence(
                sha256: $0.expectedSHA256,
                byteCount: $0.expectedByteCount
            ))
        })

        let cancellationProbe = LargeBatchUploadProbe(
            expectedEvidence: expectedEvidence,
            pauseFirstInspection: true
        )
        let cancellationCoordinator = VerifiedDeliveryUploadCoordinator(
            transport: cancellationProbe.transport(),
            fileInspector: cancellationProbe.fileInspector()
        )
        let cancelled = Task {
            try await cancellationCoordinator.upload(DeliveryUploadRequest(
                plan: fixture.plan,
                stagedBatch: stagedBatch
            ))
        }
        await cancellationProbe.waitUntilFirstInspectionStarts()
        await cancellationCoordinator.requestCancellation()
        await cancellationProbe.releaseFirstInspection()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let cancellationSnapshot = await cancellationProbe.snapshot()
        #expect(cancellationSnapshot.inspectionCount == 1)
        #expect(cancellationSnapshot.uploadCount == 0)

        let probe = LargeBatchUploadProbe(expectedEvidence: expectedEvidence)
        let coordinator = VerifiedDeliveryUploadCoordinator(
            transport: probe.transport(),
            fileInspector: probe.fileInspector(),
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        let startedAt = ContinuousClock.now
        let result = try await coordinator.upload(DeliveryUploadRequest(
            plan: fixture.plan,
            stagedBatch: stagedBatch
        ))
        let elapsed = startedAt.duration(to: .now)

        #expect(result.status == .completed)
        #expect(result.items.count == itemCount)
        #expect(result.checkpoint.items.count == itemCount)
        let snapshot = await probe.snapshot()
        #expect(snapshot.inspectionCount == itemCount * 2)
        #expect(snapshot.uploadCount == itemCount)
        #expect(snapshot.maximumConcurrentInspections == 1)
        #expect(snapshot.maximumConcurrentUploads == 1)

        // Each checkpoint entry is fixed-size identity/acknowledgement evidence; it never embeds
        // file bytes, local paths, output names, or editorial metadata from the delivery plan.
        let encoded = try JSONEncoder().encode(result.checkpoint)
        let json = String(decoding: encoded, as: UTF8.self).lowercased()
        #expect(!json.contains("private caption"))
        #expect(!json.contains("outputfilename"))
        #expect(!json.contains("localurl"))
        #expect(!json.contains(fixture.rootURL.path.lowercased()))
        #expect(encoded.count < itemCount * 700)
        #expect(elapsed > .zero)
    }
}

private actor LargeBatchUploadProbe {
    struct Snapshot: Sendable {
        let inspectionCount: Int
        let uploadCount: Int
        let maximumConcurrentInspections: Int
        let maximumConcurrentUploads: Int
    }

    private let expectedEvidence: [URL: DeliveryUploadFileEvidence]
    private let pauseFirstInspection: Bool
    private var inspections = 0
    private var uploads = 0
    private var activeInspections = 0
    private var activeUploads = 0
    private var maximumConcurrentInspections = 0
    private var maximumConcurrentUploads = 0
    private var firstInspectionStarted = false
    private var firstInspectionReleased = false
    private var inspectionStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var inspectionReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        expectedEvidence: [URL: DeliveryUploadFileEvidence],
        pauseFirstInspection: Bool = false
    ) {
        self.expectedEvidence = expectedEvidence
        self.pauseFirstInspection = pauseFirstInspection
    }

    nonisolated func fileInspector() -> DeliveryUploadFileInspector {
        DeliveryUploadFileInspector { [self] url in try await inspect(url) }
    }

    nonisolated func transport() -> DeliveryUploadTransport {
        DeliveryUploadTransport(upload: { [self] transfer in
            await upload(transfer)
        })
    }

    func waitUntilFirstInspectionStarts() async {
        if firstInspectionStarted { return }
        await withCheckedContinuation { inspectionStartWaiters.append($0) }
    }

    func releaseFirstInspection() {
        firstInspectionReleased = true
        let waiters = inspectionReleaseWaiters
        inspectionReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            inspectionCount: inspections,
            uploadCount: uploads,
            maximumConcurrentInspections: maximumConcurrentInspections,
            maximumConcurrentUploads: maximumConcurrentUploads
        )
    }

    private func inspect(_ url: URL) async throws -> DeliveryUploadFileEvidence {
        inspections += 1
        activeInspections += 1
        maximumConcurrentInspections = max(maximumConcurrentInspections, activeInspections)
        defer { activeInspections -= 1 }

        if pauseFirstInspection && inspections == 1 {
            firstInspectionStarted = true
            let waiters = inspectionStartWaiters
            inspectionStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !firstInspectionReleased {
                await withCheckedContinuation { inspectionReleaseWaiters.append($0) }
            }
        }
        await Task.yield()
        guard let evidence = expectedEvidence[url] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return evidence
    }

    private func upload(_ transfer: DeliveryUploadTransfer) async {
        activeUploads += 1
        maximumConcurrentUploads = max(maximumConcurrentUploads, activeUploads)
        uploads += 1
        await Task.yield()
        activeUploads -= 1
        #expect(expectedEvidence[transfer.localURL]?.byteCount == transfer.expectedByteCount)
        #expect(expectedEvidence[transfer.localURL]?.sha256 == transfer.expectedSHA256)
    }
}

private actor UploadRecorder {
    private var callCount = 0
    private var uploaded: [Int] = []
    private let failingCalls: Set<Int>
    private let remoteObservation: DeliveryRemoteStatObservation

    init(
        failingCalls: Set<Int> = [],
        remoteObservation: DeliveryRemoteStatObservation = .unavailable
    ) {
        self.failingCalls = failingCalls
        self.remoteObservation = remoteObservation
    }

    nonisolated func transport() -> DeliveryUploadTransport {
        DeliveryUploadTransport(
            upload: { [self] transfer in try await upload(transfer) },
            remoteStat: { [self] _ in await remoteStat() }
        )
    }

    func uploadedItemIndices() -> [Int] { uploaded }

    private func upload(_ transfer: DeliveryUploadTransfer) throws {
        callCount += 1
        let call = callCount
        guard !failingCalls.contains(call) else { throw FakeTransportError.rejected }
        uploaded.append(Self.itemIndex(from: transfer.outputFilename))
    }

    private func remoteStat() -> DeliveryRemoteStatObservation { remoteObservation }

    fileprivate nonisolated static func itemIndex(from filename: String) -> Int {
        Int(filename.dropFirst("source-".count).split(separator: ".").first ?? "-1") ?? -1
    }
}

private actor UploadProgressRecorder {
    private var stages: [DeliveryUploadItemStage] = []
    func record(_ stage: DeliveryUploadItemStage) { stages.append(stage) }
    func values() -> [DeliveryUploadItemStage] { stages }
}

private actor UploadBoundaryGate {
    private var uploaded: [Int] = []
    private var firstStarted = false
    private var firstFinished = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func transport() -> DeliveryUploadTransport {
        DeliveryUploadTransport(upload: { [self] transfer in
            await upload(transfer)
        })
    }

    func waitUntilFirstUploadStarts() async {
        if firstStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstUpload() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func hasFirstUploadFinished() -> Bool { firstFinished }
    func uploadedItemIndices() -> [Int] { uploaded }

    private func upload(_ transfer: DeliveryUploadTransfer) async {
        let index = UploadRecorder.itemIndex(from: transfer.outputFilename)
        uploaded.append(index)
        if index == 0 {
            firstStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            firstFinished = true
        }
    }
}

private actor NetworkDropBoundaryGate {
    private let dropItemIndex: Int
    private var started: [Int] = []
    private var droppedTransferStarted = false
    private var droppedTransferFinished = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(dropItemIndex: Int) { self.dropItemIndex = dropItemIndex }

    nonisolated func transport() -> DeliveryUploadTransport {
        DeliveryUploadTransport(upload: { [self] transfer in
            try await upload(transfer)
        })
    }

    func waitUntilDroppedTransferStarts() async {
        if droppedTransferStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseDroppedTransfer() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func hasDroppedTransferFinished() -> Bool { droppedTransferFinished }
    func startedItemIndices() -> [Int] { started }

    private func upload(_ transfer: DeliveryUploadTransfer) async throws {
        let index = UploadRecorder.itemIndex(from: transfer.outputFilename)
        started.append(index)
        guard index == dropItemIndex else { return }
        droppedTransferStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        droppedTransferFinished = true
        throw SensitiveNetworkDropError()
    }
}

private struct SensitiveNetworkDropError: LocalizedError {
    let errorDescription: String? =
        "Connection dropped for user:password@example.invalid/private/editorial-caption"
}

private enum FakeTransportError: Error { case rejected }

private struct UploadFixture {
    let rootURL: URL
    let plan: DeliveryPlan
    let stagingResult: DeliveryStagingBatchResult
    let stagedURLs: [URL]

    init(itemCount: Int, stagedContents: [Data]? = nil) async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-upload-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        rootURL = fixtureRoot
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)

        let contents = stagedContents ?? (0..<itemCount).map {
            Data("verified-stage-\($0)".utf8)
        }
        precondition(contents.count == itemCount)
        let sourceURLs = (0..<itemCount).map {
            fixtureRoot.appendingPathComponent("source-\($0).raw")
        }
        for (url, data) in zip(sourceURLs, contents) {
            try data.write(to: url)
        }

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
        let connectionID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
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
        let metadata = (0..<itemCount).map {
            IPTCMetadata(title: "Private caption \($0)")
        }
        var sourceRevisions: [SourceImageRevision] = []
        sourceRevisions.reserveCapacity(itemCount)
        for (url, data) in zip(sourceURLs, contents) {
            sourceRevisions.append(SourceImageRevision(
                canonicalURL: url.standardizedFileURL.resolvingSymlinksInPath(),
                fileResourceIdentifier: nil,
                filenameAtCreation: url.lastPathComponent,
                byteCount: Int64(data.count),
                contentModificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                pixelWidth: 6000,
                pixelHeight: 4000,
                exifOrientation: 1,
                sha256: try await HashStream.hashFile(at: url).lowercaseHexString,
                hashCompletedAt: Date(timeIntervalSince1970: 1_700_000_001)
            ))
        }
        let preflightRequest = DeadlinePreflightRequest(
            profile: profile,
            items: sourceURLs.enumerated().map { index, url in
                DeadlinePreflightItemSnapshot(
                    sourceURL: url,
                    metadata: metadata[index],
                    source: DeadlineSourceSnapshot(
                        byteCount: Int64(contents[index].count),
                        pixelWidth: 6000,
                        pixelHeight: 4000
                    )
                )
            },
            delivery: DeadlineBatchDeliverySnapshot(
                destinationAvailableBytes: 10_000_000,
                estimatedRequiredBytes: 1_000,
                stagingState: .ready,
                connections: [connectionID.uuidString.lowercased(): .reachable],
                remotePathState: .valid(resolvedPath: "/incoming/wire")
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
        plan = try DeliveryPlanningService().makePlan(DeliveryPlanningRequest(
            preflightRequest: preflightRequest,
            publication: publication,
            currentRevision: token,
            currentProfile: profile,
            items: zip(sourceRevisions, metadata).map {
                DeliveryPlanningItemInput(sourceRevision: $0.0, resolvedMetadata: $0.1)
            }
        ))

        let batchID = UUID()
        let stagingDirectory = fixtureRoot.appendingPathComponent(
            "deadline-\(batchID.uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        var itemResults: [DeliveryStagingItemResult] = []
        var createdURLs: [URL] = []
        for item in plan.items {
            let data = contents[item.itemIndex]
            let url = stagingDirectory.appendingPathComponent(item.stagedRelativePath)
            try data.write(to: url)
            createdURLs.append(url)
            itemResults.append(DeliveryStagingItemResult(
                itemIndex: item.itemIndex,
                stageInputFingerprint: item.stageInputFingerprint,
                stagedRelativePath: item.stagedRelativePath,
                stage: .verified,
                stagedByteCount: data.count,
                stagedSHA256: try await HashStream.hashFile(at: url).lowercaseHexString,
                renderSettings: DeliveryRenderSettings(
                    formatIdentifier: item.isHDR
                        ? plan.renderAndWrite.export.hdrFormat.rawValue
                        : plan.renderAndWrite.export.sdrFormat.rawValue,
                    colorSpaceIdentifier: item.isHDR
                        ? plan.renderAndWrite.export.hdrGamut.rawValue
                        : plan.renderAndWrite.export.sdrGamut.rawValue,
                    pixelWidth: 4_000,
                    pixelHeight: 2_667,
                    bitDepth: item.isHDR ? nil : 8,
                    quality: item.isHDR ? 85 : 90
                ),
                metadataPreservation: MetadataPreservationVerificationReport(
                    sourceFormatIdentifier: "raw",
                    stagedFormatIdentifier: item.isHDR ? "jpeg-hdr" : "jpeg",
                    domains: MetadataPreservationDomain.allCases.map {
                        MetadataPreservationDomainResult(
                            domain: $0,
                            status: .unsupported,
                            sourceIdentity: nil,
                            stagedIdentity: nil
                        )
                    },
                    c2paConsequence: .unknown
                ),
                checkedFields: IPTCMetadataVerifier.applicableFields(
                    plan.renderAndWrite.verificationFields,
                    expected: item.resolvedMetadata
                ),
                mismatchedFields: [],
                failure: nil
            ))
        }
        stagedURLs = createdURLs
        let cleanupToken = DeliveryStagingCleanupToken(
            batchID: batchID,
            planFingerprint: plan.fingerprint,
            stagingRootURL: fixtureRoot,
            stagingDirectoryURL: stagingDirectory
        )
        stagingResult = DeliveryStagingBatchResult(
            batchID: batchID,
            planFingerprint: plan.fingerprint,
            stagingDirectoryURL: stagingDirectory,
            requiredBytes: Int64(contents.reduce(0) { $0 + $1.count }),
            status: .completed,
            items: itemResults,
            cleanupToken: cleanupToken
        )
    }

    func verifiedBatch() throws -> DeliveryVerifiedStagedBatch {
        try DeliveryVerifiedStagedBatch.validated(plan: plan, stagingResult: stagingResult)
    }

    func stagingResult(
        replacing items: [DeliveryStagingItemResult],
        status: DeliveryStagingBatchStatus = .completed
    ) -> DeliveryStagingBatchResult {
        DeliveryStagingBatchResult(
            batchID: stagingResult.batchID,
            planFingerprint: stagingResult.planFingerprint,
            stagingDirectoryURL: stagingResult.stagingDirectoryURL,
            requiredBytes: stagingResult.requiredBytes,
            status: status,
            items: items,
            cleanupToken: stagingResult.cleanupToken
        )
    }

    func remove() { try? FileManager.default.removeItem(at: rootURL) }
}
