import Testing
import Foundation
import AppKit
import SwiftExif
@testable import Aagedal_Photo_Agent

/// End-to-end concurrency tests that drive the real write engine, read service,
/// and shared `MetadataIOCoordinator` against an actual image file on disk.
///
/// The coordinator-primitive tests in `MetadataIOCoordinatorTests` prove the lock
/// serializes correctly in isolation. These tests close the loop: they confirm
/// that `SwiftExifWriteEngine` and `SwiftExifReadService` are actually wired to
/// that lock, so concurrent reads and writes to the same photo never corrupt the
/// file, never observe a half-written state, and never lose an update.
@Suite("Metadata engine + coordinator integration (real file)")
struct MetadataEngineConcurrencyTests {

    /// Write a minimal, valid baseline JPEG to a unique temp URL.
    /// Generated in-process so no binary fixture needs to live in the repo.
    private func makeTempJPEG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-metadata-race-\(UUID().uuidString).jpg")
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let data = rep.representation(using: .jpeg, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
        return url
    }

    /// Sanity baseline: a sequential write-then-read roundtrips through the real
    /// file, so any failure in the concurrent tests below points at concurrency,
    /// not at the fixture or the basic I/O path.
    @Test("sequential write then read roundtrips rating and title")
    func sequentialRoundtrip() async throws {
        let engine = SwiftExifWriteEngine()
        let reader = SwiftExifReadService()
        let url = try makeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        try await engine.writeRating(.five, to: [url])
        try await engine.writeFields([.headline: "Hello"], to: [url])

        let meta = try await reader.readFullMetadata(url: url)
        #expect(meta.rating == 5)
        #expect(meta.title == "Hello")
    }

    /// Radial-mask regression: a mask written by the engine must read back with
    /// its authored geometry and local adjustments. SwiftExif returns structured
    /// XMP fields under namespace-URI-prefixed keys; the parser used to miss
    /// every one of them and silently fall back to the default ellipse, so a
    /// mask "went generic" the moment the edit view was reopened.
    @Test("radial mask roundtrips geometry and local adjustments through write then read")
    func maskRoundtrip() async throws {
        let engine = SwiftExifWriteEngine()
        let reader = SwiftExifReadService()
        let url = try makeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        var geometry = EllipseMaskGeometry()
        geometry.centerX = 0.6
        geometry.centerY = 0.4
        geometry.radiusX = 0.25
        geometry.radiusY = 0.1
        geometry.rotation = 30
        geometry.feather = 35
        var mask = MaskAdjustment(name: "Face", geometry: geometry)
        mask.inverted = true
        mask.amount = 1.0
        mask.exposure = 1.0
        mask.contrast = 25

        try await engine.writeFields(
            [:], to: [url],
            structuredData: StructuredWriteData(toneCurve: nil, masks: [mask])
        )

        let meta = try await reader.readFullMetadata(url: url)
        let read = try #require(meta.cameraRaw?.localAdjustments?.first)
        #expect(read.name == "Face")
        #expect(read.inverted == true)
        #expect(abs(read.geometry.centerX - 0.6) < 1e-5)
        #expect(abs(read.geometry.centerY - 0.4) < 1e-5)
        #expect(abs(read.geometry.radiusX - 0.25) < 1e-5)
        #expect(abs(read.geometry.radiusY - 0.1) < 1e-5)
        #expect(abs(read.geometry.rotation - 30) < 1e-5)
        #expect(abs(read.geometry.feather - 35) < 1e-5)
        #expect(read.exposure.map { abs($0 - 1.0) < 1e-5 } == true)
        #expect(read.contrast == 25)
    }

    /// Adobe-faithful crs block replacement: a full develop save replaces the
    /// file's ENTIRE crs namespace with the write's live state, dropping
    /// settings the app doesn't model (ACR's Texture, vignette, …) so ACR
    /// can't re-apply them on top of our render — while a partial crs write
    /// (develop-settings paste) keeps preserving what it doesn't carry.
    @Test("full develop save replaces the crs block; partial writes preserve unmanaged settings")
    func crsBlockReplacement() async throws {
        let engine = SwiftExifWriteEngine()
        let url = try makeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }
        let crs = "http://ns.adobe.com/camera-raw-settings/1.0/"

        // Plant settings the app doesn't model, as an ACR session would have.
        var planted = try SwiftExif.readMetadata(from: url)
        if planted.xmp == nil { planted.xmp = XMPData() }
        planted.xmp?.setValue(.simple("+40"), namespace: crs, property: "Texture")
        planted.xmp?.setValue(.simple("-30"), namespace: crs, property: "PostCropVignetteAmount")
        try planted.write(to: url)

        // Partial crs write (paste semantics): unmanaged settings survive.
        try await engine.writeFields([.crsExposure2012: "+0.50"], to: [url])
        var meta = try SwiftExif.readMetadata(from: url)
        #expect(meta.xmp?.simpleValue(namespace: crs, property: "Texture") == "+40")
        #expect(meta.xmp?.simpleValue(namespace: crs, property: "Exposure2012") == "+0.50")

        // Full develop save: block replaced, unmanaged settings dropped, ours
        // land, and the edited markers are stamped even with no masks present.
        try await engine.writeFields(
            [.crsExposure2012: "+0.75", .crsHasSettings: "True"],
            to: [url],
            structuredData: StructuredWriteData(replaceCameraRawBlock: true)
        )
        meta = try SwiftExif.readMetadata(from: url)
        #expect(meta.xmp?.simpleValue(namespace: crs, property: "Texture") == nil)
        #expect(meta.xmp?.simpleValue(namespace: crs, property: "PostCropVignetteAmount") == nil)
        #expect(meta.xmp?.simpleValue(namespace: crs, property: "Exposure2012") == "+0.75")
        #expect(meta.xmp?.simpleValue(namespace: crs, property: "AlreadyApplied") == "False")
        #expect(meta.xmp?.simpleValue(namespace: crs, property: "CompatibleVersion") == "234881024")

        // Replacement flag without any crs content in the write (caption-only
        // save of a file whose crs block we couldn't model) must not wipe it.
        try await engine.writeFields(
            [.headline: "Hello"], to: [url],
            structuredData: StructuredWriteData(replaceCameraRawBlock: true)
        )
        meta = try SwiftExif.readMetadata(from: url)
        #expect(meta.xmp?.simpleValue(namespace: crs, property: "Exposure2012") == "+0.75")
    }

    /// GPS regression: callers split a signed coordinate into a positive magnitude
    /// (`.gpsLatitude`/`.gpsLongitude`) plus a hemisphere ref (`.gpsLatitudeRef`/
    /// `.gpsLongitudeRef`), exactly as `IPTCMetadata.toWriteFields()` does. The write
    /// engine must re-apply that ref before handing the value to `setGPS` (which
    /// derives the hemisphere from the sign). Without it, southern/western coordinates
    /// — i.e. anywhere in the Americas — get written flipped to N/E.
    @Test("southern/western GPS preserves its hemisphere through write then read")
    func southernWesternGPSRoundtrips() async throws {
        let engine = SwiftExifWriteEngine()
        let reader = SwiftExifReadService()
        let url = try makeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        // Santiago, Chile: latitude S, longitude W.
        try await engine.writeFields([
            .gpsLatitude: "33.865", .gpsLatitudeRef: "S",
            .gpsLongitude: "70.649", .gpsLongitudeRef: "W"
        ], to: [url])

        let meta = try await reader.readFullMetadata(url: url)
        let lat = try #require(meta.latitude)
        let lon = try #require(meta.longitude)
        #expect(abs(lat - (-33.865)) < 0.001)
        #expect(abs(lon - (-70.649)) < 0.001)
    }

    /// The northern/eastern path must not be over-corrected by the ref handling.
    @Test("northern/eastern GPS stays positive through write then read")
    func northernEasternGPSRoundtrips() async throws {
        let engine = SwiftExifWriteEngine()
        let reader = SwiftExifReadService()
        let url = try makeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        // Oslo, Norway: latitude N, longitude E.
        try await engine.writeFields([
            .gpsLatitude: "59.913", .gpsLatitudeRef: "N",
            .gpsLongitude: "10.752", .gpsLongitudeRef: "E"
        ], to: [url])

        let meta = try await reader.readFullMetadata(url: url)
        let lat = try #require(meta.latitude)
        let lon = try #require(meta.longitude)
        #expect(abs(lat - 59.913) < 0.001)
        #expect(abs(lon - 10.752) < 0.001)
    }

    /// The core end-to-end guarantee: a rating write and a field write fired
    /// concurrently at the same photo must BOTH survive. Each is a read-modify-
    /// write cycle over the file's metadata; without per-photo serialization the
    /// two cycles read the same baseline and the second writer clobbers the
    /// first, dropping one of the two updates. Looping makes such a regression
    /// fail reliably rather than only on an unlucky interleaving.
    @Test("concurrent rating + field writes on the same file never clobber each other")
    func concurrentWritesDoNotClobber() async throws {
        let engine = SwiftExifWriteEngine()
        let reader = SwiftExifReadService()

        for _ in 0..<25 {
            let url = try makeTempJPEG()
            defer { try? FileManager.default.removeItem(at: url) }

            async let rating: Void = engine.writeRating(.five, to: [url])
            async let fields: Void = engine.writeFields([.headline: "Hello"], to: [url])
            _ = try await (rating, fields)

            let meta = try await reader.readFullMetadata(url: url)
            #expect(meta.rating == 5)
            #expect(meta.title == "Hello")
        }
    }

    /// Stress: many concurrent writers (ratings + headlines from a known set) and
    /// readers against one file. Every read must observe either a committed value
    /// from the known set or an empty/initial value — never a torn or garbage
    /// string — which is only possible if reads are serialized against writes.
    /// The file must also remain parseable after the storm.
    @Test("concurrent reads and writes never yield torn reads or corruption")
    func concurrentReadsAndWritesStayConsistent() async throws {
        let engine = SwiftExifWriteEngine()
        let reader = SwiftExifReadService()
        let url = try makeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        let titles = ["Alpha", "Bravo", "Charlie", "Delta"]
        let knownTitles = Set(titles)

        try await withThrowingTaskGroup(of: String?.self) { group in
            for i in 0..<20 {
                let rating = StarRating(rawValue: i % 6) ?? .none
                group.addTask {
                    try await engine.writeRating(rating, to: [url])
                    return nil
                }
            }
            for i in 0..<20 {
                let title = titles[i % titles.count]
                group.addTask {
                    try await engine.writeFields([.headline: title], to: [url])
                    return nil
                }
            }
            for _ in 0..<40 {
                group.addTask {
                    try await reader.readFullMetadata(url: url).title
                }
            }

            for try await title in group {
                if let title, !title.isEmpty {
                    #expect(knownTitles.contains(title))
                }
            }
        }

        // The file survived the storm: a final read parses and reflects a
        // committed value, never a half-written one.
        let surviving = try await reader.readFullMetadata(url: url).title
        if let surviving, !surviving.isEmpty {
            #expect(knownTitles.contains(surviving))
        }

        // And a deterministic write issued after the storm is the observed state.
        try await engine.writeRating(.four, to: [url])
        try await engine.writeFields([.headline: "Final"], to: [url])
        let final = try await reader.readFullMetadata(url: url)
        #expect(final.rating == 4)
        #expect(final.title == "Final")
    }
}

/// End-to-end XMP-sidecar coverage for the ACR crop-convention conversion: the
/// .xmp on disk must hold Adobe's un-rotated-frame corner encoding (so ACR/LR
/// render the same crop), while the app reads back its own upright-rect values.
@MainActor
@Suite("XMP sidecar angled-crop ACR conversion (real file)")
struct XMPSidecarAngledCropTests {

    /// 3:2 JPEG so the aspect-dependent conversion is exercised for real.
    private func makeTempJPEG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-sidecar-crop-\(UUID().uuidString).jpg")
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 30, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let data = rep.representation(using: .jpeg, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
        return url
    }

    @Test("angled crop is stored in Adobe's corner convention and roundtrips back")
    func angledCropSidecarRoundtrip() throws {
        let service = XMPSidecarService()
        let url = try makeTempJPEG()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: service.sidecarURL(for: url))
        }

        let internalCrop = CameraRawCrop(
            top: 0.2, left: 0.15, bottom: 0.8, right: 0.7,
            angle: -12.5, hasCrop: true
        )
        var settings = CameraRawSettings()
        settings.hasSettings = true
        settings.crop = internalCrop
        try service.saveCameraRawOnly(settings, orientation: 1, for: url)

        // On disk: Adobe's encoding (the upright rect's diagonal rotated back
        // into the original frame), not the app's verbatim values.
        let xml = try String(contentsOf: service.sidecarURL(for: url), encoding: .utf8)
        func storedValue(_ name: String) throws -> Double {
            let pattern = "crs:\(name)(?:=\"|>)(-?[0-9.]+)"
            let match = try #require(xml.range(of: pattern, options: .regularExpression))
            let raw = xml[match].split(separator: "\"").last ?? xml[match].split(separator: ">").last ?? ""
            return try #require(Double(raw))
        }
        let expected = internalCrop.encodedForACR(aspect: 1.5)
        #expect(abs(try storedValue("CropLeft") - expected.left!) < 1e-5)
        #expect(abs(try storedValue("CropTop") - expected.top!) < 1e-5)
        #expect(abs(try storedValue("CropRight") - expected.right!) < 1e-5)
        #expect(abs(try storedValue("CropBottom") - expected.bottom!) < 1e-5)
        // And the encoding really differs from the internal rect at this angle.
        #expect(abs(expected.left! - internalCrop.left!) > 1e-3)

        // Read back: decoded to the app's upright-rect convention.
        let loaded = try #require(service.loadSidecar(for: url)?.cameraRaw?.crop)
        #expect(abs(loaded.top! - internalCrop.top!) < 1e-4)
        #expect(abs(loaded.left! - internalCrop.left!) < 1e-4)
        #expect(abs(loaded.bottom! - internalCrop.bottom!) < 1e-4)
        #expect(abs(loaded.right! - internalCrop.right!) < 1e-4)
        #expect(abs((loaded.angle ?? 0) - (-12.5)) < 1e-6)
    }
}
