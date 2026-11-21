import Foundation
import XCTest
@testable import CompetitionCore

final class SleepScoreTests: XCTestCase {
    private let day = try! CompetitionDay(era: 1, year: 2026, month: 11, day: 17, timeZoneIdentifier: "America/Los_Angeles")

    private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 17 + dayOffset, hour: hour, minute: minute))!
    }

    private func sample(_ from: Date, _ to: Date, _ source: SleepSource) -> SleepSample {
        SleepSample(interval: DateInterval(start: from, end: to), source: source)
    }

    func testEachPartFollowsItsCurve() {
        XCTAssertEqual(SleepScore.durationPoints(minutesAsleep: 480), 50)
        XCTAssertEqual(SleepScore.durationPoints(minutesAsleep: 240), 25)
        XCTAssertEqual(SleepScore.durationPoints(minutesAsleep: 720), 50, "past 8 hours scores nothing extra")
        XCTAssertEqual(SleepScore.durationPoints(minutesAsleep: .nan), 0)

        XCTAssertEqual(SleepScore.bedtimePoints(onsetMinutes: 330, usualOnsetMinutes: 300), 30, "30 min off is full")
        XCTAssertEqual(SleepScore.bedtimePoints(onsetMinutes: 225, usualOnsetMinutes: 300), 15, "75 min early is half")
        XCTAssertEqual(SleepScore.bedtimePoints(onsetMinutes: 420, usualOnsetMinutes: 300), 0, "2 h off is 0")
        XCTAssertEqual(SleepScore.bedtimePoints(onsetMinutes: 600, usualOnsetMinutes: nil), 30, "no history yet")

        XCTAssertEqual(SleepScore.interruptionPoints(awakeMinutes: 10), 20)
        XCTAssertEqual(SleepScore.interruptionPoints(awakeMinutes: 40), 10)
        XCTAssertEqual(SleepScore.interruptionPoints(awakeMinutes: 90), 0)
    }

    func testUsualBedtimeIsTheMedianOfAtLeastThreeNights() {
        XCTAssertNil(SleepScore.usualOnset([300, 310]))
        XCTAssertEqual(SleepScore.usualOnset([300, 400, 310]), 310)
        XCTAssertEqual(SleepScore.usualOnset([300, 400, 310, 320]), 315)
    }

    func testANightScoresItsMainSleepAndIgnoresTheNap() throws {
        let window = try XCTUnwrap(SleepScore.window(for: day))
        let samples = [
            sample(at(23, dayOffset: -1), at(2), .watch),
            sample(at(2, 30), at(7), .watch),
            sample(at(14), at(15), .watch),
        ]
        let night = SleepScore.night(samples, in: window, preference: .watch, usualOnsetMinutes: 330)
        XCTAssertEqual(night.minutesAsleep, 510, "the nap counts as time asleep")
        XCTAssertEqual(night.onsetMinutes, 300)
        XCTAssertEqual(night.awakeMinutes, 30, "the gap before the nap isn't a wake-up")
        XCTAssertEqual(night.durationPoints, 50)
        XCTAssertEqual(night.bedtimePoints, 30)
        XCTAssertEqual(night.interruptionPoints, 20 * 40 / 60, accuracy: 0.0001)
        XCTAssertEqual(night.basisPoints, 9_333)
        XCTAssertEqual(SleepScore.night([], in: window, preference: .automatic, usualOnsetMinutes: 300), .none)
    }

    func testWindowRunsSixToSixAndEndsOnTheWakeDay() throws {
        let window = try XCTUnwrap(SleepScore.window(for: day))
        XCTAssertEqual(window.start, at(18, dayOffset: -1))
        XCTAssertEqual(window.end, at(18))
    }

    func testOverlapsCountOnceAndSamplesAreClippedToTheWindow() throws {
        let window = try XCTUnwrap(SleepScore.window(for: day))
        let samples = [
            sample(at(17, dayOffset: -1), at(19, dayOffset: -1), .watch),
            sample(at(23, dayOffset: -1), at(3), .watch),
            sample(at(2), at(6), .watch),
        ]
        XCTAssertEqual(SleepScore.minutesAsleep(samples, in: window, preference: .watch), 480)
    }

    func testAutomaticPrefersOuraAndNeverAddsTwoSources() throws {
        let window = try XCTUnwrap(SleepScore.window(for: day))
        let samples = [
            sample(at(23, dayOffset: -1), at(6), .watch),
            sample(at(23, dayOffset: -1), at(6, 18), .oura),
        ]
        XCTAssertEqual(SleepScore.minutesAsleep(samples, in: window, preference: .automatic), 438)
        XCTAssertEqual(SleepScore.minutesAsleep(samples, in: window, preference: .watch), 420)
        let watchOnly = samples.filter { $0.source == .watch }
        XCTAssertEqual(SleepScore.minutesAsleep(watchOnly, in: window, preference: .automatic), 420)
        XCTAssertEqual(SleepScore.minutesAsleep(watchOnly, in: window, preference: .oura), 0)
    }
}
