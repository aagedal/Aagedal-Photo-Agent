import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Render Dispatch workers")
struct RenderExecutorTests {
    @Test("Scope rendering preserves caller context and rejects cancelled pixels", arguments: [false, true])
    @MainActor
    func scopeRender(cancel: Bool) async throws {
        let queue = DispatchSerialQueue(label: "test.scope.render")
        let marker = UUID()
        let image = try makeImage()
        let worker = ScopeRenderWorker(renderer: { request, source in
            RenderWorkerContext.check(queue, marker)
            #expect(request.mode == .waveform)
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return source
        }, renderQueue: queue)
        let result = await Task(priority: .userInitiated) {
            await RenderWorkerContext.$marker.withValue(marker) {
                await worker.render(ScopeRenderRequest(mode: .waveform), from: image)
            }
        }.value
        #expect((result == nil) == cancel)
        if !cancel { #expect(result === image) }
    }

    @Test("A pre-cancelled scope does no raster work")
    @MainActor
    func cancelledScopeSkipsRenderer() async throws {
        let worker = ScopeRenderWorker(renderer: { _, _ in
            Issue.record("Cancelled scope reached its rasterizer")
            return nil
        })
        let image = try makeImage()
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await worker.render(ScopeRenderRequest(mode: .waveform), from: image)
        }.value
        #expect(result == nil)
    }

    @Test("Clean Feed resumes on Dispatch with task context after suspension", arguments: [false, true])
    @MainActor
    func cleanFeed(cancel: Bool) async {
        let queue = DispatchSerialQueue(label: "test.clean-feed.render")
        let marker = UUID()
        let service = CleanFeedBrowseRenderService(renderer: { _ in
            RenderWorkerContext.check(queue, marker)
            await Task.yield()
            RenderWorkerContext.check(queue, marker)
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8))
        }, renderQueue: queue)
        let request = CleanFeedBrowseRenderRequest(
            requestID: marker, imageURL: URL(fileURLWithPath: "/virtual/feed.jpg"),
            settings: nil, displayOrientation: 1, maxPixelSize: 128
        )
        let result = await Task(priority: .userInitiated) {
            await RenderWorkerContext.$marker.withValue(marker) {
                await service.render(request)
            }
        }.value
        #expect(result.requestID == marker)
        #expect(result.image != nil)
        #expect(result.completion == (cancel ? .cancelled(renderCompleted: true) : .complete))
    }

    @Test("Develop checks cancellation after the orientation probe before RAW decode")
    @MainActor
    func developOrientationCancellation() async {
        let queue = DispatchSerialQueue(label: "test.develop.orientation")
        let marker = UUID()
        let service = DevelopSourceDecodeService(rawDecoder: { _, _, _ in
            Issue.record("Cancelled orientation probe continued to RAW decode")
            return nil
        }, orientationReader: { _ in
            RenderWorkerContext.check(queue, marker)
            withUnsafeCurrentTask { $0?.cancel() }
            return 1
        }, renderQueue: queue)
        let result = await Task(priority: .userInitiated) {
            await RenderWorkerContext.$marker.withValue(marker) {
                await service.loadRAW(from: URL(fileURLWithPath: "/virtual/source.arw"),
                                      maxPixelSize: 128, targetOrientation: 1)
            }
        }.value
        #expect(result == nil)
    }

    @Test("Develop RAW decoding runs on Dispatch and rejects pixels after cancellation", arguments: [false, true])
    @MainActor
    func developDecode(cancel: Bool) async {
        let queue = DispatchSerialQueue(label: "test.develop.decode")
        let marker = UUID()
        let service = DevelopSourceDecodeService(rawDecoder: { _, _, _ in
            RenderWorkerContext.check(queue, marker)
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return FullScreenImageCache.RAWDecodeResult(
                image: CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8)),
                neutralTemperature: 6_500, neutralTint: 0
            )
        }, orientationReader: { _ in 1 }, renderQueue: queue)
        let result = await Task(priority: .userInitiated) {
            await RenderWorkerContext.$marker.withValue(marker) {
                await service.loadRAWPreviewSource(from: URL(fileURLWithPath: "/virtual/source.arw"),
                                                   maxPixelSize: 128)
            }
        }.value
        #expect((result == nil) == cancel)
    }

    @Test("Comparison source probing uses Dispatch and cancellation precedes revision access", arguments: [false, true])
    @MainActor
    func comparisonSourceProbe(liveEdit: Bool) async {
        let queue = DispatchSerialQueue(label: "test.comparison.source")
        let marker = UUID()
        let service = ComparisonRenderService(pixelSizeReader: { _ in
            RenderWorkerContext.check(queue, marker)
            withUnsafeCurrentTask { $0?.cancel() }
            return CGSize(width: 16, height: 8)
        }, renderQueue: queue)
        let source = ImageFile(url: URL(fileURLWithPath: "/virtual/missing-comparison.jpg"))
        do {
            _ = try await Task(priority: .userInitiated) {
                try await RenderWorkerContext.$marker.withValue(marker) {
                    if liveEdit {
                        return try await service.renderLiveEdit(
                            imageFile: source,
                            sourceImage: CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8)),
                            settings: nil, renderToken: "test", maxPixelSize: 128
                        )
                    }
                    return try await service.render(imageFile: source, settings: nil,
                                                    cache: FullScreenImageCache(), maxPixelSize: 128)
                }
            }.value
            Issue.record("Cancelled comparison unexpectedly rendered")
        } catch is CancellationError {
            // Cancellation must win before the nonexistent file's revision is read.
        } catch {
            Issue.record("Expected cancellation, received \(error)")
        }
    }

    @Test("Edited preview entry retains the caller task on Dispatch before decode")
    @MainActor
    func editedPreviewEntry() async {
        let queue = DispatchSerialQueue(label: "test.edited-preview.source")
        let marker = UUID()
        let worker = EditedPreviewRenderWorker(orientationReader: { _ in
            RenderWorkerContext.check(queue, marker)
            withUnsafeCurrentTask { $0?.cancel() }
            return 1
        }, renderQueue: queue)
        let result = await Task(priority: .userInitiated) {
            await RenderWorkerContext.$marker.withValue(marker) {
                await FullScreenImageCache.decodedEditedPreview(
                    for: URL(fileURLWithPath: "/virtual/missing-preview.jpg"), settings: nil,
                    orientation: 1, screenMaxPx: 128, isolation: worker
                )
            }
        }.value
        #expect(result == nil)
    }

    @Test("Presentation header and sidecar reads preserve context and cancellation", arguments: [false, true])
    @MainActor
    func presentationFacts(cancel: Bool) async {
        let queue = DispatchSerialQueue(label: "test.presentation.facts")
        let marker = UUID()
        let url = URL(fileURLWithPath: "/virtual/presentation.jpg")
        let service = FullScreenImagePresentationFactsService(access: .init { _ in
            RenderWorkerContext.check(queue, marker)
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return .init(sidecarCameraRaw: nil, sidecarOrientation: 6, fileOrientation: 1,
                         pixelWidth: 16, pixelHeight: 8)
        }, filesystemQueue: queue)
        let result = await Task(priority: .userInitiated) {
            await RenderWorkerContext.$marker.withValue(marker) {
                await service.load(imageURL: url, requestID: marker)
            }
        }.value
        if cancel {
            #expect(result == .cancelledAfterRead(requestID: marker, imageURL: url))
        } else {
            #expect(result == .loaded(.init(
                requestID: marker, imageURL: url, sidecarCameraRaw: nil,
                sidecarOrientation: 6, fileOrientation: 1, pixelWidth: 16, pixelHeight: 8
            )))
        }
    }

    private func makeImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }
}

private nonisolated enum RenderWorkerContext {
    @TaskLocal static var marker: UUID?

    static func check(_ queue: DispatchSerialQueue, _ expectedMarker: UUID) {
        #expect(queue.isIsolatingCurrentContext() == true)
        #expect(!Thread.isMainThread)
        #expect(marker == expectedMarker)
        #expect(Task.currentPriority >= .userInitiated)
    }
}
