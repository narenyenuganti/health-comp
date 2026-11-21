import Foundation

struct CompetitionRealtimeWakeUp: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case broadcast
        case subscribed
    }

    let reason: Reason
    let serverCursorHint: UInt64?
}

struct CompetitionRealtimeClient: Sendable {
    var wakeUps: @Sendable (
        _ profileID: UUID
    ) async -> AsyncStream<CompetitionRealtimeWakeUp>
    var stop: @Sendable () async -> Void

    static let inert = Self(
        wakeUps: { _ in
            AsyncStream { continuation in
                continuation.finish()
            }
        },
        stop: {}
    )
}
