import AppKit
import SwiftUI

struct KeyboardShortcutsSettingsView: View {
    @State private var searchText = ""
    @State private var editorSelection: ShortcutEditorSelection?
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
            VStack(spacing: 0) {
                HStack {
                    Picker("Shortcut profile", selection: Binding(
                        get: { profileRegistry.selectedPreset },
                        set: { profileRegistry.select($0) }
                    )) {
                        ForEach(KeyboardShortcutPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .accessibilityIdentifier("settings.shortcuts.profile")

                    Spacer()

                    Button("Restore Defaults") { showResetConfirmation = true }
                        .help("Restore the Photo Agent shortcut profile")

                    if !profileRegistry.selectedProfile.conflicts.isEmpty {
                        Button("Resolve \(profileRegistry.selectedProfile.conflicts.count) Conflicts") {
                            profileRegistry.resolveConflictsKeepingFirstCommand()
                        }
                        .help("Keep the first command for each duplicate chord and unassign the others")
                        .accessibilityIdentifier("settings.shortcuts.resolveConflicts")
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)

                Text("Choose a key to see or change its main-window action. Profiles include file, browsing, metadata, export, rating and label commands. Bare culling keys stay inactive during text entry; dialogs and settings editors keep their local controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 6)

                ShortcutKeyboardPreview(profile: profileRegistry.selectedProfile, onChooseChord: { chord in
                    editorSelection = ShortcutEditorSelection(
                        command: profileRegistry.selectedProfile.command(for: chord)
                            ?? (profileRegistry.selectedProfile.hasDevelopForwardDeleteFallback(for: chord)
                                ? .removeOrResetSelectedEditLayer : .clearRating),
                        suggestedChord: chord
                    )
                })
                .padding(.horizontal)
                .padding(.top, 10)

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter shortcuts", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear shortcut search")
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

                LazyVStack(alignment: .leading, spacing: 16) {
                    if showsCaptionShortcuts {
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
                    }

                    ForEach(filteredCommandCategories, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category).font(.headline)
                            ForEach(filteredCommands.filter { $0.category == category }, id: \.self) { command in
                                HStack {
                                    Text(command.displayName)
                                    Spacer()
                                    Button {
                                        editorSelection = ShortcutEditorSelection(command: command)
                                    } label: {
                                        let chords = profileRegistry.selectedProfile.bindings
                                            .filter { $0.command == command }.map(\.chord.displayName)
                                        Text(chords.isEmpty ? "Unassigned" : chords.joined(separator: " / "))
                                            .monospaced()
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .frame(maxWidth: 220, alignment: .trailing)
                                    }
                                    .accessibilityLabel("Edit shortcut for \(command.displayName)")
                                    .accessibilityValue(profileRegistry.selectedProfile.bindings
                                        .filter { $0.command == command }.map(\.chord.displayName).joined(separator: ", "))
                                    .help(command.isCulling ? "Change shortcuts or add an alternate key" : "Change or unassign this shortcut")
                                }
                                .padding(.vertical, 3)
                            }

                        }
                    }
                    ForEach(profileRegistry.selectedProfile.conflicts, id: \.chord) { conflict in
                        Label(
                            "\(conflict.chord.displayName) is disabled because it is assigned to \(conflict.commands.map(\.displayName).joined(separator: ", "))",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .accessibilityIdentifier("settings.shortcuts.conflict")
                    }
                    ForEach(filteredShortcuts, id: \.category) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.category).font(.headline)
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
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                if filteredShortcuts.isEmpty && filteredCommands.isEmpty && !showsCaptionShortcuts {
                    Spacer()
                    Text("No matching shortcuts")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $editorSelection) { selection in
            KeyboardShortcutEditor(command: selection.command, registry: profileRegistry, suggestedChord: selection.suggestedChord)
        }
        .confirmationDialog("Restore the default shortcut profile?", isPresented: $showResetConfirmation) {
            Button("Restore Defaults", role: .destructive) { profileRegistry.resetCustom() }
        } message: {
            Text("This replaces your custom profile with Photo Agent defaults. Caption advance shortcuts are unchanged.")
        }
    }

    fileprivate static let commandCategories = ["Rating & Label", "File", "Browser", "Image", "Metadata", "Templates", "Develop", "Export", "View", "Scopes", "Upload"]

    private var filteredCommands: [KeyboardShortcutCommand] {
        KeyboardShortcutCommand.allCases.filter { command in
            searchText.isEmpty || command.category.localizedCaseInsensitiveContains(searchText)
                || (command.isCulling && "culling".localizedCaseInsensitiveContains(searchText))
                || command.displayName.localizedCaseInsensitiveContains(searchText)
                || profileRegistry.selectedProfile.bindings.contains {
                    $0.command == command && $0.chord.displayName.localizedCaseInsensitiveContains(searchText)
                }
        }
    }

    private var filteredCommandCategories: [String] {
        Self.commandCategories.filter { category in filteredCommands.contains { $0.category == category } }
    }

    private var showsCaptionShortcuts: Bool {
        searchText.isEmpty || "caption workspace save write next".localizedCaseInsensitiveContains(searchText)
            || CaptionAdvanceShortcutCommand.allCases.contains { command in
                captionAdvanceRegistry.chord(for: command)?.displayName.localizedCaseInsensitiveContains(searchText) == true
            }
    }
}

private struct ShortcutEditorSelection: Identifiable {
    let command: KeyboardShortcutCommand
    var suggestedChord: KeyboardShortcutChord?
    var id: KeyboardShortcutCommand { command }
}

extension KeyboardShortcutCommand: Identifiable {
    var id: String { rawValue }
}

/// Logical key layout: availability is deliberately limited to chords supported in every culling workspace.
private struct ShortcutKeyboardPreview: View {
    let profile: KeyboardShortcutProfile
    var onChooseChord: (KeyboardShortcutChord) -> Void
    @State private var modifiers: KeyboardShortcutModifiers = []
    @State private var captionRegistry = CaptionAdvanceShortcutRegistry.shared

    private static let rows = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "delete", "forwarddelete"],
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l", "return"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Modifiers").foregroundStyle(.secondary)
                modifierToggle("⌃", modifier: .control, name: "Control")
                modifierToggle("⌥", modifier: .option, name: "Option")
                modifierToggle("⇧", modifier: .shift, name: "Shift")
                modifierToggle("⌘", modifier: .command, name: "Command")
                Spacer()
                if !modifiers.isEmpty {
                    Button("Clear") { modifiers = [] }.font(.caption)
                }
            }
            .accessibilityIdentifier("settings.shortcuts.keyboardLayer")

            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { key in
                        keycap(KeyboardShortcutChord(key: key, modifiers: modifiers))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                Label("Assigned", systemImage: "circle.fill").foregroundStyle(.tint)
                Label("Free", systemImage: "circle")
                Label("Reserved", systemImage: "lock.fill").foregroundStyle(.secondary)
            }
            .font(.caption)
            Text("Hover over a key to see its action. Turn modifiers on or off to inspect another layer. Locked keys remain with macOS, text entry or workspace gestures. Layout shows key names rather than physical positions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("settings.shortcuts.keyboardPreview")
    }

    private func modifierToggle(_ title: String, modifier: KeyboardShortcutModifiers, name: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { modifiers.contains(modifier) },
            set: { enabled in
                if enabled { modifiers.insert(modifier) } else { modifiers.remove(modifier) }
            }
        ))
        .toggleStyle(.button)
        .help(name)
        .accessibilityLabel(name)
    }

    private func keycap(_ chord: KeyboardShortcutChord) -> some View {
        let supported = KeyboardShortcutProfiles.editableChordChoices.contains(chord)
        let commands = Array(Set(profile.bindings.filter { $0.chord == chord }.map(\.command)))
            .sorted { $0.rawValue < $1.rawValue }
        let developDeleteFallback = profile.hasDevelopForwardDeleteFallback(for: chord)
        let captionOwners = CaptionAdvanceShortcutCommand.allCases.filter { captionRegistry.chord(for: $0) == chord }
        let description = !commands.isEmpty
            ? commands.map { command in
                command.displayName + (chord == .init(key: "n", modifiers: .command)
                    ? " (Keyword Editor: add keyword)" : "") + (command.hasDevelopContextOverride(for: chord)
                    ? (command == .duplicateSelected ? " (Develop: hold to mute selected layer)" : " (Develop: paste with crop)") : "")
            }.joined(separator: ", ")
            : developDeleteFallback ? "Develop: Remove or Reset Selected Edit Layer (Delete compatibility shortcut; assigning this key overrides it)"
            : !captionOwners.isEmpty ? captionOwners.map { "Caption: " + $0.displayName }.joined(separator: ", ")
                + "; edit in the Caption Workspace section"
            : (supported ? "Free" : (KeyboardShortcutProfiles.reservation(for: chord) ?? "Reserved for text entry or workspace gestures"))
        let assigned = !commands.isEmpty || !captionOwners.isEmpty || developDeleteFallback
        return Button {
            onChooseChord(chord)
        } label: {
            VStack(spacing: 1) {
                Text(chord.key == "delete" ? "⌫" : chord.key == "forwarddelete" ? "⌦" : chord.key == "return" ? "↩" : chord.key.uppercased()).font(.system(.body, design: .monospaced))
                Image(systemName: supported ? (assigned ? "circle.fill" : "circle") : "lock.fill")
                    .font(.system(size: 7))
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(assigned ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!supported)
        .help("\(chord.displayName): \(description)")
        .accessibilityLabel("\(chord.displayName), \(description)")
    }

}

private struct KeyboardShortcutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var command: KeyboardShortcutCommand
    let registry: KeyboardShortcutProfileRegistry
    var suggestedChord: KeyboardShortcutChord?
    @State private var pendingChord: KeyboardShortcutChord?
    @State private var recording = false
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Action", selection: $command) {
                ForEach(KeyboardShortcutsSettingsView.commandCategories, id: \.self) { category in
                    Section(category) {
                        ForEach(KeyboardShortcutCommand.allCases.filter { $0.category == category }) { command in
                            Text(command.displayName).tag(command)
                        }
                    }
                }
            }
            if let suggestedChord {
                Button("Assign \(suggestedChord.displayName) to \(command.displayName)") { choose(suggestedChord) }
            }
            let chords = registry.selectedProfile.bindings.filter { $0.command == command }.map(\.chord)
            if chords.isEmpty { Text("Unassigned").foregroundStyle(.secondary) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading) {
                    ForEach(chords, id: \.self) { chord in
                        Button {
                            registry.remove(chord, from: command)
                        } label: {
                            Label(chord.displayName, systemImage: "xmark.circle")
                        }
                        .help("Remove \(chord.displayName) from \(command.displayName)")
                        .accessibilityLabel("Remove \(chord.displayName) from \(command.displayName)")
                    }
                }
            }
            .frame(height: min(112, CGFloat((chords.count + 3) / 4) * 28))
            if let chord = chords.first(where: { command.hasDevelopContextOverride(for: $0) }) {
                Text(command == .duplicateSelected
                    ? "At \(chord.displayName), Develop holds the selected layer muted; Browser duplicates. Assign a different key to duplicate from Develop."
                    : "At \(chord.displayName), Develop pastes edits with crop. Assign a different key for Variable Reference in Develop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(recording ? "Cancel Recording" : "Record Shortcut") {
                recording.toggle()
                feedback = ""
            }
            if recording {
                ShortcutKeyRecorder { chord in
                    guard let chord else { recording = false; return }
                    choose(chord)
                }
                .frame(height: 32)
                .overlay(Text("Press a shortcut. Escape cancels.").allowsHitTesting(false))
                .accessibilityLabel("Press a shortcut. Escape cancels.")
            }
            ShortcutKeyboardPreview(profile: registry.selectedProfile, onChooseChord: choose)
            Text(feedback.isEmpty ? (command.isCulling
                ? "Choose a key or record a shortcut to add an alternate. Use × to remove a shortcut."
                : "Choose a key or record a shortcut to replace this command’s assignment. Use × to unassign it.") : feedback)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .alert("Reassign \(pendingChord?.displayName ?? "shortcut")?", isPresented: Binding(
            get: { pendingChord != nil }, set: { if !$0 { pendingChord = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingChord = nil }
            Button("Reassign") {
                if let chord = pendingChord {
                    registry.reassign(chord, to: command, replacingConflicts: true)
                    feedback = "\(chord.displayName) assigned to \(command.displayName)."
                }
                pendingChord = nil
            }
        } message: {
            let owners = registry.selectedProfile.bindings.filter { $0.chord == pendingChord && $0.command != command }
                .map(\.command.displayName)
            Text("This removes the shortcut from \(owners.joined(separator: ", ")) and assigns it to \(command.displayName).")
        }
        .onChange(of: command) { _, _ in recording = false; feedback = ""; pendingChord = nil }
    }

    private func choose(_ chord: KeyboardShortcutChord) {
        guard KeyboardShortcutProfiles.canAssign(chord, to: command) else {
            feedback = KeyboardShortcutProfiles.reservation(for: chord)
                ?? (command.isCulling ? "Use bare numbers, S or X, or a Command shortcut for ratings and labels."
                    : "Use a modified shortcut so this command does not interrupt typing.")
            return
        }
        recording = false
        if registry.reassign(chord, to: command) {
            feedback = "\(chord.displayName) assigned to \(command.displayName)."
        } else {
            pendingChord = chord
        }
    }
}

/// A first-responder view captures keys locally; no application-wide event monitor can leak after dismissal.
private struct ShortcutKeyRecorder: NSViewRepresentable {
    var onKey: (KeyboardShortcutChord?) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) { view.onKey = onKey }

    final class RecorderView: NSView {
        var onKey: ((KeyboardShortcutChord?) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned {
                // A modifier-layer or action-picker click ends recording. Removed views
                // must not cancel a newly mounted recorder on a later UI update.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window, window.firstResponder !== self else { return }
                    self.onKey?(nil)
                }
            }
            return resigned
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard let window, window.isKeyWindow, window.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }
        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat else { return }
            if event.keyCode == 53 { onKey?(nil); return }
            guard let chord = KeyboardShortcutChord(event: event) else { return }
            onKey?(chord)
        }
    }
}
