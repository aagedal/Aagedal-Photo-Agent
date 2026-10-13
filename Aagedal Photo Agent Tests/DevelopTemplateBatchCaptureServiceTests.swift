import AppKit
import CryptoKit
import Foundation
import SwiftMediaMetadata
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Independent app-side Develop template batch capture", .serialized)
@MainActor
struct DevelopTemplateBatchCaptureServiceTests {
    private struct Fixture {
        let root: URL
        let photos: [URL]
        let template: DevelopTemplate
        let templateURL: URL
        let revision: String
        let facade: MCPAutomationFacade
        let discovery: MCPTemplateDiscovery
        var service: DevelopTemplateBatchCaptureService { .init(facade: facade, discovery: discovery) }
    }

    private func fixture(watermark: Bool = false) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/DevelopCapture-\(UUID())", isDirectory: true)
        let directory = root.appendingPathComponent("Develop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 5, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        let photos = [root.appendingPathComponent("first.png"), root.appendingPathComponent("second.png")]
        for photo in photos { try bytes.write(to: photo) }
        var settings = CameraRawSettings(); settings.exposure2012 = 1.25
        let mask = MaskAdjustment(name: "Captured mask", exposure: 0.75)
        settings.localAdjustments = [mask]; settings.layerOrder = [.mask(mask.id), .global]
        if watermark { settings.watermarkLayers = [WatermarkLayer(libraryAssetID: UUID())] }
        let template = DevelopTemplate(name: "Captured exposure", settings: settings, includesCrop: false)
        let data = try JSONEncoder().encode(template)
        let templateURL = directory.appendingPathComponent("\(template.id.uuidString).json")
        try data.write(to: templateURL)
        let box = MCPServerCoreTests.DataBox()
        let store = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try store.addRoot(root); try store.setEnabled(true)
        return .init(root: root, photos: photos, template: template, templateURL: templateURL,
            revision: "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            facade: MCPAutomationFacade(authorizationStore: store),
            discovery: MCPTemplateDiscovery(authorizationStore: store,
                resolveScope: { .init(directory: root, release: {}) }))
    }

    @Test("Ordered capture owns fresh layers, exact source/carrier evidence and makes no writes")
    func orderedIndependentCapture() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try f.photos.map { try Data(contentsOf: $0) }
        let selected = Array(f.photos.reversed())
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: selected, mode: .writeToXMPSidecar)
        let canonicalSelection = try selected.map { try f.facade.capturePhotoSnapshot(path: $0.path).target.url }
        #expect(capture.intent.requests.map(\.imageURL) == canonicalSelection)
        #expect(capture.photos.map(\.requestID) == capture.intent.requests.map(\.id))
        #expect(capture.template == f.template)
        let masks = try capture.intent.requests.map { try #require($0.edited.cameraRaw?.localAdjustments?.first?.id) }
        #expect(Set(masks).count == 2)
        #expect(!masks.contains(try #require(f.template.settings.localAdjustments?.first?.id)))
        for request in capture.intent.requests {
            let source = try await SourceImageRevision.capture(at: request.imageURL)
            #expect(request.sourceRevision?.sha256 == source.sha256)
            #expect(request.edited.cameraRaw?.exposure2012 == 1.25)
            #expect(request.edited.cameraRaw?.asShotNeutralTemperature == nil)
            #expect(request.captureFailure == nil && request.expectedXMP?.data == nil)
            #expect(request.predecessor == nil && request.watermarkDependencies.isEmpty)
            #expect(request.edited.cameraRaw?.layerOrder == [.mask(try #require(request.edited.cameraRaw?.localAdjustments?.first?.id)), .global])
        }
        #expect(try f.photos.map { try Data(contentsOf: $0) } == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted() == ["Develop", "first.png", "second.png"])
    }

    @Test("Missing or changed exact template revision refuses admission")
    func staleTemplate() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var changed = f.template; changed.name = "Changed after selection"
        try JSONEncoder().encode(changed).write(to: f.templateURL)
        #expect(throws: MCPMetadataTemplatePreview.Failure.staleTemplate) {
            try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
                photos: f.photos, mode: .writeToXMPSidecar)
        }
    }

    @Test("Production capture executes with durable checkpoints and preserves sidecar-only sources")
    func productionCaptureExecution() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try f.photos.map { try Data(contentsOf: $0) }
        let xmpURL = f.photos[0].deletingPathExtension().appendingPathExtension("xmp")
        try Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        crs:Exposure2012="-0.5" crs:CropTop="0.1" crs:CropLeft="0.2" crs:CropBottom="0.9" crs:CropRight="0.8" crs:CropAngle="0" crs:HasCrop="True"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8).write(to: xmpURL)
        let originalHistory = MetadataHistoryEntry(timestamp: Date(), fieldName: "Title", oldValue: nil, newValue: "Retained batch title")
        try MetadataSidecarService().saveSidecar(.init(sourceFile: f.photos[0].lastPathComponent,
            lastModified: Date(), pendingChanges: true, metadata: IPTCMetadata(title: "Retained batch title"),
            history: [originalHistory]), for: f.photos[0], in: f.root)
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: Array(f.photos.reversed()), mode: .writeToXMPSidecar)
        let discovery = f.discovery
        let checkpointRoot = f.root.appendingPathComponent("Checkpoints", isDirectory: true)
        let store = DevelopTemplateBatchCheckpointStore(directory: checkpointRoot)
        let result = await DevelopTemplateBatchExecutionService(engine: SwiftExifWriteEngine()).execute(capture.intent,
            validateAuthority: { intent in
                // Disposable test authority is explicit and exact; this does not simulate
                // or grant production native consent. The executor owns photo reservations.
                try discovery.withDevelopTemplate(id: intent.templateID, revision: intent.templateRevision) { template in
                    guard template == capture.template else { throw DevelopTemplateBatchFailure.invalidIntent }
                }
                for request in intent.requests {
                    let current = try await SourceImageRevision.capture(at: request.imageURL)
                    guard current.canonicalURL == request.sourceRevision?.canonicalURL,
                          current.sha256 == request.sourceRevision?.sha256 else { throw DevelopTemplateBatchFailure.staleSource }
                }
            }, checkpointStore: store)
        #expect(result.outcome == .completed && result.completedCount == 2)
        #expect(result.results.map { $0?.requestID } == capture.intent.requests.map { Optional($0.id) })
        for request in capture.intent.requests {
            let writtenXMP = try #require(XMPSidecarService().loadSidecar(for: request.imageURL))
            let writtenJSON = try #require(try MetadataSidecarService().loadOwnedSidecarForMutation(
                for: request.imageURL, in: request.folderURL))
            #expect(writtenXMP.cameraRaw?.exposure2012 == 1.25)
            #expect(writtenXMP.cameraRaw?.crop == request.edited.cameraRaw?.crop)
            let writtenMask = try #require(writtenXMP.cameraRaw?.localAdjustments?.first)
            let expectedMask = try #require(request.edited.cameraRaw?.localAdjustments?.first)
            #expect(writtenXMP.cameraRaw?.localAdjustments?.count == 1)
            #expect(writtenMask.name == expectedMask.name && writtenMask.exposure == expectedMask.exposure)
            #expect(writtenMask.enabled == expectedMask.enabled && writtenMask.inverted == expectedMask.inverted)
            #expect(writtenMask.amount == expectedMask.amount)
            #expect(abs(writtenMask.geometry.centerX - expectedMask.geometry.centerX) < 0.000001)
            #expect(abs(writtenMask.geometry.centerY - expectedMask.geometry.centerY) < 0.000001)
            #expect(abs(writtenMask.geometry.radiusX - expectedMask.geometry.radiusX) < 0.000001)
            #expect(abs(writtenMask.geometry.radiusY - expectedMask.geometry.radiusY) < 0.000001)
            // ACR mask parsing generates runtime UUIDs. Stored ordering must reference
            // those newly parsed identities while preserving the captured chain semantics.
            #expect(writtenXMP.cameraRaw?.layerOrder == [.mask(writtenMask.id), .global])
            // JSON deliberately excludes Develop/orientation in every IPTC record;
            // XMP owns those settings, while JSON retains editorial state and history.
            let persistedEditorial = try JSONDecoder().decode(IPTCMetadata.self, from: JSONEncoder().encode(request.edited))
            #expect(writtenJSON.metadata == persistedEditorial)
            #expect(writtenJSON.imageMetadataSnapshot == persistedEditorial)
            #expect(writtenJSON.history.map(\.persistentEventID) == request.sidecar.history.map(\.persistentEventID))
            #expect(!writtenJSON.pendingChanges)
        }
        #expect(try f.photos.map { try Data(contentsOf: $0) } == before)
        // Reopening the mandatory journal proves completed receipt evidence survived
        // beyond the execution adapter's actor instance.
        let checkpoint = try await DevelopTemplateBatchCheckpointStore(directory: checkpointRoot).load(capture.intent.id)
        #expect(checkpoint.outcome == .completed && checkpoint.completedCount == 2)
        #expect(checkpoint.activeRequestID == nil && !checkpoint.needsReview)
        #expect(checkpoint.receipts.count == 2 && checkpoint.receipts.allSatisfy { $0 != nil })
    }

    @Test("Application preserves each target crop and pending editorial draft with its exact history")
    func targetCropAndPendingDraft() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let xmpURL = f.photos[0].deletingPathExtension().appendingPathExtension("xmp")
        let xmp = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        crs:Exposure2012="-0.5" crs:CropTop="0.1" crs:CropLeft="0.2" crs:CropBottom="0.9" crs:CropRight="0.8" crs:CropAngle="0" crs:HasCrop="True"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8)
        try xmp.write(to: xmpURL)
        let history = MetadataHistoryEntry(timestamp: Date(), fieldName: "Title", oldValue: nil, newValue: "Pending title")
        let pending = MetadataSidecar(sourceFile: f.photos[0].lastPathComponent, lastModified: Date(),
            pendingChanges: true, metadata: IPTCMetadata(title: "Pending title"), history: [history])
        try MetadataSidecarService().saveSidecar(pending, for: f.photos[0], in: f.root)
        let installed = try #require(try MetadataSidecarService().loadOwnedSidecarForMutation(for: f.photos[0], in: f.root))
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        let first = capture.intent.requests[0]; let second = capture.intent.requests[1]
        #expect(first.edited.title == "Pending title")
        #expect(first.expectedRecord?.metadata == installed.metadata)
        #expect(first.expectedRecord?.lastModified == installed.lastModified)
        #expect(first.expectedRecord?.history == installed.history)
        #expect(first.sidecar.history.map(\.persistentEventID).contains(history.persistentEventID))
        #expect(first.expectedXMP?.data == xmp)
        #expect(first.edited.cameraRaw?.crop == first.previous?.cameraRaw?.crop)
        #expect(first.edited.cameraRaw?.crop != nil)
        #expect(second.edited.cameraRaw?.crop == nil)
        #expect(first.edited.cameraRaw?.exposure2012 == 1.25)
        #expect(try Data(contentsOf: xmpURL) == xmp)
        let current = try #require(try MetadataSidecarService().loadOwnedSidecarForMutation(for: f.photos[0], in: f.root))
        #expect(current.metadata == installed.metadata && current.lastModified == installed.lastModified)
    }

    @Test("An original saved watermark is refused even when the template would remove it")
    func baselineWatermarkRefusal() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var settings = CameraRawSettings()
        let assetID = UUID(); settings.watermarkLayers = [WatermarkLayer(libraryAssetID: assetID)]
        try XMPSidecarService().saveCameraRawOnly(settings, orientation: nil, for: f.photos[0])
        let saved = try #require(XMPSidecarService().loadSidecar(for: f.photos[0]))
        #expect(saved.cameraRaw?.watermarkLayers?.map(\.libraryAssetID) == [assetID])
        #expect(throws: DevelopTemplateBatchFailure.unsupportedWatermarkDependencies) {
            try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
                photos: f.photos, mode: .writeToXMPSidecar)
        }
    }

    @Test("Changing a template during independent decoder admission refuses the whole capture")
    func templateDriftDuringDecoder() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let url = f.templateURL
        let service = DevelopTemplateBatchCaptureService(facade: f.facade, discovery: f.discovery,
            resolveDecoder: { bytes, photo in
                try Data("external template revision".utf8).write(to: url)
                return try MCPDevelopTemplatePreview.resolveDecoderState(data: bytes, url: photo)
            })
        #expect(throws: MCPTemplateDiscoveryError.invalidInventory) {
            try service.capture(templateID: f.template.id, templateRevision: f.revision,
                photos: f.photos, mode: .writeToXMPSidecar)
        }
    }

    @Test("A later decoder cannot silently change an earlier target carrier")
    func earlierCarrierDrift() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = f.photos[0]; let second = f.photos[1]
        let service = DevelopTemplateBatchCaptureService(facade: f.facade, discovery: f.discovery,
            resolveDecoder: { bytes, photo in
                if photo.lastPathComponent == second.lastPathComponent {
                    try Data("external source revision".utf8).write(to: first)
                }
                return try MCPDevelopTemplatePreview.resolveDecoderState(data: bytes, url: photo)
            })
        #expect(throws: MCPAutomationReadError.photoChanged) {
            try service.capture(templateID: f.template.id, templateRevision: f.revision,
                photos: f.photos, mode: .writeToXMPSidecar)
        }
        #expect(try Data(contentsOf: first) == Data("external source revision".utf8))
    }

    @Test("Template watermark dependencies are refused before decoder work")
    func watermarkRefusal() throws {
        let f = try fixture(watermark: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = DevelopTemplateBatchCaptureService(facade: f.facade, discovery: f.discovery,
            resolveDecoder: { _, _ in Issue.record("Watermark refusal must precede decoding"); throw CancellationError() })
        #expect(throws: DevelopTemplateBatchFailure.unsupportedWatermarkDependencies) {
            try service.capture(templateID: f.template.id, templateRevision: f.revision,
                photos: f.photos, mode: .writeToXMPSidecar)
        }
    }

    @Test("Capture refuses empty, excessive, duplicate and history-only selections")
    func invalidSelections() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for photos in [[], Array(repeating: f.photos[0], count: 9)] {
            #expect(throws: DevelopTemplateBatchCaptureService.Failure.invalidSelection) {
                try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
                    photos: photos, mode: .writeToXMPSidecar)
            }
        }
        #expect(throws: DevelopTemplateBatchFailure.duplicatePhoto) {
            try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
                photos: [f.photos[0], f.photos[0]], mode: .writeToXMPSidecar)
        }
        #expect(throws: DevelopTemplateBatchCaptureService.Failure.invalidSelection) {
            try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
                photos: f.photos, mode: .historyOnly)
        }
    }

    @Test("A decoder mismatch refuses admission and releases all retained reservations")
    func invalidDecoderReleasesReservations() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = DevelopTemplateBatchCaptureService(facade: f.facade, discovery: f.discovery,
            resolveDecoder: { _, _ in .init(isRAW: false, neutralTemperature: 6000, neutralTint: nil, sourceHasHDRHeadroom: nil) })
        #expect(throws: MCPDevelopTemplatePreview.Failure.decoderStateInvalid) {
            try service.capture(templateID: f.template.id, templateRevision: f.revision,
                photos: f.photos, mode: .writeToXMPSidecar)
        }
        for photo in f.photos { let lease = try MCPProcessReservation.acquirePhoto(photo); lease.release() }
        let lease = try MCPProcessReservation.acquireFolder(f.templateURL.deletingLastPathComponent()); lease.release()
    }

    @Test("Exact review evidence survives reopening and cancellation permanently consumes the capture")
    func durableNativeReviewCancellation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: Array(f.photos.reversed()), mode: .writeToXMPSidecar)
        let directory = f.root.appendingPathComponent("Admission", isDirectory: true)
        let store = DevelopTemplateBatchAdmissionStore(directory: directory)
        let service = DevelopTemplateBatchAdmissionService(captureService: f.service, store: store,
            configurationRevision: { "writer-policy-v1;decoder-v1" }, validateSession: { _ in })
        let review = try await service.review(capture)
        let journal = try await DevelopTemplateBatchAdmissionStore(directory: directory).load(capture.intent.id)
        let retained = try JSONDecoder().decode(DevelopTemplateBatchAdmissionEvidence.self, from: journal.evidenceData)
        #expect(retained.photos.map(\.url) == capture.intent.requests.map(\.imageURL))
        #expect(retained.photos.map(\.rootID) == capture.photos.map(\.rootID))
        #expect(retained.photos.map(\.sourceRevision) == capture.photos.map(\.sourceRevision))
        #expect(retained.template == capture.template && retained.templateRevision == f.revision)
        #expect(retained.configurationRevision == "writer-policy-v1;decoder-v1")
        #expect(journal.state == .awaitingReview)
        try await service.cancel(review)
        let cancelled = try await store.load(capture.intent.id)
        #expect(cancelled.state == .cancelled && cancelled.evidenceData == journal.evidenceData)
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.unavailableReview) { try await service.cancel(review) }
        let restarted = DevelopTemplateBatchAdmissionService(captureService: f.service,
            store: DevelopTemplateBatchAdmissionStore(directory: directory), configurationRevision: { "writer-policy-v1;decoder-v1" }, validateSession: { _ in })
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.alreadyConsumed) { try await restarted.review(capture) }
    }

    @Test("Historical inspection preserves ordered captures and all review dispositions without writes")
    func admissionInspection() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let directory = f.root.appendingPathComponent("Admission")
        let store = DevelopTemplateBatchAdmissionStore(directory: directory)
        var captures: [DevelopTemplateBatchCapture] = []
        for _ in 0..<3 {
            let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
                photos: Array(f.photos.reversed()), mode: .writeToXMPSidecar)
            let evidence = try DevelopTemplateBatchAdmissionEvidence(capture: capture, configurationRevision: "policy-v1")
            let digest = try await store.retain(evidence)
            if captures.count > 0 {
                try await store.finishReview(capture.intent.id, digest: digest, cancelled: captures.count == 2)
            }
            captures.append(capture)
        }
        let archive = directory.appendingPathComponent("operations.json")
        let before = try Data(contentsOf: archive)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let photosBefore = try f.photos.map { try Data(contentsOf: $0) }
        for _ in 0..<2 {
            let reviews = try await DevelopTemplateBatchAdmissionStore(directory: directory).inspect()
            #expect(reviews.map(\.id) == captures.map { $0.intent.id })
            #expect(reviews.map(\.state) == [.awaitingReview, .consumed, .cancelled])
            for (review, capture) in zip(reviews, captures) {
                #expect(review.templateID == f.template.id && review.templateName == f.template.name)
                #expect(review.templateRevision == f.revision)
                #expect(review.photos.map(\.url) == capture.intent.requests.map(\.imageURL))
                #expect(review.photos.map(\.sourceRevision) == capture.photos.map(\.sourceRevision))
            }
        }
        #expect(try Data(contentsOf: archive) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == names)
        #expect(try f.photos.map { try Data(contentsOf: $0) } == photosBefore)
        let alias = f.root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        await #expect(throws: (any Error).self) { try await DevelopTemplateBatchAdmissionStore(directory: alias).inspect() }
        var object = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
        var journals = try #require(object["journals"] as? [[String: Any]])
        journals[0]["evidenceSHA256"] = "corrupt"
        object["journals"] = journals
        let corrupt = try JSONSerialization.data(withJSONObject: object)
        try corrupt.write(to: archive)
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.corruptJournal) { try await store.inspect() }
        #expect(try Data(contentsOf: archive) == corrupt)
    }

    @Test("Cancelled cleanup migrates legacy evidence and permanently refuses replay after reopening")
    func cancelledCleanupMigrationAndReplay() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let directory = f.root.appendingPathComponent("Admission")
        let store = DevelopTemplateBatchAdmissionStore(directory: directory)
        var captures: [DevelopTemplateBatchCapture] = []
        for index in 0..<3 {
            let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
                photos: f.photos, mode: .writeToXMPSidecar)
            let digest = try await store.retain(.init(capture: capture, configurationRevision: "policy-v1"))
            if index > 0 { try await store.finishReview(capture.intent.id, digest: digest, cancelled: index == 2) }
            captures.append(capture)
        }
        let archive = directory.appendingPathComponent("operations.json")
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [String: Any])
        legacy["formatVersion"] = 1; legacy.removeValue(forKey: "tombstones")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        try legacyData.write(to: archive)
        let retained = try await store.load(captures[1].intent.id)
        let photosBefore = try f.photos.map { try Data(contentsOf: $0) }
        let preview = try await store.prepareCancelledCleanup()
        #expect(preview.cancelledCount == 1 && preview.tombstoneCount == 0)
        let cancelledPreview = try #require(preview.cancelledCaptures.first)
        #expect(cancelledPreview.id == captures[2].intent.id && cancelledPreview.state == .cancelled)
        #expect(cancelledPreview.templateID == f.template.id && cancelledPreview.templateName == f.template.name)
        #expect(cancelledPreview.templateRevision == f.revision)
        #expect(cancelledPreview.photos.map(\.url) == captures[2].intent.requests.map(\.imageURL))
        #expect(try Data(contentsOf: archive) == legacyData)
        #expect(try await store.cleanupCancelledReviews(preview) == 1)
        let reopened = DevelopTemplateBatchAdmissionStore(directory: directory)
        #expect(try await reopened.inspect().map(\.id) == captures.prefix(2).map { $0.intent.id })
        #expect(try await reopened.load(captures[1].intent.id).evidenceData == retained.evidenceData)
        let after = try Data(contentsOf: archive)
        let migrated = try #require(JSONSerialization.jsonObject(with: after) as? [String: Any])
        #expect(migrated["formatVersion"] as? Int == 2)
        let tombstones = try #require(migrated["tombstones"] as? [[String: Any]])
        #expect(tombstones.count == 1)
        #expect(Set(try #require(tombstones.first).keys) == ["batchID", "evidenceSHA256"])
        let replay = try DevelopTemplateBatchAdmissionEvidence(capture: captures[2], configurationRevision: "policy-v1")
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.alreadyConsumed) { try await reopened.retain(replay) }
        // A different evidence digest cannot reuse a retired capture identity either.
        let changed = try DevelopTemplateBatchAdmissionEvidence(capture: captures[2], configurationRevision: "policy-v2")
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.alreadyConsumed) { try await reopened.retain(changed) }
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.alreadyConsumed) {
            try await reopened.finishReview(captures[2].intent.id, digest: "unused", cancelled: false)
        }
        let restarted = DevelopTemplateBatchAdmissionService(captureService: f.service, store: reopened,
            configurationRevision: { "policy-v1" }, validateSession: { _ in })
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.alreadyConsumed) { try await restarted.review(captures[2]) }
        let empty = try await reopened.prepareCancelledCleanup()
        #expect(empty.cancelledCount == 0 && empty.tombstoneCount == 1)
        #expect(try await reopened.cleanupCancelledReviews(empty) == 0)
        #expect(try Data(contentsOf: archive) == after)
        #expect(try f.photos.map { try Data(contentsOf: $0) } == photosBefore)
    }

    @Test("Cancelled cleanup refuses a stale preview without retiring newly cancelled evidence")
    func cancelledCleanupExactPreview() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let directory = f.root.appendingPathComponent("Admission")
        let store = DevelopTemplateBatchAdmissionStore(directory: directory)
        let service = DevelopTemplateBatchAdmissionService(captureService: f.service, store: store,
            configurationRevision: { "policy-v1" }, validateSession: { _ in })
        let first = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        let firstReview = try await service.review(first)
        try await service.cancel(firstReview)
        let preview = try await store.prepareCancelledCleanup()
        let second = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        let secondReview = try await service.review(second)
        try await service.cancel(secondReview)
        let archive = directory.appendingPathComponent("operations.json")
        let before = try Data(contentsOf: archive)
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.changedEvidence) { try await store.cleanupCancelledReviews(preview) }
        #expect(try Data(contentsOf: archive) == before)
        let refreshed = try await store.prepareCancelledCleanup()
        #expect(try await store.cleanupCancelledReviews(refreshed) == 2)
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.unavailableReview) { try await service.cancel(firstReview) }
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.unavailableReview) { try await service.cancel(secondReview) }
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.alreadyConsumed) { try await service.review(first) }
    }

    @Test("A pre-cancelled queued cleanup preserves exact journal bytes and cancelled evidence")
    func cancelledCleanupHonorsTaskCancellation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let directory = f.root.appendingPathComponent("Admission")
        let store = DevelopTemplateBatchAdmissionStore(directory: directory)
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        let digest = try await store.retain(.init(capture: capture, configurationRevision: "policy-v1"))
        try await store.finishReview(capture.intent.id, digest: digest, cancelled: true)
        let preview = try await store.prepareCancelledCleanup()
        let archive = directory.appendingPathComponent("operations.json")
        let before = try Data(contentsOf: archive)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.cleanupCancelledReviews(preview)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: archive) == before)
        #expect(try await store.load(capture.intent.id).state == .cancelled)
        #expect(try await store.prepareCancelledCleanup().tombstoneCount == 0)
    }

    @Test("Cancelled cleanup preserves corrupt, future and saturated tombstone evidence")
    func cancelledCleanupStrictCapacity() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let directory = f.root.appendingPathComponent("Admission")
        let store = DevelopTemplateBatchAdmissionStore(directory: directory)
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        let digest = try await store.retain(.init(capture: capture, configurationRevision: "policy-v1"))
        try await store.finishReview(capture.intent.id, digest: digest, cancelled: true)
        let archive = directory.appendingPathComponent("operations.json")
        let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [String: Any])
        let tombstone: [String: Any] = ["batchID": UUID().uuidString, "evidenceSHA256": digest]
        var invalidArchives: [[String: Any]] = []
        var unknown = original; unknown["futureAuthority"] = true; invalidArchives.append(unknown)
        var future = original; future["formatVersion"] = 3; invalidArchives.append(future)
        var booleanVersion = original; booleanVersion["formatVersion"] = true; invalidArchives.append(booleanVersion)
        var invalidDigest = original; invalidDigest["tombstones"] = [["batchID": UUID().uuidString, "evidenceSHA256": "corrupt"]]; invalidArchives.append(invalidDigest)
        var duplicate = original; duplicate["tombstones"] = [tombstone, tombstone]; invalidArchives.append(duplicate)
        var collision = original; collision["tombstones"] = [["batchID": capture.intent.id.uuidString, "evidenceSHA256": digest]]; invalidArchives.append(collision)
        var unknownTombstone = original; unknownTombstone["tombstones"] = [["batchID": UUID().uuidString, "evidenceSHA256": digest, "futureAuthority": true]]; invalidArchives.append(unknownTombstone)
        let preview = try await store.prepareCancelledCleanup()
        for invalid in invalidArchives {
            let data = try JSONSerialization.data(withJSONObject: invalid, options: [.sortedKeys])
            try data.write(to: archive)
            await #expect(throws: DevelopTemplateBatchAdmissionFailure.corruptJournal) { try await store.prepareCancelledCleanup() }
            await #expect(throws: DevelopTemplateBatchAdmissionFailure.corruptJournal) { try await store.cleanupCancelledReviews(preview) }
            #expect(try Data(contentsOf: archive) == data)
        }
        var full = original
        full["tombstones"] = (0..<DevelopTemplateBatchAdmissionStore.maximumTombstones).map { _ in
            ["batchID": UUID().uuidString, "evidenceSHA256": digest]
        }
        let fullData = try JSONSerialization.data(withJSONObject: full, options: [.sortedKeys])
        try fullData.write(to: archive)
        let saturated = try await store.prepareCancelledCleanup()
        #expect(saturated.cancelledCount == 1 && saturated.availableTombstones == 0)
        await #expect(throws: DevelopTemplateBatchFailure.retentionLimit) { try await store.cleanupCancelledReviews(saturated) }
        #expect(try Data(contentsOf: archive) == fullData)
    }

    @Test("Empty cancelled cleanup never creates missing storage and refuses symbolic roots")
    func cancelledCleanupMissingAndUnsafeStorage() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let directory = f.root.appendingPathComponent("Missing/Admission")
        let store = DevelopTemplateBatchAdmissionStore(directory: directory)
        let before = try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted()
        let preview = try await store.prepareCancelledCleanup()
        #expect(preview.cancelledCount == 0 && preview.tombstoneCount == 0)
        #expect(try await store.cleanupCancelledReviews(preview) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted() == before)
        let alias = f.root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
        let unsafe = DevelopTemplateBatchAdmissionStore(directory: alias.appendingPathComponent("Missing"))
        await #expect(throws: (any Error).self) { try await unsafe.prepareCancelledCleanup() }
        await #expect(throws: (any Error).self) { try await unsafe.cleanupCancelledReviews(preview) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Missing").path))
    }

    @Test("Cancelled cleanup restores journal capacity without evicting replay protection")
    func cancelledCleanupRestoresCapacity() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = DevelopTemplateBatchAdmissionStore(directory: f.root.appendingPathComponent("Admission"))
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        let evidence = try DevelopTemplateBatchAdmissionEvidence(capture: capture, configurationRevision: "policy-v1")
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        var retired: DevelopTemplateBatchAdmissionEvidence?
        for _ in 0..<DevelopTemplateBatchAdmissionStore.maximumEntries {
            var object = original; object["batchID"] = UUID().uuidString
            let next = try JSONDecoder().decode(DevelopTemplateBatchAdmissionEvidence.self,
                from: JSONSerialization.data(withJSONObject: object))
            let digest = try await store.retain(next)
            try await store.finishReview(next.batchID, digest: digest, cancelled: true)
            retired = next
        }
        await #expect(throws: DevelopTemplateBatchFailure.retentionLimit) { try await store.retain(evidence) }
        let preview = try await store.prepareCancelledCleanup()
        #expect(try await store.cleanupCancelledReviews(preview) == DevelopTemplateBatchAdmissionStore.maximumEntries)
        _ = try await store.retain(evidence)
        let replay = try #require(retired)
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.alreadyConsumed) { try await store.retain(replay) }
        #expect(try await store.inspect().count == 1)
    }

    @Test("Reviewed carrier drift fails before consent or physical execution and refuses replay")
    func nativeReviewCarrierDrift() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        let store = DevelopTemplateBatchAdmissionStore(directory: f.root.appendingPathComponent("Admission"))
        let service = DevelopTemplateBatchAdmissionService(captureService: f.service, store: store,
            configurationRevision: { "native-v1" }, validateSession: { _ in })
        let review = try await service.review(capture)
        try Data("changed carrier".utf8).write(to: f.photos[0])
        let checkpoints = DevelopTemplateBatchCheckpointStore(directory: f.root.appendingPathComponent("Checkpoints"))
        let writer = DevelopTemplateBatchExecutionService(write: { request, _, _ in
            Issue.record("Drift must prevent physical execution")
            return .init(requestID: request.id)
        })
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.changedEvidence) {
            try await service.execute(review, consent: { _ in Issue.record("Drift must precede consent") },
                executionService: writer, checkpointStore: checkpoints)
        }
        #expect(try await store.load(capture.intent.id).state == .consumed)
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.unavailableReview) {
            try await service.execute(review, consent: { _ in }, executionService: writer, checkpointStore: checkpoints)
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Checkpoints").path))
    }

    @Test("Admitted native review executes the retained requests once with managed physical checkpoints")
    func nativeReviewedExecution() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        let store = DevelopTemplateBatchAdmissionStore(directory: f.root.appendingPathComponent("Admission"))
        let service = DevelopTemplateBatchAdmissionService(captureService: f.service, store: store,
            configurationRevision: { "native-v1" }, validateSession: { _ in })
        let review = try await service.review(capture)
        let checkpoints = DevelopTemplateBatchCheckpointStore(directory: f.root.appendingPathComponent("Checkpoints"))
        let result = try await service.execute(review, consent: { evidence in
            #expect(evidence.batchID == capture.intent.id)
            #expect(evidence.photos.map(\.requestID) == capture.intent.requests.map(\.id))
        }, executionService: .init(engine: SwiftExifWriteEngine()), checkpointStore: checkpoints)
        #expect(result.outcome == .completed && result.completedCount == 2)
        #expect(try await store.load(capture.intent.id).state == .consumed)
        #expect(try await checkpoints.load(capture.intent.id).outcome == .completed)
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.unavailableReview) { try await service.cancel(review) }
    }

    @Test("Writer or decoder configuration drift after review consumes admission without writes")
    func nativeConfigurationDrift() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        let configuration = MCPServerCoreTests.DataBox()
        configuration.write(Data("native-v1".utf8))
        let store = DevelopTemplateBatchAdmissionStore(directory: f.root.appendingPathComponent("Admission"))
        let service = DevelopTemplateBatchAdmissionService(captureService: f.service, store: store,
            configurationRevision: { String(decoding: configuration.read() ?? Data(), as: UTF8.self) }, validateSession: { _ in })
        let review = try await service.review(capture)
        configuration.write(Data("native-v2".utf8))
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.changedEvidence) {
            try await service.execute(review, consent: { _ in Issue.record("Changed configuration must precede consent") },
                executionService: .init(engine: SwiftExifWriteEngine()),
                checkpointStore: .init(directory: f.root.appendingPathComponent("Checkpoints")))
        }
        #expect(try await store.load(capture.intent.id).state == .consumed)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Checkpoints").path))
    }

    @Test("Cancelled native consent cannot be retried with the old review")
    func nativeConsentCancellation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        let store = DevelopTemplateBatchAdmissionStore(directory: f.root.appendingPathComponent("Admission"))
        let service = DevelopTemplateBatchAdmissionService(captureService: f.service, store: store,
            configurationRevision: { "native-v1" }, validateSession: { _ in })
        let review = try await service.review(capture)
        let execution = DevelopTemplateBatchExecutionService(engine: SwiftExifWriteEngine())
        let checkpoints = DevelopTemplateBatchCheckpointStore(directory: f.root.appendingPathComponent("Checkpoints"))
        await #expect(throws: CancellationError.self) {
            try await service.execute(review, consent: { _ in throw CancellationError() },
                executionService: execution, checkpointStore: checkpoints)
        }
        #expect(try await store.load(capture.intent.id).state == .consumed)
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.unavailableReview) {
            try await service.execute(review, consent: { _ in }, executionService: execution, checkpointStore: checkpoints)
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Checkpoints").path))
    }

    @Test("A same-byte carrier replacement during consent is refused under the executor reservation")
    func nativeConsentGenerationDrift() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        let store = DevelopTemplateBatchAdmissionStore(directory: f.root.appendingPathComponent("Admission"))
        let service = DevelopTemplateBatchAdmissionService(captureService: f.service, store: store,
            configurationRevision: { "native-v1" }, validateSession: { _ in })
        let review = try await service.review(capture)
        let target = f.photos[0], original = try Data(contentsOf: target)
        let execution = DevelopTemplateBatchExecutionService(write: { request, _, _ in
            Issue.record("Exact generation validation must prevent physical execution")
            return .init(requestID: request.id)
        })
        let result = try await service.execute(review, consent: { _ in
            try original.write(to: target, options: .atomic)
        }, executionService: execution,
            checkpointStore: .init(directory: f.root.appendingPathComponent("Checkpoints")))
        #expect(result.outcome == .failed && result.completedCount == 0)
        #expect(result.results.allSatisfy { $0 == nil })
        #expect(try await store.load(capture.intent.id).state == .consumed)
        #expect(try Data(contentsOf: target) == original)
    }

    @Test("Session withdrawal during physical writer admission prevents effects and retains a terminal checkpoint")
    func nativeSessionWithdrawalAtWriter() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try f.photos.map { try Data(contentsOf: $0) }
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        let session = MCPServerCoreTests.DataBox(); session.write(Data("active".utf8))
        let service = DevelopTemplateBatchAdmissionService(captureService: f.service,
            store: .init(directory: f.root.appendingPathComponent("Admission")),
            configurationRevision: { "native-v1" }, validateSession: { _ in
                guard session.read() == Data("active".utf8) else { throw DevelopTemplateBatchAdmissionFailure.changedEvidence }
            })
        let review = try await service.review(capture)
        var hooks = PrimaryDevelopWriteHooks()
        hooks.beforeAdmission = { session.write(Data("withdrawn".utf8)) }
        let checkpoints = DevelopTemplateBatchCheckpointStore(directory: f.root.appendingPathComponent("Checkpoints"))
        let result = try await service.execute(review, consent: { _ in },
            executionService: .init(engine: SwiftExifWriteEngine(), hooks: hooks), checkpointStore: checkpoints)
        #expect(result.outcome == .failed && result.completedCount == 0)
        #expect(result.results[0]?.requiresRecovery == false)
        #expect(try f.photos.map { try Data(contentsOf: $0) } == original)
        #expect(try await checkpoints.load(capture.intent.id).outcome == .failed)
    }

    @Test("A complete authorization configuration change after capture refuses review")
    func nativeAuthorizationConfigurationDrift() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        // Re-saving the same enabled flag rotates authorization revision without changing root IDs.
        try f.facade.authorizationStore.setEnabled(true)
        let service = DevelopTemplateBatchAdmissionService(captureService: f.service,
            store: .init(directory: f.root.appendingPathComponent("Admission")),
            configurationRevision: { "native-v1" }, validateSession: { _ in })
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.changedEvidence) { try await service.review(capture) }
    }

    @Test("Same-byte replacement of the current or later target during worker suspension refuses preeffect admission")
    func nativeWorkerGenerationDrift() async throws {
        for replaceCurrent in [true, false] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
                photos: f.photos, mode: .writeToXMPSidecar)
            let service = DevelopTemplateBatchAdmissionService(captureService: f.service,
                store: .init(directory: f.root.appendingPathComponent("Admission")),
                configurationRevision: { "native-v1" }, validateSession: { _ in })
            let review = try await service.review(capture)
            let target = capture.intent.requests[replaceCurrent ? 0 : 1].imageURL
            let original = try Data(contentsOf: target)
            let execution = DevelopTemplateBatchExecutionService(write: { request, _, validate in
                do {
                    try await validate()
                    await Task.yield()
                    try original.write(to: target, options: .atomic)
                    try await validate()
                    Issue.record("Changed exact generation must refuse worker preeffect admission")
                    return .init(requestID: request.id)
                } catch {
                    return .init(requestID: request.id, failure: error.localizedDescription)
                }
            })
            let checkpoints = DevelopTemplateBatchCheckpointStore(directory: f.root.appendingPathComponent("Checkpoints"))
            let result = try await service.execute(review, consent: { _ in }, executionService: execution,
                checkpointStore: checkpoints)
            #expect(result.outcome == .failed && result.completedCount == 0)
            #expect(result.results[0]?.requiresRecovery == false && result.results[1] == nil)
            #expect(try await checkpoints.load(capture.intent.id).outcome == .failed)
        }
    }

    @Test("Admission registry rejects unknown envelope fields without rewriting retained evidence")
    func nativeAdmissionStrictJournal() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
            photos: f.photos, mode: .writeToXMPSidecar)
        let directory = f.root.appendingPathComponent("Admission")
        let store = DevelopTemplateBatchAdmissionStore(directory: directory)
        _ = try await store.retain(.init(capture: capture, configurationRevision: "native-v1"))
        let url = directory.appendingPathComponent("operations.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["unrecognizedFutureAuthority"] = true
        let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try changed.write(to: url)
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.corruptJournal) { try await store.load(capture.intent.id) }
        await #expect(throws: DevelopTemplateBatchAdmissionFailure.corruptJournal) {
            try await store.finishReview(capture.intent.id, digest: "unused", cancelled: false)
        }
        #expect(try Data(contentsOf: url) == changed)
    }

    @Test("Native reviewed admission refuses embedded destinations until owned-effect stages are wired")
    func nativeEmbeddedAdmissionRefusal() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for mode in [MetadataWriteMode.writeToFile, .writeToFileAndXMPSidecar] {
            let capture = try f.service.capture(templateID: f.template.id, templateRevision: f.revision,
                photos: f.photos, mode: mode)
            let directory = f.root.appendingPathComponent("Admission")
            let service = DevelopTemplateBatchAdmissionService(captureService: f.service,
                store: .init(directory: directory), configurationRevision: { "native-v1" }, validateSession: { _ in })
            await #expect(throws: DevelopTemplateBatchAdmissionFailure.unsupportedEmbeddedAdmission) {
                try await service.review(capture)
            }
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }
}
