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
}
