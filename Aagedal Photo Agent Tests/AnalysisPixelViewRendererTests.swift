import CoreGraphics
import CoreImage
import Foundation
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

    @Test("alpha view renders an opaque grayscale coverage mask")
    func alphaCoverageMask() throws {
        let source = try makeSourceImage(
            red: 0.8,
            green: 0.4,
            blue: 0.2,
            alpha: 0.25
        )
        let lowCoverage = try renderedPixel(source, mode: .alpha)
        let highCoverage = try renderedPixel(
            makeSourceImage(red: 0.8, green: 0.4, blue: 0.2, alpha: 0.75),
            mode: .alpha
        )

        expectGrayscale(lowCoverage)
        expectGrayscale(highCoverage)
        #expect(lowCoverage.red < highCoverage.red)
        #expect(lowCoverage.alpha == 255)
        #expect(highCoverage.alpha == 255)
    }

    @Test("edge view preserves geometry and responds to local contrast")
    func edgeViewGeometryAndEnergy() throws {
        let uniform = try makePatternImage(width: 32, height: 24, checkerboard: false)
        let checkerboard = try makePatternImage(width: 32, height: 24, checkerboard: true)
        let uniformEdges = try #require(
            AnalysisPixelViewRenderer.render(uniform, mode: .edges)
        )
        let checkerboardEdges = try #require(
            AnalysisPixelViewRenderer.render(checkerboard, mode: .edges)
        )

        #expect(checkerboardEdges.width == checkerboard.width)
        #expect(checkerboardEdges.height == checkerboard.height)
        #expect(try meanRGB(checkerboardEdges) > meanRGB(uniformEdges) + 5)
    }

    @Test("SDR stays compact while HDR channel views preserve headroom")
    func dynamicRangeContract() throws {
        let sdr = try makeSourceImage(red: 0.8, green: 0.4, blue: 0.2)
        let sdrRed = try #require(
            AnalysisPixelViewRenderer.render(sdr, mode: .red)
        )
        #expect(sdrRed.bitsPerComponent == 8)

        let hdr = try makeHDRSourceImage(
            red: 2,
            green: 2,
            blue: 2,
            alpha: 1
        )
        #expect(hdr.bitsPerComponent == 16)
        #expect(AnalysisPixelViewRenderer.render(hdr, mode: .normal) === hdr)

        for mode in [AnalysisPixelViewMode.red, .green, .blue, .luminance] {
            let output = try #require(
                AnalysisPixelViewRenderer.render(hdr, mode: mode)
            )
            let pixel = try readLinearFloatPixel(output)

            #expect(output.width == hdr.width)
            #expect(output.height == hdr.height)
            #expect(output.bitsPerComponent == 16)
            #expect(output.contentHeadroom > 1.9)
            #expect(pixel.red > 1.9)
            #expect(abs(pixel.red - pixel.green) < 0.01)
            #expect(abs(pixel.green - pixel.blue) < 0.01)
            #expect(abs(pixel.alpha - 1) < 0.01)
        }
    }

    @Test("compression residual explicitly flattens HDR alpha to opaque SDR")
    func compressionResidualDynamicRangeContract() throws {
        let hdr = try makeHDRSourceImage(
            red: 1.5,
            green: 0.75,
            blue: 0.25,
            alpha: 0.25,
            width: 8,
            height: 6
        )
        let residual = try #require(
            AnalysisPixelViewRenderer.render(hdr, mode: .compressionResidual)
        )

        #expect(residual.width == 8)
        #expect(residual.height == 6)
        #expect(residual.bitsPerComponent == 8)
        #expect(try minimumAlpha(residual) == 255)
    }

    @Test("view modes expose an explicit method label")
    func methodLabels() {
        for mode in AnalysisPixelViewMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(!mode.compactLabel.isEmpty)
            #expect(!mode.methodLabel.isEmpty)
        }
        #expect(AnalysisPixelViewMode.luminance.methodLabel.contains("Rec. 709"))
        #expect(AnalysisPixelViewMode.alpha.methodLabel.contains("alpha"))
        #expect(AnalysisPixelViewMode.edges.methodLabel.contains("3.0"))
        #expect(
            AnalysisPixelViewMode.edges.limitationLabel?
                .contains("does not establish manipulation") == true
        )
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

    private func makeHDRSourceImage(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat,
        width: Int = 1,
        height: Int = 1
    ) throws -> CGImage {
        let colorSpace = try #require(
            CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        )
        let color = try #require(
            CIColor(
                red: red,
                green: green,
                blue: blue,
                alpha: alpha,
                colorSpace: colorSpace
            )
        )
        let ciImage = CIImage(
            color: color
        ).cropped(
            to: CGRect(x: 0, y: 0, width: width, height: height)
        )
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .cacheIntermediates: false
        ])
        let cgImage = try #require(
            context.createCGImage(
                ciImage,
                from: ciImage.extent,
                format: .RGBAh,
                colorSpace: colorSpace
            )
        )
        let peak = Float(max(red, green, blue))
        guard peak > 1 else { return cgImage }
        return CGImageCreateCopyWithContentHeadroom(peak, cgImage) ?? cgImage
    }

    private func readLinearFloatPixel(_ image: CGImage) throws -> FloatPixel {
        let colorSpace = try #require(
            CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        )
        var components = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .cacheIntermediates: false
        ])
        context.render(
            CIImage(cgImage: image),
            toBitmap: &components,
            rowBytes: MemoryLayout<Float>.size * 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: colorSpace
        )
        return FloatPixel(
            red: components[0],
            green: components[1],
            blue: components[2],
            alpha: components[3]
        )
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
                if checkerboard, (x / 4 + y / 4).isMultiple(of: 2) {
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

    private struct FloatPixel {
        let red: Float
        let green: Float
        let blue: Float
        let alpha: Float
    }
}

@Suite("Analysis derived-view cache")
struct AnalysisDerivedViewCacheTests {
    @Test("exact keys reuse a render and isolate modes")
    func exactKeyReuse() async throws {
        let probe = RenderProbe()
        let service = AnalysisDerivedViewService(
            maximumCost: 1_024,
            renderer: { source, _ in
                probe.recordRender()
                return source
            }
        )
        let source = try makeImage(width: 4, height: 4, value: 80)
        let redKey = AnalysisDerivedViewCacheKey(
            sourceIdentifier: "source-a",
            mode: .red,
            source: source
        )
        let blueKey = AnalysisDerivedViewCacheKey(
            sourceIdentifier: "source-a",
            mode: .blue,
            source: source
        )

        #expect(await service.image(for: redKey, source: source) != nil)
        #expect(await service.image(for: redKey, source: source) != nil)
        #expect(probe.renderCount == 1)
        #expect(await service.image(for: blueKey, source: source) != nil)
        #expect(probe.renderCount == 2)
    }

    @Test("least-recently-used entries are evicted within the byte budget")
    func costBoundedLRUEviction() async throws {
        let service = AnalysisDerivedViewService(
            maximumCost: 128,
            renderer: { source, _ in source }
        )
        let firstSource = try makeImage(width: 4, height: 4, value: 32)
        let secondSource = try makeImage(width: 4, height: 4, value: 224)
        let firstKey = AnalysisDerivedViewCacheKey(
            sourceIdentifier: "first",
            mode: .red,
            source: firstSource
        )
        let secondKey = AnalysisDerivedViewCacheKey(
            sourceIdentifier: "second",
            mode: .blue,
            source: secondSource
        )

        #expect(await service.image(for: firstKey, source: firstSource) != nil)
        #expect(await service.image(for: secondKey, source: secondSource) != nil)

        let metrics = await service.cacheMetrics()
        #expect(metrics.totalCost <= metrics.maximumCost)
        #expect(metrics.entryCount == 2)

        let thirdSource = try makeImage(width: 4, height: 4, value: 128)
        let thirdKey = AnalysisDerivedViewCacheKey(
            sourceIdentifier: "third",
            mode: .luminance,
            source: thirdSource
        )
        #expect(await service.image(for: thirdKey, source: thirdSource) != nil)

        let boundedMetrics = await service.cacheMetrics()
        #expect(boundedMetrics.totalCost <= 128)
        #expect(boundedMetrics.entryCount == 2)
        #expect(await service.cachedImage(for: firstKey) == nil)
        #expect(await service.cachedImage(for: secondKey) != nil)
        #expect(await service.cachedImage(for: thirdKey) != nil)
    }

    @Test("cancelling a consumer cancels and discards its detached render")
    func cancellationPropagation() async throws {
        let probe = RenderProbe()
        let service = AnalysisDerivedViewService(
            maximumCost: 1_024,
            renderer: { source, _ in
                probe.recordRender()
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                probe.recordCancellation()
                return source
            }
        )
        let source = try makeImage(width: 4, height: 4, value: 128)
        let key = AnalysisDerivedViewCacheKey(
            sourceIdentifier: "cancelled",
            mode: .compressionResidual,
            source: source
        )
        let render = Task {
            await service.image(for: key, source: source)
        }

        while probe.renderCount == 0 {
            await Task.yield()
        }
        render.cancel()

        #expect(await render.value == nil)
        #expect(probe.observedCancellation)
        #expect(await service.cachedImage(for: key) == nil)
    }

    @Test("memory pressure cancels an in-flight render before scope eviction")
    func memoryPressureCancelsInFlightRender() async throws {
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        let probe = RenderProbe()
        let service = AnalysisDerivedViewService(
            maximumCost: 1_024,
            memoryCoordinator: coordinator,
            renderer: { source, _ in
                probe.recordRender()
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                probe.recordCancellation()
                return source
            }
        )
        let source = try makeImage(width: 4, height: 4, value: 128)
        let key = AnalysisDerivedViewCacheKey(
            sourceIdentifier: "pressure-cancelled",
            mode: .compressionResidual,
            source: source
        )
        let render = Task {
            await service.image(for: key, source: source)
        }

        while probe.renderCount == 0 {
            await Task.yield()
        }
        coordinator.handleMemoryPressure(.warning)

        #expect(await render.value == nil)
        #expect(probe.observedCancellation)
        #expect(await service.cachedImage(for: key) == nil)
    }

    private func makeImage(width: Int, height: Int, value: UInt8) throws -> CGImage {
        var bytes = [UInt8](repeating: value, count: width * height * 4)
        for alphaOffset in stride(from: 3, to: bytes.count, by: 4) {
            bytes[alphaOffset] = 255
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

    nonisolated private final class RenderProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var renders = 0
        private var cancellation = false

        var renderCount: Int {
            lock.withLock { renders }
        }

        var observedCancellation: Bool {
            lock.withLock { cancellation }
        }

        func recordRender() {
            lock.withLock { renders += 1 }
        }

        func recordCancellation() {
            lock.withLock { cancellation = true }
        }
    }
}
