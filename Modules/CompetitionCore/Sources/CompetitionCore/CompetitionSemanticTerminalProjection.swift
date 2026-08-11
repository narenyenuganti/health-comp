import Foundation

/// A non-persisted, transport-independent terminal projection for comparing
/// executions of the same competition. It deliberately excludes monotonic
/// timing metadata and OS notification delivery state.
public struct CompetitionSemanticTerminalProjection:
    Codable,
    Equatable,
    Sendable
{
    public struct Day: Codable, Equatable, Sendable {
        public let ordinal: Int
        public let acceptedPoints: Double
        public let acceptedActivityContentFingerprint: String

        public init(
            ordinal: Int,
            acceptedPoints: Double,
            acceptedActivityContentFingerprint: String
        ) {
            self.ordinal = ordinal
            self.acceptedPoints = acceptedPoints
            self.acceptedActivityContentFingerprint =
                acceptedActivityContentFingerprint
        }
    }

    public enum ProjectionError: Error, Equatable, Sendable {
        case competitionIsNotCompleted
        case missingSchedule
        case missingOpponentPlan
        case ledgerIsNotFrozen
        case incompleteFrozenLedger
    }

    public let lifecycle: String
    public let competitionID: String
    public let scheduleTimeZoneIdentifier: String
    public let startDay: CompetitionDay
    public let opponentPlanContentIdentity: String
    public let opponentPlanCommitmentHex: String
    public let completedAt: Date
    public let outcome: CompetitionOutcome
    public let basis: FinalizationBasis
    public let userPoints: Double
    public let opponentPoints: Double
    public let ledgerIsFrozen: Bool
    public let scoringPolicyIdentity: String
    public let downwardRevisionPolicy: DownwardRevisionPolicy
    public let days: [Day]

    public init(projection: CompetitionReplayProjection) throws {
        guard case let .completed(completed) = projection.competition.lifecycle
        else {
            throw ProjectionError.competitionIsNotCompleted
        }
        guard let schedule = projection.competition.schedule else {
            throw ProjectionError.missingSchedule
        }
        guard let opponentPlan = projection.competition.opponentPlan else {
            throw ProjectionError.missingOpponentPlan
        }
        guard projection.scoreLedger.isFrozen else {
            throw ProjectionError.ledgerIsNotFrozen
        }
        let days = try (1...7).map { ordinal -> Day in
            guard let accepted = projection.scoreLedger
                .entry(forDayOrdinal: ordinal)?.acceptedScore
            else {
                throw ProjectionError.incompleteFrozenLedger
            }
            return Day(
                ordinal: ordinal,
                acceptedPoints: accepted.points,
                acceptedActivityContentFingerprint:
                    accepted.activityContentFingerprint.rawValue
            )
        }

        self.lifecycle = "completed"
        self.competitionID = projection.competition.id.rawValue.uuidString
            .lowercased()
        self.scheduleTimeZoneIdentifier = schedule.calendar.timeZoneIdentifier
        self.startDay = schedule.startDay
        self.opponentPlanContentIdentity = opponentPlan.contentIdentity
        self.opponentPlanCommitmentHex = opponentPlan.commitmentHex
        self.completedAt = completed.completedAt
        self.outcome = completed.outcome
        self.basis = completed.basis
        self.userPoints = completed.snapshot.userPoints
        self.opponentPoints = completed.snapshot.opponentPoints
        self.ledgerIsFrozen = true
        self.scoringPolicyIdentity = projection.scoreLedger.scoringPolicy
            .identity.rawValue
        self.downwardRevisionPolicy = projection.scoreLedger
            .downwardRevisionPolicy
        self.days = days
    }
}
