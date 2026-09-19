import AppKit
import Observation
import SwiftUI

/// Free text with the same live suggestions as Person Shown. The child panel
/// cannot take keyboard focus, so choosing a row never races a blur commit.
final class FaceGroupNameTextField: NSTextField, NSTextFieldDelegate {
    var candidates: [String] = []
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var visibleSuggestions: [ApprovedListSuggestion] = []
    private(set) var highlightedIndex: Int?
    private var suggestionPanel: NameSuggestionPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var dismissalObservers: [NSObjectProtocol] = []
    private var candidateObservationGeneration = 0
    private var suppressCandidateRefresh = false
    var suggestionsAreVisible: Bool { suggestionPanel?.isVisible == true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        bezelStyle = .roundedBezel
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.usesSingleLineMode = true
        setAccessibilityLabel("Face group name")
        setAccessibilityHelp("Type a name. Use Up and Down to select a suggestion, Return to save, and Escape to dismiss suggestions or cancel.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopObservingCandidates()
        dismissSuggestions()
        super.viewWillMove(toWindow: newWindow)
    }

    func controlTextDidChange(_ notification: Notification) {
        suppressCandidateRefresh = false
        guard !((currentEditor() as? NSTextView)?.hasMarkedText() ?? false) else {
            dismissSuggestions()
            return
        }
        refreshSuggestions()
    }

    /// AppKit doesn't subscribe to Observable services automatically. Keep the
    /// active edit in sync when the initial disk load or a list import completes.
    func observeCandidates(_ provider: @escaping @MainActor () -> [String]) {
        candidateObservationGeneration &+= 1
        suppressCandidateRefresh = false
        trackCandidates(provider, generation: candidateObservationGeneration)
    }

    func stopObservingCandidates() {
        candidateObservationGeneration &+= 1
    }

    private func trackCandidates(_ provider: @escaping @MainActor () -> [String], generation: Int) {
        guard candidateObservationGeneration == generation else { return }
        candidates = withObservationTracking {
            provider()
        } onChange: { [weak self] in
            // Observation fires before the new value is installed. Read it on
            // the next main-queue turn, and discard callbacks from older edits.
            DispatchQueue.main.async { [weak self] in
                self?.trackCandidates(provider, generation: generation)
            }
        }
        if !suppressCandidateRefresh,
           !((currentEditor() as? NSTextView)?.hasMarkedText() ?? false) {
            refreshSuggestions()
        }
    }

    func refreshSuggestions() {
        let text = currentEditor()?.string ?? stringValue
        var seen = Set<String>()
        let uniqueNames = candidates.compactMap { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
        visibleSuggestions = ApprovedListService.suggestions(prefix: text, in: uniqueNames)
        // A previous hover/arrow choice must never select a different row after typing.
        highlightedIndex = nil
        updateSuggestionPanel()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        stopObservingCandidates()
        dismissSuggestions()
        onCommit?(stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let name = highlightedIndex.flatMap { index in
                visibleSuggestions.indices.contains(index) ? visibleSuggestions[index].canonical : nil
            } ?? textView.string
            dismissSuggestions()
            onCommit?(name)
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            if visibleSuggestions.isEmpty { refreshSuggestions() }
            guard !visibleSuggestions.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            if let current = highlightedIndex {
                let next = current + delta
                highlightedIndex = next < 0 ? nil : (next >= visibleSuggestions.count ? 0 : next)
            } else {
                highlightedIndex = delta > 0 ? 0 : visibleSuggestions.count - 1
            }
            updateSuggestionPanel()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if !visibleSuggestions.isEmpty {
                suppressCandidateRefresh = true
                dismissSuggestions()
            } else {
                onCancel?()
            }
            return true
        default:
            return false
        }
    }

    func commitSuggestion(_ suggestion: ApprovedListSuggestion) {
        guard visibleSuggestions.contains(suggestion) else { return }
        dismissSuggestions()
        onCommit?(suggestion.canonical)
    }

    func dismissSuggestions() {
        visibleSuggestions = []
        highlightedIndex = nil
        dismissalObservers.forEach(NotificationCenter.default.removeObserver)
        dismissalObservers.removeAll()
        if let panel = suggestionPanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        suggestionPanel = nil
        hostingView = nil
    }

    private func updateSuggestionPanel() {
        guard !visibleSuggestions.isEmpty, let window, currentEditor() != nil else {
            dismissSuggestions()
            return
        }
        let content = AnyView(TypeaheadSuggestionsList(
            suggestions: visibleSuggestions,
            highlightedIndex: Binding(
                get: { [weak self] in self?.highlightedIndex },
                set: { [weak self] index in
                    guard let self, self.highlightedIndex != index else { return }
                    self.highlightedIndex = index
                    self.updateSuggestionPanel()
                }
            ),
            onSelect: { [weak self] in self?.commitSuggestion($0) }
        )
        .frame(width: 280)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8)))
        let panel: NameSuggestionPanel
        let host: NSHostingView<AnyView>
        if let existing = suggestionPanel, let existingHost = hostingView {
            panel = existing
            host = existingHost
            host.rootView = content
        } else {
            panel = NameSuggestionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            host = NSHostingView(rootView: content)
            panel.contentView = host
            suggestionPanel = panel
            hostingView = host
            window.addChildWindow(panel, ordered: .above)
            // A card can move inside the scrolling collection without losing
            // field focus. Don't leave its suggestions at the old screen position.
            observeDismissal(NSWindow.didResignKeyNotification, object: window)
            observeDismissal(NSWindow.didResizeNotification, object: window)
            if let clipView = enclosingScrollView?.contentView {
                observeDismissal(NSView.boundsDidChangeNotification, object: clipView)
            }
        }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let height = host.fittingSize.height
        let screen = window.screen?.visibleFrame ?? anchor.insetBy(dx: -500, dy: -500)
        let x = min(max(anchor.minX, screen.minX), screen.maxX - 280)
        let below = anchor.minY - height - 4
        let y = below >= screen.minY ? below : min(anchor.maxY + 4, screen.maxY - height)
        panel.setFrame(NSRect(x: x, y: y, width: 280, height: height), display: true)
        panel.orderFront(nil)
    }

    private func observeDismissal(_ name: Notification.Name, object: AnyObject) {
        dismissalObservers.append(NotificationCenter.default.addObserver(
            forName: name, object: object, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suppressCandidateRefresh = true
                self?.dismissSuggestions()
            }
        })
    }
}

private final class NameSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
