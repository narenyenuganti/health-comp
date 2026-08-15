import CompetitionCore
import Foundation
import XCTest

@testable import HealthComp

final class CompetitionRealtimeClientTests: XCTestCase {
    func testDuplicateOutOfOrderAndReconnectWakeupsRefetchDurableState()
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
                uuidString: "81000000-0000-4000-8000-000000000015"
            )!,
            displayName: "Beta Realtime"
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

        let remoteProbe = RealtimeRemoteAPIProbe()
        let realtimeSource = RealtimeWakeupSource()
        let client = CompetitionClient.remote(
            remoteAPI: .realtimeFixture {
                await remoteProbe.recordDurableList()
                return []
            },
            environment: try environment(),
            realtimeClient: realtimeSource.client
        )

        try await client.mountAuthenticatedProfile(profile, paths)
        var iterator = client.start().makeAsyncIterator()
        let initialPublication = await iterator.next()
        XCTAssertEqual(initialPublication?.publicationRevision, 1)
        await realtimeSource.waitForSubscription()

        let wakeups = [
            CompetitionRealtimeWakeUp(
                reason: .broadcast,
                serverCursorHint: 9
            ),
            CompetitionRealtimeWakeUp(
                reason: .broadcast,
                serverCursorHint: 7
            ),
            CompetitionRealtimeWakeUp(
                reason: .broadcast,
                serverCursorHint: 9
            ),
            CompetitionRealtimeWakeUp(
                reason: .subscribed,
                serverCursorHint: nil
            ),
        ]

        for (offset, wakeup) in wakeups.enumerated() {
            await realtimeSource.send(wakeup)
            let publication = await iterator.next()
            XCTAssertEqual(
                publication?.publicationRevision,
                UInt64(offset + 2)
            )
            XCTAssertEqual(
                publication?.dashboard.competitions,
                [CompetitionPresentation]()
            )
        }

        let durableListCount = await remoteProbe.durableListCount()
        let requestedProfiles = await realtimeSource.requestedProfiles()
        XCTAssertEqual(durableListCount, 5)
        XCTAssertEqual(requestedProfiles, [profile.id])

        await client.stop()
        let stopCount = await realtimeSource.stopCount()
        XCTAssertEqual(stopCount, 1)
        let terminalPublication = await iterator.next()
        XCTAssertNil(terminalPublication)
    }

    func testSupabaseAdapterUsesOnePrivateProfileChannelAndForwardsWakeups()
        async
    {
        let profileID = UUID(
            uuidString: "82000000-0000-4000-8000-000000000015"
        )!
        let driverProbe = SupabaseRealtimeDriverProbe()
        let client = CompetitionRealtimeClient.supabase(
            driver: driverProbe.driver
        )

        var iterator = (await client.wakeUps(profileID)).makeAsyncIterator()
        await driverProbe.waitForOpenCount(1)

        let requests = await driverProbe.requests()
        XCTAssertEqual(
            requests,
            [
                SupabaseCompetitionRealtimeDriver.Request(
                    topic: "profile:\(profileID.uuidString.lowercased())",
                    event: "competition_changed",
                    isPrivate: true
                )
            ]
        )

        await driverProbe.emitBroadcast(cursorHint: 42, opening: 0)
        await driverProbe.emitSubscribed(opening: 0)
        let broadcast = await iterator.next()
        let subscribed = await iterator.next()

        XCTAssertEqual(
            broadcast,
            CompetitionRealtimeWakeUp(
                reason: .broadcast,
                serverCursorHint: 42
            )
        )
        XCTAssertEqual(
            subscribed,
            CompetitionRealtimeWakeUp(
                reason: .subscribed,
                serverCursorHint: nil
            )
        )

        await client.stop()
        let stopCount = await driverProbe.stopCount()
        XCTAssertEqual(stopCount, 1)
        let terminal = await iterator.next()
        XCTAssertNil(terminal)
    }

    func testSupabaseAdapterReplacesProfileChannelAndDropsStaleCallbacks()
        async
    {
        let firstProfileID = UUID(
            uuidString: "83000000-0000-4000-8000-000000000015"
        )!
        let secondProfileID = UUID(
            uuidString: "84000000-0000-4000-8000-000000000015"
        )!
        let driverProbe = SupabaseRealtimeDriverProbe()
        let client = CompetitionRealtimeClient.supabase(
            driver: driverProbe.driver
        )

        var firstIterator = (await client.wakeUps(firstProfileID))
            .makeAsyncIterator()
        await driverProbe.waitForOpenCount(1)
        var secondIterator = (await client.wakeUps(secondProfileID))
            .makeAsyncIterator()
        await driverProbe.waitForOpenCount(2)

        let firstTerminal = await firstIterator.next()
        XCTAssertNil(firstTerminal)
        await driverProbe.emitBroadcast(cursorHint: 1, opening: 0)
        await driverProbe.emitBroadcast(cursorHint: 2, opening: 1)
        let secondWakeUp = await secondIterator.next()
        XCTAssertEqual(
            secondWakeUp,
            CompetitionRealtimeWakeUp(
                reason: .broadcast,
                serverCursorHint: 2
            )
        )

        let requests = await driverProbe.requests()
        XCTAssertEqual(requests.map(\.topic), [
            "profile:\(firstProfileID.uuidString.lowercased())",
            "profile:\(secondProfileID.uuidString.lowercased())",
        ])
        let replacementStopCount = await driverProbe.stopCount()
        XCTAssertEqual(replacementStopCount, 1)

        await client.stop()
        let finalStopCount = await driverProbe.stopCount()
        XCTAssertEqual(finalStopCount, 2)
    }

    func testSupabaseAdapterRetriesTransientSubscribeFailure() async {
        let profileID = UUID(
            uuidString: "85000000-0000-4000-8000-000000000015"
        )!
        let driverProbe = RetryingSupabaseRealtimeDriverProbe()
        let client = CompetitionRealtimeClient.supabase(
            driver: driverProbe.driver,
            retryDelay: { _ in }
        )

        var iterator = (await client.wakeUps(profileID)).makeAsyncIterator()
        let wakeUp = await iterator.next()

        XCTAssertEqual(
            wakeUp,
            CompetitionRealtimeWakeUp(
                reason: .subscribed,
                serverCursorHint: nil
            )
        )
        let attempts = await driverProbe.openCount()
        XCTAssertEqual(attempts, 2)
        await client.stop()
    }

    private func environment() throws -> CompetitionEnvironmentClient {
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 14,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        return .accelerated(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: try calendar.startOfDay(start),
                    monotonic: MonotonicInstant(
                        epochID: "task15-realtime",
                        nanoseconds: 1
                    )
                ),
                timeZoneIdentifier: calendar.timeZoneIdentifier,
                initialDays: try calendar.sevenDayWindow(
                    startingOn: start
                ).map { .missing(day: $0) },
                changes: []
            )
        )
    }
}

private actor RetryingSupabaseRealtimeDriverProbe {
    private var opens = 0

    nonisolated var driver: SupabaseCompetitionRealtimeDriver {
        SupabaseCompetitionRealtimeDriver(
            open: { [weak self] _, _, onSubscribed in
                guard let self else { throw CancellationError() }
                let attempt = await self.recordOpen()
                if attempt == 1 {
                    throw CompetitionRemoteFailure.retryableTransport
                }
                onSubscribed()
            },
            stop: {}
        )
    }

    func openCount() -> Int { opens }

    private func recordOpen() -> Int {
        opens += 1
        return opens
    }
}

private actor SupabaseRealtimeDriverProbe {
    private struct Opening {
        let request: SupabaseCompetitionRealtimeDriver.Request
        let onBroadcast: @Sendable (UInt64?) -> Void
        let onSubscribed: @Sendable () -> Void
    }

    private var openings: [Opening] = []
    private var stops = 0
    private var openWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    nonisolated var driver: SupabaseCompetitionRealtimeDriver {
        SupabaseCompetitionRealtimeDriver(
            open: { [weak self] request, onBroadcast, onSubscribed in
                await self?.recordOpen(
                    request,
                    onBroadcast: onBroadcast,
                    onSubscribed: onSubscribed
                )
            },
            stop: { [weak self] in
                await self?.recordStop()
            }
        )
    }

    func waitForOpenCount(_ count: Int) async {
        guard openings.count < count else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append((count, continuation))
        }
    }

    func requests() -> [SupabaseCompetitionRealtimeDriver.Request] {
        openings.map(\.request)
    }

    func stopCount() -> Int {
        stops
    }

    func emitBroadcast(cursorHint: UInt64?, opening: Int) {
        openings[opening].onBroadcast(cursorHint)
    }

    func emitSubscribed(opening: Int) {
        openings[opening].onSubscribed()
    }

    private func recordOpen(
        _ request: SupabaseCompetitionRealtimeDriver.Request,
        onBroadcast: @escaping @Sendable (UInt64?) -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) {
        openings.append(
            Opening(
                request: request,
                onBroadcast: onBroadcast,
                onSubscribed: onSubscribed
            )
        )
        let ready = openWaiters.filter { openings.count >= $0.count }
        openWaiters.removeAll { openings.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    private func recordStop() {
        stops += 1
    }
}

private actor RealtimeRemoteAPIProbe {
    private var listCount = 0

    func recordDurableList() {
        listCount += 1
    }

    func durableListCount() -> Int {
        listCount
    }
}

private actor RealtimeWakeupSource {
    private var continuation:
        AsyncStream<CompetitionRealtimeWakeUp>.Continuation?
    private var profiles: [UUID] = []
    private var stops = 0
    private var subscriptionWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated var client: CompetitionRealtimeClient {
        CompetitionRealtimeClient(
            wakeUps: { [weak self] profileID in
                guard let self else {
                    return AsyncStream { $0.finish() }
                }
                return await self.makeStream(profileID: profileID)
            },
            stop: { [weak self] in
                await self?.stop()
            }
        )
    }

    func waitForSubscription() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            subscriptionWaiters.append(continuation)
        }
    }

    func send(_ wakeup: CompetitionRealtimeWakeUp) {
        continuation?.yield(wakeup)
    }

    func requestedProfiles() -> [UUID] {
        profiles
    }

    func stopCount() -> Int {
        stops
    }

    private func makeStream(
        profileID: UUID
    ) -> AsyncStream<CompetitionRealtimeWakeUp> {
        let (stream, continuation) = AsyncStream<CompetitionRealtimeWakeUp>
            .makeStream()
        self.continuation?.finish()
        self.continuation = continuation
        profiles.append(profileID)
        let waiters = subscriptionWaiters
        subscriptionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return stream
    }

    private func stop() {
        stops += 1
        continuation?.finish()
        continuation = nil
    }
}

private extension CompetitionRemoteAPI {
    static func realtimeFixture(
        listCompetitions: @escaping @Sendable () async throws ->
            [CompetitionDescriptor]
    ) -> Self {
        Self(
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
            appendScoreRevision: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            submitAttestation: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            fetchChanges: { _, _ in
                throw CompetitionRemoteFailure.operationFailed
            },
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
