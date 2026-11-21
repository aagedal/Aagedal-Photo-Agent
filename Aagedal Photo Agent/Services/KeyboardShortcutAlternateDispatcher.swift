import AppKit

/// A menu item shows one key equivalent, so a menu command's alternate shortcut runs the
/// item whose primary shortcut the menu shows. Running the real item keeps its enabled state
/// and action identical to choosing it from the menu.
@MainActor
enum KeyboardShortcutAlternateDispatcher {
    private static var monitor: Any?

    /// Set while the shortcut editor records a key, so the press is recorded instead of run.
    static var isSuspended = false

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
              let primary = profile.menuChord(for: command), primary != chord,
              // Develop keeps its own hold and paste gestures at these chords.
              !command.hasDevelopContextOverride(for: chord),
              !keyboardTextInputState(in: event.window).imeHasMarkedText,
              let menu, let (owner, index) = item(matching: primary, in: menu) else { return false }
        if event.isARepeat { return true }
        owner.update()
        guard owner.items[index].isEnabled else { return false }
        owner.performActionForItem(at: index)
        return true
    }

    static func item(matching chord: KeyboardShortcutChord, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if let submenu = item.submenu, let found = Self.item(matching: chord, in: submenu) { return found }
            if KeyboardShortcutChord(menuItem: item) == chord { return (menu, index) }
        }
        return nil
    }
}
