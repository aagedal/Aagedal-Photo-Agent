import Testing
import Foundation
import AppKit
import CoreImage
import ImageIO
import SwiftMediaMetadata
@testable import Aagedal_Photo_Agent

/// Verifies the shared export pipeline both renders a file AND overlays pending IPTC
/// sidecar edits onto the output. The overlay is the step the FTP "publish to web"
/// path used to skip, which dropped edited keywords/captions from uploaded files;
/// routing every export path through `renderItem` is what fixed that. Drives the real
/// renderer, write engine, and sidecar services against files on disk.
@Suite("EditExportPipeline render + sidecar overlay (real file)")
struct EditExportPipelineTests {

    @Test("Pending rotation is presented consistently and blocks export before creating output")
    func pendingRotationPresentationAndExportAdmission() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PendingRotationExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("photo.jpg")
        let sourceBytes = Data("source must not be decoded or changed".utf8)
        try sourceBytes.write(to: source)
        let draft = MetadataOrientationDraft(expectedOrientation: 1, targetOrientation: 6)
        try MetadataSidecarService().saveSidecar(MetadataSidecar(sourceFile: source.lastPathComponent,
            pendingChanges: true, metadata: IPTCMetadata(title: "Pending caption"),
            orientationDraft: draft), for: source, in: folder)
        var xmp = IPTCMetadata()
        xmp.exifOrientation = 1
        try XMPSidecarService().saveSidecar(metadata: xmp, for: source)
        #expect(ThumbnailSourceAccess.system.sidecarOrientation(source) == 6)
        #expect(FullScreenImageCache.displayOrientation(for: source, fallback: 1) == 6)
        #expect(FullScreenImagePresentationFactsAccess.system.read(source).sidecarOrientation == 6)
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        do {
            _ = try await EditExportPipeline.renderItem(sourceURL: source, cameraRaw: nil, kind: .jpeg,
                outputFolder: output, folderURL: folder, writeEngine: SwiftExifWriteEngine(),
                failureTracker: MetadataFailureTracker())
            Issue.record("Export must require the saved rotation to be applied first")
        } catch {
            #expect(error.localizedDescription.contains("Write Pending Rotation"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(MetadataSidecarService().loadSidecar(for: source, in: folder)?.orientationDraft == draft)
    }

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

    @Test("Camera Raw resolution re-reads persisted settings and lets live win only for the Develop photo")
    func cameraRawResolutionPrefersPersistedSettings() async throws {
        let liveURL = URL(fileURLWithPath: "/virtual/live.ARW")
        let developURL = URL(fileURLWithPath: "/virtual/develop.ARW")
        let sidecarURL = URL(fileURLWithPath: "/virtual/sidecar.CR3")
        let jpegURL = URL(fileURLWithPath: "/virtual/finished.jpg")
        let embeddedJPEGURL = URL(fileURLWithPath: "/virtual/embedded.jpg")
        var liveSettings = CameraRawSettings()
        liveSettings.exposure2012 = 1
        var sidecarSettings = CameraRawSettings()
        sidecarSettings.exposure2012 = 2
        var embeddedSettings = CameraRawSettings()
        embeddedSettings.contrast2012 = 30
        let probe = ExportCameraRawResolutionProbe(settingsByURL: [
            liveURL: sidecarSettings,
            developURL: sidecarSettings,
            sidecarURL: sidecarSettings,
            jpegURL: sidecarSettings,
        ])
        let service = ExportCameraRawResolutionService(access: probe.access)
        let requestID = UUID()
        let urls = [liveURL, developURL, sidecarURL, jpegURL, embeddedJPEGURL]

        let result = await service.resolve(ExportCameraRawResolutionRequest(
            requestID: requestID,
            imageURLs: urls,
            liveSettingsByImageURL: [liveURL: liveSettings, developURL: liveSettings, embeddedJPEGURL: liveSettings],
            embeddedSettingsByImageURL: [embeddedJPEGURL: embeddedSettings],
            liveAuthoritativeImageURLs: [developURL]
        ))

        guard case .complete(let snapshot) = result else {
            Issue.record("Expected a complete Camera Raw resolution snapshot")
            return
        }
        #expect(snapshot.requestID == requestID)
        #expect(snapshot.requestedSidecarImageURLs == urls)
        #expect(snapshot.inspectedImageURLs == urls)
        // A browser copy never overrides what the file says, except for the photo in Develop.
        #expect(snapshot.settingsByImageURL[liveURL] == sidecarSettings)
        #expect(snapshot.settingsByImageURL[developURL] == liveSettings)
        #expect(snapshot.settingsByImageURL[sidecarURL] == sidecarSettings)
        // A non-RAW file's own sidecar develop applies; otherwise its embedded block does.
        #expect(snapshot.settingsByImageURL[jpegURL] == sidecarSettings)
        #expect(snapshot.settingsByImageURL[embeddedJPEGURL] == embeddedSettings)
        #expect(probe.loadedURLs == urls)
    }

    @Test("Export source policy never drops a redaction present in only one copy")
    func exportSourcePolicyKeepsRedactions() {
        var redacted = CameraRawSettings()
        redacted.exposure2012 = 0.3
        redacted.localAdjustments = [MaskAdjustment(name: "Face", anonymizer: AnonymizerSettings(amount: 90, blackOut: nil))]
        var globalRedacted = CameraRawSettings()
        globalRedacted.anonymizer = AnonymizerSettings(amount: nil, blackOut: true)
        var incomplete = CameraRawSettings()
        incomplete.exposure2012 = 0.3
        var newerEdit = CameraRawSettings()
        newerEdit.exposure2012 = 1.2

        // The stale browser copy (masks/anonymizer missing) must not replace the file's copy.
        #expect(ExportCameraRawSourcePolicy.resolve(live: incomplete, persisted: redacted, liveIsAuthoritative: false) == redacted)
        #expect(ExportCameraRawSourcePolicy.resolve(live: incomplete, persisted: globalRedacted, liveIsAuthoritative: false) == globalRedacted)
        // Even the Develop photo's live copy can't silently drop a persisted redaction.
        #expect(ExportCameraRawSourcePolicy.resolve(live: incomplete, persisted: redacted, liveIsAuthoritative: true) == redacted)
        // A redaction not yet on disk (save in flight) still reaches the render.
        #expect(ExportCameraRawSourcePolicy.resolve(live: redacted, persisted: incomplete, liveIsAuthoritative: false) == redacted)
        // Ordinary edits: Develop's live copy wins; elsewhere the file wins.
        #expect(ExportCameraRawSourcePolicy.resolve(live: newerEdit, persisted: incomplete, liveIsAuthoritative: true) == newerEdit)
        #expect(ExportCameraRawSourcePolicy.resolve(live: newerEdit, persisted: incomplete, liveIsAuthoritative: false) == incomplete)
        #expect(ExportCameraRawSourcePolicy.resolve(live: nil, persisted: redacted, liveIsAuthoritative: true) == redacted)
        #expect(ExportCameraRawSourcePolicy.resolve(live: newerEdit, persisted: nil, liveIsAuthoritative: false) == newerEdit)
        #expect(ExportCameraRawSourcePolicy.resolve(live: CameraRawSettings(), persisted: nil, liveIsAuthoritative: true) == nil)
    }

    @MainActor
    @Test("A JPEG's embedded redaction, watermark and global Anonymizer survive a Browser reload and reach the export render",
          arguments: [false, true])
    func embeddedJPEGRedactionSurvivesReloadAndExport(pairedWithRAW: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("apa-embedded-redaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("IMG_1.JPG")
        try checkerboardJPEG().write(to: jpeg)

        var face = MaskAdjustment(name: "Face", anonymizer: AnonymizerSettings(amount: 100, blackOut: nil))
        face.geometry = EllipseMaskGeometry(centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.3, rotation: 0, feather: 0)
        var embedded = CameraRawSettings()
        embedded.hasSettings = true
        embedded.localAdjustments = [face]
        embedded.anonymizer = AnonymizerSettings(amount: 60, blackOut: nil)
        embedded.watermarkLayers = [WatermarkLayer(libraryAssetID: UUID())]
        embedded.layerOrder = embedded.resolvedLayerOrder()
        var metadata = try SwiftMediaMetadata.readMetadata(from: jpeg)
        var xmp = metadata.xmp ?? XMPData()
        XMPDataBuilder.applyCameraRaw(embedded, imageAspect: nil, into: &xmp)
        metadata.xmp = xmp
        _ = try metadata.write(to: jpeg)

        if pairedWithRAW {
            // The RAW's stem sidecar: its develop (no redaction) must not reach the JPEG.
            try Data("raw".utf8).write(to: dir.appendingPathComponent("IMG_1.ARW"))
            var rawDevelop = CameraRawSettings()
            rawDevelop.exposure2012 = 1.5
            rawDevelop.temperature = 3200
            var sidecar = XMPData()
            sidecar.description = "Pair caption"
            XMPDataBuilder.applyCameraRaw(rawDevelop, imageAspect: nil, into: &sidecar)
            try XMPWriter.generateXML(sidecar).data(using: .utf8)!
                .write(to: dir.appendingPathComponent("IMG_1.xmp"))
        }

        // An unrelated metadata write to the file.
        var rewritten = try SwiftMediaMetadata.readMetadata(from: jpeg)
        var rewrittenXMP = rewritten.xmp ?? XMPData()
        rewrittenXMP.description = "Unrelated caption edit"
        rewritten.xmp = rewrittenXMP
        _ = try rewritten.write(to: jpeg)

        // Browser reload. The row starts with a stale, incomplete in-memory copy (what the old
        // Browser parser produced); a file change clears it in production.
        let model = BrowserViewModel()
        model.currentFolderURL = dir
        var stale = CameraRawSettings()
        stale.hasSettings = true
        var row = ImageFile(url: jpeg)
        row.cameraRawSettings = stale
        var images = [row]
        let dicts = try await SwiftExifReadService().readBatchBasicMetadata(urls: [jpeg])
        let xmpMap = PhotoSidecarOwnership.applyingDevelopOwnership(
            XMPSidecarService().loadSidecar(for: jpeg), for: jpeg
        ).map { [jpeg: $0] } ?? [:]
        model.applyBatchMetadataResults(dicts, to: &images, localIndex: [jpeg: 0], nativeHDRByURL: [:],
                                        tagRevisionsAtRead: nil)
        let reloaded = try #require(images[0].cameraRawSettings)
        #expect(reloaded.localAdjustments?.first?.isRedaction == true)
        #expect(reloaded.anonymizer == AnonymizerSettings(amount: 60, blackOut: nil))
        #expect(reloaded.watermarkLayers?.count == 1)
        #expect(reloaded.exposure2012 == nil, "the RAW's develop must not reach the paired JPEG")
        var withSidecar = [row]
        model.applyBatchMetadataResults(dicts, to: &withSidecar, localIndex: [jpeg: 0],
                                        xmpMetadataMap: xmpMap, nativeHDRByURL: [:])
        #expect(withSidecar[0].cameraRawSettings?.hasActiveRedaction == true)
        #expect(withSidecar[0].cameraRawSettings?.exposure2012 == nil)

        // Export resolution: even a stale in-memory copy can't replace the complete file copy.
        var map = try await SwiftExifReadService().readBatchFullMetadata(urls: [jpeg])
        try await EditExportPipeline.resolveCameraRaw(into: &map, urls: [jpeg], inMemory: { _ in stale })
        let resolved = try #require(map[jpeg]?.cameraRaw)
        #expect(resolved.hasActiveRedaction)
        #expect(resolved.anonymizer == AnonymizerSettings(amount: 60, blackOut: nil))
        #expect(resolved.watermarkLayers?.count == 1)
        #expect(resolved.exposure2012 == nil)

        // The render with the resolved settings is blurred where the face mask sits. (The
        // watermark layer is left out of the render: its library asset would be looked up in the
        // user's real watermark library.)
        var renderSettings = resolved
        renderSettings.watermarkLayers = nil
        renderSettings.layerOrder = nil
        let redactedDir = dir.appendingPathComponent("redacted", isDirectory: true)
        let plainDir = dir.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: redactedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
        let tracker = MetadataFailureTracker()
        let redactedRender = try await EditExportPipeline.renderItem(
            sourceURL: jpeg, cameraRaw: renderSettings, kind: .jpeg, outputFolder: redactedDir,
            folderURL: dir, writeEngine: SwiftExifWriteEngine(), failureTracker: tracker)
        // The unedited baseline bypasses the saved-redaction check (which would refuse it).
        let plainRender = try await EditExportPipeline.renderItem(
            sourceURL: jpeg, cameraRaw: nil, kind: .jpeg, outputFolder: plainDir,
            folderURL: dir, writeEngine: SwiftExifWriteEngine(), failureTracker: tracker,
            savedRedactionAccess: ExportSavedRedactionAccess { _ in [] })
        let redactedDeviation = try centerLuminanceDeviation(of: redactedRender)
        let plainDeviation = try centerLuminanceDeviation(of: plainRender)
        #expect(plainDeviation > 60, "the unedited checkerboard should be high-contrast (\(plainDeviation))")
        #expect(redactedDeviation < plainDeviation * 0.5,
                "the masked face region must be blurred (\(redactedDeviation) vs \(plainDeviation))")
    }

    /// 128×128 JPEG of 2-pixel black/white checks — maximal local contrast, so any blur shows.
    private func checkerboardJPEG() throws -> Data {
        let size = 128
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size where ((x / 2) + (y / 2)) % 2 == 0 {
                let i = (y * size + x) * 4
                pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 255
            }
        }
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    /// Standard deviation of 8-bit luminance over the central 20% square of the image at `url`.
    private func centerLuminanceDeviation(of url: URL) throws -> Double {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileReadCorruptFile) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var values: [Double] = []
        for y in (height * 2 / 5)..<(height * 3 / 5) {
            for x in (width * 2 / 5)..<(width * 3 / 5) {
                let i = (y * width + x) * 4
                values.append(0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2]))
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    @MainActor
    @Test("resolveCameraRaw applies settings to files whose metadata read failed")
    func resolveCameraRawFillsFilesMissingFromMetadataMap() async throws {
        let readURL = URL(fileURLWithPath: "/virtual/read-ok.ARW")
        let unreadableRAW = URL(fileURLWithPath: "/virtual/unreadable.ARW")
        let unreadableLive = URL(fileURLWithPath: "/virtual/unreadable-live.jpg")
        let notRequested = URL(fileURLWithPath: "/virtual/not-requested.ARW")
        var sidecarSettings = CameraRawSettings()
        sidecarSettings.exposure2012 = 1.5
        var liveSettings = CameraRawSettings()
        liveSettings.contrast2012 = 20
        let probe = ExportCameraRawResolutionProbe(settingsByURL: [
            readURL: sidecarSettings,
            unreadableRAW: sidecarSettings,
            notRequested: sidecarSettings,
        ])
        let service = ExportCameraRawResolutionService(access: probe.access)
        // Only one file parsed; the other two were dropped by readBatchFullMetadata.
        var map: [URL: IPTCMetadata] = [readURL: IPTCMetadata(title: "Kept caption")]

        try await EditExportPipeline.resolveCameraRaw(
            into: &map,
            urls: [readURL, unreadableRAW, unreadableLive],
            inMemory: { $0 == unreadableLive ? liveSettings : nil },
            service: service
        )

        #expect(map[readURL]?.cameraRaw == sidecarSettings)
        #expect(map[readURL]?.title == "Kept caption")
        #expect(map[unreadableRAW]?.cameraRaw == sidecarSettings)
        #expect(map[unreadableLive]?.cameraRaw == liveSettings)
        #expect(map[notRequested] == nil)
        #expect(map.count == 3)
    }

    @Test("Camera Raw resolution reports the exact prefix when cancellation follows a sidecar read")
    func cameraRawResolutionReportsPostReadCancellation() async {
        let firstURL = URL(fileURLWithPath: "/virtual/first.ARW")
        let secondURL = URL(fileURLWithPath: "/virtual/second.ARW")
        var settings = CameraRawSettings()
        settings.contrast2012 = 10
        let probe = ExportCameraRawResolutionProbe(
            settingsByURL: [firstURL: settings, secondURL: settings],
            cancelAtInvocation: 1
        )
        let service = ExportCameraRawResolutionService(access: probe.access)
        let requestID = UUID()

        let result = await Task {
            await service.resolve(ExportCameraRawResolutionRequest(
                requestID: requestID,
                imageURLs: [firstURL, secondURL],
                liveSettingsByImageURL: [:]
            ))
        }.value

        guard case .cancelledAfterPartialRead(let snapshot) = result else {
            Issue.record("Expected cancellation after the first non-preemptible sidecar read")
            return
        }
        #expect(snapshot.requestID == requestID)
        #expect(snapshot.requestedSidecarImageURLs == [firstURL, secondURL])
        #expect(snapshot.inspectedImageURLs == [firstURL])
        #expect(snapshot.settingsByImageURL[firstURL] == settings)
        #expect(snapshot.settingsByImageURL[secondURL] == nil)
        #expect(probe.loadedURLs == [firstURL])
    }

    @MainActor
    @Test("Camera Raw sidecar reads leave MainActor and serialize overlapping batches")
    func cameraRawResolutionIsOffMainAndSerialized() async {
        let firstURL = URL(fileURLWithPath: "/virtual/first.ARW")
        let secondURL = URL(fileURLWithPath: "/virtual/second.ARW")
        let probe = ExportCameraRawResolutionProbe(blockFirstLoad: true)
        let service = ExportCameraRawResolutionService(access: probe.access)

        let first = Task { @MainActor in
            await service.resolve(ExportCameraRawResolutionRequest(
                requestID: UUID(),
                imageURLs: [firstURL],
                liveSettingsByImageURL: [:]
            ))
        }
        await probe.waitUntilFirstLoadStarts()
        let second = Task { @MainActor in
            await service.resolve(ExportCameraRawResolutionRequest(
                requestID: UUID(),
                imageURLs: [secondURL],
                liveSettingsByImageURL: [:]
            ))
        }
        await Task.yield()

        #expect(probe.loadInvocationCount == 1)
        probe.releaseFirstLoad()
        _ = await first.value
        _ = await second.value

        #expect(probe.maximumConcurrentLoads == 1)
        #expect(!probe.ranOnMainThread)
        #expect(probe.loadedURLs == [firstURL, secondURL])
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

    @Test("Delivery rejects known metadata failures and keeps recoverable pixels",
          arguments: [(true, false), (false, true), (true, true)])
    func deliveryRejectsIncompleteMetadata(failures: (Bool, Bool)) async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pending = IPTCMetadata(title: "Pending delivery headline", keywords: ["Oslo, Norway"])
        try MetadataSidecarService().saveSidecar(MetadataSidecar(
            sourceFile: source.lastPathComponent, pendingChanges: true, metadata: pending),
            for: source, in: dir)
        let sourceBytes = try Data(contentsOf: source)
        let output = dir.appendingPathComponent("delivery")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let engine = ExportFailureEngine(failCopy: failures.0, failOverlay: failures.1)
        let tracker = MetadataFailureTracker()
        var authorizedURLs: [URL] = []
        do {
            let url = try await EditExportPipeline.renderForDelivery(sourceURL: source, cameraRaw: nil,
                kind: .jpeg, outputFolder: output, folderURL: dir,
                writeEngine: engine, failureTracker: tracker)
            authorizedURLs.append(url)
            Issue.record("Metadata failure must prevent delivery authorization")
        } catch let error as ExportMetadataIncompleteError {
            #expect(error.copyFailed == failures.0)
            #expect(error.overlayFailed == failures.1)
            #expect(FileManager.default.fileExists(atPath: error.renderedURL.path))
            let image = try #require(CGImageSourceCreateWithURL(error.renderedURL as CFURL, nil))
            #expect(CGImageSourceCreateImageAtIndex(image, 0, nil) != nil)
        }
        #expect(authorizedURLs.isEmpty)
        #expect(await tracker.metadataCopyFailures == (failures.0 ? [source.lastPathComponent] : []))
        #expect(await tracker.sidecarOverlayFailures == (failures.1 ? [source.lastPathComponent] : []))
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(MetadataSidecarService().loadSidecar(for: source, in: dir)?.metadata.title == pending.title)

        // Local exports preserve the same useful pixels and report failures to their caller.
        let localTracker = MetadataFailureTracker()
        let local = try await EditExportPipeline.renderItem(sourceURL: source, cameraRaw: nil,
            kind: .jpeg, outputFolder: output, folderURL: dir,
            writeEngine: engine, failureTracker: localTracker)
        #expect(FileManager.default.fileExists(atPath: local.path))
        #expect(await localTracker.metadataCopyFailures.count == (failures.0 ? 1 : 0))
        #expect(await localTracker.sidecarOverlayFailures.count == (failures.1 ? 1 : 0))
    }

    @Test("An earlier same-name batch failure does not reject a metadata-complete delivery")
    func deliveryUsesOnlyCurrentItemFailures() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pending = IPTCMetadata(title: "Ready for delivery", keywords: ["Oslo, Norway", "ready"])
        try MetadataSidecarService().saveSidecar(MetadataSidecar(
            sourceFile: source.lastPathComponent, pendingChanges: true, metadata: pending),
            for: source, in: dir)
        let output = dir.appendingPathComponent("delivery")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let tracker = MetadataFailureTracker()
        await tracker.recordCopyFailure(source.lastPathComponent)
        await tracker.recordOverlayFailure(source.lastPathComponent)
        let rendered = try await EditExportPipeline.renderForDelivery(sourceURL: source, cameraRaw: nil,
            kind: .jpeg, outputFolder: output, folderURL: dir,
            writeEngine: SwiftExifWriteEngine(), failureTracker: tracker)
        let actual = try await SwiftExifReadService().readFullMetadata(url: rendered)
        #expect(actual.title == pending.title)
        #expect(actual.keywords == pending.keywords)
        #expect(await tracker.metadataCopyFailures.count == 1)
        #expect(await tracker.sidecarOverlayFailures.count == 1)
    }

    /// Creates a raster TIFF carrying a Sony Make tag. SwiftMediaMetadata 3 must keep the
    /// unambiguous `.tiff` URL classified as TIFF rather than treating camera Make as proof of ARW.
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

        var metadata = try SwiftMediaMetadata.readMetadata(from: source)
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

        var planted = try SwiftMediaMetadata.readMetadata(from: source)
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

    @Test("Pending app drafts override existing XMP on export, including descriptive clears",
          arguments: [false, true])
    func pendingDraftWinsOverExistingXMP(clearsDescription: Bool) async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = SwiftExifWriteEngine()
        try await engine.writeFields([.headline: "Embedded", .description: "Embedded caption",
                                      .subject: "embedded"], to: [source])
        try XMPSidecarService().saveSidecar(metadata: IPTCMetadata(
            title: "Saved XMP", description: "Saved XMP caption", keywords: ["saved"]
        ), for: source)
        let pending = IPTCMetadata(title: clearsDescription ? nil : "Pending headline",
            localizedTitles: clearsDescription ? [] : nil,
            description: clearsDescription ? nil : "Pending caption",
            keywords: clearsDescription ? [] : ["pending"])
        try MetadataSidecarService().saveSidecar(MetadataSidecar(
            sourceFile: source.lastPathComponent, pendingChanges: true, metadata: pending
        ), for: source, in: dir)
        let sourceBytes = try Data(contentsOf: source)
        let xmpURL = XMPSidecarService().sidecarURL(for: source)
        let xmpBytes = try Data(contentsOf: xmpURL)
        let output = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(sourceURL: source, cameraRaw: nil,
            kind: .jpeg, outputFolder: output, folderURL: dir, writeEngine: engine,
            failureTracker: tracker)
        let actual = try await SwiftExifReadService().readFullMetadata(url: rendered)
        #expect((actual.title ?? "") == (pending.title ?? ""))
        #expect((actual.description ?? "") == (pending.description ?? ""))
        #expect(actual.keywords == pending.keywords)
        #expect(await tracker.sidecarOverlayFailures.isEmpty)
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(try Data(contentsOf: xmpURL) == xmpBytes)
        #expect(MetadataSidecarService().loadSidecar(for: source, in: dir)?.pendingChanges == true)
    }

    @Test("Edited exports preserve exact IPTC list values and clears from JSON and XMP",
          arguments: [false, true], ["jpeg", "png", "tiff"])
    func renderedListsRemainLossless(usesJSON: Bool, format: String) async throws {
        for clearsLists in [false, true] {
            try await assertRenderedLists(usesJSON: usesJSON, clearsLists: clearsLists, format: format)
        }
    }

    private func assertRenderedLists(usesJSON: Bool, clearsLists: Bool, format: String) async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = SwiftExifWriteEngine()
        try await engine.writeFields([.headline: "Embedded", .subject: "old keyword",
            .personInImage: "Old Person", .organisationInImageName: "Old Organisation",
            .organisationInImageCode: "OLD"], to: [source])
        let expected = IPTCMetadata(title: "Edited caption",
            keywords: clearsLists ? [] : ["Washington, D.C.", "Côte d’Ivoire", "Norge, Oslo"],
            personShown: clearsLists ? [] : ["Doe, Jane", "Ødegård, Åse"],
            organisationsShownNames: clearsLists ? [] : ["Acme, Inc.", "Photo, News"],
            organisationsShownCodes: clearsLists ? [] : ["Agency, NO", "Agency, US"])
        if usesJSON {
            try MetadataSidecarService().saveSidecar(MetadataSidecar(
                sourceFile: source.lastPathComponent, pendingChanges: true, metadata: expected
            ), for: source, in: dir)
        } else {
            try XMPSidecarService().saveSidecar(metadata: expected, for: source)
        }
        let sourceBytes = try Data(contentsOf: source)
        let output = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var settings = CameraRawSettings()
        settings.exposure2012 = 0.5
        let tracker = MetadataFailureTracker()
        // Develop Save and ordinary format export share .format; Save As uses the same overlay.
        let kind: RenderKind = switch format {
        case "png": .saveAs(.png)
        default: .format
        }
        var configuration = collisionSafeJPEGConfiguration
        if format == "tiff" { configuration.sdrFormat = .tiff }
        let rendered = try await EditExportPipeline.renderItem(sourceURL: source, cameraRaw: settings,
            kind: kind, outputFolder: output, folderURL: dir, writeEngine: engine,
            failureTracker: tracker, configuration: configuration)
        let actual = try await SwiftExifReadService().readFullMetadata(url: rendered)
        let physical = try SwiftMediaMetadata.readMetadata(from: rendered)
        #expect(actual.title == expected.title)
        #expect(actual.keywords == expected.keywords)
        #expect(actual.personShown == expected.personShown)
        #expect(actual.organisationsShownNames == expected.organisationsShownNames)
        #expect(actual.organisationsShownCodes == expected.organisationsShownCodes)
        if format != "png" { #expect(physical.iptc.keywords == expected.keywords) }
        #expect((physical.xmp?.subject ?? []) == expected.keywords)
        #expect(await tracker.metadataCopyFailures.isEmpty)
        #expect(await tracker.sidecarOverlayFailures.isEmpty)
        #expect(try Data(contentsOf: source) == sourceBytes)
        if usesJSON {
            let retained = try #require(MetadataSidecarService().loadSidecar(for: source, in: dir))
            #expect(retained.pendingChanges)
            #expect(retained.metadata.keywords == expected.keywords)
        } else {
            #expect(XMPSidecarService().loadSidecar(for: source)?.keywords == expected.keywords)
        }
    }

    @Test("Typed list writes preserve field scope, explicit clears and legacy text parsing")
    func typedListFieldScope() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = SwiftExifWriteEngine()
        try await engine.writeFields([.headline: "Keep title", .personInImage: "Keep person",
            .organisationInImageName: "Keep organisation"], to: [source])
        let intended = IPTCMetadata(keywords: ["Washington, D.C."], personShown: ["Unselected person"])
        try await engine.writeFields([.subject: "ignored legacy transport"], to: [source],
            structuredData: StructuredWriteData(listValues: EditorialListWriteData(metadata: intended)))
        let actual = try await SwiftExifReadService().readFullMetadata(url: source)
        #expect(actual.keywords == intended.keywords)
        #expect(actual.title == "Keep title")
        #expect(actual.personShown == ["Keep person"])
        #expect(actual.organisationsShownNames == ["Keep organisation"])
        try await engine.writeFields([.subject: "stale value"], to: [source],
            structuredData: StructuredWriteData(listValues: EditorialListWriteData(metadata: IPTCMetadata())))
        #expect(try SwiftMediaMetadata.readMetadata(from: source).iptc.keywords.isEmpty)
        #expect(try await SwiftExifReadService().readFullMetadata(url: source).keywords.isEmpty)
        try await engine.writeFields([.subject: "one, two"], to: [source])
        #expect(try await SwiftExifReadService().readFullMetadata(url: source).keywords == ["one", "two"])
    }

    @Test("Complete pending writes keep legacy IPTC and XMP keyword boundaries identical")
    func completeRecordListCarriersAgree() async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let intended = IPTCMetadata(title: "Complete editorial record",
            keywords: ["Washington, D.C.", "Côte d’Ivoire"], personShown: ["Doe, Jane"],
            organisationsShownNames: ["Acme, Inc."], organisationsShownCodes: ["Agency, NO"])
        let receipt = try await SwiftExifWriteEngine().writePendingMetadata(intended, to: source,
            validatePreparedIntent: {})
        let physical = try SwiftMediaMetadata.readMetadata(from: source)
        #expect(physical.iptc.keywords == intended.keywords)
        #expect(physical.xmp?.subject == intended.keywords)
        #expect(receipt.metadata.keywords == intended.keywords)
        #expect(receipt.metadata.personShown == intended.personShown)
        #expect(receipt.metadata.organisationsShownNames == intended.organisationsShownNames)
        #expect(receipt.metadata.organisationsShownCodes == intended.organisationsShownCodes)
    }

    @Test("Rendered sidecar overlay preserves explicit label clears and missing-label inheritance", arguments: [false, true], [false, true])
    func renderedLabelClearPropagation(usesJSON: Bool, explicitlyClears: Bool) async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = SwiftExifWriteEngine()
        let oldLabel = try #require(ColorLabel.red.xmpLabelValue)
        try await engine.writeFields([.label: oldLabel, .headline: "Embedded headline"], to: [source])
        let sourceBytes = try Data(contentsOf: source)
        // Rating ensures a partial record remains meaningful even when Label is absent.
        let pending = IPTCMetadata(rating: 3, label: explicitlyClears ? "" : nil)
        if usesJSON {
            try MetadataSidecarService().saveSidecar(MetadataSidecar(
                sourceFile: source.lastPathComponent, pendingChanges: true, metadata: pending
            ), for: source, in: dir)
        } else {
            try XMPSidecarService().saveSidecar(metadata: pending, for: source)
            #expect(XMPSidecarService().loadSidecar(for: source)?.label == pending.label)
        }
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source, cameraRaw: nil, kind: .jpeg,
            outputFolder: outDir, folderURL: dir,
            writeEngine: engine, failureTracker: tracker)

        #expect(await tracker.sidecarOverlayFailures.isEmpty)
        let actual = try SwiftMediaMetadata.readMetadata(from: rendered)
        if explicitlyClears {
            #expect(actual.xmp?.label == nil || actual.xmp?.label == "")
        } else {
            #expect(actual.xmp?.label == oldLabel)
        }
        #expect(try await SwiftExifReadService().readFullMetadata(url: rendered).title == "Embedded headline")
        #expect(try await SwiftExifReadService().readFullMetadata(url: rendered).rating == 3)
        #expect(try Data(contentsOf: source) == sourceBytes)
    }

    @Test("FTP sync field mapping clears an old embedded label without clearing unmodeled text", arguments: [false, true])
    func ftpSyncLabelClearPropagation(explicitlyClears: Bool) async throws {
        let (dir, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = SwiftExifWriteEngine()
        let oldLabel = try #require(ColorLabel.red.xmpLabelValue)
        try await engine.writeFields([.label: oldLabel, .headline: "Keep embedded headline"], to: [source])
        try XMPSidecarService().saveSidecar(
            metadata: IPTCMetadata(rating: 4, label: explicitlyClears ? "" : nil), for: source)
        let pending = try #require(XMPSidecarService().loadSidecar(for: source))
        // This is the same mapping and physical-write boundary used by FTPUploadView.mergeSidecar.
        let fields = SidecarIPTCOverlay.authoritativeFields(from: pending)
        #expect(fields[.label] == (explicitlyClears ? "" : nil))
        #expect(fields[.headline] == nil)
        try await engine.writeFields(fields, to: [source], structuredData: StructuredWriteData(editorial: nil))

        let actual = try SwiftMediaMetadata.readMetadata(from: source)
        if explicitlyClears {
            #expect(actual.xmp?.label == nil || actual.xmp?.label == "")
        } else {
            #expect(actual.xmp?.label == oldLabel)
        }
        #expect(try await SwiftExifReadService().readFullMetadata(url: source).title == "Keep embedded headline")
        #expect(try await SwiftExifReadService().readFullMetadata(url: source).rating == 4)
    }

    @Test("Sony-authored raster TIFF accepts direct and sidecar IPTC writes")
    func renderedSonyTIFFAcceptsSidecarIPTC() async throws {
        let (dir, source) = try makeSonyTIFFWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = SwiftExifWriteEngine()
        try await engine.writeFields([.headline: "Direct TIFF write"], to: [source])
        #expect(try await SwiftExifReadService().readFullMetadata(url: source).title == "Direct TIFF write")

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
        let embedded = try SwiftMediaMetadata.readMetadata(from: rendered)
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
        let embedded = try SwiftMediaMetadata.readMetadata(from: rendered)
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
        let embedded = try SwiftMediaMetadata.readMetadata(from: rendered)
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
        let rendered = try await EditExportPipeline.renderForDelivery(
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
        let metadata = try SwiftMediaMetadata.readMetadata(from: source)

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
    func exportArtifactIsMadeVisible() async throws {
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

        try await EditExportPipeline.ensureExportArtifactIsVisible(at: artifact)

        #expect(try artifact.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
        #expect(try Data(contentsOf: artifact) == Data("rendered".utf8))
    }

    @MainActor
    @Test("artifact finalization leaves MainActor and serializes overlapping requests")
    func artifactFinalizationIsOffMainAndSerialized() async throws {
        let firstURL = URL(fileURLWithPath: "/virtual/first.jpg")
        let secondURL = URL(fileURLWithPath: "/virtual/second.jpg")
        let probe = ExportArtifactFinalizationProbe(blockFirstVisibilityRead: true)
        let service = ExportArtifactFinalizationService(io: probe.io)

        let first = Task { @MainActor in
            try await service.finalize(ExportArtifactFinalizationRequest(
                requestID: UUID(),
                sourceURL: firstURL,
                renderedURL: firstURL,
                copiesRAWArchiveSidecar: false
            ))
        }
        await probe.waitUntilFirstVisibilityReadStarts()
        let second = Task { @MainActor in
            try await service.finalize(ExportArtifactFinalizationRequest(
                requestID: UUID(),
                sourceURL: secondURL,
                renderedURL: secondURL,
                copiesRAWArchiveSidecar: false
            ))
        }
        await Task.yield()

        #expect(probe.visibilityReadInvocationCount == 1)
        probe.releaseFirstVisibilityRead()
        _ = try await first.value
        _ = try await second.value

        #expect(probe.maximumConcurrentOperations == 1)
        #expect(!probe.ranOnMainThread)
        #expect(probe.visibilityReadURLs == [firstURL, secondURL])
    }

    @Test("RAW finalization removes incomplete pixels when sidecar copying fails")
    func artifactFinalizationCompensatesForSidecarFailure() async {
        let sourceURL = URL(fileURLWithPath: "/virtual/source.ARW")
        let renderedURL = URL(fileURLWithPath: "/virtual/archive.tiff")
        let probe = ExportArtifactFinalizationProbe(sidecarCopyFails: true)
        let service = ExportArtifactFinalizationService(io: probe.io)

        do {
            _ = try await service.finalize(ExportArtifactFinalizationRequest(
                requestID: UUID(),
                sourceURL: sourceURL,
                renderedURL: renderedURL,
                copiesRAWArchiveSidecar: true
            ))
            Issue.record("Expected sidecar finalization to fail")
        } catch {
            #expect(probe.sidecarCopies == [ExportArtifactFinalizationProbe.Copy(
                sourceURL: sourceURL,
                renderedURL: renderedURL
            )])
            #expect(probe.removedURLs == [renderedURL])
            #expect(probe.visibilityReadURLs.isEmpty)
        }
    }

    @Test("artifact finalization records cancellation without skipping durable postconditions")
    func artifactFinalizationRecordsCancellationAfterCommit() async throws {
        let sourceURL = URL(fileURLWithPath: "/virtual/source.ARW")
        let renderedURL = URL(fileURLWithPath: "/virtual/archive.tiff")
        let probe = ExportArtifactFinalizationProbe(
            hiddenURLs: [renderedURL],
            cancelDuringSidecarCopy: true
        )
        let service = ExportArtifactFinalizationService(io: probe.io)
        let requestID = UUID()

        let evidence = try await Task {
            try await service.finalize(ExportArtifactFinalizationRequest(
                requestID: requestID,
                sourceURL: sourceURL,
                renderedURL: renderedURL,
                copiesRAWArchiveSidecar: true
            ))
        }.value

        #expect(evidence.requestID == requestID)
        #expect(evidence.finalizedRAWArchiveSidecar)
        #expect(evidence.madeArtifactVisible)
        #expect(!evidence.cancellationObservedBeforeFinalization)
        #expect(evidence.cancellationObservedAfterFinalization)
        #expect(probe.visibleURLs == [renderedURL])
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

private nonisolated final class ExportCameraRawResolutionProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let settingsByURL: [URL: CameraRawSettings]
    private let cancelAtInvocation: Int?
    private let blockFirstLoad: Bool
    private var didReleaseFirstLoad = false
    private var activeLoads = 0
    private var _maximumConcurrentLoads = 0
    private var _loadInvocationCount = 0
    private var _ranOnMainThread = false
    private var _loadedURLs: [URL] = []

    init(
        settingsByURL: [URL: CameraRawSettings] = [:],
        cancelAtInvocation: Int? = nil,
        blockFirstLoad: Bool = false
    ) {
        self.settingsByURL = settingsByURL
        self.cancelAtInvocation = cancelAtInvocation
        self.blockFirstLoad = blockFirstLoad
    }

    var access: ExportCameraRawSidecarAccess {
        ExportCameraRawSidecarAccess { [self] url in
            condition.lock()
            _loadInvocationCount += 1
            activeLoads += 1
            _maximumConcurrentLoads = max(_maximumConcurrentLoads, activeLoads)
            _ranOnMainThread = _ranOnMainThread || Thread.isMainThread
            _loadedURLs.append(url)
            let invocation = _loadInvocationCount
            condition.broadcast()
            while blockFirstLoad, invocation == 1, !didReleaseFirstLoad {
                if !condition.waitBounded() { break }
            }
            activeLoads -= 1
            condition.broadcast()
            condition.unlock()

            if invocation == cancelAtInvocation {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return settingsByURL[url]
        }
    }

    var loadedURLs: [URL] { condition.withLock { _loadedURLs } }
    var loadInvocationCount: Int { condition.withLock { _loadInvocationCount } }
    var maximumConcurrentLoads: Int { condition.withLock { _maximumConcurrentLoads } }
    var ranOnMainThread: Bool { condition.withLock { _ranOnMainThread } }

    func releaseFirstLoad() {
        condition.withLock {
            didReleaseFirstLoad = true
            condition.broadcast()
        }
    }

    func waitUntilFirstLoadStarts() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                while _loadInvocationCount == 0 {
                    if !condition.waitBounded() { break }
                }
                condition.unlock()
                continuation.resume()
            }
        }
    }
}

private nonisolated final class ExportArtifactFinalizationProbe: @unchecked Sendable {
    struct Copy: Equatable {
        let sourceURL: URL
        let renderedURL: URL
    }

    private let condition = NSCondition()
    private let hiddenURLs: Set<URL>
    private let blockFirstVisibilityRead: Bool
    private let sidecarCopyFails: Bool
    private let cancelDuringSidecarCopy: Bool
    private var didReleaseFirstVisibilityRead = false
    private var activeOperations = 0
    private var _maximumConcurrentOperations = 0
    private var _visibilityReadInvocationCount = 0
    private var _ranOnMainThread = false
    private var _sidecarCopies: [Copy] = []
    private var _removedURLs: [URL] = []
    private var _visibilityReadURLs: [URL] = []
    private var _visibleURLs: [URL] = []

    init(
        hiddenURLs: Set<URL> = [],
        blockFirstVisibilityRead: Bool = false,
        sidecarCopyFails: Bool = false,
        cancelDuringSidecarCopy: Bool = false
    ) {
        self.hiddenURLs = hiddenURLs
        self.blockFirstVisibilityRead = blockFirstVisibilityRead
        self.sidecarCopyFails = sidecarCopyFails
        self.cancelDuringSidecarCopy = cancelDuringSidecarCopy
    }

    var io: ExportArtifactFinalizationIO {
        ExportArtifactFinalizationIO(
            copyRAWArchiveSidecar: { [self] sourceURL, renderedURL in
                beginOperation()
                condition.withLock {
                    _sidecarCopies.append(Copy(
                        sourceURL: sourceURL,
                        renderedURL: renderedURL
                    ))
                }
                if cancelDuringSidecarCopy {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                endOperation()
                if sidecarCopyFails {
                    throw CocoaError(.fileReadCorruptFile)
                }
            },
            removeRenderedArtifact: { [self] url in
                beginOperation()
                condition.withLock { _removedURLs.append(url) }
                endOperation()
            },
            isHidden: { [self] url in
                beginOperation()
                condition.lock()
                _visibilityReadInvocationCount += 1
                _visibilityReadURLs.append(url)
                let invocation = _visibilityReadInvocationCount
                condition.broadcast()
                while blockFirstVisibilityRead,
                      invocation == 1,
                      !didReleaseFirstVisibilityRead {
                    if !condition.waitBounded() { break }
                }
                condition.unlock()
                endOperation()
                return hiddenURLs.contains(url)
            },
            makeVisible: { [self] url in
                beginOperation()
                condition.withLock { _visibleURLs.append(url) }
                endOperation()
            }
        )
    }

    var sidecarCopies: [Copy] { condition.withLock { _sidecarCopies } }
    var removedURLs: [URL] { condition.withLock { _removedURLs } }
    var visibilityReadURLs: [URL] { condition.withLock { _visibilityReadURLs } }
    var visibleURLs: [URL] { condition.withLock { _visibleURLs } }
    var visibilityReadInvocationCount: Int {
        condition.withLock { _visibilityReadInvocationCount }
    }
    var maximumConcurrentOperations: Int {
        condition.withLock { _maximumConcurrentOperations }
    }
    var ranOnMainThread: Bool { condition.withLock { _ranOnMainThread } }

    func releaseFirstVisibilityRead() {
        condition.withLock {
            didReleaseFirstVisibilityRead = true
            condition.broadcast()
        }
    }

    func waitUntilFirstVisibilityReadStarts() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                while _visibilityReadInvocationCount == 0 {
                    if !condition.waitBounded() { break }
                }
                condition.unlock()
                continuation.resume()
            }
        }
    }

    private func beginOperation() {
        condition.withLock {
            activeOperations += 1
            _maximumConcurrentOperations = max(_maximumConcurrentOperations, activeOperations)
            _ranOnMainThread = _ranOnMainThread || Thread.isMainThread
        }
    }

    private func endOperation() {
        condition.withLock { activeOperations -= 1 }
    }
}

@Suite("SidecarReconciliation descriptive diff")
struct SidecarReconciliationTests {
    @Test("Field provenance follows inheritance, clears and equal-valued replacements", arguments: [false, true])
    func effectiveFieldCarriers(conflict: Bool) throws {
        var embedded = IPTCMetadata(title: "Same", localizedTitles: [.init(languageTag: "nb", value: "Title")],
            description: "Clear me", latitude: 59, longitude: 10,
            creators: ["Embedded"], captureDate: "2026-01-01", rating: 4, label: "Red")
        embedded.keywords = ["old"]
        let xmp = IPTCMetadata(title: "Same", latitude: 60,
            creators: ["Sidecar"], captureDate: "", rating: 0, label: "")
        let result = try EffectiveMetadataResolver.resolve(embedded: embedded,
            facts: resolutionFacts(xmp: xmp, conflict: conflict), isRaw: false)
        #expect(Set(result.fieldCarriers.keys) == IPTCMetadata.persistedJSONFieldNames)
        for key in ["title", "description", "keywords", "creators", "creator", "latitude", "rating", "label"] {
            #expect(result.fieldCarriers[key] == (conflict ? .embedded : .xmp))
        }
        for key in ["localizedTitles", "captureDate", "longitude"] {
            #expect(result.fieldCarriers[key] == .embedded)
        }
        #expect(result.metadata.creator == (conflict ? "Embedded" : "Sidecar"))
        #expect(result.metadata.description == (conflict ? "Clear me" : nil))
    }

    @Test("Non-descriptive XMP can supply GPS and label while localized clear selects a record")
    func effectiveSparseFieldCarriers() throws {
        let embedded = IPTCMetadata(title: "Embedded", localizedTitles: [.init(languageTag: "nb", value: "Title")])
        var xmp = IPTCMetadata(latitude: 0, label: "")
        let sparse = try EffectiveMetadataResolver.resolve(embedded: embedded,
            facts: resolutionFacts(xmp: xmp), isRaw: true)
        #expect(sparse.fieldCarriers["title"] == .embedded)
        #expect(sparse.fieldCarriers["latitude"] == .xmp)
        #expect(sparse.fieldCarriers["label"] == .xmp)
        xmp.localizedTitles = []
        let cleared = try EffectiveMetadataResolver.resolve(embedded: embedded,
            facts: resolutionFacts(xmp: xmp), isRaw: true)
        #expect(cleared.metadata.localizedTitles == [])
        #expect(cleared.fieldCarriers["localizedTitles"] == .xmp)
        #expect(cleared.fieldCarriers["title"] == .xmp)
    }

    @Test("Effective reads preserve XMP clears and identify the descriptive carrier")
    func effectiveReadClears() throws {
        let embedded = IPTCMetadata(title: "Old", description: "Embedded", keywords: ["old"])
        let xmp = IPTCMetadata(description: "Sidecar")
        let result = try EffectiveMetadataResolver.resolve(embedded: embedded,
            facts: resolutionFacts(xmp: xmp), isRaw: false)
        #expect(result.metadata.title == nil)
        #expect(result.metadata.description == "Sidecar")
        #expect(result.metadata.keywords.isEmpty)
        #expect(result.descriptiveCarrier == .xmp)
        #expect(!result.hasPendingChanges)
        #expect(!result.hasXMPConflict)
    }

    @Test("A stale descriptive XMP still supplies current Develop settings", arguments: [false, true])
    func effectiveConflictRetainsDevelop(isRaw: Bool) throws {
        var embedded = IPTCMetadata(title: "New embedded")
        embedded.cameraRaw = CameraRawSettings()
        embedded.cameraRaw?.exposure2012 = 1
        var xmp = IPTCMetadata(title: "Stale caption")
        xmp.cameraRaw = CameraRawSettings()
        xmp.cameraRaw?.exposure2012 = 2
        let result = try EffectiveMetadataResolver.resolve(embedded: embedded,
            facts: resolutionFacts(xmp: xmp, conflict: true), isRaw: isRaw)
        #expect(result.metadata.title == "New embedded")
        #expect(result.metadata.cameraRaw?.exposure2012 == 2)
        #expect(result.descriptiveCarrier == .embedded)
        #expect(result.hasXMPConflict)
    }

    @Test("RAW resolution does not resurrect an omitted embedded Develop value")
    func effectiveRAWReplacesDevelop() throws {
        var embedded = IPTCMetadata(title: "Embedded")
        embedded.cameraRaw = CameraRawSettings()
        embedded.cameraRaw?.temperature = 5500
        var xmp = IPTCMetadata(title: "Sidecar")
        xmp.cameraRaw = CameraRawSettings()
        xmp.cameraRaw?.exposure2012 = 2
        let result = try EffectiveMetadataResolver.resolve(embedded: embedded,
            facts: resolutionFacts(xmp: xmp), isRaw: true)
        #expect(result.metadata.cameraRaw?.temperature == nil)
        #expect(result.metadata.cameraRaw?.exposure2012 == 2)
    }

    @Test("Develop-only XMP is not reported as the descriptive source")
    func effectiveDevelopOnly() throws {
        var xmp = IPTCMetadata()
        xmp.cameraRaw = CameraRawSettings()
        xmp.cameraRaw?.exposure2012 = 2
        let result = try EffectiveMetadataResolver.resolve(embedded: IPTCMetadata(title: "Embedded"),
            facts: resolutionFacts(xmp: xmp), isRaw: true)
        #expect(result.metadata.title == "Embedded")
        #expect(result.metadata.cameraRaw?.exposure2012 == 2)
        #expect(result.descriptiveCarrier == .embedded)
    }

    @Test("Pending drafts win without replacing physical orientation or Develop", arguments: [false, true])
    func effectivePendingDraft(pending: Bool) throws {
        var embedded = IPTCMetadata(title: "Physical")
        embedded.exifOrientation = 6
        embedded.cameraRaw = CameraRawSettings()
        embedded.cameraRaw?.exposure2012 = 2
        var draft = IPTCMetadata(title: "Draft")
        draft.exifOrientation = 3
        draft.cameraRaw = CameraRawSettings()
        draft.cameraRaw?.exposure2012 = 4
        let record = MetadataSidecar(sourceFile: "frame.arw", pendingChanges: pending, metadata: draft)
        let result = try EffectiveMetadataResolver.resolve(embedded: embedded,
            facts: resolutionFacts(app: record), isRaw: true)
        #expect(result.metadata.title == (pending ? "Draft" : "Physical"))
        #expect(result.metadata.exifOrientation == 6)
        #expect(result.metadata.cameraRaw?.exposure2012 == 2)
        #expect(result.descriptiveCarrier == (pending ? .pendingAppSidecar : .embedded))
        #expect(result.hasPendingChanges == pending)
        #expect(result.fieldCarriers.values.allSatisfy { $0 == (pending ? .pendingAppSidecar : .embedded) })
    }

    @Test("Incomplete XMP is refused even when a pending draft exists", arguments: [false, true])
    func effectiveIncompleteXMP(pending: Bool) {
        let facts = MetadataEditorSourceFacts(imageURL: URL(fileURLWithPath: "/fixture/frame.arw"),
            xmpMetadata: nil,
            appSidecar: MetadataSidecar(sourceFile: "frame.arw", pendingChanges: pending),
            reconciliationVerdict: nil, xmpReadFailure: "injected read failure")
        #expect(throws: EffectiveMetadataResolver.ReadError.self) {
            try EffectiveMetadataResolver.resolve(embedded: IPTCMetadata(title: "Embedded"),
                facts: facts, isRaw: true)
        }
    }

    private func resolutionFacts(xmp: IPTCMetadata? = nil, app: MetadataSidecar? = nil,
                                 conflict: Bool = false) -> MetadataEditorSourceFacts {
        MetadataEditorSourceFacts(imageURL: URL(fileURLWithPath: "/fixture/frame.arw"),
            xmpMetadata: xmp, appSidecar: app,
            reconciliationVerdict: conflict ? .fileNewerConflict : .sidecarMaster)
    }

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
        #expect(RAWArchiveFormat.jpegXLLinear.fileExtension == "jxl")
        #expect(RAWArchiveFormat.jpegXLCamera.fileExtension == "jxl")
        #expect(RAWArchiveFormat.tiffLinear.fileExtension == "tiff")
        #expect(RAWArchiveFormat.tiffCamera.fileExtension == "tiff")
        #expect(RAWArchiveFormat.dngLossless.fileExtension == "dng")
        #expect(RAWArchiveFormat.dngLossy.fileExtension == "dng")
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

    @Test("RAW archive scope acquisition balances only successful unique claims")
    func archiveScopeBalancesSuccessfulUniqueClaims() async {
        let ingest = URL(fileURLWithPath: "/Volumes/Ingest", isDirectory: true)
        let archive = URL(fileURLWithPath: "/Volumes/Archive", isDirectory: true)
        let probe = RAWArchiveSecurityScopeProbe(unavailableURL: archive)
        let service = RAWArchiveSecurityScopeService(
            access: probe.access,
            cancellationRequested: { false }
        )
        let request = RAWArchiveSecurityScopeRequest(
            ingestRoot: ingest,
            archiveRoot: archive
        )

        let acquisition = await service.acquire(request)
        let claim: RAWArchiveSecurityScopeClaim
        if case .acquired(let acquiredClaim) = acquisition {
            claim = acquiredClaim
        } else {
            Issue.record("Expected a complete security-scope acquisition")
            return
        }

        #expect(claim.roots == [ingest, archive])
        #expect(claim.startedRoots == [ingest])
        let release = await service.release(claim)
        #expect(release.releasedRoots == [ingest])
        #expect(probe.startedURLs == [ingest, archive])
        #expect(probe.stoppedURLs == [ingest])

        let duplicateRequest = RAWArchiveSecurityScopeRequest(
            ingestRoot: ingest,
            archiveRoot: ingest
        )
        #expect(duplicateRequest.roots == [ingest])
    }

    @Test("cancellation during RAW archive scope acquisition releases its successful prefix")
    func archiveScopeCancellationBalancesSuccessfulPrefix() async {
        let ingest = URL(fileURLWithPath: "/Volumes/Ingest", isDirectory: true)
        let archive = URL(fileURLWithPath: "/Volumes/Archive", isDirectory: true)
        let preCancelledProbe = RAWArchiveSecurityScopeProbe()
        let preCancelledService = RAWArchiveSecurityScopeService(
            access: preCancelledProbe.access,
            cancellationRequested: { true }
        )
        let preCancelledRequest = RAWArchiveSecurityScopeRequest(
            ingestRoot: ingest,
            archiveRoot: archive
        )

        let preCancelledResult = await preCancelledService.acquire(preCancelledRequest)

        #expect(preCancelledResult == .cancelledBeforeAccess(
            requestID: preCancelledRequest.requestID
        ))
        #expect(preCancelledProbe.startedURLs.isEmpty)
        #expect(preCancelledProbe.stoppedURLs.isEmpty)

        let probe = RAWArchiveSecurityScopeProbe(cancelAfterFirstStart: true)
        let service = RAWArchiveSecurityScopeService(
            access: probe.access,
            cancellationRequested: { probe.isCancellationRequested }
        )
        let request = RAWArchiveSecurityScopeRequest(
            ingestRoot: ingest,
            archiveRoot: archive
        )

        let result = await service.acquire(request)

        #expect(result == .cancelledAfterAccess(
            requestID: request.requestID,
            inspectedRootCount: 1,
            releasedStartedRoots: [ingest]
        ))
        #expect(probe.startedURLs == [ingest])
        #expect(probe.stoppedURLs == [ingest])
    }

    @MainActor
    @Test("RAW archive scope APIs leave MainActor")
    func archiveScopeAccessLeavesMainActor() async {
        let ingest = URL(fileURLWithPath: "/Volumes/Ingest", isDirectory: true)
        let probe = RAWArchiveSecurityScopeProbe()
        let service = RAWArchiveSecurityScopeService(
            access: probe.access,
            cancellationRequested: { false }
        )

        let result = await service.acquire(RAWArchiveSecurityScopeRequest(
            ingestRoot: ingest,
            archiveRoot: nil
        ))
        guard case .acquired(let claim) = result else {
            Issue.record("Expected a complete security-scope acquisition")
            return
        }
        _ = await service.release(claim)

        #expect(!probe.ranOnMainThread)
    }

    @Test("ContentView delegates RAW archive scope ownership to the service")
    func archiveScopeSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent("Aagedal Photo Agent/ContentView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("await RAWArchiveSecurityScopeService.shared.acquire("))
        #expect(source.contains("await RAWArchiveSecurityScopeService.shared.release("))
        #expect(!source.contains("configuredIngestRoot?.startAccessingSecurityScopedResource()"))
        #expect(!source.contains("configuredArchiveRoot?.startAccessingSecurityScopedResource()"))
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

    @Test("ContentView routes RAW rendering and signing through the archive transaction")
    func archiveTransactionSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent("Aagedal Photo Agent/ContentView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("RAWArchiveTransactionService.shared.archive("))
        #expect(source.contains("fileExtension: format.fileExtension"))
        #expect(source.contains("sign: signer"))
        #expect(!source.contains("try? FileManager.default.removeItem(at: convertedURL)"))
    }
}

nonisolated private final class RAWArchiveSecurityScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let unavailableURL: URL?
    private let cancelAfterFirstStart: Bool
    private var _startedURLs: [URL] = []
    private var _stoppedURLs: [URL] = []
    private var _ranOnMainThread = false
    private var _isCancellationRequested = false

    init(
        unavailableURL: URL? = nil,
        cancelAfterFirstStart: Bool = false
    ) {
        self.unavailableURL = unavailableURL
        self.cancelAfterFirstStart = cancelAfterFirstStart
    }

    var access: RAWArchiveSecurityScopeAccess {
        RAWArchiveSecurityScopeAccess(
            start: { [self] url in
                lock.withLock {
                    _startedURLs.append(url)
                    _ranOnMainThread = _ranOnMainThread || Thread.isMainThread
                    if cancelAfterFirstStart, _startedURLs.count == 1 {
                        _isCancellationRequested = true
                    }
                    return url != unavailableURL
                }
            },
            stop: { [self] url in
                lock.withLock {
                    _stoppedURLs.append(url)
                    _ranOnMainThread = _ranOnMainThread || Thread.isMainThread
                }
            }
        )
    }

    var startedURLs: [URL] {
        lock.withLock { _startedURLs }
    }

    var stoppedURLs: [URL] {
        lock.withLock { _stoppedURLs }
    }

    var ranOnMainThread: Bool {
        lock.withLock { _ranOnMainThread }
    }

    var isCancellationRequested: Bool {
        lock.withLock { _isCancellationRequested }
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
                    if !condition.waitBounded() { break }
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
                    if !condition.waitBounded() { break }
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

    @Test("AVIF declares already-rendered input primaries and transfer before decoding")
    func inputColorDeclaration() throws {
        let cases: [(TargetColorGamut, Bool, String, String)] = [
            (.sRGB, false, "bt709", "iec61966-2-1"),
            (.displayP3, false, "smpte432", "iec61966-2-1"),
            (.rec2020, false, "bt2020", "bt2020-10"),
            (.adobeRGB, false, "smpte432", "gamma22"),
            (.sRGB, true, "smpte432", "arib-std-b67"),
            (.rec2020, true, "bt2020", "arib-std-b67")
        ]
        for (gamut, isHDR, primaries, transfer) in cases {
            let arguments = FFmpegService.avifArguments(
                input: "/tmp/rendered.tiff", output: "/tmp/output.avif",
                quality: 0.8, isHDR: isHDR, gamut: gamut
            )
            let inputIndex = try #require(arguments.firstIndex(of: "-i"))
            let beforeInput = Array(arguments[..<inputIndex])
            let afterInput = Array(arguments[(inputIndex + 2)...])
            for part in [beforeInput, afterInput] {
                let primariesIndex = try #require(part.firstIndex(of: "-color_primaries"))
                let transferIndex = try #require(part.firstIndex(of: "-color_trc"))
                #expect(part[primariesIndex + 1] == primaries)
                #expect(part[transferIndex + 1] == transfer)
            }
            // Input pixels are RGB; only the encoded output is YCbCr.
            #expect(!beforeInput.contains("-colorspace"))
        }
    }

    @Test("ICC-tagged TIFFs retain explicit AVIF primaries, transfer, matrix and full range")
    func bundledEncoderSignalsTIFFColor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-avif-tiff-signaling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(String, TargetColorGamut, CFString, [UInt8])] = [
            ("srgb", .sRGB, CGColorSpace.sRGB, [0, 1, 0, 13, 0, 1, 128]),
            ("p3", .displayP3, CGColorSpace.displayP3, [0, 12, 0, 13, 0, 1, 128]),
            ("rec2020", .rec2020, CGColorSpace.itur_2020, [0, 9, 0, 14, 0, 9, 128])
        ]
        for (name, gamut, spaceName, expectedNCLX) in cases {
            let space = try #require(CGColorSpace(name: spaceName))
            // ImageIO writes a real ICC-tagged TIFF, as the SDR production renderer does.
            // A bitmap context keeps this regression independent of Core Image GPU access.
            let context = try #require(CGContext(
                data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let fill = try #require(CGColor(colorSpace: space, components: [0.2, 0.6, 0.8, 1]))
            context.setFillColor(fill)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            let image = try #require(context.makeImage())
            let input = directory.appendingPathComponent("\(name).tiff")
            let output = directory.appendingPathComponent("\(name).avif")
            let destination = try #require(CGImageDestinationCreateWithURL(
                input as CFURL, "public.tiff" as CFString, 1, nil
            ))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            try await FFmpegService.encodeAVIF(
                input: input.path, output: output.path, quality: 0.8, isHDR: false, gamut: gamut
            )
            let encoded = try Data(contentsOf: output)
            let marker = try #require(encoded.range(of: Data("colrnclx".utf8)))
            let start = marker.upperBound
            #expect(encoded.count >= start + expectedNCLX.count)
            #expect(Array(encoded[start..<min(encoded.count, start + expectedNCLX.count)]) == expectedNCLX)
            let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
        }
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

/// Export rendering must reproduce what the grid, full screen and Develop show: the sidecar
/// orientation (which wins over the file's tag), the SDR rendition of adaptive-HDR sources
/// for SDR outputs, and the same pixels whether or not a resolution limit lets the source
/// decode at reduced size.
@Suite("Export render fidelity")
struct ExportRenderFidelityTests {
    private typealias RGB = (r: Int, g: Int, b: Int)
    private static let red: RGB = (255, 0, 0)
    private static let green: RGB = (0, 255, 0)
    private static let blue: RGB = (0, 0, 255)
    private static let white: RGB = (255, 255, 255)

    private func pngConfiguration(_ limit: ExportResolutionLimit = .original) -> AdvancedExportConfiguration {
        AdvancedExportConfiguration(
            sdrFormat: .png,
            sdrQuality: 0.92,
            sdrGamut: .sRGB,
            hdrFormat: .jpegGainMap,
            hdrQuality: 0.92,
            hdrGamut: .displayP3,
            tiffCompression: .lzw,
            resolutionLimit: limit,
            locationMode: .formatSubfolder,
            customSubfolderName: "Exports"
        )
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("output", isDirectory: true),
            withIntermediateDirectories: true
        )
        return directory
    }

    /// 64x32 stored pixels: top-left red, top-right green, bottom-left blue, bottom-right white.
    private func writeQuadrantJPEG(to url: URL, orientation: Int) throws {
        let width = 64, height = 32
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // CGContext is y-up: the top half of the stored image is y >= height / 2.
        let quadrants: [(CGRect, RGB)] = [
            (CGRect(x: 0, y: 16, width: 32, height: 16), Self.red),
            (CGRect(x: 32, y: 16, width: 32, height: 16), Self.green),
            (CGRect(x: 0, y: 0, width: 32, height: 16), Self.blue),
            (CGRect(x: 32, y: 0, width: 32, height: 16), Self.white),
        ]
        for (rect, color) in quadrants {
            context.setFillColor(CGColor(
                srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255, alpha: 1
            ))
            context.fill(rect)
        }
        let image = try #require(context.makeImage())
        try writeJPEG(image, to: url, orientation: orientation)
    }

    private func writeJPEG(_ image: CGImage, to url: URL, orientation: Int) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func writeSidecarOrientation(_ orientation: Int, for source: URL) throws {
        var xmp = IPTCMetadata()
        xmp.exifOrientation = orientation
        try XMPSidecarService().saveSidecar(metadata: xmp, for: source)
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func rgb(_ x: Int, _ y: Int) -> RGB {
            let index = (y * width + x) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
        }
    }

    /// Stored pixels (no orientation applied), top row first, as 8-bit sRGB.
    private func pixels(of image: CGImage) throws -> Pixels {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    private func pixels(at url: URL) throws -> Pixels {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try pixels(of: try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    private func expectColor(_ pixels: Pixels, _ x: Int, _ y: Int, _ expected: RGB,
                             _ comment: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = pixels.rgb(x, y)
        let close = abs(actual.r - expected.r) < 70
            && abs(actual.g - expected.g) < 70
            && abs(actual.b - expected.b) < 70
        #expect(close, "\(comment): pixel (\(x), \(y)) is \(actual), expected \(expected)",
                sourceLocation: sourceLocation)
    }

    private func meanAbsoluteDifference(_ lhs: Pixels, _ rhs: Pixels, border: Int = 0) -> (mean: Double, max: Int) {
        let width = min(lhs.width, rhs.width), height = min(lhs.height, rhs.height)
        var total = 0, count = 0, maximum = 0
        for y in border..<(height - border) {
            for x in border..<(width - border) {
                let a = lhs.rgb(x, y), b = rhs.rgb(x, y)
                for delta in [abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)] {
                    total += delta
                    maximum = max(maximum, delta)
                }
                count += 3
            }
        }
        return (Double(total) / Double(max(count, 1)), maximum)
    }

    private func editedSettings() -> CameraRawSettings {
        var settings = CameraRawSettings()
        settings.contrast2012 = 5
        return settings
    }

    // MARK: Orientation

    @Test("A sidecar-only rotation is baked into exported pixels", arguments: [6, 8], [false, true])
    func sidecarRotationIsBakedIn(orientation: Int, edited: Bool) async throws {
        let directory = try makeDirectory("sidecar-rotation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("photo.jpg")
        try writeQuadrantJPEG(to: source, orientation: 1)
        try writeSidecarOrientation(orientation, for: source)
        #expect(FullScreenImageCache.displayOrientation(for: source, fallback: 1) == orientation)

        let rendered = try await EditedImageRenderer.render(
            from: source, cameraRaw: edited ? editedSettings() : nil, isHDR: false,
            outputFolder: directory.appendingPathComponent("output"),
            configuration: pngConfiguration()
        )
        let output = try pixels(at: rendered)
        #expect(output.width == 32)
        #expect(output.height == 64)
        // 90° CW (6): stored bottom-left lands top-left. 90° CCW (8): stored top-right does.
        let expected: [RGB] = orientation == 6
            ? [Self.blue, Self.red, Self.white, Self.green]
            : [Self.green, Self.white, Self.red, Self.blue]
        expectColor(output, 8, 16, expected[0], "top-left")
        expectColor(output, 24, 16, expected[1], "top-right")
        expectColor(output, 8, 48, expected[2], "bottom-left")
        expectColor(output, 24, 48, expected[3], "bottom-right")
    }

    @Test("A sidecar rotation with a crop renders the region framed in Develop")
    func sidecarRotationWithCrop() async throws {
        let directory = try makeDirectory("sidecar-rotation-crop")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("photo.jpg")
        try writeQuadrantJPEG(to: source, orientation: 1)
        try writeSidecarOrientation(6, for: source)

        // Crops are stored in the sensor (stored-pixel) frame: keep the left half, which
        // holds the red (top) and blue (bottom) quadrants.
        var settings = editedSettings()
        settings.crop = CameraRawCrop(top: 0, left: 0, bottom: 1, right: 0.5, angle: 0, hasCrop: true)
        let rendered = try await EditedImageRenderer.render(
            from: source, cameraRaw: settings, isHDR: false,
            outputFolder: directory.appendingPathComponent("output"),
            configuration: pngConfiguration()
        )
        let output = try pixels(at: rendered)
        #expect(output.width == 32)
        #expect(output.height == 32)
        // Rotated 90° CW for display: blue on the left, red on the right, nothing else.
        expectColor(output, 6, 6, Self.blue, "top-left")
        expectColor(output, 6, 26, Self.blue, "bottom-left")
        expectColor(output, 26, 6, Self.red, "top-right")
        expectColor(output, 26, 26, Self.red, "bottom-right")

        // The narrower crop keeps only the sensor's top-left (red) quadrant: 32x16 stored,
        // 16x32 displayed.
        settings.crop = CameraRawCrop(top: 0, left: 0, bottom: 0.5, right: 0.5, angle: 0, hasCrop: true)
        let quadrant = try await EditedImageRenderer.render(
            from: source, cameraRaw: settings, isHDR: false,
            outputFolder: directory.appendingPathComponent("output"),
            configuration: pngConfiguration(), collisionPolicy: .appendNumber
        )
        let quadrantPixels = try pixels(at: quadrant)
        #expect(quadrantPixels.width == 16)
        #expect(quadrantPixels.height == 32)
        expectColor(quadrantPixels, 8, 4, Self.red, "top")
        expectColor(quadrantPixels, 8, 28, Self.red, "bottom")
    }

    /// The browse-mode scope source must read the same frame and region full screen shows.
    /// Its loaders bake the FILE orientation; it used to pass the sidecar orientation as the
    /// pixels' frame without rotating, so a sidecar-rotated crop selected the wrong region
    /// and the waveform's x axis followed the file instead of the display.
    @Test("The browse scope source matches full screen for a sidecar-rotated photo",
          arguments: [false, true], [false, true])
    func browseScopeSourceMatchesFullScreen(isNativeHDR: Bool, cropped: Bool) async throws {
        let directory = try makeDirectory("scope-sidecar-rotation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("photo.jpg")
        try writeQuadrantJPEG(to: source, orientation: 1)
        try writeSidecarOrientation(6, for: source)
        let displayOrientation = FullScreenImageCache.displayOrientation(for: source, fallback: 1)
        #expect(displayOrientation == 6)

        // Sensor-frame crop keeping the left half (red over blue) — see sidecarRotationWithCrop.
        var settings: CameraRawSettings?
        if cropped {
            var edited = editedSettings()
            edited.crop = CameraRawCrop(top: 0, left: 0, bottom: 1, right: 0.5, angle: 0, hasCrop: true)
            settings = edited
        }

        let scope = try pixels(of: try #require(FullScreenImageCache.browseScopeSource(
            for: source, isNativeHDR: isNativeHDR, settings: settings,
            displayOrientation: displayOrientation
        )))
        let fullScreen = try pixels(of: try #require(await FullScreenImageCache.decodedEditedPreview(
            for: source, settings: settings, orientation: displayOrientation, screenMaxPx: 720
        )))

        for (name, image) in [("scope", scope), ("full screen", fullScreen)] {
            if cropped {
                #expect(image.width == 32 && image.height == 32,
                        "\(name): expected the 32x32 displayed crop, got \(image.width)x\(image.height)")
                guard image.width == 32, image.height == 32 else { continue }
                // Rotated 90° CW for display: blue on the left, red on the right.
                expectColor(image, 6, 6, Self.blue, "\(name) top-left")
                expectColor(image, 6, 26, Self.blue, "\(name) bottom-left")
                expectColor(image, 26, 6, Self.red, "\(name) top-right")
                expectColor(image, 26, 26, Self.red, "\(name) bottom-right")
            } else {
                #expect(image.width == 32 && image.height == 64,
                        "\(name): expected the 32x64 display frame, got \(image.width)x\(image.height)")
                guard image.width == 32, image.height == 64 else { continue }
                expectColor(image, 8, 16, Self.blue, "\(name) top-left")
                expectColor(image, 24, 16, Self.red, "\(name) top-right")
                expectColor(image, 8, 48, Self.white, "\(name) bottom-left")
                expectColor(image, 24, 48, Self.green, "\(name) bottom-right")
            }
        }
        #expect(scope.width == fullScreen.width && scope.height == fullScreen.height)
    }

    @Test("Embedded and sidecar rotations both reach Save As JPEG upright with orientation 1")
    func embeddedOrientationAndSaveAsJPEG() async throws {
        let directory = try makeDirectory("embedded-rotation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let embedded = directory.appendingPathComponent("embedded.jpg")
        try writeQuadrantJPEG(to: embedded, orientation: 6)
        let sidecarOnly = directory.appendingPathComponent("sidecar.jpg")
        try writeQuadrantJPEG(to: sidecarOnly, orientation: 1)
        try writeSidecarOrientation(6, for: sidecarOnly)

        for source in [embedded, sidecarOnly] {
            let rendered = try await EditExportPipeline.renderItem(
                sourceURL: source, cameraRaw: editedSettings(), kind: .saveAs(.jpeg),
                outputFolder: directory.appendingPathComponent("output"), folderURL: directory,
                writeEngine: SwiftExifWriteEngine(), failureTracker: MetadataFailureTracker()
            )
            let output = try pixels(at: rendered)
            #expect(output.width == 32, "\(source.lastPathComponent)")
            #expect(output.height == 64, "\(source.lastPathComponent)")
            expectColor(output, 8, 16, Self.blue, "\(source.lastPathComponent) top-left")
            expectColor(output, 24, 16, Self.red, "\(source.lastPathComponent) top-right")
            let imageSource = try #require(CGImageSourceCreateWithURL(rendered as CFURL, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            #expect((properties?[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
                    "\(source.lastPathComponent) must not be rotated twice by a viewer")
        }
    }

    @Test("A photo rotated by the app's own rotate exports with EXIF and XMP orientation both 1")
    func appRotatedPhotoExportsConsistentOrientation() async throws {
        let directory = try makeDirectory("app-rotated")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("photo.jpg")
        try writeQuadrantJPEG(to: source, orientation: 1)
        _ = try await SwiftExifWriteEngine().writeFieldMutation(
            .orientation(expected: 1, new: 6), to: source, validatePreparedIntent: {}
        )
        let rotated = try SwiftMediaMetadata.readMetadata(from: source)
        #expect(rotated.exif?.orientation == 6)
        #expect(rotated.xmp?.tiffOrientation == "6")

        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source, cameraRaw: editedSettings(), kind: .saveAs(.jpeg),
            outputFolder: directory.appendingPathComponent("output"), folderURL: directory,
            writeEngine: SwiftExifWriteEngine(), failureTracker: MetadataFailureTracker()
        )
        let output = try pixels(at: rendered)
        #expect(output.width == 32)
        #expect(output.height == 64)
        let physical = try SwiftMediaMetadata.readMetadata(from: rendered)
        #expect((physical.exif?.orientation ?? 1) == 1)
        #expect((physical.xmp?.tiffOrientation ?? "1") == "1")
        #expect((physical.xmp?.simpleValue(namespace: XMPNamespace.exif, property: "Orientation") ?? "1") == "1")
    }

    /// Classifies a pixel by its dominant channel; archive pixels are PQ-encoded, so
    /// absolute levels after conversion to 8-bit sRGB are not meaningful.
    private func dominant(_ pixels: Pixels, _ x: Int, _ y: Int) -> String {
        let p = pixels.rgb(x, y)
        if p.r > p.g + 40, p.r > p.b + 40 { return "red" }
        if p.g > p.r + 40, p.g > p.b + 40 { return "green" }
        if p.b > p.r + 40, p.b > p.g + 40 { return "blue" }
        return min(p.r, p.g, p.b) > 60 ? "white" : "other"
    }

    @Test("RAW archives stay consistent with their copied sidecar's orientation")
    func rawArchiveOrientationMatchesCopiedSidecar() async throws {
        let directory = try makeDirectory("raw-archive-orientation")
        defer { try? FileManager.default.removeItem(at: directory) }
        // CIRAWFilter rejects these bytes, so the archive takes the renderer's generic
        // CIImage fallback, which bakes the embedded orientation exactly as CIRAWFilter does.
        func makeSource(_ name: String) throws -> URL {
            let jpeg = directory.appendingPathComponent("\(name).jpg")
            try writeQuadrantJPEG(to: jpeg, orientation: 6)
            let raw = directory.appendingPathComponent("\(name).dng")
            try FileManager.default.moveItem(at: jpeg, to: raw)
            #expect(FullScreenImageCache.fileEXIFOrientation(at: raw) == 6)
            return raw
        }
        func archive(_ source: URL) async throws -> URL {
            let folder = directory.appendingPathComponent("archive-\(source.deletingPathExtension().lastPathComponent)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = try await EditedImageRenderer.convertRAWTo16BitTIFF(
                from: source, decodeProfile: .camera, destinationFolder: folder)
            try RAWArchiveService.copySidecarIfPresent(from: source, to: output)
            return output
        }
        func displayedOrientation(_ url: URL) -> Int {
            FullScreenImageCache.displayOrientation(
                for: url, fallback: FullScreenImageCache.fileEXIFOrientation(at: url))
        }

        // Sidecar with orientation: sensor-frame pixels, copied sidecar orients them.
        let oriented = try makeSource("oriented")
        try writeSidecarOrientation(6, for: oriented)
        let orientedArchive = try await archive(oriented)
        let orientedPixels = try pixels(at: orientedArchive)
        #expect(orientedPixels.width == 64)
        #expect(orientedPixels.height == 32)
        #expect(dominant(orientedPixels, 8, 8) == "red")
        #expect(dominant(orientedPixels, 56, 24) == "white")
        #expect(displayedOrientation(orientedArchive) == displayedOrientation(oriented))

        // Sidecar without orientation: the RAW's embedded tag is carried into the copy.
        let unoriented = try makeSource("unoriented")
        try Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="3"/>\
            </rdf:RDF></x:xmpmeta>
            """.utf8).write(to: XMPSidecarService().sidecarURL(for: unoriented))
        #expect(XMPSidecarService().sidecarOrientation(for: unoriented) == nil)
        let unorientedArchive = try await archive(unoriented)
        let unorientedPixels = try pixels(at: unorientedArchive)
        #expect(unorientedPixels.width == 64)
        #expect(XMPSidecarService().sidecarOrientation(for: unorientedArchive) == 6)
        #expect(displayedOrientation(unorientedArchive) == displayedOrientation(unoriented))

        // No sidecar: nothing else carries the orientation, so it stays baked in.
        let bare = try makeSource("bare")
        let bareArchive = try await archive(bare)
        let barePixels = try pixels(at: bareArchive)
        #expect(barePixels.width == 32)
        #expect(barePixels.height == 64)
        #expect(dominant(barePixels, 8, 16) == "blue")
        #expect(dominant(barePixels, 24, 16) == "red")
        #expect(displayedOrientation(bareArchive) == 1)
    }

    // MARK: Adaptive HDR sources

    @Test("SDR exports of a gain-map JPEG use its SDR rendition instead of clipping the expansion")
    func gainMapSDRExportUsesSDRRendition() async throws {
        let directory = try makeDirectory("gainmap-sdr")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("adaptive.jpg")

        // Neutral ramp from black to 4x SDR white in extended linear sRGB.
        let width = 256, height = 32
        var floats = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = Float(x) / Float(width - 1) * 4
                let index = (y * width + x) * 4
                floats[index] = value
                floats[index + 1] = value
                floats[index + 2] = value
            }
        }
        let hdr = CIImage(
            bitmapData: floats.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: width * 16,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: CameraRawApproximation.workingColorSpace
        )
        try EditedImageRenderer.writeHDRGainMapJPEG(
            hdrImage: hdr, destURL: source, colorSpace: CameraRawApproximation.workingColorSpace,
            quality: 0.95, ctx: CameraRawApproximation.ciContext
        )

        let context = CameraRawApproximation.ciContext
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = try #require(CIImage(contentsOf: source, options: [.applyOrientationProperty: true]))
        let expanded = try #require(CIImage(contentsOf: source, options: [
            .applyOrientationProperty: true, .expandToHDR: true, .toneMapHDRtoSDR: false,
        ]))
        let basePixels = try pixels(of: try #require(
            context.createCGImage(base, from: base.extent, format: .RGBA8, colorSpace: sRGB)))
        let clippedPixels = try pixels(of: try #require(
            context.createCGImage(expanded, from: expanded.extent, format: .RGBA8, colorSpace: sRGB)))
        func clippedCount(_ pixels: Pixels) -> Int {
            (0..<pixels.width).filter { pixels.rgb($0, height / 2).g >= 254 }.count
        }
        // The fixture must reproduce the defect: expansion clips many more highlight columns.
        try #require(clippedCount(clippedPixels) > clippedCount(basePixels) + 20)

        let exported = try pixels(at: try await EditedImageRenderer.render(
            from: source, cameraRaw: nil, isHDR: false,
            outputFolder: directory.appendingPathComponent("output"),
            configuration: pngConfiguration()
        ))
        let unedited = meanAbsoluteDifference(exported, basePixels)
        #expect(unedited.mean < 2, "unedited SDR export differs from the SDR rendition: \(unedited)")
        #expect(clippedCount(exported) <= clippedCount(basePixels) + 2)

        // Save As forces SDR; HDR mode alone (Develop auto-enables it) is not a pixel edit.
        var hdrModeOnly = CameraRawSettings()
        hdrModeOnly.hdrEditMode = 1
        #expect(EditedImageRenderer.sdrOutputUsesBaseRendition(of: hdrModeOnly))
        let savedAs = try pixels(at: try await EditedImageRenderer.saveAs(
            from: source, cameraRaw: hdrModeOnly, format: .png,
            destinationFolder: directory.appendingPathComponent("output")
        ))
        let saved = meanAbsoluteDifference(savedAs, basePixels)
        #expect(saved.mean < 3, "Save As SDR differs from the SDR rendition: \(saved)")
        #expect(clippedCount(savedAs) <= clippedCount(basePixels) + 2)

        // An edited photo keeps Develop's expanded decode: -1 EV recovers gain-map
        // highlights exactly as the user tuned it, rather than darkening the SDR base.
        var edited = CameraRawSettings()
        edited.exposure2012 = -1
        #expect(!EditedImageRenderer.sdrOutputUsesBaseRendition(of: edited))
        func developRendition(of decoded: CIImage) throws -> Pixels {
            let rendered = CameraRawApproximation.applyWithCrop(
                to: decoded, settings: edited, exifOrientation: 1)
            return try pixels(of: try #require(
                context.createCGImage(rendered, from: rendered.extent, format: .RGBA8, colorSpace: sRGB)))
        }
        let developReference = try developRendition(of: expanded)
        let baseReference = try developRendition(of: base)
        try #require(meanAbsoluteDifference(developReference, baseReference).mean > 3,
                     "fixture must distinguish the expanded and base decodes once edited")
        let editedExport = try pixels(at: try await EditedImageRenderer.render(
            from: source, cameraRaw: edited, isHDR: false,
            outputFolder: directory.appendingPathComponent("output"),
            configuration: pngConfiguration(), collisionPolicy: .appendNumber
        ))
        let editedDifference = meanAbsoluteDifference(editedExport, developReference)
        #expect(editedDifference.mean < 2, "edited SDR export differs from Develop's rendition: \(editedDifference)")
    }

    // MARK: Reduced-resolution decode

    @Test("Resolution-limited exports decode near the needed size and match a full-size render",
          arguments: [false, true])
    func reducedDecodeMatchesFullResolution(croppedAndRotated: Bool) async throws {
        let directory = try makeDirectory("reduced-decode")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("large.jpg")
        let width = 3600, height = 2400
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let blue = UInt8(255 * Double(y) / Double(height))
            let wave = cos(Double(y) * 0.02)
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = UInt8(255 * Double(x) / Double(width))
                bytes[index + 1] = UInt8(127.5 + 127 * sin(Double(x) * 0.03) * wave)
                bytes[index + 2] = blue
            }
        }
        let image: CGImage = try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            return try #require(context.makeImage())
        }
        try writeJPEG(image, to: source, orientation: 1)

        var settings = CameraRawSettings()
        settings.exposure2012 = 0.3
        settings.contrast2012 = 10
        var orientation = 1
        if croppedAndRotated {
            settings.crop = CameraRawCrop(top: 0.1, left: 0.05, bottom: 0.8, right: 0.85, angle: 0, hasCrop: true)
            try writeSidecarOrientation(6, for: source)
            orientation = 6
        }
        // The fixture must take the reduced path: crop-aware, well below native size.
        let decodeSize = try #require(EditedImageRenderer.exportDecodeMaxPixelSize(
            maximumOutputPixelSize: 1600, settings: settings, orientation: orientation,
            sourcePixelSize: CGSize(width: width, height: height)
        ))
        #expect(decodeSize < 2200)
        #expect(decodeSize > 1600)

        let output = directory.appendingPathComponent("output")
        let limited = try pixels(at: try await EditedImageRenderer.render(
            from: source, cameraRaw: settings, isHDR: false, outputFolder: output,
            configuration: pngConfiguration(.pixels1600)
        ))
        let fullURL = try await EditedImageRenderer.render(
            from: source, cameraRaw: settings, isHDR: false, outputFolder: output,
            configuration: pngConfiguration(), collisionPolicy: .appendNumber
        )
        let fullImage = try #require(CIImage(contentsOf: fullURL))
        let resized = EditedImageRenderer.limitedForExport(fullImage, maximumPixelSize: 1600)
        let reference = try pixels(of: try #require(CameraRawApproximation.ciContext.createCGImage(
            resized, from: resized.extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )))

        #expect(max(limited.width, limited.height) == 1600)
        #expect(abs(limited.width - reference.width) <= 1)
        #expect(abs(limited.height - reference.height) <= 1)
        if croppedAndRotated {
            #expect(limited.width < limited.height, "the sidecar rotation must survive")
        }
        let difference = meanAbsoluteDifference(limited, reference, border: 3)
        #expect(difference.mean < 2.5, "reduced decode differs from full-size render: \(difference)")
        #expect(difference.max < 40, "reduced decode differs from full-size render: \(difference)")
    }

    @Test("Resolution-dependent effects keep the full-resolution decode")
    func resolutionDependentEffectsDisableReducedDecode() throws {
        let native = CGSize(width: 8000, height: 6000)
        func decodeSize(_ settings: CameraRawSettings?, limit: Int = 2048,
                        source: CGSize = native) -> CGFloat? {
            EditedImageRenderer.exportDecodeMaxPixelSize(
                maximumOutputPixelSize: limit, settings: settings, orientation: 1,
                sourcePixelSize: source
            )
        }

        let padded = CGFloat(2048) * 1.04 + 8
        #expect(decodeSize(nil) == padded)
        #expect(decodeSize(CameraRawSettings()) == padded)
        #expect(EditedImageRenderer.exportDecodeMaxPixelSize(
            maximumOutputPixelSize: nil, settings: nil, orientation: 1, sourcePixelSize: native
        ) == nil)
        // Not worth a second resample when the source is barely larger.
        #expect(decodeSize(nil, source: CGSize(width: 3000, height: 2000)) == nil)

        // A quarter-frame crop (half of each side) needs twice the decode size to fill the limit.
        var cropped = CameraRawSettings()
        cropped.crop = CameraRawCrop(top: 0, left: 0, bottom: 0.5, right: 0.5, angle: 0, hasCrop: true)
        let croppedSize = try #require(decodeSize(cropped))
        #expect(abs(croppedSize - padded * 2) < 1)

        var sharpened = CameraRawSettings()
        sharpened.sharpness = 40
        #expect(decodeSize(sharpened) == nil)

        for film in [
            FilmEmulationSettings(grain: 20), FilmEmulationSettings(halation: 20),
            FilmEmulationSettings(bloom: 20), FilmEmulationSettings(edgeBlur: 20),
        ] {
            var settings = CameraRawSettings()
            settings.filmEmulation = film
            #expect(decodeSize(settings) == nil, "\(film)")
        }
        var vignette = CameraRawSettings()
        vignette.filmEmulation = FilmEmulationSettings(vignette: -30)
        #expect(decodeSize(vignette) == padded)

        // Clarity's pixel radius is proportional only for 1000...8000 px short sides.
        var clarity = CameraRawSettings()
        clarity.clarity2012 = 25
        #expect(decodeSize(clarity) == padded)
        #expect(decodeSize(clarity, source: CGSize(width: 12000, height: 9000)) == nil)
        #expect(decodeSize(clarity, limit: 1600, source: CGSize(width: 8000, height: 1600)) == nil)

        var watermarked = CameraRawSettings()
        var layer = WatermarkLayer(libraryAssetID: UUID())
        layer.geometry.sizeUnit = .pixel
        watermarked.watermarkLayers = [layer]
        #expect(decodeSize(watermarked) == nil)
        layer.geometry.sizeUnit = .percent
        layer.geometry.marginUnit = .pixel
        watermarked.watermarkLayers = [layer]
        #expect(decodeSize(watermarked) == nil)
        layer.geometry.marginUnit = .percent
        watermarked.watermarkLayers = [layer]
        #expect(decodeSize(watermarked) == padded)
        layer.enabled = false
        layer.geometry.sizeUnit = .pixel
        watermarked.watermarkLayers = [layer]
        #expect(decodeSize(watermarked) == padded)
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

        // A real gain-map JPEG padded far past its header must still classify as
        // HDR while the container preflight reads only the header region.
        let padded = directory.appendingPathComponent("adaptive-hdr-padded.jpg")
        var paddedData = try Data(contentsOf: destination)
        paddedData.append(Data(count: 12_000_000))
        try paddedData.write(to: padded)
        let probe = SupportedImageFormats.gainMapContainerHintProbe(url: padded)
        #expect(probe.hasHint)
        #expect(probe.bytesRead < 300_000)
        #expect(SupportedImageFormats.isHDR(url: padded))
        #expect(
            SupportedImageFormats.gainMapContainerHintProbe(url: destination).hasHint
                == Self.legacyFullReadHint(url: destination)
        )
        #expect(
            SupportedImageFormats.gainMapContainerHintProbe(url: source).hasHint
                == Self.legacyFullReadHint(url: source)
        )
    }

    /// Writes a synthetic JPEG: SOI, a big EXIF-like APP1, optional APP2 payload,
    /// DQT, SOS, then `scanBytes` of entropy-coded filler and EOI.
    private static func syntheticJPEG(
        app2Payload: Data?,
        scanBytes: Int,
        scanInjection: Data? = nil
    ) -> Data {
        func segment(_ marker: UInt8, _ payload: Data) -> Data {
            let length = payload.count + 2
            var data = Data([0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)])
            data.append(payload)
            return data
        }
        var data = Data([0xFF, 0xD8])
        data.append(segment(0xE1, Data("Exif\0\0".utf8) + Data(repeating: 0x11, count: 60_000)))
        if let app2Payload { data.append(segment(0xE2, app2Payload)) }
        data.append(segment(0xDB, Data(repeating: 0x01, count: 65)))
        data.append(segment(0xDA, Data(repeating: 0x00, count: 10)))
        var scan = Data(repeating: 0x5A, count: scanBytes)
        if let scanInjection {
            scan.replaceSubrange(scanBytes / 2..<(scanBytes / 2 + scanInjection.count), with: scanInjection)
        }
        data.append(scan)
        data.append(contentsOf: [0xFF, 0xD9])
        return data
    }

    @Test("gain-map preflight reads only the JPEG header, never the whole file")
    func gainMapPreflightIsBoundedForJPEG() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-hdr-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scanBytes = 20_000_000
        let cases: [(name: String, data: Data, expected: Bool)] = [
            ("mpf.jpg", Self.syntheticJPEG(app2Payload: Data("MPF\0".utf8) + Data(count: 200), scanBytes: scanBytes), true),
            ("iso.jpg", Self.syntheticJPEG(app2Payload: Data("urn:iso:std:iso:ts:21496:-1".utf8), scanBytes: scanBytes), true),
            ("plain.jpg", Self.syntheticJPEG(app2Payload: nil, scanBytes: scanBytes), false),
            // A signature buried in the compressed scan is not gain-map linkage.
            ("scan-only.jpg", Self.syntheticJPEG(app2Payload: nil, scanBytes: scanBytes, scanInjection: Data("MPF\0".utf8)), false),
        ]
        for testCase in cases {
            let url = directory.appendingPathComponent(testCase.name)
            try testCase.data.write(to: url)
            let probe = SupportedImageFormats.gainMapContainerHintProbe(url: url)
            #expect(probe.hasHint == testCase.expected, "\(testCase.name)")
            #expect(probe.hasHint == Self.legacyFullReadHint(url: url), "\(testCase.name)")
            #expect(probe.bytesRead < 300_000, "\(testCase.name) read \(probe.bytesRead) bytes")
        }

        // Non-candidate formats are never opened.
        let tiff = directory.appendingPathComponent("frame.tiff")
        try Data(count: 1_000).write(to: tiff)
        #expect(SupportedImageFormats.gainMapContainerHintProbe(url: tiff).bytesRead == 0)
    }

    @Test("gain-map preflight reads at most the HEIF prefix")
    func gainMapPreflightIsBoundedForHEIF() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-hdr-preflight-heif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let limit = SupportedImageFormats.heifGainMapHintPrefixLimit
        var early = Data(count: 8_000_000)
        early.replaceSubrange(4_096..<4_100, with: Data("tmap".utf8))
        var late = Data(count: 8_000_000)
        late.replaceSubrange(3_000_000..<3_000_004, with: Data("tmap".utf8))

        for (name, data, expected) in [("early.heic", early, true), ("late.heic", late, false)] {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            let probe = SupportedImageFormats.gainMapContainerHintProbe(url: url)
            #expect(probe.hasHint == expected, "\(name)")
            #expect(probe.hasHint == Self.legacyFullReadHint(url: url), "\(name)")
            #expect(probe.bytesRead <= limit, "\(name) read \(probe.bytesRead) bytes")
        }
    }

    /// The pre-3.0 whole-file implementation, kept verbatim as an oracle so the
    /// bounded reader is proven to classify identically.
    private static func legacyFullReadHint(url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        let isJPEGContainer = ["jpg", "jpeg"].contains(fileExtension)
        guard isJPEGContainer || fileExtension == "heic" || fileExtension == "heif" else { return false }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        let gainMapSignatures = [
            Data("AMPF".utf8), Data("MPF\0".utf8), Data("urn:iso:std:iso:ts:21496".utf8),
            Data("HDRGainMap".utf8), Data("hdrgainmap".utf8), Data("tmap".utf8)
        ]
        if isJPEGContainer {
            guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { return false }
            var offset = 2
            while offset + 3 < data.count {
                while offset < data.count, data[offset] == 0xFF { offset += 1 }
                guard offset < data.count else { return false }
                let marker = data[offset]
                offset += 1
                if marker == 0xDA || marker == 0xD9 { return false }
                if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
                guard offset + 1 < data.count else { return false }
                let length = (Int(data[offset]) << 8) | Int(data[offset + 1])
                guard length >= 2, offset + length <= data.count else { return false }
                let payloadStart = offset + 2
                let payloadEnd = min(offset + length, payloadStart + 4_096)
                if marker >= 0xE0, marker <= 0xEF, payloadStart < payloadEnd {
                    let payload = Data(data[payloadStart..<payloadEnd])
                    if gainMapSignatures.contains(where: { payload.range(of: $0) != nil }) { return true }
                }
                offset += length
            }
            return false
        }
        let prefix = Data(data.prefix(min(data.count, 1_048_576)))
        return gainMapSignatures.contains(where: { prefix.range(of: $0) != nil })
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

    @Test("Save As names its format sub-folder after the Save As format, not the Export format")
    func saveAsFolderUsesSaveAsFormat() {
        // Export is configured for JPEG; "Save as PNG" must still land in Edited_PNG.
        let root = URL(fileURLWithPath: "/Volumes/Photos/Shoot", isDirectory: true)
        let source = root.appendingPathComponent("IMG_1.ARW")
        let folder = EditedImageRenderer.resolveOutputFolder(
            sourceURL: source, rootFolder: root, isHDR: false,
            formatPrefix: "Edited", askedFolder: nil,
            configuration: configuration,
            sdrFormat: EditedImageRenderer.SaveAsFormat.png.exportFormat
        )
        #expect(folder.lastPathComponent == "Edited_PNG")
        #expect(
            EditedImageRenderer.formatFolderName(
                prefix: "Edited", isHDR: false, configuration: configuration,
                sdrFormat: EditedImageRenderer.SaveAsFormat.jpeg.exportFormat
            ) == "Edited_JPEG"
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

    @MainActor
    @Test("Advanced Export preparation leaves MainActor and reads only required source facts")
    func advancedExportPreparationUsesMinimalOffMainReads() async {
        let liveURL = URL(fileURLWithPath: "/virtual/live.ARW")
        let sidecarURL = URL(fileURLWithPath: "/virtual/sidecar.CR3")
        let jpegURL = URL(fileURLWithPath: "/virtual/finished.jpg")
        let pendingURL = URL(fileURLWithPath: "/virtual/cloud.heic")
        var liveSettings = CameraRawSettings()
        liveSettings.exposure2012 = 1
        liveSettings.hdrEditMode = 1
        var sidecarSettings = CameraRawSettings()
        sidecarSettings.exposure2012 = 2
        let probe = AdvancedExportPreparationProbe(
            sidecars: [sidecarURL: sidecarSettings],
            sizes: [
                liveURL: .init(width: 6_000, height: 4_000),
                sidecarURL: .init(width: 4_000, height: 6_000),
                jpegURL: .init(width: 3_000, height: 2_000),
                pendingURL: .init(width: 2_000, height: 1_000),
            ]
        )
        let service = AdvancedExportPreparationService(access: probe.access)
        let requestID = UUID()
        let inputs = [
            AdvancedExportPreparationInput(
                sourceURL: liveURL,
                filename: liveURL.lastPathComponent,
                liveCameraRaw: liveSettings,
                sourceFileSize: 101,
                exifOrientation: 1,
                isICloudDownloadPending: false
            ),
            AdvancedExportPreparationInput(
                sourceURL: sidecarURL,
                filename: sidecarURL.lastPathComponent,
                liveCameraRaw: nil,
                sourceFileSize: 202,
                exifOrientation: 6,
                isICloudDownloadPending: false
            ),
            AdvancedExportPreparationInput(
                sourceURL: jpegURL,
                filename: jpegURL.lastPathComponent,
                liveCameraRaw: nil,
                sourceFileSize: nil,
                exifOrientation: 1,
                isICloudDownloadPending: false
            ),
            AdvancedExportPreparationInput(
                sourceURL: pendingURL,
                filename: pendingURL.lastPathComponent,
                liveCameraRaw: nil,
                sourceFileSize: 404,
                exifOrientation: 1,
                isICloudDownloadPending: true
            ),
        ]

        let result = await Task { await service.prepare(inputs, requestID: requestID) }.value

        guard case .complete(let snapshot) = result else {
            Issue.record("Expected a complete Advanced Export preparation snapshot")
            return
        }
        #expect(snapshot.requestID == requestID)
        #expect(snapshot.preparedURLs == [liveURL, sidecarURL, jpegURL, pendingURL])
        #expect(snapshot.preparedItems[0].cameraRaw == liveSettings)
        #expect(snapshot.preparedItems[0].isHDR)
        #expect(snapshot.preparedItems[0].sourcePixelWidth == 6_000)
        #expect(snapshot.preparedItems[1].cameraRaw == sidecarSettings)
        #expect(snapshot.preparedItems[1].sourcePixelWidth == 6_000)
        #expect(snapshot.preparedItems[1].sourcePixelHeight == 4_000)
        #expect(snapshot.preparedItems[2].cameraRaw == nil)
        #expect(snapshot.preparedItems[3].sourcePixelWidth == nil)
        #expect(probe.sidecarURLs == [sidecarURL])
        #expect(probe.nativeSizeURLs == [liveURL, sidecarURL, jpegURL])
        #expect(!probe.ranOnMainThread)
    }

    @Test("Advanced Export preparation cancellation returns the exact completed prefix")
    func advancedExportPreparationCancellationPrefix() async {
        let urls = [
            URL(fileURLWithPath: "/virtual/first.jpg"),
            URL(fileURLWithPath: "/virtual/second.jpg"),
            URL(fileURLWithPath: "/virtual/third.jpg"),
        ]
        let probe = AdvancedExportPreparationProbe(
            sizes: Dictionary(uniqueKeysWithValues: urls.map {
                ($0, AdvancedExportSourcePixelSize(width: 100, height: 50))
            }),
            cancelNativeSizeAtInvocation: 2
        )
        let service = AdvancedExportPreparationService(access: probe.access)
        let requestID = UUID()
        let inputs = urls.map {
            AdvancedExportPreparationInput(
                sourceURL: $0,
                filename: $0.lastPathComponent,
                liveCameraRaw: nil,
                sourceFileSize: nil,
                exifOrientation: 1,
                isICloudDownloadPending: false
            )
        }

        let result = await Task { await service.prepare(inputs, requestID: requestID) }.value

        guard case .cancelledAfterPartialRead(let snapshot) = result else {
            Issue.record("Expected cancellation with a fully prepared prefix")
            return
        }
        #expect(snapshot.preparedURLs == Array(urls.prefix(2)))
        #expect(probe.nativeSizeURLs == Array(urls.prefix(2)))
    }

    @MainActor
    @Test("Advanced Export preparation serializes overlapping ImageIO batches")
    func advancedExportPreparationSerializesBatches() async {
        let urls = [
            URL(fileURLWithPath: "/virtual/first.jpg"),
            URL(fileURLWithPath: "/virtual/second.jpg"),
        ]
        let probe = AdvancedExportPreparationProbe(
            sizes: Dictionary(uniqueKeysWithValues: urls.map {
                ($0, AdvancedExportSourcePixelSize(width: 100, height: 50))
            }),
            nativeSizeDelay: 0.01
        )
        let service = AdvancedExportPreparationService(access: probe.access)
        let inputs = urls.map {
            [AdvancedExportPreparationInput(
                sourceURL: $0,
                filename: $0.lastPathComponent,
                liveCameraRaw: nil,
                sourceFileSize: nil,
                exifOrientation: 1,
                isICloudDownloadPending: false
            )]
        }

        let results = await Task { @MainActor in
            async let first = service.prepare(inputs[0], requestID: UUID())
            async let second = service.prepare(inputs[1], requestID: UUID())
            return await (first, second)
        }.value

        guard case .complete = results.0, case .complete = results.1 else {
            Issue.record("Expected both serialized preparations to complete")
            return
        }
        #expect(Set(probe.nativeSizeURLs) == Set(urls))
        #expect(probe.maximumConcurrentNativeSizeReads == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("Advanced Export preparation distinguishes pre-read and post-complete cancellation")
    func advancedExportPreparationCancellationEdges() async {
        let url = URL(fileURLWithPath: "/virtual/final.jpg")
        let input = AdvancedExportPreparationInput(
            sourceURL: url,
            filename: url.lastPathComponent,
            liveCameraRaw: nil,
            sourceFileSize: nil,
            exifOrientation: 1,
            isICloudDownloadPending: false
        )
        let preCancelledProbe = AdvancedExportPreparationProbe()
        let preCancelledService = AdvancedExportPreparationService(access: preCancelledProbe.access)
        let preCancelledID = UUID()
        let preCancelledTask = Task {
            await Task.yield()
            return await preCancelledService.prepare([input], requestID: preCancelledID)
        }
        preCancelledTask.cancel()
        #expect(await preCancelledTask.value == .cancelledBeforeRead(
            requestID: preCancelledID,
            requestedURLs: [url]
        ))
        #expect(preCancelledProbe.nativeSizeURLs.isEmpty)

        let completedProbe = AdvancedExportPreparationProbe(
            sizes: [url: .init(width: 100, height: 50)],
            cancelNativeSizeAtInvocation: 1
        )
        let completedService = AdvancedExportPreparationService(access: completedProbe.access)
        let completedID = UUID()
        let completedResult = await Task {
            await completedService.prepare([input], requestID: completedID)
        }.value
        guard case .cancelledAfterCompleteRead(let snapshot) = completedResult else {
            Issue.record("Expected cancellation after the final complete source inspection")
            return
        }
        #expect(snapshot.preparedURLs == [url])
        #expect(snapshot.isComplete)
    }

    @Test("ContentView awaits request-tagged Advanced Export preparation")
    func advancedExportContentViewSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent("Aagedal Photo Agent/ContentView.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private func showAdvancedExportSelected()"))
        let end = try #require(source.range(
            of: "private func applyAdvancedExportConfiguration(",
            range: start.lowerBound..<source.endIndex
        ))
        let functionSource = String(source[start.lowerBound..<end.lowerBound])

        #expect(functionSource.contains("advancedExportPreparationTask?.cancel()"))
        #expect(functionSource.contains("service.prepare(inputs, requestID: requestID)"))
        #expect(functionSource.contains("advancedExportPreparationRequestID == requestID"))
        #expect(functionSource.contains("case .complete(let snapshot) = result"))
        #expect(functionSource.contains("currentOrderedURLs == snapshot.requestedURLs"))
        #expect(!functionSource.contains("XMPSidecarService"))
        #expect(!functionSource.contains("FullScreenImageCache.nativePixelSize"))
        #expect(source.contains(".onChange(of: browserViewModel.selectedImageIDs)"))
        #expect(source.contains("cancelAdvancedExportPreparation()"))
    }

    @Test("Save As and Archive RAW capture the pane and folder before their batch task")
    func saveAsAndArchiveCaptureSourcePane() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent("Aagedal Photo Agent/ContentView.swift"),
            encoding: .utf8
        )
        for (startMarker, endMarker) in [
            ("private func saveSelectedAsAfterMetadataFlush(", "private func archiveSelectedRAW(as format"),
            ("private func archiveSelectedRAWAfterMetadataFlush(", "private func makeC2PAArchiveSigningConfiguration()"),
        ] {
            let start = try #require(source.range(of: startMarker))
            let end = try #require(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
            let functionSource = source[start.lowerBound..<end.lowerBound]
            let task = try #require(functionSource.range(of: "renderExportTask = Task {"))
            let beforeTask = functionSource[..<task.lowerBound]
            let taskBody = functionSource[task.lowerBound...]
            // `browserViewModel` is `panes.active`; reading it per item follows a pane switch.
            #expect(beforeTask.contains("let browser = browserViewModel"))
            #expect(beforeTask.contains("let sourceFolderURL = browser.currentFolderURL"))
            #expect(!taskBody.contains("browserViewModel"))
        }
    }
}

private nonisolated final class AdvancedExportPreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let sidecars: [URL: CameraRawSettings]
    private let sizes: [URL: AdvancedExportSourcePixelSize]
    private let cancelNativeSizeAtInvocation: Int?
    private let nativeSizeDelay: TimeInterval
    private var storedSidecarURLs: [URL] = []
    private var storedNativeSizeURLs: [URL] = []
    private var observedMainThread = false
    private var activeNativeSizeReads = 0
    private var storedMaximumConcurrentNativeSizeReads = 0

    init(
        sidecars: [URL: CameraRawSettings] = [:],
        sizes: [URL: AdvancedExportSourcePixelSize] = [:],
        cancelNativeSizeAtInvocation: Int? = nil,
        nativeSizeDelay: TimeInterval = 0
    ) {
        self.sidecars = sidecars
        self.sizes = sizes
        self.cancelNativeSizeAtInvocation = cancelNativeSizeAtInvocation
        self.nativeSizeDelay = nativeSizeDelay
    }

    var access: AdvancedExportPreparationAccess {
        AdvancedExportPreparationAccess(
            loadCameraRawSidecar: loadCameraRawSidecar,
            nativePixelSize: nativePixelSize
        )
    }

    func loadCameraRawSidecar(_ url: URL) -> CameraRawSettings? {
        lock.withLock {
            storedSidecarURLs.append(url)
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return sidecars[url]
    }

    func nativePixelSize(_ url: URL) -> AdvancedExportSourcePixelSize? {
        let shouldCancel = lock.withLock {
            storedNativeSizeURLs.append(url)
            observedMainThread = observedMainThread || Thread.isMainThread
            activeNativeSizeReads += 1
            storedMaximumConcurrentNativeSizeReads = max(
                storedMaximumConcurrentNativeSizeReads,
                activeNativeSizeReads
            )
            return storedNativeSizeURLs.count == cancelNativeSizeAtInvocation
        }
        defer { lock.withLock { activeNativeSizeReads -= 1 } }
        if shouldCancel {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if nativeSizeDelay > 0 {
            Thread.sleep(forTimeInterval: nativeSizeDelay)
        }
        return sizes[url]
    }

    var sidecarURLs: [URL] { lock.withLock { storedSidecarURLs } }
    var nativeSizeURLs: [URL] { lock.withLock { storedNativeSizeURLs } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var maximumConcurrentNativeSizeReads: Int {
        lock.withLock { storedMaximumConcurrentNativeSizeReads }
    }
}

@Suite("Advanced Export preview cleanup filesystem boundary")
struct AdvancedExportPreviewCleanupTests {
    @MainActor
    @Test("blocked cleanup stays off MainActor and queued cancellation remains explicit")
    func blockedCleanupDoesNotBlockMainActor() async throws {
        let probe = BlockingAdvancedExportPreviewCleanupProbe()
        defer { probe.releaseFirstRemoval() }
        let service = AdvancedExportPreviewCleanupService(access: .init(
            removeItem: { try probe.removeItem(at: $0) }
        ))
        let firstURL = URL(fileURLWithPath: "/virtual/first-preview")
        let secondURL = URL(fileURLWithPath: "/virtual/second-preview")

        let first = Task {
            await service.removePreviewFolder(at: firstURL)
        }
        try await probe.waitUntilFirstRemovalStarts()

        // Reaching this assertion while the injected synchronous removal is blocked proves the
        // recursive filesystem mutation is not occupying MainActor.
        #expect(probe.removalCount == 1)
        let second = Task {
            await service.removePreviewFolder(at: secondURL)
        }
        second.cancel()
        probe.releaseFirstRemoval()

        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult == .removed(
            firstURL,
            cancellationRequestedAfterCommit: false
        ))
        #expect(secondResult == .cancelledBeforeRemoval(secondURL))
        #expect(probe.removalCount == 1)
        #expect(probe.maximumConcurrentRemovalCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("cancellation after recursive removal preserves durable cleanup evidence")
    func cancellationAfterCleanupCommit() async {
        let folderURL = URL(fileURLWithPath: "/virtual/committed-preview")
        let service = AdvancedExportPreviewCleanupService(access: .init(
            removeItem: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        ))

        let task = Task {
            await service.removePreviewFolder(at: folderURL)
        }
        let result = await task.value

        #expect(result == .removed(
            folderURL,
            cancellationRequestedAfterCommit: true
        ))
    }

    @Test("recursive removal failure remains explicit")
    func cleanupFailure() async {
        let folderURL = URL(fileURLWithPath: "/virtual/failed-preview")
        let service = AdvancedExportPreviewCleanupService(access: .init(
            removeItem: { _ in throw AdvancedExportPreviewCleanupInjectedError.refused }
        ))

        let result = await service.removePreviewFolder(at: folderURL)

        #expect(result == .failed(folderURL))
    }

    @MainActor
    @Test("releasing preview storage schedules cleanup without synchronous filesystem work")
    func storageDeinitSchedulesActorCleanup() async throws {
        let probe = BlockingAdvancedExportPreviewCleanupProbe()
        defer { probe.releaseFirstRemoval() }
        let service = AdvancedExportPreviewCleanupService(access: .init(
            removeItem: { try probe.removeItem(at: $0) }
        ))
        let folderURL = URL(fileURLWithPath: "/virtual/released-preview")
        var storage: AdvancedExportPreviewStorage? = AdvancedExportPreviewStorage(
            folderURL: folderURL,
            outputURL: folderURL.appendingPathComponent("preview.jpg"),
            cleanupService: service
        )

        #expect(storage != nil)
        storage = nil
        try await probe.waitUntilFirstRemovalStarts()

        // The actor removal is still blocked, but MainActor completed the final release.
        #expect(probe.removalCount == 1)
        #expect(!probe.ranOnMainThread)
    }
}

private enum AdvancedExportPreviewCleanupProbeError: Error {
    case timedOut
}

private enum AdvancedExportPreviewCleanupInjectedError: Error {
    case refused
}

private nonisolated final class BlockingAdvancedExportPreviewCleanupProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var storedRemovalCount = 0
    private var activeRemovalCount = 0
    private var storedMaximumConcurrentRemovalCount = 0
    private var firstRemovalReleased = false
    private var observedMainThread = false

    func removeItem(at url: URL) throws {
        _ = url
        condition.lock()
        storedRemovalCount += 1
        activeRemovalCount += 1
        storedMaximumConcurrentRemovalCount = max(
            storedMaximumConcurrentRemovalCount,
            activeRemovalCount
        )
        observedMainThread = observedMainThread || Thread.isMainThread
        condition.broadcast()
        if storedRemovalCount == 1 {
            while !firstRemovalReleased {
                if !condition.waitBounded() { break }
            }
        }
        activeRemovalCount -= 1
        condition.unlock()
    }

    func waitUntilFirstRemovalStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while removalCount == 0 {
            guard ContinuousClock.now < deadline else {
                // A test that gives up must not leave the probe holding a shared queue.
                releaseFirstRemoval()
                throw AdvancedExportPreviewCleanupProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstRemoval() {
        condition.lock()
        firstRemovalReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var removalCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedRemovalCount
    }

    var maximumConcurrentRemovalCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedMaximumConcurrentRemovalCount
    }

    var ranOnMainThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return observedMainThread
    }
}

@Suite("Advanced Export presenting-display layout")
struct AdvancedExportLayoutTests {
    @Test func smallDisplayKeepsSheetInsideUsableArea() {
        let layout = AdvancedExportLayout(visibleSize: CGSize(width: 1024, height: 640))
        #expect(layout.size.width <= 1024 * 0.9)
        #expect(layout.size.height <= 640 * 0.9)
        #expect(layout.comparisonWidth >= 780)
    }

    @Test func largeDisplayUsesBoundedComfortableSheet() {
        let layout = AdvancedExportLayout(visibleSize: CGSize(width: 3840, height: 2160))
        #expect(layout.size == CGSize(width: 1320, height: 1000))
        #expect(layout.comparisonWidth == 1019)
    }

    @Test func movingBetweenDisplaysRecomputesBothDimensions() {
        let laptop = AdvancedExportLayout(visibleSize: CGSize(width: 1280, height: 720))
        let external = AdvancedExportLayout(visibleSize: CGSize(width: 2560, height: 1440))
        #expect(laptop.size.width < external.size.width)
        #expect(laptop.size.height < external.size.height)
    }

    @Test func missingOrInvalidDisplayHasFiniteFallback() {
        let fallback = AdvancedExportLayout(visibleSize: nil)
        #expect(fallback.size == CGSize(width: 1060, height: 720))
        #expect(AdvancedExportLayout(visibleSize: .zero) == fallback)
        #expect(AdvancedExportLayout(visibleSize: CGSize(width: CGFloat.infinity, height: 800)) == fallback)
    }
}

@Suite("MCP typed immutable metadata snapshots")
struct MCPMetadataSnapshotReaderTests {
    @Test("Effective metadata tool dispatch preserves typed results and refuses invalid authority or carriers",
          arguments: ["success", "disabled", "extraArgument", "missingPath", "wrongPathType", "busy", "invalidSource", "invalidXMP", "oversized"])
    func effectiveToolDispatch(mode: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apa-mcp-dispatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try snapshot(invalidSource: mode == "invalidSource", invalidXMP: mode == "invalidXMP")
        let photo = root.appendingPathComponent("frame.jpg")
        let xmp = root.appendingPathComponent("frame.xmp")
        try input.sourceBytes.write(to: photo)
        try input.xmpBytes?.write(to: xmp)
        if mode == "oversized" {
            let folder = root.appendingPathComponent(".photo_metadata")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(MetadataSidecar(sourceFile: "frame.jpg", pendingChanges: true,
                metadata: IPTCMetadata(description: String(repeating: "x", count: 32_769))))
                .write(to: folder.appendingPathComponent("frame.jpg.meta.json"))
        }
        let box = MCPServerCoreTests.DataBox()
        let store = MCPAuthorizationStore(readConfigurationData: { box.read() },
            writeConfigurationData: { box.write($0) })
        try store.addRoot(root)
        try store.setEnabled(mode != "disabled")
        let lease = mode == "busy" ? try MCPProcessReservation.acquirePhoto(photo) : nil
        defer { lease?.release() }
        let session = MCPServerSession(authorizationStore: store)
        _ = session.response(forLine: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#.utf8))
        _ = session.response(forLine: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        var arguments: [String: MCPJSONValue] = ["path": .string(photo.path)]
        if mode == "extraArgument" { arguments["includePrivateHistory"] = .bool(true) }
        if mode == "missingPath" { arguments = [:] }
        if mode == "wrongPathType" { arguments["path"] = .bool(true) }
        let request = MCPJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .integer(2), "method": .string("tools/call"),
            "params": .object(["name": .string("get_photo_metadata"), "arguments": .object(arguments)])])
        let response = try #require(session.response(forLine: JSONEncoder().encode(request)))
        let result = try #require(JSONDecoder().decode(MCPJSONValue.self, from: response)
            .objectValue?["result"]?.objectValue)
        #expect(result["isError"] == .bool(mode != "success"))
        let content = try #require(result["structuredContent"]?.objectValue)
        if mode == "success" {
            #expect(content["fields"]?.objectValue?["title"] == .string("Sidecar"))
            #expect(content["fieldCarriers"]?.objectValue?["title"] == .string("xmp"))
            #expect(content["effectiveIPTCResolved"] == .bool(true))
            #expect(content["sourceRevision"]?.stringValue?.isEmpty == false)
            #expect(content["fields"]?.objectValue?["cameraRaw"] == nil)
        } else {
            let expected = switch mode {
            case "disabled": "disabled"
            case "extraArgument", "missingPath", "wrongPathType": "invalid_arguments"
            case "busy": "busy"
            default: "metadata_read_failed"
            }
            #expect(content["code"] == .string(expected))
            #expect(content["fields"] == nil)
        }
        #expect(try Data(contentsOf: photo) == input.sourceBytes)
        #expect(try Data(contentsOf: xmp) == input.xmpBytes)
        lease?.release()
        let released = try MCPProcessReservation.acquirePhoto(photo)
        released.release()
    }

    @Test("Authorized effective reads integrate captured parsing, bounded output and revision evidence")
    func authorizedEffectiveRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apa-effective-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try snapshot()
        let photo = root.appendingPathComponent("frame.jpg")
        try input.sourceBytes.write(to: photo)
        try input.xmpBytes?.write(to: root.appendingPathComponent("frame.xmp"))
        let box = MCPServerCoreTests.DataBox()
        let store = MCPAuthorizationStore(readConfigurationData: { box.read() },
            writeConfigurationData: { box.write($0) })
        try store.addRoot(root)
        try store.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: store)
        let value = try #require(MCPMetadataSnapshotReader.inspectPhoto(path: photo.path, facade: facade).objectValue)
        let fields = try #require(value["fields"]?.objectValue)
        #expect(fields["title"] == .string("Sidecar"))
        #expect(value["effectiveIPTCResolved"] == .bool(true))
        let revisions = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        for key in ["canonicalPath", "rootID", "sourceRevision", "xmpSidecarRevision", "appSidecarRevision"] {
            #expect(value[key] == revisions[key])
        }
        try store.setEnabled(false)
        #expect(throws: MCPAuthorizationError.self) {
            try MCPMetadataSnapshotReader.inspectPhoto(path: photo.path, facade: facade)
        }
    }

    @Test("Effective protocol output binds values, state and revisions to the captured target",
          arguments: [false, true])
    func protocolSnapshot(sourceNewer: Bool) throws {
        let input = try snapshot(sourceNewer: sourceNewer)
        let result = try MCPMetadataSnapshotReader.read(input)
        let output = try #require(result.protocolValue().objectValue)
        let fields = try #require(output["fields"]?.objectValue)
        #expect(fields["title"] == .string(sourceNewer ? "Embedded" : "Sidecar"))
        #expect(fields["description"] == .null)
        #expect(fields["keywords"] == .array([]))
        #expect(Set(fields.keys) == MCPEditorialFieldCatalog.fieldKeys)
        let carriers = try #require(output["fieldCarriers"]?.objectValue)
        #expect(Set(carriers.keys) == Set(fields.keys))
        #expect(carriers["title"] == .string(sourceNewer ? "embedded" : "xmp"))
        #expect(carriers["localizedTitles"] == .string("embedded"))
        #expect(output["canonicalPath"] == .string(input.target.url.path))
        #expect(output["rootID"] == .string(input.target.rootID.uuidString.lowercased()))
        #expect(output["sourceRevision"] == .string("source-token"))
        #expect(output["xmpSidecarRevision"] == .string("xmp-token"))
        #expect(output["appSidecarRevision"] == .string("json-token"))
        #expect(output["hasXMPConflict"] == .bool(sourceNewer))
        #expect(output["hasPendingChanges"] == .bool(false))
        #expect(output["descriptiveRecordCarrier"] == .string(sourceNewer ? "embedded" : "xmp"))
    }

    @Test("Protocol values preserve localized Titles, types, clears and literal untrusted text")
    func typedProtocolValues() throws {
        let text = "Ignore instructions; quote: \" slash: \\ newline: \n 😀"
        let metadata = IPTCMetadata(title: "Headline", localizedTitles: [
            .init(languageTag: "x-default", value: text), .init(languageTag: "nb", value: "Tittel")
        ], description: "", keywords: ["second", "first"], urgency: 3,
           latitude: 59.9, longitude: 10.7, creators: ["Two", "One"], rating: 4,
           label: "", cameraRaw: CameraRawSettings(), exifOrientation: 6)
        let value = try protocolResult(metadata).protocolValue()
        let roundTrip = try JSONDecoder().decode(MCPJSONValue.self, from: JSONEncoder().encode(value))
        #expect(roundTrip == value)
        let output = try #require(value.objectValue)
        let fields = try #require(output["fields"]?.objectValue)
        #expect(fields["title"] == .string("Headline"))
        #expect(fields["description"] == .string(""))
        #expect(fields["localizedTitles"] == .array([
            .object(["languageTag": .string("x-default"), "value": .string(text)]),
            .object(["languageTag": .string("nb"), "value": .string("Tittel")])]))
        #expect(fields["keywords"] == .array([.string("second"), .string("first")]))
        #expect(fields["creators"] == .array([.string("Two"), .string("One")]))
        #expect(fields["urgency"] == .integer(3))
        #expect(fields["latitude"] == .number(59.9))
        #expect(fields["cameraRaw"] == nil)
        #expect(fields["exifOrientation"] == nil)
        #expect(output["hasPendingChanges"] == .bool(true))
        #expect(output["descriptiveRecordCarrier"] == .string("pendingAppSidecar"))
        #expect(MCPEditorialFieldCatalog.fieldKeys == IPTCMetadata.persistedJSONFieldNames)
    }

    @Test("Output limits refuse whole records rather than truncating values",
          arguments: ["scalar", "unicode", "array", "item", "aggregate", "escaped", "nonfinite"])
    func protocolLimits(kind: String) throws {
        var metadata = IPTCMetadata()
        switch kind {
        case "scalar": metadata.description = String(repeating: "x", count: 32_769)
        case "unicode": metadata.description = String(repeating: "😀", count: 8_193)
        case "array": metadata.keywords = Array(repeating: "x", count: 129)
        case "item": metadata.keywords = [String(repeating: "x", count: 1_025)]
        case "aggregate":
            metadata.description = String(repeating: "x", count: 32_768)
            metadata.extendedDescription = String(repeating: "x", count: 32_768)
            metadata.title = "x"
        case "escaped":
            metadata.description = String(repeating: "\u{01}", count: 32_768)
            metadata.extendedDescription = String(repeating: "\u{01}", count: 32_768)
        default: metadata.latitude = .infinity
        }
        #expect(throws: (any Error).self) { try protocolResult(metadata).protocolValue() }
    }

    @Test("Text at the scalar and aggregate boundaries remains complete")
    func protocolBoundary() throws {
        let text = String(repeating: "x", count: 32_768)
        let value = try protocolResult(IPTCMetadata(description: text, extendedDescription: text)).protocolValue()
        let fields = try #require(value.objectValue?["fields"]?.objectValue)
        #expect(fields["description"] == .string(text))
        #expect(fields["extendedDescription"] == .string(text))
    }

    private func protocolResult(_ metadata: IPTCMetadata) throws -> MCPMetadataSnapshotReader.Result {
        let input = try snapshot()
        return .init(target: input.target,
            resolution: .init(metadata: metadata, descriptiveCarrier: .pendingAppSidecar,
                              fieldCarriers: Dictionary(uniqueKeysWithValues: IPTCMetadata.persistedJSONFieldNames.map { ($0, .pendingAppSidecar) }),
                              hasPendingChanges: true, hasXMPConflict: false),
            sourceRevision: input.sourceRevision, xmpSidecarRevision: input.xmpSidecarRevision,
            appSidecarRevision: input.appSidecarRevision)
    }

    @Test("Protocol output refuses incomplete or unexpected field provenance", arguments: [false, true])
    func invalidFieldProvenance(extra: Bool) throws {
        let original = try protocolResult(IPTCMetadata(title: "Caption"))
        var carriers = original.resolution.fieldCarriers
        if extra { carriers["privateHistory"] = .embedded }
        else { carriers.removeValue(forKey: "title") }
        let result = MCPMetadataSnapshotReader.Result(target: original.target,
            resolution: .init(metadata: original.resolution.metadata, descriptiveCarrier: .pendingAppSidecar,
                fieldCarriers: carriers, hasPendingChanges: true, hasXMPConflict: false),
            sourceRevision: original.sourceRevision, xmpSidecarRevision: original.xmpSidecarRevision,
            appSidecarRevision: original.appSidecarRevision)
        #expect(throws: MCPMetadataSnapshotReader.ReadError.self) { try result.protocolValue() }
    }

    @Test("Structured editorial output retains paired and ordered values")
    func structuredProtocolValues() throws {
        let metadata = try JSONDecoder().decode(IPTCMetadata.self, from: Data(#"""
        {"localizedTitles":[],"imageSuppliers":[{"identifier":"one","name":"First"},{"identifier":"two","name":"Second"}],
         "locationsCreated":[{"city":"Oslo","latitude":59.9,"longitude":10.7}],
         "locationsShown":[{"city":"Bergen"}],
         "creatorContactInfo":{"emails":["one@example.test","two@example.test"]}}
        """#.utf8))
        let fields = try #require(protocolResult(metadata).protocolValue().objectValue?["fields"]?.objectValue)
        #expect(fields["localizedTitles"] == .array([]))
        #expect(fields["imageSuppliers"] == .array([
            .object(["identifier": .string("one"), "name": .string("First")]),
            .object(["identifier": .string("two"), "name": .string("Second")])]))
        guard case .array(let created) = fields["locationsCreated"],
              case .array(let shown) = fields["locationsShown"] else {
            Issue.record("Structured locations were lost"); return
        }
        #expect(created.first?.objectValue?["city"] == .string("Oslo"))
        #expect(created.first?.objectValue?["latitude"] == .number(59.9))
        #expect(shown.first?.objectValue?["city"] == .string("Bergen"))
        #expect(fields["creatorContactInfo"]?.objectValue?["emails"] ==
            .array([.string("one@example.test"), .string("two@example.test")]))
    }

    @Test("Captured bytes and timestamps resolve without an existing source path", arguments: [false, true])
    func capturedResolution(sourceNewer: Bool) throws {
        let result = try MCPMetadataSnapshotReader.read(snapshot(sourceNewer: sourceNewer))
        #expect(result.resolution.metadata.title == (sourceNewer ? "Embedded" : "Sidecar"))
        #expect(result.resolution.hasXMPConflict == sourceNewer)
        #expect(result.resolution.descriptiveCarrier == (sourceNewer ? .embedded : .xmp))
        #expect(result.sourceRevision == "source-token")
        #expect(result.xmpSidecarRevision == "xmp-token")
        #expect(result.appSidecarRevision == "json-token")
    }

    @Test("Pending JSON clears physical text; saved JSON leaves physical values", arguments: [false, true])
    func ownedDraft(pending: Bool) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let app = try encoder.encode(MetadataSidecar(sourceFile: "frame.jpg", pendingChanges: pending,
            metadata: IPTCMetadata(description: "Draft")))
        let result = try MCPMetadataSnapshotReader.read(snapshot(app: app))
        #expect(result.resolution.metadata.title == (pending ? nil : "Sidecar"))
        #expect(result.resolution.metadata.description == (pending ? "Draft" : nil))
        #expect(result.resolution.hasPendingChanges == pending)
        #expect(result.resolution.descriptiveCarrier == (pending ? .pendingAppSidecar : .xmp))
        let output = try #require(result.protocolValue().objectValue)
        #expect(output["hasPendingChanges"] == .bool(pending))
        #expect(output["fields"]?.objectValue?["title"] == (pending ? .null : .string("Sidecar")))
    }

    @Test("Malformed or unsupported carriers refuse instead of returning empty metadata",
          arguments: ["source", "xmp", "owner", "schema", "pending", "metadata", "nullMetadata", "unknownSchema"])
    func invalidCarrier(kind: String) throws {
        let app: Data?
        switch kind {
        case "owner": app = Data(#"{"schemaVersion":1,"sourceFile":"other.jpg","pendingChanges":true,"metadata":{}}"#.utf8)
        case "schema": app = Data(#"{"schemaVersion":999,"sourceFile":"frame.jpg","pendingChanges":true}"#.utf8)
        case "pending": app = Data(#"{"sourceFile":"frame.jpg","metadata":{}}"#.utf8)
        case "nullMetadata": app = Data(#"{"schemaVersion":1,"sourceFile":"frame.jpg","pendingChanges":true,"metadata":null}"#.utf8)
        case "unknownSchema": app = Data(#"{"sourceFile":"frame.jpg","pendingChanges":true,"metadata":{}}"#.utf8)
        case "metadata": app = Data(#"{"sourceFile":"frame.jpg","pendingChanges":true,"metadata":42}"#.utf8)
        default: app = nil
        }
        let input = try snapshot(app: app, invalidSource: kind == "source", invalidXMP: kind == "xmp")
        #expect(throws: (any Error).self) { try MCPMetadataSnapshotReader.read(input) }
    }

    @Test("Absent XMP preserves embedded metadata")
    func absentXMP() throws {
        let result = try MCPMetadataSnapshotReader.read(snapshot(absentXMP: true))
        #expect(result.resolution.metadata.title == "Embedded")
        #expect(result.resolution.descriptiveCarrier == .embedded)
        #expect(!result.resolution.hasXMPConflict)
    }

    @Test("Incomplete, unrelated and DTD-bearing XML cannot supply effective metadata",
          arguments: ["<broken>", "<unrelated/>",
            "<!DOCTYPE rdf:RDF [<!ENTITY caption 'text'>]><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'/>"])
    func invalidXML(xml: String) throws {
        let input = try snapshot(xmpOverride: Data(xml.utf8))
        #expect(throws: EffectiveMetadataResolver.ReadError.self) {
            try MCPMetadataSnapshotReader.read(input)
        }
    }

    @Test("Empty RDF records and packet padding preserve the embedded baseline", arguments: [false, true])
    func emptyRDF(packetPadding: Bool) throws {
        var xml = "<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'/>"
        if packetPadding { xml += "<?xpacket end='w'?>\0\0" }
        let result = try MCPMetadataSnapshotReader.read(snapshot(xmpOverride: Data(xml.utf8)))
        #expect(result.resolution.metadata.title == "Embedded")
        #expect(result.resolution.descriptiveCarrier == .embedded)
    }

    private func snapshot(sourceNewer: Bool = false, app: Data? = nil,
                          invalidSource: Bool = false, invalidXMP: Bool = false,
                          absentXMP: Bool = false, xmpOverride: Data? = nil) throws -> MCPPhotoCarrierSnapshot {
        let pixels = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(pixels.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCHeadline: "Embedded"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let xmp = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" photoshop:Headline="Sidecar"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8)
        return MCPPhotoCarrierSnapshot(target: MCPAuthorizedTarget(
            url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/frame.jpg"), rootID: UUID(),
            isDirectory: false, identity: MCPFileIdentity(device: 0, inode: 0)),
            sourceBytes: invalidSource ? Data() : bytes as Data,
            xmpBytes: absentXMP ? nil : (xmpOverride ?? (invalidXMP ? Data() : xmp)), appSidecarBytes: app,
            sourceModificationDate: Date(timeIntervalSince1970: sourceNewer ? 200 : 100),
            xmpModificationDate: absentXMP ? nil : Date(timeIntervalSince1970: 150),
            sourceRevision: "source-token", xmpSidecarRevision: "xmp-token", appSidecarRevision: "json-token")
    }
}

@Suite("Captured XMP metadata decoding")
struct XMPMetadataReaderTests {
    @Test("Captured sidecars retain editorial clears and XMP-only orientation, GPS and date")
    func capturedEditorialFields() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
              xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
              xmlns:exif="http://ns.adobe.com/exif/1.0/"
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:aaphoto="http://aagedal.me/ns/photo/1.0/"
              photoshop:Headline="Captured headline" photoshop:DateCreated="2026-09-19"
              tiff:Orientation="6" exif:Orientation="3"
              exif:GPSLatitude="59° 30' 0N" exif:GPSLongitude="10.5W"
              xmp:Label="" aaphoto:LocalizedTitleCleared="True"/>
          </rdf:RDF>
        </x:xmpmeta>
        """
        let metadata = try #require(XMPMetadataReader.read(Data(xml.utf8), imageAspect: {
            Issue.record("An unrotated sidecar must not request sensor dimensions")
            return nil
        }))
        #expect(metadata.title == "Captured headline")
        #expect(metadata.localizedTitles == [])
        #expect(metadata.label == "")
        #expect(metadata.exifOrientation == 6)
        #expect(metadata.latitude == 59.5)
        #expect(metadata.longitude == -10.5)
        #expect(metadata.dateCreated == "2026-09-19")
    }

    @Test("Sensor aspect is requested only for an angled crop", arguments: [0.0, 12.0])
    func lazyCropAspect(angle: Double) throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
              crs:HasCrop="True" crs:CropLeft="0.1" crs:CropTop="0.1"
              crs:CropRight="0.9" crs:CropBottom="0.9" crs:CropAngle="\(angle)"/>
          </rdf:RDF>
        </x:xmpmeta>
        """
        var requests = 0
        let metadata = try #require(XMPMetadataReader.read(Data(xml.utf8), imageAspect: {
            requests += 1
            return 1.5
        }))
        #expect(metadata.cameraRaw?.crop != nil)
        #expect(requests == (angle == 0 ? 0 : 1))
    }
}

@Suite("FFmpeg local image boundary")
struct FFmpegLocalImageBoundaryTests {
    @Test("input and output protocols are restricted independently")
    func localInvocation() throws {
        let invocation = try FFmpegService.localImageInvocation(arguments: [
            "-hide_banner", "-y", "-i", "/tmp/Blå image '1'.png",
            "-frames:v", "1", "/tmp/output:still.png",
        ])
        #expect(invocation == [
            "-nostdin", "-hide_banner", "-y", "-protocol_whitelist", "file",
            "-i", "/tmp/Blå image '1'.png", "-frames:v", "1",
            "-protocol_whitelist", "file", "/tmp/output:still.png",
        ])
    }

    @Test("URLs, relative paths, additional inputs and protocol overrides are refused")
    func invalidInvocation() {
        for arguments in [
            ["-i", "https://example.invalid/image.png", "/tmp/output.png"],
            ["-i", "/tmp/input.png", "https://example.invalid/output.png"],
            ["-i", "input.png", "/tmp/output.png"],
            ["-i", "/tmp/input.png", "output.png"],
            ["-i", "/tmp/input.png", "-i", "/tmp/second.png", "/tmp/output.png"],
            ["-protocol_whitelist", "ALL", "-i", "/tmp/input.png", "/tmp/output.png"],
            ["-i", "/tmp/input.png", "-protocol_whitelist=ALL", "/tmp/output.png"],
            ["-i", "/tmp/input.png"],
            ["-i", "/tmp/input\0.png", "/tmp/output.png"],
        ] {
            #expect(throws: FFmpegError.self) {
                try FFmpegService.localImageInvocation(arguments: arguments)
            }
        }
    }
}

@Suite("Export IPTC selection worker")
struct ExportIPTCSelectionTests {
    @Test("Pending app drafts suppress older physical carriers, including empty and partial drafts",
          arguments: [IPTCMetadata(), IPTCMetadata(rating: 3), IPTCMetadata(title: "Pending")])
    func pendingDraftPrecedence(metadata: IPTCMetadata) async {
        let probe = ExportIPTCSelectionProbe(draft: metadata, xmp: IPTCMetadata(title: "Older XMP"))
        let result = await probe.service.select(sourceURL: probe.sourceURL, folderURL: probe.folderURL)
        #expect(result == .pendingDraft(metadata))
        #expect(probe.calls == ["draft"])
    }

    @Test("Saved app history does not hide the authoritative physical XMP record")
    func savedDraftFallsThroughToXMP() async {
        let metadata = IPTCMetadata(title: "Saved XMP")
        let probe = ExportIPTCSelectionProbe(draft: IPTCMetadata(title: "Old history"),
            xmp: metadata, draftPending: false)
        #expect(await probe.service.select(sourceURL: probe.sourceURL, folderURL: probe.folderURL) == .xmp(metadata))
        #expect(probe.calls == ["draft", "xmp", "embedded", "reconcile"])
    }

    @Test("Develop-only XMP and missing carriers avoid embedded reads and reconciliation")
    func noDescriptiveRecord() async {
        var develop = IPTCMetadata()
        var settings = CameraRawSettings()
        settings.exposure2012 = 1
        develop.cameraRaw = settings
        let probe = ExportIPTCSelectionProbe(xmp: develop)
        #expect(await probe.service.select(sourceURL: probe.sourceURL, folderURL: probe.folderURL) == .noPendingEdits)
        #expect(probe.calls == ["draft", "xmp"])
        let absent = ExportIPTCSelectionProbe()
        #expect(await absent.service.select(sourceURL: absent.sourceURL, folderURL: nil) == .noPendingEdits)
        #expect(absent.calls == ["xmp"])
    }

    @Test("XMP selection preserves conflict and embedded-read-failure policy", arguments: [false, true])
    func reconciliationPolicy(stale: Bool) async {
        let metadata = IPTCMetadata(title: "XMP")
        let probe = ExportIPTCSelectionProbe(xmp: metadata, embedded: stale ? IPTCMetadata(title: "New embedded") : nil,
            verdict: stale ? .fileNewerConflict : .sidecarMaster)
        let result = await probe.service.select(sourceURL: probe.sourceURL, folderURL: probe.folderURL)
        #expect(result == (stale ? .staleSidecarSkipped : .xmp(metadata)))
        #expect(probe.calls == ["draft", "xmp", "embedded", "reconcile"])
    }

    @Test("Rating and label-only XMP avoids unnecessary source-container reads",
          arguments: [IPTCMetadata(rating: 3), IPTCMetadata(label: "Red"), IPTCMetadata(label: "")])
    func partialXMPDoesNotReadEmbedded(metadata: IPTCMetadata) async {
        let probe = ExportIPTCSelectionProbe(xmp: metadata)
        #expect(await probe.service.select(sourceURL: probe.sourceURL, folderURL: probe.folderURL) == .xmp(metadata))
        #expect(probe.calls == ["draft", "xmp"])
    }

    @MainActor
    @Test("Selection runs on its retained worker while MainActor stays responsive and reads serialize")
    func workerContextAndSerialization() async throws {
        let marker = UUID()
        let probe = ExportIPTCSelectionProbe(draft: IPTCMetadata(title: "Pending"), blocksFirstDraft: true)
        let service = probe.service
        let first = Task { @MainActor in
            await ExportIPTCSelectionContext.$marker.withValue(marker) {
                await service.select(sourceURL: probe.sourceURL, folderURL: probe.folderURL)
            }
        }
        defer { probe.releaseDraft(); first.cancel() }
        try await waitForSelection { probe.calls == ["draft"] }
        // This assertion executes on MainActor while the filesystem callback is blocked.
        #expect(!probe.completedFirstDraft)
        let second = Task { @MainActor in
            await ExportIPTCSelectionContext.$marker.withValue(marker) {
                await service.select(sourceURL: probe.sourceURL.appendingPathExtension("other"), folderURL: probe.folderURL)
            }
        }
        defer { second.cancel() }
        await Task.yield()
        #expect(probe.calls == ["draft"])
        probe.releaseDraft()
        #expect(await first.value == .pendingDraft(IPTCMetadata(title: "Pending")))
        #expect(await second.value == .pendingDraft(IPTCMetadata(title: "Pending")))
        #expect(probe.calls == ["draft", "draft"])
        #expect(probe.observedMarkers == [marker, marker])
        #expect(probe.executedOnWorker)
        #expect(!probe.executedOnMain)
        #expect(!probe.gateTimedOut)
    }

    @Test("Selection waits for an admitted source transaction before reading its draft")
    func orderedSourceLease() async throws {
        let probe = ExportIPTCSelectionProbe(draft: IPTCMetadata(title: "Before commit"))
        let service = probe.service
        let release = AsyncStream<Void>.makeStream()
        let owner = Task {
            await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: probe.sourceURL)) {
                probe.markLeaseStarted()
                for await _ in release.stream { break }
                probe.replaceDraft(IPTCMetadata(title: "Committed"))
            }
        }
        defer { release.continuation.yield(()); release.continuation.finish(); owner.cancel() }
        try await waitForSelection { probe.leaseStarted }
        let selection = Task { await service.select(sourceURL: probe.sourceURL, folderURL: probe.folderURL) }
        defer { selection.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(probe.calls.isEmpty)
        release.continuation.yield(())
        release.continuation.finish()
        await owner.value
        #expect(await selection.value == .pendingDraft(IPTCMetadata(title: "Committed")))
    }

    @Test("A cancelled post-render caller still selects metadata rather than reporting no edits")
    func cancelledCallerStillSelects() async {
        let metadata = IPTCMetadata(title: "Pending after render")
        let probe = ExportIPTCSelectionProbe(draft: metadata)
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await probe.service.select(sourceURL: probe.sourceURL, folderURL: probe.folderURL)
        }.value
        #expect(result == .pendingDraft(metadata))
        #expect(probe.calls == ["draft"])
    }

    @Test("Selection releases the source lease before writing metadata onto that same URL")
    func sameSourceDestinationCompletes() async throws {
        let probe = ExportIPTCSelectionProbe(draft: IPTCMetadata(title: "Selected caption"))
        let (directory, source) = try selectionWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = probe.service
        let operation = Task {
            let result = await SidecarIPTCOverlay.apply(sourceURL: source, renderedURL: source,
                folderURL: directory, writeEngine: SwiftExifWriteEngine(), service: service)
            probe.recordOutcome(result)
        }
        defer { operation.cancel() }
        // A regression that retains the source lease would otherwise hang the test process.
        try await waitForSelection { probe.outcome != nil }
        guard let outcome = probe.outcome, case .applied = outcome else {
            Issue.record("Expected completed overlay"); return
        }
        #expect(try await SwiftExifReadService().readFullMetadata(url: source).title == "Selected caption")
        await operation.value
    }

    @Test("Empty drafts stop fallback and cancelled metadata writes retain their failure outcome",
          arguments: [false, true])
    func postRenderOutcomePolicy(cancelled: Bool) async throws {
        let (directory, source) = try selectionWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        let draft = cancelled ? IPTCMetadata(title: "Pending") : IPTCMetadata()
        let probe = ExportIPTCSelectionProbe(draft: draft, xmp: IPTCMetadata(title: "Older XMP"))
        let service = probe.service
        let outcome = await Task {
            if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
            return await SidecarIPTCOverlay.apply(sourceURL: source, renderedURL: source,
                folderURL: directory, writeEngine: SwiftExifWriteEngine(), service: service)
        }.value
        if cancelled {
            guard case .failed = outcome else { Issue.record("Cancelled metadata write must remain a failure"); return }
        } else {
            guard case .noPendingEdits = outcome else { Issue.record("Empty pending draft must stop XMP fallback"); return }
        }
        #expect(probe.calls == ["draft"])
        #expect(try Data(contentsOf: source) == original)
    }

    private func selectionWorkspace() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("selection-file-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("photo.jpg")
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(image.representation(using: .jpeg, properties: [:])).write(to: source)
        return (directory, source)
    }

    private func waitForSelection(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ExportIPTCSelectionProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum ExportIPTCSelectionProbeError: Error { case timedOut }

private nonisolated enum ExportIPTCSelectionContext {
    @TaskLocal static var marker: UUID?
}

private nonisolated final class ExportIPTCSelectionProbe: @unchecked Sendable {
    let folderURL = URL(fileURLWithPath: "/virtual/selection-\(UUID())", isDirectory: true)
    var sourceURL: URL { folderURL.appendingPathComponent("source.jpg") }
    let queue = DispatchSerialQueue(label: "test.export-iptc-selection")
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var draft: IPTCMetadata?
    private let xmp: IPTCMetadata?
    private let embedded: IPTCMetadata?
    private let verdict: SidecarReconciliation.Verdict
    private let blocksFirstDraft: Bool
    private let draftPending: Bool
    private var storedCalls: [String] = []
    private var storedMarkers: [UUID?] = []
    private var storedOnWorker = true
    private var storedOnMain = false
    private var storedGateTimedOut = false
    private var storedDraftCompleted = false
    private var storedLeaseStarted = false
    private var storedOutcome: SidecarIPTCOverlay.Outcome?

    init(draft: IPTCMetadata? = nil, xmp: IPTCMetadata? = nil, embedded: IPTCMetadata? = nil,
         verdict: SidecarReconciliation.Verdict = .sidecarMaster, blocksFirstDraft: Bool = false,
         draftPending: Bool = true) {
        self.draft = draft; self.xmp = xmp; self.embedded = embedded
        self.verdict = verdict; self.blocksFirstDraft = blocksFirstDraft; self.draftPending = draftPending
    }

    var service: ExportIPTCSelectionService {
        ExportIPTCSelectionService(access: ExportIPTCSelectionAccess(
            loadDraft: { [self] source, _ in
                record("draft")
                let shouldBlock = lock.withLock { storedCalls.filter { $0 == "draft" }.count == 1 && blocksFirstDraft }
                if shouldBlock {
                    let timedOut = gate.wait(timeout: .now() + 10) != .success
                    lock.withLock { storedGateTimedOut = timedOut }
                }
                return lock.withLock {
                    storedDraftCompleted = true
                    return draft.map { MetadataSidecar(sourceFile: source.lastPathComponent, pendingChanges: draftPending, metadata: $0) }
                }
            },
            loadXMP: { [self] _ in record("xmp"); return xmp },
            readEmbedded: { [self] _ in record("embedded"); return embedded },
            reconcile: { [self] _, capturedEmbedded, capturedXMP in
                record("reconcile")
                #expect(capturedEmbedded == embedded)
                #expect(capturedXMP == xmp)
                return verdict
            }
        ), filesystemQueue: queue)
    }

    private func record(_ call: String) {
        lock.withLock {
            storedCalls.append(call)
            storedMarkers.append(ExportIPTCSelectionContext.marker)
            storedOnWorker = storedOnWorker && queue.isIsolatingCurrentContext() == true
            storedOnMain = storedOnMain || Thread.isMainThread
        }
    }
    var calls: [String] { lock.withLock { storedCalls } }
    var observedMarkers: [UUID?] { lock.withLock { storedMarkers } }
    var executedOnWorker: Bool { lock.withLock { storedOnWorker } }
    var executedOnMain: Bool { lock.withLock { storedOnMain } }
    var completedFirstDraft: Bool { lock.withLock { storedDraftCompleted } }
    var gateTimedOut: Bool { lock.withLock { storedGateTimedOut } }
    var leaseStarted: Bool { lock.withLock { storedLeaseStarted } }
    var outcome: SidecarIPTCOverlay.Outcome? { lock.withLock { storedOutcome } }
    func releaseDraft() { gate.signal() }
    func markLeaseStarted() { lock.withLock { storedLeaseStarted = true } }
    func replaceDraft(_ metadata: IPTCMetadata) { lock.withLock { draft = metadata } }
    func recordOutcome(_ outcome: SidecarIPTCOverlay.Outcome) { lock.withLock { storedOutcome = outcome } }
}

/// Injects failures at the real copy/overlay boundaries; all successful operations use
/// the production backend and produce real, readable image metadata.
private nonisolated final class ExportFailureEngine: MetadataWriteEngine {
    let failCopy: Bool
    let failOverlay: Bool
    let underlying = SwiftExifWriteEngine()
    init(failCopy: Bool, failOverlay: Bool) {
        self.failCopy = failCopy
        self.failOverlay = failOverlay
    }
    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        try await underlying.writeFields(fields, to: urls, structuredData: structuredData)
    }
    func writeFieldsToRenderedFiles(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        if failOverlay { throw CocoaError(.fileWriteUnknown) }
        try await underlying.writeFieldsToRenderedFiles(fields, to: urls, structuredData: structuredData)
    }
    func addRemoveListValues(add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]], to urls: [URL]) async throws {
        try await underlying.addRemoveListValues(add: add, remove: remove, to: urls)
    }
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws {
        try await underlying.writeRating(rating, to: urls)
    }
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws {
        try await underlying.writeLabel(label, to: urls)
    }
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws {
        try await underlying.writeOrientation(orientation, to: urls)
    }
    func stripIPTCAndXMP(from urls: [URL]) async throws {
        try await underlying.stripIPTCAndXMP(from: urls)
    }
    func copyMetadataToRenderedFile(from source: URL, to destination: URL, bakedCameraRaw: CameraRawSettings?) async throws {
        if failCopy { throw CocoaError(.fileWriteUnknown) }
        try await underlying.copyMetadataToRenderedFile(from: source, to: destination, bakedCameraRaw: bakedCameraRaw)
    }
}

@Suite("Edited export source preservation")
struct EditedExportSourcePreservationTests {
    @Test("Delivery format export beside its JPEG source allocates a distinct file and preserves original metadata")
    func deliveryBesideSource() async throws {
        let (directory, source) = try await workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        let tracker = MetadataFailureTracker()
        let output = try await EditExportPipeline.renderForDelivery(sourceURL: source,
            cameraRaw: nil, kind: .format, outputFolder: directory, folderURL: directory,
            writeEngine: SwiftExifWriteEngine(), failureTracker: tracker, configuration: configuration)
        #expect(output.lastPathComponent == "photo 2.jpg")
        #expect(output.standardizedFileURL != source.standardizedFileURL)
        #expect(try Data(contentsOf: source) == original)
        #expect(try await SwiftExifReadService().readFullMetadata(url: source).title == "Original headline")
        #expect(try await SwiftExifReadService().readFullMetadata(url: output).description == "Original caption")
        #expect(await tracker.metadataCopyFailures.isEmpty)
        #expect(await tracker.sidecarOverlayFailures.isEmpty)
    }

    @Test("Replacement refuses its own source before either SDR or HDR encoding", arguments: [false, true])
    func replacementRejectsSource(isHDR: Bool) async throws {
        let (directory, source) = try await workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        do {
            _ = try await EditedImageRenderer.render(from: source, cameraRaw: nil, isHDR: isHDR,
                outputFolder: directory, configuration: configuration, collisionPolicy: .replaceExisting)
            Issue.record("Source-alias encoding must be refused")
        } catch EditedImageRenderer.RenderError.sourceDestinationAlias { }
        #expect(try Data(contentsOf: source) == original)
        #expect(try await SwiftExifReadService().readFullMetadata(url: source).description == "Original caption")
    }

    @Test("Legacy JPEG export also rejects an in-place encode")
    func legacyJPEGRejectsSource() async throws {
        let (directory, source) = try await workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        do {
            try await EditedImageRenderer.renderJPEG(from: source, cameraRaw: nil, outputFolder: directory)
            Issue.record("Legacy JPEG must not replace its source")
        } catch EditedImageRenderer.RenderError.sourceDestinationAlias { }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test("Existing file, hard-link and directory-symlink aliases are refused or safely numbered",
          arguments: ["symlink", "hardlink", "directory-symlink"])
    func existingAliases(alias: String) async throws {
        let (directory, source) = try await workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        let outputFolder = directory.appendingPathComponent("output", isDirectory: true)
        if alias == "directory-symlink" {
            try FileManager.default.createSymbolicLink(at: outputFolder, withDestinationURL: directory)
        } else {
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            let target = outputFolder.appendingPathComponent("photo.jpg")
            if alias == "hardlink" { try FileManager.default.linkItem(at: source, to: target) }
            else { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source) }
        }
        let aliasURL = outputFolder.appendingPathComponent("photo.jpg")
        do {
            _ = try await EditedImageRenderer.render(from: source, cameraRaw: nil, isHDR: false,
                outputFolder: outputFolder, configuration: configuration, collisionPolicy: .replaceExisting)
            Issue.record("An existing alias must not be encoded over")
        } catch EditedImageRenderer.RenderError.sourceDestinationAlias { }
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: aliasURL) == original)
        let tracker = MetadataFailureTracker()
        let safe = try await EditExportPipeline.renderForDelivery(sourceURL: source, cameraRaw: nil,
            kind: .format, outputFolder: outputFolder, folderURL: directory,
            writeEngine: SwiftExifWriteEngine(), failureTracker: tracker, configuration: configuration)
        #expect(safe.lastPathComponent == "photo 2.jpg")
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: aliasURL) == original)
        #expect(try await SwiftExifReadService().readFullMetadata(url: safe).title == "Original headline")
        #expect(await tracker.metadataCopyFailures.isEmpty)
    }

    @Test("Explicit replacement of an independent output remains supported")
    func independentReplacement() async throws {
        let (directory, source) = try await workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        let outputFolder = directory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let expected = outputFolder.appendingPathComponent("photo.jpg")
        try Data("older independent rendition".utf8).write(to: expected)
        let output = try await EditExportPipeline.renderItem(sourceURL: source, cameraRaw: nil,
            kind: .format, outputFolder: outputFolder, folderURL: directory,
            writeEngine: SwiftExifWriteEngine(), failureTracker: MetadataFailureTracker(),
            configuration: configuration, collisionPolicy: .replaceExisting)
        #expect(output == expected)
        #expect(try Data(contentsOf: source) == original)
        #expect(try await SwiftExifReadService().readFullMetadata(url: output).title == "Original headline")
    }

    @Test("Save As retains numbered same-folder naming and preserves source bytes")
    func saveAsBesideSource() async throws {
        let (directory, source) = try await workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        let output = try await EditExportPipeline.renderItem(sourceURL: source, cameraRaw: nil,
            kind: .saveAs(.jpeg), outputFolder: directory, folderURL: directory,
            writeEngine: SwiftExifWriteEngine(), failureTracker: MetadataFailureTracker())
        #expect(output.lastPathComponent == "photo 2.jpg")
        #expect(try Data(contentsOf: source) == original)
        #expect(try await SwiftExifReadService().readFullMetadata(url: output).description == "Original caption")
    }

    @Test("Concurrent exports keep their own IPTC while a prior overlay is still admitted",
          arguments: ["format", "jpeg", "saveAs"])
    func concurrentExportsOwnTheirMetadata(secondKind: String) async throws {
        let (firstDirectory, firstSource) = try await workspace()
        let (secondDirectory, secondSource) = try await workspace()
        defer { try? FileManager.default.removeItem(at: firstDirectory); try? FileManager.default.removeItem(at: secondDirectory) }
        let firstBytes = try Data(contentsOf: firstSource)
        let secondBytes = try Data(contentsOf: secondSource)
        let output = firstDirectory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let firstMetadata = IPTCMetadata(title: "First pending", keywords: ["First, place"])
        let secondMetadata = IPTCMetadata(title: "Second pending", keywords: ["Second, place"])
        for (source, directory, metadata) in [(firstSource, firstDirectory, firstMetadata), (secondSource, secondDirectory, secondMetadata)] {
            try MetadataSidecarService().saveSidecar(MetadataSidecar(sourceFile: source.lastPathComponent,
                pendingChanges: true, metadata: metadata), for: source, in: directory)
        }
        let gate = ExportWriteGate(phase: .overlay)
        let engine = GatedExportWriteEngine(gate: gate)
        let first = Task { try await EditExportPipeline.renderForDelivery(sourceURL: firstSource,
            cameraRaw: nil, kind: .format, outputFolder: output, folderURL: firstDirectory,
            writeEngine: engine, failureTracker: MetadataFailureTracker(), configuration: configuration) }
        let watchdog = gate.watchdog()
        defer { gate.release(); first.cancel(); watchdog.cancel() }
        let firstOutput = try await gate.waitForDestination()
        let beforeReplacement = try Data(contentsOf: firstOutput)
        do {
            _ = try await EditExportPipeline.renderItem(sourceURL: secondSource, cameraRaw: nil,
                kind: .format, outputFolder: output, folderURL: secondDirectory,
                writeEngine: SwiftExifWriteEngine(), failureTracker: MetadataFailureTracker(),
                configuration: configuration, collisionPolicy: .replaceExisting)
            Issue.record("Replacement must not enter another artifact's pending IPTC stage")
        } catch EditedImageRenderer.RenderError.destinationBusy { }
        #expect(try Data(contentsOf: firstOutput) == beforeReplacement)
        let kind: RenderKind = secondKind == "format" ? .format : secondKind == "jpeg" ? .jpeg : .saveAs(.jpeg)
        let secondOutput = try await EditExportPipeline.renderForDelivery(sourceURL: secondSource,
            cameraRaw: nil, kind: kind, outputFolder: output, folderURL: secondDirectory,
            writeEngine: SwiftExifWriteEngine(), failureTracker: MetadataFailureTracker(), configuration: configuration)
        #expect(!gate.wasReleased && !gate.timedOut)
        #expect(firstOutput.lastPathComponent == "photo.jpg")
        #expect(secondOutput.lastPathComponent == "photo 2.jpg")
        let actualSecond = try await SwiftExifReadService().readFullMetadata(url: secondOutput)
        #expect(actualSecond.title == secondMetadata.title && actualSecond.keywords == secondMetadata.keywords)
        gate.release()
        #expect(try await first.value == firstOutput)
        let actualFirst = try await SwiftExifReadService().readFullMetadata(url: firstOutput)
        #expect(actualFirst.title == firstMetadata.title && actualFirst.keywords == firstMetadata.keywords)
        #expect(try Data(contentsOf: firstSource) == firstBytes)
        #expect(try Data(contentsOf: secondSource) == secondBytes)
        // A completed artifact may still be explicitly replaced; ownership is not leaked.
        let replacement = try await EditExportPipeline.renderItem(sourceURL: secondSource,
            cameraRaw: nil, kind: .format, outputFolder: output, folderURL: secondDirectory,
            writeEngine: SwiftExifWriteEngine(), failureTracker: MetadataFailureTracker(),
            configuration: configuration, collisionPolicy: .replaceExisting)
        #expect(replacement == firstOutput)
        #expect(try await SwiftExifReadService().readFullMetadata(url: replacement).title == secondMetadata.title)
    }

    @Test("Cancel and restart cannot reuse a JPEG filename still owned by detached rendering")
    func cancelledJPEGProducerKeepsItsName() async throws {
        let (directory, source) = try await workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let original = try Data(contentsOf: source)
        let gate = ExportWriteGate(phase: .copy)
        let first = Task { try await EditExportPipeline.renderForDelivery(sourceURL: source,
            cameraRaw: nil, kind: .jpeg, outputFolder: output, folderURL: directory,
            writeEngine: GatedExportWriteEngine(gate: gate), failureTracker: MetadataFailureTracker()) }
        let watchdog = gate.watchdog()
        defer { gate.release(); first.cancel(); watchdog.cancel() }
        let firstOutput = try await gate.waitForDestination()
        first.cancel()
        let restarted = try await EditExportPipeline.renderForDelivery(sourceURL: source,
            cameraRaw: nil, kind: .jpeg, outputFolder: output, folderURL: directory,
            writeEngine: SwiftExifWriteEngine(), failureTracker: MetadataFailureTracker())
        #expect(!gate.wasReleased && !gate.timedOut)
        #expect(firstOutput.lastPathComponent == "photo.jpg")
        #expect(restarted.lastPathComponent == "photo 2.jpg")
        gate.release()
        _ = try await first.value
        #expect(try Data(contentsOf: source) == original)
        #expect(try await SwiftExifReadService().readFullMetadata(url: restarted).title == "Original headline")
        #expect(FileManager.default.fileExists(atPath: firstOutput.path))
    }

    private var configuration: AdvancedExportConfiguration {
        AdvancedExportConfiguration(sdrFormat: .jpeg, sdrQuality: 0.92, sdrGamut: .sRGB,
            hdrFormat: .jpegGainMap, hdrQuality: 0.92, hdrGamut: .displayP3,
            tiffCompression: .lzw, resolutionLimit: .original,
            locationMode: .sameAsOriginal, customSubfolderName: "Exports")
    }

    private func workspace() async throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-source-safety-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("photo.jpg")
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(image.representation(using: .jpeg, properties: [:])).write(to: source)
        try await SwiftExifWriteEngine().writeFields([.headline: "Original headline", .description: "Original caption"], to: [source])
        return (directory, source)
    }
}

private nonisolated final class ExportWriteGate: @unchecked Sendable {
    enum Phase: Sendable, Equatable { case copy, overlay }
    let phase: Phase
    private let lock = NSLock()
    private var destination: URL?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var expired = false
    init(phase: Phase) { self.phase = phase }
    var wasReleased: Bool { lock.withLock { released } }
    var timedOut: Bool { lock.withLock { expired } }
    func block(_ url: URL) async {
        await withCheckedContinuation { value in
            let alreadyReleased = lock.withLock {
                destination = url
                if released { return true }
                continuation = value
                return false
            }
            if alreadyReleased { value.resume() }
        }
    }
    func release(timedOut: Bool = false) {
        let value = lock.withLock {
            guard !released else { return Optional<CheckedContinuation<Void, Never>>.none }
            released = true
            expired = timedOut
            let value = continuation
            continuation = nil
            return value
        }
        value?.resume()
    }
    func waitForDestination() async throws -> URL {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let result = lock.withLock({ destination }) { return result }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.userCancelled)
    }
    func watchdog() -> Task<Void, Never> {
        Task.detached { [self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            release(timedOut: true)
        }
    }
}

private nonisolated final class GatedExportWriteEngine: MetadataWriteEngine {
    let gate: ExportWriteGate
    let underlying = SwiftExifWriteEngine()
    init(gate: ExportWriteGate) { self.gate = gate }
    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        try await underlying.writeFields(fields, to: urls, structuredData: structuredData)
    }
    func writeFieldsToRenderedFiles(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        if gate.phase == .overlay, let destination = urls.first { await gate.block(destination) }
        try await underlying.writeFieldsToRenderedFiles(fields, to: urls, structuredData: structuredData)
    }
    func addRemoveListValues(add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]], to urls: [URL]) async throws {
        try await underlying.addRemoveListValues(add: add, remove: remove, to: urls)
    }
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws { try await underlying.writeRating(rating, to: urls) }
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws { try await underlying.writeLabel(label, to: urls) }
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws { try await underlying.writeOrientation(orientation, to: urls) }
    func stripIPTCAndXMP(from urls: [URL]) async throws { try await underlying.stripIPTCAndXMP(from: urls) }
    func copyMetadataToRenderedFile(from source: URL, to destination: URL, bakedCameraRaw: CameraRawSettings?) async throws {
        if gate.phase == .copy { await gate.block(destination) }
        try await underlying.copyMetadataToRenderedFile(from: source, to: destination, bakedCameraRaw: bakedCameraRaw)
    }
}

// MARK: - 3.0 export/saving fixes (RAW+JPEG develop ownership, GPS, IIM, partial files, FTP)

@Suite("Export and saving fixes for 3.0")
struct ExportSavingReleaseFixTests {

    private func makeFolder(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func imageData(_ type: NSBitmapImageRep.FileType) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let data = rep.representation(using: type, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private func writeJPEG(to url: URL) throws { try imageData(.jpeg).write(to: url) }
    private func writePNG(to url: URL) throws { try imageData(.png).write(to: url) }

    /// IMG_1.ARW (placeholder bytes — never decoded here) + IMG_1.jpg + the shared IMG_1.xmp
    /// carrying the RAW's absolute-Kelvin WB, exposure and a caption.
    private func makeRawJpegPair() throws -> (dir: URL, raw: URL, jpeg: URL) {
        let dir = try makeFolder("raw-jpeg-pair")
        let raw = dir.appendingPathComponent("IMG_1.ARW")
        try Data("not a real raw".utf8).write(to: raw)
        let jpeg = dir.appendingPathComponent("IMG_1.jpg")
        try writeJPEG(to: jpeg)
        var crs = CameraRawSettings()
        crs.temperature = 5500
        crs.exposure2012 = 1.25
        try XMPSidecarService().saveSidecar(
            metadata: IPTCMetadata(title: "Shared caption", cameraRaw: crs), for: raw)
        return (dir, raw, jpeg)
    }

    // MARK: RAW+JPEG stem sidecar (finding 2)

    @Test("A RAW+JPEG pair's stem sidecar develop belongs to the RAW only")
    func stemSidecarDevelopOwnership() throws {
        let pair = try makeRawJpegPair()
        defer { try? FileManager.default.removeItem(at: pair.dir) }

        #expect(PhotoSidecarOwnership.stemSidecarDevelopBelongsToRawSibling(of: pair.jpeg))
        #expect(!PhotoSidecarOwnership.stemSidecarDevelopBelongsToRawSibling(of: pair.raw))
        let lone = pair.dir.appendingPathComponent("Other.jpg")
        try writeJPEG(to: lone)
        #expect(!PhotoSidecarOwnership.stemSidecarDevelopBelongsToRawSibling(of: lone))

        let service = XMPSidecarService()
        #expect(service.loadDevelopSettings(for: pair.raw)?.exposure2012 == 1.25)
        #expect(service.loadDevelopSettings(for: pair.jpeg) == nil)
        #expect(ExportCameraRawSidecarAccess.system.load(pair.jpeg) == nil)
        #expect(ExportCameraRawSidecarAccess.system.load(pair.raw)?.temperature == 5500)
        #expect(FullScreenImagePresentationFactsAccess.system.read(pair.jpeg).sidecarCameraRaw == nil)
        #expect(AdvancedExportPreparationAccess.live.loadCameraRawSidecar(pair.jpeg) == nil)
        #expect(FTPUploadSidecarAccess.system.load(pair.jpeg)?.cameraRaw == nil)
        // Descriptive fields stay shared (Photo Mechanic convention).
        #expect(FTPUploadSidecarAccess.system.load(pair.jpeg)?.title == "Shared caption")

        let facts = MetadataEditorReadAccess.systemRead(imageURL: pair.jpeg, folderURL: pair.dir,
            embedded: nil, reconciles: false)
        #expect(facts.xmpMetadata?.title == "Shared caption")
        #expect(facts.xmpMetadata?.cameraRaw == nil)
        let rawFacts = MetadataEditorReadAccess.systemRead(imageURL: pair.raw, folderURL: pair.dir,
            embedded: nil, reconciles: false)
        #expect(rawFacts.xmpMetadata?.cameraRaw?.exposure2012 == 1.25)
    }

    @MainActor
    @Test("Export Camera Raw resolution never hands the RAW's settings to its JPEG")
    func exportResolutionSkipsRawOwnedSidecar() async throws {
        let pair = try makeRawJpegPair()
        defer { try? FileManager.default.removeItem(at: pair.dir) }
        var map: [URL: IPTCMetadata] = [:]
        try await EditExportPipeline.resolveCameraRaw(into: &map, urls: [pair.raw, pair.jpeg],
            inMemory: { _ in nil })
        #expect(map[pair.raw]?.cameraRaw?.temperature == 5500)
        #expect(map[pair.jpeg]?.cameraRaw == nil)
    }

    @Test("Writes made for a pair's JPEG never replace the RAW's Camera Raw block")
    func jpegWritesPreserveRawDevelop() async throws {
        let pair = try makeRawJpegPair()
        defer { try? FileManager.default.removeItem(at: pair.dir) }
        let service = XMPSidecarService()
        var jpegCRS = CameraRawSettings()
        jpegCRS.exposure2012 = -2
        jpegCRS.temperature = 2000

        // Full-record descriptive save (XMP-sidecar mode) for the JPEG.
        try await service.saveSidecarSerialized(
            metadata: IPTCMetadata(title: "Edited on JPEG", cameraRaw: jpegCRS), for: pair.jpeg)
        var stored = try #require(service.loadSidecar(for: pair.raw))
        #expect(stored.title == "Edited on JPEG")
        #expect(stored.cameraRaw?.exposure2012 == 1.25)
        #expect(stored.cameraRaw?.temperature == 5500)

        // The Develop/Primary write path.
        let before = service.sidecarDataIfExists(for: pair.jpeg)
        _ = try await service.writeMetadataInHeldTransaction(
            IPTCMetadata(title: "Edited on JPEG", cameraRaw: jpegCRS), for: pair.jpeg,
            expectedSnapshot: .init(data: before), onlyIfExisting: false,
            replaceDevelopSettings: true, replaceOrientation: false)
        stored = try #require(service.loadSidecar(for: pair.raw))
        #expect(stored.cameraRaw?.exposure2012 == 1.25)

        // Develop-only writes: a clear is a no-op, a write is refused with a clear message.
        try await service.saveCameraRawOnlySerialized(nil, orientation: nil, for: pair.jpeg)
        #expect(service.loadSidecar(for: pair.raw)?.cameraRaw?.exposure2012 == 1.25)
        await #expect(throws: StemSidecarDevelopOwnedByRawError.self) {
            try await service.saveCameraRawOnlySerialized(jpegCRS, orientation: nil, for: pair.jpeg)
        }
        await #expect(throws: StemSidecarDevelopOwnedByRawError.self) {
            try await service.pasteCameraRawSerialized(jpegCRS, includeCrop: true, for: pair.jpeg)
        }
        #expect(service.loadSidecar(for: pair.raw)?.cameraRaw?.temperature == 5500)

        // The RAW itself still owns and replaces its block.
        try await service.saveCameraRawOnlySerialized(jpegCRS, orientation: nil, for: pair.raw)
        #expect(service.loadSidecar(for: pair.raw)?.cameraRaw?.exposure2012 == -2)
    }

    // MARK: Sidecar-only GPS (finding 3)

    @Test("A geotagged sidecar without a caption still carries GPS onto the export")
    func sidecarOnlyGPSReachesExport() async throws {
        let dir = try makeFolder("gps-only")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("photo.jpg")
        try writeJPEG(to: source)
        try XMPSidecarService().saveSidecar(
            metadata: IPTCMetadata(latitude: -33.8688, longitude: -70.6693), for: source)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let tracker = MetadataFailureTracker()
        let rendered = try await EditExportPipeline.renderItem(
            sourceURL: source, cameraRaw: nil, kind: .jpeg, outputFolder: outDir,
            folderURL: dir, writeEngine: SwiftExifWriteEngine(), failureTracker: tracker)
        #expect(await tracker.sidecarOverlayFailures.isEmpty)
        let meta = try await SwiftExifReadService().readFullMetadata(url: rendered)
        let lat = try #require(meta.latitude)
        let lon = try #require(meta.longitude)
        #expect(abs(lat - (-33.8688)) < 0.001)
        #expect(abs(lon - (-70.6693)) < 0.001)
    }

    @Test("Overlay fields add GPS additively without descriptive authority")
    func authoritativeFieldsIncludeGPS() {
        let gpsOnly = SidecarIPTCOverlay.authoritativeFields(from: IPTCMetadata(latitude: 59.9, longitude: -10.75))
        #expect(gpsOnly[.gpsLatitude] == "59.9")
        #expect(gpsOnly[.gpsLatitudeRef] == "N")
        #expect(gpsOnly[.gpsLongitudeRef] == "W")
        #expect(gpsOnly[.headline] == nil)
        #expect(SidecarIPTCOverlay.authoritativeFields(from: IPTCMetadata(rating: 3)) == [.rating: "3"])
    }

    // MARK: IIM into containers without IIM (finding 4)

    private func makeIIMJPEG(at url: URL, xmpDescription: String? = nil) throws {
        try writeJPEG(to: url)
        var metadata = try SwiftMediaMetadata.readMetadata(from: url)
        metadata.iptc.caption = "IIM caption"
        metadata.iptc.credit = "IIM Agency"
        metadata.iptc.copyright = "© IIM"
        metadata.iptc.keywords = ["alpha", "beta"]
        if let xmpDescription {
            var xmp = XMPData()
            xmp.description = xmpDescription
            metadata.xmp = xmp
        } else {
            metadata.xmp = nil
        }
        _ = try metadata.write(to: url)
    }

    @Test("IIM-only captions, credit, copyright and keywords survive a PNG export as XMP")
    func iimMirroredIntoPNGXMP() async throws {
        let dir = try makeFolder("iim-png")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("agency.jpg")
        try makeIIMJPEG(at: source)
        let reread = try SwiftMediaMetadata.readMetadata(from: source)
        try #require(reread.iptc.caption == "IIM caption")
        try #require(reread.xmp?.value(namespace: XMPNamespace.dc, property: "description") == nil)

        let output = dir.appendingPathComponent("agency.png")
        try writePNG(to: output)
        try await SwiftExifWriteEngine().copyMetadataToRenderedFile(from: source, to: output, bakedCameraRaw: nil)

        let xmp = try #require(try SwiftMediaMetadata.readMetadata(from: output).xmp)
        let parsed = XMPMetadataReader.parseMetadata(from: xmp, imageAspect: { nil })
        #expect(parsed.description == "IIM caption")
        #expect(parsed.credit == "IIM Agency")
        #expect(parsed.copyright == "© IIM")
        #expect(parsed.keywords == ["alpha", "beta"])
    }

    @Test("Mirroring IIM never overwrites a value the source XMP already carries")
    func iimMirrorPreservesExistingXMP() async throws {
        let dir = try makeFolder("iim-png-xmp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("agency.jpg")
        try makeIIMJPEG(at: source, xmpDescription: "XMP caption wins")
        let output = dir.appendingPathComponent("agency.png")
        try writePNG(to: output)
        try await SwiftExifWriteEngine().copyMetadataToRenderedFile(from: source, to: output, bakedCameraRaw: nil)

        let xmp = try #require(try SwiftMediaMetadata.readMetadata(from: output).xmp)
        let parsed = XMPMetadataReader.parseMetadata(from: xmp, imageAspect: { nil })
        #expect(parsed.description == "XMP caption wins")
        #expect(parsed.credit == "IIM Agency")
    }

    // MARK: Partial outputs (finding 6)

    @Test("A failed encode leaves no partial file under the reserved name")
    func discardOnFailureRemovesOwnedPartialOutput() async throws {
        let dir = try makeFolder("reservation-discard")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("photo.jpg")
        try writeJPEG(to: source)

        // Partial bytes written in place (FFmpeg `-y` truncates and writes the same inode).
        let owner = ExportOutputReservationOwner()
        let reserved = try owner.reserveOutput(for: source, in: dir, extension: "jxl", collisionPolicy: .appendNumber)
        let handle = try FileHandle(forWritingTo: reserved)
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 512))
        try handle.close()
        await owner.discardOnFailure()
        #expect(!FileManager.default.fileExists(atPath: reserved.path))

        // A pre-existing file claimed for replacement is never deleted.
        let existing = dir.appendingPathComponent("photo.avif")
        try Data("user file".utf8).write(to: existing)
        let replaceOwner = ExportOutputReservationOwner()
        let claimed = try replaceOwner.reserveOutput(for: source, in: dir, extension: "avif", collisionPolicy: .replaceExisting)
        #expect(claimed.lastPathComponent == existing.lastPathComponent)
        await replaceOwner.discardOnFailure()
        #expect(try Data(contentsOf: existing) == Data("user file".utf8))

        // A path whose identity changed after reservation is somebody else's file.
        let swapOwner = ExportOutputReservationOwner()
        let swapped = try swapOwner.reserveOutput(for: source, in: dir, extension: "tiff", collisionPolicy: .appendNumber)
        try FileManager.default.removeItem(at: swapped)
        try Data("replacement".utf8).write(to: swapped)
        await swapOwner.discardOnFailure()
        #expect(try Data(contentsOf: swapped) == Data("replacement".utf8))

        // The success path still keeps encoded pixels.
        let keepOwner = ExportOutputReservationOwner()
        let kept = try keepOwner.reserveOutput(for: source, in: dir, extension: "heic", collisionPolicy: .appendNumber)
        let keepHandle = try FileHandle(forWritingTo: kept)
        try keepHandle.write(contentsOf: Data("pixels".utf8))
        try keepHandle.close()
        await keepOwner.release()
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    // MARK: Sign cleanup and pane capture (finding 5, low)

    @Test("Sign discards a metadata-incomplete render and Export/Sign capture their pane")
    func signAndExportContentViewContracts() throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: workspace.appendingPathComponent("Aagedal Photo Agent/ContentView.swift"),
                                encoding: .utf8)
        for (startMarker, endMarker) in [
            ("private func renderAndSignSelectedAfterMetadataFlush(", "private func copyIPTCMetadata("),
            ("private func renderAndSaveEditedFolderAfterMetadataFlush(", "private func handleBrowserCommand("),
        ] {
            let start = try #require(source.range(of: startMarker))
            let end = try #require(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
            let functionSource = source[start.lowerBound..<end.lowerBound]
            let task = try #require(functionSource.range(of: "renderExportTask = Task {"))
            #expect(functionSource[..<task.lowerBound].contains("let browserViewModel = browserViewModel"))
            if startMarker.contains("Sign") {
                #expect(functionSource.contains("(error as? ExportMetadataIncompleteError)?.renderedURL"))
            }
        }
    }

    // MARK: FTP as-is uploads (finding 7)

    @Test("FTP detects sidecar metadata and rotation an as-is upload would otherwise lose")
    func ftpSidecarDifferenceDetection() {
        let embedded = IPTCMetadata(title: "Same", description: "Caption")
        #expect(!FTPUploadView.sidecarDiffersFromEmbedded(embedded: embedded,
            sidecar: IPTCMetadata(title: "Same", description: "Caption")))
        #expect(FTPUploadView.sidecarDiffersFromEmbedded(embedded: embedded,
            sidecar: IPTCMetadata(title: "Same", description: "New caption")))
        #expect(FTPUploadView.sidecarDiffersFromEmbedded(embedded: embedded,
            sidecar: IPTCMetadata(latitude: 59.9, longitude: 10.7)))
        #expect(FTPUploadView.sidecarDiffersFromEmbedded(embedded: embedded, sidecar: IPTCMetadata(rating: 4)))
        // A develop-only sidecar is not a descriptive record.
        var crs = CameraRawSettings()
        crs.exposure2012 = 1
        #expect(!FTPUploadView.sidecarDiffersFromEmbedded(embedded: embedded, sidecar: IPTCMetadata(cameraRaw: crs)))
        #expect(UploadFileInfo(isRaw: false, hasDevelop: false, hasCrop: false, hasSidecarRotation: true).hasAnyEdit)
    }

    @MainActor
    @Test("An as-is FTP upload sends a staged copy carrying the sidecar metadata; the original is untouched")
    func ftpAsIsUploadAppliesSidecarOverlayToCopy() async throws {
        let dir = try makeFolder("ftp-overlay")
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("photo.jpg")
        try writeJPEG(to: photo)
        let engine = SwiftExifWriteEngine()
        try await engine.writeFields([.headline: "Stale embedded headline"], to: [photo])
        let originalBytes = try Data(contentsOf: photo)
        try XMPSidecarService().saveSidecar(
            metadata: IPTCMetadata(title: "Sidecar headline", description: "Sidecar caption"), for: photo)

        let suite = "ExportSavingFTPOverlay.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = FTPOverlayUploadProbe()
        var execution = FTPUploadExecutionAccess()
        execution.password = { _ in "fixture-only" }
        execution.upload = { url, _, _, _ in
            let metadata = try await SwiftExifReadService().readFullMetadata(url: url)
            await probe.record(url: url, title: metadata.title, description: metadata.description)
            return FTPUploadOutcome()
        }
        execution.render = { _, _, _, _, _, _ in
            Issue.record("An as-is upload must not render")
            throw CocoaError(.fileWriteUnknown)
        }
        let model = FTPViewModel(fileSystem: FTPUploadFileSystemBoundary(temporaryRoot: dir),
                                 defaults: defaults, execution: execution)
        let connection = FTPConnection(name: "Isolated fixture", host: "fixture.invalid", port: 21, useTLS: true)
        let started = model.uploadFiles([photo], renderURLs: [], sidecarOverlayURLs: [photo], to: connection,
            readService: SwiftExifReadService(), writeEngine: engine, inMemoryCameraRaw: { _ in nil })
        #expect(started)
        await model.currentUploadCompletion()()

        let uploads = await probe.uploads
        let upload = try #require(uploads.first)
        #expect(uploads.count == 1)
        #expect(upload.url != photo)
        #expect(upload.url.lastPathComponent == "photo.jpg")
        #expect(upload.title == "Sidecar headline")
        #expect(upload.description == "Sidecar caption")
        #expect(try Data(contentsOf: photo) == originalBytes)
        #expect(model.errorMessages.isEmpty)
    }
}

@Suite("FTP as-is overlay never touches Content Credentials")
@MainActor
struct FTPCredentialedOverlayTests {
    @Test("Credentialed files are excluded from the overlay and their staged copy stays byte-identical")
    func credentialedFilesUploadSignedOriginal() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apa-ftp-c2pa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let signed = dir.appendingPathComponent("signed.jpg")
        let plain = dir.appendingPathComponent("plain.jpg")
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let jpeg = try #require(rep.representation(using: .jpeg, properties: [:]))
        try jpeg.write(to: signed); try jpeg.write(to: plain)
        for url in [signed, plain] {
            try XMPSidecarService().saveSidecar(metadata: IPTCMetadata(title: "Sidecar headline"), for: url)
        }

        let kept = await FTPUploadView.excludingCredentialed([signed, plain]) { $0 == signed }
        #expect(kept == [plain])

        // Backstop at the write: a credentialed source's staged copy is never rewritten.
        let staged = dir.appendingPathComponent("staged.jpg")
        try FileManager.default.copyItem(at: signed, to: staged)
        let before = try Data(contentsOf: staged)
        let refused = await FTPUploadExecutionAccess.applyAsIsOverlay(source: signed, staged: staged,
            engine: SwiftExifWriteEngine(), isCredentialed: { _ in true })
        #expect(refused == .noPendingEdits)
        #expect(try Data(contentsOf: staged) == before)

        let plainStaged = dir.appendingPathComponent("plain-staged.jpg")
        try FileManager.default.copyItem(at: plain, to: plainStaged)
        let applied = await FTPUploadExecutionAccess.applyAsIsOverlay(source: plain, staged: plainStaged,
            engine: SwiftExifWriteEngine(), isCredentialed: { _ in false })
        #expect(applied == .applied)
        #expect(try await SwiftExifReadService().readFullMetadata(url: plainStaged).title == "Sidecar headline")

        // An ordinary file reads as uncredentialed; an unreadable one is treated as credentialed.
        #expect(await !FTPUploadView.mayCarryC2PA(plain))
        #expect(await FTPUploadView.mayCarryC2PA(dir.appendingPathComponent("missing.jpg")))
    }

    @Test("Template reviews skip a RAW+JPEG pair's JPEG with a readable reason")
    func templateReviewSkipsPairedJPEG() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apa-template-pair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("IMG_2.Arw")
        let jpeg = dir.appendingPathComponent("IMG_2.jpg")
        let lone = dir.appendingPathComponent("IMG_3.jpg")
        for url in [raw, jpeg, lone] { try Data("x".utf8).write(to: url) }
        #expect(DevelopTemplateBatchCaptureService.pairedNonRawPhotos(in: [jpeg, lone, raw]) == [jpeg])
        let failure: any Error = DevelopTemplateBatchCaptureService.Failure.sharedRawSidecar
        #expect(failure.localizedDescription.contains("RAW+JPEG pair"))
        // Mixed-case RAW extensions are found too (case-sensitive volumes).
        #expect(PhotoSidecarOwnership.developOwningRawSibling(of: jpeg)?.lastPathComponent == "IMG_2.Arw")
    }
}

private actor FTPOverlayUploadProbe {
    struct Upload: Sendable { let url: URL; let title: String?; let description: String? }
    private(set) var uploads: [Upload] = []
    func record(url: URL, title: String?, description: String?) {
        uploads.append(Upload(url: url, title: title, description: description))
    }
}

/// A JPEG whose XMP packet is as large as the JPEG writer still accepts: any further metadata
/// (a rating, a caption) makes the XMP APP1 segment exceed 65,533 bytes.
enum NearLimitJPEGFixture {
    static func make(at url: URL) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let data = rep.representation(using: .jpeg, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
        let base = try SwiftMediaMetadata.readMetadata(from: url)
        func candidate(_ count: Int) -> ImageMetadata {
            var metadata = base
            var xmp = metadata.xmp ?? XMPData()
            xmp.setValue(.simple(String(repeating: "a", count: count)), namespace: XMPNamespace.xmp, property: "Nickname")
            metadata.xmp = xmp
            return metadata
        }
        var low = 1_000, high = 70_000
        while low < high {
            let mid = (low + high + 1) / 2
            let warnings = try candidate(mid).writeToDataWithWarnings().warnings
            if warnings.contains(where: EmbeddedMetadataLossRefusal.isLossWarning) { high = mid - 1 } else { low = mid }
        }
        _ = try candidate(low).write(to: url)
    }
}

@Suite("Embedded metadata loss refusals")
struct EmbeddedMetadataLossRefusalTests {
    private func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-loss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func plainJPEG(at url: URL) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let data = rep.representation(using: .jpeg, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    @Test("Refusal messages follow the segment kind and what the write was doing")
    func messagesDependOnContext() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        let drop = "Dropped oversized IPTC segment: 70000 bytes exceeds JPEG's 65533-byte per-segment limit."
        let descriptive = EmbeddedMetadataLossRefusal(imageURL: url, detail: drop).localizedDescription
        #expect(descriptive.contains("IPTC"))
        #expect(descriptive.contains("XMP sidecar"))
        #expect(descriptive.contains("nothing was lost"))
        #expect(!descriptive.contains("brush"))
        let develop = EmbeddedMetadataLossRefusal(imageURL: url, detail: drop, context: .develop).localizedDescription
        #expect(develop.contains("brush strokes"))
        let mismatch = EmbeddedMetadataLossRefusal(imageURL: url, detail: "x", isRoundTripMismatch: true).localizedDescription
        #expect(mismatch.contains("did not read back"))
        #expect(!mismatch.contains("too large"))
        let export = EmbeddedMetadataLossRefusal(imageURL: url, detail: drop, context: .export).localizedDescription
        #expect(export.contains("exported copy"))
    }

    @Test("Rating, label and list writes refuse a near-limit file without touching it and continue the batch")
    func directWritersRefuseAndContinue() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("a.jpg"), full = dir.appendingPathComponent("b.jpg"),
            last = dir.appendingPathComponent("c.jpg")
        try plainJPEG(at: first); try NearLimitJPEGFixture.make(at: full); try plainJPEG(at: last)
        let fullBytes = try Data(contentsOf: full)
        let engine = SwiftExifWriteEngine()

        do {
            try await engine.writeRating(.three, to: [first, full, last])
            Issue.record("The near-limit file must be refused")
        } catch let batch as EmbeddedMetadataBatchRefusal {
            #expect(batch.refusedURLs == [full])
        }
        #expect(try Data(contentsOf: full) == fullBytes)
        #expect(try SwiftMediaMetadata.readMetadata(from: first).xmp?.rating == 3)
        #expect(try SwiftMediaMetadata.readMetadata(from: last).xmp?.rating == 3)

        await #expect(throws: EmbeddedMetadataBatchRefusal.self) {
            try await engine.addRemoveListValues(add: [.subject: ["kw"]], remove: [:], to: [first, full, last])
        }
        #expect(try Data(contentsOf: full) == fullBytes)
        #expect(try await SwiftExifReadService().readFullMetadata(url: last).keywords == ["kw"])
        await #expect(throws: EmbeddedMetadataBatchRefusal.self) {
            try await engine.writeLabel(.red, to: [full])
        }
        #expect(try Data(contentsOf: full) == fullBytes)
    }

    @Test("A refused pending write reports that nothing may have been written")
    func pendingWriteRefusalIsNotMaybeWritten() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let full = dir.appendingPathComponent("full.jpg")
        try NearLimitJPEGFixture.make(at: full)
        let before = try Data(contentsOf: full)
        do {
            _ = try await SwiftExifWriteEngine().writePendingMetadata(
                IPTCMetadata(title: "Headline", description: String(repeating: "c", count: 500)), to: full,
                validatePreparedIntent: {})
            Issue.record("The oversized pending write must be refused")
        } catch let error as MetadataFieldMutationPhysicalError {
            #expect(error.mayHaveWritten == false)
            #expect(error.localizedDescription.contains("XMP sidecar"))
        }
        #expect(try Data(contentsOf: full) == before)
    }

    @Test("A field mutation on a near-limit file is refused before the file is touched")
    func fieldMutationRefusal() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let full = dir.appendingPathComponent("full.jpg")
        try NearLimitJPEGFixture.make(at: full)
        let before = try Data(contentsOf: full)
        do {
            _ = try await SwiftExifWriteEngine().writeFieldMutation(.rating(4), to: full, validatePreparedIntent: {})
            Issue.record("The oversized mutation must be refused")
        } catch let error as MetadataFieldMutationPhysicalError {
            #expect(error.mayHaveWritten == false)
        }
        #expect(try Data(contentsOf: full) == before)
    }

    @Test("The export copier refuses a metadata copy the JPEG can't hold instead of dropping it silently")
    func exportCopierRefusesOversizedCopy() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.jpg")
        try NearLimitJPEGFixture.make(at: source)
        // A large crs block pushes the copied XMP over the limit.
        let output = dir.appendingPathComponent("render.jpg")
        try plainJPEG(at: output)
        var baked = CameraRawSettings()
        baked.exposure2012 = 0.5
        baked.localAdjustments = [MaskAdjustment(name: "Brush",
            brush: BrushMaskGeometry(strokes: [BrushStroke(dabs: (0..<400).map {
                BrushDab(x: Double($0) / 400, y: 0.5, flow: 0.7, hardness: 0.4) }, radius: 0.02, density: 1, erase: false)]),
            exposure: 0.2)]
        do {
            try await SwiftExifWriteEngine().copyMetadataToRenderedFile(from: source, to: output, bakedCameraRaw: baked)
            Issue.record("The oversized copy must be refused")
        } catch let refusal as EmbeddedMetadataLossRefusal {
            #expect(refusal.context == .export)
        }
        // The rendered file itself is intact and readable.
        #expect(try SwiftMediaMetadata.readMetadata(from: output).format == .jpeg)
    }
}

@Suite("Round 6 export and RAW-sibling follow-ups")
struct ExportRoundSixTests {
    private func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-r6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func plainJPEG(at url: URL) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let data = rep.representation(using: .jpeg, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    private func setFolderModification(_ folder: URL, _ time: timespec) {
        var times = [time, time]
        _ = utimensat(AT_FDCWD, folder.path, &times, 0)
    }

    @Test("A write-path lookup never trusts an unsettled listing carried across our own sidecar write")
    func unsettledListingIsNotCarriedForWrites() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("IMG_5.jpg")
        try plainJPEG(at: jpeg)
        let index = PhotoRawStemIndex()
        // Listing taken right after the folder changed: unsettled.
        #expect(index.rawFile(forStem: "IMG_5", in: dir, allowsUnsettledReuse: false) == nil)
        let before = PhotoRawStemIndex.folderModification(dir)
        try Data("<x/>".utf8).write(to: dir.appendingPathComponent("IMG_5.xmp"))
        index.noteOwnWrite(in: dir, previousModification: before)
        let afterOwnWrite = try #require(PhotoRawStemIndex.folderModification(dir))
        // A RAW lands within the same timestamp tick (coarse-mtime volume simulation).
        try Data("raw".utf8).write(to: dir.appendingPathComponent("IMG_5.ARW"))
        setFolderModification(dir, afterOwnWrite)
        #expect(index.rawFile(forStem: "IMG_5", in: dir, allowsUnsettledReuse: false)?.lastPathComponent == "IMG_5.ARW")
    }

    @Test("A settled listing carried across our own write serves reads but not write-path decisions")
    func settledCarryIsReadOnly() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try plainJPEG(at: dir.appendingPathComponent("IMG_6.jpg"))
        let later = Date().addingTimeInterval(10)
        let index = PhotoRawStemIndex(now: { later })
        #expect(index.rawFile(forStem: "IMG_6", in: dir, allowsUnsettledReuse: false) == nil)  // settled listing
        let before = PhotoRawStemIndex.folderModification(dir)
        try Data("<x/>".utf8).write(to: dir.appendingPathComponent("IMG_6.xmp"))
        index.noteOwnWrite(in: dir, previousModification: before)
        let afterOwnWrite = try #require(PhotoRawStemIndex.folderModification(dir))
        try Data("raw".utf8).write(to: dir.appendingPathComponent("IMG_6.NEF"))
        setFolderModification(dir, afterOwnWrite)
        // Reads may reuse the carried listing; a write-path decision relists and sees the RAW.
        #expect(index.rawFile(forStem: "IMG_6", in: dir, allowsUnsettledReuse: true) == nil)
        #expect(index.rawFile(forStem: "IMG_6", in: dir, allowsUnsettledReuse: false)?.lastPathComponent == "IMG_6.NEF")
    }

    @Test("An export of a heavily brush-masked edit keeps EXIF, IPTC and caption and omits only the baked develop record")
    func exportDropsBakedDevelopBeforeDescriptive() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.jpg")
        try plainJPEG(at: source)
        let engine = SwiftExifWriteEngine()
        try await engine.writeFields([.description: "Kept caption", .credit: "Kept credit",
            .gpsLatitude: "59.9", .gpsLatitudeRef: "N", .gpsLongitude: "10.7", .gpsLongitudeRef: "E"], to: [source])
        let output = dir.appendingPathComponent("render.jpg")
        try plainJPEG(at: output)
        var baked = CameraRawSettings()
        baked.exposure2012 = 0.5
        baked.localAdjustments = [MaskAdjustment(name: "Heavy brush",
            brush: BrushMaskGeometry(strokes: [BrushStroke(dabs: (0..<6_000).map {
                BrushDab(x: Double($0 % 97) / 97 + 0.000123, y: Double($0 % 89) / 89, flow: 0.7, hardness: 0.4) },
                radius: 0.02, density: 1, erase: false)]),
            exposure: 0.2)]
        try await engine.copyMetadataToRenderedFile(from: source, to: output, bakedCameraRaw: baked)
        let written = try SwiftMediaMetadata.readMetadata(from: output)
        let xmp = try #require(written.xmp)
        #expect(xmp.properties(in: XMPNamespace.crs).isEmpty)
        #expect(written.iptc.caption == "Kept caption")
        let meta = try await SwiftExifReadService().readFullMetadata(url: output)
        #expect(meta.description == "Kept caption")
        #expect(meta.credit == "Kept credit")
        #expect(meta.latitude != nil)
    }
}

// MARK: - Redaction fail-closed rendering

@Suite("Redactions reach every rendition or the render is refused")
struct RedactionFailClosedTests {

    private func makeFolder(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("apa-redact-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func imageData(_ type: NSBitmapImageRep.FileType, size: Int = 32) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw CocoaError(.fileWriteUnknown) }
        for y in 0..<size {
            for x in 0..<size {
                let white = ((x / 2) + (y / 2)) % 2 == 0
                rep.setColor(white ? .white : .black, atX: x, y: y)
            }
        }
        guard let data = rep.representation(using: type, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private func faceMask(id: UUID = UUID(), centerX: Double = 0.5, amount: Double = 90) -> MaskAdjustment {
        var mask = MaskAdjustment(name: "Face", anonymizer: AnonymizerSettings(amount: amount, blackOut: nil))
        mask.id = id
        mask.geometry = EllipseMaskGeometry(centerX: centerX, centerY: 0.5, radiusX: 0.2, radiusY: 0.2,
                                            rotation: 0, feather: 0)
        return mask
    }

    private func redacted() -> CameraRawSettings {
        var settings = CameraRawSettings()
        settings.exposure2012 = 0.2
        settings.localAdjustments = [faceMask()]
        return settings
    }

    private func visibleFiles(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    // MARK: Finding 1 — GPU failure

    @Test("The CIFilter fallback may stand in only for settings it can reproduce")
    func fallbackReproducibility() {
        var global = CameraRawSettings()
        global.exposure2012 = 0.5
        #expect(CameraRawApproximation.fallbackCanReproduce(global))
        #expect(!CameraRawApproximation.fallbackCanReproduce(redacted()))
        var globalAnonymizer = global
        globalAnonymizer.anonymizer = AnonymizerSettings(amount: 40, blackOut: nil)
        #expect(!CameraRawApproximation.fallbackCanReproduce(globalAnonymizer))
        var ordinaryMask = global
        ordinaryMask.localAdjustments = [MaskAdjustment(name: "Sky", exposure: -0.5)]
        #expect(!CameraRawApproximation.fallbackCanReproduce(ordinaryMask))
        var disabledMask = ordinaryMask
        disabledMask.localAdjustments?[0].enabled = false
        #expect(CameraRawApproximation.fallbackCanReproduce(disabledMask))
        var watermark = global
        watermark.watermarkLayers = [WatermarkLayer(libraryAssetID: UUID())]
        #expect(!CameraRawApproximation.fallbackCanReproduce(watermark))
    }

    @Test("A preview of redacted settings shows a placeholder, never the source, when the GPU fails")
    func previewPlaceholderOnGPUFailure() async throws {
        let input = try #require(CIImage(data: try imageData(.png)))
        let settings = redacted()
        let sync = GPURenderFaultInjection.$forceFailure.withValue(true) {
            CameraRawApproximation.applyWithCrop(to: input, settings: settings)
        }
        let asyncOutput = await GPURenderFaultInjection.$forceFailure.withValue(true) {
            await CameraRawApproximation.applyWithCropAsync(to: input, settings: settings)
        }
        for output in [sync, asyncOutput] {
            #expect(output.extent == input.extent)
            var px: [Float] = [0, 0, 0, 0]
            let maxOut = output.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: input.extent)])
            CameraRawApproximation.ciContext.render(maxOut, toBitmap: &px, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                colorSpace: CameraRawApproximation.workingColorSpace)
            // The checkerboard source has white pixels; the uniform grey placeholder doesn't.
            #expect(px[0] < 0.9 && px[1] < 0.9 && px[2] < 0.9, "\(px)")
        }
        #expect(throws: EditRenderRefusedError.self) {
            try GPURenderFaultInjection.$forceFailure.withValue(true) {
                try CameraRawApproximation.applyWithCropForOutput(to: input, settings: settings)
            }
        }
    }

    @MainActor
    @Test("A GPU render failure refuses the export of a redacted photo and writes nothing",
          arguments: [0, 1, 2])
    func gpuFailureRefusesRedactedExport(kindIndex: Int) async throws {
        let dir = try makeFolder("gpu-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("photo.jpg")
        try imageData(.jpeg).write(to: source)
        let output = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let kind: RenderKind = [RenderKind.jpeg, .saveAs(.png), .saveAs(.jpeg)][kindIndex]
        let settings = redacted()

        var refusal: (any Error)?
        do {
            _ = try await GPURenderFaultInjection.$forceFailure.withValue(true) {
                try await EditExportPipeline.renderItem(
                    sourceURL: source, cameraRaw: settings, kind: kind, outputFolder: output,
                    folderURL: dir, writeEngine: SwiftExifWriteEngine(),
                    failureTracker: MetadataFailureTracker(),
                    savedRedactionAccess: ExportSavedRedactionAccess { _ in [] })
            }
        } catch {
            refusal = error
        }
        let refused = try #require(refusal as? EditRenderRefusedError)
        #expect(refused.hasRedaction)
        #expect(refused.errorDescription?.contains("the photo has redactions, so it wasn't exported") == true)
        #expect(visibleFiles(in: output).isEmpty, "\(visibleFiles(in: output))")
    }

    @MainActor
    @Test("A GPU render failure still exports global-only edits through the fallback")
    func gpuFailureKeepsGlobalOnlyExport() async throws {
        let dir = try makeFolder("gpu-fail-global")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("photo.jpg")
        try imageData(.jpeg).write(to: source)
        let output = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var settings = CameraRawSettings()
        settings.exposure2012 = 0.5
        let rendered = try await GPURenderFaultInjection.$forceFailure.withValue(true) {
            try await EditExportPipeline.renderItem(
                sourceURL: source, cameraRaw: settings, kind: .jpeg, outputFolder: output,
                folderURL: dir, writeEngine: SwiftExifWriteEngine(),
                failureTracker: MetadataFailureTracker())
        }
        #expect(FileManager.default.fileExists(atPath: rendered.path))
    }

    // MARK: Finding 3 — merging copies only adds redactions

    @Test("Reconciling sidecar and embedded develop combines redaction masks and keeps the strongest global Anonymizer")
    func reconciliationUnionsRedactions() {
        let maskA = faceMask(centerX: 0.3)
        let maskB = faceMask(centerX: 0.7)

        var embedded = CameraRawSettings()
        embedded.localAdjustments = [maskA]
        var sidecar = CameraRawSettings()
        sidecar.exposure2012 = 0.4
        sidecar.localAdjustments = [maskA, maskB]
        let both = EffectiveMetadataResolver.reconciledDevelopSettings(sidecar: sidecar, embedded: embedded)
        #expect(Set(RedactionUnion.redactionMasks(in: both).map(\.id)) == [maskA.id, maskB.id])
        #expect(both?.localAdjustments?.count == 2)

        // The embedded copy has a redaction the sidecar's (non-empty) mask list lacks.
        var sidecarB = CameraRawSettings()
        sidecarB.localAdjustments = [maskB]
        let combined = EffectiveMetadataResolver.reconciledDevelopSettings(sidecar: sidecarB, embedded: embedded)
        #expect(Set(RedactionUnion.redactionMasks(in: combined).map(\.id)) == [maskA.id, maskB.id])

        // The same face re-created under another identity is not duplicated.
        var sameRegion = embedded
        sameRegion.localAdjustments = [faceMask(centerX: 0.3)]
        let deduped = EffectiveMetadataResolver.reconciledDevelopSettings(sidecar: sidecar, embedded: sameRegion)
        #expect(deduped?.localAdjustments?.count == 2)

        // An embedded global Anonymizer survives a sidecar with develop settings.
        var embeddedGlobal = CameraRawSettings()
        embeddedGlobal.anonymizer = AnonymizerSettings(amount: 60, blackOut: nil)
        var sidecarDevelop = CameraRawSettings()
        sidecarDevelop.exposure2012 = 0.8
        let global = EffectiveMetadataResolver.reconciledDevelopSettings(sidecar: sidecarDevelop, embedded: embeddedGlobal)
        #expect(global?.anonymizer == AnonymizerSettings(amount: 60, blackOut: nil))
        #expect(global?.exposure2012 == 0.8)
        var weaker = sidecarDevelop
        weaker.anonymizer = AnonymizerSettings(amount: 20, blackOut: nil)
        #expect(EffectiveMetadataResolver.reconciledDevelopSettings(sidecar: weaker, embedded: embeddedGlobal)?
            .anonymizer == AnonymizerSettings(amount: 60, blackOut: nil))
    }

    @Test("The export source policy combines partial redaction sets of both copies")
    func exportPolicyUnionsPartialRedactions() {
        let maskA = faceMask(centerX: 0.3)
        let maskB = faceMask(centerX: 0.7)
        var live = CameraRawSettings()
        live.exposure2012 = 1.0
        live.localAdjustments = [maskA]
        var persisted = CameraRawSettings()
        persisted.exposure2012 = 0.2
        persisted.localAdjustments = [maskB]
        persisted.anonymizer = AnonymizerSettings(amount: nil, blackOut: true)

        for authoritative in [false, true] {
            let resolved = ExportCameraRawSourcePolicy.resolve(
                live: live, persisted: persisted, liveIsAuthoritative: authoritative)
            #expect(Set(RedactionUnion.redactionMasks(in: resolved).map(\.id)) == [maskA.id, maskB.id])
            #expect(resolved?.anonymizer?.blackOut == true)
            #expect(resolved?.exposure2012 == (authoritative ? 1.0 : 0.2))
            #expect(RedactionUnion.covers(render: resolved, saved: [live, persisted]))
        }

        // A redaction disabled in the preferred copy but enabled in the other is re-enabled.
        var disabled = persisted
        disabled.localAdjustments?[0].enabled = false
        var liveB = CameraRawSettings()
        liveB.localAdjustments = [maskB]
        let reenabled = ExportCameraRawSourcePolicy.resolve(live: liveB, persisted: disabled, liveIsAuthoritative: false)
        #expect(reenabled?.localAdjustments?.count == 1)
        #expect(reenabled?.localAdjustments?.first?.enabled == true)
    }

    @Test("Merged redactions stay within the renderer's mask limit")
    func unionKeepsRedactionsRenderable() {
        var base = CameraRawSettings()
        base.localAdjustments = (0..<DevelopLayerLimits.maxEnabledMasks).map {
            MaskAdjustment(name: "Adjust \($0)", exposure: 0.1)
        }
        var other = CameraRawSettings()
        other.localAdjustments = [faceMask()]
        let merged = RedactionUnion.merged(base, adding: [other])
        #expect(!RedactionUnion.redactionsExceedRenderLimit(merged))
        #expect(RedactionUnion.covers(render: merged, saved: [other]))
        #expect(merged.localAdjustments?.filter(\.enabled).count == DevelopLayerLimits.maxEnabledMasks)
    }

    @Test("The coverage check fails for a missing mask or global Anonymizer")
    func coverageCheck() {
        let saved = redacted()
        var stale = CameraRawSettings()
        stale.exposure2012 = 0.2
        #expect(!RedactionUnion.covers(render: stale, saved: [saved]))
        #expect(!RedactionUnion.covers(render: nil, saved: [saved]))
        #expect(RedactionUnion.covers(render: saved, saved: [saved, nil]))
        var global = CameraRawSettings()
        global.anonymizer = AnonymizerSettings(amount: 30, blackOut: nil)
        #expect(!RedactionUnion.covers(render: saved, saved: [global]))
        #expect(RedactionUnion.covers(render: stale, saved: [stale, nil]))
    }

    @MainActor
    @Test("renderItem refuses when the render settings lack a redaction saved in the photo's sidecar")
    func renderItemRefusesMissingSavedRedaction() async throws {
        let dir = try makeFolder("missing-saved")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("photo.jpg")
        try imageData(.jpeg).write(to: source)
        try XMPSidecarService().saveSidecar(
            metadata: IPTCMetadata(title: "Caption", cameraRaw: redacted()), for: source)
        let output = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var stale = CameraRawSettings()
        stale.exposure2012 = 0.2

        await #expect(throws: RedactionMissingFromRenderError.self) {
            _ = try await EditExportPipeline.renderItem(
                sourceURL: source, cameraRaw: stale, kind: .format, outputFolder: output,
                folderURL: dir, writeEngine: SwiftExifWriteEngine(),
                failureTracker: MetadataFailureTracker())
        }
        await #expect(throws: RedactionMissingFromRenderError.self) {
            _ = try await EditExportPipeline.renderItem(
                sourceURL: source, cameraRaw: nil, kind: .saveAs(.jpeg), outputFolder: output,
                folderURL: dir, writeEngine: SwiftExifWriteEngine(),
                failureTracker: MetadataFailureTracker())
        }
        #expect(visibleFiles(in: output).isEmpty, "\(visibleFiles(in: output))")
    }

    // MARK: Finding 2 — source blobs

    private static let blobTags: [UInt16] = [0xCD41, 0x935C, 0xC634, 0x7200, 0xC68B]

    /// A TIFF source with descriptive EXIF/GPS (written by ImageIO) plus fake source blobs in
    /// IFD0 (camera C2PA manifest, Photoshop layers, DNG private data, Sony SR2, original raw
    /// data) and XMP thumbnails / face regions.
    private func makeBlobbySourceTIFF(at url: URL) throws {
        let png = try imageData(.png)
        guard let imageSource = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "TestCam",
                kCGImagePropertyTIFFModel: "Model X",
                kCGImagePropertyTIFFDateTime: "2026:10:24 12:00:00",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifDateTimeOriginal: "2026:10:24 12:00:00",
                kCGImagePropertyExifLensModel: "Test Lens 50mm",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 59.91,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 10.75,
                kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }

        var metadata = try SwiftMediaMetadata.readMetadata(from: url)
        var exif = try #require(metadata.exif)
        var entries = exif.ifd0?.entries ?? []
        for tag in Self.blobTags {
            let payload = Data(repeating: UInt8(tag & 0xFF), count: 8_192)
            entries.append(IFDEntry(tag: tag, type: .undefined, count: UInt32(payload.count), valueData: payload))
        }
        exif.ifd0 = IFD(entries: entries.sorted { $0.tag < $1.tag })
        metadata.exif = exif
        var xmp = metadata.xmp ?? XMPData()
        xmp.description = "Kept caption"
        xmp.setValue(.simple("base64-thumbnail-of-the-original"), namespace: XMPNamespace.xmp, property: "Thumbnails")
        xmp.setValue(.simple("face-region"), namespace: XMPNamespace.mwgRegions, property: "Regions")
        metadata.xmp = xmp
        _ = try metadata.write(to: url)
    }

    @Test("Camera C2PA, Photoshop/DNG blobs and XMP thumbnails never reach a TIFF or PNG rendition; descriptive EXIF does",
          arguments: ["tiff", "png"])
    func sourceBlobsStripped(format: String) async throws {
        let dir = try makeFolder("blobs-\(format)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("camera.tif")
        try makeBlobbySourceTIFF(at: source)
        let sourceIFD0 = try #require(try SwiftMediaMetadata.readMetadata(from: source).exif?.ifd0)
        for tag in Self.blobTags {
            try #require(sourceIFD0.hasEntry(for: tag), "fixture lacks tag \(String(tag, radix: 16))")
        }

        let output = dir.appendingPathComponent("rendered.\(format)")
        try imageData(format == "png" ? .png : .tiff).write(to: output)
        var baked = redacted()
        baked.localAdjustments = [faceMask()]
        try await SwiftExifWriteEngine().copyMetadataToRenderedFile(from: source, to: output, bakedCameraRaw: baked)

        let written = try ImageMetadata.read(from: output)
        let ifd0 = written.exif?.ifd0
        for tag in Self.blobTags {
            #expect(ifd0?.hasEntry(for: tag) != true, "tag \(String(tag, radix: 16)) survived")
        }
        #expect(written.c2pa == nil)
        #expect(written.xmp?.value(namespace: XMPNamespace.xmp, property: "Thumbnails") == nil)
        #expect(written.xmp?.value(namespace: XMPNamespace.mwgRegions, property: "Regions") == nil)

        #expect(written.exif?.make == "TestCam")
        #expect(written.exif?.model == "Model X")
        #expect(written.exif?.exposureTime != nil)
        #expect(written.exif?.dateTimeOriginal == "2026:10:24 12:00:00")
        #expect(written.exif?.gpsIFD?.hasEntry(for: 0x0002) == true)
        let meta = try await SwiftExifReadService().readFullMetadata(url: output)
        #expect(meta.description == "Kept caption")
        #expect(meta.latitude != nil)
    }

    @Test("A Photoshop IRB, maker note and JPEG thumbnail offsets in a source IFD0 are dropped")
    func photoshopAndMakerNoteStripped() {
        var exif = ExifData(byteOrder: .bigEndian)
        let blob = Data(repeating: 0xAB, count: 64)
        exif.ifd0 = IFD(entries: [
            IFDEntry(tag: 0x010F, type: .ascii, count: 8, valueData: Data("TestCam\0".utf8)),
            IFDEntry(tag: 0x0201, type: .long, count: 1, valueData: Data([0, 0, 0, 8])),
            IFDEntry(tag: 0x0202, type: .long, count: 1, valueData: Data([0, 0, 0, 64])),
            IFDEntry(tag: 0x014A, type: .long, count: 1, valueData: Data([0, 0, 0, 8])),
            IFDEntry(tag: 0x02BC, type: .undefined, count: UInt32(blob.count), valueData: blob),
            IFDEntry(tag: 0x8298, type: .ascii, count: 3, valueData: Data("C\0\0".utf8)),
            IFDEntry(tag: 0x8649, type: .undefined, count: UInt32(blob.count), valueData: blob),
        ])
        exif.exifIFD = IFD(entries: [
            IFDEntry(tag: 0x829A, type: .rational, count: 1, valueData: Data([0, 0, 0, 1, 0, 0, 0, 250])),
            IFDEntry(tag: 0x927C, type: .undefined, count: UInt32(blob.count), valueData: blob),
        ])
        var metadata = ImageMetadata(exif: exif)
        SwiftExifWriteEngine.stripSourceBlobsForRendition(&metadata, renderRedacts: false)
        #expect(metadata.exif?.ifd0?.entries.map(\.tag) == [0x010F, 0x8298])
        #expect(metadata.exif?.exifIFD?.hasEntry(for: 0x927C) == true, "an unredacted render keeps its maker note")
        SwiftExifWriteEngine.stripSourceBlobsForRendition(&metadata, renderRedacts: true)
        #expect(metadata.exif?.exifIFD?.hasEntry(for: 0x927C) == false)
        #expect(metadata.exif?.exifIFD?.hasEntry(for: 0x829A) == true)
    }
}
