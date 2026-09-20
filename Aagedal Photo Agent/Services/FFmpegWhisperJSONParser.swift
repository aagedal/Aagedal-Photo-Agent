import Foundation

/// Evidence emitted by the attributed FFmpeg 9.0.1 whisper filter, not whisper-cli JSON.
/// This is an inference result only: it grants no source identity or transcript approval.
nonisolated struct FFmpegWhisperTranscript: Equatable, Sendable {
    struct Segment: Equatable, Sendable, Decodable {
        let start: Int64
        let end: Int64
        let text: String

        var startMilliseconds: Int64 { start }
        var endMilliseconds: Int64 { end }
    }

    let segments: [Segment]
    let editableText: String

    /// This upstream format emits no language evidence, including for automatic detection.
    var detectedLanguage: String? { nil }
}

nonisolated enum FFmpegWhisperJSONError: Error, Equatable, Sendable {
    case outputTooLarge
    case segmentTooLarge
    case tooManySegments
    case textTooLarge
    case malformedSegment(line: Int)
    case invalidTiming(line: Int)
    case noSpeech
}

/// Parses the exact newline-delimited JSON shape of the attributed FFmpeg whisper emitter.
/// Call only after successful subprocess completion; even a complete last line cannot prove that
/// the producer finished. The future output reader must enforce the same byte cap while reading.
nonisolated enum FFmpegWhisperJSONParser {
    static let maximumOutputBytes = 8 * 1024 * 1024
    static let maximumSegmentBytes = 64 * 1024
    static let maximumSegments = 20_000
    static let maximumTextBytes = 2 * 1024 * 1024

    static func parse(_ data: Data) throws -> FFmpegWhisperTranscript {
        guard data.count <= maximumOutputBytes else { throw FFmpegWhisperJSONError.outputTooLarge }
        // Match the emitter's exact key order, integer representation and JSON string grammar.
        // This also rejects duplicate/unknown keys, nesting, booleans and fractional timestamps
        // before Foundation decoding can silently normalize them.
        let shape = try NSRegularExpression(pattern:
            #"^\s*\{\s*"start"\s*:\s*(-?(?:0|[1-9][0-9]*))\s*,\s*"end"\s*:\s*(-?(?:0|[1-9][0-9]*))\s*,\s*"text"\s*:\s*"(?:[^"\\\x00-\x1F]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"\s*\}\s*$"#)
        let decoder = JSONDecoder()
        var segments: [FFmpegWhisperTranscript.Segment] = []
        var textParts: [String] = []
        var textBytes = 0
        var previousStart: Int64 = 0

        var cursor = data.startIndex
        var lineNumber = 0
        while cursor < data.endIndex {
            let end = data[cursor...].firstIndex(of: 0x0A) ?? data.endIndex
            let bytes = data[cursor..<end]
            cursor = end == data.endIndex ? end : data.index(after: end)
            lineNumber += 1
            guard bytes.count <= maximumSegmentBytes else { throw FFmpegWhisperJSONError.segmentTooLarge }
            guard let line = String(data: Data(bytes), encoding: .utf8) else {
                throw FFmpegWhisperJSONError.malformedSegment(line: lineNumber)
            }
            if line.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) { continue }
            guard segments.count < maximumSegments else { throw FFmpegWhisperJSONError.tooManySegments }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard shape.firstMatch(in: line, range: range)?.range == range,
                  let segment = try? decoder.decode(FFmpegWhisperTranscript.Segment.self, from: Data(bytes)) else {
                throw FFmpegWhisperJSONError.malformedSegment(line: lineNumber)
            }
            // Preserve overlaps and zero-length evidence; only backward starts/reversed or
            // negative intervals are invalid. Timing remains integer milliseconds without rounding.
            guard segment.start >= previousStart, segment.end >= segment.start else {
                throw FFmpegWhisperJSONError.invalidTiming(line: lineNumber)
            }
            previousStart = segment.start
            segments.append(segment)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                textBytes += text.utf8.count + (textParts.isEmpty ? 0 : 1)
                guard textBytes <= maximumTextBytes else { throw FFmpegWhisperJSONError.textTooLarge }
                textParts.append(text)
            }
        }
        guard !textParts.isEmpty else { throw FFmpegWhisperJSONError.noSpeech }
        return FFmpegWhisperTranscript(segments: segments, editableText: textParts.joined(separator: " "))
    }
}
