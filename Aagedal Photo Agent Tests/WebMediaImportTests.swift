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

    /// Runs `body` with the write-preset defaults restored afterwards.
    private func withRestoredWriteDefaults(_ body: () async throws -> Void) async rethrows {
        let keys = [UserDefaultsKeys.metadataWritePreset, UserDefaultsKeys.metadataWriteModeNonC2PA,
                    UserDefaultsKeys.metadataWriteModeC2PA]
        let defaults = AppDefaults.store
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        try await body()
    }

    @Test("Working-copy write destination follows the metadata write preset")
    func writeModeFollowsPreset() async {
        await withRestoredWriteDefaults {
            let jpeg = URL(fileURLWithPath: "/w/001.jpg")
            let video = URL(fileURLWithPath: "/w/002.mp4")
            let defaults = AppDefaults.store

            defaults.set(MetadataWritePreset.professional.rawValue, forKey: UserDefaultsKeys.metadataWritePreset)
            #expect(WebMediaImportService.metadataWriteMode(for: jpeg, hasCredential: false) == .writeToFile)
            #expect(WebMediaImportService.metadataWriteMode(for: jpeg, hasCredential: true) == .writeToXMPSidecar)
            #expect(WebMediaImportService.metadataWriteMode(for: video, hasCredential: false) == .writeToXMPSidecar)

            defaults.set(MetadataWritePreset.simple.rawValue, forKey: UserDefaultsKeys.metadataWritePreset)
            #expect(WebMediaImportService.metadataWriteMode(for: jpeg, hasCredential: true) == .writeToFile)
            // Formats the writer can't embed into still get a sidecar.
            #expect(WebMediaImportService.metadataWriteMode(for: video, hasCredential: false) == .writeToXMPSidecar)

            defaults.set(MetadataWritePreset.custom.rawValue, forKey: UserDefaultsKeys.metadataWritePreset)
            defaults.set(MetadataWriteMode.writeToXMPSidecar.rawValue, forKey: UserDefaultsKeys.metadataWriteModeNonC2PA)
            #expect(WebMediaImportService.metadataWriteMode(for: jpeg, hasCredential: false) == .writeToXMPSidecar)
            defaults.set(MetadataWriteMode.writeToFileAndXMPSidecar.rawValue, forKey: UserDefaultsKeys.metadataWriteModeNonC2PA)
            #expect(WebMediaImportService.metadataWriteMode(for: jpeg, hasCredential: false) == .writeToFileAndXMPSidecar)
            #expect(WebMediaImportService.metadataWriteMode(for: video, hasCredential: false) == .writeToXMPSidecar)
        }
    }

    @Test("A sidecar preset leaves the JPEG working copy byte-identical and records the sidecar")
    func sidecarPresetSkipsEmbedding() async throws {
        try await withRestoredWriteDefaults {
            AppDefaults.store.set(MetadataWritePreset.custom.rawValue, forKey: UserDefaultsKeys.metadataWritePreset)
            AppDefaults.store.set(MetadataWriteMode.writeToXMPSidecar.rawValue, forKey: UserDefaultsKeys.metadataWriteModeNonC2PA)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let bytes = try #require(bitmap.representation(using: .jpeg, properties: [:]))
            let media = item(1, kind: "image", extension: "jpg")
            let inspection = WebPostInspection(url: "https://www.instagram.com/p/fixture/", items: [media], versions: [:])
            let service = WebMediaImportService(download: { _, _, _, destination in
                try bytes.write(to: destination.appendingPathComponent("001.jpg"))
                return WebDownloadResult(files: [WebDownloadedFile(item: media, filename: "001.jpg")], versions: [:])
            })
            let working = try await service.importMedia(inspection: inspection, selected: [media.id], cookies: nil,
                destination: root, caption: "Sidecar caption", progress: { _ in })
            #expect(try Data(contentsOf: working.appendingPathComponent("001.jpg")) == bytes)
            #expect(XMPSidecarService().loadSidecar(for: working.appendingPathComponent("001.jpg"))?.description == "Sidecar caption")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let provenance = try decoder.decode(WebImportProvenance.self, from: Data(contentsOf:
                working.deletingLastPathComponent().appendingPathComponent("Provenance/001.jpg.json")))
            #expect(provenance.metadataStorage == "XMP sidecar")
        }
    }

    @Test("Batch folders are named by date, account and post, and never merge")
    func batchFolderNaming() async throws {
        let media = item(1, kind: "image", extension: "jpg")
        let inspection = WebPostInspection(url: "fixture", items: [media], versions: [:])
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 24
        components.hour = 15; components.minute = 30; components.second = 12
        let date = try #require(Calendar.current.date(from: components))
        let name = WebMediaImportService.batchFolderName(inspection: inspection, selected: [media.id], date: date)
        #expect(name == "Web Import 2026-10-24 153012 @source_account post")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unique = try await WebImportFilesystemService().uniqueBatchURL(in: root, baseName: name)
        #expect(unique.lastPathComponent == "\(name) 2")
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

    @Test("An empty download fails and preserves partial originals", arguments: [false, true])
    func emptyDownloadFails(retainPartial: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("incomplete download".utf8)
        let media = item(1, kind: "image", extension: "jpg")
        let inspection = WebPostInspection(url: "fixture", items: [media], versions: [:])
        let filesystem = WebImportFilesystemService(beforeOperation: { operation in
            #expect(operation != .workingDirectory)
            #expect(operation != .copy)
            #expect(operation != .provenanceWrite)
        })
        let service = WebMediaImportService(download: { _, _, _, destination in
            if retainPartial { try bytes.write(to: destination.appendingPathComponent("001.jpg.part")) }
            return WebDownloadResult(files: [], versions: [:])
        }, filesystem: filesystem)
        do {
            _ = try await service.importMedia(inspection: inspection, selected: [media.id], cookies: nil,
                destination: root, caption: "caption", progress: { _ in })
            Issue.record("An empty download must not return a working folder")
        } catch let error as WebDownloadRuntimeService.RuntimeError {
            #expect(error.localizedDescription.contains("No media was downloaded"))
        }
        let batches = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        if retainPartial {
            #expect(batches.count == 1)
            let batch = try #require(batches.first)
            #expect(try Data(contentsOf: batch.appendingPathComponent("Originals/001.jpg.part")) == bytes)
            #expect(FileManager.default.fileExists(atPath: batch.appendingPathComponent("Provenance/post.json").path))
            #expect(!FileManager.default.fileExists(atPath: batch.appendingPathComponent("Working").path))
        } else {
            #expect(batches.isEmpty)
        }
    }

    @Test("Cancellation takes precedence over an empty download response")
    func cancelledEmptyDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WebMediaImportService(download: { _, _, _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return WebDownloadResult(files: [], versions: [:])
        })
        let task = Task {
            try await service.importMedia(inspection: .init(url: "fixture", items: [], versions: [:]),
                selected: [], cookies: nil, destination: root, caption: "", progress: { _ in })
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Invalid download results retain originals without creating working copies",
          arguments: ["missing", "unexpected", "duplicate", "duplicateFilename", "unsafeFilename"])
    func invalidDownloadResults(reason: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = item(1, kind: "video", extension: "mp4")
        let second = item(2, kind: "video", extension: "mp4")
        let other = item(3, kind: "video", extension: "mp4")
        let inspection = WebPostInspection(url: "fixture", items: [first, second], versions: [:])
        let files: [WebDownloadedFile]
        switch reason {
        case "missing": files = [.init(item: first, filename: "001.mp4")]
        case "unexpected": files = [.init(item: first, filename: "001.mp4"), .init(item: other, filename: "003.mp4")]
        case "duplicate": files = [.init(item: first, filename: "001.mp4"), .init(item: first, filename: "002.mp4")]
        case "duplicateFilename": files = [.init(item: first, filename: "001.mp4"), .init(item: second, filename: "001.mp4")]
        default: files = [.init(item: first, filename: "001.mp4"), .init(item: second, filename: "../002.mp4")]
        }
        let bytes = Data("retained original".utf8)
        var retained: URL?
        let filesystem = WebImportFilesystemService(beforeOperation: { operation in
            #expect(operation != .workingDirectory)
            #expect(operation != .copy)
            #expect(operation != .provenanceWrite)
        })
        let service = WebMediaImportService(download: { _, _, _, destination in
            try bytes.write(to: destination.appendingPathComponent("001.mp4"))
            return WebDownloadResult(files: files, versions: [:])
        }, filesystem: filesystem)
        do {
            _ = try await service.importMedia(inspection: inspection, selected: [first.id, second.id], cookies: nil,
                destination: root, caption: "", onRetainedBatch: { retained = $0 }, progress: { _ in })
            Issue.record("An invalid download result must not complete the import")
        } catch is WebDownloadRuntimeService.RuntimeError {}
        let batch = try #require(retained)
        #expect(batch.deletingLastPathComponent().path == root.path)
        #expect(try Data(contentsOf: batch.appendingPathComponent("Originals/001.mp4")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: batch.appendingPathComponent("Working").path))
    }

    @Test("A failed download retains already received originals")
    func failureRetainsOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("downloaded original".utf8)
        var retained: URL?
        let service = WebMediaImportService(download: { _, _, _, destination in
            try bytes.write(to: destination.appendingPathComponent("001.jpg"))
            throw CancellationError()
        })
        do {
            _ = try await service.importMedia(inspection: WebPostInspection(url: "fixture", items: [], versions: [:]),
                selected: [], cookies: nil, destination: root, caption: "",
                onRetainedBatch: { retained = $0 }, progress: { _ in })
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        let batch = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        #expect(try #require(retained).resolvingSymlinksInPath() == batch.resolvingSymlinksInPath())
        #expect(try Data(contentsOf: batch.appendingPathComponent("Originals/001.jpg")) == bytes)
        #expect(FileManager.default.fileExists(atPath: batch.appendingPathComponent("Provenance/post.json").path))
    }
}
