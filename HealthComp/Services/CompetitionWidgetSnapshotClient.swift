import CompetitionCore
import Dependencies
import Foundation
import WidgetKit

/// Writes the widgets' points-only snapshot into the App Group, and reloads
/// them only when what they show changed.
struct CompetitionWidgetSnapshotClient: Sendable {
    /// Writes `snapshot`, keeping last-written matches whose id is in `carryForward`.
    var write: @Sendable (_ snapshot: CompetitionWidgetSnapshot, _ carryForward: Set<UUID>) async -> Void
    var clear: @Sendable () async throws -> Void

    static let noop = Self(write: { _, _ in }, clear: {})

    static func live(fileURL: URL?, reload: @escaping @Sendable () -> Void) -> Self {
        let store = CompetitionWidgetSnapshotStore(fileURL: fileURL, reload: reload)
        return Self(
            write: { await store.write($0, carryForward: $1) },
            clear: { try await store.clear() }
        )
    }
}

private actor CompetitionWidgetSnapshotStore {
    private let fileURL: URL?
    private let reload: @Sendable () -> Void
    private var lastWritten: CompetitionWidgetSnapshot?
    private var isSeeded = false

    init(fileURL: URL?, reload: @escaping @Sendable () -> Void) {
        self.fileURL = fileURL
        self.reload = reload
    }

    func write(_ snapshot: CompetitionWidgetSnapshot, carryForward: Set<UUID>) {
        guard let fileURL else { return }
        if !isSeeded {
            // A relaunch with unchanged data then spends no reload, and
            // carry-forward has something to carry.
            lastWritten = CompetitionWidgetSnapshot.load(from: fileURL)
            isSeeded = true
        }
        let next = snapshot.merging(carriedForward: carryForward, from: lastWritten)
        guard next != lastWritten else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(next).write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = fileURL
            try url.setResourceValues(values)
        } catch {
            // ponytail: a failed write keeps the last file; the next publish retries
            return
        }
        // Every Health read sets a new time; that alone isn't worth a reload.
        if next.ignoringUpdatedAt != lastWritten?.ignoringUpdatedAt { reload() }
        lastWritten = next
    }

    func clear() throws {
        lastWritten = nil
        isSeeded = true
        guard let fileURL else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Nothing to clear.
        }
        reload()
    }
}

extension CompetitionWidgetSnapshotClient: DependencyKey {
    static let liveValue = Self.live(
        fileURL: CompetitionWidgetSnapshot.fileURL(),
        reload: { WidgetCenter.shared.reloadAllTimelines() }
    )
    static let testValue = Self.noop
}

extension DependencyValues {
    var competitionWidgetSnapshotClient: CompetitionWidgetSnapshotClient {
        get { self[CompetitionWidgetSnapshotClient.self] }
        set { self[CompetitionWidgetSnapshotClient.self] = newValue }
    }
}

extension CompetitionWidgetSnapshot {
    /// Live, scheduled and recent results only, with Home's numbers.
    init(dashboard: CompetitionDashboard) {
        self.init(
            matches: dashboard.competitions.compactMap(Match.init(presentation:)),
            hasIncomingChallenge: dashboard.competitions.contains {
                if case .pending(.incoming, _, _) = $0.lifecycle { true } else { false }
            }
        )
    }
}

extension CompetitionWidgetSnapshot.Match {
    init?(presentation p: CompetitionPresentation) {
        guard !p.isPractice else { return nil }
        let final: CompetitionWidgetSnapshot.Final?
        switch p.lifecycle {
        case .scheduled, .active, .endsToday, .tallying:
            final = nil
        case let .completed(outcome, _, completedAt):
            guard let leavesAt = competitionResultLeavesHome(p)?.at,
                  let outcome = CompetitionWidgetSnapshot.Final.Outcome(rawValue: outcome.rawValue)
            else { return nil }
            final = CompetitionWidgetSnapshot.Final(
                outcome: outcome, completedAt: completedAt, leavesAt: leavesAt
            )
        case .pending, .declined, .expired, .cancelled, .archived:
            return nil
        }
        guard let schedule = p.acceptedConfiguration?.schedule,
              let dayStarts = try? schedule.calendar
                .sevenDayWindow(startingOn: schedule.startDay)
                .map({ try schedule.calendar.startOfDay($0) }),
              let endsAt = competitionScheduleBoundaries(schedule)?.end,
              let url = CompetitionRoute.competition(p.id).url
        else { return nil }
        let days = Dictionary(p.days.map { ($0.ordinal, $0) }) { first, _ in first }
        self.init(
            id: p.id.rawValue,
            personID: p.opponentIdentity,
            name: p.opponentDisplayName,
            url: url,
            timeZoneIdentifier: schedule.calendar.timeZoneIdentifier,
            dayStarts: dayStarts,
            endsAt: endsAt,
            userPoints: p.userPoints,
            opponentPoints: p.opponentPoints,
            userDayPoints: (1...7).map { days[$0]?.ownerAcceptedPoints },
            opponentDayPoints: (1...7).map { days[$0]?.opponentRevealedPoints },
            updatedAt: [p.lastSuccessfulFullWindowRefreshAt, p.opponentUpdatedAt]
                .compactMap { $0 }.max(),
            final: final
        )
    }
}

#if DEBUG
extension CompetitionWidgetSnapshot {
    /// Widget states for the Mac mini UI tests (`--widget-scenario <name>`),
    /// in UTC days around `now`. Nil means no snapshot: the caller clears the file.
    static func testLab(_ scenario: String, now: Date) -> Self? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        /// `currentDay` 1...7 is live; 0 starts tomorrow, -1 the day after;
        /// 8 ended at today's midnight, 9 and more ended earlier.
        func match(
            _ index: Int, _ name: String, person: String? = nil, currentDay: Int,
            you: Double = 0, them: Double = 0,
            youDays: [Double?] = [], themDays: [Double?] = [],
            updated: Bool = true, final: Final.Outcome? = nil, leavesInDays: Int = 3
        ) -> Match {
            let first = day(1 - currentDay)
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", index))!
            func padded(_ values: [Double?]) -> [Double?] {
                Array((values + Array(repeating: nil, count: 7)).prefix(7))
            }
            return Match(
                id: id,
                personID: person ?? "sample:\(name.lowercased())",
                name: name,
                url: URL(string: "\(CompetitionRoute.customURLScheme)://competition/\(id.uuidString.lowercased())")!,
                timeZoneIdentifier: "UTC",
                dayStarts: (0..<7).map { calendar.date(byAdding: .day, value: $0, to: first)! },
                endsAt: calendar.date(byAdding: .day, value: 7, to: first)!,
                userPoints: you,
                opponentPoints: them,
                userDayPoints: padded(youDays),
                opponentDayPoints: padded(themDays),
                updatedAt: updated ? now.addingTimeInterval(-11 * 60) : nil,
                final: final.map {
                    Final(outcome: $0, completedAt: day(0).addingTimeInterval(3_600), leavesAt: day(leavesInDays))
                }
            )
        }
        let week: [Double?] = [250, 230, 262, 250, 212, 260, 300]
        let theirs: [Double?] = [230, 260, 280, 192, 188, 250, 240]
        let sam = match(5, "Sam", currentDay: 5, you: 1_204, them: 1_150, youDays: week, themDays: theirs)
        let alex = match(6, "Alex", currentDay: 2, you: 480, them: 455, youDays: [250, 230], themDays: [230, 225])
        let matches: [Match]
        var hasIncomingChallenge = false
        switch scenario {
        case "live": matches = [sam]
        case "trailing":
            matches = [match(5, "Sam", currentDay: 3, you: 610, them: 664,
                             youDays: [200, 210, 200], themDays: [220, 224, 220])]
        case "square":
            matches = [match(5, "Sam", currentDay: 2, you: 480, them: 480,
                             youDays: [250, 230], themDays: [230, 250])]
        case "lastDay":
            matches = [match(5, "Sam", currentDay: 7, you: 2_190, them: 2_171, youDays: week, themDays: theirs)]
        case "pending":
            matches = [match(5, "Sam", currentDay: 8, you: 2_190, them: 2_171, youDays: week, themDays: theirs)]
        case "won":
            matches = [match(5, "Sam", currentDay: 9, you: 1_840, them: 1_726,
                             youDays: week, themDays: theirs, final: .win)]
        case "lost":
            matches = [match(5, "Sam", currentDay: 9, you: 1_700, them: 1_720,
                             youDays: theirs, themDays: week, final: .loss)]
        case "tied":
            matches = [match(5, "Sam", currentDay: 9, you: 1_650, them: 1_650,
                             youDays: week, themDays: theirs, final: .tie)]
        case "scheduled": matches = [match(5, "Sam", currentDay: -1)]
        case "empty": matches = []
        case "challenge":
            matches = []
            hasIncomingChallenge = true
        case "longName":
            matches = [match(
                5, "Maximiliana Featherstonehaugh-Worthington", person: "sample:long", currentDay: 5,
                you: 12_045, them: 11_980, youDays: [2_500, 2_300, 2_620, 2_500, 2_125],
                themDays: [2_300, 2_600, 2_800, 1_920, 2_360]
            )]
        case "former":
            matches = [match(7, "Former competitor", person: "sample:former", currentDay: 9,
                             you: 1_840, them: 1_726, youDays: week, themDays: theirs, final: .win)]
        case "several":
            matches = [
                alex, sam,
                match(8, "Riley", currentDay: 8, you: 2_190, them: 2_171, youDays: week, themDays: theirs),
                match(9, "Casey", currentDay: -2),
                match(10, "Former competitor", person: "sample:former", currentDay: 9,
                      you: 1_840, them: 1_726, final: .win),
            ]
        case "noData":
            matches = [match(5, "Sam", currentDay: 4, you: 742, them: 510,
                             youDays: [250, 230, 262], themDays: [230, 280, nil], updated: false)]
        case "samGone":
            // Sam's result has left Home; only Alex is live.
            matches = [alex, match(5, "Sam", currentDay: 12, you: 1_840, them: 1_726, final: .win, leavesInDays: -1)]
        case "noSam": matches = [alex]
        default: return nil
        }
        return Self(matches: matches, hasIncomingChallenge: hasIncomingChallenge)
    }
}
#endif
