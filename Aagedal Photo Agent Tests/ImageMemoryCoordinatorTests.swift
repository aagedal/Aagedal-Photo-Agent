import AppKit
import CoreImage
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import Aagedal_Photo_Agent

@Suite("Image memory coordinator")
struct ImageMemoryCoordinatorTests {
    private let mebibyte = 1_024 * 1_024

    @Test("cache shares stay within one hardware-scaled process budget")
    func sharedBudgetIsBoundedAndScaled() {
        let fourGiB = ImageMemoryCoordinator(
            availableMemory: { 4 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        ).policy()
        let thirtyTwoGiB = ImageMemoryCoordinator(
            availableMemory: { 32 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        ).policy()

        #expect(fourGiB.totalBudget == 512 * mebibyte)
        #expect(thirtyTwoGiB.totalBudget == 1_024 * mebibyte)
        #expect(sumOfCacheLimits(fourGiB) == fourGiB.totalBudget)
        #expect(sumOfCacheLimits(thirtyTwoGiB) == thirtyTwoGiB.totalBudget)
    }

    @Test("large full-resolution sources reduce limits and disable speculative GPU prefetch")
    func sourceDimensionsAdaptPolicy() {
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        let small = CGSize(width: 1_000, height: 1_000)
        let fortyEightMP = CGSize(width: 8_000, height: 6_000)

        let smallLimit = coordinator.adaptiveLimit(
            for: .developSpeculative,
            sourcePixelSize: small,
            bytesPerPixel: 8
        )
        let largeLimit = coordinator.adaptiveLimit(
            for: .developSpeculative,
            sourcePixelSize: fortyEightMP,
            bytesPerPixel: 8
        )
        let smallPrefetch = coordinator.prefetchItemLimit(
            for: .developSpeculative,
            sourcePixelSize: small,
            bytesPerPixel: 8,
            maximum: 2
        )
        let largePrefetch = coordinator.prefetchItemLimit(
            for: .developSpeculative,
            sourcePixelSize: fortyEightMP,
            bytesPerPixel: 8,
            maximum: 2
        )

        #expect(largeLimit < smallLimit)
        #expect(smallPrefetch == 2)
        #expect(largePrefetch == 0)
    }

    @Test("multiple caches of one kind divide rather than duplicate their share")
    func duplicateParticipantsDivideShare() {
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        let limits = IntegerRecorder()
        let first = coordinator.register(
            kind: .developSpeculative,
            applyLimit: { limits.setFirst($0) },
            evict: {}
        )
        let second = coordinator.register(
            kind: .developSpeculative,
            applyLimit: { limits.setSecond($0) },
            evict: {}
        )
        _ = [first, second]

        let share = coordinator.policy().developSpeculativeLimit
        #expect(limits.first == share / 2)
        #expect(limits.second == share / 2)
    }

    @Test("warning pressure cancels work before ordered low-cost eviction")
    func warningPressureOrder() throws {
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        let recorder = EventRecorder()
        let registrations = registerAllKinds(with: coordinator, recorder: recorder)
        _ = registrations
        recorder.reset()

        coordinator.handleMemoryPressure(.warning)
        let events = recorder.events
        let firstEviction = try #require(events.firstIndex(where: { $0.hasPrefix("evict-") }))

        #expect(events[..<firstEviction].allSatisfy { $0.hasPrefix("cancel-") })
        #expect(Array(events[firstEviction...]) == [
            "evict-developSpeculative",
            "evict-scope",
            "evict-fullScreenPreview",
        ])
    }

    @Test("critical pressure follows the complete documented eviction order")
    func criticalPressureOrder() throws {
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        let recorder = EventRecorder()
        let registrations = registerAllKinds(with: coordinator, recorder: recorder)
        _ = registrations
        recorder.reset()

        coordinator.handleMemoryPressure(.critical)
        let evictions = recorder.events.filter { $0.hasPrefix("evict-") }

        #expect(evictions == [
            "evict-developSpeculative",
            "evict-scope",
            "evict-fullScreenPreview",
            "evict-thumbnail",
            "evict-fullScreenPrimary",
        ])
    }

    @Test("thumbnail generation leaves MainActor before decoding")
    @MainActor
    func thumbnailGenerationRunsOffMainActor() async throws {
        let service = ThumbnailService(originalThumbnailLoader: { _ in
            Self.makeThumbnailAwayFromMainThread()
        })
        let url = URL(fileURLWithPath: "/virtual/off-main-thumbnail.jpg")

        let result = try #require(await service.loadThumbnail(for: url))
        #expect(service.thumbnail(for: url) === result)
    }

    nonisolated private static func makeThumbnailAwayFromMainThread() -> NSImage {
        #expect(!Thread.isMainThread)
        return NSImage(size: NSSize(width: 32, height: 32))
    }

    @Test("warning pressure cancels thumbnail producers before they can populate the cache")
    @MainActor
    func thumbnailPressureCancellation() async {
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        let probe = AsyncCancellationProbe()
        let service = ThumbnailService(
            memoryCoordinator: coordinator,
            originalThumbnailLoader: { _ in
                probe.recordStart()
                while !Task.isCancelled {
                    await Task.yield()
                }
                probe.recordCancellation()
                return NSImage(size: NSSize(width: 32, height: 32))
            }
        )
        let url = URL(fileURLWithPath: "/tmp/thumbnail-pressure-\(UUID().uuidString).jpg")
        let load = Task { await service.loadThumbnail(for: url) }

        while !probe.started {
            await Task.yield()
        }
        coordinator.handleMemoryPressure(.warning)

        #expect(await load.value == nil)
        #expect(probe.cancelled)
        #expect(service.thumbnail(for: url) == nil)
    }

    @Test("warning pressure suppresses Develop precache until the next foreground source")
    @MainActor
    func developPressureCancellation() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return
        }
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        guard let pipeline = MetalLivePreviewPipeline(
            device: device,
            commandQueue: commandQueue,
            imageMemoryCoordinator: coordinator
        ) else {
            return
        }
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let beforePressure = URL(fileURLWithPath: "/tmp/develop-precache-before.tiff")
        let suppressed = URL(fileURLWithPath: "/tmp/develop-precache-suppressed.tiff")
        let resumed = URL(fileURLWithPath: "/tmp/develop-precache-resumed.tiff")

        pipeline.uploadSourceImage(image)
        pipeline.precacheTexture(for: beforePressure, ciImage: image)
        #expect(pipeline.applyCachedTexture(for: beforePressure) != nil)

        pipeline.precacheTexture(for: beforePressure, ciImage: image)
        coordinator.handleMemoryPressure(.warning)
        #expect(pipeline.applyCachedTexture(for: beforePressure) == nil)

        pipeline.precacheTexture(for: suppressed, ciImage: image)
        #expect(pipeline.applyCachedTexture(for: suppressed) == nil)

        pipeline.uploadSourceImage(image)
        pipeline.precacheTexture(for: resumed, ciImage: image)
        #expect(pipeline.applyCachedTexture(for: resumed) != nil)
    }

    private func sumOfCacheLimits(_ policy: ImageMemoryCoordinator.Policy) -> Int {
        policy.fullScreenPrimaryLimit
            + policy.fullScreenPreviewLimit
            + policy.thumbnailLimit
            + policy.scopeLimit
            + policy.developSpeculativeLimit
    }

    private func registerAllKinds(
        with coordinator: ImageMemoryCoordinator,
        recorder: EventRecorder
    ) -> [ImageMemoryCoordinator.Registration] {
        ImageMemoryCoordinator.CacheKind.allCases.map { kind in
            coordinator.register(
                kind: kind,
                cancelSpeculativeWork: {
                    recorder.append("cancel-\(kind)")
                },
                applyLimit: { _ in },
                evict: {
                    recorder.append("evict-\(kind)")
                }
            )
        }
    }
}

nonisolated private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.withLock { storage }
    }

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }

    func reset() {
        lock.withLock { storage.removeAll() }
    }
}

nonisolated private final class IntegerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var firstStorage = 0
    private var secondStorage = 0

    var first: Int { lock.withLock { firstStorage } }
    var second: Int { lock.withLock { secondStorage } }

    func setFirst(_ value: Int) { lock.withLock { firstStorage = value } }
    func setSecond(_ value: Int) { lock.withLock { secondStorage = value } }
}

nonisolated private final class AsyncCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didCancel = false

    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }

    func recordStart() { lock.withLock { didStart = true } }
    func recordCancellation() { lock.withLock { didCancel = true } }
}

@Suite("Thumbnail image worker")
struct ThumbnailImageRenderWorkerTests {
    nonisolated enum CancellationPoint: CaseIterable, Sendable {
        case none, beforeRequest, duringProvider
    }

    nonisolated enum EditCancellationPoint: CaseIterable, Sendable {
        case none, beforeRequest, duringEdit, duringMaterialization
    }

    @Test("Thumbnail decode retains context at utility QoS and discards cancelled pixels",
          arguments: CancellationPoint.allCases)
    @MainActor
    func decodeContext(cancellation: CancellationPoint) async throws {
        let executor = FullScreenImageDecodeExecutor()
        let marker = UUID()
        let image = try makeImage()
        let url = URL(fileURLWithPath: "/virtual/thumbnail.tiff")
        let worker = ThumbnailImageRenderWorker(access: .init(
            decode: { actualURL, maxPixelSize in
                #expect(cancellation != .beforeRequest)
                ThumbnailRenderContext.check(executor, marker)
                #expect(actualURL == url)
                #expect(maxPixelSize == 480)
                if cancellation == .duringProvider { withUnsafeCurrentTask { $0?.cancel() } }
                return image
            },
            edit: { input, _, _ in input },
            materialize: { _ in nil }
        ), executor: executor)

        let result = await Task(priority: .userInitiated) {
            await ThumbnailRenderContext.$marker.withValue(marker) {
                if cancellation == .beforeRequest { withUnsafeCurrentTask { $0?.cancel() } }
                return await worker.load(from: url, maxPixelSize: 480)
            }
        }.value
        #expect((result != nil) == (cancellation == .none))
        if cancellation == .none { #expect(result === image) }
    }

    @Test("Edited thumbnail materialization resumes on utility Dispatch after suspension",
          arguments: EditCancellationPoint.allCases)
    @MainActor
    func editedMaterialization(cancellation: EditCancellationPoint) async throws {
        let executor = FullScreenImageDecodeExecutor()
        let marker = UUID()
        let image = try makeImage()
        var settings = CameraRawSettings()
        settings.exposure2012 = 1.25
        let worker = ThumbnailImageRenderWorker(access: .init(
            decode: { _, _ in nil },
            edit: { input, actualSettings, orientation in
                #expect(cancellation != .beforeRequest)
                #expect(ThumbnailRenderContext.marker == marker)
                #expect(Task.currentPriority >= .userInitiated)
                #expect(actualSettings.exposure2012 == 1.25)
                #expect(orientation == 6)
                await Task.yield()
                #expect(ThumbnailRenderContext.marker == marker)
                if cancellation == .duringEdit { withUnsafeCurrentTask { $0?.cancel() } }
                return input
            },
            materialize: { edited in
                #expect(cancellation != .beforeRequest && cancellation != .duringEdit)
                ThumbnailRenderContext.check(executor, marker)
                #expect(edited.extent.size == CGSize(width: 16, height: 8))
                if cancellation == .duringMaterialization { withUnsafeCurrentTask { $0?.cancel() } }
                return image
            }
        ), executor: executor)

        let result = await Task(priority: .userInitiated) {
            await ThumbnailRenderContext.$marker.withValue(marker) {
                if cancellation == .beforeRequest { withUnsafeCurrentTask { $0?.cancel() } }
                return await worker.renderEdited(cgImage: image, settings: settings, exifOrientation: 6)
            }
        }.value
        #expect((result != nil) == (cancellation == .none))
        if cancellation == .none { #expect(result === image) }
    }

    @Test("Independent thumbnail decodes progress while queued and active requests cancel")
    @MainActor
    func independentAndCancelledDecodes() async throws {
        let image = try makeImage()
        let firstURL = URL(fileURLWithPath: "/virtual/first-thumbnail.tiff")
        let entered = AsyncStream<Void>.makeStream()
        let submitted = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let executor = FullScreenImageDecodeExecutor(didEnqueue: { submitted.continuation.yield(()) })
        let worker = ThumbnailImageRenderWorker(access: .init(
            decode: { url, _ in
                guard url == firstURL else {
                    Issue.record("Cancelled queued thumbnail reached ImageIO")
                    return nil
                }
                entered.continuation.yield(())
                #expect(release.wait(timeout: .now() + 5) == .success)
                #expect(Task.isCancelled)
                return image
            },
            edit: { input, _, _ in input }, materialize: { _ in nil }
        ), executor: executor)
        let independent = ThumbnailImageRenderWorker(access: .init(
            decode: { _, _ in
                release.signal()
                return image
            },
            edit: { input, _, _ in input }, materialize: { _ in nil }
        ))
        let first = Task { await worker.load(from: firstURL, maxPixelSize: 480) }
        var entries = entered.stream.makeAsyncIterator()
        _ = await entries.next()
        var submissions = submitted.stream.makeAsyncIterator()
        _ = await submissions.next()
        let second = Task {
            await worker.load(from: URL(fileURLWithPath: "/virtual/cancelled-thumbnail.tiff"), maxPixelSize: 480)
        }
        _ = await submissions.next()
        first.cancel()
        second.cancel()
        #expect(await independent.load(from: firstURL, maxPixelSize: 480) === image)
        #expect(await first.value == nil)
        #expect(await second.value == nil)
    }

    @Test("System thumbnail worker preserves the strict size cap, orientation and SDR materialization")
    func systemDecodeAndMaterialization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oriented.tiff")
        let image = try makeImage(width: 600, height: 400)
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let worker = ThumbnailImageRenderWorker()
        let decoded = try #require(await worker.load(from: url, maxPixelSize: 480))
        #expect(decoded.width == 320)
        #expect(decoded.height == 480)
        let rendered = try #require(await worker.renderEdited(
            cgImage: decoded, settings: CameraRawSettings(), exifOrientation: 6
        ))
        #expect(rendered.width == 320)
        #expect(rendered.height == 480)
        #expect(rendered.bitsPerComponent == 8)
    }

    private func makeImage(width: Int = 16, height: Int = 8) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}

private nonisolated enum ThumbnailRenderContext {
    @TaskLocal static var marker: UUID?

    static func check(_ executor: FullScreenImageDecodeExecutor, _ expectedMarker: UUID) {
        #expect(executor.isIsolatingCurrentContext() == true)
        #expect(!Thread.isMainThread)
        #expect(qos_class_self() == QOS_CLASS_UTILITY)
        #expect(marker == expectedMarker)
        #expect(Task.currentPriority >= .userInitiated)
    }
}
