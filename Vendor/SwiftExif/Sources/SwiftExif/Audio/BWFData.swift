import Foundation

/// Broadcast Wave Format (EBU Tech 3285 r2) `bext` chunk metadata.
///
/// Field set is universal across field recorders (Sound Devices, Zaxcom,
/// Tascam, AATON), DAWs (Pro Tools, Reaper, Logic), and post pipelines.
/// Loudness fields are only present for `version >= 2` (Tech 3285 from 2011).
public struct BWFMetadata: Sendable, Equatable {
    /// Free-form scene / take description (max 256 ASCII chars).
    public var description: String?
    /// Producer / facility identifier (max 32 ASCII chars).
    public var originator: String?
    /// Producer-assigned reference (max 32 ASCII chars).
    public var originatorReference: String?
    /// Original creation date — typically "yyyy-mm-dd" (10 ASCII chars).
    public var originationDate: String?
    /// Original creation time — "hh:mm:ss" (8 ASCII chars).
    public var originationTime: String?
    /// Sample count from midnight on `originationDate` (combined low + high
    /// 32-bit fields). Drives the file's start timecode when paired with
    /// the WAV `fmt` chunk's sample rate.
    public var timeReference: UInt64?
    /// `bext` schema version — 0, 1 (UMID added), or 2 (loudness added).
    public var version: UInt16?
    /// SMPTE Unique Material Identifier (basic 32 bytes or extended 64),
    /// present in `version >= 1`. Returned as the raw bytes.
    public var umid: Data?

    /// Integrated loudness in LUFS (BS.1770), `version >= 2` only.
    public var loudnessValue: Double?
    /// Loudness range in LU.
    public var loudnessRange: Double?
    /// Maximum True Peak in dBTP.
    public var maxTruePeakLevel: Double?
    /// Maximum momentary loudness in LUFS (400 ms window).
    public var maxMomentaryLoudness: Double?
    /// Maximum short-term loudness in LUFS (3 s window).
    public var maxShortTermLoudness: Double?

    /// CodingHistory free-form ASCII record. Each line is one processing
    /// step (sampler / processor / encoder / etc.).
    public var codingHistory: String?

    /// Raw `iXML` chunk payload, when present. Sound Devices, Aaton, and
    /// most modern field recorders write a comprehensive XML block here
    /// containing project / scene / take / circled / sound-roll / track-name
    /// and dozens of other production fields. Surfaced verbatim so callers
    /// can apply their own XML schema; the structured fields above cover
    /// what's universal.
    public var iXML: String?

    public init(
        description: String? = nil,
        originator: String? = nil,
        originatorReference: String? = nil,
        originationDate: String? = nil,
        originationTime: String? = nil,
        timeReference: UInt64? = nil,
        version: UInt16? = nil,
        umid: Data? = nil,
        loudnessValue: Double? = nil,
        loudnessRange: Double? = nil,
        maxTruePeakLevel: Double? = nil,
        maxMomentaryLoudness: Double? = nil,
        maxShortTermLoudness: Double? = nil,
        codingHistory: String? = nil,
        iXML: String? = nil
    ) {
        self.description = description
        self.originator = originator
        self.originatorReference = originatorReference
        self.originationDate = originationDate
        self.originationTime = originationTime
        self.timeReference = timeReference
        self.version = version
        self.umid = umid
        self.loudnessValue = loudnessValue
        self.loudnessRange = loudnessRange
        self.maxTruePeakLevel = maxTruePeakLevel
        self.maxMomentaryLoudness = maxMomentaryLoudness
        self.maxShortTermLoudness = maxShortTermLoudness
        self.codingHistory = codingHistory
        self.iXML = iXML
    }

    /// Reconstruct an HH:MM:SS:FF-style start timecode from `timeReference`
    /// + the WAV file's sample rate. Returns nil when either input is missing.
    public func startTimecode(sampleRate: Int, frameRate: Double = 24.0) -> String? {
        guard let samples = timeReference, sampleRate > 0, frameRate > 0 else { return nil }
        let totalSeconds = Double(samples) / Double(sampleRate)
        let h = Int(totalSeconds) / 3600
        let m = (Int(totalSeconds) % 3600) / 60
        let s = Int(totalSeconds) % 60
        let frac = totalSeconds - floor(totalSeconds)
        let frames = Int(frac * frameRate)
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, frames)
    }
}
