import AppKit
import Foundation
import SwiftMediaMetadata
import Testing
@testable import Aagedal_Photo_Agent

private actor DevelopBatchTestJournal {
    private(set) var entries: [DevelopTemplateBatchExecutionResult] = []
    let failAt: Int?
    init(failAt: Int? = nil) { self.failAt = failAt }
    func retain(_ result: DevelopTemplateBatchExecutionResult) throws {
        if entries.count == failAt { throw CocoaError(.fileWriteNoPermission) }
        entries.append(result)
    }
}

private actor DevelopBatchTestCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

@Suite("Captured Develop template batch execution", .serialized)
@MainActor
struct DevelopTemplateBatchExecutionServiceTests {
    private func fixture(count: Int = 2) throws -> (URL, [URL]) {
        let folder = URL(fileURLWithPath: "/private/tmp/DevelopBatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 5, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        let photos = (0..<count).map { folder.appendingPathComponent("photo-\($0).png") }
        for photo in photos { try bytes.write(to: photo) }
        return (folder, photos)
    }

    private func request(_ photo: URL, mode: MetadataWriteMode = .writeToXMPSidecar,
                         captureFailure: String? = nil, predecessor: PrimaryDevelopWriteRequest? = nil,
                         watermarkKind: Int? = nil) async throws -> PrimaryDevelopWriteRequest {
        var edited = IPTCMetadata(title: "Captured original title")
        var settings = CameraRawSettings(); settings.exposure2012 = 1.5
        let assetID = UUID()
        if watermarkKind == 1 { settings.watermarkLayers = [WatermarkLayer(libraryAssetID: assetID)] }
        edited.cameraRaw = settings
        let original = IPTCMetadata()
        let xmp = try await PendingMetadataWriteService.strictXMP(for: photo)
        let revision = try await SourceImageRevision.capture(at: photo)
        return PrimaryDevelopWriteRequestBuilder.build(.init(imageURL: photo,
            folderURL: photo.deletingLastPathComponent(), loadID: predecessor?.loadID ?? UUID(), mode: mode,
            edited: edited, previous: original, original: original, xmpBaseline: xmp.metadata,
            embeddedBaseline: original, expectedRecord: nil, expectedXMP: xmp.snapshot,
            sourceRevision: revision, captureFailure: captureFailure, history: [], timestamp: Date(),
            predecessor: predecessor, watermarkDependencies: watermarkKind == 0 ? [.init(id: assetID,
                asset: nil, imageData: nil, imageURL: photo, metadataURL: photo.appendingPathExtension("json"),
                unavailableAtAdmission: true)] : []))
    }

    private func intent(_ photos: [URL]) async throws -> DevelopTemplateBatchIntent {
        var requests: [PrimaryDevelopWriteRequest] = []
        for photo in photos { requests.append(try await request(photo)) }
        return try .init(templateID: UUID(), templateRevision: "captured-template-revision", requests: requests)
    }

    @Test("Production writes retain the ordered original payload and verify both photos")
    func productionBatch() async throws {
        let (folder, photos) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(Array(photos.reversed()))
        let journal = DevelopBatchTestJournal()
        let result = await DevelopTemplateBatchExecutionService(engine: SwiftExifWriteEngine()).execute(captured,
            validateAuthority: { _ in }, retain: { try await journal.retain($0) })
        #expect(result.outcome == .completed && result.completedCount == 2)
        #expect(result.results.map { $0?.requestID } == captured.requests.map { Optional($0.id) })
        for photo in photos {
            #expect(XMPSidecarService().loadSidecar(for: photo)?.cameraRaw?.exposure2012 == 1.5)
        }
        let entries = await journal.entries
        #expect(entries.first?.outcome == .prepared && entries.last?.outcome == .completed)
        let runningIDs = entries.filter { $0.outcome == .running && $0.activeRequestID != nil }.compactMap(\.activeRequestID)
        #expect(runningIDs == captured.requests.map(\.id))
        let payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result.recoveryPayload)) as? [String: Any])
        let retained = try #require(payload["photos"] as? [[String: Any]])
        #expect(retained.count == 2)
        #expect(retained[0]["requestID"] as? String == captured.requests[0].id.uuidString)
        #expect(retained[0]["writtenXMPData"] != nil)
    }

    @Test("All batch reservations remain held through writes and terminal retention")
    func reservationLifetime() async throws {
        let (folder, photos) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(photos)
        let journal = DevelopBatchTestJournal()
        let worker = DevelopTemplateBatchExecutionService { request, held, validate in
            #expect(held.coversPhoto(request.imageURL))
            for photo in photos {
                #expect(throws: MCPProcessReservationError.busy) { try MCPProcessReservation.acquirePhoto(photo) }
            }
            return await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine()).execute(request, heldReservation: held, validateAuthority: validate)
        }
        let result = await worker.execute(captured, validateAuthority: { _ in }, retain: { state in
            for photo in photos {
                #expect(throws: MCPProcessReservationError.busy) { try MCPProcessReservation.acquirePhoto(photo) }
            }
            try await journal.retain(state)
        })
        #expect(result.outcome == .completed)
        for photo in photos { let lease = try MCPProcessReservation.acquirePhoto(photo); lease.release() }
    }

    @Test("A stale later destination prevents writes to the entire batch")
    func staleLaterPhoto() async throws {
        let (folder, photos) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(photos)
        try Data("external revision".utf8).write(to: photos[1])
        let counter = DevelopBatchTestCounter()
        let worker = DevelopTemplateBatchExecutionService { request, _, _ in
            await counter.record(); return .init(requestID: request.id)
        }
        let result = await worker.execute(captured, validateAuthority: { _ in }, retain: { _ in })
        #expect(result.outcome == .failed)
        #expect(await counter.count == 0)
        #expect(!FileManager.default.fileExists(atPath: XMPSidecarService().sidecarURL(for: photos[0]).path))
    }

    @Test("A failed running checkpoint never admits a physical write")
    func failedCheckpoint() async throws {
        let (folder, photos) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(photos)
        let journal = DevelopBatchTestJournal(failAt: 1)
        let counter = DevelopBatchTestCounter()
        let worker = DevelopTemplateBatchExecutionService { request, _, _ in
            await counter.record(); return .init(requestID: request.id)
        }
        let result = await worker.execute(captured, validateAuthority: { _ in }, retain: { try await journal.retain($0) })
        #expect(result.outcome == .failed && result.retentionFailure != nil)
        #expect(await counter.count == 0)
    }

    @Test("Partial first write stops the batch and retains exact physical receipt")
    func partialWrite() async throws {
        let (folder, photos) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(photos)
        var hooks = PrimaryDevelopWriteHooks(); hooks.beforeJSON = { throw CocoaError(.fileWriteNoPermission) }
        let journal = DevelopBatchTestJournal()
        let result = await DevelopTemplateBatchExecutionService(engine: SwiftExifWriteEngine(), hooks: hooks)
            .execute(captured, validateAuthority: { _ in }, retain: { try await journal.retain($0) })
        #expect(result.outcome == .recoveryRequired)
        #expect(result.results[0]?.completion?.wroteXMPSidecar == true)
        #expect(result.results[1] == nil)
        #expect(!FileManager.default.fileExists(atPath: XMPSidecarService().sidecarURL(for: photos[1]).path))
        #expect(await journal.entries.last?.outcome == .recoveryRequired)
    }

    @Test("Authority revoked during the running checkpoint prevents the first write")
    func authorityRevokedAtCheckpoint() async throws {
        let (folder, photos) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(photos)
        let revoked = DevelopBatchTestCounter()
        let calls = DevelopBatchTestCounter()
        let journal = DevelopBatchTestJournal()
        let worker = DevelopTemplateBatchExecutionService { request, _, _ in
            await calls.record(); return .init(requestID: request.id)
        }
        let result = await worker.execute(captured, validateAuthority: { _ in
            if await revoked.count > 0 { throw CocoaError(.fileReadNoPermission) }
        }, retain: { state in
            try await journal.retain(state)
            if state.activeRequestID != nil { await revoked.record() }
        })
        #expect(result.outcome == .failed)
        #expect(await calls.count == 0)
        #expect(await journal.entries.last?.outcome == .failed)
    }

    @Test("Cancellation after verified first write preserves completion and untouched destinations")
    func cancelledAfterFirst() async throws {
        let (folder, photos) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(photos)
        let journal = DevelopBatchTestJournal()
        let result = await DevelopTemplateBatchExecutionService(engine: SwiftExifWriteEngine()).execute(captured,
            validateAuthority: { _ in
                if await journal.entries.last?.completedCount == 1 { throw CancellationError() }
            }, retain: { try await journal.retain($0) })
        #expect(result.outcome == .recoveryRequired && result.completedCount == 1)
        #expect(result.results[1] == nil)
        #expect(!FileManager.default.fileExists(atPath: XMPSidecarService().sidecarURL(for: photos[1]).path))
    }

    @Test("Shared-XMP siblings and duplicate requests cannot become batch intents")
    func duplicates() async throws {
        let (folder, photos) = try fixture(count: 1); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await request(photos[0])
        #expect(throws: DevelopTemplateBatchFailure.duplicatePhoto) {
            try DevelopTemplateBatchIntent(templateID: UUID(), templateRevision: "revision", requests: [captured, captured])
        }
    }

    @Test("Watermark payloads require independent dependency admission", arguments: [0, 1])
    func watermarkRefusal(kind: Int) async throws {
        let (folder, photos) = try fixture(count: 1); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await request(photos[0], watermarkKind: kind)
        #expect(throws: DevelopTemplateBatchFailure.unsupportedWatermarkDependencies) {
            try DevelopTemplateBatchIntent(templateID: UUID(), templateRevision: "revision", requests: [captured])
        }
    }

    @Test("History-only, failed captures and edit ancestry cannot enter independent batch execution", arguments: [0, 1, 2])
    func invalidCapture(kind: Int) async throws {
        let (folder, photos) = try fixture(count: 1); defer { try? FileManager.default.removeItem(at: folder) }
        var parent: PrimaryDevelopWriteRequest?
        if kind == 2 { parent = try await request(photos[0]) }
        let captured = try await request(photos[0], mode: kind == 0 ? .historyOnly : .writeToXMPSidecar,
            captureFailure: kind == 1 ? "No decoder evidence" : nil, predecessor: parent)
        #expect(throws: DevelopTemplateBatchFailure.invalidIntent) {
            try DevelopTemplateBatchIntent(templateID: UUID(), templateRevision: "revision", requests: [captured])
        }
    }

    @Test("More than eight photos are refused before reservations or writes")
    func photoBound() async throws {
        let (folder, photos) = try fixture(count: 9); defer { try? FileManager.default.removeItem(at: folder) }
        var requests: [PrimaryDevelopWriteRequest] = []
        for photo in photos { requests.append(try await request(photo)) }
        #expect(throws: DevelopTemplateBatchFailure.invalidIntent) {
            try DevelopTemplateBatchIntent(templateID: UUID(), templateRevision: "revision", requests: requests)
        }
    }

    @Test("A different photo lease refuses direct execution without releasing the caller lease")
    func wrongHeldLease() async throws {
        let (folder, photos) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await request(photos[0])
        let lease = try MCPProcessReservation.acquirePhoto(photos[1]); defer { lease.release() }
        let result = await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine()).execute(captured, heldReservation: lease)
        #expect(!result.completed && !result.requiresRecovery)
        #expect(lease.coversPhoto(photos[1]))
        #expect(!FileManager.default.fileExists(atPath: XMPSidecarService().sidecarURL(for: photos[0]).path))
    }

    @Test("Durable checkpoints reload original ordered requests and completed receipts after restart")
    func durableCheckpointRoundTrip() async throws {
        let (folder, photos) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(Array(photos.reversed()))
        let directory = folder.appendingPathComponent("journal")
        let store = DevelopTemplateBatchCheckpointStore(directory: directory)
        let result = await DevelopTemplateBatchExecutionService(engine: SwiftExifWriteEngine()).execute(captured,
            validateAuthority: { _ in }, checkpointStore: store)
        #expect(result.outcome == .completed && result.retentionFailure == nil)
        let restarted = DevelopTemplateBatchCheckpointStore(directory: directory)
        let saved = try await restarted.load(captured.id)
        #expect(saved.outcome == .completed && saved.completedCount == 2 && !saved.needsReview)
        #expect(saved.receipts.allSatisfy { $0 != nil })
        let payload = try #require(JSONSerialization.jsonObject(with: saved.recoveryData) as? [String: Any])
        let retained = try #require(payload["photos"] as? [[String: Any]])
        #expect(retained.map { $0["requestID"] as? String } == captured.requests.map { Optional($0.id.uuidString) })
        #expect(try await restarted.allCheckpoints().count == 1)
    }

    @Test("Corrupt and newer checkpoint files are refused and preserved before writes", arguments: [false, true])
    func checkpointRefusesUnreadable(newer: Bool) async throws {
        let (folder, photos) = try fixture(count: 1); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(photos)
        let directory = folder.appendingPathComponent("journal")
        let batchDirectory = directory.appendingPathComponent(captured.id.uuidString)
        try FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = batchDirectory.appendingPathComponent("operations.json")
        let bytes = Data((newer ? "{\"formatVersion\":2}" : "broken checkpoint").utf8)
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let store = DevelopTemplateBatchCheckpointStore(directory: directory)
        let calls = DevelopBatchTestCounter()
        let worker = DevelopTemplateBatchExecutionService { request, _, _ in
            await calls.record(); return .init(requestID: request.id)
        }
        let result = await worker.execute(captured, validateAuthority: { _ in }, checkpointStore: store)
        #expect(result.outcome == .failed && result.retentionFailure != nil)
        #expect(await calls.count == 0)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Stored intent and returned physical receipts cannot be replaced or erased")
    func checkpointImmutableEvidence() async throws {
        let (folder, photos) = try fixture(count: 1); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(photos)
        let store = DevelopTemplateBatchCheckpointStore(directory: folder.appendingPathComponent("journal"))
        var state = DevelopTemplateBatchExecutionResult(intent: captured, results: [nil])
        try await store.retain(state)
        let altered = try DevelopTemplateBatchIntent(id: captured.id, templateID: captured.templateID,
            templateRevision: "different revision", requests: captured.requests)
        await #expect(throws: DevelopTemplateBatchCheckpointError.immutableIntentChanged) {
            try await store.retain(.init(intent: altered, results: [nil]))
        }
        state.outcome = .running; state.activeRequestID = captured.requests[0].id
        try await store.retain(state)
        state.activeRequestID = nil
        var receipt = PrimaryDevelopWriteResult(requestID: captured.requests[0].id)
        receipt.wroteEmbedded = true; receipt.failure = "physical failure"
        state.results[0] = receipt
        try await store.retain(state)
        state.results[0] = nil
        await #expect(throws: DevelopTemplateBatchCheckpointError.receiptChanged) { try await store.retain(state) }
        let saved = try await store.load(captured.id)
        #expect(saved.needsReview && saved.receipts[0] != nil && saved.sequence == 3)
    }

    @Test("A later source changed during running retention prevents the first write")
    func staleLaterPhotoAtRunningCheckpoint() async throws {
        let (folder, photos) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(photos)
        let calls = DevelopBatchTestCounter()
        let worker = DevelopTemplateBatchExecutionService { request, _, _ in
            await calls.record(); return .init(requestID: request.id)
        }
        let result = await worker.execute(captured, validateAuthority: { _ in }, retain: { state in
            if state.activeRequestID == captured.requests[0].id {
                try Data("external source".utf8).write(to: photos[1])
            }
        })
        let callCount = await calls.count
        #expect(result.outcome == .failed && callCount == 0)
    }

    @Test("Unexpected physical receipts remain durable recovery evidence")
    func unexpectedReceiptRetained() async throws {
        let (folder, photos) = try fixture(count: 1); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(photos)
        let reportedID = UUID()
        let store = DevelopTemplateBatchCheckpointStore(directory: folder.appendingPathComponent("journal"))
        let worker = DevelopTemplateBatchExecutionService { _, _, _ in
            var receipt = PrimaryDevelopWriteResult(requestID: reportedID)
            receipt.embeddedMayHaveBeenWritten = true
            return receipt
        }
        let result = await worker.execute(captured, validateAuthority: { _ in }, checkpointStore: store)
        #expect(result.outcome == .recoveryRequired && result.retentionFailure == nil)
        #expect(result.results[0] == nil && result.unexpectedReceipt?.reportedRequestID == reportedID)
        let saved = try await store.load(captured.id)
        let payload = try #require(JSONSerialization.jsonObject(with: saved.recoveryData) as? [String: Any])
        let unexpected = try #require(payload["unexpectedReceipt"] as? [String: Any])
        #expect(unexpected["reportedRequestID"] as? String == reportedID.uuidString)
        let evidence = try #require(unexpected["evidence"] as? [String: Any])
        #expect(evidence["embeddedMayHaveBeenWritten"] as? Bool == true)
    }

    @Test("Another store cannot reset unresolved or stronger checkpoint evidence")
    func checkpointCrossInstanceAdmission() async throws {
        let (folder, photos) = try fixture(count: 1); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(photos)
        let directory = folder.appendingPathComponent("journal")
        let first = DevelopTemplateBatchCheckpointStore(directory: directory)
        let second = DevelopTemplateBatchCheckpointStore(directory: directory)
        let prepared = DevelopTemplateBatchExecutionResult(intent: captured, results: [nil])
        try await first.retain(prepared)
        var running = prepared; running.outcome = .running; running.activeRequestID = captured.requests[0].id
        try await first.retain(running)
        await #expect(throws: DevelopTemplateBatchCheckpointError.invalidCheckpoint) { try await second.retain(prepared) }
        var erasedActive = running; erasedActive.activeRequestID = nil
        await #expect(throws: DevelopTemplateBatchCheckpointError.invalidCheckpoint) { try await second.retain(erasedActive) }
        let saved = try await second.load(captured.id)
        #expect(saved.sequence == 2 && saved.activeRequestID == captured.requests[0].id)
    }

    @Test("Checkpoint payload corruption and symlink storage are refused")
    func checkpointHashAndSymlinkRefusal() async throws {
        let (folder, photos) = try fixture(count: 1); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await intent(photos)
        let directory = folder.appendingPathComponent("journal")
        let store = DevelopTemplateBatchCheckpointStore(directory: directory)
        let prepared = DevelopTemplateBatchExecutionResult(intent: captured, results: [nil])
        try await store.retain(prepared)
        let file = directory.appendingPathComponent(captured.id.uuidString).appendingPathComponent("operations.json")
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        envelope["sha256"] = "invalid"
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)
        await #expect(throws: DevelopTemplateBatchCheckpointError.corruptCheckpoint) { try await store.load(captured.id) }
        let alias = folder.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let aliased = DevelopTemplateBatchCheckpointStore(directory: alias)
        await #expect(throws: (any Error).self) { try await aliased.retain(prepared) }
    }
}
