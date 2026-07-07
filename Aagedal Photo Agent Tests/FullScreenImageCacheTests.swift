import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Aagedal_Photo_Agent

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
}
