import CoreGraphics
import CoreImage
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Produces geometry-preserving channel, luminance, alpha, edge, and compression-residual visualizations
/// for Pixel Analysis.
///
/// Core Image evaluates the color matrix in an extended-linear sRGB working space. Rendering
/// back to the source image's color space applies the appropriate display transfer function,
/// making the output a view of linear channel energy rather than encoded component bytes.
nonisolated enum AnalysisPixelViewRenderer {
    private static let linearWorkingColorSpace =
        CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
    private static let outputColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB)

    static func render(_ source: CGImage, mode: AnalysisPixelViewMode) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        guard mode != .normal else { return source }
        guard let linearWorkingColorSpace else { return nil }

        if mode == .noiseResidual || mode == .levelSweep || mode == .cloneDetection {
            return renderForensicView(source, mode: mode)
        }

        if mode == .compressionResidual {
            return renderCompressionResidual(
                source,
                configuration: .standard,
                linearWorkingColorSpace: linearWorkingColorSpace
            )
        }

        if mode == .alpha {
            return renderAlpha(
                source,
                linearWorkingColorSpace: linearWorkingColorSpace
            )
        }

        if mode == .edges {
            return renderEdges(
                source,
                linearWorkingColorSpace: linearWorkingColorSpace
            )
        }

        let input = CIImage(cgImage: source)
        let weights = grayscaleWeights(for: mode)
        let output = input.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(
                    x: weights.red,
                    y: weights.green,
                    z: weights.blue,
                    w: 0
                ),
                "inputGVector": CIVector(
                    x: weights.red,
                    y: weights.green,
                    z: weights.blue,
                    w: 0
                ),
                "inputBVector": CIVector(
                    x: weights.red,
                    y: weights.green,
                    z: weights.blue,
                    w: 0
                ),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ]
        )

        let outputColorSpace = source.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? linearWorkingColorSpace
        let context = CIContext(options: [
            .workingColorSpace: linearWorkingColorSpace,
            .outputColorSpace: outputColorSpace,
            .cacheIntermediates: false
        ])
        // Keep HDR/16-bit preview headroom for channel and luminance inspection. An RGBA8
        // destination clamps extended-linear values above reference white, which can hide the
        // very highlight detail these views are intended to expose. Ordinary 8-bit SDR sources
        // retain the smaller display-ready representation.
        let renderFormat: CIFormat = source.bitsPerComponent > 8 ? .RGBAh : .RGBA8
        guard let rendered = context.createCGImage(
            output,
            from: input.extent,
            format: renderFormat,
            colorSpace: outputColorSpace
        ) else {
            return nil
        }
        let displayReady: CGImage
        if #available(macOS 15.0, *), source.contentHeadroom > 1 {
            displayReady = CGImageCreateCopyWithContentHeadroom(
                source.contentHeadroom,
                rendered
            ) ?? rendered
        } else {
            displayReady = rendered
        }
        return Task.isCancelled ? nil : displayReady
    }

    /// Renders alpha as an opaque grayscale coverage mask so transparency remains visible even
    /// when the workspace checkerboard or a downstream display surface changes.
    private static func renderAlpha(
        _ source: CGImage,
        linearWorkingColorSpace: CGColorSpace
    ) -> CGImage? {
        let input = CIImage(cgImage: source)
        let output = input.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ]
        )
        return renderSDR(
            output,
            extent: input.extent,
            linearWorkingColorSpace: linearWorkingColorSpace
        )
    }

    /// A fixed-parameter edge-strength view. This is intentionally display-referred and SDR:
    /// it is a visual aid for locating boundaries, sharpening halos, and texture transitions,
    /// not a measurement of scene-linear energy.
    private static func renderEdges(
        _ source: CGImage,
        linearWorkingColorSpace: CGColorSpace
    ) -> CGImage? {
        let input = CIImage(cgImage: source)
        let output = input.applyingFilter(
            "CIEdges",
            parameters: [kCIInputIntensityKey: 3.0]
        )
        return renderSDR(
            output,
            extent: input.extent,
            linearWorkingColorSpace: linearWorkingColorSpace
        )
    }

    private static func renderSDR(
        _ image: CIImage,
        extent: CGRect,
        linearWorkingColorSpace: CGColorSpace
    ) -> CGImage? {
        guard let outputColorSpace else { return nil }
        let context = CIContext(options: [
            .workingColorSpace: linearWorkingColorSpace,
            .outputColorSpace: outputColorSpace,
            .cacheIntermediates: false
        ])
        let rendered = context.createCGImage(
            image,
            from: extent,
            format: .RGBA8,
            colorSpace: outputColorSpace
        )
        return Task.isCancelled ? nil : rendered
    }

    private static func renderCompressionResidual(
        _ source: CGImage,
        configuration: AnalysisCompressionResidualConfiguration,
        linearWorkingColorSpace: CGColorSpace
    ) -> CGImage? {
        guard !Task.isCancelled,
              let outputColorSpace,
              let normalized = normalizedJPEGInput(
                  source,
                  alphaMatte: configuration.alphaMatte,
                  outputColorSpace: outputColorSpace,
                  linearWorkingColorSpace: linearWorkingColorSpace
              ),
              !Task.isCancelled,
              let recompressed = jpegReencode(
                  normalized,
                  quality: configuration.jpegQuality
              ),
              !Task.isCancelled else {
            return nil
        }

        let extent = CGRect(
            x: 0,
            y: 0,
            width: normalized.width,
            height: normalized.height
        )
        let original = CIImage(cgImage: normalized)
        let jpeg = CIImage(cgImage: recompressed)
        let difference = original.applyingFilter(
            "CIDifferenceBlendMode",
            parameters: [kCIInputBackgroundImageKey: jpeg]
        )
        let gain = configuration.differenceGain
        let amplified = difference.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ]
        )
        let context = CIContext(options: [
            .workingColorSpace: linearWorkingColorSpace,
            .outputColorSpace: outputColorSpace,
            .cacheIntermediates: false
        ])
        let rendered = context.createCGImage(
            amplified,
            from: extent,
            format: .RGBA8,
            colorSpace: outputColorSpace
        )
        return Task.isCancelled ? nil : rendered
    }

    /// Converts all inputs to the same opaque sRGB raster before JPEG encoding. JPEG has no
    /// alpha channel, so a fixed neutral matte avoids encoder-dependent transparency handling.
    private static func normalizedJPEGInput(
        _ source: CGImage,
        alphaMatte: CGFloat,
        outputColorSpace: CGColorSpace,
        linearWorkingColorSpace: CGColorSpace
    ) -> CGImage? {
        let input = CIImage(cgImage: source)
        guard let matteCGColor = CGColor(
            colorSpace: outputColorSpace,
            components: [alphaMatte, alphaMatte, alphaMatte, 1]
        ) else {
            return nil
        }
        let matte = CIImage(
            color: CIColor(cgColor: matteCGColor)
        ).cropped(to: input.extent)
        let flattened = input.composited(over: matte)
        let context = CIContext(options: [
            .workingColorSpace: linearWorkingColorSpace,
            .outputColorSpace: outputColorSpace,
            .cacheIntermediates: false
        ])
        return context.createCGImage(
            flattened,
            from: input.extent,
            format: .RGBA8,
            colorSpace: outputColorSpace
        )
    }

    private static func jpegReencode(_ image: CGImage, quality: Double) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImageDestinationLossyCompressionQuality: quality,
                kCGImagePropertyJFIFDictionary: [
                    kCGImagePropertyJFIFIsProgressive: false
                ]
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        )
    }

    /// Shared Metal-backed Core Image context avoids rebuilding CPU luminance buffers
    /// for each slider update. Core Image can fall back when Metal is unavailable.
    private static let forensicContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .cacheIntermediates: true
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    private static func renderLevelSweep(_ source: CGImage, level: Int) -> CGImage? {
        guard !Task.isCancelled, let outputColorSpace else { return nil }
        let scale = min(1, 2048 / CGFloat(max(source.width, source.height)))
        let scaled = CIImage(cgImage: source).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let matte = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: scaled.extent)
        let input = scaled.composited(over: matte)
        let gain: CGFloat = 255 / 32
        let weights = CIVector(x: 0.2126 * gain, y: 0.7152 * gain, z: 0.0722 * gain, w: 0)
        let bias = -CGFloat(min(255, max(0, level)) - 16) / 32
        let output = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": weights, "inputGVector": weights, "inputBVector": weights,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1)
        ])
        let result = forensicContext.createCGImage(output, from: input.extent.integral,
                                                   format: .RGBA8, colorSpace: outputColorSpace)
        return Task.isCancelled ? nil : result
    }

    /// Bounded SDR inspection aids. The raster preserves the source aspect ratio and
    /// normalized coordinates; it is never used as source-bound measurement evidence.
    static func renderForensicView(
        _ source: CGImage, mode: AnalysisPixelViewMode, level: Int = 128
    ) -> CGImage? {
        if mode == .levelSweep { return renderLevelSweep(source, level: level) }
        let maximum = mode == .cloneDetection ? 1024 : 2048
        let scale = min(1, Double(maximum) / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        guard let colorSpace = outputColorSpace,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let original = Array(UnsafeBufferPointer(start: bytes, count: width * height * 4))
        var luminance = [Int](repeating: 0, count: width * height)
        for i in luminance.indices {
            if i.isMultiple(of: width), Task.isCancelled { return nil }
            let offset = i * 4
            let red: Int = 54 * Int(original[offset])
            let green: Int = 183 * Int(original[offset + 1])
            let blue: Int = 19 * Int(original[offset + 2])
            luminance[i] = (red + green + blue) / 256
        }
        if mode == .cloneDetection {
            struct Block {
                let x: Int
                let y: Int
                let descriptor: [Int]
            }
            struct Match {
                let first: Block
                let second: Block
            }
            var buckets: [UInt64: [Block]] = [:]
            var groups: [Int: [Match]] = [:]
            var matchCount = 0
            if width >= 8 && height >= 8 {
                for y in stride(from: 0, through: height - 8, by: 4) {
                    guard !Task.isCancelled else { return nil }
                    for x in stride(from: 0, through: width - 8, by: 4) {
                        var descriptor: [Int] = []
                        // Cell averages tolerate noise/recompression better than exact pixels.
                        for dy in stride(from: 0, to: 8, by: 2) {
                            for dx in stride(from: 0, to: 8, by: 2) {
                                var total = 0
                                for yy in 0..<2 { for xx in 0..<2 {
                                    total += luminance[(y + dy + yy) * width + x + dx + xx]
                                }}
                                descriptor.append(total / 4)
                            }
                        }
                        guard descriptor.max()! - descriptor.min()! >= 24 else { continue }
                        let block = Block(x: x, y: y, descriptor: descriptor)
                        var visited = Set<Int>()
                        // Offset quantizers reduce boundary misses. Confirm every candidate
                        // against all sixteen unquantized cells before accepting it.
                        for offset in [0, 16] {
                            var signature: UInt64 = 0
                            for index in [0, 2, 5, 7, 8, 10, 13, 15] {
                                signature = (signature << 4) | UInt64((descriptor[index] + offset) / 32)
                            }
                            signature |= UInt64(offset == 0 ? 0 : 1) << 40
                            let candidates = buckets[signature] ?? []
                            for candidate in candidates {
                                guard abs(candidate.x - x) >= 16 || abs(candidate.y - y) >= 16,
                                      visited.insert(candidate.y * width + candidate.x).inserted else { continue }
                                let errors = zip(descriptor, candidate.descriptor).map { abs($0 - $1) }
                                guard errors.max()! <= 24, errors.reduce(0, +) <= 16 * 10 else { continue }
                                let displacement = (y - candidate.y) * (width * 2 + 1) + x - candidate.x
                                if matchCount < 100_000, groups[displacement, default: []].count < 4096 {
                                    matchCount += 1
                                    groups[displacement, default: []].append(Match(first: candidate, second: block))
                                }
                            }
                            if candidates.count < 32 { buckets[signature, default: []].append(block) }
                        }
                    }
                }
                // Multiple matches with the same translation suppress isolated coincidences.
                for matches in groups.values where matches.count >= 3 {
                    guard !Task.isCancelled else { return nil }
                    for match in matches {
                        for block in [match.first, match.second] {
                            for dy in 0..<8 { for dx in 0..<8 {
                                let i = ((block.y + dy) * width + block.x + dx) * 4
                                bytes[i] = original[i] / 2
                                bytes[i + 1] = 180 + original[i + 1] / 4
                                bytes[i + 2] = 180 + original[i + 2] / 4
                            }}
                        }
                    }
                }
            }
        } else {
            for y in 0..<height {
                guard !Task.isCancelled else { return nil }
                for x in 0..<width {
                    let index = y * width + x
                    let value: Int
                    do {
                        var neighbors: [Int] = []
                        for dy in -1...1 {
                            for dx in -1...1 {
                                neighbors.append(luminance[min(height - 1, max(0, y + dy)) * width
                                    + min(width - 1, max(0, x + dx))])
                            }
                        }
                        neighbors.sort()
                        value = min(255, abs(luminance[index] - neighbors[4]) * 8)
                    }
                    for channel in 0..<3 { bytes[index * 4 + channel] = UInt8(value) }
                    bytes[index * 4 + 3] = 255
                }
            }
        }
        return Task.isCancelled ? nil : context.makeImage()
    }

    private static func grayscaleWeights(
        for mode: AnalysisPixelViewMode
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch mode {
        case .normal:
            (1, 1, 1)
        case .red:
            (1, 0, 0)
        case .green:
            (0, 1, 0)
        case .blue:
            (0, 0, 1)
        case .luminance:
            (0.2126, 0.7152, 0.0722)
        case .alpha, .edges, .compressionResidual, .noiseResidual, .levelSweep, .cloneDetection:
            (1, 1, 1)
        }
    }
}
