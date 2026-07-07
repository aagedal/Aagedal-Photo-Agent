import Foundation

/// A single roster entry: a jersey number mapped to a player name.
///
/// `knownPersonID` is the optional bridge to the face-recognition Known People
/// database. It stays `nil` until the photographer confirms a face↔number link,
/// at which point the matched face is promoted into Known People and its id is
/// stamped here — so future games recognise the player by face before the number
/// is even visible. The Team database itself never stores face embeddings.
nonisolated struct RosterPlayer: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var number: Int
    var playerName: String
    var knownPersonID: UUID?

    init(
        id: UUID = UUID(),
        number: Int,
        playerName: String,
        knownPersonID: UUID? = nil
    ) {
        self.id = id
        self.number = number
        self.playerName = playerName
        self.knownPersonID = knownPersonID
    }
}

/// A configured team kit colour (sRGB, components 0...1).
nonisolated struct TeamKitColor: Codable, Sendable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Bridge to the colour type used by detection/clustering.
    var colorRGB: ColorRGB { ColorRGB(r: r, g: g, b: b) }

    init(_ color: ColorRGB) {
        self.r = color.r
        self.g = color.g
        self.b = color.b
    }
}

/// The sport a team (or startlist) plays, used to search/filter a large library.
nonisolated enum TeamSport: String, Codable, Sendable, CaseIterable {
    case football
    case handball
    case basketball
    case iceHockey
    case volleyball
    case rugby
    case americanFootball
    case athletics
    case cycling
    case other

    var displayName: String {
        switch self {
        case .football: "Football"
        case .handball: "Handball"
        case .basketball: "Basketball"
        case .iceHockey: "Ice hockey"
        case .volleyball: "Volleyball"
        case .rugby: "Rugby"
        case .americanFootball: "American football"
        case .athletics: "Athletics"
        case .cycling: "Cycling"
        case .other: "Other"
        }
    }
}

/// A team in the reusable, iCloud-synced Teams library.
///
/// Stands alone with zero face data: the photographer types the team sheet
/// (number → player) up front. Kit colours drive the colour-based home/away
/// disambiguation when two teams share a number.
nonisolated struct Team: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var primaryColor: TeamKitColor
    /// Optional alternate (away/change) kit, worn when the primary clashes with the opponent.
    /// Considered alongside the primary when matching sampled colours to this team.
    var secondaryColor: TeamKitColor?
    /// Optional alternate kit for the goalkeeper, who often wears a different colour.
    var goalkeeperColor: TeamKitColor?
    /// Sport category for search/filter. Optional for backwards compatibility; `nil` ⇒ `.other`.
    var sport: TeamSport?
    var roster: [RosterPlayer]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        primaryColor: TeamKitColor,
        secondaryColor: TeamKitColor? = nil,
        goalkeeperColor: TeamKitColor? = nil,
        sport: TeamSport? = nil,
        roster: [RosterPlayer] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.goalkeeperColor = goalkeeperColor
        self.sport = sport
        self.roster = roster
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The sport, defaulting legacy (un-set) teams to `.other`.
    var effectiveSport: TeamSport { sport ?? .other }

    /// All configured kit colours (primary, secondary, goalkeeper), used to match a sampled
    /// jersey colour to this team regardless of which kit they wore.
    var kitColors: [ColorRGB] {
        [primaryColor.colorRGB, secondaryColor?.colorRGB, goalkeeperColor?.colorRGB].compactMap { $0 }
    }

    /// Find the roster entry for a given number, if any.
    func player(forNumber number: Int) -> RosterPlayer? {
        roster.first { $0.number == number }
    }
}
