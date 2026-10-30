import Foundation

/// Owns the `BrowserViewModel` panes that share the center thumbnail area, their
/// Bridge-style arrangement (tab groups in nested splits, `tree`), and which pane is
/// active. Only the grid area splits: the sidebar, face bar, metadata panel and edit
/// view stay single and follow the active pane.
///
/// All panes share one `ThumbnailService` (decode gate + NSCache) and one
/// `FullScreenImageCache` so several folders can't multiply the concurrent-decode load
/// or the IOSurface memory pressure.
@Observable
final class BrowserPanesModel {
    /// Upper bound on open panes. Each one keeps a folder's image list, metadata and grid
    /// alive (and is auto-refreshed), so this keeps a busy layout from growing unbounded.
    static let maximumPaneCount = 8

    /// Every open pane. `panes[0]` is the primary pane: it owns the sidebar's folder-tree
    /// state, so it can be moved anywhere but never closed.
    private(set) var panes: [BrowserViewModel]
    /// Where each pane sits. Always launches as a single pane — a saved layout would point
    /// its other panes at folders we haven't reloaded yet.
    private(set) var tree: BrowserPaneTree
    private(set) var activePaneID: BrowserPaneID

    private let sharedThumbnailService: ThumbnailService
    private let sharedFullScreenImageCache: FullScreenImageCache

    /// Run on every newly created pane so callers can wire cross-cutting hooks
    /// (e.g. face deletion) without this model knowing about them.
    @ObservationIgnored var configurePane: ((BrowserViewModel) -> Void)?

    init(primary: BrowserViewModel,
         thumbnailService: ThumbnailService,
         fullScreenImageCache: FullScreenImageCache) {
        self.panes = [primary]
        self.sharedThumbnailService = thumbnailService
        self.sharedFullScreenImageCache = fullScreenImageCache
        let primaryID = BrowserPaneID(primary)
        self.tree = BrowserPaneTree(single: primaryID)
        self.activePaneID = primaryID
    }

    /// The pane every single consumer (sidebar, metadata, faces, edit) follows.
    var active: BrowserViewModel {
        pane(withID: activePaneID) ?? panes[0]
    }

    var primary: BrowserViewModel { panes[0] }

    /// More than one pane exists (split and/or tabs) — drives the pane chrome.
    var hasMultiplePanes: Bool { panes.count > 1 }

    var canAddPane: Bool { panes.count < Self.maximumPaneCount }

    func pane(withID id: BrowserPaneID) -> BrowserViewModel? {
        panes.first { BrowserPaneID($0) == id }
    }

    func isPrimary(_ id: BrowserPaneID) -> Bool {
        id == BrowserPaneID(panes[0])
    }

    /// Panes currently on screen (the front tab of every group), active pane included.
    var visiblePanes: [BrowserViewModel] {
        tree.visiblePaneIDs.compactMap(pane(withID:))
    }

    /// Folders shown by on-screen panes other than the active one — the sidebar marks
    /// them so it's clear which folder is where.
    var otherVisibleFolderURLs: Set<URL> {
        Set(visiblePanes.filter { BrowserPaneID($0) != activePaneID }.compactMap(\.currentFolderURL))
    }

    // MARK: Focus

    /// Focus a pane (and bring it to the front of its tab group).
    func activate(_ id: BrowserPaneID) {
        guard pane(withID: id) != nil else { return }
        if tree.group(containing: id)?.selectedPaneID != id { tree.select(id) }
        if activePaneID != id { activePaneID = id }
    }

    // MARK: Creating and closing panes

    /// Make a new empty pane sharing the heavy services. Not yet placed in the tree.
    private func makePane() -> BrowserViewModel? {
        guard canAddPane else { return nil }
        let pane = BrowserViewModel(
            thumbnailService: sharedThumbnailService,
            fullScreenImageCache: sharedFullScreenImageCache
        )
        configurePane?(pane)
        panes.append(pane)
        return pane
    }

    /// New tab in `groupID` (default: the active pane's group). The new pane becomes active.
    @discardableResult
    func addTab(toGroup groupID: UUID? = nil) -> BrowserViewModel? {
        guard let target = groupID ?? tree.group(containing: activePaneID)?.id,
              let pane = makePane() else { return nil }
        let id = BrowserPaneID(pane)
        tree.addTab(id, toGroup: target)
        activate(id)
        return pane
    }

    /// New pane in a split beside the active pane's group. The new pane becomes active.
    @discardableResult
    func splitActive(_ edge: BrowserPaneDropEdge) -> BrowserViewModel? {
        guard let target = tree.group(containing: activePaneID)?.id,
              let pane = makePane() else { return nil }
        let id = BrowserPaneID(pane)
        tree.split(id, besideGroup: target, edge: edge)
        activate(id)
        return pane
    }

    /// Close a pane (never the primary). Focus moves to whatever its group now shows,
    /// or to the first visible pane when the whole group went away.
    func close(_ id: BrowserPaneID) {
        guard !isPrimary(id), let index = panes.firstIndex(where: { BrowserPaneID($0) == id }) else { return }
        let replacement = tree.group(containing: id).flatMap { group -> BrowserPaneID? in
            guard group.paneIDs.count > 1, let tab = group.paneIDs.firstIndex(of: id) else { return nil }
            var remaining = group.paneIDs
            remaining.remove(at: tab)
            return remaining[min(tab, remaining.count - 1)]
        }
        tree.remove(id)
        panes.remove(at: index)
        if activePaneID == id {
            activate(replacement ?? tree.visiblePaneIDs.first ?? BrowserPaneID(panes[0]))
        }
    }

    /// Back to the classic single browser: close every pane except the primary (which owns
    /// the sidebar's folder-tree state). Callers that want to keep showing a non-primary
    /// pane's folder load it into the primary afterwards.
    func closeAllButPrimary() {
        for pane in panes.dropFirst() {
            close(BrowserPaneID(pane))
        }
        activate(BrowserPaneID(panes[0]))
    }

    /// Gather every pane into one tab group.
    func mergeAllIntoTabs() {
        tree.mergeAllIntoTabs(selected: activePaneID)
    }

    // MARK: Drag and drop / resizing

    /// Move a pane's tab onto a group edge (split) or into its tab bar.
    func move(_ id: BrowserPaneID, toGroup groupID: UUID, edge: BrowserPaneDropEdge, tabIndex: Int? = nil) {
        tree.move(id, toGroup: groupID, edge: edge, tabIndex: tabIndex)
        activate(id)
    }

    func setFractions(_ fractions: [Double], forSplit splitID: UUID) {
        tree.setFractions(fractions, forSplit: splitID)
    }
}
