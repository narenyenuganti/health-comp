import CompetitionCore
import ComposableArchitecture
import XCTest
@testable import HealthComp

final class CompetitionFeatureTests: XCTestCase {
    @MainActor
    func testAcceleratedLifecyclePublishesCanonicalTimelineAndJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "competition-feature-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let acceptedAt = Date(timeIntervalSinceReferenceDate: 43_200)
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let startDay = try calendar.startDay(afterAcceptanceAt: acceptedAt)
        let days = try calendar.sevenDayWindow(startingOn: startDay)
        let dayBoundaries = try days.map(calendar.startOfDay)
        let endBoundary = try calendar.startOfDay(calendar.day(after: days[6]))
        let lateDaySevenDate = endBoundary.addingTimeInterval(1)
        let stabilityWakeDate = lateDaySevenDate.addingTimeInterval(
            0.000_000_001
        )
        let maximumSnapshot = ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: 1_000, goal: 500),
            exercise: try ActivityRingReading(value: 60, goal: 30),
            standOrRoll: try ActivityRingReading(value: 24, goal: 12),
            pauseState: .running
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: acceptedAt,
                    monotonic: MonotonicInstant(
                        epochID: "competition-feature-lifecycle",
                        nanoseconds: 1_000
                    )
                ),
                timeZoneIdentifier: "UTC",
                initialDays: days.enumerated().map { offset, day in
                    offset < 6
                        ? .snapshot(day: day, snapshot: maximumSnapshot)
                        : .missing(day: day)
                },
                changes: [
                    try FixtureActivityChange(
                        at: lateDaySevenDate,
                        updates: [
                            .snapshot(day: days[6], snapshot: maximumSnapshot),
                        ],
                        triggers: [.summaryUpdate]
                    ),
                ]
            )
        )
        let journalStore = JSONCompetitionEventStore(rootDirectory: root)
        let realClient = CompetitionClient.localFixture(
            environment: .accelerated(source: source),
            storeAvailability: .available(journalStore),
            configuration: .testing
        )
        let capture = CompetitionLifecyclePublicationCapture()
        let client = clientRecordingCanonicalPublications(
            from: realClient,
            into: capture
        )
        let reducerStore = TestStore(initialState: CompetitionFeature.State()) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = client
        }
        let sourceID = LocalCompetitionIdentity.bootstrapCompetitionID

        await reducerStore.send(.task)
        let pending = await capture.publication(at: 0)
        XCTAssertEqual(pending.publicationRevision, 1)
        let pendingCompetition = try XCTUnwrap(
            pending.dashboard.competitions.first { $0.id == sourceID }
        )
        guard case .pending(direction: .outgoing, createdAt: acceptedAt, _) =
            pendingCompetition.lifecycle
        else {
            return XCTFail("Revision 1 must be the bootstrap pending invite")
        }
        await reducerStore.receive(.publication(pending)) {
            $0.publication = pending
        }

        await reducerStore.send(.acceptTapped(sourceID)) {
            $0.commandIDsInFlight.insert(sourceID)
        }
        let scheduled = await capture.publication(at: 1)
        XCTAssertEqual(scheduled.publicationRevision, 2)
        let scheduledCompetition = try XCTUnwrap(
            scheduled.dashboard.competitions.first { $0.id == sourceID }
        )
        XCTAssertEqual(scheduledCompetition.lifecycle, .scheduled)
        XCTAssertEqual(
            scheduledCompetition.acceptedConfiguration?.schedule.startDay,
            startDay
        )
        assertFutureDaysArePrivate(
            scheduledCompetition,
            afterCurrentOrdinal: 0
        )
        await reducerStore.receive(
            .commandFinished(sourceID, expectedRevision: 2)
        ) {
            $0.commandExpectedPublicationRevisions[sourceID] = 2
        }
        await reducerStore.receive(.publication(scheduled)) {
            $0.publication = scheduled
            $0.commandIDsInFlight.remove(sourceID)
            $0.commandExpectedPublicationRevisions[sourceID] = nil
        }

        for ordinal in 1...7 {
            await waitForExactlyOneFixtureWaiter(source)
            try await source.advance(to: dayBoundaries[ordinal - 1])
            let publication = await capture.publication(at: ordinal + 1)
            XCTAssertEqual(
                publication.publicationRevision,
                UInt64(ordinal + 2)
            )
            let competition = try XCTUnwrap(
                publication.dashboard.competitions.first { $0.id == sourceID }
            )
            if ordinal < 7 {
                XCTAssertEqual(
                    competition.lifecycle,
                    .active(dayOrdinal: ordinal)
                )
            } else {
                XCTAssertEqual(competition.lifecycle, .endsToday)
            }
            XCTAssertEqual(competition.currentDayOrdinal, ordinal)
            assertFutureDaysArePrivate(
                competition,
                afterCurrentOrdinal: ordinal
            )
            await reducerStore.receive(.publication(publication)) {
                $0.publication = publication
            }
        }

        await waitForExactlyOneFixtureWaiter(source)
        try await source.advance(to: endBoundary)
        let incompleteTally = await capture.publication(at: 9)
        XCTAssertEqual(incompleteTally.publicationRevision, 10)
        let incompleteCompetition = try XCTUnwrap(
            incompleteTally.dashboard.competitions.first { $0.id == sourceID }
        )
        XCTAssertEqual(
            incompleteCompetition.lifecycle,
            .tallying(startedAt: endBoundary)
        )
        XCTAssertEqual(
            incompleteCompetition.tally?.attention,
            .incomplete(missingOrdinals: [7], unavailableOrdinals: [])
        )
        XCTAssertEqual(
            incompleteCompetition.tally?.consecutiveStableCompleteReads,
            0
        )
        await reducerStore.receive(.publication(incompleteTally)) {
            $0.publication = incompleteTally
        }

        await waitForExactlyOneFixtureWaiter(source)
        try await source.advance(to: lateDaySevenDate)
        let stableOnce = await capture.publication(at: 10)
        XCTAssertEqual(stableOnce.publicationRevision, 11)
        let stableOnceCompetition = try XCTUnwrap(
            stableOnce.dashboard.competitions.first { $0.id == sourceID }
        )
        XCTAssertEqual(
            stableOnceCompetition.lifecycle,
            .tallying(startedAt: endBoundary)
        )
        XCTAssertEqual(stableOnceCompetition.tally?.attention, .awaitingStability)
        XCTAssertEqual(
            stableOnceCompetition.tally?.consecutiveStableCompleteReads,
            1
        )
        await reducerStore.receive(.publication(stableOnce)) {
            $0.publication = stableOnce
        }

        await waitForExactlyOneFixtureWaiter(source)
        try await source.advance(to: stabilityWakeDate)
        let completed = await capture.publication(at: 11)
        XCTAssertEqual(completed.publicationRevision, 12)
        let completedCompetition = try XCTUnwrap(
            completed.dashboard.competitions.first { $0.id == sourceID }
        )
        guard case .completed(
            outcome: .win,
            basis: .stableAcrossPostBoundaryReads,
            completedAt: stabilityWakeDate
        ) = completedCompetition.lifecycle else {
            return XCTFail("The 1ns testing wake must complete a win")
        }
        XCTAssertEqual(completedCompetition.userPoints, 4_200)
        XCTAssertEqual(
            completed.dashboard.awards.map(\.kind),
            [.completion, .victory]
        )
        XCTAssertTrue(
            completed.dashboard.awards.allSatisfy { $0.competitionID == sourceID }
        )
        await reducerStore.receive(.publication(completed)) {
            $0.publication = completed
        }

        let optionalLoadedBeforeRematch = try await journalStore.load(sourceID)
        let loadedBeforeRematch = try XCTUnwrap(optionalLoadedBeforeRematch)
        let sourceJournalBeforeRematch = loadedBeforeRematch.journal
        try assertCanonicalLifecycleJournal(
            sourceJournalBeforeRematch,
            competitionID: sourceID
        )

        await reducerStore.send(.rematchTapped(sourceID)) {
            $0.commandIDsInFlight.insert(sourceID)
        }
        let rematched = await capture.publication(at: 12)
        XCTAssertEqual(rematched.publicationRevision, 13)
        let rematchID = LocalCompetitionIdentity.rematchID(for: sourceID)
        XCTAssertEqual(
            Set(rematched.dashboard.competitions.map(\.id)),
            Set([sourceID, rematchID])
        )
        let retainedSource = try XCTUnwrap(
            rematched.dashboard.competitions.first { $0.id == sourceID }
        )
        XCTAssertEqual(retainedSource.lifecycle, completedCompetition.lifecycle)
        let newPending = try XCTUnwrap(
            rematched.dashboard.competitions.first { $0.id == rematchID }
        )
        guard case .pending(direction: .outgoing, _, _) = newPending.lifecycle else {
            return XCTFail("Rematch must append a new deterministic pending invite")
        }
        await reducerStore.receive(
            .commandFinished(sourceID, expectedRevision: 13)
        ) {
            $0.commandExpectedPublicationRevisions[sourceID] = 13
        }
        await reducerStore.receive(.publication(rematched)) {
            $0.publication = rematched
            $0.commandIDsInFlight.remove(sourceID)
            $0.commandExpectedPublicationRevisions[sourceID] = nil
        }

        let optionalLoadedAfterRematch = try await journalStore.load(sourceID)
        let loadedAfterRematch = try XCTUnwrap(optionalLoadedAfterRematch)
        XCTAssertEqual(loadedAfterRematch.journal, sourceJournalBeforeRematch)
        let loadedRematch = try await journalStore.load(rematchID)
        XCTAssertNotNil(loadedRematch)

        await reducerStore.send(.stop)
        await waitForNoFixtureWaiters(source)
        await reducerStore.finish()
    }

    @MainActor
    func testPublicationAcceptsOnlyStrictlyNewerRevisions() async {
        let revisionTwo = publication(revision: 2)
        let revisionOne = publication(revision: 1)
        let duplicateRevisionTwo = publication(revision: 2)
        let revisionThree = publication(revision: 3)
        let store = TestStore(initialState: CompetitionFeature.State()) {
            CompetitionFeature()
        }

        await store.send(.publication(revisionTwo)) {
            $0.publication = revisionTwo
        }
        await store.send(.publication(revisionOne))
        await store.send(.publication(duplicateRevisionTwo))
        await store.send(.publication(revisionThree)) {
            $0.publication = revisionThree
        }
    }

    @MainActor
    func testRepeatedTaskKeepsOneActiveReducerSubscription() async {
        let harness = CompetitionReducerStreamHarness()
        let store = TestStore(initialState: CompetitionFeature.State()) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = harness.client
        }

        await store.send(.task)
        await harness.waitForActiveSubscriberCount(1)
        XCTAssertEqual(harness.startCount, 1)

        await store.send(.task)
        await harness.waitForStartCount(2)
        await harness.waitForActiveSubscriberCount(1)

        await store.send(.stop)
        await harness.waitForActiveSubscriberCount(0)
        await store.finish()

        XCTAssertEqual(harness.stopCount, 1)
        XCTAssertEqual(
            harness.events,
            [
                .streamStarted,
                .streamCancelled,
                .streamStarted,
                .streamCancelled,
                .clientStopped,
            ]
        )
    }

    @MainActor
    func testTaskConsumesCanonicalStartStream() async {
        let harness = CompetitionReducerStreamHarness()
        let store = TestStore(initialState: CompetitionFeature.State()) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = harness.client
        }
        let first = publication(revision: 1)
        let second = publication(revision: 2)

        await store.send(.task)
        await harness.waitForActiveSubscriberCount(1)
        harness.publish(first)
        await store.receive(.publication(first)) {
            $0.publication = first
        }
        harness.publish(second)
        await store.receive(.publication(second)) {
            $0.publication = second
        }

        await store.send(.stop)
        await store.finish()
    }

    @MainActor
    func testTaskLoadsPersistedMutedOpponentIdentities() async {
        let identity = LocalCompetitionIdentity.opponentIdentity
        var client = CompetitionReducerClientRecorder().client(
            returning: publication(revision: 1)
        )
        client.loadMutedOpponentIdentities = { [identity] in [identity] }
        let store = TestStore(initialState: CompetitionFeature.State()) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = client
        }

        await store.send(.task)
        await store.receive(.mutePreferencesLoaded([identity])) {
            $0.mutedOpponentIdentities = [identity]
        }
        await store.finish()
    }

    @MainActor
    func testMuteOptimisticallyUpdatesAndGuardsStableOpponentIdentity()
        async {
        let identity = LocalCompetitionIdentity.opponentIdentity
        let gate = CompetitionMutePreferenceGate()
        var client = CompetitionReducerClientRecorder().client(
            returning: publication(revision: 1)
        )
        client.setNotificationMuted = { identity, isMuted in
            try await gate.setMuted(identity, isMuted)
        }
        let store = TestStore(initialState: CompetitionFeature.State()) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = client
        }

        await store.send(.muteTapped(identity)) {
            $0.mutedOpponentIdentities.insert(identity)
            $0.muteOpponentIdentitiesInFlight.insert(identity)
            $0.notificationPreferenceSaveFailed = false
        }
        await gate.waitForCallCount(1)
        await store.send(.muteTapped(identity))
        let callCount = await gate.callCount
        XCTAssertEqual(callCount, 1)
        await gate.release()
        await store.receive(
            .muteFinished(identity, isMuted: true, succeeded: true)
        ) {
            $0.muteOpponentIdentitiesInFlight.remove(identity)
        }
        await store.finish()
    }

    @MainActor
    func testMutePersistenceFailureRollsBackOptimisticState() async {
        let identity = LocalCompetitionIdentity.opponentIdentity
        var client = CompetitionReducerClientRecorder().client(
            returning: publication(revision: 1)
        )
        client.setNotificationMuted = { _, _ in
            throw CompetitionFeatureFixtureError.preferenceWriteFailed
        }
        let store = TestStore(initialState: CompetitionFeature.State()) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = client
        }

        await store.send(.muteTapped(identity)) {
            $0.mutedOpponentIdentities.insert(identity)
            $0.muteOpponentIdentitiesInFlight.insert(identity)
            $0.notificationPreferenceSaveFailed = false
        }
        await store.receive(
            .muteFinished(identity, isMuted: true, succeeded: false)
        ) {
            $0.mutedOpponentIdentities.remove(identity)
            $0.muteOpponentIdentitiesInFlight.remove(identity)
            $0.notificationPreferenceSaveFailed = true
        }
        await store.finish()
    }

    @MainActor
    func testDeleteUsesPerIDGuardUntilCanonicalRevisionAcknowledgesIt()
        async {
        let id = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F69602A")!
        )
        let current = publication(revision: 1)
        let returned = publication(revision: 2)
        let recorder = CompetitionDeleteRecorder(returning: returned)
        var client = CompetitionReducerClientRecorder().client(
            returning: returned
        )
        client.delete = { id in await recorder.delete(id) }
        let store = TestStore(
            initialState: CompetitionFeature.State(publication: current)
        ) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = client
        }

        await store.send(.deleteTapped(id)) {
            $0.commandIDsInFlight.insert(id)
        }
        await store.receive(.commandFinished(id, expectedRevision: 2)) {
            $0.commandExpectedPublicationRevisions[id] = 2
        }
        await store.send(.deleteTapped(id))
        let deletedIDs = await recorder.deletedIDs
        XCTAssertEqual(deletedIDs, [id])
        await store.send(.publication(returned)) {
            $0.publication = returned
            $0.commandIDsInFlight.remove(id)
            $0.commandExpectedPublicationRevisions[id] = nil
        }
        await store.finish()
    }

    @MainActor
    func testNotificationAuthorizationIsRequestedOnlyByExplicitIntent()
        async {
        let recorder = CompetitionAuthorizationRecorder()
        var client = CompetitionReducerClientRecorder().client(
            returning: publication(revision: 1)
        )
        client.requestNotificationAuthorization = {
            await recorder.request()
            return .authorized
        }
        let store = TestStore(
            initialState: CompetitionFeature.State(
                notificationAuthorizationState: .notDetermined
            )
        ) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = client
        }

        let initialRequestCount = await recorder.requestCount
        XCTAssertEqual(initialRequestCount, 0)
        await store.send(.enableNotificationsTapped) {
            $0.notificationAuthorizationRequestIsInFlight = true
        }
        await store.receive(
            .notificationAuthorizationRequestFinished(.authorized)
        ) {
            $0.notificationAuthorizationState = .authorized
            $0.notificationAuthorizationRequestIsInFlight = false
        }
        let finalRequestCount = await recorder.requestCount
        XCTAssertEqual(finalRequestCount, 1)
        await store.finish()
    }

    @MainActor
    func testCommandsCallClientAndIgnoreReturnedPublications() async {
        let recorder = CompetitionReducerClientRecorder()
        let returned = publication(revision: 99)
        let client = recorder.client(returning: returned)
        let store = TestStore(initialState: CompetitionFeature.State()) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = client
        }
        let id = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696026")!
        )

        await store.send(.acceptTapped(id)) {
            $0.commandIDsInFlight.insert(id)
        }
        await store.receive(.commandFinished(id, expectedRevision: 99)) {
            $0.commandExpectedPublicationRevisions[id] = 99
        }
        await store.send(.publication(returned)) {
            $0.publication = returned
            $0.commandIDsInFlight.remove(id)
            $0.commandExpectedPublicationRevisions[id] = nil
        }
        await store.send(.declineTapped(id)) {
            $0.commandIDsInFlight.insert(id)
        }
        await store.receive(.commandFinished(id, expectedRevision: 99)) {
            $0.commandIDsInFlight.remove(id)
        }
        await store.send(.archiveTapped(id)) {
            $0.commandIDsInFlight.insert(id)
        }
        await store.receive(.commandFinished(id, expectedRevision: 99)) {
            $0.commandIDsInFlight.remove(id)
        }
        await store.send(.rematchTapped(id)) {
            $0.commandIDsInFlight.insert(id)
        }
        await store.receive(.commandFinished(id, expectedRevision: 99)) {
            $0.commandIDsInFlight.remove(id)
        }
        let reinviteID = LocalCompetitionIdentity.bootstrapCompetitionID
        await store.send(.reinviteTapped) {
            $0.commandIDsInFlight.insert(reinviteID)
        }
        await store.receive(
            .commandFinished(reinviteID, expectedRevision: 99)
        ) {
            $0.commandIDsInFlight.remove(reinviteID)
        }
        await store.finish()

        XCTAssertEqual(store.state.publication, returned)
        XCTAssertEqual(
            recorder.invocations,
            [.accept(id), .decline(id), .archive(id), .rematch(id), .reinvite]
        )
    }

    @MainActor
    func testPerIDCommandGuardSuppressesDoubleTapUntilCommandFinishes() async {
        let returned = publication(revision: 99)
        let gate = CompetitionBlockingCommandGate()
        let recorder = CompetitionReducerClientRecorder()
        var client = recorder.client(returning: returned)
        client.accept = { id in
            await gate.run(id: id, returning: returned)
        }
        let store = TestStore(initialState: CompetitionFeature.State()) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = client
        }
        let firstID = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696027")!
        )
        let secondID = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696028")!
        )

        await store.send(.acceptTapped(firstID)) {
            $0.commandIDsInFlight = [firstID]
        }
        await gate.waitForCallCount(1)
        await store.send(.rematchTapped(firstID))
        let blockedCallCount = await gate.callCount
        XCTAssertEqual(blockedCallCount, 1)

        await store.send(.declineTapped(secondID)) {
            $0.commandIDsInFlight.insert(secondID)
        }
        await store.receive(
            .commandFinished(secondID, expectedRevision: 99)
        ) {
            $0.commandExpectedPublicationRevisions[secondID] = 99
        }
        await store.send(.publication(returned)) {
            $0.publication = returned
            $0.commandIDsInFlight.remove(secondID)
            $0.commandExpectedPublicationRevisions[secondID] = nil
        }
        XCTAssertEqual(recorder.invocations, [.decline(secondID)])

        await gate.release()
        await store.receive(
            .commandFinished(firstID, expectedRevision: 99)
        ) {
            $0.commandIDsInFlight.remove(firstID)
        }
        await store.finish()
    }

    @MainActor
    func testCommandStaysGuardedUntilReturnedRevisionArrivesOnCanonicalStream() async {
        let id = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696029")!
        )
        let recorder = CompetitionReducerClientRecorder()
        let current = publication(revision: 1)
        let next = publication(revision: 2)
        let store = TestStore(
            initialState: CompetitionFeature.State(publication: current)
        ) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client(returning: next)
        }

        await store.send(.acceptTapped(id)) {
            $0.commandIDsInFlight.insert(id)
        }
        await store.receive(.commandFinished(id, expectedRevision: 2)) {
            $0.commandExpectedPublicationRevisions[id] = 2
        }
        await store.send(.acceptTapped(id))
        XCTAssertEqual(recorder.invocations, [.accept(id)])

        await store.send(.publication(next)) {
            $0.publication = next
            $0.commandIDsInFlight.remove(id)
            $0.commandExpectedPublicationRevisions[id] = nil
        }
        await store.finish()
    }

    @MainActor
    func testRefreshAndLifecycleActionsForwardExactTriggers() async {
        let recorder = CompetitionReducerClientRecorder()
        let client = recorder.client(returning: publication(revision: 1))
        let store = TestStore(initialState: CompetitionFeature.State()) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = client
        }

        await store.send(.pullToRefresh)
        await store.send(.sceneBecameActive)
        await store.send(.timeZoneChanged)
        await store.finish()

        XCTAssertNil(store.state.publication)
        XCTAssertEqual(
            recorder.invocations,
            [
                .reconcile(.pullToRefresh),
                .reconcile(.foreground),
                .reconcile(.timeZoneChange),
            ]
        )
    }

    func testScoreVisibilityBeginsOnlyWhenDayOneStarts() {
        let pendingDate = Date(timeIntervalSinceReferenceDate: 1)
        XCTAssertFalse(
            competitionShouldShowScores(
                .pending(
                    direction: .outgoing,
                    createdAt: pendingDate,
                    expiresAt: nil
                )
            )
        )
        XCTAssertFalse(competitionShouldShowScores(.scheduled))
        XCTAssertTrue(competitionShouldShowScores(.active(dayOrdinal: 1)))
        XCTAssertTrue(competitionShouldShowScores(.endsToday))
        XCTAssertTrue(
            competitionShouldShowScores(.tallying(startedAt: pendingDate))
        )
    }

    private func publication(revision: UInt64) -> LocalCompetitionPublication {
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

    private func assertFutureDaysArePrivate(
        _ competition: LocalCompetitionPresentation,
        afterCurrentOrdinal currentOrdinal: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            competition.days.map(\.ordinal),
            Array(1...7),
            file: file,
            line: line
        )
        for day in competition.days.dropFirst(currentOrdinal) {
            XCTAssertEqual(
                day.ownerLatestAvailability,
                .notYetOccurred,
                file: file,
                line: line
            )
            XCTAssertNil(day.ownerAcceptedPoints, file: file, line: line)
            XCTAssertNil(day.opponentRevealedPoints, file: file, line: line)
            XCTAssertEqual(
                competitionPointsText(day.ownerAcceptedPoints),
                "--",
                file: file,
                line: line
            )
            XCTAssertEqual(
                competitionPointsText(day.opponentRevealedPoints),
                "--",
                file: file,
                line: line
            )
        }
    }

    private func waitForExactlyOneFixtureWaiter(
        _ source: FixtureActivitySource,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var count = await source.pendingWaiterCount()
        for _ in 0..<10_000 where count != 1 {
            await Task.yield()
            count = await source.pendingWaiterCount()
        }
        XCTAssertEqual(count, 1, file: file, line: line)
    }

    private func waitForNoFixtureWaiters(
        _ source: FixtureActivitySource,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var count = await source.pendingWaiterCount()
        for _ in 0..<10_000 where count != 0 {
            await Task.yield()
            count = await source.pendingWaiterCount()
        }
        XCTAssertEqual(count, 0, file: file, line: line)
    }

    private func assertCanonicalLifecycleJournal(
        _ journal: CompetitionJournal,
        competitionID: CompetitionID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let events = try journal.envelopes.map {
            try decoder.decode(CompetitionDomainEvent.self, from: $0.payload)
        }
        XCTAssertEqual(
            journal.envelopes.map(\.sequence),
            Array(1...25).map(UInt64.init),
            file: file,
            line: line
        )
        XCTAssertEqual(
            journal.envelopes.map(\.semanticEventID),
            events.map(\.semanticEventID),
            file: file,
            line: line
        )
        XCTAssertTrue(
            events.allSatisfy { $0.competitionID == competitionID },
            file: file,
            line: line
        )

        let attemptOrdinalPairs: [(String, UInt64)] = events.compactMap { event in
            guard case let .activityRefreshAttemptRecorded(attempt) = event
            else { return nil }
            return (attempt.attemptID, attempt.attemptOrdinal)
        }
        let attemptOrdinals = Dictionary(
            uniqueKeysWithValues: attemptOrdinalPairs
        )
        let semanticOrder = events.map { event -> String in
            switch event {
            case let .activityRefreshAttemptRecorded(attempt):
                return "refresh-\(attempt.attemptOrdinal)-\(attempt.trigger.rawValue)"
            case .activitySnapshotRecorded:
                return "unexpected-standalone-snapshot"
            case .notificationEmissionRecorded:
                return "unexpected-notification-emission"
            case .remoteConfigurationAccepted,
                 .remoteScoreRevisionRecorded,
                 .remoteFinalWindowAttested,
                 .sharedResultConfirmed,
                 .synchronizationReceiptRecorded:
                return "unexpected-remote-evidence"
            case let .lifecycle(lifecycle):
                switch lifecycle.kind {
                case .invitationAccepted: return "invitation-accepted"
                case .invitationDeclined: return "invitation-declined"
                case .invitationExpired: return "invitation-expired"
                case .competitionStarted: return "competition-started"
                case let .dayClosed(ordinal): return "day-\(ordinal)-closed"
                case .finalDayStarted: return "final-day-started"
                case .tallyStarted: return "tally-started"
                case let .finalReadRecorded(record):
                    return "final-read-\(attemptOrdinals[record.evidence.attemptID] ?? 0)"
                case .competitionFinalized: return "competition-finalized"
                case .competitionArchived: return "competition-archived"
                }
            }
        }
        XCTAssertEqual(
            semanticOrder,
            [
                "invitation-accepted",
                "competition-started",
                "refresh-1-reconciliationProbe",
                "day-1-closed",
                "refresh-2-reconciliationProbe",
                "day-2-closed",
                "refresh-3-reconciliationProbe",
                "day-3-closed",
                "refresh-4-reconciliationProbe",
                "day-4-closed",
                "refresh-5-reconciliationProbe",
                "day-5-closed",
                "refresh-6-reconciliationProbe",
                "day-6-closed",
                "final-day-started",
                "refresh-7-reconciliationProbe",
                "day-7-closed",
                "tally-started",
                "refresh-8-reconciliationProbe",
                "final-read-8",
                "refresh-9-summaryUpdate",
                "final-read-9",
                "refresh-10-reconciliationProbe",
                "final-read-10",
                "competition-finalized",
            ],
            file: file,
            line: line
        )
        XCTAssertEqual(
            journal.envelopes.map(\.commitRevision),
            [
                1,
                2, 2,
                3, 3,
                4, 4,
                5, 5,
                6, 6,
                7, 7,
                8, 8, 8,
                9, 9, 9, 9,
                10, 10,
                11, 11, 11,
            ],
            file: file,
            line: line
        )
        XCTAssertEqual(journal.cursor.eventCount, 25, file: file, line: line)
        XCTAssertEqual(journal.cursor.commitRevision, 11, file: file, line: line)
    }
}

private actor CompetitionLifecyclePublicationCapture {
    private var publications: [LocalCompetitionPublication] = []
    private var waiters: [
        Int: [CheckedContinuation<LocalCompetitionPublication, Never>]
    ] = [:]

    func record(_ publication: LocalCompetitionPublication) {
        publications.append(publication)
        let index = publications.count - 1
        for waiter in waiters.removeValue(forKey: index) ?? [] {
            waiter.resume(returning: publication)
        }
    }

    func publication(at index: Int) async -> LocalCompetitionPublication {
        if publications.indices.contains(index) {
            return publications[index]
        }
        return await withCheckedContinuation { continuation in
            waiters[index, default: []].append(continuation)
        }
    }
}

private func clientRecordingCanonicalPublications(
    from client: CompetitionClient,
    into capture: CompetitionLifecyclePublicationCapture
) -> CompetitionClient {
    let start = client.start
    var recordingClient = client
    recordingClient.start = {
        let upstream = start()
        return AsyncStream { continuation in
            let forwardingTask = Task {
                for await publication in upstream {
                    await capture.record(publication)
                    continuation.yield(publication)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                forwardingTask.cancel()
            }
        }
    }
    return recordingClient
}

final class CompetitionReducerStreamHarness: @unchecked Sendable {
    enum Event: Equatable {
        case streamStarted
        case streamCancelled
        case clientStopped
    }

    private struct State {
        var continuations: [
            UUID: AsyncStream<LocalCompetitionPublication>.Continuation
        ] = [:]
        var startCount = 0
        var stopCount = 0
        var events: [Event] = []
    }

    private let lock = NSLock()
    private var state = State()

    var activeSubscriberCount: Int {
        lock.withLock { state.continuations.count }
    }

    var startCount: Int {
        lock.withLock { state.startCount }
    }

    var stopCount: Int {
        lock.withLock { state.stopCount }
    }

    var events: [Event] {
        lock.withLock { state.events }
    }

    var client: CompetitionClient {
        CompetitionClient(
            start: { [weak self] in self?.stream() ?? Self.finishedStream() },
            updates: { Self.finishedStream() },
            reconcileAll: { _ in Self.emptyPublication },
            accept: { _ in Self.emptyPublication },
            decline: { _ in Self.emptyPublication },
            archive: { _ in Self.emptyPublication },
            rematch: { _ in Self.emptyPublication },
            reinvite: { Self.emptyPublication },
            waitUntil: { _ in },
            stop: { [weak self] in
                self?.lock.withLock {
                    self?.state.stopCount += 1
                    self?.state.events.append(.clientStopped)
                }
            }
        )
    }

    func publish(_ publication: LocalCompetitionPublication) {
        let continuations = lock.withLock {
            Array(state.continuations.values)
        }
        for continuation in continuations {
            continuation.yield(publication)
        }
    }

    func waitForActiveSubscriberCount(_ count: Int) async {
        for _ in 0..<1_000 where activeSubscriberCount != count {
            await Task.yield()
        }
        XCTAssertEqual(activeSubscriberCount, count)
    }

    func waitForStartCount(_ count: Int) async {
        for _ in 0..<1_000 where startCount != count {
            await Task.yield()
        }
        XCTAssertEqual(startCount, count)
    }

    private func stream() -> AsyncStream<LocalCompetitionPublication> {
        let token = UUID()
        return AsyncStream { continuation in
            lock.withLock {
                state.startCount += 1
                state.events.append(.streamStarted)
                state.continuations[token] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.state.continuations[token] = nil
                    self?.state.events.append(.streamCancelled)
                }
            }
        }
    }

    private static func finishedStream() -> AsyncStream<LocalCompetitionPublication> {
        AsyncStream { $0.finish() }
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

private final class CompetitionReducerClientRecorder: @unchecked Sendable {
    enum Invocation: Equatable {
        case accept(CompetitionID)
        case decline(CompetitionID)
        case archive(CompetitionID)
        case rematch(CompetitionID)
        case reinvite
        case reconcile(ActivityRefreshTrigger)
    }

    private let lock = NSLock()
    private var values: [Invocation] = []

    var invocations: [Invocation] {
        lock.withLock { values }
    }

    func client(
        returning publication: LocalCompetitionPublication
    ) -> CompetitionClient {
        CompetitionClient(
            start: { AsyncStream { $0.finish() } },
            updates: { AsyncStream { $0.finish() } },
            reconcileAll: { [weak self] trigger in
                self?.append(.reconcile(trigger))
                return publication
            },
            accept: { [weak self] id in
                self?.append(.accept(id))
                return publication
            },
            decline: { [weak self] id in
                self?.append(.decline(id))
                return publication
            },
            archive: { [weak self] id in
                self?.append(.archive(id))
                return publication
            },
            rematch: { [weak self] id in
                self?.append(.rematch(id))
                return publication
            },
            reinvite: { [weak self] in
                self?.append(.reinvite)
                return publication
            },
            waitUntil: { _ in },
            stop: {}
        )
    }

    private func append(_ invocation: Invocation) {
        lock.withLock { values.append(invocation) }
    }
}

private actor CompetitionBlockingCommandGate {
    private var calls: [CompetitionID] = []
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var callCount: Int { calls.count }

    func run(
        id: CompetitionID,
        returning publication: LocalCompetitionPublication
    ) async -> LocalCompetitionPublication {
        calls.append(id)
        let waiters = callWaiters
        callWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return publication
    }

    func waitForCallCount(_ count: Int) async {
        while calls.count < count {
            await withCheckedContinuation { continuation in
                callWaiters.append(continuation)
            }
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private enum CompetitionFeatureFixtureError: Error {
    case preferenceWriteFailed
}

private actor CompetitionMutePreferenceGate {
    private var calls: [(String, Bool)] = []
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var callCount: Int { calls.count }

    func setMuted(_ identity: String, _ isMuted: Bool) async throws {
        calls.append((identity, isMuted))
        let waiters = callWaiters
        callWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForCallCount(_ count: Int) async {
        while calls.count < count {
            await withCheckedContinuation { continuation in
                callWaiters.append(continuation)
            }
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CompetitionDeleteRecorder {
    private let publication: LocalCompetitionPublication
    private(set) var deletedIDs: [CompetitionID] = []

    init(returning publication: LocalCompetitionPublication) {
        self.publication = publication
    }

    func delete(_ id: CompetitionID) -> LocalCompetitionPublication {
        deletedIDs.append(id)
        return publication
    }
}

private actor CompetitionAuthorizationRecorder {
    private(set) var requestCount = 0

    func request() {
        requestCount += 1
    }
}
