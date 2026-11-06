import Foundation
import Observation
import Testing
@testable import Aagedal_Photo_Agent

/// `withObservationTracking`'s onChange is @Sendable; it fires synchronously inside the
/// mutating call on this test's actor, so the lock only satisfies the compiler.
private nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Suite("Browser panes model")
@MainActor
struct BrowserPanesModelTests {
    private func makeModel() -> BrowserPanesModel {
        BrowserPanesModel(primary: BrowserViewModel(),
                          thumbnailService: ThumbnailService(),
                          fullScreenImageCache: FullScreenImageCache())
    }

    @Test func layoutSummariesFollowTabsSplitsAndClose() throws {
        let model = makeModel()
        let primary = BrowserPaneID(model.primary)
        #expect(model.visiblePaneIDs == [primary])
        #expect(model.groupCount == 1)

        let tab = try #require(model.addTab())
        #expect(model.visiblePaneIDs == [BrowserPaneID(tab)])
        #expect(model.groupCount == 1)

        let split = try #require(model.splitActive(.trailing))
        #expect(model.groupCount == 2)
        #expect(model.visiblePaneIDs == model.tree.visiblePaneIDs)
        #expect(model.visiblePaneIDs.contains(BrowserPaneID(split)))

        model.close(BrowserPaneID(split))
        #expect(model.groupCount == 1)
        #expect(model.visiblePaneIDs == model.tree.visiblePaneIDs)

        model.close(BrowserPaneID(tab))
        #expect(model.visiblePaneIDs == [primary])
    }

    /// Photos dragged from a non-primary grid onto a sidebar folder (bound to the primary pane)
    /// must move through the pane that lists them.
    @Test func sidebarPhotoDropsResolveToTheListingPane() throws {
        let model = makeModel()
        let left = URL(fileURLWithPath: "/tmp/panes-left", isDirectory: true)
        let right = URL(fileURLWithPath: "/tmp/panes-right", isDirectory: true)
        model.primary.currentFolderURL = left
        let split = try #require(model.splitActive(.trailing))
        split.currentFolderURL = right
        let photo = right.appendingPathComponent("a.jpg")

        #expect(model.primary.paneOwningImages?([photo], nil) === split)
        #expect(model.primary.paneOwningImages?([left.appendingPathComponent("b.jpg")], nil) === model.primary)
        #expect(model.primary.paneOwningImages?([URL(fileURLWithPath: "/tmp/elsewhere/c.jpg")], nil) == nil)

        // Two tabs on the same folder: the active one wins.
        let twin = try #require(model.addTab())
        twin.currentFolderURL = right
        model.activate(BrowserPaneID(twin))
        #expect(model.pane(owningImagesAt: [photo]) === twin)
    }

    /// Two inactive panes on the same folder, one hidden behind a tab: a drag from the visible
    /// one must move through it, and with no known source a visible owner beats a hidden one.
    @Test func sidebarPhotoDropsPreferTheDragSourceThenVisiblePanes() throws {
        let model = makeModel()
        let left = URL(fileURLWithPath: "/tmp/panes-left", isDirectory: true)
        let shared = URL(fileURLWithPath: "/tmp/panes-shared", isDirectory: true)
        model.primary.currentFolderURL = left
        // `hidden` is created first so a first-match fallback would pick it.
        let hidden = try #require(model.addTab())
        hidden.currentFolderURL = shared
        model.activate(BrowserPaneID(model.primary))
        let visible = try #require(model.splitActive(.trailing))
        visible.currentFolderURL = shared
        model.activate(BrowserPaneID(model.primary))
        #expect(!model.visiblePanes.contains { $0 === hidden })
        #expect(model.visiblePanes.contains { $0 === visible })
        let photo = shared.appendingPathComponent("a.jpg")

        #expect(model.pane(owningImagesAt: [photo]) === visible)

        visible.draggedImageURLs = [photo]
        let source = try #require(model.primary.paneDraggingImages?())
        #expect(source === visible)
        #expect(model.primary.paneOwningImages?([photo], source) === visible)
        visible.draggedImageURLs = []
        #expect(model.primary.paneDraggingImages?() == nil)
    }

    /// Banners from a pane's file operations show where the user is looking: in the pane while
    /// it's on screen, otherwise in the active pane.
    @Test func fileOperationErrorsFromHiddenPanesReachTheActivePane() throws {
        let model = makeModel()
        let hidden = try #require(model.addTab())
        model.activate(BrowserPaneID(model.primary))
        let visible = try #require(model.splitActive(.trailing))
        model.activate(BrowserPaneID(model.primary))

        visible.folderOperationErrorReporter?("on screen")
        #expect(visible.errorMessage == "on screen")

        hidden.folderOperationErrorReporter?("behind a tab")
        #expect(hidden.errorMessage == nil)
        #expect(model.active.errorMessage == "behind a tab")
    }

    /// A divider drag replaces `tree` every frame; views outside the grid read only the
    /// summaries, which must not invalidate while the arrangement itself is unchanged.
    @Test func resizingSplitsDoesNotInvalidateLayoutSummaries() throws {
        let model = makeModel()
        _ = try #require(model.splitActive(.trailing))
        guard case .split(let split) = model.tree.root else {
            Issue.record("expected a split root")
            return
        }

        let summariesChanged = Flag()
        withObservationTracking {
            _ = model.visiblePaneIDs
            _ = model.groupCount
        } onChange: {
            summariesChanged.set()
        }
        model.setFractions([0.3, 0.7], forSplit: split.id)
        model.setFractions([0.4, 0.6], forSplit: split.id)

        #expect(!summariesChanged.isSet)
        guard case .split(let resized) = model.tree.root else {
            Issue.record("expected a split root")
            return
        }
        #expect(resized.fractions == [0.4, 0.6])
    }

    /// View ▸ Show Next/Previous Tab walk every tab of every group in reading order and wrap.
    @Test func adjacentTabCyclingWalksReadingOrderAndWraps() throws {
        let model = makeModel()
        let primary = BrowserPaneID(model.primary)
        model.activateAdjacentPane(offset: 1)
        #expect(model.activePaneID == primary)

        let tab = BrowserPaneID(try #require(model.addTab()))
        let split = BrowserPaneID(try #require(model.splitActive(.trailing)))
        #expect(model.tree.paneIDs == [primary, tab, split])

        model.activateAdjacentPane(offset: 1)
        #expect(model.activePaneID == primary)
        model.activateAdjacentPane(offset: 1)
        #expect(model.activePaneID == tab)
        model.activateAdjacentPane(offset: -1)
        #expect(model.activePaneID == primary)
        model.activateAdjacentPane(offset: -1)
        #expect(model.activePaneID == split)

        // Cycling onto a background tab brings it to the front of its group.
        model.activateAdjacentPane(offset: 1)
        model.activateAdjacentPane(offset: 1)
        #expect(model.tree.group(containing: tab)?.selectedPaneID == tab)
    }

    /// ⌘W closes the active tab only when it isn't the primary pane, which owns the sidebar.
    @Test func onlyNonPrimaryActivePanesCanCloseFromTheKeyboard() throws {
        let model = makeModel()
        #expect(!model.canCloseActivePane)
        let tab = try #require(model.addTab())
        #expect(model.canCloseActivePane)
        model.activate(BrowserPaneID(model.primary))
        #expect(!model.canCloseActivePane)
        model.activate(BrowserPaneID(tab))
        model.close(model.activePaneID)
        #expect(!model.hasMultiplePanes)
        #expect(!model.canCloseActivePane)
    }

    /// Sidebar folder operations run on the primary pane (it owns the sidebar), which may be a
    /// background tab; their failures must show in the pane the user is looking at.
    @Test func liveIDResolvesOnlyPanesThatAreStillOpen() throws {
        let model = makeModel()
        let tab = try #require(model.addTab())
        #expect(model.liveID(of: tab) == BrowserPaneID(tab))
        model.close(BrowserPaneID(tab))
        #expect(model.liveID(of: tab) == nil)
        #expect(model.liveID(of: nil) == nil)
        #expect(model.liveID(of: BrowserViewModel()) == nil)
    }

    @Test func sidebarFolderErrorsShowInTheActivePane() throws {
        let model = makeModel()
        let parent = URL(fileURLWithPath: "/tmp/panes-sidebar-parent", isDirectory: true)
        let child = parent.appendingPathComponent("child", isDirectory: true)

        model.primary.moveFolder(parent, into: child)
        #expect(model.primary.errorMessage == "Cannot move a folder into its own subfolder.")
        model.primary.errorMessage = nil

        let tab = try #require(model.addTab())
        model.primary.moveFolder(parent, into: child)
        #expect(tab.errorMessage == "Cannot move a folder into its own subfolder.")
        #expect(model.primary.errorMessage == nil)
    }

    /// Sidebar rows and Finder drags use directory URLs, whose `path(percentEncoded:)` ends in
    /// "/"; the own-subfolder guard used to compare `path + "/"` and never matched them.
    @Test func movingAFolderIntoItsOwnSubfolderIsRefusedForDirectoryAndPlainURLs() {
        let model = makeModel()
        let message = "Cannot move a folder into its own subfolder."
        let pairs: [(URL, URL)] = [
            (URL(fileURLWithPath: "/tmp/panes-move-a", isDirectory: true),
             URL(fileURLWithPath: "/tmp/panes-move-a/b/c", isDirectory: true)),
            (URL(fileURLWithPath: "/tmp/panes-move-a"), URL(fileURLWithPath: "/tmp/panes-move-a/b")),
        ]
        for (source, destination) in pairs {
            model.primary.errorMessage = nil
            model.primary.moveFolder(source, into: destination)
            #expect(model.primary.errorMessage == message)
        }
    }
}
