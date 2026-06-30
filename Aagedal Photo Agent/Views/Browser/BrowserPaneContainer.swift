import SwiftUI

/// Hosts the thumbnail grid in one of four layouts (single / side-by-side /
/// top-bottom / tabs). Only the grid area splits; everything else stays single
/// and follows `panes.active`.
struct BrowserPaneContainer: View {
    @Bindable var panes: BrowserPanesModel
    /// Face counts for the active pane only — face work is active-pane-only, so the
    /// inactive pane shows no face badges.
    var activeFaceCount: Int = 0
    var activeFaceGroupCount: Int = 0

    /// Width/height the divider occupies (and grab area). The visible line is 1px.
    private let dividerThickness: CGFloat = 7
    private let splitSpace = "browserSplit"

    var body: some View {
        switch panes.layout {
        case .single:
            paneView(panes.safeActiveIndex, showActiveChrome: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .splitHorizontal:
            splitContainer(axis: .horizontal)
        case .splitVertical:
            splitContainer(axis: .vertical)
        case .tabs:
            VStack(spacing: 0) {
                tabBar
                Divider()
                paneView(panes.safeActiveIndex, showActiveChrome: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Explicit split with a self-managed divider fraction, so changing a pane's folder
    /// doesn't disturb the user's divider position (which HSplitView/VSplitView do).
    @ViewBuilder
    private func splitContainer(axis: Axis) -> some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            let usable = max(total - dividerThickness, 1)
            let firstExtent = usable * panes.splitFraction
            let secondExtent = usable - firstExtent

            let layoutContent = Group {
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        paneView(0, showActiveChrome: true).frame(width: firstExtent)
                        splitDivider(axis: axis, usable: usable)
                        paneView(1, showActiveChrome: true).frame(width: secondExtent)
                    }
                } else {
                    VStack(spacing: 0) {
                        paneView(0, showActiveChrome: true).frame(height: firstExtent)
                        splitDivider(axis: axis, usable: usable)
                        paneView(1, showActiveChrome: true).frame(height: secondExtent)
                    }
                }
            }
            layoutContent
                .frame(width: geo.size.width, height: geo.size.height)
                .coordinateSpace(name: splitSpace)
        }
    }

    private func splitDivider(axis: Axis, usable: CGFloat) -> some View {
        // 1px visible line inside a wider transparent grab area.
        Color.clear
            .frame(
                width: axis == .horizontal ? dividerThickness : nil,
                height: axis == .vertical ? dividerThickness : nil
            )
            .overlay {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(
                        width: axis == .horizontal ? 1 : nil,
                        height: axis == .vertical ? 1 : nil
                    )
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                // Read the absolute cursor position in the (fixed) container space rather
                // than translation — the divider moves as we drag, so translation would
                // feed back and jitter. Position-based tracking is stable to the clamp.
                DragGesture(minimumDistance: 0, coordinateSpace: .named(splitSpace))
                    .onChanged { value in
                        let pos = axis == .horizontal ? value.location.x : value.location.y
                        panes.splitFraction = (pos - dividerThickness / 2) / usable
                    }
            )
    }

    @ViewBuilder
    private func paneView(_ index: Int, showActiveChrome: Bool) -> some View {
        if index < panes.panes.count {
            let pane = panes.panes[index]
            let isActive = index == panes.activePaneIndex
            BrowserView(
                viewModel: pane,
                faceCount: isActive ? activeFaceCount : 0,
                faceGroupCount: isActive ? activeFaceGroupCount : 0,
                onFocus: { panes.activePaneIndex = index },
                // Only the active pane contributes toolbar items, else split view
                // shows them twice and overflows into the "»" menu.
                providesToolbar: isActive
            )
            // Bind identity to the pane instance, not the slot. In tabs mode one slot
            // shows different panes over time; without this the AppKit grid controller
            // (whose viewModel is fixed at creation) stays bound to the previous pane
            // and the thumbnails freeze on the old folder.
            .id(ObjectIdentifier(pane))
            // Sizing is set by the caller per layout (explicit width/height in split,
            // flexible in single/tabs), so no intrinsic frame here.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Fallback focus for clicks on empty-pane chrome (where there's no NSCollectionView).
            .contentShape(Rectangle())
            .clipped()
            .simultaneousGesture(TapGesture().onEnded { panes.activePaneIndex = index })
            .overlay(alignment: .top) {
                if showActiveChrome && isActive {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(panes.panes.enumerated()), id: \.offset) { index, pane in
                let isActive = index == panes.activePaneIndex
                Button {
                    panes.activePaneIndex = index
                } label: {
                    Text(pane.currentFolderName ?? "Untitled")
                        .lineLimit(1)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                }
                .buttonStyle(.plain)
                if index < panes.panes.count - 1 {
                    Divider().frame(height: 18)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
