import Foundation

/// A non-persisted, transport-independent terminal projection for comparing
/// executions of the same competition. It deliberately excludes monotonic
/// timing metadata and OS notification delivery state.
public struct CompetitionSemanticTerminalProjection: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public let ordinal: Int
        public let acceptedPoints: Double
        public let acceptedActivityContentFingerprint: String
    }

    /// A privacy-safe representation of a server-confirmed day.  In
    /// particular, it intentionally excludes wire content hashes and local
    /// HealthKit fingerprints.
    public struct RemoteDay: Codable, Equatable, Sendable {
        public let profileID: String
        public let ordinal: Int
        public let status: SharedResultStatus
        public let source: SharedResultSource
        public let centiPoints: Int?
        public let reason: String?

        /// Kept as a non-encoded compatibility affordance: callers can make
        /// the privacy boundary explicit without exposing the hash.
        public let wireContentSHA256: String? = nil

        private enum CodingKeys: String, CodingKey {
            case profileID, ordinal, status, source, centiPoints, reason
        }
    }

    public enum CounterpartyKind: String, Codable, Equatable, Sendable {
        case simulated
        case remote
    }

    public enum ProjectionError: Error, Equatable, Sendable {
        case competitionIsNotCompleted, missingSchedule, missingOpponentPlan
        case ledgerIsNotFrozen, incompleteFrozenLedger, missingRemoteConfiguration
        case missingSharedResult
    }

    // These simulated fields deliberately retain their original types and
    // coding keys. The custom encoder below emits exactly this old shape for
    // simulated traces, so their golden terminal bytes remain unchanged.
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

    public let counterpartyKind: CounterpartyKind
    public let remoteOwnerProfileID: String?
    public let remoteParticipantProfileID: String?
    public let remoteOwnerWindowCommitment: String?
    public let remoteParticipantWindowCommitment: String?
    public let remoteResultHash: String?
    public let remoteDays: [RemoteDay]

    public init(projection: CompetitionReplayProjection) throws {
        guard case let .completed(completed) = projection.competition.lifecycle else { throw ProjectionError.competitionIsNotCompleted }
        guard let schedule = projection.competition.schedule else { throw ProjectionError.missingSchedule }
        self.lifecycle = "completed"
        self.competitionID = projection.competition.id.rawValue.uuidString.lowercased()
        self.scheduleTimeZoneIdentifier = schedule.calendar.timeZoneIdentifier
        self.startDay = schedule.startDay
        self.completedAt = completed.completedAt
        self.outcome = completed.outcome
        self.basis = completed.basis
        self.userPoints = completed.snapshot.userPoints
        self.opponentPoints = completed.snapshot.opponentPoints

        if let configuration = projection.competition.remoteConfiguration {
            guard let result = projection.sharedResult else { throw ProjectionError.missingSharedResult }
            let ownerWindow = try result.window(for: configuration.owner)
            let remoteWindow = try result.window(for: configuration.remote)
            self.opponentPlanContentIdentity = ""
            self.opponentPlanCommitmentHex = ""
            // A shared server result is the immutable terminal evidence for a
            // remote competition.  This is intentionally true even though the
            // simulated `ScoreLedger` is not the source of those rows.
            self.ledgerIsFrozen = true
            self.scoringPolicyIdentity = configuration.scoringPolicyIdentity
            self.downwardRevisionPolicy = projection.scoreLedger.downwardRevisionPolicy
            self.days = []
            self.counterpartyKind = .remote
            self.remoteOwnerProfileID = configuration.owner.profileID.uuidString.lowercased()
            self.remoteParticipantProfileID = configuration.remote.profileID.uuidString.lowercased()
            self.remoteOwnerWindowCommitment = ownerWindow.windowCommitment
            self.remoteParticipantWindowCommitment = remoteWindow.windowCommitment
            self.remoteResultHash = result.resultHash
            self.remoteDays = result.windows.flatMap { window in
                window.days.map { day in
                    RemoteDay(profileID: window.participant.profileID.uuidString.lowercased(), ordinal: day.ordinal, status: day.status, source: day.source, centiPoints: day.centiPoints, reason: day.reason)
                }
            }
            return
        }

        guard let opponentPlan = projection.competition.opponentPlan else { throw ProjectionError.missingOpponentPlan }
        guard projection.scoreLedger.isFrozen else { throw ProjectionError.ledgerIsNotFrozen }
        self.opponentPlanContentIdentity = opponentPlan.contentIdentity
        self.opponentPlanCommitmentHex = opponentPlan.commitmentHex
        self.ledgerIsFrozen = true
        self.scoringPolicyIdentity = projection.scoreLedger.scoringPolicy.identity.rawValue
        self.downwardRevisionPolicy = projection.scoreLedger.downwardRevisionPolicy
        self.days = try (1...7).map { ordinal in
            guard let accepted = projection.scoreLedger.entry(forDayOrdinal: ordinal)?.acceptedScore else { throw ProjectionError.incompleteFrozenLedger }
            return Day(ordinal: ordinal, acceptedPoints: accepted.points, acceptedActivityContentFingerprint: accepted.activityContentFingerprint.rawValue)
        }
        self.counterpartyKind = .simulated
        self.remoteOwnerProfileID = nil; self.remoteParticipantProfileID = nil
        self.remoteOwnerWindowCommitment = nil; self.remoteParticipantWindowCommitment = nil
        self.remoteResultHash = nil; self.remoteDays = []
    }

    private enum CodingKeys: String, CodingKey {
        case lifecycle, competitionID, scheduleTimeZoneIdentifier, startDay
        case opponentPlanContentIdentity, opponentPlanCommitmentHex, completedAt, outcome, basis, userPoints, opponentPoints, ledgerIsFrozen, scoringPolicyIdentity, downwardRevisionPolicy, days
        case counterpartyKind, remoteOwnerProfileID, remoteParticipantProfileID, remoteOwnerWindowCommitment, remoteParticipantWindowCommitment, remoteResultHash, remoteDays
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lifecycle, forKey: .lifecycle); try c.encode(competitionID, forKey: .competitionID)
        try c.encode(scheduleTimeZoneIdentifier, forKey: .scheduleTimeZoneIdentifier); try c.encode(startDay, forKey: .startDay)
        try c.encode(completedAt, forKey: .completedAt); try c.encode(outcome, forKey: .outcome); try c.encode(basis, forKey: .basis)
        try c.encode(userPoints, forKey: .userPoints); try c.encode(opponentPoints, forKey: .opponentPoints)
        try c.encode(scoringPolicyIdentity, forKey: .scoringPolicyIdentity)
        if counterpartyKind == .simulated {
            try c.encode(downwardRevisionPolicy, forKey: .downwardRevisionPolicy)
            try c.encode(opponentPlanContentIdentity, forKey: .opponentPlanContentIdentity); try c.encode(opponentPlanCommitmentHex, forKey: .opponentPlanCommitmentHex)
            try c.encode(ledgerIsFrozen, forKey: .ledgerIsFrozen); try c.encode(days, forKey: .days)
        } else {
            try c.encode(counterpartyKind, forKey: .counterpartyKind)
            try c.encode(remoteOwnerProfileID, forKey: .remoteOwnerProfileID); try c.encode(remoteParticipantProfileID, forKey: .remoteParticipantProfileID)
            try c.encode(remoteOwnerWindowCommitment, forKey: .remoteOwnerWindowCommitment); try c.encode(remoteParticipantWindowCommitment, forKey: .remoteParticipantWindowCommitment)
            try c.encode(remoteResultHash, forKey: .remoteResultHash); try c.encode(remoteDays, forKey: .remoteDays)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lifecycle = try c.decode(String.self, forKey: .lifecycle); competitionID = try c.decode(String.self, forKey: .competitionID)
        scheduleTimeZoneIdentifier = try c.decode(String.self, forKey: .scheduleTimeZoneIdentifier); startDay = try c.decode(CompetitionDay.self, forKey: .startDay)
        completedAt = try c.decode(Date.self, forKey: .completedAt); outcome = try c.decode(CompetitionOutcome.self, forKey: .outcome); basis = try c.decode(FinalizationBasis.self, forKey: .basis)
        userPoints = try c.decode(Double.self, forKey: .userPoints); opponentPoints = try c.decode(Double.self, forKey: .opponentPoints)
        scoringPolicyIdentity = try c.decode(String.self, forKey: .scoringPolicyIdentity)
        counterpartyKind = try c.decodeIfPresent(CounterpartyKind.self, forKey: .counterpartyKind) ?? .simulated
        if counterpartyKind == .simulated {
            downwardRevisionPolicy = try c.decode(DownwardRevisionPolicy.self, forKey: .downwardRevisionPolicy)
            opponentPlanContentIdentity = try c.decode(String.self, forKey: .opponentPlanContentIdentity); opponentPlanCommitmentHex = try c.decode(String.self, forKey: .opponentPlanCommitmentHex)
            ledgerIsFrozen = try c.decode(Bool.self, forKey: .ledgerIsFrozen); days = try c.decode([Day].self, forKey: .days)
            remoteOwnerProfileID = nil; remoteParticipantProfileID = nil; remoteOwnerWindowCommitment = nil; remoteParticipantWindowCommitment = nil; remoteResultHash = nil; remoteDays = []
        } else {
            // Remote finalization never uses the local score ledger policy;
            // retain a deterministic in-memory value solely for the shared
            // terminal type while keeping it out of the remote wire shape.
            downwardRevisionPolicy = .maximumObserved
            opponentPlanContentIdentity = ""; opponentPlanCommitmentHex = ""; ledgerIsFrozen = true; days = []
            remoteOwnerProfileID = try c.decode(String.self, forKey: .remoteOwnerProfileID); remoteParticipantProfileID = try c.decode(String.self, forKey: .remoteParticipantProfileID)
            remoteOwnerWindowCommitment = try c.decode(String.self, forKey: .remoteOwnerWindowCommitment); remoteParticipantWindowCommitment = try c.decode(String.self, forKey: .remoteParticipantWindowCommitment)
            remoteResultHash = try c.decode(String.self, forKey: .remoteResultHash); remoteDays = try c.decode([RemoteDay].self, forKey: .remoteDays)
        }
    }
}
