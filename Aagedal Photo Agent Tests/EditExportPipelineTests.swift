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

@Suite("FFmpeg AVIF encoding")
struct FFmpegAVIFEncodingTests {
    @Test("quality maps to libaom CRF and SDR color signaling")
    func sdrArguments() {
        let arguments = FFmpegService.avifArguments(
            input: "/tmp/input.tiff",
            output: "/tmp/output.avif",
            quality: 0.92,
            isHDR: false,
            gamut: .sRGB
        )

        #expect(arguments.contains("libaom-av1"))
        #expect(arguments.contains("yuv420p"))
        #expect(arguments.contains("5"))
        #expect(arguments.contains("iec61966-2-1"))
        #expect(arguments.contains("bt709"))
        #expect(arguments.contains("-still-picture"))
    }

    @Test("HDR uses 10-bit HLG signaling for the selected gamut")
    func hdrArguments() {
        let arguments = FFmpegService.avifArguments(
            input: "/tmp/input.png",
            output: "/tmp/output.avif",
            quality: 0.8,
            isHDR: true,
            gamut: .rec2020
        )

        #expect(arguments.contains("yuv420p10le"))
        #expect(arguments.contains("bt2020"))
        #expect(arguments.contains("arib-std-b67"))
        #expect(arguments.contains("bt2020nc"))
        #expect(arguments.contains("12"))
    }

    @Test("bundled libaom produces a decodable AVIF")
    func bundledEncoderProducesAVIF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-ffmpeg-avif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("input.png")
        let output = directory.appendingPathComponent("output.avif")
        let image = CIImage(
            color: CIColor(red: 0.2, green: 0.55, blue: 0.85, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        let context = CIContext(options: [.cacheIntermediates: false])
        let png = try #require(context.pngRepresentation(
            of: image,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [:]
        ))
        try png.write(to: input, options: .atomic)

        try await FFmpegService.encodeAVIF(
            input: input.path,
            output: output.path,
            quality: 0.8,
            isHDR: false,
            gamut: .sRGB
        )

        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.avif")
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
    }

    @Test("bundled libaom produces 10-bit HLG AVIF")
    func bundledEncoderProducesHDRAVIF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-ffmpeg-hdr-avif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("input.png")
        let output = directory.appendingPathComponent("output.avif")
        let image = CIImage(
            color: CIColor(red: 2.0, green: 0.8, blue: 0.3, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        let context = CIContext(options: [.cacheIntermediates: false])
        let png = try #require(context.pngRepresentation(
            of: image,
            format: .RGBA16,
            colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_HLG)!,
            options: [:]
        ))
        try png.write(to: input, options: .atomic)

        try await FFmpegService.encodeAVIF(
            input: input.path,
            output: output.path,
            quality: 0.8,
            isHDR: true,
            gamut: .rec2020
        )

        let ffmpegPath = try #require(FFmpegService.ffmpegPath)
        let probe = try await Process.run(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: ["-hide_banner", "-i", output.path],
            allowNonZeroExit: true
        )
        #expect(probe.stderr.contains("yuv420p10le"))
        #expect(probe.stderr.contains("bt2020"))
        #expect(probe.stderr.contains("arib-std-b67"))
        #expect(SupportedImageFormats.isHDR(url: output))
    }

    @Test("native and FFmpeg AVIF remain distinct persisted choices")
    func formatChoicesAreDistinct() {
        #expect(ExportFormatSDR.avif.rawValue == "avif")
        #expect(ExportFormatSDR.avifFFmpeg.rawValue == "avifFFmpeg")
        #expect(ExportFormatSDR.avif.fileExtension == "avif")
        #expect(ExportFormatSDR.avifFFmpeg.fileExtension == "avif")
        #expect(ExportFormatHDR.avif10bit.rawValue == "avif10bit")
        #expect(ExportFormatHDR.avifFFmpeg10bit.rawValue == "avifFFmpeg10bit")
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

@Suite("Native AVIF encoding")
struct NativeAVIFEncodingTests {
    private let context = CIContext(options: [.cacheIntermediates: false])

    private func makeSourceJPEG(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("source.jpg")
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 24,
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

    private func properties(at url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
    }

    @Test("SDR writer produces an 8-bit AVIF with the selected ICC profile")
    func writesSDRAVIF() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-native-sdr-avif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("sdr.avif")
        let extent = CGRect(x: 0, y: 0, width: 48, height: 32)
        let image = CIImage(
            color: CIColor(red: 0.72, green: 0.31, blue: 0.08, alpha: 1)
        ).cropped(to: extent)

        try EditedImageRenderer.writeAVIF(
            ciImage: image,
            destURL: destination,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            quality: 0.82,
            isHDR: false,
            ctx: context
        )

        let source = try #require(
            CGImageSourceCreateWithURL(destination as CFURL, nil)
        )
        #expect(CGImageSourceGetType(source) as String? == "public.avif")
        let props = try properties(at: destination)
        #expect((props[kCGImagePropertyDepth] as? NSNumber)?.intValue == 8)
        #expect((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 48)
        #expect((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 32)
        #expect(props[kCGImagePropertyProfileName] as? String == "Display P3")
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
    }

    @Test("HDR writer produces 10-bit HLG AVIF and metadata rewriting preserves HDR")
    func writesHDRAVIF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-native-hdr-avif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceJPEG = try makeSourceJPEG(in: directory)
        let destination = directory.appendingPathComponent("hdr.avif")
        let extent = CGRect(x: 0, y: 0, width: 48, height: 32)
        let image = CIImage(
            color: CIColor(red: 3.0, green: 1.25, blue: 0.45, alpha: 1)
        ).cropped(to: extent)

        try EditedImageRenderer.writeAVIF(
            ciImage: image,
            destURL: destination,
            colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_HLG)!,
            quality: 0.82,
            isHDR: true,
            ctx: context
        )
        try await SwiftExifWriteEngine().copyMetadataToRenderedFile(
            from: sourceJPEG,
            to: destination,
            bakedCameraRaw: nil
        )

        let props = try properties(at: destination)
        #expect((props[kCGImagePropertyDepth] as? NSNumber)?.intValue == 10)
        #expect((props[kCGImagePropertyProfileName] as? String)?.contains("2100 HLG") == true)
        #expect((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1)
        #expect(SupportedImageFormats.isHDR(url: destination))

        let expanded = try #require(CIImage(contentsOf: destination, options: [
            .expandToHDR: true,
            .toneMapHDRtoSDR: false
        ]))
        #expect(expanded.contentHeadroom > 1)
    }
}

@Suite("Advanced export")
struct AdvancedExportTests {
    private var configuration: AdvancedExportConfiguration {
        AdvancedExportConfiguration(
            sdrFormat: .jpeg,
            sdrQuality: 0.61,
            sdrGamut: .sRGB,
            hdrFormat: .jpegGainMap,
            hdrQuality: 0.74,
            hdrGamut: .displayP3,
            tiffCompression: .lzw,
            resolutionLimit: .original,
            locationMode: .formatSubfolder,
            customSubfolderName: "Exports"
        )
    }

    private func makeSourceJPEG(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("preview-source.jpg")
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        for y in 0..<32 {
            for x in 0..<64 {
                rep.setColor(
                    NSColor(
                        calibratedRed: CGFloat(x) / 63,
                        green: CGFloat(y) / 31,
                        blue: CGFloat((x + y) % 16) / 15,
                        alpha: 1
                    ),
                    atX: x,
                    y: y
                )
            }
        }
        guard let data = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.95]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: source)
        return source
    }

    private func makeCompressionSourceJPEG(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("compression-source.jpg")
        let width = 256
        let height = 256
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        // Deterministic high-frequency detail makes the difference between JPEG
        // quantization levels large and stable enough for a regression assertion.
        for y in 0..<height {
            for x in 0..<width {
                let red = CGFloat((x * 73 ^ y * 151) & 0xff) / 255
                let green = CGFloat((x * 29 ^ y * 199 ^ x * y) & 0xff) / 255
                let blue = CGFloat((x * 181 ^ y * 47 ^ (x + y) * 13) & 0xff) / 255
                rep.setColor(
                    NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1),
                    atX: x,
                    y: y
                )
            }
        }

        guard let data = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: 1]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: source)
        return source
    }

    private func pixelData(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }

    @Test("selected queue follows visible browser order")
    func queueUsesVisibleOrder() {
        let root = URL(fileURLWithPath: "/tmp/advanced-export-order")
        let first = ImageFile(url: root.appendingPathComponent("first.jpg"))
        let second = ImageFile(url: root.appendingPathComponent("second.jpg"))
        let third = ImageFile(url: root.appendingPathComponent("third.jpg"))

        let result = AdvancedExportQueueBuilder.orderedSelection(
            from: [third, first, second],
            selectedIDs: [first.url, third.url]
        )

        #expect(result.map(\.url) == [third.url, first.url])
    }

    @Test("preview signatures only change for pixel-affecting settings")
    func previewSignatureScoping() {
        var changedLocation = configuration
        changedLocation.locationMode = .sameAsOriginal
        #expect(
            changedLocation.previewSignature(isHDR: false)
                == configuration.previewSignature(isHDR: false)
        )

        var changedQuality = configuration
        changedQuality.sdrQuality = 0.9
        #expect(
            changedQuality.previewSignature(isHDR: false)
                != configuration.previewSignature(isHDR: false)
        )
        #expect(
            changedQuality.previewSignature(isHDR: true)
                == configuration.previewSignature(isHDR: true)
        )
        #expect(
            changedQuality.referenceSignature(isHDR: false)
                == configuration.referenceSignature(isHDR: false)
        )

        var changedFormat = configuration
        changedFormat.sdrFormat = .avif
        #expect(
            changedFormat.referenceSignature(isHDR: false)
                == configuration.referenceSignature(isHDR: false)
        )

        var changedResolution = configuration
        changedResolution.resolutionLimit = .pixels2048
        #expect(
            changedResolution.previewSignature(isHDR: false)
                != configuration.previewSignature(isHDR: false)
        )
        #expect(
            changedResolution.previewSignature(isHDR: true)
                != configuration.previewSignature(isHDR: true)
        )
        #expect(
            changedResolution.referenceSignature(isHDR: false)
                != configuration.referenceSignature(isHDR: false)
        )
    }

    @Test("preview encoder honors explicit SDR configuration")
    func previewUsesExplicitConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-advanced-preview-test-\(UUID().uuidString)", isDirectory: true)
        let output = directory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try makeSourceJPEG(in: directory)
        let artifact = try await EditedImageRenderer.renderAdvancedPreview(
            from: source,
            cameraRaw: nil,
            isHDR: false,
            configuration: configuration,
            outputFolder: output,
            maxReferencePixelSize: 32
        )

        #expect(artifact.outputURL.pathExtension == "jpg")
        #expect(FileManager.default.fileExists(atPath: artifact.outputURL.path))
        #expect(artifact.pixelWidth == 64)
        #expect(artifact.pixelHeight == 32)
        #expect(max(artifact.referenceImage.width, artifact.referenceImage.height) == 32)
        #expect(CGImageSourceCreateWithURL(artifact.outputURL as CFURL, nil) != nil)
    }

    @Test("secondary export uses its explicit settings and a distinct filename")
    func secondaryExportUsesExplicitConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-secondary-export-test-\(UUID().uuidString)", isDirectory: true)
        let output = directory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try makeSourceJPEG(in: directory)
        var secondaryConfiguration = configuration
        secondaryConfiguration.sdrFormat = .png
        secondaryConfiguration.resolutionLimit = .pixels1600

        let destination = try await EditedImageRenderer.render(
            from: source,
            cameraRaw: nil,
            isHDR: false,
            outputFolder: output,
            configuration: secondaryConfiguration,
            outputFilenameSuffix: " Secondary"
        )

        #expect(destination.lastPathComponent == "preview-source Secondary.png")
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(CGImageSourceCreateWithURL(destination as CFURL, nil) != nil)
    }

    @Test("format subfolder naming uses the selected export configuration")
    func formatSubfolderUsesExplicitConfiguration() {
        var secondaryConfiguration = configuration
        secondaryConfiguration.sdrFormat = .png

        #expect(
            EditedImageRenderer.formatFolderName(
                prefix: "Edited_Secondary",
                isHDR: false,
                configuration: secondaryConfiguration
            ) == "Edited_Secondary_PNG"
        )

        secondaryConfiguration.sdrFormat = .avifFFmpeg
        #expect(
            EditedImageRenderer.formatFolderName(
                prefix: "Edited_Secondary",
                isHDR: false,
                configuration: secondaryConfiguration
            ) == "Edited_Secondary_AVIF_FFmpeg"
        )
    }

    @Test("preview displays the artifact encoded at the selected JPEG quality")
    func previewDisplaysSelectedJPEGCompression() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-compression-preview-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try makeCompressionSourceJPEG(in: directory)
        let item = AdvancedExportItem(
            sourceURL: source,
            filename: source.lastPathComponent,
            cameraRaw: nil,
            isHDR: false
        )
        var lowConfiguration = configuration
        lowConfiguration.sdrQuality = AdvancedExportConfiguration.minimumQuality
        var highConfiguration = configuration
        highConfiguration.sdrQuality = 0.95

        let service = AdvancedExportPreviewService()
        let lowPreview = try await service.makePreview(
            item: item,
            configuration: lowConfiguration
        )
        let highPreview = try await service.makePreview(
            item: item,
            configuration: highConfiguration
        )

        #expect(lowPreview.encodedFileSize < highPreview.encodedFileSize)
        #expect(pixelData(lowPreview.exportImage) != pixelData(highPreview.exportImage))
        #expect(lowPreview.referenceImage === highPreview.referenceImage)

        let lowLoupe = try await service.makeLoupe(
            item: item,
            configuration: lowConfiguration,
            preview: lowPreview,
            normalizedPoint: CGPoint(x: 0.5, y: 0.5),
            pixelSize: 64
        )
        let highLoupe = try await service.makeLoupe(
            item: item,
            configuration: highConfiguration,
            preview: highPreview,
            normalizedPoint: CGPoint(x: 0.5, y: 0.5),
            pixelSize: 64
        )
        #expect(lowLoupe.referenceImage === highLoupe.referenceImage)
        #expect(pixelData(lowLoupe.exportImage) != pixelData(highLoupe.exportImage))

        let decodedLowArtifact = try #require(
            FullScreenImageCache.loadDownsampled(
                from: lowPreview.storage.outputURL,
                maxPixelSize: 1_600
            )
        )
        #expect(pixelData(lowPreview.exportImage) == pixelData(decodedLowArtifact))
    }

    @Test("preview displays native AVIF compression at the selected quality")
    func previewDisplaysSelectedAVIFCompression() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-avif-compression-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try makeCompressionSourceJPEG(in: directory)
        let item = AdvancedExportItem(
            sourceURL: source,
            filename: source.lastPathComponent,
            cameraRaw: nil,
            isHDR: false
        )
        var lowConfiguration = configuration
        lowConfiguration.sdrFormat = .avif
        lowConfiguration.sdrQuality = AdvancedExportConfiguration.minimumQuality
        var highConfiguration = lowConfiguration
        highConfiguration.sdrQuality = 0.95

        let service = AdvancedExportPreviewService()
        let lowPreview = try await service.makePreview(
            item: item,
            configuration: lowConfiguration
        )
        let highPreview = try await service.makePreview(
            item: item,
            configuration: highConfiguration
        )

        #expect(lowPreview.storage.outputURL.pathExtension == "avif")
        #expect(highPreview.storage.outputURL.pathExtension == "avif")
        #expect(lowPreview.encodedFileSize < highPreview.encodedFileSize)
        #expect(pixelData(lowPreview.exportImage) != pixelData(highPreview.exportImage))
    }

    @Test("preview renders the FFmpeg AVIF alternative")
    func previewRendersFFmpegAVIF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-ffmpeg-avif-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try makeCompressionSourceJPEG(in: directory)
        let item = AdvancedExportItem(
            sourceURL: source,
            filename: source.lastPathComponent,
            cameraRaw: nil,
            isHDR: false
        )
        var ffmpegConfiguration = configuration
        ffmpegConfiguration.sdrFormat = .avifFFmpeg
        ffmpegConfiguration.sdrQuality = 0.8

        let preview = try await AdvancedExportPreviewService().makePreview(
            item: item,
            configuration: ffmpegConfiguration
        )

        #expect(preview.storage.outputURL.pathExtension == "avif")
        #expect(preview.configuration.sdrFormat == .avifFFmpeg)
        #expect(CGImageSourceCreateWithURL(preview.storage.outputURL as CFURL, nil) != nil)
    }

    @Test("resolution limit caps the long edge without upscaling")
    func resolutionLimitCapsLongEdge() {
        let large = CIImage(color: .white)
            .cropped(to: CGRect(x: 0, y: 0, width: 4_000, height: 2_000))
        let limited = EditedImageRenderer.limitedForExport(
            large,
            maximumPixelSize: ExportResolutionLimit.pixels1600.maximumPixelSize
        )
        #expect(limited.extent.width == 1_600)
        #expect(limited.extent.height == 800)

        let small = CIImage(color: .white)
            .cropped(to: CGRect(x: 0, y: 0, width: 800, height: 400))
        let unchanged = EditedImageRenderer.limitedForExport(
            small,
            maximumPixelSize: ExportResolutionLimit.pixels1600.maximumPixelSize
        )
        #expect(unchanged.extent == small.extent)
    }

    @Test("lossy quality floor is ten percent")
    func lossyQualityMinimum() {
        #expect(AdvancedExportConfiguration.minimumQuality == 0.10)
        #expect(AdvancedExportConfiguration.minimumQuality < 0.5)
    }
}
