import Foundation
import Observation

/// Identifies one of the keyword lists managed by `KeywordListsStore`. Maps 1:1
/// to a stable on-disk path so iCloud sync is deterministic across machines.
nonisolated enum KeywordListKey: Hashable, CustomStringConvertible, Sendable {
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
/// is nonisolated — `resolveRootURL()` reads `current` and tests set it via
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
/// Resolves local or iCloud routes and publishes committed changes. Blocking reads and writes
/// belong to services isolated to `KeywordListsFilesystemActor`.
@Observable
@MainActor
final class KeywordListsStore {
    static let shared = KeywordListsStore()
    nonisolated static let changedKeyUserInfo = "key"
    nonisolated static let changedDestinationURLUserInfo = "destinationURL"
    nonisolated static let changedEntriesUserInfo = "entries"
    nonisolated static let changedTextUserInfo = "text"
    nonisolated static let changedSourceIDUserInfo = "sourceID"

    /// Injectable so focused migration tests do not mutate launch UI state.
    static var migrationRecoveryNotices = MigrationRecoveryNoticeCenter.shared

    /// Test seam for stale, unavailable, and subsequently recovered legacy
    /// bookmarks. Production uses security-scoped bookmark resolution.
    static var legacyBookmarkResolver: @Sendable (Data) -> URL? = { data in
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// iCloud container identifier. Must match the entry in the entitlements file.
    nonisolated static let iCloudContainerID = "iCloud.aagedal.Aagedal-Photo-Agent"

    /// Bumped whenever the backing root changes (e.g. iCloud toggled) so SwiftUI
    /// views observing the store re-evaluate `currentURL(for:)` derived values.
    private(set) var version: Int = 0

    /// Cached active root, invalidated only after the routing actor has reconciled
    /// the destination and the coordinator installs the new preference.
    @ObservationIgnored private var cachedRoot: URL?
    @ObservationIgnored private var routingGeneration = UUID()

    // Directories are prepared by coordinated writes and routing reconciliation. Merely
    // constructing the observable store or resolving a path must not touch the filesystem.
    @ObservationIgnored private let resolveCloudRoot: @Sendable () async -> URL?
    @ObservationIgnored private let usesTestStorage: Bool
    @ObservationIgnored private let cloudPreference: (() -> Bool)?

    /// Injection keeps routing-race tests isolated from both real cloud storage and preferences.
    init(
        usesTestStorage: Bool = true,
        cloudPreference: (() -> Bool)? = nil,
        resolveCloudRoot: @escaping @Sendable () async -> URL? = {
            await KeywordListsRootResolutionService.shared.resolve()
        }
    ) {
        self.usesTestStorage = usesTestStorage
        self.cloudPreference = cloudPreference
        self.resolveCloudRoot = resolveCloudRoot
    }

    // MARK: - Root resolution

    /// Whether the user has opted into iCloud sync. The actual effective root may
    /// fall back to local if iCloud is unavailable (no account, no entitlement).
    var iCloudEnabled: Bool {
        cloudPreference?() ?? UserDefaults.standard.bool(forKey: UserDefaultsKeys.keywordListsICloudEnabled)
    }

    /// Local fallback root: `<App Support>/Aagedal Photo Agent/Lists`.
    var localRootURL: URL {
        AppPaths.applicationSupport.appendingPathComponent("Lists", isDirectory: true)
    }

    /// A nonblocking route snapshot for stale-result comparisons after asynchronous resolution.
    /// Call `resolveURL(for:)` before starting new filesystem work.
    func currentURL(for key: KeywordListKey) -> URL {
        currentRootURL.appendingPathComponent(key.relativePath)
    }

    private var testStorageRoot: URL? {
        usesTestStorage ? (KeywordListsStoreStorageOverride.current
            ?? KeywordListsStoreStorageOverride.testProcessFallback) : nil
    }

    var currentRootURL: URL {
        testStorageRoot ?? cachedRoot ?? localRootURL
    }

    /// Ubiquity lookup can block during provisioning. Resolve it on a filesystem actor and
    /// discard a result if a routing preference was installed while the lookup was suspended.
    func resolveRootURL() async throws -> URL {
        while true {
            try Task.checkCancellation()
            if let root = testStorageRoot { return root }
            if let cachedRoot { return cachedRoot }
            guard iCloudEnabled else {
                cachedRoot = localRootURL
                return localRootURL
            }
            let generation = routingGeneration
            let cloud = await resolveCloudRoot()
            try Task.checkCancellation()
            guard generation == routingGeneration else { continue }
            if let cloud {
                cachedRoot = cloud
                return cloud
            }
            // Do not cache a transient fallback: subsequent requests retry provisioning.
            return localRootURL
        }
    }

    func resolveURL(for key: KeywordListKey) async throws -> URL {
        try await resolveRootURL().appendingPathComponent(key.relativePath)
    }

    // MARK: - Change publication

    /// Publishes a write already committed by a serialized filesystem service.
    /// The service owns the blocking coordinated write; the main actor only updates
    /// observable state and delivers change notifications.
    func recordExternalWrite(
        to key: KeywordListKey,
        destinationURL: URL? = nil,
        entries: [String]? = nil,
        text: String? = nil,
        sourceID: UUID? = nil
    ) {
        // A durable write can finish after routing switches roots. Invalidate observers but
        // never advertise its old-root payload as the active list. Clear source identity too,
        // since owners otherwise suppress their own invalidation notification.
        if let destinationURL, destinationURL != currentURL(for: key) {
            notifyChanged(key)
        } else {
            notifyChanged(key, entries: entries, text: text, sourceID: sourceID)
        }
    }

    /// Publishes a removal already committed by a serialized filesystem service.
    func recordExternalDeletion(to key: KeywordListKey, sourceID: UUID? = nil) {
        notifyChanged(key, sourceID: sourceID)
    }

    /// Installs the route chosen by `KeywordListsRoutingService` after its coordinated merge has
    /// completed away from MainActor. The destination skeleton already exists at this point, so
    /// publication only changes the preference/cache and invalidates observers.
    func applyICloudRoutingPreference(_ enabled: Bool, resolvedRoot: URL? = nil) {
        if cloudPreference == nil {
            UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.keywordListsICloudEnabled)
        }
        routingGeneration = UUID()
        cachedRoot = resolvedRoot
        bumpVersion()
        for key in Self.allKnownKeys() {
            notifyChanged(key)
        }
    }

    /// Called by the iCloud coordinator when an NSMetadataQuery update arrives.
    /// Forces observers to re-fetch by bumping the version and broadcasting
    /// per-key change notifications.
    func notifyRemoteUpdate() {
        bumpVersion()
        for key in Self.allKnownKeys() {
            notifyChanged(key)
        }
    }

    // MARK: - Migration

    @ObservationIgnored private var activeMigrationID: UUID?

    /// Captures preferences on MainActor, then resolves and imports legacy files on a serialized
    /// filesystem actor. Each verified source is retained even if cancellation interrupts later work.
    func migrateLegacyBookmarksIfNeeded() async {
        guard activeMigrationID == nil else { return }
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: UserDefaultsKeys.keywordListsMigratedVersion) < 1 else {
            Self.migrationRecoveryNotices.clear(.keywordLists)
            return
        }
        guard !Task.isCancelled else { return }

        let requestID = UUID()
        activeMigrationID = requestID
        defer { activeMigrationID = nil }
        guard let capturedRoot = try? await resolveRootURL() else { return }
        let capturedVersion = version
        let completed = Set(defaults.stringArray(
            forKey: UserDefaultsKeys.keywordListsMigrationCompletedKeys
        ) ?? [])
        var sources: [KeywordListsLegacyMigrationSource] = []
        func append(_ id: String, _ bookmarkKey: String, _ key: KeywordListKey,
                    _ format: KeywordListsLegacyMigrationSource.Format) {
            guard !completed.contains(id) else { return }
            sources.append(KeywordListsLegacyMigrationSource(
                id: id, bookmarkKey: bookmarkKey, bookmarkData: defaults.data(forKey: bookmarkKey),
                key: key, destinationURL: capturedRoot.appendingPathComponent(key.relativePath),
                format: format
            ))
        }
        for field in ApprovedListField.allCases {
            append("approved:\(field.rawValue)", field.bookmarkKey, .approved(field), .approved)
        }
        append("structured", UserDefaultsKeys.structuredKeywordsBookmark, .structured, .structured)
        for type in QuickListType.allCases {
            append("quick:\(type.rawValue)", type.bookmarkKey, .quick(type), .quick)
        }
        let result = await KeywordListsLegacyMigrationService.shared.migrate(
            sources: sources, requestID: requestID, resolveBookmark: Self.legacyBookmarkResolver
        )
        // Durable writes invalidate the active route even if another edit or bookmark change made
        // completion stamps stale. Notifications carry no stale contents; readers reload the file.
        let unchangedVersion = version == capturedVersion
        guard activeMigrationID == result.requestID, currentRootURL == capturedRoot else { return }
        for source in sources where result.writtenIDs.contains(source.id) {
            notifyChanged(source.key)
        }
        guard unchangedVersion else { return }
        let unchangedSources = sources.filter {
            defaults.data(forKey: $0.bookmarkKey) == $0.bookmarkData
        }
        let unchangedIDs = Set(unchangedSources.map(\.id))
        let verified = completed.union(result.completedIDs.filter { unchangedIDs.contains($0) })
        defaults.set(verified.sorted(), forKey: UserDefaultsKeys.keywordListsMigrationCompletedKeys)
        if !Task.isCancelled, !result.cancelled, result.failedIDs.isEmpty, unchangedSources.count == sources.count {
            defaults.set(1, forKey: UserDefaultsKeys.keywordListsMigratedVersion)
            Self.migrationRecoveryNotices.clear(.keywordLists)
        } else if !result.failedIDs.isEmpty {
            Self.migrationRecoveryNotices.recordFailure(in: .keywordLists)
        }
    }

    /// Managed lists are UTF-8. Lossy replacement would turn damaged bytes into an accepted
    /// merge baseline and overwrite the only recoverable copy during a subsequent write.
    nonisolated static func decodeManagedText(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    // MARK: - Internals

    private func bumpVersion() { version &+= 1 }

    private func notifyChanged(
        _ key: KeywordListKey,
        entries: [String]? = nil,
        text: String? = nil,
        sourceID: UUID? = nil
    ) {
        bumpVersion()
        var userInfo: [String: Any] = [
            Self.changedKeyUserInfo: key,
            Self.changedDestinationURLUserInfo: currentURL(for: key)
        ]
        if let entries {
            userInfo[Self.changedEntriesUserInfo] = entries
        }
        if let text {
            userInfo[Self.changedTextUserInfo] = text
        }
        if let sourceID {
            userInfo[Self.changedSourceIDUserInfo] = sourceID
        }
        NotificationCenter.default.post(
            name: .keywordListChanged,
            object: self,
            userInfo: userInfo
        )
    }

    nonisolated private static func allKnownKeys() -> [KeywordListKey] {
        var keys: [KeywordListKey] = []
        keys.append(contentsOf: QuickListType.allCases.map { KeywordListKey.quick($0) })
        keys.append(contentsOf: ApprovedListField.allCases.map { KeywordListKey.approved($0) })
        keys.append(.structured)
        keys.append(.structuredPersonShown)
        return keys
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
    nonisolated static func reconcileTree(from source: URL, to destination: URL) throws {
        try CloudCoordinatedIO.ensureDirectory(destination)
        for key in allKnownKeys() {
            let sourceURL = source.appendingPathComponent(key.relativePath)
            guard CloudCoordinatedIO.itemExists(at: sourceURL) else { continue }
            let destURL = destination.appendingPathComponent(key.relativePath)
            switch key {
            case .quick, .approved:
                let destEntries = try entries(at: destURL)
                var seen = Set(destEntries)
                var merged = destEntries
                for entry in try entries(at: sourceURL) where seen.insert(entry).inserted {
                    merged.append(entry)
                }
                let joined = merged.joined(separator: "\n") + (merged.isEmpty ? "" : "\n")
                try CloudCoordinatedIO.writeText(joined, to: destURL)
            case .structured, .structuredPersonShown:
                guard !CloudCoordinatedIO.itemExists(at: destURL) else { continue }
                let data = try CloudCoordinatedIO.readData(at: sourceURL)
                _ = try decodeManagedText(data)
                try CloudCoordinatedIO.writeData(data, to: destURL)
            }
        }
    }

    /// Reads line entries from an explicit file URL (used by `reconcileTree`, which
    /// must read both roots regardless of which one is currently active).
    nonisolated private static func entries(at url: URL) throws -> [String] {
        guard CloudCoordinatedIO.itemExists(at: url) else { return [] }
        // An unavailable cloud placeholder or unreadable file is not an empty list.
        // Abort before writing the affected key so a failed read cannot erase its existing entries.
        // Earlier keys may already have committed additive unions; retrying those is idempotent.
        let data = try CloudCoordinatedIO.readData(at: url)
        return ApprovedListParser.parseString(try decodeManagedText(data), csv: false)
    }
}

// MARK: - Legacy migration filesystem boundary

nonisolated struct KeywordListsLegacyMigrationSource: Sendable {
    nonisolated enum Format: Sendable { case approved, quick, structured }
    let id: String
    let bookmarkKey: String
    let bookmarkData: Data?
    let key: KeywordListKey
    let destinationURL: URL
    let format: Format
}

/// Written IDs record durable writes even when their subsequent verification fails. Completed IDs
/// include verified imports, preserved managed destinations, and absent legacy sources. Cancellation never erases this evidence.
nonisolated struct KeywordListsLegacyMigrationResult: Equatable, Sendable {
    let requestID: UUID
    let completedIDs: [String]
    let writtenIDs: [String]
    let failedIDs: [String]
    let cancelled: Bool
}

nonisolated struct KeywordListsLegacyMigrationFileAccess: Sendable {
    let readSource: @Sendable (URL, KeywordListsLegacyMigrationSource.Format) throws -> String
    let writeTextIfMissing: @Sendable (String, URL) throws -> Bool
    let readDestination: @Sendable (URL) throws -> String

    static let system = Self(
        readSource: { url, format in
            switch format {
            case .structured:
                return try String(contentsOf: url, encoding: .utf8)
            case .approved, .quick:
                let entries: [String]
                if case .approved = format {
                    entries = try ApprovedListParser.parse(url)
                } else {
                    entries = try String(contentsOf: url, encoding: .utf8)
                        .components(separatedBy: .newlines)
                }
                var seen = Set<String>()
                let normalized = entries.compactMap { entry -> String? in
                    let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !trimmed.isEmpty && seen.insert(trimmed).inserted ? trimmed : nil
                }
                return normalized.joined(separator: "\n") + (normalized.isEmpty ? "" : "\n")
            }
        },
        writeTextIfMissing: { try CloudCoordinatedIO.writeTextIfMissing($0, to: $1) },
        readDestination: { try KeywordListsStore.decodeManagedText(CloudCoordinatedIO.readData(at: $0)) }
    )
}

/// No suspension occurs within a migration batch, keeping each read/write/verification transaction
/// serialized. Blocking security-scoped and coordinated operations are sampled for cancellation at
/// stable boundaries; a write already entered is verified before its durable evidence is returned.
@KeywordListsFilesystemActor
final class KeywordListsLegacyMigrationService {
    nonisolated static let shared = KeywordListsLegacyMigrationService()
    private let access: KeywordListsLegacyMigrationFileAccess

    nonisolated init(access: KeywordListsLegacyMigrationFileAccess = .system) {
        self.access = access
    }

    func migrate(
        sources: [KeywordListsLegacyMigrationSource],
        requestID: UUID,
        resolveBookmark: @Sendable (Data) -> URL?
    ) -> KeywordListsLegacyMigrationResult {
        var completed: [String] = []
        var written: [String] = []
        var failed: [String] = []
        for source in sources {
            guard !Task.isCancelled else { break }
            guard let bookmark = source.bookmarkData else {
                completed.append(source.id)
                continue
            }
            guard let url = resolveBookmark(bookmark) else {
                if !Task.isCancelled { failed.append(source.id) }
                continue
            }
            guard !Task.isCancelled else { break }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            do {
                guard !Task.isCancelled else { break }
                let text = try access.readSource(url, source.format)
                guard !Task.isCancelled else { break }
                guard try access.writeTextIfMissing(text, source.destinationURL) else {
                    // Managed content takes precedence over legacy data, including an edit that
                    // committed while source parsing was in progress. Keep the bookmark for recovery.
                    completed.append(source.id)
                    continue
                }
                written.append(source.id)
                guard try access.readDestination(source.destinationURL) == text else {
                    throw CocoaError(.fileWriteUnknown)
                }
                completed.append(source.id)
            } catch {
                failed.append(source.id)
            }
        }
        return KeywordListsLegacyMigrationResult(
            requestID: requestID, completedIDs: completed, writtenIDs: written,
            failedIDs: failed, cancelled: Task.isCancelled
        )
    }
}

/// Keeps the potentially blocking first ubiquity lookup off MainActor.
actor KeywordListsRootResolutionService {
    static let shared = KeywordListsRootResolutionService()
    private let resolveContainer: @Sendable () -> URL?

    init(resolveContainer: @escaping @Sendable () -> URL? = {
        FileManager.default.url(forUbiquityContainerIdentifier: KeywordListsStore.iCloudContainerID)
    }) {
        self.resolveContainer = resolveContainer
    }

    func resolve() -> URL? {
        guard !Task.isCancelled else { return nil }
        return resolveContainer()?.appendingPathComponent("Documents/Lists", isDirectory: true)
    }
}
