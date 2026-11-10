import Foundation
import XCTest

@testable import CompetitionCore

final class BotWeekTests: XCTestCase {
    func testGoldenTotalsAndMiddayReveal() {
        for golden in goldenWeeks {
            let totals = BotWeek.dailyTotals(
                seed: golden.seed,
                mode: golden.mode,
                baselineDailyPoints: golden.baseline
            )
            XCTAssertEqual(totals, golden.totals, "\(golden.mode) \(golden.seed) \(golden.baseline)")
            XCTAssertEqual(
                totals,
                BotWeek.dailyTotals(
                    seed: golden.seed,
                    mode: golden.mode,
                    baselineDailyPoints: golden.baseline
                )
            )
            for (offset, finalPoints) in totals.enumerated() {
                let day = offset + 1
                XCTAssertEqual(
                    BotWeek.revealed(
                        seed: golden.seed,
                        mode: golden.mode,
                        dayOrdinal: day,
                        finalPoints: finalPoints,
                        progressBasisPoints: 0
                    ),
                    0
                )
                XCTAssertEqual(
                    BotWeek.revealed(
                        seed: golden.seed,
                        mode: golden.mode,
                        dayOrdinal: day,
                        finalPoints: finalPoints,
                        progressBasisPoints: 5_000
                    ),
                    golden.atFiveThousand[offset]
                )
                XCTAssertEqual(
                    BotWeek.revealed(
                        seed: golden.seed,
                        mode: golden.mode,
                        dayOrdinal: day,
                        finalPoints: finalPoints,
                        progressBasisPoints: 10_000
                    ),
                    finalPoints
                )
            }
        }
    }

    func testRangesHoldForOneThousandSeeds() {
        let baselines = [100, 300, 600]
        for seed in UInt64(0)..<1_000 {
            for baseline in baselines {
                for mode in BotMode.allCases {
                    let totals = BotWeek.dailyTotals(
                        seed: seed,
                        mode: mode,
                        baselineDailyPoints: baseline
                    )
                    XCTAssertEqual(totals.count, 7)
                    XCTAssertTrue(totals.allSatisfy { (0...600).contains($0) })
                    switch mode {
                    case .pacer:
                        expect(totals, baseline: baseline, percents: 90...110, seed: seed, mode: mode)
                    case .chill:
                        expect(totals, baseline: baseline, percents: 75...90, seed: seed, mode: mode)
                    case .beast:
                        expect(totals, baseline: baseline, percents: 125...150, seed: seed, mode: mode)
                    case .erratic:
                        let high = allowedPoints(baseline: baseline, percents: 130...160)
                        let low = allowedPoints(baseline: baseline, percents: 30...65)
                        XCTAssertTrue(high.isDisjoint(with: low))
                        XCTAssertEqual(totals.filter { high.contains($0) }.count, 3, "high \(seed) \(baseline)")
                        XCTAssertEqual(totals.filter { low.contains($0) }.count, 4, "low \(seed) \(baseline)")
                    }
                }
            }
        }
    }

    func testRevealIsMonotonicBetweenPinnedEndpoints() {
        let probes = [0, 1, 1_427, 1_428, 1_429, 2_856, 2_857, 4_284, 4_285, 5_713, 5_714, 7_141, 7_142, 8_570, 8_571, 8_572, 9_999, 10_000]
        for seed in UInt64(0)..<1_000 {
            for baseline in [100, 300, 600] {
                for mode in BotMode.allCases {
                    let totals = BotWeek.dailyTotals(
                        seed: seed,
                        mode: mode,
                        baselineDailyPoints: baseline
                    )
                    for (offset, finalPoints) in totals.enumerated() {
                        var previous = 0
                        for progress in probes {
                            let value = BotWeek.revealed(
                                seed: seed,
                                mode: mode,
                                dayOrdinal: offset + 1,
                                finalPoints: finalPoints,
                                progressBasisPoints: progress
                            )
                            XCTAssertGreaterThanOrEqual(value, previous)
                            if progress == 0 {
                                XCTAssertEqual(value, 0)
                            }
                            if progress == 10_000 {
                                XCTAssertEqual(value, finalPoints)
                            }
                            previous = value
                        }
                    }
                }
            }
        }
    }

    func testStoredCheckpointsMatchRevealAtEveryProgress() throws {
        for golden in goldenWeeks {
            let plan = try generate(
                seed: golden.seed,
                mode: golden.mode,
                baseline: golden.baseline,
                startDay: 2
            )
            XCTAssertEqual(plan.days.map(\.finalPoints), golden.totals)
            for day in plan.days {
                var mismatch: String?
                for progress in 0...10_000 {
                    let stored = try plan.revealedPoints(
                        dayOrdinal: day.ordinal,
                        progressBasisPoints: progress
                    )
                    let live = BotWeek.revealed(
                        seed: golden.seed,
                        mode: golden.mode,
                        dayOrdinal: day.ordinal,
                        finalPoints: day.finalPoints,
                        progressBasisPoints: progress
                    )
                    if stored != live {
                        mismatch = "day \(day.ordinal) progress \(progress) stored \(stored) live \(live)"
                        break
                    }
                }
                XCTAssertNil(mismatch, mismatch ?? "")
            }
        }
    }

    func testVersionThreeRoundTripsAndReplays() throws {
        let engine = CompetitionEngine()
        for mode in BotMode.allCases {
            for seed in [UInt64(0), UInt64.max] {
                let plan = try generate(seed: seed, mode: mode, baseline: 300, startDay: 2)
                let again = try generate(seed: seed, mode: mode, baseline: 300, startDay: 2)
                XCTAssertEqual(again, plan)
                XCTAssertEqual(again.canonicalBytes, plan.canonicalBytes)
                XCTAssertEqual(plan.generatorVersion, .v3)
                XCTAssertEqual(plan.difficulty.rawValue, mode.rawValue)
                XCTAssertTrue(plan.contentIdentity.hasPrefix("opponent-plan:v1:g3:sha256:"))
                let decoded = try JSONDecoder().decode(
                    OpponentPlan.self,
                    from: JSONEncoder().encode(plan)
                )
                XCTAssertEqual(decoded, plan)
                XCTAssertEqual(decoded.canonicalBytes, plan.canonicalBytes)

                var competition = Competition.pending(
                    id: CompetitionID(UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
                    direction: .incoming,
                    createdAt: date(2026, 8, 9, 10),
                    expiresAt: nil
                )
                let event = try engine.accept(
                    competition,
                    at: date(2026, 12, 31, 23, 30),
                    timeZoneIdentifier: "America/Los_Angeles",
                    opponent: OpponentPlanGenerationRequest(
                        seed: seed,
                        generatorVersion: .v3,
                        difficulty: plan.difficulty,
                        baselineDailyPoints: 300
                    )
                )
                guard case let .invitationAccepted(configuration) = event.kind else {
                    return XCTFail("Acceptance must carry the v3 plan")
                }
                XCTAssertEqual(
                    configuration.opponentPlan,
                    try OpponentPlanGenerator.generate(
                        seed: seed,
                        generatorVersion: .v3,
                        difficulty: plan.difficulty,
                        schedule: configuration.schedule,
                        baselineDailyPoints: 300
                    )
                )
                try engine.apply(event, to: &competition)
                XCTAssertEqual(competition.opponentPlan, configuration.opponentPlan)
            }
        }
    }

    func testScheduleChangesTheCommitmentButNotTheWeek() throws {
        let first = try generate(seed: 1, mode: .erratic, baseline: 300, startDay: 2)
        let nextDay = try generate(seed: 1, mode: .erratic, baseline: 300, startDay: 3)
        XCTAssertEqual(first.days, nextDay.days)
        XCTAssertNotEqual(first.commitmentHex, nextDay.commitmentHex)
    }

    func testOldVersionTwoFixtureStillDecodes() throws {
        let decoded = try JSONDecoder().decode(
            OpponentPlan.self,
            from: Data(versionTwoFixtureJSON.utf8)
        )
        let regenerated = try OpponentPlanGenerator.generate(
            seed: 42,
            generatorVersion: .v2,
            difficulty: .challenging,
            schedule: schedule(startDay: 2),
            baselineDailyPoints: 350
        )
        XCTAssertEqual(decoded, regenerated)
        XCTAssertEqual(decoded.generatorVersion, .v2)
        XCTAssertEqual(decoded.difficulty, .challenging)
        XCTAssertEqual(decoded.days.map(\.finalPoints), [446, 435, 398, 418, 440, 405, 424])
        XCTAssertEqual(
            decoded.commitmentHex,
            "7eb4f46eb91a95d12f2244a85d2ec5b47e6845c9e6f3fa3a6c741809b3e5613e"
        )
        XCTAssertEqual(decoded.canonicalBytes, regenerated.canonicalBytes)
    }

    func testSeedDecimalEncoding() {
        XCTAssertEqual(BotWeek.decimalEncoding(of: 0), "0")
        XCTAssertEqual(BotWeek.decimalEncoding(of: .max), "18446744073709551615")
        XCTAssertEqual(BotWeek.seed(decimal: "0"), 0)
        XCTAssertEqual(BotWeek.seed(decimal: "18446744073709551615"), UInt64.max)
        XCTAssertEqual(BotWeek.seed(decimal: BotWeek.decimalEncoding(of: 42)), 42)
        for rejected in ["", "00", "01", "-1", "+1", " 1", "18446744073709551616", "1.0"] {
            XCTAssertNil(BotWeek.seed(decimal: rejected), rejected)
        }
    }

    func testGeneratorAcceptsBotModesOnlyOnVersionThree() throws {
        let calendar = try schedule(startDay: 2)
        XCTAssertThrowsError(
            try OpponentPlanGenerator.generate(
                seed: 1,
                generatorVersion: .v3,
                difficulty: .balanced,
                schedule: calendar,
                baselineDailyPoints: 300
            )
        ) { error in
            XCTAssertEqual(error as? OpponentPlanError, .invalidDifficultyPolicy(dayOrdinal: 1))
        }
        for baseline in [nil, 99, 601] as [Int?] {
            XCTAssertThrowsError(
                try OpponentPlanGenerator.generate(
                    seed: 1,
                    generatorVersion: .v3,
                    difficulty: .pacer,
                    schedule: calendar,
                    baselineDailyPoints: baseline
                )
            ) { error in
                XCTAssertEqual(error as? OpponentPlanError, .invalidBaseline(baseline))
            }
        }
        XCTAssertThrowsError(
            try OpponentPlanGenerator.generate(
                seed: 1,
                generatorVersion: .v2,
                difficulty: .beast,
                schedule: calendar,
                baselineDailyPoints: 300
            )
        ) { error in
            XCTAssertEqual(error as? OpponentPlanError, .invalidDifficultyPolicy(dayOrdinal: 1))
        }
        XCTAssertThrowsError(
            try OpponentPlanGenerator.generate(
                seed: 1,
                generatorVersion: .v1,
                difficulty: .pacer,
                schedule: calendar,
                baselineDailyPoints: 300
            )
        ) { error in
            XCTAssertEqual(error as? OpponentPlanError, .invalidBaseline(300))
        }
        let legacy = try OpponentPlanGenerator.generate(
            seed: 0,
            generatorVersion: .v1,
            difficulty: .pacer,
            schedule: calendar
        )
        let bot = try generate(seed: 0, mode: .pacer, baseline: 300, startDay: 2)
        XCTAssertEqual(legacy.generatorVersion, .v1)
        XCTAssertNotEqual(legacy.days.map(\.finalPoints), bot.days.map(\.finalPoints))
    }

    private func expect(
        _ totals: [Int],
        baseline: Int,
        percents: ClosedRange<Int>,
        seed: UInt64,
        mode: BotMode
    ) {
        let allowed = allowedPoints(baseline: baseline, percents: percents)
        XCTAssertTrue(
            totals.allSatisfy { allowed.contains($0) },
            "\(mode) seed \(seed) baseline \(baseline) totals \(totals)"
        )
    }

    private func allowedPoints(baseline: Int, percents: ClosedRange<Int>) -> Set<Int> {
        Set(percents.map { percent in
            min(600, max(0, (baseline * percent + 50) / 100))
        })
    }

    private func generate(
        seed: UInt64,
        mode: BotMode,
        baseline: Int,
        startDay: Int
    ) throws -> OpponentPlan {
        try OpponentPlanGenerator.generate(
            seed: seed,
            generatorVersion: .v3,
            difficulty: OpponentDifficulty(rawValue: mode.rawValue)!,
            schedule: schedule(startDay: startDay),
            baselineDailyPoints: baseline
        )
    }

    private func schedule(startDay: Int) throws -> CompetitionSchedule {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "America/Los_Angeles")
        return CompetitionSchedule(
            calendar: calendar,
            startDay: try CompetitionDay(
                era: 1,
                year: 2027,
                month: 1,
                day: startDay,
                timeZoneIdentifier: "America/Los_Angeles"
            )
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
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

private struct GoldenWeek {
    let seed: UInt64
    let baseline: Int
    let mode: BotMode
    let totals: [Int]
    let atFiveThousand: [Int]
}

private let goldenWeeks: [GoldenWeek] = [
        GoldenWeek(seed: 0, baseline: 100, mode: .pacer, totals: [106, 105, 106, 94, 106, 99, 98], atFiveThousand: [45, 44, 45, 40, 45, 42, 41]),
        GoldenWeek(seed: 0, baseline: 100, mode: .chill, totals: [90, 79, 90, 87, 86, 85, 76], atFiveThousand: [16, 14, 16, 15, 15, 15, 13]),
        GoldenWeek(seed: 0, baseline: 100, mode: .erratic, totals: [46, 134, 154, 35, 38, 65, 137], atFiveThousand: [30, 57, 28, 14, 25, 43, 25]),
        GoldenWeek(seed: 0, baseline: 100, mode: .beast, totals: [134, 125, 126, 137, 142, 141, 148], atFiveThousand: [90, 84, 84, 92, 95, 94, 99]),
        GoldenWeek(seed: 0, baseline: 300, mode: .pacer, totals: [318, 315, 318, 282, 318, 297, 294], atFiveThousand: [136, 134, 136, 120, 136, 127, 125]),
        GoldenWeek(seed: 0, baseline: 300, mode: .chill, totals: [270, 237, 270, 261, 258, 255, 228], atFiveThousand: [49, 43, 49, 47, 47, 46, 41]),
        GoldenWeek(seed: 0, baseline: 300, mode: .erratic, totals: [138, 402, 462, 105, 114, 195, 411], atFiveThousand: [92, 172, 84, 44, 76, 131, 75]),
        GoldenWeek(seed: 0, baseline: 300, mode: .beast, totals: [402, 375, 378, 411, 426, 423, 444], atFiveThousand: [270, 252, 254, 276, 286, 284, 298]),
        GoldenWeek(seed: 0, baseline: 600, mode: .pacer, totals: [600, 600, 600, 564, 600, 594, 588], atFiveThousand: [257, 257, 257, 241, 257, 254, 251]),
        GoldenWeek(seed: 0, baseline: 600, mode: .chill, totals: [540, 474, 540, 522, 516, 510, 456], atFiveThousand: [99, 87, 99, 95, 94, 93, 83]),
        GoldenWeek(seed: 0, baseline: 600, mode: .erratic, totals: [276, 600, 600, 210, 228, 390, 600], atFiveThousand: [185, 257, 110, 89, 153, 262, 110]),
        GoldenWeek(seed: 0, baseline: 600, mode: .beast, totals: [600, 600, 600, 600, 600, 600, 600], atFiveThousand: [404, 404, 404, 404, 404, 404, 404]),
        GoldenWeek(seed: .max, baseline: 100, mode: .pacer, totals: [104, 105, 97, 96, 105, 109, 100], atFiveThousand: [44, 44, 41, 41, 44, 46, 42]),
        GoldenWeek(seed: .max, baseline: 100, mode: .chill, totals: [75, 84, 84, 77, 89, 78, 80], atFiveThousand: [13, 15, 15, 14, 16, 14, 14]),
        GoldenWeek(seed: .max, baseline: 100, mode: .erratic, totals: [137, 36, 49, 145, 137, 54, 34], atFiveThousand: [58, 24, 20, 26, 58, 36, 22]),
        GoldenWeek(seed: .max, baseline: 100, mode: .beast, totals: [129, 140, 144, 145, 131, 138, 126], atFiveThousand: [86, 94, 96, 97, 88, 92, 84]),
        GoldenWeek(seed: .max, baseline: 300, mode: .pacer, totals: [312, 315, 291, 288, 315, 327, 300], atFiveThousand: [133, 134, 124, 123, 134, 140, 128]),
        GoldenWeek(seed: .max, baseline: 300, mode: .chill, totals: [225, 252, 252, 231, 267, 234, 240], atFiveThousand: [41, 46, 46, 42, 49, 42, 44]),
        GoldenWeek(seed: .max, baseline: 300, mode: .erratic, totals: [411, 108, 147, 435, 411, 162, 102], atFiveThousand: [176, 72, 62, 79, 176, 109, 68]),
        GoldenWeek(seed: .max, baseline: 300, mode: .beast, totals: [387, 420, 432, 435, 393, 414, 378], atFiveThousand: [260, 282, 290, 292, 264, 278, 254]),
        GoldenWeek(seed: .max, baseline: 600, mode: .pacer, totals: [600, 600, 582, 576, 600, 600, 600], atFiveThousand: [257, 257, 249, 246, 257, 257, 257]),
        GoldenWeek(seed: .max, baseline: 600, mode: .chill, totals: [450, 504, 504, 462, 534, 468, 480], atFiveThousand: [82, 92, 92, 84, 98, 85, 88]),
        GoldenWeek(seed: .max, baseline: 600, mode: .erratic, totals: [600, 216, 294, 600, 600, 324, 204], atFiveThousand: [257, 145, 125, 110, 257, 218, 137]),
        GoldenWeek(seed: .max, baseline: 600, mode: .beast, totals: [600, 600, 600, 600, 600, 600, 600], atFiveThousand: [404, 404, 404, 404, 404, 404, 404]),
]

private let versionTwoFixtureJSON = #"""
{"days":[{"ordinal":1,"finalPoints":446,"checkpoints":[{"progressBasisPoints":0,"cumulativePoints":0},{"progressBasisPoints":1209,"cumulativePoints":101},{"progressBasisPoints":2285,"cumulativePoints":180},{"progressBasisPoints":3409,"cumulativePoints":252},{"progressBasisPoints":4398,"cumulativePoints":306},{"progressBasisPoints":5684,"cumulativePoints":362},{"progressBasisPoints":6664,"cumulativePoints":396},{"progressBasisPoints":7673,"cumulativePoints":421},{"progressBasisPoints":9043,"cumulativePoints":441},{"progressBasisPoints":10000,"cumulativePoints":446}]},{"ordinal":2,"finalPoints":435,"checkpoints":[{"cumulativePoints":0,"progressBasisPoints":0},{"cumulativePoints":108,"progressBasisPoints":1341},{"cumulativePoints":206,"progressBasisPoints":2747},{"cumulativePoints":304,"progressBasisPoints":4525},{"cumulativePoints":347,"progressBasisPoints":5519},{"cumulativePoints":398,"progressBasisPoints":7120},{"cumulativePoints":427,"progressBasisPoints":8724},{"cumulativePoints":435,"progressBasisPoints":10000}]},{"ordinal":3,"finalPoints":398,"checkpoints":[{"cumulativePoints":0,"progressBasisPoints":0},{"cumulativePoints":105,"progressBasisPoints":1422},{"cumulativePoints":191,"progressBasisPoints":2792},{"cumulativePoints":268,"progressBasisPoints":4291},{"cumulativePoints":322,"progressBasisPoints":5646},{"cumulativePoints":367,"progressBasisPoints":7210},{"cumulativePoints":390,"progressBasisPoints":8586},{"cumulativePoints":398,"progressBasisPoints":10000}]},{"ordinal":4,"finalPoints":418,"checkpoints":[{"progressBasisPoints":0,"cumulativePoints":0},{"progressBasisPoints":942,"cumulativePoints":75},{"progressBasisPoints":2321,"cumulativePoints":171},{"progressBasisPoints":3506,"cumulativePoints":241},{"progressBasisPoints":4318,"cumulativePoints":283},{"progressBasisPoints":5519,"cumulativePoints":334},{"progressBasisPoints":6666,"cumulativePoints":371},{"progressBasisPoints":7923,"cumulativePoints":399},{"progressBasisPoints":9076,"cumulativePoints":414},{"progressBasisPoints":10000,"cumulativePoints":418}]},{"ordinal":5,"finalPoints":440,"checkpoints":[{"progressBasisPoints":0,"cumulativePoints":0},{"progressBasisPoints":1495,"cumulativePoints":121},{"progressBasisPoints":2410,"cumulativePoints":186},{"progressBasisPoints":3569,"cumulativePoints":258},{"progressBasisPoints":4804,"cumulativePoints":321},{"progressBasisPoints":6065,"cumulativePoints":371},{"progressBasisPoints":7391,"cumulativePoints":410},{"progressBasisPoints":8563,"cumulativePoints":430},{"progressBasisPoints":10000,"cumulativePoints":440}]},{"ordinal":6,"finalPoints":405,"checkpoints":[{"progressBasisPoints":0,"cumulativePoints":0},{"progressBasisPoints":1312,"cumulativePoints":99},{"progressBasisPoints":2884,"cumulativePoints":199},{"progressBasisPoints":4301,"cumulativePoints":273},{"progressBasisPoints":5752,"cumulativePoints":331},{"progressBasisPoints":6917,"cumulativePoints":366},{"progressBasisPoints":8533,"cumulativePoints":396},{"progressBasisPoints":10000,"cumulativePoints":405}]},{"ordinal":7,"finalPoints":424,"checkpoints":[{"progressBasisPoints":0,"cumulativePoints":0},{"progressBasisPoints":1440,"cumulativePoints":113},{"progressBasisPoints":2302,"cumulativePoints":172},{"progressBasisPoints":3806,"cumulativePoints":261},{"progressBasisPoints":4800,"cumulativePoints":309},{"progressBasisPoints":6068,"cumulativePoints":358},{"progressBasisPoints":7340,"cumulativePoints":393},{"progressBasisPoints":8980,"cumulativePoints":419},{"progressBasisPoints":10000,"cumulativePoints":424}]}],"schedule":{"startDay":{"day":2,"timeZoneIdentifier":"America\/Los_Angeles","year":2027,"era":1,"month":1},"calendar":{"timeZoneIdentifier":"America\/Los_Angeles"}},"difficulty":"challenging","commitmentHex":"7eb4f46eb91a95d12f2244a85d2ec5b47e6845c9e6f3fa3a6c741809b3e5613e","schemaVersion":1,"seed":42,"generatorVersion":{"rawValue":2}}
"""#
