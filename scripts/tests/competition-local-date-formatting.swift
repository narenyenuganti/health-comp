import Foundation

@main
struct CompetitionLocalDateFormattingChecks {
    static func main() {
        let iso = ISO8601DateFormatter()
        func instant(_ text: String) -> Date { iso.date(from: text)! }
        // Folds U+2009 / U+202F (and any other whitespace) to one space.
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        func expect(_ actual: String, _ expected: String) {
            precondition(actual == expected, "Expected \"\(expected)\", got \"\(actual)\"")
        }
        func expect(_ actual: Double, _ expected: Double) {
            precondition(actual == expected, "Expected \(expected), got \(actual)")
        }
        func expect(_ actual: [Double], _ expected: [Double]) {
            precondition(actual == expected, "Expected \(expected), got \(actual)")
        }
        func require(_ text: String, contains parts: [String]) {
            for part in parts {
                precondition(normalized(text).contains(part), "Missing \(part) in \(text)")
            }
        }

        let us = Locale(identifier: "en_US")
        let de = Locale(identifier: "de_DE")
        let fr = Locale(identifier: "fr_FR")
        let utc = TimeZone(identifier: "UTC")!
        let la = TimeZone(identifier: "America/Los_Angeles")!

        // Numbers
        expect(competitionPointsText(382.2, locale: us), "382")
        expect(competitionPointsText(0.5, locale: us), "1")
        expect(competitionPointsText(2.5, locale: us), "3")
        expect(competitionPointsText(nil, locale: us), "--")
        expect(competitionPointsText(412.3, fractionDigits: 2, locale: us), "412.30")
        expect(competitionPointsText(1217, locale: de), "1.217")
        expect(normalized(competitionPointsText(1217, locale: fr)), "1 217")

        expect(competitionPointsAccessibilityText(nil, locale: us), "no points yet")
        expect(competitionPointsAccessibilityText(1, locale: us), "1 point")
        expect(competitionPointsAccessibilityText(0.6, locale: us), "1 point")
        expect(competitionPointsAccessibilityText(412.4, locale: us), "412 points")

        expect(competitionDisplayedMargin(userPoints: 0.03, opponentPoints: 0), 0)
        expect(competitionDisplayedMargin(userPoints: 412.54, opponentPoints: 412.46), 1)
        expect(competitionDisplayedMargin(userPoints: 412.46, opponentPoints: 412.54), -1)
        expect(competitionDisplayedMargin(userPoints: 382.2, opponentPoints: 0), 382)

        precondition(competitionFinalFractionDigits(userPoints: 412.3, opponentPoints: 412.0) == 2)
        precondition(competitionFinalFractionDigits(userPoints: 412, opponentPoints: 412) == 0)
        precondition(competitionFinalFractionDigits(userPoints: 420, opponentPoints: 412.3) == 0)
        precondition(competitionFinalFractionDigits(userPoints: 412.46, opponentPoints: 412.54) == 0)
        // More decimals until a decided result's numbers differ, capped at 4.
        precondition(competitionFinalFractionDigits(userPoints: 412.3333, opponentPoints: 412.3349) == 3)
        expect(competitionPointsText(412.3333, fractionDigits: 3, locale: us), "412.333")
        expect(competitionPointsText(412.3349, fractionDigits: 3, locale: us), "412.335")
        precondition(competitionFinalFractionDigits(userPoints: 412.30001, opponentPoints: 412.30002) == 4)

        expect(competitionRoundedParts([120.4, 80.4, 31.4], total: 232.2), [121, 80, 31])
        expect(competitionRoundedParts([0.5, 0.5, 0.5], total: 1.5), [0, 1, 1])
        expect(competitionRoundedParts([], total: 0), [])

        // Day
        let now = instant("2026-10-31T12:00:00Z")
        let nextYear = instant("2027-02-01T12:00:00Z")
        let thursday = instant("2026-10-29T19:00:00Z")
        expect(competitionDayText(thursday, now: now, locale: us, timeZone: la), "Thu, Oct 29")
        expect(competitionDayText(thursday, now: nextYear, locale: us, timeZone: la), "Thu, Oct 29, 2026")
        expect(competitionDayText(thursday, weekday: false, now: now, locale: us, timeZone: la), "Oct 29")
        let frenchDay = competitionDayText(thursday, now: now, locale: fr, timeZone: la)
        precondition(frenchDay.contains("29"), "Missing 29 in \(frenchDay)")
        precondition(frenchDay != "Thu, Oct 29", "French day matches English: \(frenchDay)")

        // Week
        let oct24 = instant("2026-10-24T00:00:00Z")
        let oct28 = instant("2026-10-28T00:00:00Z")
        let oct30 = instant("2026-10-30T00:00:00Z")
        let nov3 = instant("2026-11-03T00:00:00Z")
        expect(normalized(competitionWeekText(oct24, oct30, now: now, locale: us, timeZone: utc)), "Oct 24 – 30")
        expect(normalized(competitionWeekText(oct28, nov3, now: now, locale: us, timeZone: utc)), "Oct 28 – Nov 3")
        require(competitionWeekText(oct24, oct30, now: nextYear, locale: us, timeZone: utc), contains: ["2026"])

        // Moment
        let moment = instant("2026-10-28T04:41:00Z")
        expect(normalized(competitionMomentText(moment, now: now, locale: us, timeZone: la)), "Tue 9:41 PM")
        require(
            competitionMomentText(moment, now: instant("2026-11-20T12:00:00Z"), locale: us, timeZone: la),
            contains: ["Oct 27", "9:41"]
        )
        require(competitionMomentText(moment, now: now, locale: fr, timeZone: la), contains: ["21:41"])

        print("Competition local date formatting checks passed")
    }
}
