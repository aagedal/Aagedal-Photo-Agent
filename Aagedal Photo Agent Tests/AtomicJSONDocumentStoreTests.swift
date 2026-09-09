import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Atomic JSON document store")
struct AtomicJSONDocumentStoreTests {
    @Test("Separate aliased stores serialize absent primary/backup transactions and retain captured paths",
          arguments: [false, true])
    @MainActor
    func sharedTransactionAdmission(cancelQueuedSave: Bool) async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let actual = fixture.directoryURL.appendingPathComponent("actual")
        let redirected = fixture.directoryURL.appendingPathComponent("redirected")
        let alias = fixture.directoryURL.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let documentURL = actual.appendingPathComponent("missing/record.json")
        let canonicalDocument = SafePathComponent.resolvingExistingSymlinks(in: documentURL)
        let barrier = AtomicJSONAdmissionBarrier()
        let first = AtomicJSONDocumentStore<TestDocument>(
            documentURL: documentURL,
            validateCompatibility: { _ in barrier.pauseOnce() }
        )
        let second = AtomicJSONDocumentStore<TestDocument>(
            documentURL: alias.appendingPathComponent("missing/record.json")
        )
        let firstTask = Task { try await first.save(TestDocument(value: "first")) }
        defer { barrier.release() }
        try await barrier.waitUntilEntered()
        let secondTask = Task { try await second.save(TestDocument(value: "second")) }
        let deadline = ContinuousClock.now + .seconds(10)
        while await StorageTransactionAdmission.shared.waiterCount(for: canonicalDocument) != 1 {
            guard ContinuousClock.now < deadline else {
                Issue.record("The aliased save did not wait for ownership of the absent document")
                barrier.release()
                _ = try? await firstTask.value
                _ = try? await secondTask.value
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        if cancelQueuedSave { secondTask.cancel() }
        // A distinct document can finish while both jobs for the first document are pending.
        let independent = AtomicJSONDocumentStore<TestDocument>(documentURL: fixture.documentURL)
        try await independent.save(TestDocument(value: "independent"))
        #expect(try fixture.decode(at: fixture.documentURL).value == "independent")
        // Admission captures the resolved destination, even if its alias is retargeted while queued.
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: redirected)
        barrier.release()
        try await firstTask.value
        try await secondTask.value
        #expect(try fixture.decode(at: documentURL).value == "second")
        #expect(try fixture.decode(at: documentURL.appendingPathExtension("backup")).value == "first")
        #expect(!FileManager.default.fileExists(atPath: redirected.appendingPathComponent("missing").path))
    }

    @Test("Primary/backup overlap across document types cannot overwrite a newly committed future schema")
    @MainActor
    func overlappingBackupAcrossDocumentTypes() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let barrier = AtomicJSONAdmissionBarrier()
        let future = AtomicJSONDocumentStore<VersionTwoDocument>(
            documentURL: fixture.backupURL,
            validateCompatibility: { _ in barrier.pauseOnce() }
        )
        let current = AtomicJSONDocumentStore<TestDocument>(documentURL: fixture.documentURL)
        let futureTask = Task { try await future.save(VersionTwoDocument(value: "future backup")) }
        defer { barrier.release() }
        try await barrier.waitUntilEntered()
        let currentTask = Task { try await current.save(TestDocument(value: "must not install")) }
        let key = SafePathComponent.resolvingExistingSymlinks(in: fixture.backupURL)
        let deadline = ContinuousClock.now + .seconds(10)
        while await StorageTransactionAdmission.shared.waiterCount(for: key) != 1 {
            guard ContinuousClock.now < deadline else {
                Issue.record("Overlapping primary and backup paths were not serialized")
                barrier.release()
                _ = try? await futureTask.value
                _ = try? await currentTask.value
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        barrier.release()
        try await futureTask.value
        await #expect(throws: AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(found: 2, supported: 1)) {
            try await currentTask.value
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.documentURL.path))
        let saved = try JSONDecoder().decode(VersionTwoDocument.self, from: Data(contentsOf: fixture.backupURL))
        #expect(saved.value == "future backup")
        // Failure releases ownership so another read can recover the intact future backup.
        guard case .newerSchema(2, _, .backup) = try await current.load() else {
            Issue.record("Expected the preserved future backup after a rejected save")
            return
        }
    }

    @Test("Atomic replacement retains task context and completes admitted saves after cancellation",
          arguments: [false, true])
    @MainActor
    func dispatchTransactionContext(cancelDuringSave: Bool) async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let queue = DispatchSerialQueue(label: "test.atomic-json.transaction")
        let root = fixture.directoryURL
        let initialStore = AtomicJSONDocumentStore<TestDocument>(documentURL: fixture.documentURL)
        try await initialStore.save(TestDocument(value: "previous"))
        let store = AtomicJSONDocumentStore<TestDocument>(
            documentURL: fixture.documentURL, filesystemQueue: queue,
            validateCompatibility: { _ in
                #expect(!Thread.isMainThread)
                #expect(queue.isIsolatingCurrentContext() == true)
                #expect(AtomicJSONExecutorContext.marker == root)
                #expect(Task.currentPriority >= .userInitiated)
                if cancelDuringSave { withUnsafeCurrentTask { $0?.cancel() } }
            }
        )
        try await Task(priority: .userInitiated) {
            try await AtomicJSONExecutorContext.$marker.withValue(root) {
                try await store.save(TestDocument(value: "replacement"))
                #expect(Task.isCancelled == cancelDuringSave)
                guard case .document(let loaded, .primary) = try await store.load() else {
                    Issue.record("Expected the committed primary")
                    return
                }
                #expect(loaded.value == "replacement")
            }
        }.value
        #expect(try fixture.decode(at: fixture.documentURL).value == "replacement")
        #expect(try fixture.decode(at: fixture.backupURL).value == "previous")
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries.sorted() == ["case.json", "case.json.backup"])
    }

    @Test("direct saves preserve a future-only backup", arguments: [false, true], [false, true])
    func futureBackupBlocksDirectSave(corruptPrimary: Bool, nestedFuture: Bool) async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let future = Data((nestedFuture
            ? #"{"schemaVersion":1,"value":"future"}"#
            : #"{"schemaVersion":2,"value":"future"}"#).utf8)
        try future.write(to: fixture.backupURL)
        if corruptPrimary { try Data("{".utf8).write(to: fixture.documentURL) }
        let store = AtomicJSONDocumentStore<TestDocument>(
            documentURL: fixture.documentURL,
            validateCompatibility: { data in
                if nestedFuture && data == future { throw CompatibilityFailure.futureVersion }
            }
        )
        do {
            try await store.save(TestDocument(value: "replacement"))
            Issue.record("A direct save accepted a future-only backup")
        } catch {
            if nestedFuture {
                #expect(error as? CompatibilityFailure == .futureVersion)
            } else {
                #expect(error as? AtomicJSONDocumentStoreError == .newerSchemaRequiresReadOnly(found: 2, supported: 1))
            }
        }
        #expect(try Data(contentsOf: fixture.backupURL) == future)
        if corruptPrimary {
            #expect(try Data(contentsOf: fixture.documentURL) == Data("{".utf8))
        } else {
            #expect(!FileManager.default.fileExists(atPath: fixture.documentURL.path))
        }
    }

    @Test("compatibility guards reject future nested bytes without falling back or overwriting")
    func compatibilityGuardPreservesFutureBytes() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = AtomicJSONDocumentStore<TestDocument>(
            documentURL: fixture.documentURL,
            validateCompatibility: { data in
                #expect(!Thread.isMainThread)
                if String(decoding: data, as: UTF8.self).contains("future") {
                    throw CompatibilityFailure.futureVersion
                }
            }
        )
        try await store.save(TestDocument(value: "backup"))
        try await store.save(TestDocument(value: "primary"))
        let backup = try Data(contentsOf: fixture.backupURL)
        let future = Data(#"{"schemaVersion":1,"value":"future","unknown":true}"#.utf8)
        try future.write(to: fixture.documentURL)
        await #expect(throws: CompatibilityFailure.futureVersion) {
            _ = try await store.load()
        }
        await #expect(throws: CompatibilityFailure.futureVersion) {
            try await store.save(TestDocument(value: "replacement"))
        }
        #expect(try Data(contentsOf: fixture.documentURL) == future)
        #expect(try Data(contentsOf: fixture.backupURL) == backup)
    }

    @Test("backup compatibility errors remain explicit when the primary is corrupt")
    func backupCompatibilityGuard() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try Data("{".utf8).write(to: fixture.documentURL)
        let future = Data(#"{"schemaVersion":1,"value":"future"}"#.utf8)
        try future.write(to: fixture.backupURL)
        let store = AtomicJSONDocumentStore<TestDocument>(
            documentURL: fixture.documentURL,
            validateCompatibility: { data in
                if data == future { throw CompatibilityFailure.futureVersion }
            }
        )
        await #expect(throws: CompatibilityFailure.futureVersion) {
            _ = try await store.load()
        }
        #expect(try Data(contentsOf: fixture.backupURL) == future)
    }

    @Test("save writes a validated document that can be loaded")
    func saveAndLoad() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = AtomicJSONDocumentStore<TestDocument>(documentURL: fixture.documentURL)
        let document = TestDocument(value: "first")

        try await store.save(document)
        let result = try await store.load()

        guard case .document(let loaded, let source) = result else {
            Issue.record("Expected a writable document")
            return
        }
        #expect(loaded == document)
        #expect(source == .primary)
        #expect(!FileManager.default.fileExists(atPath: fixture.backupURL.path))
    }

    @Test("each replacement keeps exactly the previous valid primary as backup")
    func boundedBackup() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = AtomicJSONDocumentStore<TestDocument>(documentURL: fixture.documentURL)

        try await store.save(TestDocument(value: "one"))
        try await store.save(TestDocument(value: "two"))
        #expect(try fixture.decode(at: fixture.backupURL).value == "one")

        try await store.save(TestDocument(value: "three"))
        #expect(try fixture.decode(at: fixture.documentURL).value == "three")
        #expect(try fixture.decode(at: fixture.backupURL).value == "two")

        let siblings = try FileManager.default.contentsOfDirectory(
            at: fixture.directoryURL,
            includingPropertiesForKeys: nil
        )
        #expect(siblings.filter { $0.lastPathComponent.contains("staging-") }.isEmpty)
    }

    @Test("a corrupt primary recovers the last valid backup without rewriting either file")
    func backupRecovery() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = AtomicJSONDocumentStore<TestDocument>(documentURL: fixture.documentURL)
        try await store.save(TestDocument(value: "recover me"))
        try await store.save(TestDocument(value: "new primary"))
        let backupBeforeLoad = try Data(contentsOf: fixture.backupURL)
        try Data("{".utf8).write(to: fixture.documentURL)

        let result = try await store.load()

        guard case .document(let recovered, let source) = result else {
            Issue.record("Expected backup recovery")
            return
        }
        #expect(recovered.value == "recover me")
        #expect(source == .backup)
        #expect(try Data(contentsOf: fixture.documentURL) == Data("{".utf8))
        #expect(try Data(contentsOf: fixture.backupURL) == backupBeforeLoad)
    }

    @Test("a failed validation cannot replace the primary or its backup")
    func validationFailurePreservesFiles() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = AtomicJSONDocumentStore<TestDocument>(documentURL: fixture.documentURL)
        try await store.save(TestDocument(value: "one"))
        try await store.save(TestDocument(value: "two"))
        let primaryBefore = try Data(contentsOf: fixture.documentURL)
        let backupBefore = try Data(contentsOf: fixture.backupURL)

        await #expect(throws: TestDocument.ValidationError.emptyValue) {
            try await store.save(TestDocument(value: ""))
        }

        #expect(try Data(contentsOf: fixture.documentURL) == primaryBefore)
        #expect(try Data(contentsOf: fixture.backupURL) == backupBefore)
    }

    @Test("a newer schema is returned intact and blocks destructive downgrade")
    func newerSchemaIsReadOnly() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = AtomicJSONDocumentStore<TestDocument>(documentURL: fixture.documentURL)
        let newerData = Data(#"{"schemaVersion":2,"value":"future","unknown":{"kept":true}}"#.utf8)
        try newerData.write(to: fixture.documentURL)

        let result = try await store.load()
        guard case .newerSchema(let schemaVersion, let bytes, let source) = result else {
            Issue.record("Expected a read-only newer schema")
            return
        }
        #expect(schemaVersion == 2)
        #expect(bytes == newerData)
        #expect(source == .primary)

        await #expect(
            throws: AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
                found: 2,
                supported: 1
            )
        ) {
            try await store.save(TestDocument(value: "must not overwrite"))
        }
        #expect(try Data(contentsOf: fixture.documentURL) == newerData)
    }

    @Test("an older schema requires an explicit document migration")
    func oldSchemaRequiresMigration() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = AtomicJSONDocumentStore<VersionTwoDocument>(
            documentURL: fixture.documentURL
        )
        try Data(#"{"schemaVersion":1,"value":"old"}"#.utf8).write(to: fixture.documentURL)

        await #expect(
            throws: AtomicJSONDocumentStoreError.unsupportedOlderSchema(
                found: 1,
                supported: 2
            )
        ) {
            _ = try await store.load()
        }
    }

    @Test("saving a corrupt primary preserves the last known-good backup")
    func corruptPrimaryDoesNotDisplaceBackup() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = AtomicJSONDocumentStore<TestDocument>(documentURL: fixture.documentURL)
        try await store.save(TestDocument(value: "backup"))
        try await store.save(TestDocument(value: "primary"))
        let backupBefore = try Data(contentsOf: fixture.backupURL)
        try Data("not json".utf8).write(to: fixture.documentURL)

        try await store.save(TestDocument(value: "replacement"))

        #expect(try fixture.decode(at: fixture.documentURL).value == "replacement")
        #expect(try Data(contentsOf: fixture.backupURL) == backupBefore)
    }

    @Test("a read-only destination preserves the last valid document")
    func readOnlyDestinationPreservesPrimary() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = AtomicJSONDocumentStore<TestDocument>(documentURL: fixture.documentURL)
        try await store.save(TestDocument(value: "keep me"))
        let primaryBefore = try Data(contentsOf: fixture.documentURL)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: fixture.directoryURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.directoryURL.path
            )
        }

        await #expect(throws: CocoaError.self) {
            try await store.save(TestDocument(value: "must fail"))
        }

        #expect(try Data(contentsOf: fixture.documentURL) == primaryBefore)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: fixture.directoryURL,
            includingPropertiesForKeys: nil
        )
        #expect(siblings.filter { $0.lastPathComponent.contains("staging-") }.isEmpty)
    }
}

private nonisolated enum AtomicJSONExecutorContext {
    @TaskLocal static var marker: URL?
}

private struct TestDocument: VersionedJSONDocument, Equatable {
    enum ValidationError: Error, Equatable {
        case emptyValue
    }

    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var value: String

    func validateForPersistence() throws {
        if value.isEmpty {
            throw ValidationError.emptyValue
        }
    }
}

private struct VersionTwoDocument: VersionedJSONDocument {
    static let currentSchemaVersion = 2

    var schemaVersion = currentSchemaVersion
    var value: String
}

private struct StoreFixture {
    let directoryURL: URL
    let documentURL: URL
    let backupURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-atomic-json-\(UUID().uuidString)", isDirectory: true)
        documentURL = directoryURL.appendingPathComponent("case.json")
        backupURL = documentURL.appendingPathExtension("backup")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func decode(at url: URL) throws -> TestDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TestDocument.self, from: Data(contentsOf: url))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private enum CompatibilityFailure: Error, Equatable { case futureVersion }

nonisolated private final class AtomicJSONAdmissionBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private let semaphore = DispatchSemaphore(value: 0)

    func pauseOnce() {
        let shouldPause = lock.withLock {
            if entered { return false }
            entered = true
            return true
        }
        if shouldPause { #expect(semaphore.wait(timeout: .now() + 15) == .success) }
    }

    func release() { semaphore.signal() }

    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !lock.withLock({ entered }) {
            guard ContinuousClock.now < deadline else {
                throw CocoaError(.fileReadUnknown)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
