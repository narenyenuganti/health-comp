import Foundation
import XCTest

@testable import CompetitionCore

final class TallyReconciliationTests: XCTestCase {
    private let engine = CompetitionEngine()
    private let competitionID = CompetitionID(
        UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    )
    private let epoch = "process-launch-1"
    private let stabilityNanoseconds: UInt64 = 120_000_000_000

    func testContentFingerprintExcludesAttemptTimeAndMonotonicMetadata() throws {
        let content = try completeContent(daySevenUserPoints: 500)
        let first = try completeRead(
            attemptID: "attempt-1",
            wallMinute: 1,
            monotonicNanoseconds: 1_000,
            content: content
        )
        let second = try completeRead(
            attemptID: "attempt-2",
            wallMinute: 40,
            monotonicNanoseconds: 9_000,
            content: content
        )

        XCTAssertEqual(
            first.completeWindowFingerprint,
            second.completeWindowFingerprint
        )
        XCTAssertNotEqual(first.attemptID, second.attemptID)
        XCTAssertNotEqual(first.readAt, second.readAt)
        XCTAssertNotEqual(first.monotonicInstant, second.monotonicInstant)
    }

    func testCompleteEvidenceDerivesFingerprintAndSevenDayTotalsFromContent() throws {
        let content = try completeContent(daySevenUserPoints: 500)
        let evidence = try completeRead(
            attemptID: "derived-content",
            wallMinute: 1,
            monotonicNanoseconds: 1_000,
            content: content
        )

        XCTAssertEqual(evidence.completeWindowContent, content)
        XCTAssertEqual(evidence.completeWindowFingerprint, content.fingerprint)
        XCTAssertEqual(evidence.finalScoreSnapshot, content.finalScoreSnapshot)
        XCTAssertEqual(evidence.finalScoreSnapshot?.userPoints, 2_000)
        XCTAssertEqual(
            evidence.finalScoreSnapshot?.opponentPoints,
            Double(try fixtureOpponentPlan().days.reduce(0) {
                $0 + $1.finalPoints
            })
        )
    }

    func testChangedDailyContentChangesDerivedFingerprint() throws {
        let first = try completeRead(
            attemptID: "content-a",
            wallMinute: 1,
            monotonicNanoseconds: 1_000,
            content: try completeContent(daySevenUserPoints: 400)
        )
        let second = try completeRead(
            attemptID: "content-b",
            wallMinute: 2,
            monotonicNanoseconds: 2_000,
            content: try completeContent(daySevenUserPoints: 500)
        )

        XCTAssertNotEqual(
            first.completeWindowFingerprint,
            second.completeWindowFingerprint
        )
        XCTAssertNotEqual(first.finalScoreSnapshot, second.finalScoreSnapshot)
    }

    func testEvidenceRoundTripRecomputesAndIgnoresInjectedDerivedClaims() throws {
        let evidence = try completeRead(
            attemptID: "round-trip-content",
            wallMinute: 1,
            monotonicNanoseconds: 1_000
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(evidence)
            ) as? [String: Any]
        )
        var content = try XCTUnwrap(
            object["completeWindowContent"] as? [String: Any]
        )
        content["fingerprint"] = ["rawValue": "claimed-fingerprint"]
        content["finalScoreSnapshot"] = [
            "userPoints": 0,
            "opponentPoints": 4_200,
        ]
        object["completeWindowContent"] = content

        let decoded = try JSONDecoder().decode(
            FinalReadEvidence.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded, evidence)
        XCTAssertNotEqual(
            decoded.completeWindowFingerprint?.rawValue,
            "claimed-fingerprint"
        )
        XCTAssertEqual(
            decoded.finalScoreSnapshot?.outcome,
            evidence.finalScoreSnapshot?.outcome
        )
    }

    func testCompleteWindowContentRequiresExactlySevenValidCappedDays() throws {
        let valid = try completeContent(daySevenUserPoints: 600)
        XCTAssertEqual(valid.days.count, 7)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(valid.finalScoreSnapshot).userPoints,
            FinalScoreSnapshot.maximumPoints
        )

        var overCapDays = valid.days
        overCapDays[6] = WindowDayContent(
            ordinal: 7,
            userPoints: 601,
            opponentPoints: 0,
            activityContentFingerprint: "invalid-over-cap"
        )
        XCTAssertThrowsError(
            try CompleteWindowContent(
                days: overCapDays,
                opponentPlanVersion: "opponent-plan-v3"
            )
        )
        XCTAssertThrowsError(
            try CompleteWindowContent(
                days: Array(valid.days.dropLast()),
                opponentPlanVersion: "opponent-plan-v3"
            )
        )
    }

    func testFingerprintIsIndependentOfInputDayOrder() throws {
        let content = try completeContent(daySevenUserPoints: 500)
        let reordered = try CompleteWindowContent(
            days: Array(content.days.reversed()),
            opponentPlanVersion: content.opponentPlanVersion
        )

        XCTAssertEqual(reordered.fingerprint, content.fingerprint)
        XCTAssertEqual(reordered.finalScoreSnapshot, content.finalScoreSnapshot)
    }

    func testFingerprintNormalizesNegativeZeroPoints() throws {
        let positiveZero = try CompleteWindowContent(
            days: zeroPointDays(userZero: 0.0, opponentZero: 0.0),
            opponentPlanVersion: "opponent-plan-zero"
        )
        let negativeZero = try CompleteWindowContent(
            days: zeroPointDays(userZero: -0.0, opponentZero: -0.0),
            opponentPlanVersion: "opponent-plan-zero"
        )

        XCTAssertNotEqual(
            (0.0 as Double).bitPattern,
            (-0.0 as Double).bitPattern
        )
        XCTAssertEqual(negativeZero.finalScoreSnapshot, positiveZero.finalScoreSnapshot)
        XCTAssertEqual(negativeZero.fingerprint, positiveZero.fingerprint)
    }

    func testNoPostBoundaryReadWaitsBeforeFallbackDeadline() throws {
        let competition = try tallyingCompetition()
        let policy = fallbackPolicy(deadlineMinute: 30)

        XCTAssertEqual(
            policy.decision(for: competition, at: date(2026, 8, 17, 0, 10)),
            .wait
        )
    }

    func testPreBoundaryReadNeverSatisfiesFinalReconciliationOrFallback() throws {
        var competition = try tallyingCompetition()
        let preBoundary = try completeRead(
            attemptID: "pre-boundary",
            wallDate: date(2026, 8, 16, 23, 59),
            monotonicNanoseconds: 1_000
        )

        try record(preBoundary, in: &competition)

        let tally = try tallyState(competition)
        XCTAssertNil(tally.reconciliation.lastCompletePostBoundaryRead)
        XCTAssertEqual(tally.reconciliation.consecutiveStableCompleteReads, 0)
        XCTAssertEqual(
            fallbackPolicy(deadlineMinute: 30).decision(
                for: competition,
                at: date(2026, 8, 17, 0, 30)
            ),
            .needsAttention(.noCompletePostBoundaryRead)
        )
    }

    func testMissingDaySevenWaitsThenNeedsAttentionWithoutFabricatingZero() throws {
        var competition = try tallyingCompetition()
        let read = try incompleteRead(
            attemptID: "missing-seven",
            wallMinute: 2,
            monotonicNanoseconds: 1_000,
            missing: [7],
            unavailable: []
        )
        try record(read, in: &competition)

        let policy = fallbackPolicy(deadlineMinute: 30)
        XCTAssertEqual(
            policy.decision(for: competition, at: date(2026, 8, 17, 0, 10)),
            .wait
        )
        XCTAssertEqual(
            policy.decision(for: competition, at: date(2026, 8, 17, 0, 30)),
            .needsAttention(.missingActivity(ordinals: [7]))
        )
        XCTAssertNil(try tallyState(competition).reconciliation.latestAcceptedSnapshot)
    }

    func testTwoIdenticalCompletePostBoundaryReadsSeparatedMonotonicallyFinalizeOnce() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "stable-1",
                wallMinute: 1,
                monotonicNanoseconds: 1_000
            ),
            in: &competition
        )
        try record(
            completeRead(
                attemptID: "stable-2",
                wallMinute: 3,
                monotonicNanoseconds: 1_000 + stabilityNanoseconds
            ),
            in: &competition
        )

        let policy = fallbackPolicy(deadlineMinute: 30)
        let decision = policy.decision(
            for: competition,
            at: date(2026, 8, 17, 0, 3)
        )
        guard case let .finalize(authorization) = decision else {
            return XCTFail("Expected stable reconciliation to finalize")
        }
        XCTAssertEqual(
            authorization.basis,
            .stableAcrossPostBoundaryReads
        )

        let finalEvent = try engine.finalize(
            competition,
            authorization: authorization,
            at: date(2026, 8, 17, 0, 3)
        )
        try engine.apply(finalEvent, to: &competition)
        let completed = competition
        try engine.apply(finalEvent, to: &competition)

        XCTAssertEqual(competition, completed)
        XCTAssertEqual(
            competition.appliedEventIDs.filter { $0 == finalEvent.id }.count,
            1
        )
    }

    func testTwoTooCloseReadsAndElapsedWallTimeDoNotFinalizeWithoutAnotherRead() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "close-1",
                wallMinute: 1,
                monotonicNanoseconds: 1_000
            ),
            in: &competition
        )
        try record(
            completeRead(
                attemptID: "close-2",
                wallMinute: 2,
                monotonicNanoseconds: 1_000 + stabilityNanoseconds - 1
            ),
            in: &competition
        )

        let policy = fallbackPolicy(deadlineMinute: 60)
        XCTAssertEqual(
            policy.decision(for: competition, at: date(2026, 8, 17, 0, 40)),
            .wait
        )
        XCTAssertEqual(
            try tallyState(competition).reconciliation.consecutiveStableCompleteReads,
            2
        )

        try record(
            completeRead(
                attemptID: "close-3",
                wallMinute: 41,
                monotonicNanoseconds: 1_000 + stabilityNanoseconds
            ),
            in: &competition
        )
        guard case let .finalize(authorization) = policy.decision(
            for: competition,
            at: date(2026, 8, 17, 0, 41)
        ), authorization.basis == .stableAcrossPostBoundaryReads else {
            return XCTFail("A third qualifying read should finalize")
        }
    }

    func testLooseRecordTimePolicyCannotSatisfyLaterStrictDecisionPolicy() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "loose-record-1",
                wallMinute: 1,
                monotonicNanoseconds: 1_000
            ),
            in: &competition
        )
        try record(
            completeRead(
                attemptID: "loose-record-2",
                wallMinute: 2,
                monotonicNanoseconds: 1_001
            ),
            in: &competition
        )

        XCTAssertEqual(
            FinalizationPolicy(
                minimumStabilityNanoseconds: stabilityNanoseconds,
                bestAvailableDeadline: date(2026, 8, 17, 1)
            ).decision(for: competition, at: date(2026, 8, 17, 0, 3)),
            .wait
        )
    }

    func testStrictRecordTimePolicyCannotBlockLaterValidLooseDecisionPolicy() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "strict-record-1",
                wallMinute: 1,
                monotonicNanoseconds: 1_000
            ),
            in: &competition
        )
        try record(
            completeRead(
                attemptID: "strict-record-2",
                wallMinute: 2,
                monotonicNanoseconds: 1_010
            ),
            in: &competition
        )

        guard case let .finalize(authorization) = FinalizationPolicy(
            minimumStabilityNanoseconds: 10,
            bestAvailableDeadline: date(2026, 8, 17, 1)
        ).decision(for: competition, at: date(2026, 8, 17, 0, 3)),
              authorization.basis == .stableAcrossPostBoundaryReads
        else {
            return XCTFail("Decision policy must qualify raw monotonic separation")
        }
    }

    func testChangedCompleteDaySevenFingerprintResetsStability() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "original",
                wallMinute: 1,
                monotonicNanoseconds: 1_000,
                content: try completeContent(daySevenUserPoints: 400)
            ),
            in: &competition
        )
        try record(
            completeRead(
                attemptID: "changed",
                wallMinute: 3,
                monotonicNanoseconds: 1_000 + stabilityNanoseconds,
                content: try completeContent(daySevenUserPoints: 500)
            ),
            in: &competition
        )

        let reconciliation = try tallyState(competition).reconciliation
        XCTAssertEqual(reconciliation.consecutiveStableCompleteReads, 1)
        XCTAssertEqual(
            reconciliation.stabilityStart,
            MonotonicInstant(
                epochID: epoch,
                nanoseconds: 1_000 + stabilityNanoseconds
            )
        )
        XCTAssertEqual(
            fallbackPolicy(deadlineMinute: 30).decision(
                for: competition,
                at: date(2026, 8, 17, 0, 4)
            ),
            .wait
        )
    }

    func testIncompleteReadPreservesCompleteAnchorAndSameLaterCompleteReadFinalizes() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "complete-a",
                wallMinute: 1,
                monotonicNanoseconds: 1_000
            ),
            in: &competition
        )
        try record(
            incompleteRead(
                attemptID: "locked",
                wallMinute: 2,
                monotonicNanoseconds: 50_000,
                missing: [],
                unavailable: [7]
            ),
            in: &competition
        )

        let afterIncomplete = try tallyState(competition).reconciliation
        XCTAssertEqual(afterIncomplete.lastCompletePostBoundaryRead?.attemptID, "complete-a")
        XCTAssertEqual(afterIncomplete.consecutiveStableCompleteReads, 1)
        XCTAssertEqual(
            fallbackPolicy(deadlineMinute: 30).decision(
                for: competition,
                at: date(2026, 8, 17, 0, 2)
            ),
            .wait
        )

        try record(
            completeRead(
                attemptID: "complete-a-again",
                wallMinute: 3,
                monotonicNanoseconds: 1_000 + stabilityNanoseconds
            ),
            in: &competition
        )
        guard case let .finalize(authorization) = fallbackPolicy(
            deadlineMinute: 30
        ).decision(
            for: competition,
            at: date(2026, 8, 17, 0, 3)
        ), authorization.basis == .stableAcrossPostBoundaryReads else {
            return XCTFail("Absence of evidence must not erase the complete anchor")
        }
    }

    func testIncompleteLatestReadKeepsWaitingEvenAfterPriorStablePair() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "stable-before-incomplete-1",
                wallMinute: 1,
                monotonicNanoseconds: 1_000
            ),
            in: &competition
        )
        try record(
            completeRead(
                attemptID: "stable-before-incomplete-2",
                wallMinute: 3,
                monotonicNanoseconds: 1_000 + stabilityNanoseconds
            ),
            in: &competition
        )
        try record(
            incompleteRead(
                attemptID: "incomplete-latest",
                wallMinute: 4,
                monotonicNanoseconds: 1_000 + stabilityNanoseconds + 1,
                missing: [],
                unavailable: [7]
            ),
            in: &competition
        )

        XCTAssertEqual(
            try tallyState(competition).reconciliation.consecutiveStableCompleteReads,
            2
        )
        XCTAssertEqual(
            fallbackPolicy(deadlineMinute: 30).decision(
                for: competition,
                at: date(2026, 8, 17, 0, 5)
            ),
            .wait
        )
    }

    func testIncompleteLatestReadBlocksDeadlineFallbackUntilNewCompleteRead() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "fallback-anchor",
                wallMinute: 1,
                monotonicNanoseconds: 1_000
            ),
            in: &competition
        )
        try record(
            incompleteRead(
                attemptID: "fallback-latest-incomplete",
                wallMinute: 30,
                monotonicNanoseconds: 2_000,
                missing: [],
                unavailable: [7]
            ),
            in: &competition
        )

        XCTAssertEqual(
            fallbackPolicy(deadlineMinute: 30).decision(
                for: competition,
                at: date(2026, 8, 17, 0, 30)
            ),
            .needsAttention(
                .latestReadIncomplete(
                    missingOrdinals: [],
                    unavailableOrdinals: [7]
                )
            )
        )
        XCTAssertEqual(
            try tallyState(competition)
                .reconciliation
                .lastCompletePostBoundaryRead?
                .attemptID,
            "fallback-anchor"
        )
    }

    func testPreBoundaryEvidenceAppliedLaterDoesNotReplaceEligibleLatestRead() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "post-boundary-1",
                wallMinute: 1,
                monotonicNanoseconds: 1_000
            ),
            in: &competition
        )
        try record(
            completeRead(
                attemptID: "post-boundary-2",
                wallMinute: 3,
                monotonicNanoseconds: 1_000 + stabilityNanoseconds
            ),
            in: &competition
        )
        try record(
            completeRead(
                attemptID: "late-callback-pre-boundary",
                wallDate: date(2026, 8, 16, 23, 59),
                monotonicNanoseconds: 1_000 + stabilityNanoseconds + 1
            ),
            in: &competition
        )

        XCTAssertEqual(
            try tallyState(competition).reconciliation.latestAttempt?.attemptID,
            "post-boundary-2"
        )
        guard case .finalize = fallbackPolicy(deadlineMinute: 30).decision(
            for: competition,
            at: date(2026, 8, 17, 0, 4)
        ) else {
            return XCTFail("Pre-boundary callbacks must be absent from decision state")
        }
    }

    func testDuplicateAttemptCallbackUsesSameEventIDAndCannotAdvanceStability() throws {
        var competition = try tallyingCompetition()
        let read = try completeRead(
            attemptID: "same-attempt",
            wallMinute: 1,
            monotonicNanoseconds: 1_000
        )
        let firstEvent = try engine.recordFinalRead(
            competition,
            evidence: read
        )
        try engine.apply(firstEvent, to: &competition)
        let duplicateEvent = try engine.recordFinalRead(
            competition,
            evidence: read
        )
        try engine.apply(duplicateEvent, to: &competition)

        XCTAssertEqual(firstEvent.id, duplicateEvent.id)
        XCTAssertEqual(
            try tallyState(competition).reconciliation.consecutiveStableCompleteReads,
            1
        )
        XCTAssertEqual(
            competition.appliedEventIDs.filter { $0 == firstEvent.id }.count,
            1
        )
    }

    func testBackwardMonotonicCoordinateCreatesNewSafeAnchor() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "forward",
                wallMinute: 1,
                monotonicNanoseconds: stabilityNanoseconds + 10
            ),
            in: &competition
        )
        try record(
            completeRead(
                attemptID: "backward",
                wallMinute: 3,
                monotonicNanoseconds: 5
            ),
            in: &competition
        )

        let reconciliation = try tallyState(competition).reconciliation
        XCTAssertEqual(reconciliation.consecutiveStableCompleteReads, 1)
        XCTAssertEqual(
            reconciliation.stabilityStart,
            MonotonicInstant(epochID: epoch, nanoseconds: 5)
        )
    }

    func testDifferentMonotonicEpochCreatesNewSafeAnchor() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "old-epoch",
                wallMinute: 1,
                monotonicNanoseconds: 1_000
            ),
            in: &competition
        )
        let restarted = try completeRead(
            attemptID: "new-epoch",
            wallMinute: 4,
            monotonicNanoseconds: stabilityNanoseconds + 1_000,
            monotonicEpoch: "process-launch-2"
        )
        try record(restarted, in: &competition)

        let reconciliation = try tallyState(competition).reconciliation
        XCTAssertEqual(reconciliation.consecutiveStableCompleteReads, 1)
        XCTAssertEqual(reconciliation.stabilityStart, restarted.monotonicInstant)
    }

    func testBestAvailableDeadlineCanFinalizeAfterOneCompleteAcceptedWindow() throws {
        var competition = try tallyingCompetition()
        let read = try completeRead(
            attemptID: "only-complete",
            wallMinute: 1,
            monotonicNanoseconds: 1_000
        )
        try record(read, in: &competition)

        guard case let .finalize(authorization) = fallbackPolicy(
            deadlineMinute: 30
        ).decision(for: competition, at: date(2026, 8, 17, 0, 30)) else {
            return XCTFail("Expected safe best-available fallback")
        }
        XCTAssertEqual(authorization.snapshot, read.finalScoreSnapshot)
        XCTAssertEqual(authorization.basis, .bestAvailable)
    }

    func testBestAvailableUsesAcceptanceFromLatestCompleteFingerprint() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "accepted-old-content",
                wallMinute: 1,
                monotonicNanoseconds: 1_000,
                content: try completeContent(daySevenUserPoints: 400)
            ),
            in: &competition
        )
        let acceptedSnapshot = try XCTUnwrap(
            tallyState(competition).reconciliation.latestAcceptedSnapshot
        )
        try record(
            completeRead(
                attemptID: "unaccepted-new-content",
                wallMinute: 2,
                monotonicNanoseconds: 2_000,
                content: try completeContent(daySevenUserPoints: 500),
                acceptedScoreOrdinals: Set(1...6)
            ),
            in: &competition
        )

        XCTAssertEqual(
            try tallyState(competition).reconciliation.latestAcceptedSnapshot,
            acceptedSnapshot
        )
        XCTAssertEqual(
            fallbackPolicy(deadlineMinute: 30).decision(
                for: competition,
                at: date(2026, 8, 17, 0, 30)
            ),
            .needsAttention(.unacceptedScores(ordinals: [7]))
        )
    }

    func testDeadlineWithNeverEvaluableDayNeedsAttention() throws {
        var competition = try tallyingCompetition()
        try record(
            incompleteRead(
                attemptID: "never-seven",
                wallMinute: 1,
                monotonicNanoseconds: 1_000,
                missing: [7],
                unavailable: []
            ),
            in: &competition
        )

        XCTAssertEqual(
            fallbackPolicy(deadlineMinute: 30).decision(
                for: competition,
                at: date(2026, 8, 17, 0, 30)
            ),
            .needsAttention(.missingActivity(ordinals: [7]))
        )
    }

    func testDeadlineWithNoCompletePostBoundaryReadNeedsAttentionEvenIfAllOrdinalsAppeared() throws {
        var competition = try tallyingCompetition()
        try record(
            incompleteRead(
                attemptID: "partial-one",
                wallMinute: 1,
                monotonicNanoseconds: 1_000,
                missing: [7],
                unavailable: []
            ),
            in: &competition
        )
        try record(
            incompleteRead(
                attemptID: "partial-two",
                wallMinute: 2,
                monotonicNanoseconds: 2_000,
                missing: [1],
                unavailable: []
            ),
            in: &competition
        )

        XCTAssertEqual(
            try tallyState(competition).reconciliation.evaluableOrdinalsEver,
            Set(1...7)
        )
        XCTAssertEqual(
            fallbackPolicy(deadlineMinute: 30).decision(
                for: competition,
                at: date(2026, 8, 17, 0, 30)
            ),
            .needsAttention(.noCompletePostBoundaryRead)
        )
    }

    func testOpponentPlanMustBeFinalForStableOrFallbackFinalization() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "plan-open-1",
                wallMinute: 1,
                monotonicNanoseconds: 1_000,
                opponentPlanIsFinal: false
            ),
            in: &competition
        )
        try record(
            completeRead(
                attemptID: "plan-open-2",
                wallMinute: 3,
                monotonicNanoseconds: 1_000 + stabilityNanoseconds,
                opponentPlanIsFinal: false
            ),
            in: &competition
        )

        XCTAssertEqual(
            fallbackPolicy(deadlineMinute: 30).decision(
                for: competition,
                at: date(2026, 8, 17, 0, 10)
            ),
            .wait
        )
        XCTAssertEqual(
            fallbackPolicy(deadlineMinute: 30).decision(
                for: competition,
                at: date(2026, 8, 17, 0, 30)
            ),
            .needsAttention(.opponentPlanNotFinal)
        )
    }

    func testStableAndDeadlineRaceCanApplyOnlyFirstFinalizationEvent() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "race-1",
                wallMinute: 1,
                monotonicNanoseconds: 1_000
            ),
            in: &competition
        )
        try record(
            completeRead(
                attemptID: "race-2",
                wallMinute: 30,
                monotonicNanoseconds: 1_000 + stabilityNanoseconds
            ),
            in: &competition
        )

        let stablePolicy = FinalizationPolicy(
            minimumStabilityNanoseconds: stabilityNanoseconds,
            bestAvailableDeadline: date(2026, 8, 17, 1)
        )
        let deadlinePolicy = FinalizationPolicy(
            minimumStabilityNanoseconds: stabilityNanoseconds + 1,
            bestAvailableDeadline: date(2026, 8, 17, 0, 30)
        )
        guard case let .finalize(stableAuthorization) = stablePolicy.decision(
            for: competition,
            at: date(2026, 8, 17, 0, 30)
        ), case let .finalize(deadlineAuthorization) = deadlinePolicy.decision(
            for: competition,
            at: date(2026, 8, 17, 0, 30)
        ) else {
            return XCTFail("Expected divergent stable and deadline authorizations")
        }
        XCTAssertEqual(stableAuthorization.basis, .stableAcrossPostBoundaryReads)
        XCTAssertEqual(deadlineAuthorization.basis, .bestAvailable)
        let stableEvent = try engine.finalize(
            competition,
            authorization: stableAuthorization,
            at: date(2026, 8, 17, 0, 30)
        )
        let deadlineEvent = try engine.finalize(
            competition,
            authorization: deadlineAuthorization,
            at: date(2026, 8, 17, 0, 30)
        )
        XCTAssertEqual(stableEvent.id, deadlineEvent.id)

        try engine.apply(stableEvent, to: &competition)
        try engine.apply(deadlineEvent, to: &competition)

        guard case let .completed(completed) = competition.lifecycle else {
            return XCTFail("Expected exactly one completed result")
        }
        XCTAssertEqual(completed.basis, .stableAcrossPostBoundaryReads)
        XCTAssertEqual(
            competition.appliedEventIDs.filter { $0 == stableEvent.id }.count,
            1
        )
    }

    func testAuthorizationAndPrebuiltEventBecomeStaleAfterLaterIncompleteRead() throws {
        var competition = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "authorization-stable-1",
                wallMinute: 1,
                monotonicNanoseconds: 1_000
            ),
            in: &competition
        )
        try record(
            completeRead(
                attemptID: "authorization-stable-2",
                wallMinute: 3,
                monotonicNanoseconds: 1_000 + stabilityNanoseconds
            ),
            in: &competition
        )
        let policy = fallbackPolicy(deadlineMinute: 30)
        guard case let .finalize(authorization) = policy.decision(
            for: competition,
            at: date(2026, 8, 17, 0, 3)
        ) else {
            return XCTFail("Expected stable authorization")
        }
        let prebuiltEvent = try engine.finalize(
            competition,
            authorization: authorization,
            at: date(2026, 8, 17, 0, 3)
        )

        try record(
            incompleteRead(
                attemptID: "authorization-later-incomplete",
                wallMinute: 4,
                monotonicNanoseconds: 1_000 + stabilityNanoseconds + 1,
                missing: [],
                unavailable: [7]
            ),
            in: &competition
        )

        XCTAssertThrowsError(
            try engine.finalize(
                competition,
                authorization: authorization,
                at: date(2026, 8, 17, 0, 5)
            )
        )
        XCTAssertThrowsError(
            try engine.apply(prebuiltEvent, to: &competition)
        )
        guard case .tallying = competition.lifecycle else {
            return XCTFail("A stale event must not complete the aggregate")
        }
    }

    func testAuthorizationCannotFinalizeAnotherCompetition() throws {
        var source = try tallyingCompetition()
        try record(
            completeRead(
                attemptID: "wrong-competition-1",
                wallMinute: 1,
                monotonicNanoseconds: 1_000
            ),
            in: &source
        )
        try record(
            completeRead(
                attemptID: "wrong-competition-2",
                wallMinute: 3,
                monotonicNanoseconds: 1_000 + stabilityNanoseconds
            ),
            in: &source
        )
        guard case let .finalize(authorization) = fallbackPolicy(
            deadlineMinute: 30
        ).decision(for: source, at: date(2026, 8, 17, 0, 3)) else {
            return XCTFail("Expected source authorization")
        }
        let otherID = CompetitionID(
            UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        )
        let other = try tallyingCompetition(id: otherID)

        XCTAssertThrowsError(
            try engine.finalize(
                other,
                authorization: authorization,
                at: date(2026, 8, 17, 0, 3)
            )
        )
    }

    func testFinalScoreSnapshotRejectsNonFiniteNegativeAndOverCapValues() {
        for invalid in [-1, 4_200.1, .infinity, .nan] {
            XCTAssertThrowsError(
                try FinalScoreSnapshot(userPoints: invalid, opponentPoints: 0)
            )
            XCTAssertThrowsError(
                try FinalScoreSnapshot(userPoints: 0, opponentPoints: invalid)
            )
        }
    }

    private func record(
        _ evidence: FinalReadEvidence,
        in competition: inout Competition
    ) throws {
        let event = try engine.recordFinalRead(
            competition,
            evidence: evidence
        )
        try engine.apply(event, to: &competition)
    }

    private func fallbackPolicy(deadlineMinute: Int) -> FinalizationPolicy {
        FinalizationPolicy(
            minimumStabilityNanoseconds: stabilityNanoseconds,
            bestAvailableDeadline: date(2026, 8, 17, 0, deadlineMinute)
        )
    }

    private func completeRead(
        attemptID: String,
        wallMinute: Int,
        monotonicNanoseconds: UInt64,
        monotonicEpoch: String? = nil,
        content: CompleteWindowContent? = nil,
        opponentPlanIsFinal: Bool = true,
        acceptedScoreOrdinals: Set<Int> = Set(1...7)
    ) throws -> FinalReadEvidence {
        try completeRead(
            attemptID: attemptID,
            wallDate: date(2026, 8, 17, 0, wallMinute),
            monotonicNanoseconds: monotonicNanoseconds,
            monotonicEpoch: monotonicEpoch,
            content: content,
            opponentPlanIsFinal: opponentPlanIsFinal,
            acceptedScoreOrdinals: acceptedScoreOrdinals
        )
    }

    private func completeRead(
        attemptID: String,
        wallDate: Date,
        monotonicNanoseconds: UInt64,
        monotonicEpoch: String? = nil,
        content: CompleteWindowContent? = nil,
        opponentPlanIsFinal: Bool = true,
        acceptedScoreOrdinals: Set<Int> = Set(1...7)
    ) throws -> FinalReadEvidence {
        let content = try content ?? completeContent(daySevenUserPoints: 500)
        return try FinalReadEvidence(
            attemptID: attemptID,
            readAt: wallDate,
            monotonicInstant: MonotonicInstant(
                epochID: monotonicEpoch ?? epoch,
                nanoseconds: monotonicNanoseconds
            ),
            evaluableOrdinals: Set(1...7),
            acceptedScoreOrdinals: acceptedScoreOrdinals,
            missingOrdinals: [],
            unavailableOrdinals: [],
            completeWindowContent: content,
            opponentPlanIsFinal: opponentPlanIsFinal
        )
    }

    private func incompleteRead(
        attemptID: String,
        wallMinute: Int,
        monotonicNanoseconds: UInt64,
        missing: Set<Int>,
        unavailable: Set<Int>
    ) throws -> FinalReadEvidence {
        let unavailableOrdinals = missing.union(unavailable)
        let evaluable = Set(1...7).subtracting(unavailableOrdinals)
        return try FinalReadEvidence(
            attemptID: attemptID,
            readAt: date(2026, 8, 17, 0, wallMinute),
            monotonicInstant: MonotonicInstant(
                epochID: epoch,
                nanoseconds: monotonicNanoseconds
            ),
            evaluableOrdinals: evaluable,
            acceptedScoreOrdinals: evaluable,
            missingOrdinals: missing,
            unavailableOrdinals: unavailable,
            completeWindowContent: nil,
            opponentPlanIsFinal: true
        )
    }

    private func completeContent(
        daySevenUserPoints: Double
    ) throws -> CompleteWindowContent {
        let opponentPlan = try fixtureOpponentPlan()
        return try CompleteWindowContent(
            days: (1...7).map { ordinal in
                WindowDayContent(
                    ordinal: ordinal,
                    userPoints: ordinal == 7 ? daySevenUserPoints : 250,
                    opponentPoints: Double(
                        opponentPlan.days[ordinal - 1].finalPoints
                    ),
                    activityContentFingerprint: "activity-day-\(ordinal)-v1"
                )
            },
            opponentPlanVersion: opponentPlan.contentIdentity
        )
    }

    private func fixtureOpponentPlan() throws -> OpponentPlan {
        let competitionCalendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        return try OpponentPlanGenerator.generate(
            seed: 42,
            generatorVersion: .v1,
            difficulty: .balanced,
            schedule: CompetitionSchedule(
                calendar: competitionCalendar,
                startDay: try CompetitionDay(
                    era: 1,
                    year: 2026,
                    month: 8,
                    day: 10,
                    timeZoneIdentifier: "America/Los_Angeles"
                )
            )
        )
    }

    private func zeroPointDays(
        userZero: Double,
        opponentZero: Double
    ) -> [WindowDayContent] {
        (1...7).map { ordinal in
            WindowDayContent(
                ordinal: ordinal,
                userPoints: ordinal == 7 ? userZero : 250,
                opponentPoints: ordinal == 7 ? opponentZero : 240,
                activityContentFingerprint: "activity-day-\(ordinal)-zero"
            )
        }
    }

    private func tallyingCompetition(
        id: CompetitionID? = nil
    ) throws -> Competition {
        var competition = Competition.pending(
            id: id ?? competitionID,
            direction: .incoming,
            createdAt: date(2026, 8, 9, 10),
            expiresAt: nil
        )
        try engine.apply(
            engine.accept(
                competition,
                at: date(2026, 8, 9, 10),
                timeZoneIdentifier: "America/Los_Angeles",
                opponent: OpponentPlanGenerationRequest(
                    seed: 42,
                    generatorVersion: .v1,
                    difficulty: .balanced
                )
            ),
            to: &competition
        )
        try engine.apply(
            engine.observeClock(competition, at: date(2026, 8, 17, 0)),
            to: &competition
        )
        return competition
    }

    private func tallyState(_ competition: Competition) throws -> TallyingCompetition {
        guard case let .tallying(tally) = competition.lifecycle else {
            throw FixtureError.notTallying
        }
        return tally
    }

    private enum FixtureError: Error {
        case notTallying
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
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
