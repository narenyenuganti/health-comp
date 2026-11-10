#if DEBUG
import CompetitionCore
import ComposableArchitecture
import SwiftUI

/// `-groupLab <setup>` in the `group-matches` Test Lab scenario.
enum GroupMatchLabSetup: String, CaseIterable, Sendable {
    case formatPicker = "format-picker"
    case lineupFFA = "lineup-ffa"
    case lineupDoubles = "lineup-doubles"
    case botPicker = "bot-picker"
    case lobbyHost = "lobby-host"
    case lobbyDeclined = "lobby-declined"
    case inviteFFA = "invite-ffa"
    case versusFFA = "versus-ffa"
    case versusDoubles = "versus-doubles"
    case home
    case liveFFA = "live-ffa"
    case liveDoubles = "live-doubles"
    case liveBot = "live-bot"
    case day
    case banter
    case resultFFAWon = "result-ffa-won"
    case resultFFATied = "result-ffa-tied"
    case resultDoubles = "result-doubles"
    case history
}

/// One match per mockup state. Now is Sun Aug 16, Day 4 of a week that began
/// on Thursday.
enum GroupMatchFixtures {
    enum Player: Int, CaseIterable {
        case you = 1, sam, priya, leo, erratic

        var name: String {
            switch self {
            case .you: "You"
            case .sam: "Sam"
            case .priya: "Priya"
            case .leo: "Leo"
            case .erratic: "Erratic"
            }
        }

        var seatID: UUID { UUID(uuidString: "c1000000-0000-4000-8000-00000000000\(rawValue)")! }
        var profileID: UUID { UUID(uuidString: "c2000000-0000-4000-8000-00000000000\(rawValue)")! }
    }

    static let samProfile = Player.sam.profileID

    private static let now = MultiUserCompetitionTestLabFixtures.labNow
    private static let zone = "America/Los_Angeles"
    private static let schedule = CompetitionSchedule(
        calendar: try! CompetitionCalendar(timeZoneIdentifier: zone),
        startDay: try! CompetitionDay(era: 1, year: 2026, month: 8, day: 13, timeZoneIdentifier: zone)
    )

    private static let fourDays: [Player: [Int]] = [
        .you: [421, 437, 398, 408],
        .sam: [448, 402, 451, 411],
        .priya: [380, 365, 402, 351],
        .leo: [310, 342, 288, 263],
        .erratic: [520, 180, 505, 240],
    ]
    private static let week: [Player: [Int]] = [
        .you: [421, 437, 398, 408, 460, 430, 387],
        .sam: [448, 402, 451, 411, 395, 410, 386],
        .priya: [380, 365, 402, 351, 370, 372, 370],
        .leo: [310, 342, 288, 263, 300, 320, 331],
    ]

    /// The tie is on exact points: you and Sam both finish on 2,941.
    private static var tiedWeek: [Player: [Int]] {
        week.merging([.sam: [448, 402, 451, 411, 395, 410, 424]]) { $1 }
    }

    private static let ffaLineup: [Player] = [.you, .sam, .priya, .leo]
    private static let doublesLineup: [(Player, Int)] = [(.you, 1), (.sam, 2), (.priya, 1), (.leo, 2)]
    private static let live = LocalCompetitionLifecyclePresentation.active(dayOrdinal: 4)
    private static let won = LocalCompetitionLifecyclePresentation.completed(
        outcome: .win, basis: .stableAcrossPostBoundaryReads, completedAt: now
    )

    /// The match a setup opens through `MainTabView`, or nil for one drawn on its own.
    static func routed(_ setup: GroupMatchLabSetup) -> GroupMatchPresentation? {
        routed(setup, youLeft: false)
    }

    /// `youLeft`: as after Leave Match on the live day.
    static func routed(_ setup: GroupMatchLabSetup, youLeft: Bool) -> GroupMatchPresentation? {
        let left: [Player: Int] = youLeft ? [.you: 4] : [:]
        return switch setup {
        case .lobbyHost:
            match(
                1, .fourWay,
                .pending(direction: .outgoing, createdAt: now, expiresAt: now.addingTimeInterval(86_400)),
                ffaLineup,
                invites: [.priya: .invited, .leo: .invited]
            )
        case .lobbyDeclined:
            match(
                2, .fourWay, .declined(at: now, direction: .outgoing),
                ffaLineup, invites: [.priya: .declined, .leo: .invited]
            )
        case .inviteFFA:
            match(
                3, .fourWay,
                .pending(direction: .incoming, createdAt: now, expiresAt: now.addingTimeInterval(86_400)),
                [.sam, .priya, .leo, .you],
                viewerInvite: .invited,
                invites: [.leo: .invited]
            )
        case .liveFFA: match(4, .fourWay, live, ffaLineup, scores: fourDays, left: left)
        case .liveDoubles: doubles(5, live, scores: fourDays, left: left)
        case .liveBot: match(6, .fourWay, live, [.you, .sam, .erratic, .leo], scores: fourDays, left: left)
        case .banter: doubles(7, live, scores: fourDays)
        case .resultFFAWon: match(8, .fourWay, won, ffaLineup, scores: week, isFrozen: true)
        case .resultFFATied:
            match(
                9, .fourWay,
                .completed(outcome: .tie, basis: .stableAcrossPostBoundaryReads, completedAt: now),
                ffaLineup, scores: tiedWeek, isFrozen: true
            )
        case .resultDoubles: doubles(10, won, scores: week, isFrozen: true)
        case .formatPicker, .lineupFFA, .lineupDoubles, .botPicker,
             .versusFFA, .versusDoubles, .home, .day, .history:
            nil
        }
    }

    static var versusFFA: GroupMatchPresentation { match(11, .fourWay, .scheduled, ffaLineup) }
    static var versusDoubles: GroupMatchPresentation { doubles(12, .scheduled) }

    static func publication(
        revision: UInt64, setup: GroupMatchLabSetup, youLeft: Bool = false
    ) -> LocalCompetitionPublication {
        LocalCompetitionPublication(
            publicationRevision: revision,
            dashboard: LocalCompetitionDashboard(
                competitions: [],
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0,
                groupMatches: [routed(setup, youLeft: youLeft)].compactMap { $0 }
            ),
            evaluatedAt: now,
            timeZoneIdentifier: zone,
            source: .remoteParticipants
        )
    }

    private static func doubles(
        _ id: Int,
        _ lifecycle: LocalCompetitionLifecyclePresentation,
        scores: [Player: [Int]] = [:],
        isFrozen: Bool = false,
        left: [Player: Int] = [:]
    ) -> GroupMatchPresentation {
        match(
            id, .doubles, lifecycle, doublesLineup.map(\.0),
            teams: Dictionary(uniqueKeysWithValues: doublesLineup.map { ($0.0, $0.1) }),
            scores: scores, isFrozen: isFrozen, left: left
        )
    }

    /// Fixtures are fixed values, so a validation failure is a bug in this file.
    private static func match(
        _ id: Int,
        _ format: GroupMatchFormat,
        _ lifecycle: LocalCompetitionLifecyclePresentation,
        _ lineup: [Player],
        viewerInvite: GroupMatchInviteState = .accepted,
        invites: [Player: GroupMatchInviteState] = [:],
        teams: [Player: Int] = [:],
        scores: [Player: [Int]] = [:],
        isFrozen: Bool = false,
        left: [Player: Int] = [:]
    ) -> GroupMatchPresentation {
        let seats = lineup.enumerated().map { index, player in
            GroupMatchSeat(
                id: player.seatID,
                number: index + 1,
                name: player.name,
                occupant: player == .erratic
                    ? .bot(.erratic)
                    : .person(
                        profileID: player.profileID,
                        invite: player == .you ? viewerInvite : invites[player] ?? .accepted
                    ),
                team: teams[player]
            )
        }
        let played = lineup.compactMap { player in scores[player].map { (player, $0) } }
        let days = played.flatMap { player, points in
            points.enumerated().map { day, value in
                try! MatchDayScore(seatID: player.seatID, ordinal: day + 1, value: .centipoints(value * 100))
            }
        }
        let rings = played.filter { $0.0 != .erratic }.flatMap { player, points in
            points.enumerated().map { day, value in
                let total = value * 100
                let move = total * 2 / 5
                let exercise = total * 3 / 10
                return GroupMatchDayRings(
                    seatID: player.seatID, ordinal: day + 1, centipoints: [move, exercise, total - move - exercise]
                )
            }
        }
        func build(frozen: [GroupMatchStandingRow]?) -> GroupMatchPresentation {
            try! GroupMatchPresentation(
                id: CompetitionID(UUID(uuidString: "c3000000-0000-4000-8000-0000000000\(String(format: "%02d", id))")!),
                lifecycle: lifecycle,
                format: format,
                seats: seats,
                viewerSeatID: Player.you.seatID,
                schedule: schedule,
                days: days,
                rings: rings,
                leaveCutoffs: Dictionary(uniqueKeysWithValues: left.map { ($0.key.seatID, $0.value) }),
                frozenStandings: frozen
            )
        }
        let projected = build(frozen: nil)
        return isFrozen ? build(frozen: projected.standingRows) : projected
    }
}

struct GroupMatchTestLabView: View {
    private let setup: GroupMatchLabSetup
    @State private var store: StoreOf<MainTabFeature>

    init() {
        let setup = GroupMatchLabSetup(
            rawValue: UserDefaults.standard.string(forKey: "groupLab") ?? ""
        ) ?? .home
        self.setup = setup
        let first = GroupMatchFixtures.publication(revision: 1, setup: setup)
        let answer = GroupMatchFixtures.publication(revision: 2, setup: setup)
        let left = GroupMatchFixtures.publication(revision: 2, setup: setup, youLeft: true)
        _store = State(initialValue: Store(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: first),
                path: first.dashboard.groupMatches.map(\.id)
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = CompetitionClient(
                start: { AsyncStream { $0.yield(first) } },
                updates: { AsyncStream { _ in } },
                reconcileAll: { _ in first },
                accept: { _ in first },
                decline: { _ in first },
                archive: { _ in first },
                rematch: { _ in first },
                reinvite: { first },
                waitUntil: { _ in },
                stop: {},
                groupMatchCommand: { command in
                    if case .leave = command { return left }
                    return answer
                }
            )
            $0.competitionRoutingClient = CompetitionRoutingClient(
                routes: { AsyncStream { _ in } },
                enqueue: { _ in },
                consume: { _ in }
            )
            $0.permissionOnboardingClient = .inert
            $0.date = .constant(MultiUserCompetitionTestLabFixtures.labNow)
        })
    }

    private var group: StoreOf<GroupMatchFeature> {
        store.scope(state: \.competition.group, action: \.competition.group)
    }

    var body: some View {
        switch setup {
        case .formatPicker: GroupMatchCreateView(step: .format, store: group)
        case .lineupFFA: GroupMatchCreateView(step: .lineup(.fourWay), store: group, people: [GroupMatchFixtures.samProfile])
        case .lineupDoubles: GroupMatchCreateView(step: .lineup(.doubles), store: group, people: [GroupMatchFixtures.samProfile])
        case .botPicker: GroupMatchCreateView(step: .bots, store: group)
        // In a ScrollView: the lab root's identifier otherwise replaces a bare stack's.
        case .versusFFA: ScrollView { GroupMatchVersusIntro(match: GroupMatchFixtures.versusFFA) }
        case .versusDoubles: ScrollView { GroupMatchVersusIntro(match: GroupMatchFixtures.versusDoubles) }
        case .home:
            ScrollView {
                GroupMatchHomeCards(matches: [.liveFFA, .liveDoubles].compactMap(GroupMatchFixtures.routed))
            }
        case .day:
            GroupMatchFixtures.routed(.liveFFA).map { match in
                NavigationStack { GroupMatchDayView(match: match, ordinal: 3, store: group) }
            }
        case .history: ScrollView { GroupMatchRecord() }
        case .lobbyHost, .lobbyDeclined, .inviteFFA, .liveFFA, .liveDoubles, .liveBot, .banter,
             .resultFFAWon, .resultFFATied, .resultDoubles:
            MainTabView(store: store)
        }
    }
}
#endif
