import CompetitionCore
import Foundation
import SwiftUI

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

struct CompetitionReactionsSeen: RawRepresentable, Equatable {
    static let storageKey = "healthcomp.reactionsSeen"

    var seenAt: [String: TimeInterval]

    init() { seenAt = [:] }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let seenAt = try? JSONDecoder().decode([String: TimeInterval].self, from: data)
        else { return nil }
        self.seenAt = seenAt
    }

    var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(seenAt) else { return "{}" }
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

struct CompetitionMotionSeen: RawRepresentable, Equatable {
    static let storageKey = "healthcomp.motionSeen"

    var weekDrawn: [String: Int]

    init() { weekDrawn = [:] }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let weekDrawn = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return nil }
        self.weekDrawn = weekDrawn
    }

    var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(weekDrawn) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

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

extension CompetitionMotionSeen {
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

struct CompetitionReactionRainBatch: Equatable {
    let kinds: [CompetitionReactionKind]
    let announcement: String
}

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

func competitionReactionsInWeekOrder(_ reactions: [CompetitionReaction]) -> [CompetitionReaction] {
    reactions.sorted { lhs, rhs in
        let left = lhs.target.dayOrdinal ?? 0
        let right = rhs.target.dayOrdinal ?? 0
        if left != right { return left < right }
        return lhs.isFromYou && !rhs.isFromYou
    }
}

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

struct CompetitionReactionControl {
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

struct CompetitionReactionPicker: View {
    let selection: CompetitionReactionKind?
    let isPending: Bool
    let failed: Bool
    let select: (CompetitionReactionKind) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.competitionReactionRain) private var rain
    @ScaledMetric(relativeTo: .title2) private var chipSize: CGFloat = 48

    var body: some View {
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
        .onChange(of: isPending) { _, pending in
            if !pending, !failed, selection != nil { Sounds.play(.sent) }
        }
        .sensoryFeedback(.error, trigger: failed) { _, new in new }
    }

    private func chip(_ kind: CompetitionReactionKind) -> some View {
        let isSelected = selection == kind
        let hint: String = isSelected ? "Removes your reaction" : ""
        return Button {
            if !isSelected { rain(kind) }
            select(kind)
        } label: {
            Text(kind.emoji)
                .font(.title2)
                .frame(width: chipSize, height: chipSize)
                .background(Theme.control, in: Circle())
                .overlay {
                    Circle().strokeBorder(
                        isSelected ? Theme.you : Theme.hairline,
                        lineWidth: isSelected ? 2 : 1
                    )
                    .animation(Motion.fade, value: isSelected)
                }
                .contentShape(Circle())
        }
        .buttonStyle(CompetitionReactionChipStyle())
        .disabled(isPending)
        .accessibilityLabel(kind.spokenName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(hint)
        .accessibilityIdentifier("competition.react.\(kind.rawValue)")
    }
}

private struct CompetitionReactionChipStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onTapGesture(perform: configuration.trigger)
    }
}

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

struct CompetitionReactionEmoji: View {
    let kind: CompetitionReactionKind

    @ScaledMetric(relativeTo: .title3) private var size: CGFloat = 24
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let image = Self.cachedImage(kind: kind, size: size, displayScale: displayScale) {
            Image(decorative: image, scale: displayScale)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private struct CacheKey: Hashable {
        let kind: CompetitionReactionKind
        let size: CGFloat
        let displayScale: CGFloat
    }

    @MainActor
    private static var cache: [CacheKey: CGImage] = [:]

    @MainActor
    private static func cachedImage(
        kind: CompetitionReactionKind,
        size: CGFloat,
        displayScale: CGFloat
    ) -> CGImage? {
        let key = CacheKey(kind: kind, size: size, displayScale: displayScale)
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: Text(kind.emoji).font(.system(size: size)))
        renderer.scale = displayScale
        guard let image = renderer.cgImage else { return nil }
        cache[key] = image
        return image
    }
}

struct CompetitionReactionRainAction: Equatable {
    static let noop = Self(id: UUID(), perform: { _ in })

    let id: UUID
    private let perform: (CompetitionReactionKind) -> Void

    init(id: UUID, perform: @escaping (CompetitionReactionKind) -> Void) {
        self.id = id
        self.perform = perform
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func callAsFunction(_ kind: CompetitionReactionKind) {
        perform(kind)
    }
}

extension EnvironmentValues {
    @Entry var competitionReactionRain = CompetitionReactionRainAction.noop
}

extension View {
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
    @State private var actionID = UUID()

    func body(content: Content) -> some View {
        content
            .environment(
                \.competitionReactionRain,
                CompetitionReactionRainAction(id: actionID) { start([$0]) }
            )
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
    let start = Date.now
    let kinds: [CompetitionReactionKind]
    let drops: [Drop]

    init(kinds: [CompetitionReactionKind]) {
        self.kinds = kinds
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
        var drawing = context
        drawing.opacity = min(max(elapsed / 0.3, 0), 1, max((Motion.rain - elapsed) / 0.5, 0))
        drawing.translateBy(x: size.width / 2, y: size.height / 2)
        drawing.scaleBy(x: 2, y: 2)
        drawing.draw(glyph, at: .zero)
    }
}
