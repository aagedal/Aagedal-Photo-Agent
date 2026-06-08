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

/// A team in the reusable, iCloud-synced Teams library.
///
/// Stands alone with zero face data: the photographer types the team sheet
/// (number → player) up front. Kit colours drive the colour-based home/away
/// disambiguation when two teams share a number.
nonisolated struct Team: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var primaryColor: TeamKitColor
    /// Optional alternate kit for the goalkeeper, who often wears a different colour.
    var goalkeeperColor: TeamKitColor?
    var roster: [RosterPlayer]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        primaryColor: TeamKitColor,
        goalkeeperColor: TeamKitColor? = nil,
        roster: [RosterPlayer] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.primaryColor = primaryColor
        self.goalkeeperColor = goalkeeperColor
        self.roster = roster
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Find the roster entry for a given number, if any.
    func player(forNumber number: Int) -> RosterPlayer? {
        roster.first { $0.number == number }
    }
}
