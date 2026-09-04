import Foundation

/// Owns long-lived access for user-selected browser roots. Resolving a bookmark is not enough:
/// the security scope must remain active while thumbnails, metadata, exports, and folder monitors
/// use descendants asynchronously. Keeping one balanced access claim per normalized root avoids
/// both repeated permission prompts and unbounded `startAccessing...` calls during folder reloads.
nonisolated final class BrowserFolderSecurityScopeStore: @unchecked Sendable {
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

nonisolated struct RecentFolderBookmarkSnapshot: Sendable {
    let requestID: UUID
    let folders: [RecentFolder]
    let inspectedCount: Int
}

nonisolated enum RecentFolderBookmarkLoadResult: Sendable {
    case loaded(RecentFolderBookmarkSnapshot)
    case cancelledBeforeAccess(requestID: UUID)
    case cancelledAfterPrefix(requestID: UUID, inspectedCount: Int)
}

nonisolated struct RecentFolderBookmarkCommit: Sendable {
    let requestID: UUID
    let bookmarkData: Data?
    let cancellationRequestedAfterAccess: Bool
}

nonisolated enum RecentFolderBookmarkCommitResult: Sendable {
    case completed(RecentFolderBookmarkCommit)
    case cancelledBeforeAccess(requestID: UUID)
}

/// Serializes security-scoped bookmark creation and resolution away from MainActor.
/// Bookmark APIs can synchronously contact file providers, so even the small Open Recent
/// cache must not invoke them while SwiftUI is evaluating commands or opening a folder.
actor RecentFolderBookmarkService {
    static let shared = RecentFolderBookmarkService()

    private let securityScopes: BrowserFolderSecurityScopeStore

    init(securityScopes: BrowserFolderSecurityScopeStore = .shared) {
        self.securityScopes = securityScopes
    }

    func resolve(
        _ folders: [RecentFolder],
        requestID: UUID
    ) -> RecentFolderBookmarkLoadResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeAccess(requestID: requestID)
        }

        var repaired: [RecentFolder] = []
        repaired.reserveCapacity(folders.count)
        for folder in folders {
            guard !Task.isCancelled else {
                return .cancelledAfterPrefix(
                    requestID: requestID,
                    inspectedCount: repaired.count
                )
            }
            var resolvedFolder = folder
            if let bookmark = folder.bookmarkData,
               let resolution = securityScopes.resolveAndRetainAccess(bookmark) {
                resolvedFolder = RecentFolder(
                    id: folder.id,
                    url: resolution.url,
                    bookmarkData: resolution.bookmarkData
                )
            }
            repaired.append(resolvedFolder)
        }

        guard !Task.isCancelled else {
            return .cancelledAfterPrefix(
                requestID: requestID,
                inspectedCount: repaired.count
            )
        }
        return .loaded(RecentFolderBookmarkSnapshot(
            requestID: requestID,
            folders: repaired,
            inspectedCount: repaired.count
        ))
    }

    func createBookmark(
        for url: URL,
        requestID: UUID
    ) -> RecentFolderBookmarkCommitResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeAccess(requestID: requestID)
        }
        let bookmarkData = securityScopes.bookmarkAndRetainAccess(for: url)
        return .completed(RecentFolderBookmarkCommit(
            requestID: requestID,
            bookmarkData: bookmarkData,
            cancellationRequestedAfterAccess: Task.isCancelled
        ))
    }
}

nonisolated struct FavoriteFolderBookmarkSnapshot: Sendable {
    let requestID: UUID
    let folders: [FavoriteFolder]
    let inspectedCount: Int
}

nonisolated enum FavoriteFolderBookmarkLoadResult: Sendable {
    case loaded(FavoriteFolderBookmarkSnapshot)
    case cancelledBeforeAccess(requestID: UUID)
    case cancelledAfterPrefix(requestID: UUID, inspectedCount: Int)
}

nonisolated struct FavoriteFolderBookmarkCommit: Sendable {
    let requestID: UUID
    let bookmarkData: Data?
    let cancellationRequestedAfterAccess: Bool
}

nonisolated enum FavoriteFolderBookmarkCommitResult: Sendable {
    case completed(FavoriteFolderBookmarkCommit)
    case cancelledBeforeAccess(requestID: UUID)
}

/// Serializes Favorite-folder bookmark resolution and creation away from MainActor.
/// File-provider bookmark APIs can block even when the favorite cache itself is small.
actor FavoriteFolderBookmarkService {
    static let shared = FavoriteFolderBookmarkService()

    private let securityScopes: BrowserFolderSecurityScopeStore
    private let cancellationRequested: @Sendable () -> Bool

    init(
        securityScopes: BrowserFolderSecurityScopeStore = .shared,
        cancellationRequested: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) {
        self.securityScopes = securityScopes
        self.cancellationRequested = cancellationRequested
    }

    func resolve(
        _ folders: [FavoriteFolder],
        requestID: UUID
    ) -> FavoriteFolderBookmarkLoadResult {
        guard !cancellationRequested() else {
            return .cancelledBeforeAccess(requestID: requestID)
        }

        var repaired: [FavoriteFolder] = []
        repaired.reserveCapacity(folders.count)
        for folder in folders {
            guard !cancellationRequested() else {
                return .cancelledAfterPrefix(
                    requestID: requestID,
                    inspectedCount: repaired.count
                )
            }
            var resolvedFolder = folder
            if let bookmark = folder.bookmarkData,
               let resolution = securityScopes.resolveAndRetainAccess(bookmark) {
                resolvedFolder = FavoriteFolder(
                    id: folder.id,
                    url: resolution.url,
                    bookmarkData: resolution.bookmarkData
                )
            }
            repaired.append(resolvedFolder)
        }

        guard !cancellationRequested() else {
            return .cancelledAfterPrefix(
                requestID: requestID,
                inspectedCount: repaired.count
            )
        }
        return .loaded(FavoriteFolderBookmarkSnapshot(
            requestID: requestID,
            folders: repaired,
            inspectedCount: repaired.count
        ))
    }

    func createBookmark(
        for url: URL,
        requestID: UUID
    ) -> FavoriteFolderBookmarkCommitResult {
        guard !cancellationRequested() else {
            return .cancelledBeforeAccess(requestID: requestID)
        }
        let bookmarkData = securityScopes.bookmarkAndRetainAccess(for: url)
        return .completed(FavoriteFolderBookmarkCommit(
            requestID: requestID,
            bookmarkData: bookmarkData,
            cancellationRequestedAfterAccess: cancellationRequested()
        ))
    }
}

/// Persistent list of recently opened folders, shared between the browser
/// (which records every folder open) and the File ▸ Open Recent menu
/// (which displays and clears it).
@MainActor
@Observable
final class RecentFoldersStore {
    static let shared = RecentFoldersStore(defaults: .standard)

    private(set) var folders: [RecentFolder] = []

    private static let maxCount = 10
    private let defaults: UserDefaults
    private let bookmarkService: RecentFolderBookmarkService
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var loadRequestID = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var cacheGeneration = UUID()

    init(
        defaults: UserDefaults,
        securityScopes: BrowserFolderSecurityScopeStore = .shared
    ) {
        self.defaults = defaults
        bookmarkService = RecentFolderBookmarkService(securityScopes: securityScopes)
        scheduleLoadIfNeeded()
    }

    func track(_ url: URL) async {
        await loadIfNeeded()
        guard !Task.isCancelled else { return }
        let normalizedURL = Self.normalizedFolderURL(url)
        let existingBookmark = folders.first {
            Self.normalizedFolderURL($0.url) == normalizedURL
        }?.bookmarkData
        let requestID = UUID()
        let generation = cacheGeneration
        let result = await bookmarkService.createBookmark(for: url, requestID: requestID)
        guard case .completed(let commit) = result,
              commit.requestID == requestID,
              cacheGeneration == generation else { return }
        let bookmark = commit.bookmarkData ?? existingBookmark
        folders.removeAll { Self.normalizedFolderURL($0.url) == normalizedURL }
        folders.insert(RecentFolder(url: normalizedURL, bookmarkData: bookmark), at: 0)
        if folders.count > Self.maxCount {
            folders = Array(folders.prefix(Self.maxCount))
        }
        save()
    }

    func clear() {
        loadTask?.cancel()
        loadTask = nil
        loadRequestID = UUID()
        cacheGeneration = UUID()
        didLoad = true
        folders = []
        save()
    }

    func loadIfNeeded() async {
        if didLoad { return }
        if let loadTask {
            await loadTask.value
            return
        }
        guard let data = defaults.data(forKey: UserDefaultsKeys.recentFolders),
              let decoded = try? JSONDecoder().decode([RecentFolder].self, from: data) else {
            didLoad = true
            return
        }

        let requestID = UUID()
        loadRequestID = requestID
        let service = bookmarkService
        let task = Task { @MainActor [weak self] in
            let result = await service.resolve(decoded, requestID: requestID)
            guard let self, self.loadRequestID == requestID else { return }
            self.loadTask = nil
            guard case .loaded(let snapshot) = result,
                  snapshot.requestID == requestID else { return }
            let repaired = self.sanitized(snapshot.folders)
            self.folders = repaired
            self.didLoad = true
            if repaired != decoded {
                self.save()
            }
        }
        loadTask = task
        await task.value
    }

    private func scheduleLoadIfNeeded() {
        guard !didLoad, loadTask == nil else { return }
        Task { @MainActor [weak self] in
            await self?.loadIfNeeded()
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
            let normalizedURL = Self.normalizedFolderURL(folder.url)
            guard seen.insert(normalizedURL).inserted else { continue }
            result.append(RecentFolder(
                id: folder.id,
                url: normalizedURL,
                bookmarkData: folder.bookmarkData
            ))
            if result.count == Self.maxCount { break }
        }
        return result
    }
}
