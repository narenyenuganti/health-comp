import CompetitionCore
import SwiftUI

struct CompetitionWeekChart: View {
    let days: [LocalCompetitionDayPresentation]
    let currentDayOrdinal: Int?
    let now: Date
    let opponentName: String
    var showsDates = false
    var isGrown = true
    var selectDay: ((LocalCompetitionDayPresentation) -> Void)?
    var clap: CompetitionDayClap?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: dynamicTypeSize >= .xxLarge ? 12 : 6) {
            ForEach(days, id: \.ordinal) { day in
                HStack(spacing: 6) {
                    dayRow(day)
                    if let clap {
                        clapSlot(day, clap)
                    }
                }
                .background {
                    if day.ordinal == currentDayOrdinal, dynamicTypeSize < .xxLarge {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.panel)
                            .padding(.horizontal, -6)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayRow(_ day: LocalCompetitionDayPresentation) -> some View {
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
            .accessibilityActions {
                if let clap, competitionDayIsClappable(day, currentDayOrdinal: currentDayOrdinal),
                   clap.sent(day.ordinal) == nil {
                    Button(competitionClapLabel(opponentName: opponentName, day: day.day)) {
                        clap.send(day.ordinal)
                    }
                }
            }
        } else {
            row(day)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("competition.day.\(day.ordinal)")
                .accessibilityLabel(dayAccessibilityLabel(day))
        }
    }

    @ViewBuilder
    private func clapSlot(_ day: LocalCompetitionDayPresentation, _ clap: CompetitionDayClap) -> some View {
        if competitionDayIsClappable(day, currentDayOrdinal: currentDayOrdinal) {
            DayClapButton(
                sent: clap.sent(day.ordinal),
                isPending: clap.isPending(day.ordinal),
                label: competitionClapLabel(opponentName: opponentName, day: day.day),
                send: { clap.send(day.ordinal) },
                open: { selectDay?(day) }
            )
            .accessibilityIdentifier("competition.day.\(day.ordinal).clap")
        } else {
            Color.clear.frame(width: 44, height: 1)
        }
    }

    @ViewBuilder
    private func row(_ day: LocalCompetitionDayPresentation) -> some View {
        if dynamicTypeSize >= .xxLarge {
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
                isGrown: isGrown,
                now: now,
                opponentName: opponentName
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

struct CompetitionDayClap {
    let sent: (Int) -> CompetitionReactionKind?
    let isPending: (Int) -> Bool
    let send: (Int) -> Void
}

func competitionDayIsClappable(
    _ day: LocalCompetitionDayPresentation,
    currentDayOrdinal: Int?
) -> Bool {
    day.ownerLatestAvailability != .notYetOccurred
        && day.ordinal < currentDayOrdinal ?? .max
        && day.opponentRevealedPoints != nil
}

func competitionClapLabel(
    opponentName: String,
    day: CompetitionDay,
    locale: Locale = .current
) -> String {
    "Clap for \(opponentName)’s \(weekdayName(day, locale: locale))"
}

private struct DayClapButton: View {
    let sent: CompetitionReactionKind?
    let isPending: Bool
    let label: String
    let send: () -> Void
    let open: () -> Void

    @Environment(\.competitionReactionRain) private var rain

    var body: some View {
        let isSent = sent != nil
        Button {
            if isSent {
                open()
            } else {
                rain(.clap)
                send()
            }
        } label: {
            Text((sent ?? .clap).emoji)
                .font(.callout)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .grayscale(isSent ? 0 : 1)
                .opacity(isSent ? 1 : 0.55)
                .frame(width: 34, height: 34)
                .background(isSent ? Theme.control : Theme.ground, in: Circle())
                .overlay {
                    Circle().strokeBorder(
                        isSent ? Theme.ink : Theme.outline,
                        lineWidth: isSent ? 1.5 : 1
                    )
                }
                .animation(Motion.fade, value: sent)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .onChange(of: isPending) { _, pending in
            if !pending, isSent { Sounds.play(.sent) }
        }
        .accessibilityLabel(sent.map { "You sent \($0.spokenName)" } ?? label)
        .accessibilityHint(isSent ? "Opens this day’s breakdown" : "")
    }
}

struct CompetitionWeekStrip: View {
    let days: [LocalCompetitionDayPresentation]
    let currentDayOrdinal: Int?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.launchStage) private var launchStage

    private static let todayWeight: CGFloat = 2.6

    var body: some View {
        WeightedRow(weights: days.map { isSplit($0) ? Self.todayWeight : 1 }, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.element.ordinal) { index, day in
                VStack(spacing: 6) {
                    bar(day)
                        .frame(height: isSplit(day) ? 14 : 10)
                        .padding(.vertical, isSplit(day) ? -2 : 0)
                        .scaleEffect(x: launchStage == .waiting ? 0 : 1, anchor: .leading)
                        .moving(Motion.grow(index, of: days.count), value: launchStage)
                    if dynamicTypeSize < .xxLarge {
                        label(day)
                            .font(.caption2.weight(.bold).width(.condensed).monospacedDigit())
                            .tracking(1)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(Motion.fade, value: days.map(outcome))
        .animation(Motion.fade, value: days.map(leaderColor))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func bar(_ day: LocalCompetitionDayPresentation) -> some View {
        if isSplit(day) {
            TodaySplitBar(you: day.ownerAcceptedPoints ?? 0, them: day.opponentRevealedPoints ?? 0)
        } else {
            CompetitionDayBar(outcome: outcome(day), todayColor: leaderColor(day))
        }
    }

    @ViewBuilder
    private func label(_ day: LocalCompetitionDayPresentation) -> some View {
        let weekday = Text(weekdayText(day.day)).textCase(.uppercase)
        if isSplit(day) {
            HStack(spacing: 5) {
                Text(competitionPointsText(day.ownerAcceptedPoints)).foregroundStyle(Theme.you)
                weekday.foregroundStyle(Theme.ink)
                Text(competitionPointsText(day.opponentRevealedPoints)).foregroundStyle(Theme.ink)
            }
        } else {
            weekday.foregroundStyle(day.ordinal == currentDayOrdinal ? Theme.ink : Theme.secondary)
        }
    }

    private func isSplit(_ day: LocalCompetitionDayPresentation) -> Bool {
        day.ordinal == currentDayOrdinal
            && (day.ownerAcceptedPoints ?? 0) + (day.opponentRevealedPoints ?? 0) > 0
    }

    private func outcome(_ day: LocalCompetitionDayPresentation) -> CompetitionDayOutcome {
        competitionDayOutcome(day, currentDayOrdinal: currentDayOrdinal)
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

private struct TodaySplitBar: View {
    let you: Double
    let them: Double

    var body: some View {
        let share = you + them > 0 ? you / (you + them) : 0.5
        GeometryReader { proxy in
            let inset: CGFloat = 2.5
            let gap: CGFloat = 2
            let width = proxy.size.width - inset * 2 - gap
            HStack(spacing: gap) {
                SlantedBar()
                    .fill(Theme.youFill)
                    .frame(width: max(0, width * share))
                SlantedBar()
                    .fill(Theme.ink)
            }
            .padding(inset)
        }
        .overlay {
            SlantedBar().stroke(Theme.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
        .moving(Motion.settle, value: share)
    }
}

private struct WeightedRow: Layout {
    let weights: [CGFloat]
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let widths = columnWidths(width, count: subviews.count)
        let height = subviews.indices.map {
            subviews[$0].sizeThatFits(ProposedViewSize(width: widths[$0], height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(bounds.width, count: subviews.count)
        var x = bounds.minX
        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: widths[index], height: bounds.height)
            )
            x += widths[index] + spacing
        }
    }

    private func columnWidths(_ width: CGFloat, count: Int) -> [CGFloat] {
        let shares = (0..<count).map { $0 < weights.count ? weights[$0] : 1 }
        let total = shares.reduce(0, +)
        guard total > 0 else { return Array(repeating: 0, count: count) }
        let room = max(0, width - spacing * CGFloat(max(0, count - 1)))
        return shares.map { room * $0 / total }
    }
}

struct CompetitionRingLegend: View {
    let days: [LocalCompetitionDayPresentation]
    let opponentName: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize < .xxLarge {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    rings
                    others
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) { rings }
                    HStack(spacing: 12) { others }
                }
            }
            .frame(minHeight: 34)
            .contentShape(.accessibility, Rectangle())
            .foregroundStyle(Theme.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    @ViewBuilder
    private var others: some View {
        swatch(Theme.ink, opponentName.uppercased())
    }

    private var showsRings: Bool {
        days.contains { ringSegments($0).count == 3 }
    }

    private var standTitle: String {
        competitionStandTitle(days)
    }

    private var accessibilityText: String {
        [
            showsRings
                ? "Move, Exercise and \(standTitle.capitalized) are your rings."
                : "The top bar is yours.",
            "The bottom bar is \(opponentName).",
        ].compactMap { $0 }.joined(separator: " ")
    }

    @ViewBuilder
    private var rings: some View {
        if showsRings {
            swatch(Theme.move, "MOVE")
            swatch(Theme.exercise, "EXERCISE")
            swatch(Theme.stand, standTitle)
        } else {
            swatch(Theme.youFill, "YOU")
        }
    }

    private func swatch(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            SlantedBar().fill(color).frame(width: 10, height: 10)
            Text(title).themeLabel(tracking: 1.1)
        }
    }
}

struct CompetitionLeadLine: Equatable {
    let margins: [Double]
    let changes: [Double]
}

func competitionLeadLine(
    _ days: [LocalCompetitionDayPresentation],
    currentDayOrdinal: Int?
) -> CompetitionLeadLine? {
    var raw = 0.0
    var margins = [0.0]
    for day in days {
        guard day.ownerLatestAvailability != .notYetOccurred,
              day.ordinal < currentDayOrdinal ?? .max
        else { break }
        raw += (day.ownerAcceptedPoints ?? 0) - (day.opponentRevealedPoints ?? 0)
        margins.append(raw.rounded(.toNearestOrAwayFromZero))
    }
    guard margins.count > 1 else { return nil }
    var changes: [Double] = []
    var youLead: Bool?
    for k in 1 ..< margins.count where margins[k] != 0 {
        let a = margins[k - 1], b = margins[k]
        if let youLead, youLead != (b > 0) {
            changes.append(Double(k - 1) + (a == 0 ? 0 : abs(a) / (abs(a) + abs(b))))
        }
        youLead = b > 0
    }
    return CompetitionLeadLine(margins: margins, changes: changes)
}

struct CompetitionLeadMoment: Equatable {
    let index: Int
    let day: CompetitionDay
    let isYours: Bool
    let text: String
}

func competitionLeadMoments(
    _ line: CompetitionLeadLine,
    days: [LocalCompetitionDayPresentation],
    opponentName: String
) -> [CompetitionLeadMoment] {
    let ended = Array(days.prefix(line.margins.count - 1))
    var moments: [CompetitionLeadMoment] = []
    if let low = line.margins.indices.dropFirst().min(by: { line.margins[$0] < line.margins[$1] }),
       line.margins[low] < 0 {
        moments.append(CompetitionLeadMoment(
            index: low,
            day: ended[low - 1].day,
            isYours: false,
            text: "\(opponentName)’s biggest lead, \(competitionPointsText(-line.margins[low]))"
        ))
    }
    if let best = ended.indices.filter({ (ended[$0].ownerAcceptedPoints ?? 0) > 0 })
        .max(by: { ended[$0].ownerAcceptedPoints! < ended[$1].ownerAcceptedPoints! }),
       !moments.contains(where: { $0.index == best + 1 }) {
        moments.append(CompetitionLeadMoment(
            index: best + 1,
            day: ended[best].day,
            isYours: true,
            text: "Your best day, \(competitionPointsText(ended[best].ownerAcceptedPoints))"
        ))
    }
    return moments
}

func competitionLeadMomentY(
    at point: CGPoint,
    axis: CGFloat,
    changes: [CGFloat],
    height: CGFloat,
    radius: CGFloat = 12
) -> CGFloat {
    let reachX = 1.5 + 13 * tan(12 * CGFloat.pi / 180) + radius
    let reachY = 13 + radius
    guard abs(point.y - axis) < reachY,
          changes.contains(where: { abs($0 - point.x) < reachX })
    else { return point.y }
    let above = axis - reachY - 1, below = axis + reachY + 1
    let prefersBelow = point.y > axis
    if prefersBelow { return below <= height - radius ? below : above }
    return above >= radius ? above : below
}

struct CompetitionLeadLineView: View {
    let line: CompetitionLeadLine
    let days: [LocalCompetitionDayPresentation]
    let currentDayOrdinal: Int?
    let opponentName: String
    var isDrawn = true
    var sideLabels: (you: String, them: String)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let minimumScale = 50.0
    private static let unusedScale = 10.0
    @ScaledMetric(relativeTo: .footnote) private var endLabelWidth: CGFloat = 48
    @ScaledMetric(relativeTo: .footnote) private var endLabelHalfHeight: CGFloat = 9

    private var last: Double { line.margins.last ?? 0 }
    private var lastDay: Int { line.margins.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sideLabels {
                sideLabel(sideLabels.you, Theme.you)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SectionLabel("THE LEAD AFTER EACH DAY")
                    Spacer(minLength: 0)
                    if !line.changes.isEmpty {
                        Text(changedText)
                            .themeLabel()
                            .foregroundStyle(Theme.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            chart
                .frame(height: 120)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
                .accessibilityIdentifier("competition.leadLine")
            if let sideLabels {
                sideLabel(sideLabels.them, Theme.secondary)
            }
            if dynamicTypeSize < .xxLarge {
                weekdays
            }
            if !moments.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(moments.indices, id: \.self) { index in
                        momentRow(index, moments[index])
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private var moments: [CompetitionLeadMoment] {
        guard sideLabels == nil else { return [] }
        return competitionLeadMoments(line, days: days, opponentName: opponentName)
    }

    private func momentRow(_ index: Int, _ moment: CompetitionLeadMoment) -> some View {
        HStack(spacing: 10) {
            CompetitionLeadMomentBadge(number: index + 1, isYours: moment.isYours)
            Text(weekdayText(moment.day))
                .textCase(.uppercase)
                .themeLabel(tracking: 1.0)
                .foregroundStyle(Theme.secondary)
                .fixedSize()
            Text(moment.text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(weekdayName(moment.day)): \(moment.text)")
        .accessibilityIdentifier("competition.leadLine.moment.\(index + 1)")
    }

    private var chart: some View {
        GeometryReader { proxy in
            let plot = CGRect(
                x: 0, y: 7,
                width: proxy.size.width - endLabelWidth,
                height: proxy.size.height - 14
            )
            let high = line.margins.max() ?? 0, low = line.margins.min() ?? 0
            let collapses = sideLabels == nil
            let top = collapses && high <= 0 && low < 0 ? Self.unusedScale : max(high, Self.minimumScale)
            let bottom = collapses && low >= 0 ? Self.unusedScale : max(-low, Self.minimumScale)
            let x: (Double) -> CGFloat = { day in
                plot.minX + plot.width * CGFloat(day / Double(max(days.count, 1)))
            }
            let y: (Double) -> CGFloat = { margin in
                plot.minY + plot.height * CGFloat((top - margin) / (top + bottom))
            }
            let axis = y(0)
            let end = CGPoint(x: x(Double(lastDay)), y: y(last))
            let path = Path { path in
                path.addLines(line.margins.indices.map { CGPoint(x: x(Double($0)), y: y(line.margins[$0])) })
            }
            let drawn = path.trim(from: 0, to: isDrawn ? 1 : 0)

            ZStack(alignment: .topLeading) {
                Path { $0.addLines([CGPoint(x: 0, y: axis), CGPoint(x: end.x, y: axis)]) }
                    .stroke(Theme.outline, lineWidth: 1.5)
                Path { $0.addLines([CGPoint(x: end.x, y: axis), CGPoint(x: x(Double(days.count)), y: axis)]) }
                    .stroke(Theme.outline, style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                Group {
                    if low >= 0 || high > 0 {
                        drawn
                            .stroke(Theme.youFill, style: lineStyle)
                            .clipShape(Rectangle().path(in: CGRect(x: -8, y: -8, width: proxy.size.width + 16, height: axis + 8)))
                    }
                    if low < 0 {
                        drawn
                            .stroke(Theme.ink, style: lineStyle)
                            .clipShape(Rectangle().path(in: CGRect(x: -8, y: axis, width: proxy.size.width + 16, height: proxy.size.height)))
                    }
                }
                .moving(Motion.grow, value: isDrawn)
                ForEach(line.changes.indices, id: \.self) { index in
                    let change = line.changes[index]
                    SlantedBar()
                        .fill(Theme.ink)
                        .frame(width: 3, height: 26)
                        .scaleEffect(y: isDrawn ? 1 : 0)
                        .moving(arrival(change), value: isDrawn)
                        .position(x: x(change), y: axis)
                }
                Circle()
                    .fill(last > 0 ? Theme.youFill : last < 0 ? Theme.ink : Theme.outline)
                    .stroke(Theme.ground, lineWidth: 2)
                    .frame(width: 12, height: 12)
                    .scaleEffect(isDrawn ? 1 : 0)
                    .moving(arrival(Double(lastDay)), value: isDrawn)
                    .position(end)
                ForEach(moments.indices, id: \.self) { index in
                    let moment = moments[index]
                    let point = CGPoint(x: x(Double(moment.index)), y: y(line.margins[moment.index]))
                    let markerY: CGFloat = competitionLeadMomentY(
                        at: point,
                        axis: axis,
                        changes: line.changes.map { x($0) },
                        height: proxy.size.height
                    )
                    momentMarker(index, moment, at: CGPoint(x: point.x, y: markerY))
                }
                Text(competitionSignedMarginText(userPoints: last, opponentPoints: 0))
                    .font(.footnote.weight(.bold).width(.condensed).monospacedDigit())
                    .foregroundStyle(last > 0 ? Theme.you : last < 0 ? Theme.ink : Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: endLabelWidth - 10, alignment: .leading)
                    .opacity(isDrawn ? 1 : 0)
                    .animation(Motion.late, value: isDrawn)
                    .position(
                        x: end.x + (moments.contains { $0.index == lastDay } ? 16 : 10) + (endLabelWidth - 10) / 2,
                        y: min(max(end.y, endLabelHalfHeight), proxy.size.height - endLabelHalfHeight)
                    )
            }
        }
    }

    private func momentMarker(_ index: Int, _ moment: CompetitionLeadMoment, at point: CGPoint) -> some View {
        CompetitionLeadMomentBadge(number: index + 1, isYours: moment.isYours)
            .scaleEffect(isDrawn ? 1 : 0)
            .moving(arrival(Double(moment.index)), value: isDrawn)
            .position(point)
    }

    private func sideLabel(_ text: String, _ color: Color) -> some View {
        Text(text)
            .textCase(.uppercase)
            .themeLabel()
            .foregroundStyle(color)
            .lineLimit(1)
            .accessibilityHidden(true)
    }

    private var lineStyle: StrokeStyle {
        StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
    }

    private func arrival(_ day: Double) -> Animation {
        Motion.grow(Int(day.rounded()), of: lastDay + 1)
    }

    private var weekdays: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.ordinal) { day in
                Text(weekdayText(day.day))
                    .textCase(.uppercase)
                    .font(.caption2.weight(.bold).width(.condensed))
                    .tracking(1)
                    .foregroundStyle(day.ordinal == currentDayOrdinal ? Theme.ink : Theme.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.trailing, endLabelWidth)
        .accessibilityHidden(true)
    }

    private var changedText: String {
        line.changes.count == 1 ? "CHANGED ONCE" : "CHANGED \(line.changes.count) TIMES"
    }

    private var accessibilityText: String {
        let points = competitionPointsText(abs(last))
        let standing = last > 0
            ? "you led by \(points)"
            : last < 0 ? "\(opponentName) led by \(points)" : "it was all square"
        let changes = switch line.changes.count {
        case 0: "The lead never changed hands."
        case 1: "The lead changed hands once."
        default: "The lead changed hands \(line.changes.count) times."
        }
        return "The lead after each day. \(changes) After Day \(lastDay), \(standing)."
    }
}

private struct CompetitionLeadMomentBadge: View {
    let number: Int
    let isYours: Bool

    var body: some View {
        Text("\(number)")
            .font(.caption.weight(.heavy).monospacedDigit())
            .dynamicTypeSize(...DynamicTypeSize.large)
            .foregroundStyle(isYours ? Theme.ink : Theme.ground)
            .frame(width: 22, height: 22)
            .background(isYours ? Theme.youFill : Theme.ink, in: Circle())
            .overlay { Circle().stroke(Theme.ground, lineWidth: 2) }
            .accessibilityHidden(true)
    }
}

func competitionStandTitle(_ days: [LocalCompetitionDayPresentation]) -> String {
    days.contains { $0.ownerAcceptedSnapshot?.standMode == .rollHours } ? "ROLL" : "STAND"
}

private struct HeadToHeadDayRow: View {
    let day: LocalCompetitionDayPresentation
    let isToday: Bool
    let showsDates: Bool
    let isGrown: Bool
    let now: Date
    let opponentName: String

    @ScaledMetric(relativeTo: .subheadline) private var numberWidth: CGFloat = 32

    var body: some View {
        HStack(spacing: 10) {
            DayLabel(day: day, isToday: isToday, showsDates: showsDates, now: now)
            if ownerState == .future, !isToday {
                word("Upcoming", color: Theme.faint)
            } else {
                VStack(spacing: 3) {
                    line(chartCellText(ownerState), points: day.ownerAcceptedPoints, color: ownerColor) {
                        ownerTrack
                            .moving(Motion.grow(day.ordinal - 1, of: 7), value: isGrown)
                    }
                    line(opponentText, points: day.opponentRevealedPoints, color: opponentColor) {
                        DayTrack(
                            segments: day.opponentRevealedPoints.map { [(color: Theme.ink, points: $0)] } ?? [],
                            maximum: day.dailyMaximum
                        )
                    }
                }
            }
        }
        .frame(minHeight: showsDates ? 38 : 30)
    }

    @ViewBuilder
    private var ownerTrack: some View {
        switch ownerState {
        case let .missingWithScore(points), let .unavailableWithScore(points):
            DayTrack(segments: [(color: Theme.you, points: points)], isDashed: true, isGrown: isGrown, maximum: day.dailyMaximum)
        default:
            DayTrack(segments: ringSegments(day), isGrown: isGrown, maximum: day.dailyMaximum)
        }
    }

    private var ownerState: CompetitionChartState {
        competitionOwnerChartState(day)
    }

    private var opponentText: String {
        day.opponentRevealedPoints.map { competitionPointsText($0) }
            ?? (day.opponentReportedNoData
                ? "No data from \(opponentName)" : "\(opponentName) not synced")
    }

    private func line<Track: View>(
        _ text: String,
        points: Double?,
        color: Color,
        @ViewBuilder track: () -> Track
    ) -> some View {
        let isNumber = text.first?.isNumber == true
        return HStack(spacing: 7) {
            if isNumber {
                track()
            } else {
                word(text, color: Theme.secondary)
            }
            Text(isNumber ? text : "")
                .font(.subheadline.weight(.bold).width(.condensed).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .scoreRoll(points, id: isNumber)
                .frame(width: numberWidth, alignment: .trailing)
        }
        .animation(Motion.fade, value: isNumber)
    }

    private func word(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

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
                .fixedSize(horizontal: false, vertical: true)
            Text(competitionDayText(day.day, now: now))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.secondary)
            if ownerState != .future || isToday {
                score("You", chartCellText(ownerState), Theme.you)
                score(opponentName, competitionOpponentCellText(day), Theme.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .themePanel(cornerRadius: 14)
    }

    private var ownerState: CompetitionChartState {
        competitionOwnerChartState(day)
    }

    private func score(_ name: String, _ value: String, _ color: Color) -> some View {
        let isNumber = value.first?.isNumber == true
        return VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
            Text(value)
                .font(
                    isNumber
                        ? .title2.weight(.heavy).width(.condensed).monospacedDigit()
                        : .headline
                )
                .foregroundStyle(isNumber ? color : Theme.secondary)
        }
    }
}

private struct DayLabel: View {
    let day: LocalCompetitionDayPresentation
    let isToday: Bool
    let showsDates: Bool
    let now: Date

    @ScaledMetric(relativeTo: .footnote) private var width: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(isToday ? "Today" : weekdayText(day.day))
                .textCase(.uppercase)
                .themeLabel(tracking: 1.0)
                .foregroundStyle(isToday ? Theme.ink : Theme.secondary)
            Text(showsDates ? competitionDayText(day.day, weekday: false, now: now) : "Day \(day.ordinal)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(width: width, alignment: .leading)
    }
}

private struct DayTrack: View {
    let segments: [(color: Color, points: Double)]
    var isDashed = false
    var isGrown = true
    var maximum = ActivityScore.maximumDailyPoints

    var body: some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / maximum
            let growth: CGFloat = isGrown ? 1 : 0
            HStack(spacing: 1.5) {
                ForEach(segments.indices, id: \.self) { index in
                    Group {
                        if isDashed {
                            SlantedBar()
                                .stroke(Theme.you, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        } else {
                            SlantedBar().fill(segments[index].color)
                        }
                    }
                    .frame(width: max(2, segments[index].points * unit) * growth)
                }
                .transition(Motion.appear)
                Spacer(minLength: 0)
            }
            .moving(Motion.settle, value: segments.map(\.points))
        }
        .frame(height: 10)
        .background { SlantedBar().fill(Theme.track) }
    }
}

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

func ringSegments(
    _ day: LocalCompetitionDayPresentation
) -> [(color: Color, points: Double)] {
    guard case let .score(points) = competitionOwnerChartState(day) else {
        return []
    }
    let metrics = day.metrics.isEmpty ? .threeRings : day.metrics
    let sleep = day.ownerSleepPoints ?? 0
    let night: [(color: Color, points: Double)] = sleep > 0 ? [(Theme.sleep, sleep)] : []
    guard metrics.includesActivityRings else { return night }
    let rings = max(0, points - sleep)
    guard let snapshot = day.ownerAcceptedSnapshot else {
        return (rings > 0 ? [(Theme.youFill, rings)] : []) + night
    }
    let shares = competitionRingShares(
        snapshot, perRingCap: day.scoringPolicy.perRingCap
    )
    let allColors = [Theme.move, Theme.exercise, Theme.stand]
    let activeIndices = metrics.activeActivityIndices
    let activeShares = activeIndices.map { shares[$0] }
    let total = activeShares.reduce(0, +)
    guard total > 0 else { return (rings > 0 ? [(Theme.youFill, rings)] : []) + night }
    return activeIndices.map { index in
        (allColors[index], rings * shares[index] / total)
    } + night
}

func competitionDayOutcome(
    _ day: LocalCompetitionDayPresentation,
    currentDayOrdinal: Int?
) -> CompetitionDayOutcome {
    competitionDayOutcome(
        ordinal: day.ordinal,
        currentDayOrdinal: currentDayOrdinal,
        hasOccurred: day.ownerLatestAvailability != .notYetOccurred,
        ownerPoints: day.ownerAcceptedPoints,
        opponentPoints: day.opponentRevealedPoints
    )
}

func competitionDayListText(_ ordinals: Set<Int>, locale: Locale = .current) -> String? {
    let sorted = ordinals.sorted()
    switch sorted.count {
    case 1: return "Day \(sorted[0])"
    case 2, 3:
        return "Days " + sorted.map(String.init).formatted(.list(type: .and).locale(locale))
    default: return nil
    }
}

private func chartCellText(_ state: CompetitionChartState) -> String {
    switch state {
    case let .score(points), let .missingWithScore(points),
         let .unavailableWithScore(points):
        competitionPointsText(points)
    case .missing, .unavailable: "No data"
    case .unscored: "Not scored"
    case .future: "Upcoming"
    }
}

private func competitionOpponentCellText(_ day: LocalCompetitionDayPresentation) -> String {
    day.opponentRevealedPoints.map { competitionPointsText($0) }
        ?? (day.opponentReportedNoData ? "No data" : "Not synced")
}

private func competitionDayDate(_ day: CompetitionDay) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = competitionDayTimeZone
    return calendar.date(
        from: DateComponents(year: day.year, month: day.month, day: day.day)
    )
}

private let competitionDayTimeZone = TimeZone(identifier: "UTC")!

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

func weekdayName(_ day: CompetitionDay, locale: Locale = .current) -> String {
    guard let date = competitionDayDate(day) else {
        return "\(day.month)/\(day.day)"
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = competitionDayTimeZone
    calendar.locale = locale
    let index = calendar.component(.weekday, from: date) - 1
    return calendar.weekdaySymbols[index]
}

func competitionDayText(
    _ day: CompetitionDay,
    weekday: Bool = true,
    now: Date = Date.now,
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

func competitionWeekText(
    _ first: CompetitionDay,
    _ last: CompetitionDay,
    includesYear: Bool? = nil,
    now: Date = Date.now,
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
        includesYear: includesYear ?? (last.year != competitionYear(of: now, timeZone: timeZone)),
        locale: locale,
        timeZone: competitionDayTimeZone
    )
}
