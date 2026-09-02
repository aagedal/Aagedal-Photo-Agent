import AppKit
import Foundation
import Testing
import SwiftMediaMetadata
@testable import Aagedal_Photo_Agent

@Suite("Metadata batch list selection", .serialized)
@MainActor
struct MetadataBatchSelectionTests {
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
