#if DEBUG

import CompetitionCore
import XCTest
@testable import HealthComp

final class AppleFitnessFeaturesTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let zone = "America/Los_Angeles"

    func testRivalTrophiesAndCalendarEntries() {
        let weeks = [
            week(0, "Maya", you: Array(repeating: 420, count: 7), them: Array(repeating: 380, count: 7)),
            week(1, "Maya", you: Array(repeating: 460, count: 7), them: Array(repeating: 400, count: 7)),
            week(2, "Jordan", you: Array(repeating: 300, count: 7), them: Array(repeating: 350, count: 7)),
        ]
        let trophies = competitionRivalTrophies(weeks.reversed())
        XCTAssertEqual(trophies.count, 1)
        XCTAssertEqual(trophies[0].opponentDisplayName, "Maya")
        XCTAssertEqual(trophies[0].wins, 2)
        XCTAssertEqual(trophies[0].recordText, "2–0")
        XCTAssertTrue(trophies[0].holdsBelt)

        let entries = competitionCalendarEntries(weeks)
        XCTAssertEqual(entries.count, 21)
        let months = competitionCalendarMonths(from: entries)
        XCTAssertFalse(months.isEmpty)
        XCTAssertTrue(months.allSatisfy { (0...6).contains($0.leadingBlanks) })
    }

    func testMatchFormSummaryAndRivalryTrends() {
        let weeks = [
            week(0, "Sam", you: Array(repeating: 300, count: 7), them: Array(repeating: 310, count: 7)),
            week(1, "Sam", you: Array(repeating: 320, count: 7), them: Array(repeating: 300, count: 7)),
            week(2, "Sam", you: Array(repeating: 340, count: 7), them: Array(repeating: 310, count: 7)),
            week(3, "Sam", you: Array(repeating: 450, count: 7), them: Array(repeating: 380, count: 7)),
        ]
        let summary = competitionFormSummary(weeks, metric: .all)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.recentDays.count, 7)
        XCTAssertEqual(summary?.baselineDayCount, 28)
        XCTAssertEqual(summary?.isAbove, true)
        XCTAssertTrue(summary?.statusLabel.hasPrefix("+") == true)

        let moveSummary = competitionFormSummary(weeks, metric: .move)
        XCTAssertNotNil(moveSummary)
        XCTAssertEqual(moveSummary?.metric, .move)

        let trends = competitionRivalryTrends(weeks, locale: locale)
        XCTAssertEqual(trends.map(\.id), ["avg", "day7", "ring", "winrate"])
    }

    func testRingsideHighlightsAndFriendSorting() {
        let liveMaya = liveWeek(0, "Maya", youToday: 420, themToday: 510, youTotal: 2_100, themTotal: 2_080)
        let liveJordan = liveWeek(1, "Jordan", youToday: 300, themToday: 290, youTotal: 1_500, themTotal: 1_515)
        let competitions = [liveMaya, liveJordan]

        let highlights = ringsideHighlights(competitions, locale: locale)
        XCTAssertEqual(highlights.count, 2)
        XCTAssertEqual(highlights[0].opponentName, "Maya")
        XCTAssertTrue(highlights[0].headline.contains("510"))
        XCTAssertEqual(highlights[1].opponentName, "Jordan")

        let maya = FriendPerson(
            id: UUID(uuidString: "D1000000-0000-4000-8000-000000000001")!,
            displayName: "Maya",
            username: "maya",
            relationship: .friend
        )
        let jordan = FriendPerson(
            id: UUID(uuidString: "D1000000-0000-4000-8000-000000000002")!,
            displayName: "Jordan",
            username: "jordan",
            relationship: .friend
        )
        let byName = sortedFriends([maya, jordan], by: .name, competitions: competitions)
        XCTAssertEqual(byName.map(\.displayName), ["Jordan", "Maya"])

        let byToday = sortedFriends([jordan, maya], by: .todayPoints, competitions: competitions)
        XCTAssertEqual(byToday.map(\.displayName), ["Maya", "Jordan"])

        let byMargin = sortedFriends([maya, jordan], by: .margin, competitions: competitions)
        XCTAssertEqual(byMargin.map(\.displayName), ["Jordan", "Maya"])
    }

    func testCornerTimeoutPresetsAndSummary() {
        var calendar = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: zone)!
        calendar.timeZone = tz
        let friday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15))!

        let todayEnd = CornerTimeoutPreset.forToday.endDate(from: friday, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: todayEnd), 21)
        XCTAssertTrue(CornerTimeoutStorage.isActive(at: friday, until: todayEnd))
        XCTAssertEqual(
            CornerTimeoutStorage.summaryText(until: todayEnd, now: friday, locale: locale, timeZone: tz),
            "Resting today"
        )

        let mondayEnd = CornerTimeoutPreset.untilMonday.endDate(from: friday, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: mondayEnd), 23)
        XCTAssertEqual(calendar.component(.weekday, from: mondayEnd), 2)
        XCTAssertTrue(
            CornerTimeoutStorage.summaryText(until: mondayEnd, now: friday, locale: locale, timeZone: tz)?
                .hasPrefix("Resting until ") == true
        )

        let nextMonthEnd = CornerTimeoutPreset.untilNextMonth.endDate(from: friday, calendar: calendar)
        XCTAssertEqual(calendar.component(.month, from: nextMonthEnd), 12)
        XCTAssertEqual(calendar.component(.day, from: nextMonthEnd), 1)
    }

    private func week(
        _ number: Int,
        _ opponent: String,
        you: [Double],
        them: [Double]
    ) -> LocalCompetitionPresentation {
        let calendar = try! CompetitionCalendar(timeZoneIdentifier: zone)
        var start = try! CompetitionDay(era: 1, year: 2026, month: 10, day: 5, timeZoneIdentifier: zone)
        for _ in 0..<(number * 7) { start = try! calendar.day(after: start) }
        let schedule = CompetitionSchedule(calendar: calendar, startDay: start)
        func split(_ points: Double) -> [Double] {
            let move = (points * 0.38).rounded(), exercise = (points * 0.30).rounded()
            return [move, exercise, points - move - exercise]
        }
        let days = try! calendar.sevenDayWindow(startingOn: start).enumerated().map { offset, day in
            var presentation = LocalCompetitionDayPresentation(
                day: day,
                ordinal: offset + 1,
                ownerAcceptedPoints: you[offset],
                ownerLatestAvailability: .observed,
                opponentRevealedPoints: them[offset],
                scoringPolicy: .remoteWireV1
            )
            presentation.ownerRingPoints = split(you[offset])
            presentation.opponentRingPoints = split(them[offset])
            return presentation
        }
        let userPoints = you.reduce(0, +), opponentPoints = them.reduce(0, +)
        let outcome: CompetitionOutcome = userPoints > opponentPoints ? .win
            : userPoints < opponentPoints ? .loss : .tie
        let completedAt = competitionScheduleBoundaries(schedule)!.end.addingTimeInterval(43_200)
        return LocalCompetitionPresentation(
            id: CompetitionID(UUID(uuidString: String(format: "C8000000-0000-4000-8000-0000000000%02X", number))!),
            ownerDisplayName: "Beta Alice",
            opponentDisplayName: opponent,
            opponentIdentity: "remote-profile:v1:\(opponent.lowercased())",
            lifecycle: .archived(
                outcome: outcome,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: completedAt,
                archivedAt: completedAt.addingTimeInterval(86_400)
            ),
            acceptedConfiguration: LocalCompetitionAcceptedPresentation(schedule: schedule, difficulty: .balanced),
            userPoints: userPoints,
            opponentPoints: opponentPoints,
            days: days,
            currentDayOrdinal: nil,
            lastRefresh: nil,
            tally: nil,
            terminalResult: LocalCompetitionTerminalPresentation(
                userPoints: userPoints,
                opponentPoints: opponentPoints,
                outcome: outcome,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: completedAt
            ),
            evaluatedAt: completedAt.addingTimeInterval(172_800),
            timeZoneIdentifier: zone
        )
    }

    private func liveWeek(
        _ number: Int,
        _ opponent: String,
        youToday: Double,
        themToday: Double,
        youTotal: Double,
        themTotal: Double
    ) -> LocalCompetitionPresentation {
        let calendar = try! CompetitionCalendar(timeZoneIdentifier: zone)
        let start = try! CompetitionDay(era: 1, year: 2026, month: 11, day: 16, timeZoneIdentifier: zone)
        let schedule = CompetitionSchedule(calendar: calendar, startDay: start)
        let days = try! calendar.sevenDayWindow(startingOn: start).enumerated().map { offset, day in
            LocalCompetitionDayPresentation(
                day: day,
                ordinal: offset + 1,
                ownerAcceptedPoints: offset == 4 ? youToday : 350,
                ownerLatestAvailability: offset <= 4 ? .observed : .notYetOccurred,
                opponentRevealedPoints: offset == 4 ? themToday : 340,
                scoringPolicy: .remoteWireV1
            )
        }
        let id = UUID(uuidString: String(format: "D1000000-0000-4000-8000-00000000000%d", number + 1))!
        return LocalCompetitionPresentation(
            id: CompetitionID(UUID(uuidString: String(format: "C9000000-0000-4000-8000-0000000000%02X", number))!),
            ownerDisplayName: "Beta Alice",
            opponentDisplayName: opponent,
            opponentIdentity: "remote-profile:v1:\(id.uuidString.lowercased())",
            lifecycle: .active(dayOrdinal: 5),
            acceptedConfiguration: LocalCompetitionAcceptedPresentation(schedule: schedule, difficulty: .balanced),
            userPoints: youTotal,
            opponentPoints: themTotal,
            days: days,
            currentDayOrdinal: 5,
            lastRefresh: nil,
            tally: nil,
            terminalResult: nil,
            evaluatedAt: Date(),
            timeZoneIdentifier: zone
        )
    }
}

#endif
