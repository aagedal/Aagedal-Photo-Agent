import SwiftUI

struct KeyboardShortcutsSettingsView: View {
    @State private var searchText = ""
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
            ("S", "Toggle Scaling Filter"),
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
                if searchText.isEmpty || "caption save write next".contains(searchText.lowercased()) {
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

                if searchText.isEmpty || "rating label culling".contains(searchText.lowercased()) {
                    Section("Rating & Label — \(profileRegistry.selectedProfile.name)") {
                        ForEach(KeyboardShortcutCommand.allCases, id: \.self) { command in
                            HStack {
                                Text(command.displayName)
                                Spacer()
                                Picker("Shortcut for \(command.displayName)", selection: Binding(
                                    get: { profileRegistry.selectedProfile.chord(for: command) },
                                    set: { chord in
                                        if let chord {
                                            profileRegistry.assign(chord, to: command)
                                        } else {
                                            profileRegistry.unassign(command)
                                        }
                                    }
                                )) {
                                    Text("Unassigned").tag(nil as KeyboardShortcutChord?)
                                    ForEach(KeyboardShortcutProfiles.editableChordChoices, id: \.self) { chord in
                                        Text(chord.displayName).tag(Optional(chord))
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 120)
                                .accessibilityLabel("Shortcut for \(command.displayName)")
                                .accessibilityValue(
                                    profileRegistry.selectedProfile.chord(for: command)?.displayName
                                        ?? "Unassigned"
                                )
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

            if filteredShortcuts.isEmpty {
                Spacer()
                Text("No matching shortcuts")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}
