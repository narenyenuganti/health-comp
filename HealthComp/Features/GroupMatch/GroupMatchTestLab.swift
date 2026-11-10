#if DEBUG
import CompetitionCore
import ComposableArchitecture
import SwiftUI
import UIKit

/// `-groupLab <setup>` in the `group-matches` Test Lab scenario.
enum GroupMatchLabSetup: String, CaseIterable, Sendable {
    case formatPicker = "format-picker"
    case lineupFFA = "lineup-ffa"
    case lineupDoubles = "lineup-doubles"
    case botPicker = "bot-picker"
    case lobbyHost = "lobby-host"
    case lobbyDeclined = "lobby-declined"
    case lobbyInvitee = "lobby-invitee"
    case lobbyExpired = "lobby-expired"
    case lobbyShortInvitee = "lobby-short-invitee"
    case lobbyScheduled = "lobby-scheduled"
    case lobbyScheduledInvitee = "lobby-scheduled-invitee"
    case lobbyWithdrew = "lobby-withdrew"
    case inviteFFA = "invite-ffa"
    case versusFFA = "versus-ffa"
    case versusDoubles = "versus-doubles"
    case versusFFAPhotos = "versus-ffa-photos"
    case versusDoublesPhotos = "versus-doubles-photos"
    case versusBot = "versus-bot"
    case home
    case liveFFA = "live-ffa"
    case liveDoubles = "live-doubles"
    case liveBot = "live-bot"
    case day
    case banter
    case resultFFAWon = "result-ffa-won"
    case resultFFATied = "result-ffa-tied"
    case resultFFALost = "result-ffa-lost"
    case resultFFATiedThird = "result-ffa-tied-third"
    case resultDoubles = "result-doubles"
    case resultDoublesTied = "result-doubles-tied"
    case history
    /// The same History with no group match in it.
    case historyDuels = "history-duels"
}

extension GroupMatchLabSetup {
    var isVersus: Bool {
        [.versusFFA, .versusDoubles, .versusFFAPhotos, .versusDoublesPhotos, .versusBot].contains(self)
    }
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

    static func player(_ player: Player) -> GroupMatchPlayer {
        GroupMatchPlayer(profileID: player.profileID, name: player.name)
    }

    static let shareLink = URL(string: "https://invites.ui.healthcomp.test/c/Gm4tR8vX2pL6kN3wB9cY5z")!
    /// Maya's challenge link finds her; this one belongs to someone you can't add.
    static let mayaLink = "Mx7kQ2pL9vR4tN8wB3cY6z"
    static let unavailableLink = "Ux0aB1cD2eF3gH4iJ5kL6m"

    /// Takes a second, so the lookup shows that it's working.
    static let lookUpLink: @Sendable (CompetitionChallengeLinkCode) async -> GroupMatchLinkLookup = { code in
        try? await Task.sleep(for: .seconds(1))
        switch code.rawValue {
        case mayaLink: return .found(name: "Maya")
        case unavailableLink: return .unavailable
        default: return .notFound
        }
    }

    private static let now = MultiUserCompetitionTestLabFixtures.labNow
    private static let zone = "America/Los_Angeles"
    private static func schedule(month: Int, day: Int) -> CompetitionSchedule {
        CompetitionSchedule(
            calendar: try! CompetitionCalendar(timeZoneIdentifier: zone),
            startDay: try! CompetitionDay(era: 1, year: 2026, month: month, day: day, timeZoneIdentifier: zone)
        )
    }
    /// Everyone accepted today, so Day 1 is Monday.
    private static let tomorrow = (month: 8, day: 17)

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
    /// Answer by Sun 8 PM in Los Angeles.
    private static let waiting = LocalCompetitionLifecyclePresentation.pending(
        direction: .outgoing, createdAt: now, expiresAt: now.addingTimeInterval(19 * 3_600)
    )
    private static let waitingIncoming = LocalCompetitionLifecyclePresentation.pending(
        direction: .incoming, createdAt: now, expiresAt: now.addingTimeInterval(19 * 3_600)
    )
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
                1, .fourWay, waiting,
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
                3, .fourWay, waitingIncoming,
                [.sam, .priya, .leo, .you],
                viewerInvite: .invited,
                invites: [.leo: .invited]
            )
        case .lobbyInvitee:
            match(21, .fourWay, waitingIncoming, [.sam, .you, .priya, .leo], invites: [.leo: .invited])
        case .lobbyExpired:
            match(
                22, .doubles, .expired(at: now, direction: .outgoing), doublesLineup.map(\.0),
                invites: [.leo: .invited],
                teams: Dictionary(uniqueKeysWithValues: doublesLineup.map { ($0.0, $0.1) })
            )
        case .lobbyShortInvitee:
            match(
                23, .fourWay, .declined(at: now, direction: .incoming), [.sam, .you, .priya, .leo],
                invites: [.leo: .declined]
            )
        case .lobbyScheduled: match(24, .fourWay, .scheduled, ffaLineup, start: tomorrow)
        case .lobbyScheduledInvitee: match(25, .fourWay, .scheduled, [.sam, .you, .priya, .leo], start: tomorrow)
        case .lobbyWithdrew:
            match(26, .fourWay, .declined(at: now, direction: .outgoing), ffaLineup, invites: [.sam: .withdrew])
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
        case .resultFFALost: history[3]
        case .resultFFATiedThird:
            // Leo 1st, Sam 2nd, you and Priya both on 2,610.
            match(
                18, .fourWay,
                .completed(outcome: .loss, basis: .stableAcrossPostBoundaryReads, completedAt: now),
                ffaLineup,
                scores: [.you: week[.priya]!, .sam: week[.sam]!, .priya: week[.priya]!, .leo: week[.you]!],
                isFrozen: true
            )
        case .resultDoubles: doubles(10, won, scores: week, isFrozen: true)
        case .resultDoublesTied:
            // Both teams on 5,551.
            doubles(
                17,
                .completed(outcome: .tie, basis: .stableAcrossPostBoundaryReads, completedAt: now),
                scores: week.merging([.leo: [380, 400, 380, 400, 380, 360, 348]]) { $1 },
                isFrozen: true
            )
        case .versusFFA, .versusFFAPhotos: match(11, .fourWay, .scheduled, ffaLineup)
        case .versusDoubles, .versusDoublesPhotos: doubles(12, .scheduled)
        case .versusBot: match(27, .fourWay, .scheduled, [.you, .sam, .erratic, .leo])
        case .formatPicker, .lineupFFA, .lineupDoubles, .botPicker, .home, .day, .history, .historyDuels:
            nil
        }
    }

    /// Five finished weeks, newest first: a four-way you won, doubles won
    /// with Priya, a four-way tied for 1st, a three-way in 2nd and doubles
    /// lost with Sam.
    static var history: [GroupMatchPresentation] {
        let lost = LocalCompetitionLifecyclePresentation.completed(
            outcome: .loss, basis: .stableAcrossPostBoundaryReads, completedAt: now
        )
        let tied = LocalCompetitionLifecyclePresentation.completed(
            outcome: .tie, basis: .stableAcrossPostBoundaryReads, completedAt: now
        )
        return [
            match(8, .fourWay, won, ffaLineup, scores: week, isFrozen: true),
            match(
                13, .doubles, won, doublesLineup.map(\.0),
                teams: Dictionary(uniqueKeysWithValues: doublesLineup.map { ($0.0, $0.1) }),
                scores: week, isFrozen: true, start: (8, 6)
            ),
            match(14, .fourWay, tied, ffaLineup, scores: tiedWeek, isFrozen: true, start: (7, 30)),
            match(
                15, .threeWay, lost, [.you, .sam, .leo],
                scores: [.you: week[.priya]!, .sam: week[.sam]!, .leo: week[.leo]!], isFrozen: true, start: (7, 23)
            ),
            match(
                16, .doubles, lost, ffaLineup, teams: [.you: 1, .sam: 1, .priya: 2, .leo: 2],
                scores: [.you: week[.leo]!, .sam: week[.priya]!, .priya: week[.sam]!, .leo: week[.you]!],
                isFrozen: true, start: (7, 16)
            ),
        ]
    }

    /// History with duel weeks, plus the group weeks unless `duelsOnly`.
    static func historyPublication(duelsOnly: Bool) -> LocalCompetitionPublication {
        let duels = CompetitionRivalryFixture.publication(weeks: 5)
        return LocalCompetitionPublication(
            publicationRevision: duels.publicationRevision,
            dashboard: LocalCompetitionDashboard(
                competitions: duels.dashboard.competitions,
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0,
                groupMatches: duelsOnly ? [] : history
            ),
            evaluatedAt: duels.evaluatedAt,
            timeZoneIdentifier: duels.timeZoneIdentifier,
            source: duels.source
        )
    }

    /// Placeholder portraits for the photo intros: you, Sam and Priya; Leo
    /// keeps his initial, as in the mockup.
    static func photoData(_ setup: GroupMatchLabSetup) -> [UUID: Data] {
        guard setup == .versusFFAPhotos || setup == .versusDoublesPhotos else { return [:] }
        let tones: [(Player, UIColor)] = [(.you, .systemTeal), (.sam, .systemPurple), (.priya, .systemPink)]
        return Dictionary(uniqueKeysWithValues: tones.map { player, tone in
            let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400)).image { context in
                tone.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
                UIColor.white.withAlphaComponent(0.85).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 130, y: 70, width: 140, height: 160))
                context.cgContext.fillEllipse(in: CGRect(x: 60, y: 250, width: 280, height: 260))
            }
            return (player.profileID, image.jpegData(compressionQuality: 0.8)!)
        })
    }

    /// Home's cards: every state once, in the order Home lists them.
    static let homeSetups: [GroupMatchLabSetup] = [
        .inviteFFA, .lobbyHost, .liveFFA, .liveDoubles, .resultFFAWon, .resultDoubles, .lobbyDeclined,
    ]

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
                groupMatches: setup == .home
                    ? homeSetups.compactMap { routed($0) }
                    : [routed(setup, youLeft: youLeft)].compactMap { $0 }
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
        start: (month: Int, day: Int) = (8, 13),
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
        /// A finished fixture's server result: its places plus the seat
        /// totals and day values it was decided on.
        func build(frozen: GroupMatchPresentation?) -> GroupMatchPresentation {
            try! GroupMatchPresentation(
                id: CompetitionID(UUID(uuidString: "c3000000-0000-4000-8000-0000000000\(String(format: "%02d", id))")!),
                lifecycle: lifecycle,
                format: format,
                seats: seats,
                viewerSeatID: Player.you.seatID,
                schedule: schedule(month: start.month, day: start.day),
                days: days,
                rings: rings,
                leaveCutoffs: Dictionary(uniqueKeysWithValues: left.map { ($0.key.seatID, $0.value) }),
                frozenStandings: frozen?.standingRows,
                frozenSeatTotals: frozen?.projection.seatTotals,
                frozenDays: frozen?.days
            )
        }
        let projected = build(frozen: nil)
        return isFrozen ? build(frozen: projected) : projected
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
        let photos = GroupMatchFixtures.photoData(setup)
        var state = MainTabFeature.State(
            competition: CompetitionFeature.State(
                publication: first,
                ownProfile: AuthenticatedProfile(id: GroupMatchFixtures.Player.you.profileID, displayName: "You")
            ),
            path: setup == .home || setup.isVersus ? [] : first.dashboard.groupMatches.map(\.id)
        )
        for match in first.dashboard.groupMatches {
            state.competition.group.shareLinks[match.id] = GroupMatchFixtures.shareLink
        }
        _store = State(initialValue: Store(initialState: state) {
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
                loadProfilePhotos: { _ in throw CompetitionRemoteFailure.notFound },
                cachedProfilePhotoData: { photos[$0] },
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
        // Fixture times read in the match's zone, whatever the simulator's.
        content.environment(\.timeZone, TimeZone(identifier: "America/Los_Angeles")!)
    }

    @ViewBuilder
    private var content: some View {
        switch setup {
        case .formatPicker:
            GroupMatchCreateView(store: group, people: [GroupMatchFixtures.Player.sam, .priya, .leo].map(GroupMatchFixtures.player))
        case .lineupFFA:
            GroupMatchCreateView(
                store: group,
                people: [GroupMatchFixtures.Player.priya, .leo].map(GroupMatchFixtures.player),
                lineup: GroupMatchLineup(format: .fourWay, entries: [.person(GroupMatchFixtures.player(.sam))]),
                opensAt: [.lineup],
                lookUpLink: GroupMatchFixtures.lookUpLink
            )
        case .lineupDoubles:
            GroupMatchCreateView(
                store: group,
                people: [GroupMatchFixtures.player(.leo)],
                lineup: GroupMatchLineup(
                    format: .doubles, entries: [GroupMatchFixtures.Player.priya, .sam].map { .person(GroupMatchFixtures.player($0)) }
                ),
                opensAt: [.lineup],
                lookUpLink: GroupMatchFixtures.lookUpLink
            )
        case .botPicker:
            GroupMatchCreateView(
                store: group,
                people: [GroupMatchFixtures.Player.priya, .leo].map(GroupMatchFixtures.player),
                lineup: GroupMatchLineup(format: .fourWay, entries: [.person(GroupMatchFixtures.player(.sam))]),
                opensAt: [.lineup, .bots]
            )
        case .day:
            GroupMatchFixtures.routed(.liveFFA).map { match in
                NavigationStack { GroupMatchDayView(match: match, ordinal: 3, store: group) }
            }
        case .history, .historyDuels:
            NavigationStack {
                CompetitionHistoryView(publication: GroupMatchFixtures.historyPublication(duelsOnly: setup == .historyDuels))
            }
        case .versusFFA, .versusDoubles, .versusFFAPhotos, .versusDoublesPhotos, .versusBot:
            // Opened a beat after launch, so the photos are in when the intro decides.
            MainTabView(store: store)
                .task {
                    try? await Task.sleep(for: .seconds(1))
                    store.send(.pathChanged(store.competition.publication?.dashboard.groupMatches.map(\.id) ?? []))
                }
        case .home, .lobbyHost, .lobbyDeclined, .lobbyInvitee, .lobbyExpired, .lobbyShortInvitee,
             .lobbyScheduled, .lobbyScheduledInvitee, .lobbyWithdrew, .inviteFFA, .liveFFA, .liveDoubles, .liveBot, .banter,
             .resultFFAWon, .resultFFATied, .resultFFALost, .resultFFATiedThird, .resultDoubles, .resultDoublesTied:
            MainTabView(store: store)
        }
    }
}
#endif
