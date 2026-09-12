import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Known People immutable cloud generations", .serialized)
struct KnownPeopleCloudGenerationPublisherTests {
    private enum Injected: Error { case failure }

    private func temporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/KnownPeopleCloudGeneration-\(UUID().uuidString)",
                       isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func fixtureFiles() throws -> [String: Data] {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PeopleLibraryV2")
        let names = [
            "manifest.json": "manifest.json.base64",
            "people.json": "people.json.base64",
            "editor/photo-agent.json": "editor-photo-agent.json.base64",
            "embeddings/cccccccc-cccc-cccc-cccc-cccccccccccc.fem2": "embedding.fem2.base64",
        ]
        return try names.reduce(into: [:]) { result, pair in
            let text = try String(contentsOf: fixture.appendingPathComponent(pair.value),
                                  encoding: .utf8)
            result[pair.key] = Data(base64Encoded:
                text.components(separatedBy: .whitespacesAndNewlines).joined())
        }
    }

    private func snapshot(in parent: URL) async throws -> KnownPeoplePackageSnapshot {
        let source = parent.appendingPathComponent("source.aagedalpeople", isDirectory: true)
        for (path, bytes) in try fixtureFiles() {
            let destination = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: destination)
        }
        return try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
    }

    private func installManaged(_ snapshot: KnownPeoplePackageSnapshot, at root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let route = KnownPeopleManagedStoreRoute(rootURL: root, generation: 0,
                                                  iCloudSyncActive: false, routingActive: false)
        let replacement = KnownPeopleManagedStoreReplacement()
        let plan = try await replacement.plan(snapshot: snapshot, route: route)
        let result = await replacement.replace(plan: plan, decision: .replaceUntracked,
                                               currentRoute: route)
        #expect(result.committed && result.failure == nil && result.installedState != nil)
    }

    @Test("Publication activates one exact generation and excludes stale cloud records")
    func publishesExactGeneration() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cloud = parent.appendingPathComponent("cloud", isDirectory: true)
        let stale = cloud.appendingPathComponent("people/stale.json")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: stale)
        let admitted = try await snapshot(in: parent)
        let generationID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        var access = KnownPeopleCloudGenerationAccess()
        access.makeGenerationID = { generationID }
        let publisher = KnownPeopleCloudGenerationPublisher(access: access)

        let result = try await publisher.publish(snapshot: admitted, cloudRootURL: cloud)

        #expect(result.destinationURL.resolvingSymlinksInPath().path
            == cloud.appendingPathComponent("generations", isDirectory: true)
                .appendingPathComponent(generationID.uuidString.lowercased(), isDirectory: true)
                .resolvingSymlinksInPath().path)
        #expect(try await publisher.resolveActiveGeneration(in: cloud) == result.destinationURL)
        #expect(!FileManager.default.fileExists(atPath:
            result.destinationURL.appendingPathComponent("people/stale.json").path))
        let state = try KnownPeopleManagedStoreState.decode(Data(contentsOf:
            result.destinationURL.appendingPathComponent(KnownPeopleManagedStoreState.fileName)))
        #expect(!state.needsCloudReconciliation)
        #expect(state.currentRevision == admitted.manifest.revision)
        #expect(try KnownPeopleCloudGenerationPointer.decode(Data(contentsOf:
            cloud.appendingPathComponent(KnownPeopleCloudGenerationPointer.fileName))) == result.pointer)
    }

    @Test("A failed later generation never replaces the active pointer")
    func prepublicationFailureKeepsPriorGeneration() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cloud = parent.appendingPathComponent("cloud", isDirectory: true)
        let admitted = try await snapshot(in: parent)
        let firstID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        var firstAccess = KnownPeopleCloudGenerationAccess()
        firstAccess.makeGenerationID = { firstID }
        let firstPublisher = KnownPeopleCloudGenerationPublisher(access: firstAccess)
        let first = try await firstPublisher.publish(snapshot: admitted, cloudRootURL: cloud)
        let pointerURL = cloud.appendingPathComponent(KnownPeopleCloudGenerationPointer.fileName)
        let originalPointer = try Data(contentsOf: pointerURL)

        var failingAccess = KnownPeopleCloudGenerationAccess()
        failingAccess.makeGenerationID = {
            UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        }
        failingAccess.beforePointerPublication = { throw Injected.failure }
        let failingPublisher = KnownPeopleCloudGenerationPublisher(access: failingAccess)

        await #expect(throws: Injected.failure) {
            try await failingPublisher.publish(snapshot: admitted, cloudRootURL: cloud)
        }
        #expect(try Data(contentsOf: pointerURL) == originalPointer)
        #expect(try await firstPublisher.resolveActiveGeneration(in: cloud) == first.destinationURL)
    }

    @Test("Publication refuses to reuse an existing generation identifier")
    func generationIdentifiersAreWriteOnce() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cloud = parent.appendingPathComponent("cloud", isDirectory: true)
        let admitted = try await snapshot(in: parent)
        let generationID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        var access = KnownPeopleCloudGenerationAccess()
        access.makeGenerationID = { generationID }
        let publisher = KnownPeopleCloudGenerationPublisher(access: access)
        let first = try await publisher.publish(snapshot: admitted, cloudRootURL: cloud)
        let originalPointer = try Data(contentsOf:
            cloud.appendingPathComponent(KnownPeopleCloudGenerationPointer.fileName))

        await #expect(throws: KnownPeopleCloudGenerationFailure.publicationFailed) {
            try await publisher.publish(snapshot: admitted, cloudRootURL: cloud)
        }
        #expect(try Data(contentsOf:
            cloud.appendingPathComponent(KnownPeopleCloudGenerationPointer.fileName)) == originalPointer)
        #expect(try await publisher.resolveActiveGeneration(in: cloud) == first.destinationURL)
    }

    @Test("Cancellation during pointer commit still returns durable publication evidence")
    func cancellationDuringPointerCommitIsTruthful() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cloud = parent.appendingPathComponent("cloud", isDirectory: true)
        let admitted = try await snapshot(in: parent)
        var access = KnownPeopleCloudGenerationAccess()
        access.writeData = { bytes, url in
            try CloudCoordinatedIO.writeData(bytes, to: url)
            if url.lastPathComponent == KnownPeopleCloudGenerationPointer.fileName {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let publisher = KnownPeopleCloudGenerationPublisher(access: access)

        let publication = try await Task {
            try await publisher.publish(snapshot: admitted, cloudRootURL: cloud)
        }.value

        #expect(try await publisher.resolveActiveGeneration(in: cloud)
            == publication.destinationURL)
    }

    @Test("Pointer admission rejects unknown keys and a damaged activation package")
    func strictPointerAndGenerationValidation() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cloud = parent.appendingPathComponent("cloud", isDirectory: true)
        let admitted = try await snapshot(in: parent)
        let publisher = KnownPeopleCloudGenerationPublisher()
        let publication = try await publisher.publish(snapshot: admitted, cloudRootURL: cloud)
        let pointerURL = cloud.appendingPathComponent(KnownPeopleCloudGenerationPointer.fileName)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: pointerURL))
            as? [String: Any])
        object["unexpected"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: pointerURL, options: .atomic)
        await #expect(throws: KnownPeopleCloudGenerationFailure.malformedPointer) {
            try await publisher.resolveActiveGeneration(in: cloud)
        }

        try publication.pointer.encoded().write(to: pointerURL, options: .atomic)
        // The activated generation is the live cloud store. Intentional edits after activation
        // do not invalidate its pointer or resurrect anything from the previous generation.
        try Data("tampered".utf8).write(to:
            publication.destinationURL.appendingPathComponent(
                "people/BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB.json"))
        #expect(try await publisher.resolveActiveGeneration(in: cloud)
            == publication.destinationURL)

        // The retained activation package remains immutable authority for the pointer.
        try Data("tampered".utf8).write(to:
            publication.destinationURL.appendingPathComponent(
                ".admitted-package/people.json"))
        await #expect(throws: KnownPeopleCloudGenerationFailure.invalidGeneration) {
            try await publisher.resolveActiveGeneration(in: cloud)
        }
    }

    @Test("Service refreshes local authority, publishes cloud, then clears the local gate")
    @MainActor
    func completeServiceReconciliation() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let local = parent.appendingPathComponent("local", isDirectory: true)
        let cloud = parent.appendingPathComponent("cloud", isDirectory: true)
        let admitted = try await snapshot(in: parent)
        try await installManaged(admitted, at: local)
        #expect(try KnownPeopleManagedStoreState.requiresCloudReconciliation(at: local))

        let previousOverride = KnownPeopleService.storageOverrideURL
        KnownPeopleService.storageOverrideURL = local
        let service = KnownPeopleService()
        service.reloadAfterStorageChange(resolvedStorageURL: local)
        defer {
            KnownPeopleService.storageOverrideURL = previousOverride
            service.reloadAfterStorageChange(resolvedStorageURL: previousOverride)
        }
        let generationID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        var access = KnownPeopleCloudGenerationAccess()
        access.makeGenerationID = { generationID }
        let publisher = KnownPeopleCloudGenerationPublisher(access: access)

        let result = await service.reconcileLocalManagedStoreToCloud(
            exportedAt: admitted.manifest.exportedAt,
            exporter: admitted.manifest.exporter,
            cloudRootURL: cloud,
            routeMutationGate: KnownPeopleRouteMutationGate(),
            publisher: publisher
        )

        #expect(result.cloudPublished && result.verified && result.failure == nil)
        #expect(result.destinationURL == (try await publisher.resolveActiveGeneration(in: cloud)))
        #expect(try !KnownPeopleManagedStoreState.requiresCloudReconciliation(at: local))
        let localState = try KnownPeopleManagedStoreState.decode(Data(contentsOf:
            local.appendingPathComponent(KnownPeopleManagedStoreState.fileName)))
        let cloudState = try KnownPeopleManagedStoreState.decode(Data(contentsOf:
            try #require(result.destinationURL).appendingPathComponent(
                KnownPeopleManagedStoreState.fileName)))
        #expect(localState.libraryID == cloudState.libraryID)
        #expect(localState.currentRevision == cloudState.currentRevision)
        #expect(localState.managedProjectionSHA256 == cloudState.managedProjectionSHA256)
        #expect(!localState.needsCloudReconciliation && !cloudState.needsCloudReconciliation)
    }
}
