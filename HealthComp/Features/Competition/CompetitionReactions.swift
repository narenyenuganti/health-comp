import CompetitionCore
import Foundation
import SwiftUI

// Reactions (spec §9.8): one preset per person per target, on the other
// person's day or on the result. They live outside the change log and reach
// the app through `list_competition_reactions`.

enum CompetitionReactionKind: String, CaseIterable, Sendable {
    case clap, fire, huffing, salute

    var emoji: String {
        switch self {
        case .clap: "👏"
        case .fire: "🔥"
        case .huffing: "😤"
        case .salute: "🫡"
        }
    }

    var spokenName: String {
        switch self {
        case .clap: "Clap"
        case .fire: "Fire"
        case .huffing: "Huffing"
        case .salute: "Salute"
        }
    }
}

enum CompetitionReactionTarget: Hashable, Sendable {
    case day(Int)
    case result

    var dayOrdinal: Int? {
        if case let .day(ordinal) = self { ordinal } else { nil }
    }
}

/// On a presentation: who reacted is relative to you.
struct CompetitionReaction: Equatable, Sendable {
    let target: CompetitionReactionTarget
    let kind: CompetitionReactionKind
    let isFromYou: Bool
    let updatedAt: Date
}

struct CompetitionReactionKey: Hashable, Sendable {
    let competitionID: CompetitionID
    let target: CompetitionReactionTarget
}

/// Per match, the server `updatedAt` of the newest reaction you got that
/// you've already seen (on its match or result screen). Device-local.
struct CompetitionReactionsSeen: RawRepresentable, Equatable {
    static let storageKey = "healthcomp.reactionsSeen"

    // ponytail: never pruned (about 60 bytes per match); prune against the dashboard if that ever matters.
    var seenAt: [String: TimeInterval]

    init() { seenAt = [:] }

    // Encodes only `seenAt`: making the wrapper Codable would encode
    // through `rawValue` and recurse.
    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let seenAt = try? JSONDecoder().decode([String: TimeInterval].self, from: data)
        else { return nil }
        self.seenAt = seenAt
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(seenAt) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func marking(_ competition: LocalCompetitionPresentation) -> Self {
        guard let newest = competition.reactions.filter({ !$0.isFromYou })
            .map({ $0.updatedAt.timeIntervalSince1970 }).max()
        else { return self }
        let key = competition.id.rawValue.uuidString.lowercased()
        guard newest > seenAt[key] ?? -.infinity else { return self }
        var marked = self
        marked.seenAt[key] = newest
        return marked
    }

    func hasSeen(_ reaction: CompetitionReaction, in id: CompetitionID) -> Bool {
        guard let seen = seenAt[id.rawValue.uuidString.lowercased()] else { return false }
        return reaction.updatedAt.timeIntervalSince1970 <= seen
    }
}

func competitionReactionText(_ reaction: CompetitionReaction, opponentName: String) -> String {
    switch (reaction.isFromYou, reaction.target) {
    case let (false, .day(ordinal)): "\(opponentName) reacted to your Day \(ordinal)"
    case (false, .result): "\(opponentName) reacted to the result"
    case let (true, .day(ordinal)): "You reacted to \(opponentName)’s Day \(ordinal)"
    case (true, .result): "You reacted to the result"
    }
}

func competitionReactionAccessibilityText(
    _ reaction: CompetitionReaction,
    opponentName: String
) -> String {
    "\(reaction.kind.spokenName). \(competitionReactionText(reaction, opponentName: opponentName))"
}

/// The week's REACTIONS list: the result first, then by day; yours first
/// within each target.
func competitionReactionsInWeekOrder(_ reactions: [CompetitionReaction]) -> [CompetitionReaction] {
    reactions.sorted { lhs, rhs in
        let left = lhs.target.dayOrdinal ?? 0
        let right = rhs.target.dayOrdinal ?? 0
        if left != right { return left < right }
        return lhs.isFromYou && !rhs.isFromYou
    }
}

/// The newest reaction you got that you haven't seen, for Home and the match
/// screen. Nil for matches that show no scores (scheduled, cancelled).
func competitionUnseenReaction(
    _ competition: LocalCompetitionPresentation,
    seen: CompetitionReactionsSeen
) -> CompetitionReaction? {
    guard competitionShouldShowScores(competition.lifecycle),
          let newest = competition.reactions.filter({ !$0.isFromYou })
            .max(by: { $0.updatedAt < $1.updatedAt }),
          !seen.hasSeen(newest, in: competition.id)
    else { return nil }
    return newest
}

/// A real other person who can still see it, once the match has started.
/// Callers pick the target: days on the live screen, the result on the
/// result screen.
func competitionCanReact(_ competition: LocalCompetitionPresentation) -> Bool {
    competitionShouldShowScores(competition.lifecycle)
        && RemoteCompetitionOpponentIdentity.profileID(competition.opponentIdentity) != nil
        && competition.opponentDisplayName != "Former competitor"
}

extension LocalCompetitionPresentation {
    func ownReaction(_ target: CompetitionReactionTarget) -> CompetitionReaction? {
        reactions.first { $0.isFromYou && $0.target == target }
    }

    func receivedReaction(_ target: CompetitionReactionTarget) -> CompetitionReaction? {
        reactions.first { !$0.isFromYou && $0.target == target }
    }
}

/// One match's reaction state and the tap handler, handed to its screens.
/// Nil on a screen means no reactions there (local and simulated matches).
struct CompetitionReactionControl {
    /// The kind being saved per target; `.some(nil)` while removing.
    let pending: [CompetitionReactionTarget: CompetitionReactionKind?]
    let failed: Set<CompetitionReactionTarget>
    let react: (CompetitionReactionTarget, CompetitionReactionKind) -> Void

    func selection(
        _ target: CompetitionReactionTarget,
        in competition: LocalCompetitionPresentation
    ) -> CompetitionReactionKind? {
        if let pending = pending[target] { return pending }
        return competition.ownReaction(target)?.kind
    }

    func picker(
        _ target: CompetitionReactionTarget,
        in competition: LocalCompetitionPresentation
    ) -> CompetitionReactionPicker {
        CompetitionReactionPicker(
            selection: selection(target, in: competition),
            isPending: pending[target] != nil,
            failed: failed.contains(target),
            select: { react(target, $0) }
        )
    }
}

/// Four preset chips: one row, or 2×2 at accessibility sizes.
struct CompetitionReactionPicker: View {
    let selection: CompetitionReactionKind?
    let isPending: Bool
    let failed: Bool
    let select: (CompetitionReactionKind) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var chipSize: CGFloat = 48

    var body: some View {
        // AnyLayout, not ViewThatFits: the Dynamic Type audit flags text
        // that ViewThatFits swaps out.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        VStack(alignment: .leading, spacing: 8) {
            layout {
                HStack(spacing: 10) { chip(.clap); chip(.fire) }
                HStack(spacing: 10) { chip(.huffing); chip(.salute) }
            }
            if failed {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text("Couldn’t send your reaction. Try again.")
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("competition.react.error")
                }
                .font(.caption)
                .foregroundStyle(Theme.ink)
                .transition(Motion.appear)
            }
        }
        .moving(Motion.settle, value: failed)
        .sensoryFeedback(.selection, trigger: isPending) { _, pending in pending }
        .sensoryFeedback(.error, trigger: failed) { _, failed in failed }
    }

    private func chip(_ kind: CompetitionReactionKind) -> some View {
        let isSelected = selection == kind
        let hint: String = isSelected ? "Removes your reaction" : ""
        return Button { select(kind) } label: {
            Text(kind.emoji)
                .font(.title2)
                .frame(width: chipSize, height: chipSize)
                .background(Theme.control, in: Circle())
                .overlay {
                    // A hairline keeps unselected chips visible on a panel.
                    Circle().strokeBorder(
                        isSelected ? Theme.you : Theme.hairline,
                        lineWidth: isSelected ? 2 : 1
                    )
                    .animation(Motion.fade, value: isSelected)
                }
                .contentShape(Circle())
        }
        // A tap, never the end of a drag: in a drawer, the sheet's own drag
        // (to resize or dismiss it) doesn't cancel a Button's touch, so
        // scrolling from a chip sent a reaction.
        .buttonStyle(CompetitionReactionChipStyle())
        .disabled(isPending)
        .accessibilityLabel(kind.spokenName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(hint)
        .accessibilityIdentifier("competition.react.\(kind.rawValue)")
    }
}

/// Fires on a tap only; any drag cancels it. Keeps Button's traits,
/// disabled state and VoiceOver activation.
private struct CompetitionReactionChipStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onTapGesture(perform: configuration.trigger)
    }
}

/// `SectionLabel`'s look with kerning, not tracking: the text clipping
/// audit flags tracked labels here ("REACT TO THE RESULT", a tracked ’).
struct CompetitionReactionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.themeLabel)
            .kerning(1.2)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "😤 Jordan reacted to your Day 2", read as one element.
struct CompetitionReactionLine: View {
    let reaction: CompetitionReaction
    let opponentName: String
    var id: String?

    var body: some View {
        if let id {
            line.accessibilityIdentifier(id)
        } else {
            line
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var line: some View {
        // Emoji above the text at accessibility sizes: beside it, the text
        // gets a column a word or two wide (and hyphenates) in Home rows.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            CompetitionReactionEmoji(kind: reaction.kind)
            Text(competitionReactionText(reaction, opponentName: opponentName))
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            competitionReactionAccessibilityText(reaction, opponentName: opponentName)
        )
    }
}

/// The emoji drawn as an image. The text clipping audit flags an emoji
/// `Text` inside an accessibility container (the line, a Home card) because
/// its glyph overflows the line box, even when it's hidden.
private struct CompetitionReactionEmoji: View {
    let kind: CompetitionReactionKind

    @ScaledMetric(relativeTo: .title3) private var size: CGFloat = 24
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let image = renderedImage {
            Image(decorative: image, scale: displayScale)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    // ponytail: rendered on every body pass (a few lines on screen); cache per kind if it ever shows in a profile.
    @MainActor
    private var renderedImage: CGImage? {
        let renderer = ImageRenderer(content: Text(kind.emoji).font(.system(size: size)))
        renderer.scale = displayScale
        return renderer.cgImage
    }
}
