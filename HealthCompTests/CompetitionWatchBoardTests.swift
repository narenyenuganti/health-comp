import CompetitionCore
import ComposableArchitecture
import Foundation
import XCTest
@testable import HealthComp

/// The watch's logic. It lives in shared sources so this suite covers it on
/// CI, which has no watch lane.
final class CompetitionWatchBoardTests: XCTestCase {
    typealias Snapshot = CompetitionWidgetSnapshot
    typealias Match = CompetitionWidgetSnapshot.Match

    private let en = Locale(identifier: "en_US")
    /// A Friday.
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

    // MARK: Mirror

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
        await client.write(first, [])  // unchanged: silent
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

    // MARK: Payload

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

    // MARK: Pages

    func testPagesFollowTheComplicationAndDropWhatHasGone() {
        let several = fixture("several")
        XCTAssertEqual(several.pages(at: now).map(\.name), ["Sam", "Alex", "Riley", "Casey", "Former competitor"])
        XCTAssertEqual(several.pages(at: now).first, several.featured(personID: nil, at: now))
        XCTAssertEqual(fixture("samGone").pages(at: now).map(\.name), ["Alex"])
        XCTAssertEqual(fixture("empty").pages(at: now), [])
        XCTAssertEqual(fixture("card").pages(at: now).map(\.id), fixture("card").matches.map(\.id))
    }

    // MARK: The card, the week, the alert

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

    /// The watch reads the iPhone's keys without compiling `CompetitionRoute`.
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

    // MARK: Copy

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

    // MARK: Chase

    func testChaseFillsTodayTowardTheLead() throws {
        let chase = try XCTUnwrap(match("trailing").chase(at: now, locale: en))
        XCTAssertEqual(chase.fill, 200.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(chase.lead, "55")
        XCTAssertEqual(chase.line, "200 of 255 today")
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
        XCTAssertNil(match("beltTrailing").chase(at: now))  // the phone couldn't work it out
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

    // MARK: Stale, side, size

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
        // Decided by decimals: not square, though whole points read the same.
        XCTAssertEqual(match("closeFinal").side, .them)
        var win = match("closeFinal")
        (win.userPoints, win.opponentPoints) = (win.opponentPoints, win.userPoints)
        XCTAssertEqual(win.side, .you)
        // Live numbers round: 412.30 to 412.10 reads square.
        var live = match("live")
        (live.userPoints, live.opponentPoints) = (412.30, 412.10)
        XCTAssertEqual(live.side, .square)
    }

    func testScoreSizeLadder() {
        let widths: [CGFloat] = [162 - 20, 176 - 20, 205 - 20]  // 40, 41, 49 mm
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

    // MARK: Seen

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
}
