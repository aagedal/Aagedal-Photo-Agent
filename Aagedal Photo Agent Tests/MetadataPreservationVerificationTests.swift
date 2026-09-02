import AppKit
import Foundation
import SwiftMediaMetadata
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Unrelated metadata preservation verification")
struct MetadataPreservationVerificationTests {
    private let newsroomNamespace = "https://aagedal.example/ns/newsroom/1.0/"

    @Test("identical supported snapshots match in every unrelated domain")
    func identicalSnapshotsMatch() throws {
        let source = try makeTypedMetadata()
        let snapshot = MetadataPreservationSnapshotBuilder.makeSnapshot(from: source)
        let report = MetadataPreservationComparator.compare(source: snapshot, staged: snapshot)

        #expect(report.domains.map(\.status) == [.match, .match, .match, .match])
        #expect(!report.hasProvenMismatch)
        #expect(report.isAcceptableForDelivery)
        #expect(report.c2paConsequence == .absentFromBoth)
    }

    @Test("changed unmodeled XMP is a proven typed mismatch")
    func changedUnmodeledXMP() throws {
        let source = try makeTypedMetadata()
        var staged = source
        staged.xmp?.setValue(.simple("Sports"), namespace: newsroomNamespace, property: "Desk")

        let report = compare(source, staged)
        #expect(report.mismatchedDomains == [.xmp])
        #expect(report.hasProvenMismatch)
        #expect(!report.isAcceptableForDelivery)
        #expect(status(.iptc, in: report) == .match)
        #expect(status(.cameraRaw, in: report) == .match)
    }

    @Test("removed unrelated IPTC dataset is distinguished from an empty controlled field")
    func removedUnrelatedIPTC() throws {
        let source = try makeTypedMetadata()
        var staged = source
        staged.iptc = IPTCData(datasets: staged.iptc.datasets.filter { $0.tag != .editStatus })

        let report = compare(source, staged)
        #expect(report.mismatchedDomains == [.iptc])
        #expect(status(.xmp, in: report) == .match)
    }

    @Test("unsupported and unknown carrier capabilities never masquerade as loss")
    func unsupportedAndUnknown() {
        let unsupported = MetadataPreservationSnapshotBuilder.makeSnapshot(
            from: ImageMetadata(format: .bmp)
        )
        let unsupportedReport = MetadataPreservationComparator.compare(
            source: unsupported,
            staged: unsupported
        )
        #expect(unsupportedReport.domains.allSatisfy { $0.status == .unsupported })
        #expect(unsupportedReport.c2paConsequence == .unsupported)
        #expect(!unsupportedReport.hasProvenMismatch)
        #expect(unsupportedReport.isAcceptableForDelivery)

        let unknown = MetadataPreservationSnapshotBuilder.makeSnapshot(
            from: ImageMetadata(format: .pdf)
        )
        let unknownReport = MetadataPreservationComparator.compare(source: unknown, staged: unknown)
        #expect(unknownReport.domains.allSatisfy { $0.status == .unknown })
        #expect(!unknownReport.hasProvenMismatch)
        #expect(!unknownReport.isAcceptableForDelivery)
    }

    @Test("profile-controlled descriptive fields are excluded while unrelated identities remain")
    func controlledFieldsAreExcluded() throws {
        let source = try makeTypedMetadata()
        var staged = source
        staged.iptc = IPTCData(datasets: [
            try IPTCDataSet(tag: .headline, stringValue: "Replacement headline"),
            try IPTCDataSet(tag: .captionAbstract, stringValue: "Replacement caption"),
            try IPTCDataSet(tag: .editStatus, stringValue: "untouched-unmodeled"),
        ])
        staged.xmp?.setValue(
            .simple("Replacement headline"),
            namespace: XMPNamespace.photoshop,
            property: "Headline"
        )
        staged.xmp?.setValue(
            .langAlternative("Replacement caption"),
            namespace: XMPNamespace.dc,
            property: "description"
        )

        let report = compare(source, staged)
        #expect(status(.iptc, in: report) == .match)
        #expect(status(.xmp, in: report) == .match)
        #expect(!report.hasProvenMismatch)
        #expect(report.isAcceptableForDelivery)
    }

    @Test("TIFF carrier tags, relocated offsets, and IIM UTF-8 declaration are serialization shells")
    func tiffSerializationShellsAreExcluded() throws {
        var source = ImageMetadata(format: .tiff)
        var sourceEXIF = ExifData(byteOrder: .bigEndian)
        sourceEXIF.ifd0 = IFD(entries: [
            entry(tag: 0x010F, text: "Example Camera"),
            entry(tag: 0x0111, long: 8),
        ])
        source.exif = sourceEXIF

        var staged = source
        staged.exif?.ifd0 = IFD(entries: [
            entry(tag: 0x010F, text: "Example Camera"),
            entry(tag: 0x0111, long: 4096),
            entry(tag: 0x02BC, bytes: Data("controlled XMP carrier".utf8)),
            entry(tag: 0x8649, bytes: Data("controlled IIM carrier".utf8)),
        ])
        staged.iptc = IPTCData(datasets: [
            IPTCDataSet(tag: .codedCharacterSet, rawValue: Data([0x1B, 0x25, 0x47])),
            try IPTCDataSet(tag: .headline, stringValue: "Replacement — headline"),
        ])
        var controlledXMP = XMPData()
        controlledXMP.setValue(
            .simple("Replacement — headline"),
            namespace: XMPNamespace.photoshop,
            property: "Headline"
        )
        staged.xmp = controlledXMP

        let preserved = compare(source, staged)
        #expect(status(.exif, in: preserved) == .match)
        #expect(status(.iptc, in: preserved) == .match)
        #expect(status(.xmp, in: preserved) == .match)
        #expect(preserved.isAcceptableForDelivery)

        staged.exif?.ifd0 = IFD(entries: [
            entry(tag: 0x010F, text: "Different Camera"),
            entry(tag: 0x0111, long: 4096),
            entry(tag: 0x02BC, bytes: Data("controlled XMP carrier".utf8)),
            entry(tag: 0x8649, bytes: Data("controlled IIM carrier".utf8)),
        ])
        staged.iptc = IPTCData(datasets: staged.iptc.datasets + [
            try IPTCDataSet(tag: .editStatus, stringValue: "unrelated change"),
        ])
        let damaged = compare(source, staged)
        #expect(Set(damaged.mismatchedDomains) == [.exif, .iptc])
    }

    @Test("Camera Raw identity is checked for exact copies and explicitly unsupported for renders")
    func cameraRawCapabilityIsExplicit() throws {
        let source = try makeTypedMetadata()
        var staged = source
        staged.xmp?.setValue(.simple("+44"), namespace: XMPNamespace.crs, property: "Texture")

        let exact = compare(source, staged, policy: .exactCopy)
        #expect(status(.cameraRaw, in: exact) == .mismatch)
        #expect(status(.xmp, in: exact) == .match)

        let rendered = compare(source, staged, policy: .renderedDelivery)
        #expect(status(.cameraRaw, in: rendered) == .unsupported)
        #expect(!rendered.hasProvenMismatch)
        #expect(rendered.isAcceptableForDelivery)
    }

    @Test("render-owned orientation, dimensions, and CreatorTool are excluded by rendition policy")
    func renderedFactsAreExcluded() throws {
        let source = try makeTypedMetadata()
        var staged = source
        staged.exif?.ifd0 = IFD(entries: [
            entry(tag: 0x010F, text: "Example Camera"),
            entry(tag: 0x0112, short: 1),
        ])
        staged.xmp?.setValue(
            .simple("Aagedal Photo Agent 2"),
            namespace: XMPNamespace.xmp,
            property: "CreatorTool"
        )

        let exact = compare(source, staged, policy: .exactCopy)
        #expect(status(.exif, in: exact) == .mismatch)
        #expect(status(.xmp, in: exact) == .mismatch)

        let rendered = compare(source, staged, policy: .renderedDelivery)
        #expect(status(.exif, in: rendered) == .match)
        #expect(status(.xmp, in: rendered) == .match)
        #expect(!rendered.hasProvenMismatch)
        #expect(rendered.isAcceptableForDelivery)
    }

    @Test("real embedded JPEG preserves complex XMP across a controlled caption write")
    func realEmbeddedJPEGControlledWrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataPreservation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = try makeJPEG(in: directory, name: "source.jpg")
        var sourceMetadata = try ImageMetadata.read(from: sourceURL)
        sourceMetadata.xmp = try XMPReader.readFromXML(Data(contentsOf: complexXMPFixtureURL))
        sourceMetadata.iptc = IPTCData(datasets: [
            try IPTCDataSet(tag: .headline, stringValue: "Old controlled headline"),
            try IPTCDataSet(tag: .captionAbstract, stringValue: "Old controlled caption"),
            try IPTCDataSet(tag: .editStatus, stringValue: "unmodeled-status"),
        ])
        try sourceMetadata.write(to: sourceURL)

        let stagedURL = directory.appendingPathComponent("staged.jpg")
        try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
        try await SwiftExifWriteEngine().writeFields(
            [
                .headline: "New controlled headline",
                .description: "New controlled caption",
            ],
            to: [stagedURL]
        )

        let source = try ImageMetadata.read(from: sourceURL)
        let staged = try ImageMetadata.read(from: stagedURL)
        let report = compare(source, staged, policy: .exactCopy)
        #expect(!report.hasProvenMismatch)
        #expect(report.isAcceptableForDelivery)
        #expect(status(.iptc, in: report) == .match)
        #expect(status(.xmp, in: report) == .match)
        #expect(status(.cameraRaw, in: report) == .match)

        var damaged = staged
        damaged.xmp?.setValue(.simple("Local"), namespace: newsroomNamespace, property: "Desk")
        try damaged.write(to: stagedURL)
        let damagedReport = compare(source, try ImageMetadata.read(from: stagedURL))
        #expect(damagedReport.mismatchedDomains == [.xmp])
    }

    @Test("live adapter reports unreadable input as unknown instead of throwing or proving loss")
    func liveAdapterUnknown() async {
        let report = await DeliveryStageMetadataPreservationVerifier.liveRenderedDelivery.verify(
            URL(fileURLWithPath: "/private/tmp/does-not-exist-preservation.jpg"),
            Data([0x00, 0x01]),
            URL(fileURLWithPath: "/private/tmp/staged-invalid.jpg")
        )
        #expect(report.domains.allSatisfy { $0.status == .unknown })
        #expect(report.c2paConsequence == .unknown)
        #expect(!report.hasProvenMismatch)
        #expect(!report.isAcceptableForDelivery)
    }

    // MARK: Helpers

    private func makeTypedMetadata() throws -> ImageMetadata {
        var metadata = ImageMetadata(format: .jpeg)
        metadata.iptc = IPTCData(datasets: [
            try IPTCDataSet(tag: .headline, stringValue: "Controlled headline"),
            try IPTCDataSet(tag: .captionAbstract, stringValue: "Controlled caption"),
            try IPTCDataSet(tag: .editStatus, stringValue: "untouched-unmodeled"),
        ])
        var xmp = XMPData()
        xmp.setValue(
            .simple("Controlled headline"),
            namespace: XMPNamespace.photoshop,
            property: "Headline"
        )
        xmp.setValue(
            .langAlternative("Controlled caption"),
            namespace: XMPNamespace.dc,
            property: "description"
        )
        xmp.setValue(.simple("International"), namespace: newsroomNamespace, property: "Desk")
        xmp.setValue(.simple("+18"), namespace: XMPNamespace.crs, property: "Texture")
        metadata.xmp = xmp

        var exif = ExifData(byteOrder: .bigEndian)
        exif.ifd0 = IFD(entries: [
            entry(tag: 0x010F, text: "Example Camera"),
            entry(tag: 0x0112, short: 8),
        ])
        metadata.exif = exif
        return metadata
    }

    private func compare(
        _ source: ImageMetadata,
        _ staged: ImageMetadata,
        policy: MetadataPreservationSnapshotPolicy = .exactCopy
    ) -> MetadataPreservationVerificationReport {
        MetadataPreservationComparator.compare(
            source: MetadataPreservationSnapshotBuilder.makeSnapshot(from: source, policy: policy),
            staged: MetadataPreservationSnapshotBuilder.makeSnapshot(from: staged, policy: policy)
        )
    }

    private func status(
        _ domain: MetadataPreservationDomain,
        in report: MetadataPreservationVerificationReport
    ) -> MetadataPreservationComparisonStatus? {
        report.domains.first(where: { $0.domain == domain })?.status
    }

    private func entry(tag: UInt16, text: String) -> IFDEntry {
        IFDEntry(
            tag: tag,
            type: .ascii,
            count: UInt32(text.utf8.count + 1),
            valueData: Data(text.utf8) + Data([0])
        )
    }

    private func entry(tag: UInt16, short value: UInt16) -> IFDEntry {
        IFDEntry(
            tag: tag,
            type: .short,
            count: 1,
            valueData: Data([UInt8(value >> 8), UInt8(value & 0xff)])
        )
    }

    private func entry(tag: UInt16, long value: UInt32) -> IFDEntry {
        IFDEntry(
            tag: tag,
            type: .long,
            count: 1,
            valueData: Data([
                UInt8(value >> 24), UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
            ])
        )
    }

    private func entry(tag: UInt16, bytes: Data) -> IFDEntry {
        IFDEntry(tag: tag, type: .undefined, count: UInt32(bytes.count), valueData: bytes)
    }

    private var complexXMPFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/EditorialMetadata/preservation-complex.xmp")
    }

    private func makeJPEG(in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard let representation = NSBitmapImageRep(
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
        ), let data = representation.representation(using: .jpeg, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
        return url
    }
}
