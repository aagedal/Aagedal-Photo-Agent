import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop version catalog")
struct DevelopVersionCatalogTests {
    @Test("snapshot preserves source-bound Develop state and strips render-only state")
    func snapshotPolicyAndDependencies() {
        let maskID = UUID()
        var transform = ColorTransformSettings()
        transform.lutName = "Editorial.cube"
        transform.lutData = Data("LUT bytes".utf8)
        var mask = MaskAdjustment()
        mask.id = maskID
        mask.colorTransform = transform
        mask.aiMask = AIMaskGeometry(width: 2, height: 2, pngData: Data("mask png".utf8))
        let watermarkAssetID = UUID()
        let watermark = WatermarkLayer(libraryAssetID: watermarkAssetID)
        let correction = PreservedMaskCorrection(fields: [
            "crs:FutureField": .string("preserve exactly")
        ])

        var settings = CameraRawSettings()
        settings.version = "15.4"
        settings.processVersion = "15.4"
        settings.exposure2012 = 1.25
        settings.localAdjustments = [mask]
        settings.watermarkLayers = [watermark]
        settings.layerOrder = [.mask(maskID), .global, .watermark(watermark.id)]
        settings.asShotNeutralTemperature = 5_250
        settings.asShotNeutralTint = 7
        settings.sourceHasHDRHeadroom = true
        settings.unparsedMaskCorrections = [correction]

        let snapshot = DevelopVersionSnapshot(settings: settings)

        #expect(snapshot.settings.version == "15.4")
        #expect(snapshot.settings.processVersion == "15.4")
        #expect(snapshot.settings.asShotNeutralTemperature == 5_250)
        #expect(snapshot.settings.asShotNeutralTint == 7)
        #expect(snapshot.settings.unparsedMaskCorrections == [correction])
        #expect(snapshot.settings.sourceHasHDRHeadroom == nil)
        #expect(snapshot.settings.layerOrder == settings.layerOrder)
        #expect(snapshot.validate())
        #expect(Set(snapshot.dependencyManifest.map(\.kind)) == [
            .watermark, .lut, .aiMask, .preservedCorrection
        ])
        #expect(snapshot.dependencyManifest.first(where: {
            $0.kind == .watermark
        })?.identifier == watermarkAssetID.uuidString.lowercased())
        #expect(snapshot.dependencyManifest.filter(\.isEmbedded).count == 3)
        #expect(snapshot.dependencyManifest.filter({ $0.sha256 != nil }).count == 3)
    }

    @Test("catalog CRUD maintains active and default invariants")
    func catalogMutations() async throws {
        let fixture = try VersionCatalogFixture(contents: "source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let start = Date(timeIntervalSince1970: 100)
        var catalog = DevelopVersionCatalog.create(for: revision, now: start)
        var settings = CameraRawSettings()
        settings.exposure2012 = 0.5

        let firstID = try catalog.createVersion(
            name: "  Warm editorial  ",
            settings: settings,
            notes: "  client pick  ",
            appVersion: "2.3",
            appBuild: "500",
            now: Date(timeIntervalSince1970: 110)
        )
        try catalog.setDefaultVersion(firstID, now: Date(timeIntervalSince1970: 111))
        let duplicateID = try catalog.duplicateVersion(
            id: firstID,
            name: "Warm editorial copy",
            appVersion: "2.3",
            appBuild: "501",
            now: Date(timeIntervalSince1970: 120)
        )
        try catalog.renameVersion(
            id: duplicateID,
            name: "Cool editorial",
            now: Date(timeIntervalSince1970: 130)
        )

        #expect(catalog.versions.map(\.name) == ["Warm editorial", "Cool editorial"])
        #expect(catalog.versions.first?.notes == "client pick")
        #expect(catalog.activeVersionID == duplicateID)
        #expect(catalog.defaultVersionID == firstID)
        #expect(catalog.versions.first?.summary == "Global")
        let deletedFirst = catalog.deleteVersion(
            id: firstID,
            now: Date(timeIntervalSince1970: 140)
        )
        #expect(deletedFirst)
        #expect(catalog.defaultVersionID == nil)
        let deletedAgain = catalog.deleteVersion(id: firstID)
        #expect(!deletedAgain)
        try catalog.setActiveVersion(nil, now: Date(timeIntervalSince1970: 150))
        #expect(catalog.activeVersionID == nil)
        try catalog.validateForPersistence()

        #expect(throws: DevelopVersionCatalogMutationError.invalidName) {
            _ = try catalog.createVersion(name: "  ", settings: settings)
        }
        #expect(throws: DevelopVersionCatalogMutationError.versionNotFound) {
            try catalog.setDefaultVersion(UUID())
        }
    }

    @Test("repository atomically round-trips without writing XMP")
    func repositoryRoundTripAndBackupRecovery() async throws {
        let fixture = try VersionCatalogFixture(contents: "source bytes")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let repository = DevelopVersionCatalogRepository(sourceFolderURL: fixture.directoryURL)
        var catalog = DevelopVersionCatalog.create(
            for: revision,
            now: Date(timeIntervalSince1970: 100)
        )
        _ = try catalog.createVersion(
            name: "First",
            settings: CameraRawSettings(),
            appVersion: "2.3",
            appBuild: "500",
            now: Date(timeIntervalSince1970: 110)
        )
        try await repository.save(catalog)
        try catalog.renameVersion(
            id: try #require(catalog.activeVersionID),
            name: "Second",
            now: Date(timeIntervalSince1970: 120)
        )
        try await repository.save(catalog)

        let catalogURL = fixture.catalogURL(for: revision)
        #expect(FileManager.default.fileExists(atPath: catalogURL.path))
        #expect(FileManager.default.fileExists(atPath: catalogURL.appendingPathExtension("backup").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.xmpURL.path))

        try Data("{".utf8).write(to: catalogURL)
        let match = await repository.loadMostRelevantCatalog(for: revision)
        guard case .exact(let recovered, let source, let storage) = match else {
            Issue.record("Expected backup recovery for the exact source")
            return
        }
        #expect(source == .backup)
        #expect(storage == .folderLocal)
        #expect(recovered.versions.first?.name == "First")
    }

    @Test("repository surfaces changed source catalogs without reassociation")
    func changedSource() async throws {
        let fixture = try VersionCatalogFixture(contents: "before")
        defer { fixture.remove() }
        let originalRevision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let repository = DevelopVersionCatalogRepository(sourceFolderURL: fixture.directoryURL)
        let catalog = DevelopVersionCatalog.create(for: originalRevision)
        try await repository.save(catalog)

        try Data("after with different bytes".utf8).write(to: fixture.fileURL)
        let changedRevision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let match = await repository.loadMostRelevantCatalog(for: changedRevision)

        guard case .sourceChanged(let reopened, _, let storage) = match else {
            Issue.record("Expected the old catalog to remain source-bound")
            return
        }
        #expect(storage == .folderLocal)
        #expect(reopened.source.sha256 == originalRevision.sha256)
        #expect(reopened.source.relationship(to: changedRevision) == .sameFileChanged)
    }

    @Test("newer catalog schema opens as intact read-only bytes")
    func newerSchemaIsReadOnly() async throws {
        let fixture = try VersionCatalogFixture(contents: "source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let catalogURL = fixture.catalogURL(for: revision)
        try FileManager.default.createDirectory(
            at: catalogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let future = Data(#"{"schemaVersion":2,"future":true}"#.utf8)
        try future.write(to: catalogURL)

        let repository = DevelopVersionCatalogRepository(sourceFolderURL: fixture.directoryURL)
        let match = await repository.loadMostRelevantCatalog(for: revision)
        guard case .newerSchema(
            let schemaVersion,
            let data,
            let source,
            let storage
        ) = match else {
            Issue.record("Expected a read-only newer catalog")
            return
        }
        #expect(schemaVersion == 2)
        #expect(data == future)
        #expect(source == .primary)
        #expect(storage == .folderLocal)

        let currentCatalog = DevelopVersionCatalog.create(for: revision)
        await #expect(throws: AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
            found: 2,
            supported: 1
        )) {
            try await repository.save(currentCatalog)
        }
    }

    @Test("read-only photo folder falls back to indexed Application Support storage")
    func readOnlyFolderFallback() async throws {
        let fixture = try VersionCatalogFixture(contents: "source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let applicationSupportURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-version-support-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: fixture.directoryURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.directoryURL.path
            )
        }

        let repository = DevelopVersionCatalogRepository(
            sourceFolderURL: fixture.directoryURL,
            applicationSupportURL: applicationSupportURL
        )
        let catalog = DevelopVersionCatalog.create(for: revision)
        let storage = try await repository.save(catalog)

        #expect(storage == .applicationSupport)
        #expect(storage.portabilityWarning != nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.catalogURL(for: revision).path))
        let fallbackRoot = applicationSupportURL
            .appendingPathComponent("DevelopVersions", isDirectory: true)
        let fallbackCatalogURL = fallbackRoot
            .appendingPathComponent("catalogs", isDirectory: true)
            .appendingPathComponent("\(revision.sha256).versions.json")
        #expect(FileManager.default.fileExists(atPath: fallbackCatalogURL.path))
        let indexURL = fallbackRoot.appendingPathComponent("index.versions.json")
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
        let indexObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
        )
        let entries = try #require(indexObject["entries"] as? [[String: Any]])
        let indexedSource = try #require(entries.first?["source"] as? [String: Any])
        #expect(indexedSource["sha256"] as? String == revision.sha256)
        #expect(entries.first?["catalogFilename"] as? String
            == "\(revision.sha256).versions.json")

        let match = await repository.loadMostRelevantCatalog(for: revision)
        guard case .exact(_, _, let loadedStorage) = match else {
            Issue.record("Expected the Application Support catalog to load")
            return
        }
        #expect(loadedStorage == .applicationSupport)
    }
}

private struct VersionCatalogFixture {
    let directoryURL: URL
    let fileURL: URL

    init(contents: String) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-develop-versions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        fileURL = directoryURL.appendingPathComponent("source.raw")
        try Data(contents.utf8).write(to: fileURL)
    }

    var xmpURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    func catalogURL(for revision: SourceImageRevision) -> URL {
        directoryURL
            .appendingPathComponent(".photo_versions/catalogs", isDirectory: true)
            .appendingPathComponent("\(revision.sha256).versions.json")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
