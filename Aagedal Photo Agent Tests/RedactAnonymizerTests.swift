import CoreImage
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Redact Anonymizer settings")
struct RedactAnonymizerSettingsTests {
    private func customized() -> AnonymizerSettings {
        var settings = AnonymizerSettings.redactDefaults(seed: 424_242)
        settings.updateParameters { p in
            p.distortionAmount = 64
            p.distortionScale = 37
            p.blurRadius = 33
            p.mosaicSize = 48
            p.mosaicShape = .hexagon
            p.cellNoise = 7.5
            p.colorNoise = 4
            p.desaturate = 55
            p.blurAfterMosaic = true
            p.frostedGlass = true
            p.frostAmount = 62
            p.frostColor = AnonymizerColor(red: 0.9, green: 0.85, blue: 0.7)
            p.blurEnabled = false
        }
        return settings
    }

    @Test("enabling starts at Redact's defaults with a random seed")
    func enablingUsesRedactDefaults() {
        var settings: AnonymizerSettings?
        AnonymizerToggleBehavior.setEnabled(true, settings: &settings)

        let enabled = try? #require(settings)
        #expect(enabled?.isEmpty == false)
        #expect(enabled?.seed != nil)
        var expected = RedactParameters.defaults
        expected.seed = enabled?.seed ?? 0
        #expect(enabled?.redactParameters == expected)
    }

    @Test("a legacy strength maps onto Redact layers, never below Redact's minimums")
    func legacyStrengthMapping() {
        let weak = AnonymizerSettings(amount: 30).redactParameters
        #expect(weak.mosaicSize == 21)
        #expect(weak.blurRadius == 15)
        #expect(weak.distortionAmount == 15)
        #expect(weak.distortionScale == RedactDefaults.distortionScale)
        #expect(weak.seed == 0)

        let strong = AnonymizerSettings(amount: 100).redactParameters
        #expect(strong.mosaicSize == 128)
        #expect(abs(strong.blurRadius - 76.8) < 1e-9)
        #expect(abs(strong.distortionAmount - 76.8) < 1e-9)
        #expect(abs(strong.distortionScale - 51.2) < 1e-9)
    }

    @Test("editing a legacy anonymizer converts it without changing the other values")
    func legacyConversionOnEdit() {
        var settings = AnonymizerSettings(amount: 100)
        let before = settings.redactParameters
        settings.updateParameters { $0.cellNoise = 10 }

        #expect(!settings.isLegacyStrengthOnly)
        #expect(settings.amount == nil)
        var expected = before
        expected.cellNoise = 10
        #expect(settings.redactParameters == expected)
    }

    @Test("values are clamped to Redact's ranges")
    func clamping() {
        var settings = AnonymizerSettings.redactDefaults(seed: 1)
        settings.updateParameters { p in
            p.mosaicSize = 2
            p.blurRadius = 1
            p.distortionAmount = 900
            p.cellNoise = 60
        }
        let p = settings.redactParameters
        #expect(p.mosaicSize == 21)
        #expect(p.blurRadius == 15)
        #expect(p.distortionAmount == 200)
        #expect(p.cellNoise == 25)
    }

    @Test("Redact settings round-trip through the app-private XMP fields")
    func xmpFieldsRoundTrip() throws {
        let settings = customized()
        let fields = AnonymizerXMP.fields(for: settings)
        let byName = Dictionary(uniqueKeysWithValues: fields)
        // Versions that only know AnonymizerAmount keep redacting.
        #expect(byName[AnonymizerXMP.amount] != nil)
        #expect(fields.allSatisfy { $0.0.hasPrefix("Anonymizer") })

        let decoded = try #require(AnonymizerXMP.settings(reading: { byName[$0] }))
        #expect(decoded == settings)
        #expect(decoded.amount == nil)
    }

    @Test("a legacy strength-only anonymizer is written as it was")
    func legacyXMPUnchanged() {
        let fields = AnonymizerXMP.fields(for: AnonymizerSettings(amount: 72.5))
        #expect(fields.map(\.0) == [AnonymizerXMP.amount])
        #expect(fields.first?.1 == "72.5")
    }

    @Test("the compatible strength follows the mosaic size")
    func compatibleStrength() {
        #expect(RedactParameters.defaults.compatibleLegacyAmount == 45.8)
        var big = RedactParameters.defaults
        big.mosaicSize = 256
        #expect(big.compatibleLegacyAmount == 100)
    }

    @Test("Redact settings round-trip through an XMP sidecar and a mask correction")
    func sidecarAndMaskRoundTrip() throws {
        let svc = XMPSidecarService()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imageURL = tmp.appendingPathComponent("redact.jpg")

        var mask = MaskAdjustment(name: "Face", geometry: EllipseMaskGeometry())
        mask.anonymizer = customized()
        var settings = CameraRawSettings()
        settings.anonymizer = .redactDefaults(seed: 99)
        settings.localAdjustments = [mask]
        try svc.saveCameraRawOnly(settings, orientation: nil, for: imageURL)

        let reloaded = try #require(svc.loadSidecar(for: imageURL)?.cameraRaw)
        #expect(reloaded.anonymizer == settings.anonymizer)
        #expect(reloaded.localAdjustments?.first?.anonymizer == mask.anonymizer)

        // Clearing the global anonymizer removes every Redact field.
        settings.anonymizer = nil
        try svc.saveCameraRawOnly(settings, orientation: nil, for: imageURL)
        let cleared = try #require(svc.loadSidecar(for: imageURL)?.cameraRaw)
        #expect(cleared.anonymizer == nil)
        let xmp = try String(contentsOf: tmp.appendingPathComponent("redact.xmp"), encoding: .utf8)
        #expect(!xmp.contains("aaphoto:AnonymizerSeed=\"99\""))
    }

    @Test("paste and merge never weaken a redaction")
    func atLeastAsStrong() {
        let target = AnonymizerSettings.redactDefaults(seed: 5)

        var stronger = AnonymizerSettings.redactDefaults(seed: 6)
        stronger.updateParameters { $0.mosaicSize = 60; $0.frostedGlass = true }
        #expect(AnonymizerSettings.atLeastAsStrong(target: target, incoming: stronger) == stronger)

        var weaker = AnonymizerSettings.redactDefaults(seed: 7)
        weaker.updateParameters { $0.blurEnabled = false }
        #expect(AnonymizerSettings.atLeastAsStrong(target: target, incoming: weaker) == target)

        // Neither dominates: the target is kept with each strength raised.
        var mixed = AnonymizerSettings.redactDefaults(seed: 8)
        mixed.updateParameters { $0.blurEnabled = false; $0.mosaicSize = 80 }
        let merged = AnonymizerSettings.atLeastAsStrong(target: target, incoming: mixed)?.redactParameters
        #expect(merged?.blurEnabled == true)
        #expect(merged?.blurRadius == RedactDefaults.blurRadius)
        #expect(merged?.mosaicSize == 80)
        #expect(merged?.seed == 5)

        var blackOut = AnonymizerSettings.redactDefaults(seed: 9)
        blackOut.blackOut = true
        #expect(AnonymizerSettings.atLeastAsStrong(target: blackOut, incoming: stronger)?.blackOut == true)

        #expect(AnonymizerSettings.atLeastAsStrong(
            target: AnonymizerSettings(amount: 40), incoming: AnonymizerSettings(amount: 70)
        )?.amount == 70)
    }

    @Test("render settings scale with the image's short side")
    func renderSettingsScale() {
        let p = RedactParameters.defaults
        let preview = RedactRenderSettings(p, imageSize: SIMD2(1620, 1080))
        let export = RedactRenderSettings(p, imageSize: SIMD2(6480, 4320))
        #expect(preview.mosaicSize == 30)
        #expect(export.mosaicSize == 120)
        #expect(export.blurRadius == 4 * preview.blurRadius)
        // Same seed → same warp and cell seeds at both resolutions.
        #expect(preview.seed == export.seed)
        #expect(preview.cellSeed == export.cellSeed)
        #expect(abs(preview.biasDx) < 1 && abs(preview.biasDy) < 1)

        var off = p
        off.distortionEnabled = false
        off.blurEnabled = false
        off.mosaicEnabled = false
        let stages = RedactStage.stages(
            for: RedactRenderSettings(off, imageSize: SIMD2(100, 100)), textureScale: 1
        )
        #expect(stages.map(\.kernel) == [.mosaic])
    }

    @Test("the render plan carries each anonymizer's Redact parameters")
    func renderPlanCarriesRedact() {
        let global = EditRenderPassPlanner.globalOrderSentinel
        var maskParameters = RedactParameters.defaults
        maskParameters.mosaicSize = 77
        let plan = EditRenderPassPlanner.makePlan(
            orderEntries: [global, 0, 1],
            globalSpatialEffectsActive: true,
            anonymizerMaskIndices: [1],
            globalRedact: .defaults,
            maskRedact: [1: maskParameters]
        )
        #expect(plan.map(\.redact) == [.defaults, nil, maskParameters])
    }
}

@Suite("Redact Anonymizer rendering", .serialized)
struct RedactAnonymizerRenderingTests {
    private let extent = CGRect(x: 0, y: 0, width: 256, height: 256)

    private func checkerboard() throws -> CIImage {
        try #require(CIFilter(
            name: "CICheckerboardGenerator",
            parameters: [
                "inputColor0": CIColor(red: 0.04, green: 0.12, blue: 0.85, alpha: 1),
                "inputColor1": CIColor(red: 0.95, green: 0.18, blue: 0.04, alpha: 1),
                "inputWidth": 6.0,
                "inputSharpness": 1.0,
            ]
        )?.outputImage?.cropped(to: extent))
    }

    private func pixels(_ image: CIImage) -> [Float] {
        var result = [Float](repeating: 0, count: Int(extent.width * extent.height) * 4)
        let context = CIContext(options: [.workingColorSpace: CameraRawApproximation.workingColorSpace])
        context.render(
            image,
            toBitmap: &result,
            rowBytes: Int(extent.width) * 16,
            bounds: extent,
            format: .RGBAf,
            colorSpace: CameraRawApproximation.workingColorSpace
        )
        return result
    }

    private func meanAbsoluteDifference(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            sum += abs(a[i] - b[i]) + abs(a[i + 1] - b[i + 1]) + abs(a[i + 2] - b[i + 2])
        }
        return sum / Float(a.count / 4 * 3)
    }

    /// Mean absolute difference between horizontally adjacent pixels: high for the source
    /// checkerboard, low once the detail is gone.
    private func detail(_ p: [Float]) -> Float {
        let width = Int(extent.width)
        var sum: Float = 0
        var count = 0
        for y in 0..<Int(extent.height) {
            for x in 0..<(width - 1) {
                let i = (y * width + x) * 4
                sum += abs(p[i] - p[i + 4]) + abs(p[i + 1] - p[i + 5]) + abs(p[i + 2] - p[i + 6])
                count += 3
            }
        }
        return sum / Float(count)
    }

    private func render(_ anonymizer: AnonymizerSettings, source: CIImage) throws -> [Float] {
        var settings = CameraRawSettings()
        settings.anonymizer = anonymizer
        let rendered = try #require(MetalEditPipeline.renderOffscreen(source: source, settings: settings))
        return pixels(rendered)
    }

    @Test("the default Redact stack removes the source detail")
    func defaultsRemoveDetail() throws {
        let source = try checkerboard()
        let original = pixels(source)
        let redacted = try render(.redactDefaults(seed: 1234), source: source)
        #expect(detail(redacted) < detail(original) * 0.2)
        #expect(meanAbsoluteDifference(original, redacted) > 0.05)
    }

    @Test("the seed changes the pattern and a fixed seed renders identically")
    func seedIsDeterministic() throws {
        let source = try checkerboard()
        var a = AnonymizerSettings.redactDefaults(seed: 1)
        a.updateParameters { $0.mosaicEnabled = false }
        var b = a
        b.updateParameters { $0.seed = 777 }
        let first = try render(a, source: source)
        let again = try render(a, source: source)
        let other = try render(b, source: source)
        #expect(meanAbsoluteDifference(first, again) < 1e-4)
        #expect(meanAbsoluteDifference(first, other) > 1e-3)
    }

    @Test("Desaturate 100 % leaves a neutral result")
    func desaturateRemovesColour() throws {
        var settings = AnonymizerSettings.redactDefaults(seed: 3)
        settings.updateParameters { $0.desaturate = 100; $0.colorNoise = 0 }
        let p = try render(settings, source: try checkerboard())
        var chroma: Float = 0
        for i in stride(from: 0, to: p.count, by: 4) {
            chroma += max(p[i], p[i + 1], p[i + 2]) - min(p[i], p[i + 1], p[i + 2])
        }
        #expect(chroma / Float(p.count / 4) < 0.01)
    }

    @Test("Frosted Glass lifts the region toward the frost colour")
    func frostedGlassLifts() throws {
        let dark = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)).cropped(to: extent)
        var plain = AnonymizerSettings.redactDefaults(seed: 4)
        plain.updateParameters { $0.cellNoise = 0; $0.colorNoise = 0 }
        var frosted = plain
        frosted.updateParameters { $0.frostedGlass = true; $0.frostAmount = 80 }
        let base = try render(plain, source: dark)
        let lifted = try render(frosted, source: dark)
        let mean = { (p: [Float]) in stride(from: 0, to: p.count, by: 4).reduce(Float(0)) { $0 + p[$1 + 1] } / Float(p.count / 4) }
        #expect(mean(lifted) > mean(base) + 0.2)
    }

    @Test("every mosaic shape renders")
    func shapesRender() throws {
        let source = try checkerboard()
        var results: [[Float]] = []
        for shape in AnonymizerMosaicShape.allCases {
            var settings = AnonymizerSettings.redactDefaults(seed: 11)
            settings.updateParameters { $0.mosaicShape = shape; $0.blurEnabled = false }
            results.append(try render(settings, source: source))
        }
        #expect(meanAbsoluteDifference(results[0], results[1]) > 1e-3)
        #expect(meanAbsoluteDifference(results[0], results[2]) > 1e-3)
    }

    @Test("a legacy strength-only anonymizer still redacts")
    func legacyStillRedacts() throws {
        let source = try checkerboard()
        let original = pixels(source)
        let redacted = try render(AnonymizerSettings(amount: 30), source: source)
        #expect(detail(redacted) < detail(original) * 0.3)
    }
}
