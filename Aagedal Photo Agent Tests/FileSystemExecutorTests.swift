import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Filesystem Dispatch executor")
struct FileSystemExecutorTests {
    @Test("Trash keeps shared RAW/JPEG companions in independent recoverable bundles")
    func trashPreservesSharedBundles() async throws {
        let root = try trashTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("photo.ARW")
        let jpeg = root.appendingPathComponent("photo.JPG")
        let memo = root.appendingPathComponent("photo.WAV")
        let xmp = root.appendingPathComponent("photo.xmp")
        let metadataFolder = root.appendingPathComponent(".photo_metadata")
        let legacy = metadataFolder.appendingPathComponent("photo.meta.json")
        let current = metadataFolder.appendingPathComponent("photo.ARW.meta.json")
        try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        for url in [raw, jpeg, memo] { try Data(url.lastPathComponent.utf8).write(to: url) }
        try Data("<xmp><unknown>preserved</unknown></xmp>".utf8).write(to: xmp)
        try Data(#"{"sourceFile":"photo.JPG","unknown":"legacy"}"#.utf8).write(to: legacy)
        try Data(#"{"sourceFile":"photo.ARW","unknown":"current"}"#.utf8).write(to: current)
        let repository = VoiceMemoCompanionRepository()
        for image in [raw, jpeg] {
            try repository.save(.init(profileIdentifier: "synthetic-trash", imageURL: image, memoURL: memo))
        }
        let trash = root.appendingPathComponent("Fake Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let handler = ExecutorTestTrashHandler { bundle in
            #expect(!bundle.lastPathComponent.hasPrefix("."))
            #expect(bundle.lastPathComponent.contains("Photo Agent Trash"))
            try FileManager.default.moveItem(at: bundle, to: trash.appendingPathComponent(bundle.lastPathComponent))
        }
        let first = await FileSystemService().trashItems([raw], using: handler)
        #expect(first.completedSourceURLs == [raw])
        #expect(first.failures.isEmpty)
        #expect(try repository.lookup(for: jpeg) != .none)
        for shared in [memo, xmp, legacy] { #expect(FileManager.default.fileExists(atPath: shared.path)) }
        #expect(!FileManager.default.fileExists(atPath: current.path))
        let firstBundle = try #require(FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: firstBundle.appendingPathComponent(".photo_metadata/photo.ARW.meta.json"))
                == Data(#"{"sourceFile":"photo.ARW","unknown":"current"}"#.utf8))
        let second = await FileSystemService().trashItems([jpeg], using: handler)
        #expect(second.completedSourceURLs == [jpeg])
        #expect(second.failures.isEmpty)
        for source in [raw, jpeg, memo, xmp, legacy] { #expect(!FileManager.default.fileExists(atPath: source.path)) }
        let bundles = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        #expect(bundles.count == 2)
        for bundle in bundles {
            let image = bundle.appendingPathComponent(bundle == firstBundle ? "photo.ARW" : "photo.JPG")
            guard case .available(let association) = try repository.lookup(for: image) else {
                Issue.record("Trash bundle lost its proven association")
                continue
            }
            #expect(try Data(contentsOf: association.memoURL) == Data("photo.WAV".utf8))
            #expect(try Data(contentsOf: bundle.appendingPathComponent("photo.xmp"))
                    == Data("<xmp><unknown>preserved</unknown></xmp>".utf8))
            let bundledLegacy = bundle.appendingPathComponent(".photo_metadata/photo.meta.json")
            if bundle == firstBundle {
                #expect(!FileManager.default.fileExists(atPath: bundledLegacy.path))
            } else {
                #expect(try Data(contentsOf: bundledLegacy) == Data(#"{"sourceFile":"photo.JPG","unknown":"legacy"}"#.utf8))
            }
        }
    }

    @Test("Trash preserves opaque unreadable XMP byte-for-byte for recovery")
    func trashPreservesOpaqueXMP() async throws {
        let root = try trashTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (image, _, _) = try trashTestAssociation(in: root)
        let xmp = root.appendingPathComponent("photo.xmp")
        let opaqueBytes = Data([0xff, 0xfe, 0x00, 0x3c, 0x01])
        try opaqueBytes.write(to: xmp)
        let trashed = root.appendingPathComponent("Fake Trash Bundle")
        let result = await FileSystemService().trashItems([image], using: ExecutorTestTrashHandler { bundle in
            try FileManager.default.moveItem(at: bundle, to: trashed)
        })
        #expect(result.completedSourceURLs == [image])
        #expect(result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: xmp.path))
        #expect(try Data(contentsOf: trashed.appendingPathComponent("photo.xmp")) == opaqueBytes)
    }

    @Test("Trash restores exact originals after retirement or Trash failure", arguments: [false, true])
    func trashRestoresOriginals(failDuringRetirement: Bool) throws {
        let root = try trashTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (image, memo, repository) = try trashTestAssociation(in: root)
        let originalRecord = try Data(contentsOf: repository.recordURL(for: image))
        var io = VoiceMemoCompanionCopyIO.system
        if failDuringRetirement {
            io.install = { source, destination in
                if source == memo { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }
        let tested = VoiceMemoCompanionRepository(copyIO: io)
        do {
            try tested.trashImagePreservingCompanion(at: image, using: ExecutorTestTrashHandler { _ in
                throw CocoaError(.fileWriteUnknown)
            })
            Issue.record("Expected injected Trash failure")
        } catch { }
        #expect(try Data(contentsOf: image) == Data("photo".utf8))
        #expect(try Data(contentsOf: memo) == Data("audio".utf8))
        #expect(try Data(contentsOf: repository.recordURL(for: image)) == originalRecord)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 3)
    }

    @Test("Trash source retirement races preserve the actual newer bytes", arguments: [false, true])
    func trashRetirementRacePreservesNewBytes(changeMemo: Bool) throws {
        let root = try trashTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (image, memo, _) = try trashTestAssociation(in: root)
        let changed = changeMemo ? memo : image
        var io = VoiceMemoCompanionCopyIO.system
        io.install = { source, destination in
            if source == changed { try Data("newer bytes".utf8).write(to: source) }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        do {
            try VoiceMemoCompanionRepository(copyIO: io).trashImagePreservingCompanion(
                at: image, using: ExecutorTestTrashHandler { _ in Issue.record("Changed source reached Trash") }
            )
            Issue.record("Expected source-change rejection")
        } catch { }
        #expect(try Data(contentsOf: changed) == Data("newer bytes".utf8))
        #expect(FileManager.default.fileExists(atPath: image.path))
        #expect(FileManager.default.fileExists(atPath: memo.path))
    }

    @Test("A new differently named memo owner during retirement stops Trash and preserves both photos")
    func trashRejectsNewMemoOwner() throws {
        let root = try trashTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (image, memo, repository) = try trashTestAssociation(in: root)
        let newOwner = root.appendingPathComponent("different.JPG")
        var io = VoiceMemoCompanionCopyIO.system
        io.install = { source, destination in
            if source == image {
                try Data("new owner".utf8).write(to: newOwner)
                try repository.save(.init(profileIdentifier: "synthetic-trash", imageURL: newOwner, memoURL: memo))
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        do {
            try VoiceMemoCompanionRepository(copyIO: io).trashImagePreservingCompanion(
                at: image, using: ExecutorTestTrashHandler { _ in Issue.record("Newly shared WAV reached Trash") }
            )
            Issue.record("Expected ownership-change rejection")
        } catch { }
        for owner in [image, newOwner] {
            guard case .available(let association) = try repository.lookup(for: owner) else {
                Issue.record("Ownership race lost an association")
                continue
            }
            #expect(try Data(contentsOf: association.memoURL) == Data("audio".utf8))
        }
    }

    @Test("Shared memo partial-copy failure and preparation cancellation leave originals untouched", arguments: [false, true])
    func trashSharedPreparationFailure(cancel: Bool) async throws {
        let root = try trashTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (image, memo, repository) = try trashTestAssociation(in: root)
        let sibling = root.appendingPathComponent("photo.ARW")
        try Data("sibling".utf8).write(to: sibling)
        try repository.save(.init(profileIdentifier: "synthetic-trash", imageURL: sibling, memoURL: memo))
        var io = VoiceMemoCompanionCopyIO.system
        io.copy = { source, destination in
            if cancel {
                try FileManager.default.copyItem(at: source, to: destination)
                withUnsafeCurrentTask { $0?.cancel() }
            } else {
                try Data("partial bytes".utf8).write(to: destination)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let tested = VoiceMemoCompanionRepository(copyIO: io)
        await Task {
            do {
                try tested.trashImagePreservingCompanion(at: image, using: ExecutorTestTrashHandler { _ in
                    Issue.record("Failed or cancelled preparation reached Trash")
                })
                Issue.record("Expected preparation rejection")
            } catch { }
        }.value
        #expect(try Data(contentsOf: image) == Data("photo".utf8))
        #expect(try Data(contentsOf: memo) == Data("audio".utf8))
        for owner in [image, sibling] {
            guard case .available = try repository.lookup(for: owner) else {
                Issue.record("Preparation failure lost an association")
                continue
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 5)
    }

    @Test("Trash rollback collision keeps new source and reports recoverable original paths")
    func trashRollbackRecoveryPaths() throws {
        let root = try trashTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (image, memo, _) = try trashTestAssociation(in: root)
        do {
            try VoiceMemoCompanionRepository().trashImagePreservingCompanion(
                at: image, using: ExecutorTestTrashHandler { _ in
                    try Data("external new photo".utf8).write(to: image)
                    throw CocoaError(.fileWriteUnknown)
                }
            )
            Issue.record("Expected recovery failure")
        } catch VoiceMemoCompanionRepository.RepositoryError.trashRollbackFailed(let paths) {
            #expect(paths.count == 1)
            let backup = try #require(paths.first)
            #expect(try Data(contentsOf: URL(fileURLWithPath: backup)) == Data("photo".utf8))
        }
        #expect(try Data(contentsOf: image) == Data("external new photo".utf8))
        #expect(try Data(contentsOf: memo) == Data("audio".utf8))
    }

    @Test("Trash reports an uncertain outcome when a handler commits then throws")
    func trashThrowAfterCommitPreservesEvidence() async throws {
        let root = try trashTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (image, _, repository) = try trashTestAssociation(in: root)
        let trashed = root.appendingPathComponent("Fake Trash Bundle")
        let result = await FileSystemService().trashItems([image], using: ExecutorTestTrashHandler { bundle in
            try FileManager.default.moveItem(at: bundle, to: trashed)
            throw CocoaError(.fileWriteUnknown)
        })
        #expect(result.completedSourceURLs.isEmpty)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.message.contains("Check Finder Trash") == true)
        #expect(!FileManager.default.fileExists(atPath: image.path))
        let recoverable = trashed.appendingPathComponent(image.lastPathComponent)
        #expect(try Data(contentsOf: recoverable) == Data("photo".utf8))
        guard case .available = try repository.lookup(for: recoverable) else {
            Issue.record("Ambiguous handler outcome must retain complete recovery bundle")
            return
        }
    }

    @Test("Trash fails closed for unsafe saved companions and continues independent photos", arguments: 0..<10)
    func trashUnsafeCompanionPartialSuccess(kind: Int) async throws {
        let root = try trashTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (image, memo, repository) = try trashTestAssociation(in: root)
        let record = repository.recordURL(for: image)
        switch kind {
        case 0: try FileManager.default.removeItem(at: memo)
        case 1: try Data(#"{"schemaVersion":99}"#.utf8).write(to: record)
        case 2: try Data("corrupt".utf8).write(to: record)
        case 3:
            try FileManager.default.removeItem(at: memo)
            try FileManager.default.createSymbolicLink(at: memo, withDestinationURL: image)
        case 4:
            let metadata = root.appendingPathComponent(".photo_metadata")
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            try Data(#"{"sourceFile":"../other.JPG"}"#.utf8).write(to: metadata.appendingPathComponent("photo.JPG.meta.json"))
        case 5:
            try FileManager.default.removeItem(at: record)
            try FileManager.default.createSymbolicLink(at: record, withDestinationURL: root.appendingPathComponent("missing-record"))
        case 6:
            let metadata = root.appendingPathComponent(".photo_metadata")
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            try Data("malformed JSON".utf8).write(to: metadata.appendingPathComponent("photo.JPG.meta.json"))
        case 7:
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("photo.xmp"), withDestinationURL: image)
        case 8:
            let metadata = root.appendingPathComponent(".photo_metadata")
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: metadata.appendingPathComponent("photo.JPG.meta.json"), withDestinationURL: record)
        default:
            let linked = root.appendingPathComponent("Other Metadata")
            try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".photo_metadata"), withDestinationURL: linked)
        }
        let recordAttributes = try FileManager.default.attributesOfItem(atPath: record.path)
        let independent = root.appendingPathComponent("independent.JPG")
        let unrelatedWAV = root.appendingPathComponent("independent.WAV")
        try Data("independent".utf8).write(to: independent)
        try Data("unproven".utf8).write(to: unrelatedWAV)
        let result = await FileSystemService().trashItems([image, independent], using: ExecutorTestTrashHandler { url in
            #expect(url == independent)
            try FileManager.default.removeItem(at: url)
        })
        #expect(result.completedSourceURLs == [independent])
        #expect(result.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: image.path))
        #expect(try FileManager.default.attributesOfItem(atPath: record.path)[.type] as? FileAttributeType
                == recordAttributes[.type] as? FileAttributeType)
        #expect(try Data(contentsOf: unrelatedWAV) == Data("unproven".utf8))
    }

    @Test("Cancellation while a companion bundle enters Trash reports its commit and stops the next photo")
    func trashBundleCommitCancellation() async throws {
        let root = try trashTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (image, _, _) = try trashTestAssociation(in: root)
        let second = root.appendingPathComponent("second.JPG")
        try Data("second".utf8).write(to: second)
        let result = await Task {
            await FileSystemService().trashItems([image, second], using: ExecutorTestTrashHandler { bundle in
                #expect(bundle.lastPathComponent.contains("Photo Agent Trash"))
                try FileManager.default.removeItem(at: bundle)
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }.value
        #expect(result.completedSourceURLs == [image])
        #expect(result.failures.isEmpty)
        #expect(result.cancellationStoppedRemainingItems)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    private func trashTestRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func trashTestAssociation(in root: URL) throws -> (URL, URL, VoiceMemoCompanionRepository) {
        let image = root.appendingPathComponent("photo.JPG")
        let memo = root.appendingPathComponent("photo.WAV")
        try Data("photo".utf8).write(to: image)
        try Data("audio".utf8).write(to: memo)
        let repository = VoiceMemoCompanionRepository()
        try repository.save(.init(profileIdentifier: "synthetic-trash", imageURL: image, memoURL: memo))
        return (image, memo, repository)
    }

    @Test("Browser move preserves shared voice memos for both variants and editorial sidecars")
    func movePreservesSharedVoiceMemoBundles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Moved")
        let raw = root.appendingPathComponent("photo.ARW")
        let jpeg = root.appendingPathComponent("photo.JPG")
        let memo = root.appendingPathComponent("photo.WAV")
        let memoBytes = Data("shared memo".utf8)
        try memoBytes.write(to: memo)
        let repository = VoiceMemoCompanionRepository()
        let metadata = MetadataSidecarService()
        for image in [raw, jpeg] {
            try Data(image.lastPathComponent.utf8).write(to: image)
            try repository.save(VoiceMemoAssociation(
                profileIdentifier: "synthetic-move", imageURL: image, memoURL: memo
            ))
            try metadata.saveSidecar(
                MetadataSidecar(sourceFile: image.lastPathComponent, metadata: IPTCMetadata(title: image.lastPathComponent)),
                for: image, in: root
            )
        }
        let result = try await FileSystemService().moveImageItems(
            [raw, jpeg], into: destination, createDestinationIfNeeded: true,
            xmpSidecarService: XMPSidecarService(), metadataSidecarService: metadata
        )
        #expect(result.movedSourceURLs == [raw, jpeg])
        #expect(result.failures.isEmpty)
        #expect(!result.cancellationStoppedRemainingItems)
        for image in [raw, jpeg] {
            let moved = destination.appendingPathComponent(image.lastPathComponent)
            #expect(!FileManager.default.fileExists(atPath: image.path))
            #expect(!FileManager.default.fileExists(atPath: repository.recordURL(for: image).path))
            #expect(try Data(contentsOf: moved) == Data(image.lastPathComponent.utf8))
            guard case .available(let association) = try repository.lookup(for: moved) else {
                Issue.record("Moved image lost its voice memo")
                continue
            }
            #expect(association.memoURL.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == destination.resolvingSymlinksInPath().path)
            #expect(try Data(contentsOf: association.memoURL) == memoBytes)
            #expect(metadata.loadSidecar(for: moved, in: destination)?.metadata.title == image.lastPathComponent)
        }
        #expect(!FileManager.default.fileExists(atPath: memo.path))
    }

    @Test("Browser move fails closed for unavailable voice memos while continuing independent images", arguments: [false, true])
    func moveRejectsUnavailableVoiceMemo(unsupported: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("associated.JPG")
        let independent = root.appendingPathComponent("independent.JPG")
        let memo = root.appendingPathComponent("memo.WAV")
        for url in [image, independent, memo] { try Data(url.lastPathComponent.utf8).write(to: url) }
        let repository = VoiceMemoCompanionRepository()
        try repository.save(VoiceMemoAssociation(profileIdentifier: "synthetic-move", imageURL: image, memoURL: memo))
        if unsupported {
            try Data(#"{"schemaVersion":99}"#.utf8).write(to: repository.recordURL(for: image))
        } else {
            try FileManager.default.removeItem(at: memo)
        }
        let recordBefore = try Data(contentsOf: repository.recordURL(for: image))
        let destination = root.appendingPathComponent("Moved")
        let result = try await FileSystemService().moveImageItems(
            [image, independent], into: destination, createDestinationIfNeeded: true,
            xmpSidecarService: XMPSidecarService(), metadataSidecarService: MetadataSidecarService()
        )
        #expect(result.movedSourceURLs == [independent])
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.sourceURL == image)
        #expect(FileManager.default.fileExists(atPath: image.path))
        #expect(try Data(contentsOf: repository.recordURL(for: image)) == recordBefore)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(image.lastPathComponent).path))
    }

    @Test("Browser move cannot associate an unproven WAV or overwrite an orphan relationship")
    func moveWithoutProvenMemoRejectsOrphanRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("photo.JPG")
        let unprovenMemo = root.appendingPathComponent("photo.WAV")
        try Data("image".utf8).write(to: image)
        try Data("unproven".utf8).write(to: unprovenMemo)
        let repository = VoiceMemoCompanionRepository()
        let orphan = repository.recordURL(for: destination.appendingPathComponent("photo.JPG"))
        try Data("unrelated".utf8).write(to: orphan)
        let service = FileSystemService()
        let blocked = try await service.moveImageItems(
            [image], into: destination, createDestinationIfNeeded: false,
            xmpSidecarService: XMPSidecarService(), metadataSidecarService: MetadataSidecarService()
        )
        #expect(blocked.movedSourceURLs.isEmpty)
        #expect(blocked.failures.count == 1)
        #expect(try Data(contentsOf: orphan) == Data("unrelated".utf8))
        let safeDestination = root.appendingPathComponent("Safe")
        let moved = try await service.moveImageItems(
            [image], into: safeDestination, createDestinationIfNeeded: true,
            xmpSidecarService: XMPSidecarService(), metadataSidecarService: MetadataSidecarService()
        )
        #expect(moved.movedSourceURLs == [image])
        #expect(moved.failures.isEmpty)
        #expect(try repository.lookup(for: safeDestination.appendingPathComponent("photo.JPG")) == .none)
        #expect(try Data(contentsOf: unprovenMemo) == Data("unproven".utf8))
        #expect(!FileManager.default.fileExists(atPath: safeDestination.appendingPathComponent("photo.WAV").path))
    }

    @Test("Browser move reserves existing XMP and both editorial carrier names", arguments: ["photo.xmp", ".photo_metadata/photo.JPG.meta.json", ".photo_metadata/photo.meta.json"])
    func movePreservesOrphanMetadata(relativePath: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.JPG")
        try Data("image".utf8).write(to: source)
        let orphan = destination.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("unrelated destination metadata".utf8)
        try original.write(to: orphan)
        let metadata = MetadataSidecarService()
        try metadata.saveSidecar(MetadataSidecar(sourceFile: "photo.JPG", metadata: IPTCMetadata(title: "Source")), for: source, in: root)
        let result = try await FileSystemService().moveImageItems(
            [source], into: destination, createDestinationIfNeeded: false,
            xmpSidecarService: XMPSidecarService(), metadataSidecarService: metadata
        )
        #expect(result.movedSourceURLs.isEmpty)
        #expect(result.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: orphan) == original)
        #expect(metadata.loadSidecar(for: source, in: root)?.metadata.title == "Source")
    }

    @Test("Editorial move refuses existing destination data independently of photo preflight", arguments: [false, true])
    func editorialMoveCannotOverwrite(legacy: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: destination.appendingPathComponent(".photo_metadata"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("photo.JPG")
        let service = MetadataSidecarService()
        try service.saveSidecar(MetadataSidecar(sourceFile: "photo.JPG", metadata: IPTCMetadata(title: "Source")), for: image, in: root)
        let orphan = destination.appendingPathComponent(".photo_metadata/" + (legacy ? "photo.meta.json" : "photo.JPG.meta.json"))
        let original = Data("unrelated".utf8)
        try original.write(to: orphan)
        #expect(throws: (any Error).self) {
            try service.moveSidecar(for: image, from: root, to: destination)
        }
        #expect(try Data(contentsOf: orphan) == original)
        #expect(service.loadSidecar(for: image, in: root)?.metadata.title == "Source")
        #expect(throws: (any Error).self) {
            try service.relocateSidecar(for: image, to: destination.appendingPathComponent("photo.JPG"), from: root, to: destination)
        }
        #expect(try Data(contentsOf: orphan) == original)
        #expect(service.loadSidecar(for: image, in: root)?.metadata.title == "Source")
    }

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
