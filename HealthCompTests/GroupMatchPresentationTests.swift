#if DEBUG
import CompetitionCore
import ComposableArchitecture
import XCTest
@testable import HealthComp

@MainActor
final class GroupMatchPresentationTests: XCTestCase {
    private typealias Fixtures = GroupMatchFixtures
    private typealias Player = GroupMatchFixtures.Player

    private func fixture(_ setup: GroupMatchLabSetup) -> GroupMatchPresentation {
        Fixtures.routed(setup)!
    }

    private func dashboard(
        _ groupMatches: [GroupMatchPresentation],
        issues: [LocalCompetitionClientIssue] = []
    ) -> LocalCompetitionDashboard {
        LocalCompetitionDashboard(
            competitions: [], awards: [], issues: issues,
            hiddenTerminalCompetitionCount: 0, groupMatches: groupMatches
        )
    }

    /// Four-way on Day 1 with these scores; missing players are unsynced.
    private func dayOne(
        _ points: [Player: Int],
        format: GroupMatchFormat = .fourWay,
        teams: [Player: Int] = [:],
        unavailable: [Player] = [],
        leaveCutoffs: [Player: Int] = [:]
    ) throws -> GroupMatchPresentation {
        let lineup: [Player] = [.you, .sam, .priya, .leo]
        return try GroupMatchPresentation(
            id: CompetitionID(UUID()),
            lifecycle: .active(dayOrdinal: 1),
            format: format,
            seats: lineup.enumerated().map { index, player in
                GroupMatchSeat(
                    id: player.seatID, number: index + 1, name: player.name,
                    occupant: .person(profileID: player.profileID, invite: .accepted),
                    team: teams[player]
                )
            },
            viewerSeatID: Player.you.seatID,
            days: try points.map {
                try MatchDayScore(seatID: $0.key.seatID, ordinal: 1, value: .centipoints($0.value))
            } + unavailable.map {
                try MatchDayScore(seatID: $0.seatID, ordinal: 1, value: .unavailable)
            },
            leaveCutoffs: Dictionary(uniqueKeysWithValues: leaveCutoffs.map { ($0.key.seatID, $0.value) })
        )
    }

    // MARK: Banter

    func testBanterShowsFromDayThreeAndPostsOnceAt8PMMatchTime() throws {
        let match = fixture(.banter)
        let line = try XCTUnwrap(match.banter)
        XCTAssertFalse(line.isEmpty)
        // Quiet on Days 1 and 2, whatever the scores.
        XCTAssertNil(try dayOne([.you: 0, .sam: 60_000, .priya: 0, .leo: 0]).banter)

        // Lab now is 1 AM Sunday in Los Angeles; Day 4's line posts at 8 PM there.
        let snapshot = CompetitionNotificationPlanningSnapshot(
            publicationRevision: 1,
            evaluatedAt: MultiUserCompetitionTestLabFixtures.labNow,
            timeZoneIdentifier: "America/Los_Angeles",
            competitions: [],
            groupMatches: [match]
        )
        let planner = CompetitionNotificationPlanner(policy: .liveV1)
        let plan = try planner.plan(snapshot, authorization: .authorized, mutedOpponentIdentities: [])
        let request = try XCTUnwrap(plan.desiredScheduledRequests.first)
        XCTAssertEqual(plan.desiredScheduledRequests.count, 1)
        XCTAssertEqual(request.identifier, CompetitionNotificationIdentifier.scheduled(competitionID: match.id, family: .groupBanter))
        XCTAssertEqual(request.content, CompetitionNotificationContent(title: "Doubles, Day 4", body: line))
        XCTAssertEqual(request.dateComponents.date, Date(timeIntervalSince1970: 1_786_935_600))

        XCTAssertTrue(try planner.plan(
            snapshot, authorization: .authorized, mutedOpponentIdentities: [], switchedOff: [.groupBanter]
        ).desiredScheduledRequests.isEmpty)
        XCTAssertTrue(try planner.plan(
            CompetitionNotificationPlanningSnapshot(
                publicationRevision: 1, evaluatedAt: Date(timeIntervalSince1970: 1_786_935_600),
                timeZoneIdentifier: "America/Los_Angeles", competitions: [], groupMatches: [match]
            ),
            authorization: .authorized, mutedOpponentIdentities: []
        ).desiredScheduledRequests.isEmpty, "not after 8 PM")
    }

    // MARK: Projections

    func testTiedFirstSharesThePlaceAndTheNextIsThird() {
        XCTAssertEqual(fixture(.resultFFATied).standingRows.map(\.place), [1, 1, 3, 4])
    }

    func testLiveLeadTargetsTheNextPlaceUp() {
        XCTAssertEqual(fixture(.liveFFA).leadText, "You're 2nd. 48 behind Sam.")
    }

    func testAGapSmallerThanAPointIsNotShownAsZero() throws {
        let match = try dayOne([.you: 10_000, .sam: 10_001, .priya: 0, .leo: 0])
        XCTAssertEqual(match.lead, .chasing(place: 2, gap: 1, behind: [.seat(Player.sam.seatID)]))
        XCTAssertEqual(match.leadText, "You're 2nd. 0.01 behind Sam.")
    }

    func testLeadNamesEveryoneTiedOnTheNextPlace() throws {
        let match = try dayOne([.you: 100, .sam: 300, .priya: 300, .leo: 0])
        XCTAssertEqual(match.leadText, "You're 3rd. 2 behind Sam and Priya.")
    }

    func testFirstAloneLeadsAndTiedFirstNeverSaysYouLead() throws {
        XCTAssertEqual(try dayOne([.you: 500, .sam: 300, .priya: 0, .leo: 0]).leadText, "You lead by 2.")
        XCTAssertEqual(
            try dayOne([.you: 500, .sam: 500, .priya: 0, .leo: 0]).leadText,
            "Tied for 1st with Sam."
        )
    }

    func testDoublesLeadIsTheTeams() {
        let match = fixture(.liveDoubles)
        XCTAssertEqual(match.viewerSubject, .team(1))
        XCTAssertEqual(match.leadText, "Your team leads by 247.")
        XCTAssertEqual(match.name(of: .team(1)), "You + Priya")
        XCTAssertEqual(match.name(of: .team(2)), "Sam + Leo")
    }

    func testCarryIsTheSeatsShareOfItsTeam() throws {
        let match = fixture(.liveDoubles)
        XCTAssertEqual(match.carryPercent(seatID: Player.you.seatID), 53)
        XCTAssertEqual(match.carryPercent(seatID: Player.leo.seatID), 41)
        XCTAssertNil(fixture(.liveFFA).carryPercent(seatID: Player.you.seatID))
        let empty = try dayOne(
            [.you: 0, .sam: 0, .priya: 0, .leo: 0],
            format: .doubles,
            teams: [.you: 1, .priya: 1, .sam: 2, .leo: 2]
        )
        XCTAssertNil(empty.carryPercent(seatID: Player.you.seatID))
    }

    func testDayWinnersShareTiesAndWaitForEverySeat() throws {
        let tied = try dayOne([.you: 500, .sam: 500, .priya: 0, .leo: 0])
        XCTAssertEqual(
            tied.dayWinners(ordinal: 1),
            .winners(tied.standingRows.filter { $0.place == 1 }.map(\.subject))
        )
        XCTAssertEqual(try dayOne([.you: 500, .sam: 500]).dayWinners(ordinal: 1), .unresolved)
    }

    func testALeaveCutoffReachesScoring() throws {
        // Leo left after Day 1 with nothing synced: that day is a banked zero, not pending.
        let match = try dayOne([.you: 500, .sam: 300, .priya: 100], leaveCutoffs: [.leo: 1])
        XCTAssertFalse(match.projection.isProvisional)
        XCTAssertEqual(match.dayWinners(ordinal: 1), .winners([.seat(Player.you.seatID)]))
    }

    func testAnUnavailableDayLeavesTheDayUndecided() throws {
        let match = try dayOne([.you: 500, .sam: 300, .priya: 100], unavailable: [.leo])
        XCTAssertTrue(match.projection.isProvisional)
        XCTAssertEqual(match.dayWinners(ordinal: 1), .unresolved)
    }

    func testABotsLaterDaysDontCountYet() throws {
        let fixed = fixture(.liveBot)
        let dayTwo = try GroupMatchPresentation(
            id: fixed.id, lifecycle: .active(dayOrdinal: 2), format: fixed.format,
            seats: fixed.seats, viewerSeatID: fixed.viewerSeatID, days: fixed.days
        )
        XCTAssertEqual(dayTwo.projection.seatTotals[Player.erratic.seatID], 70_000)
    }

    func testAFinishedMatchShowsTheServersStandingsAsIs() throws {
        let live = fixture(.liveFFA)
        let frozen = [GroupMatchStandingRow(subject: .seat(Player.leo.seatID), place: 1, centipoints: 7)]
        let finished = try GroupMatchPresentation(
            id: live.id,
            lifecycle: .completed(outcome: .loss, basis: .bestAvailable, completedAt: .distantPast),
            format: live.format,
            seats: live.seats,
            viewerSeatID: live.viewerSeatID,
            frozenStandings: frozen
        )
        XCTAssertEqual(finished.standingRows, frozen)
        XCTAssertNil(finished.lead)
    }

    func testRosterThatDoesNotFitTheFormatIsRefused() {
        let live = fixture(.liveFFA)
        XCTAssertThrowsError(try GroupMatchPresentation(
            id: live.id, lifecycle: live.lifecycle, format: .threeWay,
            seats: live.seats, viewerSeatID: live.viewerSeatID
        ))
    }

    func testEveryLabSetupBuilds() {
        for setup in GroupMatchLabSetup.allCases {
            _ = Fixtures.routed(setup)
        }
        for ring in fixture(.liveBot).rings {
            XCTAssertNotEqual(ring.seatID, Player.erratic.seatID, "Bots never have rings.")
        }
    }

    // MARK: Routing

    func testEachLifecycleOpensItsScreen() {
        XCTAssertEqual(fixture(.lobbyHost).screen, .lobby)
        XCTAssertEqual(fixture(.lobbyDeclined).screen, .lobby)
        XCTAssertEqual(fixture(.inviteFFA).screen, .invite)
        XCTAssertEqual(fixture(.liveFFA).screen, .liveFreeForAll)
        XCTAssertEqual(fixture(.liveDoubles).screen, .liveDoubles)
        XCTAssertEqual(fixture(.resultFFAWon).screen, .result)
    }

    func testAPathToAGroupMatchSurvivesAPublication() async {
        let match = fixture(.liveFFA)
        let publication = LocalCompetitionPublication(
            publicationRevision: 2, dashboard: dashboard([match])
        )
        let store = TestStore(initialState: MainTabFeature.State(path: [match.id])) {
            MainTabFeature()
        }
        store.exhaustivity = .off
        await store.send(.competition(.publication(publication)))
        store.assert { $0.path = [match.id] }
    }

    // MARK: Staying out of duels

    func testAGroupMatchReachesNoDuelSurface() {
        let duels = MultiUserCompetitionTestLabFixtures.publication(archivedIDs: []).dashboard
        let mixed = LocalCompetitionDashboard(
            competitions: duels.competitions, awards: duels.awards, issues: duels.issues,
            hiddenTerminalCompetitionCount: duels.hiddenTerminalCompetitionCount,
            groupMatches: [fixture(.liveFFA), fixture(.resultFFAWon)]
        )
        let now = MultiUserCompetitionTestLabFixtures.labNow
        XCTAssertFalse(competitionHomeLayout(duels, now: now).isEmpty)
        XCTAssertEqual(competitionHomeLayout(mixed, now: now), competitionHomeLayout(duels, now: now))
        // Glance shows the live one through its own field, with no belt or
        // chase; the duel entries are unchanged.
        let glance = CompetitionWidgetSnapshot(dashboard: mixed)
        let duelGlance = CompetitionWidgetSnapshot(dashboard: duels)
        XCTAssertEqual(glance.matches.filter { $0.group == nil }, duelGlance.matches)
        XCTAssertEqual(glance.hasIncomingChallenge, duelGlance.hasIncomingChallenge)
        let groups = glance.matches.filter { $0.group != nil }
        XCTAssertEqual(groups.map(\.id), [fixture(.liveFFA).id.rawValue])
        XCTAssertTrue(groups.allSatisfy { $0.belt == nil && $0.chase == nil && $0.final == nil })
    }

    func testDashboardRebuildsKeepGroupMatches() {
        let match = fixture(.liveFFA)
        let practice = MultiUserCompetitionTestLabFixtures.practicePresentation()
        let withFailure = dashboard([match], issues: [.competitionFailures([practice.id])])
        let previous = LocalCompetitionDashboard(
            competitions: [practice], awards: [], issues: [], hiddenTerminalCompetitionCount: 0
        )
        XCTAssertEqual(
            withFailure.keepingFailedCompetitions(from: previous, now: .distantPast).groupMatches,
            [match]
        )
        XCTAssertEqual(dashboard([match]).addingPractice([practice]).groupMatches, [match])
    }

    func testHomeBoundaryIncludesAGroupInviteExpiry() {
        let now = Date(timeIntervalSince1970: 0)
        let expiry = now.addingTimeInterval(60)
        let match = try! GroupMatchPresentation(
            id: CompetitionID(UUID()),
            lifecycle: .pending(direction: .incoming, createdAt: now, expiresAt: expiry),
            format: .fourWay,
            seats: fixture(.inviteFFA).seats,
            viewerSeatID: Player.you.seatID
        )
        XCTAssertEqual(dashboard([match]).nextHomeBoundary(after: now), expiry)
    }

    func testAGroupResultLeavesHomeLikeADuelResult() {
        let match = fixture(.resultFFAWon)
        let leaves = competitionResultLeavesHome(
            schedule: match.schedule!, completedAt: MultiUserCompetitionTestLabFixtures.labNow
        )?.at
        XCTAssertNotNil(leaves)
        XCTAssertEqual(dashboard([match]).nextHomeBoundary(after: .distantPast), leaves)
    }

    func testPhotoOwnersIncludeEveryPersonInAGroupMatchButNoBot() {
        let publication = LocalCompetitionPublication(
            publicationRevision: 1,
            dashboard: dashboard([fixture(.liveBot)]),
            source: .remoteParticipants
        )
        let owners = CompetitionFeature.State(publication: publication).photoOwners
        XCTAssertEqual(
            Set(owners),
            [Player.you.profileID, Player.sam.profileID, Player.leo.profileID]
        )
    }

    // MARK: Commands

    func testACommandPublishesThroughTheParentAndClearsInFlight() async {
        let match = fixture(.liveFFA)
        let command = GroupMatchCommand.leave(match.id)
        let answer = LocalCompetitionPublication(publicationRevision: 2, dashboard: dashboard([match]))
        let store = TestStore(initialState: CompetitionFeature.State()) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = Self.client { _ in answer }
        }
        await store.send(.group(.commandTapped(command))) {
            $0.group.inFlight = [command]
        }
        await store.receive(.group(.commandFinished(command, answer))) {
            $0.group.inFlight = []
        }
        await store.receive(.group(.delegate(.published(answer))))
        await store.receive(.publication(answer)) {
            $0.publication = answer
        }
    }

    func testAFailedCommandIsRememberedUntilItIsRetried() async {
        let command = GroupMatchCommand.accept(CompetitionID(UUID()))
        let store = TestStore(initialState: GroupMatchFeature.State()) {
            GroupMatchFeature()
        } withDependencies: {
            $0.competitionClient = Self.client { _ in throw CompetitionRemoteFailure.operationFailed }
        }
        await store.send(.commandTapped(command)) { $0.inFlight = [command] }
        await store.receive(.commandFinished(command, nil)) {
            $0.inFlight = []
            $0.failed = [command]
        }
        await store.send(.commandTapped(command)) {
            $0.inFlight = [command]
            $0.failed = []
        }
        await store.receive(.commandFinished(command, nil)) {
            $0.inFlight = []
            $0.failed = [command]
        }
    }

    func testStopDropsAGroupCommandStillInFlight() async {
        let command = GroupMatchCommand.leave(CompetitionID(UUID()))
        let late = LocalCompetitionPublication(publicationRevision: 9, dashboard: dashboard([]))
        let store = TestStore(initialState: CompetitionFeature.State()) {
            CompetitionFeature()
        } withDependencies: {
            // Answers even when cancelled, as a request already sent would.
            $0.competitionClient = Self.client { _ in
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                return late
            }
        }
        await store.send(.group(.commandTapped(command))) {
            $0.group.inFlight = [command]
        }
        await store.send(.stop) {
            $0.group.inFlight = []
        }
        await store.finish()
    }

    func testASecondTapWhileInFlightDoesNothing() async {
        let command = GroupMatchCommand.cancel(CompetitionID(UUID()))
        let store = TestStore(
            initialState: GroupMatchFeature.State(inFlight: [command])
        ) {
            GroupMatchFeature()
        }
        await store.send(.commandTapped(command))
    }

    private static func client(
        _ command: @escaping @Sendable (GroupMatchCommand) async throws -> CompetitionPublication
    ) -> CompetitionClient {
        let empty = LocalCompetitionPublication(
            publicationRevision: 0,
            dashboard: LocalCompetitionDashboard(
                competitions: [], awards: [], issues: [], hiddenTerminalCompetitionCount: 0
            )
        )
        return CompetitionClient(
            start: { AsyncStream { _ in } },
            updates: { AsyncStream { _ in } },
            reconcileAll: { _ in empty },
            accept: { _ in empty },
            decline: { _ in empty },
            archive: { _ in empty },
            rematch: { _ in empty },
            reinvite: { empty },
            waitUntil: { _ in },
            stop: {},
            groupMatchCommand: command
        )
    }
}
#endif
