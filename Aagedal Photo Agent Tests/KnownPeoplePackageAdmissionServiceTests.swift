import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Known People unified schema-2 admission")
struct KnownPeoplePackageAdmissionServiceTests {
    private enum Injected: Error { case failure }
    private func parent() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/PeopleAdmission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func fixture(_ parent: URL) throws -> (directory: URL, archive: URL, temporary: URL, files: [String: Data]) {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/PeopleLibraryV2")
        var files: [String: Data] = [:]
        for (path, name) in ["manifest.json": "manifest.json.base64", "people.json": "people.json.base64",
            "editor/photo-agent.json": "editor-photo-agent.json.base64",
            "embeddings/cccccccc-cccc-cccc-cccc-cccccccccccc.fem2": "embedding.fem2.base64"] {
            let text = try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8)
            files[path] = try #require(Data(base64Encoded: text.components(separatedBy: .whitespacesAndNewlines).joined()))
        }
        let directory = parent.appendingPathComponent("golden.aagedalpeople")
        for (path, bytes) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let archive = parent.appendingPathComponent("golden.aagedalpeople.zip")
        try KnownPeoplePackageArchiveCodec.encode(files).write(to: archive)
        let temporary = parent.appendingPathComponent("temporary")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        return (directory, archive, temporary, files)
    }
    private func canonicalPeople(_ people: [KnownPerson]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(people)
    }

    @Test("Directory and archive inputs admit identical bytes and support managed planning after extraction cleanup")
    func equivalentAdmissions() async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = try fixture(parent), originalArchive = try Data(contentsOf: fixture.archive)
        let service = KnownPeoplePackageAdmissionService(temporaryParentURL: fixture.temporary)
        let directoryResult = await service.admit(at: fixture.directory)
        let archiveResult = await service.admit(at: fixture.archive)
        #expect(directoryResult.completed && archiveResult.completed)
        let directory = try #require(directoryResult.admission), archive = try #require(archiveResult.admission)
        #expect(directory.files == fixture.files && archive.files == fixture.files)
        #expect(directory.manifest == archive.manifest && directory.payload == archive.payload && directory.editor == archive.editor)
        #expect(try canonicalPeople(directory.people) == canonicalPeople(archive.people))
        #expect(directory.provenance.kind == .directoryPackage && archive.provenance.kind == .archive)
        #expect(archive.provenance.sourceURL.path == fixture.archive.path)
        #expect(archive.provenance.archiveByteCount == originalArchive.count)
        #expect(archive.provenance.archiveSHA256 == SHA256.hash(data: originalArchive).map { String(format: "%02x", $0) }.joined())
        #expect(directory.provenance.archiveSHA256 == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty)
        #expect(try Data(contentsOf: fixture.archive) == originalArchive)

        let managed = parent.appendingPathComponent("KnownPeople")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: false)
        let route = KnownPeopleManagedStoreRoute(rootURL: managed, generation: 1, iCloudSyncActive: false, routingActive: false)
        let plan = try await archive.planReplacement(route: route)
        #expect(plan.snapshot.files == fixture.files && plan.requiredDecision == .replaceUntracked)
        #expect(!FileManager.default.fileExists(atPath: plan.snapshot.sourceDirectoryURL.path))
        let result = await KnownPeopleManagedStoreReplacement().replace(plan: plan, decision: .replaceUntracked, currentRoute: route)
        #expect(result.committed && result.failure == nil)
        #expect(try await KnownPeopleManagedStoreReplacement().admittedPackageFiles(root: managed) == fixture.files)
    }

    @Test("Only exact compound extensions and matching regular input kinds are dispatched",
          arguments: ["legacy.zip", "wrong.zip.aagedalpeople.zip.zip", "name.AAGEDALPEOPLE.zip", "name.aagedalpeople.ZIP",
                      "name.aagedalpeople.bak", "bare-file.aagedalpeople", "directory.aagedalpeople.zip", ".aagedalpeople.zip"])
    func invalidNamesAndKinds(name: String) async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = try fixture(parent), input = parent.appendingPathComponent(name)
        if name == "directory.aagedalpeople.zip" { try FileManager.default.copyItem(at: fixture.directory, to: input) }
        else { try FileManager.default.copyItem(at: fixture.archive, to: input) }
        let result = await KnownPeoplePackageAdmissionService(temporaryParentURL: fixture.temporary).admit(at: input)
        #expect(!result.completed && result.admission == nil && result.failure != nil && result.recoveryDirectories.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty)
    }

    @Test("Source symlinks, ancestor aliases, hardlinks and Finder aliases are refused",
          arguments: ["directory-link", "archive-link", "ancestor-link", "hardlink", "finder-alias"])
    func unsafeAliases(kind: String) async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = try fixture(parent)
        let input: URL
        switch kind {
        case "directory-link":
            input = parent.appendingPathComponent("linked.aagedalpeople")
            try FileManager.default.createSymbolicLink(at: input, withDestinationURL: fixture.directory)
        case "archive-link":
            input = parent.appendingPathComponent("linked.aagedalpeople.zip")
            try FileManager.default.createSymbolicLink(at: input, withDestinationURL: fixture.archive)
        case "ancestor-link":
            let alias = parent.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
            input = alias.appendingPathComponent(fixture.archive.lastPathComponent)
        case "hardlink":
            input = parent.appendingPathComponent("linked.aagedalpeople.zip")
            #expect(link(fixture.archive.path, input.path) == 0)
        default:
            input = parent.appendingPathComponent("alias.aagedalpeople.zip")
            let bookmark = try fixture.archive.bookmarkData(options: .suitableForBookmarkFile)
            try URL.writeBookmarkData(bookmark, to: input)
            #expect(try input.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)
        }
        let result = await KnownPeoplePackageAdmissionService(temporaryParentURL: fixture.temporary).admit(at: input)
        #expect(!result.completed && result.admission == nil && result.failure != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty)
    }

    @Test("Renaming a legacy ZIP to the schema-2 compound suffix does not enable fallback")
    func renamedLegacyZIP() async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = try fixture(parent), input = parent.appendingPathComponent("legacy.aagedalpeople.zip")
        // Independently generated ZIP32 STORED/UTF-8 headers and valid CRCs, containing
        // a legacy database.json and schema-1 manifest. Failure must precede extraction.
        let bytes = try #require(Data(base64Encoded: "UEsDBBQAAAgAAAAAIQDwsdUxDQAAAA0AAAANAAAAZGF0YWJhc2UuanNvbnsicGVvcGxlIjpbXX1QSwMEFAAACAAAAAAhAAWrClkTAAAAEwAAAA0AAABtYW5pZmVzdC5qc29ueyJzY2hlbWFWZXJzaW9uIjoxfVBLAQIUAxQAAAgAAAAAIQDwsdUxDQAAAA0AAAANAAAAAAAAAAAAAACAgQAAAABkYXRhYmFzZS5qc29uUEsBAhQDFAAACAAAAAAhAAWrClkTAAAAEwAAAA0AAAAAAAAAAAAAAICBOAAAAG1hbmlmZXN0Lmpzb25QSwUGAAAAAAIAAgB2AAAAdgAAAAAA"))
        try bytes.write(to: input)
        var access = KnownPeoplePackageArchiveAccess()
        access.beforeMaterialization = { Issue.record("Legacy ZIP reached schema-2 extraction") }
        let result = await KnownPeoplePackageAdmissionService(archiveAccess: access, temporaryParentURL: fixture.temporary).admit(at: input)
        #expect(!result.completed && result.admission == nil && result.failure != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty)
        #expect(try Data(contentsOf: input) == bytes)
    }

    @Test("Tampered schema-2 input or extracted bytes never become managed admissions", arguments: ["directory", "archive", "stage", "source-after-decode", "source-replaced"])
    func tamper(kind: String) async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = try fixture(parent)
        var access = KnownPeoplePackageArchiveAccess()
        var input = fixture.archive
        if kind == "directory" {
            input = fixture.directory
            try Data("tampered".utf8).write(to: fixture.directory.appendingPathComponent("people.json"))
        } else if kind == "archive" {
            var bytes = try Data(contentsOf: fixture.archive); bytes[50] ^= 1
            try bytes.write(to: fixture.archive)
        } else {
            access.beforeAdmissionReadback = { stage in
                if kind == "stage" { try Data("tampered".utf8).write(to: stage.appendingPathComponent("people.json")) }
                else if kind == "source-replaced" {
                    try FileManager.default.moveItem(at: fixture.archive, to: parent.appendingPathComponent("original.zip"))
                    try FileManager.default.createSymbolicLink(at: fixture.archive, withDestinationURL: parent.appendingPathComponent("original.zip"))
                } else { try Data("newer archive".utf8).write(to: fixture.archive) }
            }
        }
        let result = await KnownPeoplePackageAdmissionService(archiveAccess: access, temporaryParentURL: fixture.temporary).admit(at: input)
        #expect(!result.completed && result.admission == nil && result.failure != nil)
        #expect(result.recoveryDirectories.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty)
    }

    @Test("Actual task cancellation cleans extracted files and never publishes admission", arguments: [false, true])
    func cancellation(afterMaterialization: Bool) async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = try fixture(parent), bytes = try Data(contentsOf: fixture.archive)
        var access = KnownPeoplePackageArchiveAccess()
        if afterMaterialization {
            access.beforeAdmissionReadback = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        } else { access.beforeMaterialization = { withUnsafeCurrentTask { $0?.cancel() } } }
        let service = KnownPeoplePackageAdmissionService(archiveAccess: access, temporaryParentURL: fixture.temporary)
        let result = await Task { await service.admit(at: fixture.archive) }.value
        #expect(result.wasCancelled && result.admission == nil && !result.completed)
        #expect(result.recoveryDirectories.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty)
        #expect(try Data(contentsOf: fixture.archive) == bytes)
    }

    @Test("Cleanup failure withholds admission and returns the actual retained private tree")
    func cleanupFailure() async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = try fixture(parent), bytes = try Data(contentsOf: fixture.archive)
        var access = KnownPeoplePackageArchiveAccess()
        access.beforeAdmissionCleanup = { _ in throw Injected.failure }
        let result = await KnownPeoplePackageAdmissionService(archiveAccess: access, temporaryParentURL: fixture.temporary).admit(at: fixture.archive)
        #expect(!result.completed && result.admission == nil && result.failure?.contains("cleanup did not finish") == true)
        let retained = try #require(result.recoveryDirectories.first)
        #expect(result.recoveryDirectories.count == 1)
        #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: retained).files == fixture.files)
        #expect(try Data(contentsOf: fixture.archive) == bytes)
    }

    @Test("Cleanup follows its held parent after rename and preserves a counterfeit lexical parent", arguments: [false, true])
    func movedTemporaryParent(failCleanup: Bool) async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = try fixture(parent), moved = parent.appendingPathComponent("moved-temporary")
        let marker = Data("independent temporary directory".utf8)
        var access = KnownPeoplePackageArchiveAccess()
        access.beforeAdmissionCleanup = { _ in
            try FileManager.default.moveItem(at: fixture.temporary, to: moved)
            try FileManager.default.createDirectory(at: fixture.temporary, withIntermediateDirectories: false)
            try marker.write(to: fixture.temporary.appendingPathComponent("keep.txt"))
            if failCleanup { throw Injected.failure }
        }
        let result = await KnownPeoplePackageAdmissionService(archiveAccess: access, temporaryParentURL: fixture.temporary).admit(at: fixture.archive)
        #expect(result.completed == !failCleanup)
        #expect(try Data(contentsOf: fixture.temporary.appendingPathComponent("keep.txt")) == marker)
        if failCleanup {
            let retained = try #require(result.recoveryDirectories.first)
            #expect(retained.deletingLastPathComponent().path == moved.path)
            #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: retained).files == fixture.files)
        } else {
            #expect(result.recoveryDirectories.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
        }
    }
}
