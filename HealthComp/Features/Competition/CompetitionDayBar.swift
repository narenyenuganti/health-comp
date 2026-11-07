import SwiftUI

// The app, the widget extensions and the watch compile this file: SwiftUI,
// Theme and the widget snapshot only.

/// One day on the week strip: amber when you won it, ink when they did, grey
/// for a tie, striped for no data, an outline when upcoming, and a dashed
/// outline in the leader's color for today.
struct CompetitionDayBar: View {
    let outcome: CompetitionDayOutcome
    let todayColor: Color

    var body: some View {
        switch outcome {
        case .today:
            SlantedBar()
                .stroke(todayColor, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        case .upcoming:
            SlantedBar().stroke(Theme.outline, lineWidth: 1)
        case .noData:
            HatchBar()
        case .won:
            SlantedBar().fill(Theme.youFill)
        case .lost:
            SlantedBar().fill(Theme.ink)
        case .tied:
            SlantedBar().fill(Theme.tertiary)
        }
    }
}

/// The week as seven bars. `decorate` lets a surface move or accent one bar,
/// so this file needs no Motion and works in the widgets.
struct CompetitionWeekStrip<Bar: View>: View {
    let match: CompetitionWidgetSnapshot.Match
    let date: Date
    let height: CGFloat
    let spacing: CGFloat
    @ViewBuilder let decorate: (Int, CompetitionDayOutcome, CompetitionDayBar) -> Bar

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(match.dayOutcomes(at: date).enumerated()), id: \.offset) { index, outcome in
                decorate(index, outcome, CompetitionDayBar(outcome: outcome, todayColor: todayColor))
                    .frame(height: height)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Today's dashed bar in the color of whoever leads the day.
    private var todayColor: Color {
        guard case let .live(day) = match.state(at: date),
              match.userDayPoints.indices.contains(day - 1),
              match.opponentDayPoints.indices.contains(day - 1),
              let user = match.userDayPoints[day - 1],
              let opponent = match.opponentDayPoints[day - 1]
        else { return Theme.outline }
        return competitionDisplayedMargin(userPoints: user, opponentPoints: opponent) >= 0
            ? Theme.you : Theme.ink
    }
}

extension CompetitionWeekStrip where Bar == CompetitionDayBar {
    init(match: CompetitionWidgetSnapshot.Match, date: Date, height: CGFloat, spacing: CGFloat) {
        self.init(match: match, date: date, height: height, spacing: spacing) { _, _, bar in bar }
    }
}

/// Vertical 1 pt lines every 3 pt: the "no data" fill.
struct HatchFill: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX + 0.5
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += 3
        }
        return path
    }
}

/// A slanted bar filled with the "no data" stripe.
struct HatchBar: View {
    var body: some View {
        HatchFill()
            .stroke(Theme.faint, lineWidth: 1)
            .clipShape(SlantedBar())
    }
}
