import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("MetadataIOCoordinator")
struct MetadataIOCoordinatorTests {

    /// Observes critical-section behavior: a non-atomic read-modify-write split across a
    /// suspension point (to detect lost updates) plus live concurrency tracking.
    private actor Probe {
        private(set) var counter = 0
        private var current = 0
        private(set) var maxConcurrent = 0

        func read() -> Int { counter }
        func write(_ value: Int) { counter = value }

        func enter() { current += 1; maxConcurrent = max(maxConcurrent, current) }
        func leave() { current -= 1 }
    }

    @Test("same key serializes read-modify-write — no lost updates")
    func sameKeyNoLostUpdates() async {
        let coordinator = MetadataIOCoordinator()
        let probe = Probe()
        let iterations = 200

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    await coordinator.withLock("same-photo") {
                        // Read, suspend (forcing interleaving if unserialized), then write back.
                        // Without per-key serialization this loses the vast majority of updates.
                        let value = await probe.read()
                        await Task.yield()
                        await probe.write(value + 1)
                    }
                }
            }
        }

        #expect(await probe.counter == iterations)
    }

    @Test("same key never runs two operations at once")
    func sameKeyNeverOverlaps() async {
        let coordinator = MetadataIOCoordinator()
        let probe = Probe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await coordinator.withLock("solo") {
                        await probe.enter()
                        try? await Task.sleep(for: .milliseconds(5))
                        await probe.leave()
                    }
                }
            }
        }

        #expect(await probe.maxConcurrent == 1)
    }

    @Test("different keys run concurrently")
    func differentKeysRunConcurrently() async {
        let coordinator = MetadataIOCoordinator()
        let probe = Probe()
        let keys = 8

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<keys {
                group.addTask {
                    await coordinator.withLock("photo-\(index)") {
                        await probe.enter()
                        try? await Task.sleep(for: .milliseconds(50))
                        await probe.leave()
                    }
                }
            }
        }

        // Distinct keys must be able to overlap; otherwise batch folder reads would serialize.
        #expect(await probe.maxConcurrent > 1)
    }

    @Test("returns the body's value and propagates thrown errors")
    func resultAndErrorPropagation() async {
        let coordinator = MetadataIOCoordinator()

        let value = await coordinator.withLock("k") { 42 }
        #expect(value == 42)

        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await coordinator.withLock("k") { throw Boom() }
        }
    }

    @Test("a failing operation does not break serialization for later ops on the same key")
    func failureDoesNotPoisonChain() async {
        let coordinator = MetadataIOCoordinator()
        let probe = Probe()

        struct Boom: Error {}
        // This op throws; it must not leave the key's chain in a broken state.
        try? await coordinator.withLock("same-photo") { throw Boom() }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await coordinator.withLock("same-photo") {
                        let value = await probe.read()
                        await Task.yield()
                        await probe.write(value + 1)
                    }
                }
            }
        }

        #expect(await probe.counter == 50)
    }

    @Test("metadata persistence returns the installed merged history record")
    func persistenceReturnsInstalledMergedRecord() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let imageURL = folder.appendingPathComponent("photo.jpg")
        try Data([0x01]).write(to: imageURL)

        let metadataService = MetadataSidecarService()
        let existingMetadata = IPTCMetadata(title: "Before", keywords: ["latest-keyword"])
        try metadataService.saveSidecar(
            MetadataSidecar(sourceFile: imageURL.lastPathComponent, metadata: existingMetadata),
            for: imageURL,
            in: folder
        )

        let editedMetadata = IPTCMetadata(title: "After", keywords: ["stale-keyword"])
        let history = MetadataHistoryEntry.changes(
            from: IPTCMetadata(title: "Before"),
            to: IPTCMetadata(title: "After"),
            timestamp: Date()
        )
        let request = MetadataSidecarPersistenceRequest(
            sidecar: MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                metadata: editedMetadata,
                history: history
            ),
            imageURL: imageURL,
            folderURL: folder
        )

        let result = await MetadataSidecarPersistenceService()
            .persistHistoryAndMirrorXMP(request)

        #expect(result.completed)
        #expect(result.failure == nil)
        #expect(result.installedSidecar?.metadata.title == "After")
        #expect(result.installedSidecar?.metadata.keywords == ["latest-keyword"])
        #expect(result.installedSidecar?.history.count == history.count)
        #expect(XMPSidecarService().loadSidecar(for: imageURL)?.title == "After")
    }

    @Test("pre-cancelled metadata persistence performs no filesystem mutation")
    func preCancelledPersistenceDoesNotWrite() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-persistence-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let imageURL = folder.appendingPathComponent("cancelled.jpg")
        let request = MetadataSidecarPersistenceRequest(
            sidecar: MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                metadata: IPTCMetadata(title: "Must not persist")
            ),
            imageURL: imageURL,
            folderURL: folder
        )
        let service = MetadataSidecarPersistenceService()

        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.persistHistoryAndMirrorXMP(request)
        }.value

        #expect(result.wasCancelled)
        #expect(result.installedSidecar == nil)
        #expect(!result.wroteXMPSidecar)
        #expect(result.failure == nil)
        #expect(!FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(MetadataSidecarService.sidecarDirectoryName).path
        ))
        #expect(!XMPSidecarService().sidecarExists(for: imageURL))
    }

    @Test("XMP failure reports durable JSON partial success")
    func xmpFailureReportsPartialSuccess() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-persistence-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let imageURL = folder.appendingPathComponent("partial.jpg")
        let xmpURL = XMPSidecarService().sidecarURL(for: imageURL)
        try FileManager.default.createDirectory(at: xmpURL, withIntermediateDirectories: true)
        let request = MetadataSidecarPersistenceRequest(
            sidecar: MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                metadata: IPTCMetadata(title: "Durable history")
            ),
            imageURL: imageURL,
            folderURL: folder
        )

        let result = await MetadataSidecarPersistenceService()
            .persistHistoryAndMirrorXMP(request)

        #expect(!result.completed)
        #expect(!result.wasCancelled)
        #expect(result.installedSidecar?.metadata.title == "Durable history")
        #expect(!result.wroteXMPSidecar)
        #expect(result.failure?.stage == .xmpSidecar)
        #expect(MetadataSidecarService().loadSidecar(for: imageURL, in: folder)?.metadata.title == "Durable history")
    }
}
