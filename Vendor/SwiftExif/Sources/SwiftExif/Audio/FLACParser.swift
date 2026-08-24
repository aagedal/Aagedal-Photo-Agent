import Foundation

/// Parse FLAC metadata blocks.
public struct FLACParser: Sendable {

    static let magic = Data([0x66, 0x4C, 0x61, 0x43]) // "fLaC"

    /// Metadata block types.
    enum BlockType: UInt8 {
        case streaminfo = 0
        case padding = 1
        case application = 2
        case seektable = 3
        case vorbisComment = 4
        case cuesheet = 5
        case picture = 6
    }

    /// A parsed FLAC metadata block.
    struct MetadataBlock: Sendable {
        let type: UInt8
        let isLast: Bool
        let data: Data
    }

    /// Parse a FLAC file and extract metadata.
    public static func parse(_ data: Data) throws -> AudioMetadata {
        guard data.count >= 8 && data.prefix(4) == magic else {
            throw MetadataError.invalidFLAC("Invalid FLAC signature")
        }

        var metadata = AudioMetadata(format: .flac)
        let blocks = try parseBlocks(data)

        // STREAMINFO (type 0) -- always first block
        if let streaminfo = blocks.first(where: { $0.type == 0 }), streaminfo.data.count >= 18 {
            parseStreamInfo(streaminfo.data, into: &metadata)
        }

        // VORBIS_COMMENT (type 4)
        if let vorbisBlock = blocks.first(where: { $0.type == 4 }) {
            let vc = try VorbisComment.parse(vorbisBlock.data)
            metadata.title = vc.value(for: "TITLE")
            metadata.artist = vc.value(for: "ARTIST")
            metadata.album = vc.value(for: "ALBUM")
            metadata.year = vc.value(for: "DATE")
            metadata.genre = vc.value(for: "GENRE")
            metadata.comment = vc.value(for: "COMMENT") ?? vc.value(for: "DESCRIPTION")
            metadata.albumArtist = vc.value(for: "ALBUMARTIST")
            metadata.composer = vc.value(for: "COMPOSER")
            if let trackStr = vc.value(for: "TRACKNUMBER") { metadata.trackNumber = Int(trackStr) }
            if let discStr = vc.value(for: "DISCNUMBER") { metadata.discNumber = Int(discStr) }
        }

        // PICTURE (type 6)
        if let pictureBlock = blocks.first(where: { $0.type == 6 }) {
            metadata.coverArt = extractPicture(pictureBlock.data)
        }

        // SEEKTABLE (type 3)
        if let seekBlock = blocks.first(where: { $0.type == 3 }) {
            metadata.flacSeekTable = parseSeekTable(seekBlock.data)
        }

        // CUESHEET (type 5)
        if let cueBlock = blocks.first(where: { $0.type == 5 }) {
            metadata.flacCueSheet = parseCueSheet(cueBlock.data)
        }

        return metadata
    }

    /// SEEKTABLE block — N × 18-byte seek points.
    private static func parseSeekTable(_ data: Data) -> [FLACSeekPoint] {
        let pointSize = 18
        let count = data.count / pointSize
        guard count > 0 else { return [] }
        var result: [FLACSeekPoint] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let off = i * pointSize
            let sample = readUInt64BE(data, at: off)
            let offset = readUInt64BE(data, at: off + 8)
            let frameSamples = (UInt16(data[off + 16]) << 8) | UInt16(data[off + 17])
            result.append(FLACSeekPoint(sampleNumber: sample, byteOffset: offset, frameSamples: frameSamples))
        }
        return result
    }

    /// CUESHEET block:
    ///   bytes 0..127  : media catalog number (ASCII, NUL-padded)
    ///   bytes 128..135: lead-in samples (uint64)
    ///   byte 136 bit7 : isCD flag (1 = CD-DA)
    ///   bytes 137..395: reserved
    ///   byte 396      : number of tracks
    ///   then tracks...
    /// Track header (36 bytes):
    ///   bytes 0..7    : track offset (uint64)
    ///   byte 8        : track number
    ///   bytes 9..20   : ISRC (12 bytes ASCII)
    ///   byte 21 bit7  : track type (0=audio, 1=non-audio)
    ///   byte 21 bit6  : pre-emphasis
    ///   bytes 21..34  : reserved (top bits of byte 21 already used)
    ///   byte 35       : number of index points
    /// Each index point (12 bytes): offset(8) + number(1) + reserved(3).
    private static func parseCueSheet(_ data: Data) -> FLACCueSheet? {
        guard data.count >= 396 + 1 else { return nil }
        let mcnBytes = data.prefix(128)
        let mcn = String(data: mcnBytes, encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            .trimmingCharacters(in: .whitespaces) ?? ""
        let leadIn = readUInt64BE(data, at: 128)
        let isCD = (data[136] & 0x80) != 0
        let trackCount = Int(data[396])

        var tracks: [FLACCueTrack] = []
        var off = 397
        for _ in 0..<trackCount {
            guard off + 36 <= data.count else { break }
            let trackOffset = readUInt64BE(data, at: off)
            let trackNumber = data[off + 8]
            let isrcBytes = data[off + 9 ..< off + 21]
            let isrc = String(data: Data(isrcBytes), encoding: .ascii)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                .trimmingCharacters(in: .whitespaces) ?? ""
            let flagsByte = data[off + 21]
            let isAudio = (flagsByte & 0x80) == 0
            let preEmphasis = (flagsByte & 0x40) != 0
            let indexCount = Int(data[off + 35])
            off += 36

            var indices: [FLACCueIndex] = []
            for _ in 0..<indexCount {
                guard off + 12 <= data.count else { break }
                let idxOff = readUInt64BE(data, at: off)
                let idxNum = data[off + 8]
                indices.append(FLACCueIndex(indexOffset: idxOff, indexNumber: idxNum))
                off += 12
            }

            tracks.append(FLACCueTrack(
                trackOffset: trackOffset, trackNumber: trackNumber, isrc: isrc,
                isAudio: isAudio, preEmphasis: preEmphasis, indices: indices))
        }

        return FLACCueSheet(
            mediaCatalogNumber: mcn, leadInSamples: leadIn, isCD: isCD, tracks: tracks)
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v = (v << 8) | UInt64(data[offset + i])
        }
        return v
    }

    /// Parse all metadata blocks from a FLAC file.
    static func parseBlocks(_ data: Data) throws -> [MetadataBlock] {
        var blocks: [MetadataBlock] = []
        var offset = 4 // Skip "fLaC" magic

        while offset < data.count {
            guard offset + 4 <= data.count else { break }

            let header = data[offset]
            let isLast = (header & 0x80) != 0
            let blockType = header & 0x7F

            let blockLength = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4

            guard offset + blockLength <= data.count else { break }
            let blockData = Data(data[offset..<offset + blockLength])
            offset += blockLength

            blocks.append(MetadataBlock(type: blockType, isLast: isLast, data: blockData))

            if isLast { break }
        }

        return blocks
    }

    /// Parse STREAMINFO block for sample rate, channels, etc.
    private static func parseStreamInfo(_ data: Data, into metadata: inout AudioMetadata) {
        guard data.count >= 18 else { return }
        let s = data.startIndex

        // STREAMINFO layout:
        //   [0..1]   min block size (2)
        //   [2..3]   max block size (2)
        //   [4..6]   min frame size (3)
        //   [7..9]   max frame size (3)
        //   [10..12] 20 bits sample rate, 3 bits channels-1, 5 bits bits_per_sample-1 (split across byte 12/13)
        //   [13..17] 4 + 32 bits total samples
        //   [18..33] MD5 signature
        let sampleRate = (Int(data[s + 10]) << 12) | (Int(data[s + 11]) << 4) | (Int(data[s + 12]) >> 4)
        let channels = ((Int(data[s + 12]) >> 1) & 0x07) + 1
        let bitsPerSample = ((Int(data[s + 12]) & 0x01) << 4 | (Int(data[s + 13]) >> 4)) + 1

        let totalSamples = (UInt64(data[s + 13] & 0x0F) << 32) |
                           (UInt64(data[s + 14]) << 24) |
                           (UInt64(data[s + 15]) << 16) |
                           (UInt64(data[s + 16]) << 8) |
                           UInt64(data[s + 17])

        metadata.sampleRate = sampleRate
        metadata.channels = channels
        metadata.bitDepth = bitsPerSample
        metadata.codec = "flac"
        metadata.codecName = "FLAC"
        if sampleRate > 0, totalSamples > 0 {
            let duration = Double(totalSamples) / Double(sampleRate)
            metadata.duration = duration
            // FLAC is VBR — derive bitrate from (file-size - metadata) / duration if possible.
            // Use the whole-file size as a close-enough approximation; metadata blocks are tiny.
        }
    }

    /// Extract picture data from a PICTURE block.
    private static func extractPicture(_ data: Data) -> Data? {
        guard data.count > 32 else { return nil }
        var offset = 4 // Skip picture type

        // MIME type
        guard offset + 4 <= data.count else { return nil }
        let mimeLen = readUInt32BE(data, at: offset)
        offset += 4 + Int(mimeLen)

        // Description
        guard offset + 4 <= data.count else { return nil }
        let descLen = readUInt32BE(data, at: offset)
        offset += 4 + Int(descLen)

        // Width, height, depth, colors (4 * 4 bytes)
        offset += 16

        // Picture data
        guard offset + 4 <= data.count else { return nil }
        let picLen = readUInt32BE(data, at: offset)
        offset += 4
        guard offset + Int(picLen) <= data.count else { return nil }
        return Data(data[offset..<offset + Int(picLen)])
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
        UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
}
