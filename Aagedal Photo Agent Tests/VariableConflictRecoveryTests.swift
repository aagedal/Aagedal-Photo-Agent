import AppKit
import Foundation
import SwiftMediaMetadata
import Testing
@testable import Aagedal_Photo_Agent

private nonisolated final class VariableRecoveryUncertainWriter: MetadataWriteEngine, PendingMetadataWriting, @unchecked Sendable {
    func writePendingMetadata(_ metadata: IPTCMetadata, to url: URL,
        validatePreparedIntent: @escaping @Sendable () async throws -> Void) async throws -> PendingMetadataPhysicalReceipt {
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: url)) {
            try await validatePreparedIntent()
            throw MetadataFieldMutationPhysicalError(message: "Injected unverified write", mayHaveWritten: true)
        }
    }
    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws { throw CocoaError(.featureUnsupported) }
    func writeFieldsToRenderedFiles(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws { throw CocoaError(.featureUnsupported) }
    func addRemoveListValues(add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]], to urls: [URL]) async throws { throw CocoaError(.featureUnsupported) }
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws { throw CocoaError(.featureUnsupported) }
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws { throw CocoaError(.featureUnsupported) }
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws { throw CocoaError(.featureUnsupported) }
    func stripIPTCAndXMP(from urls: [URL]) async throws { throw CocoaError(.featureUnsupported) }
    func copyMetadataToRenderedFile(from source: URL, to destination: URL, bakedCameraRaw: CameraRawSettings?) async throws { throw CocoaError(.featureUnsupported) }
}

private actor VariableRecoveryGate {
    private var entered = false
    private var admission: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        for continuation in admission { continuation.resume() }
        admission = []
        await withCheckedContinuation { releaseContinuation = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { admission.append($0) }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

@Suite("Variable conflict private export and verification", .serialized)
struct VariableConflictRecoveryTests {
    private func fixture() throws -> (URL, URL) {
        let folder = URL(fileURLWithPath: "/private/tmp/VariableRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("photo.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
        return (folder, image)
    }
    private func admission(_ image: URL, payload: String = "Captured editor") throws -> VariableConflictEntry {
        let data = try JSONSerialization.data(withJSONObject: ["editor": payload, "sequenceIndex": 3,
            "frozenMode": "historyOnly", "firstReadKnown": false])
        return .init(id: UUID(), imageURL: image, folderURL: image.deletingLastPathComponent(), admissionPayload: data)
    }
    private func request(_ image: URL, mode: MetadataWriteMode = .historyOnly,
                         manyFields: Bool = false, knownOriginal: Bool = false) async throws -> VariableMetadataWriteRequest {
        var original = IPTCMetadata(title: "Unresolved")
        original.exifOrientation = 6
        var technical = CameraRawSettings(); technical.exposure2012 = 1.5
        original.cameraRaw = technical
        var resolved = original; resolved.title = "Resolved"
        if manyFields {
            let fields: [WritableKeyPath<IPTCMetadata, String?>] = [\.description, \.extendedDescription,
                \.creatorJobTitle, \.descriptionWriter, \.credit, \.copyright, \.rightsUsageTerms,
                \.webStatementOfRights, \.digitalImageGUID, \.imageSupplierImageID, \.jobId,
                \.city, \.sublocation, \.provinceState, \.country, \.event, \.instructions, \.source]
            for (index, field) in fields.enumerated() { resolved[keyPath: field] = "Value \(index)" }
            resolved.countryCode = "NOR"; resolved.dateCreated = "2026-09-11T12:34:56+02:00"
        }
        let folder = image.deletingLastPathComponent()
        let baseline = MetadataSidecar(sourceFile: image.lastPathComponent, pendingChanges: true,
            metadata: original, imageMetadataSnapshot: knownOriginal ? original : nil)
        try MetadataSidecarService().saveSidecar(baseline, for: image, in: folder)
        let saved = try #require(MetadataSidecarService().loadSidecar(for: image, in: folder))
        let evidence = MetadataSidecarReplayCreationEvidence(sourceRevision: try await SourceImageRevision.capture(at: image), xmpData: nil)
        return try #require(try VariableMetadataWriteRequest.capture(original: original, resolved: resolved,
            baselineSidecar: saved, imageURL: image, folderURL: folder, requestedMode: mode,
            creationEvidence: evidence, timestamp: Date(timeIntervalSinceReferenceDate: 900_000_000.123456)))
    }
    private func worker(engine: any MetadataWriteEngine = SwiftExifWriteEngine(), hooks: VariableMetadataWriteHooks = .init()) -> VariableMetadataWriteService {
        .init(writeEngine: engine, readSourceFacts: { image in
            guard let metadata = try await SwiftExifReadService().readBatchFullMetadata(urls: [image])[image] else { throw CocoaError(.fileReadCorruptFile) }
            return .init(metadata: metadata, hasC2PA: false)
        }, hooks: hooks)
    }

    @Test("Before-prepare captured payload exports privately and authorizes only its exact IDs")
    func admissionExport() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let entry = try admission(image)
        let snapshot = try await VariableConflictRecovery.makeSnapshot(photoURL: image, reason: "Read failed", generation: 7, entries: [entry])
        let destination = folder.appendingPathComponent("recovery.json")
        let receipt = try await VariableConflictRecovery.export(snapshot, to: destination, currentEntries: [entry], generation: 7, protectedPhotoURLs: [image])
        #expect(snapshot.requestCount == 1 && receipt.exportURL == destination)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
        let exported = try #require((object["entries"] as? [[String: Any]])?.first)
        #expect((exported["admissionPayload"] as? [String: Any])?["editor"] as? String == "Captured editor")
        #expect(Data(base64Encoded: try #require(exported["admissionPayloadExactBytesBase64"] as? String)) == entry.admissionPayload)
        let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try await VariableConflictRecovery.verifyDiscard(snapshot, receipt: receipt, currentEntries: [entry], generation: 7, protectedPhotoURLs: [image]) == [entry.id])
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    @Test("Request export retains all pretrim deltas, precise dates, technical fields and original-known state", arguments: [false, true])
    func completeRequestPayload(knownOriginal: Bool) async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let request = try await request(image, manyFields: true, knownOriginal: knownOriginal)
        let recovery = try request.recoverySnapshot()
        #expect(recovery.fullChanges.count > 20)
        #expect(recovery.capturedSidecar.record.history.count <= 20)
        #expect(recovery.originalMetadata.orientation == 6)
        #expect(recovery.originalMetadata.cameraRaw?.exposure2012 == 1.5)
        #expect(recovery.capturedSidecar.originalSnapshotKnown == knownOriginal)
        let entry = VariableConflictEntry(id: request.id, imageURL: image, folderURL: folder, request: request)
        let snapshot = try await VariableConflictRecovery.makeSnapshot(photoURL: image, reason: "Conflict", generation: 1, entries: [entry])
        let destination = folder.appendingPathComponent("request.json")
        _ = try await VariableConflictRecovery.export(snapshot, to: destination, currentEntries: [entry], generation: 1, protectedPhotoURLs: [image])
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
        let graph = try #require(((object["entries"] as? [[String: Any]])?.first)?["request"] as? [String: Any])
        let decoded = try JSONDecoder().decode(VariableMetadataRequestRecoverySnapshot.self,
            from: JSONSerialization.data(withJSONObject: graph))
        #expect(decoded.fullChanges == request.replay.changes)
        #expect(decoded.fullChanges.first?.timestamp == Date(timeIntervalSinceReferenceDate: 900_000_000.123456))
        #expect(decoded.baselineRecordExisted)
        #expect(decoded.initialPhysicalEvidence?.sourceRevision.sha256 == request.replay.creationEvidence?.sourceRevision.sha256)
    }

    @Test("Known partial commits and uncertain physical failures remain in the settled export receipt", arguments: [false, true])
    func partialReceipts(uncertain: Bool) async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let request = try await request(image, mode: .writeToFileAndXMPSidecar)
        var hooks = VariableMetadataWriteHooks()
        hooks.physical.beforeJSONCommit = { throw CocoaError(.fileWriteNoPermission) }
        let engine: any MetadataWriteEngine
        if uncertain { engine = VariableRecoveryUncertainWriter() } else { engine = SwiftExifWriteEngine() }
        let result = await worker(engine: engine, hooks: hooks).execute(request)
        #expect(!result.completed)
        let snapshot = try request.recoverySnapshot()
        #expect(snapshot.jsonWasCommitted && snapshot.preparedSidecar != nil && snapshot.committedRecord != nil)
        #expect(snapshot.lastResult?.physicalResult?.embeddedWriteMayHaveOccurred == uncertain)
        if !uncertain {
            #expect(snapshot.lastResult?.physicalResult?.didWriteEmbedded == true)
            #expect(snapshot.lastResult?.physicalResult?.didWriteXMP == true)
            #expect(snapshot.currentPhysicalEvidence.xmpData != nil)
        }
    }

    @Test("JSON committed before failed verification exports its exact uncertain receipt")
    func unverifiedPreparation() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let request = try await request(image)
        var hooks = VariableMetadataWriteHooks()
        hooks.afterJSONCommit = { throw CocoaError(.fileReadNoPermission) }
        let result = await worker(hooks: hooks).execute(request)
        #expect(!result.completed && !request.hasVerifiedPreparedRecord)
        let recovery = try request.recoverySnapshot()
        #expect(recovery.jsonWasCommitted && recovery.committedRecord != nil)
        #expect(recovery.preparedSidecar == nil)
        #expect(recovery.lastResult?.committedButUnverifiedSidecarURL != nil)
        #expect(recovery.lastResult?.physicalResult == nil)
    }

    @Test("Tampered export, changed generation, changed payload and changed receipt all invalidate discard")
    func staleAndTampered() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let entry = try admission(image)
        let snapshot = try await VariableConflictRecovery.makeSnapshot(photoURL: image, reason: "Conflict", generation: 2, entries: [entry])
        let destination = folder.appendingPathComponent("safe.json")
        let receipt = try await VariableConflictRecovery.export(snapshot, to: destination, currentEntries: [entry], generation: 2, protectedPhotoURLs: [])
        var rejected = false
        do { _ = try await VariableConflictRecovery.verifyDiscard(snapshot, receipt: receipt, currentEntries: [entry], generation: 3, protectedPhotoURLs: []) }
        catch { rejected = true }
        #expect(rejected)
        let changed = VariableConflictEntry(id: entry.id, imageURL: image, folderURL: folder,
            admissionPayload: Data("{\"editor\":\"Newer\"}".utf8))
        rejected = false
        do { _ = try await VariableConflictRecovery.verifyDiscard(snapshot, receipt: receipt, currentEntries: [changed], generation: 2, protectedPhotoURLs: []) }
        catch { rejected = true }
        #expect(rejected)
        try Data("tampered".utf8).write(to: destination)
        rejected = false
        do { _ = try await VariableConflictRecovery.verifyDiscard(snapshot, receipt: receipt, currentEntries: [entry], generation: 2, protectedPhotoURLs: []) }
        catch { rejected = true }
        #expect(rejected)
    }

    @Test("Late request execution invalidates a previously captured receipt even if the caller generation is stale")
    func changedLiveReceipt() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let request = try await request(image)
        let entry = VariableConflictEntry(id: request.id, imageURL: image, folderURL: folder, request: request)
        let snapshot = try await VariableConflictRecovery.makeSnapshot(photoURL: image, reason: "Conflict", generation: 1, entries: [entry])
        _ = await worker().execute(request)
        var rejected = false
        do { _ = try await VariableConflictRecovery.export(snapshot, to: folder.appendingPathComponent("old.json"), currentEntries: [entry], generation: 1, protectedPhotoURLs: []) }
        catch { rejected = true }
        #expect(rejected)
    }

    @Test("Same-stem different extensions cannot enter another photo's review")
    func exactPhotoIdentity() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let sibling = folder.appendingPathComponent("photo.ARW")
        let entry = try admission(sibling)
        var rejected = false
        do { _ = try await VariableConflictRecovery.makeSnapshot(photoURL: image, reason: "Conflict", generation: 1, entries: [entry]) }
        catch { rejected = true }
        #expect(rejected)
    }

    @Test("All active folders, metadata directories, linked parents and hardlinked destinations are protected")
    func protectedDestinations() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let other = folder.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let protected = other.appendingPathComponent("active-source.json")
        let original = Data("protected source".utf8); try original.write(to: protected)
        let metadata = other.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        let hardlink = folder.appendingPathComponent("hardlink.json")
        try FileManager.default.linkItem(at: protected, to: hardlink)
        let entry = try admission(image)
        let snapshot = try await VariableConflictRecovery.makeSnapshot(photoURL: image, reason: "Conflict", generation: 1, entries: [entry])
        for destination in [protected, metadata.appendingPathComponent("photo.meta.json"), link.appendingPathComponent("export.json"), hardlink,
                            metadata.appendingPathComponent("../.photo_metadata/hidden.json")] {
            var rejected = false
            do { _ = try await VariableConflictRecovery.export(snapshot, to: destination, currentEntries: [entry], generation: 1, protectedPhotoURLs: [image, protected]) }
            catch { rejected = true }
            #expect(rejected)
        }
        #expect(try Data(contentsOf: protected) == original)
    }

    @Test("Atomic write and readback failures never produce discard receipts", arguments: [false, true])
    func exportFaults(readback: Bool) async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let entry = try admission(image)
        let snapshot = try await VariableConflictRecovery.makeSnapshot(photoURL: image, reason: "Conflict", generation: 1, entries: [entry])
        var access = CaptionConflictExportAccess()
        if readback { access.read = { _ in Data("wrong bytes".utf8) } }
        else { access.writeAtomic = { _, _ in throw CocoaError(.fileWriteNoPermission) } }
        var rejected = false
        do { _ = try await VariableConflictRecovery.export(snapshot, to: folder.appendingPathComponent("failed.json"), currentEntries: [entry], generation: 1, protectedPhotoURLs: [], access: access) }
        catch { rejected = true }
        #expect(rejected)
    }
    @Test("Running request receipt cannot be sampled before its execution settles")
    func runningRequest() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let request = try await request(image, mode: .writeToFile)
        let gate = VariableRecoveryGate()
        var hooks = VariableMetadataWriteHooks(); hooks.physical.afterAdmission = { await gate.pause() }
        let worker = worker(hooks: hooks)
        let task = Task { await worker.execute(request) }
        await gate.waitForEntry()
        var rejected = false
        do { _ = try request.recoverySnapshot() } catch { rejected = true }
        #expect(rejected)
        await gate.release()
        _ = await task.value
        #expect(try request.recoverySnapshot().lastResult != nil)
    }

    @Test("Missing or malformed admission payload cannot produce a discardable export")
    func incompleteAdmission() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        for payload in [nil, Data("not JSON".utf8)] as [Data?] {
            let entry = VariableConflictEntry(id: UUID(), imageURL: image, folderURL: folder, admissionPayload: payload)
            var rejected = false
            do { _ = try await VariableConflictRecovery.makeSnapshot(photoURL: image, reason: "Read failed", generation: 1, entries: [entry]) }
            catch { rejected = true }
            #expect(rejected)
        }
    }

}
