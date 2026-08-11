import Foundation

public enum DownwardRevisionPolicy: String, Codable, Equatable, Sendable {
    case maximumObserved
    case latestValue
}

public enum ScoreLedgerError: Error, Equatable, Sendable {
    case invalidDayOrdinal(Int)
    case missingAcceptedDayOrdinals(Set<Int>)
    case ledgerFrozen
    case activityModeChanged
    case incompatibleScoringPolicy
    case invalidLiveWindow
    case invalidFrozenWindow
    case invalidOpponentDayOrdinals(Set<Int>)
}

public struct ActivityScoreEvidence: Codable, Equatable, Sendable {
    public let snapshot: ActivitySnapshot
    public let scoringPolicy: ActivityScoringPolicy

    public var scoringPolicyIdentity: ActivityScoringPolicyIdentity {
        scoringPolicy.identity
    }

    public var sourceSnapshotFingerprint: ActivitySnapshotFingerprint {
        snapshot.fingerprint
    }

    public var result: ActivityScoreResult {
        ActivityScoreCalculator.score(snapshot, policy: scoringPolicy)
    }

    public init(
        snapshot: ActivitySnapshot,
        scoringPolicy: ActivityScoringPolicy
    ) {
        self.snapshot = snapshot
        self.scoringPolicy = scoringPolicy
    }
}

public struct ActivityContentFingerprint: Codable, Hashable, Sendable {
    public let rawValue: String

    internal init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct AcceptedDayScore: Codable, Equatable, Sendable {
    public let evidence: ActivityScoreEvidence
    private let acceptedScore: ActivityScore

    public var snapshot: ActivitySnapshot {
        evidence.snapshot
    }

    public var scoringPolicy: ActivityScoringPolicy {
        evidence.scoringPolicy
    }

    public var scoringPolicyIdentity: ActivityScoringPolicyIdentity {
        evidence.scoringPolicyIdentity
    }

    public var moveMode: ActivityMoveMode {
        snapshot.moveMode
    }

    public var standMode: ActivityStandMode {
        snapshot.standMode
    }

    public var sourceSnapshotFingerprint: ActivitySnapshotFingerprint {
        evidence.sourceSnapshotFingerprint
    }

    public var activityContentFingerprint: ActivityContentFingerprint {
        let encodedPolicy = Data(scoringPolicyIdentity.rawValue.utf8)
            .base64EncodedString()
        let encodedSnapshot = Data(sourceSnapshotFingerprint.rawValue.utf8)
            .base64EncodedString()
        return ActivityContentFingerprint(
            rawValue: "accepted-activity-score:v1:\(encodedPolicy):\(encodedSnapshot)"
        )
    }

    public var score: ActivityScore {
        acceptedScore
    }

    public var points: Double {
        score.points
    }

    internal init?(evidence: ActivityScoreEvidence) {
        guard let score = evidence.result.availableScore else { return nil }
        self.evidence = evidence
        self.acceptedScore = score
    }

    private enum CodingKeys: String, CodingKey {
        case evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let evidence = try container.decode(
            ActivityScoreEvidence.self,
            forKey: .evidence
        )
        guard let accepted = Self(evidence: evidence) else {
            throw DecodingError.dataCorruptedError(
                forKey: .evidence,
                in: container,
                debugDescription: "Accepted score evidence is unavailable"
            )
        }
        self = accepted
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(evidence, forKey: .evidence)
    }
}

public struct ScoreLedgerEntry: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let latestEvidence: ActivityScoreEvidence
    public let acceptedScore: AcceptedDayScore?
    public let isFrozen: Bool

    internal init(
        ordinal: Int,
        latestEvidence: ActivityScoreEvidence,
        acceptedScore: AcceptedDayScore?,
        isFrozen: Bool
    ) {
        self.ordinal = ordinal
        self.latestEvidence = latestEvidence
        self.acceptedScore = acceptedScore
        self.isFrozen = isFrozen
    }
}

public struct LiveDayScoreObservation: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let acceptedScore: AcceptedDayScore
    public let latestEvidence: ActivityScoreEvidence

    public var acceptedPoints: Double {
        acceptedScore.points
    }

    public var activityContentFingerprint: ActivityContentFingerprint {
        let encodedAccepted = Data(
            acceptedScore.activityContentFingerprint.rawValue.utf8
        ).base64EncodedString()
        let encodedLatest = Data(
            latestEvidence.sourceSnapshotFingerprint.rawValue.utf8
        ).base64EncodedString()

        return ActivityContentFingerprint(
            rawValue: [
                "live-day-score",
                "v1",
                String(ordinal),
                encodedAccepted,
                encodedLatest,
            ].joined(separator: ":")
        )
    }

    internal init(
        ordinal: Int,
        acceptedScore: AcceptedDayScore,
        latestEvidence: ActivityScoreEvidence
    ) throws {
        guard (1...7).contains(ordinal),
              let latestScore = latestEvidence.result.availableScore,
              acceptedScore.scoringPolicy == latestEvidence.scoringPolicy,
              acceptedScore.moveMode == latestEvidence.snapshot.moveMode,
              acceptedScore.standMode == latestEvidence.snapshot.standMode,
              acceptedScore.points >= latestScore.points
        else {
            throw ScoreLedgerError.invalidLiveWindow
        }
        self.ordinal = ordinal
        self.acceptedScore = acceptedScore
        self.latestEvidence = latestEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case ordinal
        case acceptedScore
        case latestEvidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                ordinal: container.decode(Int.self, forKey: .ordinal),
                acceptedScore: container.decode(
                    AcceptedDayScore.self,
                    forKey: .acceptedScore
                ),
                latestEvidence: container.decode(
                    ActivityScoreEvidence.self,
                    forKey: .latestEvidence
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .latestEvidence,
                in: container,
                debugDescription: "Live day score evidence is invalid: \(error)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ordinal, forKey: .ordinal)
        try container.encode(acceptedScore, forKey: .acceptedScore)
        try container.encode(latestEvidence, forKey: .latestEvidence)
    }
}

public struct LiveScoreWindowObservation: Codable, Equatable, Sendable {
    public let days: [LiveDayScoreObservation]

    public var totalPoints: Double {
        min(
            ActivityScore.maximumCompetitionPoints,
            days.reduce(0) { $0 + $1.acceptedPoints }
        )
    }

    internal init(days: [LiveDayScoreObservation]) throws {
        let sortedDays = days.sorted { $0.ordinal < $1.ordinal }
        guard sortedDays.map(\.ordinal) == Array(1...7),
              Set(sortedDays.map {
                  $0.acceptedScore.scoringPolicyIdentity
              }).count == 1
        else {
            throw ScoreLedgerError.invalidLiveWindow
        }
        self.days = sortedDays
    }

    public func day(forOrdinal ordinal: Int) -> LiveDayScoreObservation? {
        days.first { $0.ordinal == ordinal }
    }

    private enum CodingKeys: String, CodingKey {
        case days
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                days: container.decode(
                    [LiveDayScoreObservation].self,
                    forKey: .days
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .days,
                in: container,
                debugDescription: "Live score window is invalid: \(error)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(days, forKey: .days)
    }
}

public struct FrozenDayScore: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let acceptedScore: AcceptedDayScore

    public var points: Double {
        acceptedScore.points
    }

    public var activityContentFingerprint: ActivityContentFingerprint {
        acceptedScore.activityContentFingerprint
    }

    internal init(ordinal: Int, acceptedScore: AcceptedDayScore) {
        self.ordinal = ordinal
        self.acceptedScore = acceptedScore
    }
}

public struct FrozenScoreWindow: Codable, Equatable, Sendable {
    public static let maximumTotalPoints = ActivityScore.maximumCompetitionPoints

    public let days: [FrozenDayScore]

    public var totalPoints: Double {
        min(Self.maximumTotalPoints, days.reduce(0) { $0 + $1.points })
    }

    internal init(days: [FrozenDayScore]) throws {
        let sortedDays = days.sorted { $0.ordinal < $1.ordinal }
        guard sortedDays.map(\.ordinal) == Array(1...7),
              Set(sortedDays.map { $0.acceptedScore.scoringPolicyIdentity })
                .count == 1
        else {
            throw ScoreLedgerError.invalidFrozenWindow
        }
        self.days = sortedDays
    }

    public func day(forOrdinal ordinal: Int) -> FrozenDayScore? {
        days.first { $0.ordinal == ordinal }
    }

    public func completeWindowContent(
        opponentPointsByOrdinal: [Int: Double],
        opponentPlanVersion: String
    ) throws -> CompleteWindowContent {
        let providedOrdinals = Set(opponentPointsByOrdinal.keys)
        let requiredOrdinals = Set(1...7)
        guard providedOrdinals == requiredOrdinals else {
            throw ScoreLedgerError.invalidOpponentDayOrdinals(
                requiredOrdinals.symmetricDifference(providedOrdinals)
            )
        }

        let windowDays = try days.map { day -> WindowDayContent in
            guard let opponentPoints = opponentPointsByOrdinal[day.ordinal]
            else {
                throw ScoreLedgerError.invalidOpponentDayOrdinals([day.ordinal])
            }
            return WindowDayContent(
                ordinal: day.ordinal,
                userPoints: day.points,
                opponentPoints: opponentPoints,
                activityContentFingerprint: day.activityContentFingerprint.rawValue
            )
        }
        return try CompleteWindowContent(
            days: windowDays,
            opponentPlanVersion: opponentPlanVersion
        )
    }

    private enum CodingKeys: String, CodingKey {
        case days
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                days: container.decode([FrozenDayScore].self, forKey: .days)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .days,
                in: container,
                debugDescription: "Frozen score window is invalid: \(error)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(days, forKey: .days)
    }
}

public struct ScoreLedger: Codable, Equatable, Sendable {
    public let scoringPolicy: ActivityScoringPolicy
    public let downwardRevisionPolicy: DownwardRevisionPolicy
    private var storedEntries: [ScoreLedgerEntry]
    public private(set) var frozenWindow: FrozenScoreWindow?

    public var entries: [ScoreLedgerEntry] {
        storedEntries.sorted { $0.ordinal < $1.ordinal }
    }

    public var isFrozen: Bool {
        frozenWindow != nil
    }

    public init(
        scoringPolicy: ActivityScoringPolicy = .appleCompatibility,
        downwardRevisionPolicy: DownwardRevisionPolicy = .maximumObserved
    ) {
        self.scoringPolicy = scoringPolicy
        self.downwardRevisionPolicy = downwardRevisionPolicy
        self.storedEntries = []
        self.frozenWindow = nil
    }

    public func entry(forDayOrdinal ordinal: Int) -> ScoreLedgerEntry? {
        storedEntries.first { $0.ordinal == ordinal }
    }

    public func completeLiveWindowObservation() -> LiveScoreWindowObservation? {
        guard !isFrozen else { return nil }
        let orderedEntries = entries
        guard orderedEntries.map(\.ordinal) == Array(1...7) else {
            return nil
        }

        var observedDays: [LiveDayScoreObservation] = []
        observedDays.reserveCapacity(7)
        for entry in orderedEntries {
            guard let acceptedScore = entry.acceptedScore,
                  entry.latestEvidence.result.availableScore != nil
            else {
                return nil
            }
            guard let observedDay = try? LiveDayScoreObservation(
                    ordinal: entry.ordinal,
                    acceptedScore: acceptedScore,
                    latestEvidence: entry.latestEvidence
            ) else {
                return nil
            }
            observedDays.append(observedDay)
        }
        return try? LiveScoreWindowObservation(days: observedDays)
    }

    @discardableResult
    public mutating func record(
        _ snapshot: ActivitySnapshot,
        forDayOrdinal ordinal: Int
    ) throws -> ScoreLedgerEntry {
        guard (1...7).contains(ordinal) else {
            throw ScoreLedgerError.invalidDayOrdinal(ordinal)
        }
        guard !isFrozen else {
            throw ScoreLedgerError.ledgerFrozen
        }
        if let existing = entry(forDayOrdinal: ordinal),
           existing.latestEvidence.snapshot.moveMode != snapshot.moveMode
            || existing.latestEvidence.snapshot.standMode != snapshot.standMode {
            throw ScoreLedgerError.activityModeChanged
        }

        let evidence = ActivityScoreEvidence(
            snapshot: snapshot,
            scoringPolicy: scoringPolicy
        )
        let previousAccepted = entry(forDayOrdinal: ordinal)?.acceptedScore
        let accepted: AcceptedDayScore?
        if let candidate = AcceptedDayScore(evidence: evidence) {
            switch downwardRevisionPolicy {
            case .maximumObserved:
                if let previousAccepted,
                   candidate.points <= previousAccepted.points {
                    accepted = previousAccepted
                } else {
                    accepted = candidate
                }
            case .latestValue:
                accepted = candidate
            }
        } else {
            accepted = previousAccepted
        }

        let revisedEntry = ScoreLedgerEntry(
            ordinal: ordinal,
            latestEvidence: evidence,
            acceptedScore: accepted,
            isFrozen: false
        )
        if let index = storedEntries.firstIndex(where: { $0.ordinal == ordinal }) {
            storedEntries[index] = revisedEntry
        } else {
            storedEntries.append(revisedEntry)
        }
        storedEntries.sort { $0.ordinal < $1.ordinal }
        return revisedEntry
    }

    @discardableResult
    public mutating func freeze() throws -> FrozenScoreWindow {
        if let frozenWindow {
            return frozenWindow
        }

        let acceptedByOrdinal = Dictionary(
            uniqueKeysWithValues: storedEntries.compactMap { entry in
                entry.acceptedScore.map { (entry.ordinal, $0) }
            }
        )
        let requiredOrdinals = Set(1...7)
        let acceptedOrdinals = Set(acceptedByOrdinal.keys)
        guard acceptedOrdinals == requiredOrdinals else {
            throw ScoreLedgerError.missingAcceptedDayOrdinals(
                requiredOrdinals.subtracting(acceptedOrdinals)
            )
        }

        var candidateDays: [FrozenDayScore] = []
        candidateDays.reserveCapacity(7)
        for ordinal in 1...7 {
            guard let acceptedScore = acceptedByOrdinal[ordinal] else {
                throw ScoreLedgerError.invalidFrozenWindow
            }
            candidateDays.append(
                FrozenDayScore(
                    ordinal: ordinal,
                    acceptedScore: acceptedScore
                )
            )
        }
        let candidateWindow = try FrozenScoreWindow(days: candidateDays)
        let frozenEntries = storedEntries.map { entry in
            ScoreLedgerEntry(
                ordinal: entry.ordinal,
                latestEvidence: entry.latestEvidence,
                acceptedScore: entry.acceptedScore,
                isFrozen: true
            )
        }

        storedEntries = frozenEntries
        frozenWindow = candidateWindow
        return candidateWindow
    }

    private enum CodingKeys: String, CodingKey {
        case scoringPolicy
        case downwardRevisionPolicy
        case entries
        case frozenWindow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let scoringPolicy = try container.decode(
            ActivityScoringPolicy.self,
            forKey: .scoringPolicy
        )
        let downwardRevisionPolicy = try container.decode(
            DownwardRevisionPolicy.self,
            forKey: .downwardRevisionPolicy
        )
        let entries = try container.decode(
            [ScoreLedgerEntry].self,
            forKey: .entries
        )
        let frozenWindow = try container.decodeIfPresent(
            FrozenScoreWindow.self,
            forKey: .frozenWindow
        )

        let ordinals = entries.map(\.ordinal)
        let ordinalSet = Set(ordinals)
        guard ordinals.count == ordinalSet.count,
              ordinalSet.isSubset(of: Set(1...7)),
              entries.allSatisfy({ entry in
                  guard entry.latestEvidence.scoringPolicy == scoringPolicy
                  else {
                      return false
                  }
                  let latestScore = entry.latestEvidence.result.availableScore
                  guard let acceptedScore = entry.acceptedScore else {
                      return latestScore == nil
                  }
                  guard acceptedScore.scoringPolicy == scoringPolicy,
                        acceptedScore.moveMode
                            == entry.latestEvidence.snapshot.moveMode,
                        acceptedScore.standMode
                            == entry.latestEvidence.snapshot.standMode
                  else {
                      return false
                  }
                  guard let latestScore else {
                      return true
                  }
                  switch downwardRevisionPolicy {
                  case .maximumObserved:
                      return acceptedScore.points >= latestScore.points
                  case .latestValue:
                      return acceptedScore.evidence == entry.latestEvidence
                  }
              })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .entries,
                in: container,
                debugDescription: "Ledger entries or scoring policies are invalid"
            )
        }

        if let frozenWindow {
            let acceptedEntries = entries.compactMap { entry in
                entry.acceptedScore.map {
                    FrozenDayScore(ordinal: entry.ordinal, acceptedScore: $0)
                }
            }
            let reconstructed: FrozenScoreWindow
            do {
                reconstructed = try FrozenScoreWindow(days: acceptedEntries)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .frozenWindow,
                    in: container,
                    debugDescription: "Frozen ledger entries are incomplete"
                )
            }
            guard entries.allSatisfy(\.isFrozen),
                  reconstructed == frozenWindow
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .frozenWindow,
                    in: container,
                    debugDescription: "Frozen ledger state is inconsistent"
                )
            }
        } else if entries.contains(where: \.isFrozen) {
            throw DecodingError.dataCorruptedError(
                forKey: .frozenWindow,
                in: container,
                debugDescription: "Mutable ledger contains frozen entries"
            )
        }

        self.scoringPolicy = scoringPolicy
        self.downwardRevisionPolicy = downwardRevisionPolicy
        self.storedEntries = entries.sorted { $0.ordinal < $1.ordinal }
        self.frozenWindow = frozenWindow
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scoringPolicy, forKey: .scoringPolicy)
        try container.encode(
            downwardRevisionPolicy,
            forKey: .downwardRevisionPolicy
        )
        try container.encode(entries, forKey: .entries)
        try container.encodeIfPresent(frozenWindow, forKey: .frozenWindow)
    }
}
