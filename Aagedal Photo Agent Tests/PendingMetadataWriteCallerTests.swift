import Foundation
import Testing
@testable import Aagedal_Photo_Agent

private actor PendingWriteCallerDiscovery {
    var result: PendingMetadataDiscoveryResult
    init(_ result: PendingMetadataDiscoveryResult) { self.result = result }
    func replace(_ result: PendingMetadataDiscoveryResult) { self.result = result }
    func load(_ folder: URL) -> PendingMetadataDiscoveryResult { result }
}

private actor PendingWriteCallerExecutor {
    enum Outcome: Sendable { case success, skipped, partialCancelled, failed }
    private(set) var requests: [PendingMetadataWriteRequest] = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    let pausedNames: Set<String>
    let outcomes: [String: Outcome]
    init(pausedNames: Set<String> = [], outcomes: [String: Outcome] = [:]) {
        self.pausedNames = pausedNames; self.outcomes = outcomes
    }
    func isPaused(_ name: String) -> Bool { gates[name] != nil }
    func resume(_ name: String) { gates.removeValue(forKey: name)?.resume() }
    func execute(_ request: PendingMetadataWriteRequest) async -> PendingMetadataWriteResult {
        requests.append(request)
        let name = request.imageURL.lastPathComponent
        if pausedNames.contains(name) { await withCheckedContinuation { gates[name] = $0 } }
        switch outcomes[name] ?? .success {
        case .success:
            var installed = request.expectedSidecar
            installed.pendingChanges = false
            return .init(requestID: request.id, imageURL: request.imageURL,
                installedSidecar: installed, didWriteEmbedded: true)
        case .skipped:
            return .init(requestID: request.id, imageURL: request.imageURL, wasSkipped: true)
        case .partialCancelled:
            return .init(requestID: request.id, imageURL: request.imageURL, didWriteXMP: true,
                wasCancelled: true, failure: "Cancelled after XMP commit; pending record retained")
        case .failed:
            return .failed(request: request, message: "Injected pending-write failure")
        }
    }
}

@Suite("Write All pending caller ownership and outcomes", .serialized)
struct PendingMetadataWriteCallerTests {
    private func record(_ url: URL, title: String = "Captured pending headline") -> MetadataSidecar {
        .init(sourceFile: url.lastPathComponent, pendingChanges: true,
            metadata: IPTCMetadata(title: title), imageMetadataSnapshot: nil)
    }

    @MainActor
    private func model(discovery: PendingWriteCallerDiscovery, executor: PendingWriteCallerExecutor) -> MetadataViewModel {
        MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            pendingWriteDiscovery: { await discovery.load($0) },
            pendingWriteExecutor: { await executor.execute($0) })
    }

    private func waitForPause(_ executor: PendingWriteCallerExecutor, name: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await executor.isPaused(name)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await executor.isPaused(name))
    }

    @Test("Write All reports the sorted committed/skipped/cancelled prefix and undispatched suffix")
    @MainActor
    func truthfulPartialCancellationPrefix() async throws {
        let folder = URL(fileURLWithPath: "/virtual/pending-prefix")
        let urls = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"].map { folder.appendingPathComponent($0) }
        let discoveryFailure = PendingMetadataDiscoveryFailure(
            url: folder.appendingPathComponent(".photo_metadata/broken.meta.json"), message: "Unreadable owned metadata")
        let discovery = PendingWriteCallerDiscovery(.init(records: Dictionary(uniqueKeysWithValues: urls.reversed().map { ($0, record($0)) }),
            failures: [discoveryFailure]))
        let executor = PendingWriteCallerExecutor(outcomes: ["b.jpg": .skipped, "c.jpg": .partialCancelled])
        let model = model(discovery: discovery, executor: executor)
        model.currentFolderURL = folder
        model.selectedURLs = [urls[0]]
        model.writeAllPendingChanges(in: folder, images: [])
        await model.waitForPendingMetadataWriteBatch()
        let outcome = try #require(model.pendingWriteBatchOutcome)
        #expect(outcome.results.map(\.imageURL) == Array(urls.prefix(3)))
        #expect(outcome.unattemptedURLs == [urls[3]])
        #expect(outcome.completedCount == 1)
        #expect(outcome.attention?.message == outcome.attentionMessage)
        #expect(outcome.skippedCount == 1)
        #expect(outcome.failedCount == 0)
        #expect(outcome.wasCancelled)
        #expect(outcome.results.last?.didWriteXMP == true)
        #expect(outcome.discoveryFailures.count == 1)
        #expect(outcome.attentionMessage?.contains("Already written: XMP sidecar") == true)
        #expect(outcome.attentionMessage?.contains(discoveryFailure.url.path) == true)
        #expect(outcome.attentionMessage?.contains("1 discovered photos were not attempted") == true)
        #expect(!model.isProcessingFolder)
        #expect(model.folderProcessProgress.isEmpty)
        #expect(model.saveError == outcome.attentionMessage)
    }

    @Test("Write All snapshots the discovered records and policy without adopting stale Browser facts")
    @MainActor
    func capturedFolderAndPolicySurviveEditorChanges() async throws {
        let folder = URL(fileURLWithPath: "/virtual/pending-capture")
        let first = folder.appendingPathComponent("a.jpg")
        let raw = folder.appendingPathComponent("z.ARW")
        let discovery = PendingWriteCallerDiscovery(.init(records: [first: record(first), raw: record(raw)], failures: []))
        let executor = PendingWriteCallerExecutor(pausedNames: ["a.jpg"], outcomes: ["z.ARW": .failed])
        let model = model(discovery: discovery, executor: executor)
        model.currentFolderURL = folder
        model.selectedURLs = [first]
        model.editingMetadata = IPTCMetadata(title: "Original editor")
        model.writeAllPendingChanges(in: folder, images: [], skipC2PA: false)
        try await waitForPause(executor, name: "a.jpg")
        await discovery.replace(.init(records: [raw: record(raw, title: "Newer independent record")], failures: []))
        let other = URL(fileURLWithPath: "/virtual/other-folder/other.jpg")
        model.currentFolderURL = other.deletingLastPathComponent()
        model.selectedURLs = [other]
        model.editingMetadata = IPTCMetadata(title: "Current editor must remain")
        model.saveError = "Current editor message"
        await executor.resume("a.jpg")
        await model.waitForPendingMetadataWriteBatch()
        let requests = await executor.requests
        #expect(requests.map(\.imageURL) == [first, raw])
        #expect(requests.allSatisfy { $0.folderURL == folder && !$0.skipC2PA })
        #expect(requests.last?.expectedSidecar.metadata.title == "Captured pending headline")
        #expect(Set(requests.map(\.id)).count == 2)
        #expect(model.editingMetadata.title == "Current editor must remain")
        #expect(model.saveError == "Current editor message")
        #expect(model.pendingWriteBatchOutcome?.folderURL == folder)
        #expect(model.pendingWriteBatchOutcome?.failedCount == 1)
        // ContentView observes this immutable attention payload independently of saveError,
        // and its persistent toolbar action can reopen it after the user changes folders.
        let attention = try #require(model.pendingWriteBatchOutcome?.attention)
        #expect(attention.id == model.pendingWriteBatchOutcome?.requestID)
        #expect(attention.title.contains(folder.lastPathComponent))
        #expect(attention.message.contains(folder.path))
        #expect(attention.message.contains(raw.path))
        #expect(attention.message.contains("Injected pending-write failure"))
        #expect(model.saveError == "Current editor message")
        #expect(!model.isProcessingFolder)
    }

    @Test("An obsolete Write All completion cannot clear a replacement batch's busy state or results")
    @MainActor
    func replacementBatchOwnsPublication() async throws {
        let folder = URL(fileURLWithPath: "/virtual/pending-replacement")
        let first = folder.appendingPathComponent("first.jpg")
        let second = folder.appendingPathComponent("second.jpg")
        let discovery = PendingWriteCallerDiscovery(.init(records: [first: record(first)], failures: []))
        let executor = PendingWriteCallerExecutor(pausedNames: ["first.jpg", "second.jpg"])
        let model = model(discovery: discovery, executor: executor)
        model.currentFolderURL = folder
        model.writeAllPendingChanges(in: folder, images: [])
        try await waitForPause(executor, name: "first.jpg")
        await discovery.replace(.init(records: [second: record(second)], failures: []))
        model.writeAllPendingChanges(in: folder, images: [])
        try await waitForPause(executor, name: "second.jpg")
        await executor.resume("first.jpg")
        // Yield to the obsolete task's completion while the new task is still held.
        for _ in 0..<10 { await Task.yield() }
        #expect(model.isProcessingFolder)
        #expect(model.pendingWriteBatchOutcome == nil)
        await executor.resume("second.jpg")
        await model.waitForPendingMetadataWriteBatch()
        #expect(model.pendingWriteBatchOutcome?.results.map(\.imageURL) == [second])
        #expect(model.pendingWriteBatchOutcome?.attention == nil)
        #expect(!model.isProcessingFolder)
    }

    @Test("Cancelled discovery never claims the discovered subset is the whole pending folder")
    @MainActor
    func cancelledDiscoveryLeavesUnknownRemainder() async throws {
        let folder = URL(fileURLWithPath: "/virtual/pending-discovery-cancel")
        let photo = folder.appendingPathComponent("known.jpg")
        let discovery = PendingWriteCallerDiscovery(.init(records: [photo: record(photo)], failures: [], wasCancelled: true))
        let executor = PendingWriteCallerExecutor()
        let model = model(discovery: discovery, executor: executor)
        model.currentFolderURL = folder
        model.writeAllPendingChanges(in: folder, images: [])
        await model.waitForPendingMetadataWriteBatch()
        #expect(await executor.requests.isEmpty)
        let outcome = try #require(model.pendingWriteBatchOutcome)
        #expect(outcome.discoveryWasCancelled)
        #expect(outcome.unattemptedURLs == [photo])
        #expect(outcome.attentionMessage?.contains("additional pending photos may remain unverified") == true)
        #expect(!model.isProcessingFolder)
    }

    @Test("A missing fresh metadata/credential read retains pending JSON even when Browser says unprotected")
    @MainActor
    func failedFreshFactsRetainPendingRecord() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PendingFacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("unreadable.png")
        try Data("Not a parseable image".utf8).write(to: photo)
        let sidecars = MetadataSidecarService()
        try sidecars.saveSidecar(record(photo), for: photo, in: folder)
        let json = folder.appendingPathComponent(".photo_metadata/unreadable.png.meta.json")
        let originalJSON = try Data(contentsOf: json)
        let originalImage = try Data(contentsOf: photo)
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.currentFolderURL = folder
        model.selectedURLs = [photo]
        model.writeAllPendingChanges(in: folder, images: [ImageFile(url: photo)], skipC2PA: false)
        await model.waitForPendingMetadataWriteBatch()
        let result = try #require(model.pendingWriteBatchOutcome?.results.first)
        #expect(!result.completed)
        #expect(result.failure?.contains("content-credential status") == true)
        #expect(!result.didWriteEmbedded && !result.didWriteXMP)
        #expect(try Data(contentsOf: json) == originalJSON)
        #expect(try Data(contentsOf: photo) == originalImage)
        #expect(sidecars.loadSidecar(for: photo, in: folder)?.pendingChanges == true)
        #expect(model.saveError != nil)
    }
}
