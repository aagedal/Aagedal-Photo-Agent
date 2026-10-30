import Foundation

/// Identity of one browser pane in the layout tree (the pane's `BrowserViewModel`).
typealias BrowserPaneID = ObjectIdentifier

/// Direction of a split: `.horizontal` lays children out side by side,
/// `.vertical` stacks them top to bottom.
enum BrowserPaneAxis: Equatable {
    case horizontal
    case vertical
}

/// Where a dragged tab lands relative to a tab group. The four edges split the group;
/// `.center` adds the tab to the group.
enum BrowserPaneDropEdge: Equatable {
    case leading, trailing, top, bottom, center

    var splitAxis: BrowserPaneAxis? {
        switch self {
        case .leading, .trailing: .horizontal
        case .top, .bottom: .vertical
        case .center: nil
        }
    }

    /// The new group goes before the target (left / above) rather than after it.
    var insertsBefore: Bool { self == .leading || self == .top }
}

/// A set of panes shown as tabs in one rectangle; exactly one is visible.
struct BrowserPaneGroup: Equatable, Identifiable {
    let id: UUID
    var paneIDs: [BrowserPaneID]
    var selectedPaneID: BrowserPaneID

    init(id: UUID = UUID(), paneIDs: [BrowserPaneID], selectedPaneID: BrowserPaneID? = nil) {
        precondition(!paneIDs.isEmpty, "A pane group needs at least one pane")
        self.id = id
        self.paneIDs = paneIDs
        self.selectedPaneID = selectedPaneID.flatMap { paneIDs.contains($0) ? $0 : nil } ?? paneIDs[0]
    }
}

/// Children laid out along one axis; `fractions` (same count, summing to 1) size them.
struct BrowserPaneSplit: Equatable, Identifiable {
    let id: UUID
    var axis: BrowserPaneAxis
    var children: [BrowserPaneNode]
    var fractions: [Double]
}

indirect enum BrowserPaneNode: Equatable, Identifiable {
    case group(BrowserPaneGroup)
    case split(BrowserPaneSplit)

    var id: UUID {
        switch self {
        case .group(let group): group.id
        case .split(let split): split.id
        }
    }
}

/// Bridge-style browser layout: tab groups arranged in nested splits. A value type with
/// pure operations, so `BrowserPanesModel` owns the pane objects and this owns only where
/// each one sits. Every operation keeps the tree normalized: no empty groups, no splits
/// with fewer than two children, and no split directly nested in a split of the same axis.
struct BrowserPaneTree: Equatable {
    private(set) var root: BrowserPaneNode

    init(single pane: BrowserPaneID) {
        root = .group(BrowserPaneGroup(paneIDs: [pane]))
    }

    init(root: BrowserPaneNode) {
        self.root = root
    }

    // MARK: Queries

    /// Every group, in reading order (leading/top first).
    var groups: [BrowserPaneGroup] {
        var result: [BrowserPaneGroup] = []
        func walk(_ node: BrowserPaneNode) {
            switch node {
            case .group(let group): result.append(group)
            case .split(let split): split.children.forEach(walk)
            }
        }
        walk(root)
        return result
    }

    /// Every pane, in reading order.
    var paneIDs: [BrowserPaneID] { groups.flatMap(\.paneIDs) }

    /// The selected (on-screen) pane of every group.
    var visiblePaneIDs: [BrowserPaneID] { groups.map(\.selectedPaneID) }

    var paneCount: Int { groups.reduce(0) { $0 + $1.paneIDs.count } }

    /// True when the browser is a single group holding a single pane — the classic browser.
    var isSinglePane: Bool {
        if case .group(let group) = root, group.paneIDs.count == 1 { return true }
        return false
    }

    func group(containing pane: BrowserPaneID) -> BrowserPaneGroup? {
        groups.first { $0.paneIDs.contains(pane) }
    }

    func group(withID id: UUID) -> BrowserPaneGroup? {
        groups.first { $0.id == id }
    }

    func contains(_ pane: BrowserPaneID) -> Bool {
        group(containing: pane) != nil
    }

    // MARK: Mutations

    /// Bring `pane` to the front of its group.
    mutating func select(_ pane: BrowserPaneID) {
        updateGroup(containing: pane) { $0.selectedPaneID = pane }
    }

    /// Add a pane that isn't in the tree yet as a tab of `groupID` (selected).
    /// `index` = tab position; nil appends.
    mutating func addTab(_ pane: BrowserPaneID, toGroup groupID: UUID, at index: Int? = nil) {
        guard !contains(pane) else { return }
        updateGroup(withID: groupID) { group in
            let position = min(max(index ?? group.paneIDs.count, 0), group.paneIDs.count)
            group.paneIDs.insert(pane, at: position)
            group.selectedPaneID = pane
        }
    }

    /// Put a pane that isn't in the tree yet into a new group beside `groupID`.
    mutating func split(_ pane: BrowserPaneID, besideGroup groupID: UUID, edge: BrowserPaneDropEdge) {
        guard !contains(pane) else { return }
        guard let axis = edge.splitAxis else {
            addTab(pane, toGroup: groupID)
            return
        }
        let newGroup = BrowserPaneNode.group(BrowserPaneGroup(paneIDs: [pane]))
        root = Self.normalized(
            Self.inserting(newGroup, beside: groupID, axis: axis, before: edge.insertsBefore, in: root)
        )
    }

    /// Remove a pane. Its group disappears when it was the last tab, and the surrounding
    /// split collapses when only one child is left. The last pane can't be removed.
    mutating func remove(_ pane: BrowserPaneID) {
        guard contains(pane), paneCount > 1 else { return }
        if let pruned = Self.removing(pane, from: root) {
            root = Self.normalized(pruned)
        }
    }

    /// Drag-and-drop: move an existing pane onto `groupID` at `edge`. `.center` makes it a
    /// tab of that group (at `tabIndex`, or appended); an edge splits the group.
    /// Returns false when the drop would leave the layout unchanged.
    @discardableResult
    mutating func move(
        _ pane: BrowserPaneID,
        toGroup groupID: UUID,
        edge: BrowserPaneDropEdge,
        tabIndex: Int? = nil
    ) -> Bool {
        guard let source = group(containing: pane), let target = group(withID: groupID) else { return false }

        if source.id == target.id {
            if edge == .center {
                // Reorder within the tab bar.
                guard let from = source.paneIDs.firstIndex(of: pane) else { return false }
                var to = min(max(tabIndex ?? source.paneIDs.count, 0), source.paneIDs.count)
                if to > from { to -= 1 }
                guard to != from else {
                    select(pane)
                    return false
                }
                updateGroup(withID: groupID) { group in
                    group.paneIDs.remove(at: from)
                    group.paneIDs.insert(pane, at: to)
                    group.selectedPaneID = pane
                }
                return true
            }
            // Splitting a group by its own only tab would just recreate it.
            guard source.paneIDs.count > 1 else { return false }
        }

        let before = self
        // Removing the pane can't delete the target group: either it's a different group,
        // or (same group) it still holds the other tabs.
        if let pruned = Self.removing(pane, from: root) {
            root = Self.normalized(pruned)
        }
        if edge == .center {
            addTab(pane, toGroup: groupID, at: tabIndex)
        } else {
            split(pane, besideGroup: groupID, edge: edge)
        }
        return self != before
    }

    /// Gather every pane into one tab group, keeping `selected` in front.
    mutating func mergeAllIntoTabs(selected: BrowserPaneID?) {
        let all = paneIDs
        guard let first = all.first else { return }
        let keepID = groups.first?.id ?? UUID()
        root = .group(BrowserPaneGroup(id: keepID, paneIDs: all, selectedPaneID: selected ?? first))
    }

    /// Resize the children of split `splitID`. Ignored when the count doesn't match.
    mutating func setFractions(_ fractions: [Double], forSplit splitID: UUID) {
        root = Self.mapSplits(root) { split in
            guard split.id == splitID, fractions.count == split.children.count else { return split }
            var updated = split
            updated.fractions = Self.normalizedFractions(fractions)
            return updated
        }
    }

    // MARK: Tree helpers

    private mutating func updateGroup(withID id: UUID, _ change: (inout BrowserPaneGroup) -> Void) {
        root = Self.mapGroups(root) { group in
            guard group.id == id else { return group }
            var updated = group
            change(&updated)
            return updated
        }
    }

    private mutating func updateGroup(containing pane: BrowserPaneID, _ change: (inout BrowserPaneGroup) -> Void) {
        guard let id = group(containing: pane)?.id else { return }
        updateGroup(withID: id, change)
    }

    private static func mapGroups(_ node: BrowserPaneNode, _ transform: (BrowserPaneGroup) -> BrowserPaneGroup) -> BrowserPaneNode {
        switch node {
        case .group(let group):
            return .group(transform(group))
        case .split(var split):
            split.children = split.children.map { mapGroups($0, transform) }
            return .split(split)
        }
    }

    private static func mapSplits(_ node: BrowserPaneNode, _ transform: (BrowserPaneSplit) -> BrowserPaneSplit) -> BrowserPaneNode {
        switch node {
        case .group:
            return node
        case .split(var split):
            split.children = split.children.map { mapSplits($0, transform) }
            return .split(transform(split))
        }
    }

    /// Insert `newNode` next to the group `groupID`. Joins the parent split when its axis
    /// matches (taking half of the target's share), otherwise wraps the target in a new split.
    private static func inserting(
        _ newNode: BrowserPaneNode,
        beside groupID: UUID,
        axis: BrowserPaneAxis,
        before: Bool,
        in node: BrowserPaneNode
    ) -> BrowserPaneNode {
        switch node {
        case .group(let group):
            guard group.id == groupID else { return node }
            return .split(BrowserPaneSplit(
                id: UUID(),
                axis: axis,
                children: before ? [newNode, node] : [node, newNode],
                fractions: [0.5, 0.5]
            ))
        case .split(var split):
            if split.axis == axis,
               let index = split.children.firstIndex(where: {
                   if case .group(let g) = $0 { return g.id == groupID }
                   return false
               }) {
                let half = split.fractions[index] / 2
                split.fractions[index] = half
                let insertAt = before ? index : index + 1
                split.children.insert(newNode, at: insertAt)
                split.fractions.insert(half, at: insertAt)
                return .split(split)
            }
            split.children = split.children.map {
                inserting(newNode, beside: groupID, axis: axis, before: before, in: $0)
            }
            return .split(split)
        }
    }

    /// The node without `pane`, or nil when nothing is left of it.
    private static func removing(_ pane: BrowserPaneID, from node: BrowserPaneNode) -> BrowserPaneNode? {
        switch node {
        case .group(var group):
            guard let index = group.paneIDs.firstIndex(of: pane) else { return node }
            group.paneIDs.remove(at: index)
            guard !group.paneIDs.isEmpty else { return nil }
            if group.selectedPaneID == pane {
                // Like a browser: show the neighbour that slid into the closed tab's place.
                group.selectedPaneID = group.paneIDs[min(index, group.paneIDs.count - 1)]
            }
            return .group(group)
        case .split(var split):
            var children: [BrowserPaneNode] = []
            var fractions: [Double] = []
            for (child, fraction) in zip(split.children, split.fractions) {
                if let kept = removing(pane, from: child) {
                    children.append(kept)
                    fractions.append(fraction)
                }
            }
            guard !children.isEmpty else { return nil }
            split.children = children
            split.fractions = fractions
            return .split(split)
        }
    }

    /// Collapse single-child splits and flatten same-axis nesting.
    private static func normalized(_ node: BrowserPaneNode) -> BrowserPaneNode {
        guard case .split(var split) = node else { return node }
        var children: [BrowserPaneNode] = []
        var fractions: [Double] = []
        for (child, fraction) in zip(split.children.map(normalized), split.fractions) {
            if case .split(let inner) = child, inner.axis == split.axis {
                children.append(contentsOf: inner.children)
                fractions.append(contentsOf: normalizedFractions(inner.fractions).map { $0 * fraction })
            } else {
                children.append(child)
                fractions.append(fraction)
            }
        }
        if children.count == 1 { return children[0] }
        split.children = children
        split.fractions = normalizedFractions(fractions)
        return .split(split)
    }

    private static func normalizedFractions(_ fractions: [Double]) -> [Double] {
        let positive = fractions.map { $0.isFinite ? max($0, 0.0001) : 0.0001 }
        let total = positive.reduce(0, +)
        guard total > 0 else { return fractions.map { _ in 1 / Double(fractions.count) } }
        return positive.map { $0 / total }
    }
}
