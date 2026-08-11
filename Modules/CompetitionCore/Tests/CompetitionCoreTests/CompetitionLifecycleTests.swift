import Foundation
import XCTest

@testable import CompetitionCore

final class CompetitionLifecycleTests: XCTestCase {
    private let engine = CompetitionEngine()
    private let competitionID = CompetitionID(
        UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    )
    private let timeZoneIdentifier = "America/Los_Angeles"

    func testPendingInvitationPersistsDirectionAndConfiguredExpiry() {
        let createdAt = date(2026, 8, 9, 10)
        let expiresAt = date(2026, 8, 11, 10)

        let incoming = Competition.pending(
            id: competitionID,
            direction: .incoming,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        let outgoing = Competition.pending(
            id: competitionID,
            direction: .outgoing,
            createdAt: createdAt,
            expiresAt: nil
        )

        XCTAssertEqual(
            incoming.lifecycle,
            .pendingInvitation(
                PendingInvitation(
                    direction: .incoming,
                    createdAt: createdAt,
                    expiresAt: expiresAt
                )
            )
        )
        XCTAssertEqual(
            outgoing.lifecycle,
            .pendingInvitation(
                PendingInvitation(
                    direction: .outgoing,
                    createdAt: createdAt,
                    expiresAt: nil
                )
            )
        )
    }

    func testAcceptanceFreezesTimeZoneAndSchedulesNextLocalCalendarDay() throws {
        var competition = pending()
        let acceptedAt = date(2026, 12, 31, 23, 30)

        let event = try engine.accept(
            competition,
            at: acceptedAt,
            timeZoneIdentifier: timeZoneIdentifier,
            opponent: opponentRequest
        )
        try engine.apply(event, to: &competition)

        XCTAssertEqual(
            event.id,
            "competition-event:v1:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:invitation-accepted"
        )
        XCTAssertEqual(event.occurredAt, acceptedAt)
        XCTAssertEqual(competition.schedule?.calendar.timeZoneIdentifier, timeZoneIdentifier)
        XCTAssertEqual(
            competition.schedule?.startDay,
            try CompetitionDay(
                era: 1,
                year: 2027,
                month: 1,
                day: 1,
                timeZoneIdentifier: timeZoneIdentifier
            )
        )
        XCTAssertEqual(competition.lifecycle, .scheduled)
    }

    func testPendingInvitationCanBeDeclinedOrExpireAtItsConfiguredDeadline() throws {
        var declined = pending()
        let declinedAt = date(2026, 8, 9, 11)
        try engine.apply(engine.decline(declined, at: declinedAt), to: &declined)
        XCTAssertEqual(declined.lifecycle, .declined(at: declinedAt))

        var expiring = pending(expiresAt: date(2026, 8, 10, 10))
        XCTAssertTrue(try engine.observeClock(expiring, at: date(2026, 8, 10, 9)).isEmpty)
        let expiryEvents = try engine.observeClock(expiring, at: date(2026, 8, 10, 10))
        XCTAssertEqual(expiryEvents.map(\.kind), [.invitationExpired])
        try engine.apply(expiryEvents, to: &expiring)
        XCTAssertEqual(expiring.lifecycle, .expired(at: date(2026, 8, 10, 10)))
    }

    func testAcceptanceAtOrAfterConfiguredExpiryProducesExpiryInsteadOfSchedule() throws {
        for acceptedAt in [date(2026, 8, 10, 10), date(2026, 8, 10, 11)] {
            let expiry = date(2026, 8, 10, 10)
            var competition = pending(expiresAt: expiry)

            let event = try engine.accept(
                competition,
                at: acceptedAt,
                timeZoneIdentifier: timeZoneIdentifier,
                opponent: opponentRequest
            )
            XCTAssertEqual(event.kind, .invitationExpired)
            XCTAssertEqual(event.occurredAt, expiry)
            try engine.apply(event, to: &competition)

            XCTAssertEqual(competition.lifecycle, .expired(at: expiry))
            XCTAssertNil(competition.schedule)
        }
    }

    func testDeclineAtOrAfterConfiguredExpiryProducesExpiryInsteadOfDecline() throws {
        for declinedAt in [date(2026, 8, 10, 10), date(2026, 8, 10, 11)] {
            let expiry = date(2026, 8, 10, 10)
            var competition = pending(expiresAt: expiry)

            let event = try engine.decline(competition, at: declinedAt)
            XCTAssertEqual(event.kind, .invitationExpired)
            XCTAssertEqual(event.occurredAt, expiry)
            try engine.apply(event, to: &competition)

            XCTAssertEqual(competition.lifecycle, .expired(at: expiry))
        }
    }

    func testClockObservationAdvancesThroughActiveDaysOneToSix() throws {
        var competition = try acceptedCompetition(acceptedAt: date(2026, 8, 9, 10))
        let dayOneStart = date(2026, 8, 10, 0)

        for ordinal in 1...6 {
            let observation = calendarDate(byAddingDays: ordinal - 1, to: dayOneStart)
            let events = try engine.observeClock(competition, at: observation)
            try engine.apply(events, to: &competition)

            XCTAssertEqual(
                competition.lifecycle,
                .active(day: try CompetitionActiveDay(ordinal))
            )
        }
    }

    func testDaySevenIsEndsTodayAndEndBoundaryOnlyEntersTallying() throws {
        var competition = try acceptedCompetition(acceptedAt: date(2026, 8, 9, 10))

        let daySevenEvents = try engine.observeClock(
            competition,
            at: date(2026, 8, 16, 0)
        )
        try engine.apply(daySevenEvents, to: &competition)
        XCTAssertEqual(competition.lifecycle, .endsToday)

        let endEvents = try engine.observeClock(
            competition,
            at: date(2026, 8, 17, 0)
        )
        XCTAssertEqual(endEvents.map(\.kind), [.dayClosed(7), .tallyStarted])
        try engine.apply(endEvents, to: &competition)
        guard case .tallying = competition.lifecycle else {
            return XCTFail("Crossing the end boundary must enter tallying")
        }
    }

    func testCatchUpEmitsBoundariesInSemanticOrderWithBoundaryTimestamps() throws {
        var competition = try acceptedCompetition(acceptedAt: date(2026, 8, 9, 10))

        let events = try engine.observeClock(competition, at: date(2026, 8, 17, 12))

        XCTAssertEqual(
            events.map(\.kind),
            [
                .competitionStarted,
                .dayClosed(1),
                .dayClosed(2),
                .dayClosed(3),
                .dayClosed(4),
                .dayClosed(5),
                .dayClosed(6),
                .finalDayStarted,
                .dayClosed(7),
                .tallyStarted,
            ]
        )
        XCTAssertEqual(events.first?.occurredAt, date(2026, 8, 10, 0))
        XCTAssertEqual(events.last?.occurredAt, date(2026, 8, 17, 0))

        try engine.apply(events, to: &competition)
        guard case .tallying = competition.lifecycle else {
            return XCTFail("Catch-up must stop at tallying, not invent a result")
        }
    }

    func testClockRollbackAndDuplicateObservationEmitNoInverseOrDuplicateEvents() throws {
        var competition = try acceptedCompetition(acceptedAt: date(2026, 8, 9, 10))
        let firstEvents = try engine.observeClock(competition, at: date(2026, 8, 13, 12))
        try engine.apply(firstEvents, to: &competition)
        XCTAssertEqual(
            competition.lifecycle,
            .active(day: try CompetitionActiveDay(4))
        )

        XCTAssertTrue(
            try engine.observeClock(competition, at: date(2026, 8, 11, 12)).isEmpty
        )
        XCTAssertTrue(
            try engine.observeClock(competition, at: date(2026, 8, 13, 12)).isEmpty
        )
        XCTAssertEqual(
            competition.lifecycle,
            .active(day: try CompetitionActiveDay(4))
        )
    }

    func testReapplyingSemanticEventIDIsANoOp() throws {
        var competition = try acceptedCompetition(acceptedAt: date(2026, 8, 9, 10))
        let event = try XCTUnwrap(
            engine.observeClock(competition, at: date(2026, 8, 10, 0)).first
        )

        try engine.apply(event, to: &competition)
        let afterFirstApplication = competition
        try engine.apply(event, to: &competition)

        XCTAssertEqual(competition, afterFirstApplication)
        XCTAssertEqual(
            competition.appliedEventIDs.filter { $0 == event.id }.count,
            1
        )
    }

    func testBatchApplyIsAtomicWhenALaterEventIsInvalid() throws {
        var competition = try acceptedCompetition(
            acceptedAt: date(2026, 8, 9, 10)
        )
        let original = competition
        let start = try XCTUnwrap(
            engine.observeClock(competition, at: date(2026, 8, 10, 0)).first
        )
        let otherID = CompetitionID(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let other = Competition.pending(
            id: otherID,
            direction: .incoming,
            createdAt: date(2026, 8, 9, 10),
            expiresAt: nil
        )
        let foreignEvent = try engine.decline(
            other,
            at: date(2026, 8, 9, 11)
        )

        XCTAssertThrowsError(
            try engine.apply([start, foreignEvent], to: &competition)
        ) { error in
            XCTAssertEqual(
                error as? CompetitionEngine.EngineError,
                .eventForDifferentCompetition
            )
        }
        XCTAssertEqual(competition, original)
    }

    func testDecodedEventRevalidatesItsDeterministicSemanticID() throws {
        let event = try engine.decline(pending(), at: date(2026, 8, 9, 11))
        let roundTrip = try JSONDecoder().decode(
            CompetitionEvent.self,
            from: JSONEncoder().encode(event)
        )
        XCTAssertEqual(roundTrip, event)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(event)
            ) as? [String: Any]
        )
        object["id"] = "tampered-event-id"
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(CompetitionEvent.self, from: tampered)
        )
    }

    func testDecodingRejectsActiveDayOutsideOneThroughSix() throws {
        for ordinal in [0, 7] {
            let payload = Data(
                #"{"active":{"day":\#(ordinal)}}"#.utf8
            )
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    CompetitionLifecycle.self,
                    from: payload
                )
            ) { error in
                XCTAssertEqual(
                    error as? CompetitionActiveDay.ValidationError,
                    .outsideActiveRange(ordinal)
                )
            }
        }
    }

    func testCompletedOutcomeCannotContradictSnapshotWhenDecoded() throws {
        let losingSnapshot = try FinalScoreSnapshot(
            userPoints: 1_000,
            opponentPoints: 1_100
        )
        let completed = CompletedCompetition(
            snapshot: losingSnapshot,
            basis: .bestAvailable,
            completedAt: date(2026, 8, 17, 1)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(completed)
            ) as? [String: Any]
        )
        object["outcome"] = "win"

        let decoded = try JSONDecoder().decode(
            CompletedCompetition.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.outcome, .loss)
    }

    func testZeroReadTallyNeverReceivesFinalizationAuthorization() throws {
        let competition = try tallyingCompetition()
        let policy = FinalizationPolicy(
            minimumStabilityNanoseconds: 1,
            bestAvailableDeadline: date(2026, 8, 17, 0, 30)
        )

        XCTAssertEqual(
            policy.decision(
                for: competition,
                at: date(2026, 8, 17, 0, 1)
            ),
            .wait
        )
        XCTAssertEqual(
            policy.decision(
                for: competition,
                at: date(2026, 8, 17, 0, 30)
            ),
            .needsAttention(.noCompletePostBoundaryRead)
        )
    }

    func testFinalizationProducesExactWinLossAndTieOnlyFromTallying() throws {
        let cases: [(Double, Double, CompetitionOutcome)] = [
            (1_200, 1_100, .win),
            (1_100, 1_200, .loss),
            (1_200, 1_200, .tie),
        ]

        for (user, opponent, expectedOutcome) in cases {
            let competition = try completedCompetition(
                userPoints: user,
                opponentPoints: opponent,
                basis: .stableAcrossPostBoundaryReads
            )

            guard case let .completed(completed) = competition.lifecycle else {
                return XCTFail("Expected a completed competition")
            }
            XCTAssertEqual(completed.outcome, expectedOutcome)
            XCTAssertEqual(completed.snapshot.userPoints, user)
            XCTAssertEqual(completed.snapshot.opponentPoints, opponent)
            XCTAssertEqual(completed.basis, .stableAcrossPostBoundaryReads)
        }
    }

    func testCompletedCompetitionCanBeArchivedExactlyOnce() throws {
        var competition = try completedCompetition(
            userPoints: 10,
            opponentPoints: 5,
            basis: .bestAvailable
        )

        let archive = try engine.archive(competition, at: date(2026, 8, 18, 9))
        try engine.apply(archive, to: &competition)
        let archived = competition
        try engine.apply(archive, to: &competition)

        XCTAssertEqual(competition, archived)
        guard case let .archived(record) = competition.lifecycle else {
            return XCTFail("Expected archived state")
        }
        XCTAssertEqual(record.completed.outcome, .win)
        XCTAssertEqual(record.archivedAt, date(2026, 8, 18, 9))
    }

    func testRematchCreatesNewPendingIdentityWithoutReopeningOriginalAggregate() throws {
        let tallying = try tallyingCompetition()
        let original = try completedCompetition(
            userPoints: 10,
            opponentPoints: 5,
            basis: .stableAcrossPostBoundaryReads
        )
        let newID = CompetitionID(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )

        let rematch = try engine.rematch(
            from: original,
            newID: newID,
            createdAt: date(2026, 8, 18, 10),
            expiresAt: date(2026, 8, 20, 10)
        )

        XCTAssertEqual(original.id, competitionID)
        XCTAssertEqual(rematch.id, newID)
        XCTAssertNotEqual(rematch.id, original.id)
        guard case let .pendingInvitation(invitation) = rematch.lifecycle else {
            return XCTFail("A rematch must be a new pending invitation")
        }
        XCTAssertEqual(invitation.direction, .outgoing)
        XCTAssertNil(rematch.schedule)
        XCTAssertTrue(rematch.appliedEventIDs.isEmpty)

        XCTAssertThrowsError(
            try engine.rematch(
                from: tallying,
                newID: newID,
                createdAt: date(2026, 8, 18, 10),
                expiresAt: nil
            )
        )

        XCTAssertThrowsError(
            try engine.rematch(
                from: original,
                newID: original.id,
                createdAt: date(2026, 8, 18, 10),
                expiresAt: nil
            )
        )
    }

    private func pending(expiresAt: Date? = nil) -> Competition {
        Competition.pending(
            id: competitionID,
            direction: .incoming,
            createdAt: date(2026, 8, 9, 10),
            expiresAt: expiresAt
        )
    }

    private func acceptedCompetition(acceptedAt: Date) throws -> Competition {
        var competition = pending()
        try engine.apply(
            engine.accept(
                competition,
                at: acceptedAt,
                timeZoneIdentifier: timeZoneIdentifier,
                opponent: opponentRequest
            ),
            to: &competition
        )
        return competition
    }

    private func tallyingCompetition(
        opponentPoints: Double? = nil
    ) throws -> Competition {
        var competition: Competition
        if let opponentPoints {
            competition = pending()
            let schedule = try fixtureSchedule()
            let opponentPlan = try fixtureOpponentPlan(
                points: opponentPoints,
                schedule: schedule
            )
            try engine.apply(
                CompetitionEvent(
                    competitionID: competition.id,
                    occurredAt: date(2026, 8, 9, 10),
                    kind: .invitationAccepted(
                        try AcceptedCompetitionConfiguration(
                            schedule: schedule,
                            opponentPlan: opponentPlan
                        )
                    )
                ),
                to: &competition
            )
        } else {
            competition = try acceptedCompetition(
                acceptedAt: date(2026, 8, 9, 10)
            )
        }
        try engine.apply(
            engine.observeClock(competition, at: date(2026, 8, 17, 0)),
            to: &competition
        )
        return competition
    }

    private func completedCompetition(
        userPoints: Double,
        opponentPoints: Double,
        basis: FinalizationBasis
    ) throws -> Competition {
        var competition = try tallyingCompetition(
            opponentPoints: opponentPoints
        )
        let policy = FinalizationPolicy(
            minimumStabilityNanoseconds: 100,
            bestAvailableDeadline: date(2026, 8, 17, 0, 30)
        )
        let content = try completeContent(
            userPoints: userPoints,
            opponentPlan: try XCTUnwrap(competition.opponentPlan)
        )

        let firstRead = try FinalReadEvidence(
            attemptID: "completion-read-1",
            readAt: date(2026, 8, 17, 0, 1),
            monotonicInstant: MonotonicInstant(
                epochID: "lifecycle-test",
                nanoseconds: 100
            ),
            evaluableOrdinals: Set(1...7),
            acceptedScoreOrdinals: Set(1...7),
            missingOrdinals: [],
            unavailableOrdinals: [],
            completeWindowContent: content,
            opponentPlanIsFinal: true
        )
        try engine.apply(
            engine.recordFinalRead(
                competition,
                evidence: firstRead
            ),
            to: &competition
        )

        let decisionDate: Date
        if basis == .stableAcrossPostBoundaryReads {
            let secondRead = try FinalReadEvidence(
                attemptID: "completion-read-2",
                readAt: date(2026, 8, 17, 0, 3),
                monotonicInstant: MonotonicInstant(
                    epochID: "lifecycle-test",
                    nanoseconds: 200
                ),
                evaluableOrdinals: Set(1...7),
                acceptedScoreOrdinals: Set(1...7),
                missingOrdinals: [],
                unavailableOrdinals: [],
                completeWindowContent: content,
                opponentPlanIsFinal: true
            )
            try engine.apply(
                engine.recordFinalRead(
                    competition,
                    evidence: secondRead
                ),
                to: &competition
            )
            decisionDate = date(2026, 8, 17, 0, 3)
        } else {
            decisionDate = date(2026, 8, 17, 0, 30)
        }

        guard case let .finalize(authorization) = policy.decision(
            for: competition,
            at: decisionDate
        ) else {
            throw FixtureError.expectedAuthorization
        }
        XCTAssertEqual(authorization.basis, basis)
        let event = try engine.finalize(
            competition,
            authorization: authorization,
            at: decisionDate
        )
        try engine.apply(event, to: &competition)
        return competition
    }

    private func completeContent(
        userPoints: Double,
        opponentPlan: OpponentPlan
    ) throws -> CompleteWindowContent {
        let userDays = distribute(points: userPoints)
        return try CompleteWindowContent(
            days: (1...7).map { ordinal in
                WindowDayContent(
                    ordinal: ordinal,
                    userPoints: userDays[ordinal - 1],
                    opponentPoints: Double(
                        opponentPlan.days[ordinal - 1].finalPoints
                    ),
                    activityContentFingerprint: "lifecycle-day-\(ordinal)"
                )
            },
            opponentPlanVersion: opponentPlan.contentIdentity
        )
    }

    private func fixtureSchedule() throws -> CompetitionSchedule {
        let competitionCalendar = try CompetitionCalendar(
            timeZoneIdentifier: timeZoneIdentifier
        )
        return CompetitionSchedule(
            calendar: competitionCalendar,
            startDay: try CompetitionDay(
                era: 1,
                year: 2026,
                month: 8,
                day: 10,
                timeZoneIdentifier: timeZoneIdentifier
            )
        )
    }

    private func fixtureOpponentPlan(
        points: Double,
        schedule: CompetitionSchedule
    ) throws -> OpponentPlan {
        let pointsByDay = distribute(points: points)
        let integerPoints = try pointsByDay.map { dayPoints -> Int in
            guard let exact = Int(exactly: dayPoints) else {
                throw FixtureError.nonIntegralOpponentPoints
            }
            return exact
        }
        return try OpponentPlan(
            generatorVersion: OpponentGeneratorVersion(rawValue: 99),
            seed: UInt64(points),
            difficulty: .balanced,
            schedule: schedule,
            days: try (1...7).map { ordinal in
                let finalPoints = integerPoints[ordinal - 1]
                return try OpponentDayPlan(
                    ordinal: ordinal,
                    finalPoints: finalPoints,
                    checkpoints: [
                        try OpponentCheckpoint(
                            progressBasisPoints: 0,
                            cumulativePoints: 0
                        ),
                        try OpponentCheckpoint(
                            progressBasisPoints: 10_000,
                            cumulativePoints: finalPoints
                        ),
                    ]
                )
            }
        )
    }

    private func distribute(points: Double) -> [Double] {
        var remaining = points
        return (1...7).map { _ in
            let day = min(600, remaining)
            remaining -= day
            return day
        }
    }

    private enum FixtureError: Error {
        case expectedAuthorization
        case nonIntegralOpponentPoints
    }

    private var opponentRequest: OpponentPlanGenerationRequest {
        OpponentPlanGenerationRequest(
            seed: 42,
            generatorVersion: .v1,
            difficulty: .balanced
        )
    }

    private func calendarDate(byAddingDays days: Int, to date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar.date(byAdding: .day, value: days, to: date)!
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}
