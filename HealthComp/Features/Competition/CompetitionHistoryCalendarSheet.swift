import CompetitionCore
import SwiftUI

struct CompetitionCalendarDayKey: Hashable, Comparable, Identifiable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    var id: String { "\(year)-\(month)-\(day)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    init(_ day: CompetitionDay) {
        self.year = day.year
        self.month = day.month
        self.day = day.day
    }

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
}

struct CompetitionCalendarDayEntry: Equatable, Identifiable {
    let key: CompetitionCalendarDayKey
    let day: CompetitionDay
    let dayOrdinal: Int
    let competitionID: CompetitionID
    let opponentName: String
    let outcome: CompetitionOutcome?
    let userPoints: Double?
    let opponentPoints: Double?
    let rings: [CompetitionRing]

    var id: CompetitionCalendarDayKey { key }
}

struct CompetitionCalendarMonth: Equatable, Identifiable {
    let year: Int
    let month: Int
    let leadingBlanks: Int
    let days: [CompetitionCalendarDayKey]

    var id: String { "\(year)-\(month)" }
}

func competitionCalendarDayRings(
    _ day: LocalCompetitionDayPresentation,
    metrics: CompetitionMetrics
) -> [CompetitionRing] {
    let resolved = metrics.isEmpty ? (day.metrics.isEmpty ? .threeRings : day.metrics) : metrics
    let activityProgress: [Double]
    if let points = day.ownerRingPoints, points.count == 3 {
        activityProgress = points.map { $0 / 100 }
    } else if let snapshot = day.ownerAcceptedSnapshot ?? day.ownerLatestSnapshot,
              let score = ActivityScoreCalculator.score(
                snapshot,
                policy: day.scoringPolicy,
                metrics: .threeRings
              ).availableScore {
        activityProgress = [
            score.movePercentage / 100,
            score.exercisePercentage / 100,
            score.standOrRollPercentage / 100,
        ]
    } else if let accepted = day.ownerAcceptedPoints {
        let count = resolved.activeActivityIndices.count
        let perRing = count > 0 ? max(0, accepted - (day.ownerSleepPoints ?? 0)) / Double(count) : 0
        activityProgress = [perRing / 100, perRing / 100, perRing / 100]
    } else {
        activityProgress = [0, 0, 0]
    }
    let sleepProgress = (day.ownerSleepPoints ?? day.ownerSleepReading?.points ?? 0) / 100
    return resolved.orderedMetrics.map { metric in
        switch metric {
        case .move: CompetitionRing(color: Theme.move, progress: activityProgress[0])
        case .exercise: CompetitionRing(color: Theme.exercise, progress: activityProgress[1])
        case .stand: CompetitionRing(color: Theme.stand, progress: activityProgress[2])
        case .sleep: CompetitionRing(color: Theme.sleep, progress: sleepProgress)
        }
    }
}

func competitionCalendarEntries(
    _ competitions: [LocalCompetitionPresentation]
) -> [CompetitionCalendarDayKey: CompetitionCalendarDayEntry] {
    var map: [CompetitionCalendarDayKey: CompetitionCalendarDayEntry] = [:]
    let ordered = competitions.filter { !$0.isPractice }.sorted { lhs, rhs in
        let l = lhs.acceptedConfiguration?.schedule.startDay
        let r = rhs.acceptedConfiguration?.schedule.startDay
        return (l?.year ?? 0, l?.month ?? 0, l?.day ?? 0) < (r?.year ?? 0, r?.month ?? 0, r?.day ?? 0)
    }
    for competition in ordered {
        for day in competition.days where day.ownerLatestAvailability != .notYetOccurred {
            let outcome: CompetitionOutcome?
            switch competitionDayOutcome(day, currentDayOrdinal: competition.currentDayOrdinal) {
            case .won: outcome = .win
            case .lost: outcome = .loss
            case .tied: outcome = .tie
            case .today, .upcoming, .noData:
                if let u = day.ownerAcceptedPoints, let t = day.opponentRevealedPoints, u > 0 || t > 0 {
                    outcome = u > t ? .win : u < t ? .loss : .tie
                } else {
                    outcome = nil
                }
            }
            let key = CompetitionCalendarDayKey(day.day)
            map[key] = CompetitionCalendarDayEntry(
                key: key,
                day: day.day,
                dayOrdinal: day.ordinal,
                competitionID: competition.id,
                opponentName: competition.opponentDisplayName,
                outcome: outcome,
                userPoints: day.ownerAcceptedPoints,
                opponentPoints: day.opponentRevealedPoints,
                rings: competitionCalendarDayRings(day, metrics: competition.metrics)
            )
        }
    }
    return map
}

func competitionCalendarMonths(
    from entries: [CompetitionCalendarDayKey: CompetitionCalendarDayEntry]
) -> [CompetitionCalendarMonth] {
    var gmt = Calendar(identifier: .gregorian)
    gmt.timeZone = .gmt
    let keys = Set(entries.keys.map { "\($0.year)-\($0.month)" })
    let pairs: [(Int, Int)] = keys.compactMap { raw in
        let parts = raw.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return (y, m)
    }.sorted { lhs, rhs in
        lhs.0 != rhs.0 ? lhs.0 > rhs.0 : lhs.1 > rhs.1
    }
    return pairs.compactMap { year, month in
        guard let first = gmt.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = gmt.range(of: .day, in: .month, for: first)
        else { return nil }
        let weekday = gmt.component(.weekday, from: first)
        let mondayOffset = (weekday + 5) % 7
        let days = range.map { CompetitionCalendarDayKey(year: year, month: month, day: $0) }
        return CompetitionCalendarMonth(
            year: year,
            month: month,
            leadingBlanks: mondayOffset,
            days: days
        )
    }
}

struct CompetitionHistoryCalendarSheet: View {
    let competitions: [LocalCompetitionPresentation]
    let now: Date
    let openMatch: (CompetitionID, Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private let weekdayHeaders = ["M", "T", "W", "T", "F", "S", "S"]
    private let ringSize: CGFloat = 26
    private let dotSize: CGFloat = 5

    var body: some View {
        let entries = competitionCalendarEntries(competitions)
        let months = competitionCalendarMonths(from: entries)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if months.isEmpty {
                    Text("Played match days appear on your calendar.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(months.enumerated()), id: \.element.id) { index, month in
                        monthSection(month, entries: entries, showsHint: index == 0)
                    }
                    legend
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(Theme.ground)
        .accessibilityIdentifier("competition.calendar.sheet")
    }

    private func monthSection(
        _ month: CompetitionCalendarMonth,
        entries: [CompetitionCalendarDayKey: CompetitionCalendarDayEntry],
        showsHint: Bool
    ) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(monthTitle(month))
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if showsHint {
                    Text("Tap a day")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                }
            }

            HStack(spacing: 0) {
                ForEach(weekdayHeaders.indices, id: \.self) { index in
                    Text(weekdayHeaders[index])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<month.leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(height: 52)
                }
                ForEach(month.days, id: \.self) { day in
                    dayCell(day, entry: entries[day])
                }
            }
        }
    }

    private func dayCell(
        _ day: CompetitionCalendarDayKey,
        entry: CompetitionCalendarDayEntry?
    ) -> some View {
        Button {
            guard let entry else { return }
            dismiss()
            openMatch(entry.competitionID, entry.dayOrdinal)
        } label: {
            VStack(spacing: 3) {
                Text(String(day.day))
                    .font(.caption.weight(entry != nil ? .semibold : .medium).monospacedDigit())
                    .foregroundStyle(entry != nil ? Theme.ink : Theme.faint)
                if let entry {
                    CompetitionRingStack(rings: entry.rings)
                        .frame(width: ringSize, height: ringSize)
                    Circle()
                        .fill(dotColor(for: entry.outcome))
                        .frame(width: dotSize, height: dotSize)
                } else {
                    Color.clear
                        .frame(width: ringSize, height: ringSize + dotSize + 3)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry == nil)
        .accessibilityLabel(dayAccessibilityLabel(day, entry: entry))
        .accessibilityIdentifier("competition.calendar.day.\(day.year)-\(day.month)-\(day.day)")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: Theme.youFill, text: "You won")
            legendItem(color: Theme.ink, text: "They won")
            legendItem(color: Theme.tertiary, text: "Tied")
        }
        .font(.caption)
        .foregroundStyle(Theme.secondary)
        .accessibilityElement(children: .combine)
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
        }
    }

    private func dotColor(for outcome: CompetitionOutcome?) -> Color {
        switch outcome {
        case .win: Theme.youFill
        case .loss: Theme.ink
        case .tie: Theme.tertiary
        case nil: .clear
        }
    }

    private func monthTitle(_ month: CompetitionCalendarMonth) -> String {
        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = .gmt
        guard let date = gmt.date(from: DateComponents(year: month.year, month: month.month, day: 1)) else {
            return "\(month.year)-\(month.month)"
        }
        return date.formatted(Date.FormatStyle(locale: locale, calendar: gmt, timeZone: .gmt).month(.wide).year())
    }

    private func dayAccessibilityLabel(_ day: CompetitionCalendarDayKey, entry: CompetitionCalendarDayEntry?) -> String {
        guard let entry else { return "\(day.month)/\(day.day), no match" }
        let base = competitionDayText(entry.day, now: now, locale: locale)
        let result: String = switch entry.outcome {
        case .win: "you won"
        case .loss: "\(entry.opponentName) won"
        case .tie: "tied"
        case nil: "in play"
        }
        return "\(base), versus \(entry.opponentName), \(result)"
    }
}
