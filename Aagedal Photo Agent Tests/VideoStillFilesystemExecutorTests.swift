import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Video still Dispatch filesystem executor")
struct VideoStillFilesystemExecutorTests {
    @Test("Collision probes and JPEG/TIFF encoding preserve context and source caption", arguments: ["jpg", "tiff"])
    @MainActor
    func collisionAndMetadata(format: String) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchSerialQueue(label: "test.video-still.\(format)")
        let service = VideoStillFilesystemService(filesystemQueue: queue, beforeOperation: { _, _ in
            checkVideoStillExecutor(queue, marker: directory)
        })
        let existing = directory.appendingPathComponent("clip_01-00-00-03.\(format)")
        let original = Data("keep existing".utf8)
        try original.write(to: existing)
        let image = try makeImage()
        let caption = "Still from clip.mov at timecode 01:00:00:03 (source)"
        let output = try await VideoStillExecutorContext.$marker.withValue(directory) {
            let output = try await service.destination(directory: directory, stem: "clip",
                                                      timestamp: "01-00-00-03", format: format)
            #expect(output.lastPathComponent == "clip_01-00-00-03_2.\(format)")
            try await service.write(image: image, format: format, destination: output, description: caption)
            return output
        }
        #expect(try Data(contentsOf: existing) == original)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let iptc = try #require(properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String == caption)
    }

    @Test("Stills carry the video's capture time (plus frame offset), GPS and descriptive fields", arguments: ["jpg", "tiff"])
    @MainActor
    func sourceMetadataIsCopied(format: String) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureDate = Date(timeIntervalSince1970: 1_790_000_000)
        let source = VideoStillSourceMetadata(
            captureDate: captureDate, latitude: 59.9139, longitude: 10.7522, altitude: 12,
            creators: ["Truls \u{C5}gedal"], copyright: "\u{A9} Aagedal", credit: "NTB",
            city: "Troms\u{F8}", state: "Troms", country: "Norway", keywords: ["nordlys", "vinter"]
        )
        let output = directory.appendingPathComponent("clip.\(format)")
        let caption = "Still from clip.mov at timecode 00:00:02:12 (relative)"
        try await VideoStillFilesystemService().write(
            image: try makeImage(), format: format, destination: output, description: caption,
            sourceMetadata: source, frameOffset: 2.5
        )

        let metadata = try await SwiftExifReadService().readFullMetadata(url: output)
        #expect(metadata.description == caption)
        #expect(metadata.creators == ["Truls \u{C5}gedal"])
        #expect(metadata.copyright == "\u{A9} Aagedal")
        #expect(metadata.credit == "NTB")
        #expect(metadata.city == "Troms\u{F8}")
        #expect(metadata.country == "Norway")
        #expect(Set(metadata.keywords) == ["nordlys", "vinter"])
        let latitude = try #require(metadata.latitude)
        let longitude = try #require(metadata.longitude)
        #expect(abs(latitude - 59.9139) < 0.0001)
        #expect(abs(longitude - 10.7522) < 0.0001)

        let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any])
        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        #expect(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
                == formatter.string(from: captureDate.addingTimeInterval(2.5)))
        #expect(exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String == "500")
    }

    @Test("A video without metadata still gets only the caption")
    @MainActor
    func emptySourceMetadataKeepsCaptionOnly() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("plain.jpg")
        try await VideoStillFilesystemService().write(
            image: try makeImage(), format: "jpg", destination: output, description: "caption only"
        )
        let metadata = try await SwiftExifReadService().readFullMetadata(url: output)
        #expect(metadata.description == "caption only")
        #expect(metadata.creators.isEmpty)
        #expect(metadata.latitude == nil)
    }

    @Test("A writer racing after the collision probe cannot replace a still")
    @MainActor
    func publicationRace() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("competing writer".utf8)
        let service = VideoStillFilesystemService(beforeOperation: { operation, url in
            if case .publish = operation { try original.write(to: url, options: .withoutOverwriting) }
        })
        let output = try await service.destination(directory: directory, stem: "clip", timestamp: "00", format: "jpg")
        let image = try makeImage()
        await #expect(throws: (any Error).self) {
            try await service.write(image: image, format: "jpg", destination: output, description: "new still")
        }
        #expect(try Data(contentsOf: output) == original)
    }

    @Test("Failure or cancellation leaves completed stills intact and stops the remaining prefix", arguments: [false, true])
    @MainActor
    func partialPublication(cancel: Bool) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchSerialQueue(label: "test.video-still.partial")
        let service = VideoStillFilesystemService(filesystemQueue: queue, beforeOperation: { operation, url in
            checkVideoStillExecutor(queue, marker: directory)
            if case .publish = operation, url.lastPathComponent == "second.jpg" {
                if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                else { throw CocoaError(.fileWriteNoPermission) }
            }
        })
        let image = try makeImage()
        let names = ["first.jpg", "second.jpg", "third.jpg"]
        let saved = await Task {
            await VideoStillExecutorContext.$marker.withValue(directory) {
                var saved = 0
                do {
                    for name in names {
                        try await service.write(image: image, format: "jpg",
                                                destination: directory.appendingPathComponent(name), description: name)
                        saved += 1
                    }
                    Issue.record("The second publication should fail")
                } catch {
                    #expect((error is CancellationError) == cancel)
                }
                return saved
            }
        }.value
        #expect(saved == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["first.jpg"])
        let source = try #require(CGImageSourceCreateWithURL(directory.appendingPathComponent("first.jpg") as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
    }

    @Test("Cancellation during a collision probe stops before encoding")
    @MainActor
    func collisionCancellation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchSerialQueue(label: "test.video-still.cancel-probe")
        let service = VideoStillFilesystemService(filesystemQueue: queue, beforeOperation: { operation, _ in
            checkVideoStillExecutor(queue, marker: directory)
            if case .collisionProbe = operation { withUnsafeCurrentTask { $0?.cancel() } }
            else { Issue.record("Cancelled collision probe continued to another operation") }
        })
        await Task {
            await VideoStillExecutorContext.$marker.withValue(directory) {
                await #expect(throws: CancellationError.self) {
                    _ = try await service.destination(directory: directory, stem: "clip", timestamp: "00", format: "jpg")
                }
            }
        }.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("JXL resumes on Dispatch and removes temporary output after extractor failure or cancellation", arguments: [false, true])
    @MainActor
    func jxlCleanup(cancel: Bool) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchSerialQueue(label: "test.video-still.jxl-cleanup")
        let receipt = VideoStillTemporaryReceipt()
        let service = VideoStillFilesystemService(filesystemQueue: queue, beforeOperation: { operation, temporary in
            checkVideoStillExecutor(queue, marker: directory)
            if case .cleanup = operation {
                #expect(FileManager.default.fileExists(atPath: temporary.path))
                #expect(Task.isCancelled == cancel)
            } else { Issue.record("Incomplete extraction reached JXL parsing or publication") }
        }, extractJXL: { _, _, temporary in
            try Data("partial jxl".utf8).write(to: temporary)
            await receipt.record(temporary)
            await Task.yield()
            if cancel {
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }
            throw CocoaError(.fileWriteUnknown)
        })
        await Task {
            await VideoStillExecutorContext.$marker.withValue(directory) {
                do {
                    try await service.exportJXL(source: directory.appendingPathComponent("clip.mov"), seconds: 0,
                                                destination: directory.appendingPathComponent("still.jxl"), description: "caption")
                    Issue.record("Incomplete extraction should fail")
                } catch { #expect((error is CancellationError) == cancel) }
            }
        }.value
        let temporary = try #require(await receipt.url)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeImage() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try #require(context.makeImage())
    }
}

private nonisolated enum VideoStillExecutorContext {
    @TaskLocal static var marker: URL?
}

private nonisolated func checkVideoStillExecutor(_ queue: DispatchSerialQueue, marker: URL) {
    #expect(queue.isIsolatingCurrentContext() == true)
    #expect(!Thread.isMainThread)
    #expect(VideoStillExecutorContext.marker == marker)
}

private actor VideoStillTemporaryReceipt {
    var url: URL?
    func record(_ url: URL) { self.url = url }
}
