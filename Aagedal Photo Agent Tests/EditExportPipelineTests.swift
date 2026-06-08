import Testing
import Foundation
import AppKit
@testable import Aagedal_Photo_Agent

/// Verifies the shared export pipeline both renders a file AND overlays pending IPTC
/// sidecar edits onto the output. The overlay is the step the FTP "publish to web"
/// path used to skip, which dropped edited keywords/captions from uploaded files;
/// routing every export path through `renderItem` is what fixed that. Drives the real
/// renderer, write engine, and sidecar services against files on disk.
@Suite("EditExportPipeline render + sidecar overlay (real file)")
struct EditExportPipelineTests {

    /// Creates a unique temp working directory with a minimal valid JPEG inside it.
    /// Generated in-process so no binary fixture lives in the repo. The caller removes
    /// `dir`.
    private func makeWorkspace() throws -> (dir: URL, source: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-export-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("photo.jpg")
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let data = rep.representation(using: .jpeg, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: source)
        return (dir, source)
    }

    /// The core guarantee behind the FTP fix: pending edits that live only in a sidecar
    /// (not in the source file's own metadata) must land on the rendered output.
    @Test("renderItem overlays pending XMP sidecar keywords and title onto the rendered file")
    func renderItemAppliesSidecarIPTC() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sidecar = IPTCMetadata(title: "Aurora over the fjord",
                                   keywords: ["aurora", "fjord"],
                                   creator: "Tester")
        try XMPSidecarService().saveSidecar(metadata: sidecar, for: source)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source, cameraRaw: nil, kind: .jpeg,
            outputFolder: outDir, folderURL: source.deletingLastPathComponent(),
            writeEngine: SwiftExifWriteEngine(), failureTracker: tracker)

        #expect(FileManager.default.fileExists(atPath: rendered.path))
        // Rendered output goes to a separate folder, so it can keep the source's name.
        #expect(rendered.deletingLastPathComponent() == outDir)
        #expect(await tracker.sidecarOverlayFailures.isEmpty)

        let meta = try await SwiftExifReadService().readFullMetadata(url: rendered)
        #expect(Set(meta.keywords) == Set(["aurora", "fjord"]))
        #expect(meta.title == "Aurora over the fjord")
    }

    /// The sidecar is the authoritative edited state on export: a descriptive field the
    /// user cleared (absent from the sidecar) must be stripped from the rendered output,
    /// not survive from the source file's own embedded metadata.
    @Test("renderItem clears a descriptive field the sidecar no longer carries")
    func renderItemClearsRemovedSidecarField() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = SwiftExifWriteEngine()
        // Embed a caption + keywords directly in the source file.
        try await engine.writeFields(
            [.headline: "Headline stays", .description: "Caption to clear", .subject: "old1, old2"],
            to: [source])

        // Sidecar keeps the headline but drops the caption and keywords (user cleared them).
        try XMPSidecarService().saveSidecar(metadata: IPTCMetadata(title: "Headline stays"), for: source)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source, cameraRaw: nil, kind: .jpeg,
            outputFolder: outDir, folderURL: source.deletingLastPathComponent(),
            writeEngine: engine, failureTracker: tracker)

        #expect(await tracker.sidecarOverlayFailures.isEmpty)
        let meta = try await SwiftExifReadService().readFullMetadata(url: rendered)
        #expect(meta.title == "Headline stays")
        #expect(meta.description?.isEmpty ?? true)
        #expect(meta.keywords.isEmpty)
    }

    /// GPS is technical source data the overlay treats as additive: a sidecar that doesn't
    /// carry coordinates must not strip the camera GPS embedded in the source file.
    @Test("renderItem preserves source GPS when the sidecar carries none")
    func renderItemPreservesSourceGPS() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = SwiftExifWriteEngine()
        // Embed southern/western coordinates in the source (sign-sensitive).
        try await engine.writeFields(
            [.gpsLatitude: "33.8688", .gpsLatitudeRef: "S",
             .gpsLongitude: "151.2093", .gpsLongitudeRef: "E"],
            to: [source])

        // Sidecar has descriptive edits but no GPS.
        try XMPSidecarService().saveSidecar(metadata: IPTCMetadata(title: "Sydney"), for: source)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source, cameraRaw: nil, kind: .jpeg,
            outputFolder: outDir, folderURL: source.deletingLastPathComponent(),
            writeEngine: engine, failureTracker: tracker)

        let meta = try await SwiftExifReadService().readFullMetadata(url: rendered)
        #expect(meta.title == "Sydney")
        let lat = try #require(meta.latitude)
        let lon = try #require(meta.longitude)
        #expect(abs(lat - (-33.8688)) < 0.001)
        #expect(abs(lon - 151.2093) < 0.001)
    }

    /// Sidecar-master is the default, but if the image file was modified more recently than
    /// the .xmp AND they disagree, the sidecar looks stale (e.g. Adobe Bridge wrote into the
    /// file after the sidecar was made): the embedded values win and a warning is recorded.
    @Test("renderItem skips a stale .xmp sidecar, keeps embedded values, and warns")
    func renderItemSkipsStaleSidecar() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = SwiftExifWriteEngine()
        // Embedded (file) metadata — stands in for an external tool editing the file directly.
        try await engine.writeFields([.headline: "Embedded headline"], to: [source])
        // An older sidecar that disagrees with the file.
        try XMPSidecarService().saveSidecar(metadata: IPTCMetadata(title: "Sidecar headline"), for: source)

        // Force the image file to look newer than the sidecar.
        let sidecarURL = XMPSidecarService().sidecarURL(for: source)
        let sidecarDate = try #require(
            (try FileManager.default.attributesOfItem(atPath: sidecarURL.path))[.modificationDate] as? Date)
        try FileManager.default.setAttributes(
            [.modificationDate: sidecarDate.addingTimeInterval(60)], ofItemAtPath: source.path)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source, cameraRaw: nil, kind: .jpeg,
            outputFolder: outDir, folderURL: source.deletingLastPathComponent(),
            writeEngine: engine, failureTracker: tracker)

        #expect(await tracker.staleSidecarWarnings == [source.lastPathComponent])
        #expect(await tracker.sidecarOverlayFailures.isEmpty)
        let meta = try await SwiftExifReadService().readFullMetadata(url: rendered)
        #expect(meta.title == "Embedded headline")
    }

    /// With no sidecar there are no pending edits to apply: the overlay must be a no-op
    /// that still succeeds (no spurious failure recorded).
    @Test("renderItem succeeds and records no overlay failure when there is no sidecar")
    func renderItemWithoutSidecar() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source, cameraRaw: nil, kind: .jpeg,
            outputFolder: outDir, folderURL: source.deletingLastPathComponent(),
            writeEngine: SwiftExifWriteEngine(), failureTracker: tracker)

        #expect(FileManager.default.fileExists(atPath: rendered.path))
        #expect(await tracker.sidecarOverlayFailures.isEmpty)
    }
}

@Suite("SidecarReconciliation descriptive diff")
struct SidecarReconciliationTests {
    @Test("identical descriptive fields don't differ (keywords order-insensitive)")
    func identical() {
        let a = IPTCMetadata(title: "T", keywords: ["x", "y"], creator: "C")
        let b = IPTCMetadata(title: "T", keywords: ["y", "x"], creator: "C")
        #expect(!SidecarReconciliation.descriptiveFieldsDiffer(a, b))
    }

    @Test("a changed descriptive field is detected")
    func changed() {
        let a = IPTCMetadata(title: "T", description: "old")
        let b = IPTCMetadata(title: "T", description: "new")
        #expect(SidecarReconciliation.descriptiveFieldsDiffer(a, b))
    }

    @Test("GPS-only differences are ignored — GPS isn't descriptive")
    func gpsIgnored() {
        let a = IPTCMetadata(title: "T", latitude: 10, longitude: 20)
        let b = IPTCMetadata(title: "T", latitude: -10, longitude: -20)
        #expect(!SidecarReconciliation.descriptiveFieldsDiffer(a, b))
    }
}
