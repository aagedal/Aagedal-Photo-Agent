import CoreGraphics
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Display image transform")
struct DisplayImageTransformTests {
    @Test("all EXIF orientations map a source point to the expected display point", arguments: [
        (1, CGPoint(x: 0.2, y: 0.3)),
        (2, CGPoint(x: 0.8, y: 0.3)),
        (3, CGPoint(x: 0.8, y: 0.7)),
        (4, CGPoint(x: 0.2, y: 0.7)),
        (5, CGPoint(x: 0.3, y: 0.2)),
        (6, CGPoint(x: 0.7, y: 0.2)),
        (7, CGPoint(x: 0.7, y: 0.8)),
        (8, CGPoint(x: 0.3, y: 0.8))
    ])
    func mapsEveryOrientation(_ orientation: Int, _ expected: CGPoint) throws {
        let transform = try DisplayImageTransform(
            sourcePixelWidth: 400,
            sourcePixelHeight: 300,
            exifOrientation: orientation
        )

        let actual = transform.displayNormalizedPoint(
            fromSourceNormalized: CGPoint(x: 0.2, y: 0.3)
        )

        expectEqual(actual, expected)
    }

    @Test("normalized points round-trip for every orientation")
    func normalizedPointRoundTrips() throws {
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0.13, y: 0.71),
            CGPoint(x: -0.1, y: 1.2)
        ]

        for orientation in 1...8 {
            let transform = try DisplayImageTransform(
                sourcePixelWidth: 6000,
                sourcePixelHeight: 4000,
                exifOrientation: orientation
            )

            for point in points {
                let displayed = transform.displayNormalizedPoint(fromSourceNormalized: point)
                let roundTrip = transform.sourceNormalizedPoint(fromDisplayNormalized: displayed)
                expectEqual(roundTrip, point)
            }
        }
    }

    @Test("normalized rectangles round-trip for every orientation")
    func normalizedRectRoundTrips() throws {
        let source = CGRect(x: 0.12, y: 0.27, width: 0.31, height: 0.52)

        for orientation in 1...8 {
            let transform = try DisplayImageTransform(
                sourcePixelWidth: 1200,
                sourcePixelHeight: 800,
                exifOrientation: orientation
            )
            let displayed = transform.displayNormalizedRect(fromSourceNormalized: source)
            let roundTrip = transform.sourceNormalizedRect(fromDisplayNormalized: displayed)

            expectEqual(roundTrip, source)
        }
    }

    @Test("transposed orientations swap displayed pixel dimensions")
    func displayedDimensions() throws {
        for orientation in 1...8 {
            let transform = try DisplayImageTransform(
                sourcePixelWidth: 400,
                sourcePixelHeight: 300,
                exifOrientation: orientation
            )
            let expected = orientation >= 5
                ? CGSize(width: 300, height: 400)
                : CGSize(width: 400, height: 300)

            #expect(transform.displayedPixelSize == expected)
        }
    }

    @Test("source pixel and display-normalized coordinates round-trip")
    func pixelRoundTrip() throws {
        let sourcePoint = CGPoint(x: 100, y: 50)
        let sourceRect = CGRect(x: 80, y: 30, width: 160, height: 120)

        for orientation in 1...8 {
            let transform = try DisplayImageTransform(
                sourcePixelWidth: 400,
                sourcePixelHeight: 300,
                exifOrientation: orientation
            )

            let displayedPoint = transform.displayNormalizedPoint(fromSourcePixel: sourcePoint)
            let roundTripPoint = transform.sourcePixelPoint(
                fromDisplayNormalized: displayedPoint
            )
            expectEqual(roundTripPoint, sourcePoint)

            let displayedRect = transform.displayNormalizedRect(fromSourcePixel: sourceRect)
            let roundTripRect = transform.sourcePixelRect(
                fromDisplayNormalized: displayedRect
            )
            expectEqual(roundTripRect, sourceRect)
        }
    }

    @Test("orientation 6 pixel coordinates use the transposed display frame")
    func orientationSixPixelMapping() throws {
        let transform = try DisplayImageTransform(
            sourcePixelWidth: 400,
            sourcePixelHeight: 300,
            exifOrientation: 6
        )

        let displayed = transform.displayNormalizedPoint(
            fromSourcePixel: CGPoint(x: 100, y: 60)
        )

        expectEqual(displayed, CGPoint(x: 0.8, y: 0.25))
        #expect(transform.displayedPixelSize == CGSize(width: 300, height: 400))
    }

    @Test("upright developed crop remaps its edges and pixel dimensions")
    func developedCropMapping() throws {
        let crop = try DisplayImageTransform.DevelopedCrop(
            sourceNormalizedRect: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
        )
        let transform = try DisplayImageTransform(
            sourcePixelWidth: 1200,
            sourcePixelHeight: 800,
            developedCrop: crop
        )

        #expect(transform.fullDisplayedPixelSize == CGSize(width: 1200, height: 800))
        expectEqual(
            CGPoint(
                x: transform.displayedPixelSize.width,
                y: transform.displayedPixelSize.height
            ),
            CGPoint(x: 600, y: 480)
        )
        expectEqual(
            transform.displayNormalizedPoint(
                fromSourceNormalized: CGPoint(x: 0.25, y: 0.2)
            ),
            .zero
        )
        expectEqual(
            transform.displayNormalizedPoint(
                fromSourceNormalized: CGPoint(x: 0.75, y: 0.8)
            ),
            CGPoint(x: 1, y: 1)
        )
    }

    @Test("straightened crop is pixel-aspect correct for different image shapes", arguments: [
        (
            CGSize(width: 1200, height: 600),
            CGPoint(x: 0.3767949192431123, y: 0.1267949192431123)
        ),
        (
            CGSize(width: 600, height: 1200),
            CGPoint(x: 0.5267949192431123, y: 0.2767949192431123)
        ),
        (
            CGSize(width: 900, height: 900),
            CGPoint(x: 0.4267949192431123, y: 0.2267949192431123)
        )
    ])
    func straightenAcrossAspectRatios(
        _ sourceSize: CGSize,
        _ expectedSourcePointAtDevelopedTopLeft: CGPoint
    ) throws {
        let crop = try DisplayImageTransform.DevelopedCrop(
            sourceNormalizedRect: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            straightenAngleDegrees: 30
        )
        let transform = try DisplayImageTransform(
            sourcePixelWidth: Int(sourceSize.width),
            sourcePixelHeight: Int(sourceSize.height),
            developedCrop: crop
        )

        let sourcePoint = transform.sourceNormalizedPoint(
            fromDisplayNormalized: .zero
        )

        expectEqual(sourcePoint, expectedSourcePointAtDevelopedTopLeft)
        expectEqual(
            transform.displayNormalizedPoint(fromSourceNormalized: sourcePoint),
            .zero
        )
    }

    @Test("EXIF orientation, crop, and straighten compose without losing source coordinates")
    func orientedStraightenedCrop() throws {
        // In source storage coordinates this crop becomes x: 0.2...0.7, y: 0.25...0.75
        // after orientation 6 is applied.
        let crop = try DisplayImageTransform.DevelopedCrop(
            sourceNormalizedRect: CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.5),
            straightenAngleDegrees: -20
        )
        let transform = try DisplayImageTransform(
            sourcePixelWidth: 800,
            sourcePixelHeight: 1200,
            exifOrientation: 6,
            developedCrop: crop
        )

        #expect(transform.fullDisplayedPixelSize == CGSize(width: 1200, height: 800))
        #expect(transform.displayedPixelSize == CGSize(width: 600, height: 400))
        expectEqual(
            transform.developedCropRectInFullDisplay ?? .null,
            CGRect(x: 0.2, y: 0.25, width: 0.5, height: 0.5)
        )

        let developedPoints = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.2, y: 0.8),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 1, y: 1)
        ]
        for developedPoint in developedPoints {
            let sourcePoint = transform.sourceNormalizedPoint(
                fromDisplayNormalized: developedPoint
            )
            expectEqual(
                transform.displayNormalizedPoint(fromSourceNormalized: sourcePoint),
                developedPoint
            )
        }

        expectEqual(
            transform.sourcePixelPoint(
                fromDisplayNormalized: CGPoint(x: 0.5, y: 0.5)
            ),
            CGPoint(x: 400, y: 660)
        )
    }

    @Test("developed crop point transforms round-trip through every EXIF orientation")
    func developedCropRoundTripsEveryOrientation() throws {
        let crop = try DisplayImageTransform.DevelopedCrop(
            sourceNormalizedRect: CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4),
            straightenAngleDegrees: 17
        )
        let developedPoints = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.13, y: 0.71),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 1, y: 1)
        ]

        for orientation in 1...8 {
            let transform = try DisplayImageTransform(
                sourcePixelWidth: 1200,
                sourcePixelHeight: 800,
                exifOrientation: orientation,
                developedCrop: crop
            )

            for developedPoint in developedPoints {
                let sourcePoint = transform.sourceNormalizedPoint(
                    fromDisplayNormalized: developedPoint
                )
                expectEqual(
                    transform.displayNormalizedPoint(fromSourceNormalized: sourcePoint),
                    developedPoint
                )
            }
        }
    }

    @Test("invalid developed crop geometry is rejected")
    func rejectsInvalidDevelopedCrop() {
        let empty = CGRect(x: 0.5, y: 0.5, width: 0, height: 0.2)
        #expect(throws: DisplayImageTransformError.invalidDevelopedCrop(empty)) {
            try DisplayImageTransform.DevelopedCrop(sourceNormalizedRect: empty)
        }

        #expect(throws: DisplayImageTransformError.invalidStraightenAngle(.infinity)) {
            try DisplayImageTransform.DevelopedCrop(
                sourceNormalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                straightenAngleDegrees: .infinity
            )
        }
    }

    @Test("missing and unknown orientation values use upright orientation")
    func unknownOrientationDefaultsUpright() throws {
        for orientation in [nil, 0, 9] as [Int?] {
            let transform = try DisplayImageTransform(
                sourcePixelWidth: 10,
                sourcePixelHeight: 20,
                exifOrientation: orientation
            )

            #expect(transform.orientation == .up)
            expectEqual(
                transform.displayNormalizedPoint(
                    fromSourceNormalized: CGPoint(x: 0.25, y: 0.75)
                ),
                CGPoint(x: 0.25, y: 0.75)
            )
        }
    }

    @Test("non-positive source dimensions are rejected", arguments: [
        (0, 20),
        (10, 0),
        (-1, 20),
        (10, -1)
    ])
    func rejectsInvalidDimensions(_ width: Int, _ height: Int) {
        #expect(throws: DisplayImageTransformError.invalidSourcePixelSize(
            width: width,
            height: height
        )) {
            try DisplayImageTransform(
                sourcePixelWidth: width,
                sourcePixelHeight: height
            )
        }
    }

    private func expectEqual(
        _ actual: CGPoint,
        _ expected: CGPoint,
        accuracy: CGFloat = 0.000_000_1,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            abs(actual.x - expected.x) <= accuracy
                && abs(actual.y - expected.y) <= accuracy,
            sourceLocation: sourceLocation
        )
    }

    private func expectEqual(
        _ actual: CGRect,
        _ expected: CGRect,
        accuracy: CGFloat = 0.000_000_1,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        expectEqual(actual.origin, expected.origin, accuracy: accuracy, sourceLocation: sourceLocation)
        expectEqual(
            CGPoint(x: actual.width, y: actual.height),
            CGPoint(x: expected.width, y: expected.height),
            accuracy: accuracy,
            sourceLocation: sourceLocation
        )
    }
}
