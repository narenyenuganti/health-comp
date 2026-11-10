import CompetitionCore
import Foundation

/// Hides the group format picker in Release until the server and the remote
/// commands are live.
enum GroupMatchRollout {
    #if DEBUG || HEALTHCOMP_STAGING
    static let showsFormatPicker = true
    #else
    static let showsFormatPicker = false
    #endif
}

enum GroupMatchFormat: String, CaseIterable, Hashable, Sendable {
    case threeWay = "three-way", fourWay = "four-way", doubles

    var title: String {
        switch self {
        case .threeWay: "Three-Way"
        case .fourWay: "Four-Way"
        case .doubles: "Doubles"
        }
    }

    var seatCount: Int { self == .threeWay ? 3 : 4 }
    var matchFormat: MatchFormat { self == .doubles ? .doubles : .freeForAll }
}

extension BotMode {
    var name: String { rawValue.capitalized }
}

enum GroupMatchInviteState: Equatable, Sendable {
    case invited, accepted, declined
}

struct GroupMatchSeat: Identifiable, Equatable, Sendable {
    enum Occupant: Equatable, Sendable {
        case person(profileID: UUID, invite: GroupMatchInviteState)
        case bot(BotMode)
    }

    let id: UUID
    /// 1...4; the creator is seat 1.
    let number: Int
    let name: String
    let occupant: Occupant
    var team: Int?

    var profileID: UUID? {
        if case let .person(id, _) = occupant { return id }
        return nil
    }

    var invite: GroupMatchInviteState? {
        if case let .person(_, invite) = occupant { return invite }
        return nil
    }

    var isBot: Bool { profileID == nil }
}

/// One person's accepted day as Move, Exercise and Stand, adding up to the
/// day's score. Bots never have rings.
struct GroupMatchDayRings: Equatable, Sendable {
    let seatID: UUID
    let ordinal: Int
    let centipoints: [Int]
}

/// A place in the standings: projected while live, the server's once finished.
struct GroupMatchStandingRow: Identifiable, Equatable, Sendable {
    let subject: MatchStandingSubject
    let place: Int
    let centipoints: Int

    var id: MatchStandingSubject { subject }
}

enum GroupMatchLead: Equatable, Sendable {
    case chasing(place: Int, gap: Int, behind: [MatchStandingSubject])
    case ahead(margin: Int)
    case tiedFirst(with: [MatchStandingSubject])
}

/// A group match as the screens read it. Lives in `dashboard.groupMatches`,
/// never `dashboard.competitions`, so no duel-only surface can receive one.
/// Places, ties, leads and day winners come from `MatchScoring`.
struct GroupMatchPresentation: Identifiable, Equatable, Sendable {
    let id: CompetitionID
    let lifecycle: LocalCompetitionLifecyclePresentation
    let format: GroupMatchFormat
    let seats: [GroupMatchSeat]
    let viewerSeatID: UUID
    /// Nil until the last person accepts.
    let schedule: CompetitionSchedule?
    let days: [MatchDayScore]
    let rings: [GroupMatchDayRings]
    /// The server's result, shown as is. Nil until the match finishes.
    let frozenStandings: [GroupMatchStandingRow]?
    /// Each seat's total in the server's result; nil when the result doesn't carry them.
    let frozenSeatTotals: [UUID: Int]?
    /// The day values the server's result was decided on; nil when it doesn't carry them.
    let frozenDays: [MatchDayScore]?
    let configuration: MatchConfiguration
    let projection: MatchScoreProjection

    init(
        id: CompetitionID,
        lifecycle: LocalCompetitionLifecyclePresentation,
        format: GroupMatchFormat,
        seats: [GroupMatchSeat],
        viewerSeatID: UUID,
        schedule: CompetitionSchedule? = nil,
        days: [MatchDayScore] = [],
        rings: [GroupMatchDayRings] = [],
        leaveCutoffs: [UUID: Int] = [:],
        frozenStandings: [GroupMatchStandingRow]? = nil,
        frozenSeatTotals: [UUID: Int]? = nil,
        frozenDays: [MatchDayScore]? = nil
    ) throws {
        guard seats.count == format.seatCount else { throw MatchScoringError.invalidRoster }
        guard seats.contains(where: { $0.id == viewerSeatID }) else { throw MatchScoringError.unknownSeat }
        let configuration = try MatchConfiguration(
            format: format.matchFormat,
            seats: seats.map {
                try MatchSeat(id: $0.id, kind: $0.profileID.map(MatchSeat.Kind.human) ?? .bot, team: $0.team)
            },
            leaveCutoffs: leaveCutoffs
        )
        self.id = id
        self.lifecycle = lifecycle
        self.format = format
        self.seats = seats
        self.viewerSeatID = viewerSeatID
        self.schedule = schedule
        self.days = days
        self.rings = rings
        self.frozenStandings = frozenStandings
        self.frozenSeatTotals = frozenSeatTotals
        self.frozenDays = frozenDays
        self.configuration = configuration
        self.projection = try MatchScoring.standings(
            configuration: configuration, days: days, throughDay: Self.throughDay(lifecycle)
        )
    }

    private static func throughDay(_ lifecycle: LocalCompetitionLifecyclePresentation) -> Int {
        switch lifecycle {
        case let .active(dayOrdinal): dayOrdinal
        case .endsToday, .tallying, .completed, .archived: 7
        case .pending, .declined, .expired, .cancelled, .scheduled: 1
        }
    }

    var viewer: GroupMatchSeat { seats.first { $0.id == viewerSeatID }! }

    /// Your seat, or your team in doubles.
    var viewerSubject: MatchStandingSubject {
        format == .doubles ? .team(viewer.team!) : .seat(viewerSeatID)
    }

    var standingRows: [GroupMatchStandingRow] {
        frozenStandings ?? projection.standings.map {
            GroupMatchStandingRow(subject: $0.subject, place: $0.place, centipoints: $0.centipoints)
        }
    }

    /// "You", "Sam", or "You + Priya".
    func name(of subject: MatchStandingSubject) -> String {
        let members = switch subject {
        case let .seat(id): seats.filter { $0.id == id }
        case let .team(team): seats.filter { $0.team == team }
        }
        return members
            .sorted { ($0.id == viewerSeatID ? 0 : $0.number) < ($1.id == viewerSeatID ? 0 : $1.number) }
            .map { $0.id == viewerSeatID ? "You" : $0.name }
            .joined(separator: " + ")
    }

    /// Nil once the server has frozen the result.
    var lead: GroupMatchLead? {
        guard frozenStandings == nil else { return nil }
        let standings = projection.standings
        if let next = MatchScoring.nextPlaceUp(for: viewerSubject, in: standings),
           let place = standings.first(where: { $0.subject == viewerSubject })?.place {
            return .chasing(place: place, gap: next.centipointsToTie, behind: next.subjects)
        }
        switch MatchScoring.lead(for: viewerSubject, in: standings) {
        case let .unique(margin): return .ahead(margin: margin)
        case let .shared(leaders): return .tiedFirst(with: leaders.filter { $0 != viewerSubject })
        case nil: return nil
        }
    }

    /// "You're 2nd. 48 behind Sam."
    var leadText: String? {
        guard let lead else { return nil }
        let isDoubles = format == .doubles
        func names(_ subjects: [MatchStandingSubject]) -> String {
            subjects.map(name(of:)).formatted(.list(type: .and))
        }
        switch lead {
        case let .chasing(place, gap, behind):
            return isDoubles
                ? "Your team is \(Self.pointsText(gap)) behind \(names(behind))."
                : "You're \(Self.placeText(place)). \(Self.pointsText(gap)) behind \(names(behind))."
        case let .ahead(margin):
            return "\(isDoubles ? "Your team leads" : "You lead") by \(Self.pointsText(margin))."
        case let .tiedFirst(others):
            return isDoubles
                ? "Your team is tied with \(names(others))."
                : "Tied for 1st with \(names(others))."
        }
    }

    func dayWinners(ordinal: Int) -> MatchDayWinners {
        (try? MatchScoring.dayWinners(
            configuration: configuration, days: days, ordinal: ordinal, throughDay: Self.throughDay(lifecycle)
        )) ?? .unresolved
    }

    /// This seat's whole-percent share of its team's points. Nil outside
    /// doubles or while the team has none.
    func carryPercent(seatID: UUID) -> Int? {
        guard let share = try? MatchScoring.teamShare(
            seat: seatID, configuration: configuration, days: days, throughDay: Self.throughDay(lifecycle)
        ) else { return nil }
        return (share.numerator * 200 + share.denominator) / (share.denominator * 2)
    }

    /// Days the subject won in the server's result, shared days included.
    /// Nil without the result's day values.
    func frozenDaysWon(by subject: MatchStandingSubject) -> Int? {
        guard let frozenDays else { return nil }
        return (1...7).filter { ordinal in
            guard case let .winners(subjects)? = try? MatchScoring.dayWinners(
                configuration: configuration, days: frozenDays, ordinal: ordinal, throughDay: 7
            ) else { return false }
            return subjects.contains(subject)
        }.count
    }

    /// This seat's whole-percent share of its team in the server's result.
    /// Nil without the result's seat totals or while the team has none.
    func frozenCarryPercent(seatID: UUID) -> Int? {
        guard let frozenSeatTotals, let team = seats.first(where: { $0.id == seatID })?.team,
              let numerator = frozenSeatTotals[seatID] else { return nil }
        let denominator = seats.filter { $0.team == team }.compactMap { frozenSeatTotals[$0.id] }.reduce(0, +)
        guard denominator > 0 else { return nil }
        return (numerator * 200 + denominator) / (denominator * 2)
    }

    static func placeText(_ place: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .ordinal
        return formatter.string(from: place as NSNumber) ?? String(place)
    }

    /// Whole points, with decimals only when rounding would hide a real gap.
    static func pointsText(_ centipoints: Int) -> String {
        let points = Double(centipoints) / 100
        return competitionPointsText(
            points,
            fractionDigits: competitionFinalFractionDigits(userPoints: points, opponentPoints: 0)
        )
    }
}
