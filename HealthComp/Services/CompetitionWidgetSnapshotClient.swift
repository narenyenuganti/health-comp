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
