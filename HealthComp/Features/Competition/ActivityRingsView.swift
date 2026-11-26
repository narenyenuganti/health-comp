import CompetitionCore
import SwiftUI

struct CompetitionRingRow: Equatable, Sendable {
    var metric: CompetitionMetric = .move
    let title: String
    let detail: String
    let spokenDetail: String
    let points: Double?
    var goalFraction: Double? = nil
    var valueText: String? = nil
    var unitText: String? = nil
    var sleepReading: CompetitionSleepReading? = nil
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

    var rows = activityRingRows(snapshot, metrics: metrics, points: pointsByIndex, locale: locale)
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

private func activityRingRows(
    _ snapshot: ActivitySnapshot,
    metrics: CompetitionMetrics,
    points: [Int: Double] = [:],
    locale: Locale
) -> [CompetitionRingRow] {
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
        guard let value = reading.value else {
            return CompetitionRingRow(
                metric: metric, title: title, detail: "No data", spokenDetail: "no data", points: points[index]
            )
        }
        guard let goal = reading.goal, goal > 0 else {
            return CompetitionRingRow(
                metric: metric, title: title, detail: "\(number(value)) \(unit)",
                spokenDetail: "\(number(value)) \(spokenUnit)", points: points[index],
                valueText: number(value), unitText: unit.uppercased()
            )
        }
        return CompetitionRingRow(
            metric: metric,
            title: title,
            detail: "\(number(value))/\(number(goal)) \(unit)",
            spokenDetail: "\(number(value)) of \(number(goal)) \(spokenUnit)",
            points: points[index],
            goalFraction: value / goal,
            valueText: "\(number(value))/\(number(goal))",
            unitText: unit.uppercased()
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
    return rows
}

struct CompetitionDayRingStacks: Equatable {
    let owner: [CompetitionRing]
    let opponent: [CompetitionRing]
}

func competitionDayRings(
    _ day: LocalCompetitionDayPresentation,
    metrics: CompetitionMetrics? = nil
) -> CompetitionDayRingStacks {
    let base = metrics ?? day.metrics
    var effective = base.isEmpty ? .threeRings : base
    if !effective.includesSleep && day.dailyMaximum > ActivityScore.maximumDailyPoints {
        effective.insert(.sleep)
    }
    let ordered = effective.orderedMetrics
    guard day.ownerLatestAvailability != .notYetOccurred else {
        let empty = ordered.map { CompetitionRing(color: $0.color, progress: 0) }
        return CompetitionDayRingStacks(owner: empty, opponent: empty)
    }

    let snapshot = day.ownerAcceptedSnapshot ?? day.ownerLatestSnapshot
    let activeActivityCount = Double(max(effective.activeActivityIndices.count, 1))

    func ownerProgress(_ metric: CompetitionMetric) -> Double {
        switch metric {
        case .sleep:
            let points = day.ownerSleepPoints ?? day.ownerSleepReading?.points ?? 0
            return max(0, points / 100)
        case .move, .exercise, .stand:
            let index = metric == .move ? 0 : metric == .exercise ? 1 : 2
            if let snapshot {
                let reading = index == 0 ? snapshot.move : index == 1 ? snapshot.exercise : snapshot.standOrRoll
                if let value = reading.value, let goal = reading.goal,
                   value.isFinite, goal.isFinite, goal > 0 {
                    return max(0, value / goal)
                }
                return 0
            }
            if let ringPoints = day.ownerRingPoints, ringPoints.count == 3 {
                return max(0, ringPoints[index] / 100)
            }
            if let accepted = day.ownerAcceptedPoints {
                let activity = max(0, accepted - (day.ownerSleepPoints ?? 0))
                return max(0, (activity / activeActivityCount) / 100)
            }
            return 0
        }
    }

    func opponentProgress(_ metric: CompetitionMetric) -> Double {
        switch metric {
        case .sleep:
            let points = day.opponentSleepPoints ?? 0
            return max(0, points / 100)
        case .move, .exercise, .stand:
            let index = metric == .move ? 0 : metric == .exercise ? 1 : 2
            if let ringPoints = day.opponentRingPoints, ringPoints.count == 3 {
                return max(0, ringPoints[index] / 100)
            }
            if let revealed = day.opponentRevealedPoints {
                let activity = max(0, revealed - (day.opponentSleepPoints ?? 0))
                return max(0, (activity / activeActivityCount) / 100)
            }
            return 0
        }
    }

    return CompetitionDayRingStacks(
        owner: ordered.map { CompetitionRing(color: $0.color, progress: ownerProgress($0)) },
        opponent: ordered.map { CompetitionRing(color: $0.color, progress: opponentProgress($0)) }
    )
}

func competitionDayWinnerDotColor(_ outcome: CompetitionDayOutcome) -> Color? {
    switch outcome {
    case .won: Theme.youFill
    case .lost: Theme.ink
    case .tied: Theme.tertiary
    case .today, .upcoming, .noData: nil
    }
}

func competitionDayHeadline(
    _ day: LocalCompetitionDayPresentation,
    currentDayOrdinal: Int?,
    now: Date,
    opponentName: String,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> (title: String, subtitle: String) {
    if day.ordinal == currentDayOrdinal {
        return ("Today", "In progress")
    }
    let title = competitionDayText(day.day, now: now, locale: locale, timeZone: timeZone)
    let subtitle: String = switch competitionDayOutcome(day, currentDayOrdinal: currentDayOrdinal) {
    case .won: "You won the day"
    case .lost: "\(opponentName) won the day"
    case .tied: "Tied"
    case .today, .upcoming, .noData: "Day \(day.ordinal)"
    }
    return (title, subtitle)
}

func competitionSleepMetadataText(
    _ reading: CompetitionSleepReading,
    points: Double?,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String? {
    var parts: [String] = []
    if let bedtime = reading.bedtime {
        parts.append("Bed \(competitionFormattedDate(bedtime, template: "jmm", locale: locale, timeZone: timeZone))")
    }
    if let wakeTime = reading.wakeTime {
        parts.append("up \(competitionFormattedDate(wakeTime, template: "jmm", locale: locale, timeZone: timeZone))")
    }
    if let points {
        parts.append("score \(competitionPointsText(points, locale: locale))")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

struct CompetitionDayRingPairPanel: View {
    let day: LocalCompetitionDayPresentation
    let metrics: CompetitionMetrics
    let opponentName: String

    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var scoreSize: CGFloat = 28

    var body: some View {
        let stacks = competitionDayRings(day, metrics: metrics)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            side(
                rings: stacks.owner,
                points: day.ownerAcceptedPoints,
                color: Theme.you,
                name: "You",
                rollID: "you",
                spoken: "You, \(competitionOwnerAccessibilityText(day, locale: locale))",
                identifier: "competition.dayPair.you"
            )
            side(
                rings: stacks.opponent,
                points: day.opponentRevealedPoints,
                color: Theme.ink,
                name: opponentName,
                rollID: "opponent",
                spoken: "\(opponentName), \(opponentSpoken)",
                identifier: "competition.dayPair.opponent"
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .themePanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.dayPair")
    }

    private var opponentSpoken: String {
        day.opponentRevealedPoints.map {
            competitionPointsAccessibilityText($0, locale: locale)
        } ?? (day.opponentReportedNoData ? "no data" : "not synced")
    }

    private func side(
        rings: [CompetitionRing],
        points: Double?,
        color: Color,
        name: String,
        rollID: String,
        spoken: String,
        identifier: String
    ) -> some View {
        VStack(spacing: 6) {
            ZStack {
                CompetitionRingStack(rings: rings)
                    .frame(width: 104, height: 104)
                    .moving(Motion.grow, value: rings)
                    .id(reduceMotion ? day.ordinal : 0)
                    .transition(Motion.appear)
            }
            .animation(reduceMotion ? Motion.fade : nil, value: day.ordinal)
            Text(competitionPointsText(points, locale: locale))
                .font(.score(size: scoreSize).monospacedDigit())
                .foregroundStyle(color)
                .fixedSize()
                .scoreRoll(points, id: rollID)
            Text(name)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier(identifier)
    }
}

struct ActivityRingsView: View {
    let panel: CompetitionRingPanel
    var opponentName: String? = nil
    var hourlyPace: [Double] = []
    var isToday: Bool = false
    var openNight: (() -> Void)? = nil

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var showsHourlyPace: Bool {
        !panel.isPaused
            && !hourlyPace.isEmpty
            && !dynamicTypeSize.isAccessibilitySize
            && panel.rows.contains(where: { $0.metric.isActivityRing })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if panel.isPaused {
                CompetitionPausedRingsBanner(opponentName: opponentName)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(panel.rows.enumerated()), id: \.offset) { offset, row in
                    if offset > 0 {
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 1)
                            .padding(.vertical, 10)
                    }
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
                        .padding(.top, 10)
                }
                if let note = panel.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .themePanel()
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("competition.ownerRings")
            .accessibilityLabel(panel.accessibilityLabel)
            .accessibilityAction(named: "Last night") { openNight?() }

            if showsHourlyPace {
                Text("Each chart shows your hourly pace for that ring. It stays on this iPhone.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .accessibilityIdentifier("competition.hourlyPace")
            }
        }
    }

    private func rowView(_ row: CompetitionRingRow, opens: Bool) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                titleLine(row)
                valueLine(row)
                if row.metric == .sleep {
                    sleepSubtitle(row)
                } else if showsHourlyPace {
                    RingHourlyPaceBars(values: hourlyPace, color: row.metric.color)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if let points = row.points {
                    let score = Text(competitionPointsText(points, locale: locale))
                        .font(.title3.weight(.heavy).width(.condensed).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    let unit = Text(" pts")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                    Text("\(score)\(unit)")
                        .fixedSize()
                        .scoreRoll(points, id: row.metric)
                }
                if opens {
                    DisclosureChevron()
                }
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func titleLine(_ row: CompetitionRingRow) -> some View {
        if row.metric == .sleep, row.sleepReading != nil {
            let name = Text(row.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            let suffix = Text(isToday ? " · last night" : " · night before")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            Text("\(name)\(suffix)")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(row.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func valueLine(_ row: CompetitionRingRow) -> some View {
        if row.metric == .sleep, let reading = row.sleepReading, reading.minutesAsleep > 0 {
            let total = Int(reading.minutesAsleep.rounded())
            let hours = Text("\(total / 60)")
                .font(.title3.weight(.heavy).width(.condensed).monospacedDigit())
            let hourUnit = Text("H")
                .font(.caption2.weight(.bold).width(.condensed))
            let minutes = Text(" \((total % 60).formatted(.number.precision(.integerLength(2))))")
                .font(.title3.weight(.heavy).width(.condensed).monospacedDigit())
            let minuteUnit = Text("M")
                .font(.caption2.weight(.bold).width(.condensed))
            Text("\(hours)\(hourUnit)\(minutes)\(minuteUnit)")
                .foregroundStyle(Theme.sleep)
                .fixedSize(horizontal: false, vertical: true)
        } else if let valueText = row.valueText {
            let value = Text(valueText)
                .font(.title3.weight(.heavy).width(.condensed).monospacedDigit())
            let unit = row.unitText.map {
                Text(" \($0)").font(.caption2.weight(.bold).width(.condensed))
            } ?? Text("")
            Text("\(value)\(unit)")
                .foregroundStyle(row.metric.color)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(row.detail)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func sleepSubtitle(_ row: CompetitionRingRow) -> some View {
        if let reading = row.sleepReading,
           reading.minutesAsleep > 0,
           let subtitle = competitionSleepMetadataText(
               reading,
               points: row.points,
               locale: locale,
               timeZone: timeZone
           ) {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }
}

private struct RingHourlyPaceBars: View {
    let values: [Double]
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(values.indices, id: \.self) { hour in
                let value = min(max(values[hour], 0), 1)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .opacity(value > 0.05 ? 1 : 0.18)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, 30 * value))
            }
        }
        .frame(height: 30, alignment: .bottom)
        .moving(Motion.grow, value: values)
        .accessibilityHidden(true)
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
    let activity: MainTabFeature.TodayActivity?
    let loadActivity: () async -> Void

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var height: CGFloat = 240
    @State private var isShown = false

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
                    personalActivity
                        .task { await loadActivity() }
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
    private var personalActivity: some View {
        switch activity {
        case .reading(let snapshot):
            let rows = activityRingRows(snapshot, metrics: .threeRings, locale: locale)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(rows, id: \.metric) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.title)
                                .themeLabel()
                                .textCase(.uppercase)
                            Spacer(minLength: 8)
                            Text(row.detail)
                                .font(.headline.weight(.semibold).monospacedDigit())
                        }
                        if let fraction = row.goalFraction {
                            TodayRingBar(fraction: fraction, color: row.metric.color)
                                .frame(height: 8)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.title), \(row.spokenDetail)")
                }
                if snapshot.isPaused == true {
                    Text("Activity tracking paused")
                        .font(.caption.bold())
                }
            }
            .foregroundStyle(Theme.ink)
        case .empty:
            Text("No activity rings are available from Apple Health today.")
                .foregroundStyle(Theme.secondary)
        case .unavailable:
            Text("Couldn’t read today’s rings from Apple Health. Try again in a moment.")
                .foregroundStyle(Theme.secondary)
        case nil:
            ProgressView("Reading today’s rings…")
        }
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
                        TodayRingBar(fraction: closes / 2, color: row.metric.color)
                            .frame(height: 14)
                            .moving(Motion.grow(index, of: today.panel.rows.count), value: closes)
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

struct CompetitionHourlyPaceView: View {
    let day: CompetitionDay
    let points: Double?

    @State private var buckets: [Double] = []
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var displayedBuckets: [Double] {
        if !buckets.isEmpty { return buckets }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--multi-user-competition-test-lab"),
           let points, points > 0 {
            return Self.testLabCurve(for: day)
        }
#endif
        return []
    }

    var body: some View {
        let values = displayedBuckets
        Group {
            if !values.isEmpty, !dynamicTypeSize.isAccessibilitySize {
                let peakHour = values.enumerated().max(by: { $0.element < $1.element })?.offset ?? 18
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionLabel("24H PACE")
                        Spacer(minLength: 8)
                        Text("PEAK \(Self.hourLabel(peakHour))")
                            .themeLabel()
                            .foregroundStyle(Theme.secondary)
                    }
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(values.indices, id: \.self) { hour in
                            let value = values[hour]
                            SlantedBar()
                                .fill(barColor(value: value))
                                .frame(maxWidth: .infinity)
                                .frame(height: max(3, 44 * value))
                        }
                    }
                    .frame(height: 44, alignment: .bottom)
                    HStack {
                        Text("12A")
                        Spacer()
                        Text("6A")
                        Spacer()
                        Text("12P")
                        Spacer()
                        Text("6P")
                        Spacer()
                        Text("11P")
                    }
                    .font(.caption2.weight(.bold).width(.condensed))
                    .foregroundStyle(Theme.tertiary)
                    Text("On-device hourly rhythm. Stays on this iPhone.")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }
                .padding(16)
                .themePanel()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("24 hour pace, peak around \(Self.hourLabel(peakHour)). Stays on this iPhone.")
                .accessibilityIdentifier("competition.hourlyPace")
            }
        }
        .task(id: day) {
            buckets = await HealthKitProvider.readLocalHourlyPace(for: day, timeZone: timeZone)
        }
    }

    private func barColor(value: Double) -> Color {
        if value >= 0.72 { return Theme.exercise }
        if value >= 0.25 { return Theme.move }
        if value > 0.05 { return Theme.stand }
        return Theme.track
    }

    static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: "12 AM"
        case 1..<12: "\(hour) AM"
        case 12: "12 PM"
        default: "\(hour - 12) PM"
        }
    }

    static func testLabCurve(for day: CompetitionDay) -> [Double] {
        let base: [Double] = [
            0.05, 0.02, 0.02, 0.02, 0.02, 0.03,
            0.10, 0.28, 0.34, 0.16, 0.14, 0.22,
            0.52, 0.32, 0.14, 0.16, 0.24, 0.62,
            0.98, 0.84, 0.36, 0.18, 0.08, 0.03,
        ]
        let shift = abs(day.day) % 3
        return base.indices.map { index in
            base[(index + shift) % base.count]
        }
    }
}

private struct TodayRingBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        TodayRingSegments(fraction: 1)
            .fill(Theme.track)
            .overlay { TodayRingSegments(fraction: fraction).fill(color) }
    }
}

private struct TodayRingSegments: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let fill = min(1, max(0, fraction))
        guard fill > 0 else { return Path() }
        return SlantedBar().path(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width * fill, height: rect.height))
    }
}
