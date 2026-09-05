import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Metadata editor sidecar read boundary", .serialized)
struct MetadataEditorReadServiceTests {
    @Test("complete immutable source facts are read serially away from MainActor")
    @MainActor
    func completeFactsRunOffMainActor() async {
        let urls = [
            URL(fileURLWithPath: "/virtual/one.raw"),
            URL(fileURLWithPath: "/virtual/two.raw")
        ]
        let folderURL = URL(fileURLWithPath: "/virtual")
        let requestID = UUID()
        let probe = MetadataEditorReadAccessProbe()
        let service = MetadataEditorReadService(access: .init(read: probe.read))
        let request = MetadataEditorReadRequest(
            id: requestID,
            imageURLs: urls,
            folderURL: folderURL,
            embeddedMetadataByImageURL: [
                urls[0]: IPTCMetadata(title: "Embedded one"),
                urls[1]: IPTCMetadata(title: "Embedded two")
            ]
        )

        let result = await Task { await service.load(request) }.value

        guard case .complete(let snapshot) = result else {
            Issue.record("Expected complete Metadata editor facts")
            return
        }
        #expect(snapshot.request.id == requestID)
        #expect(snapshot.request.folderURL == folderURL)
        #expect(snapshot.inspectedImageURLs == urls)
        #expect(snapshot.isComplete)
        #expect(snapshot.factsByImageURL[urls[0]]?.xmpMetadata?.title == "XMP 1")
        #expect(snapshot.factsByImageURL[urls[1]]?.appSidecar?.metadata.title == "Draft 2")
        #expect(snapshot.factsByImageURL[urls[0]]?.reconciliationVerdict == .sidecarMaster)
        #expect(probe.readURLs == urls)
        #expect(!probe.ranOnMainThread)
        #expect(probe.maximumConcurrentReads == 1)
    }

    @Test("pre-cancellation performs no source reads")
    func preCancellation() async {
        let url = URL(fileURLWithPath: "/virtual/cancelled.raw")
        let request = MetadataEditorReadRequest(
            id: UUID(),
            imageURLs: [url],
            folderURL: nil,
            embeddedMetadataByImageURL: [:]
        )
        let probe = MetadataEditorReadAccessProbe()
        let service = MetadataEditorReadService(access: .init(read: probe.read))
        let task = Task {
            await Task.yield()
            return await service.load(request)
        }
        task.cancel()

        guard case .cancelledBeforeRead(let cancelledRequest) = await task.value else {
            Issue.record("Expected cancellation before the first read")
            return
        }
        #expect(cancelledRequest.id == request.id)
        #expect(probe.readURLs.isEmpty)
    }

    @Test("cancellation preserves the exact completed prefix and final-read state")
    func cancellationEvidence() async {
        let urls = [
            URL(fileURLWithPath: "/virtual/one.raw"),
            URL(fileURLWithPath: "/virtual/two.raw"),
            URL(fileURLWithPath: "/virtual/three.raw")
        ]
        let partialProbe = MetadataEditorReadAccessProbe(cancelAtInvocation: 2)
        let partialService = MetadataEditorReadService(access: .init(read: partialProbe.read))
        let partialRequest = MetadataEditorReadRequest(
            id: UUID(),
            imageURLs: urls,
            folderURL: nil,
            embeddedMetadataByImageURL: [:]
        )

        let partialTask = Task {
            await partialService.load(partialRequest)
        }
        guard case .cancelledAfterPartialRead(let partialSnapshot) = await partialTask.value else {
            Issue.record("Expected cancellation after an exact partial prefix")
            return
        }
        #expect(partialSnapshot.inspectedImageURLs == Array(urls.prefix(2)))
        #expect(!partialSnapshot.isComplete)
        #expect(partialProbe.readURLs == Array(urls.prefix(2)))

        let completeProbe = MetadataEditorReadAccessProbe(cancelAtInvocation: 1)
        let completeService = MetadataEditorReadService(access: .init(read: completeProbe.read))
        let completeRequest = MetadataEditorReadRequest(
            id: UUID(),
            imageURLs: [urls[0]],
            folderURL: nil,
            embeddedMetadataByImageURL: [:]
        )
        let completeTask = Task {
            await completeService.load(completeRequest)
        }
        guard case .cancelledAfterCompleteRead(let completeSnapshot) = await completeTask.value else {
            Issue.record("Expected cancellation after the final complete read")
            return
        }
        #expect(completeSnapshot.inspectedImageURLs == [urls[0]])
        #expect(completeSnapshot.isComplete)
    }

    @Test("queued requests serialize and can cancel before touching storage")
    @MainActor
    func queuedCancellation() async throws {
        let firstURL = URL(fileURLWithPath: "/virtual/blocked.raw")
        let secondURL = URL(fileURLWithPath: "/virtual/queued.raw")
        let probe = MetadataEditorReadAccessProbe(blocksFirstRead: true)
        defer { probe.releaseFirstRead() }
        let service = MetadataEditorReadService(access: .init(read: probe.read))
        let firstRequest = MetadataEditorReadRequest(
            id: UUID(), imageURLs: [firstURL], folderURL: nil,
            embeddedMetadataByImageURL: [:]
        )
        let secondRequest = MetadataEditorReadRequest(
            id: UUID(), imageURLs: [secondURL], folderURL: nil,
            embeddedMetadataByImageURL: [:]
        )

        let first = Task { await service.load(firstRequest) }
        try await probe.waitUntilFirstReadStarts()
        let second = Task { await service.load(secondRequest) }
        second.cancel()
        probe.releaseFirstRead()

        guard case .complete(let firstSnapshot) = await first.value else {
            Issue.record("Expected the first request to complete")
            return
        }
        #expect(firstSnapshot.inspectedImageURLs == [firstURL])
        guard case .cancelledBeforeRead(let cancelledRequest) = await second.value else {
            Issue.record("Expected the queued request to cancel before reading")
            return
        }
        #expect(cancelledRequest.imageURLs == [secondURL])
        #expect(probe.readURLs == [firstURL])
        #expect(!probe.ranOnMainThread)
        #expect(probe.maximumConcurrentReads == 1)
    }

    @Test("production access freezes XMP, JSON history, and timestamp reconciliation")
    func productionAccess() async throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataEditorRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let imageURL = folderURL.appendingPathComponent("sample.jpg")
        try Data("image".utf8).write(to: imageURL)
        let embedded = IPTCMetadata(title: "New embedded")
        try XMPSidecarService().saveSidecar(
            metadata: IPTCMetadata(title: "Old XMP"),
            for: imageURL
        )
        let history = MetadataHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 50),
            fieldName: "Title",
            oldValue: "Before",
            newValue: "Draft"
        )
        try MetadataSidecarService().saveSidecar(
            MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                pendingChanges: true,
                metadata: IPTCMetadata(title: "Draft"),
                history: [history]
            ),
            for: imageURL,
            in: folderURL
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: XMPSidecarService().sidecarURL(for: imageURL).path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: imageURL.path
        )
        let request = MetadataEditorReadRequest(
            id: UUID(),
            imageURLs: [imageURL],
            folderURL: folderURL,
            embeddedMetadataByImageURL: [imageURL: embedded]
        )

        let result = await MetadataEditorReadService().load(request)

        guard case .complete(let snapshot) = result,
              let facts = snapshot.factsByImageURL[imageURL] else {
            Issue.record("Expected production source facts")
            return
        }
        #expect(facts.xmpMetadata?.title == "Old XMP")
        #expect(facts.appSidecar?.metadata.title == "Draft")
        #expect(facts.appSidecar?.history.first?.newValue == "Draft")
        #expect(facts.reconciliationVerdict == .fileNewerConflict)
    }

    @Test("same-image reload publishes only the newest request")
    @MainActor
    func sameImageReloadRejectsStalePublication() async throws {
        let imageURL = URL(fileURLWithPath: "/virtual/reload.jpg")
        let probe = MetadataEditorReadAccessProbe(blocksFirstRead: true)
        defer { probe.releaseFirstRead() }
        let service = MetadataEditorReadService(access: .init(read: probe.read))
        let model = MetadataViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            editorReadService: service
        )
        let image = ImageFile(url: imageURL)

        model.loadMetadata(for: [image], folderURL: imageURL.deletingLastPathComponent())
        try await probe.waitUntilFirstReadStarts()
        model.loadMetadata(for: [image], folderURL: imageURL.deletingLastPathComponent())
        probe.releaseFirstRead()

        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isLoading)
        #expect(model.editingMetadata.title == "Draft 2")
        #expect(model.metadataLoadGeneration == 1)
        #expect(probe.readURLs == [imageURL, imageURL])
    }

    @Test("write cleanup uses persisted sidecar baseline despite editor source overlays")
    @MainActor
    func writeCleanupUsesPersistedBaseline() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("draft.jpg")
        let pending = IPTCMetadata(title: "Pending title")
        let service = MetadataSidecarService()
        try service.saveSidecar(
            MetadataSidecar(sourceFile: imageURL.lastPathComponent, pendingChanges: true, metadata: pending),
            for: imageURL, in: folder
        )
        let persisted = try #require(service.loadSidecar(for: imageURL, in: folder))
        var xmp = IPTCMetadata(title: "Reference title")
        var cameraRaw = CameraRawSettings()
        cameraRaw.exposure2012 = 0.5
        xmp.cameraRaw = cameraRaw
        let reference = xmp
        let readBoundary = MetadataEditorReadService(access: .init(read: { url, _, _, _ in
            MetadataEditorSourceFacts(
                imageURL: url, xmpMetadata: reference,
                appSidecar: persisted, reconciliationVerdict: nil
            )
        }))
        let model = MetadataViewModel(
            readService: SwiftExifReadService(),
            writeEngine: MetadataCleanupSuccessfulWriter(),
            editorReadService: readBoundary
        )
        model.loadMetadata(for: [ImageFile(url: imageURL)], folderURL: folder)
        let loadDeadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < loadDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isLoading)
        #expect(model.editingMetadata.title == "Pending title")
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == 0.5)
        #expect(model.editingMetadata.cameraRaw != persisted.metadata.cameraRaw)

        model.writeMetadataAndClearSidecar()
        let writeDeadline = ContinuousClock.now + .seconds(5)
        while model.isSaving, ContinuousClock.now < writeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isSaving)
        #expect(model.saveError == nil)
        #expect(!model.hasChanges)
        #expect(service.loadSidecar(for: imageURL, in: folder) == nil)
    }

    @Test("failed selected discard retains the draft and history")
    @MainActor
    func failedDiscardRetainsEditor() async throws {
        let model = makeDiscardModel { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let draft = model.editingMetadata
        let history = model.sidecarHistory

        let task = try #require(model.discardPendingChanges())
        await task.value

        #expect(model.editingMetadata == draft)
        #expect(model.sidecarHistory.map(\.id) == history.map(\.id))
        #expect(model.hasChanges)
        #expect(model.saveError?.contains("1 image(s)") == true)
    }

    @Test("selected discard completion preserves newer draft, selection, or batch intent", arguments: ["draft", "selection", "batch intent"])
    @MainActor
    func staleDiscardPreservesEditor(change: String) async throws {
        let gate = MetadataDiscardGate()
        let model = makeDiscardModel { _, _ in await gate.enter() }
        if change == "batch intent" {
            model.selectedCount = 2
            model.selectedURLs.append(URL(fileURLWithPath: "/virtual/second.jpg"))
            // Clearing an already empty common list changes intent without changing its preview.
            model.batchCommonMetadata = model.editingMetadata
        }
        let task = try #require(model.discardPendingChanges())
        await gate.waitUntilStarted()
        if change == "draft" {
            model.editingMetadata.title = "Newer draft"
        } else if change == "selection" {
            model.selectedURLs = [URL(fileURLWithPath: "/virtual/new-selection.jpg")]
        } else {
            try model.setBatchMutation(.clear, for: .keywords)
        }
        let expectedDraft = model.editingMetadata
        let expectedHistory = model.sidecarHistory
        await gate.release()
        await task.value

        #expect(model.editingMetadata == expectedDraft)
        #expect(model.sidecarHistory.map(\.id) == expectedHistory.map(\.id))
        #expect(model.hasChanges)
        if change == "batch intent" {
            #expect(model.batchFieldMutations[.keywords] == .clear)
        }
    }

    @Test("successful batch discard clears explicit intent and cached common values")
    @MainActor
    func batchDiscardClearsIntent() async throws {
        let model = makeDiscardModel { _, _ in }
        model.selectedCount = 2
        model.selectedURLs.append(URL(fileURLWithPath: "/virtual/second.jpg"))
        model.batchCommonMetadata = IPTCMetadata(keywords: ["common"])
        model.batchPartialKeywords = ["partial"]
        model.batchPartialPersonShown = ["Person"]
        model.batchDifferingFields = ["keywords"]
        try model.setBatchMutation(.append(["discarded"]), for: .keywords)
        try model.setBatchLocationsShownMutation(.clear)
        try model.setBatchImageSupplierMutation(.clear)

        let task = try #require(model.discardPendingChanges())
        await task.value

        #expect(!model.hasChanges)
        #expect(model.editingMetadata == IPTCMetadata())
        #expect(model.sidecarHistory.isEmpty)
        #expect(model.batchFieldMutations.isEmpty)
        #expect(model.batchLocationsShownMutation == .untouched)
        #expect(model.batchImageSupplierMutation == .untouched)
        #expect(model.batchCommonMetadata == nil)
        #expect(model.batchPartialKeywords.isEmpty)
        #expect(model.batchPartialPersonShown.isEmpty)
        #expect(model.batchDifferingFields.isEmpty)
        // A subsequent intent must not bring back the discarded keyword append.
        try model.setBatchMutation(.append(["fresh"]), for: .keywords)
        #expect(model.editingMetadata.keywords == ["fresh"])
    }

    @Test("cancelling admitted selected or folder discard allows deletion to finish", arguments: [false, true])
    func admittedDiscardCancellation(folderWide: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("draft.jpg")
        let service = MetadataSidecarService()
        try service.saveSidecar(MetadataSidecar(
            sourceFile: imageURL.lastPathComponent,
            lastModified: Date(),
            pendingChanges: true,
            metadata: IPTCMetadata(title: "Draft"),
            imageMetadataSnapshot: IPTCMetadata(title: "Original"),
            history: []
        ), for: imageURL, in: folder)
        let gate = MetadataDiscardAdmissionGate()
        defer { gate.release() }
        let task = Task {
            if folderWide {
                try await service.deleteAllSidecarsSerialized(in: folder) {
                    gate.blockAfterAdmission()
                }
            } else {
                try await service.deleteSidecarSerialized(for: imageURL, in: folder) {
                    gate.blockAfterAdmission()
                }
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.hasEntered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.hasEntered)
        task.cancel()
        gate.release()
        try await task.value
        #expect(service.loadSidecar(for: imageURL, in: folder) == nil)
    }

    @Test("folder discard preserves a newer draft, folder, or batch intent", arguments: ["draft", "folder", "batch intent"])
    @MainActor
    func staleFolderDiscard(change: String) async throws {
        let gate = MetadataDiscardGate()
        let model = makeDiscardModel(folderDiscard: { _ in await gate.enter() }, discard: { _, _ in })
        if change == "batch intent" {
            model.selectedCount = 2
            model.selectedURLs.append(URL(fileURLWithPath: "/virtual/second.jpg"))
            model.batchCommonMetadata = model.editingMetadata
        }
        let task = try #require(model.discardAllPendingInFolder())
        await gate.waitUntilStarted()
        if change == "draft" {
            model.editingMetadata.title = "New draft"
        } else if change == "folder" {
            model.currentFolderURL = URL(fileURLWithPath: "/other")
        } else {
            try model.setBatchMutation(.clear, for: .keywords)
        }
        let draft = model.editingMetadata
        await gate.release()
        await task.value
        #expect(model.editingMetadata == draft)
        #expect(model.hasChanges)
        #expect(!model.sidecarHistory.isEmpty)
    }

    @Test("folder discard failure retains editor; success clears batch intent")
    @MainActor
    func folderDiscardResult() async throws {
        let failed = makeDiscardModel(folderDiscard: { _ in
            throw CocoaError(.fileWriteNoPermission)
        }, discard: { _, _ in })
        await failed.discardAllPendingInFolder()?.value
        #expect(failed.editingMetadata.title == "Draft")
        #expect(failed.hasChanges)
        #expect(failed.saveError != nil)

        let model = makeDiscardModel(folderDiscard: { _ in }, discard: { _, _ in })
        model.selectedURLs.append(URL(fileURLWithPath: "/virtual/second.jpg"))
        model.selectedCount = 2
        model.batchCommonMetadata = model.editingMetadata
        try model.setBatchMutation(.append(["old"]), for: .keywords)
        try model.setBatchImageSupplierMutation(.clear)
        await model.discardAllPendingInFolder()?.value
        #expect(model.editingMetadata == IPTCMetadata())
        #expect(model.batchCommonMetadata == nil)
        #expect(model.batchFieldMutations.isEmpty)
        #expect(model.batchImageSupplierMutation == .untouched)
        #expect(!model.hasChanges)
        #expect(model.sidecarHistory.isEmpty)
    }

    @Test("folder barriers serialize photo operations and later barriers while siblings proceed")
    func folderBarrierOrdering() async throws {
        let coordinator = MetadataIOCoordinator()
        let gate = MetadataDiscardGate()
        let events = FolderDiscardEvents()
        let barrier = Task {
            await coordinator.withFolderLock("/virtual") {
                await events.append("folder-start")
                await gate.enter()
                await events.append("folder-end")
            }
        }
        await gate.waitUntilStarted()
        let photo = Task {
            await coordinator.withLock("/virtual/image") { await events.append("photo") }
        }
        let nextBarrier = Task {
            await coordinator.withFolderLock("/virtual") { await events.append("next-folder") }
        }
        await coordinator.withLock("/virtual-sibling/image") { await events.append("sibling") }
        #expect(await events.values == ["folder-start", "sibling"])
        await gate.release()
        await barrier.value
        await photo.value
        await nextBarrier.value
        let result = await events.values
        #expect(result.firstIndex(of: "folder-end")! < result.firstIndex(of: "photo")!)
        #expect(result.firstIndex(of: "folder-end")! < result.firstIndex(of: "next-folder")!)
    }

    @Test("folder discard waits for admitted photo writes and removes directory off main")
    @MainActor
    func folderDiscardService() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = folder.appendingPathComponent(MetadataSidecarService.sidecarDirectoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = MetadataDiscardGate()
        let imageURL = folder.appendingPathComponent("image.jpg")
        let write = Task {
            try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) {
                await gate.enter()
                try Data("saved".utf8).write(to: directory.appendingPathComponent("image.jpg.meta.json"))
            }
        }
        await gate.waitUntilStarted()
        let deletion = Task {
            try await MetadataSidecarService().deleteAllSidecarsSerialized(in: folder) {
                #expect(!Thread.isMainThread)
            }
        }
        await gate.release()
        try await write.value
        try await deletion.value
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await MetadataSidecarService().deleteAllSidecarsSerialized(in: folder)
        }
        do {
            try await cancelled.value
            Issue.record("Pre-cancelled folder deletion should fail")
        } catch is CancellationError {} catch { throw error }
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    private func makeDiscardModel(
        folderDiscard: @escaping @Sendable (URL) async throws -> Void = { _ in },
        discard: @escaping @Sendable (URL, URL) async throws -> Void
    ) -> MetadataViewModel {
        let model = MetadataViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            discardSidecar: discard,
            discardFolderSidecars: folderDiscard
        )
        model.currentFolderURL = URL(fileURLWithPath: "/virtual")
        model.selectedURLs = [URL(fileURLWithPath: "/virtual/draft.jpg")]
        model.selectedCount = 1
        model.originalImageMetadata = IPTCMetadata(title: "Original")
        model.editingMetadata = IPTCMetadata(title: "Draft")
        model.hasChanges = true
        model.sidecarHistory = MetadataHistoryEntry.changes(
            from: IPTCMetadata(title: "Original"),
            to: model.editingMetadata,
            timestamp: Date()
        )
        return model
    }

    @Test("passive Metadata callers await complete request-owned facts")
    func metadataViewModelSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/MetadataViewModel.swift"
            ),
            encoding: .utf8
        )
        let ranges = try [
            sourceSlice(source, from: "func loadCaptionCopyPreviousMetadata(", to: "func loadMetadata("),
            sourceSlice(source, from: "func loadMetadata(", to: "func applyReferenceSource("),
            sourceSlice(source, from: "private func loadBatchMetadata(", to: "private func compareOptionalField"),
            sourceSlice(source, from: "private func processVariablesBatch(", to: "private func refreshMetadataAfterProcessing("),
            sourceSlice(source, from: "private func refreshMetadataAfterProcessing(", to: "private func resolveIfChanged")
        ]
        let passiveSource = ranges.joined(separator: "\n")

        #expect(passiveSource.contains("await editorReadService.load("))
        #expect(passiveSource.contains("case .complete(let"))
        #expect(passiveSource.contains("metadataLoadRequestID == requestID"))
        #expect(passiveSource.contains("currentFolderURL == folderSnapshot"))
        #expect(!passiveSource.contains("sidecarService.loadSidecar("))
        #expect(!passiveSource.contains("xmpSidecarService.loadSidecar("))
        #expect(!passiveSource.contains("SidecarReconciliation.verdict("))
        #expect(!source.contains("refreshPendingSidecarsFlag"))
    }

    private func sourceSlice(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(
            of: end,
            range: startRange.upperBound..<source.endIndex
        ))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}

private nonisolated final class MetadataEditorReadAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let firstReadGate = DispatchSemaphore(value: 0)
    private let cancelAtInvocation: Int?
    private let blocksFirstRead: Bool
    private var urls: [URL] = []
    private var observedMainThread = false
    private var activeReads = 0
    private var maximumReads = 0
    private var firstReadReleased = false

    init(cancelAtInvocation: Int? = nil, blocksFirstRead: Bool = false) {
        self.cancelAtInvocation = cancelAtInvocation
        self.blocksFirstRead = blocksFirstRead
    }

    func read(
        imageURL: URL,
        folderURL: URL?,
        embedded: IPTCMetadata?,
        reconciles: Bool
    ) -> MetadataEditorSourceFacts {
        let state = lock.withLock { () -> (Int, Bool, Bool) in
            urls.append(imageURL)
            observedMainThread = observedMainThread || Thread.isMainThread
            activeReads += 1
            maximumReads = max(maximumReads, activeReads)
            let invocation = urls.count
            return (
                invocation,
                invocation == cancelAtInvocation,
                blocksFirstRead && invocation == 1 && !firstReadReleased
            )
        }
        defer { lock.withLock { activeReads -= 1 } }
        if state.2 { firstReadGate.wait() }
        if state.1 { withUnsafeCurrentTask { $0?.cancel() } }

        let xmp = IPTCMetadata(title: "XMP \(state.0)")
        let appSidecar = folderURL.map { _ in
            MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                pendingChanges: state.0 == 2,
                metadata: IPTCMetadata(title: "Draft \(state.0)")
            )
        }
        return MetadataEditorSourceFacts(
            imageURL: imageURL,
            xmpMetadata: xmp,
            appSidecar: appSidecar,
            reconciliationVerdict: reconciles && embedded != nil ? .sidecarMaster : nil
        )
    }

    func waitUntilFirstReadStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while readURLs.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!readURLs.isEmpty)
    }

    func releaseFirstRead() {
        let shouldSignal = lock.withLock {
            guard !firstReadReleased else { return false }
            firstReadReleased = true
            return true
        }
        if shouldSignal { firstReadGate.signal() }
    }

    var readURLs: [URL] { lock.withLock { urls } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var maximumConcurrentReads: Int { lock.withLock { maximumReads } }
}

/// Suspends the injected discard without blocking MainActor or relying on scheduling delays.
private actor MetadataDiscardGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { completionWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        completionWaiters.forEach { $0.resume() }
        completionWaiters.removeAll()
    }
}

private nonisolated final class MetadataDiscardAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false

    var hasEntered: Bool { lock.withLock { entered } }

    func blockAfterAdmission() {
        lock.withLock { entered = true }
        semaphore.wait()
    }

    func release() { semaphore.signal() }
}

private actor FolderDiscardEvents {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

/// Successful image writer isolates the editor's post-write sidecar transaction.
private nonisolated final class MetadataCleanupSuccessfulWriter: MetadataWriteEngine {
    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {}
    func writeFieldsToRenderedFiles(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {}
    func addRemoveListValues(add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]], to urls: [URL]) async throws {}
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws {}
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws {}
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws {}
    func stripIPTCAndXMP(from urls: [URL]) async throws {}
    func copyMetadataToRenderedFile(from source: URL, to destination: URL, bakedCameraRaw: CameraRawSettings?) async throws {}
}
