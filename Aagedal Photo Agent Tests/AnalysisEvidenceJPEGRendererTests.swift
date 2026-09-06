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
    @Test("counter evidence renders readable numbered badges even with thick strokes", arguments: [2.0, 32.0])
    func counterBadgesAndVisibility(lineWidth: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "analysis-evidence-counter-tests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.jpg")
        try whiteJPEG(width: 300, height: 200).write(to: sourceURL)
        let visible = AnalysisAnnotation(
            kind: .counter,
            geometry: .anchor(AnalysisNormalizedPoint(x: 0.2, y: 0.5)),
            text: "People",
            style: AnalysisAnnotationStyle(color: .palette(.red), lineWidthPoints: lineWidth, fillOpacity: 0),
            counterNumber: 42
        )
        let hidden = AnalysisAnnotation(
            kind: .counter,
            geometry: .anchor(AnalysisNormalizedPoint(x: 0.8, y: 0.5)),
            style: AnalysisAnnotationStyle(color: .palette(.blue), lineWidthPoints: 2, fillOpacity: 0),
            isVisible: false,
            counterNumber: 1
        )
        let data = try await AnalysisEvidenceJPEGRenderer.photoJPEG(
            sourceURL: sourceURL, annotations: [visible, hidden], maxPixelSize: 300
        )
        let rendered = try #require(NSBitmapImageRep(data: data))
        var redPixels = 0
        var numberPixels = 0
        for y in 92...108 {
            for x in 52...68 {
                let color = try #require(rendered.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.redComponent > color.greenComponent + 0.25,
                   color.redComponent > color.blueComponent + 0.25 {
                    redPixels += 1
                }
                // The inner region excludes the circle outline, so dark pixels
                // here confirm that the counter number survived flattening.
                if (55...65).contains(x), (96...104).contains(y),
                   max(color.redComponent, color.greenComponent, color.blueComponent) < 0.4 {
                    numberPixels += 1
                }
            }
        }
        #expect(redPixels > 100)
        #expect(numberPixels > 5)
        for y in 88...112 {
            for x in 228...252 {
                let color = try #require(rendered.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                #expect(min(color.redComponent, color.greenComponent, color.blueComponent) > 0.95)
            }
        }
        // The optional label sits above and to the right of the badge.
        var labelPixels = 0
        for y in 55...85 {
            for x in 76...145 {
                let color = try #require(rendered.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if min(color.redComponent, color.greenComponent, color.blueComponent) < 0.8 {
                    labelPixels += 1
                }
            }
        }
        #expect(labelPixels > 20)
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
