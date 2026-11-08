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

/// Motion that plays once, not on every visit. Device-local, like the
/// reaction marks: per match, the newest day your Week bars grew for.
struct CompetitionMotionSeen: RawRepresentable, Equatable {
    static let storageKey = "healthcomp.motionSeen"

    // ponytail: never pruned (about 50 bytes per match), like the reaction marks.
    var weekDrawn: [String: Int]

    init() { weekDrawn = [:] }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let weekDrawn = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return nil }
        self.weekDrawn = weekDrawn
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(weekDrawn) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// True when your newest scored day is newer than the last one drawn.
    func weekGained(_ competition: LocalCompetitionPresentation) -> Bool {
        guard let newest = Self.newestScoredDay(competition) else { return false }
        return newest > weekDrawn[Self.key(competition)] ?? 0
    }

    func drawingWeek(_ competition: LocalCompetitionPresentation) -> Self {
        var drawn = self
        drawn.weekDrawn[Self.key(competition)] = Self.newestScoredDay(competition)
        return drawn
    }

    private static func newestScoredDay(_ competition: LocalCompetitionPresentation) -> Int? {
        competition.days.filter { $0.ownerAcceptedPoints != nil }.map(\.ordinal).max()
    }

    private static func key(_ competition: LocalCompetitionPresentation) -> String {
        competition.id.rawValue.uuidString.lowercased()
    }
}

/// Reaction rain marks share the map under `rain:<match>`: the newest
/// received reaction (in ms) that has rained on this phone.
extension CompetitionMotionSeen {
    /// Received, not yet seen on its match screen, and not yet rained.
    /// Never for practice, which has no other person.
    func unrained(
        _ competition: LocalCompetitionPresentation,
        seen: CompetitionReactionsSeen
    ) -> [CompetitionReaction] {
        guard competitionShouldShowScores(competition.lifecycle), !competition.isPractice else {
            return []
        }
        let rained = weekDrawn[Self.rainMark(competition.id)] ?? .min
        return competition.reactions.filter {
            !$0.isFromYou && !seen.hasSeen($0, in: competition.id)
                && Self.milliseconds($0.updatedAt) > rained
        }
    }

    func raining(_ competitions: [LocalCompetitionPresentation]) -> Self {
        var marked = self
        for competition in competitions {
            guard let newest = competition.reactions.filter({ !$0.isFromYou })
                .map({ Self.milliseconds($0.updatedAt) }).max()
            else { continue }
            let key = Self.rainMark(competition.id)
            marked.weekDrawn[key] = max(newest, marked.weekDrawn[key] ?? .min)
        }
        return marked
    }

    private static func rainMark(_ id: CompetitionID) -> String {
        "rain:\(id.rawValue.uuidString.lowercased())"
    }

    private static func milliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}

/// What rains when a screen showing these matches appears.
struct CompetitionReactionRainBatch: Equatable {
    /// Newest first, mixed into the drops.
    let kinds: [CompetitionReactionKind]
    let announcement: String
}

/// The newest few unrained reactions across `competitions`; nil when none.
func competitionReactionRainBatch(
    _ competitions: [LocalCompetitionPresentation],
    seen: CompetitionReactionsSeen,
    motionSeen: CompetitionMotionSeen,
    cap: Int = 4
) -> CompetitionReactionRainBatch? {
    let incoming = competitions.flatMap { competition in
        motionSeen.unrained(competition, seen: seen).map {
            (reaction: $0, name: competition.opponentDisplayName)
        }
    }
    .sorted { $0.reaction.updatedAt > $1.reaction.updatedAt }
    .prefix(cap)
    guard !incoming.isEmpty else { return nil }
    return CompetitionReactionRainBatch(
        kinds: incoming.map { $0.reaction.kind },
        announcement: incoming.map {
            competitionReactionAccessibilityText($0.reaction, opponentName: $0.name)
        }.joined(separator: ". ")
    )
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
    @Environment(\.competitionReactionRain) private var rain
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
        .sensoryFeedback(.selection, trigger: isPending) { _, new in new }
        .sensoryFeedback(.error, trigger: failed) { _, new in new }
    }

    private func chip(_ kind: CompetitionReactionKind) -> some View {
        let isSelected = selection == kind
        let hint: String = isSelected ? "Removes your reaction" : ""
        return Button {
            // Setting or replacing rains; removing doesn't.
            if !isSelected { rain(kind) }
            select(kind)
        } label: {
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

// MARK: - Rain

private struct CompetitionReactionRainKey: EnvironmentKey {
    static let defaultValue: (CompetitionReactionKind) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Set by `competitionReactionRain`; a chip calls it when you react.
    var competitionReactionRain: (CompetitionReactionKind) -> Void {
        get { self[CompetitionReactionRainKey.self] }
        set { self[CompetitionReactionRainKey.self] = newValue }
    }
}

extension View {
    /// Rains reactions over this view: yours when you tap a chip inside it,
    /// and `incoming` once while it is on screen, live too. `rained` writes
    /// the seen mark. One rain at a time: a new one replaces it. A sheet
    /// needs its own, or the rain falls behind it.
    func competitionReactionRain(
        incoming: CompetitionReactionRainBatch? = nil,
        rained: @escaping () -> Void = {}
    ) -> some View {
        modifier(CompetitionReactionRainHost(incoming: incoming, rained: rained))
    }
}

private struct CompetitionReactionRainHost: ViewModifier {
    let incoming: CompetitionReactionRainBatch?
    let rained: () -> Void

    @State private var rain: CompetitionReactionRainDrops?
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .environment(\.competitionReactionRain, { start([$0]) })
            .overlay {
                if let rain {
                    CompetitionReactionRainView(rain: rain)
                }
            }
            .task(id: rain?.id) {
                guard rain != nil,
                      (try? await Task.sleep(for: .seconds(Motion.rain))) != nil
                else { return }
                rain = nil
            }
            .onAppear {
                isOnScreen = true
                startIncoming()
            }
            .onDisappear {
                isOnScreen = false
                rain = nil
            }
            .onChange(of: incoming) { startIncoming() }
    }

    private func start(_ kinds: [CompetitionReactionKind]) {
        rain = CompetitionReactionRainDrops(kinds: kinds)
    }

    private func startIncoming() {
        guard isOnScreen, let incoming else { return }
        start(incoming.kinds)
        AccessibilityNotification.Announcement(incoming.announcement).post()
        rained()
    }
}

/// One rain's drops, drawn once at the start: kinds mixed in turn, each with
/// its own column, size, delay, drift and spin.
private struct CompetitionReactionRainDrops: Equatable {
    struct Drop: Equatable {
        let kind: CompetitionReactionKind
        let x: Double
        let scale: Double
        let delay: Double
        let fall: Double
        let drift: Double
        let spin: Double
        let turn: Double
    }

    let id = UUID()
    let start = Date()
    let kinds: [CompetitionReactionKind]
    let drops: [Drop]

    init(kinds: [CompetitionReactionKind]) {
        self.kinds = kinds
        // 26 drops, the last leaving by `Motion.rain`: a delay up to 0.7 s,
        // then a fall of 1.3 s or more.
        drops = (0..<26).map { index in
            let delay = Double.random(in: 0...0.7)
            return Drop(
                kind: kinds.isEmpty ? .clap : kinds[index % kinds.count],
                x: .random(in: 0.04...0.96),
                scale: .random(in: 0.6...1.2),
                delay: delay,
                fall: .random(in: 1.3...(Motion.rain - delay)),
                drift: .random(in: -40...40),
                spin: .random(in: -25...25),
                turn: .random(in: -90...90)
            )
        }
    }
}

/// Canvas over a timeline: no per-frame state, four resolved glyphs drawn
/// many times. Reduce Motion: one emoji at centre scales in and fades.
private struct CompetitionReactionRainView: View {
    let rain: CompetitionReactionRainDrops

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(rain.start)
            Canvas { context, size in
                if reduceMotion {
                    drawStill(rain.kinds.first ?? .clap, elapsed: elapsed, in: &context, size: size)
                } else {
                    for drop in rain.drops {
                        draw(drop, elapsed: elapsed, in: &context, size: size)
                    }
                }
            } symbols: {
                ForEach(CompetitionReactionKind.allCases, id: \.self) { kind in
                    Text(kind.emoji).font(.system(size: 48)).tag(kind)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }

    private func draw(
        _ drop: CompetitionReactionRainDrops.Drop,
        elapsed: Double,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let progress = (elapsed - drop.delay) / drop.fall
        guard progress > 0, progress < 1,
              let glyph = context.resolveSymbol(id: drop.kind)
        else { return }
        // Falls from above the top to below the bottom, gathering speed.
        let fallen = 0.35 * progress + 0.65 * progress * progress
        var drawing = context
        drawing.translateBy(
            x: drop.x * size.width + drop.drift * progress,
            y: -60 + (size.height + 120) * fallen
        )
        drawing.rotate(by: .degrees(drop.spin + drop.turn * progress))
        drawing.scaleBy(x: drop.scale, y: drop.scale)
        drawing.draw(glyph, at: .zero)
    }

    private func drawStill(
        _ kind: CompetitionReactionKind,
        elapsed: Double,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard let glyph = context.resolveSymbol(id: kind) else { return }
        // In over a fade's length and a bit, out over the last half second.
        let grown = min(max(elapsed / 0.3, 0), 1)
        let scale = 1.4 + 0.6 * (1 - pow(1 - grown, 3))
        var drawing = context
        drawing.opacity = min(max((Motion.rain - elapsed) / 0.5, 0), 1)
        drawing.translateBy(x: size.width / 2, y: size.height / 2)
        drawing.scaleBy(x: scale, y: scale)
        drawing.draw(glyph, at: .zero)
    }
}
