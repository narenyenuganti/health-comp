import CompetitionCore
import SwiftUI

enum CompetitionFormMetric: String, CaseIterable, Identifiable, Sendable {
    case all, move, exercise, stand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .move: "Move"
        case .exercise: "Exercise"
        case .stand: "Stand"
        }
    }

    var maximum: Double {
        self == .all ? ActivityScore.maximumDailyPoints : 200
    }

    var barColor: Color {
        switch self {
        case .all: Theme.youFill
        case .move: Theme.move
        case .exercise: Theme.exercise
        case .stand: Theme.stand
        }
    }

    var textColor: Color {
        switch self {
        case .all: Theme.you
        case .move: Theme.move
        case .exercise: Theme.exercise
        case .stand: Theme.stand
        }
    }
}

struct CompetitionFormDay: Equatable, Identifiable, Sendable {
    let day: CompetitionDay
    let points: Double

    var id: CompetitionDay { day }
}

struct CompetitionFormSummary: Equatable, Sendable {
    let metric: CompetitionFormMetric
    let recentAverage: Double
    let baselineAverage: Double
    let deltaPercent: Int
    let recentDays: [CompetitionFormDay]
    let baselineDayCount: Int

    var statusLabel: String {
        if abs(deltaPercent) <= 3 { return "ON PACE" }
        return deltaPercent > 0 ? "+\(deltaPercent)% ABOVE" : "\u{2212}\(abs(deltaPercent))% BELOW"
    }

    var isAbove: Bool { deltaPercent > 3 }
}

func competitionDailyBaselineAverage(
    _ competitions: [LocalCompetitionPresentation],
    metric: CompetitionFormMetric = .all
) -> Double? {
    let series = competitionScoredDaySeries(competitions, metric: metric)
    guard series.count >= 3 else { return nil }
    let window = series.suffix(28)
    return window.reduce(0.0) { $0 + $1.points } / Double(window.count)
}

func competitionFormSummary(
    _ competitions: [LocalCompetitionPresentation],
    metric: CompetitionFormMetric
) -> CompetitionFormSummary? {
    let series = competitionScoredDaySeries(competitions, metric: metric)
    guard series.count >= 3 else { return nil }
    let baselineSlice = Array(series.suffix(28))
    let recentSlice = Array(series.suffix(7))
    let baseline = baselineSlice.reduce(0.0) { $0 + $1.points } / Double(baselineSlice.count)
    let recent = recentSlice.reduce(0.0) { $0 + $1.points } / Double(recentSlice.count)
    let delta: Int = baseline > 0
        ? Int(((recent - baseline) / baseline * 100).rounded(.toNearestOrAwayFromZero))
        : 0
    return CompetitionFormSummary(
        metric: metric,
        recentAverage: recent,
        baselineAverage: baseline,
        deltaPercent: delta,
        recentDays: recentSlice,
        baselineDayCount: baselineSlice.count
    )
}

private func competitionScoredDaySeries(
    _ competitions: [LocalCompetitionPresentation],
    metric: CompetitionFormMetric
) -> [CompetitionFormDay] {
    var byDay: [CompetitionDay: Double] = [:]
    for competition in competitions where !competition.isPractice {
        if metric == .all, !competition.metrics.isDefaultRings { continue }
        for day in competition.days {
            guard day.ownerLatestAvailability != .notYetOccurred else { continue }
            let value: Double?
            switch metric {
            case .all:
                value = day.ownerAcceptedPoints
            case .move:
                value = day.ownerRingPoints.flatMap { $0.count == 3 ? $0[0] : nil }
            case .exercise:
                value = day.ownerRingPoints.flatMap { $0.count == 3 ? $0[1] : nil }
            case .stand:
                value = day.ownerRingPoints.flatMap { $0.count == 3 ? $0[2] : nil }
            }
            guard let value, value > 0 else { continue }
            byDay[day.day] = max(byDay[day.day] ?? 0, value)
        }
    }
    return byDay.keys
        .sorted { ($0.year, $0.month, $0.day) < ($1.year, $1.month, $1.day) }
        .map { CompetitionFormDay(day: $0, points: byDay[$0] ?? 0) }
}

struct CompetitionFormCard: View {
    let competitions: [LocalCompetitionPresentation]

    @State private var metric: CompetitionFormMetric = .all
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var avgSize: CGFloat = 38

    var body: some View {
        let available = CompetitionFormMetric.allCases.filter {
            competitionFormSummary(competitions, metric: $0) != nil
        }
        if let summary = competitionFormSummary(competitions, metric: metric)
            ?? available.first.flatMap({ competitionFormSummary(competitions, metric: $0) }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SectionLabel("YOUR FORM")
                    Spacer(minLength: 8)
                    Text("\(summary.recentDays.count)D VS \(summary.baselineDayCount)D")
                        .themeLabel()
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 12) {
                    if available.count > 1, !dynamicTypeSize.isAccessibilitySize {
                        CompetitionSegments(
                            selection: $metric,
                            options: available.map { (value: $0, title: $0.title) }
                        )
                        .accessibilityIdentifier("competition.form.metric")
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(competitionPointsText(summary.recentAverage, locale: locale))
                                .font(.score(size: min(avgSize, 52)).monospacedDigit())
                                .foregroundStyle(summary.metric.textColor)
                                .scoreRoll(summary.recentAverage, id: summary.metric)
                            Text("pts/day vs \(competitionPointsText(summary.baselineAverage, locale: locale))")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            statusBadge(summary)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(competitionPointsText(summary.recentAverage, locale: locale))
                                .font(.score(size: min(avgSize, 52)).monospacedDigit())
                                .foregroundStyle(summary.metric.textColor)
                                .scoreRoll(summary.recentAverage, id: summary.metric)
                            Text("pts/day vs \(competitionPointsText(summary.baselineAverage, locale: locale))")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            statusBadge(summary)
                        }
                    }

                    if !dynamicTypeSize.isAccessibilitySize {
                        formBars(summary)
                    }
                }
                .padding(16)
                .themePanel()
            }
            .moving(Motion.settle, value: metric)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("competition.form")
        }
    }

    private func statusBadge(_ summary: CompetitionFormSummary) -> some View {
        Text(summary.statusLabel)
            .font(.caption2.weight(.heavy).width(.condensed).monospacedDigit())
            .tracking(0.8)
            .foregroundStyle(summary.isAbove ? Theme.onYouFill : Theme.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                summary.isAbove ? Theme.youFill : Theme.control,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .accessibilityIdentifier("competition.form.status")
    }

    private func formBars(_ summary: CompetitionFormSummary) -> some View {
        let ceiling = max(
            summary.metric.maximum,
            summary.baselineAverage,
            summary.recentDays.map(\.points).max() ?? 1
        )
        let chartHeight: CGFloat = 76
        let baselineRatio = min(1, max(0, summary.baselineAverage / ceiling))
        return VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(summary.recentDays) { item in
                        let height = max(6, chartHeight * min(1, item.points / ceiling))
                        let above = item.points >= summary.baselineAverage
                        SlantedBar()
                            .fill(summary.metric.barColor.opacity(above ? 1 : 0.42))
                            .frame(maxWidth: .infinity)
                            .frame(height: height)
                    }
                }
                .frame(height: chartHeight, alignment: .bottom)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Rectangle()
                            .stroke(Theme.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(height: 1)
                        Text(competitionPointsText(summary.baselineAverage, locale: locale))
                            .font(.caption2.weight(.bold).width(.condensed).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 4)
                            .background(Theme.panel)
                    }
                    .padding(.bottom, max(0, chartHeight * baselineRatio - 8))
                }
                .frame(height: chartHeight)
                .allowsHitTesting(false)
            }

            HStack(spacing: 8) {
                ForEach(summary.recentDays) { item in
                    Text(weekdayText(item.day, locale: locale))
                        .font(.caption2.weight(.bold).width(.condensed))
                        .foregroundStyle(Theme.secondary)
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct CompetitionRivalryTrend: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let value: String
    let detail: String
    let isYours: Bool
    var ringColor: Color? = nil
}

func competitionRivalryTrends(
    _ weeks: [LocalCompetitionPresentation],
    locale: Locale = .current
) -> [CompetitionRivalryTrend] {
    guard weeks.count >= 3 else { return [] }
    var tiles: [CompetitionRivalryTrend] = []

    let allDays = weeks.flatMap(\.days).compactMap(\.ownerAcceptedPoints)
    let recentDays = weeks.suffix(4).flatMap(\.days).compactMap(\.ownerAcceptedPoints)
    if !allDays.isEmpty, !recentDays.isEmpty {
        let allAvg = allDays.reduce(0, +) / Double(allDays.count)
        let recentAvg = recentDays.reduce(0, +) / Double(recentDays.count)
        let diff = recentAvg - allAvg
        let arrow = diff > 5 ? "↑" : diff < -5 ? "↓" : "→"
        tiles.append(.init(
            id: "avg",
            label: "RECENT AVG",
            value: competitionPointsText(recentAvg, locale: locale),
            detail: "\(arrow) vs \(competitionPointsText(allAvg, locale: locale)) all-time",
            isYours: diff >= 0
        ))
    }

    let day7Margins = weeks.compactMap { week -> Double? in
        guard let day7 = week.days.first(where: { $0.ordinal == 7 }),
              let you = day7.ownerAcceptedPoints,
              let them = day7.opponentRevealedPoints
        else { return nil }
        return you - them
    }
    if !day7Margins.isEmpty {
        let avg = day7Margins.reduce(0, +) / Double(day7Margins.count)
        let sign = avg > 0 ? "+" : avg < 0 ? "\u{2212}" : ""
        tiles.append(.init(
            id: "day7",
            label: "DAY 7 MARGIN",
            value: "\(sign)\(competitionPointsText(abs(avg), locale: locale))",
            detail: "Avg final-day swing",
            isYours: avg >= 0
        ))
    }

    if let records = competitionRingRecords(weeks) {
        let specs: [(name: String, color: Color)] = [
            ("MOVE", Theme.move),
            ("EXER", Theme.exercise),
            ("STAND", Theme.stand),
        ]
        if let best = records.enumerated().max(by: {
            ($0.element.daysYou - $0.element.daysThem) < ($1.element.daysYou - $1.element.daysThem)
        }), best.element.daysYou + best.element.daysThem > 0 {
            let spec = specs[best.offset]
            tiles.append(.init(
                id: "ring",
                label: "STRONGEST RING",
                value: spec.name,
                detail: "\(best.element.daysYou)–\(best.element.daysThem) days",
                isYours: best.element.daysYou >= best.element.daysThem,
                ringColor: spec.color
            ))
        }
    }

    let recentWeeks = Array(weeks.suffix(4))
    let recentWins = recentWeeks.filter { $0.terminalResult?.outcome == .win }.count
    let allWins = weeks.filter { $0.terminalResult?.outcome == .win }.count
    let recentPct = Int((Double(recentWins) / Double(recentWeeks.count) * 100).rounded())
    let allPct = Int((Double(allWins) / Double(weeks.count) * 100).rounded())
    tiles.append(.init(
        id: "winrate",
        label: "LAST \(recentWeeks.count) WEEKS",
        value: "\(recentPct)%",
        detail: "All-time \(allPct)% win rate",
        isYours: recentPct >= allPct
    ))

    return tiles
}

struct CompetitionRivalryTrendTiles: View {
    let weeks: [LocalCompetitionPresentation]

    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 24

    var body: some View {
        let tiles = competitionRivalryTrends(weeks, locale: locale)
        if !tiles.isEmpty {
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 10),
                count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
            )
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("TRENDS")
                    .padding(.horizontal, 4)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(tiles) { tile in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tile.label)
                                .themeLabel(tracking: 0.9)
                                .foregroundStyle(Theme.secondary)
                            Text(tile.value)
                                .font(.score(size: min(valueSize, 32)).monospacedDigit())
                                .foregroundStyle(tile.ringColor ?? (tile.isYours ? Theme.you : Theme.ink))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(tile.detail)
                                .font(.caption)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .themePanel()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(tile.label): \(tile.value). \(tile.detail).")
                        .accessibilityIdentifier("competition.records.trend.\(tile.id)")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("competition.records.trends")
        }
    }
}
