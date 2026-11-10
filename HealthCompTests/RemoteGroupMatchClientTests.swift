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
        XCTAssertTrue(refreshed.isFresh)
        XCTAssertEqual(refreshed.matches.first { $0.id == doublesID }?.lifecycle, "scheduled")

        let newer = try editedFixture(doublesID) { $0["server_version"] = "12" }
        sync = harness.sync(api: groupTestAPI(listGroupMatches: { newer }), now: { self.dayThreeNoon })
        refreshed = await sync.refresh()
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
        let failed = await server.attemptedRequests()
        XCTAssertEqual(failed.map(\.dayOrdinal), [1, 2, 3])
        XCTAssertEqual(failed.map(\.clientRevision), [4, 5, 6])
        XCTAssertTrue(failed.allSatisfy {
            $0.semanticEventID == RemoteGroupMatchSync.semanticEventID(wireContentSHA256: $0.wireContentSHA256)
        })

        await server.setFailingAppends(false)
        clock.now = dayThreeNoon.addingTimeInterval(5)
        _ = await sync.run()
        let accepted = await server.acceptedRequests()
        XCTAssertEqual(accepted, failed, "a retry sends the same request, evaluation time included")
        let document = try await XCTUnwrapAsync(await harness.store.owner(doublesID))
        XCTAssertEqual(document.allocatedRevision, 6)
        XCTAssertEqual(document.accepted.map(\.clientRevision), [4, 5, 6])
        let outbox = try await harness.outbox.entries()
        XCTAssertEqual(outbox, [])

        clock.now = dayThreeNoon.addingTimeInterval(60)
        _ = await sync.run()
        let afterUnchangedRead = await server.attemptedRequests()
        XCTAssertEqual(afterUnchangedRead.count, 6, "an unchanged reading is not sent again")
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
        let publication = await client.reconcileAll(.pullToRefresh)
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
        XCTAssertEqual(Set(offline.dashboard.groupMatches.map(\.id.rawValue)), [finishedID, pendingID])
        await relaunched.stop()
    }

    // MARK: Helpers

    private struct Harness {
        let root: URL
        let groupDirectory: URL
        let store: GroupMatchStore
        let outbox: JSONCompetitionOutboxStore
        let events: JSONCompetitionEventStore
        let viewer = UUID(uuidString: "69e5d45f-d72b-2738-b230-1af2557f7b92")!

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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

    private func groupRequest(revision: Int64) throws -> CompetitionScoreRevisionRequest {
        let wire = try RemoteScoreRevisionWireV1(
            competitionID: doublesID, participantID: viewer, dayOrdinal: 1,
            moveMode: "activeEnergyKilocalories", standMode: "standHours",
            moveBasisPoints: 10_000, exerciseBasisPoints: 5_000, standBasisPoints: 3_000,
            availabilityReason: "available", scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            clientRevision: revision
        )
        return try CompetitionScoreRevisionRequest(
            competitionID: doublesID,
            semanticEventID: RemoteGroupMatchSync.semanticEventID(wireContentSHA256: wire.wireContentSHA256),
            dayOrdinal: 1, clientRevision: revision, evaluatedAt: dayThreeNoon,
            moveMode: wire.moveMode, standMode: wire.standMode,
            moveBasisPoints: wire.moveBasisPoints, exerciseBasisPoints: wire.exerciseBasisPoints,
            standBasisPoints: wire.standBasisPoints, availabilityReason: wire.availabilityReason,
            scoringPolicyIdentity: wire.scoringPolicyIdentity, wireContentSHA256: wire.wireContentSHA256
        )
    }

    /// Health with a reading on the first `days` days of a UTC week.
    private func health(
        startDay: (Int, Int, Int), days count: Int, readFails: Bool = false
    ) throws -> CompetitionEnvironmentClient {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let start = try CompetitionDay(
            era: 1, year: startDay.0, month: startDay.1, day: startDay.2, timeZoneIdentifier: "UTC"
        )
        let days = try calendar.sevenDayWindow(startingOn: start)
        let snapshot = ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: 420, goal: 600),
            exercise: try ActivityRingReading(value: 24, goal: 30),
            standOrRoll: try ActivityRingReading(value: 10, goal: 12),
            pauseState: .running
        )
        return .accelerated(fixture: try ActivityFixture(
            initialInstant: EnvironmentInstant(
                wallDate: dayThreeNoon,
                monotonic: MonotonicInstant(epochID: "group-uploads", nanoseconds: 1)
            ),
            timeZoneIdentifier: "UTC",
            initialDays: days.enumerated().map { index, day in
                index < count ? .snapshot(day: day, snapshot: snapshot) : .missing(day: day)
            },
            initialReadState: readFails ? .failure(.healthDataUnavailable) : .available,
            changes: []
        ))
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

    private func append(_ request: CompetitionScoreRevisionRequest) throws -> CompetitionScoreRevisionResponse {
        log.append("append")
        attempts.append(request)
        if failsAppends { throw CompetitionRemoteFailure.retryableTransport }
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
        return try CompetitionScoreRevisionResponse(
            disposition: .appended, rejectionCode: nil, acceptedCentiPoints: points,
            wireContentSHA256: request.wireContentSHA256, acceptedServerSequence: sequence, competitionCursor: sequence
        )
    }

    private func attest(_ request: CompetitionAttestationRequest) throws -> CompetitionAttestationReceipt {
        log.append("attest")
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
