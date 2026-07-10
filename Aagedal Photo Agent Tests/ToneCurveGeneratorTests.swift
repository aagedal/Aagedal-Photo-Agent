import Testing
import Foundation
import CoreImage
@testable import Aagedal_Photo_Agent

/// Tests for tonal adjustment LUT generation and the separate final SDR output transform.
@Suite("ToneCurveGenerator")
struct ToneCurveGeneratorTests {

    /// Evaluates the LUT at a linear-light input value (linear interpolation).
    private func lutValue(_ lut: [Float], at x: Float) -> Float {
        let range = ToneCurveGenerator.domainMax - ToneCurveGenerator.domainMin
        let t = (x - ToneCurveGenerator.domainMin) / range
        let fIndex = t * Float(ToneCurveGenerator.lutSize - 1)
        let i0 = min(max(Int(fIndex), 0), ToneCurveGenerator.lutSize - 2)
        let frac = fIndex - Float(i0)
        return lut[i0] * (1.0 - frac) + lut[i0 + 1] * frac
    }

    private func settings(headroom: Bool, hdr: Bool = false, exposure: Double? = nil) -> CameraRawSettings {
        var s = CameraRawSettings()
        s.sourceHasHDRHeadroom = headroom ? true : nil
        s.hdrEditMode = hdr ? 1 : nil
        s.exposure2012 = exposure
        return s
    }

    @Test("No tonemap without headroom flag — super-whites pass through")
    func noTonemapWithoutFlag() {
        let lut = ToneCurveGenerator.generateLUT(settings: settings(headroom: false))
        #expect(abs(lutValue(lut, at: 0.5) - 0.5) < 0.01)
        #expect(abs(lutValue(lut, at: 1.5) - 1.5) < 0.01)
        #expect(abs(lutValue(lut, at: 3.0) - 3.0) < 0.01)
    }

    @Test("Adjustment LUT preserves scene headroom before the final output transform")
    func sdrTonemapShape() {
        let lut = ToneCurveGenerator.generateLUT(settings: settings(headroom: true))
        #expect(abs(lutValue(lut, at: 0.3) - 0.3) < 0.01)
        #expect(abs(lutValue(lut, at: 1.2) - 1.2) < 0.01)
        #expect(abs(lutValue(lut, at: 4.0) - 4.0) < 0.01)

        #expect(abs(ToneCurveGenerator.sdrOutputToneMap(0.69) - 0.69) < 0.01)
        let mid = ToneCurveGenerator.sdrOutputToneMap(1.2)
        #expect(mid > 0.9 && mid < 1.0)
        #expect(abs(ToneCurveGenerator.sdrOutputToneMap(1.6) - 1.0) < 0.005)
        #expect(abs(ToneCurveGenerator.sdrOutputToneMap(4.0) - 1.0) < 0.005)
        // Matches Apple's measured EDR=0 decode tonemap within its own scatter (~0.04)
        #expect(abs(ToneCurveGenerator.sdrOutputToneMap(0.825) - 0.811) < 0.04)
        #expect(abs(ToneCurveGenerator.sdrOutputToneMap(1.225) - 0.971) < 0.04)
    }

    @Test("SDR tonemap is monotone over the full domain")
    func sdrTonemapMonotone() {
        var previous = ToneCurveGenerator.sdrOutputToneMap(ToneCurveGenerator.domainMin)
        for i in 1..<ToneCurveGenerator.lutSize {
            let t = Float(i) / Float(ToneCurveGenerator.lutSize - 1)
            let x = ToneCurveGenerator.domainMin + t * (ToneCurveGenerator.domainMax - ToneCurveGenerator.domainMin)
            let value = ToneCurveGenerator.sdrOutputToneMap(x)
            #expect(value >= previous - 1e-5)
            previous = value
        }
    }

    @Test("HDR edit mode keeps headroom — no SDR tonemap")
    func hdrModeSkipsTonemap() {
        let lut = ToneCurveGenerator.generateLUT(settings: settings(headroom: true, hdr: true))
        #expect(abs(lutValue(lut, at: 3.0) - 3.0) < 0.01)
    }

    @Test("Negative exposure recovers distinct super-white detail in SDR")
    func negativeExposureRecoversHighlights() {
        let lut = ToneCurveGenerator.generateLUT(settings: settings(headroom: true, exposure: -1.5))
        // Two scene values that both rendered as flat white at 0 EV
        // (both >1.6) must now map to distinct values below SDR white.
        let a = ToneCurveGenerator.sdrOutputToneMap(lutValue(lut, at: 2.0))
        let b = ToneCurveGenerator.sdrOutputToneMap(lutValue(lut, at: 3.0))
        #expect(a < 1.0 && b < 1.0)
        #expect(b - a > 0.1)
        // And without the flag the same inputs would clip identically at encode:
        // both stay >1.0 with no rolloff.
        let noFlag = ToneCurveGenerator.generateLUT(settings: settings(headroom: false, exposure: -1.5))
        #expect(lutValue(noFlag, at: 3.0) > 1.0)
    }

    @Test("Output tonemapping is no longer represented as a global adjustment LUT")
    func identityAccountsForTonemap() {
        #expect(ToneCurveGenerator.isIdentity(settings: settings(headroom: true)) == true)
        #expect(ToneCurveGenerator.isIdentity(settings: settings(headroom: true, hdr: true)) == true)
        // No headroom, no edits: identity as before
        #expect(ToneCurveGenerator.isIdentity(settings: settings(headroom: false)) == true)
        #expect(ToneCurveGenerator.isIdentity(settings: nil) == true)
    }

    @Test("Two-point endpoint curves are active")
    func twoPointEndpointCurvesAreActive() {
        let identityCurve = ToneCurve(master: [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 1, y: 1),
        ])
        #expect(identityCurve.isEmpty)

        var blackLift = CameraRawSettings()
        blackLift.toneCurve = ToneCurve(master: [
            ToneCurvePoint(x: 0, y: 0.2),
            ToneCurvePoint(x: 1, y: 1),
        ])
        #expect(blackLift.toneCurve?.isEmpty == false)
        let lifted = ToneCurveGenerator.generatePerChannelLUT(settings: blackLift).r
        #expect(lutValue(lifted, at: 0) > 0.02)

        var whitePull = CameraRawSettings()
        whitePull.toneCurve = ToneCurve(master: [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 1, y: 0.8),
        ])
        #expect(whitePull.toneCurve?.isEmpty == false)
        let lowered = ToneCurveGenerator.generatePerChannelLUT(settings: whitePull).r
        #expect(lutValue(lowered, at: 1) < 0.8)
    }
}

/// Empirical check on the "loupe vs edit view disagree on color" caveat.
///
/// Both the edit view (`MetalEditPipeline.render(to:)`) and the loupe/grid path
/// (`CameraRawApproximation.apply` → `MetalEditPipeline.renderOffscreen`) drive the *same*
/// compute shader through the *same* `updateParams` LUT/WB/mask builder, so the per-pixel
/// color/contrast math is shared code. The only real variable between the two contexts is
/// source resolution: the edit view renders its full decode, while the loupe caches a
/// screen-resolution `renderOffscreen`. These tests render identical settings on identical
/// synthetic content at both resolutions through the real loupe entry point and measure the
/// resulting color delta in display (sRGB) code values — the "can you see it" number.
@Suite("Render pipeline parity (loupe vs edit-view resolution)")
struct RenderPipelineParityTests {
    private static let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let ctx = CIContext(options: [
        .workingColorSpace: cs, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false,
    ])

    /// A smooth scene-referred gradient that ramps each channel from black up into the
    /// super-white (>1.0) range, so the SDR-tonemap shoulder and highlight rolloff are
    /// exercised, with a fixed warm chroma so white balance has something to act on.
    private func gradient(width: Int, height: Int) -> CIImage {
        var px = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let t = Float(x) / Float(width - 1)
                let v = t * 1.6                       // 0 … 1.6 (into super-white)
                let i = (y * width + x) * 4
                px[i + 0] = v * 1.00
                px[i + 1] = v * 0.82
                px[i + 2] = v * 0.64
                px[i + 3] = 1
            }
        }
        let data = Data(bytes: px, count: px.count * MemoryLayout<Float>.size)
        return CIImage(bitmapData: data, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: Self.cs)
    }

    /// A representative develop edit: exposure/contrast/tone moves, saturation+vibrance, and a
    /// white-balance shift — strong enough to make any pipeline discrepancy visible.
    private func representativeSettings() -> CameraRawSettings {
        var s = CameraRawSettings()
        s.sourceHasHDRHeadroom = true        // RAW-like → engages the SDR tonemap shoulder
        s.exposure2012 = 0.3
        s.contrast2012 = 25
        s.highlights2012 = -40
        s.shadows2012 = 35
        s.whites2012 = 15
        s.blacks2012 = -12
        s.saturation = 20
        s.vibrance = 15
        s.temperature = 5200
        s.asShotNeutralTemperature = 5500
        s.tint = 8
        s.asShotNeutralTint = 0
        s.hasSettings = true
        return s
    }

    /// Renders `image` to a float bitmap and samples `count` interior columns at mid-height,
    /// keyed by normalized x so the two resolutions are compared at the same scene position.
    private func sampleRow(_ image: CIImage, count: Int) -> [SIMD3<Float>] {
        let ext = image.extent
        let w = Int(ext.width), h = Int(ext.height)
        var buf = [Float](repeating: 0, count: w * h * 4)
        Self.ctx.render(image, toBitmap: &buf, rowBytes: w * 4 * MemoryLayout<Float>.size,
                        bounds: ext, format: .RGBAf, colorSpace: Self.cs)
        let y = h / 2
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(count)
        for k in 0..<count {
            // Interior only (skip the outer 8%) so edge resampling doesn't dominate the metric.
            let nx = 0.08 + 0.84 * (Float(k) + 0.5) / Float(count)
            let x = min(max(Int(nx * Float(w)), 0), w - 1)
            let i = (y * w + x) * 4
            out.append(SIMD3(buf[i], buf[i + 1], buf[i + 2]))
        }
        return out
    }

    private func toSRGBCode(_ v: Float) -> Float {
        let c = min(max(v, 0), 1)
        let enc = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return enc * 255
    }

    @Test("Loupe-res and edit-res renders agree within display rounding")
    func resolutionParity() {
        let settings = representativeSettings()

        // Edit-view-like: render the full-resolution decode.
        let full = gradient(width: 1600, height: 200)
        // Loupe-like: a screen-resolution downsample of the same scene.
        let small = gradient(width: 640, height: 80)

        let fullOut = CameraRawApproximation.applyWithCrop(to: full, settings: settings)
        let smallOut = CameraRawApproximation.applyWithCrop(to: small, settings: settings)

        // Sanity: the edit actually changed the pixels (i.e. Metal render ran, not a pass-through).
        let srcSample = sampleRow(full, count: 32)
        let fullSample = sampleRow(fullOut, count: 32)
        let changed = zip(srcSample, fullSample).contains { abs(($0 - $1).max()) > 0.02 }
        #expect(changed, "render produced no change — Metal pipeline likely unavailable; parity result not meaningful")

        let a = sampleRow(fullOut, count: 64)
        let b = sampleRow(smallOut, count: 64)

        var maxCode: Float = 0
        var sumCode: Float = 0
        var n = 0
        for (pa, pb) in zip(a, b) {
            for ch in 0..<3 {
                let d = abs(toSRGBCode(pa[ch]) - toSRGBCode(pb[ch]))
                maxCode = max(maxCode, d)
                sumCode += d
                n += 1
            }
        }
        let meanCode = sumCode / Float(n)
        print(String(format: "[parity] loupe-res vs edit-res: mean ΔsRGB = %.3f code values, max ΔsRGB = %.3f code values (0–255)", meanCode, maxCode))

        // A difference under ~2 code values out of 255 is below the perceptual threshold for a
        // smooth gradient and within display-rounding noise — i.e. "good enough", no visible pop.
        #expect(meanCode < 2.0)
        #expect(maxCode < 4.0)
    }

    @Test("Re-rendering identical settings is deterministic (shared pipeline)")
    func determinism() {
        let settings = representativeSettings()
        let img = gradient(width: 800, height: 100)
        let first = sampleRow(CameraRawApproximation.applyWithCrop(to: img, settings: settings), count: 64)
        let second = sampleRow(CameraRawApproximation.applyWithCrop(to: img, settings: settings), count: 64)
        var maxCode: Float = 0
        for (pa, pb) in zip(first, second) {
            for ch in 0..<3 {
                maxCode = max(maxCode, abs(toSRGBCode(pa[ch]) - toSRGBCode(pb[ch])))
            }
        }
        print(String(format: "[parity] determinism: max ΔsRGB across two identical renders = %.4f code values", maxCode))
        #expect(maxCode < 0.5)
    }
}
