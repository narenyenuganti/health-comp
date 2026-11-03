import ActivityKit
import CompetitionCore
import Foundation

enum CompetitionLiveActivityPreference {
    /// Matches that already got a card, oldest first, so one swiped away
    /// doesn't come back on the next launch.
    static let startedKey = "healthcomp.liveActivity.startedMatchIDs"
    static let startedLimit = 20
}

/// A running (`.active` or `.stale`) activity.
struct CompetitionLiveActivitySnapshot: Equatable, Sendable {
    let matchID: String
    let state: MatchActivityAttributes.ContentState
}

enum CompetitionLiveActivityStep: Equatable, Sendable {
    case start(MatchActivityAttributes, MatchActivityAttributes.ContentState)
    case update(matchID: String, MatchActivityAttributes.ContentState, staleDate: Date?)
    /// `forgetStart` lets the card start again: true for ends the person
    /// didn't cause by finishing the match.
    case end(matchID: String, forgetStart: Bool)
}

/// Which card runs, for which match, with what content. Pure.
enum CompetitionLiveActivityPlanner {
    // ponytail: iOS caps a Live Activity at 8 h; 7.5 h guarantees the stale (pending) look before that. Push-to-start would lift this.
    static let startLead: TimeInterval = 7.5 * 60 * 60

    static func content(
        _ p: CompetitionPresentation,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> MatchActivityAttributes.ContentState? {
        let phase: MatchActivityAttributes.ContentState.Phase
        switch p.lifecycle {
        case .endsToday: phase = .live
        case .tallying: phase = .pending
        default: return nil
        }
        let status = competitionStatusText(p, style: .card, locale: locale, timeZone: timeZone)
        return MatchActivityAttributes.ContentState(
            phase: phase,
            title: status.title,
            // Pending has no timing, like a card gone stale at midnight.
            timing: phase == .live ? status.timing : nil,
            opponentName: p.opponentDisplayName,
            userPoints: p.userPoints,
            opponentPoints: p.opponentPoints,
            freshness: competitionFreshnessText(p, locale: locale, timeZone: timeZone)
        )
    }

    static func attributes(_ p: CompetitionPresentation) -> MatchActivityAttributes? {
        guard let schedule = p.acceptedConfiguration?.schedule,
              let endsAt = competitionScheduleBoundaries(schedule)?.end,
              let url = CompetitionRoute.competition(p.id).url
        else { return nil }
        return MatchActivityAttributes(
            matchID: p.id.rawValue.uuidString.lowercased(), endsAt: endsAt, url: url
        )
    }

    static func steps(
        presentations: [CompetitionPresentation],
        source: CompetitionPublicationSource,
        knownCompetitionIDs: Set<CompetitionID>?,
        current: [CompetitionLiveActivitySnapshot],
        started: Set<String>,
        isAllowed: Bool,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [CompetitionLiveActivityStep] {
        // The fixture runs on a logical clock, so its stale date would be wrong.
        guard isAllowed, source == .remoteParticipants else {
            return current.map { .end(matchID: $0.matchID, forgetStart: true) }
        }
        let presentations = presentations.filter { !$0.isPractice }
        let byID = Dictionary(
            presentations.map { ($0.id.rawValue.uuidString.lowercased(), $0) }
        ) { first, _ in first }
        var steps: [CompetitionLiveActivityStep] = []
        for (index, activity) in current.enumerated() {
            // A leftover from a race: keep the first.
            guard index == 0 else {
                steps.append(.end(matchID: activity.matchID, forgetStart: false))
                continue
            }
            guard let p = byID[activity.matchID] else {
                // Without discovery a missing match may still be there.
                if knownCompetitionIDs != nil {
                    steps.append(.end(matchID: activity.matchID, forgetStart: false))
                }
                continue
            }
            guard let state = content(p, locale: locale, timeZone: timeZone) else {
                steps.append(.end(matchID: activity.matchID, forgetStart: false))
                continue
            }
            if state != activity.state {
                let staleDate = state.phase == .live ? attributes(p)?.endsAt : nil
                steps.append(.update(matchID: activity.matchID, state, staleDate: staleDate))
            }
        }
        // An existing card keeps its match until it ends.
        guard current.isEmpty else { return steps }
        let candidates = presentations.compactMap { p -> CompetitionLiveActivityStep? in
            guard case .endsToday = p.lifecycle,
                  let attributes = attributes(p),
                  !started.contains(attributes.matchID),
                  attributes.endsAt - startLead <= now, now < attributes.endsAt,
                  let state = content(p, locale: locale, timeZone: timeZone)
            else { return nil }
            return .start(attributes, state)
        }
        let first = candidates.min {
            guard case let .start(a, _) = $0, case let .start(b, _) = $1 else { return false }
            return (a.endsAt, a.matchID) < (b.endsAt, b.matchID)
        }
        return steps + [first].compactMap { $0 }
    }
}

/// ActivityKit behind closures, so tests never touch it.
struct CompetitionLiveActivityClient: Sendable {
    var current: @Sendable () async -> [CompetitionLiveActivitySnapshot]
    /// False when iOS refuses, for example with the app in the background.
    var start: @Sendable (
        MatchActivityAttributes, MatchActivityAttributes.ContentState, _ staleDate: Date?
    ) async -> Bool
    var update: @Sendable (
        _ matchID: String, MatchActivityAttributes.ContentState, _ staleDate: Date?
    ) async -> Void
    var end: @Sendable (_ matchID: String) async -> Void
    var isAllowed: @Sendable () -> Bool
    /// Oldest first.
    var startedMatchIDs: @Sendable () -> [String]
    var setStartedMatchIDs: @Sendable ([String]) -> Void

    static let noop = Self(
        current: { [] },
        start: { _, _, _ in false },
        update: { _, _, _ in },
        end: { _ in },
        isAllowed: { false },
        startedMatchIDs: { [] },
        setStartedMatchIDs: { _ in }
    )

    static let live = Self(
        current: {
            Activity<MatchActivityAttributes>.activities
                .filter { $0.activityState == .active || $0.activityState == .stale }
                .map { .init(matchID: $0.attributes.matchID, state: $0.content.state) }
        },
        start: { attributes, state, staleDate in
            do {
                _ = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                return true
            } catch {
                return false
            }
        },
        update: { matchID, state, staleDate in
            for activity in Activity<MatchActivityAttributes>.activities
            where activity.attributes.matchID == matchID {
                await activity.update(ActivityContent(state: state, staleDate: staleDate))
            }
        },
        end: { matchID in
            for activity in Activity<MatchActivityAttributes>.activities
            where activity.attributes.matchID == matchID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        },
        isAllowed: {
            ActivityAuthorizationInfo().areActivitiesEnabled
                && !CompetitionNotificationChoice.switchedOff().contains(.liveActivity)
        },
        startedMatchIDs: {
            UserDefaults.standard.stringArray(forKey: CompetitionLiveActivityPreference.startedKey) ?? []
        },
        setStartedMatchIDs: {
            UserDefaults.standard.set($0, forKey: CompetitionLiveActivityPreference.startedKey)
        }
    )
}

/// Runs the planner against the latest publication and applies its steps.
/// Callers serialize calls (the remote coordinator's operation gate).
actor CompetitionLiveActivities {
    private let client: CompetitionLiveActivityClient
    private let now: @Sendable () -> Date
    private var latest: (publication: CompetitionPublication, knownCompetitionIDs: Set<CompetitionID>?)?

    init(client: CompetitionLiveActivityClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    func submit(_ publication: CompetitionPublication, knownCompetitionIDs: Set<CompetitionID>?) async {
        latest = (publication, knownCompetitionIDs)
        await reconcileLatest()
    }

    /// No network: replans the stored publication against the real time.
    func reconcileLatest() async {
        guard let latest else { return }
        let before = client.startedMatchIDs()
        var started = before
        let steps = CompetitionLiveActivityPlanner.steps(
            presentations: latest.publication.dashboard.competitions,
            source: latest.publication.source,
            knownCompetitionIDs: latest.knownCompetitionIDs,
            current: await client.current(),
            started: Set(before),
            isAllowed: client.isAllowed(),
            now: now()
        )
        for step in steps {
            switch step {
            case let .start(attributes, state):
                if await client.start(attributes, state, attributes.endsAt) {
                    started.removeAll { $0 == attributes.matchID }
                    started.append(attributes.matchID)
                }
            case let .update(matchID, state, staleDate):
                await client.update(matchID, state, staleDate)
            case let .end(matchID, forgetStart):
                await client.end(matchID)
                if forgetStart { started.removeAll { $0 == matchID } }
            }
        }
        started = Array(started.suffix(CompetitionLiveActivityPreference.startedLimit))
        if started != before { client.setStartedMatchIDs(started) }
    }

    /// Sign-out, session end or a failed mount: nobody's name stays on the
    /// Lock Screen, and a later mount may start the card again.
    func endAll() async {
        latest = nil
        let ended = await client.current().map(\.matchID)
        guard !ended.isEmpty else { return }
        for matchID in ended { await client.end(matchID) }
        client.setStartedMatchIDs(client.startedMatchIDs().filter { !ended.contains($0) })
    }
}
