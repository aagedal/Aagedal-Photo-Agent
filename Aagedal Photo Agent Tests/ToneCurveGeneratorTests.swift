import Testing
import Foundation
@testable import Aagedal_Photo_Agent

/// Tests for the SDR output tonemap that rolls scene-referred EDR headroom
/// (RAW decodes are always full-headroom) into display range when HDR edit
/// mode is off. See ToneCurveGenerator step 7.
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

    @Test("SDR tonemap: identity below knee, compressed shoulder, 1.0 ceiling")
    func sdrTonemapShape() {
        let lut = ToneCurveGenerator.generateLUT(settings: settings(headroom: true))
        // Identity below the 0.7 knee
        #expect(abs(lutValue(lut, at: 0.3) - 0.3) < 0.01)
        #expect(abs(lutValue(lut, at: 0.69) - 0.69) < 0.01)
        // Shoulder: compressed but still below 1.0 and above the knee
        let mid = lutValue(lut, at: 1.2)
        #expect(mid > 0.9 && mid < 1.0)
        // At/above the 1.6 white point: exactly SDR white
        #expect(abs(lutValue(lut, at: 1.6) - 1.0) < 0.005)
        #expect(abs(lutValue(lut, at: 4.0) - 1.0) < 0.005)
        // Matches Apple's measured EDR=0 decode tonemap within its own scatter (~0.04)
        #expect(abs(lutValue(lut, at: 0.825) - 0.811) < 0.04)
        #expect(abs(lutValue(lut, at: 1.225) - 0.971) < 0.04)
    }

    @Test("SDR tonemap is monotone over the full domain")
    func sdrTonemapMonotone() {
        let lut = ToneCurveGenerator.generateLUT(settings: settings(headroom: true))
        for i in 1..<lut.count {
            #expect(lut[i] >= lut[i - 1] - 1e-5)
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
        let a = lutValue(lut, at: 2.0)
        let b = lutValue(lut, at: 3.0)
        #expect(a < 1.0 && b < 1.0)
        #expect(b - a > 0.1)
        // And without the flag the same inputs would clip identically at encode:
        // both stay >1.0 with no rolloff.
        let noFlag = ToneCurveGenerator.generateLUT(settings: settings(headroom: false, exposure: -1.5))
        #expect(lutValue(noFlag, at: 3.0) > 1.0)
    }

    @Test("isIdentity is false for SDR headroom sources even with no edits")
    func identityAccountsForTonemap() {
        #expect(ToneCurveGenerator.isIdentity(settings: settings(headroom: true)) == false)
        // HDR mode with no edits needs no LUT (headroom passes through)
        #expect(ToneCurveGenerator.isIdentity(settings: settings(headroom: true, hdr: true)) == true)
        // No headroom, no edits: identity as before
        #expect(ToneCurveGenerator.isIdentity(settings: settings(headroom: false)) == true)
        #expect(ToneCurveGenerator.isIdentity(settings: nil) == true)
    }
}
