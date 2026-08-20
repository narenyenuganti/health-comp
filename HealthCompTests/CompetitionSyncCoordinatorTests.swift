import CompetitionCore
import Foundation
import XCTest

@testable import HealthComp

final class CompetitionSyncCoordinatorTests: XCTestCase {
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
        let durable = try await store.entries()
        XCTAssertEqual(attempts, 1)
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
            now: { clock.value }
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

        let attempts = await probe.remoteCallCount()
        XCTAssertEqual(attempts, expectedDelays.count)
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
        await fulfillment(of: [scheduleExpectation], timeout: 0.25)

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
            (.appAttestRejected, .appAttestRejected),
            (.appAttestContextUnavailable, .appAttestRejected),
            (.appAttestProofConflict, .appAttestRejected),
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

    private func scoreRequest(
        semanticEventID: UUID = UUID(
            uuidString: "64000000-0000-4000-8000-000000000001"
        )!,
        clientRevision: Int64 = 1,
        wireContentSHA256: String = String(repeating: "a", count: 64)
    ) throws -> CompetitionScoreRevisionRequest {
        try CompetitionScoreRevisionRequest(
            competitionID: competitionID,
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
