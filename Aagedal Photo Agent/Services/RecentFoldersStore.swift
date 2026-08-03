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

    struct BookmarkResolution {
        var url: URL
        var isStale: Bool
    }

    private let lock = NSLock()
    private var accessedURLs: Set<URL> = []
    private let accessStarter: (URL) -> Bool
    private let bookmarkCreator: (URL) -> Data?
    private let bookmarkResolver: (Data) -> BookmarkResolution?

    private convenience init() {
        self.init(
            accessStarter: { $0.startAccessingSecurityScopedResource() },
            bookmarkCreator: {
                try? $0.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            },
            bookmarkResolver: { data in
                var stale = false
                guard let url = try? URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) else { return nil }
                return BookmarkResolution(url: url, isStale: stale)
            }
        )
    }

    /// Injection point for deterministic lifecycle tests. Production uses `shared`.
    init(
        accessStarter: @escaping (URL) -> Bool,
        bookmarkCreator: @escaping (URL) -> Data?,
        bookmarkResolver: @escaping (Data) -> BookmarkResolution?
    ) {
        self.accessStarter = accessStarter
        self.bookmarkCreator = bookmarkCreator
        self.bookmarkResolver = bookmarkResolver
    }

    func bookmarkAndRetainAccess(for url: URL) -> Data? {
        retainAccess(to: url)
        return bookmarkCreator(url)
    }

    func resolveAndRetainAccess(_ data: Data) -> Resolution? {
        guard let bookmark = bookmarkResolver(data) else { return nil }

        retainAccess(to: bookmark.url)
        let refreshed = bookmark.isStale
            ? (bookmarkCreator(bookmark.url) ?? data)
            : data
        return Resolution(url: bookmark.url, bookmarkData: refreshed)
    }

    private func retainAccess(to url: URL) {
        let normalized = URL(
            fileURLWithPath: url.standardizedFileURL.path,
            isDirectory: true
        )
        lock.lock()
        defer { lock.unlock() }
        guard !accessedURLs.contains(where: {
            Self.isSameOrDescendant(normalized, of: $0)
        }) else { return }
        if accessStarter(url) {
            accessedURLs.insert(normalized)
        }
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.standardizedFileURL.pathComponents.starts(
            with: root.standardizedFileURL.pathComponents
        )
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
    private let securityScopes: BrowserFolderSecurityScopeStore

    init(
        defaults: UserDefaults,
        securityScopes: BrowserFolderSecurityScopeStore = .shared
    ) {
        self.defaults = defaults
        self.securityScopes = securityScopes
        load()
    }

    func track(_ url: URL) {
        let normalizedURL = Self.normalizedFolderURL(url)
        let existingBookmark = folders.first {
            Self.normalizedFolderURL($0.url) == normalizedURL
        }?.bookmarkData
        let bookmark = securityScopes
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
        folders = sanitized(decoded)
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
    private func sanitized(_ decoded: [RecentFolder]) -> [RecentFolder] {
        var seen: Set<URL> = []
        var result: [RecentFolder] = []
        result.reserveCapacity(min(decoded.count, Self.maxCount))

        for folder in decoded {
            var repaired = folder
            if let bookmark = folder.bookmarkData,
               let resolution = securityScopes
                .resolveAndRetainAccess(bookmark) {
                repaired.url = resolution.url
                repaired.bookmarkData = resolution.bookmarkData
            }
            let normalizedURL = Self.normalizedFolderURL(repaired.url)
            guard seen.insert(normalizedURL).inserted else { continue }
            result.append(RecentFolder(
                id: repaired.id,
                url: normalizedURL,
                bookmarkData: repaired.bookmarkData
            ))
            if result.count == Self.maxCount { break }
        }
        return result
    }
}
