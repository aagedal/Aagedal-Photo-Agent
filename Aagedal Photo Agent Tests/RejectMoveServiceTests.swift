import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("RejectMoveService")
struct RejectMoveServiceTests {
    @Test("Name collisions keep image and sidecars associated")
    func collisionRenamesWholeBundle() async throws {
        let root = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceImage = root.appendingPathComponent("photo.cr3")
        let sourceXMP = root.appendingPathComponent("photo.xmp")
        try Data("new image".utf8).write(to: sourceImage)
        try Data("new xmp".utf8).write(to: sourceXMP)

        let sidecarService = MetadataSidecarService()
        let sidecar = MetadataSidecar(
            sourceFile: sourceImage.lastPathComponent,
            pendingChanges: true,
            metadata: IPTCMetadata(title: "Incoming title")
        )
        try sidecarService.saveSidecar(sidecar, for: sourceImage, in: root)

        let rejected = root.appendingPathComponent(RejectMoveService.rejectedFolderName)
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        try Data("existing image".utf8).write(to: rejected.appendingPathComponent("photo.cr3"))
        try Data("existing xmp".utf8).write(to: rejected.appendingPathComponent("photo.xmp"))

        let result = await FileSystemService().moveRejectedItems([sourceImage], in: root)

        let movedImage = rejected.appendingPathComponent("photo-1.cr3")
        let movedXMP = rejected.appendingPathComponent("photo-1.xmp")
        let movedJSON = rejected
            .appendingPathComponent(MetadataSidecarService.sidecarDirectoryName)
            .appendingPathComponent("photo-1.cr3.meta.json")
        #expect(result.failedFiles.isEmpty)
        #expect(result.movedFiles == [movedImage])
        #expect(!result.cancellationStoppedRemainingItems)
        #expect(FileManager.default.fileExists(atPath: movedImage.path))
        #expect(try Data(contentsOf: movedXMP) == Data("new xmp".utf8))
        #expect(FileManager.default.fileExists(atPath: movedJSON.path))

        let loaded = try #require(sidecarService.loadSidecar(for: movedImage, in: rejected))
        #expect(loaded.sourceFile == "photo-1.cr3")
        #expect(loaded.metadata.title == "Incoming title")
        #expect(try Data(contentsOf: rejected.appendingPathComponent("photo.cr3")) == Data("existing image".utf8))
        #expect(try Data(contentsOf: rejected.appendingPathComponent("photo.xmp")) == Data("existing xmp".utf8))
    }

    @Test("Sidecar failure rolls image and XMP back")
    func sidecarFailureRollsBackBundle() async throws {
        let root = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceImage = root.appendingPathComponent("photo.cr3")
        let sourceXMP = root.appendingPathComponent("photo.xmp")
        try Data("image".utf8).write(to: sourceImage)
        try Data("xmp".utf8).write(to: sourceXMP)
        try MetadataSidecarService().saveSidecar(
            MetadataSidecar(sourceFile: "photo.cr3"),
            for: sourceImage,
            in: root
        )

        // A regular file at the metadata-directory path forces relocation to fail
        // after the image and XMP have moved, exercising transactional rollback.
        let rejected = root.appendingPathComponent(RejectMoveService.rejectedFolderName)
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        try Data("blocking file".utf8).write(
            to: rejected.appendingPathComponent(MetadataSidecarService.sidecarDirectoryName)
        )

        let result = await FileSystemService().moveRejectedItems([sourceImage], in: root)

        #expect(result.movedFiles.isEmpty)
        #expect(result.failedFiles.count == 1)
        #expect(!result.cancellationStoppedRemainingItems)
        #expect(FileManager.default.fileExists(atPath: sourceImage.path))
        #expect(FileManager.default.fileExists(atPath: sourceXMP.path))
        #expect(!FileManager.default.fileExists(atPath: rejected.appendingPathComponent("photo.cr3").path))
        #expect(!FileManager.default.fileExists(atPath: rejected.appendingPathComponent("photo.xmp").path))
    }

    @Test("Pre-cancelled actor operation leaves the source and destination untouched")
    func preCancelledMoveMakesNoFilesystemChange() async throws {
        let root = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceImage = root.appendingPathComponent("photo.cr3")
        try Data("image".utf8).write(to: sourceImage)
        let service = FileSystemService()
        let task = Task {
            await Task.yield()
            return await service.moveRejectedItems([sourceImage], in: root)
        }
        task.cancel()

        let result = await task.value
        let rejected = root.appendingPathComponent(RejectMoveService.rejectedFolderName)
        #expect(result.movedFiles.isEmpty)
        #expect(result.failedFiles.isEmpty)
        #expect(result.cancellationStoppedRemainingItems)
        #expect(FileManager.default.fileExists(atPath: sourceImage.path))
        #expect(!FileManager.default.fileExists(atPath: rejected.path))
    }

    @Test("Cancellation after one committed bundle preserves it and stops the next bundle")
    func cancellationBetweenBundlesPreservesPartialCommit() async throws {
        let root = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstImage = root.appendingPathComponent("first.cr3")
        let secondImage = root.appendingPathComponent("second.cr3")
        try Data("first".utf8).write(to: firstImage)
        try Data("second".utf8).write(to: secondImage)

        let gate = BundleCommitGate()
        defer { gate.release() }
        let service = FileSystemService(rejectMove: { urls, folderURL in
            RejectMoveService.moveRejected(
                urls: urls,
                in: folderURL,
                bundleDidCommit: gate.didCommit
            )
        })
        let task = Task {
            await service.moveRejectedItems([firstImage, secondImage], in: root)
        }

        try await gate.waitUntilFirstCommit()
        task.cancel()
        gate.release()
        let result = await task.value

        let rejected = root.appendingPathComponent(RejectMoveService.rejectedFolderName)
        let movedFirst = rejected.appendingPathComponent(firstImage.lastPathComponent)
        let unmovedSecond = rejected.appendingPathComponent(secondImage.lastPathComponent)
        #expect(result.movedFiles == [movedFirst])
        #expect(result.failedFiles.isEmpty)
        #expect(result.cancellationStoppedRemainingItems)
        #expect(FileManager.default.fileExists(atPath: rejected.path))
        #expect(FileManager.default.fileExists(atPath: movedFirst.path))
        #expect(!FileManager.default.fileExists(atPath: firstImage.path))
        #expect(FileManager.default.fileExists(atPath: secondImage.path))
        #expect(!FileManager.default.fileExists(atPath: unmovedSecond.path))
    }

    @Test("Completion from a previous folder cannot navigate the browser back")
    @MainActor
    func staleCompletionDoesNotReloadPreviousFolder() async throws {
        let root = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let nextFolder = root.appendingPathComponent("Next", isDirectory: true)
        try FileManager.default.createDirectory(at: nextFolder, withIntermediateDirectories: false)
        let sourceImage = root.appendingPathComponent("photo.cr3")
        try Data("image".utf8).write(to: sourceImage)

        let probe = BlockingRejectMoveProbe()
        defer { probe.release() }
        let fileSystemService = FileSystemService(rejectMove: probe.move)
        let viewModel = BrowserViewModel(fileSystemService: fileSystemService)
        var rejectedImage = ImageFile(url: sourceImage)
        rejectedImage.colorLabel = .trash
        viewModel.currentFolderURL = root
        viewModel.currentFolderName = root.lastPathComponent
        viewModel.images = [rejectedImage]
        await Task.yield()
        let visibleImage = try #require(viewModel.visibleImages.first)
        #expect(visibleImage.url == sourceImage)

        viewModel.moveRejectedToFolder()
        try await probe.waitUntilStarted()
        viewModel.currentFolderURL = nextFolder
        viewModel.currentFolderName = nextFolder.lastPathComponent
        probe.release()
        await viewModel.waitForPendingImageMutation()

        #expect(viewModel.currentFolderURL == nextFolder)
        #expect(viewModel.currentFolderName == nextFolder.lastPathComponent)
    }

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reject-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum RejectMoveProbeError: Error {
    case timedOut
}

private nonisolated final class BundleCommitGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var committedCount = 0
    private var released = false

    func didCommit(_ destinationURL: URL) {
        _ = destinationURL
        condition.lock()
        committedCount += 1
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilFirstCommit() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !hasCommittedBundle {
            guard ContinuousClock.now < deadline else { throw RejectMoveProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    private var hasCommittedBundle: Bool {
        condition.lock()
        defer { condition.unlock() }
        return committedCount > 0
    }
}

private nonisolated final class BlockingRejectMoveProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    func move(_ urls: [URL], _ folderURL: URL) -> RejectMoveService.MoveResult {
        condition.lock()
        started = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()

        let rejectedFolder = folderURL.appendingPathComponent(RejectMoveService.rejectedFolderName)
        return RejectMoveService.MoveResult(
            rejectedFolder: rejectedFolder,
            movedFiles: urls.map { rejectedFolder.appendingPathComponent($0.lastPathComponent) },
            failedFiles: [],
            cancellationStoppedRemainingItems: false
        )
    }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !hasStarted {
            guard ContinuousClock.now < deadline else { throw RejectMoveProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    private var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }
}
