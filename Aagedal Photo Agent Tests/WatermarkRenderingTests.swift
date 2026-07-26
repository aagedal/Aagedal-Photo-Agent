import Testing
import Foundation
import CoreImage
import ImageIO
import AppKit
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

    private func activateStore(_ dir: URL) {
        WatermarkStore.storageOverrideURL = dir
        WatermarkStore.shared.reloadAfterStorageChange()
    }

    private func teardownStore(_ dir: URL) {
        WatermarkStore.storageOverrideURL = nil
        try? FileManager.default.removeItem(at: dir)
        WatermarkStore.shared.reloadAfterStorageChange()
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

    @Test("a fully-opaque watermark layer composites its own color inside its footprint and leaves the rest of the image untouched")
    func watermarkCompositesAtItsFootprint() throws {
        let dir = makeTempDir()
        activateStore(dir)
        defer { teardownStore(dir) }

        // A 50×50 fully-opaque red PNG, imported as a library asset like a real user would.
        let pngData = try makeSolidColorPNGData(size: 50, red: 1, green: 0, blue: 0)
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString).png")
        try pngData.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try WatermarkStore.shared.importPNG(from: pngURL, name: "Red Square")

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
    func croppedRenderUsesCropFrameForWatermark() throws {
        let dir = makeTempDir()
        activateStore(dir)
        defer { teardownStore(dir) }

        let pngData = try makeSolidColorPNGData(size: 20, red: 1, green: 0, blue: 0)
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString).png")
        try pngData.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try WatermarkStore.shared.importPNG(from: pngURL, name: "Red Square")

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
    func opacityAttenuatesBlend() throws {
        let dir = makeTempDir()
        activateStore(dir)
        defer { teardownStore(dir) }

        let pngData = try makeSolidColorPNGData(size: 50, red: 1, green: 0, blue: 0)
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString).png")
        try pngData.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try WatermarkStore.shared.importPNG(from: pngURL, name: "Red Square")

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
    func watermarkUploadsRightSideUp() throws {
        let dir = makeTempDir()
        activateStore(dir)
        defer { teardownStore(dir) }

        // Top half red, bottom half green — by construction, row 0 of the pixel buffer (and
        // so the PNG's first scanline) is red, which is the TOP of the image in any viewer.
        let pngData = try makeTwoToneVerticalPNGData(
            width: 50, height: 50, topColor: (255, 0, 0), bottomColor: (0, 255, 0)
        )
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString).png")
        try pngData.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try WatermarkStore.shared.importPNG(from: pngURL, name: "Two Tone")

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

    @Test("maximum vignette strongly darkens corners while preserving the center")
    func filmVignetteHasUsefulMaximumStrength() throws {
        let source = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
            .cropped(to: extent)
        var settings = CameraRawSettings()
        settings.filmEmulation = FilmEmulationSettings(vignette: 100)
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
