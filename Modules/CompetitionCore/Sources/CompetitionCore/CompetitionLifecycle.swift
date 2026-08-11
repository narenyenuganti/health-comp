import Foundation

public struct CompetitionID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public enum InvitationDirection: String, Codable, Equatable, Sendable {
    case incoming
    case outgoing
}

public struct PendingInvitation: Codable, Equatable, Sendable {
    public let direction: InvitationDirection
    public let createdAt: Date
    public let expiresAt: Date?

    public init(direction: InvitationDirection, createdAt: Date, expiresAt: Date?) {
        self.direction = direction
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct CompetitionSchedule: Codable, Equatable, Sendable {
    public let calendar: CompetitionCalendar
    public let startDay: CompetitionDay

    public init(calendar: CompetitionCalendar, startDay: CompetitionDay) {
        self.calendar = calendar
        self.startDay = startDay
    }
}

public struct AcceptedCompetitionConfiguration: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case scheduleDoesNotMatchOpponentPlan
    }

    public let schedule: CompetitionSchedule
    public let opponentPlan: OpponentPlan

    public init(
        schedule: CompetitionSchedule,
        opponentPlan: OpponentPlan
    ) throws {
        guard schedule == opponentPlan.schedule else {
            throw ValidationError.scheduleDoesNotMatchOpponentPlan
        }
        self.schedule = schedule
        self.opponentPlan = opponentPlan
    }

    private enum CodingKeys: String, CodingKey {
        case schedule
        case opponentPlan
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                schedule: container.decode(
                    CompetitionSchedule.self,
                    forKey: .schedule
                ),
                opponentPlan: container.decode(
                    OpponentPlan.self,
                    forKey: .opponentPlan
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .schedule,
                in: container,
                debugDescription: "Accepted configuration is inconsistent: \(error)"
            )
        }
    }
}

public struct TallyingCompetition: Codable, Equatable, Sendable {
    public let startedAt: Date
    public internal(set) var reconciliation: TallyReconciliation

    public init(
        startedAt: Date,
        reconciliation: TallyReconciliation = TallyReconciliation()
    ) {
        self.startedAt = startedAt
        self.reconciliation = reconciliation
    }
}

public struct CompetitionActiveDay: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case outsideActiveRange(Int)
    }

    public let ordinal: Int

    public init(_ ordinal: Int) throws {
        guard (1...6).contains(ordinal) else {
            throw ValidationError.outsideActiveRange(ordinal)
        }
        self.ordinal = ordinal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ordinal)
    }
}

public enum CompetitionOutcome: String, Codable, Equatable, Sendable {
    case win
    case loss
    case tie
}

public enum FinalizationBasis: String, Codable, Equatable, Sendable {
    case stableAcrossPostBoundaryReads
    case bestAvailable
}

public struct FinalScoreSnapshot: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidUserPoints(Double)
        case invalidOpponentPoints(Double)
    }

    public static let maximumPoints = 4_200.0

    public let userPoints: Double
    public let opponentPoints: Double

    public init(userPoints: Double, opponentPoints: Double) throws {
        guard userPoints.isFinite, (0...Self.maximumPoints).contains(userPoints) else {
            throw ValidationError.invalidUserPoints(userPoints)
        }
        guard opponentPoints.isFinite,
              (0...Self.maximumPoints).contains(opponentPoints)
        else {
            throw ValidationError.invalidOpponentPoints(opponentPoints)
        }
        self.userPoints = userPoints
        self.opponentPoints = opponentPoints
    }

    public var outcome: CompetitionOutcome {
        if userPoints > opponentPoints { return .win }
        if userPoints < opponentPoints { return .loss }
        return .tie
    }

    private enum CodingKeys: String, CodingKey {
        case userPoints
        case opponentPoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            userPoints: container.decode(Double.self, forKey: .userPoints),
            opponentPoints: container.decode(Double.self, forKey: .opponentPoints)
        )
    }
}

public struct CompletedCompetition: Codable, Equatable, Sendable {
    public let snapshot: FinalScoreSnapshot
    public let basis: FinalizationBasis
    public let completedAt: Date

    public var outcome: CompetitionOutcome {
        snapshot.outcome
    }

    public init(
        snapshot: FinalScoreSnapshot,
        basis: FinalizationBasis,
        completedAt: Date
    ) {
        self.snapshot = snapshot
        self.basis = basis
        self.completedAt = completedAt
    }
}

public struct ArchivedCompetition: Codable, Equatable, Sendable {
    public let completed: CompletedCompetition
    public let archivedAt: Date

    public init(completed: CompletedCompetition, archivedAt: Date) {
        self.completed = completed
        self.archivedAt = archivedAt
    }
}

public enum CompetitionLifecycle: Codable, Equatable, Sendable {
    case pendingInvitation(PendingInvitation)
    case declined(at: Date)
    case expired(at: Date)
    case scheduled
    case active(day: CompetitionActiveDay)
    case endsToday
    case tallying(TallyingCompetition)
    case completed(CompletedCompetition)
    case archived(ArchivedCompetition)
}

public struct Competition: Equatable, Sendable {
    public let id: CompetitionID
    public internal(set) var lifecycle: CompetitionLifecycle
    public internal(set) var schedule: CompetitionSchedule?
    public internal(set) var opponentPlan: OpponentPlan?
    public internal(set) var appliedEventIDs: [String]

    public static func pending(
        id: CompetitionID,
        direction: InvitationDirection,
        createdAt: Date,
        expiresAt: Date?
    ) -> Self {
        Self(
            id: id,
            lifecycle: .pendingInvitation(
                PendingInvitation(
                    direction: direction,
                    createdAt: createdAt,
                    expiresAt: expiresAt
                )
            ),
            schedule: nil,
            opponentPlan: nil,
            appliedEventIDs: []
        )
    }

    internal init(
        id: CompetitionID,
        lifecycle: CompetitionLifecycle,
        schedule: CompetitionSchedule?,
        opponentPlan: OpponentPlan?,
        appliedEventIDs: [String]
    ) {
        self.id = id
        self.lifecycle = lifecycle
        self.schedule = schedule
        self.opponentPlan = opponentPlan
        self.appliedEventIDs = appliedEventIDs
    }
}
