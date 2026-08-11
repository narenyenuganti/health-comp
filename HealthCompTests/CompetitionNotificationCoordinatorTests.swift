import CompetitionCore
import Foundation
import XCTest
@testable import HealthComp

final class CompetitionNotificationCoordinatorTests: XCTestCase {
    func testJournalAppendPrecedesImmediatePost() async throws {
        let recorder = NotificationOperationRecorder()
        let snapshot = try resultSnapshot()
        let notifications = recorder.notificationClient(
            authorization: .authorized
        )
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: notifications,
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { competition, replan in
                let decisions = try replan(competition)
                guard !decisions.isEmpty else {
                    return .noDecision
                }
                for decision in decisions {
                    await recorder.record(
                        "append:\(decision.record.semanticEventID)"
                    )
                }
                return .appended(decisions)
            }
        )

        await coordinator.submit(snapshot)

        let operations = await recorder.operations
        let appendIndex = try XCTUnwrap(
            operations.firstIndex { $0.hasPrefix("append:") }
        )
        let postIndex = try XCTUnwrap(
            operations.firstIndex { $0.hasPrefix("post:") }
        )
        XCTAssertLessThan(appendIndex, postIndex)
    }

    func testSupersedingSnapshotAfterAppendDoesNotSwallowCommittedPost()
        async throws {
        let gate = NotificationCommitReturnGate()
        let recorder = NotificationOperationRecorder()
        let commits = CommitOnceRecorder()
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: recorder.notificationClient(
                authorization: .authorized
            ),
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { competition, replan in
                let result = try await commits.commit(
                    competition,
                    replan: replan
                )
                guard case .appended = result else { return result }
                await gate.didAppendAndWaitToReturn()
                return result
            }
        )

        let older = try resultSnapshot(revision: 9)
        let newer = try resultSnapshot(revision: 10)
        let inFlight = Task { await coordinator.submit(older) }
        await gate.waitUntilAppended()

        await coordinator.submit(newer)
        await gate.releaseCommitReturn()
        await inFlight.value

        let operations = await recorder.operations
        XCTAssertEqual(
            operations.filter { $0.hasPrefix("post:") }.count,
            1
        )
    }

    func testDuplicateEmissionNeverPostsAgain() async throws {
        let recorder = NotificationOperationRecorder()
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: recorder.notificationClient(
                authorization: .authorized
            ),
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { _, _ in .duplicate }
        )

        await coordinator.submit(try resultSnapshot())

        let operations = await recorder.operations
        XCTAssertFalse(operations.contains { $0.hasPrefix("post:") })
    }

    func testDeniedSettingsNeitherAppendNorPost() async throws {
        let recorder = NotificationOperationRecorder()
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: recorder.notificationClient(authorization: .denied),
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { _, _ in .noDecision }
        )

        await coordinator.submit(try resultSnapshot())

        let operations = await recorder.operations
        XCTAssertFalse(
            operations.contains {
                $0.hasPrefix("append:") || $0.hasPrefix("post:")
            }
        )
    }

    func testDeniedSettingsStillCleanUpDeclinedCompetitionRequests()
        async throws {
        let recorder = CleanupOperationRecorder()
        let snapshot = try resultSnapshot(lifecycle: .declined)
        let competition = try XCTUnwrap(snapshot.competitions.first)
        let pendingID = CompetitionNotificationIdentifier.scheduled(
            competitionID: competition.id,
            family: .inviteExpiry
        )
        let deliveredID = try NotificationEmissionRecorded.semanticID(
            competitionID: competition.id,
            family: .leadChange,
            episodeKey: .leader(dayOrdinal: 1, leader: .owner)
        )
        await recorder.configure(
            pending: [pendingID],
            delivered: [deliveredID]
        )
        var notifications = recorder.client
        notifications.authorizationState = { .denied }
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: notifications,
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { _, _ in .noDecision }
        )

        await coordinator.submit(snapshot)

        let remainingPending = await recorder.pending
        let remainingDelivered = await recorder.delivered
        XCTAssertTrue(remainingPending.isEmpty)
        XCTAssertTrue(remainingDelivered.isEmpty)
    }

    func testUnknownScheduledRequestStateRefreshesAndSecondPassAddsNothing()
        async throws {
        let center = StatefulNotificationCenterRecorder()
        let snapshot = try scheduledSnapshot()
        let id = try XCTUnwrap(snapshot.competitions.first?.id)
        let alreadyPending = CompetitionNotificationIdentifier.scheduled(
            competitionID: id,
            family: .scheduledStart
        )
        await center.setPending([
            alreadyPending,
            "competition-notification:v1:\(id.rawValue.uuidString.lowercased()):obsolete",
        ])
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: center.client,
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { _, _ in .noDecision }
        )

        await coordinator.submit(snapshot)
        let firstPass = await center.snapshot
        XCTAssertEqual(firstPass.removedPending.count, 1)
        XCTAssertEqual(firstPass.upserts.count, 3)

        await coordinator.submit(snapshot)
        let secondPass = await center.snapshot
        XCTAssertEqual(secondPass.removedPending.count, 1)
        XCTAssertEqual(secondPass.upserts.count, 3)
    }

    func testStableScheduledIdentifiersRefreshWhenTriggersChange()
        async throws {
        let center = StatefulNotificationCenterRecorder()
        let original = try scheduledSnapshot()
        let competition = try XCTUnwrap(original.competitions.first)
        let schedule = try XCTUnwrap(competition.schedule)
        let shifted = replacingSchedule(
            in: competition,
            with: CompetitionSchedule(
                calendar: schedule.calendar,
                startDay: try schedule.calendar.day(after: schedule.startDay)
            )
        )
        let changed = CompetitionNotificationPlanningSnapshot(
            publicationRevision: original.publicationRevision + 1,
            evaluatedAt: original.evaluatedAt,
            timeZoneIdentifier: original.timeZoneIdentifier,
            competitions: [shifted]
        )
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: center.client,
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { _, _ in .noDecision }
        )

        await coordinator.submit(original)
        let originalRequests = await center.snapshot.upserts
        await coordinator.submit(changed)
        let allRequests = await center.snapshot.upserts

        XCTAssertEqual(originalRequests.count, 3)
        XCTAssertEqual(allRequests.count, 6)
        XCTAssertEqual(
            Set(originalRequests.map(\.identifier)),
            Set(allRequests.suffix(3).map(\.identifier))
        )
        XCTAssertNotEqual(
            originalRequests.map(\.dateComponents),
            Array(allRequests.suffix(3)).map(\.dateComponents)
        )
    }

    func testOlderSnapshotCannotRegressWhileNewerSnapshotIsInFlight()
        async throws {
        let gate = NotificationAuthorizationGate()
        let recorder = NotificationOperationRecorder()
        let revisions = NotificationRevisionRecorder()
        var notifications = recorder.notificationClient(
            authorization: .authorized
        )
        notifications.authorizationState = {
            await gate.authorizationState()
        }
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: notifications,
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { competition, replan in
                let decisions = try replan(competition)
                guard !decisions.isEmpty else {
                    return .noDecision
                }
                for decision in decisions {
                    await revisions.append(
                        decision.record.basisPublicationRevision
                    )
                }
                return .appended(decisions)
            }
        )
        let newer = try resultSnapshot(revision: 12)
        let older = try resultSnapshot(revision: 11)

        let inFlight = Task { await coordinator.submit(newer) }
        await gate.waitUntilRequested()
        await coordinator.submit(older)
        await gate.release()
        await inFlight.value

        let committedRevisions = await revisions.values
        XCTAssertEqual(committedRevisions, [12])
    }

    func testNewerSnapshotSupersedesOlderSnapshotWaitingOnAuthorization()
        async throws {
        let gate = NotificationAuthorizationGate()
        let recorder = NotificationOperationRecorder()
        let revisions = NotificationRevisionRecorder()
        var notifications = recorder.notificationClient(
            authorization: .authorized
        )
        notifications.authorizationState = {
            await gate.authorizationState()
        }
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: notifications,
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { competition, replan in
                let decisions = try replan(competition)
                for decision in decisions {
                    await revisions.append(
                        decision.record.basisPublicationRevision
                    )
                }
                return decisions.isEmpty ? .noDecision : .appended(decisions)
            }
        )
        let older = try resultSnapshot(revision: 11)
        let newer = try resultSnapshot(revision: 12)

        let inFlight = Task { await coordinator.submit(older) }
        await gate.waitUntilRequested()
        await coordinator.submit(newer)
        await gate.release()
        await inFlight.value

        let committedRevisions = await revisions.values
        XCTAssertEqual(committedRevisions, [12])
    }

    func testPreferenceReadFailureCancelsPendingWithoutBurningHistory()
        async throws {
        let center = StatefulNotificationCenterRecorder()
        let snapshot = try scheduledSnapshot()
        let id = try XCTUnwrap(snapshot.competitions.first?.id)
        await center.setPending([
            CompetitionNotificationIdentifier.scheduled(
                competitionID: id,
                family: .scheduledStart
            ),
        ])
        let commits = NotificationRevisionRecorder()
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: center.client,
            preferences: CompetitionNotificationPreferencesClient(
                mutedOpponentIdentities: {
                    throw CoordinatorFixtureError.preferencesUnavailable
                },
                setMuted: { _, _ in }
            ),
            commitDecisions: { competition, replan in
                let decisions = try replan(competition)
                guard !decisions.isEmpty else {
                    return .noDecision
                }
                for decision in decisions {
                    await commits.append(
                        decision.record.basisPublicationRevision
                    )
                }
                return .appended(decisions)
            }
        )

        await coordinator.submit(snapshot)

        let centerSnapshot = await center.snapshot
        let committed = await commits.values
        XCTAssertEqual(centerSnapshot.removedPending.count, 1)
        XCTAssertTrue(centerSnapshot.upserts.isEmpty)
        XCTAssertTrue(committed.isEmpty)
    }

    func testOrphanCleanupRunsOnlyAfterSuccessfulStoreEnumeration()
        async throws {
        let center = CleanupOperationRecorder()
        let id = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F69604F")!
        )
        let pendingID = CompetitionNotificationIdentifier.scheduled(
            competitionID: id,
            family: .finalDay
        )
        let deliveredID = try NotificationEmissionRecorded.semanticID(
            competitionID: id,
            family: .result,
            episodeKey: .result
        )
        await center.configure(
            pending: [pendingID],
            delivered: [deliveredID]
        )
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(
                policy: .coordinatorFixture
            ),
            notifications: center.client,
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { _, _ in .noDecision }
        )
        let failedEnumeration = CompetitionNotificationPlanningSnapshot(
            publicationRevision: 1,
            evaluatedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            timeZoneIdentifier: "UTC",
            competitions: [],
            knownCompetitionIDs: nil
        )

        await coordinator.submit(failedEnumeration)
        let pendingAfterFailure = await center.pending
        let deliveredAfterFailure = await center.delivered
        XCTAssertEqual(pendingAfterFailure, [pendingID])
        XCTAssertEqual(deliveredAfterFailure, [deliveredID])

        let successfulEmptyEnumeration =
            CompetitionNotificationPlanningSnapshot(
                publicationRevision: 2,
                evaluatedAt: Date(timeIntervalSinceReferenceDate: 1_001),
                timeZoneIdentifier: "UTC",
                competitions: [],
                knownCompetitionIDs: []
            )
        await coordinator.submit(successfulEmptyEnumeration)

        let pendingAfterSuccess = await center.pending
        let deliveredAfterSuccess = await center.delivered
        XCTAssertTrue(pendingAfterSuccess.isEmpty)
        XCTAssertTrue(deliveredAfterSuccess.isEmpty)
    }

    func testPostFailureIsNotRetriedAfterDurableDecision() async throws {
        let center = FailingPostNotificationCenter()
        let committer = CommitOnceRecorder()
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: center.client,
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { competition, replan in
                try await committer.commit(competition, replan: replan)
            }
        )
        let snapshot = try resultSnapshot()

        await coordinator.submit(snapshot)
        await coordinator.submit(snapshot)

        let postCount = await center.postCount
        let commitCount = await committer.callCount
        XCTAssertEqual(postCount, 1)
        XCTAssertEqual(commitCount, 2)
    }

    func testArchiveCleanupRunsBeforeResultAppendAndKeepsDeliveredResult()
        async throws {
        let recorder = CleanupOperationRecorder()
        let snapshot = try resultSnapshot(lifecycle: .archived)
        let competition = try XCTUnwrap(snapshot.competitions.first)
        let leadID = try NotificationEmissionRecorded.semanticID(
            competitionID: competition.id,
            family: .leadChange,
            episodeKey: .leader(dayOrdinal: 7, leader: .owner)
        )
        let resultID = try NotificationEmissionRecorded.semanticID(
            competitionID: competition.id,
            family: .result,
            episodeKey: .result
        )
        await recorder.configure(
            pending: [
                CompetitionNotificationIdentifier.scheduled(
                    competitionID: competition.id,
                    family: .competitionEnded
                ),
            ],
            delivered: [leadID, resultID]
        )
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: recorder.client,
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { competition, replan in
                let decisions = try replan(competition)
                guard !decisions.isEmpty else {
                    return .noDecision
                }
                for decision in decisions {
                    await recorder.append(decision.record.semanticEventID)
                }
                return .appended(decisions)
            }
        )

        await coordinator.submit(snapshot)

        let operations = await recorder.operations
        XCTAssertEqual(
            operations.map(\.kind),
            [.removePending, .removeDelivered, .append, .post]
        )
        XCTAssertEqual(operations[1].identifiers, [leadID])
        let remainingDelivered = await recorder.delivered
        XCTAssertEqual(remainingDelivered, [resultID])
    }

    func testCancelAllRemovesOnlyCompetitionScopedPendingAndDelivered()
        async throws {
        let recorder = CleanupOperationRecorder()
        let id = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696062")!
        )
        let other = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696063")!
        )
        let ownPending = CompetitionNotificationIdentifier.scheduled(
            competitionID: id,
            family: .finalDay
        )
        let otherPending = CompetitionNotificationIdentifier.scheduled(
            competitionID: other,
            family: .finalDay
        )
        await recorder.configure(
            pending: [ownPending, otherPending],
            delivered: [ownPending, otherPending]
        )
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: recorder.client,
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { _, _ in .noDecision }
        )

        await coordinator.cancelAll(id)

        let remainingPending = await recorder.pending
        let remainingDelivered = await recorder.delivered
        XCTAssertEqual(remainingPending, [otherPending])
        XCTAssertEqual(remainingDelivered, [otherPending])
    }

    func testFreshReplayCommitsMultipleDecisionsAtomicallyAndPostsEachExactOne()
        async throws {
        let recorder = NotificationOperationRecorder()
        let commits = DurableDecisionCommitRecorder()
        let snapshot = try multiDecisionSnapshot()
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .multiDecisionFixture),
            notifications: recorder.notificationClient(
                authorization: .authorized
            ),
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { competition, replan in
                let decisions = try replan(competition)
                await commits.append(decisions)
                return decisions.isEmpty ? .noDecision : .appended(decisions)
            }
        )

        await coordinator.submit(snapshot)

        let batches = await commits.batches
        let operations = await recorder.operations
        let postedIDs = operations.compactMap { operation -> String? in
            guard operation.hasPrefix("post:") else { return nil }
            return String(operation.dropFirst("post:".count))
        }
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].count, 2)
        XCTAssertEqual(Set(postedIDs).count, 2)
        XCTAssertEqual(
            Set(postedIDs),
            Set(
                batches[0].compactMap { decision in
                    guard case let .emission(emission) = decision else {
                        return nil
                    }
                    return emission.request.identifier
                }
            )
        )
    }

    func testPerCompetitionCASReplanPreservesGlobalEvaluationBudget()
        async throws {
        let recorder = NotificationOperationRecorder()
        let commits = DurableDecisionCommitRecorder()
        let original = try resultSnapshot(revision: 15)
        let first = try XCTUnwrap(original.competitions.first)
        let second = CompetitionNotificationCompetitionSnapshot(
            id: CompetitionID(
                UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696066")!
            ),
            opponentIdentity: first.opponentIdentity,
            opponentDisplayName: first.opponentDisplayName,
            lifecycle: first.lifecycle,
            schedule: first.schedule,
            ownerPoints: first.ownerPoints,
            opponentPoints: first.opponentPoints,
            days: first.days,
            currentDayOrdinal: first.currentDayOrdinal,
            latestRefresh: first.latestRefresh,
            evaluationFreshness: first.evaluationFreshness,
            terminalResult: first.terminalResult,
            emissionHistory: first.emissionHistory
        )
        let snapshot = CompetitionNotificationPlanningSnapshot(
            publicationRevision: original.publicationRevision,
            evaluatedAt: original.evaluatedAt,
            timeZoneIdentifier: original.timeZoneIdentifier,
            competitions: [first, second]
        )
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .coordinatorFixture),
            notifications: recorder.notificationClient(
                authorization: .authorized
            ),
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { competition, replan in
                let decisions = try replan(competition)
                await commits.append(decisions)
                return decisions.isEmpty ? .noDecision : .appended(decisions)
            }
        )

        await coordinator.submit(snapshot)

        let batches = await commits.batches
        let durableDecisions = batches.flatMap { $0 }
        let emitted: [CompetitionNotificationEmissionDecision] =
            durableDecisions.compactMap { decision in
            guard case let .emission(emission) = decision else { return nil }
            return emission
        }
        let operations = await recorder.operations
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(
            operations.filter { $0.hasPrefix("post:") }.count,
            1
        )
    }

    func testSuppressionConflictReplansToNothingWithoutBurningSemanticIDs()
        async throws {
        let recorder = NotificationOperationRecorder()
        let commits = DurableDecisionCommitRecorder()
        let snapshot = try staleEpisodeSnapshot()
        let originalCompetition = try XCTUnwrap(snapshot.competitions.first)
        let freshCompetition = replacingDays(
            in: originalCompetition,
            with: [
                CompetitionNotificationDaySnapshot(
                    ordinal: 2,
                    ownerAcceptedPoints: 100,
                    opponentRevealedPoints: 100
                ),
            ]
        )
        let coordinator = CompetitionNotificationCoordinator(
            planner: CompetitionNotificationPlanner(policy: .staleFixture),
            notifications: recorder.notificationClient(
                authorization: .authorized
            ),
            preferences: .constant(mutedOpponentIdentities: []),
            commitDecisions: { _, replan in
                let decisions = try replan(freshCompetition)
                await commits.append(decisions)
                return decisions.isEmpty ? .noDecision : .appended(decisions)
            }
        )

        await coordinator.submit(snapshot)

        let batches = await commits.batches
        let operations = await recorder.operations
        XCTAssertEqual(batches, [[]])
        XCTAssertFalse(operations.contains { $0.hasPrefix("post:") })
    }

    private func resultSnapshot(
        revision: UInt64 = 9,
        lifecycle: CompetitionNotificationLifecycle = .completed
    ) throws
        -> CompetitionNotificationPlanningSnapshot {
        let id = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696060")!
        )
        return CompetitionNotificationPlanningSnapshot(
            publicationRevision: revision,
            evaluatedAt: Date(timeIntervalSinceReferenceDate: 2_000_000),
            timeZoneIdentifier: "UTC",
            competitions: [
                CompetitionNotificationCompetitionSnapshot(
                    id: id,
                    opponentIdentity: "local-opponent:v1:default",
                    opponentDisplayName: "Alex",
                    lifecycle: lifecycle,
                    schedule: nil,
                    ownerPoints: 3_700,
                    opponentPoints: 3_600,
                    days: [],
                    currentDayOrdinal: nil,
                    latestRefresh: .completed,
                    evaluationFreshness: .notFresh,
                    terminalResult: CompetitionNotificationTerminalSnapshot(
                        ownerPoints: 3_700,
                        opponentPoints: 3_600,
                        outcome: .win
                    ),
                    emissionHistory: NotificationEmissionProjection()
                ),
            ]
        )
    }

    private func scheduledSnapshot() throws
        -> CompetitionNotificationPlanningSnapshot {
        let id = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696061")!
        )
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let startDay = try calendar.day(
            containing: Date(timeIntervalSinceReferenceDate: 2_086_400)
        )
        return CompetitionNotificationPlanningSnapshot(
            publicationRevision: 10,
            evaluatedAt: Date(timeIntervalSinceReferenceDate: 2_000_000),
            timeZoneIdentifier: "UTC",
            competitions: [
                CompetitionNotificationCompetitionSnapshot(
                    id: id,
                    opponentIdentity: "local-opponent:v1:default",
                    opponentDisplayName: "Alex",
                    lifecycle: .scheduled,
                    schedule: CompetitionSchedule(
                        calendar: calendar,
                        startDay: startDay
                    ),
                    ownerPoints: 0,
                    opponentPoints: 0,
                    days: [],
                    currentDayOrdinal: nil,
                    latestRefresh: .none,
                    evaluationFreshness: .notFresh,
                    terminalResult: nil,
                    emissionHistory: NotificationEmissionProjection()
                ),
            ]
        )
    }

    private func multiDecisionSnapshot() throws
        -> CompetitionNotificationPlanningSnapshot {
        let id = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696064")!
        )
        let competition = CompetitionNotificationCompetitionSnapshot(
            id: id,
            opponentIdentity: "local-opponent:v1:default",
            opponentDisplayName: "Alex",
            lifecycle: .active(dayOrdinal: 4),
            schedule: nil,
            ownerPoints: 1_200,
            opponentPoints: 1_190,
            days: [
                CompetitionNotificationDaySnapshot(
                    ordinal: 4,
                    ownerAcceptedPoints: 600,
                    opponentRevealedPoints: 590
                ),
            ],
            currentDayOrdinal: 4,
            latestRefresh: .completed,
            evaluationFreshness: .freshCompletedRefresh(
                attemptID: "fresh-attempt",
                readAt: Date(timeIntervalSinceReferenceDate: 2_000_000)
            ),
            terminalResult: nil,
            emissionHistory: NotificationEmissionProjection()
        )
        return CompetitionNotificationPlanningSnapshot(
            publicationRevision: 13,
            evaluatedAt: Date(timeIntervalSinceReferenceDate: 2_000_000),
            timeZoneIdentifier: "UTC",
            competitions: [competition]
        )
    }

    private func staleEpisodeSnapshot() throws
        -> CompetitionNotificationPlanningSnapshot {
        let id = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696065")!
        )
        let competition = CompetitionNotificationCompetitionSnapshot(
            id: id,
            opponentIdentity: "local-opponent:v1:default",
            opponentDisplayName: "Alex",
            lifecycle: .active(dayOrdinal: 2),
            schedule: nil,
            ownerPoints: 700,
            opponentPoints: 500,
            days: [
                CompetitionNotificationDaySnapshot(
                    ordinal: 1,
                    ownerAcceptedPoints: 600,
                    opponentRevealedPoints: 400
                ),
                CompetitionNotificationDaySnapshot(
                    ordinal: 2,
                    ownerAcceptedPoints: 100,
                    opponentRevealedPoints: 100
                ),
            ],
            currentDayOrdinal: 2,
            latestRefresh: .completed,
            evaluationFreshness: .notFresh,
            terminalResult: nil,
            emissionHistory: NotificationEmissionProjection()
        )
        return CompetitionNotificationPlanningSnapshot(
            publicationRevision: 14,
            evaluatedAt: Date(timeIntervalSinceReferenceDate: 2_000_000),
            timeZoneIdentifier: "UTC",
            competitions: [competition]
        )
    }

    private func replacingDays(
        in competition: CompetitionNotificationCompetitionSnapshot,
        with days: [CompetitionNotificationDaySnapshot]
    ) -> CompetitionNotificationCompetitionSnapshot {
        CompetitionNotificationCompetitionSnapshot(
            id: competition.id,
            opponentIdentity: competition.opponentIdentity,
            opponentDisplayName: competition.opponentDisplayName,
            lifecycle: competition.lifecycle,
            schedule: competition.schedule,
            ownerPoints: competition.ownerPoints,
            opponentPoints: competition.opponentPoints,
            days: days,
            currentDayOrdinal: competition.currentDayOrdinal,
            latestRefresh: competition.latestRefresh,
            evaluationFreshness: competition.evaluationFreshness,
            terminalResult: competition.terminalResult,
            emissionHistory: competition.emissionHistory
        )
    }

    private func replacingSchedule(
        in competition: CompetitionNotificationCompetitionSnapshot,
        with schedule: CompetitionSchedule
    ) -> CompetitionNotificationCompetitionSnapshot {
        CompetitionNotificationCompetitionSnapshot(
            id: competition.id,
            opponentIdentity: competition.opponentIdentity,
            opponentDisplayName: competition.opponentDisplayName,
            lifecycle: competition.lifecycle,
            schedule: schedule,
            ownerPoints: competition.ownerPoints,
            opponentPoints: competition.opponentPoints,
            days: competition.days,
            currentDayOrdinal: competition.currentDayOrdinal,
            latestRefresh: competition.latestRefresh,
            evaluationFreshness: competition.evaluationFreshness,
            terminalResult: competition.terminalResult,
            emissionHistory: competition.emissionHistory,
            evaluatedAt: competition.evaluatedAt,
            timeZoneIdentifier: competition.timeZoneIdentifier
        )
    }
}

private enum CoordinatorFixtureError: Error {
    case preferencesUnavailable
    case postFailed
}

private actor CommitOnceRecorder {
    private(set) var callCount = 0
    private var didAppend = false

    func commit(
        _ competition: CompetitionNotificationCompetitionSnapshot,
        replan: @escaping CompetitionNotificationCoordinator.ReplanDecisions
    ) throws -> CompetitionNotificationDecisionCommitResult {
        callCount += 1
        guard !didAppend else { return .duplicate }
        let decisions = try replan(competition)
        guard !decisions.isEmpty else {
            return .noDecision
        }
        didAppend = true
        return .appended(decisions)
    }
}

private actor NotificationCommitReturnGate {
    private var didAppend = false
    private var isReleased = false
    private var appendWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func didAppendAndWaitToReturn() async {
        didAppend = true
        let waiters = appendWaiters
        appendWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilAppended() async {
        guard !didAppend else { return }
        await withCheckedContinuation { continuation in
            appendWaiters.append(continuation)
        }
    }

    func releaseCommitReturn() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor DurableDecisionCommitRecorder {
    private(set) var batches: [[CompetitionNotificationDurableDecision]] = []

    func append(_ decisions: [CompetitionNotificationDurableDecision]) {
        batches.append(decisions)
    }
}

private actor FailingPostNotificationCenter {
    private(set) var postCount = 0

    nonisolated var client: CompetitionNotificationClient {
        CompetitionNotificationClient(
            requestAuthorization: { true },
            authorizationState: { .authorized },
            upsert: { _ in },
            postNow: { [weak self] _ in
                await self?.post()
                throw CoordinatorFixtureError.postFailed
            },
            pendingIDs: { _ in [] },
            deliveredIDs: { _ in [] },
            removePending: { _ in },
            removeDelivered: { _ in }
        )
    }

    private func post() {
        postCount += 1
    }
}

private actor CleanupOperationRecorder {
    enum Kind: Equatable, Sendable {
        case removePending
        case removeDelivered
        case append
        case post
    }

    struct Operation: Equatable, Sendable {
        let kind: Kind
        let identifiers: [String]
    }

    private(set) var pending: Set<String> = []
    private(set) var delivered: Set<String> = []
    private(set) var operations: [Operation] = []

    nonisolated var client: CompetitionNotificationClient {
        CompetitionNotificationClient(
            requestAuthorization: { true },
            authorizationState: { .authorized },
            upsert: { _ in },
            postNow: { [weak self] request in
                await self?.record(
                    kind: .post,
                    identifiers: [request.identifier]
                )
            },
            pendingIDs: { [weak self] prefix in
                await self?.pendingIDs(prefix: prefix) ?? []
            },
            deliveredIDs: { [weak self] prefix in
                await self?.deliveredIDs(prefix: prefix) ?? []
            },
            removePending: { [weak self] identifiers in
                await self?.removePending(identifiers)
            },
            removeDelivered: { [weak self] identifiers in
                await self?.removeDelivered(identifiers)
            }
        )
    }

    func configure(pending: Set<String>, delivered: Set<String>) {
        self.pending = pending
        self.delivered = delivered
    }

    func append(_ identifier: String) {
        record(kind: .append, identifiers: [identifier])
    }

    private func pendingIDs(prefix: String) -> Set<String> {
        Set(pending.filter { $0.hasPrefix(prefix) })
    }

    private func deliveredIDs(prefix: String) -> Set<String> {
        Set(delivered.filter { $0.hasPrefix(prefix) })
    }

    private func removePending(_ identifiers: [String]) {
        pending.subtract(identifiers)
        record(kind: .removePending, identifiers: identifiers)
    }

    private func removeDelivered(_ identifiers: [String]) {
        delivered.subtract(identifiers)
        record(kind: .removeDelivered, identifiers: identifiers)
    }

    private func record(kind: Kind, identifiers: [String]) {
        operations.append(
            Operation(kind: kind, identifiers: identifiers.sorted())
        )
    }
}

private actor NotificationRevisionRecorder {
    private(set) var values: [UInt64] = []

    func append(_ value: UInt64) {
        values.append(value)
    }
}

private actor NotificationAuthorizationGate {
    private var isRequested = false
    private var isReleased = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func authorizationState() async -> CompetitionNotificationAuthorizationState {
        isRequested = true
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !isReleased else { return .authorized }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return .authorized
    }

    func waitUntilRequested() async {
        guard !isRequested else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor NotificationOperationRecorder {
    private(set) var operations: [String] = []

    func record(_ value: String) {
        operations.append(value)
    }

    nonisolated func notificationClient(
        authorization: CompetitionNotificationAuthorizationState
    ) -> CompetitionNotificationClient {
        CompetitionNotificationClient(
            requestAuthorization: { true },
            authorizationState: { authorization },
            upsert: { [weak self] request in
                await self?.record("upsert:\(request.identifier)")
            },
            postNow: { [weak self] request in
                await self?.record("post:\(request.identifier)")
            },
            pendingIDs: { _ in [] },
            deliveredIDs: { _ in [] },
            removePending: { _ in },
            removeDelivered: { _ in }
        )
    }
}

private actor StatefulNotificationCenterRecorder {
    struct Snapshot: Sendable {
        var upserts: [CompetitionScheduledNotificationRequest] = []
        var removedPending: [[String]] = []
    }

    private var pending: Set<String> = []
    private(set) var snapshot = Snapshot()

    nonisolated var client: CompetitionNotificationClient {
        CompetitionNotificationClient(
            requestAuthorization: { true },
            authorizationState: { .authorized },
            upsert: { [weak self] request in
                await self?.upsert(request)
            },
            postNow: { _ in },
            pendingIDs: { [weak self] prefix in
                await self?.pendingIDs(prefix: prefix) ?? []
            },
            deliveredIDs: { _ in [] },
            removePending: { [weak self] identifiers in
                await self?.removePending(identifiers)
            },
            removeDelivered: { _ in }
        )
    }

    func setPending(_ identifiers: Set<String>) {
        pending = identifiers
    }

    private func upsert(_ request: CompetitionScheduledNotificationRequest) {
        pending.insert(request.identifier)
        snapshot.upserts.append(request)
    }

    private func pendingIDs(prefix: String) -> Set<String> {
        Set(pending.filter { $0.hasPrefix(prefix) })
    }

    private func removePending(_ identifiers: [String]) {
        pending.subtract(identifiers)
        snapshot.removedPending.append(identifiers)
    }
}

private extension CompetitionNotificationPolicy {
    static var coordinatorFixture: Self {
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

    static var multiDecisionFixture: Self {
        Self(
            maximumPostsPerEvaluation: 2,
            maximumPostsPerCompetitionDay: 3,
            scheduledFireDate: { _, baseDate, _ in baseDate },
            isCloseScore: { _, _ in false },
            isDailyMaximum: { $0 == 600 },
            priority: { family in
                switch family {
                case .dailyMaximum: 30
                case .closeScore: 20
                case .leadChange: 10
                case .result: 40
                case .catchUp: 0
                }
            },
            content: { message in
                CompetitionNotificationContent(
                    title: message.family.rawValue,
                    body: "fixture"
                )
            }
        )
    }

    static var staleFixture: Self {
        Self(
            maximumPostsPerEvaluation: 1,
            maximumPostsPerCompetitionDay: 2,
            scheduledFireDate: { _, baseDate, _ in baseDate },
            isCloseScore: { _, _ in false },
            isDailyMaximum: { $0 == 600 },
            priority: { _ in 0 },
            content: { message in
                CompetitionNotificationContent(
                    title: message.family.rawValue,
                    body: "fixture"
                )
            }
        )
    }
}
