import SwiftUI
import WidgetKit

/// One widget, four sizes. All copy comes from `CompetitionWidgetSnapshot`;
/// names, numbers and name-bearing status redact on a locked phone.
struct CompetitionMatchWidgetView: View {
    let entry: CompetitionWidgetEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons

    var body: some View {
        let redacted = redactionReasons.contains(.privacy)
        Group {
            switch CompetitionWidgetSnapshot.content(
                entry.snapshot, personID: entry.personID, at: entry.date
            ) {
            case let .match(match):
                matchView(match)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(match.accessibilityLabel(
                        at: entry.date,
                        redacted: redacted,
                        circular: family == .accessoryCircular
                    ))
                    .accessibilityIdentifier("widget.match")
                    .widgetURL(match.url)
            case let .empty(text):
                EmptyStateView(text: text)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        redacted && text.namesSomeone
                            ? text.redactedAccessibilityLabel : text.accessibilityLabel
                    )
                    .accessibilityIdentifier("widget.empty")
            }
        }
        .modifier(WidgetBackground(family: family))
    }

    @ViewBuilder
    private func matchView(_ match: CompetitionWidgetSnapshot.Match) -> some View {
        switch family {
        case .systemMedium: MediumView(match: match, date: entry.date)
        case .accessoryRectangular: RectangularView(match: match, date: entry.date)
        case .accessoryCircular: CircularView(match: match, date: entry.date)
        default: SmallView(match: match, date: entry.date)
        }
    }
}

private struct WidgetBackground: ViewModifier {
    let family: WidgetFamily

    @ViewBuilder
    func body(content: Content) -> some View {
        switch family {
        case .accessoryCircular:
            content.containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryRectangular:
            content.containerBackground(for: .widget) { Color.clear }
        default:
            content.containerBackground(Theme.ground, for: .widget)
        }
    }
}

/// The uppercase status label: "DAY 5 OF 7".
private struct StatusLabel: View {
    let text: String
    var namesSomeone = false

    var body: some View {
        Text(text)
            .font(.themeLabel)
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
            .privacySensitive(namesSomeone)
    }
}

private extension CompetitionWidgetSnapshot.Match {
    /// "Sam won" names someone; the other statuses don't.
    func statusNamesSomeone(at date: Date) -> Bool {
        state(at: date) == .final(.loss)
    }
}

// MARK: Small

private struct SmallView: View {
    let match: CompetitionWidgetSnapshot.Match
    let date: Date

    @ScaledMetric(relativeTo: .title) private var scoreSize: CGFloat = 28

    var body: some View {
        if match.state(at: date) == .scheduled {
            VStack(alignment: .leading, spacing: 6) {
                StatusLabel(text: match.status(at: date))
                Text(match.name)
                    .font(.title3.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .privacySensitive()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // The lead line drops first; the Updated line stays.
            ViewThatFits(in: .vertical) {
                layout(showsLead: true)
                layout(showsLead: false)
            }
        }
    }

    private func layout(showsLead: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            StatusLabel(text: match.status(at: date), namesSomeone: match.statusNamesSomeone(at: date))
            Spacer(minLength: 4)
            row("You", match.userPointsText(), Theme.you, isYou: true)
            row(match.name, match.opponentPointsText(), Theme.ink, isYou: false)
            if showsLead, let lead = match.leadLine(at: date) {
                Text(lead)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .privacySensitive()
            }
            if let updated = match.updatedLine(at: date) {
                Text(updated)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ label: String, _ number: String, _ color: Color, isYou: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.themeLabel)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(color)
                .lineLimit(1)
                .privacySensitive(!isYou)
            Spacer(minLength: 0)
            Text(number)
                .font(.score(size: scoreSize))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(color)
                .widgetAccentable(isYou)
                .privacySensitive()
        }
    }
}

// MARK: Medium

private struct MediumView: View {
    let match: CompetitionWidgetSnapshot.Match
    let date: Date

    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusLabel(text: match.mediumHeader(at: date), namesSomeone: true)
                Spacer(minLength: 0)
                if let updated = match.updatedLine(at: date) {
                    Text(updated)
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if match.state(at: date) == .scheduled {
                strip
            } else {
                // At large sizes the strip goes first, then the Today lines.
                ViewThatFits {
                    scores(showsStrip: true, showsToday: true)
                    scores(showsStrip: false, showsToday: true)
                    scores(showsStrip: false, showsToday: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scores(showsStrip: Bool, showsToday: Bool) -> some View {
        let today = match.todayLines(at: date)
        let isFinal = if case .final = match.state(at: date) { true } else { false }
        return HStack(alignment: .bottom, spacing: 12) {
            side("YOU", match.userPointsText(), showsToday ? today.user : nil, Theme.you, isYou: true)
            VStack(spacing: 6) {
                if showsStrip { strip }
                if isFinal {
                    Text(match.leadLine(at: date) ?? "Tied")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .privacySensitive()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
            side(
                match.name.uppercased(), match.opponentPointsText(),
                showsToday ? today.opponent : nil, Theme.ink, isYou: false
            )
        }
    }

    private func side(
        _ caption: String, _ number: String, _ today: String?, _ color: Color, isYou: Bool
    ) -> some View {
        VStack(alignment: isYou ? .leading : .trailing, spacing: 2) {
            Text(caption)
                .font(.themeLabel)
                .tracking(1.2)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .privacySensitive(!isYou)
            Text(number)
                .font(.score(size: scoreSize))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(color)
                .widgetAccentable(isYou)
                .privacySensitive()
            if let today {
                Text(today)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .privacySensitive()
            }
        }
    }

    private var strip: some View {
        HStack(spacing: 4) {
            ForEach(Array(match.dayOutcomes(at: date).enumerated()), id: \.offset) { _, outcome in
                CompetitionDayBar(outcome: outcome, todayColor: todayColor)
                    .frame(height: 14)
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

// MARK: Lock Screen

private struct RectangularView: View {
    let match: CompetitionWidgetSnapshot.Match
    let date: Date

    var body: some View {
        let lines = match.rectangularLines(at: date)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, choices in
                ViewThatFits(in: .horizontal) {
                    ForEach(choices, id: \.self) { Text($0).lineLimit(1) }
                }
                .font(index == 0 ? .headline : .body)
                .privacySensitive(index < 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CircularView: View {
    let match: CompetitionWidgetSnapshot.Match
    let date: Date

    var body: some View {
        let circular = match.circular(at: date)
        VStack(spacing: 0) {
            Text(circular.caption)
                .font(.caption2.weight(.bold).width(.condensed))
                .lineLimit(1)
            Text(circular.value)
                .font(.title3.weight(.heavy).width(.compressed))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .privacySensitive()
        }
        .padding(4)
    }
}

// MARK: Nothing to show

private struct EmptyStateView: View {
    let text: CompetitionWidgetEmptyText

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.compact.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(index == 0 ? .headline : .body)
                        .lineLimit(2)
                }
            }
            .privacySensitive(text.namesSomeone)
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text(text.title)
                    .font(.title3.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.ink)
                    .privacySensitive(text.namesSomeone)
                if let line = text.line {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

#Preview(as: .systemSmall) {
    CompetitionMatchWidget()
} timeline: {
    CompetitionWidgetEntry.sample(.now)
}

#Preview(as: .systemMedium) {
    CompetitionMatchWidget()
} timeline: {
    CompetitionWidgetEntry.sample(.now)
}
