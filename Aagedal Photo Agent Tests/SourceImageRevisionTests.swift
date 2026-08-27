import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Source image revision")
struct SourceImageRevisionTests {
    @Test("capture streams an exact SHA-256 revision with source facts")
    func capturesExactRevision() async throws {
        let fixture = try TemporaryFixture(contents: Data("abc".utf8), extension: "jpg")
        defer { fixture.remove() }

        let revision = try await SourceImageRevision.capture(
            at: fixture.fileURL,
            pixelWidth: 42,
            pixelHeight: 24,
            exifOrientation: 6
        )

        #expect(revision.canonicalURL == fixture.fileURL.standardizedFileURL)
        #expect(revision.filenameAtCreation == fixture.fileURL.lastPathComponent)
        #expect(revision.byteCount == 3)
        #expect(revision.pixelWidth == 42)
        #expect(revision.pixelHeight == 24)
        #expect(revision.exifOrientation == 6)
        #expect(revision.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(revision.sha256.count == 64)
        #expect(revision.hashCompletedAt >= revision.contentModificationDate)
    }

    @Test("capture resolves symbolic links to the canonical source URL")
    func resolvesSymbolicLink() async throws {
        let fixture = try TemporaryFixture(contents: Data("source".utf8), extension: "raw")
        defer { fixture.remove() }
        let linkURL = fixture.directoryURL.appendingPathComponent("linked.raw")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: fixture.fileURL
        )

        let revision = try await SourceImageRevision.capture(at: linkURL)

        #expect(revision.canonicalURL == fixture.fileURL.standardizedFileURL)
        #expect(revision.filenameAtCreation == fixture.fileURL.lastPathComponent)
    }

    @Test("revision survives JSON round-trip without weakening identity")
    func codableRoundTrip() async throws {
        let fixture = try TemporaryFixture(contents: Data("round trip".utf8))
        defer { fixture.remove() }
        let original = try await SourceImageRevision.capture(at: fixture.fileURL)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SourceImageRevision.self, from: data)

        #expect(decoded == original)
        #expect(decoded.relationship(to: original) == .exactRevision)
    }

    @Test("content hash is authoritative across moves and copies")
    func exactRevisionAcrossDifferentFiles() async throws {
        let first = try TemporaryFixture(contents: Data("same bytes".utf8))
        let second = try TemporaryFixture(contents: Data("same bytes".utf8))
        defer {
            first.remove()
            second.remove()
        }

        let firstRevision = try await SourceImageRevision.capture(at: first.fileURL)
        let secondRevision = try await SourceImageRevision.capture(at: second.fileURL)

        #expect(firstRevision.canonicalURL != secondRevision.canonicalURL)
        #expect(firstRevision.relationship(to: secondRevision) == .exactRevision)
    }

    @Test("same path with different bytes is marked changed")
    func detectsChangedSourceAtSamePath() async throws {
        let fixture = try TemporaryFixture(contents: Data("before".utf8))
        defer { fixture.remove() }
        let before = try await SourceImageRevision.capture(at: fixture.fileURL)

        try Data("after, with a different size".utf8).write(to: fixture.fileURL)
        let after = try await SourceImageRevision.capture(at: fixture.fileURL)

        #expect(before.relationship(to: after) == .sameFileChanged)
        #expect(before.sha256 != after.sha256)
    }

    @Test("directory capture fails before hashing")
    func rejectsDirectories() async throws {
        let fixture = try TemporaryFixture(contents: Data())
        defer { fixture.remove() }

        await #expect(throws: SourceImageRevisionError.notARegularFile) {
            try await SourceImageRevision.capture(at: fixture.directoryURL)
        }
    }

    @Test("a pre-cancelled hash exits before file I/O")
    func hashHonorsPreCancellation() async throws {
        let fixture = try TemporaryFixture(contents: Data("cancel".utf8))
        defer { fixture.remove() }

        let task = Task {
            // Give the test a deterministic point at which to mark this task cancelled,
            // then call the hasher itself so its entry check is what throws.
            await Task.yield()
            return try await HashStream.hashFile(at: fixture.fileURL)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

@Suite("File system offline availability")
struct FileSystemOfflineAvailabilityTests {
    @Test("an offline iCloud item is deferred and its download is requested")
    func defersOfflineItem() async throws {
        let fixture = try OfflineFileFixture()
        defer { fixture.remove() }
        let onlineURL = try fixture.write("online.jpg", contents: "online")
        let offlineURL = try fixture.write("offline.jpg", contents: "offline")
        let requests = DownloadRequestProbe()
        let service = FileSystemService(
            isLocallyAvailable: {
                $0.standardizedFileURL != offlineURL.standardizedFileURL
            },
            requestDownload: { requests.record($0) }
        )

        let result = try await service.scanFolderWithStatus(at: fixture.directoryURL)

        #expect(result.deferredICloudItemCount == 1)
        #expect(result.files.count == 2)
        #expect(
            result.files.first(where: {
                $0.url.standardizedFileURL == onlineURL.standardizedFileURL
            })?.isICloudDownloadPending == false
        )
        #expect(
            result.files.first(where: {
                $0.url.standardizedFileURL == offlineURL.standardizedFileURL
            })?.isICloudDownloadPending == true
        )
        #expect(requests.urls.map(\.standardizedFileURL) == [offlineURL.standardizedFileURL])
    }

    @Test("an offline iCloud folder returns a deferred result without enumeration")
    func defersOfflineRoot() async throws {
        let fixture = try OfflineFileFixture()
        defer { fixture.remove() }
        _ = try fixture.write("unseen.jpg", contents: "unseen")
        let requests = DownloadRequestProbe()
        let service = FileSystemService(
            isLocallyAvailable: { _ in false },
            requestDownload: { requests.record($0) }
        )

        let result = try await service.scanFolderWithStatus(at: fixture.directoryURL)

        #expect(result.files.isEmpty)
        #expect(result.deferredICloudItemCount == 1)
        #expect(requests.urls == [fixture.directoryURL])
    }
}

@Suite("Serialized file system service")
struct SerializedFileSystemServiceTests {
    @Test("folder mutations return immutable committed results")
    func folderMutationResults() async throws {
        let fixture = try OfflineFileFixture()
        defer { fixture.remove() }
        let service = FileSystemService()
        let createdURL = fixture.directoryURL.appendingPathComponent("Zulu", isDirectory: true)
        let renamedURL = fixture.directoryURL.appendingPathComponent("Alpha", isDirectory: true)
        let destinationURL = fixture.directoryURL.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)

        let created = try await service.createFolder(at: createdURL)
        #expect(created.kind == .create)
        #expect(created.sourceURL == nil)
        #expect(created.resultingURL == createdURL)
        #expect(created.cancellationRequestedAfterCommit == false)

        let renamed = try await service.renameFolder(at: createdURL, to: renamedURL)
        #expect(renamed.kind == .rename)
        #expect(renamed.sourceURL == createdURL)
        #expect(renamed.resultingURL == renamedURL)

        let movedURL = destinationURL.appendingPathComponent("Alpha", isDirectory: true)
        let moved = try await service.moveFolder(from: renamedURL, to: movedURL)
        #expect(moved.kind == .move)
        #expect(moved.sourceURL == renamedURL)
        #expect(moved.resultingURL == movedURL)
        #expect(FileManager.default.fileExists(atPath: movedURL.path))
    }

    @Test("listing is sorted and excludes packages and ordinary files")
    func listsSubfolders() async throws {
        let fixture = try OfflineFileFixture()
        defer { fixture.remove() }
        let service = FileSystemService()
        for name in ["Zulu", "Alpha"] {
            try FileManager.default.createDirectory(
                at: fixture.directoryURL.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false
            )
        }
        try FileManager.default.createDirectory(
            at: fixture.directoryURL.appendingPathComponent("Ignored.app", isDirectory: true),
            withIntermediateDirectories: false
        )
        _ = try fixture.write("ordinary.txt", contents: "file")

        let listed = try await service.listSubfolders(at: fixture.directoryURL)

        #expect(listed.map(\.lastPathComponent) == ["Alpha", "Zulu"])
    }

    @Test("pre-cancelled mutation makes no filesystem change")
    func mutationHonorsPreCancellation() async throws {
        let fixture = try OfflineFileFixture()
        defer { fixture.remove() }
        let service = FileSystemService()
        let newURL = fixture.directoryURL.appendingPathComponent("Cancelled", isDirectory: true)
        let task = Task {
            await Task.yield()
            return try await service.createFolder(at: newURL)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: newURL.path))
    }

    @Test("destination collision reports no partial mutation")
    func collisionHasNoPartialMutation() async throws {
        let fixture = try OfflineFileFixture()
        defer { fixture.remove() }
        let service = FileSystemService()
        let sourceURL = fixture.directoryURL.appendingPathComponent("Source", isDirectory: true)
        let destinationURL = fixture.directoryURL.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)

        await #expect(throws: FileSystemService.Error.destinationAlreadyExists(destinationURL)) {
            _ = try await service.moveFolder(from: sourceURL, to: destinationURL)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    }
}

private struct TemporaryFixture {
    let directoryURL: URL
    let fileURL: URL

    init(contents: Data, extension fileExtension: String = "bin") throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-source-revision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        let fileURL = directoryURL.appendingPathComponent("fixture.\(fileExtension)")
        try contents.write(to: fileURL)
        self.directoryURL = directoryURL
        self.fileURL = fileURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

nonisolated private final class DownloadRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    var urls: [URL] {
        lock.withLock { recordedURLs }
    }

    func record(_ url: URL) {
        lock.withLock {
            recordedURLs.append(url)
        }
    }
}

private struct OfflineFileFixture {
    let directoryURL: URL

    init() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-offline-files-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: false
        )
        directoryURL = temporaryDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
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
