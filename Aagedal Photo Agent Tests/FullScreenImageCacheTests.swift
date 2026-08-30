import Testing
import AppKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Aagedal_Photo_Agent

@Suite("Full-screen image presentation filesystem boundary")
struct FullScreenImagePresentationFactsServiceTests {
    @Test("a complete immutable presentation snapshot is read away from MainActor")
    @MainActor
    func completeSnapshotRunsOffMainActor() async {
        let imageURL = URL(fileURLWithPath: "/virtual/presentation.raw")
        let requestID = UUID()
        var cameraRaw = CameraRawSettings()
        cameraRaw.exposure2012 = 1.25
        let expected = FullScreenImagePresentationFactsAccess.Snapshot(
            sidecarCameraRaw: cameraRaw,
            sidecarOrientation: 8,
            fileOrientation: 6,
            pixelWidth: 6_000,
            pixelHeight: 4_000
        )
        let probe = FullScreenImagePresentationFactsAccessProbe(snapshot: expected)
        let service = FullScreenImagePresentationFactsService(access: .init(read: probe.read))

        let result = await Task {
            await service.load(imageURL: imageURL, requestID: requestID)
        }.value

        #expect(result == .loaded(FullScreenImagePresentationFacts(
            requestID: requestID,
            imageURL: imageURL,
            sidecarCameraRaw: cameraRaw,
            sidecarOrientation: 8,
            fileOrientation: 6,
            pixelWidth: 6_000,
            pixelHeight: 4_000
        )))
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("pre-cancellation performs no synchronous presentation read")
    func preCancellation() async {
        let requestID = UUID()
        let probe = FullScreenImagePresentationFactsAccessProbe(snapshot: .empty)
        let service = FullScreenImagePresentationFactsService(access: .init(read: probe.read))
        let task = Task {
            await Task.yield()
            return await service.load(
                imageURL: URL(fileURLWithPath: "/virtual/cancelled.raw"),
                requestID: requestID
            )
        }
        task.cancel()

        #expect(await task.value == .cancelledBeforeRead(requestID: requestID))
        #expect(probe.invocationCount == 0)
    }

    @Test("cancellation during a non-preemptible presentation read is explicit")
    func cancellationAfterRead() async {
        let imageURL = URL(fileURLWithPath: "/virtual/slow.raw")
        let requestID = UUID()
        let service = FullScreenImagePresentationFactsService(access: .init { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .empty
        })

        let result = await Task {
            await service.load(imageURL: imageURL, requestID: requestID)
        }.value

        #expect(result == .cancelledAfterRead(requestID: requestID, imageURL: imageURL))
    }

    @Test("full-screen view awaits the service and rejects stale publication")
    func fullScreenViewSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/FullScreenImageView.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func loadImage() async"))
        let functionSource = String(source[functionStart.lowerBound...])

        #expect(functionSource.contains("await FullScreenImagePresentationFactsService.shared.load("))
        #expect(functionSource.contains("self.presentationFactsRequestID == presentationFactsRequestID"))
        #expect(functionSource.contains("renderGeneration == expectedGeneration"))
        #expect(!functionSource.contains("XMPSidecarService().loadSidecar(for: url)"))
        #expect(!functionSource.contains("CGImageSourceCreateWithURL(url as CFURL, nil)"))
    }
}

private extension FullScreenImagePresentationFactsAccess.Snapshot {
    nonisolated static let empty = Self(
        sidecarCameraRaw: nil,
        sidecarOrientation: nil,
        fileOrientation: nil,
        pixelWidth: nil,
        pixelHeight: nil
    )
}

private nonisolated final class FullScreenImagePresentationFactsAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: FullScreenImagePresentationFactsAccess.Snapshot
    private var count = 0
    private var observedMainThread = false

    init(snapshot: FullScreenImagePresentationFactsAccess.Snapshot) {
        self.snapshot = snapshot
    }

    func read(imageURL: URL) -> FullScreenImagePresentationFactsAccess.Snapshot {
        _ = imageURL
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return snapshot
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

@Suite("FullScreenImageCache")
struct FullScreenImageCacheTests {

    /// Writes a small solid-color PNG to a unique temp file and returns its URL.
    /// Caller is responsible for removing the parent directory.
    private func makeTempPNG(width: Int = 64, height: Int = 64) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = {
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return ctx.makeImage()
        }() else {
            throw CocoaError(.featureUnsupported)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsic-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sample.png")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Writes a two-image TIFF that ImageIO can decode through the same embedded-preview
    /// API used for RAW files, allowing the async boundary to be tested without a fixture.
    private func makeTempMultiImageTIFF() throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        func makeImage(width: Int, height: Int, red: CGFloat) throws -> CGImage {
            guard let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw CocoaError(.featureUnsupported) }
            context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else { throw CocoaError(.featureUnsupported) }
            return image
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsic-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sample.tiff")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 2, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, try makeImage(width: 64, height: 48, red: 0.2), nil)
        CGImageDestinationAddImage(destination, try makeImage(width: 32, height: 24, red: 0.8), nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Writes a non-square TIFF with an EXIF orientation tag so the same ImageIO path used by
    /// Pixel Analysis can be checked through all eight display transforms.
    private func makeTempOrientedTIFF(
        width: Int = 120,
        height: Int = 80,
        orientation: Int
    ) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.featureUnsupported)
        }
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 3, height: height / 2))
        guard let image = context.makeImage() else {
            throw CocoaError(.featureUnsupported)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsic-oriented-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("orientation-\(orientation).tiff")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    @Test("Async embedded preview extraction resumes with an image")
    func asyncEmbeddedPreviewExtraction() async throws {
        let url = try makeTempMultiImageTIFF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Match the foreground callers that originally triggered Thread Performance Checker.
        let result = await Task.detached(priority: .userInitiated) {
            await FullScreenImageCache.extractEmbeddedPreviewOffPoolWithOrientation(from: url)
        }.value

        #expect(result != nil)
        #expect(result?.image.width ?? 0 > 0)
        #expect(result?.image.height ?? 0 > 0)
        #expect(result?.orientation == 1)
    }

    @Test("Adaptive HDR expansion is limited to gain-map-capable containers")
    func adaptiveHDRExpansionRouting() {
        for ext in ["jpg", "jpeg", "heic", "heif"] {
            #expect(FullScreenImageCache.usesAdaptiveHDRExpansion(
                for: URL(fileURLWithPath: "/tmp/image.\(ext)")
            ))
        }
        for ext in ["tif", "tiff", "jxl", "png", "avif"] {
            #expect(!FullScreenImageCache.usesAdaptiveHDRExpansion(
                for: URL(fileURLWithPath: "/tmp/image.\(ext)")
            ))
        }
    }

    @Test("Returns nil when no prefetch is in flight for the URL")
    func noInFlightPrefetchReturnsNil() async {
        let cache = FullScreenImageCache()
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jpg")
        #expect(await cache.awaitPrefetchedImage(for: url) == nil)
    }

    @Test("Awaits an in-flight prefetch and returns the decoded image")
    func awaitsInFlightPrefetch() async throws {
        let cache = FullScreenImageCache()
        let url = try makeTempPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Index 1 with forward direction falls inside the prefetch-ahead window,
        // so startPrefetch registers (and begins) a decode task for `url`.
        let placeholder = URL(fileURLWithPath: "/tmp/placeholder-\(UUID().uuidString).jpg")
        cache.startPrefetch(
            currentIndex: 0,
            images: [placeholder, url],
            direction: .forward,
            screenMaxPx: 256
        )

        let image = await cache.awaitPrefetchedImage(for: url)
        #expect(image != nil)
        // Awaiting the prefetch leaves the image in the cache for instant reuse —
        // the foreground load avoids decoding it a second time.
        #expect(cache.cachedImage(for: url) != nil)
    }

    @Test("Suppressed prefetch is a no-op; un-suppressing restores it")
    func suppressedPrefetchIsNoOp() async throws {
        let cache = FullScreenImageCache()
        let url = try makeTempPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let placeholder = URL(fileURLWithPath: "/tmp/placeholder-\(UUID().uuidString).jpg")

        // While suppressed (as during develop editing), startPrefetch registers no task —
        // so its ImageIO XMP parsing can't race the editor's concurrent NSXML sidecar write.
        cache.setPrefetchSuppressed(true)
        #expect(cache.isPrefetchSuppressed)
        cache.startPrefetch(currentIndex: 0, images: [placeholder, url], direction: .forward, screenMaxPx: 256)
        #expect(await cache.awaitPrefetchedImage(for: url) == nil)
        #expect(cache.cachedImage(for: url) == nil)

        // Un-suppressing (returning to the browser) restores prefetching.
        cache.setPrefetchSuppressed(false)
        #expect(!cache.isPrefetchSuppressed)
        cache.startPrefetch(currentIndex: 0, images: [placeholder, url], direction: .forward, screenMaxPx: 256)
        #expect(await cache.awaitPrefetchedImage(for: url) != nil)
    }

    @Test("Edit-variant mismatch falls through to a fresh decode")
    func mismatchedEditVariantReturnsNil() async throws {
        let cache = FullScreenImageCache()
        let url = try makeTempPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Prefetch the unedited variant...
        let placeholder = URL(fileURLWithPath: "/tmp/placeholder-\(UUID().uuidString).jpg")
        cache.startPrefetch(
            currentIndex: 0,
            images: [placeholder, url],
            direction: .forward,
            screenMaxPx: 256,
            isEdited: false
        )

        // ...but ask for the edited variant: the in-flight task is awaited, yet the
        // edited cache stays empty, so the caller is told to decode itself.
        #expect(await cache.awaitPrefetchedImage(for: url, isEdited: true) == nil)
    }

    @Test("Orientation variants for the same URL prefetch independently")
    func orientationVariantsPrefetchIndependently() async throws {
        let cache = FullScreenImageCache()
        let url = try makeTempPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let placeholder = URL(fileURLWithPath: "/tmp/placeholder-\(UUID().uuidString).jpg")

        cache.startPrefetch(
            currentIndex: 0,
            images: [placeholder, url],
            direction: .forward,
            screenMaxPx: 256,
            orientationForURL: { _ in 1 }
        )
        cache.startPrefetch(
            currentIndex: 0,
            images: [placeholder, url],
            direction: .forward,
            screenMaxPx: 256,
            orientationForURL: { _ in 3 }
        )

        #expect(await cache.awaitPrefetchedImage(for: url, orientation: 1) != nil)
        #expect(await cache.awaitPrefetchedImage(for: url, orientation: 3) != nil)
        #expect(cache.cachedImage(for: url, orientation: 1) != nil)
        #expect(cache.cachedImage(for: url, orientation: 3) != nil)
    }

    @Test("Cropped previews preserve the requested output resolution")
    func croppedPreviewPreservesOutputResolution() async throws {
        let url = try makeTempPNG(width: 1024, height: 512)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var settings = CameraRawSettings()
        // This crop's longest edge is half the source's longest edge. A 256 px full-frame
        // decode would therefore leave a 128 px crop; the crop-aware path decodes at 512 px.
        settings.crop = CameraRawCrop(
            top: 0,
            left: 0.375,
            bottom: 1,
            right: 0.625,
            angle: 0,
            hasCrop: true
        )

        let image = await FullScreenImageCache.decodedEditedPreview(
            for: url,
            settings: settings,
            orientation: 1,
            screenMaxPx: 256
        )

        let result = try #require(image)
        #expect(max(result.width, result.height) >= 250)
    }

    @Test("Analysis preview decode bakes all EXIF orientations into display geometry")
    func analysisPreviewOrientationGeometry() throws {
        for orientation in 1...8 {
            let url = try makeTempOrientedTIFF(orientation: orientation)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            let decoded = try #require(
                FullScreenImageCache.loadDownsampledWithOrientation(
                    from: url,
                    maxPixelSize: 512
                )
            )
            let expectedSize = orientation >= 5
                ? (width: 80, height: 120)
                : (width: 120, height: 80)

            #expect(decoded.orientation == orientation)
            #expect(decoded.image.width == expectedSize.width)
            #expect(decoded.image.height == expectedSize.height)
        }
    }

    @Test("Cropped analysis previews stay renderable through every EXIF orientation")
    func croppedAnalysisPreviewsAcrossOrientations() async throws {
        var settings = CameraRawSettings()
        settings.crop = CameraRawCrop(
            top: 0.2,
            left: 0.25,
            bottom: 0.8,
            right: 0.75,
            angle: 3,
            hasCrop: true
        )

        for orientation in 1...8 {
            let url = try makeTempOrientedTIFF(orientation: orientation)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            let preview = try #require(
                await FullScreenImageCache.decodedEditedPreview(
                    for: url,
                    settings: settings,
                    orientation: orientation,
                    screenMaxPx: 256
                )
            )
            #expect(preview.width > 0)
            #expect(preview.height > 0)

            for mode in [
                AnalysisPixelViewMode.red,
                .luminance,
                .alpha,
                .edges,
                .compressionResidual
            ] {
                let derived = try #require(
                    AnalysisPixelViewRenderer.render(preview, mode: mode)
                )
                #expect(derived.width == preview.width)
                #expect(derived.height == preview.height)
            }
        }
    }

    @Test("Malformed sources fail closed across analysis preview loaders")
    func malformedAnalysisSourceFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsic-malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x40, 0x01]).write(
            to: url,
            options: .atomic
        )

        #expect(
            FullScreenImageCache.loadDownsampled(
                from: url,
                maxPixelSize: 256
            ) == nil
        )
        #expect(
            FullScreenImageCache.loadHDRPreview(
                from: url,
                maxPixelSize: 256
            ) == nil
        )
        #expect(
            await FullScreenImageCache.decodedEditedPreview(
                for: url,
                settings: nil,
                orientation: 1,
                screenMaxPx: 256
            ) == nil
        )
    }

    @Test("Thumbnail service source-decodes cropped non-RAW images")
    func thumbnailServiceSourceDecodesCroppedNonRAW() async throws {
        let url = try makeTempPNG(width: 1024, height: 512)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var settings = CameraRawSettings()
        settings.crop = CameraRawCrop(
            top: 0,
            left: 0.375,
            bottom: 1,
            right: 0.625,
            angle: 0,
            hasCrop: true
        )

        let thumbnail = await ThumbnailService().renderEditedThumbnail(
            for: url,
            settings: settings,
            exifOrientation: 1
        )
        let result = try #require(thumbnail?.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ))
        #expect(max(result.width, result.height) >= 470)
    }

    @Test("Crop-aware decode sizing handles rotated source axes and caps at native size")
    func cropAwareDecodeSizing() {
        var settings = CameraRawSettings()
        settings.crop = CameraRawCrop(
            top: 0.25,
            left: 0.4,
            bottom: 0.75,
            right: 0.6,
            angle: 0,
            hasCrop: true
        )

        let upright = FullScreenImageCache.cropAwareSourceMaxPixelSize(
            outputMaxPixelSize: 480,
            settings: settings,
            exifOrientation: 1,
            sourcePixelSize: CGSize(width: 6000, height: 4000)
        )
        let rotated = FullScreenImageCache.cropAwareSourceMaxPixelSize(
            outputMaxPixelSize: 480,
            settings: settings,
            exifOrientation: 6,
            sourcePixelSize: CGSize(width: 6000, height: 4000)
        )
        #expect(abs(upright - 1440) < 0.01)
        #expect(abs(rotated - upright) < 0.01)

        settings.crop = CameraRawCrop(
            top: 0.499,
            left: 0.499,
            bottom: 0.501,
            right: 0.501,
            angle: 0,
            hasCrop: true
        )
        let capped = FullScreenImageCache.cropAwareSourceMaxPixelSize(
            outputMaxPixelSize: 480,
            settings: settings,
            exifOrientation: 1,
            sourcePixelSize: CGSize(width: 6000, height: 4000)
        )
        #expect(capped == 6000)
    }

    @Test("Invalidating one URL preserves another URL's edited variants")
    func editedInvalidationIsScopedToURL() throws {
        let cache = FullScreenImageCache()
        let firstURL = URL(fileURLWithPath: "/tmp/first-\(UUID().uuidString).jpg")
        let secondURL = URL(fileURLWithPath: "/tmp/second-\(UUID().uuidString).jpg")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw CocoaError(.featureUnsupported)
        }

        cache.store(image, for: firstURL, orientation: 1, renderToken: "first", isEdited: true)
        cache.store(image, for: secondURL, orientation: 3, renderToken: "second", isEdited: true)
        cache.storeDisplayPreview(image, for: firstURL, orientation: 1, renderToken: "first", isEdited: true)
        cache.storeDisplayPreview(image, for: secondURL, orientation: 3, renderToken: "second", isEdited: true)

        cache.invalidateEditedImage(for: firstURL)

        #expect(cache.cachedImage(for: firstURL, orientation: 1, renderToken: "first", isEdited: true) == nil)
        #expect(cache.cachedDisplayPreview(for: firstURL, orientation: 1, renderToken: "first", isEdited: true) == nil)
        #expect(cache.cachedImage(for: secondURL, orientation: 3, renderToken: "second", isEdited: true) != nil)
        #expect(cache.cachedDisplayPreview(for: secondURL, orientation: 3, renderToken: "second", isEdited: true) != nil)
    }
}

@Suite("ThumbnailDecodeGate")
struct ThumbnailDecodeGateTests {
    @Test("Canceled waiters do not receive permits")
    func canceledWaiterDoesNotReceivePermit() async {
        let gate = ThumbnailDecodeGate(limit: 1)
        let firstPermit = await gate.acquire()
        #expect(firstPermit)

        let waiter = Task {
            await gate.acquire()
        }
        await Task.yield()
        waiter.cancel()

        let canceledPermit = await waiter.value
        #expect(!canceledPermit)

        await gate.release()
        let nextPermit = await gate.acquire()
        #expect(nextPermit)
        await gate.release()
    }

    @Test("Release skips canceled waiters and hands off to the next live waiter")
    func releaseSkipsCanceledWaiter() async {
        let gate = ThumbnailDecodeGate(limit: 1)
        let firstPermit = await gate.acquire()
        #expect(firstPermit)

        let canceledWaiter = Task {
            await gate.acquire()
        }
        let liveWaiter = Task {
            await gate.acquire()
        }
        await Task.yield()
        canceledWaiter.cancel()

        let canceledPermit = await canceledWaiter.value
        #expect(!canceledPermit)

        await gate.release()
        let livePermit = await liveWaiter.value
        #expect(livePermit)
        await gate.release()
    }
}
