import CoreGraphics
import Foundation
import ImageIO
import SwiftMediaMetadata
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Read-only exact-plan XMP candidate verification")
struct MCPIPTCPatchXMPPreflightServiceTests {
    final class Fixture {
        let root: URL
        let photo: URL
        let facade: MCPAutomationFacade
        let plans = MCPIPTCPatchPlanStore()
        let planID: String

        init(pending: Bool = false, existingXMP: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("xmp-preflight-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            photo = root.appendingPathComponent("photo.jpg")
            let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8,
                bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try #require(context.makeImage())
            let bytes = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            try #require(CGImageDestinationFinalize(destination))
            try (bytes as Data).write(to: photo)
            var xmp = XMPData()
            xmp.setValue(.simple("Before"), namespace: XMPNamespace.photoshop, property: "Headline")
            xmp.setValue(.simple("retain"), namespace: "https://example.test/private/", property: "Desk")
            xmp.setValue(.simple("0.75"), namespace: XMPNamespace.crs, property: "Exposure2012")
            xmp.setValue(.simple("6"), namespace: XMPNamespace.tiff, property: "Orientation")
            if existingXMP {
                try Data(XMPWriter.generateXML(xmp).utf8).write(to: photo.deletingPathExtension().appendingPathExtension("xmp"))
            }
            if pending {
                var metadata = try #require(XMPSidecarService().loadSidecar(for: photo))
                metadata.credit = "Pending unedited credit"
                _ = try MetadataSidecarService().saveSidecar(MetadataSidecar(sourceFile: photo.lastPathComponent,
                    pendingChanges: true, metadata: metadata, imageMetadataSnapshot: metadata), for: photo, in: root)
            }
            let box = MCPServerCoreTests.DataBox()
            let store = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
            try store.addRoot(root); try store.setEnabled(true)
            facade = MCPAutomationFacade(authorizationStore: store)
            let read = try #require(MCPMetadataSnapshotReader.inspectPhoto(path: photo.path, facade: facade).objectValue)
            var arguments: [String: MCPJSONValue] = ["path": .string(photo.path), "operations": .array([
                .object(["field": .string("title"), "operation": .string("set"), "value": .string("After")])])]
            for key in ["sourceRevision", "xmpSidecarRevision", "appSidecarRevision"] { arguments[key] = read[key] }
            let preview = try MCPIPTCPatchPreparation.prepare(arguments: arguments, facade: facade, plans: plans)
            planID = try #require(preview.objectValue?["planID"]?.stringValue)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test("A missing XMP sidecar is staged without creating a live sidecar")
    func missingSidecar() async throws {
        let fixture = try Fixture(existingXMP: false)
        let report = try await MCPIPTCPatchXMPPreflightService(plans: fixture.plans, facade: fixture.facade)
            .inspect(planID: fixture.planID)
        #expect(report.stagedByteCount > 0)
        #expect(!FileManager.default.fileExists(atPath: report.targetPath))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".photo_metadata").path))
    }

    @Test("Production staging retains technical and opaque XMP without touching live carriers", arguments: [false, true])
    func candidate(pending: Bool) async throws {
        let fixture = try Fixture(pending: pending)
        let before = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        let report = try await MCPIPTCPatchXMPPreflightService(plans: fixture.plans, facade: fixture.facade)
            .inspect(planID: fixture.planID)
        let after = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(report.planID == fixture.planID)
        #expect(report.targetPath == fixture.root.appendingPathComponent("photo.xmp").path)
        #expect(report.stagedByteCount > 0)
        #expect(report.stagedSHA256.count == 64)
        #expect(report.warnings.contains { $0.contains("pending draft") } == pending)
        #expect(before.sourceBytes == after.sourceBytes)
        #expect(before.xmpBytes == after.xmpBytes)
        #expect(before.appSidecarBytes == after.appSidecarBytes)
    }

    @Test("Changed carriers during staging invalidate the report")
    func rejectsDrift() async throws {
        let fixture = try Fixture()
        let photo = fixture.photo
        let service = MCPIPTCPatchXMPPreflightService(plans: fixture.plans, facade: fixture.facade,
            hooks: .init(afterStaging: { _ in try Data("changed".utf8).write(to: photo) }))
        await #expect(throws: (any Error).self) { try await service.inspect(planID: fixture.planID) }
    }

    @Test("Wrong staged editorial values refuse before returning a successful report")
    func rejectsChangedCandidate() async throws {
        let fixture = try Fixture()
        let service = MCPIPTCPatchXMPPreflightService(plans: fixture.plans, facade: fixture.facade,
            hooks: .init(afterStaging: { url in
                var xmp = try XMPReader.readFromXML(Data(contentsOf: url))
                xmp.setValue(.simple("Wrong"), namespace: XMPNamespace.photoshop, property: "Headline")
                try Data(XMPWriter.generateXML(xmp).utf8).write(to: url)
            }))
        await #expect(throws: (any Error).self) { try await service.inspect(planID: fixture.planID) }
    }

    @Test("Unknown properties and technical orientation cannot change in a candidate", arguments: ["Desk", "Orientation"])
    func preservationRefuses(property: String) throws {
        var original = XMPData()
        let namespace = property == "Desk" ? "https://example.test/private/" : XMPNamespace.tiff
        original.setValue(.simple("1"), namespace: namespace, property: property)
        var changed = original
        changed.setValue(.simple("2"), namespace: namespace, property: property)
        #expect(throws: (any Error).self) {
            try MCPIPTCPatchXMPPreflightService.verifyPreservation(
                before: Data(XMPWriter.generateXML(original).utf8), after: Data(XMPWriter.generateXML(changed).utf8))
        }
    }
}
