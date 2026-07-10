import Foundation
import os

nonisolated private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "AppPaths")

nonisolated enum AppPaths {
    /// True when this process hosts a test run (the app is launched as the test
    /// host, so XCTest/Swift Testing is loaded). Services that touch real user
    /// data — the keyword-list store, its backup service — check this to avoid
    /// reading from or writing to the user's live files (or the iCloud
    /// container) during tests.
    static let isTestProcess: Bool = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil

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

    /// Teams library folder inside the ubiquity container.
    static var iCloudTeamsURL: URL? {
        iCloudDocuments?.appendingPathComponent("Teams", isDirectory: true)
    }

    /// Watermark library folder inside the ubiquity container.
    static var iCloudWatermarksURL: URL? {
        iCloudDocuments?.appendingPathComponent("Watermarks", isDirectory: true)
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

    /// Cached public trust anchors used to establish C2PA signer trust. These are
    /// local application data, never iCloud-synced user content.
    static var c2paTrustDirectory: URL {
        let url = applicationSupport.appendingPathComponent("C2PATrust", isDirectory: true)
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

/// Process-wide `UserDefaults` seam, the defaults counterpart of
/// `KeywordListsStoreStorageOverride.testProcessFallback`.
///
/// The unit tests run with the real app as the test host, so
/// `UserDefaults.standard` in a test process IS the user's live settings —
/// suites that clear or set keys (approved-list mode/enabled, metadata write
/// preset) were persisting into them. Any service whose defaults keys are
/// mutated by tests must read and write through `AppDefaults.store`, and the
/// tests must do the same, so a test run stays inside a throwaway suite that
/// is wiped at process start. Production behaviour is unchanged: outside a
/// test process this is exactly `UserDefaults.standard`.
nonisolated enum AppDefaults {
    // UserDefaults is documented thread-safe but not marked Sendable in the SDK.
    nonisolated(unsafe) static let store: UserDefaults = {
        guard AppPaths.isTestProcess else { return .standard }
        let suiteName = "com.aagedal.photo-agent.tests"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            // Only happens if the suite name collides with the bundle ID or
            // global domain. Crash rather than silently touch real settings.
            preconditionFailure("Could not create test UserDefaults suite \(suiteName)")
        }
        // Fresh slate every run; also prevents leakage between test runs.
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }()
}
