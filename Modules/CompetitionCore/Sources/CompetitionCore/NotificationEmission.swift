import Foundation

/// Opportunistic notification families whose one-time emission decisions are
/// durable. Calendar-scheduled requests are derived state and are deliberately
/// not represented here.
public enum NotificationEmissionFamily: String, Codable, CaseIterable, Sendable {
    case leadChange = "lead-change"
    case closeScore = "close-score"
    case dailyMaximum = "daily-max"
    case result
    case catchUp = "catch-up"
}

public enum NotificationEmissionLeader: String, Codable, CaseIterable, Sendable {
    case owner
    case opponent
}

/// A closed, canonical episode identity. Its encoded form is the suffix used
/// by the semantic notification identifier.
public enum NotificationEpisodeKey: Equatable, Sendable {
    case day(Int)
    case leader(dayOrdinal: Int, leader: NotificationEmissionLeader)
    case result
    case tallying

    public var dayOrdinal: Int? {
        switch self {
        case let .day(dayOrdinal), let .leader(dayOrdinal, _):
            return dayOrdinal
        case .result, .tallying:
            return nil
        }
    }

    fileprivate var semanticKey: String {
        switch self {
        case let .day(dayOrdinal):
            return "day:\(dayOrdinal)"
        case let .leader(dayOrdinal, leader):
            return "day:\(dayOrdinal):leader:\(leader.rawValue)"
        case .result:
            return "result"
        case .tallying:
            return "tallying"
        }
    }
}

extension NotificationEpisodeKey: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let persisted = try container.decode(String.self)
        let components = persisted.split(
            separator: ":",
            omittingEmptySubsequences: false
        ).map(String.init)

        let decoded: Self?
        switch components.count {
        case 1 where components[0] == "result":
            decoded = .result
        case 1 where components[0] == "tallying":
            decoded = .tallying
        case 2 where components[0] == "day":
            decoded = Self.canonicalDay(components[1]).map(Self.day)
        case 4 where components[0] == "day" && components[2] == "leader":
            if let dayOrdinal = Self.canonicalDay(components[1]),
               let decodedLeader = NotificationEmissionLeader(
                    rawValue: components[3]
               ) {
                decoded = .leader(
                    dayOrdinal: dayOrdinal,
                    leader: decodedLeader
                )
            } else {
                decoded = nil
            }
        default:
            decoded = nil
        }

        guard let decoded, decoded.semanticKey == persisted else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid notification episode key."
            )
        }
        self = decoded
    }

    public func encode(to encoder: Encoder) throws {
        if let dayOrdinal, !(1...7).contains(dayOrdinal) {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Notification day ordinal must be 1 through 7."
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(semanticKey)
    }

    private static func canonicalDay(_ value: String) -> Int? {
        guard let dayOrdinal = Int(value),
              (1...7).contains(dayOrdinal),
              String(dayOrdinal) == value
        else {
            return nil
        }
        return dayOrdinal
    }
}

public enum NotificationSuppressionReason: String, Codable, CaseIterable, Sendable {
    case superseded
    case staleEpisode
    case budgetExceeded
}

public enum NotificationEmissionDisposition: Codable, Equatable, Sendable {
    case emitted
    case suppressed(reason: NotificationSuppressionReason)
}

/// A durable decision to consume one opportunistic notification episode.
/// This value records no notification copy, activity values, or OS delivery
/// claim. Acceptance by an OS notification API is outside this domain model.
public struct NotificationEmissionRecorded: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidDayOrdinal(Int)
        case episodeDoesNotMatchFamily
        case invalidDecisionDate
        case invalidPublicationRevision(UInt64)
        case semanticIDMismatch(expected: String, actual: String)
    }

    public let semanticEventID: String
    public let competitionID: CompetitionID
    public let family: NotificationEmissionFamily
    public let episodeKey: NotificationEpisodeKey
    public let disposition: NotificationEmissionDisposition
    public let decidedAt: Date
    public let basisPublicationRevision: UInt64

    public init(
        competitionID: CompetitionID,
        family: NotificationEmissionFamily,
        episodeKey: NotificationEpisodeKey,
        disposition: NotificationEmissionDisposition,
        decidedAt: Date,
        basisPublicationRevision: UInt64
    ) throws {
        try Self.validate(family: family, episodeKey: episodeKey)
        guard decidedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ValidationError.invalidDecisionDate
        }
        guard basisPublicationRevision > 0 else {
            throw ValidationError.invalidPublicationRevision(
                basisPublicationRevision
            )
        }

        self.semanticEventID = try Self.semanticID(
            competitionID: competitionID,
            family: family,
            episodeKey: episodeKey
        )
        self.competitionID = competitionID
        self.family = family
        self.episodeKey = episodeKey
        self.disposition = disposition
        self.decidedAt = decidedAt
        self.basisPublicationRevision = basisPublicationRevision
    }

    public static func semanticID(
        competitionID: CompetitionID,
        family: NotificationEmissionFamily,
        episodeKey: NotificationEpisodeKey
    ) throws -> String {
        try validate(family: family, episodeKey: episodeKey)
        return [
            "competition-notification",
            "v1",
            competitionID.rawValue.uuidString.lowercased(),
            family.rawValue,
            episodeKey.semanticKey,
        ].joined(separator: ":")
    }

    private enum CodingKeys: String, CodingKey {
        case semanticEventID
        case competitionID
        case family
        case episodeKey
        case disposition
        case decidedAt
        case basisPublicationRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persistedID = try container.decode(
            String.self,
            forKey: .semanticEventID
        )
        let competitionID = try container.decode(
            CompetitionID.self,
            forKey: .competitionID
        )
        let family = try container.decode(
            NotificationEmissionFamily.self,
            forKey: .family
        )
        let episodeKey = try container.decode(
            NotificationEpisodeKey.self,
            forKey: .episodeKey
        )
        let disposition = try container.decode(
            NotificationEmissionDisposition.self,
            forKey: .disposition
        )
        let decidedAt = try container.decode(Date.self, forKey: .decidedAt)
        let basisPublicationRevision = try container.decode(
            UInt64.self,
            forKey: .basisPublicationRevision
        )

        try self.init(
            competitionID: competitionID,
            family: family,
            episodeKey: episodeKey,
            disposition: disposition,
            decidedAt: decidedAt,
            basisPublicationRevision: basisPublicationRevision
        )
        guard semanticEventID == persistedID else {
            throw ValidationError.semanticIDMismatch(
                expected: semanticEventID,
                actual: persistedID
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(semanticEventID, forKey: .semanticEventID)
        try container.encode(competitionID, forKey: .competitionID)
        try container.encode(family, forKey: .family)
        try container.encode(episodeKey, forKey: .episodeKey)
        try container.encode(disposition, forKey: .disposition)
        try container.encode(decidedAt, forKey: .decidedAt)
        try container.encode(
            basisPublicationRevision,
            forKey: .basisPublicationRevision
        )
    }

    private static func validate(
        family: NotificationEmissionFamily,
        episodeKey: NotificationEpisodeKey
    ) throws {
        if let dayOrdinal = episodeKey.dayOrdinal,
           !(1...7).contains(dayOrdinal) {
            throw ValidationError.invalidDayOrdinal(dayOrdinal)
        }

        let matches: Bool
        switch (family, episodeKey) {
        case (.leadChange, .leader),
             (.closeScore, .day),
             (.dailyMaximum, .day),
             (.result, .result),
             (.catchUp, .day),
             (.catchUp, .tallying):
            matches = true
        default:
            matches = false
        }
        guard matches else {
            throw ValidationError.episodeDoesNotMatchFamily
        }
    }
}

public struct NotificationEmissionProjection: Equatable, Sendable {
    public private(set) var recordedIDs: Set<String>
    public private(set) var emittedCountByDayOrdinal: [Int: Int]

    public init(
        recordedIDs: Set<String> = [],
        emittedCountByDayOrdinal: [Int: Int] = [:]
    ) {
        self.recordedIDs = recordedIDs
        self.emittedCountByDayOrdinal = emittedCountByDayOrdinal
    }

    internal mutating func record(_ event: NotificationEmissionRecorded) {
        recordedIDs.insert(event.semanticEventID)
        guard case .emitted = event.disposition,
              let dayOrdinal = event.episodeKey.dayOrdinal
        else {
            return
        }
        emittedCountByDayOrdinal[dayOrdinal, default: 0] += 1
    }
}
