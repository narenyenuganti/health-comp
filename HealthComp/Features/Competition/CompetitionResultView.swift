import CompetitionCore
import SwiftUI

struct CompetitionResultView: View {
    let competition: LocalCompetitionPresentation
    let beltEvent: CompetitionBeltEvent?
    let source: CompetitionPublicationSource
    let rematch: CompetitionFeature.CompetitionRematchState
    let isCommandInFlight: Bool
    let send: (CompetitionFeature.Action) -> Void
    let openCompetition: (CompetitionID) -> Void
    var muteButton: CompetitionMuteButton?
    var issue: CompetitionRowIssue? = nil
    var retry: (() async -> Void)? = nil
    var reactions: CompetitionReactionControl? = nil
    var challengeSomeone: (() -> Void)? = nil
    var personalBest: String? = nil
    var recordLink: CompetitionRecordLink? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 52
    @State private var isRevealed = false
    @State private var winLanded = false
    @State private var isDeleteConfirmationPresented = false
    @State private var showsWeek = false
    @State private var showsShare = false
    @State private var replaysCeremony = false
    @State private var replaysJudges = false
    @AppStorage(CompetitionReactionsSeen.storageKey)
    private var reactionsSeen = CompetitionReactionsSeen()
    @AppStorage(CompetitionMotionSeen.storageKey)
    private var motionSeen = CompetitionMotionSeen()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let issue {
                    CompetitionIssueLine(issue: issue, retry: retry, id: competition.id)
                        .transition(Motion.appear)
                }

                muteButton?.failureNote
                    .transition(Motion.appear)

                resultHero
                    .verdictBeat(0, shown: isShown)

                VStack(spacing: 12) {
                    finalScore
                    summaryLine
                }
                .verdictBeat(1, shown: isShown)

                if let text = beltText {
                    beltBanner(text)
                        .verdictBeat(2, shown: isShown)
                        .transition(Motion.appear)
                }

                if let personalBest {
                    headlineLine(personalBest, holder: .you, id: "competition.result.personal-best")
                }

                if let recordLink {
                    CompetitionRecordLinkRow(link: recordLink)
                        .verdictBeat(2, shown: isShown)
                }

                if let split = competitionRingSplit(competition.days) {
                    ringSplitPanel(split)
                        .verdictBeat(2, shown: isShown)
                }

                if let reactions {
                    reactionPanel(reactions)
                        .verdictBeat(2, shown: isShown)
                }

                if isBestAvailableResult {
                    Label(
                        "Someone didn’t sync in time, so this result uses the scores that were in.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .verdictBeat(2, shown: isShown)
                }

                if !competition.days.isEmpty {
                    weekCard
                        .verdictBeat(2, shown: isShown)
                }

                Button {
                    replaysJudges = true
                } label: {
                    Label("Watch the decision again", systemImage: "arrow.counterclockwise")
                        .font(.themeLabel)
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("competition.judges.replay")

                if source == .remoteParticipants, !competition.isPractice {
                    shareResultButton
                        .verdictBeat(2, shown: isShown)
                }

                if dynamicTypeSize.isAccessibilitySize {
                    rematchControl
                }
            }
            .moving(Motion.settle, value: layoutKey)
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.ground)
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                rematchControl
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background(Theme.ground)
            }
        }
        .moving(Motion.settle, value: rematchStage)
        .onChange(of: rematch) { oldValue, newValue in
            guard oldValue == .sending, newValue != .sending,
                  let text = rematchAnnouncement(newValue)
            else { return }
            if case .sent = newValue { Sounds.play(.sent) }
            AccessibilityNotification.Announcement(text).post()
        }
        .sensoryFeedback(trigger: rematchStage) { old, new in
            guard old == .sending else { return nil }
            switch new {
            case .sent: return .success
            case .failed: return .error
            default: return nil
            }
        }
        .sensoryFeedback(.success, trigger: winLanded) { _, landed in landed }
        .navigationTitle(competition.opponentDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hasMenuActions {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        menuActions
                    } label: {
                        CompetitionMoreLabel()
                    }
                    .accessibilityIdentifier("competition.more")
                    .confirmationDialog(
                        "Delete this match from this iPhone?",
                        isPresented: $isDeleteConfirmationPresented,
                        titleVisibility: .visible
                    ) {
                        Button("Delete Local Data", role: .destructive) {
                            send(.deleteTapped(competition.id))
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(
                            "This permanently removes the match and its notifications from this iPhone."
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showsWeek) {
            weekDrawer
        }
        .sheet(isPresented: $showsShare) {
            CompetitionRecapSheet(
                competition: competition,
                belt: recapBelt,
                personalBest: personalBest
            )
        }
        .onDisappear {
            reactionsSeen = reactionsSeen.marking(competition)
            if isRevealed {
                motionSeen = motionSeen.marking(.verdict, competition.id)
            }
        }
        .competitionBeltCeremony(
            event: beltEvent,
            opponentName: opponentName,
            competition: competition,
            isFirstView: isFirstView,
            replay: $replaysCeremony,
            judgesReplay: $replaysJudges,
            onFinished: startVerdict
        )
        .competitionReactionRain()
        .task(id: isRevealed) {
            guard isRevealed, isFirstView, outcome == .win else { return }
            guard voiceOver || !competitionBeltCeremonyCanPlay(beltEvent, opponentName: opponentName)
            else { return }
            if isStaged {
                guard (try? await Task.sleep(for: .seconds(0.35))) != nil else { return }
            }
            winLanded = true
        }
    }

    private func startVerdict() {
        isRevealed = true
    }

    private var isFirstView: Bool {
        !isArchived && !motionSeen.hasSeen(.verdict, competition.id)
    }

    private var isStaged: Bool {
        isFirstView && !reduceMotion && !voiceOver
    }

    private var isShown: Bool {
        isRevealed || !isStaged
    }

    private var layoutKey: [Bool] {
        [
            issue != nil,
            muteButton?.failure != nil,
            beltText != nil,
            reactions?.failed.contains(.result) == true,
            competition.receivedReaction(.result) != nil,
            isArchived,
        ]
    }

    private var recapBelt: CompetitionRecapBelt? {
        competitionRecapBelt(
            beltEvent,
            outcome: outcome,
            isRetired: !competitionRecapAllowsNameChoice(competition)
        )
    }

    private func headlineLine(_ text: String, holder: CompetitionBeltHolder?, id: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(holder == .you ? Theme.you : holder == .them ? Theme.ink : Theme.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(id)
            .verdictBeat(2, shown: isShown)
    }

    private var beltText: (holder: CompetitionBeltHolder, title: String, detail: String?)? {
        beltEvent.flatMap { competitionBeltResultText($0, opponentName: opponentName) }
    }

    private var resultHero: some View {
        VStack(spacing: 10) {
            Text(resultKicker)
                .textCase(.uppercase)
                .themeLabel()
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Text(resultTitle)
                .font(.score(size: headlineSize))
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .accessibilityAddTraits(.isHeader)
            if let disclosure = competitionFixtureDisclosure(
                source: source,
                opponentDisplayName: competition.opponentDisplayName
            ) {
                Text(disclosure)
                    .font(.body)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var resultKicker: String {
        [competition.isPractice ? "Practice" : nil, "Final", weekRangeText, isMuted ? "Muted" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var isMuted: Bool {
        muteButton?.isMuted == true
    }

    private var titleColor: Color {
        switch outcome {
        case .win: Theme.you
        case .loss: Theme.ink
        case .tie: Theme.secondary
        }
    }

    private var weekRangeText: String? {
        guard let first = competition.days.first?.day,
              let last = competition.days.last?.day
        else {
            return nil
        }
        return competitionWeekText(
            first, last, now: competition.evaluatedAt, locale: locale, timeZone: timeZone
        )
    }

    private var digits: Int {
        competitionFinalFractionDigits(
            userPoints: competition.userPoints,
            opponentPoints: competition.opponentPoints
        )
    }

    private var finalScore: some View {
        VStack(spacing: 16) {
            SectionLabel("FINAL SCORE")

            CompetitionFinalScoreLayout { finalScoreOwners }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .themePanel()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("competition.result")
        .accessibilityLabel(
            "\(resultTitle). Final score. You \(competitionPointsAccessibilityText(competition.userPoints, fractionDigits: digits, locale: locale)). \(competition.opponentDisplayName) \(competitionPointsAccessibilityText(competition.opponentPoints, fractionDigits: digits, locale: locale))."
        )
    }

    @ViewBuilder
    private var finalScoreOwners: some View {
        FinalScoreOwner(
            name: "You",
            avatar: PersonAvatar(name: competition.ownerDisplayName, size: 40, isYou: true),
            points: competition.userPoints,
            fractionDigits: digits,
            tint: Theme.you
        )
        Rectangle()
            .fill(Theme.outline)
            .frame(width: 2, height: 52)
            .rotationEffect(.degrees(12))
            .accessibilityHidden(true)
        FinalScoreOwner(
            name: competition.opponentDisplayName,
            avatar: PersonAvatar(
                name: competition.opponentDisplayName,
                photo: competition.opponentProfileID,
                size: 40
            ),
            points: competition.opponentPoints,
            fractionDigits: digits,
            tint: Theme.ink
        )
    }

    @ViewBuilder
    private var summaryLine: some View {
        let margin = competitionMarginText(
            userPoints: competition.userPoints,
            opponentPoints: competition.opponentPoints,
            fractionDigits: digits,
            locale: locale
        )
        let days = competitionDaysSummaryText(competition.days)
        if margin != nil || days != nil {
            let marginColor = competitionDisplayedMargin(
                userPoints: competition.userPoints,
                opponentPoints: competition.opponentPoints,
                fractionDigits: digits
            ) > 0 ? Theme.you : Theme.ink
            let marginText = margin.map {
                Text($0).bold().foregroundStyle(marginColor)
            }
            let daysText = days.map { Text($0).foregroundStyle(Theme.secondary) }
            let separator = marginText != nil && daysText != nil
                ? Text(" · ").foregroundStyle(Theme.tertiary)
                : Text("")
            ((marginText ?? Text("")) + separator + (daysText ?? Text("")))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("competition.result.summary")
        }
    }

    private var weekCard: some View {
        Button {
            showsWeek = true
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SectionLabel("THE WEEK")
                    Spacer(minLength: 8)
                    DisclosureChevron()
                }
                CompetitionWeekStrip(
                    days: competition.days,
                    currentDayOrdinal: nil
                )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themePanel()
            .contentShape(Rectangle())
        }
        .buttonStyle(CompetitionPressButtonStyle())
        .accessibilityLabel(weekCardAccessibilityLabel)
        .accessibilityHint("Opens the scores for each day")
        .accessibilityIdentifier("competition.result.week")
    }

    private var weekCardAccessibilityLabel: String {
        ["The week", competitionDaysSummaryText(competition.days)]
            .compactMap { $0 }
            .joined(separator: ". ")
    }

    private var weekDrawer: some View {
        CompetitionDrawer(title: "The Week", subtitle: weekRangeText) {
            CompetitionWeekChart(
                days: competition.days,
                currentDayOrdinal: nil,
                now: competition.evaluatedAt,
                opponentName: competition.opponentDisplayName
            )
            CompetitionRingLegend(
                days: competition.days,
                opponentName: competition.opponentDisplayName
            )
            if let ringTotals {
                ringTotalsSection(ringTotals)
            }
            if !competition.reactions.isEmpty {
                reactionsSection
            }
        }
    }

    @ViewBuilder
    private func reactionPanel(_ control: CompetitionReactionControl) -> some View {
        let canReact = competitionCanReact(competition)
        let received = competition.receivedReaction(.result)
        if canReact || received != nil {
            VStack(alignment: .leading, spacing: 10) {
                if canReact {
                    CompetitionReactionLabel("REACT TO THE RESULT")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    control.picker(.result, in: competition)
                }
                if let received {
                    CompetitionReactionLine(
                        reaction: received,
                        opponentName: opponentName,
                        id: "competition.reaction.received"
                    )
                    .transition(Motion.appear)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themePanel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("competition.result.react")
            .transition(Motion.appear)
        }
    }

    private var reactionsSection: some View {
        let ordered = competitionReactionsInWeekOrder(competition.reactions)
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("REACTIONS")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, reaction in
                    CompetitionReactionLine(reaction: reaction, opponentName: opponentName)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.reactions")
    }

    private var ringTotals: [(title: String, color: Color, points: Double)]? {
        let scored = competition.days.map(ringSegments).filter { !$0.isEmpty }
        guard !scored.isEmpty, scored.allSatisfy({ $0.count == 3 }) else {
            return nil
        }
        let totals = (0..<3).map { index in
            scored.reduce(0.0) { $0 + $1[index].points }
        }
        return [
            ("MOVE", Theme.move, totals[0]),
            ("EXERCISE", Theme.exercise, totals[1]),
            (competitionStandTitle(competition.days), Theme.stand, totals[2]),
        ]
    }

    private func ringTotalsSection(
        _ totals: [(title: String, color: Color, points: Double)]
    ) -> some View {
        let sum = totals.reduce(0.0) { $0 + $1.points }
        let shown = competitionRoundedParts(totals.map(\.points), total: sum)
        let labelsLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("HOW YOU SCORED")
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(totals.indices, id: \.self) { index in
                        SlantedBar()
                            .fill(totals[index].color)
                            .frame(
                                width: ringShareWidth(
                                    totals[index].points,
                                    of: sum,
                                    in: proxy.size.width - 4
                                )
                            )
                    }
                }
            }
            .frame(height: 24)
            .accessibilityHidden(true)
            labelsLayout { ringTotalLabels(totals, shown: shown) }
        }
        .accessibilityElement(children: .combine)
    }

    private func ringShareWidth(
        _ points: Double,
        of sum: Double,
        in width: CGFloat
    ) -> CGFloat {
        guard sum > 0 else { return 0 }
        return max(2, width * points / sum)
    }

    @ViewBuilder
    private func ringTotalLabels(
        _ totals: [(title: String, color: Color, points: Double)],
        shown: [Double]
    ) -> some View {
        ForEach(totals.indices, id: \.self) { index in
            VStack(alignment: .leading, spacing: 2) {
                Text(totals[index].title)
                    .themeLabel(tracking: 1.1)
                    .foregroundStyle(Theme.secondary)
                Text(competitionPointsText(shown[index], locale: locale))
                    .font(.title2.weight(.heavy).width(.condensed).monospacedDigit())
                    .foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ringSplitPanel(_ split: (you: [Double], them: [Double])) -> some View {
        let metrics = competition.metrics
        let standTitle = competitionStandTitle(competition.days).capitalized
        let rows: [(metric: CompetitionMetric, title: String, you: Double, them: Double)] =
            metrics.orderedMetrics.compactMap { metric in
                switch metric {
                case .move:
                    return (.move, "Move", split.you[0], split.them[0])
                case .exercise:
                    return (.exercise, "Exercise", split.you[1], split.them[1])
                case .stand:
                    return (.stand, standTitle, split.you[2], split.them[2])
                case .sleep:
                    guard let sleep = competition.sleep else { return nil }
                    return (.sleep, "Sleep", sleep.ownerTotal, sleep.opponentTotal)
                }
            }
        let headerTitle = metrics.includesSleep ? "EACH METRIC" : "EACH RING"
        return Group {
            if rows.count > 1 {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(headerTitle)
                    ForEach(rows, id: \.metric) { row in
                        ringSplitRow(row.title, you: row.you, them: row.them)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .themePanel()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    ([metrics.includesSleep ? "Each metric" : "Each ring"] + rows.map {
                        "\($0.title): you \(competitionPointsText($0.you, locale: locale)), \(opponentName) \(competitionPointsText($0.them, locale: locale))"
                    })
                    .joined(separator: ". ")
                )
                .accessibilityIdentifier("competition.result.rings")
            }
        }
    }

    private func ringSplitRow(_ name: String, you: Double, them: Double) -> some View {
        let total = you + them
        return VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            GeometryReader { proxy in
                let width = proxy.size.width - 2
                HStack(spacing: 2) {
                    SlantedBar()
                        .fill(you > them ? Theme.youFill : Theme.track)
                        .frame(width: total > 0 ? width * you / total : width / 2)
                    SlantedBar()
                        .fill(them > you ? Theme.ink : Theme.track)
                }
            }
            .frame(height: 14)
            HStack {
                Text(competitionPointsText(you, locale: locale))
                    .fontWeight(.semibold)
                    .foregroundStyle(you > them ? Theme.you : Theme.secondary)
                Spacer(minLength: 8)
                Text(competitionPointsText(them, locale: locale))
                    .foregroundStyle(Theme.secondary)
            }
            .font(.caption.monospacedDigit())
        }
    }

    @ViewBuilder
    private func beltBanner(
        _ text: (holder: CompetitionBeltHolder, title: String, detail: String?)
    ) -> some View {
        if competitionBeltCeremonyCanPlay(beltEvent, opponentName: opponentName) {
            Button {
                replaysCeremony = true
            } label: {
                beltBannerContent(text)
            }
            .buttonStyle(CompetitionPressButtonStyle())
            .accessibilityHint("Plays the belt ceremony again")
        } else {
            beltBannerContent(text)
        }
    }

    private func beltBannerContent(
        _ text: (holder: CompetitionBeltHolder, title: String, detail: String?)
    ) -> some View {
        VStack(spacing: 0) {
            CompetitionBeltHeroArt(holder: text.holder)
            VStack(spacing: 4) {
                Text(text.title)
                    .font(.title3.weight(.heavy).width(.condensed))
                    .foregroundStyle(text.holder == .you ? Theme.you : Theme.ink)
                if let detail = text.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .themePanel()
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("competition.result.belt")
    }

    private var opponentName: String { competition.opponentDisplayName }

    private var shareResultButton: some View {
        Button {
            showsShare = true
        } label: {
            Label("Share Result", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(SecondaryButtonStyle())
        .accessibilityHint("Opens a preview of the image to share")
        .accessibilityIdentifier("competition.result.share")
    }

    @ViewBuilder
    private var rematchControl: some View {
        if competition.isPractice {
            if let challengeSomeone {
                Button("Challenge Someone", action: challengeSomeone)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("competition.practice.challenge")
            }
        } else {
            rematchStateControl
        }
    }

    private var rematchStage: CompetitionRematchStage { CompetitionRematchStage(rematch) }

    private var rematchStateControl: some View {
        ZStack {
            rematchStateContent
                .transition(Motion.appear)
        }
        .clipped()
    }

    @ViewBuilder
    private var rematchStateContent: some View {
        switch rematch {
        case .available, .sending:
            let isSending = rematch == .sending
            Button {
                send(.rematchTapped(competition.id))
            } label: {
                BusyLabel("Rematch \(opponentName)", isBusy: isSending)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isSending)
            .accessibilityValue(isSending ? "Sending" : "")
            .accessibilityIdentifier("competition.rematch.create")

        case let .sent(challengeID, expiresAt, link):
            sentRow(challengeID: challengeID, expiresAt: expiresAt, link: link)

        case let .received(challenge):
            let text = competitionReceivedRematchText(challenge, locale: locale, timeZone: timeZone)
            rematchRow(
                title: text.title,
                detail: text.detail,
                hint: "Opens the challenge",
                identifier: "competition.rematch.received"
            ) {
                openCompetition(challenge.id)
            }

        case let .next(child):
            let text = nextRowText(child)
            rematchRow(
                title: text.title,
                detail: text.detail,
                hint: "Opens the match",
                identifier: "competition.rematch.next"
            ) {
                openCompetition(child.id)
            }

        case let .alreadyChallenged(challenge):
            VStack(alignment: .leading, spacing: 10) {
                Text("You already challenged \(opponentName).")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Challenge") { openCompetition(challenge.id) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("competition.rematch.open-existing")
            }

        case let .inMatch(match):
            VStack(alignment: .leading, spacing: 10) {
                Text("You’re already in a match with \(opponentName).")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("View Match") { openCompetition(match.id) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("competition.rematch.view-match")
            }

        case let .challengedYou(challenge):
            VStack(alignment: .leading, spacing: 10) {
                Text("\(opponentName) already challenged you.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Review Challenge") { openCompetition(challenge.id) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("competition.rematch.review")
            }

        case let .failed(failure):
            VStack(alignment: .leading, spacing: 10) {
                Text(competitionInviteFailureText(failure, opponentName: opponentName))
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("competition.rematch.error")
                if failure != .recipientGone, failure != .unavailable {
                    Button("Try Again") {
                        send(.rematchTapped(competition.id))
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("competition.rematch.retry")
                }
            }
        }
    }

    @ViewBuilder
    private func sentRow(
        challengeID: CompetitionID,
        expiresAt: Date?,
        link: CompetitionFeature.InviteLinkState?
    ) -> some View {
        let isRemote = source == .remoteParticipants
        let detail: String? = isRemote
            ? "Waiting for \(opponentName)" + (expiresAt.map {
                " · expires \(competitionMomentText($0, now: competition.evaluatedAt, locale: locale, timeZone: timeZone))"
            } ?? "")
            : nil
        let row = rematchRow(
            title: isRemote ? "Rematch sent" : "Rematch ready",
            detail: detail,
            hint: "Opens the challenge",
            identifier: "competition.rematch.sent"
        ) {
            openCompetition(challengeID)
        }
        Group {
            if isRemote, link != .notOnThisPhone {
                let share = ZStack {
                    rematchShare(challengeID: challengeID, link: link)
                        .transition(Motion.appear)
                }
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) {
                        row
                        share
                    }
                } else {
                    HStack(spacing: 10) {
                        row
                        share.fixedSize()
                    }
                }
            } else {
                row
            }
        }
        .task(id: challengeID) {
            if isRemote, link == nil {
                send(.inviteLinkNeeded(challengeID))
            }
        }
    }

    @ViewBuilder
    private func rematchShare(
        challengeID: CompetitionID,
        link: CompetitionFeature.InviteLinkState?
    ) -> some View {
        switch link {
        case let .ready(shareLink, _)?:
            ShareLink(
                item: competitionShareMessage(
                    senderName: competition.ownerDisplayName,
                    link: shareLink
                ),
                subject: Text("Join my HealthComp match")
            ) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityHint(
                "Opens the system share sheet. The private link is not read aloud."
            )
            .accessibilityIdentifier("competition.rematch.share")

        case .failed?:
            Button("Try Again") { send(.inviteLinkNeeded(challengeID)) }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("competition.rematch.share-retry")

        case nil, .loading?, .notOnThisPhone?:
            Button {} label: {
                Label {
                    Text("Share")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                        .hidden()
                        .overlay { ProgressView().waitingFade() }
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(true)
            .accessibilityValue("Loading")
            .accessibilityIdentifier("competition.rematch.share")
        }
    }

    private func rematchRow(
        title: String,
        detail: String?,
        hint: String,
        identifier: String,
        open: @escaping () -> Void
    ) -> some View {
        Button(action: open) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline.width(.condensed))
                        .foregroundStyle(Theme.ink)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                DisclosureChevron()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(CompetitionRowButtonStyle())
        .themePanel(cornerRadius: 14)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [title, detail?.replacing(" · ", with: ", ")]
                .compactMap { $0 }
                .joined(separator: ". ")
        )
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }

    private func nextRowText(
        _ child: LocalCompetitionPresentation
    ) -> (title: String, detail: String?) {
        if case .scheduled = child.lifecycle,
           let schedule = child.acceptedConfiguration?.schedule {
            return (
                "Rematch starts \(weekdayText(schedule.startDay, locale: locale))",
                competitionScheduleDateRangeText(
                    schedule,
                    now: child.evaluatedAt,
                    locale: locale
                )
            )
        }
        return (
            "Rematch",
            competitionStatusText(child, style: .row, locale: locale, timeZone: timeZone).line
        )
    }

    private func rematchAnnouncement(
        _ state: CompetitionFeature.CompetitionRematchState
    ) -> String? {
        switch state {
        case .sent:
            source == .remoteParticipants ? "Rematch sent" : "Rematch ready"
        case let .failed(failure):
            competitionInviteFailureText(failure, opponentName: opponentName)
        case .available, .sending, .received, .next, .alreadyChallenged, .inMatch, .challengedYou:
            nil
        }
    }

    private var dataControl: CompetitionResultDataControl {
        competitionResultDataControl(source: source, isArchived: isArchived)
    }

    private var hasMenuActions: Bool {
        !competition.isPractice && (dataControl != .preservedHistory || muteButton != nil)
    }

    @ViewBuilder
    private var menuActions: some View {
        switch dataControl {
        case .archive:
            Button {
                send(.archiveTapped(competition.id))
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(isCommandInFlight)

        case .deleteLocalData:
            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label("Delete Local Data", systemImage: "trash")
            }
            .disabled(isCommandInFlight)

        case .preservedHistory:
            EmptyView()
        }

        if let muteButton {
            muteButton
        }
    }

    private var outcome: CompetitionOutcome { competitionResultOutcome(competition) }

    private var resultTitle: String {
        competitionResultTitle(
            outcome: outcome,
            opponentDisplayName: competition.opponentDisplayName
        )
    }

    private var isArchived: Bool {
        if case .archived = competition.lifecycle { return true }
        return false
    }

    private var isBestAvailableResult: Bool {
        competition.terminalResult?.basis == .bestAvailable
    }
}

enum CompetitionResultDataControl: Equatable {
    case archive
    case deleteLocalData
    case preservedHistory
}

func competitionResultDataControl(
    source: CompetitionPublicationSource,
    isArchived: Bool
) -> CompetitionResultDataControl {
    guard isArchived else { return .archive }
    return source == .remoteParticipants ? .preservedHistory : .deleteLocalData
}

func competitionResultOutcome(_ competition: LocalCompetitionPresentation) -> CompetitionOutcome {
    competition.terminalResult?.outcome ?? {
        if competition.userPoints > competition.opponentPoints { return .win }
        if competition.userPoints < competition.opponentPoints { return .loss }
        return .tie
    }()
}

func competitionResultTitle(
    outcome: CompetitionOutcome,
    opponentDisplayName: String
) -> String {
    switch outcome {
    case .win: "You beat \(opponentDisplayName)"
    case .loss: "\(opponentDisplayName) won"
    case .tie: "All square with \(opponentDisplayName)"
    }
}

func competitionRingSplit(
    _ days: [LocalCompetitionDayPresentation]
) -> (you: [Double], them: [Double])? {
    var you = [0.0, 0, 0]
    var them = [0.0, 0, 0]
    var counted = false
    for day in days {
        if day.ownerAcceptedPoints != nil {
            guard let rings = day.ownerRingPoints else { return nil }
            you = zip(you, rings).map(+)
        }
        if day.opponentRevealedPoints != nil {
            guard let rings = day.opponentRingPoints else { return nil }
            them = zip(them, rings).map(+)
        }
        counted = counted || (day.ownerAcceptedPoints != nil && day.opponentRevealedPoints != nil)
    }
    return counted ? (you, them) : nil
}

func competitionPersonalBestText(
    for competition: LocalCompetitionPresentation,
    in competitions: [LocalCompetitionPresentation],
    locale: Locale = .current
) -> String? {
    guard competition.metrics.isDefaultRings,
          let result = competition.terminalResult, result.outcome != .win
    else { return nil }
    func bounds(_ week: LocalCompetitionPresentation) -> (start: Date, end: Date)? {
        week.acceptedConfiguration.flatMap { competitionScheduleBoundaries($0.schedule) }
    }
    let weeks = competitionHistoryWeeks(competitions).filter(\.metrics.isDefaultRings)
    guard let index = weeks.firstIndex(where: { $0.id == competition.id }),
          let start = bounds(competition)?.start
    else { return nil }
    let past = weeks[(index + 1)...]
        .filter { bounds($0).map { $0.end <= start } ?? false }
        .prefix(4)
        .compactMap(\.terminalResult?.userPoints)
    guard past.count >= 3 else { return nil }
    let above = (result.userPoints - past.reduce(0, +) / Double(past.count)).rounded()
    guard above >= 1 else { return nil }
    let amount = "\(competitionPointsText(above, locale: locale)) \(above == 1 ? "point" : "points")"
    if past.allSatisfy({ result.userPoints > $0 }) {
        return "Your best week of your last \(past.count + 1), \(amount) above your average"
    }
    return "\(amount) above your average week"
}

struct CompetitionHeadline: Equatable {
    enum Kind: Equatable { case tookBelt, personalBest, allThreeRings, titleDefense, lead }
    let kind: Kind
    let text: String
    let holder: CompetitionBeltHolder?

    var isBelt: Bool { kind == .tookBelt || kind == .titleDefense }
}

func competitionHeadline(
    belt: CompetitionRecapBelt?,
    personalBest: String?,
    days: [LocalCompetitionDayPresentation],
    opponentName: String?
) -> CompetitionHeadline? {
    let beltLine = belt.map { belt -> CompetitionHeadline in
        let kind: CompetitionHeadline.Kind = switch belt {
        case .youTook, .theyTook: .tookBelt
        case .youDefended, .theyDefended: .titleDefense
        }
        return CompetitionHeadline(
            kind: kind,
            text: competitionRecapBeltText(belt, opponentName: opponentName),
            holder: belt.isYours ? .you : .them
        )
    }
    if let beltLine, beltLine.kind == .tookBelt { return beltLine }
    if let personalBest {
        return CompetitionHeadline(kind: .personalBest, text: personalBest, holder: .you)
    }
    if let split = competitionRingSplit(days),
       days.first?.metrics.isDefaultRings ?? true,
       (0..<3).allSatisfy({ split.you[$0] > split.them[$0] }) {
        return CompetitionHeadline(kind: .allThreeRings, text: "Took all three rings", holder: .you)
    }
    if let beltLine { return beltLine }
    guard let lead = competitionLeadLine(days, currentDayOrdinal: nil) else { return nil }
    let after = lead.margins.dropFirst()
    switch lead.changes.count {
    case 1:
        return CompetitionHeadline(kind: .lead, text: "The lead changed hands once", holder: nil)
    case 2:
        return CompetitionHeadline(kind: .lead, text: "The lead changed hands twice", holder: nil)
    case 3...:
        return CompetitionHeadline(
            kind: .lead, text: "The lead changed hands \(lead.changes.count) times", holder: nil
        )
    default:
        if after.allSatisfy({ $0 > 0 }) {
            return CompetitionHeadline(kind: .lead, text: "You led after every day", holder: .you)
        }
        if after.allSatisfy({ $0 < 0 }) {
            return CompetitionHeadline(
                kind: .lead, text: "\(opponentName ?? "They") led after every day", holder: .them
            )
        }
    }
    return nil
}

func competitionDaysSummaryText(_ days: [LocalCompetitionDayPresentation]) -> String? {
    let outcomes = days.map { competitionDayOutcome($0, currentDayOrdinal: nil) }
    let parts = [("won", CompetitionDayOutcome.won), ("lost", .lost), ("tied", .tied)]
        .map { verb, outcome in (verb, outcomes.filter { $0 == outcome }.count) }
        .filter { $0.1 > 0 }
    guard let first = parts.first else { return nil }
    let rest = parts.dropFirst().map { "\($0.0) \($0.1)" }
    return (["\(first.0) \(first.1) \(first.1 == 1 ? "day" : "days")"] + rest)
        .joined(separator: ", ")
}

struct CompetitionFinalScoreLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let contentProposal = contentSizedProposal(proposal)
        let layout = fittingLayout(proposal: contentProposal, subviews: subviews)
        var layoutCache = layout.makeCache(subviews: subviews)
        return layout.sizeThatFits(
            proposal: contentProposal, subviews: subviews, cache: &layoutCache
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let contentProposal = contentSizedProposal(proposal)
        let layout = fittingLayout(proposal: contentProposal, subviews: subviews)
        var layoutCache = layout.makeCache(subviews: subviews)
        _ = layout.sizeThatFits(
            proposal: contentProposal, subviews: subviews, cache: &layoutCache
        )
        layout.placeSubviews(
            in: bounds, proposal: contentProposal, subviews: subviews,
            cache: &layoutCache
        )
    }

    private func contentSizedProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(
            width: proposal.width.flatMap { $0.isFinite ? $0 : nil },
            height: proposal.height.flatMap { $0.isFinite ? $0 : nil }
        )
    }

    private func fittingLayout(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> AnyLayout {
        let horizontal = AnyLayout(HStackLayout(alignment: .bottom, spacing: 24))
        guard let width = proposal.width, width.isFinite else {
            return horizontal
        }
        var horizontalCache = horizontal.makeCache(subviews: subviews)
        let idealWidth = horizontal.sizeThatFits(
            proposal: .unspecified, subviews: subviews,
            cache: &horizontalCache
        ).width
        return idealWidth <= width
            ? horizontal
            : AnyLayout(VStackLayout(spacing: 18))
    }
}

private struct FinalScoreOwner: View {
    let name: String
    let avatar: PersonAvatar
    let points: Double
    let fractionDigits: Int
    let tint: Color

    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = 52
    var body: some View {
        VStack(spacing: 4) {
            avatar
                .padding(.bottom, 2)
            Text(name)
                .font(.subheadline.weight(.semibold))
            Text(competitionPointsText(points, fractionDigits: fractionDigits))
                .font(.score(size: scoreSize))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
    }
}

private extension View {
    func verdictBeat(_ step: Int, shown: Bool) -> some View {
        opacity(shown ? 1 : Motion.pendingOpacity)
            .animation(Motion.beat(step), value: shown)
    }
}

enum CompetitionRematchStage: Equatable {
    case available, sending
    case sent(expiryKnown: Bool, link: CompetitionFeature.InviteLinkState?)
    case received, next, alreadyChallenged, challengedYou, inMatch
    case failed(CompetitionFeature.InviteCreationFailure)

    init(_ state: CompetitionFeature.CompetitionRematchState) {
        switch state {
        case .available: self = .available
        case .sending: self = .sending
        case let .sent(_, expiresAt, link):
            self = .sent(expiryKnown: expiresAt != nil, link: link)
        case .received: self = .received
        case .next: self = .next
        case .alreadyChallenged: self = .alreadyChallenged
        case .challengedYou: self = .challengedYou
        case .inMatch: self = .inMatch
        case let .failed(failure): self = .failed(failure)
        }
    }
}

extension CompetitionMotionSeen {
    enum Moment: String {
        case verdict
        case judges
        case belt
        case versus
    }

    func hasSeen(_ moment: Moment, _ id: CompetitionID) -> Bool {
        weekDrawn[Self.mark(moment, id)] != nil
    }

    func marking(_ moment: Moment, _ id: CompetitionID) -> Self {
        var marked = self
        marked.weekDrawn[Self.mark(moment, id)] = 1
        return marked
    }

    private static func mark(_ moment: Moment, _ id: CompetitionID) -> String {
        "\(moment.rawValue):\(id.rawValue.uuidString.lowercased())"
    }
}

func competitionReceivedRematchText(
    _ challenge: LocalCompetitionPresentation,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> (title: String, detail: String?) {
    (
        "\(challenge.opponentDisplayName) sent a rematch",
        challenge.pendingExpiresAt.map {
            "Expires \(competitionMomentText($0, now: challenge.evaluatedAt, locale: locale, timeZone: timeZone))"
        }
    )
}
