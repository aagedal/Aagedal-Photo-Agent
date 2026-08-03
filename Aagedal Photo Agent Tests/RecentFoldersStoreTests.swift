import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@MainActor
@Suite("RecentFoldersStore")
struct RecentFoldersStoreTests {
    @Test("Security scope store retains one claim per normalized root")
    func securityScopeClaimsAreIdempotent() {
        var accessRequests: [URL] = []
        var bookmarkRequests: [URL] = []
        let scopes = BrowserFolderSecurityScopeStore(
            accessStarter: {
                accessRequests.append($0)
                return true
            },
            bookmarkCreator: {
                bookmarkRequests.append($0)
                return Data([0x01])
            },
            bookmarkResolver: { _ in nil }
        )
        let folder = URL(fileURLWithPath: "/tmp/photo-agent-scope/session", isDirectory: true)
        let equivalent = URL(
            fileURLWithPath: "/tmp/photo-agent-scope/other/../session",
            isDirectory: false
        )
        let descendant = folder.appendingPathComponent("shoot/day-1", isDirectory: true)

        _ = scopes.bookmarkAndRetainAccess(for: folder)
        _ = scopes.bookmarkAndRetainAccess(for: equivalent)
        _ = scopes.bookmarkAndRetainAccess(for: descendant)

        #expect(accessRequests == [folder])
        #expect(bookmarkRequests == [folder, equivalent, descendant])
    }

    @Test("A failed access claim can be retried")
    func failedSecurityScopeClaimRetries() {
        var accessCount = 0
        let scopes = BrowserFolderSecurityScopeStore(
            accessStarter: { _ in
                accessCount += 1
                return accessCount == 2
            },
            bookmarkCreator: { _ in nil },
            bookmarkResolver: { _ in nil }
        )
        let folder = URL(fileURLWithPath: "/tmp/photo-agent-scope/retry", isDirectory: true)

        _ = scopes.bookmarkAndRetainAccess(for: folder)
        _ = scopes.bookmarkAndRetainAccess(for: folder)
        _ = scopes.bookmarkAndRetainAccess(for: folder)

        #expect(accessCount == 2)
    }

    @Test("Launch resolves, retains, and refreshes a stale recent-folder bookmark")
    func staleBookmarkRefreshesOnLoad() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let original = URL(
            fileURLWithPath: "/tmp/photo-agent-recents/original",
            isDirectory: true
        )
        let moved = URL(
            fileURLWithPath: "/tmp/photo-agent-recents/moved",
            isDirectory: true
        )
        let staleData = Data([0x01])
        let refreshedData = Data([0x02])
        let persisted = [RecentFolder(url: original, bookmarkData: staleData)]
        defaults.set(
            try JSONEncoder().encode(persisted),
            forKey: UserDefaultsKeys.recentFolders
        )
        var accessedURLs: [URL] = []
        let scopes = BrowserFolderSecurityScopeStore(
            accessStarter: {
                accessedURLs.append($0)
                return true
            },
            bookmarkCreator: { url in
                #expect(url == moved)
                return refreshedData
            },
            bookmarkResolver: { data in
                #expect(data == staleData)
                return .init(url: moved, isStale: true)
            }
        )

        let store = RecentFoldersStore(defaults: defaults, securityScopes: scopes)

        #expect(accessedURLs == [moved])
        #expect(store.folders.first?.url == moved)
        #expect(store.folders.first?.bookmarkData == refreshedData)
        let savedData = try #require(
            defaults.data(forKey: UserDefaultsKeys.recentFolders)
        )
        let saved = try JSONDecoder().decode([RecentFolder].self, from: savedData)
        #expect(saved == store.folders)
    }

    @Test("Equivalent folder URL spellings share one recent entry")
    func equivalentURLsAreDeduplicated() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentFoldersStore(defaults: defaults)

        let folder = URL(
            fileURLWithPath: "/tmp/photo-agent-recents/session",
            isDirectory: true
        )
        let equivalent = URL(
            fileURLWithPath: "/tmp/photo-agent-recents/other/../session",
            isDirectory: false
        )

        store.track(folder)
        store.track(equivalent)

        #expect(store.folders.count == 1)
        #expect(store.folders.first?.url == folder)
        #expect(store.folders.first?.name == "session")

        let reloaded = RecentFoldersStore(defaults: defaults)
        #expect(reloaded.folders == store.folders)
    }

    @Test("Loading repairs duplicate, stale, and oversized persisted data")
    func loadSanitizesPersistedEntries() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let canonical = URL(
            fileURLWithPath: "/tmp/photo-agent-recents/session",
            isDirectory: true
        )
        var mostRecent = RecentFolder(url: canonical)
        mostRecent.name = "Stale display name"
        mostRecent.bookmarkData = Data([0xCA, 0xFE])
        let duplicate = RecentFolder(url: URL(
            fileURLWithPath: "/tmp/photo-agent-recents/other/../session",
            isDirectory: false
        ))
        let older = (0..<11).map {
            RecentFolder(url: URL(
                fileURLWithPath: "/tmp/photo-agent-recents/older-\($0)",
                isDirectory: true
            ))
        }
        let persisted = [mostRecent, duplicate] + older
        defaults.set(
            try JSONEncoder().encode(persisted),
            forKey: UserDefaultsKeys.recentFolders
        )

        let store = RecentFoldersStore(defaults: defaults)

        #expect(store.folders.count == 10)
        #expect(store.folders.first?.id == mostRecent.id)
        #expect(store.folders.first?.url == canonical)
        #expect(store.folders.first?.name == "session")
        #expect(store.folders.first?.bookmarkData == Data([0xCA, 0xFE]))
        #expect(Set(store.folders.map(\.url)).count == store.folders.count)
        #expect(store.folders.last?.name == "older-8")

        let savedData = try #require(
            defaults.data(forKey: UserDefaultsKeys.recentFolders)
        )
        let repaired = try JSONDecoder().decode([RecentFolder].self, from: savedData)
        #expect(repaired == store.folders)
    }

    @Test("Legacy recent and favorite folders decode without bookmark data")
    func legacyFolderModelsDecode() throws {
        let id = UUID()
        let legacyRecent = """
        {"id":"\(id.uuidString)","url":"file:///tmp/legacy-recent/","name":"legacy-recent"}
        """
        let legacyFavorite = """
        {"id":"\(id.uuidString)","url":"file:///tmp/legacy-favorite/","name":"legacy-favorite"}
        """

        let recent = try JSONDecoder().decode(RecentFolder.self, from: Data(legacyRecent.utf8))
        let favorite = try JSONDecoder().decode(FavoriteFolder.self, from: Data(legacyFavorite.utf8))
        #expect(recent.bookmarkData == nil)
        #expect(favorite.bookmarkData == nil)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "RecentFoldersStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
