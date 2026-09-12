import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Known People atomic first identity", .serialized)
struct KnownPeopleLocalIdentityAssignmentTests {
    private enum Injected: Error { case failure }
    private let date = "2026-09-12T12:00:00.000Z"
    private var exporter: KnownPeoplePackageManifest.Exporter {
        get throws { try .init(app: "Photo Agent identity test", version: "1", sourceRevision: String(repeating: "a", count: 40)) }
    }

    private func parent() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/PeopleIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func fixture(_ parent: URL, empty: Bool = false) async throws -> (URL, KnownPerson?) {
        let local = parent.appendingPathComponent("KnownPeople", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        if empty { return (local, nil) }
        let source = parent.appendingPathComponent("source.aagedalpeople")
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/PeopleLibraryV2")
        for (path, fixture) in ["manifest.json": "manifest.json.base64", "people.json": "people.json.base64",
            "editor/photo-agent.json": "editor-photo-agent.json.base64",
            "embeddings/cccccccc-cccc-cccc-cccc-cccccccccccc.fem2": "embedding.fem2.base64"] {
            let text = try String(contentsOf: base.appendingPathComponent(fixture), encoding: .utf8)
            let bytes = try #require(Data(base64Encoded: text.components(separatedBy: .whitespacesAndNewlines).joined()))
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let package = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        let person = try #require(package.people.first)
        for directory in ["people", "thumbnails", "embedding_thumbnails"] {
            try FileManager.default.createDirectory(at: local.appendingPathComponent(directory), withIntermediateDirectories: false)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(person).write(to: personURL(local, person))
        let jpeg = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/AnalysisCorpus/jpeg-single-q82.jpg"))
        try jpeg.write(to: local.appendingPathComponent("thumbnails/\(person.id.uuidString).jpg"))
        try jpeg.write(to: local.appendingPathComponent("embedding_thumbnails/\(try #require(person.embeddings.first).id.uuidString).jpg"))
        return (local, person)
    }

    private func personURL(_ root: URL, _ person: KnownPerson) -> URL {
        root.appendingPathComponent("people/\(person.id.uuidString).json")
    }
    private func canonicalPeople(_ people: [KnownPerson]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(people)
    }
    private func route(_ root: URL, generation: UInt64 = 1, cloud: Bool = false, routing: Bool = false) -> KnownPeopleManagedStoreRoute {
        .init(rootURL: root, generation: generation, iCloudSyncActive: cloud, routingActive: routing)
    }
    private func tree(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let values = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in values where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }
    private func prepare(_ root: URL, access: KnownPeopleLocalIdentityAssignmentAccess = .init()) async throws -> KnownPeopleLocalIdentityAssignmentPlan {
        try await KnownPeopleLocalIdentityAssignment(access: access).prepare(route: route(root), exportedAt: date, exporter: exporter)
    }
    private func execute(_ plan: KnownPeopleLocalIdentityAssignmentPlan,
                         route current: KnownPeopleManagedStoreRoute? = nil,
                         access: KnownPeopleManagedStoreReplacementAccess = .init()) async -> KnownPeopleLocalIdentityAssignmentResult {
        await KnownPeopleLocalIdentityAssignment().assign(plan: plan) { replacementPlan in
            await KnownPeopleManagedStoreReplacement(access: access).replace(plan: replacementPlan,
                decision: .replaceUntracked, currentRoute: current ?? replacementPlan.route)
        }
    }

    @Test("Read-only populated and empty plans install a stable identity and exact reusable package", arguments: [false, true])
    func roundTrip(empty: Bool) async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (root, person) = try await fixture(parent, empty: empty), before = try tree(root)
        let plan = try await prepare(root)
        #expect(try tree(root) == before)
        #expect(plan.replacementPlan.snapshot.manifest.libraryID == plan.libraryID)
        #expect(plan.replacementPlan.initialInstallationID == plan.installationID)
        #expect(plan.replacementPlan.snapshot.people.count == (empty ? 0 : 1))
        if let person { #expect(try canonicalPeople(plan.replacementPlan.snapshot.people) == canonicalPeople([person])) }

        let result = await execute(plan)
        #expect(result.transaction.committed && result.transaction.failure == nil && !result.returnedCommittedReceipt)
        let state = try #require(result.transaction.installedState)
        #expect(state.libraryID == plan.libraryID && state.installationID == plan.installationID)
        #expect(state.needsCloudReconciliation)
        #expect(try tree(#require(result.transaction.recoveryDirectory)) == before)
        let captured = try await KnownPeopleLocalStoreSnapshotBuilder().capture(rootURL: root, exportedAt: date, exporter: exporter)
        #expect(captured.reusedAdmittedBytes && captured.snapshot.files == plan.replacementPlan.snapshot.files)
        #expect(try canonicalPeople(captured.snapshot.people) == canonicalPeople(plan.replacementPlan.snapshot.people))
        await #expect(throws: KnownPeopleLocalStoreSnapshotFailure.identityAlreadyAssigned) { try await prepare(root) }
        let installedBytes = try tree(root)
        let repeated = await KnownPeopleLocalIdentityAssignment().assign(plan: plan) { _ in
            Issue.record("A committed identity must not execute another replacement")
            return result.transaction
        }
        #expect(repeated.returnedCommittedReceipt && repeated.transaction.committed)
        #expect(try tree(root) == installedBytes)
    }

    @Test("Precommit failure or cancellation retries the same IDs and snapshot", arguments: [false, true])
    func precommitRetry(cancel: Bool) async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (root, _) = try await fixture(parent), before = try tree(root), plan = try await prepare(root)
        var access = KnownPeopleManagedStoreReplacementAccess()
        access.beforeCommit = { if cancel { throw CancellationError() }; throw Injected.failure }
        let failed = await execute(plan, access: access)
        #expect(!failed.transaction.committed && failed.transaction.wasCancelled == cancel)
        #expect(plan.lastTransactionResult?.committed == false && failed.transaction.recoveryDirectory == nil)
        #expect(try tree(root) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).allSatisfy { !$0.hasPrefix(".KnownPeople-") })
        let retry = await execute(plan)
        #expect(retry.transaction.committed && !retry.returnedCommittedReceipt && retry.transaction.failure == nil)
        #expect(retry.transaction.installedState?.installationID == plan.installationID)
        #expect(retry.transaction.installedState?.libraryID == plan.libraryID)
        #expect(retry.transaction.revision == plan.replacementPlan.snapshot.manifest.revision)
    }

    @Test("Postcommit uncertainty retains identity and exact recovery without retrying the swap", arguments: ["readback", "cancel", "durability"])
    func committedUncertainty(kind: String) async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (root, person) = try await fixture(parent), before = try tree(root), plan = try await prepare(root)
        var access = KnownPeopleManagedStoreReplacementAccess()
        if kind == "durability" { access.syncParentAfterCommit = { _ in throw Injected.failure } }
        else { access.afterCommit = { if kind == "cancel" { throw CancellationError() }; throw Injected.failure } }
        let outcome = await execute(plan, access: access)
        #expect(outcome.transaction.committed && outcome.transaction.wasCancelled == (kind == "cancel"))
        #expect(kind == "cancel" || outcome.transaction.failure != nil)
        let state = try KnownPeopleManagedStoreState.decode(Data(contentsOf: root.appendingPathComponent(KnownPeopleManagedStoreState.fileName)))
        #expect(state.libraryID == plan.libraryID && state.installationID == plan.installationID)
        #expect(try tree(#require(outcome.transaction.recoveryDirectory)) == before)
        // A later independent edit must not be overwritten by replaying the old identity plan.
        let file = personURL(root, try #require(person))
        try Data("newer independent bytes".utf8).write(to: file)
        let after = try tree(root)
        let repeated = await KnownPeopleLocalIdentityAssignment().assign(plan: plan) { _ in
            Issue.record("Committed uncertainty must not run another transaction")
            return outcome.transaction
        }
        #expect(repeated.returnedCommittedReceipt && repeated.transaction.committed)
        #expect(repeated.transaction.recoveryDirectory == outcome.transaction.recoveryDirectory)
        #expect(repeated.transaction.failure == outcome.transaction.failure)
        #expect(try tree(root) == after)
    }

    @Test("Changed captured root or route refuses assignment", arguments: ["record", "root", "generation", "cloud", "routing"])
    func changedBeforeCommit(kind: String) async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (root, person) = try await fixture(parent), plan = try await prepare(root)
        if kind == "record" { try Data("newer".utf8).write(to: personURL(root, try #require(person))) }
        if kind == "root" {
            try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("old-root"))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        let before = try tree(root)
        let current = route(root, generation: kind == "generation" ? 2 : 1, cloud: kind == "cloud", routing: kind == "routing")
        let result = await execute(plan, route: current)
        #expect(!result.transaction.committed && result.transaction.failure != nil)
        #expect(try tree(root) == before)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(KnownPeopleManagedStoreState.fileName).path))
    }

    @Test("Strict capture cannot be rebound to newer bytes while preparing the replacement plan")
    func changedBetweenCaptureAndPlan() async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (root, person) = try await fixture(parent)
        let file = personURL(root, try #require(person)), newer = Data("newer independent bytes".utf8)
        var access = KnownPeopleLocalIdentityAssignmentAccess()
        access.beforeReplacementPlan = { try newer.write(to: file) }
        await #expect(throws: KnownPeopleManagedStoreFailure.staleInventory) { try await prepare(root, access: access) }
        #expect(try Data(contentsOf: file) == newer)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(KnownPeopleManagedStoreState.fileName).path))
    }

    @Test("Unsafe, tracked, orphaned and legacy roots never gain identity", arguments: ["state", "orphan", "tombstone", "legacy", "provenance", "symlink", "hardlink", "jpeg", "cloud", "routing"])
    func refusedInputs(kind: String) async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (root, value) = try await fixture(parent), person = try #require(value)
        let file = personURL(root, person)
        switch kind {
        case "state": try Data("{}".utf8).write(to: root.appendingPathComponent(KnownPeopleManagedStoreState.fileName))
        case "orphan": try FileManager.default.createDirectory(at: root.appendingPathComponent(".admitted-package"), withIntermediateDirectories: false)
        case "tombstone": try Data().write(to: root.appendingPathComponent("people/\(UUID().uuidString).deleted"))
        case "legacy": try Data("{}".utf8).write(to: root.appendingPathComponent("database.json"))
        case "provenance":
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var examples = try #require(object["embeddings"] as? [[String: Any]])
            examples[0].removeValue(forKey: "provenance"); object["embeddings"] = examples
            try JSONSerialization.data(withJSONObject: object).write(to: file)
        case "symlink":
            let moved = parent.appendingPathComponent("original.json")
            try FileManager.default.moveItem(at: file, to: moved)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
        case "hardlink": #expect(link(file.path, parent.appendingPathComponent("linked.json").path) == 0)
        case "jpeg": try Data("invalid JPEG".utf8).write(to: root.appendingPathComponent("thumbnails/\(person.id.uuidString).jpg"))
        default: break
        }
        let before = try tree(root)
        await #expect(throws: (any Error).self) {
            try await KnownPeopleLocalIdentityAssignment().prepare(route: route(root, cloud: kind == "cloud", routing: kind == "routing"),
                exportedAt: date, exporter: exporter)
        }
        #expect(try tree(root) == before)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".admitted-package/manifest.json").path))
    }

    @Test("An ABA root edit cannot bind a captured alternate person to the original inventory")
    func changedAndRestoredDuringCapture() async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (root, value) = try await fixture(parent), person = try #require(value)
        let file = personURL(root, person), original = try Data(contentsOf: file), before = try tree(root)
        var edited = person; edited.name = "Alternate captured name"
        let alternate = try JSONEncoder().encode(edited)
        var access = KnownPeopleLocalIdentityAssignmentAccess()
        access.capture.afterRootOpen = { try alternate.write(to: file) }
        access.afterCapture = { try original.write(to: file) }
        await #expect(throws: KnownPeopleManagedStoreFailure.staleInventory) { try await prepare(root, access: access) }
        #expect(try tree(root) == before)
    }

    @Test("A planned initial installation ID cannot override existing identity or be all-zero")
    func installationIDAdmission() async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (root, _) = try await fixture(parent), plan = try await prepare(root)
        let replacement = KnownPeopleManagedStoreReplacement()
        let zero = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        await #expect(throws: KnownPeopleManagedStoreFailure.wrongDecision) {
            try await replacement.plan(snapshot: plan.replacementPlan.snapshot, route: route(root), initialInstallationID: zero)
        }
        #expect(await execute(plan).transaction.committed)
        let before = try tree(root)
        await #expect(throws: KnownPeopleManagedStoreFailure.wrongDecision) {
            try await replacement.plan(snapshot: plan.replacementPlan.snapshot, route: route(root), initialInstallationID: UUID())
        }
        #expect(try tree(root) == before)
    }

    @Test("Production identity assignment uses the owner gateway and preserves a captured local library")
    @MainActor
    func ownerGateway() async throws {
        let lease = try await knownPeopleICloudPreferenceTestGate.acquire(); defer { lease.release() }
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (root, _) = try await fixture(parent)
        let priorOverride = KnownPeopleService.storageOverrideURL
        let key = UserDefaultsKeys.knownPeopleICloudEnabled, prior = UserDefaults.standard.object(forKey: key)
        KnownPeopleService.storageOverrideURL = root
        UserDefaults.standard.set(false, forKey: key)
        defer {
            KnownPeopleService.storageOverrideURL = priorOverride
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let owner = KnownPeopleService(), assignment = KnownPeopleLocalIdentityAssignment()
        let plan = try await assignment.prepare(route: owner.managedStoreRoute(routingActive: false), exportedAt: date, exporter: exporter)
        let result = await assignment.assign(plan: plan, owner: owner, routingActive: false, routeMutationGate: KnownPeopleRouteMutationGate())
        #expect(result.transaction.committed && result.transaction.failure == nil)
        #expect(result.transaction.installedState?.installationID == plan.installationID)
        let captured = try await KnownPeopleLocalStoreSnapshotBuilder().capture(rootURL: root, exportedAt: date, exporter: exporter)
        #expect(captured.reusedAdmittedBytes && captured.snapshot.files == plan.replacementPlan.snapshot.files)
    }

    @Test("Simultaneous assignments execute once, report busy, then return the exact committed receipt")
    func simultaneousAssignment() async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (root, _) = try await fixture(parent), plan = try await prepare(root)
        let barrier = IdentityAttemptBarrier(), assignment = KnownPeopleLocalIdentityAssignment()
        let first = Task {
            await assignment.assign(plan: plan) { replacementPlan in
                await barrier.enter()
                return await KnownPeopleManagedStoreReplacement().replace(plan: replacementPlan,
                    decision: .replaceUntracked, currentRoute: replacementPlan.route)
            }
        }
        await barrier.waitUntilEntered()
        let overlapping = await KnownPeopleLocalIdentityAssignment().assign(plan: plan) { replacementPlan in
            Issue.record("A second service instance must not execute the same plan concurrently")
            return await KnownPeopleManagedStoreReplacement().replace(plan: replacementPlan,
                decision: .replaceUntracked, currentRoute: replacementPlan.route)
        }
        #expect(!overlapping.transaction.committed && overlapping.transaction.failure?.contains("already running") == true)
        await barrier.release()
        let committed = await first.value
        #expect(committed.transaction.committed && committed.transaction.failure == nil)
        let bytes = try tree(root)
        let later = await assignment.assign(plan: plan) { _ in
            Issue.record("A later retry must return the committed receipt")
            return committed.transaction
        }
        #expect(later.returnedCommittedReceipt && later.transaction.installedState == committed.transaction.installedState)
        #expect(later.transaction.recoveryDirectory == committed.transaction.recoveryDirectory)
        #expect(await barrier.executionCount == 1)
        #expect(try tree(root) == bytes)
    }
}

private actor IdentityAttemptBarrier {
    private(set) var executionCount = 0
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func enter() async {
        executionCount += 1
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if executionCount > 0 { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
