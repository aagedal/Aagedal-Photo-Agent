import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("PlayerResolver")
struct PlayerResolverTests {

    private func makeMatch() -> MatchRoster {
        let home = Team(
            name: "Rosenborg",
            primaryColor: TeamKitColor(r: 1, g: 1, b: 1),
            roster: [
                RosterPlayer(number: 1, playerName: "Keeper Home"),
                RosterPlayer(number: 9, playerName: "Hansen"),
            ]
        )
        let away = Team(
            name: "Brann",
            primaryColor: TeamKitColor(r: 0.8, g: 0.1, b: 0.1),
            roster: [
                RosterPlayer(number: 9, playerName: "Riise"),
                RosterPlayer(number: 10, playerName: "Olsen"),
            ]
        )
        return MatchRoster(
            folderURL: URL(fileURLWithPath: "/tmp/match"),
            homeTeamID: home.id,
            awayTeamID: away.id,
            homeTeamSnapshot: home,
            awayTeamSnapshot: away
        )
    }

    @Test("Known side resolves to that team's player")
    func resolvesWithKnownSide() {
        let resolver = PlayerResolver()
        let match = makeMatch()
        #expect(resolver.resolve(number: 9, side: .home, match: match) == .resolved(match.homeTeamSnapshot!.roster.first { $0.number == 9 }!, side: .home))
        #expect(resolver.resolve(number: 9, side: .away, match: match) == .resolved(match.awayTeamSnapshot!.roster.first { $0.number == 9 }!, side: .away))
    }

    @Test("Same number on both teams with unknown side is ambiguous")
    func ambiguousWhenSharedNumberAndNoSide() {
        let resolver = PlayerResolver()
        let match = makeMatch()
        let result = resolver.resolve(number: 9, side: nil, match: match)
        if case .ambiguous(let home, let away) = result {
            #expect(home.playerName == "Hansen")
            #expect(away.playerName == "Riise")
        } else {
            Issue.record("Expected .ambiguous, got \(result)")
        }
    }

    @Test("Unique number with unknown side resolves to the only team that has it")
    func resolvesUniqueNumberWithoutSide() {
        let resolver = PlayerResolver()
        let match = makeMatch()
        #expect(resolver.resolve(number: 1, side: nil, match: match) == .resolved(RosterPlayer(id: match.homeTeamSnapshot!.roster.first { $0.number == 1 }!.id, number: 1, playerName: "Keeper Home"), side: .home))
        #expect(resolver.resolve(number: 10, side: nil, match: match) == .resolved(match.awayTeamSnapshot!.roster.first { $0.number == 10 }!, side: .away))
    }

    @Test("Unknown number is not found")
    func notFoundForUnknownNumber() {
        let resolver = PlayerResolver()
        let match = makeMatch()
        #expect(resolver.resolve(number: 42, side: .home, match: match) == .notFound)
        #expect(resolver.resolve(number: 42, side: nil, match: match) == .notFound)
    }
}
