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
        #expect(Set(manifest.files.map(\.path)) == [
            ".photo_analysis/cases/case.analysis.json",
            ".photo_analysis/folder-map.analysis.json",
            ".photo_metadata/evidence.jpg.meta.json",
            ".photo_versions/catalog.json",
            "evidence.jpg",
            "evidence.xmp",
        ])
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

    @Test("an interrupted import preserves an empty destination and retry commits atomically")
    func interruptedImportPreservesEmptyDestination() async throws {
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

        let destination = fixture.root.appendingPathComponent("Imported", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        await #expect(throws: InjectedArchiveInterruption.beforeCommit) {
            try await ImageAnalysisProjectArchive.importProject(
                from: archiveURL,
                to: destination,
                installStaging: { staging, finalDestination, destinationExisted in
                    #expect(FileManager.default.fileExists(
                        atPath: staging.appendingPathComponent("evidence.jpg").path
                    ))
                    #expect(finalDestination == destination)
                    #expect(destinationExisted)
                    throw InjectedArchiveInterruption.beforeCommit
                }
            )
        }

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: fixture.root,
            includingPropertiesForKeys: nil
        )
        #expect(!siblings.contains {
            $0.lastPathComponent.hasPrefix(".Imported.")
                && $0.lastPathComponent.hasSuffix(".importing")
        })

        _ = try await ImageAnalysisProjectArchive.importProject(
            from: archiveURL,
            to: destination
        )
        #expect(try String(
            contentsOf: destination.appendingPathComponent("evidence.jpg"),
            encoding: .utf8
        ) == "source-image")
    }

    @MainActor
    @Test("archive filesystem work leaves MainActor and complete workflows are serialized")
    func archiveIOIsOffMainAndSerialized() async throws {
        let probe = BlockingProjectArchiveIOProbe(blockFirstExport: true)
        let service = ImageAnalysisProjectArchiveService(io: probe.io)
        let firstRequest = projectArchiveExportRequest(destinationName: "First.pint")
        let secondRequest = projectArchiveExportRequest(destinationName: "Second.pint")

        let first = Task { @MainActor in try await service.export(firstRequest) }
        try await probe.waitUntilFirstExportStarts()
        let second = Task { @MainActor in try await service.export(secondRequest) }
        await Task.yield()

        #expect(probe.exportInvocationCount == 1)
        probe.releaseFirstExport()
        _ = try await first.value
        _ = try await second.value

        #expect(probe.exportInvocationCount == 2)
        #expect(probe.maximumConcurrentExports == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("a queued cancelled archive operation never starts filesystem work")
    func queuedCancellationIsExplicit() async throws {
        let probe = BlockingProjectArchiveIOProbe(blockFirstExport: true)
        let service = ImageAnalysisProjectArchiveService(io: probe.io)
        let first = Task {
            try await service.export(projectArchiveExportRequest(destinationName: "First.pint"))
        }
        try await probe.waitUntilFirstExportStarts()
        let second = Task {
            try await service.export(projectArchiveExportRequest(destinationName: "Second.pint"))
        }
        second.cancel()
        probe.releaseFirstExport()

        _ = try await first.value
        await #expect(throws: CancellationError.self) {
            try await second.value
        }
        #expect(probe.exportInvocationCount == 1)
    }

    @Test("cancellation during a non-preemptible commit returns durable commit evidence")
    func cancellationAfterCommitIsExplicit() async throws {
        let probe = BlockingProjectArchiveIOProbe(cancelDuringExport: true)
        let service = ImageAnalysisProjectArchiveService(io: probe.io)
        let request = projectArchiveExportRequest(destinationName: "Committed.pint")

        let commit = try await Task {
            try await service.export(request)
        }.value

        #expect(commit.requestID == request.requestID)
        #expect(commit.destinationURL == request.destinationURL)
        #expect(commit.cancellationObservedAfterCommit)
        #expect(probe.exportInvocationCount == 1)
    }

    @Test("source contract routes UI archive calls through the serialized service")
    func sourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let archiveSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/ImageAnalysisProjectArchive.swift"
            ),
            encoding: .utf8
        )
        let workspaceSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Analysis/AnalysisWorkspaceView.swift"
            ),
            encoding: .utf8
        )

        #expect(archiveSource.contains("actor ImageAnalysisProjectArchiveService"))
        #expect(archiveSource.contains("try await service.export("))
        #expect(archiveSource.contains("try await service.inspect("))
        #expect(archiveSource.contains("try await service.importProject("))
        #expect(archiveSource.contains("try Task.checkCancellation()\n        if let installStaging"))
        #expect(archiveSource.contains("cancellationObservedAfterCommit: Task.isCancelled"))
        #expect(workspaceSource.contains("try await ImageAnalysisProjectArchive.export("))
        #expect(workspaceSource.contains("try await ImageAnalysisProjectArchive.inspect("))
        #expect(workspaceSource.contains("try await ImageAnalysisProjectArchive.importProject("))
        #expect(workspaceSource.contains("Process()") == false)
        #expect(workspaceSource.contains("Data(contentsOf:") == false)
    }

    private nonisolated func projectArchiveExportRequest(
        destinationName: String
    ) -> ImageAnalysisProjectArchiveExportRequest {
        ImageAnalysisProjectArchiveExportRequest(
            requestID: UUID(),
            sourceFolderURL: URL(fileURLWithPath: "/virtual/source", isDirectory: true),
            imageURLs: [URL(fileURLWithPath: "/virtual/source/evidence.jpg")],
            title: "Project",
            destinationURL: URL(fileURLWithPath: "/virtual/\(destinationName)"),
            appVersion: "3.0",
            appBuild: "test"
        )
    }
}

private enum InjectedArchiveInterruption: Error {
    case beforeCommit
}

private nonisolated final class BlockingProjectArchiveIOProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let blockFirstExport: Bool
    private let cancelDuringExport: Bool
    private var exportCount = 0
    private var activeExports = 0
    private var maximumActiveExports = 0
    private var firstExportReleased = false
    private var observedMainThread = false

    init(blockFirstExport: Bool = false, cancelDuringExport: Bool = false) {
        self.blockFirstExport = blockFirstExport
        self.cancelDuringExport = cancelDuringExport
    }

    var io: ImageAnalysisProjectArchiveIO {
        ImageAnalysisProjectArchiveIO(
            export: { [self] request in
                condition.lock()
                exportCount += 1
                activeExports += 1
                maximumActiveExports = max(maximumActiveExports, activeExports)
                observedMainThread = observedMainThread || Thread.isMainThread
                condition.broadcast()
                if blockFirstExport && exportCount == 1 {
                    while !firstExportReleased { condition.wait() }
                }
                activeExports -= 1
                condition.unlock()

                if cancelDuringExport {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return ImageAnalysisProjectArchiveExportCommit(
                    requestID: request.requestID,
                    manifest: Self.manifest,
                    destinationURL: request.destinationURL,
                    cancellationObservedAfterCommit: false
                )
            },
            inspect: { _ in
                ImageAnalysisProjectArchive.Preview(
                    title: "Project",
                    exportedAt: .distantPast,
                    imageCount: 1,
                    fileCount: 1
                )
            },
            importProject: { request in
                ImageAnalysisProjectArchiveImportCommit(
                    requestID: request.requestID,
                    manifest: Self.manifest,
                    destinationURL: request.destinationURL,
                    replacedEmptyDestination: false,
                    cancellationObservedAfterCommit: false
                )
            }
        )
    }

    func waitUntilFirstExportStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while exportInvocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw ProjectArchiveProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstExport() {
        condition.lock()
        firstExportReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var exportInvocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return exportCount
    }

    var maximumConcurrentExports: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveExports
    }

    var ranOnMainThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return observedMainThread
    }

    private static let manifest = ImageAnalysisProjectArchive.Manifest(
        schemaVersion: ImageAnalysisProjectArchive.currentSchemaVersion,
        projectID: UUID(),
        title: "Project",
        exportedAt: .distantPast,
        exportedByAppVersion: "3.0",
        exportedByAppBuild: "test",
        files: []
    )
}

private enum ProjectArchiveProbeError: Error {
    case timedOut
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
