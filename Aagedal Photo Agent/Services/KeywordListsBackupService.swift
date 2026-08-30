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

nonisolated struct KeywordListBackupDirectoryRequest: Equatable, Sendable {
    let identifier: String
    let directoryURL: URL
}

nonisolated struct KeywordListBackupFileSnapshot: Equatable, Sendable {
    let url: URL
    let date: Date
    let text: String
    let byteCount: Int
}

nonisolated struct KeywordListBackupDirectorySnapshot: Equatable, Sendable {
    let identifier: String
    let versions: [KeywordListBackupFileSnapshot]
}

nonisolated struct KeywordListBackupInventorySnapshot: Equatable, Sendable {
    let requestID: UUID
    let directories: [KeywordListBackupDirectorySnapshot]
}

nonisolated enum KeywordListBackupInventoryResult: Equatable, Sendable {
    case loaded(KeywordListBackupInventorySnapshot)
    case cancelled(
        requestID: UUID,
        completedDirectoryCount: Int,
        discoveredVersionCount: Int
    )
}

nonisolated struct KeywordListBackupRestoreCommit: Equatable, Sendable {
    let requestID: UUID
    let sourceURL: URL
    let destinationURL: URL
    let byteCount: Int
    let cancellationObservedAfterCommit: Bool
}

nonisolated enum KeywordListBackupRestoreResult: Equatable, Sendable {
    case restored(KeywordListBackupRestoreCommit)
    case cancelledBeforeRead(requestID: UUID)
    case cancelledAfterRead(requestID: UUID, sourceURL: URL, byteCount: Int)
}

nonisolated struct KeywordListBackupFileIO: Sendable {
    let contentsOfDirectory: @Sendable (URL) throws -> [URL]
    let inspectTextFile: @Sendable (URL) -> KeywordListBackupFileSnapshot
    let createDirectory: @Sendable (URL) throws -> Void
    let readData: @Sendable (URL) throws -> Data
    let writeData: @Sendable (Data, URL) throws -> Void
    let removeItem: @Sendable (URL) throws -> Void

    static let system = KeywordListBackupFileIO(
        contentsOfDirectory: { directory in
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        },
        inspectTextFile: { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
            let text = String(data: data, encoding: .utf8) ?? ""
            return KeywordListBackupFileSnapshot(
                url: url,
                date: values?.contentModificationDate ?? .distantPast,
                text: text,
                byteCount: values?.fileSize ?? data.count
            )
        },
        createDirectory: { directory in
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        },
        readData: { url in
            try Data(contentsOf: url, options: .mappedIfSafe)
        },
        writeData: { data, url in
            try CloudCoordinatedIO.writeData(data, to: url)
        },
        removeItem: { url in
            try FileManager.default.removeItem(at: url)
        }
    )
}

/// Serializes keyword-backup enumeration, retention, snapshot writes, and restore commits away
/// from MainActor. Directory reads and coordinated writes are synchronous Foundation operations;
/// cancellation is therefore checked between calls, with durable-after-cancel evidence for restore.
actor KeywordListBackupFileService {
    static let shared = KeywordListBackupFileService()

    private let io: KeywordListBackupFileIO

    init(io: KeywordListBackupFileIO = .system) {
        self.io = io
    }

    func inventory(
        directories: [KeywordListBackupDirectoryRequest],
        requestID: UUID
    ) -> KeywordListBackupInventoryResult {
        var snapshots: [KeywordListBackupDirectorySnapshot] = []
        var discoveredVersionCount = 0

        for directory in directories {
            guard !Task.isCancelled else {
                return .cancelled(
                    requestID: requestID,
                    completedDirectoryCount: snapshots.count,
                    discoveredVersionCount: discoveredVersionCount
                )
            }

            let urls = (try? io.contentsOfDirectory(directory.directoryURL)) ?? []
            var versions: [KeywordListBackupFileSnapshot] = []
            for url in urls where url.pathExtension == "txt" {
                guard !Task.isCancelled else {
                    return .cancelled(
                        requestID: requestID,
                        completedDirectoryCount: snapshots.count,
                        discoveredVersionCount: discoveredVersionCount + versions.count
                    )
                }
                versions.append(io.inspectTextFile(url))
            }
            versions.sort { $0.date > $1.date }
            discoveredVersionCount += versions.count
            snapshots.append(KeywordListBackupDirectorySnapshot(
                identifier: directory.identifier,
                versions: versions
            ))
        }

        guard !Task.isCancelled else {
            return .cancelled(
                requestID: requestID,
                completedDirectoryCount: snapshots.count,
                discoveredVersionCount: discoveredVersionCount
            )
        }
        return .loaded(KeywordListBackupInventorySnapshot(
            requestID: requestID,
            directories: snapshots
        ))
    }

    @discardableResult
    func snapshot(
        text: String,
        directoryURL: URL,
        destinationURL: URL,
        retentionCutoff: Date,
        minimumVersionCount: Int
    ) throws -> Bool {
        guard !Task.isCancelled else { return false }
        let existing = textFiles(in: directoryURL)
        if let newest = existing.max(by: { $0.url.lastPathComponent < $1.url.lastPathComponent }),
           newest.text == text {
            return false
        }

        try io.createDirectory(directoryURL)
        guard !Task.isCancelled else { return false }
        try io.writeData(Data(text.utf8), destinationURL)
        prune(
            directoryURL: directoryURL,
            retentionCutoff: retentionCutoff,
            minimumVersionCount: minimumVersionCount
        )
        return true
    }

    func prune(
        directories: [URL],
        retentionCutoff: Date,
        minimumVersionCount: Int
    ) {
        for directoryURL in directories {
            guard !Task.isCancelled else { return }
            prune(
                directoryURL: directoryURL,
                retentionCutoff: retentionCutoff,
                minimumVersionCount: minimumVersionCount
            )
        }
    }

    func restore(
        from sourceURL: URL,
        to destinationURL: URL,
        requestID: UUID
    ) throws -> KeywordListBackupRestoreResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID)
        }

        let data = try io.readData(sourceURL)
        guard !Task.isCancelled else {
            return .cancelledAfterRead(
                requestID: requestID,
                sourceURL: sourceURL,
                byteCount: data.count
            )
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw KeywordListBackupPreviewError.invalidUTF8(sourceURL)
        }

        try io.writeData(data, destinationURL)
        return .restored(KeywordListBackupRestoreCommit(
            requestID: requestID,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            byteCount: data.count,
            cancellationObservedAfterCommit: Task.isCancelled
        ))
    }

    private func textFiles(in directoryURL: URL) -> [KeywordListBackupFileSnapshot] {
        let urls = (try? io.contentsOfDirectory(directoryURL)) ?? []
        return urls
            .filter { $0.pathExtension == "txt" }
            .map(io.inspectTextFile)
            .sorted { $0.date > $1.date }
    }

    private func prune(
        directoryURL: URL,
        retentionCutoff: Date,
        minimumVersionCount: Int
    ) {
        let versions = textFiles(in: directoryURL)
        guard versions.count > minimumVersionCount else { return }
        for (index, version) in versions.enumerated() where index >= minimumVersionCount {
            guard !Task.isCancelled else { return }
            if version.date < retentionCutoff {
                try? io.removeItem(version.url)
            }
        }
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
    struct Version: Identifiable, Equatable {
        let key: KeywordListKey
        let url: URL
        let date: Date
        /// Keyword count (structured) or entry count (flat lists).
        let entryCount: Int
        let byteCount: Int
        var id: URL { url }
    }

    struct VersionGroup: Equatable {
        let key: KeywordListKey
        let versions: [Version]
    }

    enum VersionInventoryResult: Equatable {
        case loaded(requestID: UUID, groups: [VersionGroup])
        case cancelled(
            requestID: UUID,
            completedDirectoryCount: Int,
            discoveredVersionCount: Int
        )
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
    private var recoverableRequestID: UUID?
    private let filesystem: KeywordListBackupFileService

    /// Every list the store manages. Same enumeration the archive uses.
    private static let allKeys: [KeywordListKey] = {
        var keys: [KeywordListKey] = []
        keys.append(contentsOf: QuickListType.allCases.map { KeywordListKey.quick($0) })
        keys.append(contentsOf: ApprovedListField.allCases.map { KeywordListKey.approved($0) })
        keys.append(.structured)
        keys.append(.structuredPersonShown)
        return keys
    }()

    init(filesystem: KeywordListBackupFileService = .shared) {
        self.filesystem = filesystem
    }

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
                await self.snapshot(key)
                await self.refreshRecoverable()
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.snapshotAll()
            await self.pruneAll()

            // Give iCloud a grace window to materialize files before deciding a list
            // is "missing". The change observer also refreshes recoverable state as
            // soon as a remote file lands, so this just covers the quiet case.
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self.refreshRecoverable()
        }
    }

    // MARK: - Snapshotting

    private func snapshotAll() async {
        for key in Self.allKeys {
            guard !Task.isCancelled else { return }
            await snapshot(key)
        }
    }

    /// Captures the current content of `key` if it's non-empty and differs from
    /// the most recent snapshot. Returns true if a new snapshot was written.
    @discardableResult
    private func snapshot(_ key: KeywordListKey) async -> Bool {
        let store = KeywordListsStore.shared
        guard let text = store.readText(key),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let dir = directory(for: key)
        let now = Date()
        do {
            return try await filesystem.snapshot(
                text: text,
                directoryURL: dir,
                destinationURL: dir.appendingPathComponent(Self.snapshotFileName(for: now)),
                retentionCutoff: now.addingTimeInterval(-Double(retentionDays) * 86_400),
                minimumVersionCount: minVersionsPerKey
            )
        } catch {
            logger.error("Failed to snapshot \(key.relativePath, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private)")
            return false
        }
    }

    // MARK: - Reading versions

    /// All keys that currently have at least one stored snapshot, paired with
    /// their version history. Used by the restore UI.
    func allVersionsByKey(requestID: UUID) async -> VersionInventoryResult {
        let result = await filesystem.inventory(
            directories: Self.allKeys.map { key in
                KeywordListBackupDirectoryRequest(
                    identifier: key.relativePath,
                    directoryURL: directory(for: key)
                )
            },
            requestID: requestID
        )

        switch result {
        case .loaded(let snapshot):
            let keyByIdentifier = Dictionary(
                uniqueKeysWithValues: Self.allKeys.map { ($0.relativePath, $0) }
            )
            let groups = snapshot.directories.compactMap { directory -> VersionGroup? in
                guard let key = keyByIdentifier[directory.identifier] else { return nil }
                let versions = directory.versions.map { file in
                    Version(
                        key: key,
                        url: file.url,
                        date: file.date,
                        entryCount: Self.entryCount(for: key, text: file.text),
                        byteCount: file.byteCount
                    )
                }
                return versions.isEmpty ? nil : VersionGroup(key: key, versions: versions)
            }
            return .loaded(requestID: snapshot.requestID, groups: groups)
        case .cancelled(let id, let completedDirectoryCount, let discoveredVersionCount):
            return .cancelled(
                requestID: id,
                completedDirectoryCount: completedDirectoryCount,
                discoveredVersionCount: discoveredVersionCount
            )
        }
    }

    // MARK: - Restore

    /// Restores `version` by writing it back through the store, which propagates
    /// to iCloud and notifies observers. The store write re-snapshots the
    /// restored content, so the action itself is captured in history.
    @discardableResult
    func restore(
        _ version: Version,
        requestID: UUID
    ) async throws -> KeywordListBackupRestoreResult {
        let store = KeywordListsStore.shared
        let result = try await filesystem.restore(
            from: version.url,
            to: store.url(for: version.key),
            requestID: requestID
        )
        if case .restored = result {
            store.recordExternalWrite(to: version.key)
            await refreshRecoverable()
        }
        return result
    }

    // MARK: - Recovery detection

    /// Recomputes which lists look empty while a backup exists.
    func refreshRecoverable() async {
        let store = KeywordListsStore.shared
        let emptyKeys = Set(Self.allKeys.filter { key in
            let text = store.readText(key)
            return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        })
        let requestID = UUID()
        recoverableRequestID = requestID
        guard case .loaded(_, let groups) = await allVersionsByKey(requestID: requestID),
              recoverableRequestID == requestID,
              !Task.isCancelled else { return }
        recoverableRequestID = nil
        let backedUpKeys = Set(groups.map(\.key))
        recoverableKeys = Self.allKeys.filter {
            emptyKeys.contains($0) && backedUpKeys.contains($0)
        }
    }

    // MARK: - Pruning

    private func pruneAll() async {
        await filesystem.prune(
            directories: Self.allKeys.map(directory(for:)),
            retentionCutoff: Date().addingTimeInterval(-Double(retentionDays) * 86_400),
            minimumVersionCount: minVersionsPerKey
        )
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
