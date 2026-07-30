import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Atomic JSON document store")
struct AtomicJSONDocumentStoreTests {
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
