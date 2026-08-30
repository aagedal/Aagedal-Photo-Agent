import SwiftUI
import UniformTypeIdentifiers

/// Editor for the reusable, optionally iCloud-synced Teams library.
/// Each team has a name, kit colour(s), and a number→player roster.
///
/// Presented as a sheet from the folder view; the same `TeamsLibraryContent`
/// is embedded directly in Settings (People and Groups ▸ Teams). The content
/// uses an explicit two-pane layout (rather than a NavigationSplitView) so it
/// renders identically in both hosts — a nested split view inside the Settings
/// window's own split view rendered cramped and hoisted its toolbar buttons.
struct TeamsLibraryView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TeamsLibraryContent()
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        // Cap the height so a long roster scrolls inside the Form instead of
        // growing the sheet past the bottom of the screen. Sized to the visible
        // screen (minus the menu bar / margins) with a safe fallback.
        .frame(minWidth: 700, minHeight: 480, maxHeight: Self.maxSheetHeight)
    }

    private static var maxSheetHeight: CGFloat {
        guard let visible = NSScreen.main?.visibleFrame.height else { return 760 }
        return max(480, visible - 80)
    }
}

/// The team list + editor split, reusable both as a sheet (TeamsLibraryView)
/// and embedded in Settings (People and Groups ▸ Teams).
struct TeamsLibraryContent: View {
    @State private var store = RosterStore.shared
    @State private var selection: UUID?
    @State private var showDeleteAlert = false
    @State private var searchText = ""
    @State private var sportFilter: TeamSport?
    @State private var deletionErrorMessage: String?

    /// Teams matching the current search text and sport filter, sorted by name.
    private var filteredTeams: [Team] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return store.allTeams().filter { team in
            (sportFilter == nil || team.effectiveSport == sportFilter)
                && (query.isEmpty || team.name.lowercased().contains(query))
        }
    }

    /// Sports that actually have teams, for a tidy filter menu.
    private var presentSports: [TeamSport] {
        let used = Set(store.allTeams().map(\.effectiveSport))
        return TeamSport.allCases.filter { used.contains($0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            teamList
                .frame(width: 240)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var teamList: some View {
        VStack(spacing: 0) {
            // Search + sport filter — a professional library can hold many teams.
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Search teams", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                Menu {
                    Button { sportFilter = nil } label: {
                        Label("All sports", systemImage: sportFilter == nil ? "checkmark" : "")
                    }
                    ForEach(presentSports, id: \.self) { sport in
                        Button { sportFilter = sport } label: {
                            Label(sport.displayName, systemImage: sportFilter == sport ? "checkmark" : "")
                        }
                    }
                } label: {
                    Label(sportFilter?.displayName ?? "All sports", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            List(selection: $selection) {
                ForEach(filteredTeams) { team in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(team.primaryColor))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.4)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(team.name.isEmpty ? "Untitled Team" : team.name)
                            Text("\(team.effectiveSport.displayName) · \(team.roster.count) player\(team.roster.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(team.id)
                }
            }

            Divider()

            // Add and delete sit together as a native source-list +/- control.
            HStack(spacing: 2) {
                Button(action: addTeam) {
                    Image(systemName: "plus")
                }
                .help("Add a team")

                Button { showDeleteAlert = true } label: {
                    Image(systemName: "trash")
                }
                .help("Delete the selected team")
                .disabled(selection == nil)

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .alert("Delete this team?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let id = selection {
                    do {
                        try store.delete(id: id)
                        selection = nil
                    } catch {
                        deletionErrorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the team and its roster from the library on all your devices.")
        }
        .alert(
            "Deletion Not Completed",
            isPresented: Binding(
                get: { deletionErrorMessage != nil },
                set: { if !$0 { deletionErrorMessage = nil } }
            )
        ) {
            Button("OK") { deletionErrorMessage = nil }
        } message: {
            Text(deletionErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let id = selection, let team = store.team(byID: id) {
            TeamEditorView(team: team, store: store)
                .id(id)
        } else {
            ContentUnavailableView("No Team Selected", systemImage: "tshirt",
                                   description: Text("Select a team, or add one with +."))
        }
    }

    private func addTeam() {
        // Clear filters so the freshly-added team is visible in the list.
        searchText = ""
        sportFilter = nil
        let team = Team(name: "", primaryColor: TeamKitColor(r: 0.2, g: 0.4, b: 0.9))
        try? store.upsert(team)
        selection = team.id
    }
}

/// Editor for one team — name, kit colours, and roster. Changes save
/// automatically (debounced), so there is no explicit Save button.
private struct TeamEditorView: View {
    let store: RosterStore

    @State private var name: String
    @State private var sport: TeamSport
    @State private var primary: Color
    @State private var hasSecondary: Bool
    @State private var secondary: Color
    @State private var hasGoalkeeper: Bool
    @State private var goalkeeper: Color
    @State private var roster: [RosterPlayer]
    @State private var pasteText: String = ""
    @State private var showPaste = false
    @State private var knownPeople: [KnownPerson] = []
    @State private var saveTask: Task<Void, Never>?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportRequestID: UUID?
    @State private var textImportTask: Task<Void, Never>?
    @State private var textImportRequestID: UUID?
    @State private var textImportErrorMessage: String?

    private let teamID: UUID
    private let createdAt: Date

    init(team: Team, store: RosterStore) {
        self.store = store
        self.teamID = team.id
        self.createdAt = team.createdAt
        _name = State(initialValue: team.name)
        _sport = State(initialValue: team.effectiveSport)
        _primary = State(initialValue: Color(team.primaryColor))
        _hasSecondary = State(initialValue: team.secondaryColor != nil)
        _secondary = State(initialValue: Color(team.secondaryColor ?? TeamKitColor(r: 0.95, g: 0.95, b: 0.95)))
        _hasGoalkeeper = State(initialValue: team.goalkeeperColor != nil)
        _goalkeeper = State(initialValue: Color(team.goalkeeperColor ?? TeamKitColor(r: 0.9, g: 0.8, b: 0.1)))
        _roster = State(initialValue: team.roster.sorted { $0.number < $1.number })
    }

    var body: some View {
        Form {
            Section("Team") {
                TextField("Name", text: $name)
                Picker("Sport", selection: $sport) {
                    ForEach(TeamSport.allCases, id: \.self) { sport in
                        Text(sport.displayName).tag(sport)
                    }
                }
                ColorPicker("Home kit colour", selection: $primary, supportsOpacity: false)
                Toggle("Has an alternate (away) kit", isOn: $hasSecondary)
                if hasSecondary {
                    ColorPicker("Away kit colour", selection: $secondary, supportsOpacity: false)
                }
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
                        Text("Face")
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
                            // Link this jersey number to a Known Person (face), and
                            // show their thumbnail so the photographer can confirm
                            // the right person at a glance.
                            faceColumn(player: $player)
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
                    Menu {
                        Button("From file…") { importTextFile() }
                        Button("Paste…") { showPaste = true }
                    } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .fixedSize()
                    Menu {
                        Button("PDF…") { exportPDF() }
                        Button("Roster text (.txt)…") { exportText() }
                    } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .fixedSize()
                    .disabled(roster.allSatisfy { $0.playerName.trimmingCharacters(in: .whitespaces).isEmpty })
                }
            } header: {
                Text("Roster (\(roster.count))")
            }
        }
        .formStyle(.grouped)
        .onAppear { knownPeople = KnownPeopleService.shared.getAllPeople() }
        .onChange(of: name) { scheduleSave() }
        .onChange(of: sport) { scheduleSave() }
        .onChange(of: primary) { scheduleSave() }
        .onChange(of: hasSecondary) { scheduleSave() }
        .onChange(of: secondary) { scheduleSave() }
        .onChange(of: hasGoalkeeper) { scheduleSave() }
        .onChange(of: goalkeeper) { scheduleSave() }
        .onChange(of: roster) { scheduleSave() }
        .onDisappear {
            saveTask?.cancel()
            exportTask?.cancel()
            exportRequestID = nil
            textImportTask?.cancel()
            textImportRequestID = nil
            save()
        }
        .sheet(isPresented: $showPaste) {
            pasteSheet
        }
        .alert(
            "Import Not Completed",
            isPresented: Binding(
                get: { textImportErrorMessage != nil },
                set: { if !$0 { textImportErrorMessage = nil } }
            )
        ) {
            Button("OK") { textImportErrorMessage = nil }
        } message: {
            Text(textImportErrorMessage ?? "")
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

    /// The "Face" column: a fixed-width thumbnail of the linked Known Person
    /// (or an empty placeholder so the columns stay aligned) plus the link menu.
    @ViewBuilder
    private func faceColumn(player: Binding<RosterPlayer>) -> some View {
        HStack(spacing: 6) {
            if let id = player.wrappedValue.knownPersonID {
                LinkedFaceThumbnail(personID: id)
            } else {
                Color.clear.frame(width: 56, height: 56)
            }
            faceLinkMenu(player: player)
        }
    }

    /// Per-player control to bind a jersey number to a Known Person, so face
    /// recognition and number recognition identify the same player.
    @ViewBuilder
    private func faceLinkMenu(player: Binding<RosterPlayer>) -> some View {
        let linkedID = player.wrappedValue.knownPersonID
        Menu {
            if knownPeople.isEmpty {
                Text("No known people yet — add people from the face manager first.")
            } else {
                ForEach(knownPeople) { person in
                    Button {
                        player.wrappedValue.knownPersonID = person.id
                        if player.wrappedValue.playerName.trimmingCharacters(in: .whitespaces).isEmpty {
                            player.wrappedValue.playerName = person.name
                        }
                    } label: {
                        if linkedID == person.id {
                            Label(person.name, systemImage: "checkmark")
                        } else {
                            Text(person.name)
                        }
                    }
                }
            }
            if linkedID != nil {
                Divider()
                Button(role: .destructive) {
                    player.wrappedValue.knownPersonID = nil
                } label: { Label("Unlink", systemImage: "person.crop.circle.badge.xmark") }
            }
        } label: {
            Image(systemName: linkedID != nil ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
                .foregroundStyle(linkedID != nil ? Color.green : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(linkedID != nil
              ? "Linked to \(linkedName(linkedID) ?? "a known person") — recognised by face. Click to change or unlink."
              : "Link this number to a known person so their face and jersey number identify each other.")
    }

    private func linkedName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return knownPeople.first { $0.id == id }?.name
    }

    private func nextNumber() -> Int {
        (roster.map(\.number).max() ?? 0) + 1
    }

    /// Parse "<number> <name>" lines (separators: space, comma, tab). Merges with
    /// existing roster, overwriting names on number collisions.
    private func importRoster(from text: String) {
        roster = RosterTextImporter.merge(text, into: roster)
    }

    /// Debounce writes so each keystroke or colour-wheel drag doesn't trigger a
    /// coordinated (possibly iCloud) disk write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        // If the team was deleted while its editor was on screen, onDisappear
        // would otherwise resurrect it via upsert. Skip when it's already gone.
        guard store.team(byID: teamID) != nil else { return }
        try? store.upsert(currentTeam())
    }

    /// Build a `Team` from the current editor state, dropping unnamed rows and
    /// sorting by number. Shared by autosave and PDF export.
    private func currentTeam() -> Team {
        let cleaned = roster
            .filter { !$0.playerName.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.number < $1.number }
        return Team(
            id: teamID,
            name: name.trimmingCharacters(in: .whitespaces),
            primaryColor: primary.teamKitColor,
            secondaryColor: hasSecondary ? secondary.teamKitColor : nil,
            goalkeeperColor: hasGoalkeeper ? goalkeeper.teamKitColor : nil,
            sport: sport,
            roster: cleaned,
            createdAt: createdAt,
            updatedAt: Date()
        )
    }

    /// Export the roster as a laid-out PDF (number, name, face, team name) via a
    /// save panel. Face images come from the linked Known People thumbnails.
    private func exportPDF() {
        let team = currentTeam()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let base = team.name.isEmpty ? "Roster" : team.name
        panel.nameFieldStringValue = "\(base).pdf"
        panel.title = "Export Roster PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let pdf = RosterPDFExporter.makePDF(for: team, exportedOn: Date()) { id in
            KnownPeopleService.shared.loadThumbnail(for: id)
        }
        startExport(data: pdf, to: url)
    }

    /// Export the roster as a plain-text list, one "<number> <name>" per line —
    /// the same format the paste/import parser accepts, so it round-trips.
    private func exportText() {
        let team = currentTeam()
        let lines = team.roster.map { "\($0.number) \($0.playerName)" }
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let base = team.name.isEmpty ? "Roster" : team.name
        panel.nameFieldStringValue = "\(base).txt"
        panel.title = "Export Roster Text"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        startExport(data: Data(text.utf8), to: url, writingOptions: .atomic)
    }

    private func startExport(
        data: Data,
        to destinationURL: URL,
        writingOptions: Data.WritingOptions = []
    ) {
        exportTask?.cancel()
        let requestID = UUID()
        exportRequestID = requestID
        let artifact = TeamRosterExportArtifact(
            data: data,
            destinationURL: destinationURL,
            writingOptions: writingOptions
        )
        exportTask = Task { @MainActor in
            let evidence = await TeamRosterExportService.shared.export(
                [artifact],
                requestID: requestID
            )
            guard exportRequestID == requestID else { return }
            exportRequestID = nil
            exportTask = nil
            guard case .failed(let failure) = evidence.results.first else { return }
            NSAlert(error: failure.nsError).runModal()
        }
    }

    /// Import a "<number> <name>" roster from a text file, merging into the
    /// current roster via the same parser as paste.
    private func importTextFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Roster Text"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        textImportTask?.cancel()
        let requestID = UUID()
        textImportRequestID = requestID
        textImportErrorMessage = nil
        textImportTask = Task { @MainActor in
            do {
                let result = try await TextFileImportService.shared.loadText(
                    from: url,
                    requestID: requestID
                )
                guard textImportRequestID == requestID else { return }
                switch result {
                case .loaded(let snapshot):
                    importRoster(from: snapshot.text)
                case .cancelledBeforeRead, .cancelledAfterRead:
                    break
                }
            } catch {
                guard textImportRequestID == requestID else { return }
                textImportErrorMessage = error.localizedDescription
            }

            guard textImportRequestID == requestID else { return }
            textImportRequestID = nil
            textImportTask = nil
        }
    }
}

/// A small rounded thumbnail of a Known Person's representative face, loaded
/// from the Known People database. Falls back to a placeholder glyph.
private struct LinkedFaceThumbnail: View {
    let personID: UUID
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
        .help("Linked known person's face")
        .task(id: personID) {
            image = KnownPeopleService.shared.loadThumbnail(for: personID)
        }
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
