import CompetitionCore
import SwiftUI

/// The week drawn like the mark: your bar on the left, split into Move,
/// Exercise and Stand; the opponent's single neutral bar on the right.
/// Accessibility sizes switch to stacked rows instead of shrinking text.
struct CompetitionWeekChart: View {
    let days: [LocalCompetitionDayPresentation]
    let currentDayOrdinal: Int?
    let ownerName: String
    let opponentName: String
    var showsDates = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 12 : 6) {
            ForEach(days, id: \.ordinal) { day in
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        StackedDayRow(
                            day: day,
                            isToday: day.ordinal == currentDayOrdinal,
                            ownerName: ownerName,
                            opponentName: opponentName
                        )
                    } else {
                        HeadToHeadDayRow(
                            day: day,
                            isToday: day.ordinal == currentDayOrdinal,
                            showsDates: showsDates
                        )
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("competition.day.\(day.ordinal)")
                .accessibilityLabel(
                    competitionDayAccessibilityLabel(
                        day,
                        currentDayOrdinal: currentDayOrdinal,
                        ownerName: ownerName,
                        opponentName: opponentName
                    )
                )
            }
        }
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
                "Move, Exercise and Stand are your rings. \(opponentName) shows points only."
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
        swatch(Theme.ink, "\(opponentName.uppercased()) · POINTS ONLY")
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

    var body: some View {
        HStack(spacing: 6) {
            Text(chartValueText(ownerState))
                .foregroundStyle(ownerColor)
                .fixedSize()
                .frame(minWidth: 36, alignment: .leading)
            OwnerDayBar(state: ownerState, segments: ringSegments(day))
            DayLabel(day: day, isToday: isToday, showsDates: showsDates)
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
        return owner >= opponent ? Theme.you : Theme.tertiary
    }

    private var opponentColor: Color {
        guard let opponent = day.opponentRevealedPoints else { return Theme.faint }
        guard !isToday, let owner = day.ownerAcceptedPoints else {
            return Theme.ink
        }
        return opponent >= owner ? Theme.ink : Theme.tertiary
    }
}

private struct StackedDayRow: View {
    let day: LocalCompetitionDayPresentation
    let isToday: Bool
    let ownerName: String
    let opponentName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isToday ? "Day \(day.ordinal) · Today" : "Day \(day.ordinal)")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text("\(day.day.month)/\(day.day.day)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.secondary)
            score(ownerName, chartValueText(competitionOwnerChartState(day)), Theme.you)
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

    var body: some View {
        VStack(spacing: 0) {
            Text(isToday ? "TODAY" : weekdayText(day.day))
                .font(.themeLabel)
                .tracking(1.0)
                .foregroundStyle(isToday ? Theme.ink : Theme.secondary)
            if showsDates {
                Text("\(day.day.month)/\(day.day.day)")
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

/// Splits an accepted day score by each ring's share of the accepted
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
    let shares = [snapshot.move, snapshot.exercise, snapshot.standOrRoll].map {
        reading -> Double in
        guard let value = reading.value, let goal = reading.goal,
              value.isFinite, goal.isFinite, value >= 0, goal > 0
        else { return 0 }
        return value / goal
    }
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

/// Short weekday for a competition calendar day, e.g. "WED".
func weekdayText(_ day: CompetitionDay) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    calendar.locale = .current
    guard let date = calendar.date(
        from: DateComponents(year: day.year, month: day.month, day: day.day)
    ) else {
        return "\(day.month)/\(day.day)"
    }
    let index = calendar.component(.weekday, from: date) - 1
    return calendar.shortWeekdaySymbols[index].uppercased(with: .current)
}
