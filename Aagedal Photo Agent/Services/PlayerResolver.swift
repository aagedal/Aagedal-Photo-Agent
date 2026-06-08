import Foundation

/// Resolves a detected jersey number (plus team side) to a roster player using
/// the per-folder `MatchRoster`.
nonisolated struct PlayerResolver: Sendable {

    enum Resolution: Sendable, Equatable {
        /// Resolved to a single player.
        case resolved(RosterPlayer, side: TeamSide)
        /// The number exists on both teams and the side is unknown — needs the
        /// photographer to pick a side.
        case ambiguous(home: RosterPlayer, away: RosterPlayer)
        /// No roster entry matches this number on the relevant team(s).
        case notFound
    }

    /// Resolve a number to a player.
    ///
    /// - When `side` is known, look up that team's roster directly.
    /// - When `side` is `nil` (colour clustering failed/low confidence), resolve
    ///   only if exactly one team carries the number; if both do, return
    ///   `.ambiguous` so the UI can ask.
    func resolve(number: Int, side: TeamSide?, match: MatchRoster) -> Resolution {
        let home = match.homeTeamSnapshot?.player(forNumber: number)
        let away = match.awayTeamSnapshot?.player(forNumber: number)

        if let side {
            switch side {
            case .home:
                if let home { return .resolved(home, side: .home) }
            case .away:
                if let away { return .resolved(away, side: .away) }
            }
            return .notFound
        }

        switch (home, away) {
        case let (h?, nil): return .resolved(h, side: .home)
        case let (nil, a?): return .resolved(a, side: .away)
        case let (h?, a?): return .ambiguous(home: h, away: a)
        case (nil, nil): return .notFound
        }
    }
}
