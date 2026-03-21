import AppKit
import CoreGraphics
import CoreText

enum WaveformScale: String, CaseIterable, Sendable {
    case percentage
    case nits

    /// SDR reference white in nits (BT.2408)
    static nonisolated let sdrWhiteNits: Float = 203
    /// Max nits shown on the waveform (logarithmic scale)
    static nonisolated let maxNits: Float = 10_000
    /// Linear light value corresponding to maxNits
    static nonisolated let maxLinear: Float = 10_000.0 / 203.0  // ~49.26

    /// Logarithmic curve constant: log10(1 + nits * k) / log10(1 + maxNits * k)
    /// With k=0.1, 1000 nits lands at ~66.8% of the axis height.
    private static nonisolated let logK: Float = 0.1
    private static nonisolated let logDenom: Float = log10(1 + 10_000 * 0.1)  // log10(1001) ≈ 3.0004

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
    private static func metrics(for width: Int) -> (labelMargin: Int, verticalMargin: Int, fontSize: CGFloat) {
        let scale = CGFloat(width) / refSize
        return (
            labelMargin: max(Int(68 * scale), 24),
            verticalMargin: max(Int(16 * scale), 4),
            fontSize: max(22 * scale, 10)
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
        drawWaveformGuides(ctx, width: outW, height: outH, dataXOffset: m.labelMargin, verticalMargin: m.verticalMargin, fontSize: m.fontSize, scale: scale, hasHDR: hasHDR)

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
        drawWaveformGuides(ctx, width: outW, height: outH, dataXOffset: m.labelMargin, verticalMargin: m.verticalMargin, fontSize: m.fontSize, scale: scale, hasHDR: hasHDR)

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
        let normFactor = 1.0 / (Float(maxCount) * 0.25)

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
                    let intensity = min(Float(count) * normFactor, 1.0)
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

    // MARK: - Guide Lines & Labels

    private func drawWaveformGuides(_ ctx: CGContext, width: Int, height: Int, dataXOffset: Int, verticalMargin: Int, fontSize: CGFloat, scale: WaveformScale, hasHDR: Bool) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let labelColor = CGColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1.0)
        let vm = CGFloat(verticalMargin)
        let dataHeight = CGFloat(height) - vm * 2  // usable range between margins

        switch scale {
        case .percentage:
            let guides: [(fraction: CGFloat, label: String)] = [
                (0.0, "0"),
                (0.25, "25"),
                (0.5, "50"),
                (0.75, "75"),
                (1.0, "100"),
            ]
            for guide in guides {
                let yPos = vm + guide.fraction * dataHeight
                ctx.setStrokeColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 0.6)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: CGFloat(dataXOffset), y: yPos))
                ctx.addLine(to: CGPoint(x: CGFloat(width), y: yPos))
                ctx.strokePath()

                drawLabel(guide.label, in: ctx, at: CGPoint(x: 2, y: yPos - 8), font: font, color: labelColor)
            }

        case .nits:
            let sdrFraction = CGFloat(WaveformScale.nitsFraction(WaveformScale.sdrWhiteNits))

            // Regular nit guides (logarithmic positions)
            let nitGuides: [(nits: Float, label: String)] = [
                (0, "0"),
                (100, "100"),
                (1000, "1k"),
                (4000, "4k"),
                (10000, "10k"),
            ]
            for guide in nitGuides {
                let fraction = CGFloat(WaveformScale.nitsFraction(guide.nits))
                let yPos = vm + fraction * dataHeight
                ctx.setStrokeColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 0.5)
                ctx.setLineWidth(1.0)
                ctx.move(to: CGPoint(x: CGFloat(dataXOffset), y: yPos))
                ctx.addLine(to: CGPoint(x: CGFloat(width), y: yPos))
                ctx.strokePath()

                drawLabel(guide.label, in: ctx, at: CGPoint(x: 2, y: yPos - 8), font: font, color: labelColor)
            }

            // SDR white line (203 nits) — prominent orange
            let sdrY = vm + sdrFraction * dataHeight
            ctx.setStrokeColor(red: 0.9, green: 0.65, blue: 0.2, alpha: 0.7)
            ctx.setLineWidth(2.0)
            ctx.move(to: CGPoint(x: CGFloat(dataXOffset), y: sdrY))
            ctx.addLine(to: CGPoint(x: CGFloat(width), y: sdrY))
            ctx.strokePath()

            let sdrColor = CGColor(srgbRed: 0.9, green: 0.65, blue: 0.2, alpha: 0.9)
            drawLabel("SDR", in: ctx, at: CGPoint(x: 2, y: sdrY - 8), font: font, color: sdrColor)

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

    private func drawLabel(_ text: String, in ctx: CGContext, at point: CGPoint, font: CTFont, color: CGColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.saveGState()
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        ctx.restoreGState()
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
