import AppKit
import Foundation
import Testing
import SwiftMediaMetadata
@testable import Aagedal_Photo_Agent

/// Holds embedded writes until `open()` so later saves queue behind them.
private nonisolated final class BatchQueueGatedWriteEngine: MetadataWriteEngine, @unchecked Sendable {
    private let inner = SwiftExifWriteEngine()
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.withLock { isOpen = true } }
    private func waitUntilOpen() async {
        while !lock.withLock({ isOpen }) { try? await Task.sleep(for: .milliseconds(5)) }
    }
    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        await waitUntilOpen()
        try await inner.writeFields(fields, to: urls, structuredData: structuredData)
    }
    func writeFieldsToRenderedFiles(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        try await inner.writeFieldsToRenderedFiles(fields, to: urls, structuredData: structuredData)
    }
    func addRemoveListValues(add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]], to urls: [URL]) async throws {
        await waitUntilOpen()
        try await inner.addRemoveListValues(add: add, remove: remove, to: urls)
    }
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws { try await inner.writeRating(rating, to: urls) }
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws { try await inner.writeLabel(label, to: urls) }
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws { try await inner.writeOrientation(orientation, to: urls) }
    func stripIPTCAndXMP(from urls: [URL]) async throws { try await inner.stripIPTCAndXMP(from: urls) }
    func copyMetadataToRenderedFile(from source: URL, to destination: URL, bakedCameraRaw: CameraRawSettings?) async throws {
        try await inner.copyMetadataToRenderedFile(from: source, to: destination, bakedCameraRaw: bakedCameraRaw)
    }
}

@Suite("Metadata batch list selection", .serialized)
@MainActor
struct MetadataBatchSelectionTests {
    @Test("batch JSON and XMP saves preserve explicit supplier append and clear intent")
    func batchSupplierSaveIntent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = [try makeJPEG(in: folder, name: "first.jpg"),
                    try makeJPEG(in: folder, name: "second.jpg")]
        let first = EditorialImageSupplier(identifier: "first", name: "First Agency")
        let second = EditorialImageSupplier(identifier: "second", name: "Second Agency")
        let appended = EditorialImageSupplier(identifier: "desk", name: "Desk")
        for (url, supplier) in zip(urls, [first, second]) {
            var metadata = IPTCMetadata()
            metadata.imageSuppliers = [supplier]
            try await write(metadata, to: url)
        }
        let model = MetadataViewModel(
            readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine()
        )
        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)
        try model.setBatchImageSupplierMutation(.append([appended]))
        model.saveToSidecar()
        try await waitForSave(model)
        for (url, supplier) in zip(urls, [first, second]) {
            let sidecar = try #require(MetadataSidecarService().loadSidecar(for: url, in: folder))
            #expect(sidecar.metadata.imageSuppliers == [supplier, appended])
            #expect(XMPSidecarService().loadSidecar(for: url)?.imageSuppliers == [supplier, appended])
        }
        try model.setBatchImageSupplierMutation(.clear)
        model.saveToSidecar()
        try await waitForSave(model)
        for url in urls {
            let sidecar = try #require(MetadataSidecarService().loadSidecar(for: url, in: folder))
            #expect(sidecar.metadata.imageSuppliers.isEmpty)
            #expect(XMPSidecarService().loadSidecar(for: url)?.imageSuppliers.isEmpty == true)
        }
    }

    @Test("embedded writer persists ordered creators and exact XMP date with representable IIM")
    func embeddedOrderedCreatorAndDateWrite() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreatorDateWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = try makeJPEG(in: folder, name: "ordered.jpg")
        let metadata = IPTCMetadata(
            creators: ["First Reporter", "Second Reporter"],
            dateCreated: "2026-08-21T10:15:30+02:30"
        )

        try await write(metadata, to: imageURL)

        let embedded = try SwiftMediaMetadata.readMetadata(from: imageURL)
        #expect(embedded.iptc.bylines == ["First Reporter", "Second Reporter"])
        #expect(embedded.iptc.dateCreated == "20260821")
        #expect(embedded.iptc.timeCreated == "101530+0230")
        #expect(embedded.xmp?.creator == ["First Reporter", "Second Reporter"])
        #expect(embedded.xmp?.simpleValue(
            namespace: XMPNamespace.photoshop,
            property: "DateCreated"
        ) == "2026-08-21T10:15:30+02:30")

        let readBack = try await SwiftExifReadService().readFullMetadata(url: imageURL)
        #expect(readBack.creators == metadata.creators)
        #expect(readBack.dateCreated == metadata.dateCreated)
    }

    @Test("common and partial projections cover every repeatable field and shown locations")
    func commonMixedAndPartialProjection() {
        let oslo = EditorialLocation(
            identifiers: [" urn:place:oslo ", "oslocode", "oslocode"],
            name: " Oslo ",
            countryCode: "nor"
        )
        let bergen = EditorialLocation(name: "Bergen", countryCode: "NOR")

        let first = IPTCMetadata(
            keywords: ["wire", "alpha", " wire "],
            personShown: ["Kari", "Ada"],
            organisationsShownNames: ["Agency", "Desk A"],
            organisationsShownCodes: ["AGY", "A"],
            sceneCodes: ["scn:011200", "012400"],
            creators: ["First Reporter", "Second Reporter"],
            locationsShown: [oslo, bergen]
        )
        let second = IPTCMetadata(
            keywords: ["beta", "wire"],
            personShown: ["Ada", "Kari"],
            organisationsShownNames: ["Desk B", "Agency"],
            organisationsShownCodes: ["B", "AGY"],
            sceneCodes: [IPTCSceneCode.schemeURI + "011200", "013100"],
            creators: ["Second Reporter", "First Reporter"],
            locationsShown: [EditorialLocation(
                identifiers: ["oslocode", "urn:place:oslo"],
                name: "Oslo",
                countryCode: "NOR"
            )]
        )

        let summary = MetadataViewModel.batchListSelectionSummary(for: [first, second])

        #expect(summary.selection(for: .keywords).common == ["wire"])
        #expect(summary.selection(for: .keywords).partial == ["alpha", "beta"])
        #expect(summary.selection(for: .personShown).common == ["Kari", "Ada"])
        #expect(summary.selection(for: .personShown).partial.isEmpty)
        #expect(summary.selection(for: .organisationShownName).common == ["Agency"])
        #expect(summary.selection(for: .organisationShownName).partial == ["Desk A", "Desk B"])
        #expect(summary.selection(for: .organisationShownCode).common == ["AGY"])
        #expect(summary.selection(for: .organisationShownCode).partial == ["A", "B"])
        #expect(summary.selection(for: .sceneCode).common == ["011200"])
        #expect(summary.selection(for: .sceneCode).partial == ["012400", "013100"])
        #expect(summary.selection(for: .creator).common.isEmpty)
        #expect(summary.selection(for: .creator).partial == ["First Reporter", "Second Reporter"])
        #expect(summary.locationsShown.common.map(\.name) == ["Oslo"])
        #expect(summary.locationsShown.partial.map(\.name) == ["Bergen"])
    }

    @Test("literal template on a multi-selection records explicit list intent")
    func literalTemplateRecordsBatchIntent() throws {
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.selectedURLs = ["one.jpg", "two.jpg"].map { URL(fileURLWithPath: "/virtual/template-batch/\($0)") }
        model.selectedCount = 2
        // No common values: per-photo lists differ, so the editor starts empty.
        model.applyTemplateFields(["keywords": "desk", "mediaTopic": "medtop:01000000",
            "genre": "genre:Feature", "subjectCode": "01000000"])
        model.applyTemplateFields(["creator": "Second Reporter"], append: true)

        #expect(model.batchFieldMutations[.keywords] == .overwrite(.repeatable(["desk"])))
        #expect(model.batchFieldMutations[.creator] == .append(["Second Reporter"]))
        for field in [MetadataFieldID.mediaTopic, .genre, .subjectCode] {
            #expect(model.batchFieldMutations[field] != nil, "Missing template intent for \(field)")
        }
        let photo = IPTCMetadata(keywords: ["own keyword"], creators: ["First Reporter"])
        let saved = try MetadataViewModel.applyingBatchListMutations(model.batchFieldMutations, to: photo)
        #expect(saved.keywords == ["desk"])
        #expect(saved.creators == ["First Reporter", "Second Reporter"])
        #expect(saved.subjectCodes == ["01000000"])
        #expect(saved.mediaTopics.map(\.termIdentifier) == model.editingMetadata.mediaTopics.map(\.termIdentifier))
        #expect(!saved.mediaTopics.isEmpty)
        #expect(!saved.genres.isEmpty)
    }

    @Test("explicit append replace and clear are normalized and transactional")
    func explicitOperations() throws {
        let oslo = EditorialLocation(name: "Oslo", countryCode: "NOR")
        let bergen = EditorialLocation(name: " Bergen ", countryCode: "nor")
        let original = IPTCMetadata(
            keywords: ["wire"],
            personShown: ["Kari"],
            organisationsShownNames: ["Agency"],
            organisationsShownCodes: ["AGY"],
            sceneCodes: ["011200"],
            creators: ["First Reporter"],
            locationsShown: [oslo]
        )

        let appended = try MetadataViewModel.applyingBatchListMutations(
            [
                .keywords: .append([" wire ", "desk"]),
                .personShown: .append(["Kari", "Ada"]),
                .organisationShownName: .append(["Agency", "Bureau"]),
                .organisationShownCode: .append(["AGY", "BR"]),
                .sceneCode: .append(["scn:011200", "012400"]),
                .creator: .append(["Second Reporter", "First Reporter"]),
            ],
            locationsShown: .append([bergen, bergen]),
            to: original
        )
        #expect(appended.keywords == ["wire", "desk"])
        #expect(appended.personShown == ["Kari", "Ada"])
        #expect(appended.organisationsShownNames == ["Agency", "Bureau"])
        #expect(appended.organisationsShownCodes == ["AGY", "BR"])
        #expect(appended.sceneCodes == ["011200", "012400"])
        #expect(appended.creators == ["First Reporter", "Second Reporter"])
        #expect(appended.locationsShown == [oslo, EditorialLocation(name: "Bergen", countryCode: "NOR")])

        let replaced = try MetadataViewModel.applyingBatchListMutations(
            [
                .keywords: .overwrite(.repeatable([" replacement ", "replacement"])),
                .personShown: .clear,
                .creator: .overwrite(.repeatable(["Second Reporter", "First Reporter"])),
                .organisationShownName: .overwrite(.repeatable(["New Agency"])),
                .organisationShownCode: .clear,
                .sceneCode: .overwrite(.repeatable(["scn:013100"])),
            ],
            locationsShown: .replace([bergen]),
            to: appended
        )
        #expect(replaced.keywords == ["replacement"])
        #expect(replaced.personShown.isEmpty)
        #expect(replaced.creators == ["Second Reporter", "First Reporter"])
        #expect(replaced.organisationsShownNames == ["New Agency"])
        #expect(replaced.organisationsShownCodes.isEmpty)
        #expect(replaced.sceneCodes == ["013100"])
        #expect(replaced.locationsShown == [EditorialLocation(name: "Bergen", countryCode: "NOR")])

        let clearOperations: [MetadataFieldID: MetadataFieldMutation] = Dictionary(
            uniqueKeysWithValues: MetadataFieldID.allCases.filter(\.isRepeatable).map { ($0, .clear) }
        )
        let cleared = try MetadataViewModel.applyingBatchListMutations(
            clearOperations,
            locationsShown: .clear,
            to: replaced
        )
        #expect(cleared.keywords.isEmpty)
        #expect(cleared.personShown.isEmpty)
        #expect(cleared.organisationsShownNames.isEmpty)
        #expect(cleared.organisationsShownCodes.isEmpty)
        #expect(cleared.sceneCodes.isEmpty)
        #expect(cleared.locationsShown.isEmpty)

        #expect(throws: BatchListSelectionError.emptyLocationAppend) {
            try MetadataViewModel.applyingBatchListMutations(
                [:], locationsShown: .append([EditorialLocation()]), to: original
            )
        }
        #expect(throws: BatchListSelectionError.emptyLocationReplace) {
            try MetadataViewModel.applyingBatchListMutations(
                [:], locationsShown: .replace([]), to: original
            )
        }
    }

    @Test("batch sidecar drafts preserve each partial record before explicit append")
    func sidecarFirstPreservesPartialValues() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataBatchSelection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let firstURL = try makeJPEG(in: folder, name: "first.jpg")
        let secondURL = try makeJPEG(in: folder, name: "second.jpg")
        let commonLocation = EditorialLocation(name: "Oslo", countryCode: "NOR")
        let firstOnlyLocation = EditorialLocation(name: "Bergen", countryCode: "NOR")
        let appendedLocation = EditorialLocation(name: "Trondheim", countryCode: "NOR")

        let first = IPTCMetadata(
            keywords: ["wire", "first-only"],
            personShown: ["Common Person", "First Person"],
            organisationsShownNames: ["Common Org", "First Org"],
            organisationsShownCodes: ["COMMON", "FIRST"],
            sceneCodes: ["011200", "012400"],
            creators: ["First Reporter"],
            locationsShown: [commonLocation, firstOnlyLocation]
        )
        let second = IPTCMetadata(
            keywords: ["wire", "second-only"],
            personShown: ["Common Person", "Second Person"],
            organisationsShownNames: ["Common Org", "Second Org"],
            organisationsShownCodes: ["COMMON", "SECOND"],
            sceneCodes: ["011200", "013100"],
            creators: ["Other Reporter"],
            locationsShown: [commonLocation]
        )
        try await write(first, to: firstURL)
        try await write(second, to: secondURL)

        let model = MetadataViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        model.loadMetadata(
            for: [ImageFile(url: firstURL), ImageFile(url: secondURL)],
            folderURL: folder
        )
        try await waitForBatchLoad(model)

        #expect(model.editingMetadata.keywords == ["wire"])
        #expect(model.batchListSelectionSummary.selection(for: .keywords).partial == ["first-only", "second-only"])
        #expect(model.editingMetadata.locationsShown == [commonLocation])

        try model.setBatchMutation(.append([" desk ", "desk"]), for: .keywords)
        try model.setBatchMutation(.append(["New Person"]), for: .personShown)
        try model.setBatchMutation(.append(["New Org"]), for: .organisationShownName)
        try model.setBatchMutation(.append(["NEW"]), for: .organisationShownCode)
        try model.setBatchMutation(.append(["scn:014000"]), for: .sceneCode)
        try model.setBatchMutation(.append(["Desk Editor"]), for: .creator)
        try model.setBatchLocationsShownMutation(.append([appendedLocation]))
        model.editingMetadata.dateCreated = "2026-08-21T10:15:30-00:00"
        model.markChanged()
        model.saveToSidecar()
        try await waitForSave(model)

        let sidecarService = MetadataSidecarService()
        let firstDraft = try #require(sidecarService.loadSidecar(for: firstURL, in: folder))
        let secondDraft = try #require(sidecarService.loadSidecar(for: secondURL, in: folder))
        #expect(firstDraft.pendingChanges)
        #expect(secondDraft.pendingChanges)
        #expect(firstDraft.metadata.keywords == ["wire", "first-only", "desk"])
        #expect(secondDraft.metadata.keywords == ["wire", "second-only", "desk"])
        #expect(firstDraft.metadata.personShown == ["Common Person", "First Person", "New Person"])
        #expect(secondDraft.metadata.personShown == ["Common Person", "Second Person", "New Person"])
        #expect(firstDraft.metadata.organisationsShownNames == ["Common Org", "First Org", "New Org"])
        #expect(secondDraft.metadata.organisationsShownCodes == ["COMMON", "SECOND", "NEW"])
        #expect(firstDraft.metadata.sceneCodes == ["011200", "012400", "014000"])
        #expect(secondDraft.metadata.locationsShown == [commonLocation, appendedLocation])
        #expect(firstDraft.metadata.creators == ["First Reporter", "Desk Editor"])
        #expect(secondDraft.metadata.creators == ["Other Reporter", "Desk Editor"])
        #expect(firstDraft.metadata.dateCreated == "2026-08-21T10:15:30-00:00")
        #expect(!firstDraft.metadata.keywords.contains("Multiple values"))

        let firstXMP = try #require(XMPSidecarService().loadSidecar(for: firstURL))
        let secondXMP = try #require(XMPSidecarService().loadSidecar(for: secondURL))
        #expect(firstXMP.keywords == firstDraft.metadata.keywords)
        #expect(secondXMP.keywords == secondDraft.metadata.keywords)
        #expect(Set(firstXMP.locationsShown) == Set(firstDraft.metadata.locationsShown))
        #expect(firstXMP.creators == firstDraft.metadata.creators)
        #expect(firstXMP.dateCreated == firstDraft.metadata.dateCreated)
    }

    // MARK: - 3.0 metadata write regressions

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataWriteRegression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func loadSingle(_ model: MetadataViewModel, _ url: URL, in folder: URL,
                            preservingUnsavedEdits: Bool = false) async throws {
        model.loadMetadata(for: [ImageFile(url: url)], folderURL: folder,
                           preservingUnsavedEdits: preservingUnsavedEdits)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.isLoading)
        try #require(model.metadata != nil)
    }

    @Test("single embedded save and batch keyword overwrite keep commas inside list items")
    func embeddedSavesKeepCommaListItems() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let single = try makeJPEG(in: folder, name: "single.jpg")
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        try await loadSingle(model, single, in: folder)
        model.editingMetadata.keywords = ["Støre, Jonas Gahr", "politikk"]
        model.editingMetadata.personShown = ["Støre, Jonas Gahr"]
        model.markChanged()
        let result = await withCheckedContinuation { continuation in
            model.commitEditsReportingResult(mode: .writeToFile) { continuation.resume(returning: $0) }
        }
        #expect(result == .succeeded)
        let singleRead = try await SwiftExifReadService().readFullMetadata(url: single)
        #expect(singleRead.keywords == ["Støre, Jonas Gahr", "politikk"])
        #expect(singleRead.personShown == ["Støre, Jonas Gahr"])

        let urls = [try makeJPEG(in: folder, name: "a.jpg"), try makeJPEG(in: folder, name: "b.jpg")]
        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)
        try model.setBatchMutation(.overwrite(.repeatable(["Støre, Jonas Gahr"])), for: .keywords)
        model.writeMetadata()
        try await waitForSave(model)
        for url in urls {
            #expect(try await SwiftExifReadService().readFullMetadata(url: url).keywords == ["Støre, Jonas Gahr"])
        }
    }

    @Test("batch embedded save advances its baseline so a just-added value can be removed again")
    func batchRemoveJustAddedValue() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = [try makeJPEG(in: folder, name: "a.jpg"), try makeJPEG(in: folder, name: "b.jpg")]
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)

        model.editingMetadata.organisationsShownNames = ["Agency, Inc"]
        model.markChanged()
        model.writeMetadata()
        try await waitForSave(model)
        for url in urls {
            #expect(try await SwiftExifReadService().readFullMetadata(url: url).organisationsShownNames == ["Agency, Inc"])
        }

        model.editingMetadata.organisationsShownNames = []
        model.markChanged()
        model.writeMetadata()
        try await waitForSave(model)
        for url in urls {
            #expect(try await SwiftExifReadService().readFullMetadata(url: url).organisationsShownNames.isEmpty)
        }
    }

    @Test("A batch save writes the files that fit, refuses an oversized one and keeps its edit as a pending draft")
    func batchContinuesPastOversizedFile() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try makeJPEG(in: folder, name: "a.jpg")
        let full = folder.appendingPathComponent("b.jpg")
        try NearLimitJPEGFixture.make(at: full)
        let last = try makeJPEG(in: folder, name: "c.jpg")
        let fullBytes = try Data(contentsOf: full)
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.loadMetadata(for: [first, full, last].map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)

        model.editingMetadata.description = "Batch caption"
        model.markChanged()
        model.writeMetadata()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isSaving, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isSaving)

        #expect(try await SwiftExifReadService().readFullMetadata(url: first).description == "Batch caption")
        #expect(try await SwiftExifReadService().readFullMetadata(url: last).description == "Batch caption")
        #expect(try Data(contentsOf: full) == fullBytes)
        let draft = try #require(MetadataSidecarService().loadSidecar(for: full, in: folder))
        #expect(draft.pendingChanges)
        #expect(draft.metadata.description == "Batch caption")
        #expect(model.saveError?.contains("b.jpg") == true)
        #expect(MetadataSidecarService().loadSidecar(for: first, in: folder)?.pendingChanges != true)
    }

    @Test("A refused single-photo save without a draft keeps the editor dirty and claims no pending draft")
    func refusedSingleSaveStaysDirty() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let full = folder.appendingPathComponent("single-full.jpg")
        try NearLimitJPEGFixture.make(at: full)
        let before = try Data(contentsOf: full)
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        // Folderless selection: the `currentFolderURL == nil` fallback that writes without drafts.
        model.loadMetadata(for: [ImageFile(url: full)], folderURL: nil)
        let loadDeadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < loadDeadline { try await Task.sleep(for: .milliseconds(10)) }
        model.editingMetadata.description = "Refused caption"
        model.markChanged()
        model.writeMetadata()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isSaving, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isSaving)
        #expect(try Data(contentsOf: full) == before)
        #expect(model.saveError?.contains("single-full.jpg") == true)
        #expect(model.hasChanges)
        #expect(!model.selectedHavePendingSidecars)
        #expect(model.metadata?.description != "Refused caption")
    }

    @Test("batch commit through the Browser write path finishes saving")
    func batchCommitClearsSaving() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = [try makeJPEG(in: folder, name: "a.jpg"), try makeJPEG(in: folder, name: "b.jpg")]
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)

        model.editingMetadata.city = "Oslo"
        model.markChanged()
        let result = await withCheckedContinuation { continuation in
            model.commitEditsReportingResult(mode: .writeToFile) { continuation.resume(returning: $0) }
        }
        #expect(result == .succeeded)
        try await waitForSave(model)
        for url in urls {
            #expect(try await SwiftExifReadService().readFullMetadata(url: url).city == "Oslo")
        }
    }

    @Test("a second batch location write keeps the first one")
    func secondBatchLocationWriteKeepsFirst() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = [try makeJPEG(in: folder, name: "a.jpg"), try makeJPEG(in: folder, name: "b.jpg")]
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)
        let first = EditorialLocation(name: "Oslo", countryCode: "NOR")
        let second = EditorialLocation(name: "Bergen", countryCode: "NOR")

        try model.setBatchLocationsShownMutation(.append([first]))
        model.writeMetadata()
        try await waitForSave(model)
        try model.setBatchLocationsShownMutation(.append([second]))
        model.writeMetadata()
        try await waitForSave(model)

        for url in urls {
            #expect(try await SwiftExifReadService().readFullMetadata(url: url).locationsShown == [first, second])
        }
    }

    @Test("emptying a batch field that was common to the selection clears it on every photo")
    func batchClearCommonField() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = [try makeJPEG(in: folder, name: "a.jpg"), try makeJPEG(in: folder, name: "b.jpg")]
        for (url, credit) in zip(urls, ["Desk A", "Desk B"]) {
            try await write(IPTCMetadata(credit: credit, city: "Oslo"), to: url)
        }
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)
        try #require(model.editingMetadata.city == "Oslo")
        model.editingMetadata.city = ""
        model.markChanged()
        model.writeMetadata()
        try await waitForSave(model)
        for (url, credit) in zip(urls, ["Desk A", "Desk B"]) {
            let read = try await SwiftExifReadService().readFullMetadata(url: url)
            #expect(read.city == nil)
            // A mixed field the user left empty stays untouched.
            #expect(read.credit == credit)
        }
        #expect(MetadataViewModel.batchScalarWriteValue(nil, previous: nil) == nil)
        #expect(MetadataViewModel.batchScalarWriteValue("", previous: "Oslo") == "")
        #expect(MetadataViewModel.batchScalarWriteValue("Bergen", previous: "Oslo") == "Bergen")
    }

    @Test("batch embedded write folds its change into existing pending drafts")
    func batchEmbeddedWriteUpdatesPendingDraft() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let drafted = try makeJPEG(in: folder, name: "drafted.jpg")
        let plain = try makeJPEG(in: folder, name: "plain.jpg")
        try MetadataSidecarService().saveSidecar(.init(sourceFile: drafted.lastPathComponent,
            pendingChanges: true, metadata: IPTCMetadata(title: "Draft headline"),
            imageMetadataSnapshot: IPTCMetadata()), for: drafted, in: folder)
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.loadMetadata(for: [ImageFile(url: drafted), ImageFile(url: plain)], folderURL: folder)
        try await waitForBatchLoad(model)
        model.editingMetadata.city = "Bergen"
        model.markChanged()
        model.writeMetadata()
        try await waitForSave(model)

        #expect(try await SwiftExifReadService().readFullMetadata(url: plain).city == "Bergen")
        let draft = try #require(MetadataSidecarService().loadSidecar(for: drafted, in: folder))
        #expect(draft.pendingChanges)
        #expect(draft.metadata.title == "Draft headline")
        #expect(draft.metadata.city == "Bergen")
        #expect(MetadataSidecarService().loadSidecar(for: plain, in: folder) == nil)
    }

    @Test("auto-refresh of the same photo keeps unsaved edits instead of replacing them")
    func sameImageReloadKeepsUnsavedEdits() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try makeJPEG(in: folder, name: "photo.jpg")
        try await write(IPTCMetadata(title: "On disk"), to: url)
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        try await loadSingle(model, url, in: folder)
        model.editingMetadata.title = "Typed but unsaved"
        model.markChanged()
        try await loadSingle(model, url, in: folder, preservingUnsavedEdits: true)
        #expect(model.editingMetadata.title == "Typed but unsaved")
        #expect(model.hasUnpersistedEditorChanges)

        // Without unsaved edits a reload still refreshes from disk.
        model.editingMetadata.title = "On disk"
        model.hasChanges = false
        try await write(IPTCMetadata(title: "Changed externally"), to: url)
        try await loadSingle(model, url, in: folder, preservingUnsavedEdits: true)
        #expect(model.editingMetadata.title == "Changed externally")
    }

    @Test("a passive same-photo reload keeps the unsaved edits' diff baseline while it loads")
    func sameImageReloadKeepsDiffBaselineWhileLoading() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try makeJPEG(in: folder, name: "photo.jpg")
        try await write(IPTCMetadata(title: "On disk"), to: url)
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        try await loadSingle(model, url, in: folder)
        model.editingMetadata.title = "Typed but unsaved"
        model.markChanged()

        model.loadMetadata(for: [ImageFile(url: url)], folderURL: folder, preservingUnsavedEdits: true)
        #expect(model.originalImageMetadata?.title == "On disk")
        try await loadSingle(model, url, in: folder, preservingUnsavedEdits: true)
        #expect(model.originalImageMetadata?.title == "On disk")

        // An explicit reload still starts from no baseline.
        model.loadMetadata(for: [ImageFile(url: url)], folderURL: folder)
        #expect(model.originalImageMetadata == nil)
        try await loadSingle(model, url, in: folder)
    }

    @Test("a single-photo save right after a batch save waits for the batch instead of cancelling it")
    func singleSaveAfterBatchSaveKeepsEveryBatchPhoto() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var urls: [URL] = []
        for index in 0..<4 { urls.append(try makeJPEG(in: folder, name: "batch\(index).jpg")) }
        let single = try makeJPEG(in: folder, name: "single.jpg")
        let engine = BatchQueueGatedWriteEngine()
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: engine)
        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)

        // A held embedded batch write keeps the following batch XMP save queued.
        model.editingMetadata.city = "Oslo"
        model.markChanged()
        model.writeMetadata()
        model.editingMetadata.event = "Cup final"
        model.markChanged()
        var batchResult: MetadataCommitResult?
        model.commitEditsReportingResult(mode: .writeToXMPSidecar) { batchResult = $0 }

        try await loadSingle(model, single, in: folder)
        model.editingMetadata.title = "Single headline"
        model.markChanged()
        var singleResult: MetadataCommitResult?
        model.commitEditsReportingResult(mode: .writeToXMPSidecar) { singleResult = $0 }
        engine.open()

        let deadline = ContinuousClock.now + .seconds(10)
        while batchResult == nil || singleResult == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(batchResult == .succeeded)
        #expect(singleResult == .succeeded)
        for url in urls {
            #expect(XMPSidecarService().loadSidecar(for: url)?.event == "Cup final")
        }
        #expect(XMPSidecarService().loadSidecar(for: single)?.title == "Single headline")
    }

    @Test("a mixed RAW+JPEG batch save keeps a rating and face name written to the RAW sidecar after load")
    func mixedBatchSaveKeepsRawSidecarRating() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpeg = try makeJPEG(in: folder, name: "a.jpg")
        let raw = try makeJPEG(in: folder, name: "b.nef")
        try #require(SupportedImageFormats.isRaw(url: raw))
        try XMPSidecarService().saveSidecar(metadata: IPTCMetadata(title: "Raw headline"), for: raw)
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.loadMetadata(for: [ImageFile(url: jpeg), ImageFile(url: raw)], folderURL: folder)
        try await waitForBatchLoad(model)

        // Rated and face-named (e.g. from the grid / face review) after the batch editor loaded.
        _ = try await XMPSidecarService().updateSidecarSerialized(for: raw, fallback: IPTCMetadata()) {
            $0.rating = 4
            $0.personShown = ["Ola Nordmann"]
        }
        let rated = XMPSidecarService().loadSidecar(for: raw)
        try #require(rated?.rating == 4)
        try #require(rated?.personShown == ["Ola Nordmann"])
        model.editingMetadata.description = "Batch caption"
        model.markChanged()
        model.writeMetadata()
        try await waitForSave(model)

        let sidecar = try #require(XMPSidecarService().loadSidecar(for: raw))
        #expect(sidecar.description == "Batch caption")
        #expect(sidecar.title == "Raw headline")
        #expect(sidecar.rating == 4)
        #expect(sidecar.personShown == ["Ola Nordmann"])
        #expect(try await SwiftExifReadService().readFullMetadata(url: jpeg).description == "Batch caption")
    }

    @Test("a batch caption save leaves a RAW sidecar's Camera Raw block exactly as stored")
    func batchSaveKeepsRawDevelopSettingsVerbatim() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpeg = try makeJPEG(in: folder, name: "a.jpg")
        let raw = try makeJPEG(in: folder, name: "b.nef")
        try #require(SupportedImageFormats.isRaw(url: raw))
        // A crs property the app's model doesn't know must survive a descriptive batch edit.
        let sidecarXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
          crs:Exposure2012="+0.50" crs:FutureVendorSetting="7" photoshop:Headline="Raw headline"/>
        </rdf:RDF></x:xmpmeta>
        """
        let sidecarURL = XMPSidecarService().sidecarURL(for: raw)
        try Data(sidecarXML.utf8).write(to: sidecarURL)
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.loadMetadata(for: [ImageFile(url: jpeg), ImageFile(url: raw)], folderURL: folder)
        try await waitForBatchLoad(model)

        model.editingMetadata.description = "Batch caption"
        model.markChanged()
        model.writeMetadata()
        try await waitForSave(model)

        let written = try String(contentsOf: sidecarURL, encoding: .utf8)
        #expect(written.contains("FutureVendorSetting"))
        let sidecar = try #require(XMPSidecarService().loadSidecar(for: raw))
        #expect(sidecar.description == "Batch caption")
        #expect(sidecar.cameraRaw?.exposure2012 == 0.5)
    }

    @Test("a same-batch reload that replaces the editor drops list changes it no longer shows")
    func sameBatchReloadWithoutPreservingDropsBatchMutations() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = [try makeJPEG(in: folder, name: "a.jpg"), try makeJPEG(in: folder, name: "b.jpg")]
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)
        try model.setBatchMutation(.overwrite(.repeatable(["Dropped"])), for: .keywords)

        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)
        #expect(!model.hasUnpersistedEditorChanges)
        model.editingMetadata.city = "Oslo"
        model.markChanged()
        let result = await withCheckedContinuation { continuation in
            model.commitEditsReportingResult(mode: .writeToXMPSidecar) { continuation.resume(returning: $0) }
        }
        #expect(result == .succeeded)
        for url in urls {
            let sidecar = XMPSidecarService().loadSidecar(for: url)
            #expect(sidecar?.city == "Oslo")
            #expect(sidecar?.keywords.isEmpty == true)
        }
    }

    @Test("Copy IPTC record carries every descriptive field but never the per-image GUID")
    func copyableIPTCRecord() {
        var source = IPTCMetadata(title: "Headline", digitalImageGUID: "guid-1", city: "Oslo")
        source.sublocation = "Youngstorget"
        source.provinceState = "Oslo"
        source.instructions = "Embargo 12:00"
        source.source = "NTB"
        source.locationsCreated = [EditorialLocation(city: "Oslo")]
        source.creatorContactInfo = CreatorContactInfo(emails: ["desk@example.com"])
        source.rating = 5
        let copied = source.copyableIPTCRecord
        #expect(copied.digitalImageGUID == nil)
        #expect(copied.rating == nil)
        #expect(copied.sublocation == "Youngstorget")
        #expect(copied.provinceState == "Oslo")
        #expect(copied.instructions == "Embargo 12:00")
        #expect(copied.source == "NTB")
        #expect(copied.locationsCreated == source.locationsCreated)
        #expect(copied.creatorContactInfo == source.creatorContactInfo)
        #expect(copied.title == "Headline")
    }

    private func makeJPEG(in folder: URL, name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = bitmap.representation(using: .jpeg, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
        return url
    }

    private func write(_ metadata: IPTCMetadata, to url: URL) async throws {
        try await SwiftExifWriteEngine().writeFields(
            metadata.toOverwriteFields(),
            to: [url],
            structuredData: StructuredWriteData(
                editorial: EditorialStructuredWriteData(metadata: metadata)
            )
        )
    }

    private func waitForBatchLoad(_ model: MetadataViewModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoadingBatchMetadata, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isLoadingBatchMetadata)
        #expect(model.saveError == nil)
    }

    private func waitForSave(_ model: MetadataViewModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isSaving, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isSaving)
        #expect(model.saveError == nil)
    }
}

/// Fails every embedded descriptive write, as a full disk or a loss-guard refusal would.
private nonisolated final class FailingDescriptiveWriteEngine: MetadataWriteEngine, @unchecked Sendable {
    private let inner = SwiftExifWriteEngine()
    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
    func writeFieldsToRenderedFiles(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        try await inner.writeFieldsToRenderedFiles(fields, to: urls, structuredData: structuredData)
    }
    func addRemoveListValues(add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]], to urls: [URL]) async throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws { try await inner.writeRating(rating, to: urls) }
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws { try await inner.writeLabel(label, to: urls) }
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws { try await inner.writeOrientation(orientation, to: urls) }
    func stripIPTCAndXMP(from urls: [URL]) async throws { try await inner.stripIPTCAndXMP(from: urls) }
    func copyMetadataToRenderedFile(from source: URL, to destination: URL, bakedCameraRaw: CameraRawSettings?) async throws {
        try await inner.copyMetadataToRenderedFile(from: source, to: destination, bakedCameraRaw: bakedCameraRaw)
    }
}

// MARK: - Metadata panel editing workflow (3.0)

extension MetadataBatchSelectionTests {
    /// Runs `body` under the Professional preset (sidecar for C2PA) in the test-isolated store.
    private func withProfessionalPreset(_ body: () async throws -> Void) async rethrows {
        let defaults = AppDefaults.store
        let saved = defaults.object(forKey: UserDefaultsKeys.metadataWritePreset)
        defaults.set(MetadataWritePreset.professional.rawValue, forKey: UserDefaultsKeys.metadataWritePreset)
        defer {
            if let saved { defaults.set(saved, forKey: UserDefaultsKeys.metadataWritePreset) }
            else { defaults.removeObject(forKey: UserDefaultsKeys.metadataWritePreset) }
        }
        try await body()
    }

    private func waitForSingleLoad(_ model: MetadataViewModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!model.isLoading)
        try #require(model.metadata != nil)
    }

    private func sharedBatchFixture(in folder: URL) async throws -> [URL] {
        let urls = [try makeJPEG(in: folder, name: "one.jpg"), try makeJPEG(in: folder, name: "two.jpg")]
        var shared = IPTCMetadata()
        shared.urgency = 3
        shared.digitalSourceType = .digitalCapture
        shared.latitude = 59.91
        shared.longitude = 10.75
        shared.dateCreated = "2026-05-17"
        for url in urls { try await write(shared, to: url) }
        return urls
    }

    private func clearSharedScalars(_ model: MetadataViewModel) {
        model.editingMetadata.urgency = nil
        model.editingMetadata.digitalSourceType = nil
        model.editingMetadata.latitude = nil
        model.editingMetadata.longitude = nil
        model.editingMetadata.dateCreated = nil
        model.markChanged()
    }

    @Test("batch embedded save clears a common urgency, digital source type and GPS")
    func batchEmbeddedClearsCommonValues() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try await sharedBatchFixture(in: folder)
        let before = try await SwiftExifReadService().readFullMetadata(url: urls[0])
        try #require(before.urgency == 3 && before.digitalSourceType == .digitalCapture && before.latitude != nil)
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)
        #expect(model.batchPlaceholder(for: "dateCreated") == "Leave empty to skip")
        clearSharedScalars(model)
        #expect(model.batchPlaceholder(for: "dateCreated") == "Will be cleared on all 2 photos")
        model.writeMetadata()
        try await waitForSave(model)
        for url in urls {
            let read = try await SwiftExifReadService().readFullMetadata(url: url)
            #expect(read.urgency == nil)
            #expect(read.digitalSourceType == nil)
            #expect(read.latitude == nil && read.longitude == nil)
            #expect(read.dateCreated == nil)
        }
    }

    @Test("batch sidecar save clears a common urgency, digital source type, GPS and date")
    func batchSidecarClearsCommonValues() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try await sharedBatchFixture(in: folder)
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)
        clearSharedScalars(model)
        model.saveToSidecar()
        try await waitForSave(model)
        for url in urls {
            let draft = try #require(MetadataSidecarService().loadSidecar(for: url, in: folder))
            #expect(draft.metadata.urgency == nil)
            #expect(draft.metadata.digitalSourceType == nil)
            #expect(draft.metadata.latitude == nil && draft.metadata.longitude == nil)
            #expect(draft.metadata.dateCreated == nil)
        }
    }

    @Test("a mixed batch value left empty stays untouched on the sidecar path")
    func batchSidecarLeavesMixedValues() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = [try makeJPEG(in: folder, name: "a.jpg"), try makeJPEG(in: folder, name: "b.jpg")]
        for (url, urgency) in zip(urls, [2, 6]) {
            var metadata = IPTCMetadata()
            metadata.urgency = urgency
            try await write(metadata, to: url)
        }
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)
        model.editingMetadata.city = "Oslo"
        model.markChanged()
        model.saveToSidecar()
        try await waitForSave(model)
        for (url, urgency) in zip(urls, [2, 6]) {
            let draft = try #require(MetadataSidecarService().loadSidecar(for: url, in: folder))
            #expect(draft.metadata.urgency == urgency)
            #expect(draft.metadata.city == "Oslo")
        }
    }

    @Test("a partial keyword added to every photo leaves the partial chips")
    func partialKeywordAddedToAllIsNoLongerPartial() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = [try makeJPEG(in: folder, name: "a.jpg"), try makeJPEG(in: folder, name: "b.jpg")]
        for (url, keywords) in zip(urls, [["shared", "alpha"], ["shared", "beta"]]) {
            var metadata = IPTCMetadata()
            metadata.keywords = keywords
            try await write(metadata, to: url)
        }
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: folder)
        try await waitForBatchLoad(model)
        try #require(Set(model.batchPartialKeywords) == ["alpha", "beta"])
        model.editingMetadata.keywords.append("alpha")
        model.markChanged()
        #expect(model.visibleBatchPartialKeywords == ["beta"])
        model.writeMetadata()
        try await waitForSave(model)
        #expect(model.batchPartialKeywords == ["beta"])
        for url in urls {
            #expect(try await SwiftExifReadService().readFullMetadata(url: url).keywords.contains("alpha"))
        }
    }

    @Test("a folder switch saves a C2PA JPEG to its sidecar in the folder it was loaded from")
    func departingEditorUsesEditorModeAndFolder() async throws {
        try await withProfessionalPreset {
            let folder = try makeFolder()
            let nextFolder = try makeFolder()
            defer {
                try? FileManager.default.removeItem(at: folder)
                try? FileManager.default.removeItem(at: nextFolder)
            }
            let url = try makeJPEG(in: folder, name: "credentialed.jpg")
            var image = ImageFile(url: url)
            image.hasC2PA = true
            let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
            model.loadMetadata(for: [image], folderURL: folder)
            try await waitForSingleLoad(model)
            model.editingMetadata.description = "Departing caption"
            model.markChanged()
            // The browser has already published the next folder (and emptied its arrays).
            model.currentFolderURL = nextFolder
            #expect(model.editorWriteMode() == .writeToXMPSidecar)
            let outcome = await withCheckedContinuation { continuation in
                model.commitDepartingEditor { continuation.resume(returning: $0) }
            }
            #expect(outcome == .saved)
            #expect(model.currentFolderURL == nextFolder)
            let embedded = try await SwiftExifReadService().readFullMetadata(url: url)
            #expect(embedded.description == nil, "a C2PA file must never be embedded into automatically")
            #expect(XMPSidecarService().loadSidecar(for: url)?.description == "Departing caption")
            #expect(MetadataSidecarService().loadSidecar(for: url, in: folder)?.metadata.description == "Departing caption")
            #expect(MetadataSidecarService().loadSidecar(for: url, in: nextFolder) == nil)
        }
    }

    @Test("a failed navigation save keeps the edit as a pending draft and names the photo")
    func failedDepartingSaveKeepsDraft() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try makeJPEG(in: folder, name: "failing.jpg")
        let next = try makeJPEG(in: folder, name: "next.jpg")
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: FailingDescriptiveWriteEngine())
        try await loadSingle(model, url, in: folder)
        model.editingMetadata.description = "Must survive"
        model.markChanged()
        var outcome: EditorBoundaryCommitOutcome?
        await withProfessionalPreset {
            #expect(model.editorWriteMode() == .writeToFile)
            model.commitDepartingEditor { outcome = $0 }
        }
        // The user has already moved on when the failure arrives.
        model.loadMetadata(for: [ImageFile(url: next)], folderURL: folder)
        let deadline = ContinuousClock.now + .seconds(5)
        while outcome == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let result = try #require(outcome)
        guard case .keptAsDraft(let message) = result else {
            Issue.record("Expected a pending draft, got \(result)")
            return
        }
        #expect(message.contains("failing.jpg"))
        let draft = try #require(MetadataSidecarService().loadSidecar(for: url, in: folder))
        #expect(draft.pendingChanges)
        #expect(draft.metadata.description == "Must survive")
    }

    @Test("resolving a description conflict to the shown value still saves it")
    func descriptionConflictChoiceIsSaved() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try makeJPEG(in: folder, name: "conflict.jpg")
        var metadata = IPTCMetadata()
        metadata.description = "XMP text"
        try await write(metadata, to: url)
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        try await loadSingle(model, url, in: folder)
        model.descriptionConflict = DescriptionConflict(xmpDescription: "XMP text", iptcCaptionAbstract: "IPTC text")
        model.resolveDescriptionConflict(keepXMP: true)
        #expect(model.editingMetadata.description == "XMP text")
        #expect(model.hasUnpersistedEditorChanges, "the choice must reach the write path")
        let result = await withCheckedContinuation { continuation in
            model.commitEditsReportingResult(mode: .writeToFile) { continuation.resume(returning: $0) }
        }
        #expect(result == .succeeded)
        let (read, conflict) = try await SwiftExifReadService().readFullMetadataWithConflictCheck(url: url)
        #expect(read.description == "XMP text")
        #expect(conflict == nil)
        #expect(!model.hasUnpersistedEditorChanges)
    }

    @Test("a sidecar-mode save disables Write until there is something new to write")
    func writeButtonDisabledAfterSidecarSave() async throws {
        try await withProfessionalPreset {
            let folder = try makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = try makeJPEG(in: folder, name: "c2pa.jpg")
            var image = ImageFile(url: url)
            image.hasC2PA = true
            let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
            model.loadMetadata(for: [image], folderURL: folder)
            try await waitForSingleLoad(model)
            model.editingMetadata.description = "Sidecar only"
            model.markChanged()
            #expect(model.canWriteMetadataToImage)
            let result = await withCheckedContinuation { continuation in
                model.commitEditsReportingResult(mode: model.editorWriteMode()) { continuation.resume(returning: $0) }
            }
            #expect(result == .succeeded)
            #expect(model.embeddedMetadata?.description == nil)
            #expect(!model.canWriteMetadataToImage)
        }
    }

    @Test("panel notices clear on a new selection; a navigation notice survives one load")
    func noticeLifetimeFollowsSelection() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try makeJPEG(in: folder, name: "first.jpg")
        let second = try makeJPEG(in: folder, name: "second.jpg")
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        try await loadSingle(model, first, in: folder)
        model.notice = MetadataPanelNotice(title: "Template: 1 rejected", detail: [], severity: .warning)
        try await loadSingle(model, second, in: folder)
        #expect(model.notice == nil)
        model.editingMetadata.description = "{filename}"
        model.markChanged()
        model.keepUnresolvedVariablesAsPendingDraft()
        try await waitForSave(model)
        try await loadSingle(model, first, in: folder)
        #expect(model.notice != nil, "the boundary's own notice must survive its navigation")
        try await loadSingle(model, second, in: folder)
        #expect(model.notice == nil)
    }

    @Test("a typed chip token registered with the editor buffers is committed on flush")
    func pendingChipInputCommitsOnFlush() {
        let registry = MetadataEditorBufferRegistry()
        let owner = UUID()
        var committed: [String] = []
        var pending = "berlin"
        registry.registerPendingInput(key: "keywords", owner: owner) {
            guard !pending.isEmpty else { return false }
            committed.append(pending)
            pending = ""
            return true
        }
        #expect(registry.commitPendingInputs())
        #expect(committed == ["berlin"])
        #expect(!registry.commitPendingInputs())
        registry.unregisterPendingInput(key: "keywords", owner: UUID())
        pending = "oslo"
        #expect(registry.commitPendingInputs(), "another owner must not unregister the field")
        registry.unregisterPendingInput(key: "keywords", owner: owner)
        pending = "paris"
        #expect(!registry.commitPendingInputs())
    }
}

/// Fails embedded descriptive writes until `recover()`, like a card that is remounted writable.
private nonisolated final class RecoveringDescriptiveWriteEngine: MetadataWriteEngine, @unchecked Sendable {
    private let inner = SwiftExifWriteEngine()
    private let lock = NSLock()
    private var failing = true
    func recover() { lock.withLock { failing = false } }
    private func failIfNeeded() throws {
        if lock.withLock({ failing }) { throw CocoaError(.fileWriteVolumeReadOnly) }
    }
    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        try failIfNeeded()
        try await inner.writeFields(fields, to: urls, structuredData: structuredData)
    }
    func writeFieldsToRenderedFiles(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        try await inner.writeFieldsToRenderedFiles(fields, to: urls, structuredData: structuredData)
    }
    func addRemoveListValues(add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]], to urls: [URL]) async throws {
        try failIfNeeded()
        try await inner.addRemoveListValues(add: add, remove: remove, to: urls)
    }
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws { try await inner.writeRating(rating, to: urls) }
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws { try await inner.writeLabel(label, to: urls) }
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws { try await inner.writeOrientation(orientation, to: urls) }
    func stripIPTCAndXMP(from urls: [URL]) async throws { try await inner.stripIPTCAndXMP(from: urls) }
    func copyMetadataToRenderedFile(from source: URL, to destination: URL, bakedCameraRaw: CameraRawSettings?) async throws {
        try await inner.copyMetadataToRenderedFile(from: source, to: destination, bakedCameraRaw: bakedCameraRaw)
    }
}

// MARK: - Boundary failure handling (3.0 review follow-ups)

extension MetadataBatchSelectionTests {
    @Test("boundary decisions: drafts continue with a notice, failures ask or report a discard")
    func boundaryDecisionLogic() {
        #expect(EditorBoundaryDecision.resolve(.saved, canStay: true) == .proceed(attention: nil))
        #expect(EditorBoundaryDecision.resolve(.nothingToCommit, canStay: true) == .proceed(attention: nil))
        #expect(EditorBoundaryDecision.resolve(.superseded, canStay: false) == .proceed(attention: nil))
        #expect(EditorBoundaryDecision.resolve(.keptAsDraft(message: "kept"), canStay: true) == .proceed(attention: "kept"))
        let failure = EditorBoundaryCommitOutcome.failureMessage(files: "card.jpg", reason: "Read-only volume.")
        #expect(failure == "Couldn't save your metadata edits to card.jpg: Read-only volume.")
        #expect(EditorBoundaryDecision.resolve(.failed(message: failure), canStay: true) == .askToDiscard(message: failure))
        guard case .proceed(let attention?) = EditorBoundaryDecision.resolve(.failed(message: failure), canStay: false) else {
            Issue.record("A selection change cannot ask; it must report the discard")
            return
        }
        #expect(attention.hasPrefix(failure))
        #expect(attention.contains("discarded"))
    }

    @Test("a read-only folder fails the boundary save, and Discard lets the transition continue")
    func readOnlyFolderFailsAndCanBeDiscarded() async throws {
        let folder = try makeFolder()
        let url = try makeJPEG(in: folder, name: "card.jpg")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: FailingDescriptiveWriteEngine())
        try await loadSingle(model, url, in: folder)
        model.editingMetadata.description = "Cannot land"
        model.markChanged()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        var outcome: EditorBoundaryCommitOutcome?
        await withProfessionalPreset {
            model.commitDepartingEditor { outcome = $0 }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while outcome == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let result = try #require(outcome)
        guard case .failed(let message) = result else {
            Issue.record("Expected a failure when neither the write nor a draft can land, got \(result)")
            return
        }
        #expect(message.hasPrefix("Couldn't save your metadata edits to card.jpg:"))
        #expect(EditorBoundaryDecision.resolve(result, canStay: true) == .askToDiscard(message: message))
        #expect(model.hasUnpersistedEditorChanges)
        model.discardUnsavedEditorChanges()
        #expect(!model.hasUnpersistedEditorChanges, "Discard must clear the edit so the transition is not blocked again")
        #expect(model.editingMetadata.description == nil)
    }

    @Test("an unresolved-variables draft that cannot be written reports its failure")
    func variablesDraftFailureIsReported() async throws {
        let folder = try makeFolder()
        let url = try makeJPEG(in: folder, name: "vars.jpg")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        try await loadSingle(model, url, in: folder)
        model.editingMetadata.description = "{filename}"
        model.markChanged()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let failure: String? = await withCheckedContinuation { continuation in
            model.keepUnresolvedVariablesAsPendingDraft { continuation.resume(returning: $0) }
        }
        #expect(failure != nil)
    }

    @Test("after a draft fallback the photo reloads, so its next save is not a stale-sidecar conflict")
    func draftFallbackReloadsBaselines() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try makeJPEG(in: folder, name: "retry.jpg")
        let engine = RecoveringDescriptiveWriteEngine()
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: engine)
        try await loadSingle(model, url, in: folder)
        model.editingMetadata.description = "First try"
        model.markChanged()
        var outcome: EditorBoundaryCommitOutcome?
        await withProfessionalPreset {
            model.commitDepartingEditor { outcome = $0 }
        }
        var deadline = ContinuousClock.now + .seconds(5)
        while outcome == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard case .keptAsDraft = try #require(outcome) else {
            Issue.record("Expected a pending draft, got \(String(describing: outcome))")
            return
        }
        deadline = ContinuousClock.now + .seconds(5)
        while (model.isLoading || !model.selectedHavePendingSidecars), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.selectedHavePendingSidecars)
        #expect(model.editingMetadata.description == "First try")
        engine.recover()
        model.editingMetadata.description = "Second try"
        model.markChanged()
        let result = await withCheckedContinuation { continuation in
            model.commitEditsReportingResult(mode: .writeToXMPSidecar) { continuation.resume(returning: $0) }
        }
        #expect(result == .succeeded)
        #expect(XMPSidecarService().loadSidecar(for: url)?.description == "Second try")
    }

    @Test("History Only reports success only once its draft is durable")
    func historyOnlyCompletesAfterDraft() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try makeJPEG(in: folder, name: "draft.jpg")
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        try await loadSingle(model, url, in: folder)
        model.editingMetadata.description = "Drafted"
        model.markChanged()
        var reported: MetadataCommitResult?
        model.commitEditsReportingResult(mode: .historyOnly) { reported = $0 }
        #expect(reported == nil, "the completion must not run before the draft is written")
        let deadline = ContinuousClock.now + .seconds(5)
        while reported == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reported == .succeeded)
        #expect(MetadataSidecarService().loadSidecar(for: url, in: folder)?.metadata.description == "Drafted")
    }
}
