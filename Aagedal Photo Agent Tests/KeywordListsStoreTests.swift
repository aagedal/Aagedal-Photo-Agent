import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("KeywordListsStore")
struct KeywordListsStoreTests {

    private func clearAllStoreFiles() {
        let store = KeywordListsStore.shared
        for type in QuickListType.allCases {
            store.delete(.quick(type))
        }
        for field in ApprovedListField.allCases {
            store.delete(.approved(field))
        }
        store.delete(.structured)
    }

    @Test("writeEntries dedupes, trims, and round-trips through readEntries")
    func writeEntriesRoundTrip() throws {
        clearAllStoreFiles()
        let key = KeywordListKey.quick(.keywords)
        try KeywordListsStore.shared.writeEntries(
            ["  Berlin  ", "Paris", "", "Berlin", "London"],
            to: key
        )
        let entries = KeywordListsStore.shared.readEntries(key)
        #expect(entries == ["Berlin", "Paris", "London"])
    }

    @Test("writeText preserves the exact text including tabs and braces")
    func writeTextPreservesVerbatim() throws {
        clearAllStoreFiles()
        let text = "animals\n\tlivestock\n\t\t{cattle}\n\t[REPTILE]\n\t\talligator\n"
        try KeywordListsStore.shared.writeText(text, to: .structured)
        #expect(KeywordListsStore.shared.readText(.structured) == text)
    }

    @Test("exists reflects writes and deletes")
    func existsContract() throws {
        clearAllStoreFiles()
        let key = KeywordListKey.approved(.keywords)
        #expect(!KeywordListsStore.shared.exists(key))
        try KeywordListsStore.shared.writeEntries(["a"], to: key)
        #expect(KeywordListsStore.shared.exists(key))
        KeywordListsStore.shared.delete(key)
        #expect(!KeywordListsStore.shared.exists(key))
    }

    @Test("readEntries returns empty array when file is missing")
    func readEntriesMissingFile() {
        clearAllStoreFiles()
        #expect(KeywordListsStore.shared.readEntries(.quick(.event)) == [])
    }

    @Test("importEntries from a temp file writes through to the store")
    func importEntriesRoundTrip() throws {
        clearAllStoreFiles()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-test-\(UUID().uuidString).txt")
        try "Alice\nBob\nCharlie\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let entries = try KeywordListsStore.shared.importEntries(from: url, into: .quick(.personShown))
        #expect(entries == ["Alice", "Bob", "Charlie"])
        #expect(KeywordListsStore.shared.readEntries(.quick(.personShown)) == ["Alice", "Bob", "Charlie"])
    }

    @Test("Write posts a keywordListChanged notification carrying the key")
    func notificationOnWrite() async throws {
        clearAllStoreFiles()
        let key = KeywordListKey.quick(.credit)

        // Tests run in parallel and the observer listens with `object: nil`, so it
        // can receive `.keywordListChanged` posts triggered by *other* suites. Filter
        // to our own key and resume exactly once — otherwise a second matching post
        // resumes the continuation twice (SWIFT TASK CONTINUATION MISUSE → crash).
        nonisolated final class Box: @unchecked Sendable {
            var token: NSObjectProtocol?
            var resumed = false
        }
        let box = Box()

        // Set up a one-shot wait for the notification before triggering the write.
        let observed = await withCheckedContinuation { (continuation: CheckedContinuation<KeywordListKey?, Never>) in
            box.token = NotificationCenter.default.addObserver(
                forName: .keywordListChanged,
                object: nil,
                queue: .main  // callbacks serialize here, so the `resumed` guard is race-free
            ) { note in
                let observed = note.userInfo?[KeywordListsStore.changedKeyUserInfo] as? KeywordListKey
                guard observed == key, !box.resumed else { return }
                box.resumed = true
                if let token = box.token {
                    NotificationCenter.default.removeObserver(token)
                }
                continuation.resume(returning: observed)
            }
            DispatchQueue.main.async {
                try? KeywordListsStore.shared.writeEntries(["Acme"], to: key)
            }
        }
        #expect(observed == key)
    }
}
