import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Browser XMP sidecar filesystem boundary")
struct BrowserXMPSidecarLoadServiceTests {
    @Test("a complete immutable batch is read serially away from MainActor")
    @MainActor
    func completeBatchRunsOffMainActor() async {
        let urls = [
            URL(fileURLWithPath: "/virtual/one.raw"),
            URL(fileURLWithPath: "/virtual/two.raw"),
            URL(fileURLWithPath: "/virtual/three.raw")
        ]
        let requestID = UUID()
        let firstData = Data("first".utf8)
        let thirdData = Data("third".utf8)
        let probe = BrowserXMPSidecarAccessProbe(dataByURL: [
            urls[0]: firstData,
            urls[2]: thirdData
        ])
        let service = BrowserXMPSidecarLoadService(access: .init(read: probe.read))

        let result = await Task {
            await service.load(imageURLs: urls, requestID: requestID)
        }.value

        #expect(result == .complete(BrowserXMPSidecarBatchSnapshot(
            requestID: requestID,
            requestedURLs: urls,
            processedURLs: urls,
            dataByImageURL: [urls[0]: firstData, urls[2]: thirdData]
        )))
        #expect(probe.readURLs == urls)
        #expect(!probe.ranOnMainThread)
    }

    @Test("pre-cancellation performs no sidecar reads")
    func preCancellation() async {
        let urls = [URL(fileURLWithPath: "/virtual/cancelled.raw")]
        let requestID = UUID()
        let probe = BrowserXMPSidecarAccessProbe(dataByURL: [:])
        let service = BrowserXMPSidecarLoadService(access: .init(read: probe.read))
        let task = Task {
            await Task.yield()
            return await service.load(imageURLs: urls, requestID: requestID)
        }
        task.cancel()

        #expect(await task.value == .cancelledBeforeRead(
            requestID: requestID,
            requestedURLs: urls
        ))
        #expect(probe.readURLs.isEmpty)
    }

    @Test("cancellation during a batch returns the exact processed prefix")
    func partialCancellation() async {
        let urls = [
            URL(fileURLWithPath: "/virtual/one.raw"),
            URL(fileURLWithPath: "/virtual/two.raw"),
            URL(fileURLWithPath: "/virtual/three.raw")
        ]
        let requestID = UUID()
        let data = Data("sidecar".utf8)
        let probe = BrowserXMPSidecarAccessProbe(
            dataByURL: [urls[0]: data, urls[1]: data],
            cancelAtInvocation: 2
        )
        let service = BrowserXMPSidecarLoadService(access: .init(read: probe.read))

        let result = await Task {
            await service.load(imageURLs: urls, requestID: requestID)
        }.value
        let expected = BrowserXMPSidecarBatchSnapshot(
            requestID: requestID,
            requestedURLs: urls,
            processedURLs: Array(urls.prefix(2)),
            dataByImageURL: [urls[0]: data, urls[1]: data]
        )

        #expect(result == .cancelledAfterPartialRead(expected))
        #expect(probe.readURLs == Array(urls.prefix(2)))
        #expect(!expected.isComplete)
    }

    @Test("cancellation after the final non-preemptible read preserves complete evidence")
    func cancellationAfterCompleteRead() async {
        let url = URL(fileURLWithPath: "/virtual/final.raw")
        let requestID = UUID()
        let data = Data("complete".utf8)
        let probe = BrowserXMPSidecarAccessProbe(
            dataByURL: [url: data],
            cancelAtInvocation: 1
        )
        let service = BrowserXMPSidecarLoadService(access: .init(read: probe.read))

        let result = await Task {
            await service.load(imageURLs: [url], requestID: requestID)
        }.value
        let expected = BrowserXMPSidecarBatchSnapshot(
            requestID: requestID,
            requestedURLs: [url],
            processedURLs: [url],
            dataByImageURL: [url: data]
        )

        #expect(result == .cancelledAfterCompleteRead(expected))
        #expect(expected.isComplete)
    }

    @Test("Browser metadata awaits the actor and rejects stale batch publication")
    func browserViewModelSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/BrowserViewModel.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func loadBasicMetadata("))
        let functionEnd = try #require(source.range(
            of: "private nonisolated static func parseXMPSidecarMetadataBatch(",
            range: functionStart.lowerBound..<source.endIndex
        ))
        let functionSource = String(source[functionStart.lowerBound..<functionEnd.lowerBound])

        #expect(functionSource.contains("async let xmpDataLoad = xmpSidecarLoadService.load("))
        #expect(functionSource.contains("metadataLoadRequestID == requestID"))
        #expect(functionSource.contains("currentFolderURL == folderURL"))
        #expect(functionSource.contains("case .complete(let xmpSnapshot) = xmpLoadResult"))
        #expect(!functionSource.contains("sidecarDataIfExists"))
        #expect(!source.contains("private func loadXMPSidecarDataBatch"))
    }
}

private nonisolated final class BrowserXMPSidecarAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let dataByURL: [URL: Data]
    private let cancelAtInvocation: Int?
    private var urls: [URL] = []
    private var observedMainThread = false

    init(dataByURL: [URL: Data], cancelAtInvocation: Int? = nil) {
        self.dataByURL = dataByURL
        self.cancelAtInvocation = cancelAtInvocation
    }

    func read(imageURL: URL) -> Data? {
        let shouldCancel = lock.withLock {
            urls.append(imageURL)
            observedMainThread = observedMainThread || Thread.isMainThread
            return urls.count == cancelAtInvocation
        }
        if shouldCancel {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return dataByURL[imageURL]
    }

    var readURLs: [URL] { lock.withLock { urls } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}
