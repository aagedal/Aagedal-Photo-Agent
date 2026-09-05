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
