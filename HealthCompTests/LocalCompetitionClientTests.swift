import CompetitionCore
import XCTest
@testable import HealthComp

final class LocalCompetitionClientTests: XCTestCase {
    func testLaunchWaitsForEveryRereadAndBuffersSignalIntoOneNewerPublication() async throws {
        let setup = try await makeTwoAcceptedCompetitions()
        let signalDate = setup.activeDate.addingTimeInterval(1)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: setup.activeDate,
                    monotonic: MonotonicInstant(
                        epochID: "client-launch",
                        nanoseconds: 1_000
                    )
                ),
                initialDays: [],
                changes: [
                    try FixtureActivityChange(
                        at: signalDate,
                        updates: [],
                        triggers: [.observerWakeupBackground]
                    ),
                ]
            )
        )
        await source.blockNextRead()
        let client = LocalCompetitionClient.make(
            environment: .accelerated(source: source),
            storeAvailability: .available(setup.store),
            configuration: .testing
        )
        let capture = ClientPublicationCapture()
        let reader = Task {
            for await publication in client.start() {
                await capture.receive(publication)
                if await capture.count == 2 { break }
            }
        }

        await source.waitUntilReadIsBlocked()
        try await source.advance(to: signalDate)
        for _ in 0..<100 { await Task.yield() }
        let publicationCountWhileBlocked = await capture.count
        XCTAssertEqual(publicationCountWhileBlocked, 0)

        await source.releaseBlockedRead()
        let publications = await capture.first(2)

        XCTAssertEqual(publications.map(\.publicationRevision), [1, 2])
        XCTAssertEqual(
            publications.map { $0.dashboard.competitions.count },
            [2, 2]
        )
        let firstAppendCount = await setup.store.appendCount(for: setup.firstID)
        let secondAppendCount = await setup.store.appendCount(for: setup.secondID)
        let signalCompletionCount = await source.signalCompletionCount(
            "fixture-signal-1"
        )
        XCTAssertEqual(firstAppendCount, 3)
        XCTAssertEqual(secondAppendCount, 3)
        XCTAssertEqual(signalCompletionCount, 1)
        reader.cancel()
        await client.stop()
    }

    func testPublicationHubReplaysLatestRejectsDuplicatesAndCleansUpTermination() async throws {
        let hub = LocalCompetitionPublicationHub()
        hub.publish(makePublication(revision: 1))
        let stream = hub.stream()
        var iterator = stream.makeAsyncIterator()

        let replayedRevision = await iterator.next()?.publicationRevision
        XCTAssertEqual(replayedRevision, 1)
        hub.publish(makePublication(revision: 1))
        hub.publish(makePublication(revision: 0))
        hub.publish(makePublication(revision: 2))
        let nextRevision = await iterator.next()?.publicationRevision
        XCTAssertEqual(nextRevision, 2)

        let heldReader = Task {
            for await _ in hub.stream() {}
        }
        for _ in 0..<100 where hub.subscriberCount < 2 {
            await Task.yield()
        }
        XCTAssertEqual(hub.subscriberCount, 2)
        heldReader.cancel()
        _ = await heldReader.result
        hub.finish()
        for _ in 0..<100 where hub.subscriberCount != 0 {
            await Task.yield()
        }
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testPublicationHubConcurrentDeliveryNeverRegressesRevision() async {
        for _ in 0..<20 {
            let hub = LocalCompetitionPublicationHub()
            let stream = hub.stream()
            let publications = (1...1_000).map {
                makePublication(revision: UInt64($0))
            }
            let reader = Task { () -> [UInt64] in
                var revisions: [UInt64] = []
                for await publication in stream {
                    revisions.append(publication.publicationRevision)
                }
                return revisions
            }

            DispatchQueue.concurrentPerform(iterations: 1_000) { index in
                hub.publish(publications[index])
            }
            hub.finish()
            let revisions = await reader.value

            XCTAssertEqual(
                revisions,
                revisions.sorted(),
                "Concurrent delivery must never publish a newer revision "
                    + "before an older one"
            )
            XCTAssertEqual(Set(revisions).count, revisions.count)
        }
    }

    func testPublicationHubRegistrationRaceNeverMissesLatestRevision() async {
        for _ in 0..<100 {
            let hub = LocalCompetitionPublicationHub()
            hub.publish(makePublication(revision: 1))
            let secondPublication = makePublication(revision: 2)
            let registration = Task.detached { hub.stream() }
            let publishing = Task.detached {
                hub.publish(secondPublication)
            }

            let stream = await registration.value
            await publishing.value
            hub.finish()
            var revisions: [UInt64] = []
            for await publication in stream {
                revisions.append(publication.publicationRevision)
            }

            XCTAssertEqual(revisions.last, 2)
            XCTAssertEqual(revisions, revisions.sorted())
        }
    }

    func testEmptyStoreBootstrapIsDurablyIdempotentAcrossConcurrentAndRepeatedStart() async throws {
        let store = ClientTestEventStore()
        let instant = EnvironmentInstant(
            wallDate: Date(timeIntervalSinceReferenceDate: 900_000),
            monotonic: MonotonicInstant(
                epochID: "client-bootstrap",
                nanoseconds: 1_000
            )
        )
        let first = LocalCompetitionClient.make(
            environment: .accelerated(
                fixture: try ActivityFixture(
                    initialInstant: instant,
                    initialDays: [],
                    changes: []
                )
            ),
            storeAvailability: .available(store),
            configuration: .testing
        )
        let second = LocalCompetitionClient.make(
            environment: .accelerated(
                fixture: try ActivityFixture(
                    initialInstant: instant,
                    initialDays: [],
                    changes: []
                )
            ),
            storeAvailability: .available(store),
            configuration: .testing
        )

        async let firstPublication = nextPublication(from: first.start())
        async let secondPublication = nextPublication(from: second.start())
        _ = await (firstPublication, secondPublication)
        _ = await nextPublication(from: first.start())

        let ids = try await store.ids()
        let successfulCreateCount = await store.successfulCreateCount
        let optionalLoaded = try await store.load(
            LocalCompetitionIdentity.bootstrapCompetitionID
        )
        XCTAssertEqual(ids, [LocalCompetitionIdentity.bootstrapCompetitionID])
        XCTAssertEqual(successfulCreateCount, 1)
        let loaded = try XCTUnwrap(optionalLoaded)
        XCTAssertEqual(loaded.journal.genesis.direction, .outgoing)
        XCTAssertEqual(
            loaded.journal.genesis.expiresAt,
            instant.wallDate.addingTimeInterval(48 * 60 * 60)
        )
        XCTAssertEqual(
            loaded.journal.genesis.scoringPolicy,
            .healthKitCompatibility
        )
        XCTAssertEqual(
            loaded.journal.genesis.downwardRevisionPolicy,
            .maximumObserved
        )
        guard case .pendingInvitation =
            loaded.projection.competition.lifecycle
        else {
            return XCTFail("Bootstrap must remain pending until a user accepts")
        }
        await first.stop()
        await second.stop()
    }

    func testDeletedBootstrapIdentityDoesNotResurrect() async throws {
        let store = ClientTestEventStore()
        let instant = EnvironmentInstant(
            wallDate: Date(timeIntervalSinceReferenceDate: 950_000),
            monotonic: MonotonicInstant(
                epochID: "client-bootstrap-tombstone",
                nanoseconds: 1_000
            )
        )
        let genesis = try CompetitionGenesis(
            competitionID: LocalCompetitionIdentity.bootstrapCompetitionID,
            direction: .outgoing,
            createdAt: instant.wallDate,
            expiresAt: instant.wallDate.addingTimeInterval(48 * 60 * 60),
            scoringPolicy: .healthKitCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
        let created = try await store.create(genesis)
        try await store.delete(
            genesis.competitionID,
            expectedCursor: created.cursor
        )
        let client = LocalCompetitionClient.make(
            environment: .accelerated(
                fixture: try ActivityFixture(
                    initialInstant: instant,
                    initialDays: [],
                    changes: []
                )
            ),
            storeAvailability: .available(store),
            configuration: .testing
        )

        let publication = await nextPublication(from: client.start())

        let ids = try await store.ids()
        let successfulCreateCount = await store.successfulCreateCount
        XCTAssertEqual(ids, [])
        XCTAssertEqual(successfulCreateCount, 1)
        XCTAssertTrue(
            publication.dashboard.issues.contains(.bootstrapIdentityRetired)
        )
        await client.stop()
    }

    func testFixedIdentityGoldenSeedAndFixtureZoneSurviveRelaunch() async throws {
        let store = ClientTestEventStore()
        let id = CompetitionID(
            UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        )
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        _ = try await store.create(
            try CompetitionGenesis(
                competitionID: id,
                direction: .incoming,
                createdAt: now.addingTimeInterval(-60),
                expiresAt: now.addingTimeInterval(48 * 60 * 60),
                scoringPolicy: .healthKitCompatibility,
                downwardRevisionPolicy: .maximumObserved
            )
        )
        let firstSource = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: now,
                    monotonic: MonotonicInstant(
                        epochID: "identity-first",
                        nanoseconds: 1_000
                    )
                ),
                timeZoneIdentifier: "Pacific/Kiritimati",
                initialDays: [],
                changes: []
            )
        )
        let first = LocalCompetitionClient.make(
            environment: .accelerated(source: firstSource),
            storeAvailability: .available(store),
            configuration: .testing
        )
        let pending = await nextPublication(from: first.start())
        XCTAssertEqual(pending.dashboard.competitions.first?.ownerDisplayName, "Naren")
        XCTAssertEqual(pending.dashboard.competitions.first?.opponentDisplayName, "Alex")
        XCTAssertNil(pending.dashboard.competitions.first?.acceptedConfiguration)

        let accepted = await first.accept(id)
        let acceptedPresentation = try XCTUnwrap(
            accepted.dashboard.competitions.first { $0.id == id }
        )
        XCTAssertEqual(
            LocalCompetitionIdentity.opponentSeed(for: id),
            7_734_633_050_809_873_892
        )
        let optionalAcceptedJournal = try await store.load(id)
        let acceptedJournal = try XCTUnwrap(optionalAcceptedJournal)
        let acceptedPlan = try XCTUnwrap(
            acceptedJournal.projection.competition.opponentPlan
        )
        XCTAssertEqual(
            acceptedPlan.seed,
            7_734_633_050_809_873_892
        )
        XCTAssertEqual(acceptedPlan.generatorVersion, .v1)
        XCTAssertEqual(
            acceptedPresentation.acceptedConfiguration?.difficulty,
            .balanced
        )
        XCTAssertEqual(
            acceptedPresentation.acceptedConfiguration?
                .schedule.calendar.timeZoneIdentifier,
            "Pacific/Kiritimati"
        )
        let acceptedFields = Set(
            Mirror(
                reflecting: try XCTUnwrap(
                    acceptedPresentation.acceptedConfiguration
                )
            ).children.compactMap(\.label)
        )
        XCTAssertEqual(
            acceptedFields,
            ["schedule", "difficulty"],
            "Presentation metadata must not permit reconstruction of future "
                + "opponent checkpoints"
        )
        await first.stop()

        let second = LocalCompetitionClient.make(
            environment: .accelerated(
                fixture: try ActivityFixture(
                    initialInstant: EnvironmentInstant(
                        wallDate: now,
                        monotonic: MonotonicInstant(
                            epochID: "identity-second",
                            nanoseconds: 2_000
                        )
                    ),
                    timeZoneIdentifier: "UTC",
                    initialDays: [],
                    changes: []
                )
            ),
            storeAvailability: .available(store),
            configuration: .testing
        )
        let relaunched = await nextPublication(from: second.start())
        let relaunchedPresentation = try XCTUnwrap(
            relaunched.dashboard.competitions.first { $0.id == id }
        )
        XCTAssertEqual(
            relaunchedPresentation.acceptedConfiguration,
            acceptedPresentation.acceptedConfiguration
        )
        XCTAssertEqual(relaunchedPresentation.ownerDisplayName, "Naren")
        XCTAssertEqual(relaunchedPresentation.opponentDisplayName, "Alex")
        await second.stop()
    }

    func testPresentationShowsSevenDaysWithoutFutureOpponentFinals() async throws {
        let store = ClientTestEventStore()
        let id = CompetitionID(
            UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        )
        let acceptedAt = Date(timeIntervalSinceReferenceDate: 1_200_000)
        let accepted = try await makeAccepted(
            store: store,
            id: id,
            acceptedAt: acceptedAt
        )
        let currentDate = accepted.activeDate.addingTimeInterval(24 * 60 * 60)
        let optionalLoadedBefore = try await store.load(id)
        let loadedBefore = try XCTUnwrap(optionalLoadedBefore)
        let persistedPlan = try XCTUnwrap(
            loadedBefore.projection.competition.opponentPlan
        )
        let window = accepted.window
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: currentDate,
                    monotonic: MonotonicInstant(
                        epochID: "presentation-privacy",
                        nanoseconds: 1_000
                    )
                ),
                initialDays: [
                    .snapshot(
                        day: window.days[0],
                        snapshot: try makeSnapshot(moveValue: 300)
                    ),
                    .snapshot(
                        day: window.days[1],
                        snapshot: try makeSnapshot(moveValue: 350)
                    ),
                ],
                changes: []
            )
        )
        let client = LocalCompetitionClient.make(
            environment: .accelerated(source: source),
            storeAvailability: .available(store),
            configuration: .testing
        )

        let publication = await nextPublication(from: client.start())
        let presentation = try XCTUnwrap(
            publication.dashboard.competitions.first { $0.id == id }
        )

        XCTAssertEqual(presentation.days.map(\.ordinal), Array(1...7))
        XCTAssertEqual(presentation.currentDayOrdinal, 2)
        XCTAssertEqual(
            presentation.days[0].opponentRevealedPoints,
            Double(persistedPlan.days[0].finalPoints)
        )
        XCTAssertNotNil(presentation.days[1].opponentRevealedPoints)
        XCTAssertGreaterThan(persistedPlan.days[2].finalPoints, 0)
        XCTAssertNil(presentation.days[2].opponentRevealedPoints)
        XCTAssertEqual(
            presentation.days[0].ownerLatestAvailability,
            .observed
        )
        XCTAssertNotNil(presentation.days[0].ownerAcceptedPoints)
        XCTAssertEqual(
            presentation.days[2].ownerLatestAvailability,
            .notYetOccurred
        )
        XCTAssertNotNil(presentation.lastRefresh)
        XCTAssertNil(presentation.terminalResult)
        await client.stop()
    }

    func testAwardsFoldIsStableIdempotentAndOnlyWinsEarnVictory() throws {
        let completedAt = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let winID = CompetitionID(
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        let lossID = CompetitionID(
            UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        )
        let tieID = CompetitionID(
            UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        )
        let presentations = [
            terminalPresentation(id: winID, outcome: .win, completedAt: completedAt),
            terminalPresentation(id: lossID, outcome: .loss, completedAt: completedAt),
            terminalPresentation(id: tieID, outcome: .tie, completedAt: completedAt),
        ]

        let first = LocalCompetitionAward.fold(
            completed: presentations + presentations
        )
        let relaunched = LocalCompetitionAward.fold(completed: presentations)

        XCTAssertEqual(first, relaunched)
        XCTAssertEqual(first.filter { $0.kind == .completion }.count, 3)
        XCTAssertEqual(first.filter { $0.kind == .victory }.count, 1)
        XCTAssertEqual(first.first { $0.kind == .victory }?.competitionID, winID)
        XCTAssertTrue(first.allSatisfy { $0.awardedAt == completedAt })
        XCTAssertTrue(first.allSatisfy { $0.friendDisplayName == "Alex" })
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
    }

    func testDesiredWindowIsSharedReleasedAtLastTerminalAndStopKeepsItEmpty() async throws {
        let setup = try await makeTwoAcceptedCompetitions()
        let endBoundary = try setup.window.calendar.startOfDay(
            setup.window.calendar.day(after: setup.window.days[6])
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: setup.activeDate,
                    monotonic: MonotonicInstant(
                        epochID: "client-windows",
                        nanoseconds: 1_000
                    )
                ),
                initialDays: try setup.window.days.map {
                    .snapshot(
                        day: $0,
                        snapshot: try makeSnapshot(moveValue: 300)
                    )
                },
                changes: [
                    try FixtureActivityChange(
                        at: endBoundary,
                        updates: [],
                        triggers: [.observerWakeupBackground]
                    ),
                ]
            )
        )
        let client = LocalCompetitionClient.make(
            environment: .accelerated(source: source),
            storeAvailability: .available(setup.store),
            configuration: LocalCompetitionRuntimeConfiguration(
                minimumStabilityNanoseconds: 1,
                bestAvailableGrace: 0
            )
        )
        var iterator = client.start().makeAsyncIterator()
        _ = await iterator.next()
        let initialDesired = await source.desiredSummarySubscriptionWindows()
        XCTAssertEqual(initialDesired, [setup.window])

        try await source.advance(to: endBoundary)
        let optionalCompleted = await iterator.next()
        let completed = try XCTUnwrap(optionalCompleted)
        XCTAssertTrue(
            completed.dashboard.competitions.allSatisfy {
                if case .completed = $0.lifecycle { return true }
                return false
            }
        )
        let completedDesired = await source.desiredSummarySubscriptionWindows()
        XCTAssertEqual(completedDesired, [])

        _ = await client.archive(setup.firstID)
        let archivedDesired = await source.desiredSummarySubscriptionWindows()
        XCTAssertEqual(archivedDesired, [])
        await client.stop()
        let stoppedDesired = await source.desiredSummarySubscriptionWindows()
        XCTAssertEqual(stoppedDesired, [])
    }

    func testStopMakesReconcileAllInert() async throws {
        let store = ClientTestEventStore()
        let id = CompetitionID(
            UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        )
        let accepted = try await makeAccepted(
            store: store,
            id: id,
            acceptedAt: Date(timeIntervalSinceReferenceDate: 3_200_000)
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: accepted.activeDate,
                    monotonic: MonotonicInstant(
                        epochID: "client-stop-reconcile",
                        nanoseconds: 1_000
                    )
                ),
                initialDays: [],
                changes: []
            )
        )
        let client = LocalCompetitionClient.make(
            environment: .accelerated(source: source),
            storeAvailability: .available(store),
            configuration: .testing
        )

        try await assertStopMakesOperationInert(
            client: client,
            source: source,
            store: store,
            trackedID: id,
            expectedLifecycle: {
                if case .active = $0 { return true }
                return false
            },
            operation: { client in
                await client.reconcileAll(.foreground)
            }
        )
    }

    func testStopMakesAcceptInert() async throws {
        let setup = try await makePendingClient(
            id: CompetitionID(
                UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
            ),
            epochID: "client-stop-accept"
        )
        try await assertStopMakesOperationInert(
            client: setup.client,
            source: setup.source,
            store: setup.store,
            trackedID: setup.id,
            expectedLifecycle: {
                if case .pending = $0 { return true }
                return false
            },
            operation: { client in await client.accept(setup.id) }
        )
    }

    func testStopMakesDeclineInert() async throws {
        let setup = try await makePendingClient(
            id: CompetitionID(
                UUID(uuidString: "40000000-0000-0000-0000-000000000003")!
            ),
            epochID: "client-stop-decline"
        )
        try await assertStopMakesOperationInert(
            client: setup.client,
            source: setup.source,
            store: setup.store,
            trackedID: setup.id,
            expectedLifecycle: {
                if case .pending = $0 { return true }
                return false
            },
            operation: { client in await client.decline(setup.id) }
        )
    }

    func testStopMakesArchiveInert() async throws {
        let setup = try await makeCompletedClient(
            id: CompetitionID(
                UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
            ),
            epochID: "client-stop-archive"
        )
        try await assertStopMakesOperationInert(
            client: setup.client,
            source: setup.source,
            store: setup.store,
            trackedID: setup.id,
            expectedLifecycle: {
                if case .completed = $0 { return true }
                return false
            },
            operation: { client in await client.archive(setup.id) }
        )
    }

    func testStopMakesRematchInert() async throws {
        let id = CompetitionID(
            UUID(uuidString: "40000000-0000-0000-0000-000000000005")!
        )
        let newID = CompetitionID(
            UUID(uuidString: "40000000-0000-0000-0000-000000000006")!
        )
        let setup = try await makeCompletedClient(
            id: id,
            epochID: "client-stop-rematch",
            idGenerator: { _ in newID }
        )
        try await assertStopMakesOperationInert(
            client: setup.client,
            source: setup.source,
            store: setup.store,
            trackedID: setup.id,
            expectedLifecycle: {
                if case .completed = $0 { return true }
                return false
            },
            operation: { client in await client.rematch(setup.id) }
        )
    }

    func testDefaultRematchIDHasStableVersionOneGoldenValue() async throws {
        let sourceID = CompetitionID(
            UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        )
        let expectedChildID = CompetitionID(
            UUID(uuidString: "B5892B8C-610D-5816-89A6-2BDB8887DA04")!
        )
        let setup = try await makeCompletedClient(
            id: sourceID,
            epochID: "client-rematch-golden"
        )
        _ = await nextPublication(from: setup.client.start())

        let publication = await setup.client.rematch(sourceID)
        let ids = try await setup.store.ids()

        XCTAssertEqual(
            ids,
            [sourceID, expectedChildID].sorted {
                $0.rawValue.uuidString < $1.rawValue.uuidString
            }
        )
        XCTAssertTrue(publication.dashboard.issues.isEmpty)
        XCTAssertNotNil(
            publication.dashboard.competitions.first {
                $0.id == expectedChildID
            }
        )
        await setup.client.stop()
    }

    func testSequentialAndConcurrentDuplicateRematchesCreateOneChildAndPreserveSource() async throws {
        let sourceID = CompetitionID(
            UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
        )
        let setup = try await makeCompletedClient(
            id: sourceID,
            epochID: "client-rematch-duplicates"
        )
        _ = await nextPublication(from: setup.client.start())
        let independentClient = LocalCompetitionClient.make(
            environment: .accelerated(source: setup.source),
            storeAvailability: .available(setup.store),
            configuration: LocalCompetitionRuntimeConfiguration(
                minimumStabilityNanoseconds: 1,
                bestAvailableGrace: 0
            )
        )
        _ = await nextPublication(from: independentClient.start())
        let optionalSourceBefore = try await setup.store.load(sourceID)
        let sourceBefore = try XCTUnwrap(optionalSourceBefore)

        async let initialRematchOne = setup.client.rematch(sourceID)
        async let initialRematchTwo = independentClient.rematch(sourceID)
        let initialRematches = await (initialRematchOne, initialRematchTwo)
        let first = initialRematches.0
        let firstChildID = try XCTUnwrap(
            first.dashboard.competitions.first { $0.id != sourceID }?.id
        )
        let optionalFirstChild = try await setup.store.load(firstChildID)
        let firstChild = try XCTUnwrap(optionalFirstChild)
        try await setup.source.advance(
            to: firstChild.journal.genesis.createdAt.addingTimeInterval(60)
        )

        let sequentialRetry = await setup.client.rematch(sourceID)
        async let concurrentRetryOne = setup.client.rematch(sourceID)
        async let concurrentRetryTwo = independentClient.rematch(sourceID)
        let concurrentRetries = await (
            concurrentRetryOne,
            concurrentRetryTwo
        )

        let ids = try await setup.store.ids()
        let optionalSourceAfter = try await setup.store.load(sourceID)
        let sourceAfter = try XCTUnwrap(optionalSourceAfter)
        let optionalChildAfter = try await setup.store.load(firstChildID)
        let childAfter = try XCTUnwrap(optionalChildAfter)
        let createCount = await setup.store.successfulCreateCount

        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids), Set([sourceID, firstChildID]))
        XCTAssertEqual(createCount, 2)
        XCTAssertEqual(sourceAfter, sourceBefore)
        XCTAssertEqual(childAfter.journal, firstChild.journal)
        XCTAssertTrue(initialRematches.0.dashboard.issues.isEmpty)
        XCTAssertTrue(initialRematches.1.dashboard.issues.isEmpty)
        XCTAssertTrue(sequentialRetry.dashboard.issues.isEmpty)
        XCTAssertTrue(concurrentRetries.0.dashboard.issues.isEmpty)
        XCTAssertTrue(concurrentRetries.1.dashboard.issues.isEmpty)
        await independentClient.stop()
        await setup.client.stop()
    }

    func testRematchRetryAfterRelaunchReusesChildAndOriginalTimestamps() async throws {
        let sourceID = CompetitionID(
            UUID(uuidString: "50000000-0000-0000-0000-000000000003")!
        )
        let childID = CompetitionID(
            UUID(uuidString: "50000000-0000-0000-0000-000000000004")!
        )
        let firstSetup = try await makeCompletedClient(
            id: sourceID,
            epochID: "client-rematch-first-process",
            idGenerator: { _ in childID }
        )
        _ = await nextPublication(from: firstSetup.client.start())
        let firstRematch = await firstSetup.client.rematch(sourceID)
        XCTAssertTrue(firstRematch.dashboard.issues.isEmpty)
        let optionalOriginalChild = try await firstSetup.store.load(childID)
        let originalChild = try XCTUnwrap(optionalOriginalChild)
        await firstSetup.client.stop()

        let retryDate = originalChild.journal.genesis.createdAt
            .addingTimeInterval(60 * 60)
        let retrySource = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: retryDate,
                    monotonic: MonotonicInstant(
                        epochID: "client-rematch-second-process",
                        nanoseconds: 1_000
                    )
                ),
                initialDays: [],
                changes: []
            )
        )
        let retryClient = LocalCompetitionClient.make(
            environment: .accelerated(source: retrySource),
            storeAvailability: .available(firstSetup.store),
            configuration: .testing,
            idGenerator: { _ in childID }
        )
        _ = await nextPublication(from: retryClient.start())

        let retryPublication = await retryClient.rematch(sourceID)
        let optionalRetriedChild = try await firstSetup.store.load(childID)
        let retriedChild = try XCTUnwrap(optionalRetriedChild)
        let ids = try await firstSetup.store.ids()
        let createCount = await firstSetup.store.successfulCreateCount

        XCTAssertTrue(retryPublication.dashboard.issues.isEmpty)
        XCTAssertEqual(retriedChild.journal, originalChild.journal)
        XCTAssertEqual(
            retriedChild.journal.genesis.createdAt,
            originalChild.journal.genesis.createdAt
        )
        XCTAssertEqual(
            retriedChild.journal.genesis.expiresAt,
            originalChild.journal.genesis.expiresAt
        )
        XCTAssertEqual(Set(ids), Set([sourceID, childID]))
        XCTAssertEqual(createCount, 2)
        await retryClient.stop()
    }

    func testRematchRetryRejectsMismatchedAndTombstonedChildIdentity() async throws {
        let mismatchedSourceID = CompetitionID(
            UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        )
        let mismatchedChildID = CompetitionID(
            UUID(uuidString: "50000000-0000-0000-0000-000000000006")!
        )
        let mismatch = try await makeCompletedClient(
            id: mismatchedSourceID,
            epochID: "client-rematch-mismatch",
            idGenerator: { _ in mismatchedChildID }
        )
        let conflictGenesis = try CompetitionGenesis(
            competitionID: mismatchedChildID,
            direction: .incoming,
            createdAt: Date(timeIntervalSinceReferenceDate: 3_500_000),
            expiresAt: Date(timeIntervalSinceReferenceDate: 3_600_000),
            scoringPolicy: .healthKitCompatibility,
            downwardRevisionPolicy: .latestValue
        )
        _ = try await mismatch.store.create(conflictGenesis)
        _ = await nextPublication(from: mismatch.client.start())

        let mismatchPublication = await mismatch.client.rematch(
            mismatchedSourceID
        )
        let storedConflict = try await mismatch.store.load(mismatchedChildID)

        XCTAssertEqual(
            mismatchPublication.dashboard.issues,
            [.commandRejected(mismatchedSourceID)]
        )
        XCTAssertEqual(storedConflict?.journal.genesis, conflictGenesis)
        await mismatch.client.stop()

        let tombstonedSourceID = CompetitionID(
            UUID(uuidString: "50000000-0000-0000-0000-000000000007")!
        )
        let tombstonedChildID = CompetitionID(
            UUID(uuidString: "50000000-0000-0000-0000-000000000008")!
        )
        let tombstone = try await makeCompletedClient(
            id: tombstonedSourceID,
            epochID: "client-rematch-tombstone",
            idGenerator: { _ in tombstonedChildID }
        )
        let retiredGenesis = try CompetitionGenesis(
            competitionID: tombstonedChildID,
            direction: .outgoing,
            createdAt: Date(timeIntervalSinceReferenceDate: 3_500_000),
            expiresAt: Date(timeIntervalSinceReferenceDate: 3_600_000),
            scoringPolicy: .healthKitCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
        let retiredCreate = try await tombstone.store.create(retiredGenesis)
        try await tombstone.store.delete(
            tombstonedChildID,
            expectedCursor: retiredCreate.cursor
        )
        _ = await nextPublication(from: tombstone.client.start())

        let tombstonePublication = await tombstone.client.rematch(
            tombstonedSourceID
        )
        let tombstonedChild = try await tombstone.store.load(
            tombstonedChildID
        )

        XCTAssertEqual(
            tombstonePublication.dashboard.issues,
            [.commandRejected(tombstonedSourceID)]
        )
        XCTAssertNil(tombstonedChild)
        await tombstone.client.stop()
    }

    func testStorageFailureIsTypedAndDependencyTestPreviewValuesAreInert() async throws {
        let unavailable = LocalCompetitionClient.make(
            environment: .accelerated(
                fixture: try ActivityFixture(
                    initialInstant: EnvironmentInstant(
                        wallDate: Date(timeIntervalSinceReferenceDate: 3_000_000),
                        monotonic: MonotonicInstant(
                            epochID: "client-storage-unavailable",
                            nanoseconds: 1_000
                        )
                    ),
                    initialDays: [],
                    changes: []
                )
            ),
            storeAvailability: .unavailable,
            configuration: .testing
        )
        let publication = await nextPublication(from: unavailable.start())
        XCTAssertEqual(publication.dashboard.issues, [.storageUnavailable])

        let testPublication = await nextPublication(
            from: LocalCompetitionClient.testValue.start()
        )
        let previewPublication = await nextPublication(
            from: LocalCompetitionClient.previewValue.start()
        )
        XCTAssertEqual(testPublication.dashboard.issues, [.unimplemented])
        XCTAssertEqual(previewPublication.dashboard.issues, [.unimplemented])
        await unavailable.stop()
    }

    func testPublicationRevisionExhaustionPublishesMaximumAndFinishes() async throws {
        let client = LocalCompetitionClient.make(
            environment: .accelerated(
                fixture: try ActivityFixture(
                    initialInstant: EnvironmentInstant(
                        wallDate: Date(timeIntervalSinceReferenceDate: 3_100_000),
                        monotonic: MonotonicInstant(
                            epochID: "client-revision-exhaustion",
                            nanoseconds: 1_000
                        )
                    ),
                    initialDays: [],
                    changes: []
                )
            ),
            storeAvailability: .available(ClientTestEventStore()),
            configuration: .testing,
            initialPublicationRevision: UInt64.max - 1
        )
        var iterator = client.start().makeAsyncIterator()

        let publication = await iterator.next()
        let finished = await iterator.next()

        XCTAssertEqual(publication?.publicationRevision, UInt64.max)
        XCTAssertEqual(
            publication?.dashboard.issues,
            [.publicationRevisionExhausted]
        )
        XCTAssertNil(finished)
        await client.stop()
    }

    func testDeclinedInvitationReinviteRaceConvergesAndIsIdempotentAcrossRelaunch() async throws {
        let sourceID = CompetitionID(
            UUID(uuidString: "41000000-0000-0000-0000-000000000001")!
        )
        let setup = try await makePendingClient(
            id: sourceID,
            epochID: "client-reinvite-declined"
        )
        _ = await nextPublication(from: setup.client.start())
        let declined = await setup.client.decline(sourceID)
        XCTAssertTrue(declined.dashboard.competitions.isEmpty)
        let independentClient = LocalCompetitionClient.make(
            environment: .accelerated(source: setup.source),
            storeAvailability: .available(setup.store),
            configuration: .testing
        )
        _ = await nextPublication(from: independentClient.start())
        let optionalSourceBefore = try await setup.store.load(sourceID)
        let sourceBefore = try XCTUnwrap(optionalSourceBefore)

        async let firstRecovery = setup.client.reinvite()
        async let secondRecovery = independentClient.reinvite()
        let recoveries = await (firstRecovery, secondRecovery)
        let childID = LocalCompetitionIdentity.rematchID(for: sourceID)
        let child = try XCTUnwrap(recoveries.0.dashboard.competitions.first {
            $0.id == childID
        })
        guard case .pending(direction: .outgoing, _, _) = child.lifecycle else {
            return XCTFail("Recovery must create one outgoing invitation")
        }
        XCTAssertNotNil(recoveries.1.dashboard.competitions.first {
            $0.id == childID
        })
        XCTAssertTrue(recoveries.0.dashboard.issues.isEmpty)
        XCTAssertTrue(recoveries.1.dashboard.issues.isEmpty)
        let optionalFirstChild = try await setup.store.load(childID)
        let firstChild = try XCTUnwrap(optionalFirstChild)
        let sourceAfterRace = try await setup.store.load(sourceID)
        XCTAssertEqual(
            sourceAfterRace,
            sourceBefore,
            "Recovery must not mutate the declined source journal"
        )
        try await setup.source.advance(
            to: firstChild.journal.genesis.createdAt.addingTimeInterval(60)
        )
        _ = await setup.client.reinvite()
        let idsAfterRetry = try await setup.store.ids()
        let childAfterRetry = try await setup.store.load(childID)
        XCTAssertEqual(idsAfterRetry.count, 2)
        XCTAssertEqual(
            childAfterRetry?.journal.genesis.createdAt,
            firstChild.journal.genesis.createdAt
        )
        XCTAssertEqual(
            childAfterRetry?.journal.genesis.expiresAt,
            firstChild.journal.genesis.expiresAt
        )
        await independentClient.stop()
        await setup.client.stop()

        let relaunched = LocalCompetitionClient.make(
            environment: .accelerated(source: setup.source),
            storeAvailability: .available(setup.store),
            configuration: .testing
        )
        let relaunchedPublication = await nextPublication(from: relaunched.start())
        XCTAssertEqual(
            relaunchedPublication.dashboard.competitions.map(\.id),
            [childID]
        )
        _ = await relaunched.reinvite()
        let relaunchedIDs = try await setup.store.ids()
        let relaunchedChild = try await setup.store.load(childID)
        XCTAssertEqual(relaunchedIDs.count, 2)
        XCTAssertEqual(
            relaunchedChild?.journal,
            firstChild.journal
        )
        await relaunched.stop()
    }

    func testExpiredInvitationCanBeReinvitedFromLatestHiddenIdentity() async throws {
        let store = ClientTestEventStore()
        let now = Date(timeIntervalSinceReferenceDate: 3_600_000)
        let sourceID = CompetitionID(
            UUID(uuidString: "42000000-0000-0000-0000-000000000001")!
        )
        _ = try await store.create(
            try CompetitionGenesis(
                competitionID: sourceID,
                direction: .outgoing,
                createdAt: now.addingTimeInterval(-120),
                expiresAt: now.addingTimeInterval(-60),
                scoringPolicy: .healthKitCompatibility,
                downwardRevisionPolicy: .maximumObserved
            )
        )
        let client = LocalCompetitionClient.make(
            environment: .accelerated(
                fixture: try ActivityFixture(
                    initialInstant: EnvironmentInstant(
                        wallDate: now,
                        monotonic: MonotonicInstant(
                            epochID: "client-reinvite-expired",
                            nanoseconds: 1_000
                        )
                    ),
                    initialDays: [],
                    changes: []
                )
            ),
            storeAvailability: .available(store),
            configuration: .testing
        )
        let expired = await nextPublication(from: client.start())
        XCTAssertTrue(expired.dashboard.competitions.isEmpty)

        let recovered = await client.reinvite()

        XCTAssertEqual(recovered.dashboard.competitions.count, 1)
        guard case .pending(direction: .outgoing, _, _) =
            recovered.dashboard.competitions[0].lifecycle else {
            return XCTFail("Expired recovery must be outgoing and pending")
        }
        await client.stop()
    }

    func testReinviteFailsClosedWhenDerivedIdentityWasTombstoned() async throws {
        let sourceID = CompetitionID(
            UUID(uuidString: "43000000-0000-0000-0000-000000000001")!
        )
        let setup = try await makePendingClient(
            id: sourceID,
            epochID: "client-reinvite-tombstone"
        )
        _ = await nextPublication(from: setup.client.start())
        _ = await setup.client.decline(sourceID)
        let childID = LocalCompetitionIdentity.rematchID(for: sourceID)
        let childGenesis = try CompetitionGenesis(
            competitionID: childID,
            direction: .outgoing,
            createdAt: Date(timeIntervalSinceReferenceDate: 3_300_001),
            expiresAt: nil,
            scoringPolicy: .healthKitCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
        let created = try await setup.store.create(childGenesis)
        try await setup.store.delete(childID, expectedCursor: created.cursor)

        let publication = await setup.client.reinvite()

        XCTAssertTrue(publication.dashboard.competitions.isEmpty)
        XCTAssertTrue(publication.dashboard.issues.contains(.commandRejected(sourceID)))
        let remainingIDs = try await setup.store.ids()
        XCTAssertEqual(remainingIDs, [sourceID])
        await setup.client.stop()
    }

    func testReinviteFailsClosedForIncompatibleDerivedIdentity() async throws {
        let sourceID = CompetitionID(
            UUID(uuidString: "43000000-0000-0000-0000-000000000002")!
        )
        let setup = try await makePendingClient(
            id: sourceID,
            epochID: "client-reinvite-mismatch"
        )
        _ = await nextPublication(from: setup.client.start())
        _ = await setup.client.decline(sourceID)
        let childID = LocalCompetitionIdentity.rematchID(for: sourceID)
        let conflictingGenesis = try CompetitionGenesis(
            competitionID: childID,
            direction: .incoming,
            createdAt: Date(timeIntervalSinceReferenceDate: 3_300_001),
            expiresAt: nil,
            scoringPolicy: .healthKitCompatibility,
            downwardRevisionPolicy: .latestValue
        )
        _ = try await setup.store.create(conflictingGenesis)

        let publication = await setup.client.reinvite()
        let storedConflict = try await setup.store.load(childID)

        XCTAssertEqual(publication.dashboard.competitions.count, 1)
        guard case .pending(direction: .incoming, _, _) =
            publication.dashboard.competitions[0].lifecycle
        else {
            return XCTFail("Recovery must not bless a mismatched child")
        }
        XCTAssertEqual(publication.dashboard.issues, [.commandRejected(sourceID)])
        XCTAssertEqual(
            storedConflict?.journal.genesis,
            conflictingGenesis
        )
        await setup.client.stop()
    }

    func testNotificationSnapshotPublishesAfterCanonicalStateAndKeepsHiddenIdentity()
        async throws {
        let id = CompetitionID(
            UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
        )
        let setup = try await makePendingClient(
            id: id,
            epochID: "client-notification-snapshot"
        )
        let notifications = ClientNotificationCoordinatorRecorder()
        let client = LocalCompetitionClient.make(
            environment: .accelerated(source: setup.source),
            storeAvailability: .available(setup.store),
            configuration: .testing,
            notificationCoordinatorFactory: { _ in notifications.client }
        )
        var iterator = client.start().makeAsyncIterator()

        let optionalInitial = await iterator.next()
        let initial = try XCTUnwrap(optionalInitial)
        let initialSnapshot = await notifications.snapshot(at: 0)

        XCTAssertEqual(initial.publicationRevision, 1)
        XCTAssertEqual(initialSnapshot.publicationRevision, 1)
        XCTAssertEqual(initialSnapshot.knownCompetitionIDs, [id])
        XCTAssertEqual(
            initialSnapshot.competitions.first?.opponentIdentity,
            LocalCompetitionIdentity.opponentIdentity
        )
        XCTAssertEqual(
            initial.dashboard.competitions.first?.opponentIdentity,
            LocalCompetitionIdentity.opponentIdentity
        )

        let declined = await client.decline(id)
        let hiddenSnapshot = await notifications.snapshot(at: 1)

        XCTAssertEqual(declined.dashboard.competitions, [])
        XCTAssertEqual(declined.dashboard.hiddenTerminalCompetitionCount, 1)
        XCTAssertEqual(hiddenSnapshot.knownCompetitionIDs, [id])
        XCTAssertEqual(hiddenSnapshot.competitions.count, 1)
        XCTAssertEqual(hiddenSnapshot.competitions.first?.lifecycle, .declined)
        await client.stop()
    }

    func testNotificationSubmitDoesNotBlockCanonicalPublicationAndDeleteCancelsFirst()
        async throws {
        let id = CompetitionID(
            UUID(uuidString: "71000000-0000-0000-0000-000000000002")!
        )
        let setup = try await makePendingClient(
            id: id,
            epochID: "client-notification-delete"
        )
        let notifications = ClientNotificationCoordinatorRecorder(
            blockSubmissions: true,
            blockCancellation: true
        )
        let client = LocalCompetitionClient.make(
            environment: .accelerated(source: setup.source),
            storeAvailability: .available(setup.store),
            configuration: .testing,
            notificationCoordinatorFactory: { _ in notifications.client }
        )
        var iterator = client.start().makeAsyncIterator()

        let optionalInitial = await iterator.next()
        let initial = try XCTUnwrap(optionalInitial)
        XCTAssertEqual(initial.publicationRevision, 1)
        await notifications.waitUntilSubmissionStarted()

        let deletion = Task { await client.delete(id) }
        await notifications.waitUntilCancellationStarted()
        let beforeCancellationRelease = try await setup.store.load(id)
        XCTAssertNotNil(beforeCancellationRelease)

        await notifications.releaseCancellation()
        let deleted = await deletion.value
        let afterDeletion = try await setup.store.load(id)

        XCTAssertNil(afterDeletion)
        XCTAssertEqual(deleted.dashboard.competitions, [])
        let cancelledIDs = await notifications.cancelledIDs
        XCTAssertEqual(cancelledIDs, [id])
        await notifications.releaseSubmissions()
        await client.reconcileNotifications()
        let reconcileLatestCount = await notifications.reconcileLatestCount
        XCTAssertEqual(reconcileLatestCount, 1)
        await client.stop()
    }

    func testLiveNotificationCoordinatorPersistsBeforePostAndRelaunchDeduplicates()
        async throws {
        let id = CompetitionID(
            UUID(uuidString: "71000000-0000-0000-0000-000000000003")!
        )
        let center = ClientNotificationCenterRecorder()
        let factory: @Sendable (LocalCompetitionRuntime?) ->
            CompetitionNotificationCoordinatorClient = { runtime in
                .live(
                    runtime: runtime,
                    planner: CompetitionNotificationPlanner(
                        policy: .clientIntegrationFixture
                    ),
                    notifications: center.client,
                    preferences: .constant(mutedOpponentIdentities: [])
                )
            }
        let setup = try await makeCompletedClient(
            id: id,
            epochID: "client-notification-live",
            notificationCoordinatorFactory: factory
        )
        var firstIterator = setup.client.start().makeAsyncIterator()

        _ = await firstIterator.next()
        let firstPost = await center.post(at: 0)
        let optionalLoadedAfterPost = try await setup.store.load(id)
        let loadedAfterPost = try XCTUnwrap(optionalLoadedAfterPost)

        XCTAssertEqual(
            loadedAfterPost.projection.notificationEmissions.recordedIDs,
            [firstPost.identifier]
        )
        await setup.client.stop()

        let relaunched = LocalCompetitionClient.make(
            environment: .accelerated(source: setup.source),
            storeAvailability: .available(setup.store),
            configuration: LocalCompetitionRuntimeConfiguration(
                minimumStabilityNanoseconds: 1,
                bestAvailableGrace: 0
            ),
            notificationCoordinatorFactory: factory
        )
        var relaunchedIterator = relaunched.start().makeAsyncIterator()
        _ = await relaunchedIterator.next()
        await relaunched.reconcileNotifications()
        for _ in 0..<100 { await Task.yield() }

        let finalPostCount = await center.postCount
        XCTAssertEqual(finalPostCount, 1)
        await relaunched.stop()
    }

    func testMutePreferencePersistsBeforeNotificationReconciliation()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "client-notification-preferences-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = CompetitionNotificationPreferencesClient.live(
            fileURL: root.appendingPathComponent("preferences.json")
        )
        let notifications = ClientNotificationCoordinatorRecorder()
        let setup = try await makePendingClient(
            id: CompetitionID(
                UUID(
                    uuidString: "71000000-0000-0000-0000-000000000004"
                )!
            ),
            epochID: "client-notification-preferences"
        )
        let client = LocalCompetitionClient.make(
            environment: .accelerated(source: setup.source),
            storeAvailability: .available(setup.store),
            configuration: .testing,
            notificationCoordinatorFactory: { _ in notifications.client },
            notificationPreferences: preferences
        )
        let identity = LocalCompetitionIdentity.opponentIdentity

        let initiallyMuted = try await client.loadMutedOpponentIdentities()
        XCTAssertEqual(initiallyMuted, [])
        try await client.setNotificationMuted(identity, true)

        let persistedMuted = try await client.loadMutedOpponentIdentities()
        XCTAssertEqual(persistedMuted, [identity])
        let reconcileCount = await notifications.reconcileLatestCount
        XCTAssertEqual(reconcileCount, 1)
    }

    func testMutePreferenceFailureDoesNotReconcileNotifications()
        async throws {
        let notifications = ClientNotificationCoordinatorRecorder()
        let setup = try await makePendingClient(
            id: CompetitionID(
                UUID(
                    uuidString: "71000000-0000-0000-0000-000000000005"
                )!
            ),
            epochID: "client-notification-preferences-failure"
        )
        let client = LocalCompetitionClient.make(
            environment: .accelerated(source: setup.source),
            storeAvailability: .available(setup.store),
            configuration: .testing,
            notificationCoordinatorFactory: { _ in notifications.client },
            notificationPreferences: .unavailable
        )

        do {
            try await client.setNotificationMuted(
                LocalCompetitionIdentity.opponentIdentity,
                true
            )
            XCTFail("Expected preference persistence failure")
        } catch {
            XCTAssertEqual(
                error as? CompetitionNotificationPreferencesError,
                .ioFailure
            )
        }
        let reconcileCount = await notifications.reconcileLatestCount
        XCTAssertEqual(reconcileCount, 0)
    }

    private func makeTwoAcceptedCompetitions() async throws -> (
        store: ClientTestEventStore,
        firstID: CompetitionID,
        secondID: CompetitionID,
        window: CompetitionActivityWindow,
        activeDate: Date
    ) {
        let store = ClientTestEventStore()
        let acceptedAt = Date(timeIntervalSinceReferenceDate: 800_000)
        let firstID = CompetitionID(
            UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        )
        let secondID = CompetitionID(
            UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        )
        let first = try await makeAccepted(
            store: store,
            id: firstID,
            acceptedAt: acceptedAt
        )
        _ = try await makeAccepted(
            store: store,
            id: secondID,
            acceptedAt: acceptedAt
        )
        return (store, firstID, secondID, first.window, first.activeDate)
    }

    private func makePendingClient(
        id: CompetitionID,
        epochID: String
    ) async throws -> (
        client: LocalCompetitionClient,
        source: FixtureActivitySource,
        store: ClientTestEventStore,
        id: CompetitionID
    ) {
        let store = ClientTestEventStore()
        let now = Date(timeIntervalSinceReferenceDate: 3_300_000)
        _ = try await store.create(
            try CompetitionGenesis(
                competitionID: id,
                direction: .incoming,
                createdAt: now.addingTimeInterval(-60),
                expiresAt: now.addingTimeInterval(48 * 60 * 60),
                scoringPolicy: .healthKitCompatibility,
                downwardRevisionPolicy: .maximumObserved
            )
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: now,
                    monotonic: MonotonicInstant(
                        epochID: epochID,
                        nanoseconds: 1_000
                    )
                ),
                initialDays: [],
                changes: []
            )
        )
        return (
            LocalCompetitionClient.make(
                environment: .accelerated(source: source),
                storeAvailability: .available(store),
                configuration: .testing
            ),
            source,
            store,
            id
        )
    }

    private func makeCompletedClient(
        id: CompetitionID,
        epochID: String,
        idGenerator: @escaping @Sendable (CompetitionID) -> CompetitionID = {
            LocalCompetitionIdentity.rematchID(for: $0)
        },
        notificationCoordinatorFactory: @escaping @Sendable (
            LocalCompetitionRuntime?
        ) -> CompetitionNotificationCoordinatorClient = { _ in .noop }
    ) async throws -> (
        client: LocalCompetitionClient,
        source: FixtureActivitySource,
        store: ClientTestEventStore,
        id: CompetitionID
    ) {
        let store = ClientTestEventStore()
        let accepted = try await makeAccepted(
            store: store,
            id: id,
            acceptedAt: Date(timeIntervalSinceReferenceDate: 3_400_000)
        )
        let endBoundary = try accepted.window.calendar.startOfDay(
            accepted.window.calendar.day(after: accepted.window.days[6])
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: endBoundary,
                    monotonic: MonotonicInstant(
                        epochID: epochID,
                        nanoseconds: 1_000
                    )
                ),
                initialDays: try accepted.window.days.map {
                    .snapshot(
                        day: $0,
                        snapshot: try makeSnapshot(moveValue: 300)
                    )
                },
                changes: []
            )
        )
        return (
            LocalCompetitionClient.make(
                environment: .accelerated(source: source),
                storeAvailability: .available(store),
                configuration: LocalCompetitionRuntimeConfiguration(
                    minimumStabilityNanoseconds: 1,
                    bestAvailableGrace: 0
                ),
                idGenerator: idGenerator,
                notificationCoordinatorFactory:
                    notificationCoordinatorFactory
            ),
            source,
            store,
            id
        )
    }

    private func assertStopMakesOperationInert(
        client: LocalCompetitionClient,
        source: FixtureActivitySource,
        store: ClientTestEventStore,
        trackedID: CompetitionID,
        expectedLifecycle: (LocalCompetitionLifecyclePresentation) -> Bool,
        operation: (LocalCompetitionClient) async -> LocalCompetitionPublication
    ) async throws {
        var iterator = client.start().makeAsyncIterator()
        let optionalInitial = await iterator.next()
        let initial = try XCTUnwrap(optionalInitial)
        let presentation = try XCTUnwrap(
            initial.dashboard.competitions.first { $0.id == trackedID }
        )
        XCTAssertTrue(expectedLifecycle(presentation.lifecycle))

        await client.stop()
        let finishedAtStop = await iterator.next()
        XCTAssertNil(finishedAtStop)
        let appendCount = await store.appendCount(for: trackedID)
        let createCount = await store.successfulCreateCount
        let ids = try await store.ids()
        let synchronizationCount = await source
            .summarySubscriptionSynchronizations().count
        let desiredAfterStop = await source
            .desiredSummarySubscriptionWindows()
        XCTAssertEqual(desiredAfterStop, [])

        let returned = await operation(client)
        let publicationAfterOperation = await iterator.next()

        XCTAssertEqual(returned, initial)
        XCTAssertNil(publicationAfterOperation)
        let finalAppendCount = await store.appendCount(for: trackedID)
        let finalCreateCount = await store.successfulCreateCount
        let finalIDs = try await store.ids()
        let finalSynchronizationCount = await source
            .summarySubscriptionSynchronizations().count
        let finalDesired = await source.desiredSummarySubscriptionWindows()
        XCTAssertEqual(finalAppendCount, appendCount)
        XCTAssertEqual(finalCreateCount, createCount)
        XCTAssertEqual(finalIDs, ids)
        XCTAssertEqual(finalSynchronizationCount, synchronizationCount)
        XCTAssertEqual(finalDesired, [])
    }

    private func makeAccepted(
        store: ClientTestEventStore,
        id: CompetitionID,
        acceptedAt: Date
    ) async throws -> (
        window: CompetitionActivityWindow,
        activeDate: Date
    ) {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        _ = try await store.create(
            try CompetitionGenesis(
                competitionID: id,
                direction: .outgoing,
                createdAt: acceptedAt.addingTimeInterval(-60),
                expiresAt: acceptedAt.addingTimeInterval(48 * 60 * 60),
                scoringPolicy: .healthKitCompatibility,
                downwardRevisionPolicy: .maximumObserved
            )
        )
        let optionalPending = try await store.load(id)
        let pending = try XCTUnwrap(optionalPending)
        let accepted = try CompetitionEngine().accept(
            pending.projection.competition,
            at: acceptedAt,
            timeZoneIdentifier: calendar.timeZoneIdentifier,
            opponent: OpponentPlanGenerationRequest(
                seed: LocalCompetitionIdentity.opponentSeed(for: id),
                generatorVersion: .v1,
                difficulty: .balanced
            )
        )
        _ = try await store.append(
            [.lifecycle(accepted)],
            to: id,
            expectedCursor: pending.journal.cursor
        )
        let optionalLoaded = try await store.load(id)
        let loaded = try XCTUnwrap(optionalLoaded)
        let schedule = try XCTUnwrap(loaded.projection.competition.schedule)
        return (
            try CompetitionActivityWindow(
                calendar: schedule.calendar,
                startDay: schedule.startDay
            ),
            try schedule.calendar.startOfDay(schedule.startDay)
                .addingTimeInterval(12 * 60 * 60)
        )
    }

    private func terminalPresentation(
        id: CompetitionID,
        outcome: CompetitionOutcome,
        completedAt: Date
    ) -> LocalCompetitionPresentation {
        LocalCompetitionPresentation(
            id: id,
            ownerDisplayName: "Naren",
            opponentDisplayName: "Alex",
            lifecycle: .completed(
                outcome: outcome,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: completedAt
            ),
            acceptedConfiguration: nil,
            userPoints: outcome == .win ? 300 : 200,
            opponentPoints: outcome == .loss ? 300 : 200,
            days: [],
            currentDayOrdinal: nil,
            lastRefresh: nil,
            tally: nil,
            terminalResult: LocalCompetitionTerminalPresentation(
                userPoints: outcome == .win ? 300 : 200,
                opponentPoints: outcome == .loss ? 300 : 200,
                outcome: outcome,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: completedAt
            )
        )
    }

    private func makePublication(
        revision: UInt64
    ) -> LocalCompetitionPublication {
        LocalCompetitionPublication(
            publicationRevision: revision,
            dashboard: LocalCompetitionDashboard(
                competitions: [],
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0
            )
        )
    }

    private func makeSnapshot(moveValue: Double) throws -> ActivitySnapshot {
        ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: moveValue, goal: 500),
            exercise: try ActivityRingReading(value: 30, goal: 30),
            standOrRoll: try ActivityRingReading(value: 12, goal: 12),
            pauseState: .running
        )
    }

    private func nextPublication(
        from stream: AsyncStream<LocalCompetitionPublication>
    ) async -> LocalCompetitionPublication {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? makePublication(revision: 0)
    }
}

private actor ClientPublicationCapture {
    private var publications: [LocalCompetitionPublication] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var count: Int { publications.count }

    func receive(_ publication: LocalCompetitionPublication) {
        publications.append(publication)
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func first(_ count: Int) async -> [LocalCompetitionPublication] {
        while publications.count < count {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        return Array(publications.prefix(count))
    }
}

private actor ClientNotificationCoordinatorRecorder {
    private var snapshots: [CompetitionNotificationPlanningSnapshot] = []
    private var submissionWaiters: [CheckedContinuation<Void, Never>] = []
    private var submissionReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private let blockSubmissions: Bool
    private let blockCancellation: Bool
    private(set) var cancelledIDs: [CompetitionID] = []
    private(set) var reconcileLatestCount = 0

    init(
        blockSubmissions: Bool = false,
        blockCancellation: Bool = false
    ) {
        self.blockSubmissions = blockSubmissions
        self.blockCancellation = blockCancellation
    }

    nonisolated var client: CompetitionNotificationCoordinatorClient {
        CompetitionNotificationCoordinatorClient(
            submit: { [weak self] snapshot in
                await self?.record(snapshot)
            },
            reconcileLatest: { [weak self] in
                await self?.recordReconcileLatest()
            },
            cancelAll: { [weak self] id in
                await self?.recordCancellation(id)
            }
        )
    }

    func snapshot(at index: Int) async -> CompetitionNotificationPlanningSnapshot {
        while snapshots.count <= index {
            await withCheckedContinuation { continuation in
                submissionWaiters.append(continuation)
            }
        }
        return snapshots[index]
    }

    func waitUntilSubmissionStarted() async {
        while snapshots.isEmpty {
            await withCheckedContinuation { continuation in
                submissionWaiters.append(continuation)
            }
        }
    }

    func releaseSubmissions() {
        for waiter in submissionReleaseWaiters { waiter.resume() }
        submissionReleaseWaiters.removeAll()
    }

    func waitUntilCancellationStarted() async {
        while cancelledIDs.isEmpty {
            await withCheckedContinuation { continuation in
                cancellationWaiters.append(continuation)
            }
        }
    }

    func releaseCancellation() {
        for waiter in cancellationReleaseWaiters { waiter.resume() }
        cancellationReleaseWaiters.removeAll()
    }

    private func record(_ snapshot: CompetitionNotificationPlanningSnapshot) async {
        snapshots.append(snapshot)
        for waiter in submissionWaiters { waiter.resume() }
        submissionWaiters.removeAll()
        if blockSubmissions {
            await withCheckedContinuation { continuation in
                submissionReleaseWaiters.append(continuation)
            }
        }
    }

    private func recordReconcileLatest() {
        reconcileLatestCount += 1
    }

    private func recordCancellation(_ id: CompetitionID) async {
        cancelledIDs.append(id)
        for waiter in cancellationWaiters { waiter.resume() }
        cancellationWaiters.removeAll()
        if blockCancellation {
            await withCheckedContinuation { continuation in
                cancellationReleaseWaiters.append(continuation)
            }
        }
    }
}

private actor ClientNotificationCenterRecorder {
    private var posts: [CompetitionImmediateNotificationRequest] = []
    private var postWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated var client: CompetitionNotificationClient {
        CompetitionNotificationClient(
            requestAuthorization: { true },
            authorizationState: { .authorized },
            upsert: { _ in },
            postNow: { [weak self] request in
                await self?.record(request)
            },
            pendingIDs: { _ in [] },
            deliveredIDs: { _ in [] },
            removePending: { _ in },
            removeDelivered: { _ in }
        )
    }

    var postCount: Int { posts.count }

    func post(at index: Int) async -> CompetitionImmediateNotificationRequest {
        while posts.count <= index {
            await withCheckedContinuation { continuation in
                postWaiters.append(continuation)
            }
        }
        return posts[index]
    }

    private func record(_ request: CompetitionImmediateNotificationRequest) {
        posts.append(request)
        for waiter in postWaiters { waiter.resume() }
        postWaiters.removeAll()
    }
}

private extension CompetitionNotificationPolicy {
    static var clientIntegrationFixture: Self {
        Self(
            maximumPostsPerEvaluation: 1,
            maximumPostsPerCompetitionDay: 2,
            scheduledFireDate: { _, baseDate, _ in baseDate },
            isCloseScore: { _, _ in false },
            isDailyMaximum: { _ in false },
            priority: { family in family == .result ? 1 : 0 },
            content: { message in
                CompetitionNotificationContent(
                    title: message.family.rawValue,
                    body: "fixture"
                )
            }
        )
    }
}

private actor ClientTestEventStore: CompetitionEventStore {
    private var journals: [CompetitionID: CompetitionJournal] = [:]
    private var tombstonedIDs: Set<CompetitionID> = []
    private var appendCounts: [CompetitionID: Int] = [:]
    private(set) var successfulCreateCount = 0

    func ids() async throws -> [CompetitionID] {
        journals.keys.sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
    }

    func load(_ id: CompetitionID) async throws -> LoadedCompetitionJournal? {
        guard let journal = journals[id] else { return nil }
        return try LoadedCompetitionJournal(journal: journal, source: .primary)
    }

    func create(
        _ genesis: CompetitionGenesis
    ) async throws -> CompetitionEventStoreCreateResult {
        guard !tombstonedIDs.contains(genesis.competitionID) else {
            throw CompetitionEventStoreError.identityWasDeleted
        }
        if let existing = journals[genesis.competitionID] {
            guard existing.genesis == genesis else {
                throw CompetitionEventStoreError.identityAlreadyExists
            }
            return CompetitionEventStoreCreateResult(
                cursor: existing.cursor,
                created: false
            )
        }
        let journal = try CompetitionJournal(genesis: genesis)
        journals[genesis.competitionID] = journal
        successfulCreateCount += 1
        return CompetitionEventStoreCreateResult(
            cursor: journal.cursor,
            created: true
        )
    }

    func append(
        _ events: [CompetitionDomainEvent],
        to id: CompetitionID,
        expectedCursor: CompetitionJournalCursor
    ) async throws -> CompetitionJournalAppendResult {
        guard var journal = journals[id] else {
            throw CompetitionEventStoreError.identityNotFound
        }
        guard journal.cursor == expectedCursor else {
            throw CompetitionEventStoreError.cursorConflict(
                expected: expectedCursor,
                actual: journal.cursor
            )
        }
        do {
            let result = try journal.append(events, expectedCursor: expectedCursor)
            journals[id] = journal
            appendCounts[id, default: 0] += 1
            return result
        } catch let error as CompetitionJournalError {
            throw CompetitionEventStoreError.journal(error)
        }
    }

    func delete(
        _ id: CompetitionID,
        expectedCursor: CompetitionJournalCursor
    ) async throws {
        guard let journal = journals[id] else {
            throw CompetitionEventStoreError.identityNotFound
        }
        guard journal.cursor == expectedCursor else {
            throw CompetitionEventStoreError.cursorConflict(
                expected: expectedCursor,
                actual: journal.cursor
            )
        }
        journals[id] = nil
        tombstonedIDs.insert(id)
    }

    func appendCount(for id: CompetitionID) -> Int {
        appendCounts[id, default: 0]
    }
}
