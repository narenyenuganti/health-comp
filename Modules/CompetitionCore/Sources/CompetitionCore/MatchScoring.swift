import Foundation

public enum MatchFormat: String, Codable, Sendable {
    case freeForAll, doubles
}

public enum MatchScoringError: Error, Equatable, Sendable {
    case invalidSeatID, invalidProfileID, invalidRoster, invalidTeams
    case invalidDay, invalidCentipoints, unknownSeat, duplicateDay, invalidLeaveCutoff, invalidAfterLeave
}

private let matchNilUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

public struct MatchSeat: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case human(UUID)
        case bot
    }

    public let id: UUID
    public let kind: Kind
    public let team: Int?

    public init(id: UUID, kind: Kind, team: Int? = nil) throws {
        guard id != matchNilUUID else { throw MatchScoringError.invalidSeatID }
        if case let .human(profileID) = kind, profileID == matchNilUUID {
            throw MatchScoringError.invalidProfileID
        }
        self.id = id
        self.kind = kind
        self.team = team
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      kind: values.decode(Kind.self, forKey: .kind),
                      team: values.decodeIfPresent(Int.self, forKey: .team))
    }
}

public struct MatchConfiguration: Codable, Equatable, Sendable {
    public let format: MatchFormat
    public let seats: [MatchSeat]
    /// Inclusive last banked day; missing banked scores and later days are resolved zero contributions.
    public let leaveCutoffs: [UUID: Int]

    public init(format: MatchFormat, seats: [MatchSeat], leaveCutoffs: [UUID: Int] = [:]) throws {
        let profiles = seats.compactMap { seat -> UUID? in
            if case let .human(id) = seat.kind { return id }
            return nil
        }
        guard (3...4).contains(seats.count), Set(seats.map(\.id)).count == seats.count,
              profiles.count >= 2, Set(profiles).count == profiles.count else {
            throw MatchScoringError.invalidRoster
        }
        switch format {
        case .freeForAll:
            guard seats.allSatisfy({ $0.team == nil }) else { throw MatchScoringError.invalidTeams }
        case .doubles:
            let teams = Dictionary(grouping: seats, by: \.team)
            guard seats.count == 4, teams.count == 2, teams[nil] == nil,
                  teams.values.allSatisfy({ $0.count == 2 }) else { throw MatchScoringError.invalidTeams }
        }
        let humanSeatIDs = Set(seats.filter { $0.kind != .bot }.map(\.id))
        guard leaveCutoffs.allSatisfy({ humanSeatIDs.contains($0.key) && (1...7).contains($0.value) }) else {
            throw MatchScoringError.invalidLeaveCutoff
        }
        self.format = format
        self.seats = seats
        self.leaveCutoffs = leaveCutoffs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(format: values.decode(MatchFormat.self, forKey: .format),
                      seats: values.decode([MatchSeat].self, forKey: .seats),
                      leaveCutoffs: values.decode([UUID: Int].self, forKey: .leaveCutoffs))
    }
}

public enum MatchDayValue: Codable, Equatable, Sendable {
    case centipoints(Int)
    case notSynced, unavailable, afterLeave

    private enum CodingKeys: String, CodingKey { case centipoints, notSynced, unavailable, afterLeave }
    private enum PayloadKeys: String, CodingKey { case _0 }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.allKeys.count == 1, let key = values.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected one day value"))
        }
        switch key {
        case .centipoints:
            let payload = try values.nestedContainer(keyedBy: PayloadKeys.self, forKey: key)
            let points = try payload.decode(Int.self, forKey: ._0)
            guard (0...60_000).contains(points) else { throw MatchScoringError.invalidCentipoints }
            self = .centipoints(points)
        case .notSynced: self = .notSynced
        case .unavailable: self = .unavailable
        case .afterLeave: self = .afterLeave
        }
    }
}

public struct MatchDayScore: Codable, Equatable, Sendable {
    public let seatID: UUID
    public let ordinal: Int
    public let value: MatchDayValue

    public init(seatID: UUID, ordinal: Int, value: MatchDayValue) throws {
        guard seatID != matchNilUUID else { throw MatchScoringError.invalidSeatID }
        guard (1...7).contains(ordinal) else { throw MatchScoringError.invalidDay }
        if case let .centipoints(points) = value, !(0...60_000).contains(points) {
            throw MatchScoringError.invalidCentipoints
        }
        self.seatID = seatID
        self.ordinal = ordinal
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(seatID: values.decode(UUID.self, forKey: .seatID),
                      ordinal: values.decode(Int.self, forKey: .ordinal),
                      value: values.decode(MatchDayValue.self, forKey: .value))
    }
}

public enum MatchStandingSubject: Codable, Hashable, Sendable {
    case seat(UUID)
    case team(Int)
}

public struct MatchStanding: Equatable, Sendable {
    public let subject: MatchStandingSubject
    public let place: Int
    public let centipoints: Int
}

public struct MatchScoreProjection: Equatable, Sendable {
    public let seatTotals: [UUID: Int]
    public let standings: [MatchStanding]
    public let isProvisional: Bool
}

public enum MatchDayWinners: Equatable, Sendable {
    case unresolved
    /// Live projections only; finished matches use the server's frozen result.
    case winners([MatchStandingSubject])
}

public struct MatchNextPlaceUp: Equatable, Sendable {
    public let subjects: [MatchStandingSubject]
    public let centipointsToTie: Int
}

public enum MatchLead: Equatable, Sendable {
    case unique(margin: Int)
    case shared([MatchStandingSubject])
}

public struct MatchTeamShare: Equatable, Sendable {
    public let numerator: Int
    public let denominator: Int
}

public enum MatchScoring {
    public static func standings(configuration: MatchConfiguration, days: [MatchDayScore],
                                 throughDay: Int) throws -> MatchScoreProjection {
        let values = try validatedValues(configuration: configuration, days: days, throughDay: throughDay)
        return project(configuration: configuration, values: values, ordinals: 1...throughDay)
    }

    public static func dayWinners(configuration: MatchConfiguration, days: [MatchDayScore],
                                  ordinal: Int, throughDay: Int) throws -> MatchDayWinners {
        guard (1...7).contains(ordinal) else { throw MatchScoringError.invalidDay }
        let values = try validatedValues(configuration: configuration, days: days, throughDay: throughDay)
        guard ordinal <= throughDay else { return .unresolved }
        let projection = project(configuration: configuration, values: values, ordinals: ordinal...ordinal)
        guard !projection.isProvisional else { return .unresolved }
        return .winners(projection.standings.filter { $0.place == 1 }.map(\.subject))
    }

    public static func nextPlaceUp(for subject: MatchStandingSubject,
                                   in standings: [MatchStanding]) -> MatchNextPlaceUp? {
        guard let current = standings.first(where: { $0.subject == subject }),
              let target = standings.filter({ $0.centipoints > current.centipoints }).map(\.centipoints).min() else {
            return nil
        }
        return MatchNextPlaceUp(subjects: standings.filter { $0.centipoints == target }.map(\.subject),
                                centipointsToTie: target - current.centipoints)
    }

    public static func lead(for subject: MatchStandingSubject, in standings: [MatchStanding]) -> MatchLead? {
        guard let current = standings.first(where: { $0.subject == subject }), current.place == 1 else { return nil }
        let leaders = standings.filter { $0.place == 1 }
        if leaders.count > 1 { return .shared(leaders.map(\.subject)) }
        guard let second = standings.filter({ $0.subject != subject }).map(\.centipoints).max() else { return nil }
        return .unique(margin: current.centipoints - second)
    }

    /// Accepted week-to-date totals, including provisional projections; no rounding or reduction.
    public static func teamShare(seat seatID: UUID, configuration: MatchConfiguration,
                                 days: [MatchDayScore], throughDay: Int) throws -> MatchTeamShare? {
        guard let seat = configuration.seats.first(where: { $0.id == seatID }) else { throw MatchScoringError.unknownSeat }
        let projection = try standings(configuration: configuration, days: days, throughDay: throughDay)
        guard let team = seat.team,
              let total = projection.standings.first(where: { $0.subject == .team(team) })?.centipoints,
              total > 0 else { return nil }
        return MatchTeamShare(numerator: projection.seatTotals[seatID]!, denominator: total)
    }

    private static func validatedValues(configuration: MatchConfiguration, days: [MatchDayScore],
                                        throughDay: Int) throws -> [UUID: [Int: MatchDayValue]] {
        guard (1...7).contains(throughDay) else { throw MatchScoringError.invalidDay }
        let ids = Set(configuration.seats.map(\.id))
        var values: [UUID: [Int: MatchDayValue]] = [:]
        for day in days {
            guard ids.contains(day.seatID) else { throw MatchScoringError.unknownSeat }
            guard values[day.seatID]?[day.ordinal] == nil else { throw MatchScoringError.duplicateDay }
            let isAfterLeave = configuration.leaveCutoffs[day.seatID].map { day.ordinal > $0 } ?? false
            guard (day.value == .afterLeave) == isAfterLeave else { throw MatchScoringError.invalidAfterLeave }
            values[day.seatID, default: [:]][day.ordinal] = day.value
        }
        return values
    }

    private static func project(configuration: MatchConfiguration, values: [UUID: [Int: MatchDayValue]],
                                ordinals: ClosedRange<Int>) -> MatchScoreProjection {
        var totals: [UUID: Int] = [:]
        var provisional = false
        for seat in configuration.seats {
            var total = 0
            for ordinal in ordinals {
                let afterLeave = configuration.leaveCutoffs[seat.id].map { ordinal > $0 } ?? false
                let value = values[seat.id]?[ordinal] ?? (afterLeave ? .afterLeave : .notSynced)
                switch value {
                case let .centipoints(points): total += points
                case .notSynced, .unavailable:
                    // Leaving seals the bank: no later upload can fill a missing score.
                    if configuration.leaveCutoffs[seat.id] == nil { provisional = true }
                case .afterLeave: break
                }
            }
            totals[seat.id] = total
        }
        var subjectTotals: [MatchStandingSubject: Int] = [:]
        for seat in configuration.seats {
            let subject: MatchStandingSubject = configuration.format == .doubles ? .team(seat.team!) : .seat(seat.id)
            subjectTotals[subject, default: 0] += totals[seat.id]!
        }
        // Stable order is solely for display; it never breaks a scoring tie.
        let ordered = subjectTotals.keys.sorted { lhs, rhs in
            if subjectTotals[lhs]! != subjectTotals[rhs]! { return subjectTotals[lhs]! > subjectTotals[rhs]! }
            switch (lhs, rhs) {
            case let (.seat(a), .seat(b)): return a.uuidString < b.uuidString
            case let (.team(a), .team(b)): return a < b
            default: return false
            }
        }
        let standings = ordered.map { subject in
            MatchStanding(subject: subject,
                          place: 1 + subjectTotals.values.filter { $0 > subjectTotals[subject]! }.count,
                          centipoints: subjectTotals[subject]!)
        }
        return MatchScoreProjection(seatTotals: totals, standings: standings, isProvisional: provisional)
    }
}
