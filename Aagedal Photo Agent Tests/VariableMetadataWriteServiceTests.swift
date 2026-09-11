import AppKit
import Foundation
import SwiftMediaMetadata
import Testing
@testable import Aagedal_Photo_Agent

private nonisolated final class VariableWriteFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func once() throws {
        let fail = lock.withLock { if failed { return false }; failed = true; return true }
        if fail { throw CocoaError(.fileWriteNoPermission) }
    }
}

@Suite("Immutable variable metadata completion", .serialized)
struct VariableMetadataWriteServiceTests {
    private func fixture() async throws -> (URL, URL, MetadataSidecar) {
        let folder = URL(fileURLWithPath: "/private/tmp/VariableWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("photo.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
        let record = MetadataSidecar(sourceFile: image.lastPathComponent, pendingChanges: true,
            metadata: IPTCMetadata(title: "{filename}", description: "Independent pending caption"),
            imageMetadataSnapshot: nil)
        return (folder, image, try MetadataSidecarService().saveSidecar(record, for: image, in: folder))
    }
    private func json(_ image: URL) -> URL {
        image.deletingLastPathComponent().appendingPathComponent(".photo_metadata/\(image.lastPathComponent).meta.json")
    }
    private nonisolated static func read(_ image: URL) async throws -> IPTCMetadata {
        guard let record = try await SwiftExifReadService().readBatchFullMetadata(urls: [image])[image] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record
    }
    private func service(_ hooks: VariableMetadataWriteHooks = .init()) -> VariableMetadataWriteService {
        .init(writeEngine: SwiftExifWriteEngine(), readSourceFacts: {
            .init(metadata: try await Self.read($0), hasC2PA: false)
        }, hooks: hooks)
    }
    private func capture(_ image: URL, _ baseline: MetadataSidecar?, mode: MetadataWriteMode,
                         resolved: IPTCMetadata? = nil) async throws -> VariableMetadataWriteRequest {
        let original: IPTCMetadata
        if let baseline { original = baseline.metadata } else { original = try await Self.read(image) }
        var edited = resolved ?? original
        if resolved == nil { edited.title = "photo.png" }
        let revision = try await SourceImageRevision.capture(at: image)
        let xmp = try await PendingMetadataWriteService.strictXMP(for: image)
        return try #require(try VariableMetadataWriteRequest.capture(original: original, resolved: edited,
            baselineSidecar: baseline, imageURL: image, folderURL: image.deletingLastPathComponent(),
            requestedMode: mode, creationEvidence: .init(sourceRevision: revision, xmpData: xmp.snapshot.data)))
    }

    @Test("History-only interpolation is awaited JSON-only and retains nil baseline, orientation and opaque bytes")
    func historyOnly() async throws {
        let (folder, image, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let orientation = MetadataOrientationDraft(expectedOrientation: 1, targetOrientation: 6)
        let baseline = try MetadataSidecarService().saveSidecar(base, for: image, in: folder,
            orientationMutation: .replace(expected: nil, with: orientation))
        var graph = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json(image))) as? [String: Any])
        graph["opaque"] = ["keep": true]
        try JSONSerialization.data(withJSONObject: graph).write(to: json(image))
        let source = try Data(contentsOf: image)
        var xmp = XMPData(); xmp.headline = "Existing physical XMP"
        let bytes = Data(XMPWriter.generateXML(xmp).utf8)
        let xmpURL = XMPSidecarService().sidecarURL(for: image)
        try bytes.write(to: xmpURL)
        let request = try await capture(image, baseline, mode: .historyOnly)
        let result = await service().execute(request)
        #expect(result.completed && result.savedToHistory)
        #expect(result.preparedSidecar?.metadata.title == "photo.png")
        #expect(result.preparedSidecar?.imageMetadataSnapshot == nil)
        #expect(result.preparedSidecar?.orientationDraft == orientation)
        #expect(try Data(contentsOf: image) == source)
        #expect(try Data(contentsOf: xmpURL) == bytes)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json(image))) as? [String: Any])
        #expect(saved["opaque"] != nil)
    }

    @Test("Physical variable modes write the complete pending caption, not just the interpolated headline",
        arguments: [MetadataWriteMode.writeToFile, .writeToXMPSidecar, .writeToFileAndXMPSidecar])
    func physicalModes(mode: MetadataWriteMode) async throws {
        let (folder, image, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Data(contentsOf: image)
        let result = await service().execute(try await capture(image, baseline, mode: mode))
        #expect(result.completed && !result.savedToHistory)
        #expect(result.physicalResult?.installedSidecar?.pendingChanges == false)
        #expect(result.physicalResult?.installedSidecar?.imageMetadataSnapshot == nil)
        if mode.writesEmbedded {
            let actual = try await Self.read(image)
            #expect(actual.title == "photo.png")
            #expect(actual.description == "Independent pending caption")
        } else { #expect(try Data(contentsOf: image) == source) }
        if mode.writesXMPSidecar {
            let actual = try #require(XMPSidecarService().loadSidecar(for: image))
            #expect(actual.title == "photo.png" && actual.description == "Independent pending caption")
        }
    }

    @Test("A retained request retries its own partial image and XMP commits without creating new history")
    func partialRetry() async throws {
        let (folder, image, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = try await capture(image, baseline, mode: .writeToFileAndXMPSidecar)
        let gate = VariableWriteFailureGate()
        var hooks = VariableMetadataWriteHooks(); hooks.physical.beforeJSONCommit = { try gate.once() }
        let worker = service(hooks)
        let first = await worker.execute(request)
        #expect(!first.completed && first.physicalResult?.didWriteEmbedded == true && first.physicalResult?.didWriteXMP == true)
        #expect(request.hasVerifiedPreparedRecord)
        let history = try #require(first.preparedSidecar?.history)
        let retried = await worker.execute(request)
        #expect(retried.completed)
        #expect(retried.physicalResult?.installedSidecar?.history == history)
        #expect(retried.requestID == first.requestID)
    }

    @Test("A newer independent draft prevents completing a retained historical preparation")
    func newerDraftOnRetry() async throws {
        let (folder, image, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = try await capture(image, baseline, mode: .writeToFile)
        let gate = VariableWriteFailureGate()
        var hooks = VariableMetadataWriteHooks(); hooks.physical.beforeXMPCommit = { try gate.once() }
        let worker = service(hooks)
        let first = await worker.execute(request)
        var newer = try #require(first.preparedSidecar); newer.metadata.credit = "New independent credit"
        try MetadataSidecarService().saveSidecar(newer, for: image, in: folder)
        let source = try Data(contentsOf: image)
        let retry = await worker.execute(request)
        #expect(!retry.completed && retry.failure != nil)
        #expect(try Data(contentsOf: image) == source)
        #expect(MetadataSidecarService().loadSidecar(for: image, in: folder)?.metadata.credit == "New independent credit")
    }

    @Test("Preparation's commit receipt rejects newer JSON even when initial readback failed")
    func unverifiedPreparation() async throws {
        let (folder, image, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = try await capture(image, baseline, mode: .historyOnly)
        let gate = VariableWriteFailureGate()
        var hooks = VariableMetadataWriteHooks(); hooks.afterJSONCommit = { try gate.once() }
        let worker = service(hooks)
        #expect(!request.hasVerifiedPreparedRecord)
        let first = await worker.execute(request)
        #expect(!request.hasVerifiedPreparedRecord)
        #expect(first.committedButUnverifiedSidecarURL != nil && !first.completed)
        var newer = try #require(MetadataSidecarService().loadSidecar(for: image, in: folder))
        newer.metadata.credit = "Later credit"
        try MetadataSidecarService().saveSidecar(newer, for: image, in: folder)
        let retry = await worker.execute(request)
        #expect(!retry.completed)
        #expect(MetadataSidecarService().loadSidecar(for: image, in: folder)?.metadata.credit == "Later credit")
    }

    @Test("External physical changes after partial completion are never adopted as an own retry baseline")
    func physicalRetryConflict() async throws {
        let (folder, image, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = try await capture(image, baseline, mode: .writeToFileAndXMPSidecar)
        let gate = VariableWriteFailureGate()
        var hooks = VariableMetadataWriteHooks(); hooks.physical.beforeJSONCommit = { try gate.once() }
        let worker = service(hooks)
        _ = await worker.execute(request)
        let xmpURL = XMPSidecarService().sidecarURL(for: image)
        var xmp = XMPData(); xmp.headline = "External changed companion"
        let external = Data(XMPWriter.generateXML(xmp).utf8)
        try external.write(to: xmpURL)
        let result = await worker.execute(request)
        #expect(!result.completed)
        #expect(try Data(contentsOf: xmpURL) == external)
        #expect(MetadataSidecarService().loadSidecar(for: image, in: folder)?.pendingChanges == true)
    }

    @Test("Full interpolation deltas survive retained history trimming")
    func moreThanTwentyChanges() async throws {
        let (folder, image, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var resolved = baseline.metadata
        let fields: [WritableKeyPath<IPTCMetadata, String?>] = [\.title, \.description, \.extendedDescription,
            \.creatorJobTitle, \.descriptionWriter, \.credit, \.copyright, \.rightsUsageTerms,
            \.webStatementOfRights, \.digitalImageGUID, \.imageSupplierImageID, \.jobId, \.dateCreated,
            \.city, \.sublocation, \.provinceState, \.country, \.countryCode, \.event, \.instructions, \.source]
        for (index, key) in fields.enumerated() { resolved[keyPath: key] = "Resolved \(index)" }
        // Country Code is canonicalized by history replay; an arbitrary scalar is invalid.
        resolved.countryCode = "NOR"
        resolved.dateCreated = "2026-09-11T12:34:56+02:00"
        let request = try await capture(image, baseline, mode: .historyOnly, resolved: resolved)
        #expect(request.replay.changes.count > 20)
        let result = await service().execute(request)
        #expect(result.completed)
        #expect(result.preparedSidecar?.metadata == resolved)
        #expect(!FileManager.default.fileExists(atPath: XMPSidecarService().sidecarURL(for: image).path))
    }
    @Test("RAW variable completion routes frozen embedded mode to XMP without changing the source")
    func rawRouting() async throws {
        let (folder, image, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("camera.ARW")
        let source = try Data(contentsOf: image); try source.write(to: raw)
        var record = baseline; record.sourceFile = raw.lastPathComponent
        record = try MetadataSidecarService().saveSidecar(record, for: raw, in: folder)
        let request = try await capture(raw, record, mode: .writeToFile)
        let worker = VariableMetadataWriteService(writeEngine: SwiftExifWriteEngine(), readSourceFacts: { _ in
            .init(metadata: IPTCMetadata(), hasC2PA: false)
        })
        let result = await worker.execute(request)
        #expect(result.completed && result.physicalResult?.didWriteXMP == true)
        #expect(result.physicalResult?.didWriteEmbedded == false)
        #expect(try Data(contentsOf: raw) == source)
    }

    @Test("Unrepresented technical editor changes are rejected at immutable capture")
    func technicalGuard() async throws {
        let (folder, image, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var edited = baseline.metadata; edited.title = "Resolved"; edited.exifOrientation = 6
        let evidence = MetadataSidecarReplayCreationEvidence(sourceRevision: try await SourceImageRevision.capture(at: image), xmpData: nil)
        var rejected = false
        do {
            _ = try VariableMetadataWriteRequest.capture(original: baseline.metadata, resolved: edited,
                baselineSidecar: baseline, imageURL: image, folderURL: folder, requestedMode: .historyOnly,
                creationEvidence: evidence)
        } catch { rejected = true }
        #expect(rejected)
        #expect(MetadataSidecarService().loadSidecar(for: image, in: folder)?.metadata.title == "{filename}")
    }

    @Test("First physical attempt never adopts an independently newer pending field")
    func newerDraftBeforePreparation() async throws {
        let (folder, image, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = try await capture(image, baseline, mode: .writeToFile)
        var newer = baseline; newer.metadata.credit = "New independent field"
        try MetadataSidecarService().saveSidecar(newer, for: image, in: folder)
        let source = try Data(contentsOf: image)
        let jsonBytes = try Data(contentsOf: json(image))
        let result = await service().execute(request)
        #expect(!result.completed && result.failure != nil)
        #expect(result.preparedSidecar == nil)
        #expect(try Data(contentsOf: image) == source)
        #expect(try Data(contentsOf: json(image)) == jsonBytes)
    }

    @Test("Final committed-but-unverified completion retries by exact readback without another source write", arguments: [false, true])
    func finalReadbackRetry(newerDraft: Bool) async throws {
        let (folder, image, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = try await capture(image, baseline, mode: .writeToFileAndXMPSidecar)
        let gate = VariableWriteFailureGate()
        var hooks = VariableMetadataWriteHooks(); hooks.physical.afterJSONCommit = { try gate.once() }
        let worker = service(hooks)
        let first = await worker.execute(request)
        #expect(!first.completed && first.committedButUnverifiedSidecarURL != nil)
        let source = try Data(contentsOf: image)
        if newerDraft {
            var changed = try #require(MetadataSidecarService().loadSidecar(for: image, in: folder))
            changed.metadata.credit = "Newer after commit"; changed.pendingChanges = true
            try MetadataSidecarService().saveSidecar(changed, for: image, in: folder)
        }
        let retried = await worker.execute(request)
        #expect(retried.completed == !newerDraft)
        #expect(try Data(contentsOf: image) == source)
        if newerDraft {
            #expect(MetadataSidecarService().loadSidecar(for: image, in: folder)?.metadata.credit == "Newer after commit")
        } else { #expect(retried.physicalResult?.installedSidecar?.pendingChanges == false) }
    }

    @Test("Unchanged physical input does not rewrite a stale completed JSON record")
    func unchangedInputWithStaleCompletedJSON() async throws {
        let (folder, image, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var completed = baseline; completed.pendingChanges = false; completed.metadata.title = "Stale JSON B"
        completed = try MetadataSidecarService().saveSidecar(completed, for: image, in: folder)
        try await SwiftExifWriteEngine().writeFields([.headline: "Current physical C"], to: [image])
        let original = try await Self.read(image)
        let sourceBytes = try Data(contentsOf: image)
        let jsonBytes = try Data(contentsOf: json(image))
        let evidence = MetadataSidecarReplayCreationEvidence(sourceRevision: try await SourceImageRevision.capture(at: image), xmpData: nil)
        let request = try VariableMetadataWriteRequest.capture(original: original, resolved: original,
            baselineSidecar: completed, imageURL: image, folderURL: folder, requestedMode: .writeToFile,
            creationEvidence: evidence)
        #expect(request == nil)
        #expect(try Data(contentsOf: image) == sourceBytes)
        #expect(try Data(contentsOf: json(image)) == jsonBytes)
    }

    @Test("A real transformation matching saved JSON prepares without invented history and retries unverified JSON",
        arguments: [MetadataWriteMode.historyOnly, .writeToFile], [false, true])
    func transformedInputAlreadyMatchesJSON(mode: MetadataWriteMode, failPreparationReadback: Bool) async throws {
        let (folder, image, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await SwiftExifWriteEngine().writeFields([.headline: "{filename}"], to: [image])
        let original = try await Self.read(image)
        var resolved = original; resolved.title = "photo.png"
        let history = [MetadataHistoryEntry(timestamp: Date(), fieldName: "Earlier audit", oldValue: nil, newValue: "Retain")]
        let completed = MetadataSidecar(sourceFile: image.lastPathComponent, pendingChanges: false,
            metadata: resolved, imageMetadataSnapshot: nil, history: history)
        try MetadataSidecarService().saveSidecar(completed, for: image, in: folder)
        let baseline = try #require(MetadataSidecarService().loadSidecar(for: image, in: folder))
        let evidence = MetadataSidecarReplayCreationEvidence(sourceRevision: try await SourceImageRevision.capture(at: image), xmpData: nil)
        let request = try #require(try VariableMetadataWriteRequest.capture(original: original, resolved: resolved,
            baselineSidecar: baseline, imageURL: image, folderURL: folder, requestedMode: mode,
            creationEvidence: evidence))
        #expect(request.replay.changes.isEmpty)
        let gate = VariableWriteFailureGate()
        var hooks = VariableMetadataWriteHooks()
        if failPreparationReadback { hooks.afterJSONCommit = { try gate.once() } }
        let worker = service(hooks)
        var result = await worker.execute(request)
        if failPreparationReadback {
            #expect(!result.completed && result.committedButUnverifiedSidecarURL != nil)
            #expect(!request.hasVerifiedPreparedRecord)
            result = await worker.execute(request)
        }
        #expect(result.completed)
        let final = try #require(MetadataSidecarService().loadSidecar(for: image, in: folder))
        #expect(final.history == baseline.history)
        #expect(final.imageMetadataSnapshot == nil)
        #expect(final.metadata.title == "photo.png")
        #expect(final.pendingChanges == (mode == .historyOnly))
        #expect(try await Self.read(image).title == (mode == .historyOnly ? "{filename}" : "photo.png"))
        #expect(!FileManager.default.fileExists(atPath: XMPSidecarService().sidecarURL(for: image).path))
    }

    @Test("Invalid canonical country values fail closed without partially saving variable deltas")
    func invalidCountryRemainsUncommitted() async throws {
        let (folder, image, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var resolved = baseline.metadata
        resolved.title = "Resolved headline"; resolved.countryCode = "not a country code"
        let request = try await capture(image, baseline, mode: .historyOnly, resolved: resolved)
        let sourceBytes = try Data(contentsOf: image)
        let jsonBytes = try Data(contentsOf: json(image))
        let result = await service().execute(request)
        #expect(!result.completed && result.failure != nil)
        #expect(!request.hasVerifiedPreparedRecord)
        #expect(try Data(contentsOf: image) == sourceBytes)
        #expect(try Data(contentsOf: json(image)) == jsonBytes)
    }

}
