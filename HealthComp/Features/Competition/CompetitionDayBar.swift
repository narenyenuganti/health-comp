import SwiftUI

// The app and the widget extension both compile this file: SwiftUI and
// Theme only.

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
