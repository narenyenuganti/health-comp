import CompetitionCore
@testable import HealthComp
import XCTest

final class GroupMatchLineupTests: XCTestCase {
    private let sam = GroupMatchPlayer(profileID: UUID(), name: "Sam")
    private let priya = GroupMatchPlayer(profileID: UUID(), name: "Priya")

    func testRemovingAFourWaySeatMakesAThreeWayAndCreateNeedsAnotherPerson() {
        var lineup = GroupMatchLineup(format: .fourWay, entries: [.bot(.erratic)])
        XCTAssertFalse(lineup.canRemoveSeat(0), "A filled seat empties first.")
        lineup.remove(seat: 2)
        XCTAssertEqual(lineup.format, .threeWay)
        XCTAssertFalse(lineup.canRemoveSeat(1), "A three-way keeps three seats.")
        lineup.add(.bot(.beast), team: nil)
        XCTAssertFalse(lineup.canCreate, "You and bots alone is practice.")
        lineup.remove(seat: 1)
        lineup.add(.person(sam), team: nil)
        XCTAssertTrue(lineup.canCreate)
        XCTAssertEqual(lineup.draft, GroupMatchDraft(format: .threeWay, seats: [
            .bot(.erratic, team: nil), .person(profileID: sam.profileID, team: nil),
        ]))
    }

    func testDoublesSendsBothTeams() {
        var lineup = GroupMatchLineup(format: .doubles)
        XCTAssertEqual(lineup.openTeams, [1, 2])
        lineup.add(.person(sam), team: 2)
        lineup.add(.person(priya), team: 1)
        lineup.add(.bot(.pacer), team: 2)
        XCTAssertEqual(lineup.openTeams, [])
        XCTAssertFalse(lineup.canRemoveSeat(2))
        XCTAssertEqual(lineup.draft, GroupMatchDraft(format: .doubles, seats: [
            .person(profileID: priya.profileID, team: 1),
            .person(profileID: sam.profileID, team: 2),
            .bot(.pacer, team: 2),
        ]))
    }

    func testAPastedLinkCountsAsAPersonAndSendsItsCode() throws {
        let code = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Mx7kQ2pL9vR4tN8wB3cY6z"))
        var lineup = GroupMatchLineup(format: .threeWay, entries: [.bot(.chill)])
        XCTAssertFalse(lineup.canCreate)
        lineup.add(.linked(code, name: "Maya"), team: nil)
        XCTAssertTrue(lineup.canCreate)
        XCTAssertEqual(lineup.draft, GroupMatchDraft(format: .threeWay, seats: [
            .bot(.chill, team: nil), .challengeLink(code, team: nil),
        ]))
    }

    func testAScheduledMatchStaysInTheLobbyUntilDayOne() throws {
        func threeWay(_ lifecycle: LocalCompetitionLifecyclePresentation) throws -> GroupMatchPresentation {
            let you = UUID()
            return try GroupMatchPresentation(
                id: CompetitionID(UUID()),
                lifecycle: lifecycle,
                format: .threeWay,
                seats: [
                    GroupMatchSeat(id: you, number: 1, name: "You", occupant: .person(profileID: UUID(), invite: .accepted)),
                    GroupMatchSeat(id: UUID(), number: 2, name: "Sam", occupant: .person(profileID: sam.profileID, invite: .accepted)),
                    GroupMatchSeat(id: UUID(), number: 3, name: "Chill", occupant: .bot(.chill)),
                ],
                viewerSeatID: you
            )
        }
        XCTAssertEqual(try threeWay(.scheduled).screen, .lobby)
        XCTAssertEqual(try threeWay(.active(dayOrdinal: 1)).screen, .liveFreeForAll)
    }

    func testANewMatchKeepsTheSameSetupAndYourPartnerFirst() throws {
        let you = UUID(), them = UUID(), partner = UUID(), bot = UUID()
        let match = try GroupMatchPresentation(
            id: CompetitionID(UUID()),
            lifecycle: .expired(at: .distantPast, direction: .outgoing),
            format: .doubles,
            seats: [
                GroupMatchSeat(id: you, number: 1, name: "You", occupant: .person(profileID: UUID(), invite: .accepted), team: 1),
                GroupMatchSeat(id: them, number: 2, name: "Sam", occupant: .person(profileID: sam.profileID, invite: .accepted), team: 2),
                GroupMatchSeat(id: partner, number: 3, name: "Priya", occupant: .person(profileID: priya.profileID, invite: .invited), team: 1),
                GroupMatchSeat(id: bot, number: 4, name: "Chill", occupant: .bot(.chill), team: 2),
            ],
            viewerSeatID: you
        )
        let lineup = GroupMatchLineup(match: match)
        XCTAssertEqual(lineup.format, .doubles)
        XCTAssertEqual(lineup.seats, [.person(priya), .person(sam), .bot(.chill)])
    }
}
