import CompetitionCore
import Foundation
import SwiftUI
import UIKit

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
                Text("Couldn’t send your reaction. Try again.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("competition.react.error")
            }
        }
    }

    private func chip(_ kind: CompetitionReactionKind) -> some View {
        let isSelected = selection == kind
        let hint: String = isSelected ? "Removes your reaction" : ""
        return Button { select(kind) } label: {
            CompetitionReactionEmoji(kind: kind, size: chipSize * 0.58)
                .frame(width: chipSize, height: chipSize)
                .background(Theme.control, in: Circle())
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(Theme.you, lineWidth: 2)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(CompetitionPressButtonStyle())
        .disabled(isPending)
        .accessibilityLabel(kind.spokenName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(hint)
        .accessibilityIdentifier("competition.react.\(kind.rawValue)")
    }
}

/// "😤 Jordan reacted to your Day 2", read as one element.
struct CompetitionReactionLine: View {
    let reaction: CompetitionReaction
    let opponentName: String
    var id: String?

    @ScaledMetric(relativeTo: .title3) private var emojiSize: CGFloat = 24

    var body: some View {
        if let id {
            line.accessibilityIdentifier(id)
        } else {
            line
        }
    }

    private var line: some View {
        HStack(spacing: 8) {
            CompetitionReactionEmoji(kind: reaction.kind, size: emojiSize)
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

/// The emoji drawn as an image, on a canvas sized from the glyph's real
/// bounds. As `Text`, 🫡 draws wider than its advance and loses its right
/// half, and the text clipping audit flags emoji glyphs overflowing the line.
private struct CompetitionReactionEmoji: View {
    let kind: CompetitionReactionKind
    let size: CGFloat

    var body: some View {
        Image(uiImage: Self.image(kind))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @MainActor private static var images: [CompetitionReactionKind: UIImage] = [:]

    /// Drawn once per kind at 96 pt and scaled down.
    @MainActor
    private static func image(_ kind: CompetitionReactionKind) -> UIImage {
        if let image = images[kind] { return image }
        let text = NSAttributedString(
            string: kind.emoji,
            attributes: [.font: UIFont.systemFont(ofSize: 96)]
        )
        let glyph = text.boundingRect(
            with: CGSize(width: 1_000, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesDeviceMetrics],
            context: nil
        )
        // A margin, in case the reported bounds are still short.
        let side = ceil(max(glyph.width, glyph.height) * 1.1)
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            text.draw(at: CGPoint(
                x: (side - glyph.width) / 2 - glyph.minX,
                y: (side - glyph.height) / 2 - glyph.minY
            ))
        }
        images[kind] = image
        return image
    }
}
