import Testing
import Foundation
import AppKit
import CoreImage
import ImageIO
import SwiftExif
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

    /// On export the develop settings that were baked into the pixels are re-emitted as a
    /// crs block marked AlreadyApplied="True" (documentation of how the image was edited),
    /// the app/version is stamped via xmp:CreatorTool, and — crucially — re-reading that
    /// rendered file yields NO live cameraRaw, so the baked edits are never applied twice.
    @Test("export embeds baked crs marked AlreadyApplied=True + CreatorTool, and re-reads as un-edited")
    func renderItemEmbedsBakedCRS() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        var baked = CameraRawSettings()
        baked.exposure2012 = 0.5
        baked.contrast2012 = 20
        baked.globalDensity = 35
        baked.sharpness = 50
        baked.clarity2012 = 24
        baked.dehaze = 19
        // HSL is part of the develop edit and must be documented in the baked crs
        // too — including the ACR `Aqua` alias for cyan and a partial channel.
        baked.hslAdjustments = HSLAdjustments(
            red: HSLColorAdjustment(saturation: 25, luminance: -15, hueShift: 10),
            cyan: HSLColorAdjustment(saturation: -40, luminance: nil, hueShift: nil)
        )

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source, cameraRaw: baked, kind: .jpeg,
            outputFolder: outDir, folderURL: source.deletingLastPathComponent(),
            writeEngine: SwiftExifWriteEngine(), failureTracker: tracker)

        let crsNS = "http://ns.adobe.com/camera-raw-settings/1.0/"
        let xmpNS = "http://ns.adobe.com/xap/1.0/"
        let appNS = "http://aagedal.me/ns/photo/1.0/"
        let embedded = try SwiftExif.readMetadata(from: rendered)
        // The baked develop settings are present, but flagged as already applied.
        #expect(embedded.xmp?.simpleValue(namespace: crsNS, property: "AlreadyApplied") == "True")
        #expect(embedded.xmp?.simpleValue(namespace: crsNS, property: "Exposure2012") == "+0.50")
        #expect(embedded.xmp?.simpleValue(namespace: crsNS, property: "Contrast2012") == "+20")
        #expect(embedded.xmp?.simpleValue(namespace: appNS, property: "GlobalDensity") == "+35")
        #expect(embedded.xmp?.simpleValue(namespace: crsNS, property: "Sharpness") == "50")
        #expect(embedded.xmp?.simpleValue(namespace: crsNS, property: "Clarity2012") == "+24")
        #expect(embedded.xmp?.simpleValue(namespace: crsNS, property: "Dehaze") == "+19")
        // HSL: signed ints, ACR `Aqua` for cyan, and only the authored channels.
        #expect(embedded.xmp?.simpleValue(namespace: crsNS, property: "HueAdjustmentRed") == "+10")
        #expect(embedded.xmp?.simpleValue(namespace: crsNS, property: "SaturationAdjustmentRed") == "+25")
        #expect(embedded.xmp?.simpleValue(namespace: crsNS, property: "LuminanceAdjustmentRed") == "-15")
        #expect(embedded.xmp?.simpleValue(namespace: crsNS, property: "SaturationAdjustmentAqua") == "-40")
        #expect(embedded.xmp?.simpleValue(namespace: crsNS, property: "HueAdjustmentAqua") == nil)
        // The producing app + version is recorded.
        let creatorTool = embedded.xmp?.simpleValue(namespace: xmpNS, property: "CreatorTool")
        #expect(creatorTool?.hasPrefix("Aagedal Photo Agent") == true)

        // The guard: reading the exported file back must NOT surface the settings as live
        // edits — otherwise they'd be re-applied on top of the already-baked pixels.
        let reread = try await SwiftExifReadService().readFullMetadata(url: rendered)
        #expect(reread.cameraRaw == nil)
    }

    /// The embedded crs HSL documentation must read back losslessly through the
    /// same dict adapter + shared decoder the app uses on import: a baked JPEG
    /// carrying HSL round-trips every authored channel — including the ACR
    /// `Aqua` (cyan) and custom `SkinTone` aliases and partially-set channels.
    @Test("baked HSL survives an embedded JPEG round-trip through the dict adapter")
    func embeddedHSLRoundtrips() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        var baked = CameraRawSettings()
        baked.hslAdjustments = HSLAdjustments(
            red: HSLColorAdjustment(saturation: 25, luminance: -15, hueShift: 10),
            cyan: HSLColorAdjustment(saturation: -40, luminance: nil, hueShift: nil),
            skinTone: HSLColorAdjustment(saturation: nil, luminance: 12, hueShift: -3)
        )

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source, cameraRaw: baked, kind: .jpeg,
            outputFolder: outDir, folderURL: source.deletingLastPathComponent(),
            writeEngine: SwiftExifWriteEngine(), failureTracker: tracker)

        // Read the embedded crs back through the dict adapter + shared decoder.
        // (The block is AlreadyApplied="True", so the full parser intentionally
        // nils cameraRaw; decode the documented HSL directly to verify it survived.)
        let embedded = try SwiftExif.readMetadata(from: rendered)
        let dict = embedded.asMetadataDict()
        let hsl = try #require(decodeHSLAdjustments { parseIntValue(dict[$0]) })

        #expect(hsl.red == HSLColorAdjustment(saturation: 25, luminance: -15, hueShift: 10))
        #expect(hsl.cyan == HSLColorAdjustment(saturation: -40, luminance: nil, hueShift: nil))
        #expect(hsl.skinTone == HSLColorAdjustment(saturation: nil, luminance: 12, hueShift: -3))
        #expect(hsl.green == nil)
    }

    /// An unedited export (no cameraRaw) carries no crs block but is still stamped with the
    /// producing app via xmp:CreatorTool.
    @Test("unedited export writes no crs block but still stamps CreatorTool")
    func renderItemStampsCreatorToolWithoutEdits() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source, cameraRaw: nil, kind: .jpeg,
            outputFolder: outDir, folderURL: source.deletingLastPathComponent(),
            writeEngine: SwiftExifWriteEngine(), failureTracker: tracker)

        let crsNS = "http://ns.adobe.com/camera-raw-settings/1.0/"
        let xmpNS = "http://ns.adobe.com/xap/1.0/"
        let embedded = try SwiftExif.readMetadata(from: rendered)
        #expect(embedded.xmp?.simpleValue(namespace: crsNS, property: "AlreadyApplied") == nil)
        #expect(embedded.xmp?.simpleValue(namespace: crsNS, property: "Exposure2012") == nil)
        #expect(embedded.xmp?.simpleValue(namespace: xmpNS, property: "CreatorTool")?
            .hasPrefix("Aagedal Photo Agent") == true)
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

    /// A develop-settings-only sidecar (written by `saveCameraRawOnly` after a develop edit
    /// in writeToFile mode) is not an IPTC record. It is typically *newer* than the image
    /// file, so the staleness guard can't help — without the descriptive-content guard its
    /// all-nil fields would force-clear every embedded descriptive value from the render.
    @Test("renderItem keeps embedded IPTC when the sidecar is develop-settings-only")
    func renderItemIgnoresDevelopOnlySidecar() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = SwiftExifWriteEngine()
        try await engine.writeFields(
            [.headline: "Embedded headline", .description: "Embedded caption",
             .subject: "kw1, kw2", .creator: "Tester"],
            to: [source])

        // CRS-only sidecar, written after the file (newer mtime) — the Simple-mode artifact.
        var crs = CameraRawSettings()
        crs.exposure2012 = 0.5
        try XMPSidecarService().saveCameraRawOnly(crs, orientation: 1, for: source)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source, cameraRaw: nil, kind: .jpeg,
            outputFolder: outDir, folderURL: source.deletingLastPathComponent(),
            writeEngine: engine, failureTracker: tracker)

        #expect(await tracker.sidecarOverlayFailures.isEmpty)
        #expect(await tracker.staleSidecarWarnings.isEmpty)
        let meta = try await SwiftExifReadService().readFullMetadata(url: rendered)
        #expect(meta.title == "Embedded headline")
        #expect(meta.description == "Embedded caption")
        #expect(Set(meta.keywords) == Set(["kw1", "kw2"]))
        #expect(meta.creator == "Tester")
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

@Suite("EditedImageRenderer.customSubfolder containment")
struct CustomSubfolderTests {
    private let root = URL(fileURLWithPath: "/Volumes/Photos/Shoot", isDirectory: true)

    private func sub(_ name: String) -> URL {
        EditedImageRenderer.customSubfolder(in: root, name: name)
    }

    @Test("a plain name nests directly under the source folder")
    func plainName() {
        #expect(sub("Edited").path == "/Volumes/Photos/Shoot/Edited")
    }

    @Test("surrounding whitespace is trimmed")
    func trimsWhitespace() {
        #expect(sub("  Edited  ").path == "/Volumes/Photos/Shoot/Edited")
    }

    @Test("a nested name stays inside the source folder")
    func nestedName() {
        #expect(sub("Edited/2026").path == "/Volumes/Photos/Shoot/Edited/2026")
    }

    @Test("an empty or whitespace-only name falls back to Exports")
    func emptyFallsBack() {
        #expect(sub("").path == "/Volumes/Photos/Shoot/Exports")
        #expect(sub("   ").path == "/Volumes/Photos/Shoot/Exports")
    }

    @Test("a name that climbs out via .. falls back to Exports")
    func parentTraversalBlocked() {
        #expect(sub("../..").path == "/Volumes/Photos/Shoot/Exports")
        #expect(sub("../../Photos").path == "/Volumes/Photos/Shoot/Exports")
        #expect(sub("Edited/../../escape").path == "/Volumes/Photos/Shoot/Exports")
    }

    @Test("an absolute path falls back to Exports rather than replacing the root")
    func absolutePathBlocked() {
        #expect(sub("/etc").path == "/Volumes/Photos/Shoot/Exports")
        #expect(sub("/Volumes/Other").path == "/Volumes/Photos/Shoot/Exports")
    }

    @Test("a name resolving to exactly the source folder falls back to Exports")
    func selfReferenceBlocked() {
        // "." resolves to rootFolder itself — exporting into the source folder could
        // overwrite originals, so it must not be used as the destination.
        #expect(sub(".").path == "/Volumes/Photos/Shoot/Exports")
    }
}

@Suite("16-bit JPEG XL conversion helpers")
struct RAWJXLConversionTests {
    @Test("RAW conversion has a fixed Rec. 2020 PQ target")
    func fixedHDRColorTarget() {
        #expect(EditedImageRenderer.rawJXLConversionGamut == .rec2020)
        #expect(EditedImageRenderer.rawJXLConversionColorSpace.name == CGColorSpace.itur_2100_PQ)
    }

    @Test("16-bit SDR conversion explicitly feeds libjxl rgb48le")
    func forces16BitRGB() {
        let args = FFmpegService.jxlArguments(
            input: "/tmp/input.png",
            output: "/tmp/output.jxl",
            quality: 0.92,
            isHDR: false,
            force16Bit: true
        )

        let pixelFormatIndex = args.firstIndex(of: "-pix_fmt")
        #expect(pixelFormatIndex != nil)
        if let pixelFormatIndex {
            #expect(args[pixelFormatIndex + 1] == "rgb48le")
        }
        #expect(args.contains("libjxl"))
        #expect(args.contains("1.2"))
    }

    @Test("ordinary SDR JPEG XL keeps its existing automatic pixel format")
    func ordinarySDRDoesNotForce16Bit() {
        let args = FFmpegService.jxlArguments(
            input: "/tmp/input.tiff",
            output: "/tmp/output.jxl",
            quality: 0.92,
            isHDR: false
        )
        #expect(!args.contains("-pix_fmt"))
    }

    @Test("conversion output avoids overwriting an existing JPEG XL")
    func uniqueDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-jxl-destination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("photo.cr3")
        let existing = directory.appendingPathComponent("photo.jxl")
        try Data().write(to: existing)

        let destination = EditedImageRenderer.uniqueOutputURL(
            for: source,
            in: directory,
            extension: "jxl"
        )
        #expect(destination.lastPathComponent == "photo 2.jxl")
    }

    @Test("bundled libjxl preserves the 16-bit RGB pixel format")
    func bundledEncoderProduces16BitJXL() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-jxl-encode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("input.png")
        let output = directory.appendingPathComponent("output.jxl")
        let image = CIImage(
            color: CIColor(red: 0.125, green: 0.5, blue: 0.875, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = EditedImageRenderer.rawJXLConversionColorSpace
        let png = try #require(context.pngRepresentation(
            of: image,
            format: .RGBA16,
            colorSpace: colorSpace,
            options: [:]
        ))
        try png.write(to: input, options: .atomic)

        try await FFmpegService.encodeJXL(
            input: input.path,
            output: output.path,
            quality: 0.92,
            isHDR: true,
            force16Bit: true
        )
        let ffmpegPath = try #require(FFmpegService.ffmpegPath)
        let probe = try await Process.run(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: ["-hide_banner", "-i", output.path],
            allowNonZeroExit: true
        )

        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(probe.stderr.contains("rgb48le"))
        #expect(probe.stderr.contains("bt2020"))
        #expect(probe.stderr.contains("smpte2084"))
    }
}

@Suite("Adaptive HDR JPEG")
struct AdaptiveHDRJPEGTests {
    private func makeSourceJPEG(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("source.jpg")
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.9]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: source)
        return source
    }

    @Test("writer embeds an ISO gain map that survives metadata copying and expands to HDR")
    func writesAndReadsGainMapJPEG() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-hdr-gainmap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try makeSourceJPEG(in: directory)
        #expect(!SupportedImageFormats.isHDR(url: source))
        let destination = directory.appendingPathComponent("adaptive-hdr.jpg")
        let extent = CGRect(x: 0, y: 0, width: 32, height: 32)
        let hdr = CIImage(
            color: CIColor(red: 3.0, green: 1.25, blue: 0.45, alpha: 1)
        ).cropped(to: extent)

        try EditedImageRenderer.writeHDRGainMapJPEG(
            hdrImage: hdr,
            destURL: destination,
            colorSpace: CameraRawApproximation.workingColorSpace,
            quality: 0.9,
            ctx: CameraRawApproximation.ciContext
        )

        let engine = SwiftExifWriteEngine()
        try await engine.copyMetadataToRenderedFile(
            from: source,
            to: destination,
            bakedCameraRaw: nil
        )

        let imageSource = try #require(
            CGImageSourceCreateWithURL(destination as CFURL, nil)
        )
        #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            imageSource,
            0,
            kCGImageAuxiliaryDataTypeISOGainMap
        ) != nil)
        #expect(SupportedImageFormats.isHDR(url: destination))

        let expanded = try #require(CIImage(contentsOf: destination, options: [
            .expandToHDR: true,
            .toneMapHDRtoSDR: false
        ]))
        #expect(expanded.contentHeadroom > 1)
    }
}
