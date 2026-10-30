import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Browser pane layout tree")
struct BrowserPaneTreeTests {
    private final class Token {}
    /// Keeps the tokens alive so their ObjectIdentifiers stay unique.
    private let tokens = (0..<6).map { _ in Token() }
    private var ids: [BrowserPaneID] { tokens.map(ObjectIdentifier.init) }

    private func groupID(_ tree: BrowserPaneTree, containing pane: BrowserPaneID) -> UUID {
        tree.group(containing: pane)!.id
    }

    private func rootSplit(_ tree: BrowserPaneTree) -> BrowserPaneSplit? {
        if case .split(let split) = tree.root { return split }
        return nil
    }

    @Test func startsAsSinglePane() {
        let tree = BrowserPaneTree(single: ids[0])
        #expect(tree.isSinglePane)
        #expect(tree.paneIDs == [ids[0]])
        #expect(tree.visiblePaneIDs == [ids[0]])
    }

    @Test func addTabSelectsItInSameGroup() {
        var tree = BrowserPaneTree(single: ids[0])
        tree.addTab(ids[1], toGroup: groupID(tree, containing: ids[0]))
        #expect(tree.groups.count == 1)
        #expect(tree.paneIDs == [ids[0], ids[1]])
        #expect(tree.visiblePaneIDs == [ids[1]])
        #expect(!tree.isSinglePane)
    }

    @Test func splitEdgesPlaceNewGroupOnTheRightSide() {
        var tree = BrowserPaneTree(single: ids[0])
        tree.split(ids[1], besideGroup: groupID(tree, containing: ids[0]), edge: .leading)
        let split = rootSplit(tree)
        #expect(split?.axis == .horizontal)
        #expect(tree.visiblePaneIDs == [ids[1], ids[0]])
        #expect(split?.fractions == [0.5, 0.5])

        tree.split(ids[2], besideGroup: groupID(tree, containing: ids[0]), edge: .bottom)
        // Different axis → the right-hand group becomes a vertical split.
        #expect(tree.visiblePaneIDs == [ids[1], ids[0], ids[2]])
        if case .split(let inner) = rootSplit(tree)?.children[1] {
            #expect(inner.axis == .vertical)
        } else {
            Issue.record("Expected a nested vertical split")
        }
    }

    @Test func sameAxisSplitJoinsParentAndHalvesTargetShare() {
        var tree = BrowserPaneTree(single: ids[0])
        tree.split(ids[1], besideGroup: groupID(tree, containing: ids[0]), edge: .trailing)
        tree.split(ids[2], besideGroup: groupID(tree, containing: ids[1]), edge: .trailing)
        let split = rootSplit(tree)
        #expect(split?.children.count == 3)
        #expect(split?.fractions == [0.5, 0.25, 0.25])
    }

    @Test func removingLastPaneOfGroupCollapsesSplit() {
        var tree = BrowserPaneTree(single: ids[0])
        tree.split(ids[1], besideGroup: groupID(tree, containing: ids[0]), edge: .trailing)
        tree.remove(ids[1])
        #expect(tree.isSinglePane)
        #expect(tree.paneIDs == [ids[0]])
    }

    @Test func removingNestedGroupFlattensSameAxisSplits() {
        var tree = BrowserPaneTree(single: ids[0])
        tree.split(ids[1], besideGroup: groupID(tree, containing: ids[0]), edge: .trailing)
        tree.split(ids[2], besideGroup: groupID(tree, containing: ids[1]), edge: .bottom)
        tree.split(ids[3], besideGroup: groupID(tree, containing: ids[2]), edge: .trailing)
        // [0 | (1 / (2 | 3))] — dropping 1 leaves [0 | 2 | 3], all horizontal.
        tree.remove(ids[1])
        let split = rootSplit(tree)
        #expect(split?.axis == .horizontal)
        #expect(split?.children.count == 3)
        #expect(tree.visiblePaneIDs == [ids[0], ids[2], ids[3]])
        let total = split?.fractions.reduce(0, +) ?? 0
        #expect(abs(total - 1) < 1e-9)
    }

    @Test func removingSelectedTabSelectsNeighbour() {
        var tree = BrowserPaneTree(single: ids[0])
        let group = groupID(tree, containing: ids[0])
        tree.addTab(ids[1], toGroup: group)
        tree.addTab(ids[2], toGroup: group)
        tree.select(ids[1])
        tree.remove(ids[1])
        #expect(tree.visiblePaneIDs == [ids[2]])
    }

    @Test func lastPaneCannotBeRemoved() {
        var tree = BrowserPaneTree(single: ids[0])
        tree.remove(ids[0])
        #expect(tree.paneIDs == [ids[0]])
    }

    @Test func draggingTabToEdgeOfOwnGroupSplitsIt() {
        var tree = BrowserPaneTree(single: ids[0])
        let group = groupID(tree, containing: ids[0])
        tree.addTab(ids[1], toGroup: group)
        let moved1 = tree.move(ids[1], toGroup: group, edge: .trailing)
        #expect(moved1)
        #expect(tree.groups.count == 2)
        #expect(tree.visiblePaneIDs == [ids[0], ids[1]])
    }

    @Test func draggingOnlyTabOntoItsOwnGroupIsANoOp() {
        var tree = BrowserPaneTree(single: ids[0])
        tree.split(ids[1], besideGroup: groupID(tree, containing: ids[0]), edge: .trailing)
        let before = tree
        let group1 = groupID(tree, containing: ids[1])
        let moved2 = tree.move(ids[1], toGroup: group1, edge: .leading)
        #expect(!moved2)
        let moved3 = tree.move(ids[1], toGroup: group1, edge: .center)
        #expect(!moved3)
        #expect(tree == before)
    }

    @Test func draggingTabIntoAnotherGroupMergesAndCollapses() {
        var tree = BrowserPaneTree(single: ids[0])
        tree.split(ids[1], besideGroup: groupID(tree, containing: ids[0]), edge: .trailing)
        let group0 = groupID(tree, containing: ids[0])
        let moved4 = tree.move(ids[1], toGroup: group0, edge: .center, tabIndex: 0)
        #expect(moved4)
        #expect(tree.groups.count == 1)
        #expect(tree.paneIDs == [ids[1], ids[0]])
        #expect(tree.visiblePaneIDs == [ids[1]])
    }

    @Test func draggingSoleTabOfOneGroupToEdgeOfAnother() {
        var tree = BrowserPaneTree(single: ids[0])
        tree.split(ids[1], besideGroup: groupID(tree, containing: ids[0]), edge: .trailing)
        // Move the right pane below the left one: [1 / 0]... as a vertical split.
        let moved5 = tree.move(ids[1], toGroup: groupID(tree, containing: ids[0]), edge: .bottom)
        #expect(moved5)
        #expect(rootSplit(tree)?.axis == .vertical)
        #expect(tree.visiblePaneIDs == [ids[0], ids[1]])
    }

    @Test func reorderingTabsWithinBar() {
        var tree = BrowserPaneTree(single: ids[0])
        let group = groupID(tree, containing: ids[0])
        tree.addTab(ids[1], toGroup: group)
        tree.addTab(ids[2], toGroup: group)
        let moved6 = tree.move(ids[0], toGroup: group, edge: .center, tabIndex: 3)
        #expect(moved6)
        #expect(tree.paneIDs == [ids[1], ids[2], ids[0]])
        let moved7 = tree.move(ids[0], toGroup: group, edge: .center, tabIndex: 1)
        #expect(moved7)
        #expect(tree.paneIDs == [ids[1], ids[0], ids[2]])
        // Dropping right where it already is changes nothing.
        let moved8 = tree.move(ids[0], toGroup: group, edge: .center, tabIndex: 2)
        #expect(!moved8)
    }

    @Test func mergeAllIntoTabsKeepsEveryPane() {
        var tree = BrowserPaneTree(single: ids[0])
        tree.split(ids[1], besideGroup: groupID(tree, containing: ids[0]), edge: .trailing)
        tree.split(ids[2], besideGroup: groupID(tree, containing: ids[1]), edge: .bottom)
        tree.mergeAllIntoTabs(selected: ids[2])
        #expect(tree.groups.count == 1)
        #expect(Set(tree.paneIDs) == Set(ids[0...2]))
        #expect(tree.visiblePaneIDs == [ids[2]])
    }

    @Test func setFractionsNormalizesAndIgnoresMismatchedCounts() {
        var tree = BrowserPaneTree(single: ids[0])
        tree.split(ids[1], besideGroup: groupID(tree, containing: ids[0]), edge: .trailing)
        let splitID = rootSplit(tree)!.id
        tree.setFractions([3, 1], forSplit: splitID)
        #expect(rootSplit(tree)?.fractions == [0.75, 0.25])
        tree.setFractions([1, 1, 1], forSplit: splitID)
        #expect(rootSplit(tree)?.fractions == [0.75, 0.25])
    }
}
