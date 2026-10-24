import AppKit
import CoreImage
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

    @Test("Trash feedback preserves every recovery path and distinguishes committed cleanup")
    func trashFeedbackPreservesCompleteCommitEvidence() throws {
        let completed = URL(fileURLWithPath: "/tmp/finished.jpg")
        let failures = (0..<8).map { index in
            FileSystemService.ItemFailure(
                sourceURL: URL(fileURLWithPath: "/tmp/folder-\(index)/photo.jpg"),
                stage: .primary,
                message: "Outcome uncertain. Inspect /tmp/recovery-\(index)/photo.jpg before retrying."
            )
        } + [.init(sourceURL: completed, stage: .cleanup, message: "Remove /tmp/retained-backup only after verification.")]
        let feedback = try #require(TrashOperationFeedback(
            completedURLs: [completed], failures: failures, cancelled: false
        ))
        #expect(feedback.summary == "1 photo(s) moved to Trash; 9 issue(s) need attention.")
        for failure in failures {
            #expect(feedback.details.contains(failure.sourceURL.path))
            #expect(feedback.details.contains(failure.message))
        }
        #expect(feedback.details.contains("Photo moved to Trash; cleanup needs attention"))
        #expect(feedback.details.contains("Move to Trash was not confirmed"))
        #expect(!feedback.details.contains("was restored"))
    }

    @Test("Face Trash failures explain that face data was removed independently of photo success")
    func faceTrashFeedbackExplainsPartialOutcome() throws {
        let result = FaceGroupDeletionResult(
            trashedPhotoURLs: [urls[0]],
            failures: [.init(sourceURL: urls[1], stage: .primary, message: "Missing linked memo.")],
            cancellationStoppedRemainingPhotos: false,
            faceDataDisposition: .applied
        )
        let feedback = try #require(TrashOperationFeedback(result: result))
        #expect(feedback.summary.contains("1 photo(s) moved"))
        #expect(feedback.details.contains("face data was removed"))
        #expect(feedback.details.contains("photos whose move to Trash failed"))
        #expect(feedback.details.contains(urls[1].path))
    }

    @Test("Face Trash interruption exposes why the face model was preserved", arguments: [
        FaceGroupDeletionResult.FaceDataDisposition.cancelledBeforeMutation,
        .staleStatePreserved,
        .groupNotFound
    ])
    func faceTrashFeedbackExplainsPreservedState(_ disposition: FaceGroupDeletionResult.FaceDataDisposition) throws {
        let feedback = try #require(TrashOperationFeedback(result: .init(
            trashedPhotoURLs: [], failures: [],
            cancellationStoppedRemainingPhotos: disposition == .cancelledBeforeMutation,
            faceDataDisposition: disposition
        )))
        switch disposition {
        case .cancelledBeforeMutation:
            #expect(feedback.details.contains("cancelled before changing the face data"))
        case .staleStatePreserved:
            #expect(feedback.details.contains("newer face data was preserved"))
        case .groupNotFound:
            #expect(feedback.details.contains("No photos or face data were changed"))
        case .applied, .failed:
            Issue.record("Unexpected test input")
        }
    }

    @Test("Successful Trash stays quiet and cancellation keeps its committed count")
    func trashFeedbackSuccessAndCancellation() throws {
        #expect(TrashOperationFeedback(completedURLs: [urls[0]], failures: [], cancelled: false) == nil)
        #expect(TrashOperationFeedback(result: .init(
            trashedPhotoURLs: [urls[0]], failures: [],
            cancellationStoppedRemainingPhotos: false, faceDataDisposition: .applied
        )) == nil)
        let cancelled = try #require(TrashOperationFeedback(
            completedURLs: [urls[0]], failures: [], cancelled: true
        ))
        #expect(cancelled.summary.contains("1 photo(s) moved"))
        #expect(cancelled.details.contains("stopped before all remaining photos"))
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
        let defaults = AppDefaults.store
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

    /// Sort changes persist to AppDefaults.store; restore the user's values afterwards.
    @MainActor
    private func withRestoredSortDefaults(_ body: () async throws -> Void) async rethrows {
        let defaults = AppDefaults.store
        let keys = [UserDefaultsKeys.thumbnailSortOrder, UserDefaultsKeys.thumbnailSortReversed]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        try await body()
    }

    private func browserImages(_ names: [String]) -> [ImageFile] {
        names.map { ImageFile(url: URL(fileURLWithPath: "/tmp/browse-sort/\($0).jpg")) }
    }

    @Test("Rating sort breaks ties by ascending filename, also when reversed")
    @MainActor
    func ratingSortTieBreaksByName() async {
        await withRestoredSortDefaults {
            // Directory order deliberately differs from name order.
            var images = browserImages(["b", "a", "c", "d"])
            for index in images.indices { images[index].starRating = .three }
            images[2].starRating = .five
            let viewModel = BrowserViewModel()
            viewModel.sortReversed = false
            viewModel.sortOrder = .rating
            viewModel.images = images
            viewModel.batchUpdate {}
            #expect(viewModel.sortedImages.map(\.filename) == ["c.jpg", "a.jpg", "b.jpg", "d.jpg"])

            viewModel.sortReversed = true
            viewModel.batchUpdate {}
            #expect(viewModel.sortedImages.map(\.filename) == ["a.jpg", "b.jpg", "d.jpg", "c.jpg"])
        }
    }

    @Test("Manual sort without an arranged order falls back to name order")
    @MainActor
    func manualSortFallsBackToNameOrder() async {
        await withRestoredSortDefaults {
            let viewModel = BrowserViewModel()
            viewModel.sortReversed = false
            viewModel.sortOrder = .name
            viewModel.images = browserImages(["c", "a", "b"])
            viewModel.batchUpdate {}

            viewModel.sortOrder = .manual
            viewModel.batchUpdate {}
            #expect(viewModel.sortedImages.map(\.filename) == ["a.jpg", "b.jpg", "c.jpg"])
        }
    }

    @Test("Only an in-grid reorder switches the sort to Manual, seeded from the visible order")
    @MainActor
    func inGridReorderSwitchesToManual() async {
        await withRestoredSortDefaults {
            let viewModel = BrowserViewModel()
            viewModel.sortReversed = false
            viewModel.sortOrder = .name
            let images = browserImages(["c", "a", "b"])
            viewModel.images = images
            viewModel.batchUpdate {}

            // Dropping onto one of the dragged items is not a reorder.
            viewModel.reorderManually([images[0].url], to: images[0].url, insertBefore: true)
            #expect(viewModel.sortOrder == .name)

            viewModel.reorderManually([images[0].url], to: images[1].url, insertBefore: true)
            viewModel.batchUpdate {}
            #expect(viewModel.sortOrder == .manual)
            #expect(viewModel.sortedImages.map(\.filename) == ["c.jpg", "a.jpg", "b.jpg"])
        }
    }

    @Test("Shift-arrow selection shrinks back toward its fixed anchor")
    @MainActor
    func shiftArrowSelectionShrinks() async {
        await withRestoredSortDefaults {
            let viewModel = BrowserViewModel()
            viewModel.sortReversed = false
            viewModel.sortOrder = .name
            let images = browserImages(["a", "b", "c", "d", "e", "f"])
            viewModel.images = images
            viewModel.batchUpdate {}
            let url = images.map(\.url)

            viewModel.applySelection(ids: [url[2]], active: url[2])
            viewModel.selectNext(extending: true)
            viewModel.selectNext(extending: true)
            #expect(viewModel.selectedImageIDs == Set(url[2...4]))

            viewModel.selectPrevious(extending: true)
            #expect(viewModel.selectedImageIDs == Set(url[2...3]))
            #expect(viewModel.lastClickedImageURL == url[3])

            viewModel.selectPrevious(extending: true)
            viewModel.selectPrevious(extending: true)
            #expect(viewModel.selectedImageIDs == Set(url[1...2]))

            // Row moves use the same anchor.
            viewModel.selectDown(columns: 3, extending: true)
            #expect(viewModel.selectedImageIDs == Set(url[2...4]))

            // A plain move resets the anchor.
            viewModel.selectNext()
            viewModel.selectPrevious(extending: true)
            #expect(viewModel.selectedImageIDs == Set(url[4...5]))
        }
    }

    @Test("Closing the current folder while it loads returns to an idle no-folder state")
    @MainActor
    func closingLoadingFolderResetsState() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let viewModel = BrowserViewModel(favoritesDefaults: defaults)
        let folder = URL(fileURLWithPath: "/virtual/closing-folder")
        let image = ImageFile(url: folder.appendingPathComponent("a.jpg"))
        viewModel.openFolders = [folder]
        viewModel.currentFolderURL = folder
        viewModel.isLoading = true
        viewModel.iCloudDownloadNotice = "Downloading"
        viewModel.images = [image]
        viewModel.applySelection(ids: [image.url], active: image.url)
        viewModel.searchText = "harbour"
        viewModel.minimumStarRating = .three

        viewModel.closeOpenFolder(folder)

        #expect(viewModel.currentFolderURL == nil)
        #expect(!viewModel.isLoading)
        #expect(viewModel.iCloudDownloadNotice == nil)
        #expect(viewModel.images.isEmpty)
        #expect(viewModel.selectedImageIDs.isEmpty)
        #expect(viewModel.lastClickedImageURL == nil)
        #expect(viewModel.searchText.isEmpty)
        #expect(viewModel.minimumStarRating == .none)
    }

    @Test("A split-view pane showing a subfolder of a closed root is released too")
    @MainActor
    func secondaryPaneReleasesClosedFolder() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let pane = BrowserViewModel(favoritesDefaults: defaults)
        let root = URL(fileURLWithPath: "/virtual/closing-root")
        pane.currentFolderURL = root.appendingPathComponent("Sub")
        pane.isLoading = true

        pane.releaseClosedFolder(URL(fileURLWithPath: "/virtual/closing-root-other"))
        #expect(pane.currentFolderURL != nil)

        pane.releaseClosedFolder(root)
        #expect(pane.currentFolderURL == nil)
        #expect(!pane.isLoading)
    }

    @Test("Moves and duplicates during a suppressed metadata load keep the image index and selection consistent")
    @MainActor
    func inventoryChangeDuringSuppressedMetadataLoadReindexes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-reindex-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let destination = root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["a.jpg", "b.jpg", "c.jpg"].map { root.appendingPathComponent($0) }
        for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }

        let viewModel = BrowserViewModel(imageTrashHandler: TrashStub())
        viewModel.currentFolderURL = root
        viewModel.images = files.map { ImageFile(url: $0) }
        await Task.yield()

        // `loadBasicMetadata` holds the cascade suppressed across its awaits.
        viewModel.setImagesCascadeSuppressedForTesting(true)
        viewModel.moveImages([files[0]], into: destination)
        await viewModel.waitForPendingImageMutation()

        #expect(viewModel.images.map(\.url) == [files[1], files[2]])
        #expect(viewModel.urlToImageIndex == [files[1]: 0, files[2]: 1])
        #expect(viewModel.visibleImages.map(\.url) == [files[1], files[2]])
        // A stale index (c → 2) would read out of range or a neighbour here.
        viewModel.applySelection(ids: [files[2]], active: files[2])
        #expect(viewModel.selectedImages.map(\.url) == [files[2]])

        viewModel.duplicateSelectedImages()
        await viewModel.waitForPendingImageMutation()
        let duplicate = try #require(viewModel.selectedImageIDs.first)
        #expect(viewModel.images.map(\.url) == [files[1], files[2], duplicate])
        #expect(viewModel.urlToImageIndex == [files[1]: 0, files[2]: 1, duplicate: 2])
        #expect(viewModel.selectedImages.map(\.url) == [duplicate])
        viewModel.setImagesCascadeSuppressedForTesting(false)
    }

    @Test("Full Screen delete trashes only the shown photo, not the hidden multi-selection")
    @MainActor
    func fullScreenDeleteTargetsShownPhoto() async {
        let images = urls.prefix(3).map { ImageFile(url: $0) }
        let viewModel = BrowserViewModel(imageTrashHandler: TrashStub())
        viewModel.images = images
        await Task.yield()
        viewModel.applySelection(ids: Set(images.map(\.url)), active: images[1].url)
        viewModel.isFullScreen = true
        #expect(viewModel.fullScreenImage?.url == images[1].url)

        viewModel.confirmDeleteFullScreenImage()
        #expect(viewModel.showDeleteConfirmation)
        #expect(viewModel.deleteConfirmationCount == 1)
        viewModel.deleteConfirmedImages()
        await viewModel.waitForPendingImageMutation()

        #expect(viewModel.images.map(\.url) == [images[0].url, images[2].url])

        // The grid path still confirms and deletes the whole selection.
        viewModel.isFullScreen = false
        viewModel.applySelection(ids: [images[0].url, images[2].url], active: images[0].url)
        viewModel.confirmDeleteSelectedImages()
        #expect(viewModel.deleteConfirmationCount == 2)
        viewModel.deleteConfirmedImages()
        await viewModel.waitForPendingImageMutation()
        #expect(viewModel.images.isEmpty)
    }

    @Test("A second file operation waits for the running one instead of cancelling it")
    @MainActor
    func fileOperationsAreSerialized() async {
        let images = urls.prefix(3).map { ImageFile(url: $0) }
        let viewModel = BrowserViewModel(imageTrashHandler: TrashStub())
        viewModel.images = images
        await Task.yield()

        viewModel.applySelection(ids: [images[0].url], active: images[0].url)
        viewModel.deleteSelectedImages()
        viewModel.applySelection(ids: [images[1].url], active: images[1].url)
        viewModel.deleteSelectedImages()
        await viewModel.waitForPendingImageMutation()

        #expect(viewModel.images.map(\.url) == [images[2].url])
        #expect(viewModel.errorMessage == nil)
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
    @MainActor
    func previewCursorMapsToDisplayUV() throws {
        let coordinator = DevelopLayerGeometryInteractionCoordinator()
        let uv = try #require(coordinator.displayUV(
            forPanePoint: CGPoint(x: 100, y: 150),
            paneSize: CGSize(width: 400, height: 200),
            viewport: DevelopPreviewViewport(
                origin: SIMD2<Float>(0.2, 0.3),
                size: SIMD2<Float>(0.5, 0.25)
            )
        ))

        #expect(abs(uv.x - 0.325) < 0.0001)
        #expect(abs(uv.y - 0.4875) < 0.0001)
    }

    @Test("Preview cursor ignores letterboxing outside the image")
    @MainActor
    func previewCursorRejectsLetterbox() {
        let coordinator = DevelopLayerGeometryInteractionCoordinator()
        let uv = coordinator.displayUV(
            forPanePoint: .zero,
            paneSize: CGSize(width: 400, height: 200),
            viewport: DevelopPreviewViewport(
                origin: SIMD2<Float>(-0.25, 0),
                size: SIMD2<Float>(1.5, 1)
            )
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

    @Test("100% zoom uses native pixels in the displayed orientation, not the screen-res texture")
    func actualPixelsZoomUsesNativeDimensions() {
        let container = CGSize(width: 1_000, height: 800)
        // 6000×4000 landscape on a 2× display: fit = 1000/6000 → 100% = 6000 / (1000 · 2) = 3.
        let landscape = EditZoomBehavior.displayPixelSize(
            nativePixelSize: CGSize(width: 6_000, height: 4_000),
            orientation: 1
        )
        #expect(landscape == CGSize(width: 6_000, height: 4_000))
        #expect(abs(EditZoomBehavior.actualPixelsScale(
            containerSize: container, displayPixelSize: landscape, backingScale: 2
        ) - 3) < 0.0001)
        // The old basis — a 3200 px screen-res texture — would have stopped at 1.6×.
        #expect(EditZoomBehavior.actualPixelsScale(
            containerSize: container,
            displayPixelSize: CGSize(width: 3_200, height: 2_133),
            backingScale: 2
        ) < 1.7)

        // Orientations 5–8 transpose the stored dimensions: portrait 4000×6000 is
        // height-limited in an 1000×800 view → fit = 800/6000 → 100% = 6000 / (800 · 2) = 3.75.
        for orientation in 5...8 {
            let portrait = EditZoomBehavior.displayPixelSize(
                nativePixelSize: CGSize(width: 6_000, height: 4_000),
                orientation: orientation
            )
            #expect(portrait == CGSize(width: 4_000, height: 6_000))
            #expect(abs(EditZoomBehavior.actualPixelsScale(
                containerSize: container, displayPixelSize: portrait, backingScale: 2
            ) - 3.75) < 0.0001)
        }
        for orientation in [1, 2, 3, 4] {
            #expect(EditZoomBehavior.displayPixelSize(
                nativePixelSize: CGSize(width: 6_000, height: 4_000),
                orientation: orientation
            ) == CGSize(width: 6_000, height: 4_000))
        }

        // An image smaller than the fitted view yields < 1; clamping keeps it at fit.
        let small = EditZoomBehavior.actualPixelsScale(
            containerSize: container,
            displayPixelSize: CGSize(width: 800, height: 600),
            backingScale: 2
        )
        #expect(small < 1)
        #expect(EditZoomBehavior.clampedScale(small) == 1)
        #expect(EditZoomBehavior.actualPixelsScale(
            containerSize: .zero, displayPixelSize: landscape, backingScale: 2
        ) == 1)
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

    @Test("Single-image paste merges exactly like multi-image paste, with fresh mask IDs")
    func singlePasteMatchesMultiPaste() throws {
        let sourceMask = MaskAdjustment(name: "Sky", exposure: -0.5)
        let watermark = WatermarkLayer(libraryAssetID: UUID())
        var source = CameraRawSettings(exposure2012: 1.0)
        source.localAdjustments = [sourceMask]
        source.watermarkLayers = [watermark]
        source.anonymizer = AnonymizerSettings(amount: 40, blackOut: nil)
        source.layerOrder = [.mask(sourceMask.id), .global, .watermark(watermark.id)]
        source.asShotNeutralTemperature = 5000

        let preserved = PreservedMaskCorrection(fields: ["What": .string("Correction")])
        var target = CameraRawSettings(exposure2012: -0.3)
        target.toneCurve = ToneCurve(
            master: [ToneCurvePoint(x: 0, y: 0.1), ToneCurvePoint(x: 1, y: 1)],
            red: nil, green: nil, blue: nil
        )
        target.hslAdjustments = HSLAdjustments(red: HSLColorAdjustment(saturation: 20))
        target.unparsedMaskCorrections = [preserved]
        target.crop = CameraRawCrop(top: 0.1, left: 0.1, bottom: 0.9, right: 0.9, angle: 0, hasCrop: true)
        target.asShotNeutralTemperature = 6500

        let multi = CameraRawSettings.pasted(source, onto: target, includeCrop: false)
        let single = CameraRawSettings.pastedIntoEditor(source, onto: target, includeCrop: false)

        // Everything but the mask identities agrees with the multi-image merge.
        let freshID = try #require(single.localAdjustments?.first?.id)
        #expect(freshID != sourceMask.id)
        var normalized = single
        normalized.localAdjustments = single.localAdjustments?.map { mask in
            var copy = mask
            copy.id = sourceMask.id
            return copy
        }
        normalized.layerOrder = [.mask(sourceMask.id), .global, .watermark(watermark.id)]
        #expect(normalized == multi)
        #expect(single.layerOrder == [.mask(freshID), .global, .watermark(watermark.id)])

        // Copied collections arrive; target collections the source lacks survive.
        #expect(single.exposure2012 == 1.0)
        #expect(single.watermarkLayers == [watermark])
        #expect(single.anonymizer == source.anonymizer)
        #expect(single.toneCurve == target.toneCurve)
        #expect(single.hslAdjustments == target.hslAdjustments)
        // Pasted masks replace the target's ordinary masks, ACR-only corrections included.
        #expect(single.unparsedMaskCorrections == nil)
        #expect(single.crop == target.crop)
        #expect(single.asShotNeutralTemperature == 6500)
    }

    @Test("Pasting a blur onto a photo with its own blur keeps both, and pasting twice adds nothing")
    func pasteAppendsMasksWithoutDuplicates() throws {
        var sourceBlur = MaskAdjustment(name: "Face A", anonymizer: AnonymizerSettings(amount: 70, blackOut: nil))
        sourceBlur.geometry.centerX = 0.25
        var source = CameraRawSettings(exposure2012: 0.5)
        source.localAdjustments = [sourceBlur]

        var targetBlur = MaskAdjustment(name: "Face B", anonymizer: AnonymizerSettings(amount: 90, blackOut: nil))
        targetBlur.geometry.centerX = 0.75
        let targetWatermark = WatermarkLayer(libraryAssetID: UUID())
        var target = CameraRawSettings(exposure2012: -0.2)
        target.localAdjustments = [targetBlur]
        target.watermarkLayers = [targetWatermark]

        for paste in [CameraRawSettings.pasted, CameraRawSettings.pastedIntoEditor] {
            let once = paste(source, target, false)
            let masks = try #require(once.localAdjustments)
            #expect(masks.count == 2)
            #expect(masks[0] == targetBlur)
            #expect(masks[1].anonymizer == sourceBlur.anonymizer)
            #expect(masks[1].geometry == sourceBlur.geometry)
            #expect(once.watermarkLayers == [targetWatermark])
            #expect(once.exposure2012 == 0.5)

            let twice = paste(source, once, false)
            #expect(twice.localAdjustments == once.localAdjustments)
        }
    }

    @Test("Paste duplicate detection survives an XMP round trip's zeros and rounding")
    func pasteDuplicateDetectionToleratesRoundTrip() {
        var mask = MaskAdjustment(name: "Sky", exposure: -0.5)
        mask.geometry.centerX = 0.333333333
        var reread = mask
        reread.id = UUID()
        reread.name = "Mask 1"
        reread.geometry.centerX = 0.333333
        reread.contrast = 0
        reread.fullFrame = false

        #expect(CameraRawSettings.layerFingerprint(mask, clearing: \.id, \.name)
            == CameraRawSettings.layerFingerprint(reread, clearing: \.id, \.name))
        var different = reread
        different.exposure = -0.4
        #expect(CameraRawSettings.layerFingerprint(mask, clearing: \.id, \.name)
            != CameraRawSettings.layerFingerprint(different, clearing: \.id, \.name))
    }

    private func ordinaryMask(_ name: String, x: Double, exposure: Double = 0.3) -> MaskAdjustment {
        var mask = MaskAdjustment(name: name, exposure: exposure)
        mask.geometry.centerX = x
        return mask
    }

    private func redactionMask(_ name: String, x: Double) -> MaskAdjustment {
        var mask = MaskAdjustment(name: name, anonymizer: AnonymizerSettings(amount: nil, blackOut: true))
        mask.geometry.centerX = x
        return mask
    }

    @Test("Paste replaces the target's ordinary masks but always keeps its Anonymizer masks")
    func pasteReplacesOrdinaryMasksKeepsRedactions() throws {
        let ownMask = ordinaryMask("Own", x: 0.1)
        let ownRedaction = redactionMask("Own face", x: 0.9)
        let ownWatermark = WatermarkLayer(libraryAssetID: UUID())
        var target = CameraRawSettings()
        target.localAdjustments = [ownMask, ownRedaction]
        target.watermarkLayers = [ownWatermark]
        target.unparsedMaskCorrections = [PreservedMaskCorrection(fields: ["What": .string("ACR")])]

        let sky = ordinaryMask("Sky", x: 0.4)
        var lut = ordinaryMask("LUT", x: 0.5)
        lut.colorTransform = ColorTransformSettings()
        var source = CameraRawSettings(exposure2012: 0.7)
        source.localAdjustments = [sky, lut]

        let pasted = CameraRawSettings.pasted(source, onto: target, includeCrop: false)
        let masks = try #require(pasted.localAdjustments)
        #expect(masks.map(\.name) == ["Own face", "Sky", "LUT"])
        #expect(masks[0] == ownRedaction)
        // Source has no watermarks: the target keeps its own.
        #expect(pasted.watermarkLayers == [ownWatermark])
        // Preserved ACR-only corrections are ordinary masks: replaced too.
        #expect(pasted.unparsedMaskCorrections == nil)
        // Source chain first; the kept redaction (after Global) follows the source's adjustment
        // layers; the kept watermark goes last.
        #expect(pasted.resolvedLayerOrder() == [
            .global, .mask(sky.id), .mask(lut.id), .mask(ownRedaction.id), .watermark(ownWatermark.id),
        ])

        // A source without masks leaves every target mask alone.
        let scalarsOnly = CameraRawSettings.pasted(CameraRawSettings(exposure2012: 1), onto: target, includeCrop: false)
        #expect(scalarsOnly.localAdjustments == target.localAdjustments)
        #expect(scalarsOnly.unparsedMaskCorrections == target.unparsedMaskCorrections)

        // Source watermarks replace the target's.
        let otherWatermark = WatermarkLayer(libraryAssetID: UUID())
        var watermarkSource = CameraRawSettings()
        watermarkSource.watermarkLayers = [otherWatermark]
        let rewatermarked = CameraRawSettings.pasted(watermarkSource, onto: target, includeCrop: false)
        #expect(rewatermarked.watermarkLayers == [otherWatermark])
        #expect(rewatermarked.localAdjustments == target.localAdjustments)
    }

    @Test("A kept Anonymizer mask below Global stays below it after a replacing paste")
    func pasteKeepsRedactionSideOfGlobal() {
        let ownRedaction = redactionMask("Face", x: 0.8)
        let ownMask = ordinaryMask("Own", x: 0.2)
        var target = CameraRawSettings()
        target.localAdjustments = [ownRedaction, ownMask]
        target.layerOrder = [.mask(ownRedaction.id), .global, .mask(ownMask.id)]

        let sky = ordinaryMask("Sky", x: 0.4)
        var source = CameraRawSettings()
        source.localAdjustments = [sky]
        source.layerOrder = [.global, .mask(sky.id)]

        let pasted = CameraRawSettings.pasted(source, onto: target, includeCrop: false)
        #expect(pasted.resolvedLayerOrder() == [.mask(ownRedaction.id), .global, .mask(sky.id)])
    }

    @Test("Over the layer limit, every target Anonymizer mask is kept first")
    func pasteLimitKeepsTargetRedactions() throws {
        let ownRedactions = (0..<DevelopLayerLimits.maxEnabledMasks).map {
            redactionMask("Face \($0)", x: 0.05 + Double($0) * 0.1)
        }
        var target = CameraRawSettings()
        target.localAdjustments = ownRedactions + [ordinaryMask("Own", x: 0.33)]

        var source = CameraRawSettings()
        source.localAdjustments = [ordinaryMask("Sky", x: 0.44), redactionMask("New face", x: 0.58)]

        let result = CameraRawSettings.pastedResult(
            source, onto: target, includeCrop: false,
            maskIdentity: .keepUnlessTaken, watermarkIdentity: .keepUnlessTaken
        )
        #expect(result.settings.localAdjustments == ownRedactions)
        #expect(result.skippedMasks == 2)

        // With one slot free, the source's redaction wins it over its ordinary mask.
        var roomier = target
        roomier.localAdjustments = Array(ownRedactions.dropLast())
        let partial = CameraRawSettings.pastedResult(
            source, onto: roomier, includeCrop: false,
            maskIdentity: .keepUnlessTaken, watermarkIdentity: .keepUnlessTaken
        )
        let masks = try #require(partial.settings.localAdjustments)
        #expect(masks.count == DevelopLayerLimits.maxEnabledMasks)
        #expect(masks.last?.name == "New face")
        #expect(partial.skippedMasks == 1)
    }

    @Test("Paste never turns the target's global Anonymizer off or weaker")
    func pasteNeverWeakensGlobalAnonymizer() {
        var target = CameraRawSettings()
        target.anonymizer = AnonymizerSettings(amount: 80, blackOut: nil)

        let off = CameraRawSettings.pasted(CameraRawSettings(exposure2012: 1), onto: target, includeCrop: false)
        #expect(off.anonymizer == target.anonymizer)

        var weaker = CameraRawSettings()
        weaker.anonymizer = AnonymizerSettings(amount: 30, blackOut: nil)
        #expect(CameraRawSettings.pasted(weaker, onto: target, includeCrop: false).anonymizer == target.anonymizer)

        var blackOut = CameraRawSettings()
        blackOut.anonymizer = AnonymizerSettings(amount: nil, blackOut: true)
        #expect(CameraRawSettings.pasted(blackOut, onto: target, includeCrop: false).anonymizer
            == AnonymizerSettings(amount: 80, blackOut: true))
        // Turning it on from the source is fine.
        #expect(CameraRawSettings.pasted(weaker, onto: CameraRawSettings(), includeCrop: false).anonymizer
            == weaker.anonymizer)
    }

    @Test("Key-repeat stepping previews every step and commits once")
    @MainActor func sliderKeyStepperCommitsOnce() async throws {
        let stepper = EditSliderKeyStepper(settleDelay: .milliseconds(20))
        var begins = 0
        var previews: [Double] = []
        var commits: [Double] = []
        stepper.onBegin = { begins += 1 }
        stepper.onPreview = { previews.append($0) }
        stepper.onCommit = { commits.append($0) }

        for _ in 0..<5 {
            stepper.step(from: 0, range: -100...100, step: 1, direction: 1, large: false)
        }
        #expect(begins == 1)
        #expect(previews == [1, 2, 3, 4, 5])
        #expect(commits.isEmpty)
        stepper.commitNow()
        #expect(commits == [5])
        stepper.commitNow()
        #expect(commits == [5])

        // Without a key-up the settle timer commits once.
        stepper.step(from: 5, range: -100...100, step: 1, direction: -1, large: true)
        for _ in 0..<100 where commits.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(commits == [5, -5])
        #expect(begins == 2)
    }

    @Test("Arrow-key slider stepping uses at least 1/200 of the range and Shift for 10x")
    func sliderKeyboardStepping() {
        #expect(EditSliderStepping.steppedValue(from: 0, range: -100...100, step: 1, direction: 1, large: false) == 1)
        #expect(EditSliderStepping.steppedValue(from: 0, range: -100...100, step: 1, direction: -1, large: true) == -10)
        let exposure = EditSliderStepping.steppedValue(from: 0, range: -5...5, step: 0.01, direction: 1, large: false)
        #expect(abs(exposure - 0.05) < 1e-9)
        #expect(EditSliderStepping.steppedValue(from: 99, range: -100...100, step: 1, direction: 1, large: true) == 100)
        #expect(EditSliderStepping.direction(forKeyCode: 126) == 1)
        #expect(EditSliderStepping.direction(forKeyCode: 125) == -1)
        #expect(EditSliderStepping.direction(forKeyCode: 0) == nil)
    }

    @Test("Reset develop adjustments clears every adjustment except crop and HDR mode")
    func developResetKeepsOnlyFraming() {
        let crop = CameraRawCrop(top: 0.1, left: 0.2, bottom: 0.9, right: 0.8, angle: 2, hasCrop: true)
        let mask = MaskAdjustment(name: "Local", exposure: 1)
        let watermark = WatermarkLayer(libraryAssetID: UUID())
        var settings = CameraRawSettings(exposure2012: 1.25, crop: crop, hdrEditMode: 1, sdrBrightness: 20)
        settings.hslAdjustments = HSLAdjustments(red: HSLColorAdjustment(saturation: 20))
        settings.localAdjustments = [mask]
        settings.watermarkLayers = [watermark]
        settings.layerOrder = [.mask(mask.id), .global, .watermark(watermark.id)]

        DevelopAdjustmentsResetBehavior.reset(&settings, isRaw: true)

        #expect(settings.whiteBalance == "As Shot")
        #expect(settings.exposure2012 == nil)
        #expect(settings.sdrBrightness == nil)
        #expect(settings.hslAdjustments == nil)
        #expect(settings.localAdjustments == nil)
        #expect(settings.watermarkLayers == nil)
        #expect(settings.layerOrder == nil)
        #expect(settings.crop == crop)
        #expect(settings.hdrEditMode == 1)
        #expect(!DevelopAdjustmentsResetBehavior.hasResettableAdjustments(settings, isRaw: true))
    }

    @Test("Reset develop adjustments is offered exactly when it would change something")
    func developResetVisibility() {
        func resettable(_ build: (inout CameraRawSettings) -> Void, isRaw: Bool = true) -> Bool {
            var settings = CameraRawSettings()
            build(&settings)
            return DevelopAdjustmentsResetBehavior.hasResettableAdjustments(settings, isRaw: isRaw)
        }
        #expect(!DevelopAdjustmentsResetBehavior.hasResettableAdjustments(nil, isRaw: true))
        #expect(!resettable { $0.whiteBalance = "As Shot" })
        #expect(!resettable({ $0.whiteBalance = "As Shot" }, isRaw: false))
        #expect(!resettable { $0.crop = CameraRawCrop(top: 0.1, left: 0, bottom: 1, right: 1, angle: 0, hasCrop: true) })
        #expect(!resettable { $0.hdrEditMode = 1 })
        #expect(resettable { $0.hslAdjustments = HSLAdjustments(red: HSLColorAdjustment(saturation: 20)) })
        #expect(resettable { $0.sdrContrast = 10 })
        #expect(resettable { $0.watermarkLayers = [WatermarkLayer(libraryAssetID: UUID())] })
        #expect(resettable { $0.whiteBalance = "Daylight" })
    }

    @Test("Toggling HDR off is a kept Develop setting even without other edits")
    func hdrToggleSurvivesAsSetting() {
        let enabled = DevelopSettingsMutation.applying({ $0.hdrEditMode = 1 }, to: nil)
        #expect(enabled?.hdrEditMode == 1)
        #expect(enabled?.hasSettings == nil)

        let disabled = DevelopSettingsMutation.applying({ $0.hdrEditMode = 0 }, to: enabled)
        #expect(disabled?.hdrEditMode == 0)
        #expect(disabled?.hasSettings == nil)

        let edited = DevelopSettingsMutation.applying({ $0.exposure2012 = 0.5 }, to: disabled)
        #expect(edited?.hasSettings == true)
        let reset = DevelopSettingsMutation.applying({ $0.exposure2012 = nil }, to: edited)
        #expect(reset?.hdrEditMode == 0)
        #expect(DevelopSettingsMutation.applying({ $0.exposure2012 = nil }, to: nil) == nil)
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

    @Test("mask and watermark transforms round-trip through orientation and straighten")
    func layerGeometryProjectionRoundTrips() {
        let coordinator = DevelopLayerGeometryInteractionCoordinator()
        let projection = DevelopLayerGeometryProjection(
            orientation: 6,
            displayImageSize: CGSize(width: 3000, height: 4000),
            crop: NormalizedCropRegion(top: 0.1, left: 0.2, bottom: 0.9, right: 0.8),
            straightenAngle: 7.5,
            zoomScale: 2
        )
        var mask = EllipseMaskGeometry()
        mask.centerX = 0.23
        mask.centerY = 0.67
        mask.radiusX = 0.12
        mask.radiusY = 0.08
        mask.rotation = 14
        var watermark = WatermarkGeometry()
        watermark.centerX = 0.81
        watermark.centerY = 0.72

        let maskRoundTrip = coordinator.maskForSensor(
            coordinator.maskForDisplay(mask, projection: projection),
            projection: projection
        )
        let watermarkRoundTrip = coordinator.watermarkForSensor(
            coordinator.watermarkForDisplay(watermark, projection: projection),
            projection: projection
        )

        #expect(abs(maskRoundTrip.centerX - mask.centerX) < 0.000_001)
        #expect(abs(maskRoundTrip.centerY - mask.centerY) < 0.000_001)
        #expect(abs(maskRoundTrip.trueRadii(aspect: 4.0 / 3.0).x - mask.trueRadii(aspect: 4.0 / 3.0).x) < 0.000_001)
        #expect(abs(maskRoundTrip.trueRadii(aspect: 4.0 / 3.0).y - mask.trueRadii(aspect: 4.0 / 3.0).y) < 0.000_001)
        #expect(abs(watermarkRoundTrip.centerX - watermark.centerX) < 0.000_001)
        #expect(abs(watermarkRoundTrip.centerY - watermark.centerY) < 0.000_001)
    }

    @Test("crop watermark framing uses crop dimensions and preview zoom")
    func cropWatermarkFraming() {
        let coordinator = DevelopLayerGeometryInteractionCoordinator()
        let projection = DevelopLayerGeometryProjection(
            displayImageSize: CGSize(width: 4000, height: 3000),
            crop: NormalizedCropRegion(top: 0.25, left: 0.25, bottom: 0.75, right: 0.75),
            zoomScale: 2
        )

        #expect(coordinator.watermarkCropImageSize(projection: projection) == CGSize(width: 2000, height: 1500))
        let content = coordinator.watermarkCropContentRect(
            in: CGSize(width: 1000, height: 500),
            projection: projection
        )
        #expect(abs(content.width - 1_333.333_333) < 0.001)
        #expect(abs(content.height - 1_000) < 0.001)
        #expect(abs(content.midX - 500) < 0.001)
        #expect(abs(content.midY - 250) < 0.001)
    }

    @Test("watermark reclamping uses the confirmed crop frame")
    func cropWatermarkReclamping() {
        let coordinator = DevelopLayerGeometryInteractionCoordinator()
        let projection = DevelopLayerGeometryProjection(
            displayImageSize: CGSize(width: 1000, height: 500),
            crop: NormalizedCropRegion(top: 0.25, left: 0.25, bottom: 0.75, right: 0.75)
        )
        var watermark = WatermarkGeometry()
        watermark.centerX = 1
        watermark.centerY = 1
        watermark.sizeUnit = .pixel
        watermark.sizeValue = 100
        watermark.marginUnit = .pixel
        watermark.marginValue = 50

        let clamped = coordinator.watermarkClampingOwnPosition(
            watermark,
            assetAspect: 1,
            usesCropFrame: true,
            projection: projection
        )

        #expect(abs(clamped.centerX - 0.8) < 0.000_001)
        #expect(abs(clamped.centerY - 0.6) < 0.000_001)
    }

    @Test("AI picks and brush strokes share the layer projection boundary")
    func aiAndBrushProjection() {
        let coordinator = DevelopLayerGeometryInteractionCoordinator()
        let projection = DevelopLayerGeometryProjection(
            orientation: 6,
            displayImageSize: CGSize(width: 3000, height: 4000),
            straightenAngle: 10
        )
        let stroke = BrushStroke(dabs: [
            BrushDab(x: 0.2, y: 0.3, flow: 0.8, hardness: 0.6)
        ])

        let sensorStroke = coordinator.brushStrokeForSensor(stroke, projection: projection)
        #expect(abs(sensorStroke.dabs[0].x - 0.3) < 0.000_001)
        #expect(abs(sensorStroke.dabs[0].y - 0.8) < 0.000_001)

        let sourcePoint = coordinator.sourcePointForAIMask(
            fromDisplayedUV: CGPoint(x: 0.1, y: 0.2),
            projection: projection
        )
        #expect(sourcePoint.x >= 0 && sourcePoint.x <= 1)
        #expect(sourcePoint.y >= 0 && sourcePoint.y <= 1)
        #expect(sourcePoint != CGPoint(x: 0.1, y: 0.2))
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
        #expect(source.contains("layerGeometryInteraction.maskForDisplay("))
        #expect(source.contains("layerGeometryInteraction.watermarkForSensor("))
        #expect(source.contains("layerGeometryInteraction.watermarkCropContentRect("))
        #expect(source.contains("layerGeometryInteraction.sourcePointForAIMask("))
        #expect(source.contains("layerGeometryInteraction.brushStrokeForSensor("))
        #expect(!source.contains("@State private var dragMaskGeometry"))
        #expect(!source.contains("@State private var dragWatermarkGeometry"))
        #expect(!source.contains("@State private var isDraggingMask"))
        #expect(!source.contains("EditPreviewCoordinateMapper"))
        #expect(!source.contains(".rotatedInDisplay(byDegrees: -displayCropAngle"))
    }
}

@Suite("Develop straighten pivot and layer limits")
@MainActor
struct DevelopStraightenPivotAndLimitTests {
    @Test("mask display mapping and AI picks rotate about the crop viewport centre")
    func straightenRotatesAboutCropCentre() {
        let coordinator = DevelopLayerGeometryInteractionCoordinator()
        let projection = DevelopLayerGeometryProjection(
            displayImageSize: CGSize(width: 1_000, height: 1_000),
            crop: NormalizedCropRegion(top: 0.1, left: 0.5, bottom: 0.5, right: 0.9),
            straightenAngle: 90,
            straightenPivot: CGPoint(x: 0.7, y: 0.3)
        )
        // Shader sampling: source = pivot + R(90°)·(displayed − pivot).
        // Displayed (0.7, 0.5) → offset (0, 0.2) → rotated (−0.2, 0) → source (0.5, 0.3).
        let source = coordinator.sourcePointForAIMask(
            fromDisplayedUV: CGPoint(x: 0.7, y: 0.5),
            projection: projection
        )
        #expect(abs(source.x - 0.5) < 0.000_001)
        #expect(abs(source.y - 0.3) < 0.000_001)

        // The overlay needs the inverse: a mask at source (0.5, 0.3) is drawn at (0.7, 0.5).
        var mask = EllipseMaskGeometry()
        mask.centerX = 0.5
        mask.centerY = 0.3
        let display = coordinator.maskForDisplay(mask, projection: projection)
        #expect(abs(display.centerX - 0.7) < 0.000_001)
        #expect(abs(display.centerY - 0.5) < 0.000_001)
        let back = coordinator.maskForSensor(display, projection: projection)
        #expect(abs(back.centerX - 0.5) < 0.000_001)
        #expect(abs(back.centerY - 0.3) < 0.000_001)
    }

    @Test("layer limit counts enabled local layers only")
    func layerLimitGating() {
        func settings(enabled: Int, disabled: Int) -> CameraRawSettings {
            var settings = CameraRawSettings()
            settings.localAdjustments = (0..<enabled).map { _ in MaskAdjustment(name: "on", geometry: EllipseMaskGeometry()) }
                + (0..<disabled).map { _ in
                    var mask = MaskAdjustment(name: "off", geometry: EllipseMaskGeometry())
                    mask.enabled = false
                    return mask
                }
            return settings
        }
        let limit = DevelopLayerLimits.maxEnabledMasks
        #expect(limit == 8)
        #expect(DevelopLayerLimits.canAddMask(to: nil))
        #expect(DevelopLayerLimits.canAddMask(to: settings(enabled: limit - 1, disabled: 3)))
        #expect(!DevelopLayerLimits.canAddMask(to: settings(enabled: limit, disabled: 0)))
        #expect(!DevelopLayerLimits.exceedsMaskLimit(settings(enabled: limit, disabled: 4)))
        #expect(DevelopLayerLimits.exceedsMaskLimit(settings(enabled: limit + 1, disabled: 0)))
    }

    @Test("watermark creation is gated at the pipeline's enabled-watermark limit")
    func watermarkLayerLimitGate() {
        func settings(enabled: Int, disabled: Int) -> CameraRawSettings {
            var cameraRaw = CameraRawSettings()
            cameraRaw.watermarkLayers = (0..<enabled).map { _ in WatermarkLayer(libraryAssetID: UUID()) }
                + (0..<disabled).map { _ in WatermarkLayer(enabled: false, libraryAssetID: UUID()) }
            return cameraRaw
        }
        let limit = DevelopLayerLimits.maxEnabledWatermarks
        #expect(limit == 4)
        #expect(DevelopLayerLimits.canAddWatermark(to: nil))
        #expect(DevelopLayerLimits.canAddWatermark(to: settings(enabled: limit - 1, disabled: 3)))
        #expect(!DevelopLayerLimits.canAddWatermark(to: settings(enabled: limit, disabled: 0)))
        #expect(DevelopLayerLimits.enabledWatermarkCount(in: settings(enabled: 2, disabled: 5)) == 2)
    }

    @Test("oversized LUT files report a size error, not an encoding error")
    func oversizedLUTReportsSize() async {
        let oversized = Data(repeating: 0x20, count: CubeLUTParser.maxFileSize + 1)
        #expect {
            try CubeLUTParser.parse(oversized)
        } throws: { error in
            guard case CubeLUTParser.ParseError.tooLarge = error else { return false }
            return error.localizedDescription == "The LUT file is too large (max 8 MB)."
        }
        await #expect(throws: CubeLUTParser.ParseError.self) {
            try await CubeLUTParser.parseOffMain(Data([0xFF, 0xFE]))
        }
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
        // Develop Save must surface a missing watermark like the batch export paths.
        #expect(source.contains("watermarkWasMissing: !watermarkWarnings.isEmpty"))
        #expect(source.contains("result.watermarkWasMissing"))
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
                if !condition.waitBounded() { break }
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
                // A test that gives up must not leave the probe holding a shared queue.
                releaseFirstRead()
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

    @Test("normal viewport derives letterboxing and pan from one navigation snapshot")
    func normalViewportGeometry() {
        let coordinator = DevelopPreviewNavigationCoordinator()
        coordinator.applyZoom(
            scale: 2,
            anchoredOffset: CGSize(width: 30, height: -20)
        )

        let viewport = coordinator.viewport(
            containerSize: CGSize(width: 600, height: 400),
            imageSize: CGSize(width: 400, height: 400)
        )

        #expect(abs(viewport.origin.x - 0.0875) < 0.000_001)
        #expect(abs(viewport.origin.y - 0.275) < 0.000_001)
        #expect(abs(viewport.size.x - 0.75) < 0.000_001)
        #expect(abs(viewport.size.y - 0.5) < 0.000_001)
    }

    @Test("cursor-anchored zoom preserves the source point and clamps pan")
    func cursorAnchoredZoomGeometry() {
        let coordinator = DevelopPreviewNavigationCoordinator()
        let container = CGSize(width: 600, height: 400)
        let image = CGSize(width: 400, height: 400)
        let cursor = CGSize(width: 100, height: 0)
        let cursorX = 0.5 + cursor.width / container.width
        let before = coordinator.viewport(containerSize: container, imageSize: image)
        let sourceXBefore = Double(before.origin.x) + Double(cursorX) * Double(before.size.x)

        coordinator.applyZoom(
            scale: 2,
            preserving: cursor,
            containerSize: container,
            imageSize: image
        )

        let after = coordinator.viewport(containerSize: container, imageSize: image)
        let sourceXAfter = Double(after.origin.x) + Double(cursorX) * Double(after.size.x)
        #expect(abs(sourceXBefore - sourceXAfter) < 0.000_001)
        #expect(coordinator.offset == CGSize(width: -100, height: 0))
        #expect(coordinator.committedOffset == coordinator.offset)
    }

    @Test("cropped viewport rotates view-space pan back into source space")
    func croppedViewportGeometry() {
        let coordinator = DevelopPreviewNavigationCoordinator()
        coordinator.applyZoom(
            scale: 2,
            anchoredOffset: CGSize(width: 100, height: 0)
        )
        let crop = NormalizedCropRegion(
            top: 0.25,
            left: 0.25,
            bottom: 0.75,
            right: 0.75
        )

        let viewport = coordinator.cropViewport(
            containerSize: CGSize(width: 600, height: 400),
            imageSize: CGSize(width: 1_200, height: 800),
            crop: crop,
            angleDegrees: 90
        )

        #expect(abs(viewport.origin.x - 0.375) < 0.000_001)
        #expect(abs(viewport.origin.y - 0.3125) < 0.000_001)
        #expect(abs(viewport.size.x - 0.25) < 0.000_001)
        #expect(abs(viewport.size.y - 0.25) < 0.000_001)
    }

    @Test("cropped cursor-anchored zoom derives from the owned navigation snapshot")
    func croppedCursorAnchoredZoom() {
        let coordinator = DevelopPreviewNavigationCoordinator()
        coordinator.applyZoom(
            scale: 2,
            anchoredOffset: CGSize(width: 30, height: -10)
        )

        coordinator.applyCropZoom(
            scale: 4,
            preserving: CGSize(width: 100, height: 50)
        )

        #expect(coordinator.zoomScale == 4)
        #expect(coordinator.offset == CGSize(width: -40, height: -70))
        #expect(coordinator.committedOffset == coordinator.offset)
    }

    @Test("crop framing and pan limits share the same zoom geometry")
    func cropFramingAndPanLimits() {
        let coordinator = DevelopPreviewNavigationCoordinator()
        coordinator.applyZoom(scale: 2)
        let crop = NormalizedCropRegion(
            top: 0.25,
            left: 0.25,
            bottom: 0.75,
            right: 0.75
        )

        let imageRect = coordinator.cropFittedImageRect(
            containerSize: CGSize(width: 600, height: 400),
            imageSize: CGSize(width: 1_200, height: 800),
            crop: crop,
            angleDegrees: 0
        )
        let maximum = coordinator.cropMaximumOffset(
            containerSize: CGSize(width: 600, height: 400),
            imageSize: CGSize(width: 1_200, height: 800),
            crop: crop,
            angleDegrees: 0
        )

        #expect(imageRect == CGRect(x: -900, y: -600, width: 2_400, height: 1_600))
        #expect(maximum == CGSize(width: 300, height: 200))
    }

    @Test("invalid preview sizes return inert geometry")
    func invalidSizesReturnFallbackGeometry() {
        let coordinator = DevelopPreviewNavigationCoordinator()
        coordinator.applyZoom(
            scale: 4,
            anchoredOffset: CGSize(width: 50, height: 25)
        )
        let crop = NormalizedCropRegion.full

        #expect(coordinator.viewport(
            containerSize: .zero,
            imageSize: CGSize(width: 100, height: 100)
        ) == .identity)
        #expect(coordinator.cropViewport(
            containerSize: CGSize(width: 100, height: 100),
            imageSize: .zero,
            crop: crop,
            angleDegrees: 12
        ) == .identity)
        #expect(coordinator.cropFittedImageRect(
            containerSize: .zero,
            imageSize: CGSize(width: 100, height: 100),
            crop: crop,
            angleDegrees: 0
        ) == .zero)
        #expect(coordinator.maximumOffset(
            containerSize: .zero,
            imageSize: CGSize(width: 100, height: 100)
        ) == .zero)
    }

    @Test("Develop view delegates preview viewport and pan-limit geometry")
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

        #expect(source.contains("previewNavigation.viewport("))
        #expect(source.contains("previewNavigation.cropViewport("))
        #expect(source.contains("previewNavigation.cropFittedImageRect("))
        #expect(source.contains("previewNavigation.cropMaximumOffset("))
        #expect(source.contains("previewNavigation.maximumOffset("))
        #expect(source.contains("previewNavigation.applyCropZoom("))
        #expect(source.contains("preserving: cursorFromCenter"))
        #expect(!source.contains("private struct EditCropViewport"))
        #expect(!source.contains("private func cropFittedImageRect("))
        #expect(!source.contains("private func cropViewRect("))
        #expect(!source.contains("let newVpOriginX"))
    }
}

@Suite("Develop transient preview coordinator")
@MainActor
struct DevelopTransientPreviewCoordinatorTests {
    @Test("focus-loss release restores edited pixels without ending the image or sticky section choices")
    func focusLossRestoresProjection() {
        let coordinator = DevelopTransientPreviewCoordinator()
        let image = URL(fileURLWithPath: "/virtual/focus-loss.raw")
        coordinator.beginImageSession(image)
        var editable = CameraRawSettings()
        editable.exposure2012 = 1.25
        editable.sharpness = 40
        editable.localAdjustments = [MaskAdjustment(name: "Selected", enabled: true, exposure: 0.5)]
        let sections = DevelopSectionMuteState(detail: true)
        let expected = coordinator.settingsForPipeline(editable, isRawSource: false, sectionMutes: sections)
        coordinator.beginBeforeComparison()
        coordinator.beginDevelopMute()
        #expect(coordinator.beginLayerMute(maskIndex: 0))
        coordinator.releaseAll()
        #expect(coordinator.activeImageURL == image)
        #expect(!coordinator.isShowingBefore && !coordinator.isMutingDevelop && !coordinator.isMutingSelectedMask)
        #expect(coordinator.settingsForPipeline(editable, isRawSource: false, sectionMutes: sections) == expected)
        #expect(editable.sharpness == 40 && editable.localAdjustments?.first?.enabled == true)
        #expect(coordinator.beginLayerMute(maskIndex: nil))
        coordinator.releaseAll()
        #expect(!coordinator.isMutingGlobal)
    }

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
    @Test("decoded source publication is generation gated and cleared with its image")
    func sourcePublicationRejectsStaleGenerations() {
        let coordinator = DevelopPreviewSessionCoordinator()
        let firstURL = URL(fileURLWithPath: "/tmp/preview-source-first.jpg")
        let secondURL = URL(fileURLWithPath: "/tmp/preview-source-second.jpg")
        let firstImage = NSImage(size: NSSize(width: 4, height: 3))
        let firstCIImage = CIImage(color: .red).cropped(
            to: CGRect(x: 0, y: 0, width: 4, height: 3)
        )

        coordinator.beginImageSession(firstURL, orientation: 1)
        let firstGeneration = coordinator.sessionGeneration
        #expect(coordinator.publishSource(
            image: firstImage,
            ciImage: firstCIImage,
            for: firstURL,
            sessionGeneration: firstGeneration
        ))
        #expect(coordinator.sourceImage === firstImage)
        #expect(coordinator.sourceCIImage === firstCIImage)

        coordinator.beginImageSession(secondURL, orientation: 6)
        #expect(coordinator.sourceImage == nil)
        #expect(coordinator.sourceCIImage == nil)
        #expect(!coordinator.publishSource(
            image: firstImage,
            ciImage: firstCIImage,
            for: firstURL,
            sessionGeneration: firstGeneration
        ))
        #expect(coordinator.sourceImage == nil)
        #expect(coordinator.sourceCIImage == nil)

        coordinator.endImageSession()
        #expect(coordinator.sourceImage == nil)
        #expect(coordinator.sourceCIImage == nil)
    }

    @Test("materialization and rotation only replace the active retained source")
    func materializationAndRotationAreImageScoped() {
        let coordinator = DevelopPreviewSessionCoordinator()
        let imageURL = URL(fileURLWithPath: "/tmp/preview-source-active.jpg")
        let otherURL = URL(fileURLWithPath: "/tmp/preview-source-other.jpg")
        let quickImage = NSImage(size: NSSize(width: 4, height: 3))
        let quickCIImage = CIImage(color: .red).cropped(
            to: CGRect(x: 0, y: 0, width: 4, height: 3)
        )
        let materialized = CIImage(color: .green).cropped(
            to: CGRect(x: 0, y: 0, width: 8, height: 6)
        )
        let rotatedImage = NSImage(size: NSSize(width: 3, height: 4))
        let rotatedCIImage = CIImage(color: .blue).cropped(
            to: CGRect(x: 0, y: 0, width: 3, height: 4)
        )

        coordinator.beginImageSession(imageURL, orientation: 1)
        let generation = coordinator.sessionGeneration
        #expect(coordinator.publishSource(
            image: quickImage,
            ciImage: quickCIImage,
            for: imageURL,
            sessionGeneration: generation
        ))
        #expect(!coordinator.publishMaterializedSource(
            materialized,
            for: otherURL,
            sessionGeneration: generation
        ))
        #expect(coordinator.sourceCIImage === quickCIImage)
        #expect(coordinator.publishMaterializedSource(
            materialized,
            for: imageURL,
            sessionGeneration: generation
        ))
        #expect(coordinator.sourceImage === quickImage)
        #expect(coordinator.sourceCIImage === materialized)

        let preRotationGeneration = coordinator.sessionGeneration
        #expect(!coordinator.replaceSourceAfterRotation(
            image: rotatedImage,
            ciImage: rotatedCIImage,
            orientation: 6,
            for: otherURL
        ))
        #expect(coordinator.replaceSourceAfterRotation(
            image: rotatedImage,
            ciImage: rotatedCIImage,
            orientation: 6,
            for: imageURL
        ))
        #expect(coordinator.sourceImage === rotatedImage)
        #expect(coordinator.sourceCIImage === rotatedCIImage)
        #expect(coordinator.loadedOrientation(for: imageURL) == 6)
        #expect(coordinator.sessionGeneration == preRotationGeneration + 1)
        #expect(!coordinator.publishMaterializedSource(
            materialized,
            for: imageURL,
            sessionGeneration: preRotationGeneration
        ))
    }

    @Test("edit workspace delegates retained source publication to the preview owner")
    func editWorkspaceSourcePublicationContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("private var sourceImage: NSImage? { previewSession.sourceImage }"))
        #expect(source.contains("private var sourceCIImage: CIImage? { previewSession.sourceCIImage }"))
        #expect(source.contains("previewSession.publishSource("))
        #expect(source.contains("previewSession.publishMaterializedSource("))
        #expect(source.contains("previewSession.replaceSourceAfterRotation("))
        #expect(!source.contains("@State private var sourceImage"))
        #expect(!source.contains("@State private var sourceCIImage"))
        #expect(!source.contains("sourceImage ="))
        #expect(!source.contains("sourceCIImage ="))
    }

    @Test("Develop texture uploads carry the preview session generation")
    func editWorkspaceMetalPublicationContract() throws {
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
            "metalSession.beginImageSession(previewSession.sessionGeneration)"
        ))
        #expect(source.contains(
            "metalSession.replaceSourceImagePublication(previewSession.sessionGeneration)"
        ))
        #expect(source.contains("sessionGeneration: previewSessionGeneration"))
        #expect(source.contains("let didPublishTexture = await Task.detached"))
        #expect(source.contains("guard didPublishTexture, !Task.isCancelled"))
        #expect(source.contains("metalSession.endImageSession()"))
        #expect(!source.contains(
            "metalPipeline?.beginSourceImageSession(previewSession.sessionGeneration)"
        ))
        #expect(!source.contains(
            "pipeline.beginSourceImagePublication(previewSession.sessionGeneration)"
        ))
        #expect(!source.contains("metalPipeline?.clearSourceTexture()"))
        #expect(!source.contains("pipeline.uploadSourceImage(ci, exifOrientation:"))
        #expect(!source.contains("pipeline.uploadSourceImage(rawCIImage, exifOrientation:"))
        #expect(!source.contains("pipeline.uploadSourceImage(fullResCIImage, exifOrientation:"))
        #expect(!source.contains("pipeline.uploadSourceImage(fullRes, exifOrientation:"))
    }

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

@Suite("Metal source publication gate")
struct MetalSourcePublicationGateTests {
    @Test("only the active image generation may publish")
    func rejectsReplacedGeneration() {
        let gate = MetalSourcePublicationGate()
        var published: [String] = []

        gate.beginSession(1) { published.append("clear-1") }
        #expect(gate.publishIfCurrent(sessionGeneration: 1) {
            published.append("publish-1")
        })

        gate.beginSession(2) { published.append("clear-2") }
        #expect(!gate.publishIfCurrent(sessionGeneration: 1) {
            published.append("stale-1")
        })
        #expect(gate.publishIfCurrent(sessionGeneration: 2) {
            published.append("publish-2")
        })

        #expect(published == ["clear-1", "publish-1", "clear-2", "publish-2"])
    }

    @Test("same-image replacement invalidates an older upload without clearing")
    func replacementAdvancesWithoutClearing() {
        let gate = MetalSourcePublicationGate()
        var published: [String] = []

        gate.beginSession(10) { published.append("clear") }
        gate.replaceGeneration(11)

        #expect(!gate.publishIfCurrent(sessionGeneration: 10) {
            published.append("stale")
        })
        #expect(gate.publishIfCurrent(sessionGeneration: 11) {
            published.append("rotated")
        })
        #expect(published == ["clear", "rotated"])
    }

    @Test("teardown clears and rejects every late publication")
    func invalidationRejectsLatePublication() {
        let gate = MetalSourcePublicationGate()
        var publicationCount = 0
        var clearCount = 0

        gate.beginSession(42) { clearCount += 1 }
        gate.invalidate { clearCount += 1 }

        #expect(!gate.publishIfCurrent(sessionGeneration: 42) {
            publicationCount += 1
        })
        #expect(clearCount == 2)
        #expect(publicationCount == 0)
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

    @Test("a redacting photo keeps the feed on the redacted render through Before and mutes")
    func redactingPhotoHoldsRedactedRender() {
        let coordinator = DevelopCleanFeedPublicationCoordinator()
        let controller = CleanFeedController.shared
        coordinator.beginWorkspace(controller: controller)
        defer { coordinator.endWorkspace(editorPipeline: nil, controller: controller) }

        func decide(
            texture: Bool = true, before: Bool = false, mute: Bool = false, layer: Bool = false,
            redaction: RedactionKnowledge
        ) -> DevelopCleanFeedPublicationCoordinator.PublicationDecision? {
            coordinator.publicationDecision(
                hasSourceTexture: texture, isShowingBefore: before, isMutingDevelop: mute,
                isMutingLayer: layer, redaction: redaction, isCropToolActive: false, proposedCrop: nil
            )
        }

        for (before, mute, layer) in [(true, false, false), (false, true, false), (false, false, true)] {
            let held = decide(before: before, mute: mute, layer: layer, redaction: .redacts)
            #expect(held?.usesEditPipeline == true, "the live pipeline keeps the redacted params")
            #expect(held?.holdsRedactedRender == true)
            #expect(held?.allowsFallbackImage == false, "never the unblurred source")
        }

        let live = decide(redaction: .redacts)
        #expect(live?.usesEditPipeline == true)
        #expect(live?.holdsRedactedRender == false)
        #expect(live?.allowsFallbackImage == false)

        let loading = decide(texture: false, before: true, redaction: .redacts)
        #expect(loading?.usesEditPipeline == false)
        #expect(loading?.allowsFallbackImage == false, "black until the GPU source is ready")
        #expect(loading?.holdsRedactedRender == false)

        let unknown = decide(redaction: .unknown)
        #expect(unknown?.usesEditPipeline == false)
        #expect(unknown?.allowsFallbackImage == false)

        // Unredacted photos keep the historical Before/mute fallback.
        let plain = decide(before: true, redaction: .none)
        #expect(plain?.usesEditPipeline == false)
        #expect(plain?.allowsFallbackImage == true)
        #expect(plain?.holdsRedactedRender == false)
    }

    @Test("publishing a redacting photo never hands the unedited source to the feed")
    func redactingPublishClearsFallbackImage() {
        let coordinator = DevelopCleanFeedPublicationCoordinator()
        let controller = CleanFeedController(makeFeedPipeline: { nil })
        coordinator.beginWorkspace(controller: controller)
        defer { coordinator.endWorkspace(editorPipeline: nil, controller: controller) }
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))

        coordinator.publish(
            fallbackImage: source, isHDR: false, hasSourceTexture: false, isShowingBefore: true,
            isMutingDevelop: false, redaction: .redacts, isCropToolActive: false,
            proposedCrop: nil, controller: controller
        )
        #expect(controller.feedImage == nil)

        coordinator.publish(
            fallbackImage: source, isHDR: false, hasSourceTexture: false, isShowingBefore: true,
            isMutingDevelop: false, redaction: .none, isCropToolActive: false,
            proposedCrop: nil, controller: controller
        )
        #expect(controller.feedImage != nil)
    }

    @Test("the held feed payload ignores press-and-hold comparisons but keeps redactions")
    func transientFreeProjectionKeepsRedactions() {
        let preview = DevelopTransientPreviewCoordinator()
        var settings = CameraRawSettings()
        settings.exposure2012 = 1
        settings.anonymizer = AnonymizerSettings(amount: 80, blackOut: nil)
        var blur = MaskAdjustment()
        blur.anonymizer = AnonymizerSettings(amount: 100, blackOut: nil)
        settings.localAdjustments = [blur]

        preview.beginDevelopMute()
        #expect(preview.isTransientComparisonActive)
        let muted = preview.settingsForPipeline(settings, isRawSource: false, sectionMutes: .init())
        #expect(muted?.localAdjustments == nil, "the editor's mute drops the masks")
        let held = preview.settingsForPipelineIgnoringTransientComparisons(
            settings, isRawSource: false, sectionMutes: .init()
        )
        #expect(held?.hasActiveRedaction == true)
        #expect(held?.exposure2012 == 1)
        preview.endDevelopMute()

        #expect(preview.beginLayerMute(maskIndex: nil))
        #expect(preview.settingsForPipeline(settings, isRawSource: false, sectionMutes: .init())?
            .anonymizer == nil, "Cmd-D on Global drops the global Anonymizer in the editor")
        #expect(preview.settingsForPipelineIgnoringTransientComparisons(
            settings, isRawSource: false, sectionMutes: .init()
        )?.anonymizer == settings.anonymizer)
        preview.endLayerMute()
        #expect(!preview.isTransientComparisonActive)
    }
}

@Suite("Redaction privacy guard")
@MainActor
struct RedactionPrivacyGuardTests {
    private func photo(_ path: String, redacts: Bool = false, loaded: Bool = true) -> ImageFile {
        var image = ImageFile(url: URL(fileURLWithPath: path))
        image.developSettingsLoaded = loaded
        if redacts {
            var settings = CameraRawSettings()
            var blur = MaskAdjustment()
            blur.anonymizer = AnonymizerSettings(amount: 100, blackOut: nil)
            settings.localAdjustments = [blur]
            image.cameraRawSettings = settings
        }
        return image
    }

    @Test("knowledge separates unredacted, redacting and not-yet-loaded photos")
    func knowledge() {
        #expect(RedactionPrivacyGuard.knowledge(for: photo("/p/a.jpg")) == .none)
        #expect(RedactionPrivacyGuard.knowledge(for: photo("/p/a.jpg", redacts: true)) == .redacts)
        #expect(RedactionPrivacyGuard.knowledge(for: photo("/p/a.jpg", loaded: false)) == .unknown)
        var disabled = photo("/p/a.jpg", redacts: true)
        disabled.cameraRawSettings?.localAdjustments?[0].enabled = false
        #expect(RedactionPrivacyGuard.knowledge(for: disabled) == .none)
    }

    @Test("drags out of the app refuse redacting, unloaded and unredacted paired JPEG photos")
    func outsideDrag() {
        let plain = photo("/p/plain.jpg")
        let blurred = photo("/p/blurred.jpg", redacts: true)
        let raw = photo("/p/IMG_1.CR3", redacts: true)
        let pairedJPEG = photo("/p/IMG_1.JPG")
        let all = [plain, blurred, raw, pairedJPEG]

        #expect(RedactionPrivacyGuard.outsideDragDecision(for: [plain], candidates: all) == .allow)
        #expect(RedactionPrivacyGuard.outsideDragDecision(for: [plain, blurred], candidates: all).message
            == RedactionPrivacyGuard.dragBlockedMessage)
        #expect(RedactionPrivacyGuard.outsideDragDecision(
            for: [photo("/p/new.jpg", loaded: false)], candidates: all
        ).message == RedactionPrivacyGuard.dragPendingMessage)
        #expect(RedactionPrivacyGuard.outsideDragDecision(for: [pairedJPEG], candidates: all).message
            == RedactionPrivacyGuard.pairedRawDragMessage)
    }

    @Test("only the unredacted non-RAW half of a redacted RAW+JPEG pair is flagged")
    func pairedJPEGs() {
        let raw = photo("/p/IMG_1.NEF", redacts: true)
        let jpeg = photo("/p/img_1.jpg")
        let otherFolderJPEG = photo("/q/IMG_1.jpg")
        let redactedJPEG = photo("/p/IMG_1.jpeg", redacts: true)
        let unredactedRaw = photo("/p/IMG_2.NEF")
        let jpeg2 = photo("/p/IMG_2.jpg")
        let all = [raw, jpeg, otherFolderJPEG, redactedJPEG, unredactedRaw, jpeg2]

        let flagged = RedactionPrivacyGuard.unredactedPairedJPEGs(
            in: [raw, jpeg, otherFolderJPEG, redactedJPEG, jpeg2], candidates: all
        )
        #expect(flagged.map(\.url) == [jpeg.url])
    }

    @Test("Clean Feed only shows frames of a redacting photo that were rendered redacted")
    func cleanFeedPanePolicy() {
        #expect(RedactionPrivacyGuard.mayPublishToCleanFeed(rendersRedaction: false, photo: .none))
        #expect(RedactionPrivacyGuard.mayPublishToCleanFeed(rendersRedaction: true, photo: .redacts))
        #expect(!RedactionPrivacyGuard.mayPublishToCleanFeed(rendersRedaction: false, photo: .redacts))
        #expect(!RedactionPrivacyGuard.mayPublishToCleanFeed(rendersRedaction: false, photo: .unknown))
    }

    @Test("a sidecar redaction the in-memory copy lacks still counts for warnings")
    func sidecarRedaction() {
        var redacting = CameraRawSettings()
        redacting.anonymizer = AnonymizerSettings(amount: nil, blackOut: true)
        let unloaded = photo("/p/a.jpg", loaded: false)
        #expect(RedactionPrivacyGuard.redactsIncludingSidecar(unloaded, readSidecar: { _ in redacting }))
        #expect(!RedactionPrivacyGuard.redactsIncludingSidecar(unloaded, readSidecar: { _ in nil }))
        // Loaded with no sidecar on disk: nothing to read.
        var reads = 0
        #expect(!RedactionPrivacyGuard.redactsIncludingSidecar(photo("/p/a.jpg"), readSidecar: { _ in
            reads += 1
            return redacting
        }))
        #expect(reads == 0)
    }

    @Test("only Export, Save As and FTP commands run the paired-JPEG check in the file-operation switch")
    func commandClassification() {
        #expect(AppCommand.renderSelected.publishesSelectionPixels)
        #expect(AppCommand.uploadAll.publishesSelectionPixels)
        #expect(AppCommand.uploadAll.publishesWholeFolder)
        #expect(!AppCommand.saveAsJPEG.publishesWholeFolder)
        #expect(!AppCommand.renderAndSignSelected.publishesSelectionPixels)
        #expect(!AppCommand.openInExternalEditor.publishesSelectionPixels)
    }

    @Test("the develop-settings-loaded flag is part of row equality and survives copies")
    func loadedFlag() {
        let url = URL(fileURLWithPath: "/p/a.jpg")
        var loaded = ImageFile(url: url)
        let unloaded = loaded
        loaded.developSettingsLoaded = true
        #expect(loaded != unloaded)
        #expect(ImageFile(url: URL(fileURLWithPath: "/p/b.jpg"), relocating: loaded).developSettingsLoaded)
    }

    private func temporaryFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("an on-demand read resolves a photo's develop settings without waiting for the batch")
    func onDemandDevelopRead() async throws {
        let folder = try temporaryFolder("OnDemandDevelop")
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("IMG_1.CR3")
        let plain = folder.appendingPathComponent("IMG_2.CR3")
        try Data("not a real raw".utf8).write(to: raw)
        try Data("not a real raw".utf8).write(to: plain)
        var settings = CameraRawSettings()
        settings.hasSettings = true
        settings.anonymizer = AnonymizerSettings(amount: 75, blackOut: nil)
        var metadata = IPTCMetadata()
        metadata.cameraRaw = settings
        try XMPSidecarService().saveSidecar(metadata: metadata, for: raw)

        let model = BrowserViewModel()
        model.currentFolderURL = folder
        model.images = [ImageFile(url: raw), ImageFile(url: plain)]
        #expect(RedactionPrivacyGuard.knowledge(for: model.images[0]) == .unknown)

        model.ensureDevelopSettingsLoaded(for: [raw, plain])
        let deadline = ContinuousClock.now + .seconds(15)
        while model.images.contains(where: { !$0.developSettingsLoaded }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(RedactionPrivacyGuard.knowledge(for: try #require(model.image(at: raw))) == .redacts)
        #expect(RedactionPrivacyGuard.knowledge(for: try #require(model.image(at: plain))) == .none)
    }

    @Test("the folder scan finds Anonymizer settings in sidecars and embedded XMP, not in RAW bytes")
    func folderScan() throws {
        let folder = try temporaryFolder("FolderRedactionScan")
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = folder.appendingPathComponent("day 2", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let marker = Data("<aaphoto:AnonymizerAmount>80.0</aaphoto:AnonymizerAmount>".utf8)

        try Data("plain".utf8).write(to: folder.appendingPathComponent("a.jpg"))
        // RAW files never carry embedded develop settings; a marker there is just bytes.
        try marker.write(to: folder.appendingPathComponent("b.NEF"))
        // Hidden app folders are skipped.
        let hidden = folder.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try marker.write(to: hidden.appendingPathComponent("a.xmp"))
        #expect(FolderRedactionScanner.scan(folderURL: folder) == .clean)

        try marker.write(to: nested.appendingPathComponent("c.xmp"))
        #expect(FolderRedactionScanner.scan(folderURL: folder) == .redacts)
        try FileManager.default.removeItem(at: nested.appendingPathComponent("c.xmp"))

        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1])
        jpeg.append(marker)
        try jpeg.write(to: nested.appendingPathComponent("d.jpg"))
        #expect(FolderRedactionScanner.scan(folderURL: folder) == .redacts)

        // Too many photos to check: incomplete, never "clean".
        try FileManager.default.removeItem(at: nested.appendingPathComponent("d.jpg"))
        try Data("plain".utf8).write(to: nested.appendingPathComponent("e.jpg"))
        #expect(FolderRedactionScanner.scan(folderURL: folder) == .clean)
        #expect(FolderRedactionScanner.scan(folderURL: folder, fileLimit: 1) == .incomplete)
    }

    @Test("folder drags leave the app only once the folder is known to be clean")
    func folderOutsideDragPolicy() {
        #expect(FolderOutsideDragPolicy.refusalMessage(for: .clean) == nil)
        #expect(FolderOutsideDragPolicy.refusalMessage(for: .checking) == FolderOutsideDragPolicy.checkingMessage)
        #expect(FolderOutsideDragPolicy.refusalMessage(for: .redacts) == FolderOutsideDragPolicy.redactsMessage)
        #expect(FolderOutsideDragPolicy.state(for: .incomplete) == .tooLarge)
        #expect(FolderOutsideDragPolicy.refusalMessage(for: .tooLarge) != nil)
        let folder = URL(fileURLWithPath: "/shoots/2026")
        #expect(FolderOutsideDragPolicy.folder(folder, contains: URL(fileURLWithPath: "/shoots/2026/day 1")))
        #expect(!FolderOutsideDragPolicy.folder(folder, contains: URL(fileURLWithPath: "/shoots/2026-b")))
    }
}

@Suite("Develop preview render coordinator")
@MainActor
struct DevelopPreviewRenderCoordinatorTests {
    @Test("edit workspace has one scope-source publication owner and no dead preview image")
    func sourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("@State private var previewRender = DevelopPreviewRenderCoordinator()"))
        #expect(source.contains("guard decision.shouldMaterializeScopeSource else {"))
        #expect(!source.contains("previewRender.previewImage"))
        #expect(!source.contains("private var displayImage: NSImage?"))
        #expect(!source.contains("@State private var previewCIImage"))
        #expect(!source.contains("previewCIImage ="))
    }

    @Test("a replacement request rejects a cancelled renderer's late publication")
    func replacementRejectsLatePublication() async throws {
        let coordinator = DevelopPreviewRenderCoordinator()
        var publishedWidths: [Int] = []

        coordinator.beginImageSession()
        coordinator.requestRender(
            isHDR: false,
            operation: {
                try? await Task.sleep(for: .milliseconds(80))
                return Self.output(width: 10)
            },
            scopePublisher: { image, _ in publishedWidths.append(image?.width ?? 0) }
        )
        await Task.yield()
        coordinator.requestRender(
            isHDR: false,
            operation: { Self.output(width: 20) },
            scopePublisher: { image, _ in publishedWidths.append(image?.width ?? 0) }
        )

        try await eventually { publishedWidths == [20] }
        try await Task.sleep(for: .milliseconds(100))

        #expect(publishedWidths == [20])
        #expect(!coordinator.isRendering)
    }

    @Test("requests made in the same main-actor turn coalesce to the last operation")
    func sameTurnRequestsCoalesce() async throws {
        let coordinator = DevelopPreviewRenderCoordinator()
        var operationRuns: [Int] = []
        var publishedWidths: [Int] = []

        for width in [10, 20, 30] {
            coordinator.requestRender(
                isHDR: false,
                operation: {
                    operationRuns.append(width)
                    return Self.output(width: width)
                },
                scopePublisher: { image, _ in publishedWidths.append(image?.width ?? 0) }
            )
        }

        try await eventually { !coordinator.isRendering }
        #expect(operationRuns == [30])
        #expect(publishedWidths == [30])
    }

    @Test("replacing a request cancels the running operation")
    func replacementCancelsRunningOperation() async throws {
        let coordinator = DevelopPreviewRenderCoordinator()
        var observedCancellation = false

        coordinator.requestRender(
            isHDR: false,
            operation: {
                try? await Task.sleep(for: .seconds(5))
                observedCancellation = Task.isCancelled
                return nil
            },
            scopePublisher: { _, _ in }
        )
        try await Task.sleep(for: .milliseconds(30))
        coordinator.cancelRender()

        try await eventually { observedCancellation }
        #expect(!coordinator.isRendering)
    }

    @Test("ending an image session rejects an uncooperative late render")
    func endingSessionRejectsLateRender() async throws {
        let coordinator = DevelopPreviewRenderCoordinator()
        var publicationCount = 0

        coordinator.requestRender(
            isHDR: true,
            operation: {
                try? await Task.sleep(for: .milliseconds(50))
                return Self.output(width: 10)
            },
            scopePublisher: { _, _ in publicationCount += 1 }
        )
        coordinator.endImageSession()
        try await Task.sleep(for: .milliseconds(80))

        #expect(publicationCount == 0)
        #expect(!coordinator.isRendering)
    }

    @Test("a failed materialization still publishes the scope HDR state")
    func failedMaterializationPublishesHDRState() async throws {
        let coordinator = DevelopPreviewRenderCoordinator()
        var published: (hasImage: Bool, isHDR: Bool)?

        coordinator.requestRender(
            isHDR: true,
            operation: { nil },
            scopePublisher: { image, isHDR in
                published = (image != nil, isHDR)
            }
        )
        try await eventually { !coordinator.isRendering }

        #expect(published?.hasImage == false)
        #expect(published?.isHDR == true)
    }

    @Test("publishing without an image cancels pending work and reports the HDR mode")
    func publishWithoutImageCancelsPendingWork() async throws {
        let coordinator = DevelopPreviewRenderCoordinator()
        var publications: [(width: Int, isHDR: Bool)] = []

        coordinator.requestRender(
            isHDR: false,
            operation: {
                try? await Task.sleep(for: .milliseconds(50))
                return Self.output(width: 40)
            },
            scopePublisher: { image, isHDR in publications.append((image?.width ?? 0, isHDR)) }
        )
        coordinator.publishWithoutImage(
            isHDR: true,
            scopePublisher: { image, isHDR in publications.append((image?.width ?? 0, isHDR)) }
        )
        try await Task.sleep(for: .milliseconds(80))

        #expect(publications.count == 1)
        #expect(publications.first?.width == 0)
        #expect(publications.first?.isHDR == true)
        #expect(!coordinator.isRendering)
    }

    private static func output(width: Int) -> DevelopPreviewRenderCoordinator.Output {
        let context = CGContext(
            data: nil,
            width: width,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return DevelopPreviewRenderCoordinator.Output(scopeImage: context.makeImage()!)
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

@Suite("Develop Metal preview session coordinator")
@MainActor
struct DevelopMetalPreviewSessionCoordinatorTests {
    @Test("workspace and image generations share one explicit lifecycle")
    func lifecycle() {
        var factoryCalls = 0
        let coordinator = DevelopMetalPreviewSessionCoordinator(
            pipelineFactory: {
                factoryCalls += 1
                return nil
            },
            warmup: { _ in }
        )

        coordinator.beginWorkspace()
        coordinator.beginImageSession(17)

        #expect(coordinator.isWorkspaceActive)
        #expect(coordinator.sourceSessionGeneration == 17)
        #expect(factoryCalls == 1)

        coordinator.replaceSourceImagePublication(18)
        #expect(coordinator.sourceSessionGeneration == 18)

        coordinator.endImageSession()
        #expect(coordinator.sourceSessionGeneration == nil)

        coordinator.endWorkspace()
        #expect(!coordinator.isWorkspaceActive)
        #expect(!coordinator.isContinuousRenderingRequested)
    }

    @Test("inactive sessions reject image and continuous-render publication")
    func inactiveSessionRejectsPublication() {
        let coordinator = DevelopMetalPreviewSessionCoordinator(
            pipelineFactory: { nil },
            warmup: { _ in }
        )

        coordinator.beginImageSession(9)
        coordinator.replaceSourceImagePublication(10)
        coordinator.startContinuousRendering()

        #expect(coordinator.sourceSessionGeneration == nil)
        #expect(!coordinator.isContinuousRenderingRequested)
    }

    @Test("continuous rendering is coordinator-owned and teardown is idempotent")
    func continuousRenderingLifecycle() {
        let coordinator = DevelopMetalPreviewSessionCoordinator(
            pipelineFactory: { nil },
            warmup: { _ in }
        )
        coordinator.beginWorkspace()

        coordinator.startContinuousRendering()
        #expect(coordinator.isContinuousRenderingRequested)

        coordinator.stopContinuousRendering()
        #expect(!coordinator.isContinuousRenderingRequested)

        coordinator.endWorkspace()
        coordinator.endWorkspace()
        #expect(!coordinator.isWorkspaceActive)
        #expect(coordinator.sourceSessionGeneration == nil)
    }

    @Test("edit workspace delegates raw Metal preview ownership")
    func sourceContract() throws {
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
            "@State private var metalSession = DevelopMetalPreviewSessionCoordinator()"
        ))
        #expect(source.contains("metalSession.beginWorkspace()"))
        #expect(source.contains("metalSession.beginImageSession(previewSession.sessionGeneration)"))
        #expect(source.contains(
            "metalSession.replaceSourceImagePublication(previewSession.sessionGeneration)"
        ))
        #expect(source.contains("metalSession.endImageSession()"))
        #expect(source.contains("metalSession.endWorkspace()"))
        #expect(!source.contains("@State private var metalPipeline:"))
        #expect(!source.contains("@State private var metalCoordinator"))
        #expect(!source.contains("MetalLivePreviewPipeline(device:"))
    }
}

@Suite("Develop render policy coordinator")
struct DevelopRenderPolicyCoordinatorTests {
    private let coordinator = DevelopRenderPolicyCoordinator()

    @Test("missing source publishes only the retained fallback")
    func missingSourceUsesFallback() {
        let decision = coordinator.decision(for: DevelopRenderPolicyInput(
            hasSourceImage: false,
            isSliderInteractionActive: false,
            hasMetalScopePipeline: true,
            hasMetalSourceTexture: true,
            isCropInteractionActive: true,
            isComparisonActive: true
        ))

        #expect(decision == DevelopRenderPolicyDecision(
            workPath: .sourceFallback,
            shouldScheduleComparison: false,
            shouldUpdateScopeCrop: false,
            shouldUpdateMetalPipeline: false
        ))
    }

    @Test("interactive edits select Metal or throttled CPU scope without duplicate pipeline work")
    func interactiveScopePolicy() {
        let metal = coordinator.decision(for: DevelopRenderPolicyInput(
            hasSourceImage: true,
            isSliderInteractionActive: true,
            hasMetalScopePipeline: true,
            hasMetalSourceTexture: true,
            isCropInteractionActive: false,
            isComparisonActive: true
        ))
        let cpu = coordinator.decision(for: DevelopRenderPolicyInput(
            hasSourceImage: true,
            isSliderInteractionActive: true,
            hasMetalScopePipeline: false,
            hasMetalSourceTexture: true,
            isCropInteractionActive: false,
            isComparisonActive: false
        ))

        #expect(metal.workPath == .interactiveMetalScope)
        #expect(metal.shouldScheduleComparison)
        #expect(metal.shouldUpdateScopeCrop)
        #expect(!metal.shouldUpdateMetalPipeline)
        #expect(!metal.shouldRequestMetalScopeRedraw)
        #expect(cpu.workPath == .interactiveCPUScope)
        #expect(!cpu.shouldScheduleComparison)
        #expect(!cpu.shouldUpdateMetalPipeline)
    }

    @Test("crop gestures retain Metal while settled edits materialize the preview")
    func cropAndMaterializationPolicy() {
        let crop = coordinator.decision(for: DevelopRenderPolicyInput(
            hasSourceImage: true,
            isSliderInteractionActive: false,
            hasMetalScopePipeline: true,
            hasMetalSourceTexture: true,
            isCropInteractionActive: true,
            isComparisonActive: false
        ))
        let settled = coordinator.decision(for: DevelopRenderPolicyInput(
            hasSourceImage: true,
            isSliderInteractionActive: false,
            hasMetalScopePipeline: true,
            hasMetalSourceTexture: false,
            isCropInteractionActive: false,
            isComparisonActive: true
        ))

        #expect(crop.workPath == .cropInteraction)
        #expect(crop.shouldUpdateMetalPipeline)
        #expect(crop.shouldRequestMetalScopeRedraw)
        #expect(settled.workPath == .materializePreview)
        #expect(settled.shouldScheduleComparison)
        #expect(!settled.shouldUpdateMetalPipeline)
    }

    @Test("settled edits materialize a CPU scope source only when the Metal scope is unavailable")
    func scopeMaterializationPolicy() {
        func decision(scopePipeline: Bool, texture: Bool, dragging: Bool = false, crop: Bool = false)
            -> DevelopRenderPolicyDecision {
            coordinator.decision(for: DevelopRenderPolicyInput(
                hasSourceImage: true,
                isSliderInteractionActive: dragging,
                hasMetalScopePipeline: scopePipeline,
                hasMetalSourceTexture: texture,
                isCropInteractionActive: crop,
                isComparisonActive: false
            ))
        }

        #expect(!decision(scopePipeline: true, texture: true).shouldMaterializeScopeSource)
        #expect(decision(scopePipeline: false, texture: true).shouldMaterializeScopeSource)
        #expect(decision(scopePipeline: true, texture: false).shouldMaterializeScopeSource)
        #expect(!decision(scopePipeline: false, texture: true, dragging: true).shouldMaterializeScopeSource)
        #expect(!decision(scopePipeline: false, texture: true, crop: true).shouldMaterializeScopeSource)
    }

    @Test("display and clipping gamut mappings remain exact")
    func gamutPolicy() {
        #expect(coordinator.displayGamut(
            isHDR: false,
            sdr: .adobeRGB,
            hdr: .rec2020
        ) == .adobeRGB)
        #expect(coordinator.displayGamut(
            isHDR: true,
            sdr: .adobeRGB,
            hdr: .rec2020
        ) == .rec2020)
        #expect(coordinator.gamutClipMode(isEnabled: false, target: .adobeRGB) == 0)
        #expect(coordinator.gamutClipMode(isEnabled: true, target: .sRGB) == 1)
        #expect(coordinator.gamutClipMode(isEnabled: true, target: .displayP3) == 2)
        #expect(coordinator.gamutClipMode(isEnabled: true, target: .rec2020) == 3)
        #expect(coordinator.gamutClipMode(isEnabled: true, target: .adobeRGB) == 4)
    }

    @Test("Develop view delegates render dispatch and gamut mapping")
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

        #expect(source.contains("private let renderPolicy = DevelopRenderPolicyCoordinator()"))
        #expect(source.contains("let decision = renderPolicy.decision("))
        #expect(source.contains("renderPolicy.displayGamut("))
        #expect(source.contains("renderPolicy.gamutClipMode("))
        #expect(!source.contains("switch scopeViewModel.targetGamut"))
        #expect(!source.contains("if lockedCropImageRect != nil {"))
    }
}

@Suite("Develop Save export routing")
struct DevelopSaveExportRoutingTests {
    @Test("Develop Save uses the same metadata overlay and finalization boundary as other exports")
    func sharedPipelineBoundary() throws {
        let source = try saveImplementation()
        #expect(source.contains("EditExportPipeline.renderItem("))
        #expect(source.contains("kind: .format"))
        #expect(source.contains("metadataViewModel.currentFolderURL"))
        #expect(source.contains("folderURL: folderURL"))
        // A source-only copier omits authoritative XMP and pending app metadata.
        #expect(!source.contains("EditedImageRenderer.render("))
        #expect(!source.contains("copyMetadataToRenderedFile("))
        #expect(source.contains("failureTracker.sidecarOverlayFailures"))
        #expect(source.contains("copyFailures.isEmpty && overlayFailures.isEmpty"))
    }

    @Test("Develop Save honors the Export Location setting and never overwrites an existing file")
    func destinationAndCollisionPolicy() throws {
        let source = try saveImplementation()
        #expect(source.contains("EditedImageRenderer.resolveOutputFolder("))
        #expect(source.contains("collisionPolicy: .appendNumber"))
        #expect(!source.contains("appendingPathComponent(\"Edited\""))
        #expect(source.contains("revealURL:"))
    }

    @Test("Develop Save retains its single-session owner and cancellation admission")
    func lifecycleBoundary() throws {
        let source = try saveImplementation()
        let request = try #require(source.range(of: "exportSession.requestExport {"))
        let directory = try #require(source.range(of: "ExportDirectoryService.shared.ensureDirectory("))
        let admission = try #require(source.range(of: "try Task.checkCancellation()"))
        let render = try #require(source.range(of: "EditExportPipeline.renderItem("))
        #expect(request.lowerBound < directory.lowerBound)
        #expect(directory.lowerBound < admission.lowerBound)
        #expect(admission.lowerBound < render.lowerBound)
        #expect(source.contains("!directoryCommit.cancellationRequestedAfterCommit"))
        #expect(source.contains("DevelopExportPersistenceResult("))
    }

    private func saveImplementation() throws -> String {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: workspace.appendingPathComponent(
            "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "    private func saveCurrentRenderedImage() {"))
        let end = try #require(source.range(of: "    private func signedIntString", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

@Suite("Develop interrupted viewport input")
@MainActor
struct DevelopInterruptedViewportTests {
    @Test("focus loss commits the visible pan and zoom as the next gesture anchor")
    func interruptedGesturesKeepVisibleViewport() {
        let navigation = DevelopPreviewNavigationCoordinator()
        navigation.applyZoom(scale: 2, anchoredOffset: CGSize(width: 10, height: 15))
        navigation.updateMagnification(2)
        #expect(navigation.updatePan(translation: CGSize(width: 20, height: -5)))
        let zoom = navigation.zoomScale
        let offset = navigation.offset
        navigation.finishInteraction()
        #expect(navigation.zoomScale == zoom && navigation.offset == offset)
        #expect(navigation.committedZoomScale == zoom && navigation.committedOffset == offset)
        navigation.updateMagnification(1)
        #expect(navigation.zoomScale == zoom)
        #expect(navigation.updatePan(translation: CGSize(width: 3, height: 4)))
        #expect(navigation.offset == CGSize(width: offset.width + 3, height: offset.height + 4))
    }
}
