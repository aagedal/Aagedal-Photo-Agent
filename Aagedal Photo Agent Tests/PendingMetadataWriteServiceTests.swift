import AppKit
import Foundation
import SwiftMediaMetadata
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Pending metadata verified completion", .serialized)
struct PendingMetadataWriteServiceTests {
    private func fixture() async throws -> (URL, URL, MetadataSidecar) {
        let folder = URL(fileURLWithPath: "/private/tmp/PendingWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("photo.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
        let record = MetadataSidecar(sourceFile: image.lastPathComponent, pendingChanges: true,
            metadata: IPTCMetadata(title: "Pending headline", description: "Pending caption"),
            imageMetadataSnapshot: nil)
        let installed = try MetadataSidecarService().saveSidecar(record, for: image, in: folder)
        return (folder, image, installed)
    }
    private func request(_ image: URL, _ record: MetadataSidecar, skip: Bool = true) -> PendingMetadataWriteRequest {
        .init(imageURL: image, folderURL: image.deletingLastPathComponent(), expectedSidecar: record, skipC2PA: skip)
    }
    private func json(_ image: URL) -> URL {
        image.deletingLastPathComponent().appendingPathComponent(".photo_metadata/\(image.lastPathComponent).meta.json")
    }
    private nonisolated static func read(_ image: URL) async throws -> IPTCMetadata {
        guard let record = try await SwiftExifReadService().readBatchFullMetadata(urls: [image])[image] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record
    }
    private func service(hooks: PendingMetadataWriteHooks = .init(), c2pa: Bool = false) -> PendingMetadataWriteService {
        .init(writeEngine: SwiftExifWriteEngine(), readSourceFacts: {
            .init(metadata: try await Self.read($0), hasC2PA: c2pa)
        }, hooks: hooks)
    }

    @Test("Embedded completion mirrors shadowing XMP and preserves nil baseline, history and opaque JSON")
    func embeddedCompletion() async throws {
        let (folder, image, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var pending = record
        pending.history = [.init(timestamp: Date(), fieldName: "Headline", oldValue: nil, newValue: "Pending headline")]
        pending = try MetadataSidecarService().saveSidecar(pending, for: image, in: folder)
        var graph = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json(image))) as? [String: Any])
        graph["opaque"] = ["keep": [1, 2, 3]]
        try JSONSerialization.data(withJSONObject: graph).write(to: json(image))
        var physical = try ImageMetadata.read(from: image)
        physical.setOrientation(6)
        var embeddedXMP = physical.xmp ?? XMPData()
        embeddedXMP.tiffOrientation = "6"
        embeddedXMP.setValue(.simple("6"), namespace: XMPNamespace.exif, property: "Orientation")
        embeddedXMP.setValue(.simple("1.25"), namespace: XMPNamespace.crs, property: "Exposure2012")
        embeddedXMP.setValue(.simple("embedded private"), namespace: "https://example.test/technical/", property: "Keep")
        let embeddedMask = MaskAdjustment(name: "Embedded mask", geometry: EllipseMaskGeometry())
        XMPDataBuilder.applyMasks([embeddedMask], preserved: [], into: &embeddedXMP)
        physical.xmp = embeddedXMP
        try physical.write(to: image)
        let embeddedBefore = try ImageMetadata.read(from: image)
        #expect(embeddedBefore.exif?.orientation == 6)
        var xmp = XMPData(); xmp.headline = "Old shadow"
        xmp.tiffOrientation = "3"
        xmp.setValue(.simple("3"), namespace: XMPNamespace.exif, property: "Orientation")
        xmp.setValue(.simple("-0.5"), namespace: XMPNamespace.crs, property: "Exposure2012")
        let sidecarMask = MaskAdjustment(name: "Sidecar mask", geometry: EllipseMaskGeometry())
        XMPDataBuilder.applyMasks([sidecarMask], preserved: [], into: &xmp)
        xmp.setValue(.simple("opaque"), namespace: "https://example.test/private/", property: "Keep")
        try Data(XMPWriter.generateXML(xmp).utf8).write(to: XMPSidecarService().sidecarURL(for: image))
        let result = await service().execute(request(image, pending))
        #expect(result.completed)
        #expect(result.didWriteEmbedded && result.didWriteXMP)
        #expect(result.installedSidecar?.imageMetadataSnapshot == nil)
        #expect(result.installedSidecar?.history.count == 1)
        #expect(try await Self.read(image).title == pending.metadata.title)
        let embeddedAfter = try ImageMetadata.read(from: image)
        #expect(embeddedAfter.exif?.orientation == 6)
        #expect(embeddedAfter.xmp?.tiffOrientation == "6")
        #expect(embeddedAfter.xmp?.simpleValue(namespace: XMPNamespace.exif, property: "Orientation") == "6")
        #expect(embeddedAfter.xmp?.simpleValue(namespace: XMPNamespace.crs, property: "Exposure2012") == "1.25")
        #expect(embeddedAfter.xmp?.simpleValue(namespace: "https://example.test/technical/", property: "Keep") == "embedded private")
        #expect(embeddedAfter.xmp?.structuredArrayValue(namespace: XMPNamespace.crs, property: "MaskGroupBasedCorrections")
            == embeddedBefore.xmp?.structuredArrayValue(namespace: XMPNamespace.crs, property: "MaskGroupBasedCorrections"))
        let mirrored = try XMPReader.readFromXML(Data(contentsOf: XMPSidecarService().sidecarURL(for: image)))
        #expect(mirrored.tiffOrientation == "3")
        #expect(mirrored.simpleValue(namespace: XMPNamespace.exif, property: "Orientation") == "3")
        #expect(mirrored.simpleValue(namespace: XMPNamespace.crs, property: "Exposure2012") == "-0.5")
        #expect(mirrored.structuredArrayValue(namespace: XMPNamespace.crs, property: "MaskGroupBasedCorrections")
            == xmp.structuredArrayValue(namespace: XMPNamespace.crs, property: "MaskGroupBasedCorrections"))
        let finalGraph = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json(image))) as? [String: Any])
        #expect(finalGraph["opaque"] != nil)
        #expect(try String(contentsOf: XMPSidecarService().sidecarURL(for: image), encoding: .utf8).contains("opaque"))
    }

    @Test("RAW is written to XMP and never silently acknowledged by the embedded engine")
    func rawRoutesToXMP() async throws {
        let (folder, image, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("photo.ARW")
        try Data(contentsOf: image).write(to: raw)
        var pending = record; pending.sourceFile = raw.lastPathComponent
        pending = try MetadataSidecarService().saveSidecar(pending, for: raw, in: folder)
        let before = try Data(contentsOf: raw)
        // A proven source-facts seam avoids claiming this synthetic PNG container is camera RAW.
        let worker = PendingMetadataWriteService(writeEngine: SwiftExifWriteEngine(), readSourceFacts: { _ in
            .init(metadata: IPTCMetadata(), hasC2PA: false)
        })
        let result = await worker.execute(request(raw, pending))
        #expect(result.completed && result.didWriteXMP && !result.didWriteEmbedded)
        #expect(try Data(contentsOf: raw) == before)
        #expect(result.installedSidecar?.pendingChanges == false)
        #expect(FileManager.default.fileExists(atPath: json(raw).path))
    }

    @Test("Rating, explicit label clear and punctuated lists are represented exactly")
    func editorialValues() async throws {
        let (folder, image, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var original = try ImageMetadata.read(from: image)
        var originalXMP = original.xmp ?? XMPData(); originalXMP.label = "Select"
        original.xmp = originalXMP
        try original.write(to: image)
        #expect(try ImageMetadata.read(from: image).xmp?.label == "Select")
        var pending = record
        pending.metadata.rating = 4; pending.metadata.label = ""
        pending.metadata.personShown = ["Doe, Jane", "Alpha;Beta"]
        pending.metadata.keywords = ["First, second", "Third;fourth"]
        pending = try MetadataSidecarService().saveSidecar(pending, for: image, in: folder)
        let result = await service().execute(request(image, pending))
        #expect(result.completed)
        let physical = try await Self.read(image)
        #expect(physical.rating == 4)
        #expect(try ImageMetadata.read(from: image).xmp?.label == "")
        #expect(physical.personShown == pending.metadata.personShown)
        #expect(physical.keywords == pending.metadata.keywords)
    }

    @Test("Post-embedded XMP failure retains the exact pending record and reports physical work")
    func partialMirrorFailure() async throws {
        let (folder, image, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: json(image))
        var hooks = PendingMetadataWriteHooks()
        hooks.beforeXMPCommit = { throw CocoaError(.fileWriteNoPermission) }
        let result = await service(hooks: hooks).execute(request(image, record))
        #expect(!result.completed && result.didWriteEmbedded && result.failure != nil)
        #expect(try Data(contentsOf: json(image)) == before)
    }

    @Test("Newer JSON at engine admission prevents any physical write")
    func newerDraft() async throws {
        let (folder, image, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: image)
        var hooks = PendingMetadataWriteHooks()
        hooks.afterAdmission = {
            var newer = record; newer.metadata.credit = "New writer"
            try MetadataSidecarService().saveSidecar(newer, for: image, in: folder)
        }
        let result = await service(hooks: hooks).execute(request(image, record))
        #expect(!result.completed && !result.embeddedWriteMayHaveOccurred)
        #expect(try Data(contentsOf: image) == before)
        #expect(MetadataSidecarService().loadSidecar(for: image, in: folder)?.metadata.credit == "New writer")
    }

    @Test("Source replacement at finalization retains pending despite a completed embedded write")
    func sourceFinalizationConflict() async throws {
        let (folder, image, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var hooks = PendingMetadataWriteHooks()
        hooks.afterEmbeddedWrite = { try Data("external replacement".utf8).write(to: image) }
        let result = await service(hooks: hooks).execute(request(image, record))
        #expect(!result.completed && result.didWriteEmbedded)
        #expect(MetadataSidecarService().loadSidecar(for: image, in: folder)?.pendingChanges == true)
    }

    @Test("C2PA skip and pending rotation both preserve source and draft")
    func admissionRefusals() async throws {
        let (folder, image, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: image)
        let skipped = await service(c2pa: true).execute(request(image, record))
        #expect(skipped.wasSkipped && !skipped.completed)
        let allowed = await service(c2pa: true).execute(request(image, record, skip: false))
        #expect(allowed.completed)
        let draft = MetadataOrientationDraft(expectedOrientation: 1, targetOrientation: 6)
        let pending = try MetadataSidecarService().saveSidecar(record, for: image, in: folder,
            orientationMutation: .replace(expected: nil, with: draft))
        let rotatedBefore = try Data(contentsOf: image)
        let refused = await service().execute(request(image, pending))
        #expect(!refused.completed && !refused.didWriteEmbedded)
        #expect(try Data(contentsOf: image) == rotatedBefore)
        #expect(before != rotatedBefore)
    }

    @Test("Strict discovery returns readable drafts alongside malformed carriers and accepts physical path spellings")
    func discovery() async throws {
        let (folder, image, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = json(image).deletingLastPathComponent().appendingPathComponent("broken.png.meta.json")
        try Data("{bad".utf8).write(to: broken)
        let result = await MetadataSidecarService().discoverPendingSidecars(in: URL(fileURLWithPath: folder.path))
        #expect(result.records.count == 1)
        #expect(result.failures.count == 1)
        #expect(!result.wasCancelled)
        let symlink = json(image).deletingLastPathComponent().appendingPathComponent("linked.png.meta.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: json(image))
        let linked = await MetadataSidecarService().discoverPendingSidecars(in: folder)
        #expect(linked.failures.count == 2)
    }
    @Test("Source mutation immediately before XMP commit does not overwrite the companion")
    func beforeXMPSourceConflict() async throws {
        let (folder, image, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let xmpURL = XMPSidecarService().sidecarURL(for: image)
        var xmp = XMPData(); xmp.headline = "Keep companion"
        let xmpBytes = Data(XMPWriter.generateXML(xmp).utf8)
        try xmpBytes.write(to: xmpURL)
        let jsonBytes = try Data(contentsOf: json(image))
        var hooks = PendingMetadataWriteHooks()
        hooks.beforeXMPCommit = { try Data("external source".utf8).write(to: image) }
        let result = await service(hooks: hooks).execute(request(image, record))
        #expect(!result.completed && result.didWriteEmbedded && !result.didWriteXMP)
        #expect(try Data(contentsOf: xmpURL) == xmpBytes)
        #expect(try Data(contentsOf: json(image)) == jsonBytes)
    }

    @Test("Post-install verification failure exposes durable but unverified completion")
    func committedJSONReceipt() async throws {
        let (folder, image, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var hooks = PendingMetadataWriteHooks()
        hooks.afterJSONCommit = { throw CocoaError(.fileReadNoPermission) }
        let result = await service(hooks: hooks).execute(request(image, record))
        #expect(!result.completed && result.didWriteEmbedded)
        #expect(result.installedSidecar == nil)
        #expect(result.committedButUnverifiedSidecarURL != nil)
        #expect(MetadataSidecarService().loadSidecar(for: image, in: folder)?.pendingChanges == false)
    }

    @Test("Cancellation after verified embedded write retains pending and physical receipt")
    func cancelledAfterEmbeddedWrite() async throws {
        let (folder, image, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var hooks = PendingMetadataWriteHooks()
        hooks.afterEmbeddedWrite = { throw CancellationError() }
        let result = await service(hooks: hooks).execute(request(image, record))
        #expect(result.wasCancelled && result.didWriteEmbedded && !result.completed)
        #expect(MetadataSidecarService().loadSidecar(for: image, in: folder)?.pendingChanges == true)
    }

    @Test("Exact XMP baseline rejects independent descriptive changes and explicit absent baselines")
    func exactXMPAdmission() async throws {
        let (folder, image, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = XMPSidecarService().sidecarURL(for: image)
        var xmp = XMPData(); xmp.headline = "First physical headline"
        let original = Data(XMPWriter.generateXML(xmp).utf8)
        let technical = XMPSidecarService().loadSidecar(fromData: original)
        xmp.headline = "Independent changed headline"
        let changed = Data(XMPWriter.generateXML(xmp).utf8)
        try changed.write(to: url)
        for expected in [XMPSidecarWriteSnapshot(data: original), .init(data: nil)] {
            var rejected = false
            do {
                _ = try await MetadataSidecarService().captureWriteCompletionSnapshot(for: image,
                    in: folder, expectedSidecar: record, expectedTechnicalMetadata: technical,
                    expectedXMPSnapshot: expected)
            } catch { rejected = true }
            #expect(rejected)
            #expect(try Data(contentsOf: url) == changed)
            #expect(MetadataSidecarService().loadSidecar(for: image, in: folder)?.pendingChanges == true)
        }
    }

}
