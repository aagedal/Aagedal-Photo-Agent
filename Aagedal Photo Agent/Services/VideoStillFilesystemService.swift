import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftMediaMetadata

/// A retained Dispatch executor keeps collision probes, image encoding and publication off the
/// main actor while preserving the extraction task's cancellation, priority and task locals.
actor VideoStillFilesystemService {
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    static let shared = VideoStillFilesystemService()

    enum Operation: Sendable {
        case collisionProbe, encode, publish, jxlRead, cleanup
    }

    typealias JXLExtractor = @Sendable (URL, Double, URL) async throws -> Void
    private let beforeOperation: @Sendable (Operation, URL) throws -> Void
    private let extractJXL: JXLExtractor

    init(
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.video-still.filesystem", qos: .userInitiated
        ),
        beforeOperation: @escaping @Sendable (Operation, URL) throws -> Void = { _, _ in },
        extractJXL: @escaping JXLExtractor = { source, seconds, temporary in
            try await FFmpegService.extractVideoStillJXL(
                input: source.path, output: temporary.path, seconds: seconds
            )
        }
    ) {
        self.filesystemQueue = filesystemQueue
        self.beforeOperation = beforeOperation
        self.extractJXL = extractJXL
    }

    private func check(_ operation: Operation, at url: URL) throws {
        try Task.checkCancellation()
        try beforeOperation(operation, url)
        try Task.checkCancellation()
    }

    func destination(directory: URL, stem: String, timestamp: String, format: String) throws -> URL {
        var candidate = directory.appendingPathComponent("\(stem)_\(timestamp).\(format)")
        var suffix = 2
        while true {
            try check(.collisionProbe, at: candidate)
            let exists = FileManager.default.fileExists(atPath: candidate.path)
            try Task.checkCancellation()
            if !exists { return candidate }
            candidate = directory.appendingPathComponent("\(stem)_\(timestamp)_\(suffix).\(format)")
            suffix += 1
        }
    }

    func write(image: CGImage, format: String, destination: URL, description: String) throws {
        try check(.encode, at: destination)
        let type = format == "jpg" ? UTType.jpeg : UTType.tiff
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: description],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: description]
        ]
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        try publish(data as Data, to: destination)
    }

    func exportJXL(source: URL, seconds: Double, destination: URL, description: String) async throws {
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jxl")
        defer {
            // Cleanup must run even after cancellation or an extractor failure.
            try? beforeOperation(.cleanup, temporary)
            try? FileManager.default.removeItem(at: temporary)
        }
        try await extractJXL(source, seconds, temporary)
        try check(.jxlRead, at: temporary)
        var file = try JXLParser.parse(Data(contentsOf: temporary))
        var xmp = XMPData()
        xmp.description = description
        file.replaceOrAddBox("xml ", data: Data(XMPWriter.generateXML(xmp).utf8))
        try publish(JXLWriter.write(file), to: destination)
    }

    private func publish(_ data: Data, to destination: URL) throws {
        try check(.publish, at: destination)
        // Probing is advisory: exclusive creation also protects against a competing writer.
        try data.write(to: destination, options: .withoutOverwriting)
        // Publication is the commit point. Return success even if cancellation arrives during
        // the write so the view removes and reports this completed marker exactly once.
    }
}
