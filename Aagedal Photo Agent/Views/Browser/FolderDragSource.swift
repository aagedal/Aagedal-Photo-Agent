import AppKit
import SwiftUI

/// Outside-app policy for dragging a sidebar folder, kept pure for tests.
nonisolated enum FolderOutsideDragPolicy {
    enum State: Equatable, Sendable {
        case checking
        case clean
        case redacts
        case tooLarge
    }

    static let redactsMessage =
        "Folders with face-blurred photos can't be dragged out as originals. Use Export to share blurred copies."
    static let checkingMessage =
        "Still checking this folder for face blurs. Try the drag again in a moment."
    static let tooLargeMessage =
        "This folder is too large to check for face blurs, so it can't be dragged out of the app. Use Export to share blurred copies."

    static func state(for result: FolderRedactionScanner.Result) -> State {
        switch result {
        case .clean: .clean
        case .redacts: .redacts
        case .incomplete: .tooLarge
        }
    }

    /// The refusal message, or nil when the folder may leave the app.
    static func refusalMessage(for state: State) -> String? {
        switch state {
        case .clean: nil
        case .checking: checkingMessage
        case .redacts: redactsMessage
        case .tooLarge: tooLargeMessage
        }
    }

    /// Whether `photoURL` lies in `folderURL` or one of its subfolders (a folder drag carries
    /// the whole tree).
    static func folder(_ folderURL: URL, contains photoURL: URL) -> Bool {
        let folder = folderURL.standardizedFileURL.path
        let photo = photoURL.standardizedFileURL.path
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return photo.hasPrefix(prefix)
    }
}

/// AppKit drag source for one sidebar folder row. SwiftUI's `.onDrag` cannot tell an in-app drop
/// (moving the folder onto another sidebar folder) from a drop on Finder, Mail or a CMS, and
/// those would receive the photos' original files without their face blurs. This source keeps
/// in-app moves working (the row's `FolderDropDelegate` still receives a file URL) and refuses
/// `.outsideApplication` while the folder holds — or may hold — redacted photos.
@MainActor
final class FolderRowDragSource: NSObject, @preconcurrency NSDraggingSource {
    /// Recent on-disk scan results, so a drag refused while "checking" works on the next try.
    private static var scanCache: [URL: (result: FolderRedactionScanner.Result, date: Date)] = [:]
    private static let scanCacheLifetime: TimeInterval = 60

    weak var anchorView: NSView?
    private(set) var isDragging = false
    private var state: FolderOutsideDragPolicy.State = .checking
    private var outsideWasRefused = false
    private var scanTask: Task<Void, Never>?
    private weak var noticeTarget: BrowserViewModel?

    /// Starts an AppKit drag for `folderURL` from the current left-mouse-dragged event. Called
    /// from the row's SwiftUI drag gesture; repeated calls during one drag are ignored.
    func beginDrag(folderURL: URL, browser: BrowserViewModel) {
        guard !isDragging, let view = anchorView, let event = NSApp.currentEvent,
              event.type == .leftMouseDragged else { return }
        isDragging = true
        outsideWasRefused = false
        noticeTarget = browser
        state = initialState(folderURL: folderURL, browser: browser)
        if state == .checking { startScan(folderURL: folderURL) }

        let item = NSDraggingItem(pasteboardWriter: folderURL as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: folderURL.path)
        icon.size = NSSize(width: 32, height: 32)
        let location = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(x: location.x - 16, y: location.y - 16, width: 32, height: 32),
            contents: icon
        )
        view.beginDraggingSession(with: [item], event: event, source: self)
    }

    private func initialState(folderURL: URL, browser: BrowserViewModel) -> FolderOutsideDragPolicy.State {
        // Loaded photos first: an unsaved in-memory redaction counts too.
        if let current = browser.currentFolderURL,
           current.standardizedFileURL == folderURL.standardizedFileURL
            || FolderOutsideDragPolicy.folder(folderURL, contains: current) {
            if browser.images.contains(where: { RedactionPrivacyGuard.knowledge(for: $0) == .redacts }) {
                return .redacts
            }
        }
        let key = folderURL.standardizedFileURL
        if let cached = Self.scanCache[key], Date().timeIntervalSince(cached.date) < Self.scanCacheLifetime {
            return FolderOutsideDragPolicy.state(for: cached.result)
        }
        return .checking
    }

    private func startScan(folderURL: URL) {
        scanTask?.cancel()
        let key = folderURL.standardizedFileURL
        scanTask = Task { [weak self] in
            let result = await FolderRedactionScanner.scanned(folderURL: key)
            guard !Task.isCancelled else { return }
            Self.scanCache[key] = (result, Date())
            guard let self, self.isDragging, self.state == .checking else { return }
            self.state = FolderOutsideDragPolicy.state(for: result)
        }
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        guard context == .outsideApplication else { return [.move, .copy, .generic] }
        if FolderOutsideDragPolicy.refusalMessage(for: state) != nil {
            outsideWasRefused = true
            return []
        }
        return .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        if operation.isEmpty, outsideWasRefused,
           let message = FolderOutsideDragPolicy.refusalMessage(for: state),
           !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(screenPoint) }) {
            noticeTarget?.fileOperationNotice = FileOperationNotice(message: message, systemImage: "eye.slash")
        }
        isDragging = false
        outsideWasRefused = false
        // Keep a running scan: its result is cached for the next drag.
        scanTask = nil
    }
}

/// Zero-size, click-through view the drag source starts its AppKit session from.
struct FolderDragAnchor: NSViewRepresentable {
    let source: FolderRowDragSource

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        source.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        source.anchorView = nsView
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
