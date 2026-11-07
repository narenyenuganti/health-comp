import SwiftUI
import WatchKit

/// The Board or Nothing to show. `drawn` trails the store, so a delivery with
/// the wrist down doesn't touch the screen until you look.
struct WatchRootView: View {
    @ObservedObject var model: WatchSnapshotModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var drawn: CompetitionWidgetSnapshot?
    @State private var selection: UUID?

    init(model: WatchSnapshotModel) {
        self.model = model
        _drawn = State(initialValue: model.snapshot)
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(at: context.date)
        }
        .onChange(of: model.snapshot) { _, next in
            if scenePhase == .active { drawn = next }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.refresh()
                drawn = model.snapshot
            case .background:
                selection = nil
            default:
                break
            }
        }
    }

    private func content(at date: Date) -> some View {
        let pages = drawn?.pages(at: date) ?? []
        return ZStack {
            if let first = pages.first {
                board(pages, current: pages.first { $0.id == selection } ?? first, at: date)
                    .transition(.opacity)
            } else if case let .empty(text) = CompetitionWidgetSnapshot.content(drawn, personID: nil, at: date) {
                WatchNothingView(text: text)
                    .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: pages.isEmpty)
    }

    @ViewBuilder
    private func board(
        _ pages: [CompetitionWidgetSnapshot.Match],
        current: CompetitionWidgetSnapshot.Match,
        at date: Date
    ) -> some View {
        if pages.count > 1 {
            TabView(selection: Binding(get: { current.id }, set: { selection = $0 })) {
                ForEach(pages, id: \.id) { match in
                    WatchBoardPage(model: model, match: match, date: date, isCurrent: match.id == current.id)
                        .tag(match.id)
                }
            }
            .tabViewStyle(.verticalPage)
            .containerBackground(Color.black, for: .tabView)
        } else {
            WatchBoardPage(model: model, match: current, date: date, isCurrent: true)
        }
    }
}

/// Who's ahead, by how much, on what day.
private struct WatchBoardPage: View {
    @ObservedObject var model: WatchSnapshotModel
    let match: CompetitionWidgetSnapshot.Match
    let date: Date
    /// The Crown's page. `TabView` builds its neighbours too.
    let isCurrent: Bool

    /// How far the first-result clock has run. First sight itself is derived
    /// from the store, so the rest state lands in the same update as the data.
    private enum Stage: Comparable { case done, verdictHeld, cardLeaving, card }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var stage = Stage.done
    @State private var cardRuns = false
    @State private var wins = 0
    @State private var losses = 0

    private var isLooking: Bool { isCurrent && scenePhase == .active }
    private var isFinal: Bool { if case .final = match.state(at: date) { true } else { false } }
    private var isFirstSight: Bool { model.seen.isFirstSight(of: match, at: date) }
    private var cardText: (headline: String, line: String, detail: [String])? {
        voiceOver ? nil : match.beltCardText
    }

    /// Your bars and number wait for the clock; the lead goes first on it.
    private var numberRests: Bool { isFirstSight || stage >= .cardLeaving }
    private var verdictRests: Bool { isFirstSight || stage > .done }
    private var barsRest: Bool { numberRests && !reduceMotion }
    private var cardIsUp: Bool { cardText != nil && (isFirstSight || stage == .card) }

    var body: some View {
        let status = match.boardStatus(at: date)
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if match.state(at: date) == .scheduled {
                    scheduled(status).transition(Motion.appear)
                } else {
                    board(status).transition(Motion.appear)
                }
            }
            .opacity(cardIsUp || stage == .cardLeaving ? 0 : 1)
            .animation(Motion.fade, value: cardIsUp || stage == .cardLeaving)
            if cardIsUp, let cardText {
                WatchBeltCard(
                    match: match, text: cardText, runs: cardRuns, reduceMotion: reduceMotion
                )
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [match.accessibilityLabel(at: date, redacted: false), match.beltAccessibilityText]
                .compactMap { $0 }.joined(separator: " ")
        )
        .accessibilityIdentifier("watch.match")
        .onChange(of: isFirstSight && isLooking, initial: true) { _, plays in
            if plays { Task { await reveal() } }
        }
        .sensoryFeedback(.success, trigger: wins)
        .sensoryFeedback(.impact(weight: .heavy), trigger: losses)
        .sensoryFeedback(trigger: match.side) { old, new in
            new == .you && old != .you && isLooking && !isFinal ? .increase : nil
        }
    }

    /// The first-result clock, once per match per device: card if earned, then
    /// bars, verdict and number. Seen is marked at t=0, so a dropped wrist
    /// never replays it.
    @MainActor
    private func reveal() async {
        let card = match.belt?.card
        let showsCard = cardText != nil
        stage = showsCard ? .card : .verdictHeld
        // A real frame at the rest state: Task.yield can merge with it.
        try? await Task.sleep(for: .milliseconds(50))
        model.markSeen(match.id)
        if showsCard {
            cardRuns = true
            // The card's one wrist tap lands on its first beat.
            let firstBeat = reduceMotion ? 0 : 0.25
            try? await Task.sleep(for: .seconds(firstBeat))
            if case .lost = card { losses += 1 } else { wins += 1 }
            try? await Task.sleep(for: .seconds(WatchBeltCard.onScreen(reduceMotion: reduceMotion) - firstBeat))
            withAnimation(Motion.fade) { stage = .cardLeaving }
            try? await Task.sleep(for: .seconds(0.2))  // one Motion.fade
            stage = .verdictHeld
            try? await Task.sleep(for: .milliseconds(50))
        }
        let won = match.state(at: date) == .final(.win)
        if reduceMotion, won, !showsCard { wins += 1 }
        withAnimation(reduceMotion ? Motion.fade : Motion.beat(0)) {
            stage = .done
        } completion: {
            if won, !showsCard, !reduceMotion { wins += 1 }
        }
    }

    // MARK: Layouts

    private func board(_ status: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(status)
            scores
            if let belt = match.belt {
                WatchBeltRow(holder: belt.holder, defenses: match.beltDefensesText)
                    .opacity(belt.holder == .you && numberRests ? Motion.pendingOpacity : 1)
                    .animation(numberAnimation, value: numberRests)
            }
            if typeSize < .accessibility1 {
                strip(status)
            }
            lead
                .padding(.top, 2)
            if match.isStale(at: date), let line = match.updatedLine(at: date) {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(typeSize < .accessibility1 ? 1 : 2)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .animation(Motion.fade, value: match.isStale(at: date))
    }

    private func scheduled(_ status: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(status)
                .padding(.trailing, 12)
            Text(match.name)
                .font(.title2.weight(.heavy).width(.condensed))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .privacySensitive()
            if typeSize < .accessibility1 {
                CompetitionMatchStrip(match: match, date: date, height: 12, spacing: 4)
            }
            Spacer(minLength: 0)
        }
    }

    private func header(_ status: String) -> some View {
        HStack(spacing: 0) {
            label(match.name)
                .privacySensitive()
            label(" · \(status)")
                .layoutPriority(1)
                .contentTransition(.opacity)
                .animation(Motion.fade, value: status)
        }
        .padding(.trailing, 12)  // the page dots
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.themeLabel)
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
    }

    private var scores: some View {
        let you = match.userPointsText()
        let them = match.opponentPointsText()
        let size = competitionWatchScoreSize(
            you: you, them: them, width: WKInterfaceDevice.current().screenBounds.width - 20
        )
        return HStack(alignment: .lastTextBaseline, spacing: 0) {
            number(you, match.userPoints, Theme.you)
                .opacity(numberRests ? Motion.pendingOpacity : 1)
                .animation(numberAnimation, value: numberRests)
            Spacer(minLength: 8)
            number(them, match.opponentPoints, Theme.ink)
        }
        .font(.score(size: size))
    }

    private func number(_ text: String, _ points: Double, _ color: Color) -> some View {
        Text(text)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .privacySensitive()
            .scoreRoll(points, id: match.id)
    }

    /// Only out of rest: into it must land at once, or a live match going
    /// final shows your number first.
    private var numberAnimation: Animation? {
        numberRests ? nil : reduceMotion ? Motion.fade : Motion.beat(1)
    }

    /// The bars fade to a new day through the ZStack, and your won bars grow
    /// on a first result.
    private func strip(_ status: String) -> some View {
        ZStack {
            CompetitionMatchStrip(match: match, date: date, height: 12, spacing: 4) { index, outcome, bar in
                bar
                    .scaleEffect(x: outcome == .won && barsRest ? 0 : 1, anchor: .trailing)
                    .moving(Motion.grow(index, of: 7), value: barsRest)
            }
            .id(status)
            .transition(.opacity)
        }
        .animation(Motion.fade, value: status)
    }

    private var lead: some View {
        leadText
            .font(.footnote)
            .foregroundStyle(Theme.secondary)
            .lineLimit(typeSize < .accessibility1 ? 1 : 2)
            .privacySensitive()
            .contentTransition(.opacity)
            .animation(Motion.late, value: match.side)
            .opacity(verdictRests ? Motion.pendingOpacity : 1)
    }

    private var leadText: Text {
        if isFinal {
            Text(match.leadLine(at: date) ?? "Tied")
        } else {
            competitionLeadText(
                userPoints: match.userPoints,
                opponentPoints: match.opponentPoints,
                opponentDisplayName: match.name
            )
        }
    }
}

/// The small belt under whoever holds it, with their defense count.
private struct WatchBeltRow: View {
    let holder: CompetitionWidgetSnapshot.Belt.Holder
    let defenses: String?

    var body: some View {
        HStack(spacing: 4) {
            if holder == .them { Spacer(minLength: 0) }
            if holder == .you { WatchBeltPlate(gold: true) }
            if let defenses {
                Text(defenses)
                    .font(.caption2.weight(.heavy).width(.condensed))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(holder == .you ? Theme.you : Theme.secondary)
                    .lineLimit(1)
            }
            if holder == .them { WatchBeltPlate(gold: false) }
        }
        .frame(height: 15)
    }
}

/// The belt moment on the wrist. It covers the Board for about two seconds on
/// the first result that moves the belt. Its copy and hold are the sanctioned
/// numbers outside Motion.swift.
private struct WatchBeltCard: View {
    let match: CompetitionWidgetSnapshot.Match
    let text: (headline: String, line: String, detail: [String])
    let runs: Bool
    let reduceMotion: Bool

    /// Until the card starts to leave: its beats, then 1.2 s to read it.
    static func onScreen(reduceMotion: Bool) -> Double {
        (reduceMotion ? 0.2 : 0.75) + 1.2
    }

    private var card: CompetitionWidgetSnapshot.Belt.Card? { match.belt?.card }
    private var isMine: Bool {
        if case .lost = card { false } else { true }
    }
    private var defended: Int? {
        if case let .defended(count) = card { count } else { nil }
    }

    private func beat(_ step: Int) -> Animation {
        reduceMotion ? Motion.fade : Motion.beat(step)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                // The plate you see last week, then the new holder's over it.
                WatchBeltPlate(gold: !isMine || defended != nil)
                WatchBeltPlate(gold: isMine)
                    .opacity(runs ? 1 : 0)
                    .animation(beat(0), value: runs)
            }
            .frame(maxWidth: 113, alignment: .leading)  // gives way to the words on small watches
            .padding(.bottom, 5)
            Text(text.headline)
                .font(.score(size: 42))
                .foregroundStyle(isMine ? Theme.you : Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .opacity(runs ? 1 : 0)
                .animation(beat(1), value: runs)
                .layoutPriority(1)
            Group {
                Text(text.line)
                    .font(.headline.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if !text.detail.isEmpty {
                    Text(text.detail.joined(separator: "\n"))
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .privacySensitive()
                }
                if let defended {
                    pips(defended)
                }
            }
            .opacity(runs ? 1 : 0)
            .animation(beat(2), value: runs)
            .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .ignoresSafeArea(edges: .bottom)
    }

    /// One slanted bar per defense; the newest grows on the first beat.
    private func pips(_ count: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                SlantedBar()
                    .fill(Theme.youFill)
                    .frame(width: 11, height: 9)
                    .scaleEffect(x: index == count - 1 && !runs && !reduceMotion ? 0 : 1, anchor: .trailing)
                    .moving(Motion.grow.delay(0.25), value: runs)
            }
        }
        .padding(.top, 3)
    }
}

/// The Belt tab's mark at watch size, gold when you hold it, pewter when they
/// do. The art's own colours, in the mark's 100×80 box with a strap stub each side.
private struct WatchBeltPlate: View {
    let gold: Bool

    private static let bars: [[CGPoint]] = [
        [(17.4, 8), (57.4, 8), (53.8, 26), (13.8, 26)],
        [(22.8, 31), (52.8, 31), (49.2, 49), (19.2, 49)],
        [(12.2, 54), (48.2, 54), (44.6, 72), (8.6, 72)],
        [(63.4, 8), (91.4, 8), (78.6, 72), (50.6, 72)],
    ].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }

    private func color(_ hex: UInt32) -> Color { Color(uiColor: UIColor(hex: hex)) }

    var body: some View {
        let strap = color(gold ? 0x241A0E : 0x1E1F22)
        let stitch = color(gold ? 0x8A6414 : 0x55575C)
        let frame = color(gold ? 0xC98A12 : 0x8A8C91)
        let fills = (gold ? [0xE4003A, 0x009A4E, 0x0072BC, 0xF2A100] : [0x45464A, 0x66686C, 0x2C2D30, 0x74767B])
            .map { color(UInt32($0)) }
        Canvas { context, size in
            context.scaleBy(x: size.width / 144, y: size.height / 80)
            context.translateBy(x: 22, y: 0)
            context.fill(Path(CGRect(x: -22, y: 21, width: 144, height: 38)), with: .color(strap))
            for y in [25.0, 55.0] {
                let line = Path { $0.addLines([CGPoint(x: -22, y: y), CGPoint(x: 122, y: y)]) }
                context.stroke(line, with: .color(stitch), lineWidth: 2.5)
            }
            for (bar, fill) in zip(Self.bars, fills) {
                let path = Path { $0.addLines(bar); $0.closeSubpath() }
                context.stroke(path, with: .color(frame), lineWidth: 5)
                context.fill(path, with: .color(frame))
                context.fill(path, with: .color(fill))
            }
        }
        .aspectRatio(144 / 80, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Says why there is no score.
private struct WatchNothingView: View {
    let text: CompetitionWidgetEmptyText

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if typeSize < .accessibility1 {
                BrandMark()
                    .frame(height: 44)
            }
            Text(text.title)
                .font(.title3.weight(.heavy).width(.condensed))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            if let line = text.line {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.accessibilityLabel)
        .accessibilityIdentifier("watch.empty")
    }
}
