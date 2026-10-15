import Foundation

nonisolated enum VideoJXLStillExporter {
    static func export(
        source: URL, seconds: Double, destination: URL, description: String,
        filesystem: VideoStillFilesystemService = .shared
    ) async throws {
        try await filesystem.exportJXL(source: source, seconds: seconds,
                                       destination: destination, description: description)
    }
}
