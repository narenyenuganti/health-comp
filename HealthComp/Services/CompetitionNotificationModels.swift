import CompetitionCore
import Foundation

enum CompetitionScheduledNotificationFamily: String, CaseIterable, Sendable {
    case inviteExpiry = "invite-expiry"
    case scheduledStart = "scheduled-start"
    case finalDay = "final-day"
    case competitionEnded = "competition-ended"
}

enum CompetitionNotificationIdentifier {
    static let namespace = "competition-notification:v1:"

    static func competitionPrefix(_ competitionID: CompetitionID) -> String {
        namespace + competitionID.rawValue.uuidString.lowercased() + ":"
    }

    static func scheduled(
        competitionID: CompetitionID,
        family: CompetitionScheduledNotificationFamily
    ) -> String {
        competitionPrefix(competitionID) + family.rawValue
    }

    static func opportunistic(
        _ record: NotificationEmissionRecorded
    ) -> String {
        record.semanticEventID
    }

    static func competitionID(from identifier: String) -> CompetitionID? {
        guard identifier.hasPrefix(namespace) else { return nil }
        let suffix = identifier.dropFirst(namespace.count)
        guard let separator = suffix.firstIndex(of: ":") else { return nil }
        let persistedID = String(suffix[..<separator])
        guard let uuid = UUID(uuidString: persistedID),
              uuid.uuidString.lowercased() == persistedID
        else {
            return nil
        }
        return CompetitionID(uuid)
    }
}

enum CompetitionNotificationLifecycle: Equatable, Sendable {
    case pending(expiresAt: Date?)
    case declined
    case expired
    case scheduled
    case active(dayOrdinal: Int)
    case endsToday
    case tallying
    case completed
    case archived
}

enum CompetitionNotificationRefreshState: Equatable, Sendable {
    case none
    case completed
    case failed
}

enum CompetitionNotificationEvaluationFreshness: Equatable, Sendable {
    case notFresh
    case freshCompletedRefresh(attemptID: String, readAt: Date)
}

struct CompetitionNotificationDaySnapshot: Equatable, Sendable {
    let ordinal: Int
    let ownerAcceptedPoints: Double?
    let opponentRevealedPoints: Double?
}

struct CompetitionNotificationTerminalSnapshot: Equatable, Sendable {
    let ownerPoints: Double
    let opponentPoints: Double
    let outcome: CompetitionOutcome
}

struct CompetitionNotificationCompetitionSnapshot: Equatable, Sendable {
    let id: CompetitionID
    let opponentIdentity: String
    let opponentDisplayName: String
    let lifecycle: CompetitionNotificationLifecycle
    let schedule: CompetitionSchedule?
    let ownerPoints: Double
    let opponentPoints: Double
    let days: [CompetitionNotificationDaySnapshot]
    let currentDayOrdinal: Int?
    let latestRefresh: CompetitionNotificationRefreshState
    let evaluationFreshness: CompetitionNotificationEvaluationFreshness
    let terminalResult: CompetitionNotificationTerminalSnapshot?
    let emissionHistory: NotificationEmissionProjection
    /// The deterministic environment instant used for this projection. It is
    /// carried per aggregate so a CAS retry can rebuild fresh state without
    /// consulting the physical clock.
    let evaluatedAt: Date
    let timeZoneIdentifier: String

    init(
        id: CompetitionID,
        opponentIdentity: String,
        opponentDisplayName: String,
        lifecycle: CompetitionNotificationLifecycle,
        schedule: CompetitionSchedule?,
        ownerPoints: Double,
        opponentPoints: Double,
        days: [CompetitionNotificationDaySnapshot],
        currentDayOrdinal: Int?,
        latestRefresh: CompetitionNotificationRefreshState,
        evaluationFreshness: CompetitionNotificationEvaluationFreshness,
        terminalResult: CompetitionNotificationTerminalSnapshot?,
        emissionHistory: NotificationEmissionProjection,
        evaluatedAt: Date = .distantPast,
        timeZoneIdentifier: String = "UTC"
    ) {
        self.id = id
        self.opponentIdentity = opponentIdentity
        self.opponentDisplayName = opponentDisplayName
        self.lifecycle = lifecycle
        self.schedule = schedule
        self.ownerPoints = ownerPoints
        self.opponentPoints = opponentPoints
        self.days = days
        self.currentDayOrdinal = currentDayOrdinal
        self.latestRefresh = latestRefresh
        self.evaluationFreshness = evaluationFreshness
        self.terminalResult = terminalResult
        self.emissionHistory = emissionHistory
        self.evaluatedAt = evaluatedAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

struct CompetitionNotificationPlanningSnapshot: Equatable, Sendable {
    let publicationRevision: UInt64
    let evaluatedAt: Date
    let timeZoneIdentifier: String
    let competitions: [CompetitionNotificationCompetitionSnapshot]
    /// `nil` means store enumeration failed and orphan cleanup must not run.
    /// A non-nil set includes both successfully loaded and failed-load IDs.
    let knownCompetitionIDs: Set<CompetitionID>?

    init(
        publicationRevision: UInt64,
        evaluatedAt: Date,
        timeZoneIdentifier: String,
        competitions: [CompetitionNotificationCompetitionSnapshot],
        knownCompetitionIDs: Set<CompetitionID>? = nil
    ) {
        self.publicationRevision = publicationRevision
        self.evaluatedAt = evaluatedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.competitions = competitions
        self.knownCompetitionIDs = knownCompetitionIDs
    }
}

enum CompetitionNotificationMessageFamily: Equatable, Sendable {
    case scheduled(CompetitionScheduledNotificationFamily)
    case opportunistic(NotificationEmissionFamily)

    var rawValue: String {
        switch self {
        case let .scheduled(family):
            family.rawValue
        case let .opportunistic(family):
            family.rawValue
        }
    }
}

struct CompetitionNotificationMessage: Equatable, Sendable {
    let family: CompetitionNotificationMessageFamily
    let competitionID: CompetitionID
    let opponentDisplayName: String
    let ownerPoints: Double?
    let opponentPoints: Double?
    let outcome: CompetitionOutcome?
}

struct CompetitionNotificationEmissionDecision: Equatable, Sendable {
    let record: NotificationEmissionRecorded
    let request: CompetitionImmediateNotificationRequest
}

enum CompetitionNotificationDurableDecision: Equatable, Sendable {
    case emission(CompetitionNotificationEmissionDecision)
    case suppression(NotificationEmissionRecorded)

    var record: NotificationEmissionRecorded {
        switch self {
        case let .emission(decision):
            decision.record
        case let .suppression(record):
            record
        }
    }
}

enum CompetitionNotificationDecisionCommitResult: Equatable, Sendable {
    case appended([CompetitionNotificationDurableDecision])
    case duplicate
    case noDecision
}

enum CompetitionNotificationDeliveredCleanup: Equatable, Sendable {
    case all
    case nonResult
}

struct CompetitionNotificationPlan: Equatable, Sendable {
    let desiredScheduledRequests: [CompetitionScheduledNotificationRequest]
    let emissionDecisions: [CompetitionNotificationEmissionDecision]
    let suppressionRecords: [NotificationEmissionRecorded]
    let cancelCompetitionIDs: Set<CompetitionID>
    let deliveredCleanupByCompetitionID: [
        CompetitionID: CompetitionNotificationDeliveredCleanup
    ]

    static let empty = Self(
        desiredScheduledRequests: [],
        emissionDecisions: [],
        suppressionRecords: [],
        cancelCompetitionIDs: [],
        deliveredCleanupByCompetitionID: [:]
    )
}
