import CoreGraphics
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Analysis pixel views")
struct AnalysisPixelViewRendererTests {
    @Test("normal view preserves the source image")
    func normalPreservesSource() throws {
        let source = try makeSourceImage(red: 0.8, green: 0.4, blue: 0.2, alpha: 0.75)
        let output = try #require(
            AnalysisPixelViewRenderer.render(source, mode: .normal)
        )

        #expect(output === source)
    }

    @Test("channel views are grayscale and isolate the requested channel")
    func channelIsolation() throws {
        let source = try makeSourceImage(red: 0.8, green: 0.4, blue: 0.2, alpha: 0.75)
        let red = try renderedPixel(source, mode: .red)
        let green = try renderedPixel(source, mode: .green)
        let blue = try renderedPixel(source, mode: .blue)

        expectGrayscale(red)
        expectGrayscale(green)
        expectGrayscale(blue)
        #expect(red.red > green.red)
        #expect(green.red > blue.red)
        #expect(abs(Int(red.alpha) - Int(green.alpha)) <= 1)
        #expect(abs(Int(green.alpha) - Int(blue.alpha)) <= 1)
        #expect(abs(Int(red.alpha) - 191) <= 1)
    }

    @Test("relative luminance uses Rec. 709 primary weighting")
    func relativeLuminanceWeighting() throws {
        let red = try renderedPixel(
            makeSourceImage(red: 1, green: 0, blue: 0),
            mode: .luminance
        )
        let green = try renderedPixel(
            makeSourceImage(red: 0, green: 1, blue: 0),
            mode: .luminance
        )
        let blue = try renderedPixel(
            makeSourceImage(red: 0, green: 0, blue: 1),
            mode: .luminance
        )

        expectGrayscale(red)
        expectGrayscale(green)
        expectGrayscale(blue)
        #expect(green.red > red.red)
        #expect(red.red > blue.red)
    }

    @Test("view modes expose an explicit method label")
    func methodLabels() {
        for mode in AnalysisPixelViewMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(!mode.compactLabel.isEmpty)
            #expect(!mode.methodLabel.isEmpty)
        }
        #expect(AnalysisPixelViewMode.luminance.methodLabel.contains("Rec. 709"))
        #expect(AnalysisPixelViewMode.compressionResidual.methodLabel.contains("0.90"))
        #expect(AnalysisPixelViewMode.compressionResidual.methodLabel.contains("×12"))
        #expect(
            AnalysisPixelViewMode.compressionResidual.limitationLabel?
                .contains("does not establish manipulation") == true
        )
    }

    @Test("compression residual uses fixed reproducible parameters")
    func compressionResidualParameters() {
        let configuration = AnalysisCompressionResidualConfiguration.standard

        #expect(configuration.jpegQuality == 0.90)
        #expect(configuration.differenceGain == 12)
        #expect(configuration.alphaMatte == 0.50)
    }

    @Test("compression residual preserves geometry and exposes reconstruction differences")
    func compressionResidualGeometryAndEnergy() throws {
        let uniform = try makePatternImage(width: 32, height: 24, checkerboard: false)
        let checkerboard = try makePatternImage(width: 32, height: 24, checkerboard: true)
        let uniformResidual = try #require(
            AnalysisPixelViewRenderer.render(uniform, mode: .compressionResidual)
        )
        let checkerboardResidual = try #require(
            AnalysisPixelViewRenderer.render(checkerboard, mode: .compressionResidual)
        )

        #expect(checkerboardResidual.width == checkerboard.width)
        #expect(checkerboardResidual.height == checkerboard.height)
        #expect(try minimumAlpha(checkerboardResidual) == 255)
        #expect(
            try meanRGB(checkerboardResidual) > meanRGB(uniformResidual) + 5,
            "High-frequency color detail should produce more JPEG reconstruction residual than a uniform field"
        )
    }

    private func renderedPixel(
        _ source: CGImage,
        mode: AnalysisPixelViewMode
    ) throws -> Pixel {
        let output = try #require(
            AnalysisPixelViewRenderer.render(source, mode: mode)
        )
        #expect(output.width == source.width)
        #expect(output.height == source.height)
        return try readPixel(output)
    }

    private func expectGrayscale(_ pixel: Pixel) {
        #expect(abs(Int(pixel.red) - Int(pixel.green)) <= 1)
        #expect(abs(Int(pixel.green) - Int(pixel.blue)) <= 1)
    }

    private func makeSourceImage(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat = 1
    ) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let color = try #require(
            CGColor(
                colorSpace: colorSpace,
                components: [red, green, blue, alpha]
            )
        )
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return try #require(context.makeImage())
    }

    private func readPixel(_ image: CGImage) throws -> Pixel {
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: &bytes,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Pixel(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
    }

    private func makePatternImage(
        width: Int,
        height: Int,
        checkerboard: Bool
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if checkerboard, (x + y).isMultiple(of: 2) {
                    bytes[offset] = 255
                    bytes[offset + 1] = 32
                    bytes[offset + 2] = 16
                } else if checkerboard {
                    bytes[offset] = 8
                    bytes[offset + 1] = 48
                    bytes[offset + 2] = 255
                } else {
                    bytes[offset] = 96
                    bytes[offset + 1] = 128
                    bytes[offset + 2] = 160
                }
            }
        }

        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        return try #require(context.makeImage())
    }

    private func meanRGB(_ image: CGImage) throws -> Double {
        let bytes = try renderedBytes(image)
        var total = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            total += Int(bytes[offset])
            total += Int(bytes[offset + 1])
            total += Int(bytes[offset + 2])
        }
        return Double(total) / Double(image.width * image.height * 3)
    }

    private func minimumAlpha(_ image: CGImage) throws -> UInt8 {
        let bytes = try renderedBytes(image)
        return stride(from: 3, to: bytes.count, by: 4)
            .map { bytes[$0] }
            .min() ?? 0
    }

    private func renderedBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: &bytes,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return bytes
    }

    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }
}
