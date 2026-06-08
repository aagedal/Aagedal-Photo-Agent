import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("KeywordListsArchive")
struct KeywordListsArchiveTests {

    /// Runs `body` with the shared store pointed at a fresh, empty temp root.
    ///
    /// The store is a process-wide singleton that several suites write to, and
    /// Swift Testing runs suites in parallel — so without isolation another
    /// suite's quick-list writes leak into the shared root and inflate the
    /// archive's file count (the historical `exported → 5` flake). The override
    /// is task-local, so this isolation holds even while sibling suites write to
    /// the default root concurrently.
    private func withIsolatedStore(_ body: () throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-archive-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try KeywordListsStoreStorageOverride.$current.withValue(root) {
            try body()
        }
    }

    private func tempZip() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-archive-\(UUID().uuidString).zip")
    }

    @Test("Export then import round-trips all list types and preserves entry order")
    func roundTripAllTypes() throws {
        try withIsolatedStore {
            let store = KeywordListsStore.shared
            try store.writeEntries(["Berlin", "Paris", "London"], to: .quick(.keywords))
            try store.writeEntries(["Alice", "Bob"], to: .quick(.personShown))
            try store.writeEntries(["Approved-A", "Approved-B"], to: .approved(.keywords))
            try store.writeText("animals\n\tlivestock\n", to: .structured)

            let zipURL = tempZip()
            defer { try? FileManager.default.removeItem(at: zipURL) }
            let exported = try KeywordListsArchive.exportAll(to: zipURL)
            #expect(exported == 4)

            // Wipe the store and re-import.
            for type in QuickListType.allCases { store.delete(.quick(type)) }
            for field in ApprovedListField.allCases { store.delete(.approved(field)) }
            store.delete(.structured)
            #expect(store.readEntries(.quick(.keywords)) == [])

            let imported = try KeywordListsArchive.importAll(from: zipURL, mode: .replace)
            #expect(imported == 4)

            #expect(store.readEntries(.quick(.keywords)) == ["Berlin", "Paris", "London"])
            #expect(store.readEntries(.quick(.personShown)) == ["Alice", "Bob"])
            #expect(store.readEntries(.approved(.keywords)) == ["Approved-A", "Approved-B"])
            #expect(store.readText(.structured)?.contains("animals") == true)
        }
    }

    @Test("Import in .merge mode appends new entries without disturbing existing order")
    func mergeMode() throws {
        try withIsolatedStore {
            let store = KeywordListsStore.shared
            try store.writeEntries(["Existing-1", "Existing-2"], to: .quick(.copyright))

            // Build an archive that has a different copyright list.
            try store.writeEntries(["New-1", "Existing-1", "New-2"], to: .quick(.copyright))
            let zipURL = tempZip()
            defer { try? FileManager.default.removeItem(at: zipURL) }
            try KeywordListsArchive.exportAll(to: zipURL)

            // Restore the original store state, then merge-import.
            try store.writeEntries(["Existing-1", "Existing-2"], to: .quick(.copyright))
            try KeywordListsArchive.importAll(from: zipURL, mode: .merge)

            let merged = store.readEntries(.quick(.copyright))
            // Existing order preserved at the front, new entries appended.
            #expect(merged == ["Existing-1", "Existing-2", "New-1", "New-2"])
        }
    }

    @Test("Importing a zip without a manifest throws an actionable error")
    func missingManifestThrows() throws {
        // Build a zip that has the right shape but no manifest.json.
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-bogus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        try "abc\n".write(
            to: stagingRoot.appendingPathComponent("random.txt"),
            atomically: true,
            encoding: .utf8
        )
        let zipURL = tempZip()
        defer { try? FileManager.default.removeItem(at: zipURL) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", stagingRoot.path, zipURL.path]
        try p.run()
        p.waitUntilExit()

        #expect(throws: KeywordListsArchive.ArchiveError.self) {
            try KeywordListsArchive.importAll(from: zipURL, mode: .replace)
        }
    }
}
