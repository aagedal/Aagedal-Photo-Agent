import Foundation
import os

nonisolated private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "AppPaths")

nonisolated enum AppPaths {
    /// iCloud ubiquity container identifier. Must match the entitlements file and
    /// `KeywordListsStore.iCloudContainerID`.
    static let iCloudContainerID = "iCloud.aagedal.Aagedal-Photo-Agent"

    /// `Documents` directory inside the ubiquity container, or nil when iCloud
    /// Drive is unavailable (no account, not signed in, entitlement missing).
    /// Apple notes the first call can block briefly, so avoid calling on a hot path.
    static var iCloudDocuments: URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: iCloudContainerID) else {
            return nil
        }
        return container.appendingPathComponent("Documents", isDirectory: true)
    }

    /// Templates folder inside the ubiquity container.
    static var iCloudTemplatesURL: URL? {
        iCloudDocuments?.appendingPathComponent("Templates", isDirectory: true)
    }

    /// Known People folder inside the ubiquity container.
    static var iCloudKnownPeopleURL: URL? {
        iCloudDocuments?.appendingPathComponent("KnownPeople", isDirectory: true)
    }

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
        // iCloud sync, when enabled and reachable, takes precedence over any
        // user-chosen folder so templates land in the synced container.
        if UserDefaults.standard.bool(forKey: UserDefaultsKeys.templatesICloudEnabled),
           let cloud = iCloudTemplatesURL {
            // Coordinated so the iCloud daemon doesn't fork this folder into
            // "Templates 2" when it races our create with a remote pull.
            try? CloudCoordinatedIO.ensureDirectory(cloud)
            return (cloud, {})
        }
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
