import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("Raw Metadata app-sidecar filesystem boundary")
struct RawMetadataSidecarLoadServiceTests {
    @Test("a complete immutable snapshot is read away from the main actor")
    @MainActor
    func completeSnapshotRunsOffMainActor() async throws {
        let imageURL = URL(fileURLWithPath: "/virtual/photo.raw")
        let folderURL = URL(fileURLWithPath: "/virtual/folder", isDirectory: true)
        let requestID = UUID()
        let bytes = Data("{\n  \"title\" : \"News\"\n}".utf8)
        let probe = RawMetadataSidecarAccessProbe(data: bytes)
        let service = RawMetadataSidecarLoadService(access: RawMetadataSidecarAccess(
            readEncodedSidecar: probe.read
        ))

        let result = try await Task {
            try await service.load(
                imageURL: imageURL,
                folderURL: folderURL,
                requestID: requestID
            )
        }.value

        #expect(result == .loaded(RawMetadataSidecarSnapshot(
            requestID: requestID,
            imageURL: imageURL,
            folderURL: folderURL,
            text: String(decoding: bytes, as: UTF8.self),
            byteCount: bytes.count
        )))
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("pre-cancellation performs no synchronous read")
    func preCancellation() async throws {
        let requestID = UUID()
        let probe = RawMetadataSidecarAccessProbe(data: Data("unused".utf8))
        let service = RawMetadataSidecarLoadService(access: RawMetadataSidecarAccess(
            readEncodedSidecar: probe.read
        ))
        let task = Task {
            await Task.yield()
            return try await service.load(
                imageURL: URL(fileURLWithPath: "/virtual/cancelled.raw"),
                folderURL: URL(fileURLWithPath: "/virtual/folder"),
                requestID: requestID
            )
        }
        task.cancel()

        #expect(try await task.value == .cancelledBeforeRead(requestID: requestID))
        #expect(probe.invocationCount == 0)
    }

    @Test("cancellation during a non-preemptible read is explicit")
    func cancellationAfterRead() async throws {
        let imageURL = URL(fileURLWithPath: "/virtual/slow.raw")
        let bytes = Data("{}".utf8)
        let requestID = UUID()
        let service = RawMetadataSidecarLoadService(access: RawMetadataSidecarAccess { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return bytes
        })

        let result = try await Task {
            try await service.load(
                imageURL: imageURL,
                folderURL: URL(fileURLWithPath: "/virtual/folder"),
                requestID: requestID
            )
        }.value

        #expect(result == .cancelledAfterRead(
            requestID: requestID,
            imageURL: imageURL,
            byteCount: bytes.count
        ))
    }

    @Test("Raw Metadata awaits the service and rejects stale publication")
    func rawMetadataViewSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Metadata/RawMetadataView.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func loadAppSidecar() async"))
        let functionSource = String(source[functionStart.lowerBound...])

        #expect(functionSource.contains("try await RawMetadataSidecarLoadService.shared.load("))
        #expect(functionSource.contains("guard appSidecarRequestID == requestID else { return }"))
        #expect(!functionSource.contains("MetadataSidecarService().loadSidecar"))
    }

    @Test("XMP presentation is read away from the main actor")
    @MainActor
    func xmpSnapshotRunsOffMainActor() async {
        let imageURL = URL(fileURLWithPath: "/virtual/xmp-photo.raw")
        let requestID = UUID()
        let text = "<x:xmpmeta>News</x:xmpmeta>"
        let probe = RawMetadataXMPAccessProbe(text: text)
        let service = RawMetadataXMPSidecarLoadService(access: .init(
            readPrettyPrintedSidecar: probe.read
        ))

        let result = await Task {
            await service.load(imageURL: imageURL, requestID: requestID)
        }.value

        #expect(result == .loaded(RawMetadataXMPSidecarSnapshot(
            requestID: requestID,
            imageURL: imageURL,
            text: text
        )))
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("XMP pre-cancellation performs no synchronous read")
    func xmpPreCancellation() async {
        let requestID = UUID()
        let probe = RawMetadataXMPAccessProbe(text: "unused")
        let service = RawMetadataXMPSidecarLoadService(access: .init(
            readPrettyPrintedSidecar: probe.read
        ))
        let task = Task {
            await Task.yield()
            return await service.load(
                imageURL: URL(fileURLWithPath: "/virtual/cancelled.raw"),
                requestID: requestID
            )
        }
        task.cancel()

        #expect(await task.value == .cancelledBeforeRead(requestID: requestID))
        #expect(probe.invocationCount == 0)
    }

    @Test("XMP cancellation after a non-preemptible read is explicit")
    func xmpCancellationAfterRead() async {
        let imageURL = URL(fileURLWithPath: "/virtual/slow.raw")
        let requestID = UUID()
        let service = RawMetadataXMPSidecarLoadService(access: .init { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return "<x:xmpmeta/>"
        })

        let result = await Task {
            await service.load(imageURL: imageURL, requestID: requestID)
        }.value

        #expect(result == .cancelledAfterRead(requestID: requestID, imageURL: imageURL))
    }

    @Test("Raw Metadata XMP awaits the actor and rejects stale publication")
    func rawMetadataXMPSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Metadata/RawMetadataView.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func loadXMPSidecar() async"))
        let functionEnd = try #require(source.range(
            of: "    private func loadAppSidecar() async",
            range: functionStart.upperBound..<source.endIndex
        ))
        let functionSource = String(source[functionStart.lowerBound..<functionEnd.lowerBound])

        #expect(functionSource.contains("await RawMetadataXMPSidecarLoadService.shared.load("))
        #expect(functionSource.contains("guard !Task.isCancelled, xmpSidecarRequestID == requestID else { return }"))
        #expect(functionSource.contains("snapshot.imageURL == imageURL"))
        #expect(!functionSource.contains("Task.detached"))
        #expect(!functionSource.contains("XMPSidecarService()"))
    }
}

private nonisolated final class RawMetadataSidecarAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data?
    private var count = 0
    private var observedMainThread = false

    init(data: Data?) {
        self.data = data
    }

    func read(imageURL: URL, folderURL: URL) throws -> Data? {
        _ = imageURL
        _ = folderURL
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return data
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

private nonisolated final class RawMetadataXMPAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let text: String?
    private var count = 0
    private var observedMainThread = false

    init(text: String?) {
        self.text = text
    }

    func read(imageURL: URL) -> String? {
        _ = imageURL
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return text
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

private actor FolderEventProbe {
    private var eventCount = 0

    func recordEvent() {
        eventCount += 1
    }

    func waitForEvent(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while eventCount == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return eventCount > 0
    }
}

@Suite("Folder change monitor setup boundary")
struct FolderChangeMonitorServiceTests {
    @Test("monitor setup runs away from the main actor")
    @MainActor
    func setupRunsOffMainActor() async {
        let probe = FolderChangeMonitorFactoryProbe()
        let service = FolderChangeMonitorService(factory: probe.makeUnavailableMonitor)

        let result = await service.createMonitor(FolderChangeMonitorRequest(
            folderURL: URL(fileURLWithPath: "/virtual/slow-volume", isDirectory: true),
            onChange: { _ in }
        ))

        guard case .unavailable = result else {
            Issue.record("Expected an unavailable monitor result")
            return
        }
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("pre-cancellation skips synchronous monitor setup")
    func preCancellationSkipsSetup() async {
        let probe = FolderChangeMonitorFactoryProbe()
        let service = FolderChangeMonitorService(factory: probe.makeUnavailableMonitor)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.createMonitor(FolderChangeMonitorRequest(
                folderURL: URL(fileURLWithPath: "/virtual/cancelled", isDirectory: true),
                onChange: { _ in }
            ))
        }

        let result = await task.value
        guard case .cancelledBeforeSetup = result else {
            Issue.record("Expected cancellation before monitor setup")
            return
        }
        #expect(probe.invocationCount == 0)
    }

    @Test("cancellation observed after synchronous setup is explicit")
    func postSetupCancellationIsExplicit() async {
        let service = FolderChangeMonitorService { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return nil
        }

        let task = Task {
            await service.createMonitor(FolderChangeMonitorRequest(
                folderURL: URL(fileURLWithPath: "/virtual/post-cancelled", isDirectory: true),
                onChange: { _ in }
            ))
        }
        let result = await task.value

        guard case .cancelledAfterSetup = result else {
            Issue.record("Expected cancellation after synchronous monitor setup")
            return
        }
    }

    @Test("Browser monitor installation awaits the actor and identity-gates publication")
    func browserCoordinatorSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/BrowserAutoRefreshCoordinator.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("await monitorService.createMonitor(request)"))
        #expect(source.contains("monitorRequestIDs[paneID] == requestID"))
        #expect(source.contains("monitoredURLs[paneID] == folderURL"))
        #expect(source.contains("monitorSetupTasks.removeValue(forKey: paneID)?.cancel()"))
        #expect(!source.contains("FolderChangeMonitor(url: folderURL)"))
    }
}

private nonisolated final class FolderChangeMonitorFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var observedMainThread = false

    func makeUnavailableMonitor(_ request: FolderChangeMonitorRequest) -> FolderChangeMonitor? {
        _ = request
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return nil
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

@Suite("MetadataSidecarService")
struct MetadataSidecarServiceTests {

    // MARK: - Helpers

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeImageURL(in folder: URL, name: String = "photo.jpg") -> URL {
        folder.appendingPathComponent(name)
    }

    private func makeSidecar(
        filename: String = "photo.jpg",
        metadata: IPTCMetadata = IPTCMetadata(),
        snapshot: IPTCMetadata? = nil,
        pendingChanges: Bool = false
    ) -> MetadataSidecar {
        MetadataSidecar(
            sourceFile: filename,
            pendingChanges: pendingChanges,
            metadata: metadata,
            imageMetadataSnapshot: snapshot
        )
    }

    @Test("explicit discard removes current and legacy pending sidecars off MainActor")
    @MainActor
    func explicitDiscard() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = makeImageURL(in: folder)
        let service = MetadataSidecarService()
        try service.saveSidecar(makeSidecar(pendingChanges: true), for: image, in: folder)
        let directory = folder.appendingPathComponent(".photo_metadata")
        let current = directory.appendingPathComponent("photo.jpg.meta.json")
        let legacy = directory.appendingPathComponent("photo.meta.json")
        try FileManager.default.copyItem(at: current, to: legacy)
        let unrelated = directory.appendingPathComponent("other.jpg.meta.json")
        try Data("keep".utf8).write(to: unrelated)
        try await service.deleteSidecarSerialized(for: image, in: folder) {
            #expect(!Thread.isMainThread)
        }
        #expect(!FileManager.default.fileExists(atPath: current.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
        try await service.deleteSidecarSerialized(for: image, in: folder)
    }

    @Test("explicit discard cancellation and failures retain pending data")
    func explicitDiscardFailure() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = makeImageURL(in: folder)
        let service = MetadataSidecarService()
        try service.saveSidecar(makeSidecar(pendingChanges: true), for: image, in: folder)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.deleteSidecarSerialized(for: image, in: folder) {
                Issue.record("Cancelled discard entered transaction")
            }
        }
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        do {
            try await service.deleteSidecarSerialized(for: image, in: folder) {
                throw CocoaError(.fileWriteNoPermission)
            }
            Issue.record("Expected deletion failure")
        } catch { #expect((error as NSError).code == CocoaError.fileWriteNoPermission.rawValue) }
        #expect(service.loadSidecar(for: image, in: folder)?.pendingChanges == true)
    }

    @Test("refresh cleanup deletes only empty committed sidecars off MainActor")
    @MainActor
    func cleanupEmptySidecar() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = makeImageURL(in: folder)
        let service = MetadataSidecarService()
        try service.saveSidecar(makeSidecar(), for: image, in: folder)
        let deleted = try await service.deleteUnneededSidecarSerialized(
            for: image, in: folder,
            beforeRevisionCheck: { _ in #expect(!Thread.isMainThread) }
        )
        #expect(deleted)
        #expect(service.loadSidecar(for: image, in: folder) == nil)
        #expect(try await !service.deleteUnneededSidecarSerialized(for: image, in: folder))
    }

    @Test("refresh cleanup preserves pending edits and history that arrived after its snapshot")
    func cleanupPreservesNewEdits() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = makeImageURL(in: folder)
        let service = MetadataSidecarService()
        for pending in [false, true] {
            try service.saveSidecar(makeSidecar(), for: image, in: folder)
            var changed = makeSidecar(metadata: IPTCMetadata(title: "New edit"), pendingChanges: pending)
            if !pending {
                changed.history = [.init(timestamp: Date(), fieldName: "Title", oldValue: nil, newValue: "New edit")]
            }
            let newerRecord = changed
            let deleted = try await service.deleteUnneededSidecarSerialized(
                for: image, in: folder,
                beforeRevisionCheck: { attempt in
                    if attempt == 0 {
                        do { try service.saveSidecar(newerRecord, for: image, in: folder) }
                        catch { Issue.record(error) }
                    }
                }
            )
            #expect(!deleted)
            #expect(service.loadSidecar(for: image, in: folder)?.metadata.title == "New edit")
        }
    }

    @Test("refresh cleanup preserves unreadable, newer-schema, and meaningful legacy sidecars")
    func cleanupProtectsLegacyAndUnreadableRecords() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = makeImageURL(in: folder)
        let service = MetadataSidecarService()
        try service.saveSidecar(makeSidecar(), for: image, in: folder)
        let directory = folder.appendingPathComponent(".photo_metadata")
        let legacy = directory.appendingPathComponent("photo.meta.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var future = try #require(JSONSerialization.jsonObject(with: encoder.encode(makeSidecar())) as? [String: Any])
        future["schemaVersion"] = MetadataSidecar.currentSchemaVersion + 1
        let protectedRecords = [
            Data("broken JSON".utf8),
            try JSONSerialization.data(withJSONObject: future),
            try encoder.encode(makeSidecar(pendingChanges: true))
        ]
        for bytes in protectedRecords {
            try bytes.write(to: legacy)
            #expect(try await !service.deleteUnneededSidecarSerialized(for: image, in: folder))
            #expect(try Data(contentsOf: legacy) == bytes)
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("photo.jpg.meta.json").path))
        }
    }

    @Test("pre-cancelled refresh cleanup leaves the sidecar intact")
    func cleanupCancellation() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = makeImageURL(in: folder)
        let service = MetadataSidecarService()
        try service.saveSidecar(makeSidecar(), for: image, in: folder)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.deleteUnneededSidecarSerialized(for: image, in: folder)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(service.loadSidecar(for: image, in: folder) != nil)
    }

    // MARK: - Save & Load

    @Test("save then load returns equivalent sidecar")
    func saveAndLoadRoundtrip() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        let metadata = IPTCMetadata(
            title: "Test Photo",
            keywords: ["nature"],
            creator: "Photographer",
            imageSupplierImageID: "AGENCY-2026-0042"
        )
        let sidecar = makeSidecar(filename: "photo.jpg", metadata: metadata)

        try service.saveSidecar(sidecar, for: imageURL, in: folder)
        let loaded = try #require(service.loadSidecar(for: imageURL, in: folder))

        #expect(loaded.metadata.title == "Test Photo")
        #expect(loaded.metadata.keywords == ["nature"])
        #expect(loaded.metadata.creator == "Photographer")
        #expect(loaded.metadata.imageSupplierImageID == "AGENCY-2026-0042")
        #expect(loaded.sourceFile == "photo.jpg")
    }

    @Test("structured editorial metadata survives the sidecar service roundtrip")
    func structuredEditorialMetadataRoundtrip() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        let contact = CreatorContactInfo(
            addressLines: ["News House", "1 Example Street"],
            city: "Oslo",
            country: "Norway",
            emails: ["desk@example.test"],
            phoneNumbers: ["+47 22 00 00 00"],
            webURLs: ["https://example.test/contact"]
        )
        let created = EditorialLocation(
            name: "City Hall",
            city: "Oslo",
            countryName: "Norway",
            countryCode: "NOR"
        )
        let shown = EditorialLocation(
            identifiers: ["https://example.test/places/harbor"],
            name: "Harbor",
            latitude: 59.90,
            longitude: 10.75
        )
        let sidecar = makeSidecar(
            metadata: IPTCMetadata(
                creatorContactInfo: contact,
                locationsCreated: [created],
                locationsShown: [shown]
            )
        )

        try service.saveSidecar(sidecar, for: imageURL, in: folder)
        let loaded = try #require(service.loadSidecar(for: imageURL, in: folder))

        #expect(loaded.metadata.creatorContactInfo == contact)
        #expect(loaded.metadata.locationsCreated == [created])
        #expect(loaded.metadata.locationsShown == [shown])
    }

    @Test("legacy version-key sidecars migrate with defaults and save using schemaVersion")
    func legacySidecarMigration() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let metadataDirectory = folder.appendingPathComponent(".photo_metadata")
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        let sidecarURL = metadataDirectory.appendingPathComponent("photo.jpg.meta.json")
        let legacyData = Data(
            #"{"version":1,"sourceFile":"photo.jpg","metadata":{"title":"Legacy headline"}}"#.utf8
        )
        try legacyData.write(to: sidecarURL)

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        let loaded = try #require(service.loadSidecar(for: imageURL, in: folder))
        #expect(loaded.schemaVersion == MetadataSidecar.currentSchemaVersion)
        #expect(loaded.metadata.title == "Legacy headline")
        #expect(loaded.pendingChanges == false)
        #expect(loaded.history.isEmpty)

        try service.saveSidecar(loaded, for: imageURL, in: folder)
        let savedObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any]
        )
        #expect(savedObject["schemaVersion"] as? Int == MetadataSidecar.currentSchemaVersion)
        #expect(savedObject["version"] == nil)
    }

    @Test("newer sidecars remain in place and cannot be overwritten")
    func newerSidecarIsReadOnly() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let metadataDirectory = folder.appendingPathComponent(".photo_metadata")
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        let sidecarURL = metadataDirectory.appendingPathComponent("photo.jpg.meta.json")
        let futureData = Data(
            #"{"schemaVersion":2,"sourceFile":"photo.jpg","future":{"keep":true}}"#.utf8
        )
        try futureData.write(to: sidecarURL)

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        #expect(service.loadSidecar(for: imageURL, in: folder) == nil)
        #expect(try Data(contentsOf: sidecarURL) == futureData)

        #expect(throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "metadata sidecar",
            found: 2,
            supported: MetadataSidecar.currentSchemaVersion
        )) {
            try service.saveSidecar(makeSidecar(), for: imageURL, in: folder)
        }
        #expect(try Data(contentsOf: sidecarURL) == futureData)
        let files = try FileManager.default.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(!files.contains { $0.lastPathComponent.contains(".corrupt.") })
    }

    @Test("same-schema unknown fields survive edits while known fields can be cleared")
    func unknownFieldsSurviveCurrentSchemaSave() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let metadataDirectory = folder.appendingPathComponent(".photo_metadata")
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        let sidecarURL = metadataDirectory.appendingPathComponent("photo.jpg.meta.json")
        try Data(
            #"{"schemaVersion":1,"sourceFile":"photo.jpg","metadata":{"title":"Before","description":"Clear me","extensionField":{"value":7}},"sidecarExtension":["keep"]}"#.utf8
        ).write(to: sidecarURL)

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        var sidecar = try #require(service.loadSidecar(for: imageURL, in: folder))
        sidecar.metadata.title = "After"
        sidecar.metadata.description = nil
        try service.saveSidecar(sidecar, for: imageURL, in: folder)

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any]
        )
        #expect(object["sidecarExtension"] as? [String] == ["keep"])
        let metadata = try #require(object["metadata"] as? [String: Any])
        #expect(metadata["title"] as? String == "After")
        #expect(metadata["description"] == nil)
        let extensionField = try #require(metadata["extensionField"] as? [String: Any])
        #expect(extensionField["value"] as? Int == 7)
    }

    @Test("load returns nil for non-existent sidecar")
    func loadNonExistentReturnsNil() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        #expect(service.loadSidecar(for: imageURL, in: folder) == nil)
    }

    @Test("save updates lastModified timestamp")
    func saveUpdatesLastModified() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        let before = Date()
        let sidecar = makeSidecar()
        try service.saveSidecar(sidecar, for: imageURL, in: folder)
        let after = Date()

        let loaded = try #require(service.loadSidecar(for: imageURL, in: folder))
        // Sidecar JSON uses .iso8601 encoding (whole-second precision), so floor `before` to seconds before comparing.
        let beforeFloor = Date(timeIntervalSince1970: before.timeIntervalSince1970.rounded(.down))
        #expect(loaded.lastModified >= beforeFloor)
        #expect(loaded.lastModified <= after)
    }

    @Test("save creates .photo_metadata directory")
    func saveCreatesMetadataDirectory() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        try service.saveSidecar(makeSidecar(), for: imageURL, in: folder)

        let metaDir = folder.appendingPathComponent(".photo_metadata")
        #expect(FileManager.default.fileExists(atPath: metaDir.path))
    }

    @Test("sidecar file named after image with .meta.json suffix")
    func sidecarFileNaming() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder, name: "DSC_0042.CR3")
        try service.saveSidecar(makeSidecar(filename: "DSC_0042.CR3"), for: imageURL, in: folder)

        let expectedPath = folder
            .appendingPathComponent(".photo_metadata")
            .appendingPathComponent("DSC_0042.CR3.meta.json")
            .path
        #expect(FileManager.default.fileExists(atPath: expectedPath))
    }

    @Test("cameraRaw not persisted to sidecar JSON")
    func cameraRawNotPersisted() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        var crs = CameraRawSettings()
        crs.exposure2012 = 1.5
        let metadata = IPTCMetadata(title: "RAW Photo", cameraRaw: crs)
        try service.saveSidecar(makeSidecar(metadata: metadata), for: imageURL, in: folder)

        let loaded = try #require(service.loadSidecar(for: imageURL, in: folder))
        #expect(loaded.metadata.cameraRaw == nil)
        #expect(loaded.metadata.title == "RAW Photo")
    }

    // MARK: - Pending Changes

    @Test("pendingFieldNames returns changed field names")
    func pendingFieldNamesReturnsChangedFields() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)

        let original = IPTCMetadata(
            title: "Original",
            creator: "Original Creator",
            creatorJobTitle: "Photographer",
            descriptionWriter: "Day Desk"
        )
        let edited = IPTCMetadata(
            title: "Edited Title",
            creator: "Original Creator",
            creatorJobTitle: "Staff Photographer",
            descriptionWriter: "Night Desk"
        )
        let sidecar = MetadataSidecar(
            sourceFile: "photo.jpg",
            pendingChanges: true,
            metadata: edited,
            imageMetadataSnapshot: original
        )
        try service.saveSidecar(sidecar, for: imageURL, in: folder)

        let names = service.pendingFieldNames(for: imageURL, in: folder)
        #expect(names.contains("Headline"))
        #expect(names.contains("Creator Job Title"))
        #expect(names.contains("Description Writer"))
        #expect(!names.contains("Creator"))
    }

    @Test("pendingFieldNames returns empty when no pending changes")
    func pendingFieldNamesEmptyWhenNoPending() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        let metadata = IPTCMetadata(title: "Test")
        let sidecar = MetadataSidecar(
            sourceFile: "photo.jpg",
            pendingChanges: false,
            metadata: metadata,
            imageMetadataSnapshot: metadata
        )
        try service.saveSidecar(sidecar, for: imageURL, in: folder)

        let names = service.pendingFieldNames(for: imageURL, in: folder)
        #expect(names.isEmpty)
    }

    @Test("pendingFieldNames returns empty when no snapshot")
    func pendingFieldNamesEmptyWhenNoSnapshot() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        let sidecar = MetadataSidecar(
            sourceFile: "photo.jpg",
            pendingChanges: true,
            metadata: IPTCMetadata(title: "Test"),
            imageMetadataSnapshot: nil
        )
        try service.saveSidecar(sidecar, for: imageURL, in: folder)

        let names = service.pendingFieldNames(for: imageURL, in: folder)
        #expect(names.isEmpty)
    }

    @Test("imagesWithPendingChanges returns only pending image URLs")
    func imagesWithPendingChangesReturnsOnlyPending() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let pendingURL = folder.appendingPathComponent("pending.jpg")
        let cleanURL = folder.appendingPathComponent("clean.jpg")

        let editedMeta = IPTCMetadata(title: "Edited")
        let originalMeta = IPTCMetadata(title: "Original")

        try service.saveSidecar(MetadataSidecar(
            sourceFile: "pending.jpg",
            pendingChanges: true,
            metadata: editedMeta,
            imageMetadataSnapshot: originalMeta
        ), for: pendingURL, in: folder)

        try service.saveSidecar(MetadataSidecar(
            sourceFile: "clean.jpg",
            pendingChanges: false,
            metadata: originalMeta,
            imageMetadataSnapshot: originalMeta
        ), for: cleanURL, in: folder)

        let pending = await service.imagesWithPendingChanges(in: folder)
        #expect(pending.contains(pendingURL))
        #expect(!pending.contains(cleanURL))
    }

    // MARK: - Delete

    @Test("deleteSidecar removes the sidecar file")
    func deleteSidecarRemovesFile() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        try service.saveSidecar(makeSidecar(), for: imageURL, in: folder)

        #expect(service.loadSidecar(for: imageURL, in: folder) != nil)
        try service.deleteSidecar(for: imageURL, in: folder)
        #expect(service.loadSidecar(for: imageURL, in: folder) == nil)
    }

    @Test("deleteAllSidecars removes the entire .photo_metadata directory")
    func deleteAllSidecarsRemovesDirectory() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL1 = makeImageURL(in: folder, name: "photo1.jpg")
        let imageURL2 = makeImageURL(in: folder, name: "photo2.jpg")
        try service.saveSidecar(makeSidecar(filename: "photo1.jpg"), for: imageURL1, in: folder)
        try service.saveSidecar(makeSidecar(filename: "photo2.jpg"), for: imageURL2, in: folder)

        try service.deleteAllSidecars(in: folder)
        let metaDir = folder.appendingPathComponent(".photo_metadata")
        #expect(!FileManager.default.fileExists(atPath: metaDir.path))
    }

    @Test("deleteSidecar on non-existent is no-op")
    func deleteSidecarNonExistentIsNoOp() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        // Should not throw
        try service.deleteSidecar(for: imageURL, in: folder)
    }

    // MARK: - Rename

    @Test("renameSidecar updates sourceFile and creates sidecar at new path")
    func renameSidecarUpdatesSourceFile() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let oldURL = makeImageURL(in: folder, name: "old.jpg")
        let newURL = makeImageURL(in: folder, name: "new.jpg")
        let metadata = IPTCMetadata(title: "Renamed Photo")
        try service.saveSidecar(makeSidecar(filename: "old.jpg", metadata: metadata), for: oldURL, in: folder)

        try service.renameSidecar(from: oldURL, to: newURL, in: folder)

        let loaded = try #require(service.loadSidecar(for: newURL, in: folder))
        #expect(loaded.sourceFile == "new.jpg")
        #expect(loaded.metadata.title == "Renamed Photo")
        #expect(service.loadSidecar(for: oldURL, in: folder) == nil)
    }

    @Test("renameSidecar on non-existent is no-op")
    func renameSidecarNonExistentIsNoOp() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let oldURL = makeImageURL(in: folder, name: "nonexistent.jpg")
        let newURL = makeImageURL(in: folder, name: "also_nonexistent.jpg")
        // Should not throw
        try service.renameSidecar(from: oldURL, to: newURL, in: folder)
    }

    @Test("rename preserves unknown fields in a newer sidecar")
    func renameNewerSidecarPreservesUnknownFields() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let metadataDirectory = folder.appendingPathComponent(".photo_metadata")
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        let oldSidecarURL = metadataDirectory.appendingPathComponent("old.jpg.meta.json")
        let futureData = Data(
            #"{"schemaVersion":2,"sourceFile":"old.jpg","future":{"nested":[1,2,3]}}"#.utf8
        )
        try futureData.write(to: oldSidecarURL)

        let service = MetadataSidecarService()
        let oldImageURL = makeImageURL(in: folder, name: "old.jpg")
        let newImageURL = makeImageURL(in: folder, name: "new.jpg")
        try service.renameSidecar(from: oldImageURL, to: newImageURL, in: folder)

        let newSidecarURL = metadataDirectory.appendingPathComponent("new.jpg.meta.json")
        #expect(!FileManager.default.fileExists(atPath: oldSidecarURL.path))
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: newSidecarURL)) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["sourceFile"] as? String == "new.jpg")
        let future = try #require(object["future"] as? [String: Any])
        #expect(future["nested"] as? [Int] == [1, 2, 3])
    }

    // MARK: - Corrupt File Handling

    @Test("corrupt sidecar is moved aside and load returns nil")
    func corruptSidecarMovedAside() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)

        // Create the .photo_metadata directory and write corrupt JSON
        let metaDir = folder.appendingPathComponent(".photo_metadata")
        try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        let sidecarURL = metaDir.appendingPathComponent("photo.jpg.meta.json")
        let corruptData = "{ this is not valid json }".data(using: .utf8)!
        try corruptData.write(to: sidecarURL)

        // Should return nil (not crash) and move the file aside
        let result = service.loadSidecar(for: imageURL, in: folder)
        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))

        // Verify a .corrupt backup was created
        let files = try FileManager.default.contentsOfDirectory(at: metaDir, includingPropertiesForKeys: nil)
        let backupFiles = files.filter { $0.lastPathComponent.contains(".corrupt.") }
        #expect(!backupFiles.isEmpty)
    }

    // MARK: - loadAllSidecars

    @Test("loadAllSidecars returns all saved sidecars")
    func loadAllSidecarsReturnsAll() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let url1 = folder.appendingPathComponent("photo1.jpg")
        let url2 = folder.appendingPathComponent("photo2.CR3")

        try service.saveSidecar(makeSidecar(filename: "photo1.jpg", metadata: IPTCMetadata(title: "Photo 1")), for: url1, in: folder)
        try service.saveSidecar(makeSidecar(filename: "photo2.CR3", metadata: IPTCMetadata(title: "Photo 2")), for: url2, in: folder)

        let all = await service.loadAllSidecars(in: folder)
        #expect(all.count == 2)
        #expect(all[url1]?.metadata.title == "Photo 1")
        #expect(all[url2]?.metadata.title == "Photo 2")
    }

    @Test("loadAllSidecars returns empty dict when no metadata directory")
    func loadAllSidecarsEmptyWhenNoDirectory() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let all = await service.loadAllSidecars(in: folder)
        #expect(all.isEmpty)
    }

    @Test("folder monitor observes nested sidecar writes")
    func folderMonitorObservesNestedSidecarWrite() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let probe = FolderEventProbe()
        let monitor = try #require(FolderChangeMonitor(url: folder) { _ in
            Task { await probe.recordEvent() }
        })
        defer { monitor.cancel() }

        // Give the dispatch-backed stream a moment to begin delivery before mutating
        // the directory. The production path naturally has this gap while a folder loads.
        try await Task.sleep(for: .milliseconds(100))
        let metadataFolder = folder.appendingPathComponent(".photo_metadata")
        try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: metadataFolder.appendingPathComponent("photo.jpg.meta.json"))

        #expect(await probe.waitForEvent())
    }

    @Test("folder change routing separates hidden 2.3 stores from browser content")
    func folderChangeRouting() {
        let root = URL(fileURLWithPath: "/tmp/photo-agent-routing", isDirectory: true)
        let analysis = root.appendingPathComponent(
            ".photo_analysis/cases/case.analysis.json"
        )
        let versions = root.appendingPathComponent(
            ".photo_versions/catalogs/source.versions.json"
        )
        let metadata = root.appendingPathComponent(
            ".photo_metadata/photo.jpg.meta.json"
        )
        let image = root.appendingPathComponent("photo.jpg")
        let finderState = root.appendingPathComponent(".DS_Store")

        #expect(impact(paths: [analysis], root: root) == .analysisStore)
        #expect(impact(paths: [versions], root: root) == .versionStore)
        #expect(impact(paths: [metadata], root: root) == .browserContent)
        #expect(impact(paths: [image], root: root) == .browserContent)
        #expect(impact(paths: [finderState], root: root).isEmpty)
        #expect(
            impact(paths: [analysis, versions, image], root: root) == .all
        )
    }

    @Test("dropped folder events conservatively invalidate every store")
    func droppedFolderEventsInvalidateEverything() {
        let root = URL(fileURLWithPath: "/tmp/photo-agent-routing", isDirectory: true)
        let batch = FolderChangeBatch(paths: [], requiresFullRescan: true)

        #expect(
            BrowserFolderChangeImpact.classify(batch, monitoredRoot: root) == .all
        )
    }

    private func impact(
        paths: Set<URL>,
        root: URL
    ) -> BrowserFolderChangeImpact {
        BrowserFolderChangeImpact.classify(
            FolderChangeBatch(paths: paths, requiresFullRescan: false),
            monitoredRoot: root
        )
    }

    // MARK: - Unicode / Special Characters

    @Test("Nordic characters in metadata survive roundtrip")
    func nordicCharactersRoundtrip() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        let metadata = IPTCMetadata(
            title: "Ærø ø Ålesund",
            description: "Bøkenøst i Östersund",
            creator: "Ingvild Ström",
            city: "Tromsø",
            country: "Norge"
        )
        try service.saveSidecar(makeSidecar(metadata: metadata), for: imageURL, in: folder)
        let loaded = try #require(service.loadSidecar(for: imageURL, in: folder))
        #expect(loaded.metadata.title == "Ærø ø Ålesund")
        #expect(loaded.metadata.description == "Bøkenøst i Östersund")
        #expect(loaded.metadata.creator == "Ingvild Ström")
        #expect(loaded.metadata.city == "Tromsø")
    }
}

@Suite("Embedded metadata existing-sidecar mirror")
struct MetadataSidecarMirrorTests {
    @Test("Existence preflight preserves ordering and runs off MainActor")
    @MainActor
    func preflight() async throws {
        let urls = ["one", "absent", "two"].map { URL(fileURLWithPath: "/virtual/\($0).jpg") }
        let service = MetadataSidecarMirrorPreflight { url in
            #expect(!Thread.isMainThread)
            return url != urls[1]
        }
        let result = try await service.existingImageURLs(urls)
        #expect(result == [urls[0], urls[2]])
    }

    @Test("Cancelled preflight performs no existence probes")
    func cancelledPreflight() async {
        let service = MetadataSidecarMirrorPreflight { _ in
            Issue.record("Cancelled preflight touched storage")
            return true
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.existingImageURLs([URL(fileURLWithPath: "/virtual/photo.jpg")])
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Cancellation during a probe does not return a partial preflight")
    func cancellationDuringPreflight() async {
        let service = MetadataSidecarMirrorPreflight { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return true
        }
        let task = Task {
            try await service.existingImageURLs([URL(fileURLWithPath: "/virtual/photo.jpg")])
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation instead of a usable partial result")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Mirror preserves sidecar edits and uses its orientation only when embedded orientation is absent")
    func preservesDevelopAndOrientation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("photo.jpg")
        let service = XMPSidecarService()
        var baseline = IPTCMetadata(title: "Old")
        baseline.exifOrientation = 6
        var edits = CameraRawSettings()
        edits.exposure2012 = 1.25
        baseline.cameraRaw = edits
        try service.saveSidecar(metadata: baseline, for: source)
        var embedded = IPTCMetadata(title: "Read back")
        var embeddedEdits = CameraRawSettings()
        embeddedEdits.exposure2012 = -2
        embedded.cameraRaw = embeddedEdits
        try await service.saveSidecarPreservingDevelopSettingsSerialized(
            metadata: embedded, for: source, onlyIfExisting: true,
            preserveExistingOrientationIfMissing: true
        )
        let first = try #require(service.loadSidecar(for: source))
        #expect(first.title == "Read back")
        #expect(first.exifOrientation == 6)
        #expect(first.cameraRaw?.exposure2012 == 1.25)
        embedded.exifOrientation = 3
        try await service.saveSidecarPreservingDevelopSettingsSerialized(
            metadata: embedded, for: source, onlyIfExisting: true,
            preserveExistingOrientationIfMissing: true
        )
        #expect(service.loadSidecar(for: source)?.exifOrientation == 3)
    }

    @Test("Mirror retry obtains fallback orientation from the latest sidecar revision")
    func retryUsesCurrentOrientation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("photo.jpg")
        let service = XMPSidecarService()
        var baseline = IPTCMetadata(title: "Old")
        baseline.exifOrientation = 6
        try service.saveSidecar(metadata: baseline, for: source)
        try await service.saveSidecarPreservingDevelopSettingsSerialized(
            metadata: IPTCMetadata(title: "Read back"), for: source, onlyIfExisting: true,
            preserveExistingOrientationIfMissing: true,
            beforeRevisionCheck: { attempt in
                guard attempt == 0 else { return }
                var replacement = IPTCMetadata(title: "External")
                replacement.exifOrientation = 8
                try? service.saveSidecar(metadata: replacement, for: source)
            }
        )
        let result = try #require(service.loadSidecar(for: source))
        #expect(result.exifOrientation == 8)
        #expect(result.title == "Read back")
    }

    @Test("Sidecars deleted after preflight are not recreated")
    func deletionAfterPreflight() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("photo.jpg")
        let service = XMPSidecarService()
        try service.saveSidecar(metadata: IPTCMetadata(title: "Old"), for: source)
        let candidates = try await MetadataSidecarMirrorPreflight.shared.existingImageURLs([source])
        #expect(candidates == [source])
        try FileManager.default.removeItem(at: service.sidecarURL(for: source))
        let installed = try await service.saveSidecarPreservingDevelopSettingsSerialized(
            metadata: IPTCMetadata(title: "Read back"), for: source, onlyIfExisting: true,
            preserveExistingOrientationIfMissing: true
        )
        #expect(!installed)
        #expect(!service.sidecarExists(for: source))
    }
}

@Suite("Batch metadata baseline transactions")
struct BatchMetadataBaselineTransactionTests {
    @Test("Pre-cancelled batch transactions neither mutate nor create sidecars")
    func preCancelledTransactions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("cancelled.raw")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await XMPSidecarService().updateSidecarSerialized(
                    for: source, fallback: IPTCMetadata(),
                    mutation: { _ in Issue.record("Cancelled XMP mutation ran") }
                )
                Issue.record("Cancelled XMP transaction succeeded")
            } catch is CancellationError {
            } catch {
                Issue.record("Unexpected XMP error: \(error)")
            }
            do {
                _ = try await MetadataSidecarService().updateMetadataSerialized(
                    for: source, in: directory, fallback: IPTCMetadata(), pendingChanges: true,
                    mutation: { _ in Issue.record("Cancelled JSON mutation ran") }
                )
                Issue.record("Cancelled JSON transaction succeeded")
            } catch is CancellationError {
            } catch {
                Issue.record("Unexpected JSON error: \(error)")
            }
        }
        await task.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("XMP retry reapplies only the requested edit to latest metadata and Develop settings")
    @MainActor
    func xmpRevisionRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("batch.raw")
        let service = XMPSidecarService()
        try service.saveSidecar(metadata: IPTCMetadata(title: "Before"), for: source)
        let installed = try await service.updateSidecarSerialized(
            for: source, fallback: IPTCMetadata(title: "Stale UI"),
            beforeRevisionCheck: { attempt in
                #expect(!Thread.isMainThread)
                guard attempt == 0 else { return }
                var replacement = IPTCMetadata(title: "External")
                replacement.keywords = ["External keyword"]
                var settings = CameraRawSettings()
                settings.exposure2012 = 1.5
                replacement.cameraRaw = settings
                try? service.saveSidecar(metadata: replacement, for: source)
            },
            mutation: { $0.keywords.append("Batch keyword") }
        )
        #expect(installed.title == "External")
        #expect(installed.keywords == ["External keyword", "Batch keyword"])
        #expect(installed.cameraRaw?.exposure2012 == 1.5)
        #expect(service.loadSidecar(for: source)?.keywords == installed.keywords)
    }

    @Test("JSON retry derives history and preserved snapshot from the latest record")
    @MainActor
    func jsonRevisionRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("batch.raw")
        let service = MetadataSidecarService()
        let initial = MetadataSidecar(sourceFile: "batch.raw", metadata: IPTCMetadata(title: "Before"))
        try service.saveSidecar(initial, for: source, in: directory)
        let installed = try await service.updateMetadataSerialized(
            for: source, in: directory, fallback: IPTCMetadata(title: "Stale UI"),
            pendingChanges: true,
            beforeRevisionCheck: { attempt in
                #expect(!Thread.isMainThread)
                guard attempt == 0 else { return }
                let replacement = MetadataSidecar(
                    sourceFile: "batch.raw",
                    metadata: IPTCMetadata(title: "External"),
                    imageMetadataSnapshot: IPTCMetadata(title: "Embedded"),
                    history: [MetadataHistoryEntry(timestamp: Date(timeIntervalSince1970: 1),
                        fieldName: "Headline", oldValue: "Before", newValue: "External")]
                )
                try? service.saveSidecar(replacement, for: source, in: directory)
            },
            mutation: { $0.title = "Batch" }
        )
        #expect(installed.metadata.title == "Batch")
        #expect(installed.imageMetadataSnapshot?.title == "Embedded")
        #expect(installed.history.count == 2)
        #expect(installed.history.last?.oldValue == "External")
        #expect(installed.history.last?.newValue == "Batch")
    }

    @Test("JSON without a sidecar uses resolved per-photo fallback and commits its new snapshot")
    func missingJSONBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("batch.raw")
        let service = MetadataSidecarService()
        var fallback = IPTCMetadata(title: "Unique title")
        fallback.keywords = ["Unique keyword"]
        let installed = try await service.updateMetadataSerialized(
            for: source, in: directory, fallback: fallback, pendingChanges: false,
            mutation: { $0.keywords.append("Batch keyword") }
        )
        #expect(installed.metadata.title == "Unique title")
        #expect(installed.metadata.keywords == ["Unique keyword", "Batch keyword"])
        #expect(installed.imageMetadataSnapshot?.keywords == installed.metadata.keywords)
        #expect(!installed.pendingChanges)
    }
}
