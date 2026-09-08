import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@MainActor
@Suite("RecentFoldersStore", .serialized)
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
    func staleBookmarkRefreshesOnLoad() async throws {
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
        await store.loadIfNeeded()

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
    func equivalentURLsAreDeduplicated() async throws {
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

        await store.track(folder)
        await store.track(equivalent)

        #expect(store.folders.count == 1)
        #expect(store.folders.first?.url == folder)
        #expect(store.folders.first?.name == "session")

        let reloaded = RecentFoldersStore(defaults: defaults)
        await reloaded.loadIfNeeded()
        #expect(reloaded.folders == store.folders)
    }

    @Test("Loading repairs duplicate, stale, and oversized persisted data")
    func loadSanitizesPersistedEntries() async throws {
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
        await store.loadIfNeeded()

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

    @Test("Recent-folder bookmark work is serialized away from MainActor")
    func recentFolderBookmarkWorkRunsOffMainActor() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = RecentFolderThreadRecorder()
        let scopes = BrowserFolderSecurityScopeStore(
            accessStarter: { _ in
                recorder.recordCurrentThread()
                return true
            },
            bookmarkCreator: { url in
                recorder.recordCurrentThread()
                return Data(url.path.utf8)
            },
            bookmarkResolver: { data in
                recorder.recordCurrentThread()
                guard let path = String(data: data, encoding: .utf8) else { return nil }
                return .init(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    isStale: false
                )
            }
        )
        let persistedURL = URL(
            fileURLWithPath: "/tmp/photo-agent-recents/persisted",
            isDirectory: true
        )
        defaults.set(
            try JSONEncoder().encode([
                RecentFolder(url: persistedURL, bookmarkData: Data(persistedURL.path.utf8))
            ]),
            forKey: UserDefaultsKeys.recentFolders
        )
        let store = RecentFoldersStore(defaults: defaults, securityScopes: scopes)

        await store.loadIfNeeded()
        await store.track(URL(
            fileURLWithPath: "/tmp/photo-agent-recents/new",
            isDirectory: true
        ))

        #expect(recorder.observedMainThread == [false, false, false, false])
    }

    @Test("Pre-cancelled recent-folder resolution returns no partial cache")
    func preCancelledResolutionIsExplicit() async {
        let scopes = BrowserFolderSecurityScopeStore(
            accessStarter: { _ in true },
            bookmarkCreator: { _ in Data([0x01]) },
            bookmarkResolver: { _ in
                Issue.record("A pre-cancelled load must not resolve a bookmark")
                return nil
            }
        )
        let service = RecentFolderBookmarkService(securityScopes: scopes)
        let requestID = UUID()
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.resolve(
                [RecentFolder(
                    url: URL(fileURLWithPath: "/tmp/cancelled", isDirectory: true),
                    bookmarkData: Data([0x01])
                )],
                requestID: requestID
            )
        }.value

        guard case .cancelledBeforeAccess(let resultID) = result else {
            Issue.record("Expected cancellation before bookmark resolution")
            return
        }
        #expect(resultID == requestID)
    }

    @Test("Favorite bookmarks resolve and refresh off MainActor before publication")
    func favoriteBookmarkWorkRunsOffMainActor() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = RecentFolderThreadRecorder()
        let original = URL(
            fileURLWithPath: "/tmp/photo-agent-favorites/original",
            isDirectory: true
        )
        let moved = URL(
            fileURLWithPath: "/tmp/photo-agent-favorites/moved",
            isDirectory: true
        )
        let added = URL(
            fileURLWithPath: "/tmp/photo-agent-favorites-added/session",
            isDirectory: true
        )
        let staleData = Data([0x11])
        let refreshedData = Data([0x12])
        let addedData = Data([0x13])
        let persisted = [FavoriteFolder(url: original, bookmarkData: staleData)]
        defaults.set(
            try JSONEncoder().encode(persisted),
            forKey: UserDefaultsKeys.favoriteFolders
        )
        let scopes = BrowserFolderSecurityScopeStore(
            accessStarter: { _ in
                recorder.recordCurrentThread()
                return true
            },
            bookmarkCreator: { url in
                recorder.recordCurrentThread()
                return url == moved ? refreshedData : addedData
            },
            bookmarkResolver: { data in
                recorder.recordCurrentThread()
                #expect(data == staleData)
                return .init(url: moved, isStale: true)
            }
        )
        let service = FavoriteFolderBookmarkService(securityScopes: scopes)
        let viewModel = BrowserViewModel(
            favoritesDefaults: defaults,
            favoriteBookmarkService: service
        )

        await viewModel.loadFavorites()
        await viewModel.addFolderToFavorites(added)

        #expect(viewModel.favoriteFolders.count == 2)
        #expect(viewModel.favoriteFolders[0].id == persisted[0].id)
        #expect(viewModel.favoriteFolders[0].url == moved)
        #expect(viewModel.favoriteFolders[0].bookmarkData == refreshedData)
        #expect(viewModel.favoriteFolders[1].url == added)
        #expect(viewModel.favoriteFolders[1].bookmarkData == addedData)
        #expect(recorder.observedMainThread == [false, false, false, false, false])
        let savedData = try #require(
            defaults.data(forKey: UserDefaultsKeys.favoriteFolders)
        )
        let saved = try JSONDecoder().decode([FavoriteFolder].self, from: savedData)
        #expect(saved == viewModel.favoriteFolders)
    }

    @Test("Pre-cancelled favorite resolution performs no bookmark access")
    func preCancelledFavoriteResolutionIsExplicit() async {
        let scopes = BrowserFolderSecurityScopeStore(
            accessStarter: { _ in true },
            bookmarkCreator: { _ in Data([0x01]) },
            bookmarkResolver: { _ in
                Issue.record("A pre-cancelled load must not resolve a favorite bookmark")
                return nil
            }
        )
        let service = FavoriteFolderBookmarkService(securityScopes: scopes)
        let requestID = UUID()
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.resolve(
                [FavoriteFolder(
                    url: URL(fileURLWithPath: "/tmp/cancelled-favorite", isDirectory: true),
                    bookmarkData: Data([0x01])
                )],
                requestID: requestID
            )
        }.value

        guard case .cancelledBeforeAccess(let resultID) = result else {
            Issue.record("Expected cancellation before favorite bookmark resolution")
            return
        }
        #expect(resultID == requestID)
    }

    @Test("Favorite creation reports cancellation after bookmark access")
    func favoriteCreationReportsPostAccessCancellation() async {
        let cancellation = FavoriteCancellationSequence([false, true])
        let scopes = BrowserFolderSecurityScopeStore(
            accessStarter: { _ in true },
            bookmarkCreator: { _ in Data([0x21]) },
            bookmarkResolver: { _ in nil }
        )
        let service = FavoriteFolderBookmarkService(
            securityScopes: scopes,
            cancellationRequested: cancellation.next
        )
        let requestID = UUID()
        let result = await Task {
            await service.createBookmark(
                for: URL(fileURLWithPath: "/tmp/favorite-commit", isDirectory: true),
                requestID: requestID
            )
        }.value

        guard case .completed(let commit) = result else {
            Issue.record("Expected completed favorite bookmark access")
            return
        }
        #expect(commit.requestID == requestID)
        #expect(commit.bookmarkData == Data([0x21]))
        #expect(commit.cancellationRequestedAfterAccess)
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

nonisolated private final class RecentFolderThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var observedMainThread: [Bool] {
        lock.withLock { storage }
    }

    func recordCurrentThread() {
        lock.withLock { storage.append(Thread.isMainThread) }
    }
}

nonisolated private final class FavoriteCancellationSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]

    init(_ values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        lock.withLock {
            values.isEmpty ? false : values.removeFirst()
        }
    }
}

@Suite("Companion filesystem Dispatch executors")
@MainActor
struct CompanionFilesystemExecutorTests {
    @Test("Bookmark resolution retains task context and exact cancellation evidence",
          arguments: [false, true], [false, true])
    func bookmarkResolution(favorite: Bool, cancel: Bool) async {
        let root = URL(fileURLWithPath: "/virtual/bookmarks")
        let requestID = UUID()
        let queue = DispatchSerialQueue(label: "test.bookmarks.resolve")
        let check = contextCheck(queue, root: root)
        let scopes = BrowserFolderSecurityScopeStore(accessStarter: { _ in
            check()
            return true
        }, bookmarkCreator: { _ in
            check()
            return Data([2])
        }, bookmarkResolver: { _ in
            check()
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return .init(url: root, isStale: true)
        })
        await Task {
            await CompanionFilesystemContext.$marker.withValue(root) {
                if favorite {
                    let service = FavoriteFolderBookmarkService(filesystemQueue: queue, securityScopes: scopes)
                    let result = await service.resolve([
                        FavoriteFolder(url: root, bookmarkData: Data([1])),
                        FavoriteFolder(url: root, bookmarkData: Data([1]))
                    ], requestID: requestID)
                    switch result {
                    case .loaded(let snapshot):
                        #expect(!cancel)
                        #expect(snapshot.requestID == requestID)
                        #expect(snapshot.inspectedCount == 2)
                        #expect(snapshot.folders.allSatisfy { $0.bookmarkData == Data([2]) })
                    case .cancelledAfterPrefix(let id, let count):
                        #expect(cancel)
                        #expect(id == requestID)
                        #expect(count == 1)
                    default: Issue.record("Bookmark resolution never entered the worker")
                    }
                } else {
                    let service = RecentFolderBookmarkService(filesystemQueue: queue, securityScopes: scopes)
                    let result = await service.resolve([
                        RecentFolder(url: root, bookmarkData: Data([1])),
                        RecentFolder(url: root, bookmarkData: Data([1]))
                    ], requestID: requestID)
                    switch result {
                    case .loaded(let snapshot):
                        #expect(!cancel)
                        #expect(snapshot.requestID == requestID)
                        #expect(snapshot.inspectedCount == 2)
                        #expect(snapshot.folders.allSatisfy { $0.bookmarkData == Data([2]) })
                    case .cancelledAfterPrefix(let id, let count):
                        #expect(cancel)
                        #expect(id == requestID)
                        #expect(count == 1)
                    default: Issue.record("Bookmark resolution never entered the worker")
                    }
                }
            }
        }.value
    }

    @Test("Bookmark creation keeps completed access evidence when cancelled", arguments: [false, true])
    func bookmarkCreation(favorite: Bool) async {
        let root = URL(fileURLWithPath: "/virtual/bookmark-create")
        let queue = DispatchSerialQueue(label: "test.bookmarks.create")
        let check = contextCheck(queue, root: root)
        let scopes = BrowserFolderSecurityScopeStore(accessStarter: { _ in
            check()
            return true
        }, bookmarkCreator: { _ in
            check()
            withUnsafeCurrentTask { $0?.cancel() }
            return Data([3])
        }, bookmarkResolver: { _ in nil })
        await Task {
            await CompanionFilesystemContext.$marker.withValue(root) {
                let id = UUID()
                if favorite {
                    let service = FavoriteFolderBookmarkService(filesystemQueue: queue, securityScopes: scopes)
                    guard case .completed(let result) = await service.createBookmark(for: root, requestID: id) else {
                        Issue.record("Completed bookmark access was discarded")
                        return
                    }
                    #expect(result.requestID == id)
                    #expect(result.bookmarkData == Data([3]))
                    #expect(result.cancellationRequestedAfterAccess)
                } else {
                    let service = RecentFolderBookmarkService(filesystemQueue: queue, securityScopes: scopes)
                    guard case .completed(let result) = await service.createBookmark(for: root, requestID: id) else {
                        Issue.record("Completed bookmark access was discarded")
                        return
                    }
                    #expect(result.requestID == id)
                    #expect(result.bookmarkData == Data([3]))
                    #expect(result.cancellationRequestedAfterAccess)
                }
            }
        }.value
    }

    @Test("Signature reads preserve task context and reject a cancelled classification", arguments: [false, true])
    func faceSignatures(classify: Bool) async {
        let root = URL(fileURLWithPath: "/virtual/face-signature")
        let queue = DispatchSerialQueue(label: "test.face-signatures")
        let check = contextCheck(queue, root: root)
        let service = FaceScanFileSignatureService(filesystemQueue: queue) { url in
            check()
            #expect(url == root)
            withUnsafeCurrentTask { $0?.cancel() }
            return FileSignature(modificationDate: .distantPast, fileSize: 12)
        }
        await Task {
            await CompanionFilesystemContext.$marker.withValue(root) {
                if classify {
                    let result = await service.classify(imageURLs: [root, root], existingSignatures: [:])
                    #expect(result == .cancelled(processedFileCount: 1, requestedFileCount: 2))
                } else {
                    #expect(await service.signature(for: root) == .cancelled(imageURL: root, readCompleted: true))
                }
            }
        }.value
    }

    @Test("Face storage reads and committed mutations retain cancellation on their worker",
          arguments: [0, 1, 2, 3, 4, 5])
    func faceStorage(operation: Int) async {
        let root = URL(fileURLWithPath: "/virtual/face-storage")
        let queue = DispatchSerialQueue(label: "test.face-storage")
        let check = contextCheck(queue, root: root)
        let cancel: @Sendable () -> Void = {
            check()
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let faceID = UUID()
        let document = FolderFaceData(folderURL: root, faces: [], groups: [], lastScanDate: .distantPast, scanComplete: true)
        let service = FaceDataFolderLoadService(filesystemQueue: queue, loadFaceData: { _ in
            cancel()
            return document
        }, faceDataExists: { _ in
            check()
            return true
        }, loadThumbnail: { _, _ in
            cancel()
            return Data([1])
        }, deleteFaceData: { _ in cancel() }, saveFaceData: { _ in cancel() },
        saveThumbnail: { _, _, _ in cancel() }, deleteThumbnail: { _, _ in
            Issue.record("Cancellation after the document commit must stop thumbnail cleanup")
        })
        await Task {
            await CompanionFilesystemContext.$marker.withValue(root) {
                switch operation {
                case 0:
                    guard case .cancelled(let url) = await service.loadDocument(folderURL: root) else {
                        Issue.record("Cancelled document read was published")
                        return
                    }
                    #expect(url == root)
                case 1:
                    guard case .cancelled(let evidence) = await service.load(folderURL: root, cleanupPolicy: .never) else {
                        Issue.record("Cancelled folder read was published")
                        return
                    }
                    #expect(evidence.folderURL == root)
                    #expect(evidence.processedThumbnailCount == 0)
                case 2:
                    guard case .cancelled = await service.loadThumbnailData(faceID: faceID, folderURL: root) else {
                        Issue.record("Cancelled thumbnail read was published")
                        return
                    }
                case 3:
                    guard case .committed(let evidence) = await service.persist(document, deletingThumbnailIDs: [faceID]) else {
                        Issue.record("Committed document evidence was lost")
                        return
                    }
                    #expect(evidence.documentCommitted)
                    #expect(evidence.deletedThumbnailIDs.isEmpty)
                    #expect(evidence.requestedThumbnailDeletionCount == 1)
                    #expect(evidence.cancellationRequestedAfterCommit)
                case 4:
                    #expect(await service.persistThumbnail(Data([1]), faceID: faceID, folderURL: root)
                        == .committed(faceID: faceID, cancellationRequestedAfterCommit: true))
                default:
                    #expect(await service.deleteAll(for: root)
                        == .committed(folderURL: root, cancellationRequestedAfterCommit: true))
                }
            }
        }.value
    }

    @Test("Rename identities keep the caller task on their Dispatch worker", arguments: [false, true])
    func renameIdentities(cancel: Bool) async throws {
        let root = URL(fileURLWithPath: "/virtual/rename-identities")
        let queue = DispatchSerialQueue(label: "test.rename-identities")
        let check = contextCheck(queue, root: root)
        let service = RenameIdentityPreparationService(filesystemQueue: queue, lookup: { url in
            check()
            return url
        }, canonical: { url in
            check()
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return url
        })
        try await Task {
            try await CompanionFilesystemContext.$marker.withValue(root) {
                do {
                    let result = try await service.prepare(urls: [root], destinations: [root])
                    #expect(!cancel)
                    #expect(result.lookup(root) == root)
                    #expect(result.canonical(root) == root)
                } catch is CancellationError {
                    #expect(cancel)
                }
            }
        }.value
    }

    @Test("Voice memo planning retains only the complete prefix on cancellation")
    func voiceMemoPlanning() async {
        let root = URL(fileURLWithPath: "/virtual/voice-memo")
        let queue = DispatchSerialQueue(label: "test.voice-memo-planning")
        let check = contextCheck(queue, root: root)
        let first = root.appendingPathComponent("first.raw")
        let second = root.appendingPathComponent("second.raw")
        let service = VoiceMemoRenamePlanningService(filesystemQueue: queue) { url in
            check()
            #expect(url == first || url == second)
            if url == second { withUnsafeCurrentTask { $0?.cancel() } }
            return []
        }
        let request = VoiceMemoRenamePlanningRequest(requestID: UUID(), folderURL: root,
            items: [first, second, root.appendingPathComponent("unused.raw")].map { RenamePlanningItem(sourceImageURL: $0) })
        let result = await Task {
            await CompanionFilesystemContext.$marker.withValue(root) { await service.plan(request) }
        }.value
        #expect(result.requestID == request.requestID)
        #expect(result.items == [request.items[0]])
        #expect(result.completion == .cancelled(completedItemCount: 1))
    }

    @Test("DNG application lookup and executable probes retain caller cancellation", arguments: [false, true])
    func dngDiscovery(cancelDuringLookup: Bool) async {
        let root = URL(fileURLWithPath: "/virtual/converter.app")
        let queue = DispatchSerialQueue(label: "test.dng-discovery")
        let check = contextCheck(queue, root: root)
        let service = AdobeDNGDiscoveryService(filesystemQueue: queue, applications: {
            check()
            if cancelDuringLookup { withUnsafeCurrentTask { $0?.cancel() } }
            return [root, root.appendingPathComponent("unused")]
        }, executable: { url in
            check()
            #expect(url == root)
            #expect(!cancelDuringLookup)
            withUnsafeCurrentTask { $0?.cancel() }
            return root
        })
        let result = await Task {
            await CompanionFilesystemContext.$marker.withValue(root) { await service.discover() }
        }.value
        #expect(result == .cancelled(inspectedCount: cancelDuringLookup ? 0 : 1))
    }

    private func contextCheck(_ queue: DispatchSerialQueue, root: URL) -> @Sendable () -> Void {
        {
            #expect(queue.isIsolatingCurrentContext() == true)
            #expect(!Thread.isMainThread)
            #expect(CompanionFilesystemContext.marker == root)
        }
    }
}

private nonisolated enum CompanionFilesystemContext {
    @TaskLocal static var marker: URL?
}
