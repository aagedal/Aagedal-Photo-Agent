import Foundation

/// Layout of the center thumbnail area. Only the grid splits — the sidebar,
/// face bar, metadata panel, and edit view stay single and follow the active pane.
enum BrowserPaneLayout: String, CaseIterable {
    /// One pane (the classic single-folder browser).
    case single
    /// Two panes side by side (vertical divider between them).
    case splitHorizontal
    /// Two panes stacked top/bottom (horizontal divider between them).
    case splitVertical
    /// Two folders as tabs; one visible at a time.
    case tabs

    var isSplit: Bool { self == .splitHorizontal || self == .splitVertical }
    /// True when more than one pane is materialized (split or tabs).
    var usesSecondPane: Bool { self != .single }
}

/// Owns the (up to two) `BrowserViewModel` panes that share the center thumbnail
/// area, plus which one is active. The active pane drives every single consumer —
/// sidebar folder loads, the metadata panel, the face bar, and the edit view.
///
/// Both panes share one `ThumbnailService` (decode gate + NSCache) and one
/// `FullScreenImageCache` so two folders can't double the concurrent-decode load
/// or the IOSurface memory pressure.
@Observable
final class BrowserPanesModel {
    /// 1 element in single mode; lazily grows to 2 the first time the user splits.
    private(set) var panes: [BrowserViewModel]
    var activePaneIndex: Int = 0
    var layout: BrowserPaneLayout {
        didSet {
            guard layout != oldValue else { return }
            UserDefaults.standard.set(layout.rawValue, forKey: UserDefaultsKeys.browserPaneLayout)
        }
    }

    /// Fraction of the split occupied by the first pane (0…1). Managed explicitly —
    /// HSplitView/VSplitView re-derive the divider from content ideal sizes and so jump
    /// when a pane's folder changes. Clamped on write; persisted across launches.
    var splitFraction: Double {
        didSet {
            let clamped = min(max(splitFraction, 0.15), 0.85)
            if clamped != splitFraction { splitFraction = clamped; return }
            UserDefaults.standard.set(splitFraction, forKey: UserDefaultsKeys.browserPaneSplitFraction)
        }
    }

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
        // Always launch in single mode — a saved split would point its second pane at
        // a folder we haven't reloaded yet, and the user can re-split in one click.
        self.layout = .single
        let storedFraction = UserDefaults.standard.double(forKey: UserDefaultsKeys.browserPaneSplitFraction)
        self.splitFraction = (storedFraction >= 0.15 && storedFraction <= 0.85) ? storedFraction : 0.5
    }

    /// The pane every single consumer (sidebar, metadata, faces, edit) follows.
    var active: BrowserViewModel {
        panes[min(activePaneIndex, panes.count - 1)]
    }

    /// Clamped active index, safe to use as a subscript while panes mutate.
    var safeActiveIndex: Int { min(activePaneIndex, panes.count - 1) }

    /// Materialize the second pane on demand, sharing the heavy services.
    @discardableResult
    private func ensureSecondPane() -> BrowserViewModel {
        if panes.count < 2 {
            let pane = BrowserViewModel(
                thumbnailService: sharedThumbnailService,
                fullScreenImageCache: sharedFullScreenImageCache
            )
            configurePane?(pane)
            panes.append(pane)
        }
        return panes[1]
    }

    /// Switch layout, creating the second pane first when needed.
    func setLayout(_ newLayout: BrowserPaneLayout) {
        if newLayout.usesSecondPane {
            ensureSecondPane()
        } else {
            // Collapsing to single: keep showing whatever pane was active.
            if safeActiveIndex == 1 { activePaneIndex = 1 }
        }
        layout = newLayout
    }

    /// Toggle between single and the given split orientation (or tabs).
    func toggle(_ splitLayout: BrowserPaneLayout) {
        setLayout(layout == splitLayout ? .single : splitLayout)
    }
}
