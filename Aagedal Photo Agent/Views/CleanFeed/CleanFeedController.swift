import AppKit
import CoreImage
import Metal
import os

/// Immutable handoff from the interactive comparison workspace to the passive Clean Feed.
/// The workspace remains the sole owner of comparison coordination; Clean Feed only presents
/// the latest completed session and bitmaps on the selected secondary display.
struct CleanFeedComparisonPresentation {
    let session: ComparisonSession
    let images: [ComparisonPane: CGImage]

    var containsHDR: Bool {
        ComparisonPane.allCases.contains {
            session[$0].source?.dynamicRange == .hdr
        }
    }
}

/// Pure layout math shared by the Metal presenter and unit tests. Rectangles use the same
/// top-left coordinate convention as ViewportState; CIRenderDestination performs the final flip.
nonisolated enum CleanFeedComparisonGeometry {
    static func paneRects(
        layout: ComparisonLayout,
        focusedPane: ComparisonPane,
        drawableSize: CGSize,
        gap: CGFloat = 2
    ) -> [(ComparisonPane, CGRect)] {
        switch layout {
        case .sideBySide:
            let safeGap = min(max(gap, 0), drawableSize.width)
            let availableWidth = max(drawableSize.width - safeGap, 0)
            let firstWidth = floor(availableWidth / 2)
            return [
                (.left, CGRect(x: 0, y: 0, width: firstWidth, height: drawableSize.height)),
                (.right, CGRect(
                    x: firstWidth + safeGap,
                    y: 0,
                    width: availableWidth - firstWidth,
                    height: drawableSize.height
                ))
            ]
        case .stacked:
            let safeGap = min(max(gap, 0), drawableSize.height)
            let availableHeight = max(drawableSize.height - safeGap, 0)
            let firstHeight = floor(availableHeight / 2)
            return [
                (.left, CGRect(x: 0, y: 0, width: drawableSize.width, height: firstHeight)),
                (.right, CGRect(
                    x: 0,
                    y: firstHeight + safeGap,
                    width: drawableSize.width,
                    height: availableHeight - firstHeight
                ))
            ]
        case .singlePane:
            return [(focusedPane, CGRect(origin: .zero, size: drawableSize))]
        }
    }
}

nonisolated private let cleanFeedLog = Logger(
    subsystem: "com.aagedal.photo-agent", category: "CleanFeed"
)

/// Non-isolated callback box. The clean-feed render view registers its MTKView
/// redraw / continuous-render hooks here; the (non-isolated) Metal edit pipeline
/// fires `redraw` from `updateParams` without crossing actor boundaries.
final class CleanFeedHooks: @unchecked Sendable {
    var redraw: (() -> Void)?
    var setContinuous: ((Bool) -> Void)?
}

/// Owns the state and GPU resources for the optional "clean feed" window shown on a
/// secondary display: a chrome-free, aspect-fit view of the current image that tracks
/// edits live. Renders in EDR when `isHDR` is set (native-HDR files or HDR edit mode).
///
/// Singleton so the `View` menu (built in the `App` scene) and `ContentView` share one
/// instance without notification plumbing, matching the app's other shared services.
@MainActor
@Observable
final class CleanFeedController {
    static let shared = CleanFeedController()

    /// Menu-driven on/off. Forced back off if no external display is available.
    var isEnabled = false {
        didSet {
            if isEnabled && !hasExternalDisplay {
                isEnabled = false  // assigning inside didSet does not re-trigger didSet
            }
        }
    }

    /// Persisted target display. `nil` → first available external screen.
    var targetDisplayID: CGDirectDisplayID? {
        didSet { persistTargetDisplay() }
    }

    /// Observable trigger so SwiftUI menus/views re-evaluate on monitor hot-plug.
    /// Updated from the screen-parameters notification.
    private(set) var externalDisplayCount: Int = 0

    // MARK: - Content state (read by the render view)

    /// Still image to display when NOT driving the live edit pipeline (browse/cull
    /// mode, or the "before"/muted states in the editor). Already edited + oriented.
    var feedImage: CIImage?
    var isHDR = false

    /// When true the feed renders via `feedPipeline` (shares the editor's source
    /// texture + params) instead of `feedImage`. Set by the edit workspace.
    var useEditPipeline = false

    /// Confirmed crop applied to the live edit feed (normalized [0,1] display-oriented
    /// edges + straighten angle), with the source image size for aspect math. `nil` means
    /// no crop — the feed shows the full image. Pushed by the edit workspace only when the
    /// crop is committed (frozen while the crop tool is active).
    struct FeedCrop: Equatable {
        var left: Double
        var top: Double
        var right: Double
        var bottom: Double
        var angle: Double
        var imageSize: CGSize

        /// Whether this differs from the full-frame, unrotated default.
        var isActive: Bool {
            let eps = 0.0001
            return abs(left) > eps || abs(top) > eps
                || abs(right - 1) > eps || abs(bottom - 1) > eps
                || abs(angle) > eps
        }
    }
    var feedCrop: FeedCrop?

    /// Live comparison snapshot supplied by ComparisonWorkspaceView. This takes precedence over
    /// browse and Develop content while present, then cleanly falls back when Compare closes.
    private(set) var comparisonPresentation: CleanFeedComparisonPresentation?

    /// Clean Feed may use a layout suited to the audience display without changing the layout of
    /// the interactive comparison workspace on the main display.
    var comparisonLayout: ComparisonLayout = .sideBySide {
        didSet {
            UserDefaults.standard.set(
                comparisonLayout.rawValue,
                forKey: UserDefaultsKeys.cleanFeedComparisonLayout
            )
            requestFeedRedraw()
        }
    }

    /// True while the edit workspace is on screen and owns the feed content. While
    /// true, the browse-mode loader stands down to avoid racing the editor's pushes.
    var editModeActive = false

    /// Dedicated compute pipeline for the feed. Shares the edit pipeline's source
    /// texture by reference (wired via `MetalEditPipeline.mirror`) but keeps its own
    /// viewport so it can letterbox for the secondary display's aspect ratio.
    let feedPipeline: MetalEditPipeline?

    /// Redraw / continuous-render hooks, registered by the render view's coordinator.
    let hooks = CleanFeedHooks()

    private init() {
        let device = MetalPreviewView.Coordinator.device
        let queue = MetalPreviewView.Coordinator.commandQueue
        self.feedPipeline = MetalEditPipeline(device: device, commandQueue: queue)
        loadTargetDisplay()
        loadComparisonLayout()
        refreshDisplays()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in CleanFeedController.shared.refreshDisplays() }
        }
    }

    // MARK: - Displays

    /// External (non-main) screens available as feed targets.
    var availableExternalScreens: [NSScreen] {
        let main = NSScreen.main
        return NSScreen.screens.filter { $0 != main }
    }

    var hasExternalDisplay: Bool { externalDisplayCount > 0 }

    /// A selectable clean-feed target for the View menu.
    struct DisplayOption: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
    }

    /// All displays available for clean output (every connected display except the
    /// one hosting the active window), with disambiguated, human-readable names.
    /// Drives the View-menu display list so any number of monitors is supported.
    var feedDisplayOptions: [DisplayOption] {
        let screens = availableExternalScreens
        // Count base names so duplicates (identical monitor models) can be disambiguated.
        var nameCounts: [String: Int] = [:]
        for screen in screens {
            let base = screen.localizedName.isEmpty ? "Display" : screen.localizedName
            nameCounts[base, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        return screens.enumerated().compactMap { index, screen in
            guard let id = screen.displayID else { return nil }
            let base = screen.localizedName.isEmpty ? "Display \(index + 1)" : screen.localizedName
            var name = base
            if (nameCounts[base] ?? 0) > 1 {
                let w = Int(screen.frame.width), h = Int(screen.frame.height)
                let duplicateIndex = (seen[base] ?? 0) + 1
                seen[base] = duplicateIndex
                name = "\(base) (\(w)×\(h) #\(duplicateIndex))"
            }
            return DisplayOption(id: id, name: name)
        }
    }

    /// The display the feed currently targets (resolved saved-or-first), as an ID —
    /// `nil` when the feed is off. Used as the View-menu radio selection.
    var activeDisplaySelection: CGDirectDisplayID? {
        isEnabled ? targetScreen?.displayID : nil
    }

    /// Where the feed should appear: the saved display if still present, else the
    /// first available external screen.
    var targetScreen: NSScreen? {
        if let id = targetDisplayID,
           let match = availableExternalScreens.first(where: { $0.displayID == id }) {
            return match
        }
        return availableExternalScreens.first
    }

    /// Recompute display availability and turn the feed off if its display vanished.
    func refreshDisplays() {
        externalDisplayCount = availableExternalScreens.count
        if isEnabled && !hasExternalDisplay {
            cleanFeedLog.info("External display disconnected — disabling clean feed")
            isEnabled = false
        }
    }

    // MARK: - Redraw

    func requestFeedRedraw() { hooks.redraw?() }
    func setFeedContinuousRendering(_ on: Bool) { hooks.setContinuous?(on) }

    var isPresentingComparison: Bool { comparisonPresentation != nil }

    func presentComparison(
        session: ComparisonSession,
        images: [ComparisonPane: CGImage]
    ) {
        comparisonPresentation = CleanFeedComparisonPresentation(
            session: session,
            images: images
        )
        requestFeedRedraw()
    }

    /// Avoids an outgoing workspace clearing a newer comparison during rapid transitions.
    func clearComparison(sessionID: UUID? = nil) {
        if let sessionID,
           comparisonPresentation?.session.id != sessionID {
            return
        }
        comparisonPresentation = nil
        requestFeedRedraw()
    }

    // MARK: - Selection

    /// Send the clean feed to a specific display (and enable it). Picking a display
    /// while the feed is already running moves the window there (handled by the presenter
    /// observing `targetDisplayID`).
    func selectDisplay(id: CGDirectDisplayID) {
        targetDisplayID = id
        if !isEnabled { isEnabled = true }
    }

    /// Toggle the feed on (to the current/last-used display) or off — bound to ⌘⇧F.
    func toggleEnabled() {
        if isEnabled {
            isEnabled = false
        } else if hasExternalDisplay {
            isEnabled = true
        }
    }

    // MARK: - Persistence

    private func loadTargetDisplay() {
        let raw = UserDefaults.standard.integer(forKey: UserDefaultsKeys.cleanFeedDisplayID)
        targetDisplayID = raw == 0 ? nil : CGDirectDisplayID(UInt32(truncatingIfNeeded: raw))
    }

    private func persistTargetDisplay() {
        if let id = targetDisplayID {
            UserDefaults.standard.set(Int(id), forKey: UserDefaultsKeys.cleanFeedDisplayID)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.cleanFeedDisplayID)
        }
    }

    private func loadComparisonLayout() {
        guard let raw = UserDefaults.standard.string(
            forKey: UserDefaultsKeys.cleanFeedComparisonLayout
        ), let saved = ComparisonLayout(rawValue: raw) else { return }
        comparisonLayout = saved
    }
}

extension NSScreen {
    /// The CoreGraphics display ID for this screen (stable across launches for a
    /// given physical display), used to persist the chosen clean-feed monitor.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
