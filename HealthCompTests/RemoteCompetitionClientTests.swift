import CompetitionCore
import Foundation
import XCTest

@testable import HealthComp

final class RemoteCompetitionClientTests: XCTestCase {
    func testMountedRemoteClientPublishesEmptyCanonicalDashboard()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let probe = RemoteCompetitionClientProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: {
                await probe.recordList()
                return []
            }),
            environment: try environment()
        )

        try await client.mountAuthenticatedProfile(profile, paths)
        var iterator = client.start().makeAsyncIterator()
        let nextPublication = await iterator.next()
        let publication = try XCTUnwrap(nextPublication)

        XCTAssertEqual(publication.publicationRevision, 1)
        XCTAssertEqual(publication.dashboard.competitions, [])
        XCTAssertEqual(publication.dashboard.awards, [])
        XCTAssertEqual(publication.dashboard.issues, [])
        let listCount = await probe.listCount()
        XCTAssertEqual(listCount, 1)
        await client.stop()
    }

    func testCreateAndClaimReturnCanonicalPublicationRevisions()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let competitionID = UUID(
            uuidString: "82000000-0000-4000-8000-000000000001"
        )!
        let token = Data(repeating: 0x42, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let invite = try CompetitionInvite(
            competitionID: competitionID,
            token: token
        )
        let claim = try CompetitionInviteClaim(
            competitionID: competitionID
        )
        let probe = RemoteCompetitionClientCommandProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(
                listCompetitions: {
                    await probe.recordList()
                    return []
                },
                createInvite: { request in
                    await probe.recordCreate(request)
                    return invite
                },
                claimInvite: { request in
                    await probe.recordClaim(request)
                    return claim
                }
            ),
            environment: try environment()
        )
        let createRequest = try CompetitionInviteCreationRequest(
            timeZoneIdentifier: "America/Los_Angeles",
            rematchParentID: nil,
            idempotencyKey: UUID(
                uuidString: "83000000-0000-4000-8000-000000000001"
            )!
        )
        let claimRequest = try CompetitionInviteClaimRequest(token: token)

        try await client.mountAuthenticatedProfile(profile, paths)
        var iterator = client.start().makeAsyncIterator()
        let initialPublication = await iterator.next()
        XCTAssertEqual(initialPublication?.publicationRevision, 1)

        let creation = try await client.createInvite(createRequest)
        let nextCreationPublication = await iterator.next()
        let creationPublication = try XCTUnwrap(nextCreationPublication)
        XCTAssertEqual(creation.invite, invite)
        XCTAssertEqual(creation.expectedPublicationRevision, 2)
        XCTAssertEqual(creationPublication.publicationRevision, 2)
        XCTAssertEqual(creationPublication.dashboard.competitions, [])

        let claimed = try await client.claimInvite(claimRequest)
        let nextClaimPublication = await iterator.next()
        let claimPublication = try XCTUnwrap(nextClaimPublication)
        XCTAssertEqual(claimed.claim, claim)
        XCTAssertEqual(claimed.expectedPublicationRevision, 3)
        XCTAssertEqual(claimPublication.publicationRevision, 3)
        XCTAssertEqual(claimPublication.dashboard.competitions, [])

        let listCount = await probe.listCount()
        let createRequests = await probe.createRequests()
        let claimRequests = await probe.claimRequests()
        XCTAssertEqual(listCount, 3)
        XCTAssertEqual(createRequests, [createRequest])
        XCTAssertEqual(claimRequests, [claimRequest])
        await client.stop()
    }

    func testProfileSwitchAndStopTerminateTheirPriorCanonicalStreams()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let secondProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000002"
            )!,
            displayName: "Beta Bob"
        )
        let firstPaths = AuthenticatedProfileStoragePaths(
            profileID: firstProfile.id,
            rootDirectory: root.appendingPathComponent(
                "first",
                isDirectory: true
            )
        )
        let secondPaths = AuthenticatedProfileStoragePaths(
            profileID: secondProfile.id,
            rootDirectory: root.appendingPathComponent(
                "second",
                isDirectory: true
            )
        )
        for directory in firstPaths.fixedDirectories
            + secondPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let probe = RemoteCompetitionClientProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: {
                await probe.recordList()
                return []
            }),
            environment: try environment()
        )

        try await client.mountAuthenticatedProfile(firstProfile, firstPaths)
        var firstIterator = client.start().makeAsyncIterator()
        let firstPublication = await firstIterator.next()
        XCTAssertEqual(firstPublication?.publicationRevision, 1)

        try await client.mountAuthenticatedProfile(secondProfile, secondPaths)
        let firstStreamTermination = await firstIterator.next()
        XCTAssertNil(firstStreamTermination)

        var secondIterator = client.start().makeAsyncIterator()
        let secondPublication = await secondIterator.next()
        XCTAssertEqual(secondPublication?.publicationRevision, 1)

        await client.stop()
        let secondStreamTermination = await secondIterator.next()
        XCTAssertNil(secondStreamTermination)
        let listCount = await probe.listCount()
        XCTAssertEqual(listCount, 2)
    }

    func testStartAfterStopCannotRestartUntilAProfileIsMountedAgain()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
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
        let initialDate = try calendar.startOfDay(startDay)
        let signalDate = initialDate.addingTimeInterval(60)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: initialDate,
                    monotonic: MonotonicInstant(
                        epochID: "task13-stop",
                        nanoseconds: 1
                    )
                ),
                timeZoneIdentifier: calendar.timeZoneIdentifier,
                initialDays: try calendar.sevenDayWindow(
                    startingOn: startDay
                ).map { .missing(day: $0) },
                changes: [
                    try FixtureActivityChange(
                        at: signalDate,
                        updates: [],
                        triggers: [.observerWakeupBackground]
                    ),
                ]
            )
        )
        let probe = RemoteCompetitionClientProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: {
                await probe.recordList()
                return []
            }),
            environment: .accelerated(source: source)
        )
        try await client.mountAuthenticatedProfile(profile, paths)
        await client.stop()

        var stoppedIterator = client.start().makeAsyncIterator()
        let stoppedPublication = await stoppedIterator.next()
        XCTAssertNil(stoppedPublication)
        try await Task.sleep(nanoseconds: 50_000_000)
        let stoppedSubscriberCount = await source.signalSubscriberCount()
        try await source.advance(to: signalDate)
        try await Task.sleep(nanoseconds: 50_000_000)
        let stoppedListCount = await probe.listCount()
        let stoppedCompletionCount = await source.signalCompletionCount(
            "fixture-signal-1"
        )
        XCTAssertEqual(stoppedListCount, 0)
        XCTAssertEqual(stoppedSubscriberCount, 0)
        XCTAssertEqual(stoppedCompletionCount, 0)

        try await client.mountAuthenticatedProfile(profile, paths)
        var remountedIterator = client.start().makeAsyncIterator()
        let remountedPublication = await remountedIterator.next()
        let remountedListCount = await probe.listCount()
        XCTAssertEqual(remountedPublication?.publicationRevision, 1)
        XCTAssertEqual(remountedListCount, 1)
        await client.stop()
    }

    func testConcurrentReconciliationsUseOneSerializedCanonicalOperation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let probe = SerializedRemoteCompetitionListProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: {
                await probe.listCompetitions()
            }),
            environment: try environment()
        )
        try await client.mountAuthenticatedProfile(profile, paths)

        let first = Task {
            await client.reconcileAll(.pullToRefresh)
        }
        await probe.waitUntilFirstCallEntered()
        let second = Task {
            await client.reconcileAll(.foreground)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let maximumBeforeRelease = await probe.maximumConcurrentCalls()
        await probe.releaseFirstCall()
        let firstPublication = await first.value
        let secondPublication = await second.value
        let maximumAfterRelease = await probe.maximumConcurrentCalls()

        XCTAssertEqual(maximumBeforeRelease, 1)
        XCTAssertEqual(maximumAfterRelease, 1)
        XCTAssertEqual(
            Set([
                firstPublication.publicationRevision,
                secondPublication.publicationRevision,
            ]),
            Set([1, 2])
        )
        await client.stop()
    }

    func testRelaunchOfflinePublishesProfileScopedDurableCache()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let competitionID = UUID(
            uuidString: "82000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let expiresAt = createdAt.addingTimeInterval(48 * 60 * 60)
        let descriptor = try pendingDescriptor(
            competitionID: competitionID,
            profile: profile,
            expiresAt: expiresAt
        )
        let page = try pendingHistoryPage(
            descriptor: descriptor,
            profileID: profile.id,
            createdAt: createdAt
        )
        let online = CompetitionClient.remote(
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page }
            ),
            environment: try environment()
        )

        try await online.mountAuthenticatedProfile(profile, paths)
        var onlineIterator = online.start().makeAsyncIterator()
        let nextOnlinePublication = await awaitNext(&onlineIterator)
        let onlinePublication = try XCTUnwrap(nextOnlinePublication)
        XCTAssertEqual(
            onlinePublication.dashboard.competitions.map(\.id),
            [CompetitionID(competitionID)]
        )
        XCTAssertEqual(onlinePublication.dashboard.issues, [])
        await online.stop()

        let offline = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: {
                throw CompetitionRemoteFailure.operationFailed
            }),
            environment: try environment()
        )
        try await offline.mountAuthenticatedProfile(profile, paths)
        var offlineIterator = offline.start().makeAsyncIterator()
        let nextOfflinePublication = await awaitNext(&offlineIterator)
        let offlinePublication = try XCTUnwrap(nextOfflinePublication)

        XCTAssertEqual(
            offlinePublication.dashboard.competitions.map(\.id),
            [CompetitionID(competitionID)]
        )
        XCTAssertEqual(
            offlinePublication.dashboard.issues,
            [.storageUnavailable]
        )
        await offline.stop()
    }

    func testRelaunchResumesFromDurableServerCursor()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let competitionID = UUID(
            uuidString: "82000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try pendingDescriptor(
            competitionID: competitionID,
            profile: profile,
            expiresAt: createdAt.addingTimeInterval(48 * 60 * 60)
        )
        let bootstrapPage = try pendingHistoryPage(
            descriptor: descriptor,
            profileID: profile.id,
            createdAt: createdAt
        )
        let first = CompetitionClient.remote(
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in bootstrapPage }
            ),
            environment: try environment()
        )
        try await first.mountAuthenticatedProfile(profile, paths)
        var firstIterator = first.start().makeAsyncIterator()
        let firstPublication = await awaitNext(&firstIterator)
        XCTAssertEqual(firstPublication?.dashboard.competitions.count, 1)
        await first.stop()

        let probe = RemoteCompetitionCursorProbe()
        let incrementalPage = try CompetitionChangePage(
            competitionID: competitionID,
            afterServerSequence: 1,
            snapshotServerSequence: 1,
            nextServerSequence: 1,
            hasMore: false,
            changes: []
        )
        let relaunched = CompetitionClient.remote(
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { cursor, pageSize in
                    await probe.record(cursor: cursor, pageSize: pageSize)
                    return incrementalPage
                }
            ),
            environment: try environment()
        )

        try await relaunched.mountAuthenticatedProfile(profile, paths)
        var relaunchedIterator = relaunched.start().makeAsyncIterator()
        let relaunchedPublication = await awaitNext(&relaunchedIterator)

        XCTAssertEqual(
            relaunchedPublication?.dashboard.competitions.map(\.id),
            [CompetitionID(competitionID)]
        )
        XCTAssertEqual(relaunchedPublication?.dashboard.issues, [])
        let observations = await probe.observations()
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(
            observations.first?.cursor.lastSeenServerSequence,
            1
        )
        XCTAssertEqual(observations.first?.pageSize, 200)
        await relaunched.stop()
    }

    private func environment() throws -> CompetitionEnvironmentClient {
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 13,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let days = try calendar.sevenDayWindow(startingOn: start)
        return .accelerated(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: try calendar.startOfDay(start),
                    monotonic: MonotonicInstant(
                        epochID: "task13-remote-client",
                        nanoseconds: 1
                    )
                ),
                timeZoneIdentifier: calendar.timeZoneIdentifier,
                initialDays: days.map { .missing(day: $0) },
                changes: []
            )
        )
    }

    private func pendingDescriptor(
        competitionID: UUID,
        profile: AuthenticatedProfile,
        expiresAt: Date
    ) throws -> CompetitionDescriptor {
        try CompetitionDescriptor(
            competitionID: competitionID,
            creatorProfileID: profile.id,
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
                    profileID: profile.id,
                    role: .creator,
                    state: .accepted,
                    profile: try CompetitionProfilePresentation(
                        id: profile.id,
                        displayName: profile.displayName
                    )
                ),
            ]
        )
    }

    private func pendingHistoryPage(
        descriptor: CompetitionDescriptor,
        profileID: UUID,
        createdAt: Date
    ) throws -> CompetitionChangePage {
        try CompetitionChangePage(
            competitionID: descriptor.competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 1,
            nextServerSequence: 1,
            hasMore: false,
            changes: [
                try CompetitionChange(
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
                ),
            ]
        )
    }

    private func awaitNext(
        _ iterator: inout AsyncStream<CompetitionPublication>.Iterator
    ) async -> CompetitionPublication? {
        await iterator.next()
    }

    private func remoteAPI(
        listCompetitions: @escaping @Sendable () async throws ->
            [CompetitionDescriptor],
        createInvite: @escaping @Sendable (
            CompetitionInviteCreationRequest
        ) async throws -> CompetitionInvite = { _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        claimInvite: @escaping @Sendable (
            CompetitionInviteClaimRequest
        ) async throws -> CompetitionInviteClaim = { _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        fetchChanges: @escaping @Sendable (
            CompetitionSynchronizationCursor,
            Int
        ) async throws -> CompetitionChangePage = { _, _ in
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
            createInvite: createInvite,
            claimInvite: claimInvite,
            appendScoreRevision: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            submitAttestation: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
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
}

private actor RemoteCompetitionClientCommandProbe {
    private var lists = 0
    private var creates: [CompetitionInviteCreationRequest] = []
    private var claims: [CompetitionInviteClaimRequest] = []

    func recordList() {
        lists += 1
    }

    func recordCreate(_ request: CompetitionInviteCreationRequest) {
        creates.append(request)
    }

    func recordClaim(_ request: CompetitionInviteClaimRequest) {
        claims.append(request)
    }

    func listCount() -> Int {
        lists
    }

    func createRequests() -> [CompetitionInviteCreationRequest] {
        creates
    }

    func claimRequests() -> [CompetitionInviteClaimRequest] {
        claims
    }
}

private actor RemoteCompetitionCursorProbe {
    struct Observation: Equatable, Sendable {
        let cursor: CompetitionSynchronizationCursor
        let pageSize: Int
    }

    private var values: [Observation] = []

    func record(
        cursor: CompetitionSynchronizationCursor,
        pageSize: Int
    ) {
        values.append(Observation(cursor: cursor, pageSize: pageSize))
    }

    func observations() -> [Observation] {
        values
    }
}

private actor RemoteCompetitionClientProbe {
    private var lists = 0

    func recordList() {
        lists += 1
    }

    func listCount() -> Int {
        lists
    }
}

private actor SerializedRemoteCompetitionListProbe {
    private var activeCalls = 0
    private var maximumActiveCalls = 0
    private var totalCalls = 0
    private var firstEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?

    func listCompetitions() async -> [CompetitionDescriptor] {
        totalCalls += 1
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        if totalCalls == 1 {
            let waiters = firstEntryWaiters
            firstEntryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstReleaseContinuation = continuation
            }
        }
        activeCalls -= 1
        return []
    }

    func waitUntilFirstCallEntered() async {
        guard totalCalls == 0 else { return }
        await withCheckedContinuation { continuation in
            firstEntryWaiters.append(continuation)
        }
    }

    func releaseFirstCall() {
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }

    func maximumConcurrentCalls() -> Int {
        maximumActiveCalls
    }
}
