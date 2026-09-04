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
        KnownPeopleService.embeddingMigrationModelReadiness = { true }
        KnownPeopleService.storageOverrideURL = dir
        KnownPeopleService.shared.reloadAfterStorageChange()
    }

    private func teardown(_ dir: URL) {
        KnownPeopleService.deletionIO = .live
        KnownPeopleService.embeddingMigrationIO = .live
        KnownPeopleService.embeddingMigrationModelReadiness = {
            CoreMLFaceEmbedder.shared.availability.isAvailable
        }
        KnownPeopleService.storageOverrideURL = nil
        try? FileManager.default.removeItem(at: dir)
        // Reset the singleton's cache so the next test starts clean.
        KnownPeopleService.shared.reloadAfterStorageChange()
    }

    private func withIsolatedEmbeddingMigration(_ body: (URL) throws -> Void) rethrows {
        let key = UserDefaultsKeys.knownPeopleEmbeddingVersion
        let previous = UserDefaults.standard.object(forKey: key)
        let dir = makeTempDir()
        KnownPeopleService.migrationRecoveryNotices = MigrationRecoveryNoticeCenter()
        activate(dir)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            KnownPeopleService.embeddingMigrationIO = .live
            KnownPeopleService.embeddingMigrationModelReadiness = {
                CoreMLFaceEmbedder.shared.availability.isAvailable
            }
            KnownPeopleService.migrationRecoveryNotices = .shared
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

    @Test("Known People thumbnail reads run off MainActor with explicit cancellation evidence")
    func thumbnailReadBoundary() async throws {
        let fileURL = URL(fileURLWithPath: "/known-people/thumbnails/person.jpg")
        let expected = Data("thumbnail".utf8)
        let probe = KnownPeopleThumbnailReadProbe(data: expected)
        let service = KnownPeopleThumbnailLoadService(access: KnownPeopleThumbnailFileAccess(
            readData: { probe.read($0) }
        ))
        let requestID = UUID()

        let result = await service.load(fileURL: fileURL, requestID: requestID)
        #expect(result == .loaded(KnownPeopleThumbnailLoadSnapshot(
            requestID: requestID,
            fileURL: fileURL,
            data: expected
        )))
        #expect(probe.urls == [fileURL])
        #expect(!probe.observedMainThread)

        let cancelledID = UUID()
        let cancelled = Task {
            await service.load(fileURL: fileURL, requestID: cancelledID)
        }
        cancelled.cancel()
        #expect(await cancelled.value == .cancelledBeforeRead(
            requestID: cancelledID,
            fileURL: fileURL
        ))
        #expect(probe.urls == [fileURL])
    }

    @Test("Known People archive preparation runs off MainActor and returns immutable thumbnail bytes")
    func archivePreparationBoundary() async throws {
        let sample = embedding(4)
        let person = KnownPerson(
            name: "Archive Person",
            embeddings: [sample],
            representativeThumbnailID: sample.id
        )
        let personThumbnail = Data([1, 2, 3])
        let embeddingThumbnail = Data([4, 5, 6])
        let probe = try KnownPeopleArchiveReadProbe(
            person: person,
            personThumbnail: personThumbnail,
            embeddingThumbnail: embeddingThumbnail
        )
        let service = KnownPeopleArchiveService(access: probe.fileAccess)
        let sourceURL = URL(fileURLWithPath: "/imports/known-people.zip")

        let payload = try await service.prepareImport(sourceURL: sourceURL)

        #expect(payload.people.map(\.id) == [person.id])
        #expect(payload.personThumbnails[person.id] == personThumbnail)
        #expect(payload.embeddingThumbnails[sample.id] == embeddingThumbnail)
        let dittoArguments = try #require(probe.dittoArguments.first)
        #expect(Array(dittoArguments.prefix(3)) == ["-x", "-k", sourceURL.path])
        #expect(dittoArguments.last?.hasPrefix(probe.temporaryDirectory.path) == true)
        #expect(!probe.observedMainThread)

        let cancelled = Task {
            try await service.prepareImport(sourceURL: sourceURL)
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
        #expect(probe.dittoArguments.count == 1)
    }

    @Test("Known People archive export/import round-trips people and thumbnails")
    func archiveRoundTrip() async throws {
        let exportStore = makeTempDir()
        let importStore = makeTempDir()
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnownPeopleRoundTrip-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: exportStore)
            try? FileManager.default.removeItem(at: archiveURL)
            teardown(importStore)
        }

        activate(exportStore)
        let sample = embedding(9)
        let person = try KnownPeopleService.shared.addPerson(
            name: "Round-trip Person",
            embeddings: [sample],
            thumbnailData: Data([10, 11, 12]),
            embeddingThumbnails: [sample.id: Data([13, 14, 15])]
        )
        try await KnownPeopleService.shared.exportToZip(destinationURL: archiveURL)

        activate(importStore)
        let importedCount = try await KnownPeopleService.shared.importFromZip(sourceURL: archiveURL)

        #expect(importedCount == 1)
        #expect(KnownPeopleService.shared.person(byID: person.id)?.name == "Round-trip Person")
        #expect(try Data(contentsOf: importStore.appendingPathComponent(
            "thumbnails/\(person.id.uuidString).jpg"
        )) == Data([10, 11, 12]))
        #expect(try Data(contentsOf: importStore.appendingPathComponent(
            "embedding_thumbnails/\(sample.id.uuidString).jpg"
        )) == Data([13, 14, 15]))
    }

    @Test("Known People archive destination commit runs off MainActor and returns its durable prefix")
    func archiveDestinationCommitBoundary() async throws {
        let firstEmbedding = embedding(21)
        let secondEmbedding = embedding(22)
        let first = KnownPerson(name: "First", embeddings: [firstEmbedding])
        let second = KnownPerson(name: "Second", embeddings: [secondEmbedding])
        let probe = KnownPeopleArchiveCommitProbe(cancelAfterFirstPerson: true)
        let service = KnownPeopleArchiveService(access: probe.fileAccess)
        let requestID = UUID()
        let storageRoot = URL(fileURLWithPath: "/known-people/import-store", isDirectory: true)

        let operation = Task {
            await service.commitImport(KnownPeopleArchiveImportCommitRequest(
                requestID: requestID,
                storageRoot: storageRoot,
                people: [first, second],
                personThumbnails: [first.id: Data([1])],
                embeddingThumbnails: [firstEmbedding.id: Data([2])]
            ))
        }
        let result = await operation.value

        guard case .cancelled(let evidence) = result else {
            Issue.record("Expected cancellation after the first durable person commit")
            return
        }
        #expect(evidence.requestID == requestID)
        #expect(evidence.requestedPersonCount == 2)
        #expect(evidence.committedPeople.map(\.id) == [first.id])
        #expect(evidence.committedFileURLs.map(\.lastPathComponent) == ["\(first.id.uuidString).json"])
        #expect(Set(evidence.committedThumbnailURLs.map(\.lastPathComponent)) == [
            "\(first.id.uuidString).jpg",
            "\(firstEmbedding.id.uuidString).jpg"
        ])
        #expect(evidence.failedThumbnailCount == 0)
        #expect(!probe.observedMainThread)
        #expect(probe.personWriteCount == 1)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Aagedal Photo Agent/Services/KnownPeopleService.swift"),
            encoding: .utf8
        )
        let importStart = try #require(serviceSource.range(of: "func importFromZip(sourceURL: URL)"))
        let statisticsStart = try #require(serviceSource.range(
            of: "// MARK: - Statistics",
            range: importStart.lowerBound..<serviceSource.endIndex
        ))
        let importFunction = serviceSource[importStart.lowerBound..<statisticsStart.lowerBound]
        #expect(importFunction.contains("await archiveService.commitImport"))
        #expect(!importFunction.contains("CloudCoordinatedIO.writeData"))
        #expect(!importFunction.contains("try writePerson(person)"))
    }

    @Test("Known People synchronous thumbnail presentation is cache-only")
    func thumbnailPresentationSourceContract() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Aagedal Photo Agent/Services/KnownPeopleService.swift"),
            encoding: .utf8
        )
        let cacheStart = try #require(serviceSource.range(of: "func cachedThumbnail(for personID: UUID)"))
        let asyncStart = try #require(serviceSource.range(
            of: "func loadThumbnail(for personID: UUID) async",
            range: cacheStart.lowerBound..<serviceSource.endIndex
        ))
        let cachedFunction = serviceSource[cacheStart.lowerBound..<asyncStart.lowerBound]
        #expect(!cachedFunction.contains("CloudCoordinatedIO"))
        #expect(!cachedFunction.contains("Data(contentsOf:"))

        for relativePath in [
            "Aagedal Photo Agent/Views/Faces/PersonEditSidebar.swift",
            "Aagedal Photo Agent/Views/Faces/KnownPeopleListView.swift",
            "Aagedal Photo Agent/Views/Faces/ExpandedKnownPeopleView.swift",
            "Aagedal Photo Agent/Views/Faces/ExpandedFaceManagementView.swift",
            "Aagedal Photo Agent/Views/Faces/EmbeddingGridView.swift",
            "Aagedal Photo Agent/Views/Teams/TeamsLibraryView.swift"
        ] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(!source.contains("= KnownPeopleService.shared.loadThumbnail(for:"))
            #expect(!source.contains("if let thumbnail = KnownPeopleService.shared.loadThumbnail(for:"))
            #expect(!source.contains("if let image = KnownPeopleService.shared.loadEmbeddingThumbnail(for:"))
        }
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
            let notice = KnownPeopleService.migrationRecoveryNotices.notice
            #expect(notice?.affectedCategories == [.knownPeople])
            #expect(notice?.message.contains("Known People") == true)
            #expect(notice?.message.contains(person.id.uuidString) == false)
        }
    }

    @Test("Embedding migration waits for the new model before touching stored embeddings")
    func embeddingMigrationRequiresVerifiedModel() throws {
        try withIsolatedEmbeddingMigration { dir in
            let person = try KnownPeopleService.shared.addPerson(
                name: "Deferred Until Model",
                embeddings: [embedding(8)]
            )
            let priorVersion = FaceRecognitionDefaults.embeddingVersion - 1
            UserDefaults.standard.set(priorVersion, forKey: UserDefaultsKeys.knownPeopleEmbeddingVersion)

            var backupAttempted = false
            var io = KnownPeopleEmbeddingMigrationIO.live
            io.mergeCopy = { _, _ in backupAttempted = true }
            KnownPeopleService.embeddingMigrationIO = io
            KnownPeopleService.embeddingMigrationModelReadiness = { false }

            KnownPeopleService.shared.reloadAfterStorageChange()

            #expect(!backupAttempted)
            #expect(FileManager.default.fileExists(atPath: personFileURL(person.id, in: dir).path))
            #expect(KnownPeopleService.shared.person(byID: person.id) != nil)
            #expect(
                UserDefaults.standard.integer(forKey: UserDefaultsKeys.knownPeopleEmbeddingVersion)
                    == priorVersion
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
            #expect(
                KnownPeopleService.migrationRecoveryNotices.notice?.affectedCategories
                    == [.knownPeople]
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

private nonisolated final class KnownPeopleThumbnailReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var storedURLs: [URL] = []
    private var storedObservedMainThread = false

    init(data: Data) {
        self.data = data
    }

    func read(_ url: URL) -> Data? {
        lock.lock()
        storedURLs.append(url)
        storedObservedMainThread = storedObservedMainThread || Thread.isMainThread
        lock.unlock()
        return data
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedURLs
    }

    var observedMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedObservedMainThread
    }
}

private nonisolated final class KnownPeopleArchiveReadProbe: @unchecked Sendable {
    let temporaryDirectory = URL(fileURLWithPath: "/temporary/archive-probe", isDirectory: true)

    private let lock = NSLock()
    private let person: KnownPerson
    private let peopleData: Data
    private let personThumbnail: Data
    private let embeddingThumbnail: Data
    private var storedDittoArguments: [[String]] = []
    private var storedObservedMainThread = false

    init(
        person: KnownPerson,
        personThumbnail: Data,
        embeddingThumbnail: Data
    ) throws {
        self.person = person
        self.personThumbnail = personThumbnail
        self.embeddingThumbnail = embeddingThumbnail
        peopleData = try JSONEncoder().encode([person])
    }

    var fileAccess: KnownPeopleArchiveFileAccess {
        let extractedDirectory = temporaryDirectory.appendingPathComponent("extracted", isDirectory: true)
        return KnownPeopleArchiveFileAccess(
            temporaryDirectory: temporaryDirectory,
            createDirectory: { [weak self] _ in self?.recordAccess() },
            removeItem: { [weak self] _ in self?.recordAccess() },
            contentsOfDirectory: { [weak self] _ in
                self?.recordAccess()
                return [extractedDirectory]
            },
            isDirectory: { [weak self] _ in
                self?.recordAccess()
                return true
            },
            itemExists: { [weak self] _ in
                self?.recordAccess()
                return true
            },
            readData: { [weak self] url in
                guard let self else { throw CancellationError() }
                self.recordAccess()
                if url.lastPathComponent == "people.json" {
                    return self.peopleData
                }
                if url.deletingLastPathComponent().lastPathComponent == "thumbnails" {
                    return self.personThumbnail
                }
                return self.embeddingThumbnail
            },
            readCoordinatedData: { _ in throw CancellationError() },
            writeData: { _, _ in },
            writeCoordinatedData: { _, _ in },
            runDitto: { [weak self] arguments in
                self?.recordDitto(arguments)
            }
        )
    }

    private func recordAccess() {
        lock.lock()
        storedObservedMainThread = storedObservedMainThread || Thread.isMainThread
        lock.unlock()
    }

    private func recordDitto(_ arguments: [String]) {
        lock.lock()
        storedDittoArguments.append(arguments)
        storedObservedMainThread = storedObservedMainThread || Thread.isMainThread
        lock.unlock()
    }

    var dittoArguments: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storedDittoArguments
    }

    var observedMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedObservedMainThread
    }
}

private nonisolated final class KnownPeopleArchiveCommitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfterFirstPerson: Bool
    private var storedObservedMainThread = false
    private var storedPersonWriteCount = 0

    init(cancelAfterFirstPerson: Bool) {
        self.cancelAfterFirstPerson = cancelAfterFirstPerson
    }

    var fileAccess: KnownPeopleArchiveFileAccess {
        KnownPeopleArchiveFileAccess(
            temporaryDirectory: URL(fileURLWithPath: "/temporary/archive-commit-probe", isDirectory: true),
            createDirectory: { _ in },
            removeItem: { _ in },
            contentsOfDirectory: { _ in [] },
            isDirectory: { _ in false },
            itemExists: { _ in false },
            readData: { _ in Data() },
            readCoordinatedData: { _ in Data() },
            writeData: { _, _ in },
            writeCoordinatedData: { [weak self] _, url in
                self?.recordWrite(url)
            },
            runDitto: { _ in }
        )
    }

    private func recordWrite(_ url: URL) {
        lock.lock()
        storedObservedMainThread = storedObservedMainThread || Thread.isMainThread
        if url.pathExtension == "json" {
            storedPersonWriteCount += 1
            let shouldCancel = cancelAfterFirstPerson && storedPersonWriteCount == 1
            lock.unlock()
            if shouldCancel {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return
        }
        lock.unlock()
    }

    var observedMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedObservedMainThread
    }

    var personWriteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPersonWriteCount
    }
}
