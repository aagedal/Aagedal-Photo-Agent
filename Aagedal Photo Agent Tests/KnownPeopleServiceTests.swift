import Testing
import Foundation
@testable import Aagedal_Photo_Agent

/// Tests for the per-person file store in `KnownPeopleService`.
///
/// The service is a `@MainActor` singleton, so the suite is `@MainActor` and
/// `.serialized` — each test points the singleton at a fresh temp directory via
/// the `storageOverrideURL` test seam and resets it afterward, so shared state
/// never leaks between tests.
@Suite("KnownPeopleService", .serialized)
@MainActor
struct KnownPeopleServiceTests {

    // MARK: - Fixtures

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnownPeopleTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Points the singleton at `dir` and drops all cached state so the next
    /// access reads from that directory.
    private func activate(_ dir: URL) {
        KnownPeopleService.deletionIO = .live
        KnownPeopleService.embeddingMigrationIO = .live
        KnownPeopleService.storageOverrideURL = dir
        KnownPeopleService.shared.reloadAfterStorageChange()
    }

    private func teardown(_ dir: URL) {
        KnownPeopleService.deletionIO = .live
        KnownPeopleService.embeddingMigrationIO = .live
        KnownPeopleService.storageOverrideURL = nil
        try? FileManager.default.removeItem(at: dir)
        // Reset the singleton's cache so the next test starts clean.
        KnownPeopleService.shared.reloadAfterStorageChange()
    }

    private func withIsolatedEmbeddingMigration(_ body: (URL) throws -> Void) rethrows {
        let key = UserDefaultsKeys.knownPeopleEmbeddingVersion
        let previous = UserDefaults.standard.object(forKey: key)
        let dir = makeTempDir()
        activate(dir)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            KnownPeopleService.embeddingMigrationIO = .live
            teardown(dir)
        }
        try body(dir)
    }

    private func embedding(_ byte: UInt8) -> PersonEmbedding {
        PersonEmbedding(featurePrintData: Data([byte, byte, byte]))
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    /// Writes a `KnownPerson` directly into `dir/people/<id>.json`, simulating a
    /// file that arrived from a peer device.
    private func writePersonFile(_ person: KnownPerson, into dir: URL) throws {
        let peopleDir = dir.appendingPathComponent("people", isDirectory: true)
        try FileManager.default.createDirectory(at: peopleDir, withIntermediateDirectories: true)
        let url = peopleDir.appendingPathComponent("\(person.id.uuidString).json")
        try encode(person).write(to: url, options: .atomic)
    }

    private func personFileURL(_ id: UUID, in dir: URL) -> URL {
        dir.appendingPathComponent("people/\(id.uuidString).json")
    }

    private func tombstoneURL(_ id: UUID, in dir: URL) -> URL {
        dir.appendingPathComponent("people/\(id.uuidString).deleted")
    }

    // MARK: - 1. Migration idempotency

    @Test("Legacy database.json migrates to per-person files, idempotently")
    func migrationIdempotency() throws {
        let dir = makeTempDir()
        defer { teardown(dir) }
        activate(dir)

        // Seed a legacy single-file database before any per-person files exist.
        let alice = KnownPerson(name: "Alice", embeddings: [embedding(1)])
        let bob = KnownPerson(name: "Bob", embeddings: [embedding(2)])
        let legacy = KnownPeopleDatabase(people: [alice, bob])
        let legacyURL = dir.appendingPathComponent("database.json")
        try encode(legacy).write(to: legacyURL, options: .atomic)

        // Trigger migration via a fresh load.
        KnownPeopleService.shared.reloadAfterStorageChange()

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(FileManager.default.fileExists(atPath: personFileURL(alice.id, in: dir).path))
        #expect(FileManager.default.fileExists(atPath: personFileURL(bob.id, in: dir).path))

        let people = KnownPeopleService.shared.getAllPeople()
        #expect(Set(people.map(\.name)) == ["Alice", "Bob"])

        // Running again must not duplicate or resurrect the legacy file.
        KnownPeopleService.shared.reloadAfterStorageChange()
        #expect(KnownPeopleService.shared.getAllPeople().count == 2)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test("Embedding migration verifies its backup before reset or version stamp")
    func embeddingMigrationRequiresVerifiedBackup() throws {
        try withIsolatedEmbeddingMigration { dir in
            let person = try KnownPeopleService.shared.addPerson(
                name: "Must Survive",
                embeddings: [embedding(3)]
            )
            UserDefaults.standard.set(
                FaceRecognitionDefaults.embeddingVersion - 1,
                forKey: UserDefaultsKeys.knownPeopleEmbeddingVersion
            )

            let backup = dir.deletingLastPathComponent()
                .appendingPathComponent("KnownPeople-Unverified-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: backup) }
            var io = KnownPeopleEmbeddingMigrationIO.live
            io.backupURL = { _, _, _, _ in backup }
            io.mergeCopy = { _, destination in
                try CloudCoordinatedIO.ensureDirectory(destination)
                // Deliberately omit the source files: read-back verification must fail.
            }
            KnownPeopleService.embeddingMigrationIO = io

            KnownPeopleService.shared.reloadAfterStorageChange()

            #expect(FileManager.default.fileExists(atPath: personFileURL(person.id, in: dir).path))
            #expect(KnownPeopleService.shared.person(byID: person.id) != nil)
            #expect(
                UserDefaults.standard.integer(forKey: UserDefaultsKeys.knownPeopleEmbeddingVersion)
                    == FaceRecognitionDefaults.embeddingVersion - 1
            )
        }
    }

    @Test("Embedding migration stamps its version only after reset succeeds")
    func embeddingMigrationDoesNotStampFailedReset() throws {
        struct InjectedResetFailure: Error {}

        try withIsolatedEmbeddingMigration { dir in
            let person = try KnownPeopleService.shared.addPerson(
                name: "Reset Failure Survivor",
                embeddings: [embedding(4)]
            )
            UserDefaults.standard.set(
                FaceRecognitionDefaults.embeddingVersion - 1,
                forKey: UserDefaultsKeys.knownPeopleEmbeddingVersion
            )

            let backup = dir.deletingLastPathComponent()
                .appendingPathComponent("KnownPeople-Verified-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: backup) }
            var io = KnownPeopleEmbeddingMigrationIO.live
            io.backupURL = { _, _, _, _ in backup }
            io.removeItem = { _ in throw InjectedResetFailure() }
            KnownPeopleService.embeddingMigrationIO = io

            KnownPeopleService.shared.reloadAfterStorageChange()

            #expect(FileManager.default.fileExists(atPath: personFileURL(person.id, in: dir).path))
            #expect(KnownPeopleService.shared.person(byID: person.id) != nil)
            #expect(
                UserDefaults.standard.integer(forKey: UserDefaultsKeys.knownPeopleEmbeddingVersion)
                    == FaceRecognitionDefaults.embeddingVersion - 1
            )
        }
    }

    // MARK: - 2. Concurrent edits to different people lose nothing

    @Test("Independently written person files both survive a load")
    func concurrentDifferentPeople() throws {
        let dir = makeTempDir()
        defer { teardown(dir) }
        activate(dir)

        // Two "devices" each wrote a different person's file. With per-person
        // files neither write clobbers the other.
        let fromDeviceA = KnownPerson(name: "Device A Person", embeddings: [embedding(10)])
        let fromDeviceB = KnownPerson(name: "Device B Person", embeddings: [embedding(20)])
        try writePersonFile(fromDeviceA, into: dir)
        try writePersonFile(fromDeviceB, into: dir)

        KnownPeopleService.shared.reloadAfterStorageChange()

        let names = Set(KnownPeopleService.shared.getAllPeople().map(\.name))
        #expect(names == ["Device A Person", "Device B Person"])
    }

    // MARK: - 3. Same-person merge: LWW scalars + embedding union

    @Test("mergePersonRecords takes newest scalars and unions/dedupes embeddings")
    func samePersonMerge() throws {
        let id = UUID()
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)

        // Shared feature-print bytes across two different embedding ids → the
        // later one must be deduped out.
        let dupData = Data([9, 9, 9])
        let e1 = PersonEmbedding(featurePrintData: Data([1, 1, 1]))
        let e2 = PersonEmbedding(featurePrintData: dupData)
        let e3 = PersonEmbedding(featurePrintData: dupData) // duplicate bytes, new id
        let e4 = PersonEmbedding(featurePrintData: Data([4, 4, 4]))

        let older = KnownPerson(
            id: id, name: "Old Name", role: "Old Role", notes: "Old Notes",
            embeddings: [e1, e2], representativeThumbnailID: e1.id,
            createdAt: early, updatedAt: early
        )
        let newer = KnownPerson(
            id: id, name: "New Name", role: "New Role", notes: "New Notes",
            embeddings: [e3, e4], representativeThumbnailID: e4.id,
            createdAt: late, updatedAt: late
        )

        let merged = KnownPeopleService.shared.mergePersonRecords([older, newer])

        // Scalars from the higher-updatedAt record.
        #expect(merged.name == "New Name")
        #expect(merged.role == "New Role")
        #expect(merged.notes == "New Notes")
        #expect(merged.representativeThumbnailID == e4.id)
        // createdAt earliest, updatedAt latest.
        #expect(merged.createdAt == early)
        #expect(merged.updatedAt == late)
        // Union by id then dedup by featurePrintData: e1, e2, e4 (e3 dropped).
        #expect(merged.embeddings.map(\.id) == [e1.id, e2.id, e4.id])
    }

    // MARK: - 4. Delete propagation / no resurrection

    @Test("removePerson tombstones the person and a peer copy can't resurrect it")
    func deletePropagationNoResurrection() throws {
        let dir = makeTempDir()
        defer { teardown(dir) }
        activate(dir)

        let person = try KnownPeopleService.shared.addPerson(name: "Doomed", embeddings: [embedding(7)])
        #expect(FileManager.default.fileExists(atPath: personFileURL(person.id, in: dir).path))

        try KnownPeopleService.shared.removePerson(id: person.id)
        #expect(KnownPeopleService.shared.getAllPeople().isEmpty)
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(person.id, in: dir).path))
        #expect(!FileManager.default.fileExists(atPath: personFileURL(person.id, in: dir).path))

        // A peer that still had the person re-syncs its file.
        try writePersonFile(person, into: dir)
        KnownPeopleService.shared.reloadAfterStorageChange()

        // The tombstone suppresses it and the stray file is cleaned up.
        #expect(KnownPeopleService.shared.getAllPeople().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: personFileURL(person.id, in: dir).path))
    }

    @Test("failed marker persistence keeps the person and all derived thumbnails usable")
    func failedMarkerPersistencePreservesPersonAndCaches() throws {
        let dir = makeTempDir()
        defer { teardown(dir) }
        activate(dir)

        let sample = embedding(8)
        let person = try KnownPeopleService.shared.addPerson(
            name: "Preserved",
            embeddings: [sample],
            thumbnailData: Data([1, 2, 3]),
            embeddingThumbnails: [sample.id: Data([4, 5, 6])]
        )
        KnownPeopleService.deletionIO = DurableDeletionIO(
            writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            readData: { try CloudCoordinatedIO.readData(at: $0) },
            removeItem: { try CloudCoordinatedIO.removeItem(at: $0) }
        )

        #expect(throws: DurableDeletionError.self) {
            try KnownPeopleService.shared.removePerson(id: person.id)
        }

        #expect(KnownPeopleService.shared.person(byID: person.id)?.name == "Preserved")
        #expect(FileManager.default.fileExists(atPath: personFileURL(person.id, in: dir).path))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("thumbnails/\(person.id.uuidString).jpg").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("embedding_thumbnails/\(sample.id.uuidString).jpg").path
        ))
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL(person.id, in: dir).path))
    }

    @Test("interrupted merge keeps its source and retry finishes without duplicate embeddings")
    func interruptedMergeIsRecoverableAndIdempotent() throws {
        let dir = makeTempDir()
        defer { teardown(dir) }
        activate(dir)

        let target = try KnownPeopleService.shared.addPerson(
            name: "Target", embeddings: [embedding(1)]
        )
        let source = try KnownPeopleService.shared.addPerson(
            name: "Source", embeddings: [embedding(2)]
        )
        KnownPeopleService.deletionIO = DurableDeletionIO(
            writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            readData: { try CloudCoordinatedIO.readData(at: $0) },
            removeItem: { try CloudCoordinatedIO.removeItem(at: $0) }
        )

        #expect(throws: DurableDeletionError.self) {
            try KnownPeopleService.shared.mergePeople(sourceID: source.id, intoTargetID: target.id)
        }
        #expect(KnownPeopleService.shared.person(byID: source.id) != nil)
        #expect(KnownPeopleService.shared.person(byID: target.id)?.embeddings.count == 2)
        #expect(FileManager.default.fileExists(atPath: personFileURL(source.id, in: dir).path))

        KnownPeopleService.deletionIO = .live
        try KnownPeopleService.shared.mergePeople(sourceID: source.id, intoTargetID: target.id)
        #expect(KnownPeopleService.shared.person(byID: source.id) == nil)
        #expect(KnownPeopleService.shared.person(byID: target.id)?.embeddings.count == 2)
    }

    // MARK: - 5. Tombstone GC

    @Test("Expired tombstones are garbage-collected; fresh ones are kept")
    func tombstoneGarbageCollection() throws {
        let dir = makeTempDir()
        defer { teardown(dir) }
        activate(dir)

        let peopleDir = dir.appendingPathComponent("people", isDirectory: true)
        try FileManager.default.createDirectory(at: peopleDir, withIntermediateDirectories: true)

        let oldID = UUID()
        let freshID = UUID()
        let expired = KnownPersonTombstone(id: oldID, deletedAt: Date(timeIntervalSince1970: 0))
        let fresh = KnownPersonTombstone(id: freshID, deletedAt: Date())
        try encode(expired).write(to: tombstoneURL(oldID, in: dir), options: .atomic)
        try encode(fresh).write(to: tombstoneURL(freshID, in: dir), options: .atomic)

        KnownPeopleService.shared.reloadAfterStorageChange()

        #expect(!FileManager.default.fileExists(atPath: tombstoneURL(oldID, in: dir).path))
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(freshID, in: dir).path))
    }

    // MARK: - 6. Encode/decode round-trip

    @Test("KnownPerson survives a per-file encode/decode round-trip")
    func roundTrip() throws {
        let original = KnownPerson(
            name: "Round Trip", role: "Tester", notes: "Some notes",
            embeddings: [embedding(1), embedding(2)],
            representativeThumbnailID: nil
        )
        let data = try encode(original)
        let decoded = try JSONDecoder().decode(KnownPerson.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.role == original.role)
        #expect(decoded.notes == original.notes)
        #expect(decoded.embeddings.map(\.id) == original.embeddings.map(\.id))
        #expect(decoded.embeddings.map(\.featurePrintData) == original.embeddings.map(\.featurePrintData))
    }
}
