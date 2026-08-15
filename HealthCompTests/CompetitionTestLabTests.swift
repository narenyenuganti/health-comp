#if DEBUG

import CompetitionCore
import Dependencies
import XCTest
@testable import HealthComp

final class CompetitionTestLabTests: XCTestCase {
    func testMultiUserLaunchParserAcceptsEveryDeterministicScenario() {
        for scenario in MultiUserCompetitionTestLabScenario.allCases {
            XCTAssertEqual(
                MultiUserCompetitionTestLabLaunchParser.decision(
                    arguments: [
                        "HealthComp",
                        "--multi-user-competition-test-lab",
                        "--multi-user-competition-scenario",
                        scenario.rawValue,
                    ]
                ),
                .configured(.init(scenario: scenario))
            )
        }
    }

    func testMultiUserLaunchParserFailsClosedForMixedOrInvalidLabModes() {
        let cases = [
            [
                "--multi-user-competition-test-lab",
                "--local-competition-test-lab",
            ],
            [
                "--multi-user-competition-test-lab",
                "--multi-user-competition-scenario", "unknown",
            ],
            [
                "--multi-user-competition-test-lab",
                "--multi-user-competition-scenario",
            ],
        ]

        for arguments in cases {
            guard case .invalid = MultiUserCompetitionTestLabLaunchParser
                .decision(arguments: arguments)
            else {
                return XCTFail("Invalid multi-user lab arguments must fail closed")
            }
        }
    }

    @MainActor
    func testMultiUserLabLaunchConstructsNoLiveDependencyGraph() {
        let authenticationMakeCount = CompetitionTestLabLockedCounter()
        let competitionMakeCount = CompetitionTestLabLockedCounter()

        _ = HealthCompApp(
            arguments: [
                "HealthComp",
                "--multi-user-competition-test-lab",
                "--multi-user-competition-scenario", "sharing",
            ],
            supabaseClientProvider: SupabaseClientProvider {
                fatalError("Multi-user Test Lab must not create Supabase")
            },
            authenticationClientFactory: AuthenticationClientFactory { _ in
                authenticationMakeCount.increment()
                return .testValue
            },
            competitionClientFactory: CompetitionClientFactory { _ in
                competitionMakeCount.increment()
                return .testValue
            }
        )

        XCTAssertEqual(authenticationMakeCount.value, 0)
        XCTAssertEqual(competitionMakeCount.value, 0)
    }

    func testLaunchParserIsDisabledWithoutLabFlag() {
        XCTAssertEqual(
            CompetitionTestLabLaunchParser.decision(arguments: ["HealthComp"]),
            .disabled
        )
    }

    func testLaunchParserAcceptsDeterministicConfiguration() throws {
        let decision = CompetitionTestLabLaunchParser.decision(arguments: [
            "HealthComp",
            "--local-competition-test-lab",
            "--local-competition-fixture", "late-sync",
            "--local-competition-direction", "incoming",
            "--local-competition-seed", "424242",
            "--local-competition-difficulty", "challenging",
            "--local-competition-run-id", "ui-run-42",
        ])

        XCTAssertEqual(
            decision,
            .configured(
                CompetitionTestLabConfiguration(
                    fixture: .lateSync,
                    seed: 424_242,
                    difficulty: .challenging,
                    direction: .incoming,
                    runID: "ui-run-42",
                    journalMode: .persistent
                )
            )
        )
    }

    func testInvalidLabArgumentsFailClosed() {
        let cases: [[String]] = [
            ["--local-competition-test-lab", "--local-competition-seed", "NaN"],
            ["--local-competition-test-lab", "--local-competition-fixture", "live"],
            ["--local-competition-test-lab", "--local-competition-run-id", "../live"],
            ["--local-competition-test-lab", "--local-competition-unknown", "x"],
        ]

        for arguments in cases {
            guard case .invalid = CompetitionTestLabLaunchParser.decision(
                arguments: arguments
            ) else {
                return XCTFail("Invalid lab arguments must never fall back live")
            }
        }
    }

    @MainActor
    func testEveryLabLaunchModeMakesZeroCallsToPoisonedLiveClient() async throws {
        let poisonedLive = PoisonedCompetitionClientRecorder()
        var launchCount = 0

        for fixture in CompetitionTestLabFixtureKind.allCases {
            for direction in [InvitationDirection.incoming, .outgoing] {
                for journalMode in [
                    CompetitionTestLabJournalMode.unique,
                    .persistent,
                ] {
                    let directionLabel = direction == .incoming
                        ? "incoming"
                        : "outgoing"
                    let journalLabel = journalMode == .unique
                        ? "unique"
                        : "persistent"
                    let runID = [
                        "poison",
                        fixture.rawValue,
                        directionLabel,
                        journalLabel,
                        String(UUID().uuidString.lowercased().prefix(8)),
                    ].joined(separator: "-")
                    let root = withDependencies {
                        $0.competitionClient = poisonedLive.client
                    } operation: {
                        CompetitionTestLabRootView(
                            configuration: CompetitionTestLabConfiguration(
                                fixture: fixture,
                                seed: 42,
                                difficulty: .balanced,
                                direction: direction,
                                runID: runID,
                                journalMode: journalMode
                            )
                        )
                    }
                    let session = try XCTUnwrap(root.controller.session)
                    launchCount += 1
                    session.store.send(.task)
                    _ = try await publication(in: session, minimumRevision: 1)
                    session.store.send(.stop)
                    await session.client.stop()
                    try CompetitionTestLabStorage.removeSessionRoot(
                        session.journalRoot,
                        runID: runID
                    )
                    XCTAssertFalse(
                        FileManager.default.fileExists(
                            atPath: session.journalRoot.path
                        )
                    )
                }
            }
        }

        XCTAssertEqual(launchCount, 28)
        XCTAssertEqual(poisonedLive.callCount, 0)
    }

    func testLateSyncCatalogHasOrderedLifecycleCheckpoints() throws {
        let catalog = try CompetitionTestLabFixtureCatalog.make(
            configuration: CompetitionTestLabConfiguration(
                fixture: .lateSync,
                seed: 7,
                difficulty: .balanced,
                direction: .outgoing,
                runID: "catalog-test"
            )
        )

        XCTAssertEqual(catalog.checkpoints.count, 10)
        XCTAssertEqual(catalog.checkpoints.map(\.label), [
            "Day 1", "Day 2", "Day 3", "Day 4", "Day 5", "Day 6",
            "Ends Today", "Tallying Points", "Late Day 7", "Result",
        ])
        XCTAssertEqual(
            catalog.checkpoints.map(\.date),
            catalog.checkpoints.map(\.date).sorted()
        )
        XCTAssertEqual(catalog.fixture.timeZoneIdentifier, "UTC")
    }

    @MainActor
    func testLabSessionIgnoresProcessGlobalLiveRoutes() async throws {
        let session = try withDependencies {
            $0.competitionRoutingClient = .live(
                hub: CompetitionRoutingEnvironment.liveHub
            )
        } operation: {
            try CompetitionTestLabSession(
                configuration: CompetitionTestLabConfiguration(
                    fixture: .lateSync,
                    seed: 8,
                    difficulty: .balanced,
                    direction: .outgoing,
                    runID: "isolated-routing"
                )
            )
        }
        session.store.send(.task)
        _ = try await publication(in: session, minimumRevision: 1)
        let envelope = try XCTUnwrap(
            CompetitionRoutingEnvironment.liveHub.enqueue(
                .competition(LocalCompetitionIdentity.bootstrapCompetitionID)
            )
        )
        defer {
            CompetitionRoutingEnvironment.liveHub.consume(
                sequence: envelope.sequence
            )
        }

        for _ in 0..<5_000 {
            if !session.store.withState({ $0.path }).isEmpty { break }
            await Task.yield()
        }

        XCTAssertTrue(session.store.withState { $0.path }.isEmpty)
        session.store.send(.stop)
        await session.client.stop()
    }

    @MainActor
    func testReadinessWaitsForPostPublicationWaiterRegistration() async throws {
        let session = try CompetitionTestLabSession(
            configuration: CompetitionTestLabConfiguration(
                fixture: .lateSync,
                seed: 9,
                difficulty: .balanced,
                direction: .outgoing,
                runID: "delayed-waiter"
            )
        )
        session.store.send(.task)
        let pending = try await publication(in: session, minimumRevision: 1)
        session.observeCanonicalPublication(pending)
        try await waitForWaiterCount(1, source: session.source)
        await session.source.blockNextWaitRegistration()

        session.store.send(
            .competition(
                .acceptTapped(LocalCompetitionIdentity.bootstrapCompetitionID)
            )
        )
        let scheduled = try await publication(in: session, minimumRevision: 2)
        session.observeCanonicalPublication(scheduled)
        await session.source.waitUntilWaitRegistrationIsBlocked()

        XCTAssertFalse(session.canAdvance)
        let revisionBeforeRegistration = scheduled.publicationRevision
        await session.source.releaseBlockedWaitRegistration()
        try await waitUntil { session.canAdvance }
        let revisionAfterRegistration = session.store.withState {
            $0.competition.publication?.publicationRevision
        }
        XCTAssertEqual(revisionAfterRegistration, revisionBeforeRegistration)
        await session.client.stop()
    }

    func testCheckpointAcknowledgerIgnoresUnrelatedNewerPublication() async throws {
        let targetDate = Date(timeIntervalSinceReferenceDate: 100)
        let checkpoint = CompetitionTestLabCheckpoint(
            label: "Day 1",
            date: targetDate,
            kind: .scheduledWake,
            expectedProjection: .active(dayOrdinal: 1)
        )
        let unrelated = publication(
            revision: 2,
            evaluatedAt: targetDate,
            lifecycle: .scheduled
        )
        let expected = publication(
            revision: 3,
            evaluatedAt: targetDate,
            lifecycle: .active(dayOrdinal: 1)
        )
        let stream = AsyncStream<LocalCompetitionPublication> { continuation in
            continuation.yield(unrelated)
            continuation.yield(expected)
            continuation.finish()
        }

        let acknowledged = await CompetitionTestLabPublicationAcknowledger.next(
            after: 1,
            checkpoint: checkpoint,
            from: stream
        )

        XCTAssertEqual(acknowledged?.publicationRevision, 3)
    }

    @MainActor
    func testBestAvailableFixtureCompletesWithBestAvailableBasis() async throws {
        let session = try CompetitionTestLabSession(
            configuration: CompetitionTestLabConfiguration(
                fixture: .bestAvailable,
                seed: 10,
                difficulty: .balanced,
                direction: .outgoing,
                runID: "best-available"
            )
        )
        var iterator = session.client.start().makeAsyncIterator()
        let optionalPending = await iterator.next()
        let pending = try XCTUnwrap(optionalPending)
        var publication = await session.client.accept(
            LocalCompetitionIdentity.bootstrapCompetitionID
        )
        XCTAssertGreaterThan(
            publication.publicationRevision,
            pending.publicationRevision
        )

        for checkpoint in session.catalog.checkpoints {
            try await waitForWaiter(
                at: checkpoint.date,
                source: session.source
            )
            let baseline = publication.publicationRevision
            let next = Task {
                await CompetitionTestLabPublicationAcknowledger.next(
                    after: baseline,
                    checkpoint: checkpoint,
                    from: session.client.updates()
                )
            }
            try await session.source.advance(to: checkpoint.date)
            let optionalNext = await next.value
            publication = try XCTUnwrap(optionalNext)
        }

        let result = try XCTUnwrap(
            publication.dashboard.competitions.first?.terminalResult
        )
        XCTAssertEqual(result.basis, .bestAvailable)
        await session.client.stop()
    }

    @MainActor
    func testLossAndTieFixturesReachTheirNamedTerminalOutcomes() async throws {
        let cases: [(CompetitionTestLabFixtureKind, CompetitionOutcome)] = [
            (.loss, .loss),
            (.tie, .tie),
        ]

        for (fixture, expectedOutcome) in cases {
            let session = try CompetitionTestLabSession(
                configuration: CompetitionTestLabConfiguration(
                    fixture: fixture,
                    seed: 424_242,
                    difficulty: .balanced,
                    direction: .outgoing,
                    runID: "\(fixture.rawValue)-outcome"
                )
            )
            var iterator = session.client.start().makeAsyncIterator()
            let optionalPending = await iterator.next()
            let pending = try XCTUnwrap(optionalPending)
            var publication = await session.client.accept(
                LocalCompetitionIdentity.bootstrapCompetitionID
            )
            XCTAssertGreaterThan(
                publication.publicationRevision,
                pending.publicationRevision
            )

            for checkpoint in session.catalog.checkpoints {
                try await waitForWaiter(
                    at: checkpoint.date,
                    source: session.source
                )
                let baseline = publication.publicationRevision
                let next = Task {
                    await CompetitionTestLabPublicationAcknowledger.next(
                        after: baseline,
                        checkpoint: checkpoint,
                        from: session.client.updates()
                    )
                }
                try await session.source.advance(to: checkpoint.date)
                let optionalNext = await next.value
                publication = try XCTUnwrap(optionalNext)
            }

            XCTAssertEqual(
                publication.dashboard.competitions.first?.terminalResult?
                    .outcome,
                expectedOutcome
            )
            await session.client.stop()
        }
    }

    @MainActor
    func testResetUsesUniqueValidatedTempDescendantAndRemovesOnlyPriorSession() async throws {
        let configuration = CompetitionTestLabConfiguration(
            fixture: .lateSync,
            seed: 11,
            difficulty: .balanced,
            direction: .outgoing,
            runID: "isolated-reset"
        )
        let controller = CompetitionTestLabController(
            configuration: configuration
        )
        let first = try XCTUnwrap(controller.session)
        first.store.send(.task)
        _ = try await publication(in: first, minimumRevision: 1)
        XCTAssertTrue(
            CompetitionTestLabStorage.isSafeSessionRoot(
                first.journalRoot,
                runID: configuration.runID
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: first.journalRoot.path)
        )

        controller.reset()
        let second = try XCTUnwrap(controller.session)
        XCTAssertNotEqual(first.journalRoot, second.journalRoot)
        try await waitUntil {
            !FileManager.default.fileExists(atPath: first.journalRoot.path)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: first.journalRoot.path)
        )
        XCTAssertTrue(
            CompetitionTestLabStorage.isSafeSessionRoot(
                second.journalRoot,
                runID: configuration.runID
            )
        )
        await second.client.stop()
    }

    @MainActor
    func testPersistentRunIDRelaunchReopensTheSameCanonicalJournal() async throws {
        let runID = "relaunch-\(UUID().uuidString.lowercased())"
        let configuration = CompetitionTestLabConfiguration(
            fixture: .lateSync,
            seed: 12,
            difficulty: .balanced,
            direction: .outgoing,
            runID: runID,
            journalMode: .persistent
        )
        let first = try CompetitionTestLabSession(configuration: configuration)
        first.store.send(.task)
        let pending = try await publication(in: first, minimumRevision: 1)
        first.observeCanonicalPublication(pending)
        first.store.send(
            .competition(
                .acceptTapped(LocalCompetitionIdentity.bootstrapCompetitionID)
            )
        )
        let scheduled = try await publication(in: first, minimumRevision: 2)
        first.observeCanonicalPublication(scheduled)
        XCTAssertEqual(
            scheduled.dashboard.competitions.first?.lifecycle,
            .scheduled
        )
        try await waitUntil { first.canAdvance }
        await first.advanceOneCheckpoint()
        let active = try await publication(in: first, minimumRevision: 3)
        XCTAssertEqual(
            active.dashboard.competitions.first?.lifecycle,
            .active(dayOrdinal: 1)
        )
        XCTAssertEqual(first.checkpointIndex, 1)
        await first.client.stop()

        let second = try CompetitionTestLabSession(configuration: configuration)
        XCTAssertEqual(second.journalRoot, first.journalRoot)
        second.store.send(.task)
        let relaunched = try await publication(in: second, minimumRevision: 1)
        XCTAssertEqual(
            relaunched.dashboard.competitions.first?.lifecycle,
            .active(dayOrdinal: 1)
        )
        XCTAssertEqual(relaunched.evaluatedAt, active.evaluatedAt)
        XCTAssertEqual(second.checkpointIndex, 1)
        XCTAssertEqual(second.nextCheckpoint?.label, "Day 2")
        await second.client.stop()
        try CompetitionTestLabStorage.removeSessionRoot(
            second.journalRoot,
            runID: runID
        )
    }

    @MainActor
    func testCorruptPersistentFixtureStateFailsClosed() throws {
        let runID = "corrupt-\(UUID().uuidString.lowercased())"
        let root = try CompetitionTestLabStorage.persistentJournalRoot(
            runID: runID
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: root.appendingPathComponent("fixture-state-v1.json")
        )
        let configuration = CompetitionTestLabConfiguration(
            fixture: .lateSync,
            seed: 13,
            difficulty: .balanced,
            direction: .outgoing,
            runID: runID,
            journalMode: .persistent
        )

        XCTAssertThrowsError(
            try CompetitionTestLabSession(configuration: configuration)
        )
        try CompetitionTestLabStorage.removeSessionRoot(root, runID: runID)
    }

    @MainActor
    private func publication(
        in session: CompetitionTestLabSession,
        minimumRevision: UInt64
    ) async throws -> LocalCompetitionPublication {
        for _ in 0..<50_000 {
            if let publication = session.store.withState({
                $0.competition.publication
            }), publication.publicationRevision >= minimumRevision {
                return publication
            }
            await Task.yield()
        }
        throw CompetitionTestLabTestError.timeout
    }

    private func waitForWaiterCount(
        _ expected: Int,
        source: FixtureActivitySource
    ) async throws {
        for _ in 0..<50_000 {
            if await source.pendingWaiterCount() == expected { return }
            await Task.yield()
        }
        throw CompetitionTestLabTestError.timeout
    }

    private func waitForWaiter(
        at date: Date,
        source: FixtureActivitySource
    ) async throws {
        for _ in 0..<50_000 {
            let dates = await source.pendingWaiterDates()
            if dates.contains(where: {
                abs($0.timeIntervalSince(date)) < 0.000_001
            }) {
                return
            }
            await Task.yield()
        }
        throw CompetitionTestLabTestError.timeout
    }

    @MainActor
    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<50_000 {
            if predicate() { return }
            await Task.yield()
        }
        throw CompetitionTestLabTestError.timeout
    }

    private func publication(
        revision: UInt64,
        evaluatedAt: Date,
        lifecycle: LocalCompetitionLifecyclePresentation
    ) -> LocalCompetitionPublication {
        let competition = LocalCompetitionPresentation(
            id: LocalCompetitionIdentity.bootstrapCompetitionID,
            ownerDisplayName: "Naren",
            opponentDisplayName: "Alex",
            lifecycle: lifecycle,
            acceptedConfiguration: nil,
            userPoints: 0,
            opponentPoints: 0,
            days: [],
            currentDayOrdinal: nil,
            lastRefresh: nil,
            tally: nil,
            terminalResult: nil,
            evaluatedAt: evaluatedAt,
            timeZoneIdentifier: "UTC"
        )
        return LocalCompetitionPublication(
            publicationRevision: revision,
            dashboard: LocalCompetitionDashboard(
                competitions: [competition],
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0
            ),
            evaluatedAt: evaluatedAt,
            timeZoneIdentifier: "UTC"
        )
    }
}

private enum CompetitionTestLabTestError: Error {
    case timeout
}

private final class CompetitionTestLabLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class PoisonedCompetitionClientRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    var client: CompetitionClient {
        CompetitionClient(
            start: { [weak self] in
                self?.recordCall()
                return AsyncStream { $0.finish() }
            },
            updates: { [weak self] in
                self?.recordCall()
                return AsyncStream { $0.finish() }
            },
            reconcileAll: { [weak self] _ in
                self?.recordCall()
                return Self.emptyPublication
            },
            accept: { [weak self] _ in
                self?.recordCall()
                return Self.emptyPublication
            },
            decline: { [weak self] _ in
                self?.recordCall()
                return Self.emptyPublication
            },
            archive: { [weak self] _ in
                self?.recordCall()
                return Self.emptyPublication
            },
            rematch: { [weak self] _ in
                self?.recordCall()
                return Self.emptyPublication
            },
            reinvite: { [weak self] in
                self?.recordCall()
                return Self.emptyPublication
            },
            delete: { [weak self] _ in
                self?.recordCall()
                return Self.emptyPublication
            },
            reconcileNotifications: { [weak self] in self?.recordCall() },
            loadMutedOpponentIdentities: { [weak self] in
                self?.recordCall()
                return []
            },
            setNotificationMuted: { [weak self] _, _ in self?.recordCall() },
            loadNotificationAuthorizationState: { [weak self] in
                self?.recordCall()
                return nil
            },
            requestNotificationAuthorization: { [weak self] in
                self?.recordCall()
                return .denied
            },
            waitUntil: { [weak self] _ in self?.recordCall() },
            stop: { [weak self] in self?.recordCall() }
        )
    }

    private func recordCall() {
        lock.withLock { calls += 1 }
    }

    private static let emptyPublication = LocalCompetitionPublication(
        publicationRevision: 0,
        dashboard: LocalCompetitionDashboard(
            competitions: [],
            awards: [],
            issues: [],
            hiddenTerminalCompetitionCount: 0
        )
    )
}

#endif
