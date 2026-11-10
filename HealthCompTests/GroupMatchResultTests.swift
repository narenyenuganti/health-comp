#if DEBUG
import CompetitionCore
import ComposableArchitecture
import XCTest
@testable import HealthComp

@MainActor
final class GroupMatchResultTests: XCTestCase {
    func testRematchEveryoneAsksTheParentForTheSameLineup() async {
        let id = GroupMatchFixtures.routed(.resultFFAWon)!.id
        let store = TestStore(initialState: GroupMatchFeature.State()) {
            GroupMatchFeature()
        }
        await store.send(.rematchEveryoneTapped(id))
        await store.receive(.delegate(.rematchEveryone(id)))
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
