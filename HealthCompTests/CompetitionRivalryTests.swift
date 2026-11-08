import CompetitionCore
import SwiftUI
import XCTest
@testable import HealthComp

/// The person page's numbers, against the rivalry history page's sample:
/// you and Sam, ten finished weeks (the Test Lab's `rivalry` fixture).
final class CompetitionRivalryTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let zone = TimeZone(identifier: "America/Los_Angeles")!
    private lazy var ten = CompetitionRivalryFixture.weeks(10, now: CompetitionRivalryFixture.now(weeks: 10))
    private lazy var five = CompetitionRivalryFixture.weeks(5, now: CompetitionRivalryFixture.now(weeks: 5))

    func testTenWeeksReadAsTheDesignDoes() throws {
        let record = try XCTUnwrap(competitionOpponentRecords(ten).first)
        XCTAssertEqual(record.text, "6–3–1")
        XCTAssertEqual(
            competitionRivalryWeeks(ten.reversed(), opponentIdentity: CompetitionRivalryFixture.samIdentity).map(\.id),
            ten.map(\.id)
        )

        let outcomes = ten.compactMap(\.terminalResult?.outcome)
        XCTAssertEqual(competitionFormLine(outcomes, opponentName: "Sam"), "You won the last 2")
        XCTAssertEqual(
            competitionFormAccessibilityText(outcomes, opponentName: "Sam"),
            "Last 10: 6 wins, 3 losses, 1 tie. You won the last 2."
        )

        let tape = competitionTaleOfTheTape(record.belt)
        XCTAssertEqual(tape.map(\.label), ["Title reigns", "Title defenses", "Longest reign", "Biggest win"])
        XCTAssertEqual(tape.map(\.you), ["2", "4", "4 weeks", "+305"])
        XCTAssertEqual(tape.map(\.them), ["2", "1", "3 weeks", "+204"])

        let rings = try XCTUnwrap(competitionRingDaysWon(ten))
        XCTAssertEqual(rings.map(\.you), [19, 51, 18])
        XCTAssertEqual(rings.map(\.them), [50, 18, 52])
    }

    func testTenWeekRecordsGoToWhoeverHoldsThem() throws {
        let rows = competitionRivalryRecords(
            ten, opponentName: "Sam", now: CompetitionRivalryFixture.now(weeks: 10), locale: locale
        )
        XCTAssertEqual(rows.map(\.label), [
            "Best week", "Best day", "Day record", "Closest finish", "Biggest comeback", "First match",
        ])
        XCTAssertEqual(rows.map(\.value), [
            .sides(you: "2,223", them: "2,190"),
            .sides(you: "395", them: "375"),
            .tally(won: 38, lost: 31, tied: 1),
            .text("You by 12", holder: .you),
            .text("You, from 220 down", holder: .you),
            .text("Sam won", holder: .them),
        ])
        XCTAssertEqual(rows[2].detail, "Days won, all weeks")
        XCTAssertTrue(rows[4].detail.hasPrefix("Behind after day 4, won by 38 · "), rows[4].detail)
        XCTAssertEqual(
            competitionRivalryRecordAccessibilityText(rows[0], opponentName: "Sam"),
            "Best week: You 2,223, Sam 2,190. \(rows[0].detail)"
        )
    }

    func testFiveWeeksHoldFiveRecordsWithWeekFoursComeback() {
        let rows = competitionRivalryRecords(
            five, opponentName: "Sam", now: CompetitionRivalryFixture.now(weeks: 5), locale: locale
        )
        XCTAssertEqual(rows.map(\.label), [
            "Best week", "Best day", "Day record", "Closest finish", "Biggest comeback",
        ])
        XCTAssertEqual(competitionComebacks(five), [
            CompetitionComeback(weekID: five[3].id, holder: .you, deficit: 47, afterDay: 6),
        ])
        XCTAssertEqual(competitionClosestFinish(five)?.id, five[3].id)
        XCTAssertEqual(competitionFormLine(five.compactMap(\.terminalResult?.outcome), opponentName: "Sam"),
                       "You won the last 4")
    }

    func testThisYearsRecordsUseOnlyThisYearsWeeks() throws {
        let now = CompetitionRivalryFixture.now(weeks: 10)
        let weeks = CompetitionRivalryFixture.weeks(10, now: now, lastYear: 5)
        let year = try XCTUnwrap(competitionYearWeeks(weeks, now: now, timeZone: zone))
        XCTAssertEqual(year.year, 2026)
        XCTAssertEqual(year.weeks.map(\.id), weeks.suffix(5).map(\.id))

        let rows = competitionRivalryRecords(year.weeks, opponentName: "Sam", now: now, year: year.year, locale: locale)
        // No first match: that's All time's.
        XCTAssertEqual(rows.map(\.label), [
            "Best week", "Best day", "Day record", "Closest finish", "Biggest comeback",
        ])
        XCTAssertEqual(rows.map(\.value), [
            .sides(you: "2,211", them: "2,190"),
            .sides(you: "395", them: "375"),
            .tally(won: 17, lost: 18, tied: 0),
            .text("You by 38", holder: .you),
            .text("You, from 220 down", holder: .you),
        ])
        XCTAssertEqual(rows[2].detail, "Days won, 2026")
        XCTAssertEqual(
            competitionAllTimeBestWeekNote(all: weeks, year: year.weeks, locale: locale),
            "All time still shows your 2,223 week from September 2025."
        )
        // All time is unchanged by the years.
        XCTAssertEqual(
            competitionRivalryRecords(weeks, opponentName: "Sam", now: now, locale: locale).map(\.value),
            competitionRivalryRecords(ten, opponentName: "Sam", now: now, locale: locale).map(\.value)
        )
        // Your best week this year is your best ever: no note.
        let allThisYear = try XCTUnwrap(competitionYearWeeks(ten, now: now, timeZone: zone))
        XCTAssertEqual(allThisYear.weeks.count, 10)
        XCTAssertNil(competitionAllTimeBestWeekNote(all: ten, year: allThisYear.weeks, locale: locale))
    }

    func testYearTabWaitsForThreeWeeksThisYear() {
        let now = CompetitionRivalryFixture.now(weeks: 10)
        XCTAssertNil(competitionYearWeeks(CompetitionRivalryFixture.weeks(10, now: now, lastYear: 8), now: now, timeZone: zone))
        XCTAssertEqual(
            competitionYearWeeks(CompetitionRivalryFixture.weeks(10, now: now, lastYear: 7), now: now, timeZone: zone)?.weeks.count,
            3
        )
        XCTAssertNil(competitionYearWeeks([], now: now, timeZone: zone))
    }

    func testAWeekCountsInTheYearItEndsAndNowInItsOwnZone() {
        let starts: [(year: Int, month: Int, day: Int)] = [
            (2026, 12, 14), (2026, 12, 21), (2026, 12, 28), (2027, 1, 4), (2027, 1, 11),
        ]
        let finished = LocalCompetitionLifecyclePresentation.archived(
            outcome: .win, basis: .stableAcrossPostBoundaryReads,
            completedAt: .distantPast, archivedAt: .distantPast
        )
        let weeks = starts.indices.map { match(id: UInt8(10 + $0), lifecycle: finished, now: .distantPast, start: starts[$0]) }
        // Wed Jan 20, 2027: Dec 28 – Jan 3 ends in 2027.
        let january = Date(timeIntervalSince1970: 1_800_475_200)
        XCTAssertEqual(competitionYearWeeks(weeks, now: january, timeZone: zone)?.weeks.map(\.id), weeks.suffix(3).map(\.id))
        XCTAssertNil(competitionYearWeeks(Array(weeks.dropLast()), now: january, timeZone: zone))
        // Thu Dec 31, 2026: only two weeks end in 2026.
        XCTAssertNil(competitionYearWeeks(weeks, now: Date(timeIntervalSince1970: 1_798_747_200), timeZone: zone))
        // 10 PM on Dec 31 in Los Angeles is already 2027 in UTC.
        let lateDecember = Date(timeIntervalSince1970: 1_798_783_200)
        let fixture = CompetitionRivalryFixture.weeks(10, now: lateDecember, lastYear: 5)
        XCTAssertEqual(competitionYearWeeks(fixture, now: lateDecember, timeZone: zone)?.year, 2026)
        XCTAssertNil(competitionYearWeeks(fixture, now: lateDecember, timeZone: TimeZone(identifier: "UTC")!))
    }

    func testPiecesWaitForEnoughWeeksAndTheLedgerKeepsOnlyTheRecord() {
        XCTAssertEqual(competitionRivalryPieces(weeks: 2, isLedger: false), CompetitionRivalryPieces())
        XCTAssertEqual(
            competitionRivalryPieces(weeks: 3, isLedger: false),
            CompetitionRivalryPieces(form: true, tape: true, rings: true)
        )
        XCTAssertEqual(
            competitionRivalryPieces(weeks: 5, isLedger: false),
            CompetitionRivalryPieces(form: true, tape: true, rings: true, records: true)
        )
        XCTAssertEqual(competitionRivalryPieces(weeks: 6, isLedger: false).weeksShown, 5)
        XCTAssertEqual(
            competitionRivalryPieces(weeks: 10, isLedger: true),
            CompetitionRivalryPieces(form: true, weeksShown: 5)
        )
    }

    func testFormLineNamesTheRunOrTheTie() {
        XCTAssertNil(competitionFormLine([], opponentName: "Sam"))
        XCTAssertEqual(competitionFormLine([.win, .loss], opponentName: "Sam"), "Sam won the last one")
        XCTAssertEqual(competitionFormLine([.loss, .loss, .tie], opponentName: "Sam"), "The last one was a tie")
        XCTAssertEqual(
            competitionFormAccessibilityText([.loss, .win, .win], opponentName: "Sam"),
            "Last 3: 2 wins, 1 loss. You won the last 2."
        )
        // Capped at the last ten.
        XCTAssertTrue(
            competitionFormAccessibilityText(Array(repeating: .loss, count: 12), opponentName: "Sam")
                .hasPrefix("Last 10: 0 wins, 10 losses.")
        )
    }

    func testBeltHoldsAtTheWeekBeforeAnUnseenVerdict() {
        let full = competitionPersonBelt(ten, holdingBack: nil, isRetired: false)
        XCTAssertEqual(full.current?.holder, .you)
        XCTAssertEqual(full.current?.defenses, 1)

        let held = competitionPersonBelt(ten, holdingBack: ten[9].id, isRetired: false)
        XCTAssertEqual(held.current?.holder, .you)
        XCTAssertEqual(held.current?.weeks, 1)
        XCTAssertEqual(held.current?.defenses, 0)
        XCTAssertNil(held.events[ten[9].id])
    }

    func testNoRingsOrDaysMeansNoSplitAndNoDayRecords() {
        let bare = five.map { week in
            LocalCompetitionPresentation(
                id: week.id,
                ownerDisplayName: week.ownerDisplayName,
                opponentDisplayName: week.opponentDisplayName,
                opponentIdentity: week.opponentIdentity,
                lifecycle: week.lifecycle,
                acceptedConfiguration: week.acceptedConfiguration,
                userPoints: week.userPoints,
                opponentPoints: week.opponentPoints,
                days: [],
                currentDayOrdinal: nil,
                lastRefresh: nil,
                tally: nil,
                terminalResult: week.terminalResult,
                evaluatedAt: week.evaluatedAt,
                timeZoneIdentifier: week.timeZoneIdentifier
            )
        }
        XCTAssertNil(competitionRingDaysWon(bare))
        XCTAssertNil(competitionDayRecord(bare))
        XCTAssertEqual(competitionComebacks(bare), [])
        XCTAssertEqual(
            competitionRivalryRecords(bare, opponentName: "Sam", now: CompetitionRivalryFixture.now(weeks: 5), locale: locale)
                .map(\.label),
            ["Best week", "Closest finish"]
        )
    }

    func testButtonAndTopFollowTheLastWeekOffHome() {
        let seen = CompetitionMotionSeen()
        // Nov 3: the last week (Oct 26 – Nov 1) is still on Home.
        let onHome = Date(timeIntervalSince1970: 1_793_736_000)
        let weeks = CompetitionRivalryFixture.weeks(10, now: onHome)
        let unseen = competitionUnseenResult(weeks, now: onHome, seen: seen)
        XCTAssertEqual(unseen, weeks[9].id)
        XCTAssertNil(competitionPersonButtonTitle(weeks, opponentName: "Sam", now: onHome, unseenResult: unseen))
        XCTAssertEqual(competitionPersonNow(weeks, now: onHome, unseenResult: unseen)?.section, "JUST FINISHED")

        let marked = seen.marking(.verdict, weeks[9].id)
        XCTAssertNil(competitionUnseenResult(weeks, now: onHome, seen: marked))
        XCTAssertNil(competitionPersonNow(weeks, now: onHome, unseenResult: nil))
        XCTAssertEqual(
            competitionPersonButtonTitle(weeks, opponentName: "Sam", now: onHome, unseenResult: nil),
            "Rematch Sam"
        )

        let later = CompetitionRivalryFixture.now(weeks: 10)
        XCTAssertNil(competitionUnseenResult(ten, now: later, seen: seen))
        XCTAssertEqual(
            competitionPersonButtonTitle(ten, opponentName: "Sam", now: later, unseenResult: nil),
            "Challenge Sam"
        )
        XCTAssertNil(competitionLastPlayedText(ten[9], now: later, locale: locale))
        let december = later.addingTimeInterval(30 * 86_400)
        XCTAssertEqual(
            competitionLastPlayedText(ten[9], now: december, locale: locale).map { $0.hasSuffix(" · 5 weeks ago") },
            true
        )
    }

    func testAnythingInFlightTakesTheTopAndHidesTheButton() {
        let now = CompetitionRivalryFixture.now(weeks: 10)
        let live = match(id: 0x21, lifecycle: .active(dayOrdinal: 5), now: now)
        let challenge = match(
            id: 0x22,
            lifecycle: .pending(direction: .incoming, createdAt: now, expiresAt: now.addingTimeInterval(86_400)),
            now: now
        )
        let declined = match(id: 0x23, lifecycle: .declined(at: now, direction: .outgoing), now: now)

        XCTAssertEqual(competitionPersonNow(ten + [live], now: now, unseenResult: nil)?.section, "THIS WEEK")
        XCTAssertEqual(competitionPersonNow(ten + [live, challenge], now: now, unseenResult: nil)?.section, "NEEDS YOU")
        XCTAssertNil(competitionPersonButtonTitle(ten + [live], opponentName: "Sam", now: now, unseenResult: nil))
        XCTAssertNil(competitionPersonButtonTitle(ten + [challenge], opponentName: "Sam", now: now, unseenResult: nil))
        XCTAssertEqual(competitionPersonNow(ten + [declined], now: now, unseenResult: nil)?.section, "UP NEXT")
        XCTAssertEqual(
            competitionPersonButtonTitle(ten + [declined], opponentName: "Sam", now: now, unseenResult: nil),
            "Challenge Sam Again"
        )
    }

    func testRecordLinkNeedsAFinishedWeekAndALiveAccount() {
        let now = CompetitionRivalryFixture.now(weeks: 10)
        let live = match(id: 0x21, lifecycle: .active(dayOrdinal: 5), now: now)
        XCTAssertNil(competitionRecordLinkRecord(for: live, in: [live]))
        XCTAssertEqual(competitionRecordLinkRecord(for: live, in: ten + [live])?.text, "6–3–1")

        let link = CompetitionRecordLink(record: competitionOpponentRecords(ten)[0], open: {})
        XCTAssertEqual(link.title, "Your record with Sam")
        XCTAssertEqual(link.accessibilityLabel, "Your record with Sam, 6 wins, 3 losses, 1 tie")

        let former = match(id: 0x24, lifecycle: .active(dayOrdinal: 5), now: now, name: competitionFormerCompetitorName)
        XCTAssertNil(competitionRecordLinkRecord(for: former, in: ten + [former]))
    }

    func testRecordFromAnyStackPopsBackToAPersonAlreadyOnIt() {
        let verdict = CompetitionID(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        let week = CompetitionID(UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
        var path = [verdict]
        var showsHistory = false
        var person: String?
        var place = CompetitionPersonPlace()
        let stack = CompetitionHomeRoute.stack(
            path: Binding(get: { path }, set: { path = $0 }),
            showsHistory: Binding(get: { showsHistory }, set: { showsHistory = $0 }),
            person: Binding(get: { person }, set: { person = $0 }),
            personPlace: Binding(get: { place }, set: { place = $0 })
        )

        // Verdict › Your record with Sam › a week › its Records.
        stack.wrappedValue += [.person("sam")]
        XCTAssertEqual(place, CompetitionPersonPlace(depth: 1))
        stack.wrappedValue += [.records("sam")]
        XCTAssertEqual(stack.wrappedValue, [.competition(verdict), .person("sam"), .records("sam")])
        stack.wrappedValue = [.competition(verdict), .person("sam"), .competition(week)]
        XCTAssertEqual(stack.wrappedValue, [.competition(verdict), .person("sam"), .competition(week)])
        XCTAssertFalse(place.showsRecords)

        // Your record with Sam again pops back to the page: one level.
        stack.wrappedValue += [.person("sam")]
        XCTAssertEqual(stack.wrappedValue, [.competition(verdict), .person("sam")])
        XCTAssertEqual(path, [verdict])

        stack.wrappedValue = [.competition(verdict)]
        XCTAssertNil(person)
        XCTAssertEqual(place, CompetitionPersonPlace())
        XCTAssertFalse(showsHistory)
    }

    func testRowsJournaledBeforeRingsTakeThemFromTheBackfill() throws {
        let digest = String(repeating: "a", count: 64)
        let old = try RemoteAcceptedScoreRow(
            ordinal: 1, acceptedCentiPoints: 17_500, availabilityReason: nil,
            wireContentSHA256: digest, clientRevision: 1, serverSequence: 7
        )
        XCTAssertNil(competitionRingPoints(nil, backfill: [7: [10_000, 5_000, 2_500]]))
        XCTAssertNil(competitionRingPoints(old, backfill: [:]))
        XCTAssertEqual(competitionRingPoints(old, backfill: [7: [10_000, 5_000, 2_500]]), [100, 50, 25])
        let kept = try RemoteAcceptedScoreRow(
            ordinal: 1, acceptedCentiPoints: 17_500, availabilityReason: nil,
            wireContentSHA256: digest, clientRevision: 1, serverSequence: 7,
            ringBasisPoints: [10_000, 5_000, 2_500]
        )
        XCTAssertEqual(competitionRingPoints(kept, backfill: [7: [0, 0, 17_500]]), [100, 50, 25])
    }

    private func match(
        id: UInt8,
        lifecycle: LocalCompetitionLifecyclePresentation,
        now: Date,
        name: String = "Sam",
        start: (year: Int, month: Int, day: Int) = (2026, 11, 3)
    ) -> LocalCompetitionPresentation {
        let zone = "America/Los_Angeles"
        return LocalCompetitionPresentation(
            id: CompetitionID(UUID(uuidString: String(format: "A6000000-0000-4000-8000-0000000000%02X", id))!),
            ownerDisplayName: "Beta Alice",
            opponentDisplayName: name,
            opponentIdentity: CompetitionRivalryFixture.samIdentity,
            lifecycle: lifecycle,
            acceptedConfiguration: LocalCompetitionAcceptedPresentation(
                schedule: CompetitionSchedule(
                    calendar: try! CompetitionCalendar(timeZoneIdentifier: zone),
                    startDay: try! CompetitionDay(
                        era: 1, year: start.year, month: start.month, day: start.day, timeZoneIdentifier: zone
                    )
                ),
                difficulty: .balanced
            ),
            userPoints: 0,
            opponentPoints: 0,
            days: [],
            currentDayOrdinal: nil,
            lastRefresh: nil,
            tally: nil,
            terminalResult: nil,
            evaluatedAt: now,
            timeZoneIdentifier: zone
        )
    }
}
