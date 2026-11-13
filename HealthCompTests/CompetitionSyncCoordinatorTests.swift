import CompetitionCore
import Foundation
import XCTest

@testable import HealthComp

final class CompetitionSyncCoordinatorTests: XCTestCase {
    func testDeletingAMatchCancelsItsUploadAndContinuesOtherMatches()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(rootDirectory: root, fileProtection: .testNoop)
        let removed = try scoreRequest()
        let retained = try scoreRequest(
            semanticEventID: UUID(uuidString: "64000000-0000-4000-8000-000000000002")!,
            competitionID: UUID(uuidString: "63000000-0000-4000-8000-000000000002")!
        )
        let now = Date(timeIntervalSince1970: 1_786_536_010)
        _ = try await store.enqueue(.scoreRevision(removed), enqueuedAt: now)
        _ = try await store.enqueue(.scoreRevision(retained), enqueuedAt: now)
        let probe = CompetitionSyncCoordinatorProbe()
        let accepted = try scoreResponse(for: retained)
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID, outboxStore: store,
            remoteAPI: remoteAPI(appendScoreRevision: { request in
                await probe.recordRemoteCall(request: request, durableEntries: try await store.entries())
                if request.competitionID == removed.competitionID {
                    try await Task.sleep(for: .seconds(3_600))
                }
                return accepted
            }),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence { _, _, _, _ in },
            now: { now }
        )
        await coordinator.wake()
        await probe.waitForRemoteCallCount(1)
        try await coordinator.discardQueuedEntries(for: removed.competitionID)
        await coordinator.waitUntilIdle()
        let remaining = try await store.entries()
        XCTAssertEqual(remaining, [])
        let calls = await probe.remoteCallCount()
        XCTAssertEqual(calls, 2)
        do {
            _ = try await coordinator.enqueue(.scoreRevision(removed), enqueuedAt: now)
            XCTFail("A deleted match must not be queued again")
        } catch {
            XCTAssertEqual(error as? CompetitionRemoteFailure, .notFound)
        }
        await coordinator.stop()
    }

    func testEnqueueCommitsPayloadBeforeFirstRemoteCall() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let response = try scoreResponse(for: request)
        let probe = CompetitionSyncCoordinatorProbe()
        let receivedAt = Date(timeIntervalSince1970: 1_786_536_010)
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    return response
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { receivedAt }
        )

        let entry = try await coordinator.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await coordinator.waitUntilIdle()

        let observation = await probe.remoteObservation()
        XCTAssertEqual(observation?.request, request)
        XCTAssertEqual(observation?.durableEntries, [entry])
    }

    func testRelaunchReplaysDurableScoreAcceptanceWithoutResending()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let response = try scoreResponse(for: request)
        let probe = CompetitionSyncCoordinatorProbe()
        let receivedAt = Date(timeIntervalSince1970: 1_786_536_010)
        let first = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    return response
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, submitted, accepted, persistedAt in
                await probe.recordPersistenceCall(
                    request: submitted,
                    response: accepted,
                    receivedAt: persistedAt,
                    durableEntries: try await store.entries()
                )
                throw CoordinatorFixtureFailure.injectedCrash
            },
            now: { receivedAt }
        )

        _ = try await first.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await first.waitUntilIdle()

        let durableEntries = try await store.entries()
        let durableAcceptance = try XCTUnwrap(durableEntries.only)
        XCTAssertEqual(
            durableAcceptance.state,
            .scoreAccepted(response, receivedAt: receivedAt)
        )
        let firstRemoteCallCount = await probe.remoteCallCount()
        let firstPersistenceObservations = await probe
            .persistenceObservations()
        XCTAssertEqual(firstRemoteCallCount, 1)
        XCTAssertEqual(
            firstPersistenceObservations.map(\.durableEntries),
            [[durableAcceptance]]
        )

        let relaunched = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: JSONCompetitionOutboxStore(
                rootDirectory: root,
                fileProtection: .testNoop
            ),
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    return response
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, submitted, accepted, persistedAt in
                await probe.recordPersistenceCall(
                    request: submitted,
                    response: accepted,
                    receivedAt: persistedAt,
                    durableEntries: try await store.entries()
                )
            },
            now: { Date(timeIntervalSince1970: 1_786_536_999) }
        )

        await relaunched.wake()
        await relaunched.waitUntilIdle()

        let finalRemoteCallCount = await probe.remoteCallCount()
        let finalPersistenceObservations = await probe
            .persistenceObservations()
        let finalEntries = try await store.entries()
        XCTAssertEqual(finalRemoteCallCount, 1)
        XCTAssertEqual(finalPersistenceObservations.count, 2)
        XCTAssertEqual(finalEntries, [])
    }

    func testRelaunchAfterCoreAppendBeforeOutboxRemovalIsIdempotent()
        async throws
    {
        let outboxRoot = makeTemporaryDirectory()
        let eventRoot = makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: outboxRoot)
            try? FileManager.default.removeItem(at: eventRoot)
        }
        let durableOutbox = JSONCompetitionOutboxStore(
            rootDirectory: outboxRoot,
            fileProtection: .testNoop
        )
        let failingOutbox = RemoveFailingOutboxStore(
            base: durableOutbox
        )
        let eventStore = JSONCompetitionEventStore(
            rootDirectory: eventRoot,
            faultInjector: .none,
            fileProtection: .testNoop
        )
        let competitionID = CompetitionID(self.competitionID)
        let genesis = try CompetitionGenesis(
            competitionID: competitionID,
            direction: .outgoing,
            createdAt: Date(timeIntervalSince1970: 1_786_000_000),
            expiresAt: nil,
            scoringPolicy: .appleCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
        let created = try await eventStore.create(genesis)
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let startDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 10,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let days = try calendar.sevenDayWindow(startingOn: startDay)
        let dayAfterWindow = try calendar.day(
            after: try XCTUnwrap(days.last)
        )
        let configuration = try RemoteCompetitionConfiguration(
            competitionID: competitionID,
            owner: try RemoteParticipant(profileID: profileID),
            remote: try RemoteParticipant(
                profileID: UUID(
                    uuidString: "62000000-0000-4000-8000-000000000001"
                )!
            ),
            acceptedSchedule: CompetitionSchedule(
                calendar: calendar,
                startDay: startDay
            ),
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            backendDescriptorRevision: 1,
            bestAvailableDeadline: try calendar.startOfDay(dayAfterWindow)
                .addingTimeInterval(3_600)
        )
        _ = try await eventStore.append(
            [.remoteConfigurationAccepted(configuration)],
            to: competitionID,
            expectedCursor: created.cursor
        )
        let request = try scoreRequest()
        let response = try scoreResponse(for: request)
        let probe = CompetitionSyncCoordinatorProbe()
        let receivedAt = Date(timeIntervalSince1970: 1_786_536_010)
        let remote = remoteAPI(
            appendScoreRevision: { submitted in
                await probe.recordRemoteCall(
                    request: submitted,
                    durableEntries: try await durableOutbox.entries()
                )
                return response
            }
        )
        let persistence = CompetitionAcceptedScorePersistence.eventStore(
            eventStore
        )
        let first = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: failingOutbox,
            remoteAPI: remote,
            acceptedScorePersistence: persistence,
            now: { receivedAt }
        )

        _ = try await first.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await first.waitUntilIdle()

        let afterCrash = try await durableOutbox.entries()
        XCTAssertEqual(
            afterCrash.only?.state,
            .scoreAccepted(response, receivedAt: receivedAt)
        )
        let afterFirstAppendValue = try await eventStore.load(competitionID)
        let afterFirstAppend = try XCTUnwrap(afterFirstAppendValue)
        XCTAssertEqual(afterFirstAppend.journal.envelopes.count, 3)

        let relaunched = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: JSONCompetitionOutboxStore(
                rootDirectory: outboxRoot,
                fileProtection: .testNoop
            ),
            remoteAPI: remote,
            acceptedScorePersistence: persistence,
            now: { Date(timeIntervalSince1970: 1_786_536_999) }
        )
        await relaunched.wake()
        await relaunched.waitUntilIdle()

        let remoteCallCount = await probe.remoteCallCount()
        let finalEntries = try await durableOutbox.entries()
        let finalLoadedValue = try await eventStore.load(competitionID)
        let finalLoaded = try XCTUnwrap(finalLoadedValue)
        XCTAssertEqual(remoteCallCount, 1)
        XCTAssertEqual(finalEntries, [])
        XCTAssertEqual(finalLoaded.journal.envelopes.count, 3)
        XCTAssertEqual(finalLoaded.journal.cursor, afterFirstAppend.journal.cursor)
    }

    func testRetryableFailurePersistsBackoffWithoutImmediateSpin()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let probe = CompetitionSyncCoordinatorProbe()
        let failedAt = Date(timeIntervalSince1970: 1_786_536_010)
        // A frozen clock with the real sleeper would fire at once and spin.
        let sleeper = CoordinatorRetrySleeper()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    throw CompetitionRemoteFailure.retryableTransport
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { failedAt },
            sleepUntil: { deadline in
                await sleeper.sleep(until: deadline)
            }
        )

        _ = try await coordinator.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await coordinator.waitUntilIdle()
        await coordinator.wake()
        await coordinator.waitUntilIdle()
        await sleeper.waitForSleepCount(1)

        let attempts = await probe.remoteCallCount()
        let durable = try await store.entries()
        let deadlines = await sleeper.deadlines()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(deadlines, [failedAt.addingTimeInterval(1)])
        XCTAssertEqual(
            durable.only?.state,
            .pending(
                attemptCount: 1,
                retryAt: failedAt.addingTimeInterval(1)
            )
        )
        await coordinator.stop()
    }

    func testRetryableFailuresUseBoundedExponentialBackoff()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let clock = CoordinatorDateBox(
            Date(timeIntervalSince1970: 1_786_536_010)
        )
        let probe = CompetitionSyncCoordinatorProbe()
        // A frozen clock with the real sleeper would fire at once and spin.
        let sleeper = CoordinatorRetrySleeper()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    throw CompetitionRemoteFailure.retryableTransport
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { clock.value },
            sleepUntil: { deadline in
                await sleeper.sleep(until: deadline)
            }
        )

        _ = try await coordinator.enqueue(
            .scoreRevision(try scoreRequest()),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await coordinator.waitUntilIdle()

        let expectedDelays: [TimeInterval] = [
            1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 900, 900,
        ]
        for (offset, delay) in expectedDelays.enumerated() {
            let entries = try await store.entries()
            let durable = try XCTUnwrap(entries.only)
            guard case let .pending(attemptCount, retryAt) = durable.state
            else {
                return XCTFail("Expected pending retry state")
            }
            XCTAssertEqual(attemptCount, offset + 1)
            XCTAssertEqual(
                retryAt,
                clock.value.addingTimeInterval(delay)
            )
            guard offset < expectedDelays.count - 1 else { continue }
            clock.value = try XCTUnwrap(retryAt)
            await coordinator.wake()
            await coordinator.waitUntilIdle()
        }

        await sleeper.waitForSleepCount(expectedDelays.count)
        let attempts = await probe.remoteCallCount()
        let deadlines = await sleeper.deadlines()
        XCTAssertEqual(attempts, expectedDelays.count)
        // One timer per attempt: a respin would add more.
        XCTAssertEqual(deadlines.count, expectedDelays.count)
        await coordinator.stop()
    }

    func testRetryAttemptOverflowBecomesInspectableInsteadOfCrashing()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let connectivity = CoordinatorBoolBox(false)
        let probe = CompetitionSyncCoordinatorProbe()
        let failedAt = Date(timeIntervalSince1970: 1_786_536_010)
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    throw CompetitionRemoteFailure.retryableTransport
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            isOnline: { connectivity.value },
            now: { failedAt }
        )

        let entry = try await coordinator.enqueue(
            .scoreRevision(try scoreRequest()),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await coordinator.waitUntilIdle()
        _ = try await store.update(
            entry.semanticEventID,
            expectedGeneration: entry.generation,
            state: .pending(attemptCount: Int.max, retryAt: nil)
        )

        connectivity.value = true
        await coordinator.wake()
        await coordinator.waitUntilIdle()

        let attempts = await probe.remoteCallCount()
        let durable = try await store.entries()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(
            durable.only?.state,
            .permanentFailure(.operationFailed, failedAt: failedAt)
        )
    }

    func testRetryableFailureSchedulesOneAutomaticRetryAtRetryDate()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let response = try scoreResponse(for: request)
        let clock = CoordinatorDateBox(
            Date(timeIntervalSince1970: 1_786_536_010)
        )
        let sleeper = CoordinatorRetrySleeper()
        let probe = CompetitionSyncCoordinatorProbe()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    if await probe.remoteCallCount() == 1 {
                        throw CompetitionRemoteFailure.retryableTransport
                    }
                    return response
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { clock.value },
            sleepUntil: { deadline in
                await sleeper.sleep(until: deadline)
            }
        )

        _ = try await coordinator.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await coordinator.waitUntilIdle()
        await sleeper.waitForSleepCount(1)

        let recordedDeadlines = await sleeper.deadlines()
        let scheduled = try XCTUnwrap(recordedDeadlines.only)
        XCTAssertEqual(scheduled, clock.value.addingTimeInterval(1))
        clock.value = scheduled
        await sleeper.releaseFirst()
        await probe.waitForRemoteCallCount(2)
        await coordinator.waitUntilIdle()

        let attempts = await probe.remoteCallCount()
        let durable = try await store.entries()
        let finalDeadlines = await sleeper.deadlines()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(durable, [])
        XCTAssertEqual(finalDeadlines, [scheduled])
    }

    func testLaterPersistenceFailurePreservesEarlierRetrySchedule()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let requestedAt = Date(timeIntervalSince1970: 1_786_536_010)
        let retryAt = requestedAt.addingTimeInterval(60)
        let futureRequest = try scoreRequest()
        let futureEntry = try await store.enqueue(
            .scoreRevision(futureRequest),
            enqueuedAt: requestedAt.addingTimeInterval(-2)
        )
        _ = try await store.update(
            futureEntry.semanticEventID,
            expectedGeneration: futureEntry.generation,
            state: .pending(attemptCount: 1, retryAt: retryAt)
        )
        let acceptedRequest = try scoreRequest(
            semanticEventID: UUID(
                uuidString: "64000000-0000-4000-8000-000000000002"
            )!,
            clientRevision: 2,
            wireContentSHA256: String(repeating: "b", count: 64)
        )
        let acceptedResponse = try scoreResponse(for: acceptedRequest)
        let pendingAcceptance = try await store.enqueue(
            .scoreRevision(acceptedRequest),
            enqueuedAt: requestedAt.addingTimeInterval(-1)
        )
        _ = try await store.update(
            pendingAcceptance.semanticEventID,
            expectedGeneration: pendingAcceptance.generation,
            state: .scoreAccepted(
                acceptedResponse,
                receivedAt: requestedAt
            )
        )
        let scheduled = CoordinatorDatesBox()
        let scheduleExpectation = expectation(
            description: "preserved retry deadline scheduled"
        )
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { _ in
                    throw CompetitionRemoteFailure.operationFailed
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
                throw CoordinatorFixtureFailure.injectedCrash
            },
            now: { requestedAt },
            sleepUntil: { deadline in
                scheduled.append(deadline)
                scheduleExpectation.fulfill()
                throw CancellationError()
            }
        )

        await coordinator.wake()
        await coordinator.waitUntilIdle()
        await fulfillment(of: [scheduleExpectation], timeout: 2)

        XCTAssertEqual(scheduled.values, [retryAt])
    }

    func testOfflineSuspendsPendingItemUntilConnectivityWake()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let response = try scoreResponse(for: request)
        let connectivity = CoordinatorBoolBox(false)
        let probe = CompetitionSyncCoordinatorProbe()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    return response
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            isOnline: { connectivity.value },
            now: { Date(timeIntervalSince1970: 1_786_536_010) }
        )

        let entry = try await coordinator.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await coordinator.waitUntilIdle()

        let offlineAttempts = await probe.remoteCallCount()
        let offlineEntries = try await store.entries()
        XCTAssertEqual(offlineAttempts, 0)
        XCTAssertEqual(offlineEntries, [entry])

        connectivity.value = true
        await coordinator.wake()
        await coordinator.waitUntilIdle()

        let onlineAttempts = await probe.remoteCallCount()
        let onlineEntries = try await store.entries()
        XCTAssertEqual(onlineAttempts, 1)
        XCTAssertEqual(onlineEntries, [])
    }

    func testConcurrentWakeupsCoalesceIntoOneSerializedDrain()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let response = try scoreResponse(for: request)
        let gate = CoordinatorRemoteGate()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { _ in
                    await gate.enter()
                    return response
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { Date(timeIntervalSince1970: 1_786_536_010) }
        )

        _ = try await coordinator.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await gate.waitForCallCount(1)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await coordinator.wake()
                }
            }
        }
        await gate.open()
        await coordinator.waitUntilIdle()

        let observation = await gate.observation()
        let durable = try await store.entries()
        XCTAssertEqual(observation.callCount, 1)
        XCTAssertEqual(observation.maximumInFlight, 1)
        XCTAssertEqual(durable, [])
    }

    func testAttestationAcknowledgmentRemainsDurableWithoutCoreFabrication()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try attestationRequest()
        let receipt = try CompetitionAttestationReceipt(
            disposition: .appended,
            windowCommitmentSHA256: request.windowCommitmentSHA256,
            entityServerSequence: 9
        )
        let probe = CompetitionSyncCoordinatorProbe()
        let receivedAt = Date(timeIntervalSince1970: 1_786_536_010)
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { _ in
                    throw CompetitionRemoteFailure.operationFailed
                },
                submitAttestation: { submitted in
                    await probe.recordAttestationCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    return receipt
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, submitted, accepted, persistedAt in
                await probe.recordPersistenceCall(
                    request: submitted,
                    response: accepted,
                    receivedAt: persistedAt,
                    durableEntries: try await store.entries()
                )
            },
            now: { receivedAt }
        )

        let pending = try await coordinator.enqueue(
            .finalWindowAttestation(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await coordinator.waitUntilIdle()
        await coordinator.wake()
        await coordinator.waitUntilIdle()

        let attestationObservations = await probe.attestationObservations()
        let persistenceObservations = await probe.persistenceObservations()
        let durable = try await store.entries()
        XCTAssertEqual(
            attestationObservations.map(\.durableEntries),
            [[pending]]
        )
        XCTAssertEqual(persistenceObservations, [])
        XCTAssertEqual(
            durable.only?.state,
            .attestationAcknowledged(receipt, receivedAt: receivedAt)
        )
        XCTAssertEqual(durable.only?.generation, pending.generation + 1)
    }

    func testPermanentRemoteFailuresRemainInspectableWithoutSpinning()
        async throws
    {
        let cases: [(CompetitionRemoteFailure, CompetitionOutboxPermanentFailure)] = [
            (.unauthenticated, .unauthenticated),
            (.forbidden, .forbidden),
            (.notFound, .notFound),
            (.inviteUnavailable, .inviteUnavailable),
            (.divergentDuplicate, .divergentDuplicate),
            (.staleRevision, .staleRevision),
            (.finalizedCompetition, .finalizedCompetition),
            (.incompatiblePolicy, .incompatiblePolicy),
            (.serverContractMismatch, .serverContractMismatch),
            (.accountDeletionUnavailable, .accountDeletionUnavailable),
            (.appAttestUnavailable, .appAttestUnavailable),
            (.appAttestRejected, .appAttestRejectedTerminal),
            (.appAttestContextUnavailable, .appAttestRejectedTerminal),
            (.appAttestProofConflict, .appAttestRejectedTerminal),
            (.operationFailed, .operationFailed),
        ]
        let failedAt = Date(timeIntervalSince1970: 1_786_536_010)

        for (remoteFailure, expectedFailure) in cases {
            let root = makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = JSONCompetitionOutboxStore(
                rootDirectory: root,
                fileProtection: .testNoop
            )
            let probe = CompetitionSyncCoordinatorProbe()
            let coordinator = CompetitionSyncCoordinator(
                profileID: profileID,
                outboxStore: store,
                remoteAPI: remoteAPI(
                    appendScoreRevision: { submitted in
                        await probe.recordRemoteCall(
                            request: submitted,
                            durableEntries: try await store.entries()
                        )
                        throw remoteFailure
                    }
                ),
                acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                    _, _, _, _ in
                },
                now: { failedAt }
            )

            _ = try await coordinator.enqueue(
                .scoreRevision(try scoreRequest()),
                enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
            )
            await coordinator.waitUntilIdle()
            await coordinator.wake()
            await coordinator.waitUntilIdle()

            let attempts = await probe.remoteCallCount()
            let durable = try await store.entries()
            XCTAssertEqual(attempts, 1, "\(remoteFailure)")
            XCTAssertEqual(
                durable.only?.state,
                .permanentFailure(expectedFailure, failedAt: failedAt),
                "\(remoteFailure)"
            )
        }
    }

    func testRelaunchRetriesPriorAppAttestUnavailableScoreOnce()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let response = try scoreResponse(for: request)
        let failedAt = Date(timeIntervalSince1970: 1_786_536_010)
        let pending = try await store.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        _ = try await store.update(
            pending.semanticEventID,
            expectedGeneration: pending.generation,
            state: .permanentFailure(
                .appAttestUnavailable,
                failedAt: failedAt
            )
        )
        let probe = CompetitionSyncCoordinatorProbe()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    return response
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, submitted, accepted, persistedAt in
                await probe.recordPersistenceCall(
                    request: submitted,
                    response: accepted,
                    receivedAt: persistedAt,
                    durableEntries: try await store.entries()
                )
            },
            now: { Date(timeIntervalSince1970: 1_786_536_020) }
        )

        await coordinator.wake()
        await coordinator.waitUntilIdle()

        let attempts = await probe.remoteCallCount()
        let persistence = await probe.persistenceObservations()
        let durable = try await store.entries()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(persistence.count, 1)
        XCTAssertEqual(durable, [])
    }

    func testRelaunchRetriesLegacyAppAttestRejectedScoreOnce()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let response = try scoreResponse(for: request)
        let failedAt = Date(timeIntervalSince1970: 1_786_536_010)
        let pending = try await store.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        _ = try await store.update(
            pending.semanticEventID,
            expectedGeneration: pending.generation,
            state: .permanentFailure(
                .appAttestRejected,
                failedAt: failedAt
            )
        )
        let probe = CompetitionSyncCoordinatorProbe()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    return response
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, submitted, accepted, persistedAt in
                await probe.recordPersistenceCall(
                    request: submitted,
                    response: accepted,
                    receivedAt: persistedAt,
                    durableEntries: try await store.entries()
                )
            },
            now: { Date(timeIntervalSince1970: 1_786_536_020) }
        )

        await coordinator.wake()
        await coordinator.waitUntilIdle()

        let attempts = await probe.remoteCallCount()
        let persistence = await probe.persistenceObservations()
        let durable = try await store.entries()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(persistence.count, 1)
        XCTAssertEqual(durable, [])
    }

    func testLegacyAppAttestRejectionRecoversOnlyOnceAcrossRelaunches()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let legacyFailureAt = Date(timeIntervalSince1970: 1_786_536_010)
        let recoveryFailureAt = Date(timeIntervalSince1970: 1_786_536_020)
        let secondLaunchAt = Date(timeIntervalSince1970: 1_786_536_030)
        let pending = try await store.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        _ = try await store.update(
            pending.semanticEventID,
            expectedGeneration: pending.generation,
            state: .permanentFailure(
                .appAttestRejected,
                failedAt: legacyFailureAt
            )
        )
        let probe = CompetitionSyncCoordinatorProbe()
        let first = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    throw CompetitionRemoteFailure.appAttestRejected
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { recoveryFailureAt }
        )

        await first.wake()
        await first.waitUntilIdle()
        await first.stop()

        let relaunched = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: JSONCompetitionOutboxStore(
                rootDirectory: root,
                fileProtection: .testNoop
            ),
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    throw CompetitionRemoteFailure.appAttestRejected
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { secondLaunchAt }
        )

        await relaunched.wake()
        await relaunched.waitUntilIdle()

        let attempts = await probe.remoteCallCount()
        let durable = try await store.entries()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(
            durable.only?.state,
            .permanentFailure(
                .appAttestRejectedTerminal,
                failedAt: recoveryFailureAt
            )
        )
    }

    func testLegacyAppAttestRejectionUnavailableRecoveryStaysTerminalAcrossRelaunches()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let legacyFailureAt = Date(timeIntervalSince1970: 1_786_536_010)
        let recoveryFailureAt = Date(timeIntervalSince1970: 1_786_536_020)
        let secondLaunchAt = Date(timeIntervalSince1970: 1_786_536_030)
        let pending = try await store.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        _ = try await store.update(
            pending.semanticEventID,
            expectedGeneration: pending.generation,
            state: .permanentFailure(
                .appAttestRejected,
                failedAt: legacyFailureAt
            )
        )
        let probe = CompetitionSyncCoordinatorProbe()
        let first = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    throw CompetitionRemoteFailure.appAttestUnavailable
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { recoveryFailureAt }
        )

        await first.wake()
        await first.waitUntilIdle()
        await first.stop()

        let relaunched = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: JSONCompetitionOutboxStore(
                rootDirectory: root,
                fileProtection: .testNoop
            ),
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    throw CompetitionRemoteFailure.appAttestUnavailable
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { secondLaunchAt }
        )

        await relaunched.wake()
        await relaunched.waitUntilIdle()

        let attempts = await probe.remoteCallCount()
        let durable = try await store.entries()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(
            durable.only?.state,
            .permanentFailure(
                .appAttestRejectedTerminal,
                failedAt: recoveryFailureAt
            )
        )
    }

    func testLegacyAppAttestRejectionRecoveryPreservesProvenanceThroughTransportRetry()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let legacyFailureAt = Date(timeIntervalSince1970: 1_786_536_010)
        let transportFailureAt = Date(timeIntervalSince1970: 1_786_536_020)
        let retryAt = transportFailureAt.addingTimeInterval(1)
        let pending = try await store.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        _ = try await store.update(
            pending.semanticEventID,
            expectedGeneration: pending.generation,
            state: .permanentFailure(
                .appAttestRejected,
                failedAt: legacyFailureAt
            )
        )
        let probe = CompetitionSyncCoordinatorProbe()
        let first = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    throw CompetitionRemoteFailure.retryableTransport
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { transportFailureAt },
            sleepUntil: { _ in throw CancellationError() }
        )

        await first.wake()
        await first.waitUntilIdle()
        await first.stop()

        let afterTransportFailure = try await store.entries()
        XCTAssertEqual(
            afterTransportFailure.only?.state,
            .appAttestRejectionRecovery(
                attemptCount: 1,
                retryAt: retryAt
            )
        )

        let relaunched = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: JSONCompetitionOutboxStore(
                rootDirectory: root,
                fileProtection: .testNoop
            ),
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    throw CompetitionRemoteFailure.appAttestUnavailable
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { retryAt }
        )

        await relaunched.wake()
        await relaunched.waitUntilIdle()

        let attempts = await probe.remoteCallCount()
        let durable = try await store.entries()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(
            durable.only?.state,
            .permanentFailure(
                .appAttestRejectedTerminal,
                failedAt: retryAt
            )
        )
    }

    func testRelaunchRecoveryDoesNotSpinIfAppAttestStaysUnavailable()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let firstFailureAt = Date(timeIntervalSince1970: 1_786_536_010)
        let retryFailureAt = Date(timeIntervalSince1970: 1_786_536_020)
        let pending = try await store.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        _ = try await store.update(
            pending.semanticEventID,
            expectedGeneration: pending.generation,
            state: .permanentFailure(
                .appAttestUnavailable,
                failedAt: firstFailureAt
            )
        )
        let probe = CompetitionSyncCoordinatorProbe()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    throw CompetitionRemoteFailure.appAttestUnavailable
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { retryFailureAt }
        )

        await coordinator.wake()
        await coordinator.waitUntilIdle()
        await coordinator.wake()
        await coordinator.waitUntilIdle()

        let attempts = await probe.remoteCallCount()
        let durable = try await store.entries()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(durable.count, 1)
        XCTAssertEqual(
            durable.first?.state,
            .permanentFailure(
                .appAttestUnavailable,
                failedAt: retryFailureAt
            )
        )
    }

    func testRelaunchRecoverySurvivesEarlierPersistenceFailure()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let acceptedRequest = try scoreRequest()
        let acceptedResponse = try scoreResponse(for: acceptedRequest)
        let accepted = try await store.enqueue(
            .scoreRevision(acceptedRequest),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        _ = try await store.update(
            accepted.semanticEventID,
            expectedGeneration: accepted.generation,
            state: .scoreAccepted(
                acceptedResponse,
                receivedAt: Date(timeIntervalSince1970: 1_786_536_005)
            )
        )
        let legacyRequest = try scoreRequest(
            semanticEventID: UUID(
                uuidString: "64000000-0000-4000-8000-000000000002"
            )!,
            clientRevision: 2,
            wireContentSHA256: String(repeating: "b", count: 64)
        )
        let legacyResponse = try scoreResponse(for: legacyRequest)
        let legacy = try await store.enqueue(
            .scoreRevision(legacyRequest),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_002)
        )
        _ = try await store.update(
            legacy.semanticEventID,
            expectedGeneration: legacy.generation,
            state: .permanentFailure(
                .appAttestUnavailable,
                failedAt: Date(timeIntervalSince1970: 1_786_536_010)
            )
        )
        let persistence = FailOnceAcceptedScorePersistenceProbe()
        let remote = CompetitionSyncCoordinatorProbe()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await remote.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    return legacyResponse
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
                try await persistence.persist()
            },
            now: { Date(timeIntervalSince1970: 1_786_536_020) }
        )

        await coordinator.wake()
        await coordinator.waitUntilIdle()
        await coordinator.wake()
        await coordinator.waitUntilIdle()

        let remoteCalls = await remote.remoteCallCount()
        let persistenceCalls = await persistence.callCount()
        let durable = try await store.entries()
        XCTAssertEqual(remoteCalls, 1)
        XCTAssertEqual(persistenceCalls, 3)
        XCTAssertEqual(durable, [])
    }

    func testUnexpectedRemoteFailureBecomesInspectableWithoutSpinning()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let probe = CompetitionSyncCoordinatorProbe()
        let failedAt = Date(timeIntervalSince1970: 1_786_536_010)
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    throw CoordinatorFixtureFailure.unexpectedRemote
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { failedAt }
        )

        _ = try await coordinator.enqueue(
            .scoreRevision(try scoreRequest()),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await coordinator.waitUntilIdle()
        await coordinator.wake()
        await coordinator.waitUntilIdle()

        let attempts = await probe.remoteCallCount()
        let durable = try await store.entries()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(
            durable.only?.state,
            .permanentFailure(.operationFailed, failedAt: failedAt)
        )
    }

    func testRejectedScoreResponsesBecomeInspectableReconciliationFailures()
        async throws
    {
        let cases: [(
            CompetitionScoreRevisionRejectionCode,
            CompetitionOutboxPermanentFailure
        )] = [
            (.divergentDuplicate, .divergentDuplicate),
            (.revisionRegression, .staleRevision),
            (.windowStable, .finalizedCompetition),
            (.competitionTerminal, .finalizedCompetition),
            (.competitionFinalized, .finalizedCompetition),
        ]
        let failedAt = Date(timeIntervalSince1970: 1_786_536_010)

        for (rejectionCode, expectedFailure) in cases {
            let root = makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = JSONCompetitionOutboxStore(
                rootDirectory: root,
                fileProtection: .testNoop
            )
            let request = try scoreRequest()
            let response = try CompetitionScoreRevisionResponse(
                disposition: .rejected,
                rejectionCode: rejectionCode,
                acceptedCentiPoints: 27_500,
                wireContentSHA256: request.wireContentSHA256,
                acceptedServerSequence: 1,
                competitionCursor: 3
            )
            let probe = CompetitionSyncCoordinatorProbe()
            let coordinator = CompetitionSyncCoordinator(
                profileID: profileID,
                outboxStore: store,
                remoteAPI: remoteAPI(
                    appendScoreRevision: { submitted in
                        await probe.recordRemoteCall(
                            request: submitted,
                            durableEntries: try await store.entries()
                        )
                        return response
                    }
                ),
                acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                    _, submitted, accepted, persistedAt in
                    await probe.recordPersistenceCall(
                        request: submitted,
                        response: accepted,
                        receivedAt: persistedAt,
                        durableEntries: try await store.entries()
                    )
                },
                now: { failedAt }
            )

            _ = try await coordinator.enqueue(
                .scoreRevision(request),
                enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
            )
            await coordinator.waitUntilIdle()
            await coordinator.wake()
            await coordinator.waitUntilIdle()

            let attempts = await probe.remoteCallCount()
            let persistence = await probe.persistenceObservations()
            let durable = try await store.entries()
            XCTAssertEqual(attempts, 1, rejectionCode.rawValue)
            XCTAssertEqual(persistence, [], rejectionCode.rawValue)
            XCTAssertEqual(
                durable.only?.state,
                .permanentFailure(expectedFailure, failedAt: failedAt),
                rejectionCode.rawValue
            )
        }
    }

    func testRetryableAttestationFailurePersistsBackoffWithoutSpin()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let failedAt = Date(timeIntervalSince1970: 1_786_536_010)
        let probe = CompetitionSyncCoordinatorProbe()
        // A frozen clock with the real sleeper would fire at once and spin.
        let sleeper = CoordinatorRetrySleeper()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { _ in
                    throw CompetitionRemoteFailure.operationFailed
                },
                submitAttestation: { submitted in
                    await probe.recordAttestationCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    throw CompetitionRemoteFailure.retryableTransport
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { failedAt },
            sleepUntil: { deadline in
                await sleeper.sleep(until: deadline)
            }
        )

        _ = try await coordinator.enqueue(
            .finalWindowAttestation(try attestationRequest()),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await coordinator.waitUntilIdle()
        await coordinator.wake()
        await coordinator.waitUntilIdle()
        await sleeper.waitForSleepCount(1)

        let attempts = await probe.attestationObservations().count
        let durable = try await store.entries()
        let deadlines = await sleeper.deadlines()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(deadlines, [failedAt.addingTimeInterval(1)])
        XCTAssertEqual(
            durable.only?.state,
            .pending(
                attemptCount: 1,
                retryAt: failedAt.addingTimeInterval(1)
            )
        )
        await coordinator.stop()
    }

    func testPermanentAttestationFailureRemainsInspectableWithoutSpin()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let failedAt = Date(timeIntervalSince1970: 1_786_536_010)
        let probe = CompetitionSyncCoordinatorProbe()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { _ in
                    throw CompetitionRemoteFailure.operationFailed
                },
                submitAttestation: { submitted in
                    await probe.recordAttestationCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    throw CompetitionRemoteFailure.forbidden
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, _, _, _ in
            },
            now: { failedAt }
        )

        _ = try await coordinator.enqueue(
            .finalWindowAttestation(try attestationRequest()),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await coordinator.waitUntilIdle()
        await coordinator.wake()
        await coordinator.waitUntilIdle()

        let attempts = await probe.attestationObservations().count
        let durable = try await store.entries()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(
            durable.only?.state,
            .permanentFailure(.forbidden, failedAt: failedAt)
        )
    }

    func testStopCancelsDrainAndRejectsFurtherWorkBeforeProfileTeardown()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let probe = CompetitionSyncCoordinatorProbe()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(
                appendScoreRevision: { submitted in
                    await probe.recordRemoteCall(
                        request: submitted,
                        durableEntries: try await store.entries()
                    )
                    try await Task.sleep(for: .seconds(3_600))
                    throw CompetitionRemoteFailure.operationFailed
                }
            ),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, submitted, accepted, persistedAt in
                await probe.recordPersistenceCall(
                    request: submitted,
                    response: accepted,
                    receivedAt: persistedAt,
                    durableEntries: try await store.entries()
                )
            },
            now: { Date(timeIntervalSince1970: 1_786_536_010) }
        )

        let pending = try await coordinator.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        await probe.waitForRemoteCallCount(1)

        await coordinator.stop()
        await coordinator.wake()
        await coordinator.waitUntilIdle()

        do {
            _ = try await coordinator.enqueue(
                .scoreRevision(request),
                enqueuedAt: Date(timeIntervalSince1970: 1_786_536_999)
            )
            XCTFail("Expected stopped coordinator failure")
        } catch {
            XCTAssertEqual(
                error as? CompetitionSyncCoordinatorFailure,
                .stopped
            )
        }

        let attempts = await probe.remoteCallCount()
        let persistence = await probe.persistenceObservations()
        let durable = try await store.entries()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(persistence, [])
        XCTAssertEqual(durable, [pending])
    }

    func testEventStorePersistenceAtomicallyAppendsAcceptedScoreAndReceipt()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let eventStore = JSONCompetitionEventStore(
            rootDirectory: root,
            faultInjector: .none,
            fileProtection: .testNoop
        )
        let competitionID = CompetitionID(self.competitionID)
        let genesis = try CompetitionGenesis(
            competitionID: competitionID,
            direction: .outgoing,
            createdAt: Date(timeIntervalSince1970: 1_786_000_000),
            expiresAt: nil,
            scoringPolicy: .appleCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
        let created = try await eventStore.create(genesis)
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let startDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 10,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let schedule = CompetitionSchedule(
            calendar: calendar,
            startDay: startDay
        )
        let days = try calendar.sevenDayWindow(startingOn: startDay)
        let dayAfterWindow = try calendar.day(
            after: try XCTUnwrap(days.last)
        )
        let configuration = try RemoteCompetitionConfiguration(
            competitionID: competitionID,
            owner: try RemoteParticipant(profileID: profileID),
            remote: try RemoteParticipant(
                profileID: UUID(
                    uuidString: "62000000-0000-4000-8000-000000000001"
                )!
            ),
            acceptedSchedule: schedule,
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            backendDescriptorRevision: 1,
            bestAvailableDeadline: try calendar.startOfDay(dayAfterWindow)
                .addingTimeInterval(3_600)
        )
        let configured = try await eventStore.append(
            [.remoteConfigurationAccepted(configuration)],
            to: competitionID,
            expectedCursor: created.cursor
        )
        let request = try scoreRequest()
        let response = try scoreResponse(for: request)
        let receivedAt = Date(timeIntervalSince1970: 1_786_536_010)
        let persistence = CompetitionAcceptedScorePersistence.eventStore(
            eventStore
        )

        try await persistence.persist(
            profileID,
            request,
            response,
            receivedAt
        )

        let loadedValue = try await eventStore.load(competitionID)
        let loaded = try XCTUnwrap(loadedValue)
        let ledger = try XCTUnwrap(
            loaded.projection.remoteScoreLedgers[profileID]
        )
        let row = try XCTUnwrap(
            try ledger.visibleEntry(forActiveDayOrdinal: request.dayOrdinal)
        )
        XCTAssertEqual(row.acceptedCentiPoints, response.acceptedCentiPoints)
        XCTAssertEqual(row.availabilityReason, nil)
        XCTAssertEqual(row.wireContentSHA256, request.wireContentSHA256)
        XCTAssertEqual(row.clientRevision, request.clientRevision)
        XCTAssertEqual(
            row.serverSequence,
            response.acceptedServerSequence
        )
        XCTAssertEqual(
            loaded.projection.synchronizationCursor,
            response.competitionCursor
        )
        XCTAssertEqual(loaded.journal.envelopes.count, 3)
        XCTAssertEqual(
            loaded.journal.envelopes.suffix(2).map(\.commitRevision),
            [
                configured.cursor.commitRevision + 1,
                configured.cursor.commitRevision + 1,
            ]
        )
    }

    func testEventStorePersistenceReloadsAfterCursorConflict()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseStore = JSONCompetitionEventStore(
            rootDirectory: root,
            faultInjector: .none,
            fileProtection: .testNoop
        )
        let competitionID = CompetitionID(self.competitionID)
        let genesis = try CompetitionGenesis(
            competitionID: competitionID,
            direction: .outgoing,
            createdAt: Date(timeIntervalSince1970: 1_786_000_000),
            expiresAt: nil,
            scoringPolicy: .appleCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
        let created = try await baseStore.create(genesis)
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let startDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 10,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let schedule = CompetitionSchedule(
            calendar: calendar,
            startDay: startDay
        )
        let days = try calendar.sevenDayWindow(startingOn: startDay)
        let dayAfterWindow = try calendar.day(
            after: try XCTUnwrap(days.last)
        )
        let remote = try RemoteParticipant(
            profileID: UUID(
                uuidString: "62000000-0000-4000-8000-000000000001"
            )!
        )
        let configuration = try RemoteCompetitionConfiguration(
            competitionID: competitionID,
            owner: try RemoteParticipant(profileID: profileID),
            remote: remote,
            acceptedSchedule: schedule,
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            backendDescriptorRevision: 1,
            bestAvailableDeadline: try calendar.startOfDay(dayAfterWindow)
                .addingTimeInterval(3_600)
        )
        _ = try await baseStore.append(
            [.remoteConfigurationAccepted(configuration)],
            to: competitionID,
            expectedCursor: created.cursor
        )
        let interferingRevision = try RemoteScoreRevision(
            competitionID: competitionID,
            participant: remote,
            row: try RemoteAcceptedScoreRow(
                ordinal: 2,
                acceptedCentiPoints: 100,
                availabilityReason: nil,
                wireContentSHA256: String(repeating: "b", count: 64),
                clientRevision: 1,
                serverSequence: 2
            ),
            recordedAt: Date(timeIntervalSince1970: 1_786_536_005)
        )
        let conflictStore = CursorConflictOnceEventStore(
            base: baseStore,
            interferingEvents: [
                .remoteScoreRevisionRecorded(interferingRevision),
            ]
        )
        let request = try scoreRequest()
        let response = try scoreResponse(for: request)

        try await CompetitionAcceptedScorePersistence
            .eventStore(conflictStore)
            .persist(
                profileID,
                request,
                response,
                Date(timeIntervalSince1970: 1_786_536_010)
            )

        let attempts = await conflictStore.appendAttemptCount()
        let loadedValue = try await baseStore.load(competitionID)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(attempts, 2)
        XCTAssertNotNil(
            try loaded.projection.remoteScoreLedgers[profileID]?
                .visibleEntry(forActiveDayOrdinal: 1)
        )
        XCTAssertNotNil(
            try loaded.projection.remoteScoreLedgers[remote.profileID]?
                .visibleEntry(forActiveDayOrdinal: 2)
        )
        XCTAssertEqual(
            loaded.projection.synchronizationCursor,
            response.competitionCursor
        )
    }

    func testLaterRevisionWaitsWhileAnEarlierOneOfItsMatchBacksOff()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(rootDirectory: root, fileProtection: .testNoop)
        let earlier = try scoreRequest()
        let later = try scoreRequest(
            semanticEventID: UUID(uuidString: "64000000-0000-4000-8000-000000000002")!,
            clientRevision: 2,
            wireContentSHA256: String(repeating: "b", count: 64)
        )
        let otherMatch = try scoreRequest(
            semanticEventID: UUID(uuidString: "64000000-0000-4000-8000-000000000003")!,
            competitionID: UUID(uuidString: "63000000-0000-4000-8000-000000000002")!
        )
        let now = Date(timeIntervalSince1970: 1_786_536_010)
        for request in [earlier, later, otherMatch] {
            _ = try await store.enqueue(.scoreRevision(request), enqueuedAt: now)
        }
        let accepted = try scoreResponse(for: otherMatch)
        let probe = CompetitionSyncCoordinatorProbe()
        let sleeper = CoordinatorRetrySleeper()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(appendScoreRevision: { submitted in
                await probe.recordRemoteCall(request: submitted, durableEntries: [])
                guard submitted == otherMatch else {
                    throw CompetitionRemoteFailure.retryableTransport
                }
                return accepted
            }),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence { _, _, _, _ in },
            now: { now },
            sleepUntil: { deadline in await sleeper.sleep(until: deadline) }
        )

        await coordinator.wake()
        await coordinator.waitUntilIdle()

        // Revision 2 would land first, and the server would then refuse
        // revision 1 as a regression; the other match isn't held up.
        let sent = await probe.remoteRequests()
        let left = try await store.entries().map(\.semanticEventID)
        XCTAssertEqual(sent, [earlier, otherMatch])
        XCTAssertEqual(left, [earlier.semanticEventID, later.semanticEventID])
        await coordinator.stop()
    }

    func testUnrecordableAnswerParksOnlyItsUploadAndTheQueueMovesOn()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(rootDirectory: root, fileProtection: .testNoop)
        let otherContent = try scoreRequest()
        let refused = try scoreRequest(
            semanticEventID: UUID(uuidString: "64000000-0000-4000-8000-000000000002")!,
            clientRevision: 2,
            wireContentSHA256: String(repeating: "b", count: 64)
        )
        let fine = try scoreRequest(
            semanticEventID: UUID(uuidString: "64000000-0000-4000-8000-000000000003")!,
            clientRevision: 3,
            wireContentSHA256: String(repeating: "d", count: 64)
        )
        let now = Date(timeIntervalSince1970: 1_786_536_010)
        for request in [otherContent, refused, fine] {
            _ = try await store.enqueue(.scoreRevision(request), enqueuedAt: now)
        }
        // An answer for different content than the upload sent.
        let mismatched = try CompetitionScoreRevisionResponse(
            disposition: .appended,
            rejectionCode: nil,
            acceptedCentiPoints: 27_500,
            wireContentSHA256: String(repeating: "f", count: 64),
            acceptedServerSequence: 4,
            competitionCursor: 4
        )
        let refusedResponse = try scoreResponse(for: refused)
        let fineResponse = try scoreResponse(for: fine)
        let probe = CompetitionSyncCoordinatorProbe()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(appendScoreRevision: { submitted in
                await probe.recordRemoteCall(request: submitted, durableEntries: [])
                if submitted == otherContent { return mismatched }
                return submitted == refused ? refusedResponse : fineResponse
            }),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, request, response, receivedAt in
                // The journal can't take this row, now or on any retry.
                if request == refused {
                    throw CompetitionRemoteFailure.serverContractMismatch
                }
                await probe.recordPersistenceCall(
                    request: request,
                    response: response,
                    receivedAt: receivedAt,
                    durableEntries: []
                )
            },
            now: { now }
        )

        await coordinator.wake()
        await coordinator.waitUntilIdle()

        let sent = await probe.remoteRequests()
        let persisted = await probe.persistenceObservations().map(\.request)
        let left = try await store.entries()
        XCTAssertEqual(sent, [otherContent, refused, fine])
        XCTAssertEqual(persisted, [fine])
        XCTAssertEqual(left.map(\.semanticEventID), [otherContent.semanticEventID, refused.semanticEventID])
        XCTAssertEqual(
            left.map(\.state),
            [CompetitionOutboxState](
                repeating: .permanentFailure(.serverContractMismatch, failedAt: now),
                count: 2
            )
        )
        await coordinator.stop()
    }

    func testWakeIgnoringBackoffRetriesAtOnce() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(rootDirectory: root, fileProtection: .testNoop)
        let failedAt = Date(timeIntervalSince1970: 1_786_536_010)
        let probe = CompetitionSyncCoordinatorProbe()
        let sleeper = CoordinatorRetrySleeper()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(appendScoreRevision: { submitted in
                await probe.recordRemoteCall(request: submitted, durableEntries: [])
                throw CompetitionRemoteFailure.retryableTransport
            }),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence { _, _, _, _ in },
            now: { failedAt },
            sleepUntil: { deadline in await sleeper.sleep(until: deadline) }
        )

        _ = try await coordinator.enqueue(.scoreRevision(try scoreRequest()), enqueuedAt: failedAt)
        await coordinator.waitUntilIdle()
        await coordinator.wake()
        await coordinator.waitUntilIdle()
        let whileBackedOff = await probe.remoteCallCount()
        // The server just answered another call: the backoff earned
        // offline no longer applies.
        await coordinator.wake(ignoringBackoff: true)
        await coordinator.waitUntilIdle()
        let afterReconnect = await probe.remoteCallCount()

        XCTAssertEqual(whileBackedOff, 1)
        XCTAssertEqual(afterReconnect, 2)
        await coordinator.stop()
    }

    func testWakeDuringAFailedPassStillGetsItsPass() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = JSONCompetitionOutboxStore(rootDirectory: root, fileProtection: .testNoop)
        let request = try scoreRequest()
        let now = Date(timeIntervalSince1970: 1_786_536_010)
        _ = try await base.enqueue(.scoreRevision(request), enqueuedAt: now)
        let store = WakeThenFailOnceOutboxStore(base: base)
        let accepted = try scoreResponse(for: request)
        let probe = CompetitionSyncCoordinatorProbe()
        let coordinator = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: store,
            remoteAPI: remoteAPI(appendScoreRevision: { submitted in
                await probe.recordRemoteCall(request: submitted, durableEntries: [])
                return accepted
            }),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence { _, _, _, _ in },
            now: { now }
        )
        // A wake lands while the first pass is failing.
        await store.failFirstRead { await coordinator.wake() }

        await coordinator.wake()
        await coordinator.waitUntilIdle()

        let calls = await probe.remoteCallCount()
        let left = try await base.entries()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(left, [])
        await coordinator.stop()
    }

    func testAcceptedScoreReplaysWithTheReceivedAtItFirstUsed() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try scoreRequest()
        let response = try scoreResponse(for: request)
        // Finer than the outbox's millisecond dates keep.
        let clock = Date(timeIntervalSince1970: 1_786_536_010.987_654_3)
        let probe = CompetitionSyncCoordinatorProbe()
        let crashing = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: JSONCompetitionOutboxStore(rootDirectory: root, fileProtection: .testNoop),
            remoteAPI: remoteAPI(appendScoreRevision: { _ in response }),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, submitted, accepted, receivedAt in
                await probe.recordPersistenceCall(
                    request: submitted, response: accepted, receivedAt: receivedAt, durableEntries: []
                )
                throw CoordinatorFixtureFailure.injectedCrash
            },
            now: { clock }
        )
        _ = try await crashing.enqueue(.scoreRevision(request), enqueuedAt: clock)
        await crashing.waitUntilIdle()
        await crashing.stop()

        let relaunched = CompetitionSyncCoordinator(
            profileID: profileID,
            outboxStore: JSONCompetitionOutboxStore(rootDirectory: root, fileProtection: .testNoop),
            remoteAPI: remoteAPI(appendScoreRevision: { _ in response }),
            acceptedScorePersistence: CompetitionAcceptedScorePersistence {
                _, submitted, accepted, receivedAt in
                await probe.recordPersistenceCall(
                    request: submitted, response: accepted, receivedAt: receivedAt, durableEntries: []
                )
            },
            now: { clock }
        )
        await relaunched.wake()
        await relaunched.waitUntilIdle()

        // The journal receipt carries receivedAt, so a replay must match.
        let observations = await probe.persistenceObservations()
        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations.first?.receivedAt, observations.last?.receivedAt)
        await relaunched.stop()
    }

    private func scoreRequest(
        semanticEventID: UUID = UUID(
            uuidString: "64000000-0000-4000-8000-000000000001"
        )!,
        clientRevision: Int64 = 1,
        wireContentSHA256: String = String(repeating: "a", count: 64),
        competitionID: UUID? = nil
    ) throws -> CompetitionScoreRevisionRequest {
        try CompetitionScoreRevisionRequest(
            competitionID: competitionID ?? self.competitionID,
            semanticEventID: semanticEventID,
            dayOrdinal: 1,
            clientRevision: clientRevision,
            evaluatedAt: Date(timeIntervalSince1970: 1_786_536_000),
            moveMode: "activeEnergyKilocalories",
            standMode: "standHours",
            moveBasisPoints: 10_000,
            exerciseBasisPoints: 5_000,
            standBasisPoints: 12_500,
            availabilityReason: "available",
            scoringPolicyIdentity: "healthcomp.activity-score.v1",
            wireContentSHA256: wireContentSHA256
        )
    }

    private func scoreResponse(
        for request: CompetitionScoreRevisionRequest
    ) throws -> CompetitionScoreRevisionResponse {
        try CompetitionScoreRevisionResponse(
            disposition: .appended,
            rejectionCode: nil,
            acceptedCentiPoints: 27_500,
            wireContentSHA256: request.wireContentSHA256,
            acceptedServerSequence: 4,
            competitionCursor: 4
        )
    }

    private func attestationRequest() throws -> CompetitionAttestationRequest {
        try CompetitionAttestationRequest(
            competitionID: competitionID,
            semanticEventID: UUID(
                uuidString: "65000000-0000-4000-8000-000000000001"
            )!,
            attestationVersion: 1,
            basis: .stable,
            acceptedRevisions: [1, 2, 3, 4, 5, 6, 7],
            windowCommitmentSHA256: String(repeating: "c", count: 64)
        )
    }

    private func remoteAPI(
        appendScoreRevision: @escaping @Sendable (
            CompetitionScoreRevisionRequest
        ) async throws -> CompetitionScoreRevisionResponse,
        submitAttestation: @escaping @Sendable (
            CompetitionAttestationRequest
        ) async throws -> CompetitionAttestationReceipt = { _ in
            throw CompetitionRemoteFailure.operationFailed
        }
    ) -> CompetitionRemoteAPI {
        CompetitionRemoteAPI(
            bootstrapProfile: { _ in throw CompetitionRemoteFailure.operationFailed },
            updateProfile: { _ in throw CompetitionRemoteFailure.operationFailed },
            listCompetitions: { throw CompetitionRemoteFailure.operationFailed },
            fetchCompetition: { _ in throw CompetitionRemoteFailure.operationFailed },
            createInvite: { _ in throw CompetitionRemoteFailure.operationFailed },
            claimInvite: { _ in throw CompetitionRemoteFailure.operationFailed },
            appendScoreRevision: appendScoreRevision,
            submitAttestation: submitAttestation,
            fetchChanges: { _, _ in throw CompetitionRemoteFailure.operationFailed },
            registerInstallation: { _ in throw CompetitionRemoteFailure.operationFailed },
            removeInstallation: { _ in throw CompetitionRemoteFailure.operationFailed },
            requestAccountDeletion: { throw CompetitionRemoteFailure.operationFailed }
        )
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
            .withCreatedDirectory()
    }

    private let profileID = UUID(
        uuidString: "61000000-0000-4000-8000-000000000001"
    )!
    private let competitionID = UUID(
        uuidString: "63000000-0000-4000-8000-000000000001"
    )!
}

private actor CompetitionSyncCoordinatorProbe {
    struct RemoteObservation: Equatable, Sendable {
        let request: CompetitionScoreRevisionRequest
        let durableEntries: [CompetitionOutboxEntry]
    }

    struct PersistenceObservation: Equatable, Sendable {
        let request: CompetitionScoreRevisionRequest
        let response: CompetitionScoreRevisionResponse
        let receivedAt: Date
        let durableEntries: [CompetitionOutboxEntry]
    }

    struct AttestationObservation: Equatable, Sendable {
        let request: CompetitionAttestationRequest
        let durableEntries: [CompetitionOutboxEntry]
    }

    private var remoteObservations: [RemoteObservation] = []
    private var persistedObservations: [PersistenceObservation] = []
    private var submittedAttestations: [AttestationObservation] = []
    private var remoteCallWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func recordRemoteCall(
        request: CompetitionScoreRevisionRequest,
        durableEntries: [CompetitionOutboxEntry]
    ) {
        remoteObservations.append(RemoteObservation(
            request: request,
            durableEntries: durableEntries
        ))
        let ready = remoteCallWaiters.filter {
            remoteObservations.count >= $0.count
        }
        remoteCallWaiters.removeAll {
            remoteObservations.count >= $0.count
        }
        ready.forEach { $0.continuation.resume() }
    }

    func recordPersistenceCall(
        request: CompetitionScoreRevisionRequest,
        response: CompetitionScoreRevisionResponse,
        receivedAt: Date,
        durableEntries: [CompetitionOutboxEntry]
    ) {
        persistedObservations.append(PersistenceObservation(
            request: request,
            response: response,
            receivedAt: receivedAt,
            durableEntries: durableEntries
        ))
    }

    func recordAttestationCall(
        request: CompetitionAttestationRequest,
        durableEntries: [CompetitionOutboxEntry]
    ) {
        submittedAttestations.append(AttestationObservation(
            request: request,
            durableEntries: durableEntries
        ))
    }

    func remoteObservation() -> RemoteObservation? {
        remoteObservations.first
    }

    func remoteCallCount() -> Int { remoteObservations.count }

    func remoteRequests() -> [CompetitionScoreRevisionRequest] {
        remoteObservations.map(\.request)
    }

    func waitForRemoteCallCount(_ count: Int) async {
        guard remoteObservations.count < count else { return }
        await withCheckedContinuation { continuation in
            remoteCallWaiters.append((count, continuation))
        }
    }

    func persistenceObservations() -> [PersistenceObservation] {
        persistedObservations
    }


    func attestationObservations() -> [AttestationObservation] {
        submittedAttestations
    }
}

private enum CoordinatorFixtureFailure: Error {
    case injectedCrash
    case unexpectedRemote
}

private actor FailOnceAcceptedScorePersistenceProbe {
    private var calls = 0

    func persist() throws {
        calls += 1
        if calls == 1 {
            throw CoordinatorFixtureFailure.injectedCrash
        }
    }

    func callCount() -> Int { calls }
}

private actor RemoveFailingOutboxStore: CompetitionOutboxStore {
    private let base: any CompetitionOutboxStore
    private var shouldFailNextRemove = true

    init(base: any CompetitionOutboxStore) {
        self.base = base
    }

    func enqueue(
        _ payload: CompetitionOutboxPayload,
        enqueuedAt: Date
    ) async throws -> CompetitionOutboxEntry {
        try await base.enqueue(payload, enqueuedAt: enqueuedAt)
    }

    func entries() async throws -> [CompetitionOutboxEntry] {
        try await base.entries()
    }

    func update(
        _ semanticEventID: UUID,
        expectedGeneration: UInt64,
        state: CompetitionOutboxState
    ) async throws -> CompetitionOutboxEntry {
        try await base.update(
            semanticEventID,
            expectedGeneration: expectedGeneration,
            state: state
        )
    }

    func remove(
        _ semanticEventID: UUID,
        expectedGeneration: UInt64
    ) async throws {
        guard !shouldFailNextRemove else {
            shouldFailNextRemove = false
            throw CoordinatorFixtureFailure.injectedCrash
        }
        try await base.remove(
            semanticEventID,
            expectedGeneration: expectedGeneration
        )
    }
}

/// Its first read lets `hook` run, then fails, as a drain pass would on an
/// outbox IO error.
private actor WakeThenFailOnceOutboxStore: CompetitionOutboxStore {
    private let base: any CompetitionOutboxStore
    private var hook: (@Sendable () async -> Void)?

    init(base: any CompetitionOutboxStore) {
        self.base = base
    }

    func failFirstRead(after hook: @escaping @Sendable () async -> Void) {
        self.hook = hook
    }

    func enqueue(
        _ payload: CompetitionOutboxPayload,
        enqueuedAt: Date
    ) async throws -> CompetitionOutboxEntry {
        try await base.enqueue(payload, enqueuedAt: enqueuedAt)
    }

    func entries() async throws -> [CompetitionOutboxEntry] {
        if let hook {
            self.hook = nil
            await hook()
            throw CoordinatorFixtureFailure.injectedCrash
        }
        return try await base.entries()
    }

    func update(
        _ semanticEventID: UUID,
        expectedGeneration: UInt64,
        state: CompetitionOutboxState
    ) async throws -> CompetitionOutboxEntry {
        try await base.update(
            semanticEventID,
            expectedGeneration: expectedGeneration,
            state: state
        )
    }

    func remove(
        _ semanticEventID: UUID,
        expectedGeneration: UInt64
    ) async throws {
        try await base.remove(
            semanticEventID,
            expectedGeneration: expectedGeneration
        )
    }
}

private actor CursorConflictOnceEventStore: CompetitionEventStore {
    private let base: any CompetitionEventStore
    private let interferingEvents: [CompetitionDomainEvent]
    private var didInjectConflict = false
    private var recordedAppendAttempts = 0

    init(
        base: any CompetitionEventStore,
        interferingEvents: [CompetitionDomainEvent]
    ) {
        self.base = base
        self.interferingEvents = interferingEvents
    }

    func ids() async throws -> [CompetitionID] {
        try await base.ids()
    }

    func load(
        _ id: CompetitionID
    ) async throws -> LoadedCompetitionJournal? {
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
        recordedAppendAttempts += 1
        guard !didInjectConflict else {
            return try await base.append(
                events,
                to: id,
                expectedCursor: expectedCursor
            )
        }

        didInjectConflict = true
        let advanced = try await base.append(
            interferingEvents,
            to: id,
            expectedCursor: expectedCursor
        )
        throw CompetitionEventStoreError.cursorConflict(
            expected: expectedCursor,
            actual: advanced.cursor
        )
    }

    func delete(
        _ id: CompetitionID,
        expectedCursor: CompetitionJournalCursor
    ) async throws {
        try await base.delete(id, expectedCursor: expectedCursor)
    }

    func appendAttemptCount() -> Int {
        recordedAppendAttempts
    }
}

private final class CoordinatorDateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Date

    init(_ value: Date) {
        self.storedValue = value
    }

    var value: Date {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class CoordinatorBoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        self.storedValue = value
    }

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class CoordinatorDatesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Date] = []

    var values: [Date] {
        lock.withLock { storedValues }
    }

    func append(_ value: Date) {
        lock.withLock { storedValues.append(value) }
    }
}

private actor CoordinatorRetrySleeper {
    private var recordedDeadlines: [Date] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var waiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func sleep(until deadline: Date) async {
        recordedDeadlines.append(deadline)
        let ready = waiters.filter { recordedDeadlines.count >= $0.count }
        waiters.removeAll { recordedDeadlines.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForSleepCount(_ count: Int) async {
        guard recordedDeadlines.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func releaseFirst() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func deadlines() -> [Date] {
        recordedDeadlines
    }
}

private actor CoordinatorRemoteGate {
    struct Observation: Equatable, Sendable {
        let callCount: Int
        let maximumInFlight: Int
    }

    private var callCount = 0
    private var inFlight = 0
    private var maximumInFlight = 0
    private var isOpen = false
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var waiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func enter() async {
        callCount += 1
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        let ready = waiters.filter { callCount >= $0.count }
        waiters.removeAll { callCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        if !isOpen {
            await withCheckedContinuation { continuation in
                blocked.append(continuation)
            }
        }
        inFlight -= 1
    }

    func waitForCallCount(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func open() {
        isOpen = true
        let continuations = blocked
        blocked.removeAll()
        continuations.forEach { $0.resume() }
    }

    func observation() -> Observation {
        Observation(
            callCount: callCount,
            maximumInFlight: maximumInFlight
        )
    }
}

private extension JSONCompetitionEventStoreFileProtection {
    static let testNoop = Self { _, _ in }
}

private extension URL {
    func withCreatedDirectory() -> URL {
        try! FileManager.default.createDirectory(
            at: self,
            withIntermediateDirectories: false
        )
        return self
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
