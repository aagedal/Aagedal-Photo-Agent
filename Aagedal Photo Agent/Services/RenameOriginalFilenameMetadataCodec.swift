import Foundation
import SwiftExif

nonisolated protocol RenameOriginalFilenameMetadataCodec: Sendable {
    func applying(
        _ mutation: RenameOriginalFilenameMetadataMutation,
        to originalData: Data
    ) throws -> Data
}

/// Produces replacement bytes without touching a live path. The executor writes those bytes only
/// after every rename source is staged, so embedded JPEG XMP and RAW sidecar XMP share exactly the
/// same commit and byte-for-byte rollback boundaries as filename moves.
nonisolated struct SwiftExifRenameOriginalFilenameMetadataCodec:
    RenameOriginalFilenameMetadataCodec,
    Sendable
{
    func applying(
        _ mutation: RenameOriginalFilenameMetadataMutation,
        to originalData: Data
    ) throws -> Data {
        guard mutation.namespaceURI == RenameOriginalFilenameMetadataMutation.namespaceURI,
              mutation.propertyName == RenameOriginalFilenameMetadataMutation.propertyName,
              !mutation.value.isEmpty else {
            throw CodecError.invalidMutation
        }

        switch mutation.storage {
        case .embeddedImageXMP:
            var metadata = try ImageMetadata.read(from: originalData)
            if metadata.xmp == nil { metadata.xmp = XMPData() }
            metadata.xmp?.setValue(
                .simple(mutation.value),
                namespace: mutation.namespaceURI,
                property: mutation.propertyName
            )
            return try metadata.writeToData()

        case .xmpSidecar:
            var xmp = try XMPReader.readFromXML(originalData)
            xmp.setValue(
                .simple(mutation.value),
                namespace: mutation.namespaceURI,
                property: mutation.propertyName
            )
            return XMPWriter.write(xmp)
        }
    }

    private enum CodecError: LocalizedError {
        case invalidMutation

        var errorDescription: String? {
            "The planned original-filename XMP mutation is invalid or unsupported"
        }
    }
}
