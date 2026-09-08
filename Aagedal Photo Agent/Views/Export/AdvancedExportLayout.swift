import AppKit
import SwiftUI

/// Size the sheet in points using its own display's usable area. Comparison panes
/// retain a readable width and scroll horizontally when that display is narrow.
nonisolated struct AdvancedExportLayout: Equatable {
    let size: CGSize
    var comparisonWidth: CGFloat { max(780, size.width - 301) }

    init(visibleSize: CGSize?) {
        guard let visibleSize,
              visibleSize.width.isFinite, visibleSize.height.isFinite,
              visibleSize.width > 0, visibleSize.height > 0 else {
            size = CGSize(width: 1060, height: 720)
            return
        }
        size = CGSize(
            width: min(1320, visibleSize.width * 0.9),
            height: min(1000, visibleSize.height * 0.9)
        )
    }
}

/// A sheet may be on a different display from the application's main window.
/// Observe the actual hosting window, including attachment and display changes.
struct AdvancedExportDisplayReader: NSViewRepresentable {
    let onChange: (CGSize?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onChange = onChange
    }

    static func dismantleNSView(_ nsView: ReaderView, coordinator: ()) {
        nsView.stopObserving()
        nsView.onChange = nil
    }

    final class ReaderView: NSView {
        var onChange: ((CGSize?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            for observedWindow in [window, window.sheetParent].compactMap({ $0 }) {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(displayChanged),
                    name: NSWindow.didChangeScreenNotification, object: observedWindow
                )
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(displayChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil
            )
            displayChanged()
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func displayChanged() {
            // Window attachment can occur during a SwiftUI update. Publish on the
            // next turn, reading the latest window rather than a stale notification.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let screen = window.screen ?? window.sheetParent?.screen
                self.onChange?(screen?.visibleFrame.size
                    ?? window.sheetParent?.contentLayoutRect.size)
            }
        }
    }
}
