import CoreGraphics
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Analysis case")
struct AnalysisCaseTests {
    @Test("linked map markers share photo annotation names with numbered suffixes")
    func linkedMapMarkerNames() {
        let firstPhotoAnnotation = AnalysisAnnotation(
            kind: .label,
            geometry: .anchor(AnalysisNormalizedPoint(x: 0.2, y: 0.3)),
            text: "  Doorway  "
        )
        let secondPhotoAnnotation = AnalysisAnnotation(
            kind: .rectangle,
            geometry: .bounds(AnalysisNormalizedBounds(
                minimum: AnalysisNormalizedPoint(x: 0.1, y: 0.1),
                maximum: AnalysisNormalizedPoint(x: 0.4, y: 0.4)
            ))
        )
        let coordinate = AnalysisGeoCoordinate(latitude: 59.91, longitude: 10.75)
        var markers = [
            AnalysisMapAnnotation(
                kind: .marker,
                geometry: .point(coordinate),
                text: "Old name",
                linkedPhotoLabelID: firstPhotoAnnotation.id
            ),
            AnalysisMapAnnotation(
                kind: .marker,
                geometry: .point(coordinate),
                linkedPhotoLabelID: firstPhotoAnnotation.id
            ),
            AnalysisMapAnnotation(
                kind: .line,
                geometry: .segment(
                    start: coordinate,
                    end: AnalysisGeoCoordinate(latitude: 59.92, longitude: 10.76)
                ),
                text: "Linked line name stays independent",
                linkedPhotoLabelID: firstPhotoAnnotation.id
            ),
            AnalysisMapAnnotation(
                kind: .marker,
                geometry: .point(coordinate),
                linkedPhotoLabelID: secondPhotoAnnotation.id
            ),
            AnalysisMapAnnotation(
                kind: .marker,
                geometry: .point(coordinate),
                linkedPhotoLabelID: firstPhotoAnnotation.id
            )
        ]

        let changed = AnalysisLinkedMapMarkerNaming.normalize(
            &markers,
            using: [firstPhotoAnnotation, secondPhotoAnnotation],
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(changed)
        #expect(markers.map(\.text) == [
            "Doorway",
            "Doorway 2",
            "Linked line name stays independent",
            "Rectangle 2",
            "Doorway 3"
        ])

        markers.removeFirst()
        AnalysisLinkedMapMarkerNaming.normalize(
            &markers,
            using: [firstPhotoAnnotation, secondPhotoAnnotation],
            now: Date(timeIntervalSince1970: 200)
        )
        #expect(markers[0].text == "Doorway")
        #expect(markers[3].text == "Doorway 2")
    }

    @Test("map annotation copies receive new identities and preserve destination-compatible links")
    func copiesMapAnnotationsBetweenPhotoAndGlobalOwners() throws {
        let caseID = UUID()
        let photoAnnotationID = UUID()
        let source = AnalysisMapAnnotation(
            kind: .marker,
            geometry: .point(AnalysisGeoCoordinate(latitude: 59.91, longitude: 10.75)),
            text: "Subject location",
            style: AnalysisMapAnnotationStyle(
                color: .palette(.cyan),
                lineWidthPoints: 3,
                fillOpacity: 0.25
            ),
            isVisible: false,
            linkedPhotoLabelID: photoAnnotationID,
            now: Date(timeIntervalSince1970: 10)
        )

        let globalCopy = source.copiedToGlobal(
            caseID: caseID,
            now: Date(timeIntervalSince1970: 20)
        )
        #expect(globalCopy.id != source.id)
        #expect(globalCopy.annotation.geometry == source.geometry)
        #expect(globalCopy.annotation.text == source.text)
        #expect(globalCopy.annotation.style == source.style)
        #expect(globalCopy.annotation.isVisible == source.isVisible)
        #expect(globalCopy.annotation.linkedPhotoLabelID == nil)
        #expect(globalCopy.photoAnnotationReferences == [
            AnalysisPhotoAnnotationReference(
                caseID: caseID,
                annotationID: photoAnnotationID
            )
        ])

        let photoCopy = globalCopy.copiedToPhoto(
            caseID: caseID,
            now: Date(timeIntervalSince1970: 30)
        )
        #expect(photoCopy.id != globalCopy.id)
        #expect(photoCopy.geometry == source.geometry)
        #expect(photoCopy.text == source.text)
        #expect(photoCopy.style == source.style)
        #expect(photoCopy.isVisible == source.isVisible)
        #expect(photoCopy.linkedPhotoLabelID == photoAnnotationID)
        #expect(photoCopy.createdAt == Date(timeIntervalSince1970: 30))
        try photoCopy.validate()
    }

    @Test("new cases are source-bound and default to original Pixel Analysis")
    func createsSourceBoundCase() async throws {
        let fixture = try AnalysisFixture(contents: "original")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)

        let analysisCase = AnalysisCase.create(
            for: revision,
            appBuild: "test",
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(analysisCase.schemaVersion == 9)
        #expect(analysisCase.source == revision)
        #expect(analysisCase.workspaceMode == .pixelAnalysis)
        #expect(analysisCase.displayPreference == .original)
        #expect(analysisCase.annotations.isEmpty)
        #expect(analysisCase.timestampEvidence.isEmpty)
        #expect(analysisCase.observations.isEmpty)
        #expect(analysisCase.mapState == AnalysisMapState())
        #expect(analysisCase.createdByAppBuild == "test")
        try analysisCase.validateForPersistence()
    }

    @Test("repository reopens the exact source revision without changing source bytes")
    func persistsAndReopensExactRevision() async throws {
        let fixture = try AnalysisFixture(contents: "source bytes")
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.fileURL)
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        let analysisCase = AnalysisCase.create(for: revision, appBuild: "test")

        try await repository.save(analysisCase)
        let match = await repository.loadMostRelevantCase(for: revision)

        guard case .exact(let reopened) = match else {
            Issue.record("Expected the exact persisted source revision")
            return
        }
        #expect(reopened.id == analysisCase.id)
        #expect(reopened.source.relationship(to: revision) == .exactRevision)
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.fileURL.deletingPathExtension().appendingPathExtension("xmp").path
        ))
    }

    @Test("read-only photo folders use indexed Application Support case storage")
    func readOnlyFolderCaseFallback() async throws {
        let fixture = try AnalysisFixture(contents: "read-only source")
        defer { fixture.remove() }
        let applicationSupportURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-analysis-support-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
        let sourceBefore = try Data(contentsOf: fixture.fileURL)
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let repository = AnalysisCaseRepository(
            sourceFolderURL: fixture.directoryURL,
            applicationSupportURL: applicationSupportURL,
            sourceFolderIsWritable: false
        )

        let storage = try await repository.save(analysisCase)

        #expect(storage == .applicationSupport)
        #expect(storage.portabilityWarning?.contains("will not automatically travel") == true)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directoryURL
                .appendingPathComponent(".photo_analysis/cases", isDirectory: true)
                .appendingPathComponent(
                    "\(analysisCase.id.uuidString.lowercased()).analysis.json"
                ).path
        ))
        let fallbackRoot = applicationSupportURL
            .appendingPathComponent("AnalysisCases", isDirectory: true)
        #expect(FileManager.default.fileExists(
            atPath: fallbackRoot
                .appendingPathComponent("cases", isDirectory: true)
                .appendingPathComponent(
                    "\(analysisCase.id.uuidString.lowercased()).analysis.json"
                ).path
        ))
        let indexURL = fallbackRoot.appendingPathComponent("index.analysis.json")
        let indexObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
        )
        let entries = try #require(indexObject["cases"] as? [[String: Any]])
        let indexedSource = try #require(entries.first?["source"] as? [String: Any])
        #expect(indexedSource["sha256"] as? String == revision.sha256)

        let reopenedRepository = AnalysisCaseRepository(
            sourceFolderURL: fixture.directoryURL,
            applicationSupportURL: applicationSupportURL,
            sourceFolderIsWritable: false
        )
        let load = await reopenedRepository.loadMostRelevantCaseWithStorage(for: revision)
        guard case .exact(let reopened) = load.match else {
            Issue.record("Expected the fallback case to reopen after repository recreation")
            return
        }
        #expect(reopened.id == analysisCase.id)
        #expect(load.storage == .applicationSupport)
        #expect(try Data(contentsOf: fixture.fileURL) == sourceBefore)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.fileURL.deletingPathExtension().appendingPathExtension("xmp").path
        ))
    }

    @Test("read-only folder map storage reopens from Application Support")
    func readOnlyFolderMapFallback() async throws {
        let fixture = try AnalysisFixture(contents: "folder map source")
        defer { fixture.remove() }
        let applicationSupportURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-analysis-map-support-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
        let repository = AnalysisCaseRepository(
            sourceFolderURL: fixture.directoryURL,
            applicationSupportURL: applicationSupportURL,
            sourceFolderIsWritable: false
        )
        var document = AnalysisFolderMapDocument.create(now: Date(timeIntervalSince1970: 1))
        document.setAnnotation(AnalysisGlobalMapAnnotation(annotation: AnalysisMapAnnotation(
            kind: .marker,
            geometry: .point(AnalysisGeoCoordinate(latitude: 59.91, longitude: 10.75)),
            text: "Shared landmark",
            now: Date(timeIntervalSince1970: 2)
        )), now: Date(timeIntervalSince1970: 2))

        let storage = try await repository.saveFolderMapDocument(document)
        let reopenedRepository = AnalysisCaseRepository(
            sourceFolderURL: fixture.directoryURL,
            applicationSupportURL: applicationSupportURL,
            sourceFolderIsWritable: false
        )
        let load = await reopenedRepository.loadFolderMapDocumentWithStorage()

        #expect(storage == .applicationSupport)
        #expect(load.storage == .applicationSupport)
        #expect(load.document == document)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directoryURL
                .appendingPathComponent(".photo_analysis/folder-map.analysis.json").path
        ))
    }

    @Test("folder-local analysis wins an equal fallback revision when writing resumes")
    func folderLocalPreferredAfterFallback() async throws {
        let fixture = try AnalysisFixture(contents: "portable source")
        defer { fixture.remove() }
        let applicationSupportURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-analysis-preference-support-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let analysisCase = AnalysisCase.create(for: revision, appBuild: "test")

        let fallbackRepository = AnalysisCaseRepository(
            sourceFolderURL: fixture.directoryURL,
            applicationSupportURL: applicationSupportURL,
            sourceFolderIsWritable: false
        )
        #expect(try await fallbackRepository.save(analysisCase) == .applicationSupport)

        let writableRepository = AnalysisCaseRepository(
            sourceFolderURL: fixture.directoryURL,
            applicationSupportURL: applicationSupportURL,
            sourceFolderIsWritable: true
        )
        #expect(try await writableRepository.save(analysisCase) == .folderLocal)
        let load = await writableRepository.loadMostRelevantCaseWithStorage(for: revision)
        #expect(load.storage == .folderLocal)
    }

    @Test("newer fallback index blocks an older writer")
    func newerFallbackIndexBlocksSave() async throws {
        let fixture = try AnalysisFixture(contents: "future index source")
        defer { fixture.remove() }
        let applicationSupportURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-analysis-future-support-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
        let indexURL = applicationSupportURL
            .appendingPathComponent("AnalysisCases", isDirectory: true)
            .appendingPathComponent("index.analysis.json")
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"schemaVersion":2,"cases":[],"folderMaps":[]}"#.utf8)
            .write(to: indexURL)
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let repository = AnalysisCaseRepository(
            sourceFolderURL: fixture.directoryURL,
            applicationSupportURL: applicationSupportURL,
            sourceFolderIsWritable: false
        )

        await #expect(throws: AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
            found: 2,
            supported: 1
        )) {
            try await repository.save(AnalysisCase.create(for: revision, appBuild: "test"))
        }
    }

    @Test("workspace stays usable and exposes fallback portability state")
    func workspaceUsesFallbackStorage() async throws {
        let fixture = try AnalysisFixture(contents: "workspace fallback source")
        defer { fixture.remove() }
        let applicationSupportURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-analysis-workspace-support-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
        let counter = AnalysisInvocationCounter()
        let model = AnalysisWorkspaceModel(
            analyzers: [ImmediateAnalysisAnalyzer(counter: counter)],
            repositoryFactory: { folderURL in
                AnalysisCaseRepository(
                    sourceFolderURL: folderURL,
                    applicationSupportURL: applicationSupportURL,
                    sourceFolderIsWritable: false
                )
            }
        )

        model.open(ImageFile(url: fixture.fileURL))
        try await waitForAnalysisState { model.loadState == .ready }

        #expect(model.analysisCase != nil)
        #expect(model.caseStorage == .applicationSupport)
        #expect(model.storagePortabilityWarning?.contains("Application Support") == true)
        #expect(counter.count == 1)
    }

    @Test("repository surfaces a changed source instead of silently rebinding its case")
    func detectsChangedSource() async throws {
        let fixture = try AnalysisFixture(contents: "before")
        defer { fixture.remove() }
        let originalRevision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        let originalCase = AnalysisCase.create(for: originalRevision, appBuild: "test")
        try await repository.save(originalCase)

        try Data("different source bytes".utf8).write(to: fixture.fileURL)
        let currentRevision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let match = await repository.loadMostRelevantCase(for: currentRevision)

        guard case .sourceChanged(let reopened) = match else {
            Issue.record("Expected the previous case to be surfaced as source changed")
            return
        }
        #expect(reopened.id == originalCase.id)
        #expect(reopened.source.sha256 == originalCase.source.sha256)
        #expect(originalCase.source.relationship(to: currentRevision) == .sameFileChanged)
    }

    @Test("analysis entry resolves the last-clicked supported image inside a multi-selection")
    func resolvesLastClickedSelection() throws {
        let fixture = try AnalysisFixture(contents: "one")
        let secondURL = fixture.directoryURL.appendingPathComponent("second.jpg")
        try Data("two".utf8).write(to: secondURL)
        defer { fixture.remove() }
        let first = ImageFile(url: fixture.fileURL)
        let second = ImageFile(url: secondURL)

        let resolved = AnalysisSelectionResolver.image(
            images: [first, second],
            selectedURLs: [first.url, second.url],
            lastClickedURL: second.url
        )

        #expect(resolved?.url == second.url)
    }

    @Test("analysis entry requires a selected supported image")
    func rejectsMissingOrUnsupportedSelection() throws {
        let fixture = try AnalysisFixture(contents: "text", extension: "txt")
        defer { fixture.remove() }
        let file = ImageFile(url: fixture.fileURL)

        #expect(AnalysisSelectionResolver.image(
            images: [file],
            selectedURLs: [file.url],
            lastClickedURL: file.url
        ) == nil)
        #expect(AnalysisSelectionResolver.image(
            images: [file],
            selectedURLs: [],
            lastClickedURL: nil
        ) == nil)
    }

    @Test("version one shell cases migrate with empty analyzer and annotation collections")
    func migratesVersionOneCase() async throws {
        let fixture = try AnalysisFixture(contents: "legacy source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(analysisCase)) as? [String: Any]
        )
        object["schemaVersion"] = 1
        object["analyzerRuns"] = nil

        let caseDirectory = fixture.directoryURL
            .appendingPathComponent(".photo_analysis/cases", isDirectory: true)
        try FileManager.default.createDirectory(
            at: caseDirectory,
            withIntermediateDirectories: true
        )
        let caseURL = caseDirectory.appendingPathComponent(
            "\(analysisCase.id.uuidString.lowercased()).analysis.json"
        )
        try JSONSerialization.data(withJSONObject: object).write(to: caseURL)

        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        let match = await repository.loadMostRelevantCase(for: revision)
        guard case .exact(let migrated) = match else {
            Issue.record("Expected the version one case to migrate")
            return
        }
        #expect(migrated.schemaVersion == 9)
        #expect(migrated.analyzerRuns.isEmpty)
        #expect(migrated.annotations.isEmpty)
        #expect(migrated.timestampEvidence.isEmpty)
    }

    @Test("version two analyzer cases migrate with an empty annotation collection")
    func migratesVersionTwoCase() async throws {
        let fixture = try AnalysisFixture(contents: "version two source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(analysisCase)) as? [String: Any]
        )
        object["schemaVersion"] = 2
        object["annotations"] = nil

        let caseDirectory = fixture.directoryURL
            .appendingPathComponent(".photo_analysis/cases", isDirectory: true)
        try FileManager.default.createDirectory(
            at: caseDirectory,
            withIntermediateDirectories: true
        )
        let caseURL = caseDirectory.appendingPathComponent(
            "\(analysisCase.id.uuidString.lowercased()).analysis.json"
        )
        try JSONSerialization.data(withJSONObject: object).write(to: caseURL)

        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        let match = await repository.loadMostRelevantCase(for: revision)
        guard case .exact(let migrated) = match else {
            Issue.record("Expected the version two case to migrate")
            return
        }
        #expect(migrated.schemaVersion == 9)
        #expect(migrated.analyzerRuns == analysisCase.analyzerRuns)
        #expect(migrated.annotations.isEmpty)
        #expect(migrated.timestampEvidence.isEmpty)
    }

    @Test("version three annotation cases migrate without inventing calibration")
    func migratesVersionThreeCase() async throws {
        let fixture = try AnalysisFixture(contents: "version three source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        analysisCase.setAnnotation(AnalysisAnnotation(
            kind: .distance,
            geometry: .segment(
                start: AnalysisNormalizedPoint(x: 0.1, y: 0.2),
                end: AnalysisNormalizedPoint(x: 0.8, y: 0.7)
            )
        ))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(analysisCase)) as? [String: Any]
        )
        object["schemaVersion"] = 3

        let caseDirectory = fixture.directoryURL
            .appendingPathComponent(".photo_analysis/cases", isDirectory: true)
        try FileManager.default.createDirectory(
            at: caseDirectory,
            withIntermediateDirectories: true
        )
        let caseURL = caseDirectory.appendingPathComponent(
            "\(analysisCase.id.uuidString.lowercased()).analysis.json"
        )
        try JSONSerialization.data(withJSONObject: object).write(to: caseURL)

        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        let match = await repository.loadMostRelevantCase(for: revision)
        guard case .exact(let migrated) = match else {
            Issue.record("Expected the version three case to migrate")
            return
        }
        #expect(migrated.schemaVersion == 9)
        #expect(migrated.annotations.count == 1)
        #expect(migrated.annotations.first?.measurementCalibration == nil)
        #expect(migrated.timestampEvidence.isEmpty)
        try migrated.validateForPersistence()
    }

    @Test("version four markup cases migrate with an empty timestamp evidence collection")
    func migratesVersionFourCase() async throws {
        let fixture = try AnalysisFixture(contents: "version four source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        analysisCase.setAnnotation(AnalysisAnnotation(
            kind: .rectangle,
            geometry: .bounds(AnalysisNormalizedBounds(
                minimum: AnalysisNormalizedPoint(x: 0.1, y: 0.2),
                maximum: AnalysisNormalizedPoint(x: 0.7, y: 0.8)
            ))
        ))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(analysisCase)) as? [String: Any]
        )
        object["schemaVersion"] = 4
        object["timestampEvidence"] = nil

        let caseDirectory = fixture.directoryURL
            .appendingPathComponent(".photo_analysis/cases", isDirectory: true)
        try FileManager.default.createDirectory(
            at: caseDirectory,
            withIntermediateDirectories: true
        )
        let caseURL = caseDirectory.appendingPathComponent(
            "\(analysisCase.id.uuidString.lowercased()).analysis.json"
        )
        try JSONSerialization.data(withJSONObject: object).write(to: caseURL)

        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        let match = await repository.loadMostRelevantCase(for: revision)
        guard case .exact(let migrated) = match else {
            Issue.record("Expected the version four case to migrate")
            return
        }
        #expect(migrated.schemaVersion == 9)
        #expect(migrated.annotations.map(\.id) == analysisCase.annotations.map(\.id))
        #expect(migrated.annotations.map(\.kind) == analysisCase.annotations.map(\.kind))
        #expect(migrated.annotations.map(\.geometry) == analysisCase.annotations.map(\.geometry))
        #expect(migrated.timestampEvidence.isEmpty)
        try migrated.validateForPersistence()
    }

    @Test("user-entered timestamp evidence persists without changing the source")
    func timestampEvidenceRoundTrip() async throws {
        let fixture = try AnalysisFixture(contents: "timeline source")
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.fileURL)
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        var analysisCase = AnalysisCase.create(
            for: revision,
            appBuild: "test",
            now: Date(timeIntervalSince1970: 1)
        )
        let evidence = AnalysisTimestampEvidence(
            kind: .observation,
            title: "Clock visible in frame",
            value: AnalysisTimestampValue(
                year: 2026,
                month: 7,
                day: 30,
                hour: 19,
                minute: 42,
                precision: .minute,
                utcOffsetMinutes: nil
            ),
            source: .userEntered,
            sourceDetail: "Entered in this analysis case",
            now: Date(timeIntervalSince1970: 2)
        )
        analysisCase.setTimestampEvidence(evidence, now: Date(timeIntervalSince1970: 3))

        try await repository.save(analysisCase)
        guard case .exact(let reopened) = await repository.loadMostRelevantCase(for: revision) else {
            Issue.record("Expected timestamp evidence to reopen")
            return
        }
        #expect(reopened.timestampEvidence.count == 1)
        #expect(reopened.timestampEvidence.first?.title == "Clock visible in frame")
        #expect(reopened.timestampEvidence.first?.value.timezoneKnown == false)
        #expect(reopened.timestampEvidence.first?.value.precision == .minute)
        #expect(try Data(contentsOf: fixture.fileURL) == before)
    }

    @Test("untimed observations persist without changing the source")
    func observationRoundTrip() async throws {
        let fixture = try AnalysisFixture(contents: "untimed observation source")
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.fileURL)
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        var analysisCase = AnalysisCase.create(
            for: revision,
            appBuild: "test",
            now: Date(timeIntervalSince1970: 1)
        )
        let observation = AnalysisObservation(
            title: "Lighting",
            note: "The north-facing windows appear illuminated, but no reliable time is visible.",
            now: Date(timeIntervalSince1970: 2)
        )
        analysisCase.setObservation(observation, now: Date(timeIntervalSince1970: 3))

        try await repository.save(analysisCase)
        guard case .exact(let reopened) = await repository.loadMostRelevantCase(for: revision) else {
            Issue.record("Expected the untimed observation to reopen")
            return
        }
        #expect(reopened.observations == [observation].map {
            var updated = $0
            updated.markUpdated(now: Date(timeIntervalSince1970: 3))
            return updated
        })
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.fileURL.deletingPathExtension().appendingPathExtension("xmp").path
        ))
    }

    @Test("version five timeline cases migrate with a default map state")
    func migratesVersionFiveCase() async throws {
        let fixture = try AnalysisFixture(contents: "version five source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(analysisCase)) as? [String: Any]
        )
        object["schemaVersion"] = 5
        object["mapState"] = nil

        let caseDirectory = fixture.directoryURL
            .appendingPathComponent(".photo_analysis/cases", isDirectory: true)
        try FileManager.default.createDirectory(
            at: caseDirectory,
            withIntermediateDirectories: true
        )
        let caseURL = caseDirectory.appendingPathComponent(
            "\(analysisCase.id.uuidString.lowercased()).analysis.json"
        )
        try JSONSerialization.data(withJSONObject: object).write(to: caseURL)

        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        guard case .exact(let migrated) = await repository.loadMostRelevantCase(for: revision) else {
            Issue.record("Expected the version five case to migrate")
            return
        }
        #expect(migrated.schemaVersion == 9)
        #expect(migrated.timestampEvidence == analysisCase.timestampEvidence)
        #expect(migrated.mapState == AnalysisMapState())
        try migrated.validateForPersistence()
    }

    @Test("map viewport and investigator location persist without writing image GPS")
    func mapEvidenceRoundTripDoesNotWriteSource() async throws {
        let fixture = try AnalysisFixture(contents: "map evidence source")
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.fileURL)
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        var analysisCase = AnalysisCase.create(
            for: revision,
            appBuild: "test",
            now: Date(timeIntervalSince1970: 1)
        )
        analysisCase.setMapStyle(.satellite, now: Date(timeIntervalSince1970: 2))
        analysisCase.setMapTrafficVisible(true, now: Date(timeIntervalSince1970: 2))
        analysisCase.setMap3DContentVisible(true, now: Date(timeIntervalSince1970: 2))
        analysisCase.setMapViewport(AnalysisMapViewport(
            center: AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522),
            latitudeDelta: 0.05,
            longitudeDelta: 0.06,
            cameraDistance: 4_500,
            heading: 32,
            pitch: 55
        ), now: Date(timeIntervalSince1970: 3))
        analysisCase.setInvestigationLocation(AnalysisLocationEvidence(
            coordinate: AnalysisGeoCoordinate(latitude: 59.911, longitude: 10.75),
            source: .placeSearch,
            sourceDetail: "Oslo, Norway",
            placeName: "Oslo",
            placeNameSource: .placeSearch,
            now: Date(timeIntervalSince1970: 3)
        ), now: Date(timeIntervalSince1970: 4))

        try await repository.save(analysisCase)
        guard case .exact(let reopened) = await repository.loadMostRelevantCase(for: revision) else {
            Issue.record("Expected map evidence to reopen")
            return
        }
        #expect(reopened.mapState.style == .satellite)
        #expect(reopened.mapState.showsTraffic)
        #expect(reopened.mapState.shows3DContent)
        #expect(reopened.mapState.viewport?.center.latitude == 59.9139)
        #expect(reopened.mapState.viewport?.cameraDistance == 4_500)
        #expect(reopened.mapState.viewport?.heading == 32)
        #expect(reopened.mapState.viewport?.pitch == 55)
        #expect(reopened.mapState.investigationLocation?.source == .placeSearch)
        #expect(reopened.mapState.investigationLocation?.placeName == "Oslo")
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.fileURL.deletingPathExtension().appendingPathExtension("xmp").path
        ))
    }

    @Test("solar overlay round-trips frozen inputs without modifying source media")
    func solarOverlayRoundTripDoesNotWriteSource() async throws {
        let fixture = try AnalysisFixture(contents: "solar overlay source")
        defer { fixture.remove() }
        let sourceBytes = try Data(contentsOf: fixture.fileURL)
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        let evidenceID = UUID()
        let overlay = makeSolarOverlay(linkedTimestampEvidenceID: evidenceID)
        var analysisCase = AnalysisCase.create(
            for: revision,
            appBuild: "test",
            now: Date(timeIntervalSince1970: 1)
        )

        analysisCase.setSolarOverlay(overlay, now: Date(timeIntervalSince1970: 2))
        try analysisCase.validateForPersistence()
        try await repository.save(analysisCase)

        guard case .exact(let reopened) = await repository.loadMostRelevantCase(for: revision) else {
            Issue.record("Expected the solar overlay case to reopen")
            return
        }
        #expect(reopened.mapState.solarOverlay == overlay)
        #expect(reopened.mapState.solarOverlay?.linkedTimestampEvidenceID == evidenceID)
        #expect(reopened.timestampEvidence.isEmpty)
        #expect(try Data(contentsOf: fixture.fileURL) == sourceBytes)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.fileURL.deletingPathExtension().appendingPathExtension("xmp").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directoryURL.appendingPathComponent(".photo_metadata").path
        ))
    }

    @Test("version eight cases migrate with solar overlay disabled")
    func migratesVersionEightCaseWithSolarDisabled() async throws {
        let fixture = try AnalysisFixture(contents: "version eight solar source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        analysisCase.setSolarOverlay(makeSolarOverlay())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(analysisCase)) as? [String: Any]
        )
        object["schemaVersion"] = 8

        let caseDirectory = fixture.directoryURL
            .appendingPathComponent(".photo_analysis/cases", isDirectory: true)
        try FileManager.default.createDirectory(
            at: caseDirectory,
            withIntermediateDirectories: true
        )
        let caseURL = caseDirectory.appendingPathComponent(
            "\(analysisCase.id.uuidString.lowercased()).analysis.json"
        )
        try JSONSerialization.data(withJSONObject: object).write(to: caseURL)

        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        guard case .exact(let migrated) = await repository.loadMostRelevantCase(for: revision) else {
            Issue.record("Expected the version eight case to migrate")
            return
        }
        #expect(migrated.schemaVersion == 9)
        #expect(migrated.mapState.solarOverlay == nil)
        try migrated.validateForPersistence()
    }

    @Test("solar overlay validation requires an absolute minute-or-better timestamp")
    func rejectsInvalidSolarOverlayState() async throws {
        let fixture = try AnalysisFixture(contents: "invalid solar overlay source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")

        var unknownTimezone = makeSolarOverlay()
        unknownTimezone.timestamp.utcOffsetMinutes = nil
        analysisCase.mapState.solarOverlay = unknownTimezone
        #expect(throws: AnalysisCaseValidationError.invalidMapState) {
            try analysisCase.validateForPersistence()
        }

        var dayOnly = makeSolarOverlay()
        dayOnly.timestamp = AnalysisTimestampValue(
            year: 2026,
            month: 8,
            day: 19,
            precision: .day,
            utcOffsetMinutes: 120
        )
        analysisCase.mapState.solarOverlay = dayOnly
        #expect(throws: AnalysisCaseValidationError.invalidMapState) {
            try analysisCase.validateForPersistence()
        }

        var invalidMinute = makeSolarOverlay()
        invalidMinute.timestamp.second = 1
        analysisCase.mapState.solarOverlay = invalidMinute
        #expect(throws: AnalysisCaseValidationError.invalidMapState) {
            try analysisCase.validateForPersistence()
        }
    }

    @Test("solar source eligibility rejects day-only and timezone-unknown timeline rows")
    func filtersSolarTimestampEvidence() {
        let eligible = AnalysisTimestampEvidence(
            kind: .capture,
            value: AnalysisTimestampValue(
                year: 2026,
                month: 8,
                day: 19,
                hour: 14,
                minute: 35,
                precision: .minute,
                utcOffsetMinutes: 120
            ),
            source: .embeddedMetadata,
            sourceDetail: "Timezone-qualified EXIF capture timestamp"
        )
        var timezoneUnknown = eligible
        timezoneUnknown.value.utcOffsetMinutes = nil
        var dayOnly = eligible
        dayOnly.value = AnalysisTimestampValue(
            year: 2026,
            month: 8,
            day: 19,
            precision: .day,
            utcOffsetMinutes: 120
        )
        var invalid = eligible
        invalid.value.minute = 75

        #expect(eligible.isEligibleForSolarPosition)
        #expect(!timezoneUnknown.isEligibleForSolarPosition)
        #expect(!dayOnly.isEligibleForSolarPosition)
        #expect(!invalid.isEligibleForSolarPosition)
    }

    @Test("workspace persists and clears solar state but remains read-only for a changed source")
    func workspaceSolarMutationsRespectSourceChangedState() async throws {
        let fixture = try AnalysisFixture(contents: "workspace solar source")
        defer { fixture.remove() }
        let image = ImageFile(url: fixture.fileURL)
        let model = AnalysisWorkspaceModel(analyzers: [])
        let overlay = makeSolarOverlay()

        model.open(image)
        try await waitForAnalysisState { model.loadState == .ready }
        let originalRevision = try #require(model.currentRevision)
        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)

        model.setSolarOverlay(overlay)
        #expect(model.mapState.solarOverlay == overlay)
        try await waitForPersistedSolarOverlay(
            overlay,
            repository: repository,
            revision: originalRevision
        )

        model.clearSolarOverlay()
        #expect(model.mapState.solarOverlay == nil)
        try await waitForPersistedSolarOverlay(
            nil,
            repository: repository,
            revision: originalRevision
        )

        try Data("changed workspace solar source".utf8).write(to: fixture.fileURL)
        model.open(ImageFile(url: fixture.fileURL))
        try await waitForAnalysisState { model.loadState == .ready }
        #expect(model.sourceChanged)

        model.setSolarOverlay(overlay)
        #expect(model.mapState.solarOverlay == nil)
        guard case .exact(let persisted) = await repository.loadMostRelevantCase(
            for: originalRevision
        ) else {
            Issue.record("Expected the unchanged persisted source revision")
            return
        }
        #expect(persisted.mapState.solarOverlay == nil)
    }

    @MainActor
    @Test("rename quiescence prevents a stale analysis writer from restoring the old path hint")
    func renameQuiescencePreventsStalePathWriter() async throws {
        let fixture = try AnalysisFixture(contents: "rename quiescence source")
        defer { fixture.remove() }
        let source = fixture.fileURL
        let destination = fixture.directoryURL.appendingPathComponent("renamed.jpg")
        let model = AnalysisWorkspaceModel(analyzers: [])
        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)

        model.open(ImageFile(url: source))
        try await waitForAnalysisState { model.loadState == .ready }
        let revision = try #require(model.currentRevision)

        model.selectWorkspaceMode(.osint)
        try await model.beginRenameQuiescence(in: fixture.directoryURL)

        guard case .exact(let flushedBeforeRename) = await repository.loadMostRelevantCase(
            for: revision
        ) else {
            Issue.record("Expected the durable pre-rename case")
            return
        }
        #expect(flushedBeforeRename.workspaceMode == .osint)
        #expect(flushedBeforeRename.source.canonicalURL == source)

        model.selectWorkspaceMode(.pixelAnalysis)
        guard case .exact(let heldBeforeRename) = await repository.loadMostRelevantCase(
            for: revision
        ) else {
            Issue.record("Expected the durable case while persistence is gated")
            return
        }
        #expect(heldBeforeRename.workspaceMode == .osint)
        #expect(heldBeforeRename.source.canonicalURL == source)

        try FileManager.default.moveItem(at: source, to: destination)
        try await model.finishRenameQuiescence(using: [
            .init(sourceURL: source, destinationURL: destination),
        ])

        let renamedRevision = try await SourceImageRevision.capture(at: destination)
        guard case .exact(let afterRename) = await repository.loadMostRelevantCase(
            for: renamedRevision
        ) else {
            Issue.record("Expected the case after rename")
            return
        }
        #expect(afterRename.workspaceMode == .pixelAnalysis)
        #expect(afterRename.source.canonicalURL == destination)

        model.selectWorkspaceMode(.osint)
        await model.flushPendingSaves()
        guard case .exact(let afterLaterSave) = await repository.loadMostRelevantCase(
            for: renamedRevision
        ) else {
            Issue.record("Expected the case after reopening persistence")
            return
        }
        #expect(afterLaterSave.workspaceMode == .osint)
        #expect(afterLaterSave.source.canonicalURL == destination)
    }

    @Test("legacy map state defaults 3D content to off")
    func legacyMapStateDefaults3DContentToOff() throws {
        let encoder = JSONEncoder()
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(AnalysisMapState()))
                as? [String: Any]
        )
        object.removeValue(forKey: "shows3DContent")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AnalysisMapState.self, from: legacyData)

        #expect(!decoded.shows3DContent)
    }

    @Test("embedded GPS promotion keeps explicit provenance")
    func embeddedGPSLocationEvidenceRoundTrip() throws {
        let evidence = AnalysisLocationEvidence(
            coordinate: AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522),
            source: .embeddedGPS,
            sourceDetail: "Promoted from the analyzed source's embedded GPS metadata",
            now: Date(timeIntervalSince1970: 1)
        )

        #expect(evidence.validate())
        let encoded = try JSONEncoder().encode(evidence)
        let decoded = try JSONDecoder().decode(AnalysisLocationEvidence.self, from: encoded)
        #expect(decoded == evidence)
        #expect(decoded.source.displayName == "Embedded GPS")
    }

    @Test("legacy map camera data defaults to a level north-facing viewport")
    func decodesLegacyMapViewportCameraDefaults() throws {
        let data = Data(#"{"center":{"latitude":59.9139,"longitude":10.7522},"latitudeDelta":0.05,"longitudeDelta":0.06}"#.utf8)
        let viewport = try JSONDecoder().decode(AnalysisMapViewport.self, from: data)

        #expect(viewport.cameraDistance == nil)
        #expect(viewport.heading == 0)
        #expect(viewport.pitch == 0)
        #expect(viewport.isValid)
    }

    @Test("all live map styles and external map links preserve coordinates")
    func mapStylesAndExternalLinkRoundTrip() throws {
        let styles = AnalysisMapStyle.allCases
        let encoded = try JSONEncoder().encode(styles)
        #expect(try JSONDecoder().decode([AnalysisMapStyle].self, from: encoded) == styles)

        let coordinate = AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522)
        let url = try #require(AnalysisExternalMapLinks.googleMapsURL(for: coordinate))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "www.google.com")
        #expect(components.path == "/maps/search/")
        #expect(components.queryItems?.first(where: { $0.name == "api" })?.value == "1")
        #expect(components.queryItems?.first(where: { $0.name == "query" })?.value
            == "59.91390000,10.75220000")

        let lookAroundURL = try #require(
            AnalysisExternalMapLinks.appleLookAroundURL(for: coordinate)
        )
        let lookAroundComponents = try #require(
            URLComponents(url: lookAroundURL, resolvingAgainstBaseURL: false)
        )
        #expect(lookAroundComponents.host == "maps.apple.com")
        #expect(lookAroundComponents.path == "/look-around")
        #expect(lookAroundComponents.queryItems?.first(where: { $0.name == "coordinate" })?.value
            == "59.91390000,10.75220000")
    }

    @Test("version six map evidence migrates with an empty map annotation collection")
    func migratesVersionSixCase() async throws {
        let fixture = try AnalysisFixture(contents: "version six map source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        analysisCase.setMapViewport(AnalysisMapViewport(
            center: AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522),
            latitudeDelta: 0.05,
            longitudeDelta: 0.06
        ))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(analysisCase)) as? [String: Any]
        )
        object["schemaVersion"] = 6
        var legacyMapState = try #require(object["mapState"] as? [String: Any])
        legacyMapState["annotations"] = nil
        object["mapState"] = legacyMapState

        let caseDirectory = fixture.directoryURL
            .appendingPathComponent(".photo_analysis/cases", isDirectory: true)
        try FileManager.default.createDirectory(
            at: caseDirectory,
            withIntermediateDirectories: true
        )
        let caseURL = caseDirectory.appendingPathComponent(
            "\(analysisCase.id.uuidString.lowercased()).analysis.json"
        )
        try JSONSerialization.data(withJSONObject: object).write(to: caseURL)

        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        guard case .exact(let migrated) = await repository.loadMostRelevantCase(for: revision) else {
            Issue.record("Expected the version six case to migrate")
            return
        }
        #expect(migrated.schemaVersion == 9)
        #expect(migrated.mapState.viewport == analysisCase.mapState.viewport)
        #expect(migrated.mapState.annotations.isEmpty)
        try migrated.validateForPersistence()
    }

    @Test("version seven map-markup cases migrate with empty untimed observations")
    func migratesVersionSevenCase() async throws {
        let fixture = try AnalysisFixture(contents: "version seven map markup source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        analysisCase.setMapAnnotation(AnalysisMapAnnotation(
            kind: .marker,
            geometry: .point(AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522))
        ))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(analysisCase)) as? [String: Any]
        )
        object["schemaVersion"] = 7
        object["observations"] = nil

        let caseDirectory = fixture.directoryURL
            .appendingPathComponent(".photo_analysis/cases", isDirectory: true)
        try FileManager.default.createDirectory(
            at: caseDirectory,
            withIntermediateDirectories: true
        )
        let caseURL = caseDirectory.appendingPathComponent(
            "\(analysisCase.id.uuidString.lowercased()).analysis.json"
        )
        try JSONSerialization.data(withJSONObject: object).write(to: caseURL)

        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        guard case .exact(let migrated) = await repository.loadMostRelevantCase(for: revision) else {
            Issue.record("Expected the version seven case to migrate")
            return
        }
        #expect(migrated.schemaVersion == 9)
        #expect(migrated.mapState.annotations.map(\.id) == analysisCase.mapState.annotations.map(\.id))
        #expect(migrated.mapState.annotations.map(\.kind) == analysisCase.mapState.annotations.map(\.kind))
        #expect(migrated.mapState.annotations.map(\.geometry) == analysisCase.mapState.annotations.map(\.geometry))
        #expect(migrated.observations.isEmpty)
        try migrated.validateForPersistence()
    }

    @Test("all map markup kinds and stable labeled-photo links persist without source writes")
    func mapAnnotationsRoundTripDoesNotWriteSource() async throws {
        let fixture = try AnalysisFixture(contents: "map markup source")
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.fileURL)
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let photoLabel = AnalysisAnnotation(
            kind: .rectangle,
            geometry: .bounds(AnalysisNormalizedBounds(
                minimum: AnalysisNormalizedPoint(x: 0.3, y: 0.4),
                maximum: AnalysisNormalizedPoint(x: 0.5, y: 0.7)
            )),
            text: "North entrance",
            note: "Stone doorway partially obscured by a tree"
        )
        analysisCase.setAnnotation(photoLabel)
        let oslo = AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522)
        let nearby = AnalysisGeoCoordinate(latitude: 59.918, longitude: 10.761)
        let polygon = [
            oslo,
            AnalysisGeoCoordinate(latitude: 59.914, longitude: 10.76),
            AnalysisGeoCoordinate(latitude: 59.919, longitude: 10.755),
        ]
        let annotations = [
            AnalysisMapAnnotation(kind: .marker, geometry: .point(oslo)),
            AnalysisMapAnnotation(
                kind: .line,
                geometry: .segment(start: oslo, end: nearby),
                isVisible: false
            ),
            AnalysisMapAnnotation(kind: .shape, geometry: .polygon(polygon)),
            AnalysisMapAnnotation(
                kind: .distance,
                geometry: .segment(start: oslo, end: nearby)
            ),
            AnalysisMapAnnotation(
                kind: .label,
                geometry: .point(nearby),
                text: "Camera position",
                linkedPhotoLabelID: photoLabel.id
            ),
        ]
        for annotation in annotations {
            analysisCase.setMapAnnotation(annotation)
        }

        try await repository.save(analysisCase)
        guard case .exact(let reopened) = await repository.loadMostRelevantCase(for: revision) else {
            Issue.record("Expected map markup to reopen")
            return
        }
        #expect(reopened.mapState.annotations.map(\.kind) == annotations.map(\.kind))
        #expect(reopened.mapState.annotations[1].isVisible == false)
        #expect(reopened.mapState.annotations.last?.linkedPhotoLabelID == photoLabel.id)
        #expect(reopened.annotations.first?.note == photoLabel.note)
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.fileURL.deletingPathExtension().appendingPathExtension("xmp").path
        ))
        try reopened.validateForPersistence()
    }

    @Test("folder map annotations link photo annotations from several image cases")
    func folderMapAnnotationsLinkAcrossCases() async throws {
        let fixture = try AnalysisFixture(contents: "first image")
        defer { fixture.remove() }
        let secondURL = fixture.directoryURL.appendingPathComponent("second.jpg")
        try Data("second image".utf8).write(to: secondURL)
        let firstBytes = try Data(contentsOf: fixture.fileURL)
        let secondBytes = try Data(contentsOf: secondURL)
        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)

        var firstCase = AnalysisCase.create(
            for: try await SourceImageRevision.capture(at: fixture.fileURL),
            appBuild: "test"
        )
        var secondCase = AnalysisCase.create(
            for: try await SourceImageRevision.capture(at: secondURL),
            appBuild: "test"
        )
        let firstPhotoAnnotation = AnalysisAnnotation(
            kind: .rectangle,
            geometry: .bounds(AnalysisNormalizedBounds(
                minimum: AnalysisNormalizedPoint(x: 0.1, y: 0.2),
                maximum: AnalysisNormalizedPoint(x: 0.3, y: 0.5)
            )),
            text: "West facade"
        )
        let secondPhotoAnnotation = AnalysisAnnotation(
            kind: .polygon,
            geometry: .polygon([
                AnalysisNormalizedPoint(x: 0.4, y: 0.2),
                AnalysisNormalizedPoint(x: 0.7, y: 0.3),
                AnalysisNormalizedPoint(x: 0.6, y: 0.7),
            ]),
            text: "Same building from the south"
        )
        firstCase.setAnnotation(firstPhotoAnnotation)
        secondCase.setAnnotation(secondPhotoAnnotation)
        try await repository.save(firstCase)
        try await repository.save(secondCase)

        let sharedMarker = AnalysisMapAnnotation(
            kind: .marker,
            geometry: .point(AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522)),
            text: "Shared landmark"
        )
        var folderDocument = AnalysisFolderMapDocument.create()
        folderDocument.setAnnotation(AnalysisGlobalMapAnnotation(
            annotation: sharedMarker,
            photoAnnotationReferences: [
                AnalysisPhotoAnnotationReference(
                    caseID: firstCase.id,
                    annotationID: firstPhotoAnnotation.id
                ),
                AnalysisPhotoAnnotationReference(
                    caseID: secondCase.id,
                    annotationID: secondPhotoAnnotation.id
                ),
            ]
        ))
        try await repository.saveFolderMapDocument(folderDocument)

        let reopened = await repository.loadFolderMapDocument()
        #expect(reopened.annotations.count == 1)
        #expect(reopened.annotations.first?.id == sharedMarker.id)
        #expect(reopened.annotations.first?.annotation.kind == sharedMarker.kind)
        #expect(reopened.annotations.first?.annotation.geometry == sharedMarker.geometry)
        #expect(reopened.annotations.first?.annotation.text == sharedMarker.text)
        #expect(reopened.annotations.first?.photoAnnotationReferences.count == 2)
        #expect(Set(reopened.annotations.first?.photoAnnotationReferences ?? []) == Set([
            AnalysisPhotoAnnotationReference(
                caseID: firstCase.id,
                annotationID: firstPhotoAnnotation.id
            ),
            AnalysisPhotoAnnotationReference(
                caseID: secondCase.id,
                annotationID: secondPhotoAnnotation.id
            ),
        ]))
        #expect(firstCase.mapState.annotations.isEmpty)
        #expect(secondCase.mapState.annotations.isEmpty)
        #expect(try Data(contentsOf: fixture.fileURL) == firstBytes)
        #expect(try Data(contentsOf: secondURL) == secondBytes)
        try reopened.validateForPersistence()
    }

    @Test("folder map links are unique and independently removable")
    func folderMapAnnotationLinksAreManyToMany() {
        let firstReference = AnalysisPhotoAnnotationReference(
            caseID: UUID(),
            annotationID: UUID()
        )
        let secondReference = AnalysisPhotoAnnotationReference(
            caseID: UUID(),
            annotationID: UUID()
        )
        var annotation = AnalysisGlobalMapAnnotation(
            annotation: AnalysisMapAnnotation(
                kind: .marker,
                geometry: .point(AnalysisGeoCoordinate(latitude: 1, longitude: 2))
            )
        )

        let addedFirst = annotation.setPhotoAnnotationLinked(firstReference, isLinked: true)
        let rejectedDuplicate = annotation.setPhotoAnnotationLinked(firstReference, isLinked: true)
        let addedSecond = annotation.setPhotoAnnotationLinked(secondReference, isLinked: true)
        #expect(addedFirst)
        #expect(!rejectedDuplicate)
        #expect(addedSecond)
        #expect(annotation.photoAnnotationReferences == [firstReference, secondReference])
        #expect(annotation.isLinked(to: firstReference))
        #expect(annotation.isLinked(to: secondReference))
        let removedFirst = annotation.setPhotoAnnotationLinked(firstReference, isLinked: false)
        #expect(removedFirst)
        #expect(annotation.photoAnnotationReferences == [secondReference])
        #expect(!annotation.isLinked(to: firstReference))
        #expect(annotation.isLinked(to: secondReference))
        #expect(annotation.validate())
    }

    @Test("map markup rejects mismatched geometry, empty labels, and duplicate IDs")
    func rejectsInvalidMapAnnotations() async throws {
        let fixture = try AnalysisFixture(contents: "invalid map markup source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let coordinate = AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522)
        let invalid = AnalysisMapAnnotation(
            kind: .label,
            geometry: .segment(start: coordinate, end: AnalysisGeoCoordinate(
                latitude: 59.92,
                longitude: 10.76
            )),
            text: ""
        )
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        analysisCase.mapState.annotations = [invalid]
        #expect(throws: AnalysisCaseValidationError.invalidMapState) {
            try analysisCase.validateForPersistence()
        }

        let valid = AnalysisMapAnnotation(kind: .marker, geometry: .point(coordinate))
        analysisCase.mapState.annotations = [valid, valid]
        #expect(throws: AnalysisCaseValidationError.invalidMapState) {
            try analysisCase.validateForPersistence()
        }
    }

    @Test("map distance uses geographic coordinates and formats useful units")
    func mapDistanceMeasurement() throws {
        let annotation = AnalysisMapAnnotation(
            kind: .distance,
            geometry: .segment(
                start: AnalysisGeoCoordinate(latitude: 0, longitude: 0),
                end: AnalysisGeoCoordinate(latitude: 1, longitude: 0)
            )
        )
        let measurement = try #require(AnalysisMapDistanceMeasurement(annotation: annotation))
        #expect(abs(measurement.meters - 111_195) < 100)
        #expect(measurement.formatted.contains("km"))
    }

    @Test("map annotation history is bounded and independent")
    func mapAnnotationUndoRedoTransactions() {
        let marker = AnalysisMapAnnotation(
            kind: .marker,
            geometry: .point(AnalysisGeoCoordinate(latitude: 59.9, longitude: 10.7))
        )
        let label = AnalysisMapAnnotation(
            kind: .label,
            geometry: .point(AnalysisGeoCoordinate(latitude: 59.91, longitude: 10.71)),
            text: "Label"
        )
        var history = AnalysisMapAnnotationUndoHistory(maximumTransactionCount: 2)
        history.record(before: [], after: [marker], actionName: "Add Marker")
        history.record(before: [marker], after: [marker, label], actionName: "Add Label")

        #expect(history.undoActionName == "Add Label")
        #expect(history.undo() == [marker])
        #expect(history.redo() == [marker, label])
        #expect(history.undo() == [marker])
        history.record(before: [marker], after: [], actionName: "Delete Marker")
        #expect(!history.canRedo)
        #expect(history.undo() == [marker])
        #expect(history.undo() == [])
        #expect(history.undo() == nil)
    }

    @Test("map state validation rejects invalid coordinates and viewports")
    func rejectsInvalidMapState() async throws {
        let fixture = try AnalysisFixture(contents: "invalid map source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        analysisCase.mapState.viewport = AnalysisMapViewport(
            center: AnalysisGeoCoordinate(latitude: 91, longitude: 10),
            latitudeDelta: 0,
            longitudeDelta: 1
        )

        #expect(throws: AnalysisCaseValidationError.invalidMapState) {
            try analysisCase.validateForPersistence()
        }
    }

    @Test("map content failures distinguish offline, network, and unavailable states")
    func classifiesMapImageryFailures() throws {
        let offline = AnalysisMapImageryAvailability.failure(
            for: URLError(.notConnectedToInternet),
            networkAvailable: false
        )
        #expect(offline == .offline)
        #expect(offline.title == "Map is offline")
        #expect(offline.message?.contains("saved map annotations remain available") == true)

        let networkFailure = AnalysisMapImageryAvailability.failure(
            for: URLError(.timedOut),
            networkAvailable: true
        )
        guard case .networkFailure = networkFailure else {
            Issue.record("Expected a connected request timeout to be a network failure")
            return
        }
        #expect(networkFailure.title == "Map network request failed")

        let imageryFailure = AnalysisMapImageryAvailability.failure(
            for: NSError(
                domain: "MapImageryTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No tiles for this region"]
            ),
            networkAvailable: true
        )
        #expect(imageryFailure == .unavailable("No tiles for this region"))
        #expect(imageryFailure.title == "Map content unavailable")
        #expect(imageryFailure.message?.contains("different scale, style, or location") == true)
    }

    @Test("timestamp validation rejects invalid dates, offsets, and non-user case entries")
    func rejectsInvalidTimestampEvidence() async throws {
        let fixture = try AnalysisFixture(contents: "invalid timeline source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let invalid = AnalysisTimestampEvidence(
            kind: .observation,
            value: AnalysisTimestampValue(
                year: 2026,
                month: 2,
                day: 30,
                precision: .day,
                utcOffsetMinutes: 15 * 60
            ),
            source: .userEntered,
            sourceDetail: "Test"
        )
        analysisCase.setTimestampEvidence(invalid)
        #expect(throws: AnalysisCaseValidationError.invalidTimestampEvidence) {
            try analysisCase.validateForPersistence()
        }

        var sourceDerived = AnalysisCase.create(for: revision, appBuild: "test")
        sourceDerived.timestampEvidence = [AnalysisTimestampEvidence(
            kind: .capture,
            value: AnalysisTimestampValue(
                year: 2026,
                month: 7,
                day: 30,
                precision: .day,
                utcOffsetMinutes: nil
            ),
            source: .embeddedMetadata,
            sourceDetail: "EXIF"
        )]
        #expect(throws: AnalysisCaseValidationError.invalidTimestampEvidence) {
            try sourceDerived.validateForPersistence()
        }
    }

    @Test("untimed observations require a title, note, and unique IDs")
    func rejectsInvalidObservations() async throws {
        let fixture = try AnalysisFixture(contents: "invalid observation source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let invalid = AnalysisObservation(title: "Observation", note: "   ")
        analysisCase.observations = [invalid]
        #expect(throws: AnalysisCaseValidationError.invalidObservations) {
            try analysisCase.validateForPersistence()
        }

        let valid = AnalysisObservation(title: "Weather", note: "Overcast conditions")
        analysisCase.observations = [valid, valid]
        #expect(throws: AnalysisCaseValidationError.invalidObservations) {
            try analysisCase.validateForPersistence()
        }
    }

    @Test("timeline keeps timezone-unknown capture evidence distinct and detects known conflicts")
    func resolvesTimestampEvidenceAndConflicts() {
        let facts = makeSourceFacts(
            fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            captureDate: "2026:07:30 19:42:10",
            captureTimezoneKnown: false
        )
        let derived = AnalysisTimelineResolver.sourceEvidence(from: facts)
        let capture = derived.first { $0.kind == .capture }
        #expect(capture?.value.formatted == "2026-07-30 19:42:10")
        #expect(capture?.value.timezoneKnown == false)
        #expect(capture?.value.resolvedInstant == nil)
        #expect(derived.first { $0.kind == .fileModification }?.value.timezoneKnown == true)

        let gps = AnalysisTimelineResolver.sourceEvidence(
            from: facts,
            rawMetadata: [
                AnalysisRawMetadataEntry(
                    id: "gps.date",
                    namespace: "GPS",
                    key: "GPSDateStamp",
                    value: "2026:07:30",
                    origin: .gps
                ),
                AnalysisRawMetadataEntry(
                    id: "gps.time",
                    namespace: "GPS",
                    key: "GPSTimeStamp",
                    value: "17:42:10",
                    origin: .gps
                ),
            ]
        ).first { $0.kind == .gps }
        #expect(gps?.value.formatted == "2026-07-30 17:42:10 UTC")
        #expect(gps?.value.timezoneKnown == true)

        let knownCapture = AnalysisTimestampEvidence(
            kind: .capture,
            value: AnalysisTimestampValue(
                year: 2026,
                month: 7,
                day: 30,
                hour: 20,
                minute: 0,
                second: 0,
                precision: .second,
                utcOffsetMinutes: 0
            ),
            source: .embeddedMetadata,
            sourceDetail: "EXIF"
        )
        let knownGPS = AnalysisTimestampEvidence(
            kind: .gps,
            value: AnalysisTimestampValue(
                year: 2026,
                month: 7,
                day: 30,
                hour: 19,
                minute: 0,
                second: 0,
                precision: .second,
                utcOffsetMinutes: 0
            ),
            source: .gpsMetadata,
            sourceDetail: "GPS"
        )
        let conflicts = AnalysisTimelineResolver.conflicts(in: [knownCapture, knownGPS])
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.evidenceIDs == [knownCapture.id, knownGPS.id])
    }

    @Test("normalized photo annotations round-trip in the source-bound case")
    func annotationRoundTrip() async throws {
        let fixture = try AnalysisFixture(contents: "annotated source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        var analysisCase = AnalysisCase.create(
            for: revision,
            appBuild: "test",
            now: Date(timeIntervalSince1970: 10)
        )
        let annotation = AnalysisAnnotation(
            kind: .distance,
            geometry: .segment(
                start: AnalysisNormalizedPoint(x: 0.125, y: 0.25),
                end: AnalysisNormalizedPoint(x: 0.875, y: 0.75)
            ),
            style: AnalysisAnnotationStyle(
                color: .custom(AnalysisAnnotationCustomColor(
                    red: 0.1,
                    green: 0.4,
                    blue: 0.9,
                    opacity: 0.8
                )),
                lineWidthPoints: 3,
                fillOpacity: 0
            ),
            isVisible: false,
            findingIDs: ["metadata.orientation-conflict"],
            measurementCalibration: AnalysisMeasurementCalibration(
                knownLength: 42,
                unit: .centimeters
            ),
            now: Date(timeIntervalSince1970: 11)
        )
        analysisCase.setAnnotation(annotation, now: Date(timeIntervalSince1970: 12))

        try await repository.save(analysisCase)
        let match = await repository.loadMostRelevantCase(for: revision)

        guard case .exact(let reopened) = match else {
            Issue.record("Expected the annotated case to reopen")
            return
        }
        #expect(reopened.annotations.first?.id == annotation.id)
        #expect(reopened.annotations.first?.geometry == annotation.geometry)
        #expect(reopened.annotations.first?.isVisible == false)
        #expect(reopened.annotations.first?.findingIDs == ["metadata.orientation-conflict"])
        #expect(
            reopened.annotations.first?.measurementCalibration
                == annotation.measurementCalibration
        )
        #expect(reopened.annotations.first?.updatedAt == Date(timeIntervalSince1970: 12))
        #expect(reopened.updatedAt == Date(timeIntervalSince1970: 12))
        try reopened.validateForPersistence()
    }

    @Test("finding links are stable, unique, removable annotation references")
    func findingLinks() throws {
        var annotation = AnalysisAnnotation(
            kind: .rectangle,
            geometry: .bounds(AnalysisNormalizedBounds(
                minimum: AnalysisNormalizedPoint(x: 0.1, y: 0.2),
                maximum: AnalysisNormalizedPoint(x: 0.8, y: 0.9)
            ))
        )

        let inserted = annotation.setFindingLinked(
            "metadata.orientation-conflict",
            isLinked: true
        )
        let duplicate = annotation.setFindingLinked(
            "metadata.orientation-conflict",
            isLinked: true
        )
        #expect(inserted)
        #expect(!duplicate)
        #expect(annotation.findingIDs == ["metadata.orientation-conflict"])
        try annotation.validate()

        let invalid = annotation.setFindingLinked("   ", isLinked: true)
        let removed = annotation.setFindingLinked(
            "metadata.orientation-conflict",
            isLinked: false
        )
        let missing = annotation.setFindingLinked(
            "metadata.orientation-conflict",
            isLinked: false
        )
        #expect(!invalid)
        #expect(removed)
        #expect(!missing)
        #expect(annotation.findingIDs.isEmpty)
        try annotation.validate()
    }

    @Test("annotation validation rejects mismatched, out-of-range, and duplicate geometry")
    func rejectsInvalidAnnotations() async throws {
        let fixture = try AnalysisFixture(contents: "invalid annotation source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let id = UUID()
        let invalid = AnalysisAnnotation(
            id: id,
            kind: .rectangle,
            geometry: .segment(
                start: AnalysisNormalizedPoint(x: -0.1, y: 0.2),
                end: AnalysisNormalizedPoint(x: 0.8, y: 0.9)
            )
        )
        analysisCase.setAnnotation(invalid)

        #expect(throws: AnalysisCaseValidationError.invalidAnnotations) {
            try analysisCase.validateForPersistence()
        }

        let valid = AnalysisAnnotation(
            id: id,
            kind: .label,
            geometry: .anchor(AnalysisNormalizedPoint(x: 0.5, y: 0.5)),
            text: "Subject"
        )
        analysisCase.setAnnotation(valid)
        analysisCase.annotations.append(valid)
        #expect(throws: AnalysisCaseValidationError.invalidAnnotations) {
            try analysisCase.validateForPersistence()
        }
    }

    @Test("every planned photo-markup kind has a valid normalized geometry")
    func supportsPlannedAnnotationKinds() throws {
        let start = AnalysisNormalizedPoint(x: 0.1, y: 0.2)
        let end = AnalysisNormalizedPoint(x: 0.8, y: 0.9)
        let bounds = AnalysisNormalizedBounds(minimum: start, maximum: end)
        let annotations = [
            AnalysisAnnotation(kind: .line, geometry: .segment(start: start, end: end)),
            AnalysisAnnotation(kind: .arrow, geometry: .segment(start: start, end: end)),
            AnalysisAnnotation(kind: .distance, geometry: .segment(start: start, end: end)),
            AnalysisAnnotation(kind: .rectangle, geometry: .bounds(bounds)),
            AnalysisAnnotation(kind: .ellipse, geometry: .bounds(bounds)),
            AnalysisAnnotation(kind: .polygon, geometry: .polygon([
                start,
                AnalysisNormalizedPoint(x: 0.8, y: 0.2),
                end,
            ])),
            AnalysisAnnotation(kind: .label, geometry: .anchor(start), text: "Detail"),
        ]

        #expect(annotations.map(\.kind) == AnalysisAnnotationKind.allCases)
        for annotation in annotations {
            try annotation.validate()
        }
    }

    @Test("annotation gesture geometry standardizes reverse drags and rejects collapsed shapes")
    func buildsAnnotationGestureGeometry() throws {
        let start = AnalysisNormalizedPoint(x: 0.8, y: 0.9)
        let end = AnalysisNormalizedPoint(x: 0.2, y: 0.3)

        let rectangle = try #require(
            AnalysisAnnotationGeometryBuilder.geometry(
                for: .rectangle,
                start: start,
                end: end
            )
        )
        #expect(rectangle == .bounds(AnalysisNormalizedBounds(
            minimum: AnalysisNormalizedPoint(x: 0.2, y: 0.3),
            maximum: AnalysisNormalizedPoint(x: 0.8, y: 0.9)
        )))
        #expect(AnalysisAnnotationGeometryBuilder.geometry(
            for: .line,
            start: start,
            end: start
        ) == nil)
        #expect(AnalysisAnnotationGeometryBuilder.geometry(
            for: .ellipse,
            start: start,
            end: start
        ) == nil)
    }

    @Test("select-tool geometry edits move, clamp, and resize annotations")
    func editsAnnotationGeometry() throws {
        let originalBounds = AnalysisAnnotationGeometry.bounds(AnalysisNormalizedBounds(
            minimum: AnalysisNormalizedPoint(x: 0.2, y: 0.3),
            maximum: AnalysisNormalizedPoint(x: 0.6, y: 0.8)
        ))
        let moved = AnalysisAnnotationGeometryEditor.moving(
            originalBounds,
            from: AnalysisNormalizedPoint(x: 0.3, y: 0.4),
            to: AnalysisNormalizedPoint(x: 0.9, y: 0.9)
        )
        guard case .bounds(let movedBounds) = moved else {
            Issue.record("Expected moved bounds geometry")
            return
        }
        #expect(abs(movedBounds.minimum.x - 0.6) < 1e-12)
        #expect(abs(movedBounds.minimum.y - 0.5) < 1e-12)
        #expect(movedBounds.maximum == AnalysisNormalizedPoint(x: 1, y: 1))

        let resizedBounds = AnalysisAnnotationGeometryEditor.resizing(
            originalBounds,
            controlPoint: .boundsMaximumXMinimumY,
            to: AnalysisNormalizedPoint(x: 0.9, y: 0.1)
        )
        #expect(resizedBounds == .bounds(AnalysisNormalizedBounds(
            minimum: AnalysisNormalizedPoint(x: 0.2, y: 0.1),
            maximum: AnalysisNormalizedPoint(x: 0.9, y: 0.8)
        )))

        let segment = AnalysisAnnotationGeometry.segment(
            start: AnalysisNormalizedPoint(x: 0.1, y: 0.2),
            end: AnalysisNormalizedPoint(x: 0.8, y: 0.9)
        )
        #expect(AnalysisAnnotationGeometryEditor.resizing(
            segment,
            controlPoint: .segmentStart,
            to: AnalysisNormalizedPoint(x: 0.3, y: 0.4)
        ) == .segment(
            start: AnalysisNormalizedPoint(x: 0.3, y: 0.4),
            end: AnalysisNormalizedPoint(x: 0.8, y: 0.9)
        ))
        #expect(AnalysisAnnotationGeometryEditor.resizing(
            segment,
            controlPoint: .segmentEnd,
            to: AnalysisNormalizedPoint(x: 0.1, y: 0.2)
        ) == nil)

        let polygonPoints = [
            AnalysisNormalizedPoint(x: 0.125, y: 0.125),
            AnalysisNormalizedPoint(x: 0.625, y: 0.125),
            AnalysisNormalizedPoint(x: 0.375, y: 0.625),
        ]
        let polygon = AnalysisAnnotationGeometry.polygon(polygonPoints)
        #expect(AnalysisAnnotationGeometryEditor.resizing(
            polygon,
            controlPoint: .polygonVertex(2),
            to: AnalysisNormalizedPoint(x: 0.5, y: 0.75)
        ) == .polygon([
            polygonPoints[0],
            polygonPoints[1],
            AnalysisNormalizedPoint(x: 0.5, y: 0.75),
        ]))
        #expect(AnalysisAnnotationGeometryEditor.moving(
            polygon,
            from: AnalysisNormalizedPoint(x: 0.375, y: 0.375),
            to: AnalysisNormalizedPoint(x: 0.5, y: 0.5)
        ) == .polygon([
            AnalysisNormalizedPoint(x: 0.25, y: 0.25),
            AnalysisNormalizedPoint(x: 0.75, y: 0.25),
            AnalysisNormalizedPoint(x: 0.5, y: 0.75),
        ]))

        let annotation = AnalysisAnnotation(kind: .line, geometry: segment)
        let transform = try DisplayImageTransform(
            sourcePixelWidth: 1_000,
            sourcePixelHeight: 1_000,
            exifOrientation: 1
        )
        let mapper = AnalysisAnnotationCoordinateMapper(
            annotationTransform: transform,
            displayTransform: transform
        )
        let viewGeometry = try ImageInspectionGeometry(
            imagePixelSize: CGSize(width: 1_000, height: 1_000),
            containerRect: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )
        #expect(AnalysisAnnotationHitTester.editTarget(
            at: CGPoint(x: 100, y: 200),
            selectedAnnotationID: annotation.id,
            annotations: [annotation],
            geometry: viewGeometry,
            coordinateMapper: mapper
        ) == .resize(annotationID: annotation.id, controlPoint: .segmentStart))
        #expect(AnalysisAnnotationHitTester.editTarget(
            at: CGPoint(x: 450, y: 550),
            selectedAnnotationID: annotation.id,
            annotations: [annotation],
            geometry: viewGeometry,
            coordinateMapper: mapper
        ) == .move(annotationID: annotation.id))
    }

    @Test("annotation coordinates survive developed crop and straighten round-trips")
    func annotationCoordinateRoundTrip() throws {
        let annotationTransform = try DisplayImageTransform(
            sourcePixelWidth: 6_000,
            sourcePixelHeight: 4_000,
            exifOrientation: 6
        )
        let displayTransform = try DisplayImageTransform(
            sourcePixelWidth: 6_000,
            sourcePixelHeight: 4_000,
            exifOrientation: 6,
            developedCrop: DisplayImageTransform.DevelopedCrop(
                sourceNormalizedRect: CGRect(x: 0.1, y: 0.15, width: 0.75, height: 0.7),
                straightenAngleDegrees: 4.5
            )
        )
        let mapper = AnalysisAnnotationCoordinateMapper(
            annotationTransform: annotationTransform,
            displayTransform: displayTransform
        )
        let original = AnalysisNormalizedPoint(x: 0.42, y: 0.61)

        let displayed = mapper.displayPoint(from: original)
        let roundTrip = mapper.annotationPoint(from: displayed)

        #expect(abs(roundTrip.x - original.x) < 1e-9)
        #expect(abs(roundTrip.y - original.y) < 1e-9)
        #expect(abs(Double(displayed.x) - original.x) > 0.01)
    }

    @Test("annotation coordinates survive every orientation and fitted view size")
    func annotationCoordinatesAcrossOrientationsAndViewSizes() throws {
        let annotationPoints = [
            AnalysisNormalizedPoint(x: 0.4, y: 0.4),
            AnalysisNormalizedPoint(x: 0.5, y: 0.5),
            AnalysisNormalizedPoint(x: 0.6, y: 0.6),
        ]
        let containers = [
            CGRect(x: 0, y: 0, width: 320, height: 900),
            CGRect(x: 17, y: 29, width: 1_200, height: 360),
            CGRect(x: 41, y: 73, width: 257, height: 257),
        ]

        for orientation in DisplayImageTransform.Orientation.allCases {
            let annotationTransform = try DisplayImageTransform(
                sourcePixelWidth: 6_000,
                sourcePixelHeight: 4_000,
                exifOrientation: orientation.rawValue
            )
            let displayTransform = try DisplayImageTransform(
                sourcePixelWidth: 6_000,
                sourcePixelHeight: 4_000,
                exifOrientation: orientation.rawValue,
                developedCrop: DisplayImageTransform.DevelopedCrop(
                    sourceNormalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
                    straightenAngleDegrees: 7.5
                )
            )
            let mapper = AnalysisAnnotationCoordinateMapper(
                annotationTransform: annotationTransform,
                displayTransform: displayTransform
            )

            for container in containers {
                let viewGeometry = try ImageInspectionGeometry(
                    imagePixelSize: displayTransform.displayedPixelSize,
                    containerRect: container
                )

                for annotationPoint in annotationPoints {
                    let displayPoint = mapper.displayPoint(from: annotationPoint)
                    let viewPoint = viewGeometry.viewPoint(fromNormalizedDisplay: displayPoint)
                    let recoveredDisplayPoint = try #require(
                        viewGeometry.normalizedDisplayPoint(fromViewPoint: viewPoint)
                    )
                    let recoveredAnnotationPoint = mapper.annotationPoint(
                        from: recoveredDisplayPoint
                    )

                    #expect(abs(recoveredAnnotationPoint.x - annotationPoint.x) < 1e-9)
                    #expect(abs(recoveredAnnotationPoint.y - annotationPoint.y) < 1e-9)
                }
            }
        }
    }

    @Test("distance annotations report original source pixels for every EXIF orientation")
    func sourcePixelDistanceAcrossOrientations() throws {
        for orientation in DisplayImageTransform.Orientation.allCases {
            let transform = try DisplayImageTransform(
                sourcePixelWidth: 4_000,
                sourcePixelHeight: 3_000,
                exifOrientation: orientation.rawValue
            )
            let sourceStart = CGPoint(x: 400, y: 600)
            let sourceEnd = CGPoint(x: 1_300, y: 1_800)
            let displayedStart = transform.displayNormalizedPoint(fromSourcePixel: sourceStart)
            let displayedEnd = transform.displayNormalizedPoint(fromSourcePixel: sourceEnd)
            let annotation = AnalysisAnnotation(
                kind: .distance,
                geometry: .segment(
                    start: AnalysisNormalizedPoint(
                        x: displayedStart.x,
                        y: displayedStart.y
                    ),
                    end: AnalysisNormalizedPoint(
                        x: displayedEnd.x,
                        y: displayedEnd.y
                    )
                )
            )
            let measurement = try #require(AnalysisSourcePixelMeasurement(
                annotation: annotation,
                annotationTransform: transform
            ))

            #expect(abs(measurement.start.x - sourceStart.x) < 1e-9)
            #expect(abs(measurement.start.y - sourceStart.y) < 1e-9)
            #expect(abs(measurement.end.x - sourceEnd.x) < 1e-9)
            #expect(abs(measurement.end.y - sourceEnd.y) < 1e-9)
            #expect(abs(measurement.length - 1_500) < 1e-9)
            let localizedLength = Double(1_500).formatted(
                .number.precision(.fractionLength(0)).grouping(.automatic)
            )
            #expect(measurement.formattedLength == localizedLength + " px")
        }
    }

    @Test("source-pixel measurement ignores developed crop and preview geometry")
    func sourcePixelDistanceIsRepresentationIndependent() throws {
        let annotationTransform = try DisplayImageTransform(
            sourcePixelWidth: 6_000,
            sourcePixelHeight: 4_000,
            exifOrientation: 6
        )
        let developedTransform = try DisplayImageTransform(
            sourcePixelWidth: 6_000,
            sourcePixelHeight: 4_000,
            exifOrientation: 6,
            developedCrop: DisplayImageTransform.DevelopedCrop(
                sourceNormalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6),
                straightenAngleDegrees: 5
            )
        )
        let mapper = AnalysisAnnotationCoordinateMapper(
            annotationTransform: annotationTransform,
            displayTransform: developedTransform
        )
        let annotation = AnalysisAnnotation(
            kind: .distance,
            geometry: .segment(
                start: AnalysisNormalizedPoint(x: 0.25, y: 0.25),
                end: AnalysisNormalizedPoint(x: 0.75, y: 0.25)
            )
        )
        let before = try #require(AnalysisSourcePixelMeasurement(
            annotation: annotation,
            annotationTransform: annotationTransform
        ))
        guard case .segment(let start, let end) = annotation.geometry else {
            Issue.record("Expected distance segment")
            return
        }
        let displayedStart = mapper.displayPoint(from: start)
        let displayedEnd = mapper.displayPoint(from: end)

        #expect(abs(before.length - 2_000) < 1e-9)
        #expect(hypot(
            displayedEnd.x - displayedStart.x,
            displayedEnd.y - displayedStart.y
        ) != before.length)
        #expect(AnalysisSourcePixelMeasurement(
            annotation: AnalysisAnnotation(kind: .line, geometry: annotation.geometry),
            annotationTransform: annotationTransform
        ) == nil)
    }

    @Test("a calibrated segment converts every source-pixel distance across units")
    func calibratedDistanceConversion() throws {
        let transform = try DisplayImageTransform(
            sourcePixelWidth: 4_000,
            sourcePixelHeight: 3_000,
            exifOrientation: 6
        )
        let calibrationStart = transform.displayNormalizedPoint(
            fromSourcePixel: CGPoint(x: 100, y: 200)
        )
        let calibrationEnd = transform.displayNormalizedPoint(
            fromSourcePixel: CGPoint(x: 1_100, y: 200)
        )
        let calibration = AnalysisAnnotation(
            kind: .distance,
            geometry: .segment(
                start: AnalysisNormalizedPoint(
                    x: calibrationStart.x,
                    y: calibrationStart.y
                ),
                end: AnalysisNormalizedPoint(
                    x: calibrationEnd.x,
                    y: calibrationEnd.y
                )
            ),
            measurementCalibration: AnalysisMeasurementCalibration(
                knownLength: 25,
                unit: .centimeters
            )
        )
        let scale = try #require(AnalysisMeasurementScale(
            annotations: [calibration],
            annotationTransform: transform
        ))

        #expect(abs(scale.metersPerPixel - 0.00025) < 1e-12)
        #expect(abs(scale.length(forPixelLength: 500) - 12.5) < 1e-12)
        #expect(abs(
            scale.length(forPixelLength: 500, in: .inches) - 4.9212598425
        ) < 1e-9)
        #expect(scale.formattedLength(forPixelLength: 500).hasSuffix(" cm"))

        let measurement = try #require(AnalysisSourcePixelMeasurement(
            annotation: calibration,
            annotationTransform: transform
        ))
        #expect(measurement.formattedLength(calibratedBy: scale).contains("25 cm"))
        #expect(measurement.formattedLength(calibratedBy: scale).hasSuffix("px"))
    }

    @Test("calibration is valid only on one positive-length distance annotation")
    func validatesMeasurementCalibration() async throws {
        let invalidCalibration = AnalysisMeasurementCalibration(
            knownLength: 0,
            unit: .meters
        )
        let invalidKind = AnalysisAnnotation(
            kind: .line,
            geometry: .segment(
                start: AnalysisNormalizedPoint(x: 0.1, y: 0.1),
                end: AnalysisNormalizedPoint(x: 0.2, y: 0.2)
            ),
            measurementCalibration: AnalysisMeasurementCalibration(
                knownLength: 1,
                unit: .meters
            )
        )
        #expect(!invalidCalibration.isValid)
        #expect(throws: AnalysisAnnotationValidationError.invalidCalibration) {
            try invalidKind.validate()
        }

        let fixture = try AnalysisFixture(contents: "duplicate calibration source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let segment = AnalysisAnnotationGeometry.segment(
            start: AnalysisNormalizedPoint(x: 0.1, y: 0.1),
            end: AnalysisNormalizedPoint(x: 0.8, y: 0.8)
        )
        analysisCase.setAnnotation(AnalysisAnnotation(
            kind: .distance,
            geometry: segment,
            measurementCalibration: AnalysisMeasurementCalibration(
                knownLength: 1,
                unit: .meters
            )
        ))
        analysisCase.setAnnotation(AnalysisAnnotation(
            kind: .distance,
            geometry: segment,
            measurementCalibration: AnalysisMeasurementCalibration(
                knownLength: 2,
                unit: .meters
            )
        ))

        #expect(throws: AnalysisCaseValidationError.invalidAnnotations) {
            try analysisCase.validateForPersistence()
        }
    }

    @Test("photo annotation history undoes, redoes, and discards a branched redo")
    func photoAnnotationUndoRedoTransactions() throws {
        let first = AnalysisAnnotation(
            kind: .label,
            geometry: .anchor(AnalysisNormalizedPoint(x: 0.2, y: 0.3)),
            text: "First"
        )
        let second = AnalysisAnnotation(
            kind: .label,
            geometry: .anchor(AnalysisNormalizedPoint(x: 0.7, y: 0.8)),
            text: "Second"
        )
        let replacement = AnalysisAnnotation(
            kind: .rectangle,
            geometry: .bounds(AnalysisNormalizedBounds(
                minimum: AnalysisNormalizedPoint(x: 0.1, y: 0.1),
                maximum: AnalysisNormalizedPoint(x: 0.4, y: 0.4)
            ))
        )
        var history = AnalysisAnnotationUndoHistory()

        history.record(before: [], after: [first], actionName: "Add Annotation")
        history.record(
            before: [first],
            after: [first, second],
            actionName: "Add Annotation"
        )

        #expect(history.undoActionName == "Add Annotation")
        #expect(history.undo() == [first])
        #expect(history.canRedo)
        #expect(history.redo() == [first, second])
        #expect(history.undo() == [first])

        history.record(
            before: [first],
            after: [first, replacement],
            actionName: "Add Annotation"
        )
        #expect(!history.canRedo)
        #expect(history.redo() == nil)
        #expect(history.undo() == [first])
        #expect(history.undo() == [])
        #expect(!history.canUndo)
    }

    @Test("photo annotation transfer creates independent source-safe copies")
    func photoAnnotationTransferCopies() throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let source = AnalysisAnnotation(
            kind: .distance,
            geometry: .segment(
                start: AnalysisNormalizedPoint(x: 0.1, y: 0.2),
                end: AnalysisNormalizedPoint(x: 0.8, y: 0.9)
            ),
            text: "Measured edge",
            note: "Keep this note",
            style: AnalysisAnnotationStyle(
                color: .palette(.cyan),
                lineWidthPoints: 4,
                fillOpacity: 0.2
            ),
            isVisible: false,
            findingIDs: ["source-only-finding"],
            measurementCalibration: AnalysisMeasurementCalibration(
                knownLength: 25,
                unit: .centimeters
            ),
            now: Date(timeIntervalSince1970: 50)
        )

        let copy = try #require(AnalysisAnnotationTransfer.copies(
            of: [source],
            now: timestamp
        ).first)

        #expect(copy.id != source.id)
        #expect(copy.kind == source.kind)
        #expect(copy.geometry == source.geometry)
        #expect(copy.text == source.text)
        #expect(copy.note == source.note)
        #expect(copy.style == source.style)
        #expect(copy.isVisible == source.isVisible)
        #expect(copy.findingIDs.isEmpty)
        #expect(copy.measurementCalibration == nil)
        #expect(copy.createdAt == timestamp)
        #expect(copy.updatedAt == timestamp)
        try copy.validate()
    }

    @Test("pasting photo annotations appends independent copies without changing map context")
    func pastesAnnotationsIntoTargetCase() async throws {
        let fixture = try AnalysisFixture(contents: "annotation paste target")
        defer { fixture.remove() }
        let image = ImageFile(url: fixture.fileURL)
        let revision = try await SourceImageRevision.capture(at: image.url)
        let existing = AnalysisAnnotation(
            kind: .label,
            geometry: .anchor(AnalysisNormalizedPoint(x: 0.2, y: 0.3)),
            text: "Existing"
        )
        var targetCase = AnalysisCase.create(for: revision, appBuild: "test")
        targetCase.setAnnotation(existing)
        let existingPhotoMapMarker = AnalysisMapAnnotation(
            kind: .marker,
            geometry: .point(AnalysisGeoCoordinate(latitude: 59.91, longitude: 10.75)),
            text: "Existing map context"
        )
        targetCase.setMapAnnotation(existingPhotoMapMarker)
        let repository = AnalysisCaseRepository(sourceFolderURL: fixture.directoryURL)
        try await repository.save(targetCase)

        let source = AnalysisAnnotation(
            kind: .rectangle,
            geometry: .bounds(AnalysisNormalizedBounds(
                minimum: AnalysisNormalizedPoint(x: 0.1, y: 0.2),
                maximum: AnalysisNormalizedPoint(x: 0.7, y: 0.8)
            )),
            note: "Copied note",
            findingIDs: ["source-finding"]
        )
        let model = AnalysisWorkspaceModel(analyzers: [])

        try await model.pastePhotoAnnotations([source], to: image)

        let match = await repository.loadMostRelevantCase(for: revision)
        guard case .exact(let pastedCase) = match else {
            Issue.record("Expected the target case after annotation paste")
            return
        }
        #expect(pastedCase.annotations.count == 2)
        #expect(pastedCase.annotations.first?.id == existing.id)
        let pasted = try #require(pastedCase.annotations.last)
        #expect(pasted.id != source.id)
        #expect(pasted.geometry == source.geometry)
        #expect(pasted.note == source.note)
        #expect(pasted.findingIDs.isEmpty)
        #expect(pastedCase.mapState.annotations.map(\.id) == [existingPhotoMapMarker.id])
        try pastedCase.validateForPersistence()
    }

    @Test("photo annotation history keeps only its configured transaction bound")
    func photoAnnotationUndoBound() {
        let annotation = AnalysisAnnotation(
            kind: .label,
            geometry: .anchor(AnalysisNormalizedPoint(x: 0.5, y: 0.5)),
            text: "Bound"
        )
        var history = AnalysisAnnotationUndoHistory(maximumTransactionCount: 2)

        history.record(before: [], after: [annotation], actionName: "One")
        history.record(before: [annotation], after: [], actionName: "Two")
        history.record(before: [], after: [annotation], actionName: "Three")

        #expect(history.undoActionName == "Three")
        #expect(history.undo() == [])
        #expect(history.undo() == [annotation])
        #expect(history.undo() == nil)
    }

    @Test("calibration replacement participates in photo annotation undo and redo")
    func calibrationUndoRedoTransaction() throws {
        let geometry = AnalysisAnnotationGeometry.segment(
            start: AnalysisNormalizedPoint(x: 0.1, y: 0.2),
            end: AnalysisNormalizedPoint(x: 0.8, y: 0.9)
        )
        let first = AnalysisAnnotation(
            kind: .distance,
            geometry: geometry,
            measurementCalibration: AnalysisMeasurementCalibration(
                knownLength: 20,
                unit: .centimeters
            )
        )
        let uncalibratedSecond = AnalysisAnnotation(kind: .distance, geometry: geometry)
        var second = uncalibratedSecond
        var clearedFirst = first
        clearedFirst.measurementCalibration = nil
        second.measurementCalibration = AnalysisMeasurementCalibration(
            knownLength: 8,
            unit: .inches
        )
        var history = AnalysisAnnotationUndoHistory()

        history.record(
            before: [first, uncalibratedSecond],
            after: [clearedFirst, second],
            actionName: "Set Measurement Calibration"
        )

        let undoResult = history.undo()
        let restored = try #require(undoResult)
        #expect(restored.first?.measurementCalibration?.knownLength == 20)
        #expect(restored.last?.measurementCalibration == nil)
        let redoResult = history.redo()
        let replaced = try #require(redoResult)
        #expect(replaced.first?.measurementCalibration == nil)
        #expect(replaced.last?.measurementCalibration?.unit == .inches)
    }

    @Test("restoring an annotation transaction keeps the case persistently valid")
    func restoredAnnotationCollectionIsValid() async throws {
        let fixture = try AnalysisFixture(contents: "undo source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(
            for: revision,
            appBuild: "test",
            now: Date(timeIntervalSince1970: 10)
        )
        let annotation = AnalysisAnnotation(
            kind: .line,
            geometry: .segment(
                start: AnalysisNormalizedPoint(x: 0.1, y: 0.2),
                end: AnalysisNormalizedPoint(x: 0.8, y: 0.9)
            ),
            now: Date(timeIntervalSince1970: 20)
        )

        analysisCase.replaceAnnotations([annotation], now: Date(timeIntervalSince1970: 15))

        #expect(analysisCase.annotations == [annotation])
        #expect(analysisCase.updatedAt == Date(timeIntervalSince1970: 20))
        try analysisCase.validateForPersistence()
    }

    @Test("cache keys include source, analyzer version, and sorted parameters")
    func cacheKeysAreExactAndDeterministic() {
        let first = AnalysisCacheKey(
            sourceSHA256: String(repeating: "a", count: 64),
            analyzerID: "metadata",
            analyzerVersion: 2,
            parameters: ["z": "last", "a": "first"]
        )
        let reordered = AnalysisCacheKey(
            sourceSHA256: String(repeating: "a", count: 64),
            analyzerID: "metadata",
            analyzerVersion: 2,
            parameters: ["a": "first", "z": "last"]
        )
        let newer = AnalysisCacheKey(
            sourceSHA256: String(repeating: "a", count: 64),
            analyzerID: "metadata",
            analyzerVersion: 3,
            parameters: ["a": "first", "z": "last"]
        )

        #expect(first == reordered)
        #expect(first != newer)
    }

    @Test("C2PA validity and signer trust remain separate")
    func c2paAxesRemainSeparate() {
        let untrusted = AnalysisC2PAEvidence(
            isPresent: true,
            result: C2PAValidationResult(
                status: .untrusted,
                message: "Signature valid; signer not trusted."
            )
        )
        #expect(untrusted.validity == .valid)
        #expect(untrusted.trust == .untrusted)

        let invalid = AnalysisC2PAEvidence(
            isPresent: true,
            result: C2PAValidationResult(
                status: .invalid,
                message: "Signature invalid."
            )
        )
        #expect(invalid.validity == .invalid)
        #expect(invalid.trust == .notApplicable)
    }

    @Test("metadata rules preserve and surface namespace conflicts")
    func metadataNamespaceConflict() {
        let facts = makeSourceFacts(camera: "Example Camera")
        let entries = [
            AnalysisRawMetadataEntry(
                id: "exif.orientation",
                namespace: "EXIF",
                key: "Orientation",
                value: "1",
                origin: .exif
            ),
            AnalysisRawMetadataEntry(
                id: "tiff.orientation",
                namespace: "TIFF",
                key: "Orientation",
                value: "6",
                origin: .tiff
            ),
        ]

        let findings = MetadataConsistencyRuleEngine.evaluate(
            facts: facts,
            rawMetadata: entries,
            analyzerID: "test",
            analyzerVersion: 1,
            now: Date(timeIntervalSince1970: 1)
        )

        let conflict = findings.first { $0.id == "metadata.namespace-conflict.orientation" }
        #expect(conflict?.severity == .caution)
        #expect(conflict?.technicalDetail.contains("EXIF.Orientation = 1") == true)
        #expect(conflict?.technicalDetail.contains("TIFF.Orientation = 6") == true)
        #expect(conflict?.includeInReport == true)
    }

    @Test("source-facts analysis does not modify source bytes or create sidecars")
    func sourceFactsAnalyzerIsReadOnly() async throws {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let fixture = try AnalysisFixture(data: png, extension: "png")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let beforeBytes = try Data(contentsOf: fixture.fileURL)
        let beforeContents = try Set(FileManager.default.contentsOfDirectory(
            atPath: fixture.directoryURL.path
        ))

        _ = try await SourceFactsAnalyzer().analyze(
            context: AnalysisAnalyzerContext(
                sourceURL: fixture.fileURL,
                sourceRevision: revision
            ),
            parameters: [:],
            progress: { _ in }
        )

        #expect(try Data(contentsOf: fixture.fileURL) == beforeBytes)
        #expect(try Set(FileManager.default.contentsOfDirectory(
            atPath: fixture.directoryURL.path
        )) == beforeContents)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.fileURL.deletingPathExtension().appendingPathExtension("xmp").path
        ))
    }

    @Test("runner publishes progress and cancellation as state")
    func runnerCancellation() async throws {
        let fixture = try AnalysisFixture(contents: "runner source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let runner = AnalysisRunner()
        let analyzer = SuspendedAnalysisAnalyzer()

        runner.start(
            analyzer,
            context: AnalysisAnalyzerContext(
                sourceURL: fixture.fileURL,
                sourceRevision: revision
            )
        )
        try await waitForAnalysisState {
            runner.runs.first?.status == .running
                && runner.runs.first?.progress == 0.5
        }
        runner.cancel(analyzerID: analyzer.identifier)
        try await waitForAnalysisState {
            runner.runs.first?.status == .cancelled
        }

        #expect(runner.runs.first?.completedAt != nil)
        #expect(runner.runs.first?.output == nil)
    }

    @Test("runner reuses only an exact completed cache key")
    func runnerCacheReuse() async throws {
        let fixture = try AnalysisFixture(contents: "cached source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let counter = AnalysisInvocationCounter()
        let analyzer = ImmediateAnalysisAnalyzer(counter: counter)
        let runner = AnalysisRunner()
        let context = AnalysisAnalyzerContext(
            sourceURL: fixture.fileURL,
            sourceRevision: revision
        )

        runner.start(analyzer, context: context, parameters: ["mode": "fast"])
        try await waitForAnalysisState {
            runner.runs.first?.status == .completed
        }
        runner.start(analyzer, context: context, parameters: ["mode": "fast"])
        await Task.yield()
        #expect(counter.count == 1)

        runner.start(analyzer, context: context, parameters: ["mode": "thorough"])
        try await waitForAnalysisState {
            runner.runs.first?.status == .completed && counter.count == 2
        }
        #expect(counter.count == 2)
    }
}

private func makeSourceFacts(
    camera: String? = nil,
    fileModificationDate: Date? = nil,
    captureDate: String? = "2026:01:01 10:00:00",
    captureTimezoneKnown: Bool = false
) -> AnalysisSourceFacts {
    AnalysisSourceFacts(
        filename: "source.jpg",
        canonicalPath: "/tmp/source.jpg",
        sha256: String(repeating: "a", count: 64),
        byteCount: 10,
        fileExtension: "jpg",
        detectedTypeIdentifier: "public.jpeg",
        detectedMIMEType: "image/jpeg",
        pixelWidth: 10,
        pixelHeight: 10,
        orientation: 1,
        bitDepth: 8,
        hasAlpha: false,
        colorProfile: "sRGB",
        frameCount: 1,
        isAnimated: false,
        isHDR: false,
        fileCreationDate: nil,
        fileModificationDate: fileModificationDate,
        captureDate: captureDate,
        captureTimezoneKnown: captureTimezoneKnown,
        camera: camera,
        lens: nil,
        focalLength: nil,
        aperture: nil,
        shutterSpeed: nil,
        iso: nil,
        serialNumber: nil,
        software: nil,
        latitude: nil,
        longitude: nil,
        gpsTimestamp: nil,
        digitalSourceType: nil,
        sidecarPath: nil,
        sidecarModificationDate: nil,
        c2pa: AnalysisC2PAEvidence(
            isPresent: false,
            result: C2PAValidationResult(
                status: .notPresent,
                message: "No manifest."
            )
        )
    )
}

private struct AnalysisFixture {
    let directoryURL: URL
    let fileURL: URL

    init(contents: String, extension fileExtension: String = "jpg") throws {
        try self.init(data: Data(contents.utf8), extension: fileExtension)
    }

    init(data: Data, extension fileExtension: String) throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-analysis-case-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        fileURL = directoryURL.appendingPathComponent("source.\(fileExtension)")
        try data.write(to: fileURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class AnalysisInvocationCounter {
    var count = 0
}

private struct ImmediateAnalysisAnalyzer: AnalysisAnalyzer {
    let identifier = "test-immediate"
    let version = 1
    let displayName = "Immediate test analyzer"
    let cost = AnalysisAnalyzerCost.fast
    let sourceRepresentation = AnalysisInputRepresentation.originalBytes
    let counter: AnalysisInvocationCounter

    func analyze(
        context: AnalysisAnalyzerContext,
        parameters: [String: String],
        progress: @MainActor @Sendable (Double) -> Void
    ) async throws -> AnalysisAnalyzerOutput {
        counter.count += 1
        progress(1)
        return AnalysisAnalyzerOutput()
    }
}

private struct SuspendedAnalysisAnalyzer: AnalysisAnalyzer {
    let identifier = "test-suspended"
    let version = 1
    let displayName = "Suspended test analyzer"
    let cost = AnalysisAnalyzerCost.fast
    let sourceRepresentation = AnalysisInputRepresentation.originalBytes

    func analyze(
        context: AnalysisAnalyzerContext,
        parameters: [String: String],
        progress: @MainActor @Sendable (Double) -> Void
    ) async throws -> AnalysisAnalyzerOutput {
        progress(0.5)
        try await Task.sleep(for: .seconds(30))
        return AnalysisAnalyzerOutput()
    }
}

private enum AnalysisTestTimeout: Error {
    case timedOut
}

private func waitForAnalysisState(
    _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AnalysisTestTimeout.timedOut
}

private func waitForPersistedSolarOverlay(
    _ expected: AnalysisSolarOverlayState?,
    repository: AnalysisCaseRepository,
    revision: SourceImageRevision
) async throws {
    for _ in 0..<200 {
        if case .exact(let analysisCase) = await repository.loadMostRelevantCase(for: revision),
           analysisCase.mapState.solarOverlay == expected {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AnalysisTestTimeout.timedOut
}

private func makeSolarOverlay(
    linkedTimestampEvidenceID: UUID? = nil
) -> AnalysisSolarOverlayState {
    AnalysisSolarOverlayState(
        timestamp: AnalysisTimestampValue(
            year: 2026,
            month: 8,
            day: 19,
            hour: 14,
            minute: 35,
            precision: .minute,
            utcOffsetMinutes: 120
        ),
        linkedTimestampEvidenceID: linkedTimestampEvidenceID,
        showsSunriseDirection: false,
        calculationMethod: .meeusNOAAV1
    )
}
