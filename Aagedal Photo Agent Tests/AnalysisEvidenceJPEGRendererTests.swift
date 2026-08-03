import AppKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Analysis evidence JPEG renderer")
struct AnalysisEvidenceJPEGRendererTests {
    @MainActor
    @Test("flattens visible photo annotations into an oriented JPEG")
    func flattensPhotoAnnotations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "analysis-evidence-jpeg-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.jpg")
        try whiteJPEG(width: 200, height: 100).write(to: sourceURL)

        let annotation = AnalysisAnnotation(
            kind: .polygon,
            geometry: .polygon([
                AnalysisNormalizedPoint(x: 0.1, y: 0.2),
                AnalysisNormalizedPoint(x: 0.4, y: 0.2),
                AnalysisNormalizedPoint(x: 0.4, y: 0.6),
                AnalysisNormalizedPoint(x: 0.1, y: 0.6),
            ]),
            text: "Detail",
            style: AnalysisAnnotationStyle(
                color: .palette(.red),
                lineWidthPoints: 6,
                fillOpacity: 0
            )
        )

        let data = try await AnalysisEvidenceJPEGRenderer.photoJPEG(
            sourceURL: sourceURL,
            annotations: [annotation],
            maxPixelSize: 200
        )
        let rendered = try #require(NSBitmapImageRep(data: data))
        #expect(rendered.pixelsWide == 200)
        #expect(rendered.pixelsHigh == 100)
        let edgeColor = try #require(rendered.colorAt(x: 20, y: 60)?.usingColorSpace(.sRGB))
        #expect(edgeColor.redComponent > edgeColor.greenComponent + 0.25)
        #expect(edgeColor.redComponent > edgeColor.blueComponent + 0.25)
    }

    @MainActor
    private func whiteJPEG(width: Int, height: Int) throws -> Data {
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: representation))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 1]
        ))
    }
}
