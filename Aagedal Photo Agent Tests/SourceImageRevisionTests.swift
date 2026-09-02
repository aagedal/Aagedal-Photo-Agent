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

    @Test("revision stat and hash primitives leave the main actor")
    @MainActor
    func capturePrimitivesRunOffMainActor() async throws {
        let probe = SourceRevisionCaptureProbe()
        let source = URL(fileURLWithPath: "/virtual/source.jpg")
        let service = SourceImageRevisionCaptureService(io: probe.io)

        let revision = try await service.capture(
            at: source,
            pixelWidth: 40,
            pixelHeight: 30,
            exifOrientation: 6
        )

        #expect(revision.canonicalURL == source.standardizedFileURL)
        #expect(revision.byteCount == 12)
        #expect(revision.pixelWidth == 40)
        #expect(revision.pixelHeight == 30)
        #expect(revision.exifOrientation == 6)
        #expect(revision.sha256 == String(repeating: "ab", count: 32))
        #expect(probe.snapshotURLs == [source.standardizedFileURL, source.standardizedFileURL])
        #expect(probe.hashURLs == [source.standardizedFileURL])
        #expect(!probe.ranOnMainThread)
    }

    @Test("capture cancellation after a non-preemptible stat stops before hashing")
    func captureCancellationAfterStat() async throws {
        let probe = SourceRevisionCaptureProbe(blockFirstSnapshot: true)
        let service = SourceImageRevisionCaptureService(io: probe.io)
        let task = Task {
            try await service.capture(at: URL(fileURLWithPath: "/virtual/cancelled.jpg"))
        }
        #expect(await probe.waitUntilFirstSnapshotStarts())
        task.cancel()
        probe.releaseFirstSnapshot()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(probe.snapshotURLs.count == 1)
        #expect(probe.hashURLs.isEmpty)
    }

    @Test("overlapping revision captures remain one serialized transaction")
    func capturesAreSerialized() async throws {
        let probe = SourceRevisionCaptureProbe(blockFirstSnapshot: true)
        let service = SourceImageRevisionCaptureService(io: probe.io)
        let firstURL = URL(fileURLWithPath: "/virtual/first.jpg").standardizedFileURL
        let secondURL = URL(fileURLWithPath: "/virtual/second.jpg").standardizedFileURL
        let first = Task { try await service.capture(at: firstURL) }
        #expect(await probe.waitUntilFirstSnapshotStarts())
        let second = Task { try await service.capture(at: secondURL) }
        await Task.yield()
        probe.releaseFirstSnapshot()

        _ = try await first.value
        _ = try await second.value

        #expect(probe.snapshotURLs == [firstURL, firstURL, secondURL, secondURL])
        #expect(probe.hashURLs == [firstURL, secondURL])
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

    @Test("sidecar presence snapshot stops at the first match and freezes counts")
    func sidecarPresenceSnapshot() async {
        let first = URL(fileURLWithPath: "/virtual/first.xmp")
        let second = URL(fileURLWithPath: "/virtual/second.xmp")
        let third = URL(fileURLWithPath: "/virtual/third.xmp")
        let probe = SidecarPresenceProbe(existingURLs: [second])
        let service = FileSystemService(sidecarExists: probe.exists)

        let snapshot = await service.sidecarPresenceSnapshot(for: [first, second, third])

        #expect(snapshot.completion == .complete)
        #expect(snapshot.hasAnySidecar)
        #expect(snapshot.checkedCount == 2)
        #expect(snapshot.requestedCount == 3)
        #expect(probe.urls == [first, second])
    }

    @Test("sidecar probes cross off the main actor")
    @MainActor
    func sidecarPresenceSnapshotRunsOffMain() async {
        let url = URL(fileURLWithPath: "/virtual/photo.xmp")
        let probe = SidecarPresenceProbe(existingURLs: [url])
        let service = FileSystemService(sidecarExists: probe.exists)

        let snapshot = await service.sidecarPresenceSnapshot(for: [url])

        #expect(snapshot.completion == .complete)
        #expect(snapshot.hasAnySidecar)
        #expect(!probe.ranOnMainThread)
    }

    @Test("sidecar presence reports cancellation arriving during a blocking probe")
    func sidecarPresenceSnapshotReportsPostProbeCancellation() async {
        let probe = BlockingSidecarPresenceProbe()
        defer { probe.release() }
        let service = FileSystemService(sidecarExists: probe.exists)
        let task = Task {
            await service.sidecarPresenceSnapshot(
                for: [URL(fileURLWithPath: "/simulated-slow-volume/photo.xmp")]
            )
        }

        let didBlock = await probe.waitUntilBlocked()
        #expect(didBlock, "The simulated slow-volume probe did not start within 30 seconds")
        guard didBlock else { return }
        task.cancel()
        probe.release()

        let snapshot = await task.value
        #expect(snapshot.completion == .cancelled)
        #expect(!snapshot.hasAnySidecar)
        #expect(snapshot.checkedCount == 1)
        #expect(snapshot.requestedCount == 1)
    }

    @Test("Remove All IPTC preflight uses serialized sidecar evidence and rejects stale results")
    func removeIPTCPreflightSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/BrowserViewModel.swift"
            ),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "func confirmRemoveAllIPTC()"))
        let suffix = source[start.lowerBound...]
        let end = try #require(suffix.range(of: "func removeIPTCFromImageFiles"))
        let implementation = suffix[..<end.lowerBound]

        #expect(implementation.contains("sidecarPresenceSnapshot(for: sidecarURLs)"))
        #expect(implementation.contains("removeIPTCPreflightRequestID == requestID"))
        #expect(implementation.contains("selectedImageIDs == Set(urls)"))
        #expect(implementation.contains("snapshot.completion == .complete"))
        #expect(!implementation.contains("FileManager.default.fileExists"))
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

@Suite("Slow volume responsiveness gate", .serialized)
struct SlowVolumeResponsivenessGateTests {
    @Test("filesystem read signposts keep stable privacy-safe measurement labels")
    func fileSystemReadSignpostSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/FileSystemService.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("category: \"FileSystemRead\""))
        #expect(source.contains("beginInterval(\"FolderScan\""))
        #expect(source.contains("\"SupportedFilesSnapshot\","))
        #expect(source.contains("\"DropSourceClassification\","))
        #expect(source.contains(
            #"itemCount=\(files.count, privacy: .private) deferredCount=\(deferredICloudItemCount, privacy: .private)"#
        ))
        #expect(source.contains(#"itemCount=\(result.count, privacy: .private)"#))
        #expect(source.contains(#"itemCount=\(urls.count, privacy: .private)"#))
        #expect(!source.contains(#"path=\("#))
        #expect(!source.contains(#"filename=\("#))
    }

    @Test("blocked drop source probe keeps the main actor responsive and cancellation queued")
    @MainActor
    func blockedDropSourceProbeDoesNotBlockMainActor() async throws {
        let probe = BlockingDropSourceProbe()
        defer { probe.release() }
        let firstURL = URL(fileURLWithPath: "/simulated-slow-volume/first.jpg")
        let queuedURL = URL(fileURLWithPath: "/simulated-slow-volume/queued.jpg")
        let service = FileSystemService(classifyDropSource: probe.classify)
        let first = Task {
            try await service.dropSourceSnapshot(for: [firstURL])
        }

        let didBlock = await probe.waitUntilBlocked()
        #expect(didBlock, "The simulated slow-volume probe did not start within 30 seconds")
        guard didBlock else { return }

        // Reaching these assertions while the synchronous probe is still blocked proves that an
        // indefinitely slow volume cannot occupy the UI executor. A second request is queued on
        // the serialized actor and cancelled before it is allowed to touch the volume.
        #expect(probe.callCount == 1)
        #expect(!probe.ranOnMainThread)
        let queued = Task {
            try await service.dropSourceSnapshot(for: [queuedURL])
        }
        queued.cancel()
        probe.release()

        let snapshot = try await first.value
        #expect(snapshot.regularFiles == [firstURL])
        await #expect(throws: CancellationError.self) {
            _ = try await queued.value
        }
        #expect(probe.callCount == 1)
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

nonisolated private final class SourceRevisionCaptureProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let blockFirstSnapshot: Bool
    private var recordedSnapshotURLs: [URL] = []
    private var recordedHashURLs: [URL] = []
    private var observedMainThread = false
    private var firstSnapshotStarted = false
    private var firstSnapshotReleased = false

    init(blockFirstSnapshot: Bool = false) {
        self.blockFirstSnapshot = blockFirstSnapshot
    }

    var io: SourceImageRevisionCaptureIO {
        SourceImageRevisionCaptureIO(
            canonicalURL: { [self] url in
                recordThread()
                return url.standardizedFileURL
            },
            snapshot: snapshot,
            hash: hash,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )
    }

    var snapshotURLs: [URL] {
        condition.withLock { recordedSnapshotURLs }
    }

    var hashURLs: [URL] {
        condition.withLock { recordedHashURLs }
    }

    var ranOnMainThread: Bool {
        condition.withLock { observedMainThread }
    }

    func snapshot(_ url: URL) -> SourceImageRevisionFileSnapshot {
        condition.lock()
        recordedSnapshotURLs.append(url)
        observedMainThread = observedMainThread || Thread.isMainThread
        if blockFirstSnapshot && recordedSnapshotURLs.count == 1 {
            firstSnapshotStarted = true
            condition.broadcast()
            while !firstSnapshotReleased {
                condition.wait()
            }
        }
        condition.unlock()
        return SourceImageRevisionFileSnapshot(
            isRegularFile: true,
            byteCount: 12,
            contentModificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            fileResourceIdentifier: nil
        )
    }

    func hash(_ url: URL) -> Data {
        condition.withLock {
            recordedHashURLs.append(url)
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return Data(repeating: 0xab, count: 32)
    }

    func waitUntilFirstSnapshotStarts() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition.withLock({ firstSnapshotStarted }) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func releaseFirstSnapshot() {
        condition.withLock {
            firstSnapshotReleased = true
            condition.broadcast()
        }
    }

    private func recordThread() {
        condition.withLock {
            observedMainThread = observedMainThread || Thread.isMainThread
        }
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

nonisolated private final class SidecarPresenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let existingURLs: Set<URL>
    private var recordedURLs: [URL] = []
    private var observedMainThread = false

    init(existingURLs: Set<URL>) {
        self.existingURLs = existingURLs
    }

    var urls: [URL] {
        lock.withLock { recordedURLs }
    }

    var ranOnMainThread: Bool {
        lock.withLock { observedMainThread }
    }

    func exists(_ url: URL) -> Bool {
        lock.withLock {
            recordedURLs.append(url)
            observedMainThread = observedMainThread || Thread.isMainThread
            return existingURLs.contains(url)
        }
    }
}

nonisolated private final class BlockingSidecarPresenceProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var isBlocked = false
    private var isReleased = false

    func exists(_ url: URL) -> Bool {
        condition.lock()
        isBlocked = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
        return true
    }

    func waitUntilBlocked(timeout: TimeInterval = 30) async -> Bool {
        await Task.detached { [self] in
            waitUntilBlockedSynchronously(timeout: timeout)
        }.value
    }

    private func waitUntilBlockedSynchronously(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !isBlocked {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release() {
        condition.withLock {
            isReleased = true
            condition.broadcast()
        }
    }
}

/// Deterministic stand-in for a filesystem call stalled by a network, external, or cloud volume.
/// The test controls the release explicitly instead of depending on machine timing or `sleep`.
nonisolated private final class BlockingDropSourceProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var isBlocked = false
    private var isReleased = false
    private var observedMainThread = false
    private var recordedCallCount = 0

    var ranOnMainThread: Bool {
        condition.withLock { observedMainThread }
    }

    var callCount: Int {
        condition.withLock { recordedCallCount }
    }

    func classify(_ url: URL) -> FileSystemService.DropSourceKind {
        condition.lock()
        observedMainThread = observedMainThread || Thread.isMainThread
        recordedCallCount += 1
        isBlocked = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
        return .regularFile
    }

    func waitUntilBlocked(timeout: TimeInterval = 30) async -> Bool {
        await Task.detached { [self] in
            waitUntilBlockedSynchronously(timeout: timeout)
        }.value
    }

    private func waitUntilBlockedSynchronously(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !isBlocked {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release() {
        condition.withLock {
            isReleased = true
            condition.broadcast()
        }
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
