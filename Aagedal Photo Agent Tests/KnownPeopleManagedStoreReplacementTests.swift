import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Known People managed-store replacement", .serialized)
struct KnownPeopleManagedStoreReplacementTests {
    private enum Injected: Error { case failure }

    @Test("Managed directory enumeration distinguishes failure from EOF")
    func directoryEnumerationFailureIsNotEOF() throws {
        #expect(throws: KnownPeopleManagedStoreFailure.io) {
            _ = try KnownPeopleManagedDirectoryReader.next {
                errno = EIO
                return nil
            }
        }
        #expect(try KnownPeopleManagedDirectoryReader.next { nil } == nil)
    }

    @Test("Whole-root inventory accounting accepts its exact limits and refuses overflow")
    func wholeRootInventoryAccountingBoundary() throws {
        var entries = KnownPeopleManagedEnumerationBudget.wholeManagedRoot
        for _ in 0..<entries.maximumEntries {
            try entries.accountEntry(byteCount: 0)
        }
        #expect(entries.entryCount == 410_010)
        #expect(throws: KnownPeopleManagedStoreFailure.unsafeEntry) {
            try entries.accountEntry(byteCount: 0)
        }

        var bytes = KnownPeopleManagedEnumerationBudget.wholeManagedRoot
        try bytes.accountEntry(byteCount: bytes.maximumBytes)
        #expect(bytes.byteCount == 1_500_000_000)
        #expect(throws: KnownPeopleManagedStoreFailure.unsafeEntry) {
            try bytes.accountEntry(byteCount: 1)
        }

        #expect(KnownPeopleManagedEnumerationBudget.projection.maximumEntries == 200_100)
        #expect(KnownPeopleManagedEnumerationBudget.projection.maximumBytes == 600_000_000)
    }

    private func temporaryDirectory() throws -> URL {
        let parent = URL(fileURLWithPath: "/private/tmp/KnownPeopleManaged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        return parent
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
            let text = try String(contentsOf: fixture.appendingPathComponent(pair.value), encoding: .utf8)
            result[pair.key] = try #require(Data(base64Encoded:
                text.components(separatedBy: .whitespacesAndNewlines).joined()))
        }
    }

    private func put(_ files: [String: Data], at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, bytes) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
    }

    private func makeManagedRoot(in parent: URL) throws -> URL {
        let root = parent.appendingPathComponent("KnownPeople", isDirectory: true)
        for name in ["people", "thumbnails", "embedding_thumbnails"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        try Data("old person".utf8).write(to: root.appendingPathComponent("people/old.json"))
        return root
    }

    private func snapshot(in parent: URL, files: [String: Data]? = nil) async throws -> KnownPeoplePackageSnapshot {
        let source = parent.appendingPathComponent("source.aagedalpeople", isDirectory: true)
        try put(files ?? fixtureFiles(), at: source)
        return try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
    }

    private func route(_ root: URL, generation: UInt64 = 1,
                       cloud: Bool = false, routing: Bool = false) -> KnownPeopleManagedStoreRoute {
        .init(rootURL: root, generation: generation, iCloudSyncActive: cloud, routingActive: routing)
    }

    private func treeFiles(_ root: URL) throws -> [String: Data] {
        let fm = FileManager.default
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard let values = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var result: [String: Data] = [:]
        while let url = values.nextObject() as? URL {
            var directory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue {
                let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                    .dropFirst(base.count).joined(separator: "/")
                result[path] = try Data(contentsOf: url)
            }
        }
        return result
    }

    @Test("Planning is nonmutating and classifies an untracked local root")
    func nonmutatingUntrackedPlan() async throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let admitted = try await snapshot(in: parent)
        let before = try treeFiles(root)

        let plan = try await KnownPeopleManagedStoreReplacement().plan(snapshot: admitted, route: route(root))

        #expect(plan.requiredDecision == .replaceUntracked)
        #expect(plan.priorState == nil)
        #expect(try treeFiles(root) == before)
    }

    @Test("Replacement installs a complete projection, preserves raw bytes and retains the old tree")
    func exactReplacementAndRecovery() async throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let old = try treeFiles(root)
        let admitted = try await snapshot(in: parent)
        actor Invalidations { var roots: [URL] = []; func add(_ root: URL) { roots.append(root) } }
        let invalidations = Invalidations()
        var access = KnownPeopleManagedStoreReplacementAccess()
        access.invalidateAfterCommit = { root in await invalidations.add(root) }
        let service = KnownPeopleManagedStoreReplacement(access: access)
        let plan = try await service.plan(snapshot: admitted, route: route(root))

        let result = await service.replace(plan: plan, decision: .replaceUntracked, currentRoute: route(root))

        #expect(result.committed && result.failure == nil && !result.wasCancelled)
        #expect(result.revision == admitted.manifest.revision)
        let recovery = try #require(result.recoveryDirectory)
        let recovered = try treeFiles(recovery)
        #expect(recovered == old)
        #expect(try await service.admittedPackageFiles(root: root) == admitted.files)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "people/BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB.json").path))
        #expect(await invalidations.roots == [root.standardizedFileURL])
        #expect(KnownPeopleManagedStoreState.protectsCurrentEmbeddingStore(at: root))
    }

    @Test("Installed identity drives same-library and different-library decisions")
    func identityDecisions() async throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let admitted = try await snapshot(in: parent)
        let service = KnownPeopleManagedStoreReplacement()
        let initial = try await service.plan(snapshot: admitted, route: route(root))
        let installed = await service.replace(plan: initial, decision: .replaceUntracked, currentRoute: route(root))
        #expect(installed.committed && installed.failure == nil)

        let same = try await service.plan(snapshot: admitted, route: route(root))
        #expect(same.requiredDecision == .replaceSameLibrary)

        let files = try fixtureFiles()
        let manifestData = try #require(files["manifest.json"])
        let manifest = String(decoding: manifestData, as: UTF8.self)
        let changed = manifest.replacingOccurrences(of:
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", with: "dddddddd-dddd-dddd-dddd-dddddddddddd")
        // Changing only the identity invalidates declared revisions, so construct a second valid empty snapshot.
        let other = try await emptySnapshot(in: parent, libraryID: UUID(uuidString:
            "dddddddd-dddd-dddd-dddd-dddddddddddd")!, suffix: changed.count)
        let different = try await service.plan(snapshot: other, route: route(root))
        #expect(different.requiredDecision == .replaceDifferentLibrary)
    }

    @Test("Stale inventory, changed routing and the wrong explicit decision are refused")
    func staleAdmissionIsRefused() async throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let admitted = try await snapshot(in: parent)
        let service = KnownPeopleManagedStoreReplacement()
        let first = try await service.plan(snapshot: admitted, route: route(root))
        try Data("changed".utf8).write(to: root.appendingPathComponent("people/late.json"))
        let stale = await service.replace(plan: first, decision: .replaceUntracked, currentRoute: route(root))
        #expect(!stale.committed && stale.failure?.contains("changed") == true)

        let second = try await service.plan(snapshot: admitted, route: route(root))
        let rerouted = await service.replace(plan: second, decision: .replaceUntracked,
                                             currentRoute: route(root, generation: 2))
        #expect(!rerouted.committed && rerouted.failure?.contains("route changed") == true)
        let wrong = await service.replace(plan: second, decision: .replaceSameLibrary, currentRoute: route(root))
        #expect(!wrong.committed && wrong.failure?.contains("confirmation") == true)
    }

    @Test("Malformed root identity and active cloud routing block before mutation")
    func malformedAndCloudRefusal() async throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let admitted = try await snapshot(in: parent)
        try Data("{\"format\":\"forged\"}".utf8).write(to:
            root.appendingPathComponent(KnownPeopleManagedStoreState.fileName))
        let service = KnownPeopleManagedStoreReplacement()
        await #expect(throws: KnownPeopleManagedStoreFailure.malformedState) {
            try await service.plan(snapshot: admitted, route: route(root))
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent(KnownPeopleManagedStoreState.fileName))
        await #expect(throws: KnownPeopleManagedStoreFailure.activeICloudOrRouting) {
            try await service.plan(snapshot: admitted, route: route(root, cloud: true))
        }
        await #expect(throws: KnownPeopleManagedStoreFailure.activeICloudOrRouting) {
            try await service.plan(snapshot: admitted, route: route(root, routing: true))
        }
    }

    @Test("State authority refuses symlinks and projection tampering")
    func stateSymlinkAndProjectionTamper() async throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let admitted = try await snapshot(in: parent)
        let service = KnownPeopleManagedStoreReplacement()
        let plan = try await service.plan(snapshot: admitted, route: route(root))
        let installed = await service.replace(plan: plan, decision: .replaceUntracked,
                                              currentRoute: route(root))
        #expect(installed.committed && installed.failure == nil)
        #expect(KnownPeopleManagedStoreState.protectsCurrentEmbeddingStore(at: root))

        let stateURL = root.appendingPathComponent(KnownPeopleManagedStoreState.fileName)
        let stateData = try Data(contentsOf: stateURL)
        let outsideState = parent.appendingPathComponent("saved-state.json")
        try stateData.write(to: outsideState)
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createSymbolicLink(at: stateURL, withDestinationURL: outsideState)
        #expect(!KnownPeopleManagedStoreState.protectsCurrentEmbeddingStore(at: root))
        await #expect(throws: KnownPeopleManagedStoreFailure.unsafeEntry) {
            try await service.plan(snapshot: admitted, route: route(root))
        }

        try FileManager.default.removeItem(at: stateURL)
        try stateData.write(to: stateURL)
        let rawManifest = root.appendingPathComponent(".admitted-package/manifest.json")
        let rawManifestData = try Data(contentsOf: rawManifest)
        let presentationOnlyChange = String(decoding: rawManifestData, as: UTF8.self)
            .replacingOccurrences(of: "2026-09-12T13:30:00.000Z", with: "2026-09-12T13:31:00.000Z")
        try Data(presentationOnlyChange.utf8).write(to: rawManifest)
        await #expect(throws: KnownPeopleManagedStoreFailure.invalidSnapshot) {
            try await service.admittedPackageFiles(root: root)
        }
        try rawManifestData.write(to: rawManifest)

        #expect(try KnownPeopleManagedStoreState.requiresCloudReconciliation(at: root))
        try Data("tampered".utf8).write(to: root.appendingPathComponent(
            "people/BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB.json"))
        #expect(!KnownPeopleManagedStoreState.protectsCurrentEmbeddingStore(at: root))
        #expect(try KnownPeopleManagedStoreState.requiresCloudReconciliation(at: root))
        await #expect(throws: KnownPeopleManagedStoreFailure.invalidSnapshot) {
            try await service.admittedPackageFiles(root: root)
        }
    }

    @Test("A stage mutated after its first readback is refused before publication")
    func stageMutationBeforeCommit() async throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let before = try treeFiles(root)
        let admitted = try await snapshot(in: parent)
        var access = KnownPeopleManagedStoreReplacementAccess()
        access.beforeCommit = {
            guard let stage = try FileManager.default.contentsOfDirectory(at: parent,
                includingPropertiesForKeys: nil).first(where: {
                    $0.lastPathComponent.hasPrefix(".KnownPeople-replacement-")
            }) else { throw Injected.failure }
            try Data("mutated after readback".utf8).write(to: stage.appendingPathComponent(
                "people/BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB.json"))
        }
        let service = KnownPeopleManagedStoreReplacement(access: access)
        let plan = try await service.plan(snapshot: admitted, route: route(root))

        let result = await service.replace(plan: plan, decision: .replaceUntracked, currentRoute: route(root))

        #expect(!result.committed)
        #expect(result.failure?.contains("staged Known People replacement failed validation") == true)
        #expect(result.failure?.contains("committed") == false)
        #expect(try treeFiles(root) == before)
    }

    @Test("A failed precommit cleanup returns the held orphan as recovery evidence")
    func cleanupFailureReturnsRecovery() async throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let admitted = try await snapshot(in: parent)
        var access = KnownPeopleManagedStoreReplacementAccess()
        access.beforeStageReadback = {
            guard let stage = try FileManager.default.contentsOfDirectory(at: parent,
                includingPropertiesForKeys: nil).first(where: {
                    $0.lastPathComponent.hasPrefix(".KnownPeople-replacement-")
                }) else { throw Injected.failure }
            try FileManager.default.createSymbolicLink(at: stage.appendingPathComponent("orphan-link"),
                withDestinationURL: root)
            throw Injected.failure
        }
        let service = KnownPeopleManagedStoreReplacement(access: access)
        let plan = try await service.plan(snapshot: admitted, route: route(root))

        let result = await service.replace(plan: plan, decision: .replaceUntracked, currentRoute: route(root))

        #expect(!result.committed)
        #expect(result.failure?.contains("recovery evidence") == true)
        let recovery = try #require(result.recoveryDirectory)
        #expect(FileManager.default.fileExists(atPath: recovery.path))
        #expect(try treeFiles(root)["people/old.json"] == Data("old person".utf8))
    }

    @Test("The live route is sampled again after the final commit hook")
    func liveRouteBeforeCommit() async throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let before = try treeFiles(root)
        let admitted = try await snapshot(in: parent)
        let routes = KnownPeopleManagedRouteProbe(initial: route(root))
        var access = KnownPeopleManagedStoreReplacementAccess()
        access.beforeCommit = { routes.set(.init(rootURL: root, generation: 2,
            iCloudSyncActive: true, routingActive: true)) }
        access.liveRouteBeforeCommit = { routes.value }
        let service = KnownPeopleManagedStoreReplacement(access: access)
        let plan = try await service.plan(snapshot: admitted, route: route(root))

        let result = await service.replace(plan: plan, decision: .replaceUntracked, currentRoute: route(root))

        #expect(!result.committed)
        #expect(result.failure?.contains("iCloud") == true)
        #expect(try treeFiles(root) == before)
    }

    @Test("A moved held parent is refused even when the old route is counterfeited exactly",
          arguments: [false, true])
    func movedParentIsRefused(actualRootMutated: Bool) async throws {
        let parent = try temporaryDirectory()
        let movedParent = parent.deletingLastPathComponent().appendingPathComponent(
            "\(parent.lastPathComponent)-moved", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: movedParent)
        }
        let root = try makeManagedRoot(in: parent)
        let before = try treeFiles(root)
        let admitted = try await snapshot(in: parent)
        var access = KnownPeopleManagedStoreReplacementAccess()
        access.beforeCommit = {
            try FileManager.default.moveItem(at: parent, to: movedParent)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (path, bytes) in before {
                let destination = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try bytes.write(to: destination)
            }
            if actualRootMutated {
                try Data("actual root changed".utf8).write(to: movedParent.appendingPathComponent(
                    "KnownPeople/people/actual-route.json"))
            }
        }
        let service = KnownPeopleManagedStoreReplacement(access: access)
        let plan = try await service.plan(snapshot: admitted, route: route(root))

        let result = await service.replace(plan: plan, decision: .replaceUntracked, currentRoute: route(root))

        #expect(!result.committed)
        #expect(result.failure?.contains("route changed") == true)
        #expect(try treeFiles(root) == before)
        let actualRoot = movedParent.appendingPathComponent("KnownPeople", isDirectory: true)
        if actualRootMutated {
            #expect(try treeFiles(actualRoot)["people/actual-route.json"] == Data("actual root changed".utf8))
        } else {
            #expect(try treeFiles(actualRoot) == before)
        }
    }

    @Test("Directory URL hints do not make an unchanged route stale")
    func directoryHintDoesNotChangeRoutePathIdentity() async throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let directoryRoot = try makeManagedRoot(in: parent)
        let unhintedRoot = URL(fileURLWithPath: directoryRoot.path, isDirectory: false)
        #expect(directoryRoot.absoluteString != unhintedRoot.absoluteString)
        let admitted = try await snapshot(in: parent)
        let service = KnownPeopleManagedStoreReplacement()
        let plan = try await service.plan(snapshot: admitted, route: route(unhintedRoot))

        let result = await service.replace(plan: plan, decision: .replaceUntracked,
            currentRoute: route(unhintedRoot))

        #expect(result.committed && result.failure == nil)
        #expect(try await service.admittedPackageFiles(root: directoryRoot) == admitted.files)
    }

    @Test("Cancellation, stage readback and pre-swap sync failure leave the current tree untouched")
    func precommitFailureDoesNotReplace() async throws {
        for mode in ["cancel", "readback", "sync"] {
            let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
            let root = try makeManagedRoot(in: parent)
            let before = try treeFiles(root)
            let admitted = try await snapshot(in: parent)
            var access = KnownPeopleManagedStoreReplacementAccess()
            if mode == "cancel" {
                access.beforeCommit = { withUnsafeCurrentTask { $0?.cancel() } }
            } else if mode == "readback" {
                access.beforeStageReadback = { throw Injected.failure }
            } else {
                access.syncStageBeforeCommit = { _ in throw Injected.failure }
            }
            let service = KnownPeopleManagedStoreReplacement(access: access)
            let plan = try await service.plan(snapshot: admitted, route: route(root))
            let result = await Task {
                await service.replace(plan: plan, decision: .replaceUntracked, currentRoute: route(root))
            }.value
            #expect(!result.committed)
            #expect(result.wasCancelled == (mode == "cancel"))
            #expect(try treeFiles(root) == before)
        }
    }

    @Test("Postcommit readback and parent-sync failures report committed recovery truthfully")
    func postcommitFailuresRetainRecovery() async throws {
        for mode in ["tamper", "sync"] {
            let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
            let root = try makeManagedRoot(in: parent)
            let before = try treeFiles(root)
            let admitted = try await snapshot(in: parent)
            var access = KnownPeopleManagedStoreReplacementAccess()
            if mode == "tamper" {
                access.afterCommit = {
                    try Data("tampered after commit".utf8).write(to: root.appendingPathComponent(
                        "people/BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB.json"))
                }
            } else {
                access.syncParentAfterCommit = { _ in throw Injected.failure }
            }
            let service = KnownPeopleManagedStoreReplacement(access: access)
            let plan = try await service.plan(snapshot: admitted, route: route(root))

            let result = await service.replace(plan: plan, decision: .replaceUntracked,
                currentRoute: route(root))

            #expect(result.committed)
            let recovery = try #require(result.recoveryDirectory)
            #expect(try treeFiles(recovery) == before)
            if mode == "tamper" {
                #expect(result.installedState == nil)
                #expect(result.failure?.contains("readback failed") == true)
            } else {
                #expect(result.installedState != nil)
                #expect(result.failure?.contains("syncing its parent directory failed") == true)
            }
        }
    }

    @Test("A valid empty snapshot is a complete replacement")
    func emptyReplacement() async throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let admitted = try await emptySnapshot(in: parent, libraryID: UUID())
        let service = KnownPeopleManagedStoreReplacement()
        let plan = try await service.plan(snapshot: admitted, route: route(root))
        let result = await service.replace(plan: plan, decision: .replaceUntracked, currentRoute: route(root))
        #expect(result.committed && result.failure == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath:
            root.appendingPathComponent("people").path).isEmpty)
        #expect(try await service.admittedPackageFiles(root: root) == admitted.files)
    }

    @Test("The shared route gate is exclusive, FIFO and cancellation-safe")
    func routeMutationGateOwnership() async throws {
        let gate = KnownPeopleRouteMutationGate()
        let first = try await gate.acquire()
        actor Entries {
            var values: [Int] = []
            func add(_ value: Int) { values.append(value) }
        }
        let entries = Entries()
        let second = Task {
            let lease = try await gate.acquire()
            await entries.add(2)
            lease.release()
        }
        let third = Task {
            let lease = try await gate.acquire()
            await entries.add(3)
            lease.release()
        }
        try await waitForWaiters(2, on: gate)
        #expect(await entries.values.isEmpty)
        first.release()
        try await second.value
        try await third.value
        #expect(await entries.values == [2, 3])
        #expect(!gate.isHeld && gate.waitingCount == 0)

        let held = try await gate.acquire()
        let cancelled = Task { () -> Bool in
            do {
                let lease = try await gate.acquire()
                lease.release()
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        try await waitForWaiters(1, on: gate)
        cancelled.cancel()
        #expect(await cancelled.value)
        #expect(gate.waitingCount == 0)
        held.release()
        let final = try await gate.acquire()
        final.release()
    }

    @Test("A replacement waiting behind a route rechecks inventory and honors cancellation")
    @MainActor
    func replacementWaitsForRouteLease() async throws {
        let preferenceLease = try await knownPeopleICloudPreferenceTestGate.acquire()
        defer { preferenceLease.release() }
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let priorOverride = KnownPeopleService.storageOverrideURL
        let defaultsKey = UserDefaultsKeys.knownPeopleICloudEnabled
        let priorPreference = UserDefaults.standard.object(forKey: defaultsKey)
        KnownPeopleService.storageOverrideURL = root
        UserDefaults.standard.set(false, forKey: defaultsKey)
        defer {
            KnownPeopleService.storageOverrideURL = priorOverride
            if let priorPreference { UserDefaults.standard.set(priorPreference, forKey: defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        }
        let admitted = try await snapshot(in: parent)
        let service = KnownPeopleService()
        let plan = try await service.planManagedStoreReplacement(snapshot: admitted, routingActive: false)
        let gate = KnownPeopleRouteMutationGate()
        let route = try await gate.acquire()
        let replacement = Task { @MainActor in
            await service.replaceManagedStore(plan: plan, decision: .replaceUntracked,
                routingActive: false, routeMutationGate: gate)
        }
        try await waitForWaiters(1, on: gate)
        try Data("routed mutation".utf8).write(to: root.appendingPathComponent("people/route.json"))
        route.release()
        let stale = await replacement.value
        #expect(!stale.committed && stale.failure?.contains("library changed") == true)

        let freshPlan = try await service.planManagedStoreReplacement(snapshot: admitted, routingActive: false)
        let held = try await gate.acquire()
        let cancelled = Task { @MainActor in
            await service.replaceManagedStore(plan: freshPlan, decision: .replaceUntracked,
                routingActive: false, routeMutationGate: gate)
        }
        try await waitForWaiters(1, on: gate)
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        #expect(!cancelledResult.committed && cancelledResult.wasCancelled)
        held.release()
    }

    @Test("Service publication occurs after reservation release so observers read the installed store")
    @MainActor
    func observerReadsInstalledStore() async throws {
        let preferenceLease = try await knownPeopleICloudPreferenceTestGate.acquire()
        defer { preferenceLease.release() }
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let priorOverride = KnownPeopleService.storageOverrideURL
        let defaultsKey = UserDefaultsKeys.knownPeopleICloudEnabled
        let priorPreference = UserDefaults.standard.object(forKey: defaultsKey)
        KnownPeopleService.storageOverrideURL = root
        UserDefaults.standard.set(false, forKey: defaultsKey)
        defer {
            KnownPeopleService.storageOverrideURL = priorOverride
            if let priorPreference { UserDefaults.standard.set(priorPreference, forKey: defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        }
        let admitted = try await snapshot(in: parent)
        let service = KnownPeopleService()
        let plan = try await service.planManagedStoreReplacement(snapshot: admitted, routingActive: false)
        let observer = KnownPeopleManagedReplacementObserver(service: service)
        NotificationCenter.default.addObserver(observer, selector: #selector(observer.changed),
            name: .knownPeopleDatabaseDidChange, object: nil)
        defer { NotificationCenter.default.removeObserver(observer) }

        let result = await service.replaceManagedStore(plan: plan, decision: .replaceUntracked,
            routingActive: false, routeMutationGate: KnownPeopleRouteMutationGate())

        #expect(result.committed && result.failure == nil)
        #expect(observer.notifications == 1)
        #expect(observer.personIDs == [UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!])
    }

    @Test("Managed projection uses CRUD-compatible uppercase UUID filenames")
    @MainActor
    func projectionFilenamesMatchCRUDConvention() async throws {
        let preferenceLease = try await knownPeopleICloudPreferenceTestGate.acquire()
        defer { preferenceLease.release() }
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let priorOverride = KnownPeopleService.storageOverrideURL
        let defaultsKey = UserDefaultsKeys.knownPeopleICloudEnabled
        let priorPreference = UserDefaults.standard.object(forKey: defaultsKey)
        KnownPeopleService.storageOverrideURL = root
        UserDefaults.standard.set(false, forKey: defaultsKey)
        defer {
            KnownPeopleService.storageOverrideURL = priorOverride
            if let priorPreference { UserDefaults.standard.set(priorPreference, forKey: defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        }
        let admitted = try await snapshot(in: parent)
        let service = KnownPeopleService()
        let plan = try await service.planManagedStoreReplacement(snapshot: admitted, routingActive: false)
        let result = await service.replaceManagedStore(plan: plan, decision: .replaceUntracked,
            routingActive: false, routeMutationGate: KnownPeopleRouteMutationGate())
        #expect(result.committed && result.failure == nil)

        let personID = try #require(admitted.people.first?.id)
        let expectedName = "\(personID.uuidString).json"
        let peopleDirectory = root.appendingPathComponent("people", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: peopleDirectory.path) == [expectedName])
        #expect(try await KnownPeopleManagedStoreReplacement().admittedPackageFiles(root: root)
            == admitted.files)

        var person = try #require(service.loadDatabase().people.first)
        person.name = "Updated through CRUD"
        try service.updatePerson(person)

        let namesAfterUpdate = try FileManager.default.contentsOfDirectory(atPath: peopleDirectory.path)
        #expect(namesAfterUpdate == [expectedName])
        #expect(!namesAfterUpdate.contains("\(personID.uuidString.lowercased()).json"))
        let admittedEmbeddingName = "cccccccc-cccc-cccc-cccc-cccccccccccc.fem2"
        let admittedEmbeddingDirectory = root.appendingPathComponent(
            ".admitted-package/embeddings", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: admittedEmbeddingDirectory.path)
            == [admittedEmbeddingName])
        let admittedEmbeddingBytes = try #require(admitted.files["embeddings/\(admittedEmbeddingName)"])
        #expect(try Data(contentsOf: admittedEmbeddingDirectory.appendingPathComponent(admittedEmbeddingName))
            == admittedEmbeddingBytes)
    }

    @Test("Whole-root reservation refuses CRUD and discards displaced deferred deletion")
    @MainActor
    func reservationScopesDeferredWorkToDisplacedGeneration() async throws {
        let preferenceLease = try await knownPeopleICloudPreferenceTestGate.acquire()
        defer { preferenceLease.release() }
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let priorOverride = KnownPeopleService.storageOverrideURL
        let defaultsKey = UserDefaultsKeys.knownPeopleICloudEnabled
        let priorPreference = UserDefaults.standard.object(forKey: defaultsKey)
        KnownPeopleService.storageOverrideURL = root
        UserDefaults.standard.set(false, forKey: defaultsKey)
        defer {
            KnownPeopleService.storageOverrideURL = priorOverride
            if let priorPreference { UserDefaults.standard.set(priorPreference, forKey: defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        }
        let removals = KnownPeopleManagedRemovalProbe()
        var archiveAccess = KnownPeopleArchiveFileAccess.system
        archiveAccess.removeCoordinatedItem = { url in removals.record(url) }
        let service = KnownPeopleService(archiveService: KnownPeopleArchiveService(access: archiveAccess))
        let admitted = try await snapshot(in: parent)
        let plan = try await service.planManagedStoreReplacement(snapshot: admitted, routingActive: false)
        let hook = KnownPeopleManagedBlockingHook()
        defer { hook.release() }
        var replacementAccess = KnownPeopleManagedStoreReplacementAccess()
        replacementAccess.beforeCommit = { hook.blockUntilReleased() }
        let replacement = Task { @MainActor in
            await service.replaceManagedStore(plan: plan, decision: .replaceUntracked,
                routingActive: false, routeMutationGate: KnownPeopleRouteMutationGate(),
                replacementAccess: replacementAccess)
        }
        try await hook.waitUntilEntered()

        #expect(KnownPeopleService.replacementReservationCovers(
            root.appendingPathComponent("thumbnails/probe.jpg")))
        #expect(throws: (any Error).self) {
            try service.saveThumbnail(Data("must be refused".utf8), for: UUID())
        }
        let embeddingID = try #require(admitted.people.first?.embeddings.first?.id)
        service.deleteEmbeddingThumbnail(for: embeddingID)
        hook.release()
        let result = await replacement.value

        #expect(result.committed && result.failure == nil)
        #expect(removals.urls.isEmpty)
        #expect(try await KnownPeopleManagedStoreReplacement().admittedPackageFiles(root: root)
            == admitted.files)
    }

    @Test("A lexically nested child symlink remains covered by whole-root reservation")
    @MainActor
    func lexicalChildSymlinkRemainsReserved() async throws {
        let preferenceLease = try await knownPeopleICloudPreferenceTestGate.acquire()
        defer { preferenceLease.release() }
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let priorOverride = KnownPeopleService.storageOverrideURL
        let defaultsKey = UserDefaultsKeys.knownPeopleICloudEnabled
        let priorPreference = UserDefaults.standard.object(forKey: defaultsKey)
        KnownPeopleService.storageOverrideURL = root
        UserDefaults.standard.set(false, forKey: defaultsKey)
        defer {
            KnownPeopleService.storageOverrideURL = priorOverride
            if let priorPreference { UserDefaults.standard.set(priorPreference, forKey: defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        }
        let admitted = try await snapshot(in: parent)
        let service = KnownPeopleService()
        let plan = try await service.planManagedStoreReplacement(snapshot: admitted, routingActive: false)
        let hook = KnownPeopleManagedBlockingHook()
        defer { hook.release() }
        var replacementAccess = KnownPeopleManagedStoreReplacementAccess()
        replacementAccess.beforeCommit = { hook.blockUntilReleased() }
        let replacement = Task { @MainActor in
            await service.replaceManagedStore(plan: plan, decision: .replaceUntracked,
                routingActive: false, routeMutationGate: KnownPeopleRouteMutationGate(),
                replacementAccess: replacementAccess)
        }
        try await hook.waitUntilEntered()
        let alias = root.appendingPathComponent("escaped-child", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)

        #expect(KnownPeopleService.replacementReservationCovers(
            alias.appendingPathComponent("would-escape.jpg")))
        hook.release()
        let result = await replacement.value
        #expect(!result.committed)
        #expect(result.failure?.contains("unsupported file or symbolic link") == true)
    }

    @Test("A valid admitted state protects v3 embeddings from stale global migration")
    @MainActor
    func admittedStateProtectsRealDatabaseLoad() async throws {
        let preferenceLease = try await knownPeopleICloudPreferenceTestGate.acquire()
        defer { preferenceLease.release() }
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = try makeManagedRoot(in: parent)
        let priorOverride = KnownPeopleService.storageOverrideURL
        let cloudKey = UserDefaultsKeys.knownPeopleICloudEnabled
        let versionKey = UserDefaultsKeys.knownPeopleEmbeddingVersion
        let priorCloud = UserDefaults.standard.object(forKey: cloudKey)
        let priorVersion = UserDefaults.standard.object(forKey: versionKey)
        KnownPeopleService.storageOverrideURL = root
        UserDefaults.standard.set(false, forKey: cloudKey)
        defer {
            KnownPeopleService.storageOverrideURL = priorOverride
            if let priorCloud { UserDefaults.standard.set(priorCloud, forKey: cloudKey) }
            else { UserDefaults.standard.removeObject(forKey: cloudKey) }
            if let priorVersion { UserDefaults.standard.set(priorVersion, forKey: versionKey) }
            else { UserDefaults.standard.removeObject(forKey: versionKey) }
        }
        let admitted = try await snapshot(in: parent)
        let installer = KnownPeopleService()
        let plan = try await installer.planManagedStoreReplacement(snapshot: admitted, routingActive: false)
        let installed = await installer.replaceManagedStore(plan: plan, decision: .replaceUntracked,
            routingActive: false, routeMutationGate: KnownPeopleRouteMutationGate())
        #expect(installed.committed && installed.failure == nil)
        UserDefaults.standard.set(FaceRecognitionDefaults.embeddingVersion - 1, forKey: versionKey)

        let loaded = KnownPeopleService().loadDatabase()

        #expect(loaded.people.map(\.id) == admitted.people.map(\.id))
        #expect(KnownPeopleManagedStoreState.protectsCurrentEmbeddingStore(at: root))
        #expect(UserDefaults.standard.integer(forKey: versionKey) == FaceRecognitionDefaults.embeddingVersion)
    }

    private func emptySnapshot(in parent: URL, libraryID: UUID, suffix: Int = 0) async throws -> KnownPeoplePackageSnapshot {
        let payload = try KnownPeoplePackagePayload(people: [])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadData = try encoder.encode(payload)
        let hash = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
        let file = try KnownPeoplePackageManifest.FileDeclaration(path: "people.json",
            byteCount: payloadData.count, sha256: hash)
        let exporter = try KnownPeoplePackageManifest.Exporter(app: "Managed test", version: "1",
            sourceRevision: String(repeating: "a", count: 40))
        let manifest = try KnownPeoplePackageManifest(libraryID: libraryID,
            exportedAt: "2026-09-12T00:00:00.000Z", exporter: exporter,
            peopleCount: 0, embeddingCount: 0, files: [file])
        let manifestData = try encoder.encode(manifest)
        let source = parent.appendingPathComponent("empty-\(suffix)-\(UUID().uuidString).aagedalpeople")
        try put(["manifest.json": manifestData, "people.json": payloadData], at: source)
        return try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
    }

    private func waitForWaiters(_ count: Int, on gate: KnownPeopleRouteMutationGate) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while gate.waitingCount != count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.waitingCount == count)
    }
}

nonisolated private final class KnownPeopleManagedBlockingHook: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func blockUntilReleased() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition.withLock({ entered }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition.withLock { entered })
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

nonisolated private final class KnownPeopleManagedRemovalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []
    func record(_ url: URL) { lock.withLock { values.append(url) } }
    var urls: [URL] { lock.withLock { values } }
}

@MainActor
private final class KnownPeopleManagedReplacementObserver: NSObject {
    let service: KnownPeopleService
    private(set) var notifications = 0
    private(set) var personIDs: [UUID] = []

    init(service: KnownPeopleService) { self.service = service }

    @objc func changed() {
        notifications += 1
        personIDs = service.loadDatabase().people.map(\.id)
    }
}

nonisolated private final class KnownPeopleManagedRouteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var route: KnownPeopleManagedStoreRoute

    init(initial: KnownPeopleManagedStoreRoute) { route = initial }
    var value: KnownPeopleManagedStoreRoute { lock.withLock { route } }
    func set(_ value: KnownPeopleManagedStoreRoute) { lock.withLock { route = value } }
}
