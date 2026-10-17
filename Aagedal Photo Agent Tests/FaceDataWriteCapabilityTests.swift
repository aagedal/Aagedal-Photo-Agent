import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Descriptor anchored face storage publication")
struct FaceDataWriteCapabilityTests {
    private enum Refusal: Error { case withdrawn }

    nonisolated private final class Authority: @unchecked Sendable {
        private let lock = NSLock()
        private var permitted = true
        func revoke() { lock.withLock { permitted = false } }
        func check(_: URL) throws {
            try lock.withLock { if !permitted { throw Refusal.withdrawn } }
        }
    }

    private func fixture(existingStorage: Bool = true) throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/face-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        if existingStorage {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".face_data/thumbnails"), withIntermediateDirectories: true)
        }
        return root
    }

    private func document(_ root: URL) -> FolderFaceData {
        .init(folderURL: root, faces: [], groups: [], lastScanDate: Date(timeIntervalSince1970: 123), scanComplete: true)
    }

    @Test("Binding creates no directories and preserves corrupt bytes until an explicit save")
    func readOnlyBindingAndPublication() throws {
        let root = try fixture(existingStorage: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".face_data").path))
        let id = UUID(), bytes = Data("thumbnail".utf8)
        try writer.saveThumbnail(bytes, for: id)
        try writer.saveFaceData(document(root))
        #expect(try Data(contentsOf: root.appendingPathComponent(".face_data/thumbnails/\(id.uuidString).jpg")) == bytes)
        let documentURL = root.appendingPathComponent(".face_data/face_data.json")
        #expect(try JSONDecoder().decode(FolderFaceData.self, from: Data(contentsOf: documentURL)).scanComplete)
        let corrupt = Data("corrupt document".utf8)
        try corrupt.write(to: documentURL)
        _ = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in })
        #expect(try Data(contentsOf: documentURL) == corrupt)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".face_data").path).sorted() == ["face_data.json", "thumbnails"])
    }

    @Test("Existing folder, storage and thumbnail identities cannot be replaced", arguments: ["folder", ".face_data", ".face_data/thumbnails"])
    func rejectsDirectoryReplacement(component: String) throws {
        let root = try fixture()
        let original = component == "folder" ? root : root.appendingPathComponent(component)
        let moved = original.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
        }
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in })
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        do {
            try writer.saveFaceData(document(root))
            Issue.record("Replaced directory accepted")
        } catch let error as FaceDataWriteError {
            #expect(!error.committed)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".face_data/face_data.json").path))
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("face_data.json").path))
    }

    @Test("Symlinks are refused at admission and after admission", arguments: [false, true])
    func rejectsSymlink(afterAdmission: Bool) throws {
        let root = try fixture()
        let external = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
        let writer = afterAdmission ? try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in }) : nil
        let storage = root.appendingPathComponent(".face_data")
        try FileManager.default.removeItem(at: storage)
        try FileManager.default.createSymbolicLink(at: storage, withDestinationURL: external)
        if let writer {
            #expect(throws: FaceDataWriteError.self) { try writer.saveFaceData(document(root)) }
        } else {
            #expect(throws: (any Error).self) { _ = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in }) }
        }
        #expect(!FileManager.default.fileExists(atPath: external.appendingPathComponent("face_data.json").path))
    }

    @Test("System temporary aliases work, but arbitrary folder aliases grant no capability")
    func rejectsArbitraryFolderAlias() throws {
        let root = try fixture()
        let alias = root.appendingPathExtension("alias")
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        for input in [alias, alias.appendingPathComponent("child"),
                      alias.appendingPathComponent("child/.."), root.appendingPathComponent("child/..")] {
            #expect(throws: (any Error).self) {
                _ = try FaceDataWriteCapability(folderURL: input, effectAuthority: { _ in })
            }
        }
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in })
        try writer.saveFaceData(document(root))
        #expect(FaceDataStorageService().loadFaceData(for: root)?.scanComplete == true)
    }

    @Test("A newly appearing storage directory is never adopted")
    func rejectsNewExternalDirectory() throws {
        let root = try fixture(existingStorage: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in })
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".face_data"), withIntermediateDirectories: false)
        #expect(throws: FaceDataWriteError.self) { try writer.saveFaceData(document(root)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".face_data").path).isEmpty)
    }

    @Test("Swapped staging inodes are neither published nor removed as cleanup")
    func rejectsStageSwap() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let replacement = Data("attacker".utf8)
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in }, checkpoint: { point in
            if case .staged(let url) = point {
                try FileManager.default.removeItem(at: url)
                try replacement.write(to: url)
            }
        })
        do {
            try writer.saveThumbnail(Data("intended".utf8), for: UUID())
            Issue.record("Swapped stage published")
        } catch let error as FaceDataWriteError { #expect(!error.committed) }
        let entries = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".face_data/thumbnails"), includingPropertiesForKeys: nil)
        #expect(entries.count == 1)
        #expect(try entries.map { try Data(contentsOf: $0) } == [replacement])
    }

    @Test("Same-inode staging modifications are detected by byte verification")
    func rejectsModifiedStage() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in }, checkpoint: { point in
            if case .staged(let url) = point {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.write(contentsOf: Data("attacker".utf8))
            }
        })
        #expect(throws: FaceDataWriteError.self) { try writer.saveThumbnail(Data("intended".utf8), for: UUID()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".face_data/thumbnails").path).isEmpty)
    }

    @Test("Consent withdrawal before and after rename has accurate publication evidence", arguments: [false, true])
    func withdrawal(afterCommit: Bool) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = Authority()
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { try authority.check($0) }, checkpoint: { point in
            switch point {
            case .willCommit where !afterCommit: authority.revoke()
            case .didCommit where afterCommit: authority.revoke()
            default: break
            }
        })
        do {
            try writer.saveFaceData(document(root))
            Issue.record("Withdrawn authority accepted")
        } catch let error as FaceDataWriteError { #expect(error.committed == afterCommit) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".face_data/face_data.json").path) == afterCommit)
    }

    @Test("Directory replacement at publication checkpoints preserves partial-commit evidence", arguments: [false, true])
    func checkpointDirectoryReplacement(afterCommit: Bool) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent(".face_data")
        let moved = root.appendingPathComponent("retained-storage")
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in }, checkpoint: { point in
            let shouldReplace: Bool
            switch point {
            case .willCommit: shouldReplace = !afterCommit
            case .didCommit: shouldReplace = afterCommit
            default: shouldReplace = false
            }
            if shouldReplace {
                try FileManager.default.moveItem(at: original, to: moved)
                try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            }
        })
        do {
            try writer.saveFaceData(document(root))
            Issue.record("Directory replacement accepted")
        } catch let error as FaceDataWriteError { #expect(error.committed == afterCommit) }
        #expect(!FileManager.default.fileExists(atPath: original.appendingPathComponent("face_data.json").path))
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("face_data.json").path) == afterCommit)
    }

    @Test("Document folder mismatch fails before any storage effect")
    func rejectsMismatchedDocumentFolder() throws {
        let root = try fixture(existingStorage: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in })
        do {
            try writer.saveFaceData(document(root.appendingPathComponent("other")))
            Issue.record("Wrong document folder accepted")
        } catch let error as FaceDataWriteError {
            #expect(!error.committed)
            #expect(!error.directoriesCreated)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Service preserves directory-creation evidence when consent is withdrawn before file publication", arguments: [false, true])
    func serviceDirectoryCreationEvidence(thumbnail: Bool) async throws {
        let root = try fixture(existingStorage: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = Authority()
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { try authority.check($0) }, checkpoint: { point in
            if case .willCommit = point { authority.revoke() }
        })
        let service = FaceDataFolderLoadService(
            saveFaceData: { _ in Issue.record("Anchored save reached path callback") },
            saveThumbnail: { _, _, _ in Issue.record("Anchored thumbnail reached path callback") })
        let id = UUID()
        let message: String
        if thumbnail {
            let result = await service.persistThumbnail(Data("thumbnail".utf8), faceID: id,
                folderURL: root, writeCapability: writer)
            guard case .failed(_, let failure) = result else { Issue.record("File must remain unpublished"); return }
            message = failure
        } else {
            let result = await service.persist(document(root), writeCapability: writer)
            guard case .failedBeforeCommit(_, let failure) = result else { Issue.record("Document must remain unpublished"); return }
            message = failure
        }
        #expect(message.contains("Storage directories were created"))
        #expect(message.contains("not published"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".face_data/thumbnails").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".face_data/face_data.json").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".face_data/thumbnails").path).isEmpty)
    }

    @Test("Service records a published document after postcommit authority failure")
    func servicePostcommitDocumentEvidence() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = Authority()
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { try authority.check($0) }, checkpoint: { point in
            if case .didCommit = point { authority.revoke() }
        })
        let result = await FaceDataFolderLoadService().persist(document(root), writeCapability: writer)
        guard case .committed(let evidence) = result else { Issue.record("Physical document commit lost"); return }
        #expect(evidence.documentCommitted)
        #expect(evidence.authorityFailure?.contains("published, but verification failed") == true)
        #expect(!evidence.cancellationRequestedAfterCommit)
        #expect(FaceDataStorageService().loadFaceData(for: root)?.scanComplete == true)
    }

    @Test("Retained reset removes exact tree and permits subsequent anchored writes")
    func resetAndRewrite() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in })
        let id = UUID()
        try writer.saveThumbnail(Data("crop".utf8), for: id)
        try writer.saveFaceData(document(root))
        let service = FaceDataFolderLoadService(deleteFaceData: { _ in Issue.record("Retained reset reached legacy deletion") })
        let result = await service.deleteAll(for: root, writeCapability: writer)
        guard case .anchored(let evidence) = result else { Issue.record("Missing anchored reset"); return }
        #expect(evidence.completed)
        #expect(evidence.failureMessage == nil)
        #expect(evidence.removedRelativePaths == [".face_data/face_data.json", ".face_data/thumbnails/\(id.uuidString).jpg", ".face_data/thumbnails", ".face_data"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".face_data").path))
        try writer.saveFaceData(document(root))
        #expect(FaceDataStorageService().loadFaceData(for: root)?.scanComplete == true)
    }

    @Test("Reset preflight refuses symbolic links without any physical deletion")
    func resetRefusesLink() throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in })
        try Data("old".utf8).write(to: root.appendingPathComponent(".face_data/a.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".face_data/z-link"), withDestinationURL: outside)
        let result = writer.reset()
        #expect(!result.completed && result.removedRelativePaths.isEmpty)
        #expect(try Data(contentsOf: root.appendingPathComponent(".face_data/a.json")) == Data("old".utf8))
    }

    @Test("Reset authority withdrawal records the exact physical prefix", arguments: [false, true])
    func resetWithdrawal(afterRemoval: Bool) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = Authority()
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { try authority.check($0) }, checkpoint: { point in
            switch point {
            case .willRemove where !afterRemoval: authority.revoke()
            case .didRemove where afterRemoval: authority.revoke()
            default: break
            }
        })
        try Data("old".utf8).write(to: root.appendingPathComponent(".face_data/a.json"))
        let result = writer.reset()
        #expect(!result.completed)
        #expect(result.removedRelativePaths == (afterRemoval ? [".face_data/a.json"] : []))
        #expect(result.failureMessage != nil)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".face_data/a.json").path) != afterRemoval)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".face_data/thumbnails").path))
    }

    @Test("Directory replacement at reset boundaries cannot redirect traversal", arguments: [false, true])
    func resetDirectoryReplacement(afterRemoval: Bool) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent(".face_data"), moved = root.appendingPathComponent("saved")
        try Data("old".utf8).write(to: original.appendingPathComponent("a.json"))
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in }, checkpoint: { point in
            let replace: Bool
            switch point {
            case .willRemove: replace = !afterRemoval
            case .didRemove: replace = afterRemoval
            default: replace = false
            }
            if replace {
                try FileManager.default.moveItem(at: original, to: moved)
                try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
                try Data("replacement".utf8).write(to: original.appendingPathComponent("sentinel"))
            }
        })
        let result = writer.reset()
        #expect(!result.completed)
        #expect(result.removedRelativePaths == (afterRemoval ? [".face_data/a.json"] : []))
        #expect(try Data(contentsOf: original.appendingPathComponent("sentinel")) == Data("replacement".utf8))
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("a.json").path) != afterRemoval)
    }

    @Test("Reset cancellation before or after physical removal retains exact evidence", arguments: [false, true])
    func resetCancellation(afterRemoval: Bool) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: root.appendingPathComponent(".face_data/a.json"))
        let result = await Task {
            let writer = try! FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in }, checkpoint: { point in
                switch point {
                case .willRemove where !afterRemoval: withUnsafeCurrentTask { $0?.cancel() }
                case .didRemove where afterRemoval: withUnsafeCurrentTask { $0?.cancel() }
                default: break
                }
            })
            return await FaceDataFolderLoadService().deleteAll(for: root, writeCapability: writer)
        }.value
        guard case .anchored(let result) = result else { Issue.record("Missing reset evidence"); return }
        #expect(!result.completed && result.cancellationRequested)
        #expect(result.removedRelativePaths == (afterRemoval ? [".face_data/a.json"] : []))
    }

    @Test("An externally appearing storage directory is refused by reset")
    func resetAbsentBinding() throws {
        let root = try fixture(existingStorage: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in })
        #expect(writer.reset().completed)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".face_data"), withIntermediateDirectories: false)
        let result = writer.reset()
        #expect(!result.completed && result.removedRelativePaths.isEmpty)
    }

    @Test("Reset refuses substituted leaf inodes without deleting the replacement")
    func resetLeafReplacement() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let leaf = root.appendingPathComponent(".face_data/a.json")
        let saved = root.appendingPathComponent("original")
        try Data("original".utf8).write(to: leaf)
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in }, checkpoint: { point in
            if case .willRemove(".face_data/a.json") = point {
                try FileManager.default.moveItem(at: leaf, to: saved)
                try Data("replacement".utf8).write(to: leaf)
            }
        })
        let evidence = writer.reset()
        #expect(!evidence.completed && evidence.removedRelativePaths.isEmpty)
        #expect(try Data(contentsOf: leaf) == Data("replacement".utf8))
        #expect(try Data(contentsOf: saved) == Data("original".utf8))
    }

    @Test("Nested reset failures preserve each physical removal boundary", arguments: [".face_data/nested/a", ".face_data/nested", ".face_data/thumbnails", ".face_data"], [false, true])
    func resetPhysicalFailure(path: String, afterRemoval: Bool) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".face_data/nested"), withIntermediateDirectories: false)
        try Data("old".utf8).write(to: root.appendingPathComponent(".face_data/nested/a"))
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in }, checkpoint: { point in
            switch point {
            case .willRemove(let entry) where !afterRemoval && entry == path: throw Refusal.withdrawn
            case .didRemove(let entry) where afterRemoval && entry == path: throw Refusal.withdrawn
            default: break
            }
        })
        let evidence = writer.reset()
        #expect(!evidence.completed && evidence.failureMessage != nil)
        let all = [".face_data/nested/a", ".face_data/nested", ".face_data/thumbnails", ".face_data"]
        let count = try #require(all.firstIndex(of: path)) + (afterRemoval ? 1 : 0)
        #expect(evidence.removedRelativePaths == Array(all.prefix(count)))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".face_data").path) == (count != all.count))
    }

    @Test("Authority cancellation is retained even before task cancellation arrives", arguments: [false, true])
    func resetAuthorityCancellation(afterRemoval: Bool) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: root.appendingPathComponent(".face_data/a.json"))
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in }, checkpoint: { point in
            switch point {
            case .willRemove where !afterRemoval: throw CancellationError()
            case .didRemove where afterRemoval: throw CancellationError()
            default: break
            }
        })
        let evidence = writer.reset()
        #expect(!evidence.completed && evidence.cancellationRequested && evidence.failureMessage == nil)
        #expect(evidence.removedRelativePaths == (afterRemoval ? [".face_data/a.json"] : []))
    }

    @Test("Reset removes an admitted hardlink without changing external file bytes")
    func resetHardlink() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("photo-sentinel")
        let bytes = Data("preserve outside storage".utf8)
        try bytes.write(to: external)
        try FileManager.default.linkItem(at: external, to: root.appendingPathComponent(".face_data/linked"))
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in })
        let evidence = writer.reset()
        #expect(evidence.completed)
        #expect(evidence.removedRelativePaths.contains(".face_data/linked"))
        #expect(try Data(contentsOf: external) == bytes)
    }

    @Test("Overdeep reset trees refuse before any removal")
    func resetDepthLimit() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent(".face_data/a.json")
        try Data("preserve".utf8).write(to: original)
        var nested = root.appendingPathComponent(".face_data")
        for _ in 0..<64 {
            nested.appendPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        }
        let writer = try FaceDataWriteCapability(folderURL: root, effectAuthority: { _ in })
        let evidence = writer.reset()
        #expect(!evidence.completed && evidence.removedRelativePaths.isEmpty)
        #expect(try Data(contentsOf: original) == Data("preserve".utf8))
    }

}
