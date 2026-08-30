import AppKit
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
        await viewModel.waitForPendingImageMutation()

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
        await viewModel.waitForPendingImageMutation()

        #expect(viewModel.images.map(\.url) == [signedImage.url])
        #expect(viewModel.selectedImageIDs == [signedImage.url])
        #expect(viewModel.errorMessage?.contains(signedImage.filename) == true)
        #expect(viewModel.errorMessage?.contains("Test trash failure") == true)
    }

    @Test("Rating an image out of the active filter advances full screen to the next image")
    @MainActor
    func ratingOutOfFilterAdvancesFullScreen() async {
        var images = urls.prefix(3).map { ImageFile(url: $0) }
        for index in images.indices {
            images[index].starRating = .five
        }
        let viewModel = BrowserViewModel()
        viewModel.sortOrder = .name
        viewModel.sortReversed = false
        viewModel.images = images
        viewModel.minimumStarRating = .three
        await Task.yield()

        viewModel.selectedImageIDs = [urls[1]]
        viewModel.lastClickedImageURL = urls[1]
        viewModel.isFullScreen = true

        viewModel.setRating(.two)

        #expect(viewModel.visibleImages.map(\.url) == [urls[0], urls[2]])
        #expect(viewModel.selectedImageIDs == [urls[2]])
        #expect(viewModel.lastClickedImageURL == urls[2])
        #expect(viewModel.isFullScreen)
    }

    @Test("Labeling the final image out of the active filter selects its previous neighbor")
    @MainActor
    func labelOutOfFilterSelectsPreviousFullScreenImage() async {
        var images = urls.prefix(3).map { ImageFile(url: $0) }
        for index in images.indices {
            images[index].colorLabel = .red
        }
        let viewModel = BrowserViewModel()
        viewModel.sortOrder = .name
        viewModel.sortReversed = false
        viewModel.images = images
        viewModel.selectedColorLabels = [.red]
        await Task.yield()

        viewModel.selectedImageIDs = [urls[2]]
        viewModel.lastClickedImageURL = urls[2]
        viewModel.isFullScreen = true

        viewModel.setLabel(.blue)

        #expect(viewModel.visibleImages.map(\.url) == [urls[0], urls[1]])
        #expect(viewModel.selectedImageIDs == [urls[1]])
        #expect(viewModel.lastClickedImageURL == urls[1])
        #expect(viewModel.isFullScreen)
    }

    @Test("Filtering the last full-screen image out closes full screen")
    @MainActor
    func filteringLastFullScreenImageOutClosesFullScreen() async {
        var image = ImageFile(url: urls[0])
        image.starRating = .five
        let viewModel = BrowserViewModel()
        viewModel.images = [image]
        viewModel.minimumStarRating = .three
        await Task.yield()

        viewModel.selectedImageIDs = [image.url]
        viewModel.lastClickedImageURL = image.url
        viewModel.isFullScreen = true

        viewModel.setRating(.two)

        #expect(viewModel.visibleImages.isEmpty)
        #expect(viewModel.selectedImageIDs.isEmpty)
        #expect(viewModel.lastClickedImageURL == nil)
        #expect(!viewModel.isFullScreen)
    }

    @Test("Explicit sort selection persists across browser model recreation")
    @MainActor
    func explicitSortSelectionPersistsAcrossRecreation() {
        let defaults = UserDefaults.standard
        let sortKey = UserDefaultsKeys.thumbnailSortOrder
        let reverseKey = UserDefaultsKeys.thumbnailSortReversed
        let originalSort = defaults.object(forKey: sortKey)
        let originalReverse = defaults.object(forKey: reverseKey)
        defer {
            if let originalSort {
                defaults.set(originalSort, forKey: sortKey)
            } else {
                defaults.removeObject(forKey: sortKey)
            }
            if let originalReverse {
                defaults.set(originalReverse, forKey: reverseKey)
            } else {
                defaults.removeObject(forKey: reverseKey)
            }
        }

        defaults.set(BrowserViewModel.SortOrder.name.rawValue, forKey: sortKey)
        defaults.set(false, forKey: reverseKey)
        let first = BrowserViewModel()

        first.selectSortOrder(.fileType)
        first.sortReversed = true

        #expect(defaults.string(forKey: sortKey) == BrowserViewModel.SortOrder.fileType.rawValue)
        #expect(defaults.bool(forKey: reverseKey))

        let recreated = BrowserViewModel()
        #expect(recreated.sortOrder == .fileType)
        #expect(recreated.sortReversed)

        recreated.selectSortOrder(.fileType)
        #expect(recreated.sortOrder == .fileType)
        #expect(defaults.string(forKey: sortKey) == BrowserViewModel.SortOrder.fileType.rawValue)
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

    @Test("Develop slider preferences ignore protected and unknown controls")
    func developSliderPreferencesProtectCoreControls() {
        let hidden = DevelopSlider.decodeHidden([
            "contrast",
            "filmGrain",
            "hsl",
            "toneCurve",
            "exposure",
            "temperature",
            "tint",
            "crop",
            "futureControl",
        ])

        #expect(hidden == [.contrast, .filmGrain, .hsl, .toneCurve])
        #expect(!DevelopSlider.allCases.contains { $0.rawValue == "exposure" })
        #expect(!DevelopSlider.allCases.contains { $0.rawValue == "temperature" })
        #expect(!DevelopSlider.allCases.contains { $0.rawValue == "tint" })
        #expect(!DevelopSlider.allCases.contains { $0.rawValue == "crop" })
    }

    @Test("Every optional Develop slider belongs to one settings group")
    func developSliderGroupsCoverInventory() {
        let grouped = Set(DevelopSliderGroup.allCases.flatMap { group in
            group.sliders
        })
        #expect(grouped == Set(DevelopSlider.allCases))
    }

    @Test("Default Develop section order places Anonymizer before Film Emulation")
    func defaultDevelopSectionOrderPrioritizesAnonymizer() throws {
        let anonymizerIndex = try #require(
            DevelopPanelSection.defaultOrder.firstIndex(of: .anonymizer)
        )
        let filmIndex = try #require(
            DevelopPanelSection.defaultOrder.firstIndex(of: .filmEmulation)
        )
        #expect(anonymizerIndex < filmIndex)
        #expect(Set(DevelopPanelSection.defaultOrder) == Set(DevelopPanelSection.allCases))
    }

    @Test("Develop section order preserves valid choices and repairs stored values")
    func developSectionOrderDecoding() {
        let decoded = DevelopPanelSection.decodeOrder([
            "filmEmulation",
            "color",
            "filmEmulation",
            "futureSection",
        ])

        #expect(decoded.prefix(2) == [.filmEmulation, .color])
        #expect(decoded.count == DevelopPanelSection.allCases.count)
        #expect(Set(decoded) == Set(DevelopPanelSection.allCases))
    }

    @Test("Develop sections own every optional slider exactly once")
    func developSectionSliderMappingIsComplete() {
        let mapped = DevelopPanelSection.allCases.flatMap(\.optionalSliders)

        #expect(mapped.count == Set(mapped).count)
        #expect(Set(mapped) == Set(DevelopSlider.allCases))
        #expect(DevelopPanelSection.color.alwaysVisibleControlNames == ["White Balance", "Tint"])
        #expect(DevelopPanelSection.exposure.alwaysVisibleControlNames == ["Exposure"])
    }

    @Test("Develop slider groups hide and restore all of their controls")
    func developSliderGroupVisibilityTogglesWholeSection() {
        var hidden: Set<DevelopSlider> = [.contrast, .filmGrain]

        DevelopSliderGroup.detail.setVisible(false, hiddenSliders: &hidden)

        #expect(!DevelopSliderGroup.detail.isVisible(hiddenSliders: hidden))
        #expect(DevelopSliderGroup.detail.sliders.allSatisfy(hidden.contains))
        #expect(hidden.contains(.contrast))
        #expect(hidden.contains(.filmGrain))

        DevelopSliderGroup.detail.setVisible(true, hiddenSliders: &hidden)

        #expect(DevelopSliderGroup.detail.isVisible(hiddenSliders: hidden))
        #expect(DevelopSliderGroup.detail.sliders.allSatisfy { !hidden.contains($0) })
        #expect(hidden.contains(.contrast))
        #expect(hidden.contains(.filmGrain))
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

    @Test("Develop preview zoom supports 4000 percent across input paths")
    func developPreviewZoomLimit() {
        #expect(EditZoomBehavior.maximumScale == 40)
        #expect(EditZoomBehavior.clampedScale(10) == 10)
        #expect(EditZoomBehavior.clampedScale(80) == 40)
        #expect(EditZoomBehavior.clampedScale(0.5) == 1)
    }

    @Test("Crop handle padding is limited to the active crop tool")
    func cropPreviewHandlePadding() {
        #expect(EditCropPreviewFraming.handlePadding(isCropToolActive: true) == 64)
        #expect(EditCropPreviewFraming.handlePadding(isCropToolActive: false) == 0)
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

@Suite("Develop mask interaction coordinator")
@MainActor
struct DevelopMaskInteractionCoordinatorTests {
    @Test("an image change clears its matte preview but preserves brush tool state")
    func imageChangePreservesBrushToolState() {
        let coordinator = DevelopMaskInteractionCoordinator()
        let firstURL = URL(fileURLWithPath: "/tmp/mask-session-first.raw")
        let secondURL = URL(fileURLWithPath: "/tmp/mask-session-second.raw")
        let maskID = UUID()

        coordinator.beginImageSession(firstURL)
        coordinator.brushRadius = 0.12
        coordinator.brushHardness = 0.8
        coordinator.brushFlow = 0.35
        coordinator.brushErase = true
        coordinator.beginBrushPainting()
        #expect(coordinator.setMattePreview(maskID: maskID, visible: true))

        coordinator.beginImageSession(secondURL)

        #expect(coordinator.activeImageURL == secondURL)
        #expect(coordinator.isBrushPainting)
        #expect(coordinator.mattePreviewMaskID == nil)
        #expect(coordinator.brushRadius == 0.12)
        #expect(coordinator.brushHardness == 0.8)
        #expect(coordinator.brushFlow == 0.35)
        #expect(coordinator.brushErase)
    }

    @Test("layer selection retains painting only for brush masks")
    func layerSelectionOwnsBrushPaintingLifecycle() {
        let coordinator = DevelopMaskInteractionCoordinator()
        coordinator.beginBrushPainting()

        coordinator.selectedLayerDidChange(isBrush: true)
        #expect(coordinator.isBrushPainting)

        coordinator.selectedLayerDidChange(isBrush: false)
        #expect(!coordinator.isBrushPainting)
    }

    @Test("a stale hover exit cannot clear a newer matte preview")
    func staleHoverExitCannotClearNewPreview() {
        let coordinator = DevelopMaskInteractionCoordinator()
        let firstMaskID = UUID()
        let secondMaskID = UUID()

        #expect(coordinator.setMattePreview(maskID: firstMaskID, visible: true))
        #expect(coordinator.setMattePreview(maskID: secondMaskID, visible: true))
        #expect(!coordinator.setMattePreview(maskID: firstMaskID, visible: false))
        #expect(coordinator.mattePreviewMaskID == secondMaskID)
        #expect(coordinator.setMattePreview(maskID: secondMaskID, visible: false))
        #expect(coordinator.mattePreviewMaskID == nil)
    }
}

@Suite("Develop preview navigation coordinator")
@MainActor
struct DevelopPreviewNavigationCoordinatorTests {
    @Test("magnification is dampened from the last committed scale and capped")
    func magnificationUsesCommittedScaleAndBounds() {
        let coordinator = DevelopPreviewNavigationCoordinator()

        coordinator.updateMagnification(3.0)
        #expect(coordinator.zoomScale == 1.8)
        coordinator.finishMagnification()

        coordinator.updateMagnification(100)
        #expect(coordinator.zoomScale == EditZoomBehavior.maximumScale)
        #expect(coordinator.committedZoomScale == 1.8)
        coordinator.finishMagnification()
        #expect(coordinator.committedZoomScale == EditZoomBehavior.maximumScale)
    }

    @Test("a discrete return to fit clears live and committed pan anchors")
    func returnToFitRecentersNavigation() {
        let coordinator = DevelopPreviewNavigationCoordinator()
        coordinator.applyZoom(scale: 4, anchoredOffset: CGSize(width: 80, height: -60))
        #expect(coordinator.updatePan(translation: CGSize(width: 25, height: 10)))

        coordinator.applyZoom(scale: 1)

        #expect(coordinator.zoomScale == 1)
        #expect(coordinator.committedZoomScale == 1)
        #expect(coordinator.offset == .zero)
        #expect(coordinator.committedOffset == .zero)
        #expect(!coordinator.updatePan(translation: CGSize(width: 10, height: 10)))
    }

    @Test("pan uses the committed gesture anchor and completion constrains both copies")
    func panAnchorsAndConstrains() {
        let coordinator = DevelopPreviewNavigationCoordinator()
        coordinator.applyZoom(scale: 2, anchoredOffset: CGSize(width: 20, height: -10))

        #expect(coordinator.updatePan(translation: CGSize(width: 100, height: -100)))
        #expect(coordinator.offset == CGSize(width: 120, height: -110))

        coordinator.constrainOffset(maximum: CGSize(width: 75, height: 40))
        #expect(coordinator.offset == CGSize(width: 75, height: -40))
        #expect(coordinator.committedOffset == CGSize(width: 75, height: -40))

        #expect(coordinator.updatePan(translation: CGSize(width: -5, height: 6)))
        #expect(coordinator.offset == CGSize(width: 70, height: -34))
    }

    @Test("an image-session reset clears every navigation value")
    func resetClearsNavigationSession() {
        let coordinator = DevelopPreviewNavigationCoordinator()
        coordinator.applyZoom(scale: 6, anchoredOffset: CGSize(width: 42, height: 18))

        coordinator.reset()

        #expect(coordinator.zoomScale == 1)
        #expect(coordinator.committedZoomScale == 1)
        #expect(coordinator.offset == .zero)
        #expect(coordinator.committedOffset == .zero)
    }

    @Test("gesture recentering clears pan without changing zoom")
    func recenterPreservesZoom() {
        let coordinator = DevelopPreviewNavigationCoordinator()
        coordinator.applyZoom(scale: 3, anchoredOffset: CGSize(width: 18, height: -9))

        coordinator.recenter()

        #expect(coordinator.zoomScale == 3)
        #expect(coordinator.committedZoomScale == 3)
        #expect(coordinator.offset == .zero)
        #expect(coordinator.committedOffset == .zero)
    }
}

@Suite("Develop preview session coordinator")
@MainActor
struct DevelopPreviewSessionCoordinatorTests {
    @Test("an image change cancels every source-lifecycle task and resets progress")
    func imageChangeCancelsTasksAndResetsProgress() {
        let coordinator = DevelopPreviewSessionCoordinator()
        let firstURL = URL(fileURLWithPath: "/tmp/preview-session-first.raw")
        let secondURL = URL(fileURLWithPath: "/tmp/preview-session-second.raw")
        let sourceLoad = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        let adjacentPrecache = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        let fullResolutionUpgrade = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }

        coordinator.beginImageSession(firstURL, orientation: 6)
        coordinator.isLoadingPreview = true
        coordinator.isDecodingFullResolution = true
        coordinator.isEditFullResLoaded = true
        coordinator.replaceSourceLoadTask(with: sourceLoad)
        coordinator.replaceAdjacentPrecacheTask(with: adjacentPrecache)
        coordinator.replaceFullResolutionUpgradeTask(with: fullResolutionUpgrade)
        let firstGeneration = coordinator.sessionGeneration

        coordinator.beginImageSession(secondURL, orientation: 1)
        let replacementUpgrade = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        defer { replacementUpgrade.cancel() }
        coordinator.replaceFullResolutionUpgradeTask(with: replacementUpgrade)
        coordinator.finishFullResolutionUpgrade(sessionGeneration: firstGeneration)

        #expect(sourceLoad.isCancelled)
        #expect(adjacentPrecache.isCancelled)
        #expect(fullResolutionUpgrade.isCancelled)
        #expect(coordinator.sourceLoadTask == nil)
        #expect(coordinator.adjacentPrecacheTask == nil)
        #expect(coordinator.fullResolutionUpgradeTask != nil)
        #expect(coordinator.activeImageURL == secondURL)
        #expect(coordinator.sourceLoadedURL == secondURL)
        #expect(coordinator.sourceLoadedOrientation == 1)
        #expect(!coordinator.isLoadingPreview)
        #expect(!coordinator.isDecodingFullResolution)
        #expect(!coordinator.isEditFullResLoaded)
    }

    @Test("source identity permits in-place rotation only for the active decoded image")
    func sourceIdentityGatesInPlaceRotation() {
        let coordinator = DevelopPreviewSessionCoordinator()
        let loadedURL = URL(fileURLWithPath: "/tmp/preview-session-loaded.jpg")
        let otherURL = URL(fileURLWithPath: "/tmp/preview-session-other.jpg")

        coordinator.beginImageSession(loadedURL, orientation: 6)

        #expect(coordinator.loadedOrientation(for: loadedURL) == 6)
        #expect(coordinator.loadedOrientation(for: otherURL) == nil)
        coordinator.recordLoadedOrientation(8)
        #expect(coordinator.loadedOrientation(for: loadedURL) == 8)

        coordinator.endImageSession()
        #expect(coordinator.activeImageURL == nil)
        #expect(coordinator.sourceLoadedURL == nil)
        #expect(coordinator.sourceLoadedOrientation == nil)
    }
}

@Suite("Develop preview render coordinator")
@MainActor
struct DevelopPreviewRenderCoordinatorTests {
    @Test("a replacement request rejects a cancelled renderer's late publication")
    func replacementRejectsLatePublication() async throws {
        let coordinator = DevelopPreviewRenderCoordinator()
        let staleImage = NSImage(size: NSSize(width: 10, height: 10))
        let currentImage = NSImage(size: NSSize(width: 20, height: 20))
        var publishedWidths: [Int] = []

        coordinator.beginImageSession()
        coordinator.requestRender(
            fallback: nil,
            isHDR: false,
            operation: {
                try? await Task.sleep(for: .milliseconds(80))
                return Self.output(image: staleImage, width: 10)
            },
            scopePublisher: { image, _ in publishedWidths.append(image?.width ?? 0) }
        )
        await Task.yield()
        coordinator.requestRender(
            fallback: nil,
            isHDR: false,
            operation: { Self.output(image: currentImage, width: 20) },
            scopePublisher: { image, _ in publishedWidths.append(image?.width ?? 0) }
        )

        try await eventually { coordinator.previewImage === currentImage }
        try await Task.sleep(for: .milliseconds(100))

        #expect(coordinator.previewImage === currentImage)
        #expect(publishedWidths == [20])
        #expect(!coordinator.isRendering)
    }

    @Test("ending an image session clears output and rejects an uncooperative late render")
    func endingSessionRejectsLateRender() async throws {
        let coordinator = DevelopPreviewRenderCoordinator()
        let image = NSImage(size: NSSize(width: 10, height: 10))
        var publicationCount = 0

        coordinator.requestRender(
            fallback: nil,
            isHDR: true,
            operation: {
                try? await Task.sleep(for: .milliseconds(50))
                return Self.output(image: image, width: 10)
            },
            scopePublisher: { _, _ in publicationCount += 1 }
        )
        coordinator.endImageSession()
        try await Task.sleep(for: .milliseconds(80))

        #expect(coordinator.previewImage == nil)
        #expect(publicationCount == 0)
        #expect(!coordinator.isRendering)
    }

    @Test("a failed materialization preserves the source fallback and scope HDR state")
    func failedMaterializationUsesFallback() async throws {
        let coordinator = DevelopPreviewRenderCoordinator()
        let fallback = NSImage(size: NSSize(width: 30, height: 30))
        var published: (hasImage: Bool, isHDR: Bool)?

        coordinator.requestRender(
            fallback: fallback,
            isHDR: true,
            operation: { nil },
            scopePublisher: { image, isHDR in
                published = (image != nil, isHDR)
            }
        )
        try await eventually { !coordinator.isRendering }

        #expect(coordinator.previewImage === fallback)
        #expect(published?.hasImage == false)
        #expect(published?.isHDR == true)
    }

    @Test("explicit cancellation retains the last preview and rejects late publication")
    func cancellationRetainsLastPreview() async throws {
        let coordinator = DevelopPreviewRenderCoordinator()
        let retained = NSImage(size: NSSize(width: 15, height: 15))
        let late = NSImage(size: NSSize(width: 40, height: 40))
        var publishedWidths: [Int] = []

        coordinator.publishFallback(
            retained,
            isHDR: false,
            scopePublisher: { image, _ in publishedWidths.append(image?.width ?? 0) }
        )
        coordinator.requestRender(
            fallback: retained,
            isHDR: false,
            operation: {
                try? await Task.sleep(for: .milliseconds(50))
                return Self.output(image: late, width: 40)
            },
            scopePublisher: { image, _ in publishedWidths.append(image?.width ?? 0) }
        )
        coordinator.cancelRender()
        try await Task.sleep(for: .milliseconds(80))

        #expect(coordinator.previewImage === retained)
        #expect(publishedWidths == [0])
        #expect(!coordinator.isRendering)
    }

    private static func output(image: NSImage, width: Int) -> DevelopPreviewRenderCoordinator.Output {
        let context = CGContext(
            data: nil,
            width: width,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return DevelopPreviewRenderCoordinator.Output(
            previewImage: image,
            scopeImage: context.makeImage()!
        )
    }

    private func eventually(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for preview render state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
