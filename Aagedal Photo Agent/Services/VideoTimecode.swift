import Foundation
import AVFoundation

/// Interprets QuickTime timecode samples using their own cadence and drop-frame flags.
/// Reference: https://developer.apple.com/library/archive/technotes/tn2310/_index.html
nonisolated struct VideoTimecode: Sendable {
    struct Segment: Sendable {
        let origin: CMTime
        var end: CMTime
        let startFrame: Int64
        let frameDuration: CMTime
        let nominalRate: Int
        let dropFrame: Bool
        let wrapsAt24Hours: Bool

        func frame(at time: CMTime) -> Int64 {
            startFrame + Int64((CMTimeSubtract(time, origin).seconds / frameDuration.seconds).rounded())
        }
    }

    let segments: [Segment]
    let relativeFrameDuration: CMTime
    let relativeNominalRate: Int
    var hasSourceTimecode: Bool { !segments.isEmpty }

    func label(at time: CMTime) -> String {
        if let segment = segments.last(where: { CMTimeCompare($0.origin, time) <= 0 && CMTimeCompare(time, $0.end) <= 0 }) {
            return Self.format(frame: segment.frame(at: time), nominalRate: segment.nominalRate,
                               dropFrame: segment.dropFrame, wrapsAt24Hours: segment.wrapsAt24Hours)
        }
        let frame = Int64(max(0, time.seconds / relativeFrameDuration.seconds).rounded())
        return Self.format(frame: frame, nominalRate: relativeNominalRate, dropFrame: false)
    }

    static func format(frame: Int64, nominalRate: Int, dropFrame: Bool, wrapsAt24Hours: Bool = true) -> String {
        let rate = Int64(max(1, nominalRate))
        let dropped = dropFrame && (rate == 30 || rate == 60) ? rate / 15 : 0
        let framesPerTenMinutes = rate * 600 - dropped * 9
        var value = abs(frame)
        if wrapsAt24Hours { value %= framesPerTenMinutes * 144 }
        if dropped > 0 {
            let tens = value / framesPerTenMinutes
            let remainder = value % framesPerTenMinutes
            value += dropped * 9 * tens
            if remainder >= dropped { value += dropped * ((remainder - dropped) / (rate * 60 - dropped)) }
        }
        let separator = dropped > 0 ? ";" : ":"
        return String(format: "%@%02lld:%02lld:%02lld%@%02lld", frame < 0 ? "-" : "",
                      value / (rate * 3600), (value / (rate * 60)) % 60,
                      (value / rate) % 60, separator, value % rate)
    }

    static func load(url: URL) async throws -> Self {
        try await Task.detached(priority: .userInitiated) {
            try await loadLocal(url: url)
        }.value
    }

    private static func loadLocal(url: URL) async throws -> Self {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let rate = Double(try await videoTrack.load(.nominalFrameRate))
        guard rate.isFinite, rate > 0, rate <= 240 else { throw CocoaError(.fileReadCorruptFile) }
        let nominalRate = Int(rate.rounded())
        let frameDuration: CMTime
        if abs(rate - Double(nominalRate) * 1000 / 1001) < 0.002 {
            frameDuration = CMTime(value: 1001, timescale: Int32(nominalRate * 1000))
        } else {
            frameDuration = CMTime(seconds: 1 / rate, preferredTimescale: 600000)
        }
        guard let track = try await asset.loadTracks(withMediaType: .timecode).first else {
            return Self(segments: [], relativeFrameDuration: frameDuration, relativeNominalRate: nominalRate)
        }
        let trackDescriptions = try await track.load(.formatDescriptions)
        let segments: [Segment] = try {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
            defer { reader.cancelReading() }
            var segments: [Segment] = []
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                // AVAssetReader also emits empty boundary/attachment marker buffers.
                if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                guard let description = CMSampleBufferGetFormatDescription(sample) ?? trackDescriptions.first,
                      let data = CMSampleBufferGetDataBuffer(sample) else { throw CocoaError(.fileReadCorruptFile) }
                let type = CMFormatDescriptionGetMediaSubType(description)
                let start: Int64
                if type == kCMTimeCodeFormatType_TimeCode32 {
                    var value: Int32 = 0
                    guard CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: 4, destination: &value) == noErr else { throw CocoaError(.fileReadCorruptFile) }
                    start = Int64(Int32(bigEndian: value))
                } else if type == kCMTimeCodeFormatType_TimeCode64 {
                    var value: Int64 = 0
                    guard CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: 8, destination: &value) == noErr else { throw CocoaError(.fileReadCorruptFile) }
                    start = Int64(bigEndian: value)
                } else { throw CocoaError(.fileReadCorruptFile) }
                let duration = CMTimeCodeFormatDescriptionGetFrameDuration(description)
                let nominal = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(description))
                let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(description)
                guard duration.seconds.isFinite, duration.seconds > 0, nominal > 0, nominal <= 240 else { throw CocoaError(.fileReadCorruptFile) }
                let origin = CMSampleBufferGetPresentationTimeStamp(sample)
                let end = CMTimeAdd(origin, CMSampleBufferGetDuration(sample))
                let segment = Segment(origin: origin, end: end, startFrame: start, frameDuration: duration,
                                      nominalRate: nominal, dropFrame: flags & kCMTimeCodeFlag_DropFrame != 0,
                                      wrapsAt24Hours: flags & kCMTimeCodeFlag_24HourMax != 0)
                // Collapse continuous per-frame samples while retaining edits and timecode jumps.
                if let last = segments.last, last.frame(at: origin) == start,
                   CMTimeCompare(last.end, origin) == 0, CMTimeCompare(last.frameDuration, duration) == 0,
                   last.nominalRate == nominal, last.dropFrame == segment.dropFrame,
                   last.wrapsAt24Hours == segment.wrapsAt24Hours {
                    segments[segments.count - 1].end = end
                } else { segments.append(segment) }
            }
            if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
            guard !segments.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return segments
        }()
        return Self(segments: segments, relativeFrameDuration: frameDuration, relativeNominalRate: nominalRate)
    }
}
