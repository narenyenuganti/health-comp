import CompetitionCore
import SwiftUI

enum FriendsSortOrder: String, CaseIterable, Identifiable, Sendable {
    case name
    case todayPoints
    case margin
    case wins

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .todayPoints: "Today’s Points"
        case .margin: "Closest Match"
        case .wins: "Head-to-Head"
        }
    }
}

struct RingsideHighlight: Equatable, Identifiable, Sendable {
    let id: String
    let competitionID: CompetitionID
    let dayOrdinal: Int
    let opponentName: String
    let headline: String
    let detail: String
}

func ringsideHighlights(
    _ competitions: [LocalCompetitionPresentation],
    locale: Locale = .current
) -> [RingsideHighlight] {
    var items: [RingsideHighlight] = []
    for competition in competitions where !competition.isPractice {
        switch competition.lifecycle {
        case .active, .endsToday:
            guard let ordinal = competition.currentDayOrdinal,
                  let today = competition.days.first(where: { $0.ordinal == ordinal })
            else { continue }
            let themToday = today.opponentRevealedPoints ?? 0
            let margin = competitionDisplayedMargin(
                userPoints: competition.userPoints,
                opponentPoints: competition.opponentPoints
            )
            if themToday >= 350 {
                let pts = competitionPointsText(themToday, locale: locale)
                let summary = margin > 0
                    ? "Your lead is \(competitionPointsText(margin, locale: locale))."
                    : margin < 0
                        ? "You trail by \(competitionPointsText(abs(margin), locale: locale))."
                        : "Match is all square."
                items.append(.init(
                    id: "\(competition.id.rawValue.uuidString):high:\(ordinal)",
                    competitionID: competition.id,
                    dayOrdinal: ordinal,
                    opponentName: competition.opponentDisplayName,
                    headline: "Posted \(pts) pts on Day \(ordinal)",
                    detail: summary
                ))
            } else if abs(margin) <= 40, competition.userPoints + competition.opponentPoints > 0 {
                let summary = margin == 0
                    ? "All square on Day \(ordinal)."
                    : margin > 0
                        ? "You lead by \(competitionPointsText(margin, locale: locale)) on Day \(ordinal)."
                        : "\(competition.opponentDisplayName) leads by \(competitionPointsText(abs(margin), locale: locale))."
                items.append(.init(
                    id: "\(competition.id.rawValue.uuidString):tight:\(ordinal)",
                    competitionID: competition.id,
                    dayOrdinal: ordinal,
                    opponentName: competition.opponentDisplayName,
                    headline: "Close match",
                    detail: summary
                ))
            }
        default:
            continue
        }
    }
    return Array(items.prefix(5))
}

func friendLiveTodayPoints(
    identity: String,
    competitions: [LocalCompetitionPresentation]
) -> Double? {
    let live = competitions.first { competition in
        guard competition.opponentIdentity == identity, !competition.isPractice else { return false }
        switch competition.lifecycle {
        case .active, .endsToday: return true
        default: return false
        }
    }
    guard let live, let ordinal = live.currentDayOrdinal else { return nil }
    return live.days.first(where: { $0.ordinal == ordinal })?.opponentRevealedPoints
}

func friendLiveMargin(
    identity: String,
    competitions: [LocalCompetitionPresentation]
) -> Double? {
    let live = competitions.first { competition in
        guard competition.opponentIdentity == identity, !competition.isPractice else { return false }
        switch competition.lifecycle {
        case .active, .endsToday, .tallying: return true
        default: return false
        }
    }
    guard let live else { return nil }
    return competitionDisplayedMargin(
        userPoints: live.userPoints,
        opponentPoints: live.opponentPoints
    )
}

func sortedFriends(
    _ friends: [FriendPerson],
    by order: FriendsSortOrder,
    competitions: [LocalCompetitionPresentation]
) -> [FriendPerson] {
    let records = Dictionary(
        uniqueKeysWithValues: competitionOpponentRecords(competitions).map { ($0.opponentIdentity, $0) }
    )
    return friends.sorted { lhs, rhs in
        switch order {
        case .name:
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        case .todayPoints:
            let l = friendLiveTodayPoints(identity: lhs.identity, competitions: competitions) ?? -1
            let r = friendLiveTodayPoints(identity: rhs.identity, competitions: competitions) ?? -1
            if l != r { return l > r }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        case .margin:
            let l = friendLiveMargin(identity: lhs.identity, competitions: competitions).map(abs) ?? .infinity
            let r = friendLiveMargin(identity: rhs.identity, competitions: competitions).map(abs) ?? .infinity
            if l != r { return l < r }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        case .wins:
            let l = records[lhs.identity]?.wins ?? -1
            let r = records[rhs.identity]?.wins ?? -1
            if l != r { return l > r }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }
}

struct RingsideHighlightsStrip: View {
    let highlights: [RingsideHighlight]
    let openMatch: (CompetitionID) -> Void
    let react: (CompetitionID, Int, CompetitionReactionKind) -> Void

    @State private var sent: [String: CompetitionReactionKind] = [:]

    var body: some View {
        if !highlights.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel("RINGSIDE")
                    Spacer(minLength: 8)
                    Text("\(highlights.count) LIVE")
                        .themeLabel()
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 4)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(highlights) { item in
                            card(item)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("friends.highlights")
        }
    }

    private func card(_ item: RingsideHighlight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { openMatch(item.competitionID) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.opponentName.uppercased())
                        .themeLabel(tracking: 0.9)
                        .foregroundStyle(Theme.secondary)
                    Text(item.headline)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                ForEach([CompetitionReactionKind.clap, .fire, .salute], id: \.self) { kind in
                    let isSent = sent[item.id] == kind
                    Button {
                        sent[item.id] = kind
                        react(item.competitionID, item.dayOrdinal, kind)
                    } label: {
                        Text(kind.emoji)
                            .font(.callout)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(
                                isSent ? Theme.ink : Theme.ground,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().strokeBorder(
                                    isSent ? Theme.ink : Theme.outline,
                                    lineWidth: 1
                                )
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send \(kind.spokenName) to \(item.opponentName)")
                    .accessibilityIdentifier("friends.highlight.react.\(kind.rawValue)")
                }
            }
        }
        .padding(14)
        .frame(width: 236, alignment: .leading)
        .themePanel()
    }
}
