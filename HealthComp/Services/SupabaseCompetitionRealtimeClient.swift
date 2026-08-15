import Foundation
import Supabase

struct SupabaseCompetitionRealtimeDriver: Sendable {
    struct Request: Equatable, Sendable {
        let topic: String
        let event: String
        let isPrivate: Bool
    }

    var open: @Sendable (
        _ request: Request,
        _ onBroadcast: @escaping @Sendable (UInt64?) -> Void,
        _ onSubscribed: @escaping @Sendable () -> Void
    ) async throws -> Void
    var stop: @Sendable () async -> Void
}

extension CompetitionRealtimeClient {
    static func supabase(provider: SupabaseClientProvider) -> Self {
        supabase(driver: .live(provider: provider))
    }

    static func supabase(
        driver: SupabaseCompetitionRealtimeDriver,
        retryDelay: @escaping @Sendable (Int) async throws -> Void = {
            failureCount in
            let exponent = min(failureCount, 6)
            let nanoseconds = UInt64(250_000_000) << UInt64(exponent)
            try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
        }
    ) -> Self {
        let box = SupabaseCompetitionRealtimeClientBox(
            driver: driver,
            retryDelay: retryDelay
        )
        return Self(
            wakeUps: { profileID in
                await box.stream(profileID: profileID)
            },
            stop: {
                await box.stop()
            }
        )
    }
}

private actor SupabaseCompetitionRealtimeClientBox {
    private let driver: SupabaseCompetitionRealtimeDriver
    private let retryDelay: @Sendable (Int) async throws -> Void

    private var generation: UInt64 = 0
    private var openingTask: Task<Void, Never>?
    private var continuation:
        AsyncStream<CompetitionRealtimeWakeUp>.Continuation?

    init(
        driver: SupabaseCompetitionRealtimeDriver,
        retryDelay: @escaping @Sendable (Int) async throws -> Void
    ) {
        self.driver = driver
        self.retryDelay = retryDelay
    }

    func stream(
        profileID: UUID
    ) async -> AsyncStream<CompetitionRealtimeWakeUp> {
        await stopCurrent()
        generation &+= 1
        let activeGeneration = generation
        let (stream, continuation) = AsyncStream<CompetitionRealtimeWakeUp>
            .makeStream()
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.terminate(generation: activeGeneration)
            }
        }
        self.continuation = continuation

        let request = SupabaseCompetitionRealtimeDriver.Request(
            topic: "profile:\(profileID.uuidString.lowercased())",
            event: "competition_changed",
            isPrivate: true
        )
        openingTask = Task { [driver, retryDelay] in
            var failureCount = 0
            while !Task.isCancelled {
                do {
                    try await driver.open(
                        request,
                        { cursorHint in
                            continuation.yield(
                                CompetitionRealtimeWakeUp(
                                    reason: .broadcast,
                                    serverCursorHint: cursorHint
                                )
                            )
                        },
                        {
                            continuation.yield(
                                CompetitionRealtimeWakeUp(
                                    reason: .subscribed,
                                    serverCursorHint: nil
                                )
                            )
                        }
                    )
                    return
                } catch is CancellationError {
                    return
                } catch {
                    await driver.stop()
                    do {
                        try await retryDelay(failureCount)
                    } catch {
                        return
                    }
                    failureCount = min(failureCount + 1, 6)
                }
            }
        }
        return stream
    }

    func stop() async {
        await stopCurrent()
    }

    private func terminate(generation: UInt64) async {
        guard generation == self.generation, continuation != nil else {
            return
        }
        await stopCurrent()
    }

    private func stopCurrent() async {
        guard openingTask != nil || continuation != nil else { return }
        generation &+= 1
        let openingTask = self.openingTask
        let continuation = self.continuation
        self.openingTask = nil
        self.continuation = nil
        openingTask?.cancel()
        continuation?.finish()
        await driver.stop()
        await openingTask?.value
    }
}

private extension SupabaseCompetitionRealtimeDriver {
    static func live(provider: SupabaseClientProvider) -> Self {
        let box = SupabaseCompetitionRealtimeDriverBox(provider: provider)
        return Self(
            open: { request, onBroadcast, onSubscribed in
                try await box.open(
                    request,
                    onBroadcast: onBroadcast,
                    onSubscribed: onSubscribed
                )
            },
            stop: {
                await box.stop()
            }
        )
    }
}

private actor SupabaseCompetitionRealtimeDriverBox {
    private struct ActiveChannel {
        let client: SupabaseClient
        let channel: RealtimeChannelV2
        let broadcastTask: Task<Void, Never>
        let statusTask: Task<Void, Never>
    }

    private let provider: SupabaseClientProvider
    private var cachedClient: SupabaseClient?
    private var activeChannel: ActiveChannel?

    init(provider: SupabaseClientProvider) {
        self.provider = provider
    }

    func open(
        _ request: SupabaseCompetitionRealtimeDriver.Request,
        onBroadcast: @escaping @Sendable (UInt64?) -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        await stop()
        try Task.checkCancellation()
        let client = try client()
        let channel = client.realtimeV2.channel(request.topic) { config in
            config.isPrivate = request.isPrivate
        }

        // Both streams are registered before subscription. In particular,
        // broadcastStream installs its callback synchronously.
        let broadcasts = channel.broadcastStream(event: request.event)
        let statuses = channel.statusChange
        let broadcastTask = Task {
            for await payload in broadcasts {
                guard !Task.isCancelled else { return }
                onBroadcast(Self.cursorHint(from: payload))
            }
        }
        let statusTask = Task {
            for await status in statuses {
                guard !Task.isCancelled else { return }
                if case .subscribed = status {
                    onSubscribed()
                }
            }
        }
        activeChannel = ActiveChannel(
            client: client,
            channel: channel,
            broadcastTask: broadcastTask,
            statusTask: statusTask
        )

        do {
            await client.realtimeV2.setAuth()
            try Task.checkCancellation()
            try await channel.subscribeWithError()
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        guard let activeChannel else { return }
        self.activeChannel = nil
        activeChannel.broadcastTask.cancel()
        activeChannel.statusTask.cancel()
        await activeChannel.client.realtimeV2.removeChannel(
            activeChannel.channel
        )
        await activeChannel.broadcastTask.value
        await activeChannel.statusTask.value
    }

    private func client() throws -> SupabaseClient {
        if let cachedClient { return cachedClient }
        let client = try provider.client()
        cachedClient = client
        return client
    }

    private nonisolated static func cursorHint(
        from message: JSONObject
    ) -> UInt64? {
        let payload = message["payload"]?.objectValue ?? message
        guard let value = payload["server_cursor_hint"] else { return nil }
        if let integer = value.intValue, integer >= 0 {
            return UInt64(integer)
        }
        if let string = value.stringValue {
            return UInt64(string)
        }
        return nil
    }
}
