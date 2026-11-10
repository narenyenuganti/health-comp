#if DEBUG
import CompetitionCore
import XCTest
@testable import HealthComp

/// Home, the versus intro and glance for group matches, from the lab fixtures.
final class GroupMatchGlanceTests: XCTestCase {
    private func fixture(_ setup: GroupMatchLabSetup) -> GroupMatchPresentation {
        GroupMatchFixtures.routed(setup)!
    }

    // MARK: Glance

    func testFreeForAllGlanceIsYourPlaceAndTheGapWithTheNextPlaceUpAsTheFallback() throws {
        let match = try XCTUnwrap(CompetitionWidgetSnapshot.Match(group: fixture(.liveFFA)))
        let group = try XCTUnwrap(match.group)
        XCTAssertEqual(group.title, "Four-Way")
        XCTAssertEqual(group.rows.map(\.name), ["Sam", "You", "Priya", "Leo"])
        XCTAssertEqual(group.rows.map(\.points), [1_712, 1_664, 1_498, 1_203])
        XCTAssertEqual(group.yourPlace, 2)
        XCTAssertEqual(group.lead, "48 behind Sam")
        XCTAssertEqual(match.groupPlaceText, "2nd")
        // What an older watch draws: you against Sam.
        XCTAssertEqual(match.name, "Sam")
        XCTAssertEqual(match.userPoints, 1_664)
        XCTAssertEqual(match.opponentPoints, 1_712)
        XCTAssertEqual(Array(match.userDayPoints.prefix(4)), [421, 437, 398, 408])
        XCTAssertTrue(match.personID.hasPrefix("group:"))
        XCTAssertNil(match.belt)
        XCTAssertNil(match.chase)
        XCTAssertNil(match.final)
    }

    func testDoublesGlanceIsTheTwoTeamTotals() throws {
        let match = try XCTUnwrap(CompetitionWidgetSnapshot.Match(group: fixture(.liveDoubles)))
        let group = try XCTUnwrap(match.group)
        XCTAssertTrue(group.isDoubles)
        XCTAssertEqual(group.rows.map(\.name), ["You + Priya", "Sam + Leo"])
        XCTAssertEqual(group.lead, "Your team up 247")
        XCTAssertNil(match.groupPlaceText)
        XCTAssertEqual(match.name, "Sam + Leo")
        XCTAssertEqual(match.userPoints, 3_162)
        XCTAssertEqual(match.opponentPoints, 2_915)
        XCTAssertEqual(match.userDayPoints[0], 801)
    }

    func testOnlyALiveGroupMatchReachesGlance() {
        for setup in [GroupMatchLabSetup.lobbyHost, .inviteFFA, .lobbyDeclined, .resultFFAWon, .resultDoubles, .versusFFA] {
            XCTAssertNil(CompetitionWidgetSnapshot.Match(group: fixture(setup)), setup.rawValue)
        }
    }

    func testTheGroupFieldKeepsTheVersionAndOldFilesStillDecode() throws {
        let now = MultiUserCompetitionTestLabFixtures.labNow
        let snapshot = try XCTUnwrap(CompetitionWidgetSnapshot.testLab("groupFFA", now: now, scheme: "healthcomp"))
        XCTAssertEqual(snapshot.version, 2)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(CompetitionWidgetSnapshot.self, from: data), snapshot)
        // A file written before the field existed.
        let old = try XCTUnwrap(CompetitionWidgetSnapshot.testLab("live", now: now, scheme: "healthcomp"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        XCTAssertNil((json["matches"] as? [[String: Any]])?.first?["group"])
        json["version"] = 2
        let decoded = try JSONDecoder().decode(
            CompetitionWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.matches.first?.group)
    }

    func testGroupWordingOnEverySurfaceAndNoPersonToPick() throws {
        let now = MultiUserCompetitionTestLabFixtures.labNow
        let ffa = try XCTUnwrap(CompetitionWidgetSnapshot.testLab("groupFFA", now: now, scheme: "healthcomp"))
        let match = try XCTUnwrap(ffa.matches.first)
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(match.groupHeader(at: now, locale: locale), "Four-Way · Day 4")
        XCTAssertEqual(
            match.accessibilityLabel(at: now, redacted: false, locale: locale),
            "Four-Way, Day 4 of 7. You're 2nd. 48 behind Sam."
        )
        XCTAssertEqual(match.accessibilityLabel(at: now, redacted: true, locale: locale), "HealthComp, Day 4.")
        XCTAssertEqual(match.rectangularLines(at: now, locale: locale).first, ["Four-Way · Day 4", "Four-Way"])
        XCTAssertEqual(match.rectangularLines(at: now, locale: locale).last, ["2nd · 48 behind Sam", "2nd"])
        XCTAssertEqual(match.circular(at: now, locale: locale).value, "2ND")
        XCTAssertEqual(match.inlineText(at: now, locale: locale), "2ND · Day 4 · Four-Way")
        XCTAssertEqual(match.cornerLabel(at: now, locale: locale), "DAY 4 · FOUR-WAY")
        XCTAssertNil(match.beltAccessibilityText)
        XCTAssertNil(match.beltCardText)
        XCTAssertTrue(ffa.suggestedPeople().isEmpty)

        let doubles = try XCTUnwrap(
            CompetitionWidgetSnapshot.testLab("groupDoubles", now: now, scheme: "healthcomp")?.matches.first
        )
        XCTAssertEqual(
            doubles.accessibilityLabel(at: now, redacted: false, locale: locale),
            "Doubles, Day 4 of 7. Your team 3,162 points. Sam + Leo 2,915 points. Your team up 247."
        )
    }

    // MARK: Versus intro

    func testIntroPutsYouFirstAndNamesTheDay() throws {
        let locale = Locale(identifier: "en_US")
        let ffa = try XCTUnwrap(groupMatchVersusIntroContent(
            fixture(.versusFFA), source: .remoteParticipants, locale: locale
        ))
        XCTAssertEqual(ffa.panels.map { $0.map(\.name) }, [["You"], ["Sam"], ["Priya"], ["Leo"]])
        XCTAssertEqual(ffa.footer, "Day 1 is Thursday. Most points after seven days wins.")
        XCTAssertEqual(
            ffa.announcement,
            "Four-Way. You, Sam, Priya, and Leo. Day 1 is Thursday. Most points after seven days wins."
        )

        let doubles = try XCTUnwrap(groupMatchVersusIntroContent(
            fixture(.versusDoubles), source: .remoteParticipants, locale: locale
        ))
        XCTAssertEqual(doubles.panels.map { $0.map(\.name) }, [["You", "Priya"], ["Sam", "Leo"]])
        XCTAssertEqual(doubles.footer, "Day 1 is Thursday. Partners’ points add up.")

        let bot = try XCTUnwrap(groupMatchVersusIntroContent(fixture(.versusBot), source: .remoteParticipants))
        XCTAssertEqual(bot.panels.joined().filter(\.isBot).map(\.name), ["Erratic"])
    }

    func testIntroAutoplaysOnlyBeforeDayTwoAndReplaysLater() {
        XCTAssertNil(groupMatchVersusIntroContent(fixture(.versusFFA), source: .simulatedFixture))
        XCTAssertNil(groupMatchVersusIntroContent(fixture(.liveFFA), source: .remoteParticipants))
        XCTAssertNil(groupMatchVersusIntroContent(fixture(.lobbyHost), source: .remoteParticipants, isReplay: true))
        XCTAssertEqual(
            groupMatchVersusIntroContent(
                fixture(.liveFFA), source: .remoteParticipants, locale: Locale(identifier: "en_US"), isReplay: true
            )?.footer,
            "Day 4 of 7. Most points after seven days wins."
        )
    }

    // MARK: Home

    private let now = MultiUserCompetitionTestLabFixtures.labNow

    func testHomeShowsEveryStateInOrder() {
        let matches = GroupMatchFixtures.homeSetups.map(fixture)
        XCTAssertEqual(GroupMatchHomeCards.shown(matches, now: now).map(\.id), matches.map(\.id))
        // Whatever order the dashboard brings.
        XCTAssertEqual(GroupMatchHomeCards.shown(matches.reversed(), now: now).map(\.id), [
            GroupMatchLabSetup.inviteFFA, .lobbyHost, .liveDoubles, .liveFFA, .resultDoubles, .resultFFAWon,
            .lobbyDeclined,
        ].map { fixture($0).id })
    }

    func testResultsAndClosedMatchesLeaveHomeOnTheDuelsClock() throws {
        let result = fixture(.resultFFAWon)
        guard case let .completed(_, _, completedAt) = result.lifecycle else { return XCTFail() }
        let leaves = try XCTUnwrap(
            competitionResultLeavesHome(schedule: XCTUnwrap(result.schedule), completedAt: completedAt)?.at
        )
        XCTAssertEqual(GroupMatchHomeCards.shown([result], now: leaves.addingTimeInterval(-1)).count, 1)
        XCTAssertTrue(GroupMatchHomeCards.shown([result], now: leaves).isEmpty)

        let closed = fixture(.lobbyDeclined)
        let retained = now.addingTimeInterval(competitionClosedChallengeRetention)
        XCTAssertEqual(GroupMatchHomeCards.shown([closed], now: retained.addingTimeInterval(-1)).count, 1)
        XCTAssertTrue(GroupMatchHomeCards.shown([closed], now: retained).isEmpty)
    }

    func testALeftMatchLeavesHomeAndGlanceButKeepsItsScreenAndPoints() throws {
        let left = try XCTUnwrap(GroupMatchFixtures.routed(.liveFFA, youLeft: true))
        XCTAssertTrue(GroupMatchHomeCards.shown([left], now: now).isEmpty)
        XCTAssertNil(CompetitionWidgetSnapshot.Match(group: left))
        XCTAssertEqual(left.screen, .liveFreeForAll)
        XCTAssertEqual(left.projection.seatTotals[GroupMatchFixtures.Player.you.seatID], 166_400)
        let doubles = try XCTUnwrap(GroupMatchFixtures.routed(.liveDoubles, youLeft: true))
        XCTAssertTrue(GroupMatchHomeCards.shown([doubles], now: now).isEmpty)
        XCTAssertNil(CompetitionWidgetSnapshot.Match(group: doubles))
    }

    // MARK: Privacy

    func testOnlyALoneYouShowsOnALockedScreen() throws {
        let doubles = try XCTUnwrap(CompetitionWidgetSnapshot.Match(group: fixture(.liveDoubles))?.group)
        XCTAssertEqual(doubles.rows.map(\.namesSomeone), [true, true])  // "You + Priya", "Sam + Leo"
        let ffa = try XCTUnwrap(CompetitionWidgetSnapshot.Match(group: fixture(.liveFFA))?.group)
        XCTAssertEqual(ffa.rows.map(\.namesSomeone), [true, false, true, true])
    }
}
#endif
