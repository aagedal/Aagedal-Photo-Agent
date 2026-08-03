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

    @Test("different aspect ratios retain one logical center and clamp independently")
    func mismatchedAspectRatioClamping() throws {
        let shared = ViewportState(
            mode: .actualPixels,
            normalizedCenter: CGPoint(x: 0.1, y: 0.9)
        )
        let landscape = try shared.clamped(
            displayedPixelSize: CGSize(width: 1000, height: 200),
            viewSize: CGSize(width: 300, height: 300),
            backingScale: 1
        )
        let portrait = try shared.clamped(
            displayedPixelSize: CGSize(width: 200, height: 1000),
            viewSize: CGSize(width: 300, height: 300),
            backingScale: 1
        )

        // The short axis fits and centers. The oversized axis clamps only at its own edge.
        expectEqual(landscape.normalizedCenter, CGPoint(x: 0.15, y: 0.5))
        expectEqual(portrait.normalizedCenter, CGPoint(x: 0.5, y: 0.85))
        #expect(shared.normalizedCenter == CGPoint(x: 0.1, y: 0.9))
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

@Suite("Image inspection geometry")
struct ImageInspectionGeometryTests {
    @Test("fit geometry honors an inset container and rejects letterbox hover")
    func fitHoverGeometry() throws {
        let geometry = try ImageInspectionGeometry(
            imagePixelSize: CGSize(width: 400, height: 200),
            containerRect: CGRect(x: 8, y: 8, width: 284, height: 284)
        )

        expectEqual(
            geometry.imageRectInView,
            CGRect(x: 8, y: 79, width: 284, height: 142)
        )
        expectEqual(
            geometry.normalizedDisplayPoint(
                fromViewPoint: CGPoint(x: 150, y: 150)
            ) ?? CGPoint(x: -1, y: -1),
            CGPoint(x: 0.5, y: 0.5)
        )
        #expect(
            geometry.normalizedDisplayPoint(
                fromViewPoint: CGPoint(x: 150, y: 40)
            ) == nil
        )
        expectEqual(
            geometry.clampedNormalizedDisplayPoint(
                fromViewPoint: CGPoint(x: 400, y: 40)
            ),
            CGPoint(x: 1, y: 0)
        )
    }

    @Test("source pixel samples remain correct through every EXIF orientation")
    func sourcePixelAcrossOrientations() throws {
        let sourcePixelCenter = CGPoint(x: 100.5, y: 60.5)

        for orientation in 1...8 {
            let transform = try DisplayImageTransform(
                sourcePixelWidth: 400,
                sourcePixelHeight: 300,
                exifOrientation: orientation
            )
            let displayPoint = transform.displayNormalizedPoint(
                fromSourcePixel: sourcePixelCenter
            )
            let sample = ImageInspectionSample(
                normalizedDisplayPoint: displayPoint,
                transform: transform
            )

            #expect(sample.sourcePixel == SourcePixelCoordinate(x: 100, y: 60))
        }
    }

    @Test("developed hover maps through crop and straighten to source pixels")
    func developedSourcePixel() throws {
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

        let sample = ImageInspectionSample(
            normalizedDisplayPoint: CGPoint(x: 0.5, y: 0.5),
            transform: transform
        )

        #expect(sample.sourcePixel == SourcePixelCoordinate(x: 400, y: 660))
    }

    @Test("true-pixel crops clamp at edges and convert the top-left hover origin")
    func truePixelCrop() {
        let extent = CGRect(x: 0, y: 0, width: 100, height: 80)
        let topLeft = ImageInspectionGeometry.centeredPixelCropRect(
            in: extent,
            normalizedDisplayPoint: .zero,
            pixelSize: 20,
            extentOrigin: .bottomLeft
        )
        let bottomRight = ImageInspectionGeometry.centeredPixelCropRect(
            in: extent,
            normalizedDisplayPoint: CGPoint(x: 1, y: 1),
            pixelSize: 20,
            extentOrigin: .bottomLeft
        )

        #expect(topLeft == CGRect(x: 0, y: 60, width: 20, height: 20))
        #expect(bottomRight == CGRect(x: 80, y: 0, width: 20, height: 20))
        #expect(
            ImageInspectionGeometry.centeredPixelCropRect(
                in: .zero,
                normalizedDisplayPoint: .zero,
                pixelSize: 20,
                extentOrigin: .bottomLeft
            ) == nil
        )
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
        expectEqual(
            actual.origin,
            expected.origin,
            accuracy: accuracy,
            sourceLocation: sourceLocation
        )
        expectEqual(
            CGPoint(x: actual.width, y: actual.height),
            CGPoint(x: expected.width, y: expected.height),
            accuracy: accuracy,
            sourceLocation: sourceLocation
        )
    }
}

@Suite("Image preview zoom geometry")
struct ImagePreviewZoomGeometryTests {
    @Test("the hand tool belongs to photo markup, not map markup")
    func handToolPlacement() {
        #expect(AnalysisAnnotationTool.photoTools.contains(.hand))
        #expect(AnalysisAnnotationTool.photoTools.contains(.shape))
        #expect(!AnalysisAnnotationTool.mapTools.contains(.hand))
        #expect(AnalysisAnnotationTool.hand.annotationKind == nil)
        #expect(AnalysisAnnotationTool.shape.annotationKind == .polygon)
    }

    @Test("analysis preview zoom supports 4000 percent")
    func zoomLimit() {
        #expect(ImagePreviewZoomGeometry.maximumScale == 40)
        #expect(ImagePreviewZoomGeometry.clampedScale(80) == 40)
        #expect(ImagePreviewZoomGeometry.clampedScale(0.5) == 1)
    }

    @Test("pan bounds follow the fitted image rather than the viewport outline")
    func fittedImagePanBounds() {
        let viewport = CGSize(width: 400, height: 300)
        let fittedImage = CGRect(x: 0, y: 50, width: 400, height: 200)

        let atFit = ImagePreviewZoomGeometry.clampedOffset(
            CGSize(width: 100, height: 100),
            zoomScale: 1,
            viewportSize: viewport,
            imageRects: [fittedImage]
        )
        #expect(atFit == .zero)

        let atTwoTimes = ImagePreviewZoomGeometry.clampedOffset(
            CGSize(width: 500, height: 500),
            zoomScale: 2,
            viewportSize: viewport,
            imageRects: [fittedImage]
        )
        #expect(atTwoTimes == CGSize(width: 200, height: 50))
    }

    @Test("cursor anchored zoom preserves the point beneath the cursor")
    func cursorAnchoredZoom() {
        let offset = ImagePreviewZoomGeometry.offset(
            anchoredAt: CGPoint(x: 300, y: 100),
            in: CGSize(width: 400, height: 300),
            currentOffset: .zero,
            oldScale: 1,
            newScale: 2
        )

        #expect(offset == CGSize(width: -100, height: 50))
    }
}
