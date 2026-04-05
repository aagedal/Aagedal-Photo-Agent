import Testing
import Foundation
@testable import Aagedal_Photo_Agent

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

    // MARK: - Save & Load

    @Test("save then load returns equivalent sidecar")
    func saveAndLoadRoundtrip() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let imageURL = makeImageURL(in: folder)
        let metadata = IPTCMetadata(title: "Test Photo", keywords: ["nature"], creator: "Photographer")
        let sidecar = makeSidecar(filename: "photo.jpg", metadata: metadata)

        try service.saveSidecar(sidecar, for: imageURL, in: folder)
        let loaded = try #require(service.loadSidecar(for: imageURL, in: folder))

        #expect(loaded.metadata.title == "Test Photo")
        #expect(loaded.metadata.keywords == ["nature"])
        #expect(loaded.metadata.creator == "Photographer")
        #expect(loaded.sourceFile == "photo.jpg")
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
        #expect(loaded.lastModified >= before)
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

        let original = IPTCMetadata(title: "Original", creator: "Original Creator")
        let edited = IPTCMetadata(title: "Edited Title", creator: "Original Creator")
        let sidecar = MetadataSidecar(
            sourceFile: "photo.jpg",
            pendingChanges: true,
            metadata: edited,
            imageMetadataSnapshot: original
        )
        try service.saveSidecar(sidecar, for: imageURL, in: folder)

        let names = service.pendingFieldNames(for: imageURL, in: folder)
        #expect(names.contains("Headline"))
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
    func imagesWithPendingChangesReturnsOnlyPending() throws {
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

        let pending = service.imagesWithPendingChanges(in: folder)
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
    func loadAllSidecarsReturnsAll() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let url1 = folder.appendingPathComponent("photo1.jpg")
        let url2 = folder.appendingPathComponent("photo2.CR3")

        try service.saveSidecar(makeSidecar(filename: "photo1.jpg", metadata: IPTCMetadata(title: "Photo 1")), for: url1, in: folder)
        try service.saveSidecar(makeSidecar(filename: "photo2.CR3", metadata: IPTCMetadata(title: "Photo 2")), for: url2, in: folder)

        let all = service.loadAllSidecars(in: folder)
        #expect(all.count == 2)
        #expect(all[url1]?.metadata.title == "Photo 1")
        #expect(all[url2]?.metadata.title == "Photo 2")
    }

    @Test("loadAllSidecars returns empty dict when no metadata directory")
    func loadAllSidecarsEmptyWhenNoDirectory() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = MetadataSidecarService()
        let all = service.loadAllSidecars(in: folder)
        #expect(all.isEmpty)
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
