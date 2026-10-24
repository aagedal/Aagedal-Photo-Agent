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
        #expect(thirtyTwoGiB.totalBudget == 4_096 * mebibyte)
        #expect(sumOfCacheLimits(fourGiB) == fourGiB.totalBudget)
        #expect(sumOfCacheLimits(thirtyTwoGiB) == thirtyTwoGiB.totalBudget)
    }

    @Test("the budget ceiling scales with RAM between 1 and 4 GiB; 8 GB Macs are unchanged")
    func budgetCeilingScalesWithPhysicalMemory() {
        func total(_ gibibytes: UInt64) -> Int {
            ImageMemoryCoordinator(
                availableMemory: { gibibytes * 1_024 * 1_024 * 1_024 },
                observesSystemPressure: false
            ).policy().totalBudget
        }
        #expect(total(8) == 1_024 * mebibyte)
        #expect(total(16) == 2_048 * mebibyte)
        #expect(total(32) == 4_096 * mebibyte)
        #expect(total(64) == 4_096 * mebibyte)
        #expect(total(128) == ImageMemoryCoordinator.maximumTotalBudget)
    }

    @Test("full-screen estimates use a 3:2 photo, not a square, so 6K screens keep their full share")
    func fullScreenEstimateUsesPhotoAspect() {
        let estimate = FullScreenImageCache.estimatedScreenImageSize(screenMaxPx: 6_016)
        #expect(estimate.width == 6_016)
        #expect(estimate.height == (6_016.0 * 2 / 3).rounded(.up))

        // On an 8 GB Mac a square 6K estimate (two reserved images ≥ 1/2 of the budget)
        // halved the cache; the 3:2 estimate stays below that tier.
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        let base = coordinator.policy().fullScreenPrimaryLimit
        let square = coordinator.adaptiveLimit(
            for: .fullScreenPrimary,
            sourcePixelSize: CGSize(width: 6_016, height: 6_016),
            bytesPerPixel: 8
        )
        let photo = coordinator.adaptiveLimit(
            for: .fullScreenPrimary,
            sourcePixelSize: estimate,
            bytesPerPixel: 8
        )
        #expect(square == base / 2)
        #expect(photo == base)
    }

    @Test("pressure handlers outside the budget run at their tier without changing cache shares")
    func pressureHandlersRunByTier() {
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        let recorder = EventRecorder()
        let limits = IntegerRecorder()
        let cache = coordinator.register(
            kind: .fullScreenPreview,
            applyLimit: { limits.setFirst($0) },
            evict: { recorder.append("evict-cache") }
        )
        let warning = coordinator.registerPressureEviction(level: .warning) {
            recorder.append("warning-handler")
        }
        let critical = coordinator.registerPressureEviction(level: .critical) {
            recorder.append("critical-handler")
        }
        // Registering handlers must not split the fullScreenPreview share.
        #expect(limits.first == coordinator.policy().fullScreenPreviewLimit)

        coordinator.handleMemoryPressure(.warning)
        #expect(recorder.events == ["evict-cache", "warning-handler"])

        recorder.reset()
        coordinator.handleMemoryPressure(.critical)
        #expect(recorder.events == ["evict-cache", "warning-handler", "critical-handler"])

        recorder.reset()
        warning.cancel()
        critical.cancel()
        coordinator.handleMemoryPressure(.critical)
        #expect(recorder.events == ["evict-cache"])
        _ = cache
    }

    @Test("Caption's preview LRU is evicted on memory pressure")
    @MainActor
    func captionPreviewPipelineYieldsToPressure() async throws {
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        let image = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        let pipeline = CaptionPreviewPipeline(memoryCoordinator: coordinator) { _, _, _, _ in image }
        let request = CaptionPreviewPipeline.Request(
            url: URL(fileURLWithPath: "/tmp/caption-pressure.jpg"), orientation: 1,
            renderToken: nil, fileSize: nil, fileModified: nil, maxPixelSize: 1_024
        )
        _ = await pipeline.image(for: request, settings: nil)
        // The cache insert happens in a follow-up main-actor task.
        let insertDeadline = ContinuousClock.now + .seconds(2)
        while pipeline.cachedImage(for: request) == nil, ContinuousClock.now < insertDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(pipeline.cachedImage(for: request) != nil)

        coordinator.handleMemoryPressure(.warning)
        let deadline = ContinuousClock.now + .seconds(2)
        while pipeline.cachedImage(for: request) != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(pipeline.cachedImage(for: request) == nil)
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

    @Test("Sidecar and header reads and orientation pixels retain utility task context and stop on cancellation",
          arguments: 0...4)
    @MainActor
    func orientationContext(cancelAt: Int) async throws {
        let executor = FullScreenImageDecodeExecutor()
        let marker = UUID()
        let url = URL(fileURLWithPath: "/virtual/orientation.tiff")
        let image = NSImage(cgImage: try makeImage(), size: NSSize(width: 16, height: 8))
        let output = try makeImage(width: 8, height: 16)
        let worker = ThumbnailImageRenderWorker(sourceAccess: .init(
            sidecarOrientation: { actualURL in
                ThumbnailRenderContext.check(executor, marker)
                #expect(actualURL == url)
                #expect(cancelAt != 1)
                if cancelAt == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                return 6
            },
            fileOrientation: { actualURL in
                ThumbnailRenderContext.check(executor, marker)
                #expect(actualURL == url)
                #expect(cancelAt == 0 || cancelAt > 2)
                if cancelAt == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                return 1
            },
            materializeOrientation: { rotated in
                ThumbnailRenderContext.check(executor, marker)
                #expect(cancelAt == 0 || cancelAt == 4)
                #expect(rotated.extent.size == CGSize(width: 8, height: 16))
                if cancelAt == 4 { withUnsafeCurrentTask { $0?.cancel() } }
                return output
            }
        ), executor: executor)
        let result = await Task(priority: .userInitiated) {
            await ThumbnailRenderContext.$marker.withValue(marker) {
                if cancelAt == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                return await worker.orientedToSidecar(image, fileURL: url)
            }
        }.value
        #expect((result != nil) == (cancelAt == 0))
        if let result { #expect(result.size == NSSize(width: 8, height: 16)) }
    }

    @Test("Thumbnail cloud probes preserve context, defer placeholders and stop at cancelled boundaries",
          arguments: 0...4, [false, true])
    @MainActor
    func availabilityContext(cancelAt: Int, placeholder: Bool) async {
        let executor = FullScreenImageDecodeExecutor()
        let marker = UUID()
        let url = URL(fileURLWithPath: "/virtual/cloud.tiff")
        let worker = ThumbnailImageRenderWorker(sourceAccess: .init(
            isUbiquitous: { actualURL in
                ThumbnailRenderContext.check(executor, marker)
                #expect(actualURL == url)
                #expect(cancelAt != 1)
                if cancelAt == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                return true
            },
            isNotDownloaded: { actualURL in
                ThumbnailRenderContext.check(executor, marker)
                #expect(actualURL == url)
                #expect(cancelAt == 0 || cancelAt > 2)
                if cancelAt == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                return placeholder
            },
            startDownload: { actualURL in
                ThumbnailRenderContext.check(executor, marker)
                #expect(actualURL == url)
                #expect(placeholder)
                #expect(cancelAt == 0 || cancelAt == 4)
                if cancelAt == 4 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        ), executor: executor)
        let result = await Task(priority: .userInitiated) {
            await ThumbnailRenderContext.$marker.withValue(marker) {
                if cancelAt == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                return await worker.isLocallyAvailable(url)
            }
        }.value
        // A downloaded cloud file never reaches the download cancellation boundary.
        #expect(result == (!placeholder && (cancelAt == 0 || cancelAt == 4)))
    }

    @Test("Local thumbnails skip cloud status and download calls")
    func localAvailability() async {
        let worker = ThumbnailImageRenderWorker(sourceAccess: .init(
            isUbiquitous: { _ in false },
            isNotDownloaded: { _ in Issue.record("Local file queried cloud status"); return true },
            startDownload: { _ in Issue.record("Local file requested download") }
        ))
        #expect(await worker.isLocallyAvailable(URL(fileURLWithPath: "/virtual/local.tiff")))
    }

    @Test("A blocked cloud probe does not hold independent thumbnails and queued cancellation skips sidecar I/O")
    @MainActor
    func queuedSourceCancellation() async throws {
        let image = NSImage(cgImage: try makeImage(), size: NSSize(width: 16, height: 8))
        let url = URL(fileURLWithPath: "/virtual/blocked-cloud.tiff")
        let entered = AsyncStream<Void>.makeStream()
        let submitted = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let executor = FullScreenImageDecodeExecutor(didEnqueue: { submitted.continuation.yield(()) })
        let worker = ThumbnailImageRenderWorker(sourceAccess: .init(
            sidecarOrientation: { _ in Issue.record("Cancelled queued request read a sidecar"); return nil },
            isUbiquitous: { _ in
                entered.continuation.yield(())
                #expect(release.wait(timeout: .now() + 5) == .success)
                #expect(Task.isCancelled)
                return false
            }
        ), executor: executor)
        let first = Task { await worker.isLocallyAvailable(url) }
        var entries = entered.stream.makeAsyncIterator()
        _ = await entries.next()
        var submissions = submitted.stream.makeAsyncIterator()
        _ = await submissions.next()
        let queued = Task { await worker.orientedToSidecar(image, fileURL: url) }
        _ = await submissions.next()
        first.cancel()
        queued.cancel()
        let independent = ThumbnailImageRenderWorker(sourceAccess: .init(isUbiquitous: { _ in
            release.signal()
            return false
        }))
        #expect(await independent.isLocallyAvailable(url))
        #expect(await first.value == false)
        #expect(await queued.value == nil)
    }

    @Test("Orientation materialization failure preserves the original thumbnail")
    func failedOrientationMaterialization() async throws {
        let image = NSImage(cgImage: try makeImage(), size: NSSize(width: 16, height: 8))
        let worker = ThumbnailImageRenderWorker(sourceAccess: .init(
            sidecarOrientation: { _ in 6 }, fileOrientation: { _ in 1 },
            materializeOrientation: { _ in nil }
        ))
        #expect(await worker.orientedToSidecar(image, fileURL: URL(fileURLWithPath: "/virtual/fallback.tiff")) === image)
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

    @Test("Real sidecar orientation corrects a file-oriented thumbnail and preserves no-op identity",
          arguments: [0, 6, 3])
    func systemSidecarOrientation(sidecarOrientation: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sidecar.tiff")
        let image = try makeImage(width: 600, height: 400)
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        if sidecarOrientation != 0 {
            let xml = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:tiff="http://ns.adobe.com/tiff/1.0/" tiff:Orientation="\(sidecarOrientation)"/>
            </rdf:RDF></x:xmpmeta>
            """
            try Data(xml.utf8).write(to: url.deletingPathExtension().appendingPathExtension("xmp"))
        }
        let worker = ThumbnailImageRenderWorker()
        #expect(await worker.isLocallyAvailable(url))
        let decoded = try #require(await worker.load(from: url, maxPixelSize: 480))
        let original = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
        let result = try #require(await worker.orientedToSidecar(original, fileURL: url))
        if sidecarOrientation == 3 {
            #expect(result.size == NSSize(width: 480, height: 320))
        } else {
            #expect(result === original)
            #expect(result.size == NSSize(width: 320, height: 480))
        }
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

@Suite("Thumbnail stale-request and folder-return invalidation")
@MainActor
struct ThumbnailRevisionInvalidationTests {
    @Test("A changed edit retires the gated old producer and renders current settings")
    func changedSettingsRetireInflightRender() async throws {
        let image = try makeThumbnailBitmap()
        let gate = AsyncStream<Void>.makeStream()
        let calls = ThumbnailRevisionLoadProbe()
        let service = ThumbnailService(memoryCoordinator: makeMemoryCoordinator(), originalThumbnailLoader: { _ in
            let index = calls.next()
            if index == 1 {
                for await _ in gate.stream { break }
            }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        })
        defer { gate.continuation.yield(()); gate.continuation.finish() }
        let url = URL(fileURLWithPath: "/virtual/edited-invalidation-\(UUID()).jpg")
        var oldSettings = CameraRawSettings()
        oldSettings.exposure2012 = -2
        var newSettings = CameraRawSettings()
        newSettings.exposure2012 = 1
        let old = Task { await service.renderEditedThumbnail(for: url, settings: oldSettings, exifOrientation: 1) }
        defer { old.cancel() }
        try await waitForThumbnail { calls.count > 0 }
        service.invalidateEditedThumbnail(for: url)
        let replacement = Task { await service.renderEditedThumbnail(for: url, settings: newSettings, exifOrientation: 1) }
        defer { replacement.cancel() }
        // Let both replacement admission and cancellation cleanup run before releasing old I/O.
        await Task.yield()
        gate.continuation.yield(())
        gate.continuation.finish()
        #expect(await old.value == nil)
        let actual = try #require(await replacement.value)
        let reference = ThumbnailService(memoryCoordinator: makeMemoryCoordinator(), originalThumbnailLoader: { _ in
            NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        })
        let expected = try #require(await reference.renderEditedThumbnail(for: url, settings: newSettings, exifOrientation: 1))
        #expect(try pixels(actual) == pixels(expected))
        #expect(service.thumbnail(for: url) === actual)
        #expect(service.hasEditedThumbnail(for: url))
    }

    @Test("Folder return invalidates only externally changed XMP while unchanged originals and edits stay cached",
          arguments: [false, true])
    func externalSidecarChangeAcrossFolderReturn(removesSidecar: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-return-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let changed = directory.appendingPathComponent("changed.jpg")
        let untouched = directory.appendingPathComponent("untouched.jpg")
        try Data("unchanged source pixels".utf8).write(to: changed)
        try Data("other unchanged pixels".utf8).write(to: untouched)
        var settings = CameraRawSettings()
        settings.exposure2012 = 0.5
        let sidecars = XMPSidecarService()
        try sidecars.saveCameraRawOnly(settings, orientation: 1, for: changed)
        let sidecarURL = sidecars.sidecarURL(for: changed)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)],
                                              ofItemAtPath: sidecarURL.path)
        let bitmap = try makeThumbnailBitmap()
        let service = ThumbnailService(memoryCoordinator: makeMemoryCoordinator(), originalThumbnailLoader: { _ in
            NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
        })
        let model = BrowserViewModel(thumbnailService: service)
        let before = ImageFile(url: changed)
        model.reconcileThumbnailCaches(against: [before, ImageFile(url: untouched)])
        _ = try #require(await service.loadThumbnail(for: changed))
        let unchangedOriginal = try #require(await service.loadThumbnail(for: untouched))
        _ = try #require(await service.renderEditedThumbnail(for: changed, settings: settings, exifOrientation: 1))
        let unchangedEdited = try #require(await service.renderEditedThumbnail(for: untouched, settings: settings, exifOrientation: 1))
        // Empty folder admission models leaving A for B without evicting A's reusable images.
        model.reconcileThumbnailCaches(against: [])
        if removesSidecar {
            try FileManager.default.removeItem(at: sidecarURL)
        } else {
            settings.exposure2012 = 2
            try sidecars.saveCameraRawOnly(settings, orientation: 6, for: changed)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)],
                                                  ofItemAtPath: sidecarURL.path)
        }
        let after = ImageFile(url: changed)
        #expect(before.fileSize == after.fileSize)
        #expect(before.dateModified == after.dateModified)
        #expect(before.sidecarModified != after.sidecarModified)
        model.reconcileThumbnailCaches(against: [after, ImageFile(url: untouched)])
        #expect(service.thumbnail(for: changed) == nil)
        #expect(!service.hasEditedThumbnail(for: changed))
        #expect(service.thumbnail(for: untouched, preferOriginal: true) === unchangedOriginal)
        #expect(service.thumbnail(for: untouched) === unchangedEdited)
        // An unchanged repeated admission must preserve already refreshed previews too.
        let refreshed = try #require(await service.loadThumbnail(for: changed))
        model.reconcileThumbnailCaches(against: [ImageFile(url: changed), ImageFile(url: untouched)])
        #expect(service.thumbnail(for: changed, preferOriginal: true) === refreshed)
    }

    private func makeMemoryCoordinator() -> ImageMemoryCoordinator {
        ImageMemoryCoordinator(availableMemory: { 8 * 1_024 * 1_024 * 1_024 }, observesSystemPressure: false)
    }

    private func makeThumbnailBitmap() throws -> CGImage {
        let image = CIImage(color: CIColor(red: 0.25, green: 0.35, blue: 0.45))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        return try #require(CIContext().createCGImage(image, from: image.extent))
    }

    private func pixels(_ image: NSImage) throws -> Data {
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return try #require(cg.dataProvider?.data) as Data
    }

    private func waitForThumbnail(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private nonisolated final class ThumbnailRevisionLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage = 0
    var count: Int { lock.withLock { countStorage } }
    func next() -> Int { lock.withLock { countStorage += 1; return countStorage } }
}

@Suite("Export output reservations")
@MainActor
struct ExportOutputReservationTests {
    @Test("Concurrent numbered contenders own distinct occupied paths")
    func concurrentNumberedReservations() async throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owners = (0..<24).map { _ in ExportOutputReservationOwner() }
        defer { withExtendedLifetime(owners) {} }
        let outputs = try await withThrowingTaskGroup(of: URL.self) { group in
            for owner in owners {
                group.addTask {
                    try owner.reserveOutput(for: fixture.source, in: fixture.output,
                        extension: "jpg", collisionPolicy: .appendNumber)
                }
            }
            var urls: [URL] = []
            for try await url in group { urls.append(url) }
            return urls
        }
        #expect(outputs.count == owners.count)
        #expect(Set(outputs).count == owners.count)
        #expect(outputs.contains(fixture.output.appendingPathComponent("photo.jpg")))
        #expect(outputs.contains(fixture.output.appendingPathComponent("photo 24.jpg")))
        for output in outputs { #expect(try Data(contentsOf: output).isEmpty) }
        #expect(try Data(contentsOf: fixture.source) == Data("source".utf8))
    }

    @Test("Replacement respects an active claim even after atomic encoding, then becomes available on release")
    func replacementClaimLifetime() throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var first: ExportOutputReservationOwner? = ExportOutputReservationOwner()
        let destination = try #require(first).reserveOutput(for: fixture.source, in: fixture.output,
            extension: "jpg", collisionPolicy: .replaceExisting)
        let encoded = Data("encoded pixels and metadata".utf8)
        try encoded.write(to: destination, options: .atomic)
        let second = ExportOutputReservationOwner()
        do {
            _ = try second.reserveOutput(for: fixture.source, in: fixture.output,
                extension: "jpg", collisionPolicy: .replaceExisting)
            Issue.record("An active output must not be replaced")
        } catch EditedImageRenderer.RenderError.destinationBusy { }
        first = nil
        let available = try second.reserveOutput(for: fixture.source, in: fixture.output,
            extension: "jpg", collisionPolicy: .replaceExisting)
        #expect(available == destination)
        #expect(try Data(contentsOf: destination) == encoded)
        withExtendedLifetime(second) {}
    }

    @Test("Directory aliases share admission without coupling distinct extensions")
    func aliasDirectoryAndExtensions() throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.root.appendingPathComponent("aliased-output")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.output)
        let first = ExportOutputReservationOwner()
        let second = ExportOutputReservationOwner()
        defer { withExtendedLifetime((first, second)) {} }
        _ = try first.reserveOutput(for: fixture.source, in: fixture.output,
            extension: "jpg", collisionPolicy: .replaceExisting)
        do {
            _ = try second.reserveOutput(for: fixture.source, in: alias,
                extension: "jpg", collisionPolicy: .replaceExisting)
            Issue.record("Alias spelling must share the active destination claim")
        } catch EditedImageRenderer.RenderError.destinationBusy { }
        let numbered = try second.reserveOutput(for: fixture.source, in: alias,
            extension: "jpg", collisionPolicy: .appendNumber)
        #expect(numbered.lastPathComponent == "photo 2.jpg")
        let sibling = try second.reserveOutput(for: fixture.source, in: alias,
            extension: "png", collisionPolicy: .replaceExisting)
        #expect(sibling.lastPathComponent == "photo.png")
    }

    @Test("Only the unchanged empty owned placeholder is removed after abandonment")
    func ownedPlaceholderCleanup() throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var owner: ExportOutputReservationOwner? = ExportOutputReservationOwner()
        let destination = try #require(owner).reserveOutput(for: fixture.source, in: fixture.output,
            extension: "jpg", collisionPolicy: .appendNumber)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        owner = nil
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let replacement = ExportOutputReservationOwner()
        #expect(try replacement.reserveOutput(for: fixture.source, in: fixture.output,
            extension: "jpg", collisionPolicy: .appendNumber) == destination)
        withExtendedLifetime(replacement) {}
    }

    @Test("Foreign replacement is retained even if it is empty", arguments: [false, true])
    func foreignReplacementPreserved(empty: Bool) throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var owner: ExportOutputReservationOwner? = ExportOutputReservationOwner()
        let destination = try #require(owner).reserveOutput(for: fixture.source, in: fixture.output,
            extension: "jpg", collisionPolicy: .appendNumber)
        try FileManager.default.removeItem(at: destination)
        let foreign = empty ? Data() : Data("foreign replacement".utf8)
        try foreign.write(to: destination, options: .withoutOverwriting)
        owner = nil
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: destination) == foreign)
    }

    @Test("Successfully written pixels survive release with in-place and atomic encoders", arguments: [false, true])
    func encodedPixelsRetained(atomic: Bool) throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var owner: ExportOutputReservationOwner? = ExportOutputReservationOwner()
        let destination = try #require(owner).reserveOutput(for: fixture.source, in: fixture.output,
            extension: "jpg", collisionPolicy: .appendNumber)
        let pixels = Data("rendered pixels".utf8)
        try pixels.write(to: destination, options: atomic ? .atomic : [])
        owner = nil
        #expect(try Data(contentsOf: destination) == pixels)
    }

    @Test("A blocked filesystem admission does not serialize unrelated destinations")
    func unrelatedDestinationProgress() async throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = ExportOutputFilesystemGate()
        let first = ExportOutputReservationOwner(beforeFilesystemAccess: { _ in probe.block() })
        let second = ExportOutputReservationOwner()
        defer { probe.release(); withExtendedLifetime((first, second)) {} }
        let blocked = Task.detached {
            try first.reserveOutput(for: fixture.source, in: fixture.output,
                extension: "jpg", collisionPolicy: .appendNumber)
        }
        defer { blocked.cancel() }
        let deadline = ContinuousClock.now + .seconds(8)
        while !probe.started {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(5))
        }
        let unrelated = try await Task.detached {
            try second.reserveOutput(for: fixture.source, in: fixture.output,
                extension: "png", collisionPolicy: .appendNumber)
        }.value
        #expect(unrelated.lastPathComponent == "photo.png")
        #expect(!probe.finished)
        probe.release()
        _ = try await blocked.value
        #expect(!probe.timedOut)
    }

    @Test("A failed creation releases its namespace claim for a later successful reservation")
    func failedCreationReleasesClaim() throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let missing = fixture.output.appendingPathComponent("not-created")
        let owner = ExportOutputReservationOwner()
        #expect(throws: (any Error).self) {
            _ = try owner.reserveOutput(for: fixture.source, in: missing,
                extension: "jpg", collisionPolicy: .replaceExisting)
        }
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let output = try owner.reserveOutput(for: fixture.source, in: missing,
            extension: "jpg", collisionPolicy: .replaceExisting)
        #expect(output.lastPathComponent == "photo.jpg")
        withExtendedLifetime(owner) {}
    }

    @Test("Atomic replacement of a final symlink keeps both pathname and target claims active")
    func atomicFinalSymlinkReplacement() throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = fixture.root.appendingPathComponent("independent-rendition.jpg")
        try Data("independent output".utf8).write(to: target)
        let destination = fixture.output.appendingPathComponent("photo.jpg")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        var first: ExportOutputReservationOwner? = ExportOutputReservationOwner()
        _ = try #require(first).reserveOutput(for: fixture.source, in: fixture.output,
            extension: "jpg", collisionPolicy: .replaceExisting)
        let encodedSibling = fixture.output.appendingPathComponent("encoded-temp.jpg")
        try Data("atomically encoded output".utf8).write(to: encodedSibling)
        try #require(Darwin.rename(encodedSibling.path, destination.path) == 0)
        let second = ExportOutputReservationOwner()
        do {
            _ = try second.reserveOutput(for: fixture.source, in: fixture.output,
                extension: "jpg", collisionPolicy: .replaceExisting)
            Issue.record("Atomic replacement must retain the original pathname claim")
        } catch EditedImageRenderer.RenderError.destinationBusy { }
        first = nil
        _ = try second.reserveOutput(for: fixture.source, in: fixture.output,
            extension: "jpg", collisionPolicy: .replaceExisting)
        #expect(try Data(contentsOf: target) == Data("independent output".utf8))
        withExtendedLifetime(second) {}
    }

    @Test("Hard-linked outputs share inode admission until the original owner releases",
          arguments: [false, true])
    func hardLinkedOutputAdmission(freshPlaceholder: Bool) throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.output.appendingPathComponent("photo.jpg")
        let alias = fixture.output.appendingPathComponent("photo-copy.jpg")
        let bytes = freshPlaceholder ? Data() : Data("independent existing output".utf8)
        if !freshPlaceholder {
            try bytes.write(to: destination)
            try FileManager.default.linkItem(at: destination, to: alias)
        }
        var first: ExportOutputReservationOwner? = ExportOutputReservationOwner()
        _ = try #require(first).reserveOutput(for: fixture.source, in: fixture.output,
            extension: "jpg", collisionPolicy: .replaceExisting)
        if freshPlaceholder { try FileManager.default.linkItem(at: destination, to: alias) }
        let second = ExportOutputReservationOwner()
        do {
            _ = try second.reserveOutput(for: fixture.source, in: fixture.output,
                extension: "jpg", filenameSuffix: "-copy", collisionPolicy: .replaceExisting)
            Issue.record("A distinct pathname must not bypass an active inode claim")
        } catch EditedImageRenderer.RenderError.destinationBusy { }
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try Data(contentsOf: alias) == bytes)
        first = nil
        let admitted = try second.reserveOutput(for: fixture.source, in: fixture.output,
            extension: "jpg", filenameSuffix: "-copy", collisionPolicy: .replaceExisting)
        #expect(admitted == alias)
        #expect(try Data(contentsOf: alias) == bytes)
        withExtendedLifetime(second) {}
    }

    @Test("Awaited cleanup keeps MainActor responsive and releases admission before returning")
    func asynchronousCleanupReleasesAdmission() async throws {
        let fixture = try workspace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = ExportOutputFilesystemGate()
        defer { gate.release() }
        let owner = ExportOutputReservationOwner(beforeCleanup: {
            #expect(!Thread.isMainThread)
            gate.block()
        })
        let destination = try owner.reserveOutput(for: fixture.source, in: fixture.output,
            extension: "jpg", collisionPolicy: .replaceExisting)
        let cleanup = Task { await owner.release() }
        let deadline = ContinuousClock.now + .seconds(8)
        while !gate.started {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(5))
        }
        // Reaching this MainActor continuation while the worker is gated proves that
        // cleanup does not block the UI executor. Its namespace lease is still active.
        #expect(!gate.finished)
        let replacement = ExportOutputReservationOwner()
        do {
            _ = try replacement.reserveOutput(for: fixture.source, in: fixture.output,
                extension: "jpg", collisionPolicy: .replaceExisting)
            Issue.record("Cleanup must retain admission until its filesystem work finishes")
        } catch EditedImageRenderer.RenderError.destinationBusy { }
        // Cleanup of an unrelated artifact must also proceed while the first is gated.
        let unrelated = ExportOutputReservationOwner()
        let sibling = try unrelated.reserveOutput(for: fixture.source, in: fixture.output,
            extension: "png", collisionPolicy: .replaceExisting)
        await unrelated.release()
        #expect(!FileManager.default.fileExists(atPath: sibling.path))
        #expect(!gate.finished)
        gate.release()
        await cleanup.value
        #expect(!gate.timedOut)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let available = try replacement.reserveOutput(for: fixture.source, in: fixture.output,
            extension: "jpg", collisionPolicy: .replaceExisting)
        #expect(available == destination)
        await replacement.release()
        await owner.release() // A drained owner is safe to release again.
    }

    private func workspace() throws -> (root: URL, source: URL, output: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("output-reservation-\(UUID())")
        let output = root.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("photo.jpg")
        try Data("source".utf8).write(to: source)
        return (root, source, output)
    }
}

private nonisolated final class ExportOutputFilesystemGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didStart = false
    private var didFinish = false
    private var didTimeOut = false
    var started: Bool { lock.withLock { didStart } }
    var finished: Bool { lock.withLock { didFinish } }
    var timedOut: Bool { lock.withLock { didTimeOut } }
    func block() {
        lock.withLock { didStart = true }
        let timeout = semaphore.wait(timeout: .now() + 10) != .success
        lock.withLock { didFinish = true; didTimeOut = timeout }
    }
    func release() { semaphore.signal() }
}

@Suite("Grid controller lifetime", .serialized)
@MainActor
struct GridControllerLifetimeTests {
    private func makeController(_ viewModel: BrowserViewModel) -> CollectionViewGridController {
        let controller = CollectionViewGridController(
            viewModel: viewModel,
            commandRouter: AppCommandRouter()
        )
        _ = controller.view // loadView + viewDidLoad start the observation loops
        return controller
    }

    /// Bounded wait that lets the main actor run cancelled observation tasks to completion.
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a grid dismantled by SwiftUI stops observing and deallocates")
    func dismantledGridDeallocates() async throws {
        let viewModel = BrowserViewModel()
        weak var weakController: CollectionViewGridController?
        autoreleasepool {
            let controller = makeController(viewModel)
            weakController = controller
            CollectionViewGridRepresentable.dismantleNSViewController(controller, coordinator: ())
            #expect(controller.isTornDown)
        }
        try await waitUntil { weakController == nil }
        #expect(weakController == nil)
    }

    @Test("a released grid deallocates even if it was never dismantled")
    func releasedGridDeallocates() async throws {
        let viewModel = BrowserViewModel()
        weak var weakController: CollectionViewGridController?
        autoreleasepool {
            weakController = makeController(viewModel)
        }
        // The loops hold only weak references across their suspension, so ARC can free the
        // controller and its deinit cancels them.
        try await waitUntil { weakController == nil }
        #expect(weakController == nil)
    }

    @Test("only the live grid applies updates and consumes the reveal request")
    func onlyLiveGridConsumesRevealRequest() async throws {
        let viewModel = BrowserViewModel()
        let originalShowOriginals = viewModel.showOriginalThumbnails
        defer { viewModel.showOriginalThumbnails = originalShowOriginals }

        let stale = makeController(viewModel)
        CollectionViewGridRepresentable.dismantleNSViewController(stale, coordinator: ())
        let staleApplies = stale.dataApplyCount
        let live = makeController(viewModel)
        let liveApplies = live.dataApplyCount
        // Let the observation tasks start and register their tracking before the change.
        try await Task.sleep(for: .milliseconds(100))

        viewModel.requestRevealActive()
        viewModel.showOriginalThumbnails.toggle()
        try await waitUntil { live.dataApplyCount > liveApplies }

        #expect(live.dataApplyCount > liveApplies)
        #expect(stale.dataApplyCount == staleApplies)
        // The live grid consumed the one-shot request; nothing is left for a later refresh.
        #expect(!viewModel.consumeRevealActiveRequest())
    }
}

@Suite("Lazy Clean Feed pipeline")
@MainActor
struct LazyCleanFeedPipelineTests {
    @Test("creating the controller builds no Metal pipeline until the feed is first needed")
    func pipelineIsCreatedOnFirstUse() {
        let factoryCalls = IntegerRecorder()
        let controller = CleanFeedController(makeFeedPipeline: {
            factoryCalls.setFirst(factoryCalls.first + 1)
            return nil
        })
        #expect(controller.feedPipeline == nil)
        #expect(factoryCalls.first == 0)

        // Tearing the Develop publication down never creates it.
        let publication = DevelopCleanFeedPublicationCoordinator()
        publication.endWorkspace(editorPipeline: nil, controller: controller)
        #expect(factoryCalls.first == 0)

        _ = controller.ensureFeedPipeline()
        _ = controller.ensureFeedPipeline()
        // Attempted once, even when the device cannot build one.
        #expect(factoryCalls.first == 1)
    }

    @Test("the production factory builds a live pipeline only on demand")
    func productionFactoryBuildsOnDemand() {
        let controller = CleanFeedController()
        #expect(controller.feedPipeline == nil)
        let pipeline = controller.ensureFeedPipeline()
        if MTLCreateSystemDefaultDevice() != nil {
            #expect(pipeline != nil)
            #expect(controller.feedPipeline === pipeline)
        }
    }
}
