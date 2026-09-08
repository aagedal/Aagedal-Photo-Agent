import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Text, cloud and monitor Dispatch workers")
struct TextAndCloudExecutorTests {
    @Test("Text reads retain task context and balance access after cancellation", arguments: [false, true])
    @MainActor
    func textRead(cancel: Bool) async throws {
        let url = URL(fileURLWithPath: "/virtual/text.txt")
        let queue = DispatchSerialQueue(label: "test.text.read")
        let requestID = UUID()
        let service = TextFileImportService(reader: TextFileImportReader(read: { _ in
            TextWorkerContext.check(queue, url)
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return Data("hello".utf8)
        }, startAccessing: { _ in
            TextWorkerContext.check(queue, url)
            return true
        }, stopAccessing: { _ in
            TextWorkerContext.check(queue, url)
            #expect(Task.isCancelled == cancel)
        }), filesystemQueue: queue)
        let result = try await Task(priority: .userInitiated) {
            try await TextWorkerContext.$marker.withValue(url) {
                try await service.loadText(from: url, requestID: requestID)
            }
        }.value
        if cancel {
            #expect(result == .cancelledAfterRead(requestID: requestID, sourceURL: url, byteCount: 5))
        } else {
            #expect(result == .loaded(TextFileImportSnapshot(
                requestID: requestID, sourceURL: url, text: "hello", byteCount: 5
            )))
        }
    }

    @Test("Bundle lookup and reads share a worker and preserve cancellation evidence", arguments: [false, true])
    @MainActor
    func bundleRead(cancel: Bool) async throws {
        let url = URL(fileURLWithPath: "/virtual/bundle.txt")
        let queue = DispatchSerialQueue(label: "test.bundle.read")
        let requestID = UUID()
        let service = BundleTextResourceService(access: BundleTextResourceAccess(resourceURL: { _, ext in
            TextWorkerContext.check(queue, url)
            return ext == "txt" ? url : nil
        }, read: { _ in
            TextWorkerContext.check(queue, url)
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return Data("bundle".utf8)
        }), filesystemQueue: queue)
        let result = try await Task(priority: .userInitiated) {
            try await TextWorkerContext.$marker.withValue(url) {
                try await service.loadText(resourceName: "bundle", fileExtensions: ["missing", "txt"], requestID: requestID)
            }
        }.value
        if cancel {
            #expect(result == .cancelled(requestID: requestID, completedAccessCount: 3))
        } else {
            #expect(result == .loaded(BundleTextResourceSnapshot(
                requestID: requestID, resourceName: "bundle", fileExtension: "txt", text: "bundle", byteCount: 6
            )))
        }
    }

    @Test("Text exports return durable evidence when cancellation arrives inside the write")
    @MainActor
    func exportCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("export.txt")
        let queue = DispatchSerialQueue(label: "test.text.export")
        let requestID = UUID()
        let service = TextFileExportService(writer: TextFileExportWriter { data, destination in
            TextWorkerContext.check(queue, url)
            try data.write(to: destination, options: .atomic)
            withUnsafeCurrentTask { $0?.cancel() }
        }, filesystemQueue: queue)
        let result = try await Task(priority: .userInitiated) {
            try await TextWorkerContext.$marker.withValue(url) {
                try await service.writeText("saved", to: url, requestID: requestID)
            }
        }.value
        #expect(result == .committed(TextFileExportCommit(
            requestID: requestID, destinationURL: url, byteCount: 5, cancellationRequestedAfterCommit: true
        )))
        #expect(try Data(contentsOf: url) == Data("saved".utf8))
    }

    @Test("Quick List cancellation preserves creation and stops after an existence probe", arguments: [false, true])
    @MainActor
    func quickList(cancelDuringProbe: Bool) async throws {
        let url = URL(fileURLWithPath: "/virtual/new.txt")
        let queue = DispatchSerialQueue(label: "test.quick-list.create")
        let requestID = UUID()
        let service = QuickListFileCreationService(access: QuickListFileAccess(fileExists: { _ in
            TextWorkerContext.check(queue, url)
            if cancelDuringProbe { withUnsafeCurrentTask { $0?.cancel() } }
            return false
        }, createEmptyFile: { _ in
            TextWorkerContext.check(queue, url)
            #expect(!cancelDuringProbe)
            withUnsafeCurrentTask { $0?.cancel() }
        }), filesystemQueue: queue)
        let result = try await Task(priority: .userInitiated) {
            try await TextWorkerContext.$marker.withValue(url) {
                try await service.createIfNeeded(at: url, requestID: requestID)
            }
        }.value
        if cancelDuringProbe {
            #expect(result == .cancelledBeforeCreation(requestID: requestID, destinationURL: url))
        } else {
            #expect(result == .created(QuickListFileCreationCommit(
                requestID: requestID, destinationURL: url, byteCount: 0, cancellationRequestedAfterCommit: true
            )))
        }
    }

    @Test("Code replacement bookmarks and source reads retain the worker task", arguments: [false, true])
    @MainActor
    func codeReplacement(cancel: Bool) async throws {
        let url = URL(fileURLWithPath: "/virtual/codes.txt")
        let queue = DispatchSerialQueue(label: "test.code-replacement.source")
        let requestID = UUID()
        let bytes = Data("code\tReplacement".utf8)
        let service = CodeReplacementSourceService(access: CodeReplacementSourceAccess(createBookmark: { _ in
            TextWorkerContext.check(queue, url)
            return Data("bookmark".utf8)
        }, resolveBookmark: { _ in
            Issue.record("Selection should not resolve an existing bookmark")
            return CodeReplacementBookmarkResolution(url: url, isStale: false)
        }, readData: { _ in
            TextWorkerContext.check(queue, url)
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return bytes
        }, modificationDate: { _ in
            TextWorkerContext.check(queue, url)
            #expect(!cancel)
            return .distantPast
        }), filesystemQueue: queue)
        let result = try await Task(priority: .userInitiated) {
            try await TextWorkerContext.$marker.withValue(url) {
                try await service.selectSource(url, sourceID: UUID(), bookmarkID: UUID(), timestamp: .distantPast, requestID: requestID)
            }
        }.value
        if cancel {
            #expect(result == .cancelled(CodeReplacementSourceCancellation(
                requestID: requestID, operation: .select, completedStage: .sourceRead, sourceURL: url, byteCount: bytes.count
            )))
        } else {
            guard case .loaded(let snapshot) = result else {
                Issue.record("Expected a complete code list")
                return
            }
            #expect(snapshot.list.entries.map(\.code) == ["code"])
        }
    }

    @Test("LUT reads reject bytes after cancellation on their Dispatch worker")
    @MainActor
    func lutRead() async throws {
        let url = URL(fileURLWithPath: "/virtual/look.cube")
        let queue = DispatchSerialQueue(label: "test.lut.read")
        let requestID = UUID()
        let service = ColorLUTImportService(reader: ColorLUTImportReader { _ in
            TextWorkerContext.check(queue, url)
            withUnsafeCurrentTask { $0?.cancel() }
            return Data("lut".utf8)
        }, filesystemQueue: queue)
        let result = try await Task(priority: .userInitiated) {
            try await TextWorkerContext.$marker.withValue(url) {
                try await service.loadLUT(from: url, requestID: requestID)
            }
        }.value
        #expect(result == .cancelledAfterRead(requestID: requestID, sourceURL: url, byteCount: 3))
    }

    @Test("Cloud cancellation returns attempted and failed URLs from the worker")
    @MainActor
    func cloudDownload() async {
        let url = URL(fileURLWithPath: "/virtual/person.json")
        let queue = DispatchSerialQueue(label: "test.cloud.download")
        let service = CloudDownloadService(startDownloading: { requested in
            TextWorkerContext.check(queue, url)
            #expect(requested == url)
            withUnsafeCurrentTask { $0?.cancel() }
            throw CocoaError(.fileReadUnknown)
        }, filesystemQueue: queue)
        let result = await Task(priority: .userInitiated) {
            await TextWorkerContext.$marker.withValue(url) {
                await service.requestDownloads(for: [url, url.appendingPathExtension("second")])
            }
        }.value
        #expect(result.attemptedURLs == [url])
        #expect(result.failedURLs == [url])
        #expect(result.wasCancelled)
    }

    @Test("Monitor setup retains cancellation on its Dispatch worker")
    @MainActor
    func monitorSetup() async {
        let url = URL(fileURLWithPath: "/virtual/folder")
        let queue = DispatchSerialQueue(label: "test.monitor.setup")
        let service = FolderChangeMonitorService(factory: { request in
            TextWorkerContext.check(queue, url)
            #expect(request.folderURL == url)
            withUnsafeCurrentTask { $0?.cancel() }
            return nil
        }, filesystemQueue: queue)
        let result = await Task(priority: .userInitiated) {
            await TextWorkerContext.$marker.withValue(url) {
                await service.createMonitor(FolderChangeMonitorRequest(folderURL: url, onChange: { _ in }))
            }
        }.value
        guard case .cancelledAfterSetup = result else {
            Issue.record("Expected cancellation evidence after worker setup")
            return
        }
    }
}

private nonisolated enum TextWorkerContext {
    @TaskLocal static var marker: URL?

    static func check(_ queue: DispatchSerialQueue, _ url: URL) {
        #expect(queue.isIsolatingCurrentContext() == true)
        #expect(!Thread.isMainThread)
        #expect(marker == url)
        #expect(Task.currentPriority >= .userInitiated)
    }
}
