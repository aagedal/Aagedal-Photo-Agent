import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Template file authority")
struct TemplateFileAuthorityTests {
    @Test("Exact bytes and directory identity protect metadata mutations",
          arguments: ["bytes", "directory"])
    func metadataConflict(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = MetadataTemplate(name: "Original", shortcutSlot: 1)
        let peer = MetadataTemplate(name: "Peer", shortcutSlot: 2)
        let storage = TemplateStorageService(directoryURL: root)
        try storage.save(original)
        try storage.save(peer)
        var edited = original
        edited.name = "Draft"
        edited.shortcutSlot = 2
        try await checkConflict(root: root, original: original, edited: edited, peer: peer,
                                change: change, access: .storage(storage))
    }

    @Test("Exact bytes and directory identity protect Develop mutations",
          arguments: ["bytes", "directory"])
    func developConflict(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = DevelopTemplate(name: "Original", shortcutSlot: 1)
        let peer = DevelopTemplate(name: "Peer", shortcutSlot: 2)
        let storage = DevelopTemplateStorageService(directoryURL: root)
        try storage.save(original)
        try storage.save(peer)
        var edited = original
        edited.name = "Draft"
        edited.shortcutSlot = 2
        try await checkConflict(root: root, original: original, edited: edited, peer: peer,
                                change: change, access: .storage(storage))
    }

    private func checkConflict<Value: Identifiable & Sendable & Equatable>(
        root: URL, original: Value, edited: Value, peer: Value,
        change: String, access: TemplateCRUDAccess<Value>
    ) async throws where Value.ID == UUID {
        let service = TemplateCRUDService(access: access)
        guard case .loaded(let inventory) = try await service.load(requestID: UUID()) else {
            Issue.record("Inventory did not load"); return
        }
        let authority = try #require(inventory.authorities[original.id])
        let file = root.appendingPathComponent("\(original.id.uuidString).json")
        let peerFile = root.appendingPathComponent("\(peer.id.uuidString).json")
        if change == "bytes" {
            var bytes = try Data(contentsOf: file)
            bytes.append(contentsOf: [10, 32]) // Same decoded value, different document.
            try bytes.write(to: file)
        } else {
            let old = root.appendingPathExtension("old")
            defer { try? FileManager.default.removeItem(at: old) }
            try FileManager.default.moveItem(at: root, to: old)
            try FileManager.default.copyItem(at: old, to: root)
        }
        let bytes = try Data(contentsOf: file)
        let peerBytes = try Data(contentsOf: peerFile)
        for operation in ["save", "delete"] {
            do {
                if operation == "save" {
                    _ = try await service.save(edited, expectedExisting: original,
                                               expectedDirectoryURL: inventory.directoryURL,
                                               expectedAuthority: authority, requestID: UUID())
                } else {
                    _ = try await service.delete(original, expectedDirectoryURL: inventory.directoryURL,
                                                 expectedAuthority: authority, requestID: UUID())
                }
                Issue.record("Changed authority allowed \(operation)")
            } catch let error as TemplateMutationError<Value> {
                #expect(error.isSnapshotConflict)
                #expect(error.durableTemplateIDs.isEmpty)
            }
            #expect(try Data(contentsOf: file) == bytes)
            #expect(try Data(contentsOf: peerFile) == peerBytes)
        }
    }

    @MainActor
    @Test("Refreshing a metadata list does not replace an open editor's byte authority")
    func refreshRetainsEditorAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TemplateStorageService(directoryURL: root)
        let original = MetadataTemplate(name: "Original")
        try storage.save(original)
        let editor = TemplateViewModel(storage: storage)
        await withCheckedContinuation { continuation in
            editor.loadTemplates { _ in continuation.resume() }
        }
        editor.startEditing(original)
        editor.editingTemplate.name = "Unsaved draft"
        let file = root.appendingPathComponent("\(original.id.uuidString).json")
        var bytes = try Data(contentsOf: file)
        bytes.append(10)
        try bytes.write(to: file)
        await withCheckedContinuation { continuation in
            editor.loadTemplates { _ in continuation.resume() }
        }
        for _ in 0..<2 {
            guard case .failure(let error) = await editor.saveEditingTemplate() else {
                Issue.record("Reload silently adopted new bytes"); return
            }
            #expect(error.isSnapshotConflict)
            #expect(editor.isEditing)
            #expect(editor.editingTemplate.name == "Unsaved draft")
            #expect(try Data(contentsOf: file) == bytes)
        }
        guard case .success(let copy) = await editor.saveEditingTemplateAsNew() else {
            Issue.record("Save as New failed"); return
        }
        #expect(copy.id != original.id)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test("Duplicate IDs and mismatched filenames cannot grant mutation authority",
          arguments: ["duplicate", "mismatch"])
    func ambiguousFiles(state: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TemplateStorageService(directoryURL: root)
        let original = MetadataTemplate(name: "Original")
        try storage.save(original)
        let canonical = root.appendingPathComponent("\(original.id.uuidString).json")
        let other = root.appendingPathComponent("other.json")
        try FileManager.default.copyItem(at: canonical, to: other)
        if state == "mismatch" { try FileManager.default.removeItem(at: canonical) }
        let service = TemplateCRUDService(access: .storage(storage))
        guard case .loaded(let inventory) = try await service.load(requestID: UUID()) else {
            Issue.record("Inventory did not load"); return
        }
        #expect(inventory.authorities[original.id] == nil)
    }

    @Test("Production existing mutations refuse omitted authority for metadata and Develop",
          arguments: ["metadata", "develop"])
    func omittedAuthority(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = TemplateTrashAccess(moveItem: { _ in
            Issue.record("Missing authority reached Trash")
        })
        if kind == "metadata" {
            let original = MetadataTemplate(name: "Original")
            let storage = TemplateStorageService(directoryURL: root, trashAccess: trash)
            try storage.save(original)
            try await checkOmittedAuthority(root: root, original: original, access: .storage(storage))
        } else {
            let original = DevelopTemplate(name: "Original")
            let storage = DevelopTemplateStorageService(directoryURL: root, trashAccess: trash)
            try storage.save(original)
            try await checkOmittedAuthority(root: root, original: original, access: .storage(storage))
        }
    }

    private func checkOmittedAuthority<Value: Identifiable & Sendable & Equatable>(
        root: URL, original: Value, access: TemplateCRUDAccess<Value>
    ) async throws where Value.ID == UUID {
        let service = TemplateCRUDService(access: access)
        let file = root.appendingPathComponent("\(original.id.uuidString).json")
        let before = try Data(contentsOf: file)
        for operation in ["save", "delete"] {
            do {
                if operation == "save" {
                    // Omitting expectedExisting must not disguise an overwrite as creation.
                    _ = try await service.save(original, requestID: UUID())
                } else {
                    _ = try await service.delete(original, requestID: UUID())
                }
                Issue.record("Missing authority permitted \(operation)")
            } catch let error as TemplateMutationError<Value> {
                #expect(error.isSnapshotConflict)
                #expect(error.durableTemplateIDs.isEmpty)
            }
            #expect(try Data(contentsOf: file) == before)
        }
    }

    @Test("Ambiguous shortcut conflicts refuse before any writes",
          arguments: ["duplicate", "mismatch"])
    func ambiguousShortcutMutation(state: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TemplateStorageService(directoryURL: root)
        let original = MetadataTemplate(name: "Original", shortcutSlot: 1)
        let validPeer = MetadataTemplate(name: "A valid shortcut peer", shortcutSlot: 1)
        try storage.save(original)
        try storage.save(validPeer)
        let canonical = root.appendingPathComponent("\(original.id.uuidString).json")
        let other = root.appendingPathComponent("other.json")
        let peerFile = root.appendingPathComponent("\(validPeer.id.uuidString).json")
        let originalBytes = try Data(contentsOf: canonical)
        let peerBytes = try Data(contentsOf: peerFile)
        try FileManager.default.copyItem(at: canonical, to: other)
        if state == "mismatch" { try FileManager.default.removeItem(at: canonical) }
        let requested = MetadataTemplate(name: "Requested", shortcutSlot: 1)
        let requestedFile = root.appendingPathComponent("\(requested.id.uuidString).json")
        let service = TemplateCRUDService(access: .storage(storage))
        do {
            _ = try await service.save(requested, requestID: UUID())
            Issue.record("Ambiguous shortcut allowed mutation")
        } catch let error as TemplateMutationError<MetadataTemplate> {
            #expect(error.isSnapshotConflict)
            #expect(error.durableTemplateIDs.isEmpty)
        }
        #expect(try Data(contentsOf: other) == originalBytes)
        #expect(try Data(contentsOf: peerFile) == peerBytes)
        #expect(!FileManager.default.fileExists(atPath: requestedFile.path))
        if state == "duplicate" {
            #expect(try Data(contentsOf: canonical) == originalBytes)
        } else {
            #expect(!FileManager.default.fileExists(atPath: canonical.path))
        }
    }

    @Test("Successful import returns immediately usable mutation authority")
    func importedAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TemplateStorageService(directoryURL: root)
        try storage.save(MetadataTemplate(name: "Existing"))
        let imported = MetadataTemplate(name: "Imported")
        let importer = TemplateImportCommitService(storage: storage)
        guard case .committed(let commit) = try await importer.commit(
            TemplateBundle(templates: [imported]), sourceURL: root.appendingPathComponent("source.templatebundle"),
            requestID: UUID()
        ) else { Issue.record("Import failed"); return }
        #expect(commit.inventoryWasRead)
        let authority = try #require(commit.authorities[imported.id])
        #expect(authority.bytes == (try Data(contentsOf: root.appendingPathComponent("\(imported.id.uuidString).json"))))
        var edited = imported
        edited.name = "Edited immediately after import"
        let service = TemplateCRUDService(access: .storage(storage))
        guard case .committed(let saved) = try await service.save(
            edited, expectedExisting: imported, expectedDirectoryURL: commit.directoryURL,
            expectedAuthority: authority, requestID: UUID()
        ) else { Issue.record("Imported authority was not usable"); return }
        #expect(saved.requestedTemplateCommitted)
        #expect(try storage.loadAll().contains(edited))
    }

    @Test("Partial import failure never grants authority to a derived inventory")
    func failedImportAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TemplateStorageService(directoryURL: root)
        let protected = MetadataTemplate(name: "Protected")
        try storage.save(protected)
        let protectedFile = root.appendingPathComponent("\(protected.id.uuidString).json")
        let unreadable = Data("invalid JSON".utf8)
        try unreadable.write(to: protectedFile)
        let added = MetadataTemplate(name: "Added before failure")
        let importer = TemplateImportCommitService(storage: storage)
        do {
            _ = try await importer.commit(
                TemplateBundle(templates: [added, protected]),
                sourceURL: root.appendingPathComponent("source.templatebundle"), requestID: UUID()
            )
            Issue.record("Corrupt overwrite unexpectedly succeeded")
        } catch let error as TemplateImportCommitError {
            #expect(error.committedTemplateIDs == [added.id])
            #expect(error.refreshedTemplates.contains(added))
            #expect(!error.inventoryWasRead)
            #expect(error.authorities.isEmpty)
        }
        #expect(try Data(contentsOf: protectedFile) == unreadable)
        #expect(try storage.loadAll().contains(added))
    }

    @Test("Occupied unreadable or mismatched targets refuse before shortcut mutations",
          arguments: ["corrupt", "mismatched", "uppercase"])
    func occupiedTargetPreflight(state: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TemplateStorageService(directoryURL: root)
        let peer = MetadataTemplate(name: "Shortcut peer", shortcutSlot: 2)
        try storage.save(peer)
        let requested = MetadataTemplate(name: "Requested", shortcutSlot: 2)
        let suffix = state == "uppercase" ? "JSON" : "json"
        let targetFile = root.appendingPathComponent("\(requested.id.uuidString).\(suffix)")
        let peerFile = root.appendingPathComponent("\(peer.id.uuidString).json")
        let targetBytes: Data
        if state == "corrupt" || state == "uppercase" {
            targetBytes = Data("not JSON".utf8)
        } else {
            targetBytes = try JSONEncoder().encode(MetadataTemplate(name: "Different identity"))
        }
        try targetBytes.write(to: targetFile)
        let peerBytes = try Data(contentsOf: peerFile)
        let service = TemplateCRUDService(access: .storage(storage))
        do {
            _ = try await service.save(requested, requestID: UUID())
            Issue.record("Occupied target was treated as a creation")
        } catch let error as TemplateMutationError<MetadataTemplate> {
            #expect(error.isSnapshotConflict)
            #expect(error.durableTemplateIDs.isEmpty)
        }
        #expect(try Data(contentsOf: targetFile) == targetBytes)
        #expect(try Data(contentsOf: peerFile) == peerBytes)
    }

}
