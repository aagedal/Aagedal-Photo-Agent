import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Known People strict manual ZIP archive")
struct KnownPeoplePackageArchiveTests {
    private enum Injected: Error { case failure }
    private func files() throws -> [String: Data] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/PeopleLibraryV2")
        let names = ["manifest.json": "manifest.json.base64", "people.json": "people.json.base64",
                     "editor/photo-agent.json": "editor-photo-agent.json.base64",
                     "embeddings/cccccccc-cccc-cccc-cccc-cccccccccccc.fem2": "embedding.fem2.base64"]
        return try names.mapValues { name in
            let encoded = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
                .components(separatedBy: .whitespacesAndNewlines).joined()
            return try #require(Data(base64Encoded: encoded))
        }
    }
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/PeopleZIP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func snapshot(_ root: URL) async throws -> KnownPeoplePackageSnapshot {
        let source = root.appendingPathComponent("source.aagedalpeople")
        for (path, data) in try files() {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
    }

    @Test("Golden archive is deterministic and admits exact bytes through the directory reader")
    func golden() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await snapshot(root), adapter = KnownPeoplePackageArchive()
        let archive = root.appendingPathComponent("export.aagedalpeople.zip")
        let result = try await adapter.export(snapshot: source, to: archive)
        #expect(result.completed, "\(result.failure ?? "")")
        #expect(result.receipt?.installedBytesVerified == true && result.receipt?.parentDirectorySynced == true)
        let bytes = try Data(contentsOf: archive)
        #expect(bytes == (try KnownPeoplePackageArchiveCodec.encode(source.files)))
        #expect(bytes == Self.zip(source.files.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        #expect(try KnownPeoplePackageArchiveCodec.decode(bytes) == source.files)
        let target = root.appendingPathComponent("imported.aagedalpeople")
        let imported = await adapter.importArchive(at: archive, to: target)
        #expect(imported.completed, "\(imported.failure ?? "")")
        let admitted = try await KnownPeoplePackageDirectoryReader().read(directoryURL: target)
        #expect(admitted.files == source.files && admitted.editor == source.editor)
        let second = root.appendingPathComponent("second.aagedalpeople.zip")
        #expect(try await adapter.export(snapshot: admitted, to: second).completed)
        #expect(try Data(contentsOf: second) == bytes)
        #expect(!(await adapter.importArchive(at: archive, to: target)).completed)
        #expect(await adapter.importArchive(at: archive, to: target, overwrite: true).completed)
    }

    @Test("Independent ZIP headers reject traversal, duplicate, collisions, links, compression and oversized ranges before extraction",
          arguments: ["traversal", "absolute", "backslash", "duplicate", "case", "directory", "symlink", "compression", "oversize", "crc", "coverage", "local-name", "extra", "comment", "truncated", "count"])
    func malformed(kind: String) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var entries = try files().sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        switch kind {
        case "traversal": entries[0].0 = "../escaped.json"
        case "absolute": entries[0].0 = "/escaped.json"
        case "backslash": entries[0].0 = "editor\\photo-agent.json"
        case "duplicate": entries.append(entries[0])
        case "case": entries.append((entries[0].0.uppercased(), entries[0].1))
        case "directory": entries.append(("editor/", Data([1])))
        case "coverage": entries.removeLast()
        default: break
        }
        var bytes = Self.zip(entries, type: kind == "symlink" ? UInt32(S_IFLNK | 0o777) : UInt32(S_IFREG | 0o600),
                             method: kind == "compression" ? 8 : 0, oversized: kind == "oversize")
        if kind == "crc" { bytes[30 + entries[0].0.utf8.count] ^= 1 }
        if kind == "local-name" { bytes[30] ^= 1 }
        if kind == "extra" { bytes[28] = 1 }
        if kind == "comment" { bytes[bytes.count - 2] = 1; bytes.append(0) }
        if kind == "truncated" { bytes.removeLast() }
        if kind == "count" { bytes[bytes.count - 12] = 0xff; bytes[bytes.count - 11] = 0xff }
        let archive = root.appendingPathComponent("bad.aagedalpeople.zip"), target = root.appendingPathComponent("output.aagedalpeople")
        try bytes.write(to: archive)
        var access = KnownPeoplePackageArchiveAccess()
        access.beforeMaterialization = { Issue.record("Invalid archive reached materialization") }
        let result = await KnownPeoplePackageArchive(access: access).importArchive(at: archive, to: target)
        #expect(!result.completed && result.receipt == nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [archive.lastPathComponent])
    }

    @Test("Replacement requires explicit authorization; failures before commit preserve prior bytes", arguments: ["failure", "cancel", "changed"])
    func precommit(kind: String) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await snapshot(root), target = root.appendingPathComponent("target.aagedalpeople.zip")
        let original = Data("prior regular output".utf8), newer = Data("independent newer output".utf8)
        try original.write(to: target)
        #expect(!(try await KnownPeoplePackageArchive().export(snapshot: source, to: target)).completed)
        var access = KnownPeoplePackageArchiveAccess()
        access.beforeCommit = {
            if kind == "cancel" { throw CancellationError() }
            if kind == "changed" { try newer.write(to: target); return }
            throw Injected.failure
        }
        let result = try await KnownPeoplePackageArchive(access: access).export(snapshot: source, to: target, overwrite: true)
        #expect(!result.completed && result.receipt == nil && result.recoveryURLs.isEmpty)
        #expect(result.wasCancelled == (kind == "cancel"))
        #expect(try Data(contentsOf: target) == (kind == "changed" ? newer : original))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".KnownPeople-") })
    }

    @Test("Post-write stage admission failure cleans the owned stage without publishing", arguments: [false, true])
    func stageAdmissionFailure(existing: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await snapshot(root), target = root.appendingPathComponent("target.aagedalpeople.zip")
        let previous = Data("prior archive".utf8)
        if existing { try previous.write(to: target) }
        var access = KnownPeoplePackageArchiveAccess()
        access.beforeStageAdmission = { descriptor in
            // Sparse extension forces the actual ArchiveFile initializer to reject its
            // post-write size check, exercising descriptor ownership on that path.
            #expect(ftruncate(descriptor, off_t(KnownPeoplePackageArchiveCodec.maximumArchiveBytes + 1)) == 0)
        }
        let result = try await KnownPeoplePackageArchive(access: access).export(snapshot: source, to: target, overwrite: existing)
        #expect(!result.completed && result.receipt == nil && result.failure != nil)
        #expect(result.recoveryURLs.isEmpty && !result.wasCancelled)
        if existing { #expect(try Data(contentsOf: target) == previous) }
        else { #expect(!FileManager.default.fileExists(atPath: target.path)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".KnownPeople-") })
    }

    @Test("After atomic replacement failure or cancellation reports installed bytes and retains prior archive", arguments: [false, true])
    func postcommit(cancel: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await snapshot(root), target = root.appendingPathComponent("target.aagedalpeople.zip")
        let previous = Data("prior archive".utf8); try previous.write(to: target)
        var access = KnownPeoplePackageArchiveAccess()
        access.afterCommit = { if cancel { throw CancellationError() }; throw Injected.failure }
        let result = try await KnownPeoplePackageArchive(access: access).export(snapshot: source, to: target, overwrite: true)
        #expect(!result.completed && result.receipt?.replacedExistingArchive == true)
        #expect(result.wasCancelled == cancel && result.recoveryURLs.count == 1)
        #expect(try KnownPeoplePackageArchiveCodec.decode(Data(contentsOf: target)) == source.files)
        #expect(try Data(contentsOf: #require(result.recoveryURLs.first)) == previous)
    }

    @Test("Successful replacement consumes backup only after exact readback")
    func replace() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await snapshot(root), target = root.appendingPathComponent("target.aagedalpeople.zip")
        try Data("old".utf8).write(to: target)
        let result = try await KnownPeoplePackageArchive().export(snapshot: source, to: target, overwrite: true)
        #expect(result.completed && result.recoveryURLs.isEmpty && result.receipt?.replacedExistingArchive == true)
        #expect(try KnownPeoplePackageArchiveCodec.decode(Data(contentsOf: target)) == source.files)
    }

    @Test("Unsafe aliases, bare directory suffix and invalid in-memory snapshots never publish")
    func unsafeDestinations() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await snapshot(root), adapter = KnownPeoplePackageArchive()
        let bare = root.appendingPathComponent("wrong.aagedalpeople")
        #expect(!(try await adapter.export(snapshot: source, to: bare)).completed)
        #expect(!(try await adapter.export(snapshot: source, to: source.sourceDirectoryURL.appendingPathComponent("nested.aagedalpeople.zip"))).completed)
        let link = root.appendingPathComponent("linked.aagedalpeople.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.sourceDirectoryURL.appendingPathComponent("manifest.json"))
        #expect(!(try await adapter.export(snapshot: source, to: link, overwrite: true)).completed)
        let hardlink = root.appendingPathComponent("hard.aagedalpeople.zip")
        try FileManager.default.linkItem(at: source.sourceDirectoryURL.appendingPathComponent("manifest.json"), to: hardlink)
        #expect(!(try await adapter.export(snapshot: source, to: hardlink, overwrite: true)).completed)
        var damaged = source.files; damaged["people.json"] = Data([0])
        let invalid = KnownPeoplePackageSnapshot(sourceDirectoryURL: source.sourceDirectoryURL, sourceDevice: source.sourceDevice,
            sourceInode: source.sourceInode, manifest: source.manifest, payload: source.payload, editor: source.editor, files: damaged, people: source.people)
        let fresh = root.appendingPathComponent("fresh.aagedalpeople.zip")
        #expect(!(try await adapter.export(snapshot: invalid, to: fresh)).completed)
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("Cancellation after full admission but before extraction leaves no materialized files")
    func cancelledImport() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("input.aagedalpeople.zip"), output = root.appendingPathComponent("output.aagedalpeople")
        try KnownPeoplePackageArchiveCodec.encode(files()).write(to: archive)
        var access = KnownPeoplePackageArchiveAccess(); access.beforeMaterialization = { throw CancellationError() }
        let result = await KnownPeoplePackageArchive(access: access).importArchive(at: archive, to: output)
        #expect(result.wasCancelled && result.receipt == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [archive.lastPathComponent])
    }

    @Test("Import cleans its real extraction stage after parent move and never touches a counterfeit parent", arguments: [false, true])
    func movedImportParent(counterfeit: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let archive = original.appendingPathComponent("input.aagedalpeople.zip")
        try KnownPeoplePackageArchiveCodec.encode(files()).write(to: archive)
        var access = KnownPeoplePackageArchiveAccess()
        access.beforeCommit = {
            try FileManager.default.moveItem(at: original, to: moved)
            if counterfeit {
                try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
                let name = try #require(FileManager.default.contentsOfDirectory(atPath: moved.path)
                    .first { $0.hasPrefix(".KnownPeople-import-") })
                let fakeStage = original.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: fakeStage, withIntermediateDirectories: false)
                try Data("unrelated sentinel".utf8).write(to: fakeStage.appendingPathComponent("sentinel"))
            }
        }
        let result = await KnownPeoplePackageArchive(access: access).importArchive(at: archive,
            to: original.appendingPathComponent("output.aagedalpeople"))
        #expect(result.completed, "\(result.failure ?? "")")
        #expect(result.recoveryDirectories.isEmpty)
        let receipt = try #require(result.receipt)
        #expect(receipt.destinationURL.path == moved.appendingPathComponent("output.aagedalpeople").path)
        #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: receipt.destinationURL).files == files())
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).allSatisfy { !$0.hasPrefix(".KnownPeople-") })
        if counterfeit {
            let fakeName = try #require(FileManager.default.contentsOfDirectory(atPath: original.path).first)
            #expect(try Data(contentsOf: original.appendingPathComponent(fakeName).appendingPathComponent("sentinel")) == Data("unrelated sentinel".utf8))
        }
    }

    @Test("Export receipt and displaced archive path follow held parent after move", arguments: [false, true], [false, true])
    func movedExportParent(counterfeit: Bool, failAfterCommit: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let source = try await snapshot(original), leaf = "output.aagedalpeople.zip"
        let output = original.appendingPathComponent(leaf), previous = Data("old archive".utf8)
        try previous.write(to: output)
        var access = KnownPeoplePackageArchiveAccess()
        access.beforeCommit = {
            try FileManager.default.moveItem(at: original, to: moved)
            if counterfeit {
                try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
                try Data("unrelated output".utf8).write(to: original.appendingPathComponent(leaf))
            }
        }
        if failAfterCommit { access.afterCommit = { throw Injected.failure } }
        let result = try await KnownPeoplePackageArchive(access: access).export(snapshot: source, to: output, overwrite: true)
        #expect(result.completed == !failAfterCommit, "\(result.failure ?? "")")
        let receipt = try #require(result.receipt)
        #expect(receipt.destinationURL.path == moved.appendingPathComponent(leaf).path)
        #expect(try KnownPeoplePackageArchiveCodec.decode(Data(contentsOf: receipt.destinationURL)) == source.files)
        if failAfterCommit {
            let backup = try #require(result.recoveryURLs.first)
            #expect(backup.deletingLastPathComponent().path == moved.path)
            #expect(try Data(contentsOf: backup) == previous)
        } else { #expect(result.recoveryURLs.isEmpty) }
        if counterfeit { #expect(try Data(contentsOf: output) == Data("unrelated output".utf8)) }
    }

    @Test("Unfinished import cleanup is explicit and reports the actual retained stage")
    func cleanupFailure() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("input.aagedalpeople.zip"), rescue = root.appendingPathComponent("retained-stage")
        try KnownPeoplePackageArchiveCodec.encode(files()).write(to: archive)
        var access = KnownPeoplePackageArchiveAccess()
        access.afterCommit = {
            let stage = try #require(FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasPrefix(".KnownPeople-import-") })
            try FileManager.default.moveItem(at: root.appendingPathComponent(stage), to: rescue)
        }
        let result = await KnownPeoplePackageArchive(access: access).importArchive(at: archive, to: root.appendingPathComponent("output.aagedalpeople"))
        #expect(result.receipt != nil && !result.completed && result.failure != nil)
        #expect(result.recoveryDirectories.map(\.path) == [rescue.path])
        #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: rescue).files == files())
    }

    /// Independent fixture assembler permits intentionally invalid headers and duplicate names.
    private static func zip(_ entries: [(String, Data)], type: UInt32 = UInt32(S_IFREG | 0o600),
                            method: UInt16 = 0, oversized: Bool = false) -> Data {
        func u16(_ value: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
        func u32(_ value: UInt32) -> Data { u16(UInt16(truncatingIfNeeded: value)) + u16(UInt16(truncatingIfNeeded: value >> 16)) }
        func crc(_ data: Data) -> UInt32 {
            var value: UInt32 = 0xffffffff
            for byte in data { value ^= UInt32(byte); for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1 } }
            return value ^ 0xffffffff
        }
        var body = Data(), index = Data()
        for (path, data) in entries {
            let name = Data(path.utf8), checksum = crc(data), offset = body.count
            let size = oversized ? UInt32(16_777_217) : UInt32(data.count)
            body += u32(0x04034b50) + u16(20) + u16(0x800) + u16(method) + u16(0) + u16(0x21)
            body += u32(checksum) + u32(size) + u32(size) + u16(UInt16(name.count)) + u16(0) + name + data
            index += u32(0x02014b50) + u16(0x314) + u16(20) + u16(0x800) + u16(method) + u16(0) + u16(0x21)
            index += u32(checksum) + u32(size) + u32(size) + u16(UInt16(name.count)) + u16(0) + u16(0) + u16(0) + u16(0)
            index += u32(type << 16) + u32(UInt32(offset)) + name
        }
        let offset = body.count; body += index
        body += u32(0x06054b50) + u16(0) + u16(0) + u16(UInt16(entries.count)) + u16(UInt16(entries.count))
        body += u32(UInt32(index.count)) + u32(UInt32(offset)) + u16(0)
        return body
    }
}
