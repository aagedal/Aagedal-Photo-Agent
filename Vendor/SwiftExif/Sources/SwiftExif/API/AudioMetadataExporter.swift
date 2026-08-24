import Foundation

/// Export audio metadata in machine-readable formats.
public struct AudioMetadataExporter: Sendable {

    public static func buildDictionary(_ metadata: AudioMetadata) -> [String: Any] {
        var dict: [String: Any] = [:]

        dict["FileFormat"] = metadata.format.rawValue.uppercased()

        if let v = metadata.title { dict["Title"] = v }
        if let v = metadata.artist { dict["Artist"] = v }
        if let v = metadata.album { dict["Album"] = v }
        if let v = metadata.trackNumber { dict["TrackNumber"] = v }
        if let v = metadata.discNumber { dict["DiscNumber"] = v }
        if let v = metadata.year { dict["Year"] = v }
        if let v = metadata.genre { dict["Genre"] = v }
        if let v = metadata.comment { dict["Comment"] = v }
        if let v = metadata.duration { dict["Duration"] = String(format: "%.2f", v) }
        if let v = metadata.bitrate { dict["Bitrate"] = v }
        if let v = metadata.sampleRate { dict["SampleRate"] = v }
        if let v = metadata.channels { dict["Channels"] = v }
        if let v = metadata.bitDepth { dict["BitDepth"] = v }
        if let v = metadata.codec { dict["Codec"] = v }
        if let v = metadata.codecName { dict["CodecName"] = v }
        if let v = metadata.channelLayout { dict["ChannelLayout"] = v }
        if let v = metadata.albumArtist { dict["AlbumArtist"] = v }
        if let v = metadata.composer { dict["Composer"] = v }
        if metadata.coverArt != nil { dict["CoverArt"] = "(binary data)" }

        return dict
    }
}
