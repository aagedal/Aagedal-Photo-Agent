import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Import filesystem Dispatch executors")
struct ImportFilesystemExecutorTests {
    @Test("Source access and release stay on Dispatch across progress suspension")
    @MainActor
    func sourceDiscoveryContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("photo.jpg")
        try Data().write(to: image)
        let queue = DispatchSerialQueue(label: "test.import.discovery")
        let service = ImportSourceDiscoveryService(securityScopeAccess: .init(start: { _ in
            checkImportExecutor(queue, marker: root)
            return true
        }, stop: { _ in
            checkImportExecutor(queue, marker: root)
        }), filesystemQueue: queue)
        let files = try await ImportExecutorContext.$marker.withValue(root) {
            try await service.discoverFiles(at: root, progressUpdateInterval: .zero) { progress in
                #expect(ImportExecutorContext.marker == root)
                #expect(progress.discoveredFileCount == 1)
                await Task.yield()
            }
        }
        // Foundation enumeration can canonicalize macOS's /var -> /private/var alias.
        #expect(files.map { $0.resolvingSymlinksInPath() } == [image.resolvingSymlinksInPath()])
    }

    @Test("Cancellation during source access remains visible and releases the scope")
    @MainActor
    func sourceAccessCancellation() async throws {
        let root = URL(fileURLWithPath: "/virtual/import-cancelled")
        let queue = DispatchSerialQueue(label: "test.import.discovery.cancelled")
        let service = ImportSourceDiscoveryService(securityScopeAccess: .init(start: { _ in
            checkImportExecutor(queue, marker: root)
            withUnsafeCurrentTask { $0?.cancel() }
            return true
        }, stop: { _ in
            checkImportExecutor(queue, marker: root)
            #expect(Task.isCancelled)
        }), filesystemQueue: queue)
        try await Task {
            try await ImportExecutorContext.$marker.withValue(root) {
                do {
                    _ = try await service.discoverFiles(at: root)
                    Issue.record("Cancellation must stop enumeration after source access")
                } catch is CancellationError {
                    // Expected before the nonexistent source can be enumerated.
                }
            }
        }.value
    }

    @Test("Preflight probes retain task context and reject cancellation on the last collision")
    @MainActor
    func preflightCancellation() async throws {
        let root = URL(fileURLWithPath: "/virtual/import-preflight")
        let queue = DispatchSerialQueue(label: "test.import.preflight")
        let service = ImportPreflightService(findDuplicateSources: { _, _ in
            checkImportExecutor(queue, marker: root)
            return []
        }, fileExists: { _ in
            checkImportExecutor(queue, marker: root)
            withUnsafeCurrentTask { $0?.cancel() }
            return true
        }, filesystemQueue: queue)
        try await Task {
            try await ImportExecutorContext.$marker.withValue(root) {
                do {
                    _ = try await service.prepare(.init(
                        jobs: [.init(source: root, desiredPrimaryDest: root, desiredBackupDest: nil)],
                        previousImportCandidates: [], companionParentBySource: [:],
                        destinationBaseURL: root, skipPreviouslyImported: true,
                        freezeOverwriteCollisions: true
                    ))
                    Issue.record("The last collision probe must not publish cancelled evidence")
                } catch is CancellationError {
                    // Expected even though there is no next job at which to check cancellation.
                }
            }
        }.value
    }

    @Test("Capture-date fallback runs on Dispatch and retains only the completed prefix")
    @MainActor
    func captureDateCancellation() async {
        let first = URL(fileURLWithPath: "/virtual/first.jpg")
        let second = URL(fileURLWithPath: "/virtual/second.jpg")
        let queue = DispatchSerialQueue(label: "test.import.capture-date")
        let service = ImportCaptureDateScanService(captureDateReader: { url in
            checkImportExecutor(queue, marker: first)
            return url == first ? "2026:09:08 12:00:00" : nil
        }, modificationDateReader: { _ in
            checkImportExecutor(queue, marker: first)
            withUnsafeCurrentTask { $0?.cancel() }
            return .distantPast
        }, filesystemQueue: queue)
        let result = await Task {
            await ImportExecutorContext.$marker.withValue(first) {
                await service.scan([first, second])
            }
        }.value
        guard case let .cancelled(evidence) = result else {
            Issue.record("Cancelled capture-date fallback must return partial evidence")
            return
        }
        #expect(evidence.processedFileCount == 1)
        #expect(evidence.groups.flatMap(\.files) == [first])
    }

    @Test("Folder suggestions retain the completed prefix on their Dispatch executor")
    @MainActor
    func folderSuggestionsCancellation() async {
        let root = URL(fileURLWithPath: "/virtual/import-folders")
        let queue = DispatchSerialQueue(label: "test.import.suggestions")
        let service = ImportFolderSuggestionService(folderFinder: { date, _ in
            checkImportExecutor(queue, marker: root)
            if date == "2026-09-09" { withUnsafeCurrentTask { $0?.cancel() } }
            return [root.appendingPathComponent(date)]
        }, filesystemQueue: queue)
        let result = await Task {
            await ImportExecutorContext.$marker.withValue(root) {
                await service.suggestions(for: ["2026-09-08", "2026-09-09"], under: root)
            }
        }.value
        guard case let .cancelled(evidence) = result else {
            Issue.record("Cancelled folder lookup must return partial evidence")
            return
        }
        #expect(evidence.completedDateCount == 1)
        #expect(evidence.suggestions == ["2026-09-08": [root.appendingPathComponent("2026-09-08")]])
    }

    @Test("Voice-memo readers share the Dispatch task and preserve processed counts")
    @MainActor
    func voiceMemoCancellation() async {
        let image = URL(fileURLWithPath: "/virtual/photo.ARW")
        let memo = URL(fileURLWithPath: "/virtual/photo.WAV")
        let queue = DispatchSerialQueue(label: "test.import.voice-memo")
        let service = ImportVoiceMemoAssociationScanService(imageEvidenceReader: { url in
            checkImportExecutor(queue, marker: image)
            return SonyVoiceMemoImageEvidence(url: url, captureSignature: nil, capturedAt: nil)
        }, memoDateReader: { _ in
            checkImportExecutor(queue, marker: image)
            withUnsafeCurrentTask { $0?.cancel() }
            return .distantPast
        }, filesystemQueue: queue)
        let result = await Task {
            await ImportExecutorContext.$marker.withValue(image) {
                await service.scan(primaryImages: [image], primaryMemos: [memo], companionFiles: [],
                                   primaryRoot: nil, companionRoot: nil)
            }
        }.value
        guard case let .cancelled(progress) = result else {
            Issue.record("Cancelled memo read must not publish complete associations")
            return
        }
        #expect(progress.processedPrimaryImageCount == 1)
        #expect(progress.processedPrimaryMemoCount == 0)
    }

    @Test("Copy verification stays on Dispatch and cancellation preserves committed primary results",
          arguments: ["none", "primary", "backup"])
    @MainActor
    func copyVerificationAndCancellation(cancelLeg: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jpg")
        let primary = root.appendingPathComponent("primary.jpg")
        let backup = root.appendingPathComponent("backup.jpg")
        let next = root.appendingPathComponent("next.jpg")
        let contents = Data(repeating: 0xA5, count: (1 << 20) + 5)
        try contents.write(to: source)
        let queue = DispatchSerialQueue(label: "test.import.copy.\(cancelLeg)")
        let service = ImportCopyService(verificationHasher: { url in
            checkImportExecutor(queue, marker: root)
            let hash = try HashStream.hashFileSynchronously(at: url)
            if url.lastPathComponent.hasPrefix(".\(cancelLeg).jpg.") {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return hash
        }, filesystemQueue: queue)
        let collector = ImportExecutorCopyResults()
        let jobs: [ImportCopyService.CopyJob] = [
            .init(source: source, desiredPrimaryDest: primary, desiredBackupDest: backup),
            .init(source: source, desiredPrimaryDest: next, desiredBackupDest: nil),
        ]
        try await Task {
            try await ImportExecutorContext.$marker.withValue(root) {
                do {
                    let results = try await service.run(jobs: jobs, conflictPolicy: .skipExisting,
                                                       verificationMode: .on, verifyBackup: true) { result in
                        #expect(ImportExecutorContext.marker == root)
                        await collector.append(result)
                    }
                    #expect(cancelLeg == "none")
                    #expect(results.count == 2)
                } catch is CancellationError {
                    #expect(cancelLeg != "none")
                }
            }
        }.value
        let reported = await collector.results
        if cancelLeg == "primary" {
            #expect(reported.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: primary.path))
        } else {
            #expect(try Data(contentsOf: primary) == contents)
            #expect(reported.first?.isPrimaryGood == true)
            #expect(reported.first?.primaryVerification == .verified)
            if cancelLeg == "backup" {
                #expect(reported.count == 1)
                #expect(reported.first?.backup == .failed("Backup cancelled."))
            } else {
                #expect(try Data(contentsOf: backup) == contents)
                #expect(try Data(contentsOf: next) == contents)
            }
        }
        if cancelLeg != "none" {
            #expect(!FileManager.default.fileExists(atPath: backup.path))
            #expect(!FileManager.default.fileExists(atPath: next.path))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!leftovers.contains { $0.hasSuffix(".partial") })
    }
}

private nonisolated enum ImportExecutorContext {
    @TaskLocal static var marker: URL?
}

private nonisolated func checkImportExecutor(_ queue: DispatchSerialQueue, marker: URL) {
    #expect(queue.isIsolatingCurrentContext() == true)
    #expect(!Thread.isMainThread)
    #expect(ImportExecutorContext.marker == marker)
}

private actor ImportExecutorCopyResults {
    var results: [ImportCopyService.CopyResult] = []
    func append(_ result: ImportCopyService.CopyResult) { results.append(result) }
}
