import Foundation

/// Write metadata to FLAC files by replacing the VORBIS_COMMENT block.
public struct FLACWriter: Sendable {

    /// Write updated metadata to a FLAC file.
    public static func write(_ metadata: AudioMetadata, to originalData: Data) throws -> Data {
        guard originalData.count >= 8 && originalData.prefix(4) == FLACParser.magic else {
            throw MetadataError.invalidFLAC("Invalid FLAC signature")
        }

        let blocks = try FLACParser.parseBlocks(originalData)

        // Find where audio frames start (after all metadata blocks)
        var audioOffset = 4 // After "fLaC"
        for block in blocks {
            audioOffset += 4 + block.data.count // header (4) + data
        }

        // Build new Vorbis Comment
        var vc = VorbisComment(vendor: "SwiftExif")

        // Try to preserve existing vendor string
        if let existingVC = blocks.first(where: { $0.type == 4 }),
           let existing = try? VorbisComment.parse(existingVC.data) {
            vc.vendor = existing.vendor
        }

        if let v = metadata.title { vc.setValue(v, for: "TITLE") }
        if let v = metadata.artist { vc.setValue(v, for: "ARTIST") }
        if let v = metadata.album { vc.setValue(v, for: "ALBUM") }
        if let v = metadata.trackNumber { vc.setValue(String(v), for: "TRACKNUMBER") }
        if let v = metadata.discNumber { vc.setValue(String(v), for: "DISCNUMBER") }
        if let v = metadata.year { vc.setValue(v, for: "DATE") }
        if let v = metadata.genre { vc.setValue(v, for: "GENRE") }
        if let v = metadata.comment { vc.setValue(v, for: "COMMENT") }
        if let v = metadata.albumArtist { vc.setValue(v, for: "ALBUMARTIST") }
        if let v = metadata.composer { vc.setValue(v, for: "COMPOSER") }

        let vcData = vc.serialize()

        // Rebuild file: magic + metadata blocks + audio data
        var result = Data()
        result.append(FLACParser.magic)

        // Write all blocks except VORBIS_COMMENT (type 4) and PADDING (type 1)
        var remainingBlocks = blocks.filter { $0.type != 4 && $0.type != 1 }

        // Add new VORBIS_COMMENT block
        let vcBlock = FLACParser.MetadataBlock(type: 4, isLast: false, data: vcData)

        // Insert VORBIS_COMMENT after STREAMINFO (if present)
        if let streaminfoIdx = remainingBlocks.firstIndex(where: { $0.type == 0 }) {
            remainingBlocks.insert(vcBlock, at: streaminfoIdx + 1)
        } else {
            remainingBlocks.insert(vcBlock, at: 0)
        }

        // Add padding block (4096 bytes)
        let paddingBlock = FLACParser.MetadataBlock(type: 1, isLast: false, data: Data(repeating: 0, count: 4096))
        remainingBlocks.append(paddingBlock)

        // Write blocks with correct last-block flags
        for (i, block) in remainingBlocks.enumerated() {
            let isLast = (i == remainingBlocks.count - 1)
            let headerByte = (isLast ? UInt8(0x80) : 0) | block.type
            result.append(headerByte)
            let length = block.data.count
            result.append(UInt8((length >> 16) & 0xFF))
            result.append(UInt8((length >> 8) & 0xFF))
            result.append(UInt8(length & 0xFF))
            result.append(block.data)
        }

        // Append audio frames
        if audioOffset < originalData.count {
            result.append(originalData[audioOffset...])
        }

        return result
    }
}
