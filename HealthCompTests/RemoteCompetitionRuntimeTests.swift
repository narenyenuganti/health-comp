import CompetitionCore
import Foundation
import XCTest

@testable import HealthComp

final class RemoteCompetitionRuntimeTests: XCTestCase {
    func testCacheSaveRejectsSymlinkWithoutChangingItsTarget() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let target = outsideRoot.appendingPathComponent("outside.json")
        let sentinel = Data("outside-sentinel".utf8)
        try sentinel.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("competition-inventory.v1.json"),
            withDestinationURL: target
        )
        let store = JSONRemoteCompetitionCacheStore(
            rootDirectory: root,
            fileProtection: JSONCompetitionEventStoreFileProtection { _, _ in }
        )

        do {
            try await store.save([], profileID: profileID)
            XCTFail("Expected the cache store to reject a symlink destination")
        } catch {
            XCTAssertEqual(
                error as? RemoteCompetitionCacheFailure,
                .unsafeFilesystemEntry
            )
        }
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
    }

    func testCacheLoadRejectsPersistedCursorOutsideDescriptorBounds()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONRemoteCompetitionCacheStore(
            rootDirectory: root,
            fileProtection: JSONCompetitionEventStoreFileProtection { _, _ in }
        )
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try pendingDescriptor(
            creatorProfileID: profileID,
            expiresAt: createdAt.addingTimeInterval(48 * 60 * 60)
        )
        try await store.save(
            [
                try RemoteCompetitionCacheEntry(
                    descriptor: descriptor,
                    lastSeenServerSequence: descriptor.serverCursor
                ),
            ],
            profileID: profileID
        )
        let fileURL = root.appendingPathComponent(
            "competition-inventory.v1.json"
        )
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
                as? [String: Any]
        )
        var entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
        entries[0]["lastSeenServerSequence"] = -1
        document["entries"] = entries
        try JSONSerialization.data(withJSONObject: document).write(to: fileURL)

        do {
            _ = try await store.load(profileID: profileID)
            XCTFail("Expected the cache store to reject an invalid cursor")
        } catch {
            XCTAssertEqual(
                error as? RemoteCompetitionCacheFailure,
                .invalidDocument
            )
        }
    }

    func testCacheOperationReapsInterruptedTemporaryFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent(
            ".competition-inventory.\(UUID().uuidString.lowercased()).tmp"
        )
        try Data("interrupted-write".utf8).write(to: stale)
        let store = JSONRemoteCompetitionCacheStore(
            rootDirectory: root,
            fileProtection: JSONCompetitionEventStoreFileProtection { _, _ in }
        )

        let entries = try await store.load(profileID: profileID)

        XCTAssertEqual(entries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testSynchronizeWithNoRemoteCompetitionsLeavesProfileCacheEmpty()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = JSONCompetitionEventStore(
            rootDirectory: root,
            faultInjector: .none,
            fileProtection: JSONCompetitionEventStoreFileProtection {
                _, _ in
            }
        )
        let probe = RemoteCompetitionRuntimeProbe()
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(listCompetitions: {
                await probe.recordListCall()
                return []
            })
        )

        let outcome = await runtime.synchronizeAll()

        XCTAssertEqual(outcome.outcomes, [])
        XCTAssertNil(outcome.discoveryFailure)
        let listCallCount = await probe.listCallCount()
        XCTAssertEqual(listCallCount, 1)
        let persistedIDs = try await store.ids()
        XCTAssertEqual(persistedIDs, [])
    }

    func testRemoteDecisionCommitterRecordsStableSemanticDecisionOnlyOnce()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try pendingDescriptor(
            creatorProfileID: profileID,
            expiresAt: createdAt.addingTimeInterval(48 * 60 * 60)
        )
        let page = try CompetitionChangePage(
            competitionID: descriptor.competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 1,
            nextServerSequence: 1,
            hasMore: false,
            changes: [
                try participantAddedChange(
                    sequence: 1,
                    profileID: profileID,
                    role: .creator,
                    occurredAt: createdAt
                ),
            ]
        )
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page }
            )
        )
        let outcome = await runtime.synchronizeAll()
        XCTAssertEqual(outcome.failures, [])
        let decision = try NotificationEmissionRecorded(
            competitionID: CompetitionID(descriptor.competitionID),
            family: .result,
            episodeKey: .result,
            disposition: .suppressed(reason: .superseded),
            decidedAt: createdAt,
            basisPublicationRevision: 1
        )
        let snapshot = CompetitionNotificationCompetitionSnapshot(
            id: CompetitionID(descriptor.competitionID),
            opponentIdentity: "remote-profile:v1:pending",
            opponentDisplayName: "Waiting for competitor",
            lifecycle: .pending(expiresAt: descriptor.invitationExpiresAt),
            schedule: nil,
            ownerPoints: 0,
            opponentPoints: 0,
            days: [],
            currentDayOrdinal: nil,
            latestRefresh: .none,
            evaluationFreshness: .notFresh,
            terminalResult: nil,
            emissionHistory: NotificationEmissionProjection(),
            evaluatedAt: createdAt,
            timeZoneIdentifier: descriptor.timeZoneIdentifier ?? "UTC"
        )
        let committer = CompetitionNotificationDecisionCommitter.remote(
            runtime: runtime
        )

        let first = try await committer.commit(snapshot) { fresh in
            XCTAssertFalse(
                fresh.emissionHistory.recordedIDs.contains(
                    decision.semanticEventID
                )
            )
            return [.suppression(decision)]
        }
        let second = try await committer.commit(snapshot) { fresh in
            XCTAssertTrue(
                fresh.emissionHistory.recordedIDs.contains(
                    decision.semanticEventID
                )
            )
            return [.suppression(decision)]
        }

        XCTAssertEqual(first, .appended([.suppression(decision)]))
        XCTAssertEqual(second, .duplicate)
        let optionalLoaded = try await store.load(
            CompetitionID(descriptor.competitionID)
        )
        let loaded = try XCTUnwrap(optionalLoaded)
        XCTAssertEqual(
            loaded.projection.notificationEmissions.recordedIDs,
            [decision.semanticEventID]
        )
    }

    func testRemoteDecisionCommitterReplansFromReloadedLifecycleAfterConflict()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseStore = makeStore(root: root)
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let declinedAt = createdAt.addingTimeInterval(60)
        let store = RemoteNotificationConflictStore(
            base: baseStore,
            declinedAt: declinedAt
        )
        let descriptor = try pendingDescriptor(
            creatorProfileID: profileID,
            expiresAt: createdAt.addingTimeInterval(48 * 60 * 60)
        )
        let page = try CompetitionChangePage(
            competitionID: descriptor.competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 1,
            nextServerSequence: 1,
            hasMore: false,
            changes: [
                try participantAddedChange(
                    sequence: 1,
                    profileID: profileID,
                    role: .creator,
                    occurredAt: createdAt
                ),
            ]
        )
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page }
            )
        )
        let outcome = await runtime.synchronizeAll()
        XCTAssertEqual(outcome.failures, [])
        let decision = try NotificationEmissionRecorded(
            competitionID: CompetitionID(descriptor.competitionID),
            family: .result,
            episodeKey: .result,
            disposition: .suppressed(reason: .superseded),
            decidedAt: createdAt,
            basisPublicationRevision: 1
        )
        let snapshot = CompetitionNotificationCompetitionSnapshot(
            id: CompetitionID(descriptor.competitionID),
            opponentIdentity: "remote-profile:v1:pending",
            opponentDisplayName: "Waiting for competitor",
            lifecycle: .pending(expiresAt: descriptor.invitationExpiresAt),
            schedule: nil,
            ownerPoints: 0,
            opponentPoints: 0,
            days: [],
            currentDayOrdinal: nil,
            latestRefresh: .none,
            evaluationFreshness: .notFresh,
            terminalResult: nil,
            emissionHistory: NotificationEmissionProjection(),
            evaluatedAt: createdAt,
            timeZoneIdentifier: descriptor.timeZoneIdentifier ?? "UTC"
        )
        let replans = RemoteNotificationReplanProbe()
        let committer = CompetitionNotificationDecisionCommitter.remote(
            runtime: runtime
        )

        let result = try await committer.commit(snapshot) { fresh in
            replans.record(fresh.lifecycle)
            guard case .pending = fresh.lifecycle else { return [] }
            return [.suppression(decision)]
        }

        XCTAssertEqual(
            result,
            CompetitionNotificationDecisionCommitResult.noDecision
        )
        let lifecycles = replans.values()
        XCTAssertEqual(lifecycles.count, 2)
        if lifecycles.count == 2 {
            guard case .pending = lifecycles[0] else {
                return XCTFail("Expected the first plan to see pending")
            }
            guard case .declined = lifecycles[1] else {
                return XCTFail("Expected the retry to see declined")
            }
        }
        let optionalLoaded = try await baseStore.load(
            CompetitionID(descriptor.competitionID)
        )
        let loaded = try XCTUnwrap(optionalLoaded)
        XCTAssertEqual(
            loaded.projection.competition.lifecycle,
            .declined(at: declinedAt)
        )
        XCTAssertEqual(
            loaded.projection.notificationEmissions.recordedIDs,
            []
        )
    }

    func testOutgoingPendingDescriptorMaterializesFromGapFreeServerHistory()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let expiresAt = createdAt.addingTimeInterval(48 * 60 * 60)
        let descriptor = try pendingDescriptor(
            creatorProfileID: profileID,
            expiresAt: expiresAt
        )
        let change = try CompetitionChange(
            serverSequence: 1,
            kind: .participantAdded,
            entityID: profileID,
            occurredAt: createdAt,
            payload: .participant(
                try CompetitionParticipantChange(
                    profileID: profileID,
                    role: .creator,
                    state: .accepted
                )
            )
        )
        let page = try CompetitionChangePage(
            competitionID: descriptor.competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 1,
            nextServerSequence: 1,
            hasMore: false,
            changes: [change]
        )
        let probe = RemoteCompetitionRuntimeProbe()
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { cursor, pageSize in
                    await probe.recordFetch(cursor: cursor, pageSize: pageSize)
                    return page
                }
            )
        )

        let outcome = await runtime.synchronizeAll()

        XCTAssertNil(outcome.discoveryFailure)
        XCTAssertEqual(outcome.failures, [])
        let materialized = try XCTUnwrap(
            outcome.successfulCompetitions.first
        )
        XCTAssertEqual(outcome.successfulCompetitions.count, 1)
        XCTAssertEqual(materialized.descriptor, descriptor)
        XCTAssertEqual(
            materialized.journal.journal.genesis.direction,
            .outgoing
        )
        XCTAssertEqual(
            materialized.journal.journal.genesis.createdAt,
            createdAt
        )
        XCTAssertEqual(
            materialized.journal.journal.genesis.expiresAt,
            expiresAt
        )
        XCTAssertNil(
            materialized.journal.projection.competition.remoteConfiguration
        )
        guard case let .pendingInvitation(invitation) =
            materialized.journal.projection.competition.lifecycle
        else {
            return XCTFail("Expected outgoing pending invitation")
        }
        XCTAssertEqual(invitation.direction, .outgoing)
        XCTAssertEqual(invitation.createdAt, createdAt)
        XCTAssertEqual(invitation.expiresAt, expiresAt)
        let fetches = await probe.fetchObservations()
        XCTAssertEqual(fetches.count, 1)
        XCTAssertEqual(fetches[0].cursor.competitionID, competitionID)
        XCTAssertEqual(fetches[0].cursor.lastSeenServerSequence, 0)
        XCTAssertEqual(fetches[0].pageSize, 200)
    }

    func testExpiredDescriptorPrunesInventoryWithoutDeletingJournalOrFailure()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsRoot = root.appendingPathComponent(
            "events",
            isDirectory: true
        )
        let cursorsRoot = root.appendingPathComponent(
            "cursors",
            isDirectory: true
        )
        for directory in [eventsRoot, cursorsRoot] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let store = makeStore(root: eventsRoot)
        let cache = JSONRemoteCompetitionCacheStore(
            rootDirectory: cursorsRoot,
            fileProtection: JSONCompetitionEventStoreFileProtection {
                _, _ in
            }
        )
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let pending = try pendingDescriptor(
            creatorProfileID: profileID,
            expiresAt: createdAt.addingTimeInterval(48 * 60 * 60)
        )
        let initialPage = try CompetitionChangePage(
            competitionID: pending.competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 1,
            nextServerSequence: 1,
            hasMore: false,
            changes: [
                try participantAddedChange(
                    sequence: 1,
                    profileID: profileID,
                    role: .creator,
                    occurredAt: createdAt
                ),
            ]
        )
        let probe = RemoteCompetitionRuntimeProbe()
        let initialRuntime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [pending] },
                fetchChanges: { cursor, pageSize in
                    await probe.recordFetch(
                        cursor: cursor,
                        pageSize: pageSize
                    )
                    return initialPage
                }
            ),
            cacheStore: cache
        )

        let initial = await initialRuntime.synchronizeAll()

        XCTAssertEqual(initial.failures, [])
        XCTAssertEqual(initial.successfulCompetitions.count, 1)
        let initialCache = try await cache.load(profileID: profileID)
        XCTAssertEqual(initialCache.count, 1)
        let journalIDs = try await store.ids()
        XCTAssertEqual(journalIDs, [CompetitionID(competitionID)])

        let expired = try CompetitionDescriptor(
            competitionID: pending.competitionID,
            creatorProfileID: pending.creatorProfileID,
            timeZoneIdentifier: nil,
            startDay: nil,
            scoringPolicyIdentity: pending.scoringPolicyIdentity,
            lifecycle: .expired,
            invitationExpiresAt: pending.invitationExpiresAt,
            bestAvailableDeadline: nil,
            rematchParentID: pending.rematchParentID,
            nextServerSequence: 3,
            participants: pending.participants
        )
        let terminalRuntime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [expired] },
                fetchChanges: { cursor, pageSize in
                    await probe.recordFetch(
                        cursor: cursor,
                        pageSize: pageSize
                    )
                    throw CompetitionRemoteFailure.operationFailed
                }
            ),
            cacheStore: cache
        )

        let terminal = await terminalRuntime.synchronizeAll()

        XCTAssertNil(terminal.discoveryFailure)
        XCTAssertEqual(terminal.outcomes, [])
        let fetches = await probe.fetchObservations()
        XCTAssertEqual(fetches.count, 1)
        let terminalCache = try await cache.load(profileID: profileID)
        XCTAssertEqual(terminalCache, [])
        let terminalJournalIDs = try await store.ids()
        XCTAssertEqual(terminalJournalIDs, journalIDs)
    }

    func testOtherNonmaterializedTerminalDescriptorsPruneWithoutFailure()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let pending = try pendingDescriptor(
            creatorProfileID: profileID,
            expiresAt: createdAt.addingTimeInterval(48 * 60 * 60)
        )

        for lifecycle in [
            CompetitionRemoteLifecycle.declined,
            .cancelled,
        ] {
            let caseRoot = root.appendingPathComponent(
                lifecycle.rawValue,
                isDirectory: true
            )
            let eventsRoot = caseRoot.appendingPathComponent(
                "events",
                isDirectory: true
            )
            let cursorsRoot = caseRoot.appendingPathComponent(
                "cursors",
                isDirectory: true
            )
            for directory in [eventsRoot, cursorsRoot] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
            let cache = JSONRemoteCompetitionCacheStore(
                rootDirectory: cursorsRoot,
                fileProtection: JSONCompetitionEventStoreFileProtection {
                    _, _ in
                }
            )
            try await cache.save(
                [
                    try RemoteCompetitionCacheEntry(
                        descriptor: pending,
                        lastSeenServerSequence: pending.serverCursor
                    ),
                ],
                profileID: profileID
            )
            let terminalDescriptor = try CompetitionDescriptor(
                competitionID: pending.competitionID,
                creatorProfileID: pending.creatorProfileID,
                timeZoneIdentifier: nil,
                startDay: nil,
                scoringPolicyIdentity: pending.scoringPolicyIdentity,
                lifecycle: lifecycle,
                invitationExpiresAt: pending.invitationExpiresAt,
                bestAvailableDeadline: nil,
                rematchParentID: pending.rematchParentID,
                nextServerSequence: 3,
                participants: pending.participants
            )
            let probe = RemoteCompetitionRuntimeProbe()
            let runtime = RemoteCompetitionRuntime(
                profileID: profileID,
                store: makeStore(root: eventsRoot),
                remoteAPI: remoteAPI(
                    listCompetitions: { [terminalDescriptor] },
                    fetchChanges: { cursor, pageSize in
                        await probe.recordFetch(
                            cursor: cursor,
                            pageSize: pageSize
                        )
                        throw CompetitionRemoteFailure.operationFailed
                    }
                ),
                cacheStore: cache
            )

            let outcome = await runtime.synchronizeAll()

            XCTAssertNil(outcome.discoveryFailure, lifecycle.rawValue)
            XCTAssertEqual(outcome.outcomes, [], lifecycle.rawValue)
            let fetches = await probe.fetchObservations()
            XCTAssertEqual(fetches.count, 0, lifecycle.rawValue)
            let cachedEntries = try await cache.load(profileID: profileID)
            XCTAssertEqual(cachedEntries, [], lifecycle.rawValue)
        }
    }

    func testEnumerationFailureForOneIDDoesNotSuppressValidCompetition()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let valid = try pendingDescriptor(
            creatorProfileID: profileID,
            expiresAt: createdAt.addingTimeInterval(48 * 60 * 60)
        )
        let unrelatedProfileID = UUID(
            uuidString: "71000000-0000-4000-8000-000000000099"
        )!
        let unrelatedCompetitionID = UUID(
            uuidString: "73000000-0000-4000-8000-000000000099"
        )!
        let invalidForProfile = try CompetitionDescriptor(
            competitionID: unrelatedCompetitionID,
            creatorProfileID: unrelatedProfileID,
            timeZoneIdentifier: nil,
            startDay: nil,
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            lifecycle: .pending,
            invitationExpiresAt: createdAt.addingTimeInterval(48 * 60 * 60),
            bestAvailableDeadline: nil,
            rematchParentID: nil,
            nextServerSequence: 2,
            participants: [
                try CompetitionParticipantDescriptor(
                    profileID: unrelatedProfileID,
                    role: .creator,
                    state: .accepted,
                    profile: try CompetitionProfilePresentation(
                        id: unrelatedProfileID,
                        displayName: "Unrelated"
                    )
                ),
            ]
        )
        let validPage = try CompetitionChangePage(
            competitionID: valid.competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 1,
            nextServerSequence: 1,
            hasMore: false,
            changes: [
                try participantAddedChange(
                    sequence: 1,
                    profileID: profileID,
                    role: .creator,
                    occurredAt: createdAt
                ),
            ]
        )
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [invalidForProfile, valid] },
                fetchChanges: { cursor, _ in
                    XCTAssertEqual(cursor.competitionID, valid.competitionID)
                    return validPage
                }
            )
        )

        let outcome = await runtime.synchronizeAll()

        XCTAssertNil(outcome.discoveryFailure)
        XCTAssertEqual(
            outcome.successfulCompetitions.map(\.descriptor.competitionID),
            [valid.competitionID]
        )
        XCTAssertEqual(
            outcome.failures,
            [
                RemoteCompetitionRuntimeIDFailure(
                    competitionID: CompetitionID(unrelatedCompetitionID),
                    failure: .profileMismatch
                ),
            ]
        )
    }

    func testFetchStopsBeforeRequestingBeyondDescriptorCursor() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try pendingDescriptor(
            creatorProfileID: profileID,
            expiresAt: Date(timeIntervalSince1970: 1_786_712_800)
        )
        let page = try CompetitionChangePage(
            competitionID: competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 3,
            nextServerSequence: 2,
            hasMore: true,
            changes: try (1...2).map { sequence in
                try CompetitionChange(
                    serverSequence: Int64(sequence),
                    kind: .profilePresentationChanged,
                    entityID: profileID,
                    occurredAt: Date(
                        timeIntervalSince1970: 1_786_540_000
                            + TimeInterval(sequence)
                    ),
                    payload: .profilePresentation(
                        try CompetitionProfilePresentationChange(
                            profileID: profileID,
                            displayName: "Beta Alice"
                        )
                    )
                )
            }
        )
        let probe = RemoteCompetitionRuntimeProbe()
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: makeStore(root: root),
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { cursor, pageSize in
                    await probe.recordFetch(cursor: cursor, pageSize: pageSize)
                    return page
                }
            )
        )

        let outcome = await runtime.synchronizeAll()

        XCTAssertEqual(
            outcome.failures,
            [
                RemoteCompetitionRuntimeIDFailure(
                    competitionID: CompetitionID(competitionID),
                    failure: .serverContractMismatch
                ),
            ]
        )
        let fetchObservations = await probe.fetchObservations()
        XCTAssertEqual(fetchObservations.count, 1)
    }

    func testIncomingScheduledDescriptorFreezesRemoteConfiguration()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let creatorID = UUID(
            uuidString: "72000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let acceptedAt = createdAt.addingTimeInterval(3_600)
        let descriptor = try scheduledDescriptor(
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt
        )
        let lifecycle = try CompetitionLifecycleChange(
            lifecycle: .scheduled,
            timeZoneIdentifier: descriptor.timeZoneIdentifier,
            startDay: descriptor.startDay,
            bestAvailableDeadline: descriptor.bestAvailableDeadline,
            scoringPolicyIdentity: descriptor.scoringPolicyIdentity
        )
        let page = try CompetitionChangePage(
            competitionID: competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 3,
            nextServerSequence: 3,
            hasMore: false,
            changes: [
                try participantAddedChange(
                    sequence: 1,
                    profileID: creatorID,
                    role: .creator,
                    occurredAt: createdAt
                ),
                try participantAddedChange(
                    sequence: 2,
                    profileID: profileID,
                    role: .invitee,
                    occurredAt: acceptedAt
                ),
                try CompetitionChange(
                    serverSequence: 3,
                    kind: .competitionLifecycleChanged,
                    entityID: competitionID,
                    occurredAt: acceptedAt,
                    payload: .lifecycle(lifecycle)
                ),
            ]
        )
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page }
            ),
            now: { acceptedAt }
        )

        let outcome = await runtime.synchronizeAll()

        XCTAssertEqual(outcome.failures, [])
        let materialized = try XCTUnwrap(
            outcome.successfulCompetitions.first
        )
        XCTAssertEqual(
            materialized.journal.journal.genesis.direction,
            .incoming
        )
        XCTAssertEqual(
            materialized.journal.journal.genesis.createdAt,
            createdAt
        )
        let configuration = try XCTUnwrap(
            materialized.journal.projection.competition.remoteConfiguration
        )
        XCTAssertEqual(configuration.owner.profileID, profileID)
        XCTAssertEqual(configuration.remote.profileID, creatorID)
        XCTAssertEqual(configuration.backendDescriptorRevision, 3)
        XCTAssertEqual(
            configuration.acceptedSchedule.calendar.timeZoneIdentifier,
            "America/Los_Angeles"
        )
        XCTAssertEqual(configuration.acceptedSchedule.startDay.year, 2026)
        XCTAssertEqual(configuration.acceptedSchedule.startDay.month, 8)
        XCTAssertEqual(configuration.acceptedSchedule.startDay.day, 13)
        XCTAssertEqual(
            configuration.bestAvailableDeadline,
            descriptor.bestAvailableDeadline
        )
        guard case .scheduled =
            materialized.journal.projection.competition.lifecycle
        else {
            return XCTFail("Expected scheduled remote competition")
        }
    }

    func testCompletedDescriptorWithoutResultChangeFailsClosed() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let creatorID = UUID(
            uuidString: "72000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try scheduledDescriptor(
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt,
            lifecycle: .completed
        )
        let page = try scheduledHistoryPage(
            descriptor: descriptor,
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt
        )
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page }
            ),
            now: { createdAt }
        )

        let outcome = await runtime.synchronizeAll()

        XCTAssertEqual(
            outcome.failures,
            [
                RemoteCompetitionRuntimeIDFailure(
                    competitionID: CompetitionID(competitionID),
                    failure: .serverContractMismatch
                ),
            ]
        )
        XCTAssertEqual(outcome.successfulCompetitions, [])
    }

    func testScheduledDescriptorAdvancesToDayOneFromImmutableCalendar()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let creatorID = UUID(
            uuidString: "72000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try scheduledDescriptor(
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt
        )
        let page = try scheduledHistoryPage(
            descriptor: descriptor,
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt
        )
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let dayOne = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 13,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let dayOneNoon = try calendar.startOfDay(dayOne)
            .addingTimeInterval(12 * 60 * 60)
        let api = remoteAPI(
            listCompetitions: { [descriptor] },
            fetchChanges: { _, _ in page }
        )
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: api,
            now: { dayOneNoon }
        )

        let outcome = await runtime.synchronizeAll()

        let materialized = try XCTUnwrap(
            outcome.successfulCompetitions.first
        )
        guard case let .active(day) =
            materialized.journal.projection.competition.lifecycle
        else {
            return XCTFail("Expected authoritative Day 1 projection")
        }
        XCTAssertEqual(day.ordinal, 1)
        XCTAssertNotNil(
            materialized.journal.projection.competition.remoteConfiguration
        )
        XCTAssertNil(materialized.journal.projection.sharedResult)

        let relaunched = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: api,
            now: { dayOneNoon }
        )
        let relaunchedOutcome = await relaunched.synchronizeAll()

        XCTAssertEqual(relaunchedOutcome.failures, [])
        guard case let .active(relaunchedDay) = relaunchedOutcome
            .successfulCompetitions.first?.journal.projection.competition
            .lifecycle
        else {
            return XCTFail("Expected relaunched Day 1 projection")
        }
        XCTAssertEqual(relaunchedDay.ordinal, 1)
    }

    func testImmutableScheduleAdvancesAcrossAllSevenDayOrdinals()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let creatorID = UUID(
            uuidString: "72000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let startDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 13,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let days = try calendar.sevenDayWindow(startingOn: startDay)

        for ordinal in 1...7 {
            let caseRoot = root.appendingPathComponent(
                "day-\(ordinal)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: caseRoot,
                withIntermediateDirectories: true
            )
            let descriptor = try scheduledDescriptor(
                creatorID: creatorID,
                inviteeID: profileID,
                createdAt: createdAt,
                lifecycle: ordinal == 7 ? .endsToday : .active
            )
            let page = try scheduledHistoryPage(
                descriptor: descriptor,
                creatorID: creatorID,
                inviteeID: profileID,
                createdAt: createdAt
            )
            let now = try calendar.startOfDay(days[ordinal - 1])
                .addingTimeInterval(12 * 60 * 60)
            let runtime = RemoteCompetitionRuntime(
                profileID: profileID,
                store: makeStore(root: caseRoot),
                remoteAPI: remoteAPI(
                    listCompetitions: { [descriptor] },
                    fetchChanges: { _, _ in page }
                ),
                now: { now }
            )

            let outcome = await runtime.synchronizeAll()

            XCTAssertEqual(outcome.failures, [], "Day \(ordinal)")
            let lifecycle = try XCTUnwrap(
                outcome.successfulCompetitions.first?.journal.projection
                    .competition.lifecycle
            )
            if ordinal == 7 {
                guard case .endsToday = lifecycle else {
                    XCTFail("Expected endsToday on Day 7")
                    continue
                }
            } else {
                guard case let .active(day) = lifecycle else {
                    XCTFail("Expected active on Day \(ordinal)")
                    continue
                }
                XCTAssertEqual(day.ordinal, ordinal)
            }
        }
    }

    func testOwnerHealthRefreshEnqueuesPrivacySafeRevisionAndPersistsAck()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsRoot = root.appendingPathComponent(
            "events",
            isDirectory: true
        )
        let outboxRoot = root.appendingPathComponent(
            "outbox",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: eventsRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: outboxRoot,
            withIntermediateDirectories: false
        )
        let eventStore = makeStore(root: eventsRoot)
        let outboxStore = JSONCompetitionOutboxStore(
            rootDirectory: outboxRoot,
            fileProtection: JSONCompetitionEventStoreFileProtection {
                _, _ in
            }
        )
        let creatorID = UUID(
            uuidString: "72000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try scheduledDescriptor(
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt
        )
        let page = try scheduledHistoryPage(
            descriptor: descriptor,
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt
        )
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let startDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 13,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let days = try calendar.sevenDayWindow(startingOn: startDay)
        let dayOneNoon = try calendar.startOfDay(startDay)
            .addingTimeInterval(12 * 60 * 60)
        let snapshot = ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: 420, goal: 600),
            exercise: try ActivityRingReading(value: 24, goal: 30),
            standOrRoll: try ActivityRingReading(value: 10, goal: 12),
            pauseState: .running
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: dayOneNoon,
                    monotonic: MonotonicInstant(
                        epochID: "task13-owner-refresh",
                        nanoseconds: 1
                    )
                ),
                timeZoneIdentifier: calendar.timeZoneIdentifier,
                initialDays: [
                    .snapshot(day: days[0], snapshot: snapshot),
                ] + days.dropFirst().map { .missing(day: $0) },
                changes: []
            )
        )
        let probe = RemoteCompetitionRuntimeProbe()
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: eventStore,
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page },
                appendScoreRevision: { request in
                    await probe.recordScoreRequest(request)
                    return try CompetitionScoreRevisionResponse(
                        disposition: .appended,
                        rejectionCode: nil,
                        acceptedCentiPoints: 23_333,
                        wireContentSHA256: request.wireContentSHA256,
                        acceptedServerSequence: 4,
                        competitionCursor: 4
                    )
                }
            ),
            environment: .accelerated(source: source),
            outboxStore: outboxStore,
            now: { dayOneNoon }
        )

        let outcome = await runtime.synchronizeAll()

        XCTAssertEqual(outcome.failures, [])
        let requests = await probe.scoreRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.competitionID, competitionID)
        XCTAssertEqual(request.dayOrdinal, 1)
        XCTAssertEqual(request.clientRevision, 1)
        XCTAssertEqual(request.moveMode, "activeEnergyKilocalories")
        XCTAssertEqual(request.standMode, "standHours")
        XCTAssertEqual(request.moveBasisPoints, 7_000)
        XCTAssertEqual(request.exerciseBasisPoints, 8_000)
        XCTAssertEqual(request.standBasisPoints, 8_333)
        XCTAssertEqual(request.availabilityReason, "available")
        XCTAssertEqual(
            request.scoringPolicyIdentity,
            RemoteScoringWireV1.policyIdentity
        )
        XCTAssertFalse(request.wireContentSHA256.isEmpty)
        let remainingOutboxEntries = try await outboxStore.entries()
        XCTAssertEqual(remainingOutboxEntries, [])
        let materialized = try XCTUnwrap(
            outcome.successfulCompetitions.first
        )
        let ownerLedger = try XCTUnwrap(
            materialized.journal.projection.remoteScoreLedgers[profileID]
        )
        let accepted = try XCTUnwrap(
            try ownerLedger.visibleEntry(forActiveDayOrdinal: 1)
        )
        XCTAssertEqual(accepted.acceptedCentiPoints, 23_333)
        XCTAssertEqual(accepted.clientRevision, 1)
        XCTAssertEqual(
            materialized.journal.projection.synchronizationCursor,
            4
        )
    }

    func testRemoteScoreArrivalPersistsLedgerAndRelaunchIsIdempotent()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let creatorID = UUID(
            uuidString: "72000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try scheduledDescriptor(
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt,
            nextServerSequence: 5
        )
        let bootstrap = try scheduledHistoryPage(
            descriptor: descriptor,
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt
        ).changes
        let wire = try RemoteScoreRevisionWireV1(
            competitionID: competitionID,
            participantID: creatorID,
            dayOrdinal: 1,
            moveMode: "activeEnergyKilocalories",
            standMode: "standHours",
            moveBasisPoints: 9_000,
            exerciseBasisPoints: 8_500,
            standBasisPoints: 8_000,
            availabilityReason: "available",
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            clientRevision: 1
        )
        let scoreChange = try CompetitionChange(
            serverSequence: 4,
            kind: .scoreRevisionRecorded,
            entityID: creatorID,
            occurredAt: createdAt.addingTimeInterval(7_200),
            payload: .score(
                try CompetitionScoreChange(
                    participantProfileID: creatorID,
                    dayOrdinal: wire.dayOrdinal,
                    clientRevision: wire.clientRevision,
                    moveMode: wire.moveMode,
                    standMode: wire.standMode,
                    moveBasisPoints: wire.moveBasisPoints,
                    exerciseBasisPoints: wire.exerciseBasisPoints,
                    standBasisPoints: wire.standBasisPoints,
                    acceptedCentiPoints: wire.acceptedCentiPoints,
                    availabilityReason: wire.availabilityReason,
                    scoringPolicyIdentity: wire.scoringPolicyIdentity,
                    wireDigestVersion: 1,
                    wireContentSHA256: wire.wireContentSHA256,
                    serverSequence: 4,
                    evaluatedAt: createdAt.addingTimeInterval(7_200)
                )
            )
        )
        let page = try CompetitionChangePage(
            competitionID: competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 4,
            nextServerSequence: 4,
            hasMore: false,
            changes: bootstrap + [scoreChange]
        )
        let api = remoteAPI(
            listCompetitions: { [descriptor] },
            fetchChanges: { _, _ in page }
        )
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: api,
            now: { createdAt }
        )

        let first = await runtime.synchronizeAll()

        XCTAssertEqual(first.failures, [])
        let firstMaterialization = try XCTUnwrap(
            first.successfulCompetitions.first
        )
        let remoteLedger = try XCTUnwrap(
            firstMaterialization.journal.projection
                .remoteScoreLedgers[creatorID]
        )
        XCTAssertEqual(
            try remoteLedger.visibleEntry(forActiveDayOrdinal: 1),
            try RemoteAcceptedScoreRow(
                ordinal: 1,
                acceptedCentiPoints: 25_500,
                availabilityReason: nil,
                wireContentSHA256: wire.wireContentSHA256,
                clientRevision: 1,
                serverSequence: 4
            )
        )
        let firstCursor = firstMaterialization.journal.journal.cursor

        let relaunched = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: api,
            now: { createdAt }
        )
        let second = await relaunched.synchronizeAll()

        XCTAssertEqual(second.failures, [])
        XCTAssertEqual(
            second.successfulCompetitions.first?.journal.journal.cursor,
            firstCursor
        )
    }

    func testStableServerResultIsTheOnlyRemoteCompletionAuthority()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let creatorID = UUID(
            uuidString: "72000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let completedAt = Date(timeIntervalSince1970: 1_787_317_200)
        let descriptor = try scheduledDescriptor(
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt,
            nextServerSequence: 19,
            lifecycle: .completed
        )
        var changes = try scheduledHistoryPage(
            descriptor: descriptor,
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt
        ).changes
        var frozenWindows: [CompetitionFrozenParticipantWindow] = []
        var sequence: Int64 = 4
        for participant in [profileID, creatorID] {
            var frozenDays: [CompetitionFrozenDay] = []
            for ordinal in 1...7 {
                let basisPoints = participant == profileID ? 10_000 : 9_000
                let wire = try RemoteScoreRevisionWireV1(
                    competitionID: competitionID,
                    participantID: participant,
                    dayOrdinal: ordinal,
                    moveMode: "activeEnergyKilocalories",
                    standMode: "standHours",
                    moveBasisPoints: basisPoints,
                    exerciseBasisPoints: basisPoints,
                    standBasisPoints: basisPoints,
                    availabilityReason: "available",
                    scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
                    clientRevision: Int64(ordinal)
                )
                let evaluatedAt = createdAt.addingTimeInterval(
                    TimeInterval(sequence * 60)
                )
                changes.append(
                    try CompetitionChange(
                        serverSequence: sequence,
                        kind: .scoreRevisionRecorded,
                        entityID: participant,
                        occurredAt: evaluatedAt,
                        payload: .score(
                            try CompetitionScoreChange(
                                participantProfileID: participant,
                                dayOrdinal: ordinal,
                                clientRevision: Int64(ordinal),
                                moveMode: wire.moveMode,
                                standMode: wire.standMode,
                                moveBasisPoints: wire.moveBasisPoints,
                                exerciseBasisPoints: wire.exerciseBasisPoints,
                                standBasisPoints: wire.standBasisPoints,
                                acceptedCentiPoints: wire
                                    .acceptedCentiPoints,
                                availabilityReason: wire
                                    .availabilityReason,
                                scoringPolicyIdentity: wire
                                    .scoringPolicyIdentity,
                                wireDigestVersion: 1,
                                wireContentSHA256: wire
                                    .wireContentSHA256,
                                serverSequence: sequence,
                                evaluatedAt: evaluatedAt
                            )
                        )
                    )
                )
                frozenDays.append(
                    try CompetitionFrozenDay(
                        ordinal: ordinal,
                        status: .points,
                        source: .acceptedRevision,
                        centiPoints: wire.acceptedCentiPoints,
                        reason: nil,
                        wireContentSHA256: wire.wireContentSHA256,
                        clientRevision: Int64(ordinal),
                        serverSequence: sequence,
                        scoringPolicyIdentity: wire
                            .scoringPolicyIdentity
                    )
                )
                sequence += 1
            }
            let commitment = try RemoteFinalizationWireV1.windowCommitment(
                competitionID: competitionID,
                participantID: participant,
                days: try frozenDays.map { day in
                    try RemoteFinalizationDayV1(
                        ordinal: day.ordinal,
                        status: .points,
                        source: .acceptedRevision,
                        points: day.centiPoints,
                        reason: nil,
                        wireContentSHA256: day.wireContentSHA256,
                        clientRevision: day.clientRevision,
                        serverSequence: day.serverSequence
                    )
                }
            )
            frozenWindows.append(
                try CompetitionFrozenParticipantWindow(
                    profileID: participant,
                    totalCentiPoints: participant == profileID
                        ? 210_000
                        : 189_000,
                    windowCommitmentSHA256: commitment,
                    days: frozenDays
                )
            )
        }
        let immutableHash = try RemoteFinalizationWireV1.resultHash(
            competitionID: competitionID,
            participantA: profileID,
            totalA: 210_000,
            commitmentA: frozenWindows[0].windowCommitmentSHA256,
            participantB: creatorID,
            totalB: 189_000,
            commitmentB: frozenWindows[1].windowCommitmentSHA256,
            outcome: "winner",
            winner: profileID,
            basis: "stable"
        )
        changes.append(
            try CompetitionChange(
                serverSequence: sequence,
                kind: .competitionResultConfirmed,
                entityID: competitionID,
                occurredAt: completedAt,
                payload: .result(
                    try CompetitionResultChange(
                        participantAProfileID: profileID,
                        participantBProfileID: creatorID,
                        participantATotalCentiPoints: 210_000,
                        participantBTotalCentiPoints: 189_000,
                        winnerProfileID: profileID,
                        outcome: .winner,
                        finalizationBasis: .stable,
                        completedAt: completedAt,
                        frozenWindow: try CompetitionFrozenWindow(
                            policy: RemoteScoringWireV1.policyIdentity,
                            participants: frozenWindows
                        ),
                        immutableHash: immutableHash,
                        serverSequence: sequence
                    )
                )
            )
        )
        let page = try CompetitionChangePage(
            competitionID: competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: sequence,
            nextServerSequence: sequence,
            hasMore: false,
            changes: changes
        )
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page }
            ),
            now: { completedAt }
        )

        let outcome = await runtime.synchronizeAll()

        XCTAssertEqual(outcome.failures, [])
        let materialized = try XCTUnwrap(
            outcome.successfulCompetitions.first
        )
        XCTAssertEqual(
            materialized.journal.projection.sharedResult?.resultHash,
            immutableHash
        )
        guard case let .completed(completed) = materialized.journal
            .projection.competition.lifecycle
        else {
            return XCTFail("Expected server-confirmed completion")
        }
        XCTAssertEqual(completed.basis, .stableAcrossPostBoundaryReads)
        XCTAssertEqual(completed.snapshot.userPoints, 2_100)
        XCTAssertEqual(completed.snapshot.opponentPoints, 1_890)

        let archivedAt = completedAt.addingTimeInterval(86_400)
        let archivedDescriptor = try scheduledDescriptor(
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt,
            nextServerSequence: sequence + 2,
            lifecycle: .archived
        )
        let archiveChange = try CompetitionChange(
            serverSequence: sequence + 1,
            kind: .competitionLifecycleChanged,
            entityID: competitionID,
            occurredAt: archivedAt,
            payload: .lifecycle(
                try CompetitionLifecycleChange(
                    lifecycle: .archived,
                    timeZoneIdentifier: archivedDescriptor
                        .timeZoneIdentifier,
                    startDay: archivedDescriptor.startDay,
                    bestAvailableDeadline: archivedDescriptor
                        .bestAvailableDeadline,
                    scoringPolicyIdentity: archivedDescriptor
                        .scoringPolicyIdentity
                )
            )
        )
        let archivedPage = try CompetitionChangePage(
            competitionID: competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: sequence + 1,
            nextServerSequence: sequence + 1,
            hasMore: false,
            changes: changes + [archiveChange]
        )
        let archivedRuntime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [archivedDescriptor] },
                fetchChanges: { _, _ in archivedPage }
            ),
            now: { archivedAt }
        )

        let archivedOutcome = await archivedRuntime.synchronizeAll()

        XCTAssertEqual(archivedOutcome.failures, [])
        guard case let .archived(archived) = archivedOutcome
            .successfulCompetitions.first?.journal.projection
            .competition.lifecycle
        else {
            return XCTFail("Expected server-confirmed archive")
        }
        XCTAssertEqual(archived.archivedAt, archivedAt)
        XCTAssertEqual(archived.completed.completedAt, completedAt)
    }

    func testCompleteOwnerWindowEnqueuesStableAttestationAndKeepsAckUntilFeed()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let outboxRoot = root.appendingPathComponent(
            "outbox",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outboxRoot,
            withIntermediateDirectories: true
        )
        let outboxStore = JSONCompetitionOutboxStore(
            rootDirectory: outboxRoot,
            faultInjector: .none,
            fileProtection: JSONCompetitionEventStoreFileProtection {
                _, _ in
            }
        )
        let creatorID = UUID(
            uuidString: "72000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try scheduledDescriptor(
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt,
            nextServerSequence: 11,
            lifecycle: .tallying
        )
        var changes = try scheduledHistoryPage(
            descriptor: descriptor,
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt
        ).changes
        for ordinal in 1...7 {
            let sequence = Int64(ordinal + 3)
            let wire = try RemoteScoreRevisionWireV1(
                competitionID: competitionID,
                participantID: profileID,
                dayOrdinal: ordinal,
                moveMode: "activeEnergyKilocalories",
                standMode: "standHours",
                moveBasisPoints: 10_000,
                exerciseBasisPoints: 10_000,
                standBasisPoints: 10_000,
                availabilityReason: "available",
                scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
                clientRevision: Int64(ordinal)
            )
            let evaluatedAt = createdAt.addingTimeInterval(
                TimeInterval(sequence * 60)
            )
            changes.append(
                try CompetitionChange(
                    serverSequence: sequence,
                    kind: .scoreRevisionRecorded,
                    entityID: profileID,
                    occurredAt: evaluatedAt,
                    payload: .score(
                        try CompetitionScoreChange(
                            participantProfileID: profileID,
                            dayOrdinal: ordinal,
                            clientRevision: Int64(ordinal),
                            moveMode: wire.moveMode,
                            standMode: wire.standMode,
                            moveBasisPoints: wire.moveBasisPoints,
                            exerciseBasisPoints: wire.exerciseBasisPoints,
                            standBasisPoints: wire.standBasisPoints,
                            acceptedCentiPoints: wire.acceptedCentiPoints,
                            availabilityReason: wire.availabilityReason,
                            scoringPolicyIdentity: wire
                                .scoringPolicyIdentity,
                            wireDigestVersion: 1,
                            wireContentSHA256: wire.wireContentSHA256,
                            serverSequence: sequence,
                            evaluatedAt: evaluatedAt
                        )
                    )
                )
            )
        }
        let page = try CompetitionChangePage(
            competitionID: competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 10,
            nextServerSequence: 10,
            hasMore: false,
            changes: changes
        )
        let probe = RemoteCompetitionRuntimeProbe()
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page },
                submitAttestation: { request in
                    await probe.recordAttestationRequest(request)
                    return try CompetitionAttestationReceipt(
                        disposition: .appended,
                        windowCommitmentSHA256: request
                            .windowCommitmentSHA256,
                        entityServerSequence: 11
                    )
                }
            ),
            outboxStore: outboxStore,
            now: {
                descriptor.bestAvailableDeadline!
                    .addingTimeInterval(-3_600)
            }
        )

        let outcome = await runtime.synchronizeAll()

        XCTAssertEqual(outcome.failures, [])
        let materialized = try XCTUnwrap(
            outcome.successfulCompetitions.first
        )
        let ledger = try XCTUnwrap(
            materialized.journal.projection.remoteScoreLedgers[profileID]
        )
        let requests = await probe.attestationRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.competitionID, competitionID)
        XCTAssertEqual(request.basis, .stable)
        XCTAssertEqual(request.acceptedRevisions, (1...7).map(Int64.init))
        XCTAssertEqual(
            request.windowCommitmentSHA256,
            try ledger.windowCommitment()
        )
        let outboxEntries = try await outboxStore.entries()
        XCTAssertEqual(outboxEntries.count, 1)
        XCTAssertEqual(outboxEntries.first?.payload, .finalWindowAttestation(request))
        guard case let .attestationAcknowledged(receipt, _)? =
            outboxEntries.first?.state
        else {
            return XCTFail("Expected durable attestation acknowledgment")
        }
        XCTAssertEqual(receipt.entityServerSequence, 11)
        XCTAssertNil(
            materialized.journal.projection
                .remoteWindowAttestations[profileID]
        )

        let attestedAt = try XCTUnwrap(descriptor.bestAvailableDeadline)
            .addingTimeInterval(-3_600)
        let updatedDescriptor = try scheduledDescriptor(
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt,
            nextServerSequence: 12,
            lifecycle: .tallying
        )
        let attestationChange = try CompetitionChange(
            serverSequence: 11,
            kind: .participantAttested,
            entityID: profileID,
            occurredAt: attestedAt,
            payload: .participantAttestation(
                try CompetitionParticipantAttestationChange(
                    participantProfileID: profileID,
                    basis: .stable,
                    windowCommitmentSHA256: request
                        .windowCommitmentSHA256,
                    acceptedRevisions: request.acceptedRevisions,
                    attestationVersion: request.attestationVersion,
                    serverSequence: 11,
                    attestedAt: attestedAt
                )
            )
        )
        let pageWithAttestation = try CompetitionChangePage(
            competitionID: competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 11,
            nextServerSequence: 11,
            hasMore: false,
            changes: changes + [attestationChange]
        )
        let relaunched = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [updatedDescriptor] },
                fetchChanges: { _, _ in pageWithAttestation }
            ),
            outboxStore: outboxStore,
            now: { attestedAt }
        )

        let reconciled = await relaunched.synchronizeAll()

        XCTAssertEqual(reconciled.failures, [])
        XCTAssertEqual(
            reconciled.successfulCompetitions.first?.journal.projection
                .remoteWindowAttestations[profileID]?
                .windowCommitment,
            request.windowCommitmentSHA256
        )
        let cleanedEntries = try await outboxStore.entries()
        XCTAssertEqual(cleanedEntries, [])
        let finalRequests = await probe.attestationRequests()
        XCTAssertEqual(finalRequests.count, 1)
    }

    func testIncompleteBestAvailableServerResultCompletesAfterDeadline()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let creatorID = UUID(
            uuidString: "72000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try scheduledDescriptor(
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt,
            nextServerSequence: 6,
            lifecycle: .completed
        )
        let completedAt = try XCTUnwrap(descriptor.bestAvailableDeadline)
            .addingTimeInterval(3_600)
        var changes = try scheduledHistoryPage(
            descriptor: descriptor,
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt
        ).changes
        let wire = try RemoteScoreRevisionWireV1(
            competitionID: competitionID,
            participantID: profileID,
            dayOrdinal: 1,
            moveMode: "activeEnergyKilocalories",
            standMode: "standHours",
            moveBasisPoints: 10_000,
            exerciseBasisPoints: 10_000,
            standBasisPoints: 10_000,
            availabilityReason: "available",
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            clientRevision: 1
        )
        let ownerPoints = try XCTUnwrap(wire.acceptedCentiPoints)
        changes.append(
            try CompetitionChange(
                serverSequence: 4,
                kind: .scoreRevisionRecorded,
                entityID: profileID,
                occurredAt: completedAt.addingTimeInterval(-60),
                payload: .score(
                    try CompetitionScoreChange(
                        participantProfileID: profileID,
                        dayOrdinal: 1,
                        clientRevision: 1,
                        moveMode: wire.moveMode,
                        standMode: wire.standMode,
                        moveBasisPoints: wire.moveBasisPoints,
                        exerciseBasisPoints: wire.exerciseBasisPoints,
                        standBasisPoints: wire.standBasisPoints,
                        acceptedCentiPoints: wire.acceptedCentiPoints,
                        availabilityReason: wire.availabilityReason,
                        scoringPolicyIdentity: wire.scoringPolicyIdentity,
                        wireDigestVersion: 1,
                        wireContentSHA256: wire.wireContentSHA256,
                        serverSequence: 4,
                        evaluatedAt: completedAt.addingTimeInterval(-60)
                    )
                )
            )
        )
        let ownerDays = try (1...7).map {
            ordinal -> CompetitionFrozenDay in
            if ordinal == 1 {
                return try CompetitionFrozenDay(
                    ordinal: ordinal,
                    status: .points,
                    source: .acceptedRevision,
                    centiPoints: wire.acceptedCentiPoints,
                    reason: nil,
                    wireContentSHA256: wire.wireContentSHA256,
                    clientRevision: wire.clientRevision,
                    serverSequence: 4,
                    scoringPolicyIdentity: wire.scoringPolicyIdentity
                )
            }
            return try CompetitionFrozenDay(
                ordinal: ordinal,
                status: .unavailable,
                source: .deadlineMissing,
                centiPoints: nil,
                reason: "missing",
                wireContentSHA256: nil,
                clientRevision: nil,
                serverSequence: nil,
                scoringPolicyIdentity: nil
            )
        }
        let remoteDays = try (1...7).map {
            ordinal in
            try CompetitionFrozenDay(
                ordinal: ordinal,
                status: .unavailable,
                source: .deadlineMissing,
                centiPoints: nil,
                reason: "missing",
                wireContentSHA256: nil,
                clientRevision: nil,
                serverSequence: nil,
                scoringPolicyIdentity: nil
            )
        }
        let ownerCommitment = try RemoteFinalizationWireV1
            .windowCommitment(
                competitionID: competitionID,
                participantID: profileID,
                days: try ownerDays.map { try $0.domainValueForTest() }
            )
        let remoteCommitment = try RemoteFinalizationWireV1
            .windowCommitment(
                competitionID: competitionID,
                participantID: creatorID,
                days: try remoteDays.map { try $0.domainValueForTest() }
            )
        let ownerWindow = try CompetitionFrozenParticipantWindow(
            profileID: profileID,
            totalCentiPoints: ownerPoints,
            windowCommitmentSHA256: ownerCommitment,
            days: ownerDays
        )
        let remoteWindow = try CompetitionFrozenParticipantWindow(
            profileID: creatorID,
            totalCentiPoints: 0,
            windowCommitmentSHA256: remoteCommitment,
            days: remoteDays
        )
        let immutableHash = try RemoteFinalizationWireV1.resultHash(
            competitionID: competitionID,
            participantA: profileID,
            totalA: ownerPoints,
            commitmentA: ownerCommitment,
            participantB: creatorID,
            totalB: 0,
            commitmentB: remoteCommitment,
            outcome: "winner",
            winner: profileID,
            basis: "best_available"
        )
        changes.append(
            try CompetitionChange(
                serverSequence: 5,
                kind: .competitionResultConfirmed,
                entityID: competitionID,
                occurredAt: completedAt,
                payload: .result(
                    try CompetitionResultChange(
                        participantAProfileID: profileID,
                        participantBProfileID: creatorID,
                        participantATotalCentiPoints: ownerPoints,
                        participantBTotalCentiPoints: 0,
                        winnerProfileID: profileID,
                        outcome: .winner,
                        finalizationBasis: .bestAvailable,
                        completedAt: completedAt,
                        frozenWindow: try CompetitionFrozenWindow(
                            policy: RemoteScoringWireV1.policyIdentity,
                            participants: [ownerWindow, remoteWindow]
                        ),
                        immutableHash: immutableHash,
                        serverSequence: 5
                    )
                )
            )
        )
        let page = try CompetitionChangePage(
            competitionID: competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 5,
            nextServerSequence: 5,
            hasMore: false,
            changes: changes
        )
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page }
            ),
            now: { completedAt }
        )

        let outcome = await runtime.synchronizeAll()

        XCTAssertEqual(outcome.failures, [])
        let projection = try XCTUnwrap(
            outcome.successfulCompetitions.first?.journal.projection
        )
        XCTAssertEqual(projection.sharedResult?.resultHash, immutableHash)
        XCTAssertEqual(projection.sharedResult?.basis, .bestAvailable)
        guard case let .completed(completed) = projection
            .competition.lifecycle
        else {
            return XCTFail("Expected server-confirmed completion")
        }
        XCTAssertEqual(completed.basis, .bestAvailable)
        XCTAssertEqual(completed.snapshot.userPoints, 300)
        XCTAssertEqual(completed.snapshot.opponentPoints, 0)
    }

    func testDeadlineWithMissingOwnerDayEnqueuesBestAvailableAttestation()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let outboxRoot = root.appendingPathComponent(
            "outbox",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outboxRoot,
            withIntermediateDirectories: true
        )
        let outboxStore = JSONCompetitionOutboxStore(
            rootDirectory: outboxRoot,
            faultInjector: .none,
            fileProtection: JSONCompetitionEventStoreFileProtection {
                _, _ in
            }
        )
        let creatorID = UUID(
            uuidString: "72000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try scheduledDescriptor(
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt,
            nextServerSequence: 10,
            lifecycle: .tallying
        )
        var changes = try scheduledHistoryPage(
            descriptor: descriptor,
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt
        ).changes
        var finalizationDays: [RemoteFinalizationDayV1] = []
        for ordinal in 1...6 {
            let sequence = Int64(ordinal + 3)
            let wire = try RemoteScoreRevisionWireV1(
                competitionID: competitionID,
                participantID: profileID,
                dayOrdinal: ordinal,
                moveMode: "activeEnergyKilocalories",
                standMode: "standHours",
                moveBasisPoints: 10_000,
                exerciseBasisPoints: 10_000,
                standBasisPoints: 10_000,
                availabilityReason: "available",
                scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
                clientRevision: Int64(ordinal)
            )
            let evaluatedAt = createdAt.addingTimeInterval(
                TimeInterval(sequence * 60)
            )
            changes.append(
                try CompetitionChange(
                    serverSequence: sequence,
                    kind: .scoreRevisionRecorded,
                    entityID: profileID,
                    occurredAt: evaluatedAt,
                    payload: .score(
                        try CompetitionScoreChange(
                            participantProfileID: profileID,
                            dayOrdinal: ordinal,
                            clientRevision: Int64(ordinal),
                            moveMode: wire.moveMode,
                            standMode: wire.standMode,
                            moveBasisPoints: wire.moveBasisPoints,
                            exerciseBasisPoints: wire.exerciseBasisPoints,
                            standBasisPoints: wire.standBasisPoints,
                            acceptedCentiPoints: wire.acceptedCentiPoints,
                            availabilityReason: wire.availabilityReason,
                            scoringPolicyIdentity: wire
                                .scoringPolicyIdentity,
                            wireDigestVersion: 1,
                            wireContentSHA256: wire.wireContentSHA256,
                            serverSequence: sequence,
                            evaluatedAt: evaluatedAt
                        )
                    )
                )
            )
            finalizationDays.append(
                try RemoteFinalizationDayV1(
                    ordinal: ordinal,
                    status: .points,
                    source: .acceptedRevision,
                    points: wire.acceptedCentiPoints,
                    reason: nil,
                    wireContentSHA256: wire.wireContentSHA256,
                    clientRevision: Int64(ordinal),
                    serverSequence: sequence
                )
            )
        }
        finalizationDays.append(
            try RemoteFinalizationDayV1(
                ordinal: 7,
                status: .unavailable,
                source: .deadlineMissing,
                points: nil,
                reason: "missing",
                wireContentSHA256: nil,
                clientRevision: nil,
                serverSequence: nil
            )
        )
        let page = try CompetitionChangePage(
            competitionID: competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 9,
            nextServerSequence: 9,
            hasMore: false,
            changes: changes
        )
        let probe = RemoteCompetitionRuntimeProbe()
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page },
                submitAttestation: { request in
                    await probe.recordAttestationRequest(request)
                    return try CompetitionAttestationReceipt(
                        disposition: .appended,
                        windowCommitmentSHA256: request
                            .windowCommitmentSHA256,
                        entityServerSequence: 10
                    )
                }
            ),
            outboxStore: outboxStore,
            now: { descriptor.bestAvailableDeadline! }
        )

        let outcome = await runtime.synchronizeAll()

        XCTAssertEqual(outcome.failures, [])
        let requests = await probe.attestationRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.basis, .bestAvailable)
        XCTAssertEqual(
            request.acceptedRevisions,
            [1, 2, 3, 4, 5, 6, 0]
        )
        XCTAssertEqual(
            request.windowCommitmentSHA256,
            try RemoteFinalizationWireV1.windowCommitment(
                competitionID: competitionID,
                participantID: profileID,
                days: finalizationDays
            )
        )
        let entries = try await outboxStore.entries()
        XCTAssertEqual(entries.count, 1)
        guard case .attestationAcknowledged? = entries.first?.state else {
            return XCTFail("Expected durable attestation acknowledgment")
        }
    }

    func testDeadlineWithNoOwnerRowsEnqueuesAllMissingAttestation()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let outboxRoot = root.appendingPathComponent(
            "outbox-all-missing",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outboxRoot,
            withIntermediateDirectories: true
        )
        let outboxStore = JSONCompetitionOutboxStore(
            rootDirectory: outboxRoot,
            faultInjector: .none,
            fileProtection: JSONCompetitionEventStoreFileProtection { _, _ in }
        )
        let creatorID = UUID(
            uuidString: "72000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try scheduledDescriptor(
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt,
            lifecycle: .tallying
        )
        let page = try scheduledHistoryPage(
            descriptor: descriptor,
            creatorID: creatorID,
            inviteeID: profileID,
            createdAt: createdAt
        )
        let probe = RemoteCompetitionRuntimeProbe()
        let runtime = RemoteCompetitionRuntime(
            profileID: profileID,
            store: store,
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page },
                submitAttestation: { request in
                    await probe.recordAttestationRequest(request)
                    return try CompetitionAttestationReceipt(
                        disposition: .appended,
                        windowCommitmentSHA256: request
                            .windowCommitmentSHA256,
                        entityServerSequence: 4
                    )
                }
            ),
            outboxStore: outboxStore,
            now: { descriptor.bestAvailableDeadline! }
        )

        let outcome = await runtime.synchronizeAll()

        XCTAssertEqual(outcome.failures, [])
        let requests = await probe.attestationRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.basis, .bestAvailable)
        XCTAssertEqual(request.acceptedRevisions, Array(repeating: 0, count: 7))
        let allMissingDays = try (1...7).map { ordinal in
            try RemoteFinalizationDayV1(
                ordinal: ordinal,
                status: .unavailable,
                source: .deadlineMissing,
                points: nil,
                reason: "missing",
                wireContentSHA256: nil,
                clientRevision: nil,
                serverSequence: nil
            )
        }
        XCTAssertEqual(
            request.windowCommitmentSHA256,
            try RemoteFinalizationWireV1.windowCommitment(
                competitionID: competitionID,
                participantID: profileID,
                days: allMissingDays
            )
        )
    }

    func testTwoIndependentClientsConvergeAfterOfflineAndDuplicateReconciliation()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let aliceID = profileID
        let bobID = UUID(
            uuidString: "72000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let server = try TwoClientCompetitionServer(
            competitionID: competitionID,
            creatorID: aliceID,
            inviteeID: bobID,
            createdAt: createdAt
        )
        let aliceRoot = root.appendingPathComponent(
            "alice",
            isDirectory: true
        )
        let bobRoot = root.appendingPathComponent("bob", isDirectory: true)
        for profileRoot in [aliceRoot, bobRoot] {
            try FileManager.default.createDirectory(
                at: profileRoot,
                withIntermediateDirectories: true
            )
            for child in ["events", "outbox", "cursors"] {
                try FileManager.default.createDirectory(
                    at: profileRoot.appendingPathComponent(
                        child,
                        isDirectory: true
                    ),
                    withIntermediateDirectories: true
                )
            }
        }
        let aliceStore = makeStore(
            root: aliceRoot.appendingPathComponent("events")
        )
        let bobStore = makeStore(
            root: bobRoot.appendingPathComponent("events")
        )
        let noProtection = JSONCompetitionEventStoreFileProtection {
            _, _ in
        }
        let aliceOutbox = JSONCompetitionOutboxStore(
            rootDirectory: aliceRoot.appendingPathComponent("outbox"),
            faultInjector: .none,
            fileProtection: noProtection
        )
        let bobOutbox = JSONCompetitionOutboxStore(
            rootDirectory: bobRoot.appendingPathComponent("outbox"),
            faultInjector: .none,
            fileProtection: noProtection
        )
        let aliceCache = JSONRemoteCompetitionCacheStore(
            rootDirectory: aliceRoot.appendingPathComponent("cursors"),
            fileProtection: noProtection
        )
        let bobCache = JSONRemoteCompetitionCacheStore(
            rootDirectory: bobRoot.appendingPathComponent("cursors"),
            fileProtection: noProtection
        )
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let startDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 13,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let days = try calendar.sevenDayWindow(startingOn: startDay)
        let dayOneNoon = try calendar.startOfDay(startDay)
            .addingTimeInterval(12 * 60 * 60)
        let aliceSnapshot = ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: 420, goal: 600),
            exercise: try ActivityRingReading(value: 24, goal: 30),
            standOrRoll: try ActivityRingReading(value: 10, goal: 12),
            pauseState: .running
        )
        let bobSnapshot = ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: 600, goal: 600),
            exercise: try ActivityRingReading(value: 30, goal: 30),
            standOrRoll: try ActivityRingReading(value: 12, goal: 12),
            pauseState: .running
        )
        func environment(
            epochID: String,
            snapshot: ActivitySnapshot
        ) throws -> CompetitionEnvironmentClient {
            .accelerated(
                fixture: try ActivityFixture(
                    initialInstant: EnvironmentInstant(
                        wallDate: dayOneNoon,
                        monotonic: MonotonicInstant(
                            epochID: epochID,
                            nanoseconds: 1
                        )
                    ),
                    timeZoneIdentifier: calendar.timeZoneIdentifier,
                    initialDays: [
                        .snapshot(day: days[0], snapshot: snapshot),
                    ] + days.dropFirst().map { .missing(day: $0) },
                    changes: []
                )
            )
        }
        let aliceAPI = remoteAPI(
            listCompetitions: {
                try await server.listCompetitions(for: aliceID)
            },
            fetchChanges: { cursor, pageSize in
                try await server.fetchChanges(
                    for: aliceID,
                    cursor: cursor,
                    pageSize: pageSize
                )
            },
            appendScoreRevision: { request in
                try await server.appendScoreRevision(
                    for: aliceID,
                    request: request
                )
            }
        )
        let bobAPI = remoteAPI(
            listCompetitions: {
                try await server.listCompetitions(for: bobID)
            },
            fetchChanges: { cursor, pageSize in
                try await server.fetchChanges(
                    for: bobID,
                    cursor: cursor,
                    pageSize: pageSize
                )
            },
            appendScoreRevision: { request in
                try await server.appendScoreRevision(
                    for: bobID,
                    request: request
                )
            }
        )
        let aliceRuntime = RemoteCompetitionRuntime(
            profileID: aliceID,
            store: aliceStore,
            remoteAPI: aliceAPI,
            environment: try environment(
                epochID: "two-client-alice",
                snapshot: aliceSnapshot
            ),
            outboxStore: aliceOutbox,
            cacheStore: aliceCache,
            now: { dayOneNoon }
        )
        let bobRuntime = RemoteCompetitionRuntime(
            profileID: bobID,
            store: bobStore,
            remoteAPI: bobAPI,
            environment: try environment(
                epochID: "two-client-bob",
                snapshot: bobSnapshot
            ),
            outboxStore: bobOutbox,
            cacheStore: bobCache,
            now: { dayOneNoon }
        )

        let initialAlice = await aliceRuntime.synchronizeAll()
        let initialBob = await bobRuntime.synchronizeAll()
        XCTAssertEqual(initialAlice.failures, [])
        XCTAssertEqual(initialBob.failures, [])
        await server.setOnline(false, for: aliceID)
        let offlineAlice = await aliceRuntime.synchronizeAll()
        XCTAssertNotNil(offlineAlice.discoveryFailure)
        XCTAssertEqual(offlineAlice.successfulCompetitions.count, 1)
        await server.setOnline(true, for: aliceID)

        let convergedAlice = await aliceRuntime.synchronizeAll()
        let convergedBob = await bobRuntime.synchronizeAll()
        let duplicateAlice = await aliceRuntime.synchronizeAll()
        let duplicateBob = await bobRuntime.synchronizeAll()

        for outcome in [
            convergedAlice,
            convergedBob,
            duplicateAlice,
            duplicateBob,
        ] {
            XCTAssertNil(outcome.discoveryFailure)
            XCTAssertEqual(outcome.failures, [])
        }
        let aliceProjection = try XCTUnwrap(
            duplicateAlice.successfulCompetitions.first?.journal.projection
        )
        let bobProjection = try XCTUnwrap(
            duplicateBob.successfulCompetitions.first?.journal.projection
        )
        for participantID in [aliceID, bobID] {
            XCTAssertEqual(
                try aliceProjection.remoteScoreLedgers[participantID]?
                    .visibleEntry(forActiveDayOrdinal: 1),
                try bobProjection.remoteScoreLedgers[participantID]?
                    .visibleEntry(forActiveDayOrdinal: 1)
            )
        }
        XCTAssertEqual(
            try aliceProjection.remoteScoreLedgers[aliceID]?
                .visibleEntry(forActiveDayOrdinal: 1)?
                .acceptedCentiPoints,
            23_333
        )
        XCTAssertEqual(
            try aliceProjection.remoteScoreLedgers[bobID]?
                .visibleEntry(forActiveDayOrdinal: 1)?
                .acceptedCentiPoints,
            30_000
        )
        let appendedScoreCount = await server.appendedScoreCount()
        let aliceOutboxEntries = try await aliceOutbox.entries()
        let bobOutboxEntries = try await bobOutbox.entries()
        XCTAssertEqual(appendedScoreCount, 2)
        XCTAssertEqual(aliceOutboxEntries, [])
        XCTAssertEqual(bobOutboxEntries, [])
        await aliceRuntime.stop()
        await bobRuntime.stop()
    }

    private func remoteAPI(
        listCompetitions: @escaping @Sendable () async throws ->
            [CompetitionDescriptor],
        fetchChanges: @escaping @Sendable (
            CompetitionSynchronizationCursor,
            Int
        ) async throws -> CompetitionChangePage = { _, _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        appendScoreRevision: @escaping @Sendable (
            CompetitionScoreRevisionRequest
        ) async throws -> CompetitionScoreRevisionResponse = { _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        submitAttestation: @escaping @Sendable (
            CompetitionAttestationRequest
        ) async throws -> CompetitionAttestationReceipt = { _ in
            throw CompetitionRemoteFailure.operationFailed
        }
    ) -> CompetitionRemoteAPI {
        CompetitionRemoteAPI(
            bootstrapProfile: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            updateProfile: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            listCompetitions: listCompetitions,
            fetchCompetition: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            createInvite: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            claimInvite: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            appendScoreRevision: appendScoreRevision,
            submitAttestation: submitAttestation,
            fetchChanges: fetchChanges,
            registerInstallation: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            removeInstallation: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            requestAccountDeletion: {
                throw CompetitionRemoteFailure.operationFailed
            }
        )
    }

    private func pendingDescriptor(
        creatorProfileID: UUID,
        expiresAt: Date
    ) throws -> CompetitionDescriptor {
        try CompetitionDescriptor(
            competitionID: competitionID,
            creatorProfileID: creatorProfileID,
            timeZoneIdentifier: nil,
            startDay: nil,
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            lifecycle: .pending,
            invitationExpiresAt: expiresAt,
            bestAvailableDeadline: nil,
            rematchParentID: nil,
            nextServerSequence: 2,
            participants: [
                try CompetitionParticipantDescriptor(
                    profileID: creatorProfileID,
                    role: .creator,
                    state: .accepted,
                    profile: try CompetitionProfilePresentation(
                        id: creatorProfileID,
                        displayName: "Beta Alice"
                    )
                ),
            ]
        )
    }

    private func scheduledDescriptor(
        creatorID: UUID,
        inviteeID: UUID,
        createdAt: Date,
        nextServerSequence: Int64 = 4,
        lifecycle: CompetitionRemoteLifecycle = .scheduled
    ) throws -> CompetitionDescriptor {
        try CompetitionDescriptor(
            competitionID: competitionID,
            creatorProfileID: creatorID,
            timeZoneIdentifier: "America/Los_Angeles",
            startDay: "2026-08-13",
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            lifecycle: lifecycle,
            invitationExpiresAt: createdAt.addingTimeInterval(48 * 60 * 60),
            bestAvailableDeadline: Date(
                timeIntervalSince1970: 1_787_299_200
            ),
            rematchParentID: nil,
            nextServerSequence: nextServerSequence,
            participants: [
                try CompetitionParticipantDescriptor(
                    profileID: creatorID,
                    role: .creator,
                    state: .accepted,
                    profile: try CompetitionProfilePresentation(
                        id: creatorID,
                        displayName: "Beta Alice"
                    )
                ),
                try CompetitionParticipantDescriptor(
                    profileID: inviteeID,
                    role: .invitee,
                    state: .accepted,
                    profile: try CompetitionProfilePresentation(
                        id: inviteeID,
                        displayName: "Beta Bob"
                    )
                ),
            ]
        )
    }

    private func participantAddedChange(
        sequence: Int64,
        profileID: UUID,
        role: CompetitionParticipantRole,
        occurredAt: Date
    ) throws -> CompetitionChange {
        try CompetitionChange(
            serverSequence: sequence,
            kind: .participantAdded,
            entityID: profileID,
            occurredAt: occurredAt,
            payload: .participant(
                try CompetitionParticipantChange(
                    profileID: profileID,
                    role: role,
                    state: .accepted
                )
            )
        )
    }

    private func scheduledHistoryPage(
        descriptor: CompetitionDescriptor,
        creatorID: UUID,
        inviteeID: UUID,
        createdAt: Date
    ) throws -> CompetitionChangePage {
        let acceptedAt = createdAt.addingTimeInterval(3_600)
        return try CompetitionChangePage(
            competitionID: competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 3,
            nextServerSequence: 3,
            hasMore: false,
            changes: [
                try participantAddedChange(
                    sequence: 1,
                    profileID: creatorID,
                    role: .creator,
                    occurredAt: createdAt
                ),
                try participantAddedChange(
                    sequence: 2,
                    profileID: inviteeID,
                    role: .invitee,
                    occurredAt: acceptedAt
                ),
                try CompetitionChange(
                    serverSequence: 3,
                    kind: .competitionLifecycleChanged,
                    entityID: competitionID,
                    occurredAt: acceptedAt,
                    payload: .lifecycle(
                        try CompetitionLifecycleChange(
                            lifecycle: .scheduled,
                            timeZoneIdentifier: descriptor
                                .timeZoneIdentifier,
                            startDay: descriptor.startDay,
                            bestAvailableDeadline: descriptor
                                .bestAvailableDeadline,
                            scoringPolicyIdentity: descriptor
                                .scoringPolicyIdentity
                        )
                    )
                ),
            ]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeStore(root: URL) -> JSONCompetitionEventStore {
        JSONCompetitionEventStore(
            rootDirectory: root,
            faultInjector: .none,
            fileProtection: JSONCompetitionEventStoreFileProtection {
                _, _ in
            }
        )
    }

    private let profileID = UUID(
        uuidString: "71000000-0000-4000-8000-000000000001"
    )!
    private let competitionID = UUID(
        uuidString: "73000000-0000-4000-8000-000000000001"
    )!
}

private actor RemoteCompetitionRuntimeProbe {
    struct FetchObservation: Equatable, Sendable {
        let cursor: CompetitionSynchronizationCursor
        let pageSize: Int
    }

    private var listCalls = 0
    private var fetches: [FetchObservation] = []
    private var submittedScoreRequests: [CompetitionScoreRevisionRequest] = []
    private var submittedAttestationRequests:
        [CompetitionAttestationRequest] = []

    func recordListCall() {
        listCalls += 1
    }

    func listCallCount() -> Int {
        listCalls
    }

    func recordFetch(
        cursor: CompetitionSynchronizationCursor,
        pageSize: Int
    ) {
        fetches.append(FetchObservation(cursor: cursor, pageSize: pageSize))
    }

    func fetchObservations() -> [FetchObservation] {
        fetches
    }

    func recordScoreRequest(_ request: CompetitionScoreRevisionRequest) {
        submittedScoreRequests.append(request)
    }

    func scoreRequests() -> [CompetitionScoreRevisionRequest] {
        submittedScoreRequests
    }

    func recordAttestationRequest(
        _ request: CompetitionAttestationRequest
    ) {
        submittedAttestationRequests.append(request)
    }

    func attestationRequests() -> [CompetitionAttestationRequest] {
        submittedAttestationRequests
    }
}

private final class RemoteNotificationReplanProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var lifecycles: [CompetitionNotificationLifecycle] = []

    func record(_ lifecycle: CompetitionNotificationLifecycle) {
        lock.withLock { lifecycles.append(lifecycle) }
    }

    func values() -> [CompetitionNotificationLifecycle] {
        lock.withLock { lifecycles }
    }
}

private actor RemoteNotificationConflictStore: CompetitionEventStore {
    private let base: JSONCompetitionEventStore
    private let declinedAt: Date
    private var didInjectConflict = false

    init(base: JSONCompetitionEventStore, declinedAt: Date) {
        self.base = base
        self.declinedAt = declinedAt
    }

    func ids() async throws -> [CompetitionID] {
        try await base.ids()
    }

    func load(_ id: CompetitionID) async throws -> LoadedCompetitionJournal? {
        try await base.load(id)
    }

    func create(
        _ genesis: CompetitionGenesis
    ) async throws -> CompetitionEventStoreCreateResult {
        try await base.create(genesis)
    }

    func append(
        _ events: [CompetitionDomainEvent],
        to id: CompetitionID,
        expectedCursor: CompetitionJournalCursor
    ) async throws -> CompetitionJournalAppendResult {
        if !didInjectConflict,
           events.contains(where: {
               if case .notificationEmissionRecorded = $0 { return true }
               return false
           }) {
            didInjectConflict = true
            guard let loaded = try await base.load(id) else {
                throw CompetitionEventStoreError.identityNotFound
            }
            let decline = try CompetitionEngine().decline(
                loaded.projection.competition,
                at: declinedAt
            )
            _ = try await base.append(
                [.lifecycle(decline)],
                to: id,
                expectedCursor: expectedCursor
            )
        }
        return try await base.append(
            events,
            to: id,
            expectedCursor: expectedCursor
        )
    }

    func delete(
        _ id: CompetitionID,
        expectedCursor: CompetitionJournalCursor
    ) async throws {
        try await base.delete(id, expectedCursor: expectedCursor)
    }
}

private actor TwoClientCompetitionServer {
    private struct AcceptedScore: Sendable {
        let request: CompetitionScoreRevisionRequest
        let participantID: UUID
        let serverSequence: Int64
        let acceptedCentiPoints: Int?
    }

    private let competitionID: UUID
    private let creatorID: UUID
    private let inviteeID: UUID
    private let createdAt: Date
    private let invitationExpiresAt: Date
    private let bestAvailableDeadline: Date
    private var changes: [CompetitionChange]
    private var onlineByProfile: [UUID: Bool]
    private var acceptedBySemanticID: [UUID: AcceptedScore] = [:]

    init(
        competitionID: UUID,
        creatorID: UUID,
        inviteeID: UUID,
        createdAt: Date
    ) throws {
        self.competitionID = competitionID
        self.creatorID = creatorID
        self.inviteeID = inviteeID
        self.createdAt = createdAt
        self.invitationExpiresAt = createdAt.addingTimeInterval(48 * 60 * 60)
        self.bestAvailableDeadline = Date(
            timeIntervalSince1970: 1_787_299_200
        )
        self.onlineByProfile = [creatorID: true, inviteeID: true]
        self.changes = [
            try CompetitionChange(
                serverSequence: 1,
                kind: .participantAdded,
                entityID: creatorID,
                occurredAt: createdAt,
                payload: .participant(
                    try CompetitionParticipantChange(
                        profileID: creatorID,
                        role: .creator,
                        state: .accepted
                    )
                )
            ),
            try CompetitionChange(
                serverSequence: 2,
                kind: .participantAdded,
                entityID: inviteeID,
                occurredAt: createdAt.addingTimeInterval(3_600),
                payload: .participant(
                    try CompetitionParticipantChange(
                        profileID: inviteeID,
                        role: .invitee,
                        state: .accepted
                    )
                )
            ),
            try CompetitionChange(
                serverSequence: 3,
                kind: .competitionLifecycleChanged,
                entityID: competitionID,
                occurredAt: createdAt.addingTimeInterval(3_600),
                payload: .lifecycle(
                    try CompetitionLifecycleChange(
                        lifecycle: .scheduled,
                        timeZoneIdentifier: "America/Los_Angeles",
                        startDay: "2026-08-13",
                        bestAvailableDeadline: Date(
                            timeIntervalSince1970: 1_787_299_200
                        ),
                        scoringPolicyIdentity: RemoteScoringWireV1
                            .policyIdentity
                    )
                )
            ),
        ]
    }

    func setOnline(_ isOnline: Bool, for profileID: UUID) {
        onlineByProfile[profileID] = isOnline
    }

    func listCompetitions(
        for profileID: UUID
    ) throws -> [CompetitionDescriptor] {
        try requireOnlineAndParticipant(profileID)
        return [try descriptor()]
    }

    func fetchChanges(
        for profileID: UUID,
        cursor: CompetitionSynchronizationCursor,
        pageSize: Int
    ) throws -> CompetitionChangePage {
        try requireOnlineAndParticipant(profileID)
        guard cursor.competitionID == competitionID,
              (1...200).contains(pageSize)
        else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        let snapshot = changes.last?.serverSequence ?? 0
        let available = changes.filter {
            $0.serverSequence > cursor.lastSeenServerSequence
        }
        let pageChanges = Array(available.prefix(pageSize))
        let next = pageChanges.last?.serverSequence
            ?? cursor.lastSeenServerSequence
        return try CompetitionChangePage(
            competitionID: competitionID,
            afterServerSequence: cursor.lastSeenServerSequence,
            snapshotServerSequence: snapshot,
            nextServerSequence: next,
            hasMore: next < snapshot,
            changes: pageChanges
        )
    }

    func appendScoreRevision(
        for profileID: UUID,
        request: CompetitionScoreRevisionRequest
    ) throws -> CompetitionScoreRevisionResponse {
        try requireOnlineAndParticipant(profileID)
        guard request.competitionID == competitionID else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        if let existing = acceptedBySemanticID[request.semanticEventID] {
            guard existing.request == request,
                  existing.participantID == profileID
            else {
                throw CompetitionRemoteFailure.divergentDuplicate
            }
            return try CompetitionScoreRevisionResponse(
                disposition: .duplicate,
                rejectionCode: nil,
                acceptedCentiPoints: existing.acceptedCentiPoints,
                wireContentSHA256: request.wireContentSHA256,
                acceptedServerSequence: existing.serverSequence,
                competitionCursor: changes.last?.serverSequence ?? 0
            )
        }
        let acceptedCentiPoints: Int?
        if request.availabilityReason == "available" {
            acceptedCentiPoints = min(
                request.moveBasisPoints!
                    + request.exerciseBasisPoints!
                    + request.standBasisPoints!,
                60_000
            )
        } else {
            acceptedCentiPoints = nil
        }
        let serverSequence = (changes.last?.serverSequence ?? 0) + 1
        let score = try CompetitionScoreChange(
            participantProfileID: profileID,
            dayOrdinal: request.dayOrdinal,
            clientRevision: request.clientRevision,
            moveMode: request.moveMode,
            standMode: request.standMode,
            moveBasisPoints: request.moveBasisPoints,
            exerciseBasisPoints: request.exerciseBasisPoints,
            standBasisPoints: request.standBasisPoints,
            acceptedCentiPoints: acceptedCentiPoints,
            availabilityReason: request.availabilityReason,
            scoringPolicyIdentity: request.scoringPolicyIdentity,
            wireDigestVersion: 1,
            wireContentSHA256: request.wireContentSHA256,
            serverSequence: serverSequence,
            evaluatedAt: request.evaluatedAt
        )
        changes.append(
            try CompetitionChange(
                serverSequence: serverSequence,
                kind: .scoreRevisionRecorded,
                entityID: profileID,
                occurredAt: request.evaluatedAt,
                payload: .score(score)
            )
        )
        acceptedBySemanticID[request.semanticEventID] = AcceptedScore(
            request: request,
            participantID: profileID,
            serverSequence: serverSequence,
            acceptedCentiPoints: acceptedCentiPoints
        )
        return try CompetitionScoreRevisionResponse(
            disposition: .appended,
            rejectionCode: nil,
            acceptedCentiPoints: acceptedCentiPoints,
            wireContentSHA256: request.wireContentSHA256,
            acceptedServerSequence: serverSequence,
            competitionCursor: serverSequence
        )
    }

    func appendedScoreCount() -> Int {
        acceptedBySemanticID.count
    }

    private func descriptor() throws -> CompetitionDescriptor {
        try CompetitionDescriptor(
            competitionID: competitionID,
            creatorProfileID: creatorID,
            timeZoneIdentifier: "America/Los_Angeles",
            startDay: "2026-08-13",
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            lifecycle: .active,
            invitationExpiresAt: invitationExpiresAt,
            bestAvailableDeadline: bestAvailableDeadline,
            rematchParentID: nil,
            nextServerSequence: (changes.last?.serverSequence ?? 0) + 1,
            participants: [
                try CompetitionParticipantDescriptor(
                    profileID: creatorID,
                    role: .creator,
                    state: .accepted,
                    profile: try CompetitionProfilePresentation(
                        id: creatorID,
                        displayName: "Beta Alice"
                    )
                ),
                try CompetitionParticipantDescriptor(
                    profileID: inviteeID,
                    role: .invitee,
                    state: .accepted,
                    profile: try CompetitionProfilePresentation(
                        id: inviteeID,
                        displayName: "Beta Bob"
                    )
                ),
            ]
        )
    }

    private func requireOnlineAndParticipant(_ profileID: UUID) throws {
        guard profileID == creatorID || profileID == inviteeID else {
            throw CompetitionRemoteFailure.forbidden
        }
        guard onlineByProfile[profileID] == true else {
            throw CompetitionRemoteFailure.retryableTransport
        }
    }
}

private extension CompetitionFrozenDay {
    func domainValueForTest() throws -> RemoteFinalizationDayV1 {
        try RemoteFinalizationDayV1(
            ordinal: ordinal,
            status: status == .points ? .points : .unavailable,
            source: source == .acceptedRevision
                ? .acceptedRevision
                : .deadlineMissing,
            points: centiPoints,
            reason: reason,
            wireContentSHA256: wireContentSHA256,
            clientRevision: clientRevision,
            serverSequence: serverSequence
        )
    }
}
