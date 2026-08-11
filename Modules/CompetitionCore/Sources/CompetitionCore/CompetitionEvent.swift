import Foundation

public struct FinalizationRecord: Codable, Equatable, Sendable {
    public let snapshot: FinalScoreSnapshot
    public let basis: FinalizationBasis
    public let policy: FinalizationPolicy
    public let decisionAt: Date
    public let reconciliationRevision: UInt64
    public let eligibleAttemptID: String

    internal init(authorization: FinalizationAuthorization) {
        self.snapshot = authorization.snapshot
        self.basis = authorization.basis
        self.policy = authorization.policy
        self.decisionAt = authorization.decisionAt
        self.reconciliationRevision = authorization.reconciliationRevision
        self.eligibleAttemptID = authorization.eligibleAttemptID
    }
}

public enum CompetitionEventKind: Codable, Equatable, Sendable {
    case invitationAccepted(AcceptedCompetitionConfiguration)
    case invitationDeclined
    case invitationExpired
    case competitionStarted
    case dayClosed(Int)
    case finalDayStarted
    case tallyStarted
    case finalReadRecorded(FinalReadRecord)
    case competitionFinalized(FinalizationRecord)
    case competitionArchived

    internal var semanticKey: String {
        switch self {
        case .invitationAccepted:
            return "invitation-accepted"
        case .invitationDeclined:
            return "invitation-declined"
        case .invitationExpired:
            return "invitation-expired"
        case .competitionStarted:
            return "competition-started"
        case let .dayClosed(day):
            return "day-\(day)-closed"
        case .finalDayStarted:
            return "final-day-started"
        case .tallyStarted:
            return "tally-started"
        case let .finalReadRecorded(record):
            return "final-read-\(record.evidence.attemptID)"
        case .competitionFinalized:
            return "competition-finalized"
        case .competitionArchived:
            return "competition-archived"
        }
    }
}

public struct CompetitionEvent: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case semanticIDMismatch(expected: String, actual: String)
    }

    public let id: String
    public let competitionID: CompetitionID
    public let occurredAt: Date
    public let kind: CompetitionEventKind

    internal init(
        competitionID: CompetitionID,
        occurredAt: Date,
        kind: CompetitionEventKind
    ) {
        self.id = Self.semanticID(
            competitionID: competitionID,
            eventKey: kind.semanticKey
        )
        self.competitionID = competitionID
        self.occurredAt = occurredAt
        self.kind = kind
    }

    public static func semanticID(
        competitionID: CompetitionID,
        eventKey: String
    ) -> String {
        "competition-event:v1:\(competitionID.rawValue.uuidString.lowercased()):\(eventKey)"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case competitionID
        case occurredAt
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persistedID = try container.decode(String.self, forKey: .id)
        let competitionID = try container.decode(
            CompetitionID.self,
            forKey: .competitionID
        )
        let occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        let kind = try container.decode(
            CompetitionEventKind.self,
            forKey: .kind
        )
        let expectedID = Self.semanticID(
            competitionID: competitionID,
            eventKey: kind.semanticKey
        )
        // This versioned ID validates replay/dedupe identity, not payload
        // integrity; Task 5 defines trusted local persistence and recovery.
        guard persistedID == expectedID else {
            throw ValidationError.semanticIDMismatch(
                expected: expectedID,
                actual: persistedID
            )
        }
        self.init(
            competitionID: competitionID,
            occurredAt: occurredAt,
            kind: kind
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(competitionID, forKey: .competitionID)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(kind, forKey: .kind)
    }
}
