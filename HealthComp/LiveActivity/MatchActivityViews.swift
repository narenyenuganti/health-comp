import SwiftUI

// The Live Activity's views, compiled into the app and the widget extension.
// No WidgetKit or ActivityKit context, so the Test Lab can draw them too.
// Callers pass `state.resolved(isStale:)`.

/// The Lock Screen card.
struct MatchActivityLockScreenView: View {
    let attributes: MatchActivityAttributes
    let state: MatchActivityAttributes.ContentState

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: isLarge ? 2 : 8) {
            MatchActivityHeader(state: state, showsTiming: !isLarge)
            HStack(alignment: .bottom, spacing: 8) {
                // At accessibility sizes the card has no room for a name row,
                // so "YOU" and the name sit beside the scores.
                MatchActivityScoreColumn(side: .you, attributes: attributes, state: state, size: 40, namesInline: isLarge)
                if !isLarge {
                    // Home's HeroScoreboard divider.
                    Rectangle()
                        .fill(Theme.outline)
                        .frame(width: 2, height: 40)
                        .rotationEffect(.degrees(12))
                        .accessibilityHidden(true)
                }
                MatchActivityScoreColumn(side: .them, attributes: attributes, state: state, size: 40, namesInline: isLarge)
            }
            MatchActivityBottomRows(state: state, showsFreshness: !isLarge)
        }
        .padding(isLarge ? 12 : 16)
        // ponytail: the Lock Screen card is at most 160 pt tall; past AX2 the
        // text can't fit without truncating, so the card stops growing there.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .combine)
    }
}

/// Dot, "LAST DAY · SAM" and, on the right, "ENDS AT MIDNIGHT".
struct MatchActivityHeader: View {
    let state: MatchActivityAttributes.ContentState
    var showsTiming = true

    @ScaledMetric(relativeTo: .footnote) private var dotSize: CGFloat = 6

    var body: some View {
        HStack(spacing: 6) {
            if state.phase == .live {
                Circle()
                    .fill(Theme.ink)
                    .frame(width: dotSize, height: dotSize)
                    .accessibilityHidden(true)
            }
            // The timing shows only when the whole title fits beside it, so
            // "Former competitor" is never cut short for "Ends at midnight".
            // A longer name shrinks a little, then truncates.
            ViewThatFits(in: .horizontal) {
                if showsTiming, let timing = state.timing {
                    HStack(spacing: 0) {
                        title.fixedSize()
                        Spacer(minLength: 20)
                        Text(timing).foregroundStyle(Theme.secondary).fixedSize()
                    }
                }
                title.minimumScaleFactor(0.8)
            }
        }
        .themeLabel()
        .textCase(.uppercase)
        .lineLimit(1)
    }

    private var title: some View {
        Text("\(state.title) · \(state.opponentName)").foregroundStyle(Theme.ink)
    }
}

enum MatchActivitySide {
    case you, them

    func name(_ state: MatchActivityAttributes.ContentState) -> String {
        self == .you ? "You" : state.opponentName
    }

    func points(_ state: MatchActivityAttributes.ContentState) -> Double {
        self == .you ? state.userPoints : state.opponentPoints
    }

    var color: Color { self == .you ? Theme.you : Theme.ink }

    func accessibilityLabel(_ state: MatchActivityAttributes.ContentState) -> String {
        "\(name(state)) \(competitionPointsAccessibilityText(points(state)))"
    }
}

/// "YOU" over the score, or the other person's name over theirs. Inline,
/// "YOU 2,190" and "2,171 SAM", where the name gives way to the score.
struct MatchActivityScoreColumn: View {
    let side: MatchActivitySide
    let attributes: MatchActivityAttributes
    let state: MatchActivityAttributes.ContentState
    let size: CGFloat
    var namesInline = false

    var body: some View {
        let alignment: HorizontalAlignment = side == .you ? .leading : .trailing
        Group {
            if namesInline {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if side == .you { name; score } else { score; name }
                }
            } else {
                VStack(alignment: alignment, spacing: 2) { name; score }
            }
        }
        .lineLimit(1)
        .foregroundStyle(side.color)
        .frame(maxWidth: .infinity, alignment: side == .you ? .leading : .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(side.accessibilityLabel(state))
    }

    // Shrinks a little, then truncates, like the header.
    private var name: some View {
        Text(side.name(state).uppercased(with: .current))
            .themeLabel(tracking: 1.4)
            .minimumScaleFactor(0.8)
    }

    private var score: some View {
        Text(competitionPointsText(side.points(state)))
            .font(.score(size: size).monospacedDigit())
            .minimumScaleFactor(0.5)
            .scoreRoll(side.points(state), id: attributes.matchID)
            .layoutPriority(1)
    }
}

/// The lead sentence, then each side's Updated time.
struct MatchActivityBottomRows: View {
    let state: MatchActivityAttributes.ContentState
    var showsFreshness = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 2) {
            lead
                .font(.footnote)
                .foregroundStyle(Theme.ink)
                .lineLimit(isLarge ? 2 : 1)
                // A long name shrinks a little, then loses its middle, so the
                // margin at the end ("leads by 15.") always shows. At
                // accessibility sizes the text is large enough to shrink
                // further into its two lines, which keeps the whole sentence.
                .minimumScaleFactor(isLarge ? 0.5 : 0.8)
                .truncationMode(.middle)
            if showsFreshness, let freshness = state.freshness {
                Text(freshness)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.middle)  // keeps "updated 6:02 PM"
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lead: Text {
        let lead = competitionLeadText(
            userPoints: state.userPoints,
            opponentPoints: state.opponentPoints,
            opponentDisplayName: state.opponentName
        )
        return state.phase == .pending ? lead + Text(" Not final yet.") : lead
    }
}

/// The expanded Dynamic Island's bottom. The island's height is fixed, so
/// above the default text size the Updated line goes, as it does on the Lock
/// Screen at accessibility sizes; it was cut in half at AX5.
struct MatchActivityIslandBottom: View {
    let state: MatchActivityAttributes.ContentState

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        MatchActivityBottomRows(state: state, showsFreshness: dynamicTypeSize <= .large)
    }
}

/// One side's score in the compact Dynamic Island.
struct MatchActivityCompactScore: View {
    let side: MatchActivitySide
    let attributes: MatchActivityAttributes
    let state: MatchActivityAttributes.ContentState

    var body: some View {
        Text(competitionPointsText(side.points(state)))
            .font(.headline.weight(.heavy).width(.compressed).monospacedDigit())
            .foregroundStyle(side.color)
            .lineLimit(1)
            .scoreRoll(side.points(state), id: attributes.matchID)
            .accessibilityLabel(side.accessibilityLabel(state))
    }
}

/// "+19" in amber, "−5" in ink or "0", for the minimal Dynamic Island.
struct MatchActivityMinimalLead: View {
    let attributes: MatchActivityAttributes
    let state: MatchActivityAttributes.ContentState

    var body: some View {
        let margin = competitionDisplayedMargin(
            userPoints: state.userPoints, opponentPoints: state.opponentPoints
        )
        Text(competitionSignedMarginText(
            userPoints: state.userPoints, opponentPoints: state.opponentPoints
        ))
        .font(.headline.weight(.heavy).width(.compressed).monospacedDigit())
        .foregroundStyle(margin > 0 ? Theme.you : margin < 0 ? Theme.ink : Theme.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .scoreRoll(margin, id: attributes.matchID)
        .accessibilityLabel(competitionLeadSentence(
            userPoints: state.userPoints,
            opponentPoints: state.opponentPoints,
            opponentDisplayName: state.opponentName
        ))
    }
}

/// Apple Watch Smart Stack and CarPlay: the title, then both scores.
struct MatchActivitySmallView: View {
    let attributes: MatchActivityAttributes
    let state: MatchActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title)
                .themeLabel()
                .textCase(.uppercase)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .bottom, spacing: 8) {
                MatchActivityScoreColumn(side: .you, attributes: attributes, state: state, size: 28)
                MatchActivityScoreColumn(side: .them, attributes: attributes, state: state, size: 28)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The expanded Dynamic Island's score size. The island's height is fixed, so
/// at 34 the scores shrank whenever the Updated line showed; 29 fits with it,
/// and the scores keep one size in every state.
let matchActivityIslandScoreSize: CGFloat = 29

/// The expanded Dynamic Island's center: "LAST DAY  5 hr, 45 min left", which
/// iOS counts down with no app work. Pending drops the countdown. One line,
/// so the scores below keep their size: the island's height is fixed, and a
/// second line here shrank them.
struct MatchActivityIslandHeader: View {
    let attributes: MatchActivityAttributes
    let state: MatchActivityAttributes.ContentState

    var body: some View {
        // `textCase` skips a date's text, so only the title is uppercased.
        let title = Text(state.title.uppercased(with: .current))
            .tracking(1.2)
            .foregroundStyle(Theme.ink)
        let countdown = Text(attributes.endsAt, style: .relative) + Text(" left")
        // Plain footnote, so the countdown reads apart from the tracked title.
        let shownCountdown = countdown.font(.footnote).foregroundStyle(Theme.secondary)
        Group {
            if state.phase == .live {
                title + Text("  ") + shownCountdown
            } else {
                title
            }
        }
        .font(.themeLabel)
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityLabel(state.phase == .live ? Text(state.title) + Text(", ") + countdown : Text(state.title))
    }
}

extension View {
    /// Every Dynamic Island region: dark, so amber stays you on black, and
    /// no larger than xxxLarge, where iOS 18.5 stops growing the island's
    /// text even at AX5. The Test Lab's island mocks use it too.
    func matchActivityIsland() -> some View {
        environment(\.colorScheme, .dark)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
