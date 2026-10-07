import Foundation
import SwiftMediaMetadata

nonisolated enum VideoJXLStillExporter {
    static func export(source: URL, seconds: Double, destination: URL, description: String) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jxl")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await FFmpegService.extractVideoStillJXL(input: source.path, output: temporary.path, seconds: seconds)
        try await Task.detached(priority: .userInitiated) {
            var file = try JXLParser.parse(Data(contentsOf: temporary))
            var xmp = XMPData()
            xmp.description = description
            file.replaceOrAddBox("xml ", data: Data(XMPWriter.generateXML(xmp).utf8))
            // Publish only the completed image with provenance; never overwrite an existing still.
            try JXLWriter.write(file).write(to: destination, options: .withoutOverwriting)
        }.value
    }
}
