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

        #expect(analysisCase.schemaVersion == 2)
        #expect(analysisCase.source == revision)
        #expect(analysisCase.workspaceMode == .pixelAnalysis)
        #expect(analysisCase.displayPreference == .original)
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

    @Test("version one shell cases migrate with an empty analyzer cache")
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
        #expect(migrated.schemaVersion == 2)
        #expect(migrated.analyzerRuns.isEmpty)
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
