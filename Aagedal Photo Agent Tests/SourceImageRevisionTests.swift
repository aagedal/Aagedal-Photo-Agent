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

    @Test("supported URL snapshot is filtered, non-recursive, and name-sorted")
    func supportedFilesSnapshot() async throws {
        let fixture = try OfflineFileFixture()
        defer { fixture.remove() }
        let nestedFolder = fixture.directoryURL.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: false)
        _ = try fixture.write("zulu.jpeg", contents: "image")
        _ = try fixture.write("Alpha.RAF", contents: "raw")
        _ = try fixture.write("notes.txt", contents: "ordinary")
        _ = try fixture.write(".hidden.jpg", contents: "hidden")
        try Data("nested".utf8).write(to: nestedFolder.appendingPathComponent("nested.jpg"))
        try FileManager.default.createDirectory(
            at: fixture.directoryURL.appendingPathComponent("not-a-file.jpg", isDirectory: true),
            withIntermediateDirectories: false
        )

        let snapshot = try await FileSystemService().supportedFilesSnapshot(at: fixture.directoryURL)

        #expect(snapshot.map(\.lastPathComponent) == ["Alpha.RAF", "zulu.jpeg"])
    }

    @Test("supported URL snapshot honors pre-cancellation")
    func supportedFilesSnapshotHonorsPreCancellation() async throws {
        let fixture = try OfflineFileFixture()
        defer { fixture.remove() }
        _ = try fixture.write("photo.jpg", contents: "image")
        let service = FileSystemService()
        let task = Task {
            await Task.yield()
            return try await service.supportedFilesSnapshot(at: fixture.directoryURL)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("supported URL enumeration crosses off the main actor")
    @MainActor
    func supportedFilesSnapshotRunsOffMain() async throws {
        let fixture = try OfflineFileFixture()
        defer { fixture.remove() }
        _ = try fixture.write("photo.jpg", contents: "image")
        let probe = DirectoryEnumerationThreadProbe()
        let service = FileSystemService(supportedFilesContents: probe.contents)

        let snapshot = try await service.supportedFilesSnapshot(at: fixture.directoryURL)

        #expect(snapshot.map(\.lastPathComponent) == ["photo.jpg"])
        #expect(!probe.ranOnMainThread)
    }

    @Test("drop source snapshot freezes directories, files, and missing URLs in input order")
    func dropSourceSnapshot() async throws {
        let directory = URL(fileURLWithPath: "/virtual/folder", isDirectory: true)
        let file = URL(fileURLWithPath: "/virtual/photo.jpg")
        let missing = URL(fileURLWithPath: "/virtual/missing.jpg")
        let kinds: [URL: FileSystemService.DropSourceKind] = [
            directory: .directory,
            file: .regularFile,
            missing: .missing,
        ]
        let service = FileSystemService(classifyDropSource: { kinds[$0] ?? .missing })

        let snapshot = try await service.dropSourceSnapshot(for: [file, missing, directory])

        #expect(snapshot.directories == [directory])
        #expect(snapshot.regularFiles == [file])
        #expect(snapshot.missingURLs == [missing])
    }

    @Test("drop source probes cross off the main actor")
    @MainActor
    func dropSourceSnapshotRunsOffMain() async throws {
        let url = URL(fileURLWithPath: "/virtual/photo.jpg")
        let probe = DropSourceThreadProbe()
        let service = FileSystemService(classifyDropSource: probe.classify)

        let snapshot = try await service.dropSourceSnapshot(for: [url])

        #expect(snapshot.regularFiles == [url])
        #expect(!probe.ranOnMainThread)
    }

    @Test("pre-cancelled drop source snapshot performs no probes")
    func dropSourceSnapshotHonorsPreCancellation() async throws {
        let probe = DropSourceThreadProbe()
        let service = FileSystemService(classifyDropSource: probe.classify)
        let task = Task {
            await Task.yield()
            return try await service.dropSourceSnapshot(for: [URL(fileURLWithPath: "/virtual/photo.jpg")])
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(probe.callCount == 0)
    }

    @Test("content-area folder drops use the serialized classification boundary")
    func contentAreaDropSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent("Aagedal Photo Agent/ContentView.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private func handleDrop(providers:"))
        let suffix = source[start.lowerBound...]
        let end = try #require(suffix.range(of: "private func openSelectedInExternalEditor"))
        let implementation = suffix[..<end.lowerBound]

        #expect(implementation.contains("Task { @MainActor in"))
        #expect(implementation.contains("dropSourceSnapshot(for: [url])"))
        #expect(implementation.contains("snapshot.directories.first == url"))
        #expect(!implementation.contains("FileManager.default.fileExists"))
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

    @Test("batch trash reports partial success without losing failures")
    func batchTrashPartialSuccess() async throws {
        let first = URL(fileURLWithPath: "/virtual/first.jpg")
        let second = URL(fileURLWithPath: "/virtual/second.jpg")
        let service = FileSystemService()

        let result = await service.trashItems(
            [first, second],
            using: SelectiveTrashHandler(failingURLs: [second])
        )

        #expect(result.completedSourceURLs == [first])
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.sourceURL == second)
        #expect(result.failures.first?.stage == .primary)
        #expect(result.cancellationStoppedRemainingItems == false)
    }

    @Test("pre-cancelled batch trash explicitly stops all remaining items")
    func batchTrashPreCancellation() async throws {
        let url = URL(fileURLWithPath: "/virtual/cancelled.jpg")
        let service = FileSystemService()
        let task = Task {
            await Task.yield()
            return await service.trashItems([url], using: SelectiveTrashHandler())
        }
        task.cancel()

        let result = await task.value
        #expect(result.completedSourceURLs.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(result.cancellationStoppedRemainingItems)
    }

    @Test("image move keeps XMP and editorial sidecars with committed primary")
    func imageMovePreservesSidecars() async throws {
        let fixture = try OfflineFileFixture()
        defer { fixture.remove() }
        let destinationFolder = fixture.directoryURL.appendingPathComponent("Destination", isDirectory: true)
        let imageURL = try fixture.write("photo.jpg", contents: "image")
        let xmpURL = imageURL.deletingPathExtension().appendingPathExtension("xmp")
        try Data("xmp".utf8).write(to: xmpURL)
        let metadataService = MetadataSidecarService()
        try metadataService.saveSidecar(
            MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                metadata: IPTCMetadata(title: "Preserved")
            ),
            for: imageURL,
            in: fixture.directoryURL
        )

        let result = try await FileSystemService().moveImageItems(
            [imageURL],
            into: destinationFolder,
            createDestinationIfNeeded: true,
            xmpSidecarService: XMPSidecarService(),
            metadataSidecarService: metadataService
        )

        let movedImageURL = destinationFolder.appendingPathComponent("photo.jpg")
        #expect(result.movedSourceURLs == [imageURL])
        #expect(result.failures.isEmpty)
        #expect(result.destinationWasCreated)
        #expect(FileManager.default.fileExists(atPath: movedImageURL.path))
        #expect(FileManager.default.fileExists(
            atPath: movedImageURL.deletingPathExtension().appendingPathExtension("xmp").path
        ))
        #expect(metadataService.loadSidecar(for: movedImageURL, in: destinationFolder)?.metadata.title == "Preserved")
    }

    @Test("duplicate selects a unique name and copies editorial sidecar")
    func duplicatePreservesEditorialSidecar() async throws {
        let fixture = try OfflineFileFixture()
        defer { fixture.remove() }
        let imageURL = try fixture.write("photo.jpg", contents: "image")
        _ = try fixture.write("photo copy.jpg", contents: "existing")
        let metadataService = MetadataSidecarService()
        try metadataService.saveSidecar(
            MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                metadata: IPTCMetadata(title: "Copied")
            ),
            for: imageURL,
            in: fixture.directoryURL
        )

        let result = await FileSystemService().duplicateImages(
            [.init(source: ImageFile(url: imageURL))],
            in: fixture.directoryURL,
            metadataSidecarService: metadataService
        )

        let duplicateURL = fixture.directoryURL.appendingPathComponent("photo copy 2.jpg")
        #expect(result.completed.count == 1)
        #expect(result.completed.first?.sourceURL == imageURL)
        #expect(result.completed.first?.duplicate.url == duplicateURL)
        #expect(result.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: duplicateURL.path))
        #expect(metadataService.loadSidecar(for: duplicateURL, in: fixture.directoryURL)?.metadata.title == "Copied")
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

nonisolated private final class DirectoryEnumerationThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observedMainThread = false

    var ranOnMainThread: Bool {
        lock.withLock { observedMainThread }
    }

    func contents(at url: URL) throws -> [URL] {
        lock.withLock {
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
    }
}

nonisolated private final class DropSourceThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observedMainThread = false
    private var recordedCallCount = 0

    var ranOnMainThread: Bool {
        lock.withLock { observedMainThread }
    }

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    func classify(_ url: URL) -> FileSystemService.DropSourceKind {
        lock.withLock {
            observedMainThread = observedMainThread || Thread.isMainThread
            recordedCallCount += 1
        }
        return .regularFile
    }
}

nonisolated private struct SelectiveTrashHandler: ImageTrashHandling {
    var failingURLs: Set<URL> = []

    func trashItem(at url: URL) throws {
        if failingURLs.contains(url) {
            throw CocoaError(.fileWriteUnknown)
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
