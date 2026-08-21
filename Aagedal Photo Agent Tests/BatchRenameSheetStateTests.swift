import CoreGraphics
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Batch rename sheet state")
struct BatchRenameSheetStateTests {
    private let root = URL(fileURLWithPath: "/rename-sheet", isDirectory: true)

    @Test("Single-file sheet starts with one directly editable full filename")
    func singleFileDefault() {
        let state = BatchRenameEditorState(sourceFilenames: ["press.NEF"])

        #expect(state.components.count == 1)
        #expect(state.components.first?.kind == .literal)
        #expect(state.components.first?.literal == "press.NEF")
        let result = BatchRenameRecipeRenderer().evaluate(
            state.recipe,
            context: BatchRenameContext(originalFilename: "press.NEF")
        )
        #expect(result.proposedFilename == "press.NEF")
    }

    @Test("Batch sheet default uses visible-order sequence and preserves extensions")
    func batchDefault() {
        let state = BatchRenameEditorState(sourceFilenames: ["z.NEF", "a.jpg"])
        let renderer = BatchRenameRecipeRenderer()

        let first = renderer.evaluate(
            state.recipe,
            context: BatchRenameContext(originalFilename: "z.NEF", sequenceIndex: 0)
        )
        let second = renderer.evaluate(
            state.recipe,
            context: BatchRenameContext(originalFilename: "a.jpg", sequenceIndex: 1)
        )

        #expect(first.proposedFilename == "z-001.NEF")
        #expect(second.proposedFilename == "a-002.jpg")
    }

    @Test("Preview rows expose typed conflict detail instead of counts alone")
    func previewIssueDetail() throws {
        let source = root.appendingPathComponent("old.jpg")
        let occupied = root.appendingPathComponent("news.jpg")
        let plan = RenamePlanningService().makePlan(
            items: [RenamePlanningItem(sourceImageURL: source)],
            recipe: BatchRenameRecipe(name: "Occupied", components: [.literal("news.jpg")]),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseInsensitive,
                existingURLs: [occupied]
            )
        )
        let row = BatchRenamePreviewRow(entry: try #require(plan.entries.first))

        #expect(row.blockingIssueCount == 1)
        #expect(row.issueText.contains("Already exists: news.jpg"))
        #expect(row.plannedName == "—")
    }

    @MainActor
    @Test("A blocked preview planner leaves the main actor responsive")
    func blockedPlannerDoesNotBlockMainActor() async {
        let gate = BlockingBatchRenamePlanBuilder()
        defer { gate.releaseAll() }
        let source = root.appendingPathComponent("old.jpg")
        let session = BatchRenameSheetSession(
            request: BatchRenameSheetRequest(
                folderURL: root,
                items: [RenamePlanningItem(sourceImageURL: source)]
            ),
            environment: RenamePlanningEnvironment(caseSensitivity: .caseSensitive),
            planningDebounce: .zero,
            planBuilder: { snapshot in gate.build(snapshot) }
        )

        await gate.waitUntilInvocation(1)

        // Reaching this main-actor assertion while the synchronous builder is still blocked is
        // the regression proof: preview CPU work cannot occupy the UI executor.
        #expect(session.isPlanning)
        #expect(session.plan == nil)
        #expect(!session.canExecute)

        gate.release(invocation: 1)
        await session.waitForPlanning()

        #expect(!session.isPlanning)
        #expect(session.plan?.entries.count == 1)
    }

    @MainActor
    @Test("A superseded planner cannot publish stale output")
    func supersededPlannerCannotPublish() async {
        let gate = BlockingBatchRenamePlanBuilder()
        defer { gate.releaseAll() }
        let source = root.appendingPathComponent("old.jpg")
        let session = BatchRenameSheetSession(
            request: BatchRenameSheetRequest(
                folderURL: root,
                items: [RenamePlanningItem(sourceImageURL: source)]
            ),
            environment: RenamePlanningEnvironment(caseSensitivity: .caseSensitive),
            planningDebounce: .zero,
            planBuilder: { snapshot in gate.build(snapshot) }
        )

        await gate.waitUntilInvocation(1)
        session.editor.components[0].literal = "intermediate.jpg"
        await Task.yield()
        session.editor.components[0].literal = "latest.jpg"
        gate.release(invocation: 1)
        await gate.waitUntilInvocation(2)

        // The first builder deliberately ran to completion after cancellation. Its initial
        // "old.jpg" result must remain unpublished while the latest generation is pending.
        #expect(session.isPlanning)
        #expect(session.plan == nil)

        gate.release(invocation: 2)
        await session.waitForPlanning()

        #expect(!session.isPlanning)
        #expect(
            session.plan?.entries.first?.requestedDestinationImageURL?.lastPathComponent
                == "latest.jpg"
        )
    }

    @Test("Successful execution mappings project selection, last click, and manual order through cycles")
    func browserStateProjection() {
        let a = root.appendingPathComponent("A.jpg")
        let b = root.appendingPathComponent("B.jpg")
        let c = root.appendingPathComponent("C.jpg")
        let state = BatchRenameBrowserURLState(
            selectedURLs: [a, b],
            lastClickedURL: a,
            manualOrder: [c, a, b]
        )

        let projected = state.applying([
            .init(sourceURL: a, destinationURL: b),
            .init(sourceURL: b, destinationURL: a),
        ])

        #expect(projected.selectedURLs == [a, b])
        #expect(projected.lastClickedURL == b)
        #expect(projected.manualOrder == [c, b, a])
    }

    @MainActor
    @Test("A failed execution invalidates its plan until a fresh filesystem snapshot")
    func failedExecutionInvalidatesPlan() async {
        let source = root.appendingPathComponent("old.jpg")
        let request = BatchRenameSheetRequest(
            folderURL: root,
            items: [RenamePlanningItem(sourceImageURL: source)]
        )
        let session = BatchRenameSheetSession(
            request: request,
            environment: RenamePlanningEnvironment(caseSensitivity: .caseSensitive)
        )
        session.editor.components[0].literal = "new.jpg"
        await session.waitForPlanning()
        #expect(session.canExecute)

        let failure = RenameExecutionResult(
            status: .failed,
            rollbackStatus: .succeeded,
            bundles: [],
            moves: [],
            issues: [RenameExecutionIssue(
                code: .moveFailed,
                itemIndex: 0,
                artifactIdentifier: "image",
                sourceURL: source,
                destinationURL: root.appendingPathComponent("new.jpg"),
                detail: "Injected failure"
            )],
            residuals: []
        )
        session.recordExecutionResult(failure)

        #expect(session.requiresFreshSnapshotAfterFailure)
        #expect(session.plan == nil)
        #expect(!session.canExecute)
        #expect(session.executionPresentation?.recoveryMessage.contains("restored") == true)
    }

    @MainActor
    @Test("A completed filesystem transaction cannot execute its immutable plan twice")
    func completedExecutionDisablesPlan() async {
        let source = root.appendingPathComponent("old.jpg")
        let request = BatchRenameSheetRequest(
            folderURL: root,
            items: [RenamePlanningItem(sourceImageURL: source)]
        )
        let session = BatchRenameSheetSession(
            request: request,
            environment: RenamePlanningEnvironment(caseSensitivity: .caseSensitive)
        )
        session.editor.components[0].literal = "new.jpg"
        await session.waitForPlanning()
        #expect(session.canExecute)

        session.recordExecutionResult(RenameExecutionResult(
            status: .succeeded,
            rollbackStatus: .notNeeded,
            bundles: [],
            moves: [],
            issues: [],
            residuals: []
        ))

        #expect(session.hasCompletedExecution)
        #expect(!session.canExecute)
    }

    @MainActor
    @Test("Execution awaits the writer barrier before the first filesystem move")
    func executionAwaitsWriterBarrier() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-rename-barrier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("old.jpg")
        let destination = folder.appendingPathComponent("new.jpg")
        try Data("image".utf8).write(to: source)
        var events: [String] = []

        let session = BatchRenameSheetSession(
            request: BatchRenameSheetRequest(
                folderURL: folder,
                items: [RenamePlanningItem(sourceImageURL: source)]
            ),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [source]
            ),
            executionQuiescence: BatchRenameExecutionQuiescence(
                prepare: {
                    events.append("barrier")
                    #expect(FileManager.default.fileExists(atPath: source.path))
                    #expect(!FileManager.default.fileExists(atPath: destination.path))
                    await Task.yield()
                },
                complete: { completion in
                    guard case .succeeded = completion else {
                        Issue.record("Expected a successful barrier completion")
                        return
                    }
                    events.append("completion")
                    #expect(!FileManager.default.fileExists(atPath: source.path))
                    #expect(FileManager.default.fileExists(atPath: destination.path))
                }
            )
        )
        session.editor.components[0].literal = destination.lastPathComponent
        await session.waitForPlanning()

        let result = await session.execute()

        #expect(result?.succeeded == true)
        #expect(events == ["barrier", "completion"])
    }

    @MainActor
    @Test("A writer barrier refusal prevents every filesystem move")
    func writerBarrierRefusalPreventsMoves() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-rename-barrier-refusal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("old.jpg")
        let destination = folder.appendingPathComponent("new.jpg")
        try Data("image".utf8).write(to: source)
        var completionWasCalled = false

        let session = BatchRenameSheetSession(
            request: BatchRenameSheetRequest(
                folderURL: folder,
                items: [RenamePlanningItem(sourceImageURL: source)]
            ),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [source]
            ),
            executionQuiescence: BatchRenameExecutionQuiescence(
                prepare: {
                    throw BatchRenameExecutionQuiescenceError.faceScan("final save failed")
                },
                complete: { _ in completionWasCalled = true }
            )
        )
        session.editor.components[0].literal = destination.lastPathComponent
        await session.waitForPlanning()

        let result = await session.execute()

        #expect(result == nil)
        #expect(!completionWasCalled)
        #expect(session.executionGuardError?.contains("Face-data writer") == true)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Failure presentation reports residual paths and never publishes success mappings")
    func failurePresentation() {
        let source = root.appendingPathComponent("old.jpg")
        let destination = root.appendingPathComponent("new.jpg")
        let temporary = root.appendingPathComponent(".aagedal-rename-temp-old.jpg")
        let result = RenameExecutionResult(
            status: .failed,
            rollbackStatus: .failed,
            bundles: [RenameExecutionBundleResult(
                itemIndex: 0,
                sourceImageURL: source,
                destinationImageURL: destination,
                artifactIdentifiers: ["image"],
                completedArtifactIdentifiers: []
            )],
            moves: [],
            issues: [],
            residuals: [RenameExecutionResidual(
                itemIndex: 0,
                artifactIdentifier: "image",
                location: .temporary,
                currentURL: temporary,
                expectedSourceURL: source,
                intendedDestinationURL: destination,
                temporaryURL: temporary,
                metadataMayContainUpdatedSourceFile: false
            )]
        )

        let presentation = BatchRenameExecutionPresentation(result: result)

        #expect(presentation.mappings.isEmpty)
        #expect(presentation.recoveryMessage.contains("incomplete"))
        #expect(!presentation.canRefreshOriginalRequest)
        #expect(presentation.residualDetails.first?.contains(temporary.path) == true)
        #expect(presentation.residualDetails.first?.contains(destination.path) == true)
    }

    @Test("RAW cycles keep XMP Develop settings and path-keyed app associations")
    func rawCycleReassociation() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-rename-reassociation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let a = folder.appendingPathComponent("A.NEF")
        let b = folder.appendingPathComponent("B.NEF")
        try Data("raw-a".utf8).write(to: a)
        try Data("raw-b".utf8).write(to: b)

        var settingsA = CameraRawSettings()
        settingsA.exposure2012 = 0.75
        var settingsB = CameraRawSettings()
        settingsB.exposure2012 = -0.5
        let xmp = XMPSidecarService()
        try xmp.saveSidecar(metadata: IPTCMetadata(cameraRaw: settingsA), for: a)
        try xmp.saveSidecar(metadata: IPTCMetadata(cameraRaw: settingsB), for: b)

        let revisionA = try await SourceImageRevision.capture(at: a)
        let revisionB = try await SourceImageRevision.capture(at: b)

        let faceA = UUID()
        let faceB = UUID()
        try FaceDataStorageService().saveFaceData(FolderFaceData(
            folderURL: folder,
            faces: [
                DetectedFace(
                    id: faceA,
                    imageURL: a,
                    faceRect: .zero,
                    featurePrintData: Data([1]),
                    detectedAt: Date()
                ),
                DetectedFace(
                    id: faceB,
                    imageURL: b,
                    faceRect: .zero,
                    featurePrintData: Data([2]),
                    detectedAt: Date()
                ),
            ],
            groups: [],
            lastScanDate: Date(),
            scanComplete: true,
            scannedFiles: [
                a.path: FileSignature(modificationDate: Date(timeIntervalSince1970: 1), fileSize: 5),
                b.path: FileSignature(modificationDate: Date(timeIntervalSince1970: 2), fileSize: 5),
            ]
        ))

        let analysisRepository = AnalysisCaseRepository(sourceFolderURL: folder)
        let analysisA = AnalysisCase.create(for: revisionA)
        let analysisB = AnalysisCase.create(for: revisionB)
        try await analysisRepository.save(analysisA)
        try await analysisRepository.save(analysisB)

        let versionRepository = DevelopVersionCatalogRepository(
            sourceFolderURL: folder,
            applicationSupportURL: folder.appendingPathComponent("fallback", isDirectory: true)
        )
        var catalogA = DevelopVersionCatalog.create(for: revisionA)
        _ = try catalogA.createVersion(name: "A named version", settings: settingsA)
        var catalogB = DevelopVersionCatalog.create(for: revisionB)
        _ = try catalogB.createVersion(name: "B named version", settings: settingsB)
        try await versionRepository.save(catalogA)
        try await versionRepository.save(catalogB)

        let plan = RenamePlanningService().makePlan(
            items: [
                RenamePlanningItem(
                    sourceImageURL: a,
                    context: BatchRenameContext(
                        originalFilename: a.lastPathComponent,
                        metadata: [.event: b.lastPathComponent]
                    )
                ),
                RenamePlanningItem(
                    sourceImageURL: b,
                    context: BatchRenameContext(
                        originalFilename: b.lastPathComponent,
                        metadata: [.event: a.lastPathComponent]
                    )
                ),
            ],
            recipe: BatchRenameRecipe(name: "Swap", components: [.token(.metadata(.event))]),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [a, b, xmp.sidecarURL(for: a), xmp.sidecarURL(for: b)]
            )
        )
        let execution = await RenameExecutionService().execute(plan)
        #expect(execution.succeeded)
        let presentation = BatchRenameExecutionPresentation(result: execution)
        let reassociation = await RenameReassociationService().reassociate(
            folderURL: folder,
            mappings: presentation.mappings
        )
        #expect(reassociation.succeeded)

        // Sidecars participate in the filesystem transaction: settings follow their RAW bytes.
        #expect(xmp.loadSidecar(for: a)?.cameraRaw?.exposure2012 == settingsB.exposure2012)
        #expect(xmp.loadSidecar(for: b)?.cameraRaw?.exposure2012 == settingsA.exposure2012)

        let faceData = try #require(FaceDataStorageService().loadFaceData(for: folder))
        #expect(faceData.faces.first(where: { $0.id == faceA })?.imageURL == b)
        #expect(faceData.faces.first(where: { $0.id == faceB })?.imageURL == a)
        #expect(Set(faceData.scannedFiles.keys) == [a.path, b.path])

        let renamedRevisionAtA = try await SourceImageRevision.capture(at: a)
        let renamedRevisionAtB = try await SourceImageRevision.capture(at: b)
        guard case .exact(let reopenedAnalysisAtA) = await analysisRepository.loadMostRelevantCase(
            for: renamedRevisionAtA
        ) else {
            Issue.record("Expected B's analysis case at A")
            return
        }
        #expect(reopenedAnalysisAtA.id == analysisB.id)
        #expect(reopenedAnalysisAtA.source.canonicalURL == a.standardizedFileURL)

        guard case .exact(let reopenedAnalysisAtB) = await analysisRepository.loadMostRelevantCase(
            for: renamedRevisionAtB
        ) else {
            Issue.record("Expected A's analysis case at B")
            return
        }
        #expect(reopenedAnalysisAtB.id == analysisA.id)
        #expect(reopenedAnalysisAtB.source.canonicalURL == b.standardizedFileURL)

        // Named Develop catalogs are content-hash keyed; no filename mutation is appropriate.
        guard case .exact(let reopenedCatalogAtA, _, _) = await versionRepository
            .loadMostRelevantCatalog(for: renamedRevisionAtA) else {
            Issue.record("Expected B's named version catalog at A")
            return
        }
        #expect(reopenedCatalogAtA.versions.first?.name == "B named version")
        guard case .exact(let reopenedCatalogAtB, _, _) = await versionRepository
            .loadMostRelevantCatalog(for: renamedRevisionAtB) else {
            Issue.record("Expected A's named version catalog at B")
            return
        }
        #expect(reopenedCatalogAtB.versions.first?.name == "A named version")
    }
}

private nonisolated final class BlockingBatchRenamePlanBuilder: @unchecked Sendable {
    private let condition = NSCondition()
    private var invocationCount = 0
    private var releasedInvocations: Set<Int> = []
    private var releasesAllInvocations = false

    func build(_ snapshot: BatchRenamePlanningSnapshot) -> RenamePlan {
        condition.lock()
        invocationCount += 1
        let invocation = invocationCount
        condition.broadcast()
        while !releasesAllInvocations, !releasedInvocations.contains(invocation) {
            condition.wait()
        }
        condition.unlock()

        return RenamePlanningService().makePlan(
            items: snapshot.items,
            recipe: snapshot.recipe,
            collisionPolicy: snapshot.collisionPolicy,
            artifactRegistry: snapshot.artifactRegistry,
            environment: snapshot.environment
        )
    }

    func waitUntilInvocation(_ expectedCount: Int) async {
        while currentInvocationCount < expectedCount {
            await Task.yield()
        }
    }

    func release(invocation: Int) {
        condition.lock()
        releasedInvocations.insert(invocation)
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        releasesAllInvocations = true
        condition.broadcast()
        condition.unlock()
    }

    private var currentInvocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return invocationCount
    }
}
