import Testing
import Foundation
import AppKit
@testable import Aagedal_Photo_Agent

/// Tests for the per-item-folder library store in `WatermarkStore`.
///
/// The service is `@MainActor`, so the suite is `@MainActor` and `.serialized`. Each test uses
/// an independently injected storage root, preventing parallel Metal suites from observing or
/// replacing its library while an asynchronous import is suspended.
@Suite("WatermarkStore", .serialized)
@MainActor
struct WatermarkStoreTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatermarkStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func activate(_ dir: URL) -> WatermarkStore {
        WatermarkStore.deletionIO = .live
        let store = WatermarkStore(storageRoot: dir)
        store.reloadAfterStorageChange()
        return store
    }

    private func teardown(_ dir: URL) {
        WatermarkStore.deletionIO = .live
        try? FileManager.default.removeItem(at: dir)
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
    func importCreatesItemFolder() async throws {
        let dir = makeTempDir()
        let store = activate(dir)
        defer { teardown(dir) }

        let pngURL = try makeTempPNG(width: 64, height: 32)
        defer { try? FileManager.default.removeItem(at: pngURL) }

        let asset = try await store.importPNG(from: pngURL, name: "Studio Logo")
        #expect(asset.pixelWidth == 64)
        #expect(asset.pixelHeight == 32)

        let itemDir = dir.appendingPathComponent("items/\(asset.id.uuidString)", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: itemDir.appendingPathComponent("meta.json").path))
        #expect(FileManager.default.fileExists(atPath: itemDir.appendingPathComponent("image.png").path))

        let listed = store.allAssets()
        #expect(listed.count == 1)
        #expect(listed.first?.name == "Studio Logo")
        #expect(store.imageData(forAssetID: asset.id)?.isEmpty == false)
    }

    @Test("importing a non-image file throws notAPNG")
    func importRejectsNonImage() async throws {
        let dir = makeTempDir()
        let store = activate(dir)
        defer { teardown(dir) }

        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-watermark-bad-\(UUID().uuidString).png")
        try Data("not a png".utf8).write(to: badURL)
        defer { try? FileManager.default.removeItem(at: badURL) }

        await #expect(throws: WatermarkImportError.self) {
            try await store.importPNG(from: badURL, name: "Bad")
        }
        #expect(store.allAssets().isEmpty)
    }

    @Test("rename updates the listed name and persists it")
    func renamePersists() async throws {
        let dir = makeTempDir()
        let store = activate(dir)
        defer { teardown(dir) }

        let pngURL = try makeTempPNG()
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try await store.importPNG(from: pngURL, name: "Old Name")

        try store.rename(asset.id, to: "New Name")
        #expect(store.asset(byID: asset.id)?.name == "New Name")

        // Reload from disk to prove the rename was actually persisted, not just cached.
        store.reloadAfterStorageChange()
        #expect(store.asset(byID: asset.id)?.name == "New Name")
    }

    @Test("delete removes the item folder and drops it from the listing")
    func deleteRemovesItemFolder() async throws {
        let dir = makeTempDir()
        let store = activate(dir)
        defer { teardown(dir) }

        let pngURL = try makeTempPNG()
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try await store.importPNG(from: pngURL, name: "To Delete")
        let itemDir = dir.appendingPathComponent("items/\(asset.id.uuidString)", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: itemDir.path))

        try store.delete(id: asset.id)
        #expect(store.allAssets().isEmpty)
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
        store.reloadAfterStorageChange()
        #expect(store.allAssets().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: itemDir.path))
    }

    @Test("failed marker persistence preserves the watermark folder and library entry")
    func failedMarkerPersistencePreservesWatermark() async throws {
        let dir = makeTempDir()
        let store = activate(dir)
        defer { teardown(dir) }

        let pngURL = try makeTempPNG()
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try await store.importPNG(from: pngURL, name: "Preserved")
        let itemDir = dir.appendingPathComponent("items/\(asset.id.uuidString)", isDirectory: true)
        WatermarkStore.deletionIO = DurableDeletionIO(
            writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            readData: { try CloudCoordinatedIO.readData(at: $0) },
            removeItem: { try CloudCoordinatedIO.removeItem(at: $0) }
        )

        #expect(throws: DurableDeletionError.self) {
            try store.delete(id: asset.id)
        }

        #expect(store.asset(byID: asset.id)?.name == "Preserved")
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
        let store = activate(dir)
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

        store.reloadAfterStorageChange()
        let loaded = try #require(store.asset(byID: id))
        #expect(loaded.name == "Legacy Watermark")
        #expect(loaded.pixelWidth == 400)
        #expect(loaded.defaultSizeDimension == .width)
        #expect(loaded.defaultSizeUnit == .percent)
        #expect(loaded.defaultSizeValue == 20)
        #expect(loaded.defaultMarginUnit == .percent)
        #expect(loaded.defaultMarginValue == 10)
    }
}

@Suite("Watermark library import filesystem boundary")
struct WatermarkLibraryImportServiceTests {
    @Test("source read and ordered two-file commit run away from MainActor")
    @MainActor
    func importRunsOffMainActor() async throws {
        let pngData = try makePNGData(width: 18, height: 9)
        let probe = WatermarkLibraryImportAccessProbe(readData: pngData)
        let service = WatermarkLibraryImportService(access: probe.fileAccess)
        let requestID = UUID()
        let source = URL(fileURLWithPath: "/virtual/source.png")
        let items = URL(fileURLWithPath: "/virtual/items", isDirectory: true)

        let result = try await service.importPNG(
            from: source,
            name: "Desk",
            into: items,
            requestID: requestID
        )

        guard case .committed(let commit) = result else {
            Issue.record("Expected a durable watermark import")
            return
        }
        #expect(commit.requestID == requestID)
        #expect(commit.asset.name == "Desk")
        #expect(commit.asset.pixelWidth == 18)
        #expect(commit.asset.pixelHeight == 9)
        #expect(commit.byteCount == pngData.count)
        #expect(probe.writtenFilenames == ["image.png", "meta.json"])
        #expect(!probe.ranOnMainThread)
    }

    @Test("a pre-cancelled import performs no source or destination access")
    func preCancelledImport() async throws {
        let probe = WatermarkLibraryImportAccessProbe(readData: Data())
        let service = WatermarkLibraryImportService(access: probe.fileAccess)
        let requestID = UUID()
        let task = Task {
            await Task.yield()
            return try await service.importPNG(
                from: URL(fileURLWithPath: "/virtual/cancelled.png"),
                name: "Cancelled",
                into: URL(fileURLWithPath: "/virtual/items", isDirectory: true),
                requestID: requestID
            )
        }
        task.cancel()

        let result = try await task.value

        #expect(result == .cancelledBeforeAccess(requestID: requestID))
        #expect(probe.readCount == 0)
        #expect(probe.writtenFilenames.isEmpty)
    }

    @Test("Settings library awaits imports and gates presentation by request identity")
    func viewSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Watermarks/WatermarksLibraryView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("let result = try await store.importPNG("))
        #expect(source.contains("guard importRequestID == requestID else { return }"))
        #expect(source.contains("importTask?.cancel()"))
        #expect(!source.contains("url.startAccessingSecurityScopedResource()"))
        #expect(!source.contains("try store.importPNG(from:"))
    }

    @MainActor
    private func makePNGData(width: Int, height: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}

private nonisolated final class WatermarkLibraryImportAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let storedReadData: Data
    private var observedMainThread = false
    private var storedReadCount = 0
    private var storedWrittenFilenames: [String] = []

    init(readData: Data) {
        storedReadData = readData
    }

    var fileAccess: WatermarkLibraryImportFileAccess {
        WatermarkLibraryImportFileAccess(
            startAccessing: { [self] _ in
                lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                return true
            },
            stopAccessing: { [self] _ in
                lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
            },
            readData: { [self] _ in
                lock.withLock {
                    storedReadCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                return storedReadData
            },
            writeData: { [self] _, url in
                lock.withLock {
                    storedWrittenFilenames.append(url.lastPathComponent)
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
            },
            removeItem: { _ in }
        )
    }

    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var readCount: Int { lock.withLock { storedReadCount } }
    var writtenFilenames: [String] { lock.withLock { storedWrittenFilenames } }
}
