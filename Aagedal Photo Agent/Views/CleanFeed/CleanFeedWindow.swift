import AppKit
import SwiftUI

/// Borderless output window for the clean feed. Never becomes key/main so it can't
/// steal focus or keyboard input from the editing window on the primary display.
final class CleanFeedNSWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Stable storage for the feed window across SwiftUI view updates. A reference type
/// held in `@State` keeps the same instance, so the screen-parameters observer (which
/// captures it once) always sees the current window.
private final class FeedWindowHolder {
    var window: CleanFeedNSWindow?
}

/// Opens/closes the clean-feed window on the chosen secondary display in response to
/// `controller.isEnabled`, and keeps it positioned across display hot-plug.
struct CleanFeedPresenter: ViewModifier {
    @Bindable var controller: CleanFeedController
    let browserViewModel: BrowserViewModel

    @State private var holder = FeedWindowHolder()
    @State private var screenObserver: NSObjectProtocol?

    func body(content: Content) -> some View {
        content
            .onChange(of: controller.isEnabled) { _, isOn in
                if isOn { openFeed() } else { closeFeed() }
            }
            .onChange(of: controller.targetDisplayID) { _, _ in
                // User picked a different display while the feed is running — move it.
                guard controller.isEnabled, let screen = controller.targetScreen else { return }
                if holder.window == nil {
                    openFeed()
                } else {
                    holder.window?.setFrame(screen.frame, display: true)
                }
            }
            .onAppear { installScreenObserver() }
            .onDisappear {
                removeScreenObserver()
                closeFeed()
            }
    }

    private func openFeed() {
        guard holder.window == nil else { return }
        guard let screen = controller.targetScreen else {
            controller.isEnabled = false
            return
        }
        // Remember which physical display we landed on (only when not already chosen,
        // to avoid re-triggering the targetDisplayID observer).
        if controller.targetDisplayID != screen.displayID {
            controller.targetDisplayID = screen.displayID
        }

        let window = CleanFeedNSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Above the menu bar so the feed fully covers the secondary display (the
        // menu bar would otherwise show through on that screen). Safe because the
        // window can't become key/main and ignores mouse events, and it only
        // occupies the chosen external display — not the editor's screen.
        window.level = .mainMenu + 1
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .ignoresCycle, .stationary]
        window.hasShadow = false
        window.ignoresMouseEvents = true  // passive output — no interaction

        let hostingView = NSHostingView(
            rootView: CleanFeedContentView(controller: controller, browserViewModel: browserViewModel)
        )
        hostingView.wantsLayer = true
        window.contentView = hostingView
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()  // show without taking key/main from the editor

        holder.window = window
    }

    private func closeFeed() {
        holder.window?.orderOut(nil)
        holder.window = nil
    }

    private func installScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard controller.isEnabled else { return }
                if let screen = controller.targetScreen {
                    holder.window?.setFrame(screen.frame, display: true)
                } else {
                    // Target display vanished — controller.refreshDisplays() will also
                    // flip isEnabled off, which closes the window via onChange.
                    closeFeed()
                }
            }
        }
    }

    private func removeScreenObserver() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }
}

extension View {
    func cleanFeedPresenter(
        controller: CleanFeedController,
        browserViewModel: BrowserViewModel
    ) -> some View {
        modifier(CleanFeedPresenter(controller: controller, browserViewModel: browserViewModel))
    }
}
