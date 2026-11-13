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
        .sample(now: Date(), url: URL(string: "healthcomp://competition/00000000-0000-0000-0000-000000000005")!)
    }

    private var stored: CompetitionWidgetSnapshot? {
        .load(from: CompetitionWidgetSnapshot.fileURL())
    }

    func placeholder(in context: Context) -> WatchMatchEntry {
        WatchMatchEntry(date: Date(), snapshot: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchMatchEntry) -> Void) {
        completion(WatchMatchEntry(date: Date(), snapshot: context.isPreview ? sample : stored))
    }

    /// Now, plus each day start, end and result leaving, so the face moves on
    /// without the phone, and the moment each score goes stale, so the face
    /// says how old it is. `.atEnd` on just `[now]` would reload in a loop.
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchMatchEntry>) -> Void) {
        let now = Date()
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
                .containerBackground(Color.black, for: .widget)
        }
        .configurationDisplayName("Match")
        .description("The score of your match.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

/// All four shapes. Amber only when the margin is yours; the sign and caption
/// carry the meaning on tinted faces. Nothing animates here.
struct WatchMatchComplicationView: View {
    let entry: WatchMatchEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons

    private var redacted: Bool { redactionReasons.contains(.privacy) }

    var body: some View {
        switch CompetitionWidgetSnapshot.content(entry.snapshot, personID: nil, at: entry.date) {
        case let .match(match):
            // The circle's short label leaves out the Updated time the others read.
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

    @ViewBuilder
    private func matchView(_ match: CompetitionWidgetSnapshot.Match) -> some View {
        let circular = match.circular(at: entry.date)
        // Without the phone for an hour: the time it was last right, not "LEAD".
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

    /// Grey and never accented once stale, so an old lead doesn't read as live.
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

/// Also the Smart Stack card, which is taller than a face's slot: the numerals
/// take whatever height the header and strip leave.
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
                VStack(alignment: .leading, spacing: 2) {
                    header
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        number(match.userPointsText(), Theme.you)
                            .widgetAccentable()
                        Spacer(minLength: 8)
                        number(match.opponentPointsText(), Theme.ink)
                    }
                    .font(.score(size: min(34, geometry.size.height - 26)))
                    CompetitionMatchStrip(match: match, date: date, height: 6, spacing: 3) { _, outcome, bar in
                        bar.widgetAccentable(outcome == .won)
                    }
                }
            }
        }
    }

    /// Stale, the status gives way to "Updated 9:30 AM".
    private var status: String {
        (match.isStale(at: date) ? match.updatedLine(at: date) : nil) ?? match.boardStatus(at: date)
    }

    private var header: some View {
        HStack(spacing: 0) {
            // A group match by its format; the place and gap are in the label.
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
