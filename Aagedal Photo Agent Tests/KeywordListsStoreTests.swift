import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("KeywordListsStore")
struct KeywordListsStoreTests {

    private func clearAllStoreFiles() {
        let store = KeywordListsStore.shared
        for type in QuickListType.allCases {
            store.delete(.quick(type))
        }
        for field in ApprovedListField.allCases {
            store.delete(.approved(field))
        }
        store.delete(.structured)
    }

    @Test("writeEntries dedupes, trims, and round-trips through readEntries")
    func writeEntriesRoundTrip() throws {
        clearAllStoreFiles()
        let key = KeywordListKey.quick(.keywords)
        try KeywordListsStore.shared.writeEntries(
            ["  Berlin  ", "Paris", "", "Berlin", "London"],
            to: key
        )
        let entries = KeywordListsStore.shared.readEntries(key)
        #expect(entries == ["Berlin", "Paris", "London"])
    }

    @Test("writeText preserves the exact text including tabs and braces")
    func writeTextPreservesVerbatim() throws {
        clearAllStoreFiles()
        let text = "animals\n\tlivestock\n\t\t{cattle}\n\t[REPTILE]\n\t\talligator\n"
        try KeywordListsStore.shared.writeText(text, to: .structured)
        #expect(KeywordListsStore.shared.readText(.structured) == text)
    }

    @Test("exists reflects writes and deletes")
    func existsContract() throws {
        clearAllStoreFiles()
        let key = KeywordListKey.approved(.keywords)
        #expect(!KeywordListsStore.shared.exists(key))
        try KeywordListsStore.shared.writeEntries(["a"], to: key)
        #expect(KeywordListsStore.shared.exists(key))
        KeywordListsStore.shared.delete(key)
        #expect(!KeywordListsStore.shared.exists(key))
    }

    @Test("readEntries returns empty array when file is missing")
    func readEntriesMissingFile() {
        clearAllStoreFiles()
        #expect(KeywordListsStore.shared.readEntries(.quick(.event)) == [])
    }

    @Test("importEntries from a temp file writes through to the store")
    func importEntriesRoundTrip() throws {
        clearAllStoreFiles()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-test-\(UUID().uuidString).txt")
        try "Alice\nBob\nCharlie\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let entries = try KeywordListsStore.shared.importEntries(from: url, into: .quick(.personShown))
        #expect(entries == ["Alice", "Bob", "Charlie"])
        #expect(KeywordListsStore.shared.readEntries(.quick(.personShown)) == ["Alice", "Bob", "Charlie"])
    }

    @Test("Write posts a keywordListChanged notification carrying the key")
    func notificationOnWrite() async throws {
        clearAllStoreFiles()
        let key = KeywordListKey.quick(.credit)

        // Tests run in parallel and the observer listens with `object: nil`, so it
        // can receive `.keywordListChanged` posts triggered by *other* suites. Filter
        // to our own key and resume exactly once — otherwise a second matching post
        // resumes the continuation twice (SWIFT TASK CONTINUATION MISUSE → crash).
        nonisolated final class Box: @unchecked Sendable {
            var token: NSObjectProtocol?
            var resumed = false
        }
        let box = Box()

        // Set up a one-shot wait for the notification before triggering the write.
        let observed = await withCheckedContinuation { (continuation: CheckedContinuation<KeywordListKey?, Never>) in
            box.token = NotificationCenter.default.addObserver(
                forName: .keywordListChanged,
                object: nil,
                queue: .main  // callbacks serialize here, so the `resumed` guard is race-free
            ) { note in
                let observed = note.userInfo?[KeywordListsStore.changedKeyUserInfo] as? KeywordListKey
                guard observed == key, !box.resumed else { return }
                box.resumed = true
                if let token = box.token {
                    NotificationCenter.default.removeObserver(token)
                }
                continuation.resume(returning: observed)
            }
            DispatchQueue.main.async {
                try? KeywordListsStore.shared.writeEntries(["Acme"], to: key)
            }
        }
        #expect(observed == key)
    }
}

@Suite("Keyword-list backup preview filesystem boundary")
struct KeywordListBackupPreviewServiceTests {
    @Test("a complete immutable preview is read away from the main actor")
    @MainActor
    func completePreviewRunsOffMainActor() async throws {
        let source = URL(fileURLWithPath: "/virtual/backup.txt")
        let bytes = Data("People\n\tAlice\n".utf8)
        let requestID = UUID()
        let probe = KeywordListBackupPreviewReaderProbe(data: bytes)
        let service = KeywordListBackupPreviewService(
            reader: KeywordListBackupPreviewReader(read: probe.read)
        )

        let result = try await Task {
            try await service.loadPreview(from: source, requestID: requestID)
        }.value

        #expect(result == .loaded(KeywordListBackupPreviewSnapshot(
            requestID: requestID,
            sourceURL: source,
            text: "People\n\tAlice\n",
            byteCount: bytes.count
        )))
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("a pre-cancelled preview never enters the synchronous reader")
    func preCancellation() async throws {
        let requestID = UUID()
        let probe = KeywordListBackupPreviewReaderProbe(data: Data("unused".utf8))
        let service = KeywordListBackupPreviewService(
            reader: KeywordListBackupPreviewReader(read: probe.read)
        )
        let task = Task {
            await Task.yield()
            return try await service.loadPreview(
                from: URL(fileURLWithPath: "/virtual/cancelled.txt"),
                requestID: requestID
            )
        }
        task.cancel()

        let result = try await task.value

        #expect(result == .cancelledBeforeRead(requestID: requestID))
        #expect(probe.invocationCount == 0)
    }

    @Test("overlapping previews serialize and cancellation stops a queued read")
    func serializedQueuedCancellation() async throws {
        let firstURL = URL(fileURLWithPath: "/virtual/first.txt")
        let secondURL = URL(fileURLWithPath: "/virtual/second.txt")
        let firstID = UUID()
        let secondID = UUID()
        let probe = BlockingKeywordListBackupPreviewReaderProbe()
        let service = KeywordListBackupPreviewService(
            reader: KeywordListBackupPreviewReader(read: probe.read)
        )
        let first = Task {
            try await service.loadPreview(from: firstURL, requestID: firstID)
        }
        try await probe.waitUntilFirstReadStarts()
        let second = Task {
            try await service.loadPreview(from: secondURL, requestID: secondID)
        }
        second.cancel()
        probe.releaseFirstRead()

        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(firstResult == .loaded(KeywordListBackupPreviewSnapshot(
            requestID: firstID,
            sourceURL: firstURL,
            text: "first",
            byteCount: Data("first".utf8).count
        )))
        #expect(secondResult == .cancelledBeforeRead(requestID: secondID))
        #expect(probe.invocationCount == 1)
        #expect(probe.maximumConcurrentReads == 1)
    }

    @Test("cancellation during a non-preemptible read reports evidence without text")
    func cancellationAfterRead() async throws {
        let source = URL(fileURLWithPath: "/virtual/slow.txt")
        let bytes = Data("complete bytes".utf8)
        let requestID = UUID()
        let service = KeywordListBackupPreviewService(
            reader: KeywordListBackupPreviewReader { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return bytes
            }
        )

        let result = try await Task {
            try await service.loadPreview(from: source, requestID: requestID)
        }.value

        #expect(result == .cancelledAfterRead(
            requestID: requestID,
            sourceURL: source,
            byteCount: bytes.count
        ))
    }

    @Test("the backup sheet awaits the boundary and rejects stale completion")
    func backupSheetSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/KeywordListBackupsSheet.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func loadPreview("))
        let suffix = source[functionStart.lowerBound...]
        let functionEnd = try #require(suffix.range(of: "\n    private func cancelPreview()"))
        let functionSource = String(suffix[..<functionEnd.lowerBound])

        #expect(functionSource.contains(
            "try await KeywordListBackupPreviewService.shared.loadPreview("
        ))
        #expect(functionSource.contains("guard previewRequestID == requestID,"))
        #expect(functionSource.contains("previewedVersion?.id == version.id"))
        #expect(functionSource.contains("case .cancelledBeforeRead, .cancelledAfterRead:"))
        #expect(source.contains(".onDisappear {\n            cancelPreview()"))
        #expect(!source.contains("String(contentsOf: version.url"))
    }
}

@Suite("Keyword-list backup inventory and restore filesystem boundary")
struct KeywordListBackupFileServiceTests {
    @Test("Inventory reports unreadable directories separately from missing directories")
    func inventoryDirectoryFailures() async {
        let io = KeywordListBackupFileIO(
            contentsOfDirectory: { url in
                throw CocoaError(url.lastPathComponent == "missing" ? .fileReadNoSuchFile : .fileReadNoPermission)
            },
            inspectTextFile: { _ in fatalError("Unexpected inspection") },
            createDirectory: { _ in }, readData: { _ in Data() },
            writeData: { _, _ in }, removeItem: { _ in }
        )
        let result = await KeywordListBackupFileService(io: io).inventory(
            directories: ["missing", "unreadable"].map {
                .init(identifier: $0, directoryURL: URL(fileURLWithPath: "/virtual/\($0)"))
            }, requestID: UUID()
        )
        guard case .loaded(let snapshot) = result else {
            Issue.record("Expected inventory")
            return
        }
        #expect(snapshot.directories.map(\.isUnavailable) == [false, true])
        #expect(snapshot.directories.allSatisfy { $0.versions.isEmpty })
    }

    @Test("Inventory distinguishes empty text, invalid UTF-8, and unreadable backups")
    func inventoryPreservesUnavailableVersions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty.txt")
        let damaged = directory.appendingPathComponent("damaged.txt")
        let unreadable = directory.appendingPathComponent("unreadable.txt")
        try Data().write(to: empty)
        try Data([0xff]).write(to: damaged)
        try FileManager.default.createSymbolicLink(at: unreadable,
                                                   withDestinationURL: directory.appendingPathComponent("missing"))
        let result = await KeywordListBackupFileService().inventory(
            directories: [.init(identifier: "test", directoryURL: directory)], requestID: UUID()
        )
        guard case .loaded(let inventory) = result else {
            Issue.record("Expected inventory")
            return
        }
        let versions = try #require(inventory.directories.first?.versions)
        #expect(versions.count == 3)
        let emptySnapshot = try #require(versions.first { $0.url == empty })
        #expect(emptySnapshot.text == "")
        #expect(emptySnapshot.unavailableReason == nil)
        let damagedSnapshot = try #require(versions.first { $0.url == damaged })
        #expect(damagedSnapshot.text == nil)
        #expect(damagedSnapshot.unavailableReason == .invalidUTF8)
        #expect(damagedSnapshot.byteCount == 1)
        let unreadableSnapshot = try #require(versions.first { $0.url == unreadable })
        #expect(unreadableSnapshot.text == nil)
        #expect(unreadableSnapshot.unavailableReason == .unreadable)
    }

    @Test("Retention preserves damaged backups and keeps the minimum readable versions")
    func retentionPreservesUnavailableVersions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["old-damaged", "old-readable", "keep-readable", "new-damaged", "new-empty"]
        for (index, name) in names.enumerated() {
            let url = directory.appendingPathComponent(name + ".txt")
            let bytes = name.contains("damaged") ? Data([0xff]) : (name == "new-empty" ? Data() : Data(name.utf8))
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))],
                                                  ofItemAtPath: url.path)
        }
        await KeywordListBackupFileService().prune(
            directories: [directory], retentionCutoff: .distantFuture, minimumVersionCount: 1
        )
        let retained = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(retained) == ["old-damaged.txt", "keep-readable.txt", "new-damaged.txt"])
        #expect(try Data(contentsOf: directory.appendingPathComponent("old-damaged.txt")) == Data([0xff]))
    }

    @Test("Restore rejects damaged UTF-8 without changing the destination")
    func restoreRejectsDamagedBackup() async throws {
        let probe = KeywordListBackupFileIOProbe(files: [])
        probe.readDataResult = Data([0xff])
        let service = KeywordListBackupFileService(io: probe.fileIO)
        await #expect(throws: KeywordListBackupPreviewError.self) {
            try await service.restore(from: URL(fileURLWithPath: "/virtual/backup.txt"),
                                      to: URL(fileURLWithPath: "/virtual/list.txt"), requestID: UUID())
        }
        #expect(probe.writeInvocationCount == 0)
    }

    @Test("Restore preserves exact previous bytes even when the current list is damaged")
    func restoreBacksUpDamagedCurrentList() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("restore.txt")
        let destination = root.appendingPathComponent("current.txt")
        let safetyBackup = root.appendingPathComponent("history/safety.txt")
        let damaged = Data([0xff, 0xfe, 0x00])
        let replacement = Data("Restored\n".utf8)
        try replacement.write(to: source)
        try damaged.write(to: destination)
        let result = try await KeywordListBackupFileService().restore(
            from: source, to: destination, requestID: UUID(), previousContentBackupURL: safetyBackup
        )
        guard case .restored = result else {
            Issue.record("Expected successful restore")
            return
        }
        #expect(try Data(contentsOf: safetyBackup) == damaged)
        #expect(try Data(contentsOf: destination) == replacement)
    }

    @Test("A failed safety backup prevents restore from replacing the current list")
    func restoreAbortsWhenSafetyBackupFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("restore.txt")
        let destination = root.appendingPathComponent("current.txt")
        let safetyBackup = root.appendingPathComponent("safety.txt")
        let original = Data("Original\n".utf8)
        try Data("Replacement\n".utf8).write(to: source)
        try original.write(to: destination)
        let system = KeywordListBackupFileIO.system
        let io = KeywordListBackupFileIO(
            contentsOfDirectory: system.contentsOfDirectory, inspectTextFile: system.inspectTextFile,
            createDirectory: system.createDirectory, readData: system.readData,
            writeData: { data, url in
                if url == safetyBackup { throw CocoaError(.fileWriteNoPermission) }
                try system.writeData(data, url)
            }, removeItem: system.removeItem
        )
        await #expect(throws: CocoaError.self) {
            try await KeywordListBackupFileService(io: io).restore(
                from: source, to: destination, requestID: UUID(), previousContentBackupURL: safetyBackup
            )
        }
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test("Backup restore resolves the configured cloud root before writing")
    @MainActor
    func restoreResolvesCloudRoot() async throws {
        let root = URL(fileURLWithPath: "/virtual/resolved-lists")
        let store = KeywordListsStore(usesTestStorage: false, cloudPreference: { true },
                                     resolveCloudRoot: { root })
        let probe = KeywordListBackupFileIOProbe(files: [])
        probe.readDataResult = Data("Berlin".utf8)
        let service = KeywordListsBackupService(filesystem: KeywordListBackupFileService(io: probe.fileIO),
                                                store: store)
        let key = KeywordListKey.quick(.keywords)
        let version = KeywordListsBackupService.Version(
            key: key, url: URL(fileURLWithPath: "/virtual/backup.txt"), date: .now,
            entryCount: 1, byteCount: 6
        )
        let result = try await service.restore(version, requestID: UUID())
        guard case .restored(let commit) = result else {
            Issue.record("Expected restored result")
            return
        }
        #expect(commit.destinationURL == root.appendingPathComponent(key.relativePath))
        #expect(probe.writtenURL == commit.destinationURL)
        #expect(probe.writtenData == Data("Berlin".utf8))
    }

    @Test("Cancelling cloud resolution prevents backup restore filesystem work")
    @MainActor
    func restoreCancellationDuringCloudResolution() async throws {
        let gate = KeywordRootResolutionGate()
        let store = KeywordListsStore(usesTestStorage: false, cloudPreference: { true },
                                     resolveCloudRoot: { await gate.resolve() })
        let probe = KeywordListBackupFileIOProbe(files: [])
        let service = KeywordListsBackupService(filesystem: KeywordListBackupFileService(io: probe.fileIO),
                                                store: store)
        let version = KeywordListsBackupService.Version(
            key: .quick(.keywords), url: URL(fileURLWithPath: "/virtual/backup.txt"), date: .now,
            entryCount: 1, byteCount: 6
        )
        let task = Task { try await service.restore(version, requestID: UUID()) }
        try await gate.waitUntilEntered()
        task.cancel()
        await gate.resume(with: URL(fileURLWithPath: "/virtual/resolved-lists"))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.readInvocationCount == 0)
        #expect(probe.writeInvocationCount == 0)
    }

    @Test("managed source snapshot reads and writes off MainActor")
    @MainActor
    func snapshotReadsManagedSourceOffMainActor() async throws {
        let probe = KeywordListBackupFileIOProbe(files: [])
        probe.readDataResult = Data("Berlin\nParis\n".utf8)
        let service = KeywordListBackupFileService(io: probe.fileIO)
        let written = try await service.snapshot(
            sourceURL: URL(fileURLWithPath: "/virtual/list.txt"),
            directoryURL: URL(fileURLWithPath: "/virtual/backups"),
            destinationURL: URL(fileURLWithPath: "/virtual/backups/version.txt"),
            retentionCutoff: .distantPast, minimumVersionCount: 1
        )
        #expect(written)
        #expect(probe.writtenData == probe.readDataResult)
        #expect(!probe.ranOnMainThread)
    }

    @Test("cancellation after managed source read prevents a backup write")
    func snapshotCancellationAfterSourceRead() async throws {
        let probe = KeywordListBackupFileIOProbe(files: [])
        probe.readDataResult = Data("Berlin".utf8)
        probe.cancelDuringRead = true
        let service = KeywordListBackupFileService(io: probe.fileIO)
        let task = Task {
            try await service.snapshot(
                sourceURL: URL(fileURLWithPath: "/virtual/list.txt"),
                directoryURL: URL(fileURLWithPath: "/virtual/backups"),
                destinationURL: URL(fileURLWithPath: "/virtual/backups/version.txt"),
                retentionCutoff: .distantPast, minimumVersionCount: 1
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.writeInvocationCount == 0)
    }

    @Test("recovery source scan distinguishes missing and empty from unreadable lists")
    @MainActor
    func recoverySourceStates() async throws {
        let io = KeywordListBackupFileIO(
            contentsOfDirectory: { _ in [] },
            inspectTextFile: { _ in fatalError("Unexpected backup inspection") },
            createDirectory: { _ in },
            readData: { url in
                #expect(!Thread.isMainThread)
                switch url.lastPathComponent {
                case "missing": throw CocoaError(.fileReadNoSuchFile)
                case "unreadable": throw CocoaError(.fileReadNoPermission)
                case "empty": return Data(" \n".utf8)
                default: return Data("Berlin".utf8)
                }
            },
            writeData: { _, _ in }, removeItem: { _ in }
        )
        let service = KeywordListBackupFileService(io: io)
        let identifiers = try await service.emptySourceIdentifiers(
            ["missing", "unreadable", "empty", "populated"].map {
                KeywordListBackupSourceRequest(
                    identifier: $0, sourceURL: URL(fileURLWithPath: "/virtual/\($0)")
                )
            }
        )
        #expect(identifiers == ["missing", "empty"])
    }

    @Test("inventory returns an immutable sorted snapshot away from the main actor")
    @MainActor
    func inventoryRunsOffMainActor() async {
        let directory = URL(fileURLWithPath: "/virtual/backups")
        let older = directory.appendingPathComponent("older.txt")
        let newer = directory.appendingPathComponent("newer.txt")
        let requestID = UUID()
        let probe = KeywordListBackupFileIOProbe(files: [older, newer])
        probe.snapshots = [
            older: KeywordListBackupFileSnapshot(
                url: older,
                date: Date(timeIntervalSince1970: 10),
                text: "older",
                byteCount: 5
            ),
            newer: KeywordListBackupFileSnapshot(
                url: newer,
                date: Date(timeIntervalSince1970: 20),
                text: "newer",
                byteCount: 5
            )
        ]
        let service = KeywordListBackupFileService(io: probe.fileIO)

        let result = await Task {
            await service.inventory(
                directories: [KeywordListBackupDirectoryRequest(
                    identifier: "structured/keywords.txt",
                    directoryURL: directory
                )],
                requestID: requestID
            )
        }.value

        #expect(result == .loaded(KeywordListBackupInventorySnapshot(
            requestID: requestID,
            directories: [KeywordListBackupDirectorySnapshot(
                identifier: "structured/keywords.txt",
                versions: [probe.snapshots[newer]!, probe.snapshots[older]!]
            )]
        )))
        #expect(probe.contentsInvocationCount == 1)
        #expect(probe.inspectInvocationCount == 2)
        #expect(!probe.ranOnMainThread)
    }

    @Test("a cancelled queued inventory does not enter filesystem enumeration")
    func queuedInventoryCancellation() async throws {
        let probe = BlockingKeywordListBackupFileIOProbe()
        let service = KeywordListBackupFileService(io: probe.fileIO)
        let firstID = UUID()
        let secondID = UUID()
        let request = [KeywordListBackupDirectoryRequest(
            identifier: "quick/keywords.txt",
            directoryURL: URL(fileURLWithPath: "/virtual/backups")
        )]
        let first = Task { await service.inventory(directories: request, requestID: firstID) }
        try await probe.waitUntilFirstEnumerationStarts()
        let second = Task { await service.inventory(directories: request, requestID: secondID) }
        second.cancel()
        probe.releaseFirstEnumeration()

        _ = await first.value
        let secondResult = await second.value

        #expect(secondResult == .cancelled(
            requestID: secondID,
            completedDirectoryCount: 0,
            discoveredVersionCount: 0
        ))
        #expect(probe.contentsInvocationCount == 1)
        #expect(probe.maximumConcurrentEnumerations == 1)
    }

    @Test("restore reports cancellation after read and does not commit")
    func restoreCancellationAfterRead() async throws {
        let source = URL(fileURLWithPath: "/virtual/source.txt")
        let destination = URL(fileURLWithPath: "/virtual/destination.txt")
        let bytes = Data("restored".utf8)
        let probe = KeywordListBackupFileIOProbe(files: [])
        probe.readDataResult = bytes
        probe.cancelDuringRead = true
        let service = KeywordListBackupFileService(io: probe.fileIO)
        let requestID = UUID()

        let result = try await Task {
            try await service.restore(
                from: source,
                to: destination,
                requestID: requestID
            )
        }.value

        #expect(result == .cancelledAfterRead(
            requestID: requestID,
            sourceURL: source,
            byteCount: bytes.count
        ))
        #expect(probe.writeInvocationCount == 0)
    }

    @Test("restore exposes cancellation observed after its durable commit")
    func restoreDurableAfterCancellation() async throws {
        let source = URL(fileURLWithPath: "/virtual/source.txt")
        let destination = URL(fileURLWithPath: "/virtual/destination.txt")
        let bytes = Data("restored".utf8)
        let probe = KeywordListBackupFileIOProbe(files: [])
        probe.readDataResult = bytes
        probe.cancelDuringWrite = true
        let service = KeywordListBackupFileService(io: probe.fileIO)
        let requestID = UUID()

        let result = try await Task {
            try await service.restore(
                from: source,
                to: destination,
                requestID: requestID
            )
        }.value

        #expect(result == .restored(KeywordListBackupRestoreCommit(
            requestID: requestID,
            sourceURL: source,
            destinationURL: destination,
            byteCount: bytes.count,
            cancellationObservedAfterCommit: true
        )))
        #expect(probe.writtenData == bytes)
        #expect(probe.writtenURL == destination)
    }

    @Test("the backup sheet awaits inventory and restore with stale-result guards")
    func backupSheetAsyncSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/KeywordListBackupsSheet.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("await KeywordListsBackupService.shared.allVersionsByKey("))
        #expect(source.contains("guard inventoryRequestID == requestID else { return }"))
        #expect(source.contains("try await KeywordListsBackupService.shared.restore("))
        #expect(source.contains("guard restoreRequestID == requestID else { return }"))
        #expect(!source.contains("KeywordListsBackupService.shared.restore(version)"))
    }
}

private nonisolated final class KeywordListBackupPreviewReaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var count = 0
    private var observedMainThread = false

    init(data: Data) {
        self.data = data
    }

    func read(_ url: URL) throws -> Data {
        _ = url
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return data
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

private nonisolated final class KeywordListBackupFileIOProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let files: [URL]
    var snapshots: [URL: KeywordListBackupFileSnapshot] = [:]
    var readDataResult = Data()
    var cancelDuringRead = false
    var cancelDuringWrite = false
    private var contentsCount = 0
    private var inspectCount = 0
    private var writeCount = 0
    private var readCount = 0
    private var observedMainThread = false
    private var committedData: Data?
    private var committedURL: URL?

    init(files: [URL]) {
        self.files = files
    }

    var fileIO: KeywordListBackupFileIO {
        KeywordListBackupFileIO(
            contentsOfDirectory: { [self] _ in
                lock.withLock {
                    contentsCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                return files
            },
            inspectTextFile: { [self] url in
                lock.withLock {
                    inspectCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                    return snapshots[url]!
                }
            },
            createDirectory: { _ in },
            readData: { [self] _ in
                let (data, shouldCancel) = lock.withLock {
                    readCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                    return (readDataResult, cancelDuringRead)
                }
                if shouldCancel { withUnsafeCurrentTask { $0?.cancel() } }
                return data
            },
            writeData: { [self] data, url in
                let shouldCancel = lock.withLock {
                    writeCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                    committedData = data
                    committedURL = url
                    return cancelDuringWrite
                }
                if shouldCancel { withUnsafeCurrentTask { $0?.cancel() } }
            },
            removeItem: { _ in }
        )
    }

    var contentsInvocationCount: Int { lock.withLock { contentsCount } }
    var inspectInvocationCount: Int { lock.withLock { inspectCount } }
    var readInvocationCount: Int { lock.withLock { readCount } }
    var writeInvocationCount: Int { lock.withLock { writeCount } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var writtenData: Data? { lock.withLock { committedData } }
    var writtenURL: URL? { lock.withLock { committedURL } }
}

private nonisolated final class BlockingKeywordListBackupFileIOProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var contentsCount = 0
    private var activeEnumerations = 0
    private var maximumActiveEnumerations = 0
    private var firstEnumerationReleased = false

    var fileIO: KeywordListBackupFileIO {
        KeywordListBackupFileIO(
            contentsOfDirectory: { [self] _ in
                condition.lock()
                contentsCount += 1
                activeEnumerations += 1
                maximumActiveEnumerations = max(maximumActiveEnumerations, activeEnumerations)
                condition.broadcast()
                if contentsCount == 1 {
                    while !firstEnumerationReleased { condition.wait() }
                }
                activeEnumerations -= 1
                condition.unlock()
                return []
            },
            inspectTextFile: { url in
                KeywordListBackupFileSnapshot(
                    url: url,
                    date: .distantPast,
                    text: "",
                    byteCount: 0
                )
            },
            createDirectory: { _ in },
            readData: { _ in Data() },
            writeData: { _, _ in },
            removeItem: { _ in }
        )
    }

    func waitUntilFirstEnumerationStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while contentsInvocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw KeywordListBackupPreviewProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstEnumeration() {
        condition.lock()
        firstEnumerationReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var contentsInvocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return contentsCount
    }

    var maximumConcurrentEnumerations: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveEnumerations
    }
}

private enum KeywordListBackupPreviewProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingKeywordListBackupPreviewReaderProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var readCount = 0
    private var activeReads = 0
    private var maximumActiveReads = 0
    private var firstReadReleased = false

    func read(_ url: URL) throws -> Data {
        _ = url
        condition.lock()
        readCount += 1
        activeReads += 1
        maximumActiveReads = max(maximumActiveReads, activeReads)
        condition.broadcast()
        if readCount == 1 {
            while !firstReadReleased {
                condition.wait()
            }
        }
        activeReads -= 1
        condition.unlock()
        return Data("first".utf8)
    }

    func waitUntilFirstReadStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while invocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw KeywordListBackupPreviewProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstRead() {
        condition.lock()
        firstReadReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var invocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return readCount
    }

    var maximumConcurrentReads: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveReads
    }
}

@Suite("Keyword list legacy migration filesystem boundary")
struct KeywordListsLegacyMigrationServiceTests {
    private func source(_ id: String, bookmark: Data? = Data([1])) -> KeywordListsLegacyMigrationSource {
        KeywordListsLegacyMigrationSource(
            id: id, bookmarkKey: id, bookmarkData: bookmark, key: .structured,
            destinationURL: URL(fileURLWithPath: "/unused/\(id).txt"), format: .structured
        )
    }

    @Test("Cancellation before execution never resolves or opens legacy files")
    func cancellationBeforeAccess() async {
        let service = KeywordListsLegacyMigrationService(access: .init(
            readSource: { _, _ in Issue.record("Unexpected source read"); return "" },
            writeTextIfMissing: { _, _ in Issue.record("Unexpected write"); return false },
            readDestination: { _ in Issue.record("Unexpected verification"); return "" }
        ))
        let sources = [source("first")]
        let id = UUID()
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.migrate(sources: sources, requestID: id) { _ in
                Issue.record("Unexpected bookmark resolution")
                return nil
            }
        }.value
        #expect(result == KeywordListsLegacyMigrationResult(
            requestID: id, completedIDs: [], writtenIDs: [], failedIDs: [], cancelled: true
        ))
    }

    @Test("Cancellation during source read leaves destination untouched")
    func cancellationDuringRead() async {
        let service = KeywordListsLegacyMigrationService(access: .init(
            readSource: { _, _ in
                #expect(!Thread.isMainThread)
                withUnsafeCurrentTask { $0?.cancel() }
                return "legacy"
            },
            writeTextIfMissing: { _, _ in Issue.record("Cancelled read must not write"); return false },
            readDestination: { _ in Issue.record("Cancelled read must not verify"); return "" }
        ))
        let sources = [source("first")]
        let result = await Task {
            await service.migrate(sources: sources, requestID: UUID()) { _ in
                URL(fileURLWithPath: "/unused/source.txt")
            }
        }.value
        #expect(result.cancelled)
        #expect(result.completedIDs.isEmpty)
        #expect(result.writtenIDs.isEmpty)
        #expect(result.failedIDs.isEmpty)
    }

    @Test("Cancellation during write preserves verified commit and skips subsequent sources")
    func cancellationDuringWrite() async {
        let service = KeywordListsLegacyMigrationService(access: .init(
            readSource: { _, _ in "legacy" },
            writeTextIfMissing: { _, url in
                #expect(!Thread.isMainThread)
                #expect(url.lastPathComponent == "first.txt")
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            },
            readDestination: { _ in "legacy" }
        ))
        let sources = [source("first"), source("second")]
        let result = await Task {
            await service.migrate(sources: sources, requestID: UUID()) { _ in
                URL(fileURLWithPath: "/unused/source.txt")
            }
        }.value
        #expect(result.cancelled)
        #expect(result.writtenIDs == ["first"])
        #expect(result.completedIDs == ["first"])
        #expect(result.failedIDs.isEmpty)
    }

    @Test("Read-back failure preserves durable evidence and permits later source migration")
    func verificationFailureContinues() async {
        let service = KeywordListsLegacyMigrationService(access: .init(
            readSource: { _, _ in "legacy" },
            writeTextIfMissing: { _, _ in true },
            readDestination: { url in url.lastPathComponent == "first.txt" ? "corrupt" : "legacy" }
        ))
        let result = await service.migrate(
            sources: [source("first"), source("second"), source("absent", bookmark: nil)],
            requestID: UUID()
        ) { _ in URL(fileURLWithPath: "/unused/source.txt") }
        #expect(!result.cancelled)
        #expect(result.writtenIDs == ["first", "second"])
        #expect(result.completedIDs == ["second", "absent"])
        #expect(result.failedIDs == ["first"])
    }

    @Test("Managed list created during source read wins over legacy migration")
    func concurrentManagedWriteIsPreserved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacySeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("managed.txt")
        let source = KeywordListsLegacyMigrationSource(
            id: "structured", bookmarkKey: "unused", bookmarkData: Data([1]),
            key: .structured, destinationURL: destination, format: .structured
        )
        let service = KeywordListsLegacyMigrationService(access: .init(
            readSource: { _, _ in
                try CloudCoordinatedIO.writeText("User's newer list", to: destination)
                return "Legacy list"
            },
            writeTextIfMissing: KeywordListsLegacyMigrationFileAccess.system.writeTextIfMissing,
            readDestination: { _ in Issue.record("Preserved destination needs no verification"); return "" }
        ))
        let result = await service.migrate(sources: [source], requestID: UUID()) { _ in
            root.appendingPathComponent("legacy.txt")
        }
        #expect(result.completedIDs == ["structured"])
        #expect(result.writtenIDs.isEmpty)
        #expect(result.failedIDs.isEmpty)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "User's newer list")
    }

    @Test("An undownloaded cloud placeholder is preserved during migration")
    func placeholderIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyPlaceholder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("managed.txt")
        let placeholder = root.appendingPathComponent(".managed.txt.icloud")
        try Data().write(to: placeholder)
        #expect(try !CloudCoordinatedIO.writeTextIfMissing("Legacy list", to: destination))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: placeholder.path))
    }

    @Test("Unresolvable bookmark remains retryable without touching files")
    func unresolvedBookmark() async {
        let service = KeywordListsLegacyMigrationService(access: .init(
            readSource: { _, _ in Issue.record("Unexpected source read"); return "" },
            writeTextIfMissing: { _, _ in Issue.record("Unexpected write"); return false },
            readDestination: { _ in Issue.record("Unexpected verification"); return "" }
        ))
        let result = await service.migrate(sources: [source("first")], requestID: UUID()) { _ in nil }
        #expect(result.failedIDs == ["first"])
        #expect(result.completedIDs.isEmpty)
        #expect(result.writtenIDs.isEmpty)
        #expect(!result.cancelled)
    }
}

@MainActor
@Suite("Keyword store path resolution")
struct KeywordListsStorePathResolutionTests {
    @Test("Resolving a test root does not create directories; coordinated writes prepare parents")
    func resolvingRootIsReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try KeywordListsStoreStorageOverride.$current.withValue(root) {
            let store = KeywordListsStore()
            #expect(store.rootURL == root)
            #expect(store.url(for: .structured) == root.appendingPathComponent("structured/keywords.txt"))
            #expect(!FileManager.default.fileExists(atPath: root.path))
            try store.writeText("Prepared lazily", to: .structured)
            #expect(store.readText(.structured) == "Prepared lazily")
        }
    }
}

@Suite("Keyword list reconciliation read failures")
struct KeywordListsReconciliationReadFailureTests {
    @Test("Earlier unions survive a later read failure and retry without duplicates")
    func partialMergeRetryIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let firstPath = KeywordListKey.quick(.keywords).relativePath
        let laterPath = KeywordListKey.quick(.personShown).relativePath
        let firstDestination = destination.appendingPathComponent(firstPath)
        let laterDestination = destination.appendingPathComponent(laterPath)
        let laterSource = source.appendingPathComponent(laterPath)
        try CloudCoordinatedIO.writeText("Paris\nLondon\n", to: source.appendingPathComponent(firstPath))
        try CloudCoordinatedIO.writeText("Berlin\nParis\n", to: firstDestination)
        try CloudCoordinatedIO.writeText("Alice\n", to: laterDestination)
        let placeholder = laterSource.deletingLastPathComponent()
            .appendingPathComponent(".\(laterSource.lastPathComponent).icloud")
        try Data().write(to: placeholder)

        #expect(throws: (any Error).self) {
            try KeywordListsStore.reconcileTree(from: source, to: destination)
        }
        let expectedFirst = "Berlin\nParis\nLondon\n"
        #expect(try String(contentsOf: firstDestination, encoding: .utf8) == expectedFirst)
        #expect(try String(contentsOf: laterDestination, encoding: .utf8) == "Alice\n")

        // Simulate the later list becoming available, then repeat the entire reconciliation.
        try FileManager.default.removeItem(at: placeholder)
        try CloudCoordinatedIO.writeText("Alice\nBob\n", to: laterSource)
        try KeywordListsStore.reconcileTree(from: source, to: destination)
        #expect(try String(contentsOf: firstDestination, encoding: .utf8) == expectedFirst)
        #expect(try String(contentsOf: laterDestination, encoding: .utf8) == "Alice\nBob\n")
    }

    @Test("An unreadable list aborts reconciliation without replacing destination content",
          arguments: [true, false], [true, false])
    func unreadableListPreservesDestination(failingSource: Bool, placeholder: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let key = KeywordListKey.quick(.keywords)
        let sourceFile = source.appendingPathComponent(key.relativePath)
        let destinationFile = destination.appendingPathComponent(key.relativePath)
        let unreadable = failingSource ? sourceFile : destinationFile
        let readable = failingSource ? destinationFile : sourceFile
        try CloudCoordinatedIO.writeText("Existing entries\n", to: readable)
        try FileManager.default.createDirectory(
            at: unreadable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let unavailableItem: URL
        if placeholder {
            unavailableItem = unreadable.deletingLastPathComponent()
                .appendingPathComponent(".\(unreadable.lastPathComponent).icloud")
            try Data("Remote placeholder".utf8).write(to: unavailableItem)
        } else {
            // A directory at a list path deterministically fails Data's file read, including
            // when tests run with privileges that would bypass POSIX permission bits.
            unavailableItem = unreadable
            try FileManager.default.createDirectory(at: unavailableItem, withIntermediateDirectories: true)
        }

        #expect(throws: (any Error).self) {
            try KeywordListsStore.reconcileTree(from: source, to: destination)
        }

        #expect(try String(contentsOf: readable, encoding: .utf8) == "Existing entries\n")
        #expect(FileManager.default.fileExists(atPath: unavailableItem.path))
        if placeholder {
            #expect(!FileManager.default.fileExists(atPath: unreadable.path))
            #expect(try Data(contentsOf: unavailableItem) == Data("Remote placeholder".utf8))
        }
    }

    @Test("A genuinely missing destination is seeded and existing lists retain union order")
    func missingDestinationAndUnion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let key = KeywordListKey.quick(.keywords)
        let sourceFile = source.appendingPathComponent(key.relativePath)
        let destinationFile = destination.appendingPathComponent(key.relativePath)
        try CloudCoordinatedIO.writeText("Berlin\nParis\n", to: sourceFile)

        try KeywordListsStore.reconcileTree(from: source, to: destination)
        #expect(try String(contentsOf: destinationFile, encoding: .utf8) == "Berlin\nParis\n")

        try CloudCoordinatedIO.writeText("Paris\nLondon\n", to: sourceFile)
        try KeywordListsStore.reconcileTree(from: source, to: destination)
        #expect(try String(contentsOf: destinationFile, encoding: .utf8) == "Berlin\nParis\nLondon\n")
    }
}

@Suite("Keyword-list durable write route publication")
@MainActor
struct KeywordListsStoreRoutePublicationTests {
    @Test("An old-root commit invalidates the current route without publishing stale payload or owner identity")
    func staleCommitInvalidatesActiveRoute() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        KeywordListsStoreStorageOverride.$current.withValue(root) {
            let store = KeywordListsStore()
            let key = KeywordListKey.approved(.keywords)
            let owner = UUID()
            var received = false
            let token = NotificationCenter.default.addObserver(
                forName: .keywordListChanged, object: store, queue: .main
            ) { note in
                let entries = note.userInfo?[KeywordListsStore.changedEntriesUserInfo] as? [String]
                let text = note.userInfo?[KeywordListsStore.changedTextUserInfo] as? String
                let sourceID = note.userInfo?[KeywordListsStore.changedSourceIDUserInfo] as? UUID
                let route = note.userInfo?[KeywordListsStore.changedDestinationURLUserInfo] as? URL
                MainActor.assumeIsolated {
                    received = true
                    #expect(entries == nil)
                    #expect(text == nil)
                    #expect(sourceID == nil)
                    #expect(route == store.url(for: key))
                }
            }
            defer { NotificationCenter.default.removeObserver(token) }
            store.recordExternalWrite(
                to: key,
                destinationURL: root.appendingPathComponent("previous/keywords.txt"),
                entries: ["Stale"], text: "Stale", sourceID: owner
            )
            #expect(received)
            #expect(store.version == 1)
        }
    }

    @Test("A current-root commit retains its payload and includes the route for deferred observers")
    func currentCommitCarriesRoute() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        KeywordListsStoreStorageOverride.$current.withValue(root) {
            let store = KeywordListsStore()
            let key = KeywordListKey.quick(.keywords)
            let destination = store.url(for: key)
            let owner = UUID()
            var received = false
            let token = NotificationCenter.default.addObserver(
                forName: .keywordListChanged, object: store, queue: .main
            ) { note in
                let entries = note.userInfo?[KeywordListsStore.changedEntriesUserInfo] as? [String]
                let text = note.userInfo?[KeywordListsStore.changedTextUserInfo] as? String
                let sourceID = note.userInfo?[KeywordListsStore.changedSourceIDUserInfo] as? UUID
                let route = note.userInfo?[KeywordListsStore.changedDestinationURLUserInfo] as? URL
                MainActor.assumeIsolated {
                    received = true
                    #expect(entries == ["Current"])
                    #expect(text == nil)
                    #expect(sourceID == owner)
                    #expect(route == destination)
                }
            }
            defer { NotificationCenter.default.removeObserver(token) }
            store.recordExternalWrite(to: key, destinationURL: destination, entries: ["Current"], sourceID: owner)
            #expect(received)
        }
    }
}

@Suite("Keyword root resolution")
struct KeywordListsRootResolutionTests {
    @Test("Container lookup runs away from the main thread")
    func resolvesOffMainThread() async {
        let container = URL(fileURLWithPath: "/tmp/keyword-container", isDirectory: true)
        let service = KeywordListsRootResolutionService(resolveContainer: {
            #expect(!Thread.isMainThread)
            return container
        })
        #expect(await service.resolve() == container.appendingPathComponent("Documents/Lists", isDirectory: true))
    }

    @Test("Cancellation skips container lookup")
    func cancellationSkipsLookup() async {
        let service = KeywordListsRootResolutionService(resolveContainer: {
            Issue.record("Cancelled request must not enter the blocking lookup")
            return nil
        })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.resolve()
        }
        #expect(await task.value == nil)
    }

    @Test("Async resolution honors the task-local storage root")
    func resolvesTaskLocalRoot() async throws {
        let root = URL(fileURLWithPath: "/tmp/keyword-task-local", isDirectory: true)
        try await KeywordListsStoreStorageOverride.$current.withValue(root) {
            let store = KeywordListsStore()
            let resolved = try await store.resolveURL(for: .structured)
            #expect(resolved == root.appendingPathComponent("structured/keywords.txt"))
            #expect(store.currentURL(for: .structured) == resolved)
        }
    }
}

private actor KeywordRootResolutionGate {
    private var continuation: CheckedContinuation<URL?, Never>?
    private var entered = false

    func resolve() async -> URL? {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !entered {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func resume(with root: URL?) { continuation?.resume(returning: root); continuation = nil }
}

@Suite("Keyword root routing publication")
struct KeywordRootRoutingPublicationTests {
    @Test("An installed route wins over a suspended container lookup")
    func installedRouteWins() async throws {
        let gate = KeywordRootResolutionGate()
        let store = KeywordListsStore(usesTestStorage: false, cloudPreference: { true },
                                     resolveCloudRoot: { await gate.resolve() })
        let lookup = Task { try await store.resolveRootURL() }
        try await gate.waitUntilEntered()
        let installed = URL(fileURLWithPath: "/tmp/installed-keyword-route", isDirectory: true)
        store.applyICloudRoutingPreference(true, resolvedRoot: installed)
        await gate.resume(with: URL(fileURLWithPath: "/tmp/stale-keyword-route"))
        #expect(try await lookup.value == installed)
        #expect(store.currentRootURL == installed)
    }

    @Test("Cancellation after container resolution does not cache the result")
    func cancelledResolutionDoesNotPublish() async throws {
        let gate = KeywordRootResolutionGate()
        let store = KeywordListsStore(usesTestStorage: false, cloudPreference: { true },
                                     resolveCloudRoot: { await gate.resolve() })
        let lookup = Task { try await store.resolveRootURL() }
        try await gate.waitUntilEntered()
        lookup.cancel()
        await gate.resume(with: URL(fileURLWithPath: "/tmp/cancelled-keyword-route"))
        do {
            _ = try await lookup.value
            Issue.record("Cancelled resolution should throw")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(store.currentRootURL == store.localRootURL)
    }
}

@Suite("Keyword managed UTF-8 preservation")
struct KeywordManagedUTF8PreservationTests {
    @Test("Routing rejects damaged source or destination without changing either file",
          arguments: [true, false])
    func routingPreservesInvalidBytes(damagedSource: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let path = KeywordListKey.quick(.keywords).relativePath
        let sourceFile = source.appendingPathComponent(path)
        let destinationFile = destination.appendingPathComponent(path)
        let damaged = Data([0xff, 0xfe, 0xff])
        let valid = Data("Existing\n".utf8)
        let sourceBytes = damagedSource ? damaged : valid
        let destinationBytes = damagedSource ? valid : damaged
        try CloudCoordinatedIO.writeData(sourceBytes, to: sourceFile)
        try CloudCoordinatedIO.writeData(destinationBytes, to: destinationFile)
        #expect(throws: CocoaError.self) {
            try KeywordListsStore.reconcileTree(from: source, to: destination)
        }
        #expect(try Data(contentsOf: sourceFile) == sourceBytes)
        #expect(try Data(contentsOf: destinationFile) == destinationBytes)
    }

    @Test("Backup rejects malformed managed text without replacing an existing version")
    func backupPreservesExistingVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let directory = root.appendingPathComponent("backups")
        let destination = directory.appendingPathComponent("existing.txt")
        let damaged = Data([0xff, 0xfe, 0xff])
        try CloudCoordinatedIO.writeData(damaged, to: source)
        try CloudCoordinatedIO.writeText("Recoverable\n", to: destination)
        let service = KeywordListBackupFileService()
        await #expect(throws: CocoaError.self) {
            try await service.snapshot(sourceURL: source, directoryURL: directory,
                                       destinationURL: destination, retentionCutoff: .distantPast,
                                       minimumVersionCount: 1)
        }
        #expect(try Data(contentsOf: source) == damaged)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Recoverable\n")
    }
}
