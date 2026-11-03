import CompetitionCore
import Foundation
import XCTest
@testable import HealthComp

final class CompetitionLiveActivityTests: XCTestCase {
    typealias Planner = CompetitionLiveActivityPlanner
    typealias Step = CompetitionLiveActivityStep
    typealias Snapshot = CompetitionLiveActivitySnapshot

    private let la = TimeZone(identifier: "America/Los_Angeles")!
    private let en = Locale(identifier: "en_US")

    private func at(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    /// Folds U+202F and other spaces, as in the formatting checks.
    private func normalized(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Sam, Day 1 = Sun Nov 1 2026 in `zone`, so Day 7 is Sat Nov 7 and an
    /// LA match ends at 2026-11-08T08:00Z.
    private func sam(
        _ n: Int = 1,
        name: String = "Sam",
        zone: String = "America/Los_Angeles",
        lifecycle: LocalCompetitionLifecyclePresentation = .endsToday,
        user: Double = 2190.4,
        opponent: Double = 2171.2,
        yourRefresh: Date?? = nil,
        theirUpdate: Date?? = nil
    ) -> CompetitionPresentation {
        let schedule = CompetitionSchedule(
            calendar: try! CompetitionCalendar(timeZoneIdentifier: zone),
            startDay: try! CompetitionDay(era: 1, year: 2026, month: 11, day: 1, timeZoneIdentifier: zone)
        )
        return CompetitionPresentation(
            id: id(n),
            ownerDisplayName: "Naren",
            opponentDisplayName: name,
            opponentIdentity: "remote-profile:v1:sam",
            lifecycle: lifecycle,
            acceptedConfiguration: LocalCompetitionAcceptedPresentation(schedule: schedule, difficulty: .balanced),
            userPoints: user,
            opponentPoints: opponent,
            days: [],
            currentDayOrdinal: 7,
            lastRefresh: nil,
            tally: nil,
            terminalResult: nil,
            evaluatedAt: at("2026-11-08T02:05:00Z"),
            timeZoneIdentifier: zone,
            lastSuccessfulFullWindowRefreshAt: yourRefresh ?? at("2026-11-08T01:40:00Z"),
            opponentUpdatedAt: theirUpdate ?? at("2026-11-08T02:02:00Z")
        )
    }

    private func id(_ n: Int) -> CompetitionID {
        CompetitionID(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", n))!)
    }

    private func key(_ n: Int) -> String { id(n).rawValue.uuidString.lowercased() }

    private func steps(
        _ presentations: [CompetitionPresentation],
        source: CompetitionPublicationSource = .remoteParticipants,
        known: Set<CompetitionID>?? = nil,
        current: [Snapshot] = [],
        started: Set<String> = [],
        isAllowed: Bool = true,
        now: String = "2026-11-08T02:05:00Z",
        timeZone: TimeZone? = nil
    ) -> [Step] {
        Planner.steps(
            presentations: presentations,
            source: source,
            knownCompetitionIDs: known ?? Set(presentations.map(\.id)),
            current: current,
            started: started,
            isAllowed: isAllowed,
            now: at(now),
            locale: en,
            timeZone: timeZone ?? la
        )
    }

    private func content(_ p: CompetitionPresentation) -> MatchActivityAttributes.ContentState {
        Planner.content(p, locale: en, timeZone: la)!
    }

    private func startedID(_ steps: [Step]) -> String? {
        guard steps.count == 1, case let .start(attributes, _) = steps[0] else { return nil }
        return attributes.matchID
    }

    func testStartsOnlyInTheLastSevenAndAHalfHoursOfDay7() throws {
        XCTAssertEqual(steps([sam()], now: "2026-11-08T00:29:00Z"), [])

        let first = steps([sam()], now: "2026-11-08T00:30:00Z")
        guard case let .start(attributes, state) = try XCTUnwrap(first.first) else {
            return XCTFail("\(first)")
        }
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(attributes.matchID, key(1))
        XCTAssertEqual(attributes.endsAt, at("2026-11-08T08:00:00Z"))
        XCTAssertEqual(attributes.url.absoluteString, "healthcomp://competition/\(key(1))")
        XCTAssertEqual(state.phase, .live)

        XCTAssertEqual(startedID(steps([sam()], now: "2026-11-08T07:59:00Z")), key(1))
        // A stored publication replanned after midnight.
        XCTAssertEqual(steps([sam()], now: "2026-11-08T08:00:00Z"), [])
        XCTAssertEqual(steps([sam(lifecycle: .active(dayOrdinal: 6))]), [])
    }

    func testLiveContentUsesSharedWords() {
        let state = content(sam())
        XCTAssertEqual(state.title, "Last day")
        XCTAssertEqual(state.timing, "Ends at midnight")
        XCTAssertEqual(state.opponentName, "Sam")
        XCTAssertEqual(state.userPoints, 2190.4)
        XCTAssertEqual(normalized(state.freshness), "You: updated 5:40 PM · Sam: updated 6:02 PM")

        let newYork = Planner.content(sam(), locale: en, timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(newYork?.timing, "Ends at midnight PST")

        XCTAssertEqual(normalized(content(sam(theirUpdate: .some(nil))).freshness), "Updated 5:40 PM")
        XCTAssertEqual(normalized(content(sam(yourRefresh: .some(nil))).freshness), "Sam: updated 6:02 PM")
        XCTAssertNil(content(sam(yourRefresh: .some(nil), theirUpdate: .some(nil))).freshness)
    }

    func testNeverStartsTwiceOrForAStartedMatch() {
        XCTAssertEqual(steps([sam()], started: [key(1)]), [])

        let a = sam(1)
        let running = Snapshot(matchID: key(1), state: content(a))
        XCTAssertEqual(steps([a, sam(2)], current: [running]), [])
        let moved = steps([sam(1, user: 2300), sam(2)], current: [running])
        XCTAssertEqual(moved.count, 1)
        guard case let .update(matchID, _, _) = moved.first else { return XCTFail("\(moved)") }
        XCTAssertEqual(matchID, key(1))
    }

    func testPicksTheMatchEndingSoonest() {
        let losAngeles = sam(1)
        let newYork = sam(2, zone: "America/New_York")
        XCTAssertEqual(startedID(steps([losAngeles, newYork], now: "2026-11-08T01:00:00Z")), key(2))
        XCTAssertEqual(startedID(steps([sam(4), sam(3)], now: "2026-11-08T01:00:00Z")), key(3))
    }

    func testUpdatesOnlyWhenContentChanges() {
        let running = Snapshot(matchID: key(1), state: content(sam()))
        XCTAssertEqual(steps([sam()], current: [running]), [])

        XCTAssertEqual(
            steps([sam(user: 2200)], current: [running]),
            [.update(matchID: key(1), content(sam(user: 2200)), staleDate: at("2026-11-08T08:00:00Z"))]
        )

        let renamed = steps([sam(name: "Former competitor")], current: [running])
        guard case let .update(_, state, _) = renamed.first else { return XCTFail("\(renamed)") }
        XCTAssertEqual(state.opponentName, "Former competitor")
    }

    func testTallyingBecomesFinalScorePending() {
        let running = Snapshot(matchID: key(1), state: content(sam()))
        let tallying = sam(lifecycle: .tallying(startedAt: at("2026-11-08T08:00:00Z")))
        let result = steps([tallying], current: [running], now: "2026-11-08T09:00:00Z")
        guard case let .update(matchID, state, staleDate) = result.first, result.count == 1 else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(matchID, key(1))
        XCTAssertEqual(state.phase, .pending)
        XCTAssertEqual(state.title, "Final score pending")
        XCTAssertNil(state.timing)
        XCTAssertNil(staleDate)
        // Never starts a card on a pending match.
        XCTAssertEqual(steps([tallying], now: "2026-11-08T07:00:00Z"), [])
    }

    func testStaleLiveContentResolvesToPending() {
        let stale = content(sam()).resolved(isStale: true)
        XCTAssertEqual(stale.phase, .pending)
        XCTAssertEqual(stale.title, MatchActivityCopy.pending)
        XCTAssertNil(stale.timing)
        XCTAssertEqual(stale.userPoints, 2190.4)
        XCTAssertEqual(content(sam()).resolved(isStale: false), content(sam()))
        XCTAssertEqual(
            MatchActivityCopy.pending,
            competitionStatusText(
                .tallying(startedAt: .distantPast), schedule: nil,
                opponentDisplayName: "Sam", style: .card
            ).title
        )
    }

    func testFinishedOrDisallowedEndsImmediately() {
        let running = Snapshot(matchID: key(1), state: content(sam()))
        let won = sam(lifecycle: .completed(outcome: .win, basis: .stableAcrossPostBoundaryReads, completedAt: at("2026-11-08T09:00:00Z")))
        XCTAssertEqual(steps([won], current: [running]), [.end(matchID: key(1), forgetStart: false)])
        XCTAssertEqual(steps([sam()], current: [running], isAllowed: false), [.end(matchID: key(1), forgetStart: true)])
        XCTAssertEqual(steps([sam()], source: .simulatedFixture, current: [running]), [.end(matchID: key(1), forgetStart: true)])
        XCTAssertEqual(steps([sam()], source: .simulatedFixture), [])
        let cancelled = sam(lifecycle: .cancelled(at: at("2026-11-08T01:00:00Z")))
        XCTAssertEqual(steps([cancelled], current: [running]), [.end(matchID: key(1), forgetStart: false)])
    }

    func testMissingMatchEndsOnlyWhenListIsAuthoritative() {
        let running = Snapshot(matchID: key(1), state: content(sam()))
        XCTAssertEqual(steps([], known: .some([]), current: [running]), [.end(matchID: key(1), forgetStart: false)])
        XCTAssertEqual(steps([], known: .some(nil), current: [running]), [])
    }

    func testExtraActivitiesAreEnded() {
        let first = Snapshot(matchID: key(1), state: content(sam(1)))
        let second = Snapshot(matchID: key(2), state: content(sam(2)))
        XCTAssertEqual(
            steps([sam(1), sam(2)], current: [first, second]),
            [.end(matchID: key(2), forgetStart: false)]
        )
    }

    func testActorRecordsStartsAndEndAllForgetsThem() async {
        let probe = LiveActivityProbe(started: ["older"])
        let activities = CompetitionLiveActivities(client: probe.client, now: { ISO8601DateFormatter().date(from: "2026-11-08T02:05:00Z")! })
        let publication = CompetitionPublication(
            publicationRevision: 1,
            dashboard: CompetitionDashboard(competitions: [sam()], awards: [], issues: [], hiddenTerminalCompetitionCount: 0),
            source: .remoteParticipants
        )
        await activities.submit(publication, knownCompetitionIDs: [id(1)])
        XCTAssertEqual(probe.starts, [key(1)])
        XCTAssertEqual(probe.started, ["older", key(1)])

        // Started once: a swiped-away card doesn't come back.
        probe.running = []
        await activities.reconcileLatest()
        XCTAssertEqual(probe.starts, [key(1)])

        probe.running = [Snapshot(matchID: key(1), state: content(sam()))]
        await activities.endAll()
        XCTAssertEqual(probe.ends, [key(1)])
        XCTAssertEqual(probe.started, ["older"])
        // endAll drops the publication: nothing to replan.
        await activities.reconcileLatest()
        XCTAssertEqual(probe.starts, [key(1)])
    }
}

/// Records what the actor asks ActivityKit to do.
final class LiveActivityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _running: [CompetitionLiveActivitySnapshot] = []
    private var _started: [String]
    private var _starts: [String] = []
    private var _ends: [String] = []
    private var _currentCalls = 0
    private var _setCalls = 0

    init(running: [CompetitionLiveActivitySnapshot] = [], started: [String] = []) {
        _running = running
        _started = started
    }

    var running: [CompetitionLiveActivitySnapshot] {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }
    var started: [String] { lock.withLock { _started } }
    var starts: [String] { lock.withLock { _starts } }
    var ends: [String] { lock.withLock { _ends } }
    var currentCalls: Int { lock.withLock { _currentCalls } }
    var setCalls: Int { lock.withLock { _setCalls } }

    var client: CompetitionLiveActivityClient {
        CompetitionLiveActivityClient(
            current: { self.lock.withLock { self._currentCalls += 1; return self._running } },
            start: { attributes, state, _ in
                self.lock.withLock {
                    self._starts.append(attributes.matchID)
                    self._running.append(.init(matchID: attributes.matchID, state: state))
                }
                return true
            },
            update: { matchID, state, _ in
                self.lock.withLock {
                    self._running = self._running.map {
                        $0.matchID == matchID ? .init(matchID: matchID, state: state) : $0
                    }
                }
            },
            end: { matchID in
                self.lock.withLock {
                    self._ends.append(matchID)
                    self._running.removeAll { $0.matchID == matchID }
                }
            },
            isAllowed: { true },
            startedMatchIDs: { self.lock.withLock { self._started } },
            setStartedMatchIDs: { ids in self.lock.withLock { self._setCalls += 1; self._started = ids } }
        )
    }
}
