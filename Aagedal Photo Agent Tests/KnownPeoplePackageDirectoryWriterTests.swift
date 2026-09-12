import Foundation
import Dispatch
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Known People directory package writer")
struct KnownPeoplePackageDirectoryWriterTests {
    private enum Injected: Error { case failure }

    private func fixtureFiles() throws -> [String: Data] {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PeopleLibraryV2")
        var files: [String: Data] = [:]
        let fixtureNames = [
            "manifest.json": "manifest.json.base64",
            "people.json": "people.json.base64",
            "editor/photo-agent.json": "editor-photo-agent.json.base64",
            "embeddings/cccccccc-cccc-cccc-cccc-cccccccccccc.fem2": "embedding.fem2.base64",
        ]
        for (path, name) in fixtureNames {
            let value = try String(contentsOf: fixture.appendingPathComponent(
                name), encoding: .utf8)
            let encoded = value.components(separatedBy: .whitespacesAndNewlines).joined()
            files[path] = try #require(Data(base64Encoded: encoded))
        }
        return files
    }

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/PeopleWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func put(_ files: [String: Data], at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (path, bytes) in files {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
        }
    }

    private func noStaging(in directory: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .allSatisfy { !$0.hasPrefix(".KnownPeople-export-") }
    }

    private func priorFiles() throws -> [String: Data] {
        var files = try fixtureFiles()
        // Exporter/time are excluded from recognition and overall revisions, but the
        // original manifest bytes still distinguish the previous directory exactly.
        let manifest = String(decoding: try #require(files["manifest.json"]), as: UTF8.self)
        files["manifest.json"] = Data(manifest.replacingOccurrences(of: "Cross-app fixture", with: "Prior saved package").utf8)
        return files
    }

    @Test("Golden bytes round-trip through new destination and atomic replacement", arguments: [false, true])
    func goldenRoundTrip(replace: Bool) async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aagedalpeople")
        let destination = directory.appendingPathComponent("output.aagedalpeople")
        let files = try fixtureFiles(); try put(files, at: source)
        if replace { try put(priorFiles(), at: destination) }
        let snapshot = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        let result = await KnownPeoplePackageDirectoryWriter().write(snapshot: snapshot, destinationURL: destination)
        #expect(result.completed, "Writer failure: \(result.failure ?? "none")")
        #expect(result.failure == nil && !result.wasCancelled && result.recoveryDirectories.isEmpty)
        let receipt = try #require(result.receipt, "Writer failure: \(result.failure ?? "none")")
        #expect(receipt.replacedExistingDirectory == replace && receipt.parentDirectorySynced)
        #expect(receipt.installedSnapshotVerified)
        #expect(receipt.revision == "12324ae00b79094d239447531d81348e4c6450b7a65fbc329daab261c08025ba")
        let written = try await KnownPeoplePackageDirectoryReader().read(directoryURL: destination)
        #expect(written.files == files)
        #expect(written.manifest.coreRevision == "636f498dba7a9bb357ece23e2f5edcd02997fb4df1acc1e1101eecfd32438e83")
        #expect(try noStaging(in: directory))
        #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: source).files == files)
    }

    @Test("Precommit failures leave old destination intact and never expose partial output", arguments: [
        "write", "readback", "before-commit", "install", "cancel"
    ], [false, true])
    func precommitFailure(stage: String, replace: Bool) async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aagedalpeople")
        let destination = directory.appendingPathComponent("output.aagedalpeople")
        let files = try fixtureFiles(); let old = try priorFiles()
        try put(files, at: source)
        if replace { try put(old, at: destination) }
        let snapshot = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        var access = KnownPeoplePackageWriteAccess()
        if stage == "write" || stage == "readback" {
            access.writeFile = { bytes, path, staging in
                try KnownPeoplePackageWriterFilesystem.writeFile(bytes, path, staging)
                if stage == "write" { throw Injected.failure }
                try Data([1]).write(to: KnownPeoplePackageWriterFilesystem.directoryURL(staging)
                    .appendingPathComponent(path))
            }
        }
        if stage == "before-commit" { access.beforeCommit = { throw Injected.failure } }
        if stage == "install" { access.install = { _, _ in throw Injected.failure } }
        if stage == "cancel" { access.beforeCommit = { withUnsafeCurrentTask { $0?.cancel() } } }
        let writer = KnownPeoplePackageDirectoryWriter(access: access)
        let task = Task { await writer.write(snapshot: snapshot, destinationURL: destination) }
        let result = await task.value
        #expect(!result.completed && result.receipt == nil)
        #expect(result.wasCancelled == (stage == "cancel"))
        if replace {
            #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: destination).files == old)
        } else { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
        #expect(try noStaging(in: directory))
        #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: source).files == files)
    }

    @Test("Postcommit errors and cancellation retain commit evidence and the replaced package", arguments: [
        "install-after-rename", "sync", "after-commit", "cancel", "cleanup", "cleanup-missing"
    ])
    func postcommitFailure(stage: String) async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aagedalpeople")
        let destination = directory.appendingPathComponent("output.aagedalpeople")
        let files = try fixtureFiles(); let old = try priorFiles()
        try put(files, at: source); try put(old, at: destination)
        let snapshot = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        var access = KnownPeoplePackageWriteAccess()
        switch stage {
        case "install-after-rename": access.install = { plan, committed in
            try KnownPeoplePackageWriterFilesystem.install(plan, onCommitted: committed)
            throw Injected.failure
        }
        case "sync": access.syncParent = { _ in throw Injected.failure }
        case "after-commit": access.afterCommit = { throw Injected.failure }
        case "cancel": access.afterCommit = { withUnsafeCurrentTask { $0?.cancel() } }
        case "cleanup": access.removeOwned = { _, _, _ in throw Injected.failure }
        default: access.removeOwned = { parent, name, expected in
            let path = try KnownPeoplePackageWriterFilesystem.entryURL(parent, name)
            try FileManager.default.removeItem(at: path)
            try KnownPeoplePackageWriterFilesystem.removeOwned(parent, name, expected)
        }
        }
        let writer = KnownPeoplePackageDirectoryWriter(access: access)
        let result = await Task { await writer.write(snapshot: snapshot, destinationURL: destination) }.value
        #expect(!result.completed)
        let receipt = try #require(result.receipt, "Writer failure: \(result.failure ?? "none")")
        #expect(receipt.replacedExistingDirectory)
        #expect(receipt.parentDirectorySynced == !["install-after-rename", "sync"].contains(stage))
        #expect(receipt.installedSnapshotVerified == ["sync", "cleanup", "cleanup-missing"].contains(stage))
        #expect(result.wasCancelled == (stage == "cancel"))
        #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: destination).files == files)
        let backup = try #require(result.recoveryDirectories.first)
        #expect(result.recoveryDirectories.count == 1)
        if stage == "cleanup-missing" {
            #expect(!FileManager.default.fileExists(atPath: backup.path))
            #expect(result.failure != nil)
        } else {
            #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: backup).files == old)
        }
    }

    @Test("Forged in-memory snapshots fail before staging", arguments: ["extra-file", "hash", "people", "editor"])
    func invalidSnapshot(kind: String) async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aagedalpeople")
        let destination = directory.appendingPathComponent("output.aagedalpeople")
        try put(fixtureFiles(), at: source)
        let original = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        var files = original.files
        var people = original.people
        if kind == "extra-file" { files["../escape"] = Data([1]) }
        if kind == "hash" { files["people.json"] = Data([1]) }
        if kind == "people" { people[0].notes = "Forged editor projection" }
        let altered = KnownPeoplePackageSnapshot(sourceDirectoryURL: original.sourceDirectoryURL,
            sourceDevice: original.sourceDevice, sourceInode: original.sourceInode,
            manifest: original.manifest, payload: original.payload, editor: kind == "editor" ? nil : original.editor,
            files: files, people: people)
        var access = KnownPeoplePackageWriteAccess()
        access.createStage = { _, _ in Issue.record("Invalid snapshot reached filesystem staging"); throw Injected.failure }
        let result = await KnownPeoplePackageDirectoryWriter(access: access).write(snapshot: altered, destinationURL: destination)
        #expect(result.receipt == nil && result.failure != nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try noStaging(in: directory))
    }

    @Test("Source aliases and source/destination nesting are refused", arguments: ["same", "alias", "inside"])
    func sourceOverlap(kind: String) async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aagedalpeople")
        let files = try fixtureFiles(); try put(files, at: source)
        let snapshot = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        let destination: URL
        if kind == "same" { destination = source }
        else if kind == "inside" { destination = source.appendingPathComponent("inside.aagedalpeople") }
        else {
            destination = directory.appendingPathComponent("alias.aagedalpeople")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        }
        let result = await KnownPeoplePackageDirectoryWriter().write(snapshot: snapshot, destinationURL: destination)
        #expect(result.receipt == nil && result.failure != nil)
        #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: source).files == files)
        #expect(try noStaging(in: directory))
    }

    @Test("A concurrently changed nested destination file is not overwritten")
    func changedDestination() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aagedalpeople")
        let destination = directory.appendingPathComponent("output.aagedalpeople")
        try put(fixtureFiles(), at: source); try put(priorFiles(), at: destination)
        let snapshot = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        let changed = Data("External editor bytes must survive".utf8)
        var access = KnownPeoplePackageWriteAccess()
        access.beforeCommit = { try changed.write(to: destination.appendingPathComponent("editor/photo-agent.json")) }
        let result = await KnownPeoplePackageDirectoryWriter(access: access).write(snapshot: snapshot, destinationURL: destination)
        #expect(result.receipt == nil && result.failure != nil)
        #expect(try Data(contentsOf: destination.appendingPathComponent("editor/photo-agent.json")) == changed)
        #expect(try noStaging(in: directory))
    }

    @Test("An independently arriving destination survives exclusive-install refusal")
    func arrivingDestination() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aagedalpeople")
        let destination = directory.appendingPathComponent("output.aagedalpeople")
        try put(fixtureFiles(), at: source)
        let snapshot = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        var access = KnownPeoplePackageWriteAccess()
        access.beforeCommit = {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data([9]).write(to: destination.appendingPathComponent("independent"))
        }
        let result = await KnownPeoplePackageDirectoryWriter(access: access).write(snapshot: snapshot, destinationURL: destination)
        #expect(result.receipt == nil && result.failure != nil)
        #expect(try Data(contentsOf: destination.appendingPathComponent("independent")) == Data([9]))
        #expect(try noStaging(in: directory))
    }

    @Test("Install-window mutations are refused through held directory validation", arguments: [
        "stage", "destination"
    ])
    func installWindowMutation(kind: String) async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aagedalpeople")
        let destination = directory.appendingPathComponent("output.aagedalpeople")
        let files = try fixtureFiles(); let old = try priorFiles()
        try put(files, at: source); try put(old, at: destination)
        let snapshot = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        let changed = Data("Install-window external bytes".utf8)
        var access = KnownPeoplePackageWriteAccess()
        access.beforeRenameValidation = {
            let target: URL
            if kind == "stage" {
                guard let name = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    .first(where: { $0.hasPrefix(".KnownPeople-export-") }) else { throw Injected.failure }
                target = directory.appendingPathComponent(name)
            } else {
                target = destination
            }
            try changed.write(to: target.appendingPathComponent("editor/photo-agent.json"))
        }
        let result = await KnownPeoplePackageDirectoryWriter(access: access)
            .write(snapshot: snapshot, destinationURL: destination)
        #expect(result.receipt == nil && result.failure != nil && !result.wasCancelled)
        if kind == "destination" {
            #expect(try Data(contentsOf: destination.appendingPathComponent("editor/photo-agent.json")) == changed)
        } else {
            #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: destination).files == old)
        }
        #expect(try noStaging(in: directory))
    }

    @Test("Mutations inside install retain commit truth and recovery", arguments: [
        "stage-before", "destination-before", "destination-after"
    ])
    func mutationInsideInstall(kind: String) async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aagedalpeople")
        let destination = directory.appendingPathComponent("output.aagedalpeople")
        let files = try fixtureFiles(); let old = try priorFiles()
        try put(files, at: source); try put(old, at: destination)
        let snapshot = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        let changed = Data("Mutation inside install".utf8)
        var access = KnownPeoplePackageWriteAccess()
        access.install = { plan, committed in
            if kind == "stage-before" {
                try changed.write(to: KnownPeoplePackageWriterFilesystem.entryURL(plan.parent, plan.stageName)
                    .appendingPathComponent("editor/photo-agent.json"))
            } else if kind == "destination-before" {
                try changed.write(to: KnownPeoplePackageWriterFilesystem.entryURL(plan.parent, plan.destinationName)
                    .appendingPathComponent("editor/photo-agent.json"))
            }
            try KnownPeoplePackageWriterFilesystem.install(plan, onCommitted: committed)
            if kind == "destination-after" {
                try changed.write(to: KnownPeoplePackageWriterFilesystem.entryURL(plan.parent, plan.destinationName)
                    .appendingPathComponent("editor/photo-agent.json"))
            }
        }
        let result = await KnownPeoplePackageDirectoryWriter(access: access)
            .write(snapshot: snapshot, destinationURL: destination)
        let receipt = try #require(result.receipt)
        #expect(!result.completed && result.failure != nil && !result.wasCancelled)
        #expect(!receipt.installedSnapshotVerified)
        #expect(result.recoveryDirectories.count == 1)
        let recovery = try #require(result.recoveryDirectories.first)
        if kind == "destination-before" {
            #expect(try Data(contentsOf: recovery.appendingPathComponent("editor/photo-agent.json")) == changed)
            #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: destination).files == files)
        } else {
            #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: recovery).files == old)
            #expect(try Data(contentsOf: destination.appendingPathComponent("editor/photo-agent.json")) == changed)
        }
    }

    @Test("Mutations after initial commit validation retain recovery", arguments: [
        "nested", "replacement"
    ])
    func afterCommitMutation(kind: String) async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aagedalpeople")
        let destination = directory.appendingPathComponent("output.aagedalpeople")
        let movedInstalled = directory.appendingPathComponent("externally-moved.aagedalpeople")
        let files = try fixtureFiles(); let old = try priorFiles()
        try put(files, at: source); try put(old, at: destination)
        let snapshot = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        let changed = Data("Mutation after initial commit validation".utf8)
        var access = KnownPeoplePackageWriteAccess()
        access.afterCommit = {
            if kind == "nested" {
                try changed.write(to: destination.appendingPathComponent("editor/photo-agent.json"))
            } else {
                try FileManager.default.moveItem(at: destination, to: movedInstalled)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                try changed.write(to: destination.appendingPathComponent("counterfeit"))
            }
        }

        let result = await KnownPeoplePackageDirectoryWriter(access: access)
            .write(snapshot: snapshot, destinationURL: destination)

        let receipt = try #require(result.receipt)
        #expect(!result.completed && result.failure != nil && !result.wasCancelled)
        #expect(!receipt.installedSnapshotVerified)
        #expect(result.recoveryDirectories.count == 1)
        let recovery = try #require(result.recoveryDirectories.first)
        #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: recovery).files == old)
        if kind == "nested" {
            #expect(try Data(contentsOf: destination.appendingPathComponent("editor/photo-agent.json")) == changed)
        } else {
            #expect(try Data(contentsOf: destination.appendingPathComponent("counterfeit")) == changed)
            #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: movedInstalled).files == files)
        }
    }

    @Test("A moved and counterfeited parent cannot retarget the held transaction")
    func parentRetarget() async throws {
        let directory = try root()
        let moved = directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + "-moved", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: moved)
        }
        let source = directory.appendingPathComponent("source.aagedalpeople")
        let destination = directory.appendingPathComponent("output.aagedalpeople")
        let files = try fixtureFiles(); try put(files, at: source)
        let snapshot = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        let counterfeit = Data([7, 8, 9])
        var access = KnownPeoplePackageWriteAccess()
        access.beforeRenameValidation = {
            guard let stageName = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .first(where: { $0.hasPrefix(".KnownPeople-export-") }) else { throw Injected.failure }
            try FileManager.default.moveItem(at: directory, to: moved)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let counterfeitStage = directory.appendingPathComponent(stageName, isDirectory: true)
            let counterfeitDestination = directory.appendingPathComponent("output.aagedalpeople", isDirectory: true)
            try FileManager.default.createDirectory(at: counterfeitStage, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: counterfeitDestination, withIntermediateDirectories: false)
            try counterfeit.write(to: counterfeitStage.appendingPathComponent("marker"))
            try counterfeit.write(to: counterfeitDestination.appendingPathComponent("marker"))
        }
        let result = await KnownPeoplePackageDirectoryWriter(access: access)
            .write(snapshot: snapshot, destinationURL: destination)
        let receipt = try #require(result.receipt, "Writer failure: \(result.failure ?? "none")")
        #expect(result.completed)
        #expect(receipt.destinationURL == moved.appendingPathComponent("output.aagedalpeople", isDirectory: true))
        #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: receipt.destinationURL).files == files)
        #expect(try Data(contentsOf: destination.appendingPathComponent("marker")) == counterfeit)
    }

    @Test("Cancellation at the cleanup boundary retains the displaced package")
    func cleanupBoundaryCancellation() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aagedalpeople")
        let destination = directory.appendingPathComponent("output.aagedalpeople")
        let files = try fixtureFiles(); let old = try priorFiles()
        try put(files, at: source); try put(old, at: destination)
        let snapshot = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        var access = KnownPeoplePackageWriteAccess()
        access.beforeCleanupRemoval = { withUnsafeCurrentTask { $0?.cancel() } }
        let result = await Task {
            await KnownPeoplePackageDirectoryWriter(access: access)
                .write(snapshot: snapshot, destinationURL: destination)
        }.value
        #expect(result.receipt != nil && result.wasCancelled && result.failure == nil)
        #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: destination).files == files)
        let recovery = try #require(result.recoveryDirectories.first)
        #expect(result.recoveryDirectories.count == 1)
        #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: recovery).files == old)
    }

    @Test("Independent writer instances serialize replacement through the parent lock")
    func independentWritersSerialize() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aagedalpeople")
        let destination = directory.appendingPathComponent("output.aagedalpeople")
        let files = try fixtureFiles(); try put(files, at: source); try put(priorFiles(), at: destination)
        let snapshot = try await KnownPeoplePackageDirectoryReader().read(directoryURL: source)
        let firstEntered = KnownPeopleWriterTestGate()
        let releaseFirst = KnownPeopleWriterTestGate()
        let secondEntered = KnownPeopleWriterTestGate()
        var firstAccess = KnownPeoplePackageWriteAccess()
        firstAccess.beforeCommit = {
            firstEntered.signal()
            releaseFirst.waitUntilSignalled()
        }
        var secondAccess = KnownPeoplePackageWriteAccess()
        secondAccess.beforeCommit = { secondEntered.signal() }
        let first = Task {
            await KnownPeoplePackageDirectoryWriter(access: firstAccess)
                .write(snapshot: snapshot, destinationURL: destination)
        }
        let firstDidEnter = await firstEntered.waitForSignal(seconds: 2)
        #expect(firstDidEnter)
        let second = Task {
            await KnownPeoplePackageDirectoryWriter(access: secondAccess)
                .write(snapshot: snapshot, destinationURL: destination)
        }
        let secondEnteredEarly = await secondEntered.waitForSignal(seconds: 0.2)
        #expect(!secondEnteredEarly)
        releaseFirst.signal()
        let firstResult = await first.value
        let secondDidEnter = await secondEntered.waitForSignal(seconds: 2)
        #expect(secondDidEnter)
        let secondResult = await second.value
        #expect(firstResult.completed && secondResult.completed)
        #expect(try await KnownPeoplePackageDirectoryReader().read(directoryURL: destination).files == files)
        #expect(try noStaging(in: directory))
    }
}

private nonisolated final class KnownPeopleWriterTestGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var signalled = false

    func signal() {
        lock.withLock { signalled = true }
        semaphore.signal()
    }
    func waitUntilSignalled() { semaphore.wait() }
    func waitForSignal(seconds: Double) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)
        while !lock.withLock({ signalled }), clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(5))
        }
        return lock.withLock { signalled }
    }
}
