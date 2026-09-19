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
        let service = TemplateCRUDService(access: access)
        do {
            let result = try await service.delete(original, requestID: requestID)
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
            #expect(error.reason.contains("before deleting again"))
            #expect(trash.count == 0)
            #expect((try? Data(contentsOf: source)) == before)
            #expect((try? Data(contentsOf: duplicate)) == duplicateBefore)

            // Retrying the original selection cannot silently adopt the new snapshot.
            do {
                _ = try await service.delete(original, requestID: UUID())
                Issue.record("Retry authorized stale deletion")
            } catch let retry as TemplateMutationError<Value> {
                #expect(retry.isSnapshotConflict)
            }
            #expect(trash.count == 0)
            #expect((try? Data(contentsOf: source)) == before)

            // A deliberate fresh selection can delete a peer's newer version.
            if state == "changed" {
                guard case .committed(let commit) = try await service.delete(changed, requestID: UUID()) else {
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
