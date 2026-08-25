import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Rename execution service")
struct RenameExecutionServiceTests {
    private let root = URL(fileURLWithPath: "/execution-tests", isDirectory: true)

    @Test("A single image without sidecars is staged and committed")
    func singleImageWithoutSidecars() async throws {
        let source = root.appendingPathComponent("one.jpg")
        let plan = plan(
            sources: [source],
            destinationNames: ["renamed.jpg"],
            existingArtifacts: []
        )
        let fileSystem = MemoryRenameFileSystem([source: Data("image".utf8)])

        let result = await service(fileSystem).execute(plan)

        #expect(result.status == .succeeded)
        #expect(result.rollbackStatus == .notNeeded)
        #expect(result.moves.map(\.phase) == [.stage, .commit])
        #expect(fileSystem.dataIfPresent(at: root.appendingPathComponent("renamed.jpg")) == Data("image".utf8))
        #expect(!fileSystem.exists(source))
        #expect(result.bundles.first?.completedArtifactIdentifiers == ["image"])
    }

    @Test("An explicit voice memo is committed in the same transactional bundle")
    func voiceMemoCompanionCommitsWithImage() async throws {
        let image = root.appendingPathComponent("DSC00001.ARW")
        let memo = root.appendingPathComponent("AUDIO_SOURCE_1.WAV")
        let plan = RenamePlanningService().makePlan(
            items: [RenamePlanningItem(
                sourceImageURL: image,
                associatedArtifacts: [RenamePlanningAssociatedArtifact(
                    identifier: "voice-memo",
                    displayName: "Voice memo",
                    sourceURL: memo,
                    filenamePattern: RenameArtifactFilenamePattern(basis: .stem, suffix: ".WAV")
                )]
            )],
            recipe: BatchRenameRecipe(name: "Desk", components: [.literal("desk-001.ARW")]),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [memo]
            )
        )
        let original: [URL: Data] = [
            image: Data("raw-bytes".utf8),
            memo: Data("wav-bytes".utf8),
        ]
        let fileSystem = MemoryRenameFileSystem(original)

        let result = await service(fileSystem).execute(plan)

        #expect(result.succeeded)
        #expect(result.bundles.first?.artifactIdentifiers == ["image", "voice-memo"])
        #expect(fileSystem.dataIfPresent(at: root.appendingPathComponent("desk-001.ARW")) == original[image])
        #expect(fileSystem.dataIfPresent(at: root.appendingPathComponent("desk-001.WAV")) == original[memo])
        #expect(!fileSystem.exists(image))
        #expect(!fileSystem.exists(memo))
    }

    @Test("A voice memo rolls back byte-for-byte when the bundle commit fails")
    func voiceMemoCompanionRollsBackWithImage() async {
        let image = root.appendingPathComponent("DSC00002.ARW")
        let memo = root.appendingPathComponent("DSC00002.WAV")
        let companion = RenamePlanningAssociatedArtifact(
            identifier: "voice-memo",
            displayName: "Voice memo",
            sourceURL: memo,
            filenamePattern: RenameArtifactFilenamePattern(basis: .stem, suffix: ".WAV")
        )
        let plan = RenamePlanningService().makePlan(
            items: [RenamePlanningItem(sourceImageURL: image, associatedArtifacts: [companion])],
            recipe: BatchRenameRecipe(name: "Desk", components: [.literal("desk-002.ARW")]),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [memo]
            )
        )
        let original: [URL: Data] = [
            image: Data("raw-two".utf8),
            memo: Data("wav-two".utf8),
        ]
        let fileSystem = MemoryRenameFileSystem(original)
        let result = await RenameExecutionService(
            fileSystem: fileSystem,
            temporaryNameToken: LockedTokenSequence().next,
            // Both artifacts are staged first; fail after the image commit.
            afterMove: { $0.ordinal == 3 ? "Injected bundle failure" : nil }
        ).execute(plan)

        #expect(result.status == .failed)
        #expect(result.rollbackStatus == .succeeded)
        #expect(result.residuals.isEmpty)
        #expect(fileSystem.snapshot() == original)
    }

    @Test("Multiple bundles execute in visible plan order")
    func multipleBundlesWithoutSidecars() async {
        let sources = ["z.jpg", "a.jpg", "m.jpg"].map(root.appendingPathComponent)
        let destinations = ["001.jpg", "002.jpg", "003.jpg"]
        let plan = plan(sources: sources, destinationNames: destinations, existingArtifacts: [])
        let fileSystem = MemoryRenameFileSystem(Dictionary(uniqueKeysWithValues: sources.enumerated().map {
            ($0.element, Data("image-\($0.offset)".utf8))
        }))

        let result = await service(fileSystem).execute(plan)

        #expect(result.succeeded)
        #expect(result.bundles.map(\.itemIndex) == [0, 1, 2])
        #expect(Array(result.moves.prefix(3)).map(\.artifactIdentifier) == ["image", "image", "image"])
        for index in destinations.indices {
            #expect(fileSystem.dataIfPresent(at: root.appendingPathComponent(destinations[index])) == Data("image-\(index)".utf8))
        }
    }

    @Test("Two-way cycles include XMP, current and legacy JSON, and custom artifacts")
    func completeArtifactCycle() async throws {
        let a = root.appendingPathComponent("A.NEF")
        let b = root.appendingPathComponent("B.NEF")
        let artifactURLs = cycleArtifactURLs(for: [a, b])
        let registry = RenameArtifactRegistry.standard.registering(RenameArtifactRule(
            identifier: "thumbnail-cache",
            displayName: "Thumbnail cache",
            relativeDirectoryComponents: [".cache"],
            filenamePattern: RenameArtifactFilenamePattern(basis: .stem, suffix: ".thumb")
        ))
        let plan = plan(
            sources: [a, b],
            destinationNames: ["B.NEF", "A.NEF"],
            existingArtifacts: Set(artifactURLs.filter { $0 != a && $0 != b }),
            registry: registry
        )
        var contents: [URL: Data] = [:]
        for url in artifactURLs {
            if url.pathExtension == "json" {
                let imageName = url.lastPathComponent.hasPrefix("A") ? "A.NEF" : "B.NEF"
                contents[url] = try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 1,
                    "sourceFile": imageName,
                    "preservedUnknown": "keep-\(imageName)",
                ])
            } else {
                contents[url] = Data("content-\(url.path)".utf8)
            }
        }
        let original = contents
        let fileSystem = MemoryRenameFileSystem(contents)

        let result = await service(fileSystem).execute(plan)

        #expect(result.succeeded)
        #expect(result.moves.filter { $0.phase == .stage }.count == 10)
        #expect(result.moves.filter { $0.phase == .commit }.count == 10)
        for entry in plan.entries {
            for action in entry.plannedArtifactActions {
                if action.artifactIsMetadataJSON {
                    let destinationData = try #require(fileSystem.dataIfPresent(at: action.destinationURL))
                    let decoded = try JSONSerialization.jsonObject(with: destinationData)
                    let object = try #require(decoded as? [String: Any])
                    #expect(object["sourceFile"] as? String == entry.plannedDestinationImageURL?.lastPathComponent)
                    #expect(object["preservedUnknown"] as? String == "keep-\(entry.sourceImageURL.lastPathComponent)")
                } else {
                    #expect(fileSystem.dataIfPresent(at: action.destinationURL) == original[action.sourceURL])
                }
            }
        }
        #expect(fileSystem.allURLs().allSatisfy { !$0.lastPathComponent.hasPrefix(".aagedal-rename-") })
    }

    @Test("A longer cycle commits only after all three sources are staged")
    func threeWayCycle() async {
        let sources = ["A.jpg", "B.jpg", "C.jpg"].map(root.appendingPathComponent)
        let plan = plan(
            sources: sources,
            destinationNames: ["B.jpg", "C.jpg", "A.jpg"],
            existingArtifacts: []
        )
        let original = Dictionary(uniqueKeysWithValues: sources.enumerated().map {
            ($0.element, Data("image-\($0.offset)".utf8))
        })
        let fileSystem = MemoryRenameFileSystem(original)

        let result = await service(fileSystem).execute(plan)

        #expect(result.succeeded)
        #expect(result.moves.map(\.phase) == [.stage, .stage, .stage, .commit, .commit, .commit])
        #expect(fileSystem.dataIfPresent(at: sources[0]) == original[sources[2]])
        #expect(fileSystem.dataIfPresent(at: sources[1]) == original[sources[0]])
        #expect(fileSystem.dataIfPresent(at: sources[2]) == original[sources[1]])
    }

    @Test("Cancellation before mutation leaves every source untouched")
    func cancellationBeforeMutation() async {
        let source = root.appendingPathComponent("one.jpg")
        let plan = plan(sources: [source], destinationNames: ["two.jpg"], existingArtifacts: [])
        let fileSystem = MemoryRenameFileSystem([source: Data("one".utf8)])
        let service = RenameExecutionService(
            fileSystem: fileSystem,
            temporaryNameToken: { "cancel-before" },
            cancellationRequested: { true }
        )

        let result = await service.execute(plan)

        #expect(result.status == .cancelled)
        #expect(result.rollbackStatus == .notNeeded)
        #expect(result.moves.isEmpty)
        #expect(fileSystem.dataIfPresent(at: source) == Data("one".utf8))
    }

    @Test("Cancellation after each move boundary rolls the entire bundle set back")
    func cancellationAtEveryMoveBoundary() async {
        let fixture = failureFixture()
        let forwardMoveCount = fixture.plan.entries.flatMap(\.plannedArtifactActions).filter(\.changesPath).count * 2

        for cancellationMove in 1...forwardMoveCount {
            let fileSystem = MemoryRenameFileSystem(fixture.contents)
            let signal = CancellationSignal(cancelAfterMove: cancellationMove)
            let service = RenameExecutionService(
                fileSystem: fileSystem,
                temporaryNameToken: fixture.tokenSource(),
                cancellationRequested: { signal.isCancelled },
                afterMove: { move in
                    signal.record(move)
                    return nil
                }
            )

            let result = await service.execute(fixture.plan)

            #expect(result.status == .cancelled, "boundary \(cancellationMove)")
            #expect(result.rollbackStatus == .succeeded, "boundary \(cancellationMove)")
            #expect(result.residuals.isEmpty, "boundary \(cancellationMove)")
            #expect(fileSystem.snapshot() == fixture.contents, "boundary \(cancellationMove)")
        }
    }

    @Test("A failure after every forward move rolls original bytes and names back")
    func failureAfterEveryMoveStep() async {
        let fixture = failureFixture()
        let forwardMoveCount = fixture.plan.entries.flatMap(\.plannedArtifactActions).filter(\.changesPath).count * 2

        for failureMove in 1...forwardMoveCount {
            let fileSystem = MemoryRenameFileSystem(fixture.contents)
            let service = RenameExecutionService(
                fileSystem: fileSystem,
                temporaryNameToken: fixture.tokenSource(),
                afterMove: { move in
                    move.ordinal == failureMove ? "Injected after move \(failureMove)" : nil
                }
            )

            let result = await service.execute(fixture.plan)

            #expect(result.status == .failed, "move \(failureMove)")
            #expect(result.rollbackStatus == .succeeded, "move \(failureMove)")
            #expect(result.residuals.isEmpty, "move \(failureMove)")
            #expect(fileSystem.snapshot() == fixture.contents, "move \(failureMove)")
        }
    }

    @Test("An injected filesystem failure is rolled back")
    func injectedMoveFailure() async {
        let fixture = failureFixture()
        let fileSystem = MemoryRenameFileSystem(fixture.contents, failMoveCallOnce: 3)
        let result = await RenameExecutionService(
            fileSystem: fileSystem,
            temporaryNameToken: fixture.tokenSource()
        ).execute(fixture.plan)

        #expect(result.status == .failed)
        #expect(result.rollbackStatus == .succeeded)
        #expect(result.issues.first?.code == .moveFailed)
        #expect(fileSystem.snapshot() == fixture.contents)
    }

    @Test("Rollback restores metadata JSON byte-for-byte after sourceFile was staged")
    func metadataJSONRollbackIsTransactional() async throws {
        let image = root.appendingPathComponent("A.jpg")
        let metadata = root
            .appendingPathComponent(".photo_metadata", isDirectory: true)
            .appendingPathComponent("A.jpg.meta.json")
        let metadataData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "sourceFile": "A.jpg",
            "unknown": ["nested": true],
        ], options: [])
        let original = [image: Data("image".utf8), metadata: metadataData]
        let plan = plan(
            sources: [image],
            destinationNames: ["B.jpg"],
            existingArtifacts: [metadata]
        )
        let fileSystem = MemoryRenameFileSystem(original)
        let service = RenameExecutionService(
            fileSystem: fileSystem,
            temporaryNameToken: LockedTokenSequence().next,
            // Image commit is move 3, after both artifacts were staged and JSON was rewritten.
            afterMove: { $0.ordinal == 3 ? "Stop after metadata update" : nil }
        )

        let result = await service.execute(plan)

        #expect(result.status == .failed)
        #expect(result.rollbackStatus == .succeeded)
        #expect(fileSystem.snapshot() == original)
    }

    @Test("Rollback failures report the exact residual path")
    func rollbackFailureReportsResidual() async throws {
        let source = root.appendingPathComponent("one.jpg")
        let plan = plan(sources: [source], destinationNames: ["two.jpg"], existingArtifacts: [])
        // Move 1 stages, injected hook starts rollback, move 2 is the restore and fails.
        let fileSystem = MemoryRenameFileSystem([source: Data("one".utf8)], failMoveCallOnce: 2)
        let result = await RenameExecutionService(
            fileSystem: fileSystem,
            temporaryNameToken: { "residual" },
            afterMove: { _ in "Stop after stage" }
        ).execute(plan)

        #expect(result.status == .failed)
        #expect(result.rollbackStatus == .failed)
        let residual = try #require(result.residuals.first)
        #expect(residual.location == .temporary)
        #expect(residual.currentURL?.lastPathComponent == ".aagedal-rename-residual-1-one.jpg")
        #expect(residual.expectedSourceURL == source)
        #expect(fileSystem.dataIfPresent(at: residual.currentURL!) == Data("one".utf8))
    }

    @Test("Preflight rejects stale sources and occupied destinations without mutation")
    func livePreflightRejectsStalePlan() async {
        let source = root.appendingPathComponent("one.jpg")
        let destination = root.appendingPathComponent("two.jpg")
        let plan = plan(sources: [source], destinationNames: ["two.jpg"], existingArtifacts: [])

        let missingSourceFS = MemoryRenameFileSystem([:])
        let missingResult = await service(missingSourceFS).execute(plan)
        #expect(missingResult.status == .preflightFailed)
        #expect(missingResult.issues.map(\.code).contains(.sourceMissing))
        #expect(missingSourceFS.moveCallCount == 0)

        let occupiedFS = MemoryRenameFileSystem([
            source: Data("source".utf8),
            destination: Data("outside".utf8),
        ])
        let occupiedResult = await service(occupiedFS).execute(plan)
        #expect(occupiedResult.status == .preflightFailed)
        #expect(occupiedResult.issues.map(\.code).contains(.destinationOccupied))
        #expect(occupiedFS.snapshot()[destination] == Data("outside".utf8))
        #expect(occupiedFS.moveCallCount == 0)
    }

    @Test("Preflight refuses a non-writable directory before any move")
    func livePreflightRejectsNonWritableDirectory() async {
        let source = root.appendingPathComponent("one.jpg")
        let plan = plan(sources: [source], destinationNames: ["two.jpg"], existingArtifacts: [])
        let fileSystem = MemoryRenameFileSystem(
            [source: Data("source".utf8)],
            unwritableDirectories: [root]
        )

        let result = await service(fileSystem).execute(plan)

        #expect(result.status == .preflightFailed)
        #expect(result.issues.map(\.code).contains(.directoryNotWritable))
        #expect(fileSystem.moveCallCount == 0)
        #expect(fileSystem.dataIfPresent(at: source) == Data("source".utf8))
    }

    @Test("Temporary-path allocation is bounded even with a repeating token supplier")
    func temporaryPathAllocationIsBounded() async {
        let source = root.appendingPathComponent("one.jpg")
        let plan = plan(sources: [source], destinationNames: ["two.jpg"], existingArtifacts: [])
        let fileSystem = MemoryRenameFileSystem(
            [source: Data("source".utf8)],
            reportTemporaryPathsOccupied: true
        )
        let result = await RenameExecutionService(
            fileSystem: fileSystem,
            temporaryNameToken: { "repeated" }
        ).execute(plan)

        #expect(result.status == .preflightFailed)
        #expect(result.issues.map(\.code).contains(.temporaryPathUnavailable))
        #expect(fileSystem.moveCallCount == 0)
    }

    @Test("A non-atomic rollback failure can report a missing artifact")
    func destructiveRollbackFailureReportsMissing() async throws {
        let source = root.appendingPathComponent("one.jpg")
        let plan = plan(sources: [source], destinationNames: ["two.jpg"], existingArtifacts: [])
        let fileSystem = MemoryRenameFileSystem(
            [source: Data("source".utf8)],
            failMoveCallOnce: 2,
            loseSourceOnFailedMove: true
        )
        let result = await RenameExecutionService(
            fileSystem: fileSystem,
            temporaryNameToken: { "missing" },
            afterMove: { _ in "Begin rollback" }
        ).execute(plan)

        #expect(result.rollbackStatus == .failed)
        let residual = try #require(result.residuals.first)
        #expect(residual.location == .missing)
        #expect(residual.currentURL == nil)
    }

    private func service(_ fileSystem: MemoryRenameFileSystem) -> RenameExecutionService {
        let sequence = LockedTokenSequence()
        return RenameExecutionService(
            fileSystem: fileSystem,
            temporaryNameToken: { sequence.next() }
        )
    }

    private func plan(
        sources: [URL],
        destinationNames: [String],
        existingArtifacts: Set<URL>,
        registry: RenameArtifactRegistry = .standard
    ) -> RenamePlan {
        let items = zip(sources, destinationNames).map { source, destination in
            RenamePlanningItem(
                sourceImageURL: source,
                context: BatchRenameContext(
                    originalFilename: source.lastPathComponent,
                    metadata: [.event: destination]
                )
            )
        }
        return RenamePlanningService().makePlan(
            items: items,
            recipe: BatchRenameRecipe(name: "Mapped", components: [.token(.metadata(.event))]),
            artifactRegistry: registry,
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: existingArtifacts
            )
        )
    }

    private func cycleArtifactURLs(for images: [URL]) -> [URL] {
        images.flatMap { image in
            let stem = image.deletingPathExtension().lastPathComponent
            let metadata = root.appendingPathComponent(".photo_metadata", isDirectory: true)
            return [
                image,
                root.appendingPathComponent("\(stem).xmp"),
                metadata.appendingPathComponent("\(image.lastPathComponent).meta.json"),
                metadata.appendingPathComponent("\(stem).meta.json"),
                root.appendingPathComponent(".cache", isDirectory: true).appendingPathComponent("\(stem).thumb"),
            ]
        }
    }

    private func failureFixture() -> FailureFixture {
        let a = root.appendingPathComponent("A.NEF")
        let b = root.appendingPathComponent("B.NEF")
        let xmpA = root.appendingPathComponent("A.xmp")
        let xmpB = root.appendingPathComponent("B.xmp")
        let plan = plan(
            sources: [a, b],
            destinationNames: ["B.NEF", "A.NEF"],
            existingArtifacts: [xmpA, xmpB]
        )
        return FailureFixture(plan: plan, contents: [
            a: Data("image-a".utf8),
            b: Data("image-b".utf8),
            xmpA: Data("xmp-a".utf8),
            xmpB: Data("xmp-b".utf8),
        ])
    }
}

private nonisolated struct FailureFixture {
    let plan: RenamePlan
    let contents: [URL: Data]

    func tokenSource() -> @Sendable () -> String {
        let sequence = LockedTokenSequence()
        return { sequence.next() }
    }
}

private extension RenameArtifactAction {
    var artifactIsMetadataJSON: Bool {
        identifier == "photo-metadata-current" || identifier == "photo-metadata-legacy"
    }
}

private nonisolated final class LockedTokenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> String {
        lock.withLock {
            value += 1
            return "token-\(value)"
        }
    }
}

private nonisolated final class CancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfterMove: Int
    private var latestMove = 0

    init(cancelAfterMove: Int) {
        self.cancelAfterMove = cancelAfterMove
    }

    var isCancelled: Bool {
        lock.withLock { latestMove >= cancelAfterMove }
    }

    func record(_ move: RenameExecutionMove) {
        lock.withLock { latestMove = move.ordinal }
    }
}

private nonisolated final class MemoryRenameFileSystem: RenameExecutionFileSystem, @unchecked Sendable {
    private struct Failure: LocalizedError {
        let call: Int
        var errorDescription: String? { "Injected move failure at call \(call)" }
    }

    private let lock = NSLock()
    private var files: [String: Data]
    private let failMoveCallOnce: Int?
    private let unwritableDirectories: Set<String>
    private let reportTemporaryPathsOccupied: Bool
    private let loseSourceOnFailedMove: Bool
    private var didFailMove = false
    private(set) var moveCallCount = 0

    init(
        _ files: [URL: Data],
        failMoveCallOnce: Int? = nil,
        unwritableDirectories: Set<URL> = [],
        reportTemporaryPathsOccupied: Bool = false,
        loseSourceOnFailedMove: Bool = false
    ) {
        self.files = Dictionary(uniqueKeysWithValues: files.map { ($0.key.standardizedFileURL.path, $0.value) })
        self.failMoveCallOnce = failMoveCallOnce
        self.unwritableDirectories = Set(unwritableDirectories.map { $0.standardizedFileURL.path })
        self.reportTemporaryPathsOccupied = reportTemporaryPathsOccupied
        self.loseSourceOnFailedMove = loseSourceOnFailedMove
    }

    func itemExists(at url: URL) -> Bool {
        lock.withLock {
            if reportTemporaryPathsOccupied,
               url.lastPathComponent.hasPrefix(".aagedal-rename-") {
                return true
            }
            return files[url.standardizedFileURL.path] != nil
        }
    }

    func directoryAllowsChanges(at directoryURL: URL) -> Bool {
        !unwritableDirectories.contains(directoryURL.standardizedFileURL.path)
    }

    func itemsReferToSameFile(_ firstURL: URL, _ secondURL: URL) throws -> Bool {
        firstURL.standardizedFileURL.path == secondURL.standardizedFileURL.path
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try lock.withLock {
            moveCallCount += 1
            if failMoveCallOnce == moveCallCount, !didFailMove {
                didFailMove = true
                if loseSourceOnFailedMove {
                    files.removeValue(forKey: sourceURL.standardizedFileURL.path)
                }
                throw Failure(call: moveCallCount)
            }
            let source = sourceURL.standardizedFileURL.path
            let destination = destinationURL.standardizedFileURL.path
            guard let data = files[source] else {
                throw CocoaError(.fileNoSuchFile)
            }
            guard files[destination] == nil else {
                throw CocoaError(.fileWriteFileExists)
            }
            files.removeValue(forKey: source)
            files[destination] = data
        }
    }

    func data(at url: URL) throws -> Data {
        try lock.withLock {
            guard let data = files[url.standardizedFileURL.path] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return data
        }
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        lock.withLock { files[url.standardizedFileURL.path] = data }
    }

    func dataIfPresent(at url: URL) -> Data? {
        lock.withLock { files[url.standardizedFileURL.path] }
    }

    func exists(_ url: URL) -> Bool {
        itemExists(at: url)
    }

    func allURLs() -> [URL] {
        lock.withLock { files.keys.map { URL(fileURLWithPath: $0) } }
    }

    func snapshot() -> [URL: Data] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: files.map { (URL(fileURLWithPath: $0.key), $0.value) })
        }
    }
}
