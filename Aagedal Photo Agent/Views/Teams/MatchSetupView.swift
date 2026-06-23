import SwiftUI

/// Per-folder sports setup: choose a two-team match (pick home & away, confirm the
/// colour → team mapping) or an individual event (pick one startlist; bibs resolve directly).
struct MatchSetupView: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    let folderURL: URL?

    @State private var store = RosterStore.shared
    @State private var mode: MatchMode = .team
    @State private var homeID: UUID?
    @State private var awayID: UUID?
    @State private var eventID: UUID?
    @State private var showTeamsLibrary = false
    @Environment(\.dismiss) private var dismiss

    private var teams: [Team] { store.allTeams() }

    private var canSave: Bool {
        guard folderURL != nil else { return false }
        switch mode {
        case .team: return homeID != nil && awayID != nil && homeID != awayID
        case .event: return eventID != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: $mode) {
                        Text("Team match").tag(MatchMode.team)
                        Text("Individual event").tag(MatchMode.event)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(mode == .team
                         ? "Two teams that may share a number, told apart by kit colour."
                         : "One startlist — each bib number maps directly to an athlete, no team colour.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if mode == .team {
                    Section("Match teams") {
                        teamPicker(title: "Home", selection: $homeID)
                        teamPicker(title: "Away", selection: $awayID)
                        Button("Manage Teams…") { showTeamsLibrary = true }
                    }

                    if let cluster = viewModel.pendingColorClusterConfirmation {
                        confirmationSection(cluster)
                    }

                    if !viewModel.ambiguousNumberDetections.isEmpty {
                        ambiguousSection
                    }
                } else {
                    Section("Startlist") {
                        teamPicker(title: "Athletes", selection: $eventID)
                        Button("Manage Startlists…") { showTeamsLibrary = true }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button("Save & Resolve") {
                    guard let folderURL else { return }
                    switch mode {
                    case .team:
                        viewModel.setMatchTeams(homeTeamID: homeID, awayTeamID: awayID, folderURL: folderURL)
                    case .event:
                        viewModel.setEventStartlist(teamID: eventID, folderURL: folderURL)
                    }
                    viewModel.runSportsResolution()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 460, height: 520)
        .onAppear {
            if let folderURL { viewModel.loadMatchRoster(for: folderURL) }
            mode = viewModel.matchRoster?.effectiveMode ?? .team
            homeID = viewModel.matchRoster?.homeTeamID
            awayID = viewModel.matchRoster?.awayTeamID
            if mode == .event { eventID = viewModel.matchRoster?.homeTeamID }
        }
        .sheet(isPresented: $showTeamsLibrary) {
            TeamsLibraryView()
        }
    }

    private func teamPicker(title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("—").tag(UUID?.none)
            ForEach(teams) { team in
                Text(team.name.isEmpty ? "Untitled Team" : team.name).tag(UUID?.some(team.id))
            }
        }
    }

    private func confirmationSection(_ cluster: TeamColorClusterer.ClusterResult) -> some View {
        Section("Confirm team colours") {
            Text("The scan grouped the players into two kit colours. Is this mapping correct?")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                swatch("Home", color: cluster.homeCentroid, count: cluster.homeCount)
                swatch("Away", color: cluster.awayCentroid, count: cluster.awayCount)
            }
            if cluster.confidence < 0.5 {
                Label("The two kit colours look similar — double-check the mapping.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Looks right") { viewModel.confirmClusterMapping(flip: false) }
                    .buttonStyle(.borderedProminent)
                Button("Flip teams") { viewModel.confirmClusterMapping(flip: true) }
            }
        }
    }

    private func swatch(_ label: String, color: ColorRGB, count: Int) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(color))
                .frame(width: 64, height: 40)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4)))
            Text(label).font(.caption.bold())
            Text("\(count) players").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var ambiguousSection: some View {
        Section("Resolve ambiguous numbers") {
            Text("These numbers exist on both teams and the kit colour was unclear. Pick a side.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(viewModel.ambiguousNumberDetections) { det in
                HStack {
                    Text("#\(det.number)")
                        .font(.title3.monospacedDigit())
                        .frame(width: 44, alignment: .leading)
                    Text(det.imageURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(homeName(det.number)) { viewModel.assignSide(.home, toNumberDetection: det.id) }
                    Button(awayName(det.number)) { viewModel.assignSide(.away, toNumberDetection: det.id) }
                }
            }
        }
    }

    private func homeName(_ number: Int) -> String {
        viewModel.matchRoster?.homeTeamSnapshot?.player(forNumber: number)?.playerName ?? "Home"
    }

    private func awayName(_ number: Int) -> String {
        viewModel.matchRoster?.awayTeamSnapshot?.player(forNumber: number)?.playerName ?? "Away"
    }
}
