#if DEBUG

import CompetitionCore
import SwiftUI
import XCTest
@testable import HealthComp

/// Badges, your records, each ring between two people and History's filter:
/// all worked out from finished weeks. Ring points split each day 38/28/34,
/// as the Test Lab's October does.
final class CompetitionBadgesTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let zone = "America/Los_Angeles"

    func testAWeeksFeatsEarnTheirBadges() {
        let weeks = [
            // Every day yours.
            week(0, you: Array(repeating: 300, count: 7), them: Array(repeating: 290, count: 7)),
            // 300 behind going into the last day.
            week(1, you: [100, 100, 100, 100, 100, 100, 400], them: [150, 150, 150, 150, 150, 150, 50]),
            // Six level days, then five points.
            week(2, you: [200, 200, 200, 200, 200, 200, 205], them: Array(repeating: 200, count: 7)),
            week(3, you: Array(repeating: 100, count: 7), them: Array(repeating: 200, count: 7)),
            // Won, but nothing on day 1.
            week(4, you: [0, 300, 300, 300, 300, 300, 300], them: Array(repeating: 250, count: 7)),
        ]
        let book = competitionBadgeBook(weeks.reversed())

        XCTAssertEqual(book.badges.map(\.kind), [
            .sweep, .comeback, .photoFinish, .tripleCrown, .fullWeek,
            .defender, .hotStreak, .collector, .rival,
        ])
        XCTAssertEqual(book.badges.map(\.count), [1, 1, 1, 4, 4, 0, 0, 0, 0])
        XCTAssertEqual(book.badges.map(\.countText), ["×1", "×1", "×1", "×4", "×4", "2 OF 3", "BEST 3", "1 OF 3", "5 OF 10"])
        XCTAssertEqual(book.badges[3].latest, weeks[4].id)
        XCTAssertEqual(book.byWeek[weeks[0].id], [.sweep, .tripleCrown])
        XCTAssertEqual(book.byWeek[weeks[1].id], [.comeback, .tripleCrown])
        XCTAssertEqual(book.byWeek[weeks[2].id], [.photoFinish, .tripleCrown])
        XCTAssertNil(book.byWeek[weeks[3].id], "A loss earns nothing to show")
        XCTAssertEqual(book.byWeek[weeks[4].id], [.tripleCrown])
        XCTAssertEqual(
            book.badges[0].accessibilityText, "Sweep, earned once. Win all seven days of a week."
        )
        XCTAssertEqual(
            book.badges[5].accessibilityText, "Defender, not yet, 2 of 3. Defend one belt three weeks running."
        )
    }

    func testRunsEarnTheBadgesYouBuildToward() {
        let win = (you: Array(repeating: 300.0, count: 7), them: Array(repeating: 290.0, count: 7))
        var weeks = (0..<10).map { week($0, you: win.you, them: win.them) }
        var book = competitionBadgeBook(weeks)
        func badge(_ kind: CompetitionBadgeKind) -> CompetitionBadge {
            book.badges.first { $0.kind == kind } ?? CompetitionBadge(kind: kind)
        }
        // Took it in week 0, so the third defence is week 3.
        XCTAssertEqual(badge(.defender).count, 1)
        XCTAssertEqual(badge(.defender).latest, weeks[3].id)
        XCTAssertEqual(badge(.hotStreak).count, 1)
        XCTAssertEqual(badge(.hotStreak).latest, weeks[4].id)
        XCTAssertEqual(badge(.rival).count, 1)
        XCTAssertEqual(badge(.rival).latest, weeks[9].id)
        XCTAssertEqual(badge(.collector).countText, "1 OF 3")
        XCTAssertEqual(book.byWeek[weeks[9].id], [.sweep, .tripleCrown, .rival])

        // Two more belts, one lost, then won back: three at once, twice.
        weeks += [
            week(10, "Alex", you: win.you, them: win.them),
            week(11, "Riley", you: win.you, them: win.them),
            week(12, "Alex", you: win.them, them: win.you),
            week(13, "Alex", you: win.you, them: win.them),
        ]
        book = competitionBadgeBook(weeks)
        XCTAssertEqual(badge(.collector).count, 2)
        XCTAssertEqual(badge(.collector).latest, weeks[13].id)
        XCTAssertEqual(badge(.hotStreak).count, 1, "One run of twelve is one streak")
    }

    func testDayMarksAndSweepReadDaysAsTheResultDoes() {
        // 300.4 to 300.2 shows as a level day; 0 to 0 is no data.
        let sample = week(0, you: [300.4, 0, 300, 300, 300, 300, 300], them: [300.2, 0, 290, 290, 290, 290, 290])
        XCTAssertEqual(competitionDayOutcomes(sample), [.tie, nil, .win, .win, .win, .win, .win])
        let book = competitionBadgeBook([sample])
        XCTAssertFalse(book.badges.contains { $0.kind == .sweep && $0.isEarned })
    }

    func testTiesAndRetiredBeltsInRuns() {
        let win = (you: Array(repeating: 300.0, count: 7), them: Array(repeating: 290.0, count: 7))
        let tie = Array(repeating: 300.0, count: 7)
        func badge(_ kind: CompetitionBadgeKind, _ book: CompetitionBadgeBook) -> CompetitionBadge {
            book.badges.first { $0.kind == kind } ?? CompetitionBadge(kind: kind)
        }
        // A tie ends a streak.
        let streak = competitionBadgeBook(
            (0..<4).map { week($0, you: win.you, them: win.them) }
                + [week(4, you: tie, them: tie), week(5, you: win.you, them: win.them)]
        )
        XCTAssertEqual(badge(.hotStreak, streak).count, 0)
        XCTAssertEqual(badge(.hotStreak, streak).countText, "BEST 4")

        // A tie keeps the belt without defending it; a deleted account's belt is never held.
        let belts = competitionBadgeBook([
            week(0, you: win.you, them: win.them),
            week(1, you: tie, them: tie),
            week(2, you: win.you, them: win.them),
            week(3, you: win.you, them: win.them),
            week(4, "Alex", you: win.you, them: win.them),
            week(5, competitionFormerCompetitorName, you: win.you, them: win.them),
        ])
        XCTAssertEqual(badge(.defender, belts).countText, "2 OF 3")
        XCTAssertEqual(badge(.collector, belts).countText, "2 OF 3")
    }

    func testOwnStreakFoldsSameDayWeeksInTheServersOrder() {
        let win = (you: Array(repeating: 300.0, count: 7), them: Array(repeating: 290.0, count: 7))
        let weeks = [
            week(0, you: win.you, them: win.them),
            week(1, you: win.you, them: win.them),
            // Same end: the smaller id is the win but finalized later.
            week(2, "Alex", you: win.you, them: win.them, idNumber: 0x20, finishedLater: 3_600),
            week(2, "Riley", you: win.them, them: win.you, idNumber: 0x21),
            week(3, you: win.you, them: win.them),
        ]
        // Server order: W W W L W.
        XCTAssertEqual(competitionOwnCareer(weeks).career.winStreak, 3)
    }

    func testHistoryFiltersByOutcomeAndPerson() {
        let weeks = competitionHistoryWeeks(CompetitionMonthFixture.weeks())
        let alex = CompetitionMonthFixture.alexIdentity
        XCTAssertEqual(competitionFilteredWeeks(weeks, filter: .all, person: nil).count, 5)
        XCTAssertEqual(competitionFilteredWeeks(weeks, filter: .won, person: nil).count, 3)
        XCTAssertEqual(competitionFilteredWeeks(weeks, filter: .lost, person: nil).count, 2)
        XCTAssertEqual(competitionFilteredWeeks(weeks, filter: .all, person: alex).map(\.opponentDisplayName), ["Alex"])
        XCTAssertTrue(competitionFilteredWeeks(weeks, filter: .won, person: alex).isEmpty)
        // Oct 4–10 with Sam, newest first at index 3.
        XCTAssertEqual(competitionDayOutcomes(weeks[3]), [.win, .loss, .win, .loss, .win, .win, .win])
    }

    func testYourRecordsAcrossOctober() throws {
        let weeks = CompetitionMonthFixture.weeks()
        let sections = competitionOwnRecordSections(weeks, now: CompetitionMonthFixture.now, locale: locale)
        XCTAssertEqual(sections.map(\.title), ["SCORING", "STREAKS", "EACH RING · BEST DAY"])

        let scoring = sections[0].rows
        XCTAssertEqual(scoring.map(\.label), ["Best week", "Best day", "Biggest win", "Closest win"])
        XCTAssertEqual(scoring.map(\.value), ["2,612", "434", "+125", "+110"])
        XCTAssertEqual(scoring.map(\.weekID), [weeks[4].id, weeks[4].id, weeks[2].id, weeks[4].id])
        XCTAssertTrue(scoring[0].detail.hasSuffix(" · beat Sam"), scoring[0].detail)
        XCTAssertTrue(scoring[0].detail.hasPrefix("Oct 25"), scoring[0].detail)
        XCTAssertEqual(scoring[1].detail, "Wed, Oct 28")

        let streaks = sections[1].rows
        XCTAssertEqual(streaks.map(\.label), ["Weeks won in a row", "Days won in a row", "Longest belt run"])
        XCTAssertEqual(streaks.map(\.value), ["2", "6", "3"])
        XCTAssertTrue(streaks[0].detail.hasPrefix("Ended Oct 11"), streaks[0].detail)
        XCTAssertEqual(streaks[1].detail, "Ended Sat, Oct 17")
        XCTAssertEqual(streaks[2].detail, "Weeks holding it against Sam")
        XCTAssertNil(streaks[2].weekID)

        let rings = sections[2].rows
        XCTAssertEqual(rings.map(\.label), ["Move", "Exercise", "Stand"])
        XCTAssertEqual(rings.map(\.value), ["165", "122", "147"])
        XCTAssertEqual(rings.map(\.ring), [0, 1, 2])
        XCTAssertEqual(rings.map(\.detail), Array(repeating: "Wed, Oct 28", count: 3))

        // A winning run that reaches the newest week is still going.
        let run = competitionOwnRecordSections(Array(weeks[..<3]), now: CompetitionMonthFixture.now, locale: locale)
        XCTAssertEqual(run[1].rows[0].detail, "Still going")
        XCTAssertTrue(competitionOwnRecordSections([], now: CompetitionMonthFixture.now).isEmpty)
    }

    func testEachRingBetweenYouAndSam() throws {
        let weeks = competitionRivalryWeeks(
            CompetitionMonthFixture.weeks(), opponentIdentity: CompetitionMonthFixture.samIdentity
        )
        let rings = try XCTUnwrap(competitionRingRecords(weeks))
        let days = try XCTUnwrap(competitionRingDaysWon(weeks))
        XCTAssertEqual(rings.map(\.weeksYou), [3, 3, 3])
        XCTAssertEqual(rings.map(\.weeksThem), [1, 1, 1])
        XCTAssertEqual(rings.map(\.daysYou), days.map(\.you))
        XCTAssertEqual(rings.map(\.daysThem), days.map(\.them))
        XCTAssertEqual(rings.map(\.bestYou), [165, 122, 147])
        XCTAssertEqual(rings.map(\.bestThem), [152, 112, 136])
        XCTAssertEqual(competitionRingEdgeText(rings, opponentName: "Sam", locale: locale), "Your edge: Move, +4 a day.")

        let split = [
            CompetitionRingRecord(averageYou: 182, averageThem: 176),
            CompetitionRingRecord(averageYou: 104, averageThem: 113),
            CompetitionRingRecord(averageYou: 71, averageThem: 64),
        ]
        XCTAssertEqual(
            competitionRingEdgeText(split, opponentName: "Sam", locale: locale),
            "Your edge: Stand, +7 a day. Sam’s edge: Exercise, +9 a day."
        )
        XCTAssertNil(competitionRingEdgeText(Array(repeating: CompetitionRingRecord(), count: 3), opponentName: "Sam"))
        XCTAssertNil(competitionRingRecords([]))
    }

    func testYourPagesKeepTheirPlaceOnTheStack() {
        let id = CompetitionID(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        var path: [CompetitionID] = []
        var showsHistory = false
        var person: String?
        var place = CompetitionPersonPlace()
        let stack = CompetitionHomeRoute.stack(
            path: Binding(get: { path }, set: { path = $0 }),
            showsHistory: Binding(get: { showsHistory }, set: { showsHistory = $0 }),
            person: Binding(get: { person }, set: { person = $0 }),
            personPlace: Binding(get: { place }, set: { place = $0 })
        )

        stack.wrappedValue = [.ownProfile, .ownBadges]
        XCTAssertEqual(stack.wrappedValue, [.ownProfile, .ownBadges])
        // Your profile › Records › the week a record happened in.
        stack.wrappedValue = [.ownProfile, .ownRecords, .competition(id)]
        XCTAssertEqual(stack.wrappedValue, [.ownProfile, .ownRecords, .competition(id)])
        // "Your record with Sam" from that week: Sam's page, without yours.
        stack.wrappedValue += [.person("sam")]
        XCTAssertEqual(stack.wrappedValue, [.competition(id), .person("sam")])
        stack.wrappedValue = []
        XCTAssertEqual(place, CompetitionPersonPlace())
    }

    // MARK: Weeks

    /// Week `number` starts that many weeks after Sun Jan 4, 2026.
    private func week(
        _ number: Int,
        _ opponent: String = "Sam",
        you: [Double],
        them: [Double],
        idNumber: Int? = nil,
        finishedLater: TimeInterval = 0
    ) -> LocalCompetitionPresentation {
        let calendar = try! CompetitionCalendar(timeZoneIdentifier: zone)
        var start = try! CompetitionDay(era: 1, year: 2026, month: 1, day: 4, timeZoneIdentifier: zone)
        for _ in 0..<(number * 7) { start = try! calendar.day(after: start) }
        let schedule = CompetitionSchedule(calendar: calendar, startDay: start)
        func split(_ points: Double) -> [Double] {
            let move = (points * 0.38).rounded(), exercise = (points * 0.28).rounded()
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
        let completedAt = competitionScheduleBoundaries(schedule)!.end.addingTimeInterval(43_200 + finishedLater)
        return LocalCompetitionPresentation(
            id: CompetitionID(UUID(uuidString: String(format: "B7000000-0000-4000-8000-0000000000%02X", idNumber ?? number))!),
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
}

#endif
