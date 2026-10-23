import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Web import filesystem Dispatch executor")
@MainActor
struct WebImportFilesystemExecutorTests {
    @Test("Blocked preparation leaves MainActor responsive and preserves task context")
    func blockedPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchSerialQueue(label: "test.web-import.blocked")
        let gate = DispatchSemaphore(value: 0)
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let filesystem = WebImportFilesystemService(filesystemQueue: queue, beforeOperation: { operation in
            #expect(queue.isIsolatingCurrentContext() == true)
            #expect(!Thread.isMainThread)
            #expect(WebImportExecutorContext.marker == root)
            if operation == .prepare {
                signal.yield(())
                gate.waitBounded()
            }
        })
        let service = WebMediaImportService(download: { _, _, _, _ in
            throw CancellationError()
        }, filesystem: filesystem)
        let task = Task {
            try await WebImportExecutorContext.$marker.withValue(root) {
                try await service.importMedia(inspection: .init(url: "fixture", items: [], versions: [:]),
                    selected: [], cookies: nil, destination: root, caption: "", progress: { _ in })
            }
        }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        // This MainActor continuation must execute while the Dispatch worker is blocked.
        task.cancel()
        gate.signal()
        do { _ = try await task.value; Issue.record("Expected cancelled preparation") }
        catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Cancellation during verification retains originals and stops provenance publication")
    func cancelledVerification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchSerialQueue(label: "test.web-import.cancel")
        let filesystem = WebImportFilesystemService(filesystemQueue: queue, beforeOperation: { operation in
            #expect(queue.isIsolatingCurrentContext() == true)
            #expect(WebImportExecutorContext.marker == root)
            if operation == .workingHash { withUnsafeCurrentTask { $0?.cancel() } }
            if operation == .cleanup { #expect(Task.isCancelled) }
        })
        let task = Task {
            try await WebImportExecutorContext.$marker.withValue(root) {
                try await fixtureService(filesystem: filesystem).importMedia(
                    inspection: fixtureInspection(), selected: ["post:1"], cookies: nil,
                    destination: root, caption: "caption", progress: { _ in })
            }
        }
        do { _ = try await task.value; Issue.record("Expected cancelled verification") }
        catch is CancellationError {}
        let batch = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: batch.appendingPathComponent("Originals/001.mp4")) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: batch.appendingPathComponent("Provenance/001.mp4.json").path))
        #expect(!FileManager.default.fileExists(atPath: batch.appendingPathComponent("Working/001.xmp").path))
    }

    @Test("A corrupt working copy fails verification without changing its original")
    func verificationFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let filesystem = WebImportFilesystemService(beforeOperation: { operation in
            if operation == .workingHash {
                let batch = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
                try Data("corrupt".utf8).write(to: batch.appendingPathComponent("Working/001.mp4"))
            }
        })
        do {
            _ = try await fixtureService(filesystem: filesystem).importMedia(
                inspection: fixtureInspection(), selected: ["post:1"], cookies: nil,
                destination: root, caption: "caption", progress: { _ in })
            Issue.record("Expected working copy verification failure")
        } catch let error as WebDownloadRuntimeService.RuntimeError {
            #expect(error.localizedDescription.contains("could not be verified"))
        }
        let batch = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: batch.appendingPathComponent("Originals/001.mp4")) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: batch.appendingPathComponent("Provenance/001.mp4.json").path))
        #expect(!FileManager.default.fileExists(atPath: batch.appendingPathComponent("Working/001.xmp").path))
    }

    @Test("Provenance write failure retains verified original and working recovery material")
    func provenanceFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let filesystem = WebImportFilesystemService(beforeOperation: { operation in
            if operation == .provenanceWrite { throw CocoaError(.fileWriteNoPermission) }
        })
        do {
            _ = try await fixtureService(filesystem: filesystem).importMedia(
                inspection: fixtureInspection(), selected: ["post:1"], cookies: nil,
                destination: root, caption: "caption", progress: { _ in })
            Issue.record("Expected provenance write failure")
        } catch let error as CocoaError { #expect(error.code == .fileWriteNoPermission) }
        let batch = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: batch.appendingPathComponent("Originals/001.mp4")) == Data("original".utf8))
        #expect(try Data(contentsOf: batch.appendingPathComponent("Working/001.mp4")) == Data("original".utf8))
        #expect(XMPSidecarService().loadSidecar(for: batch.appendingPathComponent("Working/001.mp4"))?.description == "caption")
        #expect(!FileManager.default.fileExists(atPath: batch.appendingPathComponent("Provenance/001.mp4.json").path))
    }

    private func fixtureInspection() -> WebPostInspection {
        .init(url: "fixture", items: [.init(id: "post:1", position: 1, kind: "video",
            downloadURL: "https://example.com/1.mp4", width: 16, height: 16, username: "account",
            displayName: "Account", description: "post", publishedAt: "2026-10-01", postID: "post", extension: "mp4")], versions: [:])
    }

    private func fixtureService(filesystem: WebImportFilesystemService) -> WebMediaImportService {
        let inspection = fixtureInspection()
        return WebMediaImportService(download: { _, _, _, destination in
            try Data("original".utf8).write(to: destination.appendingPathComponent("001.mp4"))
            return .init(files: [.init(item: inspection.items[0], filename: "001.mp4")], versions: [:])
        }, filesystem: filesystem)
    }
}

private nonisolated enum WebImportExecutorContext {
    @TaskLocal static var marker: URL?
}
