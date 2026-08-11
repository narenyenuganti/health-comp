import Foundation
import XCTest

@testable import CompetitionCore

final class CompetitionCalendarTests: XCTestCase {
    func testCompetitionDayIdentityIncludesGregorianComponentsAndTimeZone() throws {
        let day = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 10,
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let identicalDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 10,
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let sameComponentsInAnotherZone = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 10,
            timeZoneIdentifier: "Asia/Tokyo"
        )

        XCTAssertEqual(day, identicalDay)
        XCTAssertEqual(Set([day, identicalDay]).count, 1)
        XCTAssertNotEqual(day, sameComponentsInAnotherZone)
        XCTAssertEqual(day.era, 1)
        XCTAssertEqual(day.year, 2026)
        XCTAssertEqual(day.month, 8)
        XCTAssertEqual(day.day, 10)
        XCTAssertEqual(day.timeZoneIdentifier, "America/Los_Angeles")
    }

    func testCompetitionDayRejectsInvalidGregorianComponentsAndUnknownTimeZone() {
        XCTAssertThrowsError(
            try CompetitionDay(
                era: 1,
                year: 2026,
                month: 2,
                day: 30,
                timeZoneIdentifier: "America/Los_Angeles"
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionDay.ValidationError,
                .invalidGregorianDate(era: 1, year: 2026, month: 2, day: 30)
            )
        }

        XCTAssertThrowsError(
            try CompetitionDay(
                era: 1,
                year: 2026,
                month: 8,
                day: 10,
                timeZoneIdentifier: "Not/A_Time_Zone"
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionDay.ValidationError,
                .invalidTimeZoneIdentifier("Not/A_Time_Zone")
            )
        }
    }

    func testAcceptsFoundationSupportedTimeZoneIdentifiersAndAliases() throws {
        for identifier in ["UTC", "Etc/UTC", "US/Pacific"] {
            XCTAssertNotNil(TimeZone(identifier: identifier))

            let competitionCalendar = try CompetitionCalendar(
                timeZoneIdentifier: identifier
            )
            let competitionDay = try CompetitionDay(
                era: 1,
                year: 2026,
                month: 8,
                day: 10,
                timeZoneIdentifier: identifier
            )

            XCTAssertEqual(competitionCalendar.timeZoneIdentifier, identifier)
            XCTAssertEqual(competitionDay.timeZoneIdentifier, identifier)
        }
    }

    func testCompetitionDayCodableRoundTripPersistsTimeZoneAndRevalidatesPayload() throws {
        let original = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 10,
            timeZoneIdentifier: "America/Los_Angeles"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CompetitionDay.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.timeZoneIdentifier, "America/Los_Angeles")

        let invalidPayload = try JSONSerialization.data(withJSONObject: [
            "era": 1,
            "year": 2026,
            "month": 2,
            "day": 30,
            "timeZoneIdentifier": "America/Los_Angeles",
        ])
        XCTAssertThrowsError(
            try JSONDecoder().decode(CompetitionDay.self, from: invalidPayload)
        )
    }

    func testAcceptanceSchedulesDayOneForTheNextCompetitionCalendarDay() throws {
        let competitionCalendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let acceptance = makeDate(
            era: 1,
            year: 2026,
            month: 12,
            day: 31,
            hour: 23,
            minute: 30,
            timeZoneIdentifier: "America/Los_Angeles"
        )

        let scheduledStart = try competitionCalendar.startDay(afterAcceptanceAt: acceptance)

        XCTAssertEqual(
            scheduledStart,
            try CompetitionDay(
                era: 1,
                year: 2027,
                month: 1,
                day: 1,
                timeZoneIdentifier: "America/Los_Angeles"
            )
        )
    }

    func testSevenDayWindowIncludesDayOneAndDaySevenAcrossMonthBoundary() throws {
        let competitionCalendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 1,
            day: 29,
            timeZoneIdentifier: "America/Los_Angeles"
        )

        let window = try competitionCalendar.sevenDayWindow(startingOn: start)

        XCTAssertEqual(window.count, 7)
        XCTAssertEqual(window.first, start)
        XCTAssertEqual(
            window.last,
            try CompetitionDay(
                era: 1,
                year: 2026,
                month: 2,
                day: 4,
                timeZoneIdentifier: "America/Los_Angeles"
            )
        )
    }

    func testSpringForwardAddsOneCalendarDayEvenThoughElapsedTimeIsTwentyThreeHours() throws {
        let competitionCalendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let springForwardDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 3,
            day: 8,
            timeZoneIdentifier: "America/Los_Angeles"
        )

        let nextDay = try competitionCalendar.day(after: springForwardDay)
        let start = try competitionCalendar.startOfDay(springForwardDay)
        let nextStart = try competitionCalendar.startOfDay(nextDay)

        XCTAssertEqual(
            nextDay,
            try CompetitionDay(
                era: 1,
                year: 2026,
                month: 3,
                day: 9,
                timeZoneIdentifier: "America/Los_Angeles"
            )
        )
        XCTAssertEqual(nextStart.timeIntervalSince(start), 23 * 60 * 60, accuracy: 0.001)
    }

    func testFallBackAddsOneCalendarDayEvenThoughElapsedTimeIsTwentyFiveHours() throws {
        let competitionCalendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let fallBackDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 11,
            day: 1,
            timeZoneIdentifier: "America/Los_Angeles"
        )

        let nextDay = try competitionCalendar.day(after: fallBackDay)
        let start = try competitionCalendar.startOfDay(fallBackDay)
        let nextStart = try competitionCalendar.startOfDay(nextDay)

        XCTAssertEqual(
            nextDay,
            try CompetitionDay(
                era: 1,
                year: 2026,
                month: 11,
                day: 2,
                timeZoneIdentifier: "America/Los_Angeles"
            )
        )
        XCTAssertEqual(nextStart.timeIntervalSince(start), 25 * 60 * 60, accuracy: 0.001)
    }

    func testDecodedCalendarKeepsCompetitionTimeZoneInsteadOfUsingCurrentCalendar() throws {
        let original = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let decoded = try JSONDecoder().decode(
            CompetitionCalendar.self,
            from: JSONEncoder().encode(original)
        )
        let instant = makeDate(
            era: 1,
            year: 2026,
            month: 8,
            day: 10,
            hour: 2,
            timeZoneIdentifier: "Etc/UTC"
        )

        let localDay = try decoded.day(containing: instant)

        XCTAssertEqual(decoded.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(
            localDay,
            try CompetitionDay(
                era: 1,
                year: 2026,
                month: 8,
                day: 9,
                timeZoneIdentifier: "America/Los_Angeles"
            )
        )
    }

    private func makeDate(
        era: Int,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0,
        timeZoneIdentifier: String
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            XCTFail("Test fixture uses an invalid time-zone identifier")
            return Date(timeIntervalSinceReferenceDate: 0)
        }
        calendar.timeZone = timeZone
        let components = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            era: era,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        guard let date = calendar.date(from: components) else {
            XCTFail("Test fixture uses invalid Gregorian components")
            return Date(timeIntervalSinceReferenceDate: 0)
        }
        return date
    }
}
