import Testing
import Foundation
import AppKit
@testable import Aagedal_Photo_Agent

/// End-to-end concurrency tests that drive the real write engine, read service,
/// and shared `MetadataIOCoordinator` against an actual image file on disk.
///
/// The coordinator-primitive tests in `MetadataIOCoordinatorTests` prove the lock
/// serializes correctly in isolation. These tests close the loop: they confirm
/// that `SwiftExifWriteEngine` and `SwiftExifReadService` are actually wired to
/// that lock, so concurrent reads and writes to the same photo never corrupt the
/// file, never observe a half-written state, and never lose an update.
@Suite("Metadata engine + coordinator integration (real file)")
struct MetadataEngineConcurrencyTests {

    /// Write a minimal, valid baseline JPEG to a unique temp URL.
    /// Generated in-process so no binary fixture needs to live in the repo.
    private func makeTempJPEG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-metadata-race-\(UUID().uuidString).jpg")
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let data = rep.representation(using: .jpeg, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
        return url
    }

    /// Sanity baseline: a sequential write-then-read roundtrips through the real
    /// file, so any failure in the concurrent tests below points at concurrency,
    /// not at the fixture or the basic I/O path.
    @Test("sequential write then read roundtrips rating and title")
    func sequentialRoundtrip() async throws {
        let engine = SwiftExifWriteEngine()
        let reader = SwiftExifReadService()
        let url = try makeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        try await engine.writeRating(.five, to: [url])
        try await engine.writeFields([.headline: "Hello"], to: [url])

        let meta = try await reader.readFullMetadata(url: url)
        #expect(meta.rating == 5)
        #expect(meta.title == "Hello")
    }

    /// The core end-to-end guarantee: a rating write and a field write fired
    /// concurrently at the same photo must BOTH survive. Each is a read-modify-
    /// write cycle over the file's metadata; without per-photo serialization the
    /// two cycles read the same baseline and the second writer clobbers the
    /// first, dropping one of the two updates. Looping makes such a regression
    /// fail reliably rather than only on an unlucky interleaving.
    @Test("concurrent rating + field writes on the same file never clobber each other")
    func concurrentWritesDoNotClobber() async throws {
        let engine = SwiftExifWriteEngine()
        let reader = SwiftExifReadService()

        for _ in 0..<25 {
            let url = try makeTempJPEG()
            defer { try? FileManager.default.removeItem(at: url) }

            async let rating: Void = engine.writeRating(.five, to: [url])
            async let fields: Void = engine.writeFields([.headline: "Hello"], to: [url])
            _ = try await (rating, fields)

            let meta = try await reader.readFullMetadata(url: url)
            #expect(meta.rating == 5)
            #expect(meta.title == "Hello")
        }
    }

    /// Stress: many concurrent writers (ratings + headlines from a known set) and
    /// readers against one file. Every read must observe either a committed value
    /// from the known set or an empty/initial value — never a torn or garbage
    /// string — which is only possible if reads are serialized against writes.
    /// The file must also remain parseable after the storm.
    @Test("concurrent reads and writes never yield torn reads or corruption")
    func concurrentReadsAndWritesStayConsistent() async throws {
        let engine = SwiftExifWriteEngine()
        let reader = SwiftExifReadService()
        let url = try makeTempJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        let titles = ["Alpha", "Bravo", "Charlie", "Delta"]
        let knownTitles = Set(titles)

        try await withThrowingTaskGroup(of: String?.self) { group in
            for i in 0..<20 {
                let rating = StarRating(rawValue: i % 6) ?? .none
                group.addTask {
                    try await engine.writeRating(rating, to: [url])
                    return nil
                }
            }
            for i in 0..<20 {
                let title = titles[i % titles.count]
                group.addTask {
                    try await engine.writeFields([.headline: title], to: [url])
                    return nil
                }
            }
            for _ in 0..<40 {
                group.addTask {
                    try await reader.readFullMetadata(url: url).title
                }
            }

            for try await title in group {
                if let title, !title.isEmpty {
                    #expect(knownTitles.contains(title))
                }
            }
        }

        // The file survived the storm: a final read parses and reflects a
        // committed value, never a half-written one.
        let surviving = try await reader.readFullMetadata(url: url).title
        if let surviving, !surviving.isEmpty {
            #expect(knownTitles.contains(surviving))
        }

        // And a deterministic write issued after the storm is the observed state.
        try await engine.writeRating(.four, to: [url])
        try await engine.writeFields([.headline: "Final"], to: [url])
        let final = try await reader.readFullMetadata(url: url)
        #expect(final.rating == 4)
        #expect(final.title == "Final")
    }
}
