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

    private var collisionSafeJPEGConfiguration: AdvancedExportConfiguration {
        AdvancedExportConfiguration(
            sdrFormat: .jpeg,
            sdrQuality: 0.92,
            sdrGamut: .sRGB,
            hdrFormat: .jpegGainMap,
            hdrQuality: 0.92,
            hdrGamut: .displayP3,
            tiffCompression: .lzw,
            resolutionLimit: .original,
            locationMode: .sameAsOriginal,
            customSubfolderName: "Exports"
        )
    }

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

    /// Creates a raster TIFF carrying a Sony Make tag. SwiftExif deliberately treats
    /// any TIFF with that tag as a possible ARW, matching the archive failure this
    /// suite guards against.
    private func makeSonyTIFFWorkspace() throws -> (dir: URL, source: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-export-sony-tiff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("archive.tiff")
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let data = rep.representation(using: .tiff, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: source)

        var metadata = try SwiftExif.readMetadata(from: source)
        let make = Data("SONY\0".utf8)
        metadata.exif = metadata.exif ?? ExifData(byteOrder: .littleEndian)
        metadata.exif?.ifd0 = IFD(entries: [
            IFDEntry(
                tag: ExifTag.make,
                type: .ascii,
                count: UInt32(make.count),
                valueData: make
            )
        ])
        try metadata.write(to: source)
        return (dir, source)
    }

    /// The core guarantee behind the FTP fix: pending edits that live only in a sidecar
    /// (not in the source file's own metadata) must land on the rendered output.
    @Test("renderItem overlays pending XMP sidecar keywords and title onto the rendered file")
    func renderItemAppliesSidecarIPTC() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sidecar = IPTCMetadata(
            title: "Aurora over the fjord",
            keywords: ["aurora", "fjord"],
            organisationsShownNames: ["Example News", "Harbor Authority"],
            organisationsShownCodes: ["EXNEWS", "NO-HARBOR"],
            urgency: 2,
            sceneCodes: ["011200", "012400"],
            creator: "Tester",
            creatorJobTitle: "Staff Photographer",
            descriptionWriter: "Night Desk",
            rightsUsageTerms: "Editorial use only",
            webStatementOfRights: "https://example.test/rights",
            digitalImageGUID: "urn:uuid:photo-42",
            imageSupplierImageID: "AGENCY-2026-0042",
            countryCode: "NOR"
        )
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
        #expect(meta.creatorJobTitle == "Staff Photographer")
        #expect(meta.descriptionWriter == "Night Desk")
        #expect(meta.rightsUsageTerms == "Editorial use only")
        #expect(meta.webStatementOfRights == "https://example.test/rights")
        #expect(meta.digitalImageGUID == "urn:uuid:photo-42")
        #expect(meta.imageSupplierImageID == "AGENCY-2026-0042")
        #expect(meta.countryCode == "NOR")
        #expect(meta.urgency == 2)
        #expect(meta.sceneCodes == ["011200", "012400"])
        #expect(meta.organisationsShownNames == ["Example News", "Harbor Authority"])
        #expect(meta.organisationsShownCodes == ["EXNEWS", "NO-HARBOR"])
    }

    @Test("renderItem embeds structured creator contact and locations from the XMP sidecar")
    func renderItemAppliesStructuredSidecarIPTC() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let expected = IPTCMetadata(
            localizedTitles: [
                LocalizedMetadataText(languageTag: "x-default", value: "Default title"),
                LocalizedMetadataText(languageTag: "nb-NO", value: "Norsk tittel"),
            ],
            creatorContactInfo: CreatorContactInfo(
                addressLines: ["News House", "1 Example Street"],
                city: "Oslo",
                emails: ["photo@example.test", "desk@example.test"]
            ),
            locationsCreated: [EditorialLocation(
                identifiers: ["https://example.test/places/city-hall"],
                name: "City Hall",
                city: "Oslo",
                countryCode: "NOR",
                latitude: 59.9111,
                longitude: 10.7339
            )],
            locationsShown: [EditorialLocation(
                name: "Harbor",
                city: "Bergen",
                altitudeMeters: -4.25
            )]
        )
        try XMPSidecarService().saveSidecar(metadata: expected, for: source)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source,
            cameraRaw: nil,
            kind: .jpeg,
            outputFolder: outDir,
            folderURL: dir,
            writeEngine: SwiftExifWriteEngine(),
            failureTracker: tracker
        )

        #expect(await tracker.sidecarOverlayFailures.isEmpty)
        let actual = try await SwiftExifReadService().readFullMetadata(url: rendered)
        #expect(actual.localizedTitles == expected.localizedTitles)
        #expect(actual.creatorContactInfo == expected.creatorContactInfo)
        #expect(actual.locationsCreated == expected.locationsCreated)
        #expect(actual.locationsShown == expected.locationsShown)
    }

    @Test("renderItem applies an explicit localized Title clear reloaded from XMP sidecar")
    func renderItemClearsLocalizedTitleFromSidecar() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        var planted = try SwiftExif.readMetadata(from: source)
        planted.xmp = XMPData()
        planted.xmp?.setValue(
            .languageAlternative([
                XMPLanguageAlternative(language: "x-default", value: "Stale title"),
                XMPLanguageAlternative(language: "nb-NO", value: "Gammel tittel"),
            ]),
            namespace: XMPNamespace.dc,
            property: "title"
        )
        try planted.write(to: source)

        let sidecars = XMPSidecarService()
        try sidecars.saveSidecar(metadata: IPTCMetadata(localizedTitles: []), for: source)
        #expect(sidecars.loadSidecar(for: source)?.localizedTitles == [])

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source,
            cameraRaw: nil,
            kind: .jpeg,
            outputFolder: outDir,
            folderURL: dir,
            writeEngine: SwiftExifWriteEngine(),
            failureTracker: tracker
        )

        #expect(await tracker.sidecarOverlayFailures.isEmpty)
        #expect(try await SwiftExifReadService().readFullMetadata(url: rendered).localizedTitles == nil)
    }

    @Test("rendered Sony TIFF accepts sidecar IPTC without weakening ordinary RAW writes")
    func renderedSonyTIFFAcceptsSidecarIPTC() async throws {
        let (dir, source) = try makeSonyTIFFWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = SwiftExifWriteEngine()
        await #expect(throws: (any Error).self) {
            try await engine.writeFields([.headline: "Blocked by RAW guard"], to: [source])
        }

        let rawSource = dir.appendingPathComponent("original.ARW")
        try Data([0]).write(to: rawSource)
        try XMPSidecarService().saveSidecar(
            metadata: IPTCMetadata(
                title: "Archive headline",
                description: "Archive caption"
            ),
            for: rawSource
        )
        let outcome = await SidecarIPTCOverlay.apply(
            sourceURL: rawSource,
            renderedURL: source,
            folderURL: dir,
            writeEngine: engine
        )
        guard case .applied = outcome else {
            Issue.record("Expected the RAW sidecar to be embedded into the rendered TIFF")
            return
        }

        let metadata = try await SwiftExifReadService().readFullMetadata(url: source)
        #expect(metadata.title == "Archive headline")
        #expect(metadata.description == "Archive caption")
        #expect(SupportedImageFormats.isRaw(url: source) == false)
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
        #expect(try rendered.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
        #expect(await tracker.sidecarOverlayFailures.isEmpty)
    }

    @Test("SwiftExif atomic rewrites preserve destination visibility")
    func metadataRewritePreservesVisibility() throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let metadata = try SwiftExif.readMetadata(from: source)

        var visibleValues = URLResourceValues()
        visibleValues.isHidden = false
        var mutableSource = source
        try mutableSource.setResourceValues(visibleValues)
        _ = try metadata.write(to: source)
        #expect(try source.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)

        var hiddenValues = URLResourceValues()
        hiddenValues.isHidden = true
        mutableSource = source
        try mutableSource.setResourceValues(hiddenValues)
        _ = try metadata.write(to: source)
        #expect(try source.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)
    }

    @Test("export visibility postcondition clears a hidden filesystem flag")
    func exportArtifactIsMadeVisible() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-export-visibility-\(UUID().uuidString)", isDirectory: true)
        let artifact = directory.appendingPathComponent("rendered.jpg")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("rendered".utf8).write(to: artifact)

        var hiddenValues = URLResourceValues()
        hiddenValues.isHidden = true
        var mutableArtifact = artifact
        try mutableArtifact.setResourceValues(hiddenValues)
        #expect(try artifact.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)

        try EditExportPipeline.ensureExportArtifactIsVisible(at: artifact)

        #expect(try artifact.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
        #expect(try Data(contentsOf: artifact) == Data("rendered".utf8))
    }

    /// Command-S can target the current source folder. A JPEG-to-JPEG export used to
    /// resolve to the source URL itself, so the renderer and metadata copier operated on
    /// one file as though it were two distinct files. The source could then disappear
    /// when SwiftExif completed its atomic replacement a moment after the pixels rendered.
    @Test("collision-safe format export beside a JPEG never aliases or changes its source")
    func formatExportBesideSourcePreservesSource() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let originalBytes = try Data(contentsOf: source)

        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source,
            cameraRaw: nil,
            kind: .format,
            outputFolder: dir,
            folderURL: dir,
            writeEngine: SwiftExifWriteEngine(),
            failureTracker: tracker,
            configuration: collisionSafeJPEGConfiguration,
            collisionPolicy: .appendNumber
        )

        #expect(rendered.standardizedFileURL != source.standardizedFileURL)
        #expect(rendered.lastPathComponent == "photo 2.jpg")
        #expect(FileManager.default.fileExists(atPath: rendered.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: source) == originalBytes)
        #expect(await tracker.metadataCopyFailures.isEmpty)
    }

    /// A mixed RAW/JPEG selection (or two cards) can legitimately contain distinct
    /// source files with the same stem. A collision-safe local batch must reserve a new
    /// filename for the later item rather than silently replacing the earlier export.
    @Test("collision-safe format exports give same-basename sources distinct outputs")
    func formatExportsWithSameBasenameRemainDistinct() async throws {
        let (dir, fixture) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cardA = dir.appendingPathComponent("card-a", isDirectory: true)
        let cardB = dir.appendingPathComponent("card-b", isDirectory: true)
        let output = dir.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: cardA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let firstSource = cardA.appendingPathComponent("photo.jpg")
        let secondSource = cardB.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(at: fixture, to: firstSource)
        try FileManager.default.copyItem(at: fixture, to: secondSource)

        let tracker = MetadataFailureTracker()
        let firstOutput = try await EditExportPipeline.renderItem(
            sourceURL: firstSource,
            cameraRaw: nil,
            kind: .format,
            outputFolder: output,
            folderURL: cardA,
            writeEngine: SwiftExifWriteEngine(),
            failureTracker: tracker,
            configuration: collisionSafeJPEGConfiguration,
            collisionPolicy: .appendNumber
        )
        let secondOutput = try await EditExportPipeline.renderItem(
            sourceURL: secondSource,
            cameraRaw: nil,
            kind: .format,
            outputFolder: output,
            folderURL: cardB,
            writeEngine: SwiftExifWriteEngine(),
            failureTracker: tracker,
            configuration: collisionSafeJPEGConfiguration,
            collisionPolicy: .appendNumber
        )

        #expect(firstOutput != secondOutput)
        #expect(firstOutput.lastPathComponent == "photo.jpg")
        #expect(secondOutput.lastPathComponent == "photo 2.jpg")
        #expect(FileManager.default.fileExists(atPath: firstOutput.path))
        #expect(FileManager.default.fileExists(atPath: secondOutput.path))
        #expect(await tracker.metadataCopyFailures.isEmpty)
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

    @Test("modeled localized Title language or ordering changes are descriptive")
    func localizedTitleChanges() {
        let norwegian = LocalizedMetadataText(languageTag: "nb-NO", value: "Norsk")
        let nynorsk = LocalizedMetadataText(languageTag: "nn", value: "Nynorsk")
        let a = IPTCMetadata(localizedTitles: [norwegian, nynorsk])

        #expect(!SidecarReconciliation.descriptiveFieldsDiffer(a, a))
        #expect(SidecarReconciliation.descriptiveFieldsDiffer(
            a,
            IPTCMetadata(localizedTitles: [nynorsk, norwegian])
        ))
        #expect(SidecarReconciliation.descriptiveFieldsDiffer(
            a,
            IPTCMetadata(localizedTitles: [])
        ))
        #expect(!SidecarReconciliation.descriptiveFieldsDiffer(a, IPTCMetadata()))
        #expect(SidecarReconciliation.descriptiveFieldsDiffer(
            IPTCMetadata(),
            IPTCMetadata(localizedTitles: [norwegian])
        ))
    }

    @Test("legacy sidecar localized Title nil is a reconciliation wildcard")
    func legacyLocalizedTitleDoesNotCreateConflict() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-sidecar-reconciliation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("photo.jpg")
        let sidecarURL = directory.appendingPathComponent("photo.xmp")
        try Data().write(to: imageURL)
        try Data().write(to: sidecarURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: imageURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: sidecarURL.path
        )

        let embedded = IPTCMetadata(
            title: "Shared headline",
            localizedTitles: [LocalizedMetadataText(languageTag: "nb-NO", value: "Norsk")]
        )
        let legacySidecar = IPTCMetadata(title: "Shared headline")

        #expect(SidecarReconciliation.verdict(
            imageURL: imageURL,
            sidecarURL: sidecarURL,
            embedded: embedded,
            sidecar: legacySidecar
        ) == .sidecarMaster)
    }

    @Test("GPS-only differences are ignored — GPS isn't descriptive")
    func gpsIgnored() {
        let a = IPTCMetadata(title: "T", latitude: 10, longitude: 20)
        let b = IPTCMetadata(title: "T", latitude: -10, longitude: -20)
        #expect(!SidecarReconciliation.descriptiveFieldsDiffer(a, b))
    }

    @Test("structured location bags compare order-insensitively")
    func structuredLocationsIgnoreOrder() {
        let oslo = EditorialLocation(city: "Oslo", countryCode: "NOR")
        let bergen = EditorialLocation(city: "Bergen", countryCode: "NOR")
        let a = IPTCMetadata(locationsShown: [oslo, bergen])
        let b = IPTCMetadata(locationsShown: [bergen, oslo])

        #expect(!SidecarReconciliation.descriptiveFieldsDiffer(a, b))
    }

    @Test("structured contact changes are descriptive")
    func structuredContactChanges() {
        let a = IPTCMetadata(
            creatorContactInfo: CreatorContactInfo(emails: ["desk@example.test"])
        )
        let b = IPTCMetadata(
            creatorContactInfo: CreatorContactInfo(emails: ["newsroom@example.test"])
        )

        #expect(SidecarReconciliation.descriptiveFieldsDiffer(a, b))
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

@Suite("RAW archive helpers")
struct RAWArchiveTests {
    @Test("rendered RAW archives have a fixed Rec. 2020 PQ target")
    func fixedHDRColorTarget() {
        #expect(EditedImageRenderer.rawArchiveConversionGamut == .rec2020)
        #expect(EditedImageRenderer.rawArchiveConversionColorSpace.name == CGColorSpace.itur_2100_PQ)
    }

    @Test("archive menu order and decode profiles are fixed")
    func archiveOptions() {
        #expect(RAWArchiveFormat.allCases == [
            .jpegXLLinear,
            .jpegXLCamera,
            .tiffLinear,
            .tiffCamera,
            .dngLossless,
            .dngLossy
        ])
        #expect(RAWArchiveFormat.jpegXLLinear.decodeProfile == .linear)
        #expect(RAWArchiveFormat.jpegXLCamera.decodeProfile == .camera)
        #expect(RAWArchiveFormat.tiffLinear.decodeProfile == .linear)
        #expect(RAWArchiveFormat.tiffCamera.decodeProfile == .camera)
        #expect(RAWArchiveFormat.dngLossless.decodeProfile == nil)
        #expect(RAWArchiveFormat.dngLossy.decodeProfile == nil)
        #expect(RAWArchiveFormat.dngLossless.requiresAdobeDNGConverter)
        #expect(RAWArchiveFormat.dngLossy.requiresAdobeDNGConverter)
        #expect(RAWArchiveFormat.jpegXLLinear.c2paActionName == "c2pa.transcoded")
        #expect(RAWArchiveFormat.jpegXLCamera.c2paActionName == "c2pa.transcoded")
        #expect(RAWArchiveFormat.tiffLinear.c2paActionName == "c2pa.transcoded")
        #expect(RAWArchiveFormat.tiffCamera.c2paActionName == "c2pa.transcoded")
        #expect(RAWArchiveFormat.dngLossless.c2paActionName == "c2pa.repackaged")
        #expect(RAWArchiveFormat.dngLossy.c2paActionName == "c2pa.transcoded")
        #expect(
            RAWArchiveFormat.dngLossless.c2paActionDescription
                .contains("without applying develop edits")
        )
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
        let colorSpace = EditedImageRenderer.rawArchiveConversionColorSpace
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

    @Test("DNG arguments select compression, destination, and output name")
    func dngArguments() {
        let source = URL(fileURLWithPath: "/Volumes/Card/DCIM/PHOTO.CR3")
        let destination = URL(fileURLWithPath: "/Volumes/Archive/DNG/PHOTO 2.dng")

        let lossless = AdobeDNGConverterService.conversionArguments(
            sourceURL: source,
            destinationURL: destination,
            compression: .lossless
        )
        #expect(lossless == [
            "-c",
            "-d", "/Volumes/Archive/DNG",
            "-o", "PHOTO 2.dng",
            "/Volumes/Card/DCIM/PHOTO.CR3"
        ])

        let lossy = AdobeDNGConverterService.conversionArguments(
            sourceURL: source,
            destinationURL: destination,
            compression: .lossy
        )
        #expect(lossy.first == "-lossy")
    }

    @Test("DNG executable resolves inside the Adobe application bundle")
    func dngExecutableResolution() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-dng-app-\(UUID().uuidString)", isDirectory: true)
        let applicationURL = directory.appendingPathComponent(
            "Adobe DNG Converter.app",
            isDirectory: true
        )
        let executable = applicationURL
            .appendingPathComponent("Contents/MacOS/Adobe DNG Converter")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(
            AdobeDNGConverterService.executableURL(in: applicationURL)
                == executable
        )
    }

    @Test("DNG destination protects both image and sidecar names")
    func dngDestinationProtectsSidecar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-dng-destination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("photo.cr3")
        try Data().write(to: directory.appendingPathComponent("photo.xmp"))
        try Data().write(to: directory.appendingPathComponent("photo 2.dng"))

        let destination = RAWArchiveService.uniqueDestinationURL(
            for: source,
            in: directory,
            extension: "dng"
        )
        #expect(destination.lastPathComponent == "photo 3.dng")
    }

    @Test("work-folder mode uses an Archive sub-folder")
    func workFolderArchiveDestination() throws {
        let source = URL(fileURLWithPath: "/Volumes/Photos/Shoot/RAW/photo.cr3")
        let destination = try RAWArchiveService.destinationFolder(
            for: source,
            mode: .workFolderArchive
        )
        #expect(destination.path == "/Volumes/Photos/Shoot/RAW/Archive")
    }

    @Test("separate archive root mirrors the ingest-relative structure")
    func mirroredArchiveDestination() throws {
        let source = URL(
            fileURLWithPath: "/Volumes/Photos/2026/07/2026-07-21 – Morning/RAW/photo.cr3"
        )
        let destination = try RAWArchiveService.destinationFolder(
            for: source,
            mode: .mirroredArchiveRoot,
            ingestRoot: URL(fileURLWithPath: "/Volumes/Photos", isDirectory: true),
            archiveRoot: URL(fileURLWithPath: "/Volumes/Archive", isDirectory: true)
        )
        #expect(
            destination.path
                == "/Volumes/Archive/2026/07/2026-07-21 – Morning/RAW"
        )
    }

    @Test("mirrored archive rejects sources outside the ingest root")
    func mirroredArchiveRejectsOutsideSource() {
        #expect(throws: RAWArchiveLocationError.self) {
            try RAWArchiveService.destinationFolder(
                for: URL(fileURLWithPath: "/Volumes/Other/photo.cr3"),
                mode: .mirroredArchiveRoot,
                ingestRoot: URL(fileURLWithPath: "/Volumes/Photos", isDirectory: true),
                archiveRoot: URL(fileURLWithPath: "/Volumes/Archive", isDirectory: true)
            )
        }
    }

    @Test("manual archive mode uses the chosen folder")
    func manualArchiveDestination() throws {
        let selected = URL(fileURLWithPath: "/Volumes/Selected", isDirectory: true)
        let destination = try RAWArchiveService.destinationFolder(
            for: URL(fileURLWithPath: "/Volumes/Photos/photo.cr3"),
            manualDestination: selected,
            mode: .askEveryTime
        )
        #expect(destination == selected)
    }

    @Test("archive copies the source XMP packet unchanged")
    func copiesArchiveSidecar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-archive-xmp-\(UUID().uuidString)", isDirectory: true)
        let archive = directory.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("photo.cr3")
        let sourceSidecar = directory.appendingPathComponent("photo.xmp")
        let destination = archive.appendingPathComponent("photo.jxl")
        let xmp = Data("<x:xmpmeta>unedited pixels, external edits</x:xmpmeta>".utf8)
        try xmp.write(to: sourceSidecar)

        try RAWArchiveService.copySidecarIfPresent(
            from: source,
            to: destination
        )

        let copied = try Data(
            contentsOf: archive.appendingPathComponent("photo.xmp")
        )
        #expect(copied == xmp)
    }

    @Test("signing failure cleanup removes archive bundle and preserves source sidecar")
    func signingFailureCleanupRemovesOnlyArchiveBundle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-archive-signing-cleanup-\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = directory.appendingPathComponent("Source", isDirectory: true)
        let archiveFolder = directory.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = sourceFolder.appendingPathComponent("photo.cr3")
        let sourceSidecar = sourceFolder.appendingPathComponent("photo.xmp")
        let archive = archiveFolder.appendingPathComponent("photo.jxl")
        let archiveSidecar = archiveFolder.appendingPathComponent("photo.xmp")
        try Data("source".utf8).write(to: source)
        try Data("source-sidecar".utf8).write(to: sourceSidecar)
        try Data("unsigned-archive".utf8).write(to: archive)
        try Data("archive-sidecar".utf8).write(to: archiveSidecar)

        let request = RAWArchiveSigningFailureCleanupRequest(
            archiveURL: archive,
            sourceURL: source
        )
        let evidence = await RAWArchiveSigningFailureCleanupService().cleanup(request)

        #expect(evidence.requestID == request.requestID)
        #expect(evidence.archive.outcome == .removed)
        #expect(evidence.archiveSidecar.outcome == .removed)
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(!FileManager.default.fileExists(atPath: archiveSidecar.path))
        #expect(FileManager.default.fileExists(atPath: sourceSidecar.path))
    }

    @Test("a shared source sidecar is explicitly preserved")
    func signingFailureCleanupPreservesSharedSidecar() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-archive-shared-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("photo.cr3")
        let archive = directory.appendingPathComponent("photo.jxl")
        let sharedSidecar = directory.appendingPathComponent("photo.xmp")
        try Data("source-sidecar".utf8).write(to: sharedSidecar)
        try Data("unsigned-archive".utf8).write(to: archive)

        let evidence = await RAWArchiveSigningFailureCleanupService().cleanup(
            RAWArchiveSigningFailureCleanupRequest(
                archiveURL: archive,
                sourceURL: source
            )
        )

        #expect(evidence.archive.outcome == .removed)
        #expect(evidence.archiveSidecar.outcome == .preservedSourceSidecar)
        #expect(FileManager.default.fileExists(atPath: sharedSidecar.path))
    }

    @Test("cleanup reports partial durability and still attempts the sidecar")
    func signingFailureCleanupReportsPartialDurability() async {
        let archive = URL(fileURLWithPath: "/virtual/archive/photo.jxl")
        let source = URL(fileURLWithPath: "/virtual/source/photo.cr3")
        let request = RAWArchiveSigningFailureCleanupRequest(
            archiveURL: archive,
            sourceURL: source
        )
        let probe = RAWArchiveCleanupProbe(failingURL: archive)
        let service = RAWArchiveSigningFailureCleanupService(io: probe.io)

        let evidence = await service.cleanup(request)

        if case .removalFailed = evidence.archive.outcome {
            // Expected explicit evidence for the artifact that could not be removed.
        } else {
            Issue.record("Expected archive removal failure evidence")
        }
        #expect(evidence.archiveSidecar.outcome == .removed)
        #expect(probe.removedURLs == [request.archiveSidecarURL])
    }

    @Test("cancelled cleanup still removes both unsafe artifacts and reports cancellation")
    func signingFailureCleanupIsDurableUnderCancellation() async {
        let archive = URL(fileURLWithPath: "/virtual/archive/photo.jxl")
        let source = URL(fileURLWithPath: "/virtual/source/photo.cr3")
        let request = RAWArchiveSigningFailureCleanupRequest(
            archiveURL: archive,
            sourceURL: source
        )
        let probe = RAWArchiveCleanupProbe()
        let service = RAWArchiveSigningFailureCleanupService(io: probe.io)

        let evidence = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.cleanup(request)
        }.value

        #expect(evidence.cancellationObservedBeforeCleanup)
        #expect(evidence.cancellationObservedAfterCleanup)
        #expect(evidence.archive.outcome == .removed)
        #expect(evidence.archiveSidecar.outcome == .removed)
        #expect(probe.removedURLs == [request.archiveURL, request.archiveSidecarURL])
    }

    @MainActor
    @Test("cleanup filesystem work leaves MainActor and requests are serialized")
    func signingFailureCleanupIsOffMainAndSerialized() async {
        let probe = RAWArchiveCleanupProbe(blockFirstRemoval: true)
        let service = RAWArchiveSigningFailureCleanupService(io: probe.io)
        let firstRequest = RAWArchiveSigningFailureCleanupRequest(
            archiveURL: URL(fileURLWithPath: "/virtual/archive/first.jxl"),
            sourceURL: URL(fileURLWithPath: "/virtual/source/first.cr3")
        )
        let secondRequest = RAWArchiveSigningFailureCleanupRequest(
            archiveURL: URL(fileURLWithPath: "/virtual/archive/second.jxl"),
            sourceURL: URL(fileURLWithPath: "/virtual/source/second.cr3")
        )

        let first = Task { @MainActor in await service.cleanup(firstRequest) }
        await probe.waitUntilFirstRemovalStarts()
        let second = Task { @MainActor in await service.cleanup(secondRequest) }
        await Task.yield()

        #expect(probe.removalInvocationCount == 1)
        probe.releaseFirstRemoval()
        _ = await first.value
        _ = await second.value

        #expect(probe.maximumConcurrentRemovals == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("ContentView routes signing failure cleanup through the service boundary")
    func signingFailureCleanupSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent("Aagedal Photo Agent/ContentView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("RAWArchiveSigningFailureCleanupRequest("))
        #expect(source.contains("await RAWArchiveSigningFailureCleanupService.shared.cleanup("))
        #expect(!source.contains("try? FileManager.default.removeItem(at: convertedURL)"))
    }
}

nonisolated private final class RAWArchiveCleanupProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let failingURL: URL?
    private let blockFirstRemoval: Bool
    private var didReleaseFirstRemoval = false
    private var activeRemovals = 0
    private var _maximumConcurrentRemovals = 0
    private var _removalInvocationCount = 0
    private var _ranOnMainThread = false
    private var _removedURLs: [URL] = []

    init(failingURL: URL? = nil, blockFirstRemoval: Bool = false) {
        self.failingURL = failingURL
        self.blockFirstRemoval = blockFirstRemoval
    }

    var io: RAWArchiveSigningFailureCleanupIO {
        RAWArchiveSigningFailureCleanupIO(
            fileExists: { _ in true },
            removeItem: { [self] url in
                condition.lock()
                _removalInvocationCount += 1
                activeRemovals += 1
                _maximumConcurrentRemovals = max(_maximumConcurrentRemovals, activeRemovals)
                _ranOnMainThread = _ranOnMainThread || Thread.isMainThread
                condition.broadcast()
                while blockFirstRemoval,
                      _removalInvocationCount == 1,
                      !didReleaseFirstRemoval {
                    condition.wait()
                }

                defer {
                    activeRemovals -= 1
                    condition.broadcast()
                    condition.unlock()
                }
                if url == failingURL {
                    throw CocoaError(.fileWriteUnknown)
                }
                _removedURLs.append(url)
            }
        )
    }

    var removedURLs: [URL] {
        condition.withLock { _removedURLs }
    }

    var removalInvocationCount: Int {
        condition.withLock { _removalInvocationCount }
    }

    var maximumConcurrentRemovals: Int {
        condition.withLock { _maximumConcurrentRemovals }
    }

    var ranOnMainThread: Bool {
        condition.withLock { _ranOnMainThread }
    }

    func waitUntilFirstRemovalStarts() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                while _removalInvocationCount == 0 {
                    condition.wait()
                }
                condition.unlock()
                continuation.resume()
            }
        }
    }

    func releaseFirstRemoval() {
        condition.withLock {
            didReleaseFirstRemoval = true
            condition.broadcast()
        }
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
