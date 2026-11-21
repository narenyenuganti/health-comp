import SwiftUI
import WidgetKit

@main
struct HealthCompWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchMatchComplication()
    }
}

struct WatchMatchEntry: TimelineEntry {
    let date: Date
    let snapshot: CompetitionWidgetSnapshot?
}

struct WatchMatchProvider: TimelineProvider {
    private var sample: CompetitionWidgetSnapshot {
        .sample(now: Date.now, url: URL(string: "healthcomp://competition/00000000-0000-0000-0000-000000000005")!)
    }

    private var stored: CompetitionWidgetSnapshot? {
        .load(from: CompetitionWidgetSnapshot.fileURL())
    }

    func placeholder(in context: Context) -> WatchMatchEntry {
        WatchMatchEntry(date: Date.now, snapshot: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchMatchEntry) -> Void) {
        completion(WatchMatchEntry(date: Date.now, snapshot: context.isPreview ? sample : stored))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchMatchEntry>) -> Void) {
        let now = Date.now
        let snapshot = stored
        let stale = (snapshot?.matches ?? []).compactMap {
            $0.updatedAt?.addingTimeInterval(CompetitionWidgetSnapshot.Match.staleAfter)
        }
        let boundaries = Array(Set((snapshot?.timelineDates(after: now) ?? []) + stale.filter { $0 > now })).sorted()
        let entries = ([now] + boundaries).map { WatchMatchEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: boundaries.isEmpty ? .never : .atEnd))
    }
}

struct WatchMatchComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchMatchComplication", provider: WatchMatchProvider()) { entry in
            WatchMatchComplicationView(entry: entry)
        }
        .configurationDisplayName("Match")
        .description("The score of your match.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct WatchMatchComplicationView: View {
    let entry: WatchMatchEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons

    private var redacted: Bool { redactionReasons.contains(.privacy) }

    var body: some View {
        let content = CompetitionWidgetSnapshot.content(entry.snapshot, personID: nil, at: entry.date)
        Group {
            switch content {
            case let .match(match):
                let updated = family == .accessoryCircular && match.isStale(at: entry.date)
                    ? match.updatedLine(at: entry.date).map { " \($0)." } : nil
                matchView(match)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(match.accessibilityLabel(
                        at: entry.date, redacted: redacted, circular: family == .accessoryCircular
                    ) + (updated ?? ""))
            case let .empty(text):
                emptyView(text)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text.accessibilityLabel)
            }
        }
        .containerBackground(for: .widget) {
            widgetBackground(for: content)
        }
    }

    @ViewBuilder
    private func widgetBackground(for content: CompetitionWidgetContent) -> some View {
        if family == .accessoryRectangular, case let .match(match) = content {
            let tint: Color = if !match.isStale(at: entry.date), match.side == .you {
                Theme.youFill.opacity(0.22)
            } else {
                Color(uiColor: UIColor(hex: 0x3A3D46)).opacity(0.38)
            }
            LinearGradient(
                colors: [tint, Color(uiColor: UIColor(hex: 0x0B0B0D))],
                startPoint: .topLeading,
                endPoint: .bottom
            )
        } else {
            Color.black
        }
    }

    @ViewBuilder
    private func matchView(_ match: CompetitionWidgetSnapshot.Match) -> some View {
        let circular = match.circular(at: entry.date)
        let staleTime = match.isStale(at: entry.date)
            ? match.updatedAt.map { competitionUpdatedText($0, now: entry.date) } : nil
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(staleTime ?? circular.caption)
                        .font(.caption2.weight(.bold).width(.condensed))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    margin(circular.value, match, size: 21)
                }
                .padding(4)
            }
        case .accessoryCorner:
            margin(circular.value, match, size: 20)
                .widgetLabel {
                    Text(match.cornerLabel(at: entry.date, redacted: redacted))
                }
        case .accessoryInline:
            Text(match.inlineText(at: entry.date, redacted: redacted))
        default:
            WatchRectangularView(match: match, date: entry.date)
        }
    }

    private func margin(_ text: String, _ match: CompetitionWidgetSnapshot.Match, size: CGFloat) -> some View {
        let stale = match.isStale(at: entry.date)
        return Text(text)
            .font(.score(size: size))
            .foregroundStyle(stale ? Theme.secondary : match.side == .you ? Theme.you : Theme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .widgetAccentable(match.side == .you && !stale)
            .privacySensitive()
    }

    @ViewBuilder
    private func emptyView(_ text: CompetitionWidgetEmptyText) -> some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                BrandMark().padding(8)
            }
        case .accessoryCorner:
            BrandMark()
        case .accessoryInline:
            Text(text.compact.first ?? text.title)
        default:
            VStack(alignment: .leading, spacing: 0) {
                Text(text.title)
                    .font(.headline.width(.condensed))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let line = text.line {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WatchRectangularView: View {
    let match: CompetitionWidgetSnapshot.Match
    let date: Date

    var body: some View {
        GeometryReader { geometry in
            if match.state(at: date) == .scheduled {
                let lines = match.rectangularLines(at: date)
                VStack(alignment: .leading, spacing: 0) {
                    Text(match.name)
                        .font(.headline.width(.condensed))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .privacySensitive()
                    ViewThatFits(in: .horizontal) {
                        ForEach(lines.last ?? [], id: \.self) { Text($0).lineLimit(1) }
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                }
            } else {
                let scoreSize = min(34, max(20, geometry.size.height - 26))
                VStack(alignment: .leading, spacing: 2) {
                    header
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        number(match.userPointsText(), Theme.you)
                            .widgetAccentable()
                        Spacer(minLength: 4)
                        SlantedBar()
                            .fill(Theme.outline.opacity(0.6))
                            .frame(width: 2, height: scoreSize * 0.62)
                        Spacer(minLength: 4)
                        number(match.opponentPointsText(), Theme.ink)
                    }
                    .font(.score(size: scoreSize))
                    CompetitionMatchStrip(match: match, date: date, height: 6, spacing: 3) { _, outcome, bar in
                        bar.widgetAccentable(outcome == .won)
                    }
                }
            }
        }
    }

    private var status: String {
        if match.isStale(at: date), let updated = match.updatedLine(at: date) {
            return updated
        }
        if let lead = match.chase(at: date)?.lead {
            return "\(lead) to lead"
        }
        return match.boardStatus(at: date)
    }

    private var header: some View {
        HStack(spacing: 0) {
            label(match.group?.title ?? match.name)
                .privacySensitive(match.group == nil)
            label(" · \(status)")
                .layoutPriority(1)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold).width(.condensed))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
    }

    private func number(_ text: String, _ color: Color) -> some View {
        Text(text)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .privacySensitive()
    }
}
