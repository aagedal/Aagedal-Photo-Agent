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

@Suite("Browser HDR classification filesystem boundary")
struct BrowserHDRClassificationServiceTests {
    @Test("a complete immutable batch is inspected serially away from MainActor")
    @MainActor
    func completeBatchRunsOffMainActor() async {
        let firstURLs = [
            URL(fileURLWithPath: "/virtual/one.jpg"),
            URL(fileURLWithPath: "/virtual/two.heic"),
            URL(fileURLWithPath: "/virtual/three.tiff")
        ]
        let secondURLs = [
            URL(fileURLWithPath: "/virtual/four.avif"),
            URL(fileURLWithPath: "/virtual/five.png")
        ]
        let firstRequestID = UUID()
        let secondRequestID = UUID()
        let probe = BrowserHDRClassificationAccessProbe(
            hdrURLs: [firstURLs[1], secondURLs[0]],
            inspectionDelay: 0.005
        )
        let service = BrowserHDRClassificationService(access: .init(isHDR: probe.isHDR))

        let results = await Task {
            async let first = service.classify(
                imageURLs: firstURLs,
                requestID: firstRequestID
            )
            async let second = service.classify(
                imageURLs: secondURLs,
                requestID: secondRequestID
            )
            return await (first, second)
        }.value

        #expect(results.0 == .complete(BrowserHDRClassificationSnapshot(
            requestID: firstRequestID,
            requestedURLs: firstURLs,
            inspectedURLs: firstURLs,
            isHDRByImageURL: [
                firstURLs[0]: false,
                firstURLs[1]: true,
                firstURLs[2]: false,
            ]
        )))
        #expect(results.1 == .complete(BrowserHDRClassificationSnapshot(
            requestID: secondRequestID,
            requestedURLs: secondURLs,
            inspectedURLs: secondURLs,
            isHDRByImageURL: [secondURLs[0]: true, secondURLs[1]: false]
        )))
        #expect(
            probe.inspectedURLs == firstURLs + secondURLs
                || probe.inspectedURLs == secondURLs + firstURLs
        )
        #expect(!probe.ranOnMainThread)
        #expect(probe.maximumConcurrentInspections == 1)
    }

    @Test("pre-cancellation performs no container inspection")
    func preCancellation() async {
        let urls = [URL(fileURLWithPath: "/virtual/cancelled.jpg")]
        let requestID = UUID()
        let probe = BrowserHDRClassificationAccessProbe(hdrURLs: [])
        let service = BrowserHDRClassificationService(access: .init(isHDR: probe.isHDR))
        let task = Task {
            await Task.yield()
            return await service.classify(imageURLs: urls, requestID: requestID)
        }
        task.cancel()

        #expect(await task.value == .cancelledBeforeRead(
            requestID: requestID,
            requestedURLs: urls
        ))
        #expect(probe.inspectedURLs.isEmpty)
    }

    @Test("cancellation after a synchronous inspection reports its exact prefix")
    func partialCancellation() async {
        let urls = [
            URL(fileURLWithPath: "/virtual/one.jpg"),
            URL(fileURLWithPath: "/virtual/two.heic"),
            URL(fileURLWithPath: "/virtual/three.tiff")
        ]
        let requestID = UUID()
        let probe = BrowserHDRClassificationAccessProbe(
            hdrURLs: [urls[0]],
            cancelAtInvocation: 2
        )
        let service = BrowserHDRClassificationService(access: .init(isHDR: probe.isHDR))

        let result = await Task {
            await service.classify(imageURLs: urls, requestID: requestID)
        }.value
        let expected = BrowserHDRClassificationSnapshot(
            requestID: requestID,
            requestedURLs: urls,
            inspectedURLs: Array(urls.prefix(2)),
            isHDRByImageURL: [urls[0]: true, urls[1]: false]
        )

        #expect(result == .cancelledAfterPartialRead(expected))
        #expect(probe.inspectedURLs == Array(urls.prefix(2)))
        #expect(!expected.isComplete)
    }

    @Test("Browser metadata awaits complete request-matched HDR evidence before publication")
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
        let mergeStart = try #require(source.range(of: "private func applyBatchMetadataResults("))
        let mergeSource = String(source[mergeStart.lowerBound..<source.endIndex])

        #expect(functionSource.contains("async let hdrClassification = hdrClassificationService.classify("))
        #expect(functionSource.contains("case .complete(let hdrSnapshot) = hdrClassificationResult"))
        #expect(functionSource.contains("hdrSnapshot.requestID == requestID"))
        #expect(functionSource.contains("hdrSnapshot.requestedURLs == batchURLs"))
        #expect(functionSource.contains("nativeHDRByURL: hdrSnapshot.isHDRByImageURL"))
        #expect(!mergeSource.contains("SupportedImageFormats.isHDR(url: sourceURL)"))
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

private nonisolated final class BrowserHDRClassificationAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let hdrURLs: Set<URL>
    private let cancelAtInvocation: Int?
    private let inspectionDelay: TimeInterval
    private var urls: [URL] = []
    private var observedMainThread = false
    private var activeInspections = 0
    private var maximumInspections = 0

    init(
        hdrURLs: Set<URL>,
        cancelAtInvocation: Int? = nil,
        inspectionDelay: TimeInterval = 0
    ) {
        self.hdrURLs = hdrURLs
        self.cancelAtInvocation = cancelAtInvocation
        self.inspectionDelay = inspectionDelay
    }

    func isHDR(imageURL: URL) -> Bool {
        let shouldCancel = lock.withLock {
            urls.append(imageURL)
            observedMainThread = observedMainThread || Thread.isMainThread
            activeInspections += 1
            maximumInspections = max(maximumInspections, activeInspections)
            return urls.count == cancelAtInvocation
        }
        defer {
            lock.withLock { activeInspections -= 1 }
        }
        if shouldCancel {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if inspectionDelay > 0 {
            Thread.sleep(forTimeInterval: inspectionDelay)
        }
        return hdrURLs.contains(imageURL)
    }

    var inspectedURLs: [URL] { lock.withLock { urls } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var maximumConcurrentInspections: Int { lock.withLock { maximumInspections } }
}
