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
                // At accessibility sizes the card has no room for the name
                // row: amber is you, and the header names the other person.
                MatchActivityScoreColumn(side: .you, state: state, size: 40, showsName: !isLarge)
                if !isLarge {
                    // Home's HeroScoreboard divider.
                    Rectangle()
                        .fill(Theme.outline)
                        .frame(width: 2, height: 40)
                        .rotationEffect(.degrees(12))
                        .accessibilityHidden(true)
                }
                MatchActivityScoreColumn(side: .them, state: state, size: 40, showsName: !isLarge)
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

    var body: some View {
        HStack(spacing: 6) {
            if state.phase == .live {
                Circle()
                    .fill(Theme.ink)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Text("\(state.title) · \(state.opponentName)")
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            if showsTiming, let timing = state.timing {
                Text(timing)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .font(.themeLabel)
        .tracking(1.2)
        .textCase(.uppercase)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
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

/// "YOU" over the score, or the other person's name over theirs.
struct MatchActivityScoreColumn: View {
    let side: MatchActivitySide
    let state: MatchActivityAttributes.ContentState
    let size: CGFloat
    var showsName = true

    var body: some View {
        let alignment: HorizontalAlignment = side == .you ? .leading : .trailing
        VStack(alignment: alignment, spacing: 2) {
            if showsName {
                Text(side.name(state).uppercased(with: .current))
                    .font(.themeLabel)
                    .tracking(1.4)
            }
            Text(competitionPointsText(side.points(state)))
                .font(.score(size: size).monospacedDigit())
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .foregroundStyle(side.color)
        .frame(maxWidth: .infinity, alignment: side == .you ? .leading : .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(side.accessibilityLabel(state))
    }
}

/// The lead sentence, then each side's Updated time.
struct MatchActivityBottomRows: View {
    let state: MatchActivityAttributes.ContentState
    var showsFreshness = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            lead
                .font(.footnote)
                .foregroundStyle(Theme.ink)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.5)
            if showsFreshness, let freshness = state.freshness {
                Text(freshness)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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

/// One side's score in the compact Dynamic Island.
struct MatchActivityCompactScore: View {
    let side: MatchActivitySide
    let state: MatchActivityAttributes.ContentState

    var body: some View {
        Text(competitionPointsText(side.points(state)))
            .font(.headline.weight(.heavy).width(.compressed).monospacedDigit())
            .foregroundStyle(side.color)
            .lineLimit(1)
            .accessibilityLabel(side.accessibilityLabel(state))
    }
}

/// "+19" in amber, "−5" in ink or "0", for the minimal Dynamic Island.
struct MatchActivityMinimalLead: View {
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
        .accessibilityLabel(competitionLeadSentence(
            userPoints: state.userPoints,
            opponentPoints: state.opponentPoints,
            opponentDisplayName: state.opponentName
        ))
    }
}

/// The expanded Dynamic Island's center: "LAST DAY" and "5 hr, 45 min left",
/// which iOS counts down with no app work. Pending drops the countdown.
struct MatchActivityIslandHeader: View {
    let attributes: MatchActivityAttributes
    let state: MatchActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 2) {
            Text(state.title)
                .font(.themeLabel)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Theme.ink)
            if state.phase == .live {
                (Text(attributes.endsAt, style: .relative) + Text(" left"))
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
