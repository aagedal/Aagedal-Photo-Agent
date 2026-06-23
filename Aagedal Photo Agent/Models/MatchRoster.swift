import Foundation

/// Which side of a match a detection belongs to. Disambiguates the common case
/// where both teams field the same number, told apart by kit colour.
nonisolated enum TeamSide: String, Codable, Sendable, CaseIterable {
    case home
    case away
}

/// How a folder's numbers map to people.
///
/// - `team`: two teams that may share a number, told apart by kit colour (football etc.).
/// - `event`: one startlist where a bib number maps directly to an athlete, no team colour
///   (athletics, cycling, marathon). Colour clustering and the home/away confirm step are skipped.
nonisolated enum MatchMode: String, Codable, Sendable, CaseIterable {
    case team
    case event
}

/// Per-folder match setup: which two teams are playing in this working folder.
///
/// The home/away `Team`s are stored both by id (for re-linking to the live
/// library) and as embedded snapshots, so the folder stays self-contained and
/// keeps resolving player names even if the global Team is later edited or
/// deleted. Persisted to `<folder>/.face_data/match_roster.json`.
nonisolated struct MatchRoster: Codable, Sendable {
    var folderURL: URL
    var homeTeamID: UUID?
    var awayTeamID: UUID?
    var homeTeamSnapshot: Team?
    var awayTeamSnapshot: Team?

    /// Whether this folder is a two-team match or a single-startlist event. Optional for
    /// backwards compatibility with rosters written before bib mode existed; `nil` ⇒ `.team`.
    var mode: MatchMode?

    /// Whether the photographer has confirmed the colour-cluster → side mapping.
    /// Until confirmed, resolution pauses and surfaces the confirm/flip prompt.
    var clusterMappingConfirmed: Bool
    /// The photographer's confirmed flip choice (swaps which colour cluster maps
    /// to home vs away). Persisted so re-scans reuse the decision.
    var clusterFlipped: Bool
    var lastUpdated: Date

    init(
        folderURL: URL,
        homeTeamID: UUID? = nil,
        awayTeamID: UUID? = nil,
        homeTeamSnapshot: Team? = nil,
        awayTeamSnapshot: Team? = nil,
        mode: MatchMode? = nil,
        clusterMappingConfirmed: Bool = false,
        clusterFlipped: Bool = false,
        lastUpdated: Date = Date()
    ) {
        self.folderURL = folderURL
        self.homeTeamID = homeTeamID
        self.awayTeamID = awayTeamID
        self.homeTeamSnapshot = homeTeamSnapshot
        self.awayTeamSnapshot = awayTeamSnapshot
        self.mode = mode
        self.clusterMappingConfirmed = clusterMappingConfirmed
        self.clusterFlipped = clusterFlipped
        self.lastUpdated = lastUpdated
    }

    /// The mode, defaulting legacy (un-set) rosters to a two-team match.
    var effectiveMode: MatchMode { mode ?? .team }

    /// The team snapshot for a given side, if set.
    func team(for side: TeamSide) -> Team? {
        switch side {
        case .home: return homeTeamSnapshot
        case .away: return awayTeamSnapshot
        }
    }

    /// In event mode the single startlist is held in the home slot (away stays nil).
    var eventStartlist: Team? { homeTeamSnapshot }

    /// True when enough is set up to resolve names: both teams for a match, or the
    /// single startlist for an event.
    var isReady: Bool {
        switch effectiveMode {
        case .team: return homeTeamSnapshot != nil && awayTeamSnapshot != nil
        case .event: return homeTeamSnapshot != nil
        }
    }
}
