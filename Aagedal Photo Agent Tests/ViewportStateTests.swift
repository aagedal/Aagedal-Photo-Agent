import CoreGraphics
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Viewport state")
struct ViewportStateTests {
    @Test("fit centers the image and letterboxes the short view axis")
    func fitGeometry() throws {
        let geometry = try ViewportState(mode: .fit).geometry(
            displayedPixelSize: CGSize(width: 400, height: 200),
            viewSize: CGSize(width: 300, height: 300),
            backingScale: 2
        )

        expectEqual(geometry.imagePixelsPerBackingPixel, 2.0 / 3.0)
        expectEqual(geometry.imageRectInView, CGRect(x: 0, y: 75, width: 300, height: 150))
        expectEqual(
            geometry.normalizedDisplayPoint(fromViewPoint: CGPoint(x: 150, y: 150)),
            CGPoint(x: 0.5, y: 0.5)
        )
    }

    @Test("fit always uses the canonical center")
    func fitIgnoresStalePan() throws {
        let geometry = try ViewportState(
            mode: .fit,
            normalizedCenter: CGPoint(x: 0.1, y: 0.9)
        ).geometry(
            displayedPixelSize: CGSize(width: 400, height: 200),
            viewSize: CGSize(width: 300, height: 300),
            backingScale: 1
        )

        expectEqual(geometry.imageRectInView, CGRect(x: 0, y: 75, width: 300, height: 150))
    }

    @Test("actual pixels account for Retina backing scale")
    func actualPixelGeometry() throws {
        let geometry = try ViewportState(mode: .actualPixels).geometry(
            displayedPixelSize: CGSize(width: 800, height: 600),
            viewSize: CGSize(width: 300, height: 200),
            backingScale: 2
        )

        #expect(geometry.imagePixelsPerBackingPixel == 1)
        expectEqual(geometry.imageRectInView, CGRect(x: -50, y: -50, width: 400, height: 300))
        expectEqual(
            geometry.displayPixelPoint(fromViewPoint: CGPoint(x: 150, y: 100)),
            CGPoint(x: 400, y: 300)
        )
    }

    @Test("custom zoom and pan place the requested image center at the view center")
    func customZoomAndPan() throws {
        let state = ViewportState(
            mode: .custom(imagePixelsPerBackingPixel: 0.5),
            normalizedCenter: CGPoint(x: 0.25, y: 0.75),
            interpolation: .nearest
        )
        let geometry = try state.geometry(
            displayedPixelSize: CGSize(width: 1000, height: 500),
            viewSize: CGSize(width: 400, height: 300),
            backingScale: 2
        )

        expectEqual(
            geometry.normalizedDisplayPoint(fromViewPoint: CGPoint(x: 200, y: 150)),
            state.normalizedCenter
        )
        #expect(state.interpolation == .nearest)
    }

    @Test("view and image points and rectangles round-trip")
    func coordinateRoundTrips() throws {
        let geometry = try ViewportState(
            mode: .custom(imagePixelsPerBackingPixel: 0.75),
            normalizedCenter: CGPoint(x: 0.6, y: 0.4)
        ).geometry(
            displayedPixelSize: CGSize(width: 1200, height: 800),
            viewSize: CGSize(width: 640, height: 480),
            backingScale: 2
        )
        let viewPoint = CGPoint(x: 17, y: 429)
        let viewRect = CGRect(x: 25, y: 35, width: 210, height: 175)

        expectEqual(
            geometry.viewPoint(
                fromNormalizedDisplay: geometry.normalizedDisplayPoint(
                    fromViewPoint: viewPoint
                )
            ),
            viewPoint
        )
        expectEqual(
            geometry.viewRect(
                fromNormalizedDisplay: geometry.normalizedDisplayRect(
                    fromViewRect: viewRect
                )
            ),
            viewRect
        )
        expectEqual(
            geometry.viewPoint(
                fromDisplayPixel: geometry.displayPixelPoint(fromViewPoint: viewPoint)
            ),
            viewPoint
        )
    }

    @Test("pan clamping centers fitting axes and constrains oversized axes")
    func clampsPan() throws {
        let state = ViewportState(
            mode: .actualPixels,
            normalizedCenter: CGPoint(x: -1, y: 2)
        )
        let clamped = try state.clamped(
            displayedPixelSize: CGSize(width: 1000, height: 100),
            viewSize: CGSize(width: 400, height: 300),
            backingScale: 1
        )

        // 40% of the image is visible horizontally, while the entire height fits.
        expectEqual(clamped.normalizedCenter, CGPoint(x: 0.2, y: 0.5))
    }

    @Test("invalid geometry inputs and custom scales are rejected")
    func rejectsInvalidInput() {
        #expect(throws: ViewportStateError.invalidDisplayedPixelSize(.zero)) {
            try ViewportState().geometry(
                displayedPixelSize: .zero,
                viewSize: CGSize(width: 10, height: 10),
                backingScale: 1
            )
        }
        #expect(throws: ViewportStateError.invalidViewSize(.zero)) {
            try ViewportState().geometry(
                displayedPixelSize: CGSize(width: 10, height: 10),
                viewSize: .zero,
                backingScale: 1
            )
        }
        #expect(throws: ViewportStateError.invalidBackingScale(0)) {
            try ViewportState().geometry(
                displayedPixelSize: CGSize(width: 10, height: 10),
                viewSize: CGSize(width: 10, height: 10),
                backingScale: 0
            )
        }
        #expect(throws: ViewportStateError.invalidCustomScale(0)) {
            try ViewportState(
                mode: .custom(imagePixelsPerBackingPixel: 0)
            ).geometry(
                displayedPixelSize: CGSize(width: 10, height: 10),
                viewSize: CGSize(width: 10, height: 10),
                backingScale: 1
            )
        }
    }

    private func expectEqual(
        _ actual: CGFloat,
        _ expected: CGFloat,
        accuracy: CGFloat = 0.000_000_1,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual - expected) <= accuracy, sourceLocation: sourceLocation)
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
