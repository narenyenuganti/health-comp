import CompetitionCore
import XCTest
@testable import HealthComp

final class LocalCompetitionRuntimeTests: XCTestCase {
    func testDesiredWindowsShareOneWindowUntilLastCompetitionIsTerminal() async throws {
        let first = try await makeAcceptedCompetition(conflictOnce: false)
        let second = try await makeAcceptedCompetition(
            conflictOnce: false,
            store: first.store,
            competitionUUID: UUID(
                uuidString: "01000000-0000-0000-0000-000000000002"
            )!
        )
        let endBoundary = try first.window.calendar.startOfDay(
            first.window.calendar.day(after: first.window.days[6])
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: endBoundary.addingTimeInterval(1),
                    monotonic: MonotonicInstant(
                        epochID: "desired-windows",
                        nanoseconds: 10_000
                    )
                ),
                initialDays: try first.window.days.map {
                    .snapshot(
                        day: $0,
                        snapshot: try makeSnapshot(moveValue: 300)
                    )
                },
                changes: []
            )
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(source: source),
            store: first.store,
            configuration: LocalCompetitionRuntimeConfiguration(
                minimumStabilityNanoseconds: 1,
                bestAvailableGrace: 0
            )
        )
        var loaded = await runtime.loadAll().successfulJournals
        var desired = await runtime.desiredActivityWindows(in: loaded)
        XCTAssertEqual(desired, [first.window])

        _ = try await runtime.refresh(
            competitionID: first.competitionID,
            trigger: .reconciliationProbe
        )
        loaded = await runtime.loadAll().successfulJournals
        desired = await runtime.desiredActivityWindows(in: loaded)
        XCTAssertEqual(desired, [second.window])

        _ = try await runtime.refresh(
            competitionID: second.competitionID,
            trigger: .reconciliationProbe
        )
        _ = try await runtime.archive(competitionID: first.competitionID)
        loaded = await runtime.loadAll().successfulJournals
        desired = await runtime.desiredActivityWindows(in: loaded)
        XCTAssertEqual(desired, [])
    }

    func testNextWakeChoosesStabilityBeforePendingBoundaryAndFallback() async throws {
        let tally = try await makeAcceptedCompetition(conflictOnce: false)
        let firstReadDate = try tally.window.calendar.startOfDay(
            tally.window.calendar.day(after: tally.window.days[6])
        ).addingTimeInterval(1)
        let secondReadDate = firstReadDate.addingTimeInterval(60)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: firstReadDate,
                    monotonic: MonotonicInstant(
                        epochID: "next-wake",
                        nanoseconds: 1_000
                    )
                ),
                initialDays: try tally.window.days.map {
                    .snapshot(
                        day: $0,
                        snapshot: try makeSnapshot(moveValue: 300)
                    )
                },
                changes: []
            )
        )
        let configuration = LocalCompetitionRuntimeConfiguration(
            minimumStabilityNanoseconds: 15 * 60 * 1_000_000_000,
            bestAvailableGrace: 24 * 60 * 60
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(source: source),
            store: tally.store,
            configuration: configuration
        )
        _ = try await runtime.refresh(
            competitionID: tally.competitionID,
            trigger: .reconciliationProbe
        )
        try await source.advance(to: secondReadDate)
        _ = try await runtime.refresh(
            competitionID: tally.competitionID,
            trigger: .reconciliationProbe
        )

        let pendingID = CompetitionID(
            UUID(uuidString: "02000000-0000-0000-0000-000000000002")!
        )
        _ = try await runtime.create(
            try CompetitionGenesis(
                competitionID: pendingID,
                direction: .incoming,
                createdAt: secondReadDate,
                expiresAt: secondReadDate.addingTimeInterval(20 * 60),
                scoringPolicy: .healthKitCompatibility,
                downwardRevisionPolicy: .maximumObserved
            )
        )
        let scheduledID = CompetitionID(
            UUID(uuidString: "02000000-0000-0000-0000-000000000003")!
        )
        _ = try await runtime.create(
            try CompetitionGenesis(
                competitionID: scheduledID,
                direction: .outgoing,
                createdAt: secondReadDate,
                expiresAt: secondReadDate.addingTimeInterval(48 * 60 * 60),
                scoringPolicy: .healthKitCompatibility,
                downwardRevisionPolicy: .maximumObserved
            )
        )
        _ = try await runtime.accept(
            competitionID: scheduledID,
            opponent: OpponentPlanGenerationRequest(
                seed: 42,
                generatorVersion: .v1,
                difficulty: .balanced
            )
        )
        let loaded = await runtime.loadAll().successfulJournals
        let context = await source.context()

        let wake = await runtime.nextWake(in: loaded, context: context)

        XCTAssertEqual(
            wake,
            firstReadDate.addingTimeInterval(15 * 60)
        )
    }

    func testNextWakeDoesNotSpinAfterStabilityTargetWhenLatestReadIsIncomplete() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let firstReadDate = try setup.window.calendar.startOfDay(
            setup.window.calendar.day(after: setup.window.days[6])
        ).addingTimeInterval(1)
        let currentDate = firstReadDate.addingTimeInterval(11)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: firstReadDate,
                    monotonic: MonotonicInstant(
                        epochID: "next-wake-incomplete",
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
                        at: currentDate,
                        updates: [.missing(day: setup.window.days[6])],
                        triggers: []
                    ),
                ]
            )
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(source: source),
            store: setup.store,
            configuration: LocalCompetitionRuntimeConfiguration(
                minimumStabilityNanoseconds: 10_000_000_000,
                bestAvailableGrace: 60 * 60
            )
        )
        _ = try await runtime.refresh(
            competitionID: setup.competitionID,
            trigger: .reconciliationProbe
        )
        try await source.advance(to: currentDate)
        let latest = try await runtime.refresh(
            competitionID: setup.competitionID,
            trigger: .reconciliationProbe
        )
        guard case let .tallying(tallying) =
            latest.projection.competition.lifecycle
        else {
            return XCTFail("Expected tallying after an incomplete reread")
        }
        XCTAssertNotNil(tallying.reconciliation.stabilityStart)
        XCTAssertNil(
            tallying.reconciliation.latestAttempt?.completeWindowContent
        )

        let wake = await runtime.nextWake(
            in: [latest],
            context: await source.context()
        )

        XCTAssertNotNil(wake)
        XCTAssertGreaterThan(try XCTUnwrap(wake), currentDate)
    }

    func testNextWakeDoesNotSpinWhenMonotonicEpochChanges() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let firstReadDate = try setup.window.calendar.startOfDay(
            setup.window.calendar.day(after: setup.window.days[6])
        ).addingTimeInterval(1)
        let currentDate = firstReadDate.addingTimeInterval(11)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: firstReadDate,
                    monotonic: MonotonicInstant(
                        epochID: "next-wake-old-epoch",
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
                        at: currentDate,
                        updates: [],
                        triggers: [],
                        epochID: "next-wake-new-epoch",
                        resetMonotonicNanoseconds: 1
                    ),
                ]
            )
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(source: source),
            store: setup.store,
            configuration: LocalCompetitionRuntimeConfiguration(
                minimumStabilityNanoseconds: 10_000_000_000,
                bestAvailableGrace: 60 * 60
            )
        )
        let loaded = try await runtime.refresh(
            competitionID: setup.competitionID,
            trigger: .reconciliationProbe
        )
        try await source.advance(to: currentDate)

        let wake = await runtime.nextWake(
            in: [loaded],
            context: await source.context()
        )

        XCTAssertNotNil(wake)
        XCTAssertGreaterThan(try XCTUnwrap(wake), currentDate)
    }

    func testLaterCompetitionUsesItsOwnBestAvailableDeadline() async throws {
        let firstAcceptedAt = try date(
            year: 2026,
            month: 5,
            day: 1,
            hour: 12
        )
        let secondAcceptedAt = firstAcceptedAt.addingTimeInterval(7 * 86_400)
        let first = try await makeAcceptedCompetition(
            conflictOnce: false,
            acceptedAt: firstAcceptedAt
        )
        let second = try await makeAcceptedCompetition(
            conflictOnce: false,
            store: first.store,
            competitionUUID: UUID(
                uuidString: "10000000-0000-0000-0000-000000000002"
            )!,
            acceptedAt: secondAcceptedAt
        )
        let secondEnd = try second.window.calendar.startOfDay(
            second.window.calendar.day(after: second.window.days[6])
        )
        let readDate = secondEnd.addingTimeInterval(60 * 60)
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(
                fixture: try ActivityFixture(
                    initialInstant: EnvironmentInstant(
                        wallDate: readDate,
                        monotonic: MonotonicInstant(
                            epochID: "per-competition-deadline",
                            nanoseconds: 1_000
                        )
                    ),
                    initialDays: try second.window.days.map {
                        .snapshot(
                            day: $0,
                            snapshot: try makeSnapshot(moveValue: 300)
                        )
                    },
                    changes: []
                )
            ),
            store: first.store,
            configuration: LocalCompetitionRuntimeConfiguration(
                minimumStabilityNanoseconds: 15 * 60 * 1_000_000_000,
                bestAvailableGrace: 24 * 60 * 60
            )
        )

        let loaded = try await runtime.refresh(
            competitionID: second.competitionID,
            trigger: .reconciliationProbe
        )

        guard case .tallying = loaded.projection.competition.lifecycle else {
            return XCTFail(
                "A first complete read one hour after this competition ended must not finalize"
            )
        }
        let firstEnd = try first.window.calendar.startOfDay(
            first.window.calendar.day(after: first.window.days[6])
        )
        XCTAssertGreaterThan(readDate, firstEnd.addingTimeInterval(24 * 60 * 60))
    }

    func testHandleAllEnumeratesTwoIDsAndCompletesExactlyOnce() async throws {
        let first = try await makeAcceptedCompetition(conflictOnce: false)
        let second = try await makeAcceptedCompetition(
            conflictOnce: false,
            store: first.store,
            competitionUUID: UUID(
                uuidString: "20000000-0000-0000-0000-000000000002"
            )!
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: first.activeDate,
                    monotonic: MonotonicInstant(
                        epochID: "handle-all-two",
                        nanoseconds: 1_000
                    )
                ),
                initialDays: [],
                changes: []
            )
        )
        let runtime = makeRuntime(source: source, store: first.store)
        let signal = EnvironmentSignal(
            id: "handle-all-two",
            trigger: .observerWakeupBackground,
            requiresCompletion: true
        )

        let outcome = await runtime.handleAll(signal)

        XCTAssertNil(outcome.enumerationFailure)
        XCTAssertEqual(
            Set(outcome.successfulJournals.map(\.projection.competition.id)),
            Set([first.competitionID, second.competitionID])
        )
        XCTAssertTrue(outcome.failures.isEmpty)
        let completionCount = await source.signalCompletionCount(signal.id)
        XCTAssertEqual(completionCount, 1)
    }

    func testHandleAllEmptyEnumerationStillCompletesExactlyOnce() async throws {
        let store = RuntimeTestEventStore()
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: Date(timeIntervalSinceReferenceDate: 1_000),
                    monotonic: MonotonicInstant(
                        epochID: "handle-all-empty",
                        nanoseconds: 1_000
                    )
                ),
                initialDays: [],
                changes: []
            )
        )
        let runtime = makeRuntime(source: source, store: store)
        let signal = EnvironmentSignal(
            id: "handle-all-empty",
            trigger: .summaryUpdate,
            requiresCompletion: false
        )

        let outcome = await runtime.handleAll(signal)

        XCTAssertNil(outcome.enumerationFailure)
        XCTAssertTrue(outcome.outcomes.isEmpty)
        let completionCount = await source.signalCompletionCount(signal.id)
        XCTAssertEqual(completionCount, 1)
    }

    func testHandleAllReportsPartialFailureAfterAttemptingEveryID() async throws {
        let first = try await makeAcceptedCompetition(conflictOnce: false)
        let second = try await makeAcceptedCompetition(
            conflictOnce: false,
            store: first.store,
            competitionUUID: UUID(
                uuidString: "30000000-0000-0000-0000-000000000002"
            )!
        )
        await first.store.failAppends(for: first.competitionID)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: first.activeDate,
                    monotonic: MonotonicInstant(
                        epochID: "handle-all-partial",
                        nanoseconds: 1_000
                    )
                ),
                initialDays: [],
                changes: []
            )
        )
        let runtime = makeRuntime(source: source, store: first.store)
        let signal = EnvironmentSignal(
            id: "handle-all-partial",
            trigger: .observerWakeupBackground,
            requiresCompletion: true
        )

        let outcome = await runtime.handleAll(signal)

        XCTAssertEqual(outcome.successfulJournals.count, 1)
        XCTAssertEqual(
            outcome.successfulJournals.first?.projection.competition.id,
            second.competitionID
        )
        XCTAssertEqual(outcome.failures.map(\.competitionID), [first.competitionID])
        let completionCount = await source.signalCompletionCount(signal.id)
        XCTAssertEqual(completionCount, 1)
        let optionalPersistedSecond = try await first.store.load(
            second.competitionID
        )
        let persistedSecond = try XCTUnwrap(optionalPersistedSecond)
        XCTAssertNotNil(persistedSecond.projection.activityRefresh.latestAttempt)
    }

    func testHandleAllEnumerationFailureIsClosedAndCompletesExactlyOnce() async throws {
        let store = RuntimeTestEventStore()
        await store.failIDEnumeration()
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: Date(timeIntervalSinceReferenceDate: 1_000),
                    monotonic: MonotonicInstant(
                        epochID: "handle-all-enumeration-failure",
                        nanoseconds: 1_000
                    )
                ),
                initialDays: [],
                changes: []
            )
        )
        let runtime = makeRuntime(source: source, store: store)
        let signal = EnvironmentSignal(
            id: "handle-all-enumeration-failure",
            trigger: .observerWakeupBackground,
            requiresCompletion: true
        )

        let outcome = await runtime.handleAll(signal)

        XCTAssertEqual(outcome.enumerationFailure, .storageUnavailable)
        XCTAssertTrue(outcome.outcomes.isEmpty)
        let completionCount = await source.signalCompletionCount(signal.id)
        XCTAssertEqual(completionCount, 1)
    }

    func testAcceptUsesAtomicFixtureZoneAndRequestedStableSeed() async throws {
        let now = try date(year: 2026, month: 7, day: 1, hour: 12)
        let id = CompetitionID(
            UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        )
        let store = RuntimeTestEventStore()
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(
                fixture: try ActivityFixture(
                    initialInstant: EnvironmentInstant(
                        wallDate: now,
                        monotonic: MonotonicInstant(
                            epochID: "accept-zone",
                            nanoseconds: 1_000
                        )
                    ),
                    timeZoneIdentifier: "Pacific/Kiritimati",
                    initialDays: [],
                    changes: []
                )
            ),
            store: store,
            configuration: .testing
        )
        _ = try await runtime.create(
            try CompetitionGenesis(
                competitionID: id,
                direction: .outgoing,
                createdAt: now.addingTimeInterval(-60),
                expiresAt: now.addingTimeInterval(60),
                scoringPolicy: .healthKitCompatibility,
                downwardRevisionPolicy: .maximumObserved
            )
        )
        let request = OpponentPlanGenerationRequest(
            seed: 0x0123_4567_89ab_cdef,
            generatorVersion: .v1,
            difficulty: .balanced
        )

        let accepted = try await runtime.accept(
            competitionID: id,
            opponent: request
        )

        XCTAssertEqual(
            accepted.projection.competition.schedule?.calendar.timeZoneIdentifier,
            "Pacific/Kiritimati"
        )
        XCTAssertEqual(accepted.projection.competition.opponentPlan?.seed, request.seed)
        XCTAssertEqual(
            accepted.projection.competition.opponentPlan?.difficulty,
            .balanced
        )
    }

    func testDeclineLetsExpiryWinAtTheBoundary() async throws {
        let expiry = try date(year: 2026, month: 7, day: 2, hour: 12)
        let id = CompetitionID(
            UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        )
        let store = RuntimeTestEventStore()
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(
                fixture: try ActivityFixture(
                    initialInstant: EnvironmentInstant(
                        wallDate: expiry,
                        monotonic: MonotonicInstant(
                            epochID: "decline-expiry",
                            nanoseconds: 1_000
                        )
                    ),
                    initialDays: [],
                    changes: []
                )
            ),
            store: store,
            configuration: .testing
        )
        _ = try await runtime.create(
            try CompetitionGenesis(
                competitionID: id,
                direction: .incoming,
                createdAt: expiry.addingTimeInterval(-60),
                expiresAt: expiry,
                scoringPolicy: .healthKitCompatibility,
                downwardRevisionPolicy: .maximumObserved
            )
        )

        let declined = try await runtime.decline(competitionID: id)

        XCTAssertEqual(
            declined.projection.competition.lifecycle,
            .expired(at: expiry)
        )
    }

    func testRefreshThenArchiveShareOneMutationGate() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let endBoundary = try setup.window.calendar.startOfDay(
            setup.window.calendar.day(after: setup.window.days[6])
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: endBoundary.addingTimeInterval(1),
                    monotonic: MonotonicInstant(
                        epochID: "runtime-command-gate",
                        nanoseconds: 10_000
                    )
                ),
                initialDays: try setup.window.days.map {
                    .snapshot(
                        day: $0,
                        snapshot: try makeSnapshot(moveValue: 300)
                    )
                },
                changes: []
            )
        )
        await source.blockNextRead()
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(source: source),
            store: setup.store,
            configuration: LocalCompetitionRuntimeConfiguration(
                minimumStabilityNanoseconds: 15 * 60 * 1_000_000_000,
                bestAvailableGrace: 0
            )
        )
        let refresh = Task {
            try await runtime.refresh(
                competitionID: setup.competitionID,
                trigger: .reconciliationProbe
            )
        }
        await source.waitUntilReadIsBlocked()
        let archive = Task {
            try await runtime.archive(competitionID: setup.competitionID)
        }
        for _ in 0..<100 { await Task.yield() }
        await source.releaseBlockedRead()

        let refreshed = try await refresh.value
        let archived = try await archive.value

        guard case .completed = refreshed.projection.competition.lifecycle else {
            return XCTFail("The refresh should complete before archive runs")
        }
        guard case .archived = archived.projection.competition.lifecycle else {
            return XCTFail("Archive must observe the refresh commit")
        }
        _ = try CompetitionReplayer.replay(archived.journal)
    }

    func testRematchCreatesNewGenesisWithoutMutatingSourceJournal() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let endBoundary = try setup.window.calendar.startOfDay(
            setup.window.calendar.day(after: setup.window.days[6])
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: endBoundary.addingTimeInterval(1),
                    monotonic: MonotonicInstant(
                        epochID: "runtime-rematch",
                        nanoseconds: 10_000
                    )
                ),
                initialDays: try setup.window.days.map {
                    .snapshot(
                        day: $0,
                        snapshot: try makeSnapshot(moveValue: 300)
                    )
                },
                changes: []
            )
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(source: source),
            store: setup.store,
            configuration: LocalCompetitionRuntimeConfiguration(
                minimumStabilityNanoseconds: 1,
                bestAvailableGrace: 0
            )
        )
        _ = try await runtime.refresh(
            competitionID: setup.competitionID,
            trigger: .reconciliationProbe
        )
        let optionalSourceBefore = try await setup.store.load(
            setup.competitionID
        )
        let sourceBefore = try XCTUnwrap(optionalSourceBefore).journal
        let newID = CompetitionID(
            UUID(uuidString: "60000000-0000-0000-0000-000000000002")!
        )

        let rematch = try await runtime.createRematch(
            from: setup.competitionID,
            newID: newID,
            expiresAt: endBoundary.addingTimeInterval(48 * 60 * 60)
        )

        XCTAssertEqual(rematch.journal.genesis.competitionID, newID)
        XCTAssertEqual(rematch.journal.genesis.direction, .outgoing)
        XCTAssertEqual(rematch.journal.genesis.scoringPolicy, .healthKitCompatibility)
        let sourceAfter = try await setup.store.load(setup.competitionID)?.journal
        XCTAssertEqual(sourceAfter, sourceBefore)
    }

    func testReadCrossingEndBoundaryCatchesUpClockBeforeFinalRead() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let endBoundary = try setup.window.calendar.startOfDay(
            setup.window.calendar.day(after: setup.window.days[6])
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: endBoundary.addingTimeInterval(-1),
                    monotonic: MonotonicInstant(
                        epochID: "runtime-boundary",
                        nanoseconds: 1_000
                    )
                ),
                initialDays: try setup.window.days.map {
                    .snapshot(
                        day: $0,
                        snapshot: try makeSnapshot(moveValue: 300)
                    )
                },
                changes: []
            )
        )
        await source.blockNextRead()
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(source: source),
            store: setup.store,
            finalizationPolicy: FinalizationPolicy(
                minimumStabilityNanoseconds: 10_000,
                bestAvailableDeadline: .distantFuture
            )
        )

        let refresh = Task {
            try await runtime.refresh(
                competitionID: setup.competitionID,
                trigger: .dayBoundary
            )
        }
        await source.waitUntilReadIsBlocked()
        try await source.advance(
            to: endBoundary.addingTimeInterval(1)
        )
        await source.releaseBlockedRead()
        let loaded = try await refresh.value

        guard case let .tallying(tallying) =
            loaded.projection.competition.lifecycle
        else {
            return XCTFail("Expected clock catch-up through the read instant")
        }
        XCTAssertNotNil(tallying.reconciliation.latestAttempt)
        XCTAssertEqual(
            tallying.reconciliation.latestAttempt?.readAt,
            endBoundary.addingTimeInterval(1)
        )
    }

    func testConcurrentSignalsCoalesceIntoAtMostOneFollowUpRefresh() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: setup.activeDate,
                    monotonic: MonotonicInstant(
                        epochID: "runtime-coalescing",
                        nanoseconds: 7_000
                    )
                ),
                initialDays: [
                    .snapshot(
                        day: setup.window.days[0],
                        snapshot: try makeSnapshot(moveValue: 300)
                    ),
                ],
                changes: []
            )
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(source: source),
            store: setup.store,
            finalizationPolicy: FinalizationPolicy(
                minimumStabilityNanoseconds: 1,
                bestAvailableDeadline: .distantFuture
            )
        )
        await setup.store.blockNextAppend()
        let firstSignal = EnvironmentSignal(
            id: "coalesced-0",
            trigger: .summaryUpdate,
            requiresCompletion: true
        )
        let first = Task {
            try await runtime.handle(
                firstSignal,
                competitionID: setup.competitionID
            )
        }
        await setup.store.waitUntilAppendIsBlocked()

        let followerCount = 8
        let started = RuntimeTaskStartLatch(count: followerCount)
        let followers = (1...followerCount).map { ordinal in
            let signal = EnvironmentSignal(
                id: "coalesced-\(ordinal)",
                trigger: .observerWakeupBackground,
                requiresCompletion: true
            )
            return Task {
                await started.arrive()
                return try await runtime.handle(
                    signal,
                    competitionID: setup.competitionID
                )
            }
        }
        await started.waitUntilAllStarted()
        for _ in 0..<100 { await Task.yield() }
        await setup.store.releaseBlockedAppend()

        _ = try await first.value
        for follower in followers {
            _ = try await follower.value
        }
        let allAppendAttempts = await setup.store.appendAttempts()
        let refreshAppendAttempts = allAppendAttempts.dropFirst()
        XCTAssertLessThanOrEqual(refreshAppendAttempts.count, 2)
        for ordinal in 0...followerCount {
            let completed = await source.didCompleteSignal(
                "coalesced-\(ordinal)"
            )
            XCTAssertTrue(completed)
        }
    }

    func testInvalidSourceResponsePersistsDistinctFailureWithoutSourceData() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let fixture = try ActivityFixture(
            initialInstant: EnvironmentInstant(
                wallDate: setup.activeDate,
                monotonic: MonotonicInstant(
                    epochID: "runtime-invalid-response",
                    nanoseconds: 6_000
                )
            ),
            initialDays: [],
            initialReadState: .failure(.invalidResponse),
            changes: []
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(fixture: fixture),
            store: setup.store,
            finalizationPolicy: FinalizationPolicy(
                minimumStabilityNanoseconds: 1,
                bestAvailableDeadline: .distantFuture
            )
        )

        let loaded = try await runtime.refresh(
            competitionID: setup.competitionID,
            trigger: .foreground
        )
        let refresh = try XCTUnwrap(
            loaded.projection.activityRefresh.latestAttempt
        )

        XCTAssertEqual(
            refresh.readStatus,
            .failed(reason: .invalidResponse)
        )
        XCTAssertEqual(
            refresh.days[0].availability,
            .unavailable(reason: .invalidSourceData)
        )
        XCTAssertTrue(
            refresh.days.dropFirst().allSatisfy {
                $0.availability == .notYetOccurred
            }
        )
        XCTAssertFalse(
            refresh.days.contains {
                switch $0.availability {
                case .observed, .missing:
                    return true
                case .notYetOccurred, .unavailable:
                    return false
                }
            }
        )
    }

    func testAttemptIdentityDoesNotRepeatAfterRuntimeRelaunch() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let fixture = try ActivityFixture(
            initialInstant: EnvironmentInstant(
                wallDate: setup.activeDate,
                monotonic: MonotonicInstant(
                    epochID: "runtime-relaunch",
                    nanoseconds: 5_000
                )
            ),
            initialDays: [
                .snapshot(
                    day: setup.window.days[0],
                    snapshot: try makeSnapshot(moveValue: 300)
                ),
            ],
            changes: []
        )
        let environment = CompetitionEnvironmentClient.accelerated(
            fixture: fixture
        )
        let policy = FinalizationPolicy(
            minimumStabilityNanoseconds: 1,
            bestAvailableDeadline: .distantFuture
        )
        let firstRuntime = LocalCompetitionRuntime(
            environment: environment,
            store: setup.store,
            finalizationPolicy: policy
        )
        let first = try await firstRuntime.refresh(
            competitionID: setup.competitionID,
            trigger: .foreground
        )
        let firstAttempt = try XCTUnwrap(
            first.projection.activityRefresh.latestAttempt
        )

        let relaunchedRuntime = LocalCompetitionRuntime(
            environment: environment,
            store: setup.store,
            finalizationPolicy: policy
        )
        let second = try await relaunchedRuntime.refresh(
            competitionID: setup.competitionID,
            trigger: .pullToRefresh
        )
        let secondAttempt = try XCTUnwrap(
            second.projection.activityRefresh.latestAttempt
        )

        XCTAssertNotEqual(firstAttempt.attemptID, secondAttempt.attemptID)
        XCTAssertEqual(secondAttempt.attemptOrdinal, 2)
    }

    func testRefreshCommitsClockThenActivityAndReusesAttemptIDAcrossCASRetry() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: true)
        let snapshot = try makeSnapshot(moveValue: 300)
        let fixture = try ActivityFixture(
            initialInstant: EnvironmentInstant(
                wallDate: setup.activeDate,
                monotonic: MonotonicInstant(
                    epochID: "runtime-test",
                    nanoseconds: 1_000
                )
            ),
            initialDays: [
                .snapshot(day: setup.window.days[0], snapshot: snapshot),
            ],
            changes: []
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(fixture: fixture),
            store: setup.store,
            finalizationPolicy: FinalizationPolicy(
                minimumStabilityNanoseconds: 1,
                bestAvailableDeadline: .distantFuture
            )
        )

        let loaded = try await runtime.refresh(
            competitionID: setup.competitionID,
            trigger: .foreground
        )

        let attempts = await setup.store.appendAttempts()
        XCTAssertEqual(attempts.count, 3) // acceptance + failed CAS + retry
        let refreshBatches = Array(attempts.suffix(2))
        XCTAssertEqual(refreshBatches[0], refreshBatches[1])
        XCTAssertEqual(refreshBatches[1].count, 2)
        guard case let .lifecycle(clockEvent) = refreshBatches[1][0],
              case .competitionStarted = clockEvent.kind,
              case let .activityRefreshAttemptRecorded(refresh) = refreshBatches[1][1]
        else {
            return XCTFail("Expected lifecycle events before the refresh event")
        }
        XCTAssertEqual(refresh.trigger, .foreground)
        XCTAssertEqual(refresh.days.map(\.ordinal), Array(1...7))
        XCTAssertEqual(
            loaded.projection.activityRefresh.latestAttempt?.attemptID,
            refresh.attemptID
        )
        XCTAssertEqual(
            loaded.projection.scoreLedger.entry(forDayOrdinal: 1)?
                .latestEvidence.snapshot,
            snapshot
        )
    }

    func testInterveningRefreshSuppressesPreparedReadAfterCASConflict() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let staleSnapshot = try makeSnapshot(moveValue: 300)
        let newerSnapshot = try makeSnapshot(moveValue: 450)
        let fixture = try ActivityFixture(
            initialInstant: EnvironmentInstant(
                wallDate: setup.activeDate,
                monotonic: MonotonicInstant(
                    epochID: "runtime-real-cas",
                    nanoseconds: 1_000
                )
            ),
            initialDays: [
                .snapshot(
                    day: setup.window.days[0],
                    snapshot: staleSnapshot
                ),
            ],
            changes: []
        )
        let optionalBefore = try await setup.store.load(setup.competitionID)
        let before = try XCTUnwrap(optionalBefore)
        let clockEvents = try CompetitionEngine().observeClock(
            before.projection.competition,
            at: setup.activeDate
        )
        let externalRefresh = try ActivityRefreshAttemptRecorded(
            attemptID: "external-newer-refresh",
            competitionID: setup.competitionID,
            attemptOrdinal: 1,
            trigger: .summaryUpdate,
            attemptedAt: setup.activeDate.addingTimeInterval(1),
            readAt: setup.activeDate.addingTimeInterval(1),
            monotonicInstant: MonotonicInstant(
                epochID: "runtime-real-cas",
                nanoseconds: 2_000
            ),
            readStatus: .completed,
            days: setup.window.days.enumerated().map { offset, day in
                ActivityDayObservation(
                    day: day,
                    ordinal: offset + 1,
                    availability: offset == 0
                        ? .observed(newerSnapshot)
                        : .notYetOccurred
                )
            }
        )
        await setup.store.interveneBeforeNextAppend(
            clockEvents.map(CompetitionDomainEvent.lifecycle)
                + [.activityRefreshAttemptRecorded(externalRefresh)],
            to: setup.competitionID
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(fixture: fixture),
            store: setup.store,
            finalizationPolicy: FinalizationPolicy(
                minimumStabilityNanoseconds: 1,
                bestAvailableDeadline: .distantFuture
            )
        )

        let loaded = try await runtime.refresh(
            competitionID: setup.competitionID,
            trigger: .foreground
        )

        XCTAssertEqual(
            loaded.projection.activityRefresh.latestAttempt?.attemptID,
            externalRefresh.attemptID
        )
        XCTAssertEqual(
            loaded.projection.scoreLedger.entry(forDayOrdinal: 1)?
                .latestEvidence.snapshot,
            newerSnapshot
        )
        let attempts = await setup.store.appendAttempts()
        XCTAssertEqual(attempts.count, 2) // acceptance + stale runtime attempt
    }

    func testNewerFailedInterveningRefreshDoesNotDiscardCompletedPreparedRead() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let completedSnapshot = try makeSnapshot(moveValue: 450)
        let fixture = try ActivityFixture(
            initialInstant: EnvironmentInstant(
                wallDate: setup.activeDate,
                monotonic: MonotonicInstant(
                    epochID: "runtime-failed-cas",
                    nanoseconds: 1_000
                )
            ),
            initialDays: [
                .snapshot(
                    day: setup.window.days[0],
                    snapshot: completedSnapshot
                ),
            ],
            changes: []
        )
        let optionalBefore = try await setup.store.load(setup.competitionID)
        let before = try XCTUnwrap(optionalBefore)
        let clockEvents = try CompetitionEngine().observeClock(
            before.projection.competition,
            at: setup.activeDate
        )
        let failedRefresh = try ActivityRefreshAttemptRecorded(
            attemptID: "external-newer-failed-refresh",
            competitionID: setup.competitionID,
            attemptOrdinal: 1,
            trigger: .observerWakeupBackground,
            attemptedAt: setup.activeDate.addingTimeInterval(1),
            readAt: setup.activeDate.addingTimeInterval(1),
            monotonicInstant: MonotonicInstant(
                epochID: "runtime-failed-cas",
                nanoseconds: 2_000
            ),
            readStatus: .failed(reason: .transientFailure),
            days: setup.window.days.enumerated().map { offset, day in
                ActivityDayObservation(
                    day: day,
                    ordinal: offset + 1,
                    availability: offset == 0
                        ? .unavailable(reason: .sourceDataUnavailable)
                        : .notYetOccurred
                )
            }
        )
        await setup.store.interveneBeforeNextAppend(
            clockEvents.map(CompetitionDomainEvent.lifecycle)
                + [.activityRefreshAttemptRecorded(failedRefresh)],
            to: setup.competitionID
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(fixture: fixture),
            store: setup.store,
            finalizationPolicy: FinalizationPolicy(
                minimumStabilityNanoseconds: 1,
                bestAvailableDeadline: .distantFuture
            )
        )

        let loaded = try await runtime.refresh(
            competitionID: setup.competitionID,
            trigger: .foreground
        )

        XCTAssertEqual(
            loaded.projection.activityRefresh.latestAttempt?.attemptOrdinal,
            2
        )
        XCTAssertEqual(
            loaded.projection.activityRefresh.latestAttempt?.readStatus,
            .completed
        )
        XCTAssertEqual(
            loaded.projection.scoreLedger.entry(forDayOrdinal: 1)?
                .latestEvidence.snapshot,
            completedSnapshot
        )
        let attempts = await setup.store.appendAttempts()
        XCTAssertEqual(attempts.count, 3) // acceptance + conflict + completed retry
    }

    func testFailedLatestAttemptDoesNotHideNewerDurableCompletedReadDuringCAS() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let preparedSnapshot = try makeSnapshot(moveValue: 300)
        let durableSnapshot = try makeSnapshot(moveValue: 450)
        let preparedReadDate = setup.activeDate.addingTimeInterval(2)
        let durableReadDate = setup.activeDate.addingTimeInterval(3)
        let failedReadDate = setup.activeDate.addingTimeInterval(4)
        let fixture = try ActivityFixture(
            initialInstant: EnvironmentInstant(
                wallDate: preparedReadDate,
                monotonic: MonotonicInstant(
                    epochID: "runtime-success-before-failure-cas",
                    nanoseconds: 2_000
                )
            ),
            initialDays: [
                .snapshot(
                    day: setup.window.days[0],
                    snapshot: preparedSnapshot
                ),
            ],
            changes: []
        )
        let optionalBefore = try await setup.store.load(setup.competitionID)
        let before = try XCTUnwrap(optionalBefore)
        let clockEvents = try CompetitionEngine().observeClock(
            before.projection.competition,
            at: durableReadDate
        )
        let completedRefresh = try ActivityRefreshAttemptRecorded(
            attemptID: "external-newer-completed-before-failure",
            competitionID: setup.competitionID,
            attemptOrdinal: 1,
            trigger: .summaryUpdate,
            attemptedAt: durableReadDate,
            readAt: durableReadDate,
            monotonicInstant: MonotonicInstant(
                epochID: "runtime-success-before-failure-cas",
                nanoseconds: 3_000
            ),
            readStatus: .completed,
            days: setup.window.days.enumerated().map { offset, day in
                ActivityDayObservation(
                    day: day,
                    ordinal: offset + 1,
                    availability: offset == 0
                        ? .observed(durableSnapshot)
                        : .notYetOccurred
                )
            }
        )
        let failedRefresh = try ActivityRefreshAttemptRecorded(
            attemptID: "external-latest-failed-after-completed",
            competitionID: setup.competitionID,
            attemptOrdinal: 2,
            trigger: .observerWakeupBackground,
            attemptedAt: failedReadDate,
            readAt: failedReadDate,
            monotonicInstant: MonotonicInstant(
                epochID: "runtime-success-before-failure-cas",
                nanoseconds: 4_000
            ),
            readStatus: .failed(reason: .transientFailure),
            days: setup.window.days.enumerated().map { offset, day in
                ActivityDayObservation(
                    day: day,
                    ordinal: offset + 1,
                    availability: offset == 0
                        ? .unavailable(reason: .sourceDataUnavailable)
                        : .notYetOccurred
                )
            }
        )
        await setup.store.interveneBeforeNextAppend(
            clockEvents.map(CompetitionDomainEvent.lifecycle) + [
                .activityRefreshAttemptRecorded(completedRefresh),
                .activityRefreshAttemptRecorded(failedRefresh),
            ],
            to: setup.competitionID
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(fixture: fixture),
            store: setup.store,
            finalizationPolicy: FinalizationPolicy(
                minimumStabilityNanoseconds: 1,
                bestAvailableDeadline: .distantFuture
            )
        )

        let loaded = try await runtime.refresh(
            competitionID: setup.competitionID,
            trigger: .foreground
        )

        XCTAssertEqual(
            loaded.projection.activityRefresh.latestAttempt?.attemptID,
            failedRefresh.attemptID
        )
        XCTAssertEqual(
            loaded.projection.activityRefresh.nextAttemptOrdinal,
            3
        )
        XCTAssertEqual(
            loaded.projection.activityRefresh.lastSuccessfulFullWindowRefreshAt,
            durableReadDate
        )
        XCTAssertEqual(
            loaded.projection.scoreLedger.entry(forDayOrdinal: 1)?
                .latestEvidence.snapshot,
            durableSnapshot
        )
        let attempts = await setup.store.appendAttempts()
        XCTAssertEqual(attempts.count, 2) // acceptance + stale runtime attempt
    }

    func testOlderInterveningRefreshDoesNotSuppressNewerPreparedRead() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let olderSnapshot = try makeSnapshot(moveValue: 300)
        let newerSnapshot = try makeSnapshot(moveValue: 450)
        let newerReadDate = setup.activeDate.addingTimeInterval(2)
        let fixture = try ActivityFixture(
            initialInstant: EnvironmentInstant(
                wallDate: newerReadDate,
                monotonic: MonotonicInstant(
                    epochID: "runtime-inverse-cas",
                    nanoseconds: 3_000
                )
            ),
            initialDays: [
                .snapshot(
                    day: setup.window.days[0],
                    snapshot: newerSnapshot
                ),
            ],
            changes: []
        )
        let optionalBefore = try await setup.store.load(setup.competitionID)
        let before = try XCTUnwrap(optionalBefore)
        let clockEvents = try CompetitionEngine().observeClock(
            before.projection.competition,
            at: setup.activeDate
        )
        let externalRefresh = try ActivityRefreshAttemptRecorded(
            // A competing runtime mints the same ordinal-based identity before
            // this prepared read rebases onto its older committed result.
            attemptID: "runtime-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee-attempt-1",
            competitionID: setup.competitionID,
            attemptOrdinal: 1,
            trigger: .summaryUpdate,
            attemptedAt: setup.activeDate.addingTimeInterval(1),
            readAt: setup.activeDate.addingTimeInterval(1),
            monotonicInstant: MonotonicInstant(
                epochID: "runtime-inverse-cas",
                nanoseconds: 2_000
            ),
            readStatus: .completed,
            days: setup.window.days.enumerated().map { offset, day in
                ActivityDayObservation(
                    day: day,
                    ordinal: offset + 1,
                    availability: offset == 0
                        ? .observed(olderSnapshot)
                        : .notYetOccurred
                )
            }
        )
        await setup.store.interveneBeforeNextAppend(
            clockEvents.map(CompetitionDomainEvent.lifecycle)
                + [.activityRefreshAttemptRecorded(externalRefresh)],
            to: setup.competitionID
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(fixture: fixture),
            store: setup.store,
            finalizationPolicy: FinalizationPolicy(
                minimumStabilityNanoseconds: 1,
                bestAvailableDeadline: .distantFuture
            )
        )

        let loaded = try await runtime.refresh(
            competitionID: setup.competitionID,
            trigger: .foreground
        )

        XCTAssertEqual(
            loaded.projection.activityRefresh.latestAttempt?.attemptOrdinal,
            2
        )
        XCTAssertNotEqual(
            loaded.projection.activityRefresh.latestAttempt?.attemptID,
            externalRefresh.attemptID
        )
        XCTAssertEqual(
            loaded.projection.scoreLedger.entry(forDayOrdinal: 1)?
                .latestEvidence.snapshot,
            newerSnapshot
        )
        let attempts = await setup.store.appendAttempts()
        XCTAssertEqual(attempts.count, 3) // acceptance + conflict + newer retry
    }

    func testCursorRetryExhaustionThrowsExplicitRuntimeError() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        await setup.store.setConflictsRemaining(2)
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(
                fixture: try ActivityFixture(
                    initialInstant: EnvironmentInstant(
                        wallDate: setup.activeDate,
                        monotonic: MonotonicInstant(
                            epochID: "runtime-retry-exhaustion",
                            nanoseconds: 1_000
                        )
                    ),
                    initialDays: [],
                    changes: []
                )
            ),
            store: setup.store,
            finalizationPolicy: FinalizationPolicy(
                minimumStabilityNanoseconds: 1,
                bestAvailableDeadline: .distantFuture
            ),
            maximumCursorRetries: 2
        )

        do {
            _ = try await runtime.refresh(
                competitionID: setup.competitionID,
                trigger: .foreground
            )
            XCTFail("Expected retry exhaustion")
        } catch let error as LocalCompetitionRuntimeError {
            XCTAssertEqual(error, .cursorRetryLimitExceeded)
        }
        let attempts = await setup.store.appendAttempts()
        XCTAssertEqual(attempts.count, 3) // acceptance + two failed attempts
    }

    func testNotificationDecisionCommitAppendsOneAtomicBatch() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let runtime = try notificationRuntime(for: setup)
        let first = try notificationDecision(
            competitionID: setup.competitionID,
            family: .dailyMaximum,
            episodeKey: .day(1),
            revision: 21
        )
        let second = try notificationDecision(
            competitionID: setup.competitionID,
            family: .leadChange,
            episodeKey: .leader(dayOrdinal: 1, leader: .owner),
            revision: 21
        )
        let decisions: [CompetitionNotificationDurableDecision] = [
            .emission(first),
            .emission(second),
        ]

        let result = try await runtime.commitNotificationDecisions(
            competitionID: setup.competitionID,
            replan: { _ in decisions }
        )

        XCTAssertEqual(result, .appended(decisions))
        let loaded = try await runtime.load(setup.competitionID)
        XCTAssertEqual(
            loaded.projection.notificationEmissions.recordedIDs,
            Set(decisions.map(\.record.semanticEventID))
        )
        let attempts = await setup.store.appendAttempts()
        XCTAssertEqual(attempts.count, 2) // acceptance + one atomic decision batch
        XCTAssertEqual(attempts.last?.count, 2)
    }

    func testNotificationConflictReplansToNothingWithoutSecondAppend()
        async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let runtime = try notificationRuntime(for: setup)
        let decision = try notificationDecision(
            competitionID: setup.competitionID,
            family: .dailyMaximum,
            episodeKey: .day(1),
            revision: 22
        )
        await setup.store.interveneBeforeNextAppend(
            [.notificationEmissionRecorded(decision.record)],
            to: setup.competitionID
        )

        let result = try await runtime.commitNotificationDecisions(
            competitionID: setup.competitionID,
            replan: { loaded in
                loaded.projection.notificationEmissions.recordedIDs.contains(
                    decision.record.semanticEventID
                ) ? [] : [.emission(decision)]
            }
        )

        XCTAssertEqual(result, .noDecision)
        let attempts = await setup.store.appendAttempts()
        XCTAssertEqual(attempts.count, 2) // acceptance + conflicted first attempt
    }

    func testDeleteRetriesCursorConflictAndIsIdempotentWhenAlreadyAbsent()
        async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let runtime = try notificationRuntime(for: setup)
        await setup.store.setDeleteConflictsRemaining(1)

        try await runtime.delete(competitionID: setup.competitionID)
        try await runtime.delete(competitionID: setup.competitionID)

        let ids = try await setup.store.ids()
        let deleteAttempts = await setup.store.deleteAttempts()
        XCTAssertTrue(ids.isEmpty)
        XCTAssertEqual(deleteAttempts, 2)
    }

    func testBackgroundSignalCompletionWaitsForPersistedRefresh() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let signalDate = setup.activeDate.addingTimeInterval(60)
        let fixture = try ActivityFixture(
            initialInstant: EnvironmentInstant(
                wallDate: setup.activeDate,
                monotonic: MonotonicInstant(
                    epochID: "runtime-test",
                    nanoseconds: 1_000
                )
            ),
            initialDays: [
                .snapshot(
                    day: setup.window.days[0],
                    snapshot: try makeSnapshot(moveValue: 300)
                ),
            ],
            changes: [
                try FixtureActivityChange(
                    at: signalDate,
                    updates: [],
                    triggers: [.observerWakeupBackground]
                ),
            ]
        )
        let source = FixtureActivitySource(fixture: fixture)
        let environment = CompetitionEnvironmentClient.accelerated(
            source: source
        )
        let runtime = LocalCompetitionRuntime(
            environment: environment,
            store: setup.store,
            finalizationPolicy: FinalizationPolicy(
                minimumStabilityNanoseconds: 1,
                bestAvailableDeadline: .distantFuture
            )
        )
        let signals = await environment.signals()
        let signalTask = Task { () -> EnvironmentSignal? in
            var iterator = signals.makeAsyncIterator()
            return await iterator.next()
        }
        try await environment.advanceFixture(to: signalDate)
        let optionalSignal = await signalTask.value
        let signal = try XCTUnwrap(optionalSignal)
        XCTAssertTrue(signal.requiresCompletion)
        await setup.store.blockNextAppend()

        let handling = Task {
            try await runtime.handle(
                signal,
                competitionID: setup.competitionID
            )
        }
        await setup.store.waitUntilAppendIsBlocked()

        let completedBeforePersistence = await source.didCompleteSignal(
            signal.id
        )
        XCTAssertFalse(completedBeforePersistence)
        await setup.store.releaseBlockedAppend()
        _ = try await handling.value
        let completedAfterPersistence = await source.didCompleteSignal(
            signal.id
        )
        XCTAssertTrue(completedAfterPersistence)
    }

    func testGlobalSignalCompletesOnceAfterEveryCompetitionIsRefreshed() async throws {
        let first = try await makeAcceptedCompetition(conflictOnce: false)
        let second = try await makeAcceptedCompetition(
            conflictOnce: false,
            store: first.store,
            competitionUUID: UUID(
                uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
            )!
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: first.activeDate,
                    monotonic: MonotonicInstant(
                        epochID: "runtime-multi-competition",
                        nanoseconds: 8_000
                    )
                ),
                initialDays: [
                    .snapshot(
                        day: first.window.days[0],
                        snapshot: try makeSnapshot(moveValue: 300)
                    ),
                ],
                changes: []
            )
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(source: source),
            store: first.store,
            finalizationPolicy: FinalizationPolicy(
                minimumStabilityNanoseconds: 1,
                bestAvailableDeadline: .distantFuture
            )
        )
        let signal = EnvironmentSignal(
            id: "global-observer-signal",
            trigger: .observerWakeupBackground,
            requiresCompletion: true
        )

        let loaded = try await runtime.handle(
            signal,
            competitionIDs: [first.competitionID, second.competitionID]
        )

        XCTAssertEqual(
            loaded.map(\.projection.competition.id),
            [first.competitionID, second.competitionID]
        )
        XCTAssertTrue(
            loaded.allSatisfy {
                $0.projection.activityRefresh.latestAttempt != nil
            }
        )
        let completionCount = await source.signalCompletionCount(signal.id)
        XCTAssertEqual(completionCount, 1)
    }

    func testGlobalSignalAttemptsRemainingCompetitionsBeforeReportingFailure() async throws {
        let setup = try await makeAcceptedCompetition(conflictOnce: false)
        let missingID = CompetitionID(
            UUID(uuidString: "cccccccc-dddd-eeee-ffff-000000000000")!
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: setup.activeDate,
                    monotonic: MonotonicInstant(
                        epochID: "runtime-multi-failure",
                        nanoseconds: 9_000
                    )
                ),
                initialDays: [],
                changes: []
            )
        )
        let runtime = LocalCompetitionRuntime(
            environment: .accelerated(source: source),
            store: setup.store,
            finalizationPolicy: FinalizationPolicy(
                minimumStabilityNanoseconds: 1,
                bestAvailableDeadline: .distantFuture
            )
        )
        let signal = EnvironmentSignal(
            id: "global-partial-failure",
            trigger: .observerWakeupBackground,
            requiresCompletion: true
        )

        do {
            _ = try await runtime.handle(
                signal,
                competitionIDs: [missingID, setup.competitionID]
            )
            XCTFail("Expected the missing competition to be reported")
        } catch let error as LocalCompetitionRuntimeError {
            XCTAssertEqual(error, .competitionNotFound)
        }

        let persisted = try await runtime.load(setup.competitionID)
        XCTAssertNotNil(persisted.projection.activityRefresh.latestAttempt)
        let completionCount = await source.signalCompletionCount(signal.id)
        XCTAssertEqual(completionCount, 1)
    }

    private func makeAcceptedCompetition(
        conflictOnce: Bool,
        store: RuntimeTestEventStore? = nil,
        competitionUUID: UUID = UUID(
            uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )!,
        acceptedAt suppliedAcceptedAt: Date? = nil
    ) async throws -> (
        store: RuntimeTestEventStore,
        competitionID: CompetitionID,
        window: CompetitionActivityWindow,
        activeDate: Date
    ) {
        let store = store ?? RuntimeTestEventStore()
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let acceptedAt = try suppliedAcceptedAt ?? XCTUnwrap(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(
                    timeZone: TimeZone(identifier: "UTC"),
                    year: 2026,
                    month: 5,
                    day: 1,
                    hour: 12
                )
            )
        )
        let competitionID = CompetitionID(competitionUUID)
        let genesis = try CompetitionGenesis(
            competitionID: competitionID,
            direction: .outgoing,
            createdAt: acceptedAt.addingTimeInterval(-60),
            expiresAt: acceptedAt.addingTimeInterval(86_400),
            scoringPolicy: .healthKitCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
        _ = try await store.create(genesis)
        let optionalInitial = try await store.load(competitionID)
        let initial = try XCTUnwrap(optionalInitial)
        let accepted = try CompetitionEngine().accept(
            initial.projection.competition,
            at: acceptedAt,
            timeZoneIdentifier: calendar.timeZoneIdentifier,
            opponent: OpponentPlanGenerationRequest(
                seed: 42,
                generatorVersion: .v1,
                difficulty: .balanced
            )
        )
        _ = try await store.append(
            [.lifecycle(accepted)],
            to: competitionID,
            expectedCursor: initial.journal.cursor
        )
        let optionalAcceptedLoad = try await store.load(competitionID)
        let acceptedLoad = try XCTUnwrap(optionalAcceptedLoad)
        let schedule = try XCTUnwrap(acceptedLoad.projection.competition.schedule)
        let window = try CompetitionActivityWindow(
            calendar: schedule.calendar,
            startDay: schedule.startDay
        )
        let activeDate = try schedule.calendar.startOfDay(schedule.startDay)
            .addingTimeInterval(12 * 60 * 60)
        await store.setConflictOnce(conflictOnce)
        return (store, competitionID, window, activeDate)
    }

    private func makeRuntime(
        source: FixtureActivitySource,
        store: RuntimeTestEventStore
    ) -> LocalCompetitionRuntime {
        LocalCompetitionRuntime(
            environment: .accelerated(source: source),
            store: store,
            configuration: .testing
        )
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    timeZone: calendar.timeZone,
                    year: year,
                    month: month,
                    day: day,
                    hour: hour
                )
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

    private func notificationRuntime(
        for setup: (
            store: RuntimeTestEventStore,
            competitionID: CompetitionID,
            window: CompetitionActivityWindow,
            activeDate: Date
        )
    ) throws -> LocalCompetitionRuntime {
        LocalCompetitionRuntime(
            environment: .accelerated(
                fixture: try ActivityFixture(
                    initialInstant: EnvironmentInstant(
                        wallDate: setup.activeDate,
                        monotonic: MonotonicInstant(
                            epochID: "notification-runtime",
                            nanoseconds: 1_000
                        )
                    ),
                    initialDays: [],
                    changes: []
                )
            ),
            store: setup.store,
            configuration: .testing
        )
    }

    private func notificationDecision(
        competitionID: CompetitionID,
        family: NotificationEmissionFamily,
        episodeKey: NotificationEpisodeKey,
        revision: UInt64
    ) throws -> CompetitionNotificationEmissionDecision {
        let record = try NotificationEmissionRecorded(
            competitionID: competitionID,
            family: family,
            episodeKey: episodeKey,
            disposition: .emitted,
            decidedAt: Date(timeIntervalSinceReferenceDate: 2_000_000),
            basisPublicationRevision: revision
        )
        return CompetitionNotificationEmissionDecision(
            record: record,
            request: CompetitionImmediateNotificationRequest(
                identifier: record.semanticEventID,
                content: CompetitionNotificationContent(
                    title: family.rawValue,
                    body: "fixture"
                ),
                route: .competition(competitionID)
            )
        )
    }
}

private actor RuntimeTestEventStore: CompetitionEventStore {
    private var journals: [CompetitionID: CompetitionJournal] = [:]
    private var recordedAppendAttempts: [[CompetitionDomainEvent]] = []
    private var syntheticConflictsRemaining = 0
    private var shouldBlockNextAppend = false
    private var appendIsBlocked = false
    private var blockedAppendContinuation: CheckedContinuation<Void, Never>?
    private var appendBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var interveningAppend: (
        competitionID: CompetitionID,
        events: [CompetitionDomainEvent]
    )?
    private var shouldFailIDEnumeration = false
    private var appendFailureIDs = Set<CompetitionID>()
    private var syntheticDeleteConflictsRemaining = 0
    private var recordedDeleteAttempts = 0

    func ids() async throws -> [CompetitionID] {
        if shouldFailIDEnumeration {
            throw RuntimeTestStoreError.syntheticFailure
        }
        return journals.keys.sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
    }

    func load(
        _ id: CompetitionID
    ) async throws -> LoadedCompetitionJournal? {
        guard let journal = journals[id] else {
            return nil
        }
        return try LoadedCompetitionJournal(journal: journal, source: .primary)
    }

    func create(
        _ genesis: CompetitionGenesis
    ) async throws -> CompetitionEventStoreCreateResult {
        if let journal = journals[genesis.competitionID] {
            guard journal.genesis == genesis else {
                throw CompetitionEventStoreError.identityAlreadyExists
            }
            return CompetitionEventStoreCreateResult(
                cursor: journal.cursor,
                created: false
            )
        }
        let created = try CompetitionJournal(genesis: genesis)
        journals[genesis.competitionID] = created
        return CompetitionEventStoreCreateResult(
            cursor: created.cursor,
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
        recordedAppendAttempts.append(events)
        if appendFailureIDs.contains(id) {
            throw RuntimeTestStoreError.syntheticFailure
        }
        if shouldBlockNextAppend {
            shouldBlockNextAppend = false
            appendIsBlocked = true
            for waiter in appendBlockedWaiters { waiter.resume() }
            appendBlockedWaiters.removeAll()
            await withCheckedContinuation { continuation in
                blockedAppendContinuation = continuation
            }
            appendIsBlocked = false
        }
        if let interveningAppend,
           interveningAppend.competitionID == id {
            self.interveningAppend = nil
            guard var currentJournal = journals[id] else {
                throw CompetitionEventStoreError.identityNotFound
            }
            do {
                _ = try currentJournal.append(
                    interveningAppend.events,
                    expectedCursor: currentJournal.cursor
                )
                journals[id] = currentJournal
            } catch let error as CompetitionJournalError {
                throw CompetitionEventStoreError.journal(error)
            }
        }
        guard let currentJournal = journals[id],
              currentJournal.cursor == expectedCursor
        else {
            throw CompetitionEventStoreError.cursorConflict(
                expected: expectedCursor,
                actual: journals[id]?.cursor ?? journal.cursor
            )
        }
        journal = currentJournal
        if syntheticConflictsRemaining > 0 {
            syntheticConflictsRemaining -= 1
            throw CompetitionEventStoreError.cursorConflict(
                expected: expectedCursor,
                actual: journal.cursor
            )
        }
        do {
            let result = try journal.append(
                events,
                expectedCursor: expectedCursor
            )
            journals[id] = journal
            return result
        } catch let error as CompetitionJournalError {
            throw CompetitionEventStoreError.journal(error)
        }
    }

    func delete(
        _ id: CompetitionID,
        expectedCursor: CompetitionJournalCursor
    ) async throws {
        recordedDeleteAttempts += 1
        guard let journal = journals[id] else {
            throw CompetitionEventStoreError.identityNotFound
        }
        if syntheticDeleteConflictsRemaining > 0 {
            syntheticDeleteConflictsRemaining -= 1
            throw CompetitionEventStoreError.cursorConflict(
                expected: expectedCursor,
                actual: journal.cursor
            )
        }
        guard journal.cursor == expectedCursor else {
            throw CompetitionEventStoreError.cursorConflict(
                expected: expectedCursor,
                actual: journal.cursor
            )
        }
        journals[id] = nil
    }

    func setConflictOnce(_ value: Bool) {
        syntheticConflictsRemaining = value ? 1 : 0
    }

    func setConflictsRemaining(_ count: Int) {
        syntheticConflictsRemaining = count
    }

    func setDeleteConflictsRemaining(_ count: Int) {
        syntheticDeleteConflictsRemaining = count
    }

    func deleteAttempts() -> Int {
        recordedDeleteAttempts
    }

    func appendAttempts() -> [[CompetitionDomainEvent]] {
        recordedAppendAttempts
    }

    func interveneBeforeNextAppend(
        _ events: [CompetitionDomainEvent],
        to competitionID: CompetitionID
    ) {
        interveningAppend = (competitionID, events)
    }

    func blockNextAppend() {
        shouldBlockNextAppend = true
    }

    func waitUntilAppendIsBlocked() async {
        guard !appendIsBlocked else { return }
        await withCheckedContinuation { continuation in
            appendBlockedWaiters.append(continuation)
        }
    }

    func releaseBlockedAppend() {
        blockedAppendContinuation?.resume()
        blockedAppendContinuation = nil
    }

    func failAppends(for id: CompetitionID) {
        appendFailureIDs.insert(id)
    }

    func failIDEnumeration() {
        shouldFailIDEnumeration = true
    }
}

private enum RuntimeTestStoreError: Error {
    case syntheticFailure
}

private actor RuntimeTaskStartLatch {
    private let expectedCount: Int
    private var startedCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        expectedCount = count
    }

    func arrive() {
        startedCount += 1
        guard startedCount >= expectedCount else { return }
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func waitUntilAllStarted() async {
        guard startedCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
