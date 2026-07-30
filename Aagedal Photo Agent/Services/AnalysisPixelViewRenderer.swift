import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Produces geometry-preserving channel, luminance, and compression-residual visualizations
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

        if mode == .compressionResidual {
            return renderCompressionResidual(
                source,
                configuration: .standard,
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
        let rendered = context.createCGImage(
            output,
            from: input.extent,
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
        case .compressionResidual:
            (1, 1, 1)
        }
    }
}
