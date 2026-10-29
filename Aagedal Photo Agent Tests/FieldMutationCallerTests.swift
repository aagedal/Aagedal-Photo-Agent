import AppKit
import Foundation
import CoreGraphics
import Observation
import Testing
@testable import Aagedal_Photo_Agent

private actor FieldMutationCallerRecorder {
    private var requests: [MetadataFieldMutationWriteRequest] = []
    private var gate: CheckedContinuation<Void, Never>?
    let pausesFirst: Bool
    let failingNames: Set<String>
    let failingInvocations: Set<Int>
    init(pausesFirst: Bool = false, failingNames: Set<String> = [], failingInvocations: Set<Int> = []) {
        self.pausesFirst = pausesFirst
        self.failingNames = failingNames
        self.failingInvocations = failingInvocations
    }
    var captured: [MetadataFieldMutationWriteRequest] { requests }
    var isPaused: Bool { gate != nil }
    func resume() { gate?.resume(); gate = nil }
    func write(_ request: MetadataFieldMutationWriteRequest) async -> MetadataFieldMutationWriteResult {
        requests.append(request)
        if pausesFirst, requests.count == 1 { await withCheckedContinuation { gate = $0 } }
        if failingNames.contains(request.imageURL.lastPathComponent) || failingInvocations.contains(requests.count) {
            return .failed(request: request, message: "Injected destination failure")
        }
        var metadata = IPTCMetadata(title: "Unrelated pending caption")
        switch request.mutation {
        case .rating(let value): metadata.rating = value
        case .label(let value): metadata.label = value
        case .addPersons(let names): metadata.personShown = names
        case .replacePersons: request.mutation.apply(to: &metadata)
        case .orientation(_, let target): metadata.exifOrientation = target
        }
        var baseline = IPTCMetadata(title: "Original caption")
        request.mutation.apply(to: &baseline)
        var sidecar = MetadataSidecar(sourceFile: request.imageURL.lastPathComponent,
            pendingChanges: true, metadata: metadata,
            imageMetadataSnapshot: baseline, history: [])
        if request.requestedMode == .historyOnly, case .orientation(let expected, let target) = request.mutation {
            sidecar.orientationDraft = MetadataOrientationDraft(expectedOrientation: expected, targetOrientation: target)
        }
        return .init(requestID: request.id, imageURL: request.imageURL, installedSidecar: sidecar,
            didWriteEmbedded: request.requestedMode == .writeToFile || request.requestedMode == .writeToFileAndXMPSidecar,
            didWriteXMP: request.requestedMode == .writeToXMPSidecar || request.requestedMode == .writeToFileAndXMPSidecar)
    }
}

private actor BrowserFieldConflictSequence {
    enum FirstOutcome: Sendable { case conflict, uncertainImage, uncertainJSON }
    let firstOutcome: FirstOutcome
    private var count = 0
    private var gate: CheckedContinuation<Void, Never>?
    init(_ firstOutcome: FirstOutcome) { self.firstOutcome = firstOutcome }
    var isPaused: Bool { gate != nil }
    func resume() { gate?.resume(); gate = nil }
    func write(_ request: MetadataFieldMutationWriteRequest) async -> MetadataFieldMutationWriteResult {
        count += 1
        guard count == 1 else { return .failed(request: request, message: "Later request failed before commit") }
        await withCheckedContinuation { gate = $0 }
        switch firstOutcome {
        case .conflict:
            var metadata = IPTCMetadata(title: "Historical prepared intent")
            metadata.rating = 1
            let prepared = MetadataSidecar(sourceFile: request.imageURL.lastPathComponent,
                pendingChanges: true, metadata: metadata, imageMetadataSnapshot: nil, history: [])
            return .init(requestID: request.id, imageURL: request.imageURL, installedSidecar: prepared,
                failure: .init(stage: .finalize, message: "Newer saved C was retained", kind: .conflict))
        case .uncertainImage:
            return .init(requestID: request.id, imageURL: request.imageURL, embeddedWriteMayHaveOccurred: true,
                failure: .init(stage: .embedded, message: "Earlier image write outcome is uncertain", kind: .io))
        case .uncertainJSON:
            return .init(requestID: request.id, imageURL: request.imageURL,
                committedButUnverifiedSidecarURL: request.folderURL.appendingPathComponent(".photo_metadata/photo.jpg.meta.json"),
                failure: .init(stage: .prepare, message: "Earlier JSON write outcome is uncertain", kind: .io))
        }
    }
}

private nonisolated final class FieldMutationNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private nonisolated final class ReviewCallerCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@MainActor @Sendable () -> Void] = []
    func schedule(_ callback: @escaping @MainActor @Sendable () -> Void) { lock.withLock { callbacks.append(callback) } }
    @MainActor func deliver() {
        let pending = lock.withLock { let pending = callbacks; callbacks.removeAll(); return pending }
        pending.forEach { $0() }
    }
}

private actor ReviewCallerBaselineSequence {
    private(set) var count = 0
    func load(_ image: URL, _ folder: URL) -> MetadataReviewLoadedBaseline {
        count += 1
        let metadata = IPTCMetadata(title: "Saved revision \(count)")
        return .init(metadata: metadata, sidecar: MetadataSidecar(sourceFile: image.lastPathComponent,
            pendingChanges: true, metadata: metadata, imageMetadataSnapshot: nil))
    }
}

private actor ReviewDirectMutationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var isWaiting: Bool { continuation != nil }
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { released = true; continuation?.resume(); continuation = nil }
}

private nonisolated final class ReviewDirectMutationTrash: ImageTrashHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [URL] = []
    var urls: [URL] { lock.withLock { captured } }
    func trashItem(at url: URL) throws { lock.withLock { captured.append(url) } }
}

@Suite("Browser and Face field mutation callers", .serialized)
struct FieldMutationCallerTests {
    @Test("Metadata batches retain existing order and refresh filters and selection", arguments: [false, true])
    @MainActor
    func metadataBatchPresentation(sortChanged: Bool) {
        let model = BrowserViewModel()
        let folder = URL(fileURLWithPath: "/virtual/metadata-batches")
        let urls = ["c.jpg", "a.jpg", "b.jpg"].map { folder.appendingPathComponent($0) }
        model.currentFolderURL = folder
        model.images = urls.map { ImageFile(url: $0) }
        model.sortOrder = sortChanged ? .rating : .name
        model.selectedImageIDs = [urls[0]]
        model.batchUpdate {}
        let existingOrder = model.sortedImages.map(\.url)
        var updated = model.images
        updated[0].starRating = .five
        updated[0].metadata = IPTCMetadata(title: "Searchable caption")
        model.images = updated
        model.publishMetadataBatch(for: [urls[0]], sortKeyChanged: sortChanged)
        #expect(model.sortedImages.map(\.url) == (sortChanged ? [urls[0], urls[1], urls[2]] : existingOrder))
        #expect(model.selectedImages.first?.starRating == .five)
        model.minimumStarRating = .four
        model.batchUpdate {}
        #expect(model.visibleImages.map(\.url) == [urls[0]])
        #expect(model.visibleImages.first?.metadata?.title == "Searchable caption")
    }

    @Test("Quit waits for every pane's rating/label/rotate writes and lists them in both quit prompts")
    @MainActor
    func quitCoversBrowserFieldWrites() async throws {
        let flush = MetadataEditorTerminationFlush()
        let monitor = BackgroundOperationMonitor()
        let recorder = FieldMutationCallerRecorder(pausesFirst: true)
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) })
        let idle = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) })
        BrowserFieldMutationTermination.register(model, flush: flush, monitor: monitor)
        BrowserFieldMutationTermination.register(idle, flush: flush, monitor: monitor)
        #expect(monitor.activeOperations.isEmpty)
        #expect(flush.pendingActivityDescription == nil)

        let folder = URL(fileURLWithPath: "/virtual/quit-field-writes")
        let urls = ["a.arw", "b.arw", "c.arw"].map { folder.appendingPathComponent($0) }
        model.currentFolderURL = folder
        model.images = urls.map { ImageFile(url: $0) }
        model.selectedImageIDs = Set(urls)
        model.batchUpdate {}
        model.setRating(.three)
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await recorder.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await recorder.isPaused)
        // A second, queued batch: rotation of one photo.
        model.selectedImageIDs = [urls[0]]
        model.batchUpdate {}
        model.rotateClockwise()

        #expect(monitor.activeOperations == ["a rating/label write"])
        #expect(flush.pendingActivityDescription == "Ratings/labels: 4 remaining")

        var flushed = false
        let quit = Task { @MainActor in
            try await flush.flush()
            flushed = true
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(!flushed)
        await recorder.resume()
        try await quit.value
        #expect(flushed)
        #expect(await recorder.captured.count == 4)
        #expect(model.images.map(\.starRating) == [.three, .three, .three])
        #expect(!model.hasFieldMutationWritesInFlight)
        #expect(monitor.activeOperations.isEmpty)
        #expect(flush.pendingActivityDescription == nil)
    }

    @Test("Full screen rates and labels only the displayed photo of a multi-selection")
    @MainActor
    func fullScreenTagsOnlyDisplayedPhoto() async {
        let recorder = FieldMutationCallerRecorder()
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) })
        let folder = URL(fileURLWithPath: "/virtual/full-screen-tag")
        let urls = ["a.jpg", "b.jpg", "c.jpg"].map { folder.appendingPathComponent($0) }
        model.currentFolderURL = folder
        model.images = urls.map { ImageFile(url: $0) }
        model.selectedImageIDs = Set(urls)
        model.lastClickedImageURL = urls[1]
        model.batchUpdate {}
        model.isFullScreen = true
        #expect(model.fullScreenImage?.url == urls[1])
        model.setRatingOnFullScreenImage(.four)
        model.setLabelOnFullScreenImage(.green)
        await model.waitForPendingFieldMutationWrites()
        #expect(await recorder.captured.map(\.imageURL) == [urls[1], urls[1]])
        #expect(model.images.map(\.starRating) == [.none, .four, .none])
        #expect(model.images.map(\.colorLabel) == [.none, .green, .none])
        #expect(model.fullScreenImage?.starRating == .four)
        #expect(model.selectedImageIDs == Set(urls))
    }

    @Test("Grid rating out of the filter moves to the next survivor, else the previous, and keeps multi-selection survivors")
    @MainActor
    func gridRatingOutOfFilterMovesSelection() async {
        let recorder = FieldMutationCallerRecorder()
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) })
        let folder = URL(fileURLWithPath: "/virtual/grid-filter-survivor")
        let urls = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"].map { folder.appendingPathComponent($0) }
        model.currentFolderURL = folder
        model.images = urls.map { var image = ImageFile(url: $0); image.starRating = .three; return image }
        model.minimumStarRating = .three
        model.batchUpdate {}
        #expect(model.visibleImages.map(\.url) == urls)

        // Single selection: the next photo takes over and the culling anchor moves with it.
        model.applySelection(ids: [urls[1]], active: urls[1])
        model.setRating(.one)
        #expect(model.visibleImages.map(\.url) == [urls[0], urls[2], urls[3]])
        #expect(model.selectedImageIDs == [urls[2]])
        #expect(model.lastClickedImageURL == urls[2])
        #expect(model.computeNextSelection()?.active == urls[3])

        // Last photo: falls back to the previous one.
        model.applySelection(ids: [urls[3]], active: urls[3])
        model.setLabel(.red)
        model.setRating(.two)
        #expect(model.selectedImageIDs == [urls[2]])
        #expect(model.lastClickedImageURL == urls[2])

        // Multi-selection that partly disappears keeps its survivors.
        model.applySelection(ids: [urls[0], urls[2]], active: urls[2])
        model.setRating(.one, imagesToMutate: model.images.filter { $0.url == urls[2] })
        #expect(model.visibleImages.map(\.url) == [urls[0]])
        #expect(model.selectedImageIDs == [urls[0]])
        #expect(model.lastClickedImageURL == urls[0])
        await model.waitForPendingFieldMutationWrites()
    }

    @Test("Full screen opened on a multi-selection steps through it, stops at the ends and keeps the set")
    @MainActor
    func fullScreenStepsThroughMultiSelection() {
        let model = BrowserViewModel()
        let folder = URL(fileURLWithPath: "/virtual/full-screen-steps")
        let urls = ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"].map { folder.appendingPathComponent($0) }
        model.currentFolderURL = folder
        model.images = urls.map { ImageFile(url: $0) }
        model.batchUpdate {}
        let selection: Set<URL> = [urls[1], urls[3], urls[4]]
        model.applySelection(ids: selection, active: urls[1])
        model.isFullScreen = true

        #expect(model.stepFullScreen(by: -1) == .atFirst)
        #expect(model.fullScreenImage?.url == urls[1])
        #expect(model.stepFullScreen(by: 1) == .moved)
        #expect(model.fullScreenImage?.url == urls[3])
        #expect(model.stepFullScreen(by: 1) == .moved)
        #expect(model.fullScreenImage?.url == urls[4])
        #expect(model.stepFullScreen(by: 1) == .atLast)
        #expect(model.fullScreenImage?.url == urls[4])
        #expect(model.selectedImageIDs == selection)

        model.isFullScreen = false
        #expect(model.selectedImageIDs == selection)
        #expect(model.lastClickedImageURL == urls[4])

        // A single selection steps through every visible photo.
        model.applySelection(ids: [urls[0]], active: urls[0])
        model.isFullScreen = true
        #expect(model.stepFullScreen(by: 1) == .moved)
        #expect(model.selectedImageIDs == [urls[1]])
        #expect(model.fullScreenImage?.url == urls[1])
    }

    @Test("Deleting in full screen keeps the rest of the multi-selection and shows the next selected photo")
    @MainActor
    func fullScreenDeleteKeepsMultiSelection() async {
        let model = BrowserViewModel(imageTrashHandler: ReviewDirectMutationTrash())
        let urls = ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"].map {
            URL(fileURLWithPath: "/virtual/full-screen-delete").appendingPathComponent($0)
        }
        model.images = urls.map { ImageFile(url: $0) }
        model.batchUpdate {}
        model.applySelection(ids: [urls[1], urls[3], urls[4]], active: urls[3])
        model.isFullScreen = true

        model.confirmDeleteFullScreenImage()
        model.deleteConfirmedImages()
        await model.waitForPendingImageMutation()
        #expect(model.selectedImageIDs == [urls[1], urls[4]])
        #expect(model.fullScreenImage?.url == urls[4])
        #expect(model.isFullScreen)

        // The last selected photo goes: the viewer steps back within the selection.
        model.confirmDeleteFullScreenImage()
        model.deleteConfirmedImages()
        await model.waitForPendingImageMutation()
        #expect(model.selectedImageIDs == [urls[1]])
        #expect(model.fullScreenImage?.url == urls[1])
    }

    @Test("A plain filter change keeps only the visible selection; Compare keeps its photo selected")
    @MainActor
    func filterChangeDoesNotMoveSelectionToNeighbour() async {
        let recorder = FieldMutationCallerRecorder()
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) })
        let folder = URL(fileURLWithPath: "/virtual/filter-change")
        let urls = ["a.jpg", "b.jpg", "c.jpg"].map { folder.appendingPathComponent($0) }
        model.currentFolderURL = folder
        model.images = urls.enumerated().map { index, url in
            var image = ImageFile(url: url)
            image.starRating = index == 1 ? .one : .four
            return image
        }
        model.batchUpdate {}
        model.applySelection(ids: [urls[1]], active: urls[1])
        model.minimumStarRating = .three
        model.batchUpdate {}
        #expect(model.visibleImages.map(\.url) == [urls[0], urls[2]])
        #expect(model.selectedImageIDs.isEmpty)

        // Compare: rating its focused photo out of the filter keeps the selection on it.
        model.applySelection(ids: [urls[0]], active: urls[0])
        model.keepsSelectionThroughFilterChanges = true
        model.setRating(.one, imagesToMutate: model.images.filter { $0.url == urls[0] })
        #expect(model.visibleImages.map(\.url) == [urls[2]])
        #expect(model.selectedImageIDs == [urls[0]])
        #expect(model.selectedImages.map(\.url) == [urls[0]])
        await model.waitForPendingFieldMutationWrites()
    }

    @Test("Full-screen selection commands collapse a kept multi-selection to the shown photo")
    @MainActor
    func fullScreenCommandsTargetShownPhoto() {
        #expect(AppCommand.pasteIPTCMetadata.actsOnBrowserSelection)
        #expect(AppCommand.applyTemplateShortcut(1).actsOnBrowserSelection)
        #expect(AppCommand.renameSelected.actsOnBrowserSelection)
        #expect(!AppCommand.setRating(.one).actsOnBrowserSelection)
        #expect(!AppCommand.renderAll.actsOnBrowserSelection)
        #expect(AppCommand.setRating(.one).requiresAvailableFolder)
        #expect(!AppCommand.openFolder.requiresAvailableFolder)

        let model = BrowserViewModel()
        let urls = ["a.jpg", "b.jpg", "c.jpg"].map {
            URL(fileURLWithPath: "/virtual/full-screen-commands").appendingPathComponent($0)
        }
        model.images = urls.map { ImageFile(url: $0) }
        model.batchUpdate {}
        model.applySelection(ids: Set(urls), active: urls[1])
        model.collapseSelectionToFullScreenImage()
        #expect(model.selectedImageIDs == Set(urls)) // not in full screen: untouched
        model.isFullScreen = true
        model.collapseSelectionToFullScreenImage()
        #expect(model.selectedImageIDs == [urls[1]])
    }

    @Test("Only user-initiated changes ask the grid to reveal the selection")
    @MainActor
    func revealRequestsAreUserInitiated() {
        let model = BrowserViewModel()
        let folder = URL(fileURLWithPath: "/virtual/reveal")
        let urls = ["a.jpg", "b.jpg"].map { folder.appendingPathComponent($0) }
        model.images = urls.map { ImageFile(url: $0) }
        model.batchUpdate {}
        _ = model.consumeRevealActiveRequest()

        // A background metadata re-sort is not a reason to scroll.
        model.publishMetadataBatch(for: [urls[0]], sortKeyChanged: true)
        #expect(!model.consumeRevealActiveRequest())

        model.minimumStarRating = .one
        #expect(model.consumeRevealActiveRequest())
        #expect(!model.consumeRevealActiveRequest())
        model.sortReversed.toggle()
        #expect(model.consumeRevealActiveRequest())
    }

    @Test("Folder availability treats only a missing path as gone")
    func folderAvailability() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(BrowserViewModel.folderAvailabilityNow(folder) == .available)
        try FileManager.default.removeItem(at: folder)
        #expect(BrowserViewModel.folderAvailabilityNow(folder) == .gone)
    }

    @Test("Older background metadata cannot overwrite accepted ratings or labels", arguments: [false, true], ["pending", "accepted during read", "completed during read"])
    @MainActor
    func backgroundReadPreservesPendingTag(isLabel: Bool, phase: String) async throws {
        let recorder = FieldMutationCallerRecorder(pausesFirst: true)
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) })
        let folder = URL(fileURLWithPath: "/virtual/background-tag")
        let url = folder.appendingPathComponent("photo.jpg")
        model.currentFolderURL = folder
        model.images = [ImageFile(url: url)]
        model.selectedImageIDs = [url]
        model.batchUpdate {}
        var readRevisions = model.captureTagReadRevisions(for: [url])
        if isLabel { model.setLabel(.red) } else { model.setRating(.five) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await recorder.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await recorder.isPaused)
        if phase != "accepted during read" { readRevisions = model.captureTagReadRevisions(for: [url]) }
        if phase == "completed during read" {
            await recorder.resume()
            await model.waitForPendingFieldMutationWrites()
        }
        var images = model.images
        model.applyBatchMetadataResults([[MetadataDictKey.sourceFile: url.path, MetadataDictKey.rating: 0]],
            to: &images, localIndex: [url: 0], nativeHDRByURL: [:], tagRevisionsAtRead: readRevisions)
        #expect(images[0].starRating == (isLabel ? .none : .five))
        #expect(images[0].colorLabel == (isLabel ? .red : .none))
        await recorder.resume()
        await model.waitForPendingFieldMutationWrites()
        #expect(model.images[0].starRating == (isLabel ? .none : .five))
        #expect(model.images[0].colorLabel == (isLabel ? .red : .none))
    }

    @Test("Review commit reads the current central buffer and rejects obsolete row owners")
    @MainActor
    func reviewCaptureOnlyAndOwnerGuards() async throws {
        let photo = URL(fileURLWithPath: "/virtual/review-owner/photo.jpg")
        let queue = CaptionDraftPersistenceQueue(label: "review.owner")
        queue.enqueue(operation: { throw CaptionWorkspaceFlushError.persistenceFailed("Hold queued work") })
        let sequence = ReviewCallerBaselineSequence()
        let model = BrowserViewModel(metadataReviewBaselineLoader: { await sequence.load($0, $1) },
            metadataReviewCoordinator: CaptionWorkspaceFlushCoordinator(persistenceQueue: queue))
        model.currentFolderURL = photo.deletingLastPathComponent()
        model.images = [ImageFile(url: photo)]
        await model.prepareMetadataReviewEditor(for: photo)
        let obsoleteID = try #require(model.metadataReviewEditor(for: photo)?.id)
        await model.prepareMetadataReviewEditor(for: photo)
        let currentID = try #require(model.metadataReviewEditor(for: photo)?.id)
        #expect(obsoleteID != currentID)
        model.updateMetadataReviewText("Fresh text before another view render", field: .headline, for: photo, editorID: currentID)
        model.updateMetadataReviewText("Old row callback", field: .headline, for: photo, editorID: obsoleteID)
        model.commitMetadataReviewEditor(for: photo, editorID: obsoleteID)
        #expect(await queue.pendingCountWhenIdle() == 1)
        model.commitMetadataReviewEditor(for: photo, editorID: currentID)
        #expect(await queue.pendingCountWhenIdle() == 2)
        #expect(model.metadataReviewEditor(for: photo)?.previous.title == "Fresh text before another view render")
        #expect(model.metadataReviewEditor(for: photo)?.sidecar?.metadata.title == "Fresh text before another view render")
    }

    @Test("Review freezes row admission synchronously and obsolete cleanup cannot release a newer owner")
    @MainActor
    func reviewSynchronousFreezeOwnership() async throws {
        let photo = URL(fileURLWithPath: "/virtual/review-freeze/photo.jpg")
        let queue = CaptionDraftPersistenceQueue(label: "review.freeze")
        queue.enqueue(operation: { throw CaptionWorkspaceFlushError.persistenceFailed("Hold queued work") })
        let sequence = ReviewCallerBaselineSequence()
        let model = BrowserViewModel(metadataReviewBaselineLoader: { await sequence.load($0, $1) },
            metadataReviewCoordinator: CaptionWorkspaceFlushCoordinator(persistenceQueue: queue))
        model.currentFolderURL = photo.deletingLastPathComponent()
        model.images = [ImageFile(url: photo)]
        await model.prepareMetadataReviewEditor(for: photo)
        let editorID = try #require(model.metadataReviewEditor(for: photo)?.id)
        model.updateMetadataReviewText("Included before review", field: .headline, for: photo, editorID: editorID)
        let freeze = try model.beginMetadataReviewRecovery(for: photo)
        // The async coordinator has not begun its review yet; the model already blocks input.
        #expect(model.metadataReviewCoordinator.isReviewing(photo) == false)
        #expect(model.isMetadataReviewFrozen(for: photo))
        model.updateMetadataReviewText("Unexported admission-gap text", field: .headline, for: photo, editorID: editorID)
        model.commitMetadataReviewEditor(for: photo, editorID: editorID)
        #expect(await queue.pendingCountWhenIdle() == 2)
        #expect(model.metadataReviewEditor(for: photo)?.draft.title == "Included before review")
        model.endMetadataReviewRecovery(for: photo, owner: UUID())
        #expect(model.isMetadataReviewFrozen(for: photo))
        model.endMetadataReviewRecovery(for: photo, owner: freeze)
        let replacement = try model.beginMetadataReviewRecovery(for: photo)
        model.endMetadataReviewRecovery(for: photo, owner: freeze)
        #expect(model.isMetadataReviewFrozen(for: photo))
        model.endMetadataReviewRecovery(for: photo, owner: replacement)
        model.updateMetadataReviewText("Accepted after cancellation", field: .headline, for: photo, editorID: editorID)
        #expect(model.metadataReviewEditor(for: photo)?.draft.title == "Accepted after cancellation")
    }

    @Test("A delayed Review receipt rebases full live Description without consulting summarized history")
    @MainActor
    func reviewLiveDescriptionSurvivesReceipt() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ReviewReceipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: photo)
        let baseline = IPTCMetadata(title: "Headline A", description: "Original full description")
        try MetadataSidecarService().saveSidecar(MetadataSidecar(sourceFile: photo.lastPathComponent,
            pendingChanges: true, metadata: baseline, imageMetadataSnapshot: nil), for: photo, in: folder)
        let callbacks = ReviewCallerCallbacks()
        let queue = CaptionDraftPersistenceQueue(label: "review.receipt", failureDelivery: .init(schedule: callbacks.schedule))
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        let model = BrowserViewModel(metadataReviewCoordinator: coordinator)
        model.currentFolderURL = folder
        model.images = [ImageFile(url: photo)]
        await model.prepareMetadataReviewEditor(for: photo)
        let editorID = try #require(model.metadataReviewEditor(for: photo)?.id)
        model.updateMetadataReviewText("Headline B", field: .headline, for: photo, editorID: editorID)
        model.commitMetadataReviewEditor(for: photo, editorID: editorID)
        try await coordinator.retryQueuedPersistence()
        let liveDescription = String(repeating: "A full live sentence with spaces. ", count: 10).trimmingCharacters(in: .whitespaces)
        model.updateMetadataReviewText(liveDescription, field: .description, for: photo, editorID: editorID)
        callbacks.deliver()
        let editor = try #require(model.metadataReviewEditor(for: photo))
        #expect(editor.error == nil)
        #expect(editor.previous.title == "Headline B")
        #expect(editor.previous.description == baseline.description)
        #expect(editor.draft.description == liveDescription)
        #expect(model.metadataReviewText(for: .description, imageURL: photo) == liveDescription)
        #expect(editor.latestRequestID == nil)
    }

    @Test("Review retains a partial mirror and a dependent edit with more than twenty changed fields")
    @MainActor
    func reviewRetainsLargeDraftAndDependentRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ReviewCaller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: photo)
        let sourceBytes = try Data(contentsOf: photo)
        let initial = MetadataSidecar(sourceFile: photo.lastPathComponent, pendingChanges: true,
            metadata: IPTCMetadata(title: "Initial pending caption"), imageMetadataSnapshot: nil,
            orientationDraft: MetadataOrientationDraft(expectedOrientation: 1, targetOrientation: 6))
        let sidecars = MetadataSidecarService()
        try sidecars.saveSidecar(initial, for: photo, in: folder)
        let jsonURL = folder.appendingPathComponent(".photo_metadata/photo.png.meta.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        raw["futureReviewMarker"] = ["keep": "opaque value"]
        try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]).write(to: jsonURL)
        let callbacks = ReviewCallerCallbacks()
        let queue = CaptionDraftPersistenceQueue(label: "review.caller.large", failureDelivery: .init(schedule: callbacks.schedule))
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        let model = BrowserViewModel(metadataReviewCoordinator: coordinator)
        model.currentFolderURL = folder
        model.images = [ImageFile(url: photo)]
        await model.prepareMetadataReviewEditor(for: photo)
        let baseline = try #require(model.metadataReviewEditor(for: photo))
        #expect(baseline.sidecar?.imageMetadataSnapshot == nil)
        let xmpURL = photo.deletingPathExtension().appendingPathExtension("xmp")
        try FileManager.default.createDirectory(at: xmpURL, withIntermediateDirectories: true)
        try Data("intentional mirror obstruction".utf8).write(to: xmpURL.appendingPathComponent("blocker"))
        let fields: [MetadataFieldID] = [.headline, .description, .extendedDescription, .keywords, .personShown,
            .organisationShownName, .organisationShownCode, .creator, .creatorJobTitle, .descriptionWriter,
            .credit, .copyright, .rightsUsageTerms, .webStatementOfRights, .digitalImageGUID,
            .imageSupplierImageID, .jobId, .city, .sublocation, .provinceState, .country,
            .countryCode, .event, .instructions, .source]
        var first = baseline.draft
        for field in fields { field.setTextValue(field == .countryCode ? "NOR" : "Value \(field.rawValue)", in: &first) }
        try #require(MetadataHistoryEntry.changes(from: baseline.draft, to: first, timestamp: Date()).count > 20)
        model.saveMetadataReviewEdit(first, for: photo)
        do { try await coordinator.retryQueuedPersistence(); Issue.record("Expected the obstructed mirror to fail") } catch { }
        #expect(await queue.pendingCountWhenIdle() == 1)
        var second = first
        second.title = "Final dependent headline"
        model.saveMetadataReviewEdit(second, for: photo)
        #expect(await queue.pendingCountWhenIdle() == 2)
        callbacks.deliver()
        #expect(model.metadataReviewEditor(for: photo)?.draft.title == second.title)
        #expect(model.metadataReviewEditor(for: photo)?.error == nil)
        let savedFirst = try #require(sidecars.loadSidecar(for: photo, in: folder))
        #expect(savedFirst.metadata.title == first.title)
        #expect(savedFirst.history.count == 20)
        try FileManager.default.removeItem(at: xmpURL)
        try await coordinator.retryQueuedPersistence()
        callbacks.deliver()
        #expect(await queue.pendingCountWhenIdle() == 0)
        let final = try #require(sidecars.loadSidecar(for: photo, in: folder))
        for field in fields { #expect(field.historyValue(in: final.metadata) == field.historyValue(in: second)) }
        #expect(final.history.count == 20)
        #expect(final.history.last?.newValue == second.title)
        #expect(final.imageMetadataSnapshot == nil)
        #expect(final.orientationDraft == initial.orientationDraft)
        #expect(try Data(contentsOf: photo) == sourceBytes)
        let finalRaw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        #expect((finalRaw["futureReviewMarker"] as? [String: String])?["keep"] == "opaque value")
        #expect(XMPSidecarService().loadSidecar(for: photo)?.title == second.title)
        #expect(model.metadataReviewEditor(for: photo)?.latestRequestID == nil)
        #expect(model.metadataReviewEditor(for: photo)?.draft.title == second.title)
    }

    @Test("Review raw spaces and token delimiters survive row buffers and clean reloads preserve dirty drafts")
    @MainActor
    func reviewRawBuffersAndCleanReload() async throws {
        let sequence = ReviewCallerBaselineSequence()
        let photo = URL(fileURLWithPath: "/virtual/review-buffers/photo.jpg")
        let model = BrowserViewModel(metadataReviewBaselineLoader: { await sequence.load($0, $1) },
            metadataReviewCoordinator: CaptionWorkspaceFlushCoordinator())
        model.currentFolderURL = photo.deletingLastPathComponent()
        model.images = [ImageFile(url: photo)]
        await model.prepareMetadataReviewEditor(for: photo)
        #expect(model.metadataReviewEditor(for: photo)?.draft.title == "Saved revision 1")
        await model.prepareMetadataReviewEditor(for: photo)
        #expect(model.metadataReviewEditor(for: photo)?.draft.title == "Saved revision 2")
        model.updateMetadataReviewText("Words with a trailing ", field: .headline, for: photo)
        model.updateMetadataReviewText("one, two, ", field: .keywords, for: photo)
        #expect(model.metadataReviewText(for: .headline, imageURL: photo) == "Words with a trailing ")
        #expect(model.metadataReviewText(for: .keywords, imageURL: photo) == "one, two, ")
        #expect(model.metadataReviewEditor(for: photo)?.draft.keywords == ["one", "two"])
        await model.prepareMetadataReviewEditor(for: photo)
        #expect(await sequence.count == 2)
        #expect(model.metadataReviewText(for: .headline, imageURL: photo) == "Words with a trailing ")
    }

    @Test("A direct Browser deletion cannot bypass retained Review buffers or the shared failed queue")
    @MainActor
    func reviewDirectMutationUsesSharedBarrier() async throws {
        let photo = URL(fileURLWithPath: "/virtual/review-barrier/photo.jpg")
        let queue = CaptionDraftPersistenceQueue(label: "review.caller.barrier")
        queue.enqueue(operation: { throw CaptionWorkspaceFlushError.persistenceFailed("Earlier queued failure") })
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        let sequence = ReviewCallerBaselineSequence()
        let model = BrowserViewModel(metadataReviewBaselineLoader: { await sequence.load($0, $1) }, metadataReviewCoordinator: coordinator)
        model.currentFolderURL = photo.deletingLastPathComponent()
        model.images = [ImageFile(url: photo)]
        model.selectedImageIDs = [photo]
        await model.prepareMetadataReviewEditor(for: photo)
        model.updateMetadataReviewText("Buffered before deletion", field: .headline, for: photo)
        model.deleteSelectedImages()
        await model.waitForPendingImageMutation()
        #expect(await queue.pendingCountWhenIdle() == 2)
        #expect(model.images.first?.url == photo)
        #expect(model.errorMessage?.contains("Earlier queued failure") == true)
        #expect(model.metadataReviewEditor(for: photo)?.draft.title == "Buffered before deletion")
    }

    @Test("Direct deletion suspends for retained writes, freezes Review, and refuses duplicate or obsolete commands", arguments: [false, true])
    @MainActor
    func directDeletionWaitsForRetainedDurability(changesContext: Bool) async throws {
        let photo = URL(fileURLWithPath: "/virtual/review-direct-async/photo.jpg")
        let sequence = ReviewCallerBaselineSequence()
        let gate = ReviewDirectMutationGate()
        let trash = ReviewDirectMutationTrash()
        let queue = CaptionDraftPersistenceQueue(label: "review.direct.async")
        queue.enqueueAsync(operation: { await gate.wait() })
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        let model = BrowserViewModel(imageTrashHandler: trash,
            metadataReviewBaselineLoader: { await sequence.load($0, $1) }, metadataReviewCoordinator: coordinator)
        model.currentFolderURL = photo.deletingLastPathComponent()
        model.images = [ImageFile(url: photo)]
        model.selectedImageIDs = [photo]
        await model.prepareMetadataReviewEditor(for: photo)
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.isWaiting), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.isWaiting)
        model.deleteSelectedImages()
        #expect(coordinator.isTransitioning)
        #expect(trash.urls.isEmpty)
        model.deleteSelectedImages()
        model.updateMetadataReviewText("Blocked late edit", field: .headline, for: photo)
        #expect(model.metadataReviewText(for: .headline, imageURL: photo) == "Saved revision 1")
        if changesContext { model.selectedImageIDs = [] }
        await gate.resume()
        await model.waitForPendingImageMutation()
        #expect(!coordinator.isTransitioning)
        #expect(trash.urls == (changesContext ? [] : [photo]))
        #expect(model.images.count == (changesContext ? 1 : 0))
    }

    @Test("A failed retained write preserves newer Browser context feedback", arguments: [false, true])
    @MainActor
    func obsoleteDirectDeletionFailureDoesNotPublish(changesFolder: Bool) async throws {
        let photo = URL(fileURLWithPath: "/virtual/review-direct-failure/photo.jpg")
        let gate = ReviewDirectMutationGate()
        let trash = ReviewDirectMutationTrash()
        let queue = CaptionDraftPersistenceQueue(label: "review.direct.failure")
        queue.enqueueAsync(operation: {
            await gate.wait()
            throw CaptionWorkspaceFlushError.persistenceFailed("Old context failure")
        })
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        let model = BrowserViewModel(imageTrashHandler: trash, metadataReviewCoordinator: coordinator)
        model.currentFolderURL = photo.deletingLastPathComponent()
        model.images = [ImageFile(url: photo)]
        model.selectedImageIDs = [photo]
        model.deleteSelectedImages()
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.isWaiting), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.isWaiting)
        if changesFolder {
            model.currentFolderURL = URL(fileURLWithPath: "/virtual/replacement-folder")
        } else {
            model.selectedImageIDs = []
        }
        model.errorMessage = "Current context feedback"
        await gate.resume()
        await model.waitForPendingImageMutation()
        #expect(!coordinator.isTransitioning)
        #expect(queue.hasPendingWork)
        #expect(model.errorMessage == "Current context feedback")
        #expect(trash.urls.isEmpty)
    }

    @Test("A retained FIFO is drained before direct deletion even with no mounted Review editors")
    @MainActor
    func directDeletionDrainsWithoutEditors() async throws {
        let photo = URL(fileURLWithPath: "/virtual/review-direct-unmounted/photo.jpg")
        let gate = ReviewDirectMutationGate()
        let trash = ReviewDirectMutationTrash()
        let queue = CaptionDraftPersistenceQueue(label: "review.direct.unmounted")
        queue.enqueueAsync(operation: { await gate.wait() })
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        let model = BrowserViewModel(imageTrashHandler: trash, metadataReviewCoordinator: coordinator)
        model.currentFolderURL = photo.deletingLastPathComponent()
        model.images = [ImageFile(url: photo)]
        model.selectedImageIDs = [photo]
        model.deleteSelectedImages()
        #expect(coordinator.isTransitioning)
        #expect(trash.urls.isEmpty)
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.isWaiting), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.isWaiting)
        await gate.resume()
        await model.waitForPendingImageMutation()
        #expect(trash.urls == [photo])
    }

    @Test("Browser folder reload distinguishes absent and explicitly cleared XMP labels", arguments: [false, true])
    @MainActor
    func browserReloadRespectsExplicitLabelClear(explicitClear: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("BrowserLabelClear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: photo)
        try await SwiftExifWriteEngine().writeFields([.label: "Select", .headline: "Original caption"], to: [photo])
        let sourceBytes = try Data(contentsOf: photo)
        let attribute = explicitClear ? "xmp:Label=\"\"" : ""
        let xml = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" \(attribute)/></rdf:RDF></x:xmpmeta>"
        try Data(xml.utf8).write(to: photo.deletingPathExtension().appendingPathExtension("xmp"))
        for _ in 0..<2 {
            let model = BrowserViewModel()
            model.loadFolder(url: folder, addToOpenFolders: false)
            await model.waitForFolderLoad()
            #expect(model.folderLoadErrorMessage == nil)
            #expect(model.images.count == 1)
            let image = try #require(model.images.first)
            #expect(image.filename == photo.lastPathComponent)
            #expect(image.colorLabel == (explicitClear ? ColorLabel.none : ColorLabel.red))
        }
        #expect(try Data(contentsOf: photo) == sourceBytes)
    }

    @Test("Rapid Browser rating and label intents retain admission order, folder and mode")
    @MainActor
    func browserCapturesAndSerializesIntents() async throws {
        let recorder = FieldMutationCallerRecorder(pausesFirst: true)
        var mode = MetadataWriteMode.historyOnly
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) },
            fieldMutationModeResolver: { _, _ in mode })
        let folder = URL(fileURLWithPath: "/virtual/captured-folder")
        let photo = folder.appendingPathComponent("photo.jpg")
        model.currentFolderURL = folder
        model.images = [ImageFile(url: photo)]
        model.selectedImageIDs = [photo]
        model.setRating(.one)
        try await waitForPause(recorder)
        mode = .writeToFile
        model.setRating(.five)
        model.setLabel(.blue)
        #expect(model.images.first?.starRating == .five)
        #expect(model.images.first?.colorLabel == .blue)
        #expect(await recorder.captured.count == 1)
        let otherFolder = URL(fileURLWithPath: "/virtual/other-folder")
        let otherPhoto = otherFolder.appendingPathComponent("other.jpg")
        model.currentFolderURL = otherFolder
        model.images = [ImageFile(url: otherPhoto)]
        mode = .writeToXMPSidecar
        await recorder.resume()
        await model.waitForPendingFieldMutationWrites()
        let captured = await recorder.captured
        #expect(captured.count == 3)
        #expect(captured.allSatisfy { $0.folderURL == folder && $0.imageURL == photo })
        #expect(captured.map(\.requestedMode) == [.historyOnly, .writeToFile, .writeToFile])
        if case .rating(let rating) = captured[0].mutation { #expect(rating == 1) } else { Issue.record("First rating intent changed") }
        if case .rating(let rating) = captured[1].mutation { #expect(rating == 5) } else { Issue.record("Later rating intent changed") }
        if case .label(let label) = captured[2].mutation { #expect(label == "Review") } else { Issue.record("Independent label intent changed") }
        #expect(model.images.first?.url == otherPhoto)
        #expect(model.images.first?.starRating == StarRating.none)
        #expect(model.images.first?.colorLabel == ColorLabel.none)
        #expect(model.fieldMutationResults.isEmpty)
    }

    @Test("Browser rotations capture ordered per-photo targets and mode without cancelling prior fields", arguments: [false, true])
    @MainActor
    func browserRotationIntentChain(switchFolder: Bool) async throws {
        let recorder = FieldMutationCallerRecorder(pausesFirst: true)
        var mode: MetadataWriteMode = .historyOnly
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) },
            fieldMutationModeResolver: { _, _ in mode })
        let folder = URL(fileURLWithPath: "/virtual/rotation-chain")
        let photo = folder.appendingPathComponent("photo.jpg")
        model.currentFolderURL = folder
        model.images = [ImageFile(url: photo)]
        model.selectedImageIDs = [photo]
        model.rotateClockwise()
        try await waitForPause(recorder)
        #expect(model.images.first?.exifOrientation == 6)
        model.rotateClockwise()
        #expect(model.images.first?.exifOrientation == 3)
        mode = .writeToFileAndXMPSidecar
        model.applyPendingOrientationToSelection()
        model.setRating(.four)
        model.rotateCounterclockwise()
        #expect(model.images.first?.exifOrientation == 6)
        #expect(await recorder.captured.count == 1)
        let otherPhoto = URL(fileURLWithPath: "/virtual/other/other.jpg")
        if switchFolder {
            model.currentFolderURL = otherPhoto.deletingLastPathComponent()
            model.images = [ImageFile(url: otherPhoto)]
        }
        await recorder.resume()
        await model.waitForPendingFieldMutationWrites()
        let requests = await recorder.captured
        #expect(requests.count == 5)
        #expect(requests.allSatisfy { $0.imageURL == photo && $0.folderURL == folder })
        #expect(requests.map(\.requestedMode) == [.historyOnly, .historyOnly, .writeToFileAndXMPSidecar, .writeToFileAndXMPSidecar, .writeToFileAndXMPSidecar])
        #expect(requests[0].mutation == .orientation(expected: 1, new: 6))
        #expect(requests[1].mutation == .orientation(expected: 6, new: 3))
        #expect(requests[2].mutation == .orientation(expected: 3, new: 3))
        #expect(requests[3].mutation == .rating(4))
        #expect(requests[4].mutation == .orientation(expected: 3, new: 6))
        if switchFolder {
            #expect(model.images.first?.url == otherPhoto)
            #expect(model.images.first?.exifOrientation == 1)
            #expect(model.fieldMutationResults.isEmpty)
        } else {
            #expect(model.images.first?.exifOrientation == 6)
            #expect(model.images.first?.starRating == .four)
            #expect(model.images.first?.hasPendingMetadataChanges == true)
            #expect(model.images.first?.pendingFieldNames.contains("Headline") == true)
            #expect(model.hasPendingOrientationInSelection == false)
        }
    }

    @Test("A rotation captures each selected photo's orientation and credential-specific destination")
    @MainActor
    func browserRotationCapturesPerPhotoFacts() async throws {
        let recorder = FieldMutationCallerRecorder()
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) },
            fieldMutationModeResolver: { hasC2PA, isRaw in
                hasC2PA || isRaw ? .writeToXMPSidecar : .writeToFile
            })
        let folder = URL(fileURLWithPath: "/virtual/per-photo-rotation")
        var ordinary = ImageFile(url: folder.appendingPathComponent("ordinary.jpg"))
        ordinary.exifOrientation = 1
        var protected = ImageFile(url: folder.appendingPathComponent("protected.jpg"))
        protected.hasC2PA = true
        protected.exifOrientation = 8
        model.currentFolderURL = folder
        model.images = [ordinary, protected]
        model.selectedImageIDs = [ordinary.url, protected.url]
        model.rotateClockwise()
        await model.waitForPendingFieldMutationWrites()
        let requests = await recorder.captured
        #expect(requests.count == 2)
        let ordinaryRequest = try #require(requests.first { $0.imageURL == ordinary.url })
        let protectedRequest = try #require(requests.first { $0.imageURL == protected.url })
        #expect(ordinaryRequest.mutation == .orientation(expected: 1, new: 6))
        #expect(ordinaryRequest.requestedMode == .writeToFile)
        #expect(protectedRequest.mutation == .orientation(expected: 8, new: 1))
        #expect(protectedRequest.requestedMode == .writeToXMPSidecar)
    }

    @Test("Full Screen rotation touches only the shown photo, not the hidden multi-selection")
    @MainActor
    func fullScreenRotationTargetsShownPhoto() async throws {
        let recorder = FieldMutationCallerRecorder()
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) },
            fieldMutationModeResolver: { _, _ in .historyOnly })
        let folder = URL(fileURLWithPath: "/virtual/full-screen-rotation")
        let photos = ["a.jpg", "b.jpg", "c.jpg"].map { folder.appendingPathComponent($0) }
        model.currentFolderURL = folder
        model.images = photos.map { ImageFile(url: $0) }
        model.selectedImageIDs = Set(photos)
        model.lastClickedImageURL = photos[1]
        model.isFullScreen = true

        model.rotateFullScreenImage(clockwise: true)
        await model.waitForPendingFieldMutationWrites()

        let requests = await recorder.captured
        #expect(requests.map(\.imageURL) == [photos[1]])
        #expect(model.images.map(\.exifOrientation) == [1, 6, 1])
    }

    @Test("Failed rapid rotations restore their verified orientation without clearing a pending caption", arguments: [false, true])
    @MainActor
    func browserRotationDefiniteFailure(firstSucceeds: Bool) async throws {
        let recorder = FieldMutationCallerRecorder(pausesFirst: true, failingInvocations: firstSucceeds ? [2] : [1, 2])
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) },
            fieldMutationModeResolver: { _, _ in .historyOnly })
        let folder = URL(fileURLWithPath: "/virtual/rotation-failure")
        let photo = folder.appendingPathComponent("bad.jpg")
        var image = ImageFile(url: photo)
        image.hasPendingMetadataChanges = true
        image.pendingFieldNames = ["Headline"]
        model.currentFolderURL = folder
        model.images = [image]
        model.selectedImageIDs = [photo]
        model.rotateClockwise()
        try await waitForPause(recorder)
        model.rotateCounterclockwise()
        await recorder.resume()
        await model.waitForPendingFieldMutationWrites()
        #expect(model.images.first?.exifOrientation == (firstSucceeds ? 6 : 1))
        #expect(model.images.first?.pendingFieldNames.contains("Headline") == true)
        #expect(model.images.first?.pendingFieldNames.contains("Orientation") == firstSucceeds)
        #expect(model.images.first?.hasPendingMetadataChanges == true)
        #expect(model.errorMessage?.contains("bad.jpg") == true)
    }

    @Test("Browser reloads a durable pending rotation and explicitly writes it without another turn")
    @MainActor
    func browserPendingRotationReloadAndApply() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("BrowserRotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: photo)
        let engine = SwiftExifWriteEngine()
        try await engine.writeFields([.headline: "Original caption"], to: [photo])
        try await engine.writeOrientation(1, to: [photo])
        let sourceBytes = try Data(contentsOf: photo)
        let sidecars = MetadataSidecarService()
        try sidecars.saveSidecar(MetadataSidecar(sourceFile: photo.lastPathComponent,
            pendingChanges: true, metadata: IPTCMetadata(title: "Unwritten caption G"), imageMetadataSnapshot: nil),
            for: photo, in: folder)
        let model = BrowserViewModel(fieldMutationModeResolver: { _, _ in .historyOnly })
        model.loadFolder(url: folder, addToOpenFolders: false)
        await model.waitForFolderLoad()
        let loadedPhoto = try #require(model.images.first?.url)
        #expect(loadedPhoto.resolvingSymlinksInPath().path == photo.resolvingSymlinksInPath().path)
        model.selectedImageIDs = [loadedPhoto]
        try #require(model.selectedImages.count == 1, "Select the model's enumerated URL identity before issuing a rotation")
        model.rotateClockwise()
        model.rotateClockwise()
        await model.waitForPendingFieldMutationWrites()
        #expect(model.errorMessage == nil)
        try #require(model.fieldMutationResults.count == 1, "The final queued rotation must actually reach persistence")
        try #require(model.fieldMutationResults.first?.completed == true)
        let pending = try #require(sidecars.loadSidecar(for: photo, in: folder))
        #expect(pending.orientationDraft?.expectedOrientation == 1)
        #expect(pending.orientationDraft?.targetOrientation == 3)
        #expect(pending.imageMetadataSnapshot == nil)
        #expect(pending.metadata.title == "Unwritten caption G")
        #expect(try Data(contentsOf: photo) == sourceBytes)

        let reloaded = BrowserViewModel(fieldMutationModeResolver: { _, _ in .writeToFileAndXMPSidecar })
        reloaded.loadFolder(url: folder, addToOpenFolders: false)
        await reloaded.waitForFolderLoad()
        let reloadedPhoto = try #require(reloaded.images.first?.url)
        #expect(reloadedPhoto.resolvingSymlinksInPath().path == photo.resolvingSymlinksInPath().path)
        reloaded.selectedImageIDs = [reloadedPhoto]
        try #require(reloaded.selectedImages.count == 1)
        #expect(reloaded.images.first?.exifOrientation == 3)
        #expect(reloaded.hasPendingOrientationInSelection)
        reloaded.applyPendingOrientationToSelection()
        await reloaded.waitForPendingFieldMutationWrites()
        #expect(reloaded.errorMessage == nil)
        try #require(reloaded.fieldMutationResults.count == 1, "Write Pending Rotation must actually reach persistence")
        try #require(reloaded.fieldMutationResults.first?.completed == true)
        #expect(reloaded.images.first?.exifOrientation == 3)
        #expect(!reloaded.hasPendingOrientationInSelection)
        let final = try #require(sidecars.loadSidecar(for: photo, in: folder))
        #expect(final.orientationDraft == nil)
        #expect(final.pendingChanges)
        #expect(final.imageMetadataSnapshot == nil)
        #expect(final.metadata.title == "Unwritten caption G")
        let embedded = try await SwiftExifReadService().readFullMetadata(url: photo)
        #expect(embedded.exifOrientation == 3)
        #expect(embedded.title == "Original caption")
        #expect(XMPSidecarService().loadSidecar(for: photo)?.exifOrientation == 3)
    }

    @Test("Batch rating completion publishes every row and selection without disturbing name order")
    @MainActor
    func batchCompletionUpdatesPresentationSnapshots() async {
        let recorder = FieldMutationCallerRecorder(failingNames: ["photo-20.jpg"])
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) })
        let folder = URL(fileURLWithPath: "/virtual/batch-presentation")
        let urls = (0..<64).map { folder.appendingPathComponent("photo-\($0).jpg") }
        model.currentFolderURL = folder
        model.sortOrder = .name
        model.images = urls.map { url in
            var image = ImageFile(url: url)
            image.starRating = .two
            return image
        }
        model.selectedImageIDs = Set(urls)
        model.batchUpdate {} // Flush the initial folder's coalesced presentation rebuild.
        model.setRating(.five)
        let order = model.sortedImages.map(\.url)
        await model.waitForPendingFieldMutationWrites()
        #expect(model.sortedImages.map(\.url) == order)
        #expect(model.visibleImages.map(\.url) == order)
        #expect(model.selectedImages.count == urls.count)
        for snapshots in [model.images, model.sortedImages, model.visibleImages, model.selectedImages] {
            for image in snapshots {
                #expect(image.starRating == (image.filename == "photo-20.jpg" ? .two : .five))
                if image.filename != "photo-20.jpg" {
                    #expect(image.hasPendingMetadataChanges)
                    #expect(image.pendingFieldNames.contains("Headline"))
                }
            }
        }
        #expect(model.fieldMutationResults.count == urls.count)
    }

    @Test("Rating rollback restores filter membership after an optimistic removal")
    @MainActor
    func ratingRollbackReconcilesMembership() async {
        let recorder = FieldMutationCallerRecorder(failingNames: ["photo.jpg"])
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) })
        let folder = URL(fileURLWithPath: "/virtual/rating-filter")
        let photo = folder.appendingPathComponent("photo.jpg")
        var image = ImageFile(url: photo)
        image.starRating = .five
        model.currentFolderURL = folder
        model.images = [image]
        model.minimumStarRating = .four
        model.selectedImageIDs = [photo]
        model.setRating(.one)
        #expect(model.visibleImages.isEmpty)
        await model.waitForPendingFieldMutationWrites()
        #expect(model.visibleImages.map(\.url) == [photo])
        #expect(model.visibleImages.first?.starRating == .five)
    }

    @Test("Browser preparation failure restores only its optimistic field and reports the photo")
    @MainActor
    func browserFailedFieldIsVisible() async {
        let recorder = FieldMutationCallerRecorder(failingNames: ["bad.jpg"])
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) })
        let folder = URL(fileURLWithPath: "/virtual/field-failure")
        let photo = folder.appendingPathComponent("bad.jpg")
        var image = ImageFile(url: photo)
        image.starRating = .two
        image.colorLabel = .red
        model.currentFolderURL = folder
        model.images = [image]
        model.selectedImageIDs = [photo]
        model.setRating(.five)
        await model.waitForPendingFieldMutationWrites()
        #expect(model.images.first?.starRating == .two)
        #expect(model.images.first?.colorLabel == .red)
        #expect(model.errorMessage?.contains("0 of 1") == true)
        #expect(model.errorMessage?.contains("bad.jpg") == true)
        #expect(model.fieldMutationResults.count == 1)
        #expect(model.fieldMutationResults.first?.completed == false)
    }

    @Test("Two failed rapid ratings restore the last saved value, not the first failed optimistic rating")
    @MainActor
    func browserRapidFailuresRetainVerifiedFallback() async throws {
        let recorder = FieldMutationCallerRecorder(pausesFirst: true, failingNames: ["bad.jpg"])
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) })
        let folder = URL(fileURLWithPath: "/virtual/rapid-failures")
        let photo = folder.appendingPathComponent("bad.jpg")
        var image = ImageFile(url: photo)
        image.starRating = .two
        model.currentFolderURL = folder
        model.images = [image]
        model.selectedImageIDs = [photo]
        model.setRating(.one)
        try await waitForPause(recorder)
        model.setRating(.five)
        #expect(model.images.first?.starRating == .five)
        await recorder.resume()
        await model.waitForPendingFieldMutationWrites()
        #expect(model.images.first?.starRating == .two)
        #expect(model.errorMessage?.contains("Injected destination failure") == true)
    }

    @Test("Browser field completion keeps an unrelated caption's pending marker")
    @MainActor
    func browserFieldCompletionRetainsOtherPendingFields() async {
        let recorder = FieldMutationCallerRecorder()
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) })
        let folder = URL(fileURLWithPath: "/virtual/pending-caption")
        let photo = folder.appendingPathComponent("photo.jpg")
        model.currentFolderURL = folder
        model.images = [ImageFile(url: photo)]
        model.selectedImageIDs = [photo]
        model.setRating(.five)
        await model.waitForPendingFieldMutationWrites()
        #expect(model.images.first?.starRating == .five)
        #expect(model.images.first?.hasPendingMetadataChanges == true)
        #expect(model.images.first?.pendingFieldNames.contains("Headline") == true)
        #expect(model.images.first?.pendingFieldNames.contains("Rating") == false)
    }

    @Test("Partial field feedback identifies verified destinations and uncertain committed JSON")
    func partialFeedbackPreservesActualOutcome() throws {
        let photo = URL(fileURLWithPath: "/virtual/partial/photo.jpg")
        let json = URL(fileURLWithPath: "/virtual/partial/.photo_metadata/photo.jpg.meta.json")
        let result = MetadataFieldMutationWriteResult(requestID: UUID(), imageURL: photo,
            didWriteXMP: true, embeddedWriteMayHaveOccurred: true,
            committedButUnverifiedSidecarURL: json,
            failure: .init(stage: .finalize, message: "Newer metadata was preserved.", kind: .conflict))
        let message = try #require(MetadataFieldMutationFeedback.failureSummary([result]))
        #expect(message.contains("0 of 1"))
        #expect(message.contains("Already written: XMP sidecar"))
        #expect(message.contains("Image metadata may already have changed"))
        #expect(message.contains("saved edits for photo.jpg couldn't be checked"))
        #expect(!message.contains(json.deletingLastPathComponent().path))
    }

    @Test("A Browser conflict never installs its historical prepared draft over newer displayed metadata")
    @MainActor
    func browserConflictPreservesNewerDisplayedField() async throws {
        let sequence = BrowserFieldConflictSequence(.conflict)
        let model = BrowserViewModel(fieldMutationWriter: { await sequence.write($0) })
        let folder = URL(fileURLWithPath: "/virtual/conflict-current")
        let photo = folder.appendingPathComponent("photo.jpg")
        model.currentFolderURL = folder
        model.images = [ImageFile(url: photo)]
        model.selectedImageIDs = [photo]
        model.setRating(.one)
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await sequence.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        let paused = await sequence.isPaused
        try #require(paused)
        // A separate saved-state refresh has already shown current C while A was awaiting CAS.
        model.images[0].starRating = .three
        await sequence.resume()
        await model.waitForPendingFieldMutationWrites()
        #expect(model.images[0].starRating == .three)
        #expect(model.images[0].hasPendingMetadataChanges)
        #expect(model.errorMessage?.contains("Reload this photo") == true)
    }

    @Test("A later precommit failure retains an earlier superseded write's uncertain outcome", arguments: [false, true])
    @MainActor
    func browserRapidFailureRetainsEarlierUncertainty(jsonUncertain: Bool) async throws {
        let sequence = BrowserFieldConflictSequence(jsonUncertain ? .uncertainJSON : .uncertainImage)
        let model = BrowserViewModel(fieldMutationWriter: { await sequence.write($0) })
        let folder = URL(fileURLWithPath: "/virtual/uncertain-chain")
        let photo = folder.appendingPathComponent("photo.jpg")
        var image = ImageFile(url: photo)
        image.starRating = .two
        model.currentFolderURL = folder
        model.images = [image]
        model.selectedImageIDs = [photo]
        model.setRating(.one)
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await sequence.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        let paused = await sequence.isPaused
        try #require(paused)
        model.setRating(.five)
        await sequence.resume()
        await model.waitForPendingFieldMutationWrites()
        #expect(model.images[0].starRating == .five)
        #expect(model.images[0].hasPendingMetadataChanges)
        #expect(model.fieldMutationResults.count == 2)
        #expect(model.errorMessage?.contains(jsonUncertain ? "Earlier JSON write" : "Earlier image write") == true)
        #expect(model.errorMessage?.contains("Later request failed before commit") == true)
    }

    @Test("Face names publish partial results and always release the caller's busy state", arguments: [false, true])
    @MainActor
    func faceNamesReportFailures(allFail: Bool) async {
        let folder = URL(fileURLWithPath: "/virtual/person-mutations")
        let urls = [folder.appendingPathComponent("bad.jpg"), folder.appendingPathComponent("good.jpg")]
        let recorder = FieldMutationCallerRecorder(failingNames: allFail ? ["bad.jpg", "good.jpg"] : ["bad.jpg"])
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            fieldMutationWriter: { await recorder.write($0) }, fieldMutationModeResolver: { _, _ in .writeToFileAndXMPSidecar })
        model.faceData = faceData(folder: folder, urls: urls, name: "Lovelace, Ada")
        let counter = FieldMutationNotificationCounter()
        let observer = NotificationCenter.default.addObserver(forName: .faceMetadataDidChange, object: nil, queue: nil) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        var completions = 0
        model.applyAllNamesToMetadata(images: urls.map { ImageFile(url: $0) }, folderURL: folder) { completions += 1 }
        await model.waitForPendingFieldMutationWrites()
        #expect(completions == 1)
        #expect(model.fieldMutationResults.count == 2)
        #expect(model.fieldMutationResults.filter(\.completed).count == (allFail ? 0 : 1))
        #expect(model.errorMessage?.contains(allFail ? "0 of 2" : "1 of 2") == true)
        #expect(model.errorMessage?.contains("bad.jpg") == true)
        #expect(counter.value == (allFail ? 0 : 1))
        let requests = await recorder.captured
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.requestedMode == .writeToFileAndXMPSidecar)
            // One face group is one person: a Photo Mechanic "Last, First" name stays intact.
            if case .addPersons(let names) = request.mutation { #expect(names == ["Lovelace, Ada"]) } else { Issue.record("Captured person names changed") }
        }
    }

    @Test("Face Apply All accepts the same decoded folder with either directory URL hint", arguments: [false, true])
    @MainActor
    func faceApplyAllMatchesDirectoryIdentity(hasDirectoryHint: Bool) async throws {
        let decodedFolder = try #require(URL(string: "file:///virtual/face-directory-identity"))
        let browserFolder = URL(fileURLWithPath: decodedFolder.path, isDirectory: hasDirectoryHint)
        let savedPhoto = decodedFolder.appendingPathComponent("photo.png")
        let browserPhoto = browserFolder.appendingPathComponent("photo.png")
        let recorder = FieldMutationCallerRecorder()
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            fieldMutationWriter: { await recorder.write($0) })
        model.faceData = faceData(folder: decodedFolder, urls: [savedPhoto], name: "Saved group name")
        var completions = 0
        model.applyAllNamesToMetadata(images: [ImageFile(url: browserPhoto)], folderURL: browserFolder) { completions += 1 }
        await model.waitForPendingFieldMutationWrites()
        let requests = await recorder.captured
        #expect(requests.count == 1)
        #expect(requests.first?.folderURL == browserFolder)
        #expect(model.fieldMutationResults.count == 1)
        #expect(model.fieldMutationResults.first?.completed == true)
        #expect(model.errorMessage == nil)
        #expect(completions == 1)
    }

    @Test("Face completion from a previous folder does not publish into its replacement")
    @MainActor
    func faceFolderSwitchPreservesCapturedWrite() async throws {
        let folder = URL(fileURLWithPath: "/virtual/old-faces")
        let photo = folder.appendingPathComponent("face.jpg")
        let recorder = FieldMutationCallerRecorder(pausesFirst: true)
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            fieldMutationWriter: { await recorder.write($0) })
        model.faceData = faceData(folder: folder, urls: [photo], name: "Captured name")
        var completions = 0
        model.applyAllNamesToMetadata(images: [ImageFile(url: photo)], folderURL: folder) { completions += 1 }
        try await waitForPause(recorder)
        let replacement = URL(fileURLWithPath: "/virtual/new-faces")
        model.faceData = faceData(folder: replacement, urls: [], name: "Other")
        await recorder.resume()
        await model.waitForPendingFieldMutationWrites()
        #expect(completions == 1)
        #expect(model.faceData?.folderURL == replacement)
        #expect(model.fieldMutationResults.isEmpty)
        let request = try #require(await recorder.captured.first)
        #expect(request.folderURL == folder)
        if case .addPersons(let names) = request.mutation { #expect(names == ["Captured name"]) } else { Issue.record("Name was not captured") }
    }

    @Test("A single face group named \"Last, First\" is written as one person")
    @MainActor
    func faceGroupNameWithCommaIsOnePerson() async throws {
        // Single-group writes resolve content-credential status from the file, so it must exist.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("comma-name-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("face.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: photo)
        let recorder = FieldMutationCallerRecorder()
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            fieldMutationWriter: { await recorder.write($0) })
        let data = faceData(folder: folder, urls: [photo], name: "  Doe, Jane ")
        model.faceData = data
        model.applyNameToMetadata(groupID: try #require(data.groups.first?.id))
        await model.waitForPendingFieldMutationWrites()
        let request = try #require(await recorder.captured.first)
        if case .addPersons(let names) = request.mutation { #expect(names == ["Doe, Jane"]) } else { Issue.record("No person mutation") }
    }

    @Test("Apply All stays available for named groups from a cancelled or partially failed scan")
    @MainActor
    func applyAllAvailableAfterIncompleteScan() async throws {
        let folder = URL(fileURLWithPath: "/virtual/incomplete-scan")
        let photo = folder.appendingPathComponent("face.jpg")
        let recorder = FieldMutationCallerRecorder()
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            fieldMutationWriter: { await recorder.write($0) })
        #expect(!model.canApplyAllNames)
        var data = faceData(folder: folder, urls: [photo], name: "Partial name")
        data.scanComplete = false
        model.faceData = data
        #expect(!model.scanComplete)
        #expect(model.canApplyAllNames)
        model.applyAllNamesToMetadata(images: [ImageFile(url: photo)], folderURL: folder)
        await model.waitForPendingFieldMutationWrites()
        #expect(await recorder.captured.count == 1)

        var unnamed = faceData(folder: folder, urls: [photo], name: "x")
        unnamed.groups[0].name = nil
        model.faceData = unnamed
        #expect(!model.canApplyAllNames)
    }

    @Test("Confirmed jersey players enable Apply All in the Sports lens without any named face group")
    @MainActor
    func confirmedPlayersEnableApplyInSportsLens() async throws {
        let folder = URL(fileURLWithPath: "/virtual/sports-apply")
        let photo = folder.appendingPathComponent("match.jpg")
        let recorder = FieldMutationCallerRecorder()
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            fieldMutationWriter: { await recorder.write($0) })
        var data = faceData(folder: folder, urls: [photo], name: "x")
        data.groups[0].name = nil
        data.numberDetections = [NumberDetection(imageURL: photo, number: 10, numberConfidence: 0.9,
            boundingBox: .zero, resolvedPlayerName: "Hansen, Ola", claimState: .confirmed)]
        model.faceData = data
        #expect(model.activeLens == .face)
        #expect(!model.canApplyAllNames)
        data.activeLens = .sports
        model.faceData = data
        try #require(model.activeLens == .sports)
        #expect(model.canApplyAllNames)
        model.applyAllNamesToMetadata(images: [ImageFile(url: photo)], folderURL: folder)
        await model.waitForPendingFieldMutationWrites()
        let request = try #require(await recorder.captured.first)
        if case .addPersons(let names) = request.mutation { #expect(names == ["Hansen, Ola"]) } else { Issue.record("No person mutation") }
    }

    @Test("A write failure is still reported when face data is edited while the write runs")
    @MainActor
    func faceWriteFailureSurvivesMidWriteFaceEdit() async throws {
        let folder = URL(fileURLWithPath: "/virtual/mid-write-edit")
        let photo = folder.appendingPathComponent("bad.jpg")
        let recorder = FieldMutationCallerRecorder(pausesFirst: true, failingNames: ["bad.jpg"])
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            fieldMutationWriter: { await recorder.write($0) })
        var data = faceData(folder: folder, urls: [photo], name: "First name")
        model.faceData = data
        model.applyAllNamesToMetadata(images: [ImageFile(url: photo)], folderURL: folder)
        try await waitForPause(recorder)
        data.groups[0].name = "Renamed meanwhile"
        model.faceData = data
        await recorder.resume()
        await model.waitForPendingFieldMutationWrites()
        #expect(model.fieldMutationResults.count == 1)
        #expect(model.errorMessage?.contains("bad.jpg") == true)
    }

    @Test("Clearing the displayed folder drops the previous folder's faces")
    @MainActor
    func clearDisplayedFolderDropsFaces() {
        let folder = URL(fileURLWithPath: "/virtual/previous-faces")
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.faceData = faceData(folder: folder, urls: [folder.appendingPathComponent("a.jpg")], name: "Someone")
        #expect(!model.namedGroups.isEmpty)
        model.clearDisplayedFolder()
        #expect(model.faceData == nil)
        #expect(model.namedGroups.isEmpty)
        #expect(model.displayedFolderURL == nil)
        #expect(!model.canApplyAllNames)
    }

    // MARK: - Browser main-thread performance invariants

    @Test("The images cascade still detects same-count identity changes and publishes in-place edits")
    @MainActor
    func imagesCascadeTracksIdentityWithoutOldValue() {
        let model = BrowserViewModel()
        let folder = URL(fileURLWithPath: "/virtual/cascade-identity")
        let (a, b, c, d) = (folder.appendingPathComponent("a.jpg"), folder.appendingPathComponent("b.jpg"),
                            folder.appendingPathComponent("c.jpg"), folder.appendingPathComponent("d.jpg"))
        model.currentFolderURL = folder
        model.images = [a, b, c].map { ImageFile(url: $0) }
        model.batchUpdate {}
        #expect(Set(model.sortedImages.map(\.url)) == [a, b, c])
        #expect(model.imageCount == 3 && model.hasImages)

        // Same count, different identity (rename/replacement) must force a full re-sort;
        // reusing the previous sorted order would silently drop the new row.
        var replaced = model.images
        replaced[2] = ImageFile(url: d)
        model.images = replaced
        model.batchUpdate {}
        #expect(Set(model.sortedImages.map(\.url)) == [a, b, d])
        #expect(Set(model.visibleImages.map(\.url)) == [a, b, d])
        #expect(model.urlToImageIndex == [a: 0, b: 1, d: 2])

        // In-place element edits keep identity and reach the derived snapshots.
        model.images[0].starRating = .three
        model.batchUpdate {}
        #expect(model.sortedImages.first { $0.url == a }?.starRating == .three)
        #expect(model.visibleImages.first { $0.url == a }?.starRating == .three)

        // Order-only change on the same URLs is still an identity change.
        model.images = model.images.reversed()
        model.batchUpdate {}
        #expect(model.urlToImageIndex == [d: 0, b: 1, a: 2])
        #expect(Set(model.sortedImages.map(\.url)) == [a, b, d])

        model.images = []
        model.batchUpdate {}
        #expect(model.imageCount == 0 && !model.hasImages && model.sortedImages.isEmpty)
    }

    @Test("Full screen and count readers observe only their own row, not every row edit")
    @MainActor
    func fullScreenImageIsANarrowRead() {
        let model = BrowserViewModel()
        let folder = URL(fileURLWithPath: "/virtual/full-screen-narrow")
        let (a, b) = (folder.appendingPathComponent("a.jpg"), folder.appendingPathComponent("b.jpg"))
        model.currentFolderURL = folder
        model.images = [a, b].map { ImageFile(url: $0) }
        model.batchUpdate {}
        model.selectedImageIDs = [a]
        model.lastClickedImageURL = a
        model.isFullScreen = true
        #expect(model.fullScreenImage?.url == a)

        let fullScreenChanges = FieldMutationNotificationCounter()
        let countChanges = FieldMutationNotificationCounter()
        withObservationTracking { _ = model.fullScreenImage } onChange: { fullScreenChanges.increment() }
        withObservationTracking { _ = model.hasImages } onChange: { countChanges.increment() }
        model.images[1].starRating = .five
        #expect(fullScreenChanges.value == 0)
        #expect(countChanges.value == 0)
        #expect(model.fullScreenImage?.starRating == StarRating.none)

        model.images[0].exifOrientation = 6
        #expect(fullScreenChanges.value == 1)
        #expect(model.fullScreenImage?.exifOrientation == 6)

        // Active row outside the selection falls back to the first selected row, as before.
        model.selectedImageIDs = [b]
        #expect(model.fullScreenImage?.url == b)
        model.lastClickedImageURL = b
        #expect(model.fullScreenImage?.starRating == .five)
        model.isFullScreen = false
    }

    @Test("Pending-status refresh updates only its rows in place and keeps the order")
    @MainActor
    func pendingStatusRefreshIsInPlace() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["c.jpg", "a.jpg", "b.jpg"].map { folder.appendingPathComponent($0) }
        for url in urls { try Data("x".utf8).write(to: url) }
        _ = try MetadataSidecarService().saveSidecar(MetadataSidecar(sourceFile: "a.jpg", pendingChanges: true,
            metadata: IPTCMetadata(title: "New headline"), imageMetadataSnapshot: IPTCMetadata(title: "Old"),
            history: []), for: urls[1], in: folder)

        let model = BrowserViewModel()
        model.currentFolderURL = folder
        model.images = urls.map { ImageFile(url: $0) }
        model.batchUpdate {}
        let order = model.sortedImages.map(\.url)
        let index = model.urlToImageIndex

        model.refreshPendingStatusBatch(for: [urls[1], urls[2]])
        let deadline = ContinuousClock.now + .seconds(5)
        while !(model.visibleImages.first { $0.url == urls[1] }?.hasPendingMetadataChanges ?? false),
              ContinuousClock.now < deadline { await Task.yield() }

        for snapshot in [model.images, model.sortedImages, model.visibleImages] {
            let pending = try #require(snapshot.first { $0.url == urls[1] })
            #expect(pending.hasPendingMetadataChanges)
            #expect(!pending.pendingFieldNames.isEmpty)
            #expect(snapshot.first { $0.url == urls[2] }?.hasPendingMetadataChanges == false)
        }
        #expect(model.sortedImages.map(\.url) == order)
        #expect(model.urlToImageIndex == index)
    }

    @Test("Overlapping pending-status refreshes coalesce and never drop queued photos")
    @MainActor
    func pendingStatusRefreshesCoalesce() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["a.jpg", "b.jpg", "c.jpg"].map { folder.appendingPathComponent($0) }
        for url in urls { try Data("x".utf8).write(to: url) }
        let service = MetadataSidecarService()
        let model = BrowserViewModel()
        model.currentFolderURL = folder
        model.images = urls.map { ImageFile(url: $0) }
        model.batchUpdate {}

        func markPending(_ index: Int) throws {
            _ = try service.saveSidecar(MetadataSidecar(sourceFile: urls[index].lastPathComponent,
                pendingChanges: true, metadata: IPTCMetadata(title: "New \(index)"),
                imageMetadataSnapshot: IPTCMetadata(title: "Old"), history: []), for: urls[index], in: folder)
        }
        func settle(until condition: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(10)
            while (!condition() || model.isPendingStatusRefreshInFlight), ContinuousClock.now < deadline {
                await Task.yield()
            }
        }
        func isPending(_ index: Int) -> Bool {
            model.images.first { $0.url == urls[index] }?.hasPendingMetadataChanges == true
        }

        // A burst of whole-folder requests (one per save) collapses into a single read.
        try markPending(0)
        for _ in 0..<8 { model.refreshPendingStatus() }
        await settle { isPending(0) }
        #expect(isPending(0))
        #expect(model.pendingStatusFullRefreshCount == 1)

        // Requests landing while a pass is in flight are served by exactly one follow-up.
        model.refreshPendingStatus()
        #expect(model.isPendingStatusRefreshInFlight)
        try markPending(1)
        for _ in 0..<5 { model.refreshPendingStatus() }
        await settle { isPending(1) }
        #expect(isPending(1))
        #expect(model.pendingStatusFullRefreshCount == 2)

        // Successive targeted refreshes for different photos are both applied: a later
        // batch no longer cancels an earlier in-flight one.
        let fullCount = model.pendingStatusFullRefreshCount
        try markPending(2)
        try service.deleteSidecar(for: urls[0], in: folder)
        model.refreshPendingStatusBatch(for: [urls[2]])
        for _ in 0..<3 { await Task.yield() }
        model.refreshPendingStatusBatch(for: [urls[0]])
        await settle { isPending(2) && !isPending(0) }
        #expect(isPending(2))
        #expect(!isPending(0))
        #expect(model.pendingStatusFullRefreshCount == fullCount)
    }

    @Test("Sidecar writes are journaled after they land and reported only for written photos")
    func sidecarWriteJournalReportsLateWrites() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = folder.appendingPathComponent("journal-\(UUID().uuidString).jpg")
        let untouched = folder.appendingPathComponent("journal-\(UUID().uuidString).jpg")
        let journal = MetadataSidecarWriteJournal.shared
        let service = MetadataSidecarService()

        let beforeSave = journal.generation
        try service.saveSidecar(MetadataSidecar(sourceFile: written.lastPathComponent, pendingChanges: true,
            metadata: IPTCMetadata(title: "New"), imageMetadataSnapshot: IPTCMetadata(title: "Old"),
            history: []), for: written, in: folder)
        #expect(journal.urlsWritten(since: beforeSave, among: [written, untouched]) == [written])

        let beforeDelete = journal.generation
        #expect(journal.urlsWritten(since: beforeDelete, among: [written]).isEmpty)
        try service.deleteSidecar(for: written, in: folder)
        #expect(journal.urlsWritten(since: beforeDelete, among: [written, untouched]) == [written])
    }

    @Test("An authoritative batch read yields to sidecars written after its listing and to pending rows")
    @MainActor
    func authoritativeBatchSidecarsYieldToLateWrites() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("late.jpg")
        try Data("x".utf8).write(to: url)
        // A historyOnly-style pending draft (rating 5) that landed after the batch's listing.
        var draft = IPTCMetadata()
        draft.rating = 5
        _ = try MetadataSidecarService().saveSidecar(MetadataSidecar(sourceFile: "late.jpg",
            pendingChanges: true, metadata: draft, imageMetadataSnapshot: IPTCMetadata(), history: []),
            for: url, in: folder)

        let model = BrowserViewModel()
        model.currentFolderURL = folder
        let embedded: [[String: Any]] = [[MetadataDictKey.sourceFile: url.path, MetadataDictKey.rating: 0]]
        func apply(to row: ImageFile, stale: Set<URL>) -> ImageFile {
            var images = [row]
            model.applyBatchMetadataResults(embedded, to: &images, localIndex: [url: 0],
                cachedSidecars: [:], sidecarsAreAuthoritative: true, staleSidecarURLs: stale,
                nativeHDRByURL: [:])
            return images[0]
        }

        // A clean row the batch's read covered: absent means none, no fallback read.
        #expect(apply(to: ImageFile(url: url), stale: []).starRating == StarRating.none)
        // Written after the listing (journaled): re-read from disk at apply time.
        #expect(apply(to: ImageFile(url: url), stale: [url]).starRating == .five)
        // The row already shows pending state the read missed: re-read from disk.
        var pendingRow = ImageFile(url: url)
        pendingRow.hasPendingMetadataChanges = true
        #expect(apply(to: pendingRow, stale: []).starRating == .five)
    }

    @Test("A folder refresh keeps unchanged rows' metadata and derived search text")
    @MainActor
    func folderRefreshReusesUnchangedRows() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a.jpg", "b.jpg"] { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        // Use the scanner's spelling of the paths (/private/var vs /var) so rows match by URL.
        let listed = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let a = try #require(listed.first { $0.lastPathComponent == "a.jpg" })
        let b = try #require(listed.first { $0.lastPathComponent == "b.jpg" })
        let c = a.deletingLastPathComponent().appendingPathComponent("c.jpg")
        let model = BrowserViewModel(refreshSidecarLoader: { _ in [:] })
        model.currentFolderURL = folder
        model.images = [a, b].map { url in
            var image = ImageFile(url: url)
            image.starRating = .four
            image.metadata = IPTCMetadata(title: "Kept Caption")
            image.keywords = ["Alpha"]
            return image
        }
        model.batchUpdate {}
        try Data("x".utf8).write(to: c)

        await withCheckedContinuation { continuation in
            let started = model.refreshCurrentFolderIfNeeded { _ in continuation.resume() }
            #expect(started)
            if !started { continuation.resume() }
        }
        #expect(Set(model.images.map(\.url)) == [a, b, c])
        for url in [a, b] {
            let row = try #require(model.images.first { $0.url == url })
            #expect(row.starRating == .four)
            #expect(row.metadata?.title == "Kept Caption")
            #expect(row.metadataSearchLowercased.contains("kept caption"))
            #expect(row.keywordsLowercased == ["alpha"])
        }
    }

    @Test("Browser field writes report in-flight state until the queue drains")
    @MainActor
    func fieldWritesReportInFlight() async throws {
        let recorder = FieldMutationCallerRecorder(pausesFirst: true)
        let model = BrowserViewModel(fieldMutationWriter: { await recorder.write($0) })
        let folder = URL(fileURLWithPath: "/virtual/in-flight")
        let photo = folder.appendingPathComponent("photo.jpg")
        model.currentFolderURL = folder
        model.images = [ImageFile(url: photo)]
        model.selectedImageIDs = [photo]
        #expect(!model.hasFieldMutationWritesInFlight)
        model.setRating(.three)
        model.setLabel(.red)
        #expect(model.hasFieldMutationWritesInFlight)
        try await waitForPause(recorder)
        await recorder.resume()
        await model.waitForPendingFieldMutationWrites()
        #expect(!model.hasFieldMutationWritesInFlight)
    }

    @Test("Key-index sorts reproduce the original comparator orders, ties included")
    @MainActor
    func sortHelpersMatchOriginalComparators() {
        let folder = URL(fileURLWithPath: "/virtual/sort-identity")
        let names = ["img10.jpg", "IMG2.jpg", "img2.JPG", "a.cr3", "b.jpg", "Ä.jpg", "img1.jpg",
                     "A.CR3", "z.tif", "img02.jpg", "photo.heic", "Photo.HEIC", "b.cr3"]
        let ratings: [StarRating] = [.two, .five, .two, .none, .five, .one, .two, .none, .three, .two, .five, .one, .two]
        let rows = zip(names, ratings).map { name, rating in
            var image = ImageFile(url: folder.appendingPathComponent(name))
            image.starRating = rating
            return image
        }
        for input in [rows, rows.reversed(), rows.shuffled()] {
            let byName = input.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
            let permutation = BrowserViewModel.filenameSortPermutation(input)
            #expect(permutation.map { input[$0].url } == byName.map(\.url))

            let byRating = input.sorted { $0.starRating.rawValue > $1.starRating.rawValue }
            #expect(BrowserViewModel.reordered(input, by: \.starRating.rawValue, >).map(\.url) == byRating.map(\.url))

            let byType = input.sorted {
                let ext0 = $0.url.pathExtension.lowercased()
                let ext1 = $1.url.pathExtension.lowercased()
                if ext0 != ext1 { return ext0.localizedStandardCompare(ext1) == .orderedAscending }
                return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
            var rank = [Int](repeating: 0, count: input.count)
            for (position, index) in permutation.enumerated() { rank[index] = position }
            #expect(BrowserViewModel.fileTypeSorted(input, nameRank: rank).map(\.url) == byType.map(\.url))
        }
    }

    @MainActor
    private func waitForPause(_ recorder: FieldMutationCallerRecorder) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await recorder.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        let paused = await recorder.isPaused
        try #require(paused)
    }

    private func faceData(folder: URL, urls: [URL], name: String) -> FolderFaceData {
        let groupID = UUID()
        let faces = urls.map { DetectedFace(id: UUID(), imageURL: $0, faceRect: .zero,
            featurePrintData: Data(), groupID: groupID, detectedAt: Date()) }
        let group = FaceGroup(id: groupID, name: name, representativeFaceID: faces.first?.id ?? UUID(),
            faceIDs: faces.map(\.id))
        return FolderFaceData(folderURL: folder, faces: faces, groups: [group], lastScanDate: Date(), scanComplete: true)
    }
}

private actor PersonShownScanGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Face edits after Apply must never leave a wrong name in Person Shown: only the exact name the
/// app applied is replaced or removed, through the field-mutation write path.
@Suite("Person Shown corrections after face edits", .serialized)
struct PersonShownCorrectionTests {
    private struct GroupSpec {
        var name: String?
        var applied: String?
        var photos: [URL]
        var knownPersonID: UUID? = nil
    }

    private func makeFolder(_ label: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("person-shown-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeData(folder: URL, _ specs: [GroupSpec]) -> FolderFaceData {
        var faces: [DetectedFace] = []
        var groups: [FaceGroup] = []
        for spec in specs {
            let groupID = UUID()
            let groupFaces = spec.photos.map { DetectedFace(id: UUID(), imageURL: $0, faceRect: .zero,
                featurePrintData: Data(), groupID: groupID, detectedAt: Date(timeIntervalSince1970: 1)) }
            faces += groupFaces
            groups.append(FaceGroup(id: groupID, name: spec.name, representativeFaceID: groupFaces.first?.id ?? UUID(),
                faceIDs: groupFaces.map(\.id), knownPersonID: spec.knownPersonID,
                appliedPersonShownNames: spec.applied.map { name in
                    Dictionary(spec.photos.map { ($0.lastPathComponent, name) }, uniquingKeysWith: { first, _ in first })
                }))
        }
        return FolderFaceData(folderURL: folder, faces: faces, groups: groups,
            lastScanDate: Date(timeIntervalSince1970: 1), scanComplete: true)
    }

    @MainActor
    private func makeModel(_ data: FolderFaceData, recorder: FieldMutationCallerRecorder,
                           scanDetector: (@Sendable (URL, FaceDetectionService.DetectionConfig) async throws -> FaceDetectionService.DetectionResult)? = nil
    ) throws -> FaceRecognitionViewModel {
        try FaceDataStorageService().saveFaceData(data)
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            faceModelAvailability: .available, scanDetector: scanDetector,
            fieldMutationWriter: { await recorder.write($0) },
            fieldMutationModeResolver: { _, isRaw in isRaw ? .writeToXMPSidecar : .writeToFileAndXMPSidecar })
        model.faceData = data
        return model
    }

    @Test("Exact replacement never touches manual names, keeps comma names whole and is not diacritic-folded")
    func replacementSemantics() {
        let names = ["Store", "Hansen, Ola", "Manual Entry"]
        func replace(_ replacements: [MetadataPersonReplacement], in existing: [String]) -> [String] {
            MetadataPhysicalFieldMutation.replace(replacements, in: existing)
        }
        #expect(replace([.init(old: "Store", new: "Støre")], in: names) == ["Støre", "Hansen, Ola", "Manual Entry"])
        // A photo without the applied name (removed or typed differently by hand) is left alone.
        #expect(replace([.init(old: "Ann", new: "Anne")], in: names) == names)
        #expect(replace([.init(old: "store", new: "Anything")], in: names) == names)
        #expect(replace([.init(old: "Hansen, Ola", new: nil)], in: names) == ["Store", "Manual Entry"])
        #expect(replace([.init(old: "Store", new: "Støre", keepsOld: true)], in: names)
            == ["Store", "Støre", "Hansen, Ola", "Manual Entry"])
        #expect(replace([.init(old: nil, new: "Støre")], in: ["Store"]) == ["Store", "Støre"])
        #expect(replace([.init(old: "Store", new: "Hansen, Ola")], in: names) == ["Hansen, Ola", "Manual Entry"])
        // Sequential corrections compose (Store → Støre → Stoere).
        #expect(replace([.init(old: "Store", new: "Støre"), .init(old: "Støre", new: "Stoere")], in: names)
            == ["Stoere", "Hansen, Ola", "Manual Entry"])
    }

    @Test("Renaming an applied group offers an exact replacement; RAW photos are written to the XMP sidecar")
    @MainActor
    func renameAppliedGroup() async throws {
        let folder = try makeFolder("rename")
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpegA = folder.appendingPathComponent("a.jpg")
        let jpegB = folder.appendingPathComponent("b.jpg")
        let raw = folder.appendingPathComponent("c.NEF")
        let data = makeData(folder: folder, [GroupSpec(name: "Store", applied: "Store", photos: [jpegA, jpegB, raw])])
        let recorder = FieldMutationCallerRecorder()
        let model = try makeModel(data, recorder: recorder)
        let groupID = data.groups[0].id

        model.nameGroup(groupID, name: "Støre")
        let proposal = try #require(model.pendingPersonShownUpdate)
        #expect(proposal.photoCount == 3)
        #expect(proposal.summary.contains("Replace “Store” with “Støre”"))
        #expect(await recorder.captured.isEmpty)

        model.confirmPersonShownUpdate(knownC2PA: [jpegA: false, jpegB: false, raw: false])
        await model.waitForPendingFieldMutationWrites()
        let requests = await recorder.captured
        #expect(requests.count == 3)
        for request in requests {
            #expect(request.mutation == .replacePersons([.init(old: "Store", new: "Støre")]))
            #expect(request.requestedMode == (request.imageURL == raw ? .writeToXMPSidecar : .writeToFileAndXMPSidecar))
        }
        let written = ["a.jpg": "Støre", "b.jpg": "Støre", "c.NEF": "Støre"]
        #expect(model.faceData?.groups.first?.appliedPersonShownNames == written)
        #expect(model.pendingPersonShownUpdate == nil)
        await model.waitForCurrentFaceDataPersistence()
        #expect(FaceDataStorageService().loadFaceData(for: folder)?.groups.first?.appliedPersonShownNames == written)
    }

    @Test("Declining leaves photos and the applied name unchanged; unapplied groups never prompt")
    @MainActor
    func declineAndUnapplied() async throws {
        let folder = try makeFolder("decline")
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("a.jpg")
        let other = folder.appendingPathComponent("b.jpg")
        let data = makeData(folder: folder, [GroupSpec(name: "Store", applied: "Store", photos: [photo]),
                                             GroupSpec(name: "Typed", applied: nil, photos: [other])])
        let recorder = FieldMutationCallerRecorder()
        let model = try makeModel(data, recorder: recorder)
        model.nameGroup(data.groups[0].id, name: "Støre")
        #expect(model.pendingPersonShownUpdate != nil)
        model.declinePersonShownUpdate()
        await model.waitForPendingFieldMutationWrites()
        #expect(await recorder.captured.isEmpty)
        #expect(model.faceData?.groups.first?.appliedPersonShownNames == ["a.jpg": "Store"])
        // Renaming a never-applied group has nothing of ours to correct.
        model.nameGroup(data.groups[1].id, name: "Typed Again")
        #expect(model.pendingPersonShownUpdate == nil)
        await model.waitForCurrentFaceDataPersistence()
    }

    @Test("An unanswered rename offer is re-offered after a relaunch; a declined one only after the next rename")
    @MainActor
    func unansweredOfferSurvivesRelaunch() async throws {
        let folder = try makeFolder("reoffer")
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.jpg")
        let b = folder.appendingPathComponent("b.NEF")
        let other = folder.appendingPathComponent("c.jpg")
        let data = makeData(folder: folder, [GroupSpec(name: "Store", applied: "Store", photos: [a, b]),
                                             GroupSpec(name: "Ola", applied: "Ola", photos: [other])])
        let groupID = data.groups[0].id
        let recorder = FieldMutationCallerRecorder()

        // Session 1: rename, then quit with the prompt still open.
        let first = try makeModel(data, recorder: recorder)
        first.nameGroup(groupID, name: "Støre")
        #expect(first.pendingPersonShownUpdate?.isReoffer == false)
        await first.waitForCurrentFaceDataPersistence()

        func relaunch() async throws -> FaceRecognitionViewModel {
            let model = FaceRecognitionViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
                faceModelAvailability: .available, fieldMutationWriter: { await recorder.write($0) },
                fieldMutationModeResolver: { _, isRaw in isRaw ? .writeToXMPSidecar : .writeToFileAndXMPSidecar })
            model.loadFaceData(for: folder, cleanupPolicy: .never)
            await model.waitForCurrentFaceDataLoad()
            return model
        }

        // Session 2: the same correction is offered again, for exactly the photos still wrong.
        let second = try await relaunch()
        let reoffer = try #require(second.pendingPersonShownUpdate)
        #expect(reoffer.isReoffer)
        #expect(reoffer.replacementsByURL.keys.map(\.lastPathComponent).sorted() == ["a.jpg", "b.NEF"])
        #expect(reoffer.replacementsByURL.values.allSatisfy { $0 == [.init(old: "Store", new: "Støre")] })
        second.declinePersonShownUpdate()
        await second.waitForCurrentFaceDataPersistence()
        #expect(await recorder.captured.isEmpty)
        #expect(FaceDataStorageService().loadFaceData(for: folder)?.groups.first { $0.id == groupID }?
            .declinedPersonShownName == "Støre")

        // Session 3: a real decline is not re-offered; renaming again offers from what the
        // photos carry ("Store"), and an unanswered offer then comes back once more.
        let third = try await relaunch()
        #expect(third.pendingPersonShownUpdate == nil)
        third.nameGroup(groupID, name: "Stoere")
        let renamed = try #require(third.pendingPersonShownUpdate)
        #expect(renamed.summary == "Replace “Store” with “Stoere”")
        await third.waitForCurrentFaceDataPersistence()
        let fourth = try await relaunch()
        #expect(fourth.pendingPersonShownUpdate?.summary == "Replace “Store” with “Stoere”")

        // Accepting resolves it for good.
        fourth.confirmPersonShownUpdate(knownC2PA: [a: false, b: false])
        await fourth.waitForPendingFieldMutationWrites()
        await fourth.waitForCurrentFaceDataPersistence()
        #expect(await recorder.captured.count == 2)
        #expect(try await relaunch().pendingPersonShownUpdate == nil)
    }

    @Test("Moving a face removes the old name only when no face of that group remains; the target's applied name is added")
    @MainActor
    func moveBetweenGroups() async throws {
        let folder = try makeFolder("move")
        defer { try? FileManager.default.removeItem(at: folder) }
        let p1 = folder.appendingPathComponent("p1.jpg")
        let p2 = folder.appendingPathComponent("p2.jpg")
        let p3 = folder.appendingPathComponent("p3.jpg")
        let data = makeData(folder: folder, [
            GroupSpec(name: "Ann", applied: "Ann", photos: [p1, p2, p2]),
            GroupSpec(name: "Bob", applied: "Bob", photos: [p3]),
            GroupSpec(name: "Cy", applied: nil, photos: [p3]),
        ])
        let ann = data.groups[0], bob = data.groups[1], cy = data.groups[2]
        let recorder = FieldMutationCallerRecorder()
        let model = try makeModel(data, recorder: recorder)

        model.moveFace(ann.faceIDs[0], toGroup: bob.id)
        var proposal = try #require(model.pendingPersonShownUpdate)
        #expect(proposal.replacementsByURL == [p1: [.init(old: "Ann", new: nil), .init(old: nil, new: "Bob")]])
        model.declinePersonShownUpdate()

        // Another Ann face is still in p2: Ann stays, Bob is added.
        model.moveFace(ann.faceIDs[1], toGroup: bob.id)
        proposal = try #require(model.pendingPersonShownUpdate)
        #expect(proposal.replacementsByURL == [p2: [.init(old: nil, new: "Bob")]])
        model.declinePersonShownUpdate()

        // The last Ann face in p2 moves to a never-applied group: only the removal is offered.
        model.moveFace(ann.faceIDs[2], toGroup: cy.id)
        proposal = try #require(model.pendingPersonShownUpdate)
        #expect(proposal.replacementsByURL == [p2: [.init(old: "Ann", new: nil)]])
        model.confirmPersonShownUpdate(knownC2PA: [p2: false])
        await model.waitForPendingFieldMutationWrites()
        let requests = await recorder.captured
        #expect(requests.map(\.imageURL) == [p2])
        #expect(requests.first?.mutation == .replacePersons([.init(old: "Ann", new: nil)]))
        await model.waitForCurrentFaceDataPersistence()
    }

    @Test("Deleting a false-positive face offers to remove its applied name from that photo only")
    @MainActor
    func deleteFalsePositive() async throws {
        let folder = try makeFolder("delete")
        defer { try? FileManager.default.removeItem(at: folder) }
        let p1 = folder.appendingPathComponent("p1.jpg")
        let p2 = folder.appendingPathComponent("p2.jpg")
        let data = makeData(folder: folder, [GroupSpec(name: "Ann", applied: "Ann", photos: [p1, p1, p2])])
        let recorder = FieldMutationCallerRecorder()
        let model = try makeModel(data, recorder: recorder)
        let faces = data.groups[0].faceIDs
        model.deleteFaces([faces[0], faces[2]])
        await model.waitForCurrentFaceDataPersistence()
        let proposal = try #require(model.pendingPersonShownUpdate)
        #expect(proposal.replacementsByURL == [p2: [.init(old: "Ann", new: nil)]])
    }

    @Test("Apply records the applied name per photo; a rename during the write is planned against it once")
    @MainActor
    func applyRecordsAppliedName() async throws {
        let folder = try makeFolder("apply")
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("a.jpg")
        let data = makeData(folder: folder, [GroupSpec(name: "Ann", applied: nil, photos: [photo])])
        let recorder = FieldMutationCallerRecorder(pausesFirst: true)
        let model = try makeModel(data, recorder: recorder)
        model.applyAllNamesToMetadata(images: [ImageFile(url: photo)], folderURL: folder)
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await recorder.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await recorder.isPaused)
        // The in-flight Apply is overlaid: the rename is planned from "Ann" right away.
        model.nameGroup(data.groups[0].id, name: "Anne")
        let proposal = try #require(model.pendingPersonShownUpdate)
        #expect(proposal.replacementsByURL == [photo: [.init(old: "Ann", new: "Anne")]])
        await recorder.resume()
        await model.waitForPendingFieldMutationWrites()
        #expect(model.faceData?.groups.first?.appliedPersonShownNames == ["a.jpg": "Ann"])
        // Completion records the name without a second prompt.
        #expect(model.pendingPersonShownUpdate == proposal)
        await model.waitForCurrentFaceDataPersistence()
    }

    @Test("Renames during a running update are planned from the name the photos will carry")
    @MainActor
    func renameDuringInFlightUpdate() async throws {
        let folder = try makeFolder("chain")
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("a.jpg")
        let data = makeData(folder: folder, [GroupSpec(name: "Alice", applied: "Alice", photos: [photo])])
        let recorder = FieldMutationCallerRecorder(pausesFirst: true)
        let model = try makeModel(data, recorder: recorder)
        let groupID = data.groups[0].id
        model.nameGroup(groupID, name: "Alicia")
        model.confirmPersonShownUpdate(knownC2PA: [photo: false])
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await recorder.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await recorder.isPaused)

        model.nameGroup(groupID, name: "Alicja")
        let proposal = try #require(model.pendingPersonShownUpdate)
        #expect(proposal.replacementsByURL == [photo: [.init(old: "Alicia", new: "Alicja")]])
        await recorder.resume()
        await model.waitForPendingFieldMutationWrites()
        #expect(model.faceData?.groups.first?.appliedPersonShownNames == ["a.jpg": "Alicia"])
        #expect(model.pendingPersonShownUpdate == proposal)

        model.confirmPersonShownUpdate(knownC2PA: [photo: false])
        await model.waitForPendingFieldMutationWrites()
        let requests = await recorder.captured
        #expect(requests.map(\.mutation) == [.replacePersons([.init(old: "Alice", new: "Alicia")]),
                                             .replacePersons([.init(old: "Alicia", new: "Alicja")])])
        #expect(model.faceData?.groups.first?.appliedPersonShownNames == ["a.jpg": "Alicja"])
        await model.waitForCurrentFaceDataPersistence()
    }

    @Test("Declining a correction planned during a running update keeps later corrections exact")
    @MainActor
    func declineDuringInFlightUpdate() async throws {
        let folder = try makeFolder("chain-decline")
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("a.jpg")
        let data = makeData(folder: folder, [GroupSpec(name: "Alice", applied: "Alice", photos: [photo])])
        let recorder = FieldMutationCallerRecorder(pausesFirst: true)
        let model = try makeModel(data, recorder: recorder)
        let groupID = data.groups[0].id
        model.nameGroup(groupID, name: "Alicia")
        model.confirmPersonShownUpdate(knownC2PA: [photo: false])
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await recorder.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        model.nameGroup(groupID, name: "Alicja")
        model.declinePersonShownUpdate()
        await recorder.resume()
        await model.waitForPendingFieldMutationWrites()
        #expect(model.pendingPersonShownUpdate == nil)
        #expect(model.faceData?.groups.first?.appliedPersonShownNames == ["a.jpg": "Alicia"])
        // The photos carry "Alicia": the next rename targets exactly that.
        model.nameGroup(groupID, name: "Ali")
        #expect(model.pendingPersonShownUpdate?.replacementsByURL == [photo: [.init(old: "Alicia", new: "Ali")]])
        await model.waitForCurrentFaceDataPersistence()
    }

    @Test("Consecutive renames before answering collapse into one correction; renaming back clears it")
    @MainActor
    func pendingProposalIsReplanned() async throws {
        let folder = try makeFolder("replan")
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("a.jpg")
        let data = makeData(folder: folder, [GroupSpec(name: "Alice", applied: "Alice", photos: [photo])])
        let model = try makeModel(data, recorder: FieldMutationCallerRecorder())
        let groupID = data.groups[0].id
        model.nameGroup(groupID, name: "Alicia")
        model.nameGroup(groupID, name: "Alicja")
        #expect(model.pendingPersonShownUpdate?.replacementsByURL == [photo: [.init(old: "Alice", new: "Alicja")]])
        model.nameGroup(groupID, name: "Alice")
        #expect(model.pendingPersonShownUpdate == nil)
        await model.waitForCurrentFaceDataPersistence()
    }

    @Test("Corrections touch only photos this app wrote the name to; merges inherit only matching records")
    @MainActor
    func perPhotoAppliedRecords() async throws {
        let folder = try makeFolder("per-photo")
        defer { try? FileManager.default.removeItem(at: folder) }
        let applied = folder.appendingPathComponent("applied.jpg")
        let typed = folder.appendingPathComponent("typed.jpg")
        let other = folder.appendingPathComponent("other.jpg")
        var data = makeData(folder: folder, [
            GroupSpec(name: "Ann", applied: nil, photos: [applied, typed]),
            GroupSpec(name: "Ann", applied: nil, photos: [other]),
            GroupSpec(name: "Bob", applied: nil, photos: [folder.appendingPathComponent("bob.jpg")]),
        ])
        // Apply wrote "Ann" only to applied.jpg; typed.jpg's face joined later (hand-typed name).
        data.groups[0].appliedPersonShownNames = ["applied.jpg": "Ann"]
        data.groups[1].appliedPersonShownNames = ["other.jpg": "Ann"]
        let model = try makeModel(data, recorder: FieldMutationCallerRecorder())
        model.nameGroup(data.groups[0].id, name: "Anne")
        #expect(model.pendingPersonShownUpdate?.replacementsByURL == [applied: [.init(old: "Ann", new: "Anne")]])
        model.declinePersonShownUpdate()

        // A never-applied target named differently inherits nothing; it offers removal instead.
        model.mergeGroups(sourceID: data.groups[1].id, into: data.groups[2].id)
        #expect(model.faceData?.groups.first { $0.id == data.groups[2].id }?.appliedPersonShownNames == nil)
        #expect(model.pendingPersonShownUpdate?.replacementsByURL == [other: [.init(old: "Ann", new: nil)]])
        model.declinePersonShownUpdate()
        await model.waitForCurrentFaceDataPersistence()

        var inheritor = FaceGroup(id: UUID(), name: "Ann", representativeFaceID: UUID(), faceIDs: [])
        inheritor.inheritAppliedName(from: data.groups[1])
        #expect(inheritor.appliedPersonShownNames == ["other.jpg": "Ann"])
    }

    @Test("Known People renames, merges and deletions update linked folder groups")
    @MainActor
    func knownPeopleChangesReachFolderGroups() async throws {
        let folder = try makeFolder("known")
        defer { try? FileManager.default.removeItem(at: folder) }
        let p1 = folder.appendingPathComponent("p1.jpg")
        let p2 = folder.appendingPathComponent("p2.jpg")
        let p3 = folder.appendingPathComponent("p3.jpg")
        let renamed = UUID(), source = UUID(), target = UUID(), deleted = UUID()
        let data = makeData(folder: folder, [
            GroupSpec(name: "Old Name", applied: "Old Name", photos: [p1], knownPersonID: renamed),
            GroupSpec(name: "Merged Away", applied: "Merged Away", photos: [p2], knownPersonID: source),
            GroupSpec(name: "Kept Name", applied: nil, photos: [p3], knownPersonID: deleted),
        ])
        let recorder = FieldMutationCallerRecorder()
        let model = try makeModel(data, recorder: recorder)
        func group(_ index: Int) -> FaceGroup? { model.faceData?.groups.first { $0.id == data.groups[index].id } }

        NotificationCenter.default.post(name: .knownPeopleDatabaseDidChange, object: nil,
            userInfo: KnownPeopleIdentityChange.renamed(personID: renamed, newName: "New Name").userInfo)
        #expect(group(0)?.name == "New Name")
        #expect(group(0)?.knownPersonID == renamed)
        #expect(model.pendingPersonShownUpdate?.replacementsByURL == [p1: [.init(old: "Old Name", new: "New Name")]])
        model.declinePersonShownUpdate()

        NotificationCenter.default.post(name: .knownPeopleDatabaseDidChange, object: nil,
            userInfo: KnownPeopleIdentityChange.merged(sourceID: source, targetID: target, targetName: "Target").userInfo)
        #expect(group(1)?.knownPersonID == target)
        #expect(group(1)?.name == "Target")
        #expect(model.pendingPersonShownUpdate?.replacementsByURL == [p2: [.init(old: "Merged Away", new: "Target")]])
        model.declinePersonShownUpdate()

        NotificationCenter.default.post(name: .knownPeopleDatabaseDidChange, object: nil,
            userInfo: KnownPeopleIdentityChange.deleted(personID: deleted).userInfo)
        #expect(group(2)?.knownPersonID == nil)
        #expect(group(2)?.name == "Kept Name")
        #expect(model.pendingPersonShownUpdate == nil)
        await model.waitForCurrentFaceDataPersistence()
    }

    @Test("An inline rename keeps the Known People link only while the name is unchanged")
    @MainActor
    func inlineRenameKeepsLink() async throws {
        let folder = try makeFolder("link")
        defer { try? FileManager.default.removeItem(at: folder) }
        let person = UUID(), picked = UUID()
        let data = makeData(folder: folder, [GroupSpec(name: "Støre, Jonas Gahr", applied: nil,
            photos: [folder.appendingPathComponent("a.jpg")], knownPersonID: person)])
        let model = try makeModel(data, recorder: FieldMutationCallerRecorder())
        let groupID = data.groups[0].id
        model.nameGroup(groupID, name: "Støre, Jonas Gahr")
        #expect(model.faceData?.groups.first?.knownPersonID == person)
        model.nameGroup(groupID, name: "Someone Else")
        #expect(model.faceData?.groups.first?.knownPersonID == nil)
        model.nameGroup(groupID, name: "Picked Person", knownPersonID: picked)
        #expect(model.faceData?.groups.first?.knownPersonID == picked)
        await model.waitForCurrentFaceDataPersistence()
    }

    @Test("Face edits, Apply and deletion are refused while the folder is scanning instead of being lost")
    @MainActor
    func editsRefusedDuringScan() async throws {
        let folder = try makeFolder("scanning")
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("a.jpg")
        try Data([1]).write(to: photo)
        let data = makeData(folder: folder, [GroupSpec(name: "Ann", applied: nil, photos: [photo])])
        let gate = PersonShownScanGate()
        let recorder = FieldMutationCallerRecorder()
        let model = try makeModel(data, recorder: recorder, scanDetector: { _, _ in
            await gate.wait()
            return .init(faces: [])
        })
        let groupID = data.groups[0].id
        let submission = model.scheduleFolderScan(imageURLs: [photo], folderURL: folder)
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await gate.entered), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.entered)
        #expect(model.faceEditingPausedForScan(folderURL: folder))

        model.nameGroup(groupID, name: "Lost Edit")
        #expect(model.faceData?.groups.first?.name == "Ann")
        #expect(model.errorMessage == FaceRecognitionViewModel.scanInProgressEditRefusal)
        var completions = 0
        model.applyAllNamesToMetadata(images: [ImageFile(url: photo)], folderURL: folder) { completions += 1 }
        #expect(completions == 1)
        let deletion = await model.deleteGroup(groupID, includePhotos: false)
        if case .failed(let message) = deletion.faceDataDisposition {
            #expect(message == FaceRecognitionViewModel.scanInProgressEditRefusal)
        } else { Issue.record("Deletion during a scan must be refused") }

        await gate.release()
        _ = await submission.completion()
        #expect(!model.faceEditingPausedForScan(folderURL: folder))
        #expect(await recorder.captured.isEmpty)
    }

    @Test("A copied or moved folder's face data is rebased; edits and Apply target the open folder")
    @MainActor
    func movedAndCopiedFoldersAreRebased() async throws {
        let parent = try makeFolder("relocate")
        defer { try? FileManager.default.removeItem(at: parent) }
        let original = parent.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let photoName = "p.jpg"
        try Data([1]).write(to: original.appendingPathComponent(photoName))
        var data = makeData(folder: original, [GroupSpec(name: "Ann", applied: nil,
            photos: [original.appendingPathComponent(photoName)])])
        data.scannedFiles = [original.appendingPathComponent(photoName).path:
            FileSignature(modificationDate: Date(timeIntervalSince1970: 5), fileSize: 1)]
        try FaceDataStorageService().saveFaceData(data)

        // Copy: the copy adopts its own location; the original document is untouched.
        let copy = parent.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        let loaded = try await FaceDataFolderLoadService().loadWithFolderReservation(folderURL: copy, cleanupPolicy: .never)
        guard case .complete(let evidence) = loaded, let rebased = evidence.faceData else {
            Issue.record("The copied folder's face data must load")
            return
        }
        let copyPhoto = copy.appendingPathComponent(photoName)
        #expect(rebased.folderURL.standardizedFileURL.path == copy.standardizedFileURL.path)
        #expect(rebased.faces.map(\.imageURL.path) == [copyPhoto.path])
        #expect(Array(rebased.scannedFiles.keys) == [copyPhoto.path])
        #expect(FaceDataStorageService().loadFaceData(for: copy)?.folderURL.standardizedFileURL.path == copy.standardizedFileURL.path)
        #expect(FaceDataStorageService().loadFaceData(for: original)?.folderURL.standardizedFileURL.path == original.standardizedFileURL.path)

        // Move: edits persist in the new folder and Apply writes the new folder's photo.
        let moved = parent.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: moved)
        let recorder = FieldMutationCallerRecorder()
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            fieldMutationWriter: { await recorder.write($0) })
        model.loadFaceData(for: moved, cleanupPolicy: .never)
        await model.waitForCurrentFaceDataLoad()
        #expect(model.faceData?.folderURL.standardizedFileURL.path == moved.standardizedFileURL.path)
        model.nameGroup(data.groups[0].id, name: "Anne")
        await model.waitForCurrentFaceDataPersistence()
        #expect(model.errorMessage == nil)
        #expect(FaceDataStorageService().loadFaceData(for: moved)?.groups.first?.name == "Anne")
        #expect(!FileManager.default.fileExists(atPath: original.path))
        let movedPhoto = moved.appendingPathComponent(photoName)
        model.applyAllNamesToMetadata(images: [ImageFile(url: movedPhoto)], folderURL: moved)
        await model.waitForPendingFieldMutationWrites()
        let requests = await recorder.captured
        #expect(requests.map(\.imageURL.path) == [movedPhoto.path])
        #expect(requests.first?.folderURL.standardizedFileURL.path == moved.standardizedFileURL.path)
    }

    @Test("Review list cells join and split person names on semicolons so \"Last, First\" stays one person")
    @MainActor
    func reviewPersonShownSeparator() async throws {
        var metadata = IPTCMetadata()
        metadata.personShown = ["Støre, Jonas Gahr", "Hansen, Ola"]
        #expect(MetadataFieldID.personShown.reviewTextValue(in: metadata) == "Støre, Jonas Gahr; Hansen, Ola")
        var unchanged = metadata
        MetadataFieldID.personShown.setReviewTextValue("Støre, Jonas Gahr; Hansen, Ola", in: &unchanged)
        #expect(unchanged.personShown == metadata.personShown)
        var edited = metadata
        MetadataFieldID.personShown.setReviewTextValue("Støre, Jonas Gahr; Hansen, Ola; Brundtland, Gro Harlem", in: &edited)
        #expect(edited.personShown == ["Støre, Jonas Gahr", "Hansen, Ola", "Brundtland, Gro Harlem"])
        #expect(MetadataFieldID.personShown.reviewNameListHint(for: "Alice, Bob, Carol") != nil)
        #expect(MetadataFieldID.personShown.reviewNameListHint(for: "Støre, Jonas Gahr; Hansen, Ola") == nil)
        #expect(MetadataFieldID.personShown.reviewNameListHint(for: "Ann") == nil)
        #expect(MetadataFieldID.keywords.reviewNameListHint(for: "a, b") == nil)
        // Keywords keep the established comma syntax.
        var keywords = IPTCMetadata()
        MetadataFieldID.keywords.setReviewTextValue("a, b", in: &keywords)
        #expect(keywords.keywords == ["a", "b"])

        let photo = URL(fileURLWithPath: "/virtual/review-names-\(UUID().uuidString)/photo.jpg")
        let queue = CaptionDraftPersistenceQueue(label: "review.names")
        queue.enqueue(operation: { throw CaptionWorkspaceFlushError.persistenceFailed("Hold queued work") })
        let baseline = metadata
        let model = BrowserViewModel(metadataReviewBaselineLoader: { image, _ in
            .init(metadata: baseline, sidecar: MetadataSidecar(sourceFile: image.lastPathComponent,
                pendingChanges: true, metadata: baseline, imageMetadataSnapshot: nil))
        }, metadataReviewCoordinator: CaptionWorkspaceFlushCoordinator(persistenceQueue: queue))
        model.currentFolderURL = photo.deletingLastPathComponent()
        model.images = [ImageFile(url: photo)]
        await model.prepareMetadataReviewEditor(for: photo)
        let editor = try #require(model.metadataReviewEditor(for: photo))
        #expect(model.metadataReviewText(for: .personShown, imageURL: photo) == "Støre, Jonas Gahr; Hansen, Ola")
        model.updateMetadataReviewText("Støre, Jonas Gahr; Hansen, Ola; Solberg, Erna",
            field: .personShown, for: photo, editorID: editor.id)
        #expect(model.metadataReviewEditor(for: photo)?.draft.personShown
            == ["Støre, Jonas Gahr", "Hansen, Ola", "Solberg, Erna"])
    }

    @Test("A lazy Review row reappearing reuses its clean editor; explicit reloads still re-read")
    @MainActor
    func reviewRowsReuseCleanEditors() async throws {
        let photo = URL(fileURLWithPath: "/virtual/review-reuse-\(UUID().uuidString)/photo.jpg")
        let loads = FieldMutationLoadCounter()
        let model = BrowserViewModel(metadataReviewBaselineLoader: { image, _ in
            loads.increment()
            return .init(metadata: IPTCMetadata(title: "Saved"), sidecar: nil)
        }, metadataReviewCoordinator: CaptionWorkspaceFlushCoordinator())
        model.currentFolderURL = photo.deletingLastPathComponent()
        var image = ImageFile(url: photo)
        image.metadata = IPTCMetadata(title: "Saved")
        model.images = [image]
        await model.prepareMetadataReviewEditor(for: photo, reloadClean: false)
        let first = try #require(model.metadataReviewEditor(for: photo)?.id)
        await model.prepareMetadataReviewEditor(for: photo, reloadClean: false)
        #expect(model.metadataReviewEditor(for: photo)?.id == first)
        #expect(loads.value == 1)
        await model.prepareMetadataReviewEditor(for: photo)
        let second = try #require(model.metadataReviewEditor(for: photo)?.id)
        #expect(second != first)
        #expect(loads.value == 2)
        // Caption, a template or face Apply changed the record while Review was away: a
        // reappearing row must not keep showing the old clean draft.
        model.images[0].metadata = IPTCMetadata(title: "Changed in Caption")
        await model.prepareMetadataReviewEditor(for: photo, reloadClean: false)
        #expect(model.metadataReviewEditor(for: photo)?.id != second)
        #expect(loads.value == 3)
    }
}

private nonisolated final class FieldMutationLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@Suite("Reset All Edits write failures", .serialized)
@MainActor
struct ResetAllEditsFailureTests {
    @Test("A reset that can't be written restores the photo's edits and names it")
    func unwritableResetRestoresEdits() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("reset-edits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = folder.appendingPathComponent("a.arw")
        try Data("not really a raw".utf8).write(to: raw)
        let sidecar = folder.appendingPathComponent("a.xmp")
        try Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+1.00" crs:HasSettings="True"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8).write(to: sidecar)
        // A read-only folder: the sidecar can't be rewritten.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }

        let model = BrowserViewModel()
        model.currentFolderURL = folder
        var settings = CameraRawSettings()
        settings.exposure2012 = 1
        var image = ImageFile(url: raw)
        image.cameraRawSettings = settings
        image.hasDevelopEdits = true
        model.images = [image]
        model.selectedImageIDs = [raw]
        model.batchUpdate {}

        model.resetAllEditsOnSelected()
        #expect(model.images[0].hasDevelopEdits == false)
        await model.waitForResetAllEdits()

        #expect(model.images[0].hasDevelopEdits)
        #expect(model.images[0].cameraRawSettings?.exposure2012 == 1)
        let message = try #require(model.errorMessage)
        #expect(message.contains("a.arw"))
        #expect(message.contains("edits are kept"))
    }
}
