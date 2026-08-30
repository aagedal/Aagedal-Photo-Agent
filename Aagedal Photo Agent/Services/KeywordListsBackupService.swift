import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "KeywordListsBackupService")

nonisolated struct KeywordListBackupPreviewSnapshot: Equatable, Sendable {
    let requestID: UUID
    let sourceURL: URL
    let text: String
    let byteCount: Int
}

nonisolated enum KeywordListBackupPreviewResult: Equatable, Sendable {
    case loaded(KeywordListBackupPreviewSnapshot)
    case cancelledBeforeRead(requestID: UUID)
    case cancelledAfterRead(requestID: UUID, sourceURL: URL, byteCount: Int)
}

nonisolated enum KeywordListBackupPreviewError: LocalizedError, Equatable {
    case invalidUTF8(URL)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "The backup is not valid UTF-8 text."
        }
    }
}

nonisolated struct KeywordListBackupPreviewReader: Sendable {
    let read: @Sendable (URL) throws -> Data

    static let system = KeywordListBackupPreviewReader { url in
        try Data(contentsOf: url, options: .mappedIfSafe)
    }
}

/// Serializes backup-preview reads away from MainActor. The Foundation read cannot be preempted
/// once entered, so cancellation after that point returns byte-count evidence but never publishes
/// text that belongs to a superseded preview request.
actor KeywordListBackupPreviewService {
    static let shared = KeywordListBackupPreviewService()

    private let reader: KeywordListBackupPreviewReader

    init(reader: KeywordListBackupPreviewReader = .system) {
        self.reader = reader
    }

    func loadPreview(
        from sourceURL: URL,
        requestID: UUID
    ) throws -> KeywordListBackupPreviewResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID)
        }

        let data = try reader.read(sourceURL)
        guard !Task.isCancelled else {
            return .cancelledAfterRead(
                requestID: requestID,
                sourceURL: sourceURL,
                byteCount: data.count
            )
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw KeywordListBackupPreviewError.invalidUTF8(sourceURL)
        }

        guard !Task.isCancelled else {
            return .cancelledAfterRead(
                requestID: requestID,
                sourceURL: sourceURL,
                byteCount: data.count
            )
        }

        return .loaded(KeywordListBackupPreviewSnapshot(
            requestID: requestID,
            sourceURL: sourceURL,
            text: text,
            byteCount: data.count
        ))
    }
}

/// Keeps timestamped **local** backups of every keyword list managed by
/// `KeywordListsStore`, so a list that disappears — e.g. an unlucky iCloud
/// launch that reads an empty/stub file, or a sync conflict that drops content
/// — can always be restored.
///
/// Design invariants:
/// - Backups live under Application Support (`ListBackups/`), **never** in the
///   iCloud container. They are the safety net *against* sync loss and must not
///   themselves sync.
/// - Empty/missing content is never snapshotted, so a bad (empty) read can't
///   poison or evict good history.
/// - A snapshot is written only when content differs from the newest existing
///   snapshot for that key (content de-dup), so the frequent
///   `.keywordListChanged` notifications (writes, imports, remote syncs) don't
///   bloat history. Writing a backup file does not post that notification, so
///   the change observer never feeds back on itself.
/// - Retention prunes snapshots older than `retentionDays` but always keeps at
///   least `minVersionsPerKey` newest, so a rarely-edited list is never lost.
@MainActor
@Observable
final class KeywordListsBackupService {
    static let shared = KeywordListsBackupService()

    /// One stored snapshot of a single list.
    struct Version: Identifiable {
        let key: KeywordListKey
        let url: URL
        let date: Date
        /// Keyword count (structured) or entry count (flat lists).
        let entryCount: Int
        let byteCount: Int
        var id: URL { url }
    }

    /// Keys that read empty/missing while a non-empty backup exists. Drives the
    /// launch restore prompt; empty when there's nothing to recover. Observed by
    /// the UI, so updating it reactively shows/hides the prompt.
    private(set) var recoverableKeys: [KeywordListKey] = []

    /// Backups older than this are eligible for pruning…
    private let retentionDays = 30
    /// …unless they're among the newest this-many for the key (so a list edited
    /// once long ago still keeps its backup).
    private let minVersionsPerKey = 5

    private var started = false
    private var observer: NSObjectProtocol?
    private let fileManager = FileManager.default

    /// Every list the store manages. Same enumeration the archive uses.
    private static let allKeys: [KeywordListKey] = {
        var keys: [KeywordListKey] = []
        keys.append(contentsOf: QuickListType.allCases.map { KeywordListKey.quick($0) })
        keys.append(contentsOf: ApprovedListField.allCases.map { KeywordListKey.approved($0) })
        keys.append(.structured)
        keys.append(.structuredPersonShown)
        return keys
    }()

    private init() {}

    // MARK: - Lifecycle

    /// Idempotent. Installs the change observer, takes an initial snapshot of
    /// every list, prunes, then schedules a delayed recovery check (the iCloud
    /// container may still be resolving at launch, so an immediate check could
    /// false-flag a list whose synced file hasn't downloaded yet).
    func start() {
        guard !started else { return }
        // The test host launches the full app, which calls start(). Snapshotting
        // there would capture test-fixture list content into the user's real
        // backup history (and the recovery prompt could fire mid-test-run).
        guard !AppPaths.isTestProcess else { return }
        started = true

        observer = NotificationCenter.default.addObserver(
            forName: .keywordListChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // KeywordListKey is an enum of Sendable payloads; extract it before
            // hopping onto the main actor (the Notification itself isn't Sendable).
            let key = note.userInfo?[KeywordListsStore.changedKeyUserInfo] as? KeywordListKey
            Task { @MainActor [weak self] in
                guard let self, let key else { return }
                self.snapshot(key)
                self.refreshRecoverable()
            }
        }

        snapshotAll()
        pruneAll()

        // Give iCloud a grace window to materialize files before deciding a list
        // is "missing". The change observer also refreshes recoverable state as
        // soon as a remote file lands, so this just covers the quiet case.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            self?.refreshRecoverable()
        }
    }

    // MARK: - Snapshotting

    private func snapshotAll() {
        for key in Self.allKeys { snapshot(key) }
    }

    /// Captures the current content of `key` if it's non-empty and differs from
    /// the most recent snapshot. Returns true if a new snapshot was written.
    @discardableResult
    private func snapshot(_ key: KeywordListKey) -> Bool {
        let store = KeywordListsStore.shared
        guard let text = store.readText(key),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let dir = directory(for: key)
        // De-dup against the newest existing snapshot.
        if let newest = newestFileURL(in: dir),
           let existing = try? String(contentsOf: newest, encoding: .utf8),
           existing == text {
            return false
        }

        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(Self.snapshotFileName(for: Date()))
            try Data(text.utf8).write(to: dest, options: .atomic)
            prune(key)
            return true
        } catch {
            logger.error("Failed to snapshot \(key.relativePath, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private)")
            return false
        }
    }

    // MARK: - Reading versions

    /// Snapshots for `key`, newest first.
    func versions(for key: KeywordListKey) -> [Version] {
        let dir = directory(for: key)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [Version] = []
        for url in urls where url.pathExtension == "txt" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            result.append(Version(
                key: key,
                url: url,
                date: values?.contentModificationDate ?? .distantPast,
                entryCount: Self.entryCount(for: key, text: text),
                byteCount: values?.fileSize ?? text.utf8.count
            ))
        }
        return result.sorted { $0.date > $1.date }
    }

    /// All keys that currently have at least one stored snapshot, paired with
    /// their version history. Used by the restore UI.
    func allVersionsByKey() -> [(key: KeywordListKey, versions: [Version])] {
        Self.allKeys.compactMap { key in
            let vers = versions(for: key)
            return vers.isEmpty ? nil : (key, vers)
        }
    }

    // MARK: - Restore

    /// Restores `version` by writing it back through the store, which propagates
    /// to iCloud and notifies observers. The store write re-snapshots the
    /// restored content, so the action itself is captured in history.
    @discardableResult
    func restore(_ version: Version) -> Bool {
        guard let text = try? String(contentsOf: version.url, encoding: .utf8) else {
            logger.error("Restore failed: could not read \(version.url.lastPathComponent, privacy: .private(mask: .hash))")
            return false
        }
        do {
            try KeywordListsStore.shared.writeText(text, to: version.key)
            refreshRecoverable()
            return true
        } catch {
            logger.error("Restore failed for \(version.key.relativePath, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private)")
            return false
        }
    }

    // MARK: - Recovery detection

    /// Recomputes which lists look empty while a backup exists.
    func refreshRecoverable() {
        let store = KeywordListsStore.shared
        recoverableKeys = Self.allKeys.filter { key in
            let text = store.readText(key)
            let isEmpty = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            return isEmpty && !versions(for: key).isEmpty
        }
    }

    // MARK: - Pruning

    private func pruneAll() {
        for key in Self.allKeys { prune(key) }
    }

    /// Keeps the newest `minVersionsPerKey` regardless of age and any others
    /// within `retentionDays`; deletes the rest.
    private func prune(_ key: KeywordListKey) {
        let vers = versions(for: key) // newest first
        guard vers.count > minVersionsPerKey else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        for (index, version) in vers.enumerated() where index >= minVersionsPerKey {
            if version.date < cutoff {
                try? fileManager.removeItem(at: version.url)
            }
        }
    }

    // MARK: - Paths & helpers

    /// `<App Support>/Aagedal Photo Agent/ListBackups`.
    private var backupRoot: URL {
        AppPaths.applicationSupport.appendingPathComponent("ListBackups", isDirectory: true)
    }

    private func directory(for key: KeywordListKey) -> URL {
        backupRoot.appendingPathComponent(Self.slug(for: key), isDirectory: true)
    }

    /// Stable folder name per key, e.g. `structured/keywords.txt` → `structured-keywords`.
    private static func slug(for key: KeywordListKey) -> String {
        key.relativePath
            .replacingOccurrences(of: ".txt", with: "")
            .replacingOccurrences(of: "/", with: "-")
    }

    /// Newest snapshot file in `dir` (filenames sort chronologically). nil if none.
    private func newestFileURL(in dir: URL) -> URL? {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return urls.filter { $0.pathExtension == "txt" }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// UTC timestamp filename with fractional seconds (collision-resistant) and
    /// colons stripped so it reads cleanly in Finder, e.g. `2026-06-08T143000.123Z.txt`.
    private static func snapshotFileName(for date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        let stamp = f.string(from: date).replacingOccurrences(of: ":", with: "")
        return stamp + ".txt"
    }

    private static func entryCount(for key: KeywordListKey, text: String) -> Int {
        switch key {
        case .structured, .structuredPersonShown:
            return StructuredKeywordParser.parseString(text).reduce(0) { $0 + countKeywords(in: $1) }
        case .quick, .approved:
            return ApprovedListParser.parseString(text, csv: false).count
        }
    }

    private static func countKeywords(in node: StructuredKeyword) -> Int {
        var n = node.isKeyword ? 1 : 0
        for child in node.children { n += countKeywords(in: child) }
        return n
    }
}
