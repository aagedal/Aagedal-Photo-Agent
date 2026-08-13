import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Image Analysis Project archive")
struct ImageAnalysisProjectArchiveTests {
    @Test("pint round-trip preserves images, sidecars, and folder metadata")
    func roundTrip() async throws {
        let fixture = try ProjectArchiveFixture()
        defer { fixture.remove() }

        let imageURL = try fixture.write("evidence.jpg", contents: "source-image")
        _ = try fixture.write("evidence.xmp", contents: "<xmp>metadata</xmp>")
        let revision = try await SourceImageRevision.capture(at: imageURL)
        let analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        _ = try fixture.write(
            ".photo_analysis/cases/case.analysis.json",
            data: encoder.encode(analysisCase)
        )
        _ = try fixture.write(".photo_analysis/folder-map.analysis.json", contents: "map")
        _ = try fixture.write(".photo_metadata/evidence.jpg.meta.json", contents: "metadata")
        _ = try fixture.write(".photo_versions/catalog.json", contents: "versions")

        let archiveURL = fixture.root.appendingPathComponent("Project.pint")
        let manifest = try await ImageAnalysisProjectArchive.export(
            sourceFolderURL: fixture.source,
            imageURLs: [imageURL],
            title: "Evidence Project",
            destinationURL: archiveURL,
            appVersion: "2.3",
            appBuild: "1"
        )

        #expect(manifest.files.count == 6)
        #expect(manifest.files.count { $0.kind == .image } == 1)
        #expect(manifest.files.count { $0.kind == .xmpSidecar } == 1)
        let preview = try await ImageAnalysisProjectArchive.inspect(archiveURL)
        #expect(preview.title == "Evidence Project")
        #expect(preview.imageCount == 1)

        let destination = fixture.root.appendingPathComponent("Imported", isDirectory: true)
        let imported = try await ImageAnalysisProjectArchive.importProject(
            from: archiveURL,
            to: destination
        )
        #expect(imported == manifest)
        #expect(try String(
            contentsOf: destination.appendingPathComponent("evidence.jpg"),
            encoding: .utf8
        ) == "source-image")
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(
                ".photo_analysis/folder-map.analysis.json"
            ).path
        ))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let importedCase = try decoder.decode(
            AnalysisCase.self,
            from: Data(contentsOf: destination.appendingPathComponent(
                ".photo_analysis/cases/case.analysis.json"
            ))
        )
        #expect(importedCase.source.canonicalURL == destination
            .appendingPathComponent("evidence.jpg")
            .standardizedFileURL)
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(
                ".photo_metadata/evidence.jpg.meta.json"
            ).path
        ))
    }

    @Test("import refuses to merge a project into a non-empty folder")
    func refusesNonEmptyDestination() async throws {
        let fixture = try ProjectArchiveFixture()
        defer { fixture.remove() }
        let imageURL = try fixture.write("evidence.jpg", contents: "source-image")
        let archiveURL = fixture.root.appendingPathComponent("Project.pint")
        try await ImageAnalysisProjectArchive.export(
            sourceFolderURL: fixture.source,
            imageURLs: [imageURL],
            title: "Project",
            destinationURL: archiveURL,
            appVersion: "2.3",
            appBuild: "1"
        )

        let destination = fixture.root.appendingPathComponent("Existing", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep-me".utf8).write(to: destination.appendingPathComponent("existing.txt"))

        await #expect(throws: ImageAnalysisProjectArchive.ArchiveError.destinationNotEmpty) {
            try await ImageAnalysisProjectArchive.importProject(
                from: archiveURL,
                to: destination
            )
        }
        #expect(try String(
            contentsOf: destination.appendingPathComponent("existing.txt"),
            encoding: .utf8
        ) == "keep-me")
    }
}

private struct ProjectArchiveFixture {
    let root: URL
    let source: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pint-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, contents: String) throws -> URL {
        try write(relativePath, data: Data(contents.utf8))
    }

    func write(_ relativePath: String, data: Data) throws -> URL {
        let url = source.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
