import AppKit
import SwiftUI

/// Admission for application-wide local event monitors owned by one visible workspace.
/// A background workspace cannot consume Settings, another window, or a sheet's input.
@MainActor
final class WorkspaceEventWindowReference {
    weak var window: NSWindow?

    func ownsEvent(in candidate: NSWindow?, modalWindow: NSWindow? = NSApp.modalWindow) -> Bool {
        guard let window, candidate === window, window.isKeyWindow else { return false }
        return modalWindow == nil && window.attachedSheet == nil && window.sheetParent == nil
    }
}

struct WorkspaceEventWindowReader: NSViewRepresentable {
    let reference: WorkspaceEventWindowReference

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.reference = reference
        return view
    }

    func updateNSView(_ view: WindowReaderView, context: Context) {
        view.reference = reference
        reference.window = view.window
    }

    final class WindowReaderView: NSView {
        var reference: WorkspaceEventWindowReference?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
        }
    }
}
