import SwiftUI

/// Editor for the reusable, optionally iCloud-synced Teams library.
/// Each team has a name, kit colour(s), and a number→player roster.
struct TeamsLibraryView: View {
    @State private var store = RosterStore.shared
    @State private var selection: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.allTeams()) { team in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(team.primaryColor))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.4)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(team.name.isEmpty ? "Untitled Team" : team.name)
                            Text("\(team.roster.count) players")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(team.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let team = Team(name: "", primaryColor: TeamKitColor(r: 0.2, g: 0.4, b: 0.9))
                        try? store.upsert(team)
                        selection = team.id
                    } label: { Image(systemName: "plus") }
                    .help("Add a team")
                }
            }
        } detail: {
            if let id = selection, let team = store.team(byID: id) {
                TeamEditorView(team: team, store: store) {
                    selection = nil
                }
                .id(id)
            } else {
                ContentUnavailableView("No Team Selected", systemImage: "tshirt",
                                       description: Text("Select a team, or add one with +."))
            }
        }
        .frame(minWidth: 680, minHeight: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

/// Editor for one team — name, kit colours, and roster.
private struct TeamEditorView: View {
    let store: RosterStore
    let onDelete: () -> Void

    @State private var name: String
    @State private var primary: Color
    @State private var hasGoalkeeper: Bool
    @State private var goalkeeper: Color
    @State private var roster: [RosterPlayer]
    @State private var pasteText: String = ""
    @State private var showPaste = false
    @State private var showDeleteAlert = false

    private let teamID: UUID
    private let createdAt: Date

    init(team: Team, store: RosterStore, onDelete: @escaping () -> Void) {
        self.store = store
        self.onDelete = onDelete
        self.teamID = team.id
        self.createdAt = team.createdAt
        _name = State(initialValue: team.name)
        _primary = State(initialValue: Color(team.primaryColor))
        _hasGoalkeeper = State(initialValue: team.goalkeeperColor != nil)
        _goalkeeper = State(initialValue: Color(team.goalkeeperColor ?? TeamKitColor(r: 0.9, g: 0.8, b: 0.1)))
        _roster = State(initialValue: team.roster.sorted { $0.number < $1.number })
    }

    var body: some View {
        Form {
            Section("Team") {
                TextField("Name", text: $name)
                ColorPicker("Kit colour", selection: $primary, supportsOpacity: false)
                Toggle("Goalkeeper wears a different colour", isOn: $hasGoalkeeper)
                if hasGoalkeeper {
                    ColorPicker("Goalkeeper colour", selection: $goalkeeper, supportsOpacity: false)
                }
            }

            Section {
                // Grid so the number, name and trailing controls line up in fixed
                // columns across every row — an HStack per row drifts because the
                // optional "linked" badge changes each row's layout.
                Grid(alignment: .leading, verticalSpacing: 6) {
                    GridRow {
                        Text("No.")
                        Text("Player")
                        Color.clear.frame(width: 1, height: 1)
                        Color.clear.frame(width: 1, height: 1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ForEach($roster) { $player in
                        GridRow {
                            // labelsHidden() + prompt keeps the placeholder *inside*
                            // the field; without it a grouped Form renders the title
                            // as a separate leading label and the columns drift.
                            TextField("No.", value: $player.number, format: .number, prompt: Text("No."))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 52)
                                .textFieldStyle(.roundedBorder)
                            TextField("Player name", text: $player.playerName, prompt: Text("Player name"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 180)
                            // Fixed badge column so the delete buttons stay aligned
                            // whether or not a player is linked to a known person.
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .foregroundStyle(player.knownPersonID != nil ? Color.green : Color.clear)
                                .help(player.knownPersonID != nil ? "Linked to a known person (recognised by face)" : "")
                            Button {
                                roster.removeAll { $0.id == player.id }
                            } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                            .buttonStyle(.plain)
                            .gridColumnAlignment(.trailing)
                        }
                    }
                }
                HStack {
                    Button {
                        roster.append(RosterPlayer(number: nextNumber(), playerName: ""))
                    } label: { Label("Add player", systemImage: "plus") }
                    Spacer()
                    Button("Paste roster…") { showPaste = true }
                }
            } header: {
                Text("Roster (\(roster.count))")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(name.isEmpty ? "Untitled Team" : name)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) { showDeleteAlert = true } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this team")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
        .sheet(isPresented: $showPaste) {
            pasteSheet
        }
        .alert("Delete this team?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                try? store.delete(id: teamID)
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the team and its roster from the library on all your devices.")
        }
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste one player per line, e.g. \"9 Berg\" or \"9, Berg\".")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $pasteText)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 320, minHeight: 200)
                .border(.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel") { showPaste = false }
                Button("Import") {
                    importRoster(from: pasteText)
                    pasteText = ""
                    showPaste = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 380)
    }

    private func nextNumber() -> Int {
        (roster.map(\.number).max() ?? 0) + 1
    }

    /// Parse "<number> <name>" lines (separators: space, comma, tab). Merges with
    /// existing roster, overwriting names on number collisions.
    private func importRoster(from text: String) {
        var byNumber = Dictionary(roster.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSep = trimmed.firstIndex(where: { $0 == " " || $0 == "," || $0 == "\t" }) else { continue }
            let numberPart = trimmed[..<firstSep].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t"))
            let namePart = trimmed[firstSep...].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t"))
            guard let number = Int(numberPart), !namePart.isEmpty else { continue }
            if var existing = byNumber[number] {
                existing.playerName = namePart
                byNumber[number] = existing
            } else {
                byNumber[number] = RosterPlayer(number: number, playerName: namePart)
            }
        }
        roster = byNumber.values.sorted { $0.number < $1.number }
    }

    private func save() {
        let cleaned = roster
            .filter { !$0.playerName.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.number < $1.number }
        let team = Team(
            id: teamID,
            name: name.trimmingCharacters(in: .whitespaces),
            primaryColor: primary.teamKitColor,
            goalkeeperColor: hasGoalkeeper ? goalkeeper.teamKitColor : nil,
            roster: cleaned,
            createdAt: createdAt,
            updatedAt: Date()
        )
        try? store.upsert(team)
    }
}

extension Color {
    init(_ kit: TeamKitColor) {
        self.init(.sRGB, red: kit.r, green: kit.g, blue: kit.b)
    }

    init(_ rgb: ColorRGB) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// Convert to a kit colour by resolving in the sRGB space.
    var teamKitColor: TeamKitColor {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return TeamKitColor(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }
}
