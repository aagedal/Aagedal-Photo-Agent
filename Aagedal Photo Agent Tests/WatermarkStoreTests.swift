import Testing
import Foundation
import AppKit
@testable import Aagedal_Photo_Agent

/// Tests for the per-item-folder library store in `WatermarkStore`.
///
/// The service is a `@MainActor` singleton, so the suite is `@MainActor` and `.serialized`
/// — each test points the singleton at a fresh temp directory via the `storageOverrideURL`
/// test seam and resets it afterward, so shared state never leaks between tests.
@Suite("WatermarkStore", .serialized)
@MainActor
struct WatermarkStoreTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatermarkStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func activate(_ dir: URL) {
        WatermarkStore.deletionIO = .live
        WatermarkStore.storageOverrideURL = dir
        WatermarkStore.shared.reloadAfterStorageChange()
    }

    private func teardown(_ dir: URL) {
        WatermarkStore.deletionIO = .live
        WatermarkStore.storageOverrideURL = nil
        try? FileManager.default.removeItem(at: dir)
        WatermarkStore.shared.reloadAfterStorageChange()
    }

    /// A tiny in-process PNG so tests don't need a binary fixture on disk.
    private func makeTempPNG(width: Int = 32, height: Int = 16) throws -> URL {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-watermark-src-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    @Test("importing a PNG creates a co-located meta.json + image.png and lists the asset")
    func importCreatesItemFolder() throws {
        let dir = makeTempDir()
        activate(dir)
        defer { teardown(dir) }

        let pngURL = try makeTempPNG(width: 64, height: 32)
        defer { try? FileManager.default.removeItem(at: pngURL) }

        let asset = try WatermarkStore.shared.importPNG(from: pngURL, name: "Studio Logo")
        #expect(asset.pixelWidth == 64)
        #expect(asset.pixelHeight == 32)

        let itemDir = dir.appendingPathComponent("items/\(asset.id.uuidString)", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: itemDir.appendingPathComponent("meta.json").path))
        #expect(FileManager.default.fileExists(atPath: itemDir.appendingPathComponent("image.png").path))

        let listed = WatermarkStore.shared.allAssets()
        #expect(listed.count == 1)
        #expect(listed.first?.name == "Studio Logo")
        #expect(WatermarkStore.shared.imageData(forAssetID: asset.id)?.isEmpty == false)
    }

    @Test("importing a non-image file throws notAPNG")
    func importRejectsNonImage() throws {
        let dir = makeTempDir()
        activate(dir)
        defer { teardown(dir) }

        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-watermark-bad-\(UUID().uuidString).png")
        try Data("not a png".utf8).write(to: badURL)
        defer { try? FileManager.default.removeItem(at: badURL) }

        #expect(throws: WatermarkImportError.self) {
            try WatermarkStore.shared.importPNG(from: badURL, name: "Bad")
        }
        #expect(WatermarkStore.shared.allAssets().isEmpty)
    }

    @Test("rename updates the listed name and persists it")
    func renamePersists() throws {
        let dir = makeTempDir()
        activate(dir)
        defer { teardown(dir) }

        let pngURL = try makeTempPNG()
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try WatermarkStore.shared.importPNG(from: pngURL, name: "Old Name")

        try WatermarkStore.shared.rename(asset.id, to: "New Name")
        #expect(WatermarkStore.shared.asset(byID: asset.id)?.name == "New Name")

        // Reload from disk to prove the rename was actually persisted, not just cached.
        WatermarkStore.shared.reloadAfterStorageChange()
        #expect(WatermarkStore.shared.asset(byID: asset.id)?.name == "New Name")
    }

    @Test("delete removes the item folder and drops it from the listing")
    func deleteRemovesItemFolder() throws {
        let dir = makeTempDir()
        activate(dir)
        defer { teardown(dir) }

        let pngURL = try makeTempPNG()
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try WatermarkStore.shared.importPNG(from: pngURL, name: "To Delete")
        let itemDir = dir.appendingPathComponent("items/\(asset.id.uuidString)", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: itemDir.path))

        try WatermarkStore.shared.delete(id: asset.id)
        #expect(WatermarkStore.shared.allAssets().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: itemDir.path))

        // A tombstone must survive so a stale remote copy can't resurrect the deleted item.
        let tombstone = dir.appendingPathComponent("items/\(asset.id.uuidString).deleted")
        #expect(FileManager.default.fileExists(atPath: tombstone.path))

        // Simulate a stale peer returning the complete item folder. Reload must
        // honor the marker and clean the resurrected copy back up.
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(asset).write(
            to: itemDir.appendingPathComponent("meta.json"), options: .atomic
        )
        try Data(contentsOf: pngURL).write(
            to: itemDir.appendingPathComponent("image.png"), options: .atomic
        )
        WatermarkStore.shared.reloadAfterStorageChange()
        #expect(WatermarkStore.shared.allAssets().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: itemDir.path))
    }

    @Test("failed marker persistence preserves the watermark folder and library entry")
    func failedMarkerPersistencePreservesWatermark() throws {
        let dir = makeTempDir()
        activate(dir)
        defer { teardown(dir) }

        let pngURL = try makeTempPNG()
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try WatermarkStore.shared.importPNG(from: pngURL, name: "Preserved")
        let itemDir = dir.appendingPathComponent("items/\(asset.id.uuidString)", isDirectory: true)
        WatermarkStore.deletionIO = DurableDeletionIO(
            writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            readData: { try CloudCoordinatedIO.readData(at: $0) },
            removeItem: { try CloudCoordinatedIO.removeItem(at: $0) }
        )

        #expect(throws: DurableDeletionError.self) {
            try WatermarkStore.shared.delete(id: asset.id)
        }

        #expect(WatermarkStore.shared.asset(byID: asset.id)?.name == "Preserved")
        #expect(FileManager.default.fileExists(atPath: itemDir.appendingPathComponent("meta.json").path))
        #expect(FileManager.default.fileExists(atPath: itemDir.appendingPathComponent("image.png").path))
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("items/\(asset.id.uuidString).deleted").path
        ))
    }

    /// Regression test: `meta.json` written before `defaultSizeDimension`/`defaultSizeUnit`/
    /// `defaultSizeValue`/`defaultMarginUnit`/`defaultMarginValue` existed must still decode —
    /// a missing-key decode failure would otherwise make an already-imported watermark
    /// silently vanish from the library the first time it's loaded after this update.
    @Test("a legacy meta.json without the default-placement fields still decodes, with fallback defaults")
    func legacyMetaJSONDecodesWithDefaults() throws {
        let dir = makeTempDir()
        activate(dir)
        defer { teardown(dir) }

        let id = UUID()
        let itemDir = dir.appendingPathComponent("items/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

        // Shape of a meta.json written by the original (pre-default-placement) WatermarkAsset.
        let legacyJSON = """
        {
            "id": "\(id.uuidString)",
            "name": "Legacy Watermark",
            "pixelWidth": 400,
            "pixelHeight": 100,
            "createdAt": 758000000,
            "updatedAt": 758000000
        }
        """
        try Data(legacyJSON.utf8).write(to: itemDir.appendingPathComponent("meta.json"))

        let pngURL = try makeTempPNG()
        defer { try? FileManager.default.removeItem(at: pngURL) }
        try Data(contentsOf: pngURL).write(to: itemDir.appendingPathComponent("image.png"))

        WatermarkStore.shared.reloadAfterStorageChange()
        let loaded = try #require(WatermarkStore.shared.asset(byID: id))
        #expect(loaded.name == "Legacy Watermark")
        #expect(loaded.pixelWidth == 400)
        #expect(loaded.defaultSizeDimension == .width)
        #expect(loaded.defaultSizeUnit == .percent)
        #expect(loaded.defaultSizeValue == 20)
        #expect(loaded.defaultMarginUnit == .percent)
        #expect(loaded.defaultMarginValue == 10)
    }
}
