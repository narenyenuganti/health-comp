import Foundation

/// A single score accepted by the server for a remote participant. It carries
/// the accepted result, never local Health data or source fingerprints.
public struct RemoteAcceptedScoreRow: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidOrdinal, invalidAcceptedScore, invalidAvailability, invalidDigest, invalidRevision, invalidServerSequence, invalidPolicy
    }

    public let ordinal: Int
    public let acceptedCentiPoints: Int?
    public let availabilityReason: String?
    public let wireContentSHA256: String
    public let scoringPolicyIdentity: String
    public let clientRevision: Int64
    public let serverSequence: Int64

    public init(
        ordinal: Int,
        acceptedCentiPoints: Int?,
        availabilityReason: String?,
        wireContentSHA256: String,
        scoringPolicyIdentity: String = RemoteScoringWireV1.policyIdentity,
        clientRevision: Int64,
        serverSequence: Int64
    ) throws {
        guard (1...7).contains(ordinal) else { throw ValidationError.invalidOrdinal }
        guard scoringPolicyIdentity == RemoteScoringWireV1.policyIdentity else { throw ValidationError.invalidPolicy }
        guard wireContentSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw ValidationError.invalidDigest }
        guard clientRevision > 0 else { throw ValidationError.invalidRevision }
        guard serverSequence > 0 else { throw ValidationError.invalidServerSequence }
        if let acceptedCentiPoints {
            guard (0...60_000).contains(acceptedCentiPoints), availabilityReason == nil else { throw ValidationError.invalidAcceptedScore }
        } else {
            guard let availabilityReason, Self.closedUnavailableReasons.contains(availabilityReason) else { throw ValidationError.invalidAvailability }
        }
        self.ordinal = ordinal
        self.acceptedCentiPoints = acceptedCentiPoints
        self.availabilityReason = availabilityReason
        self.wireContentSHA256 = wireContentSHA256
        self.scoringPolicyIdentity = scoringPolicyIdentity
        self.clientRevision = clientRevision
        self.serverSequence = serverSequence
    }

    private enum CodingKeys: String, CodingKey {
        case ordinal, acceptedCentiPoints, availabilityReason, wireContentSHA256, scoringPolicyIdentity, clientRevision, serverSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            ordinal: container.decode(Int.self, forKey: .ordinal),
            acceptedCentiPoints: container.decodeIfPresent(Int.self, forKey: .acceptedCentiPoints),
            availabilityReason: container.decodeIfPresent(String.self, forKey: .availabilityReason),
            wireContentSHA256: container.decode(String.self, forKey: .wireContentSHA256),
            scoringPolicyIdentity: container.decode(String.self, forKey: .scoringPolicyIdentity),
            clientRevision: container.decode(Int64.self, forKey: .clientRevision),
            serverSequence: container.decode(Int64.self, forKey: .serverSequence)
        )
    }

    private static let closedUnavailableReasons: Set<String> = [
        "sourceDataUnavailable", "unsupportedActivityConfiguration", "invalidSourceData",
        "missingMoveValue", "missingMoveGoal", "nonPositiveMoveGoal",
        "missingExerciseValue", "missingExerciseGoal", "nonPositiveExerciseGoal",
        "missingStandOrRollValue", "missingStandOrRollGoal", "nonPositiveStandOrRollGoal",
        "summaryPaused", "summaryPauseStateUnknown", "invalidNumericCalculation",
    ]
}

/// The authoritative, privacy-minimal remote score state for one participant.
/// Rows may arrive out of order by server sequence, but client revisions are
/// participant-global and may only advance once a server accepts them.
public struct RemoteScoreLedger: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidCompetitionID, invalidAcceptedSchedule, staleRevision, revisionCollision, serverSequenceCollision, divergentDuplicate, incompleteWindow, invalidTotal
    }

    public let competitionID: CompetitionID
    public let participant: RemoteParticipant
    public let acceptedSchedule: CompetitionSchedule
    public let scoringPolicyIdentity: String
    /// Persisted so old exact replays remain idempotent and server cursor
    /// collisions remain detectable after a later revision supersedes a day.
    private var acceptedHistory: [RemoteAcceptedScoreRow]

    public init(
        competitionID: CompetitionID,
        participant: RemoteParticipant,
        acceptedSchedule: CompetitionSchedule,
        scoringPolicyIdentity: String = RemoteScoringWireV1.policyIdentity,
        acceptedRows: [RemoteAcceptedScoreRow] = []
    ) throws {
        guard competitionID.rawValue != Self.nilUUID else { throw ValidationError.invalidCompetitionID }
        guard scoringPolicyIdentity == RemoteScoringWireV1.policyIdentity else { throw RemoteAcceptedScoreRow.ValidationError.invalidPolicy }
        do {
            _ = try acceptedSchedule.calendar.sevenDayWindow(startingOn: acceptedSchedule.startDay)
        } catch {
            throw ValidationError.invalidAcceptedSchedule
        }
        self.competitionID = competitionID
        self.participant = participant
        self.acceptedSchedule = acceptedSchedule
        self.scoringPolicyIdentity = scoringPolicyIdentity
        self.acceptedHistory = []
        for row in acceptedRows.sorted(by: { $0.clientRevision < $1.clientRevision }) {
            _ = try accept(row)
        }
    }

    /// Adds a server-accepted row. `false` means that the exact row was already
    /// known; divergent duplicates and reused revisions are rejected.
    @discardableResult
    public mutating func accept(_ row: RemoteAcceptedScoreRow) throws -> Bool {
        guard row.scoringPolicyIdentity == scoringPolicyIdentity else { throw RemoteAcceptedScoreRow.ValidationError.invalidPolicy }
        if acceptedHistory.contains(row) { return false }
        if acceptedHistory.contains(where: { $0.serverSequence == row.serverSequence }) {
            throw ValidationError.serverSequenceCollision
        }
        if let sameRevision = acceptedHistory.first(where: { $0.clientRevision == row.clientRevision }) {
            if sameRevision.ordinal == row.ordinal { throw ValidationError.divergentDuplicate }
            throw ValidationError.revisionCollision
        }
        if let latestRevision = acceptedHistory.map(\.clientRevision).max(), row.clientRevision < latestRevision {
            throw ValidationError.staleRevision
        }
        acceptedHistory.append(row)
        guard totalAcceptedCentiPoints <= 420_000 else { throw ValidationError.invalidTotal }
        return true
    }

    /// Pure lookup only. Calendar/lifecycle visibility gates are applied later.
    public func visibleEntry(forActiveDayOrdinal ordinal: Int) throws -> RemoteAcceptedScoreRow? {
        guard (1...7).contains(ordinal) else { throw RemoteAcceptedScoreRow.ValidationError.invalidOrdinal }
        return acceptedHistory
            .filter { $0.ordinal == ordinal }
            .max(by: { $0.clientRevision < $1.clientRevision })
    }

    public var totalAcceptedCentiPoints: Int {
        (1...7).compactMap { try? visibleEntry(forActiveDayOrdinal: $0)?.acceptedCentiPoints }.reduce(0, +)
    }

    public func frozenWindow() throws -> [RemoteFinalizationDayV1] {
        try (1...7).map { ordinal in
            guard let row = try visibleEntry(forActiveDayOrdinal: ordinal) else { throw ValidationError.incompleteWindow }
            if let points = row.acceptedCentiPoints {
                return try RemoteFinalizationDayV1(ordinal: ordinal, status: .points, source: .acceptedRevision, points: points, reason: nil, wireContentSHA256: row.wireContentSHA256, clientRevision: row.clientRevision, serverSequence: row.serverSequence)
            }
            return try RemoteFinalizationDayV1(ordinal: ordinal, status: .unavailable, source: .acceptedRevision, points: nil, reason: row.availabilityReason, wireContentSHA256: row.wireContentSHA256, clientRevision: row.clientRevision, serverSequence: row.serverSequence)
        }
    }

    public func windowCommitment() throws -> String {
        try RemoteFinalizationWireV1.windowCommitment(competitionID: competitionID.rawValue, participantID: participant.profileID, days: frozenWindow())
    }

    private enum CodingKeys: String, CodingKey {
        case competitionID, participant, acceptedSchedule, scoringPolicyIdentity, acceptedHistory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            competitionID: container.decode(CompetitionID.self, forKey: .competitionID),
            participant: container.decode(RemoteParticipant.self, forKey: .participant),
            acceptedSchedule: container.decode(CompetitionSchedule.self, forKey: .acceptedSchedule),
            scoringPolicyIdentity: container.decode(String.self, forKey: .scoringPolicyIdentity),
            acceptedRows: container.decode([RemoteAcceptedScoreRow].self, forKey: .acceptedHistory)
        )
    }

    private static let nilUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
