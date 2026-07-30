import CoreGraphics
import CoreImage

/// Produces geometry-preserving channel and luminance visualizations for Pixel Analysis.
///
/// Core Image evaluates the color matrix in an extended-linear sRGB working space. Rendering
/// back to the source image's color space applies the appropriate display transfer function,
/// making the output a view of linear channel energy rather than encoded component bytes.
nonisolated enum AnalysisPixelViewRenderer {
    private static let linearWorkingColorSpace =
        CGColorSpace(name: CGColorSpace.extendedLinearSRGB)

    static func render(_ source: CGImage, mode: AnalysisPixelViewMode) -> CGImage? {
        guard mode != .normal else { return source }
        guard let linearWorkingColorSpace else { return nil }

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
        return context.createCGImage(
            output,
            from: input.extent,
            format: .RGBA8,
            colorSpace: outputColorSpace
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
        }
    }
}
