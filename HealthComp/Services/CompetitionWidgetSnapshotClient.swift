import CompetitionCore
import Dependencies
import Foundation
import WidgetKit

struct CompetitionWidgetSnapshotClient: Sendable {
    var write: @Sendable (_ snapshot: CompetitionWidgetSnapshot, _ carryForward: Set<UUID>) async -> Void
    var clear: @Sendable () async throws -> Void

    static let noop = Self(write: { _, _ in }, clear: {})

    static func live(
        fileURL: URL?,
        reload: @escaping @Sendable () -> Void,
        mirror: @escaping @Sendable (CompetitionWidgetSnapshot?, Bool) -> Void = { _, _ in }
    ) -> Self {
        let store = CompetitionWidgetSnapshotStore(fileURL: fileURL, reload: reload, mirror: mirror)
        return Self(
            write: { await store.write($0, carryForward: $1) },
            clear: { try await store.clear() }
        )
    }
}

private actor CompetitionWidgetSnapshotStore {
    private let fileURL: URL?
    private let reload: @Sendable () -> Void
    private let mirror: @Sendable (CompetitionWidgetSnapshot?, Bool) -> Void
    private var lastWritten: CompetitionWidgetSnapshot?
    private var isSeeded = false

    init(
        fileURL: URL?,
        reload: @escaping @Sendable () -> Void,
        mirror: @escaping @Sendable (CompetitionWidgetSnapshot?, Bool) -> Void
    ) {
        self.fileURL = fileURL
        self.reload = reload
        self.mirror = mirror
    }

    func write(_ snapshot: CompetitionWidgetSnapshot, carryForward: Set<UUID>) {
        guard let fileURL else { return }
        if !isSeeded {
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
            return
        }
        let material = next.ignoringUpdatedAt != lastWritten?.ignoringUpdatedAt
        if material { reload() }
        mirror(next, material)
        lastWritten = next
    }

    func clear() throws {
        lastWritten = nil
        isSeeded = true
        guard let fileURL else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
        }
        reload()
        mirror(nil, true)
    }
}

extension CompetitionWidgetSnapshotClient: DependencyKey {
    static let liveValue: Self = {
        let snapshots = Self.live(
            fileURL: CompetitionWidgetSnapshot.fileURL(),
            reload: { WidgetCenter.shared.reloadAllTimelines() },
            mirror: { CompetitionWatchSync.shared.mirror($0, material: $1) }
        )
        let notifications = CompetitionNotificationClient.liveValue
        return Self(
            write: snapshots.write,
            clear: {
                try await snapshots.clear()
                await CompetitionLiveActivities(client: .live).endAll()
                let namespace = CompetitionNotificationIdentifier.namespace
                let pending = await notifications.pendingIDs(namespace)
                if !pending.isEmpty { await notifications.removePending(pending.sorted()) }
                let delivered = await notifications.deliveredIDs(namespace)
                if !delivered.isEmpty { await notifications.removeDelivered(delivered.sorted()) }
            }
        )
    }()
    static let testValue = Self.noop
}

extension DependencyValues {
    var competitionWidgetSnapshotClient: CompetitionWidgetSnapshotClient {
        get { self[CompetitionWidgetSnapshotClient.self] }
        set { self[CompetitionWidgetSnapshotClient.self] = newValue }
    }
}

extension CompetitionWidgetSnapshot {
    init(dashboard: CompetitionDashboard) {
        let competitions = dashboard.competitions
        let records = competitionOpponentRecords(competitions)
        self.init(
            matches: competitions.compactMap { competition in
                Match(presentation: competition).map {
                    var match = $0
                    match.belt = Belt(for: competition, records: records, in: competitions)
                    match.rivalry = Rivalry(for: competition, records: records, in: competitions)
                    return match
                }
            } + dashboard.groupMatches.compactMap(Match.init(group:)),
            hasIncomingChallenge: competitions.contains {
                if case .pending(.incoming, _, _) = $0.lifecycle { true } else { false }
            }
        )
    }
}

extension CompetitionWidgetSnapshot.Belt {
    init?(
        for competition: CompetitionPresentation,
        records: [CompetitionOpponentRecord],
        in competitions: [CompetitionPresentation]
    ) {
        guard !competitionBeltWaitsOnAnEarlierMatch(competition, in: competitions),
              let record = records.first(where: { $0.opponentIdentity == competition.opponentIdentity }),
              let holder = record.belt.holder
        else { return nil }
        let card: Card? = switch record.belt.events[competition.id] {
        case .took(.you, nil, _): .earned
        case let .took(.you, reign?, defenses): .taken(weeks: reign, defenses: defenses)
        case let .took(.them, reign?, defenses): .lost(weeks: reign, defenses: defenses)
        case let .defended(.you, _, defenses): .defended(defenses)
        case .took(.them, nil, _), .defended(.them, _, _), .kept, .vacant, nil: nil
        }
        let defenses = record.belt.current?.defenses ?? 0
        self.init(holder: holder == .you ? .you : .them, defenses: defenses, card: card)
    }
}

extension CompetitionWidgetSnapshot.Rivalry {
    init?(
        for competition: CompetitionPresentation,
        records: [CompetitionOpponentRecord],
        in competitions: [CompetitionPresentation]
    ) {
        guard !competitionBeltWaitsOnAnEarlierMatch(competition, in: competitions),
              let record = records.first(where: { $0.opponentIdentity == competition.opponentIdentity }),
              record.wins + record.losses + record.ties > 0
        else { return nil }
        let weeks = competitionRivalryWeeks(competitions, opponentIdentity: competition.opponentIdentity)
        let outcomes = weeks.compactMap(\.terminalResult?.outcome)
        let recent = outcomes.suffix(5).compactMap {
            CompetitionWidgetSnapshot.Final.Outcome(rawValue: $0.rawValue)
        }
        let formLine = competitionFormLine(outcomes, opponentName: competition.opponentDisplayName)
        let reignWeeks = record.belt.current?.weeks
        var edgeRing: CompetitionWidgetSnapshot.TodayRings.RingKind?
        var edgeRecord: String?
        if let days = competitionRingDaysWon(weeks) {
            let kinds: [CompetitionWidgetSnapshot.TodayRings.RingKind] = [.move, .exercise, .stand]
            let best = days.enumerated()
                .filter { $0.element.you > $0.element.them }
                .max { lhs, rhs in
                    let leftMargin = lhs.element.you - lhs.element.them
                    let rightMargin = rhs.element.you - rhs.element.them
                    return leftMargin != rightMargin ? leftMargin < rightMargin : lhs.offset > rhs.offset
                }
            if let best {
                edgeRing = kinds[best.offset]
                edgeRecord = "\(best.element.you)–\(best.element.them) days"
            }
        }
        self.init(
            wins: record.wins,
            losses: record.losses,
            ties: record.ties,
            recent: recent,
            formLine: formLine,
            reignWeeks: reignWeeks,
            edgeRing: edgeRing,
            edgeRecord: edgeRecord
        )
    }
}

extension CompetitionWidgetSnapshot.TodayRings {
    init?(presentation p: CompetitionPresentation) {
        switch p.lifecycle {
        case .active, .endsToday: break
        default: return nil
        }
        guard let ordinal = p.currentDayOrdinal,
              let day = p.days.first(where: { $0.ordinal == ordinal }),
              let panel = competitionRingPanel(day)
        else { return nil }
        let snapshot = day.ownerAcceptedSnapshot ?? day.ownerLatestSnapshot
        let shares = snapshot.map {
            competitionRingShares($0, perRingCap: day.scoringPolicy.perRingCap)
        } ?? [0, 0, 0]
        let rows = panel.rows.map { row in
            let kind: RingKind = switch row.metric {
            case .move: .move
            case .exercise: .exercise
            case .stand: .stand
            case .sleep: .sleep
            }
            let progress: Double = switch row.metric {
            case .move: max(0, shares[0])
            case .exercise: max(0, shares[1])
            case .stand: max(0, shares[2])
            case .sleep: max(0, (row.points ?? 0) / 100)
            }
            return Row(
                kind: kind,
                title: row.title,
                detail: row.detail,
                progress: progress,
                points: row.points
            )
        }
        self.init(dayOrdinal: ordinal, rows: rows)
    }
}

extension CompetitionWidgetSnapshot.Match {
    init?(group m: GroupMatchPresentation) {
        switch m.lifecycle {
        case .active, .endsToday, .tallying: guard !m.hasLeft(m.viewer) else { return nil }
        default: return nil
        }
        guard let schedule = m.schedule,
              let dayStarts = try? schedule.calendar
                .sevenDayWindow(startingOn: schedule.startDay)
                .map({ try schedule.calendar.startOfDay($0) }),
              let endsAt = competitionScheduleBoundaries(schedule)?.end,
              let url = CompetitionRoute.competition(m.id).url
        else { return nil }
        let rows = m.standingRows
        let you = m.viewerSubject
        let isDoubles = m.format == .doubles
        let them: MatchStandingSubject? = switch m.lead {
        case let .chasing(_, _, behind): behind.first
        case let .tiedFirst(with): with.first
        case .ahead, nil: rows.first { $0.subject != you }?.subject
        }
        func total(_ subject: MatchStandingSubject?) -> Double {
            Double(rows.first { $0.subject == subject }?.centipoints ?? 0) / 100
        }
        func dayPoints(_ subject: MatchStandingSubject?) -> [Double?] {
            let members = subject.map(m.members(of:)) ?? []
            return (1...7).map { ordinal in
                let values = members.compactMap { m.dayCentipoints($0, ordinal: ordinal) }
                return values.isEmpty ? nil : Double(values.reduce(0, +)) / 100
            }
        }
        let lead: String? = switch m.lead {
        case let .chasing(_, gap, behind):
            isDoubles
                ? "Your team down \(GroupMatchPresentation.pointsText(gap))"
                : "\(GroupMatchPresentation.pointsText(gap)) behind \(behind.map(m.name(of:)).formatted(.list(type: .and)))"
        case let .ahead(margin):
            isDoubles
                ? "Your team up \(GroupMatchPresentation.pointsText(margin))"
                : "You lead by \(GroupMatchPresentation.pointsText(margin))"
        case .tiedFirst: isDoubles ? "All square" : "Tied for 1st"
        case nil: nil
        }
        self.init(
            id: m.id.rawValue,
            personID: "group:\(m.id.rawValue.uuidString.lowercased())",
            name: them.map(m.name(of:)) ?? m.format.title,
            url: url,
            timeZoneIdentifier: schedule.calendar.timeZoneIdentifier,
            dayStarts: dayStarts,
            endsAt: endsAt,
            userPoints: total(you),
            opponentPoints: total(them),
            userDayPoints: dayPoints(you),
            opponentDayPoints: dayPoints(them),
            updatedAt: nil,
            final: nil,
            group: CompetitionWidgetSnapshot.Group(
                title: m.format.title,
                isDoubles: isDoubles,
                rows: rows.map {
                    .init(place: $0.place, name: m.name(of: $0.subject), points: Double($0.centipoints) / 100,
                          isYou: $0.subject == you)
                },
                lead: lead
            )
        )
    }

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
                .compactMap { $0 }.min(),
            final: final,
            chase: competitionWhatItTakes(p).map {
                CompetitionWidgetSnapshot.Chase(
                    day: $0.dayOrdinal,
                    points: $0.points,
                    suggestion: $0.points == nil ? nil : $0.suggestion
                )
            },
            todayRings: CompetitionWidgetSnapshot.TodayRings(presentation: p)
        )
    }
}
