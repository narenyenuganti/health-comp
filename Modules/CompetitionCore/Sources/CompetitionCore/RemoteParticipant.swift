import Foundation

/// A remote competitor's immutable backend profile identity.
///
/// Mutable presentation data intentionally belongs to the application layer,
/// not to replayable competition state.
public struct RemoteParticipant: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable { case invalidProfileID }

    public let profileID: UUID

    public init(profileID: UUID) throws {
        guard profileID != Self.nilUUID else { throw ValidationError.invalidProfileID }
        self.profileID = profileID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(profileID: container.decode(UUID.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(profileID)
    }

    private static let nilUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

/// The counterparty model to be introduced by the v4 remote configuration
/// event. This type is deliberately not referenced from v1-v3 lifecycle data.
public enum CompetitionCounterparty: Codable, Equatable, Sendable {
    case simulated(OpponentPlan)
    case remote(RemoteParticipant)
}
