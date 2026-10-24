import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Keyword-list editor filesystem boundary")
struct KeywordListEditorPersistenceServiceTests {
    @Test("Approved import refuses a reserved destination before source access")
    func approvedImportContention() async throws {
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("approved-import-busy-\(UUID())/keywords.txt")
        let lease = try MCPKeywordListReservation.acquire(for: [list])
        defer { lease.release() }
        let service = ApprovedListImportService(access: ApprovedListImportFileAccess(
            startAccessing: { _ in Issue.record("Reserved import opened source"); return false },
            stopAccessing: { _ in }, fileSize: { _ in Issue.record("Reserved import inspected source"); return 0 },
            readData: { _ in Issue.record("Reserved import read source"); return Data() },
            writeData: { _, _ in Issue.record("Reserved import wrote destination") }
        ))
        await #expect(throws: MCPProcessReservationError.busy) {
            try await service.importEntries(from: list.appendingPathExtension("csv"), to: list, requestID: UUID())
        }
    }
    @Test("A managed-list reservation refuses all editor mutations before filesystem access")
    func cooperatingWriterContention() async throws {
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("keyword-contention-\(UUID())/approved/keywords.txt")
        let lease = try MCPKeywordListReservation.acquire(for: [list])
        defer { lease.release() }
        let service = KeywordListEditorPersistenceService(access: KeywordListEditorFileAccess(
            itemExists: { _ in Issue.record("Busy mutation probed the destination"); return true },
            readData: { _ in Issue.record("Busy mutation read the destination"); return Data() },
            writeData: { _, _ in Issue.record("Busy mutation wrote the destination") },
            removeItem: { _ in Issue.record("Busy mutation removed the destination") }
        ))
        await #expect(throws: MCPProcessReservationError.busy) {
            try await service.saveEntries(["Oslo"], to: list, requestID: UUID())
        }
        await #expect(throws: MCPProcessReservationError.busy) {
            try await service.saveText("Oslo", to: list, requestID: UUID())
        }
        await #expect(throws: MCPProcessReservationError.busy) {
            try await service.appendEntries(["Oslo"], to: list, requestID: UUID())
        }
        await #expect(throws: MCPProcessReservationError.busy) {
            try await service.deleteQuickList(at: list, requestID: UUID())
        }
    }

    @Test("Append holds its list reservation through read, merge, and durable write")
    func appendRetainsReservation() async throws {
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("keyword-held-\(UUID())/keywords.txt")
        let service = KeywordListEditorPersistenceService(access: KeywordListEditorFileAccess(
            itemExists: { _ in
                #expect(throws: MCPProcessReservationError.busy) { try MCPKeywordListReservation.acquire(for: [list]) }
                return true
            },
            readData: { _ in
                #expect(throws: MCPProcessReservationError.busy) { try MCPKeywordListReservation.acquire(for: [list]) }
                return Data("Oslo\n".utf8)
            },
            writeData: { data, _ in
                #expect(throws: MCPProcessReservationError.busy) { try MCPKeywordListReservation.acquire(for: [list]) }
                #expect(data == Data("Oslo\nParis\n".utf8))
            }
        ))
        let result = try await service.appendEntries(["Paris"], to: list, requestID: UUID())
        guard case .committed = result else { Issue.record("Append did not commit"); return }
        let next = try MCPKeywordListReservation.acquire(for: [list]); next.release()
    }

    @Test("Destination symlink drift during append refuses replacement bytes")
    func appendDestinationDrift() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyword-drift-\(UUID())")
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let route = root.appendingPathComponent("route")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: route, withDestinationURL: first)
        let list = route.appendingPathComponent("keywords.txt")
        let service = KeywordListEditorPersistenceService(access: KeywordListEditorFileAccess(
            itemExists: { _ in true }, readData: { _ in
                try FileManager.default.removeItem(at: route)
                try FileManager.default.createSymbolicLink(at: route, withDestinationURL: second)
                return Data("Oslo\n".utf8)
            }, writeData: { _, _ in Issue.record("Drifted destination was written") }
        ))
        await #expect(throws: MCPProcessReservationError.unavailable) {
            try await service.appendEntries(["Paris"], to: list, requestID: UUID())
        }
    }

    @Test("managed reads and commits use the Dispatch worker with the caller's task context")
    @MainActor
    func managedTransactionUsesDispatchWorker() async throws {
        let root = URL(fileURLWithPath: "/virtual/keyword-worker")
        let destination = root.appendingPathComponent("keywords.txt")
        let requestID = UUID()
        let queue = KeywordListsFilesystemActor.shared.filesystemQueue
        let service = KeywordListEditorPersistenceService(access: KeywordListEditorFileAccess(
            itemExists: { _ in
                #expect(queue.isIsolatingCurrentContext() == true)
                #expect(KeywordListsStoreStorageOverride.current == root)
                return true
            },
            readData: { _ in
                #expect(queue.isIsolatingCurrentContext() == true)
                #expect(KeywordListsStoreStorageOverride.current == root)
                return Data("first\n".utf8)
            },
            writeData: { bytes, url in
                #expect(queue.isIsolatingCurrentContext() == true)
                #expect(KeywordListsStoreStorageOverride.current == root)
                #expect(bytes == Data("first\nsecond\n".utf8))
                #expect(url == destination)
                // The executor must run the actual caller task, so cancellation in a blocking
                // writer is still visible when the service reports the durable commit.
                withUnsafeCurrentTask { $0?.cancel() }
            }
        ))
        let result = try await Task {
            try await KeywordListsStoreStorageOverride.$current.withValue(root) {
                try await service.appendEntries(["second"], to: destination, requestID: requestID)
            }
        }.value
        #expect(result == .committed(QuickListMutationCommit(
            requestID: requestID, destinationURL: destination,
            entries: ["first", "second"], addedEntries: ["second"],
            byteCount: Data("first\nsecond\n".utf8).count,
            cancellationRequestedAfterCommit: true
        )))
    }

    @Test("routing, approved import, and backup restore wait for an editor transaction")
    func sharedFilesystemTransactions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("list.txt")
        let backup = root.appendingPathComponent("restore.txt")
        let preimage = root.appendingPathComponent("previous.txt")
        try Data("first\n".utf8).write(to: destination)
        try Data("restored\n".utf8).write(to: backup)

        let gate = BlockingKeywordListEditorFileAccessProbe()
        let editor = KeywordListEditorPersistenceService(access: KeywordListEditorFileAccess(
            itemExists: { _ in true },
            readData: gate.fileAccess.readData,
            writeData: { try $0.write(to: $1) }
        ))
        let editorTask = Task {
            try await editor.appendEntries(["added"], to: destination, requestID: UUID())
        }
        defer { gate.releaseFirstRead() }
        try await gate.waitUntilFirstReadStarts()

        let probe = KeywordFilesystemTransactionProbe()
        let routing = KeywordListsRoutingService(access: KeywordListsRoutingFileAccess(
            localRootURL: { root }, cloudRootURL: { root.appendingPathComponent("cloud") },
            merge: { _, _ in probe.recordRouting() }
        ))
        let system = KeywordListBackupFileIO.system
        let restore = KeywordListBackupFileService(io: KeywordListBackupFileIO(
            contentsOfDirectory: system.contentsOfDirectory,
            inspectTextFile: system.inspectTextFile,
            createDirectory: system.createDirectory,
            readData: { url in probe.recordBackupRead(); return try Data(contentsOf: url) },
            writeData: { try $0.write(to: $1) }, removeItem: system.removeItem
        ))
        let approvedDestination = root.appendingPathComponent("approved.txt")
        let approvedImport = ApprovedListImportService(access: ApprovedListImportFileAccess(
            startAccessing: { _ in probe.recordApprovedAccess(); return false },
            stopAccessing: { _ in }, fileSize: { _ in 9 },
            readData: { try Data(contentsOf: $0) },
            writeData: { try $0.write(to: $1) }
        ))
        let approvedTask = Task {
            try await approvedImport.importEntries(from: backup, to: approvedDestination, requestID: UUID())
        }
        let routingTask = Task { try await routing.reconcile(enabled: true, requestID: UUID()) }
        let restoreTask = Task {
            try await restore.restore(from: backup, to: destination, requestID: UUID(),
                                      previousContentBackupURL: preimage)
        }
        // Give the independent service requests time to attempt entry while the editor is
        // suspended inside its synchronous read. None may enter the filesystem transaction.
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.routingCount == 0)
        #expect(probe.backupReadCount == 0)
        #expect(probe.approvedAccessCount == 0)
        gate.releaseFirstRead()
        guard case .committed(let edit) = try await editorTask.value else {
            Issue.record("Editor append did not commit")
            return
        }
        _ = try await routingTask.value
        guard case .restored = try await restoreTask.value else {
            Issue.record("Backup restore did not commit")
            return
        }
        guard case .committed(let approved) = try await approvedTask.value else {
            Issue.record("Approved import did not commit")
            return
        }
        #expect(approved.entries == ["restored"])
        #expect(try String(contentsOf: approvedDestination, encoding: .utf8) == "restored\n")
        #expect(probe.approvedAccessCount == 1)
        #expect(edit.entries == ["first", "added"])
        #expect(try String(contentsOf: preimage, encoding: .utf8) == "first\nadded\n")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "restored\n")
        #expect(probe.routingCount == 1)
        #expect(probe.backupReadCount == 2)
    }

    @Test("load returns a complete normalized snapshot away from MainActor")
    @MainActor
    func loadRunsOffMainActor() async throws {
        let source = URL(fileURLWithPath: "/virtual/quick-list.txt")
        let bytes = Data(" Berlin \n# ignored\nParis\nBerlin\n\n".utf8)
        let probe = KeywordListEditorFileAccessProbe(readData: bytes)
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.loadEntries(from: source, requestID: requestID)

        #expect(result == .loaded(KeywordListEditorLoadSnapshot(
            requestID: requestID,
            sourceURL: source,
            entries: ["Berlin", "Paris"],
            byteCount: bytes.count
        )))
        #expect(probe.existsInvocationCount == 1)
        #expect(probe.readInvocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("invalid managed UTF-8 is rejected without replacing source bytes")
    func invalidManagedTextPreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("keywords.txt")
        let bytes = Data([0x4E, 0x65, 0x77, 0x73, 0x0A, 0xC3, 0x28])
        try bytes.write(to: source)
        let service = KeywordListEditorPersistenceService()

        await #expect(throws: CocoaError.self) {
            try await service.loadEntries(from: source, requestID: UUID())
        }
        await #expect(throws: CocoaError.self) {
            try await service.loadText(from: source, requestID: UUID())
        }
        await #expect(throws: CocoaError.self) {
            try await service.appendEntries(["Sport"], to: source, requestID: UUID())
        }
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test("cache reports invalid text as failed while preserving valid sibling entries")
    func invalidManagedCacheText() async throws {
        let invalid = URL(fileURLWithPath: "/virtual/keywords.txt")
        let valid = URL(fileURLWithPath: "/virtual/city.txt")
        let sources = [QuickListCacheSource(type: .keywords, url: invalid),
                       QuickListCacheSource(type: .city, url: valid)]
        let service = KeywordListEditorPersistenceService(access: KeywordListEditorFileAccess(
            itemExists: { _ in true },
            readData: { $0 == invalid ? Data([0xC3, 0x28]) : Data("Tromsø\n".utf8) },
            writeData: { _, _ in Issue.record("Cache reads must not write") }
        ))
        let requestID = UUID()
        let result = await service.loadQuickListCache(from: sources, requestID: requestID)
        #expect(result == .complete(QuickListCacheSnapshot(
            requestID: requestID,
            requestedSources: sources,
            processedSources: sources,
            entriesByType: [.city: ["Tromsø"]],
            availableTypes: [.keywords, .city],
            failedTypes: [.keywords]
        )))
    }

    @Test("cancellation during a cache probe prevents its read and preserves the completed prefix")
    func cacheCancellationDuringExistenceProbe() async {
        let first = QuickListCacheSource(type: .keywords, url: URL(fileURLWithPath: "/virtual/keywords.txt"))
        let second = QuickListCacheSource(type: .city, url: URL(fileURLWithPath: "/virtual/city.txt"))
        let service = KeywordListEditorPersistenceService(access: KeywordListEditorFileAccess(
            itemExists: { url in
                if url == second.url { withUnsafeCurrentTask { $0?.cancel() } }
                return true
            },
            readData: { url in
                #expect(url == first.url)
                return Data("News\n".utf8)
            },
            writeData: { _, _ in Issue.record("Cache reads must not write") }
        ))
        let requestID = UUID()
        let result = await Task {
            await service.loadQuickListCache(from: [first, second], requestID: requestID)
        }.value
        #expect(result == .cancelledAfterPartialAccess(QuickListCacheSnapshot(
            requestID: requestID,
            requestedSources: [first, second],
            processedSources: [first],
            entriesByType: [.keywords: ["News"]],
            availableTypes: [.keywords],
            failedTypes: []
        )))
    }

    @Test("cancelled missing probes cannot authorize first-use creation or publish missing state")
    func cancellationDuringMissingProbe() async throws {
        let source = URL(fileURLWithPath: "/virtual/missing.txt")
        let service = KeywordListEditorPersistenceService(access: KeywordListEditorFileAccess(
            itemExists: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            },
            readData: { _ in Issue.record("Cancelled probes must not read"); return Data() },
            writeData: { _, _ in Issue.record("Cancelled probes must not write") },
            removeItem: { _ in Issue.record("Cancelled probes must not remove") }
        ))
        let requestID = UUID()
        let load = try await Task { try await service.loadEntries(from: source, requestID: requestID) }.value
        #expect(load == .cancelledBeforeRead(requestID: requestID, sourceURL: source))
        let append = try await Task {
            try await service.appendEntries(["News"], to: source, requestID: requestID)
        }.value
        #expect(append == .cancelledAfterRead(requestID: requestID, destinationURL: source, byteCount: 0))
        let deletion = try await Task { try await service.deleteQuickList(at: source, requestID: requestID) }.value
        #expect(deletion == .cancelledBeforeCommit(requestID: requestID, destinationURL: source))
    }

    @Test("missing file returns immutable evidence without entering the reader")
    func missingFile() async throws {
        let source = URL(fileURLWithPath: "/virtual/missing.txt")
        let probe = KeywordListEditorFileAccessProbe(itemExists: false)
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.loadEntries(from: source, requestID: requestID)

        #expect(result == .missing(requestID: requestID, sourceURL: source))
        #expect(probe.existsInvocationCount == 1)
        #expect(probe.readInvocationCount == 0)
    }

    @Test("a pre-cancelled load performs no filesystem access")
    func preCancelledLoad() async throws {
        let probe = KeywordListEditorFileAccessProbe()
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()
        let task = Task {
            await Task.yield()
            return try await service.loadEntries(
                from: URL(fileURLWithPath: "/virtual/cancelled.txt"),
                requestID: requestID
            )
        }
        task.cancel()

        let result = try await task.value

        #expect(result == .cancelledBeforeAccess(requestID: requestID))
        #expect(probe.existsInvocationCount == 0)
        #expect(probe.readInvocationCount == 0)
    }

    @Test("queued editor operations serialize and cancellation prevents the queued read")
    func serializationAndQueuedCancellation() async throws {
        let firstURL = URL(fileURLWithPath: "/virtual/first.txt")
        let secondURL = URL(fileURLWithPath: "/virtual/second.txt")
        let firstID = UUID()
        let secondID = UUID()
        let probe = BlockingKeywordListEditorFileAccessProbe()
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)

        let first = Task { try await service.loadEntries(from: firstURL, requestID: firstID) }
        try await probe.waitUntilFirstReadStarts()
        let second = Task { try await service.loadEntries(from: secondURL, requestID: secondID) }
        second.cancel()
        probe.releaseFirstRead()

        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(firstResult == .loaded(KeywordListEditorLoadSnapshot(
            requestID: firstID,
            sourceURL: firstURL,
            entries: ["first"],
            byteCount: Data("first\n".utf8).count
        )))
        #expect(secondResult == .cancelledBeforeAccess(requestID: secondID))
        #expect(probe.readInvocationCount == 1)
        #expect(probe.maximumConcurrentReads == 1)
    }

    @Test("Quick List cache load returns one complete immutable snapshot off MainActor")
    @MainActor
    func quickListCacheLoadRunsOffMainActor() async {
        let sources = [
            QuickListCacheSource(
                type: .keywords,
                url: URL(fileURLWithPath: "/virtual/keywords.txt")
            ),
            QuickListCacheSource(
                type: .city,
                url: URL(fileURLWithPath: "/virtual/city.txt")
            )
        ]
        let bytes = Data("Oslo\nBergen\n".utf8)
        let probe = KeywordListEditorFileAccessProbe(readData: bytes)
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = await service.loadQuickListCache(from: sources, requestID: requestID)

        #expect(result == .complete(QuickListCacheSnapshot(
            requestID: requestID,
            requestedSources: sources,
            processedSources: sources,
            entriesByType: [
                .keywords: ["Oslo", "Bergen"],
                .city: ["Oslo", "Bergen"]
            ],
            availableTypes: [.keywords, .city],
            failedTypes: []
        )))
        #expect(probe.existsInvocationCount == 2)
        #expect(probe.readInvocationCount == 2)
        #expect(!probe.ranOnMainThread)
    }

    @Test("Quick List cache cancellation reports the exact processed prefix")
    func quickListCacheCancellationAfterRead() async throws {
        let sources = [
            QuickListCacheSource(
                type: .keywords,
                url: URL(fileURLWithPath: "/virtual/keywords.txt")
            ),
            QuickListCacheSource(
                type: .city,
                url: URL(fileURLWithPath: "/virtual/city.txt")
            )
        ]
        let probe = BlockingKeywordListEditorFileAccessProbe()
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()
        let task = Task {
            await service.loadQuickListCache(from: sources, requestID: requestID)
        }

        try await probe.waitUntilFirstReadStarts()
        task.cancel()
        probe.releaseFirstRead()
        let result = await task.value

        #expect(result == .cancelledAfterPartialAccess(QuickListCacheSnapshot(
            requestID: requestID,
            requestedSources: sources,
            processedSources: [sources[0]],
            entriesByType: [.keywords: ["first"]],
            availableTypes: [.keywords],
            failedTypes: []
        )))
        #expect(probe.readInvocationCount == 1)
    }

    @Test("save returns exact normalized durable-commit evidence")
    func saveCommitEvidence() async throws {
        let destination = URL(fileURLWithPath: "/virtual/event.txt")
        let probe = KeywordListEditorFileAccessProbe(cancelDuringWrite: true)
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await Task {
            try await service.saveEntries(
                [" Oslo ", "Bergen", "", "Oslo"],
                to: destination,
                requestID: requestID
            )
        }.value

        #expect(result == .committed(KeywordListEditorSaveCommit(
            requestID: requestID,
            destinationURL: destination,
            entries: ["Oslo", "Bergen"],
            byteCount: Data("Oslo\nBergen\n".utf8).count,
            cancellationRequestedAfterCommit: true
        )))
        #expect(probe.writtenData == Data("Oslo\nBergen\n".utf8))
        #expect(probe.writtenURL == destination)
    }

    @Test("structured text save preserves hierarchy and reports a durable off-main commit")
    @MainActor
    func structuredTextSaveCommitEvidence() async throws {
        let destination = URL(fileURLWithPath: "/virtual/structured.txt")
        let text = "[People]\n\tAlice\n"
        let probe = KeywordListEditorFileAccessProbe(cancelDuringWrite: true)
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await Task {
            try await service.saveText(
                text,
                to: destination,
                requestID: requestID
            )
        }.value

        #expect(result == .committed(KeywordListTextSaveCommit(
            requestID: requestID,
            destinationURL: destination,
            text: text,
            byteCount: Data(text.utf8).count,
            cancellationRequestedAfterCommit: true
        )))
        #expect(probe.writtenData == Data(text.utf8))
        #expect(probe.writtenURL == destination)
        #expect(!probe.ranOnMainThread)
    }

    @Test("append merges one serialized snapshot away from MainActor")
    @MainActor
    func appendRunsOffMainActor() async throws {
        let destination = URL(fileURLWithPath: "/virtual/city.txt")
        let bytes = Data("Oslo\nBergen\n".utf8)
        let probe = KeywordListEditorFileAccessProbe(readData: bytes)
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.appendEntries(
            [" Bergen ", "Trondheim", "Oslo", "Tromsø"],
            to: destination,
            requestID: requestID
        )

        #expect(result == .committed(QuickListMutationCommit(
            requestID: requestID,
            destinationURL: destination,
            entries: ["Oslo", "Bergen", "Trondheim", "Tromsø"],
            addedEntries: ["Trondheim", "Tromsø"],
            byteCount: Data("Oslo\nBergen\nTrondheim\nTromsø\n".utf8).count,
            cancellationRequestedAfterCommit: false
        )))
        #expect(probe.writtenData == Data("Oslo\nBergen\nTrondheim\nTromsø\n".utf8))
        #expect(!probe.ranOnMainThread)
    }

    @Test("append reports a missing managed list without entering the reader")
    func appendMissingDestination() async throws {
        let destination = URL(fileURLWithPath: "/virtual/missing.txt")
        let probe = KeywordListEditorFileAccessProbe(itemExists: false)
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.appendEntries(
            ["News"],
            to: destination,
            requestID: requestID
        )

        #expect(result == .missingDestination(
            requestID: requestID,
            destinationURL: destination
        ))
        #expect(probe.readInvocationCount == 0)
        #expect(probe.writtenData == nil)
    }

    @Test("first-use import holds security scope and creates the managed list before append")
    func firstUseImport() async throws {
        let source = URL(fileURLWithPath: "/picked/credit.txt")
        let destination = URL(fileURLWithPath: "/managed/credit.txt")
        let probe = KeywordListEditorFileAccessProbe(files: [source: Data("Agency\nDesk\n".utf8)])
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.appendEntries(
            ["Desk", "Freelance"],
            to: destination,
            importing: source,
            requestID: requestID
        )

        #expect(result == .committed(QuickListMutationCommit(
            requestID: requestID,
            destinationURL: destination,
            entries: ["Agency", "Desk", "Freelance"],
            addedEntries: ["Agency", "Desk", "Freelance"],
            byteCount: Data("Agency\nDesk\nFreelance\n".utf8).count,
            cancellationRequestedAfterCommit: false
        )))
        #expect(probe.securityScopeStartCount == 1)
        #expect(probe.securityScopeStopCount == 1)
    }

    @Test("first-use import preserves CSV parsing before appending")
    func firstUseCSVImport() async throws {
        let source = URL(fileURLWithPath: "/picked/keywords.csv")
        let destination = URL(fileURLWithPath: "/managed/keywords.txt")
        let probe = KeywordListEditorFileAccessProbe(
            files: [source: Data("News,ignored column\nSport,ignored column\n".utf8)]
        )
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.appendEntries(
            ["Weather"],
            to: destination,
            importing: source,
            requestID: requestID
        )

        #expect(result == .committed(QuickListMutationCommit(
            requestID: requestID,
            destinationURL: destination,
            entries: ["News", "Sport", "Weather"],
            addedEntries: ["News", "Sport", "Weather"],
            byteCount: Data("News\nSport\nWeather\n".utf8).count,
            cancellationRequestedAfterCommit: false
        )))
    }

    @Test("file import merges into an existing managed list instead of replacing it")
    func importMergesIntoExistingList() async throws {
        let source = URL(fileURLWithPath: "/picked/city.txt")
        let destination = URL(fileURLWithPath: "/managed/city.txt")
        let probe = KeywordListEditorFileAccessProbe(files: [
            destination: Data("Oslo\nBergen\n".utf8),
            source: Data("Bergen\nTromsø\n\nOslo\nStavanger\n".utf8),
        ])
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.appendEntries(
            [],
            to: destination,
            importing: source,
            requestID: requestID
        )

        // Existing entries keep their order; only the file's new entries are appended.
        #expect(result == .committed(QuickListMutationCommit(
            requestID: requestID,
            destinationURL: destination,
            entries: ["Oslo", "Bergen", "Tromsø", "Stavanger"],
            addedEntries: ["Tromsø", "Stavanger"],
            byteCount: Data("Oslo\nBergen\nTromsø\nStavanger\n".utf8).count,
            cancellationRequestedAfterCommit: false
        )))
        #expect(probe.writtenData == Data("Oslo\nBergen\nTromsø\nStavanger\n".utf8))
    }

    @Test("file import that adds nothing leaves the managed list untouched")
    func importWithNoNewEntriesIsUnchanged() async throws {
        let source = URL(fileURLWithPath: "/picked/city.txt")
        let destination = URL(fileURLWithPath: "/managed/city.txt")
        let probe = KeywordListEditorFileAccessProbe(files: [
            destination: Data("Oslo\nBergen\n".utf8),
            source: Data("Bergen\n".utf8),
        ])
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.appendEntries(
            [],
            to: destination,
            importing: source,
            requestID: requestID
        )

        #expect(result == .unchanged(
            requestID: requestID,
            destinationURL: destination,
            entries: ["Oslo", "Bergen"]
        ))
        #expect(probe.writtenData == nil)
    }

    @Test("append publishes exact durable evidence when cancellation arrives in the writer")
    func appendDurableCancellationEvidence() async throws {
        let destination = URL(fileURLWithPath: "/virtual/event.txt")
        let probe = KeywordListEditorFileAccessProbe(
            readData: Data("Final\n".utf8),
            cancelDuringWrite: true
        )
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await Task {
            try await service.appendEntries(
                ["Awards"],
                to: destination,
                requestID: requestID
            )
        }.value

        #expect(result == .committed(QuickListMutationCommit(
            requestID: requestID,
            destinationURL: destination,
            entries: ["Final", "Awards"],
            addedEntries: ["Awards"],
            byteCount: Data("Final\nAwards\n".utf8).count,
            cancellationRequestedAfterCommit: true
        )))
    }

    @Test("Quick List deletion returns durable evidence off MainActor")
    @MainActor
    func deletionRunsOffMainActor() async throws {
        let destination = URL(fileURLWithPath: "/virtual/event.txt")
        let probe = KeywordListEditorFileAccessProbe()
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.deleteQuickList(
            at: destination,
            requestID: requestID
        )

        #expect(result == .removed(
            requestID: requestID,
            destinationURL: destination,
            cancellationRequestedAfterCommit: false
        ))
        #expect(probe.removedURL == destination)
        #expect(!probe.ranOnMainThread)
    }

    @Test("Settings retries root resolution before writing after a route switch")
    @MainActor
    func settingsMutationUsesCurrentRoot() async throws {
        let oldRoot = URL(fileURLWithPath: "/virtual/old-settings-root")
        let newRoot = URL(fileURLWithPath: "/virtual/new-settings-root")
        let store = KeywordListsStore(usesTestStorage: false, cloudPreference: { true }, resolveCloudRoot: { oldRoot })
        let probe = KeywordListEditorFileAccessProbe(readData: Data("Existing\n".utf8))
        let model = SettingsViewModel(
            quickListPersistence: KeywordListEditorPersistenceService(access: probe.fileAccess),
            quickListStore: store
        )
        let deadline = ContinuousClock.now + .seconds(10)
        while model.quickListURL(for: .keywords) == nil {
            guard ContinuousClock.now < deadline else { throw KeywordListEditorFileAccessProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.quickListURL(for: .keywords) == oldRoot.appendingPathComponent("quick/keywords.txt"))
        store.applyICloudRoutingPreference(true, resolvedRoot: newRoot)
        #expect(await model.appendToQuickList(for: .keywords, values: ["Added"]))
        #expect(probe.writtenURL == newRoot.appendingPathComponent("quick/keywords.txt"))
        #expect(model.entries(for: .keywords) == ["Existing", "Added"])
    }

    @Test("Cancelled Settings mutation cannot write after suspended root lookup")
    @MainActor
    func settingsMutationCancellationDuringRootLookup() async throws {
        let gate = SettingsQuickListRootGate()
        let store = KeywordListsStore(usesTestStorage: false, cloudPreference: { true }, resolveCloudRoot: {
            await gate.resolve()
        })
        let probe = KeywordListEditorFileAccessProbe()
        let model = SettingsViewModel(
            quickListPersistence: KeywordListEditorPersistenceService(access: probe.fileAccess),
            quickListStore: store
        )
        let mutation = Task { await model.appendToQuickList(for: .keywords, values: ["Cancelled"]) }
        let deadline = ContinuousClock.now + .seconds(10)
        while await gate.requestCount < 2 {
            guard ContinuousClock.now < deadline else { throw KeywordListEditorFileAccessProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.existsInvocationCount == 0)
        mutation.cancel()
        await gate.release(URL(fileURLWithPath: "/virtual/resolved-settings-root"))
        #expect(await mutation.value == false)
        #expect(probe.writtenURL == nil)
    }

    @Test("Settings discards a cache read completed for an earlier root")
    @MainActor
    func settingsCacheRejectsEarlierRoot() async throws {
        let oldRoot = URL(fileURLWithPath: "/virtual/old-cache-root")
        let newRoot = URL(fileURLWithPath: "/virtual/new-cache-root")
        let store = KeywordListsStore(usesTestStorage: false, cloudPreference: { true }, resolveCloudRoot: { oldRoot })
        let probe = BlockingKeywordListEditorFileAccessProbe()
        let model = SettingsViewModel(
            quickListPersistence: KeywordListEditorPersistenceService(access: probe.fileAccess),
            quickListStore: store
        )
        defer { probe.releaseFirstRead() }
        try await probe.waitUntilFirstReadStarts()
        store.applyICloudRoutingPreference(true, resolvedRoot: newRoot)
        #expect(model.entries(for: .keywords).isEmpty)
        probe.releaseFirstRead()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.quickListURL(for: .keywords) != newRoot.appendingPathComponent("quick/keywords.txt") {
            guard ContinuousClock.now < deadline else { throw KeywordListEditorFileAccessProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.entries(for: .keywords) == ["first"])
        #expect(probe.maximumConcurrentReads == 1)
    }

    @Test("Settings publishes only actor-loaded Quick List snapshots")
    func settingsCacheSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/SettingsViewModel.swift"
            ),
            encoding: .utf8
        )

        #expect(settingsSource.contains("await persistence.loadQuickListCache("))
        #expect(settingsSource.contains("case .complete(let snapshot) = result"))
        #expect(settingsSource.contains("return quickListCache[type] ?? []"))
        #expect(settingsSource.contains("try await quickListPersistence.appendEntries("))
        #expect(settingsSource.contains("try await quickListPersistence.saveEntries("))
        #expect(settingsSource.contains("try await quickListPersistence.deleteQuickList("))
        #expect(!settingsSource.contains("KeywordListsStore.shared.readEntries("))
        #expect(!settingsSource.contains("KeywordListsStore.shared.writeEntries("))
        #expect(!settingsSource.contains("KeywordListsStore.shared.importEntries("))
        #expect(!settingsSource.contains("KeywordListsStore.shared.exists("))
        #expect(!settingsSource.contains("KeywordListsStore.shared.url(for:"))
        #expect(settingsSource.contains("try await store.resolveRootURL()"))

        let metadataPanelSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Metadata/MetadataPanel.swift"
            ),
            encoding: .utf8
        )
        let faceViewSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Faces/ExpandedFaceManagementView.swift"
            ),
            encoding: .utf8
        )
        #expect(metadataPanelSource.contains("try await settingsViewModel.setKeywordsListURL(url)"))
        #expect(!metadataPanelSource.contains("KeywordListsStore.shared.url(for:"))
        #expect(metadataPanelSource.contains("try await KeywordListsStore.shared.resolveURL(for:"))
        #expect(faceViewSource.contains("try await settingsViewModel.setPersonShownListURL(url)"))
    }

    @Test("SwiftUI editor awaits the owner and rejects stale load and save publication")
    func editorSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/KeywordListEditor.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains(
            "try await KeywordListEditorPersistenceService.shared.loadEntries("
        ))
        #expect(source.contains(
            "try await KeywordListEditorPersistenceService.shared.saveEntries("
        ))
        #expect(source.contains("guard loadRequestID == requestID, !Task.isCancelled"))
        #expect(source.contains("guard persistenceRequestID == requestID else { return }"))
        #expect(source.contains("entries: commit.entries"))
        #expect(source.contains("persistenceRequestID = nil\n            persistenceTask = nil"))

        let persistStart = try #require(source.range(of: "private func persist(overwriting: Bool = false)"))
        let persistSource = source[persistStart.lowerBound...]
        let durablePublication = try #require(persistSource.range(of:
            "KeywordListsStore.shared.recordExternalWrite("
        ))
        let uiRequestGate = try #require(persistSource.range(of:
            "guard persistenceRequestID == requestID else { return }"
        ))
        #expect(durablePublication.lowerBound < uiRequestGate.lowerBound)

        // Export must not write an empty file after a failed load.
        let exportButton = try #require(source.range(of: "Button(\"Export to File…\")"))
        let exportSuffix = source[exportButton.lowerBound...]
        let exportButtonEnd = try #require(exportSuffix.range(of: "if let feedback"))
        #expect(exportSuffix[..<exportButtonEnd.lowerBound].contains(".disabled(!canEdit)"))
        let exportStart = try #require(source.range(of: "private func exportToFile() {"))
        #expect(source[exportStart.upperBound...].hasPrefix("\n        guard canEdit else { return }"))
        // Each save replaces the previous outcome so a stale "Save failed" never lingers.
        let persistBody = try #require(source.range(of: "private func persist(overwriting: Bool = false) {"))
        let firstLaunch = try #require(source[persistBody.upperBound...].range(of: "persistenceTask = Task"))
        #expect(source[persistBody.upperBound..<firstLaunch.lowerBound].contains("feedback = nil"))

        #expect(!source.contains("KeywordListsStore.shared.readEntries(storeKey)"))
        #expect(!source.contains("KeywordListsStore.shared.writeEntries(entries, to: storeKey)"))
        #expect(!source.contains("ApprovedListService.shared.saveEntries(entries"))

        let panelSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Metadata/MetadataPanel.swift"
            ),
            encoding: .utf8
        )
        #expect(panelSource.contains(
            "try await KeywordListEditorPersistenceService.shared.appendEntries("
        ))
        #expect(panelSource.contains(
            "KeywordListsStore.shared.recordExternalWrite("
        ))
        #expect(!panelSource.contains("settingsViewModel.appendToQuickList("))
        #expect(!panelSource.contains("settingsViewModel.setQuickListURL("))
    }
}

private nonisolated final class KeywordListEditorFileAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let storedItemExists: Bool
    private let storedReadData: Data
    /// When set, only these URLs exist and each reads its own bytes.
    private let storedFiles: [URL: Data]?
    private let cancelDuringWrite: Bool
    private var existsCount = 0
    private var readCount = 0
    private var observedMainThread = false
    private var committedData: Data?
    private var committedURL: URL?
    private var removedItemURL: URL?
    private var scopeStartCount = 0
    private var scopeStopCount = 0

    init(
        itemExists: Bool = true,
        readData: Data = Data(),
        files: [URL: Data]? = nil,
        cancelDuringWrite: Bool = false
    ) {
        storedItemExists = itemExists
        storedReadData = readData
        storedFiles = files
        self.cancelDuringWrite = cancelDuringWrite
    }

    var fileAccess: KeywordListEditorFileAccess {
        KeywordListEditorFileAccess(
            itemExists: { [self] url in
                lock.withLock {
                    existsCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                if let storedFiles { return storedFiles[url] != nil }
                return storedItemExists
            },
            readData: { [self] url in
                lock.withLock {
                    readCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                if let storedFiles {
                    guard let data = storedFiles[url] else { throw CocoaError(.fileReadNoSuchFile) }
                    return data
                }
                return storedReadData
            },
            writeData: { [self] data, url in
                lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                    committedData = data
                    committedURL = url
                }
                if cancelDuringWrite {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            },
            removeItem: { [self] url in
                lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                    removedItemURL = url
                }
            },
            startAccessingSecurityScopedResource: { [self] _ in
                lock.withLock { scopeStartCount += 1 }
                return true
            },
            stopAccessingSecurityScopedResource: { [self] _ in
                lock.withLock { scopeStopCount += 1 }
            }
        )
    }

    var existsInvocationCount: Int { lock.withLock { existsCount } }
    var readInvocationCount: Int { lock.withLock { readCount } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var writtenData: Data? { lock.withLock { committedData } }
    var writtenURL: URL? { lock.withLock { committedURL } }
    var removedURL: URL? { lock.withLock { removedItemURL } }
    var securityScopeStartCount: Int { lock.withLock { scopeStartCount } }
    var securityScopeStopCount: Int { lock.withLock { scopeStopCount } }
}

private enum KeywordListEditorFileAccessProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingKeywordListEditorFileAccessProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var readCount = 0
    private var activeReads = 0
    private var maximumActiveReads = 0
    private var firstReadStarted = false
    private var firstReadReleased = false

    var fileAccess: KeywordListEditorFileAccess {
        KeywordListEditorFileAccess(
            itemExists: { _ in true },
            readData: { [self] _ in
                condition.lock()
                readCount += 1
                activeReads += 1
                maximumActiveReads = max(maximumActiveReads, activeReads)
                if readCount == 1 {
                    firstReadStarted = true
                    condition.broadcast()
                    while !firstReadReleased { if !condition.waitBounded() { break } }
                }
                activeReads -= 1
                condition.unlock()
                return Data("first\n".utf8)
            },
            writeData: { _, _ in }
        )
    }

    func waitUntilFirstReadStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition.withLock({ firstReadStarted }) {
            guard ContinuousClock.now < deadline else {
                // A test that gives up must not leave the probe holding a shared queue.
                releaseFirstRead()
                throw KeywordListEditorFileAccessProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstRead() {
        condition.withLock {
            firstReadReleased = true
            condition.broadcast()
        }
    }

    var readInvocationCount: Int { condition.withLock { readCount } }
    var maximumConcurrentReads: Int { condition.withLock { maximumActiveReads } }
}

private actor SettingsQuickListRootGate {
    private var continuations: [CheckedContinuation<URL?, Never>] = []
    private(set) var requestCount = 0

    func resolve() async -> URL? {
        requestCount += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func release(_ root: URL) {
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume(returning: root) }
    }
}

private nonisolated final class KeywordFilesystemTransactionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var routes = 0
    private var reads = 0
    private var approvedAccesses = 0

    func recordApprovedAccess() { lock.withLock { approvedAccesses += 1 } }
    var approvedAccessCount: Int { lock.withLock { approvedAccesses } }
    func recordRouting() { lock.withLock { routes += 1 } }
    func recordBackupRead() { lock.withLock { reads += 1 } }
    var routingCount: Int { lock.withLock { routes } }
    var backupReadCount: Int { lock.withLock { reads } }
}

@Suite("Keyword-list editor save baselines", .serialized)
struct KeywordListEditorSaveBaselineTests {
    private func tempList(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    @Test("a flat list changed elsewhere since it was loaded refuses the save and keeps the file")
    func entriesBaselineConflict() async throws {
        let list = try tempList("keywords.txt")
        defer { try? FileManager.default.removeItem(at: list.deletingLastPathComponent()) }
        try Data("Oslo\nBergen\n".utf8).write(to: list)
        let service = KeywordListEditorPersistenceService()

        // Another Mac adds an entry after the editor loaded ["Oslo", "Bergen"].
        try Data("Oslo\nBergen\nTromsø\n".utf8).write(to: list)
        await #expect(throws: KeywordListBaselineConflictError()) {
            try await service.saveEntries(["Oslo"], to: list, expectedEntries: ["Oslo", "Bergen"], requestID: UUID())
        }
        #expect(try String(contentsOf: list, encoding: .utf8) == "Oslo\nBergen\nTromsø\n")

        // A matching baseline saves; Overwrite (no baseline) saves regardless.
        let matching = try await service.saveEntries(
            ["Oslo", "Bergen", "Tromsø", "Bodø"], to: list,
            expectedEntries: ["Oslo", "Bergen", "Tromsø"], requestID: UUID()
        )
        guard case .committed = matching else { Issue.record("Expected a commit"); return }
        _ = try await service.saveEntries(["Only"], to: list, requestID: UUID())
        #expect(try String(contentsOf: list, encoding: .utf8) == "Only\n")
    }

    @Test("a missing list file matches an empty baseline")
    func missingFileMatchesEmptyBaseline() async throws {
        let list = try tempList("new.txt")
        defer { try? FileManager.default.removeItem(at: list.deletingLastPathComponent()) }
        let service = KeywordListEditorPersistenceService()
        _ = try await service.saveEntries(["First"], to: list, expectedEntries: [], requestID: UUID())
        #expect(try String(contentsOf: list, encoding: .utf8) == "First\n")
        _ = try await service.saveText("a\n", to: list.deletingLastPathComponent().appendingPathComponent("tree.txt"),
                                        expectedText: "", requestID: UUID())
    }

    @MainActor
    @Test("the keyword-hierarchy editor's save is refused when the tree file changed since it loaded")
    func structuredTreeBaselineConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tree-baseline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await KeywordListsStoreStorageOverride.$current.withValue(root) {
            let service = StructuredKeywordService()
            try await service.saveTree([StructuredKeyword(name: "sport", kind: .keyword)])
            let baseline = try #require(service.loadedText)

            // Another writer replaces the file behind the open editor.
            let file = root.appendingPathComponent(KeywordListKey.structured.relativePath)
            try Data("sport\n\ttennis\n".utf8).write(to: file)

            await #expect(throws: KeywordListBaselineConflictError()) {
                try await service.saveTree([StructuredKeyword(name: "mine", kind: .keyword)], expectedText: baseline)
            }
            #expect(try String(contentsOf: file, encoding: .utf8) == "sport\n\ttennis\n")
            // Overwrite is an explicit choice.
            try await service.saveTree([StructuredKeyword(name: "mine", kind: .keyword)])
            #expect(try String(contentsOf: file, encoding: .utf8) == "mine\n")
            #expect(service.loadedText == "mine\n")
        }
    }

    @MainActor
    @Test("keyword trees refuse to save to an unsettled local fallback while list sync is on")
    func unsettledRouteRefusesSave() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("unsettled-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("keywords.txt")
        let service = StructuredKeywordService(
            storageURL: { _ in file },
            resolveStorageURL: { _ in file },
            isSettledRoute: { _ in false }
        )
        await #expect(throws: ICloudStorageUnavailableError()) {
            try await service.saveTree([StructuredKeyword(name: "stranded", kind: .keyword)])
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite("Template storage while iCloud is unavailable", .serialized)
struct TemplateStorageICloudUnavailableTests {
    @Test("Templates sync on with no iCloud container resolves read-only and refuses writes")
    func refusesWritesWhileICloudUnavailable() throws {
        let defaults = AppDefaults.store
        let saved = defaults.object(forKey: UserDefaultsKeys.templatesICloudEnabled)
        defaults.set(true, forKey: UserDefaultsKeys.templatesICloudEnabled)
        defer {
            if let saved { defaults.set(saved, forKey: UserDefaultsKeys.templatesICloudEnabled) }
            else { defaults.removeObject(forKey: UserDefaultsKeys.templatesICloudEnabled) }
        }
        try AppPathsICloudOverride.$documents.withValue(.some(nil)) {
            let resolution = AppPaths.templatesDirectoryResolution()
            resolution.release()
            #expect(resolution.cloudUnavailable)
            #expect(AppPaths.templatesCloudUnavailable)
            #expect(AppPaths.developTemplatesDirectoryResolution().cloudUnavailable)
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("templates-ro-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let readOnly = TemplateStorageService(directoryURL: folder, refusesWrites: true)
        #expect(throws: ICloudStorageUnavailableError()) {
            try readOnly.save(MetadataTemplate(name: "Stranded"))
        }
        #expect(try readOnly.loadAll().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        let developReadOnly = DevelopTemplateStorageService(directoryURL: folder, refusesWrites: true)
        #expect(throws: ICloudStorageUnavailableError()) {
            try developReadOnly.save(DevelopTemplate(name: "Stranded"))
        }
    }

    @Test("a reachable container is used for templates when sync is on")
    func reachableContainerIsUsed() throws {
        let defaults = AppDefaults.store
        let saved = defaults.object(forKey: UserDefaultsKeys.templatesICloudEnabled)
        defaults.set(true, forKey: UserDefaultsKeys.templatesICloudEnabled)
        defer {
            if let saved { defaults.set(saved, forKey: UserDefaultsKeys.templatesICloudEnabled) }
            else { defaults.removeObject(forKey: UserDefaultsKeys.templatesICloudEnabled) }
        }
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent("fake-icloud-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: documents) }
        AppPathsICloudOverride.$documents.withValue(.some(documents)) {
            let resolution = AppPaths.templatesDirectoryResolution()
            resolution.release()
            #expect(!resolution.cloudUnavailable)
            #expect(resolution.url == documents.appendingPathComponent("Templates", isDirectory: true))
        }
    }
}
