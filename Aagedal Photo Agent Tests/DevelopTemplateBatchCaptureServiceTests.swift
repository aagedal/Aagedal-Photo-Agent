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
}
