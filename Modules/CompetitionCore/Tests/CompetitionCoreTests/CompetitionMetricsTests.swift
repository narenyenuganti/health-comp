import CompetitionCore
import Foundation
import XCTest

final class CompetitionMetricsTests: XCTestCase {
    func testDefaultAndAllSubsetsHaveExactDailyMaximums() {
        XCTAssertEqual(CompetitionMetrics.threeRings.dailyMaximum, 600)
        XCTAssertEqual(CompetitionMetrics.threeRings.dailyMaximumCentipoints, 60_000)
        XCTAssertTrue(CompetitionMetrics.threeRings.isDefaultRings)
        XCTAssertEqual(CompetitionMetrics.all.dailyMaximum, 700)
        XCTAssertEqual(CompetitionMetrics.all.dailyMaximumCentipoints, 70_000)
        XCTAssertFalse(CompetitionMetrics.all.isDefaultRings)

        XCTAssertEqual(CompetitionMetrics([.move]).dailyMaximum, 200)
        XCTAssertEqual(CompetitionMetrics([.sleep]).dailyMaximum, 100)
        XCTAssertEqual(CompetitionMetrics([.move, .sleep]).dailyMaximum, 300)
        XCTAssertEqual(CompetitionMetrics([.move, .exercise]).dailyMaximum, 400)
        XCTAssertEqual(CompetitionMetrics([.move, .exercise, .sleep]).dailyMaximum, 500)
    }

    func testEmptyMaskFallsBackOrFailsValidation() {
        XCTAssertNil(CompetitionMetrics(validatingMove: false, exercise: false, stand: false, sleep: false))
        XCTAssertEqual(CompetitionMetrics(move: false, exercise: false, stand: false, sleep: false), .threeRings)
    }

    func testTogglingEnforcesMinimumOneAndAllowsAllFour() {
        var metrics = CompetitionMetrics.threeRings
        metrics = try! XCTUnwrap(metrics.toggling(.sleep))
        XCTAssertEqual(metrics, .all)
        XCTAssertEqual(metrics.count, 4)

        let moveOnly = CompetitionMetrics([.move])
        XCTAssertNil(moveOnly.toggling(.move))
        XCTAssertEqual(moveOnly.toggling(.sleep), [.move, .sleep])
    }

    func testActivityScoreCalculatorRespectsActiveRingsOnly() throws {
        let snapshot = try ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: ActivityRingReading(value: 600, goal: 600),
            exercise: ActivityRingReading(value: 60, goal: 30),
            standOrRoll: ActivityRingReading(value: nil, goal: nil),
            pauseState: .running
        )

        let moveExercise = ActivityScoreCalculator.score(
            snapshot,
            policy: .remoteWireV1,
            metrics: [.move, .exercise]
        )
        let score = try XCTUnwrap(moveExercise.availableScore)
        XCTAssertEqual(score.points, 300, accuracy: 0.001)

        let sleepOnly = ActivityScoreCalculator.score(
            snapshot,
            policy: .remoteWireV1,
            metrics: [.sleep]
        )
        XCTAssertEqual(try XCTUnwrap(sleepOnly.availableScore).points, 0)

        let threeRings = ActivityScoreCalculator.score(
            snapshot,
            policy: .remoteWireV1,
            metrics: .threeRings
        )
        XCTAssertNil(threeRings.availableScore)
    }

    func testBotScalingAndSleepWeekDeterminism() {
        XCTAssertEqual(CompetitionMetrics.threeRings.scaleBotActivityPoints(420), 420)
        XCTAssertEqual(CompetitionMetrics([.move, .exercise]).scaleBotActivityPoints(420), 280)
        XCTAssertEqual(CompetitionMetrics([.move]).scaleBotActivityPoints(420), 140)
        XCTAssertEqual(CompetitionMetrics([.sleep]).scaleBotActivityPoints(420), 0)

        let first = CompetitionMetrics.botSleepWeekBasisPoints(seed: 42, mode: .pacer, baselineBasisPoints: 8_000)
        let second = CompetitionMetrics.botSleepWeekBasisPoints(seed: 42, mode: .pacer, baselineBasisPoints: 8_000)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 7)
        XCTAssertTrue(first.allSatisfy { (0...SleepScore.maximumBasisPoints).contains($0) })

        let compID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let seatID = UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa")!
        let groupA = CompetitionMetrics.groupBotSleepBasisPoints(competitionID: compID, seatID: seatID, mode: .beast)
        let groupB = CompetitionMetrics.groupBotSleepBasisPoints(competitionID: compID, seatID: seatID, mode: .beast)
        XCTAssertEqual(groupA, groupB)
        XCTAssertTrue(groupA.allSatisfy { (0...SleepScore.maximumBasisPoints).contains($0) })
    }

    func testMatchDayScoreAllows70000WhenConfiguredForFourMetrics() throws {
        let seatID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        XCTAssertThrowsError(try MatchDayScore(seatID: seatID, ordinal: 1, value: .centipoints(65_000)))
        let score = try MatchDayScore(
            seatID: seatID,
            ordinal: 1,
            value: .centipoints(65_000),
            maximumCentipoints: CompetitionMetrics.all.dailyMaximumCentipoints
        )
        XCTAssertEqual(score.value, .centipoints(65_000))
        XCTAssertThrowsError(
            try MatchDayScore(
                seatID: seatID,
                ordinal: 1,
                value: .centipoints(70_001),
                maximumCentipoints: CompetitionMetrics.all.dailyMaximumCentipoints
            )
        )
    }
}
