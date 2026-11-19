import CompetitionCore
import XCTest

final class OpponentShadowPlanTests: XCTestCase {
    private func mondaySchedule() throws -> CompetitionSchedule {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        // Monday, Aug 17, 2026
        let start = try CompetitionDay(era: 1, year: 2026, month: 8, day: 17, timeZoneIdentifier: "UTC")
        return CompetitionSchedule(calendar: calendar, startDay: start)
    }

    func testShadowProfileRequiresAtLeastThreeValidSamples() throws {
        XCTAssertThrowsError(try OpponentShadowProfile(samples: []))
        let two = try [
            OpponentRivalSample(weekday: 2, points: 320),
            OpponentRivalSample(weekday: 3, points: 410),
        ]
        XCTAssertThrowsError(try OpponentShadowProfile(samples: two))
        XCTAssertThrowsError(try OpponentRivalSample(weekday: 0, points: 300))
        XCTAssertThrowsError(try OpponentRivalSample(weekday: 8, points: 300))
        XCTAssertThrowsError(try OpponentRivalSample(weekday: 2, points: -1))
        XCTAssertThrowsError(try OpponentRivalSample(weekday: 2, points: 601))
    }

    func testShadowGeneratorVariesAcrossSeedsWithinRivalDistributionAndNeverClones100Percent() throws {
        // Mon..Sun: 340, 410, 290, 450, 380, 530, 470
        let historical = [340, 410, 290, 450, 380, 530, 470]
        let weekdays = [2, 3, 4, 5, 6, 7, 1]
        let samples = try zip(weekdays, historical).map {
            try OpponentRivalSample(weekday: $0, points: $1)
        }
        let profile = try OpponentShadowProfile(
            samples: samples,
            opponentName: "Dev Patel’s Shadow"
        )
        XCTAssertEqual(profile.bounds, 290...530)
        XCTAssertEqual(profile.mean, 410)

        let schedule = try mondaySchedule()
        var weeklyTotals = Set<Int>()
        var dailyValues = Set<Int>()
        var halfDayReveals = Set<Int>()

        for seed in UInt64(0)..<UInt64(64) {
            let plan = try OpponentPlanGenerator.generate(
                seed: seed,
                generatorVersion: .v4,
                difficulty: .shadow,
                schedule: schedule,
                shadowProfile: profile
            )
            XCTAssertEqual(plan.generatorVersion, .v4)
            XCTAssertEqual(plan.difficulty, .shadow)
            XCTAssertEqual(plan.opponentName, "Dev Patel’s Shadow")

            let finals = plan.days.map(\.finalPoints)
            XCTAssertNotEqual(finals, historical, "Seed \(seed) cloned the rival week 100%")
            for day in plan.days {
                XCTAssertTrue(
                    (290...530).contains(day.finalPoints),
                    "Day \(day.ordinal) (\(day.finalPoints)) escaped rival distribution 290...530"
                )
                dailyValues.insert(day.finalPoints)
                halfDayReveals.insert(
                    try plan.revealedPoints(dayOrdinal: day.ordinal, progressBasisPoints: 5_000)
                )
            }
            weeklyTotals.insert(finals.reduce(0, +))
        }

        XCTAssertGreaterThanOrEqual(weeklyTotals.count, 15)
        XCTAssertGreaterThanOrEqual(dailyValues.count, 20)
        XCTAssertGreaterThanOrEqual(halfDayReveals.count, 10)
    }

    func testShadowGeneratorPreservesRivalWeekdayShape() throws {
        // Two weeks where Mon–Fri are 240–300 and Sat–Sun are 500–560.
        let rawPairs: [(Int, Int)] = [
            (2, 250), (3, 280), (4, 240), (5, 300), (6, 270), (7, 540), (1, 510),
            (2, 260), (3, 290), (4, 255), (5, 285), (6, 275), (7, 560), (1, 520),
        ]
        let samples = try rawPairs.map { try OpponentRivalSample(weekday: $0.0, points: $0.1) }

        let profile = try OpponentShadowProfile(samples: samples)
        let schedule = try mondaySchedule()

        var weekdaySum = 0
        var weekdayCount = 0
        var weekendSum = 0
        var weekendCount = 0

        for seed in UInt64(1)...UInt64(40) {
            let plan = try OpponentPlanGenerator.generate(
                seed: seed,
                generatorVersion: .v4,
                difficulty: .shadow,
                schedule: schedule,
                shadowProfile: profile
            )
            // Schedule starts Monday: ordinals 1..5 are Mon..Fri, 6..7 are Sat..Sun.
            for day in plan.days {
                if day.ordinal <= 5 {
                    weekdaySum += day.finalPoints
                    weekdayCount += 1
                } else {
                    weekendSum += day.finalPoints
                    weekendCount += 1
                }
            }
        }

        let weekdayAvg = Double(weekdaySum) / Double(weekdayCount)
        let weekendAvg = Double(weekendSum) / Double(weekendCount)
        XCTAssertGreaterThan(weekendAvg - weekdayAvg, 120, "weekendAvg=\(weekendAvg), weekdayAvg=\(weekdayAvg)")
    }

    func testShadowPlanBindsCustomOpponentNameInCommitmentAndRoundTripsJSON() throws {
        let samples = try [
            OpponentRivalSample(weekday: 2, points: 360),
            OpponentRivalSample(weekday: 4, points: 420),
            OpponentRivalSample(weekday: 7, points: 510),
        ]
        let schedule = try mondaySchedule()
        let first = try OpponentPlanGenerator.generate(
            seed: 99,
            generatorVersion: .v4,
            difficulty: .shadow,
            schedule: schedule,
            shadowProfile: OpponentShadowProfile(samples: samples, opponentName: "Maya’s Shadow")
        )
        let second = try OpponentPlanGenerator.generate(
            seed: 99,
            generatorVersion: .v4,
            difficulty: .shadow,
            schedule: schedule,
            shadowProfile: OpponentShadowProfile(samples: samples, opponentName: "Sam’s Shadow")
        )
        XCTAssertNotEqual(first.commitmentHex, second.commitmentHex)
        XCTAssertNotEqual(first.contentIdentity, second.contentIdentity)

        let data = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(OpponentPlan.self, from: data)
        XCTAssertEqual(decoded, first)
        XCTAssertEqual(decoded.opponentName, "Maya’s Shadow")

        // Tampering opponentName breaks commitment verification on decode.
        let tampered = try XCTUnwrap(
            String(data: data, encoding: .utf8)?
                .replacingOccurrences(of: "Maya’s Shadow", with: "Sam’s Shadow")
                .data(using: .utf8)
        )
        XCTAssertThrowsError(try JSONDecoder().decode(OpponentPlan.self, from: tampered))
    }
}
