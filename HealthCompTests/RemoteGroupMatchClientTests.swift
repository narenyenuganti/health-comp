import CompetitionCore
import Foundation
import XCTest

@testable import HealthComp

/// `Fixtures/group-matches-list.json` is the real `list_group_matches` body
/// for player 1, captured from a local stack with the 040 pgTAP setup: a
/// finished three-way with a leaver, a live doubles with a Pacer bot, and a
/// pending three-way.
final class RemoteGroupMatchClientTests: XCTestCase {
    private let viewer = UUID(uuidString: "69e5d45f-d72b-2738-b230-1af2557f7b92")!
    private let finishedID = UUID(uuidString: "0ec6385c-ab1a-496b-b0a2-84b01fa75c16")!
    private let doublesID = UUID(uuidString: "3656997c-2f73-47b5-ba2c-8288f5a7ecfe")!
    private let pendingID = UUID(uuidString: "57bb50d9-30f0-4a8f-afc1-9978cf9c52e8")!
    /// Day 3 of the doubles week (it starts Sun Nov 8, UTC).
    private let dayThreeNoon = Date(timeIntervalSince1970: 1_794_312_000)

    // MARK: Decoding

    func testDecodesTheServersOwnListExactly() throws {
        let matches = try GroupMatchWire.decodeList(fixture(), viewer: viewer)
        XCTAssertEqual(matches.map(\.id), [finishedID, doublesID, pendingID])

        let doubles = try XCTUnwrap(matches.first { $0.id == doublesID })
        XCTAssertEqual(doubles.format, .doubles)
        XCTAssertEqual(doubles.serverVersion, 11)
        XCTAssertEqual(doubles.ownerRevisionHighWater, 3)
        XCTAssertEqual(doubles.startDay, "2026-11-08")
        XCTAssertEqual(doubles.seats[0].days.map(\.clientRevision), [1, 3])
        XCTAssertEqual(doubles.seats[0].days.map(\.serverSequence), [7, 9])
        XCTAssertEqual(doubles.seats[0].days.map(\.centipoints), [25_000, 32_000])
        XCTAssertEqual(doubles.seats[0].days[0].ringBasisPoints, [20_000, 5_000, 0])
        XCTAssertEqual(doubles.seats[3].botMode, .pacer)
        XCTAssertEqual(doubles.seats[3].botSeed, 16_790_557_316_201_087_987)
        XCTAssertEqual(doubles.seats[3].botDailyTotals, [270, 285, 294, 291, 330, 300, 312])

        let finished = try XCTUnwrap(matches.first { $0.id == finishedID })
        XCTAssertEqual(finished.ownerAttestation?.acceptedRevisions, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(finished.ownerAttestation?.basis, .stable)
        XCTAssertEqual(finished.ownerAttestation?.serverSequence, 21)
        XCTAssertEqual(finished.seats[2].frozenThroughDay, 7)
        XCTAssertEqual(finished.result?.standings.map(\.place), [1, 1, 3])

        let pending = try XCTUnwrap(matches.first { $0.id == pendingID })
        XCTAssertNil(pending.startDay)
        XCTAssertEqual(pending.seats.map(\.state), ["accepted", "accepted", "pending"])
    }

    func testRejectsAnyShapeTheServerDoesNotSend() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("extra match key", { $0["note"] = "x" }),
            ("missing seat key", { Self.editSeat(&$0, 0) { _ = $0.removeValue(forKey: "can_view_photo") } }),
            ("numeric revision", { Self.editSeat(&$0, 0) { seat in
                var days = seat["days"] as! [[String: Any]]
                days[0]["client_revision"] = 1
                seat["days"] = days
            } }),
            ("numeric server version", { $0["server_version"] = 11 }),
            ("someone else's owner block", { match in
                var owner = match["owner"] as! [String: Any]
                owner["profile_id"] = "4000ca96-a5d0-db44-3b89-bbfb6bc44e19"
                match["owner"] = owner
            }),
            ("uppercase id", { $0["competition_id"] = "3656997C-2F73-47B5-BA2C-8288F5A7ECFE" }),
            ("bot with a profile", { Self.editSeat(&$0, 3) { $0["profile_id"] = "758901eb-c557-7975-e585-97488b2a907e" } }),
        ]
        for (name, mutate) in mutations {
            let data = try editedFixture(doublesID, mutate)
            XCTAssertThrowsError(try GroupMatchWire.decodeList(data, viewer: viewer), name)
        }
        XCTAssertThrowsError(try GroupMatchWire.decodeList(fixture(), viewer: UUID()), "another account's list")
    }

    func testDecodesFrozenSeatDaysWhenTheServerSendsThem() throws {
        func days(_ points: String?, status: String = "available", reason: Any = NSNull()) -> [[String: Any]] {
            (1...7).map { ["ordinal": $0, "status": status, "centi_points": points ?? NSNull(), "reason": reason] }
        }
        func seats(_ third: [[String: Any]]) -> [[String: Any]] {
            [
                ["seat_index": 1, "total_centi_points": "210000", "days": days("30000")],
                ["seat_index": 2, "total_centi_points": "210000", "days": days("30000")],
                ["seat_index": 3, "total_centi_points": "0", "days": third],
            ]
        }
        func withSeats(version: Any?, _ value: [[String: Any]]) throws -> Data {
            try editedFixture(finishedID) { match in
                var result = match["result"] as! [String: Any]
                result["seats"] = value
                if let version { result["version"] = version }
                match["result"] = result
            }
        }
        let leaver = days(nil, status: "afterLeave", reason: "afterLeave")
        let decoded = try GroupMatchWire.decodeList(withSeats(version: 1, seats(leaver)), viewer: viewer)
        let frozen = try XCTUnwrap(decoded.first { $0.id == finishedID }?.result?.seats)
        XCTAssertEqual(frozen.map(\.totalCentipoints), [210_000, 210_000, 0])
        XCTAssertEqual(frozen[0].days.map(\.centipoints), Array(repeating: 30_000, count: 7))
        XCTAssertEqual(frozen[2].days.map(\.status), Array(repeating: "afterLeave", count: 7))
        XCTAssertNil(try GroupMatchWire.decodeList(fixture(), viewer: viewer).first { $0.id == finishedID }?.result?.seats)

        XCTAssertThrowsError(try GroupMatchWire.decodeList(withSeats(version: nil, seats(leaver)), viewer: viewer), "no version")
        XCTAssertThrowsError(
            try GroupMatchWire.decodeList(withSeats(version: 1, seats(days(nil, status: "missing"))), viewer: viewer),
            "unknown status"
        )
        XCTAssertThrowsError(
            try GroupMatchWire.decodeList(withSeats(version: 1, Array(seats(leaver).prefix(2))), viewer: viewer),
            "a seat left out"
        )
        var numeric = seats(leaver)
        numeric[0]["total_centi_points"] = 210_000
        XCTAssertThrowsError(try GroupMatchWire.decodeList(withSeats(version: 1, numeric), viewer: viewer), "numeric total")
    }

    // MARK: Presentation

    func testProjectsLiveDoublesWithTheBotRevealedAndFinishedAsFrozen() throws {
        let matches = try GroupMatchWire.decodeList(fixture(), viewer: viewer)
        let doubles = try XCTUnwrap(matches.first { $0.id == doublesID }?.presentation(viewer: viewer, now: dayThreeNoon))
        XCTAssertEqual(doubles.lifecycle, .active(dayOrdinal: 3))
        XCTAssertEqual(doubles.viewerSubject, .team(1))
        let bot = UUID(uuidString: "714c90c1-600d-47f3-ba49-cc628a4812c1")!
        let botDays = doubles.days.filter { $0.seatID == bot }
        XCTAssertEqual(botDays.prefix(2).map(\.value), [.centipoints(27_000), .centipoints(28_500)])
        let revealed = BotWeek.revealed(
            seed: 16_790_557_316_201_087_987, mode: .pacer, dayOrdinal: 3, finalPoints: 294, progressBasisPoints: 5_000
        )
        XCTAssertEqual(botDays.last?.value, .centipoints(revealed * 100))
        XCTAssertNil(doubles.frozenStandings)

        let finished = try XCTUnwrap(matches.first { $0.id == finishedID }?.presentation(viewer: viewer, now: dayThreeNoon))
        XCTAssertEqual(finished.frozenStandings?.map(\.place), [1, 1, 3])
        XCTAssertEqual(finished.configuration.leaveCutoffs, [UUID(uuidString: "fd868187-1a33-4352-899f-7103d33f7899")!: 7])
        guard case .completed(outcome: .tie, basis: .stableAcrossPostBoundaryReads, _) = finished.lifecycle else {
            return XCTFail("finished match should be a shared first")
        }

        let pending = try XCTUnwrap(matches.first { $0.id == pendingID }?.presentation(viewer: viewer, now: dayThreeNoon))
        guard case .pending(direction: .outgoing, _, _) = pending.lifecycle else { return XCTFail("creator's lobby") }
        XCTAssertEqual(pending.seats[2].invite, .invited)
    }

    func testCarriesReactionsAndTheServersNudgeRuleIntoThePresentation() throws {
        let model = try XCTUnwrap(GroupMatchWire.decodeList(fixture(), viewer: viewer).first { $0.id == doublesID })
        let doubles = try XCTUnwrap(model.presentation(viewer: viewer, now: dayThreeNoon))
        let ids = doubles.seats.map(\.id)
        // Seat 2 (your partner) fired at your Day 1.
        XCTAssertEqual(doubles.reactions, [GroupMatchReaction(authorSeatID: ids[1], targetSeatID: ids[0], ordinal: 1, kind: .fire)])
        // Your partner uploaded at 08:41, under 12 hours before noon; by 21:00 the server takes a nudge.
        XCTAssertFalse(doubles.canNudgePartner)
        let evening = try XCTUnwrap(model.presentation(viewer: viewer, now: dayThreeNoon.addingTimeInterval(9 * 3_600)))
        XCTAssertTrue(evening.canNudgePartner)
    }

    func testAFinishedMatchTakesItsTotalsAndDaysFromTheFrozenResultSeats() throws {
        func days(_ points: [Int]) -> [[String: Any]] {
            points.enumerated().map {
                ["ordinal": $0.offset + 1, "status": "available", "centi_points": String($0.element), "reason": NSNull()]
            }
        }
        let data = try editedFixture(finishedID) { match in
            var result = match["result"] as! [String: Any]
            result["version"] = 1
            result["seats"] = [
                ["seat_index": 1, "total_centi_points": "210000", "days": days([40_000, 20_000] + Array(repeating: 30_000, count: 5))],
                ["seat_index": 2, "total_centi_points": "210000", "days": days([20_000, 40_000] + Array(repeating: 30_000, count: 5))],
                ["seat_index": 3, "total_centi_points": "0", "days": { () -> [[String: Any]] in
                    var seatDays = days(Array(repeating: 0, count: 7))
                    // Never uploaded: still a scored zero, so day 3 has winners.
                    seatDays[2] = ["ordinal": 3, "status": "unavailable", "centi_points": NSNull(), "reason": "missing"]
                    return seatDays
                }()],
            ]
            match["result"] = result
        }
        let finished = try XCTUnwrap(
            GroupMatchWire.decodeList(data, viewer: viewer).first { $0.id == finishedID }?
                .presentation(viewer: viewer, now: dayThreeNoon)
        )
        let ids = finished.seats.map(\.id)
        XCTAssertEqual(finished.frozenSeatTotals, [ids[0]: 210_000, ids[1]: 210_000, ids[2]: 0])
        XCTAssertEqual(finished.frozenDays?.count, 21)
        // Day 1 to seat 1, day 2 to seat 2, days 3-7 shared.
        XCTAssertEqual(ids.map { finished.frozenDaysWon(by: .seat($0)) }, [6, 6, 0])

        let withoutSeats = try XCTUnwrap(
            GroupMatchWire.decodeList(fixture(), viewer: viewer).first { $0.id == finishedID }?
                .presentation(viewer: viewer, now: dayThreeNoon)
        )
        XCTAssertNil(withoutSeats.frozenSeatTotals)
        XCTAssertNil(withoutSeats.frozenDays)
    }

    func testWhoeverClosedAMatchShowsAsWithdrawnOrDeclined() throws {
        func closed(by profileID: String) throws -> GroupMatchPresentation {
            let data = try editedFixture(pendingID) { match in
                match["lifecycle"] = "declined"
                match["closed_by_profile_id"] = profileID
                match["closed_at"] = "2026-11-10T09:00:00+00:00"
            }
            return try XCTUnwrap(
                GroupMatchWire.decodeList(data, viewer: viewer).first { $0.id == pendingID }?
                    .presentation(viewer: viewer, now: dayThreeNoon)
            )
        }
        // Seat 2 had accepted, so closing it is a withdrawal; seat 3 never answered.
        let withdrawn = try closed(by: "4000ca96-a5d0-db44-3b89-bbfb6bc44e19")
        XCTAssertEqual(withdrawn.seats.map(\.invite), [.accepted, .withdrew, .invited])
        let declined = try closed(by: "758901eb-c557-7975-e585-97488b2a907e")
        XCTAssertEqual(declined.seats.map(\.invite), [.accepted, .accepted, .declined])
    }

    // MARK: Read model cache

    func testStaleRefreshKeepsTheNewerCachedMatchAndOfflineUsesTheCache() async throws {
        let harness = try Harness()
        let current = try GroupMatchWire.decodeList(fixture(), viewer: viewer)
        try await harness.store.saveReadModel(current)
        let older = try editedFixture(doublesID) { match in
            match["server_version"] = "10"
            match["lifecycle"] = "cancelled"
        }
        var sync = harness.sync(api: groupTestAPI(listGroupMatches: { older }), now: { self.dayThreeNoon })
        var refreshed = await sync.refresh()
        XCTAssertFalse(refreshed.isFresh, "a list older than the cache can't vouch for current heads")
        XCTAssertEqual(refreshed.matches.first { $0.id == doublesID }?.lifecycle, "scheduled")

        let newer = try editedFixture(doublesID) { $0["server_version"] = "12" }
        sync = harness.sync(api: groupTestAPI(listGroupMatches: { newer }), now: { self.dayThreeNoon })
        refreshed = await sync.refresh()
        XCTAssertTrue(refreshed.isFresh)
        XCTAssertEqual(refreshed.matches.first { $0.id == doublesID }?.serverVersion, 12)

        sync = harness.sync(api: groupTestAPI(listGroupMatches: { Data("{\"version\":1}".utf8) }), now: { self.dayThreeNoon })
        refreshed = await sync.refresh()
        XCTAssertFalse(refreshed.isFresh)
        XCTAssertEqual(refreshed.matches.map(\.id), [finishedID, doublesID, pendingID])
        XCTAssertEqual(refreshed.matches.first { $0.id == doublesID }?.serverVersion, 12)

        let otherAccount = GroupMatchStore(directory: harness.groupDirectory, profileID: UUID())
        let foreign = await otherAccount.readModel()
        XCTAssertEqual(foreign, [])
    }

    // MARK: Own uploads

    func testUploadsChangedDaysOnceAndRetriesResendIdenticalBytes() async throws {
        let harness = try Harness()
        let server = try FakeGroupServer(fixture: fixture(), matchID: doublesID, viewer: viewer)
        await server.setFailingAppends(true)
        let clock = TestClock(dayThreeNoon)
        let sync = harness.sync(
            api: server.api(), environment: try health(startDay: (2026, 11, 8), days: 3), now: { clock.now }
        )

        _ = await sync.run()
        // sync-02: days 2 and 3 wait in the outbox behind day 1's failure, so
        // revisions reach the server in order.
        let failed = await server.attemptedRequests()
        XCTAssertEqual(failed.map(\.dayOrdinal), [1])
        XCTAssertEqual(failed.map(\.clientRevision), [4])
        let queued = try await harness.outbox.entries().compactMap { entry -> CompetitionScoreRevisionRequest? in
            guard case let .scoreRevision(request) = entry.payload else { return nil }
            return request
        }
        XCTAssertEqual(queued.map(\.clientRevision), [4, 5, 6])
        XCTAssertTrue(queued.allSatisfy {
            $0.semanticEventID == RemoteGroupMatchSync.semanticEventID(wireContentSHA256: $0.wireContentSHA256)
        })

        await server.setFailingAppends(false)
        clock.now = dayThreeNoon.addingTimeInterval(5)
        _ = await sync.run()
        let accepted = await server.acceptedRequests()
        XCTAssertEqual(accepted, queued, "a retry sends the same request, evaluation time included")
        XCTAssertEqual(accepted.first, failed.first)
        let document = try await XCTUnwrapAsync(await harness.store.owner(doublesID))
        XCTAssertEqual(document.allocatedRevision, 6)
        XCTAssertEqual(document.accepted.map(\.clientRevision), [4, 5, 6])
        let outbox = try await harness.outbox.entries()
        XCTAssertEqual(outbox, [])

        clock.now = dayThreeNoon.addingTimeInterval(60)
        _ = await sync.run()
        let afterUnchangedRead = await server.attemptedRequests()
        XCTAssertEqual(afterUnchangedRead.count, 4, "an unchanged reading is not sent again")
        let journal = try await harness.events.load(CompetitionID(doublesID))
        XCTAssertNil(journal, "group scores never reach the duel journal")
    }

    func testARevisionSpentBeforeACrashIsNeverReused() async throws {
        let harness = try Harness()
        let server = try FakeGroupServer(fixture: fixture(), matchID: doublesID, viewer: viewer)
        _ = try await harness.store.allocateRevision(doublesID, atLeast: 3)
        _ = try await harness.store.allocateRevision(doublesID, atLeast: 3)
        let sync = harness.sync(
            api: server.api(), environment: try health(startDay: (2026, 11, 8), days: 1), now: { self.dayThreeNoon }
        )
        _ = await sync.run()
        let sent = await server.acceptedRequests()
        XCTAssertEqual(sent.map(\.clientRevision), [6, 7, 8], "day 1 read, days 2-3 missing; 4 and 5 stay spent")
    }

    func testAcceptedButNotRemovedReplaysIntoTheOwnerDocumentEvenWhenItIsGone() async throws {
        for hasDocument in [true, false] {
            let harness = try Harness()
            if hasDocument { _ = try await harness.store.allocateRevision(doublesID, atLeast: 3) }
            let request = try groupRequest(revision: 4)
            let entry = try await harness.outbox.enqueue(.scoreRevision(request), enqueuedAt: dayThreeNoon)
            _ = try await harness.outbox.update(
                entry.semanticEventID,
                expectedGeneration: entry.generation,
                state: .scoreAccepted(
                    try CompetitionScoreRevisionResponse(
                        disposition: .appended, rejectionCode: nil, acceptedCentiPoints: 18_000,
                        wireContentSHA256: request.wireContentSHA256, acceptedServerSequence: 12, competitionCursor: 12
                    ),
                    receivedAt: dayThreeNoon
                )
            )
            let coordinator = CompetitionSyncCoordinator(
                profileID: viewer,
                outboxStore: harness.outbox,
                remoteAPI: groupTestAPI(listGroupMatches: { throw CompetitionRemoteFailure.operationFailed }),
                acceptedScorePersistence: .routing(groups: harness.store, duels: harness.events),
                now: { self.dayThreeNoon }
            )
            await coordinator.wake()
            await coordinator.waitUntilIdle()
            await coordinator.stop()
            let document = await harness.store.owner(doublesID)
            XCTAssertEqual(document?.accepted.map(\.clientRevision), [4], "document present: \(hasDocument)")
            XCTAssertEqual(document?.accepted.first?.serverSequence, 12)
            let outbox = try await harness.outbox.entries()
            XCTAssertEqual(outbox, [])
            let journal = try await harness.events.load(CompetitionID(doublesID))
            XCTAssertNil(journal)
        }
    }

    // MARK: Final window

    func testFinalAttestationWaitsForUploadsThenUsesRefreshedHeads() async throws {
        let harness = try Harness()
        let server = try FakeGroupServer(
            fixture: fixture(), matchID: doublesID, viewer: viewer,
            startDay: "2026-11-03", deadline: "2026-11-12T00:00:00+00:00"
        )
        await server.setFailingAppends(true)
        let clock = TestClock(dayThreeNoon)
        let sync = harness.sync(
            api: server.api(), environment: try health(startDay: (2026, 11, 3), days: 7), now: { clock.now }
        )

        _ = await sync.run()
        var log = await server.log
        XCTAssertFalse(log.contains("attest"), "no attestation while uploads are queued")

        await server.setFailingAppends(false)
        await server.clearLog()
        clock.now = dayThreeNoon.addingTimeInterval(5)
        _ = await sync.run()
        log = await server.log
        // The wake-up drain may start before the first list; what matters is
        // every upload, then a fresh list, then the attestation.
        XCTAssertEqual(log.filter { $0 == "append" }.count, 7)
        XCTAssertEqual(Array(log.suffix(2)), ["list", "attest"])
        let attestation = try await XCTUnwrapAsync(await server.attestations.first)
        XCTAssertEqual(attestation.basis, .stable)
        XCTAssertEqual(attestation.acceptedRevisions, [4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(attestation.attestationVersion, 1)

        // The acknowledgment stays until the read model shows it, then leaves.
        await server.clearLog()
        clock.now = dayThreeNoon.addingTimeInterval(60)
        _ = await sync.run()
        log = await server.log
        XCTAssertFalse(log.contains("attest"))
        let outbox = try await harness.outbox.entries()
        XCTAssertEqual(outbox, [])
    }

    /// sync-08: a rejected attestation (here a 401 during an auth blip) is
    /// not "already queued"; the next pass sends it again and drops the
    /// rejection.
    func testARejectedAttestationIsSentAgainOnTheNextPass() async throws {
        let harness = try Harness()
        let server = try FakeGroupServer(
            fixture: fixture(), matchID: doublesID, viewer: viewer,
            startDay: "2026-11-03", deadline: "2026-11-12T00:00:00+00:00"
        )
        await server.rejectAttestations(1)
        let clock = TestClock(dayThreeNoon)
        let sync = harness.sync(
            api: server.api(), environment: try health(startDay: (2026, 11, 3), days: 7), now: { clock.now }
        )
        _ = await sync.run()
        var sent = await server.attestations
        XCTAssertTrue(sent.isEmpty, "the first attestation was refused")
        let parked = try await harness.outbox.entries().filter {
            if case .permanentFailure = $0.state { return true } else { return false }
        }
        XCTAssertEqual(parked.count, 1)

        clock.now = dayThreeNoon.addingTimeInterval(5)
        _ = await sync.run()
        sent = await server.attestations
        XCTAssertEqual(sent.map(\.basis), [.stable])
        XCTAssertEqual(sent.map(\.attestationVersion), [2])
        let outbox = try await harness.outbox.entries()
        XCTAssertFalse(outbox.contains {
            if case .permanentFailure = $0.state { return true } else { return false }
        }, "the retried rejection left the outbox")
    }

    func testAFailedFinalReadSendsOnlyBestAvailableAfterTheDeadline() async throws {
        for (deadline, expected) in [
            ("2026-11-12T00:00:00+00:00", [CompetitionAttestationBasis]()),
            ("2026-11-10T00:00:00+00:00", [.bestAvailable]),
        ] {
            let harness = try Harness()
            let server = try FakeGroupServer(
                fixture: fixture(), matchID: doublesID, viewer: viewer, startDay: "2026-11-03", deadline: deadline
            )
            let sync = harness.sync(
                api: server.api(), environment: try health(startDay: (2026, 11, 3), days: 7, readFails: true),
                now: { self.dayThreeNoon }
            )
            _ = await sync.run()
            let sent = await server.attestations
            XCTAssertEqual(sent.map(\.basis), expected, deadline)
            XCTAssertEqual(sent.first?.acceptedRevisions ?? [1, 3, 0, 0, 0, 0, 0], [1, 3, 0, 0, 0, 0, 0])
        }
    }

    // MARK: Isolation from duels

    func testGroupUploadsSurviveTheDuelInventoryAndABadGroupListLeavesDuelsAlone() async throws {
        let harness = try Harness()
        _ = try await harness.store.allocateRevision(doublesID, atLeast: 3)
        _ = try await harness.outbox.enqueue(.scoreRevision(try groupRequest(revision: 4)), enqueuedAt: dayThreeNoon)
        let presenceChecks = PresenceProbe()
        let runtime = RemoteCompetitionRuntime(
            profileID: viewer,
            store: harness.events,
            remoteAPI: groupTestAPI(
                listGroupMatches: { Data("not json".utf8) },
                competitionExists: { id in
                    await presenceChecks.record(id)
                    return false
                }
            ),
            outboxStore: harness.outbox,
            groupMatchStore: harness.store,
            now: { self.dayThreeNoon }
        )
        async let groups = runtime.synchronizeGroupMatches()
        let duels = await runtime.synchronizeAll()
        _ = await groups
        await runtime.stop()
        XCTAssertNil(duels.discoveryFailure)
        XCTAssertEqual(duels.failures, [])
        let checked = await presenceChecks.ids
        XCTAssertEqual(checked, [], "a group id never goes through the duel deletion check")
        let outbox = try await harness.outbox.entries()
        XCTAssertEqual(outbox.map(\.payload.competitionID), [doublesID])
    }

    func testPublishedGroupMatchesStayOutOfEveryDuelSurface() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(id: viewer, displayName: "Player 1")
        let paths = AuthenticatedProfileStoragePaths(profileID: viewer, rootDirectory: root)
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Only the matches with nothing left to upload, so the real clock
        // the client runs on doesn't matter.
        let body = try listBody(fixtureMatches().filter { ($0["competition_id"] as? String) != doublesID.uuidString.lowercased() })
        let client = CompetitionClient.remote(
            remoteAPI: groupTestAPI(listGroupMatches: { body }),
            environment: try health(startDay: (2026, 11, 8), days: 3)
        )
        try await client.mountAuthenticatedProfile(profile, paths)
        let updates = client.updates()
        _ = await client.reconcileAll(.pullToRefresh)
        let publication = try await XCTUnwrapAsync(await firstPublication(updates) { !$0.dashboard.groupMatches.isEmpty })
        XCTAssertEqual(Set(publication.dashboard.groupMatches.map(\.id.rawValue)), [finishedID, pendingID])
        XCTAssertEqual(publication.dashboard.competitions, [])
        XCTAssertEqual(CompetitionWidgetSnapshot(dashboard: publication.dashboard).matches, [])
        let notifications = RemoteCompetitionProjector.notificationSnapshot(
            publication: publication, materializations: [], profile: profile,
            context: CompetitionEnvironmentContext(
                instant: EnvironmentInstant(wallDate: dayThreeNoon, monotonic: MonotonicInstant(epochID: "groups", nanoseconds: 1)),
                timeZoneIdentifier: "UTC"
            ),
            knownCompetitionIDs: nil
        )
        XCTAssertTrue(notifications.competitions.isEmpty)

        // An added issue keeps the group matches (`publication(adding:)`).
        let rejected = await client.rematch(CompetitionID(finishedID))
        XCTAssertEqual(rejected.dashboard.groupMatches.map(\.id), publication.dashboard.groupMatches.map(\.id))

        // Offline after a relaunch: shown from the disk cache.
        await client.stop()
        let relaunched = CompetitionClient.remote(
            remoteAPI: groupTestAPI(listGroupMatches: { throw CompetitionRemoteFailure.retryableTransport }),
            environment: try health(startDay: (2026, 11, 8), days: 3)
        )
        try await relaunched.mountAuthenticatedProfile(profile, paths)
        let offline = await relaunched.reconcileAll(.pullToRefresh)
        XCTAssertEqual(
            Set(offline.dashboard.groupMatches.map(\.id.rawValue)), [finishedID, pendingID],
            "the cache shows in the first publication, before the network answers"
        )
        await relaunched.stop()
    }

    // MARK: Review findings (PR #243)

    /// Finding 1: the read finished at 23:59:59 on day 7 and the uploads
    /// crossed midnight. The week may only be sealed on a read started after
    /// it ended, so a late Watch sync for day 7 still counts.
    func testAReadBeforeMidnightNeverSealsTheWeek() async throws {
        let harness = try Harness()
        let server = try FakeGroupServer(
            fixture: fixture(), matchID: doublesID, viewer: viewer,
            startDay: "2026-11-03", deadline: "2026-11-12T00:00:00+00:00"
        )
        let midnight = Date(timeIntervalSince1970: 1_794_268_800)  // 2026-11-10T00:00Z
        let clock = TestClock(midnight.addingTimeInterval(-1))
        let source = FixtureActivitySource(fixture: try weekFixture(
            startDay: (2026, 11, 3), at: clock.now,
            changes: [try FixtureActivityChange(
                at: midnight.addingTimeInterval(1),
                updates: [.snapshot(day: try weekDays((2026, 11, 3))[6], snapshot: snapshot(move: 500))],
                triggers: []
            )]
        ))
        await server.onFirstAppend {
            clock.now = midnight.addingTimeInterval(5)
            try? await source.advance(to: midnight.addingTimeInterval(5))
        }
        let sync = harness.sync(api: server.api(), environment: .accelerated(source: source), now: { clock.now })
        _ = await sync.run()
        let attestation = try await XCTUnwrapAsync(await server.attestations.first)
        XCTAssertEqual(attestation.basis, .stable)
        XCTAssertEqual(attestation.acceptedRevisions, [4, 5, 6, 7, 8, 9, 11], "day 7 from the read after midnight")
    }

    /// Finding 2: this device queued revisions 4-10, another device moved the
    /// high-water to 20, and the server rejected them as a regression. The
    /// same readings go out again above 20 and the week still seals.
    func testARejectedUploadIsReplacedAboveTheNewHighWater() async throws {
        let harness = try Harness()
        let server = try FakeGroupServer(
            fixture: fixture(), matchID: doublesID, viewer: viewer,
            startDay: "2026-11-03", deadline: "2026-11-12T00:00:00+00:00"
        )
        await server.setFailingAppends(true)
        let clock = TestClock(dayThreeNoon)
        let sync = harness.sync(
            api: server.api(), environment: try health(startDay: (2026, 11, 3), days: 7), now: { clock.now }
        )
        _ = await sync.run()
        await server.setFailingAppends(false)
        await server.setHighWater(20)
        for minutes in [10.0, 20, 30] {
            clock.now = dayThreeNoon.addingTimeInterval(minutes * 60)
            _ = await sync.run()
        }
        let accepted = await server.acceptedRequests()
        XCTAssertEqual(accepted.map(\.clientRevision), Array(21...27))
        let attestation = try await XCTUnwrapAsync(await server.attestations.first)
        XCTAssertEqual(attestation.basis, .stable)
        XCTAssertEqual(attestation.acceptedRevisions, Array(21...27))
        let outbox = try await harness.outbox.entries()
        XCTAssertEqual(outbox, [], "the rejected requests leave once replaced")
    }

    func testARejectedUploadForAFinishedMatchLeavesTheOutbox() async throws {
        let harness = try Harness()
        let entry = try await harness.outbox.enqueue(
            .scoreRevision(try groupRequest(revision: 4, competitionID: finishedID)), enqueuedAt: dayThreeNoon
        )
        _ = try await harness.outbox.update(
            entry.semanticEventID, expectedGeneration: entry.generation,
            state: .permanentFailure(.finalizedCompetition, failedAt: dayThreeNoon)
        )
        let list = try fixture()
        _ = await harness.sync(api: groupTestAPI(listGroupMatches: { list }), now: { self.dayThreeNoon }).run()
        let outbox = try await harness.outbox.entries()
        XCTAssertEqual(outbox, [], "nothing can settle it once the result is in")
    }

    /// Finding 3: day 7 was accepted as A (revision 10), B (revision 11) is
    /// still queued, and the final read says A again. A goes out above B, so
    /// the sealed week matches the last read.
    func testAnInFlightValueNeverOutlivesTheFinalReading() async throws {
        let harness = try Harness()
        let server = try FakeGroupServer(
            fixture: fixture(), matchID: doublesID, viewer: viewer,
            startDay: "2026-11-03", deadline: "2026-11-12T00:00:00+00:00"
        )
        let daySevenNoon = dayThreeNoon.addingTimeInterval(-86_400)
        let clock = TestClock(daySevenNoon)
        func sync(daySevenMove: Double) throws -> RemoteGroupMatchSync {
            harness.sync(
                api: server.api(),
                environment: try health(startDay: (2026, 11, 3), days: 7, lastDayMove: daySevenMove),
                now: { clock.now }
            )
        }
        _ = try await sync(daySevenMove: 420).run()
        // B never lands while the final read is compared.
        await server.setFailingRevisions([11])
        clock.now = daySevenNoon.addingTimeInterval(60)
        _ = try await sync(daySevenMove: 500).run()
        clock.now = dayThreeNoon
        _ = try await sync(daySevenMove: 420).run()
        var accepted = await server.acceptedRequests()
        // sync-02: A is queued above B (revision 12) and waits for B, so the
        // server takes them in order; nothing is attested meanwhile.
        XCTAssertEqual(accepted.map(\.clientRevision), [4, 5, 6, 7, 8, 9, 10])
        let queued = try await harness.outbox.entries().compactMap { entry -> CompetitionScoreRevisionRequest? in
            guard case let .scoreRevision(request) = entry.payload else { return nil }
            return request
        }
        XCTAssertEqual(queued.map(\.clientRevision), [11, 12], "A goes out above B")
        XCTAssertEqual(queued.last?.moveBasisPoints, accepted[6].moveBasisPoints)
        let early = await server.attestations
        XCTAssertTrue(early.isEmpty)

        // B finally reaches the server, then A lands above it.
        await server.setFailingRevisions([])
        clock.now = dayThreeNoon.addingTimeInterval(3_600)
        _ = try await sync(daySevenMove: 420).run()
        accepted = await server.acceptedRequests()
        XCTAssertEqual(accepted.map(\.clientRevision).last, 12)
        XCTAssertEqual(accepted.last?.moveBasisPoints, accepted[6].moveBasisPoints)
        let attestation = try await XCTUnwrapAsync(await server.attestations.first)
        XCTAssertEqual(attestation.basis, .stable)
        XCTAssertEqual(attestation.acceptedRevisions, [4, 5, 6, 7, 8, 9, 12])
    }

    /// Finding 4: a group upload stuck on the network comes first in the
    /// outbox. The duel upload behind it still goes out.
    func testAStalledGroupUploadNeverHoldsUpADuelUpload() async throws {
        let harness = try Harness()
        _ = try await harness.store.allocateRevision(doublesID, atLeast: 3)
        _ = try await harness.outbox.enqueue(.scoreRevision(try groupRequest(revision: 4)), enqueuedAt: dayThreeNoon)
        let duelID = UUID()
        _ = try await harness.outbox.enqueue(
            .scoreRevision(try groupRequest(revision: 4, competitionID: duelID, semanticEventID: UUID())),
            enqueuedAt: dayThreeNoon
        )
        let stalled = Gate()
        let duelSent = expectation(description: "the duel upload goes out")
        duelSent.assertForOverFulfill = false
        let runtime = RemoteCompetitionRuntime(
            profileID: viewer,
            store: harness.events,
            remoteAPI: groupTestAPI(
                listGroupMatches: { throw CompetitionRemoteFailure.retryableTransport },
                competitionExists: { _ in true },
                appendScoreRevision: { request in
                    if request.competitionID == duelID {
                        duelSent.fulfill()
                    } else {
                        await stalled.wait()
                    }
                    return try CompetitionScoreRevisionResponse(
                        disposition: .rejected, rejectionCode: .revisionRegression, acceptedCentiPoints: nil,
                        wireContentSHA256: nil, acceptedServerSequence: nil, competitionCursor: 1
                    )
                }
            ),
            outboxStore: harness.outbox,
            groupMatchStore: harness.store,
            now: { self.dayThreeNoon }
        )
        let groups = Task { await runtime.synchronizeGroupMatches() }
        let duels = Task { await runtime.synchronizeAll() }
        await fulfillment(of: [duelSent], timeout: 10)
        await stalled.open()
        _ = await groups.value
        _ = await duels.value
        await runtime.stop()
    }

    /// Finding 4: the group list hangs. The duel publication still goes out,
    /// and the groups follow once the list answers.
    func testASlowGroupListNeverHoldsUpTheDuelPublication() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(id: viewer, displayName: "Player 1")
        let paths = AuthenticatedProfileStoragePaths(profileID: viewer, rootDirectory: root)
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let body = try listBody(fixtureMatches().filter { ($0["competition_id"] as? String) != doublesID.uuidString.lowercased() })
        let slow = Gate()
        let client = CompetitionClient.remote(
            remoteAPI: groupTestAPI(listGroupMatches: {
                await slow.wait()
                return body
            }),
            environment: try health(startDay: (2026, 11, 8), days: 3)
        )
        try await client.mountAuthenticatedProfile(profile, paths)
        let updates = client.updates()
        let published = expectation(description: "the duel publication goes out")
        let reconcile = Task {
            let publication = await client.reconcileAll(.pullToRefresh)
            published.fulfill()
            return publication
        }
        await fulfillment(of: [published], timeout: 10)
        await slow.open()
        let first = await reconcile.value
        XCTAssertTrue(first.dashboard.groupMatches.isEmpty)
        let later = await firstPublication(updates) { !$0.dashboard.groupMatches.isEmpty }
        XCTAssertEqual(Set(later?.dashboard.groupMatches.map(\.id.rawValue) ?? []), [finishedID, pendingID])
        await client.stop()
    }

    /// Finding 5: revision 4 was accepted and left the outbox, then a power
    /// cut lost the owner document's update. Offline, nothing is queued on
    /// the old high-water; online, the next revision is 5.
    func testALostOwnerWriteNeverReusesAnAcceptedRevision() async throws {
        let harness = try Harness()
        let server = try FakeGroupServer(fixture: fixture(), matchID: doublesID, viewer: viewer)
        let clock = TestClock(dayThreeNoon)
        _ = await harness.sync(
            api: server.api(), environment: try health(startDay: (2026, 11, 8), days: 1), now: { clock.now }
        ).run()
        let first = await server.acceptedRequests()
        XCTAssertEqual(first.map(\.clientRevision), [4, 5, 6])
        let cachedHighWater = await harness.store.readModel().first { $0.id == doublesID }?.ownerRevisionHighWater
        XCTAssertEqual(cachedHighWater, 3)
        // The power cut: the owner document's updates are gone.
        try FileManager.default.removeItem(at: harness.groupDirectory.appendingPathComponent(
            "owner-\(doublesID.uuidString.lowercased()).json"
        ))

        clock.now = dayThreeNoon.addingTimeInterval(60)
        let offline = harness.sync(
            api: groupTestAPI(
                listGroupMatches: { throw CompetitionRemoteFailure.retryableTransport },
                appendScoreRevision: { _ in throw CompetitionRemoteFailure.retryableTransport }
            ),
            environment: try health(startDay: (2026, 11, 8), days: 2), now: { clock.now }
        )
        _ = await offline.run()
        let queuedOffline = try await harness.outbox.entries()
        XCTAssertEqual(queuedOffline, [], "no revision is spent on a cached high-water")

        clock.now = dayThreeNoon.addingTimeInterval(120)
        _ = await harness.sync(
            api: server.api(), environment: try health(startDay: (2026, 11, 8), days: 2), now: { clock.now }
        ).run()
        let second = await server.acceptedRequests()
        XCTAssertEqual(second.map(\.clientRevision), [4, 5, 6, 7], "day 2 goes out as 7")
    }

    /// Re-review 1: through the production App Attest wrapper, a group's
    /// challenge request hangs while a duel upload waits on the key's gate.
    /// When the group request times out the duel goes out, and every
    /// challenge issued is used.
    func testADuelBehindAHeldGroupGoesOutWhenTheGroupRequestTimesOut() async throws {
        let setup = try await AppAttestSetup(test: self, holds: .group, groupHold: .timesOut(after: .seconds(1)))
        await fulfillment(of: [setup.held], timeout: 10)
        let duels = Task { await setup.runtime.synchronizeAll() }
        await fulfillment(of: [setup.duelSent], timeout: 10)
        _ = await duels.value
        await setup.runtime.stop()
        let challenges = await setup.server.counts()
        XCTAssertGreaterThanOrEqual(challenges.issued, 1)
        XCTAssertEqual(challenges.used, challenges.issued, "no challenge is left unused")
    }

    /// Re-review 1: stopping with the group holding the gate and the duel
    /// waiting, and the other way round, finishes; nothing cancelled issues
    /// a challenge it then abandons.
    func testStoppingFinishesWhicheverFamilyHoldsAppAttest() async throws {
        for holder in [AppAttestSetup.Family.group, .duel] {
            let setup = try await AppAttestSetup(test: self, holds: holder, groupHold: .forever)
            await fulfillment(of: [setup.held], timeout: 10)
            let other = Task {
                if holder == .group {
                    _ = await setup.runtime.synchronizeAll()
                } else {
                    _ = await setup.runtime.synchronizeGroupMatches()
                }
            }
            try await Task.sleep(for: .milliseconds(300))
            let stopped = expectation(description: "the runtime stops while \(holder) holds the gate")
            Task {
                await setup.runtime.stop()
                stopped.fulfill()
            }
            await fulfillment(of: [stopped], timeout: 10)
            _ = await other.value
            let challenges = await setup.server.counts()
            XCTAssertEqual(challenges.issued, 0, "a cancelled upload issues no challenge (\(holder) holds)")
            setup.duelSent.fulfill()
            await fulfillment(of: [setup.duelSent], timeout: 0)
        }
    }

    /// Re-review note 2: the server accepted revision 4 but the response was
    /// lost. After a relaunch the unchanged request goes again, the server
    /// answers duplicate with the original points, and the owner row returns.
    func testAnAcceptedUploadWhoseResponseWasLostIsRecoveredAfterARelaunch() async throws {
        let harness = try Harness()
        let server = try FakeGroupServer(fixture: fixture(), matchID: doublesID, viewer: viewer)
        await server.loseResponse(to: 4)
        let clock = TestClock(dayThreeNoon)
        _ = await harness.sync(
            api: server.api(), environment: try health(startDay: (2026, 11, 8), days: 1), now: { clock.now }
        ).run()
        let lost = try await harness.outbox.entries()
        // sync-02: revisions 5 and 6 wait behind the unanswered 4.
        XCTAssertEqual(lost.map(\.payload.competitionID), [doublesID, doublesID, doublesID], "revision 4 is still queued")

        let relaunched = try Harness(root: harness.root)
        clock.now = dayThreeNoon.addingTimeInterval(60)
        _ = await relaunched.sync(
            api: server.api(), environment: try health(startDay: (2026, 11, 8), days: 1), now: { clock.now }
        ).run()
        let accepted = await server.acceptedRequests()
        XCTAssertEqual(accepted.map(\.clientRevision), [4, 5, 6], "no new revision for a reading already accepted")
        let document = await relaunched.store.owner(doublesID)
        XCTAssertEqual(document?.accepted.map(\.clientRevision), [4, 5, 6])
        XCTAssertEqual(document?.accepted.first?.acceptedCentiPoints, 23_333)
        let outbox = try await relaunched.outbox.entries()
        XCTAssertEqual(outbox, [])
    }

    /// Non-blocking 7: the list still shows revision 10 for day 7 after this
    /// device saw 11 accepted. Nothing is attested over the stale heads, not
    /// even best-available after the deadline.
    func testHeadsOlderThanALocalReceiptAreNotAttested() async throws {
        let harness = try Harness()
        let server = try FakeGroupServer(
            fixture: fixture(), matchID: doublesID, viewer: viewer,
            startDay: "2026-11-03", deadline: "2026-11-10T00:00:00+00:00"
        )
        let clock = TestClock(dayThreeNoon.addingTimeInterval(-86_400))
        _ = await harness.sync(
            api: server.api(), environment: try health(startDay: (2026, 11, 3), days: 7), now: { clock.now }
        ).run()
        let document = await harness.store.owner(doublesID)
        let row = try XCTUnwrap(document?.accepted.last)
        _ = try await harness.store.rehydrate(doublesID, highWater: 11, rows: [
            try RemoteAcceptedScoreRow(
                ordinal: 7, acceptedCentiPoints: row.acceptedCentiPoints, availabilityReason: nil,
                wireContentSHA256: String(repeating: "a", count: 64), clientRevision: 11,
                serverSequence: 999, ringBasisPoints: row.ringBasisPoints
            ),
        ])
        clock.now = dayThreeNoon
        _ = await harness.sync(
            api: server.api(), environment: try health(startDay: (2026, 11, 3), days: 7, readFails: true),
            now: { clock.now }
        ).run()
        let sent = await server.attestations
        XCTAssertTrue(sent.isEmpty)
    }

    /// Non-blocking 8: rows whose fields don't hash to their digest, an
    /// unknown reason or mode, or a seat twice are rejected whole.
    func testRejectsRowsTheWireValidatorsRefuse() throws {
        func viewerDay(_ edit: @escaping (inout [String: Any]) -> Void) throws -> Data {
            try editedFixture(doublesID) { match in
                Self.editSeat(&match, 0) { seat in
                    var days = seat["days"] as! [[String: Any]]
                    edit(&days[0])
                    seat["days"] = days
                }
            }
        }
        XCTAssertNoThrow(try GroupMatchWire.decodeList(fixture(), viewer: viewer))
        for (name, body) in [
            ("unknown reason", try viewerDay { $0["availability_reason"] = "madeUpReason"; $0["accepted_centi_points"] = NSNull() }),
            ("unknown mode", try viewerDay { $0["move_mode"] = "bogus" }),
            ("ring outside its range", try viewerDay { $0["move_basis_points"] = 90_000 }),
            ("points the rings don't add up to", try viewerDay { $0["accepted_centi_points"] = 100 }),
            ("a digest of other content", try viewerDay { $0["wire_content_sha256"] = String(repeating: "0", count: 64) }),
            ("a seat twice", try editedFixture(doublesID) { match in
                var seats = match["seats"] as! [[String: Any]]
                seats[1]["id"] = seats[0]["id"]
                match["seats"] = seats
            }),
        ] {
            XCTAssertThrowsError(try GroupMatchWire.decodeList(body, viewer: viewer), name)
        }
    }

    // MARK: Helpers

    private struct Harness {
        let root: URL
        let groupDirectory: URL
        let store: GroupMatchStore
        let outbox: JSONCompetitionOutboxStore
        let events: JSONCompetitionEventStore
        let viewer = UUID(uuidString: "69e5d45f-d72b-2738-b230-1af2557f7b92")!

        /// A fresh directory, or `root` again as after a relaunch.
        init(root existing: URL? = nil) throws {
            root = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let noProtection = JSONCompetitionEventStoreFileProtection { _, _ in }
            for name in ["outbox", "events"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(name), withIntermediateDirectories: true
                )
            }
            groupDirectory = root.appendingPathComponent("GroupMatches", isDirectory: true)
            store = GroupMatchStore(directory: groupDirectory, profileID: viewer)
            outbox = JSONCompetitionOutboxStore(rootDirectory: root.appendingPathComponent("outbox"), fileProtection: noProtection)
            events = JSONCompetitionEventStore(
                rootDirectory: root.appendingPathComponent("events"), faultInjector: .none, fileProtection: noProtection
            )
        }

        func sync(
            api: CompetitionRemoteAPI,
            environment: CompetitionEnvironmentClient? = nil,
            now: @escaping @Sendable () -> Date
        ) -> RemoteGroupMatchSync {
            RemoteGroupMatchSync(
                profileID: viewer,
                store: store,
                remoteAPI: api,
                environment: environment,
                outboxStore: outbox,
                syncCoordinator: CompetitionSyncCoordinator(
                    profileID: viewer,
                    outboxStore: outbox,
                    remoteAPI: api,
                    acceptedScorePersistence: .routing(groups: store, duels: events),
                    now: now
                ),
                now: now
            )
        }
    }

    private func fixtureURL() -> URL {
        Bundle(for: Self.self).url(forResource: "group-matches-list", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/group-matches-list.json")
    }

    private func fixture() throws -> Data { try Data(contentsOf: fixtureURL()) }

    private func fixtureMatches() throws -> [[String: Any]] {
        let top = try JSONSerialization.jsonObject(with: fixture()) as! [String: Any]
        return top["matches"] as! [[String: Any]]
    }

    private func listBody(_ matches: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "matches": matches])
    }

    private func editedFixture(_ id: UUID, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        try listBody(fixtureMatches().map { match in
            var match = match
            if match["competition_id"] as? String == id.uuidString.lowercased() { edit(&match) }
            return match
        })
    }

    private static func editSeat(_ match: inout [String: Any], _ index: Int, _ edit: (inout [String: Any]) -> Void) {
        var seats = match["seats"] as! [[String: Any]]
        edit(&seats[index])
        match["seats"] = seats
    }

    private func groupRequest(
        revision: Int64, competitionID: UUID? = nil, semanticEventID: UUID? = nil
    ) throws -> CompetitionScoreRevisionRequest {
        let competitionID = competitionID ?? doublesID
        let wire = try RemoteScoreRevisionWireV1(
            competitionID: competitionID, participantID: viewer, dayOrdinal: 1,
            moveMode: "activeEnergyKilocalories", standMode: "standHours",
            moveBasisPoints: 10_000, exerciseBasisPoints: 5_000, standBasisPoints: 3_000,
            availabilityReason: "available", scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            clientRevision: revision
        )
        return try CompetitionScoreRevisionRequest(
            competitionID: competitionID,
            semanticEventID: semanticEventID
                ?? RemoteGroupMatchSync.semanticEventID(wireContentSHA256: wire.wireContentSHA256),
            dayOrdinal: 1, clientRevision: revision, evaluatedAt: dayThreeNoon,
            moveMode: wire.moveMode, standMode: wire.standMode,
            moveBasisPoints: wire.moveBasisPoints, exerciseBasisPoints: wire.exerciseBasisPoints,
            standBasisPoints: wire.standBasisPoints, availabilityReason: wire.availabilityReason,
            scoringPolicyIdentity: wire.scoringPolicyIdentity, wireContentSHA256: wire.wireContentSHA256
        )
    }

    /// Health with a reading on the first `days` days of a UTC week.
    private func health(
        startDay: (Int, Int, Int), days count: Int, readFails: Bool = false, lastDayMove: Double = 420
    ) throws -> CompetitionEnvironmentClient {
        .accelerated(fixture: try weekFixture(
            startDay: startDay, at: dayThreeNoon, days: count, readFails: readFails, lastDayMove: lastDayMove
        ))
    }

    private func weekDays(_ startDay: (Int, Int, Int)) throws -> [CompetitionDay] {
        try CompetitionCalendar(timeZoneIdentifier: "UTC").sevenDayWindow(startingOn: CompetitionDay(
            era: 1, year: startDay.0, month: startDay.1, day: startDay.2, timeZoneIdentifier: "UTC"
        ))
    }

    private func snapshot(move: Double) throws -> ActivitySnapshot {
        ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: move, goal: 600),
            exercise: try ActivityRingReading(value: 24, goal: 30),
            standOrRoll: try ActivityRingReading(value: 10, goal: 12),
            pauseState: .running
        )
    }

    private func weekFixture(
        startDay: (Int, Int, Int), at instant: Date, days count: Int = 7, readFails: Bool = false,
        lastDayMove: Double = 420, changes: [FixtureActivityChange] = []
    ) throws -> ActivityFixture {
        try ActivityFixture(
            initialInstant: EnvironmentInstant(
                wallDate: instant,
                monotonic: MonotonicInstant(epochID: "group-uploads", nanoseconds: 1)
            ),
            timeZoneIdentifier: "UTC",
            initialDays: try weekDays(startDay).enumerated().map { index, day in
                index < count
                    ? .snapshot(day: day, snapshot: try snapshot(move: index == 6 ? lastDayMove : 420))
                    : .missing(day: day)
            },
            initialReadState: readFails ? .failure(.healthDataUnavailable) : .available,
            changes: changes
        )
    }

    /// The first publication matching `predicate`, or nil after 10 seconds.
    private func firstPublication(
        _ updates: AsyncStream<CompetitionPublication>,
        where predicate: @escaping @Sendable (CompetitionPublication) -> Bool
    ) async -> CompetitionPublication? {
        await withTaskGroup(of: CompetitionPublication?.self) { group in
            group.addTask {
                for await publication in updates where predicate(publication) { return publication }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func XCTUnwrapAsync<Value>(_ value: Value?, file: StaticString = #filePath, line: UInt = #line) async throws -> Value {
        try XCTUnwrap(value, file: file, line: line)
    }
}

fileprivate func groupTestAPI(
    listGroupMatches: @escaping @Sendable () async throws -> Data,
    competitionExists: @escaping @Sendable (UUID) async throws -> Bool = { _ in
        throw CompetitionRemoteFailure.operationFailed
    },
    appendScoreRevision: @escaping @Sendable (CompetitionScoreRevisionRequest) async throws
        -> CompetitionScoreRevisionResponse = { _ in throw CompetitionRemoteFailure.operationFailed },
    submitAttestation: @escaping @Sendable (CompetitionAttestationRequest) async throws
        -> CompetitionAttestationReceipt = { _ in throw CompetitionRemoteFailure.operationFailed }
) -> CompetitionRemoteAPI {
    var api = CompetitionRemoteAPI(
        bootstrapProfile: { _ in throw CompetitionRemoteFailure.operationFailed },
        updateProfile: { _ in throw CompetitionRemoteFailure.operationFailed },
        listCompetitions: { [] },
        fetchCompetition: { _ in throw CompetitionRemoteFailure.operationFailed },
        competitionExists: competitionExists,
        createInvite: { _ in throw CompetitionRemoteFailure.operationFailed },
        claimInvite: { _ in throw CompetitionRemoteFailure.operationFailed },
        appendScoreRevision: appendScoreRevision,
        submitAttestation: submitAttestation,
        fetchChanges: { _, _ in throw CompetitionRemoteFailure.operationFailed },
        registerInstallation: { _ in throw CompetitionRemoteFailure.operationFailed },
        removeInstallation: { _ in throw CompetitionRemoteFailure.operationFailed },
        requestAccountDeletion: { throw CompetitionRemoteFailure.operationFailed }
    )
    api.listGroupMatches = listGroupMatches
    return api
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return date }
        set { lock.lock(); defer { lock.unlock() }; date = newValue }
    }
}

/// Holds callers until opened.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor PresenceProbe {
    var ids: [UUID] = []
    func record(_ id: UUID) { ids.append(id) }
}

/// The group RPCs for one match, holding the viewer's accepted rows the
/// way `group_match_projection` returns them.
private actor FakeGroupServer {
    private var match: [String: Any]
    private var rows: [[String: Any]]
    private var highWater: Int64
    private var sequence: Int64 = 100
    private var attestation: [String: Any]?
    private var failsAppends = false
    private var rejectedAttestations = 0
    private var failingRevisions: Set<Int64> = []
    private var firstAppend: (@Sendable () async -> Void)?
    private var acceptedDigests: [Int64: (digest: String, sequence: Int64, points: Int?)] = [:]
    private var lostResponses: Set<Int64> = []
    private let viewer: UUID
    private(set) var log: [String] = []
    private(set) var attempts: [CompetitionScoreRevisionRequest] = []
    private(set) var accepted: [CompetitionScoreRevisionRequest] = []
    private(set) var attestations: [CompetitionAttestationRequest] = []

    init(fixture: Data, matchID: UUID, viewer: UUID, startDay: String? = nil, deadline: String? = nil) throws {
        let top = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
        var match = (top["matches"] as! [[String: Any]]).first {
            $0["competition_id"] as? String == matchID.uuidString.lowercased()
        }!
        if let startDay { match["start_day"] = startDay }
        if let deadline { match["best_available_deadline"] = deadline }
        let seats = match["seats"] as! [[String: Any]]
        self.rows = seats.first { $0["profile_id"] as? String == viewer.uuidString.lowercased() }!["days"] as! [[String: Any]]
        self.highWater = Int64((match["owner"] as! [String: Any])["revision_high_water"] as! String)!
        self.match = match
        self.viewer = viewer
    }

    nonisolated func api() -> CompetitionRemoteAPI {
        groupTestAPI(
            listGroupMatches: { await self.list() },
            appendScoreRevision: { try await self.append($0) },
            submitAttestation: { try await self.attest($0) }
        )
    }

    func setFailingAppends(_ value: Bool) { failsAppends = value }
    /// The next `count` attestations are refused with a 401.
    func rejectAttestations(_ count: Int) { rejectedAttestations = count }
    /// Another device's upload moved the participant's high-water.
    func setHighWater(_ value: Int64) { highWater = value }
    func setFailingRevisions(_ value: Set<Int64>) { failingRevisions = value }
    /// The server accepts this revision but the response never arrives.
    func loseResponse(to revision: Int64) { lostResponses.insert(revision) }
    func onFirstAppend(_ action: @escaping @Sendable () async -> Void) { firstAppend = action }
    func clearLog() { log = [] }
    func attemptedRequests() -> [CompetitionScoreRevisionRequest] { attempts }
    func acceptedRequests() -> [CompetitionScoreRevisionRequest] { accepted }

    private func list() -> Data {
        log.append("list")
        var match = match
        var seats = match["seats"] as! [[String: Any]]
        let index = seats.firstIndex { $0["profile_id"] as? String == viewer.uuidString.lowercased() }!
        let latest = Dictionary(grouping: rows) { $0["day_ordinal"] as! Int }.values.map { day in
            day.max { Int64($0["client_revision"] as! String)! < Int64($1["client_revision"] as! String)! }!
        }
        seats[index]["days"] = latest.sorted { ($0["day_ordinal"] as! Int) < ($1["day_ordinal"] as! Int) }
        match["seats"] = seats
        match["server_version"] = String(sequence)
        match["owner"] = [
            "profile_id": viewer.uuidString.lowercased(),
            "revision_high_water": String(highWater),
            "attestation": attestation ?? NSNull(),
        ] as [String: Any]
        return try! JSONSerialization.data(withJSONObject: ["version": 1, "matches": [match]])
    }

    private func append(_ request: CompetitionScoreRevisionRequest) async throws -> CompetitionScoreRevisionResponse {
        if let action = firstAppend {
            firstAppend = nil
            await action()
        }
        log.append("append")
        attempts.append(request)
        if failsAppends || failingRevisions.contains(request.clientRevision) {
            throw CompetitionRemoteFailure.retryableTransport
        }
        // The SQL's rules: an exact retry is a duplicate, anything else at or
        // below the high-water is refused.
        if let prior = acceptedDigests[request.clientRevision] {
            guard prior.digest == request.wireContentSHA256 else {
                return try .rejected(.divergentDuplicate, cursor: sequence)
            }
            return try CompetitionScoreRevisionResponse(
                disposition: .duplicate, rejectionCode: nil, acceptedCentiPoints: prior.points,
                wireContentSHA256: prior.digest, acceptedServerSequence: prior.sequence, competitionCursor: sequence
            )
        }
        guard request.clientRevision > highWater else { return try .rejected(.revisionRegression, cursor: sequence) }
        accepted.append(request)
        sequence += 1
        let points = request.availabilityReason == "available"
            ? min((request.moveBasisPoints ?? 0) + (request.exerciseBasisPoints ?? 0) + (request.standBasisPoints ?? 0), 60_000)
            : nil
        let stamp = "2026-11-10T00:00:00+00:00"
        rows.append([
            "id": UUID().uuidString.lowercased(),
            "competition_id": request.competitionID.uuidString.lowercased(),
            "participant_profile_id": viewer.uuidString.lowercased(),
            "day_ordinal": request.dayOrdinal,
            "semantic_event_id": request.semanticEventID.uuidString.lowercased(),
            "client_revision": String(request.clientRevision),
            "move_mode": request.moveMode,
            "stand_mode": request.standMode,
            "move_basis_points": request.moveBasisPoints ?? NSNull(),
            "exercise_basis_points": request.exerciseBasisPoints ?? NSNull(),
            "stand_basis_points": request.standBasisPoints ?? NSNull(),
            "accepted_centi_points": points ?? NSNull(),
            "availability_reason": request.availabilityReason,
            "scoring_policy_identity": request.scoringPolicyIdentity,
            "wire_digest_version": 1,
            "wire_content_sha256": request.wireContentSHA256,
            "server_seq": String(sequence),
            "evaluated_at": stamp,
            "received_at": stamp,
        ])
        highWater = max(highWater, request.clientRevision)
        acceptedDigests[request.clientRevision] = (request.wireContentSHA256, sequence, points)
        if lostResponses.remove(request.clientRevision) != nil { throw CompetitionRemoteFailure.retryableTransport }
        return try CompetitionScoreRevisionResponse(
            disposition: .appended, rejectionCode: nil, acceptedCentiPoints: points,
            wireContentSHA256: request.wireContentSHA256, acceptedServerSequence: sequence, competitionCursor: sequence
        )
    }

    private func attest(_ request: CompetitionAttestationRequest) throws -> CompetitionAttestationReceipt {
        log.append("attest")
        if rejectedAttestations > 0 {
            rejectedAttestations -= 1
            throw CompetitionRemoteFailure.unauthenticated
        }
        attestations.append(request)
        sequence += 1
        attestation = [
            "id": UUID().uuidString.lowercased(),
            "competition_id": request.competitionID.uuidString.lowercased(),
            "participant_profile_id": viewer.uuidString.lowercased(),
            "basis": request.basis.rawValue,
            "window_commitment_sha256": request.windowCommitmentSHA256,
            "accepted_revisions": request.acceptedRevisions.map(String.init),
            "server_seq": String(sequence),
            "attested_at": "2026-11-10T00:00:00+00:00",
            "semantic_event_id": request.semanticEventID.uuidString.lowercased(),
            "attestation_version": String(request.attestationVersion),
        ]
        return try CompetitionAttestationReceipt(
            disposition: .appended, windowCommitmentSHA256: request.windowCommitmentSHA256, entityServerSequence: sequence
        )
    }
}

private extension CompetitionScoreRevisionResponse {
    static func rejected(_ code: CompetitionScoreRevisionRejectionCode, cursor: Int64) throws -> Self {
        try Self(
            disposition: .rejected, rejectionCode: code, acceptedCentiPoints: nil,
            wireContentSHA256: nil, acceptedServerSequence: nil, competitionCursor: cursor
        )
    }
}

/// A runtime behind the production App Attest wrapper, with a group upload
/// and a duel upload queued. The holder's challenge request hangs the way a
/// stuck URLSession request does: until it times out or is cancelled.
private struct AppAttestSetup {
    enum Family: String { case group, duel }
    enum Hold { case forever, timesOut(after: Duration) }

    let harness: RemoteGroupMatchClientTestsHarnessBox
    let runtime: RemoteCompetitionRuntime
    let server: ChallengeServer
    let held: XCTestExpectation
    let duelSent: XCTestExpectation

    init(test: XCTestCase, holds holder: Family, groupHold: Hold) async throws {
        let box = try RemoteGroupMatchClientTestsHarnessBox()
        let viewer = box.viewer
        let groupID = UUID(uuidString: "3656997c-2f73-47b5-ba2c-8288f5a7ecfe")!
        let duelID = UUID()
        _ = try await box.store.allocateRevision(groupID, atLeast: 3)
        _ = try await box.outbox.enqueue(
            .scoreRevision(try appAttestTestRequest(competitionID: groupID, viewer: viewer, group: true)),
            enqueuedAt: Date()
        )
        _ = try await box.outbox.enqueue(
            .scoreRevision(try appAttestTestRequest(competitionID: duelID, viewer: viewer, group: false)),
            enqueuedAt: Date()
        )
        let held = test.expectation(description: "the \(holder) request holds the gate")
        held.assertForOverFulfill = false
        let duelSent = test.expectation(description: "the duel upload goes out")
        duelSent.assertForOverFulfill = false
        let server = ChallengeServer()
        var raw = groupTestAPI(
            listGroupMatches: { throw CompetitionRemoteFailure.retryableTransport },
            competitionExists: { _ in true }
        )
        raw.issueAppAttestChallenge = { request in
            // The production send refuses a cancelled task before sending.
            guard !Task.isCancelled else { throw CompetitionRemoteFailure.cancelled }
            let isHolder = await server.isFirstChallenge()
            if isHolder {
                held.fulfill()
                let limit: Duration? = switch (holder, groupHold) {
                case (.group, let .timesOut(after: limit)): limit
                default: nil
                }
                let start = ContinuousClock.now
                do {
                    while limit.map({ ContinuousClock.now - start < $0 }) ?? true {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                } catch {
                    throw CompetitionRemoteFailure.cancelled
                }
                throw CompetitionRemoteFailure.retryableTransport
            }
            return try await server.issue(request)
        }
        raw.submitAttestedScoreRevision = { envelope in
            await server.submitted(envelope)
            if envelope.score.competitionID == duelID { duelSent.fulfill() }
            return try CompetitionScoreRevisionResponse(
                disposition: .rejected, rejectionCode: .revisionRegression, acceptedCentiPoints: nil,
                wireContentSHA256: nil, acceptedServerSequence: nil, competitionCursor: 1
            )
        }
        let paths = AuthenticatedProfileStoragePaths(profileID: viewer, rootDirectory: box.root.appendingPathComponent("profile"))
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let api = try await ProfileScopedAppAttestRemoteAPI.make(
            profileID: viewer,
            paths: paths,
            installationStore: CompetitionInstallationStateStore(directory: paths.installationsDirectory),
            remoteAPI: raw,
            service: GroupAppAttestService()
        )
        runtime = RemoteCompetitionRuntime(
            profileID: viewer, store: box.events, remoteAPI: api,
            outboxStore: box.outbox, groupMatchStore: box.store
        )
        harness = box
        self.server = server
        self.held = held
        self.duelSent = duelSent
        // The holder's drain takes the gate first.
        if holder == .group {
            _ = await runtime.synchronizeGroupMatches()
        } else {
            let runtime = runtime
            Task { _ = await runtime.synchronizeAll() }
        }
    }
}

/// Challenges the fake server issued, and which of them a proof used.
private actor ChallengeServer {
    private var requests = 0
    private var issuedIDs: Set<UUID> = []
    private var submittedIDs: Set<UUID> = []

    func isFirstChallenge() -> Bool {
        requests += 1
        return requests == 1
    }

    func issue(_ request: CompetitionAppAttestChallengeRequest) throws -> CompetitionAppAttestChallenge {
        let id = UUID()
        issuedIDs.insert(id)
        return try CompetitionAppAttestChallenge(
            challengeID: id, challenge: Data(repeating: UInt8(issuedIDs.count % 255), count: 32),
            expiresAt: Date().addingTimeInterval(300), proofKind: issuedIDs.count == 1 ? .attestation : .assertion
        )
    }

    func submitted(_ envelope: CompetitionAttestedScoreRevisionRequest) {
        submittedIDs.insert(envelope.appAttest.challengeID)
    }

    /// Challenges issued, and how many of them a submission used.
    func counts() -> (issued: Int, used: Int) {
        (issuedIDs.count, issuedIDs.intersection(submittedIDs).count)
    }
}

/// The stores the App Attest tests share (the test class's Harness is private to it).
private struct RemoteGroupMatchClientTestsHarnessBox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let viewer = UUID(uuidString: "69e5d45f-d72b-2738-b230-1af2557f7b92")!
    let store: GroupMatchStore
    let outbox: JSONCompetitionOutboxStore
    let events: JSONCompetitionEventStore

    init() throws {
        let noProtection = JSONCompetitionEventStoreFileProtection { _, _ in }
        for name in ["outbox", "events"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        store = GroupMatchStore(directory: root.appendingPathComponent("GroupMatches"), profileID: viewer)
        outbox = JSONCompetitionOutboxStore(rootDirectory: root.appendingPathComponent("outbox"), fileProtection: noProtection)
        events = JSONCompetitionEventStore(
            rootDirectory: root.appendingPathComponent("events"), faultInjector: .none, fileProtection: noProtection
        )
    }
}

private func appAttestTestRequest(
    competitionID: UUID, viewer: UUID, group: Bool
) throws -> CompetitionScoreRevisionRequest {
    let wire = try RemoteScoreRevisionWireV1(
        competitionID: competitionID, participantID: viewer, dayOrdinal: 1,
        moveMode: "activeEnergyKilocalories", standMode: "standHours",
        moveBasisPoints: 10_000, exerciseBasisPoints: 5_000, standBasisPoints: 3_000,
        availabilityReason: "available", scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
        clientRevision: 4
    )
    return try CompetitionScoreRevisionRequest(
        competitionID: competitionID,
        semanticEventID: group ? RemoteGroupMatchSync.semanticEventID(wireContentSHA256: wire.wireContentSHA256) : UUID(),
        dayOrdinal: 1, clientRevision: 4, evaluatedAt: Date(),
        moveMode: wire.moveMode, standMode: wire.standMode,
        moveBasisPoints: wire.moveBasisPoints, exerciseBasisPoints: wire.exerciseBasisPoints,
        standBasisPoints: wire.standBasisPoints, availabilityReason: wire.availabilityReason,
        scoringPolicyIdentity: wire.scoringPolicyIdentity, wireContentSHA256: wire.wireContentSHA256
    )
}

private actor GroupAppAttestService: AppAttestServiceProtocol {
    func isSupported() -> Bool { true }
    func generateKey() -> String { Data(repeating: 0x52, count: 32).base64EncodedString() }
    func attestKey(_ keyID: String, clientDataHash: Data) -> Data { Data("attestation".utf8) }
    func generateAssertion(_ keyID: String, clientDataHash: Data) -> Data { Data("assertion".utf8) }
}

// MARK: - Commands (I3)

extension RemoteGroupMatchClientTests {
    private static let sam = UUID(uuidString: "4000ca96-a5d0-db44-3b89-bbfb6bc44e19")!
    private static let leo = UUID(uuidString: "758901eb-c557-7975-e585-97488b2a907e")!

    func testCommandsSendTheSQLParametersAndAcceptOnlyTheExactAnswers() async throws {
        let id = pendingID
        let key = UUID(uuidString: "84000000-0000-4000-8000-000000000001")!
        let draft = GroupMatchDraft(format: .doubles, seats: [
            .person(profileID: Self.sam, team: 1), .person(profileID: Self.leo, team: 2), .bot(.beast, team: 2),
        ])
        let echo: [String: Any] = ["competition_id": id.uuidString.lowercased()]
        // As `participant_projection_v2` builds it: day 1 points, day 2 an
        // accepted unavailable day, the rest never sent.
        let digest = String(repeating: "ab", count: 32)
        let bankDays: [[String: Any]] = (1...7).map { ordinal in
            var day: [String: Any] = [
                "ordinal": ordinal, "status": "unavailable", "source": "deadline_missing", "reason": "missing",
                "centi_points": NSNull(), "wire_content_sha256": NSNull(), "client_revision": NSNull(),
                "server_seq": NSNull(), "scoring_policy_identity": NSNull(),
            ]
            if ordinal <= 2 {
                day.merge([
                    "source": "accepted_revision", "wire_content_sha256": digest, "client_revision": ordinal == 1 ? "1" : "3",
                    "server_seq": "\(ordinal + 6)", "scoring_policy_identity": "healthcomp.activity-score.v1",
                ]) { $1 }
            }
            if ordinal == 1 { day.merge(["status": "points", "reason": NSNull(), "centi_points": 25_000]) { $1 } }
            if ordinal == 2 { day["reason"] = "healthDataUnavailable" }
            return day
        }
        let bank: [String: Any] = [
            "profile_id": viewer.uuidString.lowercased(), "total_centi_points": 25_000,
            "window_commitment_sha256": digest, "days": bankDays,
        ]
        let leave: [String: Any] = [
            "left_at": "2026-11-10T12:00:00+00:00", "frozen_through_day": 3,
            "accepted_revisions": ["1", "3", "0", "0", "0", "0", "0"], "bank": bank,
        ]
        let react: [String: Any] = ["competition_id": id.uuidString.lowercased(), "day_ordinal": 2, "reaction": "fire"]
        let transport = StubTransport([
            .success(echo), .success(echo.merging(["state": "scheduled"]) { $1 }), .success(echo), .success(echo),
            .success(leave), .success(["nudged_at": "2026-11-10T12:00:00.5+00:00"]), .success(react),
        ])
        let api = SupabaseCompetitionRemoteAPI.make(transport: transport.transport)
        let commands: [GroupMatchRemoteCommand] = [
            .create(creator: viewer, draft, timeZoneIdentifier: "America/Los_Angeles", idempotencyKey: key),
            .accept(id), .decline(id), .cancel(id), .leave(id),
            .nudge(id, recipient: Self.sam), .react(id, target: Self.leo, ordinal: 2, .fire),
        ]
        for command in commands {
            let answered = try await api.sendGroupMatchCommand(command)
            XCTAssertEqual(answered, id)
        }
        let sent = await transport.sent
        func wire(_ value: UUID) -> String { value.uuidString.lowercased() }
        XCTAssertEqual(sent.map(\.name), [
            "create_group_match", "accept_group_match", "decline_group_match", "cancel_group_match",
            "leave_group_match", "nudge_competition_participant", "set_competition_reaction",
        ])
        XCTAssertEqual(sent[0].body as NSDictionary, [
            "format": "doubles", "time_zone_identifier": "America/Los_Angeles", "creation_idempotency_key": wire(key),
            "seats": [
                ["kind": "human", "profile_id": wire(viewer), "team_number": 1],
                ["kind": "human", "profile_id": wire(Self.sam), "team_number": 1],
                ["kind": "human", "profile_id": wire(Self.leo), "team_number": 2],
                ["kind": "bot", "bot_mode": "beast", "team_number": 2],
            ],
        ] as NSDictionary)
        XCTAssertEqual(sent[1].body as NSDictionary, ["competition_id": wire(pendingID)] as NSDictionary)
        XCTAssertEqual(sent[5].body as NSDictionary, ["competition_id": wire(pendingID), "recipient_profile_id": wire(Self.sam)] as NSDictionary)
        XCTAssertEqual(sent[6].body as NSDictionary, [
            "competition_id": wire(pendingID), "day_ordinal": 2, "reaction": "fire", "target_profile_id": wire(Self.leo),
        ] as NSDictionary)

        // Free-for-all seats carry no team_number key at all.
        let ffa = try GroupMatchRemoteCommand.create(
            creator: viewer, GroupMatchDraft(format: .threeWay, seats: [.person(profileID: Self.sam, team: nil), .bot(.chill, team: nil)]),
            timeZoneIdentifier: "UTC", idempotencyKey: key
        ).rpc()
        XCTAssertEqual(ffa.parameters["format"] as? String, "three_way")
        XCTAssertEqual((ffa.parameters["seats"] as? [[String: Any]])?.map { Set($0.keys) }, [
            ["kind", "profile_id"], ["kind", "profile_id"], ["kind", "bot_mode"],
        ])
        // A pasted challenge link names the person by its code; the server resolves it.
        let linked = try GroupMatchRemoteCommand.create(
            creator: viewer,
            GroupMatchDraft(format: .threeWay, seats: [
                .challengeLink(try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Mx7kQ2pL9vR4tN8wB3cY6z")), team: nil),
                .bot(.chill, team: nil),
            ]),
            timeZoneIdentifier: "UTC", idempotencyKey: key
        ).rpc()
        XCTAssertEqual((linked.parameters["seats"] as? [[String: Any]])?[1] as NSDictionary?, [
            "kind": "human", "challenge_link_code": "Mx7kQ2pL9vR4tN8wB3cY6z",
        ] as NSDictionary)
        XCTAssertThrowsError(try GroupMatchRemoteCommand.create(
            creator: viewer, GroupMatchDraft(format: .fourWay, seats: [.person(profileID: Self.sam, team: nil)]),
            timeZoneIdentifier: "UTC", idempotencyKey: key
        ).rpc(), "a seat count the format can't hold")

        // Anything but the exact answer is a contract mismatch.
        let wrong: [(GroupMatchRemoteCommand, [String: Any])] = [
            (.accept(id), echo.merging(["state": "active"]) { $1 }),
            (.decline(id), ["competition_id": wire(UUID())]),
            (.cancel(id), echo.merging(["extra": 1]) { $1 }),
            (.leave(id), leave.merging(["accepted_revisions": ["1"]]) { $1 }),
            (.leave(id), leave.merging(["frozen_through_day": 8]) { $1 }),
            (.leave(id), leave.merging(["frozen_through_day": true]) { $1 }),
            (.leave(id), leave.merging(["accepted_revisions": Array(repeating: "9999999999999999999", count: 7)]) { $1 }),
            (.leave(id), leave.merging(["bank": [String: Any]()]) { $1 }),
            (.leave(id), leave.merging(["bank": bank.merging(["total_centi_points": 25_001]) { $1 }]) { $1 }),
            (.leave(id), leave.merging(["accepted_revisions": ["2", "3", "0", "0", "0", "0", "0"]]) { $1 }),
            (.nudge(id, recipient: Self.sam), ["nudged_at": "yesterday"]),
            (.react(id, target: Self.leo, ordinal: 2, nil), react),
        ]
        for (command, body) in wrong {
            let failure = await failure(of: command, answering: .success(body))
            XCTAssertEqual(failure, .serverContractMismatch, "\(command)")
        }
        // A lapsed invite answers 200 with state expired before cleanup.
        let expired = await failure(of: .accept(id), answering: .success(echo.merging(["state": "expired"]) { $1 }))
        XCTAssertEqual(expired, .inviteUnavailable)
    }

    func testGroupErrorsMapToTheReasonsTheScreensShow() async throws {
        let cases: [(String, String?, CompetitionRemoteFailure, GroupMatchFailure?)] = [
            ("recipient_unavailable", nil, .recipientUnavailable, .recipientUnavailable),
            ("group_update_required", Self.leo.uuidString.lowercased(), .groupUpdateRequired(profileID: Self.leo), .updateRequired(profileID: Self.leo)),
            ("group_update_required", "not-a-uuid", .groupUpdateRequired(profileID: nil), .updateRequired(profileID: nil)),
            ("group_creation_limit", nil, .groupCreationLimit, .creationLimit),
            ("group_match_unavailable", nil, .inviteUnavailable, .closed),
            ("withdraw_not_allowed", nil, .forbidden, nil),
            ("leave_not_allowed", nil, .forbidden, nil),
            ("invalid_group_seat", nil, .serverContractMismatch, nil),
            ("idempotency_conflict", nil, .divergentDuplicate, nil),
        ]
        for (message, detail, expected, reason) in cases {
            let failure = await failure(
                of: .accept(pendingID),
                answering: .failure(.server(statusCode: nil, code: "P0001", message: message, detail: detail))
            )
            XCTAssertEqual(failure, expected, message)
            XCTAssertEqual(failure.flatMap { GroupMatchFailure($0) }, reason, message)
        }
        // A pasted link has no local profile ID; both transports keep the name in the hint.
        let hint = "Sam needs to update HealthComp first."
        let body = try JSONSerialization.data(withJSONObject: [
            "code": "P0001", "message": "group_update_required", "details": Self.sam.uuidString.lowercased(),
            "hint": hint,
        ])
        let code = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Mx7kQ2pL9vR4tN8wB3cY6z"))
        let draft = GroupMatchDraft(format: .threeWay, seats: [.challengeLink(code, team: nil), .bot(.pacer, team: nil)])
        let create = GroupMatchRemoteCommand.create(creator: viewer, draft, timeZoneIdentifier: "UTC", idempotencyKey: UUID())
        for reply in [StubTransport.Answer.response(400, body), .failure(.server(
            statusCode: nil, code: "P0001", message: "group_update_required", detail: Self.sam.uuidString.lowercased(), hint: hint
        ))] {
            let result = await failure(of: create, answering: reply)
            let error = try XCTUnwrap(result)
            XCTAssertEqual(error, .groupUpdateRequired(profileID: Self.sam, displayName: "Sam"))
            var state = GroupMatchFeature.State()
            let command = GroupMatchCommand.create(draft)
            state.failed.insert(command)
            state.failureReasons[command] = GroupMatchFailure(error)
            XCTAssertEqual(state.failureLine([command], otherwise: "Couldn’t create match"), hint)
        }
        XCTAssertNil(GroupMatchFailure(CompetitionRemoteFailure.retryableTransport), "offline keeps the generic line")
        XCTAssertEqual(GroupMatchFailure.updateRequired(profileID: Self.leo).message(name: "Leo"), "Leo needs to update HealthComp first.")
    }

    func testLiveBuildsRegisterForGroupPushesAndFallBackOnOlderServers() async throws {
        let installationID = UUID(uuidString: "84000000-0000-4000-8000-0000000000c1")!
        let active = try JSONSerialization.data(withJSONObject: [
            "installation_id": installationID.uuidString.lowercased(), "environment": "sandbox", "state": "active",
        ])
        let notFound = try JSONSerialization.data(withJSONObject: ["code": "PGRST202", "message": "redacted"])
        let transport = StubTransport([.response(200, active), .response(404, notFound), .response(200, active)])
        let api = SupabaseCompetitionRemoteAPI.make(transport: transport.transport, supportsGroupMatches: true)
        let request = try CompetitionInstallationRequest(
            installationID: installationID, apnsToken: String(repeating: "a1", count: 32), environment: .sandbox
        )
        _ = try await api.registerInstallation(request)
        _ = try await api.registerInstallation(request)
        let sent = await transport.sent
        XCTAssertEqual(sent.count, 3)
        let current: [String: Any] = [
            "installation_id": installationID.uuidString.lowercased(), "apns_token": String(repeating: "a1", count: 32),
            "environment": "sandbox", "supports_challenges": true, "supports_reactions": true,
            "supports_friends": true, "muted_push_kinds": [String](),
        ]
        XCTAssertEqual(sent[0].body as NSDictionary, current.merging(["supports_group_matches": true]) { $1 } as NSDictionary)
        XCTAssertEqual(sent[1].body as NSDictionary, sent[0].body as NSDictionary)
        XCTAssertEqual(sent[2].body as NSDictionary, current as NSDictionary, "a server without the group overload")

        // Gate off: never advertised.
        let off = StubTransport([.response(200, active)])
        _ = try await SupabaseCompetitionRemoteAPI.make(transport: off.transport, supportsGroupMatches: false)
            .registerInstallation(request)
        let offSent = await off.sent
        XCTAssertEqual(offSent.map { $0.body as NSDictionary }, [current as NSDictionary])
    }

    func testARetriedCreateReusesItsKeyAndEverySuccessRefreshesTheList() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(id: viewer, displayName: "Player 1")
        let paths = AuthenticatedProfileStoragePaths(profileID: viewer, rootDirectory: root)
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let all = try fixtureMatches()
        let finishedOnly = try listBody(all.filter { $0["competition_id"] as? String == finishedID.uuidString.lowercased() })
        let withPending = try listBody(all.filter { $0["competition_id"] as? String != doublesID.uuidString.lowercased() })
        let server = FakeCommandServer(lists: [finishedOnly, withPending], failFirst: 1)
        var api = groupTestAPI(listGroupMatches: { await server.list() })
        api.sendGroupMatchCommand = { try await server.send($0) }
        let client = CompetitionClient.remote(remoteAPI: api, environment: try health(startDay: (2026, 11, 8), days: 3))
        try await client.mountAuthenticatedProfile(profile, paths)
        let updates = client.updates()
        _ = await client.reconcileAll(.pullToRefresh)
        _ = await firstPublication(updates) { !$0.dashboard.groupMatches.isEmpty }

        let draft = GroupMatchDraft(format: .threeWay, seats: [.person(profileID: Self.sam, team: nil), .bot(.pacer, team: nil)])
        do {
            _ = try await client.groupMatchCommand(.create(draft))
            XCTFail("the first try is offline")
        } catch {}
        let listsBefore = await server.listCount
        let published = try await client.groupMatchCommand(.create(draft))
        let listsAfter = await server.listCount
        XCTAssertGreaterThan(listsAfter, listsBefore, "a success refreshes the list")
        XCTAssertTrue(published.dashboard.groupMatches.contains { $0.id.rawValue == pendingID }, "and publishes it")
        _ = try await client.groupMatchCommand(.create(draft))

        let sent = await server.commands
        guard sent.count == 3,
              case let .create(_, _, zone0, key0) = sent[0], case let .create(creator, sentDraft, zone1, key1) = sent[1],
              case let .create(_, _, _, key2) = sent[2]
        else { return XCTFail("\(sent)") }
        XCTAssertEqual(key0, key1, "the retry sends the same idempotency key")
        XCTAssertEqual(zone0, zone1)
        XCTAssertNotEqual(key1, key2, "a new match after a success gets a new key")
        XCTAssertEqual(creator, viewer)
        XCTAssertEqual(sentDraft, draft)

        // Rematch never sends; it opens Create prefilled.
        do {
            _ = try await client.groupMatchCommand(.rematch(CompetitionID(finishedID)))
            XCTFail("rematch is not a server command")
        } catch {}
        let afterRematch = await server.commands.count
        XCTAssertEqual(afterRematch, 3)
        await client.stop()
    }

    func testNudgeAndReactionsAddressPeopleBySeat() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(id: viewer, displayName: "Player 1")
        let paths = AuthenticatedProfileStoragePaths(profileID: viewer, rootDirectory: root)
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let server = FakeCommandServer(lists: [try fixture()], failFirst: 0)
        var api = groupTestAPI(listGroupMatches: { await server.list() })
        api.sendGroupMatchCommand = { try await server.send($0) }
        let client = CompetitionClient.remote(remoteAPI: api, environment: try health(startDay: (2026, 11, 8), days: 3))
        try await client.mountAuthenticatedProfile(profile, paths)
        let updates = client.updates()
        _ = await client.reconcileAll(.pullToRefresh)
        let first = try await XCTUnwrapAsync(await firstPublication(updates) { !$0.dashboard.groupMatches.isEmpty })
        let doubles = try XCTUnwrap(first.dashboard.groupMatches.first { $0.id.rawValue == doublesID })
        let leoSeat = try XCTUnwrap(doubles.seats.first { $0.number == 3 })
        let botSeat = try XCTUnwrap(doubles.seats.first { $0.number == 4 })

        _ = try await client.groupMatchCommand(.nudge(doubles.id))
        _ = try await client.groupMatchCommand(.react(doubles.id, seatID: leoSeat.id, ordinal: 2, .clap))
        _ = try await client.groupMatchCommand(.withdraw(CompetitionID(pendingID)))
        do {
            _ = try await client.groupMatchCommand(.react(doubles.id, seatID: botSeat.id, ordinal: 2, .clap))
            XCTFail("a bot can't be reacted to")
        } catch {}
        let sent = await server.commands
        XCTAssertEqual(sent, [
            .nudge(doublesID, recipient: Self.sam),
            .react(doublesID, target: Self.leo, ordinal: 2, .clap),
            .decline(pendingID),
        ])
        await client.stop()
    }

    /// Leave sends this phone's days first and only then banks: the RPC waits
    /// for a held upload.
    func testLeaveWaitsForTheUploadPassBeforeBanking() async throws {
        let server = try FakeGroupServer(fixture: fixture(), matchID: doublesID, viewer: viewer)
        let order = OrderLog()
        let held = Gate()
        let uploading = expectation(description: "an upload is in flight")
        await server.onFirstAppend {
            uploading.fulfill()
            await held.wait()
        }
        let client = try await leaveClient(server: server, order: order, leave: { await order.add("leave") })
        let leaving = Task { try await client.groupMatchCommand(.leave(CompetitionID(doublesID))) }
        await fulfillment(of: [uploading], timeout: 10)
        try await Task.sleep(for: .milliseconds(200))
        let whileHeld = await order.entries
        XCTAssertFalse(whileHeld.contains("leave"), "no bank while an upload is still open")
        await held.open()
        _ = try await leaving.value
        let entries = await order.entries
        let leaveIndex = try XCTUnwrap(entries.firstIndex(of: "leave"))
        XCTAssertEqual(entries.filter { $0 == "leave" }.count, 1)
        XCTAssertTrue(entries[..<leaveIndex].contains("append"))
        await client.stop()
    }

    /// The uploads fail but the server answers: Leave goes ahead and banks
    /// what the server has (the confirmation said unsent points won't count).
    func testLeaveAfterAFailedUploadStillBanksOnline() async throws {
        let server = try FakeGroupServer(fixture: fixture(), matchID: doublesID, viewer: viewer)
        await server.setFailingAppends(true)
        let order = OrderLog()
        let client = try await leaveClient(server: server, order: order, leave: { await order.add("leave") })
        _ = try await client.groupMatchCommand(.leave(CompetitionID(doublesID)))
        let attempts = await server.attemptedRequests()
        XCTAssertFalse(attempts.isEmpty, "it tried to upload first")
        let accepted = await server.acceptedRequests()
        XCTAssertEqual(accepted, [])
        let entries = await order.entries
        let leaveIndex = try XCTUnwrap(entries.firstIndex(of: "leave"))
        XCTAssertTrue(entries[..<leaveIndex].contains("append"), "the failed upload came first")
        await client.stop()
    }

    /// Offline: Leave fails out loud and nothing is queued to bank later.
    func testLeaveOfflineFailsAndDoesNotQueue() async throws {
        let server = try FakeGroupServer(fixture: fixture(), matchID: doublesID, viewer: viewer)
        await server.setFailingAppends(true)
        let order = OrderLog()
        let client = try await leaveClient(server: server, order: order, listFails: true, leave: {
            await order.add("leave")
            throw CompetitionRemoteFailure.retryableTransport
        })
        do {
            _ = try await client.groupMatchCommand(.leave(CompetitionID(doublesID)))
            XCTFail("an offline leave must fail")
        } catch {
            XCTAssertEqual(error as? CompetitionRemoteFailure, .retryableTransport)
            XCTAssertNil(GroupMatchFailure(error), "the generic connection line")
        }
        _ = await client.reconcileAll(.pullToRefresh)
        let entries = await order.entries
        XCTAssertEqual(entries.filter { $0 == "leave" }.count, 1, "no retry or queued leave")
        await client.stop()
    }

    private func leaveClient(
        server: FakeGroupServer, order: OrderLog, listFails: Bool = false,
        leave: @escaping @Sendable () async throws -> Void
    ) async throws -> CompetitionClient {
        let root = try makeDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = AuthenticatedProfileStoragePaths(profileID: viewer, rootDirectory: root)
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var api = server.api()
        let list = api.listGroupMatches
        let append = api.appendScoreRevision
        api.listGroupMatches = {
            if listFails { throw CompetitionRemoteFailure.retryableTransport }
            return try await list()
        }
        api.appendScoreRevision = { request in
            await order.add("append")
            return try await append(request)
        }
        api.sendGroupMatchCommand = { command in
            guard case let .leave(id) = command else { throw CompetitionRemoteFailure.operationFailed }
            try await leave()
            return id
        }
        let client = CompetitionClient.remote(remoteAPI: api, environment: try health(startDay: (2026, 11, 8), days: 3))
        try await client.mountAuthenticatedProfile(AuthenticatedProfile(id: viewer, displayName: "Player 1"), paths)
        return client
    }

    private func failure(
        of command: GroupMatchRemoteCommand, answering answer: StubTransport.Answer
    ) async -> CompetitionRemoteFailure? {
        let transport = StubTransport([answer])
        do {
            _ = try await SupabaseCompetitionRemoteAPI.make(transport: transport.transport).sendGroupMatchCommand(command)
            return nil
        } catch {
            return error as? CompetitionRemoteFailure
        }
    }
}

/// Answers RPCs in order and records what was sent.
private actor StubTransport {
    enum Answer {
        case success([String: Any])
        case response(Int, Data)
        case failure(CompetitionRemoteTransportFailure)
    }

    private var answers: [Answer]
    private(set) var sent: [(name: String, body: [String: Any])] = []

    init(_ answers: [Answer]) { self.answers = answers }

    nonisolated var transport: CompetitionRemoteTransport {
        CompetitionRemoteTransport { try await self.answer($0) }
    }

    private func answer(_ request: CompetitionRemoteTransportRequest) throws -> CompetitionRemoteTransportResponse {
        guard case let .rpc(name, parameters) = request,
              let body = try JSONSerialization.jsonObject(with: parameters) as? [String: Any]
        else { throw CompetitionRemoteTransportFailure.other }
        sent.append((name, body))
        switch answers.removeFirst() {
        case let .success(object):
            return CompetitionRemoteTransportResponse(statusCode: 200, data: try JSONSerialization.data(withJSONObject: object))
        case let .response(status, data):
            return CompetitionRemoteTransportResponse(statusCode: status, data: data)
        case let .failure(failure):
            throw failure
        }
    }
}

/// `list_group_matches` bodies in turn (the last repeats once a command has
/// succeeded), and the group commands it was sent.
private actor FakeCommandServer {
    private let lists: [Data]
    private var failuresLeft: Int
    private var succeeded = 0
    private(set) var listCount = 0
    private(set) var commands: [GroupMatchRemoteCommand] = []

    init(lists: [Data], failFirst: Int) {
        self.lists = lists
        self.failuresLeft = failFirst
    }

    func list() -> Data {
        listCount += 1
        return lists[min(succeeded, lists.count - 1)]
    }

    func send(_ command: GroupMatchRemoteCommand) throws -> UUID {
        commands.append(command)
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw CompetitionRemoteFailure.retryableTransport
        }
        succeeded += 1
        switch command {
        case .create: return UUID(uuidString: "57bb50d9-30f0-4a8f-afc1-9978cf9c52e8")!
        case let .accept(id), let .decline(id), let .cancel(id), let .leave(id), let .nudge(id, _), let .react(id, _, _, _):
            return id
        }
    }
}

private actor OrderLog {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
}
