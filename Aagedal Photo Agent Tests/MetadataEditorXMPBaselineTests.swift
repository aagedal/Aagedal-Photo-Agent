import AppKit
import Foundation
import SwiftMediaMetadata
import Testing
@testable import Aagedal_Photo_Agent

private actor XMPBaselineWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var paused: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

private nonisolated final class XMPBaselineHeldWriter: MetadataWriteEngine {
    let gate: XMPBaselineWriteGate
    init(gate: XMPBaselineWriteGate) { self.gate = gate }
    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        await gate.wait()
        try await SwiftExifWriteEngine().writeFields(fields, to: urls, structuredData: structuredData)
    }
    func writeFieldsToRenderedFiles(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {}
    func addRemoveListValues(add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]], to urls: [URL]) async throws {}
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws {}
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws {}
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws {}
    func stripIPTCAndXMP(from urls: [URL]) async throws {}
    func copyMetadataToRenderedFile(from source: URL, to destination: URL, bakedCameraRaw: CameraRawSettings?) async throws {}
}

@Suite("Metadata editor exact loaded XMP baseline", .serialized)
@MainActor
struct MetadataEditorXMPBaselineTests {
    enum Route: String, CaseIterable, Sendable { case history, xmp, embedded }
    private struct Fixture {
        let folder: URL
        let image: URL
        let xmp: URL
        let json: URL
        let model: MetadataViewModel
    }
    private func fixture(masked: Bool = true, title: String = "Pending headline", writeEngine: any MetadataWriteEngine = SwiftExifWriteEngine()) throws -> Fixture {
        let folder = URL(fileURLWithPath: "/private/tmp/Editor-XMP-Baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("photo.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
        let pending = IPTCMetadata(title: title, description: "Keep pending caption")
        try MetadataSidecarService().saveSidecar(.init(sourceFile: image.lastPathComponent,
            pendingChanges: true, metadata: pending, imageMetadataSnapshot: nil), for: image, in: folder)
        if masked {
            var physical = pending
            var settings = CameraRawSettings(); settings.exposure2012 = 0.5
            var mask = MaskAdjustment(name: "QA ellipse", geometry: EllipseMaskGeometry())
            mask.exposure = 0.25
            settings.localAdjustments = [mask]
            physical.cameraRaw = settings; physical.exifOrientation = 6
            try XMPSidecarService().saveSidecar(metadata: physical, for: image)
        }
        return .init(folder: folder, image: image, xmp: image.deletingPathExtension().appendingPathExtension("xmp"),
            json: folder.appendingPathComponent(".photo_metadata/\(image.lastPathComponent).meta.json"),
            model: MetadataViewModel(readService: SwiftExifReadService(), writeEngine: writeEngine,
                variableOptions: { .init(ordinaryMode: .writeToXMPSidecar, credentialMode: .writeToXMPSidecar,
                    rawMode: .writeToXMPSidecar, credentialRawMode: .writeToXMPSidecar, initials: "QA",
                    addJobIDToKeywords: false, approvedKeywords: [:], strictKeywords: false) }))
    }
    private func load(_ model: MetadataViewModel, image: URL, folder: URL) async throws {
        model.loadMetadata(for: [ImageFile(url: image)], folderURL: folder)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!model.isLoading)
        try #require(model.metadata != nil)
    }
    private func save(_ fixture: Fixture, route: Route) async -> MetadataCommitResult {
        if route == .history {
            fixture.model.saveToSidecar()
            let deadline = ContinuousClock.now + .seconds(10)
            while fixture.model.isSaving, ContinuousClock.now < deadline { await Task.yield() }
            if fixture.model.isSaving { return .failed(message: "Timed out") }
            return fixture.model.saveError.map { .failed(message: $0) } ?? .succeeded
        }
        return await withCheckedContinuation { continuation in
            fixture.model.commitEditsReportingResult(mode: route == .xmp ? .writeToXMPSidecar : .writeToFile) {
                continuation.resume(returning: $0)
            }
        }
    }
    private func record(_ f: Fixture) throws -> MetadataSidecar {
        try #require(MetadataSidecarService().loadSidecar(for: f.image, in: f.folder))
    }

    @Test("Unchanged masked XMP admits all three save routes and their subsequent own writes", arguments: Route.allCases)
    func unchangedMaskedAndRepeatedSave(route: Route) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
        try await load(f.model, image: f.image, folder: f.folder)
        let reparsed = try #require(XMPSidecarService().loadSidecar(for: f.image))
        #expect(f.model.xmpMetadata?.cameraRaw != reparsed.cameraRaw)
        try #require(f.model.editingMetadata.cameraRaw?.localAdjustments?.count == 1)
        f.model.editingMetadata.cameraRaw?.exposure2012 = 0.75
        f.model.markChanged()
        #expect(await save(f, route: route) == .succeeded)
        var physical = try #require(XMPSidecarService().loadSidecar(for: f.image))
        #expect(physical.cameraRaw?.exposure2012 == 0.75)
        #expect(physical.cameraRaw?.localAdjustments?.count == 1)
        #expect(physical.description == "Keep pending caption")
        #expect(physical.exifOrientation == 6)
        if route == .history {
            #expect(try record(f).imageMetadataSnapshot == nil)
            #expect(try record(f).pendingChanges)
        }
        f.model.editingMetadata.title = "Second own save"
        f.model.markChanged()
        #expect(await save(f, route: route) == .succeeded)
        physical = try #require(XMPSidecarService().loadSidecar(for: f.image))
        #expect(physical.title == "Second own save")
        #expect(physical.cameraRaw?.exposure2012 == 0.75)
        #expect(physical.cameraRaw?.localAdjustments?.count == 1)
        #expect(try record(f).metadata.description == "Keep pending caption")
    }

    @Test("External XMP edits are refused against loaded bytes before either destination changes", arguments: Route.allCases)
    func externalChangedBytes(route: Route) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
        try await load(f.model, image: f.image, folder: f.folder)
        var external = try #require(XMPSidecarService().loadSidecar(for: f.image))
        external.cameraRaw?.exposure2012 = 1.5; external.credit = "Independent writer"
        try XMPSidecarService().saveSidecar(metadata: external, for: f.image)
        let imageBytes = try Data(contentsOf: f.image), xmpBytes = try Data(contentsOf: f.xmp), jsonBytes = try Data(contentsOf: f.json)
        f.model.editingMetadata.title = "Unsaved editor change"; f.model.markChanged()
        let result = await save(f, route: route)
        guard case .failed(let message) = result else { Issue.record("Expected stale loaded revision failure"); return }
        #expect(message.contains("changed"))
        #expect(try Data(contentsOf: f.image) == imageBytes)
        #expect(try Data(contentsOf: f.xmp) == xmpBytes)
        #expect(try Data(contentsOf: f.json) == jsonBytes)
        #expect(f.model.editingMetadata.title == "Unsaved editor change")
    }

    @Test("Loaded absence is evidence; external XMP creation cannot become a fresh save baseline", arguments: Route.allCases)
    func externalCreation(route: Route) async throws {
        let f = try fixture(masked: false); defer { try? FileManager.default.removeItem(at: f.folder) }
        try await load(f.model, image: f.image, folder: f.folder)
        try XMPSidecarService().saveSidecar(metadata: IPTCMetadata(title: "External created carrier"), for: f.image)
        let before = try Data(contentsOf: f.xmp), json = try Data(contentsOf: f.json), image = try Data(contentsOf: f.image)
        f.model.editingMetadata.title = "My edit"; f.model.markChanged()
        guard case .failed = await save(f, route: route) else { Issue.record("Expected newly created XMP conflict"); return }
        #expect(try Data(contentsOf: f.xmp) == before)
        #expect(try Data(contentsOf: f.json) == json)
        #expect(try Data(contentsOf: f.image) == image)
    }

    @Test("Verified Caption mirror advances exact evidence without changing loaded mask identity")
    func captionThenTechnicalSave() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
        try await load(f.model, image: f.image, folder: f.folder)
        f.model.editingMetadata.title = "Caption saved headline"; f.model.markChanged()
        let capture = try #require(try f.model.captureCaptionDraftPersistence())
        try await Task.detached { try capture.persist() }.value
        f.model.editingMetadata.cameraRaw?.exposure2012 = 0.8; f.model.markChanged()
        #expect(await save(f, route: .xmp) == .succeeded)
        #expect(XMPSidecarService().loadSidecar(for: f.image)?.cameraRaw?.exposure2012 == 0.8)
    }

    @Test("Caption receipt never blesses external technical changes over the editor baseline")
    func captionPreservingExternalDevelopCannotAuthorizeOldEditor() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
        try await load(f.model, image: f.image, folder: f.folder)
        var external = try #require(XMPSidecarService().loadSidecar(for: f.image))
        external.cameraRaw?.exposure2012 = 1.5
        var replacement = MaskAdjustment(name: "External replacement", geometry: EllipseMaskGeometry()); replacement.exposure = 0.9
        external.cameraRaw?.localAdjustments = [replacement]
        try XMPSidecarService().saveSidecar(metadata: external, for: f.image)
        f.model.editingMetadata.title = "New caption"; f.model.markChanged()
        let capture = try #require(try f.model.captureCaptionDraftPersistence())
        try await Task.detached { try capture.persist() }.value
        let preserved = try Data(contentsOf: f.xmp), json = try Data(contentsOf: f.json)
        f.model.editingMetadata.cameraRaw?.exposure2012 = 0.8; f.model.markChanged()
        guard case .failed(let message) = await save(f, route: .xmp) else { Issue.record("Expected old technical editor conflict"); return }
        #expect(message.contains("technical metadata changed"))
        #expect(try Data(contentsOf: f.xmp) == preserved)
        #expect(try Data(contentsOf: f.json) == json)
    }

    @Test("Old write completion cannot replace another photo's loaded exact evidence")
    func selectionChangeDuringWrite() async throws {
        let gate = XMPBaselineWriteGate()
        let a = try fixture(writeEngine: XMPBaselineHeldWriter(gate: gate))
        let b = try fixture()
        defer { try? FileManager.default.removeItem(at: a.folder); try? FileManager.default.removeItem(at: b.folder) }
        try await load(a.model, image: a.image, folder: a.folder)
        a.model.editingMetadata.title = "A saved"; a.model.markChanged()
        let writing = Task { await save(a, route: .embedded) }
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await gate.paused), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.paused)
        try await load(a.model, image: b.image, folder: b.folder)
        let selectedMetadata = a.model.editingMetadata
        await gate.resume()
        #expect(await writing.value == .succeeded)
        #expect(a.model.editingMetadata == selectedMetadata)
        a.model.editingMetadata.title = "B new title"; a.model.markChanged()
        let selected = Fixture(folder: b.folder, image: b.image, xmp: b.xmp, json: b.json, model: a.model)
        #expect(await save(selected, route: .xmp) == .succeeded)
        #expect(XMPSidecarService().loadSidecar(for: b.image)?.title == "B new title")
    }

    @Test("Missing read evidence remains a visible failure, never inferred absence")
    func unavailableEvidence() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
        let facts = MetadataEditorSourceFacts(imageURL: f.image, xmpMetadata: XMPSidecarService().loadSidecar(for: f.image),
            appSidecar: try record(f), reconciliationVerdict: nil)
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            editorReadService: MetadataEditorReadService(access: .init(read: { _, _, _, _ in facts })))
        try await load(model, image: f.image, folder: f.folder)
        model.editingMetadata.title = "Must stay unsaved"; model.markChanged()
        let before = try Data(contentsOf: f.xmp)
        let result = await save(.init(folder: f.folder, image: f.image, xmp: f.xmp, json: f.json, model: model), route: .history)
        guard case .failed(let message) = result else { Issue.record("Expected missing evidence failure"); return }
        #expect(message.contains("Reload"))
        #expect(try Data(contentsOf: f.xmp) == before)
    }
    @Test("Variable completion cannot bless preserved external Develop state for an old editor")
    func variablePreservingExternalDevelopCannotAuthorizeOldEditor() async throws {
        let f = try fixture(title: "{filename}"); defer { try? FileManager.default.removeItem(at: f.folder) }
        try await load(f.model, image: f.image, folder: f.folder)
        var external = try #require(XMPSidecarService().loadSidecar(for: f.image))
        external.cameraRaw?.exposure2012 = 1.5
        var replacement = MaskAdjustment(name: "External replacement", geometry: EllipseMaskGeometry()); replacement.exposure = 0.9
        external.cameraRaw?.localAdjustments = [replacement]
        try XMPSidecarService().saveSidecar(metadata: external, for: f.image)
        f.model.processVariablesForImages([ImageFile(url: f.image)])
        await f.model.waitForVariableProcessing()
        let outcome = try #require(f.model.variableBatchOutcome)
        try #require(outcome.results.count == 1)
        #expect(outcome.results[0].completed)
        #expect(f.model.saveError?.contains("Reload") == true)
        #expect(XMPSidecarService().loadSidecar(for: f.image)?.title == "photo")
        #expect(XMPSidecarService().loadSidecar(for: f.image)?.cameraRaw?.exposure2012 == 1.5)
        let preserved = try Data(contentsOf: f.xmp), json = try Data(contentsOf: f.json)
        f.model.editingMetadata.cameraRaw?.exposure2012 = 0.8; f.model.markChanged()
        guard case .failed(let message) = await save(f, route: .xmp) else { Issue.record("Expected reload after preserved technical revision"); return }
        #expect(message.contains("Reload"))
        #expect(try Data(contentsOf: f.xmp) == preserved)
        #expect(try Data(contentsOf: f.json) == json)
    }

}
