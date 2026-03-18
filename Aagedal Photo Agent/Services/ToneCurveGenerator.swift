import Foundation

/// Generates a 1D lookup table (4096 entries) combining all tonal operations
/// (Exposure, Contrast, Blacks, Shadows, Highlights, Whites) into a single array.
/// Both the Metal compute shader (preview) and CIFilter export path use this LUT data,
/// ensuring preview-final consistency with ACR-calibrated tone curves.
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

            // 1. Exposure: x * exp2(ev), then ACR-style soft-clip above threshold.
            //    Compresses highlights to prevent hard clipping (matches ACR Process Version 2012).
            x *= exp2f(ev)
            if abs(ev) > 0.0001 {
                let threshold: Float = 0.7
                let strength: Float = 0.5
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
                let gain = 1.0 + contrast * 0.8 * (1.0 - falloff)
                x = 0.5 + centered * max(gain, 0.1)
            }

            // 3. Blacks: tapered shadow-region adjustment.
            //    ACR: delta = amount * max(0, 1 - x/0.3)^2
            if abs(blacks) > 0.001 {
                let shadowRegion = max(Float(0), 1.0 - x / 0.3)
                x += blacks * 0.3 * shadowRegion * shadowRegion
            }

            // 4. Shadows: Gaussian-weighted lift centered at ~0.18.
            if abs(shadows) > 0.001 {
                let center: Float = 0.18
                let width: Float = 0.15
                let dist = (x - center) / width
                x += shadows * 0.25 * expf(-0.5 * dist * dist)
            }

            // 5. Highlights: Gaussian-weighted adjustment centered at ~0.75.
            if abs(highlights) > 0.001 {
                let center: Float = 0.75
                let width: Float = 0.2
                let dist = (x - center) / width
                x += highlights * 0.25 * expf(-0.5 * dist * dist)
            }

            // 6. Whites: tapered highlight-region adjustment.
            //    ACR: delta = amount * max(0, (x-0.7)/0.3)^2
            if abs(whites) > 0.001 {
                let highlightRegion = max(Float(0), (x - 0.7) / 0.3)
                x += whites * 0.5 * highlightRegion * highlightRegion
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
