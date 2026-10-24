import Testing
import Foundation
import CoreImage
import ImageIO
import AppKit
import Metal
import Synchronization
@testable import Aagedal_Photo_Agent

/// End-to-end GPU test for watermark compositing: builds a real watermark asset + layer,
/// renders it through the actual offscreen (export) Metal path — the same
/// `MetalEditPipeline.renderOffscreen` the real export pipeline calls — and samples pixels
/// from the result to confirm the watermark actually lands where its geometry says it
/// should, and nowhere else. This is deliberately isolated from the edit-view UI: it
/// exercises the highest-risk, least-previously-proven part of the feature (texture
/// decode/upload, the 3-bucket order-buffer encoding, and the premultiplied-alpha "over"
/// blend) directly, without needing the app running.
@Suite("Watermark Metal rendering", .serialized)
@MainActor
struct WatermarkRenderingTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatermarkRenderingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func activateStore(_ dir: URL) async {
        WatermarkStore.storageOverrideURL = dir
        await WatermarkStore.shared.reloadAfterStorageChange()
    }

    private func teardownStore(_ dir: URL) {
        WatermarkStore.storageOverrideURL = nil
        try? FileManager.default.removeItem(at: dir)
        WatermarkStore.shared.invalidateStorageCache()
    }

    /// A solid opaque color PNG, `size`×`size`, encoded as real PNG bytes (not a raw bitmap)
    /// so it exercises the same `CGImageSourceCreateWithData` decode path a real user's
    /// imported watermark would.
    private func makeSolidColorPNGData(size: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: red, green: green, blue: blue, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// Samples the R/G/B of `image` at normalized (nx, ny). `renderOffscreen`'s result already
    /// corrects `CIImage(mtlTexture:)`'s known vertical-flip quirk (`.oriented(.downMirrored)`),
    /// so this is in the same bottom-left-origin, y-up convention as any other CIImage: ny near
    /// 1 is the visual TOP of the rendered image, ny near 0 is the visual BOTTOM.
    private func sampleAt(_ image: CIImage, nx: Double, ny: Double) -> (r: Float, g: Float, b: Float) {
        let extent = image.extent
        let px = extent.origin.x + CGFloat(nx) * extent.width
        let py = extent.origin.y + CGFloat(ny) * extent.height
        var buffer: [Float] = [0, 0, 0, 0]
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        ctx.render(
            image, toBitmap: &buffer, rowBytes: 16,
            bounds: CGRect(x: px, y: py, width: 1, height: 1),
            format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (buffer[0], buffer[1], buffer[2])
    }

    /// Samples at the vertical midpoint — invariant to any up/down convention, so tests that
    /// only care about horizontal placement don't need to reason about orientation.
    private func sampleMidRow(_ image: CIImage, nx: Double) -> (r: Float, g: Float, b: Float) {
        sampleAt(image, nx: nx, ny: 0.5)
    }

    /// A two-tone PNG, `width`×`height`, top half `topColor` and bottom half `bottomColor` —
    /// ground truth by construction: row 0 of the raw pixel buffer is the image's first
    /// scanline, which is the TOP of the image in any viewer (Preview, Finder, a real user's
    /// watermark), independent of any CGContext coordinate-system flip ambiguity. Used to catch
    /// orientation bugs a solid-color test image can never reveal.
    private func makeTwoToneVerticalPNGData(
        width: Int, height: Int,
        topColor: (UInt8, UInt8, UInt8), bottomColor: (UInt8, UInt8, UInt8)
    ) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let color = y < height / 2 ? topColor : bottomColor
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = color.0
                pixels[i + 1] = color.1
                pixels[i + 2] = color.2
                pixels[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { throw CocoaError(.fileWriteUnknown) }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return mutableData as Data
    }

    @Test("the process-lifetime export engine releases mask, scratch and watermark textures after each render")
    func offscreenRenderReleasesTransientTextures() async throws {
        let dir = makeTempDir()
        await activateStore(dir)
        defer { teardownStore(dir) }

        let pngData = try makeSolidColorPNGData(size: 32, red: 0, green: 1, blue: 0)
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString).png")
        try pngData.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try await WatermarkStore.shared.importPNG(from: pngURL, name: "Green Square")

        var geometry = WatermarkGeometry()
        geometry.centerX = 0.5
        geometry.centerY = 0.5
        geometry.sizeDimension = .width
        geometry.sizeUnit = .percent
        geometry.sizeValue = 25
        var layer = WatermarkLayer(name: "Release", libraryAssetID: asset.id, geometry: geometry)
        layer.opacity = 1

        var settings = CameraRawSettings()
        settings.watermarkLayers = [layer]
        settings.localAdjustments = [MaskAdjustment(
            name: "Brush",
            brush: BrushMaskGeometry(strokes: [BrushStroke(
                dabs: (0..<20).map { BrushDab(x: Double($0) / 20, y: 0.5, flow: 1, hardness: 1) },
                radius: 0.05, density: 1, erase: false
            )]),
            exposure: 1
        )]

        let source = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120))
        let result = try #require(MetalEditPipeline.renderOffscreen(source: source, settings: settings))

        // The returned image only references the output texture: every per-render texture of
        // the shared engine is already gone, yet the result still renders the watermark.
        #expect(MetalEditPipeline.offscreenRetainedTransientTextureCountForTesting() == 0)
        let center = sampleMidRow(result, nx: 0.5)
        #expect(center.g > 0.9, "watermark must still be in the returned image, got \(center)")

        // The small watermark texture stays cached: this engine also renders edited thumbnails
        // and previews, which must not re-read the PNG every time.
        #expect(MetalEditPipeline.offscreenHasCachedWatermarkTextureForTesting())
        #expect(!WatermarkTextureLoadFailures.lastLoadFailed(asset.id))

        // A second render with the same settings rebuilds the masks, identically.
        let again = try #require(MetalEditPipeline.renderOffscreen(source: source, settings: settings))
        #expect(MetalEditPipeline.offscreenRetainedTransientTextureCountForTesting() == 0)
        let againCenter = sampleMidRow(again, nx: 0.5)
        #expect(abs(againCenter.g - center.g) < 0.001)
        #expect(abs(againCenter.r - center.r) < 0.001)

        // Memory pressure drops the watermark cache; the next render reloads it.
        MetalEditPipeline.evictOffscreenCachesForTesting()
        #expect(!MetalEditPipeline.offscreenHasCachedWatermarkTextureForTesting())
        let reloaded = try #require(MetalEditPipeline.renderOffscreen(source: source, settings: settings))
        #expect(abs(sampleMidRow(reloaded, nx: 0.5).g - center.g) < 0.001)
    }

    @Test("a watermark whose PNG cannot be read during render is reported to export, not skipped silently")
    func unreadableWatermarkIsReportedToExport() async throws {
        let dir = makeTempDir()
        await activateStore(dir)
        defer { teardownStore(dir) }

        let pngData = try makeSolidColorPNGData(size: 16, red: 1, green: 1, blue: 0)
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString).png")
        try pngData.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try await WatermarkStore.shared.importPNG(from: pngURL, name: "Corrupt")
        // The file stays readable on disk but no longer decodes (a torn or mid-sync read).
        try Data("not a png".utf8).write(to: WatermarkStore.resolvedImageURL(forAssetID: asset.id))

        var geometry = WatermarkGeometry()
        geometry.sizeDimension = .width
        geometry.sizeUnit = .percent
        geometry.sizeValue = 25
        var settings = CameraRawSettings()
        settings.watermarkLayers = [WatermarkLayer(name: "Corrupt", libraryAssetID: asset.id, geometry: geometry)]
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        _ = MetalEditPipeline.renderOffscreen(source: source, settings: settings)

        #expect(WatermarkTextureLoadFailures.lastLoadFailed(asset.id))
        #expect(EditExportPipeline.missingWatermarkAssetIDs(in: settings) == [asset.id])
    }

    @Test("a fully-opaque watermark layer composites its own color inside its footprint and leaves the rest of the image untouched")
    func watermarkCompositesAtItsFootprint() async throws {
        let dir = makeTempDir()
        await activateStore(dir)
        defer { teardownStore(dir) }

        // A 50×50 fully-opaque red PNG, imported as a library asset like a real user would.
        let pngData = try makeSolidColorPNGData(size: 50, red: 1, green: 0, blue: 0)
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString).png")
        try pngData.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try await WatermarkStore.shared.importPNG(from: pngURL, name: "Red Square")

        // 200×100 solid opaque blue source image.
        let sourceExtent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1)).cropped(to: sourceExtent)

        // Width = 50% of the 200px-wide image → 100px wide; the asset is square, so also
        // 100px tall. Centered → covers UV x in [0.25, 0.75], y in [0, 1] (image is only
        // 100px tall, same as the watermark, so it spans the full height).
        var geometry = WatermarkGeometry()
        geometry.centerX = 0.5
        geometry.centerY = 0.5
        geometry.sizeDimension = .width
        geometry.sizeUnit = .percent
        geometry.sizeValue = 50
        var layer = WatermarkLayer(name: "Test", libraryAssetID: asset.id, geometry: geometry)
        layer.opacity = 1.0

        var settings = CameraRawSettings()
        settings.watermarkLayers = [layer]

        let result = try #require(MetalEditPipeline.renderOffscreen(source: source, settings: settings))

        let inside = sampleMidRow(result, nx: 0.5)
        #expect(inside.r > 0.9, "expected watermark red inside its footprint, got \(inside)")
        #expect(inside.b < 0.1, "expected watermark red (not background blue) inside its footprint, got \(inside)")

        let leftOfFootprint = sampleMidRow(result, nx: 0.05)
        #expect(leftOfFootprint.b > 0.9, "expected untouched background blue left of the footprint, got \(leftOfFootprint)")
        #expect(leftOfFootprint.r < 0.1, "expected no watermark red left of the footprint, got \(leftOfFootprint)")

        let rightOfFootprint = sampleMidRow(result, nx: 0.95)
        #expect(rightOfFootprint.b > 0.9, "expected untouched background blue right of the footprint, got \(rightOfFootprint)")
        #expect(rightOfFootprint.r < 0.1, "expected no watermark red right of the footprint, got \(rightOfFootprint)")
    }

    @Test("cropped renders place watermark geometry relative to the cropped output frame")
    func croppedRenderUsesCropFrameForWatermark() async throws {
        let dir = makeTempDir()
        await activateStore(dir)
        defer { teardownStore(dir) }

        let pngData = try makeSolidColorPNGData(size: 20, red: 1, green: 0, blue: 0)
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString).png")
        try pngData.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try await WatermarkStore.shared.importPNG(from: pngURL, name: "Red Square")

        let sourceExtent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1)).cropped(to: sourceExtent)

        var geometry = WatermarkGeometry()
        geometry.centerX = 0.8
        geometry.centerY = 0.5
        geometry.sizeDimension = .width
        geometry.sizeUnit = .percent
        geometry.sizeValue = 20
        var layer = WatermarkLayer(name: "Test", libraryAssetID: asset.id, geometry: geometry)
        layer.opacity = 1.0

        var settings = CameraRawSettings()
        settings.crop = CameraRawCrop(top: 0, left: 0.25, bottom: 1, right: 0.75, angle: 0, hasCrop: true)
        settings.watermarkLayers = [layer]

        let result = CameraRawApproximation.applyWithCrop(to: source, settings: settings)

        #expect(abs(result.extent.width - 100) < 0.5, "expected cropped output width near 100, got \(result.extent.width)")
        let insideCropFrameWatermark = sampleMidRow(result, nx: 0.8)
        #expect(insideCropFrameWatermark.r > 0.9, "expected watermark red at crop-frame x=0.8, got \(insideCropFrameWatermark)")
        #expect(insideCropFrameWatermark.b < 0.1, "expected watermark to cover blue background at crop-frame x=0.8, got \(insideCropFrameWatermark)")

        let outsideFootprint = sampleMidRow(result, nx: 0.55)
        #expect(outsideFootprint.b > 0.9, "expected blue background outside crop-frame watermark, got \(outsideFootprint)")
        #expect(outsideFootprint.r < 0.1, "expected no watermark red outside crop-frame footprint, got \(outsideFootprint)")
    }

    @Test("opacity attenuates the watermark's blend toward the background")
    func opacityAttenuatesBlend() async throws {
        let dir = makeTempDir()
        await activateStore(dir)
        defer { teardownStore(dir) }

        let pngData = try makeSolidColorPNGData(size: 50, red: 1, green: 0, blue: 0)
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString).png")
        try pngData.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try await WatermarkStore.shared.importPNG(from: pngURL, name: "Red Square")

        let sourceExtent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1)).cropped(to: sourceExtent)

        var geometry = WatermarkGeometry()
        geometry.centerX = 0.5
        geometry.centerY = 0.5
        geometry.sizeDimension = .width
        geometry.sizeUnit = .percent
        geometry.sizeValue = 50
        var layer = WatermarkLayer(name: "Test", libraryAssetID: asset.id, geometry: geometry)
        layer.opacity = 0.5

        var settings = CameraRawSettings()
        settings.watermarkLayers = [layer]

        let result = try #require(MetalEditPipeline.renderOffscreen(source: source, settings: settings))
        let inside = sampleMidRow(result, nx: 0.5)
        // At 50% opacity, the blend is roughly halfway between red (1,0,0) and blue (0,0,1) —
        // neither channel should be near either pure endpoint.
        #expect(inside.r > 0.25 && inside.r < 0.75, "expected a blended red/blue mix at half opacity, got \(inside)")
        #expect(inside.b > 0.25 && inside.b < 0.75, "expected a blended red/blue mix at half opacity, got \(inside)")
    }

    /// Regression test for a real upside-down bug: an earlier version of `loadWatermarkTextures`
    /// flipped the PNG vertically while uploading it to the GPU texture, so every watermark
    /// rendered upside down relative to how it looked in Preview/Finder/the Settings library
    /// preview. A solid-color watermark can never reveal this (no vertical asymmetry to flip),
    /// which is exactly why the original tests above missed it — this uses a top/bottom
    /// two-tone PNG with an unambiguous ground truth instead.
    @Test("the watermark texture uploads right-side-up, matching the source PNG's own top/bottom order")
    func watermarkUploadsRightSideUp() async throws {
        let dir = makeTempDir()
        await activateStore(dir)
        defer { teardownStore(dir) }

        // Top half red, bottom half green — by construction, row 0 of the pixel buffer (and
        // so the PNG's first scanline) is red, which is the TOP of the image in any viewer.
        let pngData = try makeTwoToneVerticalPNGData(
            width: 50, height: 50, topColor: (255, 0, 0), bottomColor: (0, 255, 0)
        )
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString).png")
        try pngData.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try await WatermarkStore.shared.importPNG(from: pngURL, name: "Two Tone")

        // Neutral gray background so it's visually distinct from both watermark colors.
        let sourceExtent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)).cropped(to: sourceExtent)

        // Width = 50% of the 200px-wide image → 100px wide; the asset is square, so also
        // 100px tall — spans the full height of this 100px-tall source, giving a clean
        // top-edge/bottom-edge sample.
        var geometry = WatermarkGeometry()
        geometry.centerX = 0.5
        geometry.centerY = 0.5
        geometry.sizeDimension = .width
        geometry.sizeUnit = .percent
        geometry.sizeValue = 50
        let layer = WatermarkLayer(name: "Test", libraryAssetID: asset.id, geometry: geometry)

        var settings = CameraRawSettings()
        settings.watermarkLayers = [layer]

        let result = try #require(MetalEditPipeline.renderOffscreen(source: source, settings: settings))

        let nearTop = sampleAt(result, nx: 0.5, ny: 0.9)
        let nearBottom = sampleAt(result, nx: 0.5, ny: 0.1)

        #expect(nearTop.r > 0.7, "expected the PNG's red TOP half at the top of the rendered watermark, got \(nearTop)")
        #expect(nearTop.g < 0.3, "expected red (not green) near the top — watermark may be uploaded upside down, got \(nearTop)")
        #expect(nearBottom.g > 0.7, "expected the PNG's green BOTTOM half at the bottom of the rendered watermark, got \(nearBottom)")
        #expect(nearBottom.r < 0.3, "expected green (not red) near the bottom — watermark may be uploaded upside down, got \(nearBottom)")
    }

    @Test("a deleted library asset is flagged missing for the layer card and export, and bumps the texture-cache revision")
    func deletedAssetIsReportedMissing() async throws {
        let dir = makeTempDir()
        await activateStore(dir)
        defer { teardownStore(dir) }

        let pngData = try makeSolidColorPNGData(size: 20, red: 1, green: 0, blue: 0)
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString).png")
        try pngData.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try await WatermarkStore.shared.importPNG(from: pngURL, name: "Doomed")

        var settings = CameraRawSettings()
        var muted = WatermarkLayer(name: "Muted", libraryAssetID: UUID())
        muted.enabled = false
        settings.watermarkLayers = [WatermarkLayer(name: "Live", libraryAssetID: asset.id), muted]

        #expect(EditExportPipeline.missingWatermarkAssetIDs(in: settings).isEmpty)
        #expect(!WatermarkStore.shared.isAssetMissing(asset.id))

        let revisionBefore = WatermarkStore.libraryRevision.load(ordering: .relaxed)
        try await WatermarkStore.shared.delete(id: asset.id)

        #expect(WatermarkStore.libraryRevision.load(ordering: .relaxed) > revisionBefore)
        #expect(WatermarkStore.shared.isAssetMissing(asset.id))
        // Only the enabled layer counts; the muted layer's (also missing) asset is ignored.
        #expect(EditExportPipeline.missingWatermarkAssetIDs(in: settings) == [asset.id])
    }

    @Test("missing-watermark exports surface as a batch warning, not a failure")
    func missingWatermarkIsABatchWarning() async throws {
        let tracker = MetadataFailureTracker()
        await tracker.recordMissingWatermark("IMG_0001.JPG")
        let warnings = await tracker.missingWatermarkWarnings
        #expect(warnings == ["IMG_0001.JPG"])

        let result = BatchOperationResult(
            title: "Export", outcome: .partial, successCount: 1, totalCount: 1,
            failures: [], copyFailureFilenames: [], overlayFailureFilenames: [],
            missingWatermarkFilenames: warnings, sourceFolderURL: nil
        )
        #expect(result.hasWarnings)
        #expect(!result.hasFailures)
        #expect(result.summaryLine.contains("watermark image missing for 1 image"))
    }

    // MARK: Sidecar orientation

    private typealias RGB8 = (r: Int, g: Int, b: Int)

    /// Top-row-first 8-bit sRGB pixels of `image`.
    private func rgbPixels(of image: CGImage) throws -> (width: Int, height: Int, at: (Int, Int) -> RGB8) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let snapshot = bytes
        return (width, height, { x, y in
            let i = (y * width + x) * 4
            return (Int(snapshot[i]), Int(snapshot[i + 1]), Int(snapshot[i + 2]))
        })
    }

    /// A display-frame watermark (top half red, bottom half green) must render upright in the
    /// displayed bottom-right on every browse path — full screen/loupe (`applyCameraRaw` over
    /// CIImage and CGImage sources), edited thumbnails / Caption preview / prefetch
    /// (`decodedEditedPreview`) — exactly like the export render, whether the rotation lives
    /// only in the sidecar or in the file's own tag. Editing in the file frame and rotating
    /// afterwards drew the artwork sideways (and sized against the wrong edge) for
    /// sidecar-only rotations.
    @Test("sidecar-rotated photos draw watermarks upright in full screen, previews and export alike",
          arguments: [true, false])
    func sidecarRotatedWatermarkMatchesExport(sidecarOnlyRotation: Bool) async throws {
        let dir = makeTempDir()
        await activateStore(dir)
        defer { teardownStore(dir) }
        let photoDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: photoDir) }
        try FileManager.default.createDirectory(
            at: photoDir.appendingPathComponent("output"), withIntermediateDirectories: true
        )

        let pngData = try makeTwoToneVerticalPNGData(
            width: 40, height: 40, topColor: (255, 0, 0), bottomColor: (0, 255, 0)
        )
        let pngURL = photoDir.appendingPathComponent("wm.png")
        try pngData.write(to: pngURL)
        let asset = try await WatermarkStore.shared.importPNG(from: pngURL, name: "Two Tone")

        // 128x64 stored gray pixels, displayed 64x128 (orientation 6) via either the sidecar
        // (embedded tag 1) or the embedded tag itself (no sidecar).
        let source = photoDir.appendingPathComponent("photo.jpg")
        let storedWidth = 128, storedHeight = 64
        let context = try #require(CGContext(
            data: nil, width: storedWidth, height: storedHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: storedWidth, height: storedHeight))
        let destination = try #require(CGImageDestinationCreateWithURL(
            source as CFURL, "public.jpeg" as CFString, 1, nil
        ))
        let embeddedOrientation: Int = sidecarOnlyRotation ? 1 : 6
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: embeddedOrientation,
        ] as [CFString: Any] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        if sidecarOnlyRotation {
            var xmp = IPTCMetadata()
            xmp.exifOrientation = 6
            try XMPSidecarService().saveSidecar(metadata: xmp, for: source)
        }
        let fileOrientation = FullScreenImageCache.fileEXIFOrientation(at: source)
        #expect(fileOrientation == (sidecarOnlyRotation ? 1 : 6))
        let displayOrientation = FullScreenImageCache.displayOrientation(
            for: source, fallback: fileOrientation
        )
        #expect(displayOrientation == 6)

        // Placed in the displayed frame (y-down): 40% of the 64 px display width, centred in
        // the bottom-right quadrant. Stored in the sensor frame, like Develop stores it.
        var displayGeometry = WatermarkGeometry()
        displayGeometry.centerX = 0.75
        displayGeometry.centerY = 0.75
        displayGeometry.sizeDimension = .width
        displayGeometry.sizeUnit = .percent
        displayGeometry.sizeValue = 40
        displayGeometry.marginUnit = .percent
        displayGeometry.marginValue = 0
        var layer = WatermarkLayer(
            name: "Test", libraryAssetID: asset.id,
            geometry: displayGeometry.transformedForSensor(orientation: 6)
        )
        layer.opacity = 1.0
        var settings = CameraRawSettings()
        settings.watermarkLayers = [layer]

        // Export render (already display-frame since 85e5982) — the reference.
        let exported = try await EditedImageRenderer.render(
            from: source, cameraRaw: settings, isHDR: false,
            outputFolder: photoDir.appendingPathComponent("output"),
            configuration: AdvancedExportConfiguration(
                sdrFormat: .png, sdrQuality: 0.92, sdrGamut: .sRGB,
                hdrFormat: .jpegGainMap, hdrQuality: 0.92, hdrGamut: .displayP3,
                tiffCompression: .lzw, resolutionLimit: .original,
                locationMode: .formatSubfolder, customSubfolderName: "Exports"
            )
        )
        let exportSource = try #require(CGImageSourceCreateWithURL(exported as CFURL, nil))
        let exportImage = try #require(CGImageSourceCreateImageAtIndex(exportSource, 0, nil))

        // Edited thumbnails, Caption preview, prefetch and the full-screen foreground render.
        let preview = try #require(await FullScreenImageCache.decodedEditedPreview(
            for: source, settings: settings, orientation: displayOrientation, screenMaxPx: 256
        ))
        // Full-screen / loupe HDR (CIImage) and SDR (CGImage) source renders.
        let hdrDecode = try #require(FullScreenImageCache.loadHDRPreviewWithOrientation(
            from: source, maxPixelSize: 256
        ))
        let hdrEdited = FullScreenImageCache.applyEditsInDisplayFrame(
            to: hdrDecode.image, settings: settings,
            fileOrientation: hdrDecode.orientation, displayOrientation: displayOrientation
        )
        let fullScreenHDR = try #require(
            CameraRawApproximation.createDisplayCGImage(hdrEdited, from: hdrEdited.extent)
        )
        let sdrDecode = try #require(FullScreenImageCache.loadDownsampledWithOrientation(
            from: source, maxPixelSize: 256
        ))
        let fullScreenSDR = FullScreenImageCache.applyCameraRaw(
            to: sdrDecode.image, settings: settings,
            fileOrientation: sdrDecode.orientation, displayOrientation: displayOrientation
        )

        let reference = try rgbPixels(of: exportImage)
        func close(_ a: RGB8, _ b: RGB8, tolerance: Int = 70) -> Bool {
            abs(a.r - b.r) < tolerance && abs(a.g - b.g) < tolerance && abs(a.b - b.b) < tolerance
        }
        for (name, image) in [("export", exportImage), ("decodedEditedPreview", preview),
                              ("full screen HDR", fullScreenHDR), ("full screen SDR", fullScreenSDR)] {
            let pixels = try rgbPixels(of: image)
            #expect(pixels.width == 64 && pixels.height == 128,
                    "\(name): expected the 64x128 display frame, got \(pixels.width)x\(pixels.height)")
            guard pixels.width == 64, pixels.height == 128 else { continue }
            // Footprint: x 35...61, y 83...109; red top half, green bottom half on both
            // sides (a sideways watermark splits red/green left-right instead).
            for x in [41, 55] {
                #expect(close(pixels.at(x, 88), (255, 0, 0)),
                        "\(name): expected the watermark's red top half at (\(x), 88), got \(pixels.at(x, 88))")
                #expect(close(pixels.at(x, 104), (0, 255, 0)),
                        "\(name): expected the watermark's green bottom half at (\(x), 104), got \(pixels.at(x, 104))")
            }
            #expect(close(pixels.at(16, 32), (128, 128, 128), tolerance: 40),
                    "\(name): expected untouched gray outside the footprint, got \(pixels.at(16, 32))")
            #expect(close(pixels.at(48, 70), (128, 128, 128), tolerance: 40),
                    "\(name): expected gray above the footprint, got \(pixels.at(48, 70))")
            // Same pixels as the export everywhere (away from anti-aliased edges).
            var total = 0, count = 0
            for y in stride(from: 2, to: 126, by: 3) {
                for x in stride(from: 2, to: 62, by: 3) {
                    let a = pixels.at(x, y), b = reference.at(x, y)
                    total += abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
                    count += 3
                }
            }
            let mean = Double(total) / Double(max(count, 1))
            #expect(mean < 8, "\(name): mean difference from the export render is \(mean)")
        }
    }
}

@Suite("Watermark unit conversion")
struct WatermarkUnitConversionTests {
    @Test("switching size units keeps the rendered size against the image")
    func sizeConversionPreservesRenderedSize() {
        var geometry = WatermarkGeometry()
        geometry.sizeDimension = .width
        geometry.sizeUnit = .percent
        geometry.sizeValue = 20
        let pixels = geometry.convertingSizeUnit(to: .pixel, imageWidth: 6000, imageHeight: 4000)
        #expect(pixels.sizeUnit == .pixel)
        #expect(pixels.sizeValue == 1200)
        let before = geometry.renderedHalfExtentUV(assetAspect: 2, imageWidth: 6000, imageHeight: 4000)
        let after = pixels.renderedHalfExtentUV(assetAspect: 2, imageWidth: 6000, imageHeight: 4000)
        #expect(abs(before.halfWidthUV - after.halfWidthUV) < 1e-9)

        var tall = pixels
        tall.sizeDimension = .height
        tall.sizeValue = 400
        let percent = tall.convertingSizeUnit(to: .percent, imageWidth: 6000, imageHeight: 4000)
        #expect(percent.sizeValue == 10)
    }

    @Test("converted values clamp into the slider range")
    func conversionClamps() {
        var geometry = WatermarkGeometry()
        geometry.sizeUnit = .percent
        geometry.sizeValue = 100
        let huge = geometry.convertingSizeUnit(to: .pixel, imageWidth: 20000, imageHeight: 10000)
        #expect(huge.sizeValue == WatermarkGeometry.sizeRange(for: .pixel).upperBound)

        var tiny = WatermarkGeometry()
        tiny.sizeUnit = .pixel
        tiny.sizeValue = 8
        #expect(tiny.convertingSizeUnit(to: .percent, imageWidth: 6000, imageHeight: 4000).sizeValue == 1)

        var margin = WatermarkGeometry()
        margin.marginUnit = .percent
        margin.marginValue = 10
        let marginPixels = margin.convertingMarginUnit(to: .pixel, imageWidth: 6000, imageHeight: 4000)
        #expect(marginPixels.marginValue == 400) // exact on the shorter edge
        let wide = margin.convertingMarginUnit(to: .pixel, imageWidth: 40000, imageHeight: 30000)
        #expect(wide.marginValue == WatermarkGeometry.marginRange(for: .pixel).upperBound)
        #expect(marginPixels.convertingMarginUnit(to: .percent, imageWidth: 6000, imageHeight: 4000).marginValue == 10)
    }

    @Test("same-unit conversion is a no-op")
    func sameUnitIsNoOp() {
        var geometry = WatermarkGeometry()
        geometry.sizeValue = 33
        #expect(geometry.convertingSizeUnit(to: geometry.sizeUnit, imageWidth: 100, imageHeight: 100) == geometry)
        #expect(geometry.convertingMarginUnit(to: geometry.marginUnit, imageWidth: 100, imageHeight: 100) == geometry)
    }
}

@Suite("Anonymizer multi-pass rendering", .serialized)
struct AnonymizerMultiPassRenderingTests {
    private let extent = CGRect(x: 0, y: 0, width: 256, height: 256)

    private func checkerboard() throws -> CIImage {
        try #require(CIFilter(
            name: "CICheckerboardGenerator",
            parameters: [
                "inputColor0": CIColor(red: 0.04, green: 0.12, blue: 0.85, alpha: 1),
                "inputColor1": CIColor(red: 0.95, green: 0.18, blue: 0.04, alpha: 1),
                "inputWidth": 5.0,
                "inputSharpness": 1.0,
            ]
        )?.outputImage?.cropped(to: extent))
    }

    private func meanDifference(
        _ first: CIImage,
        _ second: CIImage,
        extent comparisonExtent: CGRect? = nil
    ) throws -> Float {
        let comparisonExtent = comparisonExtent ?? extent
        let difference = first.applyingFilter(
            "CIDifferenceBlendMode",
            parameters: [kCIInputBackgroundImageKey: second]
        )
        let average = try #require(CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: difference,
                kCIInputExtentKey: CIVector(cgRect: comparisonExtent),
            ]
        )?.outputImage)
        var pixel = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [
            .workingColorSpace: CameraRawApproximation.workingColorSpace
        ])
        context.render(
            average,
            toBitmap: &pixel,
            rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: CameraRawApproximation.workingColorSpace
        )
        return (pixel[0] + pixel[1] + pixel[2]) / 3
    }

    private func sampleLuminance(_ image: CIImage, x: Int, y: Int) -> Float {
        var pixel = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [
            .workingColorSpace: CameraRawApproximation.workingColorSpace
        ])
        context.render(
            image,
            toBitmap: &pixel,
            rowBytes: 16,
            bounds: CGRect(x: x, y: y, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: CameraRawApproximation.workingColorSpace
        )
        return pixel[0] * 0.2126 + pixel[1] * 0.7152 + pixel[2] * 0.0722
    }

    @Test("render-plan compiler isolates spatial nodes while batching adjacent pointwise layers")
    func renderPlanSegmentsAtAnonymizers() {
        let global = EditRenderPassPlanner.globalOrderSentinel
        let watermark = EditRenderPassPlanner.watermarkOrderFlag
        let plan = EditRenderPassPlanner.makePlan(
            orderEntries: [0, global, 1, watermark, 2],
            globalSpatialEffectsActive: false,
            anonymizerMaskIndices: [1]
        )

        #expect(plan == [
            EditRenderPass(orderOffset: 0, orderCount: 2, requiresMipmappedInput: false),
            EditRenderPass(orderOffset: 2, orderCount: 1, requiresMipmappedInput: true),
            EditRenderPass(orderOffset: 3, orderCount: 2, requiresMipmappedInput: false),
        ])
    }

    @Test("global and masked anonymizers each receive their own spatial pass")
    func renderPlanIsolatesMultipleSpatialNodes() {
        let global = EditRenderPassPlanner.globalOrderSentinel
        let plan = EditRenderPassPlanner.makePlan(
            orderEntries: [0, global, 1],
            globalSpatialEffectsActive: true,
            anonymizerMaskIndices: [0, 1]
        )

        #expect(plan == [
            EditRenderPass(orderOffset: 0, orderCount: 1, requiresMipmappedInput: true),
            EditRenderPass(orderOffset: 1, orderCount: 1, requiresMipmappedInput: true),
            EditRenderPass(orderOffset: 2, orderCount: 1, requiresMipmappedInput: true),
        ])
    }

    @Test("film blur effects isolate Global while pointwise film effects stay batched")
    func renderPlanHandlesFilmSpatialEffects() {
        let global = EditRenderPassPlanner.globalOrderSentinel
        let pointwise = EditRenderPassPlanner.makePlan(
            orderEntries: [0, global, 1],
            globalSpatialEffectsActive: false,
            anonymizerMaskIndices: []
        )
        #expect(pointwise == [
            EditRenderPass(orderOffset: 0, orderCount: 3, requiresMipmappedInput: false)
        ])

        let spatial = EditRenderPassPlanner.makePlan(
            orderEntries: [0, global, 1],
            globalSpatialEffectsActive: true,
            anonymizerMaskIndices: []
        )
        #expect(spatial == [
            EditRenderPass(orderOffset: 0, orderCount: 1, requiresMipmappedInput: false),
            EditRenderPass(orderOffset: 1, orderCount: 1, requiresMipmappedInput: true),
            EditRenderPass(orderOffset: 2, orderCount: 1, requiresMipmappedInput: false),
        ])
    }

    @Test("each film-emulation control changes offscreen render pixels")
    func filmEmulationControlsRenderOffscreen() throws {
        let source = try checkerboard()
        let baseline = source
        let effects: [(String, FilmEmulationSettings)] = [
            ("grain", FilmEmulationSettings(grain: 80)),
            ("halation", FilmEmulationSettings(halation: 80)),
            ("bloom", FilmEmulationSettings(bloom: 80)),
            ("vignette", FilmEmulationSettings(vignette: 80)),
            ("edge blur", FilmEmulationSettings(edgeBlur: 80)),
        ]

        for (name, film) in effects {
            var settings = CameraRawSettings()
            settings.filmEmulation = film
            let rendered = try #require(MetalEditPipeline.renderOffscreen(
                source: source, settings: settings
            ))
            let difference = try meanDifference(baseline, rendered)
            #expect(
                difference > 0.0005,
                "Expected \(name) to change rendered pixels; mean difference was \(difference)"
            )
        }
    }

    @Test("maximum darkening vignette strongly darkens corners while preserving the center")
    func filmDarkeningVignetteHasUsefulMaximumStrength() throws {
        let source = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
            .cropped(to: extent)
        var settings = CameraRawSettings()
        settings.filmEmulation = FilmEmulationSettings(vignette: -100)
        let rendered = try #require(MetalEditPipeline.renderOffscreen(
            source: source, settings: settings
        ))

        let baselineCenter = sampleLuminance(source, x: 128, y: 128)
        let center = sampleLuminance(rendered, x: 128, y: 128)
        let corner = sampleLuminance(rendered, x: 2, y: 2)
        #expect(
            abs(center - baselineCenter) < 0.01,
            "Vignette should leave the image center nearly unchanged"
        )
        #expect(corner < center * 0.2, "Maximum vignette should provide a visibly strong corner falloff")
    }

    @Test("film grain is spatially clustered rather than independent pixel noise")
    func filmGrainHasAnalogSpatialCorrelation() throws {
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            .cropped(to: extent)
        var settings = CameraRawSettings()
        settings.filmEmulation = FilmEmulationSettings(grain: 100)
        let rendered = try #require(MetalEditPipeline.renderOffscreen(
            source: source, settings: settings
        ))

        var pixels = [Float](repeating: 0, count: Int(extent.width) * 4)
        let context = CIContext(options: [
            .workingColorSpace: CameraRawApproximation.workingColorSpace
        ])
        context.render(
            rendered,
            toBitmap: &pixels,
            rowBytes: Int(extent.width) * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 128, width: extent.width, height: 1),
            format: .RGBAf,
            colorSpace: CameraRawApproximation.workingColorSpace
        )
        let values = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
        let mean = values.reduce(0, +) / Float(values.count)
        let deviations = values.map { $0 - mean }
        let variance = deviations.reduce(0) { $0 + $1 * $1 }
        let adjacentCovariance = zip(deviations, deviations.dropFirst())
            .reduce(0) { $0 + $1.0 * $1.1 }
        let correlation = adjacentCovariance / max(variance, 0.000001)

        #expect(variance > 0.0001, "Grain should remain visible on a flat midtone")
        #expect(correlation > 0.12, "Neighboring film grains should form soft clumps, not digital salt-and-pepper noise")
    }

    /// A high-frequency source makes the order of a nonlinear global tone operation and the
    /// Anonymizer's mip-filtered spatial sampling observably non-commutative. Before multi-pass,
    /// both orders produced the same pixels because the masked Anonymizer always sampled the
    /// original source and merely reapplied Global afterward.
    @Test("an anonymizer samples the nonlinear color result of upstream layers")
    func anonymizerSamplesUpstreamColorComposite() throws {
        let checker = try checkerboard()

        var mask = MaskAdjustment()
        mask.name = "Full-frame anonymizer"
        mask.geometry.centerX = 0.5
        mask.geometry.centerY = 0.5
        mask.geometry.radiusX = 1.0
        mask.geometry.radiusY = 1.0
        mask.geometry.feather = 0
        mask.anonymizer = AnonymizerSettings(amount: 72, blackOut: nil)

        var colorThenAnonymizer = CameraRawSettings()
        colorThenAnonymizer.contrast2012 = 100
        colorThenAnonymizer.toneCurve = ToneCurve(master: [
            ToneCurvePoint(x: 0, y: 0.12),
            ToneCurvePoint(x: 0.35, y: 0.18),
            ToneCurvePoint(x: 0.65, y: 0.86),
            ToneCurvePoint(x: 1, y: 1),
        ])
        colorThenAnonymizer.localAdjustments = [mask]
        colorThenAnonymizer.layerOrder = [.global, .mask(mask.id)]

        var anonymizerThenColor = colorThenAnonymizer
        anonymizerThenColor.layerOrder = [.mask(mask.id), .global]

        let upstreamColor = try #require(MetalEditPipeline.renderOffscreen(
            source: checker, settings: colorThenAnonymizer
        ))
        let downstreamColor = try #require(MetalEditPipeline.renderOffscreen(
            source: checker, settings: anonymizerThenColor
        ))

        let meanDifference = try meanDifference(upstreamColor, downstreamColor)
        #expect(
            meanDifference > 0.005,
            "Expected upstream-vs-downstream color ordering to change anonymized pixels; mean difference was \(meanDifference)"
        )
    }

    @Test("the global anonymizer samples local color layers placed before Global")
    func globalAnonymizerSamplesUpstreamLocalColor() throws {
        let checker = try checkerboard()

        var colorMask = MaskAdjustment()
        colorMask.name = "Full-frame color"
        colorMask.geometry.centerX = 0.5
        colorMask.geometry.centerY = 0.5
        colorMask.geometry.radiusX = 1.0
        colorMask.geometry.radiusY = 1.0
        colorMask.geometry.feather = 0
        colorMask.contrast = 100
        colorMask.saturation = 85

        var localColorThenGlobalAnonymizer = CameraRawSettings()
        localColorThenGlobalAnonymizer.anonymizer = AnonymizerSettings(
            amount: 72, blackOut: nil
        )
        localColorThenGlobalAnonymizer.localAdjustments = [colorMask]
        localColorThenGlobalAnonymizer.layerOrder = [
            .mask(colorMask.id), .global,
        ]

        var globalAnonymizerThenLocalColor = localColorThenGlobalAnonymizer
        globalAnonymizerThenLocalColor.layerOrder = [
            .global, .mask(colorMask.id),
        ]

        let upstreamColor = try #require(MetalEditPipeline.renderOffscreen(
            source: checker, settings: localColorThenGlobalAnonymizer
        ))
        let downstreamColor = try #require(MetalEditPipeline.renderOffscreen(
            source: checker, settings: globalAnonymizerThenLocalColor
        ))
        let difference = try meanDifference(upstreamColor, downstreamColor)
        #expect(
            difference > 0.005,
            "Expected the global Anonymizer to sample the upstream local-color composite; mean difference was \(difference)"
        )
    }

    /// The live preview keeps one ping/pong pair per engine instead of allocating two full-size
    /// mipmapped intermediates per drawn frame. A reused pair must produce exactly the pixels of
    /// a first frame on a fresh engine (every pass overwrites its output; mips are regenerated).
    @Test("live multi-pass frames reuse intermediates and match a fresh engine's pixels")
    @MainActor
    func liveRenderGraphReusesIntermediates() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let reused = MetalLivePreviewPipeline(device: device, commandQueue: queue),
              let fresh = MetalLivePreviewPipeline(device: device, commandQueue: queue)
        else { return }

        var colorMask = MaskAdjustment()
        colorMask.geometry.centerX = 0.5
        colorMask.geometry.centerY = 0.5
        colorMask.geometry.radiusX = 1.0
        colorMask.geometry.radiusY = 1.0
        colorMask.geometry.feather = 0
        colorMask.contrast = 80
        var anonymizerMask = MaskAdjustment()
        anonymizerMask.geometry.centerX = 0.3
        anonymizerMask.geometry.centerY = 0.3
        anonymizerMask.geometry.radiusX = 0.25
        anonymizerMask.geometry.radiusY = 0.25
        anonymizerMask.anonymizer = AnonymizerSettings(amount: 72, blackOut: nil)
        var settings = CameraRawSettings()
        settings.anonymizer = AnonymizerSettings(amount: 40, blackOut: nil)
        settings.exposure2012 = 0.3
        settings.localAdjustments = [colorMask, anonymizerMask]
        // Color → spatial Global → spatial mask: three passes, so both ping and pong are used.
        settings.layerOrder = [.mask(colorMask.id), .global, .mask(anonymizerMask.id)]

        let source = try checkerboard()
        let containerSize = CGSize(width: extent.width, height: extent.height)
        for pipeline in [reused, fresh] {
            pipeline.uploadSourceImage(source)
            pipeline.updateParams(settings)
            pipeline.updateViewport(
                zoomScale: 1,
                offset: .zero,
                containerSize: containerSize,
                imageSize: containerSize
            )
        }

        func renderFrame(_ pipeline: MetalLivePreviewPipeline) throws -> [UInt16] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: Int(extent.width),
                height: Int(extent.height),
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            let target = try #require(device.makeTexture(descriptor: descriptor))
            #expect(pipeline.renderLiveFrameForTesting(into: target))
            var pixels = [UInt16](repeating: 0, count: target.width * target.height * 4)
            pixels.withUnsafeMutableBytes { buffer in
                target.getBytes(
                    buffer.baseAddress!,
                    bytesPerRow: target.width * 8,
                    from: MTLRegionMake2D(0, 0, target.width, target.height),
                    mipmapLevel: 0
                )
            }
            return pixels
        }

        let first = try renderFrame(reused)
        let allocationsAfterFirstFrame = reused.renderGraphIntermediateAllocationCount
        #expect(allocationsAfterFirstFrame == 2)
        let second = try renderFrame(reused)
        let third = try renderFrame(reused)
        #expect(reused.renderGraphIntermediateAllocationCount == allocationsAfterFirstFrame)
        let baseline = try renderFrame(fresh)

        #expect(Set(first).count > 16, "The frame must contain real image content")
        #expect(second == first)
        #expect(third == first)
        #expect(baseline == first)
    }

    @Test("global Black Out remains terminal when the global tone curve lifts black")
    func globalBlackOutCannotBeLiftedByColorAdjustments() throws {
        var settings = CameraRawSettings()
        settings.anonymizer = AnonymizerSettings(amount: 72, blackOut: true)
        settings.toneCurve = ToneCurve(master: [
            ToneCurvePoint(x: 0, y: 0.5),
            ToneCurvePoint(x: 1, y: 1),
        ])

        let result = try #require(MetalEditPipeline.renderOffscreen(
            source: checkerboard(), settings: settings
        ))
        let black = CIImage(color: .black).cropped(to: extent)
        let difference = try meanDifference(result, black)
        #expect(
            difference < 0.0001,
            "Global Black Out must remain absolute black; mean difference was \(difference)"
        )
    }

    @Test("cropped output uses the same upstream-composite Anonymizer semantics")
    func croppedOutputUsesMultiPassOrdering() throws {
        let checker = try checkerboard()

        var mask = MaskAdjustment()
        mask.geometry.centerX = 0.5
        mask.geometry.centerY = 0.5
        mask.geometry.radiusX = 1.0
        mask.geometry.radiusY = 1.0
        mask.geometry.feather = 0
        mask.anonymizer = AnonymizerSettings(amount: 72, blackOut: nil)

        var colorThenAnonymizer = CameraRawSettings()
        colorThenAnonymizer.contrast2012 = 100
        colorThenAnonymizer.toneCurve = ToneCurve(master: [
            ToneCurvePoint(x: 0, y: 0.12),
            ToneCurvePoint(x: 0.35, y: 0.18),
            ToneCurvePoint(x: 0.65, y: 0.86),
            ToneCurvePoint(x: 1, y: 1),
        ])
        colorThenAnonymizer.crop = CameraRawCrop(
            top: 0.15, left: 0.2, bottom: 0.85, right: 0.8, angle: 0, hasCrop: true
        )
        colorThenAnonymizer.localAdjustments = [mask]
        colorThenAnonymizer.layerOrder = [.global, .mask(mask.id)]

        var anonymizerThenColor = colorThenAnonymizer
        anonymizerThenColor.layerOrder = [.mask(mask.id), .global]

        let upstreamColor = try #require(MetalEditPipeline.renderOffscreenCropped(
            source: checker, settings: colorThenAnonymizer
        ))
        let downstreamColor = try #require(MetalEditPipeline.renderOffscreenCropped(
            source: checker, settings: anonymizerThenColor
        ))
        #expect(upstreamColor.extent == downstreamColor.extent)

        let difference = try meanDifference(
            upstreamColor,
            downstreamColor,
            extent: upstreamColor.extent
        )
        #expect(difference > 0.005)
    }
}
