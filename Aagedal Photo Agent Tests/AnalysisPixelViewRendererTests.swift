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

    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }
}
