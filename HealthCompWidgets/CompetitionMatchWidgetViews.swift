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
            // The Lock Screen drops an accessory widget's container
            // background, so the disc goes in the body.
            ZStack {
                AccessoryWidgetBackground()
                content
            }
            .containerBackground(for: .widget) { Color.clear }
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
    /// Shrinks a little before truncating, so "FINAL SCORE PENDING" and
    /// "DAY 1 IS WEDNESDAY" fit the small widget.
    var shrinks = true

    var body: some View {
        Text(text)
            .font(.themeLabel)
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
            .minimumScaleFactor(shrinks ? 0.5 : 1)
            .allowsTightening(true)
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
                Spacer(minLength: 0)
                Text(match.name)
                    .font(.title3.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .privacySensitive()
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
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ label: String, _ number: String, _ color: Color, isYou: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Always a few letters of the name: the number shrinks first.
            Text(label)
                .font(.themeLabel)
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(minWidth: 64, alignment: .leading)
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
                .layoutPriority(1)  // fills what the name leaves, shrinking to fit
        }
    }
}

// MARK: Medium

private struct MediumView: View {
    let match: CompetitionWidgetSnapshot.Match
    let date: Date

    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = 40

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Spacer(minLength: 0)
            if match.state(at: date) == .scheduled {
                HStack(spacing: 12) {
                    caption("YOU", isYou: true)
                    strip
                    caption(match.name.uppercased(), isYou: false)
                }
                Spacer(minLength: 0)
            } else {
                // Large text drops the Today lines. The strip adds no height:
                // it goes only when the numbers leave it no room.
                ViewThatFits(in: .vertical) {
                    scores(showsToday: true)
                    scores(showsToday: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "SAM · DAY 5 OF 7" and the Updated time: one row, or two at large
    /// text sizes so neither truncates to nothing.
    @ViewBuilder
    private var header: some View {
        // A long name truncates; the status after it stays whole.
        let title = HStack(alignment: .firstTextBaseline, spacing: 0) {
            StatusLabel(text: match.name, namesSomeone: true, shrinks: false)
            StatusLabel(text: " · \(match.mediumStatus(at: date))", shrinks: false)
                .layoutPriority(1)
        }
        let updated = match.updatedLine(at: date).map { line in
            Text(line)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        if typeSize >= .xLarge {
            VStack(alignment: .leading, spacing: 2) {
                title
                updated
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title
                Spacer(minLength: 0)
                updated.layoutPriority(1)
            }
        }
    }

    private func scores(showsToday: Bool) -> some View {
        let today = match.todayLines(at: date)
        let isFinal = if case .final = match.state(at: date) { true } else { false }
        return HStack(alignment: .bottom, spacing: 12) {
            side("YOU", match.userPointsText(), showsToday ? today.user : nil, Theme.you, isYou: true)
            VStack(spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    strip.frame(minWidth: 60, idealWidth: 60, maxWidth: .infinity)
                    Color.clear.frame(width: 0, height: 0)
                }
                if isFinal {
                    Text(match.leadLine(at: date) ?? "Tied")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
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
            self.caption(caption, isYou: isYou)
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

    /// Capped near the number's width, so a long name truncates instead of
    /// pushing out the strip and the Today lines.
    private func caption(_ text: String, isYou: Bool) -> some View {
        Text(text)
            .font(.themeLabel)
            .tracking(1.2)
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
            .frame(maxWidth: scoreSize * 2.5, alignment: isYou ? .leading : .trailing)
            .privacySensitive(!isYou)
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
                        .minimumScaleFactor(0.8)
                        // Without this the stack held "Open the app to see
                        // your matches." to one truncated line.
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .privacySensitive(text.namesSomeone)
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text(text.title)
                    .font(.title3.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.ink)
                    .minimumScaleFactor(0.6)  // "HealthComp" can't wrap
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
