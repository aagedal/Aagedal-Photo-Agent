import AppKit
import Foundation
import CoreGraphics
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

@Suite("Browser and Face field mutation callers", .serialized)
struct FieldMutationCallerTests {
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
        #expect(message.contains(json.path))
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
        model.faceData = faceData(folder: folder, urls: urls, name: "Ada; Lin")
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
            if case .addPersons(let names) = request.mutation { #expect(names == ["Ada", "Lin"]) } else { Issue.record("Captured person names changed") }
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
