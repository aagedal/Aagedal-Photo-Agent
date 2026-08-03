import CoreGraphics
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Scope render requests")
struct ScopeRenderRequestTests {
    @Test("presentation points become bounded backing pixels")
    func backingPixelSizing() throws {
        let ordinary = try #require(
            ScopeRenderRequest.outputPixelSize(
                for: CGSize(width: 320, height: 180),
                backingScale: 2
            )
        )
        #expect(ordinary == CGSize(width: 640, height: 360))

        let bounded = try #require(
            ScopeRenderRequest.outputPixelSize(
                for: CGSize(width: 4_000, height: 12),
                backingScale: 2
            )
        )
        #expect(
            bounded == CGSize(
                width: ScopeRenderRequest.maximumDimension,
                height: ScopeRenderRequest.minimumDimension
            )
        )
    }

    @Test("collapsed and invalid presentation geometry does not create a request")
    func invalidPresentationSizing() {
        #expect(
            ScopeRenderRequest.outputPixelSize(
                for: .zero,
                backingScale: 2
            ) == nil
        )
        #expect(
            ScopeRenderRequest.outputPixelSize(
                for: CGSize(width: 320, height: CGFloat.infinity),
                backingScale: 2
            ) == nil
        )
        #expect(
            ScopeRenderRequest.outputPixelSize(
                for: CGSize(width: 320, height: 180),
                backingScale: 0
            ) == nil
        )
    }

    @Test("presentation sizing preserves established scope shapes")
    func presentationShapes() {
        let available = CGSize(width: 700, height: 225)
        #expect(
            ScopePresentationSizing.contentSize(
                mode: .waveform,
                availableSize: available
            ) == available
        )
        #expect(
            ScopePresentationSizing.contentSize(
                mode: .vectorscope,
                availableSize: available
            ) == CGSize(width: 225, height: 225)
        )
        #expect(
            ScopePresentationSizing.contentSize(
                mode: .chromaticity,
                availableSize: available
            ) == CGSize(
                width: ScopePresentationSizing.chromaticityMaximumWidth,
                height: 225
            )
        )
    }

    @Test("unified renderer honors non-square output dimensions")
    func rendersRequestedDimensions() throws {
        let source = try makeSourceImage()
        let service = ScopeRenderService()

        let waveform = try #require(
            service.render(
                ScopeRenderRequest(
                    mode: .waveform,
                    outputSize: CGSize(width: 320, height: 180)
                ),
                from: source
            )
        )
        #expect(waveform.width == 320)
        #expect(waveform.height == 180)

        let vectorscope = try #require(
            service.render(
                ScopeRenderRequest(
                    mode: .vectorscope,
                    outputSize: CGSize(width: 200, height: 120)
                ),
                from: source
            )
        )
        #expect(vectorscope.width == 200)
        #expect(vectorscope.height == 120)
    }

    private func makeSourceImage() throws -> CGImage {
        let width = 16
        let height = 12
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let fillColor = try #require(
            CGColor(
                colorSpace: colorSpace,
                components: [0.2, 0.5, 0.8, 1]
            )
        )
        context.setFillColor(fillColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
