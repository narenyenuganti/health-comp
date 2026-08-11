import XCTest
@testable import CompetitionCore

final class ActivityScoreTests: XCTestCase {
    func testActiveEnergyMoveExerciseAndStandUsePublicPercentageFormula() throws {
        let snapshot = try makeSnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: (750, 500),
            exercise: (45, 30),
            standOrRoll: (18, 12)
        )

        let score = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot).availableScore
        )

        XCTAssertEqual(snapshot.moveMode, .activeEnergyKilocalories)
        XCTAssertEqual(snapshot.standMode, .standHours)
        XCTAssertEqual(score.movePercentage, 150)
        XCTAssertEqual(score.exercisePercentage, 150)
        XCTAssertEqual(score.standOrRollPercentage, 150)
        XCTAssertEqual(score.points, 450)
    }

    func testMoveMinutesAndRollUseTheirSelectedValuesAndGoals() throws {
        let snapshot = try makeSnapshot(
            moveMode: .moveMinutes,
            standMode: .rollHours,
            move: (80, 40),
            exercise: (15, 30),
            standOrRoll: (9, 12)
        )

        let score = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot).availableScore
        )

        XCTAssertEqual(snapshot.moveMode, .moveMinutes)
        XCTAssertEqual(snapshot.standMode, .rollHours)
        XCTAssertEqual(score.points, 325)
    }

    func testUnknownStandModeUsesReportedReadingWithoutFabricatingMode() throws {
        let unknown = try makeSnapshot(
            standMode: .unknown,
            move: (500, 500),
            exercise: (30, 30),
            standOrRoll: (9, 12)
        )
        let knownStand = try makeSnapshot(
            standMode: .standHours,
            move: (500, 500),
            exercise: (30, 30),
            standOrRoll: (9, 12)
        )

        let policy = ActivityScoringPolicy.appleCompatibility
        let unknownScore = try XCTUnwrap(
            ActivityScoreCalculator.score(
                unknown,
                policy: policy
            ).availableScore
        )
        let knownScore = try XCTUnwrap(
            ActivityScoreCalculator.score(
                knownStand,
                policy: policy
            ).availableScore
        )
        let roundTripped = try JSONDecoder().decode(
            ActivitySnapshot.self,
            from: JSONEncoder().encode(unknown)
        )

        XCTAssertEqual(unknownScore, knownScore)
        XCTAssertEqual(unknownScore.standOrRollPercentage, 75)
        XCTAssertEqual(roundTripped.standMode, .unknown)
        XCTAssertEqual(roundTripped.fingerprint, unknown.fingerprint)
        XCTAssertNotEqual(unknown.fingerprint, knownStand.fingerprint)
        XCTAssertTrue(
            unknown.fingerprint.rawValue.hasPrefix("activity-snapshot:v2:")
        )
    }

    func testDefaultPolicyPreservesFractionalPercentagesWithoutUndocumentedRounding() throws {
        let snapshot = try makeSnapshot(
            move: (1, 3),
            exercise: (1, 3),
            standOrRoll: (1, 3)
        )

        let score = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot).availableScore
        )

        XCTAssertEqual(score.movePercentage, 100.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(score.points, 100, accuracy: 1e-12)
    }

    func testAggregateDailyScoreIsCappedAtSixHundred() throws {
        let snapshot = try makeSnapshot(
            move: (4, 1),
            exercise: (4, 1),
            standOrRoll: (4, 1)
        )

        let score = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot).availableScore
        )

        XCTAssertEqual(score.points, ActivityScore.maximumDailyPoints)
    }

    func testSevenCappedDaysCannotExceedFortyTwoHundred() throws {
        let snapshot = try makeSnapshot(
            move: (4, 1),
            exercise: (4, 1),
            standOrRoll: (4, 1)
        )
        let score = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot).availableScore
        )

        let sevenDayTotal = Array(repeating: score, count: 7)
            .reduce(0) { $0 + $1.points }

        XCTAssertEqual(ActivityScore.maximumCompetitionPoints, 4_200)
        XCTAssertEqual(sevenDayTotal, ActivityScore.maximumCompetitionPoints)
    }

    func testMissingValueOrGoalKeepsSnapshotUnavailableRatherThanZero() throws {
        let missingValue = try makeSnapshot(move: (nil, 500))
        let missingGoal = try makeSnapshot(move: (200, nil))

        let missingValueResult = ActivityScoreCalculator.score(missingValue)
        let missingGoalResult = ActivityScoreCalculator.score(missingGoal)

        XCTAssertNil(missingValueResult.availableScore)
        XCTAssertEqual(missingValueResult.unavailableReasons, [.missingMoveValue])
        XCTAssertNil(missingGoalResult.availableScore)
        XCTAssertEqual(missingGoalResult.unavailableReasons, [.missingMoveGoal])
    }

    func testZeroGoalIsUnavailableButZeroValueWithPositiveGoalIsARealZero() throws {
        let zeroGoal = try makeSnapshot(move: (0, 0))
        let zeroValue = try makeSnapshot(
            move: (0, 500),
            exercise: (0, 30),
            standOrRoll: (0, 12)
        )

        let zeroGoalResult = ActivityScoreCalculator.score(zeroGoal)
        let zeroValueScore = try XCTUnwrap(
            ActivityScoreCalculator.score(zeroValue).availableScore
        )

        XCTAssertNil(zeroGoalResult.availableScore)
        XCTAssertEqual(zeroGoalResult.unavailableReasons, [.nonPositiveMoveGoal])
        XCTAssertEqual(zeroValueScore.points, 0)
    }

    func testAllUnavailableRingReasonsAreReportedTogether() throws {
        let snapshot = try makeSnapshot(
            move: (nil, nil),
            exercise: (10, 0),
            standOrRoll: (nil, 12)
        )

        let result = ActivityScoreCalculator.score(snapshot)

        XCTAssertEqual(
            result.unavailableReasons,
            [
                .missingMoveValue,
                .missingMoveGoal,
                .nonPositiveExerciseGoal,
                .missingStandOrRollValue,
            ]
        )
    }

    func testNonfiniteAndNegativeValuesAndGoalsAreRejected() throws {
        XCTAssertThrowsError(
            try ActivityRingReading(value: .nan, goal: 1)
        )
        XCTAssertThrowsError(
            try ActivityRingReading(value: .infinity, goal: 1)
        )
        XCTAssertThrowsError(
            try ActivityRingReading(value: -1, goal: 1)
        )
        XCTAssertThrowsError(
            try ActivityRingReading(value: 1, goal: .nan)
        )
        XCTAssertThrowsError(
            try ActivityRingReading(value: 1, goal: .infinity)
        )
        XCTAssertThrowsError(
            try ActivityRingReading(value: 1, goal: -1)
        )
    }

    func testExtremeFiniteInputsSaturateSafelyWithoutOverflowTrap() throws {
        let snapshot = try makeSnapshot(
            move: (.greatestFiniteMagnitude, .leastNonzeroMagnitude),
            exercise: (0, 1),
            standOrRoll: (0, 1)
        )
        let perRingUp = try ActivityScoringPolicy(
            quantization: ScoreQuantizationPolicy(
                stage: .perRing,
                mode: .up,
                increment: 1
            )
        )

        let compatibilityScore = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot).availableScore
        )
        let quantizedScore = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot, policy: perRingUp)
                .availableScore
        )

        XCTAssertTrue(compatibilityScore.movePercentage.isFinite)
        XCTAssertEqual(compatibilityScore.points, 600)
        XCTAssertTrue(quantizedScore.movePercentage.isFinite)
        XCTAssertEqual(quantizedScore.points, 600)
    }

    func testOverflowSizedPercentageSurvivesCoarseDownQuantization() throws {
        let snapshot = try makeSnapshot(
            move: (.greatestFiniteMagnitude, .leastNonzeroMagnitude),
            exercise: (0, 1),
            standOrRoll: (0, 1)
        )
        let quantization = try ScoreQuantizationPolicy(
            stage: .perRing,
            mode: .down,
            increment: 700
        )
        let uncappedPolicy = try ActivityScoringPolicy(
            quantization: quantization
        )
        let explicitlyCappedPolicy = try ActivityScoringPolicy(
            quantization: quantization,
            perRingCap: 200
        )

        let uncappedScore = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot, policy: uncappedPolicy)
                .availableScore
        )
        let explicitlyCappedScore = try XCTUnwrap(
            ActivityScoreCalculator.score(
                snapshot,
                policy: explicitlyCappedPolicy
            ).availableScore
        )

        XCTAssertTrue(uncappedScore.movePercentage.isFinite)
        XCTAssertEqual(uncappedScore.points, 600)
        XCTAssertEqual(explicitlyCappedScore.movePercentage, 0)
        XCTAssertEqual(explicitlyCappedScore.points, 0)
    }

    func testFinitePercentageIsNotClippedBeforePerRingQuantization() throws {
        let snapshot = try makeSnapshot(
            move: (8, 1),
            exercise: (0, 1),
            standOrRoll: (0, 1)
        )
        let coarseDown = try ActivityScoringPolicy(
            quantization: ScoreQuantizationPolicy(
                stage: .perRing,
                mode: .down,
                increment: 700
            )
        )

        let score = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot, policy: coarseDown)
                .availableScore
        )

        XCTAssertEqual(score.movePercentage, 700)
        XCTAssertEqual(score.points, 600)
    }

    func testSignedZeroIsNormalizedForValuesAndDeterministicFingerprinting() throws {
        let negativeZero = try makeSnapshot(move: (-0.0, 500))
        let positiveZero = try makeSnapshot(move: (0.0, 500))

        XCTAssertEqual(negativeZero.move.value?.bitPattern, 0.0.bitPattern)
        XCTAssertEqual(negativeZero.fingerprint, positiveZero.fingerprint)
    }

    func testQuantizationStageAndModeAreConfigurable() throws {
        let snapshot = try makeSnapshot(
            move: (0.3336, 1),
            exercise: (0.3336, 1),
            standOrRoll: (0.3336, 1)
        )
        let aggregateDown = try ActivityScoringPolicy(
            quantization: ScoreQuantizationPolicy(
                stage: .aggregate,
                mode: .down,
                increment: 1
            )
        )
        let perRingDown = try ActivityScoringPolicy(
            quantization: ScoreQuantizationPolicy(
                stage: .perRing,
                mode: .down,
                increment: 1
            )
        )

        let aggregateScore = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot, policy: aggregateDown)
                .availableScore
        )
        let perRingScore = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot, policy: perRingDown)
                .availableScore
        )

        XCTAssertEqual(aggregateScore.points, 100)
        XCTAssertEqual(perRingScore.points, 99)
    }

    func testOptionalPerRingCapIsAnExplicitPolicy() throws {
        let snapshot = try makeSnapshot(
            move: (4, 1),
            exercise: (1, 1),
            standOrRoll: (1, 1)
        )
        let uncapped = ActivityScoringPolicy.appleCompatibility
        let capped = try ActivityScoringPolicy(perRingCap: 200)

        let uncappedScore = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot, policy: uncapped)
                .availableScore
        )
        let cappedScore = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot, policy: capped)
                .availableScore
        )

        XCTAssertEqual(uncappedScore.points, 600)
        XCTAssertEqual(cappedScore.points, 400)
    }

    func testPerRingCapRemainsUpperBoundAfterUpQuantization() throws {
        let snapshot = try makeSnapshot(
            move: (1.9, 1),
            exercise: (0.5, 1),
            standOrRoll: (0.5, 1)
        )
        let policy = try ActivityScoringPolicy(
            quantization: ScoreQuantizationPolicy(
                stage: .perRing,
                mode: .up,
                increment: 150
            ),
            perRingCap: 200
        )

        let score = try XCTUnwrap(
            ActivityScoreCalculator.score(snapshot, policy: policy)
                .availableScore
        )

        XCTAssertEqual(score.movePercentage, 200)
        XCTAssertEqual(score.exercisePercentage, 150)
        XCTAssertEqual(score.standOrRollPercentage, 150)
        XCTAssertEqual(score.points, 500)
    }

    func testCompatibilityPolicyNamesIdentityQuantizationAndNoPerRingCap() {
        let policy = ActivityScoringPolicy.appleCompatibility

        XCTAssertEqual(
            policy.identity.rawValue,
            "activity-scoring-policy:v1:aggregate:none:3ff0000000000000:none:unavailable"
        )
        XCTAssertEqual(policy.quantization.stage, .aggregate)
        XCTAssertEqual(policy.quantization.mode, .none)
        XCTAssertNil(policy.perRingCap)
    }

    func testPausedSummaryBehaviorIsExplicitAndInjectable() throws {
        let snapshot = try makeSnapshot(isPaused: true)
        let unavailablePolicy = try ActivityScoringPolicy(
            pausedSummaryPolicy: .unavailable
        )
        let reportedValuesPolicy = try ActivityScoringPolicy(
            pausedSummaryPolicy: .scoreReportedValues
        )

        let unavailable = ActivityScoreCalculator.score(
            snapshot,
            policy: unavailablePolicy
        )
        let score = try XCTUnwrap(
            ActivityScoreCalculator.score(
                snapshot,
                policy: reportedValuesPolicy
            ).availableScore
        )

        XCTAssertEqual(unavailable.unavailableReasons, [.summaryPaused])
        XCTAssertEqual(score.points, 300)
    }

    func testUnknownOnlyPausePolicyScoresUnknownButRejectsKnownPaused() throws {
        let running = try makeSnapshot()
        let paused = try makeSnapshot(isPaused: true)
        let unknown = ActivitySnapshot(
            moveMode: running.moveMode,
            standMode: running.standMode,
            move: running.move,
            exercise: running.exercise,
            standOrRoll: running.standOrRoll,
            pauseState: .unknown
        )
        let policy = ActivityScoringPolicy.healthKitCompatibility
        let roundTrippedPolicy = try JSONDecoder().decode(
            ActivityScoringPolicy.self,
            from: JSONEncoder().encode(policy)
        )

        let runningScore = try XCTUnwrap(
            ActivityScoreCalculator.score(running, policy: policy)
                .availableScore
        )
        let unknownScore = try XCTUnwrap(
            ActivityScoreCalculator.score(unknown, policy: policy)
                .availableScore
        )
        let pausedResult = ActivityScoreCalculator.score(paused, policy: policy)

        XCTAssertEqual(unknownScore, runningScore)
        XCTAssertEqual(pausedResult.unavailableReasons, [.summaryPaused])
        XCTAssertEqual(roundTrippedPolicy, policy)
        XCTAssertEqual(
            policy.pausedSummaryPolicy,
            .scoreReportedValuesWhenUnknown
        )
        XCTAssertEqual(
            policy.identity.rawValue,
            "activity-scoring-policy:v1:aggregate:none:3ff0000000000000:none:scoreReportedValuesWhenUnknown"
        )
        XCTAssertEqual(
            ActivityScoreCalculator.score(
                unknown,
                policy: .appleCompatibility
            ).unavailableReasons,
            [.summaryPauseStateUnknown]
        )
    }

    func testInvalidQuantizationAndPerRingCapPoliciesAreRejected() {
        XCTAssertThrowsError(
            try ScoreQuantizationPolicy(
                stage: .aggregate,
                mode: .nearest,
                increment: 0
            )
        )
        XCTAssertThrowsError(try ActivityScoringPolicy(perRingCap: .nan))
        XCTAssertThrowsError(try ActivityScoringPolicy(perRingCap: -1))
    }

    private func makeSnapshot(
        moveMode: ActivityMoveMode = .activeEnergyKilocalories,
        standMode: ActivityStandMode = .standHours,
        move: (Double?, Double?) = (500, 500),
        exercise: (Double?, Double?) = (30, 30),
        standOrRoll: (Double?, Double?) = (12, 12),
        isPaused: Bool = false
    ) throws -> ActivitySnapshot {
        try ActivitySnapshot(
            moveMode: moveMode,
            standMode: standMode,
            move: ActivityRingReading(value: move.0, goal: move.1),
            exercise: ActivityRingReading(
                value: exercise.0,
                goal: exercise.1
            ),
            standOrRoll: ActivityRingReading(
                value: standOrRoll.0,
                goal: standOrRoll.1
            ),
            isPaused: isPaused
        )
    }
}
