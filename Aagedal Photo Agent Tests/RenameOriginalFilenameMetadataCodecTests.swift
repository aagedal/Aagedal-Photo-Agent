import CoreGraphics
import Foundation
import ImageIO
import SwiftExif
import Testing
import UniformTypeIdentifiers
@testable import Aagedal_Photo_Agent

@Suite("Original filename XMP interoperability")
struct RenameOriginalFilenameMetadataCodecTests {
    private let codec = SwiftExifRenameOriginalFilenameMetadataCodec()

    @Test("External-tool mapping is exact for embedded JPEG XMP")
    func embeddedJPEGMapping() throws {
        let mutation = RenameOriginalFilenameMetadataMutation(
            storage: .embeddedImageXMP,
            value: "DSC_0042.JPG"
        )
        let updated = try codec.applying(mutation, to: makeJPEGData())
        let metadata = try ImageMetadata.read(from: updated)

        #expect(metadata.xmp?.simpleValue(
            namespace: "http://ns.adobe.com/xap/1.0/mm/",
            property: "PreservedFileName"
        ) == "DSC_0042.JPG")
        #expect(metadata.iptc.jobId == nil)
        #expect(metadata.xmp?.simpleValue(
            namespace: XMPNamespace.photoshop,
            property: "TransmissionReference"
        ) == nil)
    }

    @Test("RAW sidecar mapping preserves unrelated XMP")
    func rawSidecarMapping() throws {
        var original = XMPData()
        original.title = "Unrelated title"
        let mutation = RenameOriginalFilenameMetadataMutation(
            storage: .xmpSidecar,
            value: "DSC_0042.NEF"
        )
        let updated = try codec.applying(mutation, to: XMPWriter.write(original))
        let decoded = try XMPReader.readFromXML(updated)

        #expect(decoded.title == "Unrelated title")
        #expect(decoded.simpleValue(
            namespace: "http://ns.adobe.com/xap/1.0/mm/",
            property: "PreservedFileName"
        ) == "DSC_0042.NEF")
        #expect(decoded.jobId == nil)
    }

    private func makeJPEGData() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data as Data
    }
}
