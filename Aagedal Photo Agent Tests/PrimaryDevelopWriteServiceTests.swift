import AppKit
import Foundation
import SwiftMediaMetadata
import Testing
@testable import Aagedal_Photo_Agent

private actor PrimaryTestFailureGate {
    private var remaining = 1
    func failOnce() throws {
        if remaining > 0 { remaining -= 1; throw CocoaError(.fileWriteNoPermission) }
    }
}

private actor PrimaryTestCallCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private nonisolated final class PrimaryTestReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func arm() { lock.withLock { armed = true } }
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 10) == .success }
    func pauseIfArmed() {
        let pause = lock.withLock { if armed { armed = false; return true }; return false }
        if pause { entered.signal(); _ = release.wait(timeout: .now() + 10) }
    }
}

@Suite("Retained Primary Develop writes and recovery", .serialized)
@MainActor
struct PrimaryDevelopWriteServiceTests {
    private func fixture() throws -> (URL, URL) {
        let folder = URL(fileURLWithPath: "/private/tmp/PrimaryDevelop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("photo.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 5, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
        return (folder, image)
    }
    private func settings(_ exposure: Double) -> CameraRawSettings {
        var settings = CameraRawSettings(); settings.exposure2012 = exposure
        settings.localAdjustments = [MaskAdjustment(name: "Retained mask", geometry: EllipseMaskGeometry())]
        return settings
    }
    private func request(_ image: URL, mode: MetadataWriteMode = .writeToXMPSidecar,
                         reset: Bool = false, predecessor: PrimaryDevelopWriteRequest? = nil,
                         dependencies: [PrimaryDevelopWatermarkDependency] = []) async throws -> PrimaryDevelopWriteRequest {
        let folder = image.deletingLastPathComponent()
        let service = MetadataSidecarService()
        let current = service.loadSidecar(for: image, in: folder)
        let xmp = try await PendingMetadataWriteService.strictXMP(for: image)
        let source = try await SourceImageRevision.capture(at: image)
        let original = current?.metadata ?? xmp.metadata ?? IPTCMetadata()
        var edited = original; edited.title = "Primary result"; edited.cameraRaw = reset ? nil : settings(1.25)
        let changes = MetadataHistoryEntry.changes(from: original, to: edited, timestamp: Date())
        var history = current?.history ?? []; history.append(contentsOf: changes); history.trimToHistoryLimit()
        let record = MetadataSidecar(sourceFile: image.lastPathComponent, pendingChanges: false,
            metadata: edited, imageMetadataSnapshot: edited, history: history)
        var fields = edited.toOverwriteFields()
        if let settings = edited.cameraRaw { fields.merge(settings.developWriteFields()) { _, new in new } }
        else { fields[.crsVersion] = ""; fields[.crsHasSettings] = "" }
        let structured = StructuredWriteData(masks: edited.cameraRaw?.localAdjustments,
            editorial: .init(metadata: edited), replaceCameraRawBlock: true)
        return .init(imageURL: image, folderURL: folder, loadID: UUID(), mode: mode,
            edited: edited, previous: original, original: original, expectedRecord: current,
            expectedXMP: xmp.snapshot, sourceRevision: source, captureFailure: nil, sidecar: record,
            changes: changes, fields: fields, structured: structured, replaceDevelop: true,
            replaceOrientation: false, predecessor: predecessor, watermarkDependencies: dependencies)
    }
    private func load(_ model: MetadataViewModel, image: URL, folder: URL) async throws {
        model.loadMetadata(for: [ImageFile(url: image)], folderURL: folder)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isLoading)
        #expect(model.metadata != nil)
    }

    @Test("XMP Primary save preserves pixels and actual mask/settings receipt")
    func xmpCompletion() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: image)
        let captured = try await request(image)
        let result = await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine()).execute(captured)
        #expect(result.completed)
        #expect(!result.wroteEmbedded && result.completion?.wroteXMPSidecar == true)
        #expect(try Data(contentsOf: image) == original)
        let actual = try #require(XMPSidecarService().loadSidecar(for: image))
        #expect(actual.cameraRaw?.exposure2012 == 1.25)
        #expect(actual.cameraRaw?.localAdjustments?.count == 1)
        #expect(result.completion?.writtenXMPSnapshot?.data == (try Data(contentsOf: XMPSidecarService().sidecarURL(for: image))))
    }

    @Test("Original source and companion changes refuse physical writes", arguments: [0, 1, 2])
    func independentChanges(kind: Int) async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await request(image, mode: .writeToFileAndXMPSidecar)
        if kind == 0 { try Data("External image".utf8).write(to: image) }
        if kind == 1 { try XMPSidecarService().saveSidecar(metadata: .init(title: "External XMP"), for: image) }
        if kind == 2 { try MetadataSidecarService().saveSidecar(.init(sourceFile: image.lastPathComponent,
            pendingChanges: true, metadata: .init(title: "External JSON")), for: image, in: folder) }
        let before = try Data(contentsOf: image)
        let result = await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine()).execute(captured)
        #expect(!result.completed && !result.wroteEmbedded && !result.embeddedMayHaveBeenWritten)
        #expect(result.completion?.wroteXMPSidecar != true)
        #expect(try Data(contentsOf: image) == before)
    }

    @Test("Prephysical failure retries only the original request and its original evidence")
    func safeRetry() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await request(image)
        let gate = PrimaryTestFailureGate()
        var hooks = PrimaryDevelopWriteHooks(); hooks.beforeAdmission = { try await gate.failOnce() }
        let worker = PrimaryDevelopWriteService(engine: SwiftExifWriteEngine(), hooks: hooks)
        let first = await worker.execute(captured)
        #expect(!first.completed && !first.requiresRecovery)
        let second = await worker.execute(captured)
        #expect(second.completed && second.requestID == captured.id)
    }

    @Test("Partial XMP commit retains exact original and partial receipt for export")
    func partialReceiptExport() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try MetadataSidecarService().saveSidecar(.init(sourceFile: image.lastPathComponent,
            pendingChanges: true, metadata: .init(description: "Pending caption"), imageMetadataSnapshot: nil), for: image, in: folder)
        let captured = try await request(image)
        var hooks = PrimaryDevelopWriteHooks(); hooks.beforeJSON = { throw CocoaError(.fileWriteNoPermission) }
        let result = await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine(), hooks: hooks).execute(captured)
        #expect(!result.completed && result.requiresRecovery)
        #expect(result.completion?.wroteXMPSidecar == true)
        let payload = try JSONEncoder().encode(PrimaryDevelopRecoveryPayload(captured, result: result))
        let graph = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect((graph["expectedRecord"] as? [String: Any])?["originalSnapshotKnown"] as? Bool == false)
        #expect(((graph["edited"] as? [String: Any])?["cameraRaw"] as? [String: Any]) != nil)
        #expect(graph["writtenXMPData"] != nil)
        let entry = VariableConflictEntry(id: captured.id, imageURL: image, folderURL: folder, admissionPayload: payload)
        let snapshot = try await VariableConflictRecovery.makeSnapshot(photoURL: image, reason: "Retained Primary Develop", generation: 1, entries: [entry])
        let receipt = try await VariableConflictRecovery.export(snapshot, to: folder.appendingPathComponent("primary.json"), currentEntries: [entry], generation: 1, protectedPhotoURLs: [image])
        #expect(try await VariableConflictRecovery.verifyDiscard(snapshot, receipt: receipt, currentEntries: [entry], generation: 1, protectedPhotoURLs: [image]) == [captured.id])
    }

    @Test("Embedded plus XMP reset removes actual CRS while retaining editorial metadata")
    func dualReset() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let initial = try await request(image, mode: .writeToFileAndXMPSidecar)
        #expect(await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine()).execute(initial).completed)
        let reset = try await request(image, mode: .writeToFileAndXMPSidecar, reset: true)
        let result = await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine()).execute(reset)
        #expect(result.completed && result.wroteEmbedded)
        let physical = try #require(try await SwiftExifReadService().readBatchFullMetadata(urls: [image])[image])
        #expect(physical.cameraRaw?.exposure2012 == nil)
        #expect(physical.cameraRaw?.localAdjustments?.isEmpty != false)
        #expect(XMPSidecarService().loadSidecar(for: image)?.cameraRaw?.exposure2012 == nil)
        #expect(physical.title == "Primary result")
    }

    @Test("Rapid dual edits and delayed Undo use exact predecessor completion evidence", arguments: [0, 1, 2])
    func rapidUndo(scenario: Int) async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var initial = IPTCMetadata(); initial.cameraRaw = settings(0)
        try XMPSidecarService().saveSidecar(metadata: initial, for: image)
        let lifecycle = DevelopPrimaryLifecycleCoordinator()
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(), primaryDevelopLifecycle: lifecycle)
        try await load(model, image: image, folder: folder)
        model.editingMetadata.cameraRaw?.exposure2012 = 1
        model.markChanged()
        model.commitPrimaryDevelopEdits(mode: .writeToFileAndXMPSidecar, onComplete: { _ in })
        model.editingMetadata.cameraRaw?.exposure2012 = scenario == 1 ? 2 : 0
        model.markChanged()
        if scenario == 2 { await model.waitForPrimaryDevelopWrites() }
        model.commitPrimaryDevelopEdits(mode: .writeToFileAndXMPSidecar, onComplete: { _ in })
        if scenario == 1 {
            model.editingMetadata.cameraRaw?.exposure2012 = 1
            model.markChanged()
            #expect(model.hasUncapturedPrimaryDevelopEdits(mode: .writeToFileAndXMPSidecar))
            model.commitPrimaryDevelopEdits(mode: .writeToFileAndXMPSidecar, onComplete: { _ in })
        }
        if scenario != 2 { #expect(model.retainedPrimaryDevelopWrites.count == (scenario == 1 ? 3 : 2)) }
        await model.waitForPrimaryDevelopWrites()
        #expect(!model.hasRetainedPrimaryDevelopWrites)
        #expect(!lifecycle.hasPendingWork)
        let physical = try #require(try await SwiftExifReadService().readBatchFullMetadata(urls: [image])[image])
        #expect(physical.cameraRaw?.exposure2012 == (scenario == 1 ? 1 : 0))
        #expect(XMPSidecarService().loadSidecar(for: image)?.cameraRaw?.exposure2012 == (scenario == 1 ? 1 : 0))
    }

    @Test("Dismissal and generic save cannot lose a retained Primary edit; verified scoped export is required")
    func retainedFailureLifecycleAndDiscard() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let lifecycle = DevelopPrimaryLifecycleCoordinator()
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            primaryDevelopLifecycle: lifecycle, primaryDevelopExecutor: { request in
                .init(requestID: request.id, failure: "Injected Primary failure")
            })
        try await load(model, image: image, folder: folder)
        model.editingMetadata.cameraRaw = settings(2); model.markChanged()
        model.commitPrimaryDevelopEdits(mode: .writeToXMPSidecar, onComplete: { _ in })
        await model.waitForPrimaryDevelopWrites()
        model.saveError = nil
        #expect(model.hasRetainedPrimaryDevelopWrites && lifecycle.hasPendingWork)
        #expect(!model.hasUncapturedPrimaryDevelopEdits(mode: .writeToXMPSidecar))
        var refused = false
        do { try await lifecycle.flush() } catch { refused = true }
        #expect(refused)
        model.commitEditsReportingResult(mode: .writeToXMPSidecar) { result in
            if case .succeeded = result { Issue.record("Generic save bypassed retained Primary work") }
        }
        #expect(!FileManager.default.fileExists(atPath: XMPSidecarService().sidecarURL(for: image).path))
        let snapshot = try await model.beginPrimaryDevelopRecovery(for: image)
        let receipt = try await model.exportPrimaryDevelopRecovery(snapshot, to: folder.appendingPathComponent("retained.json"))
        refused = false
        do { try await model.discardPrimaryDevelopRecovery(snapshot, receipt: receipt) } catch { refused = true }
        #expect(refused && model.hasRetainedPrimaryDevelopWrites)
        model.registerPrimaryDevelopRecoveryEditorBarrier(owner: UUID(), handler: {})
        try await model.discardPrimaryDevelopRecovery(snapshot, receipt: receipt)
        #expect(!model.hasRetainedPrimaryDevelopWrites && !lifecycle.hasPendingWork)
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == nil)
    }
    @Test("Partial outcome never auto-retries; scoped discard preserves another photo's new editor")
    func partialRetentionAcrossSelection() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let other = folder.appendingPathComponent("other.png")
        try FileManager.default.copyItem(at: image, to: other)
        let calls = PrimaryTestCallCounter()
        let lifecycle = DevelopPrimaryLifecycleCoordinator()
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            primaryDevelopLifecycle: lifecycle, primaryDevelopExecutor: { request in
                await calls.record()
                return .init(requestID: request.id, completion: .init(installedSidecar: nil, wroteXMPSidecar: true,
                    wasCancelled: false, failure: .init(stage: .metadataSidecar, message: "Injected partial JSON failure")),
                    failure: "Injected partial JSON failure")
            })
        try await load(model, image: image, folder: folder)
        model.editingMetadata.cameraRaw = settings(1); model.markChanged()
        model.commitPrimaryDevelopEdits(mode: .writeToXMPSidecar, onComplete: { _ in })
        await model.waitForPrimaryDevelopWrites()
        let id = try #require(model.retainedPrimaryDevelopWrites.first?.id)
        try await load(model, image: other, folder: folder)
        model.editingMetadata.cameraRaw = settings(5); model.markChanged()
        do { try await model.retryPrimaryDevelopWrites() } catch { }
        #expect(await calls.count == 1)
        #expect(model.retainedPrimaryDevelopWrites.first?.id == id)
        let snapshot = try await model.beginPrimaryDevelopRecovery(for: image)
        let receipt = try await model.exportPrimaryDevelopRecovery(snapshot, to: folder.appendingPathComponent("partial.json"))
        try await model.discardPrimaryDevelopRecovery(snapshot, receipt: receipt)
        #expect(model.selectedURLs == [other])
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == 5)
        #expect(model.hasUnpersistedEditorChanges)
        #expect(!model.hasRetainedPrimaryDevelopWrites)
    }

    @Test("Recovery reload never overwrites a newer same-photo editor while its read is held")
    func recoveryReadRace() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let gate = PrimaryTestReadGate()
        let reader = MetadataEditorReadService(access: .init(read: { image, folder, embedded, reconciles in
            gate.pauseIfArmed()
            return MetadataEditorReadAccess.systemRead(imageURL: image, folderURL: folder,
                embedded: embedded, reconciles: reconciles)
        }))
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            editorReadService: reader, primaryDevelopLifecycle: DevelopPrimaryLifecycleCoordinator(),
            primaryDevelopExecutor: { .init(requestID: $0.id, failure: "Injected failure") })
        try await load(model, image: image, folder: folder)
        model.editingMetadata.cameraRaw = settings(2); model.markChanged()
        model.commitPrimaryDevelopEdits(mode: .writeToXMPSidecar, onComplete: { _ in })
        await model.waitForPrimaryDevelopWrites()
        model.registerPrimaryDevelopRecoveryEditorBarrier(owner: UUID(), handler: {})
        let snapshot = try await model.beginPrimaryDevelopRecovery(for: image)
        let receipt = try await model.exportPrimaryDevelopRecovery(snapshot, to: folder.appendingPathComponent("race.json"))
        gate.arm()
        let discard = Task { try await model.discardPrimaryDevelopRecovery(snapshot, receipt: receipt) }
        let didEnter = await Task.detached { gate.waitForEntry() }.value
        #expect(didEnter)
        model.editingMetadata.cameraRaw?.exposure2012 = 7
        model.markChanged()
        gate.release.signal()
        var refused = false
        do { try await discard.value } catch { refused = true }
        #expect(refused && model.hasRetainedPrimaryDevelopWrites)
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == 7)
        try await model.discardPrimaryDevelopRecovery(snapshot, receipt: receipt)
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == 7)
    }

    @Test("Recovery protects watermark metadata retained only by a completed ancestor")
    func protectsAncestorDependencyDestination() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let dependencyFolder = folder.appendingPathComponent("watermark", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencyFolder, withIntermediateDirectories: true)
        let metadataURL = dependencyFolder.appendingPathComponent("meta.json")
        let originalBytes = Data("{\"name\":\"Ancestor watermark\"}".utf8)
        try originalBytes.write(to: metadataURL)
        let dependency = PrimaryDevelopWatermarkDependency(id: UUID(), asset: nil, imageData: nil,
            imageURL: dependencyFolder.appendingPathComponent("image.png"), metadataURL: metadataURL,
            unavailableAtAdmission: true)
        let first = try await request(image, dependencies: [dependency])
        let child = try await request(image, predecessor: first)
        #expect(child.watermarkDependencies.isEmpty)
        let ancestry = PrimaryDevelopWriteRequest.ancestry(of: [child, first])
        #expect(ancestry.map(\.id) == [child.id, first.id])
        let payloads = ancestry.map { PrimaryDevelopRecoveryPayload($0, result: nil) }
        let graph = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payloads))
        let payload = try JSONSerialization.data(withJSONObject: ["requestAndPredecessors": graph])
        let entry = VariableConflictEntry(id: child.id, imageURL: image, folderURL: folder, admissionPayload: payload)
        let snapshot = try await VariableConflictRecovery.makeSnapshot(photoURL: image, reason: "Primary recovery", generation: 1, entries: [entry])
        var refused = false
        do {
            _ = try await VariableConflictRecovery.export(snapshot, to: metadataURL,
                currentEntries: [entry], generation: 1,
                protectedPhotoURLs: PrimaryDevelopWriteRequest.protectedURLs(for: [child]))
        } catch { refused = true }
        #expect(refused)
        #expect(try Data(contentsOf: metadataURL) == originalBytes)
    }

    @Test("Explicit same-value XMP then dual save still writes the embedded destination")
    func sameValueDifferentDestination() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            primaryDevelopLifecycle: DevelopPrimaryLifecycleCoordinator())
        try await load(model, image: image, folder: folder)
        model.editingMetadata.cameraRaw = settings(1)
        model.markChanged()
        model.commitPrimaryDevelopEdits(mode: .writeToXMPSidecar, onComplete: { _ in })
        #expect(!model.hasUncapturedPrimaryDevelopEdits(mode: .writeToFileAndXMPSidecar))
        model.commitPrimaryDevelopEdits(mode: .writeToFileAndXMPSidecar, onComplete: { _ in })
        #expect(model.retainedPrimaryDevelopWrites.count == 2)
        #expect(model.retainedPrimaryDevelopWrites.last?.replaceDevelop == true)
        await model.waitForPrimaryDevelopWrites()
        #expect(!model.hasRetainedPrimaryDevelopWrites)
        let physical = try #require(try await SwiftExifReadService().readBatchFullMetadata(urls: [image])[image])
        #expect(physical.cameraRaw?.exposure2012 == 1)
        #expect(physical.cameraRaw?.localAdjustments?.count == 1)
        #expect(XMPSidecarService().loadSidecar(for: image)?.cameraRaw?.exposure2012 == 1)
    }

}
