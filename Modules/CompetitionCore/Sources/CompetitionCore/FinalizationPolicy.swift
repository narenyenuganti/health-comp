import Foundation

public struct MonotonicInstant: Codable, Hashable, Sendable {
    public let epochID: String
    public let nanoseconds: UInt64

    public init(epochID: String, nanoseconds: UInt64) {
        self.epochID = epochID
        self.nanoseconds = nanoseconds
    }
}

public struct WindowDayContent: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let userPoints: Double
    public let opponentPoints: Double
    public let activityContentFingerprint: String

    public init(
        ordinal: Int,
        userPoints: Double,
        opponentPoints: Double,
        activityContentFingerprint: String
    ) {
        self.ordinal = ordinal
        self.userPoints = userPoints
        self.opponentPoints = opponentPoints
        self.activityContentFingerprint = activityContentFingerprint
    }
}

public struct CompleteWindowFingerprint: Codable, Hashable, Sendable {
    public let rawValue: String

    internal init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct CompleteWindowContent: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidDayOrdinals
        case invalidDayPoints(ordinal: Int)
        case invalidWindowTotal
        case emptyActivityFingerprint(ordinal: Int)
        case emptyOpponentPlanVersion
    }

    public static let maximumDailyPoints = 600.0

    public let days: [WindowDayContent]
    public let opponentPlanVersion: String
    public let fingerprint: CompleteWindowFingerprint
    public let finalScoreSnapshot: FinalScoreSnapshot

    public init(
        days: [WindowDayContent],
        opponentPlanVersion: String
    ) throws {
        let sortedDays = days.sorted { $0.ordinal < $1.ordinal }
        guard sortedDays.map(\.ordinal) == Array(1...7) else {
            throw ValidationError.invalidDayOrdinals
        }
        for day in sortedDays {
            guard day.userPoints.isFinite,
                  day.opponentPoints.isFinite,
                  (0...Self.maximumDailyPoints).contains(day.userPoints),
                  (0...Self.maximumDailyPoints).contains(day.opponentPoints)
            else {
                throw ValidationError.invalidDayPoints(ordinal: day.ordinal)
            }
            guard !day.activityContentFingerprint.isEmpty else {
                throw ValidationError.emptyActivityFingerprint(ordinal: day.ordinal)
            }
        }
        guard !opponentPlanVersion.isEmpty else {
            throw ValidationError.emptyOpponentPlanVersion
        }

        let userTotal = sortedDays.reduce(0) { $0 + $1.userPoints }
        let opponentTotal = sortedDays.reduce(0) { $0 + $1.opponentPoints }
        guard let snapshot = try? FinalScoreSnapshot(
            userPoints: userTotal,
            opponentPoints: opponentTotal
        ) else {
            throw ValidationError.invalidWindowTotal
        }

        self.days = sortedDays
        self.opponentPlanVersion = opponentPlanVersion
        self.fingerprint = CompleteWindowFingerprint(
            rawValue: Self.canonicalFingerprint(
                days: sortedDays,
                opponentPlanVersion: opponentPlanVersion
            )
        )
        self.finalScoreSnapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case days
        case opponentPlanVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            days: container.decode([WindowDayContent].self, forKey: .days),
            opponentPlanVersion: container.decode(
                String.self,
                forKey: .opponentPlanVersion
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(days, forKey: .days)
        try container.encode(opponentPlanVersion, forKey: .opponentPlanVersion)
    }

    private static func canonicalFingerprint(
        days: [WindowDayContent],
        opponentPlanVersion: String
    ) -> String {
        let encodedPlan = Data(opponentPlanVersion.utf8).base64EncodedString()
        let encodedDays = days.map { day in
            let activity = Data(day.activityContentFingerprint.utf8)
                .base64EncodedString()
            return [
                String(day.ordinal),
                String(normalizedBitPattern(day.userPoints), radix: 16),
                String(normalizedBitPattern(day.opponentPoints), radix: 16),
                activity,
            ].joined(separator: ":")
        }.joined(separator: "|")
        return "complete-window-content:v1:\(encodedPlan):\(encodedDays)"
    }

    private static func normalizedBitPattern(_ points: Double) -> UInt64 {
        (points == 0 ? 0.0 : points).bitPattern
    }
}

public struct FinalReadEvidence: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidAttemptID
        case invalidOrdinalSet
        case overlappingUnavailableOrdinals
        case acceptedOrdinalWasNotEvaluable
        case incompleteEvidenceHasCompleteContent
        case completeEvidenceMissingContent
    }

    public let attemptID: String
    public let readAt: Date
    public let monotonicInstant: MonotonicInstant
    public let evaluableOrdinals: Set<Int>
    public let acceptedScoreOrdinals: Set<Int>
    public let missingOrdinals: Set<Int>
    public let unavailableOrdinals: Set<Int>
    public let completeWindowContent: CompleteWindowContent?
    public let opponentPlanIsFinal: Bool

    public var completeWindowFingerprint: CompleteWindowFingerprint? {
        completeWindowContent?.fingerprint
    }

    public var finalScoreSnapshot: FinalScoreSnapshot? {
        completeWindowContent?.finalScoreSnapshot
    }

    public var fullSevenDayWindowEvaluable: Bool {
        evaluableOrdinals == Self.allOrdinals
            && missingOrdinals.isEmpty
            && unavailableOrdinals.isEmpty
    }

    internal var isCompleteWindowRead: Bool {
        fullSevenDayWindowEvaluable && completeWindowContent != nil
    }

    internal var isEligibleForFinalization: Bool {
        isCompleteWindowRead
            && acceptedScoreOrdinals == Self.allOrdinals
            && opponentPlanIsFinal
    }

    public init(
        attemptID: String,
        readAt: Date,
        monotonicInstant: MonotonicInstant,
        evaluableOrdinals: Set<Int>,
        acceptedScoreOrdinals: Set<Int>,
        missingOrdinals: Set<Int>,
        unavailableOrdinals: Set<Int>,
        completeWindowContent: CompleteWindowContent?,
        opponentPlanIsFinal: Bool
    ) throws {
        let permittedAttemptCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_.")
        )
        guard !attemptID.isEmpty,
              attemptID.unicodeScalars.allSatisfy({
                  permittedAttemptCharacters.contains($0)
              })
        else {
            throw ValidationError.invalidAttemptID
        }

        let allProvidedOrdinals = evaluableOrdinals
            .union(acceptedScoreOrdinals)
            .union(missingOrdinals)
            .union(unavailableOrdinals)
        guard allProvidedOrdinals.isSubset(of: Self.allOrdinals),
              evaluableOrdinals
                .union(missingOrdinals)
                .union(unavailableOrdinals) == Self.allOrdinals
        else {
            throw ValidationError.invalidOrdinalSet
        }
        guard missingOrdinals.isDisjoint(with: unavailableOrdinals),
              evaluableOrdinals.isDisjoint(with: missingOrdinals),
              evaluableOrdinals.isDisjoint(with: unavailableOrdinals)
        else {
            throw ValidationError.overlappingUnavailableOrdinals
        }
        guard acceptedScoreOrdinals.isSubset(of: evaluableOrdinals) else {
            throw ValidationError.acceptedOrdinalWasNotEvaluable
        }

        let isFullWindow = evaluableOrdinals == Self.allOrdinals
            && missingOrdinals.isEmpty
            && unavailableOrdinals.isEmpty
        if isFullWindow, completeWindowContent == nil {
            throw ValidationError.completeEvidenceMissingContent
        }
        if !isFullWindow, completeWindowContent != nil {
            throw ValidationError.incompleteEvidenceHasCompleteContent
        }

        self.attemptID = attemptID
        self.readAt = readAt
        self.monotonicInstant = monotonicInstant
        self.evaluableOrdinals = evaluableOrdinals
        self.acceptedScoreOrdinals = acceptedScoreOrdinals
        self.missingOrdinals = missingOrdinals
        self.unavailableOrdinals = unavailableOrdinals
        self.completeWindowContent = completeWindowContent
        self.opponentPlanIsFinal = opponentPlanIsFinal
    }

    private static let allOrdinals = Set(1...7)

    private enum CodingKeys: String, CodingKey {
        case attemptID
        case readAt
        case monotonicInstant
        case evaluableOrdinals
        case acceptedScoreOrdinals
        case missingOrdinals
        case unavailableOrdinals
        case completeWindowContent
        case opponentPlanIsFinal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            attemptID: container.decode(String.self, forKey: .attemptID),
            readAt: container.decode(Date.self, forKey: .readAt),
            monotonicInstant: container.decode(
                MonotonicInstant.self,
                forKey: .monotonicInstant
            ),
            evaluableOrdinals: Set(
                container.decode([Int].self, forKey: .evaluableOrdinals)
            ),
            acceptedScoreOrdinals: Set(
                container.decode([Int].self, forKey: .acceptedScoreOrdinals)
            ),
            missingOrdinals: Set(
                container.decode([Int].self, forKey: .missingOrdinals)
            ),
            unavailableOrdinals: Set(
                container.decode([Int].self, forKey: .unavailableOrdinals)
            ),
            completeWindowContent: container.decodeIfPresent(
                CompleteWindowContent.self,
                forKey: .completeWindowContent
            ),
            opponentPlanIsFinal: container.decode(
                Bool.self,
                forKey: .opponentPlanIsFinal
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attemptID, forKey: .attemptID)
        try container.encode(readAt, forKey: .readAt)
        try container.encode(monotonicInstant, forKey: .monotonicInstant)
        try container.encode(evaluableOrdinals.sorted(), forKey: .evaluableOrdinals)
        try container.encode(
            acceptedScoreOrdinals.sorted(),
            forKey: .acceptedScoreOrdinals
        )
        try container.encode(missingOrdinals.sorted(), forKey: .missingOrdinals)
        try container.encode(
            unavailableOrdinals.sorted(),
            forKey: .unavailableOrdinals
        )
        try container.encodeIfPresent(
            completeWindowContent,
            forKey: .completeWindowContent
        )
        try container.encode(opponentPlanIsFinal, forKey: .opponentPlanIsFinal)
    }
}

public struct FinalReadRecord: Codable, Equatable, Sendable {
    public let evidence: FinalReadEvidence

    internal init(evidence: FinalReadEvidence) {
        self.evidence = evidence
    }
}

public struct TallyReconciliation: Codable, Equatable, Sendable {
    public internal(set) var revision: UInt64
    public internal(set) var latestAttempt: FinalReadEvidence?
    public internal(set) var lastCompletePostBoundaryRead: FinalReadEvidence?
    public internal(set) var consecutiveStableCompleteReads: Int
    public internal(set) var stabilityStart: MonotonicInstant?
    public internal(set) var evaluableOrdinalsEver: Set<Int>
    public internal(set) var acceptedScoreOrdinals: Set<Int>
    public internal(set) var latestAcceptedSnapshot: FinalScoreSnapshot?
    public internal(set) var postBoundaryAttemptCount: Int

    internal var stabilityFingerprint: CompleteWindowFingerprint?
    internal var lastStabilityObservation: MonotonicInstant?

    public init() {
        self.revision = 0
        self.latestAttempt = nil
        self.lastCompletePostBoundaryRead = nil
        self.consecutiveStableCompleteReads = 0
        self.stabilityStart = nil
        self.evaluableOrdinalsEver = []
        self.acceptedScoreOrdinals = []
        self.latestAcceptedSnapshot = nil
        self.postBoundaryAttemptCount = 0
        self.stabilityFingerprint = nil
        self.lastStabilityObservation = nil
    }

    internal mutating func record(
        _ evidence: FinalReadEvidence,
        boundary: Date
    ) {
        // Reads whose actual timestamp precedes the competition boundary are
        // persisted as events but are absent from reconciliation decision state.
        guard evidence.readAt >= boundary else { return }

        revision += 1
        latestAttempt = evidence
        postBoundaryAttemptCount += 1
        evaluableOrdinalsEver.formUnion(evidence.evaluableOrdinals)
        acceptedScoreOrdinals.formUnion(evidence.acceptedScoreOrdinals)

        // An incomplete read is absence of evidence. It is recorded as latest,
        // but must not destroy a previously complete stability anchor.
        guard evidence.isCompleteWindowRead else { return }

        lastCompletePostBoundaryRead = evidence
        if evidence.acceptedScoreOrdinals == Set(1...7) {
            latestAcceptedSnapshot = evidence.finalScoreSnapshot
        }

        guard evidence.isEligibleForFinalization,
              let fingerprint = evidence.completeWindowFingerprint
        else {
            consecutiveStableCompleteReads = 0
            stabilityStart = nil
            stabilityFingerprint = nil
            lastStabilityObservation = nil
            return
        }

        guard stabilityFingerprint == fingerprint,
              let start = stabilityStart,
              let priorObservation = lastStabilityObservation
        else {
            establishAnchor(for: evidence, fingerprint: fingerprint)
            return
        }

        let current = evidence.monotonicInstant
        guard current.epochID == start.epochID,
              current.epochID == priorObservation.epochID,
              current.nanoseconds > priorObservation.nanoseconds
        else {
            establishAnchor(for: evidence, fingerprint: fingerprint)
            return
        }

        lastStabilityObservation = current
        consecutiveStableCompleteReads += 1
    }

    private mutating func establishAnchor(
        for evidence: FinalReadEvidence,
        fingerprint: CompleteWindowFingerprint
    ) {
        stabilityFingerprint = fingerprint
        stabilityStart = evidence.monotonicInstant
        lastStabilityObservation = evidence.monotonicInstant
        consecutiveStableCompleteReads = 1
    }
}

public enum TallyNeedsAttention: Codable, Equatable, Sendable {
    case missingActivity(ordinals: Set<Int>)
    case noCompletePostBoundaryRead
    case latestReadIncomplete(
        missingOrdinals: Set<Int>,
        unavailableOrdinals: Set<Int>
    )
    case unacceptedScores(ordinals: Set<Int>)
    case opponentPlanNotFinal
    case opponentPlanContentMismatch
}

public struct FinalizationAuthorization: Equatable, Sendable {
    public let snapshot: FinalScoreSnapshot
    public let basis: FinalizationBasis

    internal let competitionID: CompetitionID
    internal let reconciliationRevision: UInt64
    internal let eligibleAttemptID: String
    internal let policy: FinalizationPolicy
    internal let decisionAt: Date

    internal init(
        competitionID: CompetitionID,
        reconciliationRevision: UInt64,
        eligibleAttemptID: String,
        snapshot: FinalScoreSnapshot,
        basis: FinalizationBasis,
        policy: FinalizationPolicy,
        decisionAt: Date
    ) {
        self.competitionID = competitionID
        self.reconciliationRevision = reconciliationRevision
        self.eligibleAttemptID = eligibleAttemptID
        self.snapshot = snapshot
        self.basis = basis
        self.policy = policy
        self.decisionAt = decisionAt
    }
}

public enum FinalizationDecision: Equatable, Sendable {
    case wait
    case finalize(FinalizationAuthorization)
    case needsAttention(TallyNeedsAttention)
}

public struct FinalizationPolicy: Codable, Equatable, Sendable {
    public let minimumStabilityNanoseconds: UInt64
    public let bestAvailableDeadline: Date

    public init(
        minimumStabilityNanoseconds: UInt64,
        bestAvailableDeadline: Date
    ) {
        self.minimumStabilityNanoseconds = minimumStabilityNanoseconds
        self.bestAvailableDeadline = bestAvailableDeadline
    }

    public func decision(
        for competition: Competition,
        at decisionDate: Date
    ) -> FinalizationDecision {
        guard case let .tallying(tally) = competition.lifecycle else {
            return .wait
        }
        let reconciliation = tally.reconciliation
        guard let opponentPlan = competition.opponentPlan,
              Self.reconciliation(
                  reconciliation,
                  matches: opponentPlan
              )
        else {
            return .needsAttention(.opponentPlanContentMismatch)
        }

        if let latest = reconciliation.latestAttempt,
           latest.isEligibleForFinalization,
           reconciliation.consecutiveStableCompleteReads >= 2,
           let stabilityStart = reconciliation.stabilityStart,
           latest.monotonicInstant.epochID == stabilityStart.epochID,
           latest.monotonicInstant.nanoseconds > stabilityStart.nanoseconds,
           latest.monotonicInstant.nanoseconds - stabilityStart.nanoseconds
                >= minimumStabilityNanoseconds,
           let snapshot = latest.finalScoreSnapshot {
            return authorization(
                for: competition,
                reconciliation: reconciliation,
                latest: latest,
                snapshot: snapshot,
                basis: .stableAcrossPostBoundaryReads,
                decisionAt: decisionDate
            )
        }

        guard decisionDate >= bestAvailableDeadline else {
            return .wait
        }
        guard reconciliation.postBoundaryAttemptCount > 0 else {
            return .needsAttention(.noCompletePostBoundaryRead)
        }

        let missingActivity = Set(1...7).subtracting(
            reconciliation.evaluableOrdinalsEver
        )
        guard missingActivity.isEmpty else {
            return .needsAttention(
                .missingActivity(ordinals: missingActivity)
            )
        }
        guard reconciliation.lastCompletePostBoundaryRead != nil else {
            return .needsAttention(.noCompletePostBoundaryRead)
        }
        guard let latest = reconciliation.latestAttempt,
              latest.isCompleteWindowRead
        else {
            return .needsAttention(
                .latestReadIncomplete(
                    missingOrdinals: reconciliation.latestAttempt?.missingOrdinals ?? [],
                    unavailableOrdinals: reconciliation.latestAttempt?
                        .unavailableOrdinals ?? []
                )
            )
        }
        guard latest.opponentPlanIsFinal else {
            return .needsAttention(.opponentPlanNotFinal)
        }

        let unaccepted = Set(1...7).subtracting(
            latest.acceptedScoreOrdinals
        )
        guard unaccepted.isEmpty else {
            return .needsAttention(.unacceptedScores(ordinals: unaccepted))
        }
        guard let snapshot = latest.finalScoreSnapshot else {
            return .needsAttention(.noCompletePostBoundaryRead)
        }
        return authorization(
            for: competition,
            reconciliation: reconciliation,
            latest: latest,
            snapshot: snapshot,
            basis: .bestAvailable,
            decisionAt: decisionDate
        )
    }

    private func authorization(
        for competition: Competition,
        reconciliation: TallyReconciliation,
        latest: FinalReadEvidence,
        snapshot: FinalScoreSnapshot,
        basis: FinalizationBasis,
        decisionAt: Date
    ) -> FinalizationDecision {
        .finalize(
            FinalizationAuthorization(
                competitionID: competition.id,
                reconciliationRevision: reconciliation.revision,
                eligibleAttemptID: latest.attemptID,
                snapshot: snapshot,
                basis: basis,
                policy: self,
                decisionAt: decisionAt
            )
        )
    }

    private static func reconciliation(
        _ reconciliation: TallyReconciliation,
        matches opponentPlan: OpponentPlan
    ) -> Bool {
        [
            reconciliation.latestAttempt,
            reconciliation.lastCompletePostBoundaryRead,
        ]
        .compactMap { $0?.completeWindowContent }
        .allSatisfy(opponentPlan.matches)
    }
}
