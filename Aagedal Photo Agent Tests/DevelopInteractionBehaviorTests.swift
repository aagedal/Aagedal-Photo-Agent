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

@Suite("Develop layer geometry interaction coordinator")
@MainActor
struct DevelopLayerGeometryInteractionCoordinatorTests {
    @Test("mask and watermark geometry commit exactly once")
    func geometryCommitLifecycle() {
        let coordinator = DevelopLayerGeometryInteractionCoordinator()
        let imageURL = URL(fileURLWithPath: "/tmp/geometry-session/image.raw")
        var mask = EllipseMaskGeometry()
        mask.centerX = 0.25
        var watermark = WatermarkGeometry()
        watermark.centerY = 0.75

        coordinator.beginImageSession(imageURL)
        coordinator.beginMaskDrag()
        coordinator.updateMaskGeometry(mask)
        coordinator.updateWatermarkGeometry(watermark)

        #expect(coordinator.isDraggingMask)
        #expect(coordinator.consumeMaskGeometry() == mask)
        #expect(!coordinator.isDraggingMask)
        #expect(coordinator.consumeMaskGeometry() == nil)
        #expect(coordinator.consumeWatermarkGeometry() == watermark)
        #expect(coordinator.consumeWatermarkGeometry() == nil)
    }

    @Test("image replacement cancels every transient geometry override")
    func imageReplacementClearsGeometry() {
        let coordinator = DevelopLayerGeometryInteractionCoordinator()
        coordinator.beginImageSession(URL(fileURLWithPath: "/tmp/geometry-a.raw"))
        coordinator.beginMaskDrag()
        coordinator.updateMaskGeometry(EllipseMaskGeometry())
        coordinator.updateWatermarkGeometry(WatermarkGeometry())

        let replacement = URL(fileURLWithPath: "/tmp/geometry-b.raw")
        coordinator.beginImageSession(replacement)

        #expect(coordinator.activeImageURL == replacement)
        #expect(!coordinator.isDraggingMask)
        #expect(coordinator.maskGeometry == nil)
        #expect(coordinator.watermarkGeometry == nil)
    }

    @Test("Develop view retains no standalone mask or watermark geometry state")
    func viewDelegationSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains(
            "@State private var layerGeometryInteraction = DevelopLayerGeometryInteractionCoordinator()"
        ))
        #expect(source.contains("layerGeometryInteraction.beginImageSession(selectedImageURL)"))
        #expect(source.contains("layerGeometryInteraction.consumeMaskGeometry()"))
        #expect(source.contains("layerGeometryInteraction.consumeWatermarkGeometry()"))
        #expect(!source.contains("@State private var dragMaskGeometry"))
        #expect(!source.contains("@State private var dragWatermarkGeometry"))
        #expect(!source.contains("@State private var isDraggingMask"))
    }
}

@Suite("Develop export session coordinator")
@MainActor
struct DevelopExportSessionCoordinatorTests {
    @Test("one persistence request owns busy state and publishes its durable output")
    func successfulPersistenceLifecycle() async throws {
        let coordinator = DevelopExportSessionCoordinator()
        let output = URL(fileURLWithPath: "/tmp/develop-export-success.jpg")
        var operationCount = 0

        coordinator.beginWorkspaceSession()
        #expect(coordinator.requestExport {
            operationCount += 1
            try await Task.sleep(for: .milliseconds(40))
            return DevelopExportPersistenceResult(
                outputURL: output,
                metadataWasCopied: true
            )
        })
        #expect(coordinator.isExporting)
        #expect(!coordinator.requestExport {
            operationCount += 1
            return DevelopExportPersistenceResult(
                outputURL: URL(fileURLWithPath: "/tmp/duplicate.jpg"),
                metadataWasCopied: true
            )
        })

        try await eventually { !coordinator.isExporting }

        #expect(operationCount == 1)
        #expect(coordinator.lastPersistedOutputURL == output)
        #expect(coordinator.errorMessage == nil)
    }

    @Test("a durable image with failed metadata copy is surfaced as a warning")
    func metadataFailurePreservesDurableOutputEvidence() async throws {
        let coordinator = DevelopExportSessionCoordinator()
        let output = URL(fileURLWithPath: "/tmp/develop-export-metadata-warning.jpg")

        coordinator.beginWorkspaceSession()
        coordinator.requestExport {
            DevelopExportPersistenceResult(
                outputURL: output,
                metadataWasCopied: false
            )
        }
        try await eventually { !coordinator.isExporting }

        #expect(coordinator.lastPersistedOutputURL == output)
        #expect(
            coordinator.errorMessage
                == "Image saved but metadata copy failed — IPTC data may be missing"
        )
        coordinator.dismissError()
        #expect(coordinator.errorMessage == nil)
    }

    @Test("workspace teardown cancels ownership and rejects an uncooperative late failure")
    func workspaceTeardownRejectsLatePublication() async throws {
        let coordinator = DevelopExportSessionCoordinator()

        coordinator.beginWorkspaceSession()
        coordinator.requestExport {
            try? await Task.sleep(for: .milliseconds(50))
            throw TestError.lateFailure
        }
        await Task.yield()
        coordinator.endWorkspaceSession()
        try await Task.sleep(for: .milliseconds(80))

        #expect(!coordinator.isExporting)
        #expect(!coordinator.isWorkspaceActive)
        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.lastPersistedOutputURL == nil)
    }

    @Test("edit workspace delegates export ownership and persistence to the coordinator")
    func editWorkspaceSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("@State private var exportSession = DevelopExportSessionCoordinator()"))
        #expect(source.contains("exportSession.beginWorkspaceSession()"))
        #expect(source.contains("exportSession.requestExport {"))
        #expect(source.contains("exportSession.endWorkspaceSession()"))
        #expect(source.contains("DevelopExportPersistenceResult("))
        #expect(!source.contains("@State private var isSavingRenderedJPEG"))
        #expect(!source.contains("@State private var saveError"))
    }

    private enum TestError: Error {
        case lateFailure
    }

    private func eventually(
        // The unfiltered suite can fully occupy the cooperative executor while the app test host
        // starts. Keep the success path polling-only, but use the repository's documented
        // long-load ceiling so scheduler starvation is not mistaken for an export-state failure.
        timeout: Duration = .seconds(120),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for Develop export state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite("Color LUT import filesystem boundary")
struct ColorLUTImportServiceTests {
    @Test("a complete immutable LUT snapshot is read away from the main actor")
    @MainActor
    func completeSnapshotRunsOffMainActor() async throws {
        let source = URL(fileURLWithPath: "/virtual/look.cube")
        let bytes = Data("LUT_3D_SIZE 2\n".utf8)
        let requestID = UUID()
        let probe = ColorLUTImportReaderProbe(data: bytes)
        let service = ColorLUTImportService(
            reader: ColorLUTImportReader(read: probe.read)
        )

        let result = try await Task {
            try await service.loadLUT(from: source, requestID: requestID)
        }.value

        #expect(result == .loaded(ColorLUTImportSnapshot(
            requestID: requestID,
            sourceURL: source,
            data: bytes,
            byteCount: bytes.count
        )))
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("overlapping LUT imports serialize and cancellation stops a queued read")
    func serializedQueuedCancellation() async throws {
        let firstURL = URL(fileURLWithPath: "/virtual/first.cube")
        let secondURL = URL(fileURLWithPath: "/virtual/second.cube")
        let firstID = UUID()
        let secondID = UUID()
        let probe = BlockingColorLUTImportReaderProbe()
        let service = ColorLUTImportService(
            reader: ColorLUTImportReader(read: probe.read)
        )
        let first = Task {
            try await service.loadLUT(from: firstURL, requestID: firstID)
        }
        try await probe.waitUntilFirstReadStarts()
        let second = Task {
            try await service.loadLUT(from: secondURL, requestID: secondID)
        }
        second.cancel()
        probe.releaseFirstRead()

        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(firstResult == .loaded(ColorLUTImportSnapshot(
            requestID: firstID,
            sourceURL: firstURL,
            data: Data("first".utf8),
            byteCount: Data("first".utf8).count
        )))
        #expect(secondResult == .cancelledBeforeRead(requestID: secondID))
        #expect(probe.invocationCount == 1)
        #expect(probe.maximumConcurrentReads == 1)
    }

    @Test("cancellation during a non-preemptible LUT read reports byte evidence only")
    func cancellationAfterRead() async throws {
        let source = URL(fileURLWithPath: "/virtual/slow.cube")
        let bytes = Data("complete LUT bytes".utf8)
        let requestID = UUID()
        let service = ColorLUTImportService(
            reader: ColorLUTImportReader { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return bytes
            }
        )

        let result = try await Task {
            try await service.loadLUT(from: source, requestID: requestID)
        }.value

        #expect(result == .cancelledAfterRead(
            requestID: requestID,
            sourceURL: source,
            byteCount: bytes.count
        ))
    }

    @Test("the edit workspace delegates LUT request lifetime and persistence intent")
    func editWorkspaceSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func importColorLUT("))
        let suffix = source[functionStart.lowerBound...]
        let functionEnd = try #require(suffix.range(of: "\n    // MARK: - AI subject/object mask"))
        let functionSource = String(suffix[..<functionEnd.lowerBound])

        #expect(source.contains(
            "@State private var colorLUTImport = DevelopColorLUTImportCoordinator()"
        ))
        #expect(source.contains("colorLUTImport.beginImageSession(selectedImageURL)"))
        #expect(source.contains("colorLUTImport.endImageSession()"))
        #expect(source.contains("colorLUTImport.requestImport(for: layerID)"))
        #expect(functionSource.contains("colorLUTImport.acceptSelection("))
        #expect(functionSource.contains("try await ColorLUTImportService.shared.loadLUT("))
        #expect(functionSource.contains("intent.layerID"))
        #expect(functionSource.contains("intent.displayName"))
        #expect(functionSource.contains("commitEditAdjustments()"))
        #expect(!functionSource.contains("Data(contentsOf:"))
        #expect(!source.contains("@State private var colorLUTImportTask"))
        #expect(!source.contains("@State private var colorLUTImportRequestID"))
        #expect(!source.contains("@State private var importingLUTForLayerID"))
    }

    @Test("coordinator publishes parsed LUT persistence intent and balances URL access")
    @MainActor
    func coordinatorPublishesPersistenceIntent() async throws {
        let source = URL(fileURLWithPath: "/virtual/editorial.cube")
        let image = URL(fileURLWithPath: "/virtual/image.nef")
        let layerID = UUID()
        let data = Self.validCube(title: "  Editorial  ")
        var starts: [URL] = []
        var stops: [URL] = []
        var intents: [DevelopColorLUTPersistenceIntent] = []
        let coordinator = DevelopColorLUTImportCoordinator(
            securityScope: DevelopColorLUTSecurityScope(
                start: { starts.append($0); return true },
                stop: { stops.append($0) }
            )
        )

        coordinator.beginImageSession(image)
        #expect(coordinator.requestImport(for: layerID))
        // Mirrors SwiftUI dismissing the panel immediately before delivering its callback.
        coordinator.setImporterPresented(false)
        coordinator.acceptSelection(
            .success([source]),
            load: { url, requestID in
                .loaded(ColorLUTImportSnapshot(
                    requestID: requestID,
                    sourceURL: url,
                    data: data,
                    byteCount: data.count
                ))
            },
            parse: CubeLUTParser.parse,
            publisher: { intents.append($0) }
        )

        try await eventually { !coordinator.isImporting }
        #expect(starts == [source])
        #expect(stops == [source])
        #expect(intents == [DevelopColorLUTPersistenceIntent(
            layerID: layerID,
            displayName: "Editorial",
            data: data
        )])
        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.targetLayerID == nil)
    }

    @Test("image replacement rejects a non-cooperative LUT completion")
    @MainActor
    func coordinatorRejectsPreviousImageCompletion() async throws {
        let firstImage = URL(fileURLWithPath: "/virtual/first.nef")
        let secondImage = URL(fileURLWithPath: "/virtual/second.nef")
        let source = URL(fileURLWithPath: "/virtual/slow.cube")
        let data = Self.validCube(title: nil)
        var intents: [DevelopColorLUTPersistenceIntent] = []
        let coordinator = DevelopColorLUTImportCoordinator()

        coordinator.beginImageSession(firstImage)
        #expect(coordinator.requestImport(for: UUID()))
        coordinator.acceptSelection(
            .success([source]),
            load: { url, requestID in
                // Deliberately ignore cooperative cancellation to exercise request identity.
                try? await Task.sleep(for: .milliseconds(60))
                return .loaded(ColorLUTImportSnapshot(
                    requestID: requestID,
                    sourceURL: url,
                    data: data,
                    byteCount: data.count
                ))
            },
            parse: CubeLUTParser.parse,
            publisher: { intents.append($0) }
        )
        await Task.yield()
        coordinator.beginImageSession(secondImage)

        try await Task.sleep(for: .milliseconds(100))
        #expect(intents.isEmpty)
        #expect(coordinator.imageURL == secondImage)
        #expect(!coordinator.isImporting)
        #expect(coordinator.errorMessage == nil)
    }

    @Test("cancelled service evidence requests no persistence")
    @MainActor
    func coordinatorHonorsCancellationEvidence() async throws {
        let image = URL(fileURLWithPath: "/virtual/image.nef")
        let source = URL(fileURLWithPath: "/virtual/cancelled.cube")
        var intents: [DevelopColorLUTPersistenceIntent] = []
        let coordinator = DevelopColorLUTImportCoordinator()

        coordinator.beginImageSession(image)
        #expect(coordinator.requestImport(for: UUID()))
        coordinator.acceptSelection(
            .success([source]),
            load: { _, requestID in .cancelledBeforeRead(requestID: requestID) },
            parse: { _ in Issue.record("Cancelled input must not be parsed"); throw ColorLUTImportProbeError.timedOut },
            publisher: { intents.append($0) }
        )

        try await eventually { !coordinator.isImporting }
        #expect(intents.isEmpty)
        #expect(coordinator.errorMessage == nil)
    }

    private static func validCube(title: String?) -> Data {
        let titleLine = title.map { "TITLE \"\($0)\"\n" } ?? ""
        let rows = [
            "0 0 0", "1 0 0", "0 1 0", "1 1 0",
            "0 0 1", "1 0 1", "0 1 1", "1 1 1",
        ].joined(separator: "\n")
        return Data("\(titleLine)LUT_3D_SIZE 2\n\(rows)\n".utf8)
    }

    @MainActor
    private func eventually(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for Color LUT import state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private nonisolated final class ColorLUTImportReaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var count = 0
    private var observedMainThread = false

    init(data: Data) {
        self.data = data
    }

    func read(_ url: URL) throws -> Data {
        _ = url
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return data
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

private enum ColorLUTImportProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingColorLUTImportReaderProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var readCount = 0
    private var activeReads = 0
    private var maximumActiveReads = 0
    private var firstReadReleased = false

    func read(_ url: URL) throws -> Data {
        _ = url
        condition.lock()
        readCount += 1
        activeReads += 1
        maximumActiveReads = max(maximumActiveReads, activeReads)
        condition.broadcast()
        if readCount == 1 {
            while !firstReadReleased {
                condition.wait()
            }
        }
        activeReads -= 1
        condition.unlock()
        return Data("first".utf8)
    }

    func waitUntilFirstReadStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while invocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw ColorLUTImportProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstRead() {
        condition.lock()
        firstReadReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var invocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return readCount
    }

    var maximumConcurrentReads: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveReads
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

@Suite("Develop transient preview coordinator")
@MainActor
struct DevelopTransientPreviewCoordinatorTests {
    @Test("image-session changes release every held comparison")
    func imageChangeReleasesHeldComparisons() {
        let coordinator = DevelopTransientPreviewCoordinator()
        let firstURL = URL(fileURLWithPath: "/tmp/transient-preview-first.raw")
        let secondURL = URL(fileURLWithPath: "/tmp/transient-preview-second.raw")

        coordinator.beginImageSession(firstURL)
        coordinator.beginBeforeComparison()
        coordinator.beginDevelopMute()
        #expect(coordinator.beginLayerMute(maskIndex: 2))

        coordinator.beginImageSession(secondURL)

        #expect(coordinator.activeImageURL == secondURL)
        #expect(!coordinator.isShowingBefore)
        #expect(!coordinator.isMutingDevelop)
        #expect(!coordinator.isMutingGlobal)
        #expect(!coordinator.isMutingSelectedMask)
        #expect(coordinator.mutedMaskIndex == nil)
    }

    @Test("selected-mask mute changes only the render projection")
    func selectedMaskMuteDoesNotMutateEditableSettings() {
        let coordinator = DevelopTransientPreviewCoordinator()
        let masks = [
            MaskAdjustment(name: "First", enabled: true, exposure: 0.5),
            MaskAdjustment(name: "Second", enabled: true, exposure: 1.0),
        ]
        var editable = CameraRawSettings()
        editable.exposure2012 = 1.25
        editable.localAdjustments = masks

        #expect(coordinator.beginLayerMute(maskIndex: 1))
        #expect(!coordinator.beginLayerMute(maskIndex: 0))
        let projected = coordinator.settingsForPipeline(
            editable,
            isRawSource: false,
            sectionMutes: DevelopSectionMuteState()
        )

        #expect(editable.localAdjustments?[0].enabled == true)
        #expect(editable.localAdjustments?[1].enabled == true)
        #expect(projected?.localAdjustments?[0].enabled == true)
        #expect(projected?.localAdjustments?[1].enabled == false)
        #expect(projected?.exposure2012 == 1.25)

        #expect(coordinator.endLayerMute())
        let released = coordinator.settingsForPipeline(
            editable,
            isRawSource: false,
            sectionMutes: DevelopSectionMuteState()
        )
        #expect(released?.localAdjustments?[1].enabled == true)
    }

    @Test("global mute preserves masks and HDR mode but strips global adjustments")
    func globalMuteProjectsMasksOnly() {
        let coordinator = DevelopTransientPreviewCoordinator()
        let mask = MaskAdjustment(name: "Local", exposure: 0.75)
        var editable = CameraRawSettings()
        editable.whiteBalance = "Custom"
        editable.exposure2012 = 2
        editable.sharpness = 40
        editable.hdrEditMode = 1
        editable.localAdjustments = [mask]

        #expect(coordinator.beginLayerMute(maskIndex: nil))
        let projected = coordinator.settingsForPipeline(
            editable,
            isRawSource: true,
            sectionMutes: DevelopSectionMuteState()
        )

        #expect(projected?.whiteBalance == nil)
        #expect(projected?.exposure2012 == nil)
        #expect(projected?.sharpness == nil)
        #expect(projected?.localAdjustments == [mask])
        #expect(projected?.hdrEditMode == 1)
        #expect(projected?.sourceHasHDRHeadroom == true)
    }

    @Test("section and whole-Develop mutes retain their established boundaries")
    func sectionAndDevelopMuteProjection() {
        let coordinator = DevelopTransientPreviewCoordinator()
        let mask = MaskAdjustment(name: "Local", exposure: 0.5)
        var editable = CameraRawSettings()
        editable.whiteBalance = "Custom"
        editable.temperature = 7000
        editable.exposure2012 = 1
        editable.sharpness = 25
        editable.localAdjustments = [mask]

        let detailOnly = coordinator.settingsForPipeline(
            editable,
            isRawSource: false,
            sectionMutes: DevelopSectionMuteState(detail: true)
        )
        #expect(detailOnly?.sharpness == nil)
        #expect(detailOnly?.temperature == 7000)
        #expect(detailOnly?.exposure2012 == 1)
        #expect(detailOnly?.localAdjustments == [mask])

        coordinator.beginDevelopMute()
        let allDevelop = coordinator.settingsForPipeline(
            editable,
            isRawSource: false,
            sectionMutes: DevelopSectionMuteState()
        )
        #expect(allDevelop?.whiteBalance == nil)
        #expect(allDevelop?.temperature == nil)
        #expect(allDevelop?.exposure2012 == nil)
        #expect(allDevelop?.sharpness == nil)
        #expect(allDevelop?.localAdjustments == nil)
    }

    @Test("RAW sources without edits retain their tonemap-only payload")
    func rawTonemapOnlyProjection() {
        let coordinator = DevelopTransientPreviewCoordinator()

        let raw = coordinator.settingsForPipeline(
            nil,
            isRawSource: true,
            sectionMutes: DevelopSectionMuteState()
        )
        let nonRaw = coordinator.settingsForPipeline(
            nil,
            isRawSource: false,
            sectionMutes: DevelopSectionMuteState()
        )

        #expect(raw?.sourceHasHDRHeadroom == true)
        #expect(nonRaw == nil)
    }
}

@Suite("Develop section mute coordinator")
@MainActor
struct DevelopSectionMuteCoordinatorTests {
    @Test("section toggles remain independent and produce an exact render snapshot")
    func independentSectionToggles() {
        let coordinator = DevelopSectionMuteCoordinator()

        #expect(DevelopSectionMute.allCases.allSatisfy { !coordinator.isMuted($0) })
        #expect(coordinator.toggle(.color))
        #expect(coordinator.toggle(.toneCurve))
        #expect(coordinator.toggle(.film))

        #expect(coordinator.snapshot == DevelopSectionMuteState(
            color: true,
            toneCurve: true,
            film: true
        ))
        #expect(!coordinator.isMuted(.exposure))
        #expect(!coordinator.isMuted(.detail))
        #expect(!coordinator.isMuted(.hsl))

        coordinator.setMuted(false, for: .toneCurve)
        #expect(!coordinator.isMuted(.toneCurve))
        #expect(coordinator.isMuted(.color))
        #expect(coordinator.isMuted(.film))
    }

    @Test("workspace state survives repeated render snapshots and can be restored explicitly")
    func workspaceLifetimeAndRestorationSeams() {
        let initial = DevelopSectionMuteState(exposure: true, detail: true)
        let coordinator = DevelopSectionMuteCoordinator(initialState: initial)

        let firstImageSnapshot = coordinator.snapshot
        let secondImageSnapshot = coordinator.snapshot

        #expect(firstImageSnapshot == initial)
        #expect(secondImageSnapshot == initial)

        coordinator.toggle(.detail)
        #expect(firstImageSnapshot.detail)
        #expect(!coordinator.snapshot.detail)

        let newWorkspace = DevelopSectionMuteCoordinator()
        #expect(DevelopSectionMute.allCases.allSatisfy { !newWorkspace.isMuted($0) })
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

@Suite("Develop layer session coordinator")
@MainActor
struct DevelopLayerSessionCoordinatorTests {
    @Test("edit workspace delegates layer ownership, lifecycle, and durable mutations")
    func editWorkspaceSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains(
            "@State private var layerSession = DevelopLayerSessionCoordinator()"
        ))
        #expect(source.contains("layerSession.beginImageSession(selectedImageURL)"))
        #expect(source.contains("layerSession.endImageSession()"))
        #expect(source.contains("layerSession.beginRename("))
        #expect(source.contains("layerSession.commitRename(in: &settings)"))
        #expect(source.contains("layerSession.reorder(dragged, onto: target, in: &settings)"))
        #expect(source.contains("layerSession.deleteSelectedLayer(in: &settings)"))
        #expect(!source.contains("@State private var selectedLayer"))
        #expect(!source.contains("@State private var draggingLayer"))
        #expect(!source.contains("@State private var dropTargetLayer"))
        #expect(!source.contains("@State private var layerBeingRenamed"))
        #expect(!source.contains("@State private var layerNameDraft"))
    }

    @Test("image navigation resets transient layer state but preserves outline visibility")
    func imageNavigationResetsTransientState() {
        let coordinator = DevelopLayerSessionCoordinator()
        let firstURL = URL(fileURLWithPath: "/tmp/layer-first.jpg")
        let secondURL = URL(fileURLWithPath: "/tmp/layer-second.jpg")
        let mask = MaskAdjustment(name: "Sky")
        let ref = LayerRef.mask(mask.id)
        let settings = CameraRawSettings(localAdjustments: [mask])

        coordinator.beginImageSession(firstURL)
        coordinator.selectedLayer = ref
        coordinator.draggingLayer = ref
        coordinator.dropTargetLayer = .global
        coordinator.hoveredLayer = ref
        coordinator.hoveredAddLayerKind = .ellipseMask
        coordinator.showsMaskOutlines = false
        #expect(coordinator.beginRename(ref, in: settings))

        coordinator.beginImageSession(secondURL)

        #expect(coordinator.activeImageURL == secondURL)
        #expect(coordinator.selectedLayer == .global)
        #expect(coordinator.draggingLayer == nil)
        #expect(coordinator.dropTargetLayer == nil)
        #expect(coordinator.hoveredLayer == nil)
        #expect(coordinator.hoveredAddLayerKind == nil)
        #expect(!coordinator.isShowingRename)
        #expect(coordinator.nameDraft.isEmpty)
        #expect(!coordinator.showsMaskOutlines)

        coordinator.selectedLayer = ref
        coordinator.endImageSession()
        #expect(coordinator.activeImageURL == nil)
        #expect(coordinator.selectedLayer == .global)
        #expect(!coordinator.showsMaskOutlines)
    }

    @Test("rename trims input and reports persistence only for a durable change")
    func renameReturnsExplicitPersistenceIntent() {
        let coordinator = DevelopLayerSessionCoordinator()
        let mask = MaskAdjustment(name: "Sky")
        let ref = LayerRef.mask(mask.id)
        var settings = CameraRawSettings(localAdjustments: [mask])

        #expect(coordinator.beginRename(ref, in: settings))
        coordinator.nameDraft = "  Bright Sky  "
        #expect(coordinator.commitRename(in: &settings) == .commit)
        #expect(settings.localAdjustments?.first?.name == "Bright Sky")
        #expect(!coordinator.isShowingRename)

        #expect(coordinator.beginRename(ref, in: settings))
        coordinator.nameDraft = "Bright Sky"
        #expect(coordinator.commitRename(in: &settings) == .unchanged)
    }

    @Test("reorder materializes a sanitized layer chain as one durable mutation")
    func reorderReturnsExplicitPersistenceIntent() {
        let coordinator = DevelopLayerSessionCoordinator()
        let first = MaskAdjustment(name: "First")
        let second = MaskAdjustment(name: "Second")
        let watermark = WatermarkLayer(libraryAssetID: UUID())
        var settings = CameraRawSettings(
            localAdjustments: [first, second],
            watermarkLayers: [watermark]
        )

        #expect(
            coordinator.reorder(
                .watermark(watermark.id),
                onto: .mask(first.id),
                in: &settings
            ) == .commit
        )
        #expect(settings.layerOrder == [
            .global,
            .watermark(watermark.id),
            .mask(first.id),
            .mask(second.id),
        ])
        #expect(
            coordinator.reorder(
                .watermark(watermark.id),
                onto: .watermark(watermark.id),
                in: &settings
            ) == .unchanged
        )
    }

    @Test("deleting a selected layer removes its order entry and selects its successor")
    func deletionSelectsSuccessor() {
        let coordinator = DevelopLayerSessionCoordinator()
        let first = MaskAdjustment(name: "First")
        let selected = MaskAdjustment(name: "Selected")
        let successor = MaskAdjustment(name: "Successor")
        var settings = CameraRawSettings(
            localAdjustments: [first, selected, successor],
            layerOrder: [.global, .mask(first.id), .mask(selected.id), .mask(successor.id)]
        )
        coordinator.selectedLayer = .mask(selected.id)

        #expect(coordinator.deleteSelectedLayer(in: &settings) == .commit)
        #expect(settings.localAdjustments?.map(\.id) == [first.id, successor.id])
        #expect(settings.layerOrder == [.global, .mask(first.id), .mask(successor.id)])
        #expect(coordinator.selectedLayer == .mask(successor.id))
    }
}

@Suite("Develop Clean Feed publication coordinator")
@MainActor
struct DevelopCleanFeedPublicationCoordinatorTests {
    @Test("edit workspace delegates Clean Feed lifecycle and publication")
    func editWorkspaceSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains(
            "@State private var cleanFeedPublication = DevelopCleanFeedPublicationCoordinator()"
        ))
        #expect(source.contains("cleanFeedPublication.beginWorkspace(controller: cleanFeedController)"))
        #expect(source.contains("cleanFeedPublication.endWorkspace("))
        #expect(source.contains("cleanFeedPublication.updateMirror("))
        #expect(source.contains("cleanFeedPublication.publish("))
        #expect(!source.contains("cleanFeedController.editModeActive = true"))
        #expect(!source.contains("cleanFeedController.feedImage = displayCIImage"))
        #expect(!source.contains("cleanFeedController.useEditPipeline =\n            (metalPipeline"))
    }

    @Test("inactive sessions reject publication and active sessions choose live rendering")
    func workspaceLifetimeAndLivePolicy() {
        let coordinator = DevelopCleanFeedPublicationCoordinator()
        let controller = CleanFeedController.shared
        controller.feedCrop = nil

        #expect(coordinator.publicationDecision(
            hasSourceTexture: true,
            isShowingBefore: false,
            isMutingDevelop: false,
            isCropToolActive: false,
            proposedCrop: nil
        ) == nil)

        coordinator.beginWorkspace(controller: controller)
        let decision = coordinator.publicationDecision(
            hasSourceTexture: true,
            isShowingBefore: false,
            isMutingDevelop: false,
            isCropToolActive: false,
            proposedCrop: nil
        )

        #expect(coordinator.isWorkspaceActive)
        #expect(controller.editModeActive)
        #expect(decision?.usesEditPipeline == true)

        coordinator.endWorkspace(editorPipeline: nil, controller: controller)
        #expect(!coordinator.isWorkspaceActive)
        #expect(!controller.editModeActive)
        #expect(!controller.useEditPipeline)
    }

    @Test("before and muted states use the fallback even with a live texture")
    func transientFallbackPolicy() {
        let coordinator = DevelopCleanFeedPublicationCoordinator()
        let controller = CleanFeedController.shared
        coordinator.beginWorkspace(controller: controller)
        defer { coordinator.endWorkspace(editorPipeline: nil, controller: controller) }

        let before = coordinator.publicationDecision(
            hasSourceTexture: true,
            isShowingBefore: true,
            isMutingDevelop: false,
            isCropToolActive: false,
            proposedCrop: nil
        )
        let muted = coordinator.publicationDecision(
            hasSourceTexture: true,
            isShowingBefore: false,
            isMutingDevelop: true,
            isCropToolActive: false,
            proposedCrop: nil
        )

        #expect(before?.usesEditPipeline == false)
        #expect(muted?.usesEditPipeline == false)
    }

    @Test("crop publication freezes while the crop tool is active")
    func activeCropToolFreezesCommittedCrop() {
        let coordinator = DevelopCleanFeedPublicationCoordinator()
        let controller = CleanFeedController.shared
        controller.feedCrop = nil
        coordinator.beginWorkspace(controller: controller)
        defer { coordinator.endWorkspace(editorPipeline: nil, controller: controller) }

        let committed = CleanFeedController.FeedCrop(
            left: 0.1, top: 0.2, right: 0.9, bottom: 0.8,
            angle: 0, imageSize: CGSize(width: 4_000, height: 3_000)
        )
        let draft = CleanFeedController.FeedCrop(
            left: 0.25, top: 0.25, right: 0.75, bottom: 0.75,
            angle: 3, imageSize: CGSize(width: 4_000, height: 3_000)
        )

        let first = coordinator.publicationDecision(
            hasSourceTexture: true,
            isShowingBefore: false,
            isMutingDevelop: false,
            isCropToolActive: false,
            proposedCrop: committed
        )
        let frozen = coordinator.publicationDecision(
            hasSourceTexture: true,
            isShowingBefore: false,
            isMutingDevelop: false,
            isCropToolActive: true,
            proposedCrop: draft
        )
        let published = coordinator.publicationDecision(
            hasSourceTexture: true,
            isShowingBefore: false,
            isMutingDevelop: false,
            isCropToolActive: false,
            proposedCrop: draft
        )

        #expect(first?.crop == committed)
        #expect(frozen?.crop == committed)
        #expect(published?.crop == draft)
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
