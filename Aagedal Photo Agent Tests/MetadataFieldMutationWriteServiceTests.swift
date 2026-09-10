import AppKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Verified field mutation writes", .serialized)
struct MetadataFieldMutationWriteServiceTests {
    private func fixture() async throws -> (URL, URL, IPTCMetadata) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FieldMutation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("photo.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
        try await SwiftExifWriteEngine().writeFields([.headline: "Embedded A", .description: "Original caption"], to: [image])
        let metadata = try await read(image)
        return (folder, image, metadata)
    }
    private nonisolated func read(_ image: URL) async throws -> IPTCMetadata {
        guard let value = try await SwiftExifReadService().readBatchFullMetadata(urls: [image])[image] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
    private func worker(hooks: MetadataFieldMutationWriteHooks = .init(), engine: any MetadataWriteEngine = SwiftExifWriteEngine()) -> MetadataFieldMutationWriteService {
        .init(writeEngine: engine, readEmbedded: { try await read($0) }, hooks: hooks)
    }
    private func request(_ image: URL, mode: MetadataWriteMode = .writeToFile, mutation: MetadataPhysicalFieldMutation) -> MetadataFieldMutationWriteRequest {
        .init(imageURL: image, folderURL: image.deletingLastPathComponent(), requestedMode: mode, mutation: mutation)
    }
    private func json(_ image: URL) -> URL {
        image.deletingLastPathComponent().appendingPathComponent(".photo_metadata/\(image.lastPathComponent).meta.json")
    }

    @Test("Rating and label success preserve unrelated pending captions and absent original snapshots", arguments: [false, true], [false, true])
    func unrelatedPending(nilSnapshot: Bool, label: Bool) async throws {
        let (folder, image, embedded) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var draft = embedded
        draft.title = "Pending B"
        let sidecar = MetadataSidecar(sourceFile: image.lastPathComponent, pendingChanges: true,
            metadata: draft, imageMetadataSnapshot: nilSnapshot ? nil : embedded)
        try MetadataSidecarService().saveSidecar(sidecar, for: image, in: folder)
        var graph = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json(image))) as? [String: Any])
        graph["futureExtension"] = ["opaque": "keep"]
        try JSONSerialization.data(withJSONObject: graph).write(to: json(image))
        let result = await worker().write(request(image, mutation: label ? .label(ColorLabel.red.xmpLabelValue) : .rating(4)))
        #expect(result.completed)
        #expect(result.didWriteEmbedded)
        #expect(result.installedSidecar?.metadata.title == "Pending B")
        #expect(result.installedSidecar?.pendingChanges == true)
        #expect(result.installedSidecar?.imageMetadataSnapshot?.title == (nilSnapshot ? nil : "Embedded A"))
        let actual = try await read(image)
        #expect(actual.title == "Embedded A")
        #expect(label ? actual.label == ColorLabel.red.xmpLabelValue : actual.rating == 4)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json(image))) as? [String: Any])
        #expect((saved["futureExtension"] as? [String: String])?["opaque"] == "keep")
    }

    @Test("A sole completed field updates its snapshot and clears only proven pending state")
    func soleFieldCompletion() async throws {
        let (folder, image, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = await worker().write(request(image, mutation: .rating(3)))
        #expect(result.completed)
        #expect(result.installedSidecar?.pendingChanges == false)
        #expect(result.installedSidecar?.imageMetadataSnapshot?.rating == 3)
        #expect(result.installedSidecar?.metadata.rating == 3)
    }

    @Test("Person append preserves each destination and does not embed pending additions or removals")
    func physicalPersonsStayIndependent() async throws {
        let (folder, image, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await SwiftExifWriteEngine().addRemoveListValues(add: [.personInImage: ["Source Only", "Existing, Exact"]], remove: [:], to: [image])
        let embedded = try await read(image)
        var draft = embedded
        draft.personShown = ["Pending Only", "Existing, Exact"]
        try MetadataSidecarService().saveSidecar(.init(sourceFile: image.lastPathComponent, pendingChanges: true,
            metadata: draft, imageMetadataSnapshot: embedded), for: image, in: folder)
        let result = await worker().write(request(image, mutation: .addPersons(["Added; Exact", "existing, exact"])))
        #expect(result.completed)
        #expect(try await read(image).personShown == ["Source Only", "Existing, Exact", "Added; Exact"])
        #expect(result.installedSidecar?.metadata.personShown == ["Pending Only", "Existing, Exact", "Added; Exact"])
        #expect(result.installedSidecar?.imageMetadataSnapshot?.personShown == ["Source Only", "Existing, Exact", "Added; Exact"])
        #expect(result.installedSidecar?.pendingChanges == true)
    }

    @Test("An unchanged draft value still repairs the physical destination")
    func noDeltaRepair() async throws {
        let (folder, image, embedded) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var draft = embedded; draft.rating = 5
        try MetadataSidecarService().saveSidecar(.init(sourceFile: image.lastPathComponent, pendingChanges: true,
            metadata: draft, imageMetadataSnapshot: embedded), for: image, in: folder)
        let result = await worker().write(request(image, mutation: .rating(5)))
        #expect(result.completed)
        #expect(result.didWriteEmbedded)
        #expect(try await read(image).rating == 5)
        #expect(result.installedSidecar?.pendingChanges == false)
    }

    @Test("Newer JSON before engine admission prevents a stale physical write")
    func newerIntentBeforeWrite() async throws {
        let (folder, image, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: image)
        let hooks = MetadataFieldMutationWriteHooks(afterPrepare: {
            _ = try await MetadataSidecarService().updateMetadataSerialized(for: image, in: folder,
                fallback: .init(), pendingChanges: true) { $0.rating = 2; $0.credit = "Newer writer" }
        })
        let result = await worker(hooks: hooks).write(request(image, mutation: .rating(5)))
        #expect(result.failure?.kind == .conflict)
        #expect(!result.didWriteEmbedded)
        #expect(try Data(contentsOf: image) == before)
        let saved = try #require(MetadataSidecarService().loadSidecar(for: image, in: folder))
        #expect(saved.metadata.rating == 2)
        #expect(saved.metadata.credit == "Newer writer")
        #expect(saved.pendingChanges)
    }

    @Test("Newer metadata after an embedded commit survives without stale XMP mirroring", arguments: [false, true])
    func conflictAfterEmbedded(sameField: Bool) async throws {
        let (folder, image, embedded) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let xmp = XMPSidecarService()
        try xmp.saveSidecar(metadata: embedded, for: image)
        let xmpBefore = try Data(contentsOf: xmp.sidecarURL(for: image))
        let hooks = MetadataFieldMutationWriteHooks(afterEmbeddedWrite: {
            _ = try await MetadataSidecarService().updateMetadataSerialized(for: image, in: folder,
                fallback: embedded, pendingChanges: true) { metadata in
                    if sameField { metadata.rating = 2 } else { metadata.credit = "Independent" }
                }
        })
        let result = await worker(hooks: hooks).write(request(image, mode: .writeToFileAndXMPSidecar, mutation: .rating(5)))
        #expect(result.didWriteEmbedded)
        #expect(!result.didWriteXMP)
        #expect(result.failure?.kind == .conflict)
        #expect(try await read(image).rating == 5)
        #expect(try Data(contentsOf: xmp.sidecarURL(for: image)) == xmpBefore)
        let saved = try #require(MetadataSidecarService().loadSidecar(for: image, in: folder))
        #expect(saved.pendingChanges)
        #expect(sameField ? saved.metadata.rating == 2 : saved.metadata.credit == "Independent")
    }

    @Test("An admitted engine error reports possible physical commit and never acknowledges pending")
    func ambiguousEmbeddedFailure() async throws {
        let (folder, image, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = await worker(engine: ThrowAfterFieldCommitWriter()).write(request(image, mutation: .rating(4)))
        #expect(!result.completed)
        #expect(result.embeddedWriteMayHaveOccurred)
        #expect(result.installedSidecar?.pendingChanges == true)
        #expect(try await read(image).rating == 4)
    }

    @Test("XMP failure leaves pending intent and all unrelated physical values intact")
    func xmpFailure() async throws {
        let (folder, image, embedded) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceBefore = try Data(contentsOf: image)
        try XMPSidecarService().saveSidecar(metadata: embedded, for: image)
        let xmpURL = XMPSidecarService().sidecarURL(for: image)
        let xmpBefore = try Data(contentsOf: xmpURL)
        let hooks = MetadataFieldMutationWriteHooks(beforeXMPWrite: { throw CocoaError(.fileWriteNoPermission) })
        let result = await worker(hooks: hooks).write(request(image, mode: .writeToXMPSidecar, mutation: .label("Blue")))
        #expect(result.failure != nil)
        #expect(result.installedSidecar?.pendingChanges == true)
        #expect(try Data(contentsOf: image) == sourceBefore)
        #expect(try Data(contentsOf: xmpURL) == xmpBefore)
    }

    @Test("XMP rating clear is explicit zero; unsupported effective label clear stays pending")
    func xmpClearSemantics() async throws {
        let (folder, image, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await SwiftExifWriteEngine().writeFields([.rating: "5", .label: "Red"], to: [image])
        let beforeRating = try await read(image)
        try #require(beforeRating.label == ColorLabel.red.xmpLabelValue)
        let first = await worker().write(request(image, mode: .writeToXMPSidecar, mutation: .rating(nil)))
        #expect(first.completed)
        #expect(XMPSidecarService().loadSidecar(for: image)?.rating == 0)
        let beforeClear = try await read(image)
        try #require(beforeClear.label == ColorLabel.red.xmpLabelValue)
        let second = await worker().write(request(image, mode: .writeToXMPSidecar, mutation: .label(nil)))
        #expect(!second.completed)
        #expect(second.failure?.message.contains("falls back") == true || second.failure?.message.contains("fall back") == true)
        #expect(second.installedSidecar?.pendingChanges == true)
        #expect(second.installedSidecar?.metadata.label == nil)
        #expect(try await read(image).label == ColorLabel.red.xmpLabelValue)
    }

    @Test("XMP field mutation preserves opaque Develop, localized title and unrelated names")
    func xmpPreservation() async throws {
        let (folder, image, embedded) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var xmp = embedded
        xmp.personShown = ["XMP Only"]
        xmp.localizedTitles = [.init(languageTag: "x-default", value: "Localized title")]
        var crs = CameraRawSettings(); crs.exposure2012 = 1.5
        xmp.cameraRaw = crs; xmp.exifOrientation = 6
        try XMPSidecarService().saveSidecar(metadata: xmp, for: image)
        let before = try Data(contentsOf: image)
        let result = await worker().write(request(image, mode: .writeToXMPSidecar, mutation: .addPersons(["Added"])))
        #expect(result.completed)
        let actual = try #require(XMPSidecarService().loadSidecar(for: image))
        #expect(actual.personShown == ["XMP Only", "Added"])
        #expect(actual.title == "Embedded A")
        #expect(actual.localizedTitles == xmp.localizedTitles)
        #expect(actual.cameraRaw?.exposure2012 == 1.5)
        #expect(actual.exifOrientation == 6)
        #expect(try Data(contentsOf: image) == before)
    }

    @Test("RAW embedded requests resolve to XMP and history-only creates no physical write")
    func targetModes() async throws {
        let (folder, image, embedded) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("raw.ARW")
        try Data("opaque RAW".utf8).write(to: raw)
        let service = MetadataFieldMutationWriteService(writeEngine: SwiftExifWriteEngine(), readEmbedded: { _ in embedded })
        let rawBefore = try Data(contentsOf: raw)
        let result = await service.write(request(raw, mode: .writeToFileAndXMPSidecar, mutation: .rating(3)))
        #expect(result.completed)
        #expect(!result.didWriteEmbedded)
        #expect(result.didWriteXMP)
        #expect(try Data(contentsOf: raw) == rawBefore)
        let imageBefore = try Data(contentsOf: image)
        let history = await worker().write(request(image, mode: .historyOnly, mutation: .rating(2)))
        #expect(history.completed)
        #expect(history.installedSidecar?.pendingChanges == true)
        #expect(!history.didWriteEmbedded && !history.didWriteXMP)
        #expect(try Data(contentsOf: image) == imageBefore)
    }

    @Test("Cancellation after embedded write reports that commit and leaves intent pending")
    func cancellationAfterCommit() async throws {
        let (folder, image, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let hooks = MetadataFieldMutationWriteHooks(afterEmbeddedWrite: { throw CancellationError() })
        let result = await worker(hooks: hooks).write(request(image, mode: .writeToFileAndXMPSidecar, mutation: .rating(2)))
        #expect(result.wasCancelled)
        #expect(result.didWriteEmbedded)
        #expect(!result.didWriteXMP)
        #expect(result.installedSidecar?.pendingChanges == true)
        #expect(try await read(image).rating == 2)
    }
}

private nonisolated final class ThrowAfterFieldCommitWriter: MetadataWriteEngine, MetadataFieldMutationWriting {
    private let cancelled: Bool
    private let commits: Bool
    init(cancelled: Bool = false, commits: Bool = true) {
        self.cancelled = cancelled; self.commits = commits
    }
    func writeFieldMutation(_ mutation: MetadataPhysicalFieldMutation, to url: URL,
        validatePreparedIntent: @escaping @Sendable () async throws -> Void) async throws -> MetadataFieldMutationPhysicalReceipt {
        if commits {
            _ = try await SwiftExifWriteEngine().writeFieldMutation(mutation, to: url, validatePreparedIntent: validatePreparedIntent)
        }
        throw MetadataFieldMutationPhysicalError(message: "Injected physical operation failure",
            mayHaveWritten: commits, wasCancelled: cancelled)
    }
    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {}
    func writeFieldsToRenderedFiles(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {}
    func addRemoveListValues(add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]], to urls: [URL]) async throws {}
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws {}
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws {}
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws {}
    func stripIPTCAndXMP(from urls: [URL]) async throws {}
    func copyMetadataToRenderedFile(from source: URL, to destination: URL, bakedCameraRaw: CameraRawSettings?) async throws {}
}

extension MetadataFieldMutationWriteServiceTests {
    @Test("A prepare JSON commit followed by readback failure reports its durable unverified path")
    func prepareReadbackFailure() async throws {
        let (folder, image, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: image)
        let hooks = MetadataFieldMutationWriteHooks(afterPrepareJSONCommit: { throw CocoaError(.fileReadUnknown) })
        let result = await worker(hooks: hooks).write(request(image, mutation: .rating(3)))
        #expect(result.installedSidecar == nil)
        #expect(result.committedButUnverifiedSidecarURL == json(image))
        #expect(!result.didWriteEmbedded && !result.didWriteXMP)
        #expect(result.failure?.stage == .prepare)
        #expect(try Data(contentsOf: image) == before)
        let saved = try #require(MetadataSidecarService().loadSidecar(for: image, in: folder))
        #expect(saved.metadata.rating == 3)
        #expect(saved.pendingChanges)
    }
}

extension MetadataFieldMutationWriteServiceTests {
    @Test("Physical cancellation preserves cancellation and possible-commit evidence", arguments: [false, true])
    func physicalCancellationMapping(afterPossibleWrite: Bool) async throws {
        let (folder, image, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: image)
        let writer = ThrowAfterFieldCommitWriter(cancelled: true, commits: afterPossibleWrite)
        let result = await worker(engine: writer).write(request(image, mode: .writeToFileAndXMPSidecar, mutation: .rating(4)))
        #expect(result.wasCancelled)
        #expect(!result.completed)
        #expect(result.failure == nil)
        #expect(!result.didWriteEmbedded) // No verified receipt was returned.
        #expect(result.embeddedWriteMayHaveOccurred == afterPossibleWrite)
        #expect(!result.didWriteXMP)
        #expect(result.installedSidecar?.pendingChanges == true)
        if afterPossibleWrite { #expect(try await read(image).rating == 4) }
        else { #expect(try Data(contentsOf: image) == before) }
    }
}
