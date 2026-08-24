import Foundation

/// Supported audio file formats.
public enum AudioFormat: String, Sendable, Equatable {
    case mp3
    case flac
    case m4a
    /// Ogg Vorbis (.ogg/.oga)
    case oggVorbis
    /// Ogg Opus (.opus)
    case opus
    /// RIFF WAVE / Broadcast WAVE (.wav, .bwf, .wave). The reader decodes the
    /// Broadcast WAVE `bext` chunk plus iXML, INFO, and ID3 sub-chunks.
    case wav
    /// Apple Audio Interchange File Format (.aiff, .aif). Big-endian sibling
    /// of WAV with NAME / AUTH / (c) / ANNO / COMT chunks.
    case aiff
}
