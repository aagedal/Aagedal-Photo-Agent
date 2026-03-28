import AppKit
import CoreGraphics

enum WaveformScale: String, CaseIterable, Sendable {
    case percentage
    case nits

    /// SDR reference white in nits (BT.2408)
    static nonisolated let sdrWhiteNits: Float = 203
    /// Max nits shown on the waveform (logarithmic scale)
    static nonisolated let maxNits: Float = 2_000
    /// Linear light value corresponding to maxNits
    static nonisolated let maxLinear: Float = 2_000.0 / 203.0  // ~9.85

    /// Logarithmic curve constant: log10(1 + nits * k) / log10(1 + maxNits * k)
    private static nonisolated let logK: Float = 0.1
    private static nonisolated let logDenom: Float = log10(1 + 2_000 * 0.1)  // log10(201) ≈ 2.3032

    /// Map nits (0..10000) to normalized fraction (0..1) using logarithmic curve.
    nonisolated static func nitsFraction(_ nits: Float) -> Float {
        guard nits > 0 else { return 0 }
        return log10(1 + nits * logK) / logDenom
    }

    /// Map linear light value to normalized fraction for the nit axis.
    nonisolated static func linearToFraction(_ linear: Float) -> Float {
        let nits = linear * sdrWhiteNits
        return nitsFraction(min(nits, maxNits))
    }
}

/// Renders waveform, parade, and vectorscope displays from a CGImage.
/// Thread-safe: all methods operate on local state and CoreGraphics contexts.
nonisolated struct ScopeRenderService: Sendable {

    /// Reference size the fixed layout constants were designed for.
    private static let refSize: CGFloat = 720

    /// Compute layout metrics scaled proportionally to the output width.
    private static func metrics(for width: Int) -> (labelMargin: Int, verticalMargin: Int) {
        let scale = CGFloat(width) / refSize
        return (
            labelMargin: max(Int(68 * scale), 24),
            verticalMargin: max(Int(16 * scale), 4)
        )
    }

    // MARK: - Colorized Waveform

    func renderWaveform(from cgImage: CGImage, outputSize: CGSize, scale: WaveformScale) -> CGImage? {
        let outW = Int(outputSize.width)
        let outH = Int(outputSize.height)
        guard outW > 0, outH > 0 else { return nil }

        let m = Self.metrics(for: outW)
        let dataW = outW - m.labelMargin
        guard dataW > 0 else { return nil }

        let srcAspect = CGFloat(cgImage.height) / CGFloat(cgImage.width)
        let sampleH = max(Int(CGFloat(dataW) * srcAspect), 1)

        let levels = outH

        // Accumulate color per bin
        let binCount = dataW * levels
        var counts = [UInt32](repeating: 0, count: binCount)
        var sumR = [Float](repeating: 0, count: binCount)
        var sumG = [Float](repeating: 0, count: binCount)
        var sumB = [Float](repeating: 0, count: binCount)
        var hasHDR = false

        if scale == .nits, let floatData = downsampledFloatPixels(from: cgImage, width: dataW, height: sampleH) {
            let stride = dataW * 4
            for y in 0..<sampleH {
                let rowOffset = y * stride
                for x in 0..<dataW {
                    let px = rowOffset + x * 4
                    let r = floatData[px]
                    let g = floatData[px + 1]
                    let b = floatData[px + 2]
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b

                    // Map linear light to logarithmic nit scale
                    let fraction = WaveformScale.linearToFraction(luma)
                    let level = max(0, min(Int(fraction * Float(levels - 1)), levels - 1))
                    if luma > 1.0 { hasHDR = true }

                    let idx = x * levels + level
                    counts[idx] &+= 1
                    sumR[idx] += min(r, 1.0)
                    sumG[idx] += min(g, 1.0)
                    sumB[idx] += min(b, 1.0)
                }
            }
        } else {
            guard let pixelData = downsampledPixels(from: cgImage, width: dataW, height: sampleH) else {
                return nil
            }
            let stride = dataW * 4
            for y in 0..<sampleH {
                let rowOffset = y * stride
                for x in 0..<dataW {
                    let px = rowOffset + x * 4
                    let r = Float(pixelData[px]) / 255.0
                    let g = Float(pixelData[px + 1]) / 255.0
                    let b = Float(pixelData[px + 2]) / 255.0
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let level = min(Int(luma * Float(levels - 1)), levels - 1)
                    let idx = x * levels + level
                    counts[idx] &+= 1
                    sumR[idx] += r
                    sumG[idx] += g
                    sumB[idx] += b
                }
            }
        }

        var maxCount: UInt32 = 1
        for i in 0..<binCount {
            if counts[i] > maxCount { maxCount = counts[i] }
        }

        guard let ctx = createContext(width: outW, height: outH) else { return nil }
        fillBackground(ctx, width: outW, height: outH)
        drawWaveformGuides(ctx, width: outW, height: outH, dataXOffset: m.labelMargin, verticalMargin: m.verticalMargin, scale: scale, hasHDR: hasHDR)

        // Logarithmic intensity so sparse bins are still visible
        let logMax = log2f(1 + Float(maxCount))
        let gain: Float = 2.5
        guard let outputData = ctx.data?.bindMemory(to: UInt8.self, capacity: outW * outH * 4) else {
            return ctx.makeImage()
        }
        let outStride = outW * 4

        for x in 0..<dataW {
            let outX = m.labelMargin + x
            for level in 0..<levels {
                let idx = x * levels + level
                let count = counts[idx]
                guard count > 0 else { continue }

                let intensity = min(log2f(1 + Float(count)) / logMax * gain, 1.0)
                let invCount = 1.0 / Float(count)
                let avgR = sumR[idx] * invCount
                let avgG = sumG[idx] * invCount
                let avgB = sumB[idx] * invCount

                // Measure how chromatic this bin is (0 = gray, 1 = saturated)
                let gray = (avgR + avgG + avgB) / 3.0
                let maxDev = max(abs(avgR - gray), abs(avgG - gray), abs(avgB - gray))
                let saturation = min(maxDev / max(gray, 0.01), 1.0)

                // Boost saturation and normalize color to full brightness
                let satBoost: Float = 2.5
                var cR = max(gray + (avgR - gray) * satBoost, 0)
                var cG = max(gray + (avgG - gray) * satBoost, 0)
                var cB = max(gray + (avgB - gray) * satBoost, 0)
                let maxC = max(cR, cG, cB, 0.01)
                cR /= maxC; cG /= maxC; cB /= maxC

                // Blend between white and the boosted color based on saturation.
                // Low saturation → white trace; high saturation → colored trace.
                let colorMix = min(saturation * 3.0, 1.0)
                var finalR = cR * colorMix + (1.0 - colorMix)
                var finalG = cG * colorMix + (1.0 - colorMix)
                var finalB = cB * colorMix + (1.0 - colorMix)

                // In nit mode, tint HDR region orange
                if scale == .nits {
                    let sdrFraction = WaveformScale.nitsFraction(WaveformScale.sdrWhiteNits)
                    let sdrLevel = Int(Float(levels - 1) * sdrFraction)
                    if level > sdrLevel {
                        let hdrBlend: Float = 0.4
                        finalR = finalR * (1 - hdrBlend) + 1.0 * hdrBlend
                        finalG = finalG * (1 - hdrBlend) + 0.7 * hdrBlend
                        finalB = finalB * (1 - hdrBlend) + 0.2 * hdrBlend
                    }
                }

                // Map level to Y within the vertical margin inset
                let vm = m.verticalMargin
                let dataHeight = outH - vm * 2
                let mappedY = vm + (level * dataHeight) / (levels - 1)
                let yOut = outH - 1 - mappedY
                guard yOut >= 0, yOut < outH else { continue }
                let offset = yOut * outStride + outX * 4
                let existR = Float(outputData[offset]) / 255.0
                let existG = Float(outputData[offset + 1]) / 255.0
                let existB = Float(outputData[offset + 2]) / 255.0

                outputData[offset]     = UInt8(min((existR + finalR * intensity) * 255, 255))
                outputData[offset + 1] = UInt8(min((existG + finalG * intensity) * 255, 255))
                outputData[offset + 2] = UInt8(min((existB + finalB * intensity) * 255, 255))
                outputData[offset + 3] = 255
            }
        }

        return ctx.makeImage()
    }

    // MARK: - RGBY Parade

    func renderParade(from cgImage: CGImage, outputSize: CGSize, scale: WaveformScale) -> CGImage? {
        let outW = Int(outputSize.width)
        let outH = Int(outputSize.height)
        guard outW > 0, outH > 0 else { return nil }

        let m = Self.metrics(for: outW)
        let channelCount = 4
        let gap = 2
        let dataW = outW - m.labelMargin
        let totalGaps = gap * (channelCount - 1)
        let channelW = (dataW - totalGaps) / channelCount
        guard channelW > 1 else { return nil }

        let srcAspect = CGFloat(cgImage.height) / CGFloat(cgImage.width)
        let sampleW = channelW
        let sampleH = max(Int(CGFloat(channelW) * srcAspect), 1)

        let levels = outH
        let binCount = channelW * levels
        var rBins = [UInt32](repeating: 0, count: binCount)
        var gBins = [UInt32](repeating: 0, count: binCount)
        var bBins = [UInt32](repeating: 0, count: binCount)
        var yBins = [UInt32](repeating: 0, count: binCount)
        var hasHDR = false

        if scale == .nits, let floatData = downsampledFloatPixels(from: cgImage, width: sampleW, height: sampleH) {
            let stride = sampleW * 4
            for y in 0..<sampleH {
                let rowOffset = y * stride
                for x in 0..<sampleW {
                    let px = rowOffset + x * 4
                    let r = floatData[px]
                    let g = floatData[px + 1]
                    let b = floatData[px + 2]
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    if max(r, g, b) > 1.0 { hasHDR = true }

                    let levelsF = Float(levels - 1)
                    let rLevel = max(0, min(Int(WaveformScale.linearToFraction(r) * levelsF), levels - 1))
                    let gLevel = max(0, min(Int(WaveformScale.linearToFraction(g) * levelsF), levels - 1))
                    let bLevel = max(0, min(Int(WaveformScale.linearToFraction(b) * levelsF), levels - 1))
                    let yLevel = max(0, min(Int(WaveformScale.linearToFraction(luma) * levelsF), levels - 1))

                    rBins[x * levels + rLevel] &+= 1
                    gBins[x * levels + gLevel] &+= 1
                    bBins[x * levels + bLevel] &+= 1
                    yBins[x * levels + yLevel] &+= 1
                }
            }
        } else {
            guard let pixelData = downsampledPixels(from: cgImage, width: sampleW, height: sampleH) else {
                return nil
            }
            let stride = sampleW * 4
            for y in 0..<sampleH {
                let rowOffset = y * stride
                for x in 0..<sampleW {
                    let px = rowOffset + x * 4
                    let r = Float(pixelData[px]) / 255.0
                    let g = Float(pixelData[px + 1]) / 255.0
                    let b = Float(pixelData[px + 2]) / 255.0
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b

                    let rLevel = min(Int(r * Float(levels - 1)), levels - 1)
                    let gLevel = min(Int(g * Float(levels - 1)), levels - 1)
                    let bLevel = min(Int(b * Float(levels - 1)), levels - 1)
                    let yLevel = min(Int(luma * Float(levels - 1)), levels - 1)

                    rBins[x * levels + rLevel] &+= 1
                    gBins[x * levels + gLevel] &+= 1
                    bBins[x * levels + bLevel] &+= 1
                    yBins[x * levels + yLevel] &+= 1
                }
            }
        }

        var maxCount: UInt32 = 1
        for i in 0..<binCount {
            maxCount = max(maxCount, rBins[i], gBins[i], bBins[i], yBins[i])
        }

        guard let ctx = createContext(width: outW, height: outH) else { return nil }
        fillBackground(ctx, width: outW, height: outH)
        drawWaveformGuides(ctx, width: outW, height: outH, dataXOffset: m.labelMargin, verticalMargin: m.verticalMargin, scale: scale, hasHDR: hasHDR)

        guard let outputData = ctx.data?.bindMemory(to: UInt8.self, capacity: outW * outH * 4) else {
            return ctx.makeImage()
        }
        let outStride = outW * 4

        let channelColors: [(Float, Float, Float)] = [
            (1.0, 0.2, 0.2),
            (0.2, 1.0, 0.2),
            (0.3, 0.4, 1.0),
            (0.85, 0.85, 0.85)
        ]
        let allBins = [rBins, gBins, bBins, yBins]
        let logMax = log2f(1 + Float(maxCount))
        let gain: Float = 2.5

        for ch in 0..<channelCount {
            let xOffset = m.labelMargin + ch * (channelW + gap)
            let bins = allBins[ch]
            let (colR, colG, colB) = channelColors[ch]

            let vm = m.verticalMargin
            let dataHeight = outH - vm * 2

            for x in 0..<channelW {
                for level in 0..<levels {
                    let count = bins[x * levels + level]
                    guard count > 0 else { continue }
                    let intensity = min(log2f(1 + Float(count)) / logMax * gain, 1.0)
                    let outX = xOffset + x
                    let mappedY = vm + (level * dataHeight) / (levels - 1)
                    let yOut = outH - 1 - mappedY
                    guard yOut >= 0, yOut < outH else { continue }
                    let offset = yOut * outStride + outX * 4

                    let existR = Float(outputData[offset]) / 255.0
                    let existG = Float(outputData[offset + 1]) / 255.0
                    let existB = Float(outputData[offset + 2]) / 255.0

                    outputData[offset]     = UInt8(min((existR + colR * intensity) * 255, 255))
                    outputData[offset + 1] = UInt8(min((existG + colG * intensity) * 255, 255))
                    outputData[offset + 2] = UInt8(min((existB + colB * intensity) * 255, 255))
                    outputData[offset + 3] = 255
                }
            }
        }

        // Separator lines
        ctx.setStrokeColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 0.3)
        ctx.setLineWidth(1.0)
        for ch in 1..<channelCount {
            let sepX = CGFloat(m.labelMargin + ch * (channelW + gap) - gap / 2)
            ctx.move(to: CGPoint(x: sepX, y: 0))
            ctx.addLine(to: CGPoint(x: sepX, y: CGFloat(outH)))
        }
        ctx.strokePath()

        return ctx.makeImage()
    }

    // MARK: - Colorized Vectorscope

    func renderVectorscope(from cgImage: CGImage, outputSize: CGSize) -> CGImage? {
        let outW = Int(outputSize.width)
        let outH = Int(outputSize.height)
        let size = min(outW, outH)
        guard size > 0 else { return nil }

        let workSize = min(size, 360)
        let srcAspect = CGFloat(cgImage.height) / CGFloat(cgImage.width)
        let sampleW = workSize
        let sampleH = max(Int(CGFloat(workSize) * srcAspect), 1)
        guard let pixelData = downsampledPixels(from: cgImage, width: sampleW, height: sampleH) else {
            return nil
        }

        let stride = sampleW * 4
        let centerX = Float(outW) / 2.0
        let centerY = Float(outH) / 2.0
        let margin: Float = 8
        let radius = min(centerX, centerY) - margin

        struct ColorBin {
            var count: UInt32 = 0
            var sumR: Float = 0
            var sumG: Float = 0
            var sumB: Float = 0
        }
        var bins = [ColorBin](repeating: ColorBin(), count: outW * outH)

        for y in 0..<sampleH {
            let rowOffset = y * stride
            for x in 0..<sampleW {
                let px = rowOffset + x * 4
                let r = Float(pixelData[px]) / 255.0
                let g = Float(pixelData[px + 1]) / 255.0
                let b = Float(pixelData[px + 2]) / 255.0

                let cb = -0.1146 * r - 0.3854 * g + 0.5 * b
                let cr =  0.5 * r - 0.4542 * g - 0.0458 * b

                let outX = Int(centerX + cb * radius * 2)
                let outY = Int(centerY + cr * radius * 2)

                guard outX >= 0, outX < outW, outY >= 0, outY < outH else { continue }
                let idx = outY * outW + outX
                bins[idx].count &+= 1
                bins[idx].sumR += r
                bins[idx].sumG += g
                bins[idx].sumB += b
            }
        }

        var maxCount: UInt32 = 1
        for i in 0..<(outW * outH) {
            if bins[i].count > maxCount { maxCount = bins[i].count }
        }

        guard let ctx = createContext(width: outW, height: outH) else { return nil }
        fillBackground(ctx, width: outW, height: outH)

        let circleRect = CGRect(
            x: CGFloat(centerX - radius),
            y: CGFloat(centerY - radius),
            width: CGFloat(radius * 2),
            height: CGFloat(radius * 2)
        )
        ctx.setStrokeColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 0.6)
        ctx.setLineWidth(1.0)
        ctx.strokeEllipse(in: circleRect)

        ctx.move(to: CGPoint(x: CGFloat(centerX), y: CGFloat(margin)))
        ctx.addLine(to: CGPoint(x: CGFloat(centerX), y: CGFloat(Float(outH) - margin)))
        ctx.move(to: CGPoint(x: CGFloat(margin), y: CGFloat(centerY)))
        ctx.addLine(to: CGPoint(x: CGFloat(Float(outW) - margin), y: CGFloat(centerY)))
        ctx.strokePath()

        let skinAngle: Float = 2.146
        ctx.setStrokeColor(red: 0.6, green: 0.5, blue: 0.4, alpha: 0.6)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: CGFloat(centerX), y: CGFloat(centerY)))
        ctx.addLine(to: CGPoint(
            x: CGFloat(centerX + cos(skinAngle) * radius),
            y: CGFloat(centerY + sin(skinAngle) * radius)
        ))
        ctx.strokePath()

        drawColorTargets(ctx, centerX: centerX, centerY: centerY, radius: radius)

        // Logarithmic intensity: makes sparse bins visible while keeping dense areas bright
        let logMax = log2f(1 + Float(maxCount))
        let gain: Float = 3.0
        guard let outputData = ctx.data?.bindMemory(to: UInt8.self, capacity: outW * outH * 4) else {
            return ctx.makeImage()
        }
        let outStride = outW * 4

        for py in 0..<outH {
            for px in 0..<outW {
                let idx = py * outW + px
                let count = bins[idx].count
                guard count > 0 else { continue }

                let intensity = min(log2f(1 + Float(count)) / logMax * gain, 1.0)
                let invCount = 1.0 / Float(count)
                var avgR = bins[idx].sumR * invCount
                var avgG = bins[idx].sumG * invCount
                var avgB = bins[idx].sumB * invCount

                let gray = (avgR + avgG + avgB) / 3.0
                let satBoost: Float = 2.0
                avgR = max(gray + (avgR - gray) * satBoost, 0.05)
                avgG = max(gray + (avgG - gray) * satBoost, 0.05)
                avgB = max(gray + (avgB - gray) * satBoost, 0.05)

                let maxC = max(avgR, avgG, avgB, 0.01)
                avgR /= maxC
                avgG /= maxC
                avgB /= maxC

                let flippedY = outH - 1 - py
                let offset = flippedY * outStride + px * 4

                let existR = Float(outputData[offset]) / 255.0
                let existG = Float(outputData[offset + 1]) / 255.0
                let existB = Float(outputData[offset + 2]) / 255.0

                outputData[offset]     = UInt8(min((existR + avgR * intensity) * 255, 255))
                outputData[offset + 1] = UInt8(min((existG + avgG * intensity) * 255, 255))
                outputData[offset + 2] = UInt8(min((existB + avgB * intensity) * 255, 255))
                outputData[offset + 3] = 255
            }
        }

        return ctx.makeImage()
    }

    // MARK: - CIE 1931 Chromaticity Diagram

    func renderChromaticity(from cgImage: CGImage, outputSize: CGSize, clipped: Bool, targetGamut: TargetColorGamut) -> CGImage? {
        let outW = Int(outputSize.width)
        let outH = Int(outputSize.height)
        let size = min(outW, outH)
        guard size > 0 else { return nil }

        // Downsample — use float pixels to preserve out-of-gamut values
        let workSize = min(size, 360)
        let srcAspect = CGFloat(cgImage.height) / CGFloat(cgImage.width)
        let sampleW = workSize
        let sampleH = max(Int(CGFloat(workSize) * srcAspect), 1)
        guard let floatData = downsampledFloatPixels(from: cgImage, width: sampleW, height: sampleH) else {
            return nil
        }

        let stride = sampleW * 4

        // Viewport: CIE xy mapped to output pixels
        let xyMin: Float = -0.05
        let xyRange: Float = 0.90  // [-0.05, 0.85]

        // Row-major 3×3 matrix type (row0, row1, row2)
        typealias Mat3 = (r0: (Float, Float, Float), r1: (Float, Float, Float), r2: (Float, Float, Float))

        let sRGBtoXYZMat: Mat3 = (
            (0.4124564, 0.3575761, 0.1804375),
            (0.2126729, 0.7151522, 0.0721750),
            (0.0193339, 0.1191920, 0.9503041)
        )

        let p3toXYZMat: Mat3 = (
            (0.4865709, 0.2656677, 0.1982173),
            (0.2289746, 0.6917385, 0.0792869),
            (0.0000000, 0.0451134, 1.0439444)
        )

        let rec2020toXYZMat: Mat3 = (
            (0.6369580, 0.1446169, 0.1688810),
            (0.2627002, 0.6779981, 0.0593017),
            (0.0000000, 0.0280727, 1.0609851)
        )

        let sRGBtoP3Mat: Mat3 = (
            ( 0.8225929,  0.1775339, 0.0),
            ( 0.0331995,  0.9667835, 0.0),
            ( 0.0170854,  0.0723957, 0.9103014)
        )

        let sRGBtoRec2020Mat: Mat3 = (
            ( 0.6275037,  0.3292755,  0.0433027),
            ( 0.0691084,  0.9195192,  0.0113596),
            ( 0.0163940,  0.0880112,  0.8953803)
        )

        // Helper: row-major mat3 × vec3
        func dot3(_ row: (Float, Float, Float), _ r: Float, _ g: Float, _ b: Float) -> Float {
            row.0 * r + row.1 * g + row.2 * b
        }

        // Accumulation bins (same as vectorscope)
        struct ColorBin {
            var count: UInt32 = 0
            var sumR: Float = 0
            var sumG: Float = 0
            var sumB: Float = 0
        }
        var bins = [ColorBin](repeating: ColorBin(), count: outW * outH)

        for y in 0..<sampleH {
            let rowOffset = y * stride
            for x in 0..<sampleW {
                let px = rowOffset + x * 4
                var r = floatData[px]
                var g = floatData[px + 1]
                var b = floatData[px + 2]
                let a = floatData[px + 3]

                // Undo premultiplied alpha if needed
                if a > 0.001 && a < 0.999 {
                    let invA = 1.0 / a
                    r *= invA; g *= invA; b *= invA
                }

                // Already in linear extended sRGB
                var xyzMatrix = sRGBtoXYZMat

                if clipped {
                    switch targetGamut {
                    case .sRGB:
                        r = max(0, min(r, 1)); g = max(0, min(g, 1)); b = max(0, min(b, 1))
                    case .displayP3:
                        let pr = dot3(sRGBtoP3Mat.r0, r, g, b)
                        let pg = dot3(sRGBtoP3Mat.r1, r, g, b)
                        let pb = dot3(sRGBtoP3Mat.r2, r, g, b)
                        r = max(0, min(pr, 1)); g = max(0, min(pg, 1)); b = max(0, min(pb, 1))
                        xyzMatrix = p3toXYZMat
                    case .rec2020:
                        let rr = dot3(sRGBtoRec2020Mat.r0, r, g, b)
                        let rg = dot3(sRGBtoRec2020Mat.r1, r, g, b)
                        let rb = dot3(sRGBtoRec2020Mat.r2, r, g, b)
                        r = max(0, min(rr, 1)); g = max(0, min(rg, 1)); b = max(0, min(rb, 1))
                        xyzMatrix = rec2020toXYZMat
                    }
                }

                let X = dot3(xyzMatrix.r0, r, g, b)
                let Y = dot3(xyzMatrix.r1, r, g, b)
                let Z = dot3(xyzMatrix.r2, r, g, b)
                let sum = X + Y + Z
                guard sum > 0.001 else { continue }

                let cx = X / sum
                let cy = Y / sum

                // Map to output coordinates
                let outX = Int((cx - xyMin) / xyRange * Float(outW - 1))
                let outY = outH - 1 - Int((cy - xyMin) / xyRange * Float(outH - 1))

                guard outX >= 0, outX < outW, outY >= 0, outY < outH else { continue }
                let idx = outY * outW + outX
                bins[idx].count &+= 1
                // For display color, use sRGB-clamped values
                bins[idx].sumR += min(max(floatData[px], 0), 1)
                bins[idx].sumG += min(max(floatData[px + 1], 0), 1)
                bins[idx].sumB += min(max(floatData[px + 2], 0), 1)
            }
        }

        var maxCount: UInt32 = 1
        for i in 0..<(outW * outH) {
            if bins[i].count > maxCount { maxCount = bins[i].count }
        }

        guard let ctx = createContext(width: outW, height: outH) else { return nil }
        fillBackground(ctx, width: outW, height: outH)

        // Step 1: All CGContext API drawing first (guides use CG coordinate system: origin at bottom-left)
        drawChromaticityGuides(ctx, width: outW, height: outH, xyMin: xyMin, xyRange: xyRange, targetGamut: targetGamut)

        // Step 2: All raw pixel data operations (row 0 = CG y=height-1 = top of image)
        guard let outputData = ctx.data?.bindMemory(to: UInt8.self, capacity: outW * outH * 4) else {
            return ctx.makeImage()
        }
        let outStride = outW * 4

        // Draw dim colorful CIE background into raw pixel data
        drawChromaticityBackground(outputData, width: outW, height: outH, stride: outStride, xyMin: xyMin, xyRange: xyRange)

        // Render bin data (logarithmic intensity, same as vectorscope)
        let logMax = log2f(1 + Float(maxCount))
        let gain: Float = 3.0

        for py in 0..<outH {
            for px in 0..<outW {
                let idx = py * outW + px
                let count = bins[idx].count
                guard count > 0 else { continue }

                let intensity = min(log2f(1 + Float(count)) / logMax * gain, 1.0)
                let invCount = 1.0 / Float(count)
                var avgR = bins[idx].sumR * invCount
                var avgG = bins[idx].sumG * invCount
                var avgB = bins[idx].sumB * invCount

                // Saturation boost (matches vectorscope)
                let gray = (avgR + avgG + avgB) / 3.0
                let satBoost: Float = 2.0
                avgR = max(gray + (avgR - gray) * satBoost, 0.05)
                avgG = max(gray + (avgG - gray) * satBoost, 0.05)
                avgB = max(gray + (avgB - gray) * satBoost, 0.05)

                let maxC = max(avgR, avgG, avgB, 0.01)
                avgR /= maxC
                avgG /= maxC
                avgB /= maxC

                let offset = py * outStride + px * 4
                let existR = Float(outputData[offset]) / 255.0
                let existG = Float(outputData[offset + 1]) / 255.0
                let existB = Float(outputData[offset + 2]) / 255.0

                outputData[offset]     = UInt8(min((existR + avgR * intensity) * 255, 255))
                outputData[offset + 1] = UInt8(min((existG + avgG * intensity) * 255, 255))
                outputData[offset + 2] = UInt8(min((existB + avgB * intensity) * 255, 255))
                outputData[offset + 3] = 255
            }
        }

        return ctx.makeImage()
    }

    // MARK: - Chromaticity Helpers

    /// CIE 1931 2° observer spectral locus (xy coordinates, 5nm intervals, 380–780nm)
    private static let spectralLocus: [(x: Float, y: Float)] = [
        (0.1741, 0.0050), // 380
        (0.1740, 0.0050), // 385
        (0.1738, 0.0049), // 390
        (0.1736, 0.0049), // 395
        (0.1733, 0.0048), // 400
        (0.1726, 0.0048), // 405
        (0.1714, 0.0051), // 410
        (0.1689, 0.0069), // 415
        (0.1644, 0.0109), // 420
        (0.1566, 0.0177), // 425
        (0.1440, 0.0297), // 430
        (0.1241, 0.0578), // 435
        (0.0913, 0.1327), // 440
        (0.0687, 0.2007), // 445
        (0.0454, 0.2950), // 450
        (0.0235, 0.4127), // 455
        (0.0082, 0.5384), // 460
        (0.0039, 0.6548), // 465
        (0.0139, 0.7502), // 470
        (0.0389, 0.8120), // 475
        (0.0743, 0.8338), // 480
        (0.1142, 0.8262), // 485
        (0.1547, 0.8059), // 490
        (0.1929, 0.7816), // 495
        (0.2296, 0.7543), // 500
        (0.2658, 0.7243), // 505
        (0.3016, 0.6923), // 510
        (0.3373, 0.6589), // 515
        (0.3731, 0.6245), // 520
        (0.4087, 0.5896), // 525
        (0.4441, 0.5547), // 530
        (0.4788, 0.5202), // 535
        (0.5125, 0.4866), // 540
        (0.5448, 0.4544), // 545
        (0.5752, 0.4242), // 550
        (0.6029, 0.3965), // 555
        (0.6270, 0.3725), // 560
        (0.6482, 0.3514), // 565
        (0.6658, 0.3340), // 570
        (0.6801, 0.3197), // 575
        (0.6915, 0.3083), // 580
        (0.7006, 0.2993), // 585
        (0.7079, 0.2920), // 590
        (0.7140, 0.2859), // 595
        (0.7190, 0.2809), // 600
        (0.7230, 0.2770), // 605
        (0.7260, 0.2740), // 610
        (0.7283, 0.2717), // 615
        (0.7300, 0.2700), // 620
        (0.7311, 0.2689), // 625
        (0.7320, 0.2680), // 630
        (0.7327, 0.2673), // 635
        (0.7334, 0.2666), // 640
        (0.7340, 0.2660), // 645
        (0.7344, 0.2656), // 650
        (0.7346, 0.2654), // 655
        (0.7347, 0.2653), // 660
        (0.7347, 0.2653), // 665
        (0.7347, 0.2653), // 670
        (0.7347, 0.2653), // 675
        (0.7347, 0.2653), // 680
        (0.7347, 0.2653), // 685
        (0.7347, 0.2653), // 690
        (0.7347, 0.2653), // 695
        (0.7347, 0.2653), // 700
        (0.7347, 0.2653), // 705
        (0.7347, 0.2653), // 710
        (0.7347, 0.2653), // 715
        (0.7347, 0.2653), // 720
        (0.7347, 0.2653), // 725
        (0.7347, 0.2653), // 730
        (0.7347, 0.2653), // 735
        (0.7347, 0.2653), // 740
        (0.7347, 0.2653), // 745
        (0.7347, 0.2653), // 750
        (0.7347, 0.2653), // 755
        (0.7347, 0.2653), // 760
        (0.7347, 0.2653), // 765
        (0.7347, 0.2653), // 770
        (0.7347, 0.2653), // 775
        (0.7347, 0.2653), // 780
    ]

    /// Gamut triangle primary coordinates in CIE xy
    private static let gamutTriangles: [(name: String, primaries: [(x: Float, y: Float)], color: (r: CGFloat, g: CGFloat, b: CGFloat))] = [
        ("Rec. 2020", [(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)], (0.3, 0.8, 0.9)),
        ("Display P3", [(0.680, 0.320), (0.265, 0.690), (0.150, 0.060)], (0.9, 0.6, 0.2)),
        ("sRGB", [(0.640, 0.330), (0.300, 0.600), (0.150, 0.060)], (0.8, 0.8, 0.8)),
    ]

    /// Point-in-polygon test for the spectral locus
    private static func isInsideSpectralLocus(x: Float, y: Float) -> Bool {
        let polygon = spectralLocus
        let n = polygon.count
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let xi = polygon[i].x, yi = polygon[i].y
            let xj = polygon[j].x, yj = polygon[j].y
            if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
                inside = !inside
            }
            j = i
        }
        return inside
    }

    /// Draw dim colorful CIE background inside the spectral locus.
    /// Writes directly to raw pixel data (row 0 = top of image).
    private func drawChromaticityBackground(_ outputData: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride outStride: Int, xyMin: Float, xyRange: Float) {
        // XYZ -> sRGB matrix (row-major)
        let xyzToSRGB: ((Float, Float, Float), (Float, Float, Float), (Float, Float, Float)) = (
            ( 3.2404548, -1.5371389, -0.4985315),
            (-0.9692664,  1.8760109,  0.0415561),
            ( 0.0556434, -0.2040259,  1.0572252)
        )

        func dot3(_ row: (Float, Float, Float), _ a: Float, _ b: Float, _ c: Float) -> Float {
            row.0 * a + row.1 * b + row.2 * c
        }

        let dimFactor: Float = 0.12

        for py in 0..<height {
            for px in 0..<width {
                // Raw data row 0 = top of image = high CIE y
                let cx = xyMin + (Float(px) + 0.5) / Float(width) * xyRange
                let cy = xyMin + (Float(height - 1 - py) + 0.5) / Float(height) * xyRange

                guard Self.isInsideSpectralLocus(x: cx, y: cy), cy > 0.001 else { continue }

                // Convert xy to XYZ (Y=0.5 for moderate luminance)
                let cY: Float = 0.5
                let cX = (cx / cy) * cY
                let cZ = ((1.0 - cx - cy) / cy) * cY

                var r = dot3(xyzToSRGB.0, cX, cY, cZ)
                var g = dot3(xyzToSRGB.1, cX, cY, cZ)
                var b = dot3(xyzToSRGB.2, cX, cY, cZ)

                // Clamp and apply dim factor
                r = max(r, 0); g = max(g, 0); b = max(b, 0)
                let maxC = max(r, g, b, 0.001)
                r /= maxC; g /= maxC; b /= maxC
                r *= dimFactor; g *= dimFactor; b *= dimFactor

                let offset = py * outStride + px * 4
                outputData[offset]     = UInt8(r * 255)
                outputData[offset + 1] = UInt8(g * 255)
                outputData[offset + 2] = UInt8(b * 255)
                outputData[offset + 3] = 255
            }
        }
    }

    /// Draw spectral locus outline, gamut triangles, and D65 white point
    private func drawChromaticityGuides(_ ctx: CGContext, width: Int, height: Int, xyMin: Float, xyRange: Float, targetGamut: TargetColorGamut) {
        // Helper to convert CIE xy to CGContext coordinates (origin at bottom-left, y increases upward)
        func toPixel(x: Float, y: Float) -> CGPoint {
            let px = CGFloat((x - xyMin) / xyRange * Float(width - 1))
            let py = CGFloat((y - xyMin) / xyRange * Float(height - 1))
            return CGPoint(x: px, y: py)
        }

        // Spectral locus outline
        ctx.setStrokeColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 0.8)
        ctx.setLineWidth(1.5)
        let locus = Self.spectralLocus
        if let first = locus.first {
            ctx.move(to: toPixel(x: first.x, y: first.y))
            for i in 1..<locus.count {
                ctx.addLine(to: toPixel(x: locus[i].x, y: locus[i].y))
            }
            // Purple line closure
            ctx.addLine(to: toPixel(x: first.x, y: first.y))
        }
        ctx.strokePath()

        // Gamut triangles
        let targetName: String
        switch targetGamut {
        case .sRGB: targetName = "sRGB"
        case .displayP3: targetName = "Display P3"
        case .rec2020: targetName = "Rec. 2020"
        }

        for triangle in Self.gamutTriangles {
            let isTarget = triangle.name == targetName
            let alpha: CGFloat = isTarget ? 0.7 : 0.3
            let lineWidth: CGFloat = isTarget ? 2.0 : 1.0

            ctx.setStrokeColor(red: triangle.color.r, green: triangle.color.g, blue: triangle.color.b, alpha: alpha)
            ctx.setLineWidth(lineWidth)

            let p0 = toPixel(x: triangle.primaries[0].x, y: triangle.primaries[0].y)
            let p1 = toPixel(x: triangle.primaries[1].x, y: triangle.primaries[1].y)
            let p2 = toPixel(x: triangle.primaries[2].x, y: triangle.primaries[2].y)
            ctx.move(to: p0)
            ctx.addLine(to: p1)
            ctx.addLine(to: p2)
            ctx.addLine(to: p0)
            ctx.strokePath()
        }

        // D65 white point crosshair
        let d65 = toPixel(x: 0.3127, y: 0.3290)
        let armLen: CGFloat = 5
        ctx.setStrokeColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 0.7)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: d65.x - armLen, y: d65.y))
        ctx.addLine(to: CGPoint(x: d65.x + armLen, y: d65.y))
        ctx.move(to: CGPoint(x: d65.x, y: d65.y - armLen))
        ctx.addLine(to: CGPoint(x: d65.x, y: d65.y + armLen))
        ctx.strokePath()
    }

    // MARK: - Guide Lines & Labels

    /// Draw guide lines only (labels are rendered by the shared SwiftUI ScopeLabelsOverlay).
    private func drawWaveformGuides(_ ctx: CGContext, width: Int, height: Int, dataXOffset: Int, verticalMargin: Int, scale: WaveformScale, hasHDR: Bool) {
        let vm = CGFloat(verticalMargin)
        let dataHeight = CGFloat(height) - vm * 2

        switch scale {
        case .percentage:
            let fractions: [CGFloat] = [0.0, 0.25, 0.5, 0.75, 1.0]
            for fraction in fractions {
                let yPos = vm + fraction * dataHeight
                ctx.setStrokeColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 0.6)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: CGFloat(dataXOffset), y: yPos))
                ctx.addLine(to: CGPoint(x: CGFloat(width), y: yPos))
                ctx.strokePath()
            }

        case .nits:
            let sdrFraction = CGFloat(WaveformScale.nitsFraction(WaveformScale.sdrWhiteNits))

            let nitValues: [Float] = [0, 100, 500, 1000, 2000]
            for nits in nitValues {
                let fraction = CGFloat(WaveformScale.nitsFraction(nits))
                let yPos = vm + fraction * dataHeight
                ctx.setStrokeColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 0.5)
                ctx.setLineWidth(1.0)
                ctx.move(to: CGPoint(x: CGFloat(dataXOffset), y: yPos))
                ctx.addLine(to: CGPoint(x: CGFloat(width), y: yPos))
                ctx.strokePath()
            }

            // SDR white line (203 nits) — orange
            let sdrY = vm + sdrFraction * dataHeight
            ctx.setStrokeColor(red: 0.9, green: 0.65, blue: 0.2, alpha: 0.7)
            ctx.setLineWidth(2.0)
            ctx.move(to: CGPoint(x: CGFloat(dataXOffset), y: sdrY))
            ctx.addLine(to: CGPoint(x: CGFloat(width), y: sdrY))
            ctx.strokePath()

            // HDR region tint overlay (subtle warm tint above SDR)
            if hasHDR {
                let topY = vm + dataHeight
                let hdrRegionHeight = topY - sdrY
                if hdrRegionHeight > 0 {
                    ctx.setFillColor(red: 0.15, green: 0.12, blue: 0.08, alpha: 1.0)
                    ctx.fill(CGRect(x: CGFloat(dataXOffset), y: sdrY, width: CGFloat(width - dataXOffset), height: hdrRegionHeight))
                }
            }
        }
    }

    // MARK: - Vectorscope Helpers

    private func drawColorTargets(_ ctx: CGContext, centerX: Float, centerY: Float, radius: Float) {
        // BT.709 75% color bar targets
        let targets: [(cb: Float, cr: Float, r: CGFloat, g: CGFloat, b: CGFloat)] = [
            (-0.0860,  0.3750, 0.7, 0.15, 0.15),   // Red
            ( 0.2891,  0.3407, 0.7, 0.15, 0.7),     // Magenta
            ( 0.3750, -0.0344, 0.15, 0.15, 0.7),    // Blue
            ( 0.0860, -0.3750, 0.15, 0.7, 0.7),     // Cyan
            (-0.2891, -0.3407, 0.15, 0.7, 0.15),    // Green
            (-0.3750,  0.0344, 0.7, 0.7, 0.15),     // Yellow
        ]

        ctx.setLineWidth(2.5)
        let boxSize: CGFloat = 18
        for target in targets {
            let x = CGFloat(centerX + target.cb * radius * 2)
            let y = CGFloat(centerY + target.cr * radius * 2)
            let rect = CGRect(x: x - boxSize / 2, y: y - boxSize / 2, width: boxSize, height: boxSize)
            ctx.setStrokeColor(red: target.r, green: target.g, blue: target.b, alpha: 0.85)
            ctx.stroke(rect)
        }
    }

    // MARK: - Pixel Helpers

    /// Downsample to 8-bit RGBA (clips HDR values to 0-255).
    /// Uses explicit sRGB so linear-space inputs (e.g. from the edit pipeline) are gamma-converted correctly.
    private func downsampledPixels(from cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    /// Downsample to 32-bit float RGBA in extended linear sRGB, preserving HDR values >1.0.
    private func downsampledFloatPixels(from cgImage: CGImage, width: Int, height: Int) -> [Float]? {
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        var pixels = [Float](repeating: 0, count: height * width * 4)
        let bitmapInfo = CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let ctx = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
              ) else { return nil }

        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private func createContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private func fillBackground(_ ctx: CGContext, width: Int, height: Int) {
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
}
