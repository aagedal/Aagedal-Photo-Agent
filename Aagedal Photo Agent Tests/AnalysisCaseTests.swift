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

        #expect(analysisCase.schemaVersion == 1)
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
}

private struct AnalysisFixture {
    let directoryURL: URL
    let fileURL: URL

    init(contents: String, extension fileExtension: String = "jpg") throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-analysis-case-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        fileURL = directoryURL.appendingPathComponent("source.\(fileExtension)")
        try Data(contents.utf8).write(to: fileURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
