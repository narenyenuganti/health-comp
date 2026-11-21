import SwiftUI
import WatchKit

struct WatchRootView: View {
    @ObservedObject var model: WatchSnapshotModel

    enum Screen: Hashable { case board(UUID), week(UUID) }

    @Environment(\.scenePhase) private var scenePhase
    @State private var drawn: CompetitionWidgetSnapshot?
    @State private var path: [Screen] = []

    init(model: WatchSnapshotModel) {
        self.model = model
        _drawn = State(initialValue: model.snapshot)
    }

    var body: some View {
        NavigationStack(path: $path) {
            WatchScreen(model: model, screen: nil, drawn: $drawn, path: $path)
                .navigationDestination(for: Screen.self) { screen in
                    WatchScreen(model: model, screen: screen, drawn: $drawn, path: $path)
                }
        }
        .onChange(of: model.snapshot) { _, next in
            if scenePhase == .active { drawn = next }
        }
        .onChange(of: drawn) {
            let kept = Self.pruned(path, drawn: drawn, at: Date())
            if kept != path { path = kept }
            openTappedAlert()
        }
        .onChange(of: model.tappedAlert, initial: true) { openTappedAlert() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.refresh()
                drawn = model.snapshot
            case .background:
                path = []
                model.tappedAlert = nil
            default:
                break
            }
        }
    }

    static func pruned(_ path: [Screen], drawn: CompetitionWidgetSnapshot?, at date: Date) -> [Screen] {
        let pages = drawn?.pages(at: date) ?? []
        return path.filter { screen in
            switch screen {
            case let .board(id): pages.count > 1 && pages.contains { $0.id == id }
            case let .week(id): pages.first { $0.id == id }?.hasWeek(at: date) == true
            }
        }
    }

    private func openTappedAlert() {
        guard let id = model.tappedAlert else { return }
        let pages = drawn?.pages(at: Date()) ?? []
        guard pages.contains(where: { $0.id == id }) else { return }
        model.tappedAlert = nil
        path = pages.count > 1 ? [.board(id)] : []
    }
}

private struct WatchScreen: View {
    @ObservedObject var model: WatchSnapshotModel
    let screen: WatchRootView.Screen?
    @Binding var drawn: CompetitionWidgetSnapshot?
    @Binding var path: [WatchRootView.Screen]

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(at: context.date)
        }
        .containerBackground(Color.black, for: .navigation)
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        let pages = drawn?.pages(at: date) ?? []
        switch screen {
        case nil:
            ZStack {
                if pages.count > 1 {
                    WatchCard(model: model, pages: pages, date: date)
                        .transition(.opacity)
                } else if let only = pages.first {
                    board(only, at: date, isCurrent: path.isEmpty)
                        .transition(.opacity)
                } else if case let .empty(text) = CompetitionWidgetSnapshot.content(drawn, personID: nil, at: date) {
                    WatchNothingView(text: text)
                        .transition(.opacity)
                }
            }
            .animation(Motion.fade, value: min(pages.count, 2))
        case let .board(id)?:
            if let match = pages.first(where: { $0.id == id }) {
                board(match, at: date, isCurrent: path.last == screen)
                    .padding(.top, 12)
            } else {
                gone(at: date)
            }
        case let .week(id)?:
            if let match = pages.first(where: { $0.id == id }), match.hasWeek(at: date) {
                WatchWeekView(match: match)
            } else {
                gone(at: date)
            }
        }
    }

    private func gone(at date: Date) -> some View {
        Color.clear.onAppear {
            let kept = WatchRootView.pruned(path, drawn: drawn, at: date)
            if kept != path { path = kept }
        }
    }

    private func board(_ match: CompetitionWidgetSnapshot.Match, at date: Date, isCurrent: Bool) -> some View {
        let hasWeek = match.hasWeek(at: date)
        return WatchBoardPage(model: model, match: match, date: date, isCurrent: isCurrent)
            .contentShape(Rectangle())
            .onTapGesture { if hasWeek { path.append(.week(match.id)) } }
            .accessibilityAddTraits(hasWeek ? .isButton : [])
            .accessibilityHint(hasWeek ? "Shows the week" : "")
            .accessibilityAction { if hasWeek { path.append(.week(match.id)) } }
    }
}

private struct WatchCard: View {
    @ObservedObject var model: WatchSnapshotModel
    let pages: [CompetitionWidgetSnapshot.Match]
    let date: Date

    @ScaledMetric(relativeTo: .body) private var valueSize: CGFloat = 22
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(pages, id: \.id) { match in
                    let row = match.cardRow(at: date, firstSight: model.seen.isFirstSight(of: match, at: date))
                    NavigationLink(value: WatchRootView.Screen.board(match.id)) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name)
                                    .themeLabel()
                                    .textCase(.uppercase)
                                    .privacySensitive(match.group == nil)
                                Text(row.line)
                                    .font(.footnote)
                                    .privacySensitive()
                            }
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(typeSize < .accessibility1 ? 1 : 2)
                            Spacer(minLength: 0)
                            Text(row.value)
                                .font(.score(size: valueSize))
                                .foregroundStyle(row.isYours ? Theme.you : Theme.ink)
                                .lineLimit(1)
                                .fixedSize()
                                .privacySensitive()
                        }
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Theme.outline).frame(height: 1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.spoken)
                    .accessibilityIdentifier("watch.card.row")
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("watch.card")
    }
}

private struct WatchWeekView: View {
    let match: CompetitionWidgetSnapshot.Match

    @ScaledMetric(relativeTo: .body) private var pointsSize: CGFloat = 15
    @ScaledMetric(relativeTo: .footnote) private var dayWidth: CGFloat = 24

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    label(match.name)
                        .privacySensitive()
                    label(" · Week")
                        .layoutPriority(1)
                }
                ForEach(Array(match.weekRows().enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        label(row.day)
                            .frame(width: dayWidth, alignment: .leading)
                        points(row.you, Theme.you)
                        Spacer(minLength: 8)
                        points(row.them, Theme.ink)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        row.you == nil && row.them == nil
                            ? "\(row.spoken). No points."
                            : "\(row.spoken). You \(row.you ?? "no points"). \(match.name) \(row.them ?? "no points")."
                    )
                }
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("watch.week")
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .themeLabel()
            .textCase(.uppercase)
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
    }

    private func points(_ text: String?, _ color: Color) -> some View {
        Text(text ?? "–")
            .font(.score(size: pointsSize))
            .foregroundStyle(text == nil ? Theme.secondary : color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .privacySensitive()
    }
}

private struct WatchBoardPage: View {
    @ObservedObject var model: WatchSnapshotModel
    let match: CompetitionWidgetSnapshot.Match
    let date: Date
    let isCurrent: Bool

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
    private var spokenCard: String? {
        guard voiceOver, let card = match.beltCardText else { return nil }
        return ([card.line] + card.detail).map { $0 + "." }.joined(separator: " ")
    }

    private var numberRests: Bool { isFirstSight || stage >= .cardLeaving }
    private var verdictRests: Bool { isFirstSight || stage > .done }
    private var barsRest: Bool { numberRests && !reduceMotion }
    private var cardIsUp: Bool { cardText != nil && (isFirstSight || stage == .card) }

    var body: some View {
        let status = match.boardStatus(at: date)
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if let group = match.group {
                    groupBoard(group, status: status).transition(Motion.appear)
                } else if match.state(at: date) == .scheduled {
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
            [match.accessibilityLabel(at: date, redacted: false, standings: true), match.chase(at: date)?.spoken,
             spokenCard, match.beltAccessibilityText]
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

    @MainActor
    private func reveal() async {
        guard stage == .done else { return }
        let card = match.belt?.card
        let showsCard = cardText != nil
        stage = showsCard ? .card : .verdictHeld
        try? await Task.sleep(for: .milliseconds(50))
        model.markSeen(match.id)
        if showsCard {
            cardRuns = true
            let firstBeat = reduceMotion ? 0 : 0.25
            try? await Task.sleep(for: .seconds(firstBeat))
            if case .lost = card { losses += 1 } else { wins += 1 }
            try? await Task.sleep(for: .seconds(WatchBeltCard.onScreen(reduceMotion: reduceMotion) - firstBeat))
            withAnimation(Motion.fade) { stage = .cardLeaving }
            try? await Task.sleep(for: .seconds(0.2))
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
            ZStack(alignment: .topLeading) {
                if let chase = match.chase(at: date) {
                    chaseBar(chase).transition(Motion.appear)
                } else {
                    lead.transition(Motion.appear)
                }
            }
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

    private func groupBoard(_ group: CompetitionWidgetSnapshot.Group, status: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                label("\(group.title) · \(status)")
                ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(group.isDoubles ? row.name : "\(row.place) \(row.name)")
                            .fontWeight(row.isYou ? .bold : .regular)
                            .lineLimit(1)
                            .privacySensitive(row.namesSomeone)
                        Spacer(minLength: 4)
                        Text(competitionPointsText(row.points))
                            .font(.score(size: 20))
                            .lineLimit(1)
                            .scoreRoll(row.points, id: "\(match.id)/\(row.name)")
                            .privacySensitive()
                    }
                    .foregroundStyle(row.isYou ? Theme.you : Theme.ink)
                }
                if let lead = group.lead, typeSize < .accessibility1 {
                    Text(lead)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .privacySensitive()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func scheduled(_ status: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(status)
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
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .themeLabel()
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

    private var numberAnimation: Animation? {
        numberRests ? nil : reduceMotion ? Motion.fade : Motion.beat(1)
    }

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

    private func chaseBar(_ chase: CompetitionWatchChase) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lead = chase.lead {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(lead)
                        .font(.score(size: 30))
                        .foregroundStyle(Theme.you)
                        .lineLimit(1)
                        .scoreRoll(match.chase?.points, id: match.id)
                    label("to lead")
                }
            }
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.outline)
                Rectangle().fill(Theme.youFill)
                    .scaleEffect(x: chase.fill, anchor: .leading)
                    .moving(Motion.settle, value: chase.fill)
            }
            .frame(height: 12)
            .clipShape(SlantedBar())
            if chase.lead == nil || typeSize < .accessibility1 {
                Text(chase.line)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(typeSize < .accessibility1 ? 1 : 2)
            }
        }
        .privacySensitive()
    }

    private var lead: some View {
        leadText
            .font(.footnote)
            .foregroundStyle(Theme.secondary)
            .lineLimit(typeSize < .accessibility1 ? 1 : 2)
            .minimumScaleFactor(0.8)
            .truncationMode(.middle)
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

private struct WatchBeltCard: View {
    let match: CompetitionWidgetSnapshot.Match
    let text: (headline: String, line: String, detail: [String])
    let runs: Bool
    let reduceMotion: Bool

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
                WatchBeltPlate(gold: !isMine || defended != nil)
                WatchBeltPlate(gold: isMine)
                    .opacity(runs ? 1 : 0)
                    .animation(beat(0), value: runs)
            }
            .frame(maxWidth: 113, alignment: .leading)
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

private struct WatchBeltPlate: View {
    let gold: Bool

    private static let bars: [[CGPoint]] = (MarkPolygon.bars + [MarkPolygon.block])
        .map { $0.map { CGPoint(x: $0.0, y: $0.1) } }

    private func color(_ hex: UInt32) -> Color { Color(uiColor: UIColor(hex: hex)) }

    var body: some View {
        let strap = color(gold ? 0x241A0E : 0x1E1F22)
        let stitch = color(gold ? 0x8A6414 : 0x55575C)
        let frame = color(gold ? 0xC98A12 : 0x8A8C91)
        let fills = gold
            ? [Theme.move, Theme.exercise, Theme.stand, Theme.youFill]
            : ([0x45464A, 0x66686C, 0x2C2D30, 0x74767B] as [UInt32]).map { color($0) }
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
