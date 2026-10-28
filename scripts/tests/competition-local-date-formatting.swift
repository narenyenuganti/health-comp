import Foundation

@main
struct CompetitionLocalDateFormattingChecks {
    static func main() {
        let iso = ISO8601DateFormatter()
        func instant(_ text: String) -> Date { iso.date(from: text)! }
        func require(_ text: String, contains parts: [String]) {
            let normalized = text.replacingOccurrences(
                of: "\\s+", with: " ", options: .regularExpression
            )
            for part in parts {
                precondition(normalized.contains(part), "Missing \(part) in \(text)")
            }
        }

        let start = instant("2026-10-28T07:00:00Z")
        let end = instant("2026-11-04T08:00:00Z")
        precondition(end.timeIntervalSince(start) == 169 * 3_600)
        let us = Locale(identifier: "en_US")
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let ny = TimeZone(identifier: "America/New_York")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!

        require(competitionDateRangeText(start, end, locale: us, timeZone: la),
                contains: ["Oct 28", "Nov 4", "12:00 AM", "PDT", "PST"])
        require(competitionDateRangeText(start, end, locale: us, timeZone: ny),
                contains: ["Oct 28", "Nov 4", "3:00 AM", "EDT", "EST"])
        require(competitionDateRangeText(start, end, locale: us, timeZone: tokyo),
                contains: ["Oct 28", "Nov 4", "4:00 PM", "5:00 PM", "GMT+9"])
        require(competitionDateRangeText(start, end,
                                         locale: Locale(identifier: "fr_FR"), timeZone: tokyo),
                contains: ["16:00", "17:00"])

        let springStart = instant("2027-03-13T08:00:00Z")
        let springEnd = instant("2027-03-15T07:00:00Z")
        precondition(springEnd.timeIntervalSince(springStart) == 47 * 3_600)
        require(competitionDateRangeText(springStart, springEnd, locale: us, timeZone: la),
                contains: ["Mar 13", "Mar 15", "PST", "PDT"])

        let rollover = instant("2026-11-04T07:30:00Z")
        require(competitionDateTimeText(rollover, locale: us, timeZone: la),
                contains: ["Nov 3", "11:30 PM", "PST"])
        require(competitionDateTimeText(rollover, locale: us, timeZone: tokyo),
                contains: ["Nov 4", "4:30 PM", "GMT+9"])
        require(competitionAwardDateText(rollover, locale: us, timeZone: la),
                contains: ["Nov 3", "PST"])
        require(competitionAwardDateText(rollover, locale: us, timeZone: tokyo),
                contains: ["Nov 4", "GMT+9"])
        let french = Locale(identifier: "fr_FR")
        require(competitionDateTimeText(rollover, locale: french, timeZone: tokyo),
                contains: ["16:30", "GMT+9"])
        print("Competition local date formatting checks passed")
    }
}
