#if DEBUG
import CompetitionCore
import ComposableArchitecture
import XCTest
@testable import HealthComp

@MainActor
final class GroupMatchResultTests: XCTestCase {
    func testJudgesRevealReadsEveryFormatFromTheServersPlaces() throws {
        let won = try XCTUnwrap(CompetitionJudgesBout(GroupMatchFixtures.routed(.resultFFAWon)!))
        XCTAssertEqual(won.sides.map(\.label), ["YOU", "SAM", "PRIYA", "LEO"])
        XCTAssertEqual(won.sides.map(\.place), [1, 2, 3, 4])
        XCTAssertEqual(won.sides[0].cardTotal(0) ?? 0, 2941 * 0.4, accuracy: 0.001)
        XCTAssertEqual(won.label, "UNANIMOUS DECISION")
        XCTAssertEqual(won.title, "YOUR WINNER")
        XCTAssertEqual(won.heading, "YOU VS SAM VS PRIYA VS LEO · FINAL BELL")
        // Last place loses its light first; the last two walk to the referee.
        XCTAssertEqual(won.ring.clock.cuts, [4: 0.8, 3: 1.5])
        XCTAssertEqual(won.ring.clock.walk, 2.2)
        XCTAssertEqual(won.ring.clock.raise, 3.4, accuracy: 0.001)
        XCTAssertEqual(won.ring.stances.map(\.isOut), [false, false, true, true])
        XCTAssertEqual(won.ring.stances.prefix(2).map(\.x), [72, 288])

        let tied = try XCTUnwrap(CompetitionJudgesBout(GroupMatchFixtures.routed(.resultFFATied)!))
        XCTAssertEqual(tied.label, "DRAW")
        XCTAssertEqual(tied.title, "IT’S A DRAW")
        XCTAssertEqual(tied.ring.stances.map(\.won), [true, true, false, false])

        // You and Priya share 3rd: both lights cut together, Leo's arm goes up.
        let third = try XCTUnwrap(CompetitionJudgesBout(GroupMatchFixtures.routed(.resultFFATiedThird)!))
        XCTAssertEqual(third.title, "THE WINNER, LEO")
        XCTAssertEqual(third.ring.clock.cuts, [3: 0.8])
        XCTAssertEqual(third.ring.stances.map(\.isOut), [true, false, true, false])

        let doubles = try XCTUnwrap(CompetitionJudgesBout(GroupMatchFixtures.routed(.resultDoubles)!))
        XCTAssertEqual(doubles.sides.map(\.label), ["YOU + PRIYA", "SAM + LEO"])
        XCTAssertEqual(doubles.fighters.map(\.name), ["You", "Priya", "Sam", "Leo"])
        XCTAssertEqual(doubles.title, "YOUR WINNERS")
        XCTAssertEqual(doubles.ring.clock.raise, 1)
        XCTAssertEqual(doubles.ring.stances.map(\.isHeld), [true, false, true, false])
        XCTAssertEqual(
            try XCTUnwrap(CompetitionJudgesBout(GroupMatchFixtures.routed(.resultDoublesTied)!)).title, "IT’S A DRAW"
        )
        // No result yet, no reveal.
        XCTAssertNil(CompetitionJudgesBout(GroupMatchFixtures.routed(.liveFFA)!))
    }

    func testJudgesRevealWithoutRingsOrWithATieForSecond() {
        func bout(_ places: [Int], cards: [[Double?]]) -> CompetitionJudgesBout {
            CompetitionJudgesBout(
                format: .freeForAll,
                fighters: places.indices.map { .init(name: "P\($0)", isYou: $0 == 0, side: $0) },
                sides: places.enumerated().map { index, place in
                    .init(label: "P\(index)", isYours: index == 0, place: place, total: Double(700 - place), cards: cards)
                },
                dayLabels: (1...7).map(String.init),
                label: ""
            )
        }
        // Three still standing: no referee, and the raise waits for the one cut.
        let clock = bout([1, 2, 2, 4], cards: []).ring.clock
        XCTAssertFalse(clock.hasReferee)
        XCTAssertNil(clock.walk)
        XCTAssertEqual(clock.raise, 1.8, accuracy: 0.001)
        // A bot has no rings: the cards never decide it.
        let empty = Array(repeating: [Double?](repeating: nil, count: 7), count: 3)
        XCTAssertEqual(CompetitionJudgesBout.label(bout([1, 2, 3], cards: empty).sides), "BY TOTAL POINTS")
        XCTAssertEqual(competitionJudgesVerdict(winner: [3, 2, 1], rest: [[2, 2, 0], [1, 1, 5]]), "BY TOTAL POINTS")
        XCTAssertEqual(competitionJudgesVerdict(winner: [3, 2, 6], rest: [[2, 2, 0], [1, 1, 5]]), "MAJORITY DECISION")
    }

    func testDoublesCanTieOnTheServersPlaces() {
        let match = GroupMatchFixtures.routed(.resultDoublesTied)!
        XCTAssertEqual(match.standingRows.map(\.place), [1, 1])
        XCTAssertEqual(Set(match.standingRows.map(\.centipoints)), [555_100])
    }

    func testCarryAndDaysWonComeFromTheServersResult() throws {
        let match = GroupMatchFixtures.routed(.resultDoubles)!
        XCTAssertEqual(match.frozenCarryPercent(seatID: GroupMatchFixtures.Player.you.seatID), 53)
        XCTAssertEqual(match.frozenDaysWon(by: .team(1)), 7)

        // Cached days that disagree with a result carrying only places are never used.
        let bare = try doubles(partner: .person(profileID: UUID(), invite: .accepted), won: true)
        XCTAssertNil(bare.frozenCarryPercent(seatID: GroupMatchFixtures.Player.you.seatID))
        XCTAssertNil(bare.frozenDaysWon(by: .team(1)))
    }

    func testPartnersAreKeptApartByProfileOrBotNotName() throws {
        let sam = UUID()
        let records = GroupMatchRecord.partnerRecords([
            try doubles(partner: .person(profileID: sam, invite: .accepted), name: "Sam", won: true),
            try doubles(partner: .person(profileID: UUID(), invite: .accepted), name: "Sam", won: false),
            try doubles(partner: .person(profileID: sam, invite: .accepted), name: "Samuel", won: true),
            try doubles(partner: .person(profileID: UUID(), invite: .accepted), name: "Pacer", won: true),
            try doubles(partner: .bot(.pacer), name: "Pacer", won: false),
        ])
        XCTAssertEqual(records.map { $0.name }, ["Sam", "Sam", "Pacer", "Pacer"])
        XCTAssertEqual(records.map { $0.record }, [[2, 0, 0], [0, 1, 0], [1, 0, 0], [0, 1, 0]])
    }

    func testHistoryListsOnlyFinishedGroupMatchesNewestFirst() {
        let live = GroupMatchFixtures.routed(.liveFFA)!
        let history = GroupMatchFixtures.history
        let finished = GroupMatchRecord.finished([live] + history.reversed())
        XCTAssertEqual(finished.map(\.id), history.map(\.id))
    }

    /// A finished doubles match whose result carries only the places.
    private func doubles(
        partner: GroupMatchSeat.Occupant, name: String = "Priya", won: Bool
    ) throws -> GroupMatchPresentation {
        let you = GroupMatchFixtures.Player.you.seatID
        let seats = [
            GroupMatchSeat(id: you, number: 1, name: "You",
                           occupant: .person(profileID: UUID(), invite: .accepted), team: 1),
            GroupMatchSeat(id: UUID(), number: 2, name: name, occupant: partner, team: 1),
            GroupMatchSeat(id: UUID(), number: 3, name: "Leo",
                           occupant: .person(profileID: UUID(), invite: .accepted), team: 2),
            GroupMatchSeat(id: UUID(), number: 4, name: "Maya",
                           occupant: .person(profileID: UUID(), invite: .accepted), team: 2),
        ]
        return try GroupMatchPresentation(
            id: CompetitionID(UUID()),
            lifecycle: .completed(outcome: won ? .win : .loss, basis: .stableAcrossPostBoundaryReads, completedAt: Date()),
            format: .doubles,
            seats: seats,
            viewerSeatID: you,
            days: [try MatchDayScore(seatID: you, ordinal: 1, value: .centipoints(50_000))],
            frozenStandings: [
                GroupMatchStandingRow(subject: .team(won ? 1 : 2), place: 1, centipoints: 300_000),
                GroupMatchStandingRow(subject: .team(won ? 2 : 1), place: 2, centipoints: 200_000),
            ]
        )
    }
}
#endif
