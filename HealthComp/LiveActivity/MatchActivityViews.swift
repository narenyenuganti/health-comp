import SwiftUI

struct MatchActivityLockScreenView: View {
    let attributes: MatchActivityAttributes
    let state: MatchActivityAttributes.ContentState

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: isLarge ? 2 : 8) {
            MatchActivityHeader(state: state, showsTiming: !isLarge)
            HStack(alignment: .bottom, spacing: 8) {
                MatchActivityScoreColumn(side: .you, attributes: attributes, state: state, size: 40, namesInline: isLarge)
                if !isLarge {
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
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .combine)
    }
}

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
                .minimumScaleFactor(isLarge ? 0.5 : 0.8)
                .truncationMode(.middle)
            if showsFreshness, let freshness = state.freshness {
                Text(freshness)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.middle)
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

struct MatchActivityIslandBottom: View {
    let state: MatchActivityAttributes.ContentState

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        MatchActivityBottomRows(state: state, showsFreshness: dynamicTypeSize <= .large)
    }
}

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

let matchActivityIslandScoreSize: CGFloat = 29

struct MatchActivityIslandHeader: View {
    let attributes: MatchActivityAttributes
    let state: MatchActivityAttributes.ContentState

    var body: some View {
        let title = Text(state.title.uppercased(with: .current))
            .tracking(1.2)
            .foregroundStyle(Theme.ink)
        let countdown = Text(attributes.endsAt, style: .relative) + Text(" left")
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
    func matchActivityIsland() -> some View {
        environment(\.colorScheme, .dark)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
