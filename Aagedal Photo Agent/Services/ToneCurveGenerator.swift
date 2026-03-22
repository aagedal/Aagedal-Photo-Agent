import Foundation

/// Generates a 1D lookup table (4096 entries) combining all tonal operations
/// (Exposure, Contrast, Blacks, Shadows, Highlights, Whites) into a single array.
/// Both the Metal compute shader (preview) and CIFilter export path use this LUT data,
/// ensuring preview-final consistency with ACR-calibrated tone curves.
///
/// Coefficients calibrated against Adobe Camera Raw Process Version 2012 using
/// the calibration pipeline in calibration/.
nonisolated struct ToneCurveGenerator: Sendable {
    static let lutSize = 4096
    static let domainMin: Float = -0.5   // Handle negative from color matrix overshoot
    static let domainMax: Float = 4.0    // HDR headroom

    /// Generates a 1D LUT from CameraRawSettings.
    /// Maps input values in [domainMin, domainMax] to output values.
    /// Operations applied in order: Exposure, Contrast, Blacks, Shadows, Highlights, Whites.
    static func generateLUT(settings: CameraRawSettings?) -> [Float] {
        let range = domainMax - domainMin

        let ev = Float(settings?.exposure2012 ?? 0)
        let contrast = Float(settings?.contrast2012 ?? 0) / 100.0
        let blacks = Float(settings?.blacks2012 ?? 0) / 100.0
        let shadows = Float(settings?.shadows2012 ?? 0) / 100.0
        let highlights = Float(settings?.highlights2012 ?? 0) / 100.0
        let whites = Float(settings?.whites2012 ?? 0) / 100.0

        var lut = [Float](repeating: 0, count: lutSize)

        for i in 0..<lutSize {
            let t = Float(i) / Float(lutSize - 1)
            var x = domainMin + t * range

            // 1. Exposure: x * exp2(ev), then ACR-style progressive highlight compression.
            //    Strength scales with EV: gentle at +1, aggressive at +3.
            //    The rational function y/(1+y*s) asymptotes to threshold + 1/strength,
            //    preserving HDR headroom proportional to the exposure boost.
            x *= exp2f(ev)
            if ev > 0.001 {
                let threshold: Float = 0.7
                let strength: Float = 1.0 + ev * 0.45
                let overshoot = max(Float(0), x - threshold)
                if overshoot > 0 {
                    x = threshold + overshoot / (1.0 + overshoot * strength)
                }
            }

            // 2. Contrast: parametric sigmoid centered at 0.5.
            //    ACR: 0.5 + (x-0.5) * gain where gain peaks at midtones, falls at extremes.
            if abs(contrast) > 0.001 {
                let centered = x - 0.5
                let falloff = min(4.0 * centered * centered, 1.0)
                let gain = 1.0 + contrast * 0.7 * (1.0 - falloff)
                x = 0.5 + centered * max(gain, 0.1)
            }

            // 3. Blacks: tapered shadow-region adjustment in sqrt-space.
            //    Working in sqrt-space gives perceptually uniform deltas across the
            //    shadow region (a constant sqrt-space delta produces uniform sRGB change).
            //    Negative blacks have a wider reach than positive (ACR crushes blacks
            //    across a broader range, extending to ~sRGB 0.50).
            if abs(blacks) > 0.001 {
                let px = sqrtf(max(Float(0), x))
                let boundary: Float = blacks < 0 ? 0.50 : 0.35
                let amplitude: Float = blacks < 0 ? 0.14 : 0.10
                let shadowRegion = max(Float(0), 1.0 - px / boundary)
                let delta = blacks * amplitude * shadowRegion
                let pxNew = max(Float(0), px + delta)
                x = pxNew * pxNew
            }

            // 4. Shadows: Gaussian-weighted lift in sqrt-space.
            //    Center at sqrt(~0.02) ≈ 0.15 targets the sRGB 0.05-0.15 range
            //    where ACR's shadow adjustment peaks.
            if abs(shadows) > 0.001 {
                let px = sqrtf(max(Float(0), x))
                let center: Float = 0.15
                let width: Float = 0.15
                let dist = (px - center) / width
                let delta = shadows * 0.08 * expf(-0.5 * dist * dist)
                let pxNew = max(Float(0), px + delta)
                x = pxNew * pxNew
            }

            // 5. Highlights: one-sided ramp that only affects upper tones.
            //    ACR highlights leave shadows/blacks untouched — the adjustment ramps in
            //    smoothly from a knee point and peaks in the bright range. Uses a smooth
            //    ramp (cubic ease-in) starting at linear ~0.15 (sRGB ~0.42), peaking
            //    around linear 0.60-0.80. No effect below the knee.
            if abs(highlights) > 0.001 {
                let knee: Float = 0.15
                if x > knee {
                    let t = min((x - knee) / 0.85, 1.0) // 0 at knee, 1 at linear 1.0
                    // Bell-shaped weight: ramps up from knee, peaks ~0.6, tapers at top
                    let weight = t * t * (3.0 - 2.0 * t) * (1.0 - t * t * 0.3)
                    x += highlights * 0.30 * weight
                }
            }

            // 6. Whites: adjusts the upper tone range (sRGB ~75-100%).
            //    Positive: lifts the entire 75-100% range (not just the peak).
            //    Negative: compresses highlights toward ~75% without inverting —
            //    the brightest values stay brightest, maintaining contrast.
            //    Uses a smooth ramp from linear 0.45 (sRGB ~0.70).
            if abs(whites) > 0.001 {
                let knee: Float = 0.45
                if x > knee {
                    let t = (x - knee) / (1.0 - knee) // 0 at knee, 1 at linear 1.0
                    let tClamped = min(t, 2.0) // allow some HDR headroom
                    if whites > 0 {
                        // Positive: smooth ramp, stronger at top
                        let weight = tClamped * (2.0 - tClamped) // parabolic, peaks at t=1
                        x += whites * 1.2 * weight
                    } else {
                        // Negative: compress toward knee, preserving order.
                        // At t=1 (brightest), pull down most. At t=0 (knee), no change.
                        // Use sqrt taper so mid-highlights compress more evenly.
                        let pull = sqrtf(tClamped) * 0.25
                        x -= abs(whites) * pull * (1.0 - knee)
                    }
                }
            }

            lut[i] = x
        }

        return lut
    }

    /// Returns true if no tonal adjustments are active (LUT would be identity).
    static func isIdentity(settings: CameraRawSettings?) -> Bool {
        guard let s = settings else { return true }
        return (s.exposure2012 == nil || abs(s.exposure2012!) < 0.0001)
            && s.contrast2012 == nil
            && s.highlights2012 == nil
            && s.shadows2012 == nil
            && s.whites2012 == nil
            && s.blacks2012 == nil
            && s.toneCurve == nil
    }

    /// Generates per-channel LUTs (R, G, B), each 4096 entries.
    /// Applies slider-based tonal operations first, then composes custom curve on top.
    static func generatePerChannelLUT(settings: CameraRawSettings?) -> (r: [Float], g: [Float], b: [Float]) {
        let baseLUT = generateLUT(settings: settings)
        let curve = settings?.toneCurve

        // Apply master curve, then per-channel curves
        let masterPoints = curve?.master
        let rPoints = curve?.red
        let gPoints = curve?.green
        let bPoints = curve?.blue

        let hasMaster = (masterPoints?.count ?? 0) > 2
        let hasR = rPoints != nil
        let hasG = gPoints != nil
        let hasB = bPoints != nil

        if !hasMaster && !hasR && !hasG && !hasB {
            // No curves — all channels identical
            return (baseLUT, baseLUT, baseLUT)
        }

        let range = domainMax - domainMin
        var rLUT = [Float](repeating: 0, count: lutSize)
        var gLUT = [Float](repeating: 0, count: lutSize)
        var bLUT = [Float](repeating: 0, count: lutSize)

        for i in 0..<lutSize {
            var val = baseLUT[i]

            // Normalize to [0,1] for curve application
            let normalized = max(0, min(1, (val - domainMin) / range))

            // Apply master curve
            var masterOut = hasMaster ? evaluateCatmullRom(masterPoints!, at: Double(normalized)) : Double(normalized)
            masterOut = max(0, min(1, masterOut))

            // Apply per-channel curves on top of master
            let rOut = hasR ? evaluateCatmullRom(rPoints!, at: masterOut) : masterOut
            let gOut = hasG ? evaluateCatmullRom(gPoints!, at: masterOut) : masterOut
            let bOut = hasB ? evaluateCatmullRom(bPoints!, at: masterOut) : masterOut

            // Map back to LUT domain
            rLUT[i] = domainMin + Float(max(0, min(1, rOut))) * range
            gLUT[i] = domainMin + Float(max(0, min(1, gOut))) * range
            bLUT[i] = domainMin + Float(max(0, min(1, bOut))) * range
        }

        return (rLUT, gLUT, bLUT)
    }

    /// Evaluates a Catmull-Rom spline through sorted control points at the given x.
    /// Points must be sorted by x. Endpoints are clamped.
    static func evaluateCatmullRom(_ points: [ToneCurvePoint], at x: Double) -> Double {
        guard points.count >= 2 else { return x }

        // Clamp to endpoint values
        if x <= points.first!.x { return points.first!.y }
        if x >= points.last!.x { return points.last!.y }

        // Find the segment containing x
        var segIndex = 0
        for i in 0..<(points.count - 1) {
            if x >= points[i].x && x < points[i + 1].x {
                segIndex = i
                break
            }
        }

        // Four control points for Catmull-Rom: p0, p1, p2, p3
        let p1 = points[segIndex]
        let p2 = points[segIndex + 1]
        // Mirror endpoints for boundary segments
        let p0 = segIndex > 0 ? points[segIndex - 1] : ToneCurvePoint(x: 2 * p1.x - p2.x, y: 2 * p1.y - p2.y)
        let p3 = segIndex + 2 < points.count ? points[segIndex + 2] : ToneCurvePoint(x: 2 * p2.x - p1.x, y: 2 * p2.y - p1.y)

        let segLen = p2.x - p1.x
        guard segLen > 0 else { return p1.y }
        let t = (x - p1.x) / segLen
        let t2 = t * t
        let t3 = t2 * t

        // Catmull-Rom basis (tension = 0.5)
        let y = 0.5 * (
            (2 * p1.y)
            + (-p0.y + p2.y) * t
            + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
            + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
        )
        return y
    }

    /// Samples the LUT at 5 evenly-spaced points in [0, 1] for CIToneCurve approximation.
    /// Uses linear interpolation between LUT entries for smooth sampling.
    static func sampleForToneCurve(_ lut: [Float]) -> [(x: CGFloat, y: CGFloat)] {
        let range = domainMax - domainMin

        return [Float(0.0), 0.25, 0.5, 0.75, 1.0].map { x in
            let t = (x - domainMin) / range
            let fIndex = t * Float(lutSize - 1)
            let i0 = min(max(Int(fIndex), 0), lutSize - 2)
            let i1 = i0 + 1
            let frac = fIndex - Float(i0)
            let y = lut[i0] * (1.0 - frac) + lut[i1] * frac
            return (x: CGFloat(x), y: CGFloat(y))
        }
    }
}
