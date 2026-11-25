import SwiftUI

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

struct CompetitionMatchStrip<Bar: View>: View {
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

extension CompetitionMatchStrip where Bar == CompetitionDayBar {
    init(match: CompetitionWidgetSnapshot.Match, date: Date, height: CGFloat, spacing: CGFloat) {
        self.init(match: match, date: date, height: height, spacing: spacing) { _, _, bar in bar }
    }
}

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

struct HatchBar: View {
    var body: some View {
        HatchFill()
            .stroke(Theme.faint, lineWidth: 1)
            .clipShape(SlantedBar())
    }
}

struct CompetitionRing: Equatable {
    let color: Color
    let progress: Double
}

struct CompetitionRingStackLayout: Equatable {
    let size: CGFloat
    let count: Int

    var lineWidth: CGFloat {
        let radius = size / 2
        let available = radius - padding - hole - gap * CGFloat(max(count - 1, 0))
        return min(size * 0.15, available / CGFloat(max(count, 1)))
    }

    var hole: CGFloat { size * (size < 40 ? 0.08 : 0.13) }

    func diameter(_ index: Int) -> CGFloat {
        let radius = size / 2 - padding - lineWidth / 2 - CGFloat(index) * (lineWidth + gap)
        return radius * 2
    }

    private var padding: CGFloat { size * 0.015 }
    private var gap: CGFloat { max(0.7, size * 0.025) }
}

struct CompetitionRingStack: View {
    let rings: [CompetitionRing]
    var track: Color = Theme.track

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let layout = CompetitionRingStackLayout(size: size, count: rings.count)
            ZStack {
                ForEach(rings.indices, id: \.self) { index in
                    let diameter = layout.diameter(index)
                    Circle()
                        .stroke(track, lineWidth: layout.lineWidth)
                        .frame(width: diameter, height: diameter)
                    Circle()
                        .trim(from: 0, to: min(max(rings[index].progress, 0), 0.999))
                        .stroke(rings[index].color, style: StrokeStyle(lineWidth: layout.lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: diameter, height: diameter)
                        .opacity(rings[index].progress > 0 ? 1 : 0)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
