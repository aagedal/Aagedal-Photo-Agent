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

extension TemplateFileAuthorityTests {
    @Test("Import refuses stale preview before any write",
          arguments: ["bytes", "new", "removed", "directory", "root", "malformed", "duplicate"])
    func importPreviewConflict(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathExtension("bundle")
        let oldRoot = root.appendingPathExtension("old")
        let otherRoot = root.appendingPathExtension("other")
        defer {
            for url in [root, source, oldRoot, otherRoot] { try? FileManager.default.removeItem(at: url) }
        }
        let original = MetadataTemplate(name: "Original")
        let added = MetadataTemplate(name: "New")
        var replacement = original
        replacement.name = "Replacement"
        let storage = TemplateStorageService(directoryURL: root)
        try storage.save(original)
        let bundle = TemplateBundle(templates: [added, replacement])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bundle).write(to: source)
        let originalURL = root.appendingPathComponent("\(original.id.uuidString).json")
        if change == "malformed" {
            try Data("invalid".utf8).write(to: root.appendingPathComponent("\(added.id.uuidString).json"))
        }
        if change == "duplicate" {
            try Data(contentsOf: originalURL).write(to: root.appendingPathComponent("duplicate.json"))
        }
        guard case .prepared(let completion) = try await TemplateImportPreviewService(storage: storage)
            .preparePreview(from: source, requestID: UUID()) else {
            Issue.record("Missing preview"); return
        }
        var target = storage
        switch change {
        case "bytes":
            var bytes = try Data(contentsOf: originalURL)
            bytes.append(10)
            try bytes.write(to: originalURL)
        case "new": try storage.save(added)
        case "removed": try FileManager.default.removeItem(at: originalURL)
        case "directory":
            try FileManager.default.moveItem(at: root, to: oldRoot)
            try FileManager.default.copyItem(at: oldRoot, to: root)
        case "root":
            target = TemplateStorageService(directoryURL: otherRoot)
            try target.save(original)
        default: break
        }
        let before = try TemplateImportAuthority.read(at: change == "root" ? otherRoot : root)
        do {
            _ = try await TemplateImportCommitService(storage: target).commit(completion.preview, requestID: UUID())
            Issue.record("Stale or ambiguous preview was imported")
        } catch is TemplateImportSnapshotConflict {
            // Expected: the complete import is refused before its first (new) target is written.
        }
        #expect(try TemplateImportAuthority.read(at: before.directoryURL) == before)
    }

    @Test("Import applies captured bundle and handles repeated UUIDs with fresh durable evidence")
    func acceptedImportPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathExtension("bundle")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        let storage = TemplateStorageService(directoryURL: root)
        let original = MetadataTemplate(name: "Original")
        try storage.save(original)
        var first = original
        first.name = "First"
        var last = original
        last.name = "Last"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TemplateBundle(templates: [first, last])).write(to: source)
        let preview = try storage.previewImport(from: source)
        // The accepted bundle is the immutable decoded preview, not a later source read.
        try Data("changed source".utf8).write(to: source)
        guard case .committed(let commit) = try await TemplateImportCommitService(storage: storage)
            .commit(preview, requestID: UUID()) else {
            Issue.record("Accepted import was not committed"); return
        }
        #expect(commit.overwrittenCount == 2)
        #expect(commit.committedTemplateIDs == [original.id, original.id])
        #expect(commit.refreshedTemplates == [last])
        #expect(commit.inventoryWasRead)
        #expect(try commit.authorities[original.id]?.bytes == Data(contentsOf:
            root.appendingPathComponent("\(original.id.uuidString).json")))
    }
}

extension TemplateFileAuthorityTests {
    @Test("Import stops after a durable save when a remaining or repeated target changes", arguments: [false, true])
    func importPeerChangesBetweenWrites(repeated: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathExtension("bundle")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        let storage = TemplateStorageService(directoryURL: root)
        let original = MetadataTemplate(name: "Original")
        var added = MetadataTemplate(name: "Added")
        if repeated { added.id = original.id }
        try storage.save(original)
        var replacement = original
        replacement.name = "Replacement"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TemplateBundle(templates: [added, replacement])).write(to: source)
        let preview = try storage.previewImport(from: source)
        let originalURL = root.appendingPathComponent("\(original.id.uuidString).json")
        var peerBytes = try Data(contentsOf: originalURL)
        peerBytes.append(10)
        let expectedPeerBytes = peerBytes
        let firstID = added.id
        var access = TemplateImportCommitAccess(
            loadAll: { try storage.loadAll() }, save: { try storage.save($0) }
        )
        access.saveReturningBytes = { template in
            let written = try storage.saveReturningBytes(template)
            if template.id == firstID { try expectedPeerBytes.write(to: originalURL) }
            return written
        }
        // Production transaction admission resolves /var and other symlink aliases.
        // This injected worker must use the same canonical root as its preview.
        let canonicalRoot = try #require(preview.authority).directoryURL
        let service = TemplateImportCommitService(access: access, transactionDirectoryURL: canonicalRoot)
        do {
            _ = try await service.commit(preview, requestID: UUID())
            Issue.record("Import overwrote the changed remaining target")
        } catch let error as TemplateImportCommitError {
            #expect(error.committedTemplateIDs == [added.id])
            #expect(error.addedCount == (repeated ? 0 : 1))
            #expect(error.overwrittenCount == (repeated ? 1 : 0))
            #expect(!error.inventoryWasRead)
            #expect(error.authorities.isEmpty)
        }
        #expect(try Data(contentsOf: originalURL) == expectedPeerBytes)
        if !repeated { #expect(try storage.loadAll().contains(added)) }
    }
}
