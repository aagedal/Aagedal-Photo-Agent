import CoreGraphics
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop interaction behavior")
struct DevelopInteractionBehaviorTests {
    private let urls = (0..<5).map { URL(fileURLWithPath: "/tmp/image-\($0).jpg") }

    @Test("Deletion selects the next image when both neighbors are equally close")
    func deletionPrefersNextNeighbor() {
        let result = BrowserViewModel.closestSurvivingImageURL(
            in: urls,
            around: urls[2],
            deleting: [urls[2]]
        )

        #expect(result == urls[3])
    }

    @Test("Deletion searches past a deleted run to the actually closest neighbor")
    func deletionSearchesByOriginalDistance() {
        let result = BrowserViewModel.closestSurvivingImageURL(
            in: urls,
            around: urls[2],
            deleting: [urls[2], urls[3], urls[4]]
        )

        #expect(result == urls[1])
    }

    @Test("Deleting the final image selects its previous neighbor")
    func deletingFinalImageSelectsPrevious() {
        let result = BrowserViewModel.closestSurvivingImageURL(
            in: urls,
            around: urls[4],
            deleting: [urls[4]]
        )

        #expect(result == urls[3])
    }

    @Test("Deleting a C2PA image immediately removes its stale visible-cache entry")
    @MainActor
    func deletingC2PAImageRebuildsVisibleCacheImmediately() async {
        var signedImage = ImageFile(url: urls[1])
        signedImage.hasC2PA = true
        let survivingImage = ImageFile(url: urls[2])
        let viewModel = BrowserViewModel(imageTrashHandler: TrashStub())
        viewModel.images = [signedImage, survivingImage]
        await Task.yield()
        viewModel.selectedImageIDs = [signedImage.url]
        viewModel.lastClickedImageURL = signedImage.url

        viewModel.deleteSelectedImages()

        #expect(viewModel.images.map(\.url) == [survivingImage.url])
        #expect(viewModel.visibleImages.map(\.url) == [survivingImage.url])
        #expect(viewModel.selectedImageIDs == [survivingImage.url])
    }

    @Test("Trash failures keep the C2PA image and report the filesystem error")
    @MainActor
    func c2paTrashFailureIsReported() async {
        var signedImage = ImageFile(url: urls[1])
        signedImage.hasC2PA = true
        let viewModel = BrowserViewModel(
            imageTrashHandler: TrashStub(failingURLs: [signedImage.url])
        )
        viewModel.images = [signedImage]
        await Task.yield()
        viewModel.selectedImageIDs = [signedImage.url]

        viewModel.deleteSelectedImages()

        #expect(viewModel.images.map(\.url) == [signedImage.url])
        #expect(viewModel.selectedImageIDs == [signedImage.url])
        #expect(viewModel.errorMessage?.contains(signedImage.filename) == true)
        #expect(viewModel.errorMessage?.contains("Test trash failure") == true)
    }

    @Test("Brush axis follows the first dominant cursor direction")
    func brushAxisInference() {
        let start = CGPoint(x: 40, y: 50)

        #expect(BrushStrokeAxis.inferred(from: start, to: CGPoint(x: 70, y: 55)) == .horizontal)
        #expect(BrushStrokeAxis.inferred(from: start, to: CGPoint(x: 45, y: 80)) == .vertical)
    }

    @Test("Brush axis projection makes a perfectly straight line")
    func brushAxisProjection() {
        let start = CGPoint(x: 40, y: 50)
        let point = CGPoint(x: 70, y: 80)

        #expect(BrushStrokeAxis.horizontal.constrain(point, from: start) == CGPoint(x: 70, y: 50))
        #expect(BrushStrokeAxis.vertical.constrain(point, from: start) == CGPoint(x: 40, y: 80))
    }

    @Test("Enabling anonymizer starts at a useful strength")
    func anonymizerToggleUsesDefaultStrength() {
        var settings: AnonymizerSettings?

        AnonymizerToggleBehavior.setEnabled(true, settings: &settings)

        #expect(settings?.amount == 30)
        #expect(AnonymizerToggleBehavior.isEnabled(settings))

        AnonymizerToggleBehavior.setEnabled(false, settings: &settings)
        #expect(settings == nil)
    }

    @Test("Enabling anonymizer preserves an existing strength")
    func anonymizerTogglePreservesExistingStrength() {
        var settings: AnonymizerSettings? = AnonymizerSettings(amount: 72, blackOut: nil)

        AnonymizerToggleBehavior.setEnabled(true, settings: &settings)

        #expect(settings?.amount == 72)
    }

    private struct TrashStub: ImageTrashHandling {
        var failingURLs: Set<URL> = []

        func trashItem(at url: URL) throws {
            if failingURLs.contains(url) {
                throw NSError(
                    domain: "DevelopInteractionBehaviorTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Test trash failure"]
                )
            }
        }
    }

    @Test("Preview cursor maps through the active viewport")
    func previewCursorMapsToDisplayUV() throws {
        let uv = try #require(EditPreviewCoordinateMapper.displayUV(
            forPanePoint: CGPoint(x: 100, y: 150),
            paneSize: CGSize(width: 400, height: 200),
            viewportOrigin: SIMD2<Float>(0.2, 0.3),
            viewportSize: SIMD2<Float>(0.5, 0.25)
        ))

        #expect(abs(uv.x - 0.325) < 0.0001)
        #expect(abs(uv.y - 0.4875) < 0.0001)
    }

    @Test("Preview cursor ignores letterboxing outside the image")
    func previewCursorRejectsLetterbox() {
        let uv = EditPreviewCoordinateMapper.displayUV(
            forPanePoint: .zero,
            paneSize: CGSize(width: 400, height: 200),
            viewportOrigin: SIMD2<Float>(-0.25, 0),
            viewportSize: SIMD2<Float>(1.5, 1)
        )

        #expect(uv == nil)
    }

    @Test("Resetting Global preserves local layers and framing")
    func globalResetPreservesOtherLayers() {
        let mask = MaskAdjustment(name: "Local", exposure: 1)
        let watermark = WatermarkLayer(libraryAssetID: UUID())
        let crop = CameraRawCrop(top: 0.1, left: 0.2, bottom: 0.9, right: 0.8, angle: 2, hasCrop: true)
        let order: [LayerRef] = [.mask(mask.id), .global, .watermark(watermark.id)]
        var settings = CameraRawSettings(
            whiteBalance: "Custom",
            temperature: 7200,
            exposure2012: 1.25,
            sharpness: 50,
            clarity2012: 24,
            dehaze: 19,
            crop: crop,
            hdrEditMode: 1,
            sdrBrightness: 20,
            toneCurve: ToneCurve(
                master: [ToneCurvePoint(x: 0, y: 0.1), ToneCurvePoint(x: 1, y: 1)],
                red: nil, green: nil, blue: nil
            ),
            localAdjustments: [mask],
            watermarkLayers: [watermark],
            anonymizer: AnonymizerSettings(amount: 30, blackOut: nil),
            layerOrder: order
        )

        GlobalLayerResetBehavior.reset(&settings, isRaw: true)

        #expect(settings.whiteBalance == "As Shot")
        #expect(settings.temperature == nil)
        #expect(settings.exposure2012 == nil)
        #expect(settings.sharpness == nil)
        #expect(settings.clarity2012 == nil)
        #expect(settings.dehaze == nil)
        #expect(settings.toneCurve == nil)
        #expect(settings.anonymizer == nil)
        #expect(settings.crop == crop)
        #expect(settings.hdrEditMode == 1)
        #expect(settings.sdrBrightness == nil)
        #expect(settings.localAdjustments == [mask])
        #expect(settings.watermarkLayers == [watermark])
        #expect(settings.layerOrder == order)
    }
}
