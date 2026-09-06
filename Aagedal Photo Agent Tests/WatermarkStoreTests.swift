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

    private func activate(_ dir: URL) async -> WatermarkStore {
        WatermarkStore.deletionIO = .live
        let store = WatermarkStore(storageRoot: dir)
        await store.reloadAfterStorageChange()
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

    @Test("an old-root import returns its durable commit without repopulating the replacement")
    func oldRootImportCannotPublish() async throws {
        let oldRoot = makeTempDir()
        let replacement = makeTempDir()
        let source = try makeTempPNG()
        defer { teardown(oldRoot); teardown(replacement); try? FileManager.default.removeItem(at: source) }
        let gate = LibraryRootWriteGate()
        defer { gate.release() }
        let access = WatermarkLibraryFileAccess(
            startAccessing: { _ in false },
            stopAccessing: { _ in },
            readData: { try Data(contentsOf: $0) },
            writeData: { data, url in
                if url.lastPathComponent == "meta.json" { gate.block() }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            ensureDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            contentsOfDirectory: { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) },
            isDirectory: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        )
        let store = WatermarkStore(storageRoot: oldRoot, persistence: WatermarkLibraryPersistenceService(access: access))
        await store.loadIfNeeded()
        let requestID = UUID()
        let mutation = Task { try await store.importPNG(from: source, name: "Old root", requestID: requestID) }
        try await gate.waitUntilBlocked()
        store.invalidateStorageCache(resolvedStorageURL: replacement)
        gate.release()
        let result = try await mutation.value
        guard case .committed(let commit) = result else {
            Issue.record("The original-root import must remain a durable commit")
            return
        }
        #expect(commit.requestID == requestID)
        #expect(commit.metadataURL.path.hasPrefix(oldRoot.path + "/"))
        #expect(FileManager.default.fileExists(atPath: commit.metadataURL.path))
        #expect(FileManager.default.fileExists(atPath: commit.imageURL.path))
        #expect(store.shouldSkipRemoteReload(path: commit.metadataURL.path, contentChangeDate: nil))
        #expect(store.assets.isEmpty)
        await store.loadIfNeeded()
        #expect(store.assets.isEmpty)
        #expect(store.imageData(forAssetID: commit.asset.id) == nil)
        #expect(store.imageURL(forAssetID: commit.asset.id) == nil)
    }

    @Test("importing a PNG creates a co-located meta.json + image.png and lists the asset")
    func importCreatesItemFolder() async throws {
        let dir = makeTempDir()
        let store = await activate(dir)
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
        let store = await activate(dir)
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
        let store = await activate(dir)
        defer { teardown(dir) }

        let pngURL = try makeTempPNG()
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try await store.importPNG(from: pngURL, name: "Old Name")

        try await store.rename(asset.id, to: "New Name")
        #expect(store.asset(byID: asset.id)?.name == "New Name")

        // Reload from disk to prove the rename was actually persisted, not just cached.
        await store.reloadAfterStorageChange()
        #expect(store.asset(byID: asset.id)?.name == "New Name")
    }

    @Test("delete removes the item folder and drops it from the listing")
    func deleteRemovesItemFolder() async throws {
        let dir = makeTempDir()
        let store = await activate(dir)
        defer { teardown(dir) }

        let pngURL = try makeTempPNG()
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let asset = try await store.importPNG(from: pngURL, name: "To Delete")
        let itemDir = dir.appendingPathComponent("items/\(asset.id.uuidString)", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: itemDir.path))

        try await store.delete(id: asset.id)
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
        await store.reloadAfterStorageChange()
        #expect(store.allAssets().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: itemDir.path))
    }

    @Test("failed marker persistence preserves the watermark folder and library entry")
    func failedMarkerPersistencePreservesWatermark() async throws {
        let dir = makeTempDir()
        let store = await activate(dir)
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

        await #expect(throws: DurableDeletionError.self) {
            try await store.delete(id: asset.id)
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
    func legacyMetaJSONDecodesWithDefaults() async throws {
        let dir = makeTempDir()
        let store = await activate(dir)
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

        await store.reloadAfterStorageChange()
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

@Suite("Watermark library persistence filesystem boundary")
struct WatermarkLibraryPersistenceServiceTests {
    @Test("library load returns one metadata-and-image snapshot away from MainActor")
    @MainActor
    func libraryLoadRunsOffMainActor() async throws {
        let asset = WatermarkAsset(name: "Published", pixelWidth: 80, pixelHeight: 20)
        let imageData = Data("cached-png".utf8)
        let probe = WatermarkLibraryImportAccessProbe(
            readData: Data(),
            libraryAsset: asset,
            libraryImageData: imageData
        )
        let service = WatermarkLibraryPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = await service.load(
            from: URL(fileURLWithPath: "/virtual/watermarks", isDirectory: true),
            requestID: requestID
        )

        guard case .loaded(let snapshot) = result else {
            Issue.record("Expected a complete Watermark snapshot")
            return
        }
        #expect(snapshot.requestID == requestID)
        #expect(snapshot.assets.map(\.id) == [asset.id])
        #expect(snapshot.imageDataByAssetID[asset.id] == imageData)
        #expect(snapshot.inspectedEntryCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("pre-cancelled library load performs no filesystem access")
    func preCancelledLibraryLoad() async {
        let probe = WatermarkLibraryImportAccessProbe(readData: Data())
        let service = WatermarkLibraryPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.load(
                from: URL(fileURLWithPath: "/virtual/watermarks", isDirectory: true),
                requestID: requestID
            )
        }.value

        guard case .cancelledBeforeAccess(let resultID) = result else {
            Issue.record("Expected cancellation before Watermark library access")
            return
        }
        #expect(resultID == requestID)
        #expect(probe.filesystemCallCount == 0)
    }

    @Test("source read and ordered two-file commit run away from MainActor")
    @MainActor
    func importRunsOffMainActor() async throws {
        let pngData = try makePNGData(width: 18, height: 9)
        let probe = WatermarkLibraryImportAccessProbe(readData: pngData)
        let service = WatermarkLibraryPersistenceService(access: probe.fileAccess)
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
        let service = WatermarkLibraryPersistenceService(access: probe.fileAccess)
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

        let storeSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/WatermarkStore.swift"
            ),
            encoding: .utf8
        )
        let ownerStart = try #require(storeSource.range(of: "final class WatermarkStore"))
        let ownerSource = storeSource[ownerStart.lowerBound...]
        #expect(storeSource.contains("actor WatermarkLibraryPersistenceService"))
        #expect(ownerSource.contains("await persistence.load("))
        #expect(ownerSource.contains("try await persistence.upsertMetadata("))
        #expect(ownerSource.contains("try await persistence.delete("))
        #expect(ownerSource.contains("return imageDataByAssetID[id]"))
        #expect(!ownerSource.contains("CloudCoordinatedIO."))
        #expect(!ownerSource.contains("Data(contentsOf:"))
        #expect(!ownerSource.contains("NSFileVersion."))
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
    private let libraryAsset: WatermarkAsset?
    private let libraryImageData: Data?
    private var observedMainThread = false
    private var storedReadCount = 0
    private var storedFilesystemCallCount = 0
    private var storedWrittenFilenames: [String] = []

    init(
        readData: Data,
        libraryAsset: WatermarkAsset? = nil,
        libraryImageData: Data? = nil
    ) {
        storedReadData = readData
        self.libraryAsset = libraryAsset
        self.libraryImageData = libraryImageData
    }

    var fileAccess: WatermarkLibraryFileAccess {
        WatermarkLibraryFileAccess(
            startAccessing: { [self] _ in
                lock.withLock {
                    storedFilesystemCallCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                return true
            },
            stopAccessing: { [self] _ in
                lock.withLock {
                    storedFilesystemCallCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
            },
            readData: { [self] url in
                lock.withLock {
                    storedFilesystemCallCount += 1
                    storedReadCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                if url.lastPathComponent == "meta.json", let libraryAsset {
                    return try JSONEncoder().encode(libraryAsset)
                }
                if url.lastPathComponent == "image.png", let libraryImageData {
                    return libraryImageData
                }
                return storedReadData
            },
            writeData: { [self] _, url in
                lock.withLock {
                    storedFilesystemCallCount += 1
                    storedWrittenFilenames.append(url.lastPathComponent)
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
            },
            removeItem: { [self] _ in recordFilesystemCall() },
            ensureDirectory: { [self] _ in recordFilesystemCall() },
            contentsOfDirectory: { [self] directory in
                recordFilesystemCall()
                guard let libraryAsset else { return [] }
                return [directory.appendingPathComponent(
                    libraryAsset.id.uuidString,
                    isDirectory: true
                )]
            },
            isDirectory: { [self] url in
                recordFilesystemCall()
                return url.lastPathComponent == libraryAsset?.id.uuidString
            }
        )
    }

    private func recordFilesystemCall() {
        lock.withLock {
            storedFilesystemCallCount += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
    }

    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var readCount: Int { lock.withLock { storedReadCount } }
    var filesystemCallCount: Int { lock.withLock { storedFilesystemCallCount } }
    var writtenFilenames: [String] { lock.withLock { storedWrittenFilenames } }
}

@Suite("Teams and Watermark cloud watcher lifecycle", .serialized)
@MainActor
struct LibraryCloudWatcherLifecycleTests {
    @Test("A changed root replaces the query; the same root preserves it", arguments: [false, true])
    func replacesChangedRoot(watermarks: Bool) {
        var enabled = true
        var started: [NSMetadataQuery] = []
        var stopped: [NSMetadataQuery] = []
        let watcher = makeWatcher(
            watermarks: watermarks,
            isEnabled: { enabled },
            resolveRoot: { nil },
            start: { started.append($0) },
            stop: { stopped.append($0) }
        )
        let first = URL(fileURLWithPath: "/test/cloud-first")
        let second = URL(fileURLWithPath: "/test/cloud-second")
        watcher.refresh(first)
        watcher.refresh(first)
        #expect(started.count == 1)
        #expect(stopped.isEmpty)
        #expect(watcher.root() == first)

        watcher.refresh(second)
        #expect(started.count == 2)
        #expect(stopped.count == 1)
        #expect(stopped.first === started.first)
        #expect(watcher.root() == second)

        enabled = false
        watcher.refresh(nil)
        #expect(stopped.count == 2)
        #expect(watcher.root() == nil)
    }

    @Test("A supplied root cancels a suspended older lookup", arguments: [false, true])
    func suppliedRootSupersedesLookup(watermarks: Bool) async {
        var enabled = true
        var starts = 0
        let gate = LibraryCloudWatcherResolutionGate()
        let watcher = makeWatcher(
            watermarks: watermarks,
            isEnabled: { enabled },
            resolveRoot: { await gate.resolve() },
            start: { _ in starts += 1 },
            stop: { _ in }
        )
        watcher.refresh(nil)
        await gate.waitUntilRequested()
        let replacement = URL(fileURLWithPath: "/test/replacement")
        watcher.refresh(replacement)
        await gate.release(URL(fileURLWithPath: "/test/stale"))
        let wasCancelled = await gate.waitForCancellationEvidence()
        #expect(wasCancelled)
        #expect(watcher.root() == replacement)
        #expect(starts == 1)
        enabled = false
        watcher.refresh(nil)
    }

    @Test("Disabling cancels a suspended lookup without starting a query", arguments: [false, true])
    func disableCancelsLookup(watermarks: Bool) async {
        var enabled = true
        var starts = 0
        let gate = LibraryCloudWatcherResolutionGate()
        let watcher = makeWatcher(
            watermarks: watermarks,
            isEnabled: { enabled },
            resolveRoot: { await gate.resolve() },
            start: { _ in starts += 1 },
            stop: { _ in }
        )
        watcher.refresh(nil)
        await gate.waitUntilRequested()
        enabled = false
        watcher.refresh(nil)
        await gate.release(URL(fileURLWithPath: "/test/stale"))
        let wasCancelled = await gate.waitForCancellationEvidence()
        #expect(wasCancelled)
        #expect(starts == 0)
        #expect(watcher.root() == nil)
    }

    @Test("Queued old-query callbacks are discarded after replacement and disable", arguments: [false, true])
    func staleCallbacksAreDiscarded(watermarks: Bool) async {
        var enabled = true
        var queries: [LibraryCloudCallbackCountingQuery] = []
        let watcher = makeWatcher(
            watermarks: watermarks,
            isEnabled: { enabled },
            resolveRoot: { nil },
            makeQuery: {
                let query = LibraryCloudCallbackCountingQuery()
                queries.append(query)
                return query
            },
            start: { _ in },
            stop: { _ in }
        )
        watcher.refresh(URL(fileURLWithPath: "/test/first"))
        NotificationCenter.default.post(name: .NSMetadataQueryDidUpdate, object: queries[0])
        watcher.refresh(URL(fileURLWithPath: "/test/replacement"))
        // Let the previously enqueued MainActor observer callback finish.
        await Task { @MainActor in }.value
        #expect(queries[0].readCount == 0)
        #expect(queries[1].readCount == 0)

        NotificationCenter.default.post(name: .NSMetadataQueryDidFinishGathering, object: queries[1])
        await Task { @MainActor in }.value
        #expect(queries[1].readCount == 1)

        NotificationCenter.default.post(name: .NSMetadataQueryDidUpdate, object: queries[1])
        enabled = false
        watcher.refresh(nil)
        await Task { @MainActor in }.value
        #expect(queries[1].readCount == 1)
    }

    private func makeWatcher(
        watermarks: Bool,
        isEnabled: @escaping () -> Bool,
        resolveRoot: @escaping @Sendable () async -> URL?,
        makeQuery: @escaping () -> NSMetadataQuery = { NSMetadataQuery() },
        start: @escaping (NSMetadataQuery) -> Void,
        stop: @escaping (NSMetadataQuery) -> Void
    ) -> (refresh: (URL?) -> Void, root: () -> URL?) {
        if watermarks {
            let watcher = WatermarkCloudCoordinator(
                isEnabled: isEnabled, resolveRoot: resolveRoot, makeMetadataQuery: makeQuery,
                startMetadataQuery: start, stopMetadataQuery: stop
            )
            return ({ watcher.refresh(resolvedRoot: $0) }, { watcher.monitoredRoot })
        }
        let watcher = RosterCloudCoordinator(
            isEnabled: isEnabled, resolveRoot: resolveRoot, makeMetadataQuery: makeQuery,
            startMetadataQuery: start, stopMetadataQuery: stop
        )
        return ({ watcher.refresh(resolvedRoot: $0) }, { watcher.monitoredRoot })
    }
}

private actor LibraryCloudWatcherResolutionGate {
    private var rootContinuation: CheckedContinuation<URL?, Never>?
    private var requestedContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Bool, Never>?
    private var cancellationEvidence: Bool?

    func resolve() async -> URL? {
        let result: URL? = await withCheckedContinuation { continuation in
            rootContinuation = continuation
            requestedContinuation?.resume()
            requestedContinuation = nil
        }
        let cancelled = Task.isCancelled
        cancellationEvidence = cancelled
        cancellationContinuation?.resume(returning: cancelled)
        cancellationContinuation = nil
        return result
    }

    func waitUntilRequested() async {
        if rootContinuation != nil { return }
        await withCheckedContinuation { requestedContinuation = $0 }
    }

    func release(_ root: URL) {
        rootContinuation?.resume(returning: root)
        rootContinuation = nil
    }

    func waitForCancellationEvidence() async -> Bool {
        if let cancellationEvidence { return cancellationEvidence }
        return await withCheckedContinuation { cancellationContinuation = $0 }
    }
}

/// Count actual observer admissions without querying an iCloud provider.
nonisolated private final class LibraryCloudCallbackCountingQuery: NSMetadataQuery {
    private let lock = NSLock()
    private var storedReadCount = 0
    var readCount: Int { lock.withLock { storedReadCount } }
    override var results: [Any] {
        lock.withLock { storedReadCount += 1 }
        return []
    }
}
