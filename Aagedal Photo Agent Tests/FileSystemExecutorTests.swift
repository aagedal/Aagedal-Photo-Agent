import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Filesystem Dispatch executor")
struct FileSystemExecutorTests {
    @Test("Browser duplicate skips orphan WAV and relationship collisions and persists independent shared memos")
    func duplicatePreservesVoiceMemoBundles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("photo.ARW")
        let jpeg = root.appendingPathComponent("photo.JPG")
        let memo = root.appendingPathComponent("photo.WAV")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        try Data("memo bytes".utf8).write(to: memo)
        let repository = VoiceMemoCompanionRepository()
        for source in [raw, jpeg] {
            try repository.save(VoiceMemoAssociation(
                profileIdentifier: "sony-ilce-1-v4", imageURL: source, memoURL: memo
            ))
        }
        let orphanMemo = root.appendingPathComponent("photo copy.WAV")
        let orphanRecord = repository.recordURL(for: root.appendingPathComponent("photo copy 2.ARW"))
        let unrelated = Data("unrelated".utf8)
        try unrelated.write(to: orphanMemo)
        try unrelated.write(to: orphanRecord)

        let result = await FileSystemService().duplicateImages(
            [raw, jpeg].map { .init(source: ImageFile(url: $0)) },
            in: root, metadataSidecarService: MetadataSidecarService()
        )

        #expect(result.failures.isEmpty)
        #expect(!result.cancellationStoppedRemainingItems)
        #expect(result.completed.map { $0.duplicate.filename } == ["photo copy 3.ARW", "photo copy 2.JPG"])
        var copiedMemos: Set<URL> = []
        for completion in result.completed {
            guard case .available(let association) = try repository.lookup(for: completion.duplicate.url) else {
                Issue.record("Duplicate lost its persisted voice memo")
                continue
            }
            #expect(try Data(contentsOf: association.memoURL) == Data(contentsOf: memo))
            #expect(association.memoURL != memo)
            copiedMemos.insert(association.memoURL)
        }
        #expect(copiedMemos.count == 2)
        #expect(try Data(contentsOf: orphanMemo) == unrelated)
        #expect(try Data(contentsOf: orphanRecord) == unrelated)
        #expect(FileManager.default.fileExists(atPath: raw.path))
        #expect(FileManager.default.fileExists(atPath: jpeg.path))
    }

    @Test("Browser duplicate fails closed for missing and unsupported relationships", arguments: [false, true])
    func duplicateRejectsUnavailableVoiceMemo(unsupported: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("photo.ARW")
        let memo = root.appendingPathComponent("photo.WAV")
        try Data("image".utf8).write(to: image)
        try Data("memo".utf8).write(to: memo)
        let repository = VoiceMemoCompanionRepository()
        try repository.save(VoiceMemoAssociation(profileIdentifier: "sony-ilce-1-v4", imageURL: image, memoURL: memo))
        if unsupported {
            try Data(#"{"schemaVersion":99}"#.utf8).write(to: repository.recordURL(for: image))
        } else {
            try FileManager.default.removeItem(at: memo)
        }
        let initialNames = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()

        let result = await FileSystemService().duplicateImages(
            [.init(source: ImageFile(url: image))], in: root,
            metadataSidecarService: MetadataSidecarService()
        )

        #expect(result.completed.isEmpty)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.sourceURL == image)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == initialNames)
    }

    @Test("An unassociated photo skips an orphan relationship and never guesses a same-stem WAV")
    func duplicateWithoutProvenMemo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("photo.JPG")
        try Data("image".utf8).write(to: image)
        try Data("unproven".utf8).write(to: root.appendingPathComponent("photo.WAV"))
        let repository = VoiceMemoCompanionRepository()
        let orphan = repository.recordURL(for: root.appendingPathComponent("photo copy.JPG"))
        try Data("unrelated".utf8).write(to: orphan)

        let result = await FileSystemService().duplicateImages(
            [.init(source: ImageFile(url: image))], in: root,
            metadataSidecarService: MetadataSidecarService()
        )

        #expect(result.failures.isEmpty)
        let duplicate = try #require(result.completed.first?.duplicate.url)
        #expect(duplicate.lastPathComponent == "photo copy 2.JPG")
        #expect(try repository.lookup(for: duplicate) == .none)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("photo copy 2.WAV").path))
        #expect(try Data(contentsOf: orphan) == Data("unrelated".utf8))
    }

    @Test("Browser scan runs on its Dispatch worker with the caller's task context")
    @MainActor
    func scanTaskContext() async throws {
        let root = URL(fileURLWithPath: "/virtual/filesystem-scan")
        let queue = DispatchSerialQueue(label: "test.filesystem.scan")
        let check: @Sendable () -> Void = {
            #expect(queue.isIsolatingCurrentContext() == true)
            #expect(!Thread.isMainThread)
            #expect(FileSystemExecutorContext.marker == root)
        }
        let service = FileSystemService(isLocallyAvailable: { url in
            check()
            #expect(url == root)
            return false
        }, requestDownload: { url in
            check()
            #expect(url == root)
        }, filesystemQueue: queue)
        let snapshot = try await FileSystemExecutorContext.$marker.withValue(root) {
            try await service.scanFolderWithStatus(at: root)
        }
        #expect(snapshot.files.isEmpty)
        #expect(snapshot.deferredICloudItemCount == 1)
    }

    @Test("Cancellation during synchronous reads remains visible on the Dispatch executor",
          arguments: [0, 1, 2, 3])
    @MainActor
    func cancellationDuringRead(kind: Int) async throws {
        let root = URL(fileURLWithPath: "/virtual/filesystem-read")
        let queue = DispatchSerialQueue(label: "test.filesystem.read.\(kind)")
        let cancelDuringRead: @Sendable () -> Void = {
            #expect(queue.isIsolatingCurrentContext() == true)
            #expect(!Thread.isMainThread)
            #expect(FileSystemExecutorContext.marker == root)
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let service = FileSystemService(supportedFilesContents: { _ in
            cancelDuringRead()
            return []
        }, classifyDropSource: { _ in
            cancelDuringRead()
            return .directory
        }, sidecarExists: { _ in
            cancelDuringRead()
            return true
        }, displayOrientation: { _ in
            cancelDuringRead()
            return 6
        }, filesystemQueue: queue)

        try await Task {
            try await FileSystemExecutorContext.$marker.withValue(root) {
                switch kind {
                case 0, 1:
                    do {
                        if kind == 0 { _ = try await service.supportedFilesSnapshot(at: root) }
                        else { _ = try await service.dropSourceSnapshot(for: [root]) }
                        Issue.record("A cancelled read must not return a complete snapshot")
                    } catch is CancellationError {
                        // Expected: the read ended after its caller was cancelled.
                    }
                case 2:
                    let result = await service.sidecarPresenceSnapshot(for: [root])
                    #expect(result.completion == .cancelled)
                    #expect(result.checkedCount == 1)
                    #expect(!result.hasAnySidecar)
                default:
                    let requestID = UUID()
                    let result = await service.displayOrientationSnapshot(for: [root], requestID: requestID)
                    #expect(result.requestID == requestID)
                    #expect(result.completion == .cancelled(processedFileCount: 1))
                    #expect(result.orientations == [root: 6])
                }
            }
        }.value
    }

    @Test("Cancellation before actor entry skips synchronous filesystem probes")
    func cancelledBeforeEntry() async throws {
        let service = FileSystemService(supportedFilesContents: { _ in
            Issue.record("Cancelled work entered the filesystem")
            return []
        })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.supportedFilesSnapshot(at: URL(fileURLWithPath: "/virtual/cancelled"))
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation before the read")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test("Cancellation inside a trash call preserves committed evidence and stops the next item")
    @MainActor
    func durableTrashCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.jpg")
        let second = root.appendingPathComponent("second.jpg")
        try Data().write(to: first)
        try Data().write(to: second)
        let queue = DispatchSerialQueue(label: "test.filesystem.trash")
        let service = FileSystemService(filesystemQueue: queue)
        let handler = ExecutorTestTrashHandler { url in
            #expect(queue.isIsolatingCurrentContext() == true)
            #expect(!Thread.isMainThread)
            #expect(FileSystemExecutorContext.marker == root)
            #expect(url == first)
            try FileManager.default.removeItem(at: url)
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let result = await Task {
            await FileSystemExecutorContext.$marker.withValue(root) {
                await service.trashItems([first, second], using: handler)
            }
        }.value
        #expect(result.completedSourceURLs == [first])
        #expect(result.failures.isEmpty)
        #expect(result.cancellationStoppedRemainingItems)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
}

private nonisolated enum FileSystemExecutorContext {
    @TaskLocal static var marker: URL?
}

private nonisolated struct ExecutorTestTrashHandler: ImageTrashHandling {
    let perform: @Sendable (URL) throws -> Void

    func trashItem(at url: URL) throws {
        try perform(url)
    }
}
