import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Source image discovery")
struct SourceImageDiscoveryServiceTests {
    @Test("the recorded path is preferred after its hash is verified")
    func locatesCurrentPath() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.write("source.raw", contents: "same bytes")
        let source = try await SourceImageRevision.capture(at: sourceURL)

        let result = try await SourceImageDiscoveryService().discover(source, among: [])

        guard case .located(let located, let method) = result else {
            Issue.record("Expected the source at its current path")
            return
        }
        #expect(located.canonicalURL == sourceURL.standardizedFileURL)
        #expect(method == .currentPath)
    }

    @Test("a moved source is found by resource ID only after its hash matches")
    func locatesMovedSourceByResourceIdentifier() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let originalURL = try fixture.write("original.raw", contents: "move me")
        let source = try await SourceImageRevision.capture(at: originalURL)
        let movedURL = fixture.directoryURL.appendingPathComponent("moved.raw")
        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        let result = try await SourceImageDiscoveryService().discover(
            source,
            among: [movedURL]
        )

        guard case .located(let located, let method) = result else {
            Issue.record("Expected the moved source")
            return
        }
        #expect(located.canonicalURL == movedURL.standardizedFileURL)
        #expect(located.sha256 == source.sha256)
        #expect(method == .fileResourceIdentifier)
    }

    @Test("a unique byte-for-byte copy can be reassociated by hash")
    func locatesUniqueCopyByHash() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let originalURL = try fixture.write("original.raw", contents: "copy me")
        let source = try await SourceImageRevision.capture(at: originalURL)
        let copyURL = try fixture.write("copy.raw", contents: "copy me")
        try FileManager.default.removeItem(at: originalURL)

        let result = try await SourceImageDiscoveryService().discover(
            source,
            among: [copyURL]
        )

        guard case .located(let located, let method) = result else {
            Issue.record("Expected the unique hash match")
            return
        }
        #expect(located.canonicalURL == copyURL.standardizedFileURL)
        #expect(method == .contentHash)
    }

    @Test("multiple hash-only copies require an explicit user choice")
    func reportsAmbiguousCopies() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let originalURL = try fixture.write("original.raw", contents: "duplicate")
        let source = try await SourceImageRevision.capture(at: originalURL)
        let firstCopy = try fixture.write("a.raw", contents: "duplicate")
        let secondCopy = try fixture.write("b.raw", contents: "duplicate")
        try FileManager.default.removeItem(at: originalURL)

        let result = try await SourceImageDiscoveryService().discover(
            source,
            among: [secondCopy, firstCopy]
        )

        guard case .ambiguous(let matches) = result else {
            Issue.record("Expected ambiguous exact matches")
            return
        }
        #expect(matches.map(\.canonicalURL) == [
            firstCopy.standardizedFileURL,
            secondCopy.standardizedFileURL
        ])
    }

    @Test("changed bytes at the recorded location are never silently reassociated")
    func reportsChangedSource() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.write("source.raw", contents: "before")
        let source = try await SourceImageRevision.capture(at: sourceURL)
        try Data("after!".utf8).write(to: sourceURL)

        let result = try await SourceImageDiscoveryService().discover(
            source,
            among: [sourceURL]
        )

        guard case .sourceChanged(let changed) = result else {
            Issue.record("Expected changed source state")
            return
        }
        #expect(changed.canonicalURL == sourceURL.standardizedFileURL)
        #expect(changed.sha256 != source.sha256)
    }

    @Test("different-size candidates are rejected and no match is reported")
    func reportsNotFound() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let originalURL = try fixture.write("source.raw", contents: "source")
        let source = try await SourceImageRevision.capture(at: originalURL)
        let unrelatedURL = try fixture.write("other.raw", contents: "a different size")
        try FileManager.default.removeItem(at: originalURL)

        let result = try await SourceImageDiscoveryService().discover(
            source,
            among: [unrelatedURL]
        )

        #expect(result == .notFound)
    }

    @Test("a pre-cancelled discovery exits before inspecting candidates")
    func honorsCancellation() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.write("source.raw", contents: "cancel")
        let source = try await SourceImageRevision.capture(at: sourceURL)

        let task = Task {
            await Task.yield()
            return try await SourceImageDiscoveryService().discover(source, among: [sourceURL])
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

private struct SourceDiscoveryFixture {
    let directoryURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-source-discovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
    }

    func write(_ filename: String, contents: String) throws -> URL {
        let url = directoryURL.appendingPathComponent(filename)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
