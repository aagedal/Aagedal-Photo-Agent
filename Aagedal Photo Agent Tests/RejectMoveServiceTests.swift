import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("RejectMoveService")
struct RejectMoveServiceTests {
    @Test("Source writes at retirement are restored instead of discarded for stale staged bytes", arguments: ["ARW", "WAV"])
    func rejectRetirementRacePreservesChangedBytes(changedExtension: String) async throws {
        let fixture = try makeVoiceMemoFixture(shared: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let changedBytes = Data("external bytes changed just before retirement".utf8)
        var io = VoiceMemoCompanionCopyIO.system
        io.install = { source, destination in
            if source.pathExtension == changedExtension,
               destination.lastPathComponent.hasPrefix(".voice-memo-move-backup-") {
                try changedBytes.write(to: source)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        let repository = VoiceMemoCompanionRepository(copyIO: io)
        let service = FileSystemService(rejectMove: { urls, folder in
            RejectMoveService.moveRejected(urls: urls, in: folder, voiceMemoRepository: repository)
        })

        let result = await service.moveRejectedItems([fixture.image], in: fixture.root)

        #expect(result.movedFiles.isEmpty)
        #expect(result.failedFiles.count == 1)
        #expect(try Data(contentsOf: fixture.image) == (changedExtension == "ARW" ? changedBytes : Data("raw".utf8)))
        #expect(try Data(contentsOf: fixture.memo) == (changedExtension == "WAV" ? changedBytes : Data("memo bytes".utf8)))
        #expect(FileManager.default.fileExists(atPath: repository.recordURL(for: fixture.image).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.rejectedFolder.path).isEmpty)
    }

    @Test("Reject installs only staged destination copies and retires sources with local renames")
    func rejectKeepsEveryMoveOnOneVolume() async throws {
        let fixture = try makeVoiceMemoFixture(shared: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var io = VoiceMemoCompanionCopyIO.system
        io.install = { source, destination in
            let sourceFolder = source.deletingLastPathComponent()
            let destinationFolder = destination.deletingLastPathComponent()
            let fromDestinationStaging = sourceFolder.lastPathComponent.hasPrefix(".voice-memo-move-")
                && sourceFolder.deletingLastPathComponent() == destinationFolder
            #expect(sourceFolder == destinationFolder || fromDestinationStaging,
                    "Never send a source-to-destination cross-volume move to Foundation")
            try FileManager.default.moveItem(at: source, to: destination)
        }
        let repository = VoiceMemoCompanionRepository(copyIO: io)
        let service = FileSystemService(rejectMove: { urls, folder in
            RejectMoveService.moveRejected(urls: urls, in: folder, voiceMemoRepository: repository)
        })

        let result = await service.moveRejectedItems([fixture.image], in: fixture.root)

        #expect(result.movedFiles.count == 1)
        #expect(result.failedFiles.isEmpty)
    }

    @Test("A staging copy that writes then throws leaves source ownership unchanged", arguments: ["ARW", "WAV"])
    func rejectPartialStagingCopyLeavesSources(failingExtension: String) async throws {
        let fixture = try makeVoiceMemoFixture(shared: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var io = VoiceMemoCompanionCopyIO.system
        io.copy = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
            if source.pathExtension == failingExtension { throw CocoaError(.fileWriteUnknown) }
        }
        io.install = { _, _ in Issue.record("Failed preparation must not retire or install anything") }
        let repository = VoiceMemoCompanionRepository(copyIO: io)
        let service = FileSystemService(rejectMove: { urls, folder in
            RejectMoveService.moveRejected(urls: urls, in: folder, voiceMemoRepository: repository)
        })

        let result = await service.moveRejectedItems([fixture.image], in: fixture.root)

        #expect(result.movedFiles.isEmpty)
        #expect(result.failedFiles.count == 1)
        #expect(try Data(contentsOf: fixture.image) == Data("raw".utf8))
        #expect(try Data(contentsOf: fixture.memo) == Data("memo bytes".utf8))
        #expect(FileManager.default.fileExists(atPath: repository.recordURL(for: fixture.image).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.rejectedFolder.path).isEmpty)
    }

    @Test("Reject reports private backup cleanup failures while retaining committed success")
    func rejectCleanupFailureRemainsCommitted() async throws {
        let fixture = try makeVoiceMemoFixture(shared: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var io = VoiceMemoCompanionCopyIO.system
        io.remove = { url in
            if url.lastPathComponent.hasPrefix(".voice-memo-move-backup-") {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.removeItem(at: url)
        }
        let repository = VoiceMemoCompanionRepository(copyIO: io)
        let service = FileSystemService(rejectMove: { urls, folder in
            RejectMoveService.moveRejected(urls: urls, in: folder, voiceMemoRepository: repository)
        })

        let result = await service.moveRejectedItems([fixture.image], in: fixture.root)

        let movedImage = try #require(result.movedFiles.first)
        #expect(!FileManager.default.fileExists(atPath: fixture.image.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.memo.path))
        #expect(try Data(contentsOf: movedImage) == Data("raw".utf8))
        guard case .available(let association) = try repository.lookup(for: movedImage) else {
            Issue.record("Committed cleanup warning lost destination relationship")
            return
        }
        #expect(try Data(contentsOf: association.memoURL) == Data("memo bytes".utf8))
        #expect(result.failedFiles.count == 1)
        #expect(result.failedFiles.first?.1.contains("Photo moved successfully") == true)
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".voice-memo-move-backup-") }
        #expect(backups.count == 3)
        let warning = try #require(result.failedFiles.first?.1)
        let reported = try reportedBackupURLs(in: warning, after: "private source backups need cleanup: ")
        #expect(Set(reported.map { $0.resolvingSymlinksInPath().path })
            == Set(backups.map { $0.resolvingSymlinksInPath().path }))
        for backup in reported { #expect(FileManager.default.fileExists(atPath: backup.path)) }
    }

    @Test("Reject never consumes the target of a voice memo symbolic link", arguments: [false, true])
    func rejectLeavesMemoSymlinkTargetUntouched(external: Bool) async throws {
        let fixture = try makeVoiceMemoFixture(shared: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let targetFolder = external ? try makeTempFolder() : fixture.root
        defer { if external { try? FileManager.default.removeItem(at: targetFolder) } }
        let target = targetFolder.appendingPathComponent("other.WAV")
        try Data("unrelated target".utf8).write(to: target)
        try FileManager.default.removeItem(at: fixture.memo)
        try FileManager.default.createSymbolicLink(at: fixture.memo, withDestinationURL: target)
        let record = VoiceMemoCompanionRepository().recordURL(for: fixture.image)
        let originalRecord = try Data(contentsOf: record)

        let result = await FileSystemService().moveRejectedItems([fixture.image], in: fixture.root)

        #expect(result.movedFiles.isEmpty)
        #expect(result.failedFiles.count == 1)
        #expect(try Data(contentsOf: target) == Data("unrelated target".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.memo.path) == target.path)
        #expect(FileManager.default.fileExists(atPath: fixture.image.path))
        #expect(try Data(contentsOf: record) == originalRecord)
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.rejectedFolder.path).isEmpty)
    }

    @Test("Reject preserves exclusive and shared voice memos with independent source relationships", arguments: [false, true])
    func rejectPreservesVoiceMemo(shared: Bool) async throws {
        let fixture = try makeVoiceMemoFixture(shared: shared)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = VoiceMemoCompanionRepository()
        let originalJPEGRecord = shared ? try Data(contentsOf: repository.recordURL(for: fixture.jpeg)) : nil

        let result = await FileSystemService().moveRejectedItems([fixture.image], in: fixture.root)

        #expect(result.failedFiles.isEmpty)
        let image = try #require(result.movedFiles.first)
        guard case .available(let association) = try repository.lookup(for: image) else {
            Issue.record("Rejected image lost its proven voice memo")
            return
        }
        #expect(association.memoURL.lastPathComponent == (shared ? "photo.ARW.WAV" : "photo.WAV"))
        #expect(try Data(contentsOf: association.memoURL) == Data("memo bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.image.path))
        #expect(!FileManager.default.fileExists(atPath: repository.recordURL(for: fixture.image).path))
        #expect(FileManager.default.fileExists(atPath: fixture.memo.path) == shared)
        if shared {
            #expect(try Data(contentsOf: repository.recordURL(for: fixture.jpeg)) == originalJPEGRecord)
            guard case .available(let jpegAssociation) = try repository.lookup(for: fixture.jpeg) else {
                Issue.record("Remaining JPEG lost its source memo")
                return
            }
            #expect(jpegAssociation.memoURL == fixture.memo)
        }
    }

    @Test("Rejecting both shared RAW and JPEG variants carries both without a WAV collision")
    func rejectSharedPair() async throws {
        let fixture = try makeVoiceMemoFixture(shared: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = VoiceMemoCompanionRepository()

        let result = await FileSystemService().moveRejectedItems([fixture.image, fixture.jpeg], in: fixture.root)

        #expect(result.failedFiles.isEmpty)
        #expect(result.movedFiles.map(\.lastPathComponent) == ["photo.ARW", "photo.JPG"])
        var memos: Set<URL> = []
        for image in result.movedFiles {
            guard case .available(let association) = try repository.lookup(for: image) else {
                Issue.record("Rejected pair lost a relationship")
                continue
            }
            #expect(try Data(contentsOf: association.memoURL) == Data("memo bytes".utf8))
            memos.insert(association.memoURL)
        }
        #expect(memos.count == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.memo.path))
        #expect(!FileManager.default.fileExists(atPath: repository.recordURL(for: fixture.image).path))
        #expect(!FileManager.default.fileExists(atPath: repository.recordURL(for: fixture.jpeg).path))
    }

    @Test("Reject reserves orphan WAV and relationship names for the complete bundle", arguments: [false, true])
    func rejectVoiceMemoCollisionRenamesBundle(recordCollision: Bool) async throws {
        let fixture = try makeVoiceMemoFixture(shared: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = VoiceMemoCompanionRepository()
        let rejected = fixture.root.appendingPathComponent(RejectMoveService.rejectedFolderName)
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        let collision = recordCollision
            ? repository.recordURL(for: rejected.appendingPathComponent("photo.ARW"))
            : rejected.appendingPathComponent("photo.WAV")
        let unrelated = Data("unrelated existing artifact".utf8)
        try unrelated.write(to: collision)

        let result = await FileSystemService().moveRejectedItems([fixture.image], in: fixture.root)

        #expect(result.failedFiles.isEmpty)
        let image = try #require(result.movedFiles.first)
        #expect(image.lastPathComponent == "photo-1.ARW")
        guard case .available(let association) = try repository.lookup(for: image) else {
            Issue.record("Renamed reject lost relationship")
            return
        }
        #expect(association.memoURL.lastPathComponent == "photo-1.WAV")
        #expect(try Data(contentsOf: collision) == unrelated)
    }

    @Test("Reject fails closed for unavailable persisted memos", arguments: ["missing", "schema", "corrupt"])
    func rejectUnavailableMemo(kind: String) async throws {
        let fixture = try makeVoiceMemoFixture(shared: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = VoiceMemoCompanionRepository()
        let recordURL = repository.recordURL(for: fixture.image)
        if kind == "missing" { try FileManager.default.removeItem(at: fixture.memo) }
        else {
            try Data((kind == "schema" ? #"{"schemaVersion":99}"# : "corrupt").utf8).write(to: recordURL)
        }
        let sourceRecord = try Data(contentsOf: recordURL)

        let result = await FileSystemService().moveRejectedItems([fixture.image], in: fixture.root)

        #expect(result.movedFiles.isEmpty)
        #expect(result.failedFiles.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.image.path))
        #expect(try Data(contentsOf: recordURL) == sourceRecord)
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.rejectedFolder.path).isEmpty)
    }

    @Test("Reject metadata failure restores image, WAV, relationship bytes, and XMP", arguments: [false, true])
    func rejectMetadataFailureRestoresVoiceMemo(shared: Bool) async throws {
        let fixture = try makeVoiceMemoFixture(shared: shared)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = VoiceMemoCompanionRepository()
        let record = repository.recordURL(for: fixture.image)
        // Preserve formatting exactly through retirement and rollback.
        var original = try Data(contentsOf: record)
        original.append(Data("\n\n".utf8))
        try original.write(to: record)
        let xmp = fixture.image.deletingPathExtension().appendingPathExtension("xmp")
        try Data("xmp".utf8).write(to: xmp)
        try MetadataSidecarService().saveSidecar(
            MetadataSidecar(sourceFile: fixture.image.lastPathComponent), for: fixture.image, in: fixture.root
        )
        let rejected = fixture.root.appendingPathComponent(RejectMoveService.rejectedFolderName)
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        let blocker = rejected.appendingPathComponent(MetadataSidecarService.sidecarDirectoryName)
        try Data("blocker".utf8).write(to: blocker)

        let result = await FileSystemService().moveRejectedItems([fixture.image], in: fixture.root)

        #expect(result.movedFiles.isEmpty)
        #expect(result.failedFiles.count == 1)
        #expect(try Data(contentsOf: fixture.image) == Data("raw".utf8))
        #expect(try Data(contentsOf: fixture.memo) == Data("memo bytes".utf8))
        #expect(try Data(contentsOf: record) == original)
        #expect(try Data(contentsOf: xmp) == Data("xmp".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: rejected.path) == [blocker.lastPathComponent])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy {
            !$0.hasPrefix(".voice-memo-move-")
        })
    }

    @Test("Failed voice-memo installation rolls the reject back before moving editorial artifacts", arguments: ["WAV", "json"])
    func rejectMemoInstallFailureRollsBack(failingExtension: String) async throws {
        let fixture = try makeVoiceMemoFixture(shared: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = VoiceMemoCompanionRepository()
        let originalRecord = try Data(contentsOf: repository.recordURL(for: fixture.image))
        var io = VoiceMemoCompanionCopyIO.system
        io.install = { source, destination in
            if destination.pathExtension == failingExtension,
               destination.deletingLastPathComponent().lastPathComponent == RejectMoveService.rejectedFolderName {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        let injectedRepository = VoiceMemoCompanionRepository(copyIO: io)
        let service = FileSystemService(rejectMove: { urls, folder in
            RejectMoveService.moveRejected(urls: urls, in: folder, voiceMemoRepository: injectedRepository)
        })

        let result = await service.moveRejectedItems([fixture.image], in: fixture.root)

        #expect(result.movedFiles.isEmpty)
        #expect(result.failedFiles.count == 1)
        #expect(try Data(contentsOf: fixture.image) == Data("raw".utf8))
        #expect(try Data(contentsOf: fixture.memo) == Data("memo bytes".utf8))
        #expect(try Data(contentsOf: repository.recordURL(for: fixture.image)) == originalRecord)
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.rejectedFolder.path).isEmpty)
    }

    @Test("Reject rollback failure reports its recoverable original image backup")
    func rejectRollbackFailureReportsResidual() async throws {
        let fixture = try makeVoiceMemoFixture(shared: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var io = VoiceMemoCompanionCopyIO.system
        io.install = { source, destination in
            if (destination.pathExtension == "WAV"
                && destination.deletingLastPathComponent().lastPathComponent == RejectMoveService.rejectedFolderName)
                || destination == fixture.image {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        let repository = VoiceMemoCompanionRepository(copyIO: io)
        let service = FileSystemService(rejectMove: { urls, folder in
            RejectMoveService.moveRejected(urls: urls, in: folder, voiceMemoRepository: repository)
        })

        let result = await service.moveRejectedItems([fixture.image], in: fixture.root)

        let backups = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".voice-memo-move-backup-") }
        let residual = try #require(backups.first)
        #expect(result.movedFiles.isEmpty)
        #expect(result.failedFiles.count == 1)
        let warning = try #require(result.failedFiles.first?.1)
        let reported = try reportedBackupURLs(in: warning, after: "Recover these files before retrying: ")
        #expect(reported.count == 1)
        let reportedResidual = try #require(reported.first)
        #expect(reportedResidual.resolvingSymlinksInPath().path == residual.resolvingSymlinksInPath().path)
        #expect(try Data(contentsOf: reportedResidual) == Data("raw".utf8))
        #expect(try Data(contentsOf: residual) == Data("raw".utf8))
        #expect(try Data(contentsOf: fixture.memo) == Data("memo bytes".utf8))
        #expect(FileManager.default.fileExists(atPath: repository.recordURL(for: fixture.image).path))
    }

    @Test("Shared memo source edits during reject preparation discard staging")
    func rejectSourceChangedDuringPreparation() async throws {
        let fixture = try makeVoiceMemoFixture(shared: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var io = VoiceMemoCompanionCopyIO.system
        io.copy = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
            if source == fixture.memo { try Data("externally changed memo".utf8).write(to: source) }
        }
        let repository = VoiceMemoCompanionRepository(copyIO: io)
        let service = FileSystemService(rejectMove: { urls, folder in
            RejectMoveService.moveRejected(urls: urls, in: folder, voiceMemoRepository: repository)
        })

        let result = await service.moveRejectedItems([fixture.image], in: fixture.root)

        #expect(result.movedFiles.isEmpty)
        #expect(result.failedFiles.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.image.path))
        #expect(try Data(contentsOf: fixture.memo) == Data("externally changed memo".utf8))
        #expect(FileManager.default.fileExists(atPath: repository.recordURL(for: fixture.image).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.rejectedFolder.path).isEmpty)
    }

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
        return url.resolvingSymlinksInPath()
    }

    /// Foundation enumeration can spell the same temporary directory using /private/var while
    /// a mutation receipt uses /var. Validate the actual reported files and their canonical
    /// identity, rather than requiring one presentation spelling of those recoverable paths.
    private func reportedBackupURLs(in message: String, after prefix: String) throws -> [URL] {
        let marker = try #require(message.range(of: prefix))
        let pathList = message[marker.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return pathList.components(separatedBy: ", ").map { URL(fileURLWithPath: $0) }
    }

    private func makeVoiceMemoFixture(shared: Bool) throws -> (root: URL, image: URL, jpeg: URL, memo: URL) {
        let root = try makeTempFolder()
        let image = root.appendingPathComponent("photo.ARW")
        let jpeg = root.appendingPathComponent("photo.JPG")
        let memo = root.appendingPathComponent("photo.WAV")
        try Data("raw".utf8).write(to: image)
        try Data("memo bytes".utf8).write(to: memo)
        let repository = VoiceMemoCompanionRepository()
        try repository.save(VoiceMemoAssociation(profileIdentifier: "sony-ilce-1-v4", imageURL: image, memoURL: memo))
        if shared {
            try Data("jpeg".utf8).write(to: jpeg)
            try repository.save(VoiceMemoAssociation(profileIdentifier: "sony-ilce-1-v4", imageURL: jpeg, memoURL: memo))
        }
        return (root, image, jpeg, memo)
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
        let deadline = ContinuousClock.now + .seconds(30)
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
        let deadline = ContinuousClock.now + .seconds(30)
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
