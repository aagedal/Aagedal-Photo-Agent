import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Voice memo companion persistence")
struct VoiceMemoCompanionRepositoryTests {
    @Test("Rename relationship planning is serialized off the main actor")
    @MainActor
    func renameRelationshipPlanningIsSerializedOffMainActor() async {
        let probe = VoiceMemoPlanningProbe()
        let service = VoiceMemoRenamePlanningService(artifactPlanner: probe.plan)
        let first = makePlanningRequest(filename: "one.raw")
        let second = makePlanningRequest(filename: "two.raw")

        async let firstSnapshot = service.plan(first)
        async let secondSnapshot = service.plan(second)
        let snapshots = await [firstSnapshot, secondSnapshot]

        #expect(snapshots.allSatisfy { $0.completion == .complete })
        #expect(probe.callCount == 2)
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("Pre-cancelled relationship planning returns an empty explicit prefix")
    func preCancelledRelationshipPlanningSkipsReads() async {
        let probe = VoiceMemoPlanningProbe()
        let service = VoiceMemoRenamePlanningService(artifactPlanner: probe.plan)
        let request = makePlanningRequest(filename: "cancelled.raw")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.plan(request)
        }

        let snapshot = await task.value

        #expect(snapshot.requestID == request.requestID)
        #expect(snapshot.folderURL == request.folderURL)
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.completion == .cancelled(completedItemCount: 0))
        #expect(probe.callCount == 0)
    }

    @Test("Cancellation after a relationship read reports the exact uncommitted prefix")
    func postReadCancellationIsExplicit() async {
        let gate = BlockingVoiceMemoPlanningProbe()
        defer { gate.release() }
        let service = VoiceMemoRenamePlanningService(artifactPlanner: gate.plan)
        let request = makePlanningRequest(filename: "cancel-during-read.raw")
        let task = Task { await service.plan(request) }

        let didStart = await gate.waitUntilBlocked()
        #expect(didStart, "Relationship planning did not start within 30 seconds")
        guard didStart else { return }
        task.cancel()
        gate.release()

        let snapshot = await task.value
        #expect(snapshot.requestID == request.requestID)
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.completion == .cancelled(completedItemCount: 0))
    }

    @Test("Browser rejects relationship planning after selection changes")
    @MainActor
    func browserRejectsStaleRelationshipPlanning() async throws {
        let gate = BlockingVoiceMemoPlanningProbe()
        defer { gate.release() }
        let service = VoiceMemoRenamePlanningService(artifactPlanner: gate.plan)
        let root = URL(fileURLWithPath: "/virtual", isDirectory: true)
        let first = root.appendingPathComponent("one.raw")
        let second = root.appendingPathComponent("two.raw")
        let viewModel = BrowserViewModel(voiceMemoRenamePlanningService: service)
        viewModel.currentFolderURL = root
        viewModel.images = [ImageFile(url: first), ImageFile(url: second)]
        viewModel.selectedImageIDs = [first]
        await Task.yield()

        viewModel.renameSelected()
        let didStart = await gate.waitUntilBlocked()
        #expect(didStart, "Relationship planning did not start within 30 seconds")
        guard didStart else { return }
        viewModel.selectedImageIDs = [second]
        gate.release()
        try await Task.sleep(for: .milliseconds(30))

        #expect(viewModel.batchRenameSheetRequest == nil)
    }

    @Test("Browser refresh keeps WAV companions out of the photo list")
    func browserRefreshExcludesVoiceMemoAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let scanned = try await FileSystemService().scanFolder(
            at: fixture.root,
            includeAllFiles: true
        )
        #expect(scanned.map(\.filename) == [fixture.image.lastPathComponent])
    }

    @Test("A proven relationship survives repository recreation and supplies rename artifacts")
    func durableLookupAndPlanningArtifacts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = VoiceMemoCompanionRepository()
        try repository.save(fixture.association)

        let reopened = try VoiceMemoCompanionRepository().lookup(for: fixture.image)
        #expect(reopened == .available(fixture.association))

        let artifacts = try VoiceMemoCompanionRepository().planningArtifacts(for: fixture.image)
        #expect(artifacts.map(\.identifier) == ["voice-memo", "voice-memo-relationship"])
        #expect(artifacts[0].sourceURL == fixture.memo)
        #expect(artifacts[1].sourceURL == repository.recordURL(for: fixture.image))
    }

    @Test("Browser rename reloads persisted companions instead of guessing by stem")
    func browserRenameUsesPersistedRelationship() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try VoiceMemoCompanionRepository().save(fixture.association)
        let viewModel = BrowserViewModel()
        viewModel.currentFolderURL = fixture.root
        viewModel.images = [ImageFile(url: fixture.image)]
        viewModel.selectedImageIDs = [fixture.image]
        await Task.yield()

        viewModel.renameSelected()

        try await waitUntil { viewModel.batchRenameSheetRequest != nil }

        let item = try #require(viewModel.batchRenameSheetRequest?.items.first)
        #expect(item.associatedArtifacts.map(\.identifier) == [
            "voice-memo", "voice-memo-relationship",
        ])
    }

    @Test("Partial and full selections of a shared RAW/JPEG memo fail closed")
    func sharedMemoSelectionsFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let jpeg = fixture.root.appendingPathComponent("DSC00001.JPG")
        try Data("jpeg".utf8).write(to: jpeg)
        let repository = VoiceMemoCompanionRepository()
        try repository.save(fixture.association)
        try repository.save(VoiceMemoAssociation(
            profileIdentifier: fixture.association.profileIdentifier,
            imageURL: jpeg,
            memoURL: fixture.memo
        ))
        let viewModel = BrowserViewModel()
        viewModel.currentFolderURL = fixture.root
        viewModel.images = [ImageFile(url: fixture.image), ImageFile(url: jpeg)]
        await Task.yield()

        viewModel.selectedImageIDs = [fixture.image]
        viewModel.renameSelected()
        try await waitUntil { viewModel.errorMessage != nil }
        #expect(viewModel.batchRenameSheetRequest == nil)
        #expect(viewModel.errorMessage?.contains("linked to multiple photos") == true)

        viewModel.errorMessage = nil
        viewModel.selectedImageIDs = [fixture.image, jpeg]
        viewModel.renameSelected()
        try await waitUntil { viewModel.errorMessage != nil }
        #expect(viewModel.batchRenameSheetRequest == nil)
        #expect(viewModel.errorMessage?.contains("linked to multiple photos") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.memo.path))
        #expect(try repository.lookup(for: fixture.image) == .available(fixture.association))
    }

    @Test("A missing memo fails closed and the relationship record remains intact")
    func missingMemoFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = VoiceMemoCompanionRepository()
        try repository.save(fixture.association)
        try FileManager.default.removeItem(at: fixture.memo)

        let lookup = try repository.lookup(for: fixture.image)
        guard case .missing(let record) = lookup else {
            Issue.record("Expected a persisted missing-memo state")
            return
        }
        #expect(record.memoFilename == fixture.memo.lastPathComponent)
        #expect(throws: VoiceMemoCompanionRepository.RepositoryError.memoMissing(
            fixture.memo.lastPathComponent
        )) {
            try repository.planningArtifacts(for: fixture.image)
        }
        #expect(FileManager.default.fileExists(atPath: repository.recordURL(for: fixture.image).path))
    }

    @Test("Import persistence requires one successful matching image and memo destination")
    func importedDestinationsMustBeUnambiguous() throws {
        let sourceRoot = URL(fileURLWithPath: "/card", isDirectory: true)
        let sourceImage = sourceRoot.appendingPathComponent("DSC00001.ARW")
        let sourceMemo = sourceRoot.appendingPathComponent("DSC00001.WAV")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMemoImportPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let image = destination.appendingPathComponent("desk-001.ARW")
        let memo = destination.appendingPathComponent("desk-001.WAV")
        try Data("raw".utf8).write(to: image)
        try Data("wav".utf8).write(to: memo)
        let imageResult = successfulCopy(source: sourceImage, destination: image)
        let memoResult = successfulCopy(source: sourceMemo, destination: memo)
        let association = VoiceMemoAssociation(
            profileIdentifier: "sony-ilce-1-v4",
            imageURL: sourceImage,
            memoURL: sourceMemo
        )

        let saved = try VoiceMemoCompanionRepository().saveImportedAssociations(
            [association],
            results: [imageResult, memoResult]
        )
        #expect(saved == 1)
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .available(
            VoiceMemoAssociation(
                profileIdentifier: association.profileIdentifier,
                imageURL: image,
                memoURL: memo
            )
        ))

        #expect(throws: VoiceMemoCompanionRepository.RepositoryError.ambiguousImportedDestination(
            image.lastPathComponent
        )) {
            try VoiceMemoCompanionRepository().saveImportedAssociations(
                [association],
                results: [imageResult]
            )
        }
    }

    @Test("Verified backup legs receive the same durable relationships")
    func backupLegsReceiveRelationships() throws {
        let sourceRoot = URL(fileURLWithPath: "/card", isDirectory: true)
        let sourceImage = sourceRoot.appendingPathComponent("DSC00001.ARW")
        let sourceMemo = sourceRoot.appendingPathComponent("DSC00001.WAV")
        let primary = try Fixture()
        defer { primary.remove() }
        let backup = try Fixture()
        defer { backup.remove() }
        let imageResult = successfulCopy(
            source: sourceImage,
            destination: primary.image,
            backup: backup.image
        )
        let memoResult = successfulCopy(
            source: sourceMemo,
            destination: primary.memo,
            backup: backup.memo
        )

        let saved = try VoiceMemoCompanionRepository().saveImportedAssociations(
            [VoiceMemoAssociation(
                profileIdentifier: "sony-ilce-1-v4",
                imageURL: sourceImage,
                memoURL: sourceMemo
            )],
            results: [imageResult, memoResult]
        )

        #expect(saved == 2)
        #expect(try VoiceMemoCompanionRepository().lookup(for: backup.image) == .available(
            VoiceMemoAssociation(
                profileIdentifier: "sony-ilce-1-v4",
                imageURL: backup.image,
                memoURL: backup.memo
            )
        ))
    }

    @Test("Import validation cannot leave an earlier relationship partially committed")
    func importValidationIsAllOrNothing() throws {
        let sourceRoot = URL(fileURLWithPath: "/card", isDirectory: true)
        let firstSourceImage = sourceRoot.appendingPathComponent("DSC00001.ARW")
        let firstSourceMemo = sourceRoot.appendingPathComponent("DSC00001.WAV")
        let secondSourceImage = sourceRoot.appendingPathComponent("DSC00002.ARW")
        let secondSourceMemo = sourceRoot.appendingPathComponent("DSC00002.WAV")
        let fixture = try Fixture()
        defer { fixture.remove() }
        let secondImage = fixture.root.appendingPathComponent("DSC00002.ARW")
        try Data("raw-2".utf8).write(to: secondImage)

        #expect(throws: VoiceMemoCompanionRepository.RepositoryError.ambiguousImportedDestination(
            secondImage.lastPathComponent
        )) {
            try VoiceMemoCompanionRepository().saveImportedAssociations(
                [
                    VoiceMemoAssociation(
                        profileIdentifier: "sony-ilce-1-v4",
                        imageURL: firstSourceImage,
                        memoURL: firstSourceMemo
                    ),
                    VoiceMemoAssociation(
                        profileIdentifier: "sony-ilce-1-v4",
                        imageURL: secondSourceImage,
                        memoURL: secondSourceMemo
                    ),
                ],
                results: [
                    successfulCopy(source: firstSourceImage, destination: fixture.image),
                    successfulCopy(source: firstSourceMemo, destination: fixture.memo),
                    successfulCopy(source: secondSourceImage, destination: secondImage),
                ]
            )
        }
        #expect(try VoiceMemoCompanionRepository().lookup(for: fixture.image) == .none)
    }

    @Test("A second record write failure restores an overwritten first record byte-for-byte")
    func batchWriteFailureRestoresExistingRecord() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let batch = try twoRelationshipImportBatch(in: fixture)
        let systemRepository = VoiceMemoCompanionRepository()
        let firstRecordURL = systemRepository.recordURL(for: fixture.image)
        let secondRecordURL = systemRepository.recordURL(for: batch.secondImage)
        let original = Data("pre-existing relationship bytes\n".utf8)
        try original.write(to: firstRecordURL)
        let repository = VoiceMemoCompanionRepository(
            recordIO: FailNthWriteRecordIO(failingOnWrite: 2)
        )

        #expect(throws: InjectedWriteFailure.self) {
            try repository.saveImportedAssociations(batch.associations, results: batch.results)
        }

        #expect(try Data(contentsOf: firstRecordURL) == original)
        #expect(!FileManager.default.fileExists(atPath: secondRecordURL.path))
    }

    @Test("A second record write failure removes a newly created first record")
    func batchWriteFailureRemovesNewRecord() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let batch = try twoRelationshipImportBatch(in: fixture)
        let systemRepository = VoiceMemoCompanionRepository()
        let firstRecordURL = systemRepository.recordURL(for: fixture.image)
        let secondRecordURL = systemRepository.recordURL(for: batch.secondImage)
        let repository = VoiceMemoCompanionRepository(
            recordIO: FailNthWriteRecordIO(failingOnWrite: 2)
        )

        #expect(throws: InjectedWriteFailure.self) {
            try repository.saveImportedAssociations(batch.associations, results: batch.results)
        }

        #expect(!FileManager.default.fileExists(atPath: firstRecordURL.path))
        #expect(!FileManager.default.fileExists(atPath: secondRecordURL.path))
    }

    @Test("Transactional rename moves memo and record without requiring a repair write")
    func renameAndReassociate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = VoiceMemoCompanionRepository()
        try repository.save(fixture.association)
        let originalRecord = try Data(contentsOf: repository.recordURL(for: fixture.image))
        let artifacts = try repository.planningArtifacts(for: fixture.image)
        let plan = RenamePlanningService().makePlan(
            items: [RenamePlanningItem(
                sourceImageURL: fixture.image,
                associatedArtifacts: artifacts
            )],
            recipe: BatchRenameRecipe(name: "Desk", components: [.literal("desk-001.ARW")]),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [fixture.image, fixture.memo, repository.recordURL(for: fixture.image)]
            )
        )
        #expect(plan.canExecute)

        let execution = await RenameExecutionService().execute(plan)
        #expect(execution.succeeded)
        let presentation = BatchRenameExecutionPresentation(result: execution)
        let renamedImage = fixture.root.appendingPathComponent("desk-001.ARW")
        let renamedMemo = fixture.root.appendingPathComponent("desk-001.WAV")
        let renamedRecord = repository.recordURL(for: renamedImage)
        #expect(try Data(contentsOf: renamedRecord) == originalRecord)
        #expect(try repository.lookup(for: renamedImage) == .available(VoiceMemoAssociation(
            profileIdentifier: fixture.association.profileIdentifier,
            imageURL: renamedImage,
            memoURL: renamedMemo
        )))
        let reassociation = await RenameReassociationService().reassociate(
            folderURL: fixture.root,
            mappings: presentation.mappings
        )
        #expect(reassociation.succeeded)
        #expect(reassociation.voiceMemoCompanionCount == 1)

        #expect(try repository.lookup(for: renamedImage) == .available(VoiceMemoAssociation(
            profileIdentifier: fixture.association.profileIdentifier,
            imageURL: renamedImage,
            memoURL: renamedMemo
        )))
        #expect(!FileManager.default.fileExists(atPath: fixture.image.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.memo.path))
    }

    @Test("Corrupt and newer relationship records are left untouched")
    func invalidRecordsAreNotRewritten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = VoiceMemoCompanionRepository()
        let recordURL = repository.recordURL(for: fixture.image)
        let original = Data(#"{"schemaVersion":99,"profileIdentifier":"future","imageFilename":"DSC00001.ARW","memoFilename":"DSC00001.WAV"}"#.utf8)
        try original.write(to: recordURL)

        #expect(throws: VoiceMemoCompanionRepository.RepositoryError.unsupportedSchema(99)) {
            try repository.lookup(for: fixture.image)
        }
        #expect(try Data(contentsOf: recordURL) == original)
    }

    private func successfulCopy(
        source: URL,
        destination: URL,
        backup: URL? = nil
    ) -> ImportCopyService.CopyResult {
        ImportCopyService.CopyResult(
            id: UUID(),
            source: source,
            primary: .copied(destination, wasRenamed: false, wasReplaced: false, hash: Data()),
            primaryVerification: .verified,
            backup: backup.map {
                .copied($0, wasRenamed: false, wasReplaced: false, hash: Data())
            },
            backupVerification: backup == nil ? nil : .verified
        )
    }

    private func makePlanningRequest(filename: String) -> VoiceMemoRenamePlanningRequest {
        let root = URL(fileURLWithPath: "/virtual", isDirectory: true)
        return VoiceMemoRenamePlanningRequest(
            requestID: UUID(),
            folderURL: root,
            items: [RenamePlanningItem(
                sourceImageURL: root.appendingPathComponent(filename)
            )]
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw VoiceMemoPlanningTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func twoRelationshipImportBatch(
        in fixture: Fixture
    ) throws -> (
        associations: [VoiceMemoAssociation],
        results: [ImportCopyService.CopyResult],
        secondImage: URL
    ) {
        let sourceRoot = URL(fileURLWithPath: "/card", isDirectory: true)
        let firstSourceImage = sourceRoot.appendingPathComponent("DSC00001.ARW")
        let firstSourceMemo = sourceRoot.appendingPathComponent("DSC00001.WAV")
        let secondSourceImage = sourceRoot.appendingPathComponent("DSC00002.ARW")
        let secondSourceMemo = sourceRoot.appendingPathComponent("DSC00002.WAV")
        let secondImage = fixture.root.appendingPathComponent("DSC00002.ARW")
        let secondMemo = fixture.root.appendingPathComponent("DSC00002.WAV")
        try Data("raw-2".utf8).write(to: secondImage)
        try Data("wav-2".utf8).write(to: secondMemo)
        return (
            associations: [
                VoiceMemoAssociation(
                    profileIdentifier: "sony-ilce-1-v4",
                    imageURL: firstSourceImage,
                    memoURL: firstSourceMemo
                ),
                VoiceMemoAssociation(
                    profileIdentifier: "sony-ilce-1-v4",
                    imageURL: secondSourceImage,
                    memoURL: secondSourceMemo
                ),
            ],
            results: [
                successfulCopy(source: firstSourceImage, destination: fixture.image),
                successfulCopy(source: firstSourceMemo, destination: fixture.memo),
                successfulCopy(source: secondSourceImage, destination: secondImage),
                successfulCopy(source: secondSourceMemo, destination: secondMemo),
            ],
            secondImage: secondImage
        )
    }

    private enum InjectedWriteFailure: Error {
        case failure
    }

    private final class FailNthWriteRecordIO: VoiceMemoCompanionRecordIO, @unchecked Sendable {
        private let failingOnWrite: Int
        private let lock = NSLock()
        private var writeCount = 0
        private let system = SystemVoiceMemoCompanionRecordIO()

        init(failingOnWrite: Int) {
            self.failingOnWrite = failingOnWrite
        }

        func fileExists(at url: URL) -> Bool {
            system.fileExists(at: url)
        }

        func read(from url: URL) throws -> Data {
            try system.read(from: url)
        }

        func writeAtomically(_ data: Data, to url: URL) throws {
            let currentWrite = lock.withLock {
                writeCount += 1
                return writeCount
            }
            if currentWrite == failingOnWrite {
                throw InjectedWriteFailure.failure
            }
            try system.writeAtomically(data, to: url)
        }

        func remove(at url: URL) throws {
            try system.remove(at: url)
        }
    }

    private struct Fixture {
        let root: URL
        let image: URL
        let memo: URL
        let association: VoiceMemoAssociation

        init() throws {
            let temporaryRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoiceMemoCompanionRepositoryTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            root = temporaryRoot.standardizedFileURL
            image = root.appendingPathComponent("DSC00001.ARW")
            memo = root.appendingPathComponent("DSC00001.WAV")
            try Data("raw".utf8).write(to: image)
            try Data("wav".utf8).write(to: memo)
            association = VoiceMemoAssociation(
                profileIdentifier: "sony-ilce-1-v4",
                imageURL: image,
                memoURL: memo
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

nonisolated private enum VoiceMemoPlanningTestError: Error {
    case timedOut
}

nonisolated private final class VoiceMemoPlanningProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCalls = 0
    private var recordedCallCount = 0
    private var recordedMaximumConcurrentCalls = 0
    private var observedMainThread = false

    var callCount: Int { lock.withLock { recordedCallCount } }
    var maximumConcurrentCalls: Int { lock.withLock { recordedMaximumConcurrentCalls } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }

    func plan(_ url: URL) throws -> [RenamePlanningAssociatedArtifact] {
        lock.withLock {
            activeCalls += 1
            recordedCallCount += 1
            recordedMaximumConcurrentCalls = max(recordedMaximumConcurrentCalls, activeCalls)
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        Thread.sleep(forTimeInterval: 0.04)
        lock.withLock { activeCalls -= 1 }
        return []
    }
}

nonisolated private final class BlockingVoiceMemoPlanningProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var isBlocked = false
    private var isReleased = false

    func plan(_ url: URL) throws -> [RenamePlanningAssociatedArtifact] {
        condition.lock()
        isBlocked = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
        return []
    }

    func waitUntilBlocked(timeout: TimeInterval = 30) async -> Bool {
        await Task.detached { [self] in
            waitUntilBlockedSynchronously(timeout: timeout)
        }.value
    }

    private func waitUntilBlockedSynchronously(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !isBlocked {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release() {
        condition.withLock {
            isReleased = true
            condition.broadcast()
        }
    }
}
