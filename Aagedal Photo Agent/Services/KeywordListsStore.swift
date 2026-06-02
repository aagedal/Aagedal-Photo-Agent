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
        }
    }

    /// Folder under root that holds the file. Stored so callers can ensure the
    /// directory exists before writing.
    var directoryComponent: String {
        switch self {
        case .quick: return "quick"
        case .approved: return "approved"
        case .structured: return "structured"
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
        }
    }
}

extension Notification.Name {
    /// Posted by `KeywordListsStore` after a write, delete, or remote refresh.
    /// `userInfo[KeywordListsStore.changedKeyUserInfo]` is the `KeywordListKey`.
    static let keywordListChanged = Notification.Name("KeywordListsStore.changed")
}

/// Canonical disk-backed store for every keyword list the app manages.
///
/// All read/write goes through here so we have a single place to choose between
/// local (`~/Library/Application Support/.../Lists`) and iCloud (ubiquity
/// container) storage and to emit change notifications.
@Observable
final class KeywordListsStore: @unchecked Sendable {
    static let shared = KeywordListsStore()
    static let changedKeyUserInfo = "key"

    /// iCloud container identifier. Must match the entry in the entitlements file.
    static let iCloudContainerID = "iCloud.aagedal.Aagedal-Photo-Agent"

    /// Bumped whenever the backing root changes (e.g. iCloud toggled) so SwiftUI
    /// views observing the store re-evaluate `url(for:)` derived values.
    private(set) var version: Int = 0

    /// Set to a non-nil string when `setICloudEnabled` fails so Settings can
    /// surface the reason. Cleared on the next successful toggle attempt.
    private(set) var lastSyncError: String?

    @ObservationIgnored private let queue = DispatchQueue(label: "com.aagedal.keyword-lists-store", qos: .userInitiated)
    @ObservationIgnored private var cachedRoot: URL?

    init() {
        ensureDirectories(at: rootURL)
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
    var rootURL: URL {
        if let cached = cachedRoot { return cached }
        let resolved: URL
        if iCloudEnabled, let cloud = iCloudContainerListsURL {
            resolved = cloud
        } else {
            resolved = localRootURL
        }
        cachedRoot = resolved
        return resolved
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
            logger.error("Failed to read \(key.relativePath, privacy: .public): \(String(describing: error))")
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
                try copyTree(from: localRootURL, to: cloud)
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
            // Best-effort copy back so the user still has access locally after toggle off.
            try? copyTree(from: current, to: local)
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
    /// Idempotent: stamps `keywordListsMigratedVersion` once done so subsequent
    /// launches skip the work.
    func migrateLegacyBookmarksIfNeeded() {
        let stamp = UserDefaults.standard.integer(forKey: UserDefaultsKeys.keywordListsMigratedVersion)
        if stamp >= 1 { return }

        // Approved list (single field today: .keywords)
        for field in ApprovedListField.allCases {
            if let url = resolveBookmarkData(forKey: field.bookmarkKey) {
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                if let entries = try? ApprovedListParser.parse(url) {
                    try? writeEntries(entries, to: .approved(field))
                }
            }
        }

        // Structured keywords
        if let url = resolveBookmarkData(forKey: UserDefaultsKeys.structuredKeywordsBookmark) {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                try? writeText(text, to: .structured)
            }
        }

        // Quick lists (8)
        for type in QuickListType.allCases {
            if let url = resolveBookmarkData(forKey: type.bookmarkKey) {
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    let lines = text
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    try? writeEntries(lines, to: .quick(type))
                }
            }
        }

        UserDefaults.standard.set(1, forKey: UserDefaultsKeys.keywordListsMigratedVersion)
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
        return keys
    }

    private func resolveBookmarkData(forKey key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// Mirrors `source/*` into `destination/*` for our known subfolders. Files
    /// at the destination get overwritten; files missing from the source are
    /// left in place (so iCloud → local toggle preserves a deletion done on
    /// another device).
    private func copyTree(from source: URL, to destination: URL) throws {
        try CloudCoordinatedIO.ensureDirectory(destination)
        for sub in ["quick", "approved", "structured"] {
            let sourceDir = source.appendingPathComponent(sub, isDirectory: true)
            let destinationDir = destination.appendingPathComponent(sub, isDirectory: true)
            try CloudCoordinatedIO.ensureDirectory(destinationDir)
            guard FileManager.default.fileExists(atPath: sourceDir.path) else { continue }
            let children = (try? CloudCoordinatedIO.contentsOfDirectory(at: sourceDir)) ?? []
            for child in children where child.pathExtension.lowercased() == "txt" {
                let dest = destinationDir.appendingPathComponent(child.lastPathComponent)
                let data = try CloudCoordinatedIO.readData(at: child)
                try CloudCoordinatedIO.writeData(data, to: dest)
            }
        }
    }
}
