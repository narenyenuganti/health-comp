import CompetitionCore
import Foundation
import XCTest
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
            base
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
        XCTAssertTrue(policy.isCloseScore(1_000, 1_050))
        XCTAssertFalse(policy.isCloseScore(1_000, 1_051))
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

        let result = policy.content(
            CompetitionNotificationMessage(
                family: .opportunistic(.result),
                competitionID: competitionID(
                    "EAD172F8-531D-4327-823D-E82A4F696040"
                ),
                opponentDisplayName: "Alex",
                ownerPoints: 4_200,
                opponentPoints: 3_900,
                outcome: .win
            )
        )
        XCTAssertTrue(result.body.contains("4,200"))
        XCTAssertTrue(result.body.contains("3,900"))
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

    func testMaximumPostsPerEvaluationIsGlobalAcrossCompetitions() throws {
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

        XCTAssertEqual(plan.emissionDecisions.count, 1)
        XCTAssertEqual(plan.emissionDecisions.first?.record.family, .dailyMaximum)
        XCTAssertEqual(
            plan.suppressionRecords.filter {
                $0.family == .dailyMaximum
                    && $0.disposition == .suppressed(reason: .superseded)
            }.count,
            1
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
        currentDayOwnerPoints: Double = 0
    ) throws -> CompetitionNotificationCompetitionSnapshot {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let startDay = try calendar.day(
            containing: Date(timeIntervalSinceReferenceDate: 1_036_800)
        )
        return CompetitionNotificationCompetitionSnapshot(
            id: id,
            opponentIdentity: opponentIdentity,
            opponentDisplayName: "Alex",
            lifecycle: lifecycle,
            schedule: CompetitionSchedule(
                calendar: calendar,
                startDay: startDay
            ),
            ownerPoints: ownerPoints,
            opponentPoints: opponentPoints,
            days: currentDayOrdinal.map {
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
            terminalResult: nil,
            emissionHistory: NotificationEmissionProjection()
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
            isCloseScore: { owner, opponent in
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
