import CompetitionCore
import SwiftUI

struct CompetitionRingRow: Equatable, Sendable {
    var metric: CompetitionMetric = .move
    let title: String
    let detail: String
    let spokenDetail: String
    let points: Double?
}

struct CompetitionRingPanel: Equatable, Sendable {
    let rows: [CompetitionRingRow]
    let isPaused: Bool
    let note: String?
    let accessibilityLabel: String
}

func competitionRingPanel(
    _ day: LocalCompetitionDayPresentation,
    locale: Locale = .current
) -> CompetitionRingPanel? {
    let metrics = day.metrics.isEmpty ? .threeRings : day.metrics
    let includesSleep = metrics.includesSleep || day.dailyMaximum > ActivityScore.maximumDailyPoints
    guard let snapshot = day.ownerAcceptedSnapshot ?? day.ownerLatestSnapshot else {
        guard !metrics.includesActivityRings, includesSleep else { return nil }
        let sleepRow = competitionSleepRow(day, locale: locale)
        let spoken = "Your sleep. \(sleepRow.title), \(sleepRow.spokenDetail)"
            + (sleepRow.points.map { ", \(competitionPointsAccessibilityText($0, locale: locale))" } ?? "")
            + "."
        return CompetitionRingPanel(
            rows: [sleepRow],
            isPaused: false,
            note: nil,
            accessibilityLabel: spoken
        )
    }
    let isAccepted = day.ownerAcceptedSnapshot != nil
    let total = isAccepted
        ? day.ownerAcceptedPoints.map { max(0, $0 - (day.ownerSleepPoints ?? 0)) }
        : ActivityScoreCalculator.score(snapshot, policy: day.scoringPolicy, metrics: metrics).availableScore?.points
    let rawShares = competitionRingShares(snapshot, perRingCap: day.scoringPolicy.perRingCap)
    let activeIndices = metrics.activeActivityIndices
    let activeShares = activeIndices.map { rawShares[$0] }
    let sum = activeShares.reduce(0, +)
    let activePoints = total.map { total in
        competitionRoundedParts(activeShares.map { sum > 0 ? total * $0 / sum : 0 }, total: total)
    }
    var pointsByIndex: [Int: Double] = [:]
    if let activePoints {
        for (offset, ringIndex) in activeIndices.enumerated() {
            pointsByIndex[ringIndex] = activePoints[offset]
        }
    }

    func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }
    func row(
        _ metric: CompetitionMetric,
        _ index: Int,
        _ title: String,
        _ reading: ActivityRingReading,
        _ unit: String,
        _ spokenUnit: String
    ) -> CompetitionRingRow {
        guard let value = reading.value, let goal = reading.goal, goal > 0 else {
            return CompetitionRingRow(
                metric: metric, title: title, detail: "No data", spokenDetail: "no data", points: pointsByIndex[index]
            )
        }
        return CompetitionRingRow(
            metric: metric,
            title: title,
            detail: "\(number(value))/\(number(goal)) \(unit)",
            spokenDetail: "\(number(value)) of \(number(goal)) \(spokenUnit)",
            points: pointsByIndex[index]
        )
    }

    let minutes = snapshot.moveMode == .moveMinutes
    let standTitle = switch snapshot.standMode {
    case .standHours: "Stand"
    case .rollHours: "Roll"
    case .unknown: "Stand or Roll"
    }
    var rows: [CompetitionRingRow] = []
    if metrics.contains(.move) {
        rows.append(row(
            .move, 0, minutes ? "Move Time" : "Move", snapshot.move,
            minutes ? "min" : "kcal", minutes ? "minutes" : "kilocalories"
        ))
    }
    if metrics.contains(.exercise) {
        rows.append(row(.exercise, 1, "Exercise", snapshot.exercise, "min", "minutes"))
    }
    if metrics.contains(.stand) {
        rows.append(row(.stand, 2, standTitle, snapshot.standOrRoll, "hr", "hours"))
    }
    if includesSleep {
        rows.append(competitionSleepRow(day, locale: locale))
    }
    let isPaused = metrics.includesActivityRings && snapshot.pauseState == .paused

    let note: String? = if metrics.includesActivityRings, isAccepted, day.ownerLatestSnapshot != snapshot {
        "Points use an earlier reading. Your rings have changed since."
    } else if metrics.includesActivityRings, !isAccepted, total != nil {
        "These points haven’t synced yet."
    } else {
        nil
    }

    let spokenRows = rows.map { row in
        "\(row.title), \(row.spokenDetail)"
            + (row.points.map { ", \(competitionPointsAccessibilityText($0, locale: locale))" } ?? "")
    }
    let spoken = (["Your rings"] + spokenRows
        + (isPaused ? ["Activity tracking paused"] : [])
        + [note].compactMap { $0.map { String($0.dropLast()) } })
        .joined(separator: ". ") + "."

    return CompetitionRingPanel(
        rows: rows,
        isPaused: isPaused,
        note: note,
        accessibilityLabel: spoken
    )
}

struct ActivityRingsView: View {
    let panel: CompetitionRingPanel
    var openNight: (() -> Void)? = nil

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(panel.rows.enumerated()), id: \.offset) { _, row in
                    if row.metric == .sleep, let openNight {
                        Button(action: openNight) { rowView(row, opens: true) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("competition.sleep.row")
                    } else {
                        rowView(row, opens: false)
                    }
                }
                if panel.isPaused {
                    Text("Activity tracking paused")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.ink)
                }
                if let note = panel.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .themePanel()
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("competition.ownerRings")
            .accessibilityLabel(panel.accessibilityLabel)
            .accessibilityAction(named: "Last night") { openNight?() }
        }
    }

    private func rowView(_ row: CompetitionRingRow, opens: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SlantedBar()
                .fill(row.metric.color)
                .frame(width: 10, height: 10)
            let title = Text(row.title).fontWeight(.semibold).foregroundStyle(Theme.ink)
            let detail = Text(" · \(row.detail)").foregroundStyle(Theme.secondary)
            Text("\(title)\(detail)")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let points = row.points {
                Text(competitionPointsText(points, locale: locale))
                    .font(.headline.weight(.heavy).width(.condensed).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
                    .scoreRoll(points, id: row.title)
            }
            if opens {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct CompetitionWhatItTakes: Equatable, Sendable {
    let dayOrdinal: Int
    let points: Double?
    let headline: String
    let suggestion: String
    let accessibilityLabel: String
}

func competitionWhatItTakes(
    _ competition: LocalCompetitionPresentation,
    locale: Locale = .current
) -> CompetitionWhatItTakes? {
    switch competition.lifecycle {
    case .active, .endsToday: break
    default: return nil
    }
    guard let ordinal = competition.currentDayOrdinal,
          let day = competition.days.first(where: { $0.ordinal == ordinal }),
          let snapshot = day.ownerAcceptedSnapshot,
          let today = day.ownerAcceptedPoints,
          day.ownerLatestSnapshot == nil || day.ownerLatestSnapshot == snapshot
    else { return nil }
    let margin = competitionDisplayedMargin(
        userPoints: competition.userPoints, opponentPoints: competition.opponentPoints
    )
    guard margin <= 0 else { return nil }
    let metrics = competition.metrics
    let hasMove = metrics.contains(.move)
    let hasExercise = metrics.contains(.exercise)
    guard hasMove || hasExercise else { return nil }
    let need = 1 - margin
    let left = max(0, metrics.activityDailyMaximum - (today - (day.ownerSleepPoints ?? 0)))
    let cap = day.scoringPolicy.perRingCap
    let shares = competitionRingShares(snapshot, perRingCap: cap)

    struct Ring {
        let title: String
        let unit: String
        let spokenUnit: String
        let goal: Double
        let step: Double
        let room: Double
    }
    func ring(_ index: Int, _ reading: ActivityRingReading, _ title: String, minutes: Bool) -> Ring {
        let goal = reading.goal ?? 0
        let usable = reading.value != nil && goal > 0
        let room = !usable ? 0 : cap.map { min(left, max(0, $0 - shares[index] * 100)) } ?? left
        return Ring(
            title: title,
            unit: minutes ? "min" : "kcal",
            spokenUnit: minutes ? "minutes" : "kilocalories",
            goal: goal,
            step: minutes ? 1 : 10,
            room: room
        )
    }
    let moveMinutes = snapshot.moveMode == .moveMinutes
    let move = hasMove ? ring(0, snapshot.move, moveMinutes ? "Move Time" : "Move", minutes: moveMinutes) : nil
    let exercise = hasExercise ? ring(1, snapshot.exercise, "Exercise", minutes: true) : nil
    let activeRings = [move, exercise].compactMap { $0 }
    let reach = min(left, activeRings.reduce(0) { $0 + $1.room }).rounded(.down)

    func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }
    let name = competition.opponentDisplayName
    let activeRingNames = activeRings.map(\.title).joined(separator: " and ")

    guard need <= reach else {
        let level = margin == 0
        let gap = competitionPointsText(-margin, locale: locale)
        let spokenGap = competitionPointsAccessibilityText(-margin, locale: locale)
        func sentence(_ gap: String) -> String {
            let lead = level ? "All square, and" : "\(name) is \(gap) ahead and"
            if reach >= 1 {
                return "\(lead) you have \(competitionPointsAccessibilityText(reach, locale: locale)) left in \(activeRingNames) today."
            }
            return left.rounded(.down) == 0
                ? "\(lead) you’ve reached today’s cap."
                : "\(lead) \(activeRingNames) \(activeRings.count == 1 ? "is" : "are") at the 200% cap."
        }
        let text = sentence(gap)
        return CompetitionWhatItTakes(
            dayOrdinal: ordinal,
            points: nil,
            headline: "Out of reach today",
            suggestion: text,
            accessibilityLabel: "Out of reach today. \(sentence(spokenGap))"
        )
    }

    func amount(_ ring: Ring, _ points: Double) -> Double {
        max(ring.step, ((points / 100 * ring.goal) / ring.step - 1e-9).rounded(.up) * ring.step)
    }
    func part(_ ring: Ring, _ points: Double) -> (text: String, spoken: String) {
        let value = amount(ring, points)
        let spokenUnit = value == 1 ? String(ring.spokenUnit.dropLast()) : ring.spokenUnit
        return (
            "\(number(value)) \(ring.unit) of \(ring.title)",
            "\(number(value)) \(spokenUnit) of \(ring.title)"
        )
    }
    let rings = activeRings.sorted { $0.room > $1.room }.filter { $0.room > 0 }
    let singles = rings.filter { $0.room >= need }
    let parts = singles.isEmpty && rings.count >= 2
        ? [part(rings[0], rings[0].room), part(rings[1], need - rings[0].room)]
        : singles.map { part($0, need) }
    let joiner = singles.isEmpty ? " and " : " or "
    let suggestion = "About \(parts.map(\.text).joined(separator: joiner))."
    let spokenSuggestion = "About \(parts.map(\.spoken).joined(separator: joiner))."
    return CompetitionWhatItTakes(
        dayOrdinal: ordinal,
        points: need,
        headline: "\(competitionPointsText(need, locale: locale)) to take the lead",
        suggestion: suggestion,
        accessibilityLabel: "\(competitionPointsAccessibilityText(need, locale: locale)) to take the lead. \(spokenSuggestion)"
    )
}

struct CompetitionWhatItTakesPanel: View {
    let takes: CompetitionWhatItTakes

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .leading) {
                Text(takes.headline)
                    .font(.title3.weight(.heavy).width(.condensed))
                    .foregroundStyle(takes.points == nil ? Theme.ink : Theme.you)
                    .fixedSize(horizontal: false, vertical: true)
                    .scoreRoll(takes.points, id: headlineID)
            }
            .animation(Motion.fade, value: headlineID)
            Text(takes.suggestion)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .themePanel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(takes.accessibilityLabel)
        .accessibilityIdentifier("competition.takes")
    }

    private var headlineID: String {
        "\(takes.dayOrdinal)-\(takes.points == nil)"
    }
}

struct CompetitionTodayRings: Equatable, Sendable {
    let panel: CompetitionRingPanel
    let points: Double?
    let updated: String?
}

func competitionTodayRings(
    _ competitions: [LocalCompetitionPresentation],
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> CompetitionTodayRings? {
    for competition in competitions {
        switch competition.lifecycle {
        case .active, .endsToday: break
        default: continue
        }
        guard let ordinal = competition.currentDayOrdinal,
              let day = competition.days.first(where: { $0.ordinal == ordinal }),
              let panel = competitionRingPanel(day, locale: locale)
        else { continue }
        let points = panel.rows.compactMap(\.points)
        return CompetitionTodayRings(
            panel: panel,
            points: points.count == panel.rows.count ? points.reduce(0, +) : nil,
            updated: competition.lastSuccessfulFullWindowRefreshAt.map {
                "Updated \(competitionUpdatedText($0, now: competition.evaluatedAt, locale: locale, timeZone: timeZone))"
            }
        )
    }
    return nil
}

struct CompetitionTodayRingsSheet: View {
    let competitions: [LocalCompetitionPresentation]

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var height: CGFloat = 240
    @State private var isShown = false

    private let colors = [Theme.move, Theme.exercise, Theme.stand]

    var body: some View {
        let today = competitionTodayRings(competitions, locale: locale, timeZone: timeZone)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionLabel("YOUR RINGS TODAY")
                        Spacer(minLength: 8)
                        updated(today)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("YOUR RINGS TODAY")
                        updated(today)
                    }
                }
                if let today {
                    rings(today)
                } else {
                    Text("No match is scoring today. Your rings show here from Day 1.")
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.todayRings.empty")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 20)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.ground)
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ground)
        .onAppear { isShown = true }
    }

    @ViewBuilder
    private func updated(_ today: CompetitionTodayRings?) -> some View {
        if let updated = today?.updated {
            Text(updated)
                .themeLabel()
                .textCase(.uppercase)
                .foregroundStyle(Theme.secondary)
        }
    }

    private func rings(_ today: CompetitionTodayRings) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                ForEach(Array(today.panel.rows.enumerated()), id: \.offset) { index, row in
                    let closes = isShown ? (row.points ?? 0) / 100 : 0
                    GridRow {
                        Text(row.title)
                            .themeLabel()
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.ink)
                        TodayRingBar(closes: closes, color: colors[index])
                            .frame(height: 14)
                            .moving(Motion.grow(index, of: 3), value: closes)
                        Text(competitionPointsText(row.points, locale: locale))
                            .font(.headline.weight(.heavy).width(.condensed).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            Group {
                if let points = today.points {
                    let pointsText = Text(competitionPointsText(points, locale: locale))
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.ink)
                    Text("\(pointsText) of \(Self.dailyMaximum) points today")
                } else {
                    Text("No points yet today")
                }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
            if today.panel.isPaused {
                Text("Activity tracking paused")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.ink)
            }
            if let note = today.panel.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            today.panel.accessibilityLabel + " " + (today.points.map {
                "\(competitionPointsAccessibilityText($0, locale: locale)) of \(Self.dailyMaximum) today."
            } ?? "No points yet today.")
        )
        .accessibilityIdentifier("home.todayRings")
    }

    private static let dailyMaximum = Int(ActivityScore.maximumDailyPoints)
}

private struct TodayRingBar: View {
    let closes: Double
    let color: Color

    var body: some View {
        TodayRingSegments(closes: 2)
            .fill(Theme.track)
            .overlay { TodayRingSegments(closes: closes).fill(color) }
    }
}

private struct TodayRingSegments: Shape {
    var closes: Double

    var animatableData: Double {
        get { closes }
        set { closes = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let fill = min(1, max(0, closes / 2))
        guard fill > 0 else { return Path() }
        return SlantedBar().path(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width * fill, height: rect.height))
    }
}
