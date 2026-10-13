import AppKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Web media original preservation")
@MainActor
struct WebMediaImportTests {
    @Test("The packaged isolated Python imports both tools through the native bridge")
    func packagedRuntimeWorks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WebDownloadRuntimeService(supportURL: root)
        let versions = try await runtime.installedVersions()
        #expect(versions["gallery-dl"]?.isEmpty == false)
        #expect(versions["yt-dlp"]?.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("A rejected package update leaves the active generation unchanged")
    func failedUpdateKeepsActiveGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let generation = UUID().uuidString
        let active = root.appendingPathComponent(generation)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: active.appendingPathComponent("packages.json"))
        let pointer = try JSONEncoder().encode(generation)
        try pointer.write(to: root.appendingPathComponent("current.json"))
        let runtime = WebDownloadRuntimeService(supportURL: root)
        do {
            _ = try await runtime.update(to: ["gallery-dl": "invalid version", "yt-dlp": "0"])
            Issue.record("Expected update rejection")
        } catch {}
        #expect(try Data(contentsOf: root.appendingPathComponent("current.json")) == pointer)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [generation, "current.json"].sorted())
    }

    private func item(_ number: Int, kind: String, extension suffix: String) -> WebMediaItem {
        WebMediaItem(id: "post:\(number)", position: number, kind: kind,
            downloadURL: "https://cdn.example/\(number).\(suffix)", width: 16, height: 16,
            username: "source_account", displayName: "Source Account", description: "Original post text",
            publishedAt: "2026-10-01T12:00:00", postID: "post", extension: suffix)
    }

    @Test("JPEG enrichment preserves original bytes and original post text")
    func jpegOriginalPreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        let media = item(1, kind: "image", extension: "jpg")
        let inspection = WebPostInspection(url: "https://www.instagram.com/p/fixture/", items: [media], versions: ["gallery-dl": "fixture"])
        let service = WebMediaImportService(download: { _, _, _, destination in
            try bytes.write(to: destination.appendingPathComponent("001.jpg"))
            return WebDownloadResult(files: [WebDownloadedFile(item: media, filename: "001.jpg")], versions: inspection.versions)
        })
        let working = try await service.importMedia(inspection: inspection, selected: [media.id], cookies: nil,
            destination: root, caption: "Edited newsroom caption", progress: { _ in })
        let batch = working.deletingLastPathComponent()
        #expect(try Data(contentsOf: batch.appendingPathComponent("Originals/001.jpg")) == bytes)
        let metadata = try await SwiftExifReadService().readFullMetadata(url: working.appendingPathComponent("001.jpg"))
        #expect(metadata.description == "Edited newsroom caption")
        #expect(metadata.source == "@source_account")
        #expect(metadata.creators.isEmpty)
        #expect(metadata.captureDate == nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(WebImportProvenance.self, from: Data(contentsOf: batch.appendingPathComponent("Provenance/001.jpg.json")))
        #expect(provenance.media.description == "Original post text")
        #expect(provenance.postURL == inspection.url)
        #expect(provenance.originalSHA256 == (try HashStream.hashFileSynchronously(at: batch.appendingPathComponent("Originals/001.jpg"))).map { String(format: "%02x", $0) }.joined())
    }

    @Test("Video originals and working bytes stay identical with adjacent XMP")
    func videoUsesSidecar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("fixture video bytes".utf8)
        let media = item(2, kind: "video", extension: "mp4")
        let inspection = WebPostInspection(url: "https://www.instagram.com/p/fixture/", items: [media], versions: [:])
        let service = WebMediaImportService(download: { _, _, _, destination in
            try bytes.write(to: destination.appendingPathComponent("002.mp4"))
            return WebDownloadResult(files: [WebDownloadedFile(item: media, filename: "002.mp4")], versions: [:])
        })
        let working = try await service.importMedia(inspection: inspection, selected: [media.id], cookies: nil,
            destination: root, caption: "Video caption", progress: { _ in })
        #expect(try Data(contentsOf: working.appendingPathComponent("002.mp4")) == bytes)
        #expect(try Data(contentsOf: working.deletingLastPathComponent().appendingPathComponent("Originals/002.mp4")) == bytes)
        #expect(XMPSidecarService().loadSidecar(for: working.appendingPathComponent("002.mp4"))?.description == "Video caption")
    }

    @Test("A failed download retains already received originals")
    func failureRetainsOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("downloaded original".utf8)
        let service = WebMediaImportService(download: { _, _, _, destination in
            try bytes.write(to: destination.appendingPathComponent("001.jpg"))
            throw CancellationError()
        })
        do {
            _ = try await service.importMedia(inspection: WebPostInspection(url: "fixture", items: [], versions: [:]),
                selected: [], cookies: nil, destination: root, caption: "", progress: { _ in })
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        let batch = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: batch.appendingPathComponent("Originals/001.jpg")) == bytes)
        #expect(FileManager.default.fileExists(atPath: batch.appendingPathComponent("Provenance/post.json").path))
    }
}
