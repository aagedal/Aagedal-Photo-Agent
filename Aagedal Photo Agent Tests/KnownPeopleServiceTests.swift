import Testing
import Foundation
import AppKit
import SwiftUI
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

    @Test("Cold background edits migrate legacy records on the retained worker and release root ownership",
          arguments: ["success", "cancel", "storageChange", "readFailure", "writeFailure", "removeFailure"])
    func backgroundLegacyMigration(outcome: String) async throws {
        let directory = makeTempDir()
        activate(directory)
        let versionKey = UserDefaultsKeys.knownPeopleEmbeddingVersion
        let previousVersion = UserDefaults.standard.object(forKey: versionKey)
        defer {
            if let previousVersion { UserDefaults.standard.set(previousVersion, forKey: versionKey) }
            else { UserDefaults.standard.removeObject(forKey: versionKey) }
            teardown(directory)
        }
        let peer = KnownPeopleService()
        let original = try peer.addPerson(name: "Existing", embeddings: [embedding(91)])
        var older = original
        older.name = "Obsolete legacy name"
        let first = KnownPerson(name: "First legacy", embeddings: [embedding(92)])
        let second = KnownPerson(name: "Second legacy", embeddings: [embedding(93)])
        let legacyURL = directory.appendingPathComponent("database.json")
        let legacyData = try JSONEncoder().encode(KnownPeopleDatabase(people: [older, first, second]))
        try CloudCoordinatedIO.writeData(legacyData, to: legacyURL)
        // Legacy migration must not require or stamp readiness for a different embedding model.
        UserDefaults.standard.set(1, forKey: versionKey)
        KnownPeopleService.embeddingMigrationModelReadiness = { false }
        let gate = KnownPeopleThumbnailPublicationGate(data: legacyData)
        defer { gate.resume() }
        let system = KnownPeopleArchiveFileAccess.system
        let queue = DispatchSerialQueue(label: "test.known-people.legacy-migration")
        var access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: system.createDirectory, removeItem: system.removeItem,
            contentsOfDirectory: system.contentsOfDirectory, isDirectory: system.isDirectory,
            itemExists: system.itemExists, readData: system.readData,
            readCoordinatedData: { url in
                #expect(!Thread.isMainThread)
                #expect(queue.isIsolatingCurrentContext() == true)
                #expect(KnownPeopleEditTaskContext.root == directory)
                if url == legacyURL {
                    _ = gate.read(url)
                    if outcome == "readFailure" { throw CocoaError(.fileReadNoPermission) }
                }
                return try system.readCoordinatedData(url)
            }, writeData: system.writeData,
            writeCoordinatedData: { data, url in
                #expect(!Thread.isMainThread)
                #expect(queue.isIsolatingCurrentContext() == true)
                #expect(KnownPeopleEditTaskContext.root == directory)
                if outcome == "writeFailure", url.lastPathComponent == "\(second.id.uuidString).json" {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try system.writeCoordinatedData(data, url)
            }, runDitto: system.runDitto
        )
        access.destinationExists = { url in
            #expect(!Thread.isMainThread)
            return system.destinationExists(url)
        }
        access.removeCoordinatedItem = { url in
            #expect(!Thread.isMainThread)
            if outcome == "removeFailure", url == legacyURL { throw CocoaError(.fileWriteNoPermission) }
            try system.removeCoordinatedItem(url)
        }
        let service = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access, filesystemQueue: queue))
        var edited = original
        edited.name = "Edited"
        let task = Task {
            try await KnownPeopleEditTaskContext.$root.withValue(directory) {
                try await service.updatePersonDetailsInBackground(edited)
            }
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        #expect(throws: (any Error).self) { try peer.updatePerson(original) }
        #expect(throws: (any Error).self) { try peer.addPerson(name: "Overlapping", embeddings: []) }
        #expect(throws: (any Error).self) { try peer.clearDatabase() }
        let coldPeer = KnownPeopleService()
        #expect(coldPeer.loadDatabase().people.isEmpty)
        if outcome == "cancel" { task.cancel() }
        if outcome == "storageChange" {
            service.reloadAfterStorageChange(resolvedStorageURL: directory.appendingPathComponent("other"))
        }
        gate.resume()
        switch outcome {
        case "success": try await task.value
        case "cancel", "storageChange":
            await #expect(throws: CancellationError.self) { try await task.value }
        default:
            await #expect(throws: (any Error).self) { try await task.value }
        }
        let migratedFirst = outcome != "readFailure"
        let migratedSecond = migratedFirst && outcome != "writeFailure"
        #expect(FileManager.default.fileExists(atPath: personFileURL(first.id, in: directory).path) == migratedFirst)
        #expect(FileManager.default.fileExists(atPath: personFileURL(second.id, in: directory).path) == migratedSecond)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == outcome.hasSuffix("Failure"))
        let durable = try JSONDecoder().decode(KnownPerson.self,
            from: Data(contentsOf: personFileURL(original.id, in: directory)))
        #expect(durable.name == (outcome == "success" ? "Edited" : "Existing"))
        #expect(durable.embeddings.map(\.id) == original.embeddings.map(\.id))
        #expect(UserDefaults.standard.integer(forKey: versionKey) == 1)
        if outcome == "storageChange" {
            #expect(service.getAllPeople().isEmpty)
        }
        // Keep failed migrations from being retried by the synchronous assertion helpers.
        try? FileManager.default.removeItem(at: legacyURL)
        #expect((peer.person(byID: first.id) != nil) == migratedFirst)
        #expect((coldPeer.person(byID: second.id) != nil) == migratedSecond)
        // Every completion, including a durable prefix followed by failure, releases admission.
        try peer.updatePerson(original)
    }

    @Test("Legacy migration cancellation before the source read leaves the store untouched",
          arguments: [false, true])
    func backgroundLegacyMigrationCancelledBeforeRead(duringProbe: Bool) async throws {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = KnownPeopleThumbnailPublicationGate(data: Data())
        defer { gate.resume() }
        let system = KnownPeopleArchiveFileAccess.system
        var access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: system.createDirectory, removeItem: system.removeItem,
            contentsOfDirectory: system.contentsOfDirectory, isDirectory: system.isDirectory,
            itemExists: system.itemExists, readData: system.readData,
            readCoordinatedData: { _ in
                Issue.record("A cancelled legacy migration must not start reading")
                throw CocoaError(.fileReadUnknown)
            }, writeData: system.writeData, writeCoordinatedData: system.writeCoordinatedData,
            runDitto: system.runDitto
        )
        access.destinationExists = { url in
            _ = gate.read(url)
            return true
        }
        let worker = KnownPeopleArchiveService(access: access)
        let task = Task {
            if !duringProbe { withUnsafeCurrentTask { $0?.cancel() } }
            return await worker.migrateLegacyDatabase(root: directory)
        }
        if duringProbe {
            let deadline = ContinuousClock.now + .seconds(4)
            while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(gate.entered)
            task.cancel()
            gate.resume()
        }
        let result = await task.value
        #expect(result.writtenPersonURLs.isEmpty)
        #expect(!result.legacyRemoved)
        #expect(throws: CancellationError.self) { try result.completion.get() }
        #expect(gate.entered == duringProbe)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("Cold asynchronous additions retain tombstone suppression after legacy migration")
    func backgroundLegacyMigrationRetainsTombstones() async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let deleted = KnownPerson(name: "Deleted legacy person", embeddings: [embedding(94)])
        let legacyURL = directory.appendingPathComponent("database.json")
        try CloudCoordinatedIO.writeData(
            JSONEncoder().encode(KnownPeopleDatabase(people: [deleted])), to: legacyURL)
        let markerURL = directory.appendingPathComponent("people/\(deleted.id.uuidString).deleted")
        try CloudCoordinatedIO.writeData(JSONEncoder().encode(KnownPersonTombstone(id: deleted.id)), to: markerURL)
        let service = KnownPeopleService()
        let addition = try await service.addOrMergePerson(name: "New person", embeddings: [],
            thumbnailData: nil, duplicateCheck: .noDuplicate)
        #expect(service.getAllPeople().map(\.id) == [addition.person.id])
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(!FileManager.default.fileExists(atPath: personFileURL(deleted.id, in: directory).path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("Person editor bindings follow identity across reorder and ignore deleted records")
    func personEditorBindingSurvivesListChanges() {
        let first = KnownPerson(name: "First")
        let second = KnownPerson(name: "Second")
        var people = [first, second]
        let binding = knownPersonBinding(for: first, in: Binding(
            get: { people }, set: { people = $0 }
        ))
        people.reverse()
        var edited = binding.wrappedValue
        edited.name = "Edited"
        binding.wrappedValue = edited
        #expect(people.map(\.name) == ["Second", "Edited"])
        people.removeLast()
        #expect(binding.wrappedValue.id == first.id)
        binding.wrappedValue = edited
        #expect(people.map(\.id) == [second.id])
        people.removeAll()
        #expect(binding.wrappedValue.id == first.id)
        binding.wrappedValue = edited
        #expect(people.isEmpty)
    }

    @Test("Person detail edits reserve records and publish durable worker writes",
          arguments: ["success", "cancel", "storageChange", "writeFailure", "storageChangeWriteFailure"])
    func asynchronousPersonDetailEdit(outcome: String) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let gate = KnownPeopleThumbnailPublicationGate(data: Data())
        defer { gate.resume() }
        let system = KnownPeopleArchiveFileAccess.system
        let queue = DispatchSerialQueue(label: "test.known-people.detail-edit")
        let access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: system.createDirectory, removeItem: system.removeItem,
            contentsOfDirectory: system.contentsOfDirectory, isDirectory: system.isDirectory,
            itemExists: system.itemExists, readData: system.readData,
            readCoordinatedData: system.readCoordinatedData, writeData: system.writeData,
            writeCoordinatedData: { data, url in
                #expect(!Thread.isMainThread)
                #expect(queue.isIsolatingCurrentContext() == true)
                #expect(KnownPeopleEditTaskContext.root == directory)
                _ = gate.read(url)
                if outcome.lowercased().contains("writefailure") { throw CocoaError(.fileWriteNoPermission) }
                try system.writeCoordinatedData(data, url)
            }, runDitto: system.runDitto
        )
        let service = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access, filesystemQueue: queue))
        let sample = embedding(81)
        let original = try service.addPerson(name: "Original", embeddings: [sample])
        let peer = KnownPeopleService()
        #expect(peer.person(byID: original.id)?.name == "Original")
        var edited = original
        edited.name = "Edited"
        edited.role = "Photographer"
        edited.notes = "Saved note"
        // Only the form fields are writable through this API.
        edited.embeddings = []
        edited.representativeThumbnailID = nil
        let task = Task {
            try await KnownPeopleEditTaskContext.$root.withValue(directory) {
                try await service.updatePersonDetailsInBackground(edited)
            }
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        #expect(throws: (any Error).self) { try peer.updatePerson(original) }
        #expect(throws: (any Error).self) { try peer.removePerson(id: original.id) }
        #expect(throws: (any Error).self) { try peer.clearDatabase() }
        let unrelated = try peer.addPerson(name: "Unrelated", embeddings: [])
        if outcome == "cancel" { task.cancel() }
        if outcome.hasPrefix("storageChange") {
            service.reloadAfterStorageChange(resolvedStorageURL: directory.appendingPathComponent("other"))
        }
        gate.resume()
        if outcome == "success" {
            try await task.value
        } else if outcome == "cancel" || outcome.hasPrefix("storageChange") {
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            await #expect(throws: (any Error).self) { try await task.value }
        }
        let failed = outcome.lowercased().contains("writefailure")
        let durable = try JSONDecoder().decode(KnownPerson.self,
            from: Data(contentsOf: personFileURL(original.id, in: directory)))
        #expect(durable.name == (failed ? "Original" : "Edited"))
        #expect(durable.role == (failed ? nil : "Photographer"))
        #expect(durable.notes == (failed ? nil : "Saved note"))
        #expect(durable.embeddings.map(\.id) == [sample.id])
        #expect(durable.representativeThumbnailID == sample.id)
        #expect(durable.createdAt == original.createdAt)
        #expect(peer.person(byID: original.id)?.name == durable.name)
        #expect(peer.person(byID: unrelated.id) != nil)
        if outcome.hasPrefix("storageChange") {
            #expect(service.person(byID: original.id) == nil)
        } else {
            #expect(service.person(byID: unrelated.id) != nil)
        }
        // Every completion releases the path reservation.
        try peer.updatePerson(original)
    }

    @Test("Queued detail edits preserve newly selected samples and reject cancellation or replacement roots",
          arguments: ["success", "cancel", "storageChange"])
    func queuedPersonDetailEdit(outcome: String) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let gate = KnownPeopleThumbnailPublicationGate(data: Data())
        defer { gate.resume() }
        let system = KnownPeopleArchiveFileAccess.system
        let access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: system.createDirectory, removeItem: system.removeItem,
            contentsOfDirectory: system.contentsOfDirectory, isDirectory: system.isDirectory,
            itemExists: system.itemExists, readData: system.readData,
            readCoordinatedData: system.readCoordinatedData, writeData: system.writeData,
            writeCoordinatedData: { data, url in
                _ = gate.read(url)
                try system.writeCoordinatedData(data, url)
            }, runDitto: system.runDitto
        )
        let service = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
        let samples = [embedding(82), embedding(83)]
        let original = try service.addPerson(name: "Original", embeddings: samples)
        let selection = Task { try await service.updateRepresentativeInBackground(samples[1].id, for: original.id) }
        let deadline = ContinuousClock.now + .seconds(4)
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        var edited = original
        edited.name = "Queued edit"
        let queuedService = KnownPeopleService()
        var queuedStarted = false
        let queued = Task {
            queuedStarted = true
            try await queuedService.updatePersonDetailsInBackground(edited)
        }
        // Let the queued caller capture its revision and suspend at mutation admission.
        while !queuedStarted { await Task.yield() }
        if outcome == "cancel" { queued.cancel() }
        if outcome == "storageChange" {
            let otherRoot = directory.appendingPathComponent("other")
            try CloudCoordinatedIO.writeData(encode(original), to: personFileURL(original.id, in: otherRoot))
            queuedService.reloadAfterStorageChange(resolvedStorageURL: otherRoot)
        }
        gate.resume()
        try await selection.value
        if outcome == "success" {
            try await queued.value
        } else {
            await #expect(throws: CancellationError.self) { try await queued.value }
        }
        #expect(service.person(byID: original.id)?.representativeThumbnailID == samples[1].id)
        #expect(service.person(byID: original.id)?.name == (outcome == "success" ? "Queued edit" : "Original"))
        if outcome == "storageChange" {
            #expect(queuedService.person(byID: original.id)?.name == "Original")
            #expect(queuedService.person(byID: original.id)?.representativeThumbnailID == samples[0].id)
        }
    }

    @Test("Detail editing cancellation and missing samples leave records intact and release admission")
    func personDetailEditRejectedBeforeWrite() async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let service = KnownPeopleService()
        var edited = try service.addPerson(name: "Original", embeddings: [embedding(84)])
        edited.name = "Cancelled"
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.updatePersonDetailsInBackground(edited)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: (any Error).self) {
            try await service.updateRepresentativeInBackground(UUID(), for: edited.id)
        }
        await #expect(throws: (any Error).self) {
            try await service.updatePersonDetailsInBackground(KnownPerson(name: "Missing"))
        }
        #expect(service.person(byID: edited.id)?.name == "Original")
        edited.name = "Saved"
        try await service.updatePersonDetailsInBackground(edited)
        #expect(service.person(byID: edited.id)?.name == "Saved")
    }

    @Test("Person merges own both records, publish durable prefixes and preserve transferred thumbnails",
          arguments: ["success", "cancel", "storageChange", "targetFailure", "markerFailure", "recordFailure", "rollbackFailure", "cleanupFailure", "storageChangeMarkerFailure"])
    func asynchronousPersonMerge(outcome: String) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let gate = KnownPeopleThumbnailPublicationGate(data: Data())
        defer { gate.resume() }
        let system = KnownPeopleArchiveFileAccess.system
        var access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: system.createDirectory, removeItem: system.removeItem,
            contentsOfDirectory: system.contentsOfDirectory, isDirectory: system.isDirectory,
            itemExists: system.itemExists, readData: system.readData,
            readCoordinatedData: system.readCoordinatedData, writeData: system.writeData,
            writeCoordinatedData: { data, url in
                #expect(!Thread.isMainThread)
                _ = gate.read(url)
                if outcome == "targetFailure" { throw CocoaError(.fileWriteNoPermission) }
                try system.writeCoordinatedData(data, url)
            }, runDitto: system.runDitto
        )
        access.removeCoordinatedItem = { url in
            #expect(!Thread.isMainThread)
            if outcome == "cleanupFailure" { throw CocoaError(.fileWriteNoPermission) }
            try system.removeCoordinatedItem(url)
        }
        let writer = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
        let transferred = embedding(72)
        let targetSample = embedding(73)
        let duplicate = embedding(73)
        let target = try writer.addPerson(name: "Target", embeddings: [targetSample])
        let source = try writer.addPerson(name: "Source", embeddings: [transferred, duplicate],
            thumbnailData: Data([1]), embeddingThumbnails: [transferred.id: Data([2]), duplicate.id: Data([3])])
        let peer = KnownPeopleService()
        #expect(peer.person(byID: target.id)?.embeddings.count == 1)
        let live = DurableDeletionIO.live
        KnownPeopleService.deletionIO = DurableDeletionIO(
            writeData: { data, url in
                #expect(!Thread.isMainThread)
                if ["markerFailure", "storageChangeMarkerFailure"].contains(outcome) { throw CocoaError(.fileWriteNoPermission) }
                try live.writeData(data, url)
            },
            readData: { url in
                #expect(!Thread.isMainThread)
                return try live.readData(url)
            },
            removeItem: { url in
                #expect(!Thread.isMainThread)
                if outcome == "rollbackFailure" || (outcome == "recordFailure" && url.pathExtension == "json") {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try live.removeItem(url)
            }
        )
        let task = Task { try await writer.mergePeople(sourceID: source.id, intoTargetID: target.id) }
        let deadline = ContinuousClock.now + .seconds(4)
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        #expect(throws: (any Error).self) { try peer.removePerson(id: source.id) }
        #expect(throws: (any Error).self) { try peer.removePerson(id: target.id) }
        #expect(throws: (any Error).self) { try peer.saveEmbeddingThumbnail(Data(), for: transferred.id) }
        #expect(throws: (any Error).self) { try peer.clearDatabase() }
        let unrelated = try peer.addPerson(name: "Unrelated", embeddings: [])
        if outcome == "cancel" { task.cancel() }
        if outcome.hasPrefix("storageChange") {
            writer.reloadAfterStorageChange(resolvedStorageURL: directory.appendingPathComponent("other"))
        }
        gate.resume()
        if ["success", "cleanupFailure"].contains(outcome) {
            try await task.value
        } else if outcome == "cancel" || outcome.hasPrefix("storageChange") {
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            await #expect(throws: (any Error).self) { try await task.value }
        }
        let removed = ["success", "cancel", "storageChange", "cleanupFailure"].contains(outcome)
        #expect(FileManager.default.fileExists(atPath: personFileURL(source.id, in: directory).path) == !removed)
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(source.id, in: directory).path) == (removed || outcome == "rollbackFailure"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("embedding_thumbnails/\(transferred.id.uuidString).jpg").path))
        for path in ["thumbnails/\(source.id.uuidString).jpg", "embedding_thumbnails/\(duplicate.id.uuidString).jpg"] {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) == (!removed || outcome == "cleanupFailure"))
        }
        // Read durable worker evidence before lazy loading: a surviving rollback-failure
        // marker makes loadDatabase remove the suppressed source record during maintenance.
        #expect(peer.person(byID: target.id)?.embeddings.count == (outcome == "targetFailure" ? 1 : 2))
        #expect((peer.person(byID: source.id) == nil) == (removed || outcome == "rollbackFailure"))
        #expect(peer.person(byID: unrelated.id) != nil)
        if outcome.hasPrefix("storageChange") {
            #expect(writer.person(byID: target.id) == nil)
        } else {
            #expect(writer.person(byID: unrelated.id) != nil)
        }
        // A retry after target commit must retain the image already referenced by the target.
        if ["markerFailure", "recordFailure"].contains(outcome) {
            KnownPeopleService.deletionIO = .live
            try await peer.mergePeople(sourceID: source.id, intoTargetID: target.id)
            #expect(peer.person(byID: target.id)?.embeddings.count == 2)
            #expect(peer.person(byID: source.id) == nil)
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("embedding_thumbnails/\(transferred.id.uuidString).jpg").path))
        }
        try peer.saveThumbnail(Data([9]), for: source.id)
    }

    @Test("Multi-person merges stop after a storage switch even when both roots contain the selected IDs")
    func personMergeBatchStorageRevision() async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let otherRoot = directory.appendingPathComponent("other")
        let gate = KnownPeopleThumbnailPublicationGate(data: Data())
        defer { gate.resume() }
        let system = KnownPeopleArchiveFileAccess.system
        let access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: system.createDirectory, removeItem: system.removeItem,
            contentsOfDirectory: system.contentsOfDirectory, isDirectory: system.isDirectory,
            itemExists: system.itemExists, readData: system.readData,
            readCoordinatedData: system.readCoordinatedData, writeData: system.writeData,
            writeCoordinatedData: { data, url in
                _ = gate.read(url)
                try system.writeCoordinatedData(data, url)
            }, runDitto: system.runDitto
        )
        let service = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
        let target = try service.addPerson(name: "Target", embeddings: [])
        let first = try service.addPerson(name: "First", embeddings: [embedding(75)])
        let second = try service.addPerson(name: "Second", embeddings: [embedding(76)])
        for person in [target, first, second] {
            try CloudCoordinatedIO.writeData(encode(person), to: personFileURL(person.id, in: otherRoot))
        }
        let task = Task { try await service.mergePeople(sourceIDs: [first.id, second.id], intoTargetID: target.id) }
        let deadline = ContinuousClock.now + .seconds(4)
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        service.reloadAfterStorageChange(resolvedStorageURL: otherRoot)
        gate.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(service.person(byID: target.id)?.embeddings.isEmpty == true)
        #expect(service.person(byID: first.id) != nil)
        #expect(service.person(byID: second.id) != nil)
        let original = KnownPeopleService()
        #expect(original.person(byID: target.id)?.embeddings.map(\.id) == first.embeddings.map(\.id))
        #expect(original.person(byID: first.id) == nil)
        #expect(original.person(byID: second.id) != nil)
    }

    @Test("Merge cancellation before admission leaves both records intact")
    func cancelledPersonMergeBeforeAdmission() async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let service = KnownPeopleService()
        let source = try service.addPerson(name: "Source", embeddings: [embedding(74)])
        let target = try service.addPerson(name: "Target", embeddings: [])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.mergePeople(sourceID: source.id, intoTargetID: target.id)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(service.person(byID: source.id) != nil)
        #expect(service.person(byID: target.id)?.embeddings.isEmpty == true)
        try await service.mergePeople(sourceID: source.id, intoTargetID: target.id)
        #expect(service.person(byID: source.id) == nil)
    }

    @Test("Whole-database clear reserves all identities and publishes partial filesystem outcomes",
          arguments: ["success", "cancel", "storageChange", "removeFailure", "partialRemoval", "recreateFailure"])
    func asynchronousDatabaseClear(outcome: String) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let gate = KnownPeopleThumbnailPublicationGate(data: Data())
        defer { gate.resume() }
        let system = KnownPeopleArchiveFileAccess.system
        let queue = DispatchSerialQueue(label: "test.known-people.clear")
        var access = system
        access.removeCoordinatedItem = { url in
            #expect(!Thread.isMainThread)
            #expect(queue.isIsolatingCurrentContext() == true)
            #expect(KnownPeopleEditTaskContext.root == directory)
            _ = gate.read(url)
            if outcome == "removeFailure" { throw CocoaError(.fileWriteNoPermission) }
            if outcome == "partialRemoval" {
                try system.removeCoordinatedItem(url.appendingPathComponent("people"))
                throw CocoaError(.fileWriteNoPermission)
            }
            try system.removeCoordinatedItem(url)
        }
        access.ensureCoordinatedDirectory = { url in
            #expect(!Thread.isMainThread)
            #expect(queue.isIsolatingCurrentContext() == true)
            if outcome == "recreateFailure", url.lastPathComponent == "thumbnails" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try system.ensureCoordinatedDirectory(url)
        }
        let writer = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access, filesystemQueue: queue))
        let sample = embedding(91)
        let person = try writer.addPerson(name: "Clear me", embeddings: [sample],
            thumbnailData: Data([1]), embeddingThumbnails: [sample.id: Data([2])])
        let peer = KnownPeopleService()
        #expect(peer.person(byID: person.id) != nil)
        let task = Task {
            try await KnownPeopleEditTaskContext.$root.withValue(directory) {
                try await writer.clearDatabaseInBackground()
            }
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        #expect(throws: (any Error).self) { try peer.addPerson(name: "New identity", embeddings: []) }
        #expect(throws: (any Error).self) { try peer.updatePerson(person) }
        #expect(throws: (any Error).self) { try peer.removePerson(id: person.id) }
        #expect(throws: (any Error).self) { try peer.saveThumbnail(Data(), for: UUID()) }
        #expect(throws: (any Error).self) { try peer.saveEmbeddingThumbnail(Data(), for: UUID()) }
        #expect(throws: (any Error).self) { try peer.clearDatabase() }
        let coldPeer = KnownPeopleService()
        #expect(coldPeer.loadDatabase().people.isEmpty)
        #expect(throws: (any Error).self) { try coldPeer.addPerson(name: "Cold identity", embeddings: []) }
        if outcome == "cancel" { task.cancel() }
        let otherRoot = makeTempDir()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        var otherPerson: KnownPerson?
        if outcome == "storageChange" {
            writer.reloadAfterStorageChange(resolvedStorageURL: otherRoot)
            otherPerson = try writer.addPerson(name: "Other root", embeddings: [])
        }
        gate.resume()
        if outcome == "success" || outcome == "cancel" {
            try await task.value
        } else if outcome == "storageChange" {
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            await #expect(throws: CocoaError.self) { try await task.value }
        }
        #expect((peer.person(byID: person.id) != nil) == (outcome == "removeFailure"))
        #expect((coldPeer.person(byID: person.id) != nil) == (outcome == "removeFailure"))
        if let otherPerson {
            #expect(writer.person(byID: otherPerson.id) != nil)
            #expect(FileManager.default.fileExists(atPath: personFileURL(otherPerson.id, in: otherRoot).path))
        } else {
            #expect((writer.person(byID: person.id) != nil) == (outcome == "removeFailure"))
        }
        let added = try peer.addPerson(name: "After clear", embeddings: [])
        #expect(peer.person(byID: added.id) != nil)
    }

    @Test("Clear worker reports completed removal and the durable recreation prefix")
    func databaseClearWorkerEvidence() async throws {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        var access = KnownPeopleArchiveFileAccess.system
        access.ensureCoordinatedDirectory = { url in
            #expect(!Thread.isMainThread)
            if url.lastPathComponent == "thumbnails" { throw CocoaError(.fileWriteNoPermission) }
            try CloudCoordinatedIO.ensureDirectory(url)
        }
        let result = await KnownPeopleArchiveService(access: access).clearDatabase(root: directory)
        #expect(result.removalAttempted)
        #expect(result.rootRemoved)
        #expect(result.recreatedDirectoryURLs.map(\.lastPathComponent) == ["people"])
        #expect(throws: CocoaError.self) { try result.completion.get() }
    }

    @Test("Clear cancelled before admission leaves disk untouched and releases ownership")
    func cancelledDatabaseClearBeforeAdmission() async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let service = KnownPeopleService()
        let person = try service.addPerson(name: "Keep me", embeddings: [])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.clearDatabaseInBackground()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(service.person(byID: person.id) != nil)
        try await service.clearDatabaseInBackground()
        #expect(service.loadDatabase().people.isEmpty)
        let worker = KnownPeopleArchiveService()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await worker.clearDatabase(root: directory)
        }
        let result = await cancelled.value
        #expect(!result.removalAttempted)
        #expect(!result.rootRemoved)
        #expect(result.recreatedDirectoryURLs.isEmpty)
        #expect(throws: CancellationError.self) { try result.completion.get() }
    }

    @Test("Cancelled person deletion writes no tombstone and releases admission")
    func cancelledPersonDeletionBeforeAdmission() async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let service = KnownPeopleService()
        let person = try service.addPerson(name: "Keep me", embeddings: [])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.removePersonInBackground(id: person.id)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(service.person(byID: person.id) != nil)
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL(person.id, in: directory).path))
        try await service.removePersonInBackground(id: person.id)
        #expect(service.person(byID: person.id) == nil)
    }

    @Test("Async person deletion preserves rollback and publishes admitted deletion", arguments: [
        "success", "cancel", "storageChange", "markerFailure", "recordFailure", "rollbackFailure"
    ])
    func asynchronousPersonDeletion(outcome: String) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let gate = KnownPeopleThumbnailPublicationGate(data: Data())
        defer { gate.resume() }
        let writer = KnownPeopleService()
        let sample = embedding(8)
        let person = try writer.addPerson(name: "Delete me", embeddings: [sample],
            thumbnailData: Data([1, 2]), embeddingThumbnails: [sample.id: Data([3, 4])])
        let peer = KnownPeopleService()
        #expect(peer.person(byID: person.id) != nil)
        let live = DurableDeletionIO.live
        KnownPeopleService.deletionIO = DurableDeletionIO(
            writeData: { data, url in
                #expect(!Thread.isMainThread)
                _ = gate.read(url)
                if outcome == "markerFailure" { throw CocoaError(.fileWriteNoPermission) }
                try live.writeData(data, url)
            },
            readData: { url in
                #expect(!Thread.isMainThread)
                return try live.readData(url)
            },
            removeItem: { url in
                #expect(!Thread.isMainThread)
                if outcome == "rollbackFailure" || (outcome == "recordFailure" && url.pathExtension == "json") {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try live.removeItem(url)
            }
        )
        let task = Task { try await writer.removePersonInBackground(id: person.id) }
        let deadline = ContinuousClock.now + .seconds(4)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.entered)
        #expect(throws: (any Error).self) { try peer.removePerson(id: person.id) }
        #expect(throws: (any Error).self) { try peer.saveEmbeddingThumbnail(Data(), for: sample.id) }
        #expect(throws: (any Error).self) { try peer.clearDatabase() }
        let unrelated = try peer.addPerson(name: "Unrelated", embeddings: [])
        if outcome == "cancel" { task.cancel() }
        if outcome == "storageChange" {
            writer.reloadAfterStorageChange(resolvedStorageURL: directory.appendingPathComponent("other"))
        }
        gate.resume()
        if outcome == "success" {
            try await task.value
        } else if outcome == "cancel" || outcome == "storageChange" {
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            await #expect(throws: DurableDeletionError.self) { try await task.value }
        }
        let committed = ["success", "cancel", "storageChange"].contains(outcome)
        #expect(FileManager.default.fileExists(atPath: personFileURL(person.id, in: directory).path) == !committed)
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(person.id, in: directory).path) == (committed || outcome == "rollbackFailure"))
        for path in ["thumbnails/\(person.id.uuidString).jpg", "embedding_thumbnails/\(sample.id.uuidString).jpg"] {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) == !committed)
        }
        #expect((peer.person(byID: person.id) == nil) == (committed || outcome == "rollbackFailure"))
        #expect(peer.person(byID: unrelated.id) != nil)
        if outcome != "storageChange" { #expect(writer.person(byID: unrelated.id) != nil) }
        // Every outcome releases reservations, permitting subsequent ordinary writes.
        try peer.saveThumbnail(Data([9]), for: person.id)
    }

    @Test("Queued ordinary additions recheck names after admission")
    func queuedOrdinaryAdditions() async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let gate = KnownPeopleThumbnailPublicationGate(data: Data())
        defer { gate.resume() }
        let system = KnownPeopleArchiveFileAccess.system
        let access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: system.createDirectory, removeItem: system.removeItem,
            contentsOfDirectory: system.contentsOfDirectory, isDirectory: system.isDirectory,
            itemExists: system.itemExists, readData: system.readData,
            readCoordinatedData: system.readCoordinatedData, writeData: system.writeData,
            writeCoordinatedData: { data, url in
                #expect(!Thread.isMainThread)
                if url.pathExtension == "jpg" { _ = gate.read(url) }
                try system.writeCoordinatedData(data, url)
            }, runDitto: system.runDitto
        )
        let writer = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
        let peer = KnownPeopleService()
        let first = embedding(98)
        let second = embedding(99)
        let initial = Task {
            try await writer.addOrMergePerson(name: "Same Name", embeddings: [first],
                thumbnailData: Data([1]), duplicateCheck: .noDuplicate)
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.entered)
        var queuedStarted = false
        let queued = Task {
            queuedStarted = true
            return try await peer.addOrMergePerson(name: " same name ", embeddings: [second],
                thumbnailData: nil, duplicateCheck: .noDuplicate)
        }
        while !queuedStarted { await Task.yield() }
        gate.resume()
        let created = try await initial.value
        let merged = try await queued.value
        #expect(!created.addedToExisting)
        #expect(merged.addedToExisting)
        #expect(created.person.id == merged.person.id)
        #expect(peer.getAllPeople().count == 1)
        #expect(merged.person.embeddings.map(\.id) == [first.id, second.id])
    }

    @Test("Ordinary add and merge own their writes and publish partial durable results",
          arguments: [false, true], ["success", "cancel", "storageChange", "recordFailure", "thumbnailFailure"])
    func asynchronousOrdinaryAddition(merge: Bool, outcome: String) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let gate = KnownPeopleThumbnailPublicationGate(data: Data())
        defer { gate.resume() }
        let sample = embedding(97)
        let imageURL = directory.appendingPathComponent("embedding_thumbnails/\(sample.id.uuidString).jpg")
        let system = KnownPeopleArchiveFileAccess.system
        let access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: system.createDirectory, removeItem: system.removeItem,
            contentsOfDirectory: system.contentsOfDirectory, isDirectory: system.isDirectory,
            itemExists: system.itemExists, readData: system.readData,
            readCoordinatedData: system.readCoordinatedData, writeData: system.writeData,
            writeCoordinatedData: { data, url in
                #expect(!Thread.isMainThread)
                if merge ? url.pathExtension == "json" : url == imageURL { _ = gate.read(url) }
                if outcome == "recordFailure", url.pathExtension == "json" {
                    throw CocoaError(.fileWriteNoPermission)
                }
                if outcome == "thumbnailFailure", url == imageURL {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try system.writeCoordinatedData(data, url)
            }, runDitto: system.runDitto
        )
        let writer = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
        let existing = try writer.addPerson(name: "Existing", embeddings: [])
        let peer = KnownPeopleService()
        #expect(peer.person(byID: existing.id)?.embeddings.isEmpty == true)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        ))
        let oldImage = try #require(bitmap.representation(using: .png, properties: [:]))
        try peer.saveEmbeddingThumbnail(oldImage, for: sample.id)
        #expect(peer.cachedEmbeddingThumbnail(for: sample.id) != nil)
        // A duplicate check is a snapshot. Scalar edits since that check must survive merging.
        var edited = existing
        edited.name = "Edited"
        try peer.updatePerson(edited)
        let operation = Task {
            try await writer.addOrMergePerson(name: "New", embeddings: [sample], thumbnailData: nil,
                embeddingThumbnails: [sample.id: Data([9])],
                duplicateCheck: merge ? .nameMatch(person: existing) : .noDuplicate)
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.entered)
        #expect(throws: (any Error).self) { try peer.saveEmbeddingThumbnail(Data(), for: sample.id) }
        #expect(throws: (any Error).self) { try peer.clearDatabase() }
        if merge { #expect(throws: (any Error).self) { try peer.removePerson(id: existing.id) } }
        let unrelated = try peer.addPerson(name: "Unrelated", embeddings: [])
        if outcome == "cancel" { operation.cancel() }
        if outcome == "storageChange" {
            writer.reloadAfterStorageChange(resolvedStorageURL: directory.appendingPathComponent("other"))
        }
        gate.resume()
        if outcome == "success" {
            let result = try await operation.value
            #expect(result.addedToExisting == merge)
            #expect(result.person.name == (merge ? "Edited" : "New"))
        } else if outcome == "cancel" || outcome == "storageChange" {
            await #expect(throws: CancellationError.self) { try await operation.value }
        } else {
            await #expect(throws: (any Error).self) { try await operation.value }
        }
        let thumbnailWritten = outcome != "thumbnailFailure" && !(merge && outcome == "recordFailure")
        #expect(try Data(contentsOf: imageURL) == (thumbnailWritten ? Data([9]) : oldImage))
        if thumbnailWritten { #expect(peer.cachedEmbeddingThumbnail(for: sample.id) == nil) }
        let personWritten = outcome != "recordFailure" && (merge || outcome != "thumbnailFailure")
        if merge {
            #expect(peer.person(byID: existing.id)?.embeddings.map(\.id) == (personWritten ? [sample.id] : []))
            #expect(peer.person(byID: existing.id)?.name == "Edited")
        } else {
            #expect((peer.person(byName: "New") != nil) == personWritten)
        }
        #expect(peer.person(byID: unrelated.id) != nil)
        if outcome == "storageChange" { #expect(writer.person(byID: existing.id) == nil) }
        try peer.saveEmbeddingThumbnail(Data(), for: sample.id)
        try peer.removePerson(id: existing.id)
    }

    @Test("Embedding removal invalidates cached and suspended images when its thumbnail is already missing", arguments: [false, true])
    func embeddingRemovalMissingThumbnailInvalidation(pendingRead: Bool) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        ))
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        let writer = KnownPeopleService()
        let first = embedding(93)
        let removed = embedding(94)
        let person = try writer.addPerson(name: "Missing image", embeddings: [first, removed],
            embeddingThumbnails: [removed.id: image])
        #expect(writer.cachedEmbeddingThumbnail(for: removed.id) != nil)
        let gate = KnownPeopleThumbnailPublicationGate(data: image)
        defer { gate.resume() }
        let peer = pendingRead ? KnownPeopleService(thumbnailLoader: KnownPeopleThumbnailLoadService(
            access: KnownPeopleThumbnailFileAccess(readData: { gate.read($0) })
        )) : KnownPeopleService()
        let read: Task<NSImage?, Never>?
        if pendingRead {
            read = Task { await peer.loadEmbeddingThumbnail(for: removed.id) }
            let deadline = ContinuousClock.now + .seconds(5)
            while !gate.entered, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(gate.entered)
        } else {
            read = nil
            #expect(await peer.loadEmbeddingThumbnail(for: removed.id) != nil)
            #expect(peer.cachedEmbeddingThumbnail(for: removed.id) != nil)
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(
            "embedding_thumbnails/\(removed.id.uuidString).jpg"))
        try await writer.removeEmbedding(removed.id, fromPersonID: person.id)
        gate.resume()
        if let read { #expect(await read.value == nil) }
        #expect(writer.cachedEmbeddingThumbnail(for: removed.id) == nil)
        #expect(peer.cachedEmbeddingThumbnail(for: removed.id) == nil)
        #expect(writer.person(byID: person.id)?.embeddings.map(\.id) == [first.id])
    }

    @Test("Embedding removal reports failed replacement without undoing its durable record")
    func embeddingRemovalReplacementFailure() async throws {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = KnownPeopleArchiveFileAccess.system
        let recordURL = directory.appendingPathComponent("person.json")
        let embeddingURL = directory.appendingPathComponent("embedding.jpg")
        let thumbnailURL = directory.appendingPathComponent("person.jpg")
        try Data([1]).write(to: embeddingURL)
        try Data([2]).write(to: thumbnailURL)
        let access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: system.createDirectory, removeItem: system.removeItem,
            contentsOfDirectory: system.contentsOfDirectory, isDirectory: system.isDirectory,
            itemExists: system.itemExists, readData: system.readData,
            readCoordinatedData: system.readCoordinatedData, writeData: system.writeData,
            writeCoordinatedData: { data, url in
                #expect(!Thread.isMainThread)
                if url == thumbnailURL { throw CocoaError(.fileWriteNoPermission) }
                try system.writeCoordinatedData(data, url)
            }, runDitto: system.runDitto
        )
        let person = KnownPerson(name: "Committed")
        let result = await KnownPeopleArchiveService(access: access).removeEmbedding(
            person: person, personURL: recordURL, embeddingURL: embeddingURL,
            replacementData: Data([3]), thumbnailURL: thumbnailURL)
        try result.completion.get()
        #expect(result.personWritten)
        #expect(result.changedThumbnailURLs == [embeddingURL])
        #expect(Set(result.thumbnailFailures.keys) == [thumbnailURL])
        #expect(try JSONDecoder().decode(KnownPerson.self, from: Data(contentsOf: recordURL)).id == person.id)
        #expect(try Data(contentsOf: thumbnailURL) == Data([2]))
    }

    @Test("Embedding removal reserves its destinations and publishes durable writes after suspension", arguments: ["success", "cancel", "storageChange", "recordFailure", "thumbnailFailure", "deferredDeletion"])
    func asynchronousEmbeddingRemoval(outcome: String) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let gate = KnownPeopleThumbnailPublicationGate(data: Data())
        defer { gate.resume() }
        let system = KnownPeopleArchiveFileAccess.system
        var access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: system.createDirectory, removeItem: system.removeItem,
            contentsOfDirectory: system.contentsOfDirectory, isDirectory: system.isDirectory,
            itemExists: system.itemExists, readData: system.readData,
            readCoordinatedData: system.readCoordinatedData, writeData: system.writeData,
            writeCoordinatedData: { data, url in
                #expect(!Thread.isMainThread)
                _ = gate.read(url)
                if outcome == "recordFailure" { throw CocoaError(.fileWriteNoPermission) }
                try system.writeCoordinatedData(data, url)
            }, runDitto: system.runDitto
        )
        access.removeCoordinatedItem = { url in
            #expect(!Thread.isMainThread)
            if outcome == "thumbnailFailure" { throw CocoaError(.fileWriteNoPermission) }
            try system.removeCoordinatedItem(url)
        }
        let writer = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
        let first = embedding(91)
        let second = embedding(92)
        let person = try writer.addPerson(name: "Original", embeddings: [first, second],
            embeddingThumbnails: [first.id: Data([2]), second.id: Data([1])])
        let peer = KnownPeopleService()
        #expect(peer.person(byID: person.id) != nil)
        let operation = Task { try await writer.removeEmbedding(second.id, fromPersonID: person.id) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(gate.entered)
        #expect(throws: (any Error).self) { try peer.removePerson(id: person.id) }
        #expect(throws: (any Error).self) { try peer.saveEmbeddingThumbnail(Data(), for: second.id) }
        #expect(throws: (any Error).self) { try peer.clearDatabase() }
        let unrelated = try peer.addPerson(name: "Unrelated", embeddings: [])
        if outcome == "deferredDeletion" { peer.deleteEmbeddingThumbnail(for: first.id) }
        if outcome == "cancel" { operation.cancel() }
        if outcome == "storageChange" {
            writer.reloadAfterStorageChange(resolvedStorageURL: directory.appendingPathComponent("other"))
        }
        gate.resume()
        if ["success", "thumbnailFailure", "deferredDeletion"].contains(outcome) { try await operation.value }
        else if outcome == "recordFailure" {
            await #expect(throws: (any Error).self) { try await operation.value }
        } else {
            await #expect(throws: CancellationError.self) { try await operation.value }
        }
        let expected = outcome == "recordFailure" ? [first.id, second.id] : [first.id]
        #expect(peer.person(byID: person.id)?.embeddings.map(\.id) == expected)
        #expect(peer.person(byID: unrelated.id) != nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(
            "embedding_thumbnails/\(second.id.uuidString).jpg").path) == (["recordFailure", "thumbnailFailure"].contains(outcome)))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(
            "embedding_thumbnails/\(first.id.uuidString).jpg").path) == (outcome != "deferredDeletion"))
        if outcome == "storageChange" { #expect(writer.person(byID: person.id) == nil) }
        try peer.removePerson(id: person.id)
    }

    @Test("Thumbnail replacement reserves its record and publishes durable worker writes", arguments: ["success", "cancel", "storageChange", "recordFailure"])
    func asynchronousThumbnailReplacement(outcome: String) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let gate = KnownPeopleThumbnailPublicationGate(data: Data())
        defer { gate.resume() }
        let system = KnownPeopleArchiveFileAccess.system
        let access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: system.createDirectory, removeItem: system.removeItem,
            contentsOfDirectory: system.contentsOfDirectory, isDirectory: system.isDirectory,
            itemExists: system.itemExists, readData: system.readData,
            readCoordinatedData: system.readCoordinatedData, writeData: system.writeData,
            writeCoordinatedData: { data, url in
                #expect(!Thread.isMainThread)
                if url.pathExtension == "jpg" { _ = gate.read(url) }
                if outcome == "recordFailure", url.pathExtension == "json" {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try system.writeCoordinatedData(data, url)
            }, runDitto: system.runDitto
        )
        let writer = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
        let person = try writer.addPerson(name: "Original", embeddings: [])
        let peer = KnownPeopleService()
        #expect(peer.person(byID: person.id) != nil)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        ))
        try peer.saveThumbnail(try #require(bitmap.representation(using: .png, properties: [:])), for: person.id)
        #expect(peer.cachedThumbnail(for: person.id) != nil)
        let replacement = Data([3, 2, 1])
        let operation = Task { try await writer.replaceThumbnail(for: person.id, newThumbnailData: replacement) }
        let deadline = ContinuousClock.now + .seconds(4)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.entered)
        #expect(throws: (any Error).self) { try peer.removePerson(id: person.id) }
        #expect(throws: (any Error).self) { try peer.saveThumbnail(Data(), for: person.id) }
        #expect(throws: (any Error).self) { try peer.clearDatabase() }
        let unrelated = try peer.addPerson(name: "Unrelated", embeddings: [])
        if outcome == "cancel" { operation.cancel() }
        if outcome == "storageChange" {
            writer.reloadAfterStorageChange(resolvedStorageURL: directory.appendingPathComponent("other"))
        }
        gate.resume()
        if outcome == "success" {
            try await operation.value
        } else if outcome == "recordFailure" {
            await #expect(throws: (any Error).self) { try await operation.value }
        } else {
            await #expect(throws: CancellationError.self) { try await operation.value }
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("thumbnails/\(person.id.uuidString).jpg")) == replacement)
        #expect(peer.cachedThumbnail(for: person.id) == nil)
        #expect(peer.person(byID: unrelated.id) != nil)
        if outcome != "recordFailure" {
            #expect(try #require(peer.person(byID: person.id)).updatedAt >= person.updatedAt)
        }
        if outcome == "storageChange" { #expect(writer.person(byID: person.id) == nil) }
        // The admitted mutation releases ownership on every outcome.
        try peer.removePerson(id: person.id)
    }

    @Test("Peer databases follow durable CRUD without losing unrelated additions")
    func peerDatabaseCRUD() throws {
        try withIsolatedEmbeddingMigration { directory in
            let writer = KnownPeopleService()
            let peer = KnownPeopleService()
            _ = writer.loadDatabase()
            _ = peer.loadDatabase()
            var person = try writer.addPerson(name: "Original", embeddings: [])
            #expect(peer.person(byID: person.id)?.name == "Original")
            let other = try peer.addPerson(name: "Other", embeddings: [])
            person.name = "Updated"
            // updatePerson must reload an invalidated index before checking existence.
            try writer.updatePerson(person)
            #expect(peer.person(byID: person.id)?.name == "Updated")
            #expect(writer.person(byID: other.id) != nil)
            try peer.removePerson(id: person.id)
            #expect(writer.person(byID: person.id) == nil)
            #expect(writer.getAllPeople().map(\.id) == [other.id])
            try writer.clearDatabase()
            #expect(peer.getAllPeople().isEmpty)
        }
    }

    @Test("Remote record events on a cold receiver invalidate warm peer databases", arguments: [false, true])
    func coldRemoteReceiverInvalidatesPeers(deletion: Bool) throws {
        try withIsolatedEmbeddingMigration { directory in
            var person = KnownPerson(name: "Before")
            try writePersonFile(person, into: directory)
            let peer = KnownPeopleService()
            #expect(peer.person(byID: person.id)?.name == "Before")
            let receiver = KnownPeopleService()
            let url: URL
            if deletion {
                url = tombstoneURL(person.id, in: directory)
                try encode(KnownPersonTombstone(id: person.id)).write(to: url)
            } else {
                person.name = "Remote edit"
                try writePersonFile(person, into: directory)
                url = personFileURL(person.id, in: directory)
            }
            receiver.applyRemoteChanges([(url, nil)])
            #expect(peer.person(byID: person.id)?.name == (deletion ? nil : "Remote edit"))
        }
    }

    @Test("Database invalidation leaves unresolved and other-root peers untouched")
    func peerDatabaseRootScope() throws {
        try withIsolatedEmbeddingMigration { directory in
            let writer = KnownPeopleService()
            let original = try writer.addPerson(name: "Original root", embeddings: [])
            let peer = KnownPeopleService()
            #expect(peer.person(byID: original.id) != nil)
            let cold = KnownPeopleService()
            let otherRoot = directory.appendingPathComponent("other-root")
            KnownPeopleService.storageOverrideURL = otherRoot
            writer.reloadAfterStorageChange(resolvedStorageURL: otherRoot)
            _ = try writer.addPerson(name: "Other root", embeddings: [])
            // Remove a file behind the old peer's cache; unrelated-root invalidation must
            // not force that peer to reload, and must not resolve the cold service's root.
            try FileManager.default.removeItem(at: personFileURL(original.id, in: directory))
            _ = try writer.addPerson(name: "Another", embeddings: [])
            #expect(peer.person(byID: original.id) != nil)
            KnownPeopleService.storageOverrideURL = directory
            #expect(cold.getAllPeople().isEmpty)
        }
    }

    @Test("Mismatched tombstones suppress only their filename identity and preserve marker bytes", arguments: [false, true])
    func mismatchedTombstoneIdentity(expired: Bool) throws {
        try withIsolatedEmbeddingMigration { directory in
            let deleted = KnownPerson(name: "Deleted")
            let survivor = KnownPerson(name: "Keep")
            try writePersonFile(deleted, into: directory)
            try writePersonFile(survivor, into: directory)
            let marker = KnownPersonTombstone(
                id: survivor.id,
                deletedAt: expired ? .distantPast : Date()
            )
            let bytes = try encode(marker)
            let url = tombstoneURL(deleted.id, in: directory)
            try bytes.write(to: url)

            let service = KnownPeopleService()
            #expect(service.loadDatabase().people.map(\.id) == [survivor.id])
            #expect(try Data(contentsOf: url) == bytes)
            #expect(FileManager.default.fileExists(atPath: personFileURL(survivor.id, in: directory).path))
        }
    }

    @Test("Remote Known People changes reject old roots, siblings, and nested record paths")
    func remoteChangesRequireActiveDirectory() throws {
        try withIsolatedEmbeddingMigration { directory in
            let person = KnownPerson(name: "Keep", embeddings: [embedding(1)])
            try writePersonFile(person, into: directory)
            let service = KnownPeopleService()
            _ = service.loadDatabase()
            let foreign = directory.appendingPathExtension("old")
            defer { try? FileManager.default.removeItem(at: foreign) }
            var replacement = person
            replacement.name = "Wrong root"
            try writePersonFile(replacement, into: foreign)
            service.applyRemoteChanges([(personFileURL(person.id, in: foreign), nil)])
            service.applyRemoteChanges([(tombstoneURL(person.id, in: foreign), nil)])
            service.applyRemoteChanges([(
                directory.appendingPathComponent("people/nested/\(person.id.uuidString).deleted"), nil
            )])
            #expect(service.person(byID: person.id)?.name == "Keep")
            #expect(FileManager.default.fileExists(atPath: personFileURL(person.id, in: directory).path))
        }
    }

    @Test("Known People watcher accepts only direct records and thumbnail files")
    func remoteFileClassification() {
        let root = URL(fileURLWithPath: "/library/KnownPeople")
        let id = UUID().uuidString
        for path in ["people/\(id).json", "people/\(id).deleted", "thumbnails/\(id).jpg", "embedding_thumbnails/\(id).jpg"] {
            #expect(KnownPeopleCloudCoordinator.acceptsChange(at: root.appendingPathComponent(path), root: root))
        }
        for path in ["people/nested/\(id).json", "people/\(id).jpg", "thumbnails/\(id).json", "people/not-a-person.json", "database.json"] {
            #expect(!KnownPeopleCloudCoordinator.acceptsChange(at: root.appendingPathComponent(path), root: root))
        }
        #expect(!KnownPeopleCloudCoordinator.acceptsChange(
            at: URL(fileURLWithPath: "/library/KnownPeople-old/people/\(id).json"), root: root
        ))
    }

    @Test("Adding to a cold Known People cache preserves existing records without duplicating the new person")
    func addPersonWithColdCache() throws {
        try withIsolatedEmbeddingMigration { dir in
            let existing = KnownPerson(name: "Existing", embeddings: [embedding(1)])
            try writePersonFile(existing, into: dir)
            let service = KnownPeopleService()

            let added = try service.addPerson(name: "Added", embeddings: [embedding(2)])

            #expect(service.getAllPeople().count == 2)
            #expect(Set(service.getAllPeople().map(\.id)) == [existing.id, added.id])
            #expect(service.person(byID: added.id)?.name == "Added")
            service.reloadAfterStorageChange()
            #expect(service.getAllPeople().count == 2)
            #expect(Set(service.getAllPeople().map(\.id)) == [existing.id, added.id])
        }
    }

    @Test("Adding to a cold cache completes embedding migration before writing the new person and thumbnails")
    func addPersonAfterColdCacheEmbeddingMigration() throws {
        try withIsolatedEmbeddingMigration { dir in
            let backup = dir.deletingLastPathComponent()
                .appendingPathComponent("KnownPeople-ColdAddBackup-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: backup) }
            var io = KnownPeopleEmbeddingMigrationIO.live
            io.backupURL = { _, _, _, _ in backup }
            KnownPeopleService.embeddingMigrationIO = io
            let legacy = KnownPerson(name: "Old embedding space", embeddings: [embedding(3)])
            try writePersonFile(legacy, into: dir)
            UserDefaults.standard.set(
                FaceRecognitionDefaults.embeddingVersion - 1,
                forKey: UserDefaultsKeys.knownPeopleEmbeddingVersion
            )
            let service = KnownPeopleService()
            let sample = embedding(4)
            let thumbnail = Data([5, 6, 7])
            let embeddingThumbnail = Data([8, 9, 10])

            let added = try service.addPerson(
                name: "Current embedding space",
                embeddings: [sample],
                thumbnailData: thumbnail,
                embeddingThumbnails: [sample.id: embeddingThumbnail]
            )

            #expect(service.getAllPeople().map(\.id) == [added.id])
            #expect(FileManager.default.fileExists(atPath: personFileURL(legacy.id, in: backup).path))
            #expect(FileManager.default.fileExists(atPath: personFileURL(added.id, in: dir).path))
            #expect(try Data(contentsOf: dir.appendingPathComponent("thumbnails/\(added.id.uuidString).jpg")) == thumbnail)
            #expect(try Data(contentsOf: dir.appendingPathComponent("embedding_thumbnails/\(sample.id.uuidString).jpg")) == embeddingThumbnail)
            service.reloadAfterStorageChange()
            #expect(service.getAllPeople().map(\.id) == [added.id])
        }
    }

    @Test("Cold loads reject mismatched person filenames and preserve recovery bytes", arguments: [false, true])
    func coldLoadRejectsMismatchedIdentity(malformedFilename: Bool) throws {
        try withIsolatedEmbeddingMigration { directory in
            UserDefaults.standard.set(FaceRecognitionDefaults.embeddingVersion, forKey: UserDefaultsKeys.knownPeopleEmbeddingVersion)
            let person = KnownPerson(name: "Keep")
            try writePersonFile(person, into: directory)
            var impostor = person
            impostor.name = "Wrong file"
            let bytes = try encode(impostor)
            let filename = malformedFilename ? "not-a-person.json" : "\(UUID().uuidString).json"
            let url = directory.appendingPathComponent("people/\(filename)")
            try bytes.write(to: url)
            let service = KnownPeopleService()

            #expect(service.loadDatabase().people.count == 1)
            #expect(service.person(byID: person.id)?.name == "Keep")
            #expect(try Data(contentsOf: url) == bytes)
            let backups = try FileManager.default.contentsOfDirectory(
                at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("\(filename).corrupt.") }
            #expect(backups.count == 1)
            if let backup = backups.first { #expect(try Data(contentsOf: backup) == bytes) }
        }
    }

    @Test("Remote records cannot update another person's identity", arguments: [false, true])
    func remoteLoadRejectsMismatchedIdentity(malformedFilename: Bool) throws {
        try withIsolatedEmbeddingMigration { directory in
            UserDefaults.standard.set(FaceRecognitionDefaults.embeddingVersion, forKey: UserDefaultsKeys.knownPeopleEmbeddingVersion)
            let person = KnownPerson(name: "Keep")
            try writePersonFile(person, into: directory)
            let service = KnownPeopleService()
            _ = service.loadDatabase()
            var impostor = person
            impostor.name = "Wrong remote file"
            let bytes = try encode(impostor)
            let filename = malformedFilename ? "not-a-person.json" : "\(UUID().uuidString).json"
            let url = directory.appendingPathComponent("people/\(filename)")
            try bytes.write(to: url)

            service.applyRemoteChanges([(url, nil)])

            #expect(service.getAllPeople().count == 1)
            #expect(service.person(byID: person.id)?.name == "Keep")
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

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

    @Test("A local or remote thumbnail mutation rejects an older in-flight read", arguments: Array(0..<26))
    func thumbnailReadRejectsLocalMutation(operation: Int) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        ))
        let imageData = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(NSImage(data: imageData) != nil)
        let gate = KnownPeopleThumbnailPublicationGate(data: imageData)
        defer { gate.resume() }
        let service = KnownPeopleService(thumbnailLoader: KnownPeopleThumbnailLoadService(
            access: KnownPeopleThumbnailFileAccess(readData: { gate.read($0) })
        ))
        let sample = embedding(11)
        let person: KnownPerson
        if operation >= 8 {
            person = KnownPerson(name: "Cold thumbnail race", embeddings: [sample])
            try writePersonFile(person, into: directory)
        } else {
            person = try service.addPerson(name: "Thumbnail race", embeddings: [sample])
        }
        let isEmbedding = operation % 2 == 1
        let task = Task {
            if isEmbedding { return await service.loadEmbeddingThumbnail(for: sample.id) }
            return await service.loadThumbnail(for: person.id)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.entered)
        if operation >= 18 {
            let observer = KnownPeopleService()
            if operation >= 22 { _ = observer.loadDatabase() }
            if operation % 4 < 2 {
                observer.applyRemoteChanges([(
                    tombstoneURL(person.id, in: directory), Date.distantFuture
                )])
            } else {
                let folder = isEmbedding ? "embedding_thumbnails" : "thumbnails"
                let id = isEmbedding ? sample.id : person.id
                observer.applyRemoteChanges([(
                    directory.appendingPathComponent("\(folder)/\(id.uuidString).jpg"), Date.distantFuture
                )])
            }
        } else if operation >= 12 {
            let writer = KnownPeopleService()
            switch operation {
            case 12: try writer.saveThumbnail(Data(), for: person.id)
            case 13: try writer.saveEmbeddingThumbnail(Data(), for: sample.id)
            case 14: try writer.removePerson(id: person.id)
            case 15: writer.deleteEmbeddingThumbnail(for: sample.id)
            default: try writer.clearDatabase()
            }
        } else if operation < 2 {
            // Invalid replacement bytes deliberately clear the cache. A stale read must
            // not resurrect the earlier valid image after this successful local write.
            if isEmbedding { try service.saveEmbeddingThumbnail(Data(), for: sample.id) }
            else { try service.saveThumbnail(Data(), for: person.id) }
        } else if operation == 6 || operation == 7 || operation >= 10 {
            service.applyRemoteChanges([(
                tombstoneURL(person.id, in: directory), Date.distantFuture
            )])
        } else if operation >= 4 {
            let folder = isEmbedding ? "embedding_thumbnails" : "thumbnails"
            let id = isEmbedding ? sample.id : person.id
            service.applyRemoteChanges([(
                directory.appendingPathComponent("\(folder)/\(id.uuidString).jpg"), Date.distantFuture
            )])
        } else if isEmbedding {
            service.deleteEmbeddingThumbnail(for: sample.id)
        } else {
            try service.removePerson(id: person.id)
        }
        gate.resume()
        #expect(await task.value == nil)
        if isEmbedding { #expect(service.cachedEmbeddingThumbnail(for: sample.id) == nil) }
        else { #expect(service.cachedThumbnail(for: person.id) == nil) }
        if operation >= 8 && operation < 12 {
            #expect(service.getAllPeople().map(\.id) == [person.id])
        }
    }

    @Test("Peer thumbnail invalidation is scoped to the storage root", arguments: [false, true])
    func peerThumbnailCacheInvalidation(sameRoot: Bool) throws {
        let directory = makeTempDir()
        let otherDirectory = makeTempDir()
        activate(directory)
        defer {
            teardown(directory)
            try? FileManager.default.removeItem(at: otherDirectory)
        }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        ))
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        let reader = KnownPeopleService()
        let writer = KnownPeopleService()
        writer.reloadAfterStorageChange(resolvedStorageURL: sameRoot ? directory : otherDirectory)
        let personID = try writer.addPerson(name: "Peer echo", embeddings: []).id
        let embeddingID = UUID()
        try reader.saveThumbnail(image, for: personID)
        try reader.saveEmbeddingThumbnail(image, for: embeddingID)
        #expect(reader.cachedThumbnail(for: personID) != nil)
        #expect(reader.cachedEmbeddingThumbnail(for: embeddingID) != nil)

        // A wrong-root event and a local-write echo cannot evict another instance's cache.
        writer.applyRemoteChanges([(
            directory.appendingPathExtension("wrong").appendingPathComponent("thumbnails/\(personID.uuidString).jpg"),
            Date.distantFuture
        )])
        let marker = tombstoneURL(personID, in: sameRoot ? directory : otherDirectory)
        try encode(KnownPersonTombstone(id: personID)).write(to: marker)
        writer.applyRemoteChanges([(
            personFileURL(personID, in: sameRoot ? directory : otherDirectory), nil
        )])
        try FileManager.default.removeItem(at: marker)
        #expect(reader.cachedThumbnail(for: personID) != nil)
        #expect(reader.cachedEmbeddingThumbnail(for: embeddingID) != nil)
        try writer.saveThumbnail(Data(), for: personID)
        #expect((reader.cachedThumbnail(for: personID) == nil) == sameRoot)
        try reader.saveEmbeddingThumbnail(image, for: embeddingID)
        writer.deleteEmbeddingThumbnail(for: embeddingID)
        #expect((reader.cachedEmbeddingThumbnail(for: embeddingID) == nil) == sameRoot)
    }

    @Test("Removing an embedding cannot mutate a different storage root after its thumbnail read")
    func removeEmbeddingRejectsChangedStorageRoot() async throws {
        let originalDirectory = makeTempDir()
        let replacementDirectory = makeTempDir()
        activate(originalDirectory)
        defer {
            teardown(originalDirectory)
            try? FileManager.default.removeItem(at: replacementDirectory)
        }
        let gate = KnownPeopleThumbnailPublicationGate(data: Data())
        defer { gate.resume() }
        let service = KnownPeopleService(thumbnailLoader: KnownPeopleThumbnailLoadService(
            access: KnownPeopleThumbnailFileAccess(readData: { gate.read($0) })
        ))
        let first = embedding(21)
        let second = embedding(22)
        var person = try service.addPerson(name: "Shared ID", embeddings: [first, second])
        person.representativeThumbnailID = first.id
        try service.updatePerson(person)
        try writePersonFile(person, into: replacementDirectory)
        let task = Task { try await service.removeEmbedding(first.id, fromPersonID: person.id) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.entered)
        service.reloadAfterStorageChange(resolvedStorageURL: replacementDirectory)
        gate.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(service.person(byID: person.id)?.embeddings.map(\.id) == [first.id, second.id])
        let persisted = try JSONDecoder().decode(
            KnownPerson.self,
            from: Data(contentsOf: personFileURL(person.id, in: replacementDirectory))
        )
        #expect(persisted.embeddings.map(\.id) == [first.id, second.id])
    }

    @Test("Replacement thumbnail conversion runs off MainActor and rejects cancelled conversion")
    func replacementThumbnailConversionBoundary() async throws {
        let url = URL(fileURLWithPath: "/known-people/embedding_thumbnails/sample.jpg")
        let converted = Data([7, 8])
        let probe = KnownPeopleThumbnailReadProbe(data: converted)
        let worker = KnownPeopleThumbnailLoadService(access: KnownPeopleThumbnailFileAccess(
            readData: { _ in Data([1]) },
            prepareJPEGData: { _ in probe.read(url) }
        ))
        let requestID = UUID()
        #expect(await worker.load(fileURL: url, requestID: requestID, prepareForReplacement: true)
            == .loaded(KnownPeopleThumbnailLoadSnapshot(requestID: requestID, fileURL: url, data: converted)))
        #expect(probe.urls == [url])
        #expect(!probe.observedMainThread)

        let gate = KnownPeopleThumbnailPublicationGate(data: converted)
        defer { gate.resume() }
        let heldWorker = KnownPeopleThumbnailLoadService(access: KnownPeopleThumbnailFileAccess(
            readData: { _ in Data([1]) },
            prepareJPEGData: { _ in gate.read(url) }
        ))
        let task = Task { await heldWorker.load(fileURL: url, requestID: requestID, prepareForReplacement: true) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(gate.entered)
        task.cancel()
        gate.resume()
        #expect(await task.value == .cancelledAfterRead(requestID: requestID, fileURL: url))
    }

    @Test("Replacement thumbnail preparation returns JPEG bytes and tolerates corrupt image data", arguments: [false, true])
    func replacementThumbnailImageData(corrupt: Bool) async throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        ))
        let input = corrupt ? Data([1, 2, 3]) : try #require(bitmap.representation(using: .png, properties: [:]))
        let worker = KnownPeopleThumbnailLoadService(access: KnownPeopleThumbnailFileAccess(readData: { _ in input }))
        let url = URL(fileURLWithPath: "/known-people/embedding_thumbnails/sample.jpg")
        guard case .loaded(let snapshot) = await worker.load(
            fileURL: url, requestID: UUID(), prepareForReplacement: true
        ) else {
            Issue.record("Uncancelled conversion did not return a snapshot")
            return
        }
        if corrupt {
            #expect(snapshot.data == nil)
        } else {
            let jpeg = try #require(snapshot.data)
            #expect(Array(jpeg.prefix(2)) == [0xFF, 0xD8])
            #expect(NSImage(data: jpeg) != nil)
        }
    }

    @Test("Representative removal persists prepared JPEG and preserves the old thumbnail on conversion failure", arguments: [false, true])
    func removeEmbeddingReplacementJPEG(corrupt: Bool) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        ))
        let input = corrupt ? Data([1, 2, 3]) : try #require(bitmap.representation(using: .png, properties: [:]))
        let service = KnownPeopleService()
        let first = embedding(41)
        let second = embedding(42)
        let original = Data([9, 8, 7])
        var person = try service.addPerson(name: "Replacement", embeddings: [first, second],
            thumbnailData: original, embeddingThumbnails: [first.id: input, second.id: input])
        person.representativeThumbnailID = first.id
        try service.updatePerson(person)
        try await service.removeEmbedding(first.id, fromPersonID: person.id)
        #expect(service.person(byID: person.id)?.representativeThumbnailID == second.id)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(
            "embedding_thumbnails/\(first.id.uuidString).jpg").path))
        let persisted = try Data(contentsOf: directory.appendingPathComponent("thumbnails/\(person.id.uuidString).jpg"))
        if corrupt {
            #expect(persisted == original)
        } else {
            #expect(Array(persisted.prefix(2)) == [0xFF, 0xD8])
            #expect(NSImage(data: persisted) != nil)
        }
    }

    @Test("Embedding removal reloads peer-invalidated records after thumbnail preparation", arguments: [false, true])
    func removeEmbeddingReloadsPeerMutation(cancel: Bool) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let gate = KnownPeopleThumbnailPublicationGate(data: Data([1]))
        defer { gate.resume() }
        let service = KnownPeopleService(thumbnailLoader: KnownPeopleThumbnailLoadService(
            access: KnownPeopleThumbnailFileAccess(readData: { gate.read($0) })
        ))
        let first = embedding(31)
        let second = embedding(32)
        var person = try service.addPerson(name: "Before", embeddings: [first, second])
        person.representativeThumbnailID = first.id
        try service.updatePerson(person)
        let peer = KnownPeopleService()
        _ = peer.loadDatabase()
        let task = Task { try await service.removeEmbedding(first.id, fromPersonID: person.id) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(gate.entered)
        person.name = "Peer edit"
        try peer.updatePerson(person)
        if cancel { task.cancel() }
        gate.resume()
        if cancel {
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            try await task.value
        }
        let expectedIDs = cancel ? [first.id, second.id] : [second.id]
        #expect(service.person(byID: person.id)?.name == "Peer edit")
        #expect(service.person(byID: person.id)?.embeddings.map(\.id) == expectedIDs)
        #expect(peer.person(byID: person.id)?.embeddings.map(\.id) == expectedIDs)
        let persisted = try JSONDecoder().decode(KnownPerson.self,
            from: Data(contentsOf: personFileURL(person.id, in: directory)))
        #expect(persisted.embeddings.map(\.id) == expectedIDs)
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

    @Test("Archive preparation selects a unique payload and cleans up every layout", arguments: [
        "flat", "wrapper", "root-precedence", "ambiguous", "missing", "invalid-root"
    ])
    func archivePayloadLayouts(layout: String) async throws {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = embedding(7)
        let person = KnownPerson(name: "Selected payload", embeddings: [sample])
        let peopleData = try encode([person])
        let otherPeopleData = try encode([KnownPerson(name: "Other payload")])
        let thumbnail = Data([1, 2, 3])
        let embeddingThumbnail = Data([4, 5, 6])
        let system = KnownPeopleArchiveFileAccess.system
        let service = KnownPeopleArchiveService(access: KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: system.createDirectory,
            removeItem: system.removeItem,
            // Put irrelevant directories first to reproduce the old selection failure.
            contentsOfDirectory: { try system.contentsOfDirectory($0).sorted { $0.path < $1.path } },
            isDirectory: system.isDirectory,
            itemExists: system.itemExists,
            readData: system.readData,
            readCoordinatedData: { _ in
                Issue.record("Preparation must not read destination storage")
                throw CancellationError()
            },
            writeData: { _, _ in Issue.record("Preparation must not write payload files") },
            writeCoordinatedData: { _, _ in Issue.record("Preparation must not commit destination files") },
            runDitto: { arguments in
                let extracted = URL(fileURLWithPath: try #require(arguments.last), isDirectory: true)
                try system.createDirectory(extracted.appendingPathComponent("__MACOSX"))
                if layout == "missing" { return }
                let payloadRoot = layout == "wrapper" || layout == "ambiguous"
                    ? extracted.appendingPathComponent("payload") : extracted
                try system.createDirectory(payloadRoot.appendingPathComponent("thumbnails"))
                try system.createDirectory(payloadRoot.appendingPathComponent("embedding_thumbnails"))
                try system.writeData(
                    layout == "invalid-root" ? Data("invalid JSON".utf8) : peopleData,
                    payloadRoot.appendingPathComponent("people.json")
                )
                try system.writeData(thumbnail, payloadRoot.appendingPathComponent("thumbnails/\(person.id.uuidString).jpg"))
                try system.writeData(embeddingThumbnail, payloadRoot.appendingPathComponent("embedding_thumbnails/\(sample.id.uuidString).jpg"))
                if ["root-precedence", "ambiguous", "invalid-root"].contains(layout) {
                    let otherRoot = extracted.appendingPathComponent("other-payload")
                    try system.createDirectory(otherRoot)
                    try system.writeData(otherPeopleData, otherRoot.appendingPathComponent("people.json"))
                }
            }
        ))

        let source = directory.appendingPathComponent("fixture.zip")
        switch layout {
        case "ambiguous", "missing":
            do {
                _ = try await service.prepareImport(sourceURL: source)
                Issue.record("Invalid archive layout was accepted")
            } catch {
                #expect((error as NSError).domain == "KnownPeopleService")
                #expect((error as NSError).code == (layout == "missing" ? 3 : 4))
            }
        case "invalid-root":
            await #expect(throws: DecodingError.self) {
                _ = try await service.prepareImport(sourceURL: source)
            }
        default:
            let payload = try await service.prepareImport(sourceURL: source)
            #expect(payload.people.map(\.id) == [person.id])
            #expect(payload.personThumbnails == [person.id: thumbnail])
            #expect(payload.embeddingThumbnails == [sample.id: embeddingThumbnail])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("Archive layout discovery stops after each cancelled filesystem probe", arguments: [
        "root", "enumeration", "directory", "wrapper"
    ])
    func archiveLayoutCancellation(stage: String) async throws {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = KnownPeopleArchiveFileAccess.system
        let candidate = directory.appendingPathComponent("wrapper", isDirectory: true)
        let service = KnownPeopleArchiveService(access: KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: system.createDirectory,
            removeItem: system.removeItem,
            contentsOfDirectory: { _ in
                #expect(!Task.isCancelled)
                if stage == "enumeration" { withUnsafeCurrentTask { $0?.cancel() } }
                return [candidate, directory.appendingPathComponent("another-wrapper")]
            },
            isDirectory: { _ in
                #expect(!Task.isCancelled)
                if stage == "directory" { withUnsafeCurrentTask { $0?.cancel() } }
                return true
            },
            itemExists: { url in
                #expect(!Task.isCancelled)
                let isWrapper = url.deletingLastPathComponent().standardizedFileURL.path
                    == candidate.standardizedFileURL.path
                if stage == "root" || (stage == "wrapper" && isWrapper) {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return isWrapper
            },
            readData: { _ in
                Issue.record("Cancelled discovery must not read a payload")
                return Data()
            },
            readCoordinatedData: { _ in throw CancellationError() },
            writeData: { _, _ in Issue.record("Cancelled discovery must not write files") },
            writeCoordinatedData: { _, _ in Issue.record("Cancelled discovery must not commit files") },
            runDitto: { _ in }
        ))
        let operation = Task { try await service.prepareImport(sourceURL: directory.appendingPathComponent("fixture.zip")) }
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("Archive thumbnail commits invalidate cached and suspended reads even after person write failure", arguments: Array(0..<16))
    func importInvalidatesThumbnailPublication(operation: Int) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let isEmbedding = operation % 2 == 1
        let pendingRead = operation % 4 >= 2
        let failPersonWrite = operation % 8 >= 4
        let sample = embedding(12)
        let person = KnownPerson(name: "Imported thumbnail", embeddings: [sample])
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        ))
        let oldImage = try #require(bitmap.representation(using: .png, properties: [:]))
        let replacement = Data([9, 8, 7])
        let peopleData = try encode([person])
        let gate = KnownPeopleThumbnailPublicationGate(data: oldImage)
        defer { gate.resume() }
        let access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: { _ in }, removeItem: { _ in },
            contentsOfDirectory: { _ in [] }, isDirectory: { _ in false },
            itemExists: { _ in true },
            readData: { $0.lastPathComponent == "people.json" ? peopleData : replacement },
            readCoordinatedData: { _ in replacement }, writeData: { _, _ in },
            writeCoordinatedData: { data, url in
                if failPersonWrite && url.pathExtension == "json" {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try data.write(to: url, options: .atomic)
            },
            runDitto: { _ in }
        )
        let service = KnownPeopleService(
            thumbnailLoader: KnownPeopleThumbnailLoadService(
                access: KnownPeopleThumbnailFileAccess(readData: { gate.read($0) })
            ),
            archiveService: KnownPeopleArchiveService(access: access)
        )
        _ = service.loadDatabase()
        let read: Task<NSImage?, Never>?
        if pendingRead {
            read = Task {
                if isEmbedding { return await service.loadEmbeddingThumbnail(for: sample.id) }
                return await service.loadThumbnail(for: person.id)
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while !gate.entered, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(gate.entered)
        } else {
            read = nil
            if isEmbedding {
                try service.saveEmbeddingThumbnail(oldImage, for: sample.id)
                #expect(service.cachedEmbeddingThumbnail(for: sample.id) != nil)
            } else {
                try service.saveThumbnail(oldImage, for: person.id)
                #expect(service.cachedThumbnail(for: person.id) != nil)
            }
        }
        let importer = operation >= 8
            ? KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
            : service
        do {
            let count = try await importer.importFromZip(sourceURL: directory.appendingPathComponent("archive.zip"))
            #expect(count == 1)
            #expect(!failPersonWrite)
        } catch {
            #expect(failPersonWrite)
        }
        gate.resume()
        if let read { #expect(await read.value == nil) }
        #expect((importer.person(byID: person.id) != nil) == !failPersonWrite)
        #expect(service.cachedThumbnail(for: person.id) == nil)
        #expect(service.cachedEmbeddingThumbnail(for: sample.id) == nil)
        let folder = isEmbedding ? "embedding_thumbnails" : "thumbnails"
        let id = isEmbedding ? sample.id : person.id
        #expect(try Data(contentsOf: directory.appendingPathComponent("\(folder)/\(id.uuidString).jpg")) == replacement)
    }

    @Test("late import publication retains concurrent additions edits and deletions", arguments: [0, 1, 2], [false, true])
    func importPreservesConcurrentCacheChanges(completion: Int, crossInstance: Bool) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let first = KnownPerson(name: "Imported first", embeddings: [])
        let second = KnownPerson(name: "Imported second", embeddings: [])
        let gate = KnownPeopleImportPublicationGate(failSecondWrite: completion == 1)
        defer { gate.resume() }
        let peopleData = try encode([first, first, second])
        let access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: { _ in }, removeItem: { _ in },
            contentsOfDirectory: { _ in [] }, isDirectory: { _ in false },
            itemExists: { $0.lastPathComponent == "people.json" },
            readData: { _ in peopleData }, readCoordinatedData: { _ in peopleData },
            writeData: { _, _ in },
            writeCoordinatedData: { data, url in try gate.write(data, to: url) },
            runDitto: { _ in }
        )
        let service = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
        _ = service.loadDatabase()
        var edited = try service.addPerson(name: "Before edit", embeddings: [])
        let deleted = try service.addPerson(name: "Delete during import", embeddings: [])
        let editor = crossInstance ? KnownPeopleService() : service
        _ = editor.loadDatabase()
        let task = Task { try await service.importFromZip(sourceURL: directory.appendingPathComponent("archive.zip")) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.entered)
        edited.name = "Edited during import"
        try editor.updatePerson(edited)
        try editor.removePerson(id: deleted.id)
        let added = try editor.addPerson(name: "Added during import", embeddings: [])
        if completion == 2 { task.cancel() }
        gate.resume()
        do {
            let count = try await task.value
            #expect(completion == 0)
            #expect(count == 2)
        } catch {
            #expect(completion != 0)
            if completion == 2 { #expect(error is CancellationError) }
        }
        let people = service.getAllPeople()
        #expect(people.first { $0.id == edited.id }?.name == "Edited during import")
        #expect(people.contains { $0.id == added.id })
        #expect(!people.contains { $0.id == deleted.id })
        #expect(people.contains { $0.id == first.id })
        #expect(people.contains { $0.id == second.id } == (completion == 0))
        #expect(Set(people.map(\.id)).count == people.count)
        #expect(Set(editor.getAllPeople().map(\.id)) == Set(people.map(\.id)))
        service.reloadAfterStorageChange(resolvedStorageURL: directory)
        #expect(Set(service.getAllPeople().map(\.id)) == Set(people.map(\.id)))
    }

    @Test("Archive destination reservations cover every service instance and preserve deferred deletion", arguments: [0, 1, 2, 3], [false, true])
    func importReservesDestinationPaths(completion: Int, crossInstance: Bool) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let sample = embedding(1)
        let person = KnownPerson(name: "Imported", embeddings: [sample])
        let data = try encode([person])
        let gate = KnownPeopleImportPublicationGate(failSecondWrite: false)
        defer { gate.resume() }
        let cleanup = KnownPeopleDeferredRemovalGate()
        defer { cleanup.resume() }
        var access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: { _ in }, removeItem: { _ in },
            contentsOfDirectory: { _ in [] }, isDirectory: { _ in false },
            itemExists: { $0.lastPathComponent == "people.json" || $0.pathExtension == "jpg" },
            readData: { $0.pathExtension == "jpg" ? Data([1, 2, 3]) : data },
            readCoordinatedData: { _ in data }, writeData: { _, _ in },
            writeCoordinatedData: { data, url in try gate.write(data, to: url) },
            runDitto: { _ in }
        )
        access.removeCoordinatedItem = { try cleanup.remove($0) }
        let service = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
        _ = service.loadDatabase()
        let writer = crossInstance ? KnownPeopleService() : service
        _ = writer.loadDatabase()
        let task = Task { try await service.importFromZip(sourceURL: directory.appendingPathComponent("archive.zip")) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(gate.entered)
        // The first thumbnail has reached disk; the embedding and record writes are still pending.
        let conflictingWrites: [() throws -> Void] = [
            { try writer.removePerson(id: person.id) },
            { try writer.saveThumbnail(Data([9]), for: person.id) },
            { try writer.saveEmbeddingThumbnail(Data([9]), for: sample.id) },
            { try writer.clearDatabase() }
        ]
        for write in conflictingWrites {
            do {
                try write()
                Issue.record("A local mutation overlapped the reserved archive destination")
            } catch {
                #expect((error as NSError).domain == "KnownPeopleService")
                #expect((error as NSError).code == 11)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("people/\(person.id.uuidString).deleted").path))
        let unrelated = try writer.addPerson(name: "Unrelated", embeddings: [])
        do {
            try writer.addEmbeddingsDeduped([sample], toPersonID: unrelated.id,
                                            embeddingThumbnails: [sample.id: Data([9])])
            Issue.record("An embedding mutation bypassed thumbnail admission")
        } catch {
            #expect((error as NSError).code == 11)
        }
        #expect(writer.person(byID: unrelated.id)?.embeddings.isEmpty == true)
        let persisted = try JSONDecoder().decode(KnownPerson.self, from: Data(contentsOf:
            directory.appendingPathComponent("people/\(unrelated.id.uuidString).json")
        ))
        #expect(persisted.embeddings.isEmpty)
        // A void deletion API cannot report busy. It must win after the actor's later write.
        writer.deleteEmbeddingThumbnail(for: sample.id)
        if completion == 1 { task.cancel() }
        gate.resume()
        let cleanupDeadline = ContinuousClock.now + .seconds(5)
        while !cleanup.entered, ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(cleanup.entered)
        // Cleanup yields MainActor but keeps the import reservation alive. A second
        // deletion queued during that suspension must be drained before admission opens.
        do {
            try writer.saveEmbeddingThumbnail(Data([9]), for: sample.id)
            Issue.record("A local write bypassed the reservation during cleanup")
        } catch {
            #expect((error as NSError).code == 11)
        }
        writer.deleteEmbeddingThumbnail(for: sample.id)
        if completion == 2 { task.cancel() }
        if completion == 3 {
            // Even re-resolving the same root invalidates the captured storage revision.
            service.reloadAfterStorageChange(resolvedStorageURL: directory)
        }
        cleanup.resume()
        do {
            #expect(try await task.value == 1)
            #expect(completion == 0)
        } catch {
            #expect(completion != 0 && error is CancellationError)
        }
        #expect(cleanup.removalCount == 2)
        #expect(!cleanup.observedMainThread)
        #expect(writer.person(byID: unrelated.id) != nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(
            "embedding_thumbnails/\(sample.id.uuidString).jpg"
        ).path))
        // Both normal completion and cancellation release admission for retry.
        try writer.saveEmbeddingThumbnail(Data([9]), for: sample.id)
        #expect(try Data(contentsOf: directory.appendingPathComponent(
            "embedding_thumbnails/\(sample.id.uuidString).jpg"
        )) == Data([9]))
        try writer.clearDatabase()
        #expect(writer.getAllPeople().isEmpty)
    }

    @Test("Archive admission preserves unreadable records and tombstoned identities", arguments: [false, true])
    func importPreservesOccupiedDestinations(tombstoned: Bool) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let person = KnownPerson(name: "Archived person", embeddings: [])
        let payload = try encode([person])
        let access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: { _ in }, removeItem: { _ in },
            contentsOfDirectory: { _ in [] }, isDirectory: { _ in false },
            itemExists: { $0.lastPathComponent == "people.json" || $0.pathExtension == "jpg" },
            readData: { $0.pathExtension == "jpg" ? Data([1, 2, 3]) : payload }, readCoordinatedData: { _ in payload },
            writeData: { _, _ in },
            writeCoordinatedData: { try CloudCoordinatedIO.writeData($0, to: $1) },
            runDitto: { _ in }
        )
        let service = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
        _ = service.loadDatabase()
        let occupiedURL = tombstoned
            ? tombstoneURL(person.id, in: directory)
            : personFileURL(person.id, in: directory)
        let original = tombstoned
            ? try encode(KnownPersonTombstone(id: person.id))
            : Data("unreadable original record".utf8)
        try original.write(to: occupiedURL)
        service.reloadAfterStorageChange(resolvedStorageURL: directory)
        #expect(service.getAllPeople().isEmpty)
        #expect(try await service.importFromZip(sourceURL: directory.appendingPathComponent("archive.zip")) == 0)
        #expect(try Data(contentsOf: occupiedURL) == original)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(
            "thumbnails/\(person.id.uuidString).jpg"
        ).path))
        #expect(service.getAllPeople().isEmpty)
        service.reloadAfterStorageChange(resolvedStorageURL: directory)
        #expect(service.getAllPeople().isEmpty)
    }

    @Test("Remote deletion from either service instance wins after archive publication", arguments: [false, true], Array(0..<8))
    func importDefersRemoteDeletion(cancelImport: Bool, mode: Int) async throws {
        let recordEvent = mode % 2 == 1
        let crossInstance = mode % 4 >= 2
        let pendingRead = mode >= 4
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let person = KnownPerson(name: "Imported", embeddings: [])
        let payload = try encode([person])
        let gate = KnownPeopleImportPublicationGate(failSecondWrite: false)
        defer { gate.resume() }
        let access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: { _ in }, removeItem: { _ in },
            contentsOfDirectory: { _ in [] }, isDirectory: { _ in false },
            itemExists: { $0.lastPathComponent == "people.json" },
            readData: { _ in payload }, readCoordinatedData: { _ in payload },
            writeData: { _, _ in },
            writeCoordinatedData: { try gate.write($0, to: $1) },
            runDitto: { _ in }
        )
        let service = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
        _ = service.loadDatabase()
        let observer = crossInstance ? KnownPeopleService() : service
        _ = observer.loadDatabase()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        ))
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        let thumbnailGate = KnownPeopleThumbnailPublicationGate(data: image)
        defer { thumbnailGate.resume() }
        let peer = KnownPeopleService(thumbnailLoader: KnownPeopleThumbnailLoadService(
            access: KnownPeopleThumbnailFileAccess(readData: { thumbnailGate.read($0) })
        ))
        let read: Task<NSImage?, Never>?
        if pendingRead {
            read = Task { await peer.loadThumbnail(for: person.id) }
            let deadline = ContinuousClock.now + .seconds(5)
            while !thumbnailGate.entered, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(thumbnailGate.entered)
        } else {
            read = nil
            try peer.saveThumbnail(image, for: person.id)
        }
        let task = Task { try await service.importFromZip(sourceURL: directory.appendingPathComponent("archive.zip")) }
        let deadline = ContinuousClock.now + .seconds(30)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(gate.entered)
        let marker = tombstoneURL(person.id, in: directory)
        try encode(KnownPersonTombstone(id: person.id)).write(to: marker)
        // Unknown change dates must not become self-write echoes when replayed.
        observer.applyRemoteChanges([(recordEvent ? personFileURL(person.id, in: directory) : marker, nil)])
        #expect(FileManager.default.fileExists(atPath: personFileURL(person.id, in: directory).path))
        if !pendingRead { #expect(peer.cachedThumbnail(for: person.id) != nil) }
        if cancelImport { task.cancel() }
        gate.resume()
        do {
            #expect(try await task.value == 1)
            #expect(!cancelImport)
        } catch {
            #expect(cancelImport && error is CancellationError)
        }
        thumbnailGate.resume()
        if let read { #expect(await read.value == nil) }
        #expect(peer.cachedThumbnail(for: person.id) == nil)
        #expect(service.person(byID: person.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: personFileURL(person.id, in: directory).path))
        #expect(FileManager.default.fileExists(atPath: marker.path))
        service.reloadAfterStorageChange(resolvedStorageURL: directory)
        #expect(service.person(byID: person.id) == nil)
    }

    @Test("Cancellation during destination admission stops before subsequent probes and writes")
    func importCancellationDuringDestinationProbe() async throws {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let person = KnownPerson(name: "Cancelled", embeddings: [])
        let access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: { _ in }, removeItem: { _ in },
            contentsOfDirectory: { _ in [] }, isDirectory: { _ in false },
            itemExists: { _ in false },
            readData: { _ in Data() }, readCoordinatedData: { _ in Data() },
            writeData: { _, _ in },
            writeCoordinatedData: { _, _ in Issue.record("Cancelled admission must not write") },
            runDitto: { _ in },
            destinationExists: { url in
                #expect(!Thread.isMainThread)
                #expect(url.pathExtension == "json")
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            }
        )
        let service = KnownPeopleArchiveService(access: access)
        let operation = Task {
            await service.commitImport(KnownPeopleArchiveImportCommitRequest(
                requestID: UUID(), storageRoot: directory, people: [person],
                personThumbnails: [person.id: Data([1])], embeddingThumbnails: [:]
            ))
        }
        guard case .cancelled(let evidence) = await operation.value else {
            Issue.record("Expected cancellation during destination admission")
            return
        }
        #expect(evidence.committedPeople.isEmpty)
        #expect(evidence.committedFileURLs.isEmpty)
        #expect(evidence.committedThumbnailURLs.isEmpty)
    }

    @Test("Imports across service instances publish before readmission and reject cancelled or rerouted waiters", arguments: [0, 1, 2], [false, true])
    func overlappingImportAdmission(outcome: Int, crossInstance: Bool) async throws {
        let directory = makeTempDir()
        activate(directory)
        defer { teardown(directory) }
        let person = KnownPerson(name: "Imported once", embeddings: [])
        let data = try encode([person])
        let gate = KnownPeopleImportPublicationGate(failSecondWrite: false)
        defer { gate.resume() }
        let access = KnownPeopleArchiveFileAccess(
            temporaryDirectory: directory,
            createDirectory: { _ in }, removeItem: { _ in },
            contentsOfDirectory: { _ in [] }, isDirectory: { _ in false },
            itemExists: { $0.lastPathComponent == "people.json" },
            readData: { _ in gate.recordRead(); return data },
            readCoordinatedData: { _ in data },
            writeData: { _, _ in },
            writeCoordinatedData: { data, url in try gate.write(data, to: url) },
            runDitto: { _ in }
        )
        let service = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
        _ = service.loadDatabase()
        let secondService = crossInstance
            ? KnownPeopleService(archiveService: KnownPeopleArchiveService(access: access))
            : service
        _ = secondService.loadDatabase()
        let source = directory.appendingPathComponent("archive.zip")
        let first = Task { try await service.importFromZip(sourceURL: source) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(gate.entered)
        // This continuation resumes only once the second task has started on MainActor.
        var second: Task<Int, any Error>!
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            second = Task {
                started.resume()
                return try await secondService.importFromZip(sourceURL: source)
            }
        }
        #expect(gate.reads == 1)
        if outcome == 1 { second.cancel() }
        if outcome == 2 {
            service.reloadAfterStorageChange(resolvedStorageURL: directory)
            if crossInstance { secondService.reloadAfterStorageChange(resolvedStorageURL: directory) }
        }
        gate.resume()
        do {
            #expect(try await first.value == 1)
            #expect(outcome != 2)
        } catch {
            #expect(outcome == 2 && error is CancellationError)
        }
        do {
            #expect(try await second.value == 0)
            #expect(outcome == 0)
        } catch {
            #expect(outcome != 0 && error is CancellationError)
        }
        #expect(gate.reads == (outcome == 0 ? 2 : 1))
        #expect(gate.writes == 1)
        #expect(service.getAllPeople().map(\.id) == [person.id])
        // Releasing a cancelled/rerouted waiter must not strand later requests.
        #expect(try await service.importFromZip(sourceURL: source) == 0)
        service.reloadAfterStorageChange(resolvedStorageURL: directory)
        #expect(service.getAllPeople().map(\.id) == [person.id])
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
    func interruptedMergeIsRecoverableAndIdempotent() async throws {
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

        await #expect(throws: DurableDeletionError.self) {
            try await KnownPeopleService.shared.mergePeople(sourceID: source.id, intoTargetID: target.id)
        }
        #expect(KnownPeopleService.shared.person(byID: source.id) != nil)
        #expect(KnownPeopleService.shared.person(byID: target.id)?.embeddings.count == 2)
        #expect(FileManager.default.fileExists(atPath: personFileURL(source.id, in: dir).path))

        KnownPeopleService.deletionIO = .live
        try await KnownPeopleService.shared.mergePeople(sourceID: source.id, intoTargetID: target.id)
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

/// The first durable archive write is paused to interleave MainActor CRUD deterministically.
private nonisolated final class KnownPeopleImportPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didEnter = false
    private var writeCount = 0
    private var readCount = 0
    private let failSecondWrite: Bool

    init(failSecondWrite: Bool) { self.failSecondWrite = failSecondWrite }

    var entered: Bool { lock.withLock { didEnter } }
    var reads: Int { lock.withLock { readCount } }
    var writes: Int { lock.withLock { writeCount } }
    func recordRead() { lock.withLock { readCount += 1 } }
    func resume() { semaphore.signal() }

    func write(_ data: Data, to url: URL) throws {
        let count = lock.withLock { writeCount += 1; return writeCount }
        if count == 2, failSecondWrite { throw CocoaError(.fileWriteNoPermission) }
        try CloudCoordinatedIO.writeData(data, to: url)
        if count == 1 {
            lock.withLock { didEnter = true }
            guard semaphore.wait(timeout: .now() + 30) == .success else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
}

/// Holds one thumbnail read while MainActor performs a conflicting local mutation.
private nonisolated final class KnownPeopleThumbnailPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let data: Data
    private var didEnter = false

    init(data: Data) { self.data = data }
    var entered: Bool { lock.withLock { didEnter } }
    func resume() { semaphore.signal() }
    func read(_ url: URL) -> Data? {
        lock.withLock { didEnter = true }
        guard semaphore.wait(timeout: .now() + 5) == .success else { return nil }
        return data
    }
}

@Suite("Known People conflict preservation")
@MainActor
struct KnownPeopleConflictPreservationTests {
    @Test("Unreadable inputs and mismatched identities preserve every conflict", arguments: ["currentRead", "currentDecode", "versionRead", "versionDecode", "currentID", "versionID", "allUnreadable"])
    func preservesInvalidInputs(failure: String) throws {
        let person = KnownPerson(name: "Current")
        let currentURL = URL(fileURLWithPath: "/people/\(person.id.uuidString).json")
        let versionURL = URL(fileURLWithPath: "/versions/conflict")
        let encoded = try JSONEncoder().encode(person)
        let other = try JSONEncoder().encode(KnownPerson(name: "Unrelated"))
        var writes = 0
        var resolutions = 0
        let access = KnownPeopleConflictAccess(
            versions: { _ in [KnownPeopleConflictVersion(url: versionURL, resolve: { resolutions += 1 })] },
            readCurrent: { _ in
                if failure == "currentRead" || failure == "allUnreadable" { throw CocoaError(.fileReadUnknown) }
                if failure == "currentDecode" { return Data([0]) }
                return failure == "currentID" ? other : encoded
            },
            readVersion: { _ in
                if failure == "versionRead" || failure == "allUnreadable" { throw CocoaError(.fileReadUnknown) }
                if failure == "versionDecode" { return Data([0]) }
                return failure == "versionID" ? other : encoded
            },
            writePerson: { _ in writes += 1 }
        )
        #expect(KnownPeopleService().resolveConflicts(at: currentURL, access: access) == nil)
        #expect(writes == 0)
        #expect(resolutions == 0)
    }

    @Test("A failed durable write never resolves conflicts or publishes the merge")
    func failedWritePreservesVersions() throws {
        let person = KnownPerson(name: "Current")
        let encoded = try JSONEncoder().encode(person)
        let url = URL(fileURLWithPath: "/people/\(person.id.uuidString).json")
        var resolutions = 0
        var writes = 0
        let access = KnownPeopleConflictAccess(
            versions: { _ in [KnownPeopleConflictVersion(url: url, resolve: { resolutions += 1 })] },
            readCurrent: { _ in encoded },
            readVersion: { _ in encoded },
            writePerson: { _ in writes += 1; throw CocoaError(.fileWriteNoPermission) }
        )
        #expect(KnownPeopleService().resolveConflicts(at: url, access: access) == nil)
        #expect(writes == 1)
        #expect(resolutions == 0)
    }

    @Test("Only captured versions resolve, after the merged record is durable", arguments: [false, true])
    func durableMergePrecedesCleanup(cleanupFails: Bool) throws {
        let person = KnownPerson(name: "Current", updatedAt: Date(timeIntervalSince1970: 1))
        var newer = person
        newer.name = "Merged"
        newer.updatedAt = Date(timeIntervalSince1970: 2)
        let currentData = try JSONEncoder().encode(person)
        let versionData = try JSONEncoder().encode(newer)
        let url = URL(fileURLWithPath: "/people/\(person.id.uuidString).json")
        var events: [String] = []
        var durable: KnownPerson?
        var incomingVersionResolved = false
        let incoming = KnownPeopleConflictVersion(url: url) { incomingVersionResolved = true }
        var versions = [KnownPeopleConflictVersion(url: url) {
            #expect(durable?.name == "Merged")
            events.append("resolve")
            if cleanupFails { throw CocoaError(.fileWriteUnknown) }
        }]
        let access = KnownPeopleConflictAccess(
            versions: { _ in events.append("capture"); return versions },
            readCurrent: { _ in currentData },
            readVersion: { _ in versionData },
            writePerson: { merged in
                events.append("write")
                durable = merged
                versions.append(incoming)
            }
        )
        let merged = KnownPeopleService().resolveConflicts(at: url, access: access)
        #expect(merged?.name == "Merged")
        #expect(events == ["capture", "write", "resolve"])
        #expect(!incomingVersionResolved)
    }
}

/// Pauses the first deferred removal to exercise MainActor reentrancy during cleanup.
private nonisolated final class KnownPeopleDeferredRemovalGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    private var mainThread = false

    var entered: Bool { lock.withLock { count > 0 } }
    var removalCount: Int { lock.withLock { count } }
    var observedMainThread: Bool { lock.withLock { mainThread } }
    func resume() { semaphore.signal() }

    func remove(_ url: URL) throws {
        let current = lock.withLock {
            count += 1
            mainThread = mainThread || Thread.isMainThread
            return count
        }
        if current == 1 {
            guard semaphore.wait(timeout: .now() + 30) == .success else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try CloudCoordinatedIO.removeItem(at: url)
    }
}

private nonisolated enum KnownPeopleEditTaskContext {
    @TaskLocal static var root: URL?
}

@Suite("Known People read Dispatch executors")
struct KnownPeopleReadExecutorTests {
    @Test("Thumbnail reads and preparation preserve task context and cancellation",
          arguments: ["complete", "beforeRead", "read", "prepare"])
    @MainActor
    func thumbnailContext(stage: String) async {
        let url = URL(fileURLWithPath: "/virtual/known-people/thumbnail.jpg")
        let requestID = UUID()
        let queue = DispatchSerialQueue(label: "test.known-people.thumbnail.\(stage)")
        let check: @Sendable () -> Void = {
            #expect(!Thread.isMainThread)
            #expect(queue.isIsolatingCurrentContext() == true)
            #expect(KnownPeopleReadContext.marker == url)
            #expect(Task.currentPriority >= .userInitiated)
        }
        let service = KnownPeopleThumbnailLoadService(access: KnownPeopleThumbnailFileAccess(
            readData: { readURL in
                check()
                #expect(stage != "beforeRead")
                #expect(readURL == url)
                if stage == "read" { withUnsafeCurrentTask { $0?.cancel() } }
                return Data([1])
            }, prepareJPEGData: { data in
                check()
                #expect(stage != "read" && stage != "beforeRead")
                #expect(data == Data([1]))
                if stage == "prepare" { withUnsafeCurrentTask { $0?.cancel() } }
                return Data([2])
            }
        ), filesystemQueue: queue)
        let result = await Task(priority: .userInitiated) {
            await KnownPeopleReadContext.$marker.withValue(url) {
                if stage == "beforeRead" { withUnsafeCurrentTask { $0?.cancel() } }
                return await service.load(fileURL: url, requestID: requestID, prepareForReplacement: true)
            }
        }.value
        switch stage {
        case "complete":
            #expect(result == .loaded(KnownPeopleThumbnailLoadSnapshot(
                requestID: requestID, fileURL: url, data: Data([2])
            )))
        case "beforeRead":
            #expect(result == .cancelledBeforeRead(requestID: requestID, fileURL: url))
        default:
            #expect(result == .cancelledAfterRead(requestID: requestID, fileURL: url))
        }
    }

    @Test("Storage measurement retains its worker and rejects cancelled partial counts",
          arguments: ["complete", "unavailable", "beforeRead", "duringRead"])
    @MainActor
    func measurementContext(stage: String) async {
        let root = URL(fileURLWithPath: "/virtual/known-people/summary")
        let queue = DispatchSerialQueue(label: "test.known-people.summary.\(stage)")
        let service = KnownPeopleDataSummaryService(measureDirectory: { url in
            #expect(!Thread.isMainThread)
            #expect(queue.isIsolatingCurrentContext() == true)
            #expect(KnownPeopleReadContext.marker == root)
            #expect(Task.currentPriority >= .userInitiated)
            #expect(url == root)
            #expect(stage != "beforeRead")
            if stage == "duringRead" { withUnsafeCurrentTask { $0?.cancel() } }
            return stage == "unavailable" ? .unavailable : .complete(123)
        }, filesystemQueue: queue)
        let result = await Task(priority: .userInitiated) {
            await KnownPeopleReadContext.$marker.withValue(root) {
                if stage == "beforeRead" { withUnsafeCurrentTask { $0?.cancel() } }
                return await service.summarize(peopleCount: 2, sampleCount: 3,
                    storageURL: root, syncEnabled: true)
            }
        }.value
        if stage == "beforeRead" || stage == "duringRead" {
            #expect(result == .cancelled)
        } else {
            #expect(result == .complete(KnownPeopleDataSummary(peopleCount: 2, sampleCount: 3,
                storedBytes: stage == "unavailable" ? nil : 123, syncEnabled: true)))
        }
    }
}

private nonisolated enum KnownPeopleReadContext {
    @TaskLocal static var marker: URL?
}
