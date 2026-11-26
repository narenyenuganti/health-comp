#if DEBUG

import CompetitionCore
import XCTest
@testable import HealthComp

final class AppleFitnessFeaturesTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let zone = "America/Los_Angeles"

    func testRingStackKeepsOneFootprintForOneToFourRings() {
        XCTAssertEqual(CompetitionRingStackLayout(size: 200, count: 1).lineWidth, 30, accuracy: 0.001)
        for size in [26.0, 74, 200] as [CGFloat] {
            for count in 1...4 {
                let layout = CompetitionRingStackLayout(size: size, count: count)
                XCTAssertGreaterThan(layout.lineWidth, 0)
                XCTAssertLessThanOrEqual(layout.diameter(0) + layout.lineWidth, size + 0.001)
                let innermost = layout.diameter(count - 1) / 2 - layout.lineWidth / 2
                XCTAssertGreaterThanOrEqual(innermost, layout.hole - 0.001, "\(count) rings at \(size) pt")
            }
        }
    }

    func testRivalTrophiesAndCalendarEntries() throws {
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
        let sampleEntry = try XCTUnwrap(entries.values.first)
        XCTAssertTrue((1...7).contains(sampleEntry.dayOrdinal))
        XCTAssertEqual(sampleEntry.rings.count, 3)
        XCTAssertEqual(sampleEntry.rings.map(\.color), [Theme.move, Theme.exercise, Theme.stand])
        let months = competitionCalendarMonths(from: entries)
        XCTAssertFalse(months.isEmpty)
        XCTAssertTrue(months.allSatisfy { (0...6).contains($0.leadingBlanks) })

        var sleepWeek = week(3, "Sam", you: Array(repeating: 300, count: 7), them: Array(repeating: 250, count: 7))
        sleepWeek.metrics = [.move, .sleep]
        sleepWeek.days[0].metrics = [.move, .sleep]
        sleepWeek.days[0].ownerRingPoints = [120, 80, 90]
        sleepWeek.days[0].ownerSleepPoints = 84
        let sleepRings = competitionCalendarDayRings(sleepWeek.days[0], metrics: sleepWeek.metrics)
        XCTAssertEqual(sleepRings.count, 2)
        XCTAssertEqual(sleepRings[0].color, Theme.move)
        XCTAssertEqual(sleepRings[0].progress, 1.2, accuracy: 0.001)
        XCTAssertEqual(sleepRings[1].color, Theme.sleep)
        XCTAssertEqual(sleepRings[1].progress, 0.84, accuracy: 0.001)

        var path: [CompetitionID] = []
        var showsHistory = true
        var person: String?
        var ordinals: [CompetitionID: Int] = [:]
        let stack = CompetitionHomeRoute.stack(
            path: .init(get: { path }, set: { path = $0 }),
            showsHistory: .init(get: { showsHistory }, set: { showsHistory = $0 }),
            person: .init(get: { person }, set: { person = $0 }),
            dayOrdinals: .init(get: { ordinals }, set: { ordinals = $0 })
        )
        let targetID = weeks[0].id
        stack.wrappedValue.append(.competition(targetID, dayOrdinal: 4))
        XCTAssertEqual(path, [targetID])
        XCTAssertEqual(ordinals[targetID], 4)
        XCTAssertEqual(stack.wrappedValue, [.history, .competition(targetID, dayOrdinal: 4)])
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

    func testCompetitionDayRingsCoversAllFifteenMetricCombinations() throws {
        let day = try CompetitionDay(era: 1, year: 2026, month: 8, day: 10, timeZoneIdentifier: zone)
        let snapshot = try ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: ActivityRingReading(value: 400, goal: 500),
            exercise: ActivityRingReading(value: 45, goal: 30),
            standOrRoll: ActivityRingReading(value: 9, goal: 12),
            pauseState: .running
        )
        var observed = LocalCompetitionDayPresentation(
            day: day,
            ordinal: 3,
            ownerAcceptedPoints: 390,
            ownerLatestAvailability: .observed,
            opponentRevealedPoints: 340,
            ownerAcceptedSnapshot: snapshot,
            ownerLatestSnapshot: snapshot,
            scoringPolicy: .remoteWireV1
        )
        observed.ownerRingPoints = [80, 150, 75]
        observed.opponentRingPoints = [110, 90, 60]
        observed.ownerSleepPoints = 85
        observed.opponentSleepPoints = 80

        let expectedOwnerProgress: [CompetitionMetric: Double] = [
            .move: 0.8, .exercise: 1.5, .stand: 0.75, .sleep: 0.85,
        ]
        let expectedOpponentProgress: [CompetitionMetric: Double] = [
            .move: 1.1, .exercise: 0.9, .stand: 0.6, .sleep: 0.8,
        ]

        for mask in 1..<16 {
            let metrics = CompetitionMetrics(rawValue: mask)
            observed.metrics = metrics
            observed.dailyMaximum = metrics.dailyMaximum
            let stacks = competitionDayRings(observed, metrics: metrics)
            let ordered = metrics.orderedMetrics
            XCTAssertEqual(stacks.owner.count, ordered.count)
            XCTAssertEqual(stacks.opponent.count, ordered.count)
            for (index, metric) in ordered.enumerated() {
                XCTAssertEqual(stacks.owner[index].color, metric.color)
                XCTAssertEqual(stacks.opponent[index].color, metric.color)
                XCTAssertEqual(stacks.owner[index].progress, expectedOwnerProgress[metric]!, accuracy: 0.001)
                XCTAssertEqual(stacks.opponent[index].progress, expectedOpponentProgress[metric]!, accuracy: 0.001)
            }
        }

        var future = LocalCompetitionDayPresentation(
            day: day,
            ordinal: 6,
            ownerAcceptedPoints: nil,
            ownerLatestAvailability: .notYetOccurred,
            opponentRevealedPoints: nil,
            scoringPolicy: .remoteWireV1
        )
        future.metrics = .all
        let futureStacks = competitionDayRings(future, metrics: .all)
        XCTAssertEqual(futureStacks.owner.count, 4)
        XCTAssertTrue(futureStacks.owner.allSatisfy { $0.progress == 0 })
        XCTAssertTrue(futureStacks.opponent.allSatisfy { $0.progress == 0 })
    }

    func testCompetitionDayRingsFallbackAndWinnerDotsAndHeadlines() throws {
        let day = try CompetitionDay(era: 1, year: 2026, month: 8, day: 8, timeZoneIdentifier: zone)
        let now = Date(timeIntervalSince1970: 1_786_500_000)
        var fallback = LocalCompetitionDayPresentation(
            day: day,
            ordinal: 1,
            ownerAcceptedPoints: 300,
            ownerLatestAvailability: .observed,
            opponentRevealedPoints: 240,
            scoringPolicy: .remoteWireV1
        )
        fallback.metrics = [.move, .exercise]
        let stacks = competitionDayRings(fallback, metrics: [.move, .exercise])
        XCTAssertEqual(stacks.owner.map(\.progress), [1.5, 1.5])
        XCTAssertEqual(stacks.opponent.map(\.progress), [1.2, 1.2])

        XCTAssertEqual(competitionDayWinnerDotColor(.won), Theme.youFill)
        XCTAssertEqual(competitionDayWinnerDotColor(.lost), Theme.ink)
        XCTAssertEqual(competitionDayWinnerDotColor(.tied), Theme.tertiary)
        XCTAssertNil(competitionDayWinnerDotColor(.today))
        XCTAssertNil(competitionDayWinnerDotColor(.upcoming))
        XCTAssertNil(competitionDayWinnerDotColor(.noData))

        XCTAssertEqual(weekdayInitial(day, locale: locale), "S")

        let todayHead = competitionDayHeadline(
            fallback, currentDayOrdinal: 1, now: now, opponentName: "Sam",
            locale: locale, timeZone: TimeZone(identifier: zone)!
        )
        XCTAssertEqual(todayHead.title, "Today")
        XCTAssertEqual(todayHead.subtitle, "In progress")

        let wonHead = competitionDayHeadline(
            fallback, currentDayOrdinal: 5, now: now, opponentName: "Sam",
            locale: locale, timeZone: TimeZone(identifier: zone)!
        )
        XCTAssertEqual(wonHead.subtitle, "You won the day")

        fallback.opponentRevealedPoints = 350
        let lostHead = competitionDayHeadline(
            fallback, currentDayOrdinal: 5, now: now, opponentName: "Sam",
            locale: locale, timeZone: TimeZone(identifier: zone)!
        )
        XCTAssertEqual(lostHead.subtitle, "Sam won the day")

        fallback.opponentRevealedPoints = 300
        let tiedHead = competitionDayHeadline(
            fallback, currentDayOrdinal: 5, now: now, opponentName: "Sam",
            locale: locale, timeZone: TimeZone(identifier: zone)!
        )
        XCTAssertEqual(tiedHead.subtitle, "Tied")
    }

    func testSleepRowMetadataAndActivityRowValueUnitSplit() throws {
        let tz = TimeZone(identifier: zone)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let windowStart = calendar.date(from: DateComponents(year: 2026, month: 8, day: 11, hour: 18))!
        let reading = CompetitionSleepReading(
            night: SleepNight(
                minutesAsleep: 478,
                awakeMinutes: 12,
                onsetMinutes: 305,
                source: .watch,
                durationPoints: 49.8,
                bedtimePoints: 30,
                interruptionPoints: 16.2,
                basisPoints: 9_600
            ),
            windowStart: windowStart,
            usualOnsetMinutes: 300,
            readAt: windowStart
        )
        let metadata = try XCTUnwrap(
            competitionSleepMetadataText(reading, points: 96, locale: locale, timeZone: tz)
        )
        XCTAssertTrue(metadata.contains("Bed 11:05"), metadata)
        XCTAssertTrue(metadata.contains("up 7:15"), metadata)
        XCTAssertTrue(metadata.contains("score 96"), metadata)

        let snapshot = try ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: ActivityRingReading(value: 1000, goal: 500),
            exercise: ActivityRingReading(value: 60, goal: 30),
            standOrRoll: ActivityRingReading(value: 12, goal: 10),
            pauseState: .running
        )
        var day = LocalCompetitionDayPresentation(
            day: try CompetitionDay(era: 1, year: 2026, month: 8, day: 12, timeZoneIdentifier: zone),
            ordinal: 5,
            ownerAcceptedPoints: 520,
            ownerLatestAvailability: .observed,
            opponentRevealedPoints: 510,
            ownerAcceptedSnapshot: snapshot,
            ownerLatestSnapshot: snapshot,
            scoringPolicy: .remoteWireV1
        )
        day.metrics = .all
        day.ownerSleepReading = reading
        day.ownerSleepPoints = 96
        let panel = try XCTUnwrap(competitionRingPanel(day, locale: locale))
        XCTAssertEqual(panel.rows.map(\.metric), [.move, .exercise, .stand, .sleep])
        XCTAssertEqual(panel.rows[0].valueText, "1,000/500")
        XCTAssertEqual(panel.rows[0].unitText, "KCAL")
        XCTAssertEqual(panel.rows[1].valueText, "60/30")
        XCTAssertEqual(panel.rows[1].unitText, "MIN")
        XCTAssertEqual(panel.rows[2].valueText, "12/10")
        XCTAssertEqual(panel.rows[2].unitText, "HR")
        XCTAssertEqual(panel.rows[3].sleepReading, reading)
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
