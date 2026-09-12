import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Known People production interchange adapter")
@MainActor
struct KnownPeopleInterchangeProductionOperationsTests {
    private struct Fixture {
        let parent: URL
        let source: URL
        let snapshot: KnownPeoplePackageSnapshot
        let admission: KnownPeopleManagedImportAdmission
        let plan: KnownPeopleManagedStoreReplacementPlan
    }
    private func fixture() async throws -> Fixture {
        let parent = URL(fileURLWithPath: "/private/tmp/InterchangeAdapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let source = parent.appendingPathComponent("input.aagedalpeople")
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/PeopleLibraryV2")
        for (path, name) in ["manifest.json": "manifest.json.base64", "people.json": "people.json.base64",
            "editor/photo-agent.json": "editor-photo-agent.json.base64",
            "embeddings/cccccccc-cccc-cccc-cccc-cccccccccccc.fem2": "embedding.fem2.base64"] {
            let text = try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8)
            let bytes = try #require(Data(base64Encoded: text.components(separatedBy: .whitespacesAndNewlines).joined()))
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let snapshot = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        let admission = KnownPeopleManagedImportAdmission(snapshot: snapshot,
            provenance: .init(kind: .directoryPackage, sourceURL: source, sourceDevice: snapshot.sourceDevice,
                              sourceInode: snapshot.sourceInode, archiveByteCount: nil, archiveSHA256: nil))
        let managed = parent.appendingPathComponent("KnownPeople")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: false)
        let plan = try await admission.planReplacement(route: .init(rootURL: managed, generation: 1,
                                                                   iCloudSyncActive: false, routingActive: false))
        return .init(parent: parent, source: source, snapshot: snapshot, admission: admission, plan: plan)
    }
    private func capture(_ snapshot: KnownPeoplePackageSnapshot) -> KnownPeopleLocalStoreSnapshotCapture {
        .init(snapshot: snapshot, inventory: .init(device: snapshot.sourceDevice, inode: snapshot.sourceInode,
            directories: [], files: [:]), reusedAdmittedBytes: true, managedInventorySHA256: String(repeating: "a", count: 64))
    }
    private func bundle(in parent: URL, metadata: [String: Any]) throws -> Bundle {
        let url = parent.appendingPathComponent("Metadata-\(UUID().uuidString).bundle", isDirectory: true)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = metadata
        info["CFBundleIdentifier"] = "no.aagedal.interchange-metadata-test.\(UUID().uuidString)"
        info["CFBundlePackageType"] = "BNDL"
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: url))
    }
    private func access(_ fixture: Fixture, _ trace: InterchangeScopeTrace, started: Bool = true) -> KnownPeopleInterchangeOperationsAccess {
        .init(availability: { .available }, scope: .init(start: { _ in trace.events.append("start"); return started },
                                                       stop: { _ in trace.events.append("stop") }),
        admit: { _ in trace.events.append("admission-cleanup"); return .init(admission: fixture.admission, wasCancelled: false, failure: nil, recoveryDirectories: []) },
        planImport: { _ in trace.events.append("plan"); return fixture.plan },
        commitImport: { plan in
            trace.events.append("commit"); trace.committedPlan = plan
            return .init(committed: true, revision: plan.snapshot.manifest.revision, recoveryDirectory: nil,
                         installedState: nil, failure: "Postcommit readback detail", wasCancelled: false)
        }, prepareExport: { trace.events.append("prepare"); return .init(capture: capture(fixture.snapshot), identityAssignment: nil, failure: nil, wasCancelled: false) },
        validateDestination: { _, _, _ in trace.events.append("destination"); },
        writeDirectory: { snapshot, url, _ in
            trace.events.append("directory-cleanup")
            return .init(receipt: .init(destinationURL: url, revision: snapshot.manifest.revision, replacedExistingDirectory: false,
                parentDirectorySynced: true, installedSnapshotVerified: true), wasCancelled: false, failure: nil, recoveryDirectories: [])
        }, writeZIP: { _, url, _ in
            trace.events.append("zip-cleanup")
            return .init(receipt: .init(destinationURL: url, sha256: String(repeating: "a", count: 64), byteCount: 123,
                replacedExistingArchive: false, installedBytesVerified: true, parentDirectorySynced: true),
                wasCancelled: false, failure: nil, recoveryURLs: [])
        })
    }

    @Test("Import source scope balances exactly and ends before planning or user confirmation",
          arguments: [false, true], ["success", "failure", "cancel"])
    func importScope(started: Bool, kind: String) async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let trace = InterchangeScopeTrace(); var access = access(fixture, trace, started: started)
        if kind != "success" {
            access.admit = { _ in
                trace.events.append("admission-cleanup")
                return .init(admission: nil, wasCancelled: kind == "cancel", failure: kind == "failure" ? "cancelled stale error words" : nil,
                             recoveryDirectories: [])
            }
        }
        let operations = KnownPeopleInterchangeProductionOperations(access: access)
        let result = await operations.prepareImport(at: fixture.source)
        let prefix = ["start", "admission-cleanup"] + (started ? ["stop"] : [])
        #expect(trace.events == prefix + (kind == "success" ? ["plan"] : []))
        #expect(trace.committedPlan == nil)
        switch result {
        case .ready(let prompt):
            #expect(kind == "success" && operations.retainedImportCount == 1)
            operations.discardImport(prompt.token)
            #expect(operations.retainedImportCount == 0)
        case .failed(let problem):
            #expect(kind == "failure")
            if case .admissionFailed = problem.category {} else { Issue.record("Detail text must not classify the outcome") }
        case .cancelled: #expect(kind == "cancel")
        }
    }

    @Test("Explicit commit uses the exact retained replacement plan once and preserves typed postcommit uncertainty")
    func exactPlan() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let trace = InterchangeScopeTrace(), operations = KnownPeopleInterchangeProductionOperations(access: access(fixture, trace))
        guard case .ready(let prompt) = await operations.prepareImport(at: fixture.source) else { Issue.record("Expected prompt"); return }
        #expect(trace.committedPlan == nil)
        guard case .committed(let evidence) = await operations.commitImport(prompt.token) else { Issue.record("Expected committed evidence"); return }
        #expect(evidence.committed && !evidence.verified && evidence.requiresAttention)
        #expect(trace.committedPlan?.inventory == fixture.plan.inventory)
        #expect(trace.committedPlan?.snapshot.files == fixture.plan.snapshot.files)
        #expect(operations.retainedImportCount == 0)
        guard case .failed(let problem) = await operations.commitImport(prompt.token) else { Issue.record("Expected consumed token refusal"); return }
        if case .invalidToken = problem.category {} else { Issue.record("Expected typed invalid-token outcome") }
        #expect(trace.events.filter { $0 == "commit" }.count == 1)
    }

    @Test("Destination scope covers preparation through writer cleanup for both formats and all exits",
          arguments: [false, true], ["directory", "zip", "failure", "cancel"])
    func exportScope(started: Bool, kind: String) async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let trace = InterchangeScopeTrace(); var access = access(fixture, trace, started: started)
        if kind == "failure" || kind == "cancel" {
            access.prepareExport = {
                trace.events.append("prepare")
                return .init(capture: nil, identityAssignment: nil, failure: kind == "failure" ? "cancelled" : nil, wasCancelled: kind == "cancel")
            }
        }
        let result = await KnownPeopleInterchangeProductionOperations(access: access).export(
            to: fixture.parent.appendingPathComponent(kind == "zip" ? "output.aagedalpeople.zip" : "output.aagedalpeople"),
            format: kind == "zip" ? .zip : .directory, overwrite: false)
        let writer = kind == "zip" ? ["zip-cleanup"] : kind == "directory" ? ["directory-cleanup"] : []
        #expect(trace.events == ["start", "destination", "prepare"] + writer + (started ? ["stop"] : []))
        switch result {
        case .written: #expect(kind == "zip" || kind == "directory")
        case .cancelled: #expect(kind == "cancel")
        case .failed(let problem):
            #expect(kind == "failure")
            if case .exportPreparationFailed = problem.category {} else { Issue.record("Failure detail must not imply cancellation") }
        default: Issue.record("Unexpected result")
        }
    }

    @Test("Invalid destination refuses before identity preparation while balancing scope")
    func invalidDestination() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let trace = InterchangeScopeTrace(); var access = access(fixture, trace)
        access.validateDestination = { _, _, _ in trace.events.append("destination"); throw KnownPeopleInterchangeExportDestination.Failure.exists }
        let result = await KnownPeopleInterchangeProductionOperations(access: access).export(to: fixture.source, format: .directory, overwrite: false)
        #expect(trace.events == ["start", "destination", "stop"])
        guard case .failed(let problem) = result else { Issue.record("Expected refusal"); return }
        if case .overwriteRequired = problem.category {} else { Issue.record("Expected typed overwrite confirmation") }
    }

    @Test("Nested identity commit and uncertainty remain visible even with a ready capture", arguments: [false, true])
    func nestedIdentity(ready: Bool) async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let trace = InterchangeScopeTrace(); var access = access(fixture, trace)
        let recovery = fixture.parent.appendingPathComponent("identity-backup")
        access.prepareExport = {
            .init(capture: ready ? capture(fixture.snapshot) : nil,
                identityAssignment: .init(committed: true, revision: fixture.snapshot.manifest.revision,
                    recoveryDirectory: recovery, installedState: nil, failure: "Identity committed; sync uncertain", wasCancelled: false),
                failure: ready ? nil : "Final capture unavailable", wasCancelled: false)
        }
        let result = await KnownPeopleInterchangeProductionOperations(access: access).export(to: fixture.parent.appendingPathComponent("out.aagedalpeople"), format: .directory, overwrite: false)
        let evidence: KnownPeopleInterchangeCommitEvidence?
        switch result {
        case .written(let value): #expect(ready); evidence = value.identityAssignment
        case .failed(let problem): #expect(!ready); evidence = problem.identityAssignment
        default: Issue.record("Unexpected nested identity outcome"); return
        }
        #expect(evidence?.committed == true && evidence?.requiresAttention == true)
        #expect(evidence?.recoveryURLs == [recovery])
        #expect(trace.events.last == "stop")
    }

    @Test("ZIP entry ceiling produces typed directory guidance before invoking a writer")
    func zipGuidance() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let trace = InterchangeScopeTrace(); var access = access(fixture, trace)
        // The capture seam isolates transport selection from schema validation, which is
        // covered by the strict builder. Its possible file count exceeds ZIP32's ceiling.
        let files = Dictionary(uniqueKeysWithValues: (0...KnownPeoplePackageArchiveCodec.maximumEntries).map { ("entry-\($0)", Data([1])) })
        let oversized = KnownPeoplePackageSnapshot(sourceDirectoryURL: fixture.snapshot.sourceDirectoryURL,
            sourceDevice: fixture.snapshot.sourceDevice, sourceInode: fixture.snapshot.sourceInode,
            manifest: fixture.snapshot.manifest, payload: fixture.snapshot.payload, editor: fixture.snapshot.editor,
            files: files, people: fixture.snapshot.people)
        access.prepareExport = { .init(capture: capture(oversized), identityAssignment: nil, failure: nil, wasCancelled: false) }
        let result = await KnownPeopleInterchangeProductionOperations(access: access).export(to: fixture.parent.appendingPathComponent("out.aagedalpeople.zip"), format: .zip, overwrite: false)
        guard case .requiresDirectory(let problem) = result else { Issue.record("Expected ZIP capacity guidance"); return }
        if case .zipRequiresDirectory = problem.category {} else { Issue.record("Expected typed ZIP capacity") }
        #expect(problem.detail?.contains(".aagedalpeople directory") == true)
        #expect(!trace.events.contains("zip-cleanup") && !trace.events.contains("directory-cleanup"))
        #expect(trace.events.last == "stop")
    }

    @Test("Current prompt counts are bound to the retained plan and missing-editor metadata is explicit")
    func promptContext() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let replacement = KnownPeopleManagedStoreReplacement()
        let installed = await replacement.replace(plan: fixture.plan, decision: .replaceUntracked, currentRoute: fixture.plan.route)
        #expect(installed.committed)
        let snapshot = fixture.snapshot
        let manifest = try KnownPeoplePackageManifest(libraryID: snapshot.manifest.libraryID,
            exportedAt: snapshot.manifest.exportedAt, exporter: snapshot.manifest.exporter,
            peopleCount: snapshot.manifest.peopleCount, embeddingCount: snapshot.manifest.embeddingCount,
            files: snapshot.manifest.files.filter { $0.path != "editor/photo-agent.json" })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: fixture.source.appendingPathComponent("manifest.json"))
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("editor"))
        let recognitionOnly = try await KnownPeoplePackageDirectoryReader().read(directoryURL: fixture.source)
        let plan = try await replacement.plan(snapshot: recognitionOnly, route: fixture.plan.route)
        let trace = InterchangeScopeTrace(); var access = access(fixture, trace)
        access.planImport = { _ in plan }
        access.currentCounts = { await KnownPeopleInterchangeCurrentCountsReader().read(plan: $0) }
        let operations = KnownPeopleInterchangeProductionOperations(access: access)
        guard case .ready(let prompt) = await operations.prepareImport(at: fixture.source) else { Issue.record("Expected prompt"); return }
        #expect(prompt.relationship == .sameLibrary && prompt.currentLibraryID == snapshot.manifest.libraryID)
        #expect(prompt.currentPeopleCount == snapshot.people.count && prompt.currentEmbeddingCount == snapshot.manifest.embeddingCount)
        #expect(prompt.missingEditorMetadata)
        operations.discardImport(prompt.token)
        try Data("new independent bytes".utf8).write(to: fixture.plan.route.rootURL.appendingPathComponent("people/new.json"))
        let staleCounts = await KnownPeopleInterchangeCurrentCountsReader().read(plan: plan)
        #expect(staleCounts.people == nil && staleCounts.embeddings == nil)
    }

    @Test("Recovery evidence distinguishes routine verified rollback backup from incomplete cleanup")
    func recoveryAttention() {
        let url = URL(fileURLWithPath: "/private/tmp/retained-tree")
        #expect(KnownPeopleInterchangeCommitEvidence(committed: false, verified: false, wasCancelled: false,
            detail: nil, recoveryURLs: [url]).requiresAttention)
        #expect(!KnownPeopleInterchangeCommitEvidence(committed: true, verified: true, wasCancelled: false,
            detail: nil, recoveryURLs: [url], recoveryMeaning: .rollbackBackup).requiresAttention)
    }

    @Test("Bundle exporter binds exact required production metadata")
    func bundleExporter() async throws {
        let parent = URL(fileURLWithPath: "/private/tmp/InterchangeBundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let revision = String(repeating: "a", count: 40)
        let valid = try bundle(in: parent, metadata: [
            "CFBundleDisplayName": "Aagedal Photo Agent",
            "CFBundleShortVersionString": "3.0.0",
            "CFBundleVersion": "738",
            "AagedalSourceRevision": revision
        ])
        let exporter = try KnownPeopleInterchangeBundleExporterFactory(bundle: valid).make()
        #expect(exporter.app == "Aagedal Photo Agent")
        #expect(exporter.version == "3.0.0 (build 738)")
        #expect(exporter.sourceRevision == revision)

        let cases: [(String, [String: Any], KnownPeopleInterchangeBundleExporterFactory.Failure)] = [
            ("missing app", ["CFBundleShortVersionString": "3.0.0", "CFBundleVersion": "738", "AagedalSourceRevision": revision], .missing("CFBundleDisplayName")),
            ("missing version", ["CFBundleDisplayName": "App", "CFBundleVersion": "738", "AagedalSourceRevision": revision], .missing("CFBundleShortVersionString")),
            ("missing build", ["CFBundleDisplayName": "App", "CFBundleShortVersionString": "3.0.0", "AagedalSourceRevision": revision], .missing("CFBundleVersion")),
            ("missing revision", ["CFBundleDisplayName": "App", "CFBundleShortVersionString": "3.0.0", "CFBundleVersion": "738"], .missing("AagedalSourceRevision")),
            ("unexpanded revision", ["CFBundleDisplayName": "App", "CFBundleShortVersionString": "3.0.0", "CFBundleVersion": "738", "AagedalSourceRevision": "$(AAGEDAL_SOURCE_REVISION)"], .invalid("AagedalSourceRevision")),
            ("uppercase revision", ["CFBundleDisplayName": "App", "CFBundleShortVersionString": "3.0.0", "CFBundleVersion": "738", "AagedalSourceRevision": String(repeating: "A", count: 40)], .invalid("AagedalSourceRevision")),
            ("short revision", ["CFBundleDisplayName": "App", "CFBundleShortVersionString": "3.0.0", "CFBundleVersion": "738", "AagedalSourceRevision": String(repeating: "a", count: 39)], .invalid("AagedalSourceRevision"))
        ]
        for (_, metadata, expected) in cases {
            let candidate = try bundle(in: parent, metadata: metadata)
            do {
                _ = try KnownPeopleInterchangeBundleExporterFactory(bundle: candidate).make()
                Issue.record("Invalid bundle metadata was accepted")
            } catch let failure as KnownPeopleInterchangeBundleExporterFactory.Failure {
                #expect(failure == expected)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Missing release source revision refuses export before first identity assignment")
    func missingSourceRevisionPrecedesIdentity() async throws {
        let lease = try await knownPeopleICloudPreferenceTestGate.acquire(); defer { lease.release() }
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let bundle = try bundle(in: fixture.parent, metadata: [
            "CFBundleDisplayName": "Aagedal Photo Agent",
            "CFBundleShortVersionString": "3.0.0",
            "CFBundleVersion": "738"
        ])
        let root = fixture.plan.route.rootURL, originalOverride = KnownPeopleService.storageOverrideURL
        let key = UserDefaultsKeys.knownPeopleICloudEnabled, prior = UserDefaults.standard.object(forKey: key)
        KnownPeopleService.storageOverrideURL = root; UserDefaults.standard.set(false, forKey: key)
        defer {
            KnownPeopleService.storageOverrideURL = originalOverride
            if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let owner = KnownPeopleService()
        var access = KnownPeopleInterchangeOperationsAccess.system(owner: owner, coordinator: .shared,
            exporter: { try KnownPeopleInterchangeBundleExporterFactory(bundle: bundle).make() },
            scope: .init(start: { _ in false }, stop: { _ in Issue.record("Unstarted scope was stopped") }))
        access.availability = { .available }
        access.validateDestination = { _, _, _ in }
        let destination = fixture.parent.appendingPathComponent("missing-revision.aagedalpeople")
        let result = await KnownPeopleInterchangeProductionOperations(access: access).export(
            to: destination, format: .directory, overwrite: false)
        guard case .failed(let problem) = result else { Issue.record("Expected metadata refusal"); return }
        if case .exportPreparationFailed = problem.category {} else { Issue.record("Expected preparation failure") }
        #expect(problem.detail?.contains("AagedalSourceRevision") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(KnownPeopleManagedStoreState.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("ZIP capacity work honors task cancellation on its filesystem-independent actor")
    func cancelledCapacity() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await KnownPeopleInterchangeZIPCapacity().fits(["file": Data([1])]); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        #expect(await task.value)
    }

    @Test("The system adapter refuses a valid legacy database without migrating or exporting it")
    func legacyNeverReached() async throws {
        let lease = try await knownPeopleICloudPreferenceTestGate.acquire(); defer { lease.release() }
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let root = fixture.plan.route.rootURL, originalOverride = KnownPeopleService.storageOverrideURL
        let key = UserDefaultsKeys.knownPeopleICloudEnabled, prior = UserDefaults.standard.object(forKey: key)
        KnownPeopleService.storageOverrideURL = root; UserDefaults.standard.set(false, forKey: key)
        defer {
            KnownPeopleService.storageOverrideURL = originalOverride
            if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let legacyURL = root.appendingPathComponent("database.json")
        let bytes = try JSONEncoder().encode(KnownPeopleDatabase(people: fixture.snapshot.people))
        try bytes.write(to: legacyURL)
        let owner = KnownPeopleService(), trace = InterchangeScopeTrace()
        var access = KnownPeopleInterchangeOperationsAccess.system(owner: owner, coordinator: .shared,
            exporter: { fixture.snapshot.manifest.exporter },
            scope: .init(start: { _ in trace.events.append("start"); return true }, stop: { _ in trace.events.append("stop") }))
        // Isolate the global coordinator's cached UI preference; the real owner still
        // checks the persisted local route and uses only the strict schema-2 preparation.
        access.availability = { .available }
        let destination = fixture.parent.appendingPathComponent("output.aagedalpeople")
        let outcome = await KnownPeopleInterchangeProductionOperations(access: access).export(to: destination, format: .directory, overwrite: false)
        guard case .failed(let problem) = outcome else { Issue.record("Legacy input must not reach a writer"); return }
        if case .exportPreparationFailed = problem.category {} else { Issue.record("Expected strict preparation refusal") }
        #expect(try Data(contentsOf: legacyURL) == bytes)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(KnownPeopleManagedStoreState.fileName).path))
        #expect(trace.events == ["start", "stop"])
    }
}

@MainActor
private final class InterchangeScopeTrace {
    var events: [String] = []
    var committedPlan: KnownPeopleManagedStoreReplacementPlan?
}
