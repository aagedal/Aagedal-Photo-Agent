import AppKit
import SwiftUI

/// Settings summary of the keyboard shortcuts: the active preset, the editor window, the
/// Caption Workspace advance keys and the fixed workspace gestures.
struct KeyboardShortcutsSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    @State private var showResetConfirmation = false
    @State private var profileRegistry = KeyboardShortcutProfileRegistry.shared
    @State private var captionAdvanceRegistry = CaptionAdvanceShortcutRegistry.shared

    private static let allShortcuts: [(category: String, shortcuts: [(keys: String, description: String)])] = [
        ("Browser gestures", [
            ("← → ↑ ↓", "Navigate Selection"),
            ("⇧+Arrow", "Extend Selection"),
            ("Space / ⌘F", "Toggle Full Screen"),
            ("⌘A", "Select All"),
            ("⌥M", "Switch Embedded / XMP Reference"),
            ("⌘W", "Close Tab (when the browser has tabs or splits)"),
        ]),
        ("Develop gestures", [
            ("Escape", "Exit Edit Workspace"),
            ("Space (hold)", "Pan Image"),
            ("M (hold)", "Before / After Preview"),
            ("⌘D (hold)", "Mute Selected Mask / Global"),
            ("D (hold)", "Disable Develop Adjustments"),
            ("← →", "Previous / Next Image"),
            ("⌘C", "Copy Develop Settings"),
            ("⌘V", "Paste Develop Settings"),
            ("⌥V", "Paste with Crop"),
            ("⌘⇧V", "Paste with Crop"),
            ("⌘Z / ⌘⇧Z", "Undo / Redo"),
            ("C", "Toggle Crop Controls"),
            ("J", "Add Radial Mask"),
            ("B", "Toggle Brush Tool"),
            ("Z", "Toggle Zoom Fit / 100%"),
        ]),
        ("Full Screen gestures", [
            ("Escape / Space", "Dismiss Full Screen"),
            ("C", "Open Comparison"),
            ("Z", "Toggle Zoom at Cursor"),
            ("H", "Toggle UI Visibility"),
            ("⌥S", "Toggle Scaling Filter"),
            ("F", "Toggle Face Rectangles"),
            ("E", "Toggle Edit Rendering"),
            ("Arrow Keys", "Navigate Images"),
            ("Scroll Wheel", "Zoom at Cursor"),
        ]),
        ("List editor gestures", [
            ("⌘N", "Add Keyword (Keyword Editor)"),
        ]),
        ("Comparison gestures", [
            ("Escape", "Close Comparison"),
            ("Tab", "Focus Other Image"),
            ("← →", "Replace Focused Image"),
            ("Delete", "Move Focused Image to Trash"),
        ]),
    ]

    private var filteredShortcuts: [(category: String, shortcuts: [(keys: String, description: String)])] {
        let query = searchText.lowercased()
        return Self.allShortcuts.compactMap { section in
            let matches = section.shortcuts.filter {
                if $0.keys == "⌘D (hold)",
                   let owner = profileRegistry.selectedProfile.command(for: .init(key: "d", modifiers: .command)),
                   owner != .duplicateSelected { return false }
                if $0.keys == "⌥V",
                   let owner = profileRegistry.selectedProfile.command(for: .init(key: "v", modifiers: .option)),
                   owner != .showVariableReference { return false }
                return searchText.isEmpty ||
                $0.description.lowercased().contains(query) ||
                $0.keys.lowercased().contains(query) ||
                section.category.lowercased().contains(query)
            }
            guard !matches.isEmpty else { return nil }
            return (section.category, matches)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("Shortcut preset", selection: Binding(
                        get: { profileRegistry.activePresetName },
                        set: { name in
                            guard name != profileRegistry.activePresetName else { return }
                            profileRegistry.applyPreset(named: name)
                        }
                    )) {
                        ForEach(KeyboardShortcutPreset.allCases) { Text($0.displayName).tag($0.displayName) }
                        if !profileRegistry.presets.isEmpty { Divider() }
                        ForEach(profileRegistry.presets) { Text($0.name).tag($0.name) }
                    }
                    .fixedSize()
                    .disabled(profileRegistry.isModified)
                    .help(profileRegistry.isModified
                        ? "Save or revert your changes in the Keyboard Shortcuts window before switching presets."
                        : "Switch the active shortcut preset")
                    .accessibilityIdentifier("settings.shortcuts.profile")

                    if profileRegistry.isModified {
                        Text("Modified")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }

                    Spacer()

                    Button("Restore Defaults") { showResetConfirmation = true }
                        .help("Switch back to the Photo Agent preset")
                    Button("Open Keyboard Shortcuts…") { openWindow(id: KeyboardShortcutEditorWindow.id) }
                        .accessibilityIdentifier("settings.shortcuts.openEditor")
                }

                Text("The Keyboard Shortcuts window (⌥⌘K) shows your keyboard with every assigned key, lets you record two shortcuts per command, and saves, imports and shares presets. Bare culling keys stay inactive while you type; dialogs keep their own controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Caption Workspace").font(.headline)
                    ForEach(CaptionAdvanceShortcutCommand.allCases, id: \.self) { command in
                        HStack {
                            Text(command.displayName)
                            Spacer()
                            Picker("Shortcut for \(command.displayName)", selection: Binding(
                                get: { captionAdvanceRegistry.chord(for: command) },
                                set: { chord in
                                    if let chord {
                                        captionAdvanceRegistry.assign(chord, to: command)
                                    } else {
                                        captionAdvanceRegistry.unassign(command)
                                    }
                                }
                            )) {
                                Text("Unassigned").tag(nil as KeyboardShortcutChord?)
                                ForEach(CaptionAdvanceShortcutRegistry.editableChordChoices, id: \.self) { chord in
                                    Text(chord.displayName).tag(Optional(chord))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                            .accessibilityLabel("Shortcut for \(command.displayName)")
                            .accessibilityValue(
                                captionAdvanceRegistry.chord(for: command)?.displayName
                                    ?? "Unassigned"
                            )
                        }
                    }
                    Text("Assigning a chord already used here moves it to the selected command, so Save & Next and Write & Next cannot be ambiguous.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Workspace Gestures").font(.headline)
                        Spacer()
                        TextField("Filter gestures", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                    Text("These keys are fixed. The Keyboard Shortcuts window shows them as reserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(filteredShortcuts, id: \.category) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.category).font(.subheadline.weight(.semibold))
                            ForEach(section.shortcuts, id: \.keys) { shortcut in
                                HStack {
                                    Text(shortcut.description)
                                    Spacer()
                                    Text(shortcut.keys)
                                        .foregroundStyle(.secondary)
                                        .font(.system(.body, design: .rounded))
                                }
                            }
                        }
                    }
                    if filteredShortcuts.isEmpty {
                        Text("No matching gestures").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog("Switch back to the Photo Agent shortcuts?", isPresented: $showResetConfirmation) {
            Button("Restore Defaults", role: .destructive) { profileRegistry.resetToDefaults() }
        } message: {
            Text("Unsaved changes to the current shortcuts are discarded. Saved presets and Caption advance shortcuts are unchanged.")
        }
    }
}

/// The scene identity of the keyboard shortcut editor window.
enum KeyboardShortcutEditorWindow {
    static let id = "keyboardShortcuts"
}
