import CompetitionCore
import Foundation
import XCTest
import UserNotifications
@testable import HealthComp

final class CompetitionNotificationPlannerTests: XCTestCase {
    func testLivePolicyV1OwnsTimingBudgetPriorityAndPrivacyCopy() throws {
        let policy = CompetitionNotificationPolicy.liveV1
        let timeZoneIdentifier = "America/Los_Angeles"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: timeZoneIdentifier)
        )
        let base = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 10,
                    hour: 0
                )
            )
        )

        XCTAssertEqual(policy.maximumPostsPerEvaluation, 1)
        XCTAssertEqual(policy.maximumPostsPerCompetitionDay, 2)
        XCTAssertEqual(
            policy.scheduledFireDate(
                .inviteExpiry,
                base,
                timeZoneIdentifier
            ),
            base.addingTimeInterval(-14_400)
        )
        let start = try XCTUnwrap(
            policy.scheduledFireDate(
                .scheduledStart,
                base,
                timeZoneIdentifier
            )
        )
        XCTAssertEqual(calendar.component(.hour, from: start), 9)
        XCTAssertEqual(calendar.component(.minute, from: start), 0)
        let takes = try XCTUnwrap(
            policy.scheduledFireDate(.whatItTakes, base, timeZoneIdentifier)
        )
        XCTAssertEqual(calendar.component(.hour, from: takes), 19)
        XCTAssertEqual(calendar.component(.minute, from: takes), 0)
        XCTAssertTrue(policy.isCloseScore(1_000, 1_050, 5))
        XCTAssertFalse(policy.isCloseScore(1_000, 1_051, 5))
        XCTAssertFalse(policy.isCloseScore(1_000, 1_050, 4))
        XCTAssertFalse(policy.isCloseScore(250, 290, 6))
        XCTAssertTrue(policy.isDailyMaximum(600))
        XCTAssertGreaterThan(
            policy.priority(.result),
            policy.priority(.dailyMaximum)
        )
        XCTAssertGreaterThan(
            policy.priority(.dailyMaximum),
            policy.priority(.closeScore)
        )
        XCTAssertGreaterThan(
            policy.priority(.closeScore),
            policy.priority(.leadChange)
        )

        let scheduled = policy.content(
            CompetitionNotificationMessage(
                family: .scheduled(.finalDay),
                competitionID: competitionID(
                    "EAD172F8-531D-4327-823D-E82A4F696040"
                ),
                opponentDisplayName: "Alex",
                ownerPoints: 4_000,
                opponentPoints: 3_000,
                outcome: nil
            )
        )
        XCTAssertFalse(scheduled.title.contains("4000"))
        XCTAssertFalse(scheduled.body.contains("3000"))

        let result = CompetitionNotificationPolicy.liveV1Content(
            CompetitionNotificationMessage(
                family: .opportunistic(.result),
                competitionID: competitionID(
                    "EAD172F8-531D-4327-823D-E82A4F696040"
                ),
                opponentDisplayName: "Alex",
                ownerPoints: 4_200,
                opponentPoints: 3_900,
                outcome: .win
            ),
            locale: Locale(identifier: "en_US")
        )
        XCTAssertEqual(result.title, "The judges’ scorecards are in")
        XCTAssertEqual(result.body, "Seven rounds with Alex. Open to hear the decision.")
    }

    func testLivePolicyV1UsesTheUsersLocaleAndWholePoints() {
        let content = CompetitionNotificationPolicy.liveV1Content(
            message(.opportunistic(.leadChange), 1_217.4, 1_194),
            locale: Locale(identifier: "de_DE")
        )
        XCTAssertEqual(content.title, "You took the lead")
        XCTAssertEqual(content.body, "You 1.217, Alex 1.194.")
    }

    func testLivePolicyV1LifecycleTitlesMatchTheStatusFormatter() {
        func title(
            _ family: CompetitionNotificationMessageFamily,
            outcome: CompetitionOutcome? = nil
        ) -> String {
            CompetitionNotificationPolicy.liveV1Content(
                message(family, nil, nil, outcome),
                locale: Locale(identifier: "en_US")
            ).title
        }
        func formatter(_ lifecycle: LocalCompetitionLifecyclePresentation) -> String {
            competitionStatusText(
                lifecycle,
                schedule: nil,
                opponentDisplayName: "Alex",
                style: .notification
            ).title
        }
        XCTAssertEqual(title(.scheduled(.finalDay)), "Last day")
        XCTAssertEqual(title(.scheduled(.finalDay)), formatter(.endsToday))
        XCTAssertEqual(title(.scheduled(.competitionEnded)), "Judges are tallying…")
        XCTAssertEqual(title(.scheduled(.scheduledStart)), "Day 1 of 7")
        XCTAssertEqual(
            title(.scheduled(.scheduledStart)),
            formatter(.active(dayOrdinal: 1))
        )
        for outcome in [CompetitionOutcome.win, .loss, .tie] {
            XCTAssertEqual(title(.opportunistic(.result), outcome: outcome), "The judges’ scorecards are in")
        }
    }

    func testResultTeaserDoesNotRevealEvenAFractionalWinner() {
        let content = CompetitionNotificationPolicy.liveV1Content(
            message(.opportunistic(.result), 412.3, 412.0, .win),
            locale: Locale(identifier: "en_US")
        )
        XCTAssertEqual(content.body, "Seven rounds with Alex. Open to hear the decision.")
    }

    private func message(
        _ family: CompetitionNotificationMessageFamily,
        _ ownerPoints: Double?,
        _ opponentPoints: Double?,
        _ outcome: CompetitionOutcome? = nil
    ) -> CompetitionNotificationMessage {
        CompetitionNotificationMessage(
            family: family,
            competitionID: competitionID("EAD172F8-531D-4327-823D-E82A4F696040"),
            opponentDisplayName: "Alex",
            ownerPoints: ownerPoints,
            opponentPoints: opponentPoints,
            outcome: outcome
        )
    }

    func testDeterministicIdentifiersUseCanonicalNamespace() throws {
        let id = competitionID("EAD172F8-531D-4327-823D-E82A4F696040")

        XCTAssertEqual(
            CompetitionNotificationIdentifier.scheduled(
                competitionID: id,
                family: .finalDay
            ),
            "competition-notification:v1:ead172f8-531d-4327-823d-e82a4f696040:final-day"
        )

        let emission = try NotificationEmissionRecorded(
            competitionID: id,
            family: .closeScore,
            episodeKey: .day(4),
            disposition: .emitted,
            decidedAt: Date(timeIntervalSinceReferenceDate: 4_000),
            basisPublicationRevision: 7
        )
        XCTAssertEqual(
            CompetitionNotificationIdentifier.opportunistic(emission),
            emission.semanticEventID
        )
    }

    func testDeniedAuthorizationDoesNotBurnAnEmissionID() throws {
        let snapshot = try planningSnapshot(
            lifecycle: .active(dayOrdinal: 4),
            currentDayOrdinal: 4,
            latestRefresh: .completed,
            ownerPoints: 1_200,
            opponentPoints: 1_190
        )
        let planner = CompetitionNotificationPlanner(policy: .fixture)

        let plan = try planner.plan(
            snapshot,
            authorization: .denied,
            mutedOpponentIdentities: []
        )

        XCTAssertTrue(plan.desiredScheduledRequests.isEmpty)
        XCTAssertTrue(plan.emissionDecisions.isEmpty)
        XCTAssertTrue(plan.suppressionRecords.isEmpty)
    }

    func testMuteAppliesAcrossCompetitionIDsForOneOpponentIdentity() throws {
        let first = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696041"),
            lifecycle: .scheduled
        )
        let rematch = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696042"),
            lifecycle: .scheduled
        )
        let snapshot = CompetitionNotificationPlanningSnapshot(
            publicationRevision: 8,
            evaluatedAt: fixedDate,
            timeZoneIdentifier: "UTC",
            competitions: [first, rematch]
        )

        let plan = try CompetitionNotificationPlanner(policy: .fixture).plan(
            snapshot,
            authorization: .authorized,
            mutedOpponentIdentities: [opponentIdentity]
        )

        XCTAssertTrue(plan.desiredScheduledRequests.isEmpty)
        XCTAssertTrue(plan.emissionDecisions.isEmpty)
        XCTAssertEqual(plan.cancelCompetitionIDs, Set([first.id, rematch.id]))
    }

    func testTallyingBeforeEndFireKeepsRequestWhileCompletedDoesNot()
        throws {
        let tallying = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696049"),
            lifecycle: .tallying
        )
        let completed = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696050"),
            lifecycle: .completed
        )
        let schedule = try XCTUnwrap(tallying.schedule)
        let days = try schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        )
        let endDay = try schedule.calendar.day(after: days[6])
        let endBase = try schedule.calendar.startOfDay(endDay)
        let fireDate = try XCTUnwrap(
            CompetitionNotificationPolicy.liveV1.scheduledFireDate(
                .competitionEnded,
                endBase,
                schedule.calendar.timeZoneIdentifier
            )
        )
        let snapshot = CompetitionNotificationPlanningSnapshot(
            publicationRevision: 15,
            evaluatedAt: fireDate.addingTimeInterval(-3_600),
            timeZoneIdentifier: "UTC",
            competitions: [tallying, completed]
        )

        let plan = try CompetitionNotificationPlanner(policy: .liveV1).plan(
            snapshot,
            authorization: .authorized,
            mutedOpponentIdentities: []
        )

        XCTAssertEqual(
            plan.desiredScheduledRequests.map(\.identifier),
            [
                CompetitionNotificationIdentifier.scheduled(
                    competitionID: tallying.id,
                    family: .competitionEnded
                ),
            ]
        )
        XCTAssertFalse(
            plan.desiredScheduledRequests.contains {
                $0.identifier
                    == CompetitionNotificationIdentifier.scheduled(
                        competitionID: completed.id,
                        family: .competitionEnded
                    )
            }
        )
    }

    func testFailedLatestRefreshNeverProducesExactLeadOrCloseCopy() throws {
        let snapshot = try planningSnapshot(
            lifecycle: .active(dayOrdinal: 4),
            currentDayOrdinal: 4,
            latestRefresh: .failed,
            ownerPoints: 1_200,
            opponentPoints: 1_190
        )

        let plan = try CompetitionNotificationPlanner(policy: .fixture).plan(
            snapshot,
            authorization: .authorized,
            mutedOpponentIdentities: []
        )

        XCTAssertFalse(
            plan.emissionDecisions.contains {
                $0.record.family == .leadChange
                    || $0.record.family == .closeScore
            }
        )
    }

    func testLeadChangeNeedsALeadInTheShownWholePoints() throws {
        func leadChangeFamilies(_ owner: Double, _ opponent: Double) throws -> Int {
            let plan = try CompetitionNotificationPlanner(policy: .fixture).plan(
                try planningSnapshot(
                    lifecycle: .active(dayOrdinal: 4),
                    currentDayOrdinal: 4,
                    latestRefresh: .completed,
                    ownerPoints: owner,
                    opponentPoints: opponent
                ),
                authorization: .authorized,
                mutedOpponentIdentities: []
            )
            return plan.emissionDecisions.filter { $0.record.family == .leadChange }.count
                + plan.suppressionRecords.filter { $0.family == .leadChange }.count
        }
        // 412.4 vs 412.3 reads "412" and "412": no lead to announce.
        XCTAssertEqual(try leadChangeFamilies(412.4, 412.3), 0)
        XCTAssertEqual(try leadChangeFamilies(500, 412.3), 1)
    }

    func testPastDaysWithoutAShownLeadSuppressNoLeadChange() throws {
        let base = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696047"),
            lifecycle: .active(dayOrdinal: 2),
            currentDayOrdinal: 2,
            latestRefresh: .completed,
            evaluationFreshness: .notFresh,
            ownerPoints: 412.4,
            opponentPoints: 412.3
        )
        let competition = CompetitionNotificationCompetitionSnapshot(
            id: base.id,
            opponentIdentity: base.opponentIdentity,
            opponentDisplayName: base.opponentDisplayName,
            lifecycle: base.lifecycle,
            schedule: base.schedule,
            ownerPoints: base.ownerPoints,
            opponentPoints: base.opponentPoints,
            days: [
                .init(ordinal: 1, ownerAcceptedPoints: 412.4, opponentRevealedPoints: 412.3),
                .init(ordinal: 2, ownerAcceptedPoints: 0, opponentRevealedPoints: 0),
            ],
            currentDayOrdinal: 2,
            latestRefresh: .completed,
            evaluationFreshness: .notFresh,
            terminalResult: nil,
            emissionHistory: NotificationEmissionProjection()
        )
        let plan = try CompetitionNotificationPlanner(policy: .fixture).plan(
            CompetitionNotificationPlanningSnapshot(
                publicationRevision: 14,
                evaluatedAt: fixedDate,
                timeZoneIdentifier: "UTC",
                competitions: [competition]
            ),
            authorization: .authorized,
            mutedOpponentIdentities: []
        )
        XCTAssertFalse(plan.suppressionRecords.contains { $0.family == .leadChange })
        XCTAssertFalse(plan.emissionDecisions.contains { $0.record.family == .leadChange })
    }

    func testOldCompletedRefreshOnCommandPublicationProducesNoExactScoreCopy()
        throws {
        let snapshot = try planningSnapshot(
            lifecycle: .active(dayOrdinal: 4),
            currentDayOrdinal: 4,
            latestRefresh: .completed,
            evaluationFreshness: .notFresh,
            ownerPoints: 1_200,
            opponentPoints: 1_190
        )

        let plan = try CompetitionNotificationPlanner(policy: .fixture).plan(
            snapshot,
            authorization: .authorized,
            mutedOpponentIdentities: []
        )

        XCTAssertFalse(
            plan.emissionDecisions.contains {
                $0.record.family == .leadChange
                    || $0.record.family == .closeScore
            }
        )
    }

    func testFailedOrOldReadNeverProducesDailyMaximumCopy() throws {
        for (latestRefresh, freshness) in [
            (
                CompetitionNotificationRefreshState.failed,
                CompetitionNotificationEvaluationFreshness.notFresh
            ),
            (
                CompetitionNotificationRefreshState.completed,
                CompetitionNotificationEvaluationFreshness.notFresh
            ),
        ] {
            let snapshot = try planningSnapshot(
                lifecycle: .active(dayOrdinal: 4),
                currentDayOrdinal: 4,
                latestRefresh: latestRefresh,
                evaluationFreshness: freshness,
                ownerPoints: 1_200,
                opponentPoints: 1_000,
                currentDayOwnerPoints: 600
            )

            let plan = try CompetitionNotificationPlanner(policy: .fixture)
                .plan(
                    snapshot,
                    authorization: .authorized,
                    mutedOpponentIdentities: []
                )

            XCTAssertFalse(
                plan.emissionDecisions.contains {
                    $0.record.family == .dailyMaximum
                }
            )
        }
    }

    func testInjectedPolicyControlsPriorityBudgetAndCopy() throws {
        var policy = CompetitionNotificationPolicy.fixture
        policy.maximumPostsPerEvaluation = 1
        policy.maximumPostsPerCompetitionDay = 1
        policy.priority = { family in
            family == .dailyMaximum ? 100 : 0
        }
        policy.isDailyMaximum = { $0 == 575 }
        policy.content = { message in
            CompetitionNotificationContent(
                title: "fixture-\(message.family.rawValue)",
                body: "policy-owned-copy"
            )
        }
        let snapshot = try planningSnapshot(
            lifecycle: .endsToday,
            currentDayOrdinal: 7,
            latestRefresh: .completed,
            ownerPoints: 1_200,
            opponentPoints: 1_190,
            currentDayOwnerPoints: 575
        )

        let plan = try CompetitionNotificationPlanner(policy: policy).plan(
            snapshot,
            authorization: .authorized,
            mutedOpponentIdentities: []
        )

        XCTAssertEqual(plan.emissionDecisions.count, 1)
        XCTAssertEqual(plan.emissionDecisions.first?.record.family, .dailyMaximum)
        XCTAssertEqual(
            plan.emissionDecisions.first?.request.content.body,
            "policy-owned-copy"
        )
    }

    func testEachMatchHasItsOwnPostCap() throws {
        var policy = CompetitionNotificationPolicy.fixture
        policy.maximumPostsPerEvaluation = 1
        let first = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696047"),
            lifecycle: .active(dayOrdinal: 4),
            currentDayOrdinal: 4,
            latestRefresh: .completed,
            evaluationFreshness: .freshCompletedRefresh(
                attemptID: "first-attempt",
                readAt: fixedDate
            ),
            ownerPoints: 1_200,
            opponentPoints: 1_000,
            currentDayOwnerPoints: 600
        )
        let second = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696048"),
            lifecycle: .active(dayOrdinal: 4),
            currentDayOrdinal: 4,
            latestRefresh: .completed,
            evaluationFreshness: .freshCompletedRefresh(
                attemptID: "second-attempt",
                readAt: fixedDate
            ),
            ownerPoints: 1_100,
            opponentPoints: 1_000,
            currentDayOwnerPoints: 600
        )
        let snapshot = CompetitionNotificationPlanningSnapshot(
            publicationRevision: 14,
            evaluatedAt: fixedDate,
            timeZoneIdentifier: "UTC",
            competitions: [first, second]
        )

        let plan = try CompetitionNotificationPlanner(policy: policy).plan(
            snapshot,
            authorization: .authorized,
            mutedOpponentIdentities: []
        )

        XCTAssertEqual(
            plan.emissionDecisions.filter { $0.record.family == .dailyMaximum }.count,
            2
        )
        XCTAssertFalse(
            plan.suppressionRecords.contains {
                $0.family == .dailyMaximum
                    && $0.disposition == .suppressed(reason: .superseded)
            }
        )
    }

    func testStaleEpisodeIsSuppressedAndCollapsesToOneGenericCatchUp()
        throws {
        var competition = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696044"),
            lifecycle: .active(dayOrdinal: 4),
            currentDayOrdinal: 4,
            latestRefresh: .completed,
            evaluationFreshness: .notFresh,
            ownerPoints: 1_200,
            opponentPoints: 800,
            currentDayOwnerPoints: 100
        )
        competition = CompetitionNotificationCompetitionSnapshot(
            id: competition.id,
            opponentIdentity: competition.opponentIdentity,
            opponentDisplayName: competition.opponentDisplayName,
            lifecycle: competition.lifecycle,
            schedule: competition.schedule,
            ownerPoints: competition.ownerPoints,
            opponentPoints: competition.opponentPoints,
            days: [
                CompetitionNotificationDaySnapshot(
                    ordinal: 2,
                    ownerAcceptedPoints: 600,
                    opponentRevealedPoints: 250
                ),
                CompetitionNotificationDaySnapshot(
                    ordinal: 4,
                    ownerAcceptedPoints: 100,
                    opponentRevealedPoints: 100
                ),
            ],
            currentDayOrdinal: competition.currentDayOrdinal,
            latestRefresh: competition.latestRefresh,
            evaluationFreshness: competition.evaluationFreshness,
            terminalResult: nil,
            emissionHistory: NotificationEmissionProjection()
        )
        let snapshot = CompetitionNotificationPlanningSnapshot(
            publicationRevision: 11,
            evaluatedAt: fixedDate,
            timeZoneIdentifier: "UTC",
            competitions: [competition]
        )

        let plan = try CompetitionNotificationPlanner(policy: .fixture).plan(
            snapshot,
            authorization: .authorized,
            mutedOpponentIdentities: []
        )

        XCTAssertEqual(plan.emissionDecisions.map(\.record.family), [.catchUp])
        XCTAssertEqual(
            Set(plan.suppressionRecords.map(\.family)),
            Set([.dailyMaximum, .leadChange])
        )
        XCTAssertTrue(
            plan.suppressionRecords.allSatisfy {
                $0.disposition == .suppressed(reason: .staleEpisode)
            }
        )
    }

    func testMixedPastFamiliesAreSuppressedBeforeOneCatchUp() throws {
        let base = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696046"),
            lifecycle: .active(dayOrdinal: 4),
            currentDayOrdinal: 4,
            latestRefresh: .completed,
            evaluationFreshness: .notFresh,
            ownerPoints: 900,
            opponentPoints: 900,
            currentDayOwnerPoints: 100
        )
        let competition = CompetitionNotificationCompetitionSnapshot(
            id: base.id,
            opponentIdentity: base.opponentIdentity,
            opponentDisplayName: base.opponentDisplayName,
            lifecycle: base.lifecycle,
            schedule: base.schedule,
            ownerPoints: base.ownerPoints,
            opponentPoints: base.opponentPoints,
            days: [
                .init(
                    ordinal: 1,
                    ownerAcceptedPoints: 100,
                    opponentRevealedPoints: 200
                ),
                .init(
                    ordinal: 2,
                    ownerAcceptedPoints: 600,
                    opponentRevealedPoints: 100
                ),
                .init(
                    ordinal: 3,
                    ownerAcceptedPoints: 100,
                    opponentRevealedPoints: 500
                ),
                .init(
                    ordinal: 4,
                    ownerAcceptedPoints: 100,
                    opponentRevealedPoints: 100
                ),
            ],
            currentDayOrdinal: 4,
            latestRefresh: .completed,
            evaluationFreshness: .notFresh,
            terminalResult: nil,
            emissionHistory: NotificationEmissionProjection()
        )
        let snapshot = CompetitionNotificationPlanningSnapshot(
            publicationRevision: 13,
            evaluatedAt: fixedDate,
            timeZoneIdentifier: "UTC",
            competitions: [competition]
        )

        let plan = try CompetitionNotificationPlanner(policy: .fixture).plan(
            snapshot,
            authorization: .authorized,
            mutedOpponentIdentities: []
        )

        XCTAssertEqual(plan.emissionDecisions.map(\.record.family), [.catchUp])
        XCTAssertEqual(
            Dictionary(
                grouping: plan.suppressionRecords,
                by: \NotificationEmissionRecorded.family
            ).mapValues(\.count),
            [
                .leadChange: 2,
                .dailyMaximum: 1,
                .closeScore: 1,
            ]
        )
        XCTAssertTrue(
            plan.suppressionRecords.allSatisfy {
                $0.disposition == .suppressed(reason: .staleEpisode)
            }
        )
    }

    func testInvalidPublicationTimeZoneFailsWithoutScheduledFamilies()
        throws {
        let competition = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696045"),
            lifecycle: .completed
        )
        let snapshot = CompetitionNotificationPlanningSnapshot(
            publicationRevision: 12,
            evaluatedAt: fixedDate,
            timeZoneIdentifier: "Not/A-Time-Zone",
            competitions: [competition]
        )

        XCTAssertThrowsError(
            try CompetitionNotificationPlanner(policy: .fixture).plan(
                snapshot,
                authorization: .authorized,
                mutedOpponentIdentities: []
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionNotificationPlanner.PlanningError,
                .invalidTimeZoneIdentifier("Not/A-Time-Zone")
            )
        }
    }

    // MARK: - PR 5: notifications

    private let enUS = Locale(identifier: "en_US")
    private let fresh = CompetitionNotificationEvaluationFreshness.freshCompletedRefresh(
        attemptID: "fixture-attempt",
        readAt: Date(timeIntervalSinceReferenceDate: 1_000_000)
    )

    private func snapshot(
        _ competitions: [CompetitionNotificationCompetitionSnapshot],
        evaluatedAt: Date? = nil
    ) -> CompetitionNotificationPlanningSnapshot {
        CompetitionNotificationPlanningSnapshot(
            publicationRevision: 21,
            evaluatedAt: evaluatedAt ?? fixedDate,
            timeZoneIdentifier: "UTC",
            competitions: competitions
        )
    }

    private func liveMatch(
        _ suffix: String,
        day: Int,
        owner: Double,
        opponent: Double,
        today: Double = 300,
        lifecycle: CompetitionNotificationLifecycle? = nil,
        recorded: [(NotificationEmissionFamily, NotificationEpisodeKey)] = [],
        days: [CompetitionNotificationDaySnapshot]? = nil,
        whatItTakes: CompetitionWhatItTakes? = nil
    ) throws -> CompetitionNotificationCompetitionSnapshot {
        try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F6961" + suffix),
            lifecycle: lifecycle ?? .active(dayOrdinal: day),
            currentDayOrdinal: day,
            latestRefresh: .completed,
            evaluationFreshness: fresh,
            ownerPoints: owner,
            opponentPoints: opponent,
            currentDayOwnerPoints: today,
            recorded: recorded,
            days: days,
            whatItTakes: whatItTakes
        )
    }

    private func finishedMatch(
        _ suffix: String,
        name: String,
        owner: Double,
        opponent: Double,
        outcome: CompetitionOutcome,
        startDate: Date = Date(timeIntervalSinceReferenceDate: 1_036_800),
        recorded: [(NotificationEmissionFamily, NotificationEpisodeKey)] = []
    ) throws -> CompetitionNotificationCompetitionSnapshot {
        try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F6962" + suffix),
            lifecycle: .completed,
            ownerPoints: owner,
            opponentPoints: opponent,
            opponentDisplayName: name,
            opponentIdentity: "local-opponent:v1:" + name,
            startDate: startDate,
            terminalResult: .init(ownerPoints: owner, opponentPoints: opponent, outcome: outcome),
            recorded: recorded
        )
    }

    private func enUSPolicy() -> CompetitionNotificationPolicy {
        var policy = CompetitionNotificationPolicy.liveV1
        policy.content = { CompetitionNotificationPolicy.liveV1Content($0, locale: Locale(identifier: "en_US")) }
        policy.summaryContent = {
            CompetitionNotificationPolicy.liveV1SummaryContent($0, locale: Locale(identifier: "en_US"))
        }
        return policy
    }

    private func plan(
        _ snapshot: CompetitionNotificationPlanningSnapshot,
        policy: CompetitionNotificationPolicy = .liveV1,
        muted: Set<String> = [],
        switchedOff: Set<CompetitionNotificationChoice> = []
    ) throws -> CompetitionNotificationPlan {
        try CompetitionNotificationPlanner(policy: policy).plan(
            snapshot,
            authorization: .authorized,
            mutedOpponentIdentities: muted,
            switchedOff: switchedOff
        )
    }

    func testTwoResultsInOneEvaluationBothEmit() throws {
        let result = try plan(snapshot([
            finishedMatch("01", name: "Priya", owner: 3_410, opponent: 3_180, outcome: .win),
            finishedMatch("02", name: "Jordan", owner: 3_117, opponent: 3_302, outcome: .loss),
        ]))
        let results = result.emissionDecisions.filter { $0.record.family == .result }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.map(\.message.opponentDisplayName)), ["Priya", "Jordan"])
        XCTAssertEqual(Set(results.map(\.message.outcome)), [.win, .loss])
    }

    func testImmediateRequestsSummarizeResults() throws {
        let policy = enUSPolicy()
        let evaluation = snapshot([
            try finishedMatch("01", name: "Priya", owner: 3_410, opponent: 3_180, outcome: .win),
            try finishedMatch("02", name: "Jordan", owner: 3_117, opponent: 3_302, outcome: .loss),
        ])
        let decisions = try plan(evaluation, policy: policy).emissionDecisions
        let planner = CompetitionNotificationPlanner(policy: policy)

        let requests = planner.immediateRequests(for: decisions, in: evaluation)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].identifier, decisions.map(\.request.identifier).min())
        XCTAssertTrue(requests[0].identifier.hasSuffix(":result:result"))
        XCTAssertEqual(requests[0].content.title, "2 matches finished")
        XCTAssertEqual(
            requests[0].content.body,
            "You beat Priya 3,410 to 3,180. You took the belt. Jordan won 3,302 to 3,117. Jordan took the belt."
        )
        XCTAssertNil(requests[0].route)

        let alone = planner.immediateRequests(for: [decisions[0]], in: evaluation)
        XCTAssertEqual(alone, [decisions[0].request])
    }

    // MARK: Belt sentence

    /// The body of the single result notification this evaluation emits.
    private func resultBody(_ competitions: [CompetitionNotificationCompetitionSnapshot]) throws -> String? {
        let policy = enUSPolicy()
        let evaluation = snapshot(competitions)
        let decisions = try plan(evaluation, policy: policy).emissionDecisions
        XCTAssertEqual(decisions.filter { $0.record.family == .result }.count, 1)
        return CompetitionNotificationPlanner(policy: policy)
            .immediateRequests(for: decisions, in: evaluation).first?.content.body
    }

    /// A finished week with the same person a week earlier, already notified.
    private func earlierWeek(
        name: String = "Sam",
        outcome: CompetitionOutcome
    ) throws -> CompetitionNotificationCompetitionSnapshot {
        try finishedMatch(
            "10", name: name, owner: 2_000, opponent: 2_100, outcome: outcome,
            startDate: Date(timeIntervalSinceReferenceDate: 1_036_800 - 7 * 86_400),
            recorded: [(.result, .result)]
        )
    }

    func testResultNotificationConcealsYouTookTheBeltFromThem() throws {
        XCTAssertEqual(
            try resultBody([
                earlierWeek(outcome: .loss),
                finishedMatch("11", name: "Sam", owner: 4_200, opponent: 3_900, outcome: .win),
            ]),
            "Seven rounds with Sam. Open to hear the decision."
        )
    }

    func testResultNotificationConcealsTheyTookTheBelt() throws {
        XCTAssertEqual(
            try resultBody([
                earlierWeek(outcome: .win),
                finishedMatch("11", name: "Sam", owner: 3_117, opponent: 3_302, outcome: .loss),
            ]),
            "Seven rounds with Sam. Open to hear the decision."
        )
    }

    func testResultNotificationConcealsYouTookTheBeltOnAFirstWin() throws {
        XCTAssertEqual(
            try resultBody([
                finishedMatch("11", name: "Sam", owner: 4_200, opponent: 3_900, outcome: .win),
            ]),
            "Seven rounds with Sam. Open to hear the decision."
        )
    }

    func testResultNotificationTeasesKeptTiedAndRetiredMatches() throws {
        XCTAssertEqual(
            try resultBody([
                earlierWeek(outcome: .win),
                finishedMatch("11", name: "Sam", owner: 4_200, opponent: 3_900, outcome: .win),
            ]),
            "Seven rounds with Sam. Open to hear the decision."
        )
        XCTAssertEqual(
            try resultBody([
                earlierWeek(outcome: .win),
                finishedMatch("11", name: "Sam", owner: 1_500, opponent: 1_500, outcome: .tie),
            ]),
            "Seven rounds with Sam. Open to hear the decision."
        )
        XCTAssertEqual(
            try resultBody([
                finishedMatch("11", name: "Sam", owner: 1_500, opponent: 1_500, outcome: .tie),
            ]),
            "Seven rounds with Sam. Open to hear the decision."
        )
        XCTAssertEqual(
            try resultBody([
                finishedMatch("11", name: "Former competitor", owner: 4_200, opponent: 3_900, outcome: .win),
            ]),
            "Seven rounds with Former competitor. Open to hear the decision."
        )
    }

    func testDailyMaximumIsNotRepeatedByALaterMatchTheSameDay() throws {
        func dailyMaximum(
            a: CompetitionNotificationCompetitionSnapshot,
            b: CompetitionNotificationCompetitionSnapshot
        ) throws -> (decided: [NotificationEmissionFamily], suppressed: [NotificationEmissionRecorded]) {
            let result = try plan(snapshot([a, b]))
            return (
                result.emissionDecisions.filter { $0.record.competitionID == b.id }.map(\.record.family),
                result.suppressionRecords.filter { $0.competitionID == b.id && $0.family == .dailyMaximum }
            )
        }
        let a = try liveMatch("01", day: 3, owner: 900, opponent: 800, recorded: [(.dailyMaximum, .day(3))])

        let sameDay = try dailyMaximum(a: a, b: liveMatch("02", day: 3, owner: 1_500, opponent: 900, today: 600))
        XCTAssertEqual(sameDay.decided, [])
        XCTAssertEqual(sameDay.suppressed.map(\.episodeKey), [.day(3)])
        XCTAssertEqual(sameDay.suppressed.map(\.disposition), [.suppressed(reason: .superseded)])

        let laterStart = try dailyMaximum(
            a: a, b: liveMatch("02", day: 5, owner: 1_200, opponent: 1_190, today: 600)
        )
        XCTAssertEqual(laterStart.decided, [.closeScore])
        XCTAssertEqual(laterStart.suppressed.map(\.episodeKey), [.day(5)])

        let tallying = try liveMatch(
            "01", day: 7, owner: 900, opponent: 800, lifecycle: .tallying,
            recorded: [(.dailyMaximum, .day(7))]
        )
        XCTAssertEqual(
            try dailyMaximum(a: tallying, b: liveMatch("02", day: 3, owner: 1_500, opponent: 900, today: 600)).decided,
            [.dailyMaximum]
        )

        let yesterday = try liveMatch("01", day: 3, owner: 900, opponent: 800, recorded: [(.dailyMaximum, .day(2))])
        XCTAssertEqual(
            try dailyMaximum(a: yesterday, b: liveMatch("02", day: 3, owner: 1_500, opponent: 900, today: 600)).decided,
            [.dailyMaximum]
        )
    }

    func testImmediateRequestsPostDailyMaximumOnceWithoutAName() throws {
        let policy = enUSPolicy()
        let first = try liveMatch("01", day: 3, owner: 900, opponent: 800, today: 600)
        let second = try liveMatch("02", day: 3, owner: 900, opponent: 800, today: 600)
        let third = try liveMatch("03", day: 3, owner: 100, opponent: 800)
        let two = snapshot([first, second])
        let decisions = try plan(two, policy: policy).emissionDecisions
        XCTAssertEqual(decisions.map(\.record.family), [.dailyMaximum, .dailyMaximum])
        let planner = CompetitionNotificationPlanner(policy: policy)

        let requests = planner.immediateRequests(for: decisions, in: two)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].identifier, decisions.map(\.request.identifier).min())
        XCTAssertEqual(requests[0].content.title, "600 today")
        XCTAssertEqual(requests[0].content.body, "That’s the daily max. It counts in both your matches.")
        XCTAssertFalse(requests[0].content.body.contains("Alex"))
        XCTAssertNil(requests[0].route)

        XCTAssertEqual(
            planner.immediateRequests(for: decisions, in: snapshot([first])).map(\.content.body),
            ["That’s the daily max."]
        )
        XCTAssertEqual(
            planner.immediateRequests(for: decisions, in: snapshot([first, second, third])).map(\.content.body),
            ["That’s the daily max. It counts in all 3 of your matches."]
        )
    }

    func testSameScheduleRemindersMergeIntoOne() throws {
        func scheduled(
            _ suffix: String,
            _ name: String,
            start: Date = Date(timeIntervalSinceReferenceDate: 1_036_800)
        ) throws -> CompetitionNotificationCompetitionSnapshot {
            try competitionSnapshot(
                id: competitionID("EAD172F8-531D-4327-823D-E82A4F6963" + suffix),
                lifecycle: .scheduled,
                opponentDisplayName: name,
                opponentIdentity: "local-opponent:v1:" + name,
                startDate: start
            )
        }
        let priya = try scheduled("01", "Priya")
        let jordan = try scheduled("02", "Jordan")
        let policy = enUSPolicy()

        let merged = try plan(snapshot([priya, jordan]), policy: policy).desiredScheduledRequests
        XCTAssertEqual(
            merged.map(\.identifier),
            [
                CompetitionNotificationIdentifier.scheduled(competitionID: priya.id, family: .competitionEnded),
                CompetitionNotificationIdentifier.scheduled(competitionID: priya.id, family: .finalDay),
                CompetitionNotificationIdentifier.scheduled(competitionID: priya.id, family: .scheduledStart),
            ]
        )
        XCTAssertTrue(merged.allSatisfy { $0.route == nil })
        XCTAssertEqual(
            merged.map(\.content.body),
            [
                "HealthComp is checking the latest Activity data before finalizing your results with Jordan and Priya.",
                "Today is the last day of your matches with Jordan and Priya.",
                "Your matches with Jordan and Priya start today.",
            ]
        )
        XCTAssertEqual(merged[2].content.title, "Day 1 of 7")

        let laterJordan = try scheduled("02", "Jordan", start: Date(timeIntervalSinceReferenceDate: 1_036_800 + 86_400))
        let separate = try plan(snapshot([priya, laterJordan]), policy: policy).desiredScheduledRequests
        XCTAssertEqual(separate.count, 6)
        XCTAssertTrue(separate.allSatisfy { $0.route != nil && !$0.content.body.contains("matches") })

        let oneMuted = try plan(
            snapshot([priya, jordan]), policy: policy, muted: ["local-opponent:v1:Jordan"]
        ).desiredScheduledRequests
        XCTAssertEqual(oneMuted.count, 3)
        XCTAssertTrue(oneMuted.allSatisfy { $0.route == .competition(priya.id) })
        XCTAssertEqual(oneMuted[2].content.body, "Your match with Priya starts today.")
    }

    func testInviteExpiryFiresFourHoursEarly() throws {
        let expiresAt = Date(timeIntervalSinceReferenceDate: 1_100_000)
        let pending = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696401"),
            lifecycle: .pending(direction: .outgoing, expiresAt: expiresAt)
        )
        let early = try plan(snapshot([pending], evaluatedAt: expiresAt.addingTimeInterval(-36_000)))
        XCTAssertEqual(early.desiredScheduledRequests.count, 1)
        XCTAssertEqual(
            early.desiredScheduledRequests.first?.dateComponents.date,
            expiresAt.addingTimeInterval(-14_400)
        )
        XCTAssertEqual(early.desiredScheduledRequests.first?.route, .competition(pending.id))

        let late = try plan(snapshot([pending], evaluatedAt: expiresAt.addingTimeInterval(-10_800)))
        XCTAssertEqual(late.desiredScheduledRequests, [])
    }

    func testInviteExpiryCopyDependsOnDirection() throws {
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let expiresAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-31T21:14:00Z"))
        func content(_ direction: InvitationDirection, _ locale: Locale) -> CompetitionNotificationContent {
            var message = CompetitionNotificationMessage(
                family: .scheduled(.inviteExpiry),
                competitionID: competitionID("EAD172F8-531D-4327-823D-E82A4F696402"),
                opponentDisplayName: "Sam",
                ownerPoints: nil,
                opponentPoints: nil,
                outcome: nil
            )
            message.expiresAt = expiresAt
            message.invitationDirection = direction
            return CompetitionNotificationPolicy.liveV1Content(message, locale: locale, timeZone: la)
        }
        let outgoing = content(.outgoing, enUS)
        XCTAssertEqual(outgoing.title, "Sam hasn’t accepted yet")
        XCTAssertEqual(normalized(outgoing.body), "Your challenge expires at 2:14 PM.")
        let incoming = content(.incoming, enUS)
        XCTAssertEqual(incoming.title, "Sam challenged you")
        XCTAssertEqual(normalized(incoming.body), "The challenge expires at 2:14 PM.")
        XCTAssertTrue(content(.outgoing, Locale(identifier: "fr_FR")).body.contains("14:14"))
    }

    func testCloseScoreNeedsRealTotalsLateInWeek() throws {
        func closeScores(day: Int, owner: Double, opponent: Double) throws -> [CompetitionNotificationEmissionDecision] {
            try plan(snapshot([liveMatch("01", day: day, owner: owner, opponent: opponent)]))
                .emissionDecisions.filter { $0.record.family == .closeScore }
        }
        XCTAssertEqual(try closeScores(day: 1, owner: 0, opponent: 0).count, 0)
        XCTAssertEqual(try closeScores(day: 4, owner: 1_190, opponent: 1_200).count, 0)
        XCTAssertEqual(try closeScores(day: 6, owner: 240, opponent: 250).count, 0)
        let dayFive = try closeScores(day: 5, owner: 1_190, opponent: 1_200)
        XCTAssertEqual(dayFive.count, 1)
        let copy = try CompetitionNotificationPolicy.liveV1Content(XCTUnwrap(dayFive.first).message, locale: enUS)
        XCTAssertEqual(copy.title, "Neck and neck with Alex")
        XCTAssertEqual(copy.body, "Three days left. You’re 10 points behind.")
    }

    func testFirstLeaderIsSilentAndOnlyAChangeNotifies() throws {
        // Close-score copy is off so the lead change takes the match's slot.
        var policy = CompetitionNotificationPolicy.liveV1
        policy.isCloseScore = { _, _, _ in false }

        let first = try plan(snapshot([liveMatch("01", day: 3, owner: 900, opponent: 800)]), policy: policy)
        XCTAssertFalse(first.emissionDecisions.contains { $0.record.family == .leadChange })
        let baseline = first.suppressionRecords.filter { $0.family == .leadChange }
        XCTAssertEqual(baseline.map(\.episodeKey), [.leader(dayOrdinal: 3, leader: .owner)])
        XCTAssertEqual(baseline.map(\.disposition), [.suppressed(reason: .superseded)])

        let change = try plan(
            snapshot([liveMatch(
                "01", day: 5, owner: 1_010, opponent: 1_032,
                recorded: [(.leadChange, .leader(dayOrdinal: 3, leader: .owner))]
            )]),
            policy: policy
        )
        let leads = change.emissionDecisions.filter { $0.record.family == .leadChange }
        XCTAssertEqual(leads.count, 1)
        let copy = try CompetitionNotificationPolicy.liveV1Content(XCTUnwrap(leads.first).message, locale: enUS)
        XCTAssertEqual(copy.title, "Alex took the lead")
        XCTAssertEqual(copy.body, "Alex 1,032, you 1,010. Three days left.")

        let dayOne = try plan(
            snapshot([liveMatch(
                "01", day: 1, owner: 100, opponent: 200,
                recorded: [(.leadChange, .leader(dayOrdinal: 1, leader: .owner))]
            )]),
            policy: policy
        )
        XCTAssertFalse(dayOne.emissionDecisions.contains { $0.record.family == .leadChange })
        XCTAssertEqual(
            dayOne.suppressionRecords.filter { $0.family == .leadChange }.map(\.episodeKey),
            [.leader(dayOrdinal: 1, leader: .opponent)]
        )
    }

    func testBothDayOneLeadersResolveFromEndOfDayTotals() throws {
        let bothOnDayOne: [(NotificationEmissionFamily, NotificationEpisodeKey)] = [
            (.leadChange, .leader(dayOrdinal: 1, leader: .owner)),
            (.leadChange, .leader(dayOrdinal: 1, leader: .opponent)),
        ]
        func dayTwo(
            dayOne: CompetitionNotificationDaySnapshot,
            today: CompetitionNotificationDaySnapshot
        ) throws -> CompetitionNotificationPlan {
            try plan(snapshot([liveMatch(
                "01",
                day: 2,
                owner: (dayOne.ownerAcceptedPoints ?? 0) + (today.ownerAcceptedPoints ?? 0),
                opponent: (dayOne.opponentRevealedPoints ?? 0) + (today.opponentRevealedPoints ?? 0),
                recorded: bothOnDayOne,
                days: [dayOne, today]
            )]))
        }

        // Alex ended Day 1 ahead and still leads: no "Alex took the lead".
        let stillAlex = try dayTwo(
            dayOne: .init(ordinal: 1, ownerAcceptedPoints: 100, opponentRevealedPoints: 200),
            today: .init(ordinal: 2, ownerAcceptedPoints: 150, opponentRevealedPoints: 120)
        )
        XCTAssertFalse(stillAlex.emissionDecisions.contains { $0.record.family == .leadChange })
        XCTAssertFalse(stillAlex.suppressionRecords.contains { $0.family == .leadChange })

        // Alex ended Day 1 ahead and you pass him on Day 2: that is news.
        let youPass = try dayTwo(
            dayOne: .init(ordinal: 1, ownerAcceptedPoints: 100, opponentRevealedPoints: 200),
            today: .init(ordinal: 2, ownerAcceptedPoints: 300, opponentRevealedPoints: 50)
        )
        XCTAssertEqual(
            youPass.emissionDecisions.filter { $0.record.family == .leadChange }.map(\.record.episodeKey),
            [.leader(dayOrdinal: 2, leader: .owner)]
        )

        // Day 1's end can't be told: the Day 2 leader is a silent baseline.
        let unknown = try dayTwo(
            dayOne: .init(ordinal: 1, ownerAcceptedPoints: 100, opponentRevealedPoints: nil),
            today: .init(ordinal: 2, ownerAcceptedPoints: 300, opponentRevealedPoints: 50)
        )
        XCTAssertFalse(unknown.emissionDecisions.contains { $0.record.family == .leadChange })
        XCTAssertEqual(
            unknown.suppressionRecords.filter { $0.family == .leadChange }.map(\.episodeKey),
            [.leader(dayOrdinal: 2, leader: .owner)]
        )
    }

    func testLeaderUsesDisplayedPoints() throws {
        let result = try plan(snapshot([liveMatch(
            "01", day: 4, owner: 412.3, opponent: 412.0,
            recorded: [(.leadChange, .leader(dayOrdinal: 2, leader: .opponent))]
        )]))
        XCTAssertFalse(result.emissionDecisions.contains { $0.record.family == .leadChange })
        XCTAssertFalse(result.suppressionRecords.contains { $0.family == .leadChange })
    }

    func testLiveV1CopyForEveryFamily() throws {
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        func copy(
            _ family: CompetitionNotificationMessageFamily,
            _ owner: Double? = nil,
            _ opponent: Double? = nil,
            _ outcome: CompetitionOutcome? = nil,
            day: Int? = nil,
            live: Int = 1
        ) -> CompetitionNotificationContent {
            var built = self.message(family, owner, opponent, outcome)
            built.dayOrdinal = day
            built.liveMatchCount = live
            return CompetitionNotificationPolicy.liveV1Content(built, locale: enUS, timeZone: la)
        }
        func line(_ content: CompetitionNotificationContent) -> String {
            "\(content.title) · \(content.body)"
        }
        func formatterTitle(_ lifecycle: LocalCompetitionLifecyclePresentation) -> String {
            competitionStatusText(lifecycle, schedule: nil, opponentDisplayName: "Alex", style: .notification).title
        }

        XCTAssertEqual(
            line(copy(.opportunistic(.leadChange), 1_217, 1_194, day: 6)),
            "You took the lead · You 1,217, Alex 1,194. Two days left."
        )
        XCTAssertEqual(
            line(copy(.opportunistic(.leadChange), 1_010, 1_032, day: 7)),
            "Alex took the lead · Alex 1,032, you 1,010. Last day."
        )
        XCTAssertEqual(
            line(copy(.opportunistic(.leadChange), 1_217, 1_194)),
            "You took the lead · You 1,217, Alex 1,194."
        )
        XCTAssertEqual(
            line(copy(.opportunistic(.closeScore), 2_400, 2_382, day: 7)),
            "Neck and neck with Alex · Last day. You’re 18 points ahead."
        )
        XCTAssertEqual(copy(.opportunistic(.closeScore), 1_000, 999, day: 5).body, "Three days left. You’re 1 point ahead.")
        XCTAssertEqual(copy(.opportunistic(.closeScore), 1_000, 1_000.2, day: 6).body, "Two days left. All square.")
        XCTAssertEqual(copy(.opportunistic(.closeScore), 1_000, 1_000).body, "All square.")
        XCTAssertEqual(line(copy(.opportunistic(.dailyMaximum), 600, 100)), "600 today · That’s the daily max.")
        XCTAssertEqual(
            copy(.opportunistic(.dailyMaximum), 600, 100, live: 4).body,
            "That’s the daily max. It counts in all 4 of your matches."
        )
        for outcome in [CompetitionOutcome.win, .loss, .tie] {
            XCTAssertEqual(line(copy(.opportunistic(.result), 4_200, 3_900, outcome)),
                           "The judges’ scorecards are in · Seven rounds with Alex. Open to hear the decision.")
        }
        XCTAssertEqual(copy(.opportunistic(.result), 412.3, 412.0, .win).body,
                       "Seven rounds with Alex. Open to hear the decision.")
        XCTAssertEqual(line(copy(.opportunistic(.result))),
                       "The judges’ scorecards are in · Seven rounds with Alex. Open to hear the decision.")
        XCTAssertEqual(copy(.scheduled(.competitionEnded)).body,
                       "Seven rounds with Alex are in. The decision is coming.")
        XCTAssertEqual(
            line(copy(.opportunistic(.catchUp))),
            "Match update · Open HealthComp for the latest on your match with Alex."
        )

        func named(
            _ family: CompetitionNotificationMessageFamily,
            _ name: String,
            _ suffix: String,
            _ owner: Double? = nil,
            _ opponent: Double? = nil,
            _ outcome: CompetitionOutcome? = nil
        ) -> CompetitionNotificationMessage {
            CompetitionNotificationMessage(
                family: family,
                competitionID: competitionID("EAD172F8-531D-4327-823D-E82A4F6965" + suffix),
                opponentDisplayName: name,
                ownerPoints: owner,
                opponentPoints: opponent,
                outcome: outcome
            )
        }
        func summary(_ messages: [CompetitionNotificationMessage]) -> CompetitionNotificationContent {
            CompetitionNotificationPolicy.liveV1SummaryContent(messages, locale: enUS)
        }
        XCTAssertEqual(
            line(summary([
                named(.opportunistic(.result), "Jordan", "01", 3_117, 3_302, .loss),
                named(.opportunistic(.result), "Sam", "02", 3_180, 3_180, .tie),
                named(.opportunistic(.result), "Priya", "03", 3_410, 3_180, .win),
            ])),
            "3 matches finished · You beat Priya 3,410 to 3,180. All square with Sam at 3,180. Jordan won 3,302 to 3,117."
        )
        XCTAssertEqual(
            summary([
                named(.opportunistic(.result), "Priya", "02", 3_117, 3_302, .loss),
                named(.opportunistic(.result), "Priya", "01", 3_410, 3_180, .win),
            ]).body,
            "You beat Priya 3,410 to 3,180. Priya won 3,302 to 3,117."
        )
        XCTAssertEqual(
            line(summary([
                named(.opportunistic(.catchUp), "Priya", "01"),
                named(.opportunistic(.catchUp), "Jordan", "02"),
                named(.opportunistic(.catchUp), "Sam", "03"),
            ])),
            "Match update · Open HealthComp for the latest on your matches with Jordan, Priya, and Sam."
        )
        let ended = summary([
            named(.scheduled(.competitionEnded), "Priya", "01"),
            named(.scheduled(.competitionEnded), "Jordan", "02"),
        ])
        XCTAssertEqual(ended.title, formatterTitle(.tallying(startedAt: .distantPast)))
        XCTAssertEqual(
            ended.body,
            "HealthComp is checking the latest Activity data before finalizing your results with Jordan and Priya."
        )
        XCTAssertEqual(
            line(summary([
                named(.scheduled(.finalDay), "Priya", "01"),
                named(.scheduled(.finalDay), "Priya", "02"),
            ])),
            "Last day · Today is the last day of your matches with Priya."
        )

        // The zone is named only when its midnight offset differs from the phone's.
        func reminder(zone: String, dayEnd: String) -> String {
            var built = self.message(.scheduled(.whatItTakes), nil, nil)
            built.whatItTakes = takes(dayOrdinal: 5, points: 39)
            built.dayOrdinal = 5
            built.matchTimeZoneIdentifier = zone
            built.matchDayEnd = ISO8601DateFormatter().date(from: dayEnd)
            return line(CompetitionNotificationPolicy.liveV1Content(built, locale: enUS, timeZone: la))
        }
        let takesLine = "39 to take the lead from Alex · About 240 kcal of Move or 12 min of Exercise."
        XCTAssertEqual(
            reminder(zone: "America/Los_Angeles", dayEnd: "2027-01-16T08:00:00Z"),
            takesLine + " Day 5 ends at midnight."
        )
        XCTAssertEqual(
            reminder(zone: "America/New_York", dayEnd: "2027-01-16T05:00:00Z"),
            takesLine + " Day 5 ends at midnight EST."
        )
        XCTAssertEqual(
            reminder(zone: "America/New_York", dayEnd: "2027-07-16T04:00:00Z"),
            takesLine + " Day 5 ends at midnight EDT."
        )
        var noTakes = message(.scheduled(.whatItTakes), nil, nil)
        XCTAssertEqual(
            line(CompetitionNotificationPolicy.liveV1Content(noTakes, locale: enUS, timeZone: la)),
            "Match update · Open HealthComp for the latest on your match with Alex."
        )
        noTakes.whatItTakes = takes(dayOrdinal: 5, points: nil)
        XCTAssertEqual(
            CompetitionNotificationPolicy.liveV1Content(noTakes, locale: enUS, timeZone: la).title,
            "Match update"
        )
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    // MARK: - PR 13: notification choices

    func testEveryMessageFamilyMapsToItsSwitchOrIsAlwaysOn() {
        let families: [(CompetitionNotificationMessageFamily, CompetitionNotificationChoice?)] = [
            (.opportunistic(.leadChange), .leadChange),
            (.opportunistic(.closeScore), .closeScore),
            (.opportunistic(.dailyMaximum), nil),
            (.opportunistic(.result), nil),
            (.opportunistic(.catchUp), nil),
            (.scheduled(.inviteExpiry), nil),
            (.scheduled(.scheduledStart), nil),
            (.scheduled(.finalDay), .finalDay),
            (.scheduled(.competitionEnded), nil),
            (.scheduled(.whatItTakes), .whatItTakes),
        ]
        XCTAssertEqual(
            families.count,
            NotificationEmissionFamily.allCases.count
                + CompetitionScheduledNotificationFamily.allCases.count
        )
        for (family, choice) in families {
            XCTAssertEqual(family.choice, choice, family.rawValue)
            XCTAssertEqual(
                family.isOff(in: Set(CompetitionNotificationChoice.allCases)),
                choice != nil,
                family.rawValue
            )
            XCTAssertFalse(family.isOff(in: []), family.rawValue)
        }
    }

    func testSwitchedOffLastDayDropsOnlyThatReminder() throws {
        func scheduled(_ suffix: String, _ name: String) throws -> CompetitionNotificationCompetitionSnapshot {
            try competitionSnapshot(
                id: competitionID("EAD172F8-531D-4327-823D-E82A4F6964" + suffix),
                lifecycle: .scheduled,
                opponentDisplayName: name,
                opponentIdentity: "local-opponent:v1:" + name
            )
        }
        let priya = try scheduled("01", "Priya")
        let jordan = try scheduled("02", "Jordan")
        let policy = enUSPolicy()
        func identifier(_ family: CompetitionScheduledNotificationFamily) -> String {
            CompetitionNotificationIdentifier.scheduled(competitionID: priya.id, family: family)
        }

        let allOn = try plan(snapshot([priya]), policy: policy).desiredScheduledRequests
        XCTAssertTrue(allOn.map(\.identifier).contains(identifier(.finalDay)))

        let lastDayOff = try plan(snapshot([priya]), policy: policy, switchedOff: [.finalDay])
            .desiredScheduledRequests
        XCTAssertEqual(
            lastDayOff.map(\.identifier),
            [identifier(.competitionEnded), identifier(.scheduledStart)]
        )

        let merged = try plan(snapshot([priya, jordan]), policy: policy, switchedOff: [.finalDay])
            .desiredScheduledRequests
        XCTAssertFalse(merged.contains { $0.identifier.hasSuffix(":final-day") })
        XCTAssertTrue(merged.contains { $0.content.title == "Day 1 of 7" && $0.route == nil })
    }

    func testSwitchedOffLeadChangeSuppressesALeadChangeThatWouldPost() throws {
        let match = try liveMatch(
            "21", day: 3, owner: 900, opponent: 800,
            recorded: [(.leadChange, .leader(dayOrdinal: 2, leader: .opponent))]
        )

        let allOn = try plan(snapshot([match]))
        XCTAssertEqual(allOn.emissionDecisions.map(\.record.family), [.leadChange])

        let off = try plan(snapshot([match]), switchedOff: [.leadChange])
        XCTAssertEqual(off.emissionDecisions, [])
        XCTAssertTrue(off.suppressionRecords.contains {
            $0.family == .leadChange
                && $0.episodeKey == .leader(dayOrdinal: 3, leader: .owner)
                && $0.disposition == .suppressed(reason: .superseded)
        })
    }

    func testSwitchedOffCloseScoreFreesTheSlotForALeadChange() throws {
        let match = try liveMatch(
            "22", day: 5, owner: 1_210, opponent: 1_200,
            recorded: [(.leadChange, .leader(dayOrdinal: 4, leader: .opponent))]
        )

        let allOn = try plan(snapshot([match]))
        XCTAssertEqual(allOn.emissionDecisions.map(\.record.family), [.closeScore])

        let off = try plan(snapshot([match]), switchedOff: [.closeScore])
        XCTAssertEqual(off.emissionDecisions.map(\.record.family), [.leadChange])
        XCTAssertTrue(off.suppressionRecords.contains {
            $0.family == .closeScore
                && $0.episodeKey == .day(5)
                && $0.disposition == .suppressed(reason: .superseded)
        })
    }

    func testLeadChangeAndResultAlertsCarryReactionsOnTheirTarget() throws {
        let lead = try liveMatch(
            "24", day: 3, owner: 900, opponent: 800,
            recorded: [(.leadChange, .leader(dayOrdinal: 2, leader: .opponent))]
        )
        let leadPlan = try plan(snapshot([lead]))
        XCTAssertEqual(leadPlan.emissionDecisions.map(\.record.family), [.leadChange])
        XCTAssertEqual(leadPlan.emissionDecisions.map(\.request.reactionTarget), [.day(3)])

        let finished = try finishedMatch("24", name: "Priya", owner: 3_410, opponent: 3_180, outcome: .win)
        let resultPlan = try plan(snapshot([finished]))
        XCTAssertEqual(resultPlan.emissionDecisions.map(\.request.reactionTarget), [.result])

        // A close score posts without them, and a muted match posts nothing.
        let close = try liveMatch(
            "25", day: 5, owner: 1_210, opponent: 1_200,
            recorded: [(.leadChange, .leader(dayOrdinal: 4, leader: .opponent))]
        )
        let closePlan = try plan(snapshot([close]))
        XCTAssertEqual(closePlan.emissionDecisions.map(\.record.family), [.closeScore])
        XCTAssertEqual(closePlan.emissionDecisions.map(\.request.reactionTarget), [nil])
        XCTAssertEqual(
            try plan(snapshot([lead]), muted: [lead.opponentIdentity]).emissionDecisions,
            []
        )
    }

    func testSummarizedResultsCarryNoReactions() throws {
        let policy = enUSPolicy()
        let evaluation = snapshot([
            try finishedMatch("01", name: "Priya", owner: 3_410, opponent: 3_180, outcome: .win),
            try finishedMatch("02", name: "Jordan", owner: 3_117, opponent: 3_302, outcome: .loss),
        ])
        let decisions = try plan(evaluation, policy: policy).emissionDecisions
        let requests = CompetitionNotificationPlanner(policy: policy)
            .immediateRequests(for: decisions, in: evaluation)
        XCTAssertEqual(requests.map(\.reactionTarget), [nil])
    }

    func testReactionAlertActionsSendTheKindToTheTargetInTheRoutesMatch() {
        let id = competitionID("EAD172F8-531D-4327-823D-E82A4F696199")
        let recipient = UUID(uuidString: "6B1D2E0A-3C5F-4A71-9E2B-8D4F0C6A1B37")!
        let routeOnly = CompetitionRoute.competition(id).userInfo
        var userInfo = routeOnly
        userInfo[CompetitionReactionAlert.recipientKey] = recipient.uuidString
        let fire = CompetitionReactionAlert.request(
            actionIdentifier: CompetitionReactionAlert.actionIdentifier(.fire),
            categoryIdentifier: CompetitionReactionAlert.category(.day(4)),
            userInfo: userInfo
        )
        XCTAssertEqual(
            fire?.reaction,
            CompetitionReactionRequest(competitionID: id.rawValue, target: .day(4), kind: .fire)
        )
        XCTAssertEqual(fire?.recipientUserID, recipient)
        XCTAssertEqual(
            CompetitionReactionAlert.request(
                actionIdentifier: CompetitionReactionAlert.actionIdentifier(.salute),
                categoryIdentifier: CompetitionReactionAlert.category(.result),
                userInfo: userInfo
            )?.reaction.target,
            .result
        )
        // A tap on the alert still opens its match past the recipient key.
        XCTAssertEqual(CompetitionReactionAlert.route(userInfo: userInfo), .competition(id))
        // A plain tap, an unknown category, a payload without a match or an
        // alert that names no recipient sends nothing.
        XCTAssertNil(CompetitionReactionAlert.request(
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            categoryIdentifier: CompetitionReactionAlert.category(.result),
            userInfo: userInfo
        ))
        XCTAssertNil(CompetitionReactionAlert.request(
            actionIdentifier: CompetitionReactionAlert.actionIdentifier(.clap),
            categoryIdentifier: "",
            userInfo: userInfo
        ))
        XCTAssertNil(CompetitionReactionAlert.request(
            actionIdentifier: CompetitionReactionAlert.actionIdentifier(.clap),
            categoryIdentifier: CompetitionReactionAlert.category(.result),
            userInfo: [:]
        ))
        XCTAssertNil(CompetitionReactionAlert.request(
            actionIdentifier: CompetitionReactionAlert.actionIdentifier(.clap),
            categoryIdentifier: CompetitionReactionAlert.category(.result),
            userInfo: routeOnly
        ))
        XCTAssertEqual(CompetitionReactionAlert.categories.count, 8)
        XCTAssertTrue(CompetitionReactionAlert.categories.allSatisfy { $0.actions.count == 4 })
    }

    func testTurningASwitchBackOnPostsNothingLate() throws {
        let match = try liveMatch(
            "23", day: 3, owner: 900, opponent: 800,
            recorded: [
                (.leadChange, .leader(dayOrdinal: 2, leader: .opponent)),
                (.leadChange, .leader(dayOrdinal: 3, leader: .owner)),
            ]
        )
        let plan = try plan(snapshot([match]))
        XCTAssertFalse(plan.emissionDecisions.contains { $0.record.family == .leadChange })
    }

    func testAlwaysOnFamiliesIgnoreEverySwitch() throws {
        let everything = Set(CompetitionNotificationChoice.allCases)

        let finished = try finishedMatch("24", name: "Priya", owner: 3_410, opponent: 3_180, outcome: .win)
        XCTAssertEqual(
            try plan(snapshot([finished]), switchedOff: everything).emissionDecisions.map(\.record.family),
            [.result]
        )

        let atMaximum = try liveMatch("25", day: 3, owner: 900, opponent: 800, today: 600)
        XCTAssertTrue(
            try plan(snapshot([atMaximum]), switchedOff: everything).emissionDecisions
                .contains { $0.record.family == .dailyMaximum }
        )

        let expiresAt = Date(timeIntervalSinceReferenceDate: 1_100_000)
        let pending = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696426"),
            lifecycle: .pending(direction: .outgoing, expiresAt: expiresAt)
        )
        XCTAssertEqual(
            try plan(
                snapshot([pending], evaluatedAt: expiresAt.addingTimeInterval(-36_000)),
                switchedOff: everything
            ).desiredScheduledRequests.map(\.identifier),
            [CompetitionNotificationIdentifier.scheduled(competitionID: pending.id, family: .inviteExpiry)]
        )

        let scheduled = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696427"),
            lifecycle: .scheduled
        )
        XCTAssertEqual(
            try plan(snapshot([scheduled]), switchedOff: everything).desiredScheduledRequests.map(\.identifier),
            [
                CompetitionNotificationIdentifier.scheduled(competitionID: scheduled.id, family: .competitionEnded),
                CompetitionNotificationIdentifier.scheduled(competitionID: scheduled.id, family: .scheduledStart),
            ]
        )
    }

    func testCatchUpCountsOnlyFamiliesThatAreOn() throws {
        let competition = try competitionSnapshot(
            id: competitionID("EAD172F8-531D-4327-823D-E82A4F696428"),
            lifecycle: .active(dayOrdinal: 4),
            currentDayOrdinal: 4,
            latestRefresh: .completed,
            evaluationFreshness: .notFresh,
            ownerPoints: 1_200,
            opponentPoints: 800,
            days: [
                CompetitionNotificationDaySnapshot(
                    ordinal: 2,
                    ownerAcceptedPoints: 500,
                    opponentRevealedPoints: 250
                ),
                CompetitionNotificationDaySnapshot(
                    ordinal: 4,
                    ownerAcceptedPoints: 100,
                    opponentRevealedPoints: 100
                ),
            ]
        )
        let planner = CompetitionNotificationPlanner(policy: .fixture)
        let fixture = snapshot([competition])

        let allOn = try planner.plan(fixture, authorization: .authorized, mutedOpponentIdentities: [])
        XCTAssertEqual(allOn.emissionDecisions.map(\.record.family), [.catchUp])

        let off = try planner.plan(
            fixture, authorization: .authorized, mutedOpponentIdentities: [], switchedOff: [.leadChange]
        )
        XCTAssertEqual(off.emissionDecisions, [])
        XCTAssertTrue(off.suppressionRecords.contains {
            $0.family == .leadChange && $0.disposition == .suppressed(reason: .staleEpisode)
        })
    }

    // MARK: - PR 14: what it takes reminder

    /// Noon (or another hour) on match day `day`; the fixture starts on a UTC midnight.
    private func matchTime(day: Int, hour: Double = 12) -> Date {
        Date(timeIntervalSinceReferenceDate: 1_036_800 + Double(day - 1) * 86_400 + hour * 3_600)
    }

    private func takes(dayOrdinal: Int, points: Double?) -> CompetitionWhatItTakes {
        let suggestion = "About 240 kcal of Move or 12 min of Exercise."
        return CompetitionWhatItTakes(
            dayOrdinal: dayOrdinal,
            points: points,
            headline: points.map { "\(Int($0)) to take the lead" } ?? "Out of reach today",
            suggestion: suggestion,
            detail: suggestion,
            accessibilityLabel: suggestion
        )
    }

    private func takesRequests(_ plan: CompetitionNotificationPlan) -> [CompetitionScheduledNotificationRequest] {
        plan.desiredScheduledRequests.filter { $0.identifier.hasSuffix(":what-it-takes") }
    }

    func testWhatItTakesReminderFiresAtSevenInTheMatchZoneWhenEnabled() throws {
        let match = try liveMatch("01", day: 5, owner: 1_112, opponent: 1_150,
                                  whatItTakes: takes(dayOrdinal: 5, points: 39))
        let requests = takesRequests(try plan(
            snapshot([match], evaluatedAt: matchTime(day: 5)), policy: enUSPolicy()
        ))
        XCTAssertEqual(requests.map(\.identifier), [
            CompetitionNotificationIdentifier.scheduled(competitionID: match.id, family: .whatItTakes),
        ])
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.route, .competition(match.id))
        XCTAssertEqual(request.dateComponents.timeZone?.secondsFromGMT(), 0)
        XCTAssertEqual(request.dateComponents.hour, 19)
        XCTAssertEqual(request.dateComponents.date, matchTime(day: 5, hour: 19))
        XCTAssertEqual(request.content.title, "39 to take the lead from Alex")
        // The zone suffix depends on the phone's zone; testLiveV1CopyForEveryFamily pins it.
        XCTAssertTrue(request.content.body.hasPrefix(
            "About 240 kcal of Move or 12 min of Exercise. Day 5 ends at midnight"
        ), request.content.body)
    }

    func testWhatItTakesReminderUsesTheValuesDayNotTheLifecycleDay() throws {
        let lagging = try liveMatch("01", day: 5, owner: 1_112, opponent: 1_150,
                                    lifecycle: .active(dayOrdinal: 4),
                                    whatItTakes: takes(dayOrdinal: 5, points: 39))
        let requests = takesRequests(try plan(snapshot([lagging], evaluatedAt: matchTime(day: 5))))
        XCTAssertEqual(requests.map(\.dateComponents.date), [matchTime(day: 5, hour: 19)])

        let mismatched = try liveMatch("01", day: 5, owner: 1_112, opponent: 1_150,
                                       lifecycle: .active(dayOrdinal: 4),
                                       whatItTakes: takes(dayOrdinal: 4, points: 39))
        XCTAssertEqual(takesRequests(try plan(snapshot([mismatched], evaluatedAt: matchTime(day: 5)))), [])

        // A later day's value is still in the future, so only the day check drops it.
        let ahead = try liveMatch("01", day: 5, owner: 1_112, opponent: 1_150,
                                  whatItTakes: takes(dayOrdinal: 6, points: 39))
        XCTAssertEqual(takesRequests(try plan(snapshot([ahead], evaluatedAt: matchTime(day: 5)))), [])
    }

    func testWhatItTakesReminderIsSkippedWhenOffOutOfReachLeadingMutedOrPastSeven() throws {
        let noon = matchTime(day: 5)
        func match(
            _ value: CompetitionWhatItTakes?,
            lifecycle: CompetitionNotificationLifecycle? = nil
        ) throws -> CompetitionNotificationCompetitionSnapshot {
            try liveMatch("01", day: 5, owner: 1_112, opponent: 1_150,
                          lifecycle: lifecycle, whatItTakes: value)
        }
        let reachable = takes(dayOrdinal: 5, points: 39)
        XCTAssertEqual(takesRequests(try plan(snapshot([match(reachable)], evaluatedAt: noon))).count, 1)

        XCTAssertEqual(takesRequests(try plan(
            snapshot([match(reachable)], evaluatedAt: noon), switchedOff: [.whatItTakes]
        )), [], "switched off")
        XCTAssertEqual(takesRequests(try plan(snapshot([match(nil)], evaluatedAt: noon))), [],
                       "leading or a stale reading")
        XCTAssertEqual(takesRequests(try plan(
            snapshot([match(takes(dayOrdinal: 5, points: nil))], evaluatedAt: noon)
        )), [], "out of reach")
        XCTAssertEqual(takesRequests(try plan(
            snapshot([match(reachable)], evaluatedAt: noon), muted: [opponentIdentity]
        )), [], "muted")
        XCTAssertEqual(takesRequests(try plan(
            snapshot([match(reachable)], evaluatedAt: matchTime(day: 5, hour: 19).addingTimeInterval(1))
        )), [], "past 7 PM")
        XCTAssertEqual(takesRequests(try plan(
            snapshot([match(reachable, lifecycle: .tallying)], evaluatedAt: noon)
        )), [], "tallying")
    }

    func testWhatItTakesReminderKeepsOnlyTheSmallestGapAcrossMatches() throws {
        let far = try liveMatch("01", day: 5, owner: 1_000, opponent: 1_119,
                                whatItTakes: takes(dayOrdinal: 5, points: 120))
        let near = try liveMatch("02", day: 5, owner: 1_112, opponent: 1_150,
                                 whatItTakes: takes(dayOrdinal: 5, points: 39))
        let requests = takesRequests(try plan(
            snapshot([far, near], evaluatedAt: matchTime(day: 5)), policy: enUSPolicy()
        ))
        XCTAssertEqual(requests.map(\.identifier), [
            CompetitionNotificationIdentifier.scheduled(competitionID: near.id, family: .whatItTakes),
        ])
        XCTAssertEqual(requests.first?.route, .competition(near.id))
        XCTAssertEqual(requests.first?.content.title, "39 to take the lead from Alex")
    }

    private let opponentIdentity = "local-opponent:v1:default"
    private let fixedDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func planningSnapshot(
        lifecycle: CompetitionNotificationLifecycle,
        currentDayOrdinal: Int?,
        latestRefresh: CompetitionNotificationRefreshState,
        evaluationFreshness: CompetitionNotificationEvaluationFreshness =
            .freshCompletedRefresh(
                attemptID: "fixture-attempt",
                readAt: Date(timeIntervalSinceReferenceDate: 1_000_000)
            ),
        ownerPoints: Double,
        opponentPoints: Double,
        currentDayOwnerPoints: Double = 300
    ) throws -> CompetitionNotificationPlanningSnapshot {
        CompetitionNotificationPlanningSnapshot(
            publicationRevision: 7,
            evaluatedAt: fixedDate,
            timeZoneIdentifier: "UTC",
            competitions: [
                try competitionSnapshot(
                    id: competitionID(
                        "EAD172F8-531D-4327-823D-E82A4F696043"
                    ),
                    lifecycle: lifecycle,
                    currentDayOrdinal: currentDayOrdinal,
                    latestRefresh: latestRefresh,
                    evaluationFreshness: evaluationFreshness,
                    ownerPoints: ownerPoints,
                    opponentPoints: opponentPoints,
                    currentDayOwnerPoints: currentDayOwnerPoints
                ),
            ]
        )
    }

    private func competitionSnapshot(
        id: CompetitionID,
        lifecycle: CompetitionNotificationLifecycle,
        currentDayOrdinal: Int? = nil,
        latestRefresh: CompetitionNotificationRefreshState = .none,
        evaluationFreshness: CompetitionNotificationEvaluationFreshness =
            .notFresh,
        ownerPoints: Double = 0,
        opponentPoints: Double = 0,
        currentDayOwnerPoints: Double = 0,
        opponentDisplayName: String = "Alex",
        opponentIdentity: String? = nil,
        startDate: Date = Date(timeIntervalSinceReferenceDate: 1_036_800),
        terminalResult: CompetitionNotificationTerminalSnapshot? = nil,
        recorded: [(NotificationEmissionFamily, NotificationEpisodeKey)] = [],
        days: [CompetitionNotificationDaySnapshot]? = nil,
        whatItTakes: CompetitionWhatItTakes? = nil
    ) throws -> CompetitionNotificationCompetitionSnapshot {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let startDay = try calendar.day(containing: startDate)
        return CompetitionNotificationCompetitionSnapshot(
            id: id,
            opponentIdentity: opponentIdentity ?? self.opponentIdentity,
            opponentDisplayName: opponentDisplayName,
            lifecycle: lifecycle,
            schedule: CompetitionSchedule(
                calendar: calendar,
                startDay: startDay
            ),
            ownerPoints: ownerPoints,
            opponentPoints: opponentPoints,
            days: days ?? currentDayOrdinal.map {
                [
                    CompetitionNotificationDaySnapshot(
                        ordinal: $0,
                        ownerAcceptedPoints: currentDayOwnerPoints,
                        opponentRevealedPoints: 280
                    ),
                ]
            } ?? [],
            currentDayOrdinal: currentDayOrdinal,
            latestRefresh: latestRefresh,
            evaluationFreshness: evaluationFreshness,
            terminalResult: terminalResult,
            emissionHistory: NotificationEmissionProjection(
                recordedIDs: Set(try recorded.map { family, episode in
                    try NotificationEmissionRecorded.semanticID(
                        competitionID: id,
                        family: family,
                        episodeKey: episode
                    )
                })
            ),
            whatItTakes: whatItTakes
        )
    }

    private func competitionID(_ string: String) -> CompetitionID {
        CompetitionID(UUID(uuidString: string)!)
    }
}

private extension CompetitionNotificationPolicy {
    static var fixture: Self {
        Self(
            maximumPostsPerEvaluation: 1,
            maximumPostsPerCompetitionDay: 2,
            scheduledFireDate: { _, baseDate, _ in baseDate },
            isCloseScore: { owner, opponent, _ in
                abs(owner - opponent) <= 25
            },
            isDailyMaximum: { $0 == 600 },
            priority: { family in
                switch family {
                case .result: 40
                case .dailyMaximum: 30
                case .closeScore: 20
                case .leadChange: 10
                case .catchUp: 0
                }
            },
            content: { message in
                CompetitionNotificationContent(
                    title: message.family.rawValue,
                    body: "fixture"
                )
            }
        )
    }
}
