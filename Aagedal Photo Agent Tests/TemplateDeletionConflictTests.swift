import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Template deletion snapshot conflicts")
struct TemplateDeletionConflictTests {
    @Test("Metadata deletion protects newer and ambiguous records",
          arguments: ["changed", "removed", "corrupt", "duplicate", "unchanged"])
    func metadataDeletion(state: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = DeletionTrashProbe()
        let storage = TemplateStorageService(directoryURL: root, trashAccess: trash.access)
        let original = MetadataTemplate(name: "Selected", shortcutSlot: 1)
        var changed = original
        changed.name = "Newer edit"
        let peer = MetadataTemplate(name: "Other shortcut", shortcutSlot: 2)
        try storage.save(original)
        try storage.save(peer)
        try await checkDeletion(
            state: state, root: root, original: original, changed: changed, peer: peer,
            access: .storage(storage), trash: trash
        )
    }

    @Test("Develop deletion protects newer and ambiguous records",
          arguments: ["changed", "removed", "corrupt", "duplicate", "unchanged"])
    func developDeletion(state: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = DeletionTrashProbe()
        let storage = DevelopTemplateStorageService(directoryURL: root, trashAccess: trash.access)
        let original = DevelopTemplate(name: "Selected", shortcutSlot: 1)
        var changed = original
        changed.name = "Newer edit"
        let peer = DevelopTemplate(name: "Other shortcut", shortcutSlot: 2)
        try storage.save(original)
        try storage.save(peer)
        try await checkDeletion(
            state: state, root: root, original: original, changed: changed, peer: peer,
            access: .storage(storage), trash: trash
        )
    }

    private func checkDeletion<Value: Identifiable & Sendable & Equatable & Encodable>(
        state: String, root: URL, original: Value, changed: Value, peer: Value,
        access: TemplateCRUDAccess<Value>, trash: DeletionTrashProbe
    ) async throws where Value.ID == UUID {
        let source = root.appendingPathComponent("\(original.id.uuidString).json")
        let duplicate = root.appendingPathComponent("duplicate.json")
        let peerURL = root.appendingPathComponent("\(peer.id.uuidString).json")
        let peerBytes = try Data(contentsOf: peerURL)
        let service = TemplateCRUDService(access: access)
        guard case .loaded(let loaded) = try await service.load(requestID: UUID()) else {
            Issue.record("Expected original inventory"); return
        }
        let authority = try #require(loaded.authorities[original.id])
        switch state {
        case "changed": try JSONEncoder().encode(changed).write(to: source)
        case "removed": try FileManager.default.removeItem(at: source)
        case "corrupt": try Data("broken JSON".utf8).write(to: source)
        case "duplicate": try Data(contentsOf: source).write(to: duplicate)
        default: break
        }
        let before = try? Data(contentsOf: source)
        let duplicateBefore = try? Data(contentsOf: duplicate)
        let requestID = UUID()
        do {
            let result = try await service.delete(original, expectedAuthority: authority, requestID: requestID)
            guard state == "unchanged", case .committed(let commit) = result else {
                Issue.record("Stale selection was allowed to delete")
                return
            }
            #expect(commit.requestID == requestID)
            #expect(commit.requestedTemplateCommitted)
            #expect(commit.durableTemplateIDs == [original.id])
            #expect(commit.refreshedTemplates == [peer])
            #expect(trash.count == 1)
            #expect(!FileManager.default.fileExists(atPath: source.path))
        } catch let error as TemplateMutationError<Value> {
            #expect(state != "unchanged")
            #expect(error.requestID == requestID)
            #expect(error.isSnapshotConflict)
            #expect(error.durableTemplateIDs.isEmpty)
            #expect(error.refreshedTemplates == (try access.loadAll()))
            #expect(error.reason.contains("changed or is no longer available"))
            #expect(trash.count == 0)
            #expect((try? Data(contentsOf: source)) == before)
            #expect((try? Data(contentsOf: duplicate)) == duplicateBefore)

            // Retrying the original selection cannot silently adopt the new snapshot.
            do {
                _ = try await service.delete(original, expectedAuthority: authority, requestID: UUID())
                Issue.record("Retry authorized stale deletion")
            } catch let retry as TemplateMutationError<Value> {
                #expect(retry.isSnapshotConflict)
            }
            #expect(trash.count == 0)
            #expect((try? Data(contentsOf: source)) == before)

            // A deliberate fresh selection can delete a peer's newer version.
            if state == "changed" {
                let refreshedAuthority = try #require(error.authorities[changed.id])
                guard case .committed(let commit) = try await service.delete(changed, expectedAuthority: refreshedAuthority, requestID: UUID()) else {
                    Issue.record("Fresh selection was refused")
                    return
                }
                #expect(commit.durableTemplateIDs == [original.id])
                #expect(trash.count == 1)
            }
        }
        #expect(try Data(contentsOf: peerURL) == peerBytes)
    }
}

@Suite("Template deletion markers")
struct TemplateTombstoneTests {
    /// A deletion later than the file hides it; saving the template again clears the marker.
    @Test("A deletion marker hides an older metadata template copy until it is saved again")
    func metadataTombstone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TemplateStorageService(directoryURL: root, trashAccess: DeletionTrashProbe().access)
        let deleted = MetadataTemplate(name: "Deleted on another Mac")
        let kept = MetadataTemplate(name: "Kept")
        try storage.save(deleted)
        try storage.save(kept)

        try storage.delete(deleted)
        #expect(FileManager.default.fileExists(atPath: TemplateTombstone.url(for: deleted.id, in: root).path))
        // A copy older than the deletion (the marker is dated after the file was written).
        try storage.save(deleted)
        try TemplateTombstone.write(for: deleted.id, in: root, at: Date().addingTimeInterval(60))

        #expect(try storage.loadAll().map(\.id) == [kept.id])
        let inventory = try TemplateFileInventory<MetadataTemplate>.read(at: root) { $0 }
        #expect(inventory.templates.map(\.id) == [kept.id])
        #expect(inventory.occupiedFileIDs.contains(deleted.id))

        try storage.save(deleted)
        #expect(!FileManager.default.fileExists(atPath: TemplateTombstone.url(for: deleted.id, in: root).path))
        #expect(Set(try storage.loadAll().map(\.id)) == [deleted.id, kept.id])
    }

    @Test("A deletion marker hides an older Develop template copy")
    func developTombstone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DevelopTemplateStorageService(directoryURL: root, trashAccess: DeletionTrashProbe().access)
        let deleted = DevelopTemplate(name: "Deleted")
        try storage.save(deleted)
        try TemplateTombstone.write(for: deleted.id, in: root, at: Date().addingTimeInterval(60))
        #expect(try storage.loadAll().isEmpty)
        try storage.save(deleted)
        #expect(try storage.loadAll().map(\.id) == [deleted.id])
    }

    /// Re-enabling sync merges this Mac's folder into iCloud (and the reverse on disable).
    @Test("The sync merge neither resurrects a deleted template nor keeps one deleted elsewhere")
    func mergeHonorsDeletions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local", isDirectory: true)
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        let localStorage = TemplateStorageService(directoryURL: local, trashAccess: DeletionTrashProbe().access)
        let cloudStorage = TemplateStorageService(directoryURL: cloud, trashAccess: DeletionTrashProbe().access)
        let deletedInCloud = MetadataTemplate(name: "Deleted on another Mac")
        let deletedHere = MetadataTemplate(name: "Deleted while sync was off")
        let kept = MetadataTemplate(name: "Kept")
        try localStorage.save(deletedInCloud)
        try localStorage.save(kept)
        try cloudStorage.save(deletedHere)
        let later = Date().addingTimeInterval(60)
        try TemplateTombstone.write(for: deletedInCloud.id, in: cloud, at: later)
        try TemplateTombstone.write(for: deletedHere.id, in: local, at: later)

        try TemplateTombstone.mergeCopyHonoringDeletions(from: local, to: cloud)

        #expect(try cloudStorage.loadAll().map(\.id) == [kept.id])
        let file = { (id: UUID) in cloud.appendingPathComponent("\(id.uuidString).json").path }
        #expect(!FileManager.default.fileExists(atPath: file(deletedInCloud.id)))
        #expect(!FileManager.default.fileExists(atPath: file(deletedHere.id)))
        #expect(FileManager.default.fileExists(atPath: TemplateTombstone.url(for: deletedHere.id, in: cloud).path))
    }
}

nonisolated private final class DeletionTrashProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }
    var access: TemplateTrashAccess {
        TemplateTrashAccess(moveItem: { [self] url in
            lock.withLock { calls += 1 }
            // Tests avoid Finder's Trash; successful admission is recorded before removal.
            try FileManager.default.removeItem(at: url)
        })
    }
}
