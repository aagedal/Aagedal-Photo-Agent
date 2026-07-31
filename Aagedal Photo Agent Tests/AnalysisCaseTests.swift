import CoreGraphics
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Analysis case")
struct AnalysisCaseTests {
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

        #expect(analysisCase.schemaVersion == 3)
        #expect(analysisCase.source == revision)
        #expect(analysisCase.workspaceMode == .pixelAnalysis)
        #expect(analysisCase.displayPreference == .original)
        #expect(analysisCase.annotations.isEmpty)
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
        #expect(migrated.schemaVersion == 3)
        #expect(migrated.analyzerRuns.isEmpty)
        #expect(migrated.annotations.isEmpty)
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
        #expect(migrated.schemaVersion == 3)
        #expect(migrated.analyzerRuns == analysisCase.analyzerRuns)
        #expect(migrated.annotations.isEmpty)
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
            findingIDs: ["metadata.orientation-conflict"],
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
        #expect(reopened.annotations.first?.updatedAt == Date(timeIntervalSince1970: 12))
        #expect(reopened.updatedAt == Date(timeIntervalSince1970: 12))
        try reopened.validateForPersistence()
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

private func makeSourceFacts(camera: String? = nil) -> AnalysisSourceFacts {
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
        fileModificationDate: nil,
        captureDate: "2026:01:01 10:00:00",
        captureTimezoneKnown: false,
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
