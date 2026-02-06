import Foundation
import os

nonisolated(unsafe) private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "AppPaths")

enum AppPaths {
    static var applicationSupport: URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            logger.error("Application Support directory not found, falling back to temporary directory")
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("Aagedal Photo Agent", isDirectory: true)
        }
        let url = base.appendingPathComponent("Aagedal Photo Agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var templatesDirectory: URL {
        let url = applicationSupport.appendingPathComponent("Templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
