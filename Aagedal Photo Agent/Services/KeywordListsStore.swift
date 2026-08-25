import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "KeywordListsStore")

/// Identifies one of the keyword lists managed by `KeywordListsStore`. Maps 1:1
/// to a stable on-disk path so iCloud sync is deterministic across machines.
enum KeywordListKey: Hashable, CustomStringConvertible {
    case quick(QuickListType)
    case approved(ApprovedListField)
    case structured
    case structuredPersonShown

    /// Relative path under the store root. The path is stable per-key — do not
    /// change it once shipped, or migration logic will need to handle a rename.
    var relativePath: String {
        switch self {
        case .quick(let type):
            return "quick/\(type.rawValue).txt"
        case .approved(let field):
            return "approved/\(field.rawValue).txt"
        case .structured:
            return "structured/keywords.txt"
        case .structuredPersonShown:
            return "structured/personShown.txt"
        }
    }

    /// Folder under root that holds the file. Stored so callers can ensure the
    /// directory exists before writing.
    var directoryComponent: String {
        switch self {
        case .quick: return "quick"
        case .approved: return "approved"
        case .structured, .structuredPersonShown: return "structured"
        }
    }

    var description: String { relativePath }

    /// Human-readable label for the list this key identifies. Used by the
    /// import/export sheets and any other settings UI that lists keys.
    var displayName: String {
        switch self {
        case .quick(let type):
            return "\(type.displayName) Quick List"
        case .approved(let field):
            return "Approved \(field.displayName)"
        case .structured:
            return "Structured Keywords"
        case .structuredPersonShown:
            return "Structured Person Shown"
        }
    }
}

extension Notification.Name {
    /// Posted by `KeywordListsStore` after a write, delete, or remote refresh.
    /// `userInfo[KeywordListsStore.changedKeyUserInfo]` is the `KeywordListKey`.
    static let keywordListChanged = Notification.Name("KeywordListsStore.changed")
}

/// Test-only seam for `KeywordListsStore`'s storage root.
///
/// Declared outside the `@MainActor` class so the `@TaskLocal` projected value
/// is nonisolated — `rootURL` reads `current` and tests set it via
/// `$current.withValue(tempDir) { … }`. It is **task-local** rather than a plain
/// static because Swift Testing runs suites concurrently and several of them
/// write to this shared singleton; a process-wide static override would leak
/// across parallel suites, but a task-local stays confined to the test that set
/// it, so sibling suites writing to the default root remain invisible.
/// Production never sets it.
nonisolated enum KeywordListsStoreStorageOverride {
    @TaskLocal static var current: URL?

    /// Process-wide fallback root used for ALL store I/O while a test run is in
    /// progress and no task-local override is set. The test host launches the
    /// real app, so any test (or app code reacting to a test's write) that hits
    /// the shared singleton outside a `$current.withValue` scope — a
    /// notification observer, a `DispatchQueue.main.async` hop, a suite that
    /// never adopted the seam — would otherwise read and write the user's real
    /// lists, and with sync enabled, the live iCloud container. That actually
    /// happened: test fixtures overwrote and deleted real synced lists. This
    /// fallback makes escaping the task-local harmless.
    static let testProcessFallback: URL? = {
        guard AppPaths.isTestProcess else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "KeywordListsStore-TestFallback-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
    }()
}

/// Canonical disk-backed store for every keyword list the app manages.
///
/// All read/write goes through here so we have a single place to choose between
/// local (`~/Library/Application Support/.../Lists`) and iCloud (ubiquity
/// container) storage and to emit change notifications.
@Observable
@MainActor
final class KeywordListsStore {
    static let shared = KeywordListsStore()
    nonisolated static let changedKeyUserInfo = "key"

    /// Injectable so focused migration tests do not mutate launch UI state.
    static var migrationRecoveryNotices = MigrationRecoveryNoticeCenter.shared

    /// Test seam for stale, unavailable, and subsequently recovered legacy
    /// bookmarks. Production uses security-scoped bookmark resolution.
    static var legacyBookmarkResolver: (Data) -> URL? = { data in
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// iCloud container identifier. Must match the entry in the entitlements file.
    static let iCloudContainerID = "iCloud.aagedal.Aagedal-Photo-Agent"

    /// Bumped whenever the backing root changes (e.g. iCloud toggled) so SwiftUI
    /// views observing the store re-evaluate `url(for:)` derived values.
    private(set) var version: Int = 0

    /// Set to a non-nil string when `setICloudEnabled` fails so Settings can
    /// surface the reason. Cleared on the next successful toggle attempt.
    private(set) var lastSyncError: String?

    @ObservationIgnored private var cachedRoot: URL?

    init() {
        // Ensure the local directory skeleton exists. We intentionally do NOT
        // touch `rootURL` here: resolving the iCloud container this early in
        // launch can momentarily fail and (pre-fix) pinned the cached root to
        // local for the whole session. iCloud directories are created lazily on
        // first write (CloudCoordinatedIO ensures the parent) and by the cloud
        // coordinator when it starts its metadata query.
        ensureDirectories(at: localRootURL)
    }

    // MARK: - Root resolution

    /// Whether the user has opted into iCloud sync. The actual effective root may
    /// fall back to local if iCloud is unavailable (no account, no entitlement).
    var iCloudEnabled: Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.keywordListsICloudEnabled)
    }

    /// Returns the current ubiquity container's `Documents/Lists` directory if
    /// iCloud is reachable, else nil. The check runs off the main thread when
    /// called from the coordinator; it is safe to call from main too — Apple
    /// docs note the call can block briefly on first use.
    var iCloudContainerListsURL: URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: Self.iCloudContainerID) else {
            return nil
        }
        return container.appendingPathComponent("Documents/Lists", isDirectory: true)
    }

    /// Local fallback root: `<App Support>/Aagedal Photo Agent/Lists`.
    var localRootURL: URL {
        AppPaths.applicationSupport.appendingPathComponent("Lists", isDirectory: true)
    }

    /// Effective root: iCloud container if opted-in and available, else local.
    ///
    /// The resolved root is cached only when it is *final*: local when iCloud is
    /// off, or the ubiquity container once it actually resolves. When iCloud is
    /// on but the container isn't ready yet (the daemon can still be provisioning
    /// it right after launch) we return local **without caching**, so a later
    /// access re-resolves and picks up the container as soon as it appears.
    /// Caching local in that window would pin the store to local for the entire
    /// session and silently stop syncing — the cause of lists reverting on launch.
    var rootURL: URL {
        if let override = KeywordListsStoreStorageOverride.current {
            // Test seam: never cached, so each test's task-local root is honored
            // and never pins the singleton for the rest of the process.
            ensureDirectories(at: override)
            return override
        }
        if let testRoot = KeywordListsStoreStorageOverride.testProcessFallback {
            // Test run without a task-local override: never touch real data.
            ensureDirectories(at: testRoot)
            return testRoot
        }
        if let cached = cachedRoot { return cached }
        if iCloudEnabled {
            if let cloud = iCloudContainerListsURL {
                cachedRoot = cloud
                return cloud
            }
            logger.warning("iCloud enabled but ubiquity container unavailable; using local root transiently (will re-resolve)")
            return localRootURL
        }
        cachedRoot = localRootURL
        return localRootURL
    }

    // MARK: - Public read/write

    func url(for key: KeywordListKey) -> URL {
        rootURL.appendingPathComponent(key.relativePath)
    }

    func exists(_ key: KeywordListKey) -> Bool {
        CloudCoordinatedIO.itemExists(at: url(for: key))
    }

    func readText(_ key: KeywordListKey) -> String? {
        let target = url(for: key)
        guard CloudCoordinatedIO.itemExists(at: target) else { return nil }
        do {
            let data = try CloudCoordinatedIO.readData(at: target)
            return String(decoding: data, as: UTF8.self)
        } catch {
            logger.error("Failed to read \(key.relativePath, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// Reads the file and returns its line-delimited entries (skipping blanks
    /// and `#`-comment lines). Convenience for the flat list types.
    func readEntries(_ key: KeywordListKey) -> [String] {
        guard let text = readText(key) else { return [] }
        return ApprovedListParser.parseString(text, csv: false)
    }

    /// Writes `text` to the file atomically and posts `.keywordListChanged`.
    func writeText(_ text: String, to key: KeywordListKey) throws {
        let target = url(for: key)
        try CloudCoordinatedIO.writeText(text, to: target)
        notifyChanged(key)
    }

    /// Writes a list of entries one-per-line. Sanitizes whitespace and dedupes
    /// case-sensitively (callers can lowercase if they want a stricter rule).
    func writeEntries(_ entries: [String], to key: KeywordListKey) throws {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }
        let joined = ordered.joined(separator: "\n") + (ordered.isEmpty ? "" : "\n")
        try writeText(joined, to: key)
    }

    func delete(_ key: KeywordListKey) {
        try? CloudCoordinatedIO.removeItem(at: url(for: key))
        notifyChanged(key)
    }

    /// Convenience for editors that want to import a user-picked file directly.
    /// Reads the file, parses, and writes through the store. Returns the parsed
    /// entry list so callers can show a count toast.
    @discardableResult
    func importEntries(from source: URL, into key: KeywordListKey) throws -> [String] {
        let didStart = source.startAccessingSecurityScopedResource()
        defer { if didStart { source.stopAccessingSecurityScopedResource() } }
        let entries = try ApprovedListParser.parse(source)
        try writeEntries(entries, to: key)
        return entries
    }

    /// Convenience for the structured-tree file (preserves indentation/syntax).
    @discardableResult
    func importText(from source: URL, into key: KeywordListKey) throws -> String {
        let didStart = source.startAccessingSecurityScopedResource()
        defer { if didStart { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw NSError(domain: "KeywordListsStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not decode file contents as text."])
        }
        try writeText(text, to: key)
        return text
    }

    // MARK: - iCloud routing

    /// Atomically switches between local and iCloud storage. Copies all existing
    /// files from the old root to the new (overwriting same-name files on the
    /// target) and updates the preference. Falls back to local if the user asks
    /// for iCloud but the ubiquity container is unavailable.
    @discardableResult
    func setICloudEnabled(_ enabled: Bool) -> Bool {
        lastSyncError = nil
        if enabled {
            guard let cloud = iCloudContainerListsURL else {
                lastSyncError = "iCloud Drive is not available. Sign in to iCloud in System Settings and enable iCloud Drive for this app."
                bumpVersion()
                return false
            }
            do {
                try mergeTree(from: localRootURL, to: cloud)
                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.keywordListsICloudEnabled)
                resetRootCache()
                bumpVersion()
                return true
            } catch {
                lastSyncError = "Could not copy lists into iCloud Drive: \(error.localizedDescription)"
                bumpVersion()
                return false
            }
        } else {
            let current = rootURL
            UserDefaults.standard.set(false, forKey: UserDefaultsKeys.keywordListsICloudEnabled)
            resetRootCache()
            let local = localRootURL
            // Best-effort merge back so the user still has access locally after
            // toggle off, without clobbering anything already present locally.
            try? mergeTree(from: current, to: local)
            bumpVersion()
            return true
        }
    }

    /// Called by the iCloud coordinator when an NSMetadataQuery update arrives.
    /// Forces observers to re-fetch by bumping the version and broadcasting
    /// per-key change notifications.
    func notifyRemoteUpdate() {
        bumpVersion()
        for key in allKnownKeys() {
            notifyChanged(key)
        }
    }

    // MARK: - Migration

    /// One-shot import of legacy bookmark-pointed files into the managed store.
    /// Idempotent and retryable: every source records completion separately,
    /// and the global stamp advances only when no configured source failed.
    /// Legacy bookmark bytes are intentionally retained as recovery evidence.
    func migrateLegacyBookmarksIfNeeded() {
        let stamp = UserDefaults.standard.integer(forKey: UserDefaultsKeys.keywordListsMigratedVersion)
        if stamp >= 1 {
            Self.migrationRecoveryNotices.clear(.keywordLists)
            return
        }

        var completed = Set(
            UserDefaults.standard.stringArray(
                forKey: UserDefaultsKeys.keywordListsMigrationCompletedKeys
            ) ?? []
        )
        var hadFailure = false

        // Approved list (single field today: .keywords)
        for field in ApprovedListField.allCases {
            let migrationID = "approved:\(field.rawValue)"
            guard !completed.contains(migrationID) else { continue }
            migrateLegacySource(
                id: migrationID,
                bookmarkKey: field.bookmarkKey,
                completed: &completed,
                hadFailure: &hadFailure
            ) { url in
                let entries = try ApprovedListParser.parse(url)
                let expected = normalizedEntries(entries)
                try writeEntries(entries, to: .approved(field))
                guard readEntries(.approved(field)) == expected else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }

        // Structured keywords
        migrateLegacySource(
            id: "structured",
            bookmarkKey: UserDefaultsKeys.structuredKeywordsBookmark,
            completed: &completed,
            hadFailure: &hadFailure
        ) { url in
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            try writeText(text, to: .structured)
            guard readText(.structured) == text else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        // Quick lists (8)
        for type in QuickListType.allCases {
            let migrationID = "quick:\(type.rawValue)"
            guard !completed.contains(migrationID) else { continue }
            migrateLegacySource(
                id: migrationID,
                bookmarkKey: type.bookmarkKey,
                completed: &completed,
                hadFailure: &hadFailure
            ) { url in
                let text = try String(contentsOf: url, encoding: .utf8)
                let lines = text
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let expected = normalizedEntries(lines)
                try writeEntries(lines, to: .quick(type))
                guard readEntries(.quick(type)) == expected else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }

        UserDefaults.standard.set(
            completed.sorted(),
            forKey: UserDefaultsKeys.keywordListsMigrationCompletedKeys
        )
        if !hadFailure {
            UserDefaults.standard.set(1, forKey: UserDefaultsKeys.keywordListsMigratedVersion)
            Self.migrationRecoveryNotices.clear(.keywordLists)
        } else {
            Self.migrationRecoveryNotices.recordFailure(in: .keywordLists)
        }
    }

    private func migrateLegacySource(
        id: String,
        bookmarkKey: String,
        completed: inout Set<String>,
        hadFailure: inout Bool,
        importAndVerify: (URL) throws -> Void
    ) {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            completed.insert(id)
            return
        }
        guard let url = Self.legacyBookmarkResolver(bookmarkData) else {
            hadFailure = true
            logger.error("Legacy list migration could not resolve \(id, privacy: .private(mask: .hash)); it will retry")
            return
        }

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            try importAndVerify(url)
            completed.insert(id)
        } catch {
            hadFailure = true
            logger.error("Legacy list migration failed for \(id, privacy: .private(mask: .hash)); it will retry: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func normalizedEntries(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    // MARK: - Internals

    private func bumpVersion() { version &+= 1 }

    private func resetRootCache() {
        cachedRoot = nil
        ensureDirectories(at: rootURL)
    }

    private func ensureDirectories(at root: URL) {
        for sub in ["quick", "approved", "structured"] {
            let dir = root.appendingPathComponent(sub, isDirectory: true)
            try? CloudCoordinatedIO.ensureDirectory(dir)
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        try CloudCoordinatedIO.ensureDirectory(url)
    }

    private func notifyChanged(_ key: KeywordListKey) {
        bumpVersion()
        NotificationCenter.default.post(
            name: .keywordListChanged,
            object: self,
            userInfo: [Self.changedKeyUserInfo: key]
        )
    }

    private func allKnownKeys() -> [KeywordListKey] {
        var keys: [KeywordListKey] = []
        keys.append(contentsOf: QuickListType.allCases.map { KeywordListKey.quick($0) })
        keys.append(contentsOf: ApprovedListField.allCases.map { KeywordListKey.approved($0) })
        keys.append(.structured)
        keys.append(.structuredPersonShown)
        return keys
    }

    private func resolveBookmarkData(forKey key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return Self.legacyBookmarkResolver(data)
    }

    /// Non-destructively brings `source`'s lists into `destination` when toggling
    /// iCloud on or off.
    ///
    /// Keyword lists use *fixed* filenames (e.g. `quick/keywords.txt`), so a
    /// straight copy overwrites by name — and because the destination may already
    /// hold another device's synced content, that silently destroys it. Instead:
    ///
    /// - Flat lists (`quick`, `approved`) are merged by **union of entries**
    ///   (destination order preserved, new source entries appended).
    /// - The structured tree is free-form text we can't safely merge line-by-line,
    ///   so it is **seeded only when the destination has none** — an existing
    ///   destination tree is left untouched rather than clobbered.
    private func mergeTree(from source: URL, to destination: URL) throws {
        try CloudCoordinatedIO.ensureDirectory(destination)
        for key in allKnownKeys() {
            let sourceURL = source.appendingPathComponent(key.relativePath)
            guard CloudCoordinatedIO.itemExists(at: sourceURL) else { continue }
            let destURL = destination.appendingPathComponent(key.relativePath)
            switch key {
            case .quick, .approved:
                let destEntries = entries(at: destURL)
                var seen = Set(destEntries)
                var merged = destEntries
                for entry in entries(at: sourceURL) where seen.insert(entry).inserted {
                    merged.append(entry)
                }
                let joined = merged.joined(separator: "\n") + (merged.isEmpty ? "" : "\n")
                try CloudCoordinatedIO.writeText(joined, to: destURL)
            case .structured, .structuredPersonShown:
                guard !CloudCoordinatedIO.itemExists(at: destURL) else { continue }
                let data = try CloudCoordinatedIO.readData(at: sourceURL)
                try CloudCoordinatedIO.writeData(data, to: destURL)
            }
        }
    }

    /// Reads line entries from an explicit file URL (used by `mergeTree`, which
    /// must read both roots regardless of which one is currently active).
    private func entries(at url: URL) -> [String] {
        guard CloudCoordinatedIO.itemExists(at: url),
              let data = try? CloudCoordinatedIO.readData(at: url) else { return [] }
        return ApprovedListParser.parseString(String(decoding: data, as: UTF8.self), csv: false)
    }
}
