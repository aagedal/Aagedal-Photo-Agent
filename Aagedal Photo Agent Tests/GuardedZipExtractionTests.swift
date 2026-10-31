import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("GuardedZipExtraction")
struct GuardedZipExtractionTests {
    private typealias Guard = GuardedZipExtraction
    private static let roomy = Guard.Limits(maxTotalBytes: 64 * 1_048_576, maxEntries: 100)

    private final class Scratch {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guarded-zip-\(UUID().uuidString)", isDirectory: true)
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }

        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        /// Zips `files` (name → contents) with ditto, the way the app writes its archives.
        func archive(_ files: [String: Data]) throws -> URL {
            let source = try directory("source-\(UUID().uuidString)")
            for (name, data) in files { try data.write(to: source.appendingPathComponent(name)) }
            let archive = root.appendingPathComponent("\(UUID().uuidString).zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", source.path, archive.path]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return archive
        }

        func contents(of directory: URL) -> [String] {
            (FileManager.default.subpaths(atPath: directory.path) ?? []).sorted()
        }
    }

    @Test func honestArchiveExtracts() throws {
        let scratch = try Scratch()
        let archive = try scratch.archive([
            "manifest.json": Data("{}".utf8),
            "list.txt": Data(repeating: 0x61, count: 300_000),
        ])
        let summary = try Guard.preflight(archive, limits: Self.roomy)
        #expect(summary.declaredUncompressedBytes >= 300_002)

        let destination = try scratch.directory("out")
        try Guard.extract(archive, into: destination, limits: Self.roomy)
        let source = try #require(scratch.contents(of: destination).first)
        let list = destination.appendingPathComponent(source).appendingPathComponent("list.txt")
        #expect(try Data(contentsOf: list).count == 300_000)
    }

    @Test func tooManyEntriesIsRefusedBeforeExtracting() throws {
        let scratch = try Scratch()
        let archive = try scratch.archive(["a": Data("a".utf8), "b": Data("b".utf8), "c": Data("c".utf8)])
        let destination = try scratch.directory("out")
        let limits = Guard.Limits(maxTotalBytes: 1_048_576, maxEntries: 2)
        #expect(throws: Guard.ExtractionError.tooManyEntries(limit: 2)) {
            try Guard.extract(archive, into: destination, limits: limits)
        }
        #expect(scratch.contents(of: destination).isEmpty)
    }

    @Test func declaredSizeOverLimitIsRefusedBeforeExtracting() throws {
        let scratch = try Scratch()
        // Zeros compress to almost nothing: a tiny archive that expands 1,000-fold.
        let archive = try scratch.archive(["zeros": Data(count: 4 * 1_048_576)])
        let size = try #require(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size < 100_000)
        let destination = try scratch.directory("out")
        let limits = Guard.Limits(maxTotalBytes: 1_048_576, maxEntries: 100)
        #expect(throws: Guard.ExtractionError.tooLarge(limit: 1_048_576)) {
            try Guard.extract(archive, into: destination, limits: limits)
        }
        #expect(scratch.contents(of: destination).isEmpty)
    }

    @Test func understatedSizeNeverExtractsSuccessfully() throws {
        let scratch = try Scratch()
        let archive = try scratch.archive(["zeros": Data(count: 8 * 1_048_576)])
        // Rewrite every central-directory "uncompressed size" to 10 bytes.
        var bytes = try Data(contentsOf: archive)
        var patched = 0
        var index = 0
        while index + 46 <= bytes.count {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x01, bytes[index + 3] == 0x02 {
                bytes.replaceSubrange((index + 24)..<(index + 28), with: [10, 0, 0, 0])
                patched += 1
            }
            index += 1
        }
        #expect(patched > 0)
        try bytes.write(to: archive)
        #expect(try Guard.preflight(archive, limits: Self.roomy).declaredUncompressedBytes < 1_000)

        let destination = try scratch.directory("out")
        do {
            try Guard.extract(archive, into: destination, limits: Self.roomy)
            Issue.record("An archive that expands past its declared size must not extract")
        } catch let error as Guard.ExtractionError {
            switch error {
            case .tooLarge, .commandFailed: break
            default: Issue.record("Unexpected error \(error)")
            }
        }
    }

    @Test func watchdogStopsAnOversizedExtraction() throws {
        let scratch = try Scratch()
        let archive = try scratch.archive(["zeros": Data(count: 8 * 1_048_576)])
        let destination = try scratch.directory("out")
        #expect(throws: Guard.ExtractionError.tooLarge(limit: 1_048_576)) {
            try Guard.runWatched(
                arguments: ["-x", "-k", archive.path, destination.path],
                destination: destination, byteCap: 1_048_576, entryCap: 100,
                isCancelled: { false }
            )
        }
    }

    @Test func notEnoughFreeSpaceIsRefused() throws {
        let scratch = try Scratch()
        let archive = try scratch.archive(["zeros": Data(count: 2 * 1_048_576)])
        let destination = try scratch.directory("out")
        let available = Guard.reservedFreeBytes + 1_048_576
        #expect(throws: Guard.ExtractionError.self) {
            try Guard.extract(archive, into: destination, limits: Self.roomy, availableBytes: { _ in available })
        }
        #expect(scratch.contents(of: destination).isEmpty)
    }

    @Test func cancellationStopsBeforeExtracting() throws {
        let scratch = try Scratch()
        let archive = try scratch.archive(["a": Data("a".utf8)])
        let destination = try scratch.directory("out")
        #expect(throws: CancellationError.self) {
            try Guard.extract(archive, into: destination, limits: Self.roomy, isCancelled: { true })
        }
        #expect(scratch.contents(of: destination).isEmpty)
    }

    @Test func nonArchivesAndTruncatedArchivesAreRefused() throws {
        let scratch = try Scratch()
        let text = scratch.root.appendingPathComponent("notes.zip")
        try Data("just some text, not a zip".utf8).write(to: text)
        #expect(throws: Guard.ExtractionError.notAZipArchive) {
            try Guard.preflight(text, limits: Self.roomy)
        }

        let archive = try scratch.archive(["a": Data(repeating: 1, count: 10_000)])
        let truncated = scratch.root.appendingPathComponent("truncated.zip")
        try Data(contentsOf: archive).prefix(200).write(to: truncated)
        #expect(throws: Guard.ExtractionError.notAZipArchive) {
            try Guard.preflight(truncated, limits: Self.roomy)
        }
    }

    // MARK: - Zip64

    /// A one-entry archive whose central directory carries the size in a Zip64 extra field,
    /// optionally with Zip64 end records too. Only the directory is meaningful.
    private static func zip64Archive(uncompressed: UInt64, zip64EndRecords: Bool) -> Data {
        var data = Data()
        func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let name = Data("big.bin".utf8)

        let directoryStart = data.count
        le(UInt32(0x0201_4B50)); le(UInt16(45)); le(UInt16(45)); le(UInt16(0)); le(UInt16(0))
        le(UInt32(0)); le(UInt32(0))                         // time/date, CRC
        le(UInt32(0xFFFF_FFFF)); le(UInt32(0xFFFF_FFFF))   // compressed, uncompressed
        le(UInt16(name.count)); le(UInt16(20)); le(UInt16(0))
        le(UInt16(0)); le(UInt16(0)); le(UInt32(0)); le(UInt32(0))
        data.append(name)
        le(UInt16(0x0001)); le(UInt16(16)); le(uncompressed); le(UInt64(1_000))
        let directorySize = data.count - directoryStart

        if zip64EndRecords {
            let recordOffset = data.count
            le(UInt32(0x0606_4B50)); le(UInt64(44)); le(UInt16(45)); le(UInt16(45))
            le(UInt32(0)); le(UInt32(0)); le(UInt64(1)); le(UInt64(1))
            le(UInt64(directorySize)); le(UInt64(directoryStart))
            le(UInt32(0x0706_4B50)); le(UInt32(0)); le(UInt64(recordOffset)); le(UInt32(1))
            le(UInt32(0x0605_4B50)); le(UInt16(0)); le(UInt16(0)); le(UInt16(0xFFFF)); le(UInt16(0xFFFF))
            le(UInt32(0xFFFF_FFFF)); le(UInt32(0xFFFF_FFFF)); le(UInt16(0))
        } else {
            le(UInt32(0x0605_4B50)); le(UInt16(0)); le(UInt16(0)); le(UInt16(1)); le(UInt16(1))
            le(UInt32(directorySize)); le(UInt32(directoryStart)); le(UInt16(0))
        }
        return data
    }

    @Test(arguments: [false, true])
    func zip64SizesAreRead(zip64EndRecords: Bool) throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("zip64.zip")
        let fiveGB: UInt64 = 5 * 1_073_741_824
        try Self.zip64Archive(uncompressed: fiveGB, zip64EndRecords: zip64EndRecords).write(to: url)

        #expect(throws: Guard.ExtractionError.tooLarge(limit: Guard.Limits.knownPeople.maxTotalBytes)) {
            try Guard.preflight(url, limits: .knownPeople)
        }
        let summary = try Guard.preflight(url, limits: .analysisProject)
        #expect(summary.entryCount == 1)
        #expect(summary.declaredUncompressedBytes == Int64(fiveGB))
    }
}
