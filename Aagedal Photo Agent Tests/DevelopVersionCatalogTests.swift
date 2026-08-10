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

    @Test("switch preparation snapshots the version being left and keeps Primary virtual")
    func switchPreparationIsAtomic() async throws {
        let fixture = try VersionCatalogFixture(contents: "source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var catalog = DevelopVersionCatalog.create(
            for: revision,
            now: Date(timeIntervalSince1970: 100)
        )

        var originalNamedSettings = CameraRawSettings()
        originalNamedSettings.exposure2012 = 0.5
        let namedID = try catalog.createVersion(
            name: "Editorial",
            settings: originalNamedSettings,
            now: Date(timeIntervalSince1970: 110)
        )

        var editedNamedSettings = originalNamedSettings
        editedNamedSettings.exposure2012 = 1.25
        var primarySettings = CameraRawSettings()
        primarySettings.contrast2012 = 12

        let resolvedPrimary = try catalog.prepareSwitch(
            to: nil,
            savingCurrentSettings: editedNamedSettings,
            primarySettings: primarySettings,
            now: Date(timeIntervalSince1970: 120)
        )

        #expect(catalog.activeVersionID == nil)
        #expect(catalog.versions.count == 1)
        #expect(catalog.versions.first?.id == namedID)
        #expect(catalog.versions.first?.snapshot.settings.exposure2012 == 1.25)
        #expect(resolvedPrimary?.contrast2012 == 12)

        let restoredNamed = try catalog.prepareSwitch(
            to: namedID,
            savingCurrentSettings: primarySettings,
            primarySettings: primarySettings,
            now: Date(timeIntervalSince1970: 130)
        )
        #expect(catalog.activeVersionID == namedID)
        #expect(restoredNamed?.exposure2012 == 1.25)

        let beforeInvalidSwitch = catalog
        #expect(throws: DevelopVersionCatalogMutationError.versionNotFound) {
            _ = try catalog.prepareSwitch(
                to: UUID(),
                savingCurrentSettings: restoredNamed,
                primarySettings: primarySettings
            )
        }
        #expect(catalog == beforeInvalidSwitch)
    }

    @Test("flush coordinator forwards failures and token-owns the active registration")
    func flushCoordinatorRegistration() async {
        let coordinator = DevelopVersionFlushCoordinator()
        var receivedReasons: [DevelopVersionFlushReason] = []
        let staleID = coordinator.register { reason in
            receivedReasons.append(reason)
            return .failed("read only")
        }

        let failure = await coordinator.flush(.imageNavigation)
        #expect(failure == .failed("read only"))
        #expect(receivedReasons == [.imageNavigation])

        let activeID = coordinator.register { reason in
            receivedReasons.append(reason)
            return .succeeded
        }
        coordinator.unregister(staleID)
        #expect(coordinator.hasRegisteredHandler)
        #expect(await coordinator.flush(.applicationTermination) == .succeeded)
        #expect(receivedReasons == [.imageNavigation, .applicationTermination])

        coordinator.unregister(activeID)
        #expect(!coordinator.hasRegisteredHandler)
        #expect(await coordinator.flush(.workspaceExit) == .succeeded)
    }

    @Test("catalog JSON round-trips every current Develop layer and effect family")
    func everyCurrentLayerAndEffectRoundTrips() async throws {
        let fixture = try VersionCatalogFixture(contents: "complete settings source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(
            at: fixture.fileURL,
            pixelWidth: 6_048,
            pixelHeight: 4_024,
            exifOrientation: 1
        )
        let repository = DevelopVersionCatalogRepository(sourceFolderURL: fixture.directoryURL)
        var catalog = DevelopVersionCatalog.create(for: revision)
        var settings = everyCurrentEffectSettings()
        let expectedLayerKinds: [LayerKind] = [
            .ellipseMask,
            .rectangleMask,
            .brushMask,
            .aiMask,
            .secondaryGlobal,
            .colorTransform,
            .colorTransform
        ]
        #expect(settings.localAdjustments?.map(\.layerKind) == expectedLayerKinds)
        #expect(settings.watermarkLayers?.map(\.layerKind) == [.watermark])
        let expectedOrder = settings.layerOrder
        settings.sourceHasHDRHeadroom = true
        _ = try catalog.createVersion(name: "Everything", settings: settings)

        try await repository.save(catalog)
        let match = await repository.loadMostRelevantCatalog(for: revision)
        guard case .exact(let decoded, _, _) = match,
              let snapshot = decoded.versions.first?.snapshot else {
            Issue.record("Expected the complete catalog to round-trip")
            return
        }

        var expectedSettings = settings
        expectedSettings.sourceHasHDRHeadroom = nil
        #expect(snapshot.settings == expectedSettings)
        #expect(snapshot.settings.localAdjustments?.map(\.layerKind) == expectedLayerKinds)
        #expect(snapshot.settings.watermarkLayers?.map(\.layerKind) == [.watermark])
        #expect(snapshot.settings.layerOrder == expectedOrder)
        #expect(snapshot.settings.resolvedLayerOrder() == expectedOrder)
        #expect(Set(snapshot.dependencyManifest.map(\.kind)) == [
            .watermark, .lut, .aiMask, .preservedCorrection
        ])
        #expect(snapshot.validate())
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

    @Test("renamed exact bytes refresh source hints after hash-verified discovery")
    func renamedSourceReassociation() async throws {
        let fixture = try VersionCatalogFixture(contents: "same source bytes")
        defer { fixture.remove() }
        let originalRevision = try await SourceImageRevision.capture(
            at: fixture.fileURL,
            pixelWidth: 6_000,
            pixelHeight: 4_000,
            exifOrientation: 1
        )
        let repository = DevelopVersionCatalogRepository(sourceFolderURL: fixture.directoryURL)
        let catalog = DevelopVersionCatalog.create(for: originalRevision)
        try await repository.save(catalog)

        let renamedURL = fixture.directoryURL.appendingPathComponent("renamed.raw")
        try FileManager.default.moveItem(at: fixture.fileURL, to: renamedURL)

        let discovery = try await repository.discoverSource(
            for: catalog,
            among: [renamedURL]
        )
        guard case .located(let renamedRevision, let method) = discovery else {
            Issue.record("Expected hash-verified source discovery after rename")
            return
        }
        #expect(method == .fileResourceIdentifier || method == .contentHash)

        let result = try await repository.reassociate(catalog, to: renamedRevision)
        #expect(!result.preservedOriginalCatalog)
        #expect(result.catalog.source.sha256 == originalRevision.sha256)
        #expect(result.catalog.source.canonicalURL == renamedURL.standardizedFileURL)

        let match = await repository.loadMostRelevantCatalog(for: renamedRevision)
        guard case .exact(let refreshed, _, _) = match else {
            Issue.record("Expected the relocated source to reopen its catalog")
            return
        }
        #expect(refreshed.source.canonicalURL == renamedURL.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: fixture.catalogURL(for: originalRevision).path))
    }

    @Test("changed-source reassociation gates geometry and preserves the old catalog")
    func changedSourceReassociationPreservesOriginal() async throws {
        let fixture = try VersionCatalogFixture(contents: "old source bytes")
        defer { fixture.remove() }
        let originalRevision = try await SourceImageRevision.capture(
            at: fixture.fileURL,
            pixelWidth: 6_000,
            pixelHeight: 4_000,
            exifOrientation: 1
        )
        let repository = DevelopVersionCatalogRepository(sourceFolderURL: fixture.directoryURL)
        var catalog = DevelopVersionCatalog.create(for: originalRevision)
        var settings = CameraRawSettings()
        settings.crop = CameraRawCrop(
            top: 0.1,
            left: 0.2,
            bottom: 0.9,
            right: 0.8,
            angle: 0,
            hasCrop: true
        )
        _ = try catalog.createVersion(name: "Crop", settings: settings)
        try await repository.save(catalog)

        try Data("replacement source bytes".utf8).write(to: fixture.fileURL)
        let changedRevision = try await SourceImageRevision.capture(
            at: fixture.fileURL,
            pixelWidth: 4_000,
            pixelHeight: 6_000,
            exifOrientation: 6
        )

        #expect(catalog.geometryCompatibility(with: changedRevision) == .requiresExplicitChoice)
        await #expect(throws: DevelopVersionCatalogReassociationError.geometryRequiresExplicitChoice) {
            try await repository.reassociate(catalog, to: changedRevision)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.catalogURL(for: changedRevision).path))

        let result = try await repository.reassociate(
            catalog,
            to: changedRevision,
            geometryChoice: .keepNormalizedCoordinates
        )
        #expect(result.preservedOriginalCatalog)
        #expect(result.catalog.source.sha256 == changedRevision.sha256)
        #expect(result.catalog.versions == catalog.versions)
        #expect(FileManager.default.fileExists(atPath: fixture.catalogURL(for: originalRevision).path))
        #expect(FileManager.default.fileExists(atPath: fixture.catalogURL(for: changedRevision).path))

        let oldCatalogs = await repository.loadAllCatalogs()
        #expect(Set(oldCatalogs.map(\.source.sha256)) == [
            originalRevision.sha256,
            changedRevision.sha256
        ])
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

private func everyCurrentEffectSettings() -> CameraRawSettings {
    var settings = CameraRawSettings()
    settings.version = "15.4"
    settings.processVersion = "15.4"
    settings.whiteBalance = "Custom"
    settings.temperature = 5_400
    settings.tint = 8
    settings.incrementalTemperature = 3
    settings.incrementalTint = -2
    settings.exposure2012 = 0.65
    settings.contrast2012 = 12
    settings.highlights2012 = -24
    settings.shadows2012 = 18
    settings.whites2012 = 7
    settings.blacks2012 = -9
    settings.saturation = 5
    settings.vibrance = 14
    settings.globalDensity = 88
    settings.sharpness = 31
    settings.clarity2012 = 11
    settings.dehaze = 6
    settings.hasSettings = true
    settings.crop = CameraRawCrop(
        top: 0.08,
        left: 0.12,
        bottom: 0.91,
        right: 0.87,
        angle: -2.5,
        hasCrop: true
    )
    settings.hdrEditMode = 1
    settings.hdrMaxValue = "4"
    settings.sdrBrightness = 9
    settings.sdrContrast = 4
    settings.sdrClarity = 3
    settings.sdrHighlights = -7
    settings.sdrShadows = 8
    settings.sdrWhites = 2
    settings.sdrBlend = 35
    settings.toneCurve = ToneCurve(
        master: [ToneCurvePoint(x: 0, y: 0.02), ToneCurvePoint(x: 1, y: 0.98)],
        red: [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 0.96)],
        green: [ToneCurvePoint(x: 0, y: 0.01), ToneCurvePoint(x: 1, y: 1)],
        blue: [ToneCurvePoint(x: 0, y: 0.03), ToneCurvePoint(x: 1, y: 0.97)]
    )
    settings.hslAdjustments = HSLAdjustments(
        red: HSLColorAdjustment(saturation: 1, luminance: 2, hueShift: 3),
        yellow: HSLColorAdjustment(saturation: 4, luminance: 5, hueShift: 6),
        green: HSLColorAdjustment(saturation: 7, luminance: 8, hueShift: 9),
        cyan: HSLColorAdjustment(saturation: 10, luminance: 11, hueShift: 12),
        blue: HSLColorAdjustment(saturation: 13, luminance: 14, hueShift: 15),
        magenta: HSLColorAdjustment(saturation: 16, luminance: 17, hueShift: 18),
        skinTone: HSLColorAdjustment(saturation: 19, luminance: 20, hueShift: 21)
    )
    settings.anonymizer = AnonymizerSettings(amount: 62, blackOut: false)
    settings.filmEmulation = FilmEmulationSettings(
        grain: 28,
        grainCoarseness: 44,
        halation: 17,
        bloom: 13,
        vignette: -32,
        edgeBlur: 9
    )
    settings.asShotNeutralTemperature = 5_215
    settings.asShotNeutralTint = 6.5
    settings.unparsedMaskCorrections = [PreservedMaskCorrection(fields: [
        "crs:String": .string("future"),
        "crs:Strings": .strings(["one", "two"]),
        "crs:Structure": .structure(["crs:Nested": .string("value")]),
        "crs:Items": .items([["crs:Item": .string("payload")]])
    ])]

    var ellipseGeometry = EllipseMaskGeometry()
    ellipseGeometry.centerX = 0.35
    ellipseGeometry.centerY = 0.45
    ellipseGeometry.radiusX = 0.2
    ellipseGeometry.radiusY = 0.12
    ellipseGeometry.rotation = 8
    ellipseGeometry.feather = 42
    var ellipse = MaskAdjustment(name: "Ellipse", geometry: ellipseGeometry)
    ellipse.inverted = true
    ellipse.amount = 0.82
    ellipse.exposure = 0.4
    ellipse.contrast = 8
    ellipse.highlights = -12
    ellipse.shadows = 14
    ellipse.whites = 3
    ellipse.blacks = -5
    ellipse.saturation = 7
    ellipse.vibrance = 9
    ellipse.temperature = 4.5
    ellipse.tint = -2.5
    ellipse.anonymizer = AnonymizerSettings(amount: 35, blackOut: true)

    var rectangleGeometry = EllipseMaskGeometry()
    rectangleGeometry.cornerRadius = 0.25
    let rectangle = MaskAdjustment(name: "Rounded rectangle", geometry: rectangleGeometry)

    let brush = MaskAdjustment(
        name: "Brush",
        brush: BrushMaskGeometry(strokes: [BrushStroke(
            dabs: [BrushDab(x: 0.2, y: 0.3, flow: 0.7, hardness: 0.8)],
            radius: 0.04,
            density: 0.9,
            erase: false
        )]),
        exposure: -0.3
    )

    let aiMask = MaskAdjustment(
        name: "AI subject",
        aiMask: AIMaskGeometry(
            width: 2,
            height: 2,
            pngData: Data("raster mask".utf8),
            sourceOrientation: 1,
            displayOrientation: 6,
            target: .person,
            blackPoint: 0.1,
            whitePoint: 0.9,
            blurRadius: 0.005
        ),
        shadows: 20
    )

    var secondaryGlobal = MaskAdjustment(name: "Global 2", fullFrame: true)
    secondaryGlobal.geometry.radiusX = 2
    secondaryGlobal.geometry.radiusY = 2
    secondaryGlobal.exposure = -0.2

    var lut = MaskAdjustment(name: "LUT", amount: 0.75, fullFrame: true)
    lut.colorTransform = ColorTransformSettings(
        mode: .lut,
        lutName: "Editorial.cube",
        lutData: Data("LUT_3D_SIZE 2".utf8),
        inputSpace: .linearSRGB,
        outputSpace: .linearDisplayP3
    )

    var cst = MaskAdjustment(name: "CST", amount: 0.6, fullFrame: true)
    cst.colorTransform = ColorTransformSettings(
        mode: .cst,
        inputSpace: .linearRec2020,
        outputSpace: .linearAdobeRGB
    )

    let watermark = WatermarkLayer(
        name: "Credit",
        libraryAssetID: UUID(),
        geometry: WatermarkGeometry(
            centerX: 0.8,
            centerY: 0.85,
            sizeDimension: .height,
            sizeUnit: .pixel,
            sizeValue: 320,
            marginUnit: .percent,
            marginValue: 4
        ),
        opacity: 0.72
    )

    settings.localAdjustments = [
        ellipse, rectangle, brush, aiMask, secondaryGlobal, lut, cst
    ]
    settings.watermarkLayers = [watermark]
    settings.layerOrder = [
        .mask(lut.id),
        .global,
        .mask(ellipse.id),
        .mask(rectangle.id),
        .mask(brush.id),
        .mask(aiMask.id),
        .mask(secondaryGlobal.id),
        .mask(cst.id),
        .watermark(watermark.id)
    ]
    return settings
}
