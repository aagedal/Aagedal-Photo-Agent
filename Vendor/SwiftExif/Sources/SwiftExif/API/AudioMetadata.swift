import Foundation

/// Metadata for audio files (MP3, FLAC, M4A).
public struct AudioMetadata: Sendable {
    public var format: AudioFormat
    public var title: String?
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: String?
    public var genre: String?
    public var comment: String?
    public var duration: TimeInterval?
    public var bitrate: Int?
    public var sampleRate: Int?
    public var channels: Int?
    /// Bits per sample (e.g. 16 for CD audio, 24 for studio masters).
    public var bitDepth: Int?
    /// Short codec identifier ("mp3", "flac", "aac", "alac", …).
    public var codec: String?
    /// Human-readable codec name ("MP3", "FLAC", "AAC-LC", …).
    public var codecName: String?
    /// Channel layout label (e.g. "mono", "stereo", "5.1").
    public var channelLayout: String?
    public var albumArtist: String?
    public var composer: String?
    public var coverArt: Data?
    /// Broadcast Wave (`bext` + iXML) metadata when the source is a WAV /
    /// BWF file. Nil for non-WAV inputs and for plain RIFF WAVs that omit
    /// the BWF chunk.
    public var bwf: BWFMetadata?
    /// User-defined ID3v2 text frames (TXXX) — description → value. Common
    /// keys: "replaygain_track_gain", "MusicBrainz Album Id", "ALBUMARTIST"
    /// (in non-ASCII encodings), "BARCODE", podcast-style descriptions.
    public var userTextFrames: [String: String] = [:]
    /// User-defined ID3v2 URL frames (WXXX) — description → URL.
    public var userURLFrames: [String: String] = [:]
    /// Standard ID3v2 URL frames (WCOM, WCOP, WOAF, WOAR, WOAS, WORS, WPAY,
    /// WPUB) keyed by frame ID. Single-URL ASCII payloads.
    public var urlFrames: [String: String] = [:]
    /// ID3v2 PRIV (private) frames — owner identifier (URL/email) and
    /// arbitrary payload. iTunes/Sonos use these for app-specific state.
    public var privateFrames: [ID3PrivateFrame] = []
    /// ID3v2 GEOB (general encapsulated object) frames — embedded files.
    public var attachedObjects: [ID3AttachedObject] = []
    /// ID3v2 CHAP frames — podcast chapter segments with optional title and URL.
    public var chapters: [ID3Chapter] = []
    /// ID3v2 CTOC frames — chapter table-of-contents (top-level and nested).
    public var chapterTOCs: [ID3ChapterTOC] = []
    /// FLAC SEEKTABLE block — sparse index of seek points across the stream.
    /// Empty if the source has no seek table (typical for streaming-only FLAC).
    public var flacSeekTable: [FLACSeekPoint] = []
    /// FLAC CUESHEET block — track / index point structure for CD-rip-style FLAC files.
    public var flacCueSheet: FLACCueSheet?
    /// C2PA manifest store, when the source carries one. Currently surfaced
    /// for WAV/BWF (RIFF "C2PA" chunk).
    public var c2pa: C2PAData?
    public var warnings: [String]

    internal var originalData: Data?

    public init(format: AudioFormat) {
        self.format = format
        self.warnings = []
    }

    // MARK: - Reading

    public static func read(from url: URL) throws -> AudioMetadata {
        // Map rather than copy — FLAC/WAV/AIFF can be hundreds of MB and the
        // parsers only touch headers + tag chunks. Matches the rationale in
        // `ImageMetadata.read` and `VideoMetadata.loadContainerData`.
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let ext = url.pathExtension.lowercased()
        let format: AudioFormat
        if let detected = FormatDetector.detectAudio(data) {
            format = detected
        } else if let detected = FormatDetector.detectAudioFromExtension(ext) {
            format = detected
        } else {
            throw MetadataError.unsupportedFormat
        }
        return try read(from: data, format: format)
    }

    public static func read(from data: Data, format: AudioFormat) throws -> AudioMetadata {
        switch format {
        case .mp3:
            var m = try ID3Parser.parse(data)
            m.originalData = data
            return m
        case .flac:
            var m = try FLACParser.parse(data)
            m.originalData = data
            return m
        case .opus, .oggVorbis:
            var m = try OggReader.parse(data, format: format)
            m.originalData = data
            return m
        case .m4a:
            let vm = try MP4Parser.parse(data)
            var m = AudioMetadata(format: .m4a)
            m.title = vm.title
            m.artist = vm.artist
            m.comment = vm.comment
            m.duration = vm.duration

            // Pull codec/rate/channels/bitdepth from the first audio stream.
            if let stream = vm.audioStreams.first {
                m.sampleRate = stream.sampleRate
                m.channels = stream.channels
                m.bitDepth = stream.bitDepth
                m.codec = stream.codec
                m.codecName = stream.codecName
                m.channelLayout = stream.channelLayout
                if let bitRate = stream.bitRate { m.bitrate = bitRate }
            } else if let codec = vm.audioCodec {
                m.codec = codec
            }
            if m.sampleRate == nil { m.sampleRate = vm.audioSampleRate }
            if m.channels == nil { m.channels = vm.audioChannels }

            m.originalData = data
            return m
        case .wav:
            var m = try WAVParser.parse(data)
            m.originalData = data
            if let jumbf = C2PAReader.extractJUMBFFromRIFF(data) {
                do {
                    m.c2pa = try C2PAReader.parseManifestStore(from: jumbf)
                } catch {
                    m.warnings.append("C2PA parsing failed: \(error)")
                }
            }
            return m
        case .aiff:
            var m = try AIFFParser.parse(data)
            m.originalData = data
            return m
        }
    }

    // MARK: - Writing

    public func writeToData() throws -> Data {
        guard let original = originalData else {
            throw MetadataError.writeNotSupported("No original audio data available for writing")
        }
        switch format {
        case .mp3:
            return try ID3Writer.write(self, to: original)
        case .flac:
            return try FLACWriter.write(self, to: original)
        case .m4a:
            // M4A writing delegates to the video writer infrastructure
            var vm = try MP4Parser.parse(original)
            vm.title = title
            vm.artist = artist
            vm.comment = comment
            return try MP4Writer.write(vm, to: original)
        case .opus, .oggVorbis:
            throw MetadataError.writeNotSupported("Writing Ogg \(format == .opus ? "Opus" : "Vorbis") files is not supported")
        case .wav:
            return try WAVWriter.write(self, to: original)
        case .aiff:
            return try AIFFWriter.write(self, to: original)
        }
    }

    public func write(to url: URL) throws {
        let data = try writeToData()
        do {
            try AtomicFileWriter.replaceContents(of: url, with: data)
        } catch {
            throw MetadataError.fileWriteError("Audio write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Stripping

    public mutating func stripMetadata() {
        title = nil
        artist = nil
        album = nil
        trackNumber = nil
        discNumber = nil
        year = nil
        genre = nil
        comment = nil
        albumArtist = nil
        composer = nil
        coverArt = nil
        userTextFrames = [:]
        userURLFrames = [:]
        urlFrames = [:]
        privateFrames = []
        attachedObjects = []
        chapters = []
        chapterTOCs = []
    }
}

/// ID3v2 PRIV — private frame. Owner is typically a URL or email; payload
/// is opaque application data.
public struct ID3PrivateFrame: Sendable, Equatable {
    public var owner: String
    public var data: Data

    public init(owner: String, data: Data) {
        self.owner = owner
        self.data = data
    }
}

/// ID3v2 GEOB — general encapsulated object. Used to embed arbitrary files
/// (PDFs, lyrics files, ZIP archives) inside an MP3.
public struct ID3AttachedObject: Sendable, Equatable {
    public var mimeType: String
    public var filename: String
    public var description: String
    public var data: Data

    public init(mimeType: String, filename: String, description: String, data: Data) {
        self.mimeType = mimeType
        self.filename = filename
        self.description = description
        self.data = data
    }
}

/// ID3v2 CHAP — chapter segment with millisecond start/end times. Sub-frames
/// (TIT2, WXXX, etc.) are surfaced via `title` and `url`.
public struct ID3Chapter: Sendable, Equatable {
    public var elementID: String
    /// Chapter start in milliseconds.
    public var startTimeMs: UInt32
    /// Chapter end in milliseconds (0xFFFFFFFF = open-ended).
    public var endTimeMs: UInt32
    /// Byte offset to the first MPEG frame of the chapter (0xFFFFFFFF = unused).
    public var startOffset: UInt32
    /// Byte offset to the last MPEG frame of the chapter.
    public var endOffset: UInt32
    /// Title from the embedded TIT2 sub-frame, if present.
    public var title: String?
    /// URL from the embedded WXXX sub-frame, if present.
    public var url: String?

    public init(
        elementID: String,
        startTimeMs: UInt32, endTimeMs: UInt32,
        startOffset: UInt32, endOffset: UInt32,
        title: String? = nil, url: String? = nil
    ) {
        self.elementID = elementID
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.title = title
        self.url = url
    }
}

/// ID3v2 CTOC — table-of-contents grouping chapter element IDs.
/// `isTopLevel` and `isOrdered` come from the CTOC flags byte.
public struct ID3ChapterTOC: Sendable, Equatable {
    public var elementID: String
    public var isTopLevel: Bool
    public var isOrdered: Bool
    public var childElementIDs: [String]
    public var title: String?

    public init(
        elementID: String,
        isTopLevel: Bool, isOrdered: Bool,
        childElementIDs: [String],
        title: String? = nil
    ) {
        self.elementID = elementID
        self.isTopLevel = isTopLevel
        self.isOrdered = isOrdered
        self.childElementIDs = childElementIDs
        self.title = title
    }
}

/// One seek point inside a FLAC SEEKTABLE block.
public struct FLACSeekPoint: Sendable, Equatable {
    /// Sample number of the first sample in the target frame (0xFFFFFFFFFFFFFFFF
    /// indicates a placeholder point reserved for later).
    public var sampleNumber: UInt64
    /// Byte offset of the target frame relative to the first frame.
    public var byteOffset: UInt64
    /// Number of samples in the target frame.
    public var frameSamples: UInt16

    public init(sampleNumber: UInt64, byteOffset: UInt64, frameSamples: UInt16) {
        self.sampleNumber = sampleNumber
        self.byteOffset = byteOffset
        self.frameSamples = frameSamples
    }
}

/// A FLAC CUESHEET block — typically used by CD-rip FLACs to preserve the
/// disc table-of-contents.
public struct FLACCueSheet: Sendable, Equatable {
    /// Media catalog number (ASCII, padded with NUL). Empty for CD-DA.
    public var mediaCatalogNumber: String
    /// Lead-in samples (only meaningful for CD-DA).
    public var leadInSamples: UInt64
    /// True if the cue sheet describes a CD-DA disc.
    public var isCD: Bool
    /// Track entries.
    public var tracks: [FLACCueTrack]

    public init(mediaCatalogNumber: String, leadInSamples: UInt64, isCD: Bool, tracks: [FLACCueTrack]) {
        self.mediaCatalogNumber = mediaCatalogNumber
        self.leadInSamples = leadInSamples
        self.isCD = isCD
        self.tracks = tracks
    }
}

/// One track inside a FLAC CUESHEET.
public struct FLACCueTrack: Sendable, Equatable {
    public var trackOffset: UInt64
    public var trackNumber: UInt8
    public var isrc: String
    public var isAudio: Bool
    public var preEmphasis: Bool
    public var indices: [FLACCueIndex]

    public init(trackOffset: UInt64, trackNumber: UInt8, isrc: String, isAudio: Bool, preEmphasis: Bool, indices: [FLACCueIndex]) {
        self.trackOffset = trackOffset
        self.trackNumber = trackNumber
        self.isrc = isrc
        self.isAudio = isAudio
        self.preEmphasis = preEmphasis
        self.indices = indices
    }
}

/// One index point inside a FLAC CUESHEET track.
public struct FLACCueIndex: Sendable, Equatable {
    public var indexOffset: UInt64
    public var indexNumber: UInt8

    public init(indexOffset: UInt64, indexNumber: UInt8) {
        self.indexOffset = indexOffset
        self.indexNumber = indexNumber
    }
}
