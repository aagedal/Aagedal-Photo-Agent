import CoreGraphics
import CoreImage
import Darwin
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

@Suite("Metal offscreen task boundary")
struct MetalOffscreenRenderWorkerTests {
    @Test("Offscreen work retains caller context and discards cancelled renders", arguments: [false, true])
    @MainActor
    func renderContext(cancel: Bool) async {
        let queue = DispatchSerialQueue(label: "test.metal.offscreen.context")
        let worker = MetalOffscreenRenderWorker(renderQueue: queue)
        let marker = UUID()
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8))

        let result = await Task(priority: .userInitiated) {
            await RenderWorkerContext.$marker.withValue(marker) {
                await worker.render {
                    RenderWorkerContext.check(queue, marker)
                    if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                    return image
                }
            }
        }.value

        #expect((result == nil) == cancel)
        if !cancel { #expect(result === image) }
    }

    @Test("Queued and running cancellation share the synchronous offscreen queue")
    @MainActor
    func queuedAndRunningCancellation() async {
        let queue = DispatchSerialQueue(label: "test.metal.offscreen.cancellation")
        let worker = MetalOffscreenRenderWorker(renderQueue: queue)
        let entered = AsyncStream<Void>.makeStream()
        let submitted = AsyncStream<Void>.makeStream()
        let syncFinished = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8))
        let first = Task {
            await worker.render {
                entered.continuation.yield(())
                #expect(release.wait(timeout: .now() + 5) == .success)
                #expect(Task.isCancelled)
                return image
            }
        }
        var entries = entered.stream.makeAsyncIterator()
        _ = await entries.next()
        let second = Task {
            // This MainActor task submits its actor hop before the MainActor observer below
            // can resume, so cancellation happens after the request has been queued.
            submitted.continuation.yield(())
            return await worker.render {
                Issue.record("Cancelled queued request reached the Metal renderer")
                return image
            }
        }
        var submissions = submitted.stream.makeAsyncIterator()
        _ = await submissions.next()
        first.cancel()
        second.cancel()
        release.signal()
        #expect(await first.value == nil)
        #expect(await second.value == nil)

        // Compatibility callers use sync on the same underlying queue. The actor must
        // release that owner after cancellation, and a later request must still render.
        let sync = Task.detached {
            queue.sync {
                dispatchPrecondition(condition: .onQueue(queue))
                syncFinished.continuation.yield(())
            }
        }
        var completions = syncFinished.stream.makeAsyncIterator()
        _ = await completions.next()
        await sync.value
        let resumed = await worker.render { image }
        #expect(resumed === image)
    }

    @Test("Pre-cancelled offscreen work does not invoke the renderer")
    @MainActor
    func preCancellation() async {
        let worker = MetalOffscreenRenderWorker(
            renderQueue: DispatchSerialQueue(label: "test.metal.offscreen.pre-cancelled")
        )
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await worker.render {
                Issue.record("Pre-cancelled request reached the Metal renderer")
                return nil
            }
        }.value
        #expect(result == nil)
    }

    @Test("Cancelled Camera Raw requests leave input unchanged before fallback or crop", arguments: [false, true])
    @MainActor
    func cancelledCameraRawApproximation(crop: Bool) async {
        let input = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8))
        var settings = CameraRawSettings()
        settings.exposure2012 = 2
        settings.crop = CameraRawCrop(top: 0, left: 0, bottom: 0.5, right: 0.5, hasCrop: true)
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            if crop {
                return await CameraRawApproximation.applyWithCropAsync(to: input, settings: settings)
            }
            return await CameraRawApproximation.applyAsync(to: input, settings: settings)
        }.value
        #expect(result === input)
    }
}

@Suite("Embedded RAW decode task and QoS boundary")
struct EmbeddedRAWPreviewDecodeWorkerTests {
    @Test("Embedded extraction keeps caller context at default QoS and rejects cancelled pixels",
          arguments: [false, true])
    @MainActor
    func decodeContext(cancel: Bool) async throws {
        let executor = FullScreenImageDecodeExecutor(profile: .embeddedRAWPreview)
        let marker = UUID()
        let url = URL(fileURLWithPath: "/virtual/preview.arw")
        let image = try makeImage()
        let worker = EmbeddedRAWPreviewDecodeWorker(decoder: { actualURL in
            #expect(executor.isIsolatingCurrentContext() == true)
            #expect(!Thread.isMainThread)
            #expect(qos_class_self() == QOS_CLASS_DEFAULT)
            #expect(RenderWorkerContext.marker == marker)
            #expect(Task.currentPriority >= .userInitiated)
            #expect(actualURL == url)
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return (image, 6)
        }, executor: executor)

        let result = await Task(priority: .userInitiated) {
            await RenderWorkerContext.$marker.withValue(marker) {
                await FullScreenImageCache.extractEmbeddedPreviewOffPoolWithOrientation(from: url, worker: worker)
            }
        }.value
        #expect(result?.orientation == (cancel ? nil : 6))
        if !cancel { #expect(result?.image === image) }
    }

    @Test("Pre-cancelled embedded extraction never opens the source")
    @MainActor
    func preCancellation() async {
        let worker = EmbeddedRAWPreviewDecodeWorker(decoder: { _ in
            Issue.record("Cancelled embedded request reached ImageIO")
            return nil
        })
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await FullScreenImageCache.extractEmbeddedPreviewOffPoolWithOrientation(
                from: URL(fileURLWithPath: "/virtual/cancelled.arw"), worker: worker
            )
        }.value
        #expect(result == nil)
    }

    @Test("Independent embedded decodes progress while another source is blocked")
    @MainActor
    func independentDecodeConcurrency() async throws {
        let image = try makeImage()
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let firstWorker = EmbeddedRAWPreviewDecodeWorker(decoder: { _ in
            entered.continuation.yield(())
            #expect(release.wait(timeout: .now() + 5) == .success)
            return (image, 6)
        })
        let secondWorker = EmbeddedRAWPreviewDecodeWorker(decoder: { _ in
            release.signal()
            return (image, 8)
        })
        let url = URL(fileURLWithPath: "/virtual/concurrent.arw")
        let first = Task {
            await FullScreenImageCache.extractEmbeddedPreviewOffPoolWithOrientation(from: url, worker: firstWorker)
        }
        var entries = entered.stream.makeAsyncIterator()
        _ = await entries.next()
        let second = await FullScreenImageCache.extractEmbeddedPreviewOffPoolWithOrientation(
            from: url, worker: secondWorker
        )
        #expect(second?.orientation == 8)
        #expect(await first.value?.orientation == 6)
    }

    @Test("Embedded cancellation skips queued providers and discards a running decode")
    @MainActor
    func queuedAndRunningCancellation() async throws {
        let image = try makeImage()
        let entered = AsyncStream<Void>.makeStream()
        let queued = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let executor = FullScreenImageDecodeExecutor(
            profile: .embeddedRAWPreview, didEnqueue: { queued.continuation.yield(()) }
        )
        let firstURL = URL(fileURLWithPath: "/virtual/first.arw")
        let worker = EmbeddedRAWPreviewDecodeWorker(decoder: { url in
            guard url == firstURL else {
                Issue.record("Cancelled queued embedded decode opened its source")
                return nil
            }
            entered.continuation.yield(())
            #expect(release.wait(timeout: .now() + 5) == .success)
            #expect(Task.isCancelled)
            return (image, 6)
        }, executor: executor)
        let first = Task {
            await FullScreenImageCache.extractEmbeddedPreviewOffPoolWithOrientation(from: firstURL, worker: worker)
        }
        var entries = entered.stream.makeAsyncIterator()
        _ = await entries.next()
        var submissions = queued.stream.makeAsyncIterator()
        _ = await submissions.next()
        let second = Task {
            await FullScreenImageCache.extractEmbeddedPreviewOffPoolWithOrientation(
                from: URL(fileURLWithPath: "/virtual/cancelled.arw"), worker: worker
            )
        }
        _ = await submissions.next()
        first.cancel()
        second.cancel()
        release.signal()
        #expect(await second.value == nil)
        #expect(await first.value == nil)
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

@Suite("Full-screen decode task and QoS boundary")
struct FullScreenImageDecodeWorkerTests {
    nonisolated enum DecodeKind: CaseIterable, Sendable {
        case hdrPreview, hdrFullResolution, rasterPreview, rasterFullResolution

        var maxPixelSize: CGFloat? {
            switch self {
            case .hdrPreview, .rasterPreview: 128
            case .hdrFullResolution, .rasterFullResolution: nil
            }
        }
    }

    @Test("Decode keeps caller context at utility QoS and rejects cancelled pixels",
          arguments: DecodeKind.allCases, [false, true])
    @MainActor
    func decodeContext(kind: DecodeKind, cancel: Bool) async throws {
        let executor = FullScreenImageDecodeExecutor(label: "test.full-screen.decode")
        let marker = UUID()
        let url = URL(fileURLWithPath: "/virtual/preview.tiff")
        let image = try makeImage()
        let check: @Sendable (URL, CGFloat?) -> Void = { actualURL, maxPixelSize in
            #expect(executor.isIsolatingCurrentContext() == true)
            #expect(!Thread.isMainThread)
            #expect(qos_class_self() == QOS_CLASS_UTILITY)
            #expect(RenderWorkerContext.marker == marker)
            #expect(Task.currentPriority >= .userInitiated)
            #expect(actualURL == url)
            #expect(maxPixelSize == kind.maxPixelSize)
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let worker = FullScreenImageDecodeWorker(access: .init(
            hdr: { actualURL, maxPixelSize in
                check(actualURL, maxPixelSize)
                return (CIImage(cgImage: image), 6)
            },
            raster: { actualURL, maxPixelSize in
                check(actualURL, maxPixelSize)
                return (image, 6)
            }
        ), executor: executor)

        let orientation = await Task(priority: .userInitiated) {
            await RenderWorkerContext.$marker.withValue(marker) {
                await decode(kind, from: url, worker: worker)
            }
        }.value
        #expect(orientation == (cancel ? nil : 6))
    }

    @Test("Pre-cancelled decode never opens the source", arguments: DecodeKind.allCases)
    @MainActor
    func cancelledBeforeDecode(kind: DecodeKind) async {
        let worker = FullScreenImageDecodeWorker(access: .init(
            hdr: { _, _ in
                Issue.record("Cancelled request reached Core Image")
                return nil
            },
            raster: { _, _ in
                Issue.record("Cancelled request reached ImageIO")
                return nil
            }
        ))
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await decode(kind, from: URL(fileURLWithPath: "/virtual/cancelled.tiff"), worker: worker)
        }.value
        #expect(result == nil)
    }

    @Test("Independent default decode executors can progress while another decode is blocked")
    @MainActor
    func independentDecodeConcurrency() async throws {
        let image = try makeImage()
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let firstWorker = FullScreenImageDecodeWorker(access: .init(
            hdr: { _, _ in nil },
            raster: { _, _ in
                entered.continuation.yield(())
                #expect(release.wait(timeout: .now() + 5) == .success)
                return (image, 6)
            }
        ))
        let secondWorker = FullScreenImageDecodeWorker(access: .init(
            hdr: { _, _ in nil },
            raster: { _, _ in
                release.signal()
                return (image, 8)
            }
        ))
        let url = URL(fileURLWithPath: "/virtual/concurrent.tiff")
        let first = Task { await decode(.rasterPreview, from: url, worker: firstWorker) }
        var entries = entered.stream.makeAsyncIterator()
        _ = await entries.next()
        #expect(await decode(.rasterPreview, from: url, worker: secondWorker) == 8)
        #expect(await first.value == 6)
    }

    @Test("Cancellation while queued behind a decode skips the provider")
    @MainActor
    func queuedDecodeCancellation() async throws {
        let image = try makeImage()
        let entered = AsyncStream<Void>.makeStream()
        let queued = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let executor = FullScreenImageDecodeExecutor(didEnqueue: { queued.continuation.yield(()) })
        let firstURL = URL(fileURLWithPath: "/virtual/first.tiff")
        let worker = FullScreenImageDecodeWorker(access: .init(
            hdr: { _, _ in nil },
            raster: { url, _ in
                guard url == firstURL else {
                    Issue.record("Cancelled queued decode opened its source")
                    return nil
                }
                entered.continuation.yield(())
                #expect(release.wait(timeout: .now() + 5) == .success)
                return (image, 6)
            }
        ), executor: executor)
        let first = Task { await decode(.rasterPreview, from: firstURL, worker: worker) }
        var entries = entered.stream.makeAsyncIterator()
        _ = await entries.next()
        var submissions = queued.stream.makeAsyncIterator()
        _ = await submissions.next()
        let second = Task {
            await decode(.rasterPreview, from: URL(fileURLWithPath: "/virtual/cancelled.tiff"), worker: worker)
        }
        _ = await submissions.next()
        second.cancel()
        release.signal()
        #expect(await second.value == nil)
        #expect(await first.value == 6)
    }

    private func decode(_ kind: DecodeKind, from url: URL, worker: FullScreenImageDecodeWorker) async -> Int? {
        switch kind {
        case .hdrPreview:
            await FullScreenImageCache.loadHDRPreviewOffPoolWithOrientation(
                from: url, maxPixelSize: 128, worker: worker
            )?.orientation
        case .hdrFullResolution:
            await FullScreenImageCache.loadHDRFullResolutionOffPoolWithOrientation(
                from: url, worker: worker
            )?.orientation
        case .rasterPreview:
            await FullScreenImageCache.loadDownsampledOffPoolWithOrientation(
                from: url, maxPixelSize: 128, worker: worker
            )?.orientation
        case .rasterFullResolution:
            await FullScreenImageCache.loadFullResolutionOffPoolWithOrientation(
                from: url, worker: worker
            )?.orientation
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
