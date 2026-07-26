import Foundation

/// Owns long-lived access for user-selected browser roots. Resolving a bookmark is not enough:
/// the security scope must remain active while thumbnails, metadata, exports, and folder monitors
/// use descendants asynchronously. Keeping one balanced access claim per normalized root avoids
/// both repeated permission prompts and unbounded `startAccessing...` calls during folder reloads.
final class BrowserFolderSecurityScopeStore: @unchecked Sendable {
    static let shared = BrowserFolderSecurityScopeStore()

    struct Resolution {
        var url: URL
        var bookmarkData: Data
    }

    private let lock = NSLock()
    private var accessedURLs: Set<URL> = []

    private init() {}

    func bookmarkAndRetainAccess(for url: URL) -> Data? {
        retainAccess(to: url)
        return try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveAndRetainAccess(_ data: Data) -> Resolution? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }

        retainAccess(to: url)
        let refreshed = stale ? (bookmarkAndRetainAccess(for: url) ?? data) : data
        return Resolution(url: url, bookmarkData: refreshed)
    }

    private func retainAccess(to url: URL) {
        let normalized = URL(
            fileURLWithPath: url.standardizedFileURL.path,
            isDirectory: true
        )
        lock.lock()
        defer { lock.unlock() }
        guard !accessedURLs.contains(normalized) else { return }
        if url.startAccessingSecurityScopedResource() {
            accessedURLs.insert(normalized)
        }
    }
}

/// Persistent list of recently opened folders, shared between the browser
/// (which records every folder open) and the File ▸ Open Recent menu
/// (which displays and clears it).
@Observable
final class RecentFoldersStore {
    static let shared = RecentFoldersStore(defaults: .standard)

    private(set) var folders: [RecentFolder] = []

    private static let maxCount = 10
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        load()
    }

    func track(_ url: URL) {
        let normalizedURL = Self.normalizedFolderURL(url)
        let existingBookmark = folders.first {
            Self.normalizedFolderURL($0.url) == normalizedURL
        }?.bookmarkData
        let bookmark = BrowserFolderSecurityScopeStore.shared
            .bookmarkAndRetainAccess(for: url) ?? existingBookmark
        folders.removeAll { Self.normalizedFolderURL($0.url) == normalizedURL }
        folders.insert(RecentFolder(url: normalizedURL, bookmarkData: bookmark), at: 0)
        if folders.count > Self.maxCount {
            folders = Array(folders.prefix(Self.maxCount))
        }
        save()
    }

    func clear() {
        folders = []
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: UserDefaultsKeys.recentFolders),
              let decoded = try? JSONDecoder().decode([RecentFolder].self, from: data) else {
            return
        }
        folders = Self.sanitized(decoded)
        if folders != decoded {
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: UserDefaultsKeys.recentFolders)
        }
    }

    /// Folder pickers can represent the same directory with or without a trailing
    /// slash, and callers can supply lexical `.`/`..` path components. Persist one
    /// stable directory URL so those spellings share a single Open Recent entry.
    private static func normalizedFolderURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        return URL(fileURLWithPath: standardized.path, isDirectory: true)
    }

    /// Older or externally edited defaults may contain duplicates, stale display
    /// names, or more entries than the current menu supports. Repair that data once
    /// at load while preserving the first (most recent) entry and its identity.
    private static func sanitized(_ decoded: [RecentFolder]) -> [RecentFolder] {
        var seen: Set<URL> = []
        var result: [RecentFolder] = []
        result.reserveCapacity(min(decoded.count, maxCount))

        for folder in decoded {
            var repaired = folder
            if let bookmark = folder.bookmarkData,
               let resolution = BrowserFolderSecurityScopeStore.shared
                .resolveAndRetainAccess(bookmark) {
                repaired.url = resolution.url
                repaired.bookmarkData = resolution.bookmarkData
            }
            let normalizedURL = normalizedFolderURL(repaired.url)
            guard seen.insert(normalizedURL).inserted else { continue }
            result.append(RecentFolder(
                id: repaired.id,
                url: normalizedURL,
                bookmarkData: repaired.bookmarkData
            ))
            if result.count == maxCount { break }
        }
        return result
    }
}
