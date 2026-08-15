import Dependencies
import Foundation

struct CompetitionInviteLinkConfiguration: Equatable, Sendable {
    static let infoKey = "HEALTHCOMP_INVITE_HOST"

    let host: String?

    init(infoDictionary: [String: Any]) {
        guard let value = infoDictionary[Self.infoKey] as? String,
              CompetitionInviteHost.isValid(value)
        else {
            self.host = nil
            return
        }
        self.host = value
    }

    static let live = CompetitionInviteLinkConfiguration(
        infoDictionary: Bundle.main.infoDictionary ?? [:]
    )
}

struct CompetitionInviteLinkClient: Sendable {
    var makeShareLink: @Sendable (String) -> CompetitionInviteShareLink?
    var currentTimeZoneIdentifier: @Sendable () -> String
    var makeIdempotencyKey: @Sendable () -> UUID

    static func live(configuration: CompetitionInviteLinkConfiguration) -> Self {
        Self(
            makeShareLink: { rawToken in
                guard let host = configuration.host,
                      let token = CompetitionInviteClaimToken(
                        rawValue: rawToken
                      )
                else {
                    return nil
                }
                return CompetitionInviteShareLink(host: host, token: token)
            },
            currentTimeZoneIdentifier: { TimeZone.current.identifier },
            makeIdempotencyKey: { UUID() }
        )
    }
}

extension CompetitionInviteLinkClient: TestDependencyKey {
    static let testValue = CompetitionInviteLinkClient(
        makeShareLink: { _ in nil },
        currentTimeZoneIdentifier: { "UTC" },
        makeIdempotencyKey: {
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        }
    )
}

extension CompetitionInviteLinkClient: DependencyKey {
    static let liveValue = CompetitionInviteLinkClient.live(
        configuration: .live
    )
}

extension DependencyValues {
    var competitionInviteLinkClient: CompetitionInviteLinkClient {
        get { self[CompetitionInviteLinkClient.self] }
        set { self[CompetitionInviteLinkClient.self] = newValue }
    }
}

enum CompetitionRoutingEnvironment {
    static let liveHub = CompetitionRouteHub()

    static func makeLab() -> (
        hub: CompetitionRouteHub,
        client: CompetitionRoutingClient
    ) {
        let hub = CompetitionRouteHub()
        return (hub, .live(hub: hub))
    }
}

struct CompetitionRouteEnvelope: Equatable, Sendable {
    let sequence: UInt64
    let route: CompetitionRoute
}

final class CompetitionRouteHub: @unchecked Sendable {
    private struct State {
        var sequence: UInt64
        var pendingByKind: [
            CompetitionRoute.Kind: CompetitionRouteEnvelope
        ] = [:]
        var continuations: [
            UUID: AsyncStream<CompetitionRouteEnvelope>.Continuation
        ] = [:]
        var isFinished = false
    }

    private let lock = NSRecursiveLock()
    private var state: State

    init(initialSequence: UInt64 = 0) {
        self.state = State(sequence: initialSequence)
    }

    func stream() -> AsyncStream<CompetitionRouteEnvelope> {
        let token = UUID()
        return AsyncStream { continuation in
            lock.withLock {
                continuation.onTermination = { [weak self] _ in
                    self?.removeContinuation(token)
                }
                if state.isFinished {
                    continuation.finish()
                    return
                }
                state.continuations[token] = continuation
                for pending in state.pendingByKind.values.sorted(
                    by: { $0.sequence < $1.sequence }
                ) {
                    continuation.yield(pending)
                }
            }
        }
    }

    @discardableResult
    func enqueue(_ route: CompetitionRoute) -> CompetitionRouteEnvelope? {
        lock.withLock {
            guard !state.isFinished else { return nil }
            guard state.sequence < UInt64.max else {
                finishLocked()
                return nil
            }
            state.sequence += 1
            let envelope = CompetitionRouteEnvelope(
                sequence: state.sequence,
                route: route
            )
            state.pendingByKind[route.kind] = envelope
            for continuation in state.continuations.values {
                continuation.yield(envelope)
            }
            return envelope
        }
    }

    func consume(sequence: UInt64) {
        lock.withLock {
            guard let kind = state.pendingByKind.first(where: {
                $0.value.sequence == sequence
            })?.key else {
                return
            }
            state.pendingByKind[kind] = nil
        }
    }

    func finish() {
        lock.withLock { finishLocked() }
    }

    private func finishLocked() {
        guard !state.isFinished else { return }
        state.isFinished = true
        state.pendingByKind.removeAll()
        let continuations = Array(state.continuations.values)
        state.continuations.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeContinuation(_ token: UUID) {
        lock.withLock {
            state.continuations[token] = nil
        }
    }
}

struct CompetitionRoutingClient: Sendable {
    var routes: @Sendable () -> AsyncStream<CompetitionRouteEnvelope>
    var enqueue: @Sendable (_ route: CompetitionRoute) -> Void
    var consume: @Sendable (_ sequence: UInt64) -> Void

    static func live(hub: CompetitionRouteHub) -> Self {
        Self(
            routes: { hub.stream() },
            enqueue: { route in _ = hub.enqueue(route) },
            consume: { sequence in hub.consume(sequence: sequence) }
        )
    }

    static func inert() -> Self {
        Self(
            routes: { AsyncStream { $0.finish() } },
            enqueue: { _ in },
            consume: { _ in }
        )
    }
}

extension CompetitionRoutingClient: TestDependencyKey {
    static let testValue = CompetitionRoutingClient.inert()
}

extension CompetitionRoutingClient: DependencyKey {
    static let liveValue = CompetitionRoutingClient.live(
        hub: CompetitionRoutingEnvironment.liveHub
    )
}

extension DependencyValues {
    var competitionRoutingClient: CompetitionRoutingClient {
        get { self[CompetitionRoutingClient.self] }
        set { self[CompetitionRoutingClient.self] = newValue }
    }
}
