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

    var body: some View {
        switch panes.layout {
        case .single:
            paneView(panes.safeActiveIndex, showActiveChrome: false)
        case .splitHorizontal:
            HSplitView {
                paneView(0, showActiveChrome: true)
                paneView(1, showActiveChrome: true)
            }
        case .splitVertical:
            VSplitView {
                paneView(0, showActiveChrome: true)
                paneView(1, showActiveChrome: true)
            }
        case .tabs:
            VStack(spacing: 0) {
                tabBar
                Divider()
                paneView(panes.safeActiveIndex, showActiveChrome: false)
            }
        }
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
            .frame(minWidth: 300, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
            // Fallback focus for clicks on empty-pane chrome (where there's no NSCollectionView).
            .contentShape(Rectangle())
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
