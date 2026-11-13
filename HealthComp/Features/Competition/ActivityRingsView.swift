import CompetitionCore
import SwiftUI

struct CompetitionRingRow: Equatable, Sendable {
    /// "Move" | "Move Time" | "Exercise" | "Stand" | "Roll" | "Stand or Roll"
    let title: String
    /// "420/500 kcal" | "No data"
    let detail: String
    /// "420 of 500 kilocalories" | "no data"
    let spokenDetail: String
    /// Whole points; nil when the reading has no score.
    let points: Double?
}

struct CompetitionRingPanel: Equatable, Sendable {
    /// Always Move, Exercise, Stand.
    let rows: [CompetitionRingRow]
    let isPaused: Bool
    let note: String?
    let footer: String
    let accessibilityLabel: String
}

/// One snapshot as three ring rows whose points add up to the day's points:
/// the accepted snapshot when there is one, otherwise the latest. Nil when the
/// day has neither snapshot.
func competitionRingPanel(
    _ day: LocalCompetitionDayPresentation,
    locale: Locale = .current
) -> CompetitionRingPanel? {
    guard let snapshot = day.ownerAcceptedSnapshot ?? day.ownerLatestSnapshot else {
        return nil
    }
    let isAccepted = day.ownerAcceptedSnapshot != nil
    let total = isAccepted
        ? day.ownerAcceptedPoints
        : ActivityScoreCalculator.score(snapshot, policy: day.scoringPolicy).availableScore?.points
    let shares = competitionRingShares(snapshot, perRingCap: day.scoringPolicy.perRingCap)
    let sum = shares.reduce(0, +)
    let points = total.map { total in
        competitionRoundedParts(shares.map { sum > 0 ? total * $0 / sum : 0 }, total: total)
    }

    func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }
    func row(_ index: Int, _ title: String, _ reading: ActivityRingReading, _ unit: String, _ spokenUnit: String) -> CompetitionRingRow {
        guard let value = reading.value, let goal = reading.goal, goal > 0 else {
            return CompetitionRingRow(title: title, detail: "No data", spokenDetail: "no data", points: points?[index])
        }
        return CompetitionRingRow(
            title: title,
            detail: "\(number(value))/\(number(goal)) \(unit)",
            spokenDetail: "\(number(value)) of \(number(goal)) \(spokenUnit)",
            points: points?[index]
        )
    }

    let minutes = snapshot.moveMode == .moveMinutes
    let standTitle = switch snapshot.standMode {
    case .standHours: "Stand"
    case .rollHours: "Roll"
    case .unknown: "Stand or Roll"
    }
    let rows = [
        row(0, minutes ? "Move Time" : "Move", snapshot.move, minutes ? "min" : "kcal", minutes ? "minutes" : "kilocalories"),
        row(1, "Exercise", snapshot.exercise, "min", "minutes"),
        row(2, standTitle, snapshot.standOrRoll, "hr", "hours"),
    ]
    let isPaused = snapshot.pauseState == .paused

    let note: String? = if isAccepted, day.ownerLatestSnapshot != snapshot {
        "Points use an earlier reading. Your rings have changed since."
    } else if !isAccepted, total != nil {
        "These points haven’t synced yet."
    } else {
        nil
    }

    let rule: String = if let cap = day.scoringPolicy.perRingCap {
        "1 point per 1% of each ring, up to \(Int(cap))% per ring."
    } else if sum * 100 > ActivityScore.maximumDailyPoints {
        "Capped at 600 points a day."
    } else {
        "1 point per 1% of each ring."
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
        footer: "\(rule) Your ring values stay on this iPhone.",
        accessibilityLabel: spoken
    )
}

/// Your rings for one day: three rows that add up to the day's points, then
/// the scoring rule. Ring colors appear only here, on your own rows.
struct ActivityRingsView: View {
    let panel: CompetitionRingPanel

    @Environment(\.locale) private var locale

    private let colors = [Theme.move, Theme.exercise, Theme.stand]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(panel.rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        SlantedBar()
                            .fill(colors[index])
                            .frame(width: 10, height: 10)
                        (Text(row.title).fontWeight(.semibold).foregroundStyle(Theme.ink)
                            + Text(" · \(row.detail)").foregroundStyle(Theme.secondary))
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

            Text(panel.footer)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: What it takes

/// "39 to take the lead" on a live day when you're behind or level; nil otherwise.
struct CompetitionWhatItTakes: Equatable, Sendable {
    /// The day these numbers describe (the presentation's currentDayOrdinal).
    let dayOrdinal: Int
    /// Whole points that take the lead; nil when out of reach today.
    let points: Double?
    /// "39 to take the lead" | "Out of reach today"
    let headline: String
    /// "About 240 kcal of Move or 12 min of Exercise." | the out-of-reach sentence
    let suggestion: String
    /// The suggestion, plus " Sam can still add points today." while that's true.
    let detail: String
    let accessibilityLabel: String
}

/// The points that take the lead, as one or two of your own rings (Move and
/// Exercise only; Stand is never suggested). Needs today's accepted snapshot
/// to match the latest, so it never asks for activity you've already done.
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
    let need = 1 - margin
    let left = max(0, ActivityScore.maximumDailyPoints - today)
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
        // ActivityRingReading already rejects negative and non-finite numbers.
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
    let move = ring(0, snapshot.move, moveMinutes ? "Move Time" : "Move", minutes: moveMinutes)
    let exercise = ring(1, snapshot.exercise, "Exercise", minutes: true)
    let reach = min(left, move.room + exercise.room).rounded(.down)

    func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }
    let name = competition.opponentDisplayName

    guard need <= reach else {
        let level = margin == 0
        let gap = competitionPointsText(-margin, locale: locale)
        let spokenGap = competitionPointsAccessibilityText(-margin, locale: locale)
        func sentence(_ gap: String) -> String {
            let lead = level ? "All square, and" : "\(name) is \(gap) ahead and"
            if reach >= 1 {
                return "\(lead) you have \(competitionPointsAccessibilityText(reach, locale: locale)) left in Move and Exercise today."
            }
            return left.rounded(.down) == 0
                ? "\(lead) you’ve reached today’s cap."
                : "\(lead) Move and Exercise are at the 200% cap."
        }
        let text = sentence(gap)
        return CompetitionWhatItTakes(
            dayOrdinal: ordinal,
            points: nil,
            headline: "Out of reach today",
            suggestion: text,
            detail: text,
            accessibilityLabel: "Out of reach today. \(sentence(spokenGap))"
        )
    }

    // Rounded up, so following the suggestion always takes the lead.
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
    // More room first; Move first on ties.
    let rings = (exercise.room > move.room ? [exercise, move] : [move, exercise]).filter { $0.room > 0 }
    let singles = rings.filter { $0.room >= need }
    let parts = singles.isEmpty
        ? [part(rings[0], rings[0].room), part(rings[1], need - rings[0].room)]
        : singles.map { part($0, need) }
    let joiner = singles.isEmpty ? " and " : " or "
    let suggestion = "About \(parts.map(\.text).joined(separator: joiner))."
    let spokenSuggestion = "About \(parts.map(\.spoken).joined(separator: joiner))."
    let moving = day.opponentRevealedPoints.map { $0 < ActivityScore.maximumDailyPoints } ?? true
        ? " \(name) can still add points today."
        : ""
    return CompetitionWhatItTakes(
        dayOrdinal: ordinal,
        points: need,
        headline: "\(competitionPointsText(need, locale: locale)) to take the lead",
        suggestion: suggestion,
        detail: suggestion + moving,
        accessibilityLabel: "\(competitionPointsAccessibilityText(need, locale: locale)) to take the lead. \(spokenSuggestion)\(moving)"
    )
}

/// The Today page's line above your rings: amber when the lead is reachable.
struct CompetitionWhatItTakesPanel: View {
    let takes: CompetitionWhatItTakes

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Within reach the number rolls. Out of reach or a new day is a
            // new id, so the words and the colour crossfade.
            ZStack(alignment: .leading) {
                Text(takes.headline)
                    .font(.title3.weight(.heavy).width(.condensed))
                    .foregroundStyle(takes.points == nil ? Theme.ink : Theme.you)
                    .fixedSize(horizontal: false, vertical: true)
                    .scoreRoll(takes.points, id: headlineID)
            }
            .animation(Motion.fade, value: headlineID)
            Text(takes.detail)
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

// MARK: Today, from the Home logo

/// Today's rings for the sheet the Home logo opens.
struct CompetitionTodayRings: Equatable, Sendable {
    let panel: CompetitionRingPanel
    /// Today's points so far; nil when the reading has no score.
    let points: Double?
    /// "Updated 9:41 AM"; nil before the first full read.
    let updated: String?
}

/// The first match that is scoring today and has a reading for it. Every live
/// match reads the same rings, so the first one speaks for the day.
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

/// Your three rings today as bars, with the points each has earned.
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
        // As tall as its content; a taller one scrolls.
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
                    // 1 point per 1% of the ring: 100 closes it.
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
                    Text(competitionPointsText(points, locale: locale))
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.ink)
                        + Text(" of \(Self.dailyMaximum) points today")
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

/// Two slanted segments, one per 100% of the ring: the first full means the
/// ring is closed, both full means it has earned all a ring can.
private struct TodayRingBar: View {
    let closes: Double
    let color: Color

    var body: some View {
        TodayRingSegments(closes: 2)
            .fill(Theme.track)
            .overlay { TodayRingSegments(closes: closes).fill(color) }
    }
}

/// One shape, so a growing bar fills its first segment before its second.
private struct TodayRingSegments: Shape {
    /// 0...2: how much of the two segments to draw.
    var closes: Double

    var animatableData: Double {
        get { closes }
        set { closes = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let gap: CGFloat = 4
        let width = (rect.width - gap) / 2
        var path = Path()
        for segment in 0..<2 {
            let fill = min(1, max(0, closes - Double(segment)))
            guard fill > 0 else { continue }
            path.addPath(SlantedBar().path(in: CGRect(
                x: rect.minX + CGFloat(segment) * (width + gap),
                y: rect.minY,
                width: width * fill,
                height: rect.height
            )))
        }
        return path
    }
}
