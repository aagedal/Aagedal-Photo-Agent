import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Known People strict local snapshot builder")
struct KnownPeopleLocalStoreSnapshotBuilderTests {
    private let exportedAt = "2026-09-12T12:00:00.000Z"
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/PeopleLocalSnapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func fixtureFiles() throws -> [String: Data] {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/PeopleLibraryV2")
        let names = ["manifest.json": "manifest.json.base64", "people.json": "people.json.base64",
            "editor/photo-agent.json": "editor-photo-agent.json.base64",
            "embeddings/cccccccc-cccc-cccc-cccc-cccccccccccc.fem2": "embedding.fem2.base64"]
        return try names.mapValues { name in
            let text = try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8)
            return try #require(Data(base64Encoded: text.components(separatedBy: .whitespacesAndNewlines).joined()))
        }
    }
    private func fixture(_ parent: URL) async throws -> (URL, KnownPeoplePackageSnapshot) {
        let package = parent.appendingPathComponent("input.aagedalpeople")
        for (path, bytes) in try fixtureFiles() {
            let url = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let admitted = try await KnownPeoplePackageDirectoryReader().read(directoryURL: package)
        let local = parent.appendingPathComponent("KnownPeople")
        try await install(admitted, at: local)
        return (local, admitted)
    }
    private func install(_ snapshot: KnownPeoplePackageSnapshot, at local: URL) async throws {
        if !FileManager.default.fileExists(atPath: local.path) {
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        }
        let route = KnownPeopleManagedStoreRoute(rootURL: local, generation: 1, iCloudSyncActive: false, routingActive: false)
        var access = KnownPeopleManagedStoreReplacementAccess()
        access.liveRouteBeforeCommit = { route }
        let replacement = KnownPeopleManagedStoreReplacement(access: access)
        let plan = try await replacement.plan(snapshot: snapshot, route: route)
        let result = await replacement.replace(plan: plan, decision: plan.requiredDecision, currentRoute: route)
        #expect(result.committed && result.failure == nil, "\(result.failure ?? "")")
        _ = try #require(result.revision)
    }
    private func personURL(_ root: URL, _ snapshot: KnownPeoplePackageSnapshot) throws -> URL {
        root.appendingPathComponent("people/\(try #require(snapshot.people.first).id.uuidString).json")
    }
    private func save(_ person: KnownPerson, at url: URL, pretty: Bool = false) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(person).write(to: url)
    }
    private func tree(_ root: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }
    private func capture(_ local: URL, _ admitted: KnownPeoplePackageSnapshot,
                         access: KnownPeopleLocalStoreSnapshotAccess = .init()) async throws -> KnownPeopleLocalStoreSnapshotCapture {
        try await KnownPeopleLocalStoreSnapshotBuilder(access: access).capture(rootURL: local,
            exportedAt: exportedAt, exporter: admitted.manifest.exporter)
    }

    @Test("Unchanged managed projection re-exports the exact admitted golden bytes without writes")
    func exactReuse() async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let (local, admitted) = try await fixture(parent), before = try tree(local)
        let result = try await capture(local, admitted)
        #expect(result.reusedAdmittedBytes && result.snapshot.files == admitted.files)
        #expect(result.snapshot.editor == admitted.editor && result.snapshot.manifest == admitted.manifest)
        #expect(result.snapshot.sourceDirectoryURL.path == local.path)
        #expect(result.snapshot.sourceDevice == result.inventory.device && result.snapshot.sourceInode == result.inventory.inode)
        #expect(result.inventory.files.count == before.count)
        #expect(try tree(local) == before)
    }

    @Test("Semantically equal local JSON with different bytes regenerates instead of reusing stale admitted bytes")
    func rawProjectionChanged() async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let (local, admitted) = try await fixture(parent)
        try save(try #require(admitted.people.first), at: personURL(local, admitted), pretty: true)
        let before = try tree(local), result = try await capture(local, admitted)
        #expect(!result.reusedAdmittedBytes && result.snapshot.files != admitted.files)
        #expect(result.snapshot.manifest.libraryID == admitted.manifest.libraryID)
        #expect(result.snapshot.editor?.people == admitted.editor?.people)
        #expect(result.snapshot.editor?.examples == admitted.editor?.examples)
        #expect(result.snapshot.files["people.json"] == (try canonical(result.snapshot.payload)))
        #expect(try tree(local) == before)
    }

    @Test("Local edits produce deterministic canonical schema2 with exact FEM2 and editor values", arguments: [false, true])
    func canonicalChanges(editorOnly: Bool) async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let (local, admitted) = try await fixture(parent)
        var person = try #require(admitted.people.first)
        if !editorOnly { person.name = "New Åda {persons}" }
        person.notes = "\nNew notes preserved  "; person.role = nil; person.updatedAt = Date(timeIntervalSinceReferenceDate: 123.123456789)
        try save(person, at: personURL(local, admitted))
        let before = try tree(local), first = try await capture(local, admitted), second = try await capture(local, admitted)
        #expect(!first.reusedAdmittedBytes && first.snapshot.files == second.snapshot.files)
        #expect(first.snapshot.manifest.libraryID == admitted.manifest.libraryID)
        #expect(first.snapshot.manifest.exportedAt == exportedAt)
        #expect(first.snapshot.people.first?.notes == person.notes && first.snapshot.people.first?.role == nil)
        #expect(first.snapshot.people.first?.updatedAt == person.updatedAt)
        for (path, bytes) in admitted.files where path.hasSuffix(".fem2") { #expect(first.snapshot.files[path] == bytes) }
        try KnownPeoplePackageSnapshotValidation.validate(first.snapshot)
        let destination = parent.appendingPathComponent("output.aagedalpeople")
        #expect(await KnownPeoplePackageDirectoryWriter().write(snapshot: first.snapshot, destinationURL: destination).completed)
        #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: destination).files == first.snapshot.files)
        #expect(try tree(local) == before)
    }

    @Test("A tracked valid empty library exports; an untracked root requires an owner identity transaction", arguments: [false, true])
    func emptyAndUntracked(untracked: Bool) async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let (local, admitted) = try await fixture(parent)
        try FileManager.default.removeItem(at: personURL(local, admitted))
        if untracked { try FileManager.default.removeItem(at: local.appendingPathComponent(KnownPeopleManagedStoreState.fileName)) }
        let before = try tree(local)
        if untracked {
            await #expect(throws: KnownPeopleLocalStoreSnapshotFailure.identityAssignmentRequired) { try await capture(local, admitted) }
        } else {
            let result = try await capture(local, admitted)
            #expect(result.snapshot.people.isEmpty && result.snapshot.payload.people.isEmpty)
            #expect(result.snapshot.manifest.peopleCount == 0 && result.snapshot.manifest.embeddingCount == 0)
            #expect(result.snapshot.manifest.libraryID == admitted.manifest.libraryID)
            try KnownPeoplePackageSnapshotValidation.validate(result.snapshot)
        }
        #expect(try tree(local) == before)
    }

    @Test("Tombstones, malformed records, unknown provenance, linked entries and legacy roots fail closed",
          arguments: ["tombstone", "malformed", "unknown-field", "unknown-provenance", "duplicate", "symlink", "hardlink", "unreadable", "legacy", "state-hash", "invalid-jpeg"])
    func invalidLocal(kind: String) async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let (local, admitted) = try await fixture(parent), url = try personURL(local, admitted)
        switch kind {
        case "tombstone": try Data("retained deletion".utf8).write(to: url.deletingPathExtension().appendingPathExtension("deleted"))
        case "malformed": try Data([0xff]).write(to: url)
        case "unknown-field":
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            var json = try #require(object as? [String: Any])
            json["unknown-future-field"] = true; try JSONSerialization.data(withJSONObject: json).write(to: url)
        case "unknown-provenance":
            var person = try #require(admitted.people.first), example = try #require(person.embeddings.first)
            example = .init(id: example.id, featurePrintData: example.featurePrintData, sourceDescription: example.sourceDescription,
                addedAt: example.addedAt, recognitionMode: example.recognitionMode, provenance: nil)
            person.embeddings = [example]; try save(person, at: url)
        case "duplicate": try Data(contentsOf: url).write(to: url.deletingLastPathComponent().appendingPathComponent("dddddddd-dddd-dddd-dddd-dddddddddddd.json"))
        case "symlink":
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: parent.appendingPathComponent("missing.json"))
        case "hardlink": try FileManager.default.linkItem(at: url, to: parent.appendingPathComponent("linked-person.json"))
        case "unreadable": #expect(chmod(url.path, 0) == 0)
        case "invalid-jpeg":
            let id = try #require(admitted.people.first).id.uuidString
            try Data([0xff, 0xd8, 0, 1]).write(to: local.appendingPathComponent("thumbnails/\(id).jpg"))
        case "legacy": try Data("legacy database".utf8).write(to: local.appendingPathComponent("database.json"))
        case "state-hash":
            let stateURL = local.appendingPathComponent(KnownPeopleManagedStoreState.fileName)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
            var json = try #require(object as? [String: Any])
            json["managedProjectionSHA256"] = String(repeating: "0", count: 64)
            try JSONSerialization.data(withJSONObject: json).write(to: stateURL)
        default: break
        }
        await #expect(throws: (any Error).self) { try await capture(local, admitted) }
    }

    @Test("Captured bytes and root identity are rechecked after an await boundary", arguments: ["record", "root", "cancel"])
    func changedDuringCapture(kind: String) async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let (local, admitted) = try await fixture(parent), url = try personURL(local, admitted)
        var access = KnownPeopleLocalStoreSnapshotAccess()
        access.beforeFinalValidation = {
            if kind == "cancel" { throw CancellationError() }
            if kind == "root" {
                try FileManager.default.moveItem(at: local, to: parent.appendingPathComponent("moved"))
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
            } else { try Data("external newer record".utf8).write(to: url) }
        }
        await #expect(throws: (any Error).self) { try await capture(local, admitted, access: access) }
        if kind == "record" { #expect(try Data(contentsOf: url) == Data("external newer record".utf8)) }
    }

    @Test("Referenced JPEG bytes survive generation and a later missing referenced thumbnail is refused")
    func thumbnails() async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let (local, admitted) = try await fixture(parent)
        let jpegURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/AnalysisCorpus/jpeg-single-q82.jpg")
        let jpeg = try Data(contentsOf: jpegURL), id = try #require(admitted.people.first).id.uuidString
        let path = "thumbnails/\(id.lowercased()).jpg", localPath = "thumbnails/\(id).jpg"
        try jpeg.write(to: local.appendingPathComponent(localPath))
        let generated = try await capture(local, admitted)
        #expect(generated.snapshot.files[path] == jpeg && generated.snapshot.payload.people.first?.thumbnailPath == path)
        let secondRoot = parent.appendingPathComponent("SecondKnownPeople")
        try await install(generated.snapshot, at: secondRoot)
        try FileManager.default.removeItem(at: secondRoot.appendingPathComponent(localPath))
        await #expect(throws: KnownPeopleLocalStoreSnapshotFailure.missingReferencedThumbnail(path)) {
            try await capture(secondRoot, generated.snapshot)
        }
    }

    @Test("Replacement uses exact uppercase local filenames while builder reuses lowercase package bytes")
    func localFilenameCaseRoundTrip() async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let (local, admitted) = try await fixture(parent)
        let person = try #require(admitted.people.first), example = try #require(person.embeddings.first)
        let jpegURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/AnalysisCorpus/jpeg-single-q82.jpg")
        let jpeg = try Data(contentsOf: jpegURL)
        let localPersonThumbnail = "thumbnails/\(person.id.uuidString).jpg"
        let localExampleThumbnail = "embedding_thumbnails/\(example.id.uuidString).jpg"
        try jpeg.write(to: local.appendingPathComponent(localPersonThumbnail))
        try jpeg.write(to: local.appendingPathComponent(localExampleThumbnail))
        let generated = try await capture(local, admitted)
        let second = parent.appendingPathComponent("CaseSensitiveStyleRoot")
        try await install(generated.snapshot, at: second)

        // Enumerate actual spellings instead of using fileExists on a case-insensitive disk.
        for (directory, expected) in [
            ("people", person.id.uuidString + ".json"),
            ("thumbnails", person.id.uuidString + ".jpg"),
            ("embedding_thumbnails", example.id.uuidString + ".jpg"),
        ] {
            let names = try FileManager.default.contentsOfDirectory(atPath: second.appendingPathComponent(directory).path)
            #expect(names == [expected])
            #expect(!names.contains(expected.lowercased()))
        }
        let raw = try tree(second.appendingPathComponent(".admitted-package"))
        #expect(raw == generated.snapshot.files)
        #expect(raw[localPersonThumbnail.lowercased()] == jpeg && raw[localExampleThumbnail.lowercased()] == jpeg)
        #expect(raw[localPersonThumbnail] == nil && raw[localExampleThumbnail] == nil)
        let before = try tree(second), captured = try await capture(second, generated.snapshot)
        #expect(captured.reusedAdmittedBytes && captured.snapshot.files == generated.snapshot.files)
        #expect(captured.snapshot.editor == generated.snapshot.editor)
        #expect(try tree(second) == before)
    }

    @Test("Case-variant service-local UUID filenames are refused", arguments: ["people", "thumbnails", "embedding_thumbnails"])
    func caseVariantLocalFilename(directory: String) async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let (local, admitted) = try await fixture(parent)
        let person = try #require(admitted.people.first)
        let id = directory == "embedding_thumbnails" ? try #require(person.embeddings.first).id : person.id
        let name = id.uuidString + (directory == "people" ? ".json" : ".jpg")
        let folder = local.appendingPathComponent(directory), original = folder.appendingPathComponent(name)
        if directory != "people" {
            let jpegURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/AnalysisCorpus/jpeg-single-q82.jpg")
            try Data(contentsOf: jpegURL).write(to: original)
        }
        _ = try await capture(local, admitted)
        // Two moves force a real spelling change even on a case-insensitive volume.
        let temporary = parent.appendingPathComponent("renaming-entry")
        try FileManager.default.moveItem(at: original, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent(name.lowercased()))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains(name.lowercased()) && !names.contains(name))
        let before = try tree(local)
        await #expect(throws: (any Error).self) { try await capture(local, admitted) }
        #expect(try tree(local) == before)
    }

    @Test("An admitted manifest presentation edit cannot bypass the exact raw package binding", arguments: ["exportedAt", "exporter", "whitespace"])
    func admittedManifestTamper(kind: String) async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let (local, admitted) = try await fixture(parent)
        let path = local.appendingPathComponent(".admitted-package/manifest.json")
        let original = try Data(contentsOf: path)
        let changed: Data
        if kind == "whitespace" { changed = original + Data("\n ".utf8) }
        else {
            let object = try JSONSerialization.jsonObject(with: original)
            var json = try #require(object as? [String: Any])
            if kind == "exportedAt" { json["exportedAt"] = "2026-09-11T12:00:00.000Z" }
            else {
                var exporter = try #require(json["exporter"] as? [String: Any])
                exporter["app"] = "Externally replaced presentation"; json["exporter"] = exporter
            }
            changed = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        let manifest = try KnownPeoplePackageManifest.decode(changed)
        #expect(manifest.revision == admitted.manifest.revision && manifest.coreRevision == admitted.manifest.coreRevision)
        try changed.write(to: path)
        let before = try tree(local)
        await #expect(throws: KnownPeopleLocalStoreSnapshotFailure.invalidStateBinding) { try await capture(local, admitted) }
        #expect(try tree(local) == before)
    }

    @Test("Root symlinks are rejected at admission, including a trailing separator", arguments: [false, true])
    func rootSymlink(trailingSeparator: Bool) async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let (local, admitted) = try await fixture(parent), alias = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: local)
        let argument = trailingSeparator ? URL(fileURLWithPath: alias.path + "/") : alias
        let before = try tree(local)
        await #expect(throws: KnownPeopleLocalStoreSnapshotFailure.unsafeRoot) { try await capture(argument, admitted) }
        #expect(try tree(local) == before)
    }

    @Test("A renamed root replaced by a symlink is refused at both root-open and final-validation boundaries", arguments: [false, true])
    func rootSymlinkRace(afterOpen: Bool) async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let (local, admitted) = try await fixture(parent), moved = parent.appendingPathComponent("moved")
        let before = try tree(local)
        let replace: @Sendable () throws -> Void = {
            try FileManager.default.moveItem(at: local, to: moved)
            try FileManager.default.createSymbolicLink(at: local, withDestinationURL: moved)
        }
        var access = KnownPeopleLocalStoreSnapshotAccess()
        if afterOpen { access.afterRootOpen = replace } else { access.beforeFinalValidation = replace }
        await #expect(throws: KnownPeopleLocalStoreSnapshotFailure.changedDuringCapture) { try await capture(local, admitted, access: access) }
        #expect(try tree(moved) == before)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: local.path) == moved.path)
    }

    @Test("Actual task cancellation after capture refuses publication without mutating the store")
    func taskCancellation() async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let (local, admitted) = try await fixture(parent), before = try tree(local)
        var access = KnownPeopleLocalStoreSnapshotAccess()
        access.beforeFinalValidation = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { try await capture(local, admitted, access: access) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(task.isCancelled)
        #expect(try tree(local) == before)
    }

    private func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
