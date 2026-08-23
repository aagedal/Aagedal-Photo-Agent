import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
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
    @Test("flattens annotations in the display frame for every EXIF orientation")
    func flattensEveryOrientation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "analysis-evidence-jpeg-orientation-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let annotation = AnalysisAnnotation(
            kind: .line,
            geometry: .segment(
                start: AnalysisNormalizedPoint(x: 0.1, y: 0.2),
                end: AnalysisNormalizedPoint(x: 0.4, y: 0.2)
            ),
            style: AnalysisAnnotationStyle(
                color: .palette(.red),
                lineWidthPoints: 8,
                fillOpacity: 0
            )
        )

        for orientation in 1...8 {
            let sourceURL = directory.appendingPathComponent("source-\(orientation).jpg")
            try orientedWhiteJPEG(width: 200, height: 100, orientation: orientation)
                .write(to: sourceURL)

            let data = try await AnalysisEvidenceJPEGRenderer.photoJPEG(
                sourceURL: sourceURL,
                annotations: [annotation],
                maxPixelSize: 200
            )
            let rendered = try #require(NSBitmapImageRep(data: data))
            let expectedWidth = orientation >= 5 ? 100 : 200
            let expectedHeight = orientation >= 5 ? 200 : 100
            #expect(rendered.pixelsWide == expectedWidth)
            #expect(rendered.pixelsHigh == expectedHeight)

            let lineColor = try #require(rendered.colorAt(
                x: Int(Double(expectedWidth) * 0.25),
                y: Int(Double(expectedHeight) * 0.2)
            )?.usingColorSpace(.sRGB))
            #expect(lineColor.redComponent > lineColor.greenComponent + 0.25)
            #expect(lineColor.redComponent > lineColor.blueComponent + 0.25)
        }
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

    @MainActor
    private func orientedWhiteJPEG(width: Int, height: Int, orientation: Int) throws -> Data {
        let undecorated = try whiteJPEG(width: width, height: height)
        let source = try #require(CGImageSourceCreateWithData(undecorated as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
