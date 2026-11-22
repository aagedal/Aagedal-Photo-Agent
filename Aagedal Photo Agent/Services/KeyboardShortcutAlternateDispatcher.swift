import AppKit
import os

private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "KeyboardShortcutAlternateDispatcher")

/// A menu item shows one key equivalent, so a menu command's alternate shortcut runs the
/// item whose primary shortcut the menu shows. Running the real item keeps its enabled state
/// and action identical to choosing it from the menu. A primary that menus cannot match
/// (Shift with a digit or punctuation) runs the same way.
@MainActor
enum KeyboardShortcutAlternateDispatcher {
    private static var monitor: Any?

    /// Set while the shortcut editor records a key, so the press is recorded instead of run.
    static var isSuspended = false

    /// Develop workspaces asked whether they take a hold or paste gesture (⌘D, ⌥V) for a key
    /// event. Wherever none does, those chords run their command like any other alternate.
    private static var developGestureOwners: [UUID: (NSEvent, KeyboardShortcutChord) -> Bool] = [:]

    static func registerDevelopGestureOwner(_ id: UUID, owns: @escaping (NSEvent, KeyboardShortcutChord) -> Bool) {
        developGestureOwners[id] = owns
    }

    static func unregisterDevelopGestureOwner(_ id: UUID) {
        developGestureOwners[id] = nil
    }

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { perform(event) } ? nil : event
        }
    }

    /// Runs the menu item for an alternate shortcut. Returns whether the event was consumed.
    static func perform(_ event: NSEvent, profile: KeyboardShortcutProfile? = nil, menu: NSMenu? = NSApp.mainMenu) -> Bool {
        // Menus stay inactive behind a modal panel; so do their alternates.
        guard !isSuspended, NSApp.modalWindow == nil, let chord = KeyboardShortcutChord(event: event) else { return false }
        let profile = profile ?? KeyboardShortcutProfileRegistry.shared.selectedProfile
        guard let command = profile.command(for: chord), !command.isCulling,
              let primary = profile.menuChord(for: command), primary != chord || !chord.menuCanMatch,
              !(command.hasDevelopContextOverride(for: chord) && developGestureOwners.values.contains { $0(event, chord) }),
              !keyboardTextInputState(in: event.window).imeHasMarkedText,
              let menu, let (owner, index) = item(for: command, matching: primary, in: menu) else { return false }
        // A disabled item leaves the event to AppKit, which offers it to the key window
        // itself; asking the window here as well would run its key equivalents twice.
        owner.update()
        guard owner.items[index].isEnabled else { return false }
        // AppKit offers a menu key to the key window (a sheet, a button's key equivalent)
        // before the menu; an alternate takes the same order.
        if let window = event.window, window.performKeyEquivalent(with: event) { return true }
        if event.isARepeat { return true }
        owner.performActionForItem(at: index)
        return true
    }

    /// The item for `command` that shows `chord`. A system item can show the same chord ahead
    /// of the command's own, so when several do, the title decides. SwiftUI menu items carry
    /// no tag to match on, so a title that no longer names its command is logged, and the
    /// shortcut does nothing rather than run the system item.
    static func item(
        for command: KeyboardShortcutCommand,
        matching chord: KeyboardShortcutChord,
        in menu: NSMenu
    ) -> (NSMenu, Int)? {
        var search = ItemSearch(command: command, chord: chord)
        if let titled = search.titledItem(in: menu) { return titled }
        if search.matches > 1 {
            logger.fault("No menu item titled “\(command.displayName, privacy: .public)” shows its shortcut \(chord.displayName, privacy: .public); its alternate was not run.")
            return nil
        }
        return search.onlyMatch
    }

    /// One depth-first walk that stops at the first item titled for the command and
    /// otherwise remembers whether exactly one item shows the chord.
    private struct ItemSearch {
        let command: KeyboardShortcutCommand
        let chord: KeyboardShortcutChord
        private(set) var matches = 0
        private(set) var onlyMatch: (NSMenu, Int)?

        init(command: KeyboardShortcutCommand, chord: KeyboardShortcutChord) {
            self.command = command
            self.chord = chord
        }

        mutating func titledItem(in menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if let submenu = item.submenu, let found = titledItem(in: submenu) { return found }
                guard KeyboardShortcutChord(menuItem: item) == chord else { continue }
                if command.isMenuTitle(item.title) { return (menu, index) }
                matches += 1
                onlyMatch = matches == 1 ? (menu, index) : nil
            }
            return nil
        }
    }
}

extension KeyboardShortcutCommand {
    /// Whether a menu item's title names this command. Menus add an ellipsis, and Clean
    /// Feed's title follows its state.
    func isMenuTitle(_ title: String) -> Bool {
        var base = title
        while let last = base.last, last == "." || last == "…" { base.removeLast() }
        return self == .toggleCleanFeed ? base.hasSuffix("Clean Feed") : base == displayName
    }
}
