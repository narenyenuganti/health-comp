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
        XCTAssertEqual(calls.value.map(\.snapshot), [first, touched])
        XCTAssertEqual(calls.value.map(\.material), [true, false])
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
            let match = match(row.scenario)
            XCTAssertEqual(match.boardStatus(at: now, locale: en), row.status, row.scenario)
            XCTAssertEqual(match.inlineText(at: now, locale: en), row.inline, row.scenario)
            XCTAssertEqual(match.cornerLabel(at: now, locale: en), row.corner, row.scenario)
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

    func testAnOlderFileWithNoBeltStillDecodes() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture("live"))) as? [String: Any]
        )
        var matches = try XCTUnwrap(object["matches"] as? [[String: Any]])
        XCTAssertNil(matches[0]["belt"])
        matches[0]["belt"] = nil
        object["matches"] = matches
        let data = try JSONSerialization.data(withJSONObject: object)
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
