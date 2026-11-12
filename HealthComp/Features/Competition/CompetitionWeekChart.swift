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
    /// False holds your bars at the slash; turning true grows them, row by row.
    var isGrown = true
    /// Makes each day that has started open its breakdown.
    var selectDay: ((LocalCompetitionDayPresentation) -> Void)?
    /// A clap beside each of their finished days, while day reactions are open.
    var clap: CompetitionDayClap?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 12 : 6) {
            ForEach(days, id: \.ordinal) { day in
                // Beside the row, not in it, so the row's tap still opens the day.
                HStack(spacing: 6) {
                    dayRow(day)
                    if let clap {
                        clapSlot(day, clap)
                    }
                }
                .background {
                    if day.ordinal == currentDayOrdinal, !dynamicTypeSize.isAccessibilitySize {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
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

    /// Empty on days you can't clap, so the columns stay aligned.
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
                isGrown: isGrown,
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

/// One match's claps from the Week list, through the reactions call: one per
/// day, as in the day drawer.
struct CompetitionDayClap {
    /// What you sent to a day, pending included; nil when nothing.
    let sent: (Int) -> CompetitionReactionKind?
    let isPending: (Int) -> Bool
    let send: (Int) -> Void
}

/// Their finished days with a score: today waits until it ends.
func competitionDayIsClappable(
    _ day: LocalCompetitionDayPresentation,
    currentDayOrdinal: Int?
) -> Bool {
    day.ownerLatestAvailability != .notYetOccurred
        && day.ordinal < currentDayOrdinal ?? .max
        && day.opponentRevealedPoints != nil
}

/// "Clap for Sam’s Tuesday"
func competitionClapLabel(
    opponentName: String,
    day: CompetitionDay,
    locale: Locale = .current
) -> String {
    "Clap for \(opponentName)’s \(weekdayName(day, locale: locale))"
}

/// 👏 until you've sent something, then what you sent. Once sent, a tap opens
/// the day, where all four reactions stay.
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
        .accessibilityLabel(sent.map { "You sent \($0.spokenName)" } ?? label)
        .accessibilityHint(isSent ? "Opens this day’s breakdown" : "")
    }
}

/// The week at a glance: one bar per day in the color of whoever won it,
/// amber for you, ink for them and grey for a tie. A day with no data is
/// striped, an upcoming day is an outline, and today stays dashed.
struct CompetitionWeekStrip: View {
    let days: [LocalCompetitionDayPresentation]
    let currentDayOrdinal: Int?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.launchStage) private var launchStage

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.element.ordinal) { index, day in
                VStack(spacing: 6) {
                    // At launch the bars grow left to right behind the scores.
                    bar(day)
                        .frame(height: 10)
                        .scaleEffect(x: launchStage == .waiting ? 0 : 1, anchor: .leading)
                        .moving(Motion.grow(index, of: days.count), value: launchStage)
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
        // Only a real change: nothing draws in on appear.
        .animation(Motion.fade, value: days.map(outcome))
        .animation(Motion.fade, value: days.map(leaderColor))
        .accessibilityHidden(true)
    }

    private func bar(_ day: LocalCompetitionDayPresentation) -> some View {
        CompetitionDayBar(outcome: outcome(day), todayColor: leaderColor(day))
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

/// Your bar (Move, Exercise and Stand or Roll when the days carry a ring
/// split), the other person's single bar, and the stripe for no data.
/// Accessibility sizes show named rows instead of bars, so the legend steps
/// aside.
struct CompetitionRingLegend: View {
    let days: [LocalCompetitionDayPresentation]
    let opponentName: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if !dynamicTypeSize.isAccessibilitySize {
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
            // A one-line legend is otherwise too short for VoiceOver's target.
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
        if showsNoData {
            HStack(spacing: 5) {
                HatchBar().frame(width: 10, height: 10)
                Text("NO DATA").font(.themeLabel).tracking(1.1)
            }
        }
    }

    private var showsRings: Bool {
        days.contains { ringSegments($0).count == 3 }
    }

    private var standTitle: String {
        competitionStandTitle(days)
    }

    private var showsNoData: Bool {
        days.contains {
            $0.ownerLatestAvailability != .notYetOccurred
                && ($0.ownerAcceptedPoints == nil || $0.opponentRevealedPoints == nil)
        }
    }

    private var accessibilityText: String {
        [
            showsRings
                ? "Move, Exercise and \(standTitle.capitalized) are your rings."
                : "The left bar is yours.",
            "The single bar is \(opponentName).",
            showsNoData ? "Striped bars mean no data." : nil,
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
            Text(title).font(.themeLabel).tracking(1.1)
        }
    }
}

/// The running margin after each day that has ended, from 0 before Day 1,
/// in whole points as the scoreboard shows them. A side with no score counts
/// 0 that day, as the totals do. Today waits until it ends.
struct CompetitionLeadLine: Equatable {
    /// `margins[k]` is your margin after Day k; `margins[0]` is 0.
    let margins: [Double]
    /// Where the lead changed hands, in days from the start: 2.4 is part way
    /// along Day 3. Through a tie it is the day of the tie.
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

/// A numbered moment on the lead line, at the margin after Day `index`.
struct CompetitionLeadMoment: Equatable {
    let index: Int
    let day: CompetitionDay
    let isYours: Bool
    let text: String
}

/// Two at most, in order: the biggest lead they held, then your best day.
/// Your best day steps aside when it is the same day, so markers never stack.
func competitionLeadMoments(
    _ line: CompetitionLeadLine,
    days: [LocalCompetitionDayPresentation],
    opponentName: String
) -> [CompetitionLeadMoment] {
    let ended = Array(days.prefix(line.margins.count - 1))
    var moments: [CompetitionLeadMoment] = []
    // The first of equal minimums and maximums: the earliest day.
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

/// A marker's height: on the line, unless it would cover a lead-change slash
/// (26 pt tall on the axis). Then it moves clear on its own side of the axis,
/// or the other side when there's no room.
func competitionLeadMomentY(
    at point: CGPoint,
    axis: CGFloat,
    changes: [CGFloat],
    height: CGFloat,
    radius: CGFloat = 12
) -> CGFloat {
    // The slash's half extents, its 12 degree lean included, plus the radius.
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

/// The lead after each day as one line: amber above the axis while you lead,
/// ink below while they do, a slash at every change. False `isDrawn` holds it
/// at the start; turning true draws it out once.
struct CompetitionLeadLineView: View {
    let line: CompetitionLeadLine
    let days: [LocalCompetitionDayPresentation]
    let currentDayOrdinal: Int?
    let opponentName: String
    var isDrawn = true
    /// The sticker's "You ahead" above the line and "Sam ahead" under it, in
    /// place of the title.
    var sideLabels: (you: String, them: String)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A quiet week still gets room, so 10 points never reads as a rout.
    private static let minimumScale = 50.0
    private static let unusedScale = 10.0
    /// The end label grows with its text, and stays inside the chart's
    /// frame when the line ends at the top or bottom of the scale.
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
                            .font(.themeLabel)
                            .tracking(1.2)
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
            if let throughText {
                Text(throughText)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityHidden(true)
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

    /// The Week page's markers; the sticker keeps the bare line.
    private var moments: [CompetitionLeadMoment] {
        guard sideLabels == nil else { return [] }
        return competitionLeadMoments(line, days: days, opponentName: opponentName)
    }

    private func momentRow(_ index: Int, _ moment: CompetitionLeadMoment) -> some View {
        HStack(spacing: 10) {
            CompetitionLeadMomentBadge(number: index + 1, isYours: moment.isYours)
            Text(weekdayText(moment.day))
                .textCase(.uppercase)
                .font(.themeLabel)
                .tracking(1.0)
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
                    .overlay(Circle().stroke(Theme.ground, lineWidth: 2))
                    .frame(width: 12, height: 12)
                    .scaleEffect(isDrawn ? 1 : 0)
                    .moving(arrival(Double(lastDay)), value: isDrawn)
                    .position(end)
                // Over the line, moved clear of the slashes (competitionLeadMomentY).
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

    /// Lands as the line's head reaches its day, like the slashes. Reduce
    /// Motion: there from the start.
    private func momentMarker(_ index: Int, _ moment: CompetitionLeadMoment, at point: CGPoint) -> some View {
        CompetitionLeadMomentBadge(number: index + 1, isYours: moment.isYours)
            .scaleEffect(isDrawn ? 1 : 0)
            .moving(arrival(Double(moment.index)), value: isDrawn)
            .position(point)
    }

    private func sideLabel(_ text: String, _ color: Color) -> some View {
        Text(text)
            .textCase(.uppercase)
            .font(.themeLabel)
            .tracking(1.2)
            .foregroundStyle(color)
            .lineLimit(1)
            .accessibilityHidden(true)
    }

    private var lineStyle: StrokeStyle {
        StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
    }

    /// Lands as the line's head passes, on the mark's stagger envelope.
    private func arrival(_ day: Double) -> Animation {
        Motion.grow(Int(day.rounded()), of: lastDay + 1)
    }

    // One label per day under its stretch of the line.
    private var weekdays: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.ordinal) { day in
                Text(day.ordinal == currentDayOrdinal ? "TODAY" : weekdayText(day.day))
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

    /// The line stops at the last finished day; the score above includes today.
    private var throughText: String? {
        guard sideLabels == nil,
              let currentDayOrdinal,
              lastDay > 0,
              lastDay == currentDayOrdinal - 1,
              let day = days.first(where: { $0.ordinal == lastDay })
        else { return nil }
        return "Through \(weekdayText(day.day)), before today’s points."
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

/// A moment's number in your amber or their ink, on the line and in its legend.
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
            .overlay(Circle().stroke(Theme.ground, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

/// "ROLL" when any day's accepted snapshot counts Roll hours, else "STAND".
func competitionStandTitle(_ days: [LocalCompetitionDayPresentation]) -> String {
    days.contains { $0.ownerAcceptedSnapshot?.standMode == .rollHours } ? "ROLL" : "STAND"
}

private struct HeadToHeadDayRow: View {
    let day: LocalCompetitionDayPresentation
    let isToday: Bool
    let showsDates: Bool
    let isGrown: Bool
    let now: Date

    var body: some View {
        if ownerState == .future, !isToday {
            HStack(spacing: 6) {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                DayLabel(day: day, isToday: false, showsDates: showsDates, now: now)
                Text("Upcoming")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: showsDates ? 38 : 30)
        } else {
            scoredRow
        }
    }

    private var scoredRow: some View {
        HStack(spacing: 6) {
            cell(
                chartCellText(ownerState),
                points: day.ownerAcceptedPoints,
                color: ownerColor,
                alignment: .leading
            )
            OwnerDayBar(state: ownerState, segments: ringSegments(day), isGrown: isGrown)
                .moving(Motion.grow(day.ordinal - 1, of: 7), value: isGrown)
            DayLabel(day: day, isToday: isToday, showsDates: showsDates, now: now)
            OpponentDayBar(state: opponentState, started: started)
            cell(
                opponentText,
                points: day.opponentRevealedPoints,
                color: opponentColor,
                alignment: .trailing
            )
        }
        .frame(minHeight: showsDates ? 38 : 30)
    }

    private var ownerState: CompetitionChartState {
        competitionOwnerChartState(day)
    }

    private var opponentState: CompetitionChartState {
        day.opponentRevealedPoints.map(CompetitionChartState.score) ?? .future
    }

    private var started: Bool {
        day.ownerLatestAvailability != .notYetOccurred
    }

    private var opponentText: String {
        competitionOpponentCellText(day)
    }

    // Numbers keep the score font; words step back.
    private func cell(
        _ text: String,
        points: Double?,
        color: Color,
        alignment: Alignment
    ) -> some View {
        let isNumber = text.first?.isNumber == true
        // Words never roll: a word and a number are different ids.
        return ZStack {
            Text(text)
                .font(
                    isNumber
                        ? .headline.weight(.bold).width(.condensed).monospacedDigit()
                        : .footnote.weight(.semibold)
                )
                .foregroundStyle(isNumber ? color : Theme.secondary)
                .fixedSize()
                .scoreRoll(points, id: isNumber)
        }
        .animation(Motion.fade, value: isNumber)
        .frame(minWidth: 36, alignment: alignment)
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
                .fixedSize(horizontal: false, vertical: true)
            Text(competitionDayText(day.day, now: now))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.secondary)
            if ownerState == .future, !isToday {
                Text("Upcoming")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.tertiary)
            } else {
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

    @ScaledMetric(relativeTo: .footnote) private var width: CGFloat = 96

    var body: some View {
        VStack(spacing: 0) {
            Text(isToday ? "Day \(day.ordinal) · Today" : "Day \(day.ordinal) · \(weekdayText(day.day))")
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
        .frame(width: width)
    }
}

private struct OwnerDayBar: View {
    let state: CompetitionChartState
    let segments: [(color: Color, points: Double)]
    let isGrown: Bool

    var body: some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / ActivityScore.maximumDailyPoints
            // Width, not scale, so the 12 degree edge holds.
            let growth: CGFloat = isGrown ? 1 : 0
            HStack(spacing: 1.5) {
                Spacer(minLength: 0)
                Group {
                    switch state {
                    case .score:
                        ForEach(segments.indices.reversed(), id: \.self) { index in
                            SlantedBar()
                                .fill(segments[index].color)
                                .frame(width: max(2, segments[index].points * unit) * growth)
                        }
                    case let .missingWithScore(points), let .unavailableWithScore(points):
                        SlantedBar()
                            .stroke(Theme.you, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                            .frame(width: max(4, points * unit) * growth)
                    case .future:
                        Rectangle().fill(Theme.track).frame(height: 2)
                    case .missing, .unavailable, .unscored:
                        HatchBar().frame(width: 24, height: 10)
                    }
                }
                .transition(Motion.appear)
            }
            .moving(Motion.settle, value: segments.map(\.points))
            .frame(height: proxy.size.height)
        }
        .frame(height: 20)
    }
}

private struct OpponentDayBar: View {
    let state: CompetitionChartState
    let started: Bool

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Group {
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
                    } else if started {
                        HatchBar().frame(width: 24, height: 10)
                    } else {
                        Rectangle().fill(Theme.track).frame(height: 2)
                    }
                }
                .transition(Motion.appear)
                Spacer(minLength: 0)
            }
            .moving(Motion.settle, value: state)
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

/// A day is no data when either score is missing, or when both read 0.
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

/// "Day 7", "Days 5 and 7" or "Days 3, 5, and 7"; nil for none or four or more.
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

/// Their side: the number, "No data" when they sent the day without a
/// score, otherwise "Not synced".
private func competitionOpponentCellText(_ day: LocalCompetitionDayPresentation) -> String {
    day.opponentRevealedPoints.map { competitionPointsText($0) }
        ?? (day.opponentReportedNoData ? "No data" : "Not synced")
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

/// Full weekday for a competition calendar day, e.g. "Wednesday".
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
    includesYear: Bool? = nil,
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
        includesYear: includesYear ?? (last.year != competitionYear(of: now, timeZone: timeZone)),
        locale: locale,
        timeZone: competitionDayTimeZone
    )
}
