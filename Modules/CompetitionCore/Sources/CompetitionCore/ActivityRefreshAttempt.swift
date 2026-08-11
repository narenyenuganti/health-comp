import Foundation

public enum ActivityRefreshTrigger: String, Codable, Equatable, Sendable {
    case launch
    case foreground
    case pullToRefresh
    case summaryUpdate
    case observerWakeupForeground
    case observerWakeupBackground
    case dayBoundary
    case timeZoneChange
    case protectedDataAvailable
    case reconciliationProbe
}

/// A deliberately closed, privacy-safe classification. It never contains an
/// HealthKit error description and never claims that read access was denied.
public enum ActivityQueryFailureReason: String, Codable, Equatable, Sendable {
    case protectedDataUnavailable
    case healthDataUnavailable
    case queryCancelled
    case transientFailure
    case invalidResponse
    case unknown
}

public enum ActivityRefreshReadStatus: Codable, Equatable, Sendable {
    case completed
    case failed(reason: ActivityQueryFailureReason)

    internal var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

/// Per-day mapping failures remain closed and non-diagnostic. Adapter error
/// strings and authorization inferences never enter the durable journal.
public enum ActivityUnavailableReason: String, Codable, Equatable, Sendable {
    case sourceDataUnavailable
    case unsupportedActivityConfiguration
    case invalidSourceData
}

public enum ActivityDayAvailability: Codable, Equatable, Sendable {
    case notYetOccurred
    case observed(ActivitySnapshot)
    case missing
    case unavailable(reason: ActivityUnavailableReason)

    internal var containsSourceData: Bool {
        switch self {
        case .observed, .missing:
            return true
        case .notYetOccurred, .unavailable:
            return false
        }
    }
}

public struct ActivityDayObservation: Codable, Equatable, Sendable {
    public let day: CompetitionDay
    public let ordinal: Int
    public let availability: ActivityDayAvailability

    public init(
        day: CompetitionDay,
        ordinal: Int,
        availability: ActivityDayAvailability
    ) {
        self.day = day
        self.ordinal = ordinal
        self.availability = availability
    }
}

public struct ActivityRefreshAttemptRecorded: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidAttemptID
        case invalidAttemptOrdinal(UInt64)
        case invalidDate
        case readPrecedesAttempt
        case invalidMonotonicEpoch
        case invalidDayPartition
        case duplicateCompetitionDay
        case failedReadContainsSourceData
        case semanticIDMismatch(expected: String, actual: String)
    }

    public let semanticEventID: String
    public let attemptID: String
    public let competitionID: CompetitionID
    public let attemptOrdinal: UInt64
    public let trigger: ActivityRefreshTrigger
    public let attemptedAt: Date
    public let readAt: Date
    public let monotonicInstant: MonotonicInstant
    public let readStatus: ActivityRefreshReadStatus
    public let days: [ActivityDayObservation]

    public init(
        attemptID: String,
        competitionID: CompetitionID,
        attemptOrdinal: UInt64,
        trigger: ActivityRefreshTrigger,
        attemptedAt: Date,
        readAt: Date,
        monotonicInstant: MonotonicInstant,
        readStatus: ActivityRefreshReadStatus,
        days: [ActivityDayObservation]
    ) throws {
        try self.init(
            semanticEventID: Self.semanticID(
                competitionID: competitionID,
                attemptOrdinal: attemptOrdinal
            ),
            attemptID: attemptID,
            competitionID: competitionID,
            attemptOrdinal: attemptOrdinal,
            trigger: trigger,
            attemptedAt: attemptedAt,
            readAt: readAt,
            monotonicInstant: monotonicInstant,
            readStatus: readStatus,
            days: days
        )
    }

    public static func semanticID(
        competitionID: CompetitionID,
        attemptOrdinal: UInt64
    ) -> String {
        [
            "activity-refresh-attempt-recorded",
            "v1",
            competitionID.rawValue.uuidString.lowercased(),
            "attempt",
            String(attemptOrdinal),
        ].joined(separator: ":")
    }

    private init(
        semanticEventID: String,
        attemptID: String,
        competitionID: CompetitionID,
        attemptOrdinal: UInt64,
        trigger: ActivityRefreshTrigger,
        attemptedAt: Date,
        readAt: Date,
        monotonicInstant: MonotonicInstant,
        readStatus: ActivityRefreshReadStatus,
        days: [ActivityDayObservation]
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
        guard attemptOrdinal > 0 else {
            throw ValidationError.invalidAttemptOrdinal(attemptOrdinal)
        }
        guard attemptedAt.timeIntervalSinceReferenceDate.isFinite,
              readAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw ValidationError.invalidDate
        }
        guard attemptedAt <= readAt else {
            throw ValidationError.readPrecedesAttempt
        }
        guard !monotonicInstant.epochID.isEmpty else {
            throw ValidationError.invalidMonotonicEpoch
        }
        guard days.map(\.ordinal) == Array(1...7) else {
            throw ValidationError.invalidDayPartition
        }
        guard Set(days.map(\.day)).count == 7 else {
            throw ValidationError.duplicateCompetitionDay
        }
        if case .failed = readStatus,
           days.contains(where: { $0.availability.containsSourceData }) {
            throw ValidationError.failedReadContainsSourceData
        }
        let expectedID = Self.semanticID(
            competitionID: competitionID,
            attemptOrdinal: attemptOrdinal
        )
        guard semanticEventID == expectedID else {
            throw ValidationError.semanticIDMismatch(
                expected: expectedID,
                actual: semanticEventID
            )
        }

        self.semanticEventID = semanticEventID
        self.attemptID = attemptID
        self.competitionID = competitionID
        self.attemptOrdinal = attemptOrdinal
        self.trigger = trigger
        self.attemptedAt = attemptedAt
        self.readAt = readAt
        self.monotonicInstant = monotonicInstant
        self.readStatus = readStatus
        self.days = days
    }

    private enum CodingKeys: String, CodingKey {
        case semanticEventID
        case attemptID
        case competitionID
        case attemptOrdinal
        case trigger
        case attemptedAt
        case readAt
        case monotonicInstant
        case readStatus
        case days
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            semanticEventID: container.decode(
                String.self,
                forKey: .semanticEventID
            ),
            attemptID: container.decode(String.self, forKey: .attemptID),
            competitionID: container.decode(
                CompetitionID.self,
                forKey: .competitionID
            ),
            attemptOrdinal: container.decode(
                UInt64.self,
                forKey: .attemptOrdinal
            ),
            trigger: container.decode(
                ActivityRefreshTrigger.self,
                forKey: .trigger
            ),
            attemptedAt: container.decode(Date.self, forKey: .attemptedAt),
            readAt: container.decode(Date.self, forKey: .readAt),
            monotonicInstant: container.decode(
                MonotonicInstant.self,
                forKey: .monotonicInstant
            ),
            readStatus: container.decode(
                ActivityRefreshReadStatus.self,
                forKey: .readStatus
            ),
            days: container.decode(
                [ActivityDayObservation].self,
                forKey: .days
            )
        )
    }
}

public struct ActivityRefreshProjection: Equatable, Sendable {
    public internal(set) var latestAttempt: ActivityRefreshAttemptRecorded?
    public internal(set) var lastSuccessfulFullWindowRefreshAt: Date?
    public internal(set) var nextAttemptOrdinal: UInt64

    internal var seenAttemptIDs: Set<String>

    public init() {
        self.latestAttempt = nil
        self.lastSuccessfulFullWindowRefreshAt = nil
        self.nextAttemptOrdinal = 1
        self.seenAttemptIDs = []
    }

    internal mutating func record(
        _ attempt: ActivityRefreshAttemptRecorded
    ) throws {
        guard attempt.attemptOrdinal == nextAttemptOrdinal else {
            throw ActivityRefreshProjectionError.ordinalViolation(
                expected: nextAttemptOrdinal,
                found: attempt.attemptOrdinal
            )
        }
        guard nextAttemptOrdinal < UInt64.max else {
            throw ActivityRefreshProjectionError.ordinalOverflow
        }
        guard seenAttemptIDs.insert(attempt.attemptID).inserted else {
            throw ActivityRefreshProjectionError.duplicateAttemptID(
                attempt.attemptID
            )
        }

        latestAttempt = attempt
        if attempt.readStatus.isCompleted {
            lastSuccessfulFullWindowRefreshAt = attempt.readAt
        }
        nextAttemptOrdinal += 1
    }
}

internal enum ActivityRefreshProjectionError: Error, Equatable, Sendable {
    case ordinalViolation(expected: UInt64, found: UInt64)
    case duplicateAttemptID(String)
    case ordinalOverflow
}

public enum ActivityRefreshEvidenceError: Error, Equatable, Sendable {
    case competitionNotTallying
    case refreshForDifferentCompetition
    case invalidRefreshTransition
    case refreshProjectionMismatch
}
