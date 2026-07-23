import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@MainActor
@Suite("Sidebar expansion")
struct SidebarExpansionTests {
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
