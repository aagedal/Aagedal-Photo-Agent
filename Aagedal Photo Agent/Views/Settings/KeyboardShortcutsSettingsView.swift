import AppKit
import SwiftUI

struct KeyboardShortcutsSettingsView: View {
    @State private var searchText = ""
    @State private var editorSelection: ShortcutEditorSelection?
    @State private var showResetConfirmation = false
    @State private var profileRegistry = KeyboardShortcutProfileRegistry.shared
    @State private var captionAdvanceRegistry = CaptionAdvanceShortcutRegistry.shared

    private static let allShortcuts: [(category: String, shortcuts: [(keys: String, description: String)])] = [
        ("File", [
            ("\u{2318}O", "Open Folder"),
            ("\u{2318}\u{21E7}I", "Import Photos"),
            ("\u{2318}E", "Open in Editor"),
        ]),
        ("Browser", [
            ("\u{2190}\u{2192}\u{2191}\u{2193}", "Navigate Selection"),
            ("\u{21E7}+Arrow", "Extend Selection"),
            ("Space", "Enter Full Screen"),
            ("\u{2318}A", "Select All"),
            ("\u{2318}F", "Toggle Full Screen"),
            ("\u{2325}M", "Toggle Metadata Panel"),
        ]),
        ("Image", [
            ("\u{2318}B", "Previous Image"),
            ("\u{2318}N", "Next Image"),
            ("\u{2318}R", "Rotate Right"),
            ("\u{2318}\u{21E7}R", "Rotate Left"),
            ("\u{2318}S", "Render Selected"),
            ("\u{2318}\u{21E7}S", "Render All"),
            ("\u{2318}D", "Duplicate"),
            ("\u{2318}\u{232B}", "Move to Trash"),
            ("\u{2318}J", "Add New Mask"),
            ("\u{2303}\u{2325}\u{232B}", "Remove or Reset Selected Edit Layer"),
        ]),
        ("Metadata", [
            ("\u{2318}P", "Process Variables"),
            ("\u{2318}\u{21E7}P", "Process Variables (All)"),
            ("\u{2318}\u{21E7}W", "Write All Pending Metadata"),
            ("\u{2318}T", "Apply Metadata Template (outside Develop)"),
            ("\u{2303}1\u{2013}9", "Apply Metadata Template Slot (outside Develop)"),
            ("\u{2318}I", "Show Raw Metadata"),
        ]),
        ("Edit Workspace", [
            ("Escape", "Exit Edit Workspace"),
            ("M (hold)", "Before / After Toggle"),
            ("\u{2318}D (hold)", "Mute Selected Mask / Global"),
            ("D (hold)", "Disable Develop Adjustments"),
            ("\u{2190}\u{2192}", "Previous / Next Image"),
            ("\u{2318}C", "Copy Develop Settings"),
            ("\u{2318}T", "Apply Develop Template"),
            ("\u{2303}1\u{2013}9", "Apply Develop Template Slot"),
            ("C", "Toggle Crop Controls"),
            ("\u{2318}V", "Paste Develop Settings"),
            ("\u{2325}V", "Paste with Crop"),
            ("\u{2318}\u{21E7}V", "Paste with Crop"),
            ("\u{2318}Z", "Undo"),
            ("\u{2318}\u{21E7}Z", "Redo"),
            ("Z", "Toggle Zoom Fit / 100%"),
            ("H", "Toggle HDR"),
        ]),
        ("Full Screen", [
            ("Escape / Space", "Dismiss"),
            ("C", "Open Comparison"),
            ("Z", "Toggle Zoom at Cursor"),
            ("H", "Toggle UI Visibility"),
            ("⌥S", "Toggle Scaling Filter"),
            ("F", "Toggle Face Rectangles"),
            ("E", "Toggle Edit Rendering"),
            ("Selected profile", "Set Rating or Color Label"),
            ("Arrow Keys", "Navigate Images"),
            ("Scroll Wheel", "Zoom at Cursor"),
        ]),
        ("Comparison", [
            ("Escape", "Close Comparison"),
            ("Tab", "Focus Other Image"),
            ("\u{2190}\u{2192}", "Replace Focused Image"),
            ("Delete", "Move Focused Image to Trash"),
            ("Selected profile", "Rate or Label Focused Image"),
        ]),
        ("Clean Feed", [
            ("\u{2318}\u{21E7}F", "Toggle Clean Feed"),
        ]),
        ("Scopes", [
            ("\u{2303}\u{2325}1", "Waveform"),
            ("\u{2303}\u{2325}2", "Parade"),
            ("\u{2303}\u{2325}3", "Vectorscope"),
            ("\u{2303}\u{2325}4", "Gamut"),
            ("\u{2303}\u{2325}G", "Toggle Gamut Clipping"),
            ("\u{2303}\u{2325}H", "Toggle HDR"),
        ]),
        ("Upload", [
            ("\u{2318}U", "Upload Selected"),
            ("\u{2318}\u{21E7}U", "Upload All"),
        ]),
    ]

    private var filteredShortcuts: [(category: String, shortcuts: [(keys: String, description: String)])] {
        guard !searchText.isEmpty else { return Self.allShortcuts }
        let query = searchText.lowercased()
        return Self.allShortcuts.compactMap { section in
            let matches = section.shortcuts.filter {
                $0.description.lowercased().contains(query) ||
                $0.keys.lowercased().contains(query) ||
                section.category.lowercased().contains(query)
            }
            guard !matches.isEmpty else { return nil }
            return (section.category, matches)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Culling shortcut profile", selection: Binding(
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
                    .help("Restore the Photo Agent rating and label shortcuts")

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

            Text("The selected profile controls rating and color-label keys in Browser, Comparison, Develop, and Full Screen. Bare keys are suppressed while a text editor or input method owns typing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 6)

            ShortcutKeyboardPreview(profile: profileRegistry.selectedProfile, onChooseChord: { chord in
                editorSelection = ShortcutEditorSelection(
                    command: profileRegistry.selectedProfile.command(for: chord) ?? .clearRating,
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

            List {
                if showsCaptionShortcuts {
                    Section("Caption Workspace") {
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

                if !filteredCullingCommands.isEmpty {
                    Section("Rating & Label — \(profileRegistry.selectedProfile.name)") {
                        ForEach(filteredCullingCommands, id: \.self) { command in
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
                                .help("Change shortcuts or add an alternate key")
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
                    }
                }
                ForEach(filteredShortcuts, id: \.category) { section in
                    Section(section.category) {
                        ForEach(section.shortcuts, id: \.description) { shortcut in
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
            .listStyle(.inset)

            if filteredShortcuts.isEmpty && filteredCullingCommands.isEmpty && !showsCaptionShortcuts {
                Spacer()
                Text("No matching shortcuts")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .sheet(item: $editorSelection) { selection in
            CullingShortcutEditor(command: selection.command, registry: profileRegistry, suggestedChord: selection.suggestedChord)
        }
        .confirmationDialog("Restore default rating and label shortcuts?", isPresented: $showResetConfirmation) {
            Button("Restore Defaults", role: .destructive) { profileRegistry.resetCustom() }
        } message: {
            Text("This replaces your custom rating and label shortcuts. Caption shortcuts are unchanged.")
        }
    }

    private var filteredCullingCommands: [KeyboardShortcutCommand] {
        KeyboardShortcutCommand.allCases.filter { command in
            searchText.isEmpty || "rating label culling".localizedCaseInsensitiveContains(searchText)
                || command.displayName.localizedCaseInsensitiveContains(searchText)
                || profileRegistry.selectedProfile.bindings.contains {
                    $0.command == command && $0.chord.displayName.localizedCaseInsensitiveContains(searchText)
                }
        }
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

    private static let rows = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Keyboard layer", selection: $modifiers) {
                Text("No modifiers").tag(KeyboardShortcutModifiers())
                Text("⌘").tag(KeyboardShortcutModifiers.command)
                Text("⌘⌥").tag(KeyboardShortcutModifiers([.command, .option]))
            }
            .pickerStyle(.segmented)
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
            Text("Rating and label keys. Choose a key to inspect or assign it. Other keys are reserved for workspace and system commands. Layout shows key names, not physical positions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("settings.shortcuts.keyboardPreview")
    }

    private func keycap(_ chord: KeyboardShortcutChord) -> some View {
        let supported = KeyboardShortcutProfiles.editableChordChoices.contains(chord)
        let commands = Array(Set(profile.bindings.filter { $0.chord == chord }.map(\.command)))
            .sorted { $0.rawValue < $1.rawValue }
        let description = commands.isEmpty ? (supported ? "Free" : "Reserved")
            : commands.map(\.displayName).joined(separator: ", ")
        return Button {
            onChooseChord(chord)
        } label: {
            VStack(spacing: 1) {
                Text(chord.key.uppercased()).font(.system(.body, design: .monospaced))
                Image(systemName: supported ? (commands.isEmpty ? "circle" : "circle.fill") : "lock.fill")
                    .font(.system(size: 7))
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(commands.isEmpty ? Color.secondary.opacity(0.07) : Color.accentColor.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!supported)
        .help("\(chord.displayName): \(description)")
        .accessibilityLabel("\(chord.displayName), \(description)")
    }

}

private struct CullingShortcutEditor: View {
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
                ForEach(KeyboardShortcutCommand.allCases) { command in
                    Text(command.displayName).tag(command)
                }
            }
            if let suggestedChord {
                Button("Assign \(suggestedChord.displayName) to \(command.displayName)") { choose(suggestedChord) }
            }
            let chords = registry.selectedProfile.bindings.filter { $0.command == command }.map(\.chord)
            if chords.isEmpty { Text("Unassigned").foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), alignment: .leading)], alignment: .leading) {
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
            Text(feedback.isEmpty ? "Choose a free key or record a shortcut to add it. Use × to remove an existing shortcut." : feedback)
                .font(.caption)
                .foregroundStyle(.secondary)
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
        guard KeyboardShortcutProfiles.editableChordChoices.contains(chord) else {
            feedback = "\(chord.displayName) is reserved. Choose an unlocked key on the keyboard preview."
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
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }
        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat else { return }
            if event.keyCode == 53 { onKey?(nil); return }
            guard let key = event.charactersIgnoringModifiers, !key.isEmpty else { return }
            onKey?(KeyboardShortcutChord(key: key, modifiers: KeyboardShortcutModifiers(event.modifierFlags)))
        }
    }
}
