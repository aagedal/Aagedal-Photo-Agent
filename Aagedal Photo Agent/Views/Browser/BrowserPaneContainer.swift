import SwiftUI

/// Hosts the thumbnail grid in a Bridge-style layout: tab groups arranged in nested
/// splits (`BrowserPanesModel.tree`). Drag a tab onto an edge of any pane to split it,
/// or onto a tab bar to make it a tab there. Only the grid area splits; everything else
/// stays single and follows `panes.active`.
struct BrowserPaneContainer: View {
    @Bindable var panes: BrowserPanesModel
    /// Face counts for the active pane only — face work is active-pane-only, so inactive
    /// panes show no face badges.
    var activeFaceCount: Int = 0
    var activeFaceGroupCount: Int = 0
    /// Forwarded to each pane so its empty-state "Show Videos & Other Media" updates the
    /// app-wide setting instead of only that pane.
    var selectFileVisibility: ((BrowserFileVisibility) -> Void)? = nil

    @State private var drag = BrowserPaneDragState()

    var body: some View {
        let context = BrowserPaneLayoutContext(
            panes: panes,
            drag: drag,
            activeFaceCount: activeFaceCount,
            activeFaceGroupCount: activeFaceGroupCount,
            selectFileVisibility: selectFileVisibility
        )
        // Always the same view path, so adding the first tab or closing the last extra one
        // keeps the primary's grid (scroll position, snapshot) instead of rebuilding it.
        BrowserPaneNodeView(node: panes.tree.root, context: context)
            .overlay { BrowserPaneDropOverlay(panes: panes, drag: drag) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named(BrowserPaneDragState.space))
    }
}

/// What every node of the recursive layout needs. Passed down rather than read from the
/// environment so the recursion stays explicit.
struct BrowserPaneLayoutContext {
    let panes: BrowserPanesModel
    let drag: BrowserPaneDragState
    let activeFaceCount: Int
    let activeFaceGroupCount: Int
    let selectFileVisibility: ((BrowserFileVisibility) -> Void)?
}

// MARK: - Drag state

/// A tab being dragged, plus the drop target under the cursor. Frames are reported by
/// the groups as they lay out; they're `@ObservationIgnored` so reporting a frame never
/// re-renders the layout.
@Observable
final class BrowserPaneDragState {
    static let space = "browserPaneLayout"

    struct Target: Equatable {
        let groupID: UUID
        let edge: BrowserPaneDropEdge
        /// Tab-bar drops only: insertion index among the group's tabs.
        let tabIndex: Int?
        /// Area to highlight, in the container's coordinate space.
        let highlight: CGRect
        /// Tab-bar drops only: x of the insertion marker.
        let insertionX: CGFloat?
    }

    private(set) var draggedPaneID: BrowserPaneID?
    private(set) var location: CGPoint = .zero
    private(set) var target: Target?

    @ObservationIgnored var contentFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var tabBarFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var tabFrames: [BrowserPaneID: CGRect] = [:]

    /// Share of a pane's width/height, from each edge, that counts as a split zone.
    private let edgeZone: CGFloat = 0.25

    func update(dragging pane: BrowserPaneID, at point: CGPoint, tree: BrowserPaneTree) {
        draggedPaneID = pane
        location = point
        let next = resolveTarget(for: pane, at: point, tree: tree)
        if next != target { target = next }
    }

    /// Ends the drag; returns the target to apply, if any.
    func finish() -> Target? {
        defer {
            draggedPaneID = nil
            target = nil
        }
        return target
    }

    private func resolveTarget(for pane: BrowserPaneID, at point: CGPoint, tree: BrowserPaneTree) -> Target? {
        for group in tree.groups {
            if let bar = tabBarFrames[group.id], bar.contains(point) {
                let tabs = group.paneIDs.compactMap { id in tabFrames[id].map { (id, $0) } }
                let index = tabs.filter { $0.1.midX < point.x }.count
                let insertionX: CGFloat = index < tabs.count
                    ? tabs[index].1.minX
                    : (tabs.last?.1.maxX ?? bar.minX)
                let candidate = Target(
                    groupID: group.id,
                    edge: .center,
                    tabIndex: index,
                    highlight: contentFrames[group.id] ?? bar,
                    insertionX: insertionX
                )
                return isEffective(candidate, pane: pane, tree: tree) ? candidate : nil
            }
            guard let frame = contentFrames[group.id], frame.contains(point), frame.width > 0, frame.height > 0 else {
                continue
            }
            let rx = (point.x - frame.minX) / frame.width
            let ry = (point.y - frame.minY) / frame.height
            let distances: [(BrowserPaneDropEdge, CGFloat)] = [
                (.leading, rx), (.trailing, 1 - rx), (.top, ry), (.bottom, 1 - ry),
            ]
            let nearest = distances.min { $0.1 < $1.1 }!
            let edge = nearest.1 < edgeZone ? nearest.0 : .center
            // Dropping onto the middle of the pane it came from means "never mind".
            if edge == .center && group.paneIDs.contains(pane) { return nil }
            let candidate = Target(
                groupID: group.id,
                edge: edge,
                tabIndex: nil,
                highlight: Self.highlight(for: edge, in: frame),
                insertionX: nil
            )
            return isEffective(candidate, pane: pane, tree: tree) ? candidate : nil
        }
        return nil
    }

    /// Only show targets that would actually change the layout.
    private func isEffective(_ target: Target, pane: BrowserPaneID, tree: BrowserPaneTree) -> Bool {
        var trial = tree
        return trial.move(pane, toGroup: target.groupID, edge: target.edge, tabIndex: target.tabIndex)
    }

    private static func highlight(for edge: BrowserPaneDropEdge, in frame: CGRect) -> CGRect {
        switch edge {
        case .leading: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .trailing: CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        case .center: frame
        }
    }
}

/// Drop preview: the half (or whole pane) the tab will occupy, an insertion marker for
/// tab-bar drops, and a label following the cursor.
private struct BrowserPaneDropOverlay: View {
    let panes: BrowserPanesModel
    let drag: BrowserPaneDragState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let target = drag.target {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: max(target.highlight.width - 8, 0), height: max(target.highlight.height - 8, 0))
                    .offset(x: target.highlight.minX + 4, y: target.highlight.minY + 4)
                if let x = target.insertionX, let bar = drag.tabBarFrames[target.groupID] {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: bar.height - 6)
                        .offset(x: x - 1, y: bar.minY + 3)
                }
            }
            if let id = drag.draggedPaneID, let pane = panes.pane(withID: id) {
                Label(pane.currentFolderName ?? "No Folder", systemImage: "folder")
                    .font(.subheadline)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 3)
                    .fixedSize()
                    .offset(x: drag.location.x + 12, y: drag.location.y + 8)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: drag.target)
    }
}

// MARK: - Layout nodes

private struct BrowserPaneNodeView: View {
    let node: BrowserPaneNode
    let context: BrowserPaneLayoutContext

    var body: some View {
        switch node {
        case .group(let group):
            BrowserPaneGroupView(group: group, context: context)
        case .split(let split):
            BrowserPaneSplitView(split: split, context: context)
        }
    }
}

/// Children along one axis with self-managed dividers, so changing a pane's folder
/// doesn't disturb the divider positions (HSplitView/VSplitView re-derive them from
/// content ideal sizes and jump).
private struct BrowserPaneSplitView: View {
    let split: BrowserPaneSplit
    let context: BrowserPaneLayoutContext

    /// Width/height a divider occupies (and grab area). The visible line is 1px.
    private let dividerThickness: CGFloat = 7
    /// Smallest extent a child can be dragged down to.
    private let minimumExtent: CGFloat = 140

    @State private var dragStartFractions: [Double]?

    private var isHorizontal: Bool { split.axis == .horizontal }

    var body: some View {
        GeometryReader { geo in
            let total = isHorizontal ? geo.size.width : geo.size.height
            let dividers = CGFloat(split.children.count - 1) * dividerThickness
            let usable = max(total - dividers, 1)
            let children = Array(split.children.enumerated())
            let stack = Group {
                ForEach(children, id: \.element.id) { index, child in
                    if index > 0 {
                        divider(after: index - 1, usable: usable)
                    }
                    let extent = usable * split.fractions[index]
                    BrowserPaneNodeView(node: child, context: context)
                        .frame(width: isHorizontal ? extent : nil, height: isHorizontal ? nil : extent)
                }
            }
            Group {
                if isHorizontal {
                    HStack(spacing: 0) { stack }
                } else {
                    VStack(spacing: 0) { stack }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(.named(split.id))
        }
    }

    /// Divider between child `index` and `index + 1`.
    private func divider(after index: Int, usable: CGFloat) -> some View {
        Color.clear
            .frame(width: isHorizontal ? dividerThickness : nil, height: isHorizontal ? nil : dividerThickness)
            .overlay {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: isHorizontal ? 1 : nil, height: isHorizontal ? nil : 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                // Translation in the split's own (fixed) space against the fractions captured
                // at drag start: the divider moves as we drag, so anything relative to the
                // divider itself would feed back and jitter.
                DragGesture(minimumDistance: 0, coordinateSpace: .named(split.id))
                    .onChanged { value in
                        let start = dragStartFractions ?? split.fractions
                        if dragStartFractions == nil { dragStartFractions = start }
                        guard start.count == split.children.count else { return }
                        let pair = start[index] + start[index + 1]
                        let minimum = Double(min(minimumExtent, usable / CGFloat(split.children.count)) / usable)
                        guard pair > 2 * minimum else { return }
                        let delta = Double((isHorizontal ? value.translation.width : value.translation.height) / usable)
                        let first = min(max(start[index] + delta, minimum), pair - minimum)
                        var fractions = start
                        fractions[index] = first
                        fractions[index + 1] = pair - first
                        context.panes.setFractions(fractions, forSplit: split.id)
                    }
                    .onEnded { _ in dragStartFractions = nil }
            )
    }
}

/// One rectangle of the layout: a tab bar over the front pane's grid.
private struct BrowserPaneGroupView: View {
    let group: BrowserPaneGroup
    let context: BrowserPaneLayoutContext

    private var panes: BrowserPanesModel { context.panes }
    private var containsActive: Bool { group.paneIDs.contains(panes.activePaneID) }

    var body: some View {
        VStack(spacing: 0) {
            // The classic browser: no tab bar until there is something to arrange.
            if panes.hasMultiplePanes {
                BrowserPaneTabBar(group: group, context: context)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BrowserPaneDragState.space)) } action: {
                        context.drag.tabBarFrames[group.id] = $0
                    }
                Divider()
            }
            BrowserPaneSlot(
                paneID: group.selectedPaneID,
                // With several rectangles on screen, mark the one that is focused.
                showsActiveChrome: panes.groupCount > 1,
                context: context
            )
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BrowserPaneDragState.space)) } action: {
                context.drag.contentFrames[group.id] = $0
            }
        }
    }
}

private struct BrowserPaneTabBar: View {
    let group: BrowserPaneGroup
    let context: BrowserPaneLayoutContext

    private var panes: BrowserPanesModel { context.panes }
    private var groupIsActive: Bool { group.paneIDs.contains(panes.activePaneID) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(group.paneIDs, id: \.self) { id in
                if let pane = panes.pane(withID: id) {
                    BrowserPaneTab(
                        pane: pane,
                        isFront: id == group.selectedPaneID,
                        isActive: id == panes.activePaneID,
                        canClose: !panes.isPrimary(id),
                        context: context
                    )
                }
            }
            Button {
                panes.addTab(toGroup: group.id)
            } label: {
                Image(systemName: "plus")
                    .font(.caption)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(!panes.canAddPane)
            .help("New Tab")
            .accessibilityLabel("New tab")
            .padding(.horizontal, 4)
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(groupIsActive ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
    }
}

private struct BrowserPaneTab: View {
    let pane: BrowserViewModel
    let isFront: Bool
    let isActive: Bool
    let canClose: Bool
    let context: BrowserPaneLayoutContext

    @State private var isHovered = false

    private var id: BrowserPaneID { BrowserPaneID(pane) }
    private var title: String { pane.currentFolderName ?? "No Folder" }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isFront ? "folder.fill" : "folder")
                .font(.caption)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isFront ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
            if canClose {
                Button {
                    context.panes.close(id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(isHovered || isActive ? 1 : 0)
                .help("Close Tab")
                .accessibilityLabel("Close tab \(title)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(minWidth: 70, idealWidth: 160, maxWidth: 200, maxHeight: .infinity)
        .background {
            if isFront {
                Rectangle().fill(isActive ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
            }
        }
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { context.panes.activate(id) }
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(BrowserPaneDragState.space))
                .onChanged { value in
                    context.drag.update(dragging: id, at: value.location, tree: context.panes.tree)
                }
                .onEnded { _ in
                    if let target = context.drag.finish() {
                        context.panes.move(id, toGroup: target.groupID, edge: target.edge, tabIndex: target.tabIndex)
                    }
                }
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BrowserPaneDragState.space)) } action: {
            context.drag.tabFrames[id] = $0
        }
        .help(pane.currentFolderURL?.path ?? "Empty tab — click a folder in the sidebar to open it here")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab \(title)")
        .accessibilityAddTraits(isFront ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { context.panes.activate(id) }
    }
}

// MARK: - Pane

/// One pane's grid, with focus handling and the active-pane accent.
private struct BrowserPaneSlot: View {
    let paneID: BrowserPaneID
    let showsActiveChrome: Bool
    let context: BrowserPaneLayoutContext

    var body: some View {
        let panes = context.panes
        if let pane = panes.pane(withID: paneID) {
            let isActive = paneID == panes.activePaneID
            BrowserView(
                viewModel: pane,
                faceCount: isActive ? context.activeFaceCount : 0,
                faceGroupCount: isActive ? context.activeFaceGroupCount : 0,
                onFocus: { panes.activate(paneID) },
                isActivePane: isActive,
                // Only the active pane contributes toolbar items, else split view
                // shows them once per pane and overflows into the "»" menu.
                providesToolbar: isActive,
                selectFileVisibility: context.selectFileVisibility
            )
            // Bind identity to the pane instance, not the slot. A group's slot shows
            // different panes over time; without this the AppKit grid controller (whose
            // viewModel is fixed at creation) stays bound to the previous pane and the
            // thumbnails freeze on the old folder.
            .id(paneID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Fallback focus for clicks on empty-pane chrome (where there's no NSCollectionView).
            .contentShape(Rectangle())
            .clipped()
            .simultaneousGesture(TapGesture().onEnded { panes.activate(paneID) })
            .overlay {
                if showsActiveChrome && isActive {
                    Rectangle()
                        .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
