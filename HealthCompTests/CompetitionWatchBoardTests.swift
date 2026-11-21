import CompetitionCore
import ComposableArchitecture
import Foundation
import XCTest
@testable import HealthComp

final class CompetitionWatchBoardTests: XCTestCase {
    typealias Snapshot = CompetitionWidgetSnapshot
    typealias Match = CompetitionWidgetSnapshot.Match

    private let en = Locale(identifier: "en_US")
    private let now = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!

    private func fixture(_ scenario: String) -> Snapshot {
        Snapshot.testLab(scenario, now: now, scheme: "healthcomp")!
    }

    private func match(_ scenario: String) -> Match {
        fixture(scenario).matches[0]
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func mirroring(
        _ url: URL,
        into calls: LockIsolated<[(snapshot: Snapshot?, material: Bool)]>
    ) -> CompetitionWidgetSnapshotClient {
        .live(fileURL: url, reload: {}, mirror: { snapshot, material in
            calls.withValue { $0.append((snapshot, material)) }
        })
    }

    func testMirrorFiresOnEveryWriteAndSaysWhetherItWasMaterial() async throws {
        let url = try temporaryDirectory().appendingPathComponent(Snapshot.fileName)
        let calls = LockIsolated<[(snapshot: Snapshot?, material: Bool)]>([])
        let client = mirroring(url, into: calls)
        let first = fixture("live")
        var touched = first
        touched.matches[0].updatedAt = now
        await client.write(first, [])
        await client.write(first, [])
        await client.write(touched, [])
        XCTAssertEqual(calls.value.map { $0.snapshot }, [first, touched])
        XCTAssertEqual(calls.value.map { $0.material }, [true, false])
    }

    func testMirrorClearsOnlyAfterTheFileIsGone() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent(Snapshot.fileName)
        let calls = LockIsolated<[(snapshot: Snapshot?, material: Bool)]>([])
        let client = mirroring(url, into: calls)
        await client.write(fixture("live"), [])

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        do {
            try await client.clear()
            XCTFail("removing from a read-only folder should throw")
        } catch {}
        XCTAssertEqual(calls.value.count, 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try await client.clear()
        XCTAssertEqual(calls.value.count, 2)
        XCTAssertNil(calls.value[1].snapshot)
        XCTAssertTrue(calls.value[1].material)
    }

    func testComplicationTransfersAreSpacedAndClearsAreNot() {
        let spacing = CompetitionWatchSync.complicationTransferSpacing
        let spends = CompetitionWatchSync.spendsComplicationTransfer
        XCTAssertTrue(spends(false, nil, now))
        XCTAssertFalse(spends(false, now.addingTimeInterval(-spacing + 1), now))
        XCTAssertTrue(spends(false, now.addingTimeInterval(-spacing), now))
        XCTAssertTrue(spends(true, now, now))
    }

    func testPayloadRoundTripsWithoutThePersonID() throws {
        let sent = CompetitionWatchPayload(snapshot: fixture("several"), sentAt: 100)
        let received = try XCTUnwrap(CompetitionWatchPayload(sent.dictionary))
        XCTAssertEqual(received, sent)
        guard case let .store(snapshot) = received.action(after: nil) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertEqual(snapshot.matches.map(\.name), fixture("several").matches.map(\.name))
        XCTAssertEqual(Set(snapshot.matches.map(\.personID)), [""])
    }

    func testAnEmptyContextIsIgnored() {
        XCTAssertNil(CompetitionWatchPayload([:]))
    }

    func testOlderOrRepeatedSnapshotsAreIgnored() {
        let payload = CompetitionWatchPayload(snapshot: fixture("live"), sentAt: 100)
        XCTAssertEqual(payload.action(after: 100), .ignore)
        XCTAssertEqual(payload.action(after: 101), .ignore)
    }

    func testAClearBypassesAnOlderClockButNotItself() {
        let clear = CompetitionWatchPayload(snapshot: nil, sentAt: 100)
        XCTAssertEqual(clear.action(after: 200), .clear)
        XCTAssertEqual(clear.action(after: nil), .clear)
        XCTAssertEqual(clear.action(after: 100), .ignore)
    }

    func testAnotherVersionOrBadDataClears() throws {
        var future = fixture("live")
        future.version = Snapshot.currentVersion + 1
        XCTAssertEqual(CompetitionWatchPayload(snapshot: future, sentAt: 100).action(after: nil), .clear)
        let bad = CompetitionWatchPayload(["sentAt": 100.0, "snapshot": Data("nope".utf8)])
        XCTAssertEqual(bad?.action(after: nil), .clear)
    }

    func testPagesFollowTheComplicationAndDropWhatHasGone() {
        let several = fixture("several")
        XCTAssertEqual(several.pages(at: now).map(\.name), ["Sam", "Alex", "Riley", "Casey", "Former competitor"])
        XCTAssertEqual(several.pages(at: now).first, several.featured(personID: nil, at: now))
        XCTAssertEqual(fixture("samGone").pages(at: now).map(\.name), ["Alex"])
        XCTAssertEqual(fixture("empty").pages(at: now), [])
        XCTAssertEqual(fixture("card").pages(at: now).map(\.id), fixture("card").matches.map(\.id))
    }

    func testCardRowsFollowThePagesAndNeverSpoilAReveal() {
        let card = fixture("card")
        let rows = card.pages(at: now).map {
            $0.cardRow(at: now, firstSight: CompetitionWatchSeen().isFirstSight(of: $0, at: now), locale: en)
        }
        XCTAssertEqual(rows.map(\.name), ["Sam", "Four-Way", "Robin", "Riley", "Jo"])
        XCTAssertEqual(rows.map(\.line), ["Day 5", "48 behind Sam", "372 to lead", "Pending", "Final"])
        XCTAssertEqual(rows.map(\.value), ["+54", "2nd", "−371", "−19", ""])
        XCTAssertEqual(rows.map(\.isYours), [true, false, false, false, false])
        XCTAssertEqual(rows[0].spoken, "You lead Sam by 54 points. Day 5.")
        XCTAssertEqual(rows[1].spoken, "Four-Way, Day 4 of 7. You're 2nd. 48 behind Sam.")
        XCTAssertEqual(rows[2].spoken, "Robin leads by 371 points. 372 points to take the lead. 31 of 403 today.")
        XCTAssertEqual(rows[4].spoken, "Jo, Final.")

        let seen = card.matches.last!.cardRow(at: now, firstSight: false, locale: en)
        XCTAssertEqual([seen.line, seen.value], ["Final", "Won"])
        XCTAssertTrue(seen.isYours)
        XCTAssertEqual(match("lost").cardRow(at: now, firstSight: false, locale: en).value, "Lost")
        XCTAssertEqual(match("tied").cardRow(at: now, firstSight: false, locale: en).value, "Tied")
        let out = match("outOfReach").cardRow(at: now, firstSight: false, locale: en)
        XCTAssertEqual([out.line, out.value], ["Out of reach today", "−471"])
        let later = match("scheduled").cardRow(at: now, firstSight: false, locale: en)
        XCTAssertEqual([later.line, later.value], ["Day 1 is Sunday", ""])
    }

    func testTheWeekIsForDuelsThatHaveStarted() {
        XCTAssertEqual(
            ["live", "pending", "won", "scheduled", "groupFFA", "groupDoubles"].map { match($0).hasWeek(at: now) },
            [true, true, true, false, false, false]
        )
        let robin = fixture("card").matches[2]
        let rows = robin.weekRows(locale: en)
        XCTAssertEqual(rows.map(\.day), ["W", "T", "F", "S", "S", "M", "T"])
        XCTAssertEqual(rows[0].spoken, "Wednesday")
        XCTAssertEqual(rows.map(\.you), ["142", "152", "31", nil, nil, nil, nil])
        XCTAssertEqual(rows.map(\.them), ["388", "121", "187", nil, nil, nil, nil])
    }

    func testAnAlertNamesItsMatchWithTheRoutesOwnKeys() {
        let id = UUID()
        var userInfo = CompetitionRoute.competition(CompetitionID(id)).userInfo
        XCTAssertEqual(CompetitionWatchAlert.competitionID(userInfo), id)
        userInfo["aps"] = ["alert": "Sam took the lead"]
        userInfo[CompetitionReactionAlert.recipientKey] = UUID().uuidString
        XCTAssertEqual(CompetitionWatchAlert.competitionID(userInfo), id)
        XCTAssertNil(CompetitionWatchAlert.competitionID(CompetitionRoute.friends.userInfo))
        XCTAssertNil(CompetitionWatchAlert.competitionID([:]))
    }

    func testStatusInlineAndCornerForEveryState() {
        let rows: [(scenario: String, status: String, inline: String, corner: String)] = [
            ("live", "Day 5", "+54 · Day 5 · Sam", "DAY 5 · SAM"),
            ("trailing", "Day 3", "−54 · Day 3 · Sam", "DAY 3 · SAM"),
            ("square", "Day 2", "0 · Day 2 · Sam", "DAY 2 · SAM"),
            ("lastDay", "Last day", "+19 · Last day · Sam", "LAST DAY · SAM"),
            ("pending", "Pending", "+19 · Pending · Sam", "PENDING · SAM"),
            ("won", "Final", "+114 · Final · Sam", "FINAL · SAM"),
            ("lost", "Final", "−20 · Final · Sam", "FINAL · SAM"),
            ("tied", "Final", "0 · Final · Sam", "FINAL · SAM"),
            ("closeFinal", "Final", "−0.15 · Final · Sam", "FINAL · SAM"),
            ("scheduled", "Day 1 is Sunday", "Day 1 is Sun · Sam", "DAY 1 · SAM"),
        ]
        for row in rows {
            let shown = match(row.scenario)
            XCTAssertEqual(shown.boardStatus(at: now, locale: en), row.status, row.scenario)
            XCTAssertEqual(shown.inlineText(at: now, locale: en), row.inline, row.scenario)
            XCTAssertEqual(shown.cornerLabel(at: now, locale: en), row.corner, row.scenario)
        }
    }

    func testRedactedCopyNamesNoOneAndShowsNoMargin() {
        let live = match("live")
        XCTAssertEqual(live.inlineText(at: now, redacted: true, locale: en), "Day 5")
        XCTAssertEqual(live.cornerLabel(at: now, redacted: true, locale: en), "DAY 5")
        XCTAssertEqual(match("scheduled").cornerLabel(at: now, redacted: true, locale: en), "DAY 1")
    }

    func testBeltRowAndCardCopy() {
        XCTAssertNil(match("live").beltDefensesText)
        XCTAssertEqual(match("beltLive").beltDefensesText, "2 defenses")
        XCTAssertEqual(match("beltTrailing").beltDefensesText, "1 defense")
        XCTAssertEqual(match("beltLive").beltAccessibilityText, "You hold the belt, 2 defenses.")
        XCTAssertEqual(match("beltTrailing").beltAccessibilityText, "Sam holds the belt, 1 defense.")
        XCTAssertNil(match("beltLive").beltCardText)

        let earned = match("beltEarned").beltCardText
        XCTAssertEqual(earned?.headline, "AND NEW")
        XCTAssertEqual(earned?.line, "You took the belt")
        XCTAssertEqual(earned?.detail, [])

        let taken = match("beltTaken").beltCardText
        XCTAssertEqual(taken?.headline, "AND NEW")
        XCTAssertEqual(taken?.line, "You took the belt from Sam")
        XCTAssertEqual(taken?.detail, ["Sam’s reign: 4 weeks", "2 defenses"])

        let lost = match("beltLost").beltCardText
        XCTAssertEqual(lost?.line, "Sam took the belt")
        XCTAssertEqual(lost?.detail, ["Your reign: 4 weeks", "2 defenses"])

        let defended = match("beltDefended").beltCardText
        XCTAssertEqual(defended?.headline, "AND STILL")
        XCTAssertEqual(defended?.line, "3rd title defense")
    }

    func testChaseFillsTodayTowardTheLead() throws {
        let chase = try XCTUnwrap(match("trailing").chase(at: now, locale: en))
        XCTAssertEqual(chase.fill, 200.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(chase.lead, "55")
        XCTAssertEqual(chase.line, "200 of 255 today")
        XCTAssertEqual(chase.suggestion, "About 165 kcal of Move or 17 min of Exercise.")
        XCTAssertEqual(chase.spoken, "55 points to take the lead. 200 of 255 today.")
    }

    func testChaseOutOfReachIsAnEmptyBar() throws {
        let chase = try XCTUnwrap(match("outOfReach").chase(at: now, locale: en))
        XCTAssertEqual(chase.fill, 0)
        XCTAssertNil(chase.lead)
        XCTAssertEqual(chase.line, "Out of reach today")
        XCTAssertEqual(chase.spoken, "Out of reach today.")
    }

    func testChaseOnlyWhileYouTrailOnItsDay() {
        XCTAssertNil(match("live").chase(at: now))
        XCTAssertNil(match("beltTrailing").chase(at: now))
        var level = match("trailing")
        level.opponentPoints = level.userPoints
        XCTAssertNil(level.chase(at: now))
        var tomorrow = match("trailing")
        XCTAssertNil(tomorrow.chase(at: now.addingTimeInterval(86_400)))
        tomorrow.chase?.day = 2
        XCTAssertNil(tomorrow.chase(at: now))
    }

    func testAnOlderFileWithNoBeltStillDecodes() throws {
        let data = try JSONEncoder().encode(fixture("live"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("belt"))
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: data), fixture("live"))
    }

    func testStaleAtTheHourAndNeverForResultsOrNoTime() {
        var live = match("live")
        live.updatedAt = now.addingTimeInterval(-Match.staleAfter)
        XCTAssertFalse(live.isStale(at: now))
        live.updatedAt = now.addingTimeInterval(-Match.staleAfter - 1)
        XCTAssertTrue(live.isStale(at: now))
        XCTAssertTrue(match("stale").isStale(at: now))
        live.updatedAt = nil
        XCTAssertFalse(live.isStale(at: now))

        var pending = match("pending")
        pending.updatedAt = now.addingTimeInterval(-7_200)
        XCTAssertTrue(pending.isStale(at: now))

        var won = match("won")
        won.updatedAt = now.addingTimeInterval(-7_200)
        XCTAssertFalse(won.isStale(at: now))
    }

    func testSideUsesTheMarginAsShown() {
        XCTAssertEqual(match("live").side, .you)
        XCTAssertEqual(match("trailing").side, .them)
        XCTAssertEqual(match("square").side, .square)
        XCTAssertEqual(match("won").side, .you)
        XCTAssertEqual(match("lost").side, .them)
        XCTAssertEqual(match("tied").side, .square)
        XCTAssertEqual(match("closeFinal").side, .them)
        var win = match("closeFinal")
        (win.userPoints, win.opponentPoints) = (win.opponentPoints, win.userPoints)
        XCTAssertEqual(win.side, .you)
        var live = match("live")
        (live.userPoints, live.opponentPoints) = (412.30, 412.10)
        XCTAssertEqual(live.side, .square)
    }

    func testScoreSizeLadder() {
        let widths: [CGFloat] = [162 - 20, 176 - 20, 205 - 20]
        let rows: [(you: String, them: String, sizes: [CGFloat])] = [
            ("610", "664", [56, 56, 56]),
            ("1,204", "1,150", [39, 43, 52]),
            ("12,045", "11,980", [32, 36, 43]),
            ("1,840.25", "1,840.40", [24, 27, 32]),
        ]
        for row in rows {
            XCTAssertEqual(
                widths.map { competitionWatchScoreSize(you: row.you, them: row.them, width: $0) },
                row.sizes, row.you
            )
        }
    }

    func testAFinalIsFirstSightOnceAndLiveNever() throws {
        var seen = CompetitionWatchSeen()
        let won = match("won")
        XCTAssertTrue(seen.isFirstSight(of: won, at: now))
        seen.finals.insert(won.id)
        XCTAssertFalse(seen.isFirstSight(of: won, at: now))
        XCTAssertFalse(CompetitionWatchSeen().isFirstSight(of: match("live"), at: now))
        XCTAssertFalse(CompetitionWatchSeen().isFirstSight(of: match("pending"), at: now))
    }

    func testSeenPrunesMatchesThatLeftTheSnapshot() {
        let won = match("won")
        let other = UUID()
        var seen = CompetitionWatchSeen(sentAt: 100, finals: [won.id, other])
        seen.prune(keeping: fixture("won"))
        XCTAssertEqual(seen, CompetitionWatchSeen(sentAt: 100, finals: [won.id]))
    }

    func testEnrichedSnapshotRoundTripsAndDecodesLegacyPayloads() throws {
        var legacy = fixture("live")
        legacy.matches[0].todayRings = nil
        legacy.matches[0].rivalry = nil
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyText = String(decoding: legacyData, as: UTF8.self)
        XCTAssertFalse(legacyText.contains("todayRings"))
        XCTAssertFalse(legacyText.contains("rivalry"))
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: legacyData), legacy)

        let rich = fixture("trailing")
        let payload = CompetitionWatchPayload(snapshot: rich, sentAt: 200)
        guard case let .store(decoded) = payload.action(after: 100) else {
            return XCTFail("expected enriched snapshot")
        }
        XCTAssertEqual(decoded.matches[0].todayRings, rich.matches[0].todayRings)
        XCTAssertEqual(decoded.matches[0].rivalry, rich.matches[0].rivalry)
        XCTAssertEqual(decoded.matches[0].chase?.suggestion, "About 165 kcal of Move or 17 min of Exercise.")
    }

    func testActiveTodayRingsOnlyMatchesItsLiveDay() {
        let live = match("live")
        XCTAssertEqual(live.activeTodayRings(at: now)?.rows.count, 3)
        XCTAssertNil(live.activeTodayRings(at: now.addingTimeInterval(86_400)))
        var wrongDay = live
        wrongDay.todayRings?.dayOrdinal = 4
        XCTAssertNil(wrongDay.activeTodayRings(at: now))
    }

    func testPlayedDayPointsMasksUpcomingDaysAndCountsRounds() {
        let live = match("live")
        let played = live.playedDayPoints(at: now, locale: en)
        XCTAssertEqual(played.count, 7)
        XCTAssertEqual(played.map(\.isToday), [false, false, false, false, true, false, false])
        XCTAssertEqual(played.map(\.isUpcoming), [false, false, false, false, false, true, true])
        XCTAssertEqual(played[4].you, 212)
        XCTAssertEqual(played[4].them, 188)
        XCTAssertNil(played[5].you)
        XCTAssertNil(played[5].them)
        XCTAssertNil(played[6].you)
        let tally = live.roundTally(at: now)
        XCTAssertEqual([tally.won, tally.lost, tally.tied], [2, 2, 0])
    }

    func testTodayScoresMatchLiveAndPendingStates() {
        let live = match("live").todayScores(at: now)
        XCTAssertEqual(live.you, 212)
        XCTAssertEqual(live.them, 188)
        let pending = match("pending").todayScores(at: now)
        XCTAssertEqual(pending.you, 300)
        XCTAssertEqual(pending.them, 240)
        let scheduled = match("scheduled").todayScores(at: now)
        XCTAssertNil(scheduled.you)
        XCTAssertNil(scheduled.them)
        let won = match("won").todayScores(at: now)
        XCTAssertNil(won.you)
        XCTAssertNil(won.them)
    }

    func testRivalryRecordTextAndAccessibility() throws {
        let rivalry = try XCTUnwrap(match("live").rivalry)
        XCTAssertEqual(rivalry.recordText, "4–2")
        XCTAssertEqual(
            rivalry.accessibilityLabel(opponentName: "Sam"),
            "All-time versus Sam: 4 wins, 2 losses. You won the last 2. Strongest ring: Exercise, 14–6 days."
        )
        var tied = rivalry
        tied.ties = 1
        XCTAssertEqual(tied.recordText, "4–2–1")
        XCTAssertTrue(tied.accessibilityLabel(opponentName: "Sam").contains("1 tie."))
    }

    func testDashboardSnapshotPopulatesTodayRingsChaseSuggestionAndRivalry() throws {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let start = try CompetitionDay(era: 1, year: 2026, month: 11, day: 2, timeZoneIdentifier: "UTC")
        let schedule = CompetitionSchedule(calendar: calendar, startDay: start)
        let ringSnapshot = ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: 450, goal: 600),
            exercise: try ActivityRingReading(value: 20, goal: 30),
            standOrRoll: try ActivityRingReading(value: 8, goal: 12),
            pauseState: .running
        )
        let today = try CompetitionDay(era: 1, year: 2026, month: 11, day: 6, timeZoneIdentifier: "UTC")
        let liveDays = try (1...7).map { ordinal -> LocalCompetitionDayPresentation in
            let day = try CompetitionDay(era: 1, year: 2026, month: 11, day: 1 + ordinal, timeZoneIdentifier: "UTC")
            let isCurrent = day == today
            let past = ordinal < 5
            var row = LocalCompetitionDayPresentation(
                day: day,
                ordinal: ordinal,
                ownerAcceptedPoints: isCurrent ? 208 : (past ? 200 : nil),
                ownerLatestAvailability: isCurrent || past ? .observed : .notYetOccurred,
                opponentRevealedPoints: isCurrent ? 220 : (past ? 210 : nil),
                ownerAcceptedSnapshot: isCurrent ? ringSnapshot : nil,
                ownerLatestSnapshot: isCurrent ? ringSnapshot : nil
            )
            if past {
                row.ownerRingPoints = [70, 80, 50]
                row.opponentRingPoints = [80, 60, 70]
            }
            return row
        }
        let liveMatch = CompetitionPresentation(
            id: CompetitionID(UUID(uuidString: "00000000-0000-0000-0000-000000000101")!),
            ownerDisplayName: "Naren",
            opponentDisplayName: "Sam",
            opponentIdentity: "remote-profile:v1:sam",
            lifecycle: .active(dayOrdinal: 5),
            acceptedConfiguration: LocalCompetitionAcceptedPresentation(schedule: schedule, difficulty: .balanced),
            userPoints: 1_008,
            opponentPoints: 1_060,
            days: liveDays,
            currentDayOrdinal: 5,
            lastRefresh: nil,
            tally: nil,
            terminalResult: nil,
            evaluatedAt: now,
            timeZoneIdentifier: "UTC"
        )
        let priorSchedule = CompetitionSchedule(
            calendar: calendar,
            startDay: try CompetitionDay(era: 1, year: 2026, month: 10, day: 19, timeZoneIdentifier: "UTC")
        )
        let priorDays = try (1...7).map { ordinal -> LocalCompetitionDayPresentation in
            let day = try CompetitionDay(era: 1, year: 2026, month: 10, day: 18 + ordinal, timeZoneIdentifier: "UTC")
            var row = LocalCompetitionDayPresentation(
                day: day,
                ordinal: ordinal,
                ownerAcceptedPoints: 250,
                ownerLatestAvailability: .observed,
                opponentRevealedPoints: 220
            )
            row.ownerRingPoints = [80, 95, 75]
            row.opponentRingPoints = [85, 65, 70]
            return row
        }
        let completedAt = ISO8601DateFormatter().date(from: "2026-10-26T09:00:00Z")!
        let priorWin = CompetitionPresentation(
            id: CompetitionID(UUID(uuidString: "00000000-0000-0000-0000-000000000100")!),
            ownerDisplayName: "Naren",
            opponentDisplayName: "Sam",
            opponentIdentity: "remote-profile:v1:sam",
            lifecycle: .completed(
                outcome: .win,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: completedAt
            ),
            acceptedConfiguration: LocalCompetitionAcceptedPresentation(schedule: priorSchedule, difficulty: .balanced),
            userPoints: 1_750,
            opponentPoints: 1_540,
            days: priorDays,
            currentDayOrdinal: nil,
            lastRefresh: nil,
            tally: nil,
            terminalResult: LocalCompetitionTerminalPresentation(
                userPoints: 1_750,
                opponentPoints: 1_540,
                outcome: .win,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: completedAt
            ),
            evaluatedAt: now,
            timeZoneIdentifier: "UTC"
        )
        let dashboard = CompetitionDashboard(
            competitions: [liveMatch, priorWin],
            awards: [],
            issues: [],
            hiddenTerminalCompetitionCount: 0
        )
        let snapshot = Snapshot(dashboard: dashboard)
        let built = try XCTUnwrap(snapshot.matches.first { $0.id == liveMatch.id.rawValue })
        XCTAssertEqual(built.todayRings?.dayOrdinal, 5)
        XCTAssertEqual(built.todayRings?.rows.map(\.kind), [.move, .exercise, .stand])
        XCTAssertEqual(built.todayRings?.rows.first?.detail, "450/600 kcal")
        XCTAssertNotNil(built.chase?.suggestion)
        XCTAssertEqual(built.rivalry?.wins, 1)
        XCTAssertEqual(built.rivalry?.losses, 0)
        XCTAssertEqual(built.rivalry?.edgeRing, .exercise)
        XCTAssertEqual(built.rivalry?.edgeRecord, "7–0 days")
        XCTAssertNil(built.customMetrics)
    }

    func testWeekHeaderTitleAdaptsToMatchFormatAndStanding() {
        XCTAssertEqual(match("live").weekHeaderTitle(at: now), "Week rounds")
        XCTAssertEqual(match("groupDoubles").weekHeaderTitle(at: now), "Week rounds")
        XCTAssertEqual(match("groupFFA").weekHeaderTitle(at: now), "Week vs 1st")

        var ffaLeading = match("groupFFA")
        ffaLeading.group?.rows = [
            .init(place: 1, name: "You", points: 1_800, isYou: true),
            .init(place: 2, name: "Sam", points: 1_712, isYou: false),
            .init(place: 3, name: "Priya", points: 1_498, isYou: false),
        ]
        XCTAssertEqual(ffaLeading.weekHeaderTitle(at: now), "Week vs 2nd")
    }

    func testCustomMetricsRoundTripAndSpokenSummary() throws {
        let sleep = match("sleepMatch")
        XCTAssertEqual(sleep.customMetrics, [.move, .exercise, .stand, .sleep])
        XCTAssertEqual(sleep.customMetricsAccessibilityText, "Metrics: Move, Exercise, Stand, Sleep.")
        XCTAssertNil(match("live").customMetricsAccessibilityText)

        let payload = CompetitionWatchPayload(snapshot: fixture("sleepMatch"), sentAt: 300)
        guard case let .store(decoded) = payload.action(after: 100) else {
            return XCTFail("expected sleepMatch snapshot")
        }
        XCTAssertEqual(decoded.matches[0].customMetrics, [.move, .exercise, .stand, .sleep])
        XCTAssertEqual(
            CompetitionWidgetSnapshot.TodayRings.RingKind.customMetrics(for: .threeRings),
            nil
        )
        XCTAssertEqual(
            CompetitionWidgetSnapshot.TodayRings.RingKind.customMetrics(for: [.move, .sleep]),
            [.move, .sleep]
        )
    }
}
