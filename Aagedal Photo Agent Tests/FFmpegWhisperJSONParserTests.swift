import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("FFmpeg Whisper canonical JSON")
struct FFmpegWhisperJSONParserTests {
    @Test("NDJSON retains exact millisecond evidence and derives a Nordic editable draft")
    func canonicalOutput() throws {
        let input = #"{"start":0,"end":1240,"text":"  Hei, æøå!  "}"# + "\r\n" +
            #"{"start":1200,"end":2500,"text":"Blåbær fra Ålesund."}"# + "\n"
        let result = try FFmpegWhisperJSONParser.parse(Data(input.utf8))
        #expect(result.editableText == "Hei, æøå! Blåbær fra Ålesund.")
        #expect(result.segments.count == 2)
        #expect(result.segments[0].text == "  Hei, æøå!  ")
        #expect(result.segments[1].startMilliseconds == 1200)
        #expect(result.segments[1].endMilliseconds == 2500)
        #expect(result.detectedLanguage == nil)
    }

    @Test("Valid escaped strings and a final line without LF decode deterministically")
    func escapedText() throws {
        let result = try FFmpegWhisperJSONParser.parse(Data(
            #"{"start":0,"end":0,"text":"He said \"hei\".\nC:\\memo \u00e5"}"#.utf8))
        #expect(result.editableText == "He said \"hei\".\nC:\\memo å")
        #expect(result.segments[0].endMilliseconds == 0)
    }

    @Test("Unsupported shapes and ambiguous JSON fail closed", arguments: [
        #"[{"start":0,"end":1,"text":"hello"}]"#,
        #"{"transcription":[{"text":"hello"}]}"#,
        #"{"start":0,"end":1,"text":"hello","language":"no"}"#,
        #"{"start":0,"start":4,"end":5,"text":"hello"}"#,
        #"{"start":0.5,"end":1,"text":"hello"}"#,
        #"{"start":true,"end":1,"text":"hello"}"#,
        #"{"start":0,"end":1,"text":"He said "hello"."}"#,
        #"{"start":0,"end":1,"text":"C:\memo"}"#,
        #"{"start":0,"end":9223372036854775808,"text":"hello"}"#,
        #"{"start":0,"end":1,"text":null}"#,
        #"{"start":0,"end":1,"text":"hello"} trailing"#,
        #"{"start":0,"end":1,"text":"truncated"#
    ])
    func malformed(input: String) {
        #expect(throws: FFmpegWhisperJSONError.malformedSegment(line: 1)) {
            try FFmpegWhisperJSONParser.parse(Data(input.utf8))
        }
    }

    @Test("Negative, reversed and backward timing fails closed")
    func invalidTiming() {
        for input in [
            #"{"start":-1,"end":1,"text":"hello"}"#,
            #"{"start":2,"end":1,"text":"hello"}"#
        ] {
            #expect(throws: FFmpegWhisperJSONError.invalidTiming(line: 1)) {
                try FFmpegWhisperJSONParser.parse(Data(input.utf8))
            }
        }
        let input = #"{"start":5,"end":10,"text":"first"}"# + "\n" +
            #"{"start":4,"end":11,"text":"second"}"#
        #expect(throws: FFmpegWhisperJSONError.invalidTiming(line: 2)) {
            try FFmpegWhisperJSONParser.parse(Data(input.utf8))
        }
    }

    @Test("Empty and whitespace-only inference has no usable speech", arguments: [
        "", "\n \r\n\t", #"{"start":0,"end":1,"text":" \t "}"#
    ])
    func noSpeech(input: String) {
        #expect(throws: FFmpegWhisperJSONError.noSpeech) {
            try FFmpegWhisperJSONParser.parse(Data(input.utf8))
        }
    }

    @Test("Complete blank-audio markers have no usable speech", arguments: [
        "[BLANK_AUDIO]", " [blank_audio] ", "\t[Blank_Audio]\n"
    ])
    func blankAudioOnly(text: String) throws {
        // The emitter fixes start/end/text order; encode only the string using Foundation.
        let encoded = try #require(String(data: JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), encoding: .utf8))
        let input = "{\"start\":0,\"end\":1,\"text\":" + encoded + "}\n"
        #expect(throws: FFmpegWhisperJSONError.noSpeech) {
            try FFmpegWhisperJSONParser.parse(Data((input + input).utf8))
        }
    }

    @Test("Blank markers retain timing and original text without entering the editable draft")
    func mixedBlankAudio() throws {
        let input = #"{"start":0,"end":100,"text":" [BLANK_AUDIO] "}"# + "\n" +
            #"{"start":100,"end":200,"text":"Hei!"}"#
        let result = try FFmpegWhisperJSONParser.parse(Data(input.utf8))
        #expect(result.editableText == "Hei!")
        #expect(result.segments.count == 2)
        #expect(result.segments[0].text == " [BLANK_AUDIO] ")
        #expect(result.segments[0].endMilliseconds == 100)
    }

    @Test("Embedded marker mentions and incomplete fragments remain literal evidence", arguments: [
        "The token [BLANK_AUDIO] appears here.", "[BLANK_AUDIO] speech", "[", "BLANK", "_", "AUDIO", "]"
    ])
    func literalBlankAudio(text: String) throws {
        let encoded = try #require(String(data: JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), encoding: .utf8))
        let input = "{\"start\":0,\"end\":1,\"text\":" + encoded + "}"
        let result = try FFmpegWhisperJSONParser.parse(Data(input.utf8))
        #expect(result.editableText == text)
        #expect(result.segments[0].text == text)
    }

    @Test("Invalid UTF-8 does not become replacement characters")
    func invalidUTF8() {
        #expect(throws: FFmpegWhisperJSONError.malformedSegment(line: 1)) {
            try FFmpegWhisperJSONParser.parse(Data([0xFF]))
        }
    }

    @Test("Independent byte, segment count and draft text limits")
    func limits() {
        #expect(throws: FFmpegWhisperJSONError.outputTooLarge) {
            try FFmpegWhisperJSONParser.parse(Data(repeating: 0x20, count: FFmpegWhisperJSONParser.maximumOutputBytes + 1))
        }
        #expect(throws: FFmpegWhisperJSONError.segmentTooLarge) {
            try FFmpegWhisperJSONParser.parse(Data(repeating: 0x20, count: FFmpegWhisperJSONParser.maximumSegmentBytes + 1))
        }
        let shortLine = #"{"start":0,"end":1,"text":"a"}"# + "\n"
        #expect(throws: FFmpegWhisperJSONError.tooManySegments) {
            try FFmpegWhisperJSONParser.parse(Data(String(repeating: shortLine, count: FFmpegWhisperJSONParser.maximumSegments + 1).utf8))
        }
        let longLine = #"{"start":0,"end":1,"text":""# + String(repeating: "a", count: 60_000) + "\"}\n"
        #expect(throws: FFmpegWhisperJSONError.textTooLarge) {
            try FFmpegWhisperJSONParser.parse(Data(String(repeating: longLine, count: 36).utf8))
        }
    }
}
