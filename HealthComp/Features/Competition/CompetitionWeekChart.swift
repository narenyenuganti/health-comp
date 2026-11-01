import CompetitionCore
import SwiftUI

/// The week drawn like the mark: your bar on the left, split into Move,
/// Exercise and Stand; the opponent's single neutral bar on the right.
/// Accessibility sizes switch to stacked rows instead of shrinking text.
struct CompetitionWeekChart: View {
    let days: [LocalCompetitionDayPresentation]
    let currentDayOrdinal: Int?
    /// The projection's time, so dates agree with "Today" and "Day 4 of 7".
    let now: Date
    let opponentName: String
    var showsDates = false
    /// Makes each day that has started open its breakdown.
    var selectDay: ((LocalCompetitionDayPresentation) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 12 : 6) {
            ForEach(days, id: \.ordinal) { day in
                if let selectDay, day.ownerLatestAvailability != .notYetOccurred {
                    Button {
                        selectDay(day)
                    } label: {
                        row(day)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("competition.day.\(day.ordinal)")
                    .accessibilityLabel(dayAccessibilityLabel(day))
                    .accessibilityHint("Opens this day’s breakdown")
                } else {
                    row(day)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("competition.day.\(day.ordinal)")
                        .accessibilityLabel(dayAccessibilityLabel(day))
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ day: LocalCompetitionDayPresentation) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            StackedDayRow(
                day: day,
                isToday: day.ordinal == currentDayOrdinal,
                now: now,
                opponentName: opponentName
            )
        } else {
            HeadToHeadDayRow(
                day: day,
                isToday: day.ordinal == currentDayOrdinal,
                showsDates: showsDates,
                now: now
            )
        }
    }

    private func dayAccessibilityLabel(
        _ day: LocalCompetitionDayPresentation
    ) -> String {
        competitionDayAccessibilityLabel(
            day,
            currentDayOrdinal: currentDayOrdinal,
            opponentName: opponentName,
            now: now
        )
    }
}

/// The week at a glance: one bar per day in the color of whoever won it,
/// amber for you and ink for them. Today stays dashed until it is scored.
struct CompetitionWeekStrip: View {
    let days: [LocalCompetitionDayPresentation]
    let currentDayOrdinal: Int?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(days, id: \.ordinal) { day in
                VStack(spacing: 6) {
                    bar(day)
                        .frame(height: 10)
                    // Seven columns can't hold larger weekday text; the bars
                    // still read in order.
                    if dynamicTypeSize < .xxLarge {
                        Text(
                            day.ordinal == currentDayOrdinal
                                ? "TODAY"
                                : weekdayText(day.day)
                        )
                        .textCase(.uppercase)
                        .font(.caption2.weight(.bold).width(.condensed))
                        .tracking(1)
                        .foregroundStyle(
                            day.ordinal == currentDayOrdinal
                                ? Theme.ink
                                : Theme.secondary
                        )
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func bar(_ day: LocalCompetitionDayPresentation) -> some View {
        if day.ordinal == currentDayOrdinal {
            SlantedBar()
                .stroke(
                    leaderColor(day),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                )
        } else {
            SlantedBar().fill(winnerColor(day))
        }
    }

    private func winnerColor(_ day: LocalCompetitionDayPresentation) -> Color {
        guard let owner = day.ownerAcceptedPoints,
              let opponent = day.opponentRevealedPoints
        else {
            return day.ownerLatestAvailability == .notYetOccurred
                ? Theme.track
                : Theme.faint
        }
        let margin = competitionDisplayedMargin(userPoints: owner, opponentPoints: opponent)
        if margin > 0 { return Theme.youFill }
        if margin < 0 { return Theme.ink }
        return Theme.outline
    }

    private func leaderColor(_ day: LocalCompetitionDayPresentation) -> Color {
        guard let owner = day.ownerAcceptedPoints,
              let opponent = day.opponentRevealedPoints
        else {
            return Theme.outline
        }
        return competitionDisplayedMargin(userPoints: owner, opponentPoints: opponent) >= 0
            ? Theme.you : Theme.ink
    }
}

/// Move, Exercise and Stand, plus the opponent's single bar. Accessibility
/// sizes show named rows instead of bars, so the legend steps aside.
struct CompetitionRingLegend: View {
    let opponentName: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if !dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) { rings }
                opponent
            }
            .foregroundStyle(Theme.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Move, Exercise and Stand are your rings. The single bar is \(opponentName)."
            )
        }
    }

    @ViewBuilder
    private var rings: some View {
        swatch(Theme.move, "MOVE")
        swatch(Theme.exercise, "EXERCISE")
        swatch(Theme.stand, "STAND")
    }

    private var opponent: some View {
        swatch(Theme.ink, opponentName.uppercased())
    }

    private func swatch(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            SlantedBar().fill(color).frame(width: 10, height: 10)
            Text(title).font(.themeLabel).tracking(1.1)
        }
    }
}

private struct HeadToHeadDayRow: View {
    let day: LocalCompetitionDayPresentation
    let isToday: Bool
    let showsDates: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(chartValueText(ownerState))
                .foregroundStyle(ownerColor)
                .fixedSize()
                .frame(minWidth: 36, alignment: .leading)
            OwnerDayBar(state: ownerState, segments: ringSegments(day))
            DayLabel(day: day, isToday: isToday, showsDates: showsDates, now: now)
            OpponentDayBar(state: opponentState)
            Text(chartValueText(opponentState))
                .foregroundStyle(opponentColor)
                .fixedSize()
                .frame(minWidth: 36, alignment: .trailing)
        }
        .font(.headline.weight(.bold).width(.condensed).monospacedDigit())
        .padding(.horizontal, isToday ? 6 : 0)
        .frame(minHeight: showsDates ? 38 : 30)
        .background(
            isToday ? Theme.panel : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var ownerState: CompetitionChartState {
        competitionOwnerChartState(day)
    }

    private var opponentState: CompetitionChartState {
        day.opponentRevealedPoints.map(CompetitionChartState.score) ?? .future
    }

    // Day winners stay bright; the other number steps back.
    private var ownerColor: Color {
        guard let owner = day.ownerAcceptedPoints else { return Theme.faint }
        guard !isToday, let opponent = day.opponentRevealedPoints else {
            return Theme.you
        }
        return competitionDisplayedMargin(userPoints: owner, opponentPoints: opponent) >= 0
            ? Theme.you : Theme.tertiary
    }

    private var opponentColor: Color {
        guard let opponent = day.opponentRevealedPoints else { return Theme.faint }
        guard !isToday, let owner = day.ownerAcceptedPoints else {
            return Theme.ink
        }
        return competitionDisplayedMargin(userPoints: owner, opponentPoints: opponent) <= 0
            ? Theme.ink : Theme.tertiary
    }
}

private struct StackedDayRow: View {
    let day: LocalCompetitionDayPresentation
    let isToday: Bool
    let now: Date
    let opponentName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isToday ? "Day \(day.ordinal) · Today" : "Day \(day.ordinal)")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text(competitionDayText(day.day, now: now))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.secondary)
            score("You", chartValueText(competitionOwnerChartState(day)), Theme.you)
            score(
                opponentName,
                chartValueText(
                    day.opponentRevealedPoints.map(CompetitionChartState.score)
                        ?? .future
                ),
                Theme.ink
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .themePanel(cornerRadius: 14)
    }

    private func score(_ name: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
            Text(value).font(.title2.weight(.heavy).width(.condensed).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

private struct DayLabel: View {
    let day: LocalCompetitionDayPresentation
    let isToday: Bool
    let showsDates: Bool
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            Text(isToday ? "TODAY" : weekdayText(day.day))
                .textCase(.uppercase)
                .font(.themeLabel)
                .tracking(1.0)
                .foregroundStyle(isToday ? Theme.ink : Theme.secondary)
            if showsDates {
                Text(competitionDayText(day.day, weekday: false, now: now))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .fixedSize()
        .frame(minWidth: 44)
    }
}

private struct OwnerDayBar: View {
    let state: CompetitionChartState
    let segments: [(color: Color, points: Double)]

    var body: some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / ActivityScore.maximumDailyPoints
            HStack(spacing: 1.5) {
                Spacer(minLength: 0)
                switch state {
                case .score:
                    ForEach(segments.indices.reversed(), id: \.self) { index in
                        SlantedBar()
                            .fill(segments[index].color)
                            .frame(width: max(2, segments[index].points * unit))
                    }
                case let .missingWithScore(points), let .unavailableWithScore(points):
                    SlantedBar()
                        .stroke(Theme.you, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(width: max(4, points * unit))
                case .future:
                    Rectangle().fill(Theme.track).frame(height: 2)
                case .missing, .unavailable, .unscored:
                    Rectangle().fill(Theme.faint).frame(width: 24, height: 2)
                }
            }
            .frame(height: proxy.size.height)
        }
        .frame(height: 20)
    }
}

private struct OpponentDayBar: View {
    let state: CompetitionChartState

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if case let .score(points) = state {
                    SlantedBar()
                        .fill(Theme.ink)
                        .frame(
                            width: max(
                                2,
                                points / ActivityScore.maximumDailyPoints
                                    * proxy.size.width
                            )
                        )
                } else {
                    Rectangle().fill(Theme.track).frame(height: 2)
                }
                Spacer(minLength: 0)
            }
            .frame(height: proxy.size.height)
        }
        .frame(height: 20)
    }
}

/// Each ring's scored share (value / goal, 0 when unusable), capped at
/// `perRingCap` percent when the match caps rings.
func competitionRingShares(
    _ snapshot: ActivitySnapshot,
    perRingCap: Double?
) -> [Double] {
    [snapshot.move, snapshot.exercise, snapshot.standOrRoll].map {
        reading -> Double in
        guard let value = reading.value, let goal = reading.goal,
              value.isFinite, goal.isFinite, value >= 0, goal > 0
        else { return 0 }
        let share = value / goal
        return perRingCap.map { min($0 / 100, share) } ?? share
    }
}

/// Splits an accepted day score by each ring's scored share of the accepted
/// snapshot, so the bar's length stays exactly the accepted points. Without a
/// snapshot the day is one amber bar: your score, unsplit.
func ringSegments(
    _ day: LocalCompetitionDayPresentation
) -> [(color: Color, points: Double)] {
    guard case let .score(points) = competitionOwnerChartState(day) else {
        return []
    }
    guard let snapshot = day.ownerAcceptedSnapshot else {
        return [(Theme.youFill, points)]
    }
    let shares = competitionRingShares(
        snapshot, perRingCap: day.scoringPolicy.perRingCap
    )
    let total = shares.reduce(0, +)
    guard total > 0 else { return [(Theme.youFill, points)] }
    return zip([Theme.move, Theme.exercise, Theme.stand], shares).map {
        ($0, points * $1 / total)
    }
}

private func chartValueText(_ state: CompetitionChartState) -> String {
    switch state {
    case let .score(points), let .missingWithScore(points),
         let .unavailableWithScore(points):
        competitionPointsText(points)
    case .future: "—"
    case .missing: "?"
    case .unavailable: "!"
    case .unscored: "–"
    }
}

/// A competition calendar day as UTC midnight, so it never shifts with the
/// phone's zone.
private func competitionDayDate(_ day: CompetitionDay) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = competitionDayTimeZone
    return calendar.date(
        from: DateComponents(year: day.year, month: day.month, day: day.day)
    )
}

private let competitionDayTimeZone = TimeZone(identifier: "UTC")!

/// Short weekday for a competition calendar day, e.g. "Wed".
func weekdayText(_ day: CompetitionDay, locale: Locale = .current) -> String {
    guard let date = competitionDayDate(day) else {
        return "\(day.month)/\(day.day)"
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = competitionDayTimeZone
    calendar.locale = locale
    let index = calendar.component(.weekday, from: date) - 1
    return calendar.shortWeekdaySymbols[index]
}

/// The day style for a competition calendar day: "Thu, Oct 29". The year
/// shows when the day's calendar year isn't the viewer's current year;
/// UTC is only for drawing the day.
func competitionDayText(
    _ day: CompetitionDay,
    weekday: Bool = true,
    now: Date = Date(),
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    guard let date = competitionDayDate(day) else {
        return "\(day.month)/\(day.day)"
    }
    return competitionDayText(
        date,
        weekday: weekday,
        includesYear: day.year != competitionYear(of: now, timeZone: timeZone),
        locale: locale,
        timeZone: competitionDayTimeZone
    )
}

/// The week style for two competition calendar days: "Oct 28 – Nov 3".
func competitionWeekText(
    _ first: CompetitionDay,
    _ last: CompetitionDay,
    now: Date = Date(),
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    guard let firstDate = competitionDayDate(first),
          let lastDate = competitionDayDate(last)
    else {
        return "\(first.month)/\(first.day) – \(last.month)/\(last.day)"
    }
    return competitionWeekText(
        firstDate,
        lastDate,
        includesYear: last.year != competitionYear(of: now, timeZone: timeZone),
        locale: locale,
        timeZone: competitionDayTimeZone
    )
}
