import SwiftUI
import WatchKit

enum WatchMatchPage: String, Hashable, CaseIterable {
    case overview
    case today
    case week
    case rivalry
}

struct WatchRootView: View {
    var model: WatchSnapshotModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var drawn: CompetitionWidgetSnapshot?
    @State private var selectedMatchID: UUID?
    @State private var showingList = false
    @State private var activePage: WatchMatchPage = .overview

    init(model: WatchSnapshotModel) {
        self.model = model
        _drawn = State(initialValue: model.snapshot)
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let page = zip(arguments, arguments.dropFirst()).first(where: { $0.0 == "--watch-page" })?.1 {
            if page == "list" {
                _showingList = State(initialValue: true)
            } else if let target = WatchMatchPage(rawValue: page) {
                _activePage = State(initialValue: target)
            }
        }
#endif
    }

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                rootContent(at: context.date)
            }
        }
        .onChange(of: model.snapshot) { _, next in
            if scenePhase == .active { drawn = next }
        }
        .onChange(of: drawn) {
            pruneSelection(at: Date.now)
            openTappedAlert()
        }
        .onChange(of: model.tappedAlert, initial: true) { openTappedAlert() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.refresh()
                drawn = model.snapshot
            case .background:
                showingList = false
                activePage = .overview
                model.tappedAlert = nil
            default:
                break
            }
        }
    }

    @ViewBuilder
    private func rootContent(at date: Date) -> some View {
        let pages = drawn?.pages(at: date) ?? []
        let current = pages.first { $0.id == selectedMatchID } ?? pages.first
        ZStack {
            if showingList, pages.count > 1 {
                WatchMatchesListView(
                    model: model,
                    pages: pages,
                    date: date,
                    selectedID: current?.id
                ) { id in
                    selectedMatchID = id
                    activePage = .overview
                    showingList = false
                }
                .transition(.opacity)
            } else if let match = current {
                WatchMatchPagerView(
                    model: model,
                    match: match,
                    date: date,
                    matchCount: pages.count,
                    activePage: $activePage,
                    openList: { showingList = true }
                )
                .id(match.id)
                .transition(.opacity)
            } else if case let .empty(text) = CompetitionWidgetSnapshot.content(drawn, personID: nil, at: date) {
                WatchNothingView(text: text, hasChallenge: drawn?.hasIncomingChallenge == true)
                    .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: showingList)
        .animation(Motion.fade, value: current?.id)
    }

    private func pruneSelection(at date: Date) {
        let pages = drawn?.pages(at: date) ?? []
        if pages.count <= 1 { showingList = false }
        if let id = selectedMatchID, !pages.contains(where: { $0.id == id }) {
            selectedMatchID = nil
            activePage = .overview
        }
    }

    private func openTappedAlert() {
        guard let id = model.tappedAlert else { return }
        let pages = drawn?.pages(at: Date.now) ?? []
        guard pages.contains(where: { $0.id == id }) else { return }
        model.tappedAlert = nil
        selectedMatchID = id
        showingList = false
        activePage = .overview
    }
}

private struct WatchMatchesListView: View {
    var model: WatchSnapshotModel
    let pages: [CompetitionWidgetSnapshot.Match]
    let date: Date
    let selectedID: UUID?
    let onSelect: (UUID) -> Void

    @ScaledMetric(relativeTo: .body) private var valueSize: CGFloat = 21
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(pages, id: \.id) { match in
                    let row = match.cardRow(at: date, firstSight: model.seen.isFirstSight(of: match, at: date))
                    Button { onSelect(match.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(row.name)
                                    .themeLabel(tracking: 0.6)
                                    .textCase(.uppercase)
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                    .privacySensitive(match.group == nil)
                                Spacer(minLength: 4)
                                Text(row.value)
                                    .font(.score(size: valueSize))
                                    .foregroundStyle(row.isYours ? Theme.you : Theme.ink)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .privacySensitive()
                            }
                            Text(row.line)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(typeSize < .accessibility1 ? 1 : 2)
                                .privacySensitive()
                            if typeSize < .accessibility1, match.group == nil, match.hasWeek(at: date) {
                                CompetitionMatchStrip(match: match, date: date, height: 5.5, spacing: 3)
                                    .padding(.top, 2)
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Theme.panel)
                                .overlay {
                                    if match.id == selectedID {
                                        RoundedRectangle(cornerRadius: 14)
                                            .strokeBorder(Theme.youFill.opacity(0.45), lineWidth: 1)
                                    }
                                }
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.spoken)
                    .accessibilityIdentifier("watch.card.row")
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 6)
        }
        .navigationTitle("Matches")
        .containerBackground(
            LinearGradient(
                colors: [Color(hex: 0x1D1D20), Color.black],
                startPoint: .top,
                endPoint: .bottom
            ),
            for: .navigation
        )
        .accessibilityIdentifier("watch.card")
    }
}

private struct WatchMatchPagerView: View {
    var model: WatchSnapshotModel
    let match: CompetitionWidgetSnapshot.Match
    let date: Date
    let matchCount: Int
    @Binding var activePage: WatchMatchPage
    let openList: () -> Void

    private var showsToday: Bool {
        match.group == nil && (match.activeTodayRings(at: date) != nil || match.chase(at: date) != nil)
    }

    private var showsWeek: Bool {
        if match.group != nil {
            return match.playedDayPoints(at: date).contains { $0.you != nil || $0.them != nil }
        }
        return match.hasWeek(at: date)
    }

    private var showsRivalry: Bool {
        match.group == nil && (match.rivalry != nil || match.belt != nil)
    }

    private var availablePages: [WatchMatchPage] {
        var list: [WatchMatchPage] = [.overview]
        if showsToday { list.append(.today) }
        if showsWeek { list.append(.week) }
        if showsRivalry { list.append(.rivalry) }
        return list
    }

    var body: some View {
        TabView(selection: $activePage) {
            if let group = match.group {
                WatchGroupOverviewPage(match: match, group: group, date: date)
                    .tag(WatchMatchPage.overview)
            } else if match.state(at: date) == .scheduled {
                WatchScheduledPage(match: match, date: date)
                    .tag(WatchMatchPage.overview)
            } else {
                WatchOverviewPage(
                    model: model,
                    match: match,
                    date: date,
                    isCurrent: activePage == .overview
                )
                .tag(WatchMatchPage.overview)
            }

            if showsToday {
                WatchTodayRingsPage(match: match, date: date)
                    .tag(WatchMatchPage.today)
            }

            if showsWeek {
                WatchWeekChartPage(match: match, date: date, isGroup: match.group != nil)
                    .tag(WatchMatchPage.week)
            }

            if showsRivalry {
                WatchRivalryPage(match: match, date: date)
                    .tag(WatchMatchPage.rivalry)
            }
        }
        .tabViewStyle(.verticalPage(transitionStyle: .blur))
        .onChange(of: availablePages) { _, pages in
            if !pages.contains(activePage) { activePage = .overview }
        }
        .toolbar {
            if matchCount > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: openList) {
                        Image(systemName: "list.bullet")
                            .font(.footnote.weight(.bold))
                    }
                    .accessibilityLabel("Matches")
                    .accessibilityIdentifier("watch.matches.button")
                }
            }
        }
    }
}

private struct WatchOverviewPage: View {
    var model: WatchSnapshotModel
    let match: CompetitionWidgetSnapshot.Match
    let date: Date
    let isCurrent: Bool

    private enum Stage: Comparable { case done, verdictHeld, cardLeaving, card }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var capsuleScoreSize: CGFloat = 19
    @ScaledMetric(relativeTo: .footnote) private var capsuleDeltaSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var chaseLeadSize: CGFloat = 22
    @State private var stage = Stage.done
    @State private var cardRuns = false
    @State private var wins = 0
    @State private var losses = 0

    private var isCompact: Bool { WKInterfaceDevice.current().screenBounds.width < 175 }
    private var isLooking: Bool { isCurrent && scenePhase == .active }
    private var isLeading: Bool { match.side == .you }
    private var isTrailing: Bool { match.side == .them }
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

    private var washColor: Color {
        if isLeading { return Theme.youFill.opacity(0.24) }
        if isTrailing { return Color(hex: 0x3A3D46).opacity(0.45) }
        return Color(hex: 0x2C2C30).opacity(0.4)
    }

    var body: some View {
        let status = match.status(at: date, compact: isFinal)
        ZStack(alignment: .topLeading) {
            overviewContent(status)
                .opacity(cardIsUp || stage == .cardLeaving ? 0 : 1)
                .animation(Motion.fade, value: cardIsUp || stage == .cardLeaving)
            if cardIsUp, let cardText {
                WatchBeltCard(
                    match: match, text: cardText, runs: cardRuns, reduceMotion: reduceMotion
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(
            LinearGradient(
                colors: [washColor, Color(hex: 0x0B0B0D)],
                startPoint: .topLeading,
                endPoint: .bottom
            ),
            for: .tabView
        )
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

    @ViewBuilder
    private func overviewContent(_ status: String) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 5 : 7) {
            HStack(spacing: 6) {
                Text(status)
                    .font(.caption2.weight(.heavy).width(.condensed))
                    .tracking(0.9)
                    .textCase(.uppercase)
                    .foregroundStyle(isLeading ? Theme.you : Theme.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(Motion.fade, value: status)
                Spacer(minLength: 4)
                if let belt = match.belt {
                    HStack(spacing: 4) {
                        WatchBeltPlate(gold: belt.holder == .you)
                            .frame(height: isCompact ? 11 : 13)
                        if belt.defenses > 0 {
                            Text("\(belt.defenses)×")
                                .font(.caption2.weight(.heavy).width(.condensed))
                                .foregroundStyle(belt.holder == .you ? Theme.you : Theme.secondary)
                        }
                    }
                    .opacity(belt.holder == .you && numberRests ? Motion.pendingOpacity : 1)
                    .animation(numberAnimation, value: numberRests)
                }
            }
            .padding(.top, isCompact ? 6 : 8)

            scores

            if typeSize < .accessibility1 {
                roundStrip(status)
            }

            bottomCapsule

            if match.isStale(at: date), let line = match.updatedLine(at: date) {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(typeSize < .accessibility1 ? 1 : 2)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .animation(Motion.fade, value: match.isStale(at: date))
    }

    private var scores: some View {
        let you = match.userPointsText()
        let them = match.opponentPointsText()
        let rawSize = competitionWatchScoreSize(
            you: you, them: them, width: WKInterfaceDevice.current().screenBounds.width - 42
        )
        let scoreSize = min(rawSize, isCompact ? 34 : 44)
        return HStack(alignment: .bottom, spacing: 6) {
            VStack(alignment: .leading, spacing: -1) {
                Text("YOU")
                    .font(.caption2.weight(.bold).width(.condensed))
                    .tracking(0.8)
                    .foregroundStyle(Theme.you.opacity(0.85))
                    .lineLimit(1)
                number(you, match.userPoints, Theme.you, size: scoreSize)
                    .opacity(numberRests ? Motion.pendingOpacity : 1)
                    .animation(numberAnimation, value: numberRests)
            }
            Spacer(minLength: 4)
            SlantedBar()
                .fill(Theme.outline.opacity(0.65))
                .frame(width: 2.5, height: scoreSize * 0.72)
                .padding(.bottom, 5)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: -1) {
                Text(match.name)
                    .font(.caption2.weight(.bold).width(.condensed))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .privacySensitive()
                number(them, match.opponentPoints, Theme.ink, size: scoreSize)
            }
        }
    }

    private func number(_ text: String, _ points: Double, _ color: Color, size: CGFloat) -> some View {
        Text(text)
            .font(.score(size: size))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .privacySensitive()
            .scoreRoll(points, id: match.id)
    }

    private var numberAnimation: Animation? {
        numberRests ? nil : reduceMotion ? Motion.fade : Motion.beat(1)
    }

    private func roundStrip(_ status: String) -> some View {
        let days = match.playedDayPoints(at: date)
        return VStack(spacing: 3) {
            ZStack {
                CompetitionMatchStrip(match: match, date: date, height: isCompact ? 10 : 12, spacing: 3.5) { index, outcome, bar in
                    bar
                        .scaleEffect(x: outcome == .won && barsRest ? 0 : 1, anchor: .trailing)
                        .moving(Motion.grow(index, of: 7), value: barsRest)
                }
                .id(status)
                .transition(.opacity)
            }
            .animation(Motion.fade, value: status)

            HStack(spacing: 3.5) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, row in
                    Text(row.day)
                        .font(.caption2.weight(row.isToday ? .heavy : .semibold).width(.condensed))
                        .foregroundStyle(row.isToday ? Theme.ink : Theme.tertiary)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }

    @ViewBuilder
    private var bottomCapsule: some View {
        if let chase = match.chase(at: date) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let lead = chase.lead {
                        Text(lead)
                            .font(.score(size: isCompact ? max(18, chaseLeadSize - 3) : chaseLeadSize))
                            .foregroundStyle(Theme.you)
                            .lineLimit(1)
                            .scoreRoll(match.chase?.points, id: match.id)
                        Text("TO LEAD")
                            .font(.caption2.weight(.bold).width(.condensed))
                            .tracking(0.7)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(chase.line.replacingOccurrences(of: " today", with: ""))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.track)
                    Rectangle().fill(Theme.youFill)
                        .scaleEffect(x: max(chase.fill, chase.lead == nil ? 0 : 0.05), anchor: .leading)
                        .moving(Motion.settle, value: chase.fill)
                }
                .frame(height: 8)
                .clipShape(SlantedBar())
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.panel.opacity(0.92))
            )
            .privacySensitive()
        } else if isFinal {
            Text(match.leadLine(at: date) ?? "Tied")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isLeading ? Theme.you : Theme.ink)
                .lineLimit(typeSize < .accessibility1 ? 1 : 2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, isCompact ? 6 : 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.panel.opacity(0.92))
                )
                .privacySensitive()
                .opacity(verdictRests ? Motion.pendingOpacity : 1)
                .animation(Motion.late, value: verdictRests)
        } else {
            let margin = competitionDisplayedMargin(
                userPoints: match.userPoints, opponentPoints: match.opponentPoints
            )
            let today = match.todayScores(at: date)
            let todayDelta: Double? = if let u = today.you, let t = today.them {
                competitionDisplayedMargin(userPoints: u, opponentPoints: t)
            } else {
                nil
            }
            HStack(spacing: 6) {
                if margin == 0 {
                    Text("ALL SQUARE")
                        .font(.caption2.weight(.heavy).width(.condensed))
                        .tracking(0.6)
                        .foregroundStyle(Theme.ink)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(margin > 0 ? "UP" : "DOWN")
                            .font(.caption2.weight(.heavy).width(.condensed))
                            .tracking(0.6)
                            .foregroundStyle(Theme.secondary)
                        Text(competitionPointsText(abs(margin)))
                            .font(.score(size: isCompact ? max(16, capsuleScoreSize - 2) : capsuleScoreSize))
                            .foregroundStyle(margin > 0 ? Theme.you : Theme.ink)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let delta = todayDelta {
                    let prefix = delta > 0 ? "+" : delta < 0 ? "\u{2212}" : ""
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("TODAY")
                            .font(.caption2.weight(.bold).width(.condensed))
                            .tracking(0.5)
                            .foregroundStyle(Theme.tertiary)
                        Text("\(prefix)\(competitionPointsText(abs(delta)))")
                            .font(.score(size: isCompact ? max(14, capsuleDeltaSize - 1) : capsuleDeltaSize))
                            .foregroundStyle(delta >= 0 ? Theme.you : Theme.ink)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, isCompact ? 6 : 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.panel.opacity(0.92))
            )
            .privacySensitive()
            .contentTransition(.opacity)
            .animation(Motion.late, value: match.side)
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
}

private struct WatchTodayRingsPage: View {
    let match: CompetitionWidgetSnapshot.Match
    let date: Date

    @ScaledMetric(relativeTo: .body) private var scoreSize: CGFloat = 19
    @ScaledMetric(relativeTo: .footnote) private var ringPointsSize: CGFloat = 15

    private var isCompact: Bool { WKInterfaceDevice.current().screenBounds.width < 175 }
    private var isTrailing: Bool { match.side == .them }

    private func ringColor(_ kind: CompetitionWidgetSnapshot.TodayRings.RingKind) -> Color {
        switch kind {
        case .move: Theme.move
        case .exercise: Theme.exercise
        case .stand: Theme.stand
        case .sleep: Theme.sleep
        }
    }

    var body: some View {
        let today = match.todayScores(at: date)
        let chase = match.chase(at: date)
        let rings = match.activeTodayRings(at: date)

        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 5 : 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("TODAY")
                        .themeLabel(tracking: 1.0)
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    if today.you != nil || today.them != nil {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(today.you.map { competitionPointsText($0) } ?? "–")
                                .font(.score(size: isCompact ? max(16, scoreSize - 2) : scoreSize))
                                .foregroundStyle(Theme.you)
                            Text("–")
                                .font(.caption2.bold())
                                .foregroundStyle(Theme.tertiary)
                            Text(today.them.map { competitionPointsText($0) } ?? "–")
                                .font(.score(size: isCompact ? max(16, scoreSize - 2) : scoreSize))
                                .foregroundStyle(Theme.ink)
                        }
                        .privacySensitive()
                    }
                }
                .padding(.top, isCompact ? 4 : 6)

                if let chase {
                    VStack(alignment: .leading, spacing: 2) {
                        if let lead = chase.lead {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("+\(lead)")
                                    .font(.score(size: isCompact ? max(17, scoreSize - 1) : scoreSize))
                                    .foregroundStyle(Theme.you)
                                Text("TO LEAD")
                                    .font(.caption2.weight(.heavy).width(.condensed))
                                    .tracking(0.7)
                                    .foregroundStyle(Theme.ink)
                            }
                            if let suggestion = chase.suggestion {
                                Text(suggestion)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(chase.line)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.secondary)
                            }
                        } else {
                            Text(chase.line)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 11)
                            .fill(Theme.youFill.opacity(0.16))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11)
                                    .strokeBorder(Theme.youFill.opacity(0.45), lineWidth: 1)
                            }
                    )
                    .privacySensitive()
                }

                if let rings {
                    VStack(spacing: isCompact ? 4 : 6) {
                        ForEach(Array(rings.rows.enumerated()), id: \.offset) { _, row in
                            let color = ringColor(row.kind)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(row.title)
                                        .font(.caption2.weight(.heavy).width(.condensed))
                                        .tracking(0.5)
                                        .textCase(.uppercase)
                                        .foregroundStyle(color)
                                        .lineLimit(1)
                                    Text(row.detail)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .privacySensitive()
                                    Spacer(minLength: 2)
                                    if let points = row.points {
                                        Text(competitionPointsText(points))
                                            .font(.score(size: isCompact ? max(13, ringPointsSize - 2) : ringPointsSize))
                                            .foregroundStyle(Theme.ink)
                                            .privacySensitive()
                                    }
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        SlantedBar().fill(Theme.track)
                                        SlantedBar()
                                            .fill(color)
                                            .frame(width: row.progress > 0 ? max(8, geo.size.width * min(1, row.progress)) : 0)
                                    }
                                }
                                .frame(height: isCompact ? 5 : 6)
                            }
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, isCompact ? 6 : 7)
                    .background(
                        RoundedRectangle(cornerRadius: 13)
                            .fill(Theme.panel.opacity(0.92))
                    )
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
        .containerBackground(
            LinearGradient(
                colors: [
                    (isTrailing ? Theme.move : Theme.exercise).opacity(0.22),
                    Color(hex: 0x0B0B0D),
                ],
                startPoint: .topLeading,
                endPoint: .bottom
            ),
            for: .tabView
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watch.today")
    }
}

private struct WatchWeekChartPage: View {
    let match: CompetitionWidgetSnapshot.Match
    let date: Date
    let isGroup: Bool

    @ScaledMetric(relativeTo: .body) private var statSize: CGFloat = 19
    @ScaledMetric(relativeTo: .body) private var pointsSize: CGFloat = 15
    @ScaledMetric(relativeTo: .footnote) private var dayWidth: CGFloat = 24

    private var isCompact: Bool { WKInterfaceDevice.current().screenBounds.width < 175 }

    var body: some View {
        let days = match.playedDayPoints(at: date)
        let playedYou = days.compactMap(\.you)
        let playedThem = days.compactMap(\.them)
        let maxPoints = max((playedYou + playedThem).max() ?? 300, 100)
        let tally = match.roundTally(at: date)
        let rows = match.weekRows()

        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 5 : 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isGroup ? "WEEK VS 1ST" : "WEEK ROUNDS")
                        .themeLabel(tracking: 0.9)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    Spacer()
                    HStack(spacing: 3) {
                        Text("\(tally.won)")
                            .font(.score(size: statSize))
                            .foregroundStyle(Theme.you)
                        Text("–")
                            .font(.caption.bold())
                            .foregroundStyle(Theme.tertiary)
                        Text("\(tally.lost)")
                            .font(.score(size: statSize))
                            .foregroundStyle(Theme.ink)
                    }
                    .privacySensitive()
                }
                .padding(.top, isCompact ? 6 : 8)

                HStack(alignment: .bottom, spacing: isCompact ? 3 : 4) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        VStack(spacing: 4) {
                            GeometryReader { geo in
                                HStack(alignment: .bottom, spacing: 2) {
                                    barColumn(value: day.you, maxVal: maxPoints, height: geo.size.height, color: Theme.youFill)
                                    barColumn(value: day.them, maxVal: maxPoints, height: geo.size.height, color: Theme.ink)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            }
                            .frame(height: isCompact ? 52 : 62)

                            Text(day.day)
                                .font(.caption2.weight(day.isToday ? .heavy : .semibold).width(.condensed))
                                .foregroundStyle(day.isToday ? Theme.you : Theme.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 1.5)
                        .background {
                            if day.isToday {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.10))
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .background(
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Theme.panel.opacity(0.92))
                )
                .privacySensitive()
                .accessibilityHidden(true)

                HStack(spacing: 6) {
                    statPill(
                        title: "BEST DAY",
                        value: playedYou.max().map { competitionPointsText($0) } ?? "–",
                        accent: Theme.you
                    )
                    statPill(
                        title: "DAILY AVG",
                        value: playedYou.isEmpty ? "–" : competitionPointsText(playedYou.reduce(0, +) / Double(playedYou.count)),
                        accent: Theme.ink
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        let upcoming = days.indices.contains(index) && days[index].isUpcoming
                        let youText = upcoming ? nil : row.you
                        let themText = upcoming ? nil : row.them
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(row.day)
                                .themeLabel()
                                .textCase(.uppercase)
                                .foregroundStyle(days.indices.contains(index) && days[index].isToday ? Theme.you : Theme.secondary)
                                .frame(width: dayWidth, alignment: .leading)
                            points(youText, Theme.you)
                            Spacer(minLength: 8)
                            points(themText, Theme.ink)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            youText == nil && themText == nil
                                ? "\(row.spoken). No points."
                                : "\(row.spoken). You \(youText ?? "no points"). \(match.name) \(themText ?? "no points")."
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.panel.opacity(0.92))
                )
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
        .containerBackground(
            LinearGradient(
                colors: [Theme.stand.opacity(0.22), Color(hex: 0x0B0B0D)],
                startPoint: .topLeading,
                endPoint: .bottom
            ),
            for: .tabView
        )
        .accessibilityIdentifier("watch.week")
    }

    private func barColumn(value: Double?, maxVal: Double, height: CGFloat, color: Color) -> some View {
        let ratio = value.map { min(1, max(0.08, $0 / maxVal)) } ?? 0
        return RoundedRectangle(cornerRadius: 2)
            .fill(value == nil ? Theme.outline.opacity(0.35) : color)
            .frame(maxWidth: .infinity)
            .frame(height: value == nil ? 4 : height * ratio)
    }

    private func statPill(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2.weight(.bold).width(.condensed))
                .tracking(0.6)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Text(value)
                .font(.score(size: isCompact ? max(16, statSize - 2) : statSize))
                .foregroundStyle(accent)
                .lineLimit(1)
                .privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.panel.opacity(0.92))
        )
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

private struct WatchRivalryPage: View {
    let match: CompetitionWidgetSnapshot.Match
    let date: Date

    @ScaledMetric(relativeTo: .title2) private var recordSize: CGFloat = 34

    private var isCompact: Bool { WKInterfaceDevice.current().screenBounds.width < 175 }

    private func ringColor(_ kind: CompetitionWidgetSnapshot.TodayRings.RingKind) -> Color {
        switch kind {
        case .move: Theme.move
        case .exercise: Theme.exercise
        case .stand: Theme.stand
        case .sleep: Theme.sleep
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 5 : 7) {
                Text("RIVALRY · \(match.name)")
                    .themeLabel(tracking: 0.9)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .privacySensitive()
                    .padding(.top, isCompact ? 6 : 8)

                if let rivalry = match.rivalry {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(rivalry.wins)")
                                .font(.score(size: isCompact ? max(26, recordSize - 6) : recordSize))
                                .foregroundStyle(Theme.you)
                            Text("–")
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(Theme.tertiary)
                            Text("\(rivalry.losses)")
                                .font(.score(size: isCompact ? max(26, recordSize - 6) : recordSize))
                                .foregroundStyle(Theme.ink)
                            if rivalry.ties > 0 {
                                Text("–")
                                    .font(.title3.weight(.heavy))
                                    .foregroundStyle(Theme.tertiary)
                                Text("\(rivalry.ties)")
                                    .font(.score(size: isCompact ? max(26, recordSize - 6) : recordSize))
                                    .foregroundStyle(Theme.secondary)
                            }
                            Spacer(minLength: 4)
                            Text("ALL-TIME")
                                .font(.caption2.weight(.bold).width(.condensed))
                                .tracking(0.6)
                                .foregroundStyle(Theme.tertiary)
                        }

                        if let formLine = rivalry.formLine {
                            Text(formLine)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }

                        if !rivalry.recent.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(Array(rivalry.recent.enumerated()), id: \.offset) { _, outcome in
                                    SlantedBar()
                                        .fill(
                                            outcome == .win ? Theme.youFill
                                                : outcome == .tie ? Theme.tertiary
                                                : Theme.ink.opacity(0.75)
                                        )
                                        .frame(height: 6.5)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 13)
                            .fill(Theme.panel.opacity(0.92))
                    )
                    .privacySensitive()
                }

                if let belt = match.belt {
                    HStack(spacing: 8) {
                        WatchBeltPlate(gold: belt.holder == .you)
                            .frame(height: isCompact ? 16 : 19)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(belt.holder == .you ? "YOUR BELT" : "\(match.name)’S BELT")
                                .font(.caption2.weight(.heavy).width(.condensed))
                                .tracking(0.7)
                                .textCase(.uppercase)
                                .foregroundStyle(belt.holder == .you ? Theme.you : Theme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .privacySensitive(belt.holder == .them)
                            let parts = [
                                match.beltDefensesText,
                                match.rivalry?.reignWeeks.map { "\($0) \($0 == 1 ? "wk" : "wks")" },
                            ].compactMap { $0 }.joined(separator: " · ")
                            if !parts.isEmpty {
                                Text(parts)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Theme.beltWell)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(
                                        Theme.youFill.opacity(belt.holder == .you ? 0.35 : 0.15),
                                        lineWidth: 1
                                    )
                            }
                    )
                }

                if let edge = match.rivalry?.edgeRing, let record = match.rivalry?.edgeRecord {
                    HStack(spacing: 6) {
                        SlantedBar()
                            .fill(ringColor(edge))
                            .frame(width: 9, height: 9)
                        Text(edge.displayName)
                            .font(.caption2.weight(.heavy).width(.condensed))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        Text(record)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Theme.panel.opacity(0.88))
                    )
                    .privacySensitive()
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
        .containerBackground(
            LinearGradient(
                colors: [Theme.sleep.opacity(0.22), Color(hex: 0x0B0B0D)],
                startPoint: .topLeading,
                endPoint: .bottom
            ),
            for: .tabView
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [match.rivalry?.accessibilityLabel(opponentName: match.name), match.beltAccessibilityText]
                .compactMap { $0 }.joined(separator: " ")
        )
        .accessibilityIdentifier("watch.rivalry")
    }
}

private struct WatchGroupOverviewPage: View {
    let match: CompetitionWidgetSnapshot.Match
    let group: CompetitionWidgetSnapshot.Group
    let date: Date

    @ScaledMetric(relativeTo: .body) private var scoreSize: CGFloat = 15
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let topPoints = max(group.rows.map(\.points).max() ?? 1, 1)
        let status = match.boardStatus(at: date)
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(group.title)
                        .themeLabel(tracking: 0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(Theme.tertiary)
                    Text(status)
                        .themeLabel(tracking: 0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 6)

                VStack(spacing: 4.5) {
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(group.isDoubles ? row.name : "\(row.place)  \(row.name)")
                                    .font(.caption2.weight(row.isYou ? .heavy : .semibold))
                                    .foregroundStyle(row.isYou ? Theme.you : Theme.ink)
                                    .lineLimit(1)
                                    .privacySensitive(row.namesSomeone)
                                Spacer(minLength: 4)
                                Text(competitionPointsText(row.points))
                                    .font(.score(size: scoreSize))
                                    .foregroundStyle(row.isYou ? Theme.you : Theme.ink)
                                    .lineLimit(1)
                                    .scoreRoll(row.points, id: "\(match.id)/\(row.name)")
                                    .privacySensitive()
                            }
                            if typeSize < .accessibility1 {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        SlantedBar().fill(Theme.track)
                                        SlantedBar()
                                            .fill(row.isYou ? Theme.youFill : Theme.ink.opacity(0.7))
                                            .frame(width: row.points > 0 ? max(8, geo.size.width * min(1, row.points / topPoints)) : 0)
                                    }
                                }
                                .frame(height: 4.5)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4.5)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(row.isYou ? Theme.youFill.opacity(0.14) : Theme.panel.opacity(0.88))
                        )
                    }
                }

                if let lead = group.lead, typeSize < .accessibility1 {
                    Text(lead)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 2)
                        .padding(.top, 1)
                        .privacySensitive()
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
        .containerBackground(
            LinearGradient(
                colors: [Color(hex: 0x3A3D46).opacity(0.4), Color(hex: 0x0B0B0D)],
                startPoint: .topLeading,
                endPoint: .bottom
            ),
            for: .tabView
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(match.accessibilityLabel(at: date, redacted: false, standings: true))
        .accessibilityIdentifier("watch.match")
    }
}

private struct WatchScheduledPage: View {
    let match: CompetitionWidgetSnapshot.Match
    let date: Date

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let status = match.boardStatus(at: date)
        VStack(alignment: .leading, spacing: 7) {
            Text(status)
                .themeLabel(tracking: 0.9)
                .textCase(.uppercase)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .padding(.top, 8)
            Text(match.name)
                .font(.title2.weight(.heavy).width(.condensed))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .privacySensitive()
            if typeSize < .accessibility1 {
                CompetitionMatchStrip(match: match, date: date, height: 12, spacing: 4)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(
            LinearGradient(
                colors: [Color(hex: 0x2C2C30).opacity(0.4), Color(hex: 0x0B0B0D)],
                startPoint: .topLeading,
                endPoint: .bottom
            ),
            for: .tabView
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(match.accessibilityLabel(at: date, redacted: false, standings: true))
        .accessibilityIdentifier("watch.match")
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
        .padding(.horizontal, 4)
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

    private func color(_ hex: UInt32) -> Color { Color(hex: hex) }

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
    let hasChallenge: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize < .accessibility1 {
                BrandMark()
                    .frame(height: 36)
            }
            Text(text.title)
                .font(.title3.weight(.heavy).width(.condensed))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            if let line = text.line {
                HStack(spacing: 6) {
                    if hasChallenge {
                        SlantedBar().fill(Theme.youFill).frame(width: 4, height: 14)
                    }
                    Text(line)
                        .font(.footnote.weight(hasChallenge ? .semibold : .regular))
                        .foregroundStyle(hasChallenge ? Theme.you : Theme.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.panel)
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .containerBackground(
            LinearGradient(
                colors: [Color(hex: 0x1D1D20), Color.black],
                startPoint: .topLeading,
                endPoint: .bottom
            ),
            for: .navigation
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.accessibilityLabel)
        .accessibilityIdentifier("watch.empty")
    }
}
