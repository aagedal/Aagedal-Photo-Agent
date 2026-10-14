import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@MainActor
@Suite("Sidebar expansion")
struct SidebarExpansionTests {
    @Test("Wide sidebar prefetch is deduplicated and user expansion overtakes siblings")
    func boundedPrefetchPrioritizesExpansion() async throws {
        let root = URL(fileURLWithPath: "/virtual/sidebar")
        let children = (0..<200).map { root.appendingPathComponent("Child\($0)") }
        let scanner = SidebarScanGate()
        let viewModel = BrowserViewModel(subfolderLoader: { try await scanner.list($0) })
        viewModel.subfoldersByOpenFolder[root] = children
        viewModel.ensureSubfoldersLoaded(for: root)
        for _ in 0..<200 {
            if await scanner.calls.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await scanner.calls == [children[0]])
        // Repeated requests and overlapping trees must share the same work.
        viewModel.ensureSubfoldersLoaded(for: root)
        viewModel.ensureSubfoldersLoaded(for: children[199])
        viewModel.ensureSubfoldersLoaded(for: children[199])
        #expect(await scanner.calls.count == 1)
        await scanner.release()
        for _ in 0..<200 {
            if viewModel.subfoldersByOpenFolder[children[198]] != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let calls = await scanner.calls
        #expect(calls.count == children.count)
        #expect(Set(calls).count == children.count)
        #expect(Array(calls.prefix(2)) == [children[0], children[199]])
        #expect(viewModel.subfoldersByOpenFolder[children[199]] == [])
    }

    @Test("Removing a favorite rejects in-flight discovery and refresh", arguments: [false, true])
    func removedTreeRejectsPublication(refresh: Bool) async throws {
        let root = URL(fileURLWithPath: "/virtual/removed-sidebar")
        let children = (0..<4).map { root.appendingPathComponent("Child\($0)") }
        let scanner = SidebarScanGate()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let viewModel = BrowserViewModel(favoritesDefaults: defaults,
                                        subfolderLoader: { try await scanner.list($0) })
        let favorite = FavoriteFolder(url: root)
        viewModel.favoriteFolders = [favorite]
        viewModel.subfoldersByOpenFolder[root] = children
        if refresh { viewModel.refreshSubfolders(for: root) }
        else { viewModel.ensureSubfoldersLoaded(for: root) }
        for _ in 0..<200 {
            if await scanner.calls.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        viewModel.removeFavorite(favorite)
        await scanner.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(viewModel.subfoldersByOpenFolder[root] == nil)
        #expect(children.allSatisfy { viewModel.subfoldersByOpenFolder[$0] == nil })
        #expect(await scanner.calls == [refresh ? root : children[0]])
    }

    @Test("Failed sidebar discovery remains retryable instead of caching an empty folder")
    func failedDiscoveryRetries() async throws {
        let folder = URL(fileURLWithPath: "/virtual/retry")
        let scanner = SidebarRetryScanner()
        let viewModel = BrowserViewModel(subfolderLoader: { try await scanner.list($0) })
        viewModel.ensureSubfoldersLoaded(for: folder)
        for _ in 0..<200 {
            if await scanner.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        // Yield to allow the failed read's main-actor completion to clear admission.
        try await Task.sleep(for: .milliseconds(20))
        #expect(viewModel.subfoldersByOpenFolder[folder] == nil)
        viewModel.ensureSubfoldersLoaded(for: folder)
        for _ in 0..<200 {
            if viewModel.subfoldersByOpenFolder[folder] != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await scanner.calls == 2)
        #expect(viewModel.subfoldersByOpenFolder[folder] == [])
    }

    @Test("Expanding a cached child discovers disclosure state for newly visible descendants")
    func cachedExpansionPrefetchesVisibleDescendants() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        let child = root.appendingPathComponent("Child", isDirectory: true)
        let grandchild = child.appendingPathComponent("Grandchild", isDirectory: true)
        let descendant = grandchild.appendingPathComponent("Descendant", isDirectory: true)
        let empty = child.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = BrowserViewModel()
        viewModel.subfoldersByOpenFolder[root] = [child]
        viewModel.subfoldersByOpenFolder[child] = [grandchild, empty]
        #expect(viewModel.subfoldersByOpenFolder[grandchild] == nil)

        viewModel.toggleFolderExpansion(child, in: .open)
        for _ in 0..<200 {
            if viewModel.subfoldersByOpenFolder[grandchild] != nil,
               viewModel.subfoldersByOpenFolder[empty] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.subfoldersByOpenFolder[grandchild]?.map { $0.resolvingSymlinksInPath() }
            == [descendant.resolvingSymlinksInPath()])
        #expect(viewModel.subfoldersByOpenFolder[empty] == [])
        #expect(viewModel.currentFolderURL == nil)
        #expect(viewModel.isExpanded(child, in: .open))
        #expect(!viewModel.isExpanded(grandchild, in: .open))
    }

    @Test("A nested favorite expands independently from the same folder's favorite root")
    func overlappingFavoritesHaveIndependentExpansion() {
        let picturesURL = URL(fileURLWithPath: "/Pictures", isDirectory: true)
        let testImagesURL = picturesURL.appendingPathComponent(
            "TestImages",
            isDirectory: true
        )
        let picturesFavorite = FavoriteFolder(url: picturesURL)
        let testImagesFavorite = FavoriteFolder(url: testImagesURL)
        let viewModel = BrowserViewModel()
        viewModel.favoriteFolders = [testImagesFavorite, picturesFavorite]
        viewModel.subfoldersByOpenFolder[testImagesURL] = [
            testImagesURL.appendingPathComponent("Exports", isDirectory: true)
        ]

        let nestedTree = SidebarTree.favorites(rootID: picturesFavorite.id)
        let rootTree = SidebarTree.favorites(rootID: testImagesFavorite.id)

        viewModel.toggleFolderExpansion(testImagesURL, in: nestedTree)

        #expect(viewModel.isExpanded(testImagesURL, in: nestedTree))
        #expect(!viewModel.isExpanded(testImagesURL, in: rootTree))

        viewModel.toggleFolderExpansion(testImagesURL, in: rootTree)

        #expect(viewModel.isExpanded(testImagesURL, in: nestedTree))
        #expect(viewModel.isExpanded(testImagesURL, in: rootTree))

        viewModel.toggleFolderExpansion(testImagesURL, in: nestedTree)

        #expect(!viewModel.isExpanded(testImagesURL, in: nestedTree))
        #expect(viewModel.isExpanded(testImagesURL, in: rootTree))
    }

    @Test("Overlapping expanded favorites give duplicate child URLs unique row IDs")
    func overlappingFavoritesHaveUniqueChildRowIDs() {
        let picturesFavoriteID = UUID()
        let testImagesFavoriteID = UUID()
        let childURL = URL(
            fileURLWithPath: "/Pictures/TestImages/Exports",
            isDirectory: true
        )

        let rowIDs = [
            SidebarFolderRowIdentity(
                tree: .favorites(rootID: picturesFavoriteID),
                url: childURL
            ),
            SidebarFolderRowIdentity(
                tree: .favorites(rootID: testImagesFavoriteID),
                url: childURL
            ),
        ]

        #expect(Set(rowIDs).count == 2)
    }
}

private actor SidebarScanGate {
    private(set) var calls: [URL] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func list(_ url: URL) async throws -> [URL] {
        calls.append(url)
        if calls.count == 1 && !released {
            await withCheckedContinuation { continuation = $0 }
        }
        return []
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor SidebarRetryScanner {
    private(set) var calls = 0
    func list(_ url: URL) throws -> [URL] {
        calls += 1
        if calls == 1 { throw CocoaError(.fileReadNoPermission) }
        return []
    }
}
