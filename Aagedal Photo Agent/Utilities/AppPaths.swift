import Foundation
import os

nonisolated private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "AppPaths")

nonisolated enum AppPaths {
    static var applicationSupport: URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            logger.error("Application Support directory not found, falling back to home directory")
            let fallback = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".aagedal-photo-agent", isDirectory: true)
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        }
        let url = base.appendingPathComponent("Aagedal Photo Agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var defaultTemplatesDirectory: URL {
        let url = applicationSupport.appendingPathComponent("Templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Resolves the user's chosen templates folder if a bookmark is set, otherwise the default.
    /// The returned `release` closure MUST be invoked once the caller is done with the URL,
    /// so security-scoped access is balanced.
    static func templatesDirectory() -> (url: URL, release: () -> Void) {
        if let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.templatesFolderBookmark) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                let started = url.startAccessingSecurityScopedResource()
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return (url, { if started { url.stopAccessingSecurityScopedResource() } })
            }
        }
        return (defaultTemplatesDirectory, {})
    }

    static var certificatesDirectory: URL {
        let url = applicationSupport.appendingPathComponent("Certificates", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var cacheDirectory: URL {
        let url = applicationSupport.appendingPathComponent("Cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // v2: applicationSupport/ApprovedLists/ — reserved for URL-refreshed cached vocabulary files.
}
