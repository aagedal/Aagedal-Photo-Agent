import SwiftUI

struct KeyboardShortcutsSettingsView: View {
    @State private var searchText = ""

    private static let allShortcuts: [(category: String, shortcuts: [(keys: String, description: String)])] = [
        ("File", [
            ("\u{2318}O", "Open Folder"),
            ("\u{2318}\u{21E7}I", "Import Photos"),
            ("\u{2318}E", "Open in Editor"),
        ]),
        ("Rating & Label", [
            ("\u{2318}0", "No Rating"),
            ("\u{2318}1\u{2013}5", "Set 1\u{2013}5 Stars"),
            ("\u{2325}0", "No Label"),
            ("\u{2325}1\u{2013}8", "Set Color Label"),
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
        ]),
        ("Metadata", [
            ("\u{2318}P", "Process Variables"),
            ("\u{2318}\u{21E7}P", "Process Variables (All)"),
            ("\u{2318}\u{21E7}W", "Write All Pending Metadata"),
            ("\u{2318}T", "Apply Template"),
            ("\u{2303}1\u{2013}9", "Apply Template Slot"),
            ("\u{2318}I", "Show Raw Metadata"),
        ]),
        ("Edit Workspace", [
            ("Escape", "Exit Edit Workspace"),
            ("M (hold)", "Before / After Toggle"),
            ("\u{2318}D (hold)", "Mute Selected Mask / Global"),
            ("D (hold)", "Disable Develop Adjustments"),
            ("\u{2190}\u{2192}", "Previous / Next Image"),
            ("\u{2318}C", "Copy Develop Settings"),
            ("C", "Toggle Crop Controls"),
            ("\u{2318}V", "Paste Develop Settings"),
            ("\u{2318}\u{21E7}V", "Paste with Crop"),
            ("\u{2318}Z", "Undo"),
            ("\u{2318}\u{21E7}Z", "Redo"),
            ("Z", "Toggle Zoom Fit / 100%"),
            ("H", "Toggle HDR"),
        ]),
        ("Full Screen", [
            ("Escape / Space", "Dismiss"),
            ("Z", "Toggle Zoom at Cursor"),
            ("H", "Toggle UI Visibility"),
            ("S", "Toggle Scaling Filter"),
            ("F", "Toggle Face Rectangles"),
            ("E", "Toggle Edit Rendering"),
            ("\u{2318}0\u{2013}5", "Set Rating"),
            ("\u{2318}\u{2325}0\u{2013}8", "Set Color Label"),
            ("Arrow Keys", "Navigate Images"),
            ("Scroll Wheel", "Zoom at Cursor"),
        ]),
        ("Scopes", [
            ("\u{21E7}1", "Waveform"),
            ("\u{21E7}2", "Parade"),
            ("\u{21E7}3", "Vectorscope"),
            ("\u{21E7}4", "Gamut"),
            ("G", "Toggle Gamut Clipping"),
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
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            List {
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
