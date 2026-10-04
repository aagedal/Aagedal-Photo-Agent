import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@MainActor
@Suite("Sidebar expansion")
struct SidebarExpansionTests {
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
