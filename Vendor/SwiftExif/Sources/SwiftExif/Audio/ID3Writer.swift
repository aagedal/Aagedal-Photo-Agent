import Foundation

/// Write ID3v2.3 tags to MP3 files.
public struct ID3Writer: Sendable {

    /// Write updated metadata to an MP3 file.
    public static func write(_ metadata: AudioMetadata, to originalData: Data) throws -> Data {
        // Find the end of existing ID3v2 tag (if any)
        let audioStart = findAudioStart(originalData)

        // Build new ID3v2.3 tag
        var frames = Data()

        if let title = metadata.title { frames.append(buildTextFrame("TIT2", text: title)) }
        if let artist = metadata.artist { frames.append(buildTextFrame("TPE1", text: artist)) }
        if let album = metadata.album { frames.append(buildTextFrame("TALB", text: album)) }
        if let track = metadata.trackNumber { frames.append(buildTextFrame("TRCK", text: String(track))) }
        if let disc = metadata.discNumber { frames.append(buildTextFrame("TPOS", text: String(disc))) }
        if let year = metadata.year { frames.append(buildTextFrame("TDRC", text: year)) }
        if let genre = metadata.genre { frames.append(buildTextFrame("TCON", text: genre)) }
        if let albumArtist = metadata.albumArtist { frames.append(buildTextFrame("TPE2", text: albumArtist)) }
        if let composer = metadata.composer { frames.append(buildTextFrame("TCOM", text: composer)) }
        if let comment = metadata.comment { frames.append(buildCommentFrame(comment)) }
        if let coverArt = metadata.coverArt { frames.append(buildAPICFrame(coverArt)) }

        // Add padding (1024 bytes for future in-place edits)
        let padding = Data(repeating: 0, count: 1024)
        let totalSize = frames.count + padding.count

        // Build ID3v2.3 header
        var header = Data()
        header.append(contentsOf: [0x49, 0x44, 0x33]) // "ID3"
        header.append(contentsOf: [0x03, 0x00])         // Version 2.3
        header.append(0x00)                              // Flags
        header.append(contentsOf: ID3Parser.encodeSyncsafe(totalSize))

        // Assemble: header + frames + padding + audio data
        var result = Data()
        result.append(header)
        result.append(frames)
        result.append(padding)
        result.append(originalData[audioStart...])

        return result
    }

    // MARK: - Frame Builders

    static func buildTextFrame(_ id: String, text: String) -> Data {
        let textData = Data([0x03]) + Data(text.utf8) // UTF-8 encoding byte + text
        var frame = Data()
        frame.append(Data(id.prefix(4).utf8))
        frame.append(contentsOf: encodeUInt32BE(UInt32(textData.count)))
        frame.append(contentsOf: [0x00, 0x00]) // Flags
        frame.append(textData)
        return frame
    }

    private static func buildCommentFrame(_ text: String) -> Data {
        // COMM: encoding (1) + language (3) + short desc (null-terminated) + text
        var content = Data()
        content.append(0x03) // UTF-8
        content.append(Data("eng".utf8)) // Language
        content.append(0x00) // Empty short description + null terminator
        content.append(Data(text.utf8))

        var frame = Data()
        frame.append(Data("COMM".utf8))
        frame.append(contentsOf: encodeUInt32BE(UInt32(content.count)))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(content)
        return frame
    }

    private static func buildAPICFrame(_ imageData: Data) -> Data {
        // APIC: encoding (1) + MIME (null-terminated) + picture type (1) + description (null-terminated) + data
        var content = Data()
        content.append(0x00) // ISO-8859-1 encoding
        content.append(Data("image/jpeg".utf8))
        content.append(0x00) // null terminator
        content.append(0x03) // Cover (front)
        content.append(0x00) // empty description + null
        content.append(imageData)

        var frame = Data()
        frame.append(Data("APIC".utf8))
        frame.append(contentsOf: encodeUInt32BE(UInt32(content.count)))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(content)
        return frame
    }

    // MARK: - Helpers

    /// Find where the audio data starts (after ID3v2 tag).
    private static func findAudioStart(_ data: Data) -> Int {
        guard data.count >= 10,
              data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33 else {
            return 0 // No ID3v2 tag
        }
        let tagSize = ID3Parser.decodeSyncsafe(data[6], data[7], data[8], data[9])
        return min(10 + tagSize, data.count)
    }

    private static func encodeUInt32BE(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
