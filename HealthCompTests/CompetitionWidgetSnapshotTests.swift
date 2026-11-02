import CompetitionCore
import ComposableArchitecture
import Foundation
import XCTest
@testable import HealthComp

final class CompetitionWidgetSnapshotTests: XCTestCase {
    typealias Snapshot = CompetitionWidgetSnapshot
    typealias Match = CompetitionWidgetSnapshot.Match

    private let la = TimeZone(identifier: "America/Los_Angeles")!
    private let en = Locale(identifier: "en_US")

    private func at(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    /// Folds U+202F and other spaces, as in the formatting checks.
    private func normalized(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// A week of Los Angeles midnights starting on `start` (October or
    /// November 2026).
    private func match(
        _ id: Int,
        name: String = "Sam",
        person: String? = nil,
        start: (month: Int, day: Int) = (10, 28),
        user: Double = 1_204,
        opponent: Double = 1_150,
        updatedAt: Date? = nil,
        final: Snapshot.Final? = nil
    ) -> Match {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = la
        let first = calendar.date(from: DateComponents(year: 2026, month: start.month, day: start.day))!
        let starts = (0...7).map { calendar.date(byAdding: .day, value: $0, to: first)! }
        let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", id))!
        return Match(
            id: uuid,
            personID: person ?? "remote-profile:v1:\(name.lowercased())",
            name: name,
            url: CompetitionRoute.competition(CompetitionID(uuid)).url!,
            timeZoneIdentifier: la.identifier,
            dayStarts: Array(starts.prefix(7)),
            endsAt: starts[7],
            userPoints: user,
            opponentPoints: opponent,
            userDayPoints: [250, 230, 262, 250, 212, nil, nil],
            opponentDayPoints: [230, 260, 280, 192, 188, nil, nil],
            updatedAt: updatedAt,
            final: final
        )
    }

    private func final(
        _ outcome: Snapshot.Final.Outcome,
        completedAt: Date? = nil,
        leavesAt: Date? = nil
    ) -> Snapshot.Final {
        Snapshot.Final(
            outcome: outcome,
            completedAt: completedAt ?? at("2026-11-04T09:00:00Z"),
            leavesAt: leavesAt ?? at("2026-11-08T08:00:00Z")
        )
    }

    // Nov 1, 2026 is the US DST change; noon PST.
    private var nov1Noon: Date { at("2026-11-01T20:00:00Z") }

    func testStateAdvancesAtMatchCalendarMidnightsWithoutTheApp() {
        let week = match(1)
        XCTAssertEqual(week.state(at: at("2026-10-28T06:59:00Z")), .scheduled)
        XCTAssertEqual(week.state(at: at("2026-10-28T07:00:00Z")), .live(day: 1))
        XCTAssertEqual(week.state(at: nov1Noon), .live(day: 5))
        XCTAssertEqual(week.state(at: at("2026-11-03T20:00:00Z")), .live(day: 7))
        XCTAssertEqual(week.state(at: at("2026-11-04T07:59:00Z")), .live(day: 7))
        XCTAssertEqual(week.state(at: at("2026-11-04T08:00:00Z")), .finalPending)
    }

    func testFinalShowsUntilItLeavesHome() {
        let result = match(1, final: final(.win, leavesAt: at("2026-11-08T08:00:00Z")))
        XCTAssertEqual(result.state(at: at("2026-11-08T07:59:59Z")), .final(.win))
        XCTAssertEqual(result.state(at: at("2026-11-08T08:00:00Z")), .gone)
    }

    func testFeaturedPrefersLiveEndingSoonestThenPendingThenScheduledThenLatestFinal() {
        func featured(_ matches: [Match], at date: Date? = nil) -> UUID? {
            Snapshot(matches: matches, hasIncomingChallenge: false)
                .featured(personID: nil, at: date ?? nov1Noon)?.id
        }
        let endsNov3 = match(1, start: (10, 28))
        let endsNov2 = match(2, start: (10, 27))
        XCTAssertEqual(featured([endsNov3, endsNov2]), endsNov2.id)

        let day3 = match(3, start: (10, 30))
        let pending = match(4, start: (10, 21))
        XCTAssertEqual(pending.state(at: nov1Noon), .finalPending)
        XCTAssertEqual(featured([pending, day3]), day3.id)
        XCTAssertEqual(featured([pending]), pending.id)

        let nov6 = match(5, start: (11, 6))
        let nov5 = match(6, start: (11, 5))
        XCTAssertEqual(featured([nov6, nov5]), nov5.id)

        let older = match(7, start: (10, 21), final: final(.win, completedAt: at("2026-10-28T09:00:00Z")))
        let newer = match(8, start: (10, 21), final: final(.loss, completedAt: at("2026-10-29T09:00:00Z")))
        let gone = match(9, start: (10, 14), final: final(.win, completedAt: at("2026-10-30T09:00:00Z"), leavesAt: at("2026-10-31T07:00:00Z")))
        XCTAssertEqual(featured([older, newer, gone]), newer.id)
        XCTAssertNil(featured([gone]))
        XCTAssertNil(featured([]))

        let sam = match(10, name: "Sam")
        let alex = match(11, name: "alex")
        XCTAssertEqual(featured([sam, alex]), alex.id)
        let samAgain = match(12, name: "Sam")
        XCTAssertEqual(featured([samAgain, sam]), sam.id)
    }

    func testFeaturedHonorsPickedPersonAndNeverFallsBack() {
        let snapshot = Snapshot(matches: [match(1, person: "A")], hasIncomingChallenge: false)
        XCTAssertNil(snapshot.featured(personID: "B", at: nov1Noon))
        XCTAssertEqual(snapshot.featured(personID: "A", at: nov1Noon)?.personID, "A")
    }

    func testPickedPersonMissingFromSnapshotUsesGenericCopy() {
        let snapshot = Snapshot(matches: [match(1, person: "sam")], hasIncomingChallenge: false)
        XCTAssertEqual(snapshot.pickedPersonEmptyText(personID: "gone"), "No match with this person right now.")
        XCTAssertEqual(snapshot.emptyText(personID: "gone").compact, ["No match right now"])
        XCTAssertFalse(snapshot.emptyText(personID: "gone").namesSomeone)
        XCTAssertEqual(snapshot.pickedPersonEmptyText(personID: "sam"), "No match with Sam right now.")
        XCTAssertEqual(snapshot.emptyText(personID: "sam").compact, ["Sam", "No match right now"])
        XCTAssertEqual(
            Snapshot.content(nil, personID: "sam", at: nov1Noon),
            .empty(.noSnapshot)
        )
    }

    func testSuggestedPeopleExcludeFormerCompetitorAndSortByName() {
        let snapshot = Snapshot(
            matches: [
                match(1, name: "Sam"),
                match(2, name: "Former competitor", person: "x"),
                match(3, name: "alex"),
                match(4, name: "Sam"),
                match(5, name: "Former competitor", person: "y"),
            ],
            hasIncomingChallenge: false
        )
        XCTAssertEqual(snapshot.suggestedPeople().map(\.name), ["alex", "Sam"])
        XCTAssertEqual(snapshot.suggestedPeople().map(\.id), ["remote-profile:v1:alex", "remote-profile:v1:sam"])
    }

    func testMergingCarriesForwardOnlyRequestedMissingIDs() {
        let a = match(1, user: 10)
        let aNew = match(1, user: 20)
        let b = match(2)
        let c = match(3)
        let previous = Snapshot(matches: [a, b, c], hasIncomingChallenge: false)
        let merged = Snapshot(matches: [aNew], hasIncomingChallenge: true)
            .merging(carriedForward: [a.id, b.id], from: previous)
        XCTAssertEqual(merged.matches, [aNew, b])
        XCTAssertTrue(merged.hasIncomingChallenge)
        XCTAssertEqual(
            Snapshot(matches: [aNew], hasIncomingChallenge: false).merging(carriedForward: [b.id], from: nil).matches,
            [aNew]
        )
    }

    func testTimelineDatesAreFutureBoundariesSortedAndCapped() {
        let week = match(1)
        let result = match(2, start: (10, 21), final: final(.win, leavesAt: at("2026-11-02T08:00:00Z")))
        let snapshot = Snapshot(matches: [week, result], hasIncomingChallenge: false)
        XCTAssertEqual(
            snapshot.timelineDates(after: nov1Noon),
            [at("2026-11-02T08:00:00Z"), at("2026-11-03T08:00:00Z"), at("2026-11-04T08:00:00Z")]
        )
        let many = Snapshot(
            matches: (0..<5).map { match($0, start: (11, 2 + $0)) },
            hasIncomingChallenge: false
        )
        let dates = many.timelineDates(after: nov1Noon)
        XCTAssertEqual(dates.count, 12)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(dates.first, at("2026-11-02T08:00:00Z"))
    }

    func testCopyPerState() {
        let week = match(1, updatedAt: at("2026-11-01T17:30:00Z"))
        func status(_ date: Date, compact: Bool = false, _ m: Match? = nil) -> String {
            (m ?? week).status(at: date, compact: compact, locale: en)
        }
        let beforeDay1 = at("2026-10-27T19:00:00Z")
        XCTAssertEqual(status(beforeDay1), "Day 1 is Wednesday")
        XCTAssertEqual(status(nov1Noon), "Day 5 of 7")
        XCTAssertEqual(status(nov1Noon, compact: true), "Day 5")
        XCTAssertEqual(status(at("2026-11-03T20:00:00Z")), "Last day")
        XCTAssertEqual(status(at("2026-11-03T20:00:00Z"), compact: true), "Last day")
        XCTAssertEqual(status(at("2026-11-04T20:00:00Z")), "Final score pending")
        let resultDate = at("2026-11-05T20:00:00Z")
        let win = match(2, user: 1_318, opponent: 1_204, final: final(.win))
        XCTAssertEqual(status(resultDate, win), "You won")
        XCTAssertEqual(status(resultDate, match(3, final: final(.loss))), "Sam won")
        XCTAssertEqual(status(resultDate, match(4, final: final(.tie))), "Tied")
        XCTAssertEqual(status(resultDate, compact: true, win), "Final")

        XCTAssertEqual(week.mediumHeader(at: nov1Noon, locale: en), "Sam · Day 5 of 7")
        XCTAssertEqual(win.mediumHeader(at: resultDate, locale: en), "Sam · Final")
        XCTAssertEqual(week.mediumHeader(at: beforeDay1, locale: en), "Sam · Day 1 is Wednesday")

        XCTAssertEqual(week.rectangularLines(at: beforeDay1, locale: en, timeZone: la), [["Sam"], ["Day 1 is Wednesday"]])
        XCTAssertEqual(
            week.rectangularLines(at: nov1Noon, locale: en, timeZone: la).map { $0.map { normalized($0)! } },
            [["Sam · Day 5", "Sam"], ["You 1,204 · Sam 1,150", "You 1,204 · 1,150"], ["Updated 9:30 AM"]]
        )
        XCTAssertEqual(win.rectangularLines(at: resultDate, locale: en, timeZone: la).first, ["Sam · Final", "Sam"])

        XCTAssertEqual(normalized(week.updatedLine(at: nov1Noon, locale: en, timeZone: la)), "Updated 9:30 AM")
        let earlier = match(5, updatedAt: at("2026-10-28T04:30:00Z"))
        XCTAssertEqual(normalized(earlier.updatedLine(at: nov1Noon, locale: en, timeZone: la)), "Updated Tue 9:30 PM")
        XCTAssertNil(week.updatedLine(at: beforeDay1, locale: en, timeZone: la))
        XCTAssertNil(match(6).updatedLine(at: nov1Noon, locale: en, timeZone: la))

        XCTAssertEqual(week.leadLine(at: nov1Noon, locale: en), "You lead by 54.")
        XCTAssertNil(week.leadLine(at: beforeDay1, locale: en))
        XCTAssertEqual(win.leadLine(at: resultDate, locale: en), "Won by 114 points")
        XCTAssertNil(match(7, user: 10, opponent: 10, final: final(.tie)).leadLine(at: resultDate, locale: en))

        XCTAssertEqual(week.todayLines(at: nov1Noon, locale: en).user, "Today 212")
        XCTAssertEqual(week.todayLines(at: nov1Noon, locale: en).opponent, "Today 188")
        XCTAssertNil(week.todayLines(at: at("2026-11-02T20:00:00Z"), locale: en).user)
        XCTAssertNil(week.todayLines(at: resultDate, locale: en).user)

        XCTAssertEqual(week.circular(at: nov1Noon, locale: en).caption, "LEAD")
        XCTAssertEqual(week.circular(at: nov1Noon, locale: en).value, "+54")
        XCTAssertEqual(week.circular(at: beforeDay1, locale: en).caption, "DAY 1")
        XCTAssertEqual(week.circular(at: beforeDay1, locale: en).value, "Wed")
        XCTAssertEqual(win.circular(at: resultDate, locale: en).caption, "WON")
        XCTAssertEqual(match(8, user: 1_000, opponent: 1_020, final: final(.loss)).circular(at: resultDate, locale: en).value, "\u{2212}20")

        XCTAssertEqual(
            week.dayOutcomes(at: nov1Noon),
            [.won, .lost, .lost, .won, .today, .upcoming, .upcoming]
        )
    }

    func testEmptyStateSaysAChallengeIsWaiting() {
        let waiting = Snapshot(matches: [], hasIncomingChallenge: true).emptyText(personID: nil)
        XCTAssertEqual(waiting.title, "Nothing live right now")
        XCTAssertEqual(waiting.line, "A challenge is waiting.")
        XCTAssertEqual(Snapshot(matches: [], hasIncomingChallenge: false).emptyLine, "Challenge someone")
        XCTAssertEqual(Snapshot.content(nil, personID: nil, at: nov1Noon), .empty(.noSnapshot))
        XCTAssertEqual(CompetitionWidgetEmptyText.noSnapshot.line, "Open the app to see your matches.")
    }

    func testFinalUsesTwoDecimalsOnlyWhenWholePointsTie() {
        let resultDate = at("2026-11-05T20:00:00Z")
        let close = match(1, user: 412.30, opponent: 412.10, final: final(.win))
        XCTAssertEqual(close.userPointsText(locale: en), "412.30")
        XCTAssertEqual(close.opponentPointsText(locale: en), "412.10")
        XCTAssertEqual(close.leadLine(at: resultDate, locale: en), "Won by 0.20 points")
        XCTAssertEqual(close.circular(at: resultDate, locale: en).value, "+0.20")
        let live = match(2, user: 412.30, opponent: 412.10)
        XCTAssertEqual(live.userPointsText(locale: en), "412")
        XCTAssertEqual(live.leadLine(at: nov1Noon, locale: en), "All square.")
        let clear = match(3, user: 1_318, opponent: 1_204, final: final(.win))
        XCTAssertEqual(clear.userPointsText(locale: en), "1,318")
    }

    func testAccessibilityLabelNeverReadsDashes() {
        let week = match(1, updatedAt: at("2026-11-01T17:30:00Z"))
        XCTAssertEqual(
            normalized(week.accessibilityLabel(at: nov1Noon, redacted: false, locale: en, timeZone: la)),
            "Sam, Day 5 of 7. You 1,204 points. Sam 1,150 points. You lead by 54. Updated 9:30 AM."
        )
        XCTAssertEqual(week.accessibilityLabel(at: nov1Noon, redacted: false, circular: true, locale: en), "You lead Sam by 54 points")
        XCTAssertEqual(match(2, user: 1_150, opponent: 1_204).accessibilityLabel(at: nov1Noon, redacted: false, circular: true, locale: en), "Sam leads by 54 points")
        XCTAssertEqual(match(3, user: 5, opponent: 5).accessibilityLabel(at: nov1Noon, redacted: false, circular: true, locale: en), "All square with Sam")
        let resultDate = at("2026-11-05T20:00:00Z")
        XCTAssertEqual(
            match(4, user: 10, opponent: 10, final: final(.tie)).accessibilityLabel(at: resultDate, redacted: false, locale: en),
            "Sam, Final. You 10 points. Sam 10 points. Tied."
        )
        XCTAssertEqual(week.accessibilityLabel(at: at("2026-10-27T19:00:00Z"), redacted: false, locale: en), "Sam, Day 1 is Wednesday.")
        for date in [at("2026-10-27T19:00:00Z"), nov1Noon, at("2026-11-04T20:00:00Z"), resultDate] {
            for item in [week, match(5, final: final(.loss))] {
                XCTAssertFalse(item.accessibilityLabel(at: date, redacted: false, locale: en).contains("--"))
            }
        }
    }

    func testRedactedAccessibilityLabelHasNoNamesOrPoints() {
        let week = match(1, updatedAt: at("2026-11-01T17:30:00Z"))
        let live = week.accessibilityLabel(at: nov1Noon, redacted: true, circular: true, locale: en)
        XCTAssertEqual(live, "HealthComp, Day 5.")
        let result = match(2, final: final(.loss)).accessibilityLabel(at: at("2026-11-05T20:00:00Z"), redacted: true, locale: en)
        XCTAssertEqual(result, "HealthComp, Final.")
        for label in [live, result] {
            XCTAssertFalse(label.contains("Sam"))
            XCTAssertNil(label.replacingOccurrences(of: "Day 5", with: "").rangeOfCharacter(from: .decimalDigits))
        }
        let picked = Snapshot(matches: [week], hasIncomingChallenge: false)
            .emptyText(personID: week.personID)
        XCTAssertEqual(picked.redactedAccessibilityLabel, "HealthComp, No match right now.")
    }

    func testLoadRejectsOtherVersionsAndBadJSON() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent(Snapshot.fileName)
        XCTAssertNil(Snapshot.load(from: url))
        XCTAssertNil(Snapshot.load(from: nil))
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(Snapshot.load(from: url))
        var future = Snapshot(matches: [match(1)], hasIncomingChallenge: false)
        future.version = 2
        try JSONEncoder().encode(future).write(to: url)
        XCTAssertNil(Snapshot.load(from: url))
        let current = Snapshot(matches: [match(1)], hasIncomingChallenge: true)
        try JSONEncoder().encode(current).write(to: url)
        XCTAssertEqual(Snapshot.load(from: url), current)
    }

    // MARK: Writer

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writer(_ url: URL, reloads: LockIsolated<Int>) -> CompetitionWidgetSnapshotClient {
        .live(fileURL: url, reload: { reloads.withValue { $0 += 1 } })
    }

    func testWriterSkipsIdenticalSnapshotsAndReloadsOnChange() async throws {
        let url = try temporaryDirectory().appendingPathComponent(Snapshot.fileName)
        let reloads = LockIsolated(0)
        let client = writer(url, reloads: reloads)
        let a = Snapshot(matches: [match(1)], hasIncomingChallenge: false)
        let b = Snapshot(matches: [match(1, user: 1_300)], hasIncomingChallenge: false)
        await client.write(a, [])
        await client.write(a, [])
        await client.write(b, [])
        XCTAssertEqual(reloads.value, 2)
        XCTAssertEqual(Snapshot.load(from: url), b)
    }

    func testWriterRewritesWithoutReloadWhenOnlyUpdatedAtChanges() async throws {
        let url = try temporaryDirectory().appendingPathComponent(Snapshot.fileName)
        let reloads = LockIsolated(0)
        let client = writer(url, reloads: reloads)
        await client.write(Snapshot(matches: [match(1, updatedAt: at("2026-11-01T17:00:00Z"))], hasIncomingChallenge: false), [])
        let newer = Snapshot(matches: [match(1, updatedAt: at("2026-11-01T17:30:00Z"))], hasIncomingChallenge: false)
        await client.write(newer, [])
        XCTAssertEqual(reloads.value, 1)
        XCTAssertEqual(Snapshot.load(from: url), newer)
    }

    func testWriterCarriesForwardUnsyncedMatchesFromDisk() async throws {
        let url = try temporaryDirectory().appendingPathComponent(Snapshot.fileName)
        let a = match(1)
        let b = match(2)
        try JSONEncoder().encode(Snapshot(matches: [a, b], hasIncomingChallenge: false)).write(to: url)
        let aNew = match(1, user: 1_300)
        await writer(url, reloads: LockIsolated(0)).write(
            Snapshot(matches: [aNew], hasIncomingChallenge: false), [b.id]
        )
        XCTAssertEqual(Snapshot.load(from: url)?.matches, [aNew, b])
    }

    func testWriterSeedsFromDiskSoARelaunchDoesNotReload() async throws {
        let url = try temporaryDirectory().appendingPathComponent(Snapshot.fileName)
        let snapshot = Snapshot(matches: [match(1)], hasIncomingChallenge: false)
        await writer(url, reloads: LockIsolated(0)).write(snapshot, [])
        let reloads = LockIsolated(0)
        await writer(url, reloads: reloads).write(snapshot, [])
        XCTAssertEqual(reloads.value, 0)
    }

    func testWrittenFileIsExcludedFromBackup() async throws {
        let url = try temporaryDirectory().appendingPathComponent(Snapshot.fileName)
        await writer(url, reloads: LockIsolated(0)).write(
            Snapshot(matches: [match(1)], hasIncomingChallenge: false), []
        )
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testClearRemovesTheFileAndToleratesMissing() async throws {
        let url = try temporaryDirectory().appendingPathComponent(Snapshot.fileName)
        let reloads = LockIsolated(0)
        let client = writer(url, reloads: reloads)
        let snapshot = Snapshot(matches: [match(1)], hasIncomingChallenge: false)
        await client.write(snapshot, [])
        try await client.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try await client.clear()
        XCTAssertEqual(reloads.value, 3)
        // After a clear the same snapshot is new again.
        await client.write(snapshot, [])
        XCTAssertEqual(Snapshot.load(from: url), snapshot)
        XCTAssertEqual(reloads.value, 4)
    }
}
