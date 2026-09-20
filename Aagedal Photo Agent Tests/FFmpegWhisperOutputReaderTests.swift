import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("FFmpeg Whisper bounded output reader")
struct FFmpegWhisperOutputReaderTests {
    private let canonical = Data(#"{"start":0,"end":1200,"text":"Hei, Ålesund!"}"#.utf8)

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        // Foundation may shorten /private/var back to the /var symlink even when resolving
        // symlinks. Admission deliberately requires the actual, component-wise physical path.
        let physicalRoot = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physicalRoot) }
        let directory = URL(fileURLWithPath: String(cString: physicalRoot), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("Successful canonical file becomes an unapproved inference result")
    func successfulRead() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("output.json")
            try canonical.write(to: file)
            let result = try FFmpegWhisperOutputReader.read(from: file, completion: .exited(status: 0))
            #expect(result.editableText == "Hei, Ålesund!")
            #expect(result.segments[0].endMilliseconds == 1200)
            #expect(result.detectedLanguage == nil)
        }
    }

    @Test("Multiple bounded reads preserve UTF-8 and segment boundaries")
    func multipleChunks() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("output.json")
            let text = String(repeating: "å", count: 25_000)
            let line = "{\"start\":0,\"end\":1200,\"text\":\"" + text + "\"}\n"
            try Data(String(repeating: line, count: 3).utf8).write(to: file)
            let result = try FFmpegWhisperOutputReader.read(from: file, completion: .exited(status: 0))
            #expect(result.segments.count == 3)
            #expect(result.segments.allSatisfy { $0.text == text })
            #expect(result.editableText == [text, text, text].joined(separator: " "))
        }
    }

    @Test("A complete-looking file cannot override unsuccessful or unfinished producer state")
    func completionPrecondition() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("output.json")
            try canonical.write(to: file)
            for completion in [FFmpegWhisperProducerCompletion.running, .exited(status: 1), .signalled(signal: 9)] {
                #expect(throws: FFmpegWhisperOutputError.producerNotSuccessful) {
                    try FFmpegWhisperOutputReader.read(from: file, completion: completion)
                }
            }
        }
    }

    @Test("Cancellation before admission, during reading and before publication discards output")
    func cancellation() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("output.json")
            try canonical.write(to: file)
            for cancellationPoint in [1, 2, 4] {
                var checks = 0
                #expect(throws: CancellationError.self) {
                    try FFmpegWhisperOutputReader.read(from: file, completion: .exited(status: 0)) {
                        checks += 1
                        if checks == cancellationPoint { throw CancellationError() }
                    }
                }
            }
        }
    }

    @Test("Leaf and ancestor symlinks, hardlinks, directories and FIFOs are refused")
    func unsafeFiles() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("output.json")
            try canonical.write(to: file)
            let link = directory.appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            #expect(throws: FFmpegWhisperOutputError.unsafeFile) {
                try FFmpegWhisperOutputReader.read(from: link, completion: .exited(status: 0))
            }
            let child = directory.appendingPathComponent("child", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            try canonical.write(to: child.appendingPathComponent("output.json"))
            let alias = directory.appendingPathComponent("alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
            #expect(throws: FFmpegWhisperOutputError.unsafePath) {
                try FFmpegWhisperOutputReader.read(from: alias.appendingPathComponent("output.json"), completion: .exited(status: 0))
            }
            #expect(throws: FFmpegWhisperOutputError.unsafeFile) {
                try FFmpegWhisperOutputReader.read(from: child, completion: .exited(status: 0))
            }
            let hardlink = directory.appendingPathComponent("hardlink.json")
            try FileManager.default.linkItem(at: file, to: hardlink)
            #expect(throws: FFmpegWhisperOutputError.unsafeFile) {
                try FFmpegWhisperOutputReader.read(from: file, completion: .exited(status: 0))
            }
            let fifo = directory.appendingPathComponent("fifo")
            #expect(mkfifo(fifo.path, 0o600) == 0)
            #expect(throws: FFmpegWhisperOutputError.unsafeFile) {
                try FFmpegWhisperOutputReader.read(from: fifo, completion: .exited(status: 0))
            }
        }
    }

    @Test("Oversized sparse files fail before allocating the advertised size")
    func oversized() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("output.json")
            try Data().write(to: file)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(FFmpegWhisperJSONParser.maximumOutputBytes + 1))
            #expect(throws: FFmpegWhisperJSONError.outputTooLarge) {
                try FFmpegWhisperOutputReader.read(from: file, completion: .exited(status: 0))
            }
        }
    }

    @Test("Growth, truncation and same-size modification during reading are refused", arguments: [0, 1, 2])
    func mutation(kind: Int) throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("output.json")
            try canonical.write(to: file)
            var checks = 0
            #expect(throws: FFmpegWhisperOutputError.fileChanged) {
                try FFmpegWhisperOutputReader.read(from: file, completion: .exited(status: 0)) {
                    checks += 1
                    if checks == 3 {
                        let handle = try FileHandle(forWritingTo: file)
                        defer { try? handle.close() }
                        switch kind {
                        case 0:
                            try handle.seekToEnd()
                            try handle.write(contentsOf: Data("\n".utf8))
                        case 1:
                            try handle.truncate(atOffset: 0)
                        default:
                            try handle.write(contentsOf: Data(" ".utf8))
                            // Force a distinct metadata timestamp even on low-resolution filesystems.
                            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: file.path)
                        }
                    }
                }
            }
        }
    }

    @Test("Path replacement is refused even when the original open inode remains unchanged")
    func replacement() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("output.json")
            try canonical.write(to: file)
            var checks = 0
            #expect(throws: FFmpegWhisperOutputError.fileChanged) {
                try FFmpegWhisperOutputReader.read(from: file, completion: .exited(status: 0)) {
                    checks += 1
                    if checks == 4 {
                        try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent("original.json"))
                        try canonical.write(to: file)
                    }
                }
            }
        }
    }

    @Test("Replacing a parent directory while moving the same leaf inode is refused")
    func parentReplacement() throws {
        try withDirectory { directory in
            let job = directory.appendingPathComponent("job", isDirectory: true)
            let oldJob = directory.appendingPathComponent("old-job", isDirectory: true)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
            let file = job.appendingPathComponent("output.json")
            try canonical.write(to: file)
            var checks = 0
            #expect(throws: FFmpegWhisperOutputError.fileChanged) {
                try FFmpegWhisperOutputReader.read(from: file, completion: .exited(status: 0)) {
                    checks += 1
                    if checks == 4 {
                        try FileManager.default.moveItem(at: job, to: oldJob)
                        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
                        try FileManager.default.moveItem(at: oldJob.appendingPathComponent("output.json"), to: file)
                    }
                }
            }
        }
    }

    @Test("Parser refusals propagate without falling back to a noncanonical representation")
    func malformedAndNoSpeech() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("output.json")
            try Data().write(to: file)
            #expect(throws: FFmpegWhisperJSONError.noSpeech) {
                try FFmpegWhisperOutputReader.read(from: file, completion: .exited(status: 0))
            }
            try Data("console text".utf8).write(to: file)
            #expect(throws: FFmpegWhisperJSONError.malformedSegment(line: 1)) {
                try FFmpegWhisperOutputReader.read(from: file, completion: .exited(status: 0))
            }
        }
    }
}
