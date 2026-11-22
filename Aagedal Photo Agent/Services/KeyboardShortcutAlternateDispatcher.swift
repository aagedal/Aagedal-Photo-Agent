import AppKit

/// A menu item shows one key equivalent, so a menu command's alternate shortcut runs the
/// item whose primary shortcut the menu shows. Running the real item keeps its enabled state
/// and action identical to choosing it from the menu. A primary that menus cannot match
/// (Shift with a digit or punctuation) runs the same way.
@MainActor
enum KeyboardShortcutAlternateDispatcher {
    private static var monitor: Any?

    /// Set while the shortcut editor records a key, so the press is recorded instead of run.
    static var isSuspended = false

    /// Develop workspaces that currently handle their hold and paste gestures (⌘D, ⌥V) for
    /// a key event. Elsewhere those chords run their command like any other alternate.
    private static var developGestureOwners: [UUID: (NSEvent) -> Bool] = [:]

    static func registerDevelopGestureOwner(_ id: UUID, owns: @escaping (NSEvent) -> Bool) {
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
              !(command.hasDevelopContextOverride(for: chord) && developGestureOwners.values.contains { $0(event) }),
              !keyboardTextInputState(in: event.window).imeHasMarkedText,
              let menu, let (owner, index) = item(for: command, matching: primary, in: menu) else { return false }
        // AppKit offers a menu key to the key window (a sheet, a button's key equivalent)
        // before the menu; an alternate takes the same order.
        if let window = event.window, window.performKeyEquivalent(with: event) { return true }
        if event.isARepeat { return true }
        owner.update()
        guard owner.items[index].isEnabled else { return false }
        owner.performActionForItem(at: index)
        return true
    }

    /// The item for `command` that shows `chord`. A system item can show the same chord ahead
    /// of the command's own, so when several do, the title decides.
    static func item(
        for command: KeyboardShortcutCommand,
        matching chord: KeyboardShortcutChord,
        in menu: NSMenu
    ) -> (NSMenu, Int)? {
        let found = items(matching: chord, in: menu)
        if found.count == 1 { return found[0] }
        return found.first { command.isMenuTitle($0.0.items[$0.1].title) }
    }

    private static func items(matching chord: KeyboardShortcutChord, in menu: NSMenu) -> [(NSMenu, Int)] {
        menu.items.enumerated().flatMap { index, item -> [(NSMenu, Int)] in
            let nested = item.submenu.map { items(matching: chord, in: $0) } ?? []
            return KeyboardShortcutChord(menuItem: item) == chord ? nested + [(menu, index)] : nested
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
