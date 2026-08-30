import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("KeywordListsArchive")
struct KeywordListsArchiveTests {

    /// Runs `body` with the shared store pointed at a fresh, empty temp root.
    ///
    /// The store is a process-wide singleton that several suites write to, and
    /// Swift Testing runs suites in parallel — so without isolation another
    /// suite's quick-list writes leak into the shared root and inflate the
    /// archive's file count (the historical `exported → 5` flake). The override
    /// is task-local, so this isolation holds even while sibling suites write to
    /// the default root concurrently.
    private func withIsolatedStore(_ body: () throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-archive-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try KeywordListsStoreStorageOverride.$current.withValue(root) {
            try body()
        }
    }

    private func tempZip() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-archive-\(UUID().uuidString).zip")
    }

    @Test("Export then import round-trips all list types and preserves entry order")
    func roundTripAllTypes() throws {
        try withIsolatedStore {
            let store = KeywordListsStore.shared
            try store.writeEntries(["Berlin", "Paris", "London"], to: .quick(.keywords))
            try store.writeEntries(["Alice", "Bob"], to: .quick(.personShown))
            try store.writeEntries(["Approved-A", "Approved-B"], to: .approved(.keywords))
            try store.writeText("animals\n\tlivestock\n", to: .structured)

            let zipURL = tempZip()
            defer { try? FileManager.default.removeItem(at: zipURL) }
            let exported = try KeywordListsArchive.exportAll(to: zipURL)
            #expect(exported == 4)

            // Wipe the store and re-import.
            for type in QuickListType.allCases { store.delete(.quick(type)) }
            for field in ApprovedListField.allCases { store.delete(.approved(field)) }
            store.delete(.structured)
            #expect(store.readEntries(.quick(.keywords)) == [])

            let imported = try KeywordListsArchive.importAll(from: zipURL, mode: .replace)
            #expect(imported == 4)

            #expect(store.readEntries(.quick(.keywords)) == ["Berlin", "Paris", "London"])
            #expect(store.readEntries(.quick(.personShown)) == ["Alice", "Bob"])
            #expect(store.readEntries(.approved(.keywords)) == ["Approved-A", "Approved-B"])
            #expect(store.readText(.structured)?.contains("animals") == true)
        }
    }

    @Test("Import in .merge mode appends new entries without disturbing existing order")
    func mergeMode() throws {
        try withIsolatedStore {
            let store = KeywordListsStore.shared
            try store.writeEntries(["Existing-1", "Existing-2"], to: .quick(.copyright))

            // Build an archive that has a different copyright list.
            try store.writeEntries(["New-1", "Existing-1", "New-2"], to: .quick(.copyright))
            let zipURL = tempZip()
            defer { try? FileManager.default.removeItem(at: zipURL) }
            try KeywordListsArchive.exportAll(to: zipURL)

            // Restore the original store state, then merge-import.
            try store.writeEntries(["Existing-1", "Existing-2"], to: .quick(.copyright))
            try KeywordListsArchive.importAll(from: zipURL, mode: .merge)

            let merged = store.readEntries(.quick(.copyright))
            // Existing order preserved at the front, new entries appended.
            #expect(merged == ["Existing-1", "Existing-2", "New-1", "New-2"])
        }
    }

    @Test("Import rejects manifest entries that escape the payload root (path traversal)")
    func rejectsPathTraversal() throws {
        try withIsolatedStore {
            let store = KeywordListsStore.shared

            // Plant a secret OUTSIDE the archive payload. The importer unzips into
            // a `klists-import-*` dir directly under the system temp dir, so the
            // payload root sits two levels below temp — `../../` from there lands
            // back in the temp dir where this secret lives.
            let secretName = "kl-traversal-secret-\(UUID().uuidString).txt"
            let secretURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(secretName)
            try "TOP-SECRET-LEAK\n".write(to: secretURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: secretURL) }

            // Build an archive whose manifest points a valid list `kind` at the
            // secret via `..` traversal.
            let stagingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("kl-evil-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stagingRoot) }

            let manifest = KeywordListsArchive.Manifest(
                schemaVersion: KeywordListsArchive.currentSchemaVersion,
                exportedAt: Date(),
                files: [
                    .init(path: "../../\(secretName)", kind: "quick.keywords", entryCount: 1)
                ]
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest)
                .write(to: stagingRoot.appendingPathComponent("manifest.json"))

            let zipURL = tempZip()
            defer { try? FileManager.default.removeItem(at: zipURL) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--keepParent", stagingRoot.path, zipURL.path]
            try p.run()
            p.waitUntilExit()

            // The malicious entry must be skipped: nothing imported, secret never read.
            let imported = try KeywordListsArchive.importAll(from: zipURL, mode: .replace)
            #expect(imported == 0)
            #expect(store.readEntries(.quick(.keywords)) == [])
        }
    }

    @Test("Importing a zip without a manifest throws an actionable error")
    func missingManifestThrows() throws {
        // Build a zip that has the right shape but no manifest.json.
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-bogus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        try "abc\n".write(
            to: stagingRoot.appendingPathComponent("random.txt"),
            atomically: true,
            encoding: .utf8
        )
        let zipURL = tempZip()
        defer { try? FileManager.default.removeItem(at: zipURL) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", stagingRoot.path, zipURL.path]
        try p.run()
        p.waitUntilExit()

        #expect(throws: KeywordListsArchive.ArchiveError.self) {
            try KeywordListsArchive.importAll(from: zipURL, mode: .replace)
        }
    }
}

@Suite("Keyword-list archive export filesystem boundary")
struct KeywordListsArchiveExportServiceTests {
    @Test("a complete immutable export commit is performed away from the main actor")
    @MainActor
    func completeExportRunsOffMainActor() async throws {
        let request = sampleRequest(destination: URL(fileURLWithPath: "/virtual/lists.zip"))
        let commit = sampleCommit(for: request)
        let probe = KeywordListsArchiveExporterProbe(result: .exported(commit))
        let service = KeywordListsArchiveExportService(
            exporter: KeywordListsArchiveExporter(perform: probe.perform)
        )

        let result = try await Task { try await service.export(request) }.value

        #expect(result == .exported(commit))
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("a pre-cancelled export never enters archive staging")
    func preCancellation() async throws {
        let request = sampleRequest(destination: URL(fileURLWithPath: "/virtual/cancelled.zip"))
        let probe = KeywordListsArchiveExporterProbe(result: .exported(sampleCommit(for: request)))
        let service = KeywordListsArchiveExportService(
            exporter: KeywordListsArchiveExporter(perform: probe.perform)
        )
        let task = Task {
            await Task.yield()
            return try await service.export(request)
        }
        task.cancel()

        let result = try await task.value

        #expect(result == .cancelledBeforeCommit(
            requestID: request.requestID,
            destinationURL: request.destinationURL,
            preparedFileCount: 0
        ))
        #expect(probe.invocationCount == 0)
    }

    @Test("cancellation during non-preemptible export preserves durable commit evidence")
    func cancellationAfterCommit() async throws {
        let request = sampleRequest(destination: URL(fileURLWithPath: "/virtual/slow.zip"))
        let commit = sampleCommit(for: request)
        let service = KeywordListsArchiveExportService(
            exporter: KeywordListsArchiveExporter { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .exported(commit)
            }
        )

        let result = try await Task { try await service.export(request) }.value

        #expect(result == .exported(KeywordListsArchiveExportCommit(
            requestID: request.requestID,
            destinationURL: request.destinationURL,
            exportedFileCount: 1,
            cancellationObservedAfterCommit: true
        )))
    }

    @Test("a staging failure preserves the previous destination bytes")
    func failedStagingPreservesDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-export-atomic-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent("Keywords.zip")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("existing archive".utf8)
        try original.write(to: destination)
        let request = KeywordListsArchiveExportRequest(
            requestID: UUID(),
            destinationURL: destination,
            items: [KeywordListsArchiveExportItem(
                sourceURL: directory.appendingPathComponent("missing.txt"),
                relativePath: "quick/keywords.txt",
                kind: "quick.keywords",
                entryCount: 1
            )]
        )

        #expect(throws: (any Error).self) {
            try KeywordListsArchive.performExport(request)
        }
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test("the export sheet awaits the actor and rejects stale publication")
    func exportSheetSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/KeywordListsImportExportSheets.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func runExport()"))
        let suffix = source[functionStart.lowerBound...]
        let functionEnd = try #require(suffix.range(of: "\n    private func countKeywords"))
        let functionSource = String(suffix[..<functionEnd.lowerBound])

        #expect(functionSource.contains(
            "try await KeywordListsArchiveExportService.shared.export(request)"
        ))
        #expect(functionSource.contains("guard exportRequestID == requestID else { return }"))
        #expect(!functionSource.contains("KeywordListsArchive.exportSelected("))
        #expect(source.contains("exportRequestID = nil\n            exportTask?.cancel()"))
    }

    private func sampleRequest(destination: URL) -> KeywordListsArchiveExportRequest {
        KeywordListsArchiveExportRequest(
            requestID: UUID(),
            destinationURL: destination,
            items: [KeywordListsArchiveExportItem(
                sourceURL: URL(fileURLWithPath: "/virtual/store/quick/keywords.txt"),
                relativePath: "quick/keywords.txt",
                kind: "quick.keywords",
                entryCount: 3
            )]
        )
    }

    private func sampleCommit(
        for request: KeywordListsArchiveExportRequest
    ) -> KeywordListsArchiveExportCommit {
        KeywordListsArchiveExportCommit(
            requestID: request.requestID,
            destinationURL: request.destinationURL,
            exportedFileCount: request.items.count,
            cancellationObservedAfterCommit: false
        )
    }
}

@Suite("Keyword-list archive preview filesystem boundary")
struct KeywordListsArchivePreviewServiceTests {
    @Test("a complete immutable archive preview is inspected away from the main actor")
    @MainActor
    func completePreviewRunsOffMainActor() async throws {
        let source = URL(fileURLWithPath: "/virtual/lists.zip")
        let requestID = UUID()
        let payload = samplePayload(kind: "quick.keywords", count: 3)
        let probe = KeywordListsArchivePreviewReaderProbe(payload: payload)
        let service = KeywordListsArchivePreviewService(
            reader: KeywordListsArchivePreviewReader(inspect: probe.inspect)
        )

        let result = try await Task {
            try await service.loadPreview(from: source, requestID: requestID)
        }.value

        #expect(result == .loaded(KeywordListsArchivePreviewSnapshot(
            requestID: requestID,
            sourceURL: source,
            payload: payload
        )))
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("a pre-cancelled preview never starts archive inspection")
    func preCancellation() async throws {
        let requestID = UUID()
        let probe = KeywordListsArchivePreviewReaderProbe(payload: samplePayload())
        let service = KeywordListsArchivePreviewService(
            reader: KeywordListsArchivePreviewReader(inspect: probe.inspect)
        )
        let task = Task {
            await Task.yield()
            return try await service.loadPreview(
                from: URL(fileURLWithPath: "/virtual/cancelled.zip"),
                requestID: requestID
            )
        }
        task.cancel()

        let result = try await task.value

        #expect(result == .cancelledBeforeInspection(requestID: requestID))
        #expect(probe.invocationCount == 0)
    }

    @Test("overlapping previews serialize and cancellation stops a queued inspection")
    func serializedQueuedCancellation() async throws {
        let firstSource = URL(fileURLWithPath: "/virtual/first.zip")
        let secondSource = URL(fileURLWithPath: "/virtual/second.zip")
        let firstID = UUID()
        let secondID = UUID()
        let payload = samplePayload(kind: "structured", count: 8)
        let probe = BlockingKeywordListsArchivePreviewReaderProbe(payload: payload)
        let service = KeywordListsArchivePreviewService(
            reader: KeywordListsArchivePreviewReader(inspect: probe.inspect)
        )
        let first = Task {
            try await service.loadPreview(from: firstSource, requestID: firstID)
        }
        try await probe.waitUntilFirstInspectionStarts()
        let second = Task {
            try await service.loadPreview(from: secondSource, requestID: secondID)
        }
        second.cancel()
        probe.releaseFirstInspection()

        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(firstResult == .loaded(KeywordListsArchivePreviewSnapshot(
            requestID: firstID,
            sourceURL: firstSource,
            payload: payload
        )))
        #expect(secondResult == .cancelledBeforeInspection(requestID: secondID))
        #expect(probe.invocationCount == 1)
        #expect(probe.maximumConcurrentInspections == 1)
    }

    @Test("cancellation during non-preemptible inspection returns only cancellation evidence")
    func cancellationAfterInspection() async throws {
        let source = URL(fileURLWithPath: "/virtual/slow.zip")
        let requestID = UUID()
        let payload = samplePayload(kind: "approved.keywords", count: 5)
        let service = KeywordListsArchivePreviewService(
            reader: KeywordListsArchivePreviewReader { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return payload
            }
        )

        let result = try await Task {
            try await service.loadPreview(from: source, requestID: requestID)
        }.value

        #expect(result == .cancelledAfterInspection(
            requestID: requestID,
            sourceURL: source,
            discoveredEntryCount: 1
        ))
    }

    @Test("the import sheet awaits inspection and rejects stale preview publication")
    func importSheetSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/KeywordListsImportExportSheets.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func loadPreview()"))
        let suffix = source[functionStart.lowerBound...]
        let functionEnd = try #require(suffix.range(of: "\n    private func cancelPreview()"))
        let functionSource = String(suffix[..<functionEnd.lowerBound])

        #expect(functionSource.contains(
            "try await KeywordListsArchivePreviewService.shared.loadPreview("
        ))
        #expect(functionSource.contains("guard previewRequestID == requestID else { return }"))
        #expect(functionSource.contains(
            "case .cancelledBeforeInspection, .cancelledAfterInspection:"
        ))
        #expect(!functionSource.contains("KeywordListsArchive.inspect(source)"))
        #expect(source.contains(
            ".onDisappear {\n            cancelPreview()\n            cancelImport()\n        }"
        ))
    }

    private func samplePayload(
        kind: String = "quick.city",
        count: Int = 2
    ) -> KeywordListsArchivePreviewPayload {
        KeywordListsArchivePreviewPayload(
            entries: [KeywordListsArchivePreviewPayload.Entry(
                path: "quick/city.txt",
                kind: kind,
                entryCount: count
            )],
            schemaVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 100)
        )
    }
}

@Suite("Keyword-list archive import commit filesystem boundary")
struct KeywordListsArchiveImportServiceTests {
    @Test("system importer preserves replace and append behavior")
    @MainActor
    func systemImporterRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-async-import-store-\(UUID().uuidString)", isDirectory: true)
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-async-import-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: zipURL)
        }

        try await KeywordListsStoreStorageOverride.$current.withValue(root) {
            let store = KeywordListsStore.shared
            try store.writeEntries(["Local", "Shared"], to: .quick(.keywords))
            try store.writeEntries(["Imported", "shared"], to: .quick(.keywords))
            try KeywordListsArchive.exportSelected([.quick(.keywords)], to: zipURL)
            try store.writeEntries(["Local", "Shared"], to: .quick(.keywords))

            let requestID = UUID()
            let request = KeywordListsArchive.importRequest(
                from: zipURL,
                choices: [.quick(.keywords): .append],
                requestID: requestID
            )
            let result = await KeywordListsArchiveImportService().importArchive(request)

            #expect(result.durableCommit?.requestID == requestID)
            #expect(result.durableCommit?.items.count == 1)
            #expect(store.readEntries(.quick(.keywords)) == ["Local", "Shared", "Imported"])
        }
    }

    @Test("a complete immutable commit is performed away from the main actor")
    @MainActor
    func completeImportRunsOffMainActor() async {
        let request = sampleRequest(source: URL(fileURLWithPath: "/virtual/lists.zip"))
        let commit = sampleCommit(for: request)
        let probe = KeywordListsArchiveImporterProbe(result: .committed(commit))
        let service = KeywordListsArchiveImportService(
            importer: KeywordListsArchiveImporter(perform: probe.perform)
        )

        let result = await Task { await service.importArchive(request) }.value

        #expect(result == .committed(commit))
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("a pre-cancelled import never enters the synchronous importer")
    func preCancellation() async {
        let request = sampleRequest(source: URL(fileURLWithPath: "/virtual/cancelled.zip"))
        let probe = KeywordListsArchiveImporterProbe(result: .committed(sampleCommit(for: request)))
        let service = KeywordListsArchiveImportService(
            importer: KeywordListsArchiveImporter(perform: probe.perform)
        )
        let task = Task {
            await Task.yield()
            return await service.importArchive(request)
        }
        task.cancel()

        let result = await task.value

        #expect(result == .cancelledBeforeAccess(requestID: request.requestID))
        #expect(probe.invocationCount == 0)
    }

    @Test("overlapping imports serialize and cancellation stops queued commit work")
    func serializedQueuedCancellation() async throws {
        let firstRequest = sampleRequest(source: URL(fileURLWithPath: "/virtual/first.zip"))
        let secondRequest = sampleRequest(source: URL(fileURLWithPath: "/virtual/second.zip"))
        let probe = BlockingKeywordListsArchiveImporterProbe()
        let service = KeywordListsArchiveImportService(
            importer: KeywordListsArchiveImporter(perform: probe.perform)
        )
        let first = Task { await service.importArchive(firstRequest) }
        try await probe.waitUntilFirstImportStarts()
        let second = Task { await service.importArchive(secondRequest) }
        second.cancel()
        probe.releaseFirstImport()

        let firstResult = await first.value
        let secondResult = await second.value

        #expect(firstResult == .committed(sampleCommit(for: firstRequest)))
        #expect(secondResult == .cancelledBeforeAccess(requestID: secondRequest.requestID))
        #expect(probe.invocationCount == 1)
        #expect(probe.maximumConcurrentImports == 1)
    }

    @Test("cancellation during a non-preemptible import preserves durable commit evidence")
    func cancellationAfterCommit() async {
        let request = sampleRequest(source: URL(fileURLWithPath: "/virtual/slow.zip"))
        let commit = sampleCommit(for: request)
        let service = KeywordListsArchiveImportService(
            importer: KeywordListsArchiveImporter { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .committed(commit)
            }
        )

        let result = await Task { await service.importArchive(request) }.value

        #expect(result == .cancelledAfterCommit(commit))
        #expect(result.durableCommit == commit)
    }

    @Test("partial failure retains every earlier durable destination")
    func partialCommitEvidence() async {
        let request = sampleRequest(source: URL(fileURLWithPath: "/virtual/partial.zip"))
        let commit = sampleCommit(for: request)
        let failure = KeywordListsArchiveImportFailure(
            identifier: "approved/keywords.txt",
            reason: "simulated destination failure"
        )
        let service = KeywordListsArchiveImportService(
            importer: KeywordListsArchiveImporter { _ in
                .partiallyCommitted(commit, failure: failure)
            }
        )

        let result = await service.importArchive(request)

        #expect(result == .partiallyCommitted(commit, failure: failure))
        #expect(result.durableCommit?.items == commit.items)
    }

    @Test("the import sheet awaits commits and rejects stale UI publication")
    func importSheetSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/KeywordListsImportExportSheets.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func runImport()"))
        let suffix = source[functionStart.lowerBound...]
        let functionEnd = try #require(suffix.range(of: "\n    private func cancelImport()"))
        let functionSource = String(suffix[..<functionEnd.lowerBound])
        let publishRange = try #require(functionSource.range(of: "publish(commit"))
        let staleGuardRange = try #require(functionSource.range(of: "guard importRequestID == requestID"))

        #expect(functionSource.contains(
            "await KeywordListsArchiveImportService.shared.importArchive(request)"
        ))
        #expect(publishRange.lowerBound < staleGuardRange.lowerBound)
        #expect(functionSource.contains("case .partiallyCommitted(let commit, let failure):"))
        #expect(functionSource.contains("case .cancelledAfterCommit(let commit):"))
        #expect(!functionSource.contains("KeywordListsArchive.importSelected("))
        #expect(source.contains("cancelPreview()\n            cancelImport()"))
    }

    private func sampleRequest(source: URL) -> KeywordListsArchiveImportRequest {
        KeywordListsArchiveImportRequest(
            requestID: UUID(),
            sourceURL: source,
            routes: [KeywordListsArchiveImportRoute(
                identifier: "quick/keywords.txt",
                kind: "quick.keywords",
                destinationURL: URL(fileURLWithPath: "/virtual/store/quick/keywords.txt"),
                mode: .replace
            )]
        )
    }

    private func sampleCommit(
        for request: KeywordListsArchiveImportRequest
    ) -> KeywordListsArchiveImportCommit {
        KeywordListsArchiveImportCommit(
            requestID: request.requestID,
            sourceURL: request.sourceURL,
            items: [KeywordListsArchiveImportCommit.Item(
                identifier: request.routes[0].identifier,
                destinationURL: request.routes[0].destinationURL,
                entryCount: 3
            )]
        )
    }
}

private nonisolated final class KeywordListsArchiveExporterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let result: KeywordListsArchiveExportResult
    private var count = 0
    private var observedMainThread = false

    init(result: KeywordListsArchiveExportResult) {
        self.result = result
    }

    func perform(
        _ request: KeywordListsArchiveExportRequest
    ) throws -> KeywordListsArchiveExportResult {
        _ = request
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return result
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

private nonisolated final class KeywordListsArchivePreviewReaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let payload: KeywordListsArchivePreviewPayload
    private var count = 0
    private var observedMainThread = false

    init(payload: KeywordListsArchivePreviewPayload) {
        self.payload = payload
    }

    func inspect(_ sourceURL: URL) throws -> KeywordListsArchivePreviewPayload {
        _ = sourceURL
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return payload
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

private nonisolated final class KeywordListsArchiveImporterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let result: KeywordListsArchiveImportResult
    private var count = 0
    private var observedMainThread = false

    init(result: KeywordListsArchiveImportResult) {
        self.result = result
    }

    func perform(_ request: KeywordListsArchiveImportRequest) -> KeywordListsArchiveImportResult {
        _ = request
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return result
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

private nonisolated final class BlockingKeywordListsArchiveImporterProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var importCount = 0
    private var activeImports = 0
    private var maximumActiveImports = 0
    private var firstImportReleased = false

    func perform(_ request: KeywordListsArchiveImportRequest) -> KeywordListsArchiveImportResult {
        condition.lock()
        importCount += 1
        activeImports += 1
        maximumActiveImports = max(maximumActiveImports, activeImports)
        condition.broadcast()
        if importCount == 1 {
            while !firstImportReleased {
                condition.wait()
            }
        }
        activeImports -= 1
        condition.unlock()
        return .committed(KeywordListsArchiveImportCommit(
            requestID: request.requestID,
            sourceURL: request.sourceURL,
            items: [KeywordListsArchiveImportCommit.Item(
                identifier: request.routes[0].identifier,
                destinationURL: request.routes[0].destinationURL,
                entryCount: 3
            )]
        ))
    }

    func waitUntilFirstImportStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while invocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw KeywordListsArchivePreviewProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstImport() {
        condition.lock()
        firstImportReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var invocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return importCount
    }

    var maximumConcurrentImports: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveImports
    }
}

private enum KeywordListsArchivePreviewProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingKeywordListsArchivePreviewReaderProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let payload: KeywordListsArchivePreviewPayload
    private var inspectionCount = 0
    private var activeInspections = 0
    private var maximumActiveInspections = 0
    private var firstInspectionReleased = false

    init(payload: KeywordListsArchivePreviewPayload) {
        self.payload = payload
    }

    func inspect(_ sourceURL: URL) throws -> KeywordListsArchivePreviewPayload {
        _ = sourceURL
        condition.lock()
        inspectionCount += 1
        activeInspections += 1
        maximumActiveInspections = max(maximumActiveInspections, activeInspections)
        condition.broadcast()
        if inspectionCount == 1 {
            while !firstInspectionReleased {
                condition.wait()
            }
        }
        activeInspections -= 1
        condition.unlock()
        return payload
    }

    func waitUntilFirstInspectionStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while invocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw KeywordListsArchivePreviewProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstInspection() {
        condition.lock()
        firstInspectionReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var invocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return inspectionCount
    }

    var maximumConcurrentInspections: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveInspections
    }
}
