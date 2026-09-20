import SwiftUI

/// Coordinates multiple Teams windows so a stale review cannot reject an import being accepted.
@MainActor
final class TeamImportReviewCoordinator {
    static let shared = TeamImportReviewCoordinator()
    private var active: Set<UUID> = []

    func decide(_ team: Team, accepted: Bool, destination: URL?, cloudEnabled: Bool,
                queue: MCPTeamReviewQueue, store: RosterStore = .shared,
                authorizationStore: MCPAuthorizationStore = MCPAuthorizationStore()) async throws {
        guard active.insert(team.id).inserted else { throw MCPProcessReservationError.busy }
        defer { active.remove(team.id) }
        let decision = try await Task.detached { try queue.decision(for: team.id) }.value
        if let decision {
            guard decision == (accepted ? "accepted" : "rejected") else { throw MCPTeamLibrary.Failure.teamAlreadyExists }
            return
        }
        if accepted {
            guard let destination else { throw MCPTeamLibrary.Failure.storageUnavailable }
            try await store.importReviewedTeam(team, destination: destination, cloudEnabled: cloudEnabled,
                                               authorizationStore: authorizationStore)
        }
        try await Task.detached { try queue.finish(team, accepted: accepted) }.value
    }
}

/// Reviews the exact captured roster. Only this UI initiates writes to the active library.
struct TeamImportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var requests: [Team] = []
    @State private var selectedID: UUID?
    @State private var destination: URL?
    @State private var cloudEnabled = false
    @State private var busy = false
    @State private var errorMessage: String?

    private var selected: Team? { requests.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Team Imports").font(.title2)
            Text("Check the names, jersey numbers and kit colours before adding a team.")
                .foregroundStyle(.secondary)
            HStack {
                List(requests, selection: $selectedID) { team in
                    VStack(alignment: .leading) {
                        Text(team.name)
                        Text("\(team.roster.count) players · \(team.effectiveSport.displayName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(team.id)
                }.frame(width: 220)
                if let team = selected {
                    VStack(alignment: .leading) {
                        Text(team.name).font(.headline)
                        HStack {
                            kit("Primary", team.primaryColor)
                            if let color = team.secondaryColor { kit("Alternate", color) }
                            if let color = team.goalkeeperColor { kit("Goalkeeper", color) }
                        }
                        List(team.roster) { player in
                            HStack {
                                Text(String(player.number)).monospacedDigit().frame(width: 55, alignment: .trailing)
                                Text(player.playerName)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No Pending Import", systemImage: "person.3",
                        description: Text("Teams submitted by your AI client will appear here for review."))
                }
            }
            Text(cloudEnabled ? "Destination: iCloud Teams library. The added roster will sync to your devices."
                              : "Destination: local Teams library.")
                .font(.callout)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Refresh") { Task { await reload() } }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Reject", role: .destructive) { decide(accepted: false) }.disabled(selected == nil)
                Button("Add Team") { decide(accepted: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || destination == nil || ICloudSyncCoordinator.shared.isTeamsRouting)
            }
        }
        .padding(20)
        .frame(width: 780, height: 560)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .task { await reload() }
    }

    private func kit(_ label: String, _ color: TeamKitColor) -> some View {
        HStack {
            Circle().fill(Color(red: color.r, green: color.g, blue: color.b)).frame(width: 16, height: 16)
            Text(label).font(.caption)
        }
    }

    private func reload() async {
        busy = true
        defer { busy = false }
        errorMessage = nil
        destination = nil
        let cloud = UserDefaults.standard.bool(forKey: UserDefaultsKeys.teamsICloudEnabled)
        cloudEnabled = cloud
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let queue = try MCPTeamReviewQueue(directory: MCPTeamReviewQueue.defaultDirectory())
                let requests = try queue.pending()
                let destination = cloud ? AppPaths.iCloudTeamsURL : RosterStore.localTeamsDirectory
                return (requests, destination)
            }.value
            requests = result.0
            if !requests.contains(where: { $0.id == selectedID }) { selectedID = requests.first?.id }
            guard cloud == UserDefaults.standard.bool(forKey: UserDefaultsKeys.teamsICloudEnabled),
                  !ICloudSyncCoordinator.shared.isTeamsRouting else {
                errorMessage = "Teams storage is changing. Refresh after the change finishes."
                return
            }
            destination = result.1
            if let destination {
                await RosterStore.shared.reloadAfterStorageChange(resolvedStorageURL: destination)
            }
            if destination == nil { errorMessage = "iCloud is unavailable. Your request is still pending; try again when iCloud Drive is ready." }
        } catch { errorMessage = error.localizedDescription }
    }

    private func decide(accepted: Bool) {
        guard let team = selected else { return }
        let reviewedDestination = destination
        let reviewedCloud = cloudEnabled
        busy = true
        errorMessage = nil
        Task {
            do {
                let queue = try MCPTeamReviewQueue(directory: MCPTeamReviewQueue.defaultDirectory())
                try await TeamImportReviewCoordinator.shared.decide(team, accepted: accepted,
                    destination: reviewedDestination, cloudEnabled: reviewedCloud, queue: queue)
                requests.removeAll { $0.id == team.id }
                selectedID = requests.first?.id
            } catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }
}
